#!/usr/bin/env bash
# check-destructive-command.sh — PreToolUse hook (matcher: Bash)
# Asks for human confirmation before destructive commands:
#   - recursive rm on any target outside the project workspace (or on the
#     workspace root itself); inside the workspace is allowed
#   - destructive SQL sent to a database client (DROP/TRUNCATE, DELETE without WHERE)
#   - framework database resets (Django, Alembic, Rails, Laravel, Flyway,
#     Liquibase, EF Core, Prisma, dropdb, Redis, MongoDB, Supabase remote reset…)
#   - production deploys and resets on common platforms (PaaS, Kubernetes,
#     infrastructure-as-code, cloud CLIs), destructive Docker prunes
#   - git push to heroku/prod remotes, force-push to main/master and
#     git reset --hard to a remote branch
#
# Where a tool has environments (context, namespace, stack, project, app), the
# check requires a production signal ("prod" in that value) so everyday
# staging/dev work is not interrupted. When the target cannot be read from the
# command at all (fly without --app, kubectl without --context, firebase
# without --project), it asks. Commands that are destructive on any
# environment (terraform destroy, helm uninstall, cloud "delete" verbs, DB
# resets…) always ask.
#
# This is a regex-based safety net against accidents, not a sandbox: a
# deliberately obfuscated command (variables, aliases, scripts) can bypass it.
# Tests: plugins/dev-core/hooks/tests/run-tests.sh
#
# Claude Code delivers the event as JSON on standard input
# ({"cwd": "...", "tool_input": {"command": "..."}}), not as arguments or
# environment variables. To ask for confirmation, it prints a JSON object with
# permissionDecision "ask" and exits 0. No output means "no objection".
# Bash 3.2 compatible (macOS); POSIX grep/sed/awk/tr only.

# Without jq the event cannot be parsed and the check would silently turn off.
# Ask instead (fixed JSON, emitted without jq).
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"dev-core hook: jq is not installed, so this safety check (destructive commands) cannot run — install jq (brew install jq / apt install jq)."}}'
  exit 0
fi

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
EVENT_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Shipped in the dev-core plugin: $0 lives in the plugin cache, so the
# fallback must resolve the project from the working directory, not the script.
WORKSPACE="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

ask() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# ---------------------------------------------------------------------------
# Text views of the command
# ---------------------------------------------------------------------------
# FLAT: the command on one line (newlines/tabs → spaces).
FLAT=$(printf '%s' "$COMMAND" | tr '\n\r\t' '   ')

# SCAN: FLAT with quoted *prose* removed, used for the command patterns.
# A quoted segment that contains a space ("docs: explain kubectl delete -n
# production") is almost always a message or a string argument, not part of
# the command, so it is replaced by "". Quoted single words ("production",
# '+main') are kept, unquoted. Double-quoted segments holding a command
# substitution ($( or `) are kept as well — they run — except the
# "$(cat <<'EOF' …)" idiom used for multi-line commit messages.
# When the command hands a string to another shell (bash -c, sh -c, eval,
# ssh, su -c, watch), the quoted text IS a command, so nothing is stripped.
strip_quoted_prose() {
  awk '
    { s = s $0 " " }
    END {
      n = length(s); i = 1; start = 1; out = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == "\"" || c == "\047") {
          out = out substr(s, start, i - start)
          j = i + 1
          while (j <= n) {
            d = substr(s, j, 1)
            if (c == "\"" && d == "\\") { j += 2; continue }
            if (d == c) break
            j++
          }
          seg = substr(s, i + 1, j - i - 1)
          runs = (c == "\"") && (index(seg, "$(") > 0 || index(seg, "`") > 0) && (seg !~ /^\$\(cat[ ]+<</)
          if (seg ~ /[ ]/ && !runs) out = out "\"\""; else out = out seg
          i = j + 1; start = i; continue
        }
        i++
      }
      out = out substr(s, start)
      print out
    }'
}

# Start of a command word: line start or after whitespace / ; & | ( ` or a
# quote (bash -c "kubectl …", where the quoted text is not stripped)
CMD="(^|[[:space:];&|(\`\"'])"
# Same, but also allows a path prefix (bin/rails, ./vendor/bin/flyway, /usr/bin/psql)
BIN="(^|[[:space:];&|(\`\"'])([^[:space:];&|(\`\"']*/)?"
# Word boundary for SQL keywords (portable: no \b, which BSD ERE lacks)
WB='(^|[^[:alnum:]_])'
WE='([^[:alnum:]_]|$)'

