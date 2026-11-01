import AppKit
import Combine
import NostromoKit

/// What the subagent viewer reads of a focus's transcript. `ChatSession` is the real one; a test passes
/// a fake that holds recorded turns.
protocol SubagentTranscriptSource: AnyObject {
    var turns: [ChatTurn] { get }
    var changes: PassthroughSubject<TurnChange, Never> { get }
}

extension ChatSession: SubagentTranscriptSource {}

/// One subagent's part of a transcript, collected from the turns of its focus.
///
/// A subagent's work reaches the transcript in two shapes: its tool calls and results carry the Agent
/// call's id (`parentToolUseId`), and its text blocks are marked in the turn's `subagentTextParents`
/// (block index to parent id). Both are read here. The copies drop their parent id, so the viewer shows
/// them as an ordinary turn (the main transcript's own rendering folds them under the Agent call).
struct SubagentConversation {
    /// The subagent's own text, calls and results, in transcript order.
    var blocks: [TurnBlock] = []
    /// The `prompt` of the Agent call's input.
    var callPrompt: String?
    /// What the Agent call returned.
    var callResult: String?
    /// The Agent call itself is in the transcript.
    var agentCallFound = false

    /// The longest prompt or result the viewer draws.
    static let textLimit = 20_000

    static func collect(toolUseId: String, from turns: [ChatTurn]) -> SubagentConversation {
        var found = SubagentConversation()
        for turn in turns where turn.truncatedLengths == nil {
            for (index, block) in turn.blocks.enumerated() {
                switch block {
                case .toolCall(var call):
                    if call.toolUseId == toolUseId {
                        found.agentCallFound = true
                        found.callPrompt = found.callPrompt ?? prompt(inputFull: call.inputFull)
                    } else if call.parentToolUseId == toolUseId {
                        call.parentToolUseId = nil
                        found.blocks.append(.toolCall(call))
                    }
                case .toolResult(var result):
                    if result.parentToolUseId == toolUseId {
                        result.parentToolUseId = nil
                        found.blocks.append(.toolResult(result))
                    } else if result.toolUseId == toolUseId {
                        found.callResult = result.content
                    }
                case .text:
                    if turn.subagentTextParents[index] == toolUseId { found.blocks.append(block) }
                default:
                    break
                }
            }
        }
        return found
    }

    /// The `prompt` of an Agent/Task call's JSON input.
    static func prompt(inputFull: String) -> String? {
        guard let data = inputFull.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = object["prompt"] as? String, !prompt.isEmpty else { return nil }
        return prompt
    }
}

/// An agent task's window body: the header (tokens, tool uses, the tool it is on now), and the
/// subagent's own conversation, live: its prompt, its messages and tool groups in order through the
/// transcript's own `ChatTurnView`, and its final result at the bottom once it has ended.
///
/// The conversation is a synthetic `ChatTurn` of the blocks `SubagentConversation` collects, with the
/// prompt as its message and every group open (All activity). Folds are kept **in memory**
/// (`TurnInteractionStore` here, never `TranscriptFoldStore`), so toggling a group in the viewer
/// cannot change how the main transcript is folded.
///
/// With no blocks (Nostromo restarted, or the turns were trimmed or went cold) it says so, with the
/// prompt and result when it knows them.
final class SubagentTaskView: NSView, TaskWindowBody {
    static let unavailableMessage = "This subagent\u{2019}s conversation isn\u{2019}t available " +
        "(Nostromo restarted or the history was trimmed)."
    static let waitingMessage = "The subagent hasn\u{2019}t said anything yet."
    static let promptHeading = "Prompt"
    static let resultHeading = "Result"
    static let missingPrompt = "(The prompt isn\u{2019}t available.)"
    private static let pad: CGFloat = 12

    /// The focus the task belongs to. (Never `tag`: that is `NSView.tag`, an `Int`.)
    let focusTag: String
    let taskId: String
    let header = TaskWindowHeaderView()
    let scrollView = NSScrollView()

