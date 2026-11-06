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
