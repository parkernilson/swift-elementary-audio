# Example App Uses the Graph Renderer — Design

## Context

Neither the `Example/` Tuist iOS app nor the `swift-elementary-audio` macOS demo
exercises Elementary Audio's actual differentiating feature: the declarative
Swift DSL (`El.*`, `AudioGraphBuilder`) rendered through `GraphRenderer` into
the C++ `elem::Runtime`. Both instead drive `CustomNode`/`CustomNodeWrapper`
directly from an `AVAudioSourceNode` callback, bypassing the graph/runtime
pipeline entirely.

The one thing in the repo that *does* exercise the real pipeline correctly is
`Tests/ElementaryAudioTests/GraphRendererProcessTests.swift` (DSL → `AudioGraph`
→ `GraphRenderer.render()` → `ElemRuntime.process()`), plus the currently
unbuildable `ElementaryPlayground`'s `PlaygroundAudioEngine`.

Separately, `Sources/ElementaryAudio/Core/AudioEngine.swift` is a public
`actor` clearly intended as the top-level entry point for consumers (its doc
comments describe it as "a modern Swift API for real-time audio processing
using the Elementary Audio runtime" and show `AudioEngine`/`render`/`start`
usage examples), but it is an unfinished stub: `render(graph:)` only stores
the graph, and its render callback writes silence. It never touches
`GraphRenderer` or `ElemRuntime`.

## Goal

Make the `Example/` Tuist iOS app play a simple sine oscillator through
`AudioEngine`, with `AudioEngine` actually wired to the real
`GraphRenderer`/`ElemRuntime` pipeline — so the Example app becomes a genuine,
working demonstration of the DSL + graph renderer, using the library's own
intended public entry point rather than a lower-level building block.

## Prerequisite

This spec depends on
`2026-08-03-graph-reconciliation-engine-design.md`. Without it,
`El.const(key:value:)` is inert (confirmed by reading
`Sources/cxxElementaryAudio/ElementaryAudio/runtime/elem/Runtime.h` — the
native runtime keys nodes strictly by numeric `NodeId`, with no `"key"`
string handling anywhere), so a naive rebuild-and-`render()`-again approach
would hard-swap the oscillator node on every change. With reconciliation in
place, the same approach becomes efficient and glitch-free automatically.

## Reference material

Read these before implementing, alongside the reconciliation spec's own
reference list — this task is about using `AudioEngine` the way the library
actually intends it to be used:

- Making Sound 101 (Overview): https://www.elementary.audio/docs/guides/Making_Sound
- Sample Accurate Rendering: https://www.elementary.audio/docs/guides/Sample_Accurate_Rendering
- Native Integrations: https://www.elementary.audio/docs/guides/Native_Integrations
- Understanding Keys: https://www.elementary.audio/docs/guides/Understanding_Keys

The real Elementary source at `../elementary` is the authority for anything
the docs don't answer precisely — see the reconciliation spec for specific
file pointers into it.

## Non-goals (explicitly deferred)

- **`createRef`**: Elementary's real API separates two update mechanisms —
  *keys* (diff-based reconciliation across `render()` calls, implemented in
  the JS-side `Renderer`) and *refs* (`createRef`, a direct scoped setter that
  bypasses rendering entirely). Neither exists in this Swift port today, and
  building `createRef` is a separate piece of work. This task does not add it.
- **`AudioEngine.setProperty(nodeId:...)`**: rejected as a design — it would
  expose the raw `NodeID`-based plumbing a `createRef` should be built on top
  of, as if it were the intended ergonomic API. Not added.
- **`AudioEngine.events()`**: stays a stub. No analysis nodes (`meter`,
  `scope`, `snapshot`) are used by this simple example.
- **`AudioEngine.reset()`/gc lifecycle beyond what the reconciliation spec
  already wires up**: untouched here.
- **Restoring `ElementaryPlayground`**: separate, larger decision (local path
  dependency vs. remote package resolution) — not part of this task.
- **Parameter smoothing/ramping**: reconciliation (see Prerequisite) makes a
  value change an in-place update on the *same* native node — no phase reset,
  no node-recreate glitch. It does not add ramping/smoothing of the value
  itself; an instantaneous jump from 440 to 441 is still instantaneous. That's
  a separate DSP concern, out of scope here.

## Architecture

```
Example app: SimpleAudioEngine (ContentView.swift)
    → ElementaryAudio.AudioEngine (actor)   ← fixed by this change
        → GraphRenderer                       ← already correct, untouched
            → ElemRuntime (C++ singleton)
```

## Part 1 — Fix `Sources/ElementaryAudio/Core/AudioEngine.swift`

- Add `private let renderer = GraphRenderer()`.
- In `setupAudioEngine()` (called from `init`), call
  `renderer.initialize(sampleRate: sampleRate, blockSize: blockSize)` before
  constructing the `AVAudioSourceNode`.
- `render(graph:)`: replace the "store for reference" stub with
  `try renderer.render(graph)`, then `self.currentGraph = graph`. Catch
  `GraphRenderer.RenderError` and rethrow as the existing (currently unused)
  `AudioEngineError.renderFailed(error.description)` case.
