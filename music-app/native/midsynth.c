/*
 * midsynth.c - MIDI(.mid) と Libido7 の .MUS を SoundFont で WAV にする。
 *  - 音源: TinySoundFont (tsf/)。GS の音色バンク切替・ドラム(ch10)に対応
 *  - チャンネルごとに別々に鳴らして、GS と同じようにリバーブ/コーラスの送り量(CC91/CC93)を効かせる
 *  - SoundFont は音色ファイル置き場(pcm_dir)の *.sf2 を使う。
 *    利用者が入れたものがあればそちらを優先し、無ければ同梱の GeneralUser-GS.sf2
 * 外部公開: mid_probe / mid_to_wav / mus_probe / mus_to_wav （pmd_to_wav と同じ形）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <dirent.h>
#include <strings.h>

#define TSF_IMPLEMENTATION
#include "tsf/tsf.h"
#define TML_IMPLEMENTATION
#include "tsf/tml.h"

#if defined(__GNUC__)
#define MS_EXPORT __attribute__((visibility("default")))
#else
#define MS_EXPORT
#endif

#define NCH 16
#define BLOCK 64

/* ------------------------------------------------------------------ */
/* WAV                                                                 */
/* ------------------------------------------------------------------ */
static void put_u32(unsigned char *p, uint32_t v) { p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; }
static void put_u16(unsigned char *p, uint16_t v) { p[0]=v; p[1]=v>>8; }
static void wav_header(FILE *fp, uint32_t rate, uint32_t bytes) {
    unsigned char h[44];
    memcpy(h, "RIFF", 4); put_u32(h+4, 36+bytes);
    memcpy(h+8, "WAVEfmt ", 8); put_u32(h+16, 16);
    put_u16(h+20, 1); put_u16(h+22, 2); put_u32(h+24, rate); put_u32(h+28, rate*4);
    put_u16(h+32, 4); put_u16(h+34, 16);
    memcpy(h+36, "data", 4); put_u32(h+40, bytes);
    fseek(fp, 0, SEEK_SET); fwrite(h, 1, 44, fp);
}

/* ------------------------------------------------------------------ */
/* リバーブ (Freeverb) とコーラス                                      */
/* ------------------------------------------------------------------ */
typedef struct { float *b; int n, i; float fs; } comb_t;
typedef struct { float *b; int n, i; } ap_t;
static const int CT[8] = {1116,1188,1277,1356,1422,1491,1557,1617};
static const int AT[4] = {556,441,341,225};
typedef struct {
    comb_t cl[8], cr[8]; ap_t al[4], ar[4];
    float room, damp;
} reverb_t;

static void rv_init(reverb_t *r, int rate) {
    float k = rate / 44100.0f;
    int i;
    for (i = 0; i < 8; i++) {
        r->cl[i].n = (int)(CT[i]*k); r->cr[i].n = (int)((CT[i]+23)*k);
        r->cl[i].b = calloc(r->cl[i].n, sizeof(float)); r->cr[i].b = calloc(r->cr[i].n, sizeof(float));
        r->cl[i].i = r->cr[i].i = 0; r->cl[i].fs = r->cr[i].fs = 0;
    }
    for (i = 0; i < 4; i++) {
        r->al[i].n = (int)(AT[i]*k); r->ar[i].n = (int)((AT[i]+23)*k);
        r->al[i].b = calloc(r->al[i].n, sizeof(float)); r->ar[i].b = calloc(r->ar[i].n, sizeof(float));
        r->al[i].i = r->ar[i].i = 0;
    }
    r->room = 0.82f; r->damp = 0.35f;
}
static void rv_free(reverb_t *r) {
    int i;
    for (i = 0; i < 8; i++) { free(r->cl[i].b); free(r->cr[i].b); }
    for (i = 0; i < 4; i++) { free(r->al[i].b); free(r->ar[i].b); }
}
static inline float comb(comb_t *c, float in, float room, float damp) {
    float o = c->b[c->i];
    c->fs = o*(1-damp) + c->fs*damp;
    c->b[c->i] = in + c->fs*room;
    if (++c->i >= c->n) c->i = 0;
    return o;
}
static inline float allp(ap_t *a, float in) {
    float bo = a->b[a->i];
    float o = -in + bo;
    a->b[a->i] = in + bo*0.5f;
    if (++a->i >= a->n) a->i = 0;
    return o;
}
/* in: モノラル送り, out: ステレオに足し込む */
static void rv_run(reverb_t *r, const float *in, float *out, int n) {
    int s, i;
    for (s = 0; s < n; s++) {
        float x = in[s]*0.015f, l = 0, rr = 0;
        for (i = 0; i < 8; i++) { l += comb(&r->cl[i], x, r->room, r->damp); rr += comb(&r->cr[i], x, r->room, r->damp); }
        for (i = 0; i < 4; i++) { l = allp(&r->al[i], l); rr = allp(&r->ar[i], rr); }
        out[s*2]   += l*3.0f;
        out[s*2+1] += rr*3.0f;
    }
}

