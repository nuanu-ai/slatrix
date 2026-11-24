---
name: Slatrix for Android
description: Slack-familiar conversations on Matrix, built for Android 15 (Design B).
colors:
  light-canvas: "#ffffff"
  light-raised: "#f1f2f4"
  light-sunken: "#e6e8eb"
  light-overlay: "#ffffff"
  light-text-primary: "#0f1115"
  light-text-secondary: "#555961"
  light-text-tertiary: "#696d75"
  light-border: "#e2e4e8"
  light-border-strong: "#c4c7cd"
  light-accent: "#1a64d6"
  light-wallpaper: "#e6ebf2"
  light-wallpaper-doodle: "#1a64d6/0.07"
  light-bubble-in: "#ffffff"
  light-bubble-edge: "#000000/0"
  light-glass: "#ffffff/0.6"
  light-glass-header: "#ffffff/0.72"
  dark-canvas: "#0f1012"
  dark-raised: "#1c1d21"
  dark-sunken: "#0a0b0d"
  dark-overlay: "#26272c"
  dark-text-primary: "#f1f2f4"
  dark-text-secondary: "#aeb1b9"
  dark-text-tertiary: "#9a9da5"
  dark-border: "#2c2e33"
  dark-border-strong: "#45474d"
  dark-accent: "#7aa9ff"
  dark-wallpaper: "#101317"
  dark-wallpaper-doodle: "#ffffff/0.045"
  dark-bubble-in: "#2a2c33"
  dark-bubble-edge: "#000000/0"
  dark-glass: "#28292e/0.55"
  dark-glass-header: "#16171a/0.62"
  accent-fill: "#1a64d6"
  on-accent: "#ffffff"
  mention-you-light-text: "#8a5a00"
  mention-you-light-fill: "#f2c744/0.4"
  mention-you-dark-text: "#f2c744"
  mention-you-dark-fill: "#f2c744/0.2"
rounded:
  extraSmall: "4dp"
  small: "8dp"
  medium: "12dp"
  large: "16dp"
  bubble: "20dp"
  extraLarge: "28dp"
spacing:
  line: "2dp"
  tiny: "4dp"
  small: "8dp"
  medium: "12dp"
  large: "16dp"
  section: "24dp"
---

# Design System: Slatrix for Android

Slatrix Android follows Slack's navigation, wording, and keyboard behavior while wearing Material 3 chrome and a messenger look (Design B). Neutral surfaces hold lists and forms, one saturated blue accent marks interactive elements and outgoing bubbles, and conversations sit on a tinted wallpaper canvas under frosted glass bars.

All visual tokens, dimensions, and animation specs live in `ui/designsystem/`. `../design/tokens.json` (`"android"` section plus shared `fileColors` and `avatarColors`) owns every color and corner radius, `DesignTokens.kt` mirrors it, and `DesignTokensTest` verifies them together. Android's `DesignTokenDetector` lint rule rejects raw `Color`, literal `.dp` / `.sp` / `.em` values, and raw Compose animation specs anywhere outside `ui/designsystem/`.

## Color, Themes, and Surfaces

Appearance is split into three independent controls in `AppearancePreferences` and applied through `SlatrixTheme`:

