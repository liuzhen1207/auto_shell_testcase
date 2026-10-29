# cases/ —— 用例清单

本 skill 的用例是 **Python 模块**，集中在 `../scripts/pgkit/`：

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `cases_treeview.py` | 41 | `TV-BASE-*`（15）基础语义、`TV-SYNC-*`（16）auto_sync、`TV-HA-*`（3）高可用、`TV-LEAK-*`（1）泄漏、`TV-REF-*`（6）参考用例回归 |
| `cases_tv_repro.py` | 5 | `TV-REPRO-D1..D5` 缺陷最小复现（断言"正确行为"，FAIL 即复现） |
| `cases_tv_pipe.py` | 9 | `TV-PIPE-01..09` Pipe 数据同步（双集群） |

`MANIFEST.md5` 记录这三个模块的 md5，用于 preflight 校验（清单与源码必须同步提交）。
全量文件清单见 `../MANIFEST.md5`。
