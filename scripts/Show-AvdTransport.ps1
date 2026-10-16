<#
.SYNOPSIS
    Runs INSIDE an AVD session on the session host and shows, live, whether this session runs on
    UDP (RDP Shortpath) or TCP, without waiting for Log Analytics.

.DESCRIPTION
    Reads the RDP core log of the session host
    (Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational):
      131: the TCP connection was accepted (reverse connect is always the start)
      135: "the multi-transport connection finished for tunnel: 1, its transport type set to UDP"
           = RDP Shortpath is up
    plus the UDP sockets the RDP service (TermService) holds.

    Windows shows no remote address for UDP sockets, so WHICH UDP path (managed, STUN or TURN)
    is answered by the client's Connection Information dialog and by Log Analytics
    (kql/session-classification.kql, scripts/avd-transport.sh). This script answers
    "UDP or TCP" without any delay.

    Related: "AVD connection paths, part 2" (event 135)
    https://cloudchristoph.com/articles/avd-connection-paths-2-what-avd-settings-do/

.PARAMETER Watch
    Refresh every N seconds. 0 (default) runs once.

.PARAMETER Minutes
    How far back to read the event log. Default 30.

.EXAMPLE
    .\Show-AvdTransport.ps1 -Watch 5
#>
param(
    [int]$Watch = 0,
    [int]$Minutes = 30
)

$log = "Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational"

function Show-Once {
    $since = (Get-Date).AddMinutes(-$Minutes)
    Write-Host ""
    Write-Host "RDP transport events since $($since.ToString('HH:mm'))" -ForegroundColor White
    if (-not (Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue)) {
        Write-Host "  log not found: run this on an AVD session host" -ForegroundColor Red
    } else {
        try {
            Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 131, 135; StartTime = $since } -ErrorAction Stop |
                Sort-Object TimeCreated |
                ForEach-Object {
                    $kind = if ($_.Id -eq 135) { "UDP up " } else { "TCP in " }
                    $colour = if ($_.Id -eq 135) { "Green" } else { "Gray" }
                    Write-Host ("{0:HH:mm:ss}  {1}  {2}" -f $_.TimeCreated, $kind, ($_.Message -split "`n")[0]) -ForegroundColor $colour
                }
        } catch [System.Exception] {
            # Get-WinEvent raises "No events were found" as an error, but also real errors (rights, broken log)
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { Write-Host "  no events in the last $Minutes minutes" -ForegroundColor Gray }
            else { Write-Host "  could not read the log: $($_.Exception.Message)" -ForegroundColor Red }
        }
    }

    Write-Host ""
    Write-Host "UDP endpoints of the RDP service (TermService)" -ForegroundColor White
    $svcPid = (Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId
    if (-not $svcPid) { Write-Host "  TermService is not running: run this on an AVD session host" -ForegroundColor Red; return }
    $udp = @(Get-NetUDPEndpoint -OwningProcess $svcPid -ErrorAction SilentlyContinue | Where-Object LocalPort -ne 3389)
    if (-not $udp) { Write-Host "  none: this session runs over TCP (reverse connect, WebSocket)" -ForegroundColor Red; return }
    foreach ($e in $udp) {
        Write-Host ("  {0}:{1}" -f $e.LocalAddress, $e.LocalPort) -ForegroundColor Cyan
    }
}

if ($Watch -gt 0) {
    while ($true) { Clear-Host; Show-Once; Start-Sleep -Seconds $Watch }
} else {
    Show-Once
}
