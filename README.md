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
bash mediastack.sh          # installieren/konfigurieren – erneut ausführbar, Vorhandenes wird übersprungen
bash mediastack.sh status   # Status der Container
bash mediastack.sh remove   # Container entfernen (Configs und Medien bleiben erhalten)
```

## Wichtige Hinweise

- **Image von InfiniDysk:** Standard ist `ghcr.io/infinidysk/infinidysk:latest`. Bitte prüfen und bei Bedarf über `IMG_INFINIDYSK` anpassen.
- **`/boot/config/go`:** Das Script ergänzt dort einen markierten Block (`# >>> mediastack`). Er macht den Mountpunkt nach einem Neustart wieder *shared*, damit der rclone-Mount in den anderen Containern ankommt. Zum Deinstallieren den Block einfach löschen.
- **Netzwerk:** Die Container sprechen über `http://<server-ip>:<port>` miteinander statt über ein eigenes Docker-Netz, denn Unraid löscht eigene Netze standardmäßig beim Neustart von Docker. Der Server sollte deshalb eine **feste IP** haben.
- **Keine Unraid-Vorlagen:** Die Container werden per `docker run` angelegt. Starten, Stoppen, Logs und WebUI funktionieren im Docker-Tab, *Edit* aber nicht. Änderungen also im Script bzw. in der Konfig vornehmen, den Container mit `docker rm -f <name>` entfernen und das Script erneut starten.
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
