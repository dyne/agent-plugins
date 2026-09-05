#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/release-artifacts-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

version=$(python3 - "$root/plugins/gestalt/.codex-plugin/plugin.json" <<'PY'
import json
import sys
from pathlib import Path

print(json.loads(Path(sys.argv[1]).read_text())["version"])
PY
)
tag="v$version"
artifacts="$tmp/dist"

"$root/scripts/build-release-artifacts.sh" "$tag" "$artifacts"

python3 - "$root" "$artifacts" "$tag" <<'PY'
import hashlib
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
artifacts = Path(sys.argv[2])
tag = sys.argv[3]
skills = sorted(path.parent.name for path in (root / "plugins/gestalt/skills").glob("*/SKILL.md"))
expected = {f"gestalt-agents-{tag}.zip"}
actual = {path.name for path in artifacts.glob("*.zip")}
assert actual == expected, (actual, expected)

def regular_entries(archive: Path) -> set[str]:
    with zipfile.ZipFile(archive) as bundle:
        names = {entry.filename for entry in bundle.infolist() if not entry.is_dir()}
    for name in names:
        path = PurePosixPath(name)
        assert not path.is_absolute(), name
        assert ".." not in path.parts, name
    return names

bundle_entries = regular_entries(artifacts / f"gestalt-agents-{tag}.zip")
assert ".agents/plugins/marketplace.json" in bundle_entries
assert "gestalt-setup.sh" in bundle_entries
assert "README.md" in bundle_entries
assert "USAGE.md" in bundle_entries
assert "plugins/gestalt/.codex-plugin/plugin.json" in bundle_entries
assert "plugins/gestalt/.mcp.json" in bundle_entries
assert "plugins/context-mode/.codex-plugin/plugin.json" in bundle_entries
assert "plugins/context-mode/.mcp.json" in bundle_entries
assert "plugins/context-mode/package.json" in bundle_entries
assert {f"plugins/gestalt/skills/{skill}/SKILL.md" for skill in skills} <= bundle_entries

checksum_lines = (artifacts / "SHA256SUMS").read_text().splitlines()
assert len(checksum_lines) == len(expected)
for line in checksum_lines:
    digest, name = line.split("  ", 1)
    payload = (artifacts / name).read_bytes()
    assert name in expected
    assert hashlib.sha256(payload).hexdigest() == digest

tracked = subprocess.check_output(
    [
        "git", "-C", str(root), "ls-tree", "-r", "--name-only", "HEAD", "--",
        ".agents/plugins/marketplace.json", "README.md", "USAGE.md", "gestalt-setup.sh",
        "plugins/gestalt", "plugins/context-mode",
    ],
    text=True,
).splitlines()
assert set(tracked) == bundle_entries
PY

if "$root/scripts/build-release-artifacts.sh" "$tag" "$artifacts" 2>/dev/null; then
  printf 'packager unexpectedly accepted an existing output path\n' >&2
  exit 1
fi
if "$root/scripts/build-release-artifacts.sh" latest "$tmp/latest" 2>/dev/null; then
  printf 'packager unexpectedly accepted an invalid release tag\n' >&2
  exit 1
fi
if "$root/scripts/build-release-artifacts.sh" v1.0.0 "$tmp/v1" 2>/dev/null; then
  printf 'packager unexpectedly accepted a pre-v2 release tag\n' >&2
  exit 1
fi

printf 'release marketplace bundle is complete\n'
