#!/usr/bin/env bash
# Pre-commit hook: verify that every staged .dart / .rs source file contains
# the GPLv3 license header.  Auto-generated files are excluded.
#
# Install:  cp scripts/check-license-header.sh .git/hooks/pre-commit
#      or:  ln -sf ../../scripts/check-license-header.sh .git/hooks/pre-commit

set -euo pipefail

HEADER_LINE="// Rackery - Automatic bird identification and eBird checklist generation."

# Patterns for auto-generated files that should be skipped.
EXCLUDE_PATTERN="frb_generated|lib/src/rust/"

failed=0

for file in $(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(dart|rs)$' | grep -Ev "$EXCLUDE_PATTERN"); do
  if ! head -1 "$file" | grep -qF "$HEADER_LINE"; then
    echo "❌  Missing license header: $file"
    failed=1
  fi
done

if [ "$failed" -eq 1 ]; then
  echo ""
  echo "Add the GPLv3 header from lib/main.dart (lines 1-15) to the files above."
  exit 1
fi
