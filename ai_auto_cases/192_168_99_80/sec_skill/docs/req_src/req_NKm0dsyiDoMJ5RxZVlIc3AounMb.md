V2.0.7.1-安全模块-身份鉴别-防止口令暴力破解-技术设计
版本变更记录


操作日期

文档版本

操作人

内容

2025.9.19

V0.1（初始版本）

高宏志

创建初始文档

2025.10.10

V0.2

高宏志

修改解锁操作语法UNLOCK USER -> ALTER USER xxx ACCOUNT UNLOCK
设计背景
IoTDB V2.x.x 版本的用户登录认证过程中，对密码错误次数无任何限制，攻击者可通过暴力穷举方式破解用户密码，存在严重的安全风险。为防止此类攻击，需引入基于用户与用户@IP的双重登录失败锁定机制，并在实现安全目标的同时保证系统的可用性与性能。
设计目标
解决问题​：
如何管理用户的登录失败尝试
提供怎样的接口去进行用户解锁
如何识别特权用户以及本机登录
如何辅助 DBA 识别可能的攻击事件
解决方向与模块划分​：
无
功能目标​：
防止暴力破解用户口令。
避免攻击者通过频繁错误登录故意锁定合法用户。
支持自动解锁与手动解锁机制。
对特权用户（如 root 或安全管理员）提供本机登录豁免。
非功能目标​：
低延迟：登录认证流程增加耗时可接受
内存可控：锁表内存占用需在可接受范围内。
整体设计
3.1 系统架构概览
无
3.2 数据流与处理
补充：DROP USER要清理锁
flowchart TD
  %% --- 主流程 ---
  S([用户尝试登录]) --> CHECKEXEMPT{是否为豁免用户?}

  CHECKEXEMPT -->|是| VERIFY[验证密码]
  CHECKEXEMPT -->|否| CHECKLOCK{是否已被锁定}

  CHECKLOCK -->|User_IP 已锁定| REJ_IP[拒绝登录]
  CHECKLOCK -->|User 已锁定| REJ_USER[拒绝登录]
  CHECKLOCK -->|未锁定| VERIFY

  VERIFY -->|成功| SUCCESS[登录成功]
  SUCCESS --> CLEAR[非豁免用户清空 User_IP 和 User 的失败计数]

  VERIFY -->|失败| INC_IP[User_IP 失败计数 +1]
  INC_IP --> IP_THRESH{是否达到 User_IP 阈值}
  IP_THRESH -->|是| LOCK_IP[锁定 User_IP - 锁时长生效]
  IP_THRESH -->|否| INC_USER

  INC_IP --> INC_USER[User 全局失败计数 +1]
  INC_USER --> USER_THRESH{是否达到 User 全局阈值}
  USER_THRESH -->|是| LOCK_USER[锁定 User - 锁时长生效]
  USER_THRESH -->|否| RESP_FAIL[返回访问拒绝错误]

  LOCK_IP --> LOG_LOCK_IP[User_IP 被锁定] --> REJ_IP
  LOCK_USER --> LOG_LOCK_USER[User 被锁定] --> REJ_USER

  %% --- 管理与后台 ---
  subgraph Admin_Background [管理与后台任务]
    ADMIN_UNLOCK[管理员解锁 User 或 User_IP]
    AUTO_CLEAN[后台清理过期锁]
    ALERTS[监控告警<br>- 单用户 IP 锁过多<br>- 单 IP 锁定多个用户]
  end

  ADMIN_UNLOCK --> REMOVE_MAN[移除对应锁]
  AUTO_CLEAN --> REMOVE_EXP[自动移除过期锁]
  LOCK_IP --> ALERTS
  LOCK_USER --> ALERTS

  %% --- 配置 ---
  subgraph Configs [关键配置]
    CFG1[failed_login_attempts - User_IP 阈值]
    CFG2[failed_login_attempts_per_user - User 阈值]
    CFG3[password_lock_time_minutes - 锁时长 分钟]
  end
  CFG1 --> IP_THRESH
  CFG2 --> USER_THRESH
  CFG3 --> LOCK_IP
  CFG3 --> LOCK_USER

  %% --- 豁免策略 ---
  subgraph Exempt [豁免策略]
    EXEMPT_CFG[本机 root 或安全管理员不受限制]
  end
  EXEMPT_CFG --> CHECKEXEMPT

  %% --- 样式 ---
  classDef ok fill:#e6f7e6,stroke:#2e7d32;
  classDef blocked fill:#ffe6e6,stroke:#c62828;
  classDef action fill:#fff7e6,stroke:#ff9800;
  classDef exempt fill:#e6f0ff,stroke:#1565c0;
  class CHECKLOCK,SUCCESS ok;
  class REJ_IP,REJ_USER,LOCK_IP,LOCK_USER blocked;
  class VERIFY,INC_IP,INC_USER,IP_THRESH,USER_THRESH,ADMIN_UNLOCK,AUTO_CLEAN,ALERTS action;
  class CHECKEXEMPT,EXEMPT_CFG exempt;
