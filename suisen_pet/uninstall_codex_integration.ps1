$ErrorActionPreference = 'Stop'

$PetDir = $PSScriptRoot
$CodexDir = Join-Path $env:USERPROFILE '.codex'
$HooksPath = Join-Path $CodexDir 'hooks.json'
$ConfigPath = Join-Path $CodexDir 'config.toml'
$PreviousNotifyPath = Join-Path $PetDir 'codex_notify_previous.json'

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

function New-JsonArray {
    param([AllowNull()] [object[]] $Items)

    $list = [System.Collections.ArrayList]::new()
    foreach ($item in (Get-ArrayOrEmpty $Items)) {
        [void] $list.Add($item)
    }
    return ,$list
}

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

function Test-IsSuisenCommand {
    param([AllowNull()] [string] $Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $false
    }

    return (
        $Command.IndexOf('codex_hook.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $Command.IndexOf('codex_notify.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $Command.IndexOf('suisen_pet', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

function Remove-SuisenHooksFromEventValue {
    param([AllowNull()] [object] $Value)

    $removed = 0
    $remainingEntries = @()

    foreach ($entry in (Get-ArrayOrEmpty $Value)) {
        if ($null -eq $entry) {
            continue
        }

        if (
            ((Test-JsonProperty -Object $entry -Name 'command') -and (Test-IsSuisenCommand -Command ([string] $entry.command))) -or
            ((Test-JsonProperty -Object $entry -Name 'commandWindows') -and (Test-IsSuisenCommand -Command ([string] $entry.commandWindows)))
        ) {
            $removed += 1
            continue
        }

        if (Test-JsonProperty -Object $entry -Name 'hooks') {
            $remainingHooks = @()
            foreach ($hook in (Get-ArrayOrEmpty $entry.hooks)) {
                if (
                    ((Test-JsonProperty -Object $hook -Name 'command') -and (Test-IsSuisenCommand -Command ([string] $hook.command))) -or
                    ((Test-JsonProperty -Object $hook -Name 'commandWindows') -and (Test-IsSuisenCommand -Command ([string] $hook.commandWindows)))
                ) {
                    $removed += 1
                } else {
                    $remainingHooks += $hook
                }
            }
            Set-JsonProperty -Object $entry -Name 'hooks' -Value (New-JsonArray -Items $remainingHooks)
            if (
                $remainingHooks.Count -eq 0 -and
                -not (Test-JsonProperty -Object $entry -Name 'command') -and
                -not (Test-JsonProperty -Object $entry -Name 'commandWindows')
            ) {
                continue
            }
        }

        $remainingEntries += $entry
    }

    return @{
        Entries = (New-JsonArray -Items $remainingEntries)
        Removed = $removed
    }
}

function Uninstall-CodexHooks {
    if (-not (Test-Path -LiteralPath $HooksPath)) {
        return @{
            Backup = $null
            Removed = 0
            Message = 'hooks.json not found'
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = Join-Path $CodexDir "hooks.backup.suisen_$timestamp.json"
    Copy-Item -LiteralPath $HooksPath -Destination $backupPath -Force

    $raw = Get-Content -LiteralPath $HooksPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{
            Backup = $backupPath
            Removed = 0
            Message = 'hooks.json is empty'
        }
    }

    try {
        $hooks = $raw | ConvertFrom-Json
    } catch {
        return @{
            Backup = $backupPath
            Removed = 0
            Message = 'hooks.json is not valid JSON; no changes written'
        }
    }

    $removed = 0
    foreach ($property in @($hooks.PSObject.Properties)) {
        $result = Remove-SuisenHooksFromEventValue -Value $property.Value
        Set-JsonProperty -Object $hooks -Name $property.Name -Value $result.Entries
        $removed += [int] $result.Removed
    }

    if ($removed -gt 0) {
        Set-Content -LiteralPath $HooksPath -Value ($hooks | ConvertTo-Json -Depth 50) -Encoding UTF8
    }

    return @{
        Backup = $backupPath
        Removed = $removed
        Message = 'ok'
    }
}

function ConvertTo-TomlString {
    param([Parameter(Mandatory = $true)] [string] $Value)
    return '"' + ($Value.Replace('\', '\\').Replace('"', '\"')) + '"'
}

function ConvertTo-NotifyLineFromArray {
    param([Parameter(Mandatory = $true)] [string[]] $Command)
    return 'notify = [ ' + (($Command | ForEach-Object { ConvertTo-TomlString $_ }) -join ', ') + ' ]'
}

function Test-IsSuisenNotifyLine {
    param([Parameter(Mandatory = $true)] [string] $Line)
    return (
        $Line.IndexOf('codex_notify.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

function Get-BracketDelta {
    param([Parameter(Mandatory = $true)] [string] $Line)

    $withoutComment = ($Line -split '#', 2)[0]
    $open = ([regex]::Matches($withoutComment, '\[')).Count
    $close = ([regex]::Matches($withoutComment, '\]')).Count
    return ($open - $close)
}

function Remove-CodexInlinePermissionHook {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Lines)

    $outputLines = @()
    $insideSuisenBlock = $false
    $removed = 0

    foreach ($line in $Lines) {
        if ($line -match '^\s*#\s*BEGIN suisen_pet Codex PermissionRequest hook') {
            $insideSuisenBlock = $true
            $removed += 1
            continue
        }

        if ($insideSuisenBlock) {
            if ($line -match '^\s*#\s*END suisen_pet Codex PermissionRequest hook') {
                $insideSuisenBlock = $false
                continue
            }
            if ($line -match '^\s*\[' -and $line -notmatch '^\s*\[hooks\]\s*$') {
                $insideSuisenBlock = $false
                $outputLines += $line
                continue
            }
            continue
        }

        $outputLines += $line
    }

    $workingLines = @($outputLines)
    $hooksStart = -1
    $hooksEnd = $workingLines.Count
    for ($i = 0; $i -lt $workingLines.Count; $i += 1) {
        if ($workingLines[$i] -match '^\s*\[hooks\]\s*$') {
            $hooksStart = $i
            break
        }
    }

    if ($hooksStart -lt 0) {
        return @{
            Lines = [string[]] $workingLines
            Removed = $removed
        }
    }

    for ($i = $hooksStart + 1; $i -lt $workingLines.Count; $i += 1) {
        if ($workingLines[$i] -match '^\s*\[') {
            $hooksEnd = $i
            break
        }
    }

    $permissionStart = -1
    $permissionEnd = -1
    for ($i = $hooksStart + 1; $i -lt $hooksEnd; $i += 1) {
        if ($workingLines[$i] -match '^\s*PermissionRequest\s*=') {
            $permissionStart = $i
            $depth = 0
            for ($j = $i; $j -lt $hooksEnd; $j += 1) {
                $depth += Get-BracketDelta -Line $workingLines[$j]
                if ($depth -le 0) {
                    $permissionEnd = $j
                    break
                }
            }
            if ($permissionEnd -lt 0) {
                $permissionEnd = $i
            }
            break
        }
    }

    if ($permissionStart -ge 0) {
        $permissionBlock = ($workingLines[$permissionStart..$permissionEnd] -join [Environment]::NewLine)
        if ($permissionBlock.IndexOf('suisen_pet', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or $permissionBlock.IndexOf('codex_hook.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $before = @()
            if ($permissionStart -gt 0) {
                $before = @($workingLines[0..($permissionStart - 1)])
            }
            $after = @()
            if (($permissionEnd + 1) -le ($workingLines.Count - 1)) {
                $after = @($workingLines[($permissionEnd + 1)..($workingLines.Count - 1)])
            }
            $workingLines = @($before + $after)
            $removed += 1
        }
    }

    return @{
        Lines = [string[]] $workingLines
        Removed = $removed
    }
}

function Get-PreviousNotifyLine {
    if (-not (Test-Path -LiteralPath $PreviousNotifyPath)) {
        return $null
    }

    try {
        $previous = Get-Content -LiteralPath $PreviousNotifyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $command = @($previous.command)
        if ($command.Count -gt 0) {
            return ConvertTo-NotifyLineFromArray -Command $command
        }
    } catch {
        return $null
    }

    return $null
}

function Uninstall-CodexNotify {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return @{
            Backup = $null
            Removed = 0
            RestoredPrevious = $false
            Message = 'config.toml not found'
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = Join-Path $CodexDir "config.backup.suisen_$timestamp.toml"
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force

    $text = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $lines = @($text -split "`r?`n")
    $previousNotifyLine = Get-PreviousNotifyLine
    $restoredPrevious = $false
    $removed = 0
    $insideSuisenBlock = $false
    $outputLines = @()

    foreach ($line in $lines) {
        if ($line -match '^\s*#\s*BEGIN suisen_pet Codex notify') {
            $insideSuisenBlock = $true
            $removed += 1
            if ($null -ne $previousNotifyLine -and -not $restoredPrevious) {
                $outputLines += $previousNotifyLine
                $restoredPrevious = $true
            }
            continue
        }

        if ($insideSuisenBlock) {
            if ($line -match '^\s*#\s*END suisen_pet Codex notify') {
                $insideSuisenBlock = $false
            }
            continue
        }

        if ($line -match '^\s*notify\s*=' -and (Test-IsSuisenNotifyLine -Line $line)) {
            $removed += 1
            if ($null -ne $previousNotifyLine -and -not $restoredPrevious) {
                $outputLines += $previousNotifyLine
                $restoredPrevious = $true
            }
            continue
        }

        $outputLines += $line
    }

    $inlinePermissionResult = Remove-CodexInlinePermissionHook -Lines ([string[]] $outputLines)
    $outputLines = @($inlinePermissionResult.Lines)

    if ($removed -gt 0 -or $inlinePermissionResult.Removed -gt 0) {
        Set-Content -LiteralPath $ConfigPath -Value ($outputLines -join [Environment]::NewLine) -Encoding UTF8
    }

    return @{
        Backup = $backupPath
        Removed = $removed
        RemovedInlinePermission = $inlinePermissionResult.Removed
        RestoredPrevious = $restoredPrevious
        Message = 'ok'
    }
}

$notifyResult = Uninstall-CodexNotify

Write-Host "Codex config.toml: $ConfigPath"
Write-Host "Codex hooks.json: $HooksPath"
Write-Host "hooks.json unchanged by suisen uninstall: True"
Write-Host "config.toml backup: $($notifyResult.Backup)"
Write-Host "removed suisen notify entries: $($notifyResult.Removed)"
Write-Host "removed suisen inline PermissionRequest entries: $($notifyResult.RemovedInlinePermission)"
Write-Host "restored previous notify: $($notifyResult.RestoredPrevious)"
Write-Host "notify message: $($notifyResult.Message)"

if ($notifyResult.Removed -eq 0) {
    Write-Host "If a suisen notify line remains in config.toml, remove the block between:"
    Write-Host "  # BEGIN suisen_pet Codex notify"
    Write-Host "  # END suisen_pet Codex notify"
}
