param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $RawArgs
)

$ErrorActionPreference = 'Stop'

$PetDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PetDir
$Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$Pythonw = Join-Path $ProjectRoot '.venv\Scripts\pythonw.exe'
$Pet = Join-Path $PetDir 'pet.py'
$Cli = Join-Path $PetDir 'suisen_cli.py'
$LogDir = Join-Path $PetDir 'logs'
$LogFile = Join-Path $LogDir 'codex_notify.log'

function Write-CodexNotifyLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    Add-Content -LiteralPath $LogFile -Value "[$timestamp] $Message" -Encoding UTF8
}

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
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

try {
    Initialize-Log
    Write-CodexNotifyLog "codex_notify.ps1 started for agent-turn-complete"
    Write-CodexNotifyLog "raw args: $($RawArgs -join ' ')"

    [void] (Start-PetIfNeeded)
    Write-CodexNotifyLog "invoking show finish"
    [void] (Invoke-SuisenCli -Arguments @('show', 'finish'))
} catch {
    try {
        Initialize-Log
        Write-CodexNotifyLog "error: $($_.Exception.Message)"
    } catch {
        # Codex notify must never be blocked by this helper.
    }
}

exit 0
