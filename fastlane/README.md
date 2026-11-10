# CI signing with Fastlane match

This project uses [match](https://docs.fastlane.tools/actions/match/) to
manage the distribution certificate + ad-hoc provisioning profile, and an
**App Store Connect API key** (not your Apple ID password) to authenticate
non-interactively in CI. None of your Apple credentials are ever stored in
this repo's code -- only as encrypted GitHub Actions secrets.

## One-time setup (you do this once, locally or by giving Claude the values)

1. **Create a *separate*, empty, private GitHub repo to hold match's
   encrypted certificates** (never reuse this app's own repo for this --
   match's convention is a dedicated "certificates" repo). e.g.
   `Str8ZeRO1/ios-certificates-private`.

2. **Generate an App Store Connect API key** (if you don't have one):
   App Store Connect -> Users and Access -> Integrations -> App Store
   Connect API -> "+" -> role "App Manager" is sufficient. Download the
   `.p8` file -- it can only be downloaded once.

3. Gather these 5 values:
   - `APPSTORE_ISSUER_ID`
   - `APPSTORE_KEY_ID`
   - `APPSTORE_P8_KEY` (the full contents of the `.p8` file)
   - `DEVELOPMENT_TEAM_ID` (10-char Team ID from developer.apple.com -> Membership)
   - `MATCH_PASSWORD` (a new passphrase *you* make up -- encrypts the certs
     repo; store it somewhere safe, you'll need it if you ever manage
     signing locally)
   - `MATCH_GIT_URL` (the certificates repo's clone URL, e.g.
     `https://github.com/Str8ZeRO1/ios-certificates-private.git`)
   - a **Personal Access Token** with repo scope on the certificates repo,
     base64-encoded as `username:token`, for `MATCH_GIT_BASIC_AUTHORIZATION`
   - Your iPhone's **UDID** for `DEVICE_UDIDS` (Settings -> General -> About,
     tap the serial number field to cycle to UDID; or in Finder/Xcode if the
     phone is plugged into a Mac at any point)

4. Set all of the above as **GitHub Actions secrets** on the app repo
   (Settings -> Secrets and variables -> Actions -> New repository secret).
   The included PowerShell script (`scripts/setup-github-secrets.ps1`)
   does this for you via `gh secret set` if you'd rather paste values once
   into a prompt than click through the GitHub UI nine times.

5. Push a commit. The `ios-ci.yml` workflow runs `register_devices` once
   (safe to re-run; it's idempotent) then `build_adhoc`, producing a signed
   `AutomotiveDash.ipa` as a workflow artifact.

## Installing the resulting .ipa from Windows

An ad-hoc .ipa still needs to land on the phone through Apple's install
flow. From Windows, the two realistic options are:
- **Apple Configurator is Mac-only**, so instead use a browser-based OTA
  install: upload the .ipa + a generated manifest to a service like
  [diawi.com](https://www.diawi.com) (free tier) and open the resulting
  link in Safari *on the iPhone itself* -- it triggers the native "Install"
  prompt. `scripts/upload-to-diawi.ps1` automates the upload step.
- **Sideloadly** (Windows app) can push a local .ipa directly to a
  USB-connected iPhone without any Mac, using the same Apple ID
  signing-adjacent flow it uses for free-account sideloading -- works
  fine with an already-signed ad-hoc .ipa too.
