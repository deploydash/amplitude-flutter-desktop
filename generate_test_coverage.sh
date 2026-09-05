#!/bin/bash
# Desktop coverage gate plus optional HTML report (T-12).
#
# WHY this instead of `flutter test --coverage` plus `open`: the gate below
# enforces 100% lines and branches for `lib/desktop/` and fails otherwise,
# on any platform (no macOS-only `open`). HTML rendering stays an optional
# local extra for reading the report, never the enforcement.
set -e

# Step 1: run the executable desktop coverage gate (fails below 100%):
dart run tool/check_desktop_coverage.dart "$@"

# Step 2 (optional): render HTML when `genhtml` exists:
if command -v genhtml >/dev/null 2>&1; then
  genhtml coverage/desktop-lcov.info -o coverage/report
  echo "HTML report at coverage/report/index.html"
else
  echo "genhtml not installed; skipping HTML (LCOV at coverage/desktop-lcov.info)"
fi

