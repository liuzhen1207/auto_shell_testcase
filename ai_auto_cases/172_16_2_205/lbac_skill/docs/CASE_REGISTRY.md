# LBAC 用例总账（回归对照基准）

> 本文件由 `tools/gen_registry.py` 自动生成，请勿手工编辑；新增/删改用例后重新生成。

> 回归前先跑 `python tools/check_cases.py`，确认用例清单、脚本函数、总账三者一致（防止遗漏）。


| 项 | 数量 |
| --- | ---: |
| 用例总数 | 197 |
| 常规执行 | 187 |
| 条件执行（仅三权分立） | 1 |
| 跳过（不适用/待确认） | 9 |

判决列说明：`io_*` = 2026-11-13 旧版 160 条（IoTConsensus）；`dr2_*` = 2026-11-17 最新 197 条（SR3/DR2）；`normal` = 普通模式；`sep` = 三权分立；`-` = 该轮未参与。

## 组件（29 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-001 | 正向 | CREATE ARRAY 组件成功且系统表可见 | 执行 | PASS | PASS | PASS | PASS |
| LB-002 | 正向 | CREATE SET 组件成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-003 | 正向 | CREATE TREE 组件成功（ROOT/UNDER 层级） | 执行 | PASS | PASS | PASS | PASS |
| LB-004 | 异常 | 组件重名报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-005 | 异常 | ARRAY 元素重复报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-006 | 异常 | SET 元素重复报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-007 | 异常 | TREE 节点跨分支重复报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-008 | 边界 | 元素含保留字符 (,): 报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-009 | 边界 | 空元素/空白元素报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-010 | 边界 | 元素长度超 32 bytes 报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-011 | 正向 | ALTER ARRAY ADD ELEMENT BEFORE/AFTER 位置正确 | 执行 | PASS | PASS | PASS | PASS |
| LB-012 | 正向 | ALTER SET ADD ELEMENT 无需位置 | 执行 | PASS | PASS | PASS | PASS |
| LB-013 | 正向 | ALTER TREE ADD ELEMENT UNDER 成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-014 | 边界 | ALTER TREE ADD ROOT 后原 ROOT 不再是 ROOT | 执行 | PASS | PASS | PASS | PASS |
| LB-015 | 异常 | ALTER ADD 已存在元素报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-016 | 异常 | TREE OVER 列表元素重复报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-017 | 异常 | TREE OVER 跨父节点报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-018 | 正向 | DROP 未被引用的组件成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-019 | 异常 | DROP 被 Policy 引用的组件报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-020 | 正向 | COMMENT ON COMPONENT 添加与替换备注 | 执行 | PASS | PASS | PASS | PASS |
| LB-161 | 边界 | 单元素组件可用；200 元素 ARRAY 的 ordinal 连续 | 执行 | - | - | PASS | PASS |
| LB-162 | 异常 | 零元素/缺类型参数的组件创建被拒 | 执行 | - | - | PASS | PASS |
| LB-163 | 异常 | 非法类型 LIST、TREE 无 ROOT、UNDER 不存在父被拒 | 执行 | - | - | PASS | PASS |
| LB-164 | 边界 | ARRAY 省略位置子句默认追加；SET 拒绝位置子句 | 执行 | - | - | PASS | PASS |
| LB-165 | 边界 | TREE OVER 重挂接成功、跨父/重复 OVER 被拒 | 执行 | - | - | PASS | PASS |
| LB-166 | 异常 | TREE 多个 ROOT 创建被拒、ADD ROOT 提升新根 | 执行 | - | - | PASS | PASS |
| LB-167 | 正向 | 新增元素后比较语义按新顺序生效 | 执行 | - | - | PASS | PASS |
| LB-168 | 异常 | 组件类型不可变更（ALTER ... SET） | 执行 | - | - | PASS | PASS |
| LB-181 | 反向 | 无 SECURITY 用户与不存在对象的 COMMENT 被拒 | 执行 | - | - | PASS | PASS |

