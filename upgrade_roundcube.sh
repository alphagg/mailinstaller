#!/usr/bin/env bash
set -euo pipefail
# Roundcube upgrader for AlmaLinux 9 + iRedMail
# Safe across mixed 1.6.6/1.6.7/1.6.8 -> 1.6.11
# - Detects Roundcube path
# - Reads DB DSN from config.inc.php
# - Backs up code & DB
# - Downloads 1.6.11 from your GitHub mirror (checksum pinned)
# - Runs bin/installto.sh (handles schema hops)
# - Ensures cache/temp exist
# - Restarts php-fpm + reloads nginx
# - Idempotent: skips if already 1.6.11; refuses downgrades
#
# Usage:
#   bash upgrade_roundcube.sh
# Overrides:
#   RC_PATH=/path VERSION=1.6.11 SRC_URL=https://... SHA256_EXPECTED=<hex> bash upgrade_roundcube.sh
# or:
#   bash upgrade_roundcube.sh --rc-path /path --version 1.6.11 --src-url https://... --sha256 <hex>
#
# Debug:
#   DEBUG=1 bash upgrade_roundcube.sh

[[ "${DEBUG:-0}" = "1" ]] && set -x

VERSION_DEFAULT="1.6.11"
SRC_URL_DEFAULT="https://raw.githubusercontent.com/alphagg/mailinstaller/main/roundcubemail-1.6.11-complete.tar.gz"
SHA256_DEFAULT="2ab4ddd8ff3e010ae1e7cacc29402ee82b5121153d55cbec56feb1746844d575"

RC_PATH="${RC_PATH:-}"
VERSION="${VERSION:-$VERSION_DEFAULT}"
SRC_URL="${SRC_URL:-$SRC_URL_DEFAULT}"
SHA256_EXPECTED="${SHA256_EXPECTED:-$SHA256_DEFAULT}"

RC_PATHS_CANDIDATES=(/opt/www/roundcubemail /usr/share/roundcubemail /var/www/html/roundcubemail)

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."; }

# --- Args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rc-path) RC_PATH="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --src-url) SRC_URL="${2:-}"; shift 2 ;;
    --sha256)  SHA256_EXPECTED="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--rc-path PATH] [--version X.Y.Z] [--src-url URL] [--sha256 HEX]
Defaults:
  --version   ${VERSION_DEFAULT}
  --src-url   ${SRC_URL_DEFAULT}
  --sha256    ${SHA256_DEFAULT}
To disable checksum verification: SHA256_EXPECTED=""
EOF
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root

# --- Detect RC path ---
if [[ -z "${RC_PATH}" ]]; then
  for p in "${RC_PATHS_CANDIDATES[@]}"; do
    if [[ -d "$p" && -f "$p/index.php" ]]; then RC_PATH="$p"; break; fi
  done
fi
[[ -n "$RC_PATH" ]] || die "Could not detect Roundcube path. Use --rc-path."
[[ -d "$RC_PATH" ]] || die "Roundcube path not found: $RC_PATH"
log "Roundcube path: $RC_PATH"

# --- Detect current RC version (composer.json then Roundcube.php) ---
detect_version() {
  local path="$1" v=""
  set +e
  if [[ -f "$path/composer.json" ]]; then
    v="$(php -r 'echo (json_decode(file_get_contents(getenv("F")), true)["version"] ?? "");' 2>/dev/null F="$path/composer.json")"
  fi
  if [[ -z "$v" && -f "$path/program/lib/Roundcube.php" ]]; then
    v="$(php -r '$s=@file_get_contents(getenv("F")); if(preg_match('/const VERSION\\s*=\\s*\\"([0-9.]+)\\"/',$s,$m)) echo $m[1];' 2>/dev/null F="$path/program/lib/Roundcube.php")"
  fi
  set -e
  echo "$v"
}

CURRENT_VER="$(detect_version "$RC_PATH")"
[[ -n "$CURRENT_VER" ]] && log "Current Roundcube version: ${CURRENT_VER}" || log "Current Roundcube version: unknown"

