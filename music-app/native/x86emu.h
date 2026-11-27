/*
 * x86emu.h - 音楽ドライバを動かすための小さな 8086/80186 エミュレータ。
 * 1MB のメモリと、I/O・割り込みの横取り口だけを持つ。
 */
#pragma once
#include <stdint.h>
#include <string.h>

struct X86 {
    uint8_t *mem;            // 1MB + 余白
    uint16_t r[8];           // AX CX DX BX SP BP SI DI
    uint16_t sreg[4];        // ES CS SS DS
    uint16_t ip;
    // フラグ
    bool cf, pf, af, zf, sf, tf, ifl, df, of;
    bool halted;

    // 外とのつなぎ
    void *user = nullptr;
    uint8_t (*inb)(void *u, uint16_t port) = nullptr;
    void (*outb)(void *u, uint16_t port, uint8_t v) = nullptr;
    // true を返したらソフト割り込みを外側で処理した（CPU側では飛ばない）
    bool (*hostint)(void *u, X86 &c, uint8_t n) = nullptr;

    X86();
    ~X86();
    void reset();
    uint16_t flags() const;
    void setflags(uint16_t f);

    // 実行: 最大 n 命令、HLT で止まる。戻り値は実行した命令数
    long run(long n);
    // 割り込みベクタ n を呼び、HLT 番地まで戻ってきたら終わる
    bool callint(uint8_t n, long maxsteps = 20000000);
    bool callfar(uint16_t seg, uint16_t off, long maxsteps = 20000000);

    uint8_t  rb(uint32_t a) const { return mem[a & 0xFFFFF]; }
    uint16_t rw(uint32_t a) const { return rb(a) | (rb(a + 1) << 8); }
    void wb(uint32_t a, uint8_t v) { mem[a & 0xFFFFF] = v; }
    void ww(uint32_t a, uint16_t v) { wb(a, v & 0xFF); wb(a + 1, v >> 8); }
    static uint32_t lin(uint16_t s, uint16_t o) { return ((uint32_t)s << 4) + o; }

    // 戻り先の HLT 番地
    uint16_t stopSeg = 0xF000, stopOff = 0xFFF0;
    long steps = 0;
    bool fault = false;
    char err[96] = {0};

private:
    int seg_ovr;   // -1: なし
    int rep;       // 0: なし, 1: REPZ, 2: REPNZ
    // modrm
    int mod_, reg_, rm_;
    uint32_t ea;
    bool ea_reg;

    uint8_t fetch8() { uint8_t v = rb(lin(sreg[1], ip)); ip++; return v; }
    uint16_t fetch16() { uint16_t v = fetch8(); v |= fetch8() << 8; return v; }
    void modrm();
    uint8_t getrm8();
    uint16_t getrm16();
    void setrm8(uint8_t v);
    void setrm16(uint16_t v);
    uint8_t getr8(int i) const { return i < 4 ? (r[i] & 0xFF) : (r[i - 4] >> 8); }
    void setr8(int i, uint8_t v) {
        if (i < 4) r[i] = (r[i] & 0xFF00) | v; else r[i - 4] = (r[i - 4] & 0x00FF) | (v << 8);
    }
    void push(uint16_t v) { r[4] -= 2; ww(lin(sreg[2], r[4]), v); }
    uint16_t pop() { uint16_t v = rw(lin(sreg[2], r[4])); r[4] += 2; return v; }
    int dseg() const { return seg_ovr >= 0 ? seg_ovr : 3; }

    void setpzs8(uint8_t v);
    void setpzs16(uint16_t v);
    uint8_t alu8(int op, uint8_t a, uint8_t b);
    uint16_t alu16(int op, uint16_t a, uint16_t b);
    uint8_t shift8(int op, uint8_t v, int n);
    uint16_t shift16(int op, uint16_t v, int n);
    void intr(uint8_t n);
    void step();
    void grp3_8();
    void grp3_16();
    void strop(uint8_t op);
};
