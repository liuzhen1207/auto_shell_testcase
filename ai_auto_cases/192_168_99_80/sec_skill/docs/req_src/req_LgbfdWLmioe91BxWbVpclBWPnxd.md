V2.0.7.1-安全模块-身份鉴别-密码定期更改提示&客户端隐去明文密码-需求分析
版本变更记录


操作日期

文档版本

操作人

内容

2025.9.10

V0.1

高宏志

创建初始文档
一、需求描述
提醒用户定期更新密码。
当前start-cli.sh使用-pw参数明文输入密码。需求是增加交互式输入密码，并隐去客户端交互时的输入密码
二、产品调研
客户使用场景调研
无
常见竞品调研
密码定期更新
主流数据库通常不具备主动提醒用户定期修改密码的功能，但会在密码即将到期时提示用户，或在密码过期后的首次登录时要求用户修改密码。
密码输入

三、功能定义
功能描述
新增密码定期提醒功能，当用户登录时，若密码已长期（可配置天数）未修改，则提醒用户修改密码。密码不修改会重复触发。控制台登录成功后会显示Your password has not been changed for 30 days. For security best practices, please consider updating your password
新增交互式输入密码功能，在用户输入-pw参数且没有键入密码，进入交互式输入，且隐去输入密码。
保留-pw password输入方式。
功能定义
配置项


# The number of days since last password change to trigger a warning
# Options: any positive integer(minimum 1), <= 0 means disabled (no warning)
# effectiveMode: restart
# Datatype: Integer
password_stale_warning_days=30

# Example warning message when password has been stale for too long:
# "Warning: Your password has not been changed for 30 days. 
#  For security best practices, please consider updating your password."
密码输入如下（隐去*号,补充-pw）

PS D:\workspace\iotdb\distribution\target\apache-iotdb-2.0.6-SNAPSHOT-all-bin\apache-iotdb-2.0.6-SNAPSHOT-all-bin\sbin> .\windows\start-cli.bat
Active code page: 65001
-h 127.0.0.1 -p 6667 -u root -sql_dialect tree -pw 
please input your password:
---------------------
Starting IoTDB Cli
---------------------
 _____       _________  ______   ______
|_   _|     |  _   _  ||_   _ `.|_   _ \
  | |   .--.|_/ | | \_|  | | `. \ | |_) |
  | | / .'`\ \  | |      | |  | | |  __'.
 _| |_| \__. | _| |_    _| |_.' /_| |__) |
|_____|'.__.' |_____|  |______.'|_______/  version 2.0.6-SNAPSHOT (Build: 7cd568c-dev)


Successfully login at 127.0.0.1:6667
IoTDB>

image.png

非功能定义
性能要求
兼容性要求
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

是

审计和日志记录



该功能的关键操作是否需要被记录到审计日志中？

否



该功能的审计日志是否包含 “操作人、操作时间、操作内容、客户端 IP、操作结果” 等关键信息？

否

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

否

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
四、自测及测试场景建议
无
附录：历史内容及讨论记录
