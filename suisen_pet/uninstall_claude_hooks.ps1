$ErrorActionPreference = 'Stop'

$PetDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PetDir
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$HookScript = Join-Path $PetDir 'claude_hook.ps1'

function Test-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    return $null -ne ($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [AllowNull()]
        [object] $Value
    )

    if (Test-JsonProperty -Object $Object -Name $Name) {
        $Object.$Name = $Value
    } else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Get-ArrayOrEmpty {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [array]) {
        return @($Value)
    }

    return @($Value)
}

function Test-IsSuisenHook {
    param([AllowNull()] [object] $Hook)

    if ($null -eq $Hook -or $null -eq $Hook.command) {
        return $false
    }

    $command = [string] $Hook.command
    return (
        $command.IndexOf('claude_hook.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $command.IndexOf('suisen_pet', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    Write-Host "Claude Code settings.json was not found: $SettingsPath"
    Write-Host "No suisen hooks were removed."
    exit 0
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupPath = Join-Path $ClaudeDir "settings.backup.suisen_$timestamp.json"
Copy-Item -LiteralPath $SettingsPath -Destination $backupPath -Force

$raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Host "settings.json is empty. Backup was created, no suisen hooks were found."
    Write-Host "settings.json: $SettingsPath"
    Write-Host "backup: $backupPath"
    exit 0
}

try {
    $settings = $raw | ConvertFrom-Json
} catch {
    Write-Host "settings.json is not valid JSON. Backup was created, no changes were written." -ForegroundColor Red
    Write-Host "settings.json: $SettingsPath"
    Write-Host "backup: $backupPath"
    exit 1
}

if (
    -not (Test-JsonProperty -Object $settings -Name 'hooks') -or
    $null -eq $settings.hooks
) {
    Write-Host "No Claude Code hooks were found."
    Write-Host "settings.json: $SettingsPath"
    Write-Host "backup: $backupPath"
    exit 0
}

$removed = 0
$eventNames = @($settings.hooks.PSObject.Properties | ForEach-Object { $_.Name })

foreach ($eventName in $eventNames) {
    $entries = Get-ArrayOrEmpty $settings.hooks.$eventName
    $remainingEntries = @()

    foreach ($entry in $entries) {
        if ($null -eq $entry -or -not (Test-JsonProperty -Object $entry -Name 'hooks')) {
            $remainingEntries += $entry
            continue
        }

        $hooks = Get-ArrayOrEmpty $entry.hooks
        $remainingHooks = @()

        foreach ($hook in $hooks) {
            if (Test-IsSuisenHook -Hook $hook) {
                $removed += 1
            } else {
                $remainingHooks += $hook
            }
        }

        if ($remainingHooks.Count -gt 0) {
            Set-JsonProperty -Object $entry -Name 'hooks' -Value $remainingHooks
            $remainingEntries += $entry
        } elseif ($hooks.Count -eq 0) {
            $remainingEntries += $entry
        }
    }

    Set-JsonProperty -Object $settings.hooks -Name $eventName -Value $remainingEntries
}

if ($removed -eq 0) {
    Write-Host "No suisen hooks were found."
    Write-Host "settings.json: $SettingsPath"
    Write-Host "backup: $backupPath"
    exit 0
}

$json = $settings | ConvertTo-Json -Depth 50
Set-Content -LiteralPath $SettingsPath -Value $json -Encoding UTF8

Write-Host "Claude Code settings.json: $SettingsPath"
Write-Host "Project root: $ProjectRoot"
Write-Host "HookScript: $HookScript"
Write-Host "Backup: $backupPath"
Write-Host "Removed suisen hooks: $removed"
