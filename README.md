# my-apps

自作Androidアプリ置き場（公開）。GitHub Actions でAPKをビルドし、Releases（`<名前>-latest`）に置く。

- 署名鍵はリポジトリに置かない。シークレット `SIGN_RELEASE` / `SIGN_DEBUG` / `SIGN_PC98DISK`（base64）からビルド時に復元する（`.github/actions/restore-key`）
- ビルド通知: シークレット `NTFY_TOPIC`
- ゲームのデータを含むアプリは非公開リポジトリ側に残す
