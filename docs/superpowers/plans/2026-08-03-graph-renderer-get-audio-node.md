# Graph Renderer Entry Point (`getAudioNode`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the unfinished `AudioEngine` actor stub and replace it with `GraphRenderer.getAudioNode(...)`, a method that builds a ready-to-use `AVAudioSourceNode` wired to the renderer's existing `render`/`process` pipeline — mirroring how `WebRenderer.initialize(audioContext)` works in Elementary's JS packages, but without taking or touching an `AVAudioEngine` at all, since attach/connect/start/stop are the caller's decisions, not the library's.

**Architecture:** `Sources/ElementaryAudio/Core/AudioEngine.swift` is deleted outright (nothing references it). A new file, `Sources/ElementaryAudio/Bridge/GraphRenderer+AudioNode.swift`, adds `getAudioNode(sampleRate:blockSize:channels:) -> AVAudioSourceNode` as an extension on the existing `GraphRenderer` class — it calls the already-existing `initialize(sampleRate:blockSize:)` and builds an `AVAudioSourceNode` whose render callback calls the already-existing `process(outputData:outputChannels:numSamples:)` array overload. Two `TODO` doc comments are added directly to `GraphRenderer.swift` flagging `createRef` and `events()` as deferred, future-spec work. `Example/Sources/ChangingConfigsView.swift`'s `ToneEngine.init()` is refactored to call the new method instead of hand-building the same `AVAudioFormat`/`AVAudioSourceNode` sequence inline. `README.md`'s Quick Start and downstream code samples, which currently show the now-deleted `AudioEngine` as the primary usage pattern, are updated to show the real API.

**Tech Stack:** Swift 6 (C++ interop mode via `.interoperabilityMode(.Cxx)`), AVFoundation (`AVAudioSourceNode`, `AVAudioFormat`, `AVAudioEngine`), XCTest, SwiftUI (Example app), Tuist (Example app project generation).

## Global Constraints

- `GraphRenderer.getAudioNode` must never call `engine.attach`/`.connect`/`.start`/`.stop`, and must not take an `AVAudioEngine` parameter — every attach/routing/lifecycle decision belongs to the caller (spec Goal, Part 2).
- Deferred features (`createRef`, `events()`) get `TODO` doc comments on `GraphRenderer`, never stub methods (spec Part 3 — "a method that exists but does nothing is a worse trap for callers than a comment").
- No new error-handling machinery: `getAudioNode` force-unwraps `AVAudioFormat(standardFormatWithSampleRate:channels:)`, matching every existing `AVAudioFormat` construction site in this codebase (spec Error handling).
- `Example/Sources/ContentView.swift` ("Raw CustomNode Demo") stays internally untouched — protected by `2026-08-06-example-app-menu-changing-configs-design.md`.
- `ElementaryPlayground`/`PlaygroundAudioEngine` stays untouched — restoring it is a separate, already-deferred decision.
- Branch: `graph-renderer-get-audio-node`, created from `main`. **This branch already exists and is checked out** — do not create it again.

## Environment notes

