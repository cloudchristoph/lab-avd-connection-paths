#!/usr/bin/env bash
# macos-enable-udp.sh: make Windows App for macOS offer UDP (RDP Shortpath).
#
# From "AVD connection paths, part 1: the client decides which path you get" and the checklist
#   https://cloudchristoph.com/articles/avd-connection-paths-1-the-client-decides/
#
# Windows App for macOS can ship with "Use UDP where possible" off. This sets the same switch
# through the preference key ClientSettings.EnableAvdUdpSideTransport, prints the app version,
# and reads the value back. Quit Windows App completely (menu, Quit) and start it again
# afterwards, then check Settings, General, "Use UDP where possible".
#
# For managed Macs, deploy the key with a configuration profile instead.

set -euo pipefail
APP="/Applications/Windows App.app"

if [ -f "$APP/Contents/Info.plist" ]; then
  echo "Windows App version: $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
else
  echo "Windows App not found in /Applications (continuing anyway)."
fi

defaults write com.microsoft.rdc.macos ClientSettings.EnableAvdUdpSideTransport -bool true
echo "ClientSettings.EnableAvdUdpSideTransport = $(defaults read com.microsoft.rdc.macos ClientSettings.EnableAvdUdpSideTransport)  (1 = on)"
echo "Now quit Windows App completely and start it again."
