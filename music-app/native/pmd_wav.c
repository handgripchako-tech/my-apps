/*
 * pmd_wav.c - pmdmini を使って PMD ファイルを WAV に書き出す薄いラッパー。
 * Dart FFI から pmd_to_wav() を1回呼ぶだけの作り。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "pmdmini/pmdmini.h"

#if defined(__GNUC__)
#define PMDW_EXPORT __attribute__((visibility("default")))
#else
#define PMDW_EXPORT
#endif

#define BLOCK 512 /* 1回に作るサンプル数(左右で1サンプル) */

static void put_u32(unsigned char *p, uint32_t v) {
    p[0] = v & 255; p[1] = (v >> 8) & 255; p[2] = (v >> 16) & 255; p[3] = (v >> 24) & 255;
}
static void put_u16(unsigned char *p, uint16_t v) {
    p[0] = v & 255; p[1] = (v >> 8) & 255;
}

static void write_header(FILE *fp, uint32_t rate, uint32_t data_bytes) {
    unsigned char h[44];
    memcpy(h, "RIFF", 4);          put_u32(h + 4, 36 + data_bytes);
    memcpy(h + 8, "WAVEfmt ", 8);  put_u32(h + 16, 16);
    put_u16(h + 20, 1);            put_u16(h + 22, 2);
    put_u32(h + 24, rate);         put_u32(h + 28, rate * 4);
    put_u16(h + 32, 4);            put_u16(h + 34, 16);
    memcpy(h + 36, "data", 4);     put_u32(h + 40, data_bytes);
    fwrite(h, 1, 44, fp);
}

/*
 * PMD を WAV(16bit/ステレオ)に変換する。
 *   pmd_path : PMDファイル
 *   pcm_dir  : 音色ファイル(.PPC/.P86等)の追加探索フォルダ(NULL可)
 *   wav_path : 出力WAV
 *   rate     : サンプリング周波数(例 44100)
 *   loops    : ループを含めた演奏回数(1=ループなし相当, 2=1周繰り返す)
 *   fade_sec : ループ曲の最後にかけるフェードアウト秒数
 *   title/compo : 曲名・作曲者(Shift-JISのまま)。NULL可。各 256 バイト以上
 * 戻り値: 0=成功, 1=PMDとして開けない, 2=書き出し失敗
 */
PMDW_EXPORT
int pmd_to_wav(const char *pmd_path, const char *pcm_dir, const char *wav_path,
               int rate, int loops, int fade_sec, char *title, char *compo) {
    static char cur[] = "./"; /* 空文字だとpmdwinが探索を打ち切るため */
    char dirbuf[2048];
    short buf[BLOCK * 2];
    FILE *fp;
    int len_sec, loop_sec, total_sec, fade_start_sample;
    long long total, done = 0;
    uint32_t data_bytes;

    if (rate < 8000) rate = 44100;
    if (loops < 1) loops = 1;
    if (fade_sec < 0) fade_sec = 0;

    pmd_init();
    pmd_setrate(rate);

    if (pcm_dir && pcm_dir[0]) {
        strncpy(dirbuf, pcm_dir, sizeof(dirbuf) - 1);
        dirbuf[sizeof(dirbuf) - 1] = 0;
    } else {
        dirbuf[0] = 0;
    }
    if (pmd_play(pmd_path, dirbuf[0] ? dirbuf : cur) != 0) return 1;

    if (title) { title[0] = 0; pmd_get_title(title); title[255] = 0; }
    if (compo) { compo[0] = 0; pmd_get_compo(compo); compo[255] = 0; }

    len_sec = pmd_length_sec();
    loop_sec = pmd_loop_sec();
    if (len_sec <= 0) { len_sec = 120; loop_sec = 0; } /* 長さ不明のとき */

    if (loop_sec > 0) {
        total_sec = len_sec + loop_sec * (loops - 1) + fade_sec;
    } else {
        total_sec = len_sec + 1; /* ループ無し曲は余韻だけ足す */
        fade_sec = 0;
    }
    total = (long long)total_sec * rate;
    fade_start_sample = (int)((long long)(total_sec - fade_sec) * rate);

    fp = fopen(wav_path, "wb");
    if (!fp) { pmd_stop(); return 2; }
    write_header(fp, rate, 0);

    while (done < total) {
        int n = BLOCK, i;
        if (total - done < n) n = (int)(total - done);
        memset(buf, 0, sizeof(buf));
        pmd_renderer(buf, n);
        if (fade_sec > 0 && done + n > fade_start_sample) {
            long long fade_len = (long long)fade_sec * rate;
            for (i = 0; i < n; i++) {
                long long pos = done + i - fade_start_sample;
                double g = 1.0;
                if (pos > 0) g = 1.0 - (double)pos / (double)fade_len;
                if (g < 0) g = 0;
                buf[i * 2] = (short)(buf[i * 2] * g);
                buf[i * 2 + 1] = (short)(buf[i * 2 + 1] * g);
            }
        }
        /* 16bit リトルエンディアンで書く(ARMもx86もそのまま) */
        if (fwrite(buf, 4, n, fp) != (size_t)n) { fclose(fp); pmd_stop(); return 2; }
        done += n;
    }

    data_bytes = (uint32_t)(done * 4);
    fseek(fp, 0, SEEK_SET);
    write_header(fp, rate, data_bytes);
    fclose(fp);
    pmd_stop();
    return 0;
}

/* 曲の長さ(秒)だけ知りたいとき用。失敗は -1 */
PMDW_EXPORT
int pmd_probe(const char *pmd_path, const char *pcm_dir, char *title, char *compo) {
    static char cur[] = "./";
    char dirbuf[2048];
    int len;
    pmd_init();
    pmd_setrate(44100);
    if (pcm_dir && pcm_dir[0]) {
        strncpy(dirbuf, pcm_dir, sizeof(dirbuf) - 1);
        dirbuf[sizeof(dirbuf) - 1] = 0;
    } else dirbuf[0] = 0;
    if (pmd_play(pmd_path, dirbuf[0] ? dirbuf : cur) != 0) return -1;
    if (title) { title[0] = 0; pmd_get_title(title); title[255] = 0; }
    if (compo) { compo[0] = 0; pmd_get_compo(compo); compo[255] = 0; }
    len = pmd_length_sec();
    pmd_stop();
    return len;
}
