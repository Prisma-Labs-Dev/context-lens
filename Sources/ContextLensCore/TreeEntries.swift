/// One line of the context tree: a group header or an item. The tree shows these as a flat
/// list, so a lazy stack only ever places one short row at a time.
public enum TreeEntry: Identifiable, Sendable {
    case header(kind: ContextKind, count: Int, tokens: Int, open: Bool)
    case item(ContextItem)

    public var id: String {
        switch self {
        case .header(let kind, _, _, _): "group|\(kind.rawValue)"
        case .item(let item): Self.id(item: item.id)
        }
    }

    /// The row id of an item, for scrolling to it.
    public static func id(item: ContextItem.ID) -> String { "item|\(item)" }

    public var item: ContextItem? {
        if case .item(let item) = self { item } else { nil }
    }
}

extension ContextSnapshot {
    /// The tree as flat rows: each non-empty group's header, then its items unless collapsed.
    public func treeEntries(collapsed: Set<ContextKind> = [], onlyProblems: Bool = false) -> [TreeEntry] {
        var out: [TreeEntry] = []
        out.reserveCapacity(items.count + ContextKind.allCases.count)
        for section in sections {
            let items = onlyProblems ? section.items.filter(\.hasProblem) : section.items
            guard !items.isEmpty else { continue }
            let open = !collapsed.contains(section.kind)
            out.append(.header(kind: section.kind, count: items.count, tokens: items.reduce(0) { $0 + $1.startingTokens }, open: open))
            if open { out += items.map(TreeEntry.item) }
        }
        return out
    }
}
