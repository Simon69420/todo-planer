# Todo Planer - Einrichtung
# Prüft das System, installiert die lokale KI (Ollama + Modell), richtet den Autostart ein und startet den Planer.
# Wird von setup.bat aufgerufen.
$ErrorActionPreference = 'Stop'
$here  = $PSScriptRoot
$model = 'qwen3.5:2b'
$api   = 'http://localhost:11434'

function Step($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    $t" -ForegroundColor Yellow }

Write-Host '==============================' -ForegroundColor White
Write-Host '   Todo Planer - Einrichtung' -ForegroundColor White
Write-Host '==============================' -ForegroundColor White

# Nur die eigenen Skripte freigeben (Windows blockiert Skripte aus dem Internet sonst)
foreach ($f in 'TodoPlaner.ps1', 'Install-Autostart.ps1', 'Setup.ps1', 'setup.bat') {
    $p = Join-Path $here $f
    if (Test-Path $p) { Unblock-File $p -ErrorAction SilentlyContinue }
}

# ---------- System prüfen (PowerShell + .NET sind bei Windows 10/11 schon dabei) ----------
Step 'System prüfen'
$build = [Environment]::OSVersion.Version.Build
if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Der Todo Planer braucht Windows 10 oder 11.' }
Ok "Windows (Build $build)"

if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 fehlt. Bitte Windows Update ausführen.' }
Ok "Windows PowerShell $($PSVersionTable.PSVersion)"

$netRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
if (-not $netRelease -or $netRelease -lt 394802) {
    Warn '.NET Framework 4.6.2 oder neuer fehlt, wird installiert ...'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Microsoft.DotNet.Framework.DeveloperPack_4 -e --silent --accept-source-agreements --accept-package-agreements
    } else {
        throw '.NET Framework fehlt. Bitte von https://dotnet.microsoft.com/download/dotnet-framework installieren.'
    }
} else {
    Ok '.NET Framework vorhanden'
}

$outlook = Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\Outlook.Application\CLSID' -ErrorAction SilentlyContinue
if ($outlook) { Ok 'Outlook gefunden (für Termin-Erinnerungen)' }
else { Warn 'Outlook (classic) nicht gefunden: Termin-Erinnerungen funktionieren nur mit Outlook. Alles andere läuft trotzdem.' }

function Find-Ollama {
    $c = Get-Command ollama -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path $p) { return $p }
    return $null
}
function Test-Api {
    try { [void](Invoke-RestMethod "$api/api/tags" -TimeoutSec 3); return $true } catch { return $false }
}

# ---------- Lokale KI (optional: der Planer läuft auch ohne) ----------
try {
    Step 'Lokale KI (Ollama) prüfen'
    $ollama = Find-Ollama
    if (-not $ollama) {
        Write-Host '    Ollama ist noch nicht installiert und wird jetzt heruntergeladen (ca. 1 GB).'
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id Ollama.Ollama -e --silent --accept-source-agreements --accept-package-agreements
        }
        if (-not (Find-Ollama)) {
            $exe = Join-Path $env:TEMP 'OllamaSetup.exe'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'   # macht Invoke-WebRequest deutlich schneller
            Invoke-WebRequest 'https://ollama.com/download/OllamaSetup.exe' -OutFile $exe -UseBasicParsing
            # Nur ausführen, wenn der Installer gültig von Ollama signiert ist
            $sig = Get-AuthenticodeSignature $exe
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Ollama') {
                Remove-Item $exe -ErrorAction SilentlyContinue
                throw "Signatur des Ollama-Installers ungültig ($($sig.Status)). Installation abgebrochen."
            }
            Start-Process $exe -ArgumentList '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES' -Wait
            Remove-Item $exe -ErrorAction SilentlyContinue
        }
        $ollama = Find-Ollama
        if (-not $ollama) { throw 'Ollama konnte nicht installiert werden.' }
        Ok 'Ollama installiert.'
    } else {
        Ok 'Ollama ist schon installiert.'
    }

    if (-not (Test-Api)) {
        $trayApp = Join-Path (Split-Path $ollama) 'ollama app.exe'
        if (Test-Path $trayApp) { Start-Process $trayApp } else { Start-Process $ollama -ArgumentList 'serve' -WindowStyle Hidden }
        for ($i = 0; $i -lt 30 -and -not (Test-Api); $i++) { Start-Sleep -Seconds 1 }
        if (-not (Test-Api)) { throw 'Ollama startet nicht.' }
    }

    Step "KI-Modell $model prüfen"
    $models = @((Invoke-RestMethod "$api/api/tags").models | ForEach-Object { $_.name })
    if ($models -contains $model) {
        Ok 'Modell ist schon da.'
    } else {
        Write-Host '    Modell wird heruntergeladen (ca. 2,7 GB), das dauert ein paar Minuten ...'
        & $ollama pull $model
        if ($LASTEXITCODE -ne 0) { throw 'Download des Modells fehlgeschlagen.' }
        Ok 'Modell bereit.'
    }
} catch {
    Warn ('KI konnte nicht eingerichtet werden: ' + $_.Exception.Message)
    Warn 'Der Planer funktioniert trotzdem, nur ohne Tippfehler-Korrektur. setup.bat kann später erneut ausgeführt werden.'
}

# ---------- Autostart ----------
Step 'Autostart einrichten'
& (Join-Path $here 'Install-Autostart.ps1') | Out-Null
Ok 'Der Planer startet ab jetzt automatisch mit Windows.'

# ---------- Starten ----------
Step 'Todo Planer starten'
$cmd = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run').TodoPlaner
$exePart, $argPart = if ($cmd -match '^"([^"]+)"\s+(.*)$') { $Matches[1], $Matches[2] } else { 'powershell.exe', ($cmd -replace '^powershell\.exe\s+', '') }
Start-Process $exePart -ArgumentList $argPart -WorkingDirectory $here
Ok 'Fertig! Strg+Alt+T blendet den Planer ein und aus.'
Write-Host ''
