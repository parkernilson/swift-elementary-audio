# Example App Menu + "Changing Configs" Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the ad-hoc reconciliation verification harness in `ElementaryAudioExampleApp.swift` into a permanent "Changing Configs" example that cycles through 4 `AudioGraph` configurations on a button press, and give the Example app a simple menu so it can host that example alongside the pre-existing raw `CustomNode` demo.

**Architecture:** Extract the existing `ToneEngine`/view pair out of the App file into their own `ChangingConfigsView.swift`, extending `ToneEngine` with an array of `(label, build)` configuration entries and an `advanceConfiguration()` method that re-renders the next one through the (already-implemented) reconciliation engine. Add a new `ExampleMenuView.swift` with two `NavigationLink`s. Trim `ElementaryAudioExampleApp.swift` down to just the `@main App` struct.

**Tech Stack:** SwiftUI, AVFoundation (`AVAudioEngine`/`AVAudioSourceNode`), `ElementaryAudio` Swift package (`GraphRenderer`, `AudioGraph`, `El.*` DSL), Tuist-generated Xcode project (no XCTest — this is a UI-only manual/audible demo).

## Global Constraints

- No shared/global audio engine abstraction — each example keeps its own engine object, scoped to its own file (per spec Non-goals; deferred until there are enough examples to justify it).
- `Example/Sources/ContentView.swift` (`ContentView`/`SimpleAudioEngine`) stays internally unchanged — it only gains an entry point from the new menu, per spec Non-goals.
- No on-screen reconciliation diagnostics (instruction counts, hash hit/miss indicators) — responsiveness is judged by ear, per spec Non-goals.
- Tuist freezes the generated Xcode project's file list at generation time — any new/removed/renamed file under `Example/Sources/` requires `tuist generate` before the app will build in Xcode (see `CLAUDE.md`).

## Environment note

