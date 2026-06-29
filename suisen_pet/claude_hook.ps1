param(
    [Parameter(Position = 0)]
    [string] $Mode
)

$ErrorActionPreference = 'Stop'

$PetDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PetDir
$Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$Pythonw = Join-Path $ProjectRoot '.venv\Scripts\pythonw.exe'
$Pet = Join-Path $PetDir 'pet.py'
$Cli = Join-Path $PetDir 'suisen_cli.py'
$LogDir = Join-Path $PetDir 'logs'
$LogFile = Join-Path $LogDir 'claude_hook.log'

function Write-HookLog {
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
        Write-HookLog "python.exe not found: $Python"
        return @{
            ExitCode = 1
            Output = @("python.exe not found: $Python")
        }
    }

    if (-not (Test-Path -LiteralPath $Cli)) {
        Write-HookLog "suisen_cli.py not found: $Cli"
        return @{
            ExitCode = 1
            Output = @("suisen_cli.py not found: $Cli")
        }
    }

    $cliArguments = @($Cli) + $Arguments
    Write-HookLog "running suisen_cli.py: $Python $($cliArguments -join ' ')"

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
            Write-HookLog "suisen_cli.py output: $line"
        }
    }

    Write-HookLog "suisen_cli.py exit code: $exitCode"

    return @{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Test-PetRunning {
    $result = Invoke-SuisenCli -Arguments @('status')
    $running = ($result.ExitCode -eq 0)
    Write-HookLog "pet.py running: $running"
    return $running
}

function Start-PetIfNeeded {
    $running = Test-PetRunning
    if ($running) {
        Write-HookLog "pet.py already running; start skipped"
        return $true
    }

    if (-not (Test-Path -LiteralPath $Pet)) {
        Write-HookLog "pet.py not found: $Pet"
        return $false
    }

    $launcher = $Pythonw
    if (-not (Test-Path -LiteralPath $launcher)) {
        $launcher = $Python
        Write-HookLog "pythonw.exe not found; falling back to python.exe"
    }

    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-HookLog "launcher not found: $launcher"
        return $false
    }

    Write-HookLog "starting pet.py with launcher: $launcher"
    Start-Process -FilePath $launcher -ArgumentList @($Pet) -WorkingDirectory $ProjectRoot -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 1

    $runningAfterStart = Test-PetRunning
    Write-HookLog "pet.py started by hook: $runningAfterStart"
    return $runningAfterStart
}

try {
    Initialize-Log
    Write-HookLog "claude_hook.ps1 started mode=$Mode"

    if ($Mode -notin @('start', 'ask', 'finish', 'stop')) {
        Write-HookLog "unsupported mode: $Mode"
        exit 0
    }

    switch ($Mode) {
        'start' {
            [void] (Start-PetIfNeeded)
            Write-HookLog "mode=start complete; no show command invoked"
        }

        'ask' {
            [void] (Start-PetIfNeeded)
            Write-HookLog "invoking show ask"
            [void] (Invoke-SuisenCli -Arguments @('show', 'ask'))
        }

        'finish' {
            [void] (Start-PetIfNeeded)
            Write-HookLog "invoking show finish"
            [void] (Invoke-SuisenCli -Arguments @('show', 'finish'))
        }

        'stop' {
            $running = Test-PetRunning
            if (-not $running) {
                Write-HookLog "pet.py is not running before stop; shutdown will still be attempted"
            }
            Write-HookLog "invoking shutdown"
            [void] (Invoke-SuisenCli -Arguments @('shutdown'))
        }
    }
} catch {
    try {
        Initialize-Log
        Write-HookLog "error: $($_.Exception.Message)"
    } catch {
        # Swallow all logging failures. Claude Code hooks must never be blocked by this helper.
    }
}

exit 0
