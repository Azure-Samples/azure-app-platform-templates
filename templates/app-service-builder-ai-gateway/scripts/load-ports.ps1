function Import-AppPorts([string] $AppRoot) {
  $Path = Join-Path $AppRoot ".azure-app-platform/ports.env"
  if (-not (Test-Path $Path)) { return }
  $Seen = @{}
  $Used = @{}
  foreach ($Line in Get-Content $Path) {
    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
    if ($Line -cnotmatch '^(AGENT_PORT|WEB_PORT|SKILL_PORT|SKILL_[A-Z0-9_]+_PORT|INVENTORY_SEARCH_PORT|TRADE_IN_VALUE_PORT|RATE_SHEET_PORT|DEAL_DOC_PORT|AZURITE_BLOB_PORT|AZURITE_QUEUE_PORT|AZURITE_TABLE_PORT)=([0-9]{4,5})$') {
      throw "Invalid port settings in .azure-app-platform/ports.env"
    }
    $Name = $Matches[1]
    $Port = [int]$Matches[2]
    if ($Port -lt 1024 -or $Port -gt 65535 -or $Seen.ContainsKey($Name) -or $Used.ContainsKey($Port)) {
      throw "Port settings must be unique integers from 1024 to 65535."
    }
    $Seen[$Name] = $true
    $Used[$Port] = $true
    Set-Item -Path "Env:$Name" -Value "$Port"
  }
}

function Get-SkillPortEnvName([string] $SkillName) {
  $Normalized = (($SkillName.ToUpperInvariant() -replace '[^A-Z0-9]+', '_').Trim('_'))
  return "SKILL_${Normalized}_PORT"
}

function Get-SkillPort([string] $SkillName, [int] $Index = 0, [bool] $SingleSkill = $true) {
  $EnvName = Get-SkillPortEnvName $SkillName
  $Candidate = [Environment]::GetEnvironmentVariable($EnvName, "Process")
  if ([string]::IsNullOrWhiteSpace($Candidate) -and $SingleSkill -and $Index -eq 0) {
    $Candidate = [Environment]::GetEnvironmentVariable("SKILL_PORT", "Process")
  }
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    return (7071 + $Index)
  }
  $Port = 0
  if (-not [int]::TryParse($Candidate.Trim(), [ref]$Port) -or $Port -lt 1024 -or $Port -gt 65535) {
    throw "$EnvName must be an integer from 1024 to 65535."
  }
  return $Port
}
