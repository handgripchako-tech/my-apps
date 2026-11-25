/*
 * mdrv2.cpp - 東方靈異伝などの MDRV2 (.MDT) を fmgen の OPNA で鳴らして WAV にする。
 * 既存の pmdwav.so に同居させる(外部公開は mdt_to_wav / mdt_probe)。
 *
 * 形式の解釈は公開されている解析情報と、実ファイルの観察による推定を含む。
 * 音量・テンポ・SSGエンベロープ等は「それらしく」鳴る近似で、実機と完全一致はしない。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <vector>
#include "opna.h"

#if defined(__GNUC__)
#define MDT_EXPORT extern "C" __attribute__((visibility("default")))
#else
#define MDT_EXPORT extern "C"
#endif

namespace {

const unsigned int OPNA_CLOCK = 7987200;
const double TICKS_PER_BEAT = 48.0;   /* 4分音符 = 48クロック (全音符192) */
const int FM_VOL_OFFSET = 8;          /* MDRV98.COM の既定値 (MDP の -CF) */
const int RHY_VOL_OFFSET = 8;         /* 同 -CR */
const double TEMPO_SCALE = 1.0;       /* t の値を BPM とみなす倍率。違和感があればここで調整 */

struct Song {
    std::vector<uint8_t> d;
    int nch = 0, chip = 0;
    struct Def { int loc; int id; };
    std::vector<Def> defs;
    int fm_loc = 0, ssg_loc = 0, title_loc = 0;
    uint16_t u16(size_t p) const { return p + 1 < d.size() ? (uint16_t)(d[p] | (d[p + 1] << 8)) : 0; }
    int u8(size_t p) const { return p < d.size() ? d[p] : 0xFF; }
};

bool parse_song(Song &s) {
    if (s.d.size() < 16) return false;
    s.nch = s.u16(2);
    s.chip = s.u16(4);
    if (s.nch < 1 || s.nch > 32 || s.chip != 1) return false;
    size_t p = 6;
    for (int i = 0; i < s.nch; i++, p += 4) {
        Song::Def df;
        df.loc = s.u16(p);
        df.id = s.u16(p + 2);
        if (df.id != 0) {
            if (df.loc >= (int)s.d.size()) return false;
            s.defs.push_back(df);
        }
    }
    s.fm_loc = s.u16(p);
    s.ssg_loc = s.u16(p + 2);
    s.title_loc = s.u16(p + 4);
    if (s.defs.empty()) return false;
    if (s.fm_loc > (int)s.d.size() || s.ssg_loc > (int)s.d.size()) return false;
    return true;
}

/* 各コマンドのオペランド長(ループの先読み用) */
int oplen(const Song &s, int op, bool rhythm, int pos) {
    if (op < 0x80) return 1;
    switch (op) {
    case 0x90: return 1;
    case 0x91: return 0;
    case 0xE0: return 1;
    case 0xE1: case 0xE2: case 0xE3: return 0;
    case 0xE4: return 1;
    case 0xE5: return 0;
    case 0xE6: case 0xE7: return 1;
    case 0xE8: return 4;
    case 0xE9: case 0xEA: case 0xEB: return 1;
    case 0xEC: if (rhythm) return (s.u8(pos) & 0x80) ? 2 : 7; return 1;
    case 0xED: return 4;
    case 0xEE: return 2;
    case 0xEF: case 0xF0: return 1;
    case 0xF1: return rhythm ? 2 : 1;
    case 0xF2: return 4;
    case 0xF3: return 2;
    case 0xF4: case 0xF5: return 1;
    case 0xF6: return 3;
    case 0xF7: return 3;
    case 0xF8: return 1;
    case 0xF9: return 2;
    case 0xFA: return 2;
    case 0xFB: case 0xFC: case 0xFD: return 4;
    default: return 0;
    }
}

struct Loop { int kind; int start; int count; };

