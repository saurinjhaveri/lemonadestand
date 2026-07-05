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

- **DAT registration WORKS** (confirmed on device via `ios-dat-test/`). Root
  cause of the weeks-long stall: config had to match Meta's official sample —
  `AppLinkURLScheme` WITH `://`, `MetaAppID` "0" in Developer Mode,
  `LSApplicationQueriesSchemes` fb-viewapp, `NSBonjourServices` `_bonjour._tcp`,
  keychain-access-groups + Wi-Fi entitlements. Callback is the CUSTOM SCHEME.
- Main app (`claude/meta-glasses-chatgpt-tour-zd2vo5`) now has the **live DAT
  stream wired in**: same sample-aligned config (registration carries over via
  the shared bundle id + keychain group), background connect on session start,
  "Look at this" and voice look-intents ("what am I looking at") grab an instant
  frame from the stream, with a 4s failsafe that answers from the latest cached
  video frame. **Camera Roll bridge remains as fallback** (hardware-button
  photos still arrive that way — DAT can't see the capture button).
- Brains: GPT-5 Nano via OpenRouter (default) / Gemini (free; also "eyes" for
  photos) / GPT-4o. On-device QR fast path + OCR grounding, Wikipedia grounding,
  landmark cache, check-in memory, Obsidian export, cost meter, Lite voice.
- NEXT: on-device test of live capture end-to-end; then consider resolution
  (.medium can beat .high per-frame per Meta docs), wake-free triggers, and the
  Phase-4 backend (keys off-device) before sharing builds.