typedef struct { float *b; int n, i; float ph, inc, base, depth; } chorus_t;
static void ch_init(chorus_t *c, int rate) {
    c->n = rate / 10; c->b = calloc(c->n, sizeof(float)); c->i = 0;
    c->ph = 0; c->inc = 2*3.14159265f*0.45f/rate;
    c->base = rate*0.012f; c->depth = rate*0.004f;
}
static inline float ch_tap(chorus_t *c, float d) {
    float p = c->i - d; int a; float f;
    while (p < 0) p += c->n;
    a = (int)p; f = p - a;
    return c->b[a]*(1-f) + c->b[(a+1) % c->n]*f;
}
static void ch_run(chorus_t *c, const float *in, float *out, int n) {
    int s;
    for (s = 0; s < n; s++) {
        c->b[c->i] = in[s];
        out[s*2]   += ch_tap(c, c->base + c->depth*sinf(c->ph)) * 0.6f;
        out[s*2+1] += ch_tap(c, c->base + c->depth*cosf(c->ph)) * 0.6f;
        c->ph += c->inc; if (c->ph > 6.2831853f) c->ph -= 6.2831853f;
        if (++c->i >= c->n) c->i = 0;
    }
}

/* ------------------------------------------------------------------ */
/* SoundFont 探し                                                      */
/* ------------------------------------------------------------------ */
static int find_sf2(const char *dir, char *out, size_t outsz) {
    DIR *d; struct dirent *e; int found = 0;
    if (!dir || !*dir) return 0;
    d = opendir(dir);
    if (!d) return 0;
    while ((e = readdir(d))) {
        size_t L = strlen(e->d_name);
        if (L < 5 || strcasecmp(e->d_name + L - 4, ".sf2")) continue;
        /* 同梱品より、利用者が入れた SoundFont を優先 */
        if (strncasecmp(e->d_name, "GeneralUser", 11) == 0) {
            if (found) continue;
            snprintf(out, outsz, "%s/%s", dir, e->d_name); found = 1;
        } else {
            snprintf(out, outsz, "%s/%s", dir, e->d_name); found = 2;
            break;
        }
    }
    closedir(d);
    return found;
}

/* ------------------------------------------------------------------ */
/* Libido7 (KIN_BGM) .MUS → 標準MIDI                                    */
/* ------------------------------------------------------------------ */
typedef struct { uint32_t t; uint8_t b[3]; uint8_t n; } mev_t;
typedef struct { mev_t *v; int n, cap; } mvec_t;
static void mv_add(mvec_t *m, uint32_t t, int n, int b0, int b1, int b2) {
    if (m->n == m->cap) { m->cap = m->cap ? m->cap*2 : 256; m->v = realloc(m->v, m->cap*sizeof(mev_t)); }
    m->v[m->n].t = t; m->v[m->n].n = n; m->v[m->n].b[0] = b0; m->v[m->n].b[1] = b1; m->v[m->n].b[2] = b2;
    m->n++;
}
static const uint8_t VOLTAB[16] = {0x78,0x70,0x68,0x60,0x58,0x50,0x48,0x40,0x38,0x30,0x28,0x20,0x18,0x10,0x08,0x00};

