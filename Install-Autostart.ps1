# Traegt die App in den Benutzer-Autostart (HKCU\...\Run) ein.
# Ab Windows 10 2004 startet conhost --headless PowerShell ganz ohne Konsolenfenster,
# auf aelteren Versionen wird PowerShell versteckt gestartet.
$script = Join-Path $PSScriptRoot 'TodoPlaner.ps1'
$ps     = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA"

if ([Environment]::OSVersion.Version.Build -ge 19041) {
    $command = "`"$env:WINDIR\System32\conhost.exe`" --headless $ps -File `"$script`""
} else {
    $command = "$ps -WindowStyle Hidden -File `"$script`""
}

Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'TodoPlaner' -Value $command
Write-Output "Autostart eingetragen: $command"
