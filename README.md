# vault-cloud-bootstrap

Give every [Claude Code](https://claude.com/claude-code) cloud session, on any
repository, a live copy of your [Obsidian](https://obsidian.md) vault, plus
that project's `.env` files.

A Claude Code cloud environment runs a setup script once and caches the result
as an image. This repo is that setup script:

- It installs [`obsidian-headless`](https://www.npmjs.com/package/obsidian-headless)
  and [`age`](https://github.com/FiloSottile/age).
- It can seed the vault from a git backup.
- It installs user-level hooks.

In each session, the hooks then:

- sync the vault from Obsidian Sync in the background at session start;
- decrypt the current project's secrets from the vault;
- push vault edits back at the end of every turn.

The vault stays in Obsidian Sync, and no project repository has to know about
it. This project is not affiliated with Anthropic or Obsidian.

## How it works

```
Environment build (once, cached)          Every session
────────────────────────────────          ─────────────────────────────────────
bootstrap.sh (pasted in the UI)           SessionStart: vault-sync-pull.sh
 └ fetch this repo @ SETUP_COMMIT          └ detached worker, up to 10 tries:
    └ setup.sh                                ob login / sync-setup (first time)
       ├ npm i -g obsidian-headless           ob sync into ~/vault
       ├ apt install age                      decrypt _env/<repo>/*.age → repo
       ├ seed ~/vault from git (optional)     delete the key-bearing script
       ├ install hooks + doctor           Stop (every turn): vault-sync-push.sh
       └ /home/user/CLAUDE.md              └ ob sync (pushes edits)
```

`/home/user/CLAUDE.md` sits in the parent directory of every cloned
repository, so every session loads it. It tells the agent where the vault is
and how to check that the sync has finished. Add your own session-wide
instructions to `templates/user-claude.md`.

## Install

1. **Fork this repo**, or use it as is. Either way, pin a commit: whatever
   `SETUP_COMMIT` points at runs with your secrets. The bootstrap refuses
   anything but a full commit SHA unless you set `ALLOW_UNPINNED_SETUP=1`.
2. In the cloud environment's settings, set these **environment variables**,
   which the session hooks read:
   - `OBSIDIAN_EMAIL`
   - `OBSIDIAN_PASSWORD`
   - `OBSIDIAN_VAULT_NAME`: the remote vault's name in Obsidian Sync.
   - `OBSIDIAN_VAULT_PASSWORD`: its end-to-end encryption password.
   - `OBSIDIAN_MFA` (optional): only if the account uses 2FA. A dedicated
     account without MFA suits automation better.
3. Paste [`bootstrap.sh`](bootstrap.sh) as the environment's **Setup script**
   and fill in its `EDIT ME` block:
   - `SETUP_REPO` and `SETUP_COMMIT`: this repo or your fork, at a full
     40-character commit SHA (required).
   - `OBSIDIAN_HEADLESS_VERSION` (optional): overrides the `obsidian-headless`
     version pinned in `setup.sh`.
   - `AGE_KEY` (optional): an age identity for the per-project secrets below.
   - `VAULT_SEED_REPO` (optional): a git backup of the vault.
   - `GITHUB_TOKEN` (optional): a fine-grained token with read-only
     **Contents** on each private repo above. It is only ever sent to
     `github.com`.
4. Start a session. If the build fails, the UI shows the build output.

To roll out a change, push it to the setup repo, then update `SETUP_COMMIT` in
the pasted bootstrap. The build is cached, so a push alone changes nothing; the
edit to the setup script is what triggers a rebuild.

## Seeding from a git backup

A first sync through Obsidian alone downloads the vault one file at a time,
which takes minutes on every new session. If something already backs the vault
up to git (an hourly job, the Obsidian Git plugin), point `VAULT_SEED_REPO` at
it. The build then copies it into the image in one go, so the session's sync
only has to fetch what changed since the backup.

A seeded vault has no sync history, though. Its files all carry fresh
timestamps, so a normal two-way sync would upload them over newer edits and
bring back notes deleted since the backup. The setup therefore marks the seed
(`~/vault/.seeded-from-git`), and while the marker exists:

- the first sync runs in `mirror-remote` mode: download only, the server wins,
  and files that exist only in the backup are removed;
- the push hook does nothing.

After the first complete pass, the worker switches back to two-way sync and
removes the marker. `_env/` is left out of the seed, so the cached image never
holds the encrypted secrets.

## Per-project secrets

The worker looks for `~/vault/_env/<repo>/`, where `<repo>` is the name of the
session's repository (from its `origin` URL). It decrypts every `*.age` file
there into the project directory, and never overwrites a file that already
exists.

Obsidian Sync skips dotfiles, so a leading dot is spelled `__dot__` in the file
name:

```bash
age -r age1yourrecipient... -o ~/vault/_env/my-repo/__dot__env.age .env   # becomes .env
```

`.age` files are an "unsupported" type for Obsidian Sync, so the setup turns on
syncing for all file types.

**What this protects, and what it does not.** The age key never goes into a
repository or an environment variable. Instead, `setup.sh` bakes it into
`~/.claude/hooks/.decrypt.sh` in the cached image, and the worker deletes that
script once it has run. Until then, the key is a file the session's agent could
read. This keeps secrets out of git and out of the environment variables. It
does not hide them from an agent that goes looking.

## Diagnostics

The build's output only shows in the UI when the build fails. So the image also
keeps:

- `~/.claude/vault-cloud-bootstrap/build.log`: the full build output, with
  secrets redacted.
- `~/.claude/vault-cloud-bootstrap/build-status`: a key=value summary. It
  records the setup commit, tool versions, the seed result and commit, whether
  decryption is installed, the exit code, and the names of git's
  `http`/`url`/`credential` config keys.
- `~/.claude/hooks/vault-sync-pull.log` and `vault-sync-push.log`: what each
  session's hooks did.
- `~/.claude/hooks/vault-doctor.sh`: a report on the build, the session's
  environment variables (set or unset, never their values), the tools, the
  vault, the project's secrets, the hooks and the log tails. The session
  instructions tell the agent to run it when something is missing.

## Gotchas this works around

- **The build and the sessions are different contexts.** The setup script runs
  once, as root and without the egress proxy, and its result is cached. Hooks
  run later in each session, without root and behind an HTTPS proxy. That is
  why everything that needs root, such as `apt install age`, happens at build
  time. Environment variables and the git config set during the build do not
  carry into sessions; that is also why the GitHub token never reaches one.
- **Node ignores `HTTPS_PROXY`.** Its built-in `fetch` and `WebSocket` don't
  use the proxy, and `ob` needs both. `NODE_OPTIONS=--use-env-proxy` (Node
  22.19+) fixes that, and `--disable-warning=UNDICI-EHPA` silences the
  "EnvHttpProxyAgent is experimental" warning it prints on every run.
- **`ob sync` can sit idle after "Fully synced"** following a large download.
  The worker watches the log for that line and stops the process itself.
- **A misleading 403 from GitHub.** When a fine-grained token's repository
  selection leaves out the repo, a read-only clone fails with
  `Write access to repository not granted` (HTTP 403). The bootstrap probes the
  git endpoint and explains the status code.
- **Hooks must not block.** The SessionStart hook only launches a detached
  worker, so the agent can start immediately while the vault syncs.

## Testing

```bash
tests/run.sh
```

That runs the hooks, `bootstrap.sh` and `setup.sh` against stub `ob`, `npm` and
`age` commands in a throwaway `HOME`. It needs no network and no Obsidian
account.

```bash
docker run --rm -v "$PWD":/src:ro node:24-bookworm bash -c \
  'cp -r /src /setup && CLAUDE_MD_PATH=/root/CLAUDE.md bash /setup/setup.sh \
   && ~/.claude/hooks/vault-doctor.sh'
```

The second command builds into a throwaway container with the real tools. Add `-e VAULT_SEED_REPO=...` and
`-e AGE_KEY=...` to exercise the seed and decryption paths, or `-e OBSIDIAN_*`
and run `~/.claude/hooks/vault-sync-pull.sh` to try a real sync.

## Layout

| Path | Installed as | Role |
|---|---|---|
| `bootstrap.sh` | the environment's Setup script | Configuration and secrets; fetches and runs `setup.sh`. |
| `setup.sh` | | Runs at environment build; see its header for the design. |
| `hooks/vault-sync-pull.sh` | `~/.claude/hooks/vault-sync-pull.sh` | SessionStart: background sync and decrypt worker. |
| `hooks/vault-sync-push.sh` | `~/.claude/hooks/vault-sync-push.sh` | Stop: pushes vault edits. |
| `hooks/decrypt.sh` | `~/.claude/hooks/.decrypt.sh` | Template; `setup.sh` bakes the key in. Deleted after use. |
| `hooks/vault-doctor.sh` | `~/.claude/hooks/vault-doctor.sh` | Diagnostic report; prints no secrets. |
| `templates/user-claude.md` | `/home/user/CLAUDE.md` | Instructions for every session. |
