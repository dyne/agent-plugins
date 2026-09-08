# Supervised Org Plan execution

Read this reference completely before launching supervised roles.

## Roles and ownership

```text
director (depth 0, org-plan-reviewer, Sol or Terra, read-only root)
└── executor (depth 1, only code writer)
```

- The root director also owns supervisor and reviewer duties. It owns user
  communication, directly launches each executor, enforces evidence gates, and
  returns ACCEPT or REJECT for DONE + UNREVIEWED L1s.
- The executor writes code for one L1 and reports only to the root.
- After every L1 executor has terminated, one fresh `gpt-5.6-sol` terminal
  reviewer audits the whole branch. It is the sole exception to the rule
  against separate reviewers and becomes the sole writer only for P0/P1 fixes.
- Recommended profiles are `org-plan-reviewer` (Sol) for a newly launched root
  and `org-plan-executor` (Terra). An already-running root keeps its selected
  model while adopting the combined director/reviewer/supervisor contract.
- Codex V1 agent depth defaults to one, which permits this direct spawn. Stop
  when direct spawning is unavailable; do not edit user configuration.

## Canonical positions and agent names

Use one-based positions independently of mutable IDs and titles. L1 position
`a` is `L<a>`; its L2 child position `b` is `L<a>.<b>`. Use these labels in
assignments, reports, reviews, commits, and user updates. IDs remain the exact
helper arguments.

The collaboration API accepts lowercase letters, digits, and underscores in a
task name. A dedicated position agent therefore uses `l<a>` or `l<a>_<b>` as
its machine task name and is referred to as `L<a>` or `L<a>.<b>`. For example,
L1 position 2 uses `l2`; its fifth L2 child uses `l2_5` and displays as `L2.5`.

## Start supervision

The first tool call reads this skill completely and performs no other command.
Only after that standalone read returns may the root inspect guidance, the plan,
or repository state. This keeps discovery from running before the governing
startup contract has been loaded.

Treat the loaded skill directory and the plan path supplied by the user, host,
or authoring handoff as startup inputs. Reuse the exact supplied plan path.
Do not rediscover it with `find` or `rg`, and do not substitute
`REPOSITORY/.gestalt/` for `WORKSPACE/.gestalt/`. Resolve the helper once as
`scripts/org-plan` beneath the loaded skill directory and verify that it is
executable. Do not probe helper source or help before starting. If either input
is absent, stop with that one missing prerequisite instead of trying speculative
paths.

`prepare-supervision` is setup-only: `gestalt-setup.sh` installs or refreshes
the root and executor profiles. Do not run it during ordinary supervised
execution. A root already running in the user conversation adopts this contract
without reinstalling its own profile.

1. Validate the exact plan once. The root then signals `supervision-start`,
   runs `org-plan projection PLAN`,
   and calls host `update_plan` with its exact `plan` items, reporting the
   companion explanation separately.
2. Before each L1, verify the preceding L1 is REVIEWED, terminate the previous
   executor, confirm closure, and resolve the next milestone with
   `org-plan describe`.
3. Launch a fresh depth-one executor with `fork_turns=none` for exactly that L1,
   using task name `l<a>` for its canonical `L<a>` position.
4. The executor loads `$gestalt:context-mode`, verifies every declared L1
   skill is available, then loads exactly those declared skills before any
   repository inspection or edit. Missing skills block without edits.

Both roles use host-native filesystem tools for governing instructions, small
bounded reads, edits, mutations, and short command interaction. Context-mode
is reserved for large or uncertain analysis, filtering, indexing, and retrieval;
it never writes or changes Org state.

## Human-attention decision table

`gestalt_org_plan_attention` is an optional mobile dynamic tool, not an
`$org-plan` dependency. Its current schema version is 1. Exhaust safe,
in-scope checks first. When a row below still prevents safe progress and the
tool is available, call it before yielding with a bounded summary, concrete
`requestedAction`, and the mapped `reason` and `resumeCondition`. When absent,
report the ordinary blocker concisely and continue normal supervision rather
than requiring the tool.