struct Chan {
    int id = 0, type = 0; /* 0=FM 1=SSG 2=RHYTHM */
    int idx = 0;          /* FM: 0..5, SSG: 0..2 */
    int pos = 0;
    bool active = true, ended = false;
    int loops_done = 0;
    int wait = 0;         /* 残りクロック */
    int gate_at = -1;     /* 何クロック目でキーオフ */
    int elapsed = 0;
    bool keyed = false, tie_in = false;
    int note = 0;         /* 現在の音 (midi番号ベース) */
    int q = 8;
    int vol = 100;        /* FM:0-127 / SSG:0-15 */
    int detune = 0, transpose = 0;
    int inst = 0;
    int pan = 3;
    bool tone = true, noise = false;
    int rmask = 0;
    std::vector<Loop> loop;
    std::vector<int> ret;
    /* SSG エンベロープ状態 */
    int env = 0; double envlevel = 1.0; bool releasing = false;
    /* 実機と同じ SSG エンベロープ: level 0-255, phase 0=アタック 1=ディケイ 2=サスティン 3=リリース 4=停止 */
    int sl = 0, sph = 4;
    /* F2 (ポルタメント付き音符): FM の F-number を毎クロック足す */
    bool sliding = false; int slide_v = 0, slide_rate = 0;
};

struct Engine {
    Song *s;
    FM::OPNA *opna;
    std::vector<Chan> ch;
    double tempo = 75;
    int rate = 44100;
    uint8_t ssg_mix = 0x3F;
    int noise_freq = 16;
    bool silent;

    void reg(int a, int v) { if (!silent) opna->SetReg(a, v); }

    /* ---- 音程 ---- */
    static double midi_freq(double m) { return 440.0 * pow(2.0, (m - 69.0) / 12.0); }

    void fm_pitch(Chan &c, int note, int detune) {
        /* 実機: ブロック=オクターブ、F-number は 12音のテーブル。detune はそのF-numberに足す */
        static const int tab[12] = {0x26a, 0x28f, 0x2b6, 0x2df, 0x30b, 0x339, 0x36a, 0x39e, 0x3d5, 0x410, 0x44e, 0x48f};
        int blk = note / 12 - 1;
        if (blk < 0) blk = 0; if (blk > 7) blk = 7;
        int fn = tab[((note % 12) + 12) % 12];
        fn += detune;
        if (fn < 1) fn = 1; if (fn > 2047) fn = 2047;
        c.slide_v = (blk << 11) | fn;
        fm_write(c, c.slide_v);
    }

    /* v = ブロック(3bit)<<11 | F-number(11bit) をそのままレジスタへ */
    void fm_write(Chan &c, int v) {
        v &= 0x3FFF;
        int ofs = (c.idx % 3) + (c.idx >= 3 ? 0x100 : 0);
        reg(0xA4 + ofs, v >> 8);
        reg(0xA0 + ofs, v & 0xFF);
    }

    static int ch_slotbits(int idx) { return idx < 3 ? idx : idx + 1; }

    void fm_key(Chan &c, bool on) {
        reg(0x28, (on ? 0xF0 : 0x00) | ch_slotbits(c.idx));
    }

    /* 音色 + 音量(TL)の書き込み */
    void fm_setinst(Chan &c) {
        const Song &S = *s;
        int n = (S.ssg_loc - S.fm_loc) / 32;
        if (c.inst < 0 || c.inst >= n) return;
        const uint8_t *p = &S.d[S.fm_loc + c.inst * 32];
        int ofs = (c.idx % 3) + (c.idx >= 3 ? 0x100 : 0);
        int af = p[4] & 0x3F;
        int alg = af & 7, fb = af >> 3;
        int pan = p[4] >> 6;
        c.pan = pan;
        int lr = (pan == 0) ? 0xC0 : (pan == 1 ? 0x80 : (pan == 2 ? 0x40 : 0xC0));
        reg(0xB0 + ofs, (fb << 3) | alg);
        reg(0xB4 + ofs, lr | ((p[5] & 0x0F) << 4) | ((p[5] >> 4) & 7));
        static const int slotofs[4] = {0, 8, 4, 12}; /* ファイル順 op1..4 → OPNAスロット */
        for (int k = 0; k < 4; k++) {
            int so = slotofs[k] + ofs;
            int b6 = p[6 + k];
            int dt = (b6 >= 0x80) ? ((0x140 - b6) >> 4) : (b6 >> 4);
            reg(0x30 + so, ((dt & 7) << 4) | (b6 & 0x0F));
            reg(0x50 + so, ((p[14 + k] >> 6) << 6) | (p[14 + k] & 0x1F));
            reg(0x60 + so, ((p[18 + k] >> 7) << 7) | (p[18 + k] & 0x1F));
            reg(0x70 + so, p[22 + k] & 0x1F);
            reg(0x80 + so, ((p[26 + k] >> 4) << 4) | (p[26 + k] & 0x0F));
        }
        fm_setvol(c);
    }

