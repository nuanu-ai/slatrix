import Testing

@testable import Slatrix

struct SDKListDiffTests {
    @Test(
        "SDK list changes apply in order; a change outside the list is skipped and reported",
        arguments: [
            ([.append(["c", "d"])], ["a", "b", "c", "d"], true),
            ([.clear, .pushBack("x")], ["x"], true),
            ([.pushFront("z"), .popBack], ["z", "a"], true),
            ([.popFront, .popFront, .popFront], [], false),
            ([.insert(1, "x"), .set(0, "y"), .remove(2)], ["y", "x"], true),
            ([.insert(2, "x")], ["a", "b", "x"], true),
            ([.insert(4, "x"), .set(2, "x"), .remove(2), .pushBack("c")], ["a", "b", "c"], false),
            ([.truncate(1)], ["a"], true),
            ([.truncate(9)], ["a", "b"], true),
            ([.reset(["r"]), .popBack, .popBack], [], false),
        ] as [([SDKListDiff<String>], [String], Bool)])
    func applies(diffs: [SDKListDiff<String>], expected: [String], consistent: Bool) {
        var list = ["a", "b"]
        #expect(list.apply(diffs) == consistent)
        #expect(list == expected)
    }
}
