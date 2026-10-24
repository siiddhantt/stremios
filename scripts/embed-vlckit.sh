#!/bin/sh
# Embed only the pinned arm64 device runtime. Never downloads dependencies.
set -eu
framework=$1
app=$2
binary="$framework/MobileVLCKit"
expected=f6e419aac2bfec8854792165772a2fe9af6a0ad121cac4eda05d70983334968b
[ -f "$binary" ] || { printf '%s\n' 'MobileVLCKit is missing. See Vendor/MobileVLCKit/BUILDING.txt.' >&2; exit 1; }
actual=$(shasum -a 256 "$binary" | awk '{print $1}')
[ "$actual" = "$expected" ] || { printf '%s\n' 'MobileVLCKit checksum differs from the verified arm64 binary.' >&2; exit 1; }
[ "$(xcrun lipo -archs "$binary")" = arm64 ] || exit 1
xcrun otool -L "$binary" | awk 'NR > 1 {print $1}' | while IFS= read -r dependency; do
 case "$dependency" in @rpath/MobileVLCKit.framework/MobileVLCKit|/System/Library/Frameworks/*|/usr/lib/*) ;; *) printf 'Unexpected VideoLAN dependency: %s\n' "$dependency" >&2; exit 1 ;; esac
done
mkdir -p "$app/Frameworks/MobileVLCKit.framework"
# Public headers/modules are compile-time resources and need not ship.
cp "$binary" "$app/Frameworks/MobileVLCKit.framework/MobileVLCKit"
cp "$framework/Info.plist" "$app/Frameworks/MobileVLCKit.framework/Info.plist"
codesign --force --sign - --timestamp=none "$app/Frameworks/MobileVLCKit.framework"
codesign --verify --strict "$app/Frameworks/MobileVLCKit.framework"
