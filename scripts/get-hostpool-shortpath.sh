#!/usr/bin/env bash
# get-hostpool-shortpath.sh: read the four RDP Shortpath properties of a host pool.
#
# From "AVD connection paths, part 2: what the AVD settings really do to the path"
#   https://cloudchristoph.com/articles/avd-connection-paths-2-what-avd-settings-do/
#
# The properties (managedPrivateUDP, directUDP, publicUDP, relayUDP) are only returned by the
# preview API versions, and the stable Az.DesktopVirtualization module has no parameters for
# them. Azure CLI with a preview API version works without any preview module.
#
#   ./get-hostpool-shortpath.sh <host-pool-resource-id>
#
# The Terraform in this repo prints the ID as output host_pool_id:
#   ./get-hostpool-shortpath.sh "$(terraform -chdir=../terraform output -raw host_pool_id)"

set -euo pipefail
HOST_POOL_ID="${1:?Usage: $0 <host-pool-resource-id>}"

az resource show --ids "$HOST_POOL_ID" --api-version 2025-11-01-preview \
  --query "properties.{managed: managedPrivateUDP, direct: directUDP, public: publicUDP, relay: relayUDP}"
