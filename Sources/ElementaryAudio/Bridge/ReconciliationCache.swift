import Foundation

/// Tracks nodes across successive `GraphRenderer.render()` calls so that
/// structurally-unchanged nodes are recognized and updated in place instead
/// of being recreated on every render.
///
/// Mirrors the JS core's `Renderer.nodeMap` (`@elemaudio/core`, see
/// `../elementary/js/packages/core/src/index.ts`): a single persistent map
/// from a node's structural hash (see `NodeHasher`) to the native node ID
/// and properties it was last created/updated with. There is no old-tree
/// vs. new-tree diff -- each render just checks the new tree's node hashes
/// against this map.
final class ReconciliationCache: @unchecked Sendable {
    struct Entry {
        var nodeId: NodeID
        var properties: NodeProperties
    }

    private var entriesByHash: [Int: Entry] = [:]
    private var hashByNodeId: [Int32: Int] = [:]

    /// Looks up a previously-created node by its structural hash.
    func lookup(hash: Int) -> Entry? {
        entriesByHash[hash]
    }

    /// Registers a newly-created node under its structural hash.
    func insert(hash: Int, nodeId: NodeID, properties: NodeProperties) {
        entriesByHash[hash] = Entry(nodeId: nodeId, properties: properties)
        hashByNodeId[nodeId.rawValue] = hash
    }

    /// Updates the cached properties snapshot for an existing entry, e.g.
    /// after diffing and sending only the changed properties.
    func updateProperties(hash: Int, properties: NodeProperties) {
        entriesByHash[hash]?.properties = properties
    }

    /// Removes entries for node IDs the native runtime has actually pruned
    /// via `gc()`, keeping this cache in sync with what the runtime has
    /// destroyed. Unknown node IDs are ignored.
    func evict<S: Sequence>(nodeIds: S) where S.Element == Int32 {
        for nodeId in nodeIds {
            if let hash = hashByNodeId.removeValue(forKey: nodeId) {
                entriesByHash.removeValue(forKey: hash)
            }
        }
    }

    /// Clears all cached state.
    func removeAll() {
        entriesByHash.removeAll()
        hashByNodeId.removeAll()
    }
}
