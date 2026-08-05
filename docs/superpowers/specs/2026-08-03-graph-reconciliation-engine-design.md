# Graph Reconciliation Engine — Design

## Reference material

Before implementing against this spec, read these Elementary Audio docs to
understand how the system is *intended* to work — this design is a direct
port of the mechanism they describe, not a reinterpretation:

- Introduction: https://www.elementary.audio/docs
- Motivation: https://www.elementary.audio/docs/motivation
- Making Sound 101 (Overview): https://www.elementary.audio/docs/guides/Making_Sound
- Virtual File System: https://www.elementary.audio/docs/guides/Virtual_File_System
- Sample Accurate Rendering: https://www.elementary.audio/docs/guides/Sample_Accurate_Rendering
- Understanding Keys: https://www.elementary.audio/docs/guides/Understanding_Keys
- Using Refs: https://www.elementary.audio/docs/guides/Using_Refs
- Native Integrations: https://www.elementary.audio/docs/guides/Native_Integrations
- Custom Native Nodes: https://www.elementary.audio/docs/guides/Custom_Native_Nodes

The real Elementary Audio source is also checked out at `../elementary`
(sibling to this repo, v4.0.1 of `@elemaudio/core`). For any question about
exactly how the JS core or native runtime behaves, read the source there
rather than guessing from docs prose:

- `../elementary/js/packages/core/src/NodeRepr.res` (+ `.bs.js`) — node
  identity/hashing
- `../elementary/js/packages/core/src/Reconciler.res` (+ `.bs.js`) — the
  mount/diff algorithm this spec ports
- `../elementary/js/packages/core/src/HashUtils.res`, `Hash.ts` — the hash
  function and prop-diff helper
- `../elementary/js/packages/core/src/index.ts` — `Renderer` class:
  `nodeMap` lifecycle, `createRef`, `prune`, instruction batching
- `../elementary/js/packages/core/__tests__/core.test.js` and
  `hashing.test.js` — concrete before/after test cases; several are ported
  directly into this spec's test plan below
- `Sources/cxxElementaryAudio/ElementaryAudio/runtime/elem/Runtime.h` (in
  *this* repo) — confirms the native runtime has **no** hashing/key logic at
  all; `createNode`/`nodeTable` key strictly by numeric `NodeId`. All
  reconciliation intelligence lives in the layer this spec adds to Swift,
  matching where it lives in the JS core — never in the native runtime.

## Problem

This Swift port has no reconciliation at all. `GraphRenderer.render(_:)` →
`InstructionEncoder.encode(_:)` unconditionally walks the *entire* given
`AudioGraph` and re-emits `createNode`/`setProperty`/`appendChild` for every
node, every single call, regardless of whether an identical or
previously-rendered node already exists. `NodeID` (`Core/NodeID.swift`) is a
bare incrementing counter assigned fresh on every `AudioNode` construction —
it has no relationship to a node's structure or value, so there is no way for
two separately-constructed but "conceptually the same" nodes (e.g. a `const`
whose value changed) to be recognized as such.

Concretely, this means:
- `El.const(key:value:)`/`KeyedConstNode` stores a `"key"` property that
  currently does nothing — nothing in Swift or in the native runtime
  (confirmed by reading `Runtime.h`) ever reads it.
- Every `render()` call is a full rebuild: previously-active nodes are
  dropped (relying on `gc()` to eventually clean them up) and entirely new
  ones created, even for a graph that's structurally identical apart from
  one leaf's value.
- `ElemRuntime.gc()` (`ElemRuntime.h:179`) discards `runtime->gc()`'s
  returned pruned-`NodeId` set entirely — there is no mechanism to keep any
  Swift-side bookkeeping in sync with what the native runtime has actually
  destroyed.

## Goal

Port Elementary's actual reconciliation algorithm (content-addressed node
hashing + a persistent cross-render node cache + diff-based instruction
emission) into the Swift DSL/Bridge layer, so that:
- A keyed leaf node whose value changes across `render()` calls produces
  exactly one `setProperty` instruction — no `createNode`/`appendChild`.
- An unchanged subtree produces zero instructions on a subsequent render.
- A structurally new/different node still gets a full create, exactly as
  today.
- The Swift-side cache stays correctly in sync with what the native runtime
  has actually destroyed via `gc()`.

This mirrors the real algorithm's scope exactly — it does **not** add
`createRef` (see Non-goals) and does **not** rename any existing Swift types
to match JS names; `GraphRenderer`, `AudioEngine`, `El.*` stay as they are.
Only the *algorithm* they implement changes.

## How the real algorithm works (ported directly — see source links above)

