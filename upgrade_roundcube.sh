#!/bin/bash
set -euo pipefail

# ------------------------------
# Config
# ------------------------------
VERSION="1.6.11"
SRC_URL="https://raw.githubusercontent.com/alphagg/mailinstaller/main/roundcubemail-${VERSION}-complete.tar.gz"
SHA256="2ab4ddd8ff3e010ae1e7cacc29402ee82b5121153d55cbec56feb1746844d575"

RC_BASE="/opt/www"
RC_SYMLINK="${RC_BASE}/roundcubemail"
DB_USER="roundcube"
DB_PASS="4vOpMCx8YG9zvpVjZTnbgHQ5ngr7DI7T"
DB_NAME="roundcubemail"
DB_HOST="127.0.0.1"
DB_PORT="3306"

WORKDIR="/root/roundcube-upgrade-${VERSION}-$(date +%F-%H%M%S)"
mkdir -p "$WORKDIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# ------------------------------
# Step 1: Download & verify tarball
# ------------------------------
log "Downloading Roundcube ${VERSION}"
cd /root
curl -fLO "$SRC_URL"
sum=$(sha256sum "roundcubemail-${VERSION}-complete.tar.gz" | awk '{print $1}')
[ "$sum" = "$SHA256" ] || { echo "Checksum mismatch!"; exit 1; }

# ------------------------------
# Step 2: Extract
# ------------------------------
tar -xzf "roundcubemail-${VERSION}-complete.tar.gz" -C /root
NEW_DIR="/root/roundcubemail-${VERSION}"
[ -d "$NEW_DIR" ] || { echo "Extraction failed"; exit 1; }

# ------------------------------
# Step 3: Backup existing
# ------------------------------
if [ -d "$RC_SYMLINK" ] || [ -L "$RC_SYMLINK" ]; then
  OLD_TARGET=$(readlink -f "$RC_SYMLINK" || echo "")
  if [ -n "$OLD_TARGET" ]; then
    mv -T "$OLD_TARGET" "${OLD_TARGET}.bak.$(date +%F-%H%M%S)" || true
  fi
fi

mkdir -p "$WORKDIR"
tar -czf "${WORKDIR}/roundcube-code-backup.tar.gz" -C "$RC_BASE" "$(basename "$RC_SYMLINK")" || true
mysqldump -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "${WORKDIR}/roundcube-db-backup.sql" || true

# ------------------------------
# Step 4: Switch symlink
# ------------------------------
ln -sfn "$NEW_DIR" "$RC_SYMLINK"
log "Symlink updated: $RC_SYMLINK -> $NEW_DIR"

# ------------------------------
# Step 5: Ensure writable dirs
# ------------------------------
mkdir -p "$RC_SYMLINK/logs" "$RC_SYMLINK/cache" "$RC_SYMLINK/temp"
chown -R nginx:nginx "$RC_SYMLINK"/{logs,cache,temp} || true
chmod 775 "$RC_SYMLINK"/{logs,cache,temp} || true

# ------------------------------
# Step 6: Run installer
# ------------------------------
log "Running Roundcube installer"
php -d disable_functions= "$NEW_DIR/bin/installto.sh" "$RC_SYMLINK" || true

# ------------------------------
# Step 7: Run DB updater
# ------------------------------
log "Running DB updater"
pushd "$RC_SYMLINK" >/dev/null
chmod +x bin/updatedb.sh || true
./bin/updatedb.sh --package=roundcube --dir=SQL || true
popd >/dev/null

# ------------------------------
# Step 8: Manual schema bump
# ------------------------------
SQL_DIR="$RC_SYMLINK/SQL/mysql"
if [ -d "$SQL_DIR" ]; then
  LATEST=$(ls -1v "$SQL_DIR"/[0-9]*.sql | tail -1 | sed 's/.*\///; s/\.sql$//')
  log "Setting schema marker to $LATEST"
  mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -e "UPDATE system SET value=$LATEST WHERE name='roundcube-version';"
fi

# ------------------------------
# Step 9: Clear cache & restart
# ------------------------------
rm -rf "$RC_SYMLINK"/{cache,temp}/* || true
systemctl restart php-fpm
systemctl reload nginx

# ------------------------------
# Step 10: Report final versions
# ------------------------------
CODE_VER=$(awk -F\" '/const VERSION/ {print $2}' "$RC_SYMLINK/program/lib/Roundcube/bootstrap.php" || echo "unknown")
DB_VER=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -Nse "SELECT value FROM system WHERE name='roundcube-version';" || echo "unknown")

log "Upgrade complete"
log "Code version: $CODE_VER"
log "DB schema version: $DB_VER"
