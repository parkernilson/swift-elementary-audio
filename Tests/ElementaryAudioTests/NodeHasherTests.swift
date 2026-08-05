import XCTest
@testable import ElementaryAudio

final class NodeHasherTests: XCTestCase {
    func testIdenticalUnkeyedNodesHashEqually() {
        let propsA: NodeProperties = ["value": .number(1)]
        let propsB: NodeProperties = ["value": .number(1)]
        XCTAssertEqual(
            NodeHasher.hash(nodeType: "const", properties: propsA, childHashes: []),
            NodeHasher.hash(nodeType: "const", properties: propsB, childHashes: [])
        )
    }

    func testUnkeyedPropertyValueChangeChangesHash() {
        let propsA: NodeProperties = ["value": .number(1)]
        let propsB: NodeProperties = ["value": .number(2)]
        XCTAssertNotEqual(
            NodeHasher.hash(nodeType: "const", properties: propsA, childHashes: []),
            NodeHasher.hash(nodeType: "const", properties: propsB, childHashes: [])
        )
    }

    func testKeyedPropertyValueChangeDoesNotChangeHash() {
        let propsA: NodeProperties = ["key": .string("freq"), "value": .number(440)]
        let propsB: NodeProperties = ["key": .string("freq"), "value": .number(441)]
        XCTAssertEqual(
            NodeHasher.hash(nodeType: "const", properties: propsA, childHashes: []),
            NodeHasher.hash(nodeType: "const", properties: propsB, childHashes: [])
        )
    }

    func testDifferentKeysHashDifferently() {
        let propsA: NodeProperties = ["key": .string("a"), "value": .number(1)]
        let propsB: NodeProperties = ["key": .string("b"), "value": .number(1)]
        XCTAssertNotEqual(
            NodeHasher.hash(nodeType: "const", properties: propsA, childHashes: []),
            NodeHasher.hash(nodeType: "const", properties: propsB, childHashes: [])
        )
    }

    func testDifferentNodeTypesHashDifferently() {
        let props: NodeProperties = ["value": .number(1)]
        XCTAssertNotEqual(
            NodeHasher.hash(nodeType: "const", properties: props, childHashes: []),
            NodeHasher.hash(nodeType: "phasor", properties: props, childHashes: [])
        )
    }

    func testDifferentChildHashesChangeParentHash() {
        let props = NodeProperties()
        XCTAssertNotEqual(
            NodeHasher.hash(nodeType: "mul", properties: props, childHashes: [1, 2]),
            NodeHasher.hash(nodeType: "mul", properties: props, childHashes: [1, 3])
        )
    }

    func testPropertyIterationOrderDoesNotAffectHash() {
        var propsA = NodeProperties()
        propsA["a"] = .number(1)
        propsA["b"] = .number(2)

        var propsB = NodeProperties()
        propsB["b"] = .number(2)
        propsB["a"] = .number(1)

        XCTAssertEqual(
            NodeHasher.hash(nodeType: "mul", properties: propsA, childHashes: []),
            NodeHasher.hash(nodeType: "mul", properties: propsB, childHashes: [])
        )
    }
}