typedef struct {
    const uint8_t *d; int len, pos, ch, att, gate, tie, ended, jumps;
    int snd[16], nsnd;
    int rep_cnt[16], rep_pos[16], nrep;
    int call[16], ncall;
    int tempo; int tempo_t;
    mvec_t ev;
} mtrk_t;

static int B(mtrk_t *k, int o) { return (k->pos + o < k->len) ? k->d[k->pos + o] : 0; }
static void m_offall(mtrk_t *k, uint32_t t) {
    int i;
    for (i = 0; i < k->nsnd; i++) mv_add(&k->ev, t, 3, 0x80 | k->ch, k->snd[i], 0);
    k->nsnd = 0;
}
/* end_tick まで(または max_jumps 回目のジャンプで)進める。戻り値=止まった時刻 */
static uint32_t m_run(mtrk_t *k, uint32_t end_tick, int max_jumps) {
    uint32_t t = 0; long steps = 0;
    while (t < end_tick && !k->ended) {
        int c;
        if (++steps > 400000 || k->pos >= k->len) { k->ended = 1; break; }
        c = k->d[k->pos++];
        if (c < 0x90) {
            int ln = B(k, 0), n = c & 15, tied = k->tie;
            k->pos++;
            if (n == 0) { m_offall(k, t); tied = 0; }
            else if (!tied) {
                int note = 11 + 12*(c >> 4) + n, vel = 0x7f - k->att;
                if (note > 127) note = 127;
                if (vel < 1) vel = 1;
                mv_add(&k->ev, t, 3, 0x90 | k->ch, note, vel);
                if (k->nsnd < 16) k->snd[k->nsnd++] = note;
            }
            if (ln == 0) continue;
            k->tie = 0;
            if (k->pos < k->len && k->d[k->pos] == 0xfd) { k->pos++; k->tie = 1; }
            if (!k->tie && k->nsnd) {
                int g = ((ln - 1) * k->gate) >> 8;
                m_offall(k, (g >= 1 && g <= ln - 2) ? t + g : t + ln);
            }
            t += ln;
            continue;
        }
        switch (c) {
        case 0xa0: mv_add(&k->ev, t, 3, 0xb0|k->ch, 7, B(k,0)&127); k->pos++; break;
        case 0xa1: mv_add(&k->ev, t, 3, 0xb0|k->ch, 10, B(k,0)&127); k->pos++; break;
        case 0xa2: mv_add(&k->ev, t, 3, 0xb0|k->ch, 64, B(k,0)&127); k->pos++; break;
        case 0xa4: mv_add(&k->ev, t, 3, 0xb0|k->ch, 91, B(k,0)&127);
                   mv_add(&k->ev, t, 3, 0xb0|k->ch, 93, B(k,1)&127); k->pos += 2; break;
        case 0xe0: k->att = k->att + 4 > 127 ? 127 : k->att + 4; break;
        case 0xe1: k->att = k->att - 4 < 0 ? 0 : k->att - 4; break;
        case 0xe2: k->pos++; break;
        case 0xe3: k->pos += 2; break;
        case 0xf0: if (k->tempo < 0) { k->tempo = B(k,0); k->tempo_t = t; } k->pos++; break;
        case 0xf1: { int v = B(k,0); k->pos++; k->att = v < 16 ? VOLTAB[v] : 0x7f - v; } break;
        case 0xf2: k->gate = B(k,0); k->pos++; break;
        case 0xf3: mv_add(&k->ev, t, 3, 0xb0|k->ch, B(k,0)&127, B(k,1)&127); k->pos += 2; break;
        case 0xf4: { int o = B(k,0) | (B(k,1) << 8);
                     k->jumps++;
                     if (k->jumps > max_jumps) goto done;
                     k->pos = o; } break;
        case 0xf5: while (k->pos < k->len && k->d[k->pos] != 0xfa) k->pos++; k->pos++; break;
        case 0xf6: k->ended = 1; break;
        case 0xf7: mv_add(&k->ev, t, 2, 0xc0|k->ch, B(k,0)&127, 0); k->pos++; break;
        case 0xf8: k->pos += 2; break;
        case 0xf9: if (k->nrep < 16) { k->rep_cnt[k->nrep] = B(k,0); k->rep_pos[k->nrep] = k->pos + 1; k->nrep++; }
                   k->pos++; break;
        case 0xfa: if (k->nrep) {
                       if (--k->rep_cnt[k->nrep-1] > 0) k->pos = k->rep_pos[k->nrep-1];
                       else k->nrep--;
                   } break;
        case 0xfb: { int o = B(k,0) | (B(k,1) << 8);
                     if (k->ncall < 16) k->call[k->ncall++] = k->pos + 2;
                     k->pos = o; } break;
        case 0xfc: if (k->ncall) k->pos = k->call[--k->ncall]; break;
        case 0xfd: break;
        case 0xfe: mv_add(&k->ev, t, 3, 0xe0|k->ch, 0, B(k,0)&127); k->pos++; break;
        case 0xff: m_offall(k, t); k->ch = B(k,0) & 15; k->pos++; break;
        default: break;
        }
    }
done:
    m_offall(k, t < end_tick ? t : end_tick);
    return t;
}
static void m_init(mtrk_t *k, const uint8_t *d, int len, int start) {
    memset(k, 0, sizeof(*k));
    k->d = d; k->len = len; k->pos = start; k->gate = 0xff; k->tempo = -1;
}

