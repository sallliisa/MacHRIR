# Phase 1 Fix Plan

Goal: make termination handling safe and reliable, treat crash recovery as best-effort with startup restoration, and remove remaining AppKit UI leftovers from the SwiftUI migration.

## Termination & recovery
- Replace raw `signal(...)` handlers with `DispatchSourceSignal` on the main queue.
- Route SIGTERM/SIGINT/SIGQUIT into a single shutdown method that stops audio and restores the output device.
- Keep startup recovery as the primary guarantee: if default output is BlackHole and the engine is not running, restore the last saved physical device + volume.
- Add a small guard to prevent double-restore when both termination paths fire.
- Note limitations: SIGKILL and hard crashes cannot run cleanup; startup recovery is the fallback.

## State management and settings
- Make the `MenuBarViewModel.shared` lifetime explicit (e.g., inject via `.environmentObject` or create in a clearly documented init path) rather than relying on an unused `@StateObject`.
- SettingsManager: avoid per-instance cache divergence by using a single shared instance or inject one source of truth. A new instance has its own cache and debounce timer, which can lead to stale reads or lost saves if multiple instances are created.
- SettingsManager: add explicit migration for legacy schema instead of resetting to defaults on decode failure. Right now any decode failure wipes settings, which is risky during schema evolution.
- PermissionManager: always emit a permission-status notification, even when status is already determined, to keep UI in sync. Otherwise observers only hear about the first prompt result.
- LaunchAtLoginManager: handle register/unregister errors by syncing `isEnabled` back to actual status and log via Logger. Right now `print` logs and the UI can show the wrong toggle state after a failure.
- SettingsView: reduce duplicated device-selection/output-filtering logic by centralizing in the view model to avoid drift between menu bar and settings behavior.
- SettingsView: shared singletons should be `@ObservedObject`/`@EnvironmentObject` instead of `@StateObject` so ownership is clearer and not duplicated.
- SettingsView: remove unused state like `showNoDeviceAlert` if it’s no longer needed to avoid confusion.

## AppKit UI leftovers to remove

1) `NSAlert` in menu bar flow
   - Current: `MenuBarViewModel.selectAggregateDevice` uses `NSAlert` to show validation errors.
   - Issue: AppKit UI in a SwiftUI flow; harder to test and inconsistent with the menu bar UI.
   - Fix: move validation feedback into SwiftUI using `.alert` on `AirwaveMenuView`, with a published error state in the view model.

2) `SettingsWindowController` with `NSWindow` + `NSHostingView`
   - Current: settings window is created via AppKit and hosts `SettingsView`.
   - Issue: leftover AppKit UI, not SwiftUI-native; harder to manage scene lifecycle.
   - Fix: replace with a SwiftUI `WindowGroup`/`Settings` scene or a custom SwiftUI window presenter, and inject required environment objects.

## Core audio pipeline findings
- HRIR processing drops tail frames when `frameCount` is not a multiple of `processingBlockSize` (512). `processAudio` only processes full blocks, leaving the remainder silent. This can create periodic glitches depending on buffer size. Add a remainder path (partial block handling or zero-pad into a temp block). `Airwave/HRIRManager.swift`
- `AudioGraphManager`’s render callback always zeros all output channels and only writes when `selectedOutputChannelRange` is set. If that range is nil (e.g., no output selected, or future code path forgets to set it), output becomes silent. Consider a safe default to channels 0–1 or explicit error handling. `Airwave/AudioGraphManager.swift`
- `AudioGraphManager` allocates per-channel float buffers in `inputChannelBufferPtrs`, but later overwrites those pointers with `inputAudioBuffersPtr` in the render callback. The original allocated buffers become unused, adding memory overhead and making ownership confusing. Either use the allocated float buffers or remove them and keep a single pointer array. `Airwave/AudioGraphManager.swift`
- `Resampler.resampleHighQuality` uses `vDSP_vgenp` with a control vector but includes uncertainty about index semantics (comment notes possible 1‑based indexing). If the indices are off by one, resampling will be shifted or distorted. Confirm expected index base for `vDSP_vgenp` and adjust (or switch to `vDSP_vlint` with explicit control). `Airwave/Resampler.swift`
- `HRIRManager` caches renderer state with a static struct inside `processAudio` (not actually thread‑local). This is fine for a single audio thread but can become a data race if called concurrently (e.g., multiple audio units or offline render). Consider a `ThreadLocal` wrapper or document single‑thread assumption. `Airwave/HRIRManager.swift`
- `HRIRManager` clears `activePreset` twice in a couple of places, which looks like a leftover and suggests inconsistent state handling. Clean up duplicated assignments and centralize reset. `Airwave/HRIRManager.swift`
