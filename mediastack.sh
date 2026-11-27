#!/bin/bash
# =============================================================================
#  mediastack.sh – Usenet-Streaming-Media-Stack für Unraid und Debian/Ubuntu
#
#  Installiert und verbindet:
#    InfiniDysk (NzbDAV-Fork) + rclone-WebDAV-Mount
#    Prowlarr, Radarr, Sonarr, Jellyfin, Seerr
#
#  Aufruf (als root bzw. mit sudo, Unraid-Terminal oder SSH):
#    bash mediastack.sh                 -> installieren + konfigurieren (idempotent)
#    bash mediastack.sh update          -> Images aktualisieren + geänderte Konfig übernehmen
#    bash mediastack.sh self-update     -> Script von GitHub holen, danach "update"
#    bash mediastack.sh recreate NAME.. -> einzelne Container neu anlegen
#    bash mediastack.sh status          -> Container-Status anzeigen
#    bash mediastack.sh doctor [--yes]  -> rclone-Mount prüfen + reparieren
#    bash mediastack.sh watchdog pause|resume -> Mount-Überwachung pausieren
#    bash mediastack.sh dashboard-status -> Status fürs Dashboard schreiben (läuft minütlich)
#    bash mediastack.sh remove          -> Container entfernen (Daten bleiben!)
#
#  Eigene Werte: entweder unten im Block "KONFIGURATION" ändern oder eine Datei
#  "mediastack.conf" neben das Script legen (wird automatisch geladen).
# =============================================================================
set -Eeuo pipefail
SCRIPT_VERSION="2.3.1"
REPO_RAW="https://raw.githubusercontent.com/kernelguru/unraid-media-stack-/main"

# ------------------------------- KONFIGURATION -------------------------------
# Plattform: auto (erkennt Unraid bzw. Debian/Ubuntu) | unraid | debian
PLATFORM="auto"

SERVER_IP=""                         # leer = automatisch erkennen
TZ="Europe/Berlin"
UMASK=002

# Leer = Standard der Plattform:
#                 Unraid                  Debian/Ubuntu
#   PUID/PGID     99 / 100                Benutzer hinter sudo, sonst 1000 / 1000
#   APPDATA       /mnt/user/appdata       /opt/mediastack
#   DATA          /mnt/user/data          /srv          (Medien: $DATA/media/{movies,tv})
#   MOUNT_HOST    /mnt/addons/nzbdav      /mnt/nzbdav
#   RCLONE_MODE   plugin                  systemd
PUID=""
PGID=""
APPDATA=""                           # Container-Configs
DATA=""                              # Medienbibliothek
MOUNT_HOST=""                        # rclone-Mount auf dem Host
MOUNT_CT="/mnt/nzbdav"               # derselbe Mount in allen Containern

INSTALL_DOCKER=true                  # Debian/Ubuntu: Docker aus dem offiziellen Repo installieren

# Hardware-Beschleunigung für Jellyfin:
#   auto  = erkennen (NVIDIA mit Docker-Runtime → nvenc, Intel → qsv, AMD → vaapi)
#   none | qsv | vaapi | nvenc
JELLYFIN_HWACCEL="auto"
JELLYFIN_HWACCEL_FORCE=false         # true = auch eine vorhandene Jellyfin-Einstellung überschreiben

ADMIN_USER="admin"                   # Login für Radarr/Sonarr/Prowlarr/Jellyfin/Seerr
ADMIN_PASS=""                        # leer = wird abgefragt
ADMIN_EMAIL="admin@mediastack.local" # nur für Seerr

# Radarr/Sonarr/Prowlarr: im LAN ohne Login. Neuere Versionen verlangen dafür
# "Allowed Hosts" = die Adressen, unter denen du die Apps aufrufst (Host-Header,
# keine Client-IPs, kein CIDR). Automatisch: Server-IP, Hostname, Hostname.local,
# localhost, 127.0.0.1. Eigene zusätzlich, kommagetrennt, z. B. Proxy-Domains:
#   ARR_ALLOWED_HOSTS="radarr.example.com,*.example.com"
ARR_ALLOWED_HOSTS=""

# Dashboard: kleine Webseite mit Links, API-Keys (verdeckt) und Status
DASHBOARD_ENABLED=true

LANG_CODE="de"                       # Jellyfin-UI/Metadaten
COUNTRY_CODE="DE"

CAT_MOVIES="movies"                  # Kategorien in InfiniDysk (SABnzbd-Tab)
CAT_TV="tv"
# rclone-Mount nach InfiniDysk-Doku (Guide "Mount WebDAV with rclone")
RCLONE_CACHE_SIZE="50G"              # --vfs-cache-max-size
RCLONE_CACHE_MAX_AGE="1w"            # --vfs-cache-max-age
RCLONE_READ_AHEAD="512M"             # --vfs-read-ahead (Puffer für hohe Bitraten)
# RC-Benachrichtigungen: InfiniDysk meldet neue/entfernte Dateien per
# vfs/forget an rclone. Dann darf der Verzeichnis-Cache lang sein (1w statt 20s).
# Nur einschalten, wenn InfiniDysk die RC-Daten auch kennt (s. README).
RCLONE_RC=false
P_RCLONE_RC=5572
# WebDAV über den Backend-Port 8080 von InfiniDysk (schneller als Port 3000).
# Host-Port, nur an 127.0.0.1 gebunden (rclone läuft auf dem Host).
P_WEBDAV=18080

# Wie rclone läuft (leer = Standard der Plattform):
#   plugin    = Unraid: rclone-Plugin aus den Community Apps (Waseh), Mount
#               direkt auf dem Host – unter Unraid der zuverlässige Weg
#   systemd   = Debian/Ubuntu: rclone vom Host als systemd-Dienst
#               (mediastack-mount.service)
#   container = Docker-Container rclone-nzbdav (nsenter in den Host-Namespace)
RCLONE_MODE=""
RCLONE_REMOTE="nzbdav"               # Remote-Name in der Plugin-Konfiguration
RCLONE_PLG_URL="https://raw.githubusercontent.com/Waseh/rclone-unraid/master/plugin/rclone.plg"
RCLONE_PLG_CONF="/boot/config/plugins/rclone/.rclone.conf"

# Images
IMG_INFINIDYSK="ghcr.io/infinidysk/infinidysk:latest"   # ggf. anpassen!
IMG_RCLONE="rclone/rclone:latest"
IMG_PROWLARR="lscr.io/linuxserver/prowlarr:latest"
IMG_RADARR="lscr.io/linuxserver/radarr:latest"
IMG_SONARR="lscr.io/linuxserver/sonarr:latest"
IMG_JELLYFIN="lscr.io/linuxserver/jellyfin:latest"
IMG_SEERR="ghcr.io/seerr-team/seerr:latest"
IMG_RECYCLARR="ghcr.io/recyclarr/recyclarr:8"    # "latest" wird nicht mehr gepflegt
IMG_DASHBOARD="nginx:alpine"

# Ports
P_INFINIDYSK=3000; P_PROWLARR=9696; P_RADARR=7878; P_DASHBOARD=8090
P_SONARR=8989;     P_JELLYFIN=8096; P_SEERR=5055

# TRaSH-Guides per Recyclarr (Qualitätsprofile + Custom Formats)
RECYCLARR_ENABLED=true
# TRaSH-Profile (beliebig viele, das erste ist das Haupt-Profil):
#   german-hd-bluray-web, german-hd-remux-web, german-uhd-bluray-web,
#   german-uhd-bluray-web-alternative, german-uhd-remux-web,
#   german-anime-hd-bluray-web
TRASH_PROFILES=()                    # leer = (german-hd-bluray-web german-uhd-bluray-web)
TRASH_PROFILE=""                     # alt (v1.2–1.8), wird noch ausgewertet
# Eigenes Profil "[German] Any": jede Qualität, aber nur mit deutscher Tonspur,
# Upgrades bis 1080p (Custom Formats/Scores wie [German] HD Bluray + WEB)
TRASH_ANY_GERMAN=true
RECYCLARR_SCHEDULE="@daily"          # automatischer Abgleich (Cron-Syntax)
SEERR_USE_TRASH_PROFILE=true         # Seerr fordert mit SEERR_PROFILE an
SEERR_PROFILE="[German] HD Bluray + WEB"

# Watchdog: prüft den rclone-Mount alle 5 Minuten und repariert ihn still
# (Meldungen im Unraid-Syslog unter "mediastack")
WATCHDOG_ENABLED=true
TEMPLATES_RAW="https://raw.githubusercontent.com/recyclarr/config-templates/master"

# Zusätzliche Volumes pro Container ("host:container[:optionen]")
# Gibt es für jeden Container: JELLYFIN_, RADARR_, SONARR_, PROWLARR_, SEERR_,
# INFINIDYSK_, RCLONE_NZBDAV_, RECYCLARR_EXTRA_VOLUMES
JELLYFIN_EXTRA_VOLUMES=(
  # "/mnt/user/Fotos:/data/fotos:ro"
)
RADARR_EXTRA_VOLUMES=()
SONARR_EXTRA_VOLUMES=()

# Optional: Usenet-Indexer, die automatisch in Prowlarr angelegt werden
# Format: "Name|https://indexer.tld|APIKEY"
INDEXERS=(
  # "NZBgeek|https://api.nzbgeek.info|DEIN_API_KEY"
)
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/mediastack.conf" ]] && source "$SCRIPT_DIR/mediastack.conf"
# Abwärtskompatibel: einzelnes TRASH_PROFILE aus älteren Konfigurationen
if (( ${#TRASH_PROFILES[@]} == 0 )); then
  if [[ -n $TRASH_PROFILE ]]; then TRASH_PROFILES=("$TRASH_PROFILE")
  else TRASH_PROFILES=(german-hd-bluray-web german-uhd-bluray-web); fi
fi

# ---- Plattform erkennen und Standardwerte setzen -------------------------------
if [[ $PLATFORM == auto ]]; then
  if [[ -f /etc/unraid-version ]]; then PLATFORM=unraid
  elif [[ -r /etc/os-release ]] && grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then PLATFORM=debian
  else PLATFORM=unknown; fi
fi
case $PLATFORM in
  unraid)
    : "${PUID:=99}" "${PGID:=100}" "${APPDATA:=/mnt/user/appdata}" "${DATA:=/mnt/user/data}"
    : "${MOUNT_HOST:=/mnt/addons/nzbdav}" "${RCLONE_MODE:=plugin}"
    LOGHINT="grep mediastack /var/log/syslog" ;;
  *)
    if [[ -z $PUID ]]; then
      if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] && id -u "$SUDO_USER" >/dev/null 2>&1; then
        PUID=$(id -u "$SUDO_USER"); PGID=$(id -g "$SUDO_USER")
      else PUID=1000; fi
    fi
    : "${PGID:=$PUID}" "${APPDATA:=/opt/mediastack}" "${DATA:=/srv}"
    : "${MOUNT_HOST:=/mnt/nzbdav}" "${RCLONE_MODE:=systemd}"
    LOGHINT="journalctl -t mediastack" ;;
esac
# rclone-Binary und -Konfiguration je nach Modus
case $RCLONE_MODE in
  plugin)  RCLONE_BIN=/usr/sbin/rcloneorig; RCLONE_CONF=$RCLONE_PLG_CONF ;;
  systemd) RCLONE_BIN=/usr/bin/rclone;      RCLONE_CONF=$APPDATA/rclone-nzbdav/rclone.conf ;;
  *)       RCLONE_BIN=/usr/sbin/rcloneorig; RCLONE_CONF=$APPDATA/rclone-nzbdav/rclone.conf ;;
esac
host_mode() { [[ $RCLONE_MODE == plugin || $RCLONE_MODE == systemd ]]; }

STATE_DIR="$APPDATA/mediastack"
SECRETS="$STATE_DIR/secrets.env"
CONTAINERS=(dashboard seerr jellyfin recyclarr sonarr radarr prowlarr rclone-nzbdav infinidysk)

# ------------------------------- Hilfsfunktionen -----------------------------
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
log()  { echo "${c_g}==>${c_0} $*"; }
warn() { echo "${c_y}[!]${c_0} $*" >&2; }
die()  { echo "${c_r}[x]${c_0} $*" >&2; exit 1; }
trap 'die "Abbruch in Zeile $LINENO: $BASH_COMMAND"' ERR

jq() {  # Unraid/Debian: meist installiert – sonst per Container
  if command -v jq >/dev/null 2>&1; then command jq "$@"
  else docker run --rm -i ghcr.io/jqlang/jq:latest "$@"; fi
}

genkey() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

exists() { docker container inspect "$1" >/dev/null 2>&1; }

port_busy() { (echo >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; }

wait_http() {  # url [sekunden] – wartet auf 2xx/3xx/401 (z. B. nicht auf 503 "startet noch")
  local url=$1 t=${2:-300} i=0 code
  printf '    warte auf %s ' "$url"
  while :; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || true)
    [[ $code =~ ^[23] || $code == 401 ]] && break
    (( i++ >= t/3 )) && { echo " (HTTP ${code:-keine Antwort})"; return 1; }
    printf '.'; sleep 3
  done; echo " ok"
}

# Container sauber stoppen (rclone kann so den Mount aushängen), dann löschen
remove_ct() { docker stop -t 30 "$1" >/dev/null 2>&1 || true; docker rm -f "$1" >/dev/null; }

# Mountpunkt vorbereiten: toten FUSE-Mount aufräumen, Bind-Mount "shared" machen
prep_mount() {
  if awk -v m="$MOUNT_HOST" '$2==m && /fuse/' /proc/mounts | grep -q . \
     && ! ls "$MOUNT_HOST" >/dev/null 2>&1; then
    warn "Toter Mount unter $MOUNT_HOST – wird aufgeräumt"
    umount -l "$MOUNT_HOST" 2>/dev/null || fusermount -uz "$MOUNT_HOST" 2>/dev/null || true
  fi
  mkdir -p "$MOUNT_HOST"
  # Debian/Ubuntu: systemd macht / bereits "shared" – kein Bind-Mount nötig
  [[ $PLATFORM == unraid ]] || return 0
  # Ohne "shared" kommt der Mount aus dem rclone-Container nicht auf dem Host an
  if ! mountpoint -q "$MOUNT_HOST" \
     || ! findmnt -no PROPAGATION --target "$MOUNT_HOST" 2>/dev/null | head -1 | grep -q shared; then
    mountpoint -q "$MOUNT_HOST" || mount --bind "$MOUNT_HOST" "$MOUNT_HOST"
    mount --make-shared "$MOUNT_HOST"
    MOUNT_FIXED=1
  fi
}
MOUNT_FIXED=0

# HTTP-Aufruf mit Fehlertext statt stillem Scheitern
# http METHOD URL [DATA] [extra curl args...]
http() {
  local m=$1 u=$2 d=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$m" -H "Content-Type: application/json" -w $'\n%{http_code}')
  [[ -n $d ]] && args+=(--data "$d")
  local out code
  out=$(curl "${args[@]}" "$@" "$u") || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if (( code >= 400 )); then warn "HTTP $code bei $m $u: ${out:0:300}"; return 1; fi
  printf '%s' "$out"
}
arr() { local k=$1; shift; local m=$1 u=$2 d=${3:-}; http "$m" "$u" "$d" -H "X-Api-Key: $k"; }

