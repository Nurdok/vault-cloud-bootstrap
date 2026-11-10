#!/usr/bin/env bash
# Runs the hooks against tests/bin/ob (a stub of the obsidian-headless CLI) in a
# throwaway HOME. No network, no Obsidian account.   Usage: tests/run.sh [filter]
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="${1:-}"
pass=0; fail=0; current=""

fresh() {   # new HOME with the hooks installed, stub ob first on PATH
  T="$(mktemp -d)"
  export HOME="$T/home" STUB_DIR="$T/stub" CLAUDE_PROJECT_DIR="$T/project"
  mkdir -p "$HOME/.claude/hooks" "$CLAUDE_PROJECT_DIR"
  install -m 755 "$REPO"/hooks/vault-*.sh "$HOME/.claude/hooks/"
  export PATH="$REPO/tests/bin:$ORIG_PATH"
  unset XDG_CONFIG_HOME OBSIDIAN_MFA OBSIDIAN_AUTH_TOKEN
  unset STUB_LOGIN_NETWORK_FAILS
  unset STUB_PASSWORD STUB_VAULT_PASSWORD STUB_TOKEN STUB_MFA STUB_SYNC_FAILS STUB_SYNC_SECONDS STUB_SYNC_HANG
  export OBSIDIAN_EMAIL=me@example.com OBSIDIAN_PASSWORD=pw
  export OBSIDIAN_VAULT_NAME=Vault OBSIDIAN_VAULT_PASSWORD=vpw
  export VAULT_SYNC_RETRY_DELAY=0
  unset VAULT_PUSH_TIMEOUT VAULT_SYNC_MODE
  HOOKS="$HOME/.claude/hooks"; PULL_LOG="$HOOKS/vault-sync-pull.log"; PUSH_LOG="$HOOKS/vault-sync-push.log"
}
worker_running() { pgrep -f "$HOOKS/vault-sync-pull.sh --worker" >/dev/null 2>&1; }
wait_worker() {   # wait for the detached pull worker to exit (default 60s)
  local i
  for i in $(seq 1 $(( ${1:-60} * 5 ))); do worker_running || return 0; sleep 0.2; done
  echo "    worker still running after ${1:-60}s"; return 1
}
pull() { "$HOOKS/vault-sync-pull.sh" </dev/null; sleep 0.3; wait_worker "${1:-60}"; }
push() {   # push [hook-input-json]: stdout (what Claude Code would parse) goes to $T/push.out
  printf '%s' "${1:-{\"hook_event_name\": \"Stop\", \"stop_hook_active\": false\}}" | "$HOOKS/vault-sync-push.sh" >"$T/push.out"
}
calls() { cat "$STUB_DIR/calls" 2>/dev/null; }
stub_count() { cat "$STUB_DIR/$1" 2>/dev/null || echo 0; }

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "  FAIL [$current] $*"; }
has()  { if grep -qE -- "$2" "$1" 2>/dev/null; then ok; else bad "expected /$2/ in $(basename "$1")"; sed 's/^/      /' "$1" 2>/dev/null | tail -15; fi; }
hasnt(){ if grep -qE -- "$2" "$1" 2>/dev/null; then bad "unexpected /$2/ in $(basename "$1")"; else ok; fi; }
eq()   { if [ "$1" = "$2" ]; then ok; else bad "$3: expected '$2', got '$1'"; fi; }

t() {   # t <name> <function>
  case "$1" in *"$FILTER"*) ;; *) return ;; esac
  current="$1"; echo "- $1"
  fresh; "$2"; pkill -f "$HOOKS/vault-sync-pull.sh --worker" 2>/dev/null; rm -rf "$T"
}
ORIG_PATH="$PATH"

# ---- pull worker --------------------------------------------------------------
pull_happy() {
  pull
  has "$PULL_LOG" 'sync ok on attempt 1'
  eq "$(stub_count logins)" 1 "logins"; eq "$(stub_count setups)" 1 "setups"
}
t "pull: logs in, sets up and syncs" pull_happy

