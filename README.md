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
- push vault edits back when a turn completes, and only then, and tell you
  when a push fails.

The vault stays in Obsidian Sync, and no project repository has to know about
it. This project is not affiliated with Anthropic or Obsidian.

## How it works

```
Environment build (once, cached)          Every session
────────────────────────────────          ─────────────────────────────────────
bootstrap.sh (pasted in the UI)           SessionStart: vault-sync-pull.sh
 └ fetch this repo @ SETUP_COMMIT          └ detached worker, up to 10 tries:
    └ setup.sh                                ob login (no token) / sync-setup
       ├ npm i -g obsidian-headless           ob sync into ~/vault
       ├ apt install age                      decrypt _env/<repo>/*.age → repo
       ├ seed ~/vault from git (optional)     delete the key-bearing script
       ├ install hooks + doctor           Stop (each completed turn):
       └ /home/user/CLAUDE.md              vault-sync-push.sh
                                           └ ob sync (pushes edits; reports failure)
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
   - `OBSIDIAN_VAULT_NAME`: the remote vault's name in Obsidian Sync.
   - `OBSIDIAN_VAULT_PASSWORD`: its end-to-end encryption password. Leave it
     out for a vault without end-to-end encryption.
   - `OBSIDIAN_AUTH_TOKEN` (recommended): an Obsidian auth token. When set, it
     is the only credential used and the email and password are ignored. See
     [Authentication](#authentication).
   - `OBSIDIAN_EMAIL` and `OBSIDIAN_PASSWORD`: the account login, used only
     when no token is set.
   - `OBSIDIAN_MFA` (optional): only with the password login, if the account
     uses 2FA. A 2FA code expires within a minute, so this suits a one-off test
     at best.
   - `VAULT_SYNC_MODE` (optional): `bidirectional` (default), or `pull-only`
     or `mirror-remote` for a read-only vault. See
     [Before you let an agent write to your vault](#before-you-let-an-agent-write-to-your-vault).
   - `OBSIDIAN_DEVICE_NAME` (optional): how sessions appear in Sync's version
     history. Defaults to `claude-cloud`.
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

## Before you let an agent write to your vault

By default the sync is two-way. Whatever the agent does under `~/vault`,
including a mistaken bulk edit or deletion, reaches all your devices at the end
of that turn.

- **Keep a backup that Obsidian Sync cannot touch.** Sync's version history is
  the only built-in undo, and its retention is limited. A git backup of the
  vault (the same one `VAULT_SEED_REPO` can seed from) or any file-level backup
  on one of your machines covers what it does not.
- **Start read-only.** Set `VAULT_SYNC_MODE=pull-only` in the environment and
  sessions download the vault but never upload: local edits stay in the session
  and the push hook does nothing. `mirror-remote` additionally reverts local
  edits at each session start. Remove the variable when you want sessions to
  write.
- **Vault content reaches the agent.** The installed `CLAUDE.md` tells the
  agent to read project notes, and a vault usually holds text you did not
  write, such as web clippings. The template tells the agent to treat notes as
  reference material and not to follow instructions found in them. That lowers
  the risk of a planted instruction; it does not remove it. The stronger
  controls are the ones outside the agent: an auth token instead of the account
  password, and the environment's network allowlist.

## Authentication

Everything in a session's environment is readable by the session's agent, so
the question is which credential to expose.

**An auth token (recommended).** Set `OBSIDIAN_AUTH_TOKEN`. `ob` reads the
variable directly, so the hooks never log in and the account password never
enters the environment. A token still gives access to the account's vaults,
but it is not the password, and logging it out revokes it. To get one, log in once anywhere, for example in a throwaway
container, and copy the token:

```bash
docker run --rm -it node:24-bookworm bash -c \
  'npm install -g obsidian-headless >/dev/null && ob login && cat ~/.config/obsidian-headless/auth_token; echo'