- `swift build`/`swift test` in this environment require `--disable-sandbox` (SwiftPM's own manifest-compilation sandboxing fails otherwise with `sandbox-exec: sandbox_apply: Operation not permitted`). Baseline confirmed working during planning: `swift build --disable-sandbox` succeeds, `swift test --disable-sandbox` passes all 67 existing tests.
- `tuist` is installed via a versioned Homebrew formula, not on `PATH` by default:
  ```bash
  export PATH="/opt/homebrew/opt/tuist@4.203.3/bin:$PATH"
  ```
  Baseline confirmed working during planning:
  ```bash
  cd Example
  tuist generate --no-open
  xcodebuild -workspace ElementaryAudioExample.xcworkspace -scheme ElementaryAudioExample -destination 'generic/platform=iOS Simulator' build
  ```
  produces `** BUILD SUCCEEDED **` before any change in this plan.
- This environment cannot play audio through speakers or drive the iOS Simulator's UI — audible/interactive correctness for `ChangingConfigsView` stays unverified here, per the design spec's own Testing section. Compile-time correctness (the app builds) is fully verifiable and is this plan's bar for the Example app.

---

## File Structure

**New files:**
- `Sources/ElementaryAudio/Bridge/GraphRenderer+AudioNode.swift` — `GraphRenderer.getAudioNode(...)`.
- `Tests/ElementaryAudioTests/GraphRendererAudioNodeTests.swift` — tests for the above.

**Deleted files:**
- `Sources/ElementaryAudio/Core/AudioEngine.swift` — unfinished, unused stub.

**Modified files:**
- `Sources/ElementaryAudio/Bridge/GraphRenderer.swift` — two `TODO` doc comments added (no behavior change).
- `Example/Sources/ChangingConfigsView.swift` — `ToneEngine.init()` refactored to use `getAudioNode`.
- `README.md` — Quick Start, downstream code samples, and one Features bullet updated to match the real API (not present in the design spec's own text, but a direct, necessary consequence of deleting `AudioEngine`: the README's primary usage example currently shows the exact type being deleted).

**Unchanged:**
- `Example/Sources/ContentView.swift`, `Sources/ElementaryPlayground/PlaygroundApp.swift` — protected, per Global Constraints.

---

### Task 1: Delete the `AudioEngine` stub

**Files:**
- Delete: `Sources/ElementaryAudio/Core/AudioEngine.swift`

**Interfaces:**
- Produces: nothing — this task only removes code. Confirms the codebase compiles and tests pass with the type gone, establishing the starting point Task 2 builds on.

- [ ] **Step 1: Confirm nothing outside the file references `AudioEngine`**

```bash
grep -rn '\bAudioEngine\b' Sources Tests Example --include="*.swift"
```

Expected: the only matches are inside `Sources/ElementaryAudio/Core/AudioEngine.swift` itself (its own declarations: `public actor AudioEngine`, `extension AudioEngine`, the doc-comment usage examples, etc.). If any match appears in a *different* file, stop and investigate before deleting — this plan assumes zero external references, confirmed during design.

- [ ] **Step 2: Delete the file**

```bash
rm Sources/ElementaryAudio/Core/AudioEngine.swift
```

- [ ] **Step 3: Verify the package still builds and tests still pass**

```bash
swift build --disable-sandbox
swift test --disable-sandbox
```

Expected: build succeeds with no new errors; all 67 pre-existing tests still pass (none reference `AudioEngine`).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: delete unfinished AudioEngine actor stub

AudioEngine never actually wired render()/start() to GraphRenderer/ElemRuntime,
and nothing in the codebase used it. Its actor/self-owned-AVAudioEngine design
doesn't correspond to how Elementary's own JS packages (WebRenderer,
OfflineRenderer) divide responsibility between the engine-agnostic renderer
and the caller-owned platform audio context -- see
docs/superpowers/specs/2026-08-03-example-app-graph-renderer-design.md.
EOF
)"
```

---

### Task 2: Add `GraphRenderer.getAudioNode(...)`

**Files:**
- Create: `Sources/ElementaryAudio/Bridge/GraphRenderer+AudioNode.swift`
- Test: `Tests/ElementaryAudioTests/GraphRendererAudioNodeTests.swift`

**Interfaces:**
- Consumes: `GraphRenderer` (`Sources/ElementaryAudio/Bridge/GraphRenderer.swift`) — specifically the existing `func initialize(sampleRate: Double, blockSize: Int)` and `func process(outputData: [UnsafeMutablePointer<Float>?], outputChannels: Int, numSamples: Int)`. Both already exist; this task does not modify `GraphRenderer.swift` itself (that's Task 3).
- Produces: `extension GraphRenderer { public func getAudioNode(sampleRate: Double = 44100, blockSize: Int = 512, channels: AVAudioChannelCount = 2) -> AVAudioSourceNode }`. Task 4 (`ChangingConfigsView`) and Task 5 (`README`) both call this exact signature.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ElementaryAudioTests/GraphRendererAudioNodeTests.swift`:

