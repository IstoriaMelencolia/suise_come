$ErrorActionPreference = 'Stop'

$PetDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PetDir
$CodexDir = Join-Path $env:USERPROFILE '.codex'
$HooksPath = Join-Path $CodexDir 'hooks.json'
$ConfigPath = Join-Path $CodexDir 'config.toml'
$CodexHookScript = Join-Path $PetDir 'codex_hook.ps1'
$CodexNotifyScript = Join-Path $PetDir 'codex_notify.ps1'
$PreviousNotifyPath = Join-Path $PetDir 'codex_notify_previous.json'
$EscapedCodexHookScript = $CodexHookScript -replace "'", "''"
$AskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$EscapedCodexHookScript' ask"
$AskCommandWindows = $AskCommand

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

function Test-AndDisableBrokenHooksJson {
    if (-not (Test-Path -LiteralPath $HooksPath)) {
        return @{
            Exists = $false
            Valid = $null
            Disabled = $false
            DisabledPath = $null
            Message = 'hooks.json not found; config.toml inline hooks will be used'
        }
    }

    $raw = Get-Content -LiteralPath $HooksPath -Raw -Encoding UTF8
    try {
        $null = $raw | ConvertFrom-Json
        return @{
            Exists = $true
            Valid = $true
            Disabled = $false
            DisabledPath = $null
            Message = 'hooks.json exists and is valid; suisen will not write to it'
        }
    } catch {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $disabledPath = Join-Path $CodexDir "hooks.disabled_suisen_$timestamp.json"
        Move-Item -LiteralPath $HooksPath -Destination $disabledPath -Force
        return @{
            Exists = $true
            Valid = $false
            Disabled = $true
            DisabledPath = $disabledPath
            Message = "hooks.json was invalid and has been disabled: $disabledPath"
        }
    }
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

function Install-CodexPermissionHook {
    if (-not (Test-Path -LiteralPath $CodexDir)) {
        New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null
    }

    $backupPath = $null
    $hooks = [pscustomobject]@{}

    if (Test-Path -LiteralPath $HooksPath) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupPath = Join-Path $CodexDir "hooks.backup.suisen_$timestamp.json"
        Copy-Item -LiteralPath $HooksPath -Destination $backupPath -Force

        $raw = Get-Content -LiteralPath $HooksPath -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $hooks = $raw | ConvertFrom-Json
            } catch {
                Write-Host "hooks.json exists but is not valid JSON. Backup was created, no hooks changes were written." -ForegroundColor Red
                Write-Host "hooks.json: $HooksPath"
                Write-Host "backup: $backupPath"
                return @{
                    Backup = $backupPath
                    Removed = 0
                    Added = $false
                    Error = 'invalid JSON'
                }
            }
        }
    }

    $removed = 0
    foreach ($property in @($hooks.PSObject.Properties)) {
        $result = Remove-SuisenHooksFromEventValue -Value $property.Value
        Set-JsonProperty -Object $hooks -Name $property.Name -Value $result.Entries
        $removed += [int] $result.Removed
    }

    $permissionHooks = @(Get-ArrayOrEmpty $(if (Test-JsonProperty -Object $hooks -Name 'PermissionRequest') { $hooks.PermissionRequest } else { $null }))
    $alreadyExists = $false
    foreach ($entry in $permissionHooks) {
        if ((Test-JsonProperty -Object $entry -Name 'command') -and $entry.command -eq $AskCommand) {
            $alreadyExists = $true
        }
        if ((Test-JsonProperty -Object $entry -Name 'commandWindows') -and $entry.commandWindows -eq $AskCommandWindows) {
            $alreadyExists = $true
        }
    }

    if (-not $alreadyExists) {
        $permissionHooks += [pscustomobject]@{
            matcher = '*'
            hooks = (New-JsonArray -Items @(
                [pscustomobject]@{
                    type = 'command'
                    command = $AskCommand
                    commandWindows = $AskCommandWindows
                    statusMessage = 'Suisen ask'
                }
            ))
        }
    }

    Set-JsonProperty -Object $hooks -Name 'PermissionRequest' -Value (New-JsonArray -Items $permissionHooks)
    Set-Content -LiteralPath $HooksPath -Value ($hooks | ConvertTo-Json -Depth 50) -Encoding UTF8

    return @{
        Backup = $backupPath
        Removed = $removed
        Added = (-not $alreadyExists)
        Error = $null
    }
}

