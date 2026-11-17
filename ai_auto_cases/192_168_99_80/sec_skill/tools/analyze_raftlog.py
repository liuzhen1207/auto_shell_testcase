#!/usr/bin/env python3
"""本地分析 CN 共识日志：检索明文口令 / 用户名 / sha256，并尝试识别条目体编码。"""
import gzip, io, os, re, tarfile, zlib

BASE = r"D:\IDEA\deepseek\ip99_80\sec_skill\artifacts"
TGZ = os.path.join(BASE, "raftlog_20261117_105111.tgz")
WORK = os.path.join(BASE, "raftlog_extract")
os.makedirs(WORK, exist_ok=True)

# 1) 解包外层，再解包每节点
with tarfile.open(TGZ, "r:gz") as tf:
    tf.extractall(WORK)
for n in ("node_77.tgz", "node_78.tgz", "node_79.tgz"):
    p = os.path.join(WORK, n)
    if not os.path.exists(p):
        continue
    d = os.path.join(WORK, n.replace(".tgz", ""))
    os.makedirs(d, exist_ok=True)
    with tarfile.open(p, "r:gz") as tf:
        tf.extractall(d)

cred = io.open(os.path.join(BASE, "cred_20261117_105111.txt"), encoding="utf-8").read()
user = re.search(r"^user=(.+)$", cred, re.M).group(1).strip()
pw1 = re.search(r"^pw1=(.+)$", cred, re.M).group(1).strip()
pw2 = re.search(r"^pw2=(.+)$", cred, re.M).group(1).strip()
sha1 = re.search(r"^sha256_pw1=(.+)$", cred, re.M).group(1).strip()
sha2 = re.search(r"^sha256_pw2=(.+)$", cred, re.M).group(1).strip()
print(f"user={user}\npw1={pw1}\npw2={pw2}\nsha1={sha1}\nsha2={sha2}\n")

needles = {
    "plain_pw1": pw1.encode(),
    "plain_pw2": pw2.encode(),
    "username": user.encode(),
    "sha256_pw1_hex": sha1.encode(),
    "sha256_pw2_hex": sha2.encode(),
    "sha256_pw1_raw": bytes.fromhex(sha1),
    "sha256_pw2_raw": bytes.fromhex(sha2),
}

hits = {k: [] for k in needles}
files = []
for root, _, fs in os.walk(WORK):
    for fn in fs:
        if fn.endswith((".tgz",)):
            continue
        p = os.path.join(root, fn)
        files.append(p)

print(f"待扫描文件 {len(files)} 个\n")
for p in files:
    try:
        data = io.open(p, "rb").read()
    except Exception as e:
        print("读取失败", p, e); continue
    rel = os.path.relpath(p, WORK)
    for k, nd in needles.items():
        idx = data.find(nd)
        if idx >= 0:
            hits[k].append((rel, idx, len(data)))

print("== 命中汇总 ==")
for k, lst in hits.items():
    print(f"  {k}: {len(lst)} 处")
    for rel, off, size in lst[:5]:
        print(f"     {rel} @{off} (size={size})")

# 若命中用户名，打印上下文（hex+dump）
def show_context(needle, rel, off, span=96):
    p = os.path.join(WORK, rel)
    data = io.open(p, "rb").read()
    a = max(0, off - span); b = min(len(data), off + len(needle) + span)
    chunk = data[a:b]
    print(f"\n--- {rel} @{off} ---")
    hx = chunk.hex()
    print("hex:", " ".join(hx[i:i+2] for i in range(0, len(hx), 2))[:600])
    print("ascii:", "".join(chr(c) if 32 <= c < 127 else "." for c in chunk)[:400])

if hits["username"]:
    rel, off, _ = hits["username"][0]
    show_context(needles["username"], rel, off)
elif hits["plain_pw1"]:
    rel, off, _ = hits["plain_pw1"][0]
    show_context(needles["plain_pw1"], rel, off)
else:
    print("\n用户名/明文均未在日志与 profile 中出现 —— 打印 users 目录样例与日志头部做对比")
    # 打印一个 user profile 的十六进制
    for p in files:
        if p.endswith(".profile") and os.path.getsize(p) > 20:
            data = io.open(p, "rb").read()
            print(f"\n--- 样例 profile: {os.path.relpath(p, WORK)} ({len(data)}B) ---")
            hx = data.hex()
            print("hex:", " ".join(hx[i:i+2] for i in range(0, min(len(hx), 240), 2)))
            print("ascii:", "".join(chr(c) if 32 <= c < 127 else "." for c in data[:120]))
            break
    # 打印日志文件头
    for p in files:
        if "log_0" in os.path.basename(p) or "log_inprogress" in os.path.basename(p):
            data = io.open(p, "rb").read()
            print(f"\n--- 日志头: {os.path.relpath(p, WORK)} ({len(data)}B) ---")
            hx = data[:160].hex()
            print("hex:", " ".join(hx[i:i+2] for i in range(0, len(hx), 2)))
            print("ascii:", "".join(chr(c) if 32 <= c < 127 else "." for c in data[:160]))
            break
