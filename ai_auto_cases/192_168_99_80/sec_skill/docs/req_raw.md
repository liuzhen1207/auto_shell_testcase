V2.0.7.1-安全模块-身份鉴别-强安全级别密码-需求分析
版本变更记录


操作日期

文档版本

操作人

内容

2025.6.3

V0.1（初始版本）

江天

创建初始文档

2025.10.23

V0.2

江天

更新密码临近过期时的提示条件
一、需求描述
EAL4 安全认证提出了以下需求：
TSF（即数据库系统）应提供一种机制以验证秘密满足【赋值:一个既定的质量度量】。例如用户口令验证需满足: 
a) 被限制在最小和最大数量的字符长度之间; 
b) 包含一个大写和小写字符的组合; 
c) 至少包含一个数字字符; 
d) 至少包含一个特殊字符; 
e) 不能是用户标识或用户名称; 
f) 被限制在一个有效期内; 
g) 以前使用的口令需在多少天数内无法再度使用等。
本文档预计支持的目标为 a) - g)，即申报材料中应填写：
TSF（即数据库系统）应提供一种机制以验证秘密满足a) 被限制在最小和最大数量的字符长度之间; b) 包含一个大写和小写字符的组合;c) 至少包含一个数字字符; d) 至少包含一个特殊字符; e) 不能是用户名称；f) 被限制在一个可配置的有效期内;g) 以前使用的口令在一个可配置的天数内无法再度使用。
二、产品调研
常见竞品调研
1. Oracle Database
复杂度要求:
默认启用密码校验函数（ORA12C_STRONG_VERIFY_FUNCTION 或自定义函数）。
要求：最小长度（通常8位）、包含大小写字母、数字、特殊字符、避免用户名或常见单词。
有效期：密码会过期（默认180天），可配置 PASSWORD_LIFE_TIME。
历史记录：禁止重用旧密码（PASSWORD_REUSE_MAX 控制次数）。
配置方式：通过 Profile 管理（如 ALTER PROFILE DEFAULT LIMIT PASSWORD_VERIFY_FUNCTION ora12c_strong_verify_function;）。

密码过期时间的配置方式（单位为天）：
Oracle 配置密码过期时间
-- 创建新配置文件
CREATE PROFILE my_profile LIMIT
  PASSWORD_LIFE_TIME 180
  PASSWORD_GRACE_TIME 10;
-- 将配置文件分配给用户
ALTER USER 用户名 PROFILE my_profile;
其中 PASSWORD_GRACE_TIME 为宽限时间，即如果配置了该项，在密码已使用时间大于等于 PASSWORD_LIFE_TIME 但是小于 PASSWORD_LIFE_TIME + PASSWORD_GRACE_TIME 时，只提示密码过期不拒绝登录，即登陆成功后显示“ORA-28002: the password will expire within X days”；当密码已使用时间大于等于 PASSWORD_LIFE_TIME + PASSWORD_GRACE_TIME 时，拒绝登录并提示“ORA-28001: the password has expired”。


2. Microsoft SQL Server
复杂度要求（仅适用于 SQL 身份验证）：
长度 ≥ 8 个字符。
包含大写字母、小写字母、数字、特殊字符中的至少三类。
有效期：可配置密码过期策略（CHECK_EXPIRATION = ON）。
历史记录：防止重用旧密码（CHECK_POLICY = ON 继承 Windows 策略）。
其他：推荐使用 Windows 身份验证（集成安全）替代 SQL 登录。

因为 SQL Server 继承 Windows 的密码过期策略，无法直接通过 SQL Server 进行设置。
密码过期时，登录提示“用户"%.*ls"登录失败。原因: 该帐户的密码已过期。”

3. MySQL / MariaDB
复杂度要求（需安装组件）：
通过 validate_password 组件（MySQL 5.7+）或 cracklib（MariaDB）强制策略。
可配置：最小长度、数字/大小写/特殊字符要求、禁止字典单词。
有效期：支持密码过期（ALTER USER ... PASSWORD EXPIRE;）。
历史记录：MySQL 8.0+ 支持密码重用限制（password_history）。

