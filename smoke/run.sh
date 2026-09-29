#!/usr/bin/env bash
# Run the SDK smoke test. Usage: smoke/run.sh   (from repo root or from smoke/)
# Requires a Godot 4 binary on PATH as `godot4` or `godot`, or set GODOT=/path/to/godot
set -euo pipefail
cd "$(dirname "$0")"
GODOT="${GODOT:-$(command -v godot4 || command -v godot || true)}"
[ -n "$GODOT" ] || { echo "Godot 4 binary not found; set GODOT=/path/to/godot" >&2; exit 2; }

# Fresh copy of the addon as it sits in the repo
rm -rf addons
mkdir -p addons
cp -r ../addons/cheddaboards addons/cheddaboards

# First run needs an import pass so the autoload resolves headlessly
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

"$GODOT" --headless --path . smoke.tscn
