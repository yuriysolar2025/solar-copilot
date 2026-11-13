#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${TMPDIR:-/tmp}/AltronBargeInHarness"

xcrun swiftc \
  "$root/Sources/SolarCopilot/NativeRealtimeTransport.swift" \
  "$root/Tests/AltronBargeInHarness/AudioRecorderStub.swift" \
  "$root/Tests/AltronBargeInHarness/main.swift" \
  -framework AVFoundation \
  -framework Speech \
  -o "$out"

"$out"
