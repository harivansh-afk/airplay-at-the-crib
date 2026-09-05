#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p 'build/AirplayAtTheCrib.app/Contents/MacOS'
for arch in arm64 x86_64; do
  /usr/bin/swiftc -O -target "$arch-apple-macos13.0" Sources/main.swift -o "build/AirplayAtTheCrib-$arch"
done
/usr/bin/lipo -create build/AirplayAtTheCrib-arm64 build/AirplayAtTheCrib-x86_64 -output 'build/AirplayAtTheCrib.app/Contents/MacOS/AirplayAtTheCrib'
cp Info.plist 'build/AirplayAtTheCrib.app/Contents/Info.plist'
mkdir -p 'build/AirplayAtTheCrib.app/Contents/Resources'
/usr/bin/swift Sources/icon.swift build/AppIcon.iconset
/usr/bin/iconutil -c icns build/AppIcon.iconset -o 'build/AirplayAtTheCrib.app/Contents/Resources/AppIcon.icns'
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" 'build/AirplayAtTheCrib.app'
else
  /usr/bin/codesign --force --sign - 'build/AirplayAtTheCrib.app'
fi
/usr/bin/codesign --verify --deep --strict 'build/AirplayAtTheCrib.app'
/usr/bin/ditto -c -k --sequesterRsrc --keepParent 'build/AirplayAtTheCrib.app' build/AirplayAtTheCrib.zip
/usr/bin/shasum -a 256 build/AirplayAtTheCrib.zip
