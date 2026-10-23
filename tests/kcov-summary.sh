#!/usr/bin/env bash
# tests/kcov-summary.sh <coverage.json>
#
# Print "<percent> <covered> <total>" for ufw-docker ITSELF, or "" "" 0 when
# the report has no entry for it.
#
# Why not read the report's aggregate: the upgrade test writes the previous
# revision of the tool to a temp file, and `--include-pattern=ufw-docker`
# matched that too. The report then held two files and the aggregate blended
# them -- publishing "57.79% (1065 of 1843)" when the tool's own figure was
# 78.84% (734 of 931). Not a false green, but a wrong number presented with
# exactly the confidence of a right one.
#
# A separate script rather than a heredoc inside the workflow: a nested
# heredoc in a YAML block scalar has to stay indented or it terminates the
# block, which it duly did. This is also testable on its own, which the
# inline version was not.
set -uo pipefail

JSON="${1:-}"
[ -n "$JSON" ] && [ -r "$JSON" ] || { echo "  0"; exit 0; }

python3 - "$JSON" <<'PY'
import json, sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("", "", 0)
    raise SystemExit

for f in data.get("files", []):
    # endswith("/ufw-docker") and not "-prev": match the tool, never a copy
    # of it that some test happened to leave lying around.
    if f.get("file", "").endswith("/ufw-docker"):
        print(f.get("percent_covered", ""), f.get("covered_lines", ""), f.get("total_lines", 0))
        break
else:
    print("", "", 0)
PY
