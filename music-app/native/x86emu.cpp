/*
 * x86emu.cpp - 8086/80186 の命令を1つずつ解釈して実行する。
 * 音楽ドライバが使う範囲を想定（浮動小数点・保護モードは無し）。
 */
#include "x86emu.h"
#include <stdio.h>
#include <stdlib.h>

enum { AX, CX, DX, BX, SP, BP, SI, DI };
enum { ES, CS, SS, DS };

static bool parity(uint8_t v) {
    v ^= v >> 4; v ^= v >> 2; v ^= v >> 1;
    return !(v & 1);
}

X86::X86() {
    mem = (uint8_t *)calloc(0x110000, 1);
    reset();
}
X86::~X86() { free(mem); }

void X86::reset() {
    memset(r, 0, sizeof(r));
    memset(sreg, 0, sizeof(sreg));
    ip = 0;
    cf = pf = af = zf = sf = tf = df = of = false;
    ifl = true;
    halted = false;
    seg_ovr = -1;
    rep = 0;
    // 戻り用の HLT
    wb(lin(stopSeg, stopOff), 0xF4);
}

uint16_t X86::flags() const {
    return 0xF002 | (cf ? 1 : 0) | (pf ? 4 : 0) | (af ? 0x10 : 0) | (zf ? 0x40 : 0) |
           (sf ? 0x80 : 0) | (tf ? 0x100 : 0) | (ifl ? 0x200 : 0) | (df ? 0x400 : 0) |
           (of ? 0x800 : 0);
}
void X86::setflags(uint16_t f) {
    cf = f & 1; pf = f & 4; af = f & 0x10; zf = f & 0x40; sf = f & 0x80;
    tf = f & 0x100; ifl = f & 0x200; df = f & 0x400; of = f & 0x800;
}

void X86::modrm() {
    uint8_t m = fetch8();
    mod_ = m >> 6; reg_ = (m >> 3) & 7; rm_ = m & 7;
    if (mod_ == 3) { ea_reg = true; return; }
    ea_reg = false;
    uint16_t off = 0;
    int defseg = DS;
    switch (rm_) {
        case 0: off = r[BX] + r[SI]; break;
        case 1: off = r[BX] + r[DI]; break;
        case 2: off = r[BP] + r[SI]; defseg = SS; break;
        case 3: off = r[BP] + r[DI]; defseg = SS; break;
        case 4: off = r[SI]; break;
        case 5: off = r[DI]; break;
        case 6:
            if (mod_ == 0) { off = fetch16(); } else { off = r[BP]; defseg = SS; }
            break;
        case 7: off = r[BX]; break;
    }
    if (mod_ == 1) off += (int8_t)fetch8();
    else if (mod_ == 2) off += fetch16();
    int s = seg_ovr >= 0 ? seg_ovr : defseg;
    ea = lin(sreg[s], off);
}

uint8_t X86::getrm8() { return ea_reg ? getr8(rm_) : rb(ea); }
uint16_t X86::getrm16() { return ea_reg ? r[rm_] : rw(ea); }
void X86::setrm8(uint8_t v) { if (ea_reg) setr8(rm_, v); else wb(ea, v); }
void X86::setrm16(uint16_t v) { if (ea_reg) r[rm_] = v; else ww(ea, v); }

void X86::setpzs8(uint8_t v) { zf = v == 0; sf = v & 0x80; pf = parity(v); }
void X86::setpzs16(uint16_t v) { zf = v == 0; sf = v & 0x8000; pf = parity(v & 0xFF); }

