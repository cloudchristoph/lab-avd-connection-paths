############
## AVD connection paths lab: spoke and egress variants
##
## One private subnet for the session hosts. What changes with egress_mode is only the way to the
## internet; the way to on-prem (clients over the VPN) is pinned to the firewall in every mode:
##
##   firewall  0.0.0.0/0 -> hub firewall. SNAT to the firewall's public IP; the rules are in
##             firewall-rules.tf (optional) or in your own firewall policy.
##   natgw     no default route; the NAT gateway on the subnet takes 0.0.0.0/0. The firewall
##             sees nothing of the internet traffic.
##   direct    no default route, no NAT gateway; a Standard public IP on each host NIC.
##
## BGP route propagation stays OFF and on-prem gets its own UDR to the firewall. For symmetric
## routing, the hub's GatewaySubnet also needs a route for this spoke's address space to the
## firewall (not managed here, see the README).
############

locals {
  host_subnet_cidr = cidrsubnet(var.vnet_address_space, 2, 0) # first /26

  has_hub      = var.hub_virtual_network_id != null
  has_firewall = var.hub_firewall_private_ip != null
  has_onprem   = var.onprem_address_space != null

  hub_id_parts = local.has_hub ? split("/", var.hub_virtual_network_id) : []
  hub_rg_name  = local.has_hub ? local.hub_id_parts[4] : null
  hub_name     = local.has_hub ? local.hub_id_parts[8] : null

  # Bypass: the route sends the AVD prefixes to next hop Internet, and a private subnet has no way
  # out there without a NAT gateway (route alone: the broker on 443 times out). The 0.0.0.0/0 UDR
  # still keeps everything else on the firewall, because a UDR wins over the NAT gateway.
  bypass_active = var.egress_mode == "firewall" && var.avd_traffic_bypasses_firewall
  natgw_enabled = var.egress_mode == "natgw" || local.bypass_active

  routes = merge(
    local.has_onprem && local.has_firewall ? {
      onprem-via-firewall = {
        address_prefix         = var.onprem_address_space
        next_hop_type          = "VirtualAppliance"
        next_hop_in_ip_address = var.hub_firewall_private_ip
      }
    } : {},
    var.egress_mode == "firewall" ? {
      default-via-firewall = {
        address_prefix         = "0.0.0.0/0"
        next_hop_type          = "VirtualAppliance"
        next_hop_in_ip_address = var.hub_firewall_private_ip
      }
    } : {},
    # Microsoft's answer to "AVD sessions drop when the firewall scales in": AVD service and TURN
    # traffic leave directly, everything else still goes through the firewall.
    local.bypass_active ? {
      avd-service-direct = {
        address_prefix         = "WindowsVirtualDesktop"
        next_hop_type          = "Internet"
        next_hop_in_ip_address = null
      }
    } : {},
  )
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = var.tags

  lifecycle {
    precondition {
      condition     = var.egress_mode != "firewall" || (local.has_hub && local.has_firewall)
      error_message = "egress_mode = firewall needs hub_virtual_network_id and hub_firewall_private_ip. Without a hub, use natgw or direct."
    }
  }
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  address_space       = [var.vnet_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet" "hosts" {
  name                 = "snet-hosts-${var.name}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.host_subnet_cidr]

  # Private subnet: no default outbound access. In "direct" mode the NIC's own public IP is the
  # way out; default outbound access would only blur which path the lab shows.
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "hosts" {
  name                = "nsg-${var.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  # RDP Shortpath for managed networks: the on-prem client sends UDP straight to the host's
  # private IP. ICE uses the dynamic range on the host; 3390 is the listener port (opt-in).
  dynamic "security_rule" {
    for_each = local.has_onprem ? [1] : []
    content {
      name                       = "allow-onprem-shortpath-managed"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_ranges    = ["3390", "49152-65535"]
      source_address_prefix      = var.onprem_address_space
      destination_address_prefix = "*"
    }
  }

  # Nothing comes in from the internet, also not in "direct" mode: STUN hole punching works with
  # the stateful NSG because the host sends first, so the answer counts as established traffic.
  # No TCP 3389 either: AVD uses reverse connect and needs no inbound port.

  # Switch: no STUN and no TURN -> sessions without another UDP path fall back to TCP.
  dynamic "security_rule" {
    for_each = var.block_turn_udp ? [1] : []
    content {
      name                       = "deny-stun-turn-udp"
      priority                   = 200
      direction                  = "Outbound"
      access                     = "Deny"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "3478"
      source_address_prefix      = "*"
      destination_address_prefix = "51.5.0.0/16"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "hosts" {
  subnet_id                 = azurerm_subnet.hosts.id
  network_security_group_id = azurerm_network_security_group.hosts.id
}

resource "azurerm_route_table" "hosts" {
  name                = "rt-${var.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  # OFF on purpose: keeps the replies to on-prem on the firewall path.
  bgp_route_propagation_enabled = false

  dynamic "route" {
    for_each = local.routes
    content {
      name                   = route.key
      address_prefix         = route.value.address_prefix
      next_hop_type          = route.value.next_hop_type
      next_hop_in_ip_address = route.value.next_hop_in_ip_address
    }
  }
}

resource "azurerm_subnet_route_table_association" "hosts" {
  subnet_id      = azurerm_subnet.hosts.id
  route_table_id = azurerm_route_table.hosts.id
}

#### Peering with the existing hub (optional)
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count = local.has_hub ? 1 : 0

  name                         = "${var.name}-to-hub"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.this.name
  remote_virtual_network_id    = var.hub_virtual_network_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = var.hub_has_vpn_gateway

  # Gateway transit needs the hub side to allow it first.
  depends_on = [azurerm_virtual_network_peering.hub_to_spoke]
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  count    = local.has_hub ? 1 : 0
  provider = azurerm.hub

  name                         = "hub-to-${var.name}"
  resource_group_name          = local.hub_rg_name
  virtual_network_name         = local.hub_name
  remote_virtual_network_id    = azurerm_virtual_network.this.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = var.hub_has_vpn_gateway
}

#### Egress variant "natgw" (and the bypass route)
resource "azurerm_public_ip" "natgw" {
  count = local.natgw_enabled ? 1 : 0

  name                = "pip-natgw-${var.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  count = local.natgw_enabled ? 1 : 0

  name                    = "natgw-${var.name}"
  location                = var.location
  resource_group_name     = azurerm_resource_group.this.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = local.natgw_enabled ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.natgw[0].id
}

resource "azurerm_subnet_nat_gateway_association" "hosts" {
  count = local.natgw_enabled ? 1 : 0

  subnet_id      = azurerm_subnet.hosts.id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}
