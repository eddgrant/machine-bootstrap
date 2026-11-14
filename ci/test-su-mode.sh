#!/usr/bin/env bash
set -euo pipefail

# Proves run_privileged's "su" mode: that the bootstrap and an installer work from
# an account with NO sudo rights, by su'ing to a separate admin account.
#
# It creates throwaway users and edits /etc/pam.d/su, so it refuses to run unless
# CI_SU_TEST_ALLOW=1 and it is root. Only run it on a disposable CI runner or in a
# container - never on a real machine.
#
# What is and is not covered: su normally asks for the admin's password. Here a
# PAM rule lets exactly that user pair through without one, so there is nothing to
# type in CI. That exercises the whole su -> sudo -> command path (argument
# passing, stdin, exit codes, the bootstrap, an installer) but not the password
# prompt itself.
#
# Usage: CI_SU_TEST_ALLOW=1 ci/test-su-mode.sh        (as root)

if [ "${CI_SU_TEST_ALLOW:-}" != 1 ]; then
  echo "test-su-mode: refusing to run - this creates users and edits PAM. Set CI_SU_TEST_ALLOW=1 on a disposable machine." >&2
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "test-su-mode: must run as root" >&2
  exit 2
fi

# This test is about auto-detected su mode, so make sure no override leaks in.
unset BOOTSTRAP_PRIVILEGE

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
admin="ci-su-admin"
user="ci-su-user"
user_home="/home/${user}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# The bootstrap keeps its noisy output in a log file and prints only its path,
# which on a CI runner nobody can open afterwards. Print the logs on failure so
# the actual error is in the job output.
print_logs_on_failure() {
  local status=$?
  if [ "${status}" -ne 0 ]; then
    local log
    for log in /tmp/bootstrap-my-machine/*.log; do
      [ -e "${log}" ] || continue
      echo "::group::${log}"
      cat "${log}"
      echo "::endgroup::"
    done
  fi
}
trap print_logs_on_failure EXIT

export DEBIAN_FRONTEND=noninteractive
command -v sudo > /dev/null || { apt-get update -qq; apt-get install -y -qq sudo; }

echo "==> Creating users: ${admin} (sudo) and ${user} (no sudo)"
useradd -m -s /bin/bash "${admin}"
useradd -m -s /bin/bash "${user}"
chmod 700 "${user_home}"
{
  echo "${admin} ALL=(ALL) NOPASSWD:ALL"
  echo 'Defaults env_keep += "DEBIAN_FRONTEND"'
} > /etc/sudoers.d/ci-su-test
chmod 440 /etc/sudoers.d/ci-su-test

# Let su from ${user} to ${admin} through without a password, and nobody else.
sed -i "1i auth sufficient pam_succeed_if.so user = ${admin} ruser = ${user} quiet" /etc/pam.d/su

# Work on a copy the user owns, so this works wherever the checkout lives.
cp -r "${repo}" "${user_home}/machine-bootstrap"
chown -R "${user}:${user}" "${user_home}/machine-bootstrap"

# run_as_user <command...>: run as the unprivileged user with a clean-ish env.
# BOOTSTRAP_ADMIN_USER is supplied so nothing needs a terminal to prompt.
# It starts in the user's home: runuser keeps the caller's working directory, which
# on a CI runner is the runner's checkout, unreadable to ${user}. oh-my-zsh's
# installer cd's back to where it started and aborts when that is not accessible.
run_as_user() {
  (
    cd "${user_home}"
    runuser -u "${user}" -- env \
      HOME="${user_home}" USER="${user}" LOGNAME="${user}" \
      BOOTSTRAP_ADMIN_USER="${admin}" DEBIAN_FRONTEND=noninteractive \
      "$@"
  )
}

echo "==> Precondition: ${user} really has no sudo"
case " $(id -nG "${user}") " in
  *" sudo "*|*" admin "*|*" wheel "*) fail "${user} is in a sudo-granting group" ;;
esac
if runuser -u "${user}" -- sudo -n true 2> /dev/null; then
  fail "${user} unexpectedly has sudo"
fi
pass "${user} has no sudo access"

echo "==> Running the bootstrap as ${user} (su mode, auto-detected)"
run_as_user bash "${user_home}/machine-bootstrap/bootstrap-my-machine.sh"
[ -f "${user_home}/.zsh-functions/run_privileged" ] || fail "run_privileged was not written as a zsh function"
pass "bootstrap completed without sudo"

# call_fn <shell snippet>: run it in zsh with the autoloaded functions, as ${user}.
call_fn() {
  run_as_user zsh -e -c "
    fpath=(${user_home}/.zsh-functions \$fpath)
    autoload -Uz ${user_home}/.zsh-functions/*(:t)
    $1
  "
}

echo "==> run_privileged behaviour via the autoloaded zsh function"
[ "$(call_fn 'run_privileged id -u')" = "0" ] || fail "command did not run as root"
pass "runs the command as root"

# If "hello world" were split into two words, test would see 5 arguments and error.
call_fn 'run_privileged test "hello world" = "hello world"' || fail "arguments with spaces were not preserved"
pass "preserves arguments containing spaces"

[ "$(call_fn 'run_privileged ls -d /')" = "/" ] || fail "a command's own flags were mangled"
pass "passes a command's own -flags through"

rm -f /tmp/ci-su-pipe
call_fn 'echo piped | run_privileged tee /tmp/ci-su-pipe > /dev/null'
[ "$(cat /tmp/ci-su-pipe)" = "piped" ] || fail "stdin was not passed through"
pass "passes stdin through (pipelines work)"

set +e
call_fn 'run_privileged sh -c "exit 3"' > /dev/null 2>&1
rc=$?
set -e
[ "${rc}" -ne 0 ] || fail "a failing command reported success"
pass "propagates failure"

set +e
out="$(run_as_user env BOOTSTRAP_ADMIN_USER=no-such-user-xyz zsh -c "
  fpath=(${user_home}/.zsh-functions \$fpath)
  autoload -Uz ${user_home}/.zsh-functions/*(:t)
  run_privileged true" 2>&1)"
rc=$?
set -e
[ "${rc}" -ne 0 ] && grep -q "no such user" <<< "${out}" || fail "unknown admin user was not rejected cleanly: ${out}"
pass "rejects an unknown admin user"

echo "==> install_unattended_upgrades as ${user}"
run_as_user bash "${user_home}/machine-bootstrap/ci/run-installer.sh" install_unattended_upgrades
dropin="/etc/apt/apt.conf.d/52unattended-upgrades-local"
[ -f "${dropin}" ] || fail "${dropin} was not created"
[ "$(stat -c %U "${dropin}")" = "root" ] || fail "${dropin} is not owned by root"
# Capture first: 'apt-config dump | grep -q' fails under pipefail, because grep -q
# exits at the first match and apt-config then dies of SIGPIPE.
apt_settings="$(apt-config dump)"
grep -qF 'APT::Periodic::Update-Package-Lists "1";' <<< "${apt_settings}" || fail "apt does not see the daily list refresh"
grep -qF -- '-updates";' <<< "${apt_settings}" || fail "apt does not see the -updates origin"
pass "drop-in written by root and visible to apt"

echo "All su-mode checks passed."
