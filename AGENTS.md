# Working on Slatrix

Slatrix is a native macOS Matrix client that should feel like Slack to someone who has used Slack for years. Contributors, human or agent, follow these rules.

## Product bar

- Slack parity first. When unsure how something should look, behave or be named, do what Slack desktop does: layout, shortcuts, wording, keyboard flow. Diverge only where Matrix forces it.
- Fast and still. Nothing flickers, jumps or reflows after it appears. Reserve space for content that loads later, keep view identity stable, and put transient UI (errors, menus, suggestions) in overlays instead of pushing content around.
- Every string earns its place. No explanations of how things work under the hood, no "SDK", no apologies, no disclaimers. If a label needs a sentence of justification, the design is wrong.
- Deliberate type and grid. Sizes, spacing and radii come from the design tokens. The whole UI scales with zoom (⌘= / ⌘- / ⌘0). A hard-coded font size is a bug.
- Motion is quiet. Panes and overlays ease in over 120–150 ms. Everything else is instant.

## Code

Use the `ponytail` skill on every change: the smallest change that fully solves the task, no speculative abstractions, deletion beats addition. Comments explain only the why the code cannot show. Never cut validation at trust boundaries, data-loss handling, security or accessibility.

- `Sources/Slatrix/Core` holds state and Matrix logic. It never imports a view.
- `Sources/Slatrix/Views` holds SwiftUI and AppKit views. Rows and leaf views take plain values and closures, not services.
- Matrix work goes through the official SDK (`MatrixRustSDK`). Patches to it live in `Support/MatrixSDK/patches` and `scripts/build-sdk.sh` applies them. Send each patch upstream and drop it once a release includes it.
- Borderless buttons use `.buttonStyle(.row)`, which makes the whole frame clickable; `scripts/lint.sh` rejects `.plain`.
- A custom `NSView` that handles the mouse returns `false` from `mouseDownCanMoveWindow`. The window moves by its background, so otherwise the window server takes the drag.
- `scripts/lint.sh` runs swift format and the `.plain` check. It runs in CI; run it before committing too.

## Testing

Tests use Swift Testing in `Tests/SlatrixTests`. Shared fakes and fixtures live in `Tests/SlatrixTests/Support`.

- Work red-green with the `tdd` skill: one failing test, the minimal fix, repeat. A bug fix starts with a test that fails for the reported reason.
- Every new or changed test passes the `test-audit` authoring gate. No tests of code written inside the test, no exact internal call counts, no restated constants, no assertion counting.
- Wait on conditions (`Gate`, `eventually`), never on `Task.sleep` or a fixed number of yields. `drainMainActor()` proves SDK callbacks already queued for the main actor have run.
- Check that a test can fail: mutate the production line it protects and watch it go red. `scripts/mutate.sh <file> --filter <Suite>` tries every operator mutation in a file and lists the survivors.
- Synthetic events from `window.sendEvent` skip the window server, so window dragging, cursor rects and scroll momentum never show up in them. Check those through the contract AppKit reads, such as `mouseDownCanMoveWindow`.

Agreed seams, where tests belong:

- **Timeline mapping**: SDK timeline items to `ChatMessage`. Catches wrong kinds, bodies, attachments and send states; misses rendering.
- **Services against SDK fakes**: subclasses of the generated SDK classes. Catches races, stale completions and error handling; misses real server behavior.
- **Local storage**: encrypted drafts, saved messages, attachment staging, credentials. Catches format, permission and corruption handling.
- **Pure policies**: read state, navigation order, sidebar layout, link parsing, search query grammar, timeline grouping and scroll anchoring. Catches rule regressions directly.
- **Hosted timeline**: the real timeline in an offscreen window, opt-in with `SLATRIX_HOSTED_UI_CHECKS=1` because it needs an awake display. Catches scroll jumps and row geometry; misses real pointer input and WindowServer timing.
- **Performance log**: what the app writes to unified logging, read back through `OSLogStore`. Catches lost hang reports and names the report cannot parse; misses real WindowServer timing.
- **Release scripts**: run as a process with real arguments. Catches a tag that would ship a version Sparkle cannot order; misses signing, notarization and the appcast.

## Docs

The README and anything else a visitor reads should sound like a person wrote it. Run prose through the `humanizer` skill. Keep docs short and current; git history is the record of what happened, so the tree never holds logs, acceptance reports or proof files.

## Workflow

- Branch per change, small commits with imperative subjects, a pull request, green CI before merge.
- Review your own diff with `code-review` and `ponytail-review` before asking for a merge. Hard bugs go through `diagnosing-bugs`.
- Subagents run on Opus. Give open-ended work high effort: architecture, cross-cutting refactors, hard bugs, UI that needs judgment. Narrow tasks with a known shape get medium: a bug with a known cause, a mechanical sweep, a port.
- Debug builds keep their data and credentials in `~/Library/Application Support/Slatrix Dev`, so they never touch the daily-driver app's session.
- Never send messages, invitations or reactions from a real account unless the owner set up that account and room for testing.

## Build

```sh
scripts/test.sh         # build and run tests
scripts/build-app.sh    # release app bundle in build/
```

Both run `scripts/build-sdk.sh` first. It downloads the prebuilt SDK for the current pin and patches, and compiles it only when none is published yet (or with `SLATRIX_SDK_FROM_SOURCE=1`).
