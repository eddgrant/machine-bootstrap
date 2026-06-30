#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Curated output + per-run logging
#
# Noisy command output (apt, git, curl) is redirected to a per-run log file;
# the terminal gets deliberate one-line status updates instead. The log path is
# printed at the end and whenever a step fails.
# ---------------------------------------------------------------------------
LOG_DIR="/tmp/bootstrap-my-machine"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/$(date +%Y%m%d-%H%M%S).log"

if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
else
  C_RESET=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''
fi

info() { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok()   { printf '    %s\xe2\x9c\x93%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '    %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }

# run_step "Human-readable description" command [args...]
# Prints a status line, runs the command with all output appended to the log,
# and reports success/failure. Returns the command's exit code so the caller can
# decide whether a failure is fatal (bare call -> set -e aborts) or tolerable
# (append '|| warn ...').
run_step() {
  local description="$1"; shift
  info "${description}"
  printf '\n===== %s =====\n' "${description}" >> "${LOG_FILE}"
  if "$@" >> "${LOG_FILE}" 2>&1; then
    ok "${description}"
  else
    local rc=$?
    warn "${description} failed (exit ${rc}) - see ${LOG_FILE}"
    return "${rc}"
  fi
}

# Reprint the log location if we abort partway through.
trap 'rc=$?; if [ "${rc}" -ne 0 ]; then printf "\n%sBootstrap aborted (exit %s). Full log: %s%s\n" "${C_YELLOW}" "${rc}" "${LOG_FILE}" "${C_RESET}"; fi' EXIT

# We use sudo throughout; prompt for it once up front so the password prompt
# isn't hidden inside a redirected step (which would look like a silent hang).
info "This bootstrap needs sudo for system package installs."
sudo -v

# ---------------------------------------------------------------------------
# Framework bootstrap
#
# This script delivers software installers as autoloaded zsh functions
# (install_*, created further down). The framework those functions rely on —
# zsh, oh-my-zsh and the zshrc.d autoload plumbing — is set up here,
# imperatively, because nothing can be autoloaded until it exists.
#
# git is part of the bootstrap (not an optional install_* function) because the
# oh-my-zsh installer and the zshrc.d plugin are cloned with git, as are several
# install_* functions via clone_or_pull. Ubuntu's own git (2.53+) is current
# enough now, so we no longer add the git-core PPA. (If the PPA is still
# configured from a previous run you can remove it manually.)
# ---------------------------------------------------------------------------

# Install git. A flaky mirror shouldn't abort the whole bootstrap, so apt update
# failures are tolerated (apt falls back to cached package lists anyway).
run_step "Refreshing apt package lists" sudo apt-get update \
  || warn "apt update reported errors (often a transient mirror sync) - continuing with cached package lists"
run_step "Installing git" sudo apt-get install -y git

# Install zsh
run_step "Installing zsh" sudo apt-get install -y zsh

# Install oh-my-zsh
if [ ! -d ~/.oh-my-zsh ]; then
  run_step "Installing oh-my-zsh" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  # sudo chsh uses the cached sudo credentials rather than prompting for the
  # user's password mid-run (which the log redirection would hide).
  run_step "Setting zsh as the default shell" sudo chsh -s "$(command -v zsh)" "$USER"
else
  ok "oh-my-zsh already installed"
fi

clone_or_pull() {
  local repo_url="$1"
  local target_dir="$2"
  if [ -d "${target_dir}/.git" ]; then
    echo "Repository '${1}' already exists in ${target_dir}, updating"
    (cd "${target_dir}" && git pull)
  else
    echo "Cloning '${repo_url}' to '${target_dir}'"
    git clone --depth=1 "${repo_url}" "${target_dir}"
  fi
}

# Names of every function created via create_zsh_function, for the closing
# summary that tells the user what's now available to run.
CREATED_ZSH_FUNCTIONS=()

create_zsh_function () {
  local function_name="$1"
  local function_file="${ZSH_FUNCTIONS_DIR}/${function_name}"
  cat > "${function_file}"
  CREATED_ZSH_FUNCTIONS+=("${function_name}")
}

# Create ZSH functions directory
ZSH_FUNCTIONS_DIR="$HOME/.zsh-functions"
mkdir -p  "${ZSH_FUNCTIONS_DIR}"

# Install zshrc.d plugin - https://github.com/mattmc3/zshrc.d
# This finishes the framework: the autoload config below is loaded by the
# zshrc.d plugin, which is what makes the install_* functions available.
ZSH_CUSTOM=${ZSH_CUSTOM:-~/.oh-my-zsh/custom}
run_step "Installing the zshrc.d plugin" clone_or_pull https://github.com/mattmc3/zshrc.d "${ZSH_CUSTOM}/plugins/zshrc.d"
mkdir -p ~/.zshrc.d

# Write shell config: autoload the functions, and define aliases.
info "Writing shell configuration (autoload + aliases)"
cat << EOF > ~/.zshrc.d/autoload-edds-zsh-functions.zsh
fpath=("${ZSH_FUNCTIONS_DIR}" \$fpath)
autoload -Uz ${ZSH_FUNCTIONS_DIR}/*(:t)
EOF
cat << 'EOF' > ~/.zshrc.d/edds-zsh-aliases.zsh
alias eg="cd ~/Programming/eddgrant"
alias mns="cd ~/Programming/101ways/mns"
alias mnsg="cd ~/Programming/101ways/mns/github"
EOF
ok "Wrote ~/.zshrc.d/autoload-edds-zsh-functions.zsh and ~/.zshrc.d/edds-zsh-aliases.zsh"

# ---------------------------------------------------------------------------
# Installer functions
#
# The framework bootstrap is complete. From here we only WRITE the install_*
# functions into ${ZSH_FUNCTIONS_DIR}; they are run later, on demand, from an
# interactive shell.
# ---------------------------------------------------------------------------
info "Creating installer functions in ${ZSH_FUNCTIONS_DIR}"

create_zsh_function "download_file" << 'EOF'
download_file () {
  # download_file <url> <target-path>
  # --create-dirs so callers can target paths like ~/.local/bin/foo without
  # having to mkdir the parent first.
  local file_url="$1"
  local local_target="$2"
  curl --fail -q -L --create-dirs -o "${local_target}" "${file_url}"
}

download_file "$@"
EOF

create_zsh_function "add_signed_apt_repository" << 'EOF'
add_signed_apt_repository () {
  # Imports a third-party apt repository's signing key and registers its source
  # list, then refreshes package lists. Collapses the dearmor-key + write-.list
  # + apt-update dance that nearly every install_* function below repeats.
  #
  #   add_signed_apt_repository <name> <key_url> <repo_line>
  #
  # <name>      short id used for the keyring and .list filenames (e.g. "brave").
  # <key_url>   URL of the GPG signing key. Armoured or binary both work -
  #             gpg --dearmor passes an already-binary key through unchanged.
  # <repo_line> the 'deb [signed-by=KEYRING ...] URL suite components' line, with
  #             the literal token KEYRING where the keyring path should be spliced.
  #
  # Idempotent: gpg --yes overwrites the keyring and tee overwrites the .list.
  local name="$1" key_url="$2" repo_line="$3"
  local keyring="/usr/share/keyrings/${name}-archive-keyring.gpg"
  curl -fsSL "${key_url}" | sudo gpg --dearmor --yes -o "${keyring}"
  echo "${repo_line//KEYRING/${keyring}}" | sudo tee "/etc/apt/sources.list.d/${name}.list" > /dev/null
  sudo apt update
}

add_signed_apt_repository "$@"
EOF

# clone_or_pull is also defined in the bootstrap body above (used to install the
# zshrc.d plugin). We additionally write it as an autoloaded function because
# several install_* functions below (aws_vault, tfenv, tgenv, rbenv, goenv) call
# it at runtime, long after the bootstrap process has exited - without this they
# would fail with "command not found: clone_or_pull".
create_zsh_function "clone_or_pull" << 'EOF'
clone_or_pull () {
  local repo_url="$1"
  local target_dir="$2"
  if [ -d "${target_dir}/.git" ]; then
    echo "Repository '${repo_url}' already exists in ${target_dir}, updating"
    (cd "${target_dir}" && git pull)
  else
    echo "Cloning '${repo_url}' to '${target_dir}'"
    git clone --depth=1 "${repo_url}" "${target_dir}"
  fi
}

clone_or_pull "$@"
EOF

create_zsh_function "install_github_cli" << 'EOF'
install_github_cli () {
  # Install GitHub CLI - https://github.com/cli/cli/blob/trunk/docs/install_linux.md
  # The gh package Depends on git, so apt pulls git in regardless; git is also
  # part of the machine bootstrap.
  type -p curl >/dev/null || sudo apt install curl -y
  add_signed_apt_repository "githubcli" \
    "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
    "deb [arch=$(dpkg --print-architecture) signed-by=KEYRING] https://cli.github.com/packages stable main"
  sudo apt install gh -y
}

install_github_cli "$@"
EOF

create_zsh_function "install_gnome_tweaks" << 'EOF'
install_gnome_tweaks () {
  sudo apt install -y gnome-tweaks
}

install_gnome_tweaks "$@"
EOF

create_zsh_function "install_gnome_extensions" << 'EOF'
install_gnome_extensions () {
  sudo apt install -y chrome-gnome-shell gnome-shell-extensions
}

install_gnome_extensions "$@"
EOF

create_zsh_function "install_zoom" << 'EOF'
install_zoom () {
  # Zoom doesn't publish a deb apt repo, but /client/latest/ always serves
  # the current build, so re-running this function upgrades in place.
  local zoom_file="zoom_amd64.deb"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  download_file "https://zoom.us/client/latest/zoom_amd64.deb" "${tmp_dir}/${zoom_file}"
  sudo apt install -y "${tmp_dir}/${zoom_file}"
  rm -rf "${tmp_dir}"
}

install_zoom "$@"
EOF

create_zsh_function "install_brave_browser" << 'EOF'
install_brave_browser () {
  add_signed_apt_repository "brave-browser" \
    "https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg" \
    "deb [arch=amd64 signed-by=KEYRING] https://brave-browser-apt-release.s3.brave.com/ stable main"
  sudo apt install -y brave-browser
}

install_brave_browser "$@"
EOF

create_zsh_function "install_asdf" << 'EOF'
install_asdf () {
  ASDF_DIR="$HOME/.asdf"
  ASDF_VERSION="v0.16.7"
  ASDF_VERSIONED_FILE="asdf-${ASDF_VERSION}-linux-amd64.tar.gz"
  ASDF_MD5_FILE="${ASDF_VERSIONED_FILE}.md5"
  ASDF_BINARY_PATH="${ASDF_DIR}/asdf"

  mkdir -p "${ASDF_DIR}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  download_file "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/${ASDF_VERSIONED_FILE}" "${tmp_dir}/${ASDF_VERSIONED_FILE}"
  tar -xvzf "${tmp_dir}/${ASDF_VERSIONED_FILE}" --directory "${ASDF_DIR}"
  chmod 0755 "${ASDF_DIR}/asdf"
  rm -rf "${tmp_dir}"
  echo 'export PATH="$HOME/.asdf:$PATH"' > ~/.zshrc.d/asdf.zsh
  # ~/.zshrc.d/asdf.zsh only takes effect in future shells; put asdf on PATH now
  # so the plugin adds below work on a fresh machine (this very run).
  export PATH="${ASDF_DIR}:$PATH"

  echo "Don't forget to add asdf to your oh-my-zsh plugins"

  # Install NodeJS ASDF plugin
  asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git

  # Install pnpm ASDF plugin
  asdf plugin add pnpm

  # Install Ruby ASDF plugin
  asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git

  # Install Pandoc ASDF plugin
  asdf plugin add pandoc
}

install_asdf "$@"
EOF

create_zsh_function "install_dropbox" << 'EOF'
install_dropbox () {
  sudo apt install -y libpango-1.0-0 python3-gpg
  local dropbox_file="dropbox_2020.03.04_amd64.deb"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  download_file "https://www.dropbox.com/download?dl=packages/ubuntu/${dropbox_file}" "${tmp_dir}/${dropbox_file}"
  sudo dpkg -i "${tmp_dir}/${dropbox_file}"
  rm -rf "${tmp_dir}"
}

install_dropbox "$@"
EOF

create_zsh_function "install_google_chrome" << 'EOF'
install_google_chrome () {
  # Install Google Chrome from Google Chrome PPA repository - https://www.ubuntuupdates.org/ppa/google_chrome
  add_signed_apt_repository "google-chrome" \
    "https://dl-ssl.google.com/linux/linux_signing_key.pub" \
    "deb [signed-by=KEYRING arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main"
  sudo apt install -y google-chrome-stable
}

install_google_chrome "$@"
EOF

create_zsh_function "install_flatpak" << 'EOF'
install_flatpak () {
  sudo apt install -y flatpak gnome-software-plugin-flatpak
  sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
}

install_flatpak "$@"
EOF

create_zsh_function "install_keepassxc" << 'EOF'
install_keepassxc () {
  # Install KeepassXC
  # Flatpak doesn't seem to install correctly at the moment, so use the official PPA.
  #sudo flatpak install -y org.keepassxc.KeePassXC
  sudo add-apt-repository ppa:phoerious/keepassxc
  sudo apt update
  sudo apt install -y keepassxc
}

install_keepassxc "$@"
EOF

create_zsh_function "install_1password" << 'EOF'
install_1password () {
  # Install the 1Password desktop app - https://support.1password.com/install-linux/
  # Idempotent: re-running refreshes the repo metadata and only installs when a
  # newer version is available (apt itself is a no-op if already up to date, but
  # we report the decision explicitly first).
  local keyring="/usr/share/keyrings/1password-archive-keyring.gpg"
  local key_url="https://downloads.1password.com/linux/keys/1password.asc"
  local debsig_id="AC2D62742012EA22"
  # The repo serves per-architecture paths, so the arch drives both the apt
  # [arch=...] option and the repository URL.
  local arch
  arch="$(dpkg --print-architecture)"

  # Import the signing key. --yes lets gpg overwrite the keyring on re-runs.
  curl -sS "${key_url}" | sudo gpg --dearmor --yes --output "${keyring}"

  # Add the apt repository (tee overwrites the list in place on re-runs).
  echo "deb [arch=${arch} signed-by=${keyring}] https://downloads.1password.com/linux/debian/${arch} stable main" \
    | sudo tee /etc/apt/sources.list.d/1password.list > /dev/null

  # Configure the debsig-verify policy so the package signature can be verified.
  sudo mkdir -p "/etc/debsig/policies/${debsig_id}/"
  curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
    | sudo tee "/etc/debsig/policies/${debsig_id}/1password.pol" > /dev/null
  sudo mkdir -p "/usr/share/debsig/keyrings/${debsig_id}"
  curl -sS "${key_url}" | sudo gpg --dearmor --yes --output "/usr/share/debsig/keyrings/${debsig_id}/debsig.gpg"

  # Refresh package lists so apt sees the current candidate version.
  sudo apt update

  # Compare the installed version against the candidate the repo now offers.
  local installed_version candidate_version
  installed_version="$(dpkg-query --showformat='${Version}' --show 1password 2>/dev/null || true)"
  candidate_version="$(apt-cache policy 1password | awk '/Candidate:/ {print $2}')"

  if [ -z "${installed_version}" ]; then
    echo "1Password is not installed. Installing version ${candidate_version}."
    sudo apt install -y 1password
  elif [ "${installed_version}" = "${candidate_version}" ]; then
    echo "1Password ${installed_version} is already the latest version - nothing to do."
  else
    echo "A newer version of 1Password is available: ${installed_version} -> ${candidate_version}. Upgrading."
    sudo apt install -y 1password
  fi
}

install_1password "$@"
EOF

create_zsh_function "install_aws_cli" << 'EOF'
install_aws_cli () {
  # Install AWS CLI - https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${tmp_dir}/awscliv2.zip"
  unzip -q -d "${tmp_dir}" "${tmp_dir}/awscliv2.zip"
  # The bundled installer refuses to overwrite an existing install unless given
  # --update, so re-running (or a runner with the AWS CLI preinstalled) needs it.
  if command -v aws >/dev/null 2>&1 || [ -d /usr/local/aws-cli ]; then
    sudo "${tmp_dir}/aws/install" --update
  else
    sudo "${tmp_dir}/aws/install"
  fi
  rm -rf "${tmp_dir}"
}

install_aws_cli "$@"
EOF

create_zsh_function "install_aws_sam_cli" << 'EOF'
install_aws_sam_cli () {
  local sam_file="aws-sam-cli-linux-x86_64.zip"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  download_file "https://github.com/aws/aws-sam-cli/releases/latest/download/${sam_file}" "${tmp_dir}/${sam_file}"
  unzip -q -d "${tmp_dir}/sam-installation" "${tmp_dir}/${sam_file}"
  # As with the AWS CLI, the installer needs --update when one already exists.
  if command -v sam >/dev/null 2>&1 || [ -d /usr/local/aws-sam-cli ]; then
    sudo "${tmp_dir}/sam-installation/install" --update
  else
    sudo "${tmp_dir}/sam-installation/install"
  fi
  rm -rf "${tmp_dir}"
}

install_aws_sam_cli "$@"
EOF

create_zsh_function "install_aws_lambda_rie" << 'EOF'
install_aws_lambda_rie () {
  rie_binary_path="${HOME}/.local/bin/aws-lambda-rie"
  download_file "https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/latest/download/aws-lambda-rie" "${rie_binary_path}"
  chmod +x "${rie_binary_path}"
}

install_aws_lambda_rie "$@"
EOF

create_zsh_function "install_aws_vault" << 'EOF'
install_aws_vault () {
  sudo curl -L -o /usr/local/bin/aws-vault https://github.com/99designs/aws-vault/releases/latest/download/aws-vault-linux-amd64
  sudo chmod 755 /usr/local/bin/aws-vault

  # Install aws-vault Zsh plugin
  clone_or_pull https://github.com/blimmer/zsh-aws-vault.git "${ZSH_CUSTOM}/plugins/zsh-aws-vault"
  echo "Don't forget to add zsh-aws-vault to your oh-my-zsh plugins"
}

install_aws_vault "$@"
EOF

create_zsh_function "install_docker" << 'EOF'
install_docker () {
  # Install Docker - https://docs.docker.com/engine/install/ubuntu/
  sudo apt-get remove -y docker docker.io containerd runc

  sudo apt-get install -y \
      ca-certificates \
      curl \
      gnupg \
      lsb-release

  sudo mkdir -p /etc/apt/keyrings
  # --yes so re-runs overwrite the keyring instead of prompting. chmod a+r so
  # apt (running unprivileged) can read it - per Docker's own install docs.
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # The post-install group setup. groupadd is guarded so a re-run doesn't error
  # on the already-existing group; usermod -aG is itself idempotent.
  getent group docker >/dev/null || sudo groupadd docker
  sudo usermod -aG docker "$USER"

  # NB: we deliberately do NOT 'newgrp docker' here - it would replace the
  # current shell and silently abort the rest of this function. Pick up the new
  # group membership by logging out and back in (or run 'newgrp docker'
  # yourself in a throwaway shell to use docker without sudo before then).
  echo "Docker installed. Log out and back in to use docker without sudo."
}

install_docker "$@"
EOF

create_zsh_function "install_slack" << 'EOF'
install_slack () {
  # Slack doesn't publish an apt repository (the old packagecloud one was retired),
  # so grab the latest .deb directly from their downloads page. The instructions
  # page embeds an absolute URL to the current build on downloads.slack-edge.com.
  local instructions_url="https://slack.com/downloads/instructions/linux?ddl=1&build=deb"
  local deb_url
  deb_url=$(curl -fsSL "${instructions_url}" \
            | grep -oE 'https://downloads\.slack-edge\.com/desktop-releases/linux/x64/[0-9.]+/slack-desktop-[0-9.]+-amd64\.deb' \
            | head -1)
  if [ -z "${deb_url}" ]; then
    echo "install_slack: could not determine latest Slack .deb URL from ${instructions_url}" >&2
    return 1
  fi
  local slack_deb
  slack_deb="$(basename "${deb_url}")"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  download_file "${deb_url}" "${tmp_dir}/${slack_deb}"
  sudo apt install -y "${tmp_dir}/${slack_deb}"
  rm -rf "${tmp_dir}"
  # If the snap is also installed, remove it manually with: sudo snap remove slack
}

install_slack "$@"
EOF

create_zsh_function "install_openvpn_client" << 'EOF'
install_openvpn_client () {
  sudo apt install -y openvpn unzip network-manager-openvpn-gnome
}

install_openvpn_client "$@"
EOF

create_zsh_function "install_vscode" << 'EOF'
install_vscode () {
  # Install VSCode - https://code.visualstudio.com/docs/setup/linux
  sudo apt-get install -y wget gpg
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "${tmp_dir}/packages.microsoft.gpg"
  sudo install -D -o root -g root -m 644 "${tmp_dir}/packages.microsoft.gpg" /etc/apt/keyrings/packages.microsoft.gpg
  sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
  rm -rf "${tmp_dir}"

  sudo apt install -y apt-transport-https
  sudo apt update
  sudo apt install -y code
}

install_vscode "$@"
EOF

create_zsh_function "install_beyond_compare" << 'EOF'
install_beyond_compare () {
  # Beyond Compare has no apt repo. Their download page always advertises the
  # current build, so scrape the version from it, compare against what's already
  # installed, and only fetch + install when it differs - mirroring how
  # install_1password stays idempotent.
  local download_page="https://www.scootersoftware.com/download"
  local deb_file
  deb_file="$(curl -fsSL "${download_page}" \
              | grep -oE 'bcompare-[0-9.]+_amd64\.deb' \
              | sort -V | tail -1)"
  if [ -z "${deb_file}" ]; then
    echo "install_beyond_compare: could not determine the latest version from ${download_page}" >&2
    return 1
  fi

  local latest_version="${deb_file#bcompare-}"
  latest_version="${latest_version%_amd64.deb}"

  local installed_version
  installed_version="$(dpkg-query --showformat='${Version}' --show bcompare 2>/dev/null || true)"
  if [ "${installed_version}" = "${latest_version}" ]; then
    echo "Beyond Compare ${installed_version} is already the latest version - nothing to do."
    return 0
  fi

  echo "Installing Beyond Compare ${latest_version}${installed_version:+ (replacing ${installed_version})}."
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # The page links the file under /files/, but the actual download is served
  # from the host root.
  download_file "https://www.scootersoftware.com/${deb_file}" "${tmp_dir}/${deb_file}"
  sudo apt update
  sudo apt install -y "${tmp_dir}/${deb_file}"
  rm -rf "${tmp_dir}"
}

install_beyond_compare "$@"
EOF

create_zsh_function "install_tfenv" << 'EOF'
install_tfenv () {
  clone_or_pull https://github.com/tfutils/tfenv.git ~/.tfenv
  echo 'export PATH="$HOME/.tfenv/bin:$PATH"' > ~/.zshrc.d/tfenv.zsh
}

install_tfenv "$@"
EOF

create_zsh_function "install_tgenv" << 'EOF'
install_tgenv () {
  clone_or_pull https://github.com/cunymatthieu/tgenv.git ~/.tgenv
  echo 'export PATH="$HOME/.tgenv/bin:$PATH"' > ~/.zshrc.d/tgenv.zsh
}

install_tgenv "$@"
EOF

create_zsh_function "install_pyenv" << 'EOF'
install_pyenv () {
  # Install PyEnv
  curl https://pyenv.run | bash

  cat << 'EHEREDOC' > ~/.zshrc.d/pyenv.zsh
export PYENV_ROOT="$HOME/.pyenv"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EHEREDOC

  # Install packages required by PyEnv to build Python distributions
  # https://github.com/pyenv/pyenv/wiki/Common-build-problems
  sudo apt install -y zlib1g zlib1g-dev libssl-dev libbz2-dev libsqlite3-dev libffi-dev
  # libncursesw5 was dropped in Ubuntu 24.04; libncurses-dev provides the wide
  # headers pyenv needs to build CPython.
  sudo apt install -y libncurses-dev libreadline-dev tk-dev liblzma-dev
}

install_pyenv "$@"
EOF

create_zsh_function "install_pip" << 'EOF'
install_pip () {
  # Install pip in system python
  sudo apt install -y python3-pip
}

install_pip "$@"
EOF

create_zsh_function "install_poetry" << 'EOF'
install_poetry () {
  curl -sSL https://install.python-poetry.org | python3 -
  # Not strictly required for poetry but it's here for now.
  echo 'export PATH="$HOME/.local/bin:$PATH"' > ~/.zshrc.d/poetry.zsh
}

install_poetry "$@"
EOF

create_zsh_function "install_cruft" << 'EOF'
install_cruft () {
  pip3 install cruft
}

install_cruft "$@"
EOF

create_zsh_function "install_rbenv" << 'EOF'
install_rbenv () {
  clone_or_pull https://github.com/rbenv/rbenv.git ~/.rbenv
  echo 'eval "$(~/.rbenv/bin/rbenv init - zsh)"' >> ~/.zshrc.d/rbenv.zsh

  # Install ruby-build as RBEnv install command
  eval "$(~/.rbenv/bin/rbenv init - zsh)" # Init rbenv so the "root" command below works.
  clone_or_pull https://github.com/rbenv/ruby-build.git "$(rbenv root)"/plugins/ruby-build
}

install_rbenv "$@"
EOF

create_zsh_function "install_goenv" << 'EOF'
install_goenv () {
  clone_or_pull https://github.com/syndbg/goenv.git ~/.goenv
  cat << 'EHEREDOC' > ~/.zshrc.d/goenv.zsh
export GOENV_ROOT="$HOME/.goenv"
export PATH="$GOENV_ROOT/bin:$PATH"
eval "$(goenv init -)"
EHEREDOC
}

install_goenv "$@"
EOF

create_zsh_function "install_yq" << 'EOF'
install_yq () {
  sudo snap install yq
}

install_yq "$@"
EOF

create_zsh_function "install_nvm" << 'EOF'
install_nvm () {
  local version="v0.39.3"
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${version}/install.sh" | bash
}

install_nvm "$@"
EOF

create_zsh_function "install_rust" << 'EOF'
install_rust () {
  # Install the Rust toolchain via rustup. --no-modify-path because PATH is
  # managed through ~/.zshrc.d below, consistent with the other tools in this
  # script. Re-running rustup-init updates an existing install in place.
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain stable --profile default

  # Put cargo/rustc on PATH for future shells.
  echo '. "$HOME/.cargo/env"' > ~/.zshrc.d/rust.zsh

  # Make rustup/cargo available for the rest of this function.
  . "$HOME/.cargo/env"

  # --- Embedded extras for the BBC micro:bit v2 (Nordic nRF52833, Cortex-M4F) ---
  # Cross-compile target for the board's CPU.
  rustup target add thumbv7em-none-eabihf

  # probe-rs flashes the board and streams RTT output over its onboard USB
  # debugger. Official prebuilt installer (avoids a lengthy cargo compile).
  curl --proto '=https' --tlsv1.2 -LsSf \
    https://github.com/probe-rs/probe-rs/releases/latest/download/probe-rs-tools-installer.sh \
    | sh

  # udev rules so probe-rs can reach the debug probe without sudo. Applies on
  # the next replug, or after the reload/trigger below.
  sudo curl -fsSL https://probe.rs/files/69-probe-rs.rules \
    -o /etc/udev/rules.d/69-probe-rs.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger
}

install_rust "$@"
EOF

create_zsh_function "install_sdkman" << 'EOF'
install_sdkman () {
  curl -s "https://get.sdkman.io" | bash
}

install_sdkman "$@"
EOF

create_zsh_function "install_jetbrains_toolbox" << 'EOF'
install_jetbrains_toolbox () {
  # Install Jetbrains toobox - https://www.jetbrains.com/help/idea/installation-guide.html#fe5cb000
  sudo apt install -y libfuse-dev
  local version="2.0.5.17700"
  local toolbox_file="jetbrains-toolbox-${version}.tar.gz"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  download_file "https://download.jetbrains.com/toolbox/${toolbox_file}" "${tmp_dir}/${toolbox_file}"
  tar -xvzf "${tmp_dir}/${toolbox_file}" --directory "${tmp_dir}"
  "${tmp_dir}/${toolbox_file%.tar.gz}/jetbrains-toolbox"
  cat << EHEREDOC > ~/.zshrc.d/jetbrains-toolbox.zsh
export PATH="\$HOME/.local/share/JetBrains/Toolbox/scripts:\${PATH}"
EHEREDOC
}

install_jetbrains_toolbox "$@"
EOF

create_zsh_function "install_postman" << 'EOF'
install_postman () {
  sudo snap install postman
}

install_postman "$@"
EOF

create_zsh_function "install_backintime" << 'EOF'
install_backintime () {
  sudo apt install -y backintime-qt sshfs
}

install_backintime "$@"
EOF

create_zsh_function "install_obs_studio" << 'EOF'
install_obs_studio () {
  sudo add-apt-repository ppa:obsproject/obs-studio
  sudo apt update
  sudo apt install -y ffmpeg obs-studio
}

install_obs_studio "$@"
EOF

create_zsh_function "install_mixxx" << 'EOF'
install_mixxx () {
  sudo add-apt-repository ppa:mixxx/mixxx
  sudo apt update
  sudo apt install -y mixxx
}

install_mixxx "$@"
EOF

create_zsh_function "install_byobu" << 'EOF'
install_byobu () {
  sudo apt install -y byobu
}

install_byobu "$@"
EOF

create_zsh_function "install_akamai_cli" << 'EOF'
install_akamai_cli () {
  AKAMAI_CLI_VERSION="v1.6.0"
  download_file "https://github.com/akamai/cli/releases/download/${AKAMAI_CLI_VERSION}/akamai-${AKAMAI_CLI_VERSION}-linuxamd64" "${HOME}/.local/bin/akamai"
  chmod +x "${HOME}/.local/bin/akamai"
}

install_akamai_cli "$@"
EOF

create_zsh_function "install_openshot" << 'EOF'
install_openshot () {
  sudo add-apt-repository ppa:openshot.developers/ppa
  sudo apt update
  sudo apt install -y openshot-qt python3-openshot
}

install_openshot "$@"
EOF

create_zsh_function "install_direnv" << 'EOF'
install_direnv () {
  sudo apt install -y direnv
  echo "Don't forget to add the 'direnv' plugin to the list of plugins in ~/.zshrc"
}

install_direnv "$@"
EOF

create_zsh_function "install_wispr_flow" << 'EOF'
install_wispr_flow () {
  # Install Wispr Flow (unofficial Linux port) from its apt repository.
  # https://github.com/wispr-flow-linux/wispr-flow-linux

  add_signed_apt_repository "wispr-flow" \
    "https://pkg.wispr-flow-linux.dev/KEY.gpg" \
    "deb [signed-by=KEYRING arch=amd64,arm64] https://pkg.wispr-flow-linux.dev stable main"
  sudo apt install -y wispr-flow

  # Text injection writes to a /dev/uinput virtual keyboard, which is root-only
  # on stock images. The package ships a udev rule that ACLs it to the active
  # session, but joining the 'input' group is the cross-distro fallback. usermod
  # -aG is idempotent.
  sudo usermod -aG input "$USER"

  echo "wispr-flow installed. A few one-time setup steps remain:"
  echo "  - Run 'wispr-flow --doctor' to verify uinput, clipboard, AT-SPI and the GNOME bridge."
  echo "  - Log out and back in so the 'input' group membership and (on GNOME) the"
  echo "    'wispr-flow-window-bridge@wispr.flow' shell extension take effect."
}

install_wispr_flow "$@"
EOF

ok "Created ${#CREATED_ZSH_FUNCTIONS[@]} shell functions in ${ZSH_FUNCTIONS_DIR}"

# ---------------------------------------------------------------------------
# Summary: tell the user what was created and how to use it.
# ---------------------------------------------------------------------------
echo
echo "======================================================================"
echo "Machine bootstrap complete. Full log: ${LOG_FILE}"
echo
echo "The shell-function framework is set up and the following functions have"
echo "been created in ${ZSH_FUNCTIONS_DIR}:"
echo
printf '  %s\n' "${CREATED_ZSH_FUNCTIONS[@]}" | sort
echo
echo "Open a NEW zsh shell (or run 'exec zsh') so they autoload, then run any"
echo "you want, e.g.:"
echo "  install_github_cli"
echo "  install_wispr_flow"
echo
echo "(download_file, add_signed_apt_repository and clone_or_pull are helpers the"
echo "install_* functions use; the rest install software on demand.) Autoloading"
echo "requires the 'zshrc.d' plugin in your ~/.zshrc plugins list."
echo "======================================================================"