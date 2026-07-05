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
