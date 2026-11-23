#!/bin/bash
# 配布用の Tansu.dmg を作る。署名済みの Tansu.app を引数に渡して再梱包することもできる。
#
# 事前に必要なもの:
#   - キーチェーンに「Developer ID Application」証明書（秘密鍵つき）
#   - 公証用の認証情報: xcrun notarytool store-credentials tansu-notary --apple-id <Apple ID> --team-id <Team ID>
#
# Team ID は環境変数 TEAM_ID、なければ Config/Local.xcconfig の DEVELOPMENT_TEAM を使う。
# 公証の認証情報の名前は環境変数 NOTARY_PROFILE（既定は tansu-notary）。
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "使い方: Scripts/release.sh [署名済みの Tansu.app]" >&2
  exit 1
fi

APP="${1:-}"
case "$APP" in
  ""|/*) ;;
  *) APP="$PWD/$APP" ;;
esac
cd "$(dirname "$0")/.."

mkdir -p build/release
RELEASE_DIR="$PWD/build/release"
WORK="$(mktemp -d "$RELEASE_DIR/work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$APP" ]; then
  if [ -z "${TEAM_ID:-}" ] && [ -f Config/Local.xcconfig ]; then
    TEAM_ID="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig | head -1)"
  fi
  if [ -z "${TEAM_ID:-}" ]; then
    echo "Team ID が分かりません。TEAM_ID を指定するか Config/Local.xcconfig に DEVELOPMENT_TEAM を書いてください。" >&2
    exit 1
  fi

  xcodebuild -project Tansu.xcodeproj -scheme Tansu -configuration Release -derivedDataPath "$WORK/build" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    -quiet build
  APP="$WORK/build/Build/Products/Release/Tansu.app"
fi

codesign --verify --strict --verbose=2 "$APP"

# DMGもアプリと同じ証明書で署名する。
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
codesign --display --extract-certificates="$WORK/signer" "$APP"
SIGNER=$(shasum -a 1 "$WORK/signer0" | awk '{print $1}')

PACKAGE="$WORK/package"
DMG="$WORK/Tansu.dmg"
mkdir "$PACKAGE"
ditto "$APP" "$PACKAGE/Tansu.app"
ln -s /Applications "$PACKAGE/Applications"
cp LICENSE "$PACKAGE/LICENSE"
hdiutil create -quiet -srcfolder "$PACKAGE" -volname Tansu -fs HFS+ -format UDZO "$DMG"
codesign --sign "$SIGNER" --timestamp --identifier "$BUNDLE_ID.dmg" "$DMG"

NOTARY_PROFILE="${NOTARY_PROFILE:-tansu-notary}"
RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr)
if ! grep -q "status: Accepted" <<<"$RESULT"; then
  ID=$(sed -n 's/^ *id: //p' <<<"$RESULT" | head -1)
  echo "公証に失敗しました。理由: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
mv "$DMG" "$RELEASE_DIR/Tansu.dmg"
echo "完成: $RELEASE_DIR/Tansu.dmg"