pull_missing_var() {
  unset OBSIDIAN_VAULT_NAME
  pull
  has "$PULL_LOG" 'not set in the session environment: OBSIDIAN_VAULT_NAME'
  eq "$(stub_count logins)" 0 "logins"
}
t "pull: skips when a variable is missing" pull_missing_var

pull_retries() {
  export STUB_SYNC_FAILS=2
  pull
  has "$PULL_LOG" 'sync attempt 2 failed'; has "$PULL_LOG" 'sync ok on attempt 3'
  eq "$(stub_count logins)" 1 "logins"
}
t "pull: retries a failing sync" pull_retries

pull_idle_after_synced() {
  export STUB_SYNC_HANG=120
  pull 30
  has "$PULL_LOG" 'sync ok on attempt 1'
}
t "pull: stops an ob that idles after Fully synced" pull_idle_after_synced

pull_seed() {
  mkdir -p "$HOME/vault"; touch "$HOME/vault/.seeded-from-git"
  pull
  eq "$(head -1 "$STUB_DIR/synced-modes")" mirror-remote "mode of the first sync"
  eq "$(cat "$STUB_DIR/vault-state/mode")" bidirectional "mode after reconcile"
  [ ! -e "$HOME/vault/.seeded-from-git" ] && ok || bad "seed marker still present"
}
t "pull: a git-seeded vault reconciles download-only first" pull_seed

# ---- auth ---------------------------------------------------------------------
auth_token() {
  unset OBSIDIAN_EMAIL OBSIDIAN_PASSWORD
  export OBSIDIAN_AUTH_TOKEN=good-token
  pull
  has "$PULL_LOG" 'auth: OBSIDIAN_AUTH_TOKEN'; has "$PULL_LOG" 'sync ok on attempt 1'
  eq "$(stub_count logins)" 0 "logins"
  [ ! -e "$HOME/.config/obsidian-headless/auth_token" ] && ok || bad "token was written to disk"
}
t "auth: OBSIDIAN_AUTH_TOKEN alone is enough" auth_token

auth_token_overrides() {
  export OBSIDIAN_AUTH_TOKEN=good-token OBSIDIAN_PASSWORD=wrong
  pull
  has "$PULL_LOG" 'sync ok on attempt 1'; eq "$(stub_count logins)" 0 "logins"
}
t "auth: the token overrides email and password" auth_token_overrides

auth_bad_token() {
  export OBSIDIAN_AUTH_TOKEN=revoked
  pull
  has "$PULL_LOG" 'vault sync failed'; hasnt "$PULL_LOG" 'sync ok'
  eq "$(stub_count logins)" 0 "logins (must not fall back to the password)"
}
t "auth: a bad token never falls back to a password login" auth_bad_token

auth_no_secrets_in_argv() {
  export OBSIDIAN_PASSWORD='s3cret pw' STUB_PASSWORD='s3cret pw'
  export OBSIDIAN_VAULT_PASSWORD='v4ult pw' STUB_VAULT_PASSWORD='v4ult pw'
  pull
  has "$PULL_LOG" 'sync ok on attempt 1'
  hasnt "$STUB_DIR/calls" 's3cret|v4ult'; hasnt "$PULL_LOG" 's3cret|v4ult'
  has "$STUB_DIR/calls" '^sync-setup .*--device-name claude-cloud'
}
t "auth: passwords are passed on stdin, never as arguments" auth_no_secrets_in_argv

auth_wrong_password() {
  export OBSIDIAN_PASSWORD=wrong
  pull
  eq "$(stub_count logins)" 2 "login attempts"
  has "$PULL_LOG" 'giving up: credentials rejected 2 times'
}
t "auth: a rejected password is tried twice, not ten times" auth_wrong_password

