// AP2b: a tool call's approval status on its transcript row.
//
// The mapping from the store's per-`tool_use_id` state to the words (`awaiting your approval`,
// `approved by you · 14:02`, …) is AppKit-free, so it lives in NostromoKit:
//   Shared/NostromoKit/Sources/NostromoKit/Approvals/ApprovalRowStatusText.swift  (the words)
//   Shared/NostromoKit/Sources/NostromoKit/Approvals/ApprovalStatusBook.swift     (the bounded per-focus cache)
// `ApprovalStore` keeps the book (fed by `approval_request`, `approval_resolved` and `approval_guard_blocked`).
// The row field itself is `FoldRowView.approvalField` (ToolGroupView.swift), shared by the tool-group row and
// the Focus view's activity header (ActivityRowView.swift).
