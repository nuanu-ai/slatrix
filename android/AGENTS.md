# The Android app

The root `AGENTS.md` applies here in full: the product bar, the shared tokens and rule cases, testing and workflow. This file adds what is particular to Android and grows with the app.

- Kotlin and Jetpack Compose, in one Gradle project in this folder.
- The reference is Slack's Android app, not a smaller Slatrix for Mac: its tabs, navigation, gestures and wording. When unsure, do what Slack's Android app does.
- Matrix work goes through the Kotlin bindings of the SDK this repository builds with its patches, never Element's published `matrix-rust-components-kotlin`, which lacks them.
- Colors and radii come from `design/tokens.json`, spelled out once in Kotlin, with a unit test that checks them against the file. Screens use roles, never raw colors or literal sizes, and a lint rule rejects them as `scripts/lint.sh` does on the Mac.
- Product rules pass every case in `spec/`, with a unit test per file that reads it.
- Notifications arrive through Firebase Cloud Messaging and a Sygnal push gateway.
- Element X Android is AGPL: read it to see how the SDK is used, never copy from it. Slatrix is Apache 2.0.