// op: 0 ADD 1 OR 2 ADC 3 SBB 4 AND 5 SUB 6 XOR 7 CMP
uint8_t X86::alu8(int op, uint8_t a, uint8_t b) {
    unsigned res;
    switch (op) {
        case 0: case 2: {
            unsigned c = (op == 2 && cf) ? 1 : 0;
            res = a + b + c;
            cf = res > 0xFF;
            af = ((a & 0xF) + (b & 0xF) + c) > 0xF;
            of = (~(a ^ b) & (a ^ res) & 0x80) != 0;
            break;
        }
        case 3: case 5: case 7: {
            unsigned c = (op == 3 && cf) ? 1 : 0;
            res = a - b - c;
            cf = (unsigned)a < (unsigned)b + c;
            af = (a & 0xF) < (b & 0xF) + c;
            of = ((a ^ b) & (a ^ res) & 0x80) != 0;
            break;
        }
        case 1: res = a | b; cf = of = false; af = false; break;
        case 4: res = a & b; cf = of = false; af = false; break;
        default: res = a ^ b; cf = of = false; af = false; break;
    }
    setpzs8((uint8_t)res);
    return (uint8_t)res;
}

uint16_t X86::alu16(int op, uint16_t a, uint16_t b) {
    unsigned res;
    switch (op) {
        case 0: case 2: {
            unsigned c = (op == 2 && cf) ? 1 : 0;
            res = a + b + c;
            cf = res > 0xFFFF;
            af = ((a & 0xF) + (b & 0xF) + c) > 0xF;
            of = (~(a ^ b) & (a ^ res) & 0x8000) != 0;
            break;
        }
        case 3: case 5: case 7: {
            unsigned c = (op == 3 && cf) ? 1 : 0;
            res = a - b - c;
            cf = (unsigned)a < (unsigned)b + c;
            af = (a & 0xF) < (b & 0xF) + c;
            of = ((a ^ b) & (a ^ res) & 0x8000) != 0;
            break;
        }
        case 1: res = a | b; cf = of = false; af = false; break;
        case 4: res = a & b; cf = of = false; af = false; break;
        default: res = a ^ b; cf = of = false; af = false; break;
    }
    setpzs16((uint16_t)res);
    return (uint16_t)res;
}

// op: 0 ROL 1 ROR 2 RCL 3 RCR 4 SHL 5 SHR 6 SAL 7 SAR
uint8_t X86::shift8(int op, uint8_t v, int n) {
    n &= 0x1F;
    if (n == 0) return v;
    for (int i = 0; i < n; i++) {
        uint8_t o = v;
        switch (op) {
            case 0: cf = v & 0x80; v = (v << 1) | (cf ? 1 : 0); of = ((v ^ o) & 0x80) != 0; break;
            case 1: cf = v & 1; v = (v >> 1) | (cf ? 0x80 : 0); of = ((v ^ (v << 1)) & 0x80) != 0; break;
            case 2: { bool c = v & 0x80; v = (v << 1) | (cf ? 1 : 0); cf = c; of = ((v ^ o) & 0x80) != 0; break; }
            case 3: { bool c = v & 1; v = (v >> 1) | (cf ? 0x80 : 0); cf = c; of = ((v ^ (v << 1)) & 0x80) != 0; break; }
            case 4: case 6: cf = v & 0x80; v <<= 1; of = ((v ^ o) & 0x80) != 0; setpzs8(v); break;
            case 5: cf = v & 1; of = o & 0x80; v >>= 1; setpzs8(v); break;
            case 7: cf = v & 1; v = (uint8_t)((int8_t)v >> 1); of = false; setpzs8(v); break;
        }
    }
    return v;
}

uint16_t X86::shift16(int op, uint16_t v, int n) {
    n &= 0x1F;
    if (n == 0) return v;
    for (int i = 0; i < n; i++) {
        uint16_t o = v;
        switch (op) {
            case 0: cf = v & 0x8000; v = (v << 1) | (cf ? 1 : 0); of = ((v ^ o) & 0x8000) != 0; break;
            case 1: cf = v & 1; v = (v >> 1) | (cf ? 0x8000 : 0); of = ((v ^ (v << 1)) & 0x8000) != 0; break;
            case 2: { bool c = v & 0x8000; v = (v << 1) | (cf ? 1 : 0); cf = c; of = ((v ^ o) & 0x8000) != 0; break; }
            case 3: { bool c = v & 1; v = (v >> 1) | (cf ? 0x8000 : 0); cf = c; of = ((v ^ (v << 1)) & 0x8000) != 0; break; }
            case 4: case 6: cf = v & 0x8000; v <<= 1; of = ((v ^ o) & 0x8000) != 0; setpzs16(v); break;
            case 5: cf = v & 1; of = o & 0x8000; v >>= 1; setpzs16(v); break;
            case 7: cf = v & 1; v = (uint16_t)((int16_t)v >> 1); of = false; setpzs16(v); break;
        }
    }
    return v;
}