3.3 关键业务流程


操作

说明

user@ip锁定

如果user未被锁定，那么在该ip登录user被拒绝访问

user锁定

在任意ip登录user都被拒绝访问

user@ip自动解锁

如果user未被锁定，那么允许在该ip登录user

user自动解锁

允许在任意ip登录user，对应的user@ip锁也被解开

user@ip手动解锁

同user@ip自动解锁。如果user未被锁定，那么允许在该ip登录user.。
如果此时user被锁住，返回成功，但实际没有解开锁。

user手动解锁

同user自动解锁。允许在任意ip登录user，对应的user@ip锁也被解开
如果此时user@ip被锁住， 也会被解开。
3.4 性能与可伸缩性
使用并发哈希表存储锁信息，支持高效查询与更新。用户锁定名单的最大条目≈用户数×1000(用户级别最大尝试次数，每次登录错误都在不同ip)。哈希表遍历耗时毫秒级，单条目查询ns级。

定期清理过期锁记录，避免内存无限增长。
不同条目数占用最大内存


3.5 安全性概览
配置项仅允许 root 或安全管理员修改。
UNLOCK 语句需管理员权限执行。
各模块详细设计
模块1
内部实现使用userid作为用户唯一标识
模块接口概览
LoginLockManager 是登录锁定功能的管理类，负责维护用户(User) 与 用户@IP的登录失败计数和锁定状态。它对上层认证流程提供检查和更新接口，并支持管理员解锁、后台自动清理等管理功能
补充：DROP USER要清理锁
flowchart TD
    Client[客户端<br/>用户名+密码] --> AuthAPI[登录认证模块]
    AuthAPI -->|调用| LoginLockManager

    subgraph LoginLockManager [LoginLockManager 类]
        checkLock:::api
        recordFailure:::api
        clearFailure:::api
        unlock:::api
        cleanExpiredLocks:::api
    end

    AuthAPI --> UserService[用户服务模块] --> DB[(用户存储)]
    LoginLockManager --> Logs[(运营日志)]

    Admin[管理员<br/>UNLOCK USER命令] -->|调用| LoginLockManager

    classDef api fill:#e6f7e6,stroke:#2e7d32,stroke-width:2px;

4.1.1 设计目标
问题阐述：
 IoTDB V2.x.x 用户登录认证过程中缺乏登录失败次数限制，攻击者可通过暴力穷举方式破解口令，存在严重安全风险。同时，过于严格的锁定策略可能导致攻击者利用频繁错误登录行为，恶意锁定合法用户，影响系统可用性。
目标设定：
实现基于用户与用户@IP 的双重失败登录锁定机制，防止暴力破解。
提供自动解锁与手动解锁机制
保持较低性能开销，确保认证流程延迟在可接受范围内。
提供运营日志与异常行为监控，支持后续安全分析与告警。
对特权用户（如 root、管理员）支持本机登录豁免策略。

4.1.2 接口设计
UNLOCK USER 接口
语法定义：
ALTER USER username [@ 'ip_address'] ACCOUNT UNLOCK;
功能描述：
手动解锁登录失败导致的锁定状态。
当只指定 username 时，解锁用户全局锁；
当同时指定 username@ip_address 时，仅解锁该用户在对应 IP 下的锁。
参数说明：