| Genuine blocker after safe checks | `reason` | `resumeCondition` |
| --- | --- | --- |
| Material plan scope, goal, or work change requires approval. | `planChange` | `planRevision` |
| An exhausted hard block requires external repair or an alternative. | `hardBlock` | `externalStateChanged` |
| A required system capability or declared task skill is unavailable. | `missingDependency` | `dependencyInstalled` |
| Missing authority, credentials, or permission prevents the work. | `permissionRequired` | `permissionGranted` |
| Verified relevant external state changed. | `externalState` | `externalStateChanged` |
| A material ambiguity remains after plan and repository evidence are exhausted. | `materialAmbiguity` | `userGuidance` |

Never call the tool for L1/L2 progress, a child report, waiting on a live child,
review readiness, a diagnosable or recoverable failing test, an ordinary merge
conflict, token/context pressure, elapsed time, a checkpoint, or an idle
executor. Resume the next legal supervision action in each of those cases.

## Evidence and review loop

Supervision is a completion loop:

- The executor owns the entire assigned L1. It continues from one L2 to the
  next without returning a final report merely because an L2, checkpoint,
  focused test, or progress update completed.
- After every executor report, inspect the executor's current state. If the L1
  is partial and the executor stopped or became idle, call `followup_task` on
  that same executor before returning any root response. If the user asks for
  status, answer briefly and perform that continuation in the same turn; the
  status reply does not satisfy the supervision action. If `org-plan next PLAN
  review` selects a DONE + UNREVIEWED L1,
  review it immediately and return ACCEPT or REJECT. Never review an
  ineligible L1. An executor result, a review result, an accepted-L1 report,
  and terminal whole-plan acceptance are distinct boundaries.
- A partial report, idle executor, self-described pause, token or elapsed-time
  notice, or completed L2 is never a user-facing stopping condition. Use the
  available follow-up or wait mechanism and keep supervision moving.
- End successfully only when every L1 is DONE and REVIEWED and final gates pass.
  Stop early only for a genuine external blocker that the root cannot resolve
  without user input, new authority, or changed external state.

After each L2, the root verifies intended dirty paths, inspects the L2
diff, and requires current focused-test evidence before DONE.

After every successful `authoring-start`, `set`, `l2`, `review`, or external
`resync`, the executor reports the helper mutation to the root. The root then
runs `org-plan projection PLAN` and calls host `update_plan`; executors never
create a competing native projection. A missing or failed host tool produces
one concise warning and never reverses a valid Org mutation.

After all L2s, require a current full-suite pass and intended complete L1 diff.
Use `org-plan next PLAN review`; request review only for the selected DONE +
UNREVIEWED L1. The request contains:

- plan path, branch, base, starting commit, and selected L1 ID;
- position, title, Goal, Tests, Done-when criteria, and UNREVIEWED status;
- uncommitted diff scope and shared-code regression impact;
- exact test commands with pass/fail summaries and evidence locations;
- UI evidence matrix when applicable;
- preserved paths, prohibited actions, and material-ambiguity stop condition.

The root independently returns structured findings plus explicit ACCEPT or
REJECT. Skip already REVIEWED L1s. On REJECT, send the findings unchanged in
substance to the same executor, which corrects the same uncommitted diff. Repeat
the gates and review without pausing for user approval.

On ACCEPT, inspect `git diff --cached --name-only`, direct the executor to
create exactly one conventional L1 commit when files changed, then record
`REVIEWED`. The root runs the helper projection and host `update_plan` before
the reporting boundary, verifies the subject and intended scope, and terminates
the executor. A no-change L1 explicitly records that no commit was required.

Org Plan files are never Git deliverables. Immediately before every accepted
L1 commit, the executor and root inspect `git diff --cached --name-only` and
exclude the active Org Plan plus every `.gestalt/*.org` path, including paths
introduced with `git add --force`. No repository instruction, release workflow,
or user request overrides this boundary.

When no L1 review is pending, record that milestone review is current.

## Terminal whole-branch review

After every L1 is DONE and REVIEWED, terminate the last L1 executor and confirm
that no other writer is active. Before final acceptance:

1. Spawn one fresh depth-one subagent with `fork_turns=none`,
   `agent_type=worker`, `model=gpt-5.6-sol`, and `task_name=final_review`.
2. Give it a general overview containing the Org Plan goal, every implemented
   L1/L2 outcome, the branch base and current HEAD, milestone commits, tests,
   known tradeoffs, and the exact plan path as read-only context.