void X86::intr(uint8_t n) {
    if (hostint && hostint(user, *this, n)) return;
    uint16_t off = rw(n * 4), seg = rw(n * 4 + 2);
    if (off == 0 && seg == 0) return;   // 何も登録されていない割り込みは無視
    push(flags());
    push(sreg[CS]);
    push(ip);
    ifl = false; tf = false;
    sreg[CS] = seg; ip = off;
}

void X86::grp3_8() {
    uint8_t v = getrm8();
    switch (reg_) {
        case 0: case 1: alu8(4, v, fetch8()); break;   // TEST
        case 2: setrm8(~v); break;
        case 3: setrm8(alu8(5, 0, v)); cf = v != 0; break;
        case 4: { uint16_t res = (uint16_t)(r[AX] & 0xFF) * v; r[AX] = res; cf = of = (res >> 8) != 0; break; }
        case 5: { int16_t res = (int16_t)(int8_t)(r[AX] & 0xFF) * (int8_t)v; r[AX] = (uint16_t)res;
                  cf = of = res != (int8_t)res; break; }
        case 6: {
            if (v == 0) { intr(0); return; }
            uint16_t a = r[AX]; uint16_t q = a / v;
            if (q > 0xFF) { intr(0); return; }
            r[AX] = ((a % v) << 8) | q; break;
        }
        case 7: {
            if (v == 0) { intr(0); return; }
            int16_t a = (int16_t)r[AX]; int q = a / (int8_t)v;
            if (q > 127 || q < -128) { intr(0); return; }
            r[AX] = ((uint8_t)(a % (int8_t)v) << 8) | (uint8_t)q; break;
        }
    }
}

void X86::grp3_16() {
    uint16_t v = getrm16();
    switch (reg_) {
        case 0: case 1: alu16(4, v, fetch16()); break;
        case 2: setrm16(~v); break;
        case 3: setrm16(alu16(5, 0, v)); cf = v != 0; break;
        case 4: { uint32_t res = (uint32_t)r[AX] * v; r[AX] = res; r[DX] = res >> 16; cf = of = r[DX] != 0; break; }
        case 5: { int32_t res = (int32_t)(int16_t)r[AX] * (int16_t)v; r[AX] = res; r[DX] = (uint32_t)res >> 16;
                  cf = of = res != (int16_t)res; break; }
        case 6: {
            if (v == 0) { intr(0); return; }
            uint32_t a = ((uint32_t)r[DX] << 16) | r[AX]; uint32_t q = a / v;
            if (q > 0xFFFF) { intr(0); return; }
            r[AX] = q; r[DX] = a % v; break;
        }
        case 7: {
            if (v == 0) { intr(0); return; }
            int32_t a = (int32_t)(((uint32_t)r[DX] << 16) | r[AX]); int32_t q = a / (int16_t)v;
            if (q > 32767 || q < -32768) { intr(0); return; }
            r[AX] = (uint16_t)q; r[DX] = (uint16_t)(a % (int16_t)v); break;
        }
    }
}

