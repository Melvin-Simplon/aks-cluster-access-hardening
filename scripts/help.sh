#!/usr/bin/env bash
# Print the Makefile targets, grouped and coloured by the ##@ section markers.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# One colour per section. Unlisted sections fall back to DEFAULT_COLOR.
SECTION_COLORS="Setup=38;5;220,Hardening=38;5;170,Verification=38;5;39,Help=38;5;80"
DEFAULT_COLOR="38;5;80"
BANNER_COLOR="38;5;141"

# Sections follow the include order of the Makefile, not the alphabet.
# Includes that do not resolve to a readable file are skipped, so a conditional
# `include scripts/config.env` never breaks the help.
makefiles() {
  printf '%s\n' "${PROJECT_ROOT}/Makefile"
  awk '/^include /{print $2}' "${PROJECT_ROOT}/Makefile" |
    while read -r rel; do
      [[ -f "${PROJECT_ROOT}/${rel}" ]] && printf '%s\n' "${PROJECT_ROOT}/${rel}"
    done
}

print_targets() {
  awk -v colors="$SECTION_COLORS" -v fallback="$DEFAULT_COLOR" '
    BEGIN {
      split(colors, pairs, ",")
      for (i in pairs) {
        split(pairs[i], kv, "=")
        color[kv[1]] = kv[2]
      }
      current = fallback
    }
    /^##@ / {
      section = substr($0, 5)
      current = (section in color) ? color[section] : fallback
      printf "\n\033[1;%sm%s\033[0m\n", current, section
      next
    }
    /^[a-z][a-z0-9-]*:.*## / {
      split($0, parts, ":.*## ")
      printf "  \033[%sm%-16s\033[0m %s\n", current, parts[1], parts[2]
    }
  ' "$@"
}

# Quoted heredoc, so the backslashes of the figlet art survive untouched.
banner() {
  printf '\033[1;%sm\n' "${BANNER_COLOR}"
  cat <<'BANNER'
  ___ ___                  .___            .__                    _____   ____  __.  _________
 /   |   \_____ _______  __| _/____   ____ |__| ____    ____     /  _  \ |    |/ _| /   _____/
/    ~    \__  \\_  __ \/ __ |/ __ \ /    \|  |/    \  / ___\   /  /_\  \|      <   \_____  \ 
\    Y    // __ \|  | \/ /_/ \  ___/|   |  \  |   |  \/ /_/  > /    |    \    |  \  /        \
 \___|_  /(____  /__|  \____ |\___  >___|  /__|___|  /\___  /  \____|__  /____|__ \/_______  /
       \/      \/           \/    \/     \/        \//_____/           \/        \/        \/
BANNER
  printf '\033[0m\n'
}

main() {
  banner
  echo "AKS cluster access hardening"
  echo
  echo "Usage: make <target> [DRY_RUN=1] [ASSUME_YES=1]"
  echo "DRY_RUN prints the commands without applying them, ASSUME_YES skips the prompts."
  mapfile -t files < <(makefiles)
  print_targets "${files[@]}"
  echo
}

main "$@"
