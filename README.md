# Unraid Media Stack

Ein Script, das einen kompletten **Usenet-Streaming-Media-Stack** auf Unraid installiert, die Apps miteinander verbindet und so weit vorkonfiguriert, dass danach kaum noch Handarbeit nötig ist.

| App | Aufgabe | Port |
|---|---|---|
| **InfiniDysk** (NzbDAV-Fork) | Bindet NZBs als WebDAV ein, ohne sie herunterzuladen, und stellt eine SABnzbd-kompatible API bereit | 3000 |
| **rclone** | Hängt das WebDAV von InfiniDysk ins Dateisystem ein | – |
| **Prowlarr** | Verwaltet die Indexer und verteilt sie an Radarr/Sonarr | 9696 |
| **Radarr** | Filme | 7878 |
| **Sonarr** | Serien | 8989 |
| **Jellyfin** | Mediaserver | 8096 |
| **Seerr** | Anfragen für Filme und Serien | 5055 |
| **Recyclarr** | Überträgt die deutschen TRaSH-Guides-Profile in Radarr/Sonarr und gleicht sie täglich ab | – |

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

- Unraid 6.12 oder neuer, Array gestartet, Docker aktiviert
- Zugang zu einem Usenet-Provider und mindestens ein Usenet-Indexer
- Root-Zugang per SSH oder über das Web-Terminal
- Freie Ports: 3000, 5055, 7878, 8096, 8989, 9696

## Installation

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
bash mediastack.sh remove             # Container entfernen (Configs und Medien bleiben erhalten)
```

## TRaSH-Guides (deutsche Profile)

[Recyclarr](https://recyclarr.dev) überträgt die Qualitätsprofile und Custom Formats aus den [TRaSH-Guides](https://trash-guides.info) nach Radarr und Sonarr und hält sie aktuell.

Das Script macht dafür Folgendes:

1. Es lädt die offizielle Vorlage für das gewählte Profil aus [recyclarr/config-templates](https://github.com/recyclarr/config-templates) und trägt URL und API-Key ein. Das ergibt `appdata/recyclarr/configs/radarr.yml` und `sonarr.yml`.
2. Es startet den Container `recyclarr`. Er gleicht standardmäßig täglich ab (`RECYCLARR_SCHEDULE`).
3. Es führt den ersten Abgleich sofort aus. Danach gibt es in Radarr und Sonarr z. B. das Profil **[German] HD Bluray + WEB**.
4. Seerr fordert ab jetzt mit diesem Profil an.

Profil wählen (`TRASH_PROFILE` in `mediastack.conf`):

| Wert | Profil |
|---|---|
| `german-hd-bluray-web` *(Standard)* | 1080p (720p als Fallback), Bluray + WEB |
| `german-hd-remux-web` | 1080p, Remux + WEB |
| `german-uhd-bluray-web` | 2160p, Bluray + WEB |
| `german-uhd-bluray-web-alternative` | 2160p, Variante des UHD-Profils (siehe TRaSH-Guides) |
| `german-uhd-remux-web` | 2160p, Remux + WEB |
| `german-anime-hd-bluray-web` | Anime |

**Anpassen:** Die Dateien `appdata/recyclarr/configs/*.yml` gehören dir. Du kannst dort zusätzliche Custom-Format-Gruppen aktivieren, etwa Streaming-Dienste oder Movie Versions. Die Optionen stehen als Kommentare in der Datei. Das Script überschreibt die Dateien nie. Ein Abgleich von Hand geht mit `docker exec recyclarr recyclarr sync`.

**Profil wechseln:** `TRASH_PROFILE` ändern, die beiden `.yml` löschen, dann `bash mediastack.sh update` ausführen.

**Hinweise:**
- Filme und Serien, die schon in der Bibliothek sind, behalten ihr altes Profil. Du stellst sie in Radarr/Sonarr über *Bibliothek bearbeiten* (Mehrfachauswahl) um.
- Die Option `SEERR_USE_TRASH_PROFILE=true` stellt die Standard-Server in Seerr auf das `[German]`-Profil um. Mit `false` bleibt deine Auswahl in Seerr unangetastet.
- Recyclarr setzt `reset_unmatched_scores`. Eigene Bewertungen für Custom Formats, die im Profil nicht vorkommen, werden deshalb auf 0 zurückgesetzt.

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
- **`/boot/config/go`:** Das Script ergänzt dort einen markierten Block (`# >>> mediastack`). Er macht den Mountpunkt nach einem Neustart wieder *shared*, damit der rclone-Mount in den anderen Containern ankommt. Zum Deinstallieren den Block einfach löschen.
- **Netzwerk:** Die Container sprechen über `http://<server-ip>:<port>` miteinander statt über ein eigenes Docker-Netz, denn Unraid löscht eigene Netze standardmäßig beim Neustart von Docker. Der Server sollte deshalb eine **feste IP** haben.
- **Keine Unraid-Vorlagen:** Die Container werden per `docker run` angelegt. Starten, Stoppen, Logs und WebUI funktionieren im Docker-Tab, *Edit* aber nicht. Änderungen deshalb in `mediastack.conf` vornehmen und `bash mediastack.sh update` ausführen.
- **Bestehende Container:** Gibt es schon einen Container mit gleichem Namen (z. B. `jellyfin`), wird er nicht angefasst. Die Jellyfin-Automatik funktioniert dann nur, wenn Benutzer und Passwort übereinstimmen.
- **Sicherheit:** Die Apps sind ohne Reverse Proxy nur für das LAN gedacht. Für den Zugriff von außen bitte einen Reverse Proxy (z. B. Nginx Proxy Manager, SWAG) oder ein VPN (z. B. Tailscale, WireGuard) verwenden.

## Fehlersuche

| Problem | Lösung |
|---|---|
| `Port … ist belegt` | Port in `mediastack.conf` ändern oder den anderen Container stoppen |
| Mount nicht sichtbar | `docker logs rclone-nzbdav` · prüfen, ob `/dev/fuse` vorhanden ist · `grep nzbdav /proc/mounts` |
| WebDAV liefert nicht 207 | Zugangsdaten falsch → Zeilen `WEBDAV_*` in `secrets.env` löschen und Script neu starten |
| Importe in Radarr/Sonarr schlagen fehl | Kategorien in InfiniDysk (`movies,tv`) und Rclone Mount Directory (`/mnt/nzbdav`) prüfen |
| `.rclonelink`-Dateien statt Symlinks | rclone muss mit `--links` laufen (Standard im Script) |
| Seerr nicht eingerichtet | Einrichtung unter `:5055` kurz manuell durchklicken, Jellyfin-Host `http://<server-ip>:8096` |
