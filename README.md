# Todo Planer

Ein kleines, transparentes Todo-Fenster für Windows, das immer auf dem Desktop schwebt.
Aufgaben einfach reinschreiben, mit einem Klick abhaken – fertig.

## Funktionen

- **Transparentes Mini-Fenster**: verschiebbar, Größe änderbar, Transparenz per Mausrad über der Titelzeile.
  Klicks auf leere Flächen gehen zum Fenster dahinter durch.
- **Stört nicht**: Solange es offen ist, taucht es weder in der Taskleiste noch bei `Alt+Tab` auf.
  Minimiert (—) liegt es in der Taskleiste.
- **Startet automatisch mit Windows.**
- **Zeiten werden erkannt**: `bis 13:00`, `um 1300`, `morgen um 9`, `bis Freitag`, `am Montag um 10`,
  `bis 24.12.`, `in 30 min`.
  - `um` = Termin → Erinnerung 5 Min. vorher
  - `bis` = Deadline → Erinnerung 30 Min. vorher
  - enthält der Text „Anmeldung“/„anmelden“ → Erinnerung 30 **und** 5 Min. vorher
- **Aufgeräumte Liste**: Aufgaben weit in der Zukunft erscheinen erst 2 Tage vorher („3 geplant – anzeigen“).
  Mit Stern markierte Aufgaben sind immer sichtbar.
- **Kalender (Outlook + Google)**: 15 Min. vor einem Termin kommt er oben auf die Liste und verschwindet danach wieder.
  In den Einstellungen gibt es eine Übersicht der nächsten 14 Tage.
- **Lokale KI** (Ollama, Modell `qwen3.5:2b`):
  - korrigiert Tippfehler – Namen, Abkürzungen und Zahlen bleiben unangetastet,
  - kürzt lange Einträge auf das Wichtigste; der volle Text steht im Tooltip und beim Bearbeiten.
- Doppelklick = bearbeiten, ziehen = sortieren, Stern = wichtig, `Strg+Z` = rückgängig.
- **Globaler Hotkey** `Strg+Alt+T` holt den Planer von überall nach vorne.

## Voraussetzungen

| | |
|---|---|
| **Windows 10 oder 11** | PowerShell 5.1 und .NET Framework sind bereits dabei – kein Python o. Ä. nötig |
| **[Ollama](https://ollama.com)** | für Tippfehler-Korrektur und Kürzen. Wird von `setup.bat` automatisch installiert (ca. 1 GB + 2,7 GB Modell). Ohne Ollama läuft alles andere trotzdem. |
| **Outlook (classic)** | optional, für Termine aus Outlook. Das „neue Outlook“ hat keine Schnittstelle dafür. |
| **Google Kalender** | optional, über die private iCal-Adresse (siehe unten) |

## Installation

1. Repository herunterladen (grüner Button **Code → Download ZIP**) und entpacken, z. B. nach `Dokumente\Todo Planer`.
2. **`setup.bat` doppelklicken.** Das Setup
   - prüft Windows, PowerShell und .NET (und installiert .NET bei Bedarf nach),
   - installiert Ollama (per `winget`, sonst direkt von ollama.com mit Signaturprüfung),
   - lädt das KI-Modell `qwen3.5:2b`,
   - trägt den Planer in den Autostart ein und startet ihn.

## Einstellungen (Zahnrad)

- **Kalender** an/aus. Gelesen wird dein eigener Outlook-Hauptkalender.
  Weitere Kalender (Feiertage, Kurse, freigegebene Kalender von Kollegen …) erscheinen als Liste zum Anhaken.
- **Google-Kalender dazu**: In Google Kalender → Einstellungen → dein Kalender → „Privatadresse im iCal-Format“ kopieren und einfügen.
  Termine, die in beiden Kalendern stehen, werden nur einmal angezeigt.
- **Tippfehler korrigieren** an/aus.

## Bedienung

| Aktion | So geht's |
|---|---|
| Aufgabe hinzufügen | unten reinschreiben + Enter |
| Erledigt | Kreis anklicken |
| Bearbeiten | Doppelklick auf den Text (zeigt den vollen Text) |
| Sortieren | Text ziehen |
| Wichtig (immer sichtbar) | Stern |
| Rückgängig | `Strg+Z` oder ↶ in der Titelzeile |
| Minimieren / zurückholen | — in der Titelzeile, `Strg+Alt+T`, Taskleiste oder Tray-Symbol |
| Beenden | Rechtsklick aufs Tray-Symbol → Beenden |
| Aufgaben importieren | `import.txt` in den Ordner legen, eine Aufgabe pro Zeile – wird automatisch übernommen und gelöscht |

## Datenschutz

- Aufgaben und Einstellungen (inkl. Google-Kalender-Link) liegen nur in `todos.json` / `settings.json` im Programmordner
  und sind per `.gitignore` vom Repository ausgeschlossen.
- Outlook wird lokal gelesen. Der Google-Kalender wird direkt von Google geladen, sonst geht nichts an einen Server.
- Die KI läuft über Ollama auf `localhost` – Texte verlassen den PC nicht.
- Der Google-iCal-Link ist geheim (jeder mit dem Link sieht den Kalender) – nicht weitergeben.

## Deinstallation

1. Rechtsklick aufs Tray-Symbol → **Beenden**
2. Autostart entfernen (PowerShell):
   ```powershell
   Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name TodoPlaner
   ```
3. Ordner löschen. Ollama kann bei Bedarf über *Einstellungen → Apps* deinstalliert werden.

## Hinweise

- Der Autostart ruft PowerShell mit `-ExecutionPolicy Bypass` auf, damit die (unsignierten) Skripte ohne Systemänderung laufen. Die Richtlinie gilt nur für diesen einen Prozess.
- Fehler landen in `error.log` im Programmordner.
