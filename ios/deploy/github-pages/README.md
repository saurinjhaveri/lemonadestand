# GitHub Pages host for the DAT Universal Link

The Meta Wearables DAT app-linking handshake uses a **Universal Link**, which
needs an **Apple App Site Association (AASA)** file served from the root of a
domain you control. We use free **GitHub Pages** at `saurinjhaveri.github.io`.

## One-time setup

1. **Create a repo named exactly `saurinjhaveri.github.io`** (a GitHub *user
   site* — this is what serves files at the domain root, which Universal Links
   require; a project page like `…github.io/lemonadestand/` will NOT work).

2. Copy the `.well-known/apple-app-site-association` file from this folder into
   that repo at the same path:
   ```
   saurinjhaveri.github.io/
     └── .well-known/
           └── apple-app-site-association   (no file extension!)
   ```

3. **Replace `TEAM_ID`** in that file with your real Apple Team ID, e.g.
   `A1B2C3D4E5.com.saurin.tourguide`. (How to find your Team ID: Xcode ▸
   Settings ▸ Accounts ▸ select your team; or developer.apple.com ▸ Account ▸
   Membership ▸ Team ID; or run:
   `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`
   and read the `OU=` field.)

4. In the repo's **Settings ▸ Pages**, set Source = `main` branch, `/ (root)`.
   Wait for it to publish.

5. **Verify** it's live and served as JSON over HTTPS with no redirect:
   ```
   curl -i https://saurinjhaveri.github.io/.well-known/apple-app-site-association
   ```
   You should get `HTTP/2 200`. (Content-Type doesn't have to be JSON, but a
   200 with the raw JSON body and no redirect is required.)

## Values to enter in the Meta Wearables Developer Center

| Field          | Value                                            |
|----------------|--------------------------------------------------|
| Bundle ID      | `com.saurin.tourguide`                           |
| Team ID        | your Apple Team ID (10 chars)                     |
| Universal link | `https://saurinjhaveri.github.io/tourguide`      |

The app side is already wired:
- `applinks:saurinjhaveri.github.io` is in the Associated Domains entitlement
  (`project.yml`).
- `TourGuideApp` handles the incoming Universal Link via
  `onContinueUserActivity` and forwards it to `Wearables.shared.handleUrl`.

> ⚠️ Associated Domains requires the **paid** Apple Developer Program. A free
> personal team can host the AASA fine but can't sign the entitlement on-device.