auth_login_network_failure() {
  export STUB_LOGIN_NETWORK_FAILS=3
  pull
  has "$PULL_LOG" 'login failed before reaching Obsidian \(network\); will retry'
  has "$PULL_LOG" 'sync ok on attempt 4'; hasnt "$PULL_LOG" 'giving up'
}
t "auth: a login that fails on the network keeps its retries" auth_login_network_failure

auth_wrong_vault_password() {
  export OBSIDIAN_VAULT_PASSWORD=wrong
  pull
  eq "$(stub_count logins)" 1 "logins"; eq "$(stub_count setups)" 2 "setup attempts"
  has "$PULL_LOG" 'vault setup was rejected'
}
t "auth: a rejected vault password is tried twice" auth_wrong_vault_password

auth_no_vault_password() {
  unset OBSIDIAN_VAULT_PASSWORD; export STUB_VAULT_PASSWORD=''
  pull
  has "$PULL_LOG" 'sync ok on attempt 1'
}
t "auth: the vault password is optional (vault without E2EE)" auth_no_vault_password

auth_missing() {
  unset OBSIDIAN_PASSWORD
  pull
  has "$PULL_LOG" 'not set in the session environment: OBSIDIAN_PASSWORD'
  has "$PULL_LOG" 'either OBSIDIAN_AUTH_TOKEN or OBSIDIAN_EMAIL'
}
t "auth: explains what to set when nothing usable is configured" auth_missing

# ---- push hook ----------------------------------------------------------------
push_happy() {
  pull; push
  eq "$(stub_count syncs)" 2 "syncs"
  has "$PUSH_LOG" 'push ok'; hasnt "$PUSH_LOG" 'PUSH FAILED'
  eq "$(cat "$T/push.out")" "" "hook output on success"
}
t "push: syncs after a pull" push_happy

push_seed_pending() {
  mkdir -p "$HOME/vault"; touch "$HOME/vault/.seeded-from-git"
  push
  has "$PUSH_LOG" 'push skipped'; has "$T/push.out" '"systemMessage".*still download-only'
  push
  eq "$(cat "$T/push.out")" "" "second warning in the same session"
  eq "$(stub_count syncs)" 0 "syncs"
}
t "push: warns once while the git seed is unreconciled" push_seed_pending

push_failure_reported() {
  pull; : >"$STUB_DIR/fail-sync"
  push
  has "$T/push.out" '"decision": "block".*NOT synced'
  has "$PUSH_LOG" 'PUSH FAILED'
  push '{"hook_event_name": "Stop", "stop_hook_active": true}'
  has "$T/push.out" '"systemMessage".*NOT synced'; hasnt "$T/push.out" 'block'
  push
  hasnt "$T/push.out" 'block'   # same failure streak: warn, do not interrupt the agent again
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$T/push.out" && ok || bad "hook output is not valid JSON"
  rm "$STUB_DIR/fail-sync"; push
  eq "$(cat "$T/push.out")" "" "output once the push works again"
  : >"$STUB_DIR/fail-sync"; push
  has "$T/push.out" '"decision": "block"'   # a new streak is reported again
}
t "push: a failed push is reported, never silent" push_failure_reported

push_session_end() {
  pull; : >"$STUB_DIR/fail-sync"
  push '{"hook_event_name": "SessionEnd", "reason": "other"}'
  eq "$(cat "$T/push.out")" "" "output on SessionEnd"; has "$PUSH_LOG" 'PUSH FAILED'
}
t "push: SessionEnd pushes without emitting Stop decisions" push_session_end

push_waits_for_lock() {
  pull
  STUB_SYNC_SECONDS=5 ob sync --path "$HOME/vault" >/dev/null 2>&1 &
  sleep 1; push; wait
  has "$PUSH_LOG" 'another sync holds the vault lock; waiting'; has "$PUSH_LOG" 'push ok'
  eq "$(cat "$T/push.out")" "" "hook output"
}
t "push: waits for a sync that holds the vault lock" push_waits_for_lock

