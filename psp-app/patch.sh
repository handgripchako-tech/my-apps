#!/bin/bash
# PPSSPP のソースを Galaxy S26 向けに調整する（引数: PPSSPP のソースのルート）
# どの sed も「当たらなかったらビルドを失敗させる」ようにしてある
set -e
cd "$1"
chk() { grep -q "$2" "$1" || { echo "パッチ失敗: $1 に $2 がない"; exit 1; }; }

C=Core/Config.cpp
# 内部解像度の既定を 4倍（約1080p）に。Android は通常 2倍
sed -i 's#int scale = longestDisplaySide >= 1000 ? 2 : 1;#int scale = longestDisplaySide >= 1000 ? 4 : 1;#' $C
chk $C 'longestDisplaySide >= 1000 ? 4 : 1'
# 熱で性能が落ちにくい「持続性能モード」を既定でオン
sed -i 's#"SustainedPerformanceMode", SETTING(g_Config, bSustainedPerformanceMode), false#"SustainedPerformanceMode", SETTING(g_Config, bSustainedPerformanceMode), true#' $C
chk $C 'bSustainedPerformanceMode), true'
# 遅い設定の警告を出さない
sed -i 's#"HideSlowWarnings", SETTING(g_Config, bHideSlowWarnings), false#"HideSlowWarnings", SETTING(g_Config, bHideSlowWarnings), true#' $C
chk $C 'bHideSlowWarnings), true'

G=android/build.gradle.kts
# arm64 だけビルド（ビルド時間とAPKサイズを減らす）
sed -i 's#abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a", "x86_64"))#abiFilters.addAll(listOf("arm64-v8a"))#' $G
chk $G 'abiFilters.addAll(listOf("arm64-v8a"))'
# 公式PPSSPPと併存できるよう、アプリIDを変える（normal 版のみ）
sed -i '0,/applicationId = "org.ppsspp.ppsspp"$/! s#^\(\s*\)applicationId = "org.ppsspp.ppsspp"$#\1applicationId = "jp.chako.psp"#' $G
echo "パッチ適用OK"
