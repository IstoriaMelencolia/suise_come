param(
    [switch] $DelayedWorker,
    [string] $ExpectedTurnId,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $NotifyArgs
)

$ErrorActionPreference = 'Stop'
$ScriptArgs = @($args)

$FINISH_COOLDOWN_SECONDS = 20
$FINISH_DELAY_SECONDS = 10

$PetDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PetDir
$Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$Pythonw = Join-Path $ProjectRoot '.venv\Scripts\pythonw.exe'
$Pet = Join-Path $PetDir 'pet.py'
$Cli = Join-Path $PetDir 'suisen_cli.py'
$LogDir = Join-Path $PetDir 'logs'
$LogFile = Join-Path $LogDir 'codex_notify.log'
$StateFile = Join-Path $LogDir 'codex_notify_state.json'

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
}

function Write-CodexNotifyLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    Add-Content -LiteralPath $LogFile -Value "[$timestamp] $Message" -Encoding UTF8
}

function New-NotifyState {
    return [pscustomobject] [ordered] @{
        pending_turn_id = $null
        pending_thread_id = $null
        pending_timestamp = $null
        pending_cwd = $null
        last_triggered_turn_id = $null
        last_triggered_timestamp = $null
    }
}

function Read-NotifyState {
    $defaultState = New-NotifyState

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $defaultState
    }

    try {
        $rawState = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($rawState)) {
            return $defaultState
        }

        $state = $rawState | ConvertFrom-Json
    } catch {
        Write-CodexNotifyLog "state read failed; using empty state: $($_.Exception.Message)"
        return $defaultState
    }

    foreach ($property in $defaultState.PSObject.Properties.Name) {
        if ($null -eq $state.PSObject.Properties[$property]) {
            $state | Add-Member -NotePropertyName $property -NotePropertyValue $defaultState.$property
        }
    }

    return $state
}

function Write-NotifyState {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $State
    )

    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Get-NowStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-ElapsedSeconds {
    param(
        [string] $Timestamp
    )

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        return [double]::PositiveInfinity
    }

    $parsedTimestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Timestamp, [ref] $parsedTimestamp)) {
        return [double]::PositiveInfinity
    }

    return ([DateTimeOffset]::UtcNow - $parsedTimestamp.ToUniversalTime()).TotalSeconds
}

function Test-InCooldown {
    param(
        [pscustomobject] $State
    )

    $elapsedSeconds = Get-ElapsedSeconds -Timestamp ([string] $State.last_triggered_timestamp)
    if ($elapsedSeconds -lt $FINISH_COOLDOWN_SECONDS) {
        Write-CodexNotifyLog "skipped by cooldown: elapsed=$([math]::Round($elapsedSeconds, 3))s cooldown=${FINISH_COOLDOWN_SECONDS}s last_triggered_turn_id=$($State.last_triggered_turn_id)"
        return $true
    }

    return $false
}

function Get-PayloadText {
    param(
        [string[]] $PrimaryArgs,
        [object[]] $FallbackArgs
    )

    if ($PrimaryArgs -and $PrimaryArgs.Count -gt 0) {
        return ($PrimaryArgs -join ' ')
    }

    if ($FallbackArgs -and $FallbackArgs.Count -gt 0) {
        return ($FallbackArgs -join ' ')
    }

    try {
        if ([Console]::IsInputRedirected) {
            return [Console]::In.ReadToEnd()
        }
    } catch {
        Write-CodexNotifyLog "stdin read failed: $($_.Exception.Message)"
    }

    return ''
}

