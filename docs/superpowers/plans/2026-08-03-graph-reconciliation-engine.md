# Graph Reconciliation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Elementary Audio's actual JS reconciliation algorithm (content-addressed node hashing + a persistent cross-render node cache + diff-based instruction emission) into this Swift port, so `GraphRenderer.render()` called repeatedly with a structurally-similar graph updates unchanged/keyed nodes in place instead of recreating them every call.

**Architecture:** Add a pure hashing function (`NodeHasher`) and a persistent cache class (`ReconciliationCache`) in the `Bridge` layer. Rewire `InstructionEncoder`'s tree walk to consult that cache (hash hit → props diff only; hash miss → full create, as today) and `GraphRenderer` to own the cache across `render()` calls. Fix `ElemRuntime::gc()` (C++) to return pruned node IDs so the cache can be kept in sync with what the native runtime actually destroys.

**Tech Stack:** Swift 5.10 (Cxx interoperability mode), C++20, `elem::Runtime<float>` (vendored Elementary Audio C++ runtime), XCTest.

## Global Constraints

- Swift/C++ interop via `.interoperabilityMode(.Cxx)` — all touched Swift files in the `ElementaryAudio` target already build under this mode; no new interop mode changes needed.
- No `DELETE_NODE` instruction exists in the v4 runtime — cleanup is via `Runtime::gc()` only. This plan does not add any delete/teardown instruction; matches upstream Elementary, which also never emits one from its reconciler.
- `NodeId`/`NodeID.rawValue` is `Int32` on both sides (`Types.h: using NodeId = int32_t;` / `NodeID.swift: rawValue: Int32`).
- This plan does not add `createRef`, does not rename any existing Swift type (`GraphRenderer`, `AudioEngine`, `El`, etc.), and does not add positional/index-based matching — see the design spec's Non-goals for why.

## Environment note

`swift build`/`swift test` could not be executed in this planning session — the sandboxed environment's `swift package` manifest compilation fails with `sandbox-exec: sandbox_apply: Operation not permitted` regardless of sandbox settings on the Bash tool itself (a limitation of this specific execution environment, not of the code). Every verification step below still specifies the exact command and expected outcome; whoever executes this plan needs an environment where `swift build`/`swift test` actually run (e.g. this repo opened directly in Xcode, or a differently-configured agent sandbox) to confirm each step's outcome.

---

## File Structure

**New files:**
- `Sources/ElementaryAudio/Bridge/NodeHasher.swift` — pure structural-hash function.
- `Sources/ElementaryAudio/Bridge/ReconciliationCache.swift` — persistent hash → node cache, owned by `GraphRenderer`.
- `Tests/ElementaryAudioTests/NodeHasherTests.swift`
- `Tests/ElementaryAudioTests/ReconciliationCacheTests.swift`
- `Tests/ElementaryAudioTests/InstructionEncoderReconciliationTests.swift`

**Modified files:**
- `Sources/ElementaryAudio/Core/PropertyValue.swift` — add `Hashable` conformance (needed by `NodeHasher`).
- `Sources/ElementaryAudio/Bridge/InstructionEncoder.swift` — `encode(_:)` becomes `encode(_:cache:)`; `encodeNode` becomes hash-aware.
- `Sources/ElementaryAudio/Bridge/GraphRenderer.swift` — owns a `ReconciliationCache`; `render()`, `clear()`, `gc()` updated.
- `Sources/cxxElementaryAudio/ElemRuntime.h` — `gc()` returns `std::vector<int32_t>` instead of `void`.
- `Sources/ElementaryAudio/Core/VFSLoader.swift` — one call site (`pruneUnreferencedResources()`) updated for the new `gc()` return type.
- `Tests/ElementaryAudioTests/GraphRendererProcessTests.swift` — two new integration/smoke tests.
- `CLAUDE.md` — test count comment updated to the new total.

`InstructionEncoder.encode`'s signature change and `GraphRenderer`'s corresponding call-site fix **must land in the same task/commit** — the `ElementaryAudio` target won't compile with one changed and not the other, which would block every test (including the new ones) from even running. Same reasoning applies to `ElemRuntime::gc()`'s signature change and `GraphRenderer.gc()`'s fix.