## 策略（18 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-021 | 正向 | CREATE POLICY 单组件成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-022 | 正向 | 多组件策略的组件顺序决定标签值展示顺序 | 执行 | PASS | PASS | PASS | PASS |
| LB-023 | 异常 | 引用不存在的组件报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-024 | 异常 | 策略重名报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-025 | 正向 | WITH LBACRULES 与省略等价（rule_set=LBACRULES） | 执行 | PASS | PASS | PASS | PASS |
| LB-026 | 正向 | ALTER ADD COMPONENT 追加到末尾且已有标签补空值 | 执行 | PASS | PASS | PASS | PASS |
| LB-027 | 异常 | ALTER ADD 重复组件报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-028 | 正向 | ALTER ADD 多个组件（多条子句） | 执行 | PASS | PASS | PASS | PASS |
| LB-029 | 异常 | 表已绑定策略时 ALTER ADD COMPONENT 报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-030 | 正向 | USE/IGNORE ROLE AUTHORIZATIONS 状态切换 | 执行 | PASS | PASS | PASS | PASS |
| LB-031 | 正向 | DROP 无依赖策略成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-032 | 异常 | DROP 仍有标签的策略报错（2413） | 执行 | PASS | PASS | PASS | PASS |
| LB-033 | 异常 | DROP 被表绑定的策略报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-034 | 异常 | DROP 仍有标签授权/免除权的策略报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-035 | 正向 | COMMENT ON POLICY 添加与替换备注 | 执行 | PASS | PASS | PASS | PASS |
| LB-169 | 异常 | 策略重复引用同一组件被拒 | 执行 | - | - | PASS | PASS |
| LB-170 | 异常 | 空组件列表/省略 COMPONENTS 被拒 | 执行 | - | - | PASS | PASS |
| LB-171 | 异常 | 非法规则集名称被拒（OTHER_RULES/拼写错误） | 执行 | - | - | PASS | PASS |

## 标签（18 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-036 | 正向 | CREATE LABEL 单组件单值成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-037 | 正向 | CREATE LABEL 多组件多值（SET 多值） | 执行 | PASS | PASS | PASS | PASS |
| LB-038 | 异常 | 所有组件均为空值时创建失败 | 执行 | PASS | PASS | PASS | PASS |
| LB-039 | 异常 | 使用不属于该策略的组件报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-040 | 异常 | 同一策略下标签重名报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-041 | 正向 | 不同策略下同名标签允许创建 | 执行 | PASS | PASS | PASS | PASS |
| LB-042 | 异常 | SET 多值中出现重复元素报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-043 | 正向 | DROP 未被引用的标签成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-044 | 异常 | DROP 已授予用户的标签报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-045 | 异常 | DROP 被列引用的标签报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-046 | 正向 | COMMENT ON LABEL 与规范化 label_value 展示 | 执行 | PASS | PASS | PASS | PASS |
| LB-172 | 异常 | SET 拒绝 packed string 形式的多值 | 执行 | - | - | PASS | PASS |
| LB-173 | 异常 | ARRAY 拒绝多值及 packed string | 执行 | - | - | PASS | PASS |
| LB-174 | 异常 | 标签重复指定同一组件被拒 | 执行 | - | - | PASS | PASS |
| LB-175 | 异常 | 标签名必须带策略前缀（裸名 COMMENT/DROP 失败） | 执行 | - | - | PASS | PASS |
| LB-176 | 异常 | ALTER LABEL 修改标签值不被支持 | 执行 | - | - | PASS | PASS |
| LB-182 | 异常 | 歧义/非法标签值（括号不配对、嵌套、冒号、越界元素）被拒 | 执行 | - | - | PASS | PASS |
| LB-197 | 边界 | SET/TREE 多值标签创建（语法不支持，待确认） | 执行 | - | - | PASS | PASS |

## 授权（15 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-047 | 正向 | GRANT READ ACCESS 成功且系统表可见 | 执行 | PASS | PASS | PASS | PASS |
| LB-048 | 正向 | GRANT WRITE ACCESS 成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-049 | 正向 | GRANT ALL ACCESS 同时产生读写两条记录 | 执行 | PASS | PASS | PASS | PASS |
| LB-050 | 异常 | 重复授予同一标签同一访问类型报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-051 | 异常 | 同策略下另一标签占用同一访问类型报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-052 | 异常 | 已有 READ 后 GRANT ALL 报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-053 | 异常 | 已有 ALL 后再 GRANT READ 报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-054 | 异常 | 授予不存在的标签报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-055 | 异常 | 授予不存在的用户报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-056 | 正向 | 授予角色成功（grantee_type=ROLE） | 执行 | PASS | PASS | PASS | PASS |
| LB-057 | 正向 | REVOKE 一次性清除读写授权 | 执行 | PASS | PASS | PASS | PASS |
| LB-058 | 异常 | 撤销不存在的授权报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-059 | 异常 | 无 SECURITY 权限的用户执行 LBAC DDL 被拒 | 执行 | PASS | PASS | PASS | PASS |
| LB-060 | 正向 | USE/IGNORE ROLE AUTHORIZATIONS 决定角色标签是否参与判断 | 执行 | PASS | PASS | PASS | PASS |
| LB-156 | 正向 | GRANT EXEMPTION TO ROLE 生效且受 IGNORE 影响 | 执行 | PASS | PASS | PASS | PASS |