static int mus_header_ok(const uint8_t *d, int len) {
    int i, prev = 0x38;
    if (len < 0x40) return 0;
    for (i = 0; i < 14; i++) {
        int no = d[i*4], ofs = d[i*4+2] | (d[i*4+3] << 8);
        int want = i < 6 ? i + 1 : i - 5;
        if (no != want || ofs < prev || ofs >= len) return 0;
        prev = ofs;
    }
    return d[2] == 0x38 && d[3] == 0;
}

static int cmp_ev(const void *a, const void *b) {
    const mev_t *x = a, *y = b;
    if (x->t != y->t) return x->t < y->t ? -1 : 1;
    /* 同じ時刻なら、ノートオフ → その他 → ノートオン の順 */
    {
        int px = (x->b[0] & 0xf0) == 0x80 ? 0 : ((x->b[0] & 0xf0) == 0x90 ? 2 : 1);
        int py = (y->b[0] & 0xf0) == 0x80 ? 0 : ((y->b[0] & 0xf0) == 0x90 ? 2 : 1);
        return px - py;
    }
}
typedef struct { uint8_t *p; int n, cap; } buf_t;
static void bput(buf_t *b, const void *s, int n) {
    if (b->n + n > b->cap) { b->cap = (b->n + n) * 2 + 1024; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->n, s, n); b->n += n;
}
static void bvlq(buf_t *b, uint32_t v) {
    uint8_t t[5]; int n = 0, i;
    t[n++] = v & 127;
    while (v >>= 7) t[n++] = (v & 127) | 128;
    for (i = n - 1; i >= 0; i--) bput(b, &t[i], 1);
}
static void bu32be(buf_t *b, uint32_t v) { uint8_t t[4] = {v>>24, v>>16, v>>8, v}; bput(b, t, 4); }
static void bu16be(buf_t *b, uint32_t v) { uint8_t t[2] = {v>>8, v}; bput(b, t, 2); }

#define MUS_PPQ 24
#define MUS_TIMER_HZ (2457600.0 / 4500.0)

