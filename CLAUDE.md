# Project guidance

Smart-glasses AI tour guide ("point at anything, hear the story"). iOS app in
`ios/` (XcodeGen; run `xcodegen generate` after changing `project.yml` or
adding files). Minimal Meta-DAT connection tester in `ios-dat-test/` on the
`claude/dat-minimal-connect-test` branch.

## Meta Wearables DAT SDK reference

- Official Claude Code plugin (skills + integration patterns) lives in the SDK
  repo itself — install locally with:
  `claude plugin marketplace add facebook/meta-wearables-dat-ios` then
  `claude plugin install mwdat-ios@mwdat-ios-marketplace`.
- Full API reference: fetch
  https://wearables.developer.meta.com/llms.txt?full=true (fetchable from local
  machines; blocked from some sandboxes — the same content ships in the repo's
  `AGENTS.md` and `plugins/mwdat-ios/skills/`).
- Official sample app source: `samples/CameraAccess` in the SDK repo — treat its
  Info.plist/entitlements as the source of truth for required config
  (AppLinkURLScheme WITH '://', MetaAppID "0" in Developer Mode,
  LSApplicationQueriesSchemes fb-viewapp, NSBonjourServices _bonjour._tcp,
  keychain + Wi-Fi entitlements). The registration callback is a CUSTOM URL
  SCHEME, not a universal link.
- Known upstream issues we've hit are catalogued in `META_DAT_FEEDBACK.md`.

## Current status (June 2026 handoff)

- Main app (`claude/meta-glasses-chatgpt-tour-zd2vo5`): works today via the
  **Camera Roll bridge** (glasses photo → Meta AI sync → auto-narrate). Brains:
  GPT-5 Nano via OpenRouter (default, throughput-routed) / Gemini (free, also
  the "eyes" for photos) / GPT-4o. On-device QR fast path (fetch + summarize the
  linked page aloud) and OCR grounding via Apple Vision. Wikipedia grounding,
  landmark cache, check-in memory, Obsidian export, cost meter. Lite voice only
  (on-device STT/TTS); push-to-talk holds through pauses.
- DAT tester (`claude/dat-minimal-connect-test`, `ios-dat-test/`): registration
  previously stalled (approve in Meta AI but no callback — see
  META_DAT_FEEDBACK.md). Config now matches Meta's official sample (scheme with
  `://`, MetaAppID "0", fb-viewapp allowlist, Bonjour, Wi-Fi/keychain
  entitlements). NEXT: fresh-install the tester on the iPhone, verify the
  per-glasses Developer Mode toggle, run Connect, watch for
  `reg state → registered`. If registration lands, port the DAT **live-stream**
  capture path into the main app (instant point-and-shoot); the provider code
  already exists in `ios/TourGuide/Glasses/MetaDATGlassesProvider.swift` (inert).