push_during_first_sync() {
  export STUB_SYNC_SECONDS=4
  "$HOOKS/vault-sync-pull.sh" </dev/null; sleep 0.5
  STUB_SYNC_SECONDS=0 push
  has "$PUSH_LOG" 'push ok'; eq "$(cat "$T/push.out")" "" "hook output"
  wait_worker
}
t "push: a turn that ends during the first sync still pushes" push_during_first_sync

push_idle_after_synced() {
  pull; export STUB_SYNC_HANG=120
  local start=$SECONDS; push
  has "$PUSH_LOG" 'push ok'
  [ $((SECONDS - start)) -lt 20 ] && ok || bad "push took $((SECONDS - start))s"
}
t "push: stops an ob that idles after Fully synced" push_idle_after_synced

push_timeout() {
  pull; export STUB_SYNC_SECONDS=120 VAULT_PUSH_TIMEOUT=3
  push
  has "$T/push.out" 'no completed sync within 3s'
  has "$STUB_DIR/signals" 'term'   # stopped with SIGTERM, so ob can shut down cleanly
}
t "push: gives up at its own deadline and stops ob cleanly" push_timeout

push_never_set_up() {
  mkdir -p "$HOME/vault"
  push
  has "$T/push.out" 'never set up for sync'
}
t "push: reports a vault that was never set up" push_never_set_up

# ---- read-only mode -------------------------------------------------------------
mode_pull_only() {
  export VAULT_SYNC_MODE=pull-only
  pull; push
  has "$PULL_LOG" 'read-only in this environment'; has "$PULL_LOG" 'sync ok on attempt 1'
  eq "$(sort -u "$STUB_DIR/synced-modes")" pull-only "modes synced in"
  eq "$(stub_count syncs)" 1 "syncs (the push hook must not sync)"
  has "$PUSH_LOG" 'push skipped \(read-only vault\)'; eq "$(cat "$T/push.out")" "" "hook output"
}
t "mode: pull-only never uploads" mode_pull_only

mode_seed_then_pull_only() {
  export VAULT_SYNC_MODE=pull-only
  mkdir -p "$HOME/vault"; touch "$HOME/vault/.seeded-from-git"
  pull
  eq "$(head -1 "$STUB_DIR/synced-modes")" mirror-remote "mode of the first sync"
  eq "$(cat "$STUB_DIR/vault-state/mode")" pull-only "mode after reconcile"
}
t "mode: a seeded vault ends in the configured mode" mode_seed_then_pull_only

mode_default_bidirectional() {
  pull
  eq "$(sort -u "$STUB_DIR/synced-modes")" bidirectional "modes synced in"
}
t "mode: default is bidirectional" mode_default_bidirectional

mode_invalid() {
  export VAULT_SYNC_MODE=readonly
  pull
  has "$PULL_LOG" "VAULT_SYNC_MODE='readonly' is not"
  eq "$(stub_count syncs)" 0 "syncs"
}
t "mode: an unknown mode syncs nothing" mode_invalid

# ---- pull worker concurrency ----------------------------------------------------
pull_single_worker() {
  export STUB_SYNC_SECONDS=3
  "$HOOKS/vault-sync-pull.sh" </dev/null; sleep 0.5
  "$HOOKS/vault-sync-pull.sh" </dev/null
  wait_worker
  has "$PULL_LOG" 'sync worker already running, not starting another'
  has "$PULL_LOG" 'sync ok on attempt 1'   # the first worker's log was not truncated
  eq "$(stub_count syncs)" 1 "syncs"
  pull; eq "$(stub_count syncs)" 2 "syncs after a later session start"
}
t "pull: a second SessionStart does not start a second worker" pull_single_worker

