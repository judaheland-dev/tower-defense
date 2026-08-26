#!/usr/bin/env bash
set -euo pipefail

: "${GODOT_BIN:?GODOT_BIN is required}"

"${GODOT_BIN}" \
  --headless \
  --path . \
  --log-file "${RUNNER_TEMP:-/tmp}/tower-defense-placement-validation.log" \
  res://tests/PlacementValidationTest.tscn
