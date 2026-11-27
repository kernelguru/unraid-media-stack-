# Unraid Media Stack

Ein Script, das einen kompletten **Usenet-Streaming-Media-Stack** auf **Unraid** oder **Debian/Ubuntu** installiert, die Apps miteinander verbindet und so weit vorkonfiguriert, dass danach kaum noch Handarbeit nötig ist. Die Plattform erkennt das Script selbst.

| App | Aufgabe | Port |
|---|---|---|
| **InfiniDysk** (NzbDAV-Fork) | Bindet NZBs als WebDAV ein, ohne sie herunterzuladen, und stellt eine SABnzbd-kompatible API bereit | 3000 |
| **rclone** (Unraid-Plugin bzw. systemd-Dienst) | Hängt das WebDAV von InfiniDysk auf dem Host ein | – |
| **Prowlarr** | Verwaltet die Indexer und verteilt sie an Radarr/Sonarr | 9696 |
| **Radarr** | Filme | 7878 |
| **Sonarr** | Serien | 8989 |
| **Jellyfin** | Mediaserver | 8096 |
| **Seerr** | Anfragen für Filme und Serien | 5055 |
| **Recyclarr** | Überträgt die deutschen TRaSH-Profile (HD, UHD) plus „[German] Any“ in Radarr/Sonarr und gleicht sie täglich ab | – |

## So funktioniert es

```
Seerr ──► Radarr / Sonarr ──► Prowlarr (Indexer)
                │
                ▼  NZB über die SABnzbd-API
           InfiniDysk ──WebDAV──► rclone-Mount (/mnt/nzbdav)
                │                        ▲
                ▼                        │ Symlinks zeigen hierhin
   completed-symlinks ──► Import in /data/media ──► Jellyfin streamt
```

Es wird nichts heruntergeladen. Radarr und Sonarr importieren nur **Symlinks**, die auf den rclone-Mount zeigen. Jellyfin streamt die Datei beim Abspielen direkt vom Usenet-Provider.

## Voraussetzungen

- **Unraid** 6.12 oder neuer, Array gestartet, Docker aktiviert, **oder**
  **Debian** 12+ bzw. **Ubuntu** 22.04+ mit systemd. Docker, rclone und die übrigen Pakete installiert das Script.
- Zugang zu einem Usenet-Provider und mindestens ein Usenet-Indexer
- Root-Zugang (Unraid: SSH oder Web-Terminal · Debian/Ubuntu: `sudo`)
- Freie Ports: 3000, 5055, 7878, 8096, 8989, 9696

## Dashboard

Unter `http://<server-ip>:8090` liegt eine kleine Übersichtsseite (Container `dashboard`, nginx):

- Links zu Seerr, Jellyfin, Radarr, Sonarr, Prowlarr und InfiniDysk
- **API-Keys** verdeckt, mit Knöpfen zum Einblenden (👁) und **Kopieren**
- **Online-Status** je App (grün/rot) und **rclone-Mount-Status**

Der Status wird **auf dem Server** geprüft, nicht im Browser. Ein Job läuft jede Minute (`bash mediastack.sh dashboard-status`), fragt die Apps über `127.0.0.1` ab, prüft den Mount und schreibt das Ergebnis nach `status.json`. Die Seite liest nur diese Datei. Deshalb funktioniert sie lokal genauso wie über HTTPS oder einen Reverse Proxy. Der Job läuft unter Unraid per Cron (`/boot/config/plugins/dynamix/mediastack-dashboard.cron`), unter Debian/Ubuntu als `mediastack-dashboard.timer`. Ist der Status älter als 5 Minuten, zeigt die Seite graue Punkte und einen Hinweis.

> Die Seite hat **keinen Login**. Jeder im LAN kann die API-Keys sehen. Port 8090 deshalb **nicht** ins Internet freigeben und auch nicht über einen Reverse Proxy veröffentlichen.

Einstellungen: `DASHBOARD_ENABLED=true|false`, `P_DASHBOARD=8090`. Die Dateien liegen in `appdata/mediastack/dashboard/` (`index.html`, `apps.json`, `status.json`) und werden bei jedem Lauf des Scripts neu geschrieben.

