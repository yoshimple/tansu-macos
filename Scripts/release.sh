#!/bin/bash
# 配布用の Tansu.app を作る。Developer ID で署名し、公証して、zip にまとめる。
#
# 事前に必要なもの:
#   - キーチェーンに「Developer ID Application」証明書（秘密鍵つき）
#   - 公証用の認証情報: xcrun notarytool store-credentials tansu-notary --apple-id <Apple ID> --team-id <Team ID>
#
# Team ID は環境変数 TEAM_ID、なければ Config/Local.xcconfig の DEVELOPMENT_TEAM を使う。
# 公証の認証情報の名前は環境変数 NOTARY_PROFILE（既定は tansu-notary）。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -z "${TEAM_ID:-}" ] && [ -f Config/Local.xcconfig ]; then
  TEAM_ID="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig | head -1)"
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-tansu-notary}"
if [ -z "${TEAM_ID:-}" ]; then
  echo "Team ID が分かりません。TEAM_ID を指定するか Config/Local.xcconfig に DEVELOPMENT_TEAM を書いてください。" >&2
  exit 1
fi

DERIVED=build/release
APP="$DERIVED/Build/Products/Release/Tansu.app"

rm -rf "$DERIVED"
xcodebuild -project Tansu.xcodeproj -scheme Tansu -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -quiet build

VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
ZIP="$DERIVED/Tansu-$VERSION.zip"
SUBMISSION="$DERIVED/notarization.zip"

codesign --verify --strict --verbose=2 "$APP"

# 公証に出すための zip（staple 前）
ditto -c -k --keepParent "$APP" "$SUBMISSION"
# notarytool は公証に失敗しても終了コード 0 を返すので、結果を見て判定する
RESULT=$(xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr)
if ! grep -q "status: Accepted" <<<"$RESULT"; then
  ID=$(sed -n 's/^ *id: //p' <<<"$RESULT" | head -1)
  echo "公証に失敗しました。理由: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi

# 公証チケットを付け、アプリとライセンスを配布用 ZIP にまとめる
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"

PACKAGE="$DERIVED/package"
mkdir "$PACKAGE"
ditto "$APP" "$PACKAGE/Tansu.app"
cp LICENSE "$PACKAGE/LICENSE"
ditto -c -k "$PACKAGE" "$ZIP"
rm "$SUBMISSION"
echo "完成: $ZIP"
