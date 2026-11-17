# Releasing

Slatrix updates itself with [Sparkle](https://sparkle-project.org). Every hour it reads `appcast.xml` from the latest GitHub release, downloads a newer version in the background and installs it when you quit. Until then an Update button in the title bar shows the release notes and can restart into the new version right away.

## Ship a version

Releases ship from the owner's Mac, where the signing keys live. Tag `main` and run the script:

```sh
git tag -a v1.2.0 -m "What changed"
scripts/release.sh v1.2.0
```

The script builds the app, signs it with the keychain's Developer ID certificate, has Apple notarize it and staples the ticket. It then signs the update with Sparkle's EdDSA key, pushes the tag and publishes the zip and `appcast.xml` as a GitHub release. The tag message becomes the release notes.

## Keys

The Mac needs three things in its keychain:

- A Developer ID Application certificate.
- A notarytool profile, made once with `xcrun notarytool store-credentials`. The script uses the `git-sight` profile unless `SLATRIX_NOTARY_PROFILE` names another.
- Sparkle's EdDSA key. `scripts/setup-update-key.sh` creates it and writes the public key into `Config/Info.plist`. Back up the keychain item: every installed copy checks updates against that key, so the script never replaces a public key that `Config/Info.plist` already holds.

A fork ships with its own key. Point `SUFeedURL` in `Config/Info.plist` at the fork's releases, delete `SUPublicEDKey`, and run the setup script.
