import Foundation

/// The editable language table for `SyntaxHighlighter`. Adding a C-like language
/// means adding one `SyntaxLanguageSpec` to `all` (and, if it needs scanner
/// features that don't exist yet, a `Feature`).
struct SyntaxLanguageSpec: Sendable {
    enum Feature: Sendable {
        case sql, php, bash, json, yaml, swift, rust, python, js, diff
    }

    struct BlockComment: Sendable {
        let open: String
        let close: String
    }

    /// Lowercase aliases (a fence info string's first word, matched case-insensitively).
    let ids: [String]
    var lineComments: [String] = []
    var blockComment: BlockComment?
    var blockCommentsNest = false
    var keywords: Set<String> = []
    var literals: Set<String> = []
    var builtinTypes: Set<String> = []
    /// SQL and PHP: `select`, `SELECT` and `Select` are the same keyword. The sets
    /// above are then lowercase.
    var caseInsensitiveKeywords = false
    /// Swift, Rust, JS/TS, Python, PHP: `Foo` / `URLSession` (starts uppercase, has a
    /// lowercase letter) is a `.type`.
    var capitalizedIdentifiersAreTypes = false
    var features: Set<Feature> = []

    /// `text` and friends: a known fence language that gets no tokens.
    var isPlain: Bool { features.isEmpty && keywords.isEmpty && lineComments.isEmpty }
}

enum SyntaxLanguages {

    static func spec(for language: String) -> SyntaxLanguageSpec? {
        byID[language.lowercased()]
    }

    private static let byID: [String: SyntaxLanguageSpec] = {
        var table: [String: SyntaxLanguageSpec] = [:]
        for spec in all {
            for id in spec.ids { table[id] = spec }
        }
        return table
    }()

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    static let all: [SyntaxLanguageSpec] = [
        SyntaxLanguageSpec(
            ids: ["sql", "mysql", "postgres", "postgresql", "psql", "sqlite", "plpgsql"],
            lineComments: ["--"],
            blockComment: .init(open: "/*", close: "*/"),
            keywords: words("""
                select from where and or not in is as on join inner left right full outer cross
                group by order having limit offset union all distinct insert into values update set
                delete create alter drop table index view database schema primary key foreign
                references unique default check constraint add column case when then else end like
                between exists asc desc with recursive begin commit rollback transaction explain
                analyze truncate grant revoke if replace returning over partition using natural
                intersect except
                """),
            literals: words("null true false"),
            builtinTypes: words("""
                int integer bigint smallint tinyint varchar char text boolean bool date datetime
                timestamp decimal numeric float double json uuid serial blob
                """),
            caseInsensitiveKeywords: true,
            features: [.sql]),

        SyntaxLanguageSpec(
            ids: ["php"],
            lineComments: ["//", "#"],
            blockComment: .init(open: "/*", close: "*/"),
            keywords: words("""
                abstract and array as break callable case catch class clone const continue declare
                default do echo else elseif empty enddeclare endfor endforeach endif endswitch
                endwhile enum extends final finally fn for foreach function global goto if
                implements include include_once instanceof insteadof interface isset list match
                namespace new or print private protected public readonly require require_once
                return static switch throw trait try unset use var while xor yield
                """),
            literals: words("true false null"),
            builtinTypes: words("int float string bool mixed void never iterable callable object"),
            caseInsensitiveKeywords: true,
            capitalizedIdentifiersAreTypes: true,
            features: [.php]),

        SyntaxLanguageSpec(
            ids: ["bash", "sh", "zsh", "shell"],
            lineComments: ["#"],
            keywords: words("""
                if then else elif fi for while until do done case esac function in select return
                local export readonly declare unset break continue
                """),
            literals: words("true false"),
            features: [.bash]),

        SyntaxLanguageSpec(
            ids: ["json", "jsonc", "json5"],
            lineComments: ["//"],
            blockComment: .init(open: "/*", close: "*/"),
            literals: words("true false null"),
            features: [.json]),

        SyntaxLanguageSpec(
            ids: ["yaml", "yml"],
            lineComments: ["#"],
            features: [.yaml]),

        SyntaxLanguageSpec(
            ids: ["swift"],
            lineComments: ["//"],
            blockComment: .init(open: "/*", close: "*/"),
            blockCommentsNest: true,
            keywords: words("""
                associatedtype class deinit enum extension fileprivate func import init inout
                internal let operator private precedencegroup protocol public rethrows static
                struct subscript typealias var break case catch continue default defer do else
                fallthrough for guard if in repeat return throw switch where while as await async
                is self Self super throws try actor nonisolated mutating override final lazy weak
                unowned indirect convenience required willSet didSet
                """),
            literals: words("true false nil"),
            capitalizedIdentifiersAreTypes: true,
            features: [.swift]),

        SyntaxLanguageSpec(
            ids: ["rust", "rs"],
            lineComments: ["//"],
            blockComment: .init(open: "/*", close: "*/"),
            blockCommentsNest: true,
            keywords: words("""
                as async await break const continue crate dyn else enum extern fn for if impl in
                let loop match mod move mut pub ref return self Self static struct super trait
                type unsafe use where while
                """),
            literals: words("true false"),
            builtinTypes: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
            capitalizedIdentifiersAreTypes: true,
            features: [.rust]),

        SyntaxLanguageSpec(
            ids: ["python", "py", "python3"],
            lineComments: ["#"],
            keywords: words("""
                and as assert async await break class continue def del elif else except finally
                for from global if import in is lambda nonlocal not or pass raise return try
                while with yield
                """),
            literals: words("True False None"),
            builtinTypes: words("int float str bool bytes list dict set tuple"),
            capitalizedIdentifiersAreTypes: true,
            features: [.python]),

        SyntaxLanguageSpec(
            ids: ["js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx"],
            lineComments: ["//"],
            blockComment: .init(open: "/*", close: "*/"),
            keywords: words("""
                async await break case catch class const continue debugger default delete do else
                export extends finally for function if import in instanceof let new of return
                static super switch this throw try typeof var void while with yield interface type
                enum implements declare namespace readonly keyof as satisfies abstract private
                protected public
                """),
            literals: words("true false null undefined NaN Infinity"),
            capitalizedIdentifiersAreTypes: true,
            features: [.js]),

        SyntaxLanguageSpec(
            ids: ["diff", "patch"],
            features: [.diff]),

        SyntaxLanguageSpec(
            ids: ["text", "plain", "txt", "plaintext"]),
    ]
}
