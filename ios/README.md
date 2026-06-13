# Tour Guide — iOS app (Phase 1 scaffold)

Phase 1 of the [Smart Glasses Tour Guide plan](../SMART_GLASSES_TOUR_GUIDE_PLAN.md):
foundations for the **talking guide**.

What this scaffold gives you:
- **Glasses session** abstraction with photo capture (Meta Wearables Device
  Access Toolkit integration point + a mock provider so it runs in the simulator).
- **GPS** via CoreLocation.
- **Bluetooth audio** routing so the glasses act as the mic/speaker.
- **OpenAI Realtime** voice client (speech-to-speech over WebSocket) for the
  hands-free conversation.
- A minimal SwiftUI control surface to connect, push-to-talk, and "look at this".

This is a **skeleton**: it compiles and runs in the simulator against the
`MockGlassesProvider`, but you must supply your own API keys and swap in the
real Meta SDK (see "Integration points" below) to use it with real glasses.

---

## Layout

```
TourGuide/
  App/        App entry, SwiftUI view, coordinating AppModel
  Glasses/    GlassesProvider protocol, Mock + Meta DAT implementations
  Location/   CoreLocation manager
  Audio/      Bluetooth audio session routing
  Voice/      OpenAI Realtime WebSocket client
  Brain/      Google Places + tour-guide orchestration (vision lands in Phase 2)
  Models/     Shared types
  Config/     Build config + secrets template
  Resources/  Info.plist (permissions + background audio)
```

## Generate the Xcode project

This uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) so the project file
is reproducible:

```bash
brew install xcodegen
cd ios
# 1. Create your secrets file and add your keys (see below)
cp TourGuide/Config/Secrets.example.plist TourGuide/Config/Secrets.plist
# 2. Edit Secrets.plist, then generate AFTER the file exists so it gets bundled
xcodegen generate
open TourGuide.xcodeproj
```

Then set your Apple **Team** in Signing, pick your device, and run.
Out of the box it uses `MockGlassesProvider`, so it runs in the simulator.

## Configuration / secrets

Keys live in `Secrets.plist` (git-ignored), read directly by `Config.swift`.
Copy `Secrets.example.plist` → `Secrets.plist` and fill in:

- `OpenAIAPIKey` — required for Realtime voice.
- `GooglePlacesAPIKey` — for landmark grounding (used more in Phase 2).

> Important: `Secrets.plist` is bundled as a resource, so after creating or
> editing it you must re-run `xcodegen generate` (so it's added to the project),
> then **Clean Build Folder** in Xcode before running.

> For anything beyond personal testing, move these keys behind a backend so they
> don't ship in the app (see plan §3).

> For anything beyond personal testing, move these keys behind a backend so they
> don't ship in the app (see plan §3).

## Integration points (swap mock → real)

1. **Meta Wearables Device Access Toolkit**
   - Apply for the developer preview, register the app, get GitHub-gated SDK access.
   - Add the SPM package in `project.yml` (placeholder is there, commented).
   - Implement the `TODO(meta-dat)` markers in
     `Glasses/MetaDATGlassesProvider.swift` against the real SDK symbols.
   - Switch `AppModel` to use `MetaDATGlassesProvider` instead of `MockGlassesProvider`.

2. **Glasses audio** — confirmed via standard Bluetooth: pair the glasses, and
   `AudioSessionManager` routes mic/speaker through them. No SDK needed.

3. **OpenAI Realtime model name** — `RealtimeClient` defaults to `gpt-realtime`;
   update if you use a different model.

## Phase 1 milestone

Connect → push-to-talk → ask "what's worth seeing near me?" → hear a grounded
spoken answer through the glasses. Photo capture is wired and verified (logs the
captured frame); full **vision identification** is Phase 2.
