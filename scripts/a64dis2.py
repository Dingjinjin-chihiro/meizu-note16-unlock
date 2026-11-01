"""最小 AArch64 解码器（本次分析子集）+ SPL 校验点分析。

原则：只解码能确定编码的指令，其余输出 `dw 0x........`，绝不猜测。
"""
import struct, sys

def sx(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v

def rd(w): return w & 0x1F
def rn(w): return (w >> 5) & 0x1F
def ra(w): return (w >> 10) & 0x1F
def rm(w): return (w >> 16) & 0x1F

def reg(n, sf, sp=False):
    if n == 31: return ('sp' if (sp and sf) else ('xzr' if sf else 'wzr'))
    return ('x%d' if sf else 'w%d') % n

CONDS = ['eq','ne','cs','cc','mi','pl','vs','vc','hi','ls','ge','lt','gt','le','al','nv']

def decode(w, pc):
    sf = (w >> 31) & 1

    if w == 0xD503201F: return 'nop'
    if (w & 0xFFFFFC1F) == 0xD65F0000:
        return 'ret' if rn(w) == 30 else 'ret %s' % reg(rn(w), 1)

    if (w >> 26) == 0x25: return 'bl 0x%x' % (pc + (sx(w & 0x3FFFFFF, 26) << 2))
    if (w >> 26) == 0x05: return 'b 0x%x' % (pc + (sx(w & 0x3FFFFFF, 26) << 2))

    if ((w >> 25) & 0x3F) == 0x1A:
        op = 'cbnz' if (w >> 24) & 1 else 'cbz'
        return '%s %s, 0x%x' % (op, reg(rd(w), sf), pc + (sx((w >> 5) & 0x7FFFF, 19) << 2))

    if (w & 0xFF000010) == 0x54000000:
        return 'b.%s 0x%x' % (CONDS[w & 0xF], pc + (sx((w >> 5) & 0x7FFFF, 19) << 2))

    for base, name in ((0x52800000, 'movz'), (0x12800000, 'movn'), (0x72800000, 'movk')):
        if (w & 0x7F800000) == base:
            imm = ((w >> 5) & 0xFFFF) << (16 * ((w >> 21) & 3))
            return '%s %s, #0x%x' % (name, reg(rd(w), sf), imm)

    if (w & 0x9F000000) == 0x90000000:
        imm = sx((((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3), 21) << 12
        return 'adrp %s, 0x%x' % (reg(rd(w), 1), (pc & ~0xFFF) + imm)

    # ADD/SUB immediate
    if (w & 0x1F000000) == 0x11000000:
        op = 'sub' if (w >> 30) & 1 else 'add'
        s = (w >> 29) & 1
        imm = (w >> 10) & 0xFFF
        if (w >> 22) & 1: imm <<= 12
        if s and sf and rd(w) == 31:
            return 'cmp %s, #0x%x' % (reg(rn(w), 1), imm)
        return '%s%s %s, %s, #0x%x' % (op, 's' if s else '', reg(rd(w), sf), reg(rn(w), sf, sp=True), imm)

    # ADD/SUB shifted register
    if (w & 0x1F200000) == 0x0B000000:
        op = 'sub' if (w >> 30) & 1 else 'add'
        s = 's' if (w >> 29) & 1 else ''
        sh, amt = (w >> 22) & 3, (w >> 10) & 0x3F
        suf = '' if (sh == 0 and amt == 0) else ', %s #%d' % (['lsl','lsr','asr','ror'][sh], amt)
        return '%s%s %s, %s, %s%s' % (op, s, reg(rd(w), sf), reg(rn(w), sf), reg(rm(w), sf), suf)

    # logical shifted register (AND/BIC/ORR/ORN/EOR/EON/ANDS/BICS)
    if (w & 0x1F200000) in (0x0A000000, 0x2A000000, 0x4A000000, 0x6A000000):
        opc = (w >> 29) & 3
        N   = (w >> 21) & 1
        nm  = [('and','bic'), ('orr','orn'), ('eor','eon'), ('ands','bics')][opc][N]
        if nm == 'orr' and rn(w) == 31:
            return 'mov %s, %s' % (reg(rd(w), sf), reg(rm(w), sf))
        if nm == 'ands' and rd(w) == 31:
            return 'tst %s, %s' % (reg(rn(w), sf), reg(rm(w), sf))
        return '%s %s, %s, %s' % (nm, reg(rd(w), sf), reg(rn(w), sf), reg(rm(w), sf))
    # UBFX / SBFX / UBFIZ
    if (w & 0x7F800000) == 0x53000000:
        lsb, width = (w >> 10) & 0x3F, ((w >> 16) & 0x3F) + 1
        return '%s %s, %s, #%d, #%d' % ('sbfx' if (w >> 31) & 1 else 'ubfx',
                                        reg(rd(w), sf), reg(rn(w), sf), lsb, width)

    # CSINC / CSET / CSEL
    if (w & 0x7FE00C00) == 0x1A800400:
        cond = (w >> 12) & 0xF
        if rn(w) == 31 and rm(w) == 31:
            return 'cset %s, %s' % (reg(rd(w), sf), 'ne' if cond == 0 else CONDS[cond])
        return 'csinc %s, %s, %s, %s' % (reg(rd(w), sf), reg(rn(w), sf), reg(rm(w), sf), CONDS[cond])
    if (w & 0x7FE00C00) == 0x1A800000:
        return 'csel %s, %s, %s, %s' % (reg(rd(w), sf), reg(rn(w), sf), reg(rm(w), sf), CONDS[(w >> 12) & 0xF])

    # LDR/STR unsigned offset
    if (w & 0x3B000000) == 0x39000000:
        size = (w >> 30) & 3
        op = 'ldr' if (w >> 22) & 1 else 'str'
        sfx = ['b', 'h', '', ''][size]
        return '%s%s %s, [%s, #0x%x]' % (op, sfx, reg(rd(w), size == 3), reg(rn(w), 1, sp=True), ((w >> 10) & 0xFFF) << size)

    # LDR/STR register offset
    if (w & 0x3B200C00) == 0x38200800:
        size = (w >> 30) & 3
        op = 'ldr' if (w >> 22) & 1 else 'str'
        sfx = ['b', 'h', '', ''][size]
        ext = 'uxtw' if ((w >> 13) & 7) == 2 else 'lsl'
        return '%s%s %s, [%s, %s, %s]' % (op, sfx, reg(rd(w), size == 3), reg(rn(w), 1), reg(rm(w), (w >> 13) & 7 == 3), ext)

    # STP/LDP signed offset
    if (w & 0xFFC00000) == 0xA9000000:
        imm = sx((w >> 15) & 0x7F, 7) * 8
        return 'stp %s, %s, [%s, #%d]' % (reg(rd(w),1), reg(ra(w),1), reg(rn(w),1,sp=True), imm)
    if (w & 0xFFC00000) == 0xA9400000:
        imm = sx((w >> 15) & 0x7F, 7) * 8
        return 'ldp %s, %s, [%s, #%d]' % (reg(rd(w),1), reg(ra(w),1), reg(rn(w),1,sp=True), imm)

    # STP/LDP pre-index
    if (w & 0xFFC00000) == 0xA9800000:
        return 'stp %s, %s, [%s, #%d]!' % (reg(rd(w),1), reg(ra(w),1), reg(rn(w),1,sp=True), sx((w >> 15) & 0x7F, 7) * 8)
    if (w & 0xFFC00000) == 0xA8C00000:
        return 'ldp %s, %s, [%s], #%d' % (reg(rd(w),1), reg(ra(w),1), reg(rn(w),1,sp=True), sx((w >> 15) & 0x7F, 7) * 8)

    if (w & 0xFFE0001F) == 0xD4000001:
        return 'svc #0x%x' % ((w >> 5) & 0xFFFF)

    return 'dw 0x%08x' % w

SELFTEST = [
    (0x940000DA, 0x1000, 'bl 0x1368'),
    (0x34000060, 0x1004, 'cbz w0, 0x1010'),
    (0x528003C0, 0x1008, 'movz w0, #0x1e'),
    (0xD503201F, 0x100C, 'nop'),
    (0xD65F03C0, 0x1010, 'ret'),
    (0x2A0403E3, 0x1014, 'mov w3, w4'),
    (0x6A00003F, 0x1018, 'tst w1, w0'),
    (0x1A9F07E0, 0x101C, 'cset w0, ne'),
]

def selftest():
    ok = True
    for w, pc, want in SELFTEST:
        got = decode(w, pc)
        if got != want:
            ok = False
            print(f'  [BAD] 0x{w:08x} -> {got:<26} expect {want}')
    return ok

def dump(buf, base, start, count, title):
    print(f'\n--- {title} (0x{start:05x}) ---')
    for i in range(count):
        off = start + i * 4
        if off + 4 > len(buf): break
        w = struct.unpack_from('<I', buf, off)[0]
        print(f'  {off:06x}  {w:08x}  {decode(w, base + off)}')

if __name__ == '__main__':
    print('=== 自检 ===')
    if not selftest():
        sys.exit(1)
    print('  全部通过')

    orig = open(sys.argv[1], 'rb').read()
    patched = open(sys.argv[2], 'rb').read()
    base, SITES = 0x40000000, [0xB660, 0xB770, 0xB8C0, 0xB8F8, 0xB92C]

    print('\n=== 5 处补丁点（原始镜像） ===')
    targets, errs = [], []
    for s in SITES:
        print(f'[site 0x{s:05x}]')
        for i in range(4):
            off = s + i * 4
            w = struct.unpack_from('<I', orig, off)[0]
            print(f'    {off:06x}  {w:08x}  {decode(w, base + off)}')
        w0 = struct.unpack_from('<I', orig, s)[0]
        w2 = struct.unpack_from('<I', orig, s + 8)[0]
        targets.append(s + (sx(w0 & 0x3FFFFFF, 26) << 2))
        errs.append((w2 >> 5) & 0xFFFF)

    print('\n=== 目标收敛性 ===')
    for t in sorted(set(targets)):
        print(f'  0x{t:05x} 被调用 {targets.count(t)} 次')
    print('  各点错误码:', [hex(e) for e in errs])

    dump(orig, base, 0xB9C8, 8, '共享校验入口（thunk）')
    dump(orig, base, 0xCD00, 24, 'thunk 真正的去向 0x0CD00')
    dump(orig, base, 0x1BD0, 10, '错误上报 0x01BD0')
    dump(orig, base, 0x1B34, 10, '信息打印 0x01B34')
