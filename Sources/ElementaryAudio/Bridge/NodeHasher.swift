import Foundation

/// Computes a content-addressed structural hash for an audio graph node,
/// mirroring Elementary's JS core (`HashUtils.hashNode` in `@elemaudio/core`'s
/// `Reconciler`/`NodeRepr` implementation -- see
/// `../elementary/js/packages/core/src/HashUtils.res`).
///
/// Two nodes with the same `nodeType`, the same identity (see below), and
/// the same children hashes (in order) are considered the same node across
/// renders, letting `InstructionEncoder` update properties in place instead
/// of recreating the node. See the design spec at
/// `docs/superpowers/specs/2026-08-03-graph-reconciliation-engine-design.md`.
enum NodeHasher {
    /// Computes the structural hash for a single node given its already-
    /// resolved type, properties, and its children's hashes (in traversal
    /// order).
    ///
    /// If `properties` contains a `"key"` string property, only that key
    /// contributes to the hash -- all other property values are excluded,
    /// so changing them does not change the hash. Without a string `"key"`,
    /// every property value is folded into the hash, so any value change
    /// produces a different hash.
    static func hash(nodeType: String, properties: NodeProperties, childHashes: [Int]) -> Int {
        var hasher = Hasher()
        hasher.combine(nodeType)

        if case .string(let key)? = properties["key"] {
            hasher.combine(key)
        } else {
            for propertyKey in properties.keys.sorted() {
                hasher.combine(propertyKey)
                hasher.combine(properties[propertyKey])
            }
        }

        for childHash in childHashes {
            hasher.combine(childHash)
        }

        return hasher.finalize()
    }
}
