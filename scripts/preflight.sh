#!/bin/sh
# Read-only host checks. This script never installs or downloads anything.
set -eu

fail() { printf 'StremIOS preflight: %s\n' "$*" >&2; exit 1; }
launch_mode=${MS_LAUNCH_MODE:-storyboard}
case "$launch_mode" in
    storyboard|static-ipad12) ;;
    *) fail 'MS_LAUNCH_MODE must be storyboard (default) or static-ipad12.' ;;
esac

[ "$(uname -s)" = Darwin ] || fail 'Build on macOS with full Xcode and its iOS platform support.'
for tool in xcode-select xcrun codesign plutil ditto shasum awk; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required macOS tool is unavailable: $tool"
done

developer_dir=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}
if [ -z "$developer_dir" ] || [ ! -d "$developer_dir/Platforms/iPhoneOS.platform" ]; then
    printf '%s\n' \
        'StremIOS cannot be built yet: the selected developer tools do not contain the iPhoneOS platform.' \
        "Selected developer directory: ${developer_dir:-none}" \
        'Command Line Tools alone are insufficient. Install full Xcode from Apple with iOS platform support.' \
        'Then, if needed, select it for this command without changing the system default:' \
        '  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build.sh' \
        'No tools or SDKs have been downloaded or installed by this script.' >&2
    exit 1
fi

sdk_path=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) || fail 'The iPhoneOS SDK is unavailable. Complete iOS platform setup in Xcode.'
[ -d "$sdk_path" ] || fail "SDK directory does not exist: $sdk_path"
for tool in clang lipo otool; do
    xcrun --sdk iphoneos --find "$tool" >/dev/null 2>&1 || fail "Xcode tool is unavailable: $tool"
done
if [ "$launch_mode" = storyboard ]; then
    xcrun --sdk iphoneos --find ibtool >/dev/null 2>&1 || fail 'ibtool is unavailable for storyboard mode. See the documented static-ipad12 option for a device-only build.'
fi
xcrun --sdk macosx --find swift >/dev/null 2>&1 || fail 'The host Swift compiler is unavailable; it is used only to generate static icons.'
xcrun xcodebuild -version >/dev/null 2>&1 || fail 'Xcode is not ready. Open it and complete its first-launch setup.'
xcrun xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || fail 'Xcode first-launch setup is incomplete. Complete it before building.'

printf '%s\n' \
    "iPhoneOS SDK: $sdk_path" \
    "Launch mode: $launch_mode" \
    'Target: ordinary arm64 iPad app, minimum iOS 12.0, ad-hoc signed.' \
    'An iOS 12 build must be tested on the real iPad; newer Xcode versions do not provide iOS 12 simulator/debug support.'
if [ "$launch_mode" = static-ipad12 ]; then
    printf '%s\n' 'Static launch mode skips ibtool. It preserves all iPad orientations, but opts this build out of Slide Over/Split View.'
fi
