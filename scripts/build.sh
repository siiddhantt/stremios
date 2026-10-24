#!/bin/sh
# Usage: ./scripts/build.sh [build-directory]
# Uses only installed Apple tools. No download, provisioning, or device install.
set -eu
umask 022

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir=${1:-"$project_dir/build"}
[ "$#" -le 1 ] || { printf 'Usage: %s [build-directory]\n' "$0" >&2; exit 2; }
launch_mode=${MS_LAUNCH_MODE:-storyboard}
vlc_framework=${MS_VLCKIT_FRAMEWORK:-"$project_dir/.cache/vlckit/arm64/MobileVLCKit.framework"}
[ -f "$vlc_framework/Headers/VLCMediaPlayer.h" ] || { printf '%s\n' 'Missing verified MobileVLCKit headers; see Vendor/MobileVLCKit/BUILDING.txt.' >&2; exit 1; }
vlc_parent=$(CDPATH= cd -- "$(dirname -- "$vlc_framework")" && pwd)

MS_LAUNCH_MODE="$launch_mode" "$script_dir/preflight.sh"
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$build_dir"
build_dir=$(CDPATH= cd -- "$build_dir" && pwd)
# A unique staging directory prevents stale files being included on rebuilds.
stage_dir=$(mktemp -d "$build_dir/stage.XXXXXX")
app_dir="$stage_dir/Payload/StremIOS.app"
mkdir -p "$app_dir" "$stage_dir/objects" "$build_dir/module-cache"
printf 'Build directory: %s\n' "$build_dir"

