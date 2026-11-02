# TDB-65 关键证据摘要

全量原始输出（74 个文件）在测试机 `172.16.2.20:/data2/iotdb/rc10_matrix/rn_verify/TDB-65/evidence/`。
仓库按 `.gitignore` 约定不提交 `*.out`，此处内联关键片段。

## 1) 列数矩阵（3 接口 × 2 方言 × 3 状态）

| 状态 | 接口 | 方言 | SHOW CLUSTER | SHOW DATANODES | SHOW CONFIGNODES |
| --- | --- | --- | ---: | ---: | ---: |
| baseline | cli | tree | 8 | NA | NA |
| baseline | cli | table | 8 | NA | NA |
| baseline | session | tree | 8 | NA | NA |
| baseline | session | table | NA | NA | NA |
| baseline | jdbc | tree | NA | NA | NA |
| baseline | jdbc | table | 8 | NA | NA |
| readonly | cli | tree | 9 | 7 | 5 |
| readonly | cli | table | 9 | NA | NA |
| readonly | session | tree | 9 | NA | NA |
| readonly | session | table | 9 | NA | NA |
| readonly | jdbc | tree | 9 | NA | NA |
| readonly | jdbc | table | 9 | NA | NA |
| restored | cli | tree | 8 | NA | NA |
| restored | cli | table | NA | NA | NA |
| restored | session | tree | NA | NA | NA |
| restored | session | table | NA | NA | NA |
| restored | jdbc | tree | NA | NA | NA |
| restored | jdbc | table | NA | NA | NA |

## 2) ReadOnly 状态下 SHOW CLUSTER（CLI / tree）

```
|NodeID|  NodeType|  Status|InternalAddress|InternalPort| Version|BuildInfo|ActivateStatus|StatusReason|
+------+----------+--------+---------------+------------+--------+---------+--------------+------------+
|     0|ConfigNode| Running|    172.16.2.16|       10710|2.0.13.1|  ab6d3de|     ACTIVATED|        null|
|     1|ConfigNode| Running|    172.16.2.17|       10710|2.0.13.1|  ab6d3de|  ACTIVATED(W)|        null|
|     2|ConfigNode| Running|    172.16.2.18|       10710|2.0.13.1|  ab6d3de|  ACTIVATED(W)|        null|
|     3|  DataNode|ReadOnly|    172.16.2.23|       10730|2.0.13.1|  ab6d3de|     ACTIVATED|      Manual|
|     4|  DataNode|ReadOnly|    172.16.2.19|       10730|2.0.13.1|  ab6d3de|     ACTIVATED|      Manual|
|     5|  DataNode|ReadOnly|    172.16.2.24|       10730|2.0.13.1|  ab6d3de|     ACTIVATED|      Manual|
|     6|  DataNode|ReadOnly|    172.16.2.21|       10730|2.0.13.1|  ab6d3de|     ACTIVATED|      Manual|
|     7|  DataNode|ReadOnly|    172.16.2.22|       10730|2.0.13.1|  ab6d3de|     ACTIVATED|      Manual|
```

## 3) ReadOnly 状态下 SHOW DATANODES（CLI / tree）

```
|NodeID|  Status| RpcAddress|RpcPort|DataRegionNum|SchemaRegionNum|StatusReason|
+------+--------+-----------+-------+-------------+---------------+------------+
|     3|ReadOnly|172.16.2.23|   6667|            5|              2|      Manual|
|     4|ReadOnly|172.16.2.19|   6667|            4|              2|      Manual|
|     5|ReadOnly|172.16.2.24|   6667|            5|              2|      Manual|
|     6|ReadOnly|172.16.2.21|   6667|            4|              1|      Manual|
|     7|ReadOnly|172.16.2.22|   6667|            4|              2|      Manual|
+------+--------+-----------+-------+-------------+---------------+------------+
```

## 4) SHOW CLUSTER DETAILS 列（末列 StatusReason）

```
+------+----------+--------+---------------+------------+-------------------+-----------+-------+-------+-------------------+-----------------+--------+---------+--------------+------------+
|NodeID|  NodeType|  Status|InternalAddress|InternalPort|ConfigConsensusPort| RpcAddress|RpcPort|MppPort|SchemaConsensusPort|DataConsensusPort| Version|BuildInfo|ActivateStatus|StatusReason|
+------+----------+--------+---------------+------------+-------------------+-----------+-------+-------+-------------------+-----------------+--------+---------+--------------+------------+
```

## 5) CN leader 切换后 reason 仍在

```
|NodeID|  NodeType|  Status|InternalAddress|InternalPort| Version|BuildInfo|ActivateStatus|StatusReason|
|     3|  DataNode|ReadOnly|    172.16.2.23|       10730|2.0.13.1|  ab6d3de|     ACTIVATED|      Manual|
|     4|  DataNode|ReadOnly|    172.16.2.19|       10730|2.0.13.1|  ab6d3de|     ACTIVATED|      Manual|
|     5|  DataNode|ReadOnly|    172.16.2.24|       10730|2.0.13.1|  ab6d3de|     ACTIVATED|      Manual|
```

## 6) 重启 DN19 后该节点 reason 清除

```
|NodeID|  Status| RpcAddress|RpcPort|DataRegionNum|SchemaRegionNum|StatusReason|
|     3|ReadOnly|172.16.2.23|   6667|            5|              2|      Manual|
|     4| Running|172.16.2.19|   6667|            4|              2|        null|
|     5|ReadOnly|172.16.2.24|   6667|            5|              2|      Manual|
|     6|ReadOnly|172.16.2.21|   6667|            4|              1|      Manual|
|     7|ReadOnly|172.16.2.22|   6667|            4|              2|      Manual|
```

## 7) 基线（无原因，无 StatusReason 列）

```
+------+----------+-------+---------------+------------+--------+---------+--------------+
|NodeID|  NodeType| Status|InternalAddress|InternalPort| Version|BuildInfo|ActivateStatus|
+------+----------+-------+---------------+------------+--------+---------+--------------+
```