- Render callback inside `setupAudioEngine()`: replace the silence-writing
  loop with a call to `renderer.process(outputData:outputChannels:numSamples:)`,
  building the output pointer array from the `AudioBufferList` the same way
  `PlaygroundAudioEngine`'s callback does.
  - **Concurrency note**: `AudioEngine` is an `actor`. The render callback
    runs on the real-time audio thread and must never hop through actor
    isolation (that would mean `Task`-based dispatch inside an audio
    callback, which is not real-time-safe and also won't compile without
    `await`). Capture the plain `renderer` local (a `GraphRenderer`, declared
    `@unchecked Sendable`) directly in the closure — never `self`.
- `events()`, `reset()` semantics: unchanged (still stubs, see Non-goals).

## Part 2 — `Example/Sources/ContentView.swift`

- `SimpleAudioEngine` (currently `@MainActor class: ObservableObject` wrapping
  `CustomNodeWrapper` + a raw `AVAudioEngine`) is reworked to hold an
  `ElementaryAudio.AudioEngine?` instead.
- Because `AudioEngine`'s API is `async throws` and `SimpleAudioEngine`'s
  entry points (`init`, `play()`, `stop()`, `updateFrequency()`) are called
  synchronously from SwiftUI, each wraps its call in `Task { ... }` —
  standard bridging for an actor-backed view model.
- Setup (in a `Task` from `init`):
  ```swift
  engine = try await AudioEngine(sampleRate: 44100, blockSize: 512)
  try await engine?.render { El.cycle(El.const(key: "frequency", value: frequency)) * 0.3 }
  ```
- `updateFrequency()`:
  ```swift
  func updateFrequency() {
      Task {
          try? await engine?.render {
              El.cycle(El.const(key: "frequency", value: frequency)) * 0.3
          }
      }
  }
  ```
  Full rebuild of the `AudioGraph` and a fresh `render()` call on every
  change — no `NodeID`, no `setProperty`, no ref, at this call site. This is
  the pattern Elementary's own docs describe as the base case ("audio graphs
  as pure functions of application state — rebuild the graph and let
  Elementary reconcile"), and it is now genuinely efficient because of the
  Prerequisite: the reconciliation engine recognizes the `"frequency"`-keyed
  const node across renders and emits a single `setProperty`, reusing the
  same native node (and its running phase) rather than recreating it.
  Without that prerequisite, this same code would silently degrade to a full
  node swap on every call — the keyed const only pays off once reconciliation
  exists.
- `play()` → `Task { try? await engine?.start() }`;
  `stop()` → `Task { await engine?.stop() }`.
- Remove the waveform `Picker`, its backing `@Published var waveform`, and
  `SimpleAudioEngine.updateWaveform()` from `ContentView` — this example is
  scoped to a single sine oscillator with a frequency slider and play/stop,
  matching "a very simple setup." The frequency slider itself (range
  `100...1000`, default `440`) is unchanged.
- Drop `import cxxElementaryAudio` and `CustomNodeWrapper` usage from this
  file entirely — the app becomes a pure `ElementaryAudio` (Swift DSL)
  consumer with no direct C++ interop.

## Data flow

Slider drag → `updateFrequency()` → new
`AudioGraph { El.cycle(El.const(key: "frequency", value: frequency)) * 0.3 }`
→ `AudioEngine.render(graph:)` → `GraphRenderer.render()` (gc → hash-aware
encode, hitting the `"frequency"` key on every call after the first →
`applyInstructions` with a single `setProperty` → `activateRootsAndCommit`)
→ next audio block picks up the updated value on the same running node.

## Error handling

`AudioEngine.init`, `render(graph:)`, and `start()` all throw. The Example
app wraps each call site in `do/catch` inside its `Task { ... }` blocks,
logging failures via `print` — matching this file's existing minimal
error-handling style. No new error-handling machinery is introduced.

## Known limitation

Reconciliation (Prerequisite) removes the phase-reset/node-recreate glitch —
the oscillator's underlying native node is reused across renders, not
rebuilt. It does not add value smoothing: each `render()` still applies an
instantaneous jump to the frequency value, so very rapid slider dragging may
still sound stepped rather than perfectly continuous. That's a parameter-
smoothing concern, explicitly out of scope (see Non-goals).

## Testing

- New `Tests/ElementaryAudioTests/AudioEngineTests.swift`: a smoke test that
  constructs an `AudioEngine`, calls `render()` with two different graphs in
  sequence (exercising the exact repeated-re-render path this design relies
  on), and calls `start()`/`stop()` — asserting no throw/crash. It should
  also assert, using a keyed const across two `render()` calls, that this
  reuses the same underlying node rather than recreating it — the same
  property the reconciliation spec's own tests check at the `GraphRenderer`
  level, verified here one layer up through `AudioEngine`. Sample-level
  correctness of the DSL → graph → render path is already covered by
  `GraphRendererProcessTests`, and `AudioEngine.render` now just delegates to
  the same `GraphRenderer.render`, so that coverage is not duplicated.
- `Example/` app: verified by building via Tuist + `xcodebuild`, the same way
  `e53ca60` ("fix: build the Tuist Example app") was verified. This
  environment cannot play audio through speakers, so audible correctness
  cannot be verified here and will be stated plainly rather than claimed.

## Branch

All work happens on a new branch, `make-example-app-use-graph-renderer`,
created from `main`.