// 文字列命令（REP 対応）
void X86::strop(uint8_t op) {
    int d = df ? -1 : 1;
    bool w = op & 1;
    int sz = w ? 2 : 1;
    for (;;) {
        if (rep && r[CX] == 0) break;
        uint32_t src = lin(sreg[dseg()], r[SI]);
        uint32_t dst = lin(sreg[ES], r[DI]);
        bool cmpop = false;
        switch (op) {
            case 0xA4: wb(dst, rb(src)); r[SI] += d; r[DI] += d; break;
            case 0xA5: ww(dst, rw(src)); r[SI] += 2 * d; r[DI] += 2 * d; break;
            case 0xA6: alu8(7, rb(src), rb(dst)); r[SI] += d; r[DI] += d; cmpop = true; break;
            case 0xA7: alu16(7, rw(src), rw(dst)); r[SI] += 2 * d; r[DI] += 2 * d; cmpop = true; break;
            case 0xAA: wb(dst, r[AX] & 0xFF); r[DI] += d; break;
            case 0xAB: ww(dst, r[AX]); r[DI] += 2 * d; break;
            case 0xAC: setr8(0, rb(src)); r[SI] += d; break;
            case 0xAD: r[AX] = rw(src); r[SI] += 2 * d; break;
            case 0xAE: alu8(7, r[AX] & 0xFF, rb(dst)); r[DI] += d; cmpop = true; break;
            case 0xAF: alu16(7, r[AX], rw(dst)); r[DI] += 2 * d; cmpop = true; break;
            case 0x6C: wb(dst, inb ? inb(user, r[DX]) : 0xFF); r[DI] += d; break;
            case 0x6D: ww(dst, inb ? (inb(user, r[DX]) | (inb(user, r[DX] + 1) << 8)) : 0xFFFF); r[DI] += 2 * d; break;
            case 0x6E: if (outb) outb(user, r[DX], rb(src)); r[SI] += d; break;
            case 0x6F: if (outb) { outb(user, r[DX], rb(src)); outb(user, r[DX] + 1, rb(src + 1)); } r[SI] += 2 * d; break;
        }
        (void)sz;
        if (!rep) break;
        r[CX]--;
        if (cmpop) {
            if (rep == 1 && !zf) break;
            if (rep == 2 && zf) break;
        }
    }
}

