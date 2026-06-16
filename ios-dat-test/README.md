# DAT Connect Test (minimal)

A bare-bones app whose only job is to **connect the iPhone to the Meta glasses**
and print every step, so we can isolate whether DAT connectivity works at all on
your phone/iOS version — separate from the full Tour Guide app.

It uses the **same bundle id (`com.saurin.tourguide`) and URL scheme
(`tourguide`)** as the main app, so the Developer Mode trust carries over.

## Build & run
```bash
cd ios-dat-test
# set your Apple Team ID for device signing:
#   edit project.yml → uncomment DEVELOPMENT_TEAM: <your team id>
xcodegen generate
open DATTest.xcodeproj
```
- Select your **physical iPhone**, set the signing **Team**, and run.
- Make sure the **glasses are connected in the Meta AI app** (Bluetooth) and
  **worn (hinges open)**, with **Developer Mode ON**.

## What it does
Tap **Connect** and it logs, in order:
1. `Wearables.configure()`
2. registration state (+ `startRegistration()` if needed — approve in Meta AI app)
3. camera permission status (+ request)
4. device discovery (`Wearables.shared.devices`)
5. `createSession()`
6. `session.start()` + session state stream
7. `addStream()`
8. `stream.start()`

Then **Capture photo** triggers a photo and logs the byte count.

## Reading the result
- Stops at **device discovery (0 devices)** → the glasses aren't reaching the
  toolkit (Meta AI connection / Developer Mode / firmware).
- Stops at **camera permission** with a `meta.ai` open failure → the iOS-26
  permission deep-link bug (issue #133).
- Reaches **CONNECTED** → DAT works on your phone; we port the flow into the
  main app with confidence.