## Plattformen

Das Script erkennt die Plattform an `/etc/unraid-version` bzw. `/etc/os-release`. Erzwingen geht mit `PLATFORM=unraid|debian` in der `mediastack.conf`.

| | Unraid | Debian / Ubuntu |
|---|---|---|
| Configs (`APPDATA`) | `/mnt/user/appdata` | `/opt/mediastack` |
| Medien | `/mnt/user/data/media/{movies,tv}` | `/srv/media/{movies,tv}` |
| rclone-Mount | `/mnt/addons/nzbdav` | `/mnt/nzbdav` |
| Benutzer (PUID:PGID) | 99:100 | Benutzer hinter `sudo`, sonst 1000:1000 |
| rclone | Plugin aus den Community Apps | rclone.org-Paket, Dienst `mediastack-mount.service` |
| Start nach Neustart | Unraid-Hooks + go-Datei | systemd (nach Docker, wartet auf InfiniDysk) |
| Watchdog | Cron (`dynamix/mediastack.cron`) | systemd-Timer `mediastack-watchdog.timer` |
| Log | `grep mediastack /var/log/syslog` | `journalctl -t mediastack` |
| Docker | vorhanden | wird bei Bedarf aus dem offiziellen Docker-Repository installiert (`INSTALL_DOCKER=true`) |

Alle Werte lassen sich in der `mediastack.conf` überschreiben. Auf Debian/Ubuntu kommen automatisch hinzu: `curl`, `jq`, `fuse3`, `gnupg`, Docker CE samt Compose-Plugin und rclone.

## Installation

**Debian/Ubuntu:**
```bash
sudo mkdir -p /opt/mediastack-setup && cd /opt/mediastack-setup
sudo wget https://raw.githubusercontent.com/kernelguru/unraid-media-stack-/main/mediastack.sh
sudo bash mediastack.sh
```

**Unraid:**

```bash
cd /mnt/user/appdata
mkdir -p mediastack-setup && cd mediastack-setup
wget https://raw.githubusercontent.com/kernelguru/unraid-media-stack-/main/mediastack.sh
# optional: eigene Einstellungen
wget https://raw.githubusercontent.com/kernelguru/unraid-media-stack-/main/mediastack.conf.example -O mediastack.conf
nano mediastack.conf

bash mediastack.sh
```

> Das Script ist interaktiv. Bitte **nicht** über das User-Scripts-Plugin starten, sondern im Terminal.

### Ablauf

1. Das Script fragt nach einem **Admin-Passwort**. Es gilt für Radarr, Sonarr, Prowlarr, Jellyfin und Seerr.
2. Das Script startet InfiniDysk und **pausiert**. Öffne dann `http://<server-ip>:3000` → *Settings* und trage ein:
   - **Usenet:** Provider-Host, Port, SSL, Benutzer, Passwort, Anzahl der Verbindungen
   - **SABnzbd:** Categories `movies,tv` · Rclone Mount Directory `/mnt/nzbdav` · API-Key kopieren
   - **WebDAV:** Benutzer und Passwort festlegen
3. API-Key, WebDAV-Benutzer und WebDAV-Passwort ins Terminal einfügen.
4. Den Rest erledigt das Script.
5. Indexer in **Prowlarr** hinzufügen, falls du sie nicht über `INDEXERS` in der Konfig mitgegeben hast. Prowlarr verteilt sie automatisch an Radarr und Sonarr.

Fertig. In Seerr (`http://<server-ip>:5055`) kannst du jetzt Filme und Serien anfragen.

## Was automatisch konfiguriert wird

- **Ordner:** `/mnt/user/data/media/{movies,tv}` und appdata, mit den richtigen Rechten (99:100, für Seerr 1000:1000)
- **rclone:** WebDAV-Mount mit `--links` (damit die Symlinks funktionieren) und VFS-Cache. Er wird unter `/mnt/addons/nzbdav` mit Mount-Propagation in alle Container eingehängt.
- **Radarr / Sonarr:**
  - API-Keys werden vorab erzeugt, Login (Forms, für das lokale Netz deaktiviert) wird gesetzt
  - Root-Ordner `/data/media/movies` bzw. `/data/media/tv`
  - InfiniDysk ist als SABnzbd-Download-Client mit passender Kategorie eingetragen
  - Die Mediainfo-Analyse ist aus, damit gestreamte Dateien nicht angelesen werden
  - Jellyfin-Benachrichtigung: Bibliotheks-Scan nach Import, Upgrade, Umbenennen und Löschen
