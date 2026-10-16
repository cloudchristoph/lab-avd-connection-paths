#### General
variable "subscription_id" {
  description = "Subscription for the spoke, the host pool and the session hosts."
  type        = string
}

variable "name" {
  description = "Base name of all resources (rg-<name>, vnet-<name>, vdpool-<name>, vm-<name>-01, ...). Keep it short: the VM name vm-<name>-NN must fit the 15 character Windows computer name limit."
  type        = string
  default     = "avd-demo"

  validation {
    condition     = length("vm-${var.name}-01") <= 15
    error_message = "vm-<name>-NN must not be longer than 15 characters."
  }
}

variable "location" {
  description = "Azure region of the spoke and the session hosts."
  type        = string
  default     = "germanywestcentral"
}

variable "avd_metadata_location" {
  description = "Region of the AVD control plane objects (host pool, application group, workspace). These only exist in AVD metadata regions; there is none in Germany, westeurope is the closest one to germanywestcentral."
  type        = string
  default     = "westeurope"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    environment = "lab"
    workload    = "avd-connection-paths"
  }
}

#### Network
variable "vnet_address_space" {
  description = "Address space of the spoke VNet. The first /26 becomes the session host subnet. Must not overlap with the hub or on-prem."
  type        = string
  default     = "10.20.0.0/24"
}

variable "egress_mode" {
  description = <<-EOT
    How the session hosts reach the internet (AVD control plane, STUN/TURN, everything else):
      firewall - 0.0.0.0/0 via the hub Azure Firewall (needs hub_virtual_network_id and hub_firewall_private_ip).
      natgw    - NAT gateway on the host subnet, no firewall in the path to the internet.
      direct   - a Standard public IP on each session host NIC (comparison only, never a pattern to copy).
    On-prem traffic (onprem_address_space) stays on the firewall path in all three modes.
    After every switch, restart the session hosts before you test (part 3, trap 2).
  EOT
  type        = string
  default     = "firewall"

  validation {
    condition     = contains(["firewall", "natgw", "direct"], var.egress_mode)
    error_message = "egress_mode must be one of: firewall, natgw, direct."
  }
}

variable "avd_traffic_bypasses_firewall" {
  description = "egress_mode = firewall only: add the UDR WindowsVirtualDesktop -> Internet, so AVD service and TURN traffic skip the firewall (Microsoft's guidance against disconnects during firewall scale-in), and attach a NAT gateway. On a private subnet the route alone has no way out (part 3, trap 3)."
  type        = bool
  default     = false
}

variable "block_turn_udp" {
  description = "NSG denies UDP 3478 to 51.5.0.0/16. Removes the TURN candidate AND the STUN (server reflexive) candidate (part 3, trap 1). Works the same in every egress mode."
  type        = bool
  default     = false
}

variable "hub_virtual_network_id" {
  description = "Resource ID of an existing hub VNet to peer with. null = no hub: no peering, no on-prem path, and egress_mode must be natgw or direct. The hub may be in another subscription (the hub peering uses the subscription from this ID)."
  type        = string
  default     = null
}

variable "hub_has_vpn_gateway" {
  description = "The hub has a VPN or ExpressRoute gateway: the spoke uses remote gateways (gateway transit) to reach on-prem."
  type        = bool
  default     = true
}

variable "hub_firewall_private_ip" {
  description = "Private IP of the hub Azure Firewall. Next hop for 0.0.0.0/0 (egress_mode = firewall) and for on-prem. null = no firewall."
  type        = string
  default     = null
}

variable "onprem_address_space" {
  description = "On-prem network behind the hub VPN gateway (where the on-prem clients sit). Routed via the firewall in every egress mode and allowed inbound on UDP for the managed path. null = no on-prem."
  type        = string
  default     = null
}

#### Optional: firewall rules in an existing Azure Firewall policy
variable "firewall_policy_id" {
  description = "Resource ID of the hub's Azure Firewall policy. If set, this stack adds its own rule collection group with the AVD rules from part 3 (firewall-rules.tf). null = manage the rules yourself."
  type        = string
  default     = null
}

variable "firewall_rule_collection_group_priority" {
  description = "Priority of the AVD rule collection group in the firewall policy. Must be unique within the policy."
  type        = number
  default     = 1000
}

variable "firewall_allow_user_web" {
  description = "Let the desktop users browse (http/https to *). Off by default, so the firewall logs show only what AVD itself needs."
  type        = bool
  default     = false
}

#### RDP Shortpath (host pool properties, see part 2)
# Values: "Default" (service default), "Enabled", "Disabled". On new host pools "Default" already
# means on; the lab sets them explicitly so you can flip one network type at a time.
variable "shortpath" {
  description = "RDP Shortpath per network type. managed = managedPrivateUDP and directUDP (direct UDP over VPN or ExpressRoute), public_stun = publicUDP (direct UDP across the internet via STUN), public_turn = relayUDP (UDP relayed through TURN, 51.5.0.0/16)."
  type = object({
    managed     = string
    public_stun = string
    public_turn = string
  })
  default = {
    managed     = "Enabled"
    public_stun = "Enabled"
    public_turn = "Enabled"
  }

  validation {
    condition     = alltrue([for v in values(var.shortpath) : contains(["Default", "Enabled", "Disabled"], v)])
    error_message = "Every shortpath value must be Default, Enabled or Disabled."
  }
}

#### Host pool and session hosts
variable "session_host_count" {
  description = "Number of pooled session hosts. One is enough to show the transport."
  type        = number
  default     = 1

  validation {
    condition     = var.session_host_count >= 1 && var.session_host_count <= 2
    error_message = "session_host_count must be 1 or 2 (this is a lab)."
  }
}

variable "session_host_sku" {
  description = "Session host VM size. Check availability in your region before the first apply."
  type        = string
  default     = "Standard_D2as_v5"
}

variable "session_host_image" {
  description = "Windows 11 Enterprise multi-session marketplace image (24H2, no Microsoft 365 apps)."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-24h2-avd"
    version   = "latest"
  }
}

variable "max_sessions_per_host" {
  description = "Session limit per host."
  type        = number
  default     = 4
}

variable "admin_username" {
  description = "Local admin on the session hosts (break-glass only; users sign in with Entra ID). The password is generated and available as sensitive output admin_password."
  type        = string
  default     = "avdlabadmin"
}

#### Identities (Entra ID)
variable "avd_user_group_object_id" {
  description = "Object ID of the Entra group with the lab user(s). Gets Desktop Virtualization User on the application group and Virtual Machine User Login on the resource group. Empty = no assignments (deploy works, sign-in does not)."
  type        = string
  default     = ""
}

variable "avd_admin_group_object_id" {
  description = "Optional Entra group that gets Virtual Machine Administrator Login on the session hosts. Empty = none."
  type        = string
  default     = ""
}

variable "avd_service_principal_object_id" {
  description = "Object ID of the \"Azure Virtual Desktop\" service principal in your tenant (az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv). Needed for Start VM on Connect. Empty = no role assignment, start the hosts yourself."
  type        = string
  default     = ""
}

#### Logging
variable "log_analytics_workspace_id" {
  description = "Resource ID of an existing Log Analytics workspace for the host pool and workspace diagnostics (WVDConnections, WVDCheckpoints, ...). null = this stack creates one in its resource group."
  type        = string
  default     = null
}
