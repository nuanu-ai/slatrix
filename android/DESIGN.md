---
name: Slatrix for Android
description: Slack-familiar conversations on Matrix.
colors:
  dark-canvas: "#1c1d21"
  dark-raised: "#24262a"
  dark-overlay: "#222529"
  dark-text-primary: "#f5f5f5"
  dark-text-body: "#d1d2d3"
  dark-text-secondary: "#abadb1"
  dark-border: "#383a3e"
  dark-border-strong: "#5a5c61"
  dark-accent: "#8195ff"
  light-canvas: "#ffffff"
  light-raised: "#f8f8f8"
  light-text-primary: "#1d1c1d"
  light-text-secondary: "#616061"
  light-border: "#e3e3e3"
  light-accent: "#334ec9"
  aubergine-dark-frame: "#350d36"
  aubergine-light-frame: "#ede4ef"
  aubergine-dark-selection: "#713783"
  aubergine-light-selection: "#f0e6f4"
  lagoon-dark-frame: "#0e293b"
  lagoon-light-frame: "#e2edf4"
  lagoon-dark-selection: "#195b7c"
  lagoon-light-selection: "#dceef8"
  button-primary: "#007a5a"
  on-accent: "#ffffff"
  mention: "#e01e5a"
  focus-ring: "#1d9bd1"
rounded:
  small: "4dp"
  default: "6dp"
  large: "8dp"
  panel: "12dp"
spacing:
  tiny: "4dp"
  small: "8dp"
  medium: "12dp"
  large: "16dp"
  section: "24dp"
components:
  button-primary:
    backgroundColor: "{colors.button-primary}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.small}"
  composer-dark:
    backgroundColor: "{colors.dark-canvas}"
    textColor: "{colors.dark-text-body}"
    rounded: "{rounded.panel}"
  conversation-header-dark:
    backgroundColor: "{colors.dark-raised}"
    textColor: "{colors.dark-text-primary}"
    rounded: "{rounded.panel}"
---

# Design System: Slatrix for Android

## Overview

**Creative North Star: "Slack on Android"**

Conversations lead. Familiar Slack navigation, compact rows and clear unread states sit inside native Android controls. The workspace frame carries the chosen palette; the conversation canvas stays neutral.

**Key Characteristics:**

- Dense, readable conversation lists.
- Quiet surfaces with restrained color.
- Native text scaling, Back and keyboard behavior.

## Colors

The frontmatter lists the reused roles for the two palettes exposed in Preferences. `../design/tokens.json` owns all shared colors and radii; `DesignTokens.kt` mirrors it. Extend those sources together when adding roles.

### Primary

Green marks account actions. The theme's accent marks links, input focus and send actions. Selected navigation uses the palette's selection fill with primary text.

### Secondary

Aubergine and Lagoon tint the workspace frame and selection. Color mode and palette are independent choices. System default is the initial mode; Aubergine is the initial palette.

### Neutral

Canvas holds conversations. Raised surfaces distinguish headers, overlay surfaces hold transient controls, and secondary text carries timestamps and supporting details. Mention badges use the shared mention role with white text.

**The Role Color Rule.** Read colors through `SlatrixTheme.colors`; preserve the light and dark role pairs.

## Typography

Use the native Material 3 type ramp supplied by `SlatrixTheme`. Account headings use `headlineMedium`; workspace headings use `headlineSmall`; profile names use `titleLarge`; conversation headers and section labels use `titleSmall`, which the theme maps to `titleMedium`. These titles are bold where the screen requests it. Message bodies and list labels use `bodyLarge`, supporting details use `bodyMedium`, and timestamps use `bodySmall`. Avatar initials use the bold `labelLarge` role.

**The Scaled Type Rule.** Use theme type roles and allow Android system font scaling. Do not replace them with fixed text sizes. The app inherits Material's font metrics; it has no separate display face.

## Layout

Use `UiMetrics`: the spacing steps are in the frontmatter. Lists use large horizontal gutters and small vertical row padding. Interactive rows have a minimum touch height (48dp), and conversation list rows and section headers Slack's (44dp), with content allowed to grow for larger text. Root headers have a minimum height (60dp) and sit on the palette's dark frame color with white text in both modes, as Slack's do. Account forms are centered with a maximum width (480dp).

Below the expanded threshold (600dp), Home and DMs use bottom navigation. At the threshold, navigation moves into a rail. You opens from the header avatar as a page with Back, as Slack's does. Honor status bars, navigation bars and the keyboard. Keep conversation identity stable as content changes.

## Elevation & Depth

The main screens separate areas with neutral surface tones, thin borders and dividers (1dp). Menus, dialogs and snackbars use native Material treatments. Do not add decorative shadows to conversation rows.

## Shapes

Use the four shared radii in the frontmatter. The top content panel rounds its top corners and keeps its bottom corners square. Conversation headers and the composer use the panel radius; search uses the large radius. Account buttons and compact avatar tiles use the small radius.

## Components

Account actions are full-width green buttons with white labels. Browser alternatives can use an outlined button. Cancel and Retry use text buttons. Let Material provide interaction and disabled states.

Search uses an outlined field with a leading search icon. The composer is a rounded raised field on a bar under a hairline, with an accent cursor and the send icon inside the field; it expands to five text lines. Keep its keyboard semantics and accessible label.

Home groups conversations under Starred (only while something is starred), Channels and Direct messages. Each section header pairs an icon and a bold title with a chevron that collapses it; a collapsed section still shows its unread conversations. Conversation rows pair a channel icon (a lock for a private channel) or initials tile with a single-line title and optional unread count; read titles use the body color, unread ones bold primary. A long press opens a sheet to star or unstar the conversation. The bottom bar sits on the raised surface under a hairline, with a pill behind the selected tab's filled icon and a bold label. Rows in the DMs tab add the time and up to two lines of the latest message. Unread titles are bold, and unread state is announced as a state description. Initials tiles have a fixed size; the initials shrink to fit. Message rows align an initials tile with sender, timestamp and body text; a sender's run within five minutes drops the tile and name. Day dividers read Today, Yesterday or the date. A long press opens the message sheet with Copy message, and Retry and Delete message for a failed send. Preserve stable message keys.

Preferences uses full-row selection with radio semantics for color mode and palette. Errors appear as snackbars over the content. Connection progress waits (400ms); its reserved space prevents the account form from moving.

## Do's and Don'ts

### Do:

- Do follow Slack Android conventions for supported actions and wording.
- Do use shared color roles, shared radii and Android spacing tokens.
- Do preserve readable foregrounds in both modes and at larger text sizes.
- Do show cached content immediately and keep rows still as details arrive.

### Don't:

- Don't expose controls without a working action.
- Don't replace native icons with text glyphs.
- Don't cover visible content with loading UI or add loading explanations.
