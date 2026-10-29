# The Android app

The root `AGENTS.md` applies here in full: the product bar, the shared tokens and rule cases, testing and workflow. This file adds what is particular to Android and grows with the app.

- Kotlin and Jetpack Compose, in one Gradle project in this folder.
- The reference is Slack's Android app, not a smaller Slatrix for Mac: its tabs, navigation, gestures and wording. When unsure, do what Slack's Android app does.
- Matrix work goes through the SDK from `scripts/build-sdk.sh --android`, never Element's published `matrix-rust-components-kotlin`, which lacks our patches. Gradle takes its `kotlin` folder as a source set and its `jniLibs` as native libraries; minSdk is 24 or higher. The bindings need:
  - JNA as `net.java.dev.jna:jna:5.18.1@aar`, plus `kotlinx-coroutines-core` and `androidx.annotation`;
  - `org.matrix.rustsdk.Android.init(applicationContext)` before `initPlatform`, or TLS verification fails;
  - rustls's `rustls-platform-verifier` at the version the package's `Cargo.lock` pins, with its ProGuard keep rule;
  - a 4–6 GB Gradle heap, since the generated Kotlin is large.
- Colors and radii come from `design/tokens.json`, spelled out once in Kotlin, with a unit test that checks them against the file. Screens use roles, never raw colors or literal sizes, and a lint rule rejects them as `scripts/lint.sh` does on the Mac.
- Product rules pass every case in `spec/`, with a unit test per file that reads it.
- Notifications arrive through Firebase Cloud Messaging. The Matrix push gateway is a small Cloud Function in the app's own Firebase project, so there is no server to run and no Firebase key to keep anywhere else.
- Element X Android is AGPL: read it to see how the SDK is used, never copy from it. Slatrix is Apache 2.0.

## Tests

- **Compose screens**: drive real screens with fictional data through Compose semantics and render them with Roborazzi. Catches navigation, draft and appearance regressions; captures support visual review but miss physical input, real server behavior and device timing.

- **Shared design tokens**: resolve every light/dark palette and compare all colors, file/avatar colors and radii with `design/tokens.json`. Catches cross-platform drift; misses rendering.
- **Appearance storage**: reopen Android preferences after changing theme and palette. Catches lost appearance choices; misses rendered application and abrupt process death.
- **Window configuration**: inspect the real Activity's keyboard adjustment mode and system bar icon appearance. Catches a missing resize request or icons that ignore theme changes; actual IME geometry and icon contrast still need emulator inspection.
- **Device startup**: launch the real application and call the native SDK through its generated bindings. Catches missing entry points, startup failures and JNI packaging; misses authenticated server behavior.
- **Android lint**: run the real detector on Kotlin fixtures. Catches off-system Compose colors and sizes; misses rendered layout and contrast.

Run `./gradlew :lint-rules:test :app:testDebugUnitTest :app:lintDebug` from this folder after preparing the SDK package.