## 豁免（17 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-061 | 正向 | GRANT EXEMPTION LBACREADARRAY 后读放行 | 执行 | PASS | PASS | PASS | PASS |
| LB-062 | 正向 | LBACWRITEARRAY WRITE_UP 只免上写，下写仍拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-063 | 正向 | GRANT EXEMPTION ALL 展开为多条记录 | 执行 | PASS | PASS | PASS | PASS |
| LB-064 | 边界 | 重复授予同一豁免静默成功且不刷新时间 | 执行 | PASS | PASS | PASS | PASS |
| LB-065 | 正向 | REVOKE 单条豁免生效 | 执行 | PASS | PASS | PASS | PASS |
| LB-066 | 异常 | 撤销不存在的豁免报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-067 | 正向 | REVOKE ALL 清空该策略下全部豁免 | 执行 | PASS | PASS | PASS | PASS |
| LB-068 | 正向 | 角色豁免在 IGNORE 下不生效、USE 下生效 | 执行 | PASS | PASS | PASS | PASS |
| LB-178 | 正向 | 仅授 READARRAY 豁免：ARRAY 维度放行、SET 维度仍拒 | 执行 | - | - | PASS | PASS |
| LB-179 | 边界 | ALL 豁免展开后撤销单规则，剩余规则仍生效 | 执行 | - | - | PASS | PASS |
| LB-180 | 正向 | 角色 READTREE 豁免受 IGNORE/USE 控制 | 执行 | - | - | PASS | PASS |
| LB-186 | 正向 | 六条内置规则逐一 GRANT/REVOKE 与记录核对 | 执行 | - | - | PASS | PASS |
| LB-187 | 正向 | LBACWRITEARRAY 的 WRITE_UP / WRITE_DOWN 方向语义 | 执行 | - | - | PASS | PASS |
| LB-188 | 正向 | SET 维度豁免：READSET / WRITESET 放行集合不满足的读写 | 执行 | - | - | PASS | PASS |
| LB-189 | 正向 | TREE 维度豁免：READTREE / WRITETREE 放行后代访问 | 执行 | - | - | PASS | PASS |
| LB-190 | 反向 | 策略级豁免不跨策略生效 | 执行 | - | - | PASS | PASS |
| LB-191 | 边界 | 多规则叠加后逐步撤销；非法规则/方向组合被拒 | 执行 | - | - | PASS | PASS |

