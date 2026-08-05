import XCTest
@testable import ElementaryAudio

final class ReconciliationCacheTests: XCTestCase {
    func testLookupMissingHashReturnsNil() {
        let cache = ReconciliationCache()
        XCTAssertNil(cache.lookup(hash: 42))
    }

    func testInsertThenLookupReturnsEntry() {
        let cache = ReconciliationCache()
        let nodeId = NodeID()
        let properties: NodeProperties = ["value": .number(1)]

        cache.insert(hash: 42, nodeId: nodeId, properties: properties)

        let entry = cache.lookup(hash: 42)
        XCTAssertEqual(entry?.nodeId, nodeId)
        XCTAssertEqual(entry?.properties, properties)
    }

    func testUpdatePropertiesMutatesStoredSnapshot() {
        let cache = ReconciliationCache()
        let nodeId = NodeID()
        cache.insert(hash: 42, nodeId: nodeId, properties: ["value": .number(1)])

        cache.updateProperties(hash: 42, properties: ["value": .number(2)])

        XCTAssertEqual(cache.lookup(hash: 42)?.properties, ["value": .number(2)])
    }

    func testEvictRemovesEntryByNodeId() {
        let cache = ReconciliationCache()
        let nodeId = NodeID()
        cache.insert(hash: 42, nodeId: nodeId, properties: [:])

        cache.evict(nodeIds: [nodeId.rawValue])

        XCTAssertNil(cache.lookup(hash: 42))
    }

    func testEvictWithUnknownNodeIdIsANoOp() {
        let cache = ReconciliationCache()
        let nodeId = NodeID()
        cache.insert(hash: 42, nodeId: nodeId, properties: [:])

        cache.evict(nodeIds: [Int32(999_999)])

        XCTAssertNotNil(cache.lookup(hash: 42))
    }

    func testRemoveAllClearsEverything() {
        let cache = ReconciliationCache()
        cache.insert(hash: 1, nodeId: NodeID(), properties: [:])
        cache.insert(hash: 2, nodeId: NodeID(), properties: [:])

        cache.removeAll()

        XCTAssertNil(cache.lookup(hash: 1))
        XCTAssertNil(cache.lookup(hash: 2))
    }
}
