import Foundation

/// Encodes Swift audio graph into instructions for the C++ runtime
///
/// The instruction encoder traverses the audio graph and generates a series
/// of instructions that the Elementary Audio runtime can execute to build
/// and update the processing graph. Traversal is hash-aware: given a
/// `ReconciliationCache` that persists across calls, a node whose structural
/// hash already exists in the cache is treated as the same node -- only a
/// property diff is emitted -- rather than being recreated. See
/// `NodeHasher` and `ReconciliationCache`.
public struct InstructionEncoder: Sendable {
    /// Instruction types matching the C++ runtime (v4: deleteNode removed, GC handles cleanup)
    public enum InstructionType: Int32, Sendable {
        case createNode = 0
        case appendChild = 2
        case setProperty = 3
        case activateRoots = 4
        case commitUpdates = 5
    }

    /// A single instruction for the runtime
    public struct Instruction: Sendable {
        public let type: InstructionType
        public let nodeId: NodeID?
        public let nodeType: String?
        public let propertyKey: String?
        public let propertyValue: PropertyValue?
        public let childId: NodeID?
        public let childOutputChannel: Int32?
        public let rootIds: [NodeID]?

        init(type: InstructionType,
             nodeId: NodeID? = nil,
             nodeType: String? = nil,
             propertyKey: String? = nil,
             propertyValue: PropertyValue? = nil,
             childId: NodeID? = nil,
             childOutputChannel: Int32? = nil,
             rootIds: [NodeID]? = nil) {
            self.type = type
            self.nodeId = nodeId
            self.nodeType = nodeType
            self.propertyKey = propertyKey
            self.propertyValue = propertyValue
            self.childId = childId
            self.childOutputChannel = childOutputChannel
            self.rootIds = rootIds
        }
    }

    private var instructions: [Instruction] = []

    /// Creates a new instruction encoder
    public init() {}

    // MARK: - Encoding Methods

    /// Encodes a complete audio graph against a persistent reconciliation
    /// cache, emitting only the instructions needed to bring the runtime
    /// from whatever `cache` last reflects to `graph`.
    ///
    /// - Parameters:
    ///   - graph: The audio graph to encode
    ///   - cache: The cross-render node cache. Pass the same instance across
    ///     successive calls (as `GraphRenderer` does) to get in-place
    ///     property updates instead of full recreation for unchanged nodes.
    mutating func encode(_ graph: AudioGraph, cache: ReconciliationCache) {
        // Local to this single encode() call only -- see encodeNode's doc
        // comment. Not persisted across renders (unlike `cache`, which is).
        var visited: [Int32: (nodeId: NodeID, hash: Int)] = [:]
        let rootIds = graph.roots.map { encodeNode($0, cache: cache, visited: &visited).nodeId }
        activateRoots(rootIds)
        commit()
    }

