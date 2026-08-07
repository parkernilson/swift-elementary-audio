# Example App Menu + "Changing Configs" Reconciliation Demo — Design

## Context

The `Example/` Tuist iOS app's `@main` entry currently points at an
uncommitted, one-off `ReconciliationVerificationView` (defined inline in
`ElementaryAudioExampleApp.swift`) — a minimal harness that drives
`GraphRenderer` directly with a single fixed `AudioGraph { El.cycle(440.0) *
0.3 }`, built to manually verify the reconciliation engine
(`2026-08-03-graph-reconciliation-engine-design.md`) actually works.

Separately, `Example/Sources/ContentView.swift` holds the app's original demo
(`SimpleAudioEngine` + `CustomNodeWrapper`, driving the raw C++ bridge
directly, bypassing the DSL/`GraphRenderer` entirely) — orphaned since
`@main` no longer references it.

Neither is wired into any kind of picker, and the verification harness only
ever renders one graph — it can't yet demonstrate the reconciliation engine's
actual payoff (in-place updates vs. full rebuilds) by ear.

## Goal

1. Turn the verification harness into a permanent, real example — "Changing
   Configs" — that cycles through 4 `AudioGraph` configurations on a button
   press, exercising the reconciliation engine's core cases audibly: a keyed
   value change (in-place `setProperty`, no pop), a structurally different
   node (full rebuild), and a switch back to the original shape.
2. Give the app a simple menu so it can hold more than one example going
   forward, with both the new "Changing Configs" example and the pre-existing
   raw `CustomNode` demo as entries.

## Non-goals

- **Shared/global audio engine abstraction.** Only one example
  (`ChangingConfigsView`) actually renders through `GraphRenderer` today;
  introducing a shared engine now would be premature. Each example keeps its
  own engine object, scoped to its own file — deferred until there are enough
  examples for the duplication to actually hurt.
- **Reworking `ContentView`/`SimpleAudioEngine` to use `AudioEngine`/DSL.**
  That is `2026-08-03-example-app-graph-renderer-design.md`'s job, still
  unstarted. This task only gives the existing raw-`CustomNode` demo a home
  in the menu, unchanged internally.
- **On-screen reconciliation diagnostics** (instruction counts, hash hit/miss
  indicators). Responsiveness is judged by ear for this demo; no new
  introspection API is added to `GraphRenderer`/`InstructionEncoder`.

## Design

### File layout (`Example/Sources/`)

- `ElementaryAudioExampleApp.swift` — trimmed to just the `@main App` struct,
  `WindowGroup { ExampleMenuView() }`. `ToneEngine` and the view move out.
- `ExampleMenuView.swift` (new) — the menu:
  ```swift
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
  Two literal `NavigationLink`s — no data-driven list abstraction; not
  justified for two items.
- `ChangingConfigsView.swift` (new) — `ToneEngine` (unchanged
  `AVAudioEngine`/`GraphRenderer` plumbing) plus the renamed/extended view,
  detailed below.
- `ContentView.swift` — untouched internally. Gains a menu entry only.

### `ChangingConfigsView.swift`

`ToneEngine` gains:
- `let configurations: [(label: String, build: () -> AudioGraph)]`, in cycle
  order (wraps 3→0):
  0. `("El.cycle(El.const(key: \"frequency\", value: 440)) * 0.3", { AudioGraph { El.cycle(El.const(key: "frequency", value: 440.0)) * 0.3 } })` — initial
  1. `("El.cycle(El.const(key: \"frequency\", value: 660)) * 0.3  — keyed value change", ...)` — same keyed node, value only → in-place `setProperty`, no rebuild, phase preserved
  2. `("El.blepsquare(440.0) * 0.3  — structurally different", ...)` — different oscillator type → full rebuild; old sine nodes orphaned, collected on the next `gc()`
  3. `("El.cycle(El.const(key: \"frequency\", value: 440)) * 0.3  — back to config 1's shape", ...)` — identical graph to step 0 → switch-back case
- `@Published private(set) var currentConfigIndex = 0`.
- `init()` renders `configurations[0].build()`, as today.
- `func advanceConfiguration()`: `next = (currentConfigIndex + 1) %
  configurations.count`; `try renderer.render(configurations[next].build())`;
  on success, update `currentConfigIndex`; on failure, `print` the error and
  leave the index unchanged (matches this file's existing minimal
  error-handling style — no new machinery).

`ReconciliationVerificationView` is renamed `ChangingConfigsView`, gets
`.navigationTitle("Changing Configs")`, its static label `Text` becomes
`Text(toneEngine.configurations[toneEngine.currentConfigIndex].label)`, and a
`Button("Next Configuration") { toneEngine.advanceConfiguration() }` is added
below it.

## Data flow

Button tap → `advanceConfiguration()` → build next `AudioGraph` →
`GraphRenderer.render()` (gc → hash-aware encode → `applyInstructions` →
commit) → next audio block picks up the change on the RT thread. Same
non-RT-thread call pattern the existing `init()` already uses — no `Task`,
no actor hop, since `ToneEngine` isn't actor-isolated and the button tap
already runs on the main thread.

## Error handling

Unchanged from the existing harness: `renderer.render()` failures are caught
and `print`ed; nothing else changes behavior. No new error type or handling
path.

## Testing

Manual/audible only, same as the harness this replaces — this is a
verification demo, not library code. The reconciliation engine itself is
already covered by the unit test suite listed in `CLAUDE.md`
(`NodeHasherTests`, `ReconciliationCacheTests`,
`InstructionEncoderReconciliationTests`, `GraphRendererProcessTests`).
Verification here is: `swift build` succeeds, `tuist generate` + build the
Example app in Xcode succeeds, and (if run on a real device/simulator with
audio) each button press is glitch-free per the expected reconciliation
behavior at each step.

**Build step:** adding `ExampleMenuView.swift` and `ChangingConfigsView.swift`
requires `tuist generate` before the Example app will build in Xcode — Tuist
freezes the file list at generation time (see `CLAUDE.md`).

## Branch

Same branch as the rest of this work: `make-example-app-use-graph-renderer`.
