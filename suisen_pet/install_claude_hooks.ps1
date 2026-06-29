$ErrorActionPreference = 'Stop'

$PetDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PetDir
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$HookScript = Join-Path $PetDir 'claude_hook.ps1'
$EscapedHookScript = $HookScript -replace "'", "''"

$DesiredHooks = @(
    [pscustomobject]@{
        Event = 'SessionStart'
        Matcher = ''
        Label = 'SessionStart suisen start'
        Command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$EscapedHookScript' start"
    },
    [pscustomobject]@{
        Event = 'Notification'
        Matcher = 'permission_prompt'
        Label = 'Notification permission_prompt suisen ask'
        Command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$EscapedHookScript' ask"
    },
    [pscustomobject]@{
        Event = 'Notification'
        Matcher = 'idle_prompt'
        Label = 'Notification idle_prompt suisen finish'
        Command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$EscapedHookScript' finish"
    },
    [pscustomobject]@{
        Event = 'SessionEnd'
        Matcher = ''
        Label = 'SessionEnd suisen stop'
        Command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$EscapedHookScript' stop"
    }
)

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

function Remove-ExistingSuisenHooks {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    if (
        -not (Test-JsonProperty -Object $Settings -Name 'hooks') -or
        $null -eq $Settings.hooks
    ) {
        return 0
    }

    $removed = 0
    $eventNames = @($Settings.hooks.PSObject.Properties | ForEach-Object { $_.Name })

    foreach ($eventName in $eventNames) {
        $entries = Get-ArrayOrEmpty $Settings.hooks.$eventName
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

        Set-JsonProperty -Object $Settings.hooks -Name $eventName -Value $remainingEntries
    }

    return $removed
}

function Test-CommandExistsForEvent {
    param(
        [object[]] $Entries,
        [string] $Command
    )

    foreach ($entry in $Entries) {
        foreach ($hook in (Get-ArrayOrEmpty $entry.hooks)) {
            if ($hook.command -eq $Command) {
                return $true
            }
        }
    }

    return $false
}

function Add-Hook {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,
        [Parameter(Mandatory = $true)]
        [string] $Event,
        [AllowNull()]
        [string] $Matcher,
        [Parameter(Mandatory = $true)]
        [string] $Command
    )

    if (-not (Test-JsonProperty -Object $Settings.hooks -Name $Event) -or $null -eq $Settings.hooks.$Event) {
        Set-JsonProperty -Object $Settings.hooks -Name $Event -Value @()
    }

    $entries = Get-ArrayOrEmpty $Settings.hooks.$Event
    if (Test-CommandExistsForEvent -Entries $entries -Command $Command) {
        return 'already exists'
    }

    $matcherValue = if ($null -eq $Matcher) { '' } else { $Matcher }
    $target = $entries | Where-Object { $_.matcher -eq $matcherValue } | Select-Object -First 1

    if ($null -eq $target) {
        $target = [pscustomobject]@{
            matcher = $matcherValue
            hooks = @()
        }
        $entries = @($entries) + $target
    }

    $newHook = [pscustomobject]@{
        type = 'command'
        command = $Command
    }

    $existingHooks = Get-ArrayOrEmpty $target.hooks
    Set-JsonProperty -Object $target -Name 'hooks' -Value (@($existingHooks) + $newHook)
    Set-JsonProperty -Object $Settings.hooks -Name $Event -Value $entries

    return 'added'
}

if (-not (Test-Path -LiteralPath $ClaudeDir)) {
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
}

$backupPath = $null
$settings = [pscustomobject]@{}

if (Test-Path -LiteralPath $SettingsPath) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = Join-Path $ClaudeDir "settings.backup.suisen_$timestamp.json"
    Copy-Item -LiteralPath $SettingsPath -Destination $backupPath -Force

    $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $settings = $raw | ConvertFrom-Json
        } catch {
            Write-Host "settings.json exists but is not valid JSON. Backup was created, no changes were written." -ForegroundColor Red
            Write-Host "settings.json: $SettingsPath"
            Write-Host "backup: $backupPath"
            exit 1
        }
    }
}

if (-not (Test-JsonProperty -Object $settings -Name 'hooks') -or $null -eq $settings.hooks) {
    Set-JsonProperty -Object $settings -Name 'hooks' -Value ([pscustomobject]@{})
}

$removedOldHooks = Remove-ExistingSuisenHooks -Settings $settings
$changes = @()

foreach ($desiredHook in $DesiredHooks) {
    $status = Add-Hook -Settings $settings -Event $desiredHook.Event -Matcher $desiredHook.Matcher -Command $desiredHook.Command
    $changes += "$($desiredHook.Label): $status"
}

$json = $settings | ConvertTo-Json -Depth 50
Set-Content -LiteralPath $SettingsPath -Value $json -Encoding UTF8

Write-Host "Claude Code settings.json: $SettingsPath"
Write-Host "Project root: $ProjectRoot"
Write-Host "HookScript: $HookScript"
if ($null -ne $backupPath) {
    Write-Host "Backup: $backupPath"
} else {
    Write-Host "Backup: none (settings.json did not exist)"
}
Write-Host "Removed old suisen hooks: $removedOldHooks"
Write-Host "Hooks:"
foreach ($change in $changes) {
    Write-Host "  $change"
}
Write-Host "Open Claude Code and run /hooks to check:"
Write-Host "  SessionStart has suisen start"
Write-Host "  Notification permission_prompt has suisen ask"
Write-Host "  Notification idle_prompt has suisen finish"
Write-Host "  SessionEnd has suisen stop"
