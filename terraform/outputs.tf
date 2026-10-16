output "egress_mode" {
  description = "Active egress variant. The first thing to check before every test run."
  value       = var.egress_mode
}

output "egress_public_ips" {
  description = "Public IP(s) the internet sees from the session hosts in natgw or direct mode (also with the bypass route). In plain firewall mode it is the firewall's public IP (not managed here)."
  value = merge(
    { for p in azurerm_public_ip.natgw : "natgw" => p.ip_address },
    { for k, p in azurerm_public_ip.host : "vm-${var.name}-${k}" => p.ip_address },
  )
}

output "session_hosts" {
  description = "Session hosts by index."
  value = {
    for k, vm in azurerm_windows_virtual_machine.host : k => {
      name       = vm.name
      private_ip = vm.private_ip_address
    }
  }
}

output "host_pool_id" {
  description = "Host pool resource ID (scripts/get-hostpool-shortpath.sh; _ResourceId in WVDConnections)."
  value       = azapi_resource.host_pool.id
}

output "shortpath" {
  description = "RDP Shortpath switches as deployed."
  value       = var.shortpath
}

output "session_host_subnet" {
  description = "Session host subnet. Use its prefix in kql/firewall-avd-hits.kql."
  value       = local.host_subnet_cidr
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace that receives the AVD diagnostics."
  value       = local.log_analytics_workspace_id
}

output "log_analytics_workspace_customer_id" {
  description = "Workspace (customer) ID for az monitor log-analytics query (scripts/avd-transport.sh). Only set when this stack created the workspace."
  value       = try(azurerm_log_analytics_workspace.this[0].workspace_id, null)
}

output "admin_password" {
  description = "Generated password of the local admin (break-glass only)."
  value       = random_password.admin.result
  sensitive   = true
}
