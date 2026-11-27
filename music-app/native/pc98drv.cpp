/*
 * pc98drv.cpp - ゲームに入っている「本物の音楽ドライバ」を小さな PC-98 もどきで動かし、
 * 音源チップ(OPNA)への書き込みを fmgen で鳴らして WAV にする。
 *
 * いま対応しているドライバ:
 *   - WM : "MUSIC DRIVER Version 0.38a By Pirorin/Witch2" (MUSIC.COM, silky's 作品など)
 *          INT 60h で操作。AX=80h で曲置き場を受け取り、曲を写して AX=100h で演奏開始。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <vector>
#include <string>
#include "opna.h"
#include "x86emu.h"

#if defined(__GNUC__)
#define DRV_EXPORT extern "C" __attribute__((visibility("default")))
#else
#define DRV_EXPORT extern "C"
#endif

namespace {

const unsigned int OPNA_CLOCK = 7987200;

class Chip : public FM::OPNA {
public:
    bool irq = false;
    void Intr(bool f) override { irq = f; }
};

struct Machine {
    X86 cpu;
    Chip *opna = nullptr;
    uint8_t addr0 = 0, addr1 = 0;
    uint8_t mask_m = 0x00, mask_s = 0x00;   // PIC の割り込みマスク
    bool exited = false;                    // TSR / 終了 した
    uint16_t next_free = 0x3000;            // DOS のメモリ確保用（段落）
    long writes = 0;                        // 音源への書き込み数（確認用）
    bool silent = false;                    // true なら音は作らない（長さを測るとき）
    // この割り込み1回分の「鍵盤を押した/離した」書き込みの指紋。
    // 音色の揺れ（LFO）などは時間でずれるので入れない
    uint64_t h = 1469598103934665603ULL;
    long keys = 0;
    void mixh(uint32_t v) { h ^= v; h *= 1099511628211ULL; }

    static uint8_t s_in(void *u, uint16_t p) { return ((Machine *)u)->in(p); }
    static void s_out(void *u, uint16_t p, uint8_t v) { ((Machine *)u)->out(p, v); }
    static bool s_int(void *u, X86 &c, uint8_t n) { return ((Machine *)u)->hostint(c, n); }

    Machine() {
        cpu.user = this;
        cpu.inb = s_in;
        cpu.outb = s_out;
        cpu.hostint = s_int;
    }

    uint8_t in(uint16_t p) {
        switch (p) {
            case 0x188: return opna ? (opna->ReadStatus() & 0x7F) : 0;
            case 0x18A: return addr0 == 0xFF ? 1 : (opna ? opna->GetReg(addr0) : 0);
            case 0x18C: return opna ? (opna->ReadStatusEx() & 0x7F) : 0;
            case 0x18E: return opna ? opna->GetReg(0x100 | addr1) : 0;
            case 0x02: return mask_m;
            case 0x0A: return mask_s;
            case 0x00: case 0x08: return 0;
            default: return 0xFF;
        }
    }

    void out(uint16_t p, uint8_t v) {
        switch (p) {
            case 0x188: addr0 = v; break;
            case 0x18A:
                writes++;
                if (addr0 == 0x28 || addr0 == 0x10 || addr0 <= 0x07) { mixh((addr0 << 8) | v); keys++; }
                if (opna) opna->SetReg(addr0, v);
                break;
            case 0x18C: addr1 = v; break;
            case 0x18E:
                writes++;
                if (opna) opna->SetReg(0x100 | addr1, v);
                break;
            case 0x02: mask_m = v; break;
            case 0x0A: mask_s = v; break;
            default: break;
        }
    }

    // ゲスト側で割り込みが用意されていないものだけ、ここで処理する
    bool hostint(X86 &c, uint8_t n) {
        uint16_t off = c.rw(n * 4), seg = c.rw(n * 4 + 2);
        if (off || seg) return false;
        if (n == 0x21) dos(c);
        // それ以外（BIOS など）は何もしない
        return true;
    }

    void setcf(X86 &c, bool v) {
        // INT から戻るときの FLAGS は積まれていないので CF をそのまま
        c.setflags((c.flags() & ~1) | (v ? 1 : 0));
    }

    void dos(X86 &c) {
        uint8_t ah = c.r[0] >> 8;
        switch (ah) {
            case 0x09: case 0x02: case 0x06: break;
            case 0x25: {   // 割り込みベクタ設定
                uint8_t n = c.r[0] & 0xFF;
                c.ww(n * 4, c.r[2]);
                c.ww(n * 4 + 2, c.sreg[3]);
                break;
            }
            case 0x35: {   // 割り込みベクタ取得
                uint8_t n = c.r[0] & 0xFF;
                c.r[3] = c.rw(n * 4);
                c.sreg[0] = c.rw(n * 4 + 2);
                break;
            }
            case 0x30: c.r[0] = 0x0005; break;
            case 0x31: case 0x4C: case 0x00:
                exited = true; c.halted = true; break;
            case 0x48: {   // メモリ確保
                uint16_t n = c.r[3];
                c.r[0] = next_free; next_free += n + 1;
                setcf(c, false);
                break;
            }
            case 0x49: case 0x4A: setcf(c, false); break;
            case 0x3D: case 0x3C: setcf(c, true); c.r[0] = 2; break;   // ファイルは無い
            default: setcf(c, false); break;
        }
    }

    // COM を seg:0100 に置いて、常駐するまで動かす
    bool loadCom(const uint8_t *d, int len, uint16_t seg) {
        if (len <= 0 || len > 0xFF00) return false;
        uint32_t base = X86::lin(seg, 0);
        memset(cpu.mem + base, 0, 0x100);
        cpu.wb(base, 0xCD); cpu.wb(base + 1, 0x20);
        cpu.ww(base + 2, 0x9FFF);
        cpu.ww(base + 0x2C, 0);   // 環境変数なし
        memcpy(cpu.mem + base + 0x100, d, len);
        cpu.sreg[0] = cpu.sreg[1] = cpu.sreg[2] = cpu.sreg[3] = seg;
        cpu.r[4] = 0xFFFE;
        cpu.ww(X86::lin(seg, 0xFFFE), 0);
        cpu.ip = 0x100;
        cpu.halted = false;
        exited = false;
        cpu.run(50000000);
        cpu.halted = false;
        return exited && !cpu.fault;
    }

    // 呼び出し用のスタックを用意
    void prepStack() {
        cpu.sreg[2] = 0x9000;
        cpu.r[4] = 0xFFF0;
    }

    bool int60(uint16_t ax, uint16_t bx = 0) {
        prepStack();
        cpu.r[0] = ax; cpu.r[3] = bx;
        cpu.sreg[3] = cpu.sreg[0] = 0x8000;
        return cpu.callint(0x60);
    }

    // 音源のタイマー割り込み (INT 14h = IRQ12)
    // 割り込みを1回処理したら true。そのときの指紋は last_h に入る
    uint64_t last_h = 0;
    bool tick() {
        if (!opna || !opna->irq) return false;
        if (mask_s & 0x10) return false;
        prepStack();
        cpu.sreg[3] = cpu.sreg[0] = 0x8000;
        h = 1469598103934665603ULL;
        cpu.callint(0x14, 2000000);
        last_h = h;
        return true;
    }
};

void write_header(FILE *fp, int rate, uint32_t bytes) {
    uint8_t h[44];
    memcpy(h, "RIFF", 4);
    uint32_t v = 36 + bytes; memcpy(h + 4, &v, 4);
    memcpy(h + 8, "WAVEfmt ", 8);
    v = 16; memcpy(h + 16, &v, 4);
    uint16_t s = 1; memcpy(h + 20, &s, 2);
    s = 2; memcpy(h + 22, &s, 2);
    v = rate; memcpy(h + 24, &v, 4);
    v = rate * 4; memcpy(h + 28, &v, 4);
    s = 4; memcpy(h + 32, &s, 2);
    s = 16; memcpy(h + 34, &s, 2);
    memcpy(h + 36, "data", 4);
    memcpy(h + 40, &bytes, 4);
    fwrite(h, 1, 44, fp);
}

bool read_all(const char *path, std::vector<uint8_t> &out) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return false;
    fseek(fp, 0, SEEK_END);
    long n = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (n <= 0 || n > 4 * 1024 * 1024) { fclose(fp); return false; }
    out.resize(n);
    bool ok = fread(&out[0], 1, n, fp) == (size_t)n;
    fclose(fp);
    return ok;
}

// 曲を音源の時間で進める。us だけ進めて、その間の音を out に足す
void advance(Machine &m, long long &acc, int rate, int32_t us, std::vector<int32_t> &mix, int &ns) {
    acc += (long long)us * rate;
    ns = (int)(acc / 1000000);
    acc %= 1000000;
    if (ns > 0 && !m.silent) {
        mix.assign((size_t)ns * 2, 0);
        m.opna->Mix(&mix[0], ns);
    }
    m.opna->Count(us);
}


// 指定のドライバで曲を鳴らし始める
bool start_wm(Machine &m, const std::vector<uint8_t> &drv, const std::vector<uint8_t> &song,
              const char *pcm_dir, int rate) {
    m.opna = new Chip();
    char dir[2048] = {0};
    if (pcm_dir && pcm_dir[0]) {
        strncpy(dir, pcm_dir, sizeof(dir) - 2);
        size_t l = strlen(dir);
        if (dir[l - 1] != '/') { dir[l] = '/'; dir[l + 1] = 0; }
    }
    if (!m.opna->Init(OPNA_CLOCK, rate, false, dir[0] ? dir : "./")) return false;
    if (!m.loadCom(&drv[0], (int)drv.size(), 0x1000)) return false;
    // 演奏中なら止める → 曲置き場をもらう → 写す → 演奏
    m.int60(0xFE);
    if ((m.cpu.r[0] & 0xFF) != 0) m.int60(0x00);
    if (!m.int60(0x80)) return false;
    uint32_t dst = X86::lin(m.cpu.sreg[0], m.cpu.r[0]);
    size_t n = song.size();
    if (n > 0x2000) n = 0x2000;
    memcpy(m.cpu.mem + dst, &song[0], n);
    return m.int60(0x100);
}

struct Length {
    double intro = 0;     // ループが始まるまで（秒）
    double loop = 0;      // 1ループの長さ（秒）。0 ならループしない
    double end = 0;       // ループしない曲の終わり（秒）
};

// 音を作らずに進めて、曲の長さを測る。
// 割り込みごとの書き込みの指紋を並べ、同じ並びがもう一度出てきたらそこがループ。
Length measure(const std::vector<uint8_t> &drv, const std::vector<uint8_t> &song, const char *pcm_dir) {
    Length L;
    Machine m;
    m.silent = true;
    if (!start_wm(m, drv, song, pcm_dir, 44100)) { delete m.opna; return L; }
    const double MAX_SEC = 900;
    const int W = 24;    // この数の割り込みが続けて一致したら同じ所とみなす
    std::vector<uint64_t> hs;
    std::vector<double> ts;
    double t = 0, last_sound = 0;
    long long acc = 0;
    std::vector<int32_t> mix;
    // 窓の指紋 → 最初に出た位置
    std::vector<std::pair<uint64_t, int>> seen;
    std::vector<int> table(1 << 20, -1);
    int cand_d = 0, cand_start = 0, cand_until = 0;
    while (t < MAX_SEC) {
        int32_t us = m.opna->GetNextEvent();
        if (us <= 0 || us > 5000) us = 5000;
        int ns;
        advance(m, acc, 44100, us, mix, ns);
        t += us / 1e6;
        long before = m.keys;
        if (!m.tick()) continue;
        if (m.cpu.fault) break;
        if (m.keys == before) {
            if (t - last_sound > 8 && last_sound > 0) { L.end = last_sound; break; }
            if (t > 30 && last_sound == 0) break;
            continue;
        }
        last_sound = t;
        hs.push_back(m.last_h);
        ts.push_back(t);
        int k = (int)hs.size();
        if (k < W) continue;
        uint64_t w = 1469598103934665603ULL;
        for (int i = k - W; i < k; i++) { w ^= hs[i]; w *= 1099511628211ULL; }
        // 候補を確かめ中: 1周分ずっと同じなら本物のループ
        if (cand_d > 0) {
            double dt = (ts[k - 1] - ts[k - 1 - cand_d]) - (ts[cand_start + cand_d] - ts[cand_start]);
            if (hs[k - 1] != hs[k - 1 - cand_d] || dt > 0.05 || dt < -0.05) {
#ifdef PC98DRV_TEST
                fprintf(stderr, "cancel d=%d (%.2fs) at %.2f after %.2f\n", cand_d, ts[k-1]-ts[k-1-cand_d], ts[k-1], ts[k-1]-ts[cand_start+cand_d]);
#endif
                cand_d = 0;
            } else if (k - 1 >= cand_until && ts[k - 1] - ts[cand_start + cand_d] >= 25) {
                int s0 = cand_start;
                double per = ts[s0 + cand_d] - ts[s0];
                while (s0 > 0 && hs[s0 - 1] == hs[s0 - 1 + cand_d] &&
                       ts[s0 - 1 + cand_d] - ts[s0 - 1] - per < 0.05 && ts[s0 - 1 + cand_d] - ts[s0 - 1] - per > -0.05) s0--;
                double start = ts[s0];
                L.intro = start > 0.3 ? start - 0.3 : 0;
                L.loop = ts[s0 + cand_d] - ts[s0];
                delete m.opna;
                return L;
            }
        }
        int slot = (int)(w & ((1 << 20) - 1));
        while (table[slot] >= 0) {
            int j = table[slot];
            bool same = true;
            for (int i = 0; i < W; i++) if (hs[j - W + 1 + i] != hs[k - W + i]) { same = false; break; }
            if (same) {
                int d = (k - 1) - j;
                if (cand_d == 0 && ts[k - 1] - ts[j] > 3) {
                    cand_d = d;
                    cand_start = j - W + 1;
                    cand_until = k - 1 + d;   // もう1周分ようすを見る
                }
                break;
            }
            slot = (slot + 1) & ((1 << 20) - 1);
        }
        if (table[slot] < 0) table[slot] = k - 1;
    }
    if (L.end <= 0) L.end = t;
    delete m.opna;
    return L;
}

int render(const std::vector<uint8_t> &drv, const std::vector<uint8_t> &song, const char *pcm_dir,
           const char *wav_path, int rate, double seconds, double fade_sec) {
    Machine m;
    if (!start_wm(m, drv, song, pcm_dir, rate)) { delete m.opna; return 1; }
    FILE *fp = fopen(wav_path, "wb");
    if (!fp) { delete m.opna; return 2; }
    write_header(fp, rate, 0);

    long long total = (long long)(seconds * rate);
    long long written = 0, acc = 0;
    long long fade_from = total - (long long)(fade_sec * rate);
    std::vector<int32_t> mix;
    std::vector<int16_t> pcm;
    while (written < total) {
        int32_t us = m.opna->GetNextEvent();
        if (us <= 0 || us > 5000) us = 5000;
        int ns = 0;
        advance(m, acc, rate, us, mix, ns);
        if (ns > 0) {
            if (written + ns > total) ns = (int)(total - written);
            pcm.resize((size_t)ns * 2);
            for (int i = 0; i < ns; i++) {
                double g = 1.0;
                long long tt = written + i;
                if (fade_sec > 0 && tt > fade_from) g = 1.0 - (double)(tt - fade_from) / (fade_sec * rate);
                if (g < 0) g = 0;
                for (int ch = 0; ch < 2; ch++) {
                    int v = (int)(mix[i * 2 + ch] * 6 / 10 * g);
                    if (v > 32767) v = 32767;
                    if (v < -32768) v = -32768;
                    pcm[i * 2 + ch] = (int16_t)v;
                }
            }
            fwrite(&pcm[0], 4, ns, fp);
            written += ns;
        }
        m.tick();
        if (m.cpu.fault) break;
    }
    fseek(fp, 0, SEEK_SET);
    write_header(fp, rate, (uint32_t)(written * 4));
    fclose(fp);
#ifdef PC98DRV_TEST
    fprintf(stderr, "writes=%ld steps=%ld fault=%d %s\n", m.writes, m.cpu.steps, m.cpu.fault, m.cpu.err);
#endif
    int rc = m.cpu.fault ? 1 : 0;
    delete m.opna;
    return rc;
}

// 書き出す長さ（秒）と、フェードするかを決める
double plan(const Length &L, int loops, int fade_sec, double &fade) {
    if (L.loop > 0) {
        fade = fade_sec;
        return L.intro + L.loop * loops + fade_sec;
    }
    fade = 0;
    double e = L.end > 0 ? L.end + 2 : 180;
    if (e > 600) e = 600;
    return e;
}

std::string drv_dir_file(const char *pcm_dir, const char *name) {
    std::string d = pcm_dir ? pcm_dir : "";
    if (!d.empty() && d.back() != '/') d += '/';
    return d + name;
}

bool load_driver(const char *pcm_dir, std::vector<uint8_t> &drv) {
    const char *names[] = {"MUSIC.COM", "music.com", "Music.com"};
    for (const char *n : names) if (read_all(drv_dir_file(pcm_dir, n).c_str(), drv)) return true;
    return false;
}

} // namespace

/*
 * WM（silky's などの MUSIC.COM 用の曲）
 * ドライバ MUSIC.COM は pcm_dir（音色ファイル置き場）に置いておく。
 * pmd_to_wav と同じ引数。戻り値 0=成功 1=読めない/ドライバが無い 2=書き出せない
 */
