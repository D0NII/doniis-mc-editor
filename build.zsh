#!/bin/zsh
# Baut "DONII's MC Editor.app" aus MCAssetStudio.swift (benötigt Xcode oder die Command Line Tools)
emulate -L zsh
setopt err_exit pipe_fail no_unset

# In den Ordner wechseln, in dem dieses Skript liegt
cd "${0:A:h}"

if (( ! $+commands[swiftc] )); then
  print -u2 "swiftc nicht gefunden – bitte zuerst im Terminal ausführen:  xcode-select --install"
  exit 1
fi

APP="DONII's MC Editor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 MCAssetStudio.swift -o "$APP/Contents/MacOS/MCAssetStudio"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DONII's MC Editor</string>
  <key>CFBundleDisplayName</key><string>DONII's MC Editor</string>
  <key>CFBundleIdentifier</key><string>local.donii.mceditor</string>
  <key>CFBundleExecutable</key><string>MCAssetStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

print "Fertig: $PWD/$APP"
(( $+commands[ffmpeg] )) || print "Hinweis: ffmpeg fehlt noch (für Sound-Vorschau & eigene Sounds) → brew install ffmpeg"
open -R "$APP"
