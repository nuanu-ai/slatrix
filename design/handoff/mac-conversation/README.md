# Mac conversation redesign

The owner approved these boards on November 6, 2026. This folder lives only on the `design/mac-conversation` branch: never merge that branch, and never copy the folder into a pull request. Build the redesign on a branch from `main` and read the boards from here:

```sh
git fetch origin design/mac-conversation
mkdir -p "$TMPDIR/handoff"
git archive origin/design/mac-conversation design/handoff | tar -x -C "$TMPDIR/handoff"
```

Once the redesign has merged, delete the branch:

```sh
git push origin --delete design/mac-conversation
```

## Boards

- `before-dark.png` is the screen as it is today, redrawn from a screenshot of the app.
- `after-dark.png` and `after-light.png` are the target.
- `sidebar-footers-dark.png` and `sidebar-footers-light.png` show the bottom of the sidebar with a long channel list: the old hard cut, today's glass plate, and the target.
- `mockup/` holds the boards' source. The inline styles carry exact sizes and colors. The live canvas is at https://claude.ai/artifact/N5FfJFCDfjaVog8NdSKofE, visible to the owner's account only.

The boards show a realistic conversation: mostly short direct messages and one long one. The demo fixture's long messages hid how empty the timeline looks in daily use, so check against content like this.

## What changes

1. **The timeline is a centered column**, 720 pt wide including each row's 20 pt side padding. The composer has the same width and is centered too. The hover toolbar sits at the column's right edge, not the window's (`placeToolbar` in `TimelineTable.swift`). Row height estimates measure the column instead of the window (`estimate`). The thread pane is narrower than the column already and doesn't change.
2. **Day dividers** (`TimelineDayDivider`) become a hairline, the label at 11 pt semibold in the secondary color, and another hairline, spanning the column. They have no capsule and no border, with 20 pt above and 4 below.
3. **Message rows** (`MessageRow`):
   - the avatar is 32 pt (`Metrics.messageAvatar`, now 36);
   - the sender's name is 13 pt semibold (`.body`, now `.reading`);
   - the time is in `textTertiary`;
   - the body stays at 14/20.
4. **Reactions** (`ReactionChip`): your own reaction keeps the accent tint and loses the accent edge. The pill stays 24 pt tall and keeps the faces that `spec/reactions.json` asks for.
5. **Channel glyphs** in the sidebar use `textTertiary` instead of the accent (the room row in `SidebarView.swift`).
6. **The sidebar footer** loses its plate (`FooterPlate`):
   - you appear as a plain row on the sidebar's own color, with a 20 pt avatar, the presence dot, and your name at 13 pt;
   - above the row, the list fades into the sidebar color over `sp32`, with no line;
   - a short list shows nothing extra;
   - at the end of a long list, the bottom padding keeps the last row clear of the fade.
7. **The header's Files and links button** uses `paperclip` instead of `doc.on.doc` (`ChannelHeader.swift`).

## Not part of this redesign

The boards also show two things that need their own pull requests:

- **The floating date at the top of the timeline.** The app doesn't have one today, so it's a new behavior.
- **The brighter avatar palette.** Mac and Android share it (`design/tokens.json`, `spec/avatar.json`), so it changes in both apps at once, and everyone's color changes with it.

## Checking the result

Render the screen with the same kind of content, using `SLATRIX_SNAPSHOTS=1 scripts/test.sh --filter Snapshots`. Put each snapshot beside `after-dark.png` and `after-light.png`, in dark and light. A difference counts as unfinished work, not a matter of taste.

## What else is unfinished

Everything below is outside the redesign. It was open on `main` at `827cdef6` on November 6, 2026.

### Before anything else

- **Main's CI is red after #212.** The `mac (test)` job hit its 30-minute limit. The watchdog's list of running suites was empty, and #212 changed nothing on the Mac except `spec/capabilities.json`, so it looks like a hang outside any test. The failed jobs were started again. If they fail again, find what hangs before merging anything else.
- **Nothing ships until the owner says so.** Main has had no release since 0.2.23. When the owner lifts the hold, the first release carries #203 through #212: the guard against space under the newest message, the Activity badge, names in mentions and notifications, Android reaction faces, Mac themes, and Later's tabs and reminders.

### Unverified

- **Space under the newest message** (#203). `closeGap()` in `TimelineTable.swift` scrolls back when the table ends up taller than its rows, and logs `timeline.gap` each time. The owner hasn't run a build with it yet. After the next release, `scripts/perf-report.sh` counts how often it fired.
- **Later reminders** (#211, #212). Tests cover scheduling. Nobody has watched a reminder arrive after a real wait on a signed Mac build or a phone, or measured how late Android delivers one under Doze.
- **Switching themes by hand.** Nobody has checked whether the Mac window flickers when the theme changes.

### Bugs

- **Verification hangs** on "exchanging verification codes" and never shows the emoji.
- **A message jumps when someone reacts to it** on the Mac. Not reproduced yet. Start from `timeline.jump` in the performance log.
- **Gaps inside the feed after a day divider.** Probably the same kind of problem as the space under the newest message: rows whose measured height is wrong.
- **The High Contrast tile in Preferences looks like the Default one.** Make the four tiles tell their themes apart.

### Missing features

- **Online status and read receipts** on both apps: presence dots that reflect the server, and who has read up to where.
- **Themes on Android.** `app.themes` is `missing` there; the Mac has Slate, Sand and High Contrast in `design/tokens.json` (`mac.themes`).
- **Mac polish beyond these boards:** a focus ring that follows the system, and Preferences as a grouped form in the style of System Settings.

### Housekeeping

- The worktree `.claude/worktrees/agent-ad2bd0ab444c44faf` and its local branch `later-workflow-android` on the old machine were locked by the harness. #212 has already merged their work, so remove both once they unlock.
