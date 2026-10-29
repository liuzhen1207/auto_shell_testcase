#!/bin/bash
# ============================================================================
# 把暂存目录（/tmp/stage，保持相对 skill 根的路径）里的文件**原子**安装到 skill 目录：
#   cp 到同目录隐藏名 + mv -f —— bash 是"按 fd 增量读"脚本的，就地覆盖正在跑的用例
#   会读到错位内容；mv 只换目录项，正在跑的进程继续读旧 inode，安全。
#   安装前对 .sh 做 LF 归一 + `bash -n` 语法检查，任一失败即报错退出。
# 用法： bash tools/install_staged.sh [/tmp/stage]
# ============================================================================
set -uo pipefail
SKILL=/data/iotdb/autotest/compaction_skill
SRC=${1:-/tmp/stage}
cd "$SRC" || { echo "找不到暂存目录 $SRC"; exit 1; }
bad=0
while IFS= read -r f; do
  rel=${f#./}
  tgt="$SKILL/$rel"
  d=$(dirname "$tgt")
  [ -d "$d" ] || { echo "  !! 目标目录不存在：$d"; bad=1; continue; }
  case "$rel" in
    *.sh)
      sed -i 's/\r$//' "$f"
      if ! bash -n "$f"; then echo "  !! 语法错误：$rel"; bad=1; continue; fi
      ;;
  esac
  if cp "$f" "$d/.stage.new" && mv -f "$d/.stage.new" "$tgt"; then
    case "$rel" in *.sh) chmod +x "$tgt";; esac
    echo "  装入 $rel"
  else
    echo "  !! 安装失败：$rel"; bad=1
  fi
done < <(find . -type f | sort)
if [ "$bad" = 0 ]; then echo "全部安装成功"; else echo "有失败项"; fi
exit "$bad"