save_secret() {  # name wert
  touch "$SECRETS"; chmod 600 "$SECRETS"
  sed -i "/^$1=/d" "$SECRETS"
  printf '%s=%q\n' "$1" "$2" >> "$SECRETS"
}

# docker run mit Unraid-Labels (WebUI-Link + Icon im Docker-Tab).
# Jeder Container bekommt ein Label "mediastack.hash" mit einem Fingerabdruck
# seiner Konfiguration. So erkennt "update", ob er neu angelegt werden muss.
run_ct() {  # name webui-port icon-url -- docker-args...
  local name=$1 port=$2 icon=$3; shift 4

  # Extra-Volumes aus <NAME>_EXTRA_VOLUMES
  local var="${name//-/_}"; var="${var^^}_EXTRA_VOLUMES"
  local extra=() v host
  if declare -p "$var" >/dev/null 2>&1; then
    local ref="$var[@]"
    for v in "${!ref}"; do
      host=${v%%:*}
      [[ -e $host ]] || die "$var: Host-Pfad '$host' existiert nicht – bitte zuerst anlegen."
      extra+=(-v "$v")
    done
  fi

  local hash; hash=$(printf '%s\0' "$TZ" "${extra[@]}" "$@" | md5sum | cut -c1-12)

  if exists "$name"; then
    local old; old=$(docker inspect -f '{{index .Config.Labels "mediastack.hash"}}' "$name")
    [[ $old == "<no value>" ]] && old=""
    if [[ -z $old ]]; then
      log "$name existiert (nicht vom Script verwaltet) – übersprungen"
      return 0
    fi
    local cur_img new_img
    cur_img=$(docker inspect -f '{{.Image}}' "$name")
    new_img=$(docker image inspect -f '{{.Id}}' "$(docker inspect -f '{{.Config.Image}}' "$name")" 2>/dev/null || echo "$cur_img")
    if [[ $old == "$hash" && $cur_img == "$new_img" ]]; then
      log "$name ist aktuell"; return 0
    fi
    if (( APPLY )); then
      log "$name: Konfiguration/Image geändert → wird neu angelegt (Daten bleiben)"
      remove_ct "$name"
      [[ $name == rclone-nzbdav ]] && prep_mount
    else
      warn "$name: Konfiguration oder Image geändert – übernehmen mit: bash $SELF_NAME update"
      return 0
    fi
  fi

  if [[ -n $port ]] && port_busy "$port"; then die "Port $port ist belegt (für $name)"; fi
  log "Starte $name"
  local labels=(--label net.unraid.docker.managed=dockerman --label "mediastack.hash=$hash")
  [[ -n $port ]] && labels+=(--label "net.unraid.docker.webui=http://[IP]:[PORT:$port]/")
  [[ -n $icon ]] && labels+=(--label "net.unraid.docker.icon=$icon")
  docker run -d --name "$name" --restart unless-stopped \
    --log-opt max-size=10m --log-opt max-file=3 \
    -e TZ="$TZ" "${labels[@]}" "${extra[@]}" "$@" >/dev/null
}

ICON="https://cdn.jsdelivr.net/gh/selfhst/icons/png"

# ---- mediastack.conf mit Standardwerten anlegen (nur wenn sie fehlt) ----------
# Alle Einstellungen stehen auskommentiert mit dem Wert, den das Script gerade
# verwendet (für diese Plattform). Zum Ändern: "#" entfernen, Wert anpassen,
# danach "bash mediastack.sh update".
CONF_FILE="$SCRIPT_DIR/mediastack.conf"
write_default_conf() {
  [[ -e $CONF_FILE ]] && return 0
  local q='"'
  conf_arr() { local a; a=$(printf ' %s' "$@"); echo "(${a# })"; }
  local tmp="$CONF_FILE.tmp.$$"
  cat > "$tmp" <<EOF
# =============================================================================
#  mediastack.conf – eigene Einstellungen für mediastack.sh
#
#  Automatisch angelegt am $(date '+%d.%m.%Y %H:%M') (Script $SCRIPT_VERSION, Plattform: $PLATFORM).
#  Jede Zeile zeigt den aktuell verwendeten Standardwert. Zum Ändern das "#"
#  am Zeilenanfang entfernen, Wert anpassen und danach ausführen:
#      bash mediastack.sh update
#  Diese Datei wird von self-update und update nie überschrieben.
# =============================================================================

# ---- Plattform & System -------------------------------------------------------
#PLATFORM="$PLATFORM"                 # auto | unraid | debian
#SERVER_IP="$SERVER_IP"               # leer = automatisch erkennen
#TZ="$TZ"
#PUID=$PUID
#PGID=$PGID
#UMASK=$UMASK
#INSTALL_DOCKER=$INSTALL_DOCKER       # Debian/Ubuntu: Docker aus dem offiziellen Repo

# ---- Pfade --------------------------------------------------------------------
#APPDATA="$APPDATA"                   # Container-Configs
#DATA="$DATA"                         # Medien liegen in \$DATA/media/{movies,tv}
#MOUNT_HOST="$MOUNT_HOST"             # rclone-Mount auf dem Host
#MOUNT_CT="$MOUNT_CT"                 # derselbe Mount in den Containern

# ---- Zugangsdaten -------------------------------------------------------------
#ADMIN_USER="$ADMIN_USER"
#ADMIN_PASS=""                        # leer = wird abgefragt bzw. aus secrets.env
#ADMIN_EMAIL="$ADMIN_EMAIL"           # nur für Seerr
# Zusätzliche Adressen für Radarr/Sonarr/Prowlarr (z. B. Reverse-Proxy-Domains),
# kommagetrennt; Server-IP und Hostname sind automatisch enthalten
#ARR_ALLOWED_HOSTS="$ARR_ALLOWED_HOSTS"

# ---- Jellyfin -----------------------------------------------------------------
#LANG_CODE="$LANG_CODE"
#COUNTRY_CODE="$COUNTRY_CODE"
#JELLYFIN_HWACCEL="$JELLYFIN_HWACCEL" # auto | none | qsv | vaapi | nvenc
#JELLYFIN_HWACCEL_FORCE=$JELLYFIN_HWACCEL_FORCE

# ---- InfiniDysk & rclone ------------------------------------------------------
#CAT_MOVIES="$CAT_MOVIES"
#CAT_TV="$CAT_TV"
#RCLONE_MODE="$RCLONE_MODE"           # plugin (Unraid) | systemd (Debian) | container
#RCLONE_REMOTE="$RCLONE_REMOTE"
#RCLONE_CACHE_SIZE="$RCLONE_CACHE_SIZE"
#RCLONE_CACHE_MAX_AGE="$RCLONE_CACHE_MAX_AGE"
#RCLONE_READ_AHEAD="$RCLONE_READ_AHEAD"
#RCLONE_RC=$RCLONE_RC                 # erst true, wenn InfiniDysk die RC-Daten kennt (README)
#P_RCLONE_RC=$P_RCLONE_RC
#P_WEBDAV=$P_WEBDAV                   # Host-Port für InfiniDysk-Backend (8080)

# ---- TRaSH-Guides / Recyclarr -------------------------------------------------
#RECYCLARR_ENABLED=$RECYCLARR_ENABLED
#TRASH_PROFILES=$(conf_arr "${TRASH_PROFILES[@]}")
#TRASH_ANY_GERMAN=$TRASH_ANY_GERMAN
#RECYCLARR_SCHEDULE="$RECYCLARR_SCHEDULE"
#SEERR_USE_TRASH_PROFILE=$SEERR_USE_TRASH_PROFILE
#SEERR_PROFILE="$SEERR_PROFILE"

# ---- Watchdog & Dashboard -----------------------------------------------------
#WATCHDOG_ENABLED=$WATCHDOG_ENABLED
#DASHBOARD_ENABLED=$DASHBOARD_ENABLED  # Seite ohne Login – nur im LAN!

# ---- Ports --------------------------------------------------------------------
#P_INFINIDYSK=$P_INFINIDYSK
#P_PROWLARR=$P_PROWLARR
#P_RADARR=$P_RADARR
#P_SONARR=$P_SONARR
#P_JELLYFIN=$P_JELLYFIN
#P_SEERR=$P_SEERR
#P_DASHBOARD=$P_DASHBOARD

# ---- Images -------------------------------------------------------------------
#IMG_INFINIDYSK="$IMG_INFINIDYSK"
#IMG_RCLONE="$IMG_RCLONE"
#IMG_PROWLARR="$IMG_PROWLARR"
#IMG_RADARR="$IMG_RADARR"
#IMG_SONARR="$IMG_SONARR"
#IMG_JELLYFIN="$IMG_JELLYFIN"
#IMG_SEERR="$IMG_SEERR"
#IMG_RECYCLARR="$IMG_RECYCLARR"
#IMG_DASHBOARD="$IMG_DASHBOARD"

# ---- Zusätzliche Volumes ("host:container[:optionen]") ------------------------
# Gibt es für jeden Container: JELLYFIN_, RADARR_, SONARR_, PROWLARR_, SEERR_,
# INFINIDYSK_, RCLONE_NZBDAV_, RECYCLARR_, DASHBOARD_EXTRA_VOLUMES
#JELLYFIN_EXTRA_VOLUMES=(
#  "/pfad/auf/dem/host:/data/fotos:ro"
#)
#RADARR_EXTRA_VOLUMES=()
#SONARR_EXTRA_VOLUMES=()

# ---- Usenet-Indexer automatisch in Prowlarr anlegen ---------------------------
# Format: "Name|https://indexer.tld|APIKEY"
#INDEXERS=(
#  ${q}NZBgeek|https://api.nzbgeek.info|DEIN_API_KEY${q}
#)
EOF
  # nur eine vollständig geschriebene Datei übernehmen
  if [[ -s $tmp ]] && bash -n "$tmp"; then
    chmod 600 "$tmp"; mv -f "$tmp" "$CONF_FILE"
  else
    rm -f "$tmp"; unset -f conf_arr; warn "mediastack.conf konnte nicht angelegt werden"; return 0
  fi
  unset -f conf_arr
  log "mediastack.conf mit Standardwerten angelegt: $CONF_FILE"
}

# ---- Allowed Hosts für Radarr/Sonarr/Prowlarr ------------------------------------
arr_allowed_hosts() {
  local h=("$SERVER_IP" localhost 127.0.0.1) hn extra
  hn=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
  [[ -n $hn ]] && h+=("$hn" "$hn.local")
  IFS=',; ' read -r -a extra <<<"$ARR_ALLOWED_HOSTS"
  h+=("${extra[@]}")
  printf '%s\n' "${h[@]}" | awk 'NF && !seen[tolower($0)]++' | paste -sd, -
}

# ---- Dashboard ------------------------------------------------------------------
DASH_DIR="$STATE_DIR/dashboard"

# Ergebnis der letzten doctor/watchdog-Prüfung merken (Detailtext bei Fehlern)
# und status.json sofort aktualisieren
write_mount_status() {  # rc [detail]
  [[ $DASHBOARD_ENABLED == true && -d $DASH_DIR ]] || return 0
  jq -n --arg ok "$([[ $1 == 0 ]] && echo true || echo false)" --arg d "${2:-}" --arg t "$(date -Iseconds)" \
     '{ok: ($ok == "true"), detail: $d, checked: $t}' > "$DASH_DIR/.doctor.json.tmp" \
  && mv -f "$DASH_DIR/.doctor.json.tmp" "$DASH_DIR/.doctor.json"
  write_status_json
}

# status.json für das Dashboard – wird serverseitig erzeugt (minütlich per
# Cron/Timer), damit die Seite auch über HTTPS/Reverse Proxy funktioniert.
# Die Apps werden über 127.0.0.1 geprüft (in den Allowed Hosts enthalten).
DASH_CHECKS=("Seerr|$P_SEERR|/api/v1/status" "Jellyfin|$P_JELLYFIN|/health" "Radarr|$P_RADARR|/ping"
             "Sonarr|$P_SONARR|/ping" "Prowlarr|$P_PROWLARR|/ping" "InfiniDysk|$P_INFINIDYSK|/")
