#!/usr/bin/env bash
#
# install_libki.sh
# Installiert den Libki Server (PC-Reservierungs-/Zeitmanagementsystem für
# öffentliche Computer, z. B. in Bibliotheken) auf Debian 13.6 "Trixie".
#
# Hinweis: Libki testet und unterstützt offiziell Ubuntu 18.04/20.04 und
# Debian 11 für die klassische (native) Installation via install.sh.
# Debian 13 wird dort nicht gelistet. Dieses Script nutzt daher den von
# Libki selbst empfohlenen Docker-Weg, der distributionsunabhängig und
# damit auch auf Debian 13.6 zuverlässig lauffähig ist.
#
# Was das Script tut:
#   1. System aktualisieren
#   2. Docker Engine + Docker Compose Plugin installieren (offizielles
#      Docker-Repository, da Debians eigenes docker.io-Paket oft veraltet ist)
#   3. Libki-Server-Repository klonen
#   4. docker-compose.yml + .env für Libki Server + MariaDB konfigurieren
#   5. Container starten
#   6. Cronjobs für Libki (Session-Timeout, nächtliche Bereinigung) einrichten
#
# Ausführen mit:
#   sudo bash install_libki.sh
#
set -euo pipefail

# ----------------------------------------------------------------------------
# 0. Vorabprüfungen
# ----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen, z. B.: sudo bash $0"
  exit 1
fi

if ! grep -qi "trixie\|13" /etc/debian_version 2>/dev/null; then
  echo "Warnung: Es konnte keine Debian 13 (Trixie) Installation eindeutig"
  echo "erkannt werden. Das Script sollte trotzdem funktionieren, da es auf"
  echo "Docker basiert, aber bitte im Zweifel manuell prüfen."
  read -rp "Trotzdem fortfahren? [j/N] " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[jJ]$ ]]; then
    exit 1
  fi
fi

INSTALL_DIR="/opt/libki-server"
LIBKI_TZ="$(cat /etc/timezone 2>/dev/null || echo "Europe/Berlin")"

echo "=== Libki Server Installation für Debian 13.6 ==="
echo "Installationsverzeichnis: ${INSTALL_DIR}"
echo "Verwendete Zeitzone: ${LIBKI_TZ}"
echo

# ----------------------------------------------------------------------------
# 1. System aktualisieren
# ----------------------------------------------------------------------------

echo "--- Aktualisiere Paketquellen ---"
apt update
apt upgrade -y
apt install -y ca-certificates curl gnupg git

# ----------------------------------------------------------------------------
# 2. Docker Engine + Compose Plugin installieren (offizielles Docker-Repo)
# ----------------------------------------------------------------------------

if ! command -v docker &>/dev/null; then
  echo "--- Installiere Docker Engine ---"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # Debian 13 (trixie) wird von Docker evtl. noch nicht als eigenes Codewort
  # geführt; falls nicht vorhanden, auf die zuletzt unterstützte Debian-Codebase
  # (bookworm) zurückfallen, was mit Docker CE kompatibel ist.
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  if ! curl -fsSL "https://download.docker.com/linux/debian/dists/${CODENAME}/Release" &>/dev/null; then
    echo "Hinweis: Docker-Repo für '${CODENAME}' noch nicht verfügbar, verwende 'bookworm' als Fallback."
    CODENAME="bookworm"
  fi

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  echo "--- Docker ist bereits installiert, überspringe Installation ---"
fi

# ----------------------------------------------------------------------------
# 3. Libki-Server-Repository klonen
# ----------------------------------------------------------------------------

echo "--- Lade Libki Server Repository ---"
if [[ -d "${INSTALL_DIR}" ]]; then
  echo "Verzeichnis ${INSTALL_DIR} existiert bereits, überspringe Klonen."
else
  git clone https://github.com/Libki/libki-server.git "${INSTALL_DIR}"
fi

cd "${INSTALL_DIR}/docker"

# ----------------------------------------------------------------------------
# 4. .env-Datei konfigurieren
#
# WICHTIG: Die Variablennamen müssen exakt zu docker/docker-compose.yml
# passen. Das offizielle Compose-File erwartet:
#   LIBKI_ADMIN_USERNAME, LIBKI_ADMIN_PASSWORD, LIBKI_INSTANCE, LIBKI_TZ,
#   LIBKI_PORT, LIBKI_MAX_WORKERS, DB_NAME, DB_USER, DB_PASS, DB_ROOT_PASS
# Falsche/fehlende Variablen (insbesondere DB_ROOT_PASS) führen dazu, dass
# der MariaDB-Container ohne Root-Passwort startet, sofort abstürzt und
# der libki-Container mit "dependency db failed to start" fehlschlägt.
# ----------------------------------------------------------------------------