```

Do not run `ob logout` there: that revokes the token. It works with 2FA, since
you type the code yourself during that one login.

**Email and password.** Without a token, the worker logs in with
`OBSIDIAN_EMAIL` and `OBSIDIAN_PASSWORD` at the start of every new session.
That puts the account password where the agent can read it, creates a new
login token per session that nothing ever revokes, and cannot work unattended
with 2FA.

Either way, passwords are passed to `ob` on stdin, never as command-line
arguments. If `ob` rejects a credential (account password, 2FA code, vault
password) or cannot find the vault, the worker stops after two rejections
instead of retrying ten times, so a typo cannot lock the account. A login that
fails because the request never reached Obsidian (proxy, DNS, timeout) is not
counted as a rejection and keeps the full ten retries.

## When edits are pushed, and when they are not

The rule is conservative on purpose: **an edit that fails to sync is preferred
to a faulty or partial edit reaching the vault.** A missed push costs one
session's edits. A half-finished edit that syncs lands on every device.

So vault edits leave the session at exactly one point: the Stop hook, when a
turn completes. Nothing else pushes.

- There is no continuous sync. While a turn is running, the agent's
  intermediate states stay in the session.
- Nothing is pushed when a session ends or is cut off mid-turn (the VM pausing,
  a crash, an interrupted turn). Those edits stay in the session. They are
  pushed if a later turn in the same session completes, and lost if the session
  is discarded first. The push hook refuses to run for any event but Stop.
- `ob` is stopped with a signal it shuts down cleanly on, after 100 seconds
  (`VAULT_PUSH_TIMEOUT`), before Claude Code's hook timeout would kill it
  mid-write.

Within that rule, a push that should have happened and did not is never
silent:

- The hook waits for the vault lock when the pull worker or another push is
  still syncing, instead of failing.
- The first failed push of a streak blocks the stop once, so the agent tells
  you; later failures show a warning line until a push succeeds. Every Stop
  retries the push.

What this does not judge is whether a completed turn's edit is *right*. For
that, see [Before you let an agent write to your
vault](#before-you-let-an-agent-write-to-your-vault): `VAULT_SYNC_MODE=pull-only`
stops all uploads.

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
- the push hook does nothing, and says so once per session: edits made to
  `~/vault` before the first sync finishes are reverted by it.

After the first complete pass, the worker switches back to two-way sync and
removes the marker. `_env/` is left out of the seed, so the cached image never
holds the encrypted secrets.

## Per-project secrets

The worker looks for `~/vault/_env/<repo>/`, where `<repo>` is the name of the
session's repository (from its `origin` URL). It decrypts every `*.age` file
there into the project directory, with these limits:

- Only names that decode to `.env` or `.env.<something>` are written
  (`SECRET_NAME_PATTERN` in the bootstrap widens this). Encrypting to an age
  recipient needs only the public key, so anyone who can write to the vault,
  including an agent in another session, can add a file under `_env/`. The
  filter keeps such a file from landing as `.mcp.json`, `.envrc`, a `Makefile`
  or anything else a tool would load or run by itself.
- It never overwrites a file that already exists, and never writes through a
  symlink.
- Each file it writes is added to the clone's `.git/info/exclude`, so a later
  `git add -A` cannot commit a decrypted secret. The repository itself is not
  changed.

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
script once it has run, or the launcher deletes it at session start when no
sync is going to run. Until then, the key is a file the session's agent could
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
- **One sync per vault.** `ob` holds a per-vault lock and a second `ob sync`
  exits at once. The pull worker therefore runs once per session start
  (`startup|resume`, guarded by a lock file), and the push hook waits for the
  lock.

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
| `hooks/vault-sync-push.sh` | `~/.claude/hooks/vault-sync-push.sh` | Stop: pushes vault edits when a turn completes, reports failures. |
| `hooks/decrypt.sh` | `~/.claude/hooks/.decrypt.sh` | Template; `setup.sh` bakes the key in. Deleted after use. |
| `hooks/vault-doctor.sh` | `~/.claude/hooks/vault-doctor.sh` | Diagnostic report; prints no secrets. |
| `templates/user-claude.md` | `/home/user/CLAUDE.md` | Instructions for every session. |
