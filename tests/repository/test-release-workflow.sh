#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/release-workflow-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
ruby -ryaml -rjson -e 'File.write(ARGV[1], JSON.generate(YAML.safe_load_file(ARGV[0], aliases: false)))' \
  "$root/.github/workflows/release.yml" "$tmp/workflow.json"
ruby -ryaml -rjson -e 'File.write(ARGV[1], JSON.generate(YAML.safe_load_file(ARGV[0], aliases: false)))' \
  "$root/.github/workflows/test.yml" "$tmp/test-workflow.json"
python3 - "$root/.github/workflows/release.yml" "$tmp/workflow.json" \
  "$root/.github/workflows/test.yml" "$tmp/test-workflow.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text()
workflow = json.loads(Path(sys.argv[2]).read_text())
test_source = Path(sys.argv[3]).read_text()
test_workflow = json.loads(Path(sys.argv[4]).read_text())
trigger = workflow.get("on", workflow.get("true"))
test_trigger = test_workflow.get("on", test_workflow.get("true"))

assert workflow["name"] == "Release"
assert trigger == {"push": {"branches": ["main"]}}
assert workflow["permissions"] == {"contents": "read"}
assert workflow["concurrency"] == {
    "group": "release-${{ github.repository }}",
    "cancel-in-progress": False,
}

assert workflow["jobs"]["test"] == {"uses": "./.github/workflows/test.yml"}
release_job = workflow["jobs"]["release"]
assert release_job["needs"] == "test"
assert release_job["permissions"] == {"contents": "write"}

steps = release_job["steps"]
checkout = next(step for step in steps if step.get("uses") == "actions/checkout@v7")
assert checkout["with"]["fetch-depth"] == 0

baseline = next(step for step in steps if step.get("id") == "baseline")
release_tag_filter = r"^v([2-9]|[1-9][0-9]+)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
assert release_tag_filter in baseline["run"]
assert "^v(0|[1-9][0-9]*)" not in baseline["run"]
assert "has_tag=false" in baseline["run"]

semver = next(step for step in steps if step.get("id") == "semver")
assert semver["uses"] == "ietf-tools/semver-action@v1"
assert semver["if"] == "steps.baseline.outputs.has_tag == 'true'"
assert semver["with"]["token"] == "${{ github.token }}"
assert semver["with"]["branch"] == "main"
assert semver["with"]["majorList"] == ""
assert semver["with"]["minorList"] == "feat, feature"
assert semver["with"]["patchList"] == "fix, bugfix, perf, refactor, test, tests"
assert semver["with"]["skipInvalidTags"] is True
assert semver["with"]["tagFilter"] == release_tag_filter
assert semver["with"]["maxTagsToFetch"] == 100
assert semver["with"]["noNewCommitBehavior"] == "current"
assert semver["with"]["noVersionBumpBehavior"] == "current"

release = next(step for step in steps if step.get("id") == "release")
assert release["env"]["NEXT_VERSION"] == "${{ steps.semver.outputs.nextStrict }}"
assert "tag=v2.0.0" in release["run"]
assert "version=2.0.0" in release["run"]
assert release_tag_filter in release["run"]
assert "tag=v0.1.0" not in release["run"]
assert "major|minor|patch) should_release=true" in release["run"]
assert "none) should_release=false" in release["run"]
assert "printf 'tag=%s\\n' \"$tag\"" in release["run"]
assert "printf 'version=%s\\n' \"$version\"" in release["run"]
assert "printf 'should_release=%s\\n' \"$should_release\"" in release["run"]
assert release["run"].count('>>"$GITHUB_OUTPUT"') == 1

synchronize = next(
    step for step in steps if step.get("name") == "Synchronize plugin manifests"
)
commit = next(
    step for step in steps if step.get("name") == "Commit synchronized plugin versions"
)
build = next(
    step for step in steps if step.get("name") == "Build installable release bundle"
)
publish = next(
    step for step in steps if step.get("name") == "Tag and atomically publish release"
)
github_release = next(
    step for step in steps if step.get("name") == "Publish GitHub release"
)
release_guard = "steps.release.outputs.should_release == 'true'"
assert synchronize["if"] == release_guard
assert commit["if"] == release_guard
assert build["if"] == release_guard
assert publish["if"] == release_guard
assert github_release["if"] == release_guard
assert 'scripts/set-plugin-version.py "$VERSION"' in synchronize["run"]
for versioned_path in (
    "plugins/gestalt/.codex-plugin/plugin.json",
    "plugins/context-mode/.codex-plugin/plugin.json",
    "plugins/context-mode/package.json",
):
    assert versioned_path in synchronize["run"]
