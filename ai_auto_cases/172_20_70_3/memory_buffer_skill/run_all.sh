#!/bin/bash
# 便捷入口：等价于 bash tools/run_all.sh
exec bash "$(cd "$(dirname "$0")" && pwd)/tools/run_all.sh" "$@"