---

### Task 1: `NodeHasher` — structural hash algorithm

**Files:**
- Modify: `Sources/ElementaryAudio/Core/PropertyValue.swift`
- Create: `Sources/ElementaryAudio/Bridge/NodeHasher.swift`
- Test: `Tests/ElementaryAudioTests/NodeHasherTests.swift`

**Interfaces:**
- Produces: `enum NodeHasher { static func hash(nodeType: String, properties: NodeProperties, childHashes: [Int]) -> Int }` — used by Task 3.
- Produces: `PropertyValue: Hashable` (in addition to its existing `Sendable, Equatable`) — used by `NodeHasher` and by Task 3's property diffing (unchanged there, `Equatable` already sufficed for diffing; `Hashable` is only needed for hashing).

- [ ] **Step 1: Write the failing tests**

Create `Tests/ElementaryAudioTests/NodeHasherTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NodeHasherTests`
Expected: FAIL to build — `NodeHasher` does not exist yet (`cannot find 'NodeHasher' in scope`).

- [ ] **Step 3: Add `Hashable` to `PropertyValue`**

In `Sources/ElementaryAudio/Core/PropertyValue.swift`, change:

```swift
public enum PropertyValue: Sendable, Equatable {
```

to:

```swift
public enum PropertyValue: Sendable, Equatable, Hashable {
```

(Swift auto-synthesizes `hash(into:)` for this enum — every associated value across its cases, `Double`, `Bool`, `String`, `[Double]`, and `[String: PropertyValue]`, is itself `Hashable`, including the recursive `.object` case since `PropertyValue` is now `Hashable` too.)

- [ ] **Step 4: Write `NodeHasher`**

Create `Sources/ElementaryAudio/Bridge/NodeHasher.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter NodeHasherTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ElementaryAudio/Core/PropertyValue.swift Sources/ElementaryAudio/Bridge/NodeHasher.swift Tests/ElementaryAudioTests/NodeHasherTests.swift
git commit -m "feat: add NodeHasher for content-addressed node identity"
```

---

### Task 2: `ReconciliationCache` — persistent cross-render node cache

**Files:**
- Create: `Sources/ElementaryAudio/Bridge/ReconciliationCache.swift`
- Test: `Tests/ElementaryAudioTests/ReconciliationCacheTests.swift`

