add_german.sh - Fügt die deutsche Sprachdatei de.po zum Libki Server hinzu und wendet api_key_template.patch und user_table_translation.patch an um fehlende Übersetzungen hinzuzufügen.

install_libki_client_de.sh - Installiert den verwaisten Qt6 Branch des Libki Client auf Ubuntu 24.04 und fügt die deutschen Sprachdateien hinzu.

install_libki_client_qt5_de.sh - Installationsscript für den Libki Client in aktuellster Version mit Qt5 für Linux (Ubuntu 24).

install_libki_de_docker.sh - Kombiniert die Installation des Libki Servers in einem Docker Container mit der Installation der deutschen Sprachdatei de.po und dem Anwenden der beiden Patches user_table_translation.patch und api_key_template.patch um fehlende Übersetzungen im Code zu fixen.

install_libki_server.sh - Installiert den Libki Server auf Debian 13 in einem Docker Container und führt diesen dann aus. Um den Server auf deutsch zu bekommen muss danach noch die Datei add_german.sh ausgeführt werden.

libki-client-build_qt5_de.zip - Dieses Archiv enthält die Libki Client Quelldateien, deutsche Sprachdateien und die fertig kompilierte Libki Client 2.3.0 Binärdatei für Linux.

libki-client-qt6.patch - Dieser Patch ändert den Code des Qt5 Branch vom Libki Client so ab, dass dieser auf Qt6 portiert wird. Fügt außerdem deutsche Sprachdateien hinzu. Ändert sogar das Installerscript für die Erstellung der Windows Installationsdatei so ab, dass alles deutsch ist, wenn man mit einem auf Deutsch eingestellten Betriebssystem den gebauten Installer ausführt.

libki-client-qt6.zip - Dieses Archiv enthält die Libki Client Quelldateien Version 2.3.0 welche von Qt5 zu Qt6 portiert wurden, die deutschen Sprachdateien, ein auf deutsch übersetztes Installationsscript zum erstellen des Installationsprogramms für die Windows Version, die fertig kompilierte Libki Client Binärdatei für ein 64 Bit Windows (benötigt zur Ausführung noch die Qt 6.11.1 Dateien) und den Installer für Linux (Ubuntu 26).

libki-handbuch.html - Auf deutsch übersetztes Libki Handbuch.

libki-server.zip - Dieses Archiv enthält die Quelldateien für den Libki Server Version 5.3.1 inklusive der deutschen Sprachdatei de.po und bereits angewendeter Code Patches welche fehlende Übersetzungen hinzufügt.

libkiclient - Fertig kompilierte Libki Client 2.2.26 Binärdatei auf Deutsch für Intel 64 Bit (erstellt auf Ubuntu 24.04 mit Qt6).

libkiclient.exe - Der fertig kompilierte Libki Client Version 2.3.0 inklusive deutscher Sprache für Windows x86. Benötigt zum ausführen noch Qt 5.15.2 Framework Dateien.

libkiclient_2.3.0_amd64.deb - Installationsdatei für den Libki Client Version 2.3.0 für Linux (Ubuntu 24, benötigt Qt5).

libkiclient_2.3.0_amd64_qt6.deb - Libki Client Version 2.3.0 Ubuntu 26 Qt6 64 Bit Intel Installer.

libkiclient_qt6.exe - Der fertig kompilierte Libki Client Version 2.3.0 inklusive deutscher Sprache für Windows x86_64. Benötigt zum ausführen noch Qt 6.11.1 Framework Dateien.

setup_libki_kiosk_lockdown.sh - Ein Script welches Linux abhärtet, damit Anwender nicht mehr einfach so den Libki Client minimieren können und so weiter. Achtung: Könnte sein, dass man nach der Installation nicht mehr ins System rein kommt. Also bitte Backup/Prüfpunkt erstellen bevor dieses Script ausgeführt wird.
