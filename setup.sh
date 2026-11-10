#!/usr/bin/env bash
set -euo pipefail

# vault-cloud-bootstrap: Claude Code cloud environment setup for an Obsidian vault.
#
# Run by bootstrap.sh, which is pasted as the environment's "Setup script". The
# environment build is cached into the snapshot and skipped on later sessions,
# so a change here only lands once the bootstrap's SETUP_COMMIT points at it.
# Installs tooling, optionally seeds ~/vault from a git backup, and installs into
# the cached image:
#
#   ~/.claude/hooks/vault-sync-pull.sh   SessionStart: launches the bg worker (keyless)
#   ~/.claude/hooks/.decrypt.sh          keyed decrypt for the current project (ephemeral)
#   ~/.claude/hooks/vault-sync-push.sh   Stop and SessionEnd: pushes vault edits
#   ~/.claude/hooks/vault-doctor.sh      diagnostic report, run on demand
#   /home/user/CLAUDE.md                 vault instructions for every session
#
# Inputs (environment):
#   AGE_KEY          from the bootstrap; never committed. Empty disables .env
#                    decryption.
#   VAULT_SEED_REPO  git backup of the vault to seed from. Empty skips seeding.
#   (git auth)       the bootstrap passes its GitHub token, if any, to git
#                    through GIT_CONFIG_*, which the seed clone inherits.
#   OBSIDIAN_HEADLESS_VERSION  obsidian-headless version to install. Empty
#                    uses the pinned default below.
#   CLAUDE_MD_PATH   where the session CLAUDE.md goes (override for testing).
#
# Seeding:
#   An Obsidian-only first sync fetches every file one by one (minutes). With a
#   seed repo, ~/vault is instead filled from the git backup in one bulk copy at
#   build time. If the clone fails it is non-fatal: sessions then fall back to a
#   full Obsidian download. A seeded vault has no sync history, and a plain
#   bidirectional sync would treat the backup's files (all stamped "now") as
#   newer and upload them, reverting recent edits and resurrecting deleted
#   notes. So the seed carries a marker, .seeded-from-git: while it exists the
#   pull worker syncs in mirror-remote mode (download-only, server wins,
#   backup-only files removed) and the push hook does nothing. After the first
#   complete pass the worker switches back to bidirectional and drops the
#   marker. _env/ is left out of the seed so the snapshot never holds the
#   ciphertext; it arrives through Obsidian at session time.
#
# Key lifetime / threat model:
#   The age key lives only in the bootstrap (the environment's setup script) and
#   in .decrypt.sh; it reaches this script as AGE_KEY and is never written to the
#   repo. Never `set -x` here or in the bootstrap: the build log would print it.
#   .decrypt.sh is part of the cached image, so every session starts with it on
#   disk. The SessionStart hook returns immediately and runs the sync in a
#   detached background worker, so the agent is never blocked on Obsidian. The
#   worker retries sync up to 10 times, 60s apart. On a successful sync it
#   materializes THIS project's secrets (every file under _env/<repo>/ in the
#   vault) and then removes .decrypt.sh via an EXIT trap (which also fires if
#   all retries fail, so the key never outlives the worker). Until then the key
#   is on disk, readable by the session's agent like any other file: this design
#   keeps the key out of the repo and the environment variables, it does not
#   hide it from a session that goes looking.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_KEY="${AGE_KEY:-}"
VAULT_SEED_REPO="${VAULT_SEED_REPO:-}"
CLAUDE_MD_PATH="${CLAUDE_MD_PATH:-/home/user/CLAUDE.md}"
# obsidian-headless is a 0.0.x beta that syncs the real vault, and the cached
# environment is rebuilt about weekly. Pin the version so a new release only
# lands when this line (or the bootstrap's override) changes.
OB_VERSION_DEFAULT=0.0.14
OB_VERSION="${OBSIDIAN_HEADLESS_VERSION:-$OB_VERSION_DEFAULT}"
export GIT_TERMINAL_PROMPT=0   # an unreachable repo fails fast instead of asking for a login

