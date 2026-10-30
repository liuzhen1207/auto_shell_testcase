V2.0.7.1-安全模块-身份鉴别-防止口令暴力破解-需求分析


操作日期

文档版本

操作人

内容

2025.9.8

V0.1（初始版本）

高宏志

创建初始文档

2025.9.16


v1.0（正式评审版本）

高宏志

调研MySQL登录报错信息；去掉可配置的登录安全名单机制；新增手动解锁UNLOCK语句；调整文档目录结构；补充对应到需求模板中的缺失章节；补充相关内存数据结构设计； 补充本地登录IP的检测方案；补充调研修改系统时钟需要的权限

2025.10.10

V1.1

高宏志

修改解锁SQL语法
一、需求描述
IoTDB V2.x.x的登录对于密码错误无任何限制，攻击者可以通过穷举法轻易破解比较简单的密码，从而获取系统控制权限。因此需要对用户登录时密码输入的错误次数进行限制。
在加上限制的基础上，还要考虑的情况是攻击者故意对某个用户（例如管理员）反复输入错误密码，导致该用户无法正常登录的情况。
二、相关调研
客户使用场景调研
常见竞品调研
MySQL与Oracle账户锁定功能

MySQL登录报错信息
用户名不存在

~$ mysql -u wrong_iotdb -p
Enter password:
ERROR 1045 (28000): Access denied for user 'wrong_iotdb'@'localhost' (using password: YES)
密码输入错误

~$ mysql -u iotdb -pWrongPass123
ERROR 1045 (28000): Access denied for user 'iotdb'@'localhost' (using password: YES)
对于已经设置了密码锁定策略的用户（只能给已经存在的用户设置）。多次密码输入错误，账户被锁定

~$ mysql -u iotdb -pWrongPass123
ERROR 3955 (HY000): Access denied for user 'iotdb'@'localhost'. Account is blocked for 1 day(s) (1 day(s) remaining) due to 3 consecutive failed logins.

对于不存在的用户反复输入错误密码不会导致该用户被锁定
建议：隐去报错信息
Mysql安全策略与系统时间戳
Windows/macos/linux修改系统时间戳均需要管理员/超级用户权限。
MySQL的密码锁定时间依赖系统时间戳。
账户“iotdb”密码多次输入错误被锁定1天，修改系统系统时间戳+2 days，“iotdb”已被解锁

hongzhi@LAPTOP-98LI931I:~$ mysql -u iotdb -pIotDB@2025
mysql: [Warning] Using a password on the command line interface can be insecure.
ERROR 3955 (HY000): Access denied for user 'iotdb'@'localhost'. Account is blocked for 1 day(s) (1 day(s) remaining) due to 3 consecutive failed logins.
hongzhi@LAPTOP-98LI931I:~$ date
Tue Sep 16 16:20:08 CST 2025
hongzhi@LAPTOP-98LI931I:~$ sudo date -s "+2 days"
Thu Sep 18 16:20:22 CST 2025
hongzhi@LAPTOP-98LI931I:~$ mysql -u iotdb -pIotDB@2025
mysql: [Warning] Using a password on the command line interface can be insecure.
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 29
Server version: 8.0.43-0ubuntu0.24.04.1

Copyright (c) 2000, 2025, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql>
三、功能定义
功能描述
为提升系统安全性，防止用户密码被暴力破解，本功能引入了基于用户与用户@IP的双重登录失败锁定机制，支持自动解锁，并为特权管理账户（如 root 用户及三权分立后的安全管理员 本机）提供豁免。
功能定义
配置项定义


# The maximum number of consecutive failed login attempts for a specific user@address
# Options: any positive integer
# effectiveMode: restart
# Datatype: Integer
# Note: When enabled, failed_login_attempts_per_user must also be enabled
failed_login_attempts=5

# The maximum number of consecutive failed login attempts for a specific user (global)
# Options:
#   -1 = Completely disable global user-level restrictions (overrides master switch)
#    0 = Automatically adjusted to minimum value 1
#   ≥1 = Custom attempt threshold
# effectiveMode: restart
# Datatype: Integer
# Note: Must be enabled if failed_login_attempts is enabled
failed_login_attempts_per_user=1000