    void fm_setvol(Chan &c) {
        const Song &S = *s;
        int n = (S.ssg_loc - S.fm_loc) / 32;
        if (c.inst < 0 || c.inst >= n) return;
        const uint8_t *p = &S.d[S.fm_loc + c.inst * 32];
        int alg = p[4] & 7;
        static const int carrier[8] = {0x8, 0x8, 0x8, 0x8, 0xA, 0xE, 0xE, 0xF}; /* bit k = file op k */
        int ofs = (c.idx % 3) + (c.idx >= 3 ? 0x100 : 0);
        static const int slotofs[4] = {0, 8, 4, 12};
        int v = c.vol - FM_VOL_OFFSET; if (v < 0) v = 0; if (v > 127) v = 127;  /* 実機の既定: 音量値から8を引く */
        for (int k = 0; k < 4; k++) {
            int tl = p[10 + k];
            if (carrier[alg] & (1 << k)) tl += (127 - v);
            if (tl > 127) tl = 127;
            reg(0x40 + slotofs[k] + ofs, tl);
        }
    }

    /* ---- SSG ---- */
    void ssg_pitch(Chan &c, int note, int detune) {
        double f = midi_freq(note);
        int tp = (int)(OPNA_CLOCK / 4.0 / (16.0 * f) + 0.5) - detune;
        if (tp < 1) tp = 1; if (tp > 4095) tp = 4095;
        reg(c.idx * 2, tp & 0xFF);
        reg(c.idx * 2 + 1, tp >> 8);
    }
    void ssg_mixer(Chan &c) {
        int b = c.idx;
        ssg_mix |= (1 << b) | (8 << b);
        if (c.tone) ssg_mix &= ~(1 << b);
        if (c.noise) ssg_mix &= ~(8 << b);
        reg(7, ssg_mix);
    }
    void ssg_amp(Chan &c) {
        /* 実機: 音量レジスタ = (エンベロープ段階 * 音量) / 256 */
        int a = (c.sl * c.vol) >> 8;
        if (a < 0) a = 0; if (a > 15) a = 15;
        reg(8 + c.idx, a);
    }

    /* SSGエンベロープ1つ分(6バイト): 初期値,アタック,ディケイ,サスティン位置,サスティン減衰,リリース */
    void ssg_env_params(const Chan &c, int b[6]) {
        const Song &S = *s;
        int ne = (int)(S.d.size() - S.ssg_loc) / 6;
        if (c.env >= ne) { b[0] = 255; b[1] = 255; b[2] = 255; b[3] = 255; b[4] = 0; b[5] = 255; return; }
        for (int i = 0; i < 6; i++) b[i] = S.d[S.ssg_loc + c.env * 6 + i];
    }

    /* ---- ノートオン/オフ ---- */
    void note_on(Chan &c, int nbyte) {
        int o = nbyte >> 4, n = nbyte & 0x0F;
        int midi = 12 * (o + 1) + n + c.transpose;
        if (c.type == 0) {
            if (!(c.tie_in && c.keyed)) {
                if (c.keyed) fm_key(c, false);
                fm_pitch(c, midi, c.detune);
                fm_key(c, true);
            } else fm_pitch(c, midi, c.detune);
        } else if (c.type == 1) {
            ssg_pitch(c, midi, c.detune);
            if (!(c.tie_in && c.keyed)) { int b[6]; ssg_env_params(c, b); c.sl = b[0]; c.sph = 0; c.releasing = false; }
            ssg_mixer(c);
        }
        c.note = midi;
        c.keyed = true;
        if (c.type == 1) ssg_amp(c);
    }
    void note_off(Chan &c) {
        if (!c.keyed) return;
        if (c.type == 0) fm_key(c, false);
        else if (c.type == 1) { c.releasing = true; if (c.sph != 4) c.sph = 3; }
        c.keyed = false;
        if (c.type == 1) ssg_amp(c);
    }

