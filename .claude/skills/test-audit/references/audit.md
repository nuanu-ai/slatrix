# Audit workflow

- Use after the [authoring gate](../SKILL.md#authoring-gate).

## Junk patterns

Reject new matches unless the [retention bar](#retention-bar) identifies an independent contract. Audit existing matches:

- Assertion-free probes, self-comparisons, identity copiers, subject-generated expected values.
- Copied inventories, manifests or constant tables restated from production; exact source, import or string greps.
- Private predicate or call-shape tests duplicating boundary proof; repeated invocations of shared helpers.
- Test-only exports, globals or wrappers; production paths called only by tests.
- Fakes implementing the asserted behavior, or pretending distinct SDK APIs match.
- Fixtures supplying receipts, admission or callback ordering the owner should produce; persistence asserted against a store path the code never writes.
- Capability flags asserted instead of the promised delivery or acknowledgement.
- Negative controls passing on an unrelated guard or an unreachable rejection.
- Names promising behavior the inputs and assertions never exercise.
- Real sleeps and fixed yield counts standing in for a condition.

## Retention bar

- Keep independent public API, SDK, protocol, config, migration, storage, security, platform, default, package, release and architecture contracts. Keep observable ordering and credible regressions.
- Source inspection is valid when it is the cheapest independent guard of a user-facing key, byte or path and survives identifier-only refactoring.
- Static or slow is not a reason to delete. A baseline failure may be a product bug: reproduce and repair the owner; never delete the test for it.

## Candidate evidence

- Before editing, read the full test, production owner, entry point, callers, callees, siblings, overlapping proof and history. For SDK-backed claims, inspect the generated `MatrixRustSDK` Swift API.
- Record for each candidate:
  - exact name and location, and the failure it can detect;
  - non-test callers of the covered production seam;
  - stronger remaining owner proof, or why none is needed;
  - why it exists and what deleting it unlocks;
  - risk and the focused validation command.
- Missing evidence means no deletion. Discovery is read-only; report before editing. Prefer a few high-confidence candidates.
- Delete obsolete seams and dead paths; move retained regressions to their owner; consolidate shared fixtures into `Tests/SlatrixTests/Support`.
- Prefer net-negative production LOC. Never add replacement implementation tests or turn uncertainty into cleanup.

## Validation and handoff

- Run the owner and sibling suites, then the full `swift test`.
- Run `swift format lint` on changed files and `git diff --check`.
- Inspect `git diff --numstat`, then get a final review with the `code-review` skill.
- Report causes, removed categories and seams, retained false positives, proof and cost, production versus test LOC, and follow-ups.