"$script_dir/build-webp.sh" "$stage_dir" iphoneos
source_count=0
for source in "$project_dir"/Sources/*.m "$project_dir"/Sources/*.c; do
    [ -f "$source" ] || continue
    case "$source" in *.m) objc_arc_flag=-fobjc-arc ;; *) objc_arc_flag= ;; esac
    # This optional flag is either one fixed compiler argument or empty.
    xcrun --sdk iphoneos clang \
        -arch arm64 -isysroot "$sdk_path" -miphoneos-version-min=12.0 \
        $objc_arc_flag -fblocks -fmodules -fmodules-cache-path="$build_dir/module-cache" \
        -O2 -DNDEBUG -Wall -Wextra \
        -Werror=unguarded-availability -Werror=unguarded-availability-new \
        -F "$vlc_parent" -I "$project_dir/Sources" -c "$source" \
        -o "$stage_dir/objects/$(basename "$source").o"
    source_count=$((source_count + 1))
done
[ "$source_count" -gt 0 ] || { printf 'No .m or .c sources found in %s/Sources\n' "$project_dir" >&2; exit 1; }
xcrun --sdk iphoneos clang \
    -arch arm64 -isysroot "$sdk_path" -miphoneos-version-min=12.0 \
    "$stage_dir"/objects/*.o "$stage_dir/libwebpdecoder.a" \
    -framework Foundation -framework UIKit -framework AVFoundation \
    -framework AVKit -framework Security -framework CoreGraphics -framework QuartzCore \
    -framework CoreMedia -framework ImageIO \
    -F "$vlc_parent" -framework MobileVLCKit -Wl,-rpath,@executable_path/Frameworks \
    -o "$app_dir/StremIOS"

cp "$project_dir/Resources/Info.plist" "$app_dir/Info.plist"
# The licensed demo remains a test fixture, outside the production payload.
cp "$project_dir/Resources/ThirdPartyNotices.txt" "$app_dir/ThirdPartyNotices.txt"
plutil -lint "$app_dir/Info.plist"

# Default: compiled launch storyboard. The opt-in legacy mode below avoids
# ibtool and simulator services, at the cost of iPad multitasking support.
if [ "$launch_mode" = storyboard ]; then
cat > "$stage_dir/LaunchScreen.storyboard" <<'STORYBOARD'
<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="21507" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" launchScreen="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" initialViewController="launch-controller">
    <device id="ipad9_7" orientation="portrait" layout="fullscreen"/>
    <dependencies><deployment identifier="iOS"/><plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="21505"/><capability name="Safe area layout guides" minToolsVersion="9.0"/><capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/></dependencies>
    <scenes><scene sceneID="launch-scene"><objects>
        <viewController id="launch-controller" sceneMemberID="viewController"><view key="view" contentMode="scaleToFill" id="launch-view">
            <rect key="frame" x="0.0" y="0.0" width="768" height="1024"/>
            <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
            <viewLayoutGuide key="safeArea" id="launch-safe-area"/>
            <color key="backgroundColor" red="0.035" green="0.055" blue="0.082" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>
        </view></viewController>
        <placeholder placeholderIdentifier="IBFirstResponder" id="launch-responder" userLabel="First Responder" sceneMemberID="firstResponder"/>
    </objects></scene></scenes>
</document>
STORYBOARD
xcrun --sdk iphoneos ibtool \
    --compile "$app_dir/LaunchScreen.storyboardc" \
    --minimum-deployment-target 12.0 --target-device ipad \
    "$stage_dir/LaunchScreen.storyboard"
fi

if [ "$launch_mode" = static-ipad12 ]; then
    CLANG_MODULE_CACHE_PATH="$build_dir/module-cache" \
        xcrun --sdk macosx swift "$script_dir/make_icons.swift" "$app_dir" --static-ipad12-launch
else
    CLANG_MODULE_CACHE_PATH="$build_dir/module-cache" \
        xcrun --sdk macosx swift "$script_dir/make_icons.swift" "$app_dir"
fi
plutil -lint "$app_dir/Info.plist"

"$script_dir/embed-vlckit.sh" "$vlc_framework" "$app_dir"

# Deliberately no entitlements: no root, JIT, debugger, background, or sandbox bypass.
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict "$app_dir"

architectures=$(xcrun lipo -archs "$app_dir/StremIOS")
[ "$architectures" = arm64 ] || { printf 'Unexpected architectures: %s\n' "$architectures" >&2; exit 1; }
xcrun otool -l "$app_dir/StremIOS" > "$stage_dir/load-commands.txt"
if awk '$1 == "cmd" && $2 == "LC_DYLD_CHAINED_FIXUPS" { found = 1 } END { exit !found }' "$stage_dir/load-commands.txt"; then
    printf 'The binary uses chained fixups that are unsuitable for iOS 12. Inspect the selected linker/toolchain before installing.\n' >&2
    exit 1
fi
minimum_os=$(awk '
    $1 == "cmd" { platform = ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_IPHONEOS") }
    platform && ($1 == "minos" || $1 == "version") { print $2; exit }
' "$stage_dir/load-commands.txt")
case "$minimum_os" in 12.0|12.0.0) ;; *) printf 'Unexpected minimum OS: %s\n' "$minimum_os" >&2; exit 1;; esac
plist_minimum=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app_dir/Info.plist")
[ "$plist_minimum" = 12.0 ] || { printf 'Info.plist minimum OS differs: %s\n' "$plist_minimum" >&2; exit 1; }
xcrun otool -L "$app_dir/StremIOS" > "$stage_dir/dependencies.txt"
awk 'NR > 1 { print $1 }' "$stage_dir/dependencies.txt" | while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/Frameworks/*|/usr/lib/*|@rpath/MobileVLCKit.framework/MobileVLCKit) ;;
        *) printf 'Unexpected runtime dependency: %s\n' "$dependency" >&2; exit 1 ;;
    esac
done
codesign -d --entitlements :- "$app_dir" > "$stage_dir/entitlements.plist" 2> "$stage_dir/signing.txt"
if [ -s "$stage_dir/entitlements.plist" ]; then
    printf 'Unexpected embedded entitlements; inspect %s\n' "$stage_dir/entitlements.plist" >&2
    exit 1
fi

ipa_path="$build_dir/StremIOS-iOS12.ipa"
ditto -c -k --norsrc --noextattr --keepParent "$stage_dir/Payload" "$stage_dir/StremIOS-iOS12.ipa"
mv -f "$stage_dir/StremIOS-iOS12.ipa" "$ipa_path"
shasum -a 256 "$ipa_path" > "$build_dir/StremIOS-iOS12.ipa.sha256"
printf '\nBuilt: %s\nAudit: arm64, minimum iOS %s, pinned VideoLAN framework + Apple dependencies, no entitlements.\n' "$ipa_path" "$minimum_os"
printf 'Launch mode: %s\n' "$launch_mode"
printf 'Audit files and app bundle: %s\n' "$stage_dir"
printf '%s\n' 'This is a build audit, not an iPad runtime test. Installation was not attempted.'
