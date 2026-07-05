# Tour Guide — iOS app

A hands-free AI **tour guide** for Ray-Ban Meta glasses. Take a photo with the
glasses (or in-app), and the guide identifies what you're looking at and tells
you the story — grounded with real facts, spoken aloud.

## How glasses photos reach the app (the Camera Roll bridge)

Meta's Device Access Toolkit (DAT) can't reliably connect on iOS 26 yet (open
SDK bug), so the app uses a simpler, robust path that works **today**:

1. You press the **capture button on the glasses**.
2. The photo syncs to your iPhone **Camera Roll** via the Meta AI app.
3. The app **watches the Camera Roll** and **auto-narrates** each new photo.

Bonus: this uses the glasses' **full-resolution** photo (better than DAT's
streaming frames). You can also tap **Look at this** to pick/take a photo
manually.

## How an answer is built

Point at **anything** — landmarks, plants, products, food, menus, signs — not
just tourist sights.

`photo / question → on-device scan (QR + OCR, free) → Gemini "eyes" (if the
brain can't see) → chosen brain writes the narration → spoken`, grounded by:
- **On-device Vision** (Apple framework): QR/barcode detection + sign/label OCR — free, instant.
- **Google Places** (nearby landmark candidates by GPS) — optional.
- **Wikipedia** (verified facts → less hallucination).
- **Memory** (traveler profile + "been here before" + recent turns).

**QR codes are a fast path:** if the photo contains a QR code linking to a
website, the app fetches the page, strips it to readable text, and the brain
summarizes it aloud (prices, hours, menu highlights…). Non-URL codes (wifi,
plain text) are read out directly — no cloud call at all.

## Layout

```
TourGuide/
  App/        App entry, AppModel, SwiftUI screens (Start/Session/Settings), Theme
  Glasses/    PhotoLibraryWatcher (Camera Roll bridge) + inert DAT provider files
  Location/   CoreLocation manager
  Audio/      Audio session routing (glasses as BT headset for mic/speaker)
  Voice/      On-device speech-to-text + text-to-speech
  Brain/      Persona, reasoning/vision backends, Places + Wikipedia + orchestration
  Models/     Shared types + cost estimates
  Config/     Build config + secrets template
  Resources/  Info.plist (permissions)
```

## Generate the Xcode project

Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd ios
cp TourGuide/Config/Secrets.example.plist TourGuide/Config/Secrets.plist  # add keys
xcodegen generate
open TourGuide.xcodeproj
```

## Configuration / secrets

Keys live in `Secrets.plist` (git-ignored), read by `Config.swift`:

- `OpenRouterAPIKey` — cheap GPT-5 Nano brain (sub-cent/query; https://openrouter.ai/keys). Recommended default.
- `GeminiAPIKey` — free Gemini brain **and** photo vision (https://aistudio.google.com/apikey).
- `OpenAIAPIKey` — optional, paid: the ChatGPT (GPT-4o) brain + Natural TTS voice.
- `GooglePlacesAPIKey` — optional: landmark grounding by GPS (clear it to stay 100% free).

> `Secrets.plist` is bundled as a resource — after editing it, re-run
> `xcodegen generate` and **Clean Build Folder** before running.

## Brains

Pick on the start screen (gear ▸ Settings ▸ Brain):
- **GPT-5 Nano** (default, via OpenRouter) — cheap, fast, strong. Text-only, so
  photos go through Gemini "eyes → brain".
- **Gemini** — free, sees photos directly.
- **ChatGPT (GPT-4o)** — paid, best accuracy, sees photos directly.

Swap `openRouterModel` in `Config.swift` for any model at
https://openrouter.ai/models. The generic `OpenAICompatibleBackend` also works
with Groq / GitHub Models / Cerebras (change base URL + model). Brains
**auto-fall back** to a lighter same-provider model on failure (e.g. 429).

## Voice

On-device **speech-to-text** (push-to-talk) + **text-to-speech**:
- **Device voice** (free) — pick an Enhanced/Premium voice in Settings ▸
  Accessibility ▸ Spoken Content ▸ Voices for a less robotic sound.
- **Natural voice** (OpenAI TTS, small cost).

A live **cost meter** (per-turn + session/lifetime estimate) shows in Settings;
edit rates in `Models/Usage.swift`.

## Memory (second brain)

Behind a `MemoryStore` protocol:
- **Local** (`LocalMemoryStore`): on-device JSON — records every turn (place,
  GPS, Q&A) + a preferences profile; recall is injected into each prompt.
- **Obsidian journal** (`ObsidianExporter`): mirrors entries to
  `Documents/TourGuideVault/<date>.md` with `[[place]]` backlinks + `#tags`
  (open the folder in Files / Obsidian).

## Meta DAT (live glasses connection) — parked for now

The DAT provider (`Glasses/MetaDATGlassesProvider.swift`) is kept in the repo but
**inert** (the SDK package is not added). DAT's iOS-26 registration/permission
deep-links are broken upstream, and the camera is streaming-resolution only, so
the Camera Roll bridge is the better path today. To revisit when Meta ships a fix:
add the `meta-wearables-dat-ios` SPM package back, re-add the Associated Domains
entitlement + `MWDAT` Info.plist keys, and wire `AppModel` to the provider.