write_status_json() {
  [[ $DASHBOARD_ENABLED == true && -d $DASH_DIR ]] || return 0
  local e name port path code apps='{}' mok=false detail="" doc='{}'
  for e in "${DASH_CHECKS[@]}"; do
    IFS='|' read -r name port path <<<"$e"
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$port$path" 2>/dev/null || true)
    apps=$(jq -c --arg n "$name" --argjson up "$([[ $code =~ ^[2-4][0-9][0-9]$ ]] && echo true || echo false)" \
           '. + {($n): $up}' <<<"$apps")
  done
  if host_healthy 2>/dev/null; then mok=true
  else
    [[ -f $DASH_DIR/.doctor.json ]] && detail=$(jq -r 'select(.ok|not) | .detail // empty' "$DASH_DIR/.doctor.json" 2>/dev/null || true)
    [[ -n $detail ]] || detail="Mount leer oder nicht vorhanden"
  fi
  [[ -f $DASH_DIR/.doctor.json ]] && doc=$(cat "$DASH_DIR/.doctor.json")
  jq -n --argjson apps "$apps" --argjson ok "$mok" --arg d "$detail" --arg m "$MOUNT_HOST" \
        --arg t "$(date -Iseconds)" --argjson doc "$doc" \
     '{checked: $t, apps: $apps, mount_ok: $ok, detail: (if $ok then "" else $d end), path: $m,
       watchdog_checked: ($doc.checked // null)}' > "$DASH_DIR/status.json.tmp" \
  && chmod 644 "$DASH_DIR/status.json.tmp" && mv -f "$DASH_DIR/status.json.tmp" "$DASH_DIR/status.json"
}

# Minütlicher Status-Job: Unraid per Cron (dynamix-Ordner), sonst systemd-Timer
DASH_CRON=/boot/config/plugins/dynamix/mediastack-dashboard.cron
DASH_SERVICE=/etc/systemd/system/mediastack-dashboard.service
DASH_TIMER=/etc/systemd/system/mediastack-dashboard.timer
install_dashboard_job() {
  if [[ $PLATFORM == unraid ]]; then
    if [[ $DASHBOARD_ENABLED == true ]]; then
      {
        echo "# mediastack: Dashboard-Status jede Minute"
        printf '* * * * * [ -f %q ] && bash %q dashboard-status >/dev/null 2>&1\n' "$SELF" "$SELF"
      } > "$DASH_CRON"
    else
      rm -f "$DASH_CRON"
    fi
    /usr/local/sbin/update_cron >/dev/null 2>&1 || true
    return 0
  fi
  if [[ $DASHBOARD_ENABLED == true ]]; then
    cat > "$DASH_SERVICE" <<EOF
[Unit]
Description=mediastack: Dashboard-Status schreiben

[Service]
Type=oneshot
ExecStart=/bin/bash $SELF dashboard-status
EOF
    cat > "$DASH_TIMER" <<EOF
[Unit]
Description=mediastack: Dashboard-Status jede Minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now mediastack-dashboard.timer >/dev/null 2>&1 || true
  else
    systemctl disable --now mediastack-dashboard.timer >/dev/null 2>&1 || true
    rm -f "$DASH_SERVICE" "$DASH_TIMER"; systemctl daemon-reload 2>/dev/null || true
  fi
}

write_dashboard() {
  mkdir -p "$DASH_DIR"
  local seerr_key=""
  [[ -f $APPDATA/seerr/settings.json ]] && seerr_key=$(jq -r '.main.apiKey // empty' "$APPDATA/seerr/settings.json" 2>/dev/null || true)
  jq -n --arg ip "$SERVER_IP" --arg v "$SCRIPT_VERSION" --arg t "$(date '+%d.%m.%Y %H:%M')" \
        --arg icon "$ICON" --arg plat "$PLATFORM" \
        --arg pse "$P_SEERR" --arg pjf "$P_JELLYFIN" --arg pra "$P_RADARR" \
        --arg pso "$P_SONARR" --arg ppr "$P_PROWLARR" --arg pnd "$P_INFINIDYSK" \
        --arg kse "$seerr_key" --arg kjf "${JF_KEY:-}" --arg kra "${KEY_RADARR:-}" \
        --arg kso "${KEY_SONARR:-}" --arg kpr "${KEY_PROWLARR:-}" --arg knd "${NZBDAV_API_KEY:-}" '
    def app(n; d; p; ping; ic; k): {name:n, desc:d, url:"http://\($ip):\(p)/", ping:"http://\($ip):\(p)\(ping)", icon:"\($icon)/\(ic).png", key:k};
    {generated:$t, version:$v, platform:$plat, apps:[
      app("Seerr";      "Filme & Serien anfragen";     $pse; "/api/v1/status"; "seerr";     $kse),
      app("Jellyfin";   "Mediaserver";                 $pjf; "/health";        "jellyfin";  $kjf),
      app("Radarr";     "Filme";                       $pra; "/ping";          "radarr";    $kra),
      app("Sonarr";     "Serien";                      $pso; "/ping";          "sonarr";    $kso),
      app("Prowlarr";   "Indexer";                     $ppr; "/ping";          "prowlarr";  $kpr),
      app("InfiniDysk"; "Usenet-Streaming";          $pnd; "/";              "nzbget";    $knd)
    ]}' > "$DASH_DIR/apps.json"
  chmod 644 "$DASH_DIR/apps.json"

  cat > "$DASH_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Media-Stack</title>
<style>
  :root { --bg:#f4f5f7; --card:#fff; --text:#1d2129; --muted:#6b7280; --line:#e5e7eb;
          --ok:#16a34a; --bad:#dc2626; --wait:#9ca3af; --accent:#2563eb; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0f1115; --card:#181b21; --text:#e5e7eb; --muted:#9ca3af; --line:#262a33; --accent:#60a5fa; }
  }
  * { box-sizing:border-box; }
  body { margin:0; font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; background:var(--bg); color:var(--text); }
  main { max-width:960px; margin:0 auto; padding:24px 16px 40px; }
  header { display:flex; align-items:baseline; justify-content:space-between; gap:12px; flex-wrap:wrap; margin-bottom:16px; }
  h1 { font-size:22px; margin:0; }
  .meta { color:var(--muted); font-size:13px; }
  .mount { display:flex; align-items:center; gap:10px; background:var(--card); border:1px solid var(--line);
           border-radius:12px; padding:12px 14px; margin-bottom:16px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:14px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px; display:flex; flex-direction:column; gap:10px; }
  .top { display:flex; align-items:center; gap:12px; }
  .top img { width:40px; height:40px; border-radius:8px; object-fit:contain; }
  .name { font-weight:600; font-size:16px; }
  .desc { color:var(--muted); font-size:13px; }
  .dot { width:10px; height:10px; border-radius:50%; background:var(--wait); flex:none; margin-left:auto; }
  .dot.ok { background:var(--ok); } .dot.bad { background:var(--bad); }
  .mount .dot { margin-left:0; }
  a.open { color:var(--accent); text-decoration:none; font-size:14px; word-break:break-all; }
  a.open:hover { text-decoration:underline; }
  .key { display:flex; align-items:center; gap:6px; border-top:1px solid var(--line); padding-top:10px; }
  .key code { flex:1; font:13px ui-monospace,SFMono-Regular,Menlo,monospace; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .key .label { color:var(--muted); font-size:12px; }
  button { border:1px solid var(--line); background:transparent; color:var(--text); border-radius:8px; padding:4px 8px; font-size:13px; cursor:pointer; }
  button:hover { border-color:var(--accent); }
  footer { color:var(--muted); font-size:12px; margin-top:20px; text-align:center; }
</style>
</head>
<body>
<main>
  <header>
    <h1>Media-Stack</h1>
    <span class="meta" id="meta"></span>
  </header>
  <div class="mount"><span class="dot" id="mdot"></span><span id="mtext">rclone-Mount: Status wird geladen …</span></div>
  <div class="grid" id="grid"></div>
  <footer id="foot">Status wird vom Server jede Minute geprüft</footer>
</main>
<script>
const MASK = '••••••••••••••••';
const grid = document.getElementById('grid');

function copyText(t) {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(t);
  const ta = document.createElement('textarea'); ta.value = t; ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta); ta.select(); try { document.execCommand('copy'); } finally { ta.remove(); }
  return Promise.resolve();
}

function card(a, i) {
  const el = document.createElement('div'); el.className = 'card';
  el.innerHTML = `
    <div class="top"><img alt="" src="${a.icon}" onerror="this.style.visibility='hidden'">
      <div><div class="name"></div><div class="desc"></div></div><span class="dot" id="d${i}" title="wird geprüft"></span></div>
    <a class="open" target="_blank" rel="noopener"></a>`;
  el.querySelector('.name').textContent = a.name;
  el.querySelector('.desc').textContent = a.desc;
  const link = el.querySelector('a.open'); link.href = a.url; link.textContent = a.url;
  if (a.key) {
    const k = document.createElement('div'); k.className = 'key';
    k.innerHTML = '<span class="label">API-Key</span><code></code><button class="show" title="Anzeigen">👁</button><button class="copy">Kopieren</button>';
    const code = k.querySelector('code'); code.textContent = MASK;
    k.querySelector('.show').onclick = () => { code.textContent = code.textContent === MASK ? a.key : MASK; };
    const cb = k.querySelector('.copy');
    cb.onclick = () => copyText(a.key).then(() => { cb.textContent = 'Kopiert ✓'; setTimeout(() => cb.textContent = 'Kopieren', 1500); });
    el.appendChild(k);
  }
  return el;
}

// Status kommt vollständig vom Server (status.json, minütlich erzeugt).
// Kein Zugriff vom Browser auf die Apps -> funktioniert auch über HTTPS/Proxy.
async function refreshStatus(apps) {
  const dot = document.getElementById('mdot'), txt = document.getElementById('mtext');
  let s;
  try { s = await (await fetch('status.json', { cache: 'no-store' })).json(); }
  catch {
    dot.className = 'dot'; txt.textContent = 'Status: noch keine Prüfung vorhanden';
    apps.forEach((a, i) => { const d = document.getElementById('d' + i); d.className = 'dot'; d.title = 'unbekannt'; });
    return;
  }
  const when = new Date(s.checked), age = (Date.now() - when.getTime()) / 1000, stale = age > 300;
  const whenTxt = when.toLocaleString('de-DE');
  apps.forEach((a, i) => {
    const d = document.getElementById('d' + i), up = s.apps ? s.apps[a.name] : undefined;
    if (stale || up === undefined) { d.className = 'dot'; d.title = 'unbekannt'; return; }
    d.className = 'dot ' + (up ? 'ok' : 'bad'); d.title = up ? 'online' : 'nicht erreichbar';
  });
  dot.className = 'dot ' + (stale ? '' : (s.mount_ok ? 'ok' : 'bad'));
  txt.textContent = s.mount_ok ? `rclone-Mount ${s.path}: in Ordnung · geprüft ${whenTxt}`
                               : `rclone-Mount ${s.path}: ${s.detail || 'Problem'} · geprüft ${whenTxt}`;
  document.getElementById('foot').textContent = stale
    ? `Status veraltet (letzte Prüfung ${whenTxt}) – läuft der Status-Job auf dem Server?`
    : 'Status wird vom Server jede Minute geprüft';
}

fetch('apps.json', { cache: 'no-store' }).then(r => r.json()).then(cfg => {
  document.getElementById('meta').textContent = `mediastack ${cfg.version} · ${cfg.platform} · erzeugt ${cfg.generated}`;
  cfg.apps.forEach((a, i) => grid.appendChild(card(a, i)));
  refreshStatus(cfg.apps);
  setInterval(() => refreshStatus(cfg.apps), 30000);
});
</script>
</body>
</html>
HTML
  chmod 644 "$DASH_DIR/index.html"
}

# ---- Radarr: Profil-Sprache für "[German] Any" ----------------------------------
# Die Sprache regeln bei den [German]-Profilen die Custom Formats; die
# Profil-Sprache muss deshalb "Any" sein (wie in den TRaSH-Profilen). Recyclarr v8
# kann die Sprache nur für TRaSH-Profile setzen, nicht für eigene – daher hier.
# Mit "Original" lehnt Radarr deutsche Releases englischer Originale ab.
ANY_LANG_PROFILE="[German] Any"
radarr_fix_profile_language() {  # [quiet]
  local key url profiles id name lang body
  key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/radarr/config.xml" 2>/dev/null)
  [[ -n $key && -n $SERVER_IP ]] || return 0
  url="http://$SERVER_IP:$P_RADARR/api/v3"
  profiles=$(curl -s -m 10 -H "X-Api-Key: $key" "$url/qualityprofile") || return 0
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$profiles" || return 0
  while IFS=$'\t' read -r id name lang; do
    [[ -n $id ]] || continue
    if [[ $name == "$ANY_LANG_PROFILE" ]]; then
      [[ $lang == Any ]] && continue
      body=$(jq -c --argjson id "$id" '.[] | select(.id == $id) | .language = {id: -1, name: "Any"}' <<<"$profiles")
      if curl -s -o /dev/null -m 10 -w '%{http_code}' -X PUT -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
           --data "$body" "$url/qualityprofile/$id" | grep -q '^2'; then
        dmsg "  Radarr: Sprache von „$name“ von „$lang“ auf „Any“ gesetzt"
      else
        dmsg "  Radarr: Sprache von „$name“ konnte nicht gesetzt werden"
      fi
    elif [[ $name == "[German]"* && $lang != Any && ${1:-} != quiet ]]; then
      warn "  Radarr: Profil „$name“ hat Sprache „$lang“ statt „Any“ – deutsche Releases englischer Filme werden abgelehnt"
    fi
  done < <(jq -r '.[] | [.id, .name, (.language.name // "?")] | @tsv' <<<"$profiles")
}

# ------------------------------- Mount-Diagnose / Reparatur ------------------
detect_ip() {
  [[ -n $SERVER_IP ]] || SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
}

# WebDAV-URL wählen: Backend-Port (empfohlen) oder Frontend-Port 3000 als Fallback
detect_dav() {
  local code
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X PROPFIND -H 'Depth: 0' \
         "http://127.0.0.1:$P_WEBDAV/" 2>/dev/null || true)
  if [[ $code =~ ^[2-4][0-9][0-9]$ ]]; then
    DAV_URL="http://127.0.0.1:$P_WEBDAV/"; DAV_BACKEND=1
  else
    DAV_URL="http://$SERVER_IP:$P_INFINIDYSK/"; DAV_BACKEND=0
  fi
}

# Mount-Flags laut InfiniDysk-Doku; mit RC: langer Verzeichnis-Cache
build_rclone_flags() {
  # --allow-non-empty: Der Mountpunkt ist ein shared-Bind-Mount (für die
  # Propagation in die Container). Neuere rclone-Versionen verweigern sonst
  # mit "directory already mounted".
  RCLONE_FLAGS=(--allow-other --allow-non-empty --links --use-cookies
    --uid="$PUID" --gid="$PGID" --umask="$UMASK"
    --vfs-cache-mode=full --vfs-cache-max-size="$RCLONE_CACHE_SIZE"
    --vfs-cache-max-age="$RCLONE_CACHE_MAX_AGE" --buffer-size=0
    --vfs-read-ahead="$RCLONE_READ_AHEAD")
  if [[ $RCLONE_RC == true ]]; then
    RCLONE_FLAGS+=(--dir-cache-time=1w --poll-interval=0
      --rc --rc-addr=":$P_RCLONE_RC" --rc-user=rclone --rc-pass="${RC_PASS:-}")
  else
    RCLONE_FLAGS+=(--dir-cache-time=20s)
  fi
}

# Aktuell eingetragene WebDAV-URL des rclone-Remotes
conf_url() {
  if [[ $RCLONE_MODE == plugin ]]; then
    "$RCLONE_BIN" --config "$RCLONE_PLG_CONF" config show "$RCLONE_REMOTE" 2>/dev/null | sed -n 's/^url *= *//p'
  else
    sed -n 's/^url *= *//p' "$APPDATA/rclone-nzbdav/rclone.conf" 2>/dev/null
  fi
}

