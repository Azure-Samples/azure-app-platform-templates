param(
  [Parameter(Mandatory = $true)][string] $Name,
  [Parameter(Mandatory = $true)][string] $Path,
  [Parameter(Mandatory = $true)][int] $Port,
  [Parameter(Mandatory = $true)][string] $RunDir,
  [switch] $Clean
)

$ErrorActionPreference = "Stop"

if ($Port -lt 1024 -or $Port -gt 65535) {
  [Console]::Error.WriteLine("[$Name] Skill port must be an integer from 1024 to 65535.")
  exit 1
}

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
  [Console]::Error.WriteLine("[$Name] MCP skill directory does not exist: $Path")
  exit 1
}

$UvCommand = Get-Command uv -ErrorAction SilentlyContinue
if (-not $UvCommand) {
  [Console]::Error.WriteLine("[$Name] uv is required to start MCP Hosted Skills. Install uv and retry.")
  exit 1
}

function Resolve-FuncCommand {
  $userFunc = Join-Path $HOME ".azure-functions\func.exe"
  if (Test-Path -LiteralPath $userFunc) {
    return $userFunc
  }
  foreach ($candidateName in @("func.cmd", "func.exe", "func")) {
    $cmd = Get-Command $candidateName -All -ErrorAction SilentlyContinue
    foreach ($entry in @($cmd)) {
      if (-not $entry -or -not $entry.Source) { continue }
      $src = [string]$entry.Source
      if ($src -like "*\Azure Functions Core Tools\func.exe") {
        $kvDll = Join-Path (Split-Path -Parent $src) "Azure.Security.KeyVault.Secrets.dll"
        if (-not (Test-Path -LiteralPath $kvDll)) { continue }
      }
      return $src
    }
  }
  return $null
}

$FuncCommand = Resolve-FuncCommand
if (-not $FuncCommand) {
  [Console]::Error.WriteLine("[$Name] Azure Functions Core Tools ('func') is required to start MCP Hosted Skills. Install Azure Functions Core Tools v4 and retry.")
  exit 1
}

$IndexUrl = if ($env:PIP_INDEX_URL) { $env:PIP_INDEX_URL } elseif ($env:UV_INDEX_URL) { $env:UV_INDEX_URL } else { $env:UV_DEFAULT_INDEX }
if (-not $IndexUrl -and (Get-Command python -ErrorAction SilentlyContinue)) {
  $ConfiguredIndex = & python -m pip config get global.index-url 2>$null
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ConfiguredIndex)) {
    $IndexUrl = $ConfiguredIndex.Trim()
  }
}
if ($IndexUrl) {
  $env:PIP_INDEX_URL = $env:UV_INDEX_URL = $env:UV_DEFAULT_INDEX = $IndexUrl
}

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$StateFile = Join-Path $RunDir "processes.json"

$Listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($Listening) {
  [Console]::Error.WriteLine("[$Name] cannot start: port $Port is already in use.")
  exit 1
}

$SettingsPath = Join-Path $Path "local.settings.json"
$SettingsExample = Join-Path $Path "local.settings.json.example"
if (-not (Test-Path -LiteralPath $SettingsPath) -and (Test-Path -LiteralPath $SettingsExample)) {
  Copy-Item -LiteralPath $SettingsExample -Destination $SettingsPath
}

$ForceClean = $Clean.IsPresent -or ($env:FORCE_CLEAN -eq "1")
if ($ForceClean -and (Test-Path -LiteralPath (Join-Path $Path ".venv"))) {
  Remove-Item -Recurse -Force -LiteralPath (Join-Path $Path ".venv")
}

function Read-ProcessRecords {
  if (-not (Test-Path -LiteralPath $StateFile)) { return @() }
  $raw = Get-Content -LiteralPath $StateFile -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  return @($raw | ConvertFrom-Json)
}

function Write-ProcessRecords([object[]] $Records) {
  if ($Records.Count -eq 0) {
    Set-Content -LiteralPath $StateFile -Value "[]"
  } else {
    @($Records) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile
  }
}

function Test-McpInitializeBody([string] $Body) {
  if ([string]::IsNullOrWhiteSpace($Body)) { return $false }
  if ($Body.Contains('"result"') -and $Body.Contains('"protocolVersion"')) {
    try {
      $trimmed = $Body.Trim()
      if ($trimmed.StartsWith("{")) {
        $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
        return ($null -ne $parsed.result -and -not [string]::IsNullOrWhiteSpace([string]$parsed.result.protocolVersion))
      }
      foreach ($line in ($trimmed -split "`r?`n")) {
        if ($line.StartsWith("data:")) {
          $jsonPart = $line.Substring(5).Trim()
          if ($jsonPart) {
            $parsed = $jsonPart | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed.result -and -not [string]::IsNullOrWhiteSpace([string]$parsed.result.protocolVersion)) {
              return $true
            }
          }
        }
      }
    } catch {
      return $false
    }
  }
  return $false
}

