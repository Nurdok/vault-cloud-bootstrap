#!/usr/bin/env bash
# Prints the state of the vault setup for diagnosing a session: what the build
# did, what this session's hooks did, and what is on disk now. Prints no secret
# values, only whether they are present. Safe to run any time, any number of times.
set -uo pipefail

HOOKS="$HOME/.claude/hooks"
STATE_DIR="$HOME/.claude/vault-cloud-bootstrap"
VAULT_DIR="$HOME/vault"
OB_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-headless"
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

section() { printf '\n== %s\n' "$1"; }
present() { [ -e "$1" ] && echo present || echo absent; }

section "Build (environment setup, cached in the image)"
if [ -f "$STATE_DIR/build-status" ]; then
  sed 's/^/  /' "$STATE_DIR/build-status"
  echo "  full log: $STATE_DIR/build.log"
else
  echo "  no build-status: the image was built by a setup.sh without diagnostics"
fi

section "Session environment (values hidden)"
for var in OBSIDIAN_AUTH_TOKEN OBSIDIAN_EMAIL OBSIDIAN_PASSWORD OBSIDIAN_MFA OBSIDIAN_VAULT_NAME OBSIDIAN_VAULT_PASSWORD HTTPS_PROXY; do
  printf '  %-24s %s\n' "$var" "$([ -n "${!var:-}" ] && echo set || echo unset)"
done
if [ -n "${OBSIDIAN_AUTH_TOKEN:-}" ]; then
  echo "  auth method: OBSIDIAN_AUTH_TOKEN (email and password ignored)"
elif [ -n "${OBSIDIAN_EMAIL:-}" ] && [ -n "${OBSIDIAN_PASSWORD:-}" ]; then
  echo "  auth method: account email and password"
else
  echo "  auth method: NONE (set OBSIDIAN_AUTH_TOKEN, or OBSIDIAN_EMAIL and OBSIDIAN_PASSWORD)"
fi
echo "  sync mode: ${VAULT_SYNC_MODE:-bidirectional (default)}"
echo "  project dir: $ROOT"

section "Tools"
echo "  node: $(node --version 2>/dev/null || echo missing)"
echo "  ob:   $(command -v ob || echo missing)"
echo "  age:  $(age --version 2>/dev/null || echo missing)"
if node --use-env-proxy -e 0 >/dev/null 2>&1; then
  echo "  node --use-env-proxy: ok"
else
  echo "  node --use-env-proxy: REJECTED (ob cannot start in the hooks)"
fi

section "Vault"
if [ -d "$VAULT_DIR" ]; then
  echo "  $VAULT_DIR: $(find "$VAULT_DIR" -type f -not -path '*/.obsidian/*' | wc -l) files"
else
  echo "  $VAULT_DIR: missing"
fi
echo "  seed marker (.seeded-from-git, download-only while present): $(present "$VAULT_DIR/.seeded-from-git")"
echo "  ob auth token file (password login only): $(present "$OB_CONFIG_DIR/auth_token")"
if command -v ob >/dev/null 2>&1 && [ -d "$VAULT_DIR" ]; then
  echo "  ob sync-status:"
  NODE_OPTIONS="--use-env-proxy --disable-warning=UNDICI-EHPA" timeout 30 ob sync-status --path "$VAULT_DIR" 2>&1 | sed 's/^/    /'
fi

section "Project secrets"
remote="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
repo="$(basename -s .git "$remote" 2>/dev/null || true)"
[ -n "$repo" ] || repo="$(basename "$ROOT")"
echo "  repo name used for _env lookup: $repo"
if [ -d "$VAULT_DIR/_env/$repo" ]; then
  echo "  $VAULT_DIR/_env/$repo: $(find "$VAULT_DIR/_env/$repo" -name '*.age' | wc -l) .age files"
else
  echo "  $VAULT_DIR/_env/$repo: missing (nothing to decrypt for this project)"
fi
# Project notes live under a project name, which need not match the repo name.
notes="$(grep -rlis --include='*.md' -- "$repo" "$VAULT_DIR"/projects/*/ 2>/dev/null \
  | sed -E "s#^$VAULT_DIR/projects/([^/]+)/.*#\1#" | sort | uniq -c | sort -rn | head -5)"
echo "  vault project folders mentioning $repo (notes count):"
if [ -n "$notes" ]; then echo "$notes" | sed 's/^ */    /'; else echo "    none"; fi
# Present while the worker is still retrying; gone once it has finished.
echo "  .decrypt.sh: $(present "$HOOKS/.decrypt.sh")"

section "Hooks"
python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  settings.json unreadable: {e}")
    sys.exit()
for event, entries in cfg.get("hooks", {}).items():
    for entry in entries:
        for hook in entry.get("hooks", []):
            print(f"  {event}: {hook.get('command')}")
PY
if pgrep -f "vault-sync-pull.sh --worker" >/dev/null 2>&1; then
  echo "  pull worker: running"
else
  echo "  pull worker: not running"
fi

section "Pull log (last 40 lines of $HOOKS/vault-sync-pull.log)"
tail -n 40 "$HOOKS/vault-sync-pull.log" 2>/dev/null | sed 's/^/  /' || echo "  missing"

section "Push log (last 15 lines of $HOOKS/vault-sync-push.log)"
tail -n 15 "$HOOKS/vault-sync-push.log" 2>/dev/null | sed 's/^/  /' \
  || echo "  missing (normal before the first Stop hook of the session)"
