# 研发自测用例（139 条）覆盖对照与扩展

| 项 | 内容 |
| --- | --- |
| 自测文档 | Feishu《TimechoDB LBAC 全功能自测用例》，139 条，7 组（C/P/L/G/R/E/M） |
| 我方套件 | `lbac_skill` 180 条（原 160 + 本次按自测缺口新增 20：LB-161~LB-180） |
| 对照结论 | 主干语义全覆盖；**新增 20 条覆盖自测中我方原先未断言的点**；仍有 12 项细粒度场景待补（见第四节） |

## 一、分组覆盖总览

| 自测组 | 自测条数 | 我方覆盖方式 | 新增覆盖（本次） | 仍未覆盖 |
| --- | ---: | --- | --- | ---: |
| C 安全标签组件 | 28 | LB-001~020（创建/重名/重复元素/保留字符/32B/ALTER 位置/DROP 依赖/COMMENT） | LB-161 单元素+200 元素 ordinal；LB-162 零元素/缺类型；LB-163 非法类型与非法 TREE 节点；LB-164 ARRAY 省略位置、SET 拒绝位置；LB-165 TREE OVER 重挂接/跨父/重复；LB-166 双 ROOT 拒绝与 ADD ROOT 提升；LB-167 元素插入后比较语义；LB-168 组件类型不可变 | 2（C-24 备注权限） |
| P 策略 | 18 | LB-021~035（创建/组件顺序/ALTER ADD/角色开关/四类依赖/COMMENT） | LB-169 重复引用组件；LB-170 空/省略 COMPONENTS；LB-171 规则集名校验 | 0 |
| L 标签 | 22 | LB-036~046（多组件/SET 多值/全空/越界组件/重名/作用域/DROP 依赖/label_value） | LB-172 SET packed string；LB-173 ARRAY 多值与 packed；LB-174 重复指定组件；LB-175 裸名必须带策略前缀；LB-176 ALTER LABEL 不支持 | 1（L-21 歧义值） |
| G 授权 | 18 | LB-047~060（READ/WRITE/ALL 冲突/角色/无 SECURITY/撤销/角色开关） | LB-177 READ=高标签 + WRITE=低标签（G-07/G-11） | 2（G-17 管理员视角、G-18 跨策略同名） |
| R 比较语义 | 23 | LB-069~096（ARRAY/SET/TREE 比较、空值、多组件 AND、ALL） | LB-177（读写不同标签）、LB-167（顺序变更生效） | 5（R-09/R-10 TREE 多值；R-12/R-13 SET/TREE 空值三态；R-21/22 多角色多策略） |
| E 豁免 | 23 | LB-061~068（READ/WRITEARRAY、UP/DOWN、ALL 展开、幂等、REVOKE、角色豁免） | LB-178 仅 READARRAY 时 ARRAY 放行；LB-179 ALL 展开展开后撤销单规则；LB-180 角色 READTREE 受 IGNORE/USE | 7（SET/TREE 豁免原语、策略级豁免、多规则叠加、非法规则/方向、对象不存在、重复授权、同名 SET 组件） |
| M 元数据/会话 | 7 | LB-123~131、137、141（7 张系统表、可见性、并发授权） | — | 2（M-07 并发 DDL 唯一性、M-08 活跃会话期间失败操作） |

## 二、本次新增的 20 条（LB-161 ~ LB-180）