1. Every node's identity is a **hash** of `(nodeType, key-or-props, children
   hashes)`, computed once at construction. If a `"key"` prop is present,
   *only the key* feeds the hash — prop values are excluded entirely, so a
   value change on a keyed node does not change its hash. Without a key, the
   *entire* props are hashed, so any value change produces a new hash.
2. A **persistent map, `hash → node`**, is owned by the renderer and survives
   across every `render()` call. There is no old-tree-vs-new-tree diff —
   each `render()` does one traversal of the *new* tree, testing each node's
   hash for membership in that map.
3. **Hash hit**: no `createNode`/`appendChild` — only a props diff, emitting
   `setProperty` for keys whose value actually changed.
4. **Hash miss**: full `createNode` + every prop as `setProperty` +
   `appendChild` for each child, then inserted into the map.
5. **No delete is ever emitted by the reconciler.** Orphaned map entries just
   sit there until the native engine autonomously reports them as prunable
   via `gc()`; the renderer then removes exactly those entries from its map.
   This is why `Native_Integrations` stresses that `gc()`'s returned IDs
   "must be passed to the corresponding prune method... to ensure the
   Renderer and the Runtime remain in sync" — skipping this means the cache
   can go stale relative to what the native side actually destroyed.
6. Keys only protect the *keyed node's own* prop values. They do not help
   across children/structural changes, and there's no positional/index
   matching anywhere — it's pure content-addressed hashing.

## Non-goals

- **`createRef`**: per the source, this is pure JS-side sugar over the
  mechanism this spec builds (auto-generate a permanently-unique key, build
  a normal keyed node, return a setter that reuses the same prop-diff
  helper) — it requires no separate reconciler support. Once this spec
  lands, `createRef` becomes a small, cheap follow-up rather than a
  prerequisite. Not built here; flagged for a later pass.
- **Renaming Swift types/methods to mirror JS names** (`core`, `el`,
  `Renderer`) — out of scope; only the algorithm is ported.
- **Positional/index-based matching, list diffing, or any mechanism beyond
  hash equality** — the real algorithm doesn't have this either; not adding
  it here.

## Design

### 1. Structural hashing

Add a way to compute a content-addressed hash for any `any AudioNode`:
`hash(nodeType, key-or-sorted-properties, childHashes)`, combined via
Swift's `Hasher`. Swift's hash seed is randomized per process run, which is
fine — the cache only needs to be internally consistent within one running
app's lifetime across repeated `render()` calls, not stable across restarts
or comparable to JS's specific hash values.

`NodeProperties` (`Core/NodeProperties.swift`) needs key iteration exposed
(if not already) so properties can be sorted before hashing — dictionary
iteration order is not guaranteed, so an explicit sort is required for a
stable hash given identical content.

### 2. Persistent node cache in `GraphRenderer`

`GraphRenderer` gains a private cache surviving across `render()` calls:
- `hash → (nodeId, properties)` — the reconciliation map itself.
- `nodeId → hash` — a reverse index so a `gc()`-returned pruned `NodeId` can
  be mapped back to the cache entry to evict.

`GraphRenderer.clear()` (currently only clears `createdNodeIds`/
`currentRootIds`) is extended to also clear this cache.

### 3. Mount/diff traversal

`InstructionEncoder.encodeNode` currently unconditionally emits
`createNode`/`setProperty`(all props)/`appendChild` for every node
(depth-first, children before parent, deduped only *within* one `encode()`
call via `encodedNodes`). This becomes hash-aware: the persistent cache is
passed in (by the caller, `GraphRenderer`, which owns it) so that for each
node:
- Compute its hash.
- **Hit**: resolve the already-assigned `nodeId` from the cache; diff the
  new node's `properties` against the cached snapshot; emit `setProperty`
  only for changed keys; update the cached snapshot. No `createNode`/
  `appendChild`.
- **Miss**: allocate a fresh `NodeID()`; emit `createNode` + `setProperty`
  for every prop + `appendChild` (using already-resolved child node IDs, so
  children must still be processed before their parent, exactly as today);
  insert into the cache.

`RootNode` needs no special-casing: it already carries `channel` as a
property (`AudioGraph.swift`), so it participates in the same hash/mount
mechanism as any other node — a root whose child or channel changes gets a
new hash and a fresh create, same as today; an unchanged root becomes a
no-op on the next render.

### 4. GC-cache synchronization

- `elem::Runtime<FloatType>::gc()` (`Runtime.h:85`) returns
  `std::set<NodeId>` — the set of pruned node IDs. `ElemRuntime::gc()`
  (`ElemRuntime.h:179`) currently discards this. It needs to return the
  pruned IDs to Swift in a bridgeable form (e.g. `std::vector<int32_t>`).
- `GraphRenderer.gc()` uses the returned IDs, looks each up in the reverse
  `nodeId → hash` index, and removes the corresponding entries from both
  cache maps — mirroring `Renderer.prune()` in the JS core. Once evicted, a
  later render of that same hash is correctly treated as a miss and fully
  recreated, matching the real behavior.

## Testing

Port these cases directly from `../elementary/js/packages/core/__tests__/`
as Swift `XCTest`s against `GraphRenderer`/`InstructionEncoder`, asserting
on the emitted instruction sequence (not just audio output), since the
whole point is *which instructions* get generated:

- **Structural equality with value change** (`core.test.js`): render a
  keyed leaf, then render again with only its value changed — assert the
  second render's instructions are exactly one `setProperty` (no
  `createNode`/`appendChild` anywhere in the batch).
- **Switch and switch back**: render A, then B, then A again — assert the
  third render reuses A's original `NodeID` with no new `createNode`.
- **Distinguish by props (no key)**: render an unkeyed leaf, then render
  again with a different value — assert this *does* produce a full
  `createNode`/`setProperty`/`appendChild` (i.e. confirms keys are actually
  required for the optimization, not incidentally applied everywhere).
- **Distinguish by key**: two structurally different subtrees with
  different keys never get conflated with each other.
- **GC eviction**: after a node is dropped from the rendered graph and
  `gc()` reports it pruned, rendering a graph that would otherwise hash-hit
  that same node produces a full recreate, not a stale reuse.

## Sequencing

This is a prerequisite for `2026-08-03-example-app-graph-renderer-design.md`
— once this lands, that spec's frequency-update path (rebuild the graph with
a new keyed const value and call `render()` again) becomes efficient and
glitch-free automatically, with no `setProperty(nodeId:...)` or `createRef`
API needed at the call site.

## Branch

Same branch as the Example app work: `make-example-app-use-graph-renderer`.
