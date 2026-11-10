#!/usr/bin/env bash
set -euo pipefail

HOOKS="$HOME/.claude/hooks"
LOG="$HOOKS/vault-sync-pull.log"
SELF="$HOOKS/vault-sync-pull.sh"
WORKER_LOCK="$HOOKS/.vault-sync-pull.lock"

# ---- background worker re-entry -------------------------------------------
if [ "${1:-}" = "--worker" ]; then
  ROOT="${2:-$PWD}"
  EPHEMERAL="$HOOKS/.decrypt.sh"
  VAULT_DIR="$HOME/vault"
  SEED_MARKER="$VAULT_DIR/.seeded-from-git"
  OB_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-headless"
  SYNC_MODE="${VAULT_SYNC_MODE:-bidirectional}"
  export NODE_OPTIONS="--use-env-proxy --disable-warning=UNDICI-EHPA"

  # One worker per session. A second SessionStart (resume, or the hook firing
  # twice) must not start a competing sync, and must not run the EXIT trap
  # below, which would delete the decrypt script the first worker still needs.
  exec 9>"$WORKER_LOCK"
  if ! flock -n 9; then
    echo "[vault-sync] $(date -Is) a sync worker is already running; this one exits" >>"$LOG"
    exit 0
  fi

  # The key-bearing script never outlives this worker, on any exit path
  # (normal return after success, all-retries-failed, or a caught signal).
  STEP_OUT="$(mktemp)"   # output of the last login / setup call
  trap 'rm -f "$EPHEMERAL" "$STEP_OUT"' EXIT INT TERM

  log() { echo "[vault-sync] $(date -Is) $*" >>"$LOG"; }
  # ob prints a Checking and a Downloading line per file; keep the rest.
  quiet() { grep --line-buffered -vE '^(Checking|Downloading) ' || true; }

  # True if `ob sync` printed "Fully synced" after log line $1.
  synced_since() { awk -v s="$1" 'NR > s && /^Fully synced/ { f = 1 } END { exit !f }' "$LOG"; }

  # Credentials never go on a command line, where any process in the VM could
  # read them from the process list: ob reads a password from stdin when the
  # flag is omitted, and reads OBSIDIAN_AUTH_TOKEN from the environment itself.
  # The timeout covers ob waiting forever for a 2FA code nobody can type.
  login() {
    printf '%s' "$OBSIDIAN_PASSWORD" | timeout 60 ob login --email "$OBSIDIAN_EMAIL" \
      ${OBSIDIAN_MFA:+--mfa "$OBSIDIAN_MFA"} >"$STEP_OUT" 2>&1
  }
  setup() {
    printf '%s' "${OBSIDIAN_VAULT_PASSWORD:-}" | timeout 60 ob sync-setup --path "$VAULT_DIR" \
      --vault "$OBSIDIAN_VAULT_NAME" --device-name "${OBSIDIAN_DEVICE_NAME:-claude-cloud}" >"$STEP_OUT" 2>&1
  }
  # ob exits 2 when it rejects a credential (account password, 2FA code, vault
  # password) and 3 when the vault does not exist. Retrying those ten times a
  # session invites a lockout and cannot succeed, so the worker gives up after
  # MAX_REJECTIONS of them. But `ob login` also exits 2 when the request never
  # reached Obsidian (proxy, DNS, timeout), and that must keep its retries: a
  # failure whose output shows a transport error is not counted.
  MAX_REJECTIONS=2
  rejections=0
  NETWORK_ERRORS='fetch failed|UND_ERR|ECONN|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|EHOSTUNREACH|ENETUNREACH|socket hang up|Proxy response|getaddrinfo|certificate'
  step() {   # step <name> <function>: run it, keep its output in the log, classify a failure
    local rc=0
    "$2" || rc=$?
    cat "$STEP_OUT" >>"$LOG"
    [ "$rc" -ne 0 ] || return 0
    case "$rc" in
      2|3)
        if grep -qE "$NETWORK_ERRORS" "$STEP_OUT"; then
          log "$1 failed before reaching Obsidian (network); will retry"
        else
          rejections=$((rejections + 1))
          log "$1 was rejected (ob exit $rc); check the credentials and vault name"
        fi ;;
    esac
    return 1
  }

  attempt() {
    # OBSIDIAN_AUTH_TOKEN, when set, replaces the account login entirely.
    if [ -z "${OBSIDIAN_AUTH_TOKEN:-}" ] && [ ! -f "$OB_CONFIG_DIR/auth_token" ]; then
      step "login" login || return 1
    fi
    if ! ob sync-status --path "$VAULT_DIR" >/dev/null 2>&1; then
      step "vault setup" setup || return 1
      ob sync-config --path "$VAULT_DIR" \
        --file-types image,audio,video,pdf,unsupported >>"$LOG" 2>&1 || return 1
    fi
    # A git-seeded vault has no sync history: reconcile download-only first.
    if [ -e "$SEED_MARKER" ]; then
      ob sync-config --path "$VAULT_DIR" --mode mirror-remote >>"$LOG" 2>&1 || return 1
    else
      ob sync-config --path "$VAULT_DIR" --mode "$SYNC_MODE" >>"$LOG" 2>&1 || return 1
    fi
    local start pid rc=0
    start=$(wc -l <"$LOG")
    timeout 300 ob sync --path "$VAULT_DIR" > >(quiet >>"$LOG" 9>&-) 2>&1 9>&- & pid=$!
    # ob can sit idle after "Fully synced" following a large download; treat that
    # line as success and stop the process ourselves instead of waiting it out.
    while kill -0 "$pid" 2>/dev/null; do
      if synced_since "$start"; then
        sleep 2; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 0
      fi
      sleep 2
    done
    wait "$pid" || rc=$?
    [ "$rc" -eq 0 ] || synced_since "$start"
  }

  mkdir -p "$VAULT_DIR"
  ok=0
  for i in $(seq 1 10); do
    if attempt; then
      ok=1; log "sync ok on attempt $i"
      if [ -e "$SEED_MARKER" ]; then
        if ob sync-config --path "$VAULT_DIR" --mode "$SYNC_MODE" >>"$LOG" 2>&1; then
          rm -f "$SEED_MARKER"; log "git seed reconciled; sync mode is now $SYNC_MODE"
        else
          log "could not switch to $SYNC_MODE; vault stays download-only"
        fi
      fi
      break
    fi
    log "sync attempt $i failed"
    if [ "$rejections" -ge "$MAX_REJECTIONS" ]; then
      log "giving up: credentials rejected $rejections times; not retrying, to avoid locking the account"
      break
    fi
    if [ "$i" -lt 10 ]; then sleep "${VAULT_SYNC_RETRY_DELAY:-60}"; fi
  done

  if [ "$ok" = 1 ] && [ ! -f "$EPHEMERAL" ]; then
    log "no .decrypt.sh (AGE_KEY was empty at build); no .env injected"
  elif [ "$ok" = 1 ]; then
    if ! bash "$EPHEMERAL" "$ROOT" 2>&1 | while IFS= read -r line; do log "decrypt: $line"; done; then
      log "decrypt step failed"
    fi
  else
    log "vault sync failed; no .env injected this session"
  fi
  # EXIT trap removes "$EPHEMERAL" here.
  exit 0
