# Working on Slatrix

Slatrix is a Matrix client that should feel like Slack to someone who has used Slack for years. The macOS app lives at the root of this repository (`Sources`, `Tests`, `scripts`). The Android app lives in `android/`, which adds its own rules in `android/AGENTS.md`. Contributors, human or agent, follow these rules in both.

## Product bar

- Slack parity first. When unsure how something should look, behave or be named, do what Slack does on that platform: Slack desktop on the Mac, Slack's mobile app on Android. That covers layout, shortcuts and gestures, wording and keyboard flow. Diverge only where Matrix forces it.
- Fast and still. Nothing flickers, jumps or reflows after it appears. Reserve space for content that loads later, keep view identity stable, and put transient UI (errors, menus, suggestions) in overlays instead of pushing content around.
- No visible kitchen. Show what's cached at once and reconcile quietly; late pieces (members, pins, reply previews, avatars) land without changing a row's height. A loading indicator waits ~400 ms, never covers content already on screen, and never comes with "Loading…" text.
- Every string earns its place. No explanations of how things work under the hood, no "SDK", no apologies, no disclaimers. If a label needs a sentence of justification, the design is wrong.
- Deliberate type and grid. Sizes, spacing and radii come from the design tokens, and the whole UI scales with the platform's text size: zoom (⌘= / ⌘- / ⌘0) on the Mac, the system font size on Android. A hard-coded font size is a bug.
- Motion is quiet. Panes and overlays ease in over 120–150 ms. Everything else is instant.

## Shared by both apps

- `design/tokens.json` holds the color roles for light and dark and every sidebar palette, the file and avatar colors, and the corner radii. Each app spells them out in its own code, and a test on each side checks them against the file, so a color changes in the file and in both apps in one pull request. Type sizes and spacing stay per platform.
- `spec/` holds product rules as cases, each an input and its expected result: unread badges, @ suggestions, search queries, what the composer sends, and avatar initials and colors. Each app's tests run every case, so the apps can't drift apart. Change a rule by changing its cases first, then each app until they pass. When a rule one app has comes to the other, its cases move into `spec/`.
- Both apps use the same pinned `matrix-rust-sdk` with the patches in `Support/MatrixSDK/patches`: `scripts/build-sdk.sh` puts the Mac's in `.build/native-sdk-package`, and `scripts/build-sdk.sh --android` puts the Kotlin bindings with `arm64-v8a` and `x86_64` libraries in `.build/native-sdk-android`. Each downloads the package CI published for the current pin and patches. Send each patch upstream and drop it once a release includes it.
- Skills live in `.claude/skills`. An agent that doesn't load skills reads the `SKILL.md` it names.

## Code

Use the `ponytail` skill on every change: the smallest change that fully solves the task, no speculative abstractions, deletion beats addition. Comments explain only the why the code cannot show. Never cut validation at trust boundaries, data-loss handling, security or accessibility.

State and Matrix logic never import a view. Rows and leaf views take plain values and callbacks, not services. Views build from the design system, which owns every color, size and animation.

## Testing

- Every behavior change starts red. Work with the `tdd` skill: one failing test, the minimal change, repeat; a bug fix starts with a test that fails for the reported reason. Commit the failing test first, with a message that says how it fails, then the change that makes it pass, so the pull request shows red before green.
- Every new or changed test passes the `test-audit` authoring gate. No tests of code written inside the test, no exact internal call counts, no restated constants, no assertion counting.
- Wait on conditions, never on sleeps or a fixed number of yields.
- Check that a test can fail: mutate the production line it protects and watch it go red.
- Speed budgets time real work at the scale of a busy account against about three times a local debug run. Raise one only with a measurement that explains why.

## Docs

The README and anything else a visitor reads should sound like a person wrote it. Run prose through the `humanizer` skill. Keep docs short and current; git history is the record of what happened, so the tree never holds logs, acceptance reports or proof files.

## Workflow

- Branch per change, small commits with imperative subjects, a pull request, green CI before merge. Pull requests merge as one squashed commit, so `main` stays green and bisectable while the pull request keeps the red-then-green record.
- Open pull requests with auto-merge on (`gh pr merge --auto --squash`), so green CI merges them.
- Match the process to the change. Small fixes (a visual tweak, a wrong condition, a few lines) go together in one pull request: one red test and the fix for each, the protected line mutated once by hand, and no mutation runs, hosted runs, snapshots or review skills unless the fix is in their area. New features, hard bugs and anything touching sync, storage or encryption get the full process.
- Review a larger diff with `code-review` and `ponytail-review` before it merges. Hard bugs go through `diagnosing-bugs`.
- Subagents run on Opus. Give open-ended work high effort: architecture, cross-cutting refactors, hard bugs, UI that needs judgment. Narrow tasks with a known shape get medium: a bug with a known cause, a mechanical sweep, a port.
- Never send messages, invitations or reactions from a real account unless the owner set up that account and room for testing.