3. Ask it to review the whole branch from the branch base through HEAD, plus any
   intended working-tree changes, against the complete Org Plan. Require a
   concise severity-ranked report with P0, P1, P2, or lower findings and file
   evidence.
4. If the report contains no P0 or P1, retain any lower-severity findings for
   the final report and continue to the root's final gates.
5. If the report contains a P0 or P1, order that same subagent to become the
   sole writer and fix every P0/P1. It adds regression coverage, runs focused
   checks and the full suite, and returns a concise correction diff and evidence
   report. The root reviews those corrections. After acceptance, direct the
   subagent to create one conventional final-review correction commit, excluding
   the active Org Plan and every `.gestalt/*.org` path.

Do not finish with an unresolved P0 or P1. Final acceptance requires the
terminal review, a current root-side full-suite pass, and clean intended scope.
This terminal reviewer is the sole exception to the prohibition on separate
reviewers; it never replaces routine root-owned L1 review.

## Accepted-L1 reporting boundary

An accepted L1 ends one root turn, not the plan. After the ACCEPT commit/review
transition, projection, and host `update_plan`, call optional
`gestalt_org_plan_checkpoint` once with `kind: l1Accepted`, the plan identity,
canonical L1 position/ID, and bounded created-or-not-required commit metadata.
Then send exactly one root final answer using the template below. Do not make
executor output user-facing, duplicate the final answer in commentary, or infer
acceptance from executor prose.

```
L<a>/TOTAL — TITLE: ACCEPTED

Completion: bounded delivered behavior.
Review: ACCEPT; include any REJECT findings repaired before acceptance.
Verification: exact commands and bounded pass/fail results.
Commit: conventional subject, then optional short hash; or “No commit required”.
Next: automatic continuation to L<n>, or terminal review after the final L1.
```

For non-final L1s, Autopilot starts the next root turn. For the final L1, that
later distinct continuation starts terminal review; its accepted-L1 report is
not whole-plan success. A missing checkpoint tool is not a blocker: preserve
the commit, review, projection, and single-writer gates, continue supervision
without early success, and use the legacy continuous-root fallback. In that
fallback, do not end the last-L1 turn before terminal review; combine its
accepted-L1 summary with terminal success only when a separate safe report
boundary is unavailable.

## Terminal whole-plan report

Only after terminal review has accepted the whole branch, all P0/P1 corrections
have their one conventional correction commit when needed, final gates pass,
and intended scope is clean, optionally checkpoint once with
`kind: terminalReviewAccepted` and send the sole terminal success answer. It
states terminal-review result, correction commit if any, final gate results,
residual P2-or-lower findings, clean intended scope, and all milestone commits.
It must not repeat an accepted-L1 final or include raw logs or child transcripts.

```
Plan terminal review: ACCEPTED

Review: whole-branch verdict and repaired P0/P1 findings.
Commits: milestone subjects and any terminal correction commit.
Verification: final gate commands and bounded results.
Residual findings: P2 or lower only.
Scope: clean intended scope.
```

## Reporting evidence ownership

Potentially large or uncertain inspections, tests, and logs use context-mode or
another context-preserving analysis path in both roles; small bounded filesystem
work stays native.
If unavailable, capture output outside the conversation and report only the
command, exit status, pass/fail counts, affected scope, and smallest diagnostic
excerpt. Never relay raw logs or complete child transcripts upward.

The root remains active and gives brief updates at supervision start and when an
L1 starts, reaches review, is rejected, is accepted, or blocks. On first mention
use `L<a>/TOTAL — TITLE: STATUS` plus its Goal; later use the same canonical
position and title. On first commit mention, report the conventional subject and purpose;
hashes are supplemental.

Routine review is agent-to-agent. Ask the user only for a material ambiguity or
unavailable prerequisite, never for progress approval.

## Standalone assignments

Every executor assignment identifies canonical `L<a>` and uses task name
`l<a>`. It includes its one L1 and full L2 block, repository
starting state, accepted prior outputs, allowed scope, required tests, exact
skills, implicit context-mode baseline, helper-only transitions, one post-ACCEPT
commit rule, preserved paths, completion-driven continuation, and genuine
external-blocker stop conditions. It explicitly forbids treating an L2 boundary
or partial report as completion of the assigned L1.

Never rely on inherited conversation context or write “continue above.”