/* .MUS を SMF(メモリ)にする。*secs に曲の長さ(秒)。失敗で NULL */
static uint8_t *mus_to_smf(const uint8_t *d, int len, int loops, int *out_len, double *secs) {
    mtrk_t tr[8];
    uint32_t end = 0, cap = 60000;
    int i, any = 0, base_div = 10, div = -1;
    buf_t out = {0};
    if (!mus_header_ok(d, len)) return NULL;
    for (i = 0; i < 6; i++) {
        int o = d[i*4+2] | (d[i*4+3] << 8);
        if (o + 1 < len && d[o] == 0xf0) { base_div = d[o+1]; break; }
    }
    if (loops < 1) loops = 1;
    /* 1回目: 曲の終わり(ループ loops 回)を探す。ドラムの「ほぼ無限の繰り返し」は数えない */
    for (i = 0; i < 8; i++) {
        int o = d[(6+i)*4+2] | (d[(6+i)*4+3] << 8);
        uint32_t t;
        m_init(&tr[i], d, len, o);
        t = m_run(&tr[i], cap, loops - 1);
        if (tr[i].ended || tr[i].jumps >= loops) { if (t > end) end = t; any = 1; }
        if (tr[i].tempo >= 0 && div < 0) div = tr[i].tempo;
        free(tr[i].ev.v);
    }
    if (div < 0) div = base_div;
    if (!any) end = (uint32_t)(180 * MUS_TIMER_HZ / (div + 1));
    /* 2回目: 本番 */
    for (i = 0; i < 8; i++) {
        int o = d[(6+i)*4+2] | (d[(6+i)*4+3] << 8);
        m_init(&tr[i], d, len, o);
        m_run(&tr[i], end, 1 << 30);
    }
    bput(&out, "MThd", 4); bu32be(&out, 6); bu16be(&out, 1); bu16be(&out, 9); bu16be(&out, MUS_PPQ);
    /* テンポのトラック */
    {
        buf_t t = {0};
        uint32_t us = (uint32_t)(MUS_PPQ * (div + 1) / MUS_TIMER_HZ * 1e6 + 0.5);
        uint8_t tm[6] = {0xff, 0x51, 3, us >> 16, us >> 8, us};
        uint8_t eot[3] = {0xff, 0x2f, 0};
        bvlq(&t, 0); bput(&t, tm, 6);
        bvlq(&t, 0); bput(&t, eot, 3);
        bput(&out, "MTrk", 4); bu32be(&out, t.n); bput(&out, t.p, t.n); free(t.p);
    }
    for (i = 0; i < 8; i++) {
        buf_t t = {0};
        uint32_t last = 0; int j;
        uint8_t eot[3] = {0xff, 0x2f, 0};
        qsort(tr[i].ev.v, tr[i].ev.n, sizeof(mev_t), cmp_ev);
        for (j = 0; j < tr[i].ev.n; j++) {
            mev_t *e = &tr[i].ev.v[j];
            bvlq(&t, e->t - last); last = e->t;
            bput(&t, e->b, e->n);
        }
        bvlq(&t, 0); bput(&t, eot, 3);
        bput(&out, "MTrk", 4); bu32be(&out, t.n); bput(&out, t.p, t.n);
        free(t.p); free(tr[i].ev.v);
    }
    *out_len = out.n;
    *secs = end * (div + 1) / MUS_TIMER_HZ;
    return out.p;
}

static uint8_t *read_all(const char *path, int *len) {
    FILE *fp = fopen(path, "rb"); long n; uint8_t *p;
    if (!fp) return NULL;
    fseek(fp, 0, SEEK_END); n = ftell(fp); fseek(fp, 0, SEEK_SET);
    if (n <= 0 || n > 64*1024*1024) { fclose(fp); return NULL; }
    p = malloc(n);
    if (fread(p, 1, n, fp) != (size_t)n) { free(p); fclose(fp); return NULL; }
    fclose(fp); *len = (int)n; return p;
}