if printf '%s' "$FLAT" | grep -qE -e "${CMD}((ba|z|da|k)?sh[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*c|eval|ssh|su[[:space:]].*-c|watch)([[:space:]]|$)"; then
  SCAN="$FLAT"
else
  SCAN=$(printf '%s' "$FLAT" | strip_quoted_prose)
fi

# Matching helpers (case-insensitive): has → SCAN, has_flat → FLAT
has() { printf '%s' "$SCAN" | grep -qiE -e "$1"; }
has_flat() { printf '%s' "$FLAT" | grep -qiE -e "$1"; }

# ---------------------------------------------------------------------------
# rm -r: every target must resolve to a path strictly inside the workspace
# ---------------------------------------------------------------------------

# normalize_path <absolute path> → path with //, /./ and /../ collapsed
# (pure bash, no realpath -m: works on macOS and Linux, paths need not exist).
normalize_path() {
  local IFS='/' part out=""
  local -a parts stack
  set -f
  parts=($1)
  set +f
  stack=()
  for part in "${parts[@]}"; do
    case "$part" in
      '' | .) ;;
      ..) [ ${#stack[@]} -gt 0 ] && unset "stack[$((${#stack[@]} - 1))]" ;;
      *) stack[${#stack[@]}]="$part" ;;
    esac
  done
  for part in "${stack[@]}"; do out="$out/$part"; done
  printf '%s' "${out:-/}"
}

# resolve_target <word> <base dir> → normalized absolute path, or "?" when the
# target cannot be known statically (variables, command substitution, ~user).
resolve_target() {
  local t="$1" base="$2"
  t="${t//\"/}"
  t="${t//\'/}"
  case "$t" in
    '~' | '~/'*) t="$HOME${t#\~}" ;;
    '$HOME' | '$HOME/'*) t="$HOME${t#\$HOME}" ;;
    '${HOME}' | '${HOME}/'*) t="$HOME${t#\$\{HOME\}}" ;;
  esac
  case "$t" in
    *'$'* | *'`'* | '~'*) printf '?'; return ;;
    /*) ;;
    *) t="$base/$t" ;;
  esac
  normalize_path "$t"
}

WS_NORM=$(normalize_path "$WORKSPACE")
WS_REAL=$(cd "$WORKSPACE" 2>/dev/null && pwd -P)
[ -n "$WS_REAL" ] || WS_REAL="$WS_NORM"
HOME_NORM=$(normalize_path "${HOME:-/nonexistent-home}")

# Strictly inside the workspace ("$WS/" prefix — /ws-other is not inside /ws,
# and the workspace root itself is not "inside"). Both the given and the
# physical workspace path count (macOS: /tmp → /private/tmp).
inside_workspace() {
  local ws
  for ws in "$WS_NORM" "$WS_REAL"; do
    [ "$ws" = "/" ] && continue
    case "$1" in
      "$ws"/'*' | "$ws"/'.*') return 1 ;; # rm -rf * at the workspace root
      "$ws"/*) return 0 ;;
    esac
  done
  return 1
}

# check_rm_targets <words after rm>: parses combined (-rf, -Rfv), separate
# (-r -f) and long (--recursive) flags; "--" ends the options. Only recursive
# removals are checked; every target is resolved and checked.
check_rm_targets() {
  local w recursive=0 end_opts=0 target resolved
  local -a targets
  targets=()
  for w in "$@"; do
    if [ "$end_opts" -eq 0 ]; then
      case "$w" in
        --) end_opts=1; continue ;;
        --recursive) recursive=1; continue ;;
        --*) continue ;;
        -?*)
          case "$w" in *[rR]*) recursive=1 ;; esac
          continue
          ;;
      esac
    fi
    targets[${#targets[@]}]="$w"
  done
  [ "$recursive" -eq 1 ] || return 0
  for target in "${targets[@]}"; do
    resolved=$(resolve_target "$target" "$BASE")
    if [ "$resolved" = "?" ]; then
      ask "⛔ rm -r on a target that cannot be resolved statically (target: $target — variable, command substitution or ~user). If a variable is empty this can hit / or the home directory. Requires human confirmation."
    elif [ "$resolved" = "/" ] || [ "$resolved" = "$HOME_NORM" ]; then
      ask "⛔ rm -r on the filesystem root or the home directory (target: $target). Confirm only if this is intentional."
    elif [ "$resolved" = "$WS_NORM" ] || [ "$resolved" = "$WS_REAL" ]; then
      ask "⛔ rm -r on the project workspace root itself (target: $target). Requires human confirmation."
    elif ! inside_workspace "$resolved"; then
      ask "⛔ rm -r outside the project workspace (target: $target → $resolved; workspace: $WORKSPACE). Requires human confirmation."
    fi
  done
}

# Relative paths resolve against the event's cwd (falling back to the
# workspace); a "cd DIR" earlier in the same command line is followed.
BASE="${EVENT_CWD:-$WORKSPACE}"
case "$BASE" in /*) ;; *) BASE="$PWD/$BASE" ;; esac
BASE=$(normalize_path "$BASE")

# Split the command into simple commands at ; & | ( ) and newlines. Quotes are
# not tracked here — a "; rm -rf /x" inside a message is checked too (a false
# positive in the safe direction).
SEGMENTS=$(printf '%s' "$COMMAND" | tr ';&|()' '\n\n\n\n\n')
while IFS= read -r SEGMENT; do
  set -f
  # shellcheck disable=SC2086
  set -- $SEGMENT
  set +f
  # Skip prefixes that run the next word as the command
  while [ $# -gt 0 ]; do
    case "$1" in
      sudo | doas)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u | -g | -C | -h | -p) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        ;;
      command | builtin | exec | nice | nohup | time | env | *=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || continue
  case "$1" in
    cd)
      if [ $# -ge 2 ]; then
        NEW_BASE=$(resolve_target "$2" "$BASE")
        [ "$NEW_BASE" != "?" ] && BASE="$NEW_BASE"
      else
        BASE="$HOME_NORM"
      fi
      ;;
    rm | */rm)
      shift
      check_rm_targets "$@"
      ;;
  esac