write_rclone_conf() {
  local dir="$APPDATA/rclone-nzbdav" obscured
  mkdir -p "$dir/cache"
  obscured=$(docker run --rm "$IMG_RCLONE" obscure "${WEBDAV_PASS:-}")
  cat > "$dir/rclone.conf" <<EOF
[nzbdav]
type = webdav
url = ${DAV_URL:-http://$SERVER_IP:$P_INFINIDYSK/}
vendor = other
user = ${WEBDAV_USER:-}
pass = $obscured
EOF
  chmod 600 "$dir/rclone.conf"
}

# ---- rclone über das Unraid-Plugin ------------------------------------------
# Das Plugin installiert das echte Binary als /usr/sbin/rcloneorig und einen
# Wrapper /usr/sbin/rclone, der immer --config $RCLONE_PLG_CONF setzt.
prclone() { "$RCLONE_BIN" --config "$RCLONE_CONF" "$@"; }

# ---- Debian/Ubuntu: Pakete, Docker, rclone, NVIDIA-Toolkit ---------------------
apt_install() {  # nur fehlende Pakete installieren
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  (( ${#missing[@]} )) || return 0
  log "Installiere Pakete: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

ensure_docker_debian() {
  if ! command -v docker >/dev/null 2>&1; then
    [[ $INSTALL_DOCKER == true ]] || die "Docker fehlt (INSTALL_DOCKER=false) – bitte selbst installieren."
    log "Installiere Docker aus dem offiziellen Repository"
    # shellcheck disable=SC1091
    . /etc/os-release
    local distro=debian codename=${VERSION_CODENAME:-}
    if [[ $ID == ubuntu || ${ID_LIKE:-} == *ubuntu* ]]; then distro=ubuntu; codename=${UBUNTU_CODENAME:-$codename}; fi
    [[ -n $codename ]] || die "Distribution nicht erkannt (VERSION_CODENAME fehlt)."
    apt_install ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$distro $codename stable" \
      > /etc/apt/sources.list.d/docker.list
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >/dev/null
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "Docker läuft nicht – systemctl status docker"
  log "  $(docker --version)"
}

# rclone vom Host (aktuelle Version von rclone.org, Paket nur als Fallback)
ensure_rclone_host() {
  [[ -x $RCLONE_BIN ]] && return 0
  local arch tmp; arch=$(dpkg --print-architecture)
  log "Installiere rclone"
  if [[ $arch == amd64 || $arch == arm64 ]]; then
    tmp=$(mktemp --suffix=.deb)
    if curl -fsSL "https://downloads.rclone.org/rclone-current-linux-$arch.deb" -o "$tmp" \
       && dpkg -i "$tmp" >/dev/null; then rm -f "$tmp"; return 0; fi
    rm -f "$tmp"
  fi
  apt_install rclone
  [[ -x $RCLONE_BIN ]]
}

# NVIDIA: Treiber muss installiert sein; dann Container Toolkit + Docker-Runtime
ensure_nvidia_toolkit() {
  [[ $JELLYFIN_HWACCEL == auto || $JELLYFIN_HWACCEL == nvenc ]] || return 0
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 || return 0
  docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia && return 0
  log "NVIDIA-GPU erkannt – installiere NVIDIA Container Toolkit"
  apt_install ca-certificates curl gnupg
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit >/dev/null
  nvidia-ctk runtime configure --runtime=docker >/dev/null
  systemctl restart docker
  docker info >/dev/null 2>&1 || die "Docker startet nach NVIDIA-Konfiguration nicht – systemctl status docker"
}

# ---- Hardware-Beschleunigung für Jellyfin --------------------------------------
# Setzt JF_HW_ARGS (docker run), JF_HW_TYPE (Jellyfin) und JF_HW_DEV (Gerät)
detect_hwaccel() {
  JF_HW_ARGS=(); JF_HW_TYPE=none; JF_HW_DEV=""
  local want=$JELLYFIN_HWACCEL has_nv=0 vendor
  [[ $want == none ]] && return 0
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 && has_nv=1
  if [[ $want == nvenc || ( $want == auto && $has_nv == 1 ) ]]; then
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
      JF_HW_TYPE=nvenc
      JF_HW_ARGS=(--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all)
      return 0
    fi
    if [[ $PLATFORM == unraid ]]; then
      warn "NVIDIA-GPU ohne Docker-Runtime – bitte das Plugin \"Nvidia Driver\" (Community Apps) installieren."
    else
      warn "NVIDIA-GPU ohne Docker-Runtime – NVIDIA Container Toolkit fehlt."
    fi
    [[ $want == nvenc ]] && return 0
  fi
  if [[ -e /dev/dri/renderD128 ]]; then
    vendor=$(cat /sys/class/drm/renderD128/device/vendor 2>/dev/null || true)
    JF_HW_ARGS=(--device /dev/dri); JF_HW_DEV=/dev/dri/renderD128
    case $want in
      qsv|vaapi) JF_HW_TYPE=$want ;;
      *) if [[ $vendor == 0x8086 ]]; then JF_HW_TYPE=qsv; else JF_HW_TYPE=vaapi; fi ;;
    esac
    # Intel: OpenCL für HDR-Tonemapping (linuxserver-Mod)
    [[ $JF_HW_TYPE == qsv ]] && JF_HW_ARGS+=(-e DOCKER_MODS=linuxserver/mods:jellyfin-opencl-intel)
  fi
}

ensure_rclone_plugin() {
  [[ -x $RCLONE_BIN ]] && return 0
  log "Installiere rclone-Plugin (Community Apps, Waseh/rclone-unraid)"
  if ! /usr/local/sbin/plugin install "$RCLONE_PLG_URL" >/tmp/mediastack-plugin.log 2>&1; then
    tail -n 15 /tmp/mediastack-plugin.log | sed 's/^/      /' >&2
    return 1
  fi
  [[ -x $RCLONE_BIN ]]
}

# Remote [$RCLONE_REMOTE] in der Plugin-Konfiguration anlegen/aktualisieren.
# Andere Remotes in der Datei bleiben unangetastet.
write_plugin_remote() {
  local obs
  mkdir -p "$(dirname "$RCLONE_PLG_CONF")"; touch "$RCLONE_PLG_CONF"
  obs=$(prclone obscure "${WEBDAV_PASS:-}")
  prclone config delete "$RCLONE_REMOTE" >/dev/null 2>&1 || true
  prclone config create "$RCLONE_REMOTE" webdav \
    url="${DAV_URL:-http://$SERVER_IP:$P_INFINIDYSK/}" vendor=other \
    user="${WEBDAV_USER:-}" pass="$obs" --no-obscure >/dev/null
}

host_mounted() { awk -v m="$MOUNT_HOST" '$2==m && $3 ~ /^fuse/' /proc/mounts | grep -q .; }
host_healthy() { host_mounted && timeout 15 ls -A "$MOUNT_HOST" 2>/dev/null | grep -q completed-symlinks; }
# Erst alle rclone-Prozesse für diesen Mount beenden und WARTEN, bis sie weg
# sind: rclone hängt beim Beenden "seinen" Mount per Pfad aus. Läuft dann schon
# ein neuer Mount am selben Pfad, würde sonst der neue ausgehängt.
# Danach alle (ggf. gestapelten) FUSE-Mounts am Pfad entfernen.
host_unmount() {
  local pat="rcloneorig .*mount $RCLONE_REMOTE: $MOUNT_HOST" i
  if [[ $RCLONE_MODE == systemd ]]; then
    systemctl stop mediastack-mount.service >/dev/null 2>&1 || true
    pat="rclone mount $RCLONE_REMOTE: $MOUNT_HOST"
  fi
  if pgrep -f "$pat" >/dev/null 2>&1; then
    pkill -TERM -f "$pat" 2>/dev/null || true
    for i in $(seq 1 30); do pgrep -f "$pat" >/dev/null 2>&1 || break; sleep 1; done
    if pgrep -f "$pat" >/dev/null 2>&1; then pkill -KILL -f "$pat" 2>/dev/null || true; sleep 1; fi
  fi
  for i in 1 2 3 4 5; do
    host_mounted || break
    fusermount -uz "$MOUNT_HOST" 2>/dev/null || fusermount3 -uz "$MOUNT_HOST" 2>/dev/null \
      || umount -l "$MOUNT_HOST" 2>/dev/null || true
    sleep 1
  done
}

# Debian/Ubuntu: Mount als systemd-Dienst. Startet nach Docker, wartet bis
# InfiniDysk antwortet (bis 15 Min.) und startet rclone bei Fehlern neu.
MOUNT_UNIT=/etc/systemd/system/mediastack-mount.service
systemd_mount() {
  build_rclone_flags
  mkdir -p "$APPDATA/rclone-nzbdav/cache" "$STATE_DIR" "$MOUNT_HOST"
  local tmp i; tmp=$(mktemp)
  cat > "$tmp" <<EOF
[Unit]
Description=mediastack: rclone-Mount InfiniDysk-WebDAV ($MOUNT_HOST)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p $MOUNT_HOST
ExecStartPre=/bin/bash -c 'for i in \$\$(seq 1 180); do curl -s -o /dev/null -m 5 -X PROPFIND ${DAV_URL:-http://$SERVER_IP:$P_INFINIDYSK/} && exit 0; sleep 5; done; exit 1'
ExecStart=$RCLONE_BIN mount $RCLONE_REMOTE: $MOUNT_HOST --config $RCLONE_CONF ${RCLONE_FLAGS[*]} --cache-dir $APPDATA/rclone-nzbdav/cache --log-file $STATE_DIR/rclone.log --log-level NOTICE
ExecStop=/usr/bin/fusermount3 -uz $MOUNT_HOST
Restart=always
RestartSec=15
TimeoutStartSec=1200
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
  if ! cmp -s "$tmp" "$MOUNT_UNIT" || ! host_healthy; then
    install -m 644 "$tmp" "$MOUNT_UNIT"
    systemctl daemon-reload
    systemctl enable mediastack-mount.service >/dev/null 2>&1 || true
    MOUNT_FIXED=1
    systemctl restart mediastack-mount.service || { rm -f "$tmp"; return 1; }
  fi
  rm -f "$tmp"
  for i in $(seq 1 20); do host_healthy && return 0; sleep 3; done
  return 1
}

# Mount mit dem Plugin-rclone als Daemon direkt auf dem Host
host_mount() {
  [[ $RCLONE_MODE == systemd ]] && { systemd_mount; return; }
  build_rclone_flags
  # Fingerabdruck aus URL + Flags: geänderte Einstellungen -> neu mounten
  local sig; sig=$(printf '%s ' "${DAV_URL:-}" "${RCLONE_FLAGS[@]}" | md5sum | cut -c1-12)
  if host_healthy && [[ $(cat "$STATE_DIR/mount.sig" 2>/dev/null) == "$sig" ]]; then return 0; fi
  MOUNT_FIXED=1
  host_unmount
  prep_mount
  mkdir -p "$APPDATA/rclone-nzbdav/cache" "$STATE_DIR"
  echo "$sig" > "$STATE_DIR/mount.sig" 2>/dev/null || true
  prclone mount "$RCLONE_REMOTE:" "$MOUNT_HOST" --daemon "${RCLONE_FLAGS[@]}" \
    --cache-dir "$APPDATA/rclone-nzbdav/cache" \
    --log-file "$STATE_DIR/rclone.log" --log-level NOTICE || return 1
  local i
  for i in $(seq 1 20); do host_healthy && return 0; sleep 3; done
  return 1
}

# ---- Neustartfest: Hooks + go-Eintrag ----------------------------------------
# 1. disks_mounted (nach dem Einhängen der Platten, VOR Docker): Mountpunkt
#    als shared-Bind-Mount vorbereiten.
# 2. started (Array + Docker laufen): Watchdog im Boot-Modus starten.
# 3. Zusätzlich startet die go-Datei einen Boot-Wächter im Hintergrund, der
#    wartet, bis das Array (und damit das Script) da ist – falls der started-
#    Hook nicht greift. Doppelte Läufe verhindert das Lock im Watchdog.
# Die Event-Verzeichnisse liegen im RAM; die go-Datei legt sie bei jedem Boot an.
HOOK_DIR=/boot/config/plugins/mediastack
HOOK_SRC=$HOOK_DIR/mount-prep.sh
HOOK_DST=/usr/local/emhttp/plugins/mediastack/event/disks_mounted
HOOK2_SRC=$HOOK_DIR/started.sh
HOOK2_DST=/usr/local/emhttp/plugins/mediastack/event/started
BOOT_SRC=$HOOK_DIR/boot-watch.sh
install_boot_hooks() {
  mkdir -p "$HOOK_DIR"
  cat > "$HOOK_SRC" <<EOF
#!/bin/bash
# mediastack: Mountpunkt für rclone "shared" machen
M="$MOUNT_HOST"
mkdir -p "\$M"
mountpoint -q "\$M" || mount --bind "\$M" "\$M"
mount --make-shared "\$M"
logger -t mediastack "Mountpunkt \$M vorbereitet (shared)"
EOF
  install -D -m 755 "$HOOK_SRC" "$HOOK_DST"

  cat > "$HOOK2_SRC" <<EOF
#!/bin/bash
# mediastack: rclone-Mount nach dem Array-Start einhängen
logger -t mediastack "Event started: starte Watchdog (boot)"
setsid nohup bash "$SELF" watchdog boot >/dev/null 2>&1 < /dev/null &
EOF
  install -D -m 755 "$HOOK2_SRC" "$HOOK2_DST"

  cat > "$BOOT_SRC" <<EOF
#!/bin/bash
# mediastack: Boot-Wächter – wartet bis zu 60 Min. auf Array + Docker,
# dann Watchdog im Boot-Modus (falls der started-Hook nicht gegriffen hat)
for i in \$(seq 1 360); do
  [ -f "$SELF" ] && docker info >/dev/null 2>&1 && break
  sleep 10
done
[ -f "$SELF" ] || { logger -t mediastack "Boot-Wächter: Script nicht gefunden ($SELF)"; exit 0; }
logger -t mediastack "Boot-Wächter: Array/Docker bereit, starte Watchdog (boot)"
exec bash "$SELF" watchdog boot
EOF

  local go=/boot/config/go
  if [[ -f $go ]] && ! grep -q '# >>> mediastack v5' "$go"; then
    log "Aktualisiere Boot-Eintrag in $go"
    sed -i '/# >>> mediastack/,/# <<< mediastack/d' "$go"
    cat >> "$go" <<EOF

# >>> mediastack v5 (rclone-Mount: Hooks, Boot-Wächter, Watchdog-Cron)
install -D -m 755 $HOOK_SRC $HOOK_DST
install -D -m 755 $HOOK2_SRC $HOOK2_DST
bash $HOOK_SRC
setsid nohup bash $BOOT_SRC >/dev/null 2>&1 < /dev/null &
/usr/local/sbin/update_cron
# <<< mediastack
EOF
  fi
}

# Status der Neustart-Absicherung (für doctor)
boot_status_ok() {
  if [[ $PLATFORM != unraid ]]; then
    if host_mode; then systemctl is-enabled -q mediastack-mount.service 2>/dev/null || return 1; fi
    if [[ $WATCHDOG_ENABLED == true ]]; then systemctl is-active -q mediastack-watchdog.timer 2>/dev/null || return 1; fi
    return 0
  fi
  [[ -x $HOOK_DST && -x $HOOK2_DST && -f $BOOT_SRC ]] || return 1
  grep -q '# >>> mediastack v5' /boot/config/go 2>/dev/null || return 1
  if [[ $WATCHDOG_ENABLED == true ]]; then grep -qF "$(basename "$SELF") watchdog" /etc/cron.d/root 2>/dev/null || return 1; fi
  return 0
}

# Unraid: /etc/cron.d liegt im RAM. update_cron baut /etc/cron.d/root bei jedem
# Boot neu – aber nur aus *.cron-Dateien von INSTALLIERTEN Plugins. "mediastack"
# ist kein Plugin, deshalb liegt die Datei im dynamix-Ordner (Unraid selbst),
# der immer eingelesen wird.
CRON_FILE=/boot/config/plugins/dynamix/mediastack.cron
CRON_OLD=/boot/config/plugins/mediastack/mediastack.cron
WD_SERVICE=/etc/systemd/system/mediastack-watchdog.service
WD_TIMER=/etc/systemd/system/mediastack-watchdog.timer
install_watchdog_systemd() {
  if [[ $WATCHDOG_ENABLED == true ]]; then
    cat > "$WD_SERVICE" <<EOF
[Unit]
Description=mediastack: rclone-Mount prüfen und reparieren
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $SELF watchdog
EOF
    cat > "$WD_TIMER" <<EOF
[Unit]
Description=mediastack: Watchdog alle 5 Minuten

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now mediastack-watchdog.timer >/dev/null 2>&1 || true
    log "Watchdog aktiv (systemd-Timer alle 5 Min., Log: $LOGHINT)"
  else
    systemctl disable --now mediastack-watchdog.timer >/dev/null 2>&1 || true
    rm -f "$WD_SERVICE" "$WD_TIMER"; systemctl daemon-reload
  fi
}

install_watchdog() {
  [[ $PLATFORM == unraid ]] || { install_watchdog_systemd; return; }
  rm -f "$CRON_OLD"
  mkdir -p "$(dirname "$CRON_FILE")"
  if [[ $WATCHDOG_ENABLED == true ]]; then
    {
      echo "# mediastack: rclone-Mount alle 5 Minuten prüfen und reparieren"
      printf '*/5 * * * * [ -f %q ] && bash %q watchdog >/dev/null 2>&1\n' "$SELF" "$SELF"
    } > "$CRON_FILE"
    log "Watchdog aktiv (alle 5 Min., Log: $LOGHINT)"
  else
    rm -f "$CRON_FILE"
  fi
  /usr/local/sbin/update_cron >/dev/null 2>&1 || true
}

DOC_AUTO=0    # 1 = ohne Rückfrage reparieren
DOC_QUIET=0   # 1 = nur Syslog (Watchdog)
dmsg() { if (( DOC_QUIET )); then logger -t mediastack "$*"; else echo "$*"; fi; }
ok()   { (( DOC_QUIET )) || echo "  ${c_g}✔${c_0} $*"; }
LAST_BAD=""
bad()  { LAST_BAD="$*"; if (( DOC_QUIET )); then logger -t mediastack "Problem: $*"; else echo "  ${c_r}✘${c_0} $*"; fi; }
ask()  { (( DOC_AUTO )) && return 0; local a; read -rp "    → $*? [J/n] " a; [[ -z $a || $a =~ ^[jJyY] ]]; }
running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
has_content() { grep -q 'completed-symlinks' <<<"$1"; }

# Prüft die Kette InfiniDysk → WebDAV → rclone → Container-Mount → Host → Apps.
# Beim ersten Fehler: FIX = Reparaturfunktion, FIX_DESC = Beschreibung.
check_chain() {
  FIX=""; FIX_DESC=""
  local out code c broken=()

  if ! exists infinidysk; then bad "Container infinidysk fehlt"; return 1; fi
  if ! running infinidysk; then
    bad "InfiniDysk läuft nicht"; FIX=fix_start_infinidysk; FIX_DESC="InfiniDysk starten"; return 1; fi
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$ND/" || true)
  if [[ ! $code =~ ^[234] ]]; then
    bad "InfiniDysk antwortet nicht (HTTP ${code:-–})"
    FIX=fix_restart_infinidysk; FIX_DESC="InfiniDysk neu starten"; return 1; fi
  ok "InfiniDysk erreichbar ($ND)"

  detect_dav
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -u "${WEBDAV_USER:-}:${WEBDAV_PASS:-}" \
         -X PROPFIND -H 'Depth: 1' "$DAV_URL" || true)
  if [[ $code != 207 ]]; then
    bad "WebDAV-Login fehlgeschlagen (HTTP $code)"
    FIX=fix_new_creds; FIX_DESC="WebDAV-Zugangsdaten neu eingeben"; return 1; fi
  if (( DAV_BACKEND )); then ok "WebDAV-Login (Backend-Port $P_WEBDAV)"
  else
    ok "WebDAV-Login (Port $P_INFINIDYSK)"
    (( DOC_QUIET )) || echo "  ${c_y}!${c_0} WebDAV läuft über den Frontend-Proxy (langsamer). Empfohlen: InfiniDysk-Port 8080 als Host-Port $P_WEBDAV veröffentlichen."
  fi
  if [[ $(conf_url) != "$DAV_URL" && -n $(conf_url) ]]; then
    bad "rclone nutzt $(conf_url), erwartet $DAV_URL"
    FIX=fix_rewrite_conf; FIX_DESC="rclone auf $DAV_URL umstellen und neu mounten"; return 1; fi

  if host_mode; then
    local what="rclone-Plugin"; [[ $RCLONE_MODE == systemd ]] && what="rclone"
    if exists rclone-nzbdav; then
      bad "Alter Container rclone-nzbdav läuft parallel zu $what"
      FIX=fix_remove_rclone_ct; FIX_DESC="Container rclone-nzbdav entfernen und per $what mounten"; return 1; fi
    if [[ ! -x $RCLONE_BIN ]]; then
      bad "$what nicht installiert"
      FIX=fix_install_plugin; FIX_DESC="$what installieren"; return 1; fi
    ok "$what installiert ($("$RCLONE_BIN" version 2>/dev/null | head -1))"
    if ! timeout 30 "$RCLONE_BIN" --config "$RCLONE_CONF" lsd "$RCLONE_REMOTE:" >/dev/null 2>&1; then
      bad "Remote '$RCLONE_REMOTE:' erreicht das WebDAV nicht"
      FIX=fix_rewrite_conf; FIX_DESC="Remote '$RCLONE_REMOTE' neu schreiben und neu mounten"; return 1; fi
    ok "Remote '$RCLONE_REMOTE:' erreicht das WebDAV"
    if ! host_mounted; then
      bad "rclone-Mount unter $MOUNT_HOST läuft nicht"
      FIX=fix_mount; FIX_DESC="rclone-Mount starten, danach Radarr/Sonarr/Jellyfin neu starten"; return 1; fi
  else
  if ! exists rclone-nzbdav; then
    bad "Container rclone-nzbdav fehlt"; FIX=fix_reinstall; FIX_DESC="Installation ausführen"; return 1; fi
  if ! running rclone-nzbdav; then
    bad "rclone-nzbdav läuft nicht"; FIX=fix_propagation; FIX_DESC="rclone-nzbdav starten"; return 1; fi
  ok "rclone-nzbdav läuft"

  if ! timeout 30 docker exec rclone-nzbdav rclone lsd nzbdav: --config /config/rclone/rclone.conf >/dev/null 2>&1; then
    bad "rclone erreicht das WebDAV nicht (rclone.conf veraltet?)"
    FIX=fix_rewrite_conf; FIX_DESC="rclone.conf neu schreiben und rclone neu starten"; return 1; fi
  ok "rclone erreicht das WebDAV"

  if [[ $(docker inspect -f '{{.HostConfig.PidMode}}' rclone-nzbdav 2>/dev/null) != host ]]; then
    bad "rclone-nzbdav ist noch im alten Modus (Mount nur im Container)"
    FIX=fix_reinstall; FIX_DESC="Update ausführen (rclone-nzbdav wird neu angelegt)"; return 1; fi
  fi

  if ! mountpoint -q "$MOUNT_HOST" \
     || ! findmnt -no PROPAGATION --target "$MOUNT_HOST" 2>/dev/null | head -1 | grep -q shared; then
    bad "$MOUNT_HOST ist nicht shared – Mount kommt nicht in den Containern an"
    FIX=fix_mount; FIX_DESC="Mountpunkt shared machen, rclone + Radarr/Sonarr/Jellyfin neu starten"; return 1; fi
  out=$(timeout 15 ls -A "$MOUNT_HOST" 2>&1 || true)
  if ! has_content "$out"; then
    bad "Mount auf dem Host leer oder tot"
    FIX=fix_mount; FIX_DESC="Mount aufräumen, rclone + Radarr/Sonarr/Jellyfin neu starten"; return 1; fi
  ok "Mount auf dem Host ($MOUNT_HOST)"

  for c in radarr sonarr jellyfin; do
    exists "$c" && running "$c" || continue
    out=$(timeout 15 docker exec "$c" ls -A "$MOUNT_CT" 2>&1 || true)
    if has_content "$out"; then ok "Mount in $c"; else bad "Mount in $c leer"; broken+=("$c"); fi
  done
  if (( ${#broken[@]} )); then
    FIX="fix_restart_apps ${broken[*]}"; FIX_DESC="${broken[*]} neu starten"; return 1; fi
  return 0
}

wait_ct_mount() {
  local i
  for i in $(seq 1 20); do
    timeout 10 ls -A "$MOUNT_HOST" 2>/dev/null | grep -q completed-symlinks && return 0
    sleep 3
  done
  return 1
}
fix_start_infinidysk()   { docker start infinidysk >/dev/null && wait_http "$ND" 120 >/dev/null; }
fix_restart_infinidysk() { docker restart infinidysk >/dev/null && wait_http "$ND" 120 >/dev/null; }
fix_restart_apps() {
  local c
  for c; do exists "$c" && docker restart "$c" >/dev/null && dmsg "    $c neu gestartet"; done
}
# rclone sauber stoppen, Mountpunkt aufräumen + shared machen, rclone starten,
# danach die Apps neu starten, damit sie den Mount sicher sehen
fix_propagation() {
  docker stop -t 30 rclone-nzbdav >/dev/null 2>&1 || true
  prep_mount
  docker start rclone-nzbdav >/dev/null || return 1
  wait_ct_mount || { dmsg "    rclone hat nicht gemountet – docker logs rclone-nzbdav"; return 1; }
  sleep 2
  fix_restart_apps radarr sonarr jellyfin
}
# Plugin-Modus: Mount neu aufbauen, dann Apps neu starten
fix_host_mount() {
  host_unmount
  prep_mount
  host_mount || { dmsg "    rclone-Mount fehlgeschlagen – Log: $STATE_DIR/rclone.log"; return 1; }
  sleep 2
  fix_restart_apps radarr sonarr jellyfin
}
fix_mount() { if host_mode; then fix_host_mount; else fix_propagation; fi; }
write_conf() { if [[ $RCLONE_MODE == plugin ]]; then write_plugin_remote; else write_rclone_conf; fi; }
fix_rewrite_conf() { write_conf && fix_mount; }
fix_install_plugin() {
  (( DOC_QUIET )) && return 1
  if [[ $RCLONE_MODE == systemd ]]; then ensure_rclone_host && write_rclone_conf && fix_host_mount
  else ensure_rclone_plugin && write_plugin_remote && fix_host_mount; fi
}
fix_remove_rclone_ct() { remove_ct rclone-nzbdav && fix_host_mount; }
fix_new_creds() {
  (( DOC_QUIET )) && return 1
  read -rp  "    WebDAV-Benutzer: " WEBDAV_USER
  read -rsp "    WebDAV-Passwort: " WEBDAV_PASS; echo
  save_secret WEBDAV_USER "$WEBDAV_USER"; save_secret WEBDAV_PASS "$WEBDAV_PASS"
  write_conf && fix_mount
}
fix_reinstall() { (( DOC_QUIET )) && return 1; bash "$SELF" update; }

run_doctor() {
  detect_ip
  ND="http://$SERVER_IP:$P_INFINIDYSK"
  [[ -f $SECRETS ]] && source "$SECRETS"
  local round
  for round in 1 2 3 4 5; do
    (( DOC_QUIET )) || echo "${c_b}── rclone-Mount: Prüfung $round ──${c_0}"
    if check_chain; then
      if (( ! DOC_QUIET )); then
        if boot_status_ok; then ok "Neustart-Absicherung (Hooks, go-Eintrag, Watchdog-Cron)"
        else
          bad "Neustart-Absicherung unvollständig (Hooks/go-Eintrag/Watchdog-Cron)"
          if ask "Hooks, go-Eintrag und Watchdog-Cron neu einrichten"; then
            if [[ $PLATFORM == unraid ]]; then install_boot_hooks
            elif host_mode; then systemctl enable mediastack-mount.service >/dev/null 2>&1 || true; fi
            install_watchdog
            boot_status_ok && ok "Neustart-Absicherung eingerichtet" || bad "Weiterhin unvollständig"
          fi
        fi
      fi
      if (( DOC_QUIET )); then
        (( round > 1 )) && logger -t mediastack "rclone-Mount repariert"
      else
        log "rclone-Mount ist in Ordnung."
      fi
      return 0
    fi
    if [[ -z $FIX ]]; then dmsg "Keine automatische Reparatur möglich."; return 1; fi
    ask "$FIX_DESC" || return 1
    dmsg "    Repariere: $FIX_DESC"
    $FIX || { dmsg "    Reparatur fehlgeschlagen: $FIX_DESC"; return 1; }
  done
  dmsg "Nach 5 Durchläufen weiterhin fehlerhaft – docker logs rclone-nzbdav prüfen."
  return 1
}

# ------------------------------- Sub-Kommandos -------------------------------
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SELF_NAME="$(basename "$SELF")"
usage() { sed -n '/^#  Aufruf/,/^#$/p' "$SELF" | sed 's/^#//'; }

CMD=${1:-install}; shift || true
APPLY=0; PULL=0
case "$CMD" in
  status)
    docker ps -a --filter "name=^($(IFS='|'; echo "${CONTAINERS[*]}"))$" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo "Script-Version: $SCRIPT_VERSION"; exit 0 ;;
  doctor|diagnose)
    [[ $EUID -eq 0 ]] || die "Bitte als root ausführen."
    [[ ${1:-} == -y || ${1:-} == --yes ]] && DOC_AUTO=1
    trap - ERR; set +e
    run_doctor; rc=$?; write_mount_status "$rc" "$LAST_BAD"; exit $rc ;;
  watchdog)
    case "${1:-run}" in
      pause)  mkdir -p "$STATE_DIR"; touch "$STATE_DIR/watchdog.paused"; log "Watchdog pausiert"; exit 0 ;;
      resume) rm -f "$STATE_DIR/watchdog.paused"; log "Watchdog wieder aktiv"; exit 0 ;;
    esac
    trap - ERR; set +e
    [[ -f $STATE_DIR/watchdog.paused ]] && exit 0
    if [[ ${1:-} == boot ]]; then                  # nach dem Array-Start: bis zu 15 Min. auf InfiniDysk warten
      detect_ip
      logger -t mediastack "Boot: warte auf InfiniDysk ($SERVER_IP:$P_INFINIDYSK)"
      for i in $(seq 1 180); do
        curl -s -o /dev/null -m 5 "http://$SERVER_IP:$P_INFINIDYSK/" && break; sleep 5
      done
      sleep 10                                     # InfiniDysk-Backend etwas Zeit geben
      logger -t mediastack "Boot: prüfe/hänge rclone-Mount ein"
    fi
    docker info >/dev/null 2>&1 || exit 0          # Array/Docker gestoppt
    exists infinidysk || exit 0
    exec 9>/var/run/mediastack-watchdog.lock
    flock -n 9 || exit 0                           # läuft schon
    DOC_AUTO=1; DOC_QUIET=1
    run_doctor; rc=$?; write_mount_status "$rc" "$LAST_BAD"
    [[ $RECYCLARR_ENABLED == true && $TRASH_ANY_GERMAN == true ]] && radarr_fix_profile_language quiet
    exit $rc ;;
  dashboard-status)
    trap - ERR; set +e
    [[ $DASHBOARD_ENABLED == true && -d $DASH_DIR ]] || exit 0
    exec 8>/var/run/mediastack-dashboard.lock
    flock -n 8 || exit 0
    detect_ip
    write_status_json; exit 0 ;;
  remove)
    rm -f "$CRON_FILE" "$CRON_OLD" "$DASH_CRON"; /usr/local/sbin/update_cron >/dev/null 2>&1 || true
    host_mode && host_unmount && log "rclone-Mount $MOUNT_HOST ausgehängt (rclone bleibt installiert)"
    if [[ $PLATFORM != unraid ]]; then
      systemctl disable --now mediastack-mount.service mediastack-watchdog.timer mediastack-dashboard.timer >/dev/null 2>&1 || true
      rm -f "$DASH_SERVICE" "$DASH_TIMER"
      rm -f "$MOUNT_UNIT" "$WD_SERVICE" "$WD_TIMER"; systemctl daemon-reload 2>/dev/null || true
    fi
    for c in "${CONTAINERS[@]}"; do exists "$c" && remove_ct "$c" && log "$c entfernt"; done
    log "Configs in $APPDATA und Medien in $DATA wurden NICHT gelöscht."; exit 0 ;;
  self-update)
    log "Lade neue Version von GitHub"
    new="$SELF.new"
    curl -fsSL "$REPO_RAW/mediastack.sh" -o "$new" || { rm -f "$new"; die "Download fehlgeschlagen"; }
    bash -n "$new" || { rm -f "$new"; die "Heruntergeladenes Script ist fehlerhaft – nichts geändert."; }
    new_ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$new")
    cp -p "$SELF" "$SELF.bak"
    chmod +x "$new"; mv -f "$new" "$SELF"     # atomar ersetzen
    log "Script $SCRIPT_VERSION → ${new_ver:-?} (Backup: $SELF_NAME.bak)"
    [[ -f "$SCRIPT_DIR/mediastack.conf" ]] && log "Deine mediastack.conf bleibt unverändert."
    exec bash "$SELF" update ;;
  update)   APPLY=1; PULL=1 ;;
  recreate)
    [[ $# -gt 0 ]] || die "Welche Container? z. B.: bash $SELF_NAME recreate jellyfin"
    for c in "$@"; do
      [[ " ${CONTAINERS[*]} " == *" $c "* ]] || die "Unbekannter Container: $c (${CONTAINERS[*]})"
      exists "$c" && remove_ct "$c" && log "$c entfernt – wird neu angelegt"
    done ;;
  install)  ;;
  help|-h|--help) usage; exit 0 ;;
  *) usage; die "Unbekannter Befehl: $CMD" ;;