    /* ---- ループの先読み ---- */
    /* pos から始めて、深さ0のときの終端コマンド(endop)の次の位置を返す。openop/closeop が入れ子 */
    int scan_loop_end(int pos, bool rhythm, int openA, int closeA, int openB, int closeB) {
        int depth = 0;
        int p = pos;
        int n = (int)s->d.size();
        while (p < n) {
            int op = s->d[p++];
            if (op == 0xFF) return p;
            if (op == openA || op == openB) depth++;
            else if (op == closeA || op == closeB) {
                if (depth == 0) return p + oplen(*s, op, rhythm, p);
                depth--;
            }
            p += oplen(*s, op, rhythm, p);
        }
        return n;
    }

    /* ---- 1チャンネルを1クロック進める ---- */
    void run_cmds(Chan &c) {
        const Song &S = *s;
        int guard = 0;
        while (c.active && c.wait == 0 && guard++ < 100000) {
            if (c.pos >= (int)S.d.size()) { c.active = false; c.ended = true; note_off(c); return; }
            int op = S.d[c.pos++];
            bool rh = (c.type == 2);
            if (op < 0x80) {
                c.sliding = false;
                int len = S.u8(c.pos++);
                if (len <= 0) len = 256;
                if (rh) {
                    if (c.rmask) reg(0x10, c.rmask & 0x3F);
                } else {
                    note_on(c, op);
                }
                c.tie_in = false;
                bool tie = false;
                if (S.u8(c.pos) == 0x91) { tie = true; c.pos++; }
                c.wait = len;
                c.elapsed = 0;
                c.gate_at = (tie || rh) ? -1 : (len * c.q / 8);
                if (!tie && !rh && c.q >= 8) c.gate_at = len;
                c.tie_in = tie;
                if (!rh) c.keyed = true;
                return;
            }
            switch (op) {
            case 0x90: { /* 休符 */
                c.sliding = false;
                int len = S.u8(c.pos++);
                if (len <= 0) len = 256;
                note_off(c);
                c.tie_in = false;
                if (S.u8(c.pos) == 0x91) c.pos++;
                c.wait = len; c.gate_at = -1; c.elapsed = 0;
                return; }
            case 0x91: break;
            case 0xE0: { Loop l = {0, c.pos + 1, S.u8(c.pos)}; c.pos++; c.loop.push_back(l); break; }
            case 0xE1: {
                if (!c.loop.empty() && c.loop.back().kind == 0 && c.loop.back().count <= 1) {
                    c.pos = scan_loop_end(c.pos, rh, 0xE0, 0xE2, 0xE0, 0xE2);
                    c.loop.pop_back();
                }
                break; }
            case 0xE2: {
                if (!c.loop.empty()) {
                    Loop &l = c.loop.back();
                    if (--l.count > 0) c.pos = l.start; else c.loop.pop_back();
                }
                break; }
            case 0xE3: note_off(c); break;
            case 0xE4: { Loop l = {1, c.pos + 1, S.u8(c.pos)}; c.pos++; c.loop.push_back(l); break; }
            case 0xE5: {
                if (!c.loop.empty()) {
                    Loop &l = c.loop.back();
                    if (--l.count > 0) c.pos = l.start; else c.loop.pop_back();
                }
                break; }
            case 0xE6: c.detune = (int8_t)S.u8(c.pos++); break;
            case 0xE7: c.transpose = (int8_t)S.u8(c.pos++); break;
            case 0xE9: tempo = S.u8(c.pos++); if (tempo < 1) tempo = 1; break;
            case 0xEA: c.q = S.u8(c.pos++); if (c.q > 8) c.q = 8; break;
            case 0xEB: {
                int v = S.u8(c.pos++);
                if (c.type == 0) { c.inst = v; fm_setinst(c); }
                else if (c.type == 1) {
                    c.env = v & 0x3F; c.tone = !(v & 0x40); c.noise = !(v & 0x80);
                    ssg_mixer(c);
                } else c.rmask = v;
                break; }
            case 0xEC: {
                if (rh) {
                    int f = S.u8(c.pos++);
                    if (f & 0x80) {
                        int i = f & 0x7F, lv = S.u8(c.pos++);
                        if (i < 6) reg(0x18 + i, 0xC0 | (lv & 0x1F));
                    } else {
                        { int tl = (f & 0x3F) - RHY_VOL_OFFSET; if (tl < 0) tl = 0; reg(0x11, tl + 1); }
                        for (int i = 0; i < 6; i++) reg(0x18 + i, 0xC0 | (S.u8(c.pos++) & 0x1F));
                    }
                } else if (c.type == 1) { c.vol = S.u8(c.pos++); ssg_amp(c); }
                else { c.vol = S.u8(c.pos++); fm_setvol(c); }
                break; }
            case 0xEF: {
                int v = S.u8(c.pos++);
                if (c.type == 1) { noise_freq = v & 0x1F; reg(6, noise_freq); }
                break; }
            case 0xF2: { /* ポルタメント付き音符: 音程, 長さ, 1クロックあたりの音程変化(16bit) */
                int nb = S.u8(c.pos++);
                int len = S.u8(c.pos++);
                int rate = (int16_t)S.u16(c.pos); c.pos += 2;
                if (len <= 0) len = 256;
                if (rh) { c.wait = len; c.gate_at = -1; c.elapsed = 0; return; }
                c.tie_in = false;
                note_on(c, nb);
                if (c.type == 0) { c.sliding = true; c.slide_rate = rate / 4; } /* 実機は FM だけ 1/4 */
                c.wait = len; c.elapsed = 0; c.gate_at = len;
                return; }
            case 0xF3: {
                int off = (int16_t)S.u16(c.pos);
                int target = c.pos + 1 + off; /* 実機: オフセット先頭の次のバイトが基準 */
                c.loops_done++;
                c.loop.clear(); c.ret.clear();
                if (target < 0 || target >= (int)S.d.size()) { c.active = false; c.ended = true; return; }
                c.pos = target;
                break; }
            case 0xF4: if (c.type == 0) { c.vol += S.u8(c.pos++); if (c.vol > 127) c.vol = 127; fm_setvol(c); }
                       else { c.vol += S.u8(c.pos++); if (c.vol > 15) c.vol = 15; } break;
            case 0xF5: if (c.type == 0) { c.vol -= S.u8(c.pos++); if (c.vol < 0) c.vol = 0; fm_setvol(c); }
                       else { c.vol -= S.u8(c.pos++); if (c.vol < 0) c.vol = 0; } break;
            case 0xF6: { Loop l = {2, c.pos + 3, S.u8(c.pos)}; c.pos += 3; c.loop.push_back(l); break; }
            case 0xF7: {
                c.pos += 3;
                if (!c.loop.empty()) {
                    Loop &l = c.loop.back();
                    if (--l.count > 0) c.pos = l.start; else c.loop.pop_back();
                }
                break; }
            case 0xF9: {
                c.pos += 2;
                if (!c.loop.empty() && c.loop.back().kind == 2 && c.loop.back().count <= 1) {
                    c.pos = scan_loop_end(c.pos, rh, 0xF6, 0xF7, 0xF6, 0xF7);
                    c.loop.pop_back();
                }
                break; }
            case 0xFA: {
                int tgt = S.u16(c.pos); c.pos += 2;
                if (tgt > 0 && tgt < (int)S.d.size() && c.ret.size() < 16) { c.ret.push_back(c.pos); c.pos = tgt; }
                break; }
            case 0xFF:
                if (!c.ret.empty()) { c.pos = c.ret.back(); c.ret.pop_back(); }
                else { c.active = false; c.ended = true; note_off(c); return; }
                break;
            default: /* 未対応(LFO, ポルタメント, フェード, パン等)は読み飛ばし */
                c.pos += oplen(S, op, rh, c.pos);
                break;
            }
        }
    }

