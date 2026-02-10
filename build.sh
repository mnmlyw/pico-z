#!/bin/bash
set -e

VERSION="${1:+_$1}"
VNUM="${1:-0.0.0}"
VNUM="${VNUM#v}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/tmp/release"

rm -rf "$OUT"
mkdir -p "$OUT"

cd "$ROOT"

# macOS (native arm64)
echo "Building macOS..."
zig build -Doptimize=ReleaseSafe --prefix tmp
mkdir -p "$OUT/pico-z/PICO-Z.app/Contents/MacOS" "$OUT/pico-z/PICO-Z.app/Contents/Resources"
cp tmp/bin/pico-z "$OUT/pico-z/PICO-Z.app/Contents/MacOS/pico-z"

cp "$ROOT/assets/icon.icns" "$OUT/pico-z/PICO-Z.app/Contents/Resources/pico-z.icns"
cp "$ROOT/assets/license.txt" "$OUT/pico-z/license.txt"
cp "$ROOT/assets/manual.txt" "$OUT/pico-z/"
cat > "$OUT/pico-z/PICO-Z.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>PICO-Z</string>
	<key>CFBundleDisplayName</key>
	<string>PICO-Z</string>
	<key>CFBundleIdentifier</key>
	<string>com.yw.pico-z</string>
	<key>CFBundleVersion</key>
	<string>${VNUM}</string>
	<key>CFBundleShortVersionString</key>
	<string>${VNUM}</string>
	<key>CFBundleExecutable</key>
	<string>pico-z</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>pico-z</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>PICO-8 Cartridge</string>
			<key>CFBundleTypeExtensions</key>
			<array>
				<string>p8</string>
				<string>p8.png</string>
			</array>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Default</string>
		</dict>
	</array>
</dict>
</plist>
EOF
xattr -cr "$OUT/pico-z/PICO-Z.app"
cd "$OUT" && zip -r "pico-z${VERSION}_macos.zip" pico-z/ && cd "$ROOT"
rm -rf "$OUT/pico-z"

# Windows
echo "Building Windows..."
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe --prefix tmp
mkdir -p "$OUT/pico-z"
cp tmp/bin/pico-z.exe "$OUT/pico-z/pico-z.exe"
cp "$ROOT/assets/license.txt" "$OUT/pico-z/license.txt"
cp "$ROOT/assets/manual.txt" "$OUT/pico-z/"
cd "$OUT" && zip -r "pico-z${VERSION}_windows.zip" pico-z/ && cd "$ROOT"
rm -rf "$OUT/pico-z"

# Linux
echo "Building Linux..."
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe --prefix tmp
mkdir -p "$OUT/pico-z"
cp tmp/bin/pico-z "$OUT/pico-z/pico-z"
cp "$ROOT/assets/license.txt" "$OUT/pico-z/license.txt"
cp "$ROOT/assets/manual.txt" "$OUT/pico-z/"
cp "$ROOT/assets/icon.png" "$OUT/pico-z/"
cd "$OUT" && zip -r "pico-z${VERSION}_linux.zip" pico-z/ && cd "$ROOT"
rm -rf "$OUT/pico-z"

echo ""
echo "Done:"
ls -lh "$OUT/"
