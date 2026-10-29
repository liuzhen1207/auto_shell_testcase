"""Entry point so `python3 -m pgkit` behaves like `scripts/pg.sh`.

``SIGUSR1`` 打印当前所有线程的 Python 栈（faulthandler）。长跑（25 节点 × 上百条 ssh）
里若某一步卡住，``kill -USR1 <pid>`` 就能把卡点写进 run.log，不必重现。
"""
from __future__ import annotations

import faulthandler
import signal
import sys

from .cli import main

faulthandler.register(signal.SIGUSR1, all_threads=True)

if __name__ == "__main__":
    sys.exit(main())