DRV_EXPORT int wm_probe(const char *path, const char *pcm_dir, char *title, char *compo) {
    std::vector<uint8_t> drv, song;
    if (title) title[0] = 0;
    if (compo) compo[0] = 0;
    if (!load_driver(pcm_dir, drv) || !read_all(path, song)) return -1;
    Length L = measure(drv, song, pcm_dir);
    double f;
    double s = plan(L, 2, 6, f);
    if (L.loop <= 0 && L.end <= 0.5) return -1;
    return (int)(s + 0.5);
}

DRV_EXPORT int wm_to_wav(const char *path, const char *pcm_dir, const char *wav_path,
                         int rate, int loops, int fade_sec, char *title, char *compo) {
    std::vector<uint8_t> drv, song;
    if (title) title[0] = 0;
    if (compo) compo[0] = 0;
    if (!load_driver(pcm_dir, drv) || !read_all(path, song)) return 1;
    if (rate < 8000) rate = 44100;
    if (loops < 1) loops = 1;
    if (fade_sec < 0) fade_sec = 0;
    Length L = measure(drv, song, pcm_dir);
    double fade;
    double sec = plan(L, loops, fade_sec, fade);
#ifdef PC98DRV_TEST
    fprintf(stderr, "intro=%.2f loop=%.2f end=%.2f -> %.1fs\n", L.intro, L.loop, L.end, sec);
#endif
    return render(drv, song, pcm_dir, wav_path, rate, sec, fade);
}

#ifdef PC98DRV_TEST
int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s libdir song.wm out.wav\n", argv[0]); return 1; }
    int rc = wm_to_wav(argv[2], argv[1], argv[3], 44100, 2, 6, nullptr, nullptr);
    fprintf(stderr, "rc=%d\n", rc);
    return rc;
}
#endif
