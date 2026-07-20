#!/usr/bin/env bash
#
# setup_libki_kiosk_lockdown.sh
#
# Härtet einen Ubuntu-24.04-Rechner ab, damit der Libki Client nicht mehr
# durch Minimieren, Taskleiste, Super-Taste, Alt+Tab, virtuelle Konsolen
# (Strg+Alt+F1-F7) etc. umgangen werden kann.
#
# HINTERGRUND (warum das nötig ist):
# Libki selbst versucht bereits, sich per showFullScreen() und
# Qt::WindowStaysOnTopHint oben zu halten (siehe loginwindow.cpp,
# timerwindow.cpp, sessionlockedwindow.cpp). Das sind aber nur Hinweise an
# den Window-Manager - keine echte Sperre. Im Quellcode selbst steht dazu
# ein Kommentar der Libki-Entwickler: "there appears to be no way to
# [always bring the window to the front]". Auf einer normalen GNOME/KDE/
# XFCE-Sitzung mit Taskleiste, Super-Taste-Übersicht, Alt+Tab usw. lässt
# sich das Fenster deshalb jederzeit wegklicken oder minimieren.
#
# LÖSUNG: Dieses Skript richtet für den Kiosk-Benutzer eine ZUSÄTZLICHE,
# separate Sitzung ein (Openbox, ganz ohne Taskleiste/Panel/Tastenkürzel),
# die ausschliesslich den Libki Client zeigt. Deine normale GNOME-Sitzung
# für Admin-Zwecke bleibt davon unberührt und wählbar.
#
# Das Skript:
#   1. Installiert Openbox + Hilfswerkzeuge (xdotool, wmctrl, unclutter)
#   2. Legt eine minimale Openbox-Konfiguration OHNE Tastenkürzel an
#      (Super-Taste, Alt+Tab, Alt+F2 etc. sind dadurch automatisch
#      wirkungslos, weil nichts mehr daran gebunden ist)
#   3. Legt einen Autostart-/Watchdog-Skript an, der:
#        - libkiclient startet
#        - alle 1-2 Sekunden prüft, ob das Libki-Fenster im Vordergrund,
#          fokussiert und im Vollbild ist - falls nicht, wird es
#          zurückgeholt
#        - libkiclient automatisch neu startet, falls der Prozess beendet
#          wird (z.B. über einen (theoretisch nicht mehr vorhandenen)
#          Fensterrahmen-Schliessen-Knopf)
#   4. Deaktiviert das Wechseln der virtuellen Konsolen (Strg+Alt+F1-F7)
#      auf Xorg-Ebene - betrifft die ganze Maschine, nicht nur die
#      Kiosk-Sitzung (siehe Hinweis am Ende)
#   5. Legt eine eigene Sitzung "Libki Kiosk" an, die am Login-Bildschirm
#      auswählbar ist
#   6. Versucht, Autologin + automatische Sitzungsauswahl für den
#      Kiosk-Benutzer einzurichten (GDM3 und LightDM werden erkannt)
#
# Verwendung:
#   sudo ./setup_libki_kiosk_lockdown.sh <kiosk-benutzername>
#
# Der angegebene Benutzer muss bereits existieren (z.B. der Account, unter
# dem aktuell Libki läuft).

set -euo pipefail