function Get-PayloadValue {
    param(
        [Parameter(Mandatory = $true)]
        $Payload,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $property = $Payload.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertFrom-NativeDequotedPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    $trimmed = $Text.Trim()
    if (-not ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}'))) {
        return $null
    }

    $body = $trimmed.Substring(1, $trimmed.Length - 2)
    $propertyNames = @(
        'type',
        'thread-id',
        'turn-id',
        'cwd',
        'client',
        'input-messages',
        'last-assistant-message'
    )
    $propertyPattern = ($propertyNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $parts = [regex]::Split($body, ",(?=(?:$propertyPattern):)")
    $values = [ordered] @{}

    foreach ($part in $parts) {
        $separatorIndex = $part.IndexOf(':')
        if ($separatorIndex -lt 1) {
            continue
        }

        $name = $part.Substring(0, $separatorIndex).Trim()
        if ($propertyNames -notcontains $name) {
            continue
        }

        $value = $part.Substring($separatorIndex + 1).Trim()
        if ($value -eq 'null') {
            $value = $null
        }

        $values[$name] = $value
    }

    if (-not $values.Contains('type')) {
        return $null
    }

    return [pscustomobject] $values
}

function Invoke-SuisenCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    if (-not (Test-Path -LiteralPath $Python)) {
        Write-CodexNotifyLog "python.exe not found: $Python"
        return @{
            ExitCode = 1
            Output = @("python.exe not found: $Python")
        }
    }

    if (-not (Test-Path -LiteralPath $Cli)) {
        Write-CodexNotifyLog "suisen_cli.py not found: $Cli"
        return @{
            ExitCode = 1
            Output = @("suisen_cli.py not found: $Cli")
        }
    }

    $cliArguments = @($Cli) + $Arguments
    Write-CodexNotifyLog "running suisen_cli.py: $Python $($cliArguments -join ' ')"

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Python @cliArguments 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($null -ne $output) {
        foreach ($line in $output) {
            Write-CodexNotifyLog "suisen_cli.py output: $line"
        }
    }

    Write-CodexNotifyLog "suisen_cli.py exit code: $exitCode"

    return @{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Test-PetRunning {
    $result = Invoke-SuisenCli -Arguments @('status')
    $running = ($result.ExitCode -eq 0)
    Write-CodexNotifyLog "pet.py running: $running"
    return $running
}

function Start-PetIfNeeded {
    $running = Test-PetRunning
    if ($running) {
        Write-CodexNotifyLog "pet.py already running; start skipped"
        return $true
    }

    if (-not (Test-Path -LiteralPath $Pet)) {
        Write-CodexNotifyLog "pet.py not found: $Pet"
        return $false
    }

    $launcher = $Pythonw
    if (-not (Test-Path -LiteralPath $launcher)) {
        $launcher = $Python
        Write-CodexNotifyLog "pythonw.exe not found; falling back to python.exe"
    }

    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-CodexNotifyLog "launcher not found: $launcher"
        return $false
    }

    Write-CodexNotifyLog "starting pet.py with launcher: $launcher"
    Start-Process -FilePath $launcher -ArgumentList @($Pet) -WorkingDirectory $ProjectRoot -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 1

    $runningAfterStart = Test-PetRunning
    Write-CodexNotifyLog "pet.py started by notify: $runningAfterStart"
    return $runningAfterStart
}

function Quote-ProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-DelayedFinishWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TurnId
    )

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Quote-ProcessArgument -Value $scriptPath),
        '-DelayedWorker',
        '-ExpectedTurnId',
        (Quote-ProcessArgument -Value $TurnId)
    )

    Write-CodexNotifyLog "starting delayed finish worker: turn-id=$TurnId delay=${FINISH_DELAY_SECONDS}s"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -WorkingDirectory $ProjectRoot -WindowStyle Hidden | Out-Null
}

function Invoke-DelayedFinish {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TurnId
    )

    Write-CodexNotifyLog "delayed worker started: expected_turn_id=$TurnId delay=${FINISH_DELAY_SECONDS}s"
    Start-Sleep -Seconds $FINISH_DELAY_SECONDS

    $state = Read-NotifyState
    Write-CodexNotifyLog "delayed worker state check: expected_turn_id=$TurnId pending_turn_id=$($state.pending_turn_id) last_triggered_turn_id=$($state.last_triggered_turn_id)"

    if ([string] $state.pending_turn_id -ne $TurnId) {
        Write-CodexNotifyLog "delayed worker skipped: pending turn changed"
        return
    }

    if ([string] $state.last_triggered_turn_id -eq $TurnId) {
        Write-CodexNotifyLog "delayed worker skipped duplicate turn-id: $TurnId"
        return
    }

    if (Test-InCooldown -State $state) {
        return
    }

    if (-not (Start-PetIfNeeded)) {
        Write-CodexNotifyLog "delayed worker skipped: pet.py could not be started"
        return
    }

    Write-CodexNotifyLog "delayed worker invoking show finish: turn-id=$TurnId"
    $result = Invoke-SuisenCli -Arguments @('show', 'finish')

    if ($result.ExitCode -eq 0) {
        $state = Read-NotifyState
        if ([string] $state.pending_turn_id -eq $TurnId) {
            $state.pending_turn_id = $null
            $state.pending_thread_id = $null
            $state.pending_timestamp = $null
            $state.pending_cwd = $null
        }

        $state.last_triggered_turn_id = $TurnId
        $state.last_triggered_timestamp = Get-NowStamp
        Write-NotifyState -State $state
        Write-CodexNotifyLog "finish triggered successfully: turn-id=$TurnId"
    } else {
        Write-CodexNotifyLog "finish trigger failed; state not marked successful: turn-id=$TurnId exit_code=$($result.ExitCode)"
    }
}