$McpUrl = "http://127.0.0.1:$Port/runtime/webhooks/mcp"
$McpInitBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"app-platform-readiness","version":"0.1.0"}}}'
$StopScript = Join-Path $PSScriptRoot "mcp-skill-stop.ps1"
$FuncVersionOut = (& $FuncCommand --version 2>$null | Out-String).Trim()
$IsFuncV5 = $FuncVersionOut.StartsWith("5.")

function Invoke-McpInitializeProbe([string] $Url, [string] $Payload) {
  $Client = [System.Net.Http.HttpClient]::new()
  $Client.Timeout = [TimeSpan]::FromSeconds(2)
  try {
    $Req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Url)
    $Req.Headers.Accept.ParseAdd("application/json")
    $Req.Headers.Accept.ParseAdd("text/event-stream")
    $Req.Content = [System.Net.Http.StringContent]::new($Payload, [System.Text.Encoding]::UTF8, "application/json")
    $Resp = $Client.SendAsync($Req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $Status = [int]$Resp.StatusCode
    if ($Status -ne 200) {
      return @{ StatusCode = $Status; Body = "" }
    }
    $MediaType = if ($Resp.Content.Headers.ContentType) { [string]$Resp.Content.Headers.ContentType.MediaType } else { "" }
    $Stream = $Resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $Reader = [System.IO.StreamReader]::new($Stream, [System.Text.Encoding]::UTF8)
    try {
      if ($MediaType -eq "text/event-stream") {
        $Builder = [System.Text.StringBuilder]::new()
        while ($true) {
          $Line = $Reader.ReadLine()
          if ($null -eq $Line) { break }
          [void]$Builder.AppendLine($Line)
          if ($Line -eq "" -and $Builder.Length -gt 0) {
            break
          }
        }
        return @{ StatusCode = $Status; Body = $Builder.ToString() }
      }
      return @{ StatusCode = $Status; Body = $Reader.ReadToEnd() }
    } finally {
      $Reader.Dispose()
      $Stream.Dispose()
      $Resp.Dispose()
    }
  } finally {
    $Client.Dispose()
  }
}

if (Test-Path -LiteralPath (Join-Path $Path "pyproject.toml")) {
  $PrevVenv = [Environment]::GetEnvironmentVariable("VIRTUAL_ENV", "Process")
  try {
    [Environment]::SetEnvironmentVariable("VIRTUAL_ENV", $null, "Process")
    Push-Location $Path
    try {
      & $UvCommand.Source sync
      if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("[$Name] uv sync failed.")
        exit 1
      }
    } finally {
      Pop-Location
    }
  } finally {
    [Environment]::SetEnvironmentVariable("VIRTUAL_ENV", $PrevVenv, "Process")
  }
}

$ReqPath = Join-Path $Path "requirements.txt"
$ReqStashPath = Join-Path $Path ".requirements.azd.bak"
function Restore-StashedRequirements {
  if ((Test-Path -LiteralPath $ReqStashPath) -and -not (Test-Path -LiteralPath $ReqPath)) {
    Move-Item -Force -LiteralPath $ReqStashPath -Destination $ReqPath
  }
}

