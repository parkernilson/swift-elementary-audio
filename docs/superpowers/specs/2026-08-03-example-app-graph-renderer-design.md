# Complete the Graph Renderer's Entry Point — Design

## Context

This spec originally set out to make the `Example/` app exercise Elementary's
declarative Swift DSL by finishing `Sources/ElementaryAudio/Core/AudioEngine.swift`
— a public `actor` stub whose `render(graph:)` only stored the graph and whose
render callback wrote silence — as the library's intended top-level entry
point.

Since that version was written, two things changed:

1. `2026-08-03-graph-reconciliation-engine-design.md` landed: `GraphRenderer`
   now does hash-aware reconciliation, so keyed nodes update in place across
   `render()` calls instead of being recreated.
2. `2026-08-06-example-app-menu-changing-configs-design.md` landed:
   `Example/Sources/ChangingConfigsView.swift`'s `ToneEngine` already
   constructs its own `AVAudioEngine`, calls `GraphRenderer.initialize()` and
   `.render()` directly, and drives an `AVAudioSourceNode` from
   `GraphRenderer.process()` — correctly exercising the real DSL → `AudioGraph`
   → `GraphRenderer` → `ElemRuntime` pipeline. The example app's job (per that
   spec's own goal) is done. `AudioEngine` remains untouched and unused by any
   of it.

So the original premise — "the example app doesn't exercise the real
pipeline" — is no longer true. What's left is narrower: `AudioEngine.swift`
itself is still an unfinished, unused stub, and its own doc comments still
promise a "modern Swift API for real-time audio processing" including
`render`/`start`/`events()`. Before finishing it, it's worth checking whether
an `actor` that owns a private `AVAudioEngine` is actually the shape Elementary
intends for this boundary — or whether it's solving a problem the JS packages
don't have.

## Investigation: what does the JS side actually abstract here?

Reading `../elementary/js/packages/web-renderer/index.ts` and
`../elementary/js/packages/offline-renderer/index.ts`:

