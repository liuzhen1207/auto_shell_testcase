# LBAC 双模式对比（普通模式 vs 三权分立，160 条）

## 一、总览

| 模式 | 用例 | PASS | FAIL | SKIP |
| --- | ---: | ---: | ---: | ---: |
| 普通模式 | 160 | 150 | 0 | 10 |
| 三权分立 | 160 | 151 | 0 | 9 |

## 二、差异项（同 ID 判决不同）

- LB-157：普通=SKIP 三权分立=PASS

## 三、失败明细

### 普通模式
（无失败）

### 三权分立
（无失败）

## 四、SKIP 明细（三权分立）

- LB-143：待需求确认：TAG / TIME 列是否允许 SECURED WITH（需求未写，暂不判定）
- LB-144：表模型不支持 RENAME TABLE（RENAME 语法报 700），无法验证
- LB-146：表模型不支持 CREATE TABLE ... AS SELECT / LIKE（语法报 700），无继承路径
- LB-154：待需求确认：同一策略下 READ 与 WRITE 能否授予不同标签
- LB-158：待需求确认：导出链路（EXPORT / SELECT INTO）是否在 LBAC 检查范围
- LB-159：待需求确认：pipe / subscription 写入是否在 LBAC 检查范围
- LB-160：待需求确认：LOAD / 批量导入是否在 LBAC 检查范围
- LB-109：不适用（已确认）：可写视图源为树模型（VIEW FROM TREE），不做 LBAC 保护；逻辑视图场景见 LB-110
- LB-122：同上（可写视图写入检查）

## 五、逐条对照