    void ssg_env_tick(Chan &c) {
        if (c.sph < 4) {
            int b[6]; ssg_env_params(c, b);
            int lv = c.sl;
            bool end = false;
            switch (c.sph) {
            case 0: lv += b[1]; if (lv >= 255) { lv = 255; end = true; } break;
            case 1: lv -= b[2]; if (lv <= b[3]) { lv = b[3]; end = true; } break;
            case 2: lv -= b[4]; if (lv <= 0) { lv = 0; end = true; } break;
            case 3: lv -= b[5]; if (lv <= 0) { lv = 0; end = true; } break;
            }
            c.sl = lv;
            if (end) {
                if (lv == 0 || c.sph == 3) c.sph = 4;   /* 0 になったら、またはリリース終了で停止 */
                else c.sph++;
            }
        }
        ssg_amp(c);
    }

    void tick(Chan &c) {
        if (!c.active) {
            if (c.type == 1) ssg_env_tick(c);
            return;
        }
        if (c.wait == 0) run_cmds(c);
        if (c.sliding && c.type == 0 && c.keyed) {
            c.slide_v += c.slide_rate;
            fm_write(c, c.slide_v);
        }
        if (c.wait > 0) {
            c.elapsed++;
            if (c.gate_at >= 0 && c.elapsed == c.gate_at && c.gate_at < c.wait) note_off(c);
            c.wait--;
            if (c.wait == 0 && c.gate_at == c.elapsed && c.gate_at >= 0) { /* 次の音で再発音 */ }
        }
        if (c.type == 1) ssg_env_tick(c);
    }
};

