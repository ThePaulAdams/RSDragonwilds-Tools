# One-command model export for the Model Viewer.
#   .\ModelViewer\export-models.ps1
# Finds the game, makes sure a Mappings.usmap exists (launching the game once with UE4SS if needed),
# builds the exporter, exports every static mesh to ModelViewer\export, then opens the viewer.
param(
    [string]$GameRoot = "",           # ...\steamapps\common\RSDragonwilds (found automatically if empty)
    [string]$Aes = "",                # only needed if the paks turn out to be encrypted
    [string[]]$Include = @(),         # limit to paths containing these parts, e.g. -Include Base_Building,Castle
    [int]$Limit = 0,                  # export at most N meshes (handy for a quick test)
    [switch]$NoTextures,
    [switch]$NoViewer
)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$repo = Split-Path $here -Parent

function Find-Game {
    $candidates = @("F:\Steam\steamapps\common\RSDragonwilds",
                    "C:\Program Files (x86)\Steam\steamapps\common\RSDragonwilds")
    $steam = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $candidates += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') "steamapps\common\RSDragonwilds")
            }
        }
    }
    foreach ($c in $candidates) { if (Test-Path (Join-Path $c "RSDragonwilds\Content\Paks")) { return $c } }
    return $null
}

if (-not $GameRoot) { $GameRoot = Find-Game }
if (-not $GameRoot -or -not (Test-Path (Join-Path $GameRoot "RSDragonwilds\Content\Paks"))) {
    Write-Error "Could not find RSDragonwilds. Pass -GameRoot '<Steam library>\steamapps\common\RSDragonwilds'."
}
$paks = Join-Path $GameRoot "RSDragonwilds\Content\Paks"
$win64 = Join-Path $GameRoot "RSDragonwilds\Binaries\Win64"
Write-Host "Game: $GameRoot" -ForegroundColor Cyan

# ---- 1. Mappings file (UE5 assets can't be read without it) ----
function Find-Usmap {
    Get-ChildItem -Path $win64 -Filter *.usmap -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
$usmap = Find-Usmap
if (-not $usmap) {
    $mods = Join-Path $win64 "ue4ss\Mods"
    if (-not (Test-Path $mods)) { Write-Error "UE4SS is not installed in $win64 (no ue4ss\Mods folder)." }
    Write-Host "No Mappings.usmap yet. Installing the MappingsDumper helper mod..." -ForegroundColor Yellow
    $dst = Join-Path $mods "MappingsDumper"
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item -Path (Join-Path $repo "MappingsDumper\*") -Destination $dst -Recurse -Force
    $modsTxt = Join-Path $mods "mods.txt"
    if ((Test-Path $modsTxt) -and -not (Select-String -Path $modsTxt -Pattern '^\s*MappingsDumper\s*:' -Quiet)) {
        Add-Content -Path $modsTxt -Value "MappingsDumper : 1"
    }

    $running = Get-Process -Name "RSDragonwilds-Win64-Shipping" -ErrorAction SilentlyContinue
    $launched = $false
    if ($running) {
        Write-Host "The game is already running without the helper. Close it and run this script again." -ForegroundColor Red
        exit 1
    }
    Write-Host "Starting the game once to write the mappings file (it closes again by itself)..." -ForegroundColor Yellow
    Start-Process "steam://rungameid/1374490"
    $launched = $true
    $deadline = (Get-Date).AddMinutes(10)
    while (-not ($usmap = Find-Usmap) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    if (-not $usmap) { Write-Error "Mappings.usmap did not appear within 10 minutes. Check ue4ss\UE4SS.log for [MappingsDumper]." }
    Start-Sleep -Seconds 5   # let the write finish
    if ($launched) { Get-Process -Name "RSDragonwilds-Win64-Shipping" -ErrorAction SilentlyContinue | Stop-Process -Force }
}
Write-Host "Mappings: $($usmap.FullName)" -ForegroundColor Cyan

# ---- 2. .NET 10 SDK (installed locally next to the exporter if missing; no admin needed) ----
$dotnet = "dotnet"
$hasSdk = $false
try { $hasSdk = [bool]((& dotnet --list-sdks 2>$null) -match '^10\.') } catch {}
if (-not $hasSdk) {
    $localDotnet = Join-Path $here "Exporter\.dotnet"
    $dotnet = Join-Path $localDotnet "dotnet.exe"
    if (-not (Test-Path $dotnet)) {
        Write-Host "Installing the .NET 10 SDK into ModelViewer\Exporter\.dotnet ..." -ForegroundColor Yellow
        $installer = Join-Path $env:TEMP "dotnet-install.ps1"
        Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $installer -UseBasicParsing
        & $installer -Channel 10.0 -InstallDir $localDotnet -NoPath
    }
}

# ---- 3. Build and run the exporter ----
$proj = Join-Path $here "Exporter\ModelExporter.csproj"
Write-Host "Building the exporter..." -ForegroundColor Yellow
& $dotnet build $proj -c Release --nologo -v quiet
if ($LASTEXITCODE -ne 0) { Write-Error "Exporter build failed." }

$out = Join-Path $here "export"
$exporterArgs = @("--paks", $paks, "--usmap", $usmap.FullName, "--out", $out)
if ($Aes) { $exporterArgs += @("--aes", $Aes) }
foreach ($i in $Include) { $exporterArgs += @("--include", $i) }
if ($Limit -gt 0) { $exporterArgs += @("--limit", "$Limit") }
if ($NoTextures) { $exporterArgs += "--no-textures" }
Write-Host "Exporting models to $out (re-running resumes where it stopped)..." -ForegroundColor Yellow
& $dotnet (Join-Path $here "Exporter\bin\Release\net10.0\ModelExporter.dll") @exporterArgs
$code = $LASTEXITCODE
if ($code -ne 0 -and -not (Test-Path (Join-Path $out "models.json"))) { Write-Error "Export failed (exit code $code)." }

# ---- 4. Open the viewer ----
if (-not $NoViewer) { & (Join-Path $here "view.ps1") }
