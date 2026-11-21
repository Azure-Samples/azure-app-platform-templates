param(
  [Parameter(Mandatory = $true)][string] $RunDir,
  [string] $Name = ""
)

$ErrorActionPreference = "Stop"
$State = Join-Path $RunDir "processes.json"
$NextState = Join-Path $RunDir "processes.mcp.next.json"

if (-not (Test-Path -LiteralPath $State)) {
  exit 0
}

function Get-ProcessStartIdentity([int] $ProcessId) {
  $Process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $Process) { return $null }
  return $Process.StartTime.ToUniversalTime().ToString("O")
}

function Stop-ExactProcessTree([int] $ProcessId, [string] $ExpectedStart) {
  if ((Get-ProcessStartIdentity $ProcessId) -ne $ExpectedStart) { return $true }
  try { & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null } catch { }
  for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
    if ((Get-ProcessStartIdentity $ProcessId) -ne $ExpectedStart) { return $true }
    Start-Sleep -Milliseconds 100
  }
  return (Get-ProcessStartIdentity $ProcessId) -ne $ExpectedStart
}

$ProtectedPids = @{}
$AncestorPid = [int]$PID
while ($AncestorPid -gt 0 -and -not $ProtectedPids.ContainsKey($AncestorPid)) {
  $ProtectedPids[$AncestorPid] = $true
  try {
    $Ancestor = Get-CimInstance Win32_Process -Filter "ProcessId=$AncestorPid" -ErrorAction Stop
    $AncestorPid = [int]$Ancestor.ParentProcessId
  } catch {
    break
  }
}

$Items = @(Get-Content -LiteralPath $State -Raw | ConvertFrom-Json)
$Remaining = @()
$Failed = $false

foreach ($Item in $Items) {
  if ($Name -and $Item.name -ne $Name) {
    $Remaining += $Item
    continue
  }
  $TrackedPid = 0
  if (-not $Item.pid -or -not [int]::TryParse("$($Item.pid)", [ref]$TrackedPid) -or $TrackedPid -le 1) {
    $Remaining += $Item
    $Failed = $true
    continue
  }
  $CurrentStart = $null
  try { $CurrentStart = Get-ProcessStartIdentity $TrackedPid } catch { $Remaining += $Item; $Failed = $true; continue }
  if (-not $CurrentStart) { continue }
  $RecordedStart = if ($Item.startedAt -is [DateTime]) { $Item.startedAt.ToUniversalTime().ToString("O") } else { [string]$Item.startedAt }
  if (-not $RecordedStart) { $Remaining += $Item; $Failed = $true; continue }
  if ($CurrentStart -ne $RecordedStart) { continue }
  if ($ProtectedPids.ContainsKey($TrackedPid)) { $Remaining += $Item; $Failed = $true; continue }
  if (-not (Stop-ExactProcessTree -ProcessId $TrackedPid -ExpectedStart $RecordedStart)) {
    $Remaining += $Item
    $Failed = $true
  }
}

if ($Remaining.Count -gt 0) {
  @($Remaining) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $NextState
  Move-Item -Force -LiteralPath $NextState -Destination $State
} else {
  Remove-Item -LiteralPath $State -Force -ErrorAction SilentlyContinue
}

if ($Failed) { exit 1 }
exit 0