void put_u32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
void put_u16(unsigned char *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
void write_header(FILE *fp, uint32_t rate, uint32_t bytes) {
    unsigned char h[44];
    memcpy(h, "RIFF", 4); put_u32(h + 4, 36 + bytes);
    memcpy(h + 8, "WAVEfmt ", 8); put_u32(h + 16, 16);
    put_u16(h + 20, 1); put_u16(h + 22, 2);
    put_u32(h + 24, rate); put_u32(h + 28, rate * 4);
    put_u16(h + 32, 4); put_u16(h + 34, 16);
    memcpy(h + 36, "data", 4); put_u32(h + 40, bytes);
    fwrite(h, 1, 44, fp);
}

bool load_file(const char *path, Song &s) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return false;
    fseek(fp, 0, SEEK_END);
    long n = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (n < 16 || n > 1 << 20) { fclose(fp); return false; }
    s.d.resize(n);
    size_t r = fread(&s.d[0], 1, n, fp);
    fclose(fp);
    return (long)r == n;
}

void copy_title(const Song &s, char *title, char *compo) {
    if (title) title[0] = 0;
    if (compo) compo[0] = 0;
    if (!title) return;
    int p = s.title_loc;
    int n = 0;
    while (p < (int)s.d.size() && s.d[p] != '$' && n < 250) {
        title[n++] = (char)s.d[p++];
    }
    title[n] = 0;
    /* 末尾の空白(半角/全角)を落とす: 全角空白は 81 40 */
    while (n > 0) {
        if (title[n - 1] == ' ') title[--n] = 0;
        else if (n >= 2 && (uint8_t)title[n - 2] == 0x81 && (uint8_t)title[n - 1] == 0x40) { n -= 2; title[n] = 0; }
        else break;
    }
}

void setup_channels(Engine &e) {
    for (size_t i = 0; i < e.s->defs.size(); i++) {
        const Song::Def &df = e.s->defs[i];
        Chan c;
        c.id = df.id;
        c.pos = df.loc;
        if (df.id & 0x80) { c.type = 0; c.idx = df.id & 7; if (c.idx > 5) continue; c.vol = 100; }
        else if (df.id & 0x40) { c.type = 1; c.idx = df.id & 3; if (c.idx > 2) continue; c.vol = 12; }
        else if (df.id & 0x10) { c.type = 2; }
        else continue;
        e.ch.push_back(c);
    }
}