done <<EOF
$SEGMENTS
EOF

# ---------------------------------------------------------------------------
# Destructive SQL — only when a database client is part of the command
# ---------------------------------------------------------------------------
# The SQL itself is usually quoted (psql -c "…", mysql -e "…", heredocs), so
# it is read from FLAT; the client is looked up in SCAN, so a commit message
# or a grep pattern mentioning "delete from" does not count. Keywords are
# word-bounded and case-insensitive. DELETE FROM only asks without a WHERE.
DB_CLIENTS="${BIN}(psql|pgcli|mysql|mariadb|mycli|sqlite3|sqlcmd|usql|duckdb|clickhouse(-client)?|snowsql|cqlsh)([[:space:]]|$)|${BIN}cockroach[[:space:]]+sql|${BIN}prisma[[:space:]]+db[[:space:]]+execute|${BIN}wrangler[[:space:]]+d1[[:space:]]+execute|${BIN}bq[[:space:]]+query"
if has "$DB_CLIENTS"; then
  if has_flat "${WB}DROP[[:space:]]+(TABLE|DATABASE|SCHEMA)${WE}"; then
    ask "⛔ Destructive SQL command detected (DROP TABLE/DATABASE/SCHEMA). Requires explicit human confirmation."
  fi
  if has_flat "${WB}TRUNCATE${WE}"; then
    ask "⛔ Destructive SQL command detected (TRUNCATE). Requires explicit human confirmation."
  fi
  # Each DELETE FROM up to the end of its statement (; or a closing quote)
  DELETES=$(printf '%s' "$FLAT" | grep -oiE -e "${WB}DELETE[[:space:]]+FROM[^;\"']*")
  while IFS= read -r stmt; do
    [ -n "$stmt" ] || continue
    if ! printf '%s' "$stmt" | grep -qiE -e "${WB}WHERE${WE}"; then
      ask "⛔ Destructive SQL command detected (DELETE FROM without WHERE). Requires explicit human confirmation."
    fi
  done <<EOF
$DELETES
EOF
fi

# Redis / MongoDB: wiping commands sent through their clients
if has "${BIN}redis-cli([[:space:]]|$)" && has_flat "${WB}FLUSH(ALL|DB)${WE}"; then
  ask "⛔ Redis FLUSHALL/FLUSHDB detected. Requires explicit human confirmation."
fi
if has "${BIN}(mongo|mongosh)([[:space:]]|$)" && has_flat "dropDatabase[[:space:]]*\(|\.drop[[:space:]]*\([[:space:]]*\)"; then
  ask "⛔ MongoDB dropDatabase()/drop() detected. Requires explicit human confirmation."
