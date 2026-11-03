import json, os, re, sys, time, urllib.request

APP_ID = "cli_a9395bcdacb89bc8"
APP_SECRET = None
# 从 MCP 源码里读 app_secret，避免硬编码
src = open(r"D:\IDEA\ClaudeCode\feishu\dist\index.js", "r", encoding="utf-8", errors="ignore").read()
m = re.search(r'FEISHU_APP_SECRET\s*=\s*process\.env\.FEISHU_APP_SECRET\s*\|\|\s*"([^"]+)"', src)
APP_SECRET = m.group(1)

def post(url, data, token=None):
    body = json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/json; charset=utf-8",
        **({"Authorization": "Bearer " + token} if token else {})
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

def get(url, token):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

tok = post("https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
           {"app_id": APP_ID, "app_secret": APP_SECRET})["tenant_access_token"]
base = os.path.dirname(os.path.abspath(__file__))
print("token ok", flush=True)

files = json.load(open(os.path.join(base, "fs_files.json"), encoding="utf-8-sig"))
docs = [f for f in files if f.get("type") == "docx"]
print("docs:", len(docs), flush=True)

outdir = os.path.join(base, "feishu_docs")
os.makedirs(outdir, exist_ok=True)
index = []
ok = fail = 0
for i, d in enumerate(docs, 1):
    name, token = d["name"], d["token"]
    num = None
    mm = re.search(r"TIMECHODB-(\d+)", name)
    if mm:
        num = mm.group(1)
    fn = (num or token) + ".md"
    path = os.path.join(outdir, fn)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        ok += 1
        index.append({"num": num, "name": name, "token": token, "file": fn})
        continue
    try:
        r = get(f"https://open.feishu.cn/open-apis/docx/v1/documents/{token}/raw_content", tok)
        content = r.get("data", {}).get("content", "")
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        index.append({"num": num, "name": name, "token": token, "file": fn, "len": len(content)})
        ok += 1
    except Exception as e:
        fail += 1
        index.append({"num": num, "name": name, "token": token, "file": None, "err": str(e)[:80]})
    if i % 50 == 0:
        print(f"progress {i}/{len(docs)} ok={ok} fail={fail}", flush=True)
    time.sleep(0.12)

with open(os.path.join(base, "feishu_index.json"), "w", encoding="utf-8") as f:
    json.dump(index, f, ensure_ascii=False, indent=1)
print(f"DONE ok={ok} fail={fail}")
