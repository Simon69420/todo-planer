@echo off
rem Startet den Todo Planer (gleicher Befehl wie im Autostart, ohne Konsolenfenster)
start "" "%WINDIR%\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0TodoPlaner.ps1"