**Interfaces:**
- Consumes: `NodeID` (`Core/NodeID.swift`, existing), `NodeProperties` (`Core/NodeProperties.swift`, existing).
- Produces: `final class ReconciliationCache { struct Entry { var nodeId: NodeID; var properties: NodeProperties }; func lookup(hash: Int) -> Entry?; func insert(hash: Int, nodeId: NodeID, properties: NodeProperties); func updateProperties(hash: Int, properties: NodeProperties); func evict<S: Sequence>(nodeIds: S) where S.Element == Int32; func removeAll() }` — used by Task 3 and Task 4.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ElementaryAudioTests/ReconciliationCacheTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ReconciliationCacheTests`
Expected: FAIL to build — `ReconciliationCache` does not exist yet.

- [ ] **Step 3: Write `ReconciliationCache`**

Create `Sources/ElementaryAudio/Bridge/ReconciliationCache.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ReconciliationCacheTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ElementaryAudio/Bridge/ReconciliationCache.swift Tests/ElementaryAudioTests/ReconciliationCacheTests.swift
git commit -m "feat: add ReconciliationCache for cross-render node identity"
```

---

### Task 3: Rewire `InstructionEncoder` + `GraphRenderer` to reconcile instead of rebuild

**Files:**
- Modify: `Sources/ElementaryAudio/Bridge/InstructionEncoder.swift`
- Modify: `Sources/ElementaryAudio/Bridge/GraphRenderer.swift:41-48` (the `render(_:)` body) and `:150-155` (`clear()`)
- Test: `Tests/ElementaryAudioTests/InstructionEncoderReconciliationTests.swift`
- Test: `Tests/ElementaryAudioTests/GraphRendererProcessTests.swift` (add one test)

**Interfaces:**
- Consumes: `NodeHasher.hash(nodeType:properties:childHashes:)` (Task 1), `ReconciliationCache` (Task 2).
- Produces: `InstructionEncoder.encode(_ graph: AudioGraph, cache: ReconciliationCache)` (replaces the old zero-cache `encode(_:)` — this is the exact signature Task 4 and any future caller must use).

- [ ] **Step 1: Write the failing tests**

Create `Tests/ElementaryAudioTests/InstructionEncoderReconciliationTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InstructionEncoderReconciliationTests`
Expected: FAIL to build — `InstructionEncoder.encode` does not accept a `cache:` argument yet.

- [ ] **Step 3: Rewrite `InstructionEncoder`**

Replace the full contents of `Sources/ElementaryAudio/Bridge/InstructionEncoder.swift` with:

```swift
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
    public mutating func encode(_ graph: AudioGraph, cache: ReconciliationCache) {
        let rootIds = graph.roots.map { encodeNode($0, cache: cache).nodeId }
        activateRoots(rootIds)
        commit()
    }

    /// Encodes a single node and its children recursively, reusing an
    /// existing native node when this node's structural hash is already in
    /// `cache`.
    ///
    /// - Returns: The resolved node ID (the cached one on a hit, or the
    ///   node's own freshly-assigned one on a miss) and its structural hash
    ///   -- both needed by the caller (a parent node computing its own hash,
    ///   or `encode` activating roots).
    @discardableResult
    private mutating func encodeNode(_ node: any AudioNode, cache: ReconciliationCache) -> (nodeId: NodeID, hash: Int) {
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

        // Children must be resolved first: their (possibly-reused) node IDs
        // feed both this node's hash and, on a miss, its appendChild calls.
        let childResults = actualNode.children.map { encodeNode($0, cache: cache) }
        let childHashes = childResults.map { $0.hash }
        let hash = NodeHasher.hash(nodeType: actualNodeType, properties: actualNode.properties, childHashes: childHashes)

        if let existing = cache.lookup(hash: hash) {
            // Hit: same node as a previous render (or an earlier reference
            // to it within this same render) -- update only changed props.
            for (key, value) in actualNode.properties where existing.properties[key] != value {
                setProperty(nodeId: existing.nodeId, key: key, value: value)
            }
            cache.updateProperties(hash: hash, properties: actualNode.properties)
            return (existing.nodeId, hash)
        }

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
        return (nodeId, hash)
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
```

Note what changed from the current file: `encodedNodes: Set<Int32>` (the old within-one-`encode()`-call dedup, keyed by Swift-object identity) is removed entirely -- deduplication now falls out naturally from the hash cache itself (a second reference to a structurally-identical node within the same render is just another cache hit), which also matches Elementary's real behavior of merging structurally-identical sibling nodes into one native node, not only object-identical ones.

- [ ] **Step 4: Fix `GraphRenderer`'s call site (same commit -- see File Structure note)**

In `Sources/ElementaryAudio/Bridge/GraphRenderer.swift`, find:

```swift
    // Track node IDs we've created for cleanup
    private var createdNodeIds: Set<Int32> = []
    // Track root IDs for activation
    private var currentRootIds: [Int32] = []
```

Change to:

```swift
    // Track node IDs we've created for cleanup
    private var createdNodeIds: Set<Int32> = []
    // Track root IDs for activation
    private var currentRootIds: [Int32] = []
    // Persists across render() calls so unchanged nodes are updated in place
    // instead of recreated -- see ReconciliationCache.
    private let reconciliationCache = ReconciliationCache()
```

Find, inside `render(_ graph: AudioGraph)`:

```swift
        // Encode the graph to instructions
        var encoder = InstructionEncoder()
        encoder.encode(graph)
```

Change to:

```swift
        // Encode the graph to instructions
        var encoder = InstructionEncoder()
        encoder.encode(graph, cache: reconciliationCache)
```

Find `clear()`:

```swift
    public func clear() {
        // Just clear tracking - nodes will be replaced on next render
        // The runtime handles node replacement internally
        createdNodeIds.removeAll()
        currentRootIds.removeAll()
    }
```

Change to:

```swift
    public func clear() {
        // Just clear tracking - nodes will be replaced on next render
        // The runtime handles node replacement internally
        createdNodeIds.removeAll()
        currentRootIds.removeAll()
        reconciliationCache.removeAll()
    }
```

- [ ] **Step 5: Add an integration-level test to `GraphRendererProcessTests.swift`**

Add this test to `Tests/ElementaryAudioTests/GraphRendererProcessTests.swift` (in the `// MARK: - Integration` section, alongside `testRenderThenProcessMultipleBlocksDoesNotCrash`):

```swift
    func testRepeatedRenderWithKeyedConstStaysNonSilentAfterValueChange() throws {
        let firstGraph = AudioGraph { El.cycle(El.const(key: "freq", value: 440.0)) * 0.5 }
        try renderer.render(firstGraph)

        for _ in 0 ..< 4 { _ = processBlock(numSamples: 512) }

        let secondGraph = AudioGraph { El.cycle(El.const(key: "freq", value: 880.0)) * 0.5 }
        try renderer.render(secondGraph)

        var foundNonZero = false
        for _ in 0 ..< 4 {
            let samples = processBlock(numSamples: 512)
            let maxAmp = samples.map { Swift.abs($0) }.max() ?? 0
            if maxAmp > 0.1 {
                foundNonZero = true
                XCTAssertLessThanOrEqual(maxAmp, 1.0)
                break
            }
        }
        XCTAssertTrue(foundNonZero, "audio should still play after a second render reusing the keyed const node")
    }
```

This is a smoke-level check (still produces valid, non-silent audio after a second render reusing a keyed node) -- it does not itself prove "no node recreation happened"; that's what Step 1's `InstructionEncoderReconciliationTests` already prove at the instruction level.

- [ ] **Step 6: Run all reconciliation-related tests to verify they pass**

Run: `swift test --filter InstructionEncoderReconciliationTests`
Expected: PASS (5 tests).

Run: `swift test --filter GraphRendererProcessTests`
Expected: PASS (all existing tests plus the new one, 9 total).

Run: `swift test --filter NodeHasherTests` and `swift test --filter ReconciliationCacheTests`
Expected: still PASS (confirms Task 3's changes didn't regress Tasks 1-2).

- [ ] **Step 7: Commit**

```bash
git add Sources/ElementaryAudio/Bridge/InstructionEncoder.swift Sources/ElementaryAudio/Bridge/GraphRenderer.swift Tests/ElementaryAudioTests/InstructionEncoderReconciliationTests.swift Tests/ElementaryAudioTests/GraphRendererProcessTests.swift
git commit -m "feat: make InstructionEncoder hash-aware, wire GraphRenderer's persistent cache"
```

---

### Task 4: Sync the cache with native `gc()`

**Files:**
- Modify: `Sources/cxxElementaryAudio/ElemRuntime.h`
- Modify: `Sources/ElementaryAudio/Bridge/GraphRenderer.swift` (`gc()` method)
- Modify: `Sources/ElementaryAudio/Core/VFSLoader.swift` (`pruneUnreferencedResources()`)
- Modify: `Tests/ElementaryAudioTests/GraphRendererProcessTests.swift` (add one smoke test)
- Modify: `CLAUDE.md` (test count)

**Interfaces:**
- Consumes: `ReconciliationCache.evict<S: Sequence>(nodeIds: S) where S.Element == Int32` (Task 2).
- Produces: `ElemRuntime.gc() -> std::vector<int32_t>` (was `-> void`) -- this is a breaking signature change; both of its two call sites (`GraphRenderer.gc()`, `VFSLoader.pruneUnreferencedResources()`) are fixed in this same task.

- [ ] **Step 1: Write the failing test**

Add this test to `Tests/ElementaryAudioTests/GraphRendererProcessTests.swift`:

```swift
    func testGcAfterRenderDoesNotCrash() throws {
        try renderer.render(AudioGraph { El.cycle(440.0) })
        _ = processBlock(numSamples: 512)
        renderer.gc()
    }
```

This alone won't fail today (the old `gc()` already runs fine) -- the point of writing it first is that it's the test that must still pass once `gc()`'s return type changes underneath it. Proceed to the implementation step; re-run this specific test in Step 3 to confirm the refactor didn't break it.

- [ ] **Step 2: Change `ElemRuntime::gc()` to return pruned node IDs**

In `Sources/cxxElementaryAudio/ElemRuntime.h`, find:

```cpp
    // Explicit garbage collection (v4: replaces implicit deleteNode)
    void gc() {
        if (runtime) {
            runtime->gc();
        }
    }
```

Change to:

```cpp
    // Explicit garbage collection (v4: replaces implicit deleteNode).
    // Returns the node IDs the native runtime actually pruned, so Swift-side
    // caches (GraphRenderer's reconciliation node map) can evict matching
    // entries and stay in sync with what the runtime has destroyed.
    std::vector<int32_t> gc() {
        if (!runtime) return {};

        auto pruned = runtime->gc();
        return std::vector<int32_t>(pruned.begin(), pruned.end());
    }
```

(`<vector>` is already `#include`d at the top of this file.)

- [ ] **Step 3: Fix both call sites (same commit -- see File Structure note)**

In `Sources/ElementaryAudio/Bridge/GraphRenderer.swift`, find:

```swift
    public func gc() {
        ElemRuntime.getInstance().gc()
    }
```

Change to:

```swift
    public func gc() {
        let prunedNodeIds = ElemRuntime.getInstance().gc()
        reconciliationCache.evict(nodeIds: prunedNodeIds)
    }
```

(If the imported `std::vector<int32_t>` doesn't satisfy `ReconciliationCache.evict`'s `S.Element == Int32` constraint directly due to a toolchain interop quirk, convert explicitly first: `reconciliationCache.evict(nodeIds: Array(prunedNodeIds))`.)

In `Sources/ElementaryAudio/Core/VFSLoader.swift`, find:

```swift
    public static func pruneUnreferencedResources() {
        ElemRuntime.getInstance().gc()
    }
```

Change to:

```swift
    public static func pruneUnreferencedResources() {
        _ = ElemRuntime.getInstance().gc()
    }
```

(Needed because `gc()` no longer returns `Void` -- an unused non-`Void` result triggers a compiler warning otherwise. This call site has no reconciliation cache to update; it only exists to trigger native-side pruning of unreferenced VFS resources.)

- [ ] **Step 4: Run tests to verify everything passes**

Run: `swift test --filter GraphRendererProcessTests`
Expected: PASS (all tests from Task 3 plus this task's new `testGcAfterRenderDoesNotCrash`, 10 total).

Run: `swift build`
Expected: builds cleanly, no warnings about unused `gc()` results.

- [ ] **Step 5: Run the full suite and update the CLAUDE.md test count**

Run: `swift test 2>&1 | tail -20`
Expected: PASS, with a summary line reporting the total test count.

Open `CLAUDE.md` and find:

```
swift test          # Run all 23 tests (ComparisonNodeTests + GraphRendererProcessTests)
```

Replace `23` with the number `swift test` actually reported, and update the parenthetical to list every test class that now exists (`ComparisonNodeTests`, `SequencerNodeTests`, `GraphRendererProcessTests`, `NodeHasherTests`, `ReconciliationCacheTests`, `InstructionEncoderReconciliationTests`).

- [ ] **Step 6: Commit**

```bash
git add Sources/cxxElementaryAudio/ElemRuntime.h Sources/ElementaryAudio/Bridge/GraphRenderer.swift Sources/ElementaryAudio/Core/VFSLoader.swift Tests/ElementaryAudioTests/GraphRendererProcessTests.swift CLAUDE.md
git commit -m "feat: sync ReconciliationCache with native gc(), update test count docs"
```

---

## Known limitation (not fixed by this plan)

If code calls the pre-existing `GraphRenderer.setProperty(nodeId:key:value:)` directly (bypassing `render()` entirely -- this method is untouched by this plan) to change a node's property, and later a `render()` call encodes a node whose hash matches that node, the cache's stored property snapshot will be stale relative to the value actually sent natively via the direct call, potentially causing a missed diff. This plan doesn't change or deprecate that direct method (it's a separate, pre-existing feature); fixing this interaction is out of scope here and would only matter if both mechanisms are used on the same node.