```swift
import AVFoundation
import cxxElementaryAudio
@testable import ElementaryAudio
import XCTest

final class GraphRendererAudioNodeTests: XCTestCase {
    private var renderer: GraphRenderer!

    override func setUp() {
        super.setUp()
        renderer = GraphRenderer()
    }

    override func tearDown() {
        renderer.reset()
        renderer = nil
        super.tearDown()
    }

    func testGetAudioNodeReturnsNodeWithRequestedFormat() {
        let node = renderer.getAudioNode(sampleRate: 48000, blockSize: 256, channels: 1)
        let format = node.outputFormat(forBus: 0)
        XCTAssertEqual(format.sampleRate, 48000)
        XCTAssertEqual(format.channelCount, 1)
    }

    func testRenderAndProcessStillWorkAfterGetAudioNode() throws {
        _ = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 1)

        let graph = AudioGraph { El.cycle(440.0) }
        try renderer.render(graph)

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
        XCTAssertTrue(foundNonZero, "audio should still play via process() after getAudioNode's internal initialize() call")
    }

    func testCallingGetAudioNodeTwiceDoesNotCrash() {
        _ = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 2)
        _ = renderer.getAudioNode(sampleRate: 48000, blockSize: 256, channels: 1)
    }

    // MARK: - Helpers

    private func processBlock(numSamples: Int) -> [Float] {
        var outputBuffer = [Float](repeating: 0, count: numSamples)
        outputBuffer.withUnsafeMutableBufferPointer { bufPtr in
            var channelPtr: UnsafeMutablePointer<Float>? = bufPtr.baseAddress
            withUnsafeMutablePointer(to: &channelPtr) { channelPtrPtr in
                renderer.process(
                    outputData: channelPtrPtr,
                    outputChannels: 1,
                    numSamples: numSamples
                )
            }
        }
        return outputBuffer
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

```bash
swift test --disable-sandbox --filter GraphRendererAudioNodeTests 2>&1 | tail -20
```

Expected: a compile error along the lines of `value of type 'GraphRenderer' has no member 'getAudioNode'`. This confirms the test is actually exercising code that doesn't exist yet.

- [ ] **Step 3: Create `Sources/ElementaryAudio/Bridge/GraphRenderer+AudioNode.swift`**

```swift
import AVFoundation