    /// Encodes a single node and its children recursively, reusing an
    /// existing native node when this node's structural hash is already in
    /// `cache`.
    ///
    /// - Parameter visited: A memo of nodes already processed *within this
    ///   one `encode()` call*, keyed by the Swift node's own object-identity
    ///   `nodeId`. A node referenced from multiple places in a single graph
    ///   (e.g. a shared LFO signal feeding two destinations) would otherwise
    ///   be re-walked once per reference -- correct (the cross-render
    ///   `cache` still resolves repeat encounters to the same native node
    ///   id) but exponential in the depth of shared subgraphs, since every
    ///   root-to-leaf path re-visits shared nodes. This memo restores O(nodes)
    ///   traversal by short-circuiting on a second encounter of the same
    ///   Swift node instance in this call.
    /// - Returns: The resolved node ID (the cached one on a hit, or the
    ///   node's own freshly-assigned one on a miss) and its structural hash
    ///   -- both needed by the caller (a parent node computing its own hash,
    ///   or `encode` activating roots).
    @discardableResult
    private mutating func encodeNode(
        _ node: any AudioNode,
        cache: ReconciliationCache,
        visited: inout [Int32: (nodeId: NodeID, hash: Int)]
    ) -> (nodeId: NodeID, hash: Int) {
        // Unwrap Signal to get the actual node
        let actualNode: any AudioNode
        let actualNodeType: String

        if let signal = node as? Signal {
            actualNode = signal.underlyingNode
            actualNodeType = signal.wrappedNodeType
        } else {
            actualNode = node
            actualNodeType = node.nodeType
        }

        if let alreadyProcessed = visited[actualNode.nodeId.rawValue] {
            return alreadyProcessed
        }

        // Children must be resolved first: their (possibly-reused) node IDs
        // feed both this node's hash and, on a miss, its appendChild calls.
        let childResults = actualNode.children.map { encodeNode($0, cache: cache, visited: &visited) }
        let childHashes = childResults.map { $0.hash }
        let hash = NodeHasher.hash(nodeType: actualNodeType, properties: actualNode.properties, childHashes: childHashes)

        let resolved: (nodeId: NodeID, hash: Int)
        if let existing = cache.lookup(hash: hash) {
            // Hit: same node as a previous render (or an earlier reference
            // to it within this same render) -- update only changed props.
            for (key, value) in actualNode.properties where existing.properties[key] != value {
                setProperty(nodeId: existing.nodeId, key: key, value: value)
            }
            cache.updateProperties(hash: hash, properties: actualNode.properties)
            resolved = (existing.nodeId, hash)
        } else {
            // Miss: a genuinely new/changed node -- create it fully.
            let nodeId = actualNode.nodeId
            createNode(id: nodeId, type: actualNodeType)
            for (key, value) in actualNode.properties {
                setProperty(nodeId: nodeId, key: key, value: value)
            }
            for childResult in childResults {
                appendChild(parentId: nodeId, childId: childResult.nodeId)
            }
            cache.insert(hash: hash, nodeId: nodeId, properties: actualNode.properties)
            resolved = (nodeId, hash)
        }

        visited[actualNode.nodeId.rawValue] = resolved
        return resolved
    }

    // MARK: - Instruction Generation

    /// Creates a node with the given type
    public mutating func createNode(id: NodeID, type: String) {
        instructions.append(Instruction(
            type: .createNode,
            nodeId: id,
            nodeType: type
        ))
    }

    /// Appends a child node to a parent
    /// - Parameters:
    ///   - parentId: The parent node ID
    ///   - childId: The child node ID
    ///   - outputChannel: The child's output channel (0 for mono nodes)
    public mutating func appendChild(parentId: NodeID, childId: NodeID, outputChannel: Int32 = 0) {
        instructions.append(Instruction(
            type: .appendChild,
            nodeId: parentId,
            childId: childId,
            childOutputChannel: outputChannel
        ))
    }

    /// Sets a property on a node
    public mutating func setProperty(nodeId: NodeID, key: String, value: PropertyValue) {
        instructions.append(Instruction(
            type: .setProperty,
            nodeId: nodeId,
            propertyKey: key,
            propertyValue: value
        ))
    }

    /// Activates the specified root nodes for output
    public mutating func activateRoots(_ rootIds: [NodeID]) {
        instructions.append(Instruction(
            type: .activateRoots,
            rootIds: rootIds
        ))
    }

    /// Commits all pending updates
    public mutating func commit() {
        instructions.append(Instruction(type: .commitUpdates))
    }

    // MARK: - Output

    /// Returns all generated instructions
    public var allInstructions: [Instruction] { instructions }

    /// The number of instructions generated
    public var count: Int { instructions.count }

    /// Clears all instructions
    public mutating func clear() {
        instructions.removeAll()
    }
}

// MARK: - Debug Description

extension InstructionEncoder.Instruction: CustomStringConvertible {
    public var description: String {
        switch type {
        case .createNode:
            return "CREATE(\(nodeId?.rawValue ?? -1), \(nodeType ?? "?"))"
        case .appendChild:
            return "APPEND(\(nodeId?.rawValue ?? -1), \(childId?.rawValue ?? -1), ch:\(childOutputChannel ?? 0))"
        case .setProperty:
            return "SET(\(nodeId?.rawValue ?? -1), \(propertyKey ?? "?"), \(propertyValue.map { "\($0)" } ?? "?"))"
        case .activateRoots:
            let ids = rootIds?.map { "\($0.rawValue)" }.joined(separator: ", ") ?? ""
            return "ACTIVATE([\(ids)])"
        case .commitUpdates:
            return "COMMIT"
        }
    }
}

extension InstructionEncoder: CustomStringConvertible {
    public var description: String {
        instructions.map { $0.description }.joined(separator: "\n")
    }
}