- **Prowlarr:** Radarr und Sonarr sind als Apps angelegt (Full Sync), optional auch Newznab-Indexer
- **Jellyfin:**
  - Einrichtungsassistent wird durchlaufen, Admin-Benutzer angelegt
  - Bibliotheken *Filme* und *Serien*. Trickplay- und Kapitelbilder sind aus, das ist beim Streaming wichtig.
  - API-Key für Radarr und Sonarr
  - Hardware-Transcoding über `/dev/dri`, sofern vorhanden
- **Seerr:** Login über Jellyfin, Bibliotheken aktiviert, Radarr und Sonarr als Standard-Server eingetragen
- **Unraid:** Die Container erscheinen im Docker-Tab mit WebUI-Link und Icon. Die Logs sind auf 30 MB pro Container begrenzt.

Zugangsdaten und API-Keys landen in `/mnt/user/appdata/mediastack/secrets.env` (Rechte 600).

## Befehle

```bash
bash mediastack.sh                    # installieren/konfigurieren – erneut ausführbar
bash mediastack.sh update             # Images aktualisieren + geänderte Konfiguration übernehmen
bash mediastack.sh self-update        # neue Script-Version von GitHub holen, danach automatisch "update"
bash mediastack.sh recreate jellyfin  # einzelne Container neu anlegen (mehrere möglich)
bash mediastack.sh status             # Status der Container + Script-Version
bash mediastack.sh doctor             # rclone-Mount prüfen, Reparatur mit Rückfrage
bash mediastack.sh doctor --yes       # dasselbe ohne Rückfrage
bash mediastack.sh watchdog pause     # Mount-Überwachung pausieren (resume = fortsetzen)
bash mediastack.sh remove             # Container entfernen (Configs und Medien bleiben erhalten)
```

## Hardware-Beschleunigung (Jellyfin)

Mit `JELLYFIN_HWACCEL=auto` (Standard) erkennt das Script die GPU, reicht sie an den Jellyfin-Container durch und stellt Jellyfin passend ein (*Dashboard → Wiedergabe → Transcoding*):

| GPU | Jellyfin | Container |
|---|---|---|
| Intel (iGPU/Arc) | **QSV** inkl. HDR-Tonemapping | `--device /dev/dri` + linuxserver-Mod `jellyfin-opencl-intel` |
| AMD | **VAAPI** | `--device /dev/dri` |
| NVIDIA | **NVENC** inkl. Tonemapping | `--runtime=nvidia`, alle GPUs |

Aktiviert werden Hardware-Encoding und -Decoding für H.264, HEVC (auch 10 Bit), MPEG-2, VC-1 und VP9 (auch 10 Bit).

- **NVIDIA auf Debian/Ubuntu:** Der NVIDIA-Treiber muss installiert sein (`nvidia-smi` funktioniert). Das *NVIDIA Container Toolkit* installiert das Script dann selbst und richtet die Docker-Runtime ein.
- **NVIDIA auf Unraid:** Dafür braucht es das Plugin *Nvidia Driver* aus den Community Apps.
- Ist in Jellyfin schon eine Beschleunigung eingestellt, bleibt sie unverändert. Überschreiben geht mit `JELLYFIN_HWACCEL_FORCE=true`.
- Erzwingen oder abschalten geht mit `JELLYFIN_HWACCEL=qsv|vaapi|nvenc|none`.

## rclone: Plugin oder Container

