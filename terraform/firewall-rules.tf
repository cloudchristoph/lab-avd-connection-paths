############
## AVD connection paths lab: optional rule collection group in the hub's Azure Firewall policy
##
## Only created when firewall_policy_id is set. One collection per question (part 3):
##
##   avd-onprem-shortpath   (net 100)  on-prem client <-> session host, RDP Shortpath managed path
##   avd-required-net       (net 200)  what the service needs below L7: service tags, TURN, KMS
##   avd-stun-direct        (net 300)  direct UDP to the internet client. Allowed on purpose: STUN
##                                     still fails behind the firewall, its SNAT is symmetric NAT
##   avd-required-app       (app 400)  required FQDNs for session hosts
##                                     (https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint)
##   avd-entra-join         (app 410)  what an Entra joined host needs on top
##   avd-optional-app       (app 420)  recommended, not required (telemetry, certificates, updates)
##
## Everything not listed hits the policy's default deny, which is the point: the firewall logs
## show what AVD really needs (kql/firewall-avd-hits.kql). No TLS inspection for AVD traffic.
## The KMS rule uses FQDNs in a network rule and needs DNS proxy enabled on the policy.
############

locals {
  fw_rules_enabled = var.firewall_policy_id != null

  # STUN and TURN relays. Moved from 20.202.0.0/16 to 51.5.0.0/16 in 2025.
  avd_turn_prefix = "51.5.0.0/16"

  fw_onprem_collection = local.has_onprem ? [{
    name               = "avd-onprem-shortpath"
    ruleCollectionType = "FirewallPolicyFilterRuleCollection"
    priority           = 100
    action             = { type = "Allow" }
    rules = [
      {
        name                 = "onprem-client-to-host-udp"
        description          = "RDP Shortpath for managed networks: on-prem client to the host's private IP (3390 = listener mode, 49152-65535 = ICE)"
        ruleType             = "NetworkRule"
        sourceAddresses      = [var.onprem_address_space]
        destinationAddresses = [local.host_subnet_cidr]
        destinationPorts     = ["3390", "49152-65535"]
        ipProtocols          = ["UDP"]
      },
      {
        # ICE checks run in both directions; without this rule the host's half of the
        # handshake dies at the firewall.
        name                 = "host-to-onprem-client-udp"
        description          = "RDP Shortpath for managed networks: the host's ICE checks towards the client's private candidate"
        ruleType             = "NetworkRule"
        sourceAddresses      = [local.host_subnet_cidr]
        destinationAddresses = [var.onprem_address_space]
        destinationPorts     = ["1024-65535"]
        ipProtocols          = ["UDP"]
      },
    ]
  }] : []

  fw_user_web_collection = var.firewall_allow_user_web ? [{
    name               = "avd-user-web"
    ruleCollectionType = "FirewallPolicyFilterRuleCollection"
    priority           = 500
    action             = { type = "Allow" }
    rules = [
      {
        name            = "desktop-users-browse"
        description     = "What the users in the desktop browse, kept apart from what AVD needs"
        ruleType        = "ApplicationRule"
        sourceAddresses = [local.host_subnet_cidr]
        targetFqdns     = ["*"]
        protocols       = [{ protocolType = "Http", port = 80 }, { protocolType = "Https", port = 443 }]
      },
    ]
  }] : []
}

resource "azapi_resource" "firewall_rules" {
  count = local.fw_rules_enabled ? 1 : 0

  type      = "Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01"
  name      = "avd-${var.name}-rule-collection-group"
  parent_id = var.firewall_policy_id

  body = {
    properties = {
      priority = var.firewall_rule_collection_group_priority
      ruleCollections = concat(local.fw_onprem_collection, [
        {
          name               = "avd-required-net"
          ruleCollectionType = "FirewallPolicyFilterRuleCollection"
          priority           = 200
          action             = { type = "Allow" }
          rules = [
            {
              name                 = "avd-service-tcp"
              description          = "AVD service traffic incl. reverse connect (*.wvd.microsoft.com, *.service.windows.cloud.microsoft)"
              ruleType             = "NetworkRule"
              sourceAddresses      = [local.host_subnet_cidr]
              destinationAddresses = ["WindowsVirtualDesktop"]
              destinationPorts     = ["443"]
              ipProtocols          = ["TCP"]
            },
            {
              name                 = "avd-stun-turn-udp"
              description          = "RDP Shortpath for public networks: STUN and TURN relays"
              ruleType             = "NetworkRule"
              sourceAddresses      = [local.host_subnet_cidr]
              destinationAddresses = [local.avd_turn_prefix]
              destinationPorts     = ["3478"]
              ipProtocols          = ["UDP"]
            },
            {
              name                 = "azure-monitor"
              description          = "AVD agent telemetry and diagnostics"
              ruleType             = "NetworkRule"
              sourceAddresses      = [local.host_subnet_cidr]
              destinationAddresses = ["AzureMonitor"]
              destinationPorts     = ["443"]
              ipProtocols          = ["TCP"]
            },
            {
              name             = "windows-activation-kms"
              description      = "Windows activation (azkms.core.windows.net:1688), not covered by any FQDN tag. Needs DNS proxy on the policy."
              ruleType         = "NetworkRule"
              sourceAddresses  = [local.host_subnet_cidr]
              destinationFqdns = ["azkms.core.windows.net", "kms.core.windows.net"]
              destinationPorts = ["1688"]
              ipProtocols      = ["TCP"]
            },
          ]
        },
        {
          name               = "avd-stun-direct"
          ruleCollectionType = "FirewallPolicyFilterRuleCollection"
          priority           = 300
          action             = { type = "Allow" }
          rules = [
            {
              name                 = "host-to-internet-client-udp"
              description          = "Direct UDP to the internet client's public candidate (Microsoft's recommendation for the direct STUN path)"
              ruleType             = "NetworkRule"
              sourceAddresses      = [local.host_subnet_cidr]
              destinationAddresses = ["*"]
              destinationPorts     = ["1024-65535"]
              ipProtocols          = ["UDP"]
            },
          ]
        },
        {
          name               = "avd-required-app"
          ruleCollectionType = "FirewallPolicyFilterRuleCollection"
          priority           = 400
          action             = { type = "Allow" }
          rules = [
            {
              name            = "avd-fqdn-tag"
              description     = "FQDN tag WindowsVirtualDesktop"
              ruleType        = "ApplicationRule"
              sourceAddresses = [local.host_subnet_cidr]
              fqdnTags        = ["WindowsVirtualDesktop"]
              protocols       = [{ protocolType = "Https", port = 443 }]
            },
            {
              name            = "avd-required-https"
              description     = "Required FQDNs for session hosts, TCP 443"
              ruleType        = "ApplicationRule"
              sourceAddresses = [local.host_subnet_cidr]
              targetFqdns = [
                "login.microsoftonline.com",
                "*.wvd.microsoft.com",
                "*.service.windows.cloud.microsoft",
                "*.windows.cloud.microsoft",
                "*.windows.static.microsoft",
                "catalogartifact.azureedge.net",
                "*.prod.warm.ingest.monitor.core.windows.net",
                "gcs.prod.monitoring.core.windows.net",
                "mrsglobalsteus2prod.blob.core.windows.net",
                "wvdportalstorageblob.blob.core.windows.net",
              ]
              protocols = [{ protocolType = "Https", port = 443 }]
            },
            {
              name            = "avd-required-certificates"
              description     = "Required FQDNs for session hosts, TCP 80 (certificate revocation and AIK certificates)"
              ruleType        = "ApplicationRule"
              sourceAddresses = [local.host_subnet_cidr]
              targetFqdns = [
                "oneocsp.microsoft.com",
                "www.microsoft.com",
                "*.aikcertaia.microsoft.com",
                "azcsprodeusaikpublish.blob.core.windows.net",
                "*.microsoftaik.azure.net",
                "ctldl.windowsupdate.com",
              ]
              protocols = [{ protocolType = "Http", port = 80 }]
            },
          ]
        },
        {
          name               = "avd-entra-join"
          ruleCollectionType = "FirewallPolicyFilterRuleCollection"
          priority           = 410
          action             = { type = "Allow" }
          rules = [
            {
              name            = "entra-joined-host"
              description     = "Entra join and Entra sign-in on the host (not part of the AVD list)"
              ruleType        = "ApplicationRule"
              sourceAddresses = [local.host_subnet_cidr]
              targetFqdns = [
                "enterpriseregistration.windows.net",
                "pas.windows.net",
                "device.login.microsoftonline.com",
                "login.windows.net",
              ]
              protocols = [{ protocolType = "Https", port = 443 }]
            },
          ]
        },
        {
          name               = "avd-optional-app"
          ruleCollectionType = "FirewallPolicyFilterRuleCollection"
          priority           = 420
          action             = { type = "Allow" }
          rules = [
            {
              name            = "optional-https"
              description     = "Optional: telemetry, delivery optimization, Azure DNS over HTTPS endpoints"
              ruleType        = "ApplicationRule"
              sourceAddresses = [local.host_subnet_cidr]
              targetFqdns = [
                "*.events.data.microsoft.com",
                "*.prod.do.dsp.mp.microsoft.com",
                "*.sfx.ms",
                "*.azure-dns.com",
                "*.azure-dns.net",
              ]
              protocols = [{ protocolType = "Https", port = 443 }]
            },
            {
              name            = "optional-http"
              description     = "Optional: connectivity test and certificate checks"
              ruleType        = "ApplicationRule"
              sourceAddresses = [local.host_subnet_cidr]
              targetFqdns     = ["www.msftconnecttest.com", "*.digicert.com"]
              protocols       = [{ protocolType = "Http", port = 80 }]
            },
            {
              name            = "windows-update"
              description     = "Windows Update, keeps the image patchable"
              ruleType        = "ApplicationRule"
              sourceAddresses = [local.host_subnet_cidr]
              fqdnTags        = ["WindowsUpdate"]
              protocols       = [{ protocolType = "Http", port = 80 }, { protocolType = "Https", port = 443 }]
            },
          ]
        },
      ], local.fw_user_web_collection)
    }
  }
}
