$ErrorActionPreference = 'Stop'

$PetDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PetDir
Set-Location -LiteralPath $ProjectRoot

$Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$PetPy = Join-Path $ProjectRoot 'suisen_pet\pet.py'
$CliPy = Join-Path $ProjectRoot 'suisen_pet\suisen_cli.py'
$PictureDir = Join-Path $ProjectRoot 'suisen_picture'
$VoiceDir = Join-Path $ProjectRoot 'suisen_voice'
$FinishVoiceDir = Join-Path $ProjectRoot 'finish_voice'
$ImageExtensions = @('.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif')
$AudioExtensions = @('.ogg', '.wav', '.mp3', '.flac')

$Failed = $false

function Test-RequiredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    if (Test-Path -LiteralPath $Path) {
        Write-Host "[OK] $Label`: $Path"
    } else {
        Write-Host "[Missing] $Label`: $Path" -ForegroundColor Red
        $script:Failed = $true
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

Test-RequiredPath -Path $Python -Label 'Python'
Test-RequiredPath -Path $PetPy -Label 'pet.py'
Test-RequiredPath -Path $CliPy -Label 'suisen_cli.py'
Test-RequiredPath -Path $FinishVoiceDir -Label 'finish voice directory'

$Images = @(Get-SupportedFiles -Directory $PictureDir -Extensions $ImageExtensions)
$AskVoices = @(Get-SupportedFiles -Directory $VoiceDir -Extensions $AudioExtensions)
$FinishVoices = @(Get-SupportedFiles -Directory $FinishVoiceDir -Extensions $AudioExtensions)

if ($Images.Count -gt 0) {
    Write-Host "[OK] image count: $($Images.Count)"
} else {
    Write-Host "[Missing] supported images in suisen_picture" -ForegroundColor Red
    $Failed = $true
}

if ($AskVoices.Count -gt 0) {
    Write-Host "[OK] ask audio count: $($AskVoices.Count)"
} else {
    Write-Host "[Warning] ask audio files were not found in suisen_voice" -ForegroundColor Yellow
    Write-Host "          show ask will still display the pet, but it will not play an ask voice."
}

if ($FinishVoices.Count -gt 0) {
    Write-Host "[OK] finish audio count: $($FinishVoices.Count)"
} else {
    Write-Host "[Warning] finish audio files were not found in $FinishVoiceDir" -ForegroundColor Yellow
    Write-Host "          show finish will still display the pet, but it will not play a finish voice."
}

if ($Failed) {
    Write-Host ""
    Write-Host "Some required files are missing. Please fix the paths above before testing." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Open PowerShell window 1 and start pet.py:"
Write-Host "  & '$Python' '$PetPy'"

Write-Host ""
Write-Host "Open PowerShell window 2 and run these manual checks:"
Write-Host "  & '$Python' '$CliPy' status"
Write-Host "  & '$Python' '$CliPy' show ask"
Write-Host "  & '$Python' '$CliPy' show finish"
Write-Host "  & '$Python' '$CliPy' hide"
