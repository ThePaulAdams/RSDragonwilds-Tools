$wshell = New-Object -ComObject WScript.Shell
$proc = Get-Process -Name 'RSDragonwilds-Win64-Shipping' -ErrorAction SilentlyContinue
if ($proc) {
    $wshell.AppActivate($proc.Id)
    Start-Sleep -Milliseconds 300
    $wshell.SendKeys('^r')
    Write-Output 'Sent Ctrl+R to game window.'
} else {
    Write-Output 'Game process not found.'
}
