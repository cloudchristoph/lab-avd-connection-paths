#!/usr/bin/env bash
# avd-transport.sh: which transport did the AVD sessions really use?
#
# Runs kql/session-classification.kql (part 6 of the series) against a Log Analytics workspace
# and prints one coloured line per session. Meant for a terminal next to the demo.
#
#   WORKSPACE_ID=<workspace guid> ./avd-transport.sh            # once
#   WORKSPACE_ID=<workspace guid> WATCH=30 ./avd-transport.sh   # refresh every 30 s
#
# WORKSPACE_ID is the workspace's customer ID (GUID), not its resource ID:
#   az monitor log-analytics workspace show -g <rg> -n <name> --query customerId -o tsv
# The Terraform in this repo prints it as output log_analytics_workspace_customer_id.
#
# Needs: az CLI, signed in (the log-analytics extension is installed on first use).
# WVDConnections lags up to about 15 minutes, so a session you just started shows up late.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUERY_FILE="$HERE/../kql/session-classification.kql"
: "${WORKSPACE_ID:?Set WORKSPACE_ID to the Log Analytics workspace customer ID (GUID)}"

BOLD=$'\033[1m'; RESET=$'\033[0m'
GREEN=$'\033[1;32m'; CYAN=$'\033[1;36m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'

colour_of() {
  case "$1" in
    "UDP direct"*|"UDP private"*) printf '%s' "$GREEN" ;;
    "UDP via TURN"*) printf '%s' "$CYAN" ;;
    "Unclear"*|"Still running"*) printf '%s' "$YELLOW" ;;
    *)              printf '%s' "$RED" ;;
  esac
}

show() {
  local rows
  # Strip full-line comments (the query has none inside). Empty values become "-": read with a tab
  # as separator would otherwise swallow an empty column and shift the rest.
  rows=$(az monitor log-analytics query -w "$WORKSPACE_ID" \
    --analytics-query "$(grep -v '^//' "$QUERY_FILE")" \
    --query "[].[Started, ClientType || '-', SessionHostName || '-', Path, UdpType || '-']" -o tsv)
  printf '\n%s%-8s %-20s %-16s %-44s %s%s\n' "$BOLD" "start" "client" "host" "path" "udp type" "$RESET"
  [ -z "$rows" ] && { echo "(no sessions yet, WVDConnections lags up to about 15 minutes)"; return; }
  while IFS=$'\t' read -r t client host path udp; do
    printf '%-8s %-20.20s %-16.16s %s%-44s%s %s\n' \
      "${t:11:5}" "$client" "${host%%.*}" "$(colour_of "$path")" "$path" "$RESET" "$udp"
  done <<< "$rows"
}

if [ -n "${WATCH:-}" ]; then
  while true; do clear; show; sleep "$WATCH"; done
else
  show
fi