echo "--- Konfiguriere Umgebungsvariablen ---"

read -rp "Admin-Benutzername für die Libki-Weboberfläche [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

ADMIN_PASSWORD="$(openssl rand -base64 18)"
DB_ROOT_PASS="$(openssl rand -base64 24)"
DB_PASS="$(openssl rand -base64 24)"

cat > .env <<EOF
LIBKI_ADMIN_USERNAME=${ADMIN_USER}
LIBKI_ADMIN_PASSWORD=${ADMIN_PASSWORD}
LIBKI_INSTANCE=libki
LIBKI_TZ=${LIBKI_TZ}
LIBKI_PORT=3000
LIBKI_MAX_WORKERS=4

DB_NAME=libki
DB_USER=libki
DB_PASS=${DB_PASS}
DB_ROOT_PASS=${DB_ROOT_PASS}
EOF

chmod 600 .env

echo "Zugangsdaten wurden in ${INSTALL_DIR}/docker/.env gespeichert."
echo "Admin-Benutzer: ${ADMIN_USER}"
echo "Admin-Passwort: ${ADMIN_PASSWORD}"
echo "Bitte diese Datei bzw. die Zugangsdaten sicher aufbewahren!"

# ----------------------------------------------------------------------------
# 5. Container starten
# ----------------------------------------------------------------------------

echo "--- Starte Libki Server + MariaDB Container ---"
docker compose up -d

echo "Warte 30 Sekunden, damit Datenbank und Server initialisieren können..."
sleep 30

# ----------------------------------------------------------------------------
# 5b. Admin-Benutzer anlegen
#
# Die Variablen LIBKI_ADMIN_USERNAME/LIBKI_ADMIN_PASSWORD in der .env werden
# vom aktuellen Docker-Image NICHT automatisch ausgewertet. Der Admin-Account
# muss über das mitgelieferte Skript im Container erstellt werden.
# ----------------------------------------------------------------------------

echo "--- Lege Admin-Benutzer an ---"
if docker compose exec -T libki /app/script/administration/create_user.pl \
    -u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}" -s; then
  echo "Admin-Benutzer '${ADMIN_USER}' wurde erfolgreich angelegt."
else
  echo "Hinweis: Admin-Benutzer konnte nicht automatisch angelegt werden."
  echo "Du kannst ihn später manuell nachholen mit:"
  echo "  cd ${INSTALL_DIR}/docker"
  echo "  docker compose exec -T libki /app/script/administration/create_user.pl -u ${ADMIN_USER} -p '<passwort>' -s"
fi

# ----------------------------------------------------------------------------
# 6. Cronjobs einrichten
# ----------------------------------------------------------------------------

echo "--- Richte Cronjobs für Libki ein ---"

# docker compose exec braucht das Compose-Projektverzeichnis (bzw. -f Pfad zur
# docker-compose.yml), aber KEINEN geratenen Containernamen. Das ist robuster
# als "docker exec <name>", da sich Compose-Projektnamen ändern können.
CRON_FILE="/etc/cron.d/libki"
cat > "${CRON_FILE}" <<EOF
# Libki Cronjobs - verwaltet Sessions und nächtliche Bereinigung
* * * * * root cd ${INSTALL_DIR}/docker && docker compose exec -T libki /app/script/cronjobs/libki.pl
0 0 * * * root cd ${INSTALL_DIR}/docker && docker compose exec -T libki /app/script/cronjobs/libki_nightly.pl
EOF

chmod 644 "${CRON_FILE}"

# ----------------------------------------------------------------------------
# Abschluss
# ----------------------------------------------------------------------------

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo
echo "=== Installation abgeschlossen ==="
echo "Libki Server sollte nun erreichbar sein unter:"
echo "  http://${SERVER_IP}:3000"
echo
echo "Administrationsoberfläche:"
echo "  http://${SERVER_IP}:3000/administration"
echo
echo "Admin-Login: ${ADMIN_USER} / ${ADMIN_PASSWORD}"
echo
echo "Wichtige Dateien:"
echo "  - Konfiguration: ${INSTALL_DIR}/docker/.env"
echo "  - Cronjobs:       ${CRON_FILE}"
echo
echo "Nützliche Befehle (im Verzeichnis ${INSTALL_DIR}/docker ausführen):"
echo "  docker compose ps            # Status der Container anzeigen"
echo "  docker compose logs -f       # Logs live verfolgen"
echo "  docker compose down          # Container stoppen"
echo "  docker compose up -d         # Container wieder starten"
echo
echo "Für SSL/TLS wird ein Reverse-Proxy (z. B. nginx oder Apache) benötigt,"
echo "der den Header 'X-Request-Base' mit der HTTPS-URL des Servers setzt."
