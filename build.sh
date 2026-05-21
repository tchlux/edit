#!/bin/sh
set -eu
cc -std=c11 -Wall -Wextra -pedantic -O2 -o edit edit.c grammar.c regex.c

app=Edit.app
bin="$app/Contents/MacOS"
res="$app/Contents/Resources"
rm -rf "$app"
mkdir -p "$bin" "$res"
cc -fobjc-arc -framework Cocoa -lutil -o "$bin/Edit" macos/edit_app.m
cp edit "$res/edit"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Edit</string>
  <key>CFBundleIdentifier</key>
  <string>com.thomaslux.edit</string>
  <key>CFBundleName</key>
  <string>Edit</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Text Document</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.text</string>
        <string>public.source-code</string>
      </array>
    </dict>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
