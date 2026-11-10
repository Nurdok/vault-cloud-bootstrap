#!/usr/bin/env bash
# Bootstrap for the Claude Code cloud environment "Setup script": paste this file
# there with the EDIT ME block filled in. All logic lives in the setup repo
# (SETUP_REPO, pinned to SETUP_COMMIT); only configuration and secrets stay in
# the pasted copy.
#
# Rolling out a change: push it to the setup repo, then set SETUP_COMMIT to the
# new commit and save. Editing this script is what makes new sessions rebuild
# the environment; pushing alone does not. Pinning a commit (rather than
# tracking main) also means nobody who can push to the setup repo can change
# what runs with your secrets until you point SETUP_COMMIT at it.
#
# Never `set -x` here: the build log would print the secrets.
set -euo pipefail

# ---- EDIT ME -----------------------------------------------------------------
# Optional: age identity for decrypting _env/<repo>/*.age from the vault into
# each session's project directory. Empty disables .env decryption.
AGE_KEY=''
# Optional: git backup of the vault, for a fast first sync (see README).
VAULT_SEED_REPO=''
# Optional: GitHub fine-grained token with read-only Contents on every private
# repo above and below (a private seed repo, a private fork of the setup repo).
GITHUB_TOKEN=''
# The setup repo: this one, or your fork.
SETUP_REPO='https://github.com/Nurdok/vault-cloud-bootstrap'
# Required: the full 40-character SHA of the setup repo commit to run. Whatever
# this points at runs with your secrets, so a branch name is refused: anyone who
# can push to the branch could change it. Set ALLOW_UNPINNED_SETUP=1 below to
# track a branch anyway (for testing a fork you alone control).
SETUP_COMMIT=''
ALLOW_UNPINNED_SETUP=''
# Optional: obsidian-headless version to install. Empty uses the version pinned
# in setup.sh, which is the one the hooks were tested against.
OBSIDIAN_HEADLESS_VERSION=''
# ------------------------------------------------------------------------------
export GIT_TERMINAL_PROMPT=0   # fail fast instead of asking for a login
say() { echo "[vault-cloud-bootstrap] $*" >&2; }

# Send the token with every github.com request git makes, here and in setup.sh's
# vault seed. It goes in through GIT_CONFIG_* (appended to any entries already
# there), so it never lands in a URL, an argument or a .git/config. These
# variables exist only during the build; sessions never see the token.
if [ -n "$GITHUB_TOKEN" ]; then
  n="${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_$n=http.https://github.com/.extraheader"
  export "GIT_CONFIG_VALUE_$n=Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
  export GIT_CONFIG_COUNT=$((n + 1))
fi

if ! [[ "$SETUP_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  if [ -n "$SETUP_COMMIT" ] && [ "$ALLOW_UNPINNED_SETUP" = 1 ]; then
    say "WARNING: SETUP_COMMIT '$SETUP_COMMIT' is not a full commit SHA; running an unpinned setup."
  else
    say "SETUP_COMMIT must be a full 40-character commit SHA of $SETUP_REPO (got '${SETUP_COMMIT:-<empty>}')."
    say "Copy it from the repo's commit history, or set ALLOW_UNPINNED_SETUP=1 to track a branch."
    exit 1
  fi
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
git -C "$dir" init -q
if ! git -C "$dir" fetch -q --depth 1 "$SETUP_REPO" "$SETUP_COMMIT"; then
  say "Could not fetch $SETUP_REPO at $SETUP_COMMIT."
  if [ -n "$GITHUB_TOKEN" ] && [[ "$SETUP_REPO" != https://github.com/* ]]; then
    # The token is a GitHub credential: never send it to any other host.
    say "SETUP_REPO is not on https://github.com/, so the GitHub token was not used for it."
  elif [ -n "$GITHUB_TOKEN" ]; then
    # Ask GitHub's git endpoint directly: the REST API can be answered by the
    # sandbox proxy, so it says nothing about the token.
    code="$(printf 'user = "x-access-token:%s"\n' "$GITHUB_TOKEN" \
      | curl -sS -K - -o "$dir/probe" -w '%{http_code}' \
          "$SETUP_REPO.git/info/refs?service=git-upload-pack" || true)"
    say "GitHub's git endpoint answered the token with HTTP $code:"
    say "  $(head -c 200 "$dir/probe" 2>/dev/null | tr -d '\0' | head -1)"
    say "200: the token works, check SETUP_COMMIT. 401: invalid or expired token."
    say "403 (\"Write access to repository not granted\", even for a read) or 404:"
    say "the token's repository selection does not include this repo."
  else
    say "If the repo is private, set GITHUB_TOKEN. Otherwise check SETUP_REPO"
    say "and SETUP_COMMIT (a full SHA, or a branch name)."
  fi
  # Names only: an environment-level url.*.insteadOf or extra auth header would
  # redirect or override the token, and shows up here.
  say "git $(git --version | cut -d' ' -f3); http/url/credential config keys:"
  git config --show-origin --name-only --get-regexp '^(http|url|credential)\.' 2>/dev/null \
    | sed -E 's#://[^/@ ]+@#://<redacted>@#g; s/^/[vault-cloud-bootstrap]   /' >&2 || true
  exit 1
fi
git -C "$dir" checkout -q FETCH_HEAD
AGE_KEY="$AGE_KEY" VAULT_SEED_REPO="$VAULT_SEED_REPO" \
  OBSIDIAN_HEADLESS_VERSION="$OBSIDIAN_HEADLESS_VERSION" bash "$dir/setup.sh"
