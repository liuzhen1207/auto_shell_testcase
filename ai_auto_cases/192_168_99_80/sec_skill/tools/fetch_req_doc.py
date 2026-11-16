#!/usr/bin/env python3
# 用飞书应用凭证拉取指定 docx 文档正文
import json, os, re, sys, urllib.request, urllib.error

DOC = "HSHJdPdeMo9hnYxnyaAc7bHxn22"
APP_ID = "cli_a9395bcdacb89bc8"
SRC = r"D:\IDEA\ClaudeCode\feishu\dist\index.js"
OUT = r"D:\IDEA\deepseek\ip99_80\sec_skill\docs\req_raw.md"

def app_secret():
    src = open(SRC, "r", encoding="utf-8", errors="ignore").read()
    m = re.search(r'FEISHU_APP_SECRET\s*=\s*process\.env\.FEISHU_APP_SECRET\s*\|\|\s*"([^"]+)"', src)
    if not m:
        m = re.search(r'FEISHU_APP_SECRET["\']?\s*[:=]\s*["\']([a-zA-Z0-9]{20,})["\']', src)
    if not m:
        sys.exit("没找到 app_secret")
    return m.group(1)

def req(url, tok=None, data=None):
    h = {"Content-Type": "application/json; charset=utf-8"}
    if tok:
        h["Authorization"] = "Bearer " + tok
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(url, data=body, headers=h, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(r, timeout=40) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except Exception:
            return {"code": -1, "msg": f"HTTP {e.code}"}
    except Exception as e:
        return {"code": -2, "msg": str(e)}

secret = app_secret()
t = req("https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        data={"app_id": APP_ID, "app_secret": secret})
if t.get("code") != 0:
    sys.exit(f"token 失败: {t}")
tok = t["tenant_access_token"]
print("token ok")

# 1) 新版 docx raw_content
r = req(f"https://open.feishu.cn/open-apis/docx/v1/documents/{DOC}/raw_content", tok)
print("raw_content:", r.get("code"), r.get("msg"))
if r.get("code") == 0:
    content = (r.get("data") or {}).get("content", "")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w", encoding="utf-8").write(content)
    print("长度:", len(content), "→", OUT)
    print("前 600 字:\n" + content[:600])
    sys.exit(0)

# 2) blocks 兜底
r2 = req(f"https://open.feishu.cn/open-apis/docx/v1/documents/{DOC}/blocks?page_size=500", tok)
print("blocks:", r2.get("code"), r2.get("msg"))
if r2.get("code") == 0:
    items = (r2.get("data") or {}).get("items") or []
    print("blocks 数:", len(items))
    lines = []
    for b in items:
        for k in ("text", "heading1", "heading2", "heading3", "bullet", "ordered", "code", "quote"):
            v = b.get(k)
            if isinstance(v, dict) and v.get("elements"):
                txt = "".join(e.get("text_run", {}).get("content", "") for e in v["elements"])
                if txt.strip():
                    lines.append(txt)
    content = "\n".join(lines)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w", encoding="utf-8").write(content)
    print("拼出长度:", len(content), "→", OUT)
    print("前 600 字:\n" + content[:600])
    sys.exit(0)

print("两种方式都失败；可能需要把文档共享给应用（或改用 wiki 节点接口）")
