# Matrix Rust SDK

The official `matrix-rust-components-swift` releases ship iOS slices only, so
`scripts/build-sdk.sh` builds [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk)
for macOS at the revision pinned by `SDK_REV` in that script, with these patches
applied in order:

- `0001-canonical-edited-search-hits`: search hits for edited messages point at the original event (ID, sender, time) with the edited body, so jumping to a hit finds it in the timeline.
- `0002-clt-framework-export`: adds xtask `--skip-xcodebuild` and `--stable-toolchain` so `build-framework` works with Command Line Tools only and a pinned Rust toolchain.
- `0003-bounded-cached-search-replay`: replays a bounded slice of already-cached room events into a newly configured search index, so history cached before indexing becomes searchable.
- `0004-focused-cache-freshness`: forwards later edits, reactions and redactions into event-focused (jump-to-message) timelines, which otherwise show stale content.
- `0005-focused-initialization-retry`: lets a failed or cancelled event-focused timeline initialization be retried instead of failing with `CacheStateAlreadyExists`.

Send each patch upstream and drop it once an SDK release includes it.
