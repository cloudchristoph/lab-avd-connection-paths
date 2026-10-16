<#
  Which transport carries an AVD session right now? Reads the RemoteFX Network counters on the
  session host.

  Source: "AVD connection paths, part 6", section "The other way round: UDP the dialog doesn't show"
          https://cloudchristoph.com/articles/avd-connection-paths-6-reading-the-logs/

  Run it on the session host while a session is active, for example:
    az vm run-command invoke -g <rg> -n <vm> --command-id RunPowerShellScript --scripts @Get-RemoteFxCounters.ps1

  Reading the result (lab observation, not documented):
    UDP RTT and UDP bandwidth move with the load, TCP RTT sits at 400 ms and TCP bandwidth at 512
    -> the data runs over UDP. With TCP only, the UDP counters stay empty or at zero.
#>
param(
  [int] $SampleInterval = 10,
  [int] $MaxSamples = 6
)

$counters = @(
  '\RemoteFX Network(*)\Current UDP RTT',
  '\RemoteFX Network(*)\Current UDP Bandwidth',
  '\RemoteFX Network(*)\Current TCP RTT',
  '\RemoteFX Network(*)\Current TCP Bandwidth'
)

try {
  $samples = Get-Counter -Counter $counters -SampleInterval $SampleInterval -MaxSamples $MaxSamples -ErrorAction Stop
} catch {
  # The counter set only has instances while a remote session is active on this host.
  Write-Warning "No RemoteFX Network counters: is a remote session active on this host? ($($_.Exception.Message))"
  return
}

$samples |
  ForEach-Object {
    $t = $_.Timestamp.ToUniversalTime().ToString('HH:mm:ss')
    $_.CounterSamples | ForEach-Object {
      [pscustomobject]@{ TimeUtc = $t; Instance = $_.InstanceName; Counter = ($_.Path -split '\\')[-1]; Value = [math]::Round($_.CookedValue, 0) }
    }
  } | Format-Table -AutoSize
