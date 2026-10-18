#!/usr/bin/env bash
# check-service-tag.sh: does the service tag WindowsVirtualDesktop contain the TURN range?
#
# Optional helper, related to "AVD connection paths, part 3: the firewall rules you need, the ones you don't, and three traps"
#   https://cloudchristoph.com/articles/avd-connection-paths-3-firewall-rules-and-three-traps/
#
# Lists the prefixes of the service tag in a region and checks for 51.5.0.0/16 (STUN and TURN
# relays) and leftovers of the old range 20.202.0.0/16. The tag changes without notice: run it
# for your own region before you rely on the tag for UDP 3478, and again when connections
# suddenly fall back to TCP.
#
#   ./check-service-tag.sh                       # germanywestcentral
#   ./check-service-tag.sh westeurope

set -euo pipefail
LOCATION="${1:-germanywestcentral}"

prefixes=$(az network list-service-tags --location "$LOCATION" \
  --query "values[?name=='WindowsVirtualDesktop'].properties.addressPrefixes" -o tsv)

echo "WindowsVirtualDesktop in $LOCATION:"
echo "$prefixes" | tr '\t' '\n' | sed 's/^/  /'
echo

if echo "$prefixes" | tr '\t' '\n' | grep -qx '51.5.0.0/16'; then
  echo "OK: 51.5.0.0/16 (STUN/TURN) is part of the tag."
else
  echo "CHECK: 51.5.0.0/16 is NOT listed as its own prefix. Allow UDP 3478 to 51.5.0.0/16 explicitly."
fi

if echo "$prefixes" | tr '\t' '\n' | grep -q '^20\.202\.'; then
  echo "NOTE: the tag still contains prefixes from the old relay range 20.202.0.0/16."
fi
