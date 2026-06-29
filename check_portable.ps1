$ErrorActionPreference = 'Stop'

$ProjectRoot = $PSScriptRoot
$Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$PetPy = Join-Path $ProjectRoot 'suisen_pet\pet.py'
$CliPy = Join-Path $ProjectRoot 'suisen_pet\suisen_cli.py'
$PictureDir = Join-Path $ProjectRoot 'suisen_picture'
$VoiceDir = Join-Path $ProjectRoot 'suisen_voice'
$FinishVoiceDir = Join-Path $ProjectRoot 'finish_voice'
$ImageExtensions = @('.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif')
$AudioExtensions = @('.ogg', '.wav', '.mp3', '.flac')

function Write-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Label,
        [Parameter(Mandatory = $true)]
        [bool] $Ok,
        [string] $Detail = ''
    )

    if ($Ok) {
        Write-Host "[OK] $Label $Detail"
    } else {
        Write-Host "[Missing] $Label $Detail" -ForegroundColor Yellow
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

Write-Host "Project root: $ProjectRoot"
Write-Host ""

Write-Check -Label 'Python' -Ok (Test-Path -LiteralPath $Python) -Detail $Python
Write-Check -Label 'pet.py' -Ok (Test-Path -LiteralPath $PetPy) -Detail $PetPy
Write-Check -Label 'suisen_cli.py' -Ok (Test-Path -LiteralPath $CliPy) -Detail $CliPy

$Images = @(Get-SupportedFiles -Directory $PictureDir -Extensions $ImageExtensions)
Write-Check -Label 'images' -Ok ($Images.Count -gt 0) -Detail "count=$($Images.Count) dir=suisen_picture"

$AskVoices = @(Get-SupportedFiles -Directory $VoiceDir -Extensions $AudioExtensions)
Write-Check -Label 'ask voices' -Ok ($AskVoices.Count -gt 0) -Detail "count=$($AskVoices.Count) dir=suisen_voice"

$FinishVoices = @(Get-SupportedFiles -Directory $FinishVoiceDir -Extensions $AudioExtensions)
Write-Check -Label 'finish voices' -Ok ($FinishVoices.Count -gt 0) -Detail "count=$($FinishVoices.Count)"

Write-Host ""
Write-Host "pet.py status:"
if ((Test-Path -LiteralPath $Python) -and (Test-Path -LiteralPath $CliPy)) {
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Python $CliPy status 2>&1
        $statusExitCode = $LASTEXITCODE
    } catch {
        $output = @($_.Exception.Message)
        $statusExitCode = 1
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    foreach ($line in $output) {
        Write-Host "  $line"
    }
    Write-Host "  exit_code=$statusExitCode"
} else {
    Write-Host "  Cannot run status because Python or suisen_cli.py is missing."
}

Write-Host ""
Write-Host "If .venv is missing or broken, run:"
Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$(Join-Path $ProjectRoot 'setup_env.ps1')'"