# --- Simple semver compare (X.Y.Z only) ---
verlte() { [ "$1" = "$2" ] && return 0 || [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }
verlt()  { [ "$1" = "$2" ] && return 1 || [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }

if [[ -n "$CURRENT_VER" ]]; then
  if [[ "$CURRENT_VER" = "$VERSION" ]]; then
    log "Already at target ${VERSION}. Nothing to do."
    exit 0
  fi
  if verlt "$VERSION" "$CURRENT_VER"; then
    die "Target version ${VERSION} is lower than current ${CURRENT_VER}. Refusing downgrade."
  fi
fi

# --- Locate config & DB creds ---
CONFIG_FILE=""
for c in "$RC_PATH/config/config.inc.php" "/etc/roundcubemail/config.inc.php"; do
  [[ -f "$c" ]] && CONFIG_FILE="$c" && break
done
[[ -n "$CONFIG_FILE" ]] || die "config.inc.php not found."

DB_DSN=$(php -r "include '${CONFIG_FILE}'; echo isset(\$config['db_dsnw']) ? \$config['db_dsnw'] : '';" 2>/dev/null || true)
[[ -n "$DB_DSN" ]] || die "Cannot read \$config['db_dsnw'] from ${CONFIG_FILE}."

# Parse DSN safely
read -r DB_DRIVER DB_USER DB_PASS DB_HOST DB_NAME < <(DB_DSN="${DB_DSN}" php -r '
  $u = parse_url(getenv("DB_DSN"));
  $driver = $u["scheme"] ?? "mysql";
  $user   = $u["user"]   ?? "root";
  $pass   = $u["pass"]   ?? "";
  $host   = $u["host"]   ?? "localhost";
  $db     = ltrim(($u["path"] ?? "/roundcubemail"), "/");
  echo "$driver $user $pass $host $db";
' 2>/dev/null)
[[ "$DB_DRIVER" == "mysql" || "$DB_DRIVER" == "mysqli" ]] || die "Unsupported DB driver: $DB_DRIVER"
log "DB: ${DB_NAME} on ${DB_HOST} (user: ${DB_USER})"

# --- Tools check ---
for b in mysqldump mysql tar php curl systemctl; do command -v "$b" >/dev/null || die "$b not found."; done

# --- Service names (avoid fragile pipes) ---
PHPFPM_SVC=""
for s in php-fpm php-fpm80 php-fpm81 php-fpm82; do
  if systemctl status "$s" >/dev/null 2>&1; then PHPFPM_SVC="$s"; break; fi
done
[[ -n "$PHPFPM_SVC" ]] || PHPFPM_SVC="php-fpm"
NGINX_SVC="nginx"

# --- Ensure cache/temp exist & are writable ---
mkdir -p "${RC_PATH}/cache" "${RC_PATH}/temp"
chown -R nginx:nginx "${RC_PATH}/cache" "${RC_PATH}/temp" || true
chmod 775 "${RC_PATH}/cache" "${RC_PATH}/temp" || true

# --- Workdir & backups ---
TS="$(date +%F-%H%M%S)"
WORKDIR="/root/roundcube-upgrade-${TS}"
mkdir -p "${WORKDIR}"
log "Workdir: ${WORKDIR}"

CODE_BKP="${WORKDIR}/roundcube-code-${TS}.tar.gz"
log "Backing up code to ${CODE_BKP}"
tar -czf "${CODE_BKP}" -C "$(dirname "$RC_PATH")" "$(basename "$RC_PATH")"

DB_BKP="${WORKDIR}/roundcube-db-${DB_NAME}-${TS}.sql"
log "Backing up DB to ${DB_BKP}"
if [[ -n "${DB_PASS}" ]]; then
  mysqldump -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASS}" --single-transaction --quick --routines --triggers "${DB_NAME}" > "${DB_BKP}"
else
  if [[ -f /root/.my.cnf ]]; then
    mysqldump -h "${DB_HOST}" -u "${DB_USER}" --single-transaction --quick --routines --triggers "${DB_NAME}" > "${DB_BKP}"
  else
    die "No DB password available and /root/.my.cnf not present."
  fi
fi

# --- Download tarball ---
DL="${WORKDIR}/roundcubemail-${VERSION}-complete.tar.gz"
log "Downloading Roundcube ${VERSION} from ${SRC_URL}"
curl -fL --retry 3 --retry-delay 2 -o "${DL}" "${SRC_URL}"

if [[ -n "${SHA256_EXPECTED}" ]]; then
  ACTUAL_SHA256="$(sha256sum "${DL}" | awk '{print $1}')"
  [[ "${ACTUAL_SHA256}" == "${SHA256_EXPECTED}" ]] || die "Checksum mismatch. Expected ${SHA256_EXPECTED}, got ${ACTUAL_SHA256}"
fi

# --- Extract & upgrade ---
EXTRACT_DIR="${WORKDIR}/src"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${DL}" -C "${EXTRACT_DIR}"
NEW_DIR="$(find "${EXTRACT_DIR}" -maxdepth 1 -type d -name "roundcubemail-*")"
[[ -n "${NEW_DIR}" ]] || die "Extracted directory not found."

log "Running installto.sh"
pushd "${NEW_DIR}" >/dev/null
bash bin/installto.sh "${RC_PATH}"
popd >/dev/null

# --- Clear cache & restart ---
log "Clearing cache"
rm -rf "${RC_PATH}/cache/"* "${RC_PATH}/temp/"* || true

log "Restarting ${PHPFPM_SVC} and reloading ${NGINX_SVC}"
systemctl restart "${PHPFPM_SVC}" || log "Warning: failed to restart ${PHPFPM_SVC}"
systemctl reload  "${NGINX_SVC}"   || log "Warning: failed to reload ${NGINX_SVC}"

# --- Post-check ---
NEW_VER="$(detect_version "$RC_PATH")"
if [[ -n "$NEW_VER" ]]; then
  log "Roundcube version now: ${NEW_VER}"
  if verlt "$NEW_VER" "$VERSION"; then
    log "WARNING: Detected ${NEW_VER} < target ${VERSION}. Check manually."
  fi
else
  log "Could not auto-detect version. Verify via web UI."
fi

log "Done. Backups in ${WORKDIR}"
