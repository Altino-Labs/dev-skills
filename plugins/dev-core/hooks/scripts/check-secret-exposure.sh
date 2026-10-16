#!/usr/bin/env bash
# check-secret-exposure.sh — PreToolUse hook (matcher: Write|Edit)
# Asks for human confirmation when the content about to be written looks
# like it contains a secret:
#   - well-known token formats (Stripe, AWS, GitHub, Slack, Google, OpenAI,
#     Anthropic, SendGrid, Twilio), JWTs and PEM private keys — in any file,
#     markdown and .env.example included
#   - a literal assigned to a secret-looking name (password, secret, token,
#     api_key, access_key, private_key, *_KEY…) with =, := or :
#   - .NET connection strings with Password=…; and URLs with credentials
#     (scheme://user:pass@host)
#
# This is a regex-based safety net against accidents, not a secret scanner:
# encoded, split or unusually named secrets get through.
# Tests: plugins/dev-core/hooks/tests/run-tests.sh
#
# Claude Code delivers the event as JSON on standard input:
#   Write → tool_input.file_path + tool_input.content
#   Edit  → tool_input.file_path + tool_input.new_string
# To ask for confirmation, it prints a JSON object with permissionDecision "ask".
# Bash 3.2 compatible (macOS); POSIX grep/sed only (no \s, no \b, no -P).

# Without jq the event cannot be parsed and the check would silently turn off.
# Ask instead (fixed JSON, emitted without jq).
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"dev-core hook: jq is not installed, so this safety check (secret exposure) cannot run — install jq (brew install jq / apt install jq)."}}'
  exit 0
fi

INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null)
[ -z "$CONTENT" ] && exit 0

BASENAME="${FILE_PATH##*/}"

ask_secret() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

MSG_TAIL="Secrets belong in environment variables, never in code — confirm only if this is an example/test value."

# Placeholder files (exact basename): they hold names with dummy values, so
# the assignment and URL checks are skipped. Real token formats are still
# checked — a live key pasted into .env.example is still a leak.
PLACEHOLDER_FILE=0
case "$BASENAME" in
  .env.example | .env.sample | .env.template | .env.dist) PLACEHOLDER_FILE=1 ;;
esac

# Config-style files, where an unquoted value is a literal (KEY=value,
# key: value). In source code an unquoted right-hand side is an expression
# (getToken(), config.apiKey), so only quoted literals count there.
UNQUOTED_IS_LITERAL=0
case "$BASENAME" in
  .env | .env.* | *.env | .envrc | *.yml | *.yaml | *.properties | *.ini | *.cfg | *.conf | *.toml | *.tfvars \
    | *.sh | *.bash | *.zsh | Dockerfile | Dockerfile.* | *.dockerfile | .npmrc | .pypirc)
    UNQUOTED_IS_LITERAL=1
    ;;
esac

# Token-boundary prefix: start of line or a non-identifier character
# (portable replacement for \b; keeps TASK0123… from matching the Twilio SK…).
TB='(^|[^[:alnum:]_])'

# ---------------------------------------------------------------------------
# 1. Well-known token formats — case-sensitive (the prefixes are
#    case-significant; -i would turn random identifiers into hits)
# ---------------------------------------------------------------------------
TOKEN_PATTERNS=(
  # Stripe live secret / restricted keys
  "${TB}(sk|rk)_live_[A-Za-z0-9]{24,}"
  # AWS access key IDs (long-term AKIA, temporary ASIA)
  "(^|[^A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Z0-9]|$)"
  # GitHub tokens (classic and fine-grained)
  "${TB}gh[pousr]_[A-Za-z0-9]{36}"
  "${TB}github_pat_[A-Za-z0-9_]{60,}"
  # Slack tokens
  "${TB}xox[baprs]-[A-Za-z0-9-]{10,}"
  # Google API keys
  "${TB}AIza[0-9A-Za-z_-]{35}"
  # Anthropic and OpenAI keys
  "${TB}sk-ant-[A-Za-z0-9_-]{20,}"
  "${TB}sk-proj-[A-Za-z0-9_-]{20,}"
  "${TB}sk-[A-Za-z0-9]{32,}"
  # SendGrid API keys
  "${TB}SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"
  # Twilio API key SIDs (word-bounded: TASK0123… is not one)
  "(^|[^A-Za-z0-9])SK[0-9a-fA-F]{32}([^A-Za-z0-9]|$)"
  # JWTs: three base64url parts, header and payload both JSON ("eyJ")
  "eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
  # PEM / OpenSSH / PGP private keys
  "-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----"
)

for pattern in "${TOKEN_PATTERNS[@]}"; do
  if printf '%s' "$CONTENT" | grep -qE -e "$pattern"; then
    ask_secret "⛔ Possible secret in $FILE_PATH (token format: $pattern). $MSG_TAIL"
  fi
done

# Stripe test keys are not production credentials but still should not be
# committed (they grant access to the account's test data).
if printf '%s' "$CONTENT" | grep -qE -e "${TB}(sk|rk)_test_[A-Za-z0-9]{24,}"; then
  ask_secret "⛔ Stripe TEST key in $FILE_PATH (pattern: (sk|rk)_test_…). Test keys are less sensitive than live keys but still belong in environment variables — confirm only if this is intentional."
fi

