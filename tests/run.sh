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
