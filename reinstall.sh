#!/bin/bash
# Rebuild volknob.swift and reload the installed app in /Applications.
#
# Why the Accessibility dance below is needed: the app is ad-hoc signed, so every
# rebuild produces a new code signature. macOS ties the Accessibility grant (needed
# for the volume-key event tap) to that signature, so after every rebuild the old
# grant is dead. Toggling the existing checkbox in System Settings does NOT fix it —
# the stored entry still references the old signature. The entry must be deleted
# (tccutil reset) and granted fresh.
set -e
cd "$(dirname "$0")"

echo "1/5  Compiling…"
swiftc -O -o volknob volknob.swift \
  -framework Cocoa -framework CoreAudio -framework CoreGraphics -framework ApplicationServices

echo "2/5  Installing binary + icon into /Applications/VolKnob.app…"
cp volknob /Applications/VolKnob.app/Contents/MacOS/volknob
mkdir -p /Applications/VolKnob.app/Contents/Resources
cp VolKnob.icns /Applications/VolKnob.app/Contents/Resources/VolKnob.icns
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile VolKnob" /Applications/VolKnob.app/Contents/Info.plist 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string VolKnob" /Applications/VolKnob.app/Contents/Info.plist
codesign --force --deep -s - /Applications/VolKnob.app   # sign last — sealing the finished bundle

echo "3/5  Clearing the stale Accessibility grant…"
tccutil reset Accessibility com.volknob.app

echo "4/5  Restarting the app…"
launchctl kickstart -k "gui/$(id -u)/com.volknob.app"

echo "5/5  ACTION NEEDED: re-grant Accessibility"
echo "     System Settings → Privacy & Security → Accessibility → enable VolKnob."
echo "     (The app will have popped this dialog for you.)"
echo
read -r -p "Press Enter once you've re-enabled it… "
launchctl kickstart -k "gui/$(id -u)/com.volknob.app"
echo "Done. VolKnob reloaded with the new build."
