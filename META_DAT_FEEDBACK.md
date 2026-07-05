# Meta Wearables DAT (iOS) — Developer Feedback

Findings from building a real third-party app (hands-free AI tour guide /
point-and-shoot identifier) against **meta-wearables-dat-ios 0.7.0** on
**iOS 26.x** with Ray-Ban Meta glasses, June 2026. Ready to paste into a GitHub
issue / developer-forum post.

## Blocking

1. **iOS 26: registration & permission deep links fail.**
   `startRegistration()` opens the Meta AI app and the trust prompt appears,
   but the return link never reaches the third-party app, so state oscillates
   `available → registering → available` forever. Separately,
   `requestPermission(.camera)` tries to open
   `https://www.meta.ai/stella/DevicePermissionRequest?...` and iOS rejects it
   (`LSApplicationWorkspaceErrorDomain Code=115`). Matches issue #133. We
   verified everything app-side: Associated Domains active (long-press link
   offers "Open in <app>"), AASA hosted and fetched (`?mode=developer`),
   correct bundle ID / Team ID / universal link in the dashboard, custom scheme
   registered. Registration is simply not completable on iOS 26 today.

2. **No terminal failure state for registration.** When the return link never
   arrives, there is no timeout, no error callback, no `.failed` state — the
   app can only guess. Please surface a terminal error with a reason.

## Major limitations

3. **Registration availability is silently gated on Bluetooth authorization.**
   If the host app lacks CoreBluetooth permission, `registrationState` is just
   `.unavailable` with no reason. We only discovered this by reading strings in
   the binary ("Central is unauthorized. This should have already been
   caught."). Please: (a) document it, (b) expose an "unavailable reason", and
   (c) have the SDK trigger the Bluetooth prompt itself.

4. **No access to hardware-button captures or full-resolution photos.** The
   camera capability is stream-resolution only (`StreamingResolution` ≤ high);
   photos the wearer takes with the capture button go to the Meta gallery and
   are invisible to DAT. For "point and shoot at anything" apps, the natural UX
   *is* the hardware button + full-res sensor. Today we work around DAT
   entirely by watching the iOS Camera Roll for Meta-AI-synced photos — which
   works, but with sync latency and no in-session control.

5. **Error ergonomics.** Enums bridge to NSError with garbage-looking codes
   (`PermissionError(rawValue: 4533249088)` when printed via interpolation),
   `RegistrationError.configurationInvalid` gives no hint *what* is invalid
   (missing MetaAppID vs bundle mismatch vs signature), and
   `WearablesError.alreadyConfigured` forces `try?` around `configure()`.

## Minor / DX

6. Docs (`wearables.developer.meta.com/docs`) are login-gated and return 403 to
   tooling — hard for CI, AI assistants, and link previews.
7. The GitHub repo ships only binary xcframeworks — no sample app source, no
   `Examples/` directory; the "sample app guide" lives behind the doc login.
8. Dashboard "Mobile app configuration" accepts a saved state with a stale
   bundle ID and the failure mode downstream (silent non-return during
   registration) gives no diagnostic pointing back to it.

## Related open issues (same family, none with maintainer responses as of June 2026)

- **#188** — startRegistration fails, `LSApplicationWorkspaceErrorDomain Code=115`
  (identical to ours; affects native + Flutter, new and existing apps, any DAT version).
- **#215** — Meta AI opens from `startRegistration()` but shows no approval sheet
  when it was backgrounded; no error surfaced. Workaround: kill Meta AI first.
- **#219** — production/release-channel registration completes in Meta AI but no
  callback is returned to the app (the "approved but never returns" symptom).
- **#205** — "Internal error" in Meta AI during startRegistration (iPhone 17e),
  reproducible with the official sample.
- **#222** — iPhone 17 Pro + Ray-Ban Meta Gen 2: "The operation could not be completed."
- **#133** — requestPermission(.camera) deep-links to Meta View/AI but the
  permission modal never appears; hangs indefinitely (iOS 26).

## Environment
- meta-wearables-dat-ios 0.7.0 (also reproduced pre-0.7 behaviors per CHANGELOG)
- iPhone on iOS 26.x, paid Apple Developer team, Associated Domains verified
- Ray-Ban Meta (Gen 2), Meta AI app latest, Developer Mode ON
