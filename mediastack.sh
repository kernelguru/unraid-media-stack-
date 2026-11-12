#!/bin/bash
# =============================================================================
#  mediastack.sh – Usenet-Streaming-Media-Stack für Unraid
#
#  Installiert und verbindet:
#    InfiniDysk (NzbDAV-Fork) + rclone-WebDAV-Mount
#    Prowlarr, Radarr, Sonarr, Jellyfin, Seerr
#
#  Aufruf (als root im Unraid-Terminal / per SSH):
#    bash mediastack.sh                 -> installieren + konfigurieren (idempotent)
#    bash mediastack.sh update          -> Images aktualisieren + geänderte Konfig übernehmen
#    bash mediastack.sh self-update     -> Script von GitHub holen, danach "update"
#    bash mediastack.sh recreate NAME.. -> einzelne Container neu anlegen
#    bash mediastack.sh status          -> Container-Status anzeigen
#    bash mediastack.sh remove          -> Container entfernen (Daten bleiben!)
#
#  Eigene Werte: entweder unten im Block "KONFIGURATION" ändern oder eine Datei
#  "mediastack.conf" neben das Script legen (wird automatisch geladen).
# =============================================================================
set -Eeuo pipefail
SCRIPT_VERSION="1.2.0"
REPO_RAW="https://raw.githubusercontent.com/kernelguru/unraid-media-stack-/main"

# ------------------------------- KONFIGURATION -------------------------------
SERVER_IP=""                         # leer = automatisch erkennen
TZ="Europe/Berlin"
PUID=99                              # Unraid-Standard: nobody
PGID=100                             # Unraid-Standard: users
UMASK=002

APPDATA="/mnt/user/appdata"          # Container-Configs
DATA="/mnt/user/data"                # Medienbibliothek (media/movies, media/tv)
MOUNT_HOST="/mnt/addons/nzbdav"      # rclone-Mount auf dem Host (NICHT unter /mnt/user!)
MOUNT_CT="/mnt/nzbdav"               # derselbe Mount in allen Containern

ADMIN_USER="admin"                   # Login für Radarr/Sonarr/Prowlarr/Jellyfin/Seerr
ADMIN_PASS=""                        # leer = wird abgefragt
ADMIN_EMAIL="admin@mediastack.local" # nur für Seerr

LANG_CODE="de"                       # Jellyfin-UI/Metadaten
COUNTRY_CODE="DE"

CAT_MOVIES="movies"                  # Kategorien in InfiniDysk (SABnzbd-Tab)
CAT_TV="tv"
RCLONE_CACHE_SIZE="50G"              # VFS-Cache für Streaming

# Images
IMG_INFINIDYSK="ghcr.io/infinidysk/infinidysk:latest"   # ggf. anpassen!
IMG_RCLONE="rclone/rclone:latest"
IMG_PROWLARR="lscr.io/linuxserver/prowlarr:latest"
IMG_RADARR="lscr.io/linuxserver/radarr:latest"
IMG_SONARR="lscr.io/linuxserver/sonarr:latest"
IMG_JELLYFIN="lscr.io/linuxserver/jellyfin:latest"
IMG_SEERR="ghcr.io/seerr-team/seerr:latest"
IMG_RECYCLARR="ghcr.io/recyclarr/recyclarr:8"    # "latest" wird nicht mehr gepflegt

# Ports
P_INFINIDYSK=3000; P_PROWLARR=9696; P_RADARR=7878
P_SONARR=8989;     P_JELLYFIN=8096; P_SEERR=5055

# TRaSH-Guides per Recyclarr (Qualitätsprofile + Custom Formats)
RECYCLARR_ENABLED=true
# Deutsche Profile: german-hd-bluray-web, german-hd-remux-web,
#   german-uhd-bluray-web, german-uhd-bluray-web-alternative,
#   german-uhd-remux-web, german-anime-hd-bluray-web
TRASH_PROFILE="german-hd-bluray-web"
RECYCLARR_SCHEDULE="@daily"          # automatischer Abgleich (Cron-Syntax)
SEERR_USE_TRASH_PROFILE=true         # Seerr fordert mit dem TRaSH-Profil an
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

STATE_DIR="$APPDATA/mediastack"
SECRETS="$STATE_DIR/secrets.env"
CONTAINERS=(seerr jellyfin recyclarr sonarr radarr prowlarr rclone-nzbdav infinidysk)

# ------------------------------- Hilfsfunktionen -----------------------------
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
log()  { echo "${c_g}==>${c_0} $*"; }
warn() { echo "${c_y}[!]${c_0} $*" >&2; }
die()  { echo "${c_r}[x]${c_0} $*" >&2; exit 1; }
trap 'die "Abbruch in Zeile $LINENO: $BASH_COMMAND"' ERR

jq() {  # Unraid hat meist jq – sonst per Container
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
  if ! awk -v m="$MOUNT_HOST" '$2==m && /fuse/' /proc/mounts | grep -q .; then
    mountpoint -q "$MOUNT_HOST" || mount --bind "$MOUNT_HOST" "$MOUNT_HOST"
    mount --make-shared "$MOUNT_HOST"
  fi
}

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

# ------------------------------- Sub-Kommandos -------------------------------
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SELF_NAME="$(basename "$SELF")"
usage() { sed -n '9,15p' "$SELF" | sed 's/^#//'; }

CMD=${1:-install}; shift || true
APPLY=0; PULL=0
case "$CMD" in
  status)
    docker ps -a --filter "name=^($(IFS='|'; echo "${CONTAINERS[*]}"))$" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo "Script-Version: $SCRIPT_VERSION"; exit 0 ;;
  remove)
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
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."
[[ -f /etc/unraid-version ]] || warn "Kein Unraid erkannt – fahre trotzdem fort."
docker info >/dev/null 2>&1 || die "Docker läuft nicht (Array gestartet? Docker aktiviert?)."
[[ -d /mnt/user ]] || die "/mnt/user fehlt – ist das Array gestartet?"
[[ -e /dev/fuse ]] || die "/dev/fuse fehlt – rclone-Mount nicht möglich."

