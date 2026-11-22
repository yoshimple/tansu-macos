# Tansu 開発ガイド

## ビルドと実行

ビルドにはXcode 16以降が必要です。外部のSwiftパッケージを追加する必要はありません。

```bash
xcodebuild -project Tansu.xcodeproj -scheme Tansu -configuration Debug -derivedDataPath build build
```

```bash
open build/Build/Products/Debug/Tansu.app
```

Xcode で開く場合は `Tansu.xcodeproj` を開いて実行（Cmd+R）します。

単体テスト（ファイル操作、ドロップ判定、ZIP、AI 連携のロジック）:

```bash
xcodebuild -project Tansu.xcodeproj -scheme Tansu -configuration Debug -derivedDataPath build test
```

### ローカルビルドの署名

**ビルドし直すたびに許可を尋ねられる場合**
初期設定ではローカル実行用の署名（ad-hoc）でビルドされます。この署名はビルドのたびに変わるため、macOS は別のアプリとみなして許可を尋ね直します。
自分の Apple ID（無料アカウントでも可）で署名すると、許可が残るようになります。

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

`Config/Local.xcconfig` の `DEVELOPMENT_TEAM` を自分の Team ID に書き換えます。Team ID は「Xcode > Settings > Accounts」で確認できます。このファイルは `.gitignore` に入っているので、リポジトリには含まれません。

## フォルダ構成

```
Tansu.xcodeproj     手書きの Xcode プロジェクト（フォルダと自動同期するので、ファイルの追加時に編集は不要）
Tansu/
  App/              起動、メニューバー、ウィンドウ、キー操作
  Models/           タブ・ウィンドウ・ナビゲーションウィンドウの状態、ファイル操作の呼び出し
  Services/         FileOps（コピー・移動・ゴミ箱・名前変更）、ZIP、Spotlight、タグ、ボリューム、表示先の切り替え
  Views/            タブバー、アドレスバー、コマンドバー、ファイル一覧、プレビュー、右クリックメニュー
  AI/               AI 連携（設定ファイル、Git、AI 用コピー、ツリー、機密ファイル判定）
  Support/          表示文字列、配色、メニューの補助
  Localizable.xcstrings   英語訳
TansuTests/         単体テスト
Scripts/            check-strings.py（英語訳の漏れ検査）
```

- 外枠（タブバー、ナビゲーション行、コマンドバー、ナビゲーションウィンドウ、ステータスバー、プレビュー）は SwiftUI です
- ファイル一覧は AppKit です。詳細表示は NSTableView、大アイコン表示と一覧表示は NSCollectionView を使います。1 万件を超えるフォルダ、列幅の変更、その場での名前変更、ドラッグ＆ドロップを確実に扱うためです

### 表示文字列

画面の文言は、コード中に `L("日本語")` の形で書きます。英語訳は `Tansu/Localizable.xcstrings` に登録します。
文言を追加・変更したら、英語訳の漏れを次のコマンドで確かめます。

```bash
python3 Scripts/check-strings.py
```

## 配布（Developer ID 署名と公証）

App Store 外での直接配布を前提にしています。App Sandbox は使いません。
開発中はローカル実行用の署名（ad-hoc）でビルドされます。配布する場合は、Developer ID で署名して公証します。

事前に次の 2 つを用意します。

- キーチェーンに「Developer ID Application」証明書（秘密鍵つき）。作れるのはチームの Account Holder だけです。
- 公証用の認証情報（アプリ用パスワードを使います）

```bash
xcrun notarytool store-credentials tansu-notary --apple-id "YOUR_APPLE_ID" --team-id "YOUR_TEAM_ID"
```

用意ができたら、次のスクリプトでビルド、署名、公証、staple までを行い、`build/release/Tansu-<バージョン>.zip` を作ります。
Team ID は環境変数 `TEAM_ID`、なければ `Config/Local.xcconfig` の `DEVELOPMENT_TEAM` を使います。

```bash
Scripts/release.sh
```

Release 構成では Hardened Runtime を有効にしています。

## 将来の構想

Apple 純正の端末内 AI（Foundation Models framework、macOS 26 以降）を使って、次の機能を追加する予定です。初回リリースには含めていません。

- 画像内の文字による検索（Vision）
- プレビューウィンドウでの PDF・文書の要約
- 中身に合ったファイル名の提案（提案のみ。自動では変更しない）
- 自然言語でのファイル検索

追加するときは `Tansu/AI/` に置き、`if #available(macOS 26, *)` で機能の表示を切り替えます。
表示の入口は、右クリックメニューの「AI」サブメニュー（`WindowModel+AI.swift`）とプレビューウィンドウ（`PreviewPane.swift`）の 2 か所です。