esac

# ------------------------------- 0. Prüfungen --------------------------------
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen (z. B. sudo bash $SELF_NAME)."
case $PLATFORM in
  unraid)
    log "Plattform: Unraid $(cat /etc/unraid-version 2>/dev/null | sed -n 's/version="\(.*\)"/\1/p')"
    docker info >/dev/null 2>&1 || die "Docker läuft nicht (Array gestartet? Docker aktiviert?)."
    [[ -d /mnt/user ]] || die "/mnt/user fehlt – ist das Array gestartet?" ;;
  debian)
    log "Plattform: $(. /etc/os-release; echo "${PRETTY_NAME:-Debian/Ubuntu}")"
    command -v systemctl >/dev/null 2>&1 || die "systemd wird benötigt."
    apt_install curl jq fuse3 ca-certificates gnupg procps util-linux
    ensure_docker_debian
    ensure_nvidia_toolkit ;;
  *) die "Plattform nicht unterstützt (nur Unraid und Debian/Ubuntu). Erzwingen: PLATFORM=unraid|debian" ;;
esac
log "Pfade: Configs $APPDATA · Medien $DATA/media · Mount $MOUNT_HOST · Benutzer $PUID:$PGID"
[[ -e /dev/fuse ]] || die "/dev/fuse fehlt – rclone-Mount nicht möglich."