[[ -n $SERVER_IP ]] || SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[[ -n $SERVER_IP ]] || die "Server-IP nicht erkannt – bitte SERVER_IP setzen."
log "Server-IP: $SERVER_IP"

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
GO=/boot/config/go
if [[ -f $GO ]] && ! grep -q '# >>> mediastack' "$GO"; then
  log "Trage Mount-Vorbereitung in $GO ein (für Neustarts)"
  cat >> "$GO" <<EOF

# >>> mediastack (rclone/InfiniDysk mount propagation)
mkdir -p $MOUNT_HOST
mountpoint -q $MOUNT_HOST || mount --bind $MOUNT_HOST $MOUNT_HOST
mount --make-shared $MOUNT_HOST
# <<< mediastack
EOF
fi

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
run_ct infinidysk $P_INFINIDYSK "" -- \
  "${LSIO_ENV[@]}" -p $P_INFINIDYSK:3000 \
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

code=$(curl -s -o /dev/null -w '%{http_code}' -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND -H 'Depth: 1' "$ND/" || true)
[[ $code == 207 ]] || warn "WebDAV-Login liefert HTTP $code (erwartet 207) – Zugangsdaten prüfen. Werte in $SECRETS löschen und Script neu starten."

# ------------------------------- 5. rclone-Mount -----------------------------
RC_DIR="$APPDATA/rclone-nzbdav"
OBSCURED=$(docker run --rm "$IMG_RCLONE" obscure "$WEBDAV_PASS")
cat > "$RC_DIR/rclone.conf" <<EOF
[nzbdav]
type = webdav
url = $ND/
vendor = other
user = $WEBDAV_USER
pass = $OBSCURED
EOF
chmod 600 "$RC_DIR/rclone.conf"

run_ct rclone-nzbdav "" "$ICON/rclone.png" -- \
  --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined \
  -v "$RC_DIR:/config/rclone" \
  -v "$RC_DIR/cache:/cache" \
  -v "$MOUNT_HOST:$MOUNT_CT:rshared" \
  --entrypoint sh "$IMG_RCLONE" -c \
  "fusermount3 -uz $MOUNT_CT 2>/dev/null; fusermount -uz $MOUNT_CT 2>/dev/null; \
   exec rclone mount nzbdav: $MOUNT_CT --config /config/rclone/rclone.conf \
   --allow-other --links --use-cookies \
   --uid $PUID --gid $PGID --umask $UMASK \
   --dir-cache-time 1s --buffer-size 32M \
   --vfs-cache-mode full --vfs-cache-max-size $RCLONE_CACHE_SIZE --vfs-cache-max-age 24h \
   --cache-dir /cache"

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

JF_GPU=(); [[ -e /dev/dri ]] && JF_GPU=(--device /dev/dri)
run_ct jellyfin $P_JELLYFIN "$ICON/jellyfin.png" -- \
  "${LSIO_ENV[@]}" "${JF_GPU[@]}" -p $P_JELLYFIN:8096 \
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
  cfg=$(jq -c --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '
    .authenticationMethod="forms" | .authenticationRequired="disabledForLocalAddresses"
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
# Bevorzugt ein "[German] ..."-Profil, sonst das erste vorhandene
pick_profile() {  # key base-url -> {"id":..,"name":..}
  arr "$1" GET "$2/api/v3/qualityprofile" | jq -c '([.[] | select(.name|startswith("[German]"))] + .)[0] | {id,name}'
}

if [[ $RECYCLARR_ENABLED == true ]]; then
  log "TRaSH-Guides über Recyclarr: $TRASH_PROFILE"
  RC="$APPDATA/recyclarr"
  mkdir -p "$RC/configs"
  for app in radarr sonarr; do
    f="$RC/configs/$app.yml"
    if [[ -f $f ]]; then log "  $app.yml existiert – deine Anpassungen bleiben"; continue; fi
    if [[ $app == radarr ]]; then u=$RA; k=$KEY_RADARR; else u=$SO; k=$KEY_SONARR; fi
    if ! curl -fsSL "$TEMPLATES_RAW/$app/templates/$TRASH_PROFILE.yml" -o "$f.tmp"; then
      rm -f "$f.tmp"; warn "  Vorlage '$TRASH_PROFILE' für $app nicht gefunden – TRASH_PROFILE prüfen"; continue
    fi
    sed -e "0,/base_url:/s|^\([[:space:]]*base_url:\).*|\1 $u|" \
        -e "0,/api_key:/s|^\([[:space:]]*api_key:\).*|\1 $k|" "$f.tmp" > "$f"
    rm -f "$f.tmp"
    log "  $app.yml aus Vorlage erstellt"
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
fi

# ------------------------------- 8. Jellyfin ---------------------------------
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

seerr_setup() {
  se POST /auth/jellyfin "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" --arg h "$SERVER_IP" \
     --argjson port $P_JELLYFIN --arg e "$ADMIN_EMAIL" \
     '{username:$u,password:$p,hostname:$h,port:$port,useSsl:false,urlBase:"",email:$e,serverType:2}')" >/dev/null || return 1
  ids=$(se GET "/settings/jellyfin/library?sync=true" | jq -r '[.[].id] | join(",")') || return 1
  se GET "/settings/jellyfin/library?enable=$ids" >/dev/null || return 1

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

# ------------------------------- Fertig --------------------------------------
cat <<EOF

${c_b}════════════ Media-Stack bereit ════════════${c_0}
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