/* ------------------------------------------------------------------ */
/* 演奏して WAV に書く                                                  */
/* ------------------------------------------------------------------ */
static int render(tml_message *msgs, const char *sf2_dir, const char *wav_path,
                  int rate, int fade_sec, int fade_at_end) {
    char sfpath[2048];
    tsf *base, *f[NCH];
    float rsend[NCH], csend[NCH];
    float chbuf[BLOCK*2], mix[BLOCK*2], rin[BLOCK], cin[BLOCK];
    short pcm[BLOCK*2];
    reverb_t rv; chorus_t ch;
    unsigned int len_ms = 0;
    tml_message *m = msgs;
    FILE *fp;
    long long total, done = 0, fade_start, fade_len;
    uint32_t bytes = 0;
    int i;

    if (!find_sf2(sf2_dir, sfpath, sizeof sfpath)) return 3;
    base = tsf_load_filename(sfpath);
    if (!base) return 3;
    tml_get_info(msgs, NULL, NULL, NULL, NULL, &len_ms);
    if (rate < 8000) rate = 44100;
    for (i = 0; i < NCH; i++) {
        f[i] = i == 0 ? base : tsf_copy(base);
        tsf_set_output(f[i], TSF_STEREO_INTERLEAVED, rate, 0.0f);
        tsf_set_max_voices(f[i], 48);
        tsf_channel_set_presetnumber(f[i], i, 0, i == 9);
        tsf_channel_set_pitchrange(f[i], i, 2.0f);
        rsend[i] = 40 / 127.0f;   /* GS の初期値 */
        csend[i] = 0;
    }
    rv_init(&rv, rate); ch_init(&ch, rate);
    fp = fopen(wav_path, "wb");
    if (!fp) { for (i = NCH-1; i >= 0; i--) tsf_close(f[i]); rv_free(&rv); free(ch.b); return 2; }
    wav_header(fp, rate, 0);

    total = (long long)len_ms * rate / 1000;
    if (fade_at_end && fade_sec > 0) {
        fade_len = (long long)fade_sec * rate;
        if (fade_len > total / 3) fade_len = total / 3;
        fade_start = total - fade_len;
    } else {
        fade_len = 0; fade_start = total;
        total += rate * 2;    /* 余韻(リリース・リバーブ)のぶん */
    }

    while (done < total) {
        int n = BLOCK, s;
        double now_ms;
        if (total - done < n) n = (int)(total - done);
        now_ms = done * 1000.0 / rate;
        for (; m && m->time <= now_ms; m = m->next) {
            int c = m->channel & 15;
            switch (m->type) {
            case TML_PROGRAM_CHANGE: tsf_channel_set_presetnumber(f[c], c, m->program, c == 9); break;
            case TML_NOTE_ON:
                if (m->velocity) tsf_channel_note_on(f[c], c, m->key, m->velocity / 127.0f);
                else tsf_channel_note_off(f[c], c, m->key);
                break;
            case TML_NOTE_OFF: tsf_channel_note_off(f[c], c, m->key); break;
            case TML_PITCH_BEND: tsf_channel_set_pitchwheel(f[c], c, m->pitch_bend); break;
            case TML_CONTROL_CHANGE:
                if (m->control == 91) rsend[c] = m->control_value / 127.0f;
                else if (m->control == 93) csend[c] = m->control_value / 127.0f;
                else if (m->control == 121) {
                    tsf_channel_midi_control(f[c], c, 121, 0);
                } else tsf_channel_midi_control(f[c], c, m->control, m->control_value);
                break;
            }
        }
        memset(mix, 0, sizeof(float) * n * 2);
        memset(rin, 0, sizeof(float) * n);
        memset(cin, 0, sizeof(float) * n);
        for (i = 0; i < NCH; i++) {
            if (!tsf_active_voice_count(f[i])) continue;
            tsf_render_float(f[i], chbuf, n, 0);
            for (s = 0; s < n; s++) {
                float l = chbuf[s*2], r = chbuf[s*2+1], mono = (l + r) * 0.5f;
                mix[s*2] += l; mix[s*2+1] += r;
                rin[s] += mono * rsend[i];
                cin[s] += mono * csend[i];
            }
        }
        rv_run(&rv, rin, mix, n);
        ch_run(&ch, cin, mix, n);
        for (s = 0; s < n; s++) {
            float g = 0.5f;
            long long pos = done + s;
            if (pos >= fade_start && fade_len > 0) g *= 1.0f - (float)(pos - fade_start) / fade_len;
            for (i = 0; i < 2; i++) {
                float v = mix[s*2+i] * g;
                /* やわらかいリミッター */
                if (v > 0.8f) v = 0.8f + (1 - 0.8f) * tanhf((v - 0.8f) / (1 - 0.8f));
                else if (v < -0.8f) v = -0.8f - (1 - 0.8f) * tanhf((-v - 0.8f) / (1 - 0.8f));
                pcm[s*2+i] = (short)(v * 32767);
            }
        }
        fwrite(pcm, 4, n, fp);
        bytes += n * 4;
        done += n;
    }
    wav_header(fp, rate, bytes);
    fclose(fp);
    for (i = NCH-1; i >= 0; i--) tsf_close(f[i]);
    rv_free(&rv); free(ch.b);
    return 0;
}

