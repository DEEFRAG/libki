#!/usr/bin/env bash
#
# add_german.sh
# Fügt eine deutsche Übersetzung (Deutsch) zu einer bestehenden
# Libki-Server-Installation (Docker-Variante) hinzu.
#
# Voraussetzung:
#   - Libki wurde mit dem Docker-Compose-Setup installiert
#     (Standardpfad: /opt/libki-server)
#   - Die Datei de.po liegt im selben Verzeichnis wie dieses Script
#
# Ausführen mit:
#   sudo bash add_german.sh [/pfad/zu/libki-server]
#
set -euo pipefail

INSTALL_DIR="${1:-/opt/libki-server}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "${INSTALL_DIR}/lib/Libki/I18N" ]]; then
  echo "Konnte ${INSTALL_DIR}/lib/Libki/I18N nicht finden."
  echo "Bitte den korrekten Pfad zur Libki-Server-Installation als Argument angeben:"
  echo "  sudo bash add_german.sh /pfad/zu/libki-server"
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/de.po" ]]; then
  echo "de.po wurde nicht im selben Verzeichnis wie dieses Script gefunden."
  exit 1
fi

I18N_DIR="${INSTALL_DIR}/lib/Libki/I18N"

echo "--- Kopiere deutsche Übersetzung ---"
cp "${SCRIPT_DIR}/de.po" "${I18N_DIR}/de.po"

if [[ -f "${SCRIPT_DIR}/api_key_template.patch" ]]; then
  echo "--- Wende Template-Patch an (übersetzbare Texte im API-Schlüssel-Bereich) ---"
  cd "${INSTALL_DIR}"
  if git apply --check "${SCRIPT_DIR}/api_key_template.patch" 2>/dev/null; then
    git apply "${SCRIPT_DIR}/api_key_template.patch"
    echo "  Patch angewendet."
  else
    echo "  Hinweis: Patch konnte nicht automatisch angewendet werden (evtl. schon vorhanden oder Datei geändert)."
    echo "  Bitte bei Bedarf manuell prüfen: ${SCRIPT_DIR}/api_key_template.patch"
  fi
fi

echo "--- Ergänze 'Deutsch' im Sprachmenü aller vorhandenen Sprachen ---"
for f in "${I18N_DIR}"/*.po; do
  base="$(basename "$f")"
  if [[ "$base" == "de.po" ]]; then
    continue
  fi
  if ! grep -q '"lang.de"' "$f"; then
    printf '\nmsgid "lang.de"\nmsgstr "Deutsch"\n' >> "$f"
    echo "  lang.de ergänzt in ${base}"
  else
    echo "  ${base} enthält lang.de bereits, überspringe"
  fi
done

echo "--- Baue den Libki-Container neu (das kann einige Minuten dauern) ---"
cd "${INSTALL_DIR}/docker"
docker compose build libki
docker compose up -d

echo
echo "Fertig! Nach dem Neuladen der Seite sollte oben rechts im Sprachmenü"
echo "(Globus-Symbol) jetzt auch 'Deutsch' auswählbar sein."
echo
echo "Falls die Seite noch Englisch zeigt: Browser-Cache leeren bzw. mit"
echo "Strg+Shift+R neu laden, und prüfen, dass der Container neu gestartet ist:"
echo "  docker compose ps"
