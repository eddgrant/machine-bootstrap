#!/usr/bin/env bash
set -euo pipefail

# Proves what install_gsconnect is supposed to leave behind, rather than only that
# it ran to completion: the package is installed, UFW holds the KDE Connect rules,
# re-running does not duplicate them, GSCONNECT_FIREWALL_SOURCES is honoured, and
# the installer never switches UFW on.
#
# What is and is not covered: a CI runner has no phone, so this cannot show that
# packets actually get through the firewall. It checks the rules UFW holds, which
# 'ufw show added' lists whether or not UFW is enabled.
#
# Changes the machine's firewall rules and installs packages, so it refuses to run
# unless CI_GSCONNECT_TEST_ALLOW=1. Only run it on a disposable CI runner.
#
# Prerequisite: bootstrap-my-machine.sh has already run (as ci/run-installer.sh
# needs), and the user can sudo without a password.
#
# Usage: CI_GSCONNECT_TEST_ALLOW=1 ci/test-gsconnect.sh

if [ "${CI_GSCONNECT_TEST_ALLOW:-}" != 1 ]; then
  echo "test-gsconnect: refusing to run - this installs packages and edits firewall rules. Set CI_GSCONNECT_TEST_ALLOW=1 on a disposable machine." >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_source="192.168.0.0/16"
other_source="10.1.2.0/24"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# kde_connect_rules: the stored rules for KDE Connect's port range, one per line.
kde_connect_rules() {
  { sudo ufw show added | grep -F "port 1714:1764" || true; }
}

# assert_rule <proto> <source>
assert_rule() {
  kde_connect_rules | grep -qF "from $2 to any port 1714:1764 proto $1" \
    || fail "no $1 rule from $2 for ports 1714:1764. Rules were: $(kde_connect_rules)"
}

ufw_state() { sudo ufw status | head -1; }

state_before="$(ufw_state)"
echo "==> UFW state before: ${state_before}"

echo "==> Running install_gsconnect with default sources"
bash "${here}/run-installer.sh" install_gsconnect

dpkg -s gnome-shell-extension-gsconnect > /dev/null 2>&1 \
  || fail "gnome-shell-extension-gsconnect is not installed"
pass "package installed"

assert_rule tcp "${default_source}"
assert_rule udp "${default_source}"
[ "$(kde_connect_rules | wc -l)" -eq 2 ] \
  || fail "expected exactly 2 rules after the first run: $(kde_connect_rules)"
pass "tcp and udp allowed from ${default_source}, and nothing else"

echo "==> Re-running install_gsconnect"
bash "${here}/run-installer.sh" install_gsconnect
[ "$(kde_connect_rules | wc -l)" -eq 2 ] \
  || fail "re-running changed the rules: $(kde_connect_rules)"
pass "re-running adds no duplicate rules"

echo "==> Running install_gsconnect with GSCONNECT_FIREWALL_SOURCES=${other_source}"
GSCONNECT_FIREWALL_SOURCES="${other_source}" bash "${here}/run-installer.sh" install_gsconnect
assert_rule tcp "${other_source}"
assert_rule udp "${other_source}"
assert_rule tcp "${default_source}"
assert_rule udp "${default_source}"
[ "$(kde_connect_rules | wc -l)" -eq 4 ] \
  || fail "expected 4 rules after the override run: $(kde_connect_rules)"
pass "GSCONNECT_FIREWALL_SOURCES adds the requested source alongside the existing rules"

[ "$(ufw_state)" = "${state_before}" ] \
  || fail "UFW state changed from '${state_before}' to '$(ufw_state)'"
pass "UFW enabled/disabled state left as it was"

echo "All install_gsconnect checks passed."
