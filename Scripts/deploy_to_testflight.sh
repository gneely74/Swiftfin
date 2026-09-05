#!/usr/bin/env bash
# ==============================================================================
# Swiftfin: Automated Build, Archive & TestFlight Upload Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

TARGET_PLATFORM="${1:-both}"
API_KEY_ID="9MHL5YVWZ5"
API_ISSUER_ID="0126c02e-aa3e-4063-9a32-9ab86c316c8b"
TEAM_ID="PPK9R6P695"
BUNDLE_ID="com.gradyneely.swiftfin"

echo "========================================================"
echo "🚀 Swiftfin TestFlight Deployment Pipeline ($TARGET_PLATFORM)"
echo "========================================================"
echo "   Bundle ID: $BUNDLE_ID"
echo "   Team ID:   $TEAM_ID"
echo "   API Key:   $API_KEY_ID"
echo "========================================================"

deploy_platform() {
    local PLATFORM="$1"
    local SCHEME=""
    local DESTINATION=""
    local PROFILE_NAME=""
    local ALTOOL_TYPE=""

    if [[ "$PLATFORM" == "tvos" ]]; then
        SCHEME="Swiftfin tvOS"
        DESTINATION="generic/platform=tvOS"
        PROFILE_NAME="com.gradyneely.swiftfin TVOS AppStore"
        ALTOOL_TYPE="tvos"
    elif [[ "$PLATFORM" == "ios" ]]; then
        SCHEME="Swiftfin"
        DESTINATION="generic/platform=iOS"
        PROFILE_NAME="com.gradyneely.swiftfin IOS AppStore"
        ALTOOL_TYPE="ios"
    else
        echo "❌ Unknown platform: $PLATFORM. Use 'tvos', 'ios', or 'both'." >&2
        exit 1
    fi

    echo ""
    echo "--------------------------------------------------------"
    echo "📦 Starting deployment for $PLATFORM ($SCHEME)..."
    echo "--------------------------------------------------------"

    local DATE_DIR
    DATE_DIR=$(date +%Y-%m-%d)
    local ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$DATE_DIR"
    mkdir -p "$ARCHIVE_DIR"
    local ARCHIVE_PATH="$ARCHIVE_DIR/Swiftfin-${PLATFORM}-$(date +%Y%m%d-%H%M%S).xcarchive"
    local EXPORT_DIR="/tmp/Swiftfin-${PLATFORM}-export"

    # Ensure DevelopmentTeam.xcconfig exists and has correct profile specifier
    cat << CONFIG_EOF > "$SCRIPT_DIR/XcodeConfig/DevelopmentTeam.xcconfig"
DEVELOPMENT_TEAM = $TEAM_ID
PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID
CODE_SIGN_IDENTITY = Apple Distribution
CODE_SIGN_STYLE = Manual
PROVISIONING_PROFILE_SPECIFIER = $PROFILE_NAME
CONFIG_EOF

    echo "📦 Archiving $SCHEME..."
    xcodebuild archive \
        -project "$SCRIPT_DIR/Swiftfin.xcodeproj" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -archivePath "$ARCHIVE_PATH" \
        -skipMacroValidation \
        CODE_SIGN_STYLE=Manual \
        -quiet

    if [[ ! -d "$ARCHIVE_PATH" ]]; then
        echo "❌ Archiving failed for $PLATFORM." >&2
        exit 1
    fi
    echo "✅ Archive created: $ARCHIVE_PATH"

    echo "📤 Exporting IPA..."
    local EXPORT_PLIST="/tmp/Swiftfin_ExportOptions_${PLATFORM}.plist"
    cat << PLIST_EOF > "$EXPORT_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>uploadSymbols</key>
    <true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>$PROFILE_NAME</string>
    </dict>
</dict>
</plist>
PLIST_EOF

    rm -rf "$EXPORT_DIR"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -exportPath "$EXPORT_DIR" \
        -quiet

    local IPA_PATH
    IPA_PATH=$(find "$EXPORT_DIR" -name "*.ipa" | head -n 1)
    if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
        echo "❌ IPA export failed for $PLATFORM." >&2
        exit 1
    fi
    echo "✅ IPA exported: $IPA_PATH ($(du -h "$IPA_PATH" | cut -f1))"

    echo "🚀 Uploading $PLATFORM to TestFlight via App Store Connect API..."
    xcrun altool --upload-app \
        -f "$IPA_PATH" \
        -t "$ALTOOL_TYPE" \
        --apiKey "$API_KEY_ID" \
        --apiIssuer "$API_ISSUER_ID"

    echo "🎉 TestFlight upload complete for $PLATFORM!"
}

if [[ "$TARGET_PLATFORM" == "both" ]]; then
    deploy_platform "tvos"
    deploy_platform "ios"
elif [[ "$TARGET_PLATFORM" == "tvos" || "$TARGET_PLATFORM" == "ios" ]]; then
    deploy_platform "$TARGET_PLATFORM"
else
    echo "❌ Unknown platform argument: $TARGET_PLATFORM. Allowed: 'both' (default), 'tvos', 'ios'." >&2
    exit 1
fi

echo ""
echo "========================================================"
echo "🏁 All requested deployments completed successfully!"
echo "========================================================"
