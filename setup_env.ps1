$ErrorActionPreference = 'Stop'

$ProjectRoot = $PSScriptRoot
$VenvDir = Join-Path $ProjectRoot '.venv'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
$Requirements = Join-Path $ProjectRoot 'requirements.txt'

function Write-Section {
    param([Parameter(Mandatory = $true)] [string] $Message)
    Write-Host ""
    Write-Host "== $Message =="
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,
        [string[]] $Arguments = @()
    )

    try {
        $null = & $Command @Arguments 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Get-SupportedFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Directory,
        [Parameter(Mandatory = $true)]
        [string[]] $Extensions
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
            Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() }
    )
}

Write-Section "Project"
Write-Host "Project root: $ProjectRoot"

Write-Section "Python"
$UsePyLauncher = $false
if (Test-CommandAvailable -Command 'py' -Arguments @('-3.12', '--version')) {
    $UsePyLauncher = $true
    Write-Host "Using Python launcher: py -3.12"
} elseif (Test-CommandAvailable -Command 'python' -Arguments @('--version')) {
    Write-Host "Using Python command: python"
} else {
    Write-Host "Python was not found. Please install Python 3.12, then run this script again." -ForegroundColor Red
    exit 1
}

Write-Section "Virtual environment"
if (Test-Path -LiteralPath $VenvDir) {
    $resolvedProject = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $resolvedVenv = (Resolve-Path -LiteralPath $VenvDir).Path
    if (-not $resolvedVenv.StartsWith($resolvedProject, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "Refusing to remove .venv outside project root: $resolvedVenv" -ForegroundColor Red
        exit 1
    }

    Write-Host "Removing existing .venv: $VenvDir"
    Remove-Item -LiteralPath $VenvDir -Recurse -Force
}

if ($UsePyLauncher) {
    & py -3.12 -m venv $VenvDir
} else {
    & python -m venv $VenvDir
}

if (-not (Test-Path -LiteralPath $VenvPython)) {
    Write-Host "Virtual environment Python was not created: $VenvPython" -ForegroundColor Red
    exit 1
}

Write-Host "Virtual environment ready: $VenvDir"

Write-Section "Dependencies"
if (-not (Test-Path -LiteralPath $Requirements)) {
    Write-Host "requirements.txt was not found: $Requirements" -ForegroundColor Red
    exit 1
}

& $VenvPython -m pip install --upgrade pip
& $VenvPython -m pip install -r $Requirements

Write-Section "Assets"
$ImageExtensions = @('.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif')
$AudioExtensions = @('.ogg', '.wav', '.mp3', '.flac')
$PictureDir = Join-Path $ProjectRoot 'suisen_picture'
$VoiceDir = Join-Path $ProjectRoot 'suisen_voice'
$FinishVoiceDir = Join-Path $ProjectRoot 'finish_voice'

foreach ($directory in @($PictureDir, $VoiceDir, $FinishVoiceDir)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$Images = @(Get-SupportedFiles -Directory $PictureDir -Extensions $ImageExtensions)
if ($Images.Count -gt 0) {
    Write-Host "[OK] images: $($Images.Count)"
} else {
    Write-Host "[Missing] images: put supported image files in suisen_picture" -ForegroundColor Yellow
    Write-Host "          supported: $($ImageExtensions -join ', ')"
}

$AskVoices = @(Get-SupportedFiles -Directory $VoiceDir -Extensions $AudioExtensions)
if ($AskVoices.Count -gt 0) {
    Write-Host "[OK] ask voices: $($AskVoices.Count)"
} else {
    Write-Host "[Missing] ask voices: put supported audio files in suisen_voice" -ForegroundColor Yellow
    Write-Host "          supported: $($AudioExtensions -join ', ')"
}

$FinishVoices = @(Get-SupportedFiles -Directory $FinishVoiceDir -Extensions $AudioExtensions)
if ($FinishVoices.Count -gt 0) {
    Write-Host "[OK] finish voices: $($FinishVoices.Count)"
} else {
    Write-Host "[Missing] finish voices: put supported audio files in finish_voice" -ForegroundColor Yellow
    Write-Host "          supported: $($AudioExtensions -join ', ')"
}

Write-Section "Next steps"
Write-Host "Manual window test:"
Write-Host "  & '$VenvPython' '$(Join-Path $ProjectRoot 'suisen_pet\pet.py')'"
Write-Host "  & '$VenvPython' '$(Join-Path $ProjectRoot 'suisen_pet\suisen_cli.py')' show test"
Write-Host ""
Write-Host "Install Claude Code hooks:"
Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$(Join-Path $ProjectRoot 'suisen_pet\install_claude_hooks.ps1')'"
