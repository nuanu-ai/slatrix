# Slatrix design standards

Slatrix follows Slack for layout, wording, and keyboard flow while drawing in the host platform's native style: Apple's Human Interface Guidelines on macOS and Material 3 on Android. Shared color tokens and corner radii live in `design/tokens.json` and are checked by `DesignTokenTests` and `ThemeTests`.

## Themes and floating sidebar geometry

Every macOS theme uses the same window geometry. The sidebar floats as an inset rounded panel (`m.sidebarInset`, `m.radiusPanel`, `.elevation(.e1, cornerRadius: m.radiusPanel)`), while the conversation and right inspector fill the window edge to edge on `colors.canvas`. Switching themes never shifts the sidebar header (`m.paneHeader - 2 * m.sidebarInset`), window buttons, search bar, or conversation frame.

Six curated themes split into two groups in Preferences:

- Neutral: Glass (default, translucent macOS sidebar vibrancy tinted by `colors.sidebar`, blending behind the window when docked and within the window in the narrow drawer), Neutral (opaque graphite sidebar), and Sand (warm paper canvas and sidebar).
- Colored: Aubergine, Jade, and Ocean. Each renders a rich colored floating sidebar with a built-in vertical gradient (`colors.sidebar` to `colors.sidebarEnd`) and light sidebar ink (`colors.onSidebar`).

Two independent toggles work on all six themes:

- Chat wallpaper (default on): draws repeating doodle tiles from `design/wallpaper.json` at `2.5%` opacity (`0.025`) behind messages, using subtle theme-tinted ink in light mode and white in dark mode. Opaque `rowHover`, `surfaceCard`, and `overlay` surfaces block the texture cleanly.
- Increase contrast (default off, also combined with macOS Increase Contrast): doubles border and selection line strength (`lines = 2.0`), deepens dark canvases to pure or near black (`#000000`, `#050403` for Sand), raises text and status contrast, and adds a `1pt` border to the floating sidebar.

Workspaces can override the global theme individually. When a space is open, Preferences lets the user pick a theme for all workspaces or for the active space alone, with a "Use default" reset back to the global choice.

## Surface luminance ladder

Surfaces step cleanly in luminance so floating chrome and cards never sink into a hovered row, and wallpaper doodles never bleed through interactive surfaces. Every surface in the ladder is opaque (`alpha == 1.0`).

In dark mode, elevation rises strictly from canvas to overlay:

`canvas < rowHover < control < raised <= surfaceCard < overlay`

| Palette | `canvas` | `rowHover` | `raised` | `surfaceCard` | `overlay` |
| --- | --- | --- | --- | --- | --- |
| Neutral base (Glass, Neutral, Aubergine, Jade, Ocean) | `#141416` | `#1b1b1f` | `#222227` | `#222227` | `#27272d` |
| Sand | `#171512` | `#1f1c18` | `#27231e` | `#27231e` | `#2e2a24` |
| Neutral base (Increase contrast) | `#000000` | `#101012` | `#19191d` | `#19191d` | `#222226` |
| Sand (Increase contrast) | `#050403` | `#13110e` | `#1e1a16` | `#1e1a16` | `#27231d` |

In light mode, background bands step down from the canvas (`canvas > rowHover > raised`) while interactive cards (`surfaceCard`) and floating bars (`overlay`) lift above `rowHover` with a `1px` `colors.border` hairline:

| Palette | `canvas` | `rowHover` | `raised` | `surfaceCard` | `overlay` |
| --- | --- | --- | --- | --- | --- |
| Neutral base (Glass, Neutral, Aubergine, Jade, Ocean) | `#ffffff` | `#f6f6f8` | `#f2f2f5` | `#ffffff` | `#fbfbfd` |
| Sand | `#fdfbf7` | `#f7f3eb` | `#f2ece2` | `#fffdfa` | `#fffdfa` |
| Neutral base (Increase contrast) | `#ffffff` | `#f5f5f7` | `#f0f0f2` | `#ffffff` | `#ffffff` |
| Sand (Increase contrast) | `#fdfbf7` | `#f7f3eb` | `#f2ece2` | `#fffdfa` | `#fffdfa` |

Translucent fills (`colors.hover`, `colors.pressed`, `colors.selection`) are for controls inside a surface, sidebar rows on floating sidebar gradients, and secondary states on top of an already opaque background. Full-bleed list and timeline rows use opaque `colors.rowHover`.

## Accent discipline and semantic color

The system accent is reserved for primary buttons, links, active selections, unread counts, and mentions of other people. Every theme keeps the user's macOS accent color instead of introducing competing brand hues.

Mentions that notify you (`@you` and `@room`) use warm amber so they separate immediately from links and ordinary mentions:

- Light mode: `#7a4d00` text on `#f2c744/0.30` fill (`#5c3900` under Increase contrast)
- Dark mode: `#ffe58f` text on `#cc8e14/0.22` fill

Every text, status, sidebar, and mention pairing meets WCAG AA (`>= 4.5:1`) across all six themes in light and dark mode, with Increase contrast both off and on, across steady-state surfaces (`canvas`, `rowHover`, `raised`, `surfaceCard`, `overlay`, `control`), floating sidebar surfaces, and all macOS system accent colors. Warm amber own mentions also meet `>= 4.5:1` over the transient jump highlight.

File-type icons use the shared `fileColors` palette as a soft tinted tile (`0.12` opacity fill in light mode, `0.16` in dark mode) with a subtle tinted hairline (`0.18` / `0.24`) and a deepened light or lifted dark vector symbol (`colors.fileGlyph(_:)`). All ten file kinds maintain at least `3.0:1` graphical contrast against their tile without turning into saturated solid blocks that compete with links.

