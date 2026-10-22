# Google Drive backup

Cue Studio can back up recordings to the user's Google Drive. The user connects an account in **Settings › Storage › Google Drive**. After that:

- Each saved recording uploads automatically. This can be switched off.
- Any recording can be sent by hand from its menu in **Recordings**: *Upload to Google Drive*, *Copy Google Drive Link*, or *Open in Google Drive*.

Recordings are uploaded to `Cue Studio/<recording name>/` in the user's Drive. Each folder mirrors the `.cuerec` package: `manifest.json`, `media/` and `telemetry/`. The `derived/` caches are not uploaded. The copy on the Mac is never removed.

What has been uploaded is recorded in a `.drive.json` file inside each package. Uploading again only sends the files that changed. If an upload is interrupted, it carries on at the next launch.

## Setting up the OAuth client (once)

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project (or pick one).
2. **APIs & Services › Library**: enable the **Google Drive API**.
3. **Google Auth Platform › Branding / Audience**: set up the consent screen.
   - Pick the **External** user type.
   - While the app is in *Testing*, add your Google accounts as test users.
4. **Data Access**: add these scopes:
   - `.../auth/drive.file`
   - `openid`
   - `.../auth/userinfo.email`

   `drive.file` is non-sensitive, because it only covers files the app creates. Publishing the app therefore doesn't need Google's security review.
5. **Clients › Create client**: choose application type **iOS** and enter bundle ID `com.stackrover.cue.studio`.
   - Use iOS, not *Desktop*. An iOS client has no secret, and it can return to the app on its reversed-client-ID URL scheme, which `ASWebAuthenticationSession` catches.
6. Copy `Config/Google.xcconfig.example` to `Config/Google.xcconfig` (git ignores it), then paste in the client ID:

   ```
   CUE_GOOGLE_CLIENT_ID = 1234567890-abc123.apps.googleusercontent.com
   ```

7. Rebuild Cue Studio. Without a client ID, the Connect button is disabled and explains why.

Release builds made from a clean worktree need `Config/Google.xcconfig` copied in, just like `Config/Signing.xcconfig`.

## Consent screen links

The pages are hosted with GitHub Pages from the `mehedihasanhr/mehedihasanhr.github.io` repo:

- Home page: https://mehedihasanhr.github.io/klik/
- Privacy policy: https://mehedihasanhr.github.io/klik/privacy/
- Authorized domain: `mehedihasanhr.github.io`

If Studio's use of Google data changes, update the privacy policy as well.

## How it works

| Piece | File |
| --- | --- |
| Sign-in: OAuth code flow with PKCE, token refresh and revoke | `CueStudio/App/Cloud/GoogleOAuth.swift` |
| Drive v3: folders, plus resumable uploads in 8 MiB chunks | `CueStudio/App/Cloud/GoogleDriveClient.swift` |
| Queue, auto-upload, per-recording state | `CueStudio/App/Cloud/DriveStorage.swift` |
| Refresh token storage (login keychain) | `CueStudio/App/Cloud/StudioKeychain.swift` |
| Settings UI | `CueStudio/App/Settings/DriveSettingsGroup.swift` |

The access token is only kept in memory. The refresh token is stored in the keychain. When the user disconnects, the app revokes the grant with Google and forgets the account. Recordings that are already in Drive stay there.