# ---- build: bootstrap.sh and setup.sh ------------------------------------------
build() {   # run setup.sh the way the bootstrap does; output in $T/build.out
  CLAUDE_MD_PATH="$HOME/CLAUDE.md" bash "$REPO/setup.sh" >"$T/build.out" 2>&1
}
bootstrap_with() {   # bootstrap_with <sed-expr>...: run an edited copy of bootstrap.sh
  local args=(-e '') e
  for e in "$@"; do args+=(-e "$e"); done
  sed "${args[@]}" "$REPO/bootstrap.sh" >"$T/bootstrap.sh"
  bash "$T/bootstrap.sh" >"$T/bootstrap.out" 2>&1
}

bootstrap_unpinned() {
  bootstrap_with; eq $? 1 "exit code with an empty SETUP_COMMIT"
  has "$T/bootstrap.out" 'SETUP_COMMIT must be a full 40-character commit SHA'
  bootstrap_with "s/^SETUP_COMMIT=.*/SETUP_COMMIT='main'/"; eq $? 1 "exit code with a branch name"
  has "$T/bootstrap.out" "got 'main'"
}
t "bootstrap: refuses a SETUP_COMMIT that is not a full SHA" bootstrap_unpinned

bootstrap_token_host() {
  # An unreachable non-GitHub repo: the fetch fails, and the token must not be probed against it.
  bootstrap_with "s/^SETUP_COMMIT=.*/SETUP_COMMIT='$(printf 'a%.0s' $(seq 40))'/" \
    "s#^SETUP_REPO=.*#SETUP_REPO='file://$T/nope'#" "s/^GITHUB_TOKEN=.*/GITHUB_TOKEN='github_pat_x'/"
  eq $? 1 "exit code"
  has "$T/bootstrap.out" 'not on https://github.com/, so the GitHub token was not used'
  hasnt "$T/bootstrap.out" 'answered the token'
}
t "bootstrap: never sends the GitHub token to another host" bootstrap_token_host

setup_pins_ob() {
  export STUB_OB_INSTALLED=0.0.1
  build; eq $? 0 "setup.sh exit code"
  has "$STUB_DIR/npm-installs" 'obsidian-headless@0\.0\.14$'
  rm -f "$STUB_DIR/npm-installs"; export STUB_OB_INSTALLED=0.0.14
  build
  [ ! -e "$STUB_DIR/npm-installs" ] && ok || bad "reinstalled although the pinned version is present"
  rm -f "$STUB_DIR/npm-installs"
  OBSIDIAN_HEADLESS_VERSION=9.9.9 build
  has "$STUB_DIR/npm-installs" 'obsidian-headless@9\.9\.9$'
}
t "setup: installs the pinned obsidian-headless version" setup_pins_ob

setup_registers_hooks() {
  export STUB_OB_INSTALLED=0.0.14
  mkdir -p "$HOME/.claude"
  # An image built by an older setup.sh: matcher "*", and someone else's hook.
  cat >"$HOME/.claude/settings.json" <<'JSON'
{"hooks": {"SessionStart": [
  {"matcher": "*", "hooks": [{"type": "command", "command": "~/.claude/hooks/vault-sync-pull.sh", "timeout": 30}]},
  {"matcher": "startup", "hooks": [{"type": "command", "command": "other.sh"}]}]}}
JSON
  build; build
  python3 - "$HOME/.claude/settings.json" >"$T/hooks.txt" <<'PY'
import json, sys
for event, entries in json.load(open(sys.argv[1]))["hooks"].items():
    for e in entries:
        for h in e["hooks"]:
            print(event, e.get("matcher", "-"), h["command"], h.get("timeout", "-"))
PY
  has "$T/hooks.txt" '^SessionStart startup\|resume ~/.claude/hooks/vault-sync-pull.sh 30$'
  has "$T/hooks.txt" '^SessionStart startup other.sh'
  has "$T/hooks.txt" '^Stop - ~/.claude/hooks/vault-sync-push.sh 150$'
  has "$T/hooks.txt" '^SessionEnd - ~/.claude/hooks/vault-sync-push.sh 150$'
  eq "$(wc -l <"$T/hooks.txt" | tr -d ' ')" 4 "registered hooks after two builds"
}
t "setup: registers hooks once, with the right matchers" setup_registers_hooks