| 用例 | 普通模式 | 三权分立 |
| --- | --- | --- |
| LB-142 | PASS | PASS |
| LB-143 | SKIP | SKIP |
| LB-144 | SKIP | SKIP |
| LB-145 | PASS | PASS |
| LB-146 | SKIP | SKIP |
| LB-147 | PASS | PASS |
| LB-148 | PASS | PASS |
| LB-149 | PASS | PASS |
| LB-150 | PASS | PASS |
| LB-151 | PASS | PASS |
| LB-152 | PASS | PASS |
| LB-153 | PASS | PASS |
| LB-154 | SKIP | SKIP |
| LB-155 | PASS | PASS |
| LB-156 | PASS | PASS |
| LB-157 | PASS | SKIP |
| LB-158 | SKIP | SKIP |
| LB-159 | SKIP | SKIP |
| LB-160 | SKIP | SKIP |
| LB-001 | PASS | PASS |
| LB-002 | PASS | PASS |
| LB-003 | PASS | PASS |
| LB-004 | PASS | PASS |
| LB-005 | PASS | PASS |
| LB-006 | PASS | PASS |
| LB-007 | PASS | PASS |
| LB-008 | PASS | PASS |
| LB-009 | PASS | PASS |
| LB-010 | PASS | PASS |
| LB-011 | PASS | PASS |
| LB-012 | PASS | PASS |
| LB-013 | PASS | PASS |
| LB-014 | PASS | PASS |
| LB-015 | PASS | PASS |
| LB-016 | PASS | PASS |
| LB-017 | PASS | PASS |
| LB-018 | PASS | PASS |
| LB-019 | PASS | PASS |
| LB-020 | PASS | PASS |
| LB-021 | PASS | PASS |
| LB-022 | PASS | PASS |
| LB-023 | PASS | PASS |
| LB-024 | PASS | PASS |
| LB-025 | PASS | PASS |
| LB-026 | PASS | PASS |
| LB-027 | PASS | PASS |
| LB-028 | PASS | PASS |
| LB-029 | PASS | PASS |
| LB-030 | PASS | PASS |
| LB-031 | PASS | PASS |
| LB-032 | PASS | PASS |
| LB-033 | PASS | PASS |
| LB-034 | PASS | PASS |
| LB-035 | PASS | PASS |
| LB-036 | PASS | PASS |
| LB-037 | PASS | PASS |
| LB-038 | PASS | PASS |
| LB-039 | PASS | PASS |
| LB-040 | PASS | PASS |
| LB-041 | PASS | PASS |
| LB-042 | PASS | PASS |
| LB-043 | PASS | PASS |
| LB-044 | PASS | PASS |
| LB-045 | PASS | PASS |
| LB-046 | PASS | PASS |
| LB-047 | PASS | PASS |
| LB-048 | PASS | PASS |
| LB-049 | PASS | PASS |
| LB-050 | PASS | PASS |
| LB-051 | PASS | PASS |
| LB-052 | PASS | PASS |
| LB-053 | PASS | PASS |
| LB-054 | PASS | PASS |
| LB-055 | PASS | PASS |
| LB-056 | PASS | PASS |
| LB-057 | PASS | PASS |
| LB-058 | PASS | PASS |
| LB-059 | PASS | PASS |
| LB-060 | PASS | PASS |
| LB-061 | PASS | PASS |
| LB-062 | PASS | PASS |
| LB-063 | PASS | PASS |
| LB-064 | PASS | PASS |
| LB-065 | PASS | PASS |
| LB-066 | PASS | PASS |
| LB-067 | PASS | PASS |
| LB-068 | PASS | PASS |
| LB-069 | PASS | PASS |
| LB-070 | PASS | PASS |
| LB-071 | PASS | PASS |
| LB-072 | PASS | PASS |
| LB-073 | PASS | PASS |
| LB-074 | PASS | PASS |
| LB-075 | PASS | PASS |
| LB-076 | PASS | PASS |
| LB-077 | PASS | PASS |
| LB-078 | PASS | PASS |
| LB-079 | PASS | PASS |
| LB-080 | PASS | PASS |
| LB-081 | PASS | PASS |
| LB-082 | PASS | PASS |
| LB-083 | PASS | PASS |
| LB-084 | PASS | PASS |
| LB-085 | PASS | PASS |
| LB-086 | PASS | PASS |
| LB-087 | PASS | PASS |
| LB-088 | PASS | PASS |
| LB-089 | PASS | PASS |
| LB-090 | PASS | PASS |
| LB-091 | PASS | PASS |
| LB-092 | PASS | PASS |
| LB-093 | PASS | PASS |
| LB-094 | PASS | PASS |
| LB-095 | PASS | PASS |
| LB-096 | PASS | PASS |
| LB-097 | PASS | PASS |
| LB-098 | PASS | PASS |
| LB-099 | PASS | PASS |
| LB-100 | PASS | PASS |
| LB-101 | PASS | PASS |
| LB-102 | PASS | PASS |
| LB-103 | PASS | PASS |
| LB-104 | PASS | PASS |
| LB-105 | PASS | PASS |
| LB-106 | PASS | PASS |
| LB-107 | PASS | PASS |
| LB-108 | PASS | PASS |
| LB-109 | SKIP | SKIP |
| LB-110 | PASS | PASS |
| LB-111 | PASS | PASS |
| LB-112 | PASS | PASS |
| LB-113 | PASS | PASS |
| LB-114 | PASS | PASS |
| LB-115 | PASS | PASS |
| LB-116 | PASS | PASS |
| LB-117 | PASS | PASS |
| LB-118 | PASS | PASS |
| LB-119 | PASS | PASS |
| LB-120 | PASS | PASS |
| LB-121 | PASS | PASS |
| LB-122 | SKIP | SKIP |
| LB-123 | PASS | PASS |
| LB-124 | PASS | PASS |
| LB-125 | PASS | PASS |
| LB-126 | PASS | PASS |
| LB-127 | PASS | PASS |
| LB-128 | PASS | PASS |
| LB-129 | PASS | PASS |
| LB-130 | PASS | PASS |
| LB-131 | PASS | PASS |
| LB-132 | PASS | PASS |
| LB-133 | PASS | PASS |
| LB-134 | PASS | PASS |
| LB-135 | PASS | PASS |
| LB-136 | PASS | PASS |
| LB-137 | PASS | PASS |
| LB-138 | PASS | PASS |
| LB-139 | PASS | PASS |
| LB-140 | PASS | PASS |
| LB-141 | PASS | PASS |
