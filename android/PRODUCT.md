# Slatrix for Android

<!-- impeccable:product-schema 1 -->

## Platform

android

## Stack

Kotlin and Jetpack Compose, using the repository's patched Matrix Rust SDK.

## Users

People who know Slack and want a familiar way to use Matrix on their phone.

## Product Purpose

Read and send conversations, find channels and direct messages, and notice unread messages.

## Capabilities and Constraints

The app connects to Matrix accounts through supported password or browser sign-in,
restores sessions, and supports identity verification and recovery. Home lists real
channels and direct messages, with Matrix spaces as workspace choices and a local
conversation filter. Conversations show messages, load earlier history, mark visible
messages read and send text. Drafts are stored encrypted on the device.

You shows the signed-in identity and Preferences. Color mode follows the system by
default, with Light and Dark overrides. Aubergine and Lagoon are separate palette
choices. Appearance and workspace choices persist across launches.

Notifications require a configured Firebase project and a Firebase Cloud Function
that implements the Matrix push gateway API.
Live acceptance uses an owner-provided test account and room.

## Brand Commitments

Slack Android sets layout, navigation, gestures and wording. The Mac app is the
behavior reference. `../design/tokens.json` owns colors and radii; Android owns its
type and spacing scale. Follow system text size, theme, Back and window insets.

## Product Principles

Show cached content immediately. Keep rows still as details arrive. Keep frequent
communication tasks obvious and copy short. Preserve accessibility and data safety.
Omit unsupported features and controls that do nothing.
