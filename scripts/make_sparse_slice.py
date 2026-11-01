"""生成 sparse 镜像：只写 [start, start+window) 区间，其余标记 DONT_CARE。

用途：fastbootd 的写入会话约 70 秒超时，无法一次写完 10 GiB。
     用 DONT_CARE 跳过已写区域，让每次会话只搬运一段新数据。
"""
import struct, sys, os

BLK = 4096
MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_DONTCARE = 0xCAC3
MAX_CHUNK_BLKS = 256          # 1 MiB per chunk

def build(src_path, dst_path, start_byte, end_byte, total_bytes):
    start_blk = start_byte // BLK
    end_blk = end_byte // BLK
    total_blk = total_bytes // BLK
    if start_blk * BLK != start_byte or end_blk * BLK != end_byte:
        raise SystemExit("偏移必须 4096 对齐")

    chunks = []
    if start_blk > 0:
        chunks.append((CHUNK_DONTCARE, start_blk))
    n = end_blk - start_blk
    while n > 0:
        c = min(MAX_CHUNK_BLKS, n)
        chunks.append((CHUNK_RAW, c))
        n -= c
    if end_blk < total_blk:
        chunks.append((CHUNK_DONTCARE, total_blk - end_blk))

    with open(src_path, "rb") as fin, open(dst_path, "wb") as fout:
        total_chunks = len(chunks)
        fout.write(struct.pack("<IHHHHIIII", MAGIC, 1, 0, 28, 12, BLK,
                               total_blk, total_chunks, 0))
        fin.seek(start_blk * BLK)
        for ctype, csz in chunks:
            if ctype == CHUNK_DONTCARE:
                fout.write(struct.pack("<HHII", ctype, 0, csz, 12))
            else:
                payload = fin.read(csz * BLK)
                if len(payload) != csz * BLK:
                    raise SystemExit("源文件长度不足")
                fout.write(struct.pack("<HHII", ctype, 0, csz, 12 + len(payload)))
                fout.write(payload)
    return os.path.getsize(dst_path)

if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    start = int(sys.argv[3])
    end = int(sys.argv[4])
    total = int(sys.argv[5])
    size = build(src, dst, start, end, total)
    print(f"{dst}  write=[{start:,}..{end:,})  file={size/1048576:.1f} MB")