function ConvertTo-TomlString {
    param([Parameter(Mandatory = $true)] [string] $Value)
    return '"' + ($Value.Replace('\', '\\').Replace('"', '\"')) + '"'
}

function ConvertTo-NotifyLine {
    param([Parameter(Mandatory = $true)] [string] $ScriptPath)
    $parts = @(
        'powershell.exe',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $ScriptPath
    )
    return 'notify = [' + (($parts | ForEach-Object { ConvertTo-TomlString $_ }) -join ', ') + ']'
}

function ConvertTo-NotifyBlockLines {
    param([Parameter(Mandatory = $true)] [string] $ScriptPath)

    return @(
        '# BEGIN suisen_pet Codex notify',
        (ConvertTo-NotifyLine -ScriptPath $ScriptPath),
        '# END suisen_pet Codex notify'
    )
}

function Insert-LinesBeforeFirstTable {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]] $Lines,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]] $InsertLines
    )

    $insertIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i += 1) {
        if ($Lines[$i] -match '^\s*\[') {
            $insertIndex = $i
            break
        }
    }

    if ($insertIndex -lt 0) {
        $merged = @($Lines)
        if ($merged.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($merged[-1])) {
            $merged += ''
        }
        $merged += $InsertLines
        return [string[]] $merged
    }

    if ($Lines[$insertIndex] -match '^\s*\[hooks\]\s*$') {
        $markerIndex = $insertIndex - 1
        while ($markerIndex -ge 0 -and [string]::IsNullOrWhiteSpace($Lines[$markerIndex])) {
            $markerIndex -= 1
        }
        if ($markerIndex -ge 0 -and $Lines[$markerIndex] -match '^\s*#\s*BEGIN suisen_pet Codex PermissionRequest hook') {
            $insertIndex = $markerIndex
        }
    }

    $before = @()
    if ($insertIndex -gt 0) {
        $before = @($Lines[0..($insertIndex - 1)])
    }
    if ($before.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($before[-1])) {
        $before += ''
    }
    $after = @($Lines[$insertIndex..($Lines.Count - 1)])
    return [string[]] @($before + $InsertLines + '' + $after)
}

function ConvertFrom-TomlArrayLine {
    param([Parameter(Mandatory = $true)] [string] $Line)

    $matches = [System.Text.RegularExpressions.Regex]::Matches($Line, '"((?:\\.|[^"\\])*)"')
    $values = @()
    foreach ($match in $matches) {
        $value = $match.Groups[1].Value
        $value = $value -replace '\\"', '"'
        $value = $value -replace '\\\\', '\'
        $values += $value
    }
    return $values
}