## 比较（33 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-069 | 正向 | ARRAY READ：用户 SEC 读 INT 保护列允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-070 | 正向 | ARRAY READ：用户 SEC 读 SEC 保护列允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-071 | 反向 | ARRAY READ：用户 SEC 读 TOP 保护列拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-072 | 边界 | ARRAY READ：空用户标签读 PUB 保护列拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-073 | 边界 | ARRAY READ：空对象保护值不阻挡任何用户值 | 执行 | PASS | PASS | PASS | PASS |
| LB-074 | 边界 | ARRAY READ：双方均为空值允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-075 | 反向 | ARRAY WRITE：SEC 写 INT 保护列拒绝（下写） | 执行 | PASS | PASS | PASS | PASS |
| LB-076 | 正向 | ARRAY WRITE：SEC 写 SEC 保护列允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-077 | 反向 | ARRAY WRITE：SEC 写 TOP 保护列拒绝（上写） | 执行 | PASS | PASS | PASS | PASS |
| LB-078 | 边界 | ARRAY WRITE：空用户标签写 PUB 保护列拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-079 | 边界 | ARRAY WRITE：用户 PUB 写空保护值允许（不算下写） | 执行 | PASS | PASS | PASS | PASS |
| LB-080 | 边界 | ARRAY WRITE：双方均为空值允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-081 | 正向 | SET READ：用户 (RD,QA) 读 RD 保护列允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-082 | 反向 | SET READ：用户 RD 读 (RD,QA) 保护列拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-083 | 边界 | SET READ：空用户标签读 RD 保护列拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-084 | 边界 | SET READ：用户 RD 读空保护值允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-085 | 正向 | SET WRITE：用户 (RD,QA) 写 RD 保护列允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-086 | 反向 | SET WRITE：用户 RD 写 (RD,QA) 保护列拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-087 | 正向 | TREE READ：用户 COMPANY 读 RND 保护列允许（祖先） | 执行 | PASS | PASS | PASS | PASS |
| LB-088 | 正向 | TREE READ：用户 RND 读 STORAGE 保护列允许（祖先） | 执行 | PASS | PASS | PASS | PASS |
| LB-089 | 反向 | TREE READ：用户 STORAGE 读 RND 保护列拒绝（后代） | 执行 | PASS | PASS | PASS | PASS |
| LB-090 | 边界 | TREE READ：空用户标签读 RND 保护列拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-091 | 正向 | TREE WRITE：用户 COMPANY 写 STORAGE 保护列允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-092 | 反向 | TREE WRITE：用户 STORAGE 写 RND 保护列拒绝 | 执行 | PASS | PASS | PASS | PASS |
| LB-093 | 边界 | 默认空标签：无任何授权的用户读 PUB 保护列被拒、读未保护列允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-094 | 反向 | 多组件 AND：任一组件不满足即拒绝（dept 缺 QA） | 执行 | PASS | PASS | PASS | PASS |
| LB-095 | 正向 | 多组件 AND：所有组件均满足时允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-096 | 正向 | ALL ACCESS 授权可读可写 | 执行 | PASS | PASS | PASS | PASS |
| LB-177 | 正向 | 同一主体 READ=高标签、WRITE=低标签：读放行/写本级放行/写上级拒绝 | 执行 | - | - | PASS | PASS |
| LB-183 | 边界 | SET 维度空值三态（空用户/空对象/双方空） | 执行 | - | - | PASS | PASS |
| LB-184 | 边界 | TREE 维度空值三态（空用户/空对象/双方空） | 执行 | - | - | PASS | PASS |
| LB-185 | 正向 | 多角色多策略：USED/IGNORED 混合下角色标签生效范围 | 执行 | - | - | PASS | PASS |
| LB-196 | 边界 | TREE 多值标签读写（语法不支持，待确认） | 执行 | - | - | PASS | PASS |

## 绑定（18 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-097 | 正向 | CREATE TABLE 同时绑定策略与列保护生效 | 执行 | PASS | PASS | PASS | PASS |
| LB-098 | 异常 | 建表时 SECURED WITH 标签不属于该策略报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-099 | 异常 | 建表时绑定不存在的策略报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-100 | 正向 | ALTER TABLE ADD SECURITY POLICY 成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-101 | 异常 | 表已绑定策略后再次 ADD 报错 | 执行 | PASS | PASS | PASS | PASS |
| LB-102 | 反向 | 新增列保护需要新标签写凭证（无凭证拒绝） | 执行 | PASS | PASS | PASS | PASS |
| LB-103 | 反向 | 修改列保护需要旧标签读写 + 新标签写（缺一即拒） | 执行 | PASS | PASS | PASS | PASS |
| LB-104 | 边界 | 修改列保护为新标签且凭证齐全时成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-105 | 边界 | SECURED WITH 相同标签在凭证齐全时幂等成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-106 | 反向 | 解除列保护需要旧标签读写凭证 | 执行 | PASS | PASS | PASS | PASS |
| LB-107 | 正向 | DROP SECURITY POLICY 同时移除表策略与全部列标签 | 执行 | PASS | PASS | PASS | PASS |
| LB-108 | 异常 | 视图（可写视图/逻辑视图）不能设置 LBAC 保护 | 执行 | PASS | PASS | PASS | PASS |
| LB-142 | 正向 | 表切换到另一策略：解绑旧策略后按新策略重新保护列 | 执行 | PASS | PASS | PASS | PASS |
| LB-143 | 边界 | 保护 TAG 列 / TIME 列（待需求确认） | 跳过 | SKIP | SKIP | SKIP | SKIP |
| LB-144 | 边界 | RENAME TABLE 后策略与列标签保持（语法不支持） | 跳过 | SKIP | SKIP | SKIP | SKIP |
| LB-145 | 正向 | DROP COLUMN 删除受保护列后该标签可被删除 | 执行 | PASS | PASS | PASS | PASS |
| LB-146 | 边界 | CREATE TABLE AS SELECT / LIKE 不继承策略（语法不支持） | 跳过 | SKIP | SKIP | SKIP | SKIP |
| LB-195 | 正向 | 两个策略下的同名标签互不串用 | 执行 | - | - | PASS | PASS |

