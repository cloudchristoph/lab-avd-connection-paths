terraform {
  required_version = ">= 1.9"

  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.4"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.47"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Local state by default. For a shared setup, add your own backend, for example:
  # backend "azurerm" {
  #   use_azuread_auth     = true
  #   storage_account_name = "<your state storage account>"
  #   container_name       = "<container>"
  #   key                  = "lab-avd-connection-paths.tfstate"
  # }
}

provider "azurerm" {
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}

# The hub VNet and the firewall policy may live in another subscription (typical hub and spoke).
# This alias is used for the hub to spoke peering. (The optional firewall rule collection group is
# written with azapi by full resource ID and needs no alias.)
provider "azurerm" {
  alias               = "hub"
  subscription_id     = var.hub_virtual_network_id != null ? split("/", var.hub_virtual_network_id)[2] : var.subscription_id
  storage_use_azuread = true
  features {}
}