[ "$PLACEHOLDER_FILE" -eq 1 ] && exit 0

# is_placeholder <value>: references and dummy values that are not secrets —
# env/variable interpolation, templates, "your-…", "changeme", well-known
# local-dev defaults, URLs, numbers, booleans.
is_placeholder() {
  local v lower
  v="$1"
  lower=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    '$'* | '<'* | '{{'* | '%('* | '!'* | '*'* | '...'* | 'xxx'* | 'http://'* | 'https://'*) return 0 ;;
    *process.env* | *os.environ* | *getenv* | env\(* | env\[* | *environment.get* | *secrets.* | *vault:* ) return 0 ;;
    your-* | your_* | yourpass* | *-here | *_here | *changeme* | *change-me* | *change_me* | *placeholder* | *example* | *redacted* | *dummy*) return 0 ;;
    password | passwd | pass | pwd | secret | postgres | root | admin | test | user | true | false | null | none) return 0 ;;
  esac
  # Pure numbers (timeouts, TTLs: token_ttl: 86400000)
  case "$v" in
    *[!0-9]*) ;;
    *) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 2. Literal assigned to a secret-looking name
# ---------------------------------------------------------------------------
# The keyword must be a component of the name: SECRET_KEY, DB_PASSWORD,
# spring.datasource.password, apiKey, "api_key" — but not tokenizer or
# passwordHint (the keyword must end the name or be followed by _ . -).
# Operators: = (any language, .env, .properties), := (Go), : (YAML, JSON).
# Values: quoted literal, or unquoted in config-style files; at least 8
# characters, no whitespace, not a placeholder/reference (is_placeholder).
KW='(passw(or)?d|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|auth[_-]?key)'
NAME_KW="(^|[^[:alnum:]_.-])[[:alnum:]_.-]*${KW}([_.-][[:alnum:]_.-]*)?[\"']?"
# Upper-case env-style names ending in _KEY (STRIPE_KEY, SUPABASE_SERVICE_ROLE_KEY)
NAME_ENVKEY="(^|[^[:alnum:]_])[A-Z][A-Z0-9_]*_KEY[\"']?"
OP='[[:space:]]*(:=|=|:)[[:space:]]*'
VAL="(\"[^\"]*\"?|'[^']*'?|[^[:space:]\"'\`,;)}]+)"

CANDIDATES=$(
  printf '%s\n' "$CONTENT" | grep -oiE -e "${NAME_KW}${OP}${VAL}"
  printf '%s\n' "$CONTENT" | grep -oE -e "${NAME_ENVKEY}${OP}${VAL}"
)

while IFS= read -r m; do
  [ -n "$m" ] || continue
  # Drop the name and operator: everything up to the first := / = / :
  # (the leading boundary character, if any, is dropped first)
  v=$(printf '%s' "$m" | sed -E 's/^[^[:alnum:]_.-]//; s/^[^:=]*(:=|=|:)[[:space:]]*//')
  quoted=0
  case "$v" in
    \"* | \'*)
      quoted=1
      v="${v#?}"
      v="${v%[\"\']}"
      ;;
  esac
  [ ${#v} -ge 8 ] || continue
  [ "$quoted" -eq 1 ] || [ "$UNQUOTED_IS_LITERAL" -eq 1 ] || continue
  case "$v" in *[[:space:]]* | *'('* | *'['*) continue ;; esac
  is_placeholder "$v" && continue
  NAME=$(printf '%s' "$m" | sed -E 's/^[^[:alnum:]_.-]//; s/[\"'"'"']?[[:space:]]*(:=|=|:).*$//')
  ask_secret "⛔ Possible secret in $FILE_PATH (literal value assigned to \"$NAME\"). $MSG_TAIL"
done <<EOF
$CANDIDATES
EOF

# ---------------------------------------------------------------------------
# 3. .NET / ODBC connection strings: Password=…; or Pwd=…;
# ---------------------------------------------------------------------------
CONN=$(printf '%s\n' "$CONTENT" | grep -oiE -e "(^|[;\"'[:space:]])(Password|Pwd)[[:space:]]*=[[:space:]]*[^;\"'[:space:]]{6,}[;\"']")
while IFS= read -r m; do
  [ -n "$m" ] || continue
  v=$(printf '%s' "$m" | sed -E 's/^[^=]*=[[:space:]]*//; s/[;"'"'"']$//')
  is_placeholder "$v" && continue
  ask_secret "⛔ Possible secret in $FILE_PATH (connection string with Password=…). $MSG_TAIL"
done <<EOF
$CONN
EOF

# ---------------------------------------------------------------------------
# 4. URLs with credentials: scheme://user:password@host
# ---------------------------------------------------------------------------
URLS=$(printf '%s\n' "$CONTENT" | grep -oE -e "[[:alpha:]][[:alnum:]+.-]*://[^/[:space:]:@\"']+:[^/[:space:]@\"']+@")
while IFS= read -r m; do
  [ -n "$m" ] || continue
  v="${m#*://}"
  v="${v#*:}"
  v="${v%@}"
  is_placeholder "$v" && continue
  ask_secret "⛔ Possible secret in $FILE_PATH (URL with embedded credentials: ${m%%://*}://…:…@). $MSG_TAIL"
done <<EOF
$URLS
EOF

exit 0
