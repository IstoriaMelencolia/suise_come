param(
    [Parameter(Position = 0)]
    [string] $Mode,
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
$LogFile = Join-Path $LogDir 'codex_hook.log'

function Write-CodexHookLog {
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
        Write-CodexHookLog "python.exe not found: $Python"
        return @{
            ExitCode = 1
            Output = @("python.exe not found: $Python")
        }
    }
    Write-CodexHookLog "python.exe found: $Python"

    if (-not (Test-Path -LiteralPath $Cli)) {
        Write-CodexHookLog "suisen_cli.py not found: $Cli"
        return @{
            ExitCode = 1
            Output = @("suisen_cli.py not found: $Cli")
        }
    }

    $cliArguments = @($Cli) + $Arguments
    Write-CodexHookLog "running suisen_cli.py: $Python $($cliArguments -join ' ')"

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
            Write-CodexHookLog "suisen_cli.py output: $line"
        }
    }

    Write-CodexHookLog "suisen_cli.py exit code: $exitCode"

    return @{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Test-PetRunning {
    $result = Invoke-SuisenCli -Arguments @('status')
    $running = ($result.ExitCode -eq 0)
    Write-CodexHookLog "pet.py running: $running"
    return $running
}

function Start-PetIfNeeded {
    $running = Test-PetRunning
    if ($running) {
        Write-CodexHookLog "pet.py already running; start skipped"
        return $true
    }

    if (-not (Test-Path -LiteralPath $Pet)) {
        Write-CodexHookLog "pet.py not found: $Pet"
        return $false
    }

    $launcher = $Pythonw
    if (-not (Test-Path -LiteralPath $launcher)) {
        $launcher = $Python
        Write-CodexHookLog "pythonw.exe not found; falling back to python.exe"
    }

    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-CodexHookLog "launcher not found: $launcher"
        return $false
    }

    Write-CodexHookLog "starting pet.py with launcher: $launcher"
    Start-Process -FilePath $launcher -ArgumentList @($Pet) -WorkingDirectory $ProjectRoot -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 1

    $runningAfterStart = Test-PetRunning
    Write-CodexHookLog "pet.py started by hook: $runningAfterStart"
    return $runningAfterStart
}

try {
    Initialize-Log
    $allArgs = @($Mode) + @($RawArgs)
    Write-CodexHookLog "codex_hook.ps1 started mode=$Mode"
    Write-CodexHookLog "raw args: $($allArgs -join ' ')"
    Write-CodexHookLog "current directory: $((Get-Location).Path)"
    Write-CodexHookLog "python path: $Python"
    Write-CodexHookLog "python exists: $(Test-Path -LiteralPath $Python)"
    Write-CodexHookLog "pythonw path: $Pythonw"
    Write-CodexHookLog "pythonw exists: $(Test-Path -LiteralPath $Pythonw)"

    if ($Mode -notin @('start', 'ask', 'stop')) {
        Write-CodexHookLog "unsupported mode: $Mode"
        exit 0
    }

    switch ($Mode) {
        'start' {
            [void] (Start-PetIfNeeded)
            Write-CodexHookLog "mode=start complete; no show command invoked"
        }

        'ask' {
            [void] (Start-PetIfNeeded)
            Write-CodexHookLog "invoking show ask"
            [void] (Invoke-SuisenCli -Arguments @('show', 'ask'))
        }

        'stop' {
            $running = Test-PetRunning
            if (-not $running) {
                Write-CodexHookLog "pet.py is not running before stop; shutdown will still be attempted"
            }
            Write-CodexHookLog "invoking shutdown"
            [void] (Invoke-SuisenCli -Arguments @('shutdown'))
        }
    }
} catch {
    try {
        Initialize-Log
        Write-CodexHookLog "error: $($_.Exception.Message)"
    } catch {
        # Codex hooks must never be blocked by this helper.
    }
}

exit 0
