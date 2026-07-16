#!/usr/bin/env bash
#
# install_libki_client.sh
#
# Baut und installiert den Libki Client (qt6-Branch) auf Ubuntu 24.04.
#
# Verwendung:
#   chmod +x install_libki_client.sh
#   ./install_libki_client.sh
#
# Das Skript:
#   1. Prüft, ob es auf Ubuntu 24.x läuft (Warnung bei anderen Versionen)
#   2. Installiert die benötigten Build-Abhängigkeiten (Qt6, build-essential, git)
#   3. Klont den qt6-Branch von github.com/Libki/libki-client
#   4. Baut den Client mit qmake6 + make
#   5. Installiert das Binary nach /usr/local/bin/libkiclient
#   6. Legt optional eine Autostart-Verknüpfung für den aktuellen Benutzer an
#
# Erfordert sudo-Rechte für Paketinstallation und die Installation nach /usr/local/bin.

set -euo pipefail

# ----------------------------- Konfiguration --------------------------------
REPO_URL="https://github.com/Libki/libki-client.git"
BRANCH="qt6"
BUILD_DIR="${HOME}/libki-client-build"
INSTALL_PATH="/usr/local/bin/libkiclient"
LOGFILE="/tmp/libki-client-install.log"

# ----------------------------- Hilfsfunktionen -------------------------------
log()  { echo -e "\e[1;34m[*]\e[0m $*" | tee -a "$LOGFILE"; }
ok()   { echo -e "\e[1;32m[OK]\e[0m $*" | tee -a "$LOGFILE"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*" | tee -a "$LOGFILE"; }
err()  { echo -e "\e[1;31m[FEHLER]\e[0m $*" | tee -a "$LOGFILE" >&2; }

trap 'err "Skript abgebrochen in Zeile $LINENO. Siehe $LOGFILE für Details."' ERR

: > "$LOGFILE"

# ----------------------------- 1. OS-Check -----------------------------------
log "Prüfe Betriebssystem..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "Dies scheint kein Ubuntu zu sein (erkannt: ${PRETTY_NAME:-unbekannt}). Fahre trotzdem fort."
    elif [[ "${VERSION_ID:-}" != 24.* ]]; then
        warn "Erkannte Ubuntu-Version: ${VERSION_ID:-unbekannt}. Dieses Skript ist für 24.04 gedacht, andere Versionen können abweichende Paketnamen benötigen."
    else
        ok "Ubuntu ${VERSION_ID} erkannt."
    fi
else
    warn "/etc/os-release nicht gefunden, Betriebssystem konnte nicht geprüft werden."
fi

# ----------------------------- 2. Abhängigkeiten -----------------------------
log "Aktualisiere Paketlisten und installiere Build-Abhängigkeiten (benötigt sudo)..."
sudo apt-get update -y | tee -a "$LOGFILE"

PACKAGES=(
    git
    build-essential
    qt6-base-dev
    qt6-base-dev-tools
    qt6-tools-dev
    qt6-tools-dev-tools
    qt6-l10n-tools
    libqt6webenginewidgets6
    libqt6webenginecore6-bin
    qt6-webengine-dev
    qt6-webengine-dev-tools
    libgl1-mesa-dev
)
# qt6-l10n-tools liefert lrelease, das wir benötigen, um die deutsche
# Übersetzung (.ts -> .qm) zu kompilieren, bevor der Client gebaut wird.

MISSING=()
for pkg in "${PACKAGES[@]}"; do
    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        MISSING+=("$pkg")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Folgende Pakete sind im APT-Index nicht auffindbar und werden übersprungen: ${MISSING[*]}"
    warn "Falls der Build danach fehlschlägt, prüfe die exakten Paketnamen mit: apt search qt6-webengine"
fi

TO_INSTALL=()
for pkg in "${PACKAGES[@]}"; do
    if ! printf '%s\n' "${MISSING[@]:-}" | grep -qx "$pkg"; then
        TO_INSTALL+=("$pkg")
    fi
done

sudo apt-get install -y "${TO_INSTALL[@]}" | tee -a "$LOGFILE"
ok "Abhängigkeiten installiert."

# Finde ein nutzbares qmake-Binary (heißt je nach Distro qmake6 oder qmake)
QMAKE_BIN=""
for candidate in qmake6 /usr/lib/qt6/bin/qmake6 qmake; do
    if command -v "$candidate" >/dev/null 2>&1; then
        QMAKE_BIN="$candidate"
        break
    fi
done

if [ -z "$QMAKE_BIN" ]; then
    err "Kein qmake-Binary gefunden. Ist qt6-base-dev-tools korrekt installiert?"
    exit 1
fi
ok "Verwende qmake: $QMAKE_BIN ($($QMAKE_BIN -v | tr '\n' ' '))"

# lrelease wird benötigt, um die deutsche .ts-Datei in eine .qm-Datei zu kompilieren
LRELEASE_BIN=""
for candidate in lrelease6 /usr/lib/qt6/bin/lrelease lrelease; do
    if command -v "$candidate" >/dev/null 2>&1; then
        LRELEASE_BIN="$candidate"
        break
    fi
done

if [ -z "$LRELEASE_BIN" ]; then
    err "Kein lrelease-Binary gefunden. Ist qt6-l10n-tools korrekt installiert?"
    exit 1
fi
ok "Verwende lrelease: $LRELEASE_BIN"

# ----------------------------- 3. Quellcode holen ----------------------------
log "Klone Libki Client (Branch: $BRANCH) nach $BUILD_DIR ..."
if [ -d "$BUILD_DIR" ]; then
    warn "$BUILD_DIR existiert bereits. Aktualisiere bestehendes Repository."
    git -C "$BUILD_DIR" fetch origin "$BRANCH" | tee -a "$LOGFILE"
    git -C "$BUILD_DIR" checkout "$BRANCH" | tee -a "$LOGFILE"
    git -C "$BUILD_DIR" reset --hard "origin/$BRANCH" | tee -a "$LOGFILE"
else
    git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$BUILD_DIR" | tee -a "$LOGFILE"
fi
ok "Quellcode bereit unter $BUILD_DIR"

# ----------------------------- 3b. Deutsche Übersetzung ----------------------
# Es gibt bislang keine offizielle deutsche Sprachdatei im Repository.
# Wir legen hier eine vollständige Übersetzung an (alle UI-Strings aus
# loginwindow, sessionlockedwindow und timerwindow), verankern sie im
# Build (Libki.pro) und in den Qt-Ressourcen (libki.qrc), und kompilieren
# sie zu einer .qm-Datei.
#
# Hinweis zum Dateinamen: Der Client lädt die Übersetzung anhand des
# Systemgebietsschemas (QLocale::system().name()), z.B. "de_DE" auf den
# meisten deutschen Ubuntu-Installationen. Falls dein System ein anderes
# Gebietsschema meldet (z.B. "de_AT" oder "de_CH"), musst du die Datei
# zusätzlich unter diesem Namen ablegen bzw. umbenennen, damit sie
# automatisch geladen wird. Prüfen kannst du das mit: locale

log "Lege deutsche Übersetzung an..."

LANG_DIR="${BUILD_DIR}/languages"
TS_FILE="${LANG_DIR}/libkiclient_de_DE.ts"
mkdir -p "$LANG_DIR"

cat > "$TS_FILE" <<'LIBKI_DE_TS_EOF'
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE TS>
<TS version="2.1" language="de_DE">
<context>
    <name>LoginWindow</name>
    <message>
        <location filename="../loginwindow.ui" line="14"/>
        <source>Libki Kiosk System</source>
        <translation>Libki Kiosk-System</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="29"/>
        <source>Internet Kiosk</source>
        <translation>Internet-Terminal</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="115"/>
        <location filename="../loginwindow.cpp" line="434"/>
        <source>Reserved</source>
        <translation>Reserviert</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="144"/>
        <source>Please Log In.</source>
        <translation>Bitte anmelden.</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="218"/>
        <source>Username:</source>
        <translation>Benutzername:</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="234"/>
        <source>Password:</source>
        <translation>Passwort:</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="254"/>
        <source>Cancel</source>
        <translation>Abbrechen</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="270"/>
        <source>Log In</source>
        <translation>Anmelden</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="347"/>
        <source>Bottom Banner</source>
        <translation>Banner unten</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="384"/>
        <source>Top Banner</source>
        <translation>Banner oben</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="450"/>
        <source>2.2.26</source>
        <translation>2.2.26</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="497"/>
        <source>&lt;html&gt;&lt;head/&gt;&lt;body&gt;&lt;p&gt;&lt;span style=&quot; color:#ff0000;&quot;&gt;Unable to connect to server&lt;/span&gt;&lt;/p&gt;&lt;/body&gt;&lt;/html&gt;</source>
        <translation>&lt;html&gt;&lt;head/&gt;&lt;body&gt;&lt;p&gt;&lt;span style=&quot; color:#ff0000;&quot;&gt;Verbindung zum Server nicht möglich&lt;/span&gt;&lt;/p&gt;&lt;/body&gt;&lt;/html&gt;</translation>
    </message>
    <message>
        <location filename="../loginwindow.ui" line="520"/>
        <source>&lt;html&gt;&lt;head/&gt;&lt;body&gt;&lt;p&gt;&lt;span style=&quot; color:#ff0000;&quot;&gt;Unable to connect to Internet&lt;/span&gt;&lt;/p&gt;&lt;/body&gt;&lt;/html&gt;</source>
        <translation>&lt;html&gt;&lt;head/&gt;&lt;body&gt;&lt;p&gt;&lt;span style=&quot; color:#ff0000;&quot;&gt;Verbindung zum Internet nicht möglich&lt;/span&gt;&lt;/p&gt;&lt;/body&gt;&lt;/html&gt;</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="146"/>
        <source>Please Wait...</source>
        <translation>Bitte warten...</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="185"/>
        <source>Do you accept the terms of service?</source>
        <translation>Akzeptieren Sie die Nutzungsbedingungen?</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="190"/>
        <source>Terms of Service</source>
        <translation>Nutzungsbedingungen</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="204"/>
        <source>Yes</source>
        <translation>Ja</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="205"/>
        <source>No</source>
        <translation>Nein</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="226"/>
        <source>Login Failed: Username and password do not match</source>
        <translation>Anmeldung fehlgeschlagen: Benutzername und Passwort stimmen nicht überein</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="229"/>
        <source>Login Failed: You are not the correct age to use this client</source>
        <translation>Anmeldung fehlgeschlagen: Sie erfüllen nicht die Altersvoraussetzung für dieses Gerät</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="231"/>
        <source>Login Failed: No time left</source>
        <translation>Anmeldung fehlgeschlagen: Keine Zeit mehr verfügbar</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="233"/>
        <source>Login Failed: This kiosk is closed for the day</source>
        <translation>Anmeldung fehlgeschlagen: Dieses Gerät ist für heute geschlossen</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="235"/>
        <source>Login Failed: Account is currently in use</source>
        <translation>Anmeldung fehlgeschlagen: Konto wird bereits verwendet</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="237"/>
        <source>Login Failed: Account is disabled</source>
        <translation>Anmeldung fehlgeschlagen: Konto ist deaktiviert</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="240"/>
        <source>Login Failed: This kiosk is reserved for someone else</source>
        <translation>Anmeldung fehlgeschlagen: Dieses Gerät ist für eine andere Person reserviert</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="242"/>
        <source>Login Failed: Reservation required</source>
        <translation>Anmeldung fehlgeschlagen: Reservierung erforderlich</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="245"/>
        <location filename="../loginwindow.cpp" line="274"/>
        <source>Login Failed: You have excessive outstanding fees</source>
        <translation>Anmeldung fehlgeschlagen: Sie haben zu hohe ausstehende Gebühren</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="247"/>
        <source>Login Failed: Charge privileges denied</source>
        <translation>Anmeldung fehlgeschlagen: Ausleiherechte verweigert</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="249"/>
        <source>Login Failed: Renewal privileges denied</source>
        <translation>Anmeldung fehlgeschlagen: Verlängerungsrechte verweigert</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="251"/>
        <source>Login Failed: Recall privileges denied</source>
        <translation>Anmeldung fehlgeschlagen: Rückforderungsrechte verweigert</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="253"/>
        <source>Login Failed: Hold privileges denied</source>
        <translation>Anmeldung fehlgeschlagen: Vormerkrechte verweigert</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="255"/>
        <source>Login Failed: Your card has been reported lost</source>
        <translation>Anmeldung fehlgeschlagen: Ihr Ausweis wurde als verloren gemeldet</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="258"/>
        <source>Login Failed: You have too many items charged to your account</source>
        <translation>Anmeldung fehlgeschlagen: Sie haben zu viele Medien auf Ihrem Konto ausgeliehen</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="260"/>
        <source>Login Failed: You have too many items overdue</source>
        <translation>Anmeldung fehlgeschlagen: Sie haben zu viele überfällige Medien</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="263"/>
        <source>Login Failed: You have renewed items too many times</source>
        <translation>Anmeldung fehlgeschlagen: Sie haben Medien zu oft verlängert</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="266"/>
        <source>Login Failed: You have claimed too many items as returned</source>
        <translation>Anmeldung fehlgeschlagen: Sie haben zu viele Medien fälschlich als zurückgegeben gemeldet</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="268"/>
        <source>Login Failed: You have have lost too many items</source>
        <translation>Anmeldung fehlgeschlagen: Sie haben zu viele Medien verloren</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="271"/>
        <source>Login Failed: You have excessive outstanding fines</source>
        <translation>Anmeldung fehlgeschlagen: Sie haben zu hohe ausstehende Mahngebühren</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="277"/>
        <source>Login Failed: You have a recalled item which is overdue</source>
        <translation>Anmeldung fehlgeschlagen: Sie haben ein zurückgefordertes Medium, das überfällig ist</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="280"/>
        <source>Login Failed: You have been billed for too many items</source>
        <translation>Anmeldung fehlgeschlagen: Ihnen wurden zu viele Medien in Rechnung gestellt</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="282"/>
        <source>Login Failed: Client not registered</source>
        <translation>Anmeldung fehlgeschlagen: Gerät ist nicht registriert</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="284"/>
        <source>Login Failed: Unable to connect to ILS</source>
        <translation>Anmeldung fehlgeschlagen: Verbindung zum Bibliothekssystem (ILS) nicht möglich</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="287"/>
        <source>Login Failed: Too many concurrent sessions on this account</source>
        <translation>Anmeldung fehlgeschlagen: Zu viele gleichzeitige Sitzungen für dieses Konto</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="290"/>
        <source>Login Failed: Expired Membership. Please inquire at the circulation desk.</source>
        <translation>Anmeldung fehlgeschlagen: Mitgliedschaft abgelaufen. Bitte wenden Sie sich an die Ausleihtheke.</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="293"/>
        <source>Login Failed: </source>
        <translation>Anmeldung fehlgeschlagen: </translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="432"/>
        <source>Reserved: </source>
        <translation>Reserviert: </translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="542"/>
        <source>This kiosk is out of order.</source>
        <translation>Dieses Gerät ist außer Betrieb.</translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="560"/>
        <source>Error connecting to server. Verify Libki server is accessible from this network. Error Code: </source>
        <translation>Fehler beim Verbinden mit dem Server. Bitte prüfen Sie, ob der Libki-Server über dieses Netzwerk erreichbar ist. Fehlercode: </translation>
    </message>
    <message>
        <location filename="../loginwindow.cpp" line="573"/>
        <source>Error connecting to Internet: </source>
        <translation>Fehler beim Verbinden mit dem Internet: </translation>
    </message>
</context>
<context>
    <name>SessionLockedWindow</name>
    <message>
        <location filename="../sessionlockedwindow.ui" line="14"/>
        <source>Libki Kiosk System</source>
        <translation>Libki Kiosk-System</translation>
    </message>
    <message>
        <location filename="../sessionlockedwindow.ui" line="55"/>
        <source>Internet Kiosk</source>
        <translation>Internet-Terminal</translation>
    </message>
    <message>
        <location filename="../sessionlockedwindow.ui" line="141"/>
        <source>Session Locked</source>
        <translation>Sitzung gesperrt</translation>
    </message>
    <message>
        <location filename="../sessionlockedwindow.ui" line="170"/>
        <source>Enter Password To Resume Session</source>
        <translation>Passwort eingeben, um die Sitzung fortzusetzen</translation>
    </message>
    <message>
        <location filename="../sessionlockedwindow.ui" line="244"/>
        <source>Password:</source>
        <translation>Passwort:</translation>
    </message>
    <message>
        <location filename="../sessionlockedwindow.ui" line="269"/>
        <source>Resume</source>
        <translation>Fortsetzen</translation>
    </message>
    <message>
        <location filename="../sessionlockedwindow.cpp" line="118"/>
        <source>Incorrect Password</source>
        <translation>Falsches Passwort</translation>
    </message>
</context>
<context>
    <name>TimerWindow</name>
    <message>
        <location filename="../timerwindow.ui" line="14"/>
        <source>Libki Kiosk System</source>
        <translation>Libki Kiosk-System</translation>
    </message>
    <message>
        <location filename="../timerwindow.ui" line="107"/>
        <location filename="../timerwindow.cpp" line="288"/>
        <source>Log Out</source>
        <translation>Abmelden</translation>
    </message>
    <message>
        <location filename="../timerwindow.ui" line="146"/>
        <source>Lock Session</source>
        <translation>Sitzung sperren</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="114"/>
        <source>You have one or more items on hold waiting for pickup. Please contact a librarian for more details</source>
        <translation>Sie haben ein oder mehrere vorgemerkte Medien zur Abholung bereit. Bitte wenden Sie sich für weitere Informationen an das Bibliothekspersonal</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="172"/>
        <location filename="../timerwindow.cpp" line="366"/>
        <source>Minutes Left</source>
        <translation>Minuten übrig</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="251"/>
        <source>Log Out?</source>
        <translation>Abmelden?</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="252"/>
        <source>Are you sure you want to log out?</source>
        <translation>Möchten Sie sich wirklich abmelden?</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="255"/>
        <source>Yes</source>
        <translation>Ja</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="256"/>
        <source>Cancel</source>
        <translation>Abbrechen</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="364"/>
        <source>Time Remaining</source>
        <translation>Verbleibende Zeit</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="420"/>
        <source>Inactivity detected</source>
        <translation>Inaktivität erkannt</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="421"/>
        <source>Please confirm you are still using this computer.</source>
        <translation>Bitte bestätigen Sie, dass Sie diesen Computer noch verwenden.</translation>
    </message>
    <message>
        <location filename="../timerwindow.cpp" line="456"/>
        <source>You have a message</source>
        <translation>Sie haben eine Nachricht</translation>
    </message>
</context>
</TS>
LIBKI_DE_TS_EOF

ok "Deutsche .ts-Datei angelegt: $TS_FILE"

# .ts zu .qm kompilieren
"$LRELEASE_BIN" "$TS_FILE" | tee -a "$LOGFILE"
if [ ! -f "${LANG_DIR}/libkiclient_de_DE.qm" ]; then
    err "lrelease hat keine .qm-Datei erzeugt."
    exit 1
fi
ok "Deutsche .qm-Datei kompiliert: ${LANG_DIR}/libkiclient_de_DE.qm"

# In Libki.pro eintragen, damit die Übersetzung Teil des Projekts ist
PRO_FILE_FOR_TS=$(find "$BUILD_DIR" -maxdepth 1 -name "*.pro" | head -n1)
if [ -n "$PRO_FILE_FOR_TS" ]; then
    if ! grep -q "libkiclient_de_DE.ts" "$PRO_FILE_FOR_TS"; then
        echo "TRANSLATIONS += languages/libkiclient_de_DE.ts" >> "$PRO_FILE_FOR_TS"
        ok "Eintrag in $(basename "$PRO_FILE_FOR_TS") ergänzt (TRANSLATIONS)."
    else
        log "Eintrag in $(basename "$PRO_FILE_FOR_TS") bereits vorhanden."
    fi
else
    warn "Keine .pro-Datei gefunden, TRANSLATIONS-Eintrag konnte nicht ergänzt werden."
fi

# In libki.qrc eintragen, damit die .qm-Datei in die Anwendung eingebettet wird
QRC_FILE="${BUILD_DIR}/libki.qrc"
if [ -f "$QRC_FILE" ]; then
    if ! grep -q "libkiclient_de_DE.qm" "$QRC_FILE"; then
        if grep -q '<qresource prefix="/">' "$QRC_FILE"; then
            sed -i '/<qresource prefix="\/">/a\        <file>languages/libkiclient_de_DE.qm</file>' "$QRC_FILE"
            ok "Eintrag in libki.qrc ergänzt (Ressource eingebettet)."
        else
            warn "Erwarteter <qresource prefix=\"/\">-Block nicht in libki.qrc gefunden. Bitte manuell prüfen: $QRC_FILE"
        fi
    else
        log "Eintrag in libki.qrc bereits vorhanden."
    fi
else
    warn "libki.qrc nicht gefunden unter $QRC_FILE. Übersetzung wird eventuell nicht eingebettet."
fi

# ----------------------------- 4. Bauen --------------------------------------
log "Baue den Libki Client..."
cd "$BUILD_DIR"

PRO_FILE=$(find . -maxdepth 1 -name "*.pro" | head -n1)
if [ -z "$PRO_FILE" ]; then
    err "Keine .pro-Datei im Repository gefunden. Struktur des qt6-Branches hat sich möglicherweise geändert."
    exit 1
fi
log "Verwende Projektdatei: $PRO_FILE"

"$QMAKE_BIN" "$PRO_FILE" | tee -a "$LOGFILE"
make -j"$(nproc)" | tee -a "$LOGFILE"
ok "Build abgeschlossen."

# Binary suchen (kann je nach .pro-Konfiguration im Build- oder im aktuellen Ordner liegen)
BIN_PATH=$(find . -maxdepth 3 -type f -iname "libkiclient" -executable | head -n1)
if [ -z "$BIN_PATH" ]; then
    err "Kompiliertes Binary 'libkiclient' wurde nicht gefunden. Prüfe die Build-Ausgabe in $LOGFILE."
    exit 1
fi
ok "Binary gefunden: $BIN_PATH"

# ----------------------------- 5. Installieren -------------------------------
log "Installiere Binary nach $INSTALL_PATH (benötigt sudo)..."
sudo install -m 755 "$BIN_PATH" "$INSTALL_PATH"
ok "Libki Client installiert unter $INSTALL_PATH"

# ----------------------------- 6. Autostart (optional) -----------------------
read -rp "Soll der Libki Client beim Login dieses Benutzers automatisch starten? [j/N] " ANTWORT
if [[ "${ANTWORT,,}" == "j" || "${ANTWORT,,}" == "y" ]]; then
    AUTOSTART_DIR="${HOME}/.config/autostart"
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/libki.desktop" <<EOF
[Desktop Entry]
Encoding=UTF-8
Version=1.0
Type=Application
Terminal=false
Name=Libki Client
Exec=${INSTALL_PATH}
EOF
    ok "Autostart-Eintrag angelegt unter ${AUTOSTART_DIR}/libki.desktop"
else
    log "Kein Autostart-Eintrag angelegt. Du kannst den Client jederzeit manuell mit '${INSTALL_PATH}' starten."
fi

# ----------------------------- 7. Konfigurationsdatei ------------------------
# Der Client liest seine Einstellungen über QSettings mit
# Organisation "Libki" und Anwendungsname "Libki Kiosk Management System".
# Unter Linux landet das entsprechend unter:
#   ~/.config/Libki/Libki Kiosk Management System.ini
#
# Statt hier ein eigenes (potenziell fehlerhaftes) Beispiel zu erzeugen,
# kopieren wir die im Repository mitgelieferte example.ini an genau
# diesen Ort und benennen sie passend um.

CONFIG_DIR="${HOME}/.config/Libki"
CONFIG_FILE="${CONFIG_DIR}/Libki Kiosk Management System.ini"
EXAMPLE_INI="${BUILD_DIR}/example.ini"

if [ -f "$EXAMPLE_INI" ]; then
    mkdir -p "$CONFIG_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        warn "Es existiert bereits eine Konfiguration unter '$CONFIG_FILE'. Sie wird NICHT überschrieben."
        warn "Die mitgelieferte Beispieldatei liegt zum Vergleich hier: $EXAMPLE_INI"
    else
        cp "$EXAMPLE_INI" "$CONFIG_FILE"
        ok "example.ini kopiert nach '$CONFIG_FILE'"
    fi
else
    warn "example.ini wurde im Repository nicht gefunden unter $EXAMPLE_INI. Bitte Konfiguration manuell anlegen."
fi

# ----------------------------- 8. Abschlusshinweis ---------------------------
cat <<EOF

--------------------------------------------------------------------
Installation abgeschlossen!

Passe vor dem ersten Start deine Server-Zugangsdaten in dieser Datei an:
  ${CONFIG_FILE}

Wichtige Felder im Abschnitt [server]:
  host   = IP-Adresse oder Hostname deines Libki-Servers
  port   = Port deines Libki-Servers (Standard: 3000)
  scheme = "http" oder "https"

Starten kannst du den Client danach mit:
  ${INSTALL_PATH}

Die deutsche Übersetzung wird automatisch verwendet, wenn dein System
auf das Gebietsschema de_DE eingestellt ist (prüfbar mit: locale).

Log dieser Installation: $LOGFILE
--------------------------------------------------------------------
EOF