assert "Downstream package version" in synchronize["run"]
assert "tests/plugins/context-mode/test-upstream-vendor.sh" in synchronize["run"]
assert "git config user.name github-actions[bot]" in commit["run"]
assert "release_paths=(" in commit["run"]
assert 'git diff --quiet -- "${release_paths[@]}"' in commit["run"]
assert 'git add -- "${release_paths[@]}"' in commit["run"]
assert "context-mode-codex-hardening-4b1348d.sha256" in commit["run"]
assert 'git commit -m "chore(release): $TAG [skip ci]"' in commit["run"]
assert build["env"]["TAG"] == "${{ steps.release.outputs.tag }}"
assert build["run"] == 'scripts/build-release-artifacts.sh "$TAG" dist'
assert 'git tag "$TAG" HEAD' in publish["run"]
assert 'git push --atomic origin HEAD:main "refs/tags/$TAG"' in publish["run"]
assert github_release["env"] == {
    "GH_TOKEN": "${{ github.token }}",
    "TAG": "${{ steps.release.outputs.tag }}",
}
assert 'gh release create "$TAG" dist/*' in github_release["run"]
assert "--verify-tag --generate-notes --title \"$TAG\"" in github_release["run"]
assert (
    steps.index(synchronize)
    < steps.index(commit)
    < steps.index(build)
    < steps.index(publish)
    < steps.index(github_release)
)
assert source.count(release_guard) == 5
assert "chore" not in semver["with"]["minorList"]
assert "chore" not in semver["with"]["patchList"]
assert "GITHUB_TOKEN pushes do not recursively trigger" in source
assert "Protected main" in source

assert test_workflow["name"] == "Test"
assert test_trigger == {
    "workflow_call": None,
    "pull_request": None,
}
assert test_workflow["permissions"] == {"contents": "read"}
matrix_job = test_workflow["jobs"]["test"]
assert matrix_job["runs-on"] == "${{ matrix.os }}"
assert matrix_job["strategy"] == {
    "fail-fast": False,
    "matrix": {"os": ["ubuntu-latest", "macos-latest"]},
}
matrix_steps = matrix_job["steps"]
checkout = next(step for step in matrix_steps if step.get("uses") == "actions/checkout@v7")
node = next(step for step in matrix_steps if step.get("uses") == "actions/setup-node@v7")
bun = next(step for step in matrix_steps if step.get("uses") == "oven-sh/setup-bun@v2")
assert node["with"]["node-version"] == "22.12.0"
assert not any(step.get("uses", "").startswith("actions/setup-go@") for step in matrix_steps)
assert bun["with"]["bun-version"] == "1.3.14"
codex = next(step for step in matrix_steps if step.get("name") == "Install current Codex CLI")
assert codex["run"] == "npm install --global @openai/codex@latest"
assert any(step.get("if") == "runner.os == 'Linux'" and "shellcheck" in step.get("run", "") for step in matrix_steps)
assert any(
    step.get("if") == "runner.os == 'macOS'"
    and "coreutils" in step.get("run", "")
    and "gnu-sed" in step.get("run", "")
    for step in matrix_steps
)
actionlint = next(step for step in matrix_steps if step.get("name") == "Validate GitHub Actions workflows")
assert actionlint["if"] == "runner.os == 'Linux'"
assert actionlint["env"] == {
    "ACTIONLINT_VERSION": "1.7.12",
    "ACTIONLINT_SHA256": "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
}
assert "rhysd/actionlint/releases/download" in actionlint["run"]
assert "sha256sum --check --strict" in actionlint["run"]
assert "go install" not in actionlint["run"]
validation = next(step for step in matrix_steps if step.get("name") == "Run complete validation")
assert validation["run"] == "bash tests/ci.sh"
assert "tests/run.sh" not in test_source
PY

printf 'release workflow contract is valid\n'
