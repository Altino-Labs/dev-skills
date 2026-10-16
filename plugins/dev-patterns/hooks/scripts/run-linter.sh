#!/usr/bin/env bash
# run-linter.sh — PostToolUse hook (matcher: Write|Edit)
# Runs ESLint on the file just written, if it is TypeScript and the project
# has an ESLint config. Without a config, it does nothing.
#
# Claude Code delivers the event as JSON on standard input
# (tool_input.file_path). Exit 2 returns the lint output to Claude as
# feedback (the file is already written; there is nothing to block).

# Without jq the event cannot be parsed: warn once and skip (non-blocking).
if ! command -v jq >/dev/null 2>&1; then
  echo "dev-patterns hook: jq is not installed, so the post-write lint check was skipped — install jq (brew install jq / apt install jq)." >&2
  exit 0
fi

INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Only process TypeScript files
if [[ "$FILE_PATH" != *.ts && "$FILE_PATH" != *.tsx ]]; then
  exit 0
fi

# Skip test files to keep lint fast
if [[ "$FILE_PATH" == *.spec.ts || "$FILE_PATH" == *.test.ts || "$FILE_PATH" == *.test.tsx ]]; then
  exit 0
fi

# Only run if there is an ESLint config between the file's folder and the repo root
ROOT="${CLAUDE_PROJECT_DIR:-$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null)}"
DIR=$(dirname "$FILE_PATH")
HAS_CONFIG=""
while [ -n "$DIR" ] && [ "$DIR" != "/" ]; do
  for candidate in "$DIR"/eslint.config.* "$DIR"/.eslintrc*; do
    [ -e "$candidate" ] && HAS_CONFIG=1
  done
  [ -n "$HAS_CONFIG" ] && break
  [ "$DIR" = "$ROOT" ] && break
  DIR=$(dirname "$DIR")
done
[ -z "$HAS_CONFIG" ] && exit 0

# Use only the project's own ESLint (node_modules/.bin between the config folder and
# the root). `npx --no-install` falls back to a global ESLint of another major when the
# project has not installed dependencies yet — and fails with an error unrelated to the file.
ESLINT=""
D="$DIR"
while [ -n "$D" ] && [ "$D" != "/" ]; do
  if [ -x "$D/node_modules/.bin/eslint" ]; then
    ESLINT="$D/node_modules/.bin/eslint"
    break
  fi
  [ "$D" = "$ROOT" ] && break
  D=$(dirname "$D")
done
[ -z "$ESLINT" ] && exit 0

# Run lint (no --fix, so code is never changed silently)
OUTPUT=$(cd "$DIR" && "$ESLINT" "$FILE_PATH" --max-warnings 0 2>&1)
EXIT_CODE=$?

# ESLint exit codes: 1 = lint problems in the file; 2 = ESLint itself failed
# (invalid config, incompatible plugin). An ESLint failure is not the file's fault:
# warn the user (systemMessage) without blocking Claude.
if [ $EXIT_CODE -ge 2 ]; then
  jq -n --arg msg "⚠️  ESLint failed to run (exit $EXIT_CODE) — lint of $FILE_PATH was not checked: $(printf '%s' "$OUTPUT" | head -5)" \
    '{systemMessage: $msg}'
  exit 0
fi

if [ $EXIT_CODE -ne 0 ]; then
  {
    echo "⚠️  LINT: problems found in $FILE_PATH"
    echo "$OUTPUT"
    echo ""
    echo "Fix the lint problems before proceeding."
  } >&2
  exit 2
fi

exit 0