| 用例 | 对应自测 | 数据量/说明 |
| --- | --- | --- |
| LB-161 | C-07 / C-28 | **200 元素 ARRAY**（自测为单元素）+ 三类单元素组件 |
| LB-162 | C-08 | `ARRAY()/SET()/TREE()` 与缺类型 |
| LB-163 | C-09 | LIST 类型、TREE 无 ROOT、UNDER 不存在父 |
| LB-164 | C-14 / C-16 | ARRAY 省略位置子句；SET 拒绝 BEFORE/UNDER |
| LB-165 | C-18 / C-19 | OVER 重挂接、跨父 OVER、重复 OVER |
| LB-166 | C-21 | 双 ROOT 拒绝 + ADD ROOT 提升 |
| LB-167 | C-10~C-13 | 插入 ULTRA 后用读判定验证新顺序 |
| LB-168 | C-22 | ALTER COMPONENT 改类型被拒 |
| LB-169 | P-06 | 重复引用组件 |
| LB-170 | P-07 | 空/省略 COMPONENTS |
| LB-171 | P-08 | OTHER_RULES / 拼写错误 / 标准 LBACRULES |
| LB-172 | L-04 | SET packed string 两种写法 |
| LB-173 | L-06 | ARRAY 多值与 packed |
| LB-174 | L-10 | 重复指定组件（同值/不同值） |
| LB-175 | L-14 | 裸名 COMMENT/DROP 拒绝，限定名成功 |
| LB-176 | L-16 | ALTER LABEL 改值 |
| LB-177 | G-07/G-11/R-23 | READ=TOP + WRITE=SEC：读放行、写本级放行、写上级拒绝 |
| LB-178 | E-08 | 三组件策略，仅 READARRAY 豁免 |
| LB-179 | E-23 | ALL 展开后撤销单规则 |
| LB-180 | E-22 | 角色 READTREE 豁免 + IGNORE/USE |

## 三、每个用例的 CN/DN 日志检查（本次增强）

`tools/suite.sh` 已加**逐用例日志窗口**：

- 每个用例执行前后记录 3 CN + 5 DN 的 `log_confignode_all.log` / `log_datanode_all.log` 行号；
- 用例结束后抓取该窗口内的 `ERROR`/`WARN`，写入 `results/<run>/<CASE>.logwin.txt`；
- 用噪声白名单（Ratis / GrpcLogAppender / Pipe / ConsensusPipe / 重启类看门狗等）过滤，**非噪声条数 >0 时**在 `results.tsv` 的 detail 列写 `LOG{err=N warn=N unexp=N}`，可直接定位到“哪个用例产生了不符合预期的日志”。

## 四、仍待补的 12 项（下一批建议）

| 自测 ID | 场景 | 备注 |
| --- | --- | --- |
| C-24 | 组件备注的权限（无 SECURITY 用户、评论不存在组件） | 需补 COMMENT 权限断言 |
| L-21 | 歧义/非法标签值（括号不配对、空元素、嵌套、冒号跨组件） | 需逐一构造 |
| R-09 / R-10 | TREE 多值标签的读/写 | 需多值 TREE 标签 |
| R-12 / R-13 | SET / TREE 维度的空值三态 | ARRAY 已覆盖，SET/TREE 未覆盖 |
| R-21 / R-22 | 多角色、多策略（USED/IGNORED 混合） | 需多角色会话 |
| E-01 / E-03~E-06 | 六条内置规则逐一 GRANT/REVOKE；WRITE_UP/DOWN 组合 | 目前只覆盖 ARRAY 读写 |
| E-09 ~ E-13 | SET/TREE 豁免原语（READSET/WRITESET/READTREE/WRITETREE） | 缺口最大 |
| E-14 / E-16 | 策略级豁免；多规则叠加后逐步撤销 | 需顺序敏感断言 |
| E-17 / E-18 | 非法规则/方向；对象不存在或主体类型错误 | 负向断言 |
| E-20 / E-21 | 重复授权幂等；同名规则 SET 组件 | 需构造同名规则 |
| M-07 / M-08 | 并发 DDL 唯一性；活跃会话期间执行必失败操作后不重连 | 需并发脚本与会话保持 |
| G-17 / G-18 | 管理员/本人/无关用户的 access 表可见性；跨策略同名标签访问 | 三权分立下补充更合适 |

> 数据量放大原则：组件元素 200（自测 3~5）、受保护列 100、标签 50、并发 8 会话；单条 DDL/INSERT 构造，避免逐条 CLI 造成时间膨胀。
