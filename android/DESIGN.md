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

Use the Material 3 type ramp supplied by `SlatrixTheme`, set in Lato (Slack's typeface, bundled under the SIL Open Font License) with no added tracking. Account headings use `headlineMedium`; workspace headings use `headlineSmall`; profile names use `titleLarge`; conversation headers and section labels use `titleSmall`, which the theme maps to `titleMedium`. These titles are bold where the screen requests it. Message bodies and list labels use `bodyLarge`, supporting details use `bodyMedium`, and timestamps use `bodySmall`. Avatar initials use the bold `labelLarge` role.

**The Scaled Type Rule.** Use theme type roles and allow Android system font scaling. Do not replace them with fixed text sizes. Lato ships in regular, italic, bold, bold italic and black.

## Layout

Use `UiMetrics`: the spacing steps are in the frontmatter. Lists use large horizontal gutters and small vertical row padding. Interactive rows have a minimum touch height (48dp), and conversation list rows and section headers Slack's (44dp), with content allowed to grow for larger text. Root headers have a minimum height (60dp) and sit on the palette's dark frame color with white text in both modes, as Slack's do. Account forms are centered with a maximum width (480dp).

Below the expanded threshold (600dp), Home and DMs use bottom navigation. At the threshold, navigation moves into a rail. You opens from the header avatar as a page with Back, as Slack's does. Honor status bars, navigation bars and the keyboard. Keep conversation identity stable as content changes.

## Elevation & Depth

The main screens separate areas with neutral surface tones, thin borders and dividers (1dp). Menus, dialogs and snackbars use native Material treatments. Do not add decorative shadows to conversation rows.

## Shapes

Use the four shared radii in the frontmatter. The top content panel rounds its top corners and keeps its bottom corners square. Conversation headers and the composer use the panel radius; search uses the large radius. Account buttons and compact avatar tiles use the small radius.

## Components

Account actions are full-width green buttons with white labels. Browser alternatives can use an outlined button. Cancel and Retry use text buttons. Let Material provide interaction and disabled states.

The Search tab opens with the cursor in a single-line rounded field (40dp) under the header, a search icon before the text and a clear button after it. While the field is empty it lists Recent searches, each with a clock icon. Typing lists the best-matching channels and people, after any recent searches that match; searching lists message hits with their conversation, sender and time, the matched words bold on the highlight color. The composer is a rounded raised field on a bar under a hairline, with an accent cursor and the send icon inside the field; it expands to five text lines. Keep its keyboard semantics and accessible label.

The Home header shows the open workspace's rounded-square icon (its initials on the palette's strong selection color), its name in black weight and a chevron; they open the workspace switcher, a sheet of the top-level workspaces, plus All conversations while a channel has no workspace. Home groups conversations under Starred (only while something is starred), Channels and Direct messages. Each section header pairs a thin icon and a bold 14 sp title with a small chevron after it, and a chevron at the end that collapses it; a collapsed section still shows its unread conversations. Conversation rows pair a channel icon (a lock for a private channel) or initials tile with a single-line title and optional unread count; read titles use the body color, unread ones bold primary. A long press opens a sheet to star or unstar the conversation, mark it read or unread, and mark every unread conversation in view read. Invitations, while there are any, lead Home under an Invitations header with a mail icon and nothing to collapse, each a bold row with its channel icon or initials tile. One opens a pushed page titled with what it invites you to, its icon or tile centered over "You’re invited to …", who sent it, and equal Decline (outlined) and Join (filled; Join workspace for a workspace) buttons; a spinner keeps its place under them. Where channels can be browsed, the Channels title opens Browse channels and only its end chevron collapses the section, and an Add channel row with a plus closes the section, opening a sheet with Browse channels and Create a channel. Browse channels is a pushed page with a search field over rows of a channel icon, the bold name, and a secondary line of members, who may join and the topic; a joined channel says Joined at the end, and one that needs an invitation shows a lock and does not respond. Create a channel takes a name with a # prefix and an optional topic, with Create in the bar. The bottom bar sits on the raised surface under a hairline, with a pill behind the selected tab's filled icon and a bold label. Rows in the DMs tab add the time and up to two lines of the latest message. Unread titles are bold, and unread state is announced as a state description. Initials tiles have a fixed size; the initials shrink to fit. Workspace, direct message, profile and search tiles show their Matrix picture over the initials once it loads, in the same box, so nothing moves; a picture already loaded this session shows at once. Message rows align an initials tile with sender, timestamp and body text; a sender's run within five minutes drops the tile and name. The body shows its formatting, mention pills, quotes beside a bar, lists and code blocks, and ends an edit with "(edited)". A reply quotes its parent's sender and first line above the body; a tap opens the parent where it is. Images show inline in a box reserved from their size and open full screen; other files show as a row with a tile in the kind's color. Reaction chips and a thread's replies line sit under the body. Day dividers read Today, Yesterday or the date. A long press opens the message sheet with Mark unread, which leaves the channel, Copy message, and Retry and Delete message for a failed send. Preserve stable message keys. Once the connection has been down for two seconds, a dark pill under the header says you're offline, floating over the list so nothing moves, and fades out when sync runs again. Home's top holds Slack's Later card, an outlined rounded tile with a bookmark, Later and how many items; it opens Later, a pushed page of saved messages newest first, each with its conversation, sender, time and text, and a filled bookmark that removes it. The message sheet's Save for later, or Remove from Later, sits above Copy link.

A profile is a page pushed over what was open, under a bar with Back and Profile: a 120dp picture tile, the name in black weight, a full-width outlined Message button for anyone but you, then Contact information with the Matrix ID on the accent color beside a sunken at-sign tile. A sender's name and picture, a mention pill and a direct message's header open it. A failed Message shows as a snackbar over the page.

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
- Draw Slack's thin outlined icons from `SlackIcons`; Material's outlined set reads heavier than Slack's.
- Don't cover visible content with loading UI or add loading explanations.
