---
name: test-audit
description: "Writing, changing, reviewing or sweeping tests: reject duplicate or implementation-coupled proof; remove test-only production seams."
---

# Test Audit

Adapted from the OpenClaw `test-audit` skill for this Swift Testing codebase.

- The authoring gate applies to every new or changed test.
- Audits remove low-value proof in coherent owner batches; never chase deletion counts.

## Authoring gate

Before adding a test, answer:

1. Which observable behavior, invariant, or independent contract does it protect?
2. Which credible regression makes it fail?
3. Why does existing proof miss it? Each contract has one primary owner at the strongest boundary. Another layer needs a distinct transport or lifecycle risk. Extend parameterized arguments and shared fixtures; consolidate repeated setup.
4. Does it need an export, flag, wrapper or injection hook with no production caller? Move the proof to the real boundary instead.

- Regressions must fail before the fix for the intended reason and pass after the repair. Report it when baseline proof is unavailable.
- One owner regression covers a bug; never replay it at every layer it crosses.
- Behavior-preserving refactors should not break a test.
- Waits are condition-based (`Gate`, `eventually`), never `Task.sleep` or a fixed number of `Task.yield()`s. A negative check proves the guarded path was reached, not that the scheduler hasn't run yet.

## Junk patterns

- Reject self-comparisons, copied inventories, source greps, implementation and call-shape assertions (exact internal call counts), duplicate contracts, test-only seams, subject-generated expected values, mocks supplying the asserted behavior.
- Fixtures must not fabricate owner receipts or ordering, or claim a persistence path the code never writes.
- Negative controls must fail at the intended guard; names must match the exercised behavior.
- No assertion counting, PASS banners or tests of code written inside the test.
- When auditing candidates, use the [full checklist](references/audit.md#junk-patterns).

## Retention bar

- Keep independent API, SDK, protocol, config, migration, storage, security, platform, default, package, release, architecture and observable-ordering contracts. Static or slow is not disposable.
- Source inspection must survive identifier-only refactors and guard an independent user-facing contract.
- Baseline failures may be bugs to repair, not tests to delete.

## Audit and validation

- Before an audit edit, read the [candidate evidence and workflow](references/audit.md#candidate-evidence); inspect full owners, callers and history; record the remaining proof before deletion.
- Delete obsolete production seams with their tests; never optimize for deletion counts.
- Prove a kept contract with a deliberate mutation of the production owner (`scripts/mutate.sh` when available, or a manual edit) and confirm the keeper goes red; restore the source byte for byte.
- Run the owner and sibling suites (`swift test --filter`) and the full suite before handing off.
- Report causes, retained contracts, proof and cost, production versus test LOC, and follow-ups.
