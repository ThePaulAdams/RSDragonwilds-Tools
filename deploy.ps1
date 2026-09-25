param(
    [string]$Tool = "All",
    [string]$GamePath = "F:\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64\ue4ss\Mods"
)

$ToolsDir = $PSScriptRoot

if (-not (Test-Path $GamePath)) {
    Write-Error "Game mods path not found: $GamePath"
    exit 1
}

$availableTools = @("OSRSMinimap", "QuickStack", "EnhancedReticle", "TelekineticWoodcraft", "ModMenu")

$toDeploy = @()
if ($Tool -eq "All") {
    $toDeploy = $availableTools
} elseif ($availableTools -contains $Tool) {
    $toDeploy = @($Tool)
} else {
    Write-Error "Unknown tool: $Tool. Available tools: $($availableTools -join ', ')"
    exit 1
}

Write-Host "Deploying tools to $GamePath..." -ForegroundColor Cyan

foreach ($t in $toDeploy) {
    $src = Join-Path $ToolsDir $t
    $dst = Join-Path $GamePath $t

    if (Test-Path $src) {
        Write-Host "  -> Deploying $t..." -ForegroundColor Yellow
        if (-not (Test-Path $dst)) {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
        }
        Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force
        Write-Host "     [OK] $t deployed." -ForegroundColor Green
    }
}

# Update mods.txt if necessary
$modsTxtPath = Join-Path $GamePath "mods.txt"
if (Test-Path $modsTxtPath) {
    $modsContent = Get-Content $modsTxtPath
    $updated = $false

    foreach ($t in $toDeploy) {
        $pattern = "^\s*$t\s*:"
        $found = $false
        foreach ($line in $modsContent) {
            if ($line -match $pattern) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            Write-Host "  -> Adding '$t : 1' to mods.txt..." -ForegroundColor Yellow
            $modsContent += "$t : 1"
            $updated = $true
        }
    }

    if ($updated) {
        Set-Content -Path $modsTxtPath -Value $modsContent -Encoding utf8
        Write-Host "     [OK] mods.txt updated." -ForegroundColor Green
    }
}

Write-Host "`nAll requested tools deployed successfully!" -ForegroundColor Green
