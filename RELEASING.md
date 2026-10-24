# Releasing

Slatrix updates itself with [Sparkle](https://sparkle-project.org). Once a day it reads `appcast.xml` from the latest GitHub release, downloads a newer version in the background and installs it when you quit. Until then an Update button in the title bar shows the release notes and can restart into the new version right away.

## Ship a version

Push an annotated tag:

```sh
git tag -a v1.2.0 -m "What changed"
git push origin v1.2.0
```

The [release workflow](.github/workflows/release.yml) builds and signs the app, signs the update with Sparkle's EdDSA key and publishes the zip and `appcast.xml` as a GitHub release. The tag message becomes the release notes. If you drafted a release for the tag first, its text is used instead.

## Update key

The workflow needs the `SPARKLE_ED_PRIVATE_KEY` secret. Create it once by running `scripts/setup-update-key.sh` on your Mac with `gh` signed in. The script creates the EdDSA key pair in your login keychain, writes the public key into `Config/Info.plist` for you to commit, and stores the private key as the secret. Back up the keychain item: every installed copy checks updates against that key, so the script never replaces a public key that `Config/Info.plist` already holds.

A fork ships with its own key. Point `SUFeedURL` in `Config/Info.plist` at the fork's releases, delete `SUPublicEDKey`, and run the script.

## Signing and notarization

To sign with a Developer ID Application certificate (exported from Keychain Access as a `.p12`) and notarize with an App Store Connect API key, add these secrets. The workflow picks them up as is:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD
gh secret set NOTARY_API_KEY_P8 < AuthKey_KEYID.p8
gh secret set NOTARY_API_KEY_ID --body KEYID
gh secret set NOTARY_API_ISSUER_ID --body ISSUER_ID
```

Without them, releases are signed ad hoc and not notarized. Sparkle still installs them, but macOS asks once after each update before Slatrix can read its saved session from the keychain, and a first download from the release page needs Open Anyway in System Settings → Privacy & Security.