## 视图（2 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-109 | 正向 | 可写视图 CRUD 走底层表的 LBAC 检查 | 跳过 | SKIP | SKIP | SKIP | SKIP |
| LB-110 | 正向 | 逻辑视图查询走底层表的 LBAC 检查 | 执行 | PASS | PASS | PASS | PASS |

## 查询（11 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-111 | 反向 | SELECT 受保护列无读凭证被拒（2400） | 执行 | PASS | PASS | PASS | PASS |
| LB-112 | 反向 | SELECT * 含无权受保护列被拒 | 执行 | PASS | PASS | PASS | PASS |
| LB-113 | 正向 | 仅查询有权限的列允许 | 执行 | PASS | PASS | PASS | PASS |
| LB-114 | 正向 | COUNT(*) 不因存在无权列而失败 | 执行 | PASS | PASS | PASS | PASS |
| LB-115 | 正向 | DESCRIBE / SHOW CREATE TABLE 不触发 LBAC 检查 | 执行 | PASS | PASS | PASS | PASS |
| LB-147 | 反向 | 聚合函数 COUNT/SUM/AVG 引用受保护列触发读检查 | 执行 | PASS | PASS | PASS | PASS |
| LB-148 | 反向 | GROUP BY / HAVING / ORDER BY 引用受保护列触发读检查 | 执行 | PASS | PASS | PASS | PASS |
| LB-149 | 反向 | WHERE 过滤条件引用受保护列触发读检查 | 执行 | PASS | PASS | PASS | PASS |
| LB-150 | 反向 | SELECT 别名不能绕过受保护列读检查 | 执行 | PASS | PASS | PASS | PASS |
| LB-151 | 反向 | JOIN 两张不同标签的表按 AND 语义判定 | 执行 | PASS | PASS | PASS | PASS |
| LB-152 | 反向 | UNION / 子查询引用受保护列触发读检查 | 执行 | PASS | PASS | PASS | PASS |

## 写入（3 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-116 | 反向 | INSERT 受保护列无写凭证被拒 | 执行 | PASS | PASS | PASS | PASS |
| LB-117 | 正向 | INSERT 受保护列有写凭证成功 | 执行 | PASS | PASS | PASS | PASS |
| LB-122 | 正向 | 经可写视图 INSERT 时按底层表检查（有凭证成功） | 跳过 | SKIP | SKIP | SKIP | SKIP |

## 更新（1 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-118 | 边界 | UPDATE ATTRIBUTE 需 SET 列写凭证与 WHERE 列读凭证 | 执行 | PASS | PASS | PASS | PASS |

## 删除（3 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-119 | 反向 | DELETE 行需要所有受保护列的写凭证 | 执行 | PASS | PASS | PASS | PASS |
| LB-120 | 边界 | DELETE WHERE 引用受保护列时还需读凭证 | 执行 | PASS | PASS | PASS | PASS |
| LB-121 | 正向 | DROP TABLE / DROP DATABASE 不额外触发 LBAC 检查 | 执行 | PASS | PASS | PASS | PASS |

## 系统表（8 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-123 | 正向 | 普通用户可查询 security_policies | 执行 | PASS | PASS | PASS | PASS |
| LB-124 | 正向 | security_label_component_elements 的 ordinal/parent 正确 | 执行 | PASS | PASS | PASS | PASS |
| LB-125 | 正向 | security_policy_component_rules 返回读写规则名与顺序 | 执行 | PASS | PASS | PASS | PASS |
| LB-126 | 正向 | security_labels 的规范化 label_value 正确 | 执行 | PASS | PASS | PASS | PASS |
| LB-127 | 正向 | security_label_access 普通用户只看自己、SECURITY 看全部 | 执行 | PASS | PASS | PASS | PASS |
| LB-128 | 正向 | security_policy_exemptions 的可见范围 | 执行 | PASS | PASS | PASS | PASS |
| LB-129 | 正向 | tables.security_policy / columns.security_label 字段正确 | 执行 | PASS | PASS | PASS | PASS |
| LB-194 | 正向 | SECURITY 主体与普通用户对 security_label_access 的可见范围 | 执行 | - | - | PASS | PASS |

## 审计（2 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-130 | 正向 | LBAC 拒绝访问产生 LBAC_AUTHENTICATION 审计记录 | 执行 | PASS | PASS | PASS | PASS |
| LB-131 | 正向 | LBAC 元数据 DDL 需要 SECURITY 权限（无权限被拒） | 执行 | PASS | PASS | PASS | PASS |

