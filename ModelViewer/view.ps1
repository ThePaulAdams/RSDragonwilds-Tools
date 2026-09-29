# Serves the Model Viewer on http://localhost:8765 and opens it in the browser.
# The viewer loads export\models.json by itself and saves the previews it draws to export\thumbs. Close this window (or press Ctrl+C) to stop.
param([int]$Port = 8765)
$root = $PSScriptRoot
$types = @{ ".html" = "text/html"; ".js" = "text/javascript"; ".json" = "application/json";
            ".glb" = "model/gltf-binary"; ".gltf" = "model/gltf+json"; ".bin" = "application/octet-stream";
            ".png" = "image/png"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"; ".tga" = "image/x-tga"; ".webp" = "image/webp" }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Model Viewer running at http://localhost:$Port/  (Ctrl+C to stop)" -ForegroundColor Green
Start-Process "http://localhost:$Port/"
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
        if ($path -eq "") { $path = "index.html" }
        $file = [System.IO.Path]::GetFullPath((Join-Path $root $path))
        $res = $ctx.Response
        $thumbs = [System.IO.Path]::GetFullPath((Join-Path $root "export\thumbs"))
        if ($path -eq "thumbs-list") {
            # Which previews are already saved, so the viewer only draws the missing ones.
            $list = @()
            if (Test-Path $thumbs) {
                $list = Get-ChildItem -Path $thumbs -Recurse -File -Filter *.webp |
                    ForEach-Object { $_.FullName.Substring($thumbs.Length + 1).Replace('\', '/') }
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($list) -Compress))
            $res.ContentType = "application/json"
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } elseif ($ctx.Request.HttpMethod -eq "PUT") {
            # The viewer saves each preview it draws under export\thumbs, so it is only drawn once.
            if ($file.StartsWith($thumbs + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and $file.EndsWith(".webp")) {
                New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
                $fs = [System.IO.File]::Create($file)
                try { $ctx.Request.InputStream.CopyTo($fs) } finally { $fs.Close() }
                $res.StatusCode = 204
            } else {
                $res.StatusCode = 403
            }
        } elseif ($file.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $file -PathType Leaf)) {
            $ext = [System.IO.Path]::GetExtension($file).ToLower()
            $res.ContentType = if ($types.ContainsKey($ext)) { $types[$ext] } else { "application/octet-stream" }
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $res.StatusCode = 404
        }
        $res.Close()
    }
} finally {
    $listener.Stop()
}