static void set_str(char *dst, const char *s) { if (dst) { strncpy(dst, s, 255); dst[255] = 0; } }
static const char *base_name(const char *p) { const char *s = strrchr(p, '/'); return s ? s + 1 : p; }

/* 戻り値: 長さ(秒, 1以上)=読める / 0=読めない */
MS_EXPORT int mid_probe(const char *path, const char *pcm_dir, char *title, char *compo) {
    tml_message *m = tml_load_filename(path);
    unsigned int len = 0; int notes = 0;
    if (!m) return 0;
    tml_get_info(m, NULL, NULL, &notes, NULL, &len);
    tml_free(m);
    set_str(title, base_name(path)); set_str(compo, "");
    if (notes <= 0) return 0;
    return len / 1000 + 1;
}

/* 0=成功, 1=読めない, 2=書けない, 3=SoundFontが無い */
MS_EXPORT int mid_to_wav(const char *path, const char *pcm_dir, const char *wav_path,
                         int rate, int loops, int fade_sec, char *title, char *compo) {
    tml_message *m = tml_load_filename(path);
    int r;
    if (!m) return 1;
    set_str(title, base_name(path)); set_str(compo, "");
    r = render(m, pcm_dir, wav_path, rate, fade_sec, 0);
    tml_free(m);
    return r;
}

MS_EXPORT int mus_probe(const char *path, const char *pcm_dir, char *title, char *compo) {
    int len = 0, sl = 0; double secs = 0;
    uint8_t *d = read_all(path, &len), *smf;
    if (!d) return 0;
    smf = mus_to_smf(d, len, 2, &sl, &secs);
    free(d);
    if (!smf) return 0;
    free(smf);
    set_str(title, base_name(path)); set_str(compo, "");
    return (int)secs + 1;
}

MS_EXPORT int mus_to_wav(const char *path, const char *pcm_dir, const char *wav_path,
                         int rate, int loops, int fade_sec, char *title, char *compo) {
    int len = 0, sl = 0, r; double secs = 0;
    uint8_t *d = read_all(path, &len), *smf;
    tml_message *m;
    if (!d) return 1;
    smf = mus_to_smf(d, len, loops, &sl, &secs);
    free(d);
    if (!smf) return 1;
    m = tml_load_memory(smf, sl);
    free(smf);
    if (!m) return 1;
    set_str(title, base_name(path)); set_str(compo, "");
    r = render(m, pcm_dir, wav_path, rate, fade_sec, 1);
    tml_free(m);
    return r;
}

/* デバッグ用: .MUS を .mid に書き出す */
MS_EXPORT int mus_to_mid(const char *path, const char *mid_path, int loops) {
    int len = 0, sl = 0; double secs = 0;
    uint8_t *d = read_all(path, &len), *smf;
    FILE *fp;
    if (!d) return 1;
    smf = mus_to_smf(d, len, loops, &sl, &secs);
    free(d);
    if (!smf) return 1;
    fp = fopen(mid_path, "wb");
    if (!fp) { free(smf); return 2; }
    fwrite(smf, 1, sl, fp); fclose(fp); free(smf);
    return 0;
}