function Test-IsSuisenNotifyLine {
    param([Parameter(Mandatory = $true)] [string] $Line)
    return (
        $Line.IndexOf('codex_notify.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

function ConvertTo-InlinePermissionLines {
    param([bool] $IncludeHooksHeader)

    $lines = @('# BEGIN suisen_pet Codex PermissionRequest hook')
    if ($IncludeHooksHeader) {
        $lines += '[hooks]'
    }
    $lines += 'PermissionRequest = ['
    $lines += '  { matcher = "*", hooks = ['
    $lines += '    { type = "command", command = ' + (ConvertTo-TomlString $AskCommand) + ', commandWindows = ' + (ConvertTo-TomlString $AskCommandWindows) + ', statusMessage = "Suisen ask" },'
    $lines += '  ] },'
    $lines += ']'
    $lines += '# END suisen_pet Codex PermissionRequest hook'
    return $lines
}

function Remove-SuisenInlinePermissionBlocks {
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

    return @{
        Lines = [string[]] $outputLines
        Removed = $removed
    }
}

function Get-BracketDelta {
    param([Parameter(Mandatory = $true)] [string] $Line)

    $withoutComment = ($Line -split '#', 2)[0]
    $open = ([regex]::Matches($withoutComment, '\[')).Count
    $close = ([regex]::Matches($withoutComment, '\]')).Count
    return ($open - $close)
}

function Install-CodexInlinePermissionHook {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Lines)

    $cleanResult = Remove-SuisenInlinePermissionBlocks -Lines $Lines
    $workingLines = @($cleanResult.Lines)
    $hooksStart = -1
    $hooksEnd = $workingLines.Count
    $permissionStart = -1
    $permissionEnd = -1
    $warning = $null

    for ($i = 0; $i -lt $workingLines.Count; $i += 1) {
        if ($workingLines[$i] -match '^\s*\[hooks\]\s*$') {
            $hooksStart = $i
            break
        }
    }

    if ($hooksStart -ge 0) {
        for ($i = $hooksStart + 1; $i -lt $workingLines.Count; $i += 1) {
            if ($workingLines[$i] -match '^\s*\[') {
                $hooksEnd = $i
                break
            }
        }

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
    }

    $inlineLines = ConvertTo-InlinePermissionLines -IncludeHooksHeader:($hooksStart -lt 0)
    if ($hooksStart -ge 0) {
        $inlineLines = ConvertTo-InlinePermissionLines -IncludeHooksHeader:$false
    }

    if ($hooksStart -lt 0) {
        if ($workingLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($workingLines[-1])) {
            $workingLines += ''
        }
        $workingLines += $inlineLines
        return @{
            Lines = [string[]] $workingLines
            Added = $true
            Replaced = ($cleanResult.Removed -gt 0)
            RemovedOldBlocks = $cleanResult.Removed
            Warning = $null
        }
    }

    if ($permissionStart -lt 0) {
        $before = @()
        if ($hooksStart -ge 0) {
            $before = @($workingLines[0..$hooksStart])
        }
        $after = @()
        if (($hooksStart + 1) -le ($workingLines.Count - 1)) {
            $after = @($workingLines[($hooksStart + 1)..($workingLines.Count - 1)])
        }
        $merged = @($before + $inlineLines + $after)
        return @{
            Lines = [string[]] $merged
            Added = $true
            Replaced = ($cleanResult.Removed -gt 0)
            RemovedOldBlocks = $cleanResult.Removed
            Warning = $null
        }
    }

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
        $merged = @($before + $inlineLines + $after)
        return @{
            Lines = [string[]] $merged
            Added = $true
            Replaced = $true
            RemovedOldBlocks = $cleanResult.Removed
            Warning = $null
        }
    }

    $before = @()
    if ($permissionEnd -gt 0) {
        $before = @($workingLines[0..($permissionEnd - 1)])
    }
    $after = @()
    if ($permissionEnd -le ($workingLines.Count - 1)) {
        $after = @($workingLines[$permissionEnd..($workingLines.Count - 1)])
    }
    $suisenEntry = @(
        '  { matcher = "*", hooks = [',
        '    { type = "command", command = ' + (ConvertTo-TomlString $AskCommand) + ', commandWindows = ' + (ConvertTo-TomlString $AskCommandWindows) + ', statusMessage = "Suisen ask" },',
        '  ] },'
    )
    $merged = @($before + $suisenEntry + $after)
    return @{
        Lines = [string[]] $merged
        Added = $true
        Replaced = ($cleanResult.Removed -gt 0)
        RemovedOldBlocks = $cleanResult.Removed
        Warning = 'Existing non-suisen [hooks].PermissionRequest was preserved; suisen entry was appended.'
    }
}

function Get-SuisenInlinePermissionSnippet {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Lines)

    $insideSuisenBlock = $false
    $snippet = @()
    foreach ($line in $Lines) {
        if ($line -match '^\s*#\s*BEGIN suisen_pet Codex PermissionRequest hook') {
            $insideSuisenBlock = $true
        }

        if ($insideSuisenBlock) {
            $snippet += $line
        }

        if ($insideSuisenBlock -and $line -match '^\s*#\s*END suisen_pet Codex PermissionRequest hook') {
            break
        }
    }

    return ($snippet -join [Environment]::NewLine)
}