Unter Unraid ist das **rclone-Plugin** aus den Community Apps ([Waseh/rclone-unraid](https://github.com/Waseh/rclone-unraid)) der zuverlässige Weg. rclone läuft dabei direkt auf dem Host, der Mount entsteht also genau dort, wo Radarr, Sonarr und Jellyfin ihn brauchen. Ein Mount, der in einem Container entsteht, kommt unter Unraid oft nicht auf dem Host an.

**Standard: `RCLONE_MODE="plugin"`.** Das Script

1. installiert das Plugin, falls es fehlt (`plugin install …/rclone.plg`, also genau wie über die Community Apps). Es erscheint danach normal unter *Plugins*.
2. trägt das Remote `nzbdav` in die Plugin-Konfiguration `/boot/config/plugins/rclone/.rclone.conf` ein. Andere Remotes in der Datei bleiben unangetastet.
3. hängt das WebDAV als Daemon unter `/mnt/addons/nzbdav` ein. Log: `appdata/mediastack/rclone.log`.
4. hängt den Mount nach jedem Neustart automatisch wieder ein. Ein Unraid-Hook (`started`) wartet nach dem Array-Start auf InfiniDysk und mountet dann. Fällt der Mount später aus, holt ihn der Watchdog innerhalb von 5 Minuten zurück.

Ein vorhandener Container `rclone-nzbdav` wird im Plugin-Modus entfernt.

> Hast du das Plugin schon und hängst eigene Remotes per User Scripts ein, ist das kein Problem: Das Script nutzt nur das Remote `nzbdav` (änderbar über `RCLONE_REMOTE`). Hängt dein eigenes Skript **dasselbe** WebDAV ein, deaktiviere es, damit es nicht doppelt gemountet wird.

**Debian/Ubuntu: `RCLONE_MODE="systemd"` (Standard dort).** rclone läuft vom Host als Dienst `mediastack-mount.service`. Er startet nach Docker, wartet bis zu 15 Minuten auf InfiniDysk und startet rclone bei Fehlern neu. Wichtige Befehle: `systemctl status mediastack-mount`, `journalctl -u mediastack-mount`. Konfiguration: `/opt/mediastack/rclone-nzbdav/rclone.conf`.

**Alternative: `RCLONE_MODE="container"`.** rclone läuft dann im Container `rclone-nzbdav` (`--privileged --pid=host`, Mount per `nsenter` im Host-Namespace). Das ist nur sinnvoll, wenn du kein Plugin installieren willst.

## rclone-Einstellungen (nach InfiniDysk-Doku)

Die Mount-Optionen folgen dem InfiniDysk-Guide *Mount WebDAV with rclone*:

| Option | Wert | Warum |
|---|---|---|
| `--links` | – | `.rclonelink` → echte Symlinks |
| `--use-cookies` | – | keine erneute Anmeldung bei jeder Anfrage |
| `--vfs-cache-mode` | `full` | Lese-Cache auf der Platte, flüssiges Spulen |
| `--vfs-cache-max-size` | `50G` (`RCLONE_CACHE_SIZE`) | Obergrenze des Caches |
| `--vfs-cache-max-age` | `1w` (`RCLONE_CACHE_MAX_AGE`) | wie lange Cache-Daten bleiben |
| `--buffer-size` | `0` | kein doppeltes Puffern neben dem VFS-Cache |
| `--vfs-read-ahead` | `512M` (`RCLONE_READ_AHEAD`) | Vorlauf für Bitraten-Spitzen |
| `--dir-cache-time` | `20s`, mit RC `1w` + `--poll-interval=0` | aktuelle Verzeichnislisten |

Der Cache liegt in `appdata/rclone-nzbdav/cache`. Ändert sich eine Einstellung, hängt `update` den Mount automatisch neu ein.

**Backend-Port statt Port 3000:** Laut Doku soll rclone das WebDAV direkt über den Backend-Port **8080** von InfiniDysk ansprechen. Port 3000 ist der Proxy der Weboberfläche: langsamer beim Streaming, und InfiniDysk zeigt dann eine Warnung an. Das Script veröffentlicht Port 8080 als `127.0.0.1:18080` (`P_WEBDAV`), also nur für den Host und nicht im LAN, und nutzt ihn automatisch. Hast du InfiniDysk selbst angelegt (eigene Unraid-Vorlage), füge dort einen Port hinzu: Container-Port `8080` → Host-Port `18080`. `doctor` zeigt, welcher Weg aktiv ist, und stellt rclone bei Bedarf um.

**Segment Cache:** Bei Symlink-Bibliotheken übernimmt rclone das Caching, deshalb sollte der Segment Cache in InfiniDysk aus sein (*Settings → Streaming*). Bei vom Script angelegtem InfiniDysk setzt es das per `NZBDAV_CONFIG__USENET__SEGMENT_CACHE__ENABLED=false`.

**RC-Benachrichtigungen (optional, `RCLONE_RC=true`):** InfiniDysk meldet neue und entfernte Dateien direkt an rclone (`vfs/forget`). Dann darf der Verzeichnis-Cache eine Woche gelten, das bedeutet weniger WebDAV-Anfragen. rclone lauscht dafür auf Port 5572 (Benutzer `rclone`, Passwort `RC_PASS` in `secrets.env`). Hat das Script InfiniDysk angelegt, trägt es die RC-Daten per Umgebungsvariablen ein. Sonst trägst du sie selbst ein, unter *Settings → Rclone Server*: Notifications an, Host `http://<server-ip>:5572`, Benutzer und Passwort, dann **Test**. Erst danach `RCLONE_RC=true` setzen, sonst sieht rclone neue Dateien bis zu einer Woche lang nicht.

> **Jellyfin und STRM:** InfiniDysk empfiehlt für Emby und Jellyfin eigentlich STRM-Dateien statt Symlinks. Der Nachteil laut Doku: Jellyfin zeigt dann Laufzeit und Tonspuren erst nach dem ersten Abspielen. Dieser Stack nutzt Symlinks mit rclone-Mount, die Doku nennt das als gleichwertige Alternative.

## rclone-Mount: Diagnose, Reparatur und Watchdog

`bash mediastack.sh doctor` prüft die ganze Kette der Reihe nach und hält beim ersten Fehler an:

| # | Prüfung | Reparatur (nach Rückfrage) |
|---|---|---|
| 1 | InfiniDysk läuft und antwortet | starten bzw. neu starten |
| 2 | WebDAV-Login (PROPFIND → 207) | Zugangsdaten neu eingeben, `rclone.conf` neu schreiben |
| 3 | **Plugin:** Plugin installiert, kein alter Container parallel · **Container:** `rclone-nzbdav` läuft im Host-Modus | Plugin installieren bzw. alten Container entfernen · Container neu anlegen |
| 4 | rclone erreicht das WebDAV | Remote bzw. `rclone.conf` aus `secrets.env` neu schreiben |
| 5 | rclone-Mount läuft | Mount (neu) starten |
| 6 | Mount auf dem Host mit Inhalt, Mountpunkt *shared* | toten Mount aufräumen, Mountpunkt *shared* machen, neu mounten, Apps neu starten |
| 7 | Mount in Radarr, Sonarr und Jellyfin sichtbar | betroffene Container neu starten |

Nach jeder Reparatur beginnt die Prüfung von vorn. Nach höchstens 5 Durchläufen ist Schluss.

**Watchdog:** Mit `WATCHDOG_ENABLED=true` (Standard) läuft dieselbe Prüfung alle 5 Minuten im Hintergrund und repariert ohne Rückfrage. Ist alles in Ordnung, passiert nichts. Reparaturen und Probleme landen im Unraid-Syslog:

```bash
grep mediastack /var/log/syslog
```

- Der Watchdog fragt nie nach Zugangsdaten und führt keine Installation aus. Solche Fälle meldet er nur im Syslog.
- Läuft Docker nicht (Array gestoppt), tut er nichts. Zwei Läufe gleichzeitig verhindert ein Lock.
- Für Wartungsarbeiten: `bash mediastack.sh watchdog pause`, danach `bash mediastack.sh watchdog resume`.

**Cron unter Unraid:** `/etc/cron.d` liegt im RAM. `update_cron` baut die Datei bei jedem Boot neu, und zwar nur aus `*.cron`-Dateien von *installierten* Plugins. `mediastack` ist kein Plugin, deshalb liegt der Job in `/boot/config/plugins/dynamix/mediastack.cron`. Den Ordner von Unraid selbst liest `update_cron` immer ein. Prüfen: `grep mediastack /etc/cron.d/root`. Abschalten: `WATCHDOG_ENABLED=false` in `mediastack.conf`, dann `bash mediastack.sh update`.

**Nach einem Neustart** sorgen drei Stufen dafür, dass der Mount wieder da ist:
1. **Hook `disks_mounted`** (vor Docker): Er macht den Mountpunkt *shared*.
2. **Hook `started`** (Array und Docker laufen) und zusätzlich ein **Boot-Wächter aus der go-Datei**: Beide starten den Watchdog im Boot-Modus. Der wartet bis zu 15 Minuten auf InfiniDysk und hängt dann ein. Ein Lock verhindert, dass beide gleichzeitig laufen.
3. **Watchdog-Cron** alle 5 Minuten als Rückfallebene.

Was beim Booten passiert ist: `grep mediastack /var/log/syslog`. `doctor` prüft am Ende auch, ob Hooks, go-Eintrag und Cron vollständig sind, und richtet sie bei Bedarf neu ein.

## TRaSH-Guides (deutsche Profile)

[Recyclarr](https://recyclarr.dev) überträgt Qualitätsprofile und Custom Formats aus den [TRaSH-Guides](https://trash-guides.info) nach Radarr und Sonarr und gleicht sie täglich ab (`RECYCLARR_SCHEDULE`).

**Standard:** In Radarr und Sonarr gibt es drei Profile:

| Profil | Herkunft | Inhalt |
|---|---|---|
| **[German] HD Bluray + WEB** | TRaSH | 720p/1080p, Bluray + WEB, deutsche Releases bevorzugt. **Standard in Seerr** |
| **[German] UHD Bluray + WEB** | TRaSH | 2160p, Bluray + WEB |
| **[German] Any** | mediastack | jede Qualität (SD bis 1080p), **nur mit deutscher Tonspur**, Upgrades bis 1080p |

Profile wählen in `mediastack.conf`:
```bash
TRASH_PROFILES=(german-hd-bluray-web german-uhd-bluray-web)   # das erste ist das Haupt-Profil
TRASH_ANY_GERMAN=true                                          # [German] Any an/aus
SEERR_PROFILE="[German] HD Bluray + WEB"                       # Standard für Anfragen
```
Verfügbar sind `german-hd-bluray-web`, `german-hd-remux-web`, `german-uhd-bluray-web`, `german-uhd-bluray-web-alternative`, `german-uhd-remux-web` und `german-anime-hd-bluray-web`.

**[German] Any** nutzt dieselben Custom Formats und Bewertungen wie *[German] HD Bluray + WEB* (Score-Set `german`) plus die Standard-Formate aus *[Unwanted] Unwanted Formats German*. Damit fliegen etwa LQ, Microsized, Mic-Dubbed und Upscaled raus. Die Mindestbewertung von **5000** erzwingt die deutsche Tonspur: *German* bringt +10.000, *German DL* +11.000, ein rein englisches Release erreicht höchstens rund 2.500. Upgrades laufen bis zur Qualitätsgruppe 1080p bzw. bis 35.000 Punkte.

**So entsteht die Konfiguration:** Das Script erzeugt `appdata/recyclarr/configs/radarr.yml` und `sonarr.yml` selbst. Die Profil- und Gruppen-IDs holt es aus den offiziellen [recyclarr/config-templates](https://github.com/recyclarr/config-templates), dazu kommen die standardmäßig aktiven Custom-Format-Gruppen aller gewählten Profile. Die erste Zeile enthält einen Fingerabdruck (`# mediastack-generated: …`):
- Ändern sich `TRASH_PROFILES` oder `TRASH_ANY_GERMAN`, erzeugt `update` die Datei neu und sichert die alte als `.yml.bak`.
- Bleibt die Auswahl gleich, bleiben deine eigenen Anpassungen in der Datei erhalten, etwa zusätzlich aktivierte Gruppen.

Ein Abgleich von Hand geht mit `docker exec recyclarr recyclarr sync`, das Ergebnis steht in `appdata/recyclarr/last-sync.log`.

**Seerr** fordert standardmäßig mit `SEERR_PROFILE` an. Als Admin kannst du bei einer Anfrage unter *Erweitert* jedes andere Profil wählen, also UHD oder Any. Ein eigener „In 4K anfragen“-Knopf bräuchte eine zweite Radarr- bzw. Sonarr-Instanz.

**Hinweise:**
- Vorhandene Filme und Serien behalten ihr Profil. Umstellen kannst du sie in Radarr und Sonarr über *Bibliothek bearbeiten* mit Mehrfachauswahl.
- `reset_unmatched_scores` setzt Bewertungen von Custom Formats, die nicht zum Profil gehören, auf 0.
- Die Any-Custom-Formats sind im Script hinterlegt (`ANY_CF_RADARR` und `ANY_CF_SONARR`). Benennt TRaSH ein Format um oder entfernt es, meldet Recyclarr das im Sync-Log.

## Zusätzliche Volumes (z. B. ein weiterer Ordner für Jellyfin)

Liegt der Ordner unter `/mnt/user/data/media`, sieht Jellyfin ihn schon als `/data/media/...`. Dafür brauchst du kein extra Volume.

Für andere Pfade trägst du die Volumes in `mediastack.conf` ein:

```bash
JELLYFIN_EXTRA_VOLUMES=(
  "/mnt/user/Fotos:/data/fotos:ro"
  "/mnt/user/Musik:/data/musik:ro"
)
```

Dann ausführen:

```bash
bash mediastack.sh update
```

Das Script erkennt die geänderte Konfiguration und legt **nur Jellyfin** neu an. Bibliotheken, Benutzer und Einstellungen bleiben erhalten, denn sie liegen in appdata. Danach in Jellyfin eine Bibliothek mit dem Pfad `/data/fotos` hinzufügen.

Die gleiche Variable gibt es für jeden Container: `RADARR_`, `SONARR_`, `PROWLARR_`, `SEERR_`, `INFINIDYSK_` und `RCLONE_NZBDAV_EXTRA_VOLUMES`.

## Updates

```bash
bash mediastack.sh self-update
```

1. Das Script lädt die neueste `mediastack.sh` von GitHub, prüft die Syntax und ersetzt sich selbst. Die alte Version bleibt als `mediastack.sh.bak` liegen.
2. **Deine `mediastack.conf` wird nie angefasst.** Neue Variablen haben im Script Standardwerte. Willst du einen davon ändern, trägst du die Variable einfach in deine Konfig ein (siehe `mediastack.conf.example`).
3. Danach läuft automatisch `update`:
   - Die Images werden aktualisiert.
   - Nur Container, deren Image oder Konfiguration sich geändert hat, werden neu angelegt. Alle anderen bleiben unangetastet.
   - Zugangsdaten und API-Keys kommen aus `secrets.env`, es wird also nichts erneut abgefragt.
   - Bestehende Einstellungen in den Apps werden nicht überschrieben, fehlende werden ergänzt.

Willst du nur die Images aktualisieren, ohne das Script zu ändern: `bash mediastack.sh update`.

Zurück zur alten Script-Version: `mv mediastack.sh.bak mediastack.sh`

> **Erkennung:** Jeder Container bekommt ein Label `mediastack.hash`, einen Fingerabdruck seiner Konfiguration. Container ohne dieses Label wurden nicht vom Script angelegt (oder von Version 1.0). `update` lässt sie in Ruhe. Mit `bash mediastack.sh recreate <name>` übernimmt das Script sie ausdrücklich.

### Umstieg von Version 1.0

Container aus Version 1.0 haben das Label noch nicht. Deshalb übernimmt sie das Script einmalig mit `recreate`:

```bash
bash mediastack.sh self-update
bash mediastack.sh recreate rclone-nzbdav prowlarr radarr sonarr jellyfin seerr
```

`infinidysk` nur hinzufügen, wenn das Script ihn auch angelegt hat. Die Daten bleiben in jedem Fall erhalten.

## Wichtige Hinweise

- **Image von InfiniDysk:** Standard ist `ghcr.io/infinidysk/infinidysk:latest`. Bitte prüfen und bei Bedarf über `IMG_INFINIDYSK` anpassen.
- **rclone:** siehe *rclone: Plugin oder Container*. Standard ist das Unraid-Plugin.
- **Mount-Propagation (Unraid-spezifisch):** Damit der Mount in Radarr, Sonarr und Jellyfin ankommt, muss `/mnt/addons/nzbdav` ein *shared*-Mountpunkt sein, und zwar **bevor** Docker startet. Unraid hat kein systemd, das das von sich aus erledigt. Deshalb:
  - legt das Script einen Unraid-Event-Hook an (`disks_mounted`, läuft nach dem Einhängen der Platten und vor Docker), Quelle: `/boot/config/plugins/mediastack/mount-prep.sh`
  - legt einen zweiten Hook an (`started`, läuft nach dem Start von Array und Docker), der den rclone-Mount einhängt, sobald InfiniDysk antwortet
  - ergänzt einen markierten Block in `/boot/config/go` (`# >>> mediastack v5`), der die Hooks bei jedem Boot installiert, den Boot-Wächter startet und den Watchdog-Cron lädt
  - prüft das Script bei jedem Lauf, ob der Mountpunkt *shared* ist. Wenn nicht, repariert es ihn und startet rclone, Radarr, Sonarr und Jellyfin neu.

  Zum Deinstallieren den Block aus der go-Datei und den Ordner `/boot/config/plugins/mediastack` entfernen.
- **Netzwerk:** Die Container sprechen über `http://<server-ip>:<port>` miteinander statt über ein eigenes Docker-Netz, denn Unraid löscht eigene Netze standardmäßig beim Neustart von Docker. Der Server sollte deshalb eine **feste IP** haben.
- **Keine Unraid-Vorlagen:** Die Container werden per `docker run` angelegt. Starten, Stoppen, Logs und WebUI funktionieren im Docker-Tab, *Edit* aber nicht. Änderungen deshalb in `mediastack.conf` vornehmen und `bash mediastack.sh update` ausführen.
- **Bestehende Container:** Gibt es schon einen Container mit gleichem Namen (z. B. `jellyfin`), wird er nicht angefasst. Die Jellyfin-Automatik funktioniert dann nur, wenn Benutzer und Passwort übereinstimmen.
- **Login für Radarr, Sonarr und Prowlarr:** Im LAN gibt es keinen Login (*Disabled for Local Addresses*), von außen gilt Benutzer und Passwort. Neuere Versionen verlangen dafür *Allowed Hosts*, also die Adressen, unter denen du die Apps aufrufst. Es zählt der Hostname im Browser, nicht die IP des Clients, und CIDR geht nicht. Automatisch eingetragen werden Server-IP, Hostname, `Hostname.local`, `localhost` und `127.0.0.1`. Weitere Adressen, etwa die Domain eines Reverse Proxys, kommen kommagetrennt in `ARR_ALLOWED_HOSTS` (Platzhalter wie `*.example.com` gehen). Fehlt eine Adresse, antwortet die App dort mit „Invalid Hostname“.
- **Sicherheit:** Die Apps sind ohne Reverse Proxy nur für das LAN gedacht. Für den Zugriff von außen bitte einen Reverse Proxy (z. B. Nginx Proxy Manager, SWAG) oder ein VPN (z. B. Tailscale, WireGuard) verwenden.

## Fehlersuche

| Problem | Lösung |
|---|---|
| `Invalid Hostname` beim Aufruf von Radarr/Sonarr/Prowlarr | Adresse fehlt in *Allowed Hosts* → in `ARR_ALLOWED_HOSTS` ergänzen, dann `bash mediastack.sh` ausführen |
| `Port … ist belegt` | Port in `mediastack.conf` ändern oder den anderen Container stoppen |
| Mount leer / nicht sichtbar | `bash mediastack.sh doctor` |
| WebDAV liefert nicht 207 | `bash mediastack.sh doctor` → Zugangsdaten neu eingeben |
| Importe in Radarr/Sonarr schlagen fehl | Kategorien in InfiniDysk (`movies,tv`) und Rclone Mount Directory (`/mnt/nzbdav`) prüfen |
| `.rclonelink`-Dateien statt Symlinks | rclone muss mit `--links` laufen (Standard im Script) |
| Seerr nicht eingerichtet | Einrichtung unter `:5055` kurz manuell durchklicken, Jellyfin-Host `http://<server-ip>:8096` |