/* mode: 0=WAV出力 1=長さ測定のみ */
int run(const char *path, const char *pcm_dir, const char *wav_path, int rate, int loops,
        int fade_sec, char *title, char *compo, int measure_only, int *out_len) {
    Song s;
    if (!load_file(path, s) || !parse_song(s)) return 1;
    copy_title(s, title, compo);
    if (rate < 8000) rate = 44100;
    if (loops < 1) loops = 1;
    if (fade_sec < 0) fade_sec = 0;

    Engine e;
    e.s = &s; e.rate = rate; e.silent = measure_only != 0;
    FM::OPNA *opna = nullptr;
    if (!measure_only) {
        opna = new FM::OPNA();
        char dir[2048] = {0};
        if (pcm_dir && pcm_dir[0]) { strncpy(dir, pcm_dir, sizeof(dir) - 2); size_t l = strlen(dir); if (dir[l - 1] != '/') { dir[l] = '/'; dir[l + 1] = 0; } }
        if (!opna->Init(OPNA_CLOCK, rate, false, dir[0] ? dir : "./")) { delete opna; return 1; }
        opna->SetReg(0x29, 0x80);
        opna->SetReg(7, 0x3F);
        opna->SetReg(0x11, 0x3F);
        for (int i = 0; i < 6; i++) opna->SetReg(0x18 + i, 0xDF);
    }
    e.opna = opna;
    setup_channels(e);

    FILE *fp = nullptr;
    if (!measure_only) {
        fp = fopen(wav_path, "wb");
        if (!fp) { delete opna; return 2; }
        write_header(fp, rate, 0);
    }

    const double MAX_SEC = 900.0;
    double elapsed = 0;               /* 秒 */
    double samp_acc = 0;
    long long written = 0;
    bool finished = false;
    double fade_start = -1;
    std::vector<int32_t> mixbuf;
    std::vector<int16_t> outbuf;
    long long total_limit = -1;

    while (elapsed < MAX_SEC) {
        /* 1クロック分 */
        for (size_t i = 0; i < e.ch.size(); i++) e.tick(e.ch[i]);
        double spt = (double)rate * 60.0 / (e.tempo * TEMPO_SCALE * TICKS_PER_BEAT);
        samp_acc += spt;
        int ns = (int)samp_acc;
        samp_acc -= ns;
        elapsed += spt / rate;

        if (!measure_only && ns > 0) {
            mixbuf.assign((size_t)ns * 2, 0);
            opna->Mix(&mixbuf[0], ns);
            outbuf.resize((size_t)ns * 2);
            for (int i = 0; i < ns * 2; i++) {
                int v = mixbuf[i] * 6 / 10;
                if (v > 32767) v = 32767; if (v < -32768) v = -32768;
                outbuf[i] = (int16_t)v;
            }
            if (fade_start >= 0) {
                for (int i = 0; i < ns; i++) {
                    double t = (double)(written + i) / rate - fade_start;
                    double g = 1.0 - t / fade_sec; if (g < 0) g = 0; if (g > 1) g = 1;
                    outbuf[i * 2] = (int16_t)(outbuf[i * 2] * g);
                    outbuf[i * 2 + 1] = (int16_t)(outbuf[i * 2 + 1] * g);
                }
            }
            fwrite(&outbuf[0], 4, ns, fp);
            written += ns;
        } else if (measure_only) {
            written += ns;
        }

        if (!finished) {
            bool all = true; bool any_loop = false;
            for (size_t i = 0; i < e.ch.size(); i++) {
                Chan &c = e.ch[i];
                if (c.ended) continue;
                if (c.loops_done >= loops) { any_loop = true; continue; }
                all = false;
            }
            if (all) {
                finished = true;
                bool looped = false;
                for (size_t i = 0; i < e.ch.size(); i++) if (e.ch[i].loops_done > 0) looped = true;
                (void)any_loop;
                if (looped && fade_sec > 0) { fade_start = (double)written / rate; total_limit = written + (long long)fade_sec * rate; }
                else total_limit = written + (long long)rate * 2; /* 余韻 */
                if (measure_only && out_len) { *out_len = (int)(elapsed + (looped ? fade_sec : 2)); }
            }
        }
        if (finished && written >= total_limit) break;
    }
    if (measure_only && !finished && out_len) *out_len = (int)elapsed;

    if (fp) {
        uint32_t bytes = (uint32_t)(written * 4);
        fseek(fp, 0, SEEK_SET);
        write_header(fp, rate, bytes);
        fclose(fp);
    }
    delete opna;
    return 0;
}

} /* namespace */

/* MDTを一度だけ頭から数えて曲の長さ(秒)を返す。失敗は -1 */
MDT_EXPORT int mdt_probe(const char *path, const char *pcm_dir, char *title, char *compo) {
    int len = 0;
    if (run(path, pcm_dir, nullptr, 44100, 2, 6, title, compo, 1, &len) != 0) return -1;
    return len;
}

/* pmd_to_wav と同じ引数。戻り値 0=成功 1=開けない 2=書き出し失敗 */
MDT_EXPORT int mdt_to_wav(const char *path, const char *pcm_dir, const char *wav_path,
                          int rate, int loops, int fade_sec, char *title, char *compo) {
    return run(path, pcm_dir, wav_path, rate, loops, fade_sec, title, compo, 0, nullptr);
}
