#!/usr/bin/env bash
set -euo pipefail

# Lists the install_* functions defined in bootstrap-my-machine.sh so the CI
# matrix stays in sync with the script automatically - add an installer and CI
# picks it up on the next run, no workflow edit required.
#
# Usage:
#   list-installers.sh names    # one function name per line (default)
#   list-installers.sh matrix   # compact JSON: [{"name":...,"optional":bool}, ...]
#
# Classification:
#   EXCLUDE  - never run in CI (e.g. launches a GUI and would hang headless).
#   OPTIONAL - run, but allowed to fail: fragile external sources, snaps, or
#              cases known not to work on a headless runner. Reported, but they
#              do not turn the build red.
#   (everything else is "required" - a failure fails the build, which is the
#    point of the weekly canary: it tells us when an upstream URL/repo has rotted.)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../bootstrap-my-machine.sh"

EXCLUDE=(
  install_jetbrains_toolbox # launches the Toolbox GUI; hangs on a headless runner
)

OPTIONAL=(
  install_authy          # snap; the Authy desktop app has been discontinued
  install_postman        # snap; large download, occasionally flaky
  install_yq             # snap
  install_slack          # scrapes Slack's download page for the current .deb URL
  install_dropbox        # pinned 2020 .deb; the URL may 404
  install_beyond_compare # pinned old .deb; the URL may 404
  install_wispr_flow     # unofficial third-party apt repository
  install_cruft          # pip3 into a PEP-668 externally-managed system Python
)

mode="${1:-names}"

mapfile -t all < <(
  grep -oE 'create_zsh_function "install_[a-z0-9_]+"' "$script" \
    | sed -E 's/.*"(install_[a-z0-9_]+)".*/\1/' \
    | sort -u
)

contains() { # contains <needle> <haystack...>
  local needle="$1"; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

included=()
for fn in "${all[@]}"; do
  contains "$fn" "${EXCLUDE[@]}" && continue
  included+=("$fn")
done

case "$mode" in
  names)
    printf '%s\n' "${included[@]}"
    ;;
  matrix)
    json=""
    for fn in "${included[@]}"; do
      if contains "$fn" "${OPTIONAL[@]}"; then optional=true; else optional=false; fi
      json+="{\"name\":\"${fn}\",\"optional\":${optional}},"
    done
    printf '[%s]\n' "${json%,}"
    ;;
  *)
    echo "usage: $0 [names|matrix]" >&2
    exit 2
    ;;
esac
