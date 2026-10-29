# Slatrix for Android

Requires JDK 17 and an Android SDK with platform 36 and build tools 36.0.0.
Set `ANDROID_HOME` to the SDK directory, or put `sdk.dir` in `local.properties`.

From the repository root:

```sh
scripts/build-sdk.sh --android
cd android
./gradlew :lint-rules:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease
```

The debug APK is in `app/build/outputs/apk/debug/`. The release APK is unsigned.
The Matrix library uses the repository's patched Kotlin bindings and native libraries,
including the Android certificate verifier version from the packaged `Cargo.lock`.

Colors and radii live in `design/tokens.json` and `DesignTokens.kt`. Change both together.
Android type and spacing tokens live in the design system. Screens use those roles;
Android lint rejects raw Compose colors and literal sizes outside that package.

## Using the app

Choose a homeserver, sign in with the method it offers, and verify the device with
another device or a recovery key. Home lists starred conversations, channels and direct
messages. Long-press a conversation to star or unstar it. The Search tab
finds channels and people as you type, people in the server's directory too,, and messages when you search, with Slack's
`in:` and `from:`. An empty search field lists your recent searches. Tap the workspace
icon or name to switch workspaces; direct messages remain available in every workspace.
Invitations to channels, direct messages and workspaces lead Home; open one to join or
decline it.
Tap Channels to browse the open workspace's channels, or the server's public ones,
and join one; Add channel offers that or creating a private channel in the workspace.
The + on Home and DMs starts a new message: find someone by name or Matrix ID and open
your direct message with them. Tap a name, a picture or a mention to open that person's profile, and Message to open
your direct message with them, made if there is none; a direct message's header opens
the other person.
Open You, then Preferences, to change the color mode and sidebar palette.
Color mode follows the system until you choose Light or Dark.

Use a dedicated test account and room for automated message checks.

## Push notifications

Push builds need a Firebase Android client and the [push gateway](push-gateway/README.md).
Keep the Firebase configuration outside the repository, then pass its absolute path:

```sh
./gradlew :app:assembleDebug \
  -PslatrixGoogleServices=/absolute/path/google-services.json \
  -PslatrixPushGateway=https://matrixpush-mfdhzgmbba-ew.a.run.app/_matrix/push/v1/notify
```

The Firebase file must include `ai.nuanu.slatrix.dev` for debug builds or
`ai.nuanu.slatrix` for release builds. The Cloud Function sends through that
Firebase project using its runtime identity, without a service-account key.
Builds without these properties leave push disabled.

## Screenshots

Render Home, DMs, You and a conversation with fictional data, without signing in:

```sh
./gradlew :app:recordRoborazziDebug
```

The PNGs land in `app/build/outputs/roborazzi/`, in both themes, with the Lagoon palette
and larger text for some. Android CI attaches them with its test reports and APKs.
