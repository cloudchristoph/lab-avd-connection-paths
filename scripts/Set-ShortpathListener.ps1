<#
  Enables the RDP Shortpath listener for managed networks on a session host: the host listens on
  UDP 3390 (all addresses) and the Windows Firewall lets the on-prem / VPN client networks in.
  Lab shortcut for "AVD connection paths, part 4: private networks and the Shortpath listener"
  (https://cloudchristoph.com/articles/avd-connection-paths-4-private-networks/).
  Runs as SYSTEM, for example through az vm run-command; idempotent.

  The official way is the policy "Enable RDP Shortpath for managed networks" through Intune or
  Group Policy:
  https://learn.microsoft.com/azure/virtual-desktop/configure-rdp-shortpath#enable-the-rdp-shortpath-listener-for-rdp-shortpath-for-managed-networks
  The two registry value names below are not documented on Learn. Use this script in a lab only.

  Example:
    az vm run-command invoke -g <rg> -n <vm> --command-id RunPowerShellScript \
      --scripts @Set-ShortpathListener.ps1 --parameters "RemoteAddresses=10.1.10.0/24,192.168.10.0/24"
#>
param(
  # Comma-separated CIDRs allowed to reach UDP 3390 (on-prem + VPN client pools).
  [Parameter(Mandatory)] [string] $RemoteAddresses,
  [int] $UdpPort = 3390
)

$ErrorActionPreference = 'Stop'
$script:rebootNeeded = $false

function Set-RegDword {
  param([string] $Path, [string] $Name, [int] $Value, [switch] $NeedsReboot)
  if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
  $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
  if ($current -ne $Value) {
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    Write-Output "set    $Path\$Name = $Value (was: $current)"
    if ($NeedsReboot) { $script:rebootNeeded = $true }
  } else {
    Write-Output "ok     $Path\$Name = $Value"
  }
}

# The listener is read at service start: both values need a restart when they change.
$ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
Set-RegDword $ts 'fUseUdpPortRedirector' 1 -NeedsReboot
Set-RegDword $ts 'UdpPortNumber' $UdpPort -NeedsReboot

function ConvertTo-FwAddress {
  param([string] $Cidr)
  if ($Cidr -notmatch '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') { return $Cidr }
  $bits = [int]$Matches[2]
  if ($bits -eq 32) { return $Matches[1] }
  $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $bits))
  $octets = 0..3 | ForEach-Object { [string](($mask -shr (24 - 8 * $_)) -band 255) }
  "$($Matches[1])/$($octets -join '.')"
}

# Inbound rule, scoped to the client networks. No reboot: the firewall applies it at once.
$ruleName  = "RDPShortpath-Managed-UDP$UdpPort"
$wanted    = @($RemoteAddresses -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$rule      = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if (-not $rule) {
  New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Direction Inbound -Protocol UDP `
    -LocalPort $UdpPort -RemoteAddress $wanted -Action Allow -Profile Any | Out-Null
  Write-Output "set    firewall rule $ruleName = $($wanted -join ',') (was: missing)"
} else {
  $filter  = $rule | Get-NetFirewallAddressFilter
  $portf   = $rule | Get-NetFirewallPortFilter
  $current = @($filter.RemoteAddress)
  # Windows stores CIDRs as address/netmask, so bring both sides into that form before comparing.
  $expected = $wanted | ForEach-Object { ConvertTo-FwAddress $_ }
  $same = ((@($current) | Sort-Object) -join ',') -eq ((@($expected) | Sort-Object) -join ',')
  if (-not $same -or $portf.LocalPort -ne "$UdpPort" -or $rule.Enabled -ne 'True' -or $rule.Action -ne 'Allow') {
    Set-NetFirewallRule -Name $ruleName -Enabled True -Action Allow -Direction Inbound -Profile Any `
      -Protocol UDP -LocalPort $UdpPort -RemoteAddress $wanted
    Write-Output "set    firewall rule $ruleName = $($wanted -join ',') (was: $($current -join ','))"
  } else {
    Write-Output "ok     firewall rule $ruleName = $($wanted -join ',')"
  }
}

if ($script:rebootNeeded) {
  # Delayed, so this run command can report success before the host goes down.
  shutdown.exe /r /t 60 /c "RDP Shortpath listener on UDP $UdpPort needs a restart"
  Write-Output 'reboot scheduled in 60 s'
} else {
  Write-Output 'no reboot needed'
}