# Diagnostics for later sessions: the build output only shows in the UI when the
# build fails, so a copy is kept in the image. build.log is the full output with
# secrets redacted (belt and braces: nothing here should print one), and
# build-status is a key=value summary. vault-doctor.sh reads both.
STATE_DIR="$HOME/.claude/vault-cloud-bootstrap"
BUILD_LOG="$STATE_DIR/build.log"
BUILD_STATUS="$STATE_DIR/build-status"
mkdir -p "$STATE_DIR"
: > "$BUILD_STATUS"
redact() {
  sed -u -E \
    -e 's/AGE-SECRET-KEY-[0-9A-Z]+/AGE-SECRET-KEY-<redacted>/g' \
    -e 's/(github_pat_|ghp_|gho_|ghs_|ghu_)[A-Za-z0-9_]+/\1<redacted>/g' \
    -e 's/(Authorization: *[A-Za-z]+ )[^ ]+/\1<redacted>/g' \
    -e 's#://[^/@ ]+@#://<redacted>@#g'
}
exec > >(redact | tee "$BUILD_LOG") 2>&1
tee_pid=$!
status() { printf '%s=%s\n' "$1" "$2" >>"$BUILD_STATUS"; }
on_exit() {
  local rc=$?
  status build_exit "$rc"
  [ "$rc" -eq 0 ] || echo "[vault-cloud-bootstrap] FAILED with exit code $rc."
  exec >&- 2>&-
  wait "$tee_pid" 2>/dev/null || true
}
trap on_exit EXIT
trap 'echo "[vault-cloud-bootstrap] command failed at setup.sh line $LINENO: $BASH_COMMAND"' ERR

setup_commit="$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "vault-cloud-bootstrap ${setup_commit:0:12} building at $(date -Is) as $(id -un), HOME=$HOME"
status setup_commit "$setup_commit"
status built_at "$(date -Is)"
for proxy_var in HTTPS_PROXY https_proxy HTTP_PROXY NO_PROXY; do
  status "env_$proxy_var" "$([ -n "${!proxy_var:-}" ] && echo set || echo unset)"
done
# Names only (values can hold credentials): shows whether the environment
# rewrites github.com URLs or adds its own auth next to the bootstrap's token.
echo "git $(git --version | cut -d' ' -f3); git http/url/credential config keys:"
git config --show-origin --name-only --get-regexp '^(http|url|credential)\.' 2>/dev/null \
  | sed 's/^/  /' || echo "  (none)"

# 1. Install tooling eagerly (cached). `age` cannot be apt-installed at session
#    time (hooks have no root), so it must land here.
ob_installed() { npm ls -g --depth=0 obsidian-headless 2>/dev/null | grep -o 'obsidian-headless@[^ ]*' | cut -d@ -f2; }
if ! command -v ob >/dev/null 2>&1 || [ "$(ob_installed)" != "$OB_VERSION" ]; then
  npm install -g --no-fund --no-update-notifier "obsidian-headless@$OB_VERSION"
fi
command -v age >/dev/null 2>&1 || { apt-get update && apt-get install -y age; } \
  || echo "[vault-cloud-bootstrap] age install FAILED; sessions cannot decrypt .env files."
status node "$(node --version 2>/dev/null || echo missing)"
status ob "obsidian-headless@$(ob_installed || true)"
status ob_pinned "$OB_VERSION"
status age "$(age --version 2>/dev/null || echo missing)"
# The hooks run ob with this flag; an older Node refuses to start with it.
if node --use-env-proxy -e 0 >/dev/null 2>&1; then
  status node_use_env_proxy ok
else
  status node_use_env_proxy unsupported
  echo "[vault-cloud-bootstrap] node $(node --version 2>/dev/null) rejects --use-env-proxy; ob will not start in the hooks."
fi

mkdir -p ~/.claude/hooks

# 1b. Seed ~/vault from the git backup (see "Seeding" above). The marker is
#     written before any content lands, so a partial seed is never synced
#     bidirectionally.
if [ -z "$VAULT_SEED_REPO" ]; then
  status seed skipped-no-seed-repo
