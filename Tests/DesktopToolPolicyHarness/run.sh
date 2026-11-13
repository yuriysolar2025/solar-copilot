#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${TMPDIR:-/tmp}/DesktopToolPolicyHarness"

xcrun swiftc \
  "$root/Sources/SolarCopilot/MacDesktopToolPolicy.swift" \
  "$root/Tests/DesktopToolPolicyHarness/main.swift" \
  -framework CoreGraphics \
  -o "$out"

"$out"
