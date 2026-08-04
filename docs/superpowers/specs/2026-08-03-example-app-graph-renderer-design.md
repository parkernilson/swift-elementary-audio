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

## Non-goals (explicitly deferred)

- **`createRef`**: Elementary's real API separates two update mechanisms —
  *keys* (diff-based reconciliation across `render()` calls, implemented in
  the JS-side `Renderer`) and *refs* (`createRef`, a direct scoped setter that
  bypasses rendering entirely). Neither exists in this Swift port today, and
  building `createRef` is a separate piece of work. This task does not add it.
- **`AudioEngine.setProperty(nodeId:...)`**: rejected as a design — it would
  expose the raw `NodeID`-based plumbing a `createRef` should be built on top
  of, as if it were the intended ergonomic API. Not added.
- **Key-based reconciliation** (`El.const(key:value:)`): confirmed inert in
  this codebase — `elem::Runtime::createNode` (`Runtime.h`) keys its internal
  `nodeTable` strictly by numeric `NodeId`; there is no `"key"` string handling
  anywhere in the C++ runtime. Key-based diffing lives entirely in Elementary's
  JS `Renderer`, which this Swift port has no equivalent of. Not used here.
- **`AudioEngine.events()`**: stays a stub. No analysis nodes (`meter`,
  `scope`, `snapshot`) are used by this simple example.
- **`AudioEngine.reset()`/gc lifecycle**: untouched.
- **Restoring `ElementaryPlayground`**: separate, larger decision (local path
  dependency vs. remote package resolution) — not part of this task.
- **Smooth/click-free parameter changes**: out of scope. See "Known
  limitation" below.

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
  try await engine?.render { El.cycle(frequency) * 0.3 }
  ```
- `updateFrequency()`:
  ```swift
  func updateFrequency() {
      Task { try? await engine?.render { El.cycle(frequency) * 0.3 } }
  }
  ```
  Full rebuild of the `AudioGraph` and a fresh `render()` call on every
  change — no `NodeID`, no `setProperty`, no ref. This is the pattern
  Elementary's own docs describe as the base case ("audio graphs as pure
  functions of application state — rebuild the graph and let Elementary
  reconcile"); it works today without any extra plumbing because
  `GraphRenderer.render()` already calls `gc()` on every invocation
  specifically to clean up the previous render's orphaned nodes.
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

Slider drag → `updateFrequency()` → new `AudioGraph { El.cycle(frequency) * 0.3 }`
→ `AudioEngine.render(graph:)` → `GraphRenderer.render()` (gc → encode →
`applyInstructions` → `activateRootsAndCommit`) → next audio block picks up
the new render sequence.

## Error handling

`AudioEngine.init`, `render(graph:)`, and `start()` all throw. The Example
app wraps each call site in `do/catch` inside its `Task { ... }` blocks,
logging failures via `print` — matching this file's existing minimal
error-handling style. No new error-handling machinery is introduced.

## Known limitation

Because there is no reconciliation (no keys, no refs) in this Swift port,
every `render()` call is a hard swap: the previous const/cycle nodes are
discarded and new ones created. Rapid slider dragging may produce audible
clicking rather than a smooth ramp. This is an accepted tradeoff for this
"very simple setup" pass — the correct long-term fix is `createRef`, which is
explicitly deferred (see Non-goals).

## Testing

- New `Tests/ElementaryAudioTests/AudioEngineTests.swift`: a smoke test that
  constructs an `AudioEngine`, calls `render()` with two different graphs in
  sequence (exercising the exact repeated-re-render path this design relies
  on), and calls `start()`/`stop()` — asserting no throw/crash. Sample-level
  correctness of the DSL → graph → render path is already covered by
  `GraphRendererProcessTests`, and `AudioEngine.render` now just delegates to
  the same `GraphRenderer.render`, so that coverage is not duplicated.
- `Example/` app: verified by building via Tuist + `xcodebuild`, the same way
  `e53ca60` ("fix: build the Tuist Example app") was verified. This
  environment cannot play audio through speakers, so audible correctness
  (including the click-per-change limitation noted above) cannot be verified
  here and will be stated plainly rather than claimed.

## Branch

All work happens on a new branch, `make-example-app-use-graph-renderer`,
created from `main`.