## 高可用（3 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-132 | 可靠性 | CN 重启后 LBAC 元数据与授权仍有效 | 执行 | PASS | PASS | PASS | PASS |
| LB-133 | 可靠性 | DN 重启后 LBAC 访问判断仍生效 | 执行 | PASS | PASS | PASS | PASS |
| LB-134 | 可靠性 | ALTER COMPONENT ADD ELEMENT 后新标签按新版本生效 | 执行 | PASS | PASS | PASS | PASS |

## 缓存（2 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-135 | 可靠性 | 解除列保护后立即生效（不按旧缓存放行） | 执行 | PASS | PASS | PASS | PASS |
| LB-136 | 可靠性 | ALTER POLICY USE ROLE AUTHORIZATIONS 后立即生效 | 执行 | PASS | PASS | PASS | PASS |

## 一致性（2 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-137 | 可靠性 | 三个 CN 的 LBAC 元数据一致（schema 3 副本） | 执行 | PASS | PASS | PASS | PASS |
| LB-138 | 可靠性 | 数据 2 副本下写入后多次查询结果一致 | 执行 | PASS | PASS | PASS | PASS |

## 持久化（1 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-139 | 可靠性 | 重启后 label grant / exemption 仍存在 | 执行 | PASS | PASS | PASS | PASS |

## 日志（1 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-140 | 可靠性 | 正常授权访问路径无异常 ERROR | 执行 | PASS | PASS | PASS | PASS |

## 并发（3 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-141 | 并发 | 并发对同一用户授予同一标签同类型：一成功一失败 | 执行 | PASS | PASS | PASS | PASS |
| LB-192 | 并发 | 8 个并发会话创建同名组件：仅 1 个成功 | 执行 | - | - | PASS | PASS |
| LB-193 | 边界 | 活跃访问期间执行必失败操作后，原访问与元数据不受影响 | 执行 | - | - | PASS | PASS |

## 权限（4 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-153 | 反向 | 仅有 LBAC 凭证、无 RBAC 权限仍被拒（803） | 执行 | PASS | PASS | PASS | PASS |
| LB-154 | 边界 | 同一策略 READ 与 WRITE 授予不同标签（待需求确认） | 跳过 | SKIP | SKIP | SKIP | SKIP |
| LB-155 | 正向 | DROP USER 后 label 授权与豁免级联清理 | 执行 | PASS | PASS | PASS | PASS |
| LB-157 | 正向 | 三权分立：security_admin 授 label 给 sys_admin 后仍无数据权限 | 条件执行 | SKIP | PASS | SKIP | PASS |

## 旁路（3 条）

| 用例 | 类型 | 描述 | 状态 | io普通 | io三权 | DR2普通 | DR2三权 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-158 | 边界 | EXPORT / SELECT INTO 导出受保护列是否受检（待需求确认） | 跳过 | SKIP | SKIP | SKIP | SKIP |
| LB-159 | 边界 | pipe / subscription 写入受保护列是否受检（待需求确认） | 跳过 | SKIP | SKIP | SKIP | SKIP |
| LB-160 | 边界 | LOAD / 批量导入受保护列是否受检（待需求确认） | 跳过 | SKIP | SKIP | SKIP | SKIP |

## 跳过明细

| 用例 | 原因 |
| --- | --- |
| LB-109 | 不适用（已确认）：可写视图源为树模型（VIEW FROM TREE），不做 LBAC 保护；逻辑视图场景见 LB-110 |
| LB-122 | 同上（可写视图写入检查） |
| LB-143 | 待需求确认：TAG / TIME 列是否允许 SECURED WITH（需求未写，暂不判定） |
| LB-144 | 表模型不支持 RENAME TABLE（RENAME 语法报 700），无法验证 |
| LB-146 | 表模型不支持 CREATE TABLE ... AS SELECT / LIKE（语法报 700），无继承路径 |
| LB-154 | 待需求确认：同一策略下 READ 与 WRITE 能否授予不同标签 |
| LB-157 | 仅三权分立场景（SEP=1）验证跨管理员权限边界 |
| LB-158 | 待需求确认：导出链路（EXPORT / SELECT INTO）是否在 LBAC 检查范围 |
| LB-159 | 待需求确认：pipe / subscription 写入是否在 LBAC 检查范围 |
| LB-160 | 待需求确认：LOAD / 批量导入是否在 LBAC 检查范围 |