function Install-CodexNotify {
    if (-not (Test-Path -LiteralPath $CodexDir)) {
        New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null
    }

    $backupPath = $null
    $text = ''
    if (Test-Path -LiteralPath $ConfigPath) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupPath = Join-Path $CodexDir "config.backup.suisen_$timestamp.toml"
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
        $text = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    }

    $lines = @()
    if (-not [string]::IsNullOrEmpty($text)) {
        $lines = @($text -split "`r?`n")
    }

    $inlinePermissionResult = Install-CodexInlinePermissionHook -Lines ([string[]] $lines)
    $lines = @($inlinePermissionResult.Lines)

    $newNotifyBlock = ConvertTo-NotifyBlockLines -ScriptPath $CodexNotifyScript
    $outputLines = @()
    $removedSuisenNotify = 0
    $replacedNotify = $false
    $savedPreviousNotify = $false
    $insideSuisenBlock = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*#\s*BEGIN suisen_pet Codex notify') {
            $insideSuisenBlock = $true
            $removedSuisenNotify += 1
            continue
        }

        if ($insideSuisenBlock) {
            if ($line -match '^\s*#\s*END suisen_pet Codex notify') {
                $insideSuisenBlock = $false
            }
            continue
        }

        if ($line -match '^\s*notify\s*=') {
            if (Test-IsSuisenNotifyLine -Line $line) {
                $removedSuisenNotify += 1
                continue
            }

            $previousCommand = ConvertFrom-TomlArrayLine -Line $line
            if ($previousCommand.Count -gt 0) {
                [pscustomobject]@{
                    command = $previousCommand
                    captured_at = (Get-Date).ToString('o')
                    source = $ConfigPath
                } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PreviousNotifyPath -Encoding UTF8
                $savedPreviousNotify = $true
            }

            $outputLines += '# BEGIN suisen_pet Codex notify'
            $outputLines += $newNotifyBlock[1]
            $outputLines += '# END suisen_pet Codex notify'
            $replacedNotify = $true
            continue
        }

        $outputLines += $line
    }

    if (-not $replacedNotify) {
        $outputLines = @(Insert-LinesBeforeFirstTable -Lines ([string[]] $outputLines) -InsertLines ([string[]] $newNotifyBlock))
    }

    Set-Content -LiteralPath $ConfigPath -Value ($outputLines -join [Environment]::NewLine) -Encoding UTF8

    return @{
        Backup = $backupPath
        RemovedSuisenNotify = $removedSuisenNotify
        ReplacedExistingNotify = $replacedNotify
        SavedPreviousNotify = $savedPreviousNotify
        InlinePermissionAdded = $inlinePermissionResult.Added
        InlinePermissionReplaced = $inlinePermissionResult.Replaced
        InlinePermissionRemovedOldBlocks = $inlinePermissionResult.RemovedOldBlocks
        InlinePermissionWarning = $inlinePermissionResult.Warning
        InlinePermissionSnippet = (Get-SuisenInlinePermissionSnippet -Lines ([string[]] $outputLines))
    }
}

$hookResult = Test-AndDisableBrokenHooksJson
$notifyResult = Install-CodexNotify

Write-Host "Codex hooks.json: $HooksPath"
Write-Host "Codex config.toml: $ConfigPath"
Write-Host "codex_hook.ps1: $CodexHookScript"
Write-Host "codex_notify.ps1: $CodexNotifyScript"
Write-Host "hooks.json exists: $($hookResult.Exists)"
Write-Host "hooks.json valid: $($hookResult.Valid)"
Write-Host "hooks.json disabled: $($hookResult.Disabled)"
Write-Host "hooks.json disabled path: $($hookResult.DisabledPath)"
Write-Host "hooks.json message: $($hookResult.Message)"
Write-Host "config.toml backup: $($notifyResult.Backup)"
Write-Host "wrote notify -> codex_notify.ps1: True"
Write-Host "config.toml inline PermissionRequest hook written: $($notifyResult.InlinePermissionAdded)"
Write-Host "config.toml inline PermissionRequest hook replaced: $($notifyResult.InlinePermissionReplaced)"
Write-Host "config.toml inline PermissionRequest warning: $($notifyResult.InlinePermissionWarning)"
Write-Host "removed old suisen notify entries: $($notifyResult.RemovedSuisenNotify)"
Write-Host "existing notify preserved for chaining: $($notifyResult.SavedPreviousNotify)"
Write-Host "notify finish kept via config.toml: True"
Write-Host "Final config.toml suisen PermissionRequest snippet:"
Write-Host $notifyResult.InlinePermissionSnippet
Write-Host "Codex App now uses config.toml inline hooks for ask; hooks.json is not used by suisen."
Write-Host "Restart Codex App, then trigger a real PermissionRequest to test ask."
Write-Host "Finish uses Codex config.toml notify for agent-turn-complete via codex_notify.ps1."
Write-Host "If you move the project folder, run install_codex_integration.ps1 again from the new location."
