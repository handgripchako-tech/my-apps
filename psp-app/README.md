# psp-app
公式 PPSSPP（hrydgard/ppsspp、GPLv2）を、Galaxy S26 向けの初期設定にしてビルドするだけの置き場。
ソースは持たず、GitHub Actions が公式の固定タグを取得して patch.sh を当てる。
- 変更点: 内部解像度4倍、持続性能モード、遅い設定の警告オフ、arm64のみ、アプリID jp.chako.psp
- 上げるとき: .github/workflows/build-psp-app.yml の PPSSPP_REF を変える
