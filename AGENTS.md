# Air Canvas 開発ルール

このフォルダは、App Store公開用のAir Canvas独立リポジトリです。変更はこのアプリの範囲に限定し、親のclaude-labや子供向け試作版を参照・変更しません。

## アプリの目的

背面カメラでARKitの3D空間に線を描き、描いた線と端末の動きから推定した人形を再生する。作品は端末内に保存し、絵＋人形を無音の縦MP4として共有できます。

人形は身体の実測や骨格認識ではありません。端末姿勢から生成する推定表現です。この説明をUIやストア文面から削除しないでください。

## 実行方法

1. `src/AirCanvas.xcodeproj`をXcodeで開く。
2. App Store用のTeamとBundle Identifierを設定する。公開ソース側の`com.example.aircanvas`はサンプル値です。
3. ARKit対応の実機（iOS 18以降）で実行する。カメラ描画はシミュレータでは検証できません。
4. ホームの「描く」→「完成」→「動画」で一連の動作を確認する。

## 検証

変更後は最低限、次を実行する。

```sh
xcodebuild -project src/AirCanvas.xcodeproj -scheme AirCanvas -sdk iphoneos -configuration Debug -derivedDataPath /private/tmp/aircanvas-public-build CODE_SIGNING_ALLOWED=NO build
```

AR描画は実機で確認する。保存、アプリ再起動後の作品一覧、再生、人形ON/OFF、動画の生成と共有も確認する。Swiftソースを変更した場合は、既存の`src/Tests/ArtworkTests.swift`と`src/Tests/ReleaseTests.swift`も必要に応じて実行する。

## 保存・プライバシー

- カメラ画像と音声、顔や身体の骨格は保存しない。
- 保存するのは線の座標・色・時刻と端末の位置・向き。
- アカウント、広告、解析SDK、開発者サーバーへの送信はない。
- 作品や動画、署名ファイル、証明書、個人情報をGitへ追加しない。
- `credentials.json`、`token.json`、`.env`、`.p12`、`.mobileprovision`は絶対に読まない・コミットしない。
- 問い合わせ先は`sazabys044@gmail.com`。

ポリシーとサポートの原稿は`docs/privacy-policy.md`と`docs/support.md`にある。データの扱いを変えたら、コード・UI・この2ページ・README・App Store用説明を同時に更新する。

## Gitと公開

- 通常の作業は`main`へ行う。履歴を書き換えない。
- commitとpushは、ユーザーが依頼したときだけ行う。
- App Storeへ提出する前に、TestFlightで実機確認する。
- GitHub Pagesは`main`ブランチの`/docs`を公開元にする。
- Pagesの公開URLは通常、`https://ltantan.github.io/air-canvas/privacy-policy.html`と`https://ltantan.github.io/air-canvas/support.html`。
- ストア素材やアーカイブはこのリポジトリへ入れず、元のclaude-lab側の`data/`で管理する。

## 変更の判断

公開版の入口は一般向けの外カメラ体験です。子供向けUI、インカメラの笑顔撮影、別の作品管理方式をこのリポジトリへ戻さないでください。将来それを公開する場合は別ブランチまたは別リポジトリとして設計します。