fi

# A "production signal" is a flag value containing "prod" (prod, production,
# my-app-prod, prod-eu, …).
PROD_VAL='[^[:space:]]*prod'
# Any argument or flag value containing "prod" — for cloud CLIs whose target
# is a positional stack/bucket name or one of many possible flags.
PROD_ARG="[[:space:]=]${PROD_VAL}"

# ---------------------------------------------------------------------------
# Framework database resets (always ask — they wipe data on any environment)
# ---------------------------------------------------------------------------
DB_RESET_PATTERNS=(
  # Django
  "${BIN}(manage\.py|django-admin)[[:space:]]+(flush|reset_db|sqlflush)([[:space:]]|$)"
  # Alembic (SQLAlchemy): any downgrade
  "${BIN}alembic[[:space:]]+(.*[[:space:]])?downgrade([[:space:]]|$)"
  # Rails / rake
  "${BIN}(rails|rake)[[:space:]]+(.*[[:space:]])?db:(drop|reset|purge|truncate_all|schema:load|migrate:reset)([[:space:]:]|$)"
  # Laravel
  "${BIN}artisan[[:space:]]+(migrate:(fresh|reset|refresh)|db:wipe)([[:space:]]|$)"
  # Flyway (CLI, Maven/Gradle plugins)
  "${BIN}flyway[[:space:]]+(.*[[:space:]])?clean([[:space:]]|$)"
  "flyway:clean|flywayClean"
  # Liquibase (CLI, Maven plugin)
  "${BIN}liquibase[[:space:]]+(.*[[:space:]])?drop-?all([[:space:]]|$)"
  "liquibase:dropAll"
  # Entity Framework Core
  "${BIN}dotnet(-ef|[[:space:]]+ef)[[:space:]]+database[[:space:]]+drop([[:space:]]|$)"
  # Prisma
  "${BIN}prisma[[:space:]]+migrate[[:space:]]+reset([[:space:]]|$)"
  "${BIN}prisma[[:space:]]+db[[:space:]]+push[[:space:]].*--force-reset"
  # PostgreSQL dropdb
  "${BIN}dropdb([[:space:]]|$)"
  # Elixir Ecto, Sequelize, TypeORM
  "${BIN}mix[[:space:]]+ecto\.(drop|reset)([[:space:]]|$)"
  "${BIN}sequelize(-cli)?[[:space:]]+db:drop([[:space:]]|$)"
  "${BIN}typeorm(-ts-node-[a-z]+)?[[:space:]].*schema:drop([[:space:]]|$)"
  # Supabase: reset of a remote database (a plain local "supabase db reset" is allowed)
  "${BIN}supabase[[:space:]]+db[[:space:]]+reset[[:space:]].*--(linked|db-url)"
  "${BIN}supabase[[:space:]]+db[[:space:]]+reset.*production"
)

for pattern in "${DB_RESET_PATTERNS[@]}"; do
  if has "$pattern"; then
    ask "⛔ Database reset/drop command (pattern: $pattern). It wipes data — requires explicit human confirmation."
  fi
done

