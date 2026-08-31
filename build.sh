#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Builds Vorssaint, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# Flags: --dev builds the local-only "Vorssaint (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
    esac
done

if (( DEV )); then
    APP_NAME="Cyra (Developer)"
    EXECUTABLE="CyraDeveloper"
    APP_BUNDLE_ID="com.cyra.utils.dev"
    BUILD_VARIANT_FLAGS=(-D CYRA_DEVELOPMENT -D VORSSAINT_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    APP_NAME="Cyra"
    EXECUTABLE="Cyra"
    APP_BUNDLE_ID="com.cyra.utils"
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
TARGET="x86_64-apple-macosx14.0"
ENTITLEMENTS="Resources/Cyra.entitlements"
LEGACY_IDENTITY="${CODESIGN_IDENTITY:-Cyra Utils Signing}"

developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local devid
    devid="$(developer_id_identity)"

    echo "▸ Finalizing installed signature…"
    sleep 3
    if [[ -n "$devid" ]]; then
        [[ -f "$helper" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$FAN_HELPER_ID" --sign "$devid" "$helper"
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$devid" "$bundle"
    elif security find-identity -p codesigning 2>/dev/null | grep -q "$LEGACY_IDENTITY"; then
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign "$LEGACY_IDENTITY" "$helper"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign - "$helper"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${CYRA_INSTALL_CHILD:-${VORSSAINT_INSTALL_CHILD:-0}}" != "1" ]]; then
    CYRA_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `MetricsTests` keeps every suite name inside these two namespaces (a
# check in the test file holds it to that), which is what makes this sweep
# complete rather than a list to keep in step by hand.
discard_test_preferences() {
    local preferences="$HOME/Library/Preferences" name
    for name in "cyra.tests." "com.cyra.tests." "vorss.tests." "com.vorssaint.tests."; do
        find "$preferences" -maxdepth 1 -name "$name*.plist" -delete 2>/dev/null || true
    done
    # The harness has no bundle identifier, so `UserDefaults.standard` writes
    # a file named after the executable.
    rm -f "$preferences/metrics-tests.plist"
    local survivors
    survivors=$(find "$preferences" -maxdepth 1 \
        \( -name "cyra.tests.*.plist" -o -name "com.cyra.tests.*.plist" \
           -o -name "vorss.tests.*.plist" -o -name "com.vorssaint.tests.*.plist" \
           -o -name "metrics-tests.plist" \) 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$survivors" != "0" ]]; then
        echo "✗ the test run left $survivors preference file(s) in $preferences" >&2
        return 1
    fi
}

# --test: compile and run the standalone unit tests (pure helpers only: metrics,
# Homebrew parsing, defaults, localization contracts; no app, no UI, no IOKit),
# then exit. Fast and deterministic; no XCTest needed.
if (( TEST )); then
    echo "▸ Building & running unit tests against $(basename "$SDK")…"
    rm -rf build
    mkdir -p build
    # The full app build below remains optimized and is the optimizer gate.
    # Unit assertions do not need optimization; avoiding it cuts most of the
    # test harness compile time without reducing the code the tests exercise.
    swiftc -Onone -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${VM_STATISTICS_COMPAT_FLAGS[@]}" \
        Sources/Cyra/Services/Media/MediaSupport.swift \
        Sources/Cyra/Core/Defaults.swift \
        Sources/Cyra/Core/FeatureCatalog.swift \
        Sources/Cyra/Core/FeaturePresets.swift \
        Sources/Cyra/Core/FeatureHubStrings.swift \
        Sources/Cyra/Core/ShortcutSettingsStrings.swift \
        Sources/Cyra/Core/SettingsBackupSupport.swift \
        Sources/Cyra/Core/BackupStrings.swift \
        Sources/Cyra/Core/SnippetStrings.swift \
        Sources/Cyra/Core/BrightnessStrings.swift \
        Sources/Cyra/Core/MediaImageStrings.swift \
        Sources/Cyra/Core/QuickToggleStrings.swift \
        Sources/Cyra/Core/ScreenshotStrings.swift \
        Sources/Cyra/Core/RecentCaptureStrings.swift \
        Sources/Cyra/Core/RecorderStrings.swift \
        Sources/Cyra/Core/RecorderShareStrings.swift \
        Sources/Cyra/Core/CameraPreviewStrings.swift \
        Sources/Cyra/Core/ScratchpadStrings.swift \
        Sources/Cyra/Core/FinderRenameStrings.swift \
        Sources/Cyra/Core/CommandBarStrings.swift \
        Sources/Cyra/Core/FeedbackStrings.swift \
        Sources/Cyra/Core/RadialMenuStrings.swift \
        Sources/Cyra/Core/MenuBarAppearanceStrings.swift \
        Sources/Cyra/Core/AppAppearance.swift \
        Sources/Cyra/Core/AppearanceStrings.swift \
        Sources/Cyra/Core/BatteryTimeStrings.swift \
        Sources/Cyra/Core/KeepAwakeStrings.swift \
        Sources/Cyra/Core/BluetoothSleepStrings.swift \
        Sources/Cyra/Core/PermissionGuideStrings.swift \
        Sources/Cyra/Core/FanControlStrings.swift \
        Sources/Cyra/Services/FanControl/FanControlSupport.swift \
        Sources/Cyra/Services/Snippets/TextSnippetSupport.swift \
        Sources/Cyra/Services/RadialMenu/RadialMenuSupport.swift \
        Sources/Cyra/Services/QuickTools/ScratchpadSupport.swift \
        Sources/Cyra/Services/KillProcess/KillProcessSupport.swift \
        Sources/Cyra/Services/Recorder/RecorderSupport.swift \
        Sources/Cyra/Services/Recorder/RecordingSharingSupport.swift \
        Sources/Cyra/Services/PrivateFileStore.swift \
        Sources/Cyra/Services/Recorder/RecorderTakeStore.swift \
        Sources/Cyra/Services/Recorder/RecorderMotion.swift \
        Sources/Cyra/Services/Recorder/RecorderPointerTrack.swift \
        Sources/Cyra/Services/Recorder/RecorderTypingTrack.swift \
        Sources/Cyra/Services/Recorder/RecorderTimeline.swift \
        Sources/Cyra/Services/Recorder/RecorderTextOverlay.swift \
        Sources/Cyra/Services/Recorder/RecorderEditDocument.swift \
        Sources/Cyra/Core/AppInfo.swift \
        Sources/Cyra/Core/GlobalShortcut.swift \
        Sources/Cyra/Core/Localization.swift \
        Sources/Cyra/Core/Localizations/Strings+*.swift \
        Sources/Cyra/Core/FeatureStrings.swift \
        Sources/Cyra/Core/KillProcessStrings.swift \
        Sources/Cyra/Core/WhatsAppDownloadStrings.swift \
        Sources/Cyra/Core/WhatsAppOrganizerStrings.swift \
        Sources/Cyra/Core/ReleaseNotes.swift \
        Sources/Cyra/Core/URLCleaning.swift \
        Sources/Cyra/Services/GeneralPasteboardAccess.swift \
        Sources/Cyra/Services/Audio/MixerRoutingSupport.swift \
        Sources/Cyra/Services/Audio/MusicLaunchSupport.swift \
        Sources/Cyra/Services/Bluetooth/BluetoothSleepSupport.swift \
        Sources/Cyra/UI/MenuPanel/MixerPercentNativeTextField.swift \
        Sources/Cyra/Services/Audio/BoostLimiter.swift \
        Sources/Cyra/Services/Audio/MixerRender.swift \
        Sources/Cyra/Services/Audio/PreciseVolumeRollerSupport.swift \
        Sources/Cyra/Services/DockPreview/DockPreviewSupport.swift \
        Sources/Cyra/Services/Homebrew/HomebrewSupport.swift \
        Sources/Cyra/Services/AppUpdates/AppUpdatesSupport.swift \
        Sources/Cyra/Core/AppUpdateStrings.swift \
        Sources/Cyra/Core/DiskImageInstallerStrings.swift \
        Sources/Cyra/Services/DiskImageInstaller/DiskImageInstallerSupport.swift \
        Sources/Cyra/Services/Clipboard/ClipboardHistorySupport.swift \
        Sources/Cyra/Services/Clipboard/ClipboardAutoClearSupport.swift \
        Sources/Cyra/Services/AutoQuit/AutoQuitSupport.swift \
        Sources/Cyra/Services/Shelf/ShelfSupport.swift \
        Sources/Cyra/Services/Finder/FinderRenameSupport.swift \
        Sources/Cyra/Services/Update/UpdateInstallerSupport.swift \
        Sources/Cyra/Services/Update/UpdateServiceSupport.swift \
        Sources/Cyra/Services/InstalledApps.swift \
        Sources/Cyra/Services/LaunchAtLoginSupport.swift \
        Sources/Cyra/UI/Settings/SettingsSearchSupport.swift \
        Sources/Cyra/UI/Settings/FeatureVisibilitySupport.swift \
        Sources/Cyra/App/MenuBarSpacingSupport.swift \
        Sources/Cyra/App/StatusItemAnchorSupport.swift \
        Sources/Cyra/Services/DockClick/DockClickSupport.swift \
        Sources/Cyra/Services/Finder/CutPasteProgressSupport.swift \
        Sources/Cyra/Services/Finder/FinderPasteImageSupport.swift \
        Sources/Cyra/Services/MiddleClick/MiddleClickSupport.swift \
        Sources/Cyra/Services/MouseNavigation/MouseNavigationSupport.swift \
        Sources/Cyra/Services/MouseButtons/MouseButtonShortcutSupport.swift \
        Sources/Cyra/Services/MouseExceptions/MouseAppExceptionSupport.swift \
        Sources/Cyra/Core/MouseButtonStrings.swift \
        Sources/Cyra/Core/MouseExceptionStrings.swift \
        Sources/Cyra/Core/ClipboardIgnoredAppsStrings.swift \
        Sources/Cyra/Core/WindowPreviewExclusionStrings.swift \
        Sources/Cyra/Core/SwitcherAppRulesStrings.swift \
        Sources/Cyra/Services/QuickTools/QuickToolsSupport.swift \
        Sources/Cyra/Services/CommandBar/CommandBarSupport.swift \
        Sources/Cyra/Services/CommandBar/CommandBarPreferences.swift \
        Sources/Cyra/Services/CommandBar/CommandBarMath.swift \
        Sources/Cyra/Services/CommandBar/CommandBarUnits.swift \
        Sources/Cyra/Services/CommandBar/CommandBarEmoji.swift \
        Sources/Cyra/Services/CommandBar/CommandBarLinks.swift \
        Sources/Cyra/Services/CommandBar/CommandBarDates.swift \
        Sources/Cyra/Services/CommandBar/CommandBarRowShortcuts.swift \
        Sources/Cyra/Services/CommandBar/CommandBarSystemSettingsSupport.swift \
        Sources/Cyra/Services/CommandBar/CommandBarFileSearchSupport.swift \
        Sources/Cyra/Services/CommandBar/CommandBarQueryMemory.swift \
        Sources/Cyra/Services/SpotlightNamesSupport.swift \
        Sources/Cyra/Services/QuickTools/MicMuteSupport.swift \
        Sources/Cyra/Services/QuickTools/QuickTogglesSupport.swift \
        Sources/Cyra/Services/QuickTools/ScreenshotCapturePolicy.swift \
        Sources/Cyra/Services/QuickTools/ScreenshotSupport.swift \
        Sources/Cyra/Services/QuickTools/ScreenshotSharingSupport.swift \
        Sources/Cyra/Services/QuickTools/WindowActivationPolicy.swift \
        Sources/Cyra/Services/KeyboardDebounce/KeyboardDebounceSupport.swift \
        Sources/Cyra/Services/SuperKey/SuperKeySupport.swift \
        Sources/Cyra/Core/SuperKeyStrings.swift \
        Sources/Cyra/Services/ScrollWheelSupport.swift \
        Sources/Cyra/Services/SmoothScrollSupport.swift \
        Sources/Cyra/Services/FocusFollowsMouse/FocusFollowsMouseSupport.swift \
        Sources/Cyra/Services/Switcher/SwitcherModels.swift \
        Sources/Cyra/Services/Switcher/SwitcherSupport.swift \
        Sources/Cyra/Services/Switcher/SpaceHopSupport.swift \
        Sources/Cyra/Services/Switcher/WindowUseOrder.swift \
        Sources/Cyra/Services/Metrics/MetricFormat.swift \
        Sources/Cyra/Services/Metrics/VMStatisticsDecoder.swift \
        Sources/Cyra/Services/KeepAwakeAutomationSupport.swift \
        Sources/Cyra/Services/SudoersSupport.swift \
        Sources/Cyra/Services/Metrics/BatteryTimeSupport.swift \
        Sources/Cyra/Services/BoundedProcessRunner.swift \
        Sources/Cyra/Services/ShellSupport.swift \
        Sources/Cyra/Services/Metrics/NetworkProcessSupport.swift \
        Sources/Cyra/Services/Metrics/NetworkSampler.swift \
        Sources/Cyra/Services/Metrics/PeripheralBatterySupport.swift \
        Sources/Cyra/Services/Metrics/DiskSupport.swift \
        Sources/Cyra/Services/Metrics/MonitorSamplingPolicy.swift \
        Sources/Cyra/Services/Metrics/MaxCapacityProbe.swift \
        Sources/Cyra/Services/Metrics/TemperatureSensorSelector.swift \
        Sources/Cyra/Services/Metrics/SustainedAlertGate.swift \
        Sources/Cyra/Services/WindowLayout/WindowLayoutSupport.swift \
        Sources/Cyra/Services/WindowLayout/WindowGestureSupport.swift \
        Sources/Cyra/Core/WindowDirectionalStrings.swift \
        Sources/Cyra/Services/CleaningMode/CleaningUnlockCounter.swift \
        Sources/Cyra/Services/Display/ExtraBrightnessSupport.swift \
        Sources/Cyra/Services/Display/BrightnessSupport.swift \
        Sources/Cyra/Services/Cleaner/CleanerSupport.swift \
        Sources/Cyra/Services/Cleaner/CleanerPolicy.swift \
        Sources/Cyra/Services/Cleaner/CleanerSchedule.swift \
        Sources/Cyra/Services/Uninstall/UninstallerSupport.swift \
        Sources/Cyra/Services/ManagedDownloads/WhatsAppDownloadSupport.swift \
        Tests/MetricsTests.swift \
        -o build/metrics-tests
    # `set -e` would end the script on a failing run before the sweep below.
    test_status=0
    ./build/metrics-tests || test_status=$?
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/Cyra/**/*.swift)
if (( DEV )); then
    APP_OBJECT_DIR="build/objects/$EXECUTABLE"
    mkdir -p build "$APP_OBJECT_DIR"
    APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
    swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -j "$(sysctl -n hw.logicalcpu)" \
        -output-file-map "$APP_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" \
        "${BUILD_VARIANT_FLAGS[@]}" \
        "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"
    ln -sf "$EXECUTABLE" "build/Vorssaint"
else
    rm -rf build
    mkdir -p build
    swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -j "$(sysctl -n hw.logicalcpu)" \
        -target "$TARGET" -sdk "$SDK" \
        "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
        "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"
    ln -sf "$EXECUTABLE" "build/Vorssaint"
fi

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/Cyra/Services/FanControl/FanControlSupport.swift \
    Sources/Cyra/Services/FanControl/FanControlXPC.swift \
    Sources/Cyra/Services/SystemMonitor/SMCClient.swift \
    Sources/Cyra/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/Cyra/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
ACTOOL_BIN="$(xcrun --find actool 2>/dev/null || true)"
ICON_TMP="$(mktemp -d)"
ADAPTIVE_SKIP=""
if [[ -z "$ACTOOL_BIN" ]]; then
    ADAPTIVE_SKIP="actool not found (adaptive icons need Xcode 26+)"
else
    echo "▸ Compiling adaptive icon catalog…"
    # actool crashes on File Provider-synced paths, so compile a local copy.
    ditto "Resources/Brand/AppIcon.icon" "$ICON_TMP/AppIcon.icon"
    # Xcode 27 beta actool requires the --compile target directory to already exist.
    mkdir -p "$ICON_TMP/catalog"
    if "$ACTOOL_BIN" "$ICON_TMP/AppIcon.icon" \
            --compile "$ICON_TMP/catalog" \
            --app-icon AppIcon \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --enable-on-demand-resources NO \
            --output-partial-info-plist "$ICON_TMP/partial-info.plist" \
            >"$ICON_TMP/actool.log" 2>&1 && [[ -s "$ICON_TMP/catalog/Assets.car" ]]; then
        mv "$ICON_TMP/catalog/Assets.car" build/Assets.car
    else
        ADAPTIVE_SKIP="actool could not compile the catalog"
    fi
fi
if [[ -n "$ADAPTIVE_SKIP" ]]; then
    cp "$ICON_TMP/actool.log" build/actool-failure.log 2>/dev/null || true
    echo "  adaptive icon skipped: $ADAPTIVE_SKIP (Dock falls back to AppIcon.icns)"
fi
rm -rf "$ICON_TMP"

echo "▸ Assembling and signing bundle…"
STAGE="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
cp Resources/com.cyra.utils.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj(N); do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.cyra.utils.dev" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Cyra (Developer)" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Cyra (Developer)" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.cyra.utils.fan-control" "$FAN_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.vorssaint.utils.fan-control" "$FAN_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :CyraBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :CyraFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "Vorssaint Utils Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
DEVID="$(developer_id_identity)"
codesign_app() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$target"
    elif security find-identity -p codesigning 2>/dev/null | grep -q "$LEGACY_IDENTITY" && codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$target" 2>/dev/null; then
        :
    else
        codesign --force --strip-disallowed-xattrs --sign - "$target"
    fi
}

codesign_fan_helper() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$FAN_HELPER_ID" --sign "$DEVID" "$target"
    elif security find-identity -p codesigning 2>/dev/null | grep -q "$LEGACY_IDENTITY" && codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" \
            --sign "$LEGACY_IDENTITY" "$target" 2>/dev/null; then
        :
    else
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" --sign - "$target"
    fi
}

sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"

    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
    elif security find-identity -p codesigning 2>/dev/null | grep -q "$LEGACY_IDENTITY"; then
        echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    else
        echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    fi
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

process_is_running() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pgrep -f "/Contents/MacOS/$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

stop_process() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pkill -f "/Contents/MacOS/$proc" 2>/dev/null || true
    else
        pkill -x "$proc" 2>/dev/null || true
    fi
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

mkdir -p "build/stage"
BUILD_STAGE="build/stage/$APP_NAME.app"
rm -rf "$BUILD_STAGE"
ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
    if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
        echo "  build/stage copy has local filesystem metadata; temp bundle was verified"
    else
        codesign --verify --deep --strict "$BUILD_STAGE"
    fi
fi
echo "✓ Bundle ready: $BUILD_STAGE"

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    stop_process "$EXECUTABLE"
    # Remove the pre-rename apps so two menu bar items never coexist. Same bundle
    # id, so macOS keeps the granted permissions for the new bundle.
    for legacy in "Vorssaint:Vorssaint" "Vorss:Vorss" "Vorssaint Utils:VorssaintUtils"; do
        name="${legacy%%:*}"; proc="${legacy##*:}"
        if [[ -d "/Applications/$name.app" ]]; then
            stop_process "$proc"
            rm -rf "/Applications/$name.app"
            echo "  (legacy $name.app removed)"
        fi
    done
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi
