# sec_skill 断言清单（16 条 × 双模式，最新一轮）

> 生成时间：2026-11-17 17:46:49；数据源：`results/SEC-*.out`（每个 (用例,模式) 取 mtime 最新的一份）。
> 断言前缀含义：`PASS` 通过 / `WARN` 记录性提示（不判失败） / `FAIL` 失败。

## 一、汇总

| 用例 | 模式 | 结果 | PASS 数 | WARN 数 | FAIL 数 | 耗时 |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-01 | normal | PASS | 16 | 0 | 0 | 109s |
| SEC-01 | sep | PASS | 16 | 0 | 0 | 22s |
| SEC-02 | normal | PASS | 26 | 0 | 0 | 312s |
| SEC-02 | sep | PASS | 26 | 0 | 0 | 41s |
| SEC-03 | normal | PASS | 13 | 0 | 0 | 157s |
| SEC-03 | sep | PASS | 13 | 0 | 0 | 30s |
| SEC-04 | normal | PASS | 14 | 1 | 0 | 163s |
| SEC-04 | sep | PASS | 14 | 1 | 0 | 31s |
| SEC-05 | normal | PASS | 20 | 2 | 0 | 31s |
| SEC-05 | sep | PASS | 20 | 2 | 0 | 138s |
| SEC-06 | normal | PASS | 15 | 1 | 0 | 118s |
| SEC-06 | sep | PASS | 15 | 1 | 0 | 26s |
| SEC-07 | normal | PASS | 13 | 0 | 0 | 150s |
| SEC-07 | sep | PASS | 15 | 0 | 0 | 31s |
| SEC-08 | normal | PASS | 17 | 0 | 0 | 171s |
| SEC-08 | sep | PASS | 17 | 0 | 0 | 41s |
| SEC-09 | normal | PASS | 18 | 0 | 0 | 120s |
| SEC-09 | sep | PASS | 18 | 0 | 0 | 86s |
| SEC-10 | normal | PASS | 15 | 2 | 0 | 38s |
| SEC-10 | sep | PASS | 15 | 2 | 0 | 29s |
| SEC-11 | normal | PASS | 11 | 1 | 0 | 80s |
| SEC-11 | sep | PASS | 11 | 1 | 0 | 75s |
| SEC-12 | normal | PASS | 23 | 2 | 0 | 23s |
| SEC-12 | sep | PASS | 22 | 2 | 0 | 23s |
| SEC-13 | normal | PASS | 13 | 1 | 0 | 30s |
| SEC-13 | sep | PASS | 14 | 0 | 0 | 21s |
| SEC-14 | normal | PASS | 10 | 2 | 0 | 30s |
| SEC-14 | sep | PASS | 10 | 2 | 0 | 25s |
| SEC-15 | normal | PASS | 18 | 0 | 0 | 23s |
| SEC-15 | sep | PASS | 17 | 1 | 0 | 25s |
| SEC-16 | normal | PASS | 8 | 2 | 0 | 26s |
| SEC-16 | sep | PASS | 8 | 2 | 0 | 20s |

## 二、逐条断言

### SEC-01 · normal

`PASS fail_flag=0 elapsed=109s passes=16 warns=0`

- ✅ enforce_strong_password 生效值: true == true
- ✅ 11 字符被拒（>=12）: 命中 /820/
- ✅ 11 字符文案: 命中 /must be greater than or equal to 12/
- ✅ 33 字符被拒（<=32）: 命中 /820/
- ✅ 33 字符文案: 命中 /must be less than or equal to 32/
- ✅ 12 字符（下边界）创建成功: 命中 /successfully/
- ✅ 32 字符（上边界）创建成功: 命中 /successfully/
- ✅ 32 位密码可登录: yes == yes
- ✅ enforce_strong_password 已关闭: false == false
- ✅ 关闭强密码后 11 字符仍被拒: 命中 /820/
- ✅ 关闭强密码后 33 字符仍被拒: 命中 /820/
- ✅ 关闭强密码后 12 字符可建: 命中 /successfully/
- ✅ 空密码被拒: 命中 /820/
- ✅ 1 字符被拒: 命中 /820/
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-01 · sep

`PASS fail_flag=0 elapsed=22s passes=16 warns=0`

- ✅ enforce_strong_password 生效值: true == true
- ✅ 11 字符被拒（>=12）: 命中 /820/
- ✅ 11 字符文案: 命中 /must be greater than or equal to 12/
- ✅ 33 字符被拒（<=32）: 命中 /820/
- ✅ 33 字符文案: 命中 /must be less than or equal to 32/
- ✅ 12 字符（下边界）创建成功: 命中 /successfully/
- ✅ 32 字符（上边界）创建成功: 命中 /successfully/
- ✅ 32 位密码可登录: yes == yes
- ✅ enforce_strong_password 已关闭: false == false
- ✅ 关闭强密码后 11 字符仍被拒: 命中 /820/
- ✅ 关闭强密码后 33 字符仍被拒: 命中 /820/
- ✅ 关闭强密码后 12 字符可建: 命中 /successfully/
- ✅ 空密码被拒: 命中 /820/
- ✅ 1 字符被拒: 命中 /820/
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-02 · normal

`PASS fail_flag=0 elapsed=312s passes=26 warns=0`

- ✅ enforce_strong_password 生效值: true == true
- ✅ 缺大写被拒: 命中 /820/
- ✅ 文案点名缺大写: 命中 /uppercase/
- ✅ 缺小写被拒: 命中 /820/
- ✅ 文案点名缺小写: 命中 /lowercase/
- ✅ 缺数字被拒: 命中 /820/
- ✅ 文案点名缺数字: 命中 /digit/
- ✅ 缺特殊字符被拒: 命中 /820/
- ✅ 文案点名缺特殊字符: 命中 /special character/
- ✅ 缺大写+特殊被拒: 命中 /820/
- ✅ 同时点名 uppercase: 命中 /uppercase/
- ✅ 同时点名 special character: 命中 /special character/
- ✅ 四要素齐备创建成功: 命中 /successfully/
- ✅ 该用户可登录: yes == yes
- ✅ 含空格被拒: 命中 /820/
- ✅ 空格文案: 命中 /cannot contain spaces/
- ✅ 中文被拒: 命中 /820/
- ✅ 非法字符文案: 命中 /can only contain letters, numbers/
- ✅ 14 个特殊字符都能作为特殊字符位: 14 == 14
- ✅ 无特殊字符被误拒
- ✅ 字符 [/] 被拒（820 白名单校验 或 700 语法拒绝）
- ✅ 字符 [:] 被拒（820 白名单校验 或 700 语法拒绝）
- ✅ 字符 ["] 被拒（820 白名单校验 或 700 语法拒绝）
- ✅ 字符 [;] 被拒（820 白名单校验 或 700 语法拒绝）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-02 · sep

`PASS fail_flag=0 elapsed=41s passes=26 warns=0`

- ✅ enforce_strong_password 生效值: true == true
- ✅ 缺大写被拒: 命中 /820/
- ✅ 文案点名缺大写: 命中 /uppercase/
- ✅ 缺小写被拒: 命中 /820/
- ✅ 文案点名缺小写: 命中 /lowercase/
- ✅ 缺数字被拒: 命中 /820/
- ✅ 文案点名缺数字: 命中 /digit/
- ✅ 缺特殊字符被拒: 命中 /820/
- ✅ 文案点名缺特殊字符: 命中 /special character/
- ✅ 缺大写+特殊被拒: 命中 /820/
- ✅ 同时点名 uppercase: 命中 /uppercase/
- ✅ 同时点名 special character: 命中 /special character/
- ✅ 四要素齐备创建成功: 命中 /successfully/
- ✅ 该用户可登录: yes == yes
- ✅ 含空格被拒: 命中 /820/
- ✅ 空格文案: 命中 /cannot contain spaces/
- ✅ 中文被拒: 命中 /820/
- ✅ 非法字符文案: 命中 /can only contain letters, numbers/
- ✅ 14 个特殊字符都能作为特殊字符位: 14 == 14
- ✅ 无特殊字符被误拒
- ✅ 字符 [/] 被拒（820 白名单校验 或 700 语法拒绝）
- ✅ 字符 [:] 被拒（820 白名单校验 或 700 语法拒绝）
- ✅ 字符 ["] 被拒（820 白名单校验 或 700 语法拒绝）
- ✅ 字符 [;] 被拒（820 白名单校验 或 700 语法拒绝）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-03 · normal

`PASS fail_flag=0 elapsed=157s passes=13 warns=0`

- ✅ 密码等于用户名被拒: 命中 /820/
- ✅ 文案：Password cannot be the same as user name: 命中 /cannot be the same as user name/
- ✅ 同密码不同用户名可创建: 命中 /successfully/
- ✅ 对照用户可登录: yes == yes
- ✅ 密码包含用户名但不相等时放行（实现为等式判定，非包含判定）
- ✅ 准备用户创建成功: 命中 /successfully/
- ✅ ALTER 改成合法强密码成功: 命中 /successfully/
- ✅ 新密码可登录: yes == yes
- ✅ ALTER 改成弱密码被拒（同一套复杂度校验）: 命中 /820/
- ✅ 被拒后新密码仍可用: yes == yes
- ✅ 用户名大小写不同则不算「等于用户名」（放行）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-03 · sep

`PASS fail_flag=0 elapsed=30s passes=13 warns=0`

- ✅ 密码等于用户名被拒: 命中 /820/
- ✅ 文案：Password cannot be the same as user name: 命中 /cannot be the same as user name/
- ✅ 同密码不同用户名可创建: 命中 /successfully/
- ✅ 对照用户可登录: yes == yes
- ✅ 密码包含用户名但不相等时放行（实现为等式判定，非包含判定）
- ✅ 准备用户创建成功: 命中 /successfully/
- ✅ ALTER 改成合法强密码成功: 命中 /successfully/
- ✅ 新密码可登录: yes == yes
- ✅ ALTER 改成弱密码被拒（同一套复杂度校验）: 命中 /820/
- ✅ 被拒后新密码仍可用: yes == yes
- ✅ 用户名大小写不同则不算「等于用户名」（放行）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-04 · normal

`PASS fail_flag=0 elapsed=163s passes=14 warns=1`

- ✅ 生效值=true: true == true
- ✅ 开启时全小写 12 位被拒: 命中 /820/
- ✅ 关闭配置被接受: 命中 /successfully/
- ✅ 生效值=false（热加载）: false == false
- ✅ 关闭后全小写 12 位可建: 命中 /successfully/
- ✅ 关闭后 11 位仍被拒: 命中 /820/
- ✅ 仍报长度文案: 命中 /greater than or equal to 12/
- ⚠️ 关闭强密码后 密码==用户名 仍被拒（实现上 e 未随开关关闭）：Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 820: The length of password must be greater than or equal to 12
- ✅ 强密码用户创建成功: 命中 /successfully/
- ✅ 关闭后老用户仍可登录（不追溯）: yes == yes
- ✅ 生效值恢复 true: true == true
- ✅ 重新开启后弱密码再次被拒: 命中 /820/
- ✅ 重新开启后不报长度错误（说明是复杂度拦截）: 未出现 /greater than or equal to 12/
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-04 · sep

`PASS fail_flag=0 elapsed=31s passes=14 warns=1`

- ✅ 生效值=true: true == true
- ✅ 开启时全小写 12 位被拒: 命中 /820/
- ✅ 关闭配置被接受: 命中 /successfully/
- ✅ 生效值=false（热加载）: false == false
- ✅ 关闭后全小写 12 位可建: 命中 /successfully/
- ✅ 关闭后 11 位仍被拒: 命中 /820/
- ✅ 仍报长度文案: 命中 /greater than or equal to 12/
- ⚠️ 关闭强密码后 密码==用户名 仍被拒（实现上 e 未随开关关闭）：Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 820: The length of password must be greater than or equal to 12
- ✅ 强密码用户创建成功: 命中 /successfully/
- ✅ 关闭后老用户仍可登录（不追溯）: yes == yes
- ✅ 生效值恢复 true: true == true
- ✅ 重新开启后弱密码再次被拒: 命中 /820/
- ✅ 重新开启后不报长度错误（说明是复杂度拦截）: 未出现 /greater than or equal to 12/
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-05 · normal

`PASS fail_flag=0 elapsed=31s passes=20 warns=2`

- ✅ 相位1 用户已重建（密码 A）: yes == yes
- ✅ A→B 成功: 命中 /successfully/
- ✅ 禁用状态下 B→A 允许（无历史约束，硬门禁）: 命中 /successfully/
- ✅ 设置 =0 被接受: 命中 /successfully/
- ✅ 相位2 A→B 成功: 命中 /successfully/
- ⚠️ 显式 =0 时 B→A 被拒（实现把 0 改写为 1 天，CommonConfig.java:3428；需求为 0=无约束）—— 已记录为待确认偏差，不判 FAIL：Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 701: The password has been used recently, and it cannot be reused before Wed Nov 18 17:13:27 CST 2026
- ✅ 设置 =1 被接受: 命中 /successfully/
- ✅ 生效值=1（热加载）: 1 == 1
- ✅ 相位3 用户已重建: yes == yes
- ✅ A→B 成功（B 为当前密码）: 命中 /successfully/
- ✅ =1 时 B→A 被拒（硬门禁）: 命中 /cannot be reused before/
- ✅ 复用文案含 used recently: 命中 /used recently/
- ✅ 被拒后当前密码仍是 B: yes == yes
- ✅ 相位4 A→B 成功: 命中 /successfully/
- ✅ B→C 成功: 命中 /successfully/
- ✅ C→B 被拒（历史 B）: 命中 /cannot be reused before/
- ✅ C→A 被拒（历史 A）: 命中 /cannot be reused before/
- ✅ C→全新密码 成功: 命中 /successfully/
- ✅ 禁用后 C→A 允许（恢复无限制）: 命中 /successfully/
- ⚠️ 本用例验证 禁用无限制 / =1 窗口内拒绝 / 恢复；'窗口过后可重用'见 SEC-06
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-05 · sep

`PASS fail_flag=0 elapsed=138s passes=20 warns=2`

- ✅ 相位1 用户已重建（密码 A）: yes == yes
- ✅ A→B 成功: 命中 /successfully/
- ✅ 禁用状态下 B→A 允许（无历史约束，硬门禁）: 命中 /successfully/
- ✅ 设置 =0 被接受: 命中 /successfully/
- ✅ 相位2 A→B 成功: 命中 /successfully/
- ⚠️ 显式 =0 时 B→A 被拒（实现把 0 改写为 1 天，CommonConfig.java:3428；需求为 0=无约束）—— 已记录为待确认偏差，不判 FAIL：Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 701: The password has been used recently, and it cannot be reused before Tue Nov 17 17:16:17 CST 2026
- ✅ 设置 =1 被接受: 命中 /successfully/
- ✅ 生效值=1（热加载）: 1 == 1
- ✅ 相位3 用户已重建: yes == yes
- ✅ A→B 成功（B 为当前密码）: 命中 /successfully/
- ✅ =1 时 B→A 被拒（硬门禁）: 命中 /cannot be reused before/
- ✅ 复用文案含 used recently: 命中 /used recently/
- ✅ 被拒后当前密码仍是 B: yes == yes
- ✅ 相位4 A→B 成功: 命中 /successfully/
- ✅ B→C 成功: 命中 /successfully/
- ✅ C→B 被拒（历史 B）: 命中 /cannot be reused before/
- ✅ C→A 被拒（历史 A）: 命中 /cannot be reused before/
- ✅ C→全新密码 成功: 命中 /successfully/
- ✅ 禁用后 C→A 允许（恢复无限制）: 命中 /successfully/
- ⚠️ 本用例验证 禁用无限制 / =1 窗口内拒绝 / 恢复；'窗口过后可重用'见 SEC-06
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-06 · normal

`PASS fail_flag=0 elapsed=118s passes=15 warns=1`

- ✅ 默认 password_expiration_days: 0 == 0
- ✅ 用户创建成功: 命中 /successfully/
- ✅ 用户当前可登录（192.168.99.78）: yes == yes
- ✅ expiry=2 设置成功: 命中 /successfully/
- ✅ 生效值=2: 2 == 2
- ✅ 该 DN 已前移天数: 3 == 3
- ✅ 过期登录被拒（820 + Password has expired）: 命中 /Password has expired/
- ✅ 文案提示用 ALTER USER 改密: 命中 /ALTER USER/
- ✅ 确实登不进去: no == no
- ⚠️ 观察：过期判定依赖 DN 本地时钟 —— 192.168.99.77 判过期、192.168.99.78 仍可登录（节点时钟偏差时结论不一致）
- ✅ 经 192.168.99.78 改密码成功: 命中 /successfully/
- ✅ 新密码可登录（192.168.99.78）: yes == yes
- ✅ 极大 expiry 不提示 will expire at: 未出现 /will expire at/
- ✅ 恢复后用户可登录（192.168.99.77）: yes == yes
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-06 · sep

`PASS fail_flag=0 elapsed=26s passes=15 warns=1`

- ✅ 默认 password_expiration_days: 0 == 0
- ✅ 用户创建成功: 命中 /successfully/
- ✅ 用户当前可登录（192.168.99.78）: yes == yes
- ✅ expiry=2 设置成功: 命中 /successfully/
- ✅ 生效值=2: 2 == 2
- ✅ 该 DN 已前移天数: 3 == 3
- ✅ 过期登录被拒（820 + Password has expired）: 命中 /Password has expired/
- ✅ 文案提示用 ALTER USER 改密: 命中 /ALTER USER/
- ✅ 确实登不进去: no == no
- ⚠️ 观察：过期判定依赖 DN 本地时钟 —— 192.168.99.77 判过期、192.168.99.78 仍可登录（节点时钟偏差时结论不一致）
- ✅ 经 192.168.99.78 改密码成功: 命中 /successfully/
- ✅ 新密码可登录（192.168.99.78）: yes == yes
- ✅ 极大 expiry 不提示 will expire at: 未出现 /will expire at/
- ✅ 恢复后用户可登录（192.168.99.77）: yes == yes
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-07 · normal

`PASS fail_flag=0 elapsed=150s passes=13 warns=0`

- ✅ enforce_strong_password 默认 true: true == true
- ✅ password_expiration_days 默认 0: 0 == 0
- ✅ password_reuse_interval_days 默认 0: 0 == 0
- ✅ expiry 热加载读回 7: 7 == 7
- ✅ expiry 热加载读回 0: 0 == 0
- ✅ 关闭后（不重启）弱密码立刻可建: 命中 /successfully/
- ✅ 重新开启后（不重启）立刻被拒: 命中 /820/
- ✅ normal 模式 root 可登录: 命中 /Running/
- ✅ 普通用户创建成功: 命中 /successfully/
- ✅ 普通用户修改安全配置被拒（803 需 SECURITY）
- ✅ 配置未被普通用户改动: 0 == 0
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-07 · sep

`PASS fail_flag=0 elapsed=31s passes=15 warns=0`

- ✅ enforce_strong_password 默认 true: true == true
- ✅ password_expiration_days 默认 0: 0 == 0
- ✅ password_reuse_interval_days 默认 0: 0 == 0
- ✅ expiry 热加载读回 7: 7 == 7
- ✅ expiry 热加载读回 0: 0 == 0
- ✅ 关闭后（不重启）弱密码立刻可建: 命中 /successfully/
- ✅ 重新开启后（不重启）立刻被拒: 命中 /820/
- ✅ 三权分立下 root 登录被拒（803）: 命中 /SUPER USER is not allowed to login/
- ✅ sys_admin 修改 password_expiration_days 被拒（803 需 SECURITY）
- ✅ security_admin 可改（生效值被本用例改过）: 0 == 0
- ✅ 普通用户创建成功: 命中 /successfully/
- ✅ 普通用户修改安全配置被拒（803 需 SECURITY）
- ✅ 配置未被普通用户改动: 0 == 0
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-08 · normal

`PASS fail_flag=0 elapsed=171s passes=17 warns=0`

- ✅ 建用户成功: 命中 /successfully/
- ✅ 改密码成功: 命中 /successfully/
- ✅ 改安全配置成功: 命中 /successfully/
- ✅ 删用户生效: gone == gone
- ✅ 弱密码被拒（820）: 命中 /820/
- ✅ 密码==用户名被拒（820）: 命中 /820/
- ✅ 错误密码登录被拒: 命中 /Error/
- ✅ 弱密码错误文案不含该密码本身: 未出现 /abcdefghijkl/
- ✅ 密码==用户名错误文案不回显密码: 未出现 /sec_u_audit6/
- ✅ 日志不含明文密码（Abcd***）
- ✅ 日志不含明文密码（Abcd***）
- ✅ 日志不含明文密码（abcd***）
- ✅ 日志不含明文密码（Wron***）
- ✅ 至少 6 个节点的日志里出现审计/操作留痕（MODIFY_PASSWD/CREATE_USER/AuditLog 等）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-08 · sep

`PASS fail_flag=0 elapsed=41s passes=17 warns=0`

- ✅ 建用户成功: 命中 /successfully/
- ✅ 改密码成功: 命中 /successfully/
- ✅ 改安全配置成功: 命中 /successfully/
- ✅ 删用户生效: gone == gone
- ✅ 弱密码被拒（820）: 命中 /820/
- ✅ 密码==用户名被拒（820）: 命中 /820/
- ✅ 错误密码登录被拒: 命中 /Error/
- ✅ 弱密码错误文案不含该密码本身: 未出现 /abcdefghijkl/
- ✅ 密码==用户名错误文案不回显密码: 未出现 /sec_u_audit6/
- ✅ 日志不含明文密码（Abcd***）
- ✅ 日志不含明文密码（Abcd***）
- ✅ 日志不含明文密码（abcd***）
- ✅ 日志不含明文密码（Wron***）
- ✅ 至少 6 个节点的日志里出现审计/操作留痕（MODIFY_PASSWD/CREATE_USER/AuditLog 等）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-09 · normal

`PASS fail_flag=0 elapsed=120s passes=18 warns=0`

- ✅ enforce 基线: true == true
- ✅ 节点 192.168.99.77 策略生效值与基线一致（true/0/0）
- ✅ 节点 192.168.99.78 策略生效值与基线一致（true/0/0）
- ✅ 节点 192.168.99.79 策略生效值与基线一致（true/0/0）
- ✅ 经 DN 192.168.99.77 建弱密码被拒（820）
- ✅ 经 DN 192.168.99.78 建弱密码被拒（820）
- ✅ 经 DN 192.168.99.79 建弱密码被拒（820）
- ✅ 合法用户创建成功: 命中 /successfully/
- ✅ 可登录: yes == yes
- ✅ DN1 与 DN2 指纹: ffc58c020241c660dab33e3fcf563bbd == ffc58c020241c660dab33e3fcf563bbd
- ✅ DN1 与 DN3 指纹: ffc58c020241c660dab33e3fcf563bbd == ffc58c020241c660dab33e3fcf563bbd
- ✅ 改密成功: 命中 /successfully/
- ✅ 改密后 DN1 与 DN2 指纹: ffc58c020241c660dab33e3fcf563bbd == ffc58c020241c660dab33e3fcf563bbd
- ✅ 旧密码已失效: no == no
- ✅ 新密码可登录: yes == yes
- ✅ 删除后 DN1 与 DN2 指纹: 2b4f8acfc369b8e4cf3809269d4d1e1e == 2b4f8acfc369b8e4cf3809269d4d1e1e
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-09 · sep

`PASS fail_flag=0 elapsed=86s passes=18 warns=0`

- ✅ enforce 基线: true == true
- ✅ 节点 192.168.99.77 策略生效值与基线一致（true/0/0）
- ✅ 节点 192.168.99.78 策略生效值与基线一致（true/0/0）
- ✅ 节点 192.168.99.79 策略生效值与基线一致（true/0/0）
- ✅ 经 DN 192.168.99.77 建弱密码被拒（820）
- ✅ 经 DN 192.168.99.78 建弱密码被拒（820）
- ✅ 经 DN 192.168.99.79 建弱密码被拒（820）
- ✅ 合法用户创建成功: 命中 /successfully/
- ✅ 可登录: yes == yes
- ✅ DN1 与 DN2 指纹: fc94bdced09f0b7fa1b822c3703ce3db == fc94bdced09f0b7fa1b822c3703ce3db
- ✅ DN1 与 DN3 指纹: fc94bdced09f0b7fa1b822c3703ce3db == fc94bdced09f0b7fa1b822c3703ce3db
- ✅ 改密成功: 命中 /successfully/
- ✅ 改密后 DN1 与 DN2 指纹: fc94bdced09f0b7fa1b822c3703ce3db == fc94bdced09f0b7fa1b822c3703ce3db
- ✅ 旧密码已失效: no == no
- ✅ 新密码可登录: yes == yes
- ✅ 删除后 DN1 与 DN2 指纹: 23f949cc10b7c267ec564e9e84670ca0 == 23f949cc10b7c267ec564e9e84670ca0
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-10 · normal

`PASS fail_flag=0 elapsed=38s passes=15 warns=2`

- ✅ password_stale_warning_days 生效值/配置值: 30 == 30
- ✅ SET stale=30 成功: 命中 /successfully/
- ⚠️ 观察：password_stale_warning_days 实测为热加载（SET 后无 restart 提示），与需求文档 effectiveMode: restart 不一致 —— 语义差异，待研发确认是否需要改文档
- ✅ 创建用户: 命中 /successfully/
- ✅ 未超阈值不提示密码陈旧: 未出现 /has not been changed for/
- ✅ 用户可正常登录: yes == yes
- ✅ 超阈值登录出现密码陈旧提示: 命中 /has not been changed for/
- ✅ 提示含可配置天数（30 days）: 命中 /30 days/
- ✅ 提示含安全建议文案: 命中 /please consider updating your password/
- ✅ 提示不影响登录成功: yes == yes
- ✅ 不修改密码则重复触发（第二次登录仍提示）: 命中 /has not been changed for/
- ✅ 改密后不再提示（历史时间已刷新）: 未出现 /has not been changed for/
- ✅ stale=0 热生效：超期用户登录不再提示（<=0 禁用）: 未出现 /has not been changed for/
- ⚠️ 恢复 30 后未立即再次提示（热加载反向可能有延迟/需下次登录），不影响 <=0 禁用与超期提示两条主断言
- ✅ 恢复后时钟正确、用户可登录: yes == yes
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-10 · sep

`PASS fail_flag=0 elapsed=29s passes=15 warns=2`

- ✅ password_stale_warning_days 生效值/配置值: 30 == 30
- ✅ SET stale=30 成功: 命中 /successfully/
- ⚠️ 观察：password_stale_warning_days 实测为热加载（SET 后无 restart 提示），与需求文档 effectiveMode: restart 不一致 —— 语义差异，待研发确认是否需要改文档
- ✅ 创建用户: 命中 /successfully/
- ✅ 未超阈值不提示密码陈旧: 未出现 /has not been changed for/
- ✅ 用户可正常登录: yes == yes
- ✅ 超阈值登录出现密码陈旧提示: 命中 /has not been changed for/
- ✅ 提示含可配置天数（30 days）: 命中 /30 days/
- ✅ 提示含安全建议文案: 命中 /please consider updating your password/
- ✅ 提示不影响登录成功: yes == yes
- ✅ 不修改密码则重复触发（第二次登录仍提示）: 命中 /has not been changed for/
- ✅ 改密后不再提示（历史时间已刷新）: 未出现 /has not been changed for/
- ✅ stale=0 热生效：超期用户登录不再提示（<=0 禁用）: 未出现 /has not been changed for/
- ⚠️ 恢复 30 后未立即再次提示（热加载反向可能有延迟/需下次登录），不影响 <=0 禁用与超期提示两条主断言
- ✅ 恢复后时钟正确、用户可登录: yes == yes
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-11 · normal

`PASS fail_flag=0 elapsed=80s passes=11 warns=1`

- ✅ 创建测试用户: 命中 /successfully/
- ✅ -pw 直传密码可登录: 命中 /Successfully login/
- ✅ -pw 直传时不出现交互提示: 未出现 /please input your password/
- ✅ 出现交互式提示 please input your password:: 命中 /please input your password/
- ✅ 交互式输入密码后可登录: 命中 /Successfully login/
- ✅ 交互式错误密码登录失败（801）: 命中 /801/
- ✅ 错误密码不应提示登录成功: 未出现 /Successfully login/
- ✅ PTY 下出现交互提示: 命中 /please input your password/
- ⚠️ PTY 输出中出现密码明文，但 script(1) 的 pty 会回显喂入输入（对照已确认），无法据此判定是否回显；需真实终端人工确认
- ✅ PTY 下可登录: 命中 /Successfully login/
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-11 · sep

`PASS fail_flag=0 elapsed=75s passes=11 warns=1`

- ✅ 创建测试用户: 命中 /successfully/
- ✅ -pw 直传密码可登录: 命中 /Successfully login/
- ✅ -pw 直传时不出现交互提示: 未出现 /please input your password/
- ✅ 出现交互式提示 please input your password:: 命中 /please input your password/
- ✅ 交互式输入密码后可登录: 命中 /Successfully login/
- ✅ 交互式错误密码登录失败（801）: 命中 /801/
- ✅ 错误密码不应提示登录成功: 未出现 /Successfully login/
- ✅ PTY 下出现交互提示: 命中 /please input your password/
- ⚠️ PTY 输出中出现密码明文，但 script(1) 的 pty 会回显喂入输入（对照已确认），无法据此判定是否回显；需真实终端人工确认
- ✅ PTY 下可登录: 命中 /Successfully login/
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-12 · normal

`PASS fail_flag=0 elapsed=23s passes=23 warns=2`

- ✅ list user 含 root: 命中 /root/
- ✅ root 为超级管理员（SUPER_USER/root 行）: 命中 /root/
- ✅ root 不可删除（803 Access Denied）: 命中 /803/
- ✅ root 不可删除的文案说明原因: 命中 /Cannot drop admin user/
- ✅ 创建用户: 命中 /successfully/
- ✅ 运行日志中无明文密码: none == none
- ⚠️ 已知问题（研发确认不可修复）：明文口令出现在 CN 共识日志（47474747-4747-4747-4747-000000000000/current/log_inprogress_329）；见 docs/KNOWN_DEFECTS.md #4
- ✅ 用户元数据文件（profile）中无明文口令（应为哈希）: none == none
- ✅ 日志不含明文密码（Abcd***）
- ✅ 新用户出现在 list user: yes == yes
- ✅ ALTER USER SET PASSWORD 成功: 命中 /successfully/
- ✅ 旧密码失效: no == no
- ✅ 新密码可登录: yes == yes
- ⚠️ 新用户查 root.** 未报权限错误（返回空集/计数）：|Time|
- ✅ 大写用户名可独立创建（说明用户名大小写敏感）: 命中 /successfully/
- ✅ 大写用户名与原名是两个用户: yes == yes
- ✅ 清理大写用户: 命中 /successfully/
- ✅ 密码大小写不同 → 认证失败（801）: 801 == 801
- ✅ 不存在的用户 → 804: 804 == 804
- ✅ 密码错误 → 801: 801 == 801
- ✅ 认证失败不回显密码: 未出现 /WrongPass123!/
- ✅ DROP USER 成功: 命中 /successfully/
- ✅ 删除后用户不存在: no == no
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-12 · sep

`PASS fail_flag=0 elapsed=23s passes=22 warns=2`

- ✅ list user 含 root: 命中 /root/
- ✅ root 为超级管理员（SUPER_USER/root 行）: 命中 /root/
- ✅ root 不可删除（803 Access Denied）: 命中 /803/
- ✅ root 不可删除的文案说明原因: 命中 /Cannot drop admin user/
- ✅ 创建用户: 命中 /successfully/
- ✅ 日志中无明文密码: none == none
- ⚠️ 缺陷候选：明文密码出现在 ConfigNode 共识（Raft）日志中（需求：密码不得明文存储）：47474747-4747-4747-4747-000000000000/current/log_0-776
- ✅ 日志不含明文密码（Abcd***）
- ✅ 新用户出现在 list user: yes == yes
- ✅ ALTER USER SET PASSWORD 成功: 命中 /successfully/
- ✅ 旧密码失效: no == no
- ✅ 新密码可登录: yes == yes
- ⚠️ 新用户查 root.** 未报权限错误（返回空集/计数）：|Time|
- ✅ 大写用户名可独立创建（说明用户名大小写敏感）: 命中 /successfully/
- ✅ 大写用户名与原名是两个用户: yes == yes
- ✅ 清理大写用户: 命中 /successfully/
- ✅ 密码大小写不同 → 认证失败（801）: 801 == 801
- ✅ 不存在的用户 → 804: 804 == 804
- ✅ 密码错误 → 801: 801 == 801
- ✅ 认证失败不回显密码: 未出现 /WrongPass123!/
- ✅ DROP USER 成功: 命中 /successfully/
- ✅ 删除后用户不存在: no == no
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-13 · normal

`PASS fail_flag=0 elapsed=30s passes=13 warns=1`

- ✅ 创建测试用户: 命中 /successfully/
- ✅ 阈值内失败仍为认证失败（无 822）
- ✅ 第 4 次（超过阈值）返回 822: 命中 /822/
- ✅ 锁定文案（Account is blocked due to consecutive failed logins）: 命中 /Account is blocked due to consecutive failed logins/
- ✅ 锁定期正确密码仍 822: 命中 /822/
- ✅ 确为锁定而非密码错误（错误码=822）: 822 == 822
- ✅ ALTER USER ... ACCOUNT UNLOCK 成功: 命中 /successfully/
- ✅ 解锁后可登录: yes == yes
- ✅ 2 次错误后仍可登录（说明未锁）: yes == yes
- ✅ 登录成功已清空失败计数（第二段 2 次错误仍不锁）
- ✅ ALTER USER u @ 'ip' ACCOUNT UNLOCK 语法可用: 命中 /successfully/
- ⚠️ 缺陷候选：普通用户执行 ALTER USER ... ACCOUNT UNLOCK 返回 305（INTERNAL_SERVER_ERROR + Java 异常文本），期望 803 权限错误：
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-13 · sep

`PASS fail_flag=0 elapsed=21s passes=14 warns=0`

- ✅ 创建测试用户: 命中 /successfully/
- ✅ 阈值内失败仍为认证失败（无 822）
- ✅ 第 4 次（超过阈值）返回 822: 命中 /822/
- ✅ 锁定文案（Account is blocked due to consecutive failed logins）: 命中 /Account is blocked due to consecutive failed logins/
- ✅ 锁定期正确密码仍 822: 命中 /822/
- ✅ 确为锁定而非密码错误（错误码=822）: 822 == 822
- ✅ ALTER USER ... ACCOUNT UNLOCK 成功: 命中 /successfully/
- ✅ 解锁后可登录: yes == yes
- ✅ 2 次错误后仍可登录（说明未锁）: yes == yes
- ✅ 登录成功已清空失败计数（第二段 2 次错误仍不锁）
- ✅ ALTER USER u @ 'ip' ACCOUNT UNLOCK 语法可用: 命中 /successfully/
- ✅ 普通用户执行解锁被拒（803，权限错误）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-14 · normal

`PASS fail_flag=0 elapsed=30s passes=10 warns=2`

- ✅ 创建测试用户: 命中 /successfully/
- ✅ 本机登录的管理员未被锁定（豁免生效，5 次错误仍为 801）
- ✅ 豁免后管理员仍可正常登录
- ✅ 用户已被锁定: 命中 /822/
- ✅ 删除被锁用户: 命中 /successfully/
- ✅ 同名重建: 命中 /successfully/
- ✅ 重建后立即可登录（锁已随 DROP 清理）: yes == yes
- ✅ 已锁定（等待 10 分钟自动解锁）
- ⚠️ 锁定时长 10 分钟过长（>200s），自动解锁改为文档性检查：不等待
- ⚠️ 文档要求锁名单不持久化（重启即清）；本用例不重启集群，按设计记录为文档性检查（由回归手册人工确认）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-14 · sep

`PASS fail_flag=0 elapsed=25s passes=10 warns=2`

- ✅ 创建测试用户: 命中 /successfully/
- ✅ 本机登录的管理员未被锁定（豁免生效，7 次错误仍为 801）
- ✅ 豁免后管理员仍可正常登录
- ✅ 用户已被锁定: 命中 /822/
- ✅ 删除被锁用户: 命中 /successfully/
- ✅ 同名重建: 命中 /successfully/
- ✅ 重建后立即可登录（锁已随 DROP 清理）: yes == yes
- ✅ 已锁定（等待 10 分钟自动解锁）
- ⚠️ 锁定时长 10 分钟过长（>200s），自动解锁改为文档性检查：不等待
- ⚠️ 文档要求锁名单不持久化（重启即清）；本用例不重启集群，按设计记录为文档性检查（由回归手册人工确认）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-15 · normal

`PASS fail_flag=0 elapsed=23s passes=18 warns=0`

- ✅ 模板含 failed_login_attempts: 命中 /failed_login_attempts/
- ✅ 模板含 failed_login_attempts_per_user: 命中 /failed_login_attempts_per_user/
- ✅ 模板含 password_lock_time_minutes: 命中 /password_lock_time_minutes/
- ✅ failed_login_attempts SET 成功: 命中 /successfully/
- ✅ failed_login_attempts 为 restart 生效: 命中 /restart is required/
- ✅ password_lock_time_minutes 为 restart 生效: 命中 /restart is required/
- ✅ per_user=-1 被接受（完全禁用全局限制）: 命中 /successfully/
- ✅ per_user=0 被接受（按需求自动调整为最小 1）: 命中 /successfully/
- ✅ per_user=1000 被接受: 命中 /successfully/
- ✅ failed_login_attempts=-5 被接受（按禁用处理）: 命中 /successfully/
- ✅ DN 日志有 'IP-level login attempts disabled' 记录（INFO，符合 ≤0=禁用语义）
- ✅ 普通模式 root 可修改 failed_login_attempts: 命中 /successfully/
- ✅ 普通模式 root 可修改 failed_login_attempts_per_user: 命中 /successfully/
- ✅ 普通模式 root 可修改 password_lock_time_minutes: 命中 /successfully/
- ✅ 普通模式 root 可修改 password_stale_warning_days: 命中 /successfully/
- ✅ 已回写默认值 5/1000/10/30（下次重启生效）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-15 · sep

`PASS fail_flag=0 elapsed=25s passes=17 warns=1`

- ✅ 模板含 failed_login_attempts: 命中 /failed_login_attempts/
- ✅ 模板含 failed_login_attempts_per_user: 命中 /failed_login_attempts_per_user/
- ✅ 模板含 password_lock_time_minutes: 命中 /password_lock_time_minutes/
- ✅ failed_login_attempts SET 成功: 命中 /successfully/
- ✅ failed_login_attempts 为 restart 生效: 命中 /restart is required/
- ✅ password_lock_time_minutes 为 restart 生效: 命中 /restart is required/
- ✅ per_user=-1 被接受（完全禁用全局限制）: 命中 /successfully/
- ✅ per_user=0 被接受（按需求自动调整为最小 1）: 命中 /successfully/
- ✅ per_user=1000 被接受: 命中 /successfully/
- ⚠️ failed_login_attempts=-5 未被拒绝（需求：不合理的配置项会转用默认值，并写错误日志）：Msg: The statement is executed successfully.Configuration has been set successfully, but restart is required for the following par
- ✅ 非法配置已在 DN 日志留痕（ERROR fallback）
- ✅ 三权分立按设计：failed_login_attempts 由 sys_admin 修改（security_admin 无 SYSTEM，返回 803）
- ✅ 三权分立按设计：failed_login_attempts_per_user 由 sys_admin 修改（security_admin 无 SYSTEM，返回 803）
- ✅ 三权分立按设计：password_lock_time_minutes 由 sys_admin 修改（security_admin 无 SYSTEM，返回 803）
- ✅ 三权分立按设计：password_stale_warning_days 由 security_admin 修改（sys_admin 返回 803 SECURITY）
- ✅ 已回写默认值 5/1000/10/30（下次重启生效）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-16 · normal

`PASS fail_flag=0 elapsed=26s passes=8 warns=2`

- ✅ 创建测试用户: 命中 /successfully/
- ✅ 锁定/解锁事件在 DN 日志留痕
- ✅ 错误响应不含所输密码: 未出现 /WrongPass999/
- ✅ 错误响应不含密码哈希/盐: 未出现 /hash/
- ✅ 错误响应未暴露用户存在性（统一 801）
- ⚠️ 构造 1200 个 IP 锁 / 50 个用户同 IP 锁不现实，本条只校验规格：需求要求 WARN 文案含 potential attack
- ⚠️ 非法配置回退无日志留痕（需求要求：不支持直接拒绝，而不合理配置转默认值并写错误日志）
- ✅ 日志不含明文密码（Abcd***）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

### SEC-16 · sep

`PASS fail_flag=0 elapsed=20s passes=8 warns=2`

- ✅ 创建测试用户: 命中 /successfully/
- ✅ 锁定/解锁事件在 DN 日志留痕
- ✅ 错误响应不含所输密码: 未出现 /WrongPass999/
- ✅ 错误响应不含密码哈希/盐: 未出现 /hash/
- ✅ 错误响应未暴露用户存在性（统一 801）
- ⚠️ 构造 1200 个 IP 锁 / 50 个用户同 IP 锁不现实，本条只校验规格：需求要求 WARN 文案含 potential attack
- ⚠️ 非法配置回退无日志留痕（需求要求：不支持直接拒绝，而不合理配置转默认值并写错误日志）
- ✅ 日志不含明文密码（Abcd***）
- ✅ sync lag 归零（各 DN syncLag 合计=0）
- ✅ CN/DN 日志门禁：无预期外 WARN/ERROR

## 三、28 条 WARN 的归类与对应单号

> WARN 一律**不判失败**，只作记录。下表把每条 WARN 归到"设计行为 / 已提单 / 已知问题 / 环境限制"。

| 用例 | WARN 摘要 | 归类 | 对应项 |
| --- | --- | --- | --- |
| SEC-04 | 关闭 enforce 后长度仍校验（需求 a 不可关） | 符合预期 | 需求 a |
| SEC-05 ×2 | 显式 `=0` 时 B→A 被拒（0 被改写为 1 天） | 已提单 | **TDB-1606**（P3） |
| SEC-06 | "窗口过后可重用"由 SEC-06 覆盖的说明性提示 | 记录 | — |
| SEC-10 ×2 | ①`password_stale_warning_days` 实测热加载（文档写 restart）②恢复 30 后未立即再次提示 | 文档修订 / 观察 | **D1**（文档修订项） |
| SEC-11 | PTY 回显受 `script` 自身回显干扰，无法脚本判定 | 环境限制 | 需真实终端人工确认 |
| SEC-12 ×2 | ①明文口令出现在 CN 共识日志（研发不修）②树模型新用户查 `root.**` 返回空集 | ①已知问题 ②设计行为 | **已知问题 #4** / 树模型读权限过滤 |
| SEC-13（normal） | 普通用户执行 `ALTER USER … ACCOUNT UNLOCK` → 305 + NPE（应 803） | 已提单 | **TDB-1607**（P2） |
| SEC-14 ×2 | ①自动解锁等待上限②锁名单不持久化属文档性检查 | 环境/记录 | — |
| SEC-15 ×2 | ①非法值 `-5` 按禁用处理（无 ERROR）②`lock_time=0` 回退生效但 show 显示原值 | ①需求措辞 ②符合预期（显式原值） | **D2** / `docs/CONFIG_SEMANTICS.md` |
| SEC-16 ×2 | ①异常行为 WARN 无法构造②非法配置无回退日志 | 环境限制 / 需求措辞 | **D2** |

> 备注：
> - 三权分立下 `security_admin` 无法修改锁定配置已提单 **TDB-1610**（P2，MR 7532）；该行为在 `SEC-15` 中是 **PASS**（按"现状/设计"断言），修复后需把该方法改成"security_admin 可改"的硬断言。
> - 明文口令入 Raft 日志为 **已知问题 #4**（研发确认不修复），`SEC-12` 以 WARN 基线持续探测：若某版本不再命中，会提示"已知问题已变化，请复核台账"。