- `WebRenderer.initialize(audioContext, workletOptions)` takes an
  **already-constructed, caller-owned `AudioContext`** and returns an
  `AudioWorkletNode` for the caller to `.connect()` themselves (see the
  package's own README: `node.connect(ctx.destination)`). `WebRenderer` never
  owns the `AudioContext`, never calls `.resume()`/`.suspend()`/`.close()` on
  it, and is agnostic to how the caller routes the resulting node.
- `WebRenderer`/`OfflineRenderer` themselves wrap Elementary's engine-agnostic
  `Renderer` (`@elemaudio/core`, reconciliation + instruction batching) plus
  whatever bridge is needed to reach the actual DSP runtime — a Web Audio
  worklet + WASM module for `WebRenderer`, a native WASM module for
  `OfflineRenderer`. Both bridges genuinely cross a process/thread/module
  boundary (`postMessage` to a worklet; loading/calling into a WASM module),
  which is why every one of their methods (`render`, `initialize`, `gc`, …) is
  `async`.

Mapping this onto the Swift port:

- **`AVAudioEngine` is the Swift equivalent of `AudioContext`** — a platform
  primitive the *host application* owns and manages the lifecycle of, not
  something Elementary abstracts away.
- **`GraphRenderer` (already exists, already correct) is the Swift equivalent
  of `WebRenderer`/`OfflineRenderer`** — except Swift/C++ interop means
  `GraphRenderer` calls straight into the in-process `ElemRuntime` C++
  singleton with **no boundary to cross**. There's no worklet, no WASM module,
  no message-passing. So `GraphRenderer` already fully plays the
  `WebRenderer` role, and does it *more* simply than JS needs to, because it
  doesn't need `async` for something that was never actually asynchronous here
  — confirmed by `ChangingConfigsView.ToneEngine` and
  `ElementaryPlayground`'s `PlaygroundAudioEngine`, both of which already call
  `renderer.render(...)` synchronously with no actor hop, today.
- **`AudioEngine` (the actor stub) doesn't correspond to anything on this
  list.** It fully owns and hides an `AVAudioEngine` internally — backwards
  from `WebRenderer.initialize(audioContext)`, which takes the caller's
  context and hands back a node. Its `actor`/`async throws` surface exists to
  manage a self-owned `AVAudioEngine`'s lifecycle safely across threads — a
  problem that only exists because of the ownership design itself, not
  because `GraphRenderer.render()`/`.process()` need it (they're already
  synchronous and thread-safe as documented on `GraphRenderer`).

Conclusion: the missing piece is not "finish `AudioEngine`" — it's the one
thing `WebRenderer.initialize(audioContext)` does that `GraphRenderer` doesn't
yet: attach itself into a caller-owned engine and hand back the node to route.
`AudioEngine` itself should be deleted, not completed.

## Goal

Give `GraphRenderer` the one piece of glue `WebRenderer.initialize(audioContext)`
provides in JS — wiring its output into a caller-owned native audio
engine — and remove the stub that was standing in for it, so the library's
actual entry point (`GraphRenderer`) matches how Elementary's own JS packages
divide responsibility between the engine-agnostic renderer and the
caller-owned platform audio context.

## Non-goals (explicitly deferred)

- **Finishing `AudioEngine.swift` as designed.** Deleted instead (see Part 1).
  Its `actor`/`async throws` surface and self-owned `AVAudioEngine` don't
  correspond to anything the JS APIs need Swift to replicate.
- **`createRef`.** Elementary's real API separates *keys* (diff-based
  reconciliation, already ported) from *refs* (`createRef` — a direct scoped
  setter that bypasses rendering entirely, see
  `../elementary/js/packages/core/index.ts`'s `Renderer.createRef`). Marked
  with a `TODO` doc comment on `GraphRenderer` (Part 3) pointing at a future
  design spec — not implemented here. Building it well requires deciding
  whether Swift's typed node constructors need a generic
  `kind`/`properties`/`children` escape hatch to match `createRef`'s full
  generality (JS's version is generic over any node kind), which is its own
  design question, not a mechanical port.
- **`events()` / analysis-node event streaming.** Also marked with a `TODO`
  doc comment (Part 3). `ElemRuntime` has no Swift-facing bridge for
  `elem::Runtime::processQueuedEvents` at all today — this is new C++
  bridging work, a different kind of task than the pure-Swift attachment glue
  this spec adds, and needs its own design spec.
- **A new standalone example view.** Earlier drafts of this spec planned a
  third menu entry to showcase the completed `AudioEngine` actor plus
  `createRef`. With `AudioEngine` deleted and `createRef` deferred, there's
  nothing left for such a view to demonstrate beyond what
  `ChangingConfigsView` already shows (keyed-const reconciliation through a
  renderer attached to a real `AVAudioEngine`). Not added.
- **`ContentView`/"Raw CustomNode Demo"**: untouched, per
  `2026-08-06-example-app-menu-changing-configs-design.md`'s existing
  protection of this file as a deliberately raw, unabstracted example.
- **`ElementaryPlayground`/`PlaygroundAudioEngine`**: untouched — restoring it
  is a separate, larger decision already deferred by the original version of
  this spec (local path dependency vs. remote package resolution).
- **Parameter smoothing/ramping, `reset()`/gc lifecycle beyond what
  reconciliation already wires up**: unchanged, same reasoning as the
  original spec.

## Reference material

- `../elementary/js/packages/web-renderer/index.ts` and its `README.md` —
  `WebRenderer.initialize(audioContext, workletOptions) -> AudioWorkletNode`,
  the method this spec's `attachToEngine` mirrors.
- `../elementary/js/packages/offline-renderer/index.ts` — same
  caller-owns-the-context division, for the non-realtime case.
- `../elementary/js/packages/core/index.ts` — `Renderer` class; confirms
  `WebRenderer`/`OfflineRenderer` are thin bridges *around* the same
  engine-agnostic reconciliation `GraphRenderer` already ports.
- Native Integrations: https://www.elementary.audio/docs/guides/Native_Integrations
- `Sources/ElementaryAudio/Bridge/GraphRenderer.swift` — existing
  `initialize`, `render`, `process` methods this spec adds one method
  alongside.
- `Example/Sources/ChangingConfigsView.swift` — the existing hand-rolled
  format/`AVAudioSourceNode`/attach/connect sequence this spec extracts into
  `GraphRenderer.attachToEngine(...)`.

## Architecture

Before (never actually wired up):

```
Example app → ElementaryAudio.AudioEngine (actor, stub)
                  → [nothing: render(graph:) stores the graph;
                     the render callback writes silence]
```

After:

```
Example app (owns AVAudioEngine, exactly as a JS app owns its AudioContext)
    → GraphRenderer.attachToEngine(_:sampleRate:blockSize:channels:)
          → GraphRenderer.initialize(...)                    (existing)
          → builds an AVAudioSourceNode whose callback calls
            GraphRenderer.process(...)                        (existing, tested)
          → engine.attach(node); engine.connect(node, to: engine.mainMixerNode, ...)
          → returns the node
    → app calls engine.start()/.stop() itself (mirrors ctx.resume()/.close() in JS)
    → app calls renderer.render(...) directly — same call ChangingConfigsView
      already makes today
```

## Part 1 — Delete `Sources/ElementaryAudio/Core/AudioEngine.swift`

Confirmed by search: no file in `Sources/`, `Tests/`, or `Example/` references
the `AudioEngine` type (only unrelated types whose names happen to contain
"AudioEngine" — `AVAudioEngine`, `SimpleAudioEngine`, `PlaygroundAudioEngine`,
`ToneEngine` — exist). This is a clean deletion: remove the file and its
`State`, `AudioEngineError`, `events()` stub, and `static func start(...)`
convenience along with it.

## Part 2 — Add `GraphRenderer.attachToEngine(...)`

New file: `Sources/ElementaryAudio/Bridge/GraphRenderer+AVAudioEngine.swift`.

```swift
import AVFoundation

extension GraphRenderer {
    /// Wires this renderer's output into a caller-owned `AVAudioEngine`,
    /// mirroring `WebRenderer.initialize(audioContext) -> AudioWorkletNode`:
    /// the caller keeps ownership of the engine and is responsible for
    /// starting/stopping it and routing the returned node.
    @discardableResult
    public func attachToEngine(
        _ engine: AVAudioEngine,
        sampleRate: Double = 44100,
        blockSize: Int = 512,
        channels: AVAudioChannelCount = 2
    ) -> AVAudioSourceNode {
        initialize(sampleRate: sampleRate, blockSize: blockSize)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let node = AVAudioSourceNode(format: format) { [self] _, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let outputPtrs: [UnsafeMutablePointer<Float>?] = ablPointer.map {
                $0.mData?.assumingMemoryBound(to: Float.self)
            }
            self.process(outputData: outputPtrs, outputChannels: outputPtrs.count, numSamples: Int(frameCount))
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        return node
    }
}
```

- No concurrency workaround is needed here (unlike the original `AudioEngine`
  design): `GraphRenderer` is declared `@unchecked Sendable`, not
  actor-isolated, so the render callback captures `self` directly, exactly
  like `PlaygroundAudioEngine`'s callback already captures its `renderer`
  local.
- Uses the existing, already-tested array-based `process(outputData:
  outputChannels: numSamples:)` overload — generalizes over channel count
  rather than hardcoding mono the way `ChangingConfigsView`'s inline version
  currently does.
- `attachToEngine` never calls `engine.start()`/`.stop()` — the caller does,
  exactly as a JS caller calls `ctx.resume()`/`audioContext.close()` around
  `WebRenderer.initialize()`.

## Part 3 — Deferred-work markers on `GraphRenderer`

Doc-comment `TODO`s, not stub methods — a method that exists but does nothing
is a worse trap for callers than a comment:

```swift
// TODO(createRef): Port Elementary's `Renderer.createRef(kind, props, children)`
// (see `../elementary/js/packages/core/index.ts`) — a scoped property setter
// that bypasses full graph reconciliation for a single node. Needs its own
// design spec: a `ReconciliationCache` lookup keyed by `NodeID`, a property
// diff against the cached snapshot, and a decision about whether Swift's
// typed node constructors need a generic kind/properties/children escape
// hatch to match createRef's full generality (every real JS usage is on a
// `const` node, but the JS API itself is generic over any node kind).

// TODO(events): Bridge `elem::Runtime::processQueuedEvents`
// (`Sources/cxxElementaryAudio/ElementaryAudio/runtime/elem/Runtime.h`) to a
// Swift-facing event stream, mirroring `WebRenderer`'s `EventEmitter` /
// `OfflineRenderer.process()`'s inline event draining. `ElemRuntime` has no
// Swift-facing event API today — this is new C++ bridging work and needs its
// own design spec.
```

## Part 4 — Refactor `Example/Sources/ChangingConfigsView.swift`

`ToneEngine.init()` currently hand-builds the `AVAudioFormat`,
`AVAudioSourceNode`, `engine.attach`, and `engine.connect` sequence inline
(~15 lines) before rendering the first configuration. Replace that block with
a single call to the new helper:

```swift
init() {
    sourceNode = renderer.attachToEngine(engine, sampleRate: 44100, blockSize: 512, channels: 1)
    do {
        try renderer.render(configurations[currentConfigIndex].build())
    } catch {
        print("[ToneEngine] render failed: \(error)")
    }
}
```

This both simplifies the one existing example and exercises
`attachToEngine` as a real caller — there is no other production call site to
prove it against otherwise. `start()`/`stop()`/`advanceConfiguration()` and
everything else in `ToneEngine` are unchanged.

## Data flow

Button tap → `advanceConfiguration()` → build next `AudioGraph` →
`GraphRenderer.render()` (gc → hash-aware encode → `applyInstructions` →
commit) → next audio block, produced via the `AVAudioSourceNode` callback
`attachToEngine` installed, picks up the change on the RT thread. Identical to
the data flow the menu spec already documented — this spec only changes how
the source node gets created and attached, not what happens after.

## Error handling

`GraphRenderer.render()` still throws `RenderError`; `ChangingConfigsView`
still catches and `print`s, unchanged. `attachToEngine` itself does not throw:
its only failure point is `AVAudioFormat(standardFormatWithSampleRate:
channels:)`'s force-unwrap, which cannot fail for the sample rates/channel
counts this library targets — matching the force-unwrap already used at every
existing `AVAudioFormat` construction site in this codebase
(`ChangingConfigsView`, `PlaygroundAudioEngine`, `ContentView`).

## Testing

New `Tests/ElementaryAudioTests/GraphRendererAVAudioEngineTests.swift`. Note
an `AVAudioSourceNode`'s render block is a private closure with no public
hook to invoke directly in a test — these tests check `attachToEngine`'s
observable effects (attachment/connection state, and runtime state via the
existing tested `process()` path) rather than driving audio through the node
itself:

- `attachToEngine` does not throw/crash, and afterward `engine.attachedNodes`
  contains the returned node (confirms `engine.attach` ran) and
  `engine.outputConnectionPoints(for: node, outputBus: 0)` includes
  `engine.mainMixerNode` (confirms `engine.connect` ran).
- After `attachToEngine(engine, ...)` followed by `renderer.render(graph)`,
  calling `renderer.process(...)` directly (the existing, already-tested
  array overload — same technique `GraphRendererProcessTests` uses) produces
  non-silent output. This is the real regression to guard against:
  `attachToEngine`'s internal `initialize()` call must not leave the runtime
  in a state where the normal `render()`/`process()` path stops working.
- Calling `attachToEngine` a second time on the same `GraphRenderer` (e.g. a
  reconfigure) does not crash.

`Example/` app: verified by `tuist generate` + building via `xcodebuild`, the
same bar prior specs used. This environment cannot play audio through
speakers, so audible correctness stays unverified here and will be stated
plainly rather than claimed.

## Branch

The branch used by the specs this one supersedes work from
(`make-example-app-use-graph-renderer`) has already been merged to `main`.
This work happens on a new branch, `graph-renderer-attach-to-engine`, created
from `main`.