/// Builds an `AVAudioSourceNode` wired to this renderer's own
/// `render`/`process` pipeline -- the Swift-side counterpart to
/// `WebRenderer.initialize(audioContext) -> AudioWorkletNode`. Unlike that JS
/// method, this does not take or touch an `AVAudioEngine`: the caller decides
/// whether/where to `attach`/`connect` the returned node, and owns
/// starting/stopping whatever engine it ends up in.
extension GraphRenderer {
    public func getAudioNode(
        sampleRate: Double = 44100,
        blockSize: Int = 512,
        channels: AVAudioChannelCount = 2
    ) -> AVAudioSourceNode {
        initialize(sampleRate: sampleRate, blockSize: blockSize)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        return AVAudioSourceNode(format: format) { [self] _, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let outputPtrs: [UnsafeMutablePointer<Float>?] = ablPointer.map {
                $0.mData?.assumingMemoryBound(to: Float.self)
            }
            self.process(outputData: outputPtrs, outputChannels: outputPtrs.count, numSamples: Int(frameCount))
            return noErr
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --disable-sandbox --filter GraphRendererAudioNodeTests
```

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Run the full suite to confirm no regressions**

```bash
swift test --disable-sandbox
```

Expected: all tests pass (67 pre-existing + 3 new = 70).

- [ ] **Step 6: Commit**

```bash
git add Sources/ElementaryAudio/Bridge/GraphRenderer+AudioNode.swift Tests/ElementaryAudioTests/GraphRendererAudioNodeTests.swift
git commit -m "feat: add GraphRenderer.getAudioNode, the AudioEngine replacement"
```

---

### Task 3: Add deferred-work `TODO` comments to `GraphRenderer.swift`

**Files:**
- Modify: `Sources/ElementaryAudio/Bridge/GraphRenderer.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing callable — comments only, no behavior change. Included as its own task because it's a distinct, independently-reviewable piece of the spec (Part 3) with no test cycle of its own.

- [ ] **Step 1: Insert the TODO block**

In `Sources/ElementaryAudio/Bridge/GraphRenderer.swift`, find this existing text near the end of the file (the blank line right after the `GraphRenderer` class's closing brace, right before the `// MARK: - Convenience Extensions` section that adds the `render(@AudioGraphBuilder ...)` convenience):

```swift
}

// MARK: - Convenience Extensions
```

Replace it with:

```swift
}

// MARK: - Deferred Work

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

// MARK: - Convenience Extensions
```

- [ ] **Step 2: Verify the package still builds**

```bash
swift build --disable-sandbox
```

Expected: succeeds with no new errors (comments only).

- [ ] **Step 3: Commit**

```bash
git add Sources/ElementaryAudio/Bridge/GraphRenderer.swift
git commit -m "docs: flag createRef and events() as deferred follow-up specs on GraphRenderer"
```

---

### Task 4: Refactor `ChangingConfigsView.ToneEngine` to use `getAudioNode`

**Files:**
- Modify: `Example/Sources/ChangingConfigsView.swift`

**Interfaces:**
- Consumes: `GraphRenderer.getAudioNode(sampleRate:blockSize:channels:) -> AVAudioSourceNode` (Task 2).
- Produces: nothing new — `ToneEngine`'s public surface (`start()`, `stop()`, `advanceConfiguration()`, `configurations`, `currentConfigIndex`) is unchanged; only `init()`'s implementation changes.

- [ ] **Step 1: Replace `ToneEngine.init()`**

In `Example/Sources/ChangingConfigsView.swift`, find:

```swift
    init() {
        renderer.initialize(sampleRate: 44100, blockSize: 512)
        do {
            try renderer.render(configurations[currentConfigIndex].build())
        } catch {
            print("[ToneEngine] render failed: \(error)")
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let renderer = self.renderer
        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first,
                  let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            var channelPtr: UnsafeMutablePointer<Float>? = ptr
            withUnsafeMutablePointer(to: &channelPtr) { channelPtrPtr in
                renderer.process(outputData: channelPtrPtr, outputChannels: 1, numSamples: Int(frameCount))
            }
            return noErr
        }
        self.sourceNode = sourceNode
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }
```

Replace it with:

```swift
    init() {
        let node = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 1)
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: node.outputFormat(forBus: 0))

        do {
            try renderer.render(configurations[currentConfigIndex].build())
        } catch {
            print("[ToneEngine] render failed: \(error)")
        }
    }
```

Everything else in the file (`configurations`, `@Published private(set) var currentConfigIndex`, `private let engine`/`renderer`/`sourceNode` properties, `start()`, `stop()`, `advanceConfiguration()`, `ChangingConfigsView`'s `body`) stays exactly as-is.

- [ ] **Step 2: Regenerate the Tuist project and build**

No files were added/removed/renamed under `Example/Sources/`, so `tuist generate` is not strictly required by the rule in `CLAUDE.md` — but run it anyway to be certain, since it's cheap and this is the first real check that the refactored code compiles inside the Tuist-generated project:

```bash
cd Example
export PATH="/opt/homebrew/opt/tuist@4.203.3/bin:$PATH"
tuist generate --no-open
xcodebuild -workspace ElementaryAudioExample.xcworkspace -scheme ElementaryAudioExample -destination 'generic/platform=iOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`. If it fails with an error about `getAudioNode` not being found, confirm Task 2 was committed and its file exists at `Sources/ElementaryAudio/Bridge/GraphRenderer+AudioNode.swift`.

- [ ] **Step 3: Commit**

```bash
cd /Users/parkernilson/Code/swift-elementary-audio
git add Example/Sources/ChangingConfigsView.swift
git commit -m "refactor: use GraphRenderer.getAudioNode in ChangingConfigsView, replacing hand-rolled node setup"
```

---

### Task 5: Update `README.md` to match the real API

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `GraphRenderer.getAudioNode(...)` (Task 2), `GraphRenderer.render(...)` (pre-existing).
- Produces: nothing callable — documentation only.

**Context:** Not called out by name in the design spec, but a direct consequence of Task 1: the README's Quick Start section is currently the single most prominent usage example in the whole repo, and it constructs the exact `AudioEngine` type this plan deletes. Leaving it unchanged would mean the project's front-door documentation shows broken example code for a type that no longer exists.

- [ ] **Step 1: Replace the Quick Start code block**

In `README.md`, find:

```swift
import ElementaryAudio

// Create an audio engine
let engine = try await AudioEngine()

// Render a simple sine wave
try await engine.render {
    El.cycle(440) * 0.5  // 440Hz sine at 50% volume
}

// Start playback
try await engine.start()
```

Replace it with:

```swift
import ElementaryAudio
import AVFoundation

// Create your own AVAudioEngine and attach Elementary's renderer to it
let avEngine = AVAudioEngine()
let renderer = GraphRenderer()
let node = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 2)
avEngine.attach(node)
avEngine.connect(node, to: avEngine.mainMixerNode, format: node.outputFormat(forBus: 0))

// Render a simple sine wave
try renderer.render {
    El.cycle(440) * 0.5  // 440Hz sine at 50% volume
}

// Start playback
try avEngine.start()
```

- [ ] **Step 2: Update the five downstream code samples**

Five more blocks each currently read `try await engine.render { ... }`. Change
each to `try renderer.render { ... }` (drop `await`, rename `engine` to
`renderer`) — the closure bodies themselves are untouched:

**FM Synthesis:**
```swift
try renderer.render {
    let modulator = El.cycle(220) * 200
    El.cycle(440 + modulator) * 0.3
}
```

**Filtered Sawtooth with LFO:**
```swift
try renderer.render {
    let lfo = El.cycle(0.5) * 500 + 1000
    El.blepsaw(110)
        .lowpass(frequency: lfo, q: 4)
        .gain(0.4)
}
```

**Stereo Output:**
```swift
try renderer.render {
    El.cycle(440) * 0.3  // Left channel
    El.cycle(550) * 0.3  // Right channel
}
```

**Delay Effect:**
```swift
try renderer.render {
    let dry = El.cycle(440) * 0.3
    let wet = El.delay(44100, El.const(22050), dry) * 0.5
    dry + wet
}
```

**Step Sequencer:**
```swift
try renderer.render {
    let trigger = El.phasor(4)  // 4Hz trigger
    let notes: [Double] = [261.63, 293.66, 329.63, 349.23]  // C D E F
    let freq = El.seq(trigger, notes)
    El.cycle(freq) * 0.3
}
```

- [ ] **Step 3: Update the inaccurate Features bullet**

Find, in the `## Features` list:

```markdown
- **Async/Await** - Modern Swift concurrency for engine lifecycle
```

Replace it with:

```markdown
- **Bring Your Own Engine** - Attach directly to your own `AVAudioEngine`; no owned lifecycle to manage
```

- [ ] **Step 4: Verify no remaining references to the deleted API**

```bash
grep -n 'AudioEngine()\|await engine' README.md
```

Expected: no output (the only remaining `AVAudioEngine`/`avEngine` references are the new, correct ones from Step 1).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: update README to GraphRenderer.getAudioNode, replacing deleted AudioEngine examples"
```

---

### Task 6: Final full-suite verification

**Files:** none (verification only).

**Interfaces:** none.

- [ ] **Step 1: Run the full Swift test suite**

```bash
swift build --disable-sandbox
swift test --disable-sandbox
```

Expected: build succeeds; `Executed 70 tests, with 0 failures` (67 pre-existing + 3 from Task 2).

- [ ] **Step 2: Rebuild the Example app one more time**

```bash
cd Example
export PATH="/opt/homebrew/opt/tuist@4.203.3/bin:$PATH"
tuist generate --no-open
xcodebuild -workspace ElementaryAudioExample.xcworkspace -scheme ElementaryAudioExample -destination 'generic/platform=iOS Simulator' build
cd ..
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm a clean git state**

```bash
git status --short
git log --oneline main..HEAD
```

Expected: `git status --short` prints nothing (everything committed). `git log` shows exactly the 5 commits from Tasks 1–5, in order.

- [ ] **Step 4: State what remains manually unverified**

No commit needed for this step — it's a documentation-of-limits check, not code. Confirm out loud / in the final report: this environment cannot play audio through speakers or drive the iOS Simulator UI, so `ChangingConfigsView`'s actual audio output (does config-cycling still sound correct through the refactored `init()`) is unverified here, matching the design spec's own stated limitation. Everything else — compilation, the reconciliation-engine behavior itself (already covered by `GraphRendererProcessTests`, `InstructionEncoderReconciliationTests`, etc., none of which changed), and the new `getAudioNode` unit tests — is verified.

---

## Manual verification (not automatable here)

On a device/simulator with audio, confirm:

1. `Example/` app → "Changing Configs" → still plays a 440Hz sine tone on entry, and "Next Configuration" still cycles through all 4 configs audibly correctly (identical behavior to before this plan — only the node-construction code changed, not the reconciliation/render logic).
2. `Example/` app → "Raw CustomNode Demo" → unaffected, still works exactly as before (this plan never touches `ContentView.swift`).