# ---------------------------------------------------------------------------
# Production deploys and resets (each pattern needs a production signal)
# ---------------------------------------------------------------------------
PROD_PATTERNS=(
  # Railway: deploy/redeploy/down on a prod environment (-e / --environment)
  "${BIN}railway[[:space:]]+(up|redeploy|down|deploy)[[:space:]].*(-e|--environment)[[:space:]=]+${PROD_VAL}"
  # Expo EAS: store submission / OTA update to a production profile, channel or branch
  "${BIN}eas[[:space:]]+(submit|update)[[:space:]].*(--profile|--channel|--branch|-e|--environment)[[:space:]=]+${PROD_VAL}"
  # Vercel: production deploys are the ones with --prod
  "${BIN}vercel([[:space:]]+deploy)?[[:space:]].*--prod([[:space:]=]|$)"
  # Kubernetes: mutating verbs against a prod context or namespace
  # (read verbs such as get/describe/logs never match)
  "${BIN}kubectl[[:space:]].*(delete|apply|replace|patch|scale|drain|create|edit|set|rollout[[:space:]]+(undo|restart))[[:space:]].*(--context|--cluster|-n|--namespace)[[:space:]=]+${PROD_VAL}"
  "${BIN}kubectl[[:space:]].*(--context|--cluster|-n|--namespace)[[:space:]=]+${PROD_VAL}.*[[:space:]](delete|apply|replace|patch|scale|drain|create|edit|set|rollout[[:space:]]+(undo|restart))([[:space:]]|$)"
  # Pulumi: non-interactive update of a prod stack
  "${BIN}pulumi[[:space:]]+(up|update)[[:space:]].*(--yes|-y)([[:space:]]|$).*(-s|--stack)[[:space:]=]+${PROD_VAL}"
  "${BIN}pulumi[[:space:]]+(up|update)[[:space:]].*(-s|--stack)[[:space:]=]+${PROD_VAL}.*(--yes|-y)([[:space:]]|$)"
  # Firebase: deploy to a prod project alias/id
  "${BIN}firebase[[:space:]]+deploy([[:space:]].*)?(-P|--project)[[:space:]=]+${PROD_VAL}"
  # Google Cloud: mutating verbs with a prod project/service/flag value
  "${BIN}gcloud[[:space:]].*[[:space:]](deploy|update|replace|create|scale|import|set-iam-policy|add-iam-policy-binding|remove-iam-policy-binding)([[:space:]].*)?${PROD_ARG}"
  # Azure: deploy/create/update/swap with a prod resource group/name/slot/subscription
  "${BIN}az[[:space:]].*[[:space:]](deploy|up|create|update|swap|restart|stop)([[:space:]].*)?${PROD_ARG}"
  # AWS CLI: deploy/update-*/put-*/create-*/s3 sync with a prod profile/stack/bucket
  "${BIN}aws[[:space:]]+[a-z0-9-]+[[:space:]]+(deploy|update-[a-z0-9-]+|put-[a-z0-9-]+|create-[a-z0-9-]+|sync)([[:space:]].*)?${PROD_ARG}"
  # AWS SAM: deploy/sync to a prod config-env/stack/profile
  "${BIN}sam[[:space:]]+(deploy|sync)([[:space:]].*)?${PROD_ARG}"
  # AWS CDK: deploy of a prod stack/context, or of every stack at once
  "${BIN}cdk[[:space:]]+deploy([[:space:]].*)?${PROD_ARG}"
  "${BIN}cdk[[:space:]]+deploy[[:space:]](.*[[:space:]])?--all([[:space:]]|$)"
  # Serverless Framework: deploy to a prod stage
  "${BIN}(serverless|sls)[[:space:]]+deploy([[:space:]].*)?${PROD_ARG}"
  # git push to a remote that deploys (Heroku, or a remote named prod*/production)
  "${CMD}git[[:space:]]+push([[:space:]]+-[^[:space:]]+)*[[:space:]]+(heroku|prod[^[:space:]]*)([[:space:]]|$)"
)

for pattern in "${PROD_PATTERNS[@]}"; do
  if has "$pattern"; then
    ask "⛔ Production environment operation (pattern: $pattern). Production deploys and resets require explicit human confirmation."
  fi
done

# ---------------------------------------------------------------------------
# Deploys whose target cannot be read from the command (ask, like fly)
# ---------------------------------------------------------------------------
# Fly.io: prod app, or no --app (fly.toml decides — cannot tell)
if has "${BIN}fly(ctl)?[[:space:]]+deploy([[:space:]]|$)"; then
  if ! has "(-a|--app)[[:space:]=]+[^[:space:]]+" || has "(-a|--app)[[:space:]=]+${PROD_VAL}"; then
    ask "⛔ fly deploy to a production app (or with no --app, so the target comes from fly.toml and cannot be checked). Requires explicit human confirmation."
  fi
fi

# Kubernetes: mutating verb with no --context/--cluster → the current context
# (possibly production) is used and cannot be checked
if has "${BIN}kubectl[[:space:]](.*[[:space:]])?(delete|apply|replace|patch|scale|drain|create|edit|set|rollout[[:space:]]+(undo|restart))([[:space:]]|$)" \
  && ! has "(--context|--cluster)[[:space:]=]+[^[:space:]]+"; then
  ask "⛔ kubectl mutating command with no --context/--cluster, so it runs against the current context (which cannot be checked for production). Requires explicit human confirmation."
fi

# Firebase: deploy with no -P/--project → the active project (.firebaserc) is used
if has "${BIN}firebase[[:space:]]+deploy([[:space:]]|$)" && ! has "(-P|--project)[[:space:]=]+[^[:space:]]+"; then
  ask "⛔ firebase deploy with no -P/--project, so the active project (.firebaserc) is used and cannot be checked for production. Requires explicit human confirmation."
