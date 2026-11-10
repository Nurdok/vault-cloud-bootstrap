#!/usr/bin/env bash
set -euo pipefail

HOOKS="$HOME/.claude/hooks"
LOG="$HOOKS/vault-sync-pull.log"
SELF="$HOOKS/vault-sync-pull.sh"

# ---- background worker re-entry -------------------------------------------
if [ "${1:-}" = "--worker" ]; then
  ROOT="${2:-$PWD}"
  EPHEMERAL="$HOOKS/.decrypt.sh"
  VAULT_DIR="$HOME/vault"
  SEED_MARKER="$VAULT_DIR/.seeded-from-git"
  OB_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-headless"
  export NODE_OPTIONS="--use-env-proxy --disable-warning=UNDICI-EHPA"

  # The key-bearing script never outlives this worker, on any exit path
  # (normal return after success, all-retries-failed, or a caught signal).
  trap 'rm -f "$EPHEMERAL"' EXIT INT TERM

  log() { echo "[vault-sync] $(date -Is) $*" >>"$LOG"; }
  # ob prints a Checking and a Downloading line per file; keep the rest.
  quiet() { grep --line-buffered -vE '^(Checking|Downloading) ' || true; }

  # True if `ob sync` printed "Fully synced" after log line $1.
  synced_since() { awk -v s="$1" 'NR > s && /^Fully synced/ { f = 1 } END { exit !f }' "$LOG"; }

  attempt() {
    if [ ! -f "$OB_CONFIG_DIR/auth_token" ]; then
      ob login --email "$OBSIDIAN_EMAIL" --password "$OBSIDIAN_PASSWORD" \
        ${OBSIDIAN_MFA:+--mfa "$OBSIDIAN_MFA"} >>"$LOG" 2>&1 || return 1
    fi
    if ! ob sync-status --path "$VAULT_DIR" >/dev/null 2>&1; then
      ob sync-setup --path "$VAULT_DIR" \
        --vault "$OBSIDIAN_VAULT_NAME" --password "$OBSIDIAN_VAULT_PASSWORD" >>"$LOG" 2>&1 || return 1
      ob sync-config --path "$VAULT_DIR" \
        --file-types image,audio,video,pdf,unsupported >>"$LOG" 2>&1 || return 1
    fi
    # A git-seeded vault has no sync history: reconcile download-only first.
    if [ -e "$SEED_MARKER" ]; then
      ob sync-config --path "$VAULT_DIR" --mode mirror-remote >>"$LOG" 2>&1 || return 1
    fi
    local start pid rc=0
    start=$(wc -l <"$LOG")
    timeout 300 ob sync --path "$VAULT_DIR" > >(quiet >>"$LOG") 2>&1 & pid=$!
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
        if ob sync-config --path "$VAULT_DIR" --mode bidirectional >>"$LOG" 2>&1; then
          rm -f "$SEED_MARKER"; log "git seed reconciled; back to bidirectional sync"
        else
          log "could not switch back to bidirectional; vault stays download-only"
        fi
      fi
      break
    fi
    log "sync attempt $i failed"
    if [ "$i" -lt 10 ]; then sleep "${VAULT_SYNC_RETRY_DELAY:-60}"; fi
  done

  if [ "$ok" = 1 ] && [ ! -f "$EPHEMERAL" ]; then
    log "no .decrypt.sh (AGE_KEY was empty at build); no .env injected"
  elif [ "$ok" = 1 ]; then
    if ! bash "$EPHEMERAL" "$ROOT" 2>&1 | while IFS= read -r line; do log "decrypt: $line"; done; then
      log "decrypt step failed"
    fi
  else
    log "all 10 sync attempts failed; no .env injected this session"
  fi
  # EXIT trap removes "$EPHEMERAL" here.
  exit 0
fi

# ---- launcher path (runs as the SessionStart hook) ------------------------
: > "$LOG"
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
missing=""
for v in OBSIDIAN_EMAIL OBSIDIAN_PASSWORD OBSIDIAN_VAULT_NAME OBSIDIAN_VAULT_PASSWORD; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "[vault-sync] not set in the session environment:$missing; vault sync skipped." >>"$LOG"
  exit 0
fi

nohup bash "$SELF" --worker "$ROOT" >>"$LOG" 2>&1 &
echo "[vault-sync] background sync started (up to 10 tries, 60s apart)." >>"$LOG"
exit 0
