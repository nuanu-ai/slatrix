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

## Screen mockups

The app opens with fictional conversations. Home, DMs and Activity share the tab bar;
open the profile photo for You. Appearance offers Aubergine and Lagoon in light or dark.
Messages sent here stay in the local preview.

```sh
./gradlew :app:recordRoborazziDebug
```

The PNGs in `app/build/outputs/roborazzi/` cover all six screens, both themes and palettes,
plus larger text. Android CI attaches them with its test reports and APKs.
The owner chooses the direction before these screens connect to Matrix.
