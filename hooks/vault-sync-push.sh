#!/usr/bin/env bash
# Stop / SessionEnd hook: pushes vault edits to Obsidian Sync.
#
# A push that does not happen is the one way this setup loses work (the VM is
# discarded later, with the edits in it), so a failure is never silent: the
# first failed push of a streak blocks the stop once, which makes the agent
# tell the user, and later ones show a warning line until a push succeeds.
set -uo pipefail
HOOKS="$HOME/.claude/hooks"
LOG="$HOOKS/vault-sync-push.log"
VAULT_DIR="$HOME/vault"
FAILED="$HOOKS/.vault-push-failed"         # present while the last push failed
SEED_WARNED="$HOOKS/.vault-seed-warned"    # the seed warning was shown this session
BUDGET="${VAULT_PUSH_TIMEOUT:-100}"        # seconds; keep below the hook's own timeout

INPUT=""
[ -t 0 ] || INPUT="$(cat 2>/dev/null || true)"
field() { printf '%s' "$INPUT" | grep -oE "\"$1\" *: *(\"[^\"]*\"|[a-z]+)" | head -1 | sed -E 's/^[^:]*: *"?//; s/"$//'; }
EVENT="$(field hook_event_name)"; EVENT="${EVENT:-Stop}"
STOP_ACTIVE="$(field stop_hook_active)"

log() { echo "[vault-sync] $(date -Is) $*" >>"$LOG"; }
# Messages are fixed text, so they need no JSON escaping.
warn_user() { [ "$EVENT" = Stop ] && printf '{"systemMessage": "%s"}\n' "$1"; return 0; }
block_stop() { printf '{"decision": "block", "reason": "%s"}\n' "$1"; }

[ -d "$VAULT_DIR" ] || exit 0

# A read-only environment never uploads: nothing to push, nothing to report.
if [ "${VAULT_SYNC_MODE:-bidirectional}" != bidirectional ]; then
  log "VAULT_SYNC_MODE=${VAULT_SYNC_MODE}; push skipped (read-only vault)."
  exit 0
fi

if [ -e "$VAULT_DIR/.seeded-from-git" ]; then
  log "git seed not reconciled yet; push skipped."
  if [ ! -e "$SEED_WARNED" ]; then
    : >"$SEED_WARNED"
    warn_user "Obsidian vault: the first sync has not finished, so ~/vault is still download-only. Edits made to it so far are not pushed and will be reverted. See ~/.claude/hooks/vault-sync-pull.log."
  fi
  exit 0
fi

fail() {   # fail <log line>
  log "PUSH FAILED: $1. Vault edits are NOT synced."
  local msg="Obsidian vault push failed: edits under ~/vault are NOT synced to Obsidian Sync ($1). Details: ~/.claude/hooks/vault-sync-push.log and ~/.claude/hooks/vault-doctor.sh."
  if [ "$EVENT" = Stop ] && [ ! -e "$FAILED" ] && [ "$STOP_ACTIVE" != true ]; then
    : >"$FAILED"
    block_stop "$msg Tell the user this now, in one or two sentences, and do not retry by hand: the push is retried automatically when this turn ends."
  else
    : >"$FAILED"
    warn_user "$msg"
  fi
  exit 0
}

command -v ob >/dev/null 2>&1 || fail "ob is not installed"
export NODE_OPTIONS="--use-env-proxy --disable-warning=UNDICI-EHPA"
deadline=$(( $(date +%s) + BUDGET ))
left() { echo $(( deadline - $(date +%s) )); }
worker_running() { pgrep -f "$HOOKS/vault-sync-pull.sh --worker" >/dev/null 2>&1; }

# The pull worker sets the vault up; give it time before calling the vault unconfigured.
while ! ob sync-status --path "$VAULT_DIR" >/dev/null 2>&1; do
  if ! worker_running; then fail "the vault was never set up for sync in this session"; fi
  if [ "$(left)" -le 0 ]; then fail "the first sync is still running"; fi
  sleep 3
done

log "push start ($EVENT)"
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
while :; do
  : >"$out"
  # SIGTERM (not SIGKILL) at the deadline: ob then stops cleanly instead of being
  # killed mid-write by the hook's own timeout.
  timeout "$(( $(left) > 1 ? $(left) : 1 ))" ob sync --path "$VAULT_DIR" >"$out" 2>&1 & pid=$!
  # ob can sit idle after "Fully synced"; treat that line as success and stop it.
  synced=0
  while kill -0 "$pid" 2>/dev/null; do
    if grep -q '^Fully synced' "$out"; then
      synced=1; sleep 1; kill "$pid" 2>/dev/null || true; break
    fi
    sleep 1
  done
  rc=0; wait "$pid" 2>/dev/null || rc=$?
  grep -q '^Fully synced' "$out" && synced=1
  grep -vE '^(Checking|Downloading) ' "$out" >>"$LOG" || true
  if [ "$synced" = 1 ]; then break; fi
  # ob takes a per-vault lock; the pull worker (or another push) may hold it.
  if grep -q 'Another sync instance is already running' "$out" && [ "$(left)" -gt 3 ]; then
    log "another sync holds the vault lock; waiting ($(left)s left)"
    sleep 3; continue
  fi
  if [ "$rc" -eq 124 ] || [ "$(left)" -le 0 ]; then fail "no completed sync within ${BUDGET}s"; fi
  fail "ob sync exited with status $rc"
done

log "push ok"
rm -f "$FAILED"
exit 0
