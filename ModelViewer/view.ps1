# Serves the Model Viewer on http://localhost:8765 and opens it in the browser.
# The viewer loads export\models.json by itself. Close this window (or press Ctrl+C) to stop.
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
        if ($file.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $file -PathType Leaf)) {
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