elif [ ! -e ~/vault ]; then
  seed_tmp="$(mktemp -d)"
  if git clone -q --depth 1 "$VAULT_SEED_REPO" "$seed_tmp/vault"; then
    status seed_commit "$(git -C "$seed_tmp/vault" log -1 --format='%H %cI')"
    mkdir -p ~/vault && touch ~/vault/.seeded-from-git
    if git -C "$seed_tmp/vault" archive HEAD -- . ':(exclude)_env' | tar -x -C ~/vault; then
      status seed ok
      echo "[vault-sync init] Seeded ~/vault from $VAULT_SEED_REPO ($(find ~/vault -type f | wc -l) files)."
    else
      status seed extract-incomplete
      echo "[vault-sync init] Seed extraction incomplete; the first sync fills the gaps."
    fi
  else
    status seed clone-failed
    echo "[vault-sync init] Vault seed skipped (clone failed; does the bootstrap's GITHUB_TOKEN cover $VAULT_SEED_REPO?)."
    echo "[vault-sync init] Sessions fall back to a full Obsidian download."
  fi
  rm -rf "$seed_tmp"
else
  status seed skipped-vault-exists
fi

# 2. Keyless hooks: SessionStart launcher/worker and Stop push.
install -m 755 "$HERE/hooks/vault-sync-pull.sh" "$HERE/hooks/vault-sync-push.sh" \
  "$HERE/hooks/vault-doctor.sh" ~/.claude/hooks/

# 3. Ephemeral keyed decrypt (removed by the worker after use). The key is
#    substituted into the template here and nowhere else.
if [ -n "$AGE_KEY" ]; then
  tpl="$(<"$HERE/hooks/decrypt.sh")"
  (umask 077; printf '%s\n' "${tpl//__AGE_KEY__/"$AGE_KEY"}" > ~/.claude/hooks/.decrypt.sh)
  chmod 700 ~/.claude/hooks/.decrypt.sh
  status decrypt installed
else
  status decrypt disabled-no-age-key
  echo "[vault-sync init] AGE_KEY not set; .env decryption disabled."
fi

# 4. Register hooks (idempotent merge; preserves any existing hooks).
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
cfg = json.load(open(path)) if os.path.exists(path) else {}
hooks = cfg.setdefault("hooks", {})
def ensure(event, command, timeout, matcher=None):
    entries = hooks.setdefault(event, [])
    # Drop any earlier registration of the same command, so a rebuild replaces
    # its matcher and timeout instead of keeping stale ones.
    for e in entries:
        e["hooks"] = [h for h in e.get("hooks", []) if h.get("command") != command]
    entries[:] = [e for e in entries if e["hooks"]]
    entry = {"hooks": [{"type": "command", "command": command, "timeout": timeout}]}
    if matcher:
        entry["matcher"] = matcher
    entries.append(entry)
# The launcher returns instantly, so a short timeout is fine. Only a new or
# resumed session needs a sync: "clear" and "compact" keep the same VM and vault.
ensure("SessionStart", "~/.claude/hooks/vault-sync-pull.sh", 30, "startup|resume")
# The push hook budgets 100s for itself (VAULT_PUSH_TIMEOUT), below this limit,
# so ob is stopped cleanly by the hook rather than killed by Claude Code.
ensure("Stop",       "~/.claude/hooks/vault-sync-push.sh", 150)
# A last push when the session ends, for edits made in a turn that never
# reached its Stop hook.
ensure("SessionEnd", "~/.claude/hooks/vault-sync-push.sh", 150)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(path, 0o600)
PY

echo "[vault-sync init] Done. Hooks at ~/.claude/hooks/, registered in ~/.claude/settings.json."
echo

# 5. Configure no idle compaction
python3 - <<'EOF'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    with open(p) as fh:
        d = json.load(fh)
except FileNotFoundError:
    d = {}
d["idleCompaction"] = False
with open(p, "w") as fh:
    json.dump(d, fh, indent=2)
EOF
echo "Disabled idle compaction (settings.json)"
echo

# 6. Session-wide instructions (the vault, topic-switch checks, PR naming).
install -D -m 644 "$HERE/templates/user-claude.md" "$CLAUDE_MD_PATH"
echo "Wrote $CLAUDE_MD_PATH"
echo "Build log kept at $BUILD_LOG; run ~/.claude/hooks/vault-doctor.sh in a session."
