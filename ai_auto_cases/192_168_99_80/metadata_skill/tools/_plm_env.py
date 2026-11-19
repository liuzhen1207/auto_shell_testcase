import io, os, shutil

src = r"D:\IDEA\deepseek\ip99_80\metadata_skill"
dst = r"D:\IDEA\deepseek\_repo_auto_shell_testcase\ai_auto_cases\192_168_99_80\metadata_skill"
os.makedirs(dst, exist_ok=True)
for sub in ("cases", "lib", "conf", "tools", "docs", "assets"):
    s = os.path.join(src, sub)
    if os.path.isdir(s):
        shutil.copytree(s, os.path.join(dst, sub), dirs_exist_ok=True)
for f in ("SKILL.md", "README.md"):
    p = os.path.join(src, f)
    if os.path.exists(p):
        shutil.copy2(p, os.path.join(dst, f))
print("已复制 metadata_skill 到仓库")

p = os.path.join(dst, "conf", "env.conf")
s = io.open(p, encoding="utf-8").read()

old = '''CLUSTER_NODES="${CLUSTER_NODES:-192.168.99.77 192.168.99.78 192.168.99.79}"
CN_NODES="${CN_NODES:-$CLUSTER_NODES}"
DN_NODES="${DN_NODES:-$CLUSTER_NODES}"
SSH_USER="${SSH_USER:-root}"'''
new = '''# PLM 注入优先（PVE 实例）：有 PLM_DB_HOME 时按实例路径推导，否则用本地默认
if [ -n "${PLM_DB_HOME:-}" ]; then
  _md_plm_parent="$(dirname "$PLM_DB_HOME")"
  _md_plm_ver="$(basename "$PLM_DB_HOME")"
else
  _md_plm_parent="/data/iotdb"
  _md_plm_ver="v20121rc5_1003_aaf460d"
fi
[ -n "${PLM_DB_VERSION:-}" ] && _md_plm_ver="$PLM_DB_VERSION"

CLUSTER_NODES="${CLUSTER_NODES:-${PLM_CLUSTER_DN_NODES:-192.168.99.77 192.168.99.78 192.168.99.79}}"
CN_NODES="${CN_NODES:-${PLM_CLUSTER_CN_NODES:-$CLUSTER_NODES}}"
DN_NODES="${DN_NODES:-${PLM_CLUSTER_DN_NODES:-$CLUSTER_NODES}}"
SSH_USER="${SSH_USER:-${PLM_SSH_USER:-root}}"'''
if old in s:
    s = s.replace(old, new, 1)
else:
    print("!! CLUSTER/SSH 段未匹配")

reps = {
 'DB_PARENT_DIR="${DB_PARENT_DIR:-/data/iotdb}"': 'DB_PARENT_DIR="${DB_PARENT_DIR:-${PLM_PARENT_DIR:-$_md_plm_parent}}"',
 'SHELL_CLIENT_DIR="${SHELL_CLIENT_DIR:-/data/iotdb/testdb}"': 'SHELL_CLIENT_DIR="${SHELL_CLIENT_DIR:-${PLM_PARENT_DIR:-$_md_plm_parent}}"',
 'V_TESTDB="${V_TESTDB:-v20121rc5_1003_aaf460d}"': 'V_TESTDB="${V_TESTDB:-$_md_plm_ver}"',
 'ROOT_PW="${ROOT_PW:-TimechoDB@2021}"': 'ROOT_PW="${ROOT_PW:-${PLM_DB_PASSWORD:-TimechoDB@2021}}"',
}
for a, b in reps.items():
    if a in s:
        s = s.replace(a, b, 1)
    else:
        print("!! 未匹配:", a[:60])

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("metadata env.conf 已按 PLM 注入改造")
