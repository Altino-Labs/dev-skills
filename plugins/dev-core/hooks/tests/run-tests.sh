#!/usr/bin/env bash
# run-tests.sh — regression tests for the dev-core PreToolUse hooks.
#
#   bash plugins/dev-core/hooks/tests/run-tests.sh
#
# Feeds hook events (JSON on standard input, as Claude Code does) to each
# script and asserts the decision: ASK (the script printed
# permissionDecision "ask") or ALLOW (no output). Exits non-zero if any case
# fails. Requires bash (3.2+) and jq — nothing else.
#
# The workspace is fixed (/tmp/hooktest-ws, via CLAUDE_PROJECT_DIR) so
# "inside the project" paths are deterministic. Token-like test values are
# assembled at runtime (rep/concatenation) so this file does not itself look
# like it contains secrets.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
DESTRUCTIVE="$HERE/../scripts/check-destructive-command.sh"
SECRETS="$HERE/../scripts/check-secret-exposure.sh"
WS="/tmp/hooktest-ws"
mkdir -p "$WS/sub"

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "run-tests.sh: jq is required" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILURES=""

# decision_of <hook output> → ASK | ALLOW | INVALID
decision_of() {
  if [ -z "$1" ]; then
    printf 'ALLOW'
  elif [ "$(printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = "ask" ]; then
    printf 'ASK'
  else
    printf 'INVALID'
  fi
}

# record <expected> <actual> <label>
record() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES="${FAILURES}  FAIL [expected $1, got $2] $3
"
  fi
}

# d <ASK|ALLOW> <command> [event cwd] — destructive-command hook
d() {
  local event out
  if [ $# -ge 3 ]; then
    event=$(jq -n --arg c "$2" --arg cwd "$3" '{cwd: $cwd, tool_name: "Bash", tool_input: {command: $c}}')
  else
    event=$(jq -n --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}')
  fi
  out=$(printf '%s' "$event" | CLAUDE_PROJECT_DIR="$WS" bash "$DESTRUCTIVE" 2>/dev/null)
  record "$1" "$(decision_of "$out")" "destructive: $2${3:+ (cwd $3)}"
}

# d_fallback <ASK|ALLOW> <command> — no CLAUDE_PROJECT_DIR, run from inside $WS
d_fallback() {
  local event out
  event=$(jq -n --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}')
  out=$(cd "$WS" && printf '%s' "$event" | CLAUDE_PROJECT_DIR= bash "$DESTRUCTIVE" 2>/dev/null)
  record "$1" "$(decision_of "$out")" "destructive (cwd fallback): $2"
}

# s <ASK|ALLOW> <file_path> <content> [Edit] — secret-exposure hook
s() {
  local event out
  if [ "${4:-Write}" = "Edit" ]; then
    event=$(jq -n --arg f "$2" --arg c "$3" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: "x", new_string: $c}}')
  else
    event=$(jq -n --arg f "$2" --arg c "$3" '{tool_name: "Write", tool_input: {file_path: $f, content: $c}}')
  fi
  out=$(printf '%s' "$event" | CLAUDE_PROJECT_DIR="$WS" bash "$SECRETS" 2>/dev/null)
  record "$1" "$(decision_of "$out")" "secret (${4:-Write} $2): $3"
}

