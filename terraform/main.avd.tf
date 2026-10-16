############
## AVD connection paths lab: control plane objects
##
## Host pool (pooled, breadth-first), one desktop application group, one workspace. The four
## RDP Shortpath switches live on the host pool itself (azapi, azurerm has no arguments for them),
## so you can flip one network type at a time with a single apply.
############

resource "azapi_resource" "host_pool" {
  # Preview API on purpose: the four *UDP Shortpath properties are missing from the GA API
  # versions (2024-04-03, 2025-10-10) that azurerm_virtual_desktop_host_pool builds on.
  type      = "Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview"
  name      = "vdpool-${var.name}"
  parent_id = azurerm_resource_group.this.id
  location  = var.avd_metadata_location
  tags      = var.tags

  body = {
    properties = {
      hostPoolType          = "Pooled"
      loadBalancerType      = "BreadthFirst"
      maxSessionLimit       = var.max_sessions_per_host
      preferredAppGroupType = "Desktop"
      validationEnvironment = false
      startVMOnConnect      = true

      # targetisaadjoined:i:1  - the client knows the host is Entra joined (no domain controller)
      # enablerdsaadauth:i:1   - Entra single sign-on (Windows Cloud Login), also from macOS
      # Everything else stays at the service defaults: transport is the topic here.
      customRdpProperty = "targetisaadjoined:i:1;enablerdsaadauth:i:1;"

      # RDP Shortpath per network type (part 2). managedPrivateUDP = managed networks (on-prem over
      # VPN), directUDP = direct UDP inside the same network, publicUDP = STUN, relayUDP = TURN.
      managedPrivateUDP = var.shortpath.managed
      directUDP         = var.shortpath.managed
      publicUDP         = var.shortpath.public_stun
      relayUDP          = var.shortpath.public_turn
    }
  }

  # The registration token is written by azurerm_virtual_desktop_host_pool_registration_info below;
  # the service also adds agentUpdate defaults. Neither is managed here.
  lifecycle {
    ignore_changes = [body.properties.registrationInfo, body.properties.agentUpdate]
  }
}

# Registration token for the session hosts. Rotates daily; only new hosts consume it.
resource "time_rotating" "registration_token" {
  rotation_days = 1
}

resource "azurerm_virtual_desktop_host_pool_registration_info" "this" {
  hostpool_id     = azapi_resource.host_pool.id
  expiration_date = time_rotating.registration_token.rotation_rfc3339
}

resource "azurerm_virtual_desktop_application_group" "desktop" {
  name                         = "vdag-${var.name}-desktop"
  location                     = var.avd_metadata_location
  resource_group_name          = azurerm_resource_group.this.name
  host_pool_id                 = azapi_resource.host_pool.id
  type                         = "Desktop"
  friendly_name                = "AVD connection paths lab"
  default_desktop_display_name = "AVD connection paths lab"
  tags                         = var.tags
}

resource "azurerm_virtual_desktop_workspace" "this" {
  name                = "vdws-${var.name}"
  location            = var.avd_metadata_location
  resource_group_name = azurerm_resource_group.this.name
  friendly_name       = "AVD lab"
  tags                = var.tags
}

resource "azurerm_virtual_desktop_workspace_application_group_association" "this" {
  workspace_id         = azurerm_virtual_desktop_workspace.this.id
  application_group_id = azurerm_virtual_desktop_application_group.desktop.id
}

#### Who may connect
resource "azurerm_role_assignment" "users_desktop" {
  count = var.avd_user_group_object_id != "" ? 1 : 0

  scope                = azurerm_virtual_desktop_application_group.desktop.id
  role_definition_name = "Desktop Virtualization User"
  principal_id         = var.avd_user_group_object_id
  principal_type       = "Group"
}

# Entra joined hosts: sign-in needs one of the VM login roles on the VM (here: the whole RG).
resource "azurerm_role_assignment" "users_vm_login" {
  count = var.avd_user_group_object_id != "" ? 1 : 0

  scope                = azurerm_resource_group.this.id
  role_definition_name = "Virtual Machine User Login"
  principal_id         = var.avd_user_group_object_id
  principal_type       = "Group"
}

resource "azurerm_role_assignment" "admins_vm_login" {
  count = var.avd_admin_group_object_id != "" ? 1 : 0

  scope                = azurerm_resource_group.this.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = var.avd_admin_group_object_id
  principal_type       = "Group"
}

#### Start VM on Connect: the AVD service principal may power on deallocated hosts
resource "azurerm_role_assignment" "avd_power_on" {
  count = var.avd_service_principal_object_id != "" ? 1 : 0

  scope                = azurerm_resource_group.this.id
  role_definition_name = "Desktop Virtualization Power On Contributor"
  principal_id         = var.avd_service_principal_object_id
  principal_type       = "ServicePrincipal"
}

#### Diagnostics (WVDConnections, WVDCheckpoints, WVDErrors, WVDConnectionNetworkData, WVDAgentHealthStatus)
resource "azurerm_log_analytics_workspace" "this" {
  count = var.log_analytics_workspace_id == null ? 1 : 0

  name                = "law-${var.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

locals {
  log_analytics_workspace_id = coalesce(var.log_analytics_workspace_id, try(azurerm_log_analytics_workspace.this[0].id, null))
}

resource "azurerm_monitor_diagnostic_setting" "host_pool" {
  name                       = "avd-to-law"
  target_resource_id         = azapi_resource.host_pool.id
  log_analytics_workspace_id = local.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "workspace" {
  name                       = "avd-to-law"
  target_resource_id         = azurerm_virtual_desktop_workspace.this.id
  log_analytics_workspace_id = local.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
}