## Avatars

People avatars are always circles (`AvatarView` with `cornerRadius: nil`), including in message rows, profile views, search results, and Preferences miniatures. Spaces and channels are rounded squares (`m.radiusSpace` or `m.radius`).

## Typography and reading rhythm

All sizes come from `TextRole` and `Metrics`, scaling uniformly with window zoom (`⌘=`, `⌘-`, `⌘0`, from `80%` to `200%`). Hard-coded point sizes outside `Views/DesignSystem` are rejected by `scripts/lint.sh`.

| Role | Size / Line height | Where it belongs |
| --- | --- | --- |
| `subheadline` | `11 / 14` | Timestamps, dividers, badges, `(edited)`, status labels |
| `caption` | `12 / 16` | Channel topics, reply previews, file metadata, inline errors |
| `body` | `13 / 16` | Sidebar, list rows, buttons, fields, file card names (Medium) |
| `reading` | `14 / 21` | Message bodies, author names (Semibold), composer text |
| `title3` | `15 / 20` | Pane headers, sheet titles, space name, message `h3`-`h6` |
| `title2` | `17 / 22` | Message `h2` |
| `title1` | `22 / 26` | Page headers, message `h1` |
| `largeTitle` | `26 / 32` | Empty states, channel welcome titles, sign-in |

Message bodies and the composer share reading line spacing, paragraph spacing, and line-breaking rules in `MessageBlocks`:

- Reading line spacing scales with `fontSize` (`fontSize * 0.27`, producing ~21 pt lines at 14 pt).
- Non-code paragraphs carry `paragraphSpacing` (`fontSize * 0.25`, `3.5 pt` at 14 pt) so explicit line breaks (`\n`) separate cleanly from soft-wrapped lines inside the same paragraph.
- Non-code paragraphs enable `lineBreakStrategy = .pushOut` so macOS avoids leaving single-word orphans at the end of wrapped lines.
- Rendered messages collapse blank lines between non-code paragraphs to `0.5 * fontSize` (`7 pt` at 14 pt) with zero extra `paragraphSpacing`, giving multi-paragraph posts clear air while the composer keeps full editable blank lines for caret placement.
- Code blocks keep `0` internal paragraph spacing, standard line breaking, and intact blank lines.

File names in `FileCard`, `FileRow`, and staged composer tiles stay visually subordinate to sender names: `.body` (`13 pt`) Medium for the filename and `.caption` (`12 pt`) muted text for type and size metadata.

## Conversation grid and grouping rhythm

Conversation and thread timelines span the full width of their pane, matching Slack desktop. Horizontal insets are `20 pt` for conversations and `16 pt` for threads (`ConversationGrid.inset(thread:)`), with avatar-to-text gaps of `12 pt` and `8 pt`. Collection feeds (Activity, Threads, Later, Drafts, Search) cap content at `920 pt` (`ConversationGrid.collectionWidth`) so wide monitors stay scannable.

Vertical spacing in comfortable density reflects real message boundaries:

- `12 pt` top inset above a new sender.
- `3 pt` top inset between grouped text messages from the same sender.
- `10 pt` top inset above a grouped message that immediately follows an attachment (file card or inline media), giving follow-up text clear separation from the attachment and clean room for the hover toolbar.

Hovered message rows paint a full-bleed opaque `colors.rowHover` band edge to edge across the pane, avoiding inset rounded boxes around nested cards and thread bars.

## Compact cards, bars, and toolbars

Components inside message rows hug their content instead of stretching into half-empty rectangles across wide windows:

- `FileCard` fits its content between `240 pt` minimum and `348 pt` maximum width (clamped to narrow panes), with a `36 pt` tinted `FileTypeIcon`, middle-truncated `.body` Medium filename, `.caption` metadata, `colors.surfaceCard` fill, and a `1px` border (`colors.border` at rest, `colors.borderStrong` on hover). Hovering reveals quiet trailing Download and More controls inside reserved horizontal padding so they never collide with the filename or shift row geometry.
- `ThreadRepliesBar` fits its content up to `340 pt` maximum width without a greedy spacer, placing the trailing chevron `8 pt` after "View thread". Hovering fills the bar with opaque `colors.overlay` and a `1px` `colors.border` hairline at constant height (`minHeight: 24 pt`).
- `MessageToolbar` uses an `8 pt` corner radius (`m.radius`) on `colors.overlay` with `.elevation(.e1, cornerRadius: m.radius)`. A `1px` vertical `colors.border` divider (`16 pt` tall) separates the three quick-reaction emojis from the monochrome SF Symbol actions.
- Cards in side panes and settings (`PinnedMessagesView`, `PreferencesView`) sit on `colors.raised` with `m.radiusLarge` (`12 pt`) corners and a `1px` `colors.border` hairline.

## Motion

Motion stays quiet and respects macOS Reduce Motion. Every token in `Motion` returns `nil` when `accessibilityDisplayShouldReduceMotion` is enabled:

- `Motion.overlay` (`120 ms` ease-out): popovers, menus, toasts, floating composer accessories, and hover control reveals.
- `Motion.content` (`120 ms` ease-out): late-arriving images fading over placeholders, typing indicator updates, and composer height changes when edit, formatting, or attachment strips toggle.
- `Motion.pane` (`150 ms` ease-out): sidebar and side pane open/close transitions.
- `Motion.highlight` (`1 s` ease-out): jump-to-message highlight fading out after landing.

Row hover, selection changes, tab switches, and ordinary button clicks are instant. Never introduce bouncy springs or durations longer than `150 ms` for routine desktop chrome.
