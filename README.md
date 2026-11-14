# machine-bootstrap

Bootstraps a fresh **Ubuntu** workstation the way I like it, and keeps the
installers honest with CI.

## What it does

`bootstrap-my-machine.sh` does two things:

1. **Sets up a small zsh framework** — installs `zsh`, `oh-my-zsh` and the
   [`zshrc.d`](https://github.com/mattmc3/zshrc.d) autoload plugin, and wires up
   `~/.zsh-functions` so functions placed there autoload on demand.
2. **Writes a library of `install_*` functions** into `~/.zsh-functions`. The
   script does **not** install all that software up front — it gives you
   `install_docker`, `install_brave_browser`, `install_rust`, … to run
   individually, whenever you actually want each tool.

```bash
git clone https://github.com/eddgrant/machine-bootstrap.git
cd machine-bootstrap
./bootstrap-my-machine.sh

# open a new shell so the functions autoload, then install what you need:
exec zsh
install_github_cli
install_docker
```

A few shared helpers back the installers: `download_file`,
`add_signed_apt_repository` (key import + apt source + refresh), `clone_or_pull`
and `run_privileged` (see below).

`install_unattended_upgrades` is a configuration installer rather than an app: it
writes one local apt drop-in (`/etc/apt/apt.conf.d/52unattended-upgrades-local`)
that refreshes package lists daily and also allows the `-updates` pocket alongside
security updates. Automatic reboot is deliberately left off, so reboot by hand
when `/var/run/reboot-required` appears. It is idempotent and checks the result
with `apt-config dump`.

`install_gsconnect` installs GSConnect (KDE Connect for GNOME Shell) and gets it
working. That includes the firewall: Ubuntu's UFW denies inbound traffic by
default and the GNOME extension runs as your user, so it cannot open its own
ports, and without them a phone on the same network never sees the laptop. It
allows TCP and UDP 1714-1764 from `192.168.0.0/16` only, never the internet. To
restrict it further, or to cover other private ranges, list your own networks:

```bash
GSCONNECT_FIREWALL_SOURCES="192.168.5.0/24 192.168.10.0/24" install_gsconnect
```

The firewall step only adds rules (it never enables UFW) and is safe to re-run.
A newly installed extension is not visible to
the running GNOME Shell until you log out and back in, so enable it then.

## Running without sudo

The bootstrap works from an account that has no sudo rights (a standard
daily-driver user with a separate admin account). Every root-needing command goes
through `run_privileged`, which picks a mode per call:

| Mode | When | What it does |
|---|---|---|
| root | already uid 0 | runs the command directly |
| sudo | you are in the `sudo`/`admin`/`wheel` group | `sudo <command>` |
| su | otherwise | `su` to an admin account, which runs `sudo <command>` |

In **su** mode you are asked for the admin account's username once per run, then
for its password. The username is never stored or hard-coded; to skip the prompt,
set it in the environment:

```bash
BOOTSTRAP_ADMIN_USER=<admin-account> ./bootstrap-my-machine.sh
```

`BOOTSTRAP_PRIVILEGE=sudo|su` overrides the automatic choice. Expect a password
prompt per privileged command in su mode: `su` does not cache, although the
admin's `sudo` does for the rest of the run.

> Autoloading requires the `zshrc.d` plugin in your `~/.zshrc` `plugins=(...)`
> list — the bootstrap installs the plugin but doesn't edit an existing
> `~/.zshrc` for you.

## CI

Every installer is exercised on a fresh **GitHub-hosted `ubuntu-latest`** runner
— which is a real Ubuntu VM with passwordless `sudo`, so no self-hosted VM is
needed. The [`CI` workflow](.github/workflows/ci.yml):

- **discovers** the installers straight from the script (add one and CI picks it
  up automatically — see [`ci/list-installers.sh`](ci/list-installers.sh)),
- runs each in its **own matrix job** (`fail-fast: false`) so you get a per-tool
  pass/fail grid, then posts a summary table to the run and to the PR,
- runs **weekly** as a canary for upstream rot (moved download URLs, retired apt
  repos, scraped pages whose markup changed).

Installers are classified in `ci/list-installers.sh`:

| Tier | Meaning |
|---|---|
| **required** | A failure fails the build. |
| **optional** | Run and reported, but allowed to fail — snaps and fragile external sources (Slack's scraped `.deb`, the unofficial Wispr repo, pinned old `.deb`s, etc.). |
| **excluded** | Not run at all — currently just `install_jetbrains_toolbox`, which launches a GUI and would hang headless. |

A separate **`su mode`** job proves the no-sudo path: on a disposable runner,
[`ci/test-su-mode.sh`](ci/test-su-mode.sh) creates an admin account and an account
with no sudo, then runs the bootstrap and `install_unattended_upgrades` as the
latter. A PAM rule lets that one user pair through `su` without a password, so the
`su` -> `sudo` -> command path is exercised but the password prompt itself is not.
The script refuses to run unless `CI_SU_TEST_ALLOW=1`, because it creates users
and edits PAM - never run it on a real machine.

A **`gsconnect`** job goes further for `install_gsconnect`: [`ci/test-gsconnect.sh`](ci/test-gsconnect.sh)
asserts the package is installed, UFW holds exactly the TCP and UDP rules for
`1714:1764` from `192.168.0.0/16`, a re-run adds no duplicates,
`GSCONNECT_FIREWALL_SOURCES` adds the source you ask for, and UFW's enabled state
is untouched. It cannot show that packets really get through, as the runner has no
phone. Like the su-mode test it edits system state, so it needs
`CI_GSCONNECT_TEST_ALLOW=1`.

CI verifies that each installer **runs to completion**, not that the resulting
GUI app launches — the runner has no display server.

## Scope

Targets Ubuntu on `amd64`. Many installers assume `amd64` package URLs.