# rep <chars> <n> — first n characters of <chars> repeated
rep() {
  local out=""
  while [ ${#out} -lt "$2" ]; do out="$out$1"; done
  printf '%s' "${out:0:$2}"
}

# ===================================================================
# check-destructive-command.sh
# ===================================================================

# --- rm: must ASK ---
d ASK "rm -rf /etc/foo"
d ASK "rm -Rf /etc/foo"
d ASK "rm -r -f /opt/data"
d ASK "rm -rfv /etc/foo"
d ASK "rm --recursive --force /etc/foo"
d ASK "rm -rf ./build /etc/foo"
d ASK "rm -rf ../other-repo"
d ASK "rm -rf /tmp/hooktest-ws-other"
d ASK "rm -rf ~"
d ASK "rm -rf /"
d ASK "rm -rf /tmp/hooktest-ws"
d ASK "rm -rf /tmp/hooktest-ws/../hooktest-ws-other"
d ASK "cd src && rm -rf /etc/foo"
d ASK "sudo rm -rf /var/lib/app"
d ASK 'rm -rf "$UNSET_DIR/"'
d ASK "rm -rf ../../etc" "$WS/sub"

# --- rm: must ALLOW ---
d ALLOW "ls -la"
d ALLOW "rm -rf node_modules"
d ALLOW "rm -rf /tmp/hooktest-ws/dist"
d ALLOW "rm -rf ./build"
d ALLOW "rm file.txt"
d ALLOW "rm -rf ../dist" "$WS/sub"
d ALLOW "rm -rf ./a/../b"

# --- cwd fallback (no CLAUDE_PROJECT_DIR): workspace = git toplevel or pwd ---
d_fallback ALLOW "rm -rf ./build"
d_fallback ASK "rm -rf /etc/foo"
d_fallback ASK "rm -rf ../other-repo"

# --- SQL: must ASK ---
d ASK 'psql -c "DROP TABLE users"'
d ASK 'psql -c "truncate orders"'
d ASK 'psql -c "DELETE FROM users"'
d ASK 'mysql -e "DROP DATABASE app"'
d ASK 'echo "drop schema public cascade" | psql "$DATABASE_URL"'
d ASK 'psql -c "DELETE FROM a WHERE id = 1; DELETE FROM b"'

# --- SQL: must ALLOW ---
d ALLOW 'git commit -m "truncate long titles in the list"'
d ALLOW 'grep -rn "delete from" src'
d ALLOW 'psql -c "DELETE FROM users WHERE id = 1"'
d ALLOW 'psql -c "SELECT * FROM truncated_events"'

# --- Framework DB resets: must ASK ---
d ASK "python manage.py flush --noinput"
d ASK "alembic downgrade base"
d ASK "rails db:drop"
d ASK "bin/rails db:reset"
d ASK "php artisan migrate:fresh"
d ASK "flyway clean"
d ASK "mvn flyway:clean"
d ASK "liquibase dropAll"
d ASK "dotnet ef database drop -f"
d ASK "npx prisma migrate reset --force"
d ASK "dropdb app_prod"
d ASK "redis-cli FLUSHALL"
d ASK "mongosh --eval 'db.dropDatabase()'"
d ASK "supabase db reset --linked"
d ASK "supabase db reset --db-url postgres://x@db/app"

# --- Framework DB commands: must ALLOW ---
d ALLOW "alembic upgrade head"
d ALLOW "python manage.py migrate"
d ALLOW "rails db:migrate"
d ALLOW "flyway migrate"
d ALLOW "dotnet ef database update"
d ALLOW "npx prisma migrate deploy"
d ALLOW "supabase db reset"

# --- Production deploys / destroys: must ASK ---
d ASK "railway up --environment production"
d ASK "railway up -e prod"
d ASK "eas submit --profile production"
d ASK "vercel --prod"
d ASK "fly deploy"
d ASK "fly deploy --app myapp-prod"
d ASK "heroku pg:reset"
d ASK "git push heroku main"
d ASK "git push production main"
d ASK "kubectl delete deployment api -n production"
d ASK "kubectl delete deployment api"
d ASK "kubectl apply -f k8s/ --context prod-eu"
d ASK "helm uninstall api"
d ASK "terraform destroy"
d ASK "terraform apply -auto-approve"
d ASK "pulumi destroy"
d ASK "pulumi up --yes --stack prod"
d ASK "gcloud run deploy api --project my-prod"
d ASK "gcloud compute instances delete vm1"
d ASK "aws ec2 terminate-instances --instance-ids i-1"
d ASK "aws s3 rm s3://b --recursive"
d ASK "az webapp deploy --resource-group prod-rg"
d ASK "az group delete -n rg"
d ASK "sam deploy --config-env prod"
d ASK "cdk deploy --all"
d ASK "serverless deploy --stage prod"
d ASK "firebase deploy -P prod"
d ASK "firebase deploy"
d ASK "docker system prune -a --volumes"
d ASK "docker volume prune"
d ASK "git push --force origin main"
d ASK "git push -f origin master"
d ASK "git push origin +main"
d ASK "git reset --hard origin/main"
d ASK 'bash -c "kubectl delete ns api --context prod-eu"'

# --- Everyday commands: must ALLOW ---
# Quoted prose (commit messages) is not matched against command patterns.
d ALLOW 'git commit -m "docs: explain kubectl delete -n production"'
d ALLOW 'git commit -m "chore: stop running terraform destroy in CI"'
d ALLOW "railway up --environment staging"
d ALLOW "vercel deploy"
d ALLOW "fly deploy -a myapp-staging"
d ALLOW "heroku logs"
d ALLOW "git push origin feature-x"
d ALLOW "git push --force-with-lease origin feature-x"
d ALLOW "kubectl get pods -n production"
d ALLOW "kubectl logs api --context prod-eu"
d ALLOW "kubectl apply -f k8s/ --context staging-eu"
d ALLOW "terraform plan"
d ALLOW "terraform apply"
d ALLOW "pulumi preview --stack prod"
d ALLOW "gcloud run services list --project my-prod"
d ALLOW "gcloud run deploy api --project my-staging"
d ALLOW "aws s3 ls"
d ALLOW "aws s3 rm s3://b/one-file.txt"
d ALLOW "sam deploy --config-env staging"
d ALLOW "serverless deploy --stage dev"
d ALLOW "firebase deploy -P staging"
d ALLOW "docker ps"
d ALLOW "docker system prune -a"
d ALLOW "git reset --hard HEAD~1"
d ALLOW "echo -n hello"
d ALLOW "printf '%s' x"
d ALLOW "git commit -m \"\$(cat <<'EOF'
fix: handle kubectl delete -n production in docs

Mentions terraform destroy and DROP TABLE users.
EOF
)\""
d ALLOW "rm -rf dist/*"
d ALLOW "kubectl config use-context prod-eu"

# --- Quoted text that runs is still checked ---
d ASK 'echo "$(terraform destroy -auto-approve)"'
d ASK "rm -rf *"
d ASK "cd /etc && rm -rf foo"

# ===================================================================
# check-secret-exposure.sh
# ===================================================================

PW="Super""Secret123"
B64=$(rep 'aB3dE_fG7hI-jK9' 40)

# --- must ASK ---
s ASK "$WS/app/settings.py" "SECRET_KEY = \"django-insecure-abc123def456ghi789\""
s ASK "$WS/main.go" "	password := \"$PW!\""
s ASK "$WS/src/main/resources/application.yml" "spring:
  datasource:
    password: $PW"
s ASK "$WS/src/main/resources/application.properties" "spring.datasource.password=$PW"
s ASK "$WS/appsettings.json" "{ \"ConnectionStrings\": { \"Default\": \"Server=db;User Id=sa;Password=$PW;\" } }"
s ASK "$WS/docker-compose.yml" "DATABASE_URL: postgresql://app:S3cret""Pass@db:5432/app"
s ASK "$WS/config.json" "{ \"api_key\": \"abcd1234""efgh5678ijkl\" }"
s ASK "$WS/.env" "API_SECRET=abcdef1234""567890abcd"
s ASK "$WS/billing.ts" "const k = '""sk_live_$(rep 'aB3dE' 24)';"
s ASK "$WS/deploy.sh" "export AWS_ACCESS_KEY_ID=AKIA$(rep 'ABCDEFGH23' 16)"
s ASK "$WS/ci.yml" "token: ghp_$(rep 'aB3dE' 36)"
s ASK "$WS/notify.py" "SLACK = 'xoxb-""123456789012-abcdefghijkl'"
s ASK "$WS/maps.js" "const key = 'AIza$(rep 'aB3dE_' 35)';"
s ASK "$WS/llm.py" "client = OpenAI(api_key='sk-proj-$(rep 'aB3dE' 30)')"
s ASK "$WS/llm.ts" "new Anthropic({ apiKey: 'sk-ant-$(rep 'aB3dE' 30)' })"
s ASK "$WS/key.pem" "-----BEGIN RSA ""PRIVATE KEY-----
MIIEowIBAAKCAQEA"
s ASK "$WS/fixtures.ts" "const jwt = 'eyJ$(rep 'hbGciOiJIUzI1' 20).eyJ$(rep 'zdWIiOiIxMjM0' 40).$B64';"
s ASK "$WS/docs/RUNBOOK.md" "Use this key: sk-ant-$(rep 'aB3dE' 30)"
s ASK "$WS/src/config.ts" "export const apiKey = \"abcd1234""efgh5678ijkl\";" Edit
s ASK "$WS/twilio.js" "const sid = 'SK$(rep '0123456789abcdef' 32)';"

# --- must ALLOW ---
s ALLOW "$WS/src/a.ts" "const a = 1;"
s ALLOW "$WS/src/auth.ts" "const token = process.env.API_TOKEN;"
s ALLOW "$WS/db.py" "password = os.environ[\"DB_PASSWORD\"]"
s ALLOW "$WS/src/auth.ts" "// the token is refreshed by the interceptor; never log the secret"
s ALLOW "$WS/tasks.ts" "const id = 'TASK0123456789abcdef0123456789abcdef';"
s ALLOW "$WS/hash.txt" "$(rep '0123456789abcdef' 64)"
s ALLOW "$WS/.env.example" "API_KEY=your-key-here
API_KEY="
s ALLOW "$WS/config/application.yml" "password: \${DB_PASSWORD}"
s ALLOW "$WS/.env.example" "DATABASE_URL=postgresql://user:password@localhost:5432/db"
s ALLOW "$WS/README.md" "Set your API key in the env before running the app."
s ALLOW "$WS/src/auth.ts" "const token = await getToken(request);"
s ALLOW "$WS/src/tokenizer.ts" "const tokenizer = new Tokenizer(options);"
s ALLOW "$WS/docker-compose.yml" "POSTGRES_PASSWORD: postgres"
s ALLOW "$WS/.github/workflows/ci.yml" "token: \${{ secrets.GITHUB_TOKEN }}"
s ALLOW "$WS/config/application.yml" "jwt:
  token-ttl: 86400000"
s ALLOW "$WS/locales/pt-BR.json" "{ \"forgot_password\": \"Esqueceu a senha?\" }"
s ALLOW "$WS/src/types.ts" "interface Login { password: string; token?: string }"
s ASK "$WS/src/login.ts" "const password = \"hunter2""hunter2\";"

# ===================================================================
# jq guard: without jq both hooks must ask (not silently allow)
# ===================================================================
out=$(printf '%s' '{"tool_input":{"command":"ls"}}' | PATH=/nonexistent /bin/bash "$DESTRUCTIVE" 2>/dev/null)
record ASK "$(decision_of "$out")" "destructive: jq missing → ask"
out=$(printf '%s' '{"tool_input":{"file_path":"a.ts","content":"x"}}' | PATH=/nonexistent /bin/bash "$SECRETS" 2>/dev/null)
record ASK "$(decision_of "$out")" "secret: jq missing → ask"

# ===================================================================
printf '%s' "$FAILURES"
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
