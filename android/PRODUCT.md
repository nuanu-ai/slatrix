# Slatrix for Android

<!-- impeccable:product-schema 1 -->

## Platform

android

## Stack

Kotlin and Jetpack Compose, using the repository's patched Matrix Rust SDK.

## Users

People who know Slack and want a familiar way to use Matrix on their phone.

## Product Purpose

Read and send conversations, follow threads, and notice messages that need attention.

## Capabilities and Constraints

The first screens use fictional data: Home, DMs, Activity, a channel, a thread, and You.
Follow Slack for actions Slatrix supports through Matrix. Omit unsupported features
and controls that do nothing.
Follow the system theme by default. Preferences offers System default, Light and Dark,
plus a separate color palette. Remember these choices across launches.
The owner chooses a direction before Matrix is connected. Live acceptance uses an
owner-provided test account and room. Notifications use FCM and Sygnal.

## Brand Commitments

Slack Android sets the layout, navigation, gestures and wording. The Mac app is the
behavior reference. `design/tokens.json` owns colors and radii; Android owns its type
and spacing scale. The app follows system text size, theme, Back and window insets.

## Product Principles

Show cached content immediately. Keep rows still as details arrive. Keep frequent
communication tasks obvious and copy short. Preserve accessibility and data safety.
