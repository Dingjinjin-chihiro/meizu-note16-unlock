"""用 Capstone（ARM64）对 SPL 做权威反汇编，并与自研解码器结果对照。"""
import sys, json, struct
sys.path.insert(0, r"C:\Users\DINGJINJIN\Downloads\Compressed\_pylibs")
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

ORIG = r"C:\Users\DINGJINJIN\Downloads\Compressed\_backup\splloader.bin"
PATCHED = r"C:\Users\DINGJINJIN\Downloads\Compressed\ums9621_Meizu_Note16\spl-unlock.bin"
BASE = 0x40000000
SITES = [0xB660, 0xB770, 0xB8C0, 0xB8F8, 0xB92C]

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = False

def dis(blob, off, count, base=BASE):
    out = []
    for i in range(count):
        o = off + i * 4
        if o + 4 > len(blob):
            break
        code = blob[o:o + 4]
        g = list(md.disasm(code, base + o))
        if g:
            ins = g[0]
            out.append((base + o, ins.mnemonic, ins.op_str))
        else:
            out.append((base + o, "dw", "0x" + code.hex()))
    return out

orig = open(ORIG, "rb").read()
patched = open(PATCHED, "rb").read()

print("=" * 78)
print("Capstone", __import__("capstone").__version__, "| ARM64 | base 0x%x" % BASE)
print("=" * 78)

print("\n[1] 五处补丁点（原始镜像，含上下文）")
targets = []
for s in SITES:
    print(f"\n--- site 0x{s:05X} ---")
    for (a, m, o), i in zip(dis(orig, s - 8, 8), range(-2, 6)):
        mark = "  <== NOP 覆盖" if 0 <= i < 4 else ""
        print(f"  0x{a:08X}  {m:<8}{o}{mark}")
    w0 = struct.unpack_from("<I", orig, s)[0]
    imm = w0 & 0x3FFFFFF
    if imm & 0x2000000:
        imm -= 0x4000000
    tgt = s + (imm << 2)
    targets.append(tgt)

print("\n[2] 调用目标收敛性")
print("   ", sorted(set(targets)), " 唯一目标数:", len(set(targets)))

print("\n[3] 共享入口 0x0B9C8")
for a, m, o in dis(orig, 0xB9C8, 4):
    print(f"  0x{a:08X}  {m:<8}{o}")

print("\n[4] 真正的校验函数 0x0CD00（前 40 条）")
for a, m, o in dis(orig, 0xCD00, 40):
    print(f"  0x{a:08X}  {m:<8}{o}")

print("\n[5] 错误上报 0x1BD0（前 16 条）")
for a, m, o in dis(orig, 0x1BD0, 16):
    print(f"  0x{a:08X}  {m:<8}{o}")

print("\n[6] 补丁后（spl-unlock.bin）五处内容")
for s in SITES:
    row = " ".join(f"{struct.unpack_from('<I', patched, s+i*4)[0]:08x}" for i in range(4))
    print(f"  0x{s:05X}: {row}")
    print("           " + " | ".join(f"{m} {o}" for _, m, o in dis(patched, s, 4)))

print("\n[7] 校验函数被谁调用（全镜像扫描 bl 0x0CD00）")
callers = []
for i in range(0, len(orig) - 3, 4):
    w = struct.unpack_from("<I", orig, i)[0]
    if (w >> 26) == 0x25:
        imm = w & 0x3FFFFFF
        if imm & 0x2000000:
            imm -= 0x4000000
        if i + (imm << 2) == 0xCD00:
            callers.append(i)
print("   直接调用 0x0CD00 的位置:", [hex(c) for c in callers])