使用示例：

-- 解锁用户全局锁
ALTER USER alice ACCOUNT UNLOCK;

-- 解锁用户在指定 IP 下的锁
ALTER USER alice @ '192.168.1.100' ACCOUNT UNLOCK;
LoginLockManager 类接口

public class LoginLockManager {
    // --- 登录检查相关 ---
    boolean checkLock(String user, String ip);
    void recordFailure(String user, String ip);
    void clearFailure(String user, String ip);
    // --- 管理与后台 ---
    void unlock(String user, String ip);
    void cleanExpiredLocks();
}
checkLock(user, ip)
输入：用户名、IP
输出：true/false，表示是否已被锁定
说明：登录前调用，若命中锁定则直接拒绝
recordFailure(user, ip)
输入：用户名、IP
行为：
对 user@ip 累加失败次数，若达到阈值则锁定
对 user 累加全局失败次数，若达到阈值则锁定
clearFailure(user, ip)
输入：用户名、IP
行为：登录成功后移除对应失败记录（user 与 user@ip）
unlock(user, ip) 不存在报错“message: xxxxx”
输入：用户名必填，IP 可选
行为：
仅传 user → 解锁全局用户锁
传 user+ip → 解锁指定 user@ip 锁
cleanExpiredLocks()
行为：清理所有已过期锁记录（到期时间 < now），支持后台定时任务或登录流程触发

4.1.3 细节设计
模块化：
使用 ConcurrentHashMap<String, UserLockInfo> 维护锁状态，支持用户级锁和用户@IP 锁并存。
独立 LoginLockManager 模块，解耦上层认证逻辑。
配置管理：
配置项：
failed_login_attempts → 单 IP 最大失败次数
failed_login_attempts_per_user → 单用户全局最大失败次数
password_lock_time_minutes → 锁定时长
支持非法配置回退到默认值，并写入错误日志。
性能优化：
通过 cleanExpiredLocks 定时清理，避免无效数据堆积。
用户登录响应：

日志与异常处理：
锁定与解锁事件（INFO）：

[INFO] 2025-09-17 12:00:01 - User 'alice' locked due to 5 failed attempts
[INFO] 2025-09-17 12:00:05 - IP '192.168.1.100' locked for user 'alice'
[INFO] 2025-09-17 12:10:00 - User 'alice' unlocked (manual)
[INFO] 2025-09-17 12:15:00 - IP '192.168.1.100' for user 'alice' unlocked (expired)
异常行为监控（WARN）：

[WARN] 2025-09-17 12:00:01 - User 'alice' has 1200 IP locks within 10 minutes → potential attack
[WARN] 2025-09-17 12:00:01 - IP '192.168.1.100' locked by 50 different users → potential attack
系统异常（ERROR）：

[ERROR] 2025-09-17 12:00:02 - Invalid config: failed_login_attempts_per_user=-5 → fallback to default=1000

4.1.4 安全性设计
认证机制：
无（LoginLockManager 本身不负责认证，仅作为认证前置安全控制）
授权和访问控制：
更新配置和UNLOCK操作需要对应root/安全管理员权限
数据加密和保护：
无


自查内容

说明

自查结果

第三方依赖安全

该功能是否引入新的第三方库、框架、工具或服务？

否



引入的新依赖是否存在已知安全漏洞？

否



第三方依赖是否有断供的风险？是否有备选方案？

否

可用性

该功能是否具备抗拒绝服务（DoS）能力？

是



若功能涉及核心数据处理，是否具备灾难恢复能力？

无关

机密性


该功能是否涉及跨网络 / 跨服务的数据传输，传输链路是否启用加密协议？

否



该功能涉及的数据存储是是否需进行加密存储？

否



该功能处理的敏感数据是否需进行数据加密？

否



加密算法是否符合安全标准？

无关

测试计划

附录：历史内容及讨论记录
xxxx年x月x日 内部讨论
讨论录屏：
讨论关键记录及结论：
