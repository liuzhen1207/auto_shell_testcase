#!/usr/bin/env python3
"""定位明文口令在 Raft 日志中的精确上下文（含 plan 结构解读）。"""
import io, os, re

BASE = r"D:\IDEA\deepseek\ip99_80\sec_skill\artifacts"
WORK = os.path.join(BASE, "raftlog_extract")
cred = io.open(os.path.join(BASE, "cred_20261117_105111.txt"), encoding="utf-8").read()
user = re.search(r"^user=(.+)$", cred, re.M).group(1).strip()
pw1 = re.search(r"^pw1=(.+)$", cred, re.M).group(1).strip()
pw2 = re.search(r"^pw2=(.+)$", cred, re.M).group(1).strip()

def dump(path, needle, name, before=64, after=64):
    data = io.open(path, "rb").read()
    off = data.find(needle.encode())
    if off < 0:
        print(f"[{name}] 未找到于 {path}")
        return None
    a, b = max(0, off - before), min(len(data), off + len(needle) + after)
    chunk = data[a:b]
    print(f"\n===== {name} =====")
    print(f"file : {os.path.relpath(path, WORK)}")
    print(f"offset: {off} (0x{off:x})  file_size={len(data)}")
    print("hex  :")
    for i in range(0, len(chunk), 16):
        seg = chunk[i:i+16]
        hx = " ".join(f"{c:02x}" for c in seg)
        asc = "".join(chr(c) if 32 <= c < 127 else "." for c in seg)
        print(f"  {a+i:08x}  {hx:<47}  {asc}")
    return off

for node in ("node_77", "node_78", "node_79"):
    d = os.path.join(WORK, node, "data", "confignode", "consensus",
                     "47474747-4747-4747-4747-000000000000", "current")
    if not os.path.isdir(d):
        continue
    for fn in sorted(os.listdir(d)):
        if not fn.startswith("log"):
            continue
        p = os.path.join(d, fn)
        o1 = dump(p, pw1, f"{node}/{fn} 明文 pw1 (CREATE)")
        o2 = dump(p, pw2, f"{node}/{fn} 明文 pw2 (ALTER)")
        if o1 is not None:
            # 该条目起点：向前找 0x72/0x0a 之类不可靠，这里直接给出计划结构推断
            print("  说明：该区域为 Raft LogEntry 的 stateMachineData（ConfigPhysicalPlan 序列化字节），")
            print("        其中可见 userName 与紧随其后的 password/newPassword 明文。")

# 检查用户 profile 是否含明文
print("\n===== 用户 profile 是否含明文口令 =====")
found = False
for root, _, fs in os.walk(os.path.join(WORK, "node_77", "data", "confignode", "system", "users")):
    for fn in fs:
        p = os.path.join(root, fn)
        data = io.open(p, "rb").read()
        if pw1.encode() in data or pw2.encode() in data:
            print(f"  !! 命中明文: {fn}")
            found = True
print("  profile 命中明文:", "是" if found else "否（存的是哈希）")