LOGFILE="/tmp/libki-kiosk-lockdown.log"
log()  { echo -e "\e[1;34m[*]\e[0m $*" | tee -a "$LOGFILE"; }
ok()   { echo -e "\e[1;32m[OK]\e[0m $*" | tee -a "$LOGFILE"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*" | tee -a "$LOGFILE"; }
err()  { echo -e "\e[1;31m[FEHLER]\e[0m $*" | tee -a "$LOGFILE" >&2; }

: > "$LOGFILE"

if [ "$(id -u)" -ne 0 ]; then
    err "Bitte mit sudo/als root ausführen: sudo $0 <kiosk-benutzername>"
    exit 1
fi

if [ $# -lt 1 ]; then
    err "Benutzung: sudo $0 <kiosk-benutzername>"
    err "Beispiel:  sudo $0 libki"
    exit 1
fi

KIOSK_USER="$1"

if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    err "Der Benutzer '$KIOSK_USER' existiert nicht. Bitte zuerst anlegen, z.B.:"
    err "  sudo adduser --disabled-password --gecos \"\" $KIOSK_USER"
    exit 1
fi

KIOSK_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)
if [ -z "$KIOSK_HOME" ] || [ ! -d "$KIOSK_HOME" ]; then
    err "Home-Verzeichnis von '$KIOSK_USER' konnte nicht ermittelt werden."
    exit 1
fi

LIBKI_BIN="/usr/local/bin/libkiclient"
if [ ! -x "$LIBKI_BIN" ]; then
    warn "libkiclient wurde nicht unter $LIBKI_BIN gefunden. Passe LIBKI_BIN im Skript an, falls es woanders liegt."
fi

ok "Kiosk-Benutzer: $KIOSK_USER (Home: $KIOSK_HOME)"

# ----------------------------- 1. Pakete -------------------------------------
log "Installiere Openbox und Hilfswerkzeuge..."
apt-get update -y 2>&1 | tee -a "$LOGFILE" || warn "apt-get update meldete Fehler bei mindestens einem Repository. Fahre fort."
apt-get install -y openbox xdotool wmctrl unclutter x11-xserver-utils | tee -a "$LOGFILE"
ok "Pakete installiert."

# ----------------------------- 2. Openbox-Konfiguration -----------------------
log "Lege gehärtete Openbox-Konfiguration an..."

OB_CONFIG_DIR="${KIOSK_HOME}/.config/openbox"
mkdir -p "$OB_CONFIG_DIR"

# Minimale rc.xml OHNE Tastenkürzel-Bindings (leerer <keyboard>-Block) und
# ohne Rechtsklick-Desktopmenü (leerer <mouse>-Root-Kontext). Dadurch
# wirken Super-Taste, Alt+Tab, Alt+F2, Strg+Esc usw. schlicht nicht mehr,
# weil ihnen keine Aktion mehr zugewiesen ist.
cat > "${OB_CONFIG_DIR}/rc.xml" <<'OBRC_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance>
    <strength>0</strength>
    <screen_edge_strength>0</screen_edge_strength>
  </resistance>
  <focus>
    <focusNew>yes</focusNew>
    <followMouse>no</followMouse>
    <focusLast>yes</focusLast>
  </focus>
  <placement>
    <policy>Smart</policy>
  </placement>
  <theme>
    <name>Clearlooks</name>
    <titleLayout></titleLayout>
    <keepBorder>no</keepBorder>
    <animateIconify>no</animateIconify>
  </theme>
  <desktops>
    <number>1</number>
    <firstdesk>1</firstdesk>
  </desktops>
  <resize>
    <drawContents>no</drawContents>
  </resize>
  <margins>
    <top>0</top>
    <bottom>0</bottom>
    <left>0</left>
    <right>0</right>
  </margins>
  <dock>
    <hide>yes</hide>
  </dock>
  <!-- ABSICHTLICH LEER: keine Tastenkombination ist gebunden.
       Super-Taste, Alt+Tab, Alt+F2, Strg+Esc, Strg+Alt+T usw. tun
       dadurch nichts mehr. -->
  <keyboard>
  </keyboard>
  <!-- ABSICHTLICH MINIMAL: kein Rechtsklick-Desktopmenü, kein
       Fenster-Kontextmenü, kein Klick-Verhalten auf dem Root-Fenster. -->
  <mouse>
    <dragThreshold>8</dragThreshold>
    <doubleClickTime>200</doubleClickTime>
    <screenEdgeWarpTime>400</screenEdgeWarpTime>
  </mouse>
  <menu>
  </menu>
  <applications>
    <application class="*">
      <decor>no</decor>
      <maximized>true</maximized>
      <fullscreen>yes</fullscreen>
      <focus>yes</focus>
      <layer>above</layer>
      <skip_taskbar>yes</skip_taskbar>
      <skip_pager>yes</skip_pager>
    </application>
  </applications>
</openbox_config>
OBRC_EOF
ok "rc.xml angelegt: ${OB_CONFIG_DIR}/rc.xml"

# Leeres Menü, falls Openbox trotzdem irgendwo danach sucht
cat > "${OB_CONFIG_DIR}/menu.xml" <<'OBMENU_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
</openbox_menu>
OBMENU_EOF

# ----------------------------- 3. Autostart / Watchdog ------------------------
log "Lege Autostart- und Watchdog-Skript an..."

cat > "${OB_CONFIG_DIR}/autostart" <<AUTOSTART_EOF
#!/usr/bin/env bash
# Wird von Openbox beim Sitzungsstart ausgeführt.

# Bildschirmschoner/Energiesparen/Sperrbildschirm deaktivieren, damit der
# Rechner nicht selbst eine Sperre zeigt, die man umgehen könnte, und
# damit der Bildschirm nicht abschaltet, während niemand angemeldet ist.
xset s off
xset s noblank
xset -dpms

# Mauszeiger bei Inaktivität ausblenden (kosmetisch, für Kiosk üblich)
unclutter --timeout 3 &

# Watchdog + Respawn-Schleife im Hintergrund starten
"${OB_CONFIG_DIR}/kiosk-watchdog.sh" &

exit 0
AUTOSTART_EOF
chmod +x "${OB_CONFIG_DIR}/autostart"

cat > "${OB_CONFIG_DIR}/kiosk-watchdog.sh" <<WATCHDOG_EOF
#!/usr/bin/env bash
#
# Sorgt dafür, dass libkiclient läuft, im Vollbild ist, den Fokus hat und
# ganz oben liegt. Startet den Client automatisch neu, falls er beendet
# wird. Alle Libki-Fenster (Login, Timer, Sitzung gesperrt) tragen laut
# Quellcode denselben Fenstertitel "Libki Kiosk System", danach wird
# gesucht.

LIBKI_BIN="${LIBKI_BIN}"
WINDOW_TITLE="Libki Kiosk System"

while true; do
    if ! pgrep -x "libkiclient" >/dev/null 2>&1; then
        "\$LIBKI_BIN" >>/tmp/libkiclient.log 2>&1 &
        sleep 3
    fi

    WIN_ID=\$(xdotool search --name "\$WINDOW_TITLE" 2>/dev/null | head -n1)
    if [ -n "\$WIN_ID" ]; then
        xdotool windowactivate --sync "\$WIN_ID" >/dev/null 2>&1
        xdotool windowraise "\$WIN_ID" >/dev/null 2>&1
        wmctrl -i -r "\$WIN_ID" -b add,fullscreen,above >/dev/null 2>&1
    fi

    sleep 1
done
WATCHDOG_EOF
chmod +x "${OB_CONFIG_DIR}/kiosk-watchdog.sh"

chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config"
ok "Autostart- und Watchdog-Skript angelegt."

# ----------------------------- 4. VT-Switching deaktivieren -------------------
log "Deaktiviere das Wechseln virtueller Konsolen (Strg+Alt+F1-F7)..."
warn "Dies betrifft die GESAMTE Maschine, nicht nur die Kiosk-Sitzung."
warn "Zur Wartung per Konsole entweder diese Datei vorübergehend entfernen,"
warn "oder per SSH/Remote-Zugriff arbeiten."

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-disable-vt-switch.conf <<'VTCONF_EOF'
Section "ServerFlags"
    Option "DontVTSwitch" "true"
EndSection
VTCONF_EOF
ok "VT-Switching deaktiviert (wirksam nach dem nächsten X-Neustart/Reboot)."

# ----------------------------- 5. Eigene Sitzung anlegen -----------------------
log "Lege Sitzungseintrag 'Libki Kiosk' für den Login-Bildschirm an..."

cat > /usr/share/xsessions/libki-kiosk.desktop <<'XSESSION_EOF'
[Desktop Entry]
Name=Libki Kiosk
Comment=Gehärtete Kiosk-Sitzung, zeigt ausschliesslich den Libki Client
Exec=openbox-session
Type=Application
DesktopNames=Libki-Kiosk
XSESSION_EOF
ok "Sitzung angelegt: /usr/share/xsessions/libki-kiosk.desktop"

# ----------------------------- 6. Autologin einrichten -------------------------
log "Versuche Autologin für '$KIOSK_USER' in die 'Libki Kiosk'-Sitzung einzurichten..."

# accountsservice: legt fest, welche Sitzung für den Benutzer standardmässig
# vorausgewählt ist (funktioniert für GDM3 und die meisten Anzeigemanager,
# die accountsservice nutzen)
mkdir -p /var/lib/AccountsService/users
cat > "/var/lib/AccountsService/users/${KIOSK_USER}" <<ACCOUNTS_EOF
[User]
Session=libki-kiosk
XSession=libki-kiosk
SystemAccount=false
ACCOUNTS_EOF
ok "Standard-Sitzung für '$KIOSK_USER' auf 'Libki Kiosk' gesetzt."

if [ -f /etc/gdm3/custom.conf ]; then
    log "GDM3 erkannt. Richte Autologin ein..."
    if ! grep -q "^AutomaticLoginEnable" /etc/gdm3/custom.conf; then
        sed -i "/\[daemon\]/a AutomaticLoginEnable = true\nAutomaticLogin = ${KIOSK_USER}" /etc/gdm3/custom.conf
    else
        sed -i "s/^AutomaticLoginEnable.*/AutomaticLoginEnable = true/" /etc/gdm3/custom.conf
        sed -i "s/^AutomaticLogin[[:space:]]*=.*/AutomaticLogin = ${KIOSK_USER}/" /etc/gdm3/custom.conf
    fi
    ok "GDM3-Autologin für '$KIOSK_USER' konfiguriert (/etc/gdm3/custom.conf)."
elif [ -d /etc/lightdm ]; then
    log "LightDM erkannt. Richte Autologin ein..."
    mkdir -p /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-libki-kiosk.conf <<LIGHTDM_EOF
[Seat:*]
autologin-user=${KIOSK_USER}
autologin-session=libki-kiosk
LIGHTDM_EOF
    ok "LightDM-Autologin für '$KIOSK_USER' konfiguriert."
else
    warn "Weder GDM3 noch LightDM gefunden. Bitte Autologin manuell einrichten"
    warn "und dabei die Sitzung 'Libki Kiosk' auswählen."
fi

# ----------------------------- Abschluss ---------------------------------------
cat <<EOF

--------------------------------------------------------------------
Kiosk-Härtung abgeschlossen!

Was jetzt anders ist:
  - Es gibt eine neue Sitzung "Libki Kiosk" (Openbox, ohne Taskleiste,
    ohne Tastenkürzel, ohne Rechtsklick-Menü)
  - Der Benutzer '$KIOSK_USER' meldet sich (sofern Autologin geklappt hat)
    automatisch in genau dieser Sitzung an
  - Ein Watchdog hält libkiclient dauerhaft im Vollbild, fokussiert und
    ganz oben, und startet es neu, falls es beendet wird
  - Strg+Alt+F1 bis F7 (virtuelle Konsolen) sind auf der ganzen Maschine
    deaktiviert

WICHTIG - bitte manuell prüfen:
  1. Starte den Rechner neu und melde dich einmal am Login-Bildschirm an,
     um zu bestätigen, dass die Sitzung "Libki Kiosk" ausgewählt ist
     (Zahnrad-Symbol am Login-Bildschirm, falls Autologin nicht greift).
  2. Teste bewusst: Super-Taste, Alt+Tab, Strg+Esc, Strg+Alt+F2,
     Rechtsklick auf den Desktop - all das sollte jetzt wirkungslos sein.
  3. Falls dein Libki-Server über SIP2/ILS-Integration verfügt und du das
     Fenster testweise minimieren willst: Es sollte automatisch innerhalb
     von ca. 1 Sekunde durch den Watchdog zurückgeholt werden.
  4. Für Wartungsarbeiten: entweder per SSH verbinden, oder temporär
     /etc/X11/xorg.conf.d/10-disable-vt-switch.conf umbenennen/löschen
     und den Rechner neu starten.

Log dieses Durchlaufs: $LOGFILE
--------------------------------------------------------------------
EOF