# The lock time duration (in minutes) after reaching failed login attempts threshold
# Options: any positive integer
# effectiveMode: restart
# Datatype: Integer
password_lock_time_minutes=10
限制生效
管理粒度：
用户@IP级别：同一用户从同一地址连续failed_login_attempts次失败后，锁定该用户@地址组合。password_lock_time_minutes配置锁定时间（分钟）。
用户级别：同一用户从任意地址累计failed_login_attempts_per_user失败后，全局锁定该用户。
失败提示：返回Error: 822: Account is blocked due to consecutive failed logins.
解除限制
自动解除：锁定时间（password_lock_time_minutes）到期后自动移除登陆锁定名单。
手动解除：

豁免限制
豁免用户
本机登录的root或安全管理员不会因为密码输入错误被锁定。
登录锁定名单
登录锁定名单在DN内存中，不持久化。
Key
全局锁：username
针对用户的所有登录尝试计数。
精细锁：username@ip
针对某个用户在某个 IP 的登录尝试计数。
username->userid
value：UserLockInfo 对象

static class UserLockInfo {
    // Deque to store timestamps of failed attempts (milliseconds)
    private final Deque<Long> failureTimestamps = new ConcurrentLinkedDeque<>();
}
非功能定义
性能要求
用户锁定名单的最大条目≈用户数×1000(用户级别最大尝试次数)。登录锁定名单清理耗时

兼容性要求
无
安全性要求
权限要求
新增配置只可由 root 或安全管理员修改
Unlock语句只可由 root 或安全管理员执行
内存占用
避免登录锁定名单内存占用过高。ASCII编码，每条记录主要包括：
Key（username + @ + IP）：
IPv4：username(8) + @ + IP(15) ≈ 24 B
IPv6：username(8) + @ + IP(39) ≈ 48 B
Value（UserLockInfo）：
int + long ≈ 12 B，取 16 B（方便对齐）
Node/Entry（map 内部）：
key/value 引用 + next ≈ 24 B
每条内存记录

不同条目数占用内存


安全风险
用户锁定名单容量飙升
假设failed_login_attempts_per_user=1000。该用户下最多出现约1000条条目。用户锁定名单≈用户数×1000。搭配IP白名单功能使用可有效降低该风险。
用户名泄漏风险
黑客暴力尝试用户名字符串，直到获得“密码错误，用户被锁定”的报错信息，可能导致用户名泄漏。但在MySQL中，开启了登录锁定后也会报类似错误。 
区别是MySQL只能特定用户开启，而本方案针对所有用户。
用户名通常不作为一个秘密进行保护，单纯的用户名泄露对系统威胁极低。
锁表不持久化的安全风险
重启后锁会消失。用户可以重新尝试登录。
运营日志
单用户下 IP 锁过多

[WARN] 2025-09-17 12:00:01 - User 'alice' has 1200 IP locks within 10 minutes → potential attack
单 IP 被锁定多用户，考虑加入黑名单

[WARN] 2025-09-17 12:00:01 - IP '192.168.1.100' locked by 50 different users → potential attack
锁定与解锁

[INFO] 2025-09-17 12:00:01 - User 'alice' locked due to 5 failed attempts
[INFO] 2025-09-17 12:00:05 - IP '192.168.1.100' locked for user 'alice'
[INFO] 2025-09-17 12:10:00 - User 'alice' unlocked (manual)
[INFO] 2025-09-17 12:15:00 - IP '192.168.1.100' for user 'alice' unlocked (expired)


自查内容

说明

自查结果

身份验证和授权


该功能是否涉及用户身份验证逻辑？

是



是否确保仅通过验证的合法用户可使用功能？

仅限配置项修改



是否确保仅被授予权限的合法用户可使用功能？

仅限配置项修改

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

是

输入验证

该功能是否对所有用户输入进行验证，如数据类型、格式、范围校验，避免非法输入？

是



是否通过输入过滤防止注入攻击，如 SQL 注入、跨站脚本（XSS）等？

无关



对超出预期的输入是否直接拒绝，而非仅做警告处理？

否，不合理的配置项会转用默认值

访问控制


该功能是否涉及在权限方面进行控制？

仅限配置项修改



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
四、自测及相关调研
无
附录：历史内容及讨论记录
2025.9.16 意见要求。调研MySQL登录报错信息；去掉可配置的登录安全名单机制；新增手动解锁UNLOCK语句；调整文档目录结构；补充对应到需求模板中的缺失章节；补充相关内存数据结构设计； 补充本地登录IP的检测方案；补充调研修改系统时钟需要的权限