try {
    Initialize-Log

    if ($DelayedWorker) {
        Write-CodexNotifyLog "codex_notify.ps1 delayed worker mode"
        if ([string]::IsNullOrWhiteSpace($ExpectedTurnId)) {
            Write-CodexNotifyLog "delayed worker skipped: ExpectedTurnId is empty"
        } else {
            Invoke-DelayedFinish -TurnId $ExpectedTurnId
        }

        exit 0
    }

    Write-CodexNotifyLog "codex_notify.ps1 started"
    Write-CodexNotifyLog "NotifyArgs count: $(@($NotifyArgs).Count)"
    Write-CodexNotifyLog "args count: $($ScriptArgs.Count)"

    $payloadText = Get-PayloadText -PrimaryArgs $NotifyArgs -FallbackArgs $ScriptArgs
    Write-CodexNotifyLog "raw payload: $payloadText"
    if ([string]::IsNullOrWhiteSpace($payloadText)) {
        Write-CodexNotifyLog "skipped: empty Codex notify payload"
        exit 0
    }

    try {
        $payload = $payloadText | ConvertFrom-Json
    } catch {
        Write-CodexNotifyLog "standard JSON parse failed: $($_.Exception.Message)"
        $payload = ConvertFrom-NativeDequotedPayload -Text $payloadText
        if ($null -eq $payload) {
            Write-CodexNotifyLog "skipped: failed to parse Codex notify payload"
            exit 0
        }

        Write-CodexNotifyLog "parsed payload using Windows PowerShell dequoted-argument compatibility"
    }

    $eventType = [string] (Get-PayloadValue -Payload $payload -Name 'type')
    $threadId = [string] (Get-PayloadValue -Payload $payload -Name 'thread-id')
    $turnId = [string] (Get-PayloadValue -Payload $payload -Name 'turn-id')
    $cwd = [string] (Get-PayloadValue -Payload $payload -Name 'cwd')
    $client = [string] (Get-PayloadValue -Payload $payload -Name 'client')
    $lastAssistantMessage = Get-PayloadValue -Payload $payload -Name 'last-assistant-message'
    $lastAssistantMessageEmpty = ($null -eq $lastAssistantMessage) -or [string]::IsNullOrWhiteSpace([string] $lastAssistantMessage)

    Write-CodexNotifyLog "payload type: $eventType"
    Write-CodexNotifyLog "payload thread-id: $threadId"
    Write-CodexNotifyLog "payload turn-id: $turnId"
    Write-CodexNotifyLog "payload cwd: $cwd"
    Write-CodexNotifyLog "payload client: $client"
    Write-CodexNotifyLog "payload last-assistant-message empty: $lastAssistantMessageEmpty"

    if ($eventType -ne 'agent-turn-complete') {
        Write-CodexNotifyLog "skipped: unsupported notify type '$eventType'"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($turnId)) {
        Write-CodexNotifyLog "skipped: missing turn-id"
        exit 0
    }

    $state = Read-NotifyState

    if ([string] $state.last_triggered_turn_id -eq $turnId) {
        Write-CodexNotifyLog "skipped duplicate turn-id: $turnId"
        exit 0
    }

    if (Test-InCooldown -State $state) {
        exit 0
    }

    $state.pending_turn_id = $turnId
    $state.pending_thread_id = $threadId
    $state.pending_timestamp = Get-NowStamp
    $state.pending_cwd = $cwd
    Write-NotifyState -State $state
    Write-CodexNotifyLog "pending finish recorded: turn-id=$turnId thread-id=$threadId cwd=$cwd"

    Start-DelayedFinishWorker -TurnId $turnId
} catch {
    try {
        Initialize-Log
        Write-CodexNotifyLog "error: $($_.Exception.Message)"
    } catch {
        # Codex notify must never be blocked by this helper.
    }
}

exit 0