- Color mode: System, Light, or Dark.
- Theme palette (`AndroidTheme`): six choices in two groups. The Neutral group has Neutral (cool grays with blue accent), Material You (dynamic colors from the phone's wallpaper via `dynamicLightColorScheme` and `dynamicDarkColorScheme`), and Sand (warm paper surfaces and sand-tinted wallpaper). The Colored group has Aubergine (plum), Jade (forest green), and Ocean (marine blue), each tinting its surfaces, outgoing bubbles, frosted glass chrome, and chat wallpaper while keeping WCAG AA contrast in both light and dark modes. Existing installs with legacy `wallpaperColors = true` migrate automatically to Material You on read.
- Two independent toggles that apply on top of every theme: Chat wallpaper (`chatWallpaper`, on by default) shows or hides the tiled doodle overlay behind messages while keeping the tinted `wallpaper` backdrop, and Increase contrast (`increaseContrast`, off by default) strengthens borders and text contrast, deepens dark canvas to `#000000`, and keeps incoming bubbles borderless with stronger separation against the wallpaper.

Workspaces can override the global palette (`workspaceThemes` keyed by Matrix space ID and isolated per signed-in account). `SlatrixApp` resolves the active workspace theme in memory so switching spaces updates the palette immediately, and Preferences offers a scope toggle (`All workspaces` or the current workspace) with a `Use default` reset when an override is set.

Static palettes live under `"android"` (`"colors"` for Neutral and `"themes"` for `sand`, `aubergine`, `jade`, and `ocean`) in `../design/tokens.json`, mirrored in `DesignTokens.kt` and checked by `DesignTokensTest` and `SlatrixThemeTest`. Read colors through `SlatrixTheme.colors` so every screen stays coherent across palettes, color modes, and contrast settings.

In conversations (both channels and threads), messages float over a tinted `wallpaper` surface (`#e6ebf2` light and `#101317` dark in Neutral) patterned with a tiled 240 dp doodle shader (`Wallpaper.kt`). When Chat wallpaper is on, doodles draw at `0.07` alpha in light mode (tinted by the theme) and `0.045` alpha in dark mode (`#ffffff/0.045`, or `onSurface/0.045` under Material You). Turning Chat wallpaper off skips the doodle tile and draws only the solid `wallpaper` color.

Incoming bubbles fill with `bubbleIn` (`#ffffff` light, `#2a2c33` dark in Neutral) and have no border stroke (`bubbleEdge` is `#000000/0` across every theme and contrast mode, and `BubbleNode` skips the edge pass whenever alpha is zero). Outgoing bubbles use `accentFill` wrapped in `OnAccentFill`, which maps text to `onAccent`, metadata to `bubbleOutMeta` (`#ffffff/0.9`), dividers to `bubbleOutRule` (`#ffffff/0.22`), and underlines links so they stay legible on the accent fill.

Mentions of other people use `mentionText` and `mentionFill` in the theme's accent hue. Mentions of you keep warm amber across every theme (`#f2c744` fill at 40% light and 20% dark, with `#8a5a00` light and `#f2c744` dark text), matching the jump highlight wash so messages addressed to you stand out immediately.

Shared file colors (`design/tokens.json`) tint attachment badges calmly. On neutral surfaces and incoming bubbles, `AppColors.fileTileFill` draws a 14% tinted square (`40dp`, `shapes.small`) behind `AppColors.fileTileIcon`, which lifts the hue in dark mode and shades it slightly in light mode so every file icon clears WCAG 3:1 contrast against the tinted tile. Inside outgoing bubbles, `fileTileFill` switches to `bubbleOutRule` and `fileTileIcon` to `onAccent` so blue document icons remain readable against the blue bubble.

## Typography

`SlatrixType.kt` bundles Roboto as a single variable font covering Normal, Medium, SemiBold, Bold, and Black weights with italics so metrics stay consistent across OEMs. The theme maps Roboto across the full Material 3 type scale with `0.sp` tracking so small captions and timestamps stay tight on narrow phones.

Every size uses `sp` and scales with the Android system font size. Message bodies use `MaterialTheme.typography.message`, which applies `LocalMessageScale` on top of the system font scale with tighter `22.sp` base leading so multi-line bubbles read as cohesive blocks.

Screen titles use `titleLarge` or `titleMedium`, section labels use `ListHeading` (`titleSmall` in `textSecondary`), primary row titles use `bodyLarge` (bold for unread rows, medium for filenames and secondary cards), supporting previews use `bodyMedium`, and timestamps use `labelSmall` in `textSecondary`. Tab labels use `Typography.tabFit` auto-sizing so large system fonts shrink gracefully instead of clipping.

## Shapes, Avatars, and Layout Rhythm

Corner radii come from `MaterialTheme.shapes` and `DesignTokens.radii`: `extraSmall` (4dp), `small` (8dp), `medium` (12dp), `large` (16dp), `bubble` (20dp), and `extraLarge` (28dp).

People avatars are always circles (`CircleShape`), including uploaded profile photo previews and message facepiles. Each initials avatar shades from its shared avatar color down to 16% darker at the bottom (`AvatarStyle.fill`) with auto-sized bold initials, and swaps in the loaded Matrix picture inside the same fixed box so rows never shift. Workspace icons remain rounded squares so workspaces read apart from people.

Chat bubbles use `bubbleShape(own, grouped, last)`: `20dp` outer corners, `8dp` where adjacent bubbles from the same sender meet, and a `4dp` tail on the last bubble of a run. Vertical spacing between bubbles follows three explicit steps in `UiMetrics`:
- `BubbleGroupedGap` (`3dp`) between grouped text bubbles from the same sender.
- `BubbleAfterAttachmentGap` (`6dp`) when a grouped bubble follows an image, video, or file attachment so media keeps breathing room.
- `BubbleSenderGap` (`12dp`) when the sender changes.

Outgoing bubbles leave a `12%` far-side gutter (`BubbleGutter`), and incoming bubbles leave a gutter that grows smoothly from `24dp` on 320dp phones to `56dp` on 412dp phones.

Consistent rhythm across screens comes from `UiMetrics`:
- Lists use `GapLarge` (`16dp`) horizontal gutters, `ConversationRow` (`72dp`) with `RowAvatar` (`48dp`) for two-line conversation rows, `CompactRow` (`48dp`) for one-line entries, and `Touch` (`48dp`) minimum hit targets on every interactive row and button.
- Search fields use capsule styling (`CircleShape`, `SearchBar = 48dp` or `SearchField = 40dp`).
- Form inputs, profile action buttons, and detail rows standardize on `shapes.medium` (`12dp`).
- Bottom sheets clip their top corners to `SlatrixTheme.topPanelShape` (`28dp` top, `0dp` bottom) over `colors.overlay`, open with a `32x4dp` grab handle, and render actions through the shared `MenuItem` row.
- Dividers (`1dp` in `colors.border`) sit only between items, never trailing after the last row.

On compact screens (below 600dp), Home, DMs, Activity, and You sit in a floating frosted glass capsule (`TabBar = 64dp`, `TabInset = 4dp`, `GlassBlur = 24dp`, `GlassLift = 12dp`) above a swipeable `HorizontalPager`. At 600dp and above, navigation moves to a vertical rail. Inside conversations, headers (`HeaderRow = 64dp`) and the composer sit on full-width `glassBar` surfaces blurring the wallpapered `glassSource` timeline scrolling behind them.

## Motion System

Slatrix Android targets Android 15 (`minSdk = 35`) and uses spring physics in `Motion.kt` so gestures carry velocity, stay 100% interruptible, and exit as smoothly as they enter. No surface snaps or teleports closed.

### Physics Vocabulary

- `Motion.spatial()` (damping `0.88`, stiffness `380`): critically damped spatial movement for page push/pop, bottom sheet entrance and snap-back, composer banner height changes, and message focus lift.
- `Motion.snappy()` (damping `0.78`, stiffness `520`): crisp tactile response for swipe-to-reply snap-back, timeline item placement, quick-reaction stagger, reaction chip pop, and jump-to-bottom button entry.
- `Motion.gentle()` (damping `0.94`, stiffness `320`): smooth exits and fades for bottom sheet dismissal, scrims, focus blur unwind, jump highlight fade-out, media viewer dismissal, and Later swipe completion.

Normalized 0..1 progress animations pass `Motion.UnitThreshold` (`0.001f`) and pixel-space animations pass `Motion.PixelThreshold` (`1f`) so springs settle right as motion visually completes without a long sub-pixel tail.

### Navigation and Predictive Back

`LiveWorkspace` coordinates pushed pages with `rememberPredictiveBack` through `LocalBackProgress`:
- Pushing a page slides it in from the right on `Motion.spatial(UnitThreshold)` with a soft left-edge shadow (`pageEdgeShadow`) while the covered page parallaxes left by `18%` (`Motion.PushParallax`) under a dark scrim up to `22%` alpha (`Motion.ScrimMaxAlpha`, `pageScrim`).
- Swiping from the screen edge tracks the finger 1:1 on the top page, glides the covered page back from `-18%` toward `0%`, and fades the scrim proportionally. Releasing early springs smoothly back to `0`.
- Tapping the Back button keeps the popped page mounted in its existing composition slot (with touches and semantics cleared and its lifecycle lowered to `CREATED`) while sliding it off to the right on `Motion.spatial(UnitThreshold)` as the underlying page glides home. Re-pushing mid-exit cancels the old exit cleanly and starts fresh.

### Conversations, Sheets, Composer, and Media

- Interactive keyboard dismissal: the timeline `LazyColumn` attaches `Modifier.imeNestedScroll()` whenever `WindowInsets.isImeVisible` is true, so dragging down smoothly tracks the IME with the thumb.
- Timeline arrivals: message rows apply `Modifier.animateItem(fadeInSpec = Motion.gentle(), placementSpec = Motion.snappy(), fadeOutSpec = Motion.gentle())` so sent and incoming bubbles settle upward without jumping.
- Swipe to reply: dragging a bubble right reveals a `32dp` circular badge (`ReplySwipeBadge`) that scales up and fills with `colors.accentFill` plus a `GestureThresholdActivate` haptic tick at `UiMetrics.Swipe` (`64dp`), then springs back on `Motion.snappy(PixelThreshold)`.
- Message focus lift and reactions: long-pressing a message lifts the bubble above the sheet while blurring (`SheetBlur = 3dp`) and dimming the conversation behind it on `Motion.spatial(UnitThreshold)`. Quick-reaction buttons stagger in by `18ms` (`Motion.ReactionStaggerMillis`) on `Motion.snappy(UnitThreshold)`, and reaction chips pop when added or when their count changes. Dismissing the sheet fires `onDismissing` right away so the bubble lowers and the blur fades out on `Motion.gentle(UnitThreshold)` in lockstep with the sheet sliding down.
- Jump-to-bottom and highlights: the scroll-to-bottom FAB scales and fades both in (`Motion.snappy()`) and out (`Motion.gentle()`), and tapping it uses `animateScrollToItem(0)`. Jump highlights hold for `1500ms` (`UiMetrics.HighlightMillis`), then fade out smoothly on `Motion.gentle(UnitThreshold)`.
- Bottom sheets: `BottomSheet` springs up on `Motion.spatial(UnitThreshold)`, tracks downward drags and nested scroll handoffs 1:1 with the scrim, carries release fling velocity into `settle` and `dismiss`, consumes touches while exiting so actions never double-fire, and slides completely off-screen on `Motion.gentle(PixelThreshold)` before calling `onDismissRequest`.
- Composer: reply, edit, and also-send banners expand upward from the bottom via `AnimatedVisibility` (`Motion.spatial()` enter, `Motion.gentle()` exit) so the input field and bottom toolbar stay anchored without clipping, while `LiveChannelScreen` defers `Scaffold` bar padding into layout; `ComposerSendButton` morphs cleanly between disabled and filled accent states while keeping its `"Send message"` or `"Save changes"` accessibility label intact.
- Media viewer: when zoom is `1x`, dragging vertically tracks the image 1:1 while scaling it slightly and fading both backdrop and top bar; releasing past `UiMetrics.ViewerDismiss` (`120dp`) or flicking past `SheetDismissVelocity` dismisses smoothly on `Motion.gentle(PixelThreshold)`, and shorter drags spring back on `Motion.snappy(PixelThreshold)`. Zoomed images pan freely without triggering dismiss.
- Later cards: swiping past `UiMetrics.Swipe` animates the card off-screen on `Motion.gentle(PixelThreshold)`, and cancelled swipes spring home on `Motion.snappy(PixelThreshold)`.

### Performance and Reduced Motion

Per-frame animation reads stay inside `graphicsLayer`, `drawBehind`, or `offset` lambdas so moving surfaces never recompose Compose trees on every frame.

Every custom animation checks `CoroutineContext.isMotionReduced(context)` (reading both Compose's `MotionDurationScale` and Android's `ValueAnimator.areAnimatorsEnabled()` / `ANIMATOR_DURATION_SCALE`). When reduced motion is enabled, transitions snap directly to their target state without intermediate frames.

## Rules of Thumb

- Read every color from `SlatrixTheme.colors`, every dimension from `UiMetrics`, every radius from `MaterialTheme.shapes` or `DesignTokens.radii`, and every animation spec from `Motion`.
- Show cached content immediately and reserve fixed dimensions for avatars, images, and loading indicators (which wait `400ms` via `ProgressDelayMillis` and never carry `"Loading..."` copy).
- Keep transient chrome (errors, menus, offline pill, jump button) in overlays so message timelines never jump or reflow.
- Use `SlackIcons` for Slack's thin-stroke icons where Material's outlined set reads too heavy.