过期时间全局设置（影响所有用户）

-- 设置全局密码过期策略为默认90天过期
SET GLOBAL default_password_lifetime = 90;
或者修改配置文件my.cnf（或my.ini）：

[mysqld]
default_password_lifetime = 90
为特定用户设置密码过期

-- 设置用户密码立即过期（下次登录必须修改密码）
ALTER USER 'user'@'localhost' PASSWORD EXPIRE;
-- 设置用户密码在指定天数后过期
ALTER USER 'user'@'localhost' PASSWORD EXPIRE INTERVAL 180 DAY;
-- 禁用该用户的密码过期（覆盖全局设置）
ALTER USER 'user'@'localhost' PASSWORD EXPIRE NEVER;
-- 用户遵循全局过期策略
ALTER USER 'user'@'localhost' PASSWORD EXPIRE DEFAULT;
密码过期时，提示：ERROR 1862 (HY000): Your password has expired. To log in you must change it using a client that supports expired passwords.

4. PostgreSQL
复杂度要求（需第三方模块）：
原生无强制复杂度，可通过 pgcrypto 或 passwordcheck 扩展实现。
常见实践：最小长度、禁止纯数字、包含非字母字符。
有效期：不支持原生密码过期，需外部工具管理。
历史记录：无内置支持。

5. MongoDB
复杂度要求：
建议最小长度（如12字符），但无内置强制策略。
通过第三方工具或应用层实现复杂度规则。

三、功能定义
功能描述
通过本功能，数据库管理员可以设置对密码的强度要求、过期时间、重用策略。
功能定义
在 iotdb-system.properties 配置文件中增加配置项 enforce_strong_password，默认值为 true。
当设置为 true 时，在新建用户或修改已有用户密码时，密码需要满足下列要求，否则阻止该行为并报错：
a) 被限制在最小(12)和最大数量(32)的字符长度之间（注意，即使不开启 enforce_strong_password，这一条也生效）; 
b) 包含一个大写和小写字符的组合; 
c) 至少包含一个数字字符; 
d) 至少包含一个特殊字符; 
e) 不能是用户名称。
修改该配置不影响已有的密码使用。

在 iotdb-system.properties 配置文件中增加配置项 password_expiration_days，默认值为 0（代表无过期时间）。
当设置值大于 0 时，用户从上次修改密码（新用户以用户创建时间作为上次修改时间）起至当前时间的时间跨度如果超过该配置值，则拒绝用户登录并提示用户修改密码：Password has expired, please use "ALTER USER" to change to a new one
如果密码未过期，并且 password_expiration_days > 0 以及过期时间在三天之内则会提示密码过期时间："Your password will expire at <密码过期时间点>"；否则与之前保持一致。提示时，如果过期时间的时间戳超过了 int64 的表示范围，则会不提示。
已登录的会话不会因为密码过期被踢出。

在 iotdb-system.properties 配置文件中增加配置项 password_reuse_interval_days，默认值为 0（代表无历史密码约束）。
当设置值大于 0 时，用户修改密码后将对旧密码进行记录与匹配，如果新密码与某一个历史密码相同，并且该历史密码的最后一次修改时间至今的时间跨度小于该配置值，则拒绝本次密码修改并报错：The password has been used recently, and it cannot be reused before <下次可用时间>。
安全性要求


自查内容

说明

自查结果

身份验证和授权


该功能是否涉及用户身份验证逻辑？

是



是否确保仅通过验证的合法用户可使用功能？

是



是否确保仅被授予权限的合法用户可使用功能？

是

完整性


该功能是否能保证数据在传输、计算和存储过程中不被泄露、篡改或越权访问？

无关

审计和日志记录



该功能的关键操作是否需要被记录到审计日志中？

是



该功能的审计日志是否包含 “操作人、操作时间、操作内容、客户端 IP、操作结果” 等关键信息？

是

错误处理和异常管理

该功能是否合理处理运行时错误，避免报错信息泄露敏感内容？

是



是否监控异常行为，并触发告警或限制操作？

是



异常日志是否仅记录必要信息，不包含敏感数据？