void X86::step() {
    seg_ovr = -1;
    rep = 0;
    uint8_t op;
    // プレフィックス
    for (;;) {
        op = fetch8();
        if (op == 0x26) seg_ovr = ES;
        else if (op == 0x2E) seg_ovr = CS;
        else if (op == 0x36) seg_ovr = SS;
        else if (op == 0x3E) seg_ovr = DS;
        else if (op == 0xF3) rep = 1;
        else if (op == 0xF2) rep = 2;
        else if (op == 0xF0) {}   // LOCK
        else break;
    }

    if (op < 0x40 && (op & 7) < 6) {
        int alu = op >> 3;
        switch (op & 7) {
            case 0: modrm(); { uint8_t v = alu8(alu, getrm8(), getr8(reg_)); if (alu != 7) setrm8(v); } break;
            case 1: modrm(); { uint16_t v = alu16(alu, getrm16(), r[reg_]); if (alu != 7) setrm16(v); } break;
            case 2: modrm(); { uint8_t v = alu8(alu, getr8(reg_), getrm8()); if (alu != 7) setr8(reg_, v); } break;
            case 3: modrm(); { uint16_t v = alu16(alu, r[reg_], getrm16()); if (alu != 7) r[reg_] = v; } break;
            case 4: { uint8_t v = alu8(alu, r[AX] & 0xFF, fetch8()); if (alu != 7) setr8(0, v); } break;
            case 5: { uint16_t v = alu16(alu, r[AX], fetch16()); if (alu != 7) r[AX] = v; } break;
        }
        return;
    }

    switch (op) {
        case 0x06: push(sreg[ES]); break;
        case 0x07: sreg[ES] = pop(); break;
        case 0x0E: push(sreg[CS]); break;
        case 0x0F: sreg[CS] = pop(); break;   // 8086 の POP CS
        case 0x16: push(sreg[SS]); break;
        case 0x17: sreg[SS] = pop(); break;
        case 0x1E: push(sreg[DS]); break;
        case 0x1F: sreg[DS] = pop(); break;
        case 0x27: {   // DAA
            uint8_t al = r[AX] & 0xFF; bool c = cf;
            if ((al & 0xF) > 9 || af) { al += 6; af = true; } else af = false;
            if ((r[AX] & 0xFF) > 0x99 || c) { al += 0x60; cf = true; } else cf = false;
            setr8(0, al); setpzs8(al); break;
        }
        case 0x2F: {   // DAS
            uint8_t al = r[AX] & 0xFF, old = al; bool c = cf;
            if ((al & 0xF) > 9 || af) { al -= 6; af = true; } else af = false;
            if (old > 0x99 || c) { al -= 0x60; cf = true; } else cf = false;
            setr8(0, al); setpzs8(al); break;
        }
        case 0x37: {   // AAA
            if ((r[AX] & 0xF) > 9 || af) { r[AX] += 0x106; af = cf = true; } else af = cf = false;
            r[AX] &= 0xFF0F; break;
        }
        case 0x3F: {   // AAS
            if ((r[AX] & 0xF) > 9 || af) { r[AX] -= 6; r[AX] -= 0x100; af = cf = true; } else af = cf = false;
            r[AX] &= 0xFF0F; break;
        }
        case 0x40: case 0x41: case 0x42: case 0x43: case 0x44: case 0x45: case 0x46: case 0x47: {
            bool c = cf; r[op & 7] = alu16(0, r[op & 7], 1); cf = c; break;
        }
        case 0x48: case 0x49: case 0x4A: case 0x4B: case 0x4C: case 0x4D: case 0x4E: case 0x4F: {
            bool c = cf; r[op & 7] = alu16(5, r[op & 7], 1); cf = c; break;
        }
        case 0x50: case 0x51: case 0x52: case 0x53: case 0x55: case 0x56: case 0x57:
            push(r[op & 7]); break;
        case 0x54: { uint16_t v = r[SP]; push(v); break; }
        case 0x58: case 0x59: case 0x5A: case 0x5B: case 0x5C: case 0x5D: case 0x5E: case 0x5F:
            r[op & 7] = pop(); break;
        case 0x60: {   // PUSHA
            uint16_t sp = r[SP];
            push(r[AX]); push(r[CX]); push(r[DX]); push(r[BX]); push(sp); push(r[BP]); push(r[SI]); push(r[DI]);
            break;
        }
        case 0x61: {   // POPA
            r[DI] = pop(); r[SI] = pop(); r[BP] = pop(); pop(); r[BX] = pop(); r[DX] = pop(); r[CX] = pop(); r[AX] = pop();
            break;
        }
        case 0x62: modrm(); break;   // BOUND（検査しない）
        case 0x68: push(fetch16()); break;
        case 0x69: case 0x6B: {
            modrm();
            int16_t a = (int16_t)getrm16();
            int16_t b = op == 0x69 ? (int16_t)fetch16() : (int16_t)(int8_t)fetch8();
            int32_t res = (int32_t)a * b;
            r[reg_] = (uint16_t)res;
            cf = of = res != (int16_t)res;
            break;
        }
        case 0x6A: push((uint16_t)(int16_t)(int8_t)fetch8()); break;
        case 0x6C: case 0x6D: case 0x6E: case 0x6F: strop(op); break;
        case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
        case 0x78: case 0x79: case 0x7A: case 0x7B: case 0x7C: case 0x7D: case 0x7E: case 0x7F: {
            int8_t d = (int8_t)fetch8();
            bool t;
            switch (op & 0xE) {
                case 0x0: t = of; break;
                case 0x2: t = cf; break;
                case 0x4: t = zf; break;
                case 0x6: t = cf || zf; break;
                case 0x8: t = sf; break;
                case 0xA: t = pf; break;
                case 0xC: t = sf != of; break;
                default: t = zf || (sf != of); break;
            }
            if (op & 1) t = !t;
            if (t) ip += d;
            break;
        }
        case 0x80: case 0x82: { modrm(); uint8_t v = alu8(reg_, getrm8(), fetch8()); if (reg_ != 7) setrm8(v); break; }
        case 0x81: { modrm(); uint16_t v = alu16(reg_, getrm16(), fetch16()); if (reg_ != 7) setrm16(v); break; }
        case 0x83: { modrm(); uint16_t v = alu16(reg_, getrm16(), (uint16_t)(int16_t)(int8_t)fetch8()); if (reg_ != 7) setrm16(v); break; }
        case 0x84: modrm(); alu8(4, getrm8(), getr8(reg_)); break;
        case 0x85: modrm(); alu16(4, getrm16(), r[reg_]); break;
        case 0x86: { modrm(); uint8_t a = getrm8(); setrm8(getr8(reg_)); setr8(reg_, a); break; }
        case 0x87: { modrm(); uint16_t a = getrm16(); setrm16(r[reg_]); r[reg_] = a; break; }
        case 0x88: modrm(); setrm8(getr8(reg_)); break;
        case 0x89: modrm(); setrm16(r[reg_]); break;
        case 0x8A: modrm(); setr8(reg_, getrm8()); break;
        case 0x8B: modrm(); r[reg_] = getrm16(); break;
        case 0x8C: modrm(); setrm16(sreg[reg_ & 3]); break;
        case 0x8D: {   // LEA
            modrm();
            // ea はセグメント込みなので、オフセットだけ取り直す
            int s = seg_ovr;
            (void)s;
            // 再計算: セグメント分を引く
            int defseg = (rm_ == 2 || rm_ == 3 || (rm_ == 6 && mod_ != 0)) ? SS : DS;
            int sg = seg_ovr >= 0 ? seg_ovr : defseg;
            r[reg_] = (uint16_t)(ea - ((uint32_t)sreg[sg] << 4));
            break;
        }
        case 0x8E: modrm(); sreg[reg_ & 3] = getrm16(); break;
        case 0x8F: modrm(); { uint16_t v = pop(); setrm16(v); } break;
        case 0x90: break;
        case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97: {
            uint16_t t = r[AX]; r[AX] = r[op & 7]; r[op & 7] = t; break;
        }
        case 0x98: r[AX] = (uint16_t)(int16_t)(int8_t)(r[AX] & 0xFF); break;
        case 0x99: r[DX] = (r[AX] & 0x8000) ? 0xFFFF : 0; break;
        case 0x9A: { uint16_t o = fetch16(), s = fetch16(); push(sreg[CS]); push(ip); sreg[CS] = s; ip = o; break; }
        case 0x9B: break;   // WAIT
        case 0x9C: push(flags()); break;
        case 0x9D: setflags(pop()); break;
        case 0x9E: { uint8_t ah = r[AX] >> 8; cf = ah & 1; pf = ah & 4; af = ah & 0x10; zf = ah & 0x40; sf = ah & 0x80; break; }
        case 0x9F: r[AX] = (r[AX] & 0xFF) | ((flags() & 0xFF) << 8); break;
        case 0xA0: setr8(0, rb(lin(sreg[dseg()], fetch16()))); break;
        case 0xA1: r[AX] = rw(lin(sreg[dseg()], fetch16())); break;
        case 0xA2: wb(lin(sreg[dseg()], fetch16()), r[AX] & 0xFF); break;
        case 0xA3: ww(lin(sreg[dseg()], fetch16()), r[AX]); break;
        case 0xA4: case 0xA5: case 0xA6: case 0xA7: case 0xAA: case 0xAB: case 0xAC: case 0xAD: case 0xAE: case 0xAF:
            strop(op); break;
        case 0xA8: alu8(4, r[AX] & 0xFF, fetch8()); break;
        case 0xA9: alu16(4, r[AX], fetch16()); break;
        case 0xB0: case 0xB1: case 0xB2: case 0xB3: case 0xB4: case 0xB5: case 0xB6: case 0xB7:
            setr8(op & 7, fetch8()); break;
        case 0xB8: case 0xB9: case 0xBA: case 0xBB: case 0xBC: case 0xBD: case 0xBE: case 0xBF:
            r[op & 7] = fetch16(); break;
        case 0xC0: { modrm(); uint8_t v = getrm8(); int n = fetch8(); setrm8(shift8(reg_, v, n)); break; }
        case 0xC1: { modrm(); uint16_t v = getrm16(); int n = fetch8(); setrm16(shift16(reg_, v, n)); break; }
        case 0xC2: { uint16_t n = fetch16(); ip = pop(); r[SP] += n; break; }
        case 0xC3: ip = pop(); break;
        case 0xC4: modrm(); r[reg_] = rw(ea); sreg[ES] = rw(ea + 2); break;
        case 0xC5: modrm(); r[reg_] = rw(ea); sreg[DS] = rw(ea + 2); break;
        case 0xC6: modrm(); setrm8(fetch8()); break;
        case 0xC7: modrm(); setrm16(fetch16()); break;
        case 0xC8: {   // ENTER
            uint16_t sz = fetch16(); uint8_t lv = fetch8() & 31;
            push(r[BP]); uint16_t fp = r[SP];
            for (int i = 1; i < lv; i++) { r[BP] -= 2; push(rw(lin(sreg[SS], r[BP]))); }
            if (lv) push(fp);
            r[BP] = fp; r[SP] -= sz; break;
        }
        case 0xC9: r[SP] = r[BP]; r[BP] = pop(); break;
        case 0xCA: { uint16_t n = fetch16(); ip = pop(); sreg[CS] = pop(); r[SP] += n; break; }
        case 0xCB: ip = pop(); sreg[CS] = pop(); break;
        case 0xCC: intr(3); break;
        case 0xCD: intr(fetch8()); break;
        case 0xCE: if (of) intr(4); break;
        case 0xCF: ip = pop(); sreg[CS] = pop(); setflags(pop()); break;
        case 0xD0: modrm(); setrm8(shift8(reg_, getrm8(), 1)); break;
        case 0xD1: modrm(); setrm16(shift16(reg_, getrm16(), 1)); break;
        case 0xD2: modrm(); setrm8(shift8(reg_, getrm8(), r[CX] & 0xFF)); break;
        case 0xD3: modrm(); setrm16(shift16(reg_, getrm16(), r[CX] & 0xFF)); break;
        case 0xD4: {   // AAM
            uint8_t b = fetch8(); if (!b) { intr(0); break; }
            uint8_t al = r[AX] & 0xFF; r[AX] = ((al / b) << 8) | (al % b); setpzs8(r[AX] & 0xFF); break;
        }
        case 0xD5: {   // AAD
            uint8_t b = fetch8(); uint8_t al = ((r[AX] >> 8) * b + (r[AX] & 0xFF)) & 0xFF; r[AX] = al; setpzs8(al); break;
        }
        case 0xD6: setr8(0, cf ? 0xFF : 0); break;
        case 0xD7: setr8(0, rb(lin(sreg[dseg()], (uint16_t)(r[BX] + (r[AX] & 0xFF))))); break;
        case 0xD8: case 0xD9: case 0xDA: case 0xDB: case 0xDC: case 0xDD: case 0xDE: case 0xDF:
            modrm(); break;   // 浮動小数点は無視
        case 0xE0: case 0xE1: case 0xE2: {
            int8_t d = (int8_t)fetch8();
            r[CX]--;
            bool t = r[CX] != 0;
            if (op == 0xE0) t = t && !zf;
            if (op == 0xE1) t = t && zf;
            if (t) ip += d;
            break;
        }
        case 0xE3: { int8_t d = (int8_t)fetch8(); if (r[CX] == 0) ip += d; break; }
        case 0xE4: setr8(0, inb ? inb(user, fetch8()) : 0xFF); break;
        case 0xE5: { uint8_t p = fetch8(); r[AX] = inb ? (inb(user, p) | (inb(user, p + 1) << 8)) : 0xFFFF; break; }
        case 0xE6: { uint8_t p = fetch8(); if (outb) outb(user, p, r[AX] & 0xFF); break; }
        case 0xE7: { uint8_t p = fetch8(); if (outb) { outb(user, p, r[AX] & 0xFF); outb(user, p + 1, r[AX] >> 8); } break; }
        case 0xE8: { int16_t d = (int16_t)fetch16(); push(ip); ip += d; break; }
        case 0xE9: { int16_t d = (int16_t)fetch16(); ip += d; break; }
        case 0xEA: { uint16_t o = fetch16(), s = fetch16(); sreg[CS] = s; ip = o; break; }
        case 0xEB: { int8_t d = (int8_t)fetch8(); ip += d; break; }
        case 0xEC: setr8(0, inb ? inb(user, r[DX]) : 0xFF); break;
        case 0xED: r[AX] = inb ? (inb(user, r[DX]) | (inb(user, r[DX] + 1) << 8)) : 0xFFFF; break;
        case 0xEE: if (outb) outb(user, r[DX], r[AX] & 0xFF); break;
        case 0xEF: if (outb) { outb(user, r[DX], r[AX] & 0xFF); outb(user, r[DX] + 1, r[AX] >> 8); } break;
        case 0xF4: halted = true; break;
        case 0xF5: cf = !cf; break;
        case 0xF6: modrm(); grp3_8(); break;
        case 0xF7: modrm(); grp3_16(); break;
        case 0xF8: cf = false; break;
        case 0xF9: cf = true; break;
        case 0xFA: ifl = false; break;
        case 0xFB: ifl = true; break;
        case 0xFC: df = false; break;
        case 0xFD: df = true; break;
        case 0xFE: {
            modrm();
            uint8_t v = getrm8(); bool c = cf;
            if (reg_ == 0) setrm8(alu8(0, v, 1));
            else if (reg_ == 1) setrm8(alu8(5, v, 1));
            cf = c;
            break;
        }
        case 0xFF: {
            modrm();
            switch (reg_) {
                case 0: { bool c = cf; setrm16(alu16(0, getrm16(), 1)); cf = c; break; }
                case 1: { bool c = cf; setrm16(alu16(5, getrm16(), 1)); cf = c; break; }
                case 2: { uint16_t t = getrm16(); push(ip); ip = t; break; }
                case 3: { uint16_t o = rw(ea), s = rw(ea + 2); push(sreg[CS]); push(ip); sreg[CS] = s; ip = o; break; }
                case 4: ip = getrm16(); break;
                case 5: ip = rw(ea); sreg[CS] = rw(ea + 2); break;
                case 6: push(getrm16()); break;
                default: break;
            }
            break;
        }
        default:
            fault = true;
            snprintf(err, sizeof(err), "unknown opcode %02X at %04X:%04X", op, sreg[CS], (uint16_t)(ip - 1));
            halted = true;
            break;
    }
}

long X86::run(long n) {
    long i = 0;
    while (i < n && !halted) { step(); i++; }
    steps += i;
    return i;
}

bool X86::callfar(uint16_t seg, uint16_t off, long maxsteps) {
    push(stopSeg);
    push(stopOff);
    sreg[CS] = seg; ip = off;
    halted = false;
    run(maxsteps);
    bool ok = halted && !fault && sreg[CS] == stopSeg && (uint16_t)(ip - 1) == stopOff;
    halted = false;
    return ok;
}

bool X86::callint(uint8_t n, long maxsteps) {
    uint16_t off = rw(n * 4), seg = rw(n * 4 + 2);
    if (off == 0 && seg == 0) return false;
    push(flags());
    push(stopSeg);
    push(stopOff);
    ifl = false;
    sreg[CS] = seg; ip = off;
    halted = false;
    run(maxsteps);
    bool ok = halted && !fault && sreg[CS] == stopSeg && (uint16_t)(ip - 1) == stopOff;
    halted = false;
    return ok;
}
