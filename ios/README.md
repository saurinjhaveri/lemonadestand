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

- `OpenRouterAPIKey` — free DeepSeek R1 brain (get one at https://openrouter.ai/keys). Recommended.
- `GeminiAPIKey` — free Gemini brain + photo vision (https://aistudio.google.com/apikey).
- `OpenAIAPIKey` — optional, paid: Realtime voice + the ChatGPT brain.
- `GooglePlacesAPIKey` — optional: landmark grounding by GPS (clear it to be 100% free).

## Modes & brains

- **Lite mode** (default): Apple on-device speech-to-text + text-to-speech (free)
  + a text/vision brain. Cheap or free, turn-based.
- **Realtime mode**: OpenAI speech-to-speech (premium, pricier).
- **Brain** (Lite voice + "Look at this"): **DeepSeek R1** (free, strong
  reasoning, via OpenRouter — text-only, so photos auto-route to Gemini),
  **Gemini** (free, best vision), or **ChatGPT** ($). Toggle on the start screen.
  The generic `OpenAICompatibleBackend` also works with Groq / GitHub Models /
  Cerebras — just change base URL + model in `Config.swift`.

A live **cost meter** (Realtime token usage → estimated $) shows in the status
card; edit the rates in `Models/Usage.swift`. OpenAI exposes no balance API, so
check openai.com for your true remaining credit.

> Important: `Secrets.plist` is bundled as a resource, so after creating or
> editing it you must re-run `xcodegen generate` (so it's added to the project),
> then **Clean Build Folder** in Xcode before running.

> For anything beyond personal testing, move these keys behind a backend so they
> don't ship in the app (see plan §3).

## Activating the real Meta glasses camera

The real integration is already written in `Glasses/MetaDATGlassesProvider.swift`,
guarded by `#if canImport(MWDATCore)`. It's a no-op stub until the SDK is present,
then activates automatically. When your DAT preview access comes through:

1. **Add the SPM package**: in Xcode, File → Add Package Dependencies →
   `https://github.com/facebook/meta-wearables-dat-ios`; add products
   `MWDATCore`, `MWDATCamera`, `MWDATMockDevice`. (Or uncomment the
   `packages:`/`dependencies:` block in `project.yml` and re-run `xcodegen generate`.)
2. **Set your Meta App ID**: in `project.yml`, replace `MWDAT.MetaAppID`
   (`YOUR_META_APP_ID`) with the ID from your Meta developer app registration.
   The URL scheme `tourguide` is already wired (`CFBundleURLTypes` + `onOpenURL`).
3. **Set your Apple `DEVELOPMENT_TEAM`** in `project.yml` and run on a real iPhone
   with the glasses paired to the Meta AI app.
4. First launch will prompt the **Meta app linking** (registration) flow, then
   ask for **camera permission** on the glasses.

That's it — `AppModel.makeGlassesProvider()` picks the real provider once the SDK
imports; on the Simulator it uses MockDeviceKit so the same code path is testable.
If a symbol name differs in your SDK version, the compiler points right at it.

> Audio (mic/speaker) needs no SDK — the glasses are a standard Bluetooth headset,
> routed by `AudioSessionManager`.

## Memory (second brain)

Persistent, layered memory behind a `MemoryStore` protocol:
- **Local now** (`LocalMemoryStore`): on-device JSON in Documents — offline, free.
  Records every turn (place, GPS, Q&A) + a preferences profile; recall (recent +
  nearby + profile) is injected into each prompt.
- **Obsidian journal** (`ObsidianExporter`): mirrors entries to
  `Documents/TourGuideVault/<date>.md` with `[[place]]` backlinks and `#tags`.
  File sharing is enabled, so open the folder in the Files app / point Obsidian at it.
- **Later**: SwiftData and/or Supabase (Postgres + pgvector) adopt the same
  protocol for cross-device sync + semantic recall.

Brains also **auto-fall back** (Gemini↔ChatGPT) on failure such as 429 quota.

## Status

- **Phase 1 (talking guide):** done — Realtime + Lite voice through the glasses.
- **Phase 2 (vision "Look at this"):** done — photo + GPS + Places → Gemini/ChatGPT.
- **Real glasses camera:** code complete, behind `canImport(MWDATCore)`; activate
  with the steps above when DAT access lands.