[[ -n $SERVER_IP ]] || SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[[ -n $SERVER_IP ]] || die "Server-IP nicht erkannt – bitte SERVER_IP setzen."
log "Server-IP: $SERVER_IP"
write_default_conf

if (( PULL )); then
  log "Hole aktuelle Images"
  for v in ${!IMG_@}; do
    docker pull -q "${!v}" >/dev/null && echo "    ${!v}" || warn "Pull fehlgeschlagen: ${!v}"
  done
fi

mkdir -p "$STATE_DIR"
[[ -f $SECRETS ]] && source "$SECRETS"

if [[ -z $ADMIN_PASS ]]; then
  while :; do
    read -rsp "Admin-Passwort für alle Apps (User '$ADMIN_USER'): " ADMIN_PASS; echo
    read -rsp "Wiederholen: " p2; echo
    [[ ${#ADMIN_PASS} -ge 8 && $ADMIN_PASS == "$p2" ]] && break
    warn "Mind. 8 Zeichen und identisch, bitte nochmal."
  done
fi
save_secret ADMIN_USER "$ADMIN_USER"; save_secret ADMIN_PASS "$ADMIN_PASS"
[[ -n ${RC_PASS:-} ]] || { RC_PASS=$(genkey); save_secret RC_PASS "$RC_PASS"; }

# ------------------------------- 1. Ordner -----------------------------------
log "Lege Ordner an"
mkdir -p "$DATA/media/movies" "$DATA/media/tv" \
         "$APPDATA"/{infinidysk,rclone-nzbdav/cache,prowlarr,radarr,sonarr,jellyfin,seerr}
chown "$PUID:$PGID" "$DATA" "$DATA/media" "$DATA/media/movies" "$DATA/media/tv"
chown -R "$PUID:$PGID" "$APPDATA"/{infinidysk,prowlarr,radarr,sonarr,jellyfin}
chown -R 1000:1000 "$APPDATA/seerr"     # Seerr läuft als UID 1000

# ------------------------------- 2. Mount-Propagation ------------------------
# Damit der rclone-Mount aus dem Container auf dem Host und in den anderen
# Containern sichtbar wird, muss der Mountpunkt "shared" sein.
prep_mount
[[ $PLATFORM == unraid ]] && install_boot_hooks

# ------------------------------- 3. *arr API-Keys vorbelegen -----------------
seed_arr() {  # name port -> setzt Variable KEY_<NAME>
  local name=$1 port=$2 cfg="$APPDATA/$1/config.xml" key
  if [[ -f $cfg ]]; then
    key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$cfg")
  else
    key=$(genkey)
    cat > "$cfg" <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>$port</Port>
  <UrlBase></UrlBase>
  <ApiKey>$key</ApiKey>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <AllowedHosts>$(arr_allowed_hosts)</AllowedHosts>
  <LaunchBrowser>False</LaunchBrowser>
  <UpdateMechanism>Docker</UpdateMechanism>
  <InstanceName>${name^}</InstanceName>
</Config>
EOF
    chown "$PUID:$PGID" "$cfg"
  fi
  [[ -n $key ]] || die "API-Key für $name nicht gefunden ($cfg)"
  printf -v "KEY_${name^^}" '%s' "$key"
}
seed_arr prowlarr $P_PROWLARR
seed_arr radarr   $P_RADARR
seed_arr sonarr   $P_SONARR

LSIO_ENV=(-e PUID="$PUID" -e PGID="$PGID" -e UMASK="$UMASK")

# ------------------------------- 4. InfiniDysk -------------------------------
# Symlink-Bibliothek: Caching macht rclone (VFS), Segment Cache von InfiniDysk aus
ND_ENV=(-e NZBDAV_CONFIG__USENET__SEGMENT_CACHE__ENABLED=false)
if [[ $RCLONE_RC == true ]]; then
  ND_ENV+=(-e NZBDAV_CONFIG__RCLONE__RC_ENABLED=true
           -e "NZBDAV_CONFIG__RCLONE__HOST=http://$SERVER_IP:$P_RCLONE_RC"
           -e NZBDAV_CONFIG__RCLONE__USER=rclone
           -e "NZBDAV_CONFIG__RCLONE__PASS=$RC_PASS")
fi
run_ct infinidysk $P_INFINIDYSK "" -- \
  "${LSIO_ENV[@]}" "${ND_ENV[@]}" \
  -p $P_INFINIDYSK:3000 -p "127.0.0.1:$P_WEBDAV:8080" \
  -v "$APPDATA/infinidysk:/config" \
  "$IMG_INFINIDYSK"

ND="http://$SERVER_IP:$P_INFINIDYSK"
wait_http "$ND" || die "InfiniDysk antwortet nicht – Logs: docker logs infinidysk"

if [[ -z ${NZBDAV_API_KEY:-} || -z ${WEBDAV_USER:-} || -z ${WEBDAV_PASS:-} ]]; then
  cat <<EOF

${c_b}──────── Einmaliger Schritt in InfiniDysk ────────${c_0}
Öffne ${c_b}$ND${c_0} → Settings und trage ein:
  • Usenet:   Provider-Host, Port, SSL, User, Passwort, Verbindungen
  • SABnzbd:  Categories enthalten: ${c_b}$CAT_MOVIES,$CAT_TV${c_0}
              Rclone Mount Directory: ${c_b}$MOUNT_CT${c_0}
              API-Key kopieren
  • WebDAV:   Benutzer + Passwort festlegen
  → Speichern. Dann hier weitermachen.

EOF
  read -rp  "InfiniDysk API-Key (SABnzbd-Tab): " NZBDAV_API_KEY
  read -rp  "WebDAV-Benutzer: " WEBDAV_USER
  read -rsp "WebDAV-Passwort: " WEBDAV_PASS; echo
  save_secret NZBDAV_API_KEY "$NZBDAV_API_KEY"
  save_secret WEBDAV_USER "$WEBDAV_USER"
  save_secret WEBDAV_PASS "$WEBDAV_PASS"
fi

detect_dav
if (( DAV_BACKEND )); then
  log "WebDAV über Backend-Port: $DAV_URL"
else
  warn "WebDAV läuft über Port $P_INFINIDYSK (Frontend-Proxy, langsamer)."
  warn "  Empfohlen: in InfiniDysk Container-Port 8080 als Host-Port $P_WEBDAV veröffentlichen"
  warn "  (wird vom Script automatisch gemacht, wenn es InfiniDysk selbst angelegt hat)."
fi
if [[ $RCLONE_RC == true ]] && ! docker inspect -f '{{index .Config.Labels "mediastack.hash"}}' infinidysk 2>/dev/null | grep -qv '<no value>'; then
  warn "RCLONE_RC=true: Bitte in InfiniDysk unter Settings → Rclone Server eintragen:"
  warn "  Notifications an · Host http://$SERVER_IP:$P_RCLONE_RC · User rclone · Passwort: RC_PASS aus $SECRETS"
fi
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND -H 'Depth: 1' "$DAV_URL" || true)
[[ $code == 207 ]] || warn "WebDAV-Login liefert HTTP $code (erwartet 207) – Zugangsdaten prüfen. Werte in $SECRETS löschen und Script neu starten."

# ------------------------------- 5. rclone-Mount -----------------------------
RC_DIR="$APPDATA/rclone-nzbdav"
if host_mode; then
  if exists rclone-nzbdav; then log "Entferne Container rclone-nzbdav ($RCLONE_MODE-Modus)"; remove_ct rclone-nzbdav; fi
  if [[ $RCLONE_MODE == plugin ]]; then
    log "rclone über das Unraid-Plugin"
    ensure_rclone_plugin || die "rclone-Plugin konnte nicht installiert werden – Log: /tmp/mediastack-plugin.log"
    write_plugin_remote
  else
    log "rclone als systemd-Dienst (mediastack-mount.service)"
    ensure_rclone_host || die "rclone konnte nicht installiert werden"
    write_rclone_conf
  fi
  log "  $("$RCLONE_BIN" version | head -1)"
  log "  Remote '$RCLONE_REMOTE' in $RCLONE_CONF eingetragen"
  printf '    hänge %s ein ' "$MOUNT_HOST"
  if host_mount; then echo " ok"
  else
    echo; warn "rclone-Mount fehlgeschlagen – Log: $STATE_DIR/rclone.log"
    tail -n 10 "$STATE_DIR/rclone.log" 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
else
write_rclone_conf

# Unraid: Die Mount-Propagation aus einem Container zurück auf den Host ist
# unzuverlässig. Deshalb hängt rclone direkt im Mount-Namespace des Hosts ein
# (nsenter -t 1 -m). Der Container bleibt nur die Hülle: Start/Stopp/Logs/Update
# laufen weiter über Docker. Das Netzwerk bleibt das des Containers.
build_rclone_flags
RCLONE_HOST_CMD="cp $RC_DIR/rclone.bin /tmp/mediastack-rclone && chmod 755 /tmp/mediastack-rclone; \
  if mountpoint -q $MOUNT_HOST && grep -q ' $MOUNT_HOST fuse' /proc/mounts && ! ls $MOUNT_HOST >/dev/null 2>&1; then umount -l $MOUNT_HOST; fi; \
  exec /tmp/mediastack-rclone mount nzbdav: $MOUNT_HOST --config $RC_DIR/rclone.conf \
  ${RCLONE_FLAGS[*]} --cache-dir $RC_DIR/cache"
run_ct rclone-nzbdav "" "$ICON/rclone.png" -- \
  --privileged --pid=host --network host \
  -v "$RC_DIR:/config/rclone" \
  --entrypoint sh "$IMG_RCLONE" -c \
  "set -e; command -v nsenter >/dev/null || apk add --no-cache util-linux-misc >/dev/null; \
   cp /usr/local/bin/rclone /config/rclone/rclone.bin; \
   exec nsenter -t 1 -m -- /bin/sh -c \"$RCLONE_HOST_CMD\""

if (( MOUNT_FIXED )) && exists rclone-nzbdav; then
  log "Mountpunkt war nicht shared – starte rclone-nzbdav neu"
  docker restart -t 30 rclone-nzbdav >/dev/null
fi

printf '    warte auf rclone-Mount '
for i in $(seq 1 40); do
  awk -v m="$MOUNT_HOST" '$2==m && /fuse/' /proc/mounts | grep -q . && { echo " ok"; break; }
  printf '.'; sleep 3
  if [[ $i == 40 ]]; then
    echo; warn "rclone-Mount nicht sichtbar. Letzte Logs von rclone-nzbdav:"
    docker logs --tail 20 rclone-nzbdav 2>&1 | sed 's/^/      /' >&2 || true
    warn "Radarr/Sonarr/Jellyfin laufen weiter, Streams gehen aber erst mit Mount."
  fi
done
fi   # RCLONE_MODE

# Container, die vor der Korrektur liefen, sehen den Mount erst nach Neustart
if (( MOUNT_FIXED )); then
  for c in radarr sonarr jellyfin; do
    exists "$c" && docker restart "$c" >/dev/null && log "$c neu gestartet (Mount)"
  done
fi

# ------------------------------- 6. Apps starten -----------------------------
run_ct prowlarr $P_PROWLARR "$ICON/prowlarr.png" -- \
  "${LSIO_ENV[@]}" -p $P_PROWLARR:9696 \
  -v "$APPDATA/prowlarr:/config" "$IMG_PROWLARR"

for app in radarr sonarr; do
  port_var="P_${app^^}"; img_var="IMG_${app^^}"
  run_ct "$app" "${!port_var}" "$ICON/$app.png" -- \
    "${LSIO_ENV[@]}" -p "${!port_var}:${!port_var}" \
    -v "$APPDATA/$app:/config" \
    -v "$DATA:/data" \
    -v "$MOUNT_HOST:$MOUNT_CT:rslave" \
    "${!img_var}"
done

detect_hwaccel
log "Jellyfin Hardware-Beschleunigung: $JF_HW_TYPE${JF_HW_DEV:+ ($JF_HW_DEV)}"
run_ct jellyfin $P_JELLYFIN "$ICON/jellyfin.png" -- \
  "${LSIO_ENV[@]}" "${JF_HW_ARGS[@]}" -p $P_JELLYFIN:8096 \
  -v "$APPDATA/jellyfin:/config" \
  -v "$DATA/media:/data/media" \
  -v "$MOUNT_HOST:$MOUNT_CT:rslave" \
  "$IMG_JELLYFIN"

run_ct seerr $P_SEERR "$ICON/seerr.png" -- \
  --init -e LOG_LEVEL=info -p $P_SEERR:5055 \
  -v "$APPDATA/seerr:/app/config" "$IMG_SEERR"

PR="http://$SERVER_IP:$P_PROWLARR"; RA="http://$SERVER_IP:$P_RADARR"
SO="http://$SERVER_IP:$P_SONARR";   JF="http://$SERVER_IP:$P_JELLYFIN"
SE="http://$SERVER_IP:$P_SEERR"
wait_http "$PR/ping"; wait_http "$RA/ping"; wait_http "$SO/ping"

# ------------------------------- 7. *arr konfigurieren -----------------------
# Eintrag aus Schema anlegen, falls Name noch nicht existiert
# arr_add KEY BASE RESOURCE IMPLEMENTATION NAME FIELDS_JSON [TOP_JSON]
arr_add() {
  local key=$1 base=$2 res=$3 impl=$4 name=$5 fields=$6 top=${7:-'{}'} body
  if arr "$key" GET "$base/$res" | jq -e --arg n "$name" 'any(.[]; .name==$n)' >/dev/null; then
    log "  $name in $res existiert bereits"; return 0
  fi
  body=$(arr "$key" GET "$base/$res/schema" | jq -c --arg i "$impl" --arg n "$name" \
         --argjson f "$fields" --argjson t "$top" '
    [.[] | select(.implementation==$i)][0]
    | .name=$n | .enable=true
    | .fields |= map(.name as $k | if ($f|has($k)) then .value=$f[$k] else . end)
    | . + $t')
  [[ $body != null ]] || { warn "  Implementierung $impl nicht gefunden"; return 1; }
  arr "$key" POST "$base/$res" "$body" >/dev/null && log "  $name → $res angelegt"
}

set_auth() {  # key base
  local cfg; cfg=$(arr "$1" GET "$2/config/host") || return 1
  cfg=$(jq -c --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" --arg h "$(arr_allowed_hosts)" '
    .authenticationMethod="forms" | .authenticationRequired="disabledForLocalAddresses"
    | .allowedHosts=$h
    | .username=$u | .password=$p | .passwordConfirmation=$p' <<<"$cfg")
  arr "$1" PUT "$2/config/host/$(jq -r .id <<<"$cfg")" "$cfg" >/dev/null
}

for app in radarr sonarr; do
  if [[ $app == radarr ]]; then K=$KEY_RADARR; B="$RA/api/v3"; ROOT=/data/media/movies; CATF=movieCategory; CAT=$CAT_MOVIES
  else                          K=$KEY_SONARR; B="$SO/api/v3"; ROOT=/data/media/tv;     CATF=tvCategory;    CAT=$CAT_TV; fi
  log "Konfiguriere ${app^}"
  set_auth "$K" "$B" || warn "  Login konnte nicht gesetzt werden"

  if ! arr "$K" GET "$B/rootfolder" | jq -e --arg p "$ROOT" 'any(.[]; .path==$p)' >/dev/null; then
    arr "$K" POST "$B/rootfolder" "{\"path\":\"$ROOT\"}" >/dev/null && log "  Root-Ordner $ROOT"
  fi

  arr_add "$K" "$B" downloadclient Sabnzbd InfiniDysk \
    "$(jq -nc --arg h "$SERVER_IP" --argjson p $P_INFINIDYSK --arg k "$NZBDAV_API_KEY" \
           --arg cf "$CATF" --arg c "$CAT" '{host:$h,port:$p,apiKey:$k,useSsl:false,urlBase:""} + {($cf):$c}')" \
    '{"priority":1,"removeCompletedDownloads":true,"removeFailedDownloads":true}' || true

  # Streaming-freundlich: keine Mediainfo-Analyse (würde Dateien anlesen)
  mm=$(arr "$K" GET "$B/config/mediamanagement") && \
  arr "$K" PUT "$B/config/mediamanagement/$(jq -r .id <<<"$mm")" \
      "$(jq -c '.enableMediaInfo=false' <<<"$mm")" >/dev/null || warn "  Media-Management nicht gesetzt"
done

log "Konfiguriere Prowlarr"
PB="$PR/api/v1"
set_auth "$KEY_PROWLARR" "$PB" || warn "  Login konnte nicht gesetzt werden"
for app in Radarr Sonarr; do
  [[ $app == Radarr ]] && { u=$RA; k=$KEY_RADARR; } || { u=$SO; k=$KEY_SONARR; }
  arr_add "$KEY_PROWLARR" "$PB" applications "$app" "$app" \
    "$(jq -nc --arg pu "$PR" --arg bu "$u" --arg k "$k" '{prowlarrUrl:$pu,baseUrl:$bu,apiKey:$k}')" \
    '{"syncLevel":"fullSync"}' || true
done
for entry in "${INDEXERS[@]}"; do
  IFS='|' read -r iname iurl ikey <<<"$entry"
  if arr "$KEY_PROWLARR" GET "$PB/indexer" | jq -e --arg n "$iname" 'any(.[]; .name==$n)' >/dev/null; then continue; fi
  body=$(arr "$KEY_PROWLARR" GET "$PB/indexer/schema" | jq -c --arg n "$iname" --arg u "$iurl" --arg k "$ikey" '
    ([.[] | select(.implementation=="Newznab" and (.name|test("generic";"i")))] + [.[] | select(.implementation=="Newznab")])[0]
    | .name=$n | .enable=true | .appProfileId=1
    | .fields |= map(if .name=="baseUrl" then .value=$u elif .name=="apiKey" then .value=$k
                     elif .name=="apiPath" then .value="/api" else . end)')
  arr "$KEY_PROWLARR" POST "$PB/indexer" "$body" >/dev/null && log "  Indexer $iname angelegt" || warn "  Indexer $iname fehlgeschlagen"
done

# ------------------------------- 7b. TRaSH-Guides (Recyclarr) ---------------
# Bevorzugt SEERR_PROFILE, dann ein "[German] HD"-Profil, dann irgendein
# "[German]"-Profil, sonst das erste vorhandene
pick_profile() {  # key base-url -> {"id":..,"name":..}
  arr "$1" GET "$2/api/v3/qualityprofile" | jq -c --arg p "$SEERR_PROFILE" '
    ([.[] | select(.name==$p)] + [.[] | select(.name|startswith("[German] HD"))]
     + [.[] | select(.name|startswith("[German]"))] + .)[0] | {id,name}'
}

# ---- Recyclarr-Konfiguration erzeugen ----------------------------------------
# Profil- und Gruppen-IDs kommen aus den offiziellen recyclarr/config-templates.
# "[German] Any" ist ein eigenes Profil mit den Custom Formats des TRaSH-Profils
# "[German] HD Bluray + WEB" (Score-Set "german") plus den Standard-Formaten der
# Gruppe "[Unwanted] Unwanted Formats German". Quelle: TRaSH-Guides JSON.
ANY_CF_RADARR=(
  3bc8df3a71baaac60a31ef696ea72d36 820b09bb9acbfde9c35c71e0e565dad8 b2be17d608fc88818940cd1833b0b24c
  86bc3115eb4e9873ac96904a4a68e19e f845be10da4f442654c13e1f2c3d6cd5 6aad77771dabe9d3e9d7be86f310b867
  4eadb75fb23d09dfc0a8e3f687e72287 54795711b78ea87e56127928c423689b 1bfc773c53283d47c68e535811da30b7
  aee01d40cd1bf4bcded81ee62f0f3659 a2ab25194f463f057a5559c03c84a3df 08d120d5a003ec4954b5b255c0691d79
  439f9d71becaed589058ec949e037ff3 2d136d4e33082fe573d06b1f237c40dd ed27ebfef2f323e964fb1f61391bcb35
  c20c8647f2746a1f4c4262b0fbbeeeae 5608c71bcebba0a5e666223bae8c9227 c20f169ef63c5f40c2def54abaf4438e
  403816d65392c79236dcb6dd591aeda4 af94e0fe497124d1f9ce732069ec8c3b e7718d7a3ce595f289bfee26adc178f5
  ae43b294509409a6a13919dedd4764c4 5caaaa1c08c1742aa4342d8c4cc463f2
  # Unwanted (German)
  b8cd450cbfa689c0259a01d9e29ba3d6 cae4ca30163749b891686f95532519bd cc444569854e9de0b084ab2b8b1532b2
  ed38b889b31be83fda192888e2286d83 0a3f082873eb454bde444150b70253cc 263943bc5d99550c68aad0c4278ba1c7
  a826ee9e46607bc61795c85a6f2b1279 03c430f326f10a27a9739b8bc83c30e4 c465ccc73923871b3eb1802042331306
  90a6f9a284dff5103f6346090e6280c8 e204b80c87be9497a8a6eaff48f72905 712d74cd88bceb883ee32f773656b1f5
  bfd8eb01832d646a0a89c4deb46f8564
)
ANY_CF_SONARR=(
  9aa0ca0d2d66b6f6ee51fc630f46cf6f 290078c8b266272a5cc8e251b5e2eb0b c99279ee27a154c2f20d1d505cc99e25
  8a9fcdbb445f2add0505926df3bb7b8a ed51973a811f51985f14e2f6f290e47a c5dd0fd675f85487ad5bdf97159180bd
  133589380b89f8f8394320901529bac1 7940b2fb0278f27cf4f70187f2be95d6 83b336a90d90d6b35ca673b007f80661
  d8f8e1539827967e0e564833e6c08d33 68be37323132b35cf333c81a2ac8fc16 f51b96a50b0e6196cb69724b7833d837
  bda67c2c0aae257308a4723d92475b86 c2eec878fa1989599c226ce4c287d6a7 d6819cba26b1a6508138d25fb5e32293
  c2216b7b8aa545dc1ce8388c618f8d57 e6258996055b9fbab7e9cb2f75819294 58790d4e2fdcd9733aa7ae68ba2bb503
  d84935abd3f8556dcd51d4f27e22d0a6 ec8fa7296b64e8cd390a1600981f3923 eb3d5cc0a2be0db205fb823640db6a3c
  44e7c4de10ae50265753082e5dc76047
  # Unwanted (German)
  15a05bc7c1a36e2b57fd628f8977e2fc 85c61753df5da1fb2aab6f2a47426b09 fbcb31d8dabd2a319072b84fc0b7249c
  a6a6c33d057406aaad978a6902823c35 d80c9f7cd2aad50271f1bd4e53125778 237eda4ef550a97da2c9d87b437e500b
  9c11cd3f07101cdba90a2d81cf0e56b4 e2315f990da2e2cbfc9fa5b7a6fcfe48 23297a736ca77c0fc8e70f8edd7ee56c
)
# Deutsche Tonspur erzwingen: "German" (+10000) bzw. "German DL" (+11000);
# rein englische Releases erreichen höchstens ~2500 Punkte.
ANY_MIN_SCORE=5000
ANY_UNTIL_SCORE=35000                # wie cutoffFormatScore der TRaSH-HD-Profile

# Fingerabdruck der gewünschten Konfiguration (Profile + Any + Version des Aufbaus)
recyclarr_sig() { printf '%s ' v1 "${TRASH_PROFILES[@]}" "$TRASH_ANY_GERMAN" "$ANY_MIN_SCORE" | md5sum | cut -c1-12; }

# write_recyclarr_yml APP URL KEY DATEI
write_recyclarr_yml() {
  local app=$1 url=$2 key=$3 out=$4 prof tmp pid groups=() profiles=() g qdef ids
  [[ $app == radarr ]] && qdef=movie || qdef=series
  tmp=$(mktemp -d)
  for prof in "${TRASH_PROFILES[@]}"; do
    if ! curl -fsSL "$TEMPLATES_RAW/$app/templates/$prof.yml" -o "$tmp/$prof.yml"; then
      warn "  Vorlage '$prof' für $app nicht gefunden – TRASH_PROFILES prüfen"; continue
    fi
    # Profil-ID: erster Eintrag unter quality_profiles
    pid=$(awk '/^    quality_profiles:/{f=1;next} f && /^      - trash_id:/{print $3; exit}' "$tmp/$prof.yml")
    [[ -n $pid ]] && profiles+=("$pid|$(sed -n "s/^      - trash_id: $pid *# *//p" "$tmp/$prof.yml" | head -1)")
    # Standardmäßig aktive Gruppen (nicht auskommentiert) unter custom_format_groups.add
    while read -r g; do
      [[ -n $g && " ${groups[*]} " != *" $g|"* ]] && groups+=("$g|$(grep -m1 -o "trash_id: $g *#.*" "$tmp/$prof.yml" | sed 's/.*# *//')")
    done < <(awk '/^      add:/{f=1;next} f && /^      [a-z]/{f=0} f && /^        - trash_id:/{print $3}' "$tmp/$prof.yml")
  done
  rm -rf "$tmp"
  (( ${#profiles[@]} )) || return 1

  {
    echo "# mediastack-generated: $(recyclarr_sig)"
    echo "# Erzeugt von mediastack.sh. Wird neu erzeugt (mit .bak), wenn sich"
    echo "# TRASH_PROFILES/TRASH_ANY_GERMAN ändern. Eigene Anpassungen sonst erhalten."
    echo "# yaml-language-server: \$schema=https://schemas.recyclarr.dev/v8/config-schema.json"
    echo "$app:"
    echo "  $app-mediastack:"
    echo "    base_url: $url"
    echo "    api_key: $key"
    echo "    quality_definition:"
    echo "      type: $qdef"
    echo "    quality_profiles:"
    local e
    for e in "${profiles[@]}"; do
      echo "      - trash_id: ${e%%|*}  # ${e#*|}"
      echo "        reset_unmatched_scores:"
      echo "          enabled: true"
    done
    if [[ $TRASH_ANY_GERMAN == true ]]; then
      cat <<EOF
      - name: "[German] Any"
        score_set: german
        reset_unmatched_scores:
          enabled: true
        min_format_score: $ANY_MIN_SCORE
        upgrade:
          allowed: true
          until_quality: 1080p
          until_score: $ANY_UNTIL_SCORE
        quality_sort: top
        qualities:
          - name: 1080p
            qualities: [Bluray-1080p, WEBDL-1080p, WEBRip-1080p, HDTV-1080p]
          - name: 720p
            qualities: [Bluray-720p, WEBDL-720p, WEBRip-720p, HDTV-720p]
          - name: SD
            qualities: [Bluray-576p, Bluray-480p, WEBDL-480p, WEBRip-480p, DVD, SDTV]
EOF
    fi
    if (( ${#groups[@]} )); then
      echo "    custom_format_groups:"
      echo "      add:"
      for e in "${groups[@]}"; do echo "        - trash_id: ${e%%|*}  # ${e#*|}"; done
    fi
    if [[ $TRASH_ANY_GERMAN == true ]]; then
      [[ $app == radarr ]] && ids=("${ANY_CF_RADARR[@]}") || ids=("${ANY_CF_SONARR[@]}")
      echo "    custom_formats:"
      echo "      - trash_ids:"
      for e in "${ids[@]}"; do echo "          - $e"; done
      echo "        assign_scores_to:"
      echo '          - name: "[German] Any"'
    fi
  } > "$out"
}

if [[ $RECYCLARR_ENABLED == true ]]; then
  log "TRaSH-Guides über Recyclarr: ${TRASH_PROFILES[*]}$([[ $TRASH_ANY_GERMAN == true ]] && echo ' + [German] Any')"
  RC="$APPDATA/recyclarr"
  mkdir -p "$RC/configs"
  sig=$(recyclarr_sig)
  for app in radarr sonarr; do
    f="$RC/configs/$app.yml"
    if [[ -f $f ]] && grep -q "^# mediastack-generated: $sig" "$f"; then
      log "  $app.yml aktuell – deine Anpassungen bleiben"; continue
    fi
    if [[ $app == radarr ]]; then u=$RA; k=$KEY_RADARR; else u=$SO; k=$KEY_SONARR; fi
    [[ -f $f ]] && cp -p "$f" "$f.bak" && log "  alte $app.yml gesichert als $app.yml.bak"
    if write_recyclarr_yml "$app" "$u" "$k" "$f.new"; then
      mv -f "$f.new" "$f"; log "  $app.yml erzeugt"
    else
      rm -f "$f.new"; warn "  $app.yml konnte nicht erzeugt werden – bisherige Datei bleibt"
    fi
  done
  chown -R "$PUID:$PGID" "$RC"; chmod 600 "$RC"/configs/*.yml 2>/dev/null || true

  run_ct recyclarr "" "$ICON/recyclarr.png" -- \
    --user "$PUID:$PGID" -e CRON_SCHEDULE="$RECYCLARR_SCHEDULE" \
    -v "$RC:/config" "$IMG_RECYCLARR"

  sleep 3
  log "  Erster Abgleich (kann 1–2 Minuten dauern)"
  if docker exec recyclarr recyclarr sync >"$RC/last-sync.log" 2>&1; then
    log "  Profile und Custom Formats übernommen"
  else
    warn "  Recyclarr-Abgleich mit Fehlern – Details: $RC/last-sync.log"
    tail -n 15 "$RC/last-sync.log" | sed 's/^/      /' >&2 || true
  fi
  [[ $TRASH_ANY_GERMAN == true ]] && radarr_fix_profile_language
fi

# ------------------------------- 8. Jellyfin ---------------------------------
# HW-Beschleunigung in Jellyfin eintragen (Dashboard → Wiedergabe → Transcoding).
# Eine vorhandene Einstellung bleibt, außer JELLYFIN_HWACCEL_FORCE=true.
jf_set_hwaccel() {
  [[ $JF_HW_TYPE == none ]] && return 0
  local enc cur
  enc=$(jfc GET /System/Configuration/encoding) || return 1
  cur=$(jq -r '.HardwareAccelerationType // "none"' <<<"$enc")
  if [[ ${cur,,} != none && $JELLYFIN_HWACCEL_FORCE != true ]]; then
    log "  Hardware-Beschleunigung bereits eingestellt ($cur) – unverändert"; return 0
  fi
  enc=$(jq -c --arg t "$JF_HW_TYPE" --arg d "$JF_HW_DEV" '
    .HardwareAccelerationType = $t
    | .EnableHardwareEncoding = true
    | .HardwareDecodingCodecs = ["h264","hevc","mpeg2video","vc1","vp9"]
    | .EnableDecodingColorDepth10Hevc = true
    | .EnableDecodingColorDepth10Vp9 = true
    | (if $d != "" then .VaapiDevice = $d | .QsvDevice = $d else . end)
    | (if $t == "qsv" or $t == "nvenc" then .EnableTonemapping = true else . end)' <<<"$enc")
  jfc POST /System/Configuration/encoding "$enc" >/dev/null || return 1
  log "  Hardware-Beschleunigung: $JF_HW_TYPE${JF_HW_DEV:+ ($JF_HW_DEV)}"
}

log "Konfiguriere Jellyfin"
wait_http "$JF/health"
JF_AUTH='MediaBrowser Client="mediastack", Device="setup", DeviceId="mediastack-setup", Version="1.0"'
jfc() { local m=$1 u=$2 d=${3:-}; http "$m" "$JF$u" "$d" -H "Authorization: $JF_AUTH${JF_TOKEN:+, Token=\"$JF_TOKEN\"}"; }

JF_TOKEN=""
wait_http "$JF/System/Info/Public" || die "Jellyfin antwortet nicht – Logs: docker logs jellyfin"
if [[ $(jfc GET /System/Info/Public | jq -r .StartupWizardCompleted) != true ]]; then
  jfc POST /Startup/Configuration "$(jq -nc --arg l "$LANG_CODE" --arg c "$COUNTRY_CODE" \
       '{UICulture:$l,MetadataCountryCode:$c,PreferredMetadataLanguage:$l}')" >/dev/null
  jfc GET  /Startup/User >/dev/null
  jfc POST /Startup/User "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{Name:$u,Password:$p}')" >/dev/null
  jfc POST /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
  jfc POST /Startup/Complete >/dev/null
  log "  Einrichtungsassistent abgeschlossen"
fi

JF_TOKEN=$(jfc POST /Users/AuthenticateByName \
  "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{Username:$u,Pw:$p}')" | jq -r .AccessToken) || JF_TOKEN=""
JF_KEY=""
if [[ -n $JF_TOKEN && $JF_TOKEN != null ]]; then
  existing=$(jfc GET /Library/VirtualFolders | jq -r '.[].Name')
  add_lib() {  # name type path
    grep -qx "$1" <<<"$existing" && return 0
    jfc POST "/Library/VirtualFolders?name=$1&collectionType=$2&refreshLibrary=true" \
      "$(jq -nc --arg p "$3" --arg l "$LANG_CODE" --arg c "$COUNTRY_CODE" '{LibraryOptions:{
          PathInfos:[{Path:$p}], PreferredMetadataLanguage:$l, MetadataCountryCode:$c,
          EnableTrickplayImageExtraction:false, ExtractTrickplayImagesDuringLibraryScan:false,
          EnableChapterImageExtraction:false, ExtractChapterImagesDuringLibraryScan:false,
          EnableRealtimeMonitor:false }}')" >/dev/null && log "  Bibliothek $1 → $3"
  }
  add_lib Filme  movies  /data/media/movies
  add_lib Serien tvshows /data/media/tv
  jf_set_hwaccel || warn "  Hardware-Beschleunigung konnte nicht gesetzt werden – Dashboard → Wiedergabe → Transcoding"

  JF_KEY=$(jfc GET /Auth/Keys | jq -r '[.Items[] | select(.AppName=="mediastack")][0].AccessToken // empty')
  if [[ -z $JF_KEY ]]; then
    jfc POST "/Auth/Keys?app=mediastack" >/dev/null
    JF_KEY=$(jfc GET /Auth/Keys | jq -r '[.Items[] | select(.AppName=="mediastack")][0].AccessToken // empty')
  fi
else
  warn "  Jellyfin-Login fehlgeschlagen (bestehende Instanz mit anderem Passwort?) – Bibliotheken bitte manuell anlegen."
fi

if [[ -n $JF_KEY ]]; then
  NOTIF_TOP='{"onDownload":true,"onUpgrade":true,"onRename":true,"onMovieDelete":true,"onMovieFileDelete":true,"onSeriesDelete":true,"onEpisodeFileDelete":true}'
  NOTIF_F=$(jq -nc --arg h "$SERVER_IP" --argjson p $P_JELLYFIN --arg k "$JF_KEY" \
            '{host:$h,port:$p,useSsl:false,apiKey:$k,notify:false,updateLibrary:true}')
  arr_add "$KEY_RADARR" "$RA/api/v3" notification MediaBrowser Jellyfin "$NOTIF_F" "$NOTIF_TOP" || true
  arr_add "$KEY_SONARR" "$SO/api/v3" notification MediaBrowser Jellyfin "$NOTIF_F" "$NOTIF_TOP" || true
fi

# ------------------------------- 9. Seerr ------------------------------------
log "Konfiguriere Seerr"
wait_http "$SE/api/v1/status"
JAR=$(mktemp)
se() { local m=$1 u=$2 d=${3:-}; http "$m" "$SE/api/v1$u" "$d" -b "$JAR" -c "$JAR"; }

# Jellyfin-Bibliotheken in Seerr synchronisieren und alle aktivieren
# (Seerr >= 3.x: POST .../library/sync + PUT .../library/<id>; ältere: GET ?sync/&enable)
seerr_libraries() {
  local libs id ids
  if libs=$(se POST /settings/jellyfin/library/sync 2>/dev/null); then
    [[ $(jq length <<<"$libs") -gt 0 ]] || { warn "  Jellyfin hat keine Film-/Serien-Bibliotheken"; return 1; }
    for id in $(jq -r '.[].id' <<<"$libs"); do
      se PUT "/settings/jellyfin/library/$id" '{"enabled":true}' >/dev/null || return 1
    done
  else
    ids=$(se GET "/settings/jellyfin/library?sync=true" | jq -r '[.[].id] | join(",")') || return 1
    se GET "/settings/jellyfin/library?enable=$ids" >/dev/null || return 1
  fi
  log "  Seerr: Jellyfin-Bibliotheken aktiviert"
}

seerr_setup() {
  # Anmelden. Ist der Jellyfin-Host schon gespeichert (halb abgeschlossene
  # Einrichtung), lehnt Seerr "hostname" ab -> dann ohne Host erneut.
  se POST /auth/jellyfin "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" --arg h "$SERVER_IP" \
     --argjson port $P_JELLYFIN --arg e "$ADMIN_EMAIL" \
     '{username:$u,password:$p,hostname:$h,port:$port,useSsl:false,urlBase:"",email:$e,serverType:2}')" >/dev/null 2>&1 \
  || se POST /auth/jellyfin "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')" >/dev/null \
  || return 1
  seerr_libraries || return 1

  rp=$(pick_profile "$KEY_RADARR" "$RA") || return 1
  se POST /settings/radarr "$(jq -nc --arg h "$SERVER_IP" --argjson port $P_RADARR --arg k "$KEY_RADARR" --argjson qp "$rp" '{
      name:"Radarr", hostname:$h, port:$port, apiKey:$k, useSsl:false, baseUrl:"",
      activeProfileId:$qp.id, activeProfileName:$qp.name, activeDirectory:"/data/media/movies",
      is4k:false, minimumAvailability:"released", tags:[], isDefault:true,
      externalUrl:"", syncEnabled:true, preventSearch:false }')" >/dev/null || return 1

  sp=$(pick_profile "$KEY_SONARR" "$SO") || return 1
  se POST /settings/sonarr "$(jq -nc --arg h "$SERVER_IP" --argjson port $P_SONARR --arg k "$KEY_SONARR" --argjson qp "$sp" '{
      name:"Sonarr", hostname:$h, port:$port, apiKey:$k, useSsl:false, baseUrl:"",
      activeProfileId:$qp.id, activeProfileName:$qp.name, activeDirectory:"/data/media/tv",
      activeAnimeProfileId:$qp.id, activeAnimeProfileName:$qp.name, activeAnimeDirectory:"/data/media/tv",
      seriesType:"standard", animeSeriesType:"anime", tags:[], animeTags:[],
      is4k:false, isDefault:true, enableSeasonFolders:true,
      externalUrl:"", syncEnabled:true, preventSearch:false }')" >/dev/null || return 1

  se POST /settings/initialize >/dev/null
}

seerr_use_profile() {  # Standard-Server in Seerr auf das TRaSH-Profil umstellen
  se POST /auth/jellyfin "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')" >/dev/null || return 1
  local svc key base qp servers id body
  for svc in radarr sonarr; do
    if [[ $svc == radarr ]]; then key=$KEY_RADARR; base=$RA; else key=$KEY_SONARR; base=$SO; fi
    qp=$(pick_profile "$key" "$base") || return 1
    [[ $(jq -r .name <<<"$qp") == "[German]"* ]] || continue
    servers=$(se GET "/settings/$svc") || return 1
    for id in $(jq -r --arg n "$(jq -r .name <<<"$qp")" '.[] | select(.is4k|not) | select(.activeProfileName != $n) | .id' <<<"$servers"); do
      body=$(jq -c --argjson id "$id" --argjson qp "$qp" '.[] | select(.id==$id)
              | .activeProfileId=$qp.id | .activeProfileName=$qp.name' <<<"$servers")
      se PUT "/settings/$svc/$id" "$body" >/dev/null && log "  Seerr ($svc) nutzt jetzt Profil $(jq -r .name <<<"$qp")"
    done
  done
}

if [[ $(se GET /settings/public | jq -r .initialized) == true ]]; then
  log "  Seerr ist bereits eingerichtet"
  if [[ $RECYCLARR_ENABLED == true && $SEERR_USE_TRASH_PROFILE == true ]]; then
    seerr_use_profile || warn "  Seerr-Profil konnte nicht umgestellt werden (Login?) – in Seerr unter Einstellungen → Dienste anpassen."
  fi
elif seerr_setup; then
  log "  Seerr mit Jellyfin, Radarr und Sonarr verbunden"
else
  warn "  Seerr-Automatik fehlgeschlagen – Assistent unter $SE kurz manuell durchklicken (Jellyfin: $JF)."
fi
rm -f "$JAR"

install_watchdog

# ------------------------------- 10. Dashboard -------------------------------
if [[ $DASHBOARD_ENABLED == true ]]; then
  log "Dashboard"
  write_dashboard
  if host_healthy 2>/dev/null; then write_mount_status 0; else write_mount_status 1 "Mount bei der Installation nicht sichtbar"; fi
  run_ct dashboard "$P_DASHBOARD" "$ICON/homepage.png" -- \
    -p "$P_DASHBOARD:80" -v "$DASH_DIR:/usr/share/nginx/html:ro" "$IMG_DASHBOARD"
  install_dashboard_job
  log "  Status-Job aktiv (jede Minute)"
elif exists dashboard; then
  remove_ct dashboard
  install_dashboard_job
fi

# ------------------------------- Fertig --------------------------------------
cat <<EOF

${c_b}════════════ Media-Stack bereit ════════════${c_0}
$([[ $DASHBOARD_ENABLED == true ]] && echo "  Dashboard   http://$SERVER_IP:$P_DASHBOARD   ← alle Links + API-Keys")
  Seerr       $SE        ← hier Filme/Serien anfragen
  Jellyfin    $JF
  Radarr      $RA
  Sonarr      $SO
  Prowlarr    $PR
  InfiniDysk  $ND

  Login überall: ${c_b}$ADMIN_USER${c_0} / (dein Passwort)
  API-Keys & Zugangsdaten: $SECRETS  (chmod 600)

${c_b}Noch offen:${c_0}
  • Indexer in Prowlarr hinzufügen (falls nicht über INDEXERS gesetzt) –
    sie werden automatisch an Radarr & Sonarr verteilt.
EOF

if (( APPLY )); then
  docker image prune -f >/dev/null 2>&1 || true
fi