This is the Tuist-based iOS app (`Example/`), not the root SPM package — there is no `swift test` coverage for it (Non-goal: manual/audible verification only, confirmed in the design spec's Testing section). "Passing" for each task in this plan means the app **builds successfully**, verified with:

```bash
cd Example
tuist generate --no-open
xcodebuild -workspace ElementaryAudioExample.xcworkspace -scheme ElementaryAudioExample -destination 'generic/platform=iOS Simulator' build
```

Look for `** BUILD SUCCEEDED **` in the output. Both commands were run and confirmed working during planning (baseline `xcodebuild` already succeeds before any change in this plan).

`tuist` may not be on `PATH` in a fresh shell — it's installed via a versioned Homebrew formula. If `tuist: command not found`, run:

```bash
export PATH="/opt/homebrew/opt/tuist@4.203.3/bin:$PATH"
```

first, then retry `tuist generate --no-open`.

---

## File Structure

**New files:**
- `Example/Sources/ChangingConfigsView.swift` — `ToneEngine` (private to this file) + `ChangingConfigsView` (the config-cycling example page).
- `Example/Sources/ExampleMenuView.swift` — the example picker menu.

**Modified files:**
- `Example/Sources/ElementaryAudioExampleApp.swift` — trimmed to just the `@main App` struct; the inline `ToneEngine`/`ReconciliationVerificationView` code currently in this file is deleted (moved to `ChangingConfigsView.swift`).

**Unchanged:**
- `Example/Sources/ContentView.swift` — referenced by the new menu, no internal edits.

---

### Task 1: Extract and extend the Changing Configs example

**Files:**
- Create: `Example/Sources/ChangingConfigsView.swift`
- Modify: `Example/Sources/ElementaryAudioExampleApp.swift` (temporarily point `@main` straight at `ChangingConfigsView()` — Task 2 swaps this to the menu)

**Interfaces:**
- Produces: `struct ChangingConfigsView: View` (internal, no access modifier — must be visible from `ExampleMenuView.swift` in Task 2), initializable as `ChangingConfigsView()` with no arguments.

- [ ] **Step 1: Create `Example/Sources/ChangingConfigsView.swift`**

```swift
import SwiftUI
import AVFoundation
import ElementaryAudio

/// Cycles through a handful of `AudioGraph` configurations on each button
/// press so the graph reconciliation engine's behavior can be heard
/// directly: a keyed value change updates the running oscillator in place
/// (no pop), while a structurally different node forces a full rebuild.
private final class ToneEngine: ObservableObject {
    let configurations: [(label: String, build: () -> AudioGraph)] = [
        (
            label: "El.cycle(El.const(key: \"frequency\", value: 440)) * 0.3",
            build: { AudioGraph { El.cycle(El.const(key: "frequency", value: 440.0)) * 0.3 } }
        ),
        (
            label: "El.cycle(El.const(key: \"frequency\", value: 660)) * 0.3  — keyed value change",
            build: { AudioGraph { El.cycle(El.const(key: "frequency", value: 660.0)) * 0.3 } }
        ),
        (
            label: "El.blepsquare(440.0) * 0.3  — structurally different",
            build: { AudioGraph { El.blepsquare(440.0) * 0.3 } }
        ),
        (
            label: "El.cycle(El.const(key: \"frequency\", value: 440)) * 0.3  — back to config 1's shape",
            build: { AudioGraph { El.cycle(El.const(key: "frequency", value: 440.0)) * 0.3 } }
        ),
    ]

    @Published private(set) var currentConfigIndex = 0

    private let engine = AVAudioEngine()
    private let renderer = GraphRenderer()
    private var sourceNode: AVAudioSourceNode?

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

    func start() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            print("[ToneEngine] failed to start: \(error)")
        }
    }

    func stop() {
        engine.stop()
    }

    func advanceConfiguration() {
        let next = (currentConfigIndex + 1) % configurations.count
        do {
            try renderer.render(configurations[next].build())
            currentConfigIndex = next
        } catch {
            print("[ToneEngine] render failed: \(error)")
        }
    }
}

struct ChangingConfigsView: View {
    @StateObject private var toneEngine = ToneEngine()

    var body: some View {
        VStack(spacing: 12) {
            Text("GraphRenderer verification")
                .font(.headline)
            Text(toneEngine.configurations[toneEngine.currentConfigIndex].label)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Next Configuration") {
                toneEngine.advanceConfiguration()
            }
            .padding(.top, 8)
        }
        .padding()
        .navigationTitle("Changing Configs")
        .onAppear { toneEngine.start() }
        .onDisappear { toneEngine.stop() }
    }
}
```

- [ ] **Step 2: Trim `Example/Sources/ElementaryAudioExampleApp.swift` to reference the extracted view**

Replace the entire file contents with:

```swift
import SwiftUI

@main
struct ElementaryAudioExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ChangingConfigsView()
        }
    }
}
```

(This is an intermediate state — Task 2 swaps `ChangingConfigsView()` for `ExampleMenuView()`.)

- [ ] **Step 3: Regenerate the Tuist project and build**

```bash
cd Example
export PATH="/opt/homebrew/opt/tuist@4.203.3/bin:$PATH"
tuist generate --no-open
xcodebuild -workspace ElementaryAudioExample.xcworkspace -scheme ElementaryAudioExample -destination 'generic/platform=iOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`. If it fails with `cannot find 'ChangingConfigsView' in scope`, re-run `tuist generate --no-open` — the file list was frozen at an earlier generation.

- [ ] **Step 4: Commit**

```bash
git add Example/Sources/ChangingConfigsView.swift Example/Sources/ElementaryAudioExampleApp.swift
git commit -m "feat: extract Changing Configs example, add config-cycling button"
```

---

### Task 2: Add the example picker menu

**Files:**
- Create: `Example/Sources/ExampleMenuView.swift`
- Modify: `Example/Sources/ElementaryAudioExampleApp.swift`

**Interfaces:**
- Consumes: `ChangingConfigsView` (Task 1, no-argument initializer), `ContentView` (pre-existing, `Example/Sources/ContentView.swift`, no-argument initializer).
- Produces: `struct ExampleMenuView: View`, initializable as `ExampleMenuView()` with no arguments.

- [ ] **Step 1: Create `Example/Sources/ExampleMenuView.swift`**

```swift
import SwiftUI

struct ExampleMenuView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Changing Configs") { ChangingConfigsView() }
                NavigationLink("Raw CustomNode Demo") { ContentView() }
            }
            .navigationTitle("Elementary Audio Examples")
        }
    }
}
```

- [ ] **Step 2: Point `@main` at the menu**

Replace `Example/Sources/ElementaryAudioExampleApp.swift`'s body with:

```swift
import SwiftUI

@main
struct ElementaryAudioExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ExampleMenuView()
        }
    }
}
```

- [ ] **Step 3: Regenerate the Tuist project and build**

```bash
cd Example
export PATH="/opt/homebrew/opt/tuist@4.203.3/bin:$PATH"
tuist generate --no-open
xcodebuild -workspace ElementaryAudioExample.xcworkspace -scheme ElementaryAudioExample -destination 'generic/platform=iOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Example/Sources/ExampleMenuView.swift Example/Sources/ElementaryAudioExampleApp.swift
git commit -m "feat: add example picker menu, list Changing Configs and Raw CustomNode Demo"
```

---

## Manual verification (not automatable here)

This environment cannot run the iOS Simulator's audio output or drive UI taps, so the following must be checked by hand on a device/simulator with audio, per the design spec's Testing section:

1. Launch the app → menu shows "Changing Configs" and "Raw CustomNode Demo".
2. Tap "Changing Configs" → hear a 440Hz sine tone; label reads config 1's text.
3. Tap "Next Configuration" three times in a row, listening for pops/clicks at each step:
   - → 660Hz sine (should be a clean pitch change, no click — in-place `setProperty`).
   - → 440Hz square wave (a full timbre change, some transient is expected here — full node rebuild).
   - → 440Hz sine again (back to config 1's shape).
4. Tap "Raw CustomNode Demo" → confirm the pre-existing slider/waveform picker/play-stop UI still works unchanged.
5. From "Changing Configs", tap back to the menu, then re-enter "Changing Configs" — confirm audio still plays (a fresh `GraphRenderer`/`ToneEngine` is constructed on each entry since it's now a `NavigationLink` destination rather than the app's root view) and the label resets to config 1.
