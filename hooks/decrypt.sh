#!/usr/bin/env bash
set -uo pipefail
ROOT="${1:?usage: .decrypt.sh <project-dir>}"
VAULT_DIR="$HOME/vault"
AGE_KEY='__AGE_KEY__'
# Only files whose decoded name matches this (extended) glob are written. Encrypting to
# the age recipient needs only the public key, so anyone who can write to the
# vault (including an agent in another session) can add a file under _env/. The
# default, .env and .env.<anything>, keeps that to dotenv files and out of names
# a tool would execute or load on its own (.mcp.json, .envrc, Makefile, ...).
NAME_PATTERN='__NAME_PATTERN__'
DOT="__dot__"

REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
REPO="$(basename -s .git "$REMOTE" 2>/dev/null || true)"
[ -n "$REPO" ] || REPO="$(basename "$ROOT")"
SRCDIR="$VAULT_DIR/_env/$REPO"

[ -d "$SRCDIR" ] || { echo "no _env/$REPO in vault"; exit 0; }
command -v age >/dev/null 2>&1 || { echo "age missing"; exit 0; }

# Decrypted secrets must never be committed by a later `git add -A`. The
# exclude file is local to this clone, so the repository itself is not changed.
EXCLUDE="$(git -C "$ROOT" rev-parse --git-path info/exclude 2>/dev/null || true)"
case "$EXCLUDE" in ""|/*) ;; *) EXCLUDE="$ROOT/$EXCLUDE" ;; esac
git_exclude() {
  [ -n "$EXCLUDE" ] || return 0
  mkdir -p "$(dirname "$EXCLUDE")" 2>/dev/null || return 0
  grep -qxF -- "/$1" "$EXCLUDE" 2>/dev/null || printf '/%s\n' "$1" >>"$EXCLUDE"
}

umask 077
shopt -s nullglob extglob
for enc in "$SRCDIR"/*.age; do
  name="$(basename "$enc" .age)"; name="${name//$DOT/.}"   # decode __dot__ -> .
  dest="$ROOT/$name"
  # shellcheck disable=SC2254  # NAME_PATTERN is meant to be matched as a glob
  case "$name" in
    .env.example|.env.sample|.env.template) echo "skip $name (not a secrets file)"; continue ;;
    $NAME_PATTERN) ;;
    *) echo "skip $name (name does not match '$NAME_PATTERN')"; continue ;;
  esac
  # -L: never write through a symlink, which could point outside the project.
  if [ -e "$dest" ] || [ -L "$dest" ]; then echo "skip existing $name"; continue; fi
  if age -d -i <(printf '%s\n' "$AGE_KEY") "$enc" > "$dest"; then
    git_exclude "$name"
    echo "wrote $name"
  else
    rm -f "$dest"; echo "decrypt failed for $name"
  fi
done