    /// The conversation's turn view; nil while there is nothing to show in it.
    private(set) var turnView: ChatTurnView?
    /// The prompt, when the daemon or the Agent call gave it.
    private(set) var promptText: String?
    /// The final result (the Agent call's, else the task's completion summary) once the task has ended.
    private(set) var resultText: String?
    private(set) var conversationBlockCount = 0

    private let source: SubagentTranscriptSource?
    private let document = SubagentDocumentView()
    private let promptHeadingLabel = SubagentTaskView.makeHeading(SubagentTaskView.promptHeading)
    private let promptLabel = SubagentTaskView.makeBody()
    private let messageLabel = SubagentTaskView.makeBody()
    private let resultHeadingLabel = SubagentTaskView.makeHeading(SubagentTaskView.resultHeading)
    private let resultLabel = SubagentTaskView.makeBody()
    private let interactions = TurnInteractionStore()
    private let turnId = UUID()
    private var content: TaskWindowContent?
    private var toolUseId: String?
    private var subscription: AnyCancellable?
    private var isRelayingOut = false
    private var isFollowing = true
    private var lastBlockSignature: [String] = []

    /// The message shown instead of a conversation (`unavailableMessage`, `waitingMessage`); nil with one.
    var conversationMessage: String? { messageLabel.isHidden ? nil : messageLabel.stringValue }