for ($Attempt = 1; $Attempt -le 2; $Attempt++) {
  $OutLog = Join-Path $RunDir "$Name.log"
  $ErrLog = Join-Path $RunDir "$Name.err.log"
  $ExtraFuncFlags = if ($IsFuncV5) { @("--no-tui", "--no-azurite", "--offline") } else { @() }
  $SkillArgs = if (Test-Path -LiteralPath (Join-Path $Path "pyproject.toml")) {
    @("run", "--no-sync", $FuncCommand, "start", "--port", "$Port") + $ExtraFuncFlags
  } else {
    @("run", "--with-requirements", "requirements.txt", $FuncCommand, "start", "--port", "$Port") + $ExtraFuncFlags
  }

  $PrevVirtualEnv = [Environment]::GetEnvironmentVariable("VIRTUAL_ENV", "Process")
  $PrevWorkerRuntime = [Environment]::GetEnvironmentVariable("FUNCTIONS_WORKER_RUNTIME", "Process")
  $PrevTemp = [Environment]::GetEnvironmentVariable("TEMP", "Process")
  $PrevTmp = [Environment]::GetEnvironmentVariable("TMP", "Process")
  $SkillTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("app-plat-mcp-" + $Name + "-" + $Port)
  New-Item -ItemType Directory -Force -Path $SkillTemp | Out-Null

  try {
    [Environment]::SetEnvironmentVariable("VIRTUAL_ENV", $null, "Process")
    if (-not (Test-Path -LiteralPath $SettingsPath) -and -not $PrevWorkerRuntime) {
      [Environment]::SetEnvironmentVariable("FUNCTIONS_WORKER_RUNTIME", "python", "Process")
    }
    [Environment]::SetEnvironmentVariable("TEMP", $SkillTemp, "Process")
    [Environment]::SetEnvironmentVariable("TMP", $SkillTemp, "Process")
    if ($IsFuncV5 -and (Test-Path -LiteralPath (Join-Path $Path "pyproject.toml")) -and (Test-Path -LiteralPath $ReqPath)) {
      Move-Item -Force -LiteralPath $ReqPath -Destination $ReqStashPath
    }
    $Proc = Start-Process -FilePath $UvCommand.Source `
      -ArgumentList $SkillArgs `
      -WorkingDirectory $Path `
      -WindowStyle Hidden `
      -RedirectStandardOutput $OutLog `
      -RedirectStandardError $ErrLog `
      -PassThru
  } finally {
    [Environment]::SetEnvironmentVariable("VIRTUAL_ENV", $PrevVirtualEnv, "Process")
    [Environment]::SetEnvironmentVariable("FUNCTIONS_WORKER_RUNTIME", $PrevWorkerRuntime, "Process")
    [Environment]::SetEnvironmentVariable("TEMP", $PrevTemp, "Process")
    [Environment]::SetEnvironmentVariable("TMP", $PrevTmp, "Process")
  }

  $Records = @(Read-ProcessRecords | Where-Object { $_.name -ne $Name })
  $StartedAt = $null
  try {
    $StartedAt = $Proc.StartTime.ToUniversalTime().ToString("O")
  } catch {
    [Console]::Error.WriteLine("[$Name] Could not record process identity for PID $($Proc.Id).")
    exit 1
  }
  $Records += [pscustomobject]@{
    name      = $Name
    port      = $Port
    pid       = $Proc.Id
    startedAt = $StartedAt
  }
  Write-ProcessRecords $Records

  $Deadline = (Get-Date).AddSeconds(90)
  $LastError = "No MCP response."
  $RetryTransient = $false

  while ((Get-Date) -lt $Deadline) {
    if ($Proc.HasExited) {
      if (
        $Attempt -eq 1 -and (Test-Path -LiteralPath $ErrLog) -and
        (Select-String -LiteralPath $ErrLog -SimpleMatch "Value cannot be null. (Parameter 'provider')" -Quiet)
      ) {
        $Cleaned = @(Read-ProcessRecords | Where-Object { $_.pid -ne $Proc.Id })
        Write-ProcessRecords $Cleaned
        Write-Warning "[$Name] Azure Functions Core Tools reported a transient provider error. Retrying once."
        $RetryTransient = $true
        break
      }
      $ErrTail = if (Test-Path -LiteralPath $ErrLog) { (Get-Content -LiteralPath $ErrLog -Tail 30) -join "`n" } else { "" }
      $OutTail = if (Test-Path -LiteralPath $OutLog) { (Get-Content -LiteralPath $OutLog -Tail 30) -join "`n" } else { "" }
      Restore-StashedRequirements
      & $StopScript -RunDir $RunDir -Name $Name | Out-Null
      [Console]::Error.WriteLine("[$Name] MCP skill exited before becoming ready on port $Port.`n$OutTail`n$ErrTail")
      exit 1
    }

    try {
      $Probe = Invoke-McpInitializeProbe -Url $McpUrl -Payload $McpInitBody
      if ($Probe.StatusCode -eq 200 -and (Test-McpInitializeBody ([string]$Probe.Body))) {
        Restore-StashedRequirements
        Write-Host "[$Name] MCP READY at $McpUrl"
        exit 0
      }
      $LastError = "HTTP $($Probe.StatusCode)"
    } catch {
      $LastError = $_.Exception.Message
    }

    Start-Sleep -Milliseconds 150
  }

  if (-not $RetryTransient) {
    Restore-StashedRequirements
    & $StopScript -RunDir $RunDir -Name $Name | Out-Null
    [Console]::Error.WriteLine("[$Name] timed out waiting for MCP initialize at $McpUrl ($LastError).")
    exit 1
  }
}

Restore-StashedRequirements
[Console]::Error.WriteLine("[$Name] failed to start MCP skill on port $Port.")
exit 1
