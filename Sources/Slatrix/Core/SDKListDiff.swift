import MatrixRustSDK

/// One change from an SDK list stream. The generated update enums all share these cases.
enum SDKListDiff<Element> {
    case append([Element])
    case clear
    case pushFront(Element)
    case pushBack(Element)
    case popFront, popBack
    case insert(UInt32, Element)
    case set(UInt32, Element)
    case remove(UInt32)
    case truncate(UInt32)
    case reset([Element])

    /// The elements this change adds or replaces.
    var values: [Element] {
        switch self {
        case .append(let values), .reset(let values): values
        case .pushFront(let value), .pushBack(let value), .insert(_, let value), .set(_, let value): [value]
        case .clear, .popFront, .popBack, .remove, .truncate: []
        }
    }
}

extension Array {
    /// Applies SDK changes in order. A change whose index this copy lacks means the copy and the
    /// stream disagree: it is skipped, the rest still apply, and the result is false.
    @discardableResult
    mutating func apply(_ diffs: [SDKListDiff<Element>]) -> Bool {
        var consistent = true
        for diff in diffs {
            switch diff {
            case .append(let values): append(contentsOf: values)
            case .clear: removeAll()
            case .pushFront(let value): insert(value, at: 0)
            case .pushBack(let value): append(value)
            case .popFront where !isEmpty: removeFirst()
            case .popBack where !isEmpty: removeLast()
            case .insert(let index, let value) where Int(index) <= count: insert(value, at: Int(index))
            case .set(let index, let value) where Int(index) < count: self[Int(index)] = value
            case .remove(let index) where Int(index) < count: remove(at: Int(index))
            case .truncate(let length): if Int(length) < count { removeSubrange(Int(length)...) }
            case .reset(let values): self = values
            default: consistent = false
            }
        }
        return consistent
    }
}

extension TimelineDiff {
    var change: SDKListDiff<TimelineItem> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(index, value)
        case .set(let index, let value): .set(index, value)
        case .remove(let index): .remove(index)
        case .truncate(let length): .truncate(length)
        case .reset(let values): .reset(values)
        }
    }
}

extension SearchServiceResultsUpdate {
    var change: SDKListDiff<SearchServiceResult> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(index, value)
        case .set(let index, let value): .set(index, value)
        case .remove(let index): .remove(index)
        case .truncate(let length): .truncate(length)
        case .reset(let values): .reset(values)
        }
    }
}

extension ThreadListUpdate {
    var change: SDKListDiff<ThreadListItem> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(index, value)
        case .set(let index, let value): .set(index, value)
        case .remove(let index): .remove(index)
        case .truncate(let length): .truncate(length)
        case .reset(let values): .reset(values)
        }
    }
}

extension RoomDirectorySearchEntryUpdate {
    var change: SDKListDiff<RoomDescription> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(index, value)
        case .set(let index, let value): .set(index, value)
        case .remove(let index): .remove(index)
        case .truncate(let length): .truncate(length)
        case .reset(let values): .reset(values)
        }
    }
}
