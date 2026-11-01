"""解析 spd_dump --verbose 2 抓包日志，统计 BROM 协议报文。

帧格式（实测）：
    0x7E | channel:1 | type:1 | size:2(LE) | payload:size | crc:2 | 0x7E
    转义：0x7D 0x5E -> 0x7E, 0x7D 0x5D -> 0x7D
"""
import re, json, sys
from collections import Counter, OrderedDict

LOG = r"C:\Users\DINGJINJIN\Downloads\Compressed\_dump\session4.log"
OUT = r"C:\Users\DINGJINJIN\Downloads\Compressed\_dump\brom_proto.json"

dir_pat = re.compile(r"^(send|recv) \((\d+)\)")
hex_pat = re.compile(r"^\s*((?:[0-9a-f]{2} ){1,16})")

TYPE_NAME = {
    0x00: "CONNECT / 连接握手",
    0x01: "START_DATA / 开始传输",
    0x02: "MID_DATA / 数据块",
    0x03: "END_DATA / 结束传输",
    0x04: "EXEC / 执行已发送镜像",
    0x05: "FLUSH / 复位",
    0x0A: "ERASE / 擦除扇区",
    0x0D: "SET_BAUD / 设置波特率",
    0x10: "READ_START / 读分区起始",
    0x11: "READ_MID / 读分区数据",
    0x12: "READ_END / 读分区结束",
    0x21: "EXEC_DATA / 执行数据段",
    0x28: "ENABLE_RAW / 开启原始数据模式",
    0x33: "CHECK_BAUD / 波特率协商",
    0x80: "ACK / 应答",
    0x81: "BSL_REP_VER / 版本应答",
    0x93: "READ_RESP / 读数据应答",
    0x96: "EXEC_RESP / 执行应答",
}

def unframe(buf: bytes):
    if not buf or buf[0] != 0x7E:
        return None
    body = buf[1:]
    if body and body[-1] == 0x7E:
        body = body[:-1]
    out = bytearray()
    i = 0
    while i < len(body):
        if body[i] == 0x7D and i + 1 < len(body):
            out.append(body[i + 1] ^ 0x20)
            i += 2
        else:
            out.append(body[i])
            i += 1
    return bytes(out)

def parse(path):
    packets = []
    cur_dir = None
    need = 0
    buf = bytearray()
    with open(path, "rb") as f:
        for raw in f:
            line = raw.decode("ascii", "ignore")
            m = dir_pat.match(line)
            if m:
                if cur_dir and buf:
                    packets.append((cur_dir, bytes(buf)))
                cur_dir, need, buf = m.group(1), int(m.group(2)), bytearray()
                continue
            h = hex_pat.match(line)
            if h and cur_dir:
                buf.extend(bytes.fromhex(h.group(1).replace(" ", "")))
                if len(buf) >= need:
                    packets.append((cur_dir, bytes(buf)))
                    buf = bytearray()
        if cur_dir and buf:
            packets.append((cur_dir, bytes(buf)))
    return packets

def main():
    packets = parse(LOG)
    stats = OrderedDict()
    stats["total_frames"] = len(packets)
    stats["by_dir"] = dict(Counter(d for d, _ in packets))

    hist = Counter()
    bad = Counter()
    payload_bytes = 0
    chans = Counter()
    crlfail = 0
    parsed = []
    for d, b in packets:
        body = unframe(b)
        if body is None:
            bad["unframed"] += 1
            continue
        if len(body) < 4:
            bad["short"] += 1
            continue
        ch, typ = body[0], body[1]
        size = body[2] | (body[3] << 8)
        payload = body[4:4 + size]
        chans[ch] += 1
        hist[typ] += 1
        payload_bytes += len(payload)
        parsed.append({"dir": d, "type": typ, "size": size})
        if len(payload) != size:
            crlfail += 1

    stats["channel_hist"] = {f"0x{k:02x}": v for k, v in chans.most_common(5)}
    stats["type_hist"] = [
        {"type": f"0x{k:02x}", "name": TYPE_NAME.get(k, "（未命名）"), "count": v}
        for k, v in hist.most_common()
    ]
    stats["payload_bytes"] = payload_bytes
    stats["bad_frames"] = dict(bad)

    # 单条会话的报文序列（取第一段连续 send，最多 40 帧）
    seq = []
    for p in parsed[:60]:
        seq.append(f'{p["dir"]} 0x{p["type"]:02x}({p["size"]})')
    stats["first_60_frames"] = seq

    # 统计各类型报文的大小分布
    size_by_type = {}
    for p in parsed:
        size_by_type.setdefault(p["type"], Counter())[p["size"]] += 1
    stats["size_by_type"] = {
        f"0x{k:02x}": [{"size": s, "count": c} for s, c in v.most_common(3)]
        for k, v in size_by_type.items()
    }

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)
    print("frames:", stats["total_frames"], "payload bytes:", payload_bytes)
    for row in stats["type_hist"]:
        print(f'  {row["type"]}  {row["name"]:<28} {row["count"]}')
    print("size_by_type sample:", json.dumps(stats["size_by_type"], ensure_ascii=False)[:300])

if __name__ == "__main__":
    main()
