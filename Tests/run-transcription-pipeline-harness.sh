#!/bin/zsh -f
set -e
cd "$(dirname "$0")/.."
OUT="/tmp/solar-copilot-transcription-pipeline-harness"
swiftc \
  -parse-as-library \
  Sources/SolarCopilot/TranscriptionPipeline.swift \
  Sources/SolarCopilot/SessionRecovery.swift \
  Sources/SolarCopilot/WAVFileWriter.swift \
  Tests/TranscriptionPipelineHarness/Support.swift \
  Tests/TranscriptionPipelineHarness/main.swift \
  -o "$OUT"
"$OUT"