fi

# ---- launcher path (runs as the SessionStart hook) ------------------------
# Leave a running worker and its log alone (see the lock in the worker).
if [ -e "$WORKER_LOCK" ] && ! flock -n "$WORKER_LOCK" true; then
  echo "[vault-sync] $(date -Is) session start: sync worker already running, not starting another" >>"$LOG"
  exit 0
fi
: > "$LOG"
rm -f "$HOOKS/.vault-seed-warned"   # per-session notice state of the push hook
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
{
  echo "[vault-sync] $(date -Is) session start; project $ROOT"
  echo "[vault-sync] setup commit $(sed -n 's/^setup_commit=//p' "$HOME/.claude/vault-cloud-bootstrap/build-status" 2>/dev/null || true)" \
    "| ob $(command -v ob >/dev/null && echo found || echo MISSING)" \
    "| age $(command -v age >/dev/null && echo found || echo MISSING)" \
    "| .decrypt.sh $([ -f "$HOOKS/.decrypt.sh" ] && echo present || echo absent)" \
    "| seed marker $([ -e "$HOME/vault/.seeded-from-git" ] && echo present || echo absent)"
  echo "[vault-sync] for a full report run ~/.claude/hooks/vault-doctor.sh"
} >>"$LOG"
# Needs the vault name plus either an auth token (preferred: it can be revoked
# and is not the account password) or the account email and password.
# OBSIDIAN_VAULT_PASSWORD is only needed for an end-to-end encrypted vault.
# The worker deletes the key-bearing decrypt script when it exits. When no
# worker is going to run, nothing can be decrypted this session, so the launcher
# removes the script itself rather than leaving the age key on disk.
no_worker() {
  if [ -f "$HOOKS/.decrypt.sh" ]; then
    rm -f "$HOOKS/.decrypt.sh"
    echo "[vault-sync] removed .decrypt.sh: no sync this session, so nothing to decrypt." >>"$LOG"
  fi
}
missing=""
[ -n "${OBSIDIAN_VAULT_NAME:-}" ] || missing="$missing OBSIDIAN_VAULT_NAME"
if [ -n "${OBSIDIAN_AUTH_TOKEN:-}" ]; then
  echo "[vault-sync] auth: OBSIDIAN_AUTH_TOKEN (account email and password are not used)" >>"$LOG"
else
  for v in OBSIDIAN_EMAIL OBSIDIAN_PASSWORD; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  [ -n "$missing" ] || echo "[vault-sync] auth: account email and password" >>"$LOG"
fi
case "${VAULT_SYNC_MODE:-bidirectional}" in
  bidirectional) ;;
  pull-only|mirror-remote)
    echo "[vault-sync] VAULT_SYNC_MODE=$VAULT_SYNC_MODE: the vault is read-only in this environment; edits are not pushed" >>"$LOG" ;;
  *)
    # Fail closed: a typo must not silently become a two-way sync.
    echo "[vault-sync] VAULT_SYNC_MODE='$VAULT_SYNC_MODE' is not bidirectional, pull-only or mirror-remote; vault sync skipped." >>"$LOG"
    no_worker; exit 0 ;;
esac
if [ -n "$missing" ]; then
  {
    echo "[vault-sync] not set in the session environment:$missing; vault sync skipped."
    echo "[vault-sync] set OBSIDIAN_VAULT_NAME and either OBSIDIAN_AUTH_TOKEN or OBSIDIAN_EMAIL + OBSIDIAN_PASSWORD."
  } >>"$LOG"
  no_worker; exit 0
fi

nohup bash "$SELF" --worker "$ROOT" >>"$LOG" 2>&1 &
echo "[vault-sync] background sync started (up to 10 tries, ${VAULT_SYNC_RETRY_DELAY:-60}s apart)." >>"$LOG"
exit 0
