"""把裸二进制包装成最小的 ELF64 (EM_AARCH64)，便于 IDA 自动识别为 ARM64。"""
import struct, sys, os

def wrap(src, dst, base=0x40000000, entry_off=0):
    data = open(src, 'rb').read()
    # ELF64 头 64 字节
    e_ident = b'\x7fELF' + bytes([2, 1, 1, 0]) + b'\x00' * 8   # 64bit, LE, v1, SysV
    ehdr = e_ident + struct.pack('<HHIQQQIHHHHHH',
        2,          # e_type = ET_EXEC
        183,        # e_machine = EM_AARCH64
        1,          # e_version
        base + entry_off,  # e_entry
        64,         # e_phoff
        0,          # e_shoff
        0,          # e_flags
        64,         # e_ehsize
        56,         # e_phentsize
        1,          # e_phnum
        0, 0, 0)    # shentsize/shnum/shstrndx
    phdr = struct.pack('<IIQQQQQQ',
        1,          # p_type = PT_LOAD
        5,          # p_flags = R|X
        0,          # p_offset
        base,       # p_vaddr
        base,       # p_paddr
        len(data),  # p_filesz
        len(data),  # p_memsz
        0x1000)     # p_align
    with open(dst, 'wb') as f:
        f.write(ehdr)   # 64
        f.write(phdr)   # 56
        f.write(data)
        pad = (-(120 + len(data))) % 16
        f.write(b'\x00' * pad)
    return 120 + len(data)

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    base = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x40000000
    n = wrap(src, dst, base)
    print(f'{src} -> {dst}  ({n} bytes, base=0x{base:x})')
