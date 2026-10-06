# Converts the model viewer's .webp previews to .png (which the game can load) in
# CustomBuilds\thumbs, one file per mesh named after its game path:
#   /Game/Art/Env/X/SM_Y.SM_Y  ->  thumbs\Game\Art\Env\X\SM_Y.png
# Existing files are skipped, so it is quick to run again after a new export.
#   .\make-thumbs.ps1 [-Viewer <model viewer folder>] [-Dest <folder>]
param(
    [string]$Viewer = (Join-Path $PSScriptRoot "..\..\RSDragonwilds-ModelViewer"),
    [string]$Dest = (Join-Path $PSScriptRoot "thumbs")
)
Add-Type -AssemblyName PresentationCore
$src = Join-Path $Viewer "export\thumbs"
if (-not (Test-Path $src)) { Write-Error "Not found: $src (open the viewer once so it draws previews)"; exit 1 }
# Full path without "..", so cutting it off each file's path leaves the right relative path.
$src = (Resolve-Path $src).ProviderPath.TrimEnd('\')
$done = 0; $skipped = 0; $failed = 0
Get-ChildItem $src -Recurse -Filter *.webp | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)            # RSDragonwilds\Content\Art\...\SM_X.webp
    $parts = $rel -split '\\'
    $root = if ($parts[0] -eq 'RSDragonwilds') { 'Game' } else { $parts[0] }
    $tail = ($parts[2..($parts.Count - 1)]) -join '\'
    $out = Join-Path $Dest ((Join-Path $root $tail) -replace '\.webp$', '.png')
    if (Test-Path $out) { $skipped++; return }
    try {
        New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
        $dec = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$_.FullName, 'None', 'OnLoad')
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add($dec.Frames[0])
        $fs = [IO.File]::Create($out)
        try { $enc.Save($fs) } finally { $fs.Close() }
        $done++
    } catch { $failed++ }
}
Write-Host "Converted $done, skipped $skipped existing, failed $failed. Output: $Dest"