# ---- per-project secrets --------------------------------------------------------
with_secrets() {   # build with an age key, and give the vault some _env files for this project
  export STUB_OB_INSTALLED=0.0.14
  AGE_KEY=AGE-SECRET-KEY-TEST build || bad "setup.sh failed"
  git -C "$CLAUDE_PROJECT_DIR" init -q
  local d="$HOME/vault/_env/project" f; mkdir -p "$d"
  for f in "$@"; do echo "secret of $f" >"$d/$f.age"; done
}

secrets_decrypt() {
  with_secrets __dot__env __dot__env.local
  pull
  eq "$(cat "$CLAUDE_PROJECT_DIR/.env" 2>/dev/null)" "secret of __dot__env" ".env content"
  [ -f "$CLAUDE_PROJECT_DIR/.env.local" ] && ok || bad ".env.local not written"
  has "$CLAUDE_PROJECT_DIR/.git/info/exclude" '^/\.env$'; has "$CLAUDE_PROJECT_DIR/.git/info/exclude" '^/\.env\.local$'
  eq "$(git -C "$CLAUDE_PROJECT_DIR" status --porcelain)" "" "git status (secrets must be ignored)"
  [ ! -e "$HOOKS/.decrypt.sh" ] && ok || bad ".decrypt.sh left on disk after the worker"
  hasnt "$HOME/.claude/vault-cloud-bootstrap/build.log" 'AGE-SECRET-KEY-TEST'
}
t "secrets: .env files are decrypted and git-ignored" secrets_decrypt

secrets_name_filter() {
  with_secrets __dot__env __dot__mcp.json Makefile __dot__envrc __dot__env.example
  pull
  [ -f "$CLAUDE_PROJECT_DIR/.env" ] && ok || bad ".env not written"
  local f
  for f in .mcp.json Makefile .envrc .env.example; do
    [ ! -e "$CLAUDE_PROJECT_DIR/$f" ] && ok || bad "$f was written"
  done
  has "$PULL_LOG" "skip \.mcp\.json \(name does not match"
}
t "secrets: only names matching the pattern are written" secrets_name_filter

secrets_no_symlink() {
  with_secrets __dot__env
  ln -s "$T/outside" "$CLAUDE_PROJECT_DIR/.env"
  pull
  [ ! -e "$T/outside" ] && ok || bad "wrote through a symlink to outside the project"
  has "$PULL_LOG" 'skip existing \.env'
}
t "secrets: never writes through a symlink" secrets_no_symlink

secrets_key_removed_without_worker() {
  with_secrets __dot__env
  unset OBSIDIAN_PASSWORD
  pull
  [ ! -e "$HOOKS/.decrypt.sh" ] && ok || bad "age key left on disk although no worker ran"
  has "$PULL_LOG" 'removed \.decrypt\.sh'
}
t "secrets: the key is removed when no sync can run" secrets_key_removed_without_worker

# ---- static checks ------------------------------------------------------------
static() {
  local f
  for f in "$REPO"/bootstrap.sh "$REPO"/setup.sh "$REPO"/hooks/*.sh "$REPO"/tests/run.sh "$REPO"/tests/bin/ob; do
    bash -n "$f" && ok || bad "bash -n $f"
  done
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$REPO"/bootstrap.sh "$REPO"/setup.sh "$REPO"/hooks/*.sh && ok || bad "shellcheck"
  else
    echo "    shellcheck not installed; skipped"
  fi
}
t "static: scripts parse and pass shellcheck" static

echo
echo "$pass checks passed, $fail failed"
[ "$fail" -eq 0 ]
