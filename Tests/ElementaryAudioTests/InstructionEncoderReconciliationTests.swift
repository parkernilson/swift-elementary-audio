import XCTest
@testable import ElementaryAudio

final class InstructionEncoderReconciliationTests: XCTestCase {
    func testStructuralEqualityWithValueChangeEmitsOnlyASingleSetProperty() {
        let cache = ReconciliationCache()

        var firstEncoder = InstructionEncoder()
        firstEncoder.encode(AudioGraph(root: KeyedConstNode(key: "freq", value: 440)), cache: cache)
        let originalNodeId = firstEncoder.allInstructions.first { $0.type == .createNode }?.nodeId
        XCTAssertNotNil(originalNodeId)

        var secondEncoder = InstructionEncoder()
        secondEncoder.encode(AudioGraph(root: KeyedConstNode(key: "freq", value: 441)), cache: cache)

        let secondInstructions = secondEncoder.allInstructions
        XCTAssertTrue(secondInstructions.filter { $0.type == .createNode }.isEmpty, "hash-matched node must not be recreated")
        XCTAssertTrue(secondInstructions.filter { $0.type == .appendChild }.isEmpty)

        let setPropertyInstructions = secondInstructions.filter { $0.type == .setProperty }
        XCTAssertEqual(setPropertyInstructions.count, 1, "only the changed property should be sent")
        XCTAssertEqual(setPropertyInstructions.first?.nodeId, originalNodeId)
        XCTAssertEqual(setPropertyInstructions.first?.propertyKey, "value")
        XCTAssertEqual(setPropertyInstructions.first?.propertyValue, .number(441))
    }

    func testSwitchAndSwitchBackReusesOriginalNode() {
        let cache = ReconciliationCache()

        var encoder1 = InstructionEncoder()
        encoder1.encode(AudioGraph(root: KeyedConstNode(key: "a", value: 1)), cache: cache)
        let nodeAId = encoder1.allInstructions.first { $0.type == .createNode }?.nodeId
        XCTAssertNotNil(nodeAId)

        var encoder2 = InstructionEncoder()
        encoder2.encode(AudioGraph(root: KeyedConstNode(key: "b", value: 2)), cache: cache)
        XCTAssertEqual(encoder2.allInstructions.filter { $0.type == .createNode }.count, 1, "switching to a structurally different node creates it")

        var encoder3 = InstructionEncoder()
        encoder3.encode(AudioGraph(root: KeyedConstNode(key: "a", value: 1)), cache: cache)

        XCTAssertTrue(encoder3.allInstructions.filter { $0.type == .createNode }.isEmpty, "switching back to A's hash must reuse the original node, not recreate it")
        let activateInstruction = encoder3.allInstructions.first { $0.type == .activateRoots }
        XCTAssertEqual(activateInstruction?.rootIds, [nodeAId!])
    }

    func testUnkeyedPropertyChangeRecreatesTheNode() {
        let cache = ReconciliationCache()

        var encoder1 = InstructionEncoder()
        encoder1.encode(AudioGraph(root: ConstNode(0.25)), cache: cache)
        XCTAssertEqual(encoder1.allInstructions.filter { $0.type == .createNode }.count, 1)

        var encoder2 = InstructionEncoder()
        encoder2.encode(AudioGraph(root: ConstNode(0.75)), cache: cache)

        XCTAssertEqual(encoder2.allInstructions.filter { $0.type == .createNode }.count, 1, "an unkeyed property change has no way to be recognized as the same node, so it must be recreated")
    }

    func testDifferentKeysAreNeverConflated() {
        let cache = ReconciliationCache()

        var encoder1 = InstructionEncoder()
        encoder1.encode(AudioGraph(root: KeyedConstNode(key: "a", value: 1)), cache: cache)
        let idA = encoder1.allInstructions.first { $0.type == .createNode }?.nodeId

        var encoder2 = InstructionEncoder()
        encoder2.encode(AudioGraph(root: KeyedConstNode(key: "b", value: 1)), cache: cache)
        let idB = encoder2.allInstructions.first { $0.type == .createNode }?.nodeId

        XCTAssertNotNil(idA)
        XCTAssertNotNil(idB)
        XCTAssertNotEqual(idA, idB, "different keys, even with identical values, must never be treated as the same node")
        XCTAssertEqual(encoder2.allInstructions.filter { $0.type == .createNode }.count, 1)
    }

    func testEvictedNodeIsRecreatedRatherThanReused() {
        let cache = ReconciliationCache()

        var encoder1 = InstructionEncoder()
        encoder1.encode(AudioGraph(root: KeyedConstNode(key: "freq", value: 440)), cache: cache)
        let originalNodeId = encoder1.allInstructions.first { $0.type == .createNode }?.nodeId
        XCTAssertNotNil(originalNodeId)

        // Simulate what GraphRenderer.gc() does once the native runtime
        // reports this node ID as pruned: evict it from the cache.
        cache.evict(nodeIds: [originalNodeId!.rawValue])

        var encoder2 = InstructionEncoder()
        encoder2.encode(AudioGraph(root: KeyedConstNode(key: "freq", value: 440)), cache: cache)

        XCTAssertEqual(encoder2.allInstructions.filter { $0.type == .createNode }.count, 1, "once evicted, an identical-looking node must be treated as a fresh miss, not reused")
    }
}
