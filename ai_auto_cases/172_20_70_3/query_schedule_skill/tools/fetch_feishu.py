#!/usr/bin/env python3
"""从飞书拉取需求文档到 feishu_src/。

用法:
  python3 tools/fetch_feishu.py <folder_token> [--recursive]

支持: docx（新版文档）、doc（旧版文档）。表格/多维表格只记录链接。
"""
import json, os, re, sys, urllib.request, urllib.error

ENV = '/data/deepseek/skill_case_ip3_3c5d/.feishu.env'
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'feishu_src')

def load_env():
    e = {}
    for line in open(ENV):
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1); e[k.strip()] = v.strip()
    return e

def _req(url, tok=None, data=None):
    headers = {'Content-Type': 'application/json; charset=utf-8'}
    if tok: headers['Authorization'] = f'Bearer {tok}'
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers,
                                 method='POST' if data is not None else 'GET')
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())

def token(env):
    r = _req('https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal',
             data={'app_id': env['FEISHU_APP_ID'], 'app_secret': env['FEISHU_APP_SECRET']})
    if r.get('code') != 0:
        sys.exit(f"获取 token 失败: {r}")
    return r['tenant_access_token']

def list_folder(tok, folder):
    files, page = [], ''
    while True:
        u = f'https://open.feishu.cn/open-apis/drive/v1/files?folder_token={folder}&page_size=200'
        if page: u += f'&page_token={page}'
        r = _req(u, tok)
        if r.get('code') != 0:
            return None, r
        d = r.get('data') or {}
        files += d.get('files') or []
        page = d.get('next_page_token') or ''
        if not page or not d.get('has_more'): break
    return files, None

def raw_content(tok, ftype, ftoken):
    for url in (
        f'https://open.feishu.cn/open-apis/docx/v1/documents/{ftoken}/raw_content',
        f'https://open.feishu.cn/open-apis/doc/v2/{ftoken}/raw_content',
    ):
        r = _req(url, tok)
        if r.get('code') == 0:
            d = r.get('data') or {}
            return d.get('content') or d.get('raw_content') or ''
    return None

def safe(name):
    return re.sub(r'[/\\:*?"<>|]+', '_', name)[:80]

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    folder = sys.argv[1]
    recursive = '--recursive' in sys.argv
    os.makedirs(OUT, exist_ok=True)
    env = load_env(); tok = token(env)
    files, err = list_folder(tok, folder)
    if err:
        sys.exit(f"列目录失败: code={err.get('code')} msg={err.get('msg')} "
                 f"（请把该文件夹共享给应用 {env.get('FEISHU_APP_NAME','') or '对应应用'} 并授予「可阅读」）")
    print(f"共 {len(files)} 个条目")
    for f in files:
        t, name, ftoken = f.get('type'), f.get('name'), f.get('token')
        print(f" - {t:8s} {name}  ({ftoken})")
        if t in ('docx', 'doc'):
            c = raw_content(tok, t, ftoken)
            if c is None:
                print(f"     !! 拉取正文失败")
                continue
            path = os.path.join(OUT, f"{safe(name)}__{ftoken[:6]}.md")
            with open(path, 'w') as fh:
                fh.write(f"<!-- 飞书原文: {f.get('url','')} -->\n\n{c}")
            print(f"     -> {path} ({len(c)} 字符)")
        elif t == 'folder' and recursive:
            print(f"     (子目录，需单独运行: {ftoken})")

if __name__ == '__main__':
    main()
