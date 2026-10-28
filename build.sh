#!/bin/zsh
# Builds "Mayfly's Wallpaper Lab.app" (with its Finder right-click extension) next to this script:
# own aerial entry, hardware encoder, no x265.
set -e
cd "$(dirname "$0")"
APP="Mayfly's Wallpaper Lab.app"
EXT="$APP/Contents/PlugIns/MayflysWallpaperLabFinder.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/MayflysWallpaperLab" Sources/*.swift 2>&1 | grep -E "error:" -A3 || true
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.mayfly.wallpaperlab</string>
  <key>CFBundleName</key><string>Mayfly's Wallpaper Lab</string>
  <key>CFBundleDisplayName</key><string>Mayfly's Wallpaper Lab</string>
  <key>CFBundleExecutable</key><string>MayflysWallpaperLab</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>local.mayfly.wallpaperlab</string>
    <key>CFBundleURLSchemes</key><array><string>mayflywallpaperlab</string></array>
  </dict></array>
</dict></plist>
PLIST

# Finder Sync extension: an app extension, so its entry point is NSExtensionMain and it must be sandboxed.
swiftc -O -application-extension -module-name MayflysWallpaperLabFinder -framework FinderSync \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/Contents/MacOS/MayflysWallpaperLabFinder" FinderExtension/FinderSync.swift 2>&1 | grep -E "error:" -A3 || true
cat > "$EXT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.mayfly.wallpaperlab.finder</string>
  <key>CFBundleName</key><string>Mayfly's Wallpaper Lab Finder</string>
  <key>CFBundleDisplayName</key><string>Mayfly's Wallpaper Lab</string>
  <key>CFBundleExecutable</key><string>MayflysWallpaperLabFinder</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
    <key>NSExtensionPrincipalClass</key><string>FinderSync</string>
    <key>NSExtensionAttributes</key><dict/>
  </dict>
</dict></plist>
PLIST

codesign --force --sign - --entitlements FinderExtension/FinderExtension.entitlements "$EXT"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
