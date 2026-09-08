#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
helper="$root/plugins/gestalt/skills/org-plan/scripts/org-plan"
fixtures="$root/tests/plugins/gestalt/fixtures"
skill="$root/plugins/gestalt/skills/org-plan/SKILL.md"
manifest="$root/plugins/gestalt/.codex-plugin/plugin.json"
readme="$root/README.md"
agents="$root/AGENTS.md"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/org-plan-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
# Each status-publication case supplies its own endpoint. Do not let the
# parent relay's optional publication configuration change which endpoint the
# helper chooses while this test is exercising legacy file and directory mode.
unset GESTALT_MOBILE_ORG_PLAN_STATUS_DIRECTORY GESTALT_MOBILE_ORG_PLAN_STATUS_FILE
passes=0 failures=0

pass() { passes=$((passes + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
expect_ok() { if "$@" >"$tmp/out" 2>"$tmp/err"; then pass; else fail "$* (expected success): $(<"$tmp/err")"; fi; }
expect_fail() { if "$@" >"$tmp/out" 2>"$tmp/err"; then fail "$* (expected failure)"; else pass; fi; }
expect_status() { local expected=$1 status; shift; if "$@" >"$tmp/out" 2>"$tmp/err"; then status=0; else status=$?; fi; test "$status" = "$expected" && pass || fail "$* (expected status $expected, got $status)"; }
expect_contains() { if grep -F -- "$2" "$1" >/dev/null; then pass; else fail "missing $2 in $1"; fi; }
expect_not_contains() { if grep -F -- "$2" "$1" >/dev/null; then fail "unexpected $2 in $1"; else pass; fi; }
copy() {
  cp "$fixtures/$1" "$tmp/$2"
}

copy valid-minimal.org plan.org
expect_ok "$helper" validate "$tmp/plan.org"
expect_ok "$helper" --help
expect_contains "$tmp/out" 'usage: org-plan COMMAND [args]'
expect_ok "$helper" signal --help
expect_contains "$tmp/out" 'usage: org-plan signal PLAN [REASON]'
expect_ok "$helper" supervision-start --help
expect_contains "$tmp/out" 'usage: org-plan supervision-start PLAN'
expect_ok "$helper" status --help
expect_contains "$tmp/out" 'usage: org-plan status PLAN'
expect_ok "$helper" prepare-supervision --help
expect_contains "$tmp/out" 'setup-only: installs or refreshes supervised role profiles'
test ! -e "$tmp/.codex/agents/org-plan-reviewer.toml" && pass || fail 'prepare-supervision help has no setup side effect'
expect_status 2 "$helper"
copy valid-multi.org multi.org
sed '0,/:REVIEW_STATUS: UNREVIEWED/s//:REVIEW_STATUS: REVIEWED/' "$tmp/multi.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/multi.org"
expect_ok "$helper" validate "$tmp/multi.org"

copy valid-multi.org measured.org
measurement_start='{"observedAt":"2026-08-01T10:00:00Z","weeklyRemaining":80,"tokensUsed":100}'
measurement_checkpoint='{"observedAt":"2026-08-01T10:01:30Z","weeklyRemaining":75,"tokensUsed":160}'
measurement_finish='{"observedAt":"2026-08-01T10:02:00Z","weeklyRemaining":74,"tokensUsed":180}'
expect_fail "$helper" measure finish "$tmp/measured.org" second-task "$measurement_finish"
expect_ok "$helper" measure start "$tmp/measured.org" first-outcome "$measurement_start"
expect_ok "$helper" measure start "$tmp/measured.org" second-task "$measurement_start"
expect_fail "$helper" measure start "$tmp/measured.org" second-task "$measurement_start"
expect_ok "$helper" measure checkpoint "$tmp/measured.org" second-task "$measurement_checkpoint"
measurement_before=$(cksum "$tmp/measured.org")
expect_ok "$helper" measure checkpoint "$tmp/measured.org" second-task "$measurement_checkpoint"
test "$measurement_before" = "$(cksum "$tmp/measured.org")" && pass || fail 'repeated checkpoint is idempotent'
expect_fail "$helper" measure checkpoint "$tmp/measured.org" second-task '{"tokensUsed":160}'
expect_contains "$tmp/measured.org" ':ELAPSED_SECONDS: 90'
expect_contains "$tmp/measured.org" ':WEEKLY_PERCENT_USED: 5'
expect_contains "$tmp/measured.org" ':TOKENS_USED: 60'
expect_ok "$helper" measure checkpoint "$tmp/measured.org" second-task '{"observedAt":"2026-08-01T10:01:30Z","weeklyRemaining":90,"tokensUsed":160}'
expect_contains "$tmp/measured.org" ':WEEKLY_PERCENT_USED: 0'
expect_ok "$helper" measure finish "$tmp/measured.org" second-task "$measurement_finish"
expect_contains "$tmp/measured.org" ':COMPLETED_AT: 2026-08-01T10:02:00Z'
expect_contains "$tmp/measured.org" ':WEEKLY_REMAINING_END: 74'
expect_contains "$tmp/measured.org" ':TOKENS_END: 180'
expect_ok "$helper" validate "$tmp/measured.org"

copy valid-multi.org 'measured plan with spaces.org'
measured_with_spaces="$tmp/measured plan with spaces.org"
expect_ok "$helper" measure start "$measured_with_spaces" second-task "$measurement_start"
expect_ok "$helper" measure checkpoint "$measured_with_spaces" second-task "$measurement_checkpoint"
expect_contains "$measured_with_spaces" ':ELAPSED_SECONDS: 90'

copy valid-multi.org measure-failure.org
measure_failure_before=$(cksum "$tmp/measure-failure.org")
measure_failure_bin="$tmp/measure-failure-bin"
mkdir -p "$measure_failure_bin"
printf '#!/bin/sh\nexit 1\n' > "$measure_failure_bin/chmod"
chmod +x "$measure_failure_bin/chmod"
expect_fail env PATH="$measure_failure_bin:$PATH" "$helper" measure start "$tmp/measure-failure.org" second-task "$measurement_start"
test "$measure_failure_before" = "$(cksum "$tmp/measure-failure.org")" && pass || fail 'failed measurement write leaves original unchanged'
test -z "$(find "$tmp" -maxdepth 1 -name 'measure-failure.org.tmp.*' -print -quit)" && pass || fail 'failed measurement write cleans temporary file'

copy valid-multi.org migrated.org
sed \
  -e '0,/:REVIEW_STATUS: UNREVIEWED/s//:REVIEW_STATUS: REVIEWED/' \
  -e 's/^\* WIP \[#A\]/\* DONE [#A]/' \
  -e 's/^\*\* WIP \[#B\]/\*\* DONE [#B]/' \
  "$tmp/migrated.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/migrated.org"
expect_ok "$helper" validate "$tmp/migrated.org"

for review_mutation in \
  '/:REVIEW_STATUS: UNREVIEWED/d' \
  '/:REVIEW_STATUS: UNREVIEWED/a:REVIEW_STATUS: REVIEWED' \
  's/:REVIEW_STATUS: UNREVIEWED/:REVIEW_STATUS: PENDING/' \
  's/:REVIEW_STATUS: UNREVIEWED/:REVIEW_STATUS: unreviewed/' \
  '/:ID: first-task/a:REVIEW_STATUS: UNREVIEWED'; do
  copy valid-minimal.org invalid-review.org
  sed "$review_mutation" "$tmp/invalid-review.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/invalid-review.org"
  expect_fail "$helper" validate "$tmp/invalid-review.org"
done

for skills_mutation in \
  '/:SKILLS:/d' \
  '/:SKILLS:/a:SKILLS: $make' \
  's/:SKILLS:.*/:SKILLS: gestalt:development-testing/' \
  's/:SKILLS:.*/:SKILLS: $make, $vite/' \
  's/:SKILLS:.*/:SKILLS: $make $make/' \
  '/:ID: first-task/a:SKILLS: $make'; do
  copy valid-minimal.org invalid-skills.org
  sed "$skills_mutation" "$tmp/invalid-skills.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/invalid-skills.org"
  expect_fail "$helper" validate "$tmp/invalid-skills.org"
done

for mutation in \
  '1d' \
  '1a#+TITLE: Duplicate' \
  's/^\*\* TODO/\*\*\* TODO/' \
  's/^\* TODO/\* WAIT/' \
  's/\[#A\] //' \
  's/:ID: first-task/:ID: bad_id/' \
  '/- Goal ::/d' \
  '/- Done when ::/d' \
  's/:ID: first-task/:ID: first-outcome/'; do
  copy valid-minimal.org invalid.org
  sed "$mutation" "$tmp/invalid.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/invalid.org"
  expect_fail "$helper" validate "$tmp/invalid.org"
done

copy valid-multi.org invalid.org
sed 's/^\* TODO \[#B\]/\* WIP [#B]/' "$tmp/invalid.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/invalid.org"
expect_fail "$helper" validate "$tmp/invalid.org"
copy valid-multi.org invalid.org
sed 's/^\* TODO \[#B\]/\* DONE [#B]/' "$tmp/invalid.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/invalid.org"
expect_fail "$helper" validate "$tmp/invalid.org"

expect_ok "$helper" next "$tmp/multi.org" l1
expect_contains "$tmp/out" 'first-outcome'
expect_ok "$helper" next "$tmp/multi.org" l2
expect_contains "$tmp/out" 'second-task'
expect_ok "$helper" summary "$tmp/multi.org"
expect_contains "$tmp/out" 'L1 WIP=1'
expect_contains "$tmp/out" 'L1 REVIEWED=1'
expect_contains "$tmp/out" 'L1 UNREVIEWED=1'
printf '%s\n' \
  'L1 TODO=1' \
  'L1 WIP=1' \
  'L1 DONE=0' \
  'L2 TODO=1' \
  'L2 WIP=1' \
  'L2 DONE=1' \
  'current  first-outcome [#WIP] First outcome' \
  'L1 REVIEWED=1' \
  'L1 UNREVIEWED=1' >"$tmp/expected-summary"
cmp -s "$tmp/expected-summary" "$tmp/out" && pass || fail 'summary preserves execution-state line order before review counts'
cp "$tmp/out" "$tmp/summary-output"
expect_ok "$helper" status "$tmp/multi.org"
cmp -s "$tmp/summary-output" "$tmp/out" && pass || fail 'status is a read-only compatibility alias for summary'
expect_ok "$helper" l2 "$tmp/multi.org" 'Second task|Run tests'
expect_contains "$tmp/out" 'second-task'
expect_fail "$helper" l2 "$tmp/multi.org" '['
expect_fail "$helper" l2 "$tmp/multi.org" 'no-such-text'

copy valid-multi.org projection.org
projection_before=$(cksum "$tmp/projection.org")
projection_status="$tmp/projection-status.json"
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$projection_status" "$helper" projection "$tmp/projection.org"
test "$projection_before" = "$(cksum "$tmp/projection.org")" && pass || fail 'projection never changes the source plan'
test ! -e "$projection_status" && pass || fail 'projection never publishes a status signal'
python3 -c '
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
assert document["explanation"] == "L1 1/2 — First outcome. Goal: Test order.. Current L2 2/2: Second task (WIP)"
assert document["plan"] == [
  {"step": "L1 1/2 — First outcome", "status": "in_progress"},
  {"step": "L1 2/2 — Second outcome", "status": "pending"},
]
assert sum(item["status"] == "in_progress" for item in document["plan"]) == 1
assert all("Test order" not in item["step"] for item in document["plan"])
assert all("Second task" not in item["step"] for item in document["plan"])
' "$tmp/out" && pass || fail 'projection has stable ordered tool-input statuses and active L2 context'

copy valid-multi.org projection-awaiting-review.org
sed -e 's/^\* WIP \[#A\]/\* DONE [#A]/' -e 's/^\*\* WIP \[#B\]/\*\* DONE [#B]/' "$tmp/projection-awaiting-review.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/projection-awaiting-review.org"
expect_ok "$helper" projection "$tmp/projection-awaiting-review.org"
python3 -c 'import json, sys; document=json.load(open(sys.argv[1], encoding="utf-8")); assert document["plan"][0]["status"] == "in_progress" and document["explanation"].startswith("Awaiting review.")' "$tmp/out" && pass || fail 'unreviewed completed work remains in progress for native plans'

copy valid-multi.org projection-complete.org
sed -e 's/^\* WIP \[#A\]/\* DONE [#A]/' -e 's/^\*\* WIP \[#B\]/\*\* DONE [#B]/' -e 's/^\* TODO \[#B\]/\* DONE [#B]/' -e 's/^\*\* TODO \[#A\]/\*\* DONE [#A]/' -e 's/:REVIEW_STATUS: UNREVIEWED/:REVIEW_STATUS: REVIEWED/g' "$tmp/projection-complete.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/projection-complete.org"
expect_ok "$helper" projection "$tmp/projection-complete.org"
python3 -c 'import json, sys; document=json.load(open(sys.argv[1], encoding="utf-8")); assert {item["status"] for item in document["plan"]} == {"completed"} and document["explanation"] == "No L1 is active. 2/2 L1 milestones are reviewed. Org state remains authoritative."' "$tmp/out" && pass || fail 'reviewed completed work is completed in native projection'

copy valid-minimal.org projection-special.org
sed 's/First outcome/Quoted "title" \\ slash ✓/' "$tmp/projection-special.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/projection-special.org"
expect_ok "$helper" projection "$tmp/projection-special.org"
python3 -c 'import json, sys; step=json.load(open(sys.argv[1], encoding="utf-8"))["plan"][0]["step"]; assert "Quoted" in step and "title" in step and "✓" in step' "$tmp/out" && pass || fail 'projection safely JSON-escapes special characters'

copy valid-multi.org projection-multiple-active.org
sed -e 's/^\* WIP \[#A\]/\* DONE [#A]/' -e 's/^\*\* WIP \[#B\]/\*\* DONE [#B]/' -e 's/^\* TODO \[#B\]/\* WIP [#B]/' -e 's/^\*\* TODO \[#A\]/\*\* WIP [#A]/' "$tmp/projection-multiple-active.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/projection-multiple-active.org"
expect_fail "$helper" projection "$tmp/projection-multiple-active.org"
expect_contains "$tmp/err" 'native projection has multiple in_progress L1 items'
expect_contains "$tmp/err" 'L1 1 first-outcome (DONE + UNREVIEWED)'
expect_contains "$tmp/err" 'L1 2 second-outcome (WIP)'
expect_contains "$tmp/err" 'review the earlier DONE + UNREVIEWED L1 before continuing the later WIP L1'

copy valid-multi.org review-order.org
sed \
  -e 's/^\* WIP \[#A\]/\* DONE [#A]/' \
  -e 's/^\*\* WIP \[#B\]/\*\* DONE [#B]/' \
  -e 's/^\* TODO \[#B\]/\* DONE [#B]/' \
  -e 's/^\*\* TODO \[#A\]/\*\* DONE [#A]/' \
  "$tmp/review-order.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/review-order.org"
expect_ok "$helper" next "$tmp/review-order.org" review
test "$(<"$tmp/out")" = ' first-outcome [#DONE] First outcome' && pass || fail 'next review selects the first completed unreviewed L1'
expect_ok "$helper" review "$tmp/review-order.org" first-outcome REVIEWED
expect_ok "$helper" next "$tmp/review-order.org" review
test "$(<"$tmp/out")" = ' second-outcome [#DONE] Second outcome' && pass || fail 'next review advances in plan order'
expect_ok "$helper" review "$tmp/review-order.org" second-outcome REVIEWED
expect_status 1 "$helper" next "$tmp/review-order.org" review
test ! -s "$tmp/out" && pass || fail 'next review emits no output when no review is pending'
expect_ok "$helper" summary "$tmp/review-order.org"
expect_contains "$tmp/out" 'L1 TODO=0'
expect_contains "$tmp/out" 'L1 WIP=0'
expect_contains "$tmp/out" 'L1 DONE=2'
expect_contains "$tmp/out" 'L2 TODO=0'
expect_contains "$tmp/out" 'L2 WIP=0'
expect_contains "$tmp/out" 'L2 DONE=3'
expect_contains "$tmp/out" 'L1 REVIEWED=2'
expect_contains "$tmp/out" 'L1 UNREVIEWED=0'

cp "$tmp/review-order.org" "$tmp/appended-review.org"
sed -n '/^\* DONE \[#B\] Second outcome/,$p' "$tmp/review-order.org" | sed \
  -e 's/Second outcome/Appended refinement/' \
  -e 's/second-outcome/appended-refinement/' \
  -e 's/Third task/Appended task/' \
  -e 's/third-task/appended-task/' \
  -e 's/:REVIEW_STATUS: REVIEWED/:REVIEW_STATUS: UNREVIEWED/' \
  >>"$tmp/appended-review.org"
expect_ok "$helper" validate "$tmp/appended-review.org"
expect_ok "$helper" next "$tmp/appended-review.org" review
test "$(<"$tmp/out")" = ' appended-refinement [#DONE] Appended refinement' && pass || fail 'appended unreviewed L1 is selected without selecting reviewed history'
expect_ok "$helper" summary "$tmp/appended-review.org"
expect_contains "$tmp/out" 'L1 REVIEWED=2'
expect_contains "$tmp/out" 'L1 UNREVIEWED=1'
expect_ok "$helper" next "$tmp/appended-review.org" review
test "$(<"$tmp/out")" = ' appended-refinement [#DONE] Appended refinement' && pass || fail 'rejected L1 remains pending without a review transition'
expect_ok "$helper" set "$tmp/appended-review.org" appended-refinement WIP --force
sed 's/- Goal :: Test order\./- Goal :: Correct the rejected refinement./' "$tmp/appended-review.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/appended-review.org"
expect_ok "$helper" set "$tmp/appended-review.org" appended-refinement DONE
expect_ok "$helper" next "$tmp/appended-review.org" review
test "$(<"$tmp/out")" = ' appended-refinement [#DONE] Appended refinement' && pass || fail 'corrected rejected L1 is selected for re-review'
expect_ok "$helper" review "$tmp/appended-review.org" appended-refinement REVIEWED
expect_status 1 "$helper" next "$tmp/appended-review.org" review
test ! -s "$tmp/out" && pass || fail 'accepted appended L1 leaves review current'

copy valid-minimal.org review-transitions.org
review_before=$(cksum "$tmp/review-transitions.org")
expect_fail "$helper" review "$tmp/review-transitions.org" first-outcome REVIEWED
test "$review_before" = "$(cksum "$tmp/review-transitions.org")" && pass || fail 'review rejects unfinished L1 without mutation'
expect_fail "$helper" review "$tmp/review-transitions.org" first-task REVIEWED
expect_contains "$tmp/err" 'ID first-task is not an L1'
expect_fail "$helper" review "$tmp/review-transitions.org" missing REVIEWED
expect_contains "$tmp/err" 'unknown ID missing'
expect_status 2 "$helper" review "$tmp/review-transitions.org" first-outcome PENDING
expect_ok "$helper" set "$tmp/review-transitions.org" first-outcome WIP
expect_fail "$helper" review "$tmp/review-transitions.org" first-outcome REVIEWED
expect_ok "$helper" set "$tmp/review-transitions.org" first-task WIP
expect_ok "$helper" set "$tmp/review-transitions.org" first-task DONE
expect_ok "$helper" set "$tmp/review-transitions.org" first-outcome DONE
chmod 640 "$tmp/review-transitions.org"
expect_ok "$helper" review "$tmp/review-transitions.org" first-outcome REVIEWED
expect_contains "$tmp/review-transitions.org" ':REVIEW_STATUS: REVIEWED'
test "$(stat -c '%a' "$tmp/review-transitions.org" 2>/dev/null || stat -f '%Lp' "$tmp/review-transitions.org")" = 640 && pass || fail 'review preserves mode'
expect_ok "$helper" review "$tmp/review-transitions.org" first-outcome UNREVIEWED
expect_contains "$tmp/review-transitions.org" ':REVIEW_STATUS: UNREVIEWED'
expect_contains "$tmp/review-transitions.org" '* DONE [#A] First outcome'
sed 's/- Goal :: Test the helper\./- Goal :: Corrected after explicit review reset./' "$tmp/review-transitions.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/review-transitions.org"
expect_ok "$helper" validate "$tmp/review-transitions.org"
expect_ok "$helper" review "$tmp/review-transitions.org" first-outcome REVIEWED
expect_ok "$helper" set "$tmp/review-transitions.org" first-outcome WIP --force
expect_contains "$tmp/review-transitions.org" ':REVIEW_STATUS: UNREVIEWED'
expect_contains "$tmp/review-transitions.org" '* WIP [#A] First outcome'
expect_ok "$helper" set "$tmp/review-transitions.org" first-outcome DONE
expect_ok "$helper" next "$tmp/review-transitions.org" review
test "$(<"$tmp/out")" = ' first-outcome [#DONE] First outcome' && pass || fail 'materially changed reviewed L1 returns to pending review'

copy valid-multi.org describe.org
expect_ok "$helper" describe "$tmp/describe.org" first-outcome
test "$(<"$tmp/out")" = $'L1 1/2 First outcome\nGoal: Test order.\nSkills: $gestalt:development-testing $make' && pass || fail 'describe prints stable L1 position, text, and skills'
expect_ok "$helper" describe "$tmp/describe.org" second-task
test "$(<"$tmp/out")" = $'L2 Second task\nWhy: Needed.' && pass || fail 'describe prints stable L2 text'
expect_fail "$helper" describe "$tmp/describe.org" missing
expect_contains "$tmp/err" 'unknown ID missing'
whitespace_plan="$tmp/plan with spaces.org"
copy valid-minimal.org 'plan with spaces.org'
sed \
  -e 's/First outcome/First outcome with  internal spaces/' \
  -e 's/- Goal :: Test the helper\./- Goal :: Text with  internal spaces./' \
  "$whitespace_plan" >"$tmp/changed" && mv "$tmp/changed" "$whitespace_plan"
expect_ok "$helper" describe "$whitespace_plan" first-outcome
test "$(<"$tmp/out")" = $'L1 1/1 First outcome with  internal spaces\nGoal: Text with  internal spaces.\nSkills: $gestalt:development-testing' && pass || fail 'describe output is position-aware and whitespace-safe'

describe_sentinel="$tmp/describe-output-was-evaluated"
adversarial_plan="$tmp/"$'plan %=\tline\nnext.org'
adversarial_title='Outcome %= with tab'
adversarial_title+=$'\t'
adversarial_title+='$(touch '"$describe_sentinel"') ; `touch '"$describe_sentinel"'` & | < >'
adversarial_goal='Purpose %= with tab'
adversarial_goal+=$'\t'
adversarial_goal+='$(touch '"$describe_sentinel"') ; $HOME * ? [x]'
awk -v title="$adversarial_title" -v goal="$adversarial_goal" '
  /^\* TODO \[#A\] First outcome$/ { print "* TODO [#A] " title; next }
  /^- Goal :: Test the helper\.$/ { print "- Goal :: " goal; next }
  { print }
' "$fixtures/valid-minimal.org" >"$adversarial_plan"
expect_ok "$helper" validate "$adversarial_plan"
expect_ok "$helper" describe "$adversarial_plan" first-outcome
{
  printf 'L1 1/1 %s\n' "$adversarial_title"
  printf 'Goal: %s\n' "$adversarial_goal"
  printf 'Skills: $gestalt:development-testing\n'
} >"$tmp/expected-describe"
cmp -s "$tmp/expected-describe" "$tmp/out" && pass || fail 'describe preserves adversarial text as data'
test ! -e "$describe_sentinel" && pass || fail 'describe output is never evaluated as shell code'

copy valid-minimal.org review-failure.org
expect_ok "$helper" set "$tmp/review-failure.org" first-outcome WIP
expect_ok "$helper" set "$tmp/review-failure.org" first-task WIP
expect_ok "$helper" set "$tmp/review-failure.org" first-task DONE
expect_ok "$helper" set "$tmp/review-failure.org" first-outcome DONE
review_failure_before=$(cksum "$tmp/review-failure.org")
review_failure_bin="$tmp/review-failure-bin"
mkdir -p "$review_failure_bin"
printf '#!/bin/sh\nexit 1\n' > "$review_failure_bin/chmod"
chmod +x "$review_failure_bin/chmod"
expect_fail env PATH="$review_failure_bin:$PATH" "$helper" review "$tmp/review-failure.org" first-outcome REVIEWED
test "$review_failure_before" = "$(cksum "$tmp/review-failure.org")" && pass || fail 'failed review write leaves original unchanged'
test -z "$(find "$tmp" -maxdepth 1 -name 'review-failure.org.tmp.*' -print -quit)" && pass || fail 'failed review write cleans temporary file'

copy valid-minimal.org state.org
chmod 640 "$tmp/state.org"
expect_ok "$helper" set "$tmp/state.org" first-outcome WIP
expect_ok "$helper" set "$tmp/state.org" first-task WIP
expect_ok "$helper" set "$tmp/state.org" first-task DONE
expect_ok "$helper" set "$tmp/state.org" first-outcome DONE
expect_fail "$helper" set "$tmp/state.org" first-outcome TODO
expect_fail "$helper" set "$tmp/state.org" missing TODO
test "$(stat -c '%a' "$tmp/state.org" 2>/dev/null || stat -f '%Lp' "$tmp/state.org")" = 640 && pass || fail 'set preserves mode'
copy valid-minimal.org forced.org
expect_ok "$helper" set "$tmp/forced.org" first-outcome WIP
expect_ok "$helper" set "$tmp/forced.org" first-outcome TODO --force
expect_fail "$helper" set "$tmp/forced.org" first-task WIP --force

agents_dir="$tmp/org-plan-test-agents"
profile="$agents_dir/org-plan-test-executor.toml"
expect_ok "$helper" prepare-executor --model gpt-5.4-mini --agents-dir "$agents_dir" --profile-name org-plan-test-executor
expect_contains "$tmp/out" "profile=$profile"
test -f "$profile" && pass || fail 'default executor profile exists'
expect_contains "$profile" 'name = "org-plan-test-executor"'
expect_contains "$profile" 'model = "gpt-5.4-mini"'
expect_contains "$profile" 'developer_instructions ='
expect_contains "$profile" 'You are the depth-one executor and the only code writer.'
expect_contains "$profile" 'report directly to the root director/reviewer'
test "$(stat -c '%a' "$profile" 2>/dev/null || stat -f '%Lp' "$profile")" = 600 && pass || fail 'new executor profile mode is 600'
chmod 640 "$profile"
expect_ok "$helper" prepare-executor --model gpt-5.6-terra --agents-dir "$agents_dir" --profile-name org-plan-test-executor
expect_contains "$profile" 'model = "gpt-5.6-terra"'
test "$(stat -c '%a' "$profile" 2>/dev/null || stat -f '%Lp' "$profile")" = 640 && pass || fail 'existing executor profile mode is preserved'
python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$profile" && pass || fail 'executor profile is parseable TOML'
before=$(cksum "$profile")
expect_fail "$helper" prepare-executor --model 'bad"value' --agents-dir "$agents_dir" --profile-name org-plan-test-executor
expect_contains "$tmp/err" 'invalid model: bad"value'
test "$before" = "$(cksum "$profile")" && pass || fail 'invalid model does not mutate profile'
expect_fail "$helper" prepare-executor --model gpt-5.6-terra --agents-dir "$agents_dir" --profile-name 'Bad_Profile'
expect_contains "$tmp/err" 'invalid profile name: Bad_Profile'
test "$before" = "$(cksum "$profile")" && pass || fail 'invalid profile name does not mutate profile'
test -z "$(find "$agents_dir" -name '.*.??????' -print -quit)" && pass || fail 'profile writer leaves no temporary files'
failure_bin="$tmp/failure-bin"
mkdir -p "$failure_bin"
printf '#!/bin/sh\nexit 1\n' > "$failure_bin/chmod"
chmod +x "$failure_bin/chmod"
write_failure_dir="$tmp/write-failure-agents"
expect_fail env PATH="$failure_bin:$PATH" "$helper" prepare-executor --agents-dir "$write_failure_dir"
test -z "$(find "$write_failure_dir" -type f -name '.*.??????' -print -quit)" && pass || fail 'profile writer cleans current temporary file on chmod failure'
interrupt_bin="$tmp/interrupt-bin"
mkdir -p "$interrupt_bin"
printf '#!/bin/sh\nkill -TERM "$PPID"\nsleep 1\nexit 1\n' > "$interrupt_bin/chmod"
chmod +x "$interrupt_bin/chmod"
interrupt_executor_dir="$tmp/interrupt-executor-agents"
expect_fail env PATH="$interrupt_bin:$PATH" "$helper" prepare-executor --agents-dir "$interrupt_executor_dir"
test -z "$(find "$interrupt_executor_dir" -type f -name '.*.??????' -print -quit)" && pass || fail 'interrupted executor preparation cleans current staged file'
interrupt_supervision_dir="$tmp/interrupt-supervision-agents"
expect_fail env PATH="$interrupt_bin:$PATH" "$helper" prepare-supervision --agents-dir "$interrupt_supervision_dir"
test -z "$(find "$interrupt_supervision_dir" -type f -name '.*.??????' -print -quit)" && pass || fail 'interrupted supervision preparation cleans current staged file'

mkdir_interrupt_bin="$tmp/mkdir-interrupt-bin"
mkdir -p "$mkdir_interrupt_bin"
real_mkdir=$(command -v mkdir)
printf '#!/bin/sh\nreal_mkdir=%s\n"$real_mkdir" "$@" || exit\ncase "$*" in *org-plan-stage.*) kill -TERM "$PPID" ;; esac\n' "$real_mkdir" > "$mkdir_interrupt_bin/mkdir"
chmod +x "$mkdir_interrupt_bin/mkdir"
for command in prepare-executor prepare-supervision; do
  creation_dir="$tmp/creation-$command-agents"
  expect_status 143 env PATH="$mkdir_interrupt_bin:$PATH" "$helper" "$command" --agents-dir "$creation_dir"
  test -z "$(find "$creation_dir" -name '.org-plan-stage.*' -print -quit)" && pass || fail "$command cleans a stage directory interrupted during creation"
  test ! -s "$tmp/out" && pass || fail "$command interruption prints no success result"
done

mv_interrupt_bin="$tmp/mv-interrupt-bin"
mkdir -p "$mv_interrupt_bin"
real_mv=$(command -v mv)
printf '#!/bin/sh\nreal_mv=%s\n"$real_mv" "$@" || exit\ncount=0\ntest ! -f "$MOVE_COUNTER" || count=$(cat "$MOVE_COUNTER")\ncount=$((count + 1))\nprintf "%%s\\n" "$count" > "$MOVE_COUNTER"\ntest "$count" -ne 1 || kill -TERM "$PPID"\n' "$real_mv" > "$mv_interrupt_bin/mv"
chmod +x "$mv_interrupt_bin/mv"

fresh_rollback_dir="$tmp/fresh-rollback-agents"
expect_status 143 env PATH="$mv_interrupt_bin:$PATH" MOVE_COUNTER="$tmp/fresh-moves" "$helper" prepare-supervision --agents-dir "$fresh_rollback_dir"
test -z "$(find "$fresh_rollback_dir" -maxdepth 1 -type f -name '*.toml' -print -quit)" && pass || fail 'interrupted fresh supervision install leaves no partial profiles'
test -z "$(find "$fresh_rollback_dir" -name '.org-plan-stage.*' -print -quit)" && pass || fail 'fresh supervision rollback cleans stage directory'
test ! -s "$tmp/out" && pass || fail 'fresh supervision rollback prints no success result'

legacy_rollback_dir="$tmp/legacy-rollback-agents"
expect_ok "$helper" prepare-executor --agents-dir "$legacy_rollback_dir"
printf 'legacy-old\n' > "$legacy_rollback_dir/org-plan-executor.toml"
chmod 640 "$legacy_rollback_dir/org-plan-executor.toml"
legacy_before=$(cksum "$legacy_rollback_dir/org-plan-executor.toml")
expect_status 143 env PATH="$mv_interrupt_bin:$PATH" MOVE_COUNTER="$tmp/legacy-moves" "$helper" prepare-executor --agents-dir "$legacy_rollback_dir"
test "$legacy_before" = "$(cksum "$legacy_rollback_dir/org-plan-executor.toml")" && pass || fail 'interrupted legacy install restores old profile'
test "$(stat -c '%a' "$legacy_rollback_dir/org-plan-executor.toml" 2>/dev/null || stat -f '%Lp' "$legacy_rollback_dir/org-plan-executor.toml")" = 640 && pass || fail 'legacy rollback preserves old mode'
test -z "$(find "$legacy_rollback_dir" -name '.org-plan-stage.*' -print -quit)" && pass || fail 'legacy rollback cleans stage directory'
test ! -s "$tmp/out" && pass || fail 'legacy rollback prints no success result'

supervision_rollback_dir="$tmp/supervision-rollback-agents"
expect_ok "$helper" prepare-supervision --agents-dir "$supervision_rollback_dir"
rollback_index=0
for role in reviewer executor; do
  rollback_index=$((rollback_index + 1))
  printf 'old-%s\n' "$role" > "$supervision_rollback_dir/org-plan-$role.toml"
  chmod "$((600 + rollback_index))" "$supervision_rollback_dir/org-plan-$role.toml"
done
rollback_before=$(cksum "$supervision_rollback_dir"/*.toml)
rollback_modes=$(for file in "$supervision_rollback_dir"/*.toml; do stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file"; done)
expect_status 143 env PATH="$mv_interrupt_bin:$PATH" MOVE_COUNTER="$tmp/supervision-moves" "$helper" prepare-supervision --agents-dir "$supervision_rollback_dir"
test "$rollback_before" = "$(cksum "$supervision_rollback_dir"/*.toml)" && pass || fail 'interrupted supervision install restores all old profiles'
test "$rollback_modes" = "$(for file in "$supervision_rollback_dir"/*.toml; do stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file"; done)" && pass || fail 'supervision rollback preserves all old modes'
test -z "$(find "$supervision_rollback_dir" -name '.org-plan-stage.*' -print -quit)" && pass || fail 'supervision rollback cleans stage directory'
test ! -s "$tmp/out" && pass || fail 'supervision rollback prints no success result'

for command in prepare-executor prepare-supervision; do
  for link_kind in valid dangling; do
    symlink_dir="$tmp/symlink-$command-$link_kind"
    mkdir -p "$symlink_dir"
    if [[ $command == prepare-executor ]]; then link_path="$symlink_dir/org-plan-executor.toml"; else link_path="$symlink_dir/org-plan-reviewer.toml"; fi
    link_target="$symlink_dir/target.toml"
    if [[ $link_kind == valid ]]; then printf 'unchanged-target\n' > "$link_target"; chmod 640 "$link_target"; link_value=$link_target; else link_value="$symlink_dir/missing-target.toml"; fi
    ln -s "$link_value" "$link_path"
    link_before=$(readlink "$link_path")
    target_before= target_mode=; [[ $link_kind == dangling ]] || { target_before=$(cksum "$link_target"); target_mode=$(stat -c '%a' "$link_target" 2>/dev/null || stat -f '%Lp' "$link_target"); }
    expect_fail "$helper" "$command" --agents-dir "$symlink_dir"
    test -L "$link_path" && test "$link_before" = "$(readlink "$link_path")" && pass || fail "$command preserves $link_kind destination symlink"
    [[ $link_kind == dangling ]] || { test "$target_before" = "$(cksum "$link_target")" && pass || fail "$command preserves symlink target"; }
    [[ $link_kind == dangling ]] || { test "$target_mode" = "$(stat -c '%a' "$link_target" 2>/dev/null || stat -f '%Lp' "$link_target")" && pass || fail "$command preserves symlink target mode"; }
    test -z "$(find "$symlink_dir" -name '.org-plan-stage.*' -print -quit)" && pass || fail "$command rejects symlink before staging"
    test ! -s "$tmp/out" && pass || fail "$command symlink rejection prints no success result"
  done
done

collision_bin="$tmp/collision-bin"
mkdir -p "$collision_bin"
printf '#!/bin/sh\nreal_mkdir=%s\ncase "$*" in *org-plan-stage.*) "$real_mkdir" "$@" || exit; for last do :; done; test "${COLLISION_NONEMPTY:-0}" != 1 || printf foreign > "$last/sentinel"; exit 1 ;; *) exec "$real_mkdir" "$@" ;; esac\n' "$real_mkdir" > "$collision_bin/mkdir"
chmod +x "$collision_bin/mkdir"
for command in prepare-executor prepare-supervision; do
  for collision_kind in empty nonempty; do
    collision_dir="$tmp/collision-$command-$collision_kind-agents"
    if [[ $collision_kind == nonempty ]]; then collision_nonempty=1; else collision_nonempty=0; fi
    expect_fail env PATH="$collision_bin:$PATH" COLLISION_NONEMPTY="$collision_nonempty" "$helper" "$command" --agents-dir "$collision_dir"
    foreign_stage=$(find "$collision_dir" -maxdepth 1 -type d -name '.org-plan-stage.*' -print -quit)
    test -n "$foreign_stage" && pass || fail "$command preserves foreign $collision_kind colliding stage directory"
    [[ $collision_kind == empty ]] || { test -f "$foreign_stage/sentinel" && pass || fail "$command preserves foreign collision sentinel"; }
    test ! -s "$tmp/out" && pass || fail "$command $collision_kind collision prints no success result"
  done
done

encoded_dir="$tmp/encoded agents%="
encoded_dir="$encoded_dir"$'\tline\nnext'
expect_ok "$helper" prepare-supervision --agents-dir "$encoded_dir"
test "$(wc -l < "$tmp/out")" = 1 && pass || fail 'encoded success output is exactly one record'
python3 -c 'import sys, urllib.parse; fields=dict(item.split("=", 1) for item in open(sys.argv[1], encoding="ascii").read().strip().split(" ")); expected=sys.argv[2]; assert urllib.parse.unquote(fields["executor_profile"]) == expected + "/org-plan-executor.toml"; assert urllib.parse.unquote(fields["root_reviewer_profile"]) == expected + "/org-plan-reviewer.toml"' "$tmp/out" "$encoded_dir" && pass || fail 'encoded profile paths round-trip without eval'
expect_contains "$tmp/out" '%20'
expect_contains "$tmp/out" '%25'
expect_contains "$tmp/out" '%3D'
expect_contains "$tmp/out" '%09'
expect_contains "$tmp/out" '%0A'
expect_ok "$helper" prepare-executor --agents-dir "$encoded_dir" --profile-name encoded-executor
test "$(wc -l < "$tmp/out")" = 1 && pass || fail 'legacy encoded success output is exactly one record'
python3 -c 'import sys, urllib.parse; fields=dict(item.split("=", 1) for item in open(sys.argv[1], encoding="ascii").read().strip().split(" ")); assert urllib.parse.unquote(fields["profile"]) == sys.argv[2] + "/encoded-executor.toml"' "$tmp/out" "$encoded_dir" && pass || fail 'legacy encoded profile path round-trips without eval'
expect_contains "$encoded_dir/encoded-executor.toml" 'verify every reference in that L1 SKILLS property is available'
expect_contains "$encoded_dir/encoded-executor.toml" 'load the mandatory $gestalt:context-mode baseline'
expect_contains "$encoded_dir/encoded-executor.toml" 'load exactly those declared task-specific skills, and load no other optional or task skill'
expect_contains "$encoded_dir/encoded-executor.toml" 'The baseline never needs to appear in the Org plan SKILLS property.'
expect_contains "$encoded_dir/encoded-executor.toml" 'Use host-native filesystem tools for governing instructions, small bounded reads, edits, mutations, and short command interaction'
expect_contains "$encoded_dir/encoded-executor.toml" 'Context-mode never writes or changes Org state.'
expect_contains "$encoded_dir/encoded-executor.toml" 'Stop without edits and report the unavailable reference'
expect_contains "$encoded_dir/encoded-executor.toml" 'The assignment is the entire L1, not one L2.'
expect_contains "$encoded_dir/encoded-executor.toml" 'progress updates, token usage, or elapsed time are non-terminal'
expect_contains "$encoded_dir/encoded-executor.toml" 'do not return a final report while implementation remains.'
expect_fail "$helper" prepare-executor --model
expect_contains "$tmp/err" 'usage: org-plan'
test ! -e "$tmp/.codex/agents/org-plan-executor.toml" && pass || fail 'tests avoid the default agents directory'

supervision_dir="$tmp/supervision-agents"
expect_ok "$helper" prepare-supervision --agents-dir "$supervision_dir"
expect_contains "$tmp/out" 'executor=org-plan-executor executor_model=gpt-5.6-terra'
expect_contains "$tmp/out" 'root_reviewer=org-plan-reviewer root_reviewer_model=gpt-5.6-sol'
expect_contains "$supervision_dir/org-plan-executor.toml" 'model = "gpt-5.6-terra"'
expect_contains "$supervision_dir/org-plan-executor.toml" 'You are the depth-one executor and the only code writer.'
expect_contains "$supervision_dir/org-plan-executor.toml" 'verify every reference in the assigned L1 Skills list is available'
expect_contains "$supervision_dir/org-plan-executor.toml" 'load the mandatory $gestalt:context-mode baseline'
expect_contains "$supervision_dir/org-plan-executor.toml" 'load exactly those declared task-specific skills, and load no other optional or task skill'
expect_contains "$supervision_dir/org-plan-executor.toml" 'The baseline never needs to appear in the Org plan Skills list.'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Use host-native filesystem tools for governing instructions, small bounded reads, edits, mutations, and short command interaction'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Context-mode never writes or changes Org state.'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Stop without edits and report the unavailable reference'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Keep all implementation and review-correction changes uncommitted until the root explicitly ACCEPTS the L1.'
expect_contains "$supervision_dir/org-plan-executor.toml" 'The assignment is the entire L1, not one L2.'
expect_contains "$supervision_dir/org-plan-executor.toml" 'immediately continue with the next actionable L2'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Continue until the L1 is DONE with full-suite evidence and ready for root review.'
expect_contains "$supervision_dir/org-plan-executor.toml" 'At that review boundary report evidence and await the root verdict'
expect_contains "$supervision_dir/org-plan-executor.toml" 'inspect git diff --cached --name-only'
expect_contains "$supervision_dir/org-plan-executor.toml" 'active Org Plan and every .gestalt/*.org path, including force-added paths'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Org Plans are never Git deliverables; no user request, repository instruction, or release workflow overrides this ban.'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Never create pre-review, fixup, or autosquash commits.'
expect_contains "$supervision_dir/org-plan-executor.toml" 'report directly to the root director/reviewer'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Return only concise structured evidence to the root director/reviewer'
expect_not_contains "$supervision_dir/org-plan-executor.toml" 'sandbox_mode ='
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'model = "gpt-5.6-sol"'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'sandbox_mode = "read-only"'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'You are the depth-zero read-only director/reviewer/supervisor in the user conversation.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Accepted-L1 reporting is a root-only turn boundary, not plan completion.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'gestalt_org_plan_checkpoint'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'l1Accepted'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'terminalReviewAccepted'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Completion, Review (including repaired REJECT findings), Verification'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'safe legacy continuous-root behavior'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Do not run prepare-supervision during ordinary supervised execution.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Reuse the exact supplied plan path'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Do not rediscover it with find or rg'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Do not probe helper source or help before starting'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Before any work, load the mandatory $gestalt:context-mode baseline'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'it never needs to appear in an Org plan SKILLS property.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Use host-native filesystem tools for governing instructions, small bounded reads, edits, mutations, and short command interaction'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Context-mode never writes or changes Org state.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'recommended root launch profile'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'directly spawn exactly one fresh depth-one org-plan executor per L1'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Name the L<a> executor with collaboration-safe task_name l<a>'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Use `L<a>/TOTAL — TITLE: STATUS`'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Never spawn an intermediate supervisor or a separate routine L1 reviewer; the required terminal whole-branch reviewer is the sole exception.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Keep one executor active and keep the root active.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Supervision is a completion loop, not a report relay.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'After every executor report, inspect the executor current state.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'If its L1 is partial and the executor stopped or became idle, call followup_task on that same executor before returning any root response.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'If the user asks for status, answer briefly and perform that continuation in the same turn; a status reply never consumes the required supervision action.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Review only the DONE + UNREVIEWED L1 selected by `org-plan next PLAN review`'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Treat an L2 completion, checkpoint, focused test, partial report, idle executor, self-described pause, token notice, or elapsed-time notice as non-terminal'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'never turn it into a final user response or wait for progress approval.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Continue until every L1 is DONE and REVIEWED and final gates pass.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Stop early only for a genuine external blocker'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Show brief user-facing status'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'L<a>/TOTAL — TITLE: STATUS'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Independently inspect its uncommitted diff against the starting commit'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'shared-code regression impact, and named evidence'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'explicit ACCEPT or REJECT verdict'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'return an explicit ACCEPT or REJECT verdict directly to the executor.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'On REJECT'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'On ACCEPT'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'require inspection of git diff --cached --name-only'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'active Org Plan and every .gestalt/*.org path, including force-added paths'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Org Plans are never Git deliverables; no user request, repository instruction, or release workflow overrides this ban.'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'spawn one fresh depth-one subagent with fork_turns=none, agent_type=worker, model=gpt-5.6-sol, and task_name=final_review'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Give it a general overview of the implemented Org Plan'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'severity-ranked whole-branch review of all implementation work'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'If it reports any P0 or P1 issue, order that same subagent to become the sole writer'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'fix every P0/P1, add regression coverage, run focused and full-suite checks'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'one conventional final-review correction commit'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Final acceptance requires this terminal review, no unresolved P0/P1'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'Never expose raw logs or complete executor transcripts to the user.'
test ! -e "$supervision_dir/org-plan-supervisor.toml" && pass || fail 'supervision preparation creates no intermediate supervisor profile'
for role in executor reviewer; do
  python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$supervision_dir/org-plan-$role.toml" && pass || fail "$role profile is parseable TOML"
  test "$(stat -c '%a' "$supervision_dir/org-plan-$role.toml" 2>/dev/null || stat -f '%Lp' "$supervision_dir/org-plan-$role.toml")" = 600 && pass || fail "new $role profile mode is 600"
  expect_not_contains "$supervision_dir/org-plan-$role.toml" 'Luna'
  expect_not_contains "$supervision_dir/org-plan-$role.toml" 'Terra'
  expect_not_contains "$supervision_dir/org-plan-$role.toml" 'Sol'
done
first_output=$(cat "$tmp/out")
expect_ok "$helper" prepare-supervision --agents-dir "$supervision_dir"
test "$first_output" = "$(cat "$tmp/out")" && pass || fail 'prepare-supervision is idempotent'

override_dir="$tmp/override-agents"
expect_ok "$helper" prepare-supervision --agents-dir "$override_dir" \
  --executor-model terra-test --reviewer-model sol-test \
  --executor-profile-name test-executor --reviewer-profile-name test-reviewer
expect_contains "$override_dir/test-executor.toml" 'model = "terra-test"'
expect_contains "$override_dir/test-reviewer.toml" 'model = "sol-test"'
expect_contains "$tmp/out" 'executor=test-executor executor_model=terra-test'
expect_contains "$tmp/out" 'root_reviewer=test-reviewer root_reviewer_model=sol-test'
expect_fail "$helper" prepare-supervision --agents-dir "$override_dir" --supervisor-model luna-test
expect_contains "$tmp/err" 'usage: org-plan'
expect_fail "$helper" prepare-supervision --agents-dir "$override_dir" --reviewer-model 'bad"model'
expect_contains "$tmp/err" 'invalid model: bad"model'
expect_fail "$helper" prepare-supervision --agents-dir "$override_dir" --executor-profile-name Bad_Name
expect_contains "$tmp/err" 'invalid profile name: Bad_Name'
expect_fail "$helper" prepare-supervision --agents-dir "$override_dir" --executor-profile-name same --reviewer-profile-name same
expect_contains "$tmp/err" 'profile names must be distinct'

failure_dir="$tmp/failure-agents"
mkdir -p "$failure_dir/org-plan-reviewer.toml"
expect_fail "$helper" prepare-supervision --agents-dir "$failure_dir"
expect_contains "$tmp/err" 'profile destination is not a regular file'
test ! -e "$failure_dir/org-plan-executor.toml" && pass || fail 'failed preparation does not install executor'
test -z "$(find "$failure_dir" -type f -name '.*.??????' -print -quit)" && pass || fail 'failed preparation cleans staged files'
test ! -s "$tmp/out" && pass || fail 'failed preparation prints no success result'

plan_format="$root/plugins/gestalt/skills/org-plan/references/plan-format.md"
cli_state="$root/plugins/gestalt/skills/org-plan/references/cli-state.md"
supervised="$root/plugins/gestalt/skills/org-plan/references/supervised-execution.md"

expect_contains "$skill" '## Choose a workflow'
expect_contains "$skill" '[Plan format](references/plan-format.md)'
expect_contains "$skill" '[CLI state machine](references/cli-state.md)'
expect_contains "$skill" '[Supervised execution](references/supervised-execution.md)'
expect_contains "$skill" 'one fresh depth-one'
expect_contains "$skill" '`gpt-5.6-sol` whole-branch reviewer'
expect_contains "$skill" '`agent_type=worker`, and `task_name=final_review`'
expect_contains "$skill" 'If it reports P0 or P1 issues, order that same reviewer'
expect_contains "$skill" 'to become the sole writer, fix every P0/P1'
expect_contains "$skill" 'Do not finish with an unresolved P0 or P1.'
expect_contains "$skill" 'Every L1 has exactly one non-empty `:SKILLS:` property'
expect_contains "$skill" '`$gestalt:context-mode` is an implicit execution baseline.'
expect_contains "$skill" 'Keep one writer. L2 changes remain uncommitted through L1 review.'
expect_contains "$skill" 'Execution is completion-driven. One executor owns the whole assigned L1,'
expect_contains "$skill" 'L2 completion, a checkpoint, a passing focused test, or a'
expect_contains "$skill" 'Routine progress, L2 completion, review readiness,'
expect_contains "$skill" 'Review only DONE + UNREVIEWED L1s.'
expect_contains "$skill" 'create exactly one conventional commit for the L1'
expect_contains "$skill" "<workspace-root>/.gestalt/<topic>.org"
expect_contains "$skill" 'A Git repository root never redefines the supplied'
expect_contains "$skill" 'git diff --cached --name-only'
expect_not_contains "$skill" 'Do not commit Org plan files unless the governing repository or user'
expect_contains "$skill" '## Manual execution loop'
expect_contains "$plan_format" '## L1 contract'
expect_contains "$plan_format" '## Storage boundary'
expect_contains "$plan_format" '<workspace-root>/.gestalt/<topic>.org'
expect_contains "$plan_format" 'Create the `.gestalt/` directory when absent.'
expect_contains "$plan_format" 'Do not substitute a nearest Git repository root'
expect_contains "$plan_format" 'No repository instruction, release workflow, or user request can override this'
expect_contains "$plan_format" 'git diff --cached --name-only'
expect_contains "$plan_format" 'L2 property drawers contain an `:ID:` but no `:SKILLS:`'
expect_contains "$plan_format" 'viewport sizes,'
expect_contains "$plan_format" 'org-plan measure start PLAN ID SNAPSHOT_JSON'
expect_contains "$cli_state" 'org-plan next PLAN review'
expect_contains "$cli_state" 'org-plan review PLAN L1_ID REVIEWED\|UNREVIEWED'
expect_contains "$cli_state" 'org-plan signal PLAN resync'
expect_contains "$cli_state" 'org-plan projection PLAN'
expect_contains "$cli_state" '`in_progress`'
expect_contains "$cli_state" 'Bash helpers and MCP code never invoke `update_plan`.'
expect_contains "$supervised" 'director (depth 0, org-plan-reviewer, Sol or Terra, read-only root)'
expect_contains "$supervised" 'executor (depth 1, only code writer)'
expect_contains "$supervised" 'fork_turns=none'
expect_contains "$supervised" 'Codex V1 agent depth defaults to one'
expect_contains "$supervised" 'The root director also owns supervisor and reviewer duties.'
expect_contains "$supervised" 'communication, directly launches each executor, enforces evidence gates'
expect_contains "$supervised" 'The root independently returns structured findings plus explicit ACCEPT or'
expect_contains "$supervised" 'Never relay raw logs or complete child transcripts upward.'
expect_contains "$supervised" 'L<a>/TOTAL — TITLE: STATUS'
expect_contains "$supervised" 'Routine review is agent-to-agent.'
expect_contains "$supervised" 'Supervision is a completion loop:'
expect_contains "$supervised" "After every executor report, inspect the executor's current state."
expect_contains "$supervised" 'If the L1'
expect_contains "$supervised" 'is partial and the executor stopped or became idle, call `followup_task` on'
expect_contains "$supervised" 'status reply does not satisfy the supervision action.'
expect_contains "$supervised" 'review` selects a DONE + UNREVIEWED L1,'
expect_contains "$supervised" 'Never review an'
expect_contains "$supervised" 'ineligible L1.'
expect_contains "$supervised" 'A partial report, idle executor, self-described pause, token or elapsed-time'
expect_contains "$supervised" 'End successfully only when every L1 is DONE and REVIEWED and final gates pass.'
expect_contains "$supervised" '## Terminal whole-branch review'
expect_contains "$supervised" '`task_name=final_review`'
expect_contains "$supervised" '`agent_type=worker`, `model=gpt-5.6-sol`'
expect_contains "$supervised" 'review the whole branch from the branch base through HEAD'
expect_contains "$supervised" 'If the report contains a P0 or P1, order that same subagent'
expect_contains "$supervised" 'Do not finish with an unresolved P0 or P1.'
expect_contains "$supervised" 'Never rely on inherited conversation context'
expect_contains "$supervised" 'Org Plan files are never Git deliverables.'
expect_contains "$supervised" 'git diff --cached --name-only'
expect_contains "$supervised" 'companion explanation separately'
expect_contains "$supervised" '## Accepted-L1 reporting boundary'
expect_contains "$supervised" 'An accepted L1 ends one root turn, not the plan.'
expect_contains "$supervised" 'L<a>/TOTAL — TITLE: ACCEPTED'
expect_contains "$supervised" 'kind: l1Accepted'
expect_contains "$supervised" '## Terminal whole-plan report'
expect_contains "$supervised" 'kind: terminalReviewAccepted'
expect_contains "$supervised" 'Plan terminal review: ACCEPTED'
expect_contains "$supervised" 'Residual findings: P2 or lower only.'
expect_contains "$readme" 'director (depth 0, org-plan-reviewer, Sol or Terra, read-only)'
expect_contains "$readme" 'Context-mode transports evidence; it does not spawn agents'
expect_contains "$readme" 'Each L1 also declares a non-empty `:SKILLS:` property'
expect_contains "$readme" 'Supervision is completion-driven. An executor owns its entire L1'
expect_contains "$readme" 'After every report, the root inspects executor state and'
expect_contains "$readme" 'immediately resumes the same executor when its L1 is partial'
expect_contains "$readme" 'It reviews only DONE + UNREVIEWED L1s and advances accepted work.'
expect_contains "$agents" '## Org Plan supervised workflow invariants'
expect_contains "$agents" 'The depth-zero root combines director, reviewer, and supervisor duties'
expect_contains "$agents" '`org-plan-reviewer` launch profile defaults to Sol; an already-running root'
expect_contains "$agents" 'keeps its CLI-selected model.'
expect_contains "$agents" 'Do not create an intermediate'
expect_contains "$agents" 'Every L1 must have exactly one non-empty `:SKILLS:` property and exactly one'
expect_contains "$agents" '`UNREVIEWED`; L2s must have neither.'
expect_contains "$agents" '`:SKILLS:` is a whitespace-separated list of exact `$skill` references chosen'
expect_contains "$agents" 'by comparing the L1 with the complete available skill catalog.'
expect_contains "$agents" '`$gestalt:context-mode`; every role loads it as a mandatory baseline.'
expect_contains "$agents" 'Each fresh L1 executor loads that baseline plus exactly the declared'
expect_contains "$agents" 'task-specific list before repository inspection or implementation and stops'
expect_contains "$agents" 'without edits if either is unavailable.'
expect_contains "$agents" '`REVIEWED` is valid only after reviewer'
expect_contains "$agents" 'Reopening a'
expect_contains "$agents" 'reviewed L1 as WIP resets it to `UNREVIEWED`; reset a completed reviewed L1'
expect_contains "$agents" 'explicitly before any material correction'
expect_contains "$agents" '`org-plan next PLAN review` to select the first DONE + UNREVIEWED L1'
expect_contains "$agents" '`org-plan review PLAN ID REVIEWED|UNREVIEWED` for durable transitions'
expect_contains "$agents" '`org-plan describe PLAN ID` for stable title plus Goal/Why text and L1 Skills.'
expect_contains "$agents" 'skips already REVIEWED milestones'
expect_contains "$agents" 'Keep one writer active.'
expect_contains "$agents" 'Treat supervision as a completion loop, not a report relay.'
expect_contains "$agents" 'The executor owns'
expect_contains "$agents" "After every executor report, inspect the executor's current state."
expect_contains "$agents" 'If its L1 is partial and the executor stopped or became idle, resume that same'
expect_contains "$agents" 'review only a DONE + UNREVIEWED L1'
expect_contains "$agents" 'Never turn a partial report into a final user response'
expect_contains "$agents" 'genuine external'
expect_contains "$agents" 'blocker remains that the root cannot resolve'
expect_contains "$agents" 'The read-only root delegates implementation and'
expect_contains "$agents" 'corrective edits only to the active executor.'
expect_contains "$agents" 'Org Plan files are workspace-local runtime coordination data and are never'
expect_contains "$agents" 'reject the commit if it contains the active plan or any `.gestalt/*.org` path.'
expect_contains "$agents" 'calls host `update_plan` with its exact ordered plan items'
expect_contains "$agents" 'Use host-native filesystem tools for governing instructions, small bounded'
expect_contains "$agents" 'for large or uncertain analysis, filtering, indexing, and retrieval.'
expect_contains "$agents" 'capture'
expect_contains "$agents" 'output outside conversational context and report only the command, exit'
expect_contains "$agents" 'status, pass/fail counts, affected scope, and smallest necessary failure'
expect_contains "$agents" '`$gestalt:context-mode` skill in every role, but do not install or enable'
expect_contains "$agents" 'Post brief human-facing status at supervision start'
expect_contains "$agents" 'emit exactly one concise root final answer with Completion, Review,'
expect_contains "$agents" 'Use `L<a>/TOTAL — TITLE: STATUS` when possible.'
expect_contains "$agents" '`org-plan describe` and lead with its position, title,'
expect_contains "$agents" 'first commit mention with its conventional subject and purpose; IDs and hashes'
expect_contains "$agents" '`task_name=final_review`'
expect_contains "$agents" 'Require a whole-branch review of all'
expect_contains "$agents" 'implementation work against the Org Plan'
expect_contains "$agents" 'reports any P0 or P1'
expect_contains "$agents" 'Final acceptance requires no unresolved'
expect_contains "$manifest" 'Dyne.org Gestalt'
expect_contains "$manifest" 'Org Plan'
expect_contains "$manifest" 'structured Codex workflows'

status_dir="$tmp/status-dir"
mkdir -m 700 "$status_dir"
status_plan="$status_dir/plan with \"quotes\" \\ backslash ✓.org"
copy valid-minimal.org "status-plan.org"
mv "$tmp/status-plan.org" "$status_plan"
status_file="$status_dir/status.json"
expect_ok "$helper" signal "$status_plan" absent-env
test ! -e "$status_file" && pass || fail 'signal is a no-op when status publishing is not configured'
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$status_plan" 'supervision-start'
python3 -c '
import datetime, json, os, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
assert document["schemaVersion"] == 1
assert document["planPath"] == os.path.realpath(sys.argv[2])
assert document["reason"] == "supervision-start"
assert set(document) == {"schemaVersion", "planPath", "reason", "updatedAt"}
datetime.datetime.fromisoformat(document["updatedAt"].replace("Z", "+00:00"))
' "$status_file" "$status_plan" && pass || fail 'signal writes the versioned canonical JSON envelope'
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" supervision-start "$status_plan"
python3 -c 'import json, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["reason"] == "supervision-start"' "$status_file" && pass || fail 'supervision-start is a compatibility alias for the lifecycle signal'
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$status_plan" authoring-start
python3 -c 'import json, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["reason"] == "authoring-start"' "$status_file" && pass || fail 'authoring-start preserves its Plan-tab signal reason'
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$status_plan" work-start
python3 -c 'import json, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["reason"] == "work-start"' "$status_file" && pass || fail 'resumed work preserves its Plan-tab signal reason'
directory_status_dir="$tmp/directory-status/session-a"
mkdir -m 700 -p "$directory_status_dir"
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_DIRECTORY="$directory_status_dir" "$helper" signal "$status_plan" supervision-start
directory_status_file=$(find "$directory_status_dir" -maxdepth 1 -type f -name '*.plan-status.json' -print -quit)
python3 -c 'import hashlib, json, os, pathlib, sys; plan=os.path.realpath(sys.argv[2]); expected=hashlib.sha256(plan.encode()).hexdigest()+".plan-status.json"; assert pathlib.Path(sys.argv[1]).name == expected; assert json.load(open(sys.argv[1], encoding="utf-8"))["planPath"] == plan' "$directory_status_file" "$status_plan" && pass || fail 'directory publication derives a plan-specific opaque status filename'
copy valid-minimal.org second-status-plan.org
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_DIRECTORY="$directory_status_dir" "$helper" signal "$tmp/second-status-plan.org" supervision-start
test "$(find "$directory_status_dir" -maxdepth 1 -type f -name '*.plan-status.json' | wc -l)" = 2 && pass || fail 'different Org plans retain distinct status files in one session'
final_plan_link="$status_dir/final-plan-link.org"
ln -s "$status_plan" "$final_plan_link"
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$final_plan_link" final-plan-symlink
python3 -c 'import json, os, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["planPath"] == os.path.realpath(sys.argv[2])' "$status_file" "$final_plan_link" && pass || fail 'final plan symlink publishes its true canonical target path'
linked_parent="$tmp/status-parent-link"
ln -s "$status_dir" "$linked_parent"
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$linked_parent/${status_plan##*/}" parent-symlink
python3 -c 'import json, os, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["planPath"] == os.path.realpath(sys.argv[2])' "$status_file" "$linked_parent/${status_plan##*/}" && pass || fail 'symlinked plan parent publishes its true canonical path'
test "$(stat -c '%a' "$status_file" 2>/dev/null || stat -f '%Lp' "$status_file")" = 600 && pass || fail 'status signal uses restrictive permissions'
old_status_inode=$(stat -c '%i' "$status_file" 2>/dev/null || stat -f '%i' "$status_file")
status_reason='resync\backslash'
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$status_plan" "$status_reason"
new_status_inode=$(stat -c '%i' "$status_file" 2>/dev/null || stat -f '%i' "$status_file")
test "$old_status_inode" != "$new_status_inode" && pass || fail 'status signal atomically replaces the prior document'
python3 -c 'import json, os, sys; document=json.load(open(sys.argv[1], encoding="utf-8")); assert document["reason"] == sys.argv[2] and document["planPath"] == os.path.realpath(sys.argv[3])' "$status_file" "$status_reason" "$status_plan" && pass || fail 'repeated signal JSON round-trips backslashes and replaces the complete document'
ln -s "$status_dir/redirected.json" "$status_dir/symlink.json"
expect_fail env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_dir/symlink.json" "$helper" signal "$status_plan" hostile
expect_contains "$tmp/err" 'status file must not be a symlink'
test ! -e "$status_dir/redirected.json" && pass || fail 'symlink status destination cannot redirect writes'
unsafe_status_dir="$tmp/unsafe-status-dir"
mkdir -m 777 "$unsafe_status_dir"
expect_fail env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$unsafe_status_dir/status.json" "$helper" signal "$status_plan" unsafe
expect_contains "$tmp/err" 'unsafe status file directory'
interrupt_bin="$tmp/status-interrupt-bin"
mkdir -m 700 "$interrupt_bin"
printf '#!/bin/sh\nkill -TERM "$PPID"\nexit 1\n' >"$interrupt_bin/mv"
chmod +x "$interrupt_bin/mv"
expect_fail env PATH="$interrupt_bin:$PATH" GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$status_plan" interrupted
test -z "$(find "$status_dir" -maxdepth 1 -name '.status.json.tmp.*' -print -quit)" && pass || fail 'interrupted signal cleans its status temporary file'
test -f "$status_file" && pass || fail 'interrupted signal preserves the prior complete status file'
rm -rf "$interrupt_bin"
chmod 700 "$unsafe_status_dir"
rm -rf "$unsafe_status_dir"

copy valid-minimal.org implicit-status.org
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" set "$tmp/implicit-status.org" first-outcome WIP
python3 -c 'import json, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["reason"] == "set:first-outcome:WIP"' "$status_file" && pass || fail 'successful set publishes its stable target reason'
copy valid-minimal.org implicit-warning.org
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_dir/missing/status.json" "$helper" set "$tmp/implicit-warning.org" first-outcome WIP
expect_contains "$tmp/err" 'warning: plan status not published'
expect_contains "$tmp/implicit-warning.org" '* WIP [#A] First outcome'

lifecycle_plan="$tmp/lifecycle.org"
copy valid-minimal.org lifecycle.org
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$lifecycle_plan" supervision-start
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" set "$lifecycle_plan" first-outcome WIP
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" l2 "$lifecycle_plan" first-task WIP
python3 -c 'import json, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["reason"] == "l2:first-task:WIP"' "$status_file" && pass || fail 'L2 WIP publishes exactly one L2 lifecycle reason'
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" l2 "$lifecycle_plan" first-task DONE
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" set "$lifecycle_plan" first-outcome DONE
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" review "$lifecycle_plan" first-outcome REVIEWED
python3 -c 'import json, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["reason"] == "review:first-outcome:REVIEWED"' "$status_file" && pass || fail 'review publishes its stable target reason'
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" review "$lifecycle_plan" first-outcome UNREVIEWED
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" review "$lifecycle_plan" first-outcome REVIEWED
expect_ok env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" set "$lifecycle_plan" first-outcome WIP --force
python3 -c 'import json, sys; assert json.load(open(sys.argv[1], encoding="utf-8"))["reason"] == "set:first-outcome:WIP"' "$status_file" && pass || fail 'reopen after review publishes after the durable state reset'
status_before=$(cksum "$status_file")
copy valid-minimal.org malformed-status.org
sed 's/^\* TODO /\* WAIT /' "$tmp/malformed-status.org" >"$tmp/changed" && mv "$tmp/changed" "$tmp/malformed-status.org"
expect_fail env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" signal "$tmp/malformed-status.org" bad
test "$status_before" = "$(cksum "$status_file")" && pass || fail 'malformed plans never advance the status document'
expect_fail env GESTALT_MOBILE_ORG_PLAN_STATUS_FILE="$status_file" "$helper" l2 "$lifecycle_plan" missing WIP
test "$status_before" = "$(cksum "$status_file")" && pass || fail 'unknown transition IDs never advance the status document'
expect_ok "$helper" l2 "$lifecycle_plan" 'First task'
test ! -e "$tmp/status-without-publish.json" && pass || fail 'read-only L2 selection does not publish'
expect_contains "$cli_state" '`org-plan signal PLAN supervision-start`'
expect_contains "$cli_state" '`org-plan signal PLAN authoring-start`'
expect_contains "$cli_state" '`org-plan signal PLAN work-start`'
expect_contains "$plan_format" 'org-plan measure start PLAN ID SNAPSHOT_JSON'
expect_contains "$plan_format" 'Checkpoint the active'
expect_contains "$cli_state" '`org-plan set PLAN L1_ID WIP\|DONE`'
expect_contains "$cli_state" '`org-plan l2 PLAN L2_ID WIP\|DONE`'
expect_contains "$skill" 'Use helper commands for TODO and review transitions'
expect_contains "$skill" 'Do not run `prepare-supervision` during ordinary supervision'
expect_contains "$supervised" 'Reuse the exact supplied plan path'
expect_contains "$supervised" 'Do not rediscover it with `find` or `rg`'
expect_contains "$supervised" 'The first tool call reads this skill completely and performs no other command'
expect_contains "$supervised" 'Do not probe helper source or help before starting'
expect_contains "$agents" 'Do not run `prepare-supervision` during ordinary supervised execution'
expect_contains "$cli_state" '`org-plan signal PLAN resync`'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'org-plan signal PLAN supervision-start'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'The first tool call reads the org-plan skill completely and performs no other command'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'org-plan signal PLAN authoring-start'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'org-plan signal PLAN work-start'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'org-plan measure start|checkpoint|finish PLAN ID SNAPSHOT_JSON'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'direct TODO keyword or property edits are forbidden'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'org-plan l2 PLAN L2_ID WIP|DONE'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'the active root runs org-plan projection PLAN and makes the host-owned update_plan call with its exact plan items'
expect_contains "$supervision_dir/org-plan-reviewer.toml" 'If update_plan is absent or fails, warn once, keep Org state authoritative'
expect_contains "$supervision_dir/org-plan-executor.toml" 'org-plan set PLAN L1_ID WIP|DONE'
expect_contains "$supervision_dir/org-plan-executor.toml" 'org-plan signal PLAN resync'
expect_contains "$supervision_dir/org-plan-executor.toml" 'org-plan signal PLAN authoring-start'
expect_contains "$supervision_dir/org-plan-executor.toml" 'org-plan signal PLAN work-start'
expect_contains "$supervision_dir/org-plan-executor.toml" 'org-plan measure start|checkpoint|finish PLAN ID SNAPSHOT_JSON'
expect_contains "$supervision_dir/org-plan-executor.toml" 'Executors report mutations and never invoke host update_plan or create a competing native projection'
expect_contains "$encoded_dir/encoded-executor.toml" 'org-plan signal PLAN authoring-start'
expect_contains "$encoded_dir/encoded-executor.toml" 'org-plan signal PLAN work-start'
expect_contains "$encoded_dir/encoded-executor.toml" 'org-plan measure start|checkpoint|finish PLAN ID SNAPSHOT_JSON'
expect_contains "$encoded_dir/encoded-executor.toml" 'Status publication is optional when neither GESTALT_MOBILE_ORG_PLAN_STATUS_DIRECTORY nor the legacy GESTALT_MOBILE_ORG_PLAN_STATUS_FILE is present.'

if [ "$failures" -ne 0 ]; then printf '%s passed, %s failed\n' "$passes" "$failures"; exit 1; fi
printf '%s passed\n' "$passes"