是

安全配置

该功能相关的默认配置是否安全，如无默认弱密码、默认启用必要的安全开关？ 

是



是否适配安全更新机制，如后续发现漏洞时，可通过补丁更新、配置调整修复，无需大规模修改代码？

是



是否提供安全配置指引，如提醒用户修改默认密码、限制端口访问范围？

是



是否暴露新的端口，该端口是否安全？

无关

输入验证

该功能是否对所有用户输入进行验证，如数据类型、格式、范围校验，避免非法输入？

是



是否通过输入过滤防止注入攻击，如 SQL 注入、跨站脚本（XSS）等？

是



对超出预期的输入是否直接拒绝，而非仅做警告处理？

是

访问控制


该功能是否涉及在权限方面进行控制？

是



是否遵循 “最小权限原则”？

是



是否通过访问控制列表（ACL）或角色机制，定义哪些用户或组可以访问哪些资源？

是
场景示例
完成计划


功能内容

预计排期

enforce_strong_password

本版本

password_expiration_days

本版本

password_reuse_interval_days

本版本

用户粒度的过期时间配置

待排期
四、非功能定义
兼容性
默认打开强安全密码可能会影响包含修改用户密码或创建用户的测试用例，需要测试组修改相应用例。
默认密码修改后，一方面已有测试用例也有可能受到影响，另一方面已有用户升级后，新的 Cli 等脚本中的默认密码将无法作用于已有集群，需要选择执行下列之一：1.升级后修改 Cli 中的默认密码；2.使用脚本时手动指定密码；3.升级时跳过对应脚本。
集群升级后，在一个没有密码修改历史的用户首次登录时，以当前时间作为其密码的上次修改时间进行记录。
性能
本功能不涉及性能要求。
安全性


自查内容

说明

自查结果

身份验证和授权


该功能是否涉及用户身份验证逻辑？

是



是否确保仅通过验证的合法用户可使用功能？

是



是否确保仅被授予权限的合法用户可使用功能？

是

完整性


该功能是否能保证数据在传输、计算和存储过程中不被泄露、篡改或越权访问？

无关

审计和日志记录



该功能的关键操作是否需要被记录到审计日志中？

仅限配置项修改



该功能的审计日志是否包含 “操作人、操作时间、操作内容、客户端 IP、操作结果” 等关键信息？

是

错误处理和异常管理

该功能是否合理处理运行时错误，避免报错信息泄露敏感内容？

是



是否监控异常行为，并触发告警或限制操作？

是



异常日志是否仅记录必要信息，不包含敏感数据？

是

安全配置

该功能相关的默认配置是否安全，如无默认弱密码、默认启用必要的安全开关？ 

是



是否适配安全更新机制，如后续发现漏洞时，可通过补丁更新、配置调整修复，无需大规模修改代码？

是



是否提供安全配置指引，如提醒用户修改默认密码、限制端口访问范围？

无关


输入验证

该功能是否对所有用户输入进行验证，如数据类型、格式、范围校验，避免非法输入？

是



是否通过输入过滤防止注入攻击，如 SQL 注入、跨站脚本（XSS）等？

无关



对超出预期的输入是否直接拒绝，而非仅做警告处理？

是

访问控制


该功能是否涉及在权限方面进行控制？

是



是否遵循 “最小权限原则”？

是



是否通过访问控制列表（ACL）或角色机制，定义哪些用户或组可以访问哪些资源？

是

安全测试

该功能是否支持安全漏洞扫描？

是



该功能是否便于开展渗透测试？

是



该功能上线前是否需通过专项安全测试？

是
五、自测及测试场景建议
开启 enforce_strong_password，使用弱密码创建用户失败；
开启 enforce_strong_password，使用强密码创建用户成功；
设置 password_expiration_days 大于 0，等待 password_expiration_days 后尝试连接，失败；
设置 password_reuse_interval_days 大于 0，将密码从 A 修改为 B，立即尝试从 B 修改为 A，失败；等待 password_reuse_interval_days 后从 B 修改为 A，成功。 
附录：历史内容及讨论记录

