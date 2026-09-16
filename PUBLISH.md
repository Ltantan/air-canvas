# GitHub公開手順

このディレクトリは、claude-lab本体とは別のGitリポジトリです。

1. GitHubで空の `Ltantan/air-canvas` リポジトリを作る（READMEやLicenseは追加しない）。
2. このディレクトリで `git add . && git commit -m "Prepare Air Canvas 1.0"` を実行する。
3. `git remote add origin git@github.com:Ltantan/air-canvas.git` を設定し、`git push -u origin main` する。
4. GitHubのSettings → Pagesで、Deploy from a branch、`main`、`/docs` を選ぶ。
5. Pagesの公開後、`docs/privacy-policy` と `docs/support` のURLをブラウザで開き、プレースホルダーの運営者名・連絡先が残っていないことを確認する。
6. App Store ConnectのPrivacy Policy URLとSupport URLへ入力する。

App Store用のBundle IDと署名チームは、公開repoの `com.example.aircanvas` から、自分のApp Store Connectで登録した値へ変更する。

この作業にはGitHubアカウントへのログイン、リポジトリ作成、外部公開が含まれるため、ここでは実行していません。
