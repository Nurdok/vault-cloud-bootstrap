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
  unset STUB_PASSWORD STUB_VAULT_PASSWORD STUB_TOKEN STUB_MFA STUB_SYNC_FAILS STUB_SYNC_SECONDS STUB_SYNC_HANG
  export OBSIDIAN_EMAIL=me@example.com OBSIDIAN_PASSWORD=pw
  export OBSIDIAN_VAULT_NAME=Vault OBSIDIAN_VAULT_PASSWORD=vpw
  export VAULT_SYNC_RETRY_DELAY=0
  HOOKS="$HOME/.claude/hooks"; PULL_LOG="$HOOKS/vault-sync-pull.log"; PUSH_LOG="$HOOKS/vault-sync-push.log"
}
worker_running() { pgrep -f "$HOOKS/vault-sync-pull.sh --worker" >/dev/null 2>&1; }
wait_worker() {   # wait for the detached pull worker to exit (default 60s)
  local i
  for i in $(seq 1 $(( ${1:-60} * 5 ))); do worker_running || return 0; sleep 0.2; done
  echo "    worker still running after ${1:-60}s"; return 1
}
pull() { "$HOOKS/vault-sync-pull.sh" </dev/null; sleep 0.3; wait_worker "${1:-60}"; }
push() { "$HOOKS/vault-sync-push.sh" </dev/null; }
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

# ---- push hook ----------------------------------------------------------------
push_happy() {
  pull; push
  eq "$(stub_count syncs)" 2 "syncs"
  hasnt "$PUSH_LOG" 'PUSH FAILED'
}
t "push: syncs after a pull" push_happy

push_seed_pending() {
  mkdir -p "$HOME/vault"; touch "$HOME/vault/.seeded-from-git"
  push
  has "$PUSH_LOG" 'push skipped'
  eq "$(stub_count syncs)" 0 "syncs"
}
t "push: does nothing while the git seed is unreconciled" push_seed_pending

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
