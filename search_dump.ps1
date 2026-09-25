param([string]$pattern = "Splinter")
$file = 'F:\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64\ue4ss\UE4SS_ObjectDump.txt'
$reader = [System.IO.File]::OpenText($file)
$found = 0
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ($line -match $pattern) {
            Write-Output $line
            $found++
            if ($found -ge 40) { break }
        }
    }
} finally {
    $reader.Close()
}
