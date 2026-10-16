############
## AVD connection paths lab: session hosts
##
## Windows 11 Enterprise multi-session 24H2, Entra joined (AADLoginForWindows), registered with
## the host pool by the AVD DSC configuration. No domain controller, no FSLogix: the lab is about
## the transport, nobody keeps data on the hosts.
############

locals {
  hosts = {
    for i in range(var.session_host_count) : format("%02d", i + 1) => cidrhost(local.host_subnet_cidr, 11 + i)
  }

  # AVD agent and boot loader installer, published by Microsoft. A newer version only matters
  # for new hosts; the agent updates itself afterwards.
  avd_dsc_modules_url = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.03211.1002.zip"
}

resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
}

# Exists in direct mode only.
resource "azurerm_public_ip" "host" {
  for_each = var.egress_mode == "direct" ? local.hosts : {}

  name                = "pip-vm-${var.name}-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "host" {
  for_each = local.hosts

  name                = "nic-vm-${var.name}-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.hosts.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value
    public_ip_address_id          = var.egress_mode == "direct" ? azurerm_public_ip.host[each.key].id : null
  }
}

resource "azurerm_windows_virtual_machine" "host" {
  for_each = local.hosts

  name                = "vm-${var.name}-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  size                = var.session_host_sku
  admin_username      = var.admin_username
  admin_password      = random_password.admin.result
  license_type        = "Windows_Client" # multi-session needs the client licence flag (per-user licensing)
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.host[each.key].id]

  secure_boot_enabled = true
  vtpm_enabled        = true
  patch_mode          = "AutomaticByOS"

  os_disk {
    name                 = "osdisk-vm-${var.name}-${each.key}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = var.session_host_image.publisher
    offer     = var.session_host_image.offer
    sku       = var.session_host_image.sku
    version   = var.session_host_image.version
  }

  boot_diagnostics {}

  # Required for the Entra join (AADLoginForWindows).
  identity {
    type = "SystemAssigned"
  }

  # Registration needs the control plane; cloud egress needs the routes (and the NAT gateway).
  depends_on = [
    azurerm_subnet_route_table_association.hosts,
    azurerm_subnet_network_security_group_association.hosts,
    azurerm_subnet_nat_gateway_association.hosts,
    azurerm_virtual_network_peering.spoke_to_hub,
    azapi_resource.firewall_rules,
  ]
}

# Entra join, no Intune enrollment.
resource "azurerm_virtual_machine_extension" "aad_login" {
  for_each = local.hosts

  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.host[each.key].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true
}

# AVD agent and registration with the host pool (aadJoin = true: no domain join step).
resource "azurerm_virtual_machine_extension" "avd_agent" {
  for_each = local.hosts

  name                       = "Microsoft.PowerShell.DSC"
  virtual_machine_id         = azurerm_windows_virtual_machine.host[each.key].id
  publisher                  = "Microsoft.Powershell"
  type                       = "DSC"
  type_handler_version       = "2.73"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    modulesUrl            = local.avd_dsc_modules_url
    configurationFunction = "Configuration.ps1\\AddSessionHost"
    properties = {
      HostPoolName = azapi_resource.host_pool.name
      aadJoin      = true
      registrationInfoTokenCredential = {
        UserName = "PLACEHOLDER_DO_NOT_USE"
        Password = "PrivateSettingsRef:RegistrationInfoToken"
      }
    }
  })

  protected_settings = jsonencode({
    Items = {
      RegistrationInfoToken = azurerm_virtual_desktop_host_pool_registration_info.this.token
    }
  })

  lifecycle {
    # The token expires; a new one must not re-run the extension on registered hosts.
    ignore_changes = [protected_settings]
  }

  depends_on = [azurerm_virtual_machine_extension.aad_login]
}