    init(focusTag: String, taskId: String, source: SubagentTranscriptSource?) {
        self.focusTag = focusTag
        self.taskId = taskId
        self.source = source
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TaskWindowPalette.background.cgColor

        scrollView.drawsBackground = true
        scrollView.backgroundColor = TaskWindowPalette.background
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        for view in [promptHeadingLabel, promptLabel, messageLabel, resultHeadingLabel, resultLabel] {
            view.isHidden = true
            document.addSubview(view)
        }
        for view in [header, scrollView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scrollView)
        addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        subscription = source?.changes.sink { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: TaskWindowBody

    func apply(content: TaskWindowContent) {
        self.content = content
        toolUseId = content.toolUseId
        header.apply(content)
        refresh()
    }

    // MARK: Refresh

    /// Read the transcript again and bring the view in line with it (every change the session reports).
    func refresh() {
        let following = isFollowing && isNearBottom
        let found = toolUseId.flatMap { id in source.map { SubagentConversation.collect(toolUseId: id, from: $0.turns) } }
            ?? SubagentConversation()
        conversationBlockCount = found.blocks.count

        let prompt = (content?.prompt ?? found.callPrompt).map(Self.clipped)
        promptText = prompt
        let ended = content?.isEnded == true
        let result = ended ? (found.callResult.map { Self.clipped(FoldTextSanitizer.sanitizeMultiline($0)) } ?? content?.summary) : nil
        resultText = result

        show(prompt: prompt, found: found, ended: ended)
        showResult(result)
        relayout()
        if following { scrollToBottom() }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        guard !isRelayingOut else { return }
        isRelayingOut = true
        defer { isRelayingOut = false }
        let width = scrollView.contentSize.width
        guard width > 1 else { return }
        let pad = Self.pad
        let inner = width - 2 * pad
        var y = pad

        func place(_ label: NSTextField) {
            guard !label.isHidden else { return }
            label.preferredMaxLayoutWidth = inner
            let height = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100_000)).height ?? 16
            label.frame = NSRect(x: pad, y: y, width: inner, height: ceil(height))
            y += ceil(height) + 6
        }
        place(promptHeadingLabel)
        place(promptLabel)
        place(messageLabel)
        if let turnView {
            turnView.setIslandWidth(inner)
            let height = turnView.islandHeight()
            turnView.frame = NSRect(x: pad, y: y, width: inner, height: height)
            y += height + 10
        }
        place(resultHeadingLabel)
        place(resultLabel)
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y + pad, scrollView.contentSize.height))
    }

    // MARK: Private

    private var isNearBottom: Bool {
        FollowTailPolicy.isNearBottom(documentHeight: document.frame.height,
                                      visibleMaxY: scrollView.contentView.bounds.maxY)
    }

    private func scrollToBottom() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - clip.bounds.height)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func show(prompt: String?, found: SubagentConversation, ended: Bool) {
        if found.blocks.isEmpty {
            dropTurnView()
            let waiting = !ended && found.agentCallFound
            setLabel(promptHeadingLabel, text: prompt == nil ? nil : Self.promptHeading)
            setLabel(promptLabel, text: prompt)
            setLabel(messageLabel, text: waiting ? Self.waitingMessage : Self.unavailableMessage)
            return
        }
        setLabel(promptHeadingLabel, text: nil)
        setLabel(promptLabel, text: nil)
        setLabel(messageLabel, text: nil)
        let message = prompt.map { FoldTextSanitizer.sanitizeMultiline($0) } ?? Self.missingPrompt
        let turn = ChatTurn(id: turnId, userInput: message, timestamp: Date(timeIntervalSince1970: 0),
                            blocks: found.blocks, isComplete: ended)
        let signature = found.blocks.map { Self.signature(of: $0) }
        // Blocks only added at the end go in through `update`; a text that changed where it stood (the
        // attach snapshot replaced it) is not something `update` repaints, so that one is a new view.
        if let existing = turnView, signature.starts(with: lastBlockSignature), message == lastPrompt {
            existing.update(turn: turn)
        } else {
            rebuildTurnView(turn)
        }
        lastBlockSignature = signature
        lastPrompt = message
    }

    private var lastPrompt = ""

    private func rebuildTurnView(_ turn: ChatTurn) {
        dropTurnView()
        let state = interactions.state(for: turn.id)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: state,
                                folds: FoldResolver(state: state, expandedByDefault: true))
        let id = turn.id
        view.onGroupToggle = { [weak self] key, open in
            self?.interactions.setGroup(turn: id, key: key, open)
            self?.relayout()
        }
        view.onActivityToggle = { [weak self] key, open in
            self?.interactions.setActivity(turn: id, key: key, open)
            self?.relayout()
        }
        view.onBlockExpansion = { [weak self] block, open in
            self?.interactions.setExpanded(turn: id, block: block, open)
            self?.relayout()
        }
        view.onIntrinsicHeightChange = { [weak self] in self?.relayout() }
        document.addSubview(view)
        turnView = view
    }

    private func dropTurnView() {
        turnView?.removeFromSuperview()
        turnView = nil
        lastBlockSignature = []
        lastPrompt = ""
    }

    private func showResult(_ result: String?) {
        setLabel(resultHeadingLabel, text: result == nil ? nil : Self.resultHeading)
        setLabel(resultLabel, text: result)
    }

    private func setLabel(_ label: NSTextField, text: String?) {
        label.isHidden = text == nil
        let new = text ?? ""
        if label.stringValue != new { label.stringValue = new }
    }

    /// What a block is, for telling "more blocks" from "a block changed": its kind, and a text's length.
    private static func signature(of block: TurnBlock) -> String {
        if case .text(let text) = block { return "t\(text.utf16.count)" }
        return block.kindCode
    }

    private static func clipped(_ text: String) -> String {
        let clean = FoldTextSanitizer.sanitizeMultiline(text)
        return clean.count > SubagentConversation.textLimit
            ? String(clean.prefix(SubagentConversation.textLimit - 1)) + "\u{2026}" : clean
    }

    private static func makeHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = TaskWindowPalette.muted
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }

    private static func makeBody() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = TaskWindowPalette.text
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }
}

/// The scrolled content: top-down coordinates, laid out by hand.
private final class SubagentDocumentView: NSView {
    override var isFlipped: Bool { true }
}