fi

# Pulumi up --yes with no --stack (current stack cannot be checked)
if has "${BIN}pulumi[[:space:]]+(up|update)[[:space:]].*(--yes|-y)([[:space:]]|$)" && ! has "(-s|--stack)[[:space:]=]"; then
  ask "⛔ pulumi up --yes on the currently selected stack (no --stack given, so it cannot be checked for production). Requires explicit human confirmation."
fi

# ---------------------------------------------------------------------------
# Destructive on any environment (always ask)
# ---------------------------------------------------------------------------
ALWAYS_PATTERNS=(
  # Fly.io / Heroku: destroy apps, reset databases, roll back releases
  "${BIN}fly(ctl)?[[:space:]]+(apps[[:space:]]+destroy|destroy)([[:space:]]|$)"
  "${BIN}heroku[[:space:]]+(pg:reset|apps:destroy|destroy|releases:rollback|rollback)([[:space:]]|$)"
  # Helm: removing a release
  "${BIN}helm[[:space:]]+(uninstall|delete|del)([[:space:]]|$)"
  # Terraform / OpenTofu: destroy, or apply without the interactive plan review
  "${BIN}(terraform|tofu)[[:space:]]+(.*[[:space:]])?destroy([[:space:]]|$)"
  "${BIN}(terraform|tofu)[[:space:]]+(.*[[:space:]])?apply[[:space:]].*-(auto-approve|destroy)([[:space:]=]|$)"
  # Pulumi: destroying a stack's resources
  "${BIN}pulumi[[:space:]]+(destroy|stack[[:space:]]+rm)([[:space:]]|$)"
  # AWS CDK / SAM / Serverless: tearing down stacks
  "${BIN}cdk[[:space:]]+destroy([[:space:]]|$)"
  "${BIN}sam[[:space:]]+delete([[:space:]]|$)"
  "${BIN}(serverless|sls)[[:space:]]+remove([[:space:]]|$)"
  # Google Cloud: any "delete" subcommand (gcloud compute instances delete, gcloud projects delete…)
  "${BIN}gcloud[[:space:]].*[[:space:]]delete([[:space:]]|$)"
  # AWS: delete-*/terminate-* actions, recursive S3 removal, forced bucket removal
  "${BIN}aws[[:space:]]+[a-z0-9-]+[[:space:]]+(delete-[a-z0-9-]+|terminate-instances)([[:space:]]|$)"
  "${BIN}aws[[:space:]]+s3[[:space:]]+rm[[:space:]].*--recursive"
  "${BIN}aws[[:space:]]+s3[[:space:]]+rb[[:space:]].*--force"
  # Azure: deleting resource groups (and any other "az … delete")
  "${BIN}az[[:space:]].*[[:space:]]delete([[:space:]]|$)"
  # Docker: prunes that delete volume data
  "${BIN}docker[[:space:]]+system[[:space:]]+prune[[:space:]].*--volumes"
  "${BIN}docker[[:space:]]+volume[[:space:]]+(prune|rm)([[:space:]]|$)"
  # git: discard local work by resetting hard to a remote-tracking branch
  "${CMD}git[[:space:]]+reset[[:space:]]+(.*[[:space:]])?--hard[[:space:]]+([A-Za-z0-9._-]+/|@\{u)"
)

for pattern in "${ALWAYS_PATTERNS[@]}"; do
  if has "$pattern"; then
    ask "⛔ Destructive operation (pattern: $pattern). Requires explicit human confirmation."
  fi
done

# ---------------------------------------------------------------------------
# git push --force to main/master
# ---------------------------------------------------------------------------
# Force flags: --force, --force-with-lease, -f, or a +refspec. Asks when the
# command names main/master, or names no branch and the current branch is main/master.
if has "${CMD}git[[:space:]]+push([[:space:]]|$)" \
  && has "[[:space:]](--force(-with-lease)?(=[^[:space:]]*)?|-f)([[:space:]]|$)|[[:space:]:]\+[A-Za-z0-9._/-]+"; then
  CURRENT_BRANCH=$(git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if has "[[:space:]:+/](main|master)([[:space:]]|$)" || [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    ask "⛔ Force-push that may rewrite main/master (current branch: ${CURRENT_BRANCH:-unknown}). Requires explicit human confirmation."
  fi
fi

exit 0