## macOS app

### Code

- `Sources/Slatrix/Core` holds state and Matrix logic. `Sources/Slatrix/Views` holds SwiftUI and AppKit views.
- `MatrixService` is `@Observable`, so a view redraws only for what its body reads. Keep fast-changing state (messages, typing, the room list, drafts) out of `RootView`'s body, and place a view that redraws often with `layoutIsolated()` so its changes never lay out the whole window.
- Matrix work goes through the SDK's Swift bindings (`MatrixRustSDK`), which `scripts/build-sdk.sh` builds with the patches.
- Views build from `Views/DesignSystem`: color roles in `AppColors`, `Elevation` and `Motion` tokens, the `.primary`, `.secondary`, `.destructive`, `.textLink` and `.icon` button styles, `.field` and `SearchField`, `DelayedProgress` and `SkeletonRows`, and `PopoverHost` for anchored cards. `LoadingPresentation` sets when a loading indicator shows. The debug build's Window ▸ Component Gallery shows them all.
- Borderless buttons use `.buttonStyle(.row)`, which makes the whole frame clickable; `scripts/lint.sh` rejects `.plain`.
- A custom `NSView` that handles the mouse returns `false` from `mouseDownCanMoveWindow`. The window moves by its background, so otherwise the window server takes the drag.
- CI builds with Xcode 26. A local named like a function called in the same expression (`let count = … count($1)`) builds locally but fails there, so give the local its own name.
- `scripts/lint.sh` runs swift format, the `.plain` check, and rejects raw colors, off-system button styles, spinners, shadows, literal animations and rounded-border fields outside `Views/DesignSystem`. It runs in CI; run it before committing too.

### Tests

Tests use Swift Testing in `Tests/SlatrixTests`. Shared fakes and fixtures live in `Tests/SlatrixTests/Support`, and `SharedSpec` reads the shared tokens and cases.

- When a pull request changes both `Sources` and `Tests`, CI runs `scripts/red-check.sh`: its tests run on the base branch's sources and must fail. A behavior-preserving refactor carries the `refactor` label instead.
- Wait with `Gate` and `eventually`. `drainMainActor()` proves SDK callbacks already queued for the main actor have run.
- `scripts/mutate.sh <file> --filter <Suite>` tries every operator mutation in a file and lists the survivors.
- Speed budgets carry the `budget` tag and `Budget` in their names. Parallel tests skew the clock, so they run only alone: `SLATRIX_BUDGETS=1 scripts/test.sh --filter Budget --no-parallel`, which CI does in a step of its own.
- Tests open windows only through `offscreenWindow(_:)`, and lint rejects any other. AppKit pulls a titled window onto the screen, so whoever runs the tests would see it flash.
- Synthetic events from `window.sendEvent` skip the window server, so window dragging, cursor rects and scroll momentum never show up in them. Check those through the contract AppKit reads, such as `mouseDownCanMoveWindow`.

Agreed seams, where tests belong:

- **Timeline mapping**: SDK timeline items to `ChatMessage`. Catches wrong kinds, bodies, attachments and send states; misses rendering.
- **Services against SDK fakes**: subclasses of the generated SDK classes. Catches races, stale completions and error handling; misses real server behavior.
- **Local storage**: encrypted drafts, saved messages, attachment staging, credentials. Catches format, permission and corruption handling.
- **Pure policies**: read state, navigation order, sidebar layout, link parsing, search query grammar, timeline grouping and scroll anchoring. Catches rule regressions directly. Rules with cases in `spec/` run them.
- **Hosted timeline and window**: the real timeline, the whole window, or a design system component, in an offscreen window, opt-in with `SLATRIX_HOSTED_UI_CHECKS=1` because it needs an awake display. Catches scroll jumps, row geometry and what an update costs the main thread; misses real pointer input and WindowServer timing.
- **Performance log**: what the app writes to unified logging, read back through `OSLogStore`. Catches lost hang reports and names the report cannot parse; misses real WindowServer timing.
- **Release scripts**: run as a process with real arguments. Catches a tag that would ship a version Sparkle cannot order; misses signing, notarization and the appcast.

### Build

```sh
scripts/test.sh         # build and run tests
scripts/build-app.sh    # release app bundle in build/
scripts/perf-report.sh  # flow timings, loading states, moved rows and hangs from the last day of use (or e.g. 7d)
```

Both run `scripts/build-sdk.sh` first. It downloads the prebuilt SDK for the current pin and patches, and compiles it only when none is published yet (or with `SLATRIX_SDK_FROM_SOURCE=1`).

Debug builds keep their data and credentials in `~/Library/Application Support/Slatrix Dev`, so they never touch the daily-driver app's session.
