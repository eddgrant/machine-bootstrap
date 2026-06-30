#!/usr/bin/env bash
set -euo pipefail

# Runs a single install_* function the way the autoload framework does at
# runtime: put ~/.zsh-functions on fpath, autoload every function, then call the
# requested one. This mirrors ~/.zshrc.d/autoload-edds-zsh-functions.zsh exactly,
# without depending on an interactive ~/.zshrc opting into the zshrc.d plugin.
#
# Invoking via autoload (rather than `zsh ~/.zsh-functions/install_foo`) is what
# makes the shared helpers - download_file, add_signed_apt_repository,
# clone_or_pull - resolvable when an installer calls them.
#
# Usage: run-installer.sh <install_function_name>
#
# Prerequisite: bootstrap-my-machine.sh has already run on this machine, so
# ~/.zsh-functions is populated and oh-my-zsh is installed.

fn="${1:?usage: run-installer.sh <install_function_name>}"

export DEBIAN_FRONTEND=noninteractive
# install_aws_vault (and other oh-my-zsh plugin installers) reference ZSH_CUSTOM,
# which oh-my-zsh defines in an interactive shell but not in this non-login zsh.
export ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

functions_dir="$HOME/.zsh-functions"
if [ ! -d "$functions_dir" ]; then
  echo "run-installer: $functions_dir not found - did bootstrap-my-machine.sh run first?" >&2
  exit 1
fi

echo "==> Running ${fn} via the autoload framework"

# -e so a failing installer propagates a non-zero exit to the CI step. The
# (:t) glob qualifier strips each path to its tail, so autoload receives bare
# function names - this line must stay unquoted for the qualifier to apply.
zsh -e -c "
  fpath=(${functions_dir} \$fpath)
  autoload -Uz ${functions_dir}/*(:t)
  ${fn}
"
