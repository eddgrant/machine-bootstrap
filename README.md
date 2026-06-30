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
`add_signed_apt_repository` (key import + apt source + refresh) and
`clone_or_pull`.

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

CI verifies that each installer **runs to completion**, not that the resulting
GUI app launches — the runner has no display server.

## Scope

Targets Ubuntu on `amd64`. Many installers assume `amd64` package URLs.
