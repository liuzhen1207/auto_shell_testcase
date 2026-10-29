V2.0.7.1-安全模块-权限管理-三权分立-需求分析
版本变更记录


操作日期

文档版本

操作人

内容

2025.5.26

V0.1（初始版本）

田原

创建初始文档

2025.09.07

V0.2（细化版本）

田原、舒文炜

补充竞品调研（并总结对比）
其他的每个操作在之前版本的鉴权情况，本次版本三权分立开启前，以及三权分立开启后的鉴权情况
关键决策点

2025.09.08

V0.3


田原

补充 3.1.1 小节，对于内置管理员用户的创建流程进行阐述
补充 3.1.2 小节，对于此次版本修改后的全局权限进行梳理
补充 3.1.3.1.1 小节，细化 set configuration 的权限需求
补充 3.4 小节，定初步开发任务分配

2025.09.09


V0.4


田原、舒文炜

挨个对一遍所有鉴权细节，确保没有互相矛盾的点


2025.09.16


V1.0


田原、舒文炜

正式评审版


2025.09.26

V1.1

舒文炜

更新了修改用户密码的鉴权逻辑

2025.10.09

V1.2

田原

增加典型的场景示例

2025.11.04

V1.2.1

陈荣钊

更正审计日志配置参数名称

2025.11.10

V1.3

田原

show version 操作不需要任何权限

修改理由：1. EAL 规定；2. GaussDB 也不需要任何权限

2025.11.27

V1.3.1

舒文炜

增加 show available urls，操作不需要任何权限
需求描述
数据库的 “三权分立” 是借鉴行政权力制衡思想的安全管理机制，核心是将数据库管理员（DBA）的权限拆分为 “系统管理员”“安全管理员”“审计管理员” 三大独立角色，通过权限隔离与相互监督，避免单一角色拥有过度权限导致的安全风险，是保障数据库数据安全与操作合规的关键设计。
同步块
三大角色的核心权限与职责明确分离：
系统管理员：负责数据库基础运维，如实例启停、参数配置、对象创建（不含权限分配）、存储资源管理等，无数据访问和安全配置权限；
安全管理员：专注权限与安全策略管控，如分配用户数据读写权限、设置访问控制规则、管理加密策略等，无运维操作和审计查看权限；
审计管理员：仅负责监督与追溯，如开启操作审计日志、查看审计记录（验证是否存在违规操作），无运维和权限配置权限。

该机制的核心价值在于 “制衡”—— 任何单一角色无法独立完成 “运维 + 授权 + 访问数据” 或 “篡改数据 + 删除审计记录” 等高危操作，从权限层面防范内部误操作、恶意篡改数据或权限滥用，是金融、政务等对数据安全要求极高的领域的必备数据库安全策略。

产品调研
客户使用场景调研
暂无
常见竞品调研
GaussDB
有一个初始用户，无论是否在三权分立的情况下都拥有所有权限。

官方文档中并未提及是否支持删除该初始用户
除初始用户外，一共分成了六类管理员：系统管理员、安全管理员、审计管理员、监控管理员、运维管理员和安全策略管理员。
官方文档中表述，与三权分立相关的三类管理员为：系统管理员、安全管理员和审计管理员。三权分立前，SYSADMIN属性的系统管理员，具备系统最高权限。三权分立后将系统管理员的用户管理和审计管理的权限分别分给安全管理员和审计管理员。即系统管理员将不再具有 CREATEROLE 属性（安全管理员）和 AUDITADMIN 属性（审计管理员）能力，即不再拥有创建角色和用户的权限，也不再拥有查看和维护数据库审计日志的权限。
详细请见：GaussDB 调研文档

show version 操作不需要任何权限
img_v3_02rt_5b72c40a-a0a9-4383-acde-1882bb3e5dfg.jpg


PolarDB
作为一款云数据库，很多操作都是在web控制台界面上进行操作，而登录 web 控制台界面的是 RAM 用户，有点类似于 GaussDB 的初始用户，开启和关闭三权分立均由 RAM 用户在控制台进行操作。
三权分立分为系统管理员、安全管理员和审计管理员
数据库管理员（DBA）：只具备DDL（Data Definition Language）权限。
安全管理员（DSA）：只具备管理角色（Role）或用户（User）以及为其他账号授予权限的权限。
审计管理员（DAA）：只具备查看审计日志的权限。
PolarDB-调研文档


OceanBase
在企业版中使用 Oracle 模式，这个模式下默认启用了三权分立的机制，有三个初始用户：数据库管理员（SYS）、数据库安全管理员（LBACSYS）、数据库审计员（ORAAUDITOR）。
初始状态只有 SYS 用户可使用，其它两个内置用户需要通过 SYS 用户设定密码并解除锁定状态才被启用，是否开启其他两个用户对 SYS 用户本身拥有的权限无影响。

从官方权限概述文档（用户和权限概述）的描述中，可以看到 OceanBase 中的三权分立机制与上面需求描述中的定义不太一致
数据库管理员能够对其他用户进行锁定、修改密码、通过 GRANT 进行授权等操作
数据库安全管理员和数据库审计员都可以定义新的数据库审计员、查看审计日志（无法确定这篇概述文档的描述是否正确，在其他文档中涉及安全策略配置的文档都是使用的 LBACSYS 用户进行演示，涉及审计的操作都是由 ORAAUDITOR 用户演示）
数据库安全管理员能够管理和使用 Label Security 功能， Label Security 是强制访问控制的一种方式（访问控制），而概述文档中还提到 ORAAUDITOR 负责对系统进行强制访问控制
详情请见：OceanBase 调研文档


DB2
用户认证依赖外部安全机制，这个外部安全机制可以说操作系统的一部分（比如在 Windows 操作系统上使用域账号/本地账号），也可以是一个独立产品，如 LDAP 服务等，数据库内只维护权限映射关系。
Db2 在实例级别，数据库级别和模式级别存在各种管理权限，不强制执行三权分立的设计，权限体系是模块化的，需要由管理员人工设计，在实际使用时，可以根据需求通过为不同的组/用户赋予权限的方式实现三权分立。
Db2 中有内置一些类似的数据库级别权限，通过对用户赋予这些权限可以起到类似三权分立的效果：
DBADM：类似数据库管理员
SECADM： 类似安全管理员 + 审计管理员
详情请见：Db2 调研文档


TiDB
TiDB 企业版（平凯数据库）中支持三/四权分立，但是没有找到相关的公开文档

Oracle
因为 OceanBase 的 Oracle 租户是宣称与 Oracle 兼容的，所以 Oracle 相关的参考 OB 的调研结果

对比




GaussDB

PolarDB

OB

DB2

是否有明确的三权分立的三个角色的划分

有


有

有

无

三权分立由谁开启和关闭


未提及，猜测是初始用户


开启：RAM 用户
关闭：RAM 用户登录控制台，高权限账号（系统管理员）密码进行二次验证

SYS 用户


管理员自行分配权限人工设计


三权分立开启后能否切回

能，不建议

能，不建议

没有这项配置

没有这项配置

三权分立开启后，对于开启前的用户已分配的权限如何做处理？


不做任何处理，用户拥有开启前的所有权限

需要注意的是，当需从非三权分立权限管理模型切换至三权分立权限管理模型时，应重新审视已有用户的权限集合。如用户具备系统管理员权限(SYSADMIN)审计管理员权限(AUDIT)，则需要进行权限裁剪。

由于安全管理员和审计管理员是开启三权分立时才创建的，且无法对系统管理员、安全管理员、审计管理员赋权和撤回权限，所以不会有任何问题


没有这项配置


没有这项配置

三权分立的打开和关闭是否支持热加载

未知

支持，官网提到需要等待 3~5 秒才能生效

没有这项配置

没有这项配置

每种管理员能否有多个

能


不能


未提及，推测可以通过创建用户并赋予相关权限做到

能


是否有内置的三种管理员

无，需要开启后创建


无，开启时强制用户手动创建

有，但需要开启后手动解锁

无

系统管理员拥有的权限


仅有对表空间有创建、修改、删除、访问、分配操作的权限、系统对象（类似于系统表）的权限

并没有运维权限，因为它有单独的运维管理员分类

仅 DDL 权限


配置参数、创建数据库对象、分配自主访问权限、导入导出数据等

分配自主访问权限：能够通过 GRANT 将拥有的权限赋予其他用户

文档中称为数据库管理员的用户有 DBADM 权限，此权限拥有创建对象和发出数据库命令的权限

安全管理员拥有的权限

用户、角色以及权限管理


用户、角色以及权限管理

设置系统安全等级、范围和组

概述文档中还写出了具有一些审计管理员的权限，不确定描述是否正确

文档中称为安全管理员的用户有 SECADM 权限，此权限可以创建和管理与安全相关的数据库对象，还有审计权限


审计管理员拥有的权限

维护审计规则
查询审计日志

查询审计日志


设置需要审计的对象、定义新的数据库审计员、查看和分析审计记录

概述文档中还写出了具有一些安全管理员的权限，不确定描述是否正确

没有审计管理员的说法

三种管理员名字是否可变

能

不能

未知

能

三种管理员密码能够被谁修改

只能被他们自己或者初始用户

只能被他们自己


有修改密码权限的用户（如 SYS）或他们自己

任意有修改密码权限的用户或他们自己

普通用户能够被谁创建

安全管理员/初始用户


安全管理员

有创建用户权限的用户，内置用户中为 SYS 用户

外部安全机制（如操作系统中的用户管理）

系统管理员能够被谁创建

这里的创建隐含意思就是赋予某个用户系统管理员的权限

初始用户/其他系统管理员

三权分立后没有提及还是否能由系统管理员创建，也没有提及是否能由安全管理员创建

RAM 用户


有创建用户权限的用户，内置用户中为 SYS 用户

外部安全机制（如操作系统中的用户管理）


安全管理员能够被谁创建

这里的创建隐含意思就是赋予某个用户安全管理员的权限

三权分立打开时，只能由安全管理员创建
没有提到初始用户，但推断初始用户在任何情况下都应该可以创建安全管理员，不然第一个安全管理员哪里来？

RAM 用户


有创建用户权限的用户，内置用户中为 SYS 

外部安全机制（如操作系统中的用户管理）

审计管理员能够被谁创建

这里的创建隐含意思就是赋予某个用户审计管理员的权限

三权分立打开时，只能由审计管理员创建
没有提到初始用户，但推断初始用户在任何情况下都应该可以创建审计管理员，不然第一个安全管理员哪里来？

此处官方文档自相矛盾，详见 GaussDB 的调研文档

RAM 用户


有创建用户权限的用户，三种内置用户都能够创建

概述文档中写安全管理员和数据库审计员能够定义新的审计员，不确定描述是否正确

外部安全机制（如操作系统中的用户管理）

三种管理员是否还能被 GRANT/REVOKE

即三种管理员还能否被安全管理员赋予其他对象权限，去查询用户数据

能

否

能


能


三种管理员的权限是否在系统层面保证互斥

即某一种管理员只能拥有自己的一种权限

是


是

否


否


功能定义
功能定义
关键概念
重构全局权限，将全局权限定义成三个 SYSTEM、SECURITY、AUDIT，分别对应三权分立下的三个管理员：
系统管理员（DBA）：只具备运维操作、DDL（Data Definition Language）相关的权限。
安全管理员（DSA）：只具备管理角色（Role）或用户（User）以及为其他账号授予权限的权限。
审计管理员（DAA）：只具备维护审计规则、查看审计日志的权限。

这个改动对开源版也生效，即开源版在 2.0.7 版本中，全局权限也会只剩下三个


无论三权分立是否开启，新版本中全局权限都只包含这三个
之前的全局权限无法再被授予，最新的官网文档中也会被删除
为了保持兼容，旧版本的全局权限在鉴权时依然会生效（具体见 3.1.2 章节），查询原来的用户/角色拥有的权限列表时，也能够看到这些旧权限
序列权限和对象权限相较于之前版本，并未做任何修改
三权分立关闭
三权分立关闭时，系统内有一个超级管理员用户，拥有所有权限（包括全局权限和普通权限），系统自己创建（默认为 root），不可被删除，名称和密码均可被其自己修改，不可被赋予和回收权限。
其他用户均为普通用户，可以被赋予任意的权限组合，不受任何限制。

原全局权限与当前全局权限的对应关系


原全局权限

原适用模型

当前全局权限

当前适用模型

MAINTAIN

树

SYSTEM


树&表

USE_UDF

树



树&表

USE_MODEL

树



树&表

USE_TRIGGER

树



树&表

USE_CQ

树



树&表

USE_PIPE

树



树&表

MANAGE_DATABASE

树



树&表

EXTEND_TEMPLATE

树



树&表

MANAGE_USER

树&表

SECURITY


树&表

MANAGE_ROLE

树&表



树&表

无

无

AUDIT

只存在于企业版，因为审计日志是企业版功能

树&表

三权分立打开
企业版新增如下配置项（仅企业版支持三权分立）：


配置项名称

默认值

含义

生效模式

enable_separation_of_powers

false

是否开启三权分立

热加载
首次打开三权分立，并启动后会创建三个初始内置的管理员账户：
内置初始的系统管理员，名为 sys_admin：
默认密码为 TimechoDB@2021
默认仅拥有 SYSTEM 权限
用户名和密码只能被其自己修改
内置初始的安全管理员，名为 security_admin：
默认密码为 TimechoDB@2021
默认仅拥有 SECURITY 权限
用户名和密码只能被其自己修改
内置初始的审计管理员：名为 audit_admin：
默认密码为 TimechoDB@2021
默认仅拥有 AUDIT 权限
用户名和密码只能被其自己修改
一个用户至多只能拥有三个全局权限中的一个（确保核心权限：管理、安全、审计，不能交叉）
对于普通权限并无限制，管理员也可以拥有任意多的普通权限
三类管理员可以有多个
拥有 SYSTEM 全局权限的就被称为系统管理员，SYSTEM 全局权限只能被初始系统管理员赋予和回收
新的系统管理员诞生流程：安全管理员创建一个新用户 -> 初始系统管理员赋予该用户 SYSTEM 权限
拥有 SECURITY 全局权限的就被称为安全管理员，SECURITY 全局权限只能被初始安全管理员赋予和回收
新的安全管理员诞生流程：安全管理员创建一个新用户 -> 初始安全管理员赋予该用户 SECURITY 权限
拥有 AUDIT 全局权限的就被称为审计管理员，AUDIT 全局权限只能被初始审计管理员赋予和回收
新的审计管理员诞生流程：安全管理员创建一个新用户 -> 初始审计管理员赋予该用户 AUDIT 权限
普通用户就是没有任何全局权限的用户
普通用户只能由安全管理员（包括初始安全管理员）创建出来
普通权限只能由安全管理员（包括初始安全管理员）赋予和回收
角色只能拥有普通权限，只能被安全管理员所创建、删除、修改、赋予和回收
如果让角色可以拥有全局权限，那一个角色被系统管理员赋予 SYSTEM 权限后，又被安全管理员赋予普通权限，那这个角色能够被谁赋予给其他用户呢？
安全管理员？不太好，因为这样相当于安全管理员可以赋予用户 SYSTEM 权限了
系统管理员？也不太好，因为这样相当于系统管理员可以赋予用户普通权限了



场景分类
打开三权分立时，若系统中已存在与内置初始管理员账户同名的其他用户，则报错
若是通过修改配置文件进行打开，则启动失败，并在 CN 的 error 日志中打印具体错误信息
若是通过 set configuration 的方式修改一个正在运行的 IoTDB 集群的 enable_separation_of_powers 为 true（原来为 false），则修改失败（打开三权分立失败），抛出异常信息，创建 XX 管理员时，用户名 XXXX 已存在，请先修改源用户名
三权分立打开后，原来的超级管理员被当做一个没有任何权限的且不可修改（改密码用户名、赋权、撤销权限、赋予角色、撤销角色都不行）的普通用户，也不能登录
但可以被 list user 看到

三权分立不允许由打开到关闭的切换
三权分立开启后，对于开启前的用户已分配的权限不做任何处理，用户拥有开启前的所有权限，即使这些权限的组合不满足三权分立的要求，依赖用户在开启三权分立前，对所有用户权限手动裁剪


操作鉴权
树表通用操作


功能分类

一级功能

二级功能

修改前（当前master版本）




三权分立关闭（本次版本修改后）



三权分立打开（本次版本新增）













root 用户

普通用户

超级管理员

普通用户

系统管理员

安全管理员

审计管理员

普通用户

安全相关

用户管理


创建


支持

需要 MANAGE_USER 权限

支持


需要 MANAGE_USER/SECURITY 权限

不支持


支持


不支持

不支持






删除


支持


需要 MANAGE_USER 权限


支持


需要 MANAGE_USER/SECURITY 权限


不支持


可以删除不包含 SYSTEM 和 SECURITY 和 AUDIT 权限的任何用户
（如果想删除其他系统管理员或者审计管理员，需要找对应的初始管理员先撤销掉相关的全局权限，再由安全管理员删除用户）

仅初始安全管理员能删除包含SECUIRTY 权限的用户


所有初始管理员永远无法删除

不支持


不支持






修改密码


支持


MANAGE_USER 权限可以修改所有人，否则只能修改自己


支持

超级管理员的密码只能被他自己修改

MANAGE_USER/SECURITY 权限可以修改所有人（除超级管理员外），否则只能修改自己


系统管理员只能被自己修改


如果普通系统管理员忘记密码，需使用内置系统管理员先撤销其管理员权限，然后由安全管理员修改密码


可以修改普通用户

初始安全管理员只能被自己修改

其他安全管理员能够被自己或者初始安全管理员修改

审计管理员只能被自己修改


如果普通审计管理员忘记密码，需使用内置审计管理员先撤销其管理员权限，然后由安全管理员修改密码


仅支持修改自己






解除锁定

支持

需要 MANAGE_USER 权限


支持

需要 MANAGE_USER/SECURITY 权限

不支持

支持

不支持

不支持





修改用户名

无该功能

无该功能

支持

超级管理员的用户名只能被他自己修改


MANAGE_USER/SECURITY 权限可以修改所有人（除超级管理员外），否则只能修改自己

系统管理员只能被自己修改


如果普通系统管理员忘记密码，需使用内置系统管理员先撤销其管理员权限，然后由安全管理员修改密码


可以修改普通用户

初始安全管理员只能被自己修改

其他安全管理员能够被自己或者初始安全管理员修改

审计管理员只能被自己修改


如果普通审计管理员忘记密码，需使用内置审计管理员先撤销其管理员权限，然后由安全管理员修改密码


仅支持修改自己






设置最大最小连接数

无该功能

无该功能

支持（超级管理员的最大连接数默认-1，最小连接数默认1，且不允许修改）


MANAGE_USER/SECURITY 权限可以修改所有人（除超级管理员外）

不支持

可以修改普通用户

初始安全管理员、初始审计管理员、初始系统管理员不允许被修改

其他安全管理员、其他审计管理员、其他系统管理员初始安全管理员修改

不支持

不支持





查询

增加一列标识是否是初始用户
list user

支持

需要 MANAGE_USER 权限


支持


有 MANAGE_USER/SECURITY 权限时可以看到所有用户

其他用户仅能看到自己

仅能看到自己

初始系统管理员还能看到所有其他系统管理员


能看到所有用户


仅能看到自己

初始审计管理员还能看到所有其他审计管理员


仅能看到自己




角色管理

创建


支持

需要 MANAGE_ROLE 权限

支持

需要 MANAGE_ROLE/SECURITY 权限

不支持


支持


不支持

不支持





删除


支持

需要 MANAGE_ROLE 权限

支持

需要 MANAGE_ROLE/SECURITY 权限

不支持


支持


不支持

不支持





查询
list role (OF USER)?


支持

需要 MANAGE_ROLE 权限


支持

有 MANAGE_ROLE/SECURITY 权限时可以看到所有角色

其他用户仅能看到自己拥有的角色

普通系统管理员仅能看到自己拥有的角色

初始系统管理员还能看到所有其他系统管理员拥有的角色


支持


普通审计管理员仅能看到自己拥有的角色

初始审计管理员还能看到所有其他审计管理员拥有的角色


仅能看到自己拥有的角色



权限管理


授予用户权限
Grant XXX TO USER XXX


支持

授予权限需要获得权限或角色时指定了 with grant option 关键字


支持

有SECURITY 权限可以授权任何权限，否则仅能授予拥有 with GRANT OPTION 的权限




仅初始系统管理员支持授予用户SYSTEM 权限


对于 SYSTEM 权限，WITH GRANT OPTION 会报错


能够授予用户除 SYSTEM 、SECURITY 、AUDIT 以外的其他所有普通权限
仅初始安全管理员支持授予用户SECURITY 权限


对于 SECURITY 权限，WITH GRANT OPTION 会报错

仅初始审计管理员支持授予用户 AUDIT 权限

对于 AUDIT 权限，WITH GRANT OPTION 会报错

仅能授予其他用户，自身有WITH GRANT OPTION的权限







授予角色权限
Grant XXX TO ROLE XXX

支持

需要MANAGE_ROLE 权限

支持

需要MANAGE_ROLE/SECURITY 权限

不支持


能够授予角色普通权限


不支持


不支持






授予用户角色
GRANT ROLE XXX TO USER XXX

支持


需要MANAGE_ROLE 权限

支持

授予角色需要MANAGE_ROLE/SECURITY 权限

不支持

支持


不支持

不支持





撤销用户权限


支持


获得权限或角色时指定了 grant option 关键字


支持


获得权限或角色时指定了 grant option 关键字
或 SECURITY 权限



仅初始系统管理员支持撤销用户 SYSTEM 权限

初始系统管理员的 SYSTEM 权限无法被撤销


支持撤销用户除了 SYSTEM 、SECURITY和 AUDIT 以外的所有普通权限

仅初始安全管理员支持撤销用户 SECURITY  权限

初始安全管理员的 SECURITY权限无法被撤销

仅支持初始审计管理员撤销用户 AUDIT 权限

初始审计管理员的 AUDIT 权限无法被撤销

不支持






撤销角色权限


支持

获得权限或角色时指定了 grant option 关键字

支持

获得权限或角色时指定了 grant option 关键字
或 SECURITY 权限

不支持


支持


不支持


不支持





撤销用户角色


支持


需要 MANAGE_ROLE 权限

支持

需要MANAGE_ROLE/SECURITY 权限

不支持

支持


不支持


不支持






查询用户拥有的权限
LIST PRIVILEGES OF USER userName


支持

查看自己以外的用户需要 MANAGE_USER 


支持

查看自己以外的用户需要 MANAGE_USER/SECURITY


初始系统管理员还能看到所有其他系统管理员拥有的权限

其他系统管理员仅能看到自己拥有的权限


能看到所有用户的权限

初始审计管理员还能看到所有其他审计管理员拥有的权限

其他审计管理员仅能看到自己拥有的权限

仅能看到自己拥有的权限






查询角色拥有的权限
LIST PRIVILEGES OF ROLE roleName


支持

查看自己以外的角色拥有的权限需要 MANAGE_ROLE 权限

支持

查看自己以外的角色拥有的权限需要 MANAGE_ROLE/SECURITY 权限

普通系统管理员仅能看到自己拥有的角色的权限

初始系统管理员还能看到所有其他系统管理员拥有的角色的权限

能看到所有角色的权限

普通审计管理员仅能看到自己拥有的角色的权限

初始审计管理员还能看到所有其他审计管理员拥有的角色的权限

仅能看到自己拥有的角色的权限


审计相关


审计日志规则的维护以及审计日志的查询




通过配置文件进行，拥有配置文件读写权限和CN&DN进程启停权限的服务器用户可以进行
通过 sql 查询审计日志：支持

通过配置文件进行，拥有配置文件读写权限和CN&DN进程启停权限的服务器用户可以进行
通过 sql 查询审计日志：需要 root..audit._root 的 read_data 权限

支持


需要 AUDIT 权限


不支持


不支持


支持


不支持


运维、管理、DDL 相关


集群管理

展示 CN

ShowConfigNodesStatement

支持

树模型：MAINTAIN
表模型：不支持

支持

树模型：需要 MAINTAIN/SYSTEM 权限
表模型：需要 SYSTEM 权限

支持


不支持

不支持

不支持





展示 DN

ShowDataNodesStatement

支持


树模型：MAINTAIN
表模型：不支持

支持

树模型：需要 MAINTAIN/SYSTEM 权限
表模型：需要 SYSTEM 权限

支持

不支持

不支持

不支持





展示可用节点

ShowAvailableUrlsStatement

支持

支持

支持

支持

支持

支持

支持

支持





展示集群信息

ShowClusterStatement

支持

树模型：MAINTAIN
表模型：不支持

支持

树模型：需要 MAINTAIN/SYSTEM 权限
表模型：需要 SYSTEM 权限

支持

不支持

不支持

不支持





展示 region 信息

ShowRegionsStatement

支持

树模型：MAINTAIN
表模型：不支持

支持

树模型：需要 MAINTAIN/SYSTEM 权限
表模型：需要 SYSTEM 权限

支持

不支持

不支持

不支持





迁移 region

MigrateRegionStatement

支持

树模型：MAINTAIN
表模型：不支持

支持

树模型：需要 MAINTAIN/SYSTEM 权限
表模型：需要 SYSTEM 权限

支持

不支持

不支持

不支持




运维语句


showCurrentSqlDialectStatement

支持

支持

支持

支持

支持

支持

支持

支持





showCurrentUserStatement

支持

支持

支持

支持

支持

支持

支持


支持





showVersionStatement

支持

支持


支持

支持


支持


支持

支持

支持





showCurrentTimestampStatement

支持

支持

支持

支持

支持

支持


支持

支持





showVariablesStatement

支持

树模型：支持
表模型：不支持

支持

树模型：需要 MAINTAIN/SYSTEM 权限
表模型：需要 SYSTEM 权限

支持

不支持


不支持

不支持





showClusterIdStatement

支持


树模型：需要 MAINTAIN 权限
表模型：不支持

支持

树模型：需要 MAINTAIN/SYSTEM 权限
表模型：需要 SYSTEM 权限

支持

不支持

不支持

不支持





flushStatement

支持

不支持


支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持





clearCacheStatement

支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持





setConfigurationStatement

详见3.1.3.1.1 章节

支持

不支持

支持


根据配置项的不同，需要不同的权限，详见3.1.2.1.1 章节


支持部分，详见3.1.2.1.1 章节


支持部分，详见3.1.2.1.1 章节

支持部分，详见3.1.2.1.1 章节


不支持





showQueriesStatement


支持

树模型：需要 MAINTAIN 权限
表模型：支持


能看到所有人的

树模型：
有MAINTAIN/SYSTEM 权限的用户可以看到所有人的，其他用户只能看到自己的

表模型：
有SYSTEM 权限的用户可以看到所有人的，其他用户只能看到自己的

支持

只能看到自己的


只能看到自己的

只能看到自己的





killQueryStatement

支持

树模型：需要MAINTAIN 权限
表模型：不支持

支持

树模型：MAINTAIN/SYSTEM 权限可以 KILL 所有人的
其他用户只能 kill 自己的
表模型：SYSTEM权限可以kill 所有人的
其他用户只能 kill 自己的

支持

只能 kill 自己的


只能 kill 自己的

只能 kill 自己的





loadConfigurationStatement


支持

不支持

支持

不支持


不支持

需要注意一下，三权分立打开后，这个语句就被禁止了，没有人能够执行

不支持


不支持


不支持






setSystemStatusStatement

支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持





startRepairData


支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持






stopRepairData

支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持





激活


支持


不支持

支持

需要 MAINTAIN/SYSTEM 权限

支持

不支持

不支持

不支持





展示激活信息

支持

不支持

支持

需要 MAINTAIN/SYSTEM 权限

支持

不支持

不支持

不支持





展示系统信息

支持

不支持

支持

需要 MAINTAIN/SYSTEM 权限

支持

不支持

不支持

不支持



UDF 管理

创建


支持

树模型：需要 USE_UDF 权限
表模型：不支持

支持

树模型：需要 USE_UDF/SYSTEM 权限
表模型：需要SYSTEM权限

支持

不支持

不支持

不支持





删除


支持

树模型：需要 USE_UDF 权限
表模型：不支持

支持

树模型：需要 USE_UDF/SYSTEM 权限
表模型：需要SYSTEM权限

支持

不支持

不支持

不支持





展示


支持

树模型：需要 USE_UDF 权限
表模型：支持

支持

支持


支持

支持


支持

支持






使用

支持

支持

支持

支持

支持

支持

支持

支持



Pipe 管理


创建

支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM

支持


不支持

不支持

不支持





展示


支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：有USE_PIPE/SYSTEM 权限可以看到所有的pipes，否则用户只能看到任何source/sink 用户指向他自己的pipes
表模型：有 SYSTEM 权限可以看到所有的 pipes，否则用户只能看到任何source/sink 用户指向他自己的pipes

支持


只能看到任何source/sink 用户指向他自己的pipes


只能看到任何source/sink 用户指向他自己的pipes

只能看到任何source/sink 用户指向他自己的pipes






删除


支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持

不支持


不支持

不支持





修改

支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM 权限

支持

不支持


不支持

不支持





启动

支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持

不支持


不支持

不支持





停止


支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持

不支持


不支持

不支持


























Pipe 插件管理


创建


支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持

不支持


不支持

不支持





删除


支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持

不支持


不支持

不支持





展示


支持

树模型：需要 USE_PIPE 权限
表模型：支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限


支持


不支持


不支持

不支持



订阅管理

创建主题


支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持


不支持


不支持

不支持





展示主题


支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持


不支持


不支持

不支持





删除主题


支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持


不支持


不支持

不支持





主题的运行阶段

支持

消费时动态对消费涉及的所有数据进行查询鉴权

支持

消费时动态对消费涉及的所有数据进行查询鉴权


消费时动态对消费涉及的所有数据进行查询鉴权

消费时动态对消费涉及的所有数据进行查询鉴权

消费时动态对消费涉及的所有数据进行查询鉴权

消费时动态对消费涉及的所有数据进行查询鉴权





删除订阅

支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持

不支持


不支持

不支持






查看订阅

支持

树模型：需要 USE_PIPE 权限
表模型：不支持

支持

树模型：需要 USE_PIPE/SYSTEM 权限
表模型：需要 SYSTEM权限

支持

不支持


不支持

不支持




数据库管理

创建

任何人都无法对 root.__audit 和 __audit 进行创建

支持

树模型：需要 MANAGE_DATABASE 权限
表模型：需要对应 db/ANY 的 CREATE 权限

支持

树模型：需要 MANAGE_DATABASE/SYSTEM 权限
表模型：需要对应 db/ANY 的 CREATE 权限/SYSTEM 权限

支持


树模型：
不支持
表模型：需要对应 db /ANY的 CREATE 权限


树模型：
不支持
表模型：需要对应 db/ANY 的 CREATE 权限

树模型：
不支持
表模型：需要对应 db/ANY 的 CREATE 权限





展示

show/count
只有拥有 AUDIT 权限的人才能看到 root.__audit 以及 __audit

支持


树模型：仅展示拥有READ_SCHEMA权限的路径所属的数据库

表模型：仅展示拥有任意权限的数据库

支持

树模型：拥有MANAGE_DATABASE/SYSTEM 权限看到所有，否则仅展示拥有READ_SCHEMA权限的路径所属的数据库

表模型：仅展示拥有任意权限的数据库

支持


树模型：展示拥有READ_SCHEMA权限的路径所属的数据库

表模型：仅展示拥有任意权限的数据库


树模型：展示拥有READ_SCHEMA权限的路径所属的数据库

表模型：仅展示拥有任意权限的数据库

树模型：展示拥有READ_SCHEMA权限的路径所属的数据库

表模型：仅展示拥有任意权限的数据库






修改

任何人都无法对 root.__audit 和 __audit 进行修改

支持

树模型：需要 MANAGE_DATABASE 权限
表模型：需要对应 db/ANY 的 ALTER 权限

支持

树模型：需要 MANAGE_DATABASE/SYSTEM 权限
表模型：需要对应 db/ANY 的 ALTER 权限/SYSTEM 权限

支持

树模型：不支持
表模型：需要对应 db/ANY 的 ALTER 权限/

树模型：不支持
表模型：需要对应 db/ANY 的 ALTER 权限/

树模型：不支持
表模型：需要对应 db/ANY 的 ALTER 权限/





删除

如果指定删除 root.**，不会对 root.__audit 生效

支持

树模型：需要 MANAGE_DATABASE 权限
表模型：需要对应 db/ANY 的 DROP 权限

支持


树模型：需要 MANAGE_DATABASE/SYSTEM 权限
表模型：需要对应 db/ANY 的 DROP 权限/SYSTEM 权限

支持

树模型：不支持
表模型：需要对应 db/ANY 的 DROP 权限/

树模型：不支持
表模型：需要对应 db/ANY 的 DROP 权限/

树模型：不支持
表模型：需要对应 db/ANY 的 DROP 权限/



模型管理


创建


支持

树模型：需要 USE_MODEL 权限
表模型：支持

支持


树模型：需要 USE_MODEL/SYSTEM 权限
表模型：需要SYSTEM权限

支持

不支持

不支持

不支持





创建训练任务


支持


树模型：不支持
表模型：支持

支持

树模型：不支持
表模型：需要SYSTEM权限


支持


不支持

不支持

不支持





训练运行时

在 iotdb-ainode.properties中明文写的用户名和密码

支持

需要拥有待训练输入数据上的查询权限

支持

需要拥有待训练输入数据上的查询权限

需要拥有待训练输入数据上的查询权限

需要拥有待训练输入数据上的查询权限

需要拥有待训练输入数据上的查询权限

需要拥有待训练输入数据上的查询权限





删除

支持

树模型：需要 USE_MODEL 权限
表模型：支持

支持

树模型：需要 USE_MODEL/SYSTEM 权限
表模型：需要SYSTEM权限


支持

不支持

不支持

不支持





加载模型

支持


不支持

支持


树模型：需要 USE_MODEL/SYSTEM 权限
表模型：需要SYSTEM权限

支持

不支持

不支持

不支持





卸载模型

支持

不支持

支持

树模型：需要 USE_MODEL/SYSTEM 权限
表模型：需要SYSTEM权限

支持

不支持

不支持

不支持





查看可用的 GPU 资源

支持

不支持

支持

树模型：需要 USE_MODEL/SYSTEM 权限
表模型：需要SYSTEM权限

支持

不支持

不支持

不支持





查询


支持

树模型：需要 USE_MODEL 权限
表模型：支持

支持

支持

支持

支持

支持

支持





使用

用创建的 model 进行查询

支持


支持


支持

支持

支持

支持

支持

支持
同步块
set/show configuration 语句
set/show configuration 子句需要根据具体设置的配置项决定其不同的鉴权逻辑，所以在此列出具体的配置项需要的权限：

基于 master 分支 b6c417e commit 进行梳理，若有晚于该 commit 的新增配置项，需自行在表格中添加


功能项


配置项

修改前（当前master版本）



三权分立关闭时（本次版本修改后）



三权分立打开时（本次版本新增）











root 用户

普通用户

超级管理员

普通用户

系统管理员

安全管理员

审计管理员

普通用户

初始管理员账户管理

enable_separation_of_powers


无该配置项

无该配置项

支持

只有超级管理员能够开启三权分立

不支持

不支持

一旦打开，就不支持关闭

不支持

一旦打开，就不支持关闭

不支持

一旦打开，就不支持关闭

不支持

一旦打开，就不支持关闭

通信加密


enable_thrift_ssl

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



enable_internal_ssl

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



key_store_path/key_store_pwd

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



trust_store_path/trust_store_pwd

支持

不支持

支持

SECURITY 权限


不支持

支持

不支持

不支持



enable_https

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持

黑白名单


enable_white_list

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



white_ip_list

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



enable_black_list

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



white_ip_list

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持

权限相关


authorizer_provider_class

支持

不支持


支持

SECURITY 权限

不支持

支持


不支持

不支持



openID_url

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



iotdb_server_encrypt_decrypt_provider

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



iotdb_server_encrypt_decrypt_provider_parameter

支持

不支持


支持

SECURITY 权限

不支持

支持

不支持

不支持



enforce_strong_password

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持



password_expiration_days

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持




password_reuse_interval_days

支持

不支持

支持

SECURITY 权限


不支持

支持

不支持

不支持

会话管理

dn_rpc_max_concurrent_client_num

支持

不支持

支持

SECURITY 权限

不支持

支持

不支持

不支持

审计日志


enable_audit_log

支持

不支持

支持

AUDIT 权限

不支持

不支持

支持

不支持



auditable_operation_type

无该配置项

无该配置项

支持

AUDIT 权限


不支持

不支持

支持

不支持



auditable_operation_level

无该配置项

无该配置项

支持

AUDIT 权限

不支持

不支持

支持

不支持



auditable_operation_result

无该配置项

无该配置项

支持

AUDIT 权限

不支持

不支持

支持

不支持



audit_log_ttl_in_days

无该配置项

无该配置项

支持

AUDIT 权限


不支持

不支持

支持

不支持



audit_log_space_tl_in_GB

无该配置项

无该配置项

支持

AUDIT 权限

不支持

不支持

支持

不支持

其他

其他配置项

支持

不支持

支持

SYSTEM 权限

支持

不支持

不支持

不支持

树模型专有操作


一级功能

二级功能

修改前



三权分立关闭



三权分立打开











root 用户

普通用户

超级管理员

普通用户

系统管理员

安全管理员

审计管理员

普通用户

TTL 管理

root.__audit以下的路径不支持设置 TTL，也不支持查看


设置

支持


需要对应路径的 WRITE_SCHEMA 权限

支持


有system权限或对应路径的 WRITE_SCHEMA 权限

支持


需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限



展示


支持

支持


支持

SYSTEM 权限能够看到所有TTL，否则只能看到自己有READ_SCHEMA权限的路径上的TTL

支持

需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限


需要对应路径的 READ_SCHEMA 权限



取消

支持

需要对应路径的 WRITE_SCHEMA 权限

支持

有SYSTEM权限或对应路径的 WRITE_SCHEMA 权限

支持


需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

序列视图管理

创建

支持

需要对应路径的 WRITE_SCHEMA 权限以及数据源的 READ_SCHEMA 权限

支持

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限


需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限



修改

支持

需要对应路径的 WRITE_SCHEMA 权限以及数据源的 READ_SCHEMA 权限

支持

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限

需要对应路径的 WRITE_SCHEMA 权限，以及源序列的READ_SCHEMA权限



展示

支持

需要对应路径的 READ_SCHEMA 权限

支持


需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限



删除

支持

需要对应路径的 WRITE_SCHEMA 权限

支持

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

设备管理

展示（不带时间过滤）
show/count

支持

需要对应路径的READ_SCHEMA 权限

支持

需要对应路径的READ_SCHEMA 权限

需要对应路径的READ_SCHEMA 权限

需要对应路径的READ_SCHEMA 权限

需要对应路径的READ_SCHEMA 权限

需要对应路径的READ_SCHEMA 权限



展示（带时间过滤）
show/count where

支持

需要对应路径的 READ_SCHEMA和READ_DATA 权限

支持

需要对应路径的 READ_SCHEMA和READ_DATA 权限

需要对应路径的 READ_SCHEMA和READ_DATA 权限

需要对应路径的 READ_SCHEMA和READ_DATA 权限

需要对应路径的 READ_SCHEMA和READ_DATA 权限

需要对应路径的 READ_SCHEMA和READ_DATA 权限

序列管理


创建

支持

需要对应路径的 WRITE_SCHEMA 权限

支持

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限



删除

支持

需要对应路径的 WRITE_SCHEMA 权限

支持

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限



查看

支持

需要对应路径的 READ_SCHEMA 权限

支持

需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限

需要对应路径的 READ_SCHEMA 权限



修改

标签点的修改、序列改名

支持

需要对应路径的 WRITE_SCHEMA 权限

支持

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

模板管理


创建


支持

不支持

支持

需要 SYSTEM 权限

支持


不支持

不支持

不支持



挂载

root.__audit 上不允许挂载模版


支持

不支持

支持


需要 SYSTEM 权限

支持

不支持

不支持

不支持



激活


支持

需要对应路径的 WRITE_SCHEMA 权限

支持


需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限



查询设备模板

show device templates

支持

不支持

支持

SYSTEM 权限能看到所有，否则只能看到那些有READ_SCHEMA权限的路径上的template

支持

只能看到那些有READ_SCHEMA权限的路径上的template

只能看到那些有READ_SCHEMA权限的路径上的template

只能看到那些有READ_SCHEMA权限的路径上的template



查看某个设备模板下的物理量

show nodes in device template t1

支持

不支持

支持

SYSTEM 权限能看到所有，否则只能看到那些有READ_SCHEMA权限的路径上的template

支持

只能看到那些有READ_SCHEMA权限的路径上的template

只能看到那些有READ_SCHEMA权限的路径上的template

只能看到那些有READ_SCHEMA权限的路径上的template



查看挂载了某个设备模板的路径

show paths set device template t1

支持


不支持

支持


SYSTEM 权限能看到所有，否则只能看到那些有READ_SCHEMA权限的路径

支持

只能看到那些有READ_SCHEMA权限的路径

只能看到那些有READ_SCHEMA权限的路径

只能看到那些有READ_SCHEMA权限的路径



查看使用了某个设备模板的路径（即模板在该路径上已激活，序列已创建）

show paths using device template t1

支持

只能看到那些有READ_SCHEMA权限的路径

支持

只能看到那些有READ_SCHEMA权限的路径

只能看到那些有READ_SCHEMA权限的路径

只能看到那些有READ_SCHEMA权限的路径

只能看到那些有READ_SCHEMA权限的路径

只能看到那些有READ_SCHEMA权限的路径



解除

支持

需要对应路径的 WRITE_SCHEMA 权限

支持

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限

需要对应路径的 WRITE_SCHEMA 权限



卸载


支持

不支持


支持

需要 SYSTEM 权限

支持


不支持

不支持

不支持



删除


支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持



修改


支持

不支持


支持

需要 SYSTEM/EXTEND_TEMPLATE 权限

支持


不支持

不支持

不支持

集群管理


测试连接连通性

TestConnectionStatement

支持

需要 MAINTAIN 权限

支持

需要 MAINTAIN/SYSTEM 权限

支持

不支持

不支持

不支持



展示时间分区槽

showTimeSlotListStatement


支持

需要 MAINTAIN 权限

支持

需要 MAINTAIN/SYSTEM 权限

支持

不支持

不支持

不支持



统计时间分区槽个数

countTimeSlotListStatement

支持


需要 MAINTAIN 权限

支持


需要 MAINTAIN/SYSTEM 权限


支持

不支持

不支持

不支持



展示序列分区槽

showSeriesSlotListStatement

支持


需要 MAINTAIN 权限

支持


需要 MAINTAIN/SYSTEM 权限

支持

不支持

不支持


不支持



设置空间限制

SetSpaceQuotaStatement

支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持



设置流量限制

SetThrottleQuotaStatement

支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持



展示空间限制

ShowSpaceQuotaStatement

支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持



展示流量限制

ShowThrottleQuotaStatement

支持

不支持

支持

需要 SYSTEM 权限

支持

不支持

不支持

不支持

Trigger 管理

创建

支持

需要 USE_TRIGGER 权限


支持

需要 SYSTEM/USE_TRIGGER 权限

支持

不支持

不支持

不支持



删除

支持

需要 USE_TRIGGER 权限

支持

需要 SYSTEM/USE_TRIGGER 权限

支持

不支持

不支持

不支持



展示

支持

需要 USE_TRIGGER 权限

支持

需要 SYSTEM/USE_TRIGGER 权限

支持

不支持


不支持

不支持

CQ 管理

创建


支持

需要 USE_CQ 权限

支持

需要 SYSTEM/USE_CQ 权限

支持


不支持

不支持

不支持



查询

支持

需要 USE_CQ 权限

支持

需要 SYSTEM/USE_CQ 权限

支持


不支持

不支持

不支持



删除

支持

需要 USE_CQ 权限

支持

需要 SYSTEM/USE_CQ 权限

支持

不支持

不支持

不支持



运行阶段


支持

需要有源序列上的READ_DATA以及目标序列的WRITE_DATA权限，若涉及自动创建，还需WRITE_SCHEMA权限

支持

需要有源序列上的READ_DATA以及目标序列的WRITE_DATA权限，若涉及自动创建，还需WRITE_SCHEMA权限

需要有源序列上的READ_DATA以及目标序列的WRITE_DATA权限，若涉及自动创建，还需WRITE_SCHEMA权限

不支持


不支持


不支持


Load 



支持

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

支持

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

写入数据



支持

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

支持

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA


需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

需要对应路径的 WRITE_DATA 权限，自动创建还需要 WRITE_SCHEMA

删除数据



支持

需要对应路径的 WRITE_DATA 权限

支持

需要对应路径的 WRITE_DATA 权限

需要对应路径的 WRITE_DATA 权限

需要对应路径的 WRITE_DATA 权限

需要对应路径的 WRITE_DATA 权限

需要对应路径的 WRITE_DATA 权限

更新数据



支持


需要对应路径的 WRITE_DATA 权限

支持

需要对应路径的 WRITE_DATA 权限

需要对应路径的 WRITE_DATA 权限

需要对应路径的 WRITE_DATA 权限

需要对应路径的 WRITE_DATA 权限

需要对应路径的 WRITE_DATA 权限

查询数据

SELECT

支持

需要对应路径的 READ_DATA 权限

支持

需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限


需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限



ExplainStatement


支持

不支持


支持

需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限



ExplainAnalyzeStatement

支持

需要对应路径的 READ_DATA 权限

支持

需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限


需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限

需要对应路径的 READ_DATA 权限



查询写回

支持

需要对应源路径的 READ_DATA 权限，以及对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

支持

需要对应源路径的 READ_DATA 权限，以及对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

需要对应源路径的 READ_DATA 权限，以及对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

需要对应源路径的 READ_DATA 权限，以及对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

需要对应源路径的 READ_DATA 权限，以及对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

需要对应源路径的 READ_DATA 权限，以及对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

Pipe 运行时

IoTDB-Source


支持


需要对应源路径的 READ_DATA 权限

支持


需要对应源路径的 READ_DATA 权限

需要对应源路径的 READ_DATA 权限


需要对应源路径的 READ_DATA 权限

需要对应源路径的 READ_DATA 权限

需要对应源路径的 READ_DATA 权限



Write-back-sink

支持


需要对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

支持

需要对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

需要对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

需要对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

需要对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

需要对应目标路径的WRITE_DATA权限，若设计自动创建，还需WRITE_SCHEMA权限

查看占用磁盘空间

ShowDiskUsageStatement





支持

需要 SYSTEM 权限

需要 SYSTEM 权限

不支持

不支持

不支持

表模型专有操作


一级功能

二级功能

修改前



三权分立关闭



三权分立打开











root 用户

普通用户

超级管理员

普通用户

系统管理员

安全管理员

审计管理员

普通用户

权限管理

撤销用户某一个权限的 WITH GRANT OPTION

支持


获得权限或角色时指定了 grant option 关键字

支持


获得权限或角色时指定了 grant option 关键字
或 SECURITY 权限


不支持


支持撤销用户除了 SYSTEM 、SECURITY和 AUDIT 以外的所有普通权限的with grant option


不支持

不支持




撤销角色某一个权限的 WITH GRANT OPTION

支持

获得权限或角色时指定了 grant option 关键字

支持

获得权限或角色时指定了 grant option 关键字
或 SECURITY 权限

不支持


支持


不支持


不支持

数据库管理

使用
USE XXX

支持

拥有ANY，该数据库或数据库内任意表的任意权限即可使用该数据库

支持

拥有ANY，该数据库或数据库内任意表的任意权限即可使用该数据库
或 SYSTEM 权限

支持


有ANY，该数据库或数据库内任意表的任意权限即可使用该数据库

有ANY，该数据库或数据库内任意表的任意权限即可使用该数据库


拥有ANY，该数据库或数据库内任意表的任意权限即可使用该数据库

运维语句

showCurrentDatabaseStatement

支持


支持

支持

支持

支持

支持

支持

支持

表管理

创建

支持

需要对应 table（或所属DB，或 ANY） 的 CREATE 权限

支持

需要对应 table（或所属DB，或 ANY） 的 CREATE 权限
或 SYSTEM 权限


支持

需要对应 table（或所属DB，或 ANY） 的 CREATE 权限

需要对应 table（或所属DB，或 ANY） 的 CREATE 权限

需要对应 table（或所属DB，或 ANY） 的 CREATE 权限



展示（包括 SHOW CREATE）

支持

拥有该表（或所属DB，或ANY）的任意权限即可列出该表

支持

拥有该表（或所属DB，或ANY）的任意权限即可列出该表
或 SYSTEM 权限

支持

拥有该表（或所属DB，或ANY）的任意权限即可列出该表

拥有该表（或所属DB，或ANY）的任意权限即可列出该表

拥有该表（或所属DB，或ANY）的任意权限即可列出该表



修改


支持

需要对应 table（或所属DB，或 ANY） 的 ALTER 权限

支持

需要对应 table（或所属DB，或 ANY） 的 ALTER 权限
或 SYSTEM 权限

支持


需要对应 table（或所属DB，或 ANY） 的 ALTER 权限

需要对应 table（或所属DB，或 ANY） 的 ALTER 权限

需要对应 table（或所属DB，或 ANY） 的 ALTER 权限



删除

支持

需要对应 table 的 DROP 权限

支持

需要对应 table（或所属DB，或 ANY） 的 DROP 权限
或 SYSTEM 权限

支持

需要对应 table（或所属DB，或 ANY） 的 DROP 权限

需要对应 table（或所属DB，或 ANY） 的 DROP 权限

需要对应 table（或所属DB，或 ANY） 的 DROP 权限

表视图管理

创建


支持


需要对应源路径的 READ_SCHEMA 和 READ_DATA 权限以及需要对应 view（或所属DB，或 ANY） 的 CREATE 权限

支持

SYSTEM 权限 且 
需要对应源路径的 READ_SCHEMA 和 READ_DATA 权限以及需要对应 view（或所属DB，或 ANY） 的 CREATE 权限


支持

需要对应源路径的 READ_SCHEMA 和 READ_DATA 权限以及需要对应 view（或所属DB，或 ANY） 的 CREATE 权限

需要对应源路径的 READ_SCHEMA 和 READ_DATA 权限以及需要对应 view（或所属DB，或 ANY） 的 CREATE 权限

需要对应源路径的 READ_SCHEMA 和 READ_DATA 权限以及需要对应 view（或所属DB，或 ANY） 的 CREATE 权限



修改

支持

需要对应视图 的 ALTER 权限

支持

SYSTEM 权限 或 需要对应视图 的 ALTER 权限

支持

 需要对应视图 的 ALTER 权限

 需要对应视图 的 ALTER 权限

 需要对应视图 的 ALTER 权限



展示（包括 SHOW CREATE）


支持

需要对应视图 或对应 db 或 ANY 的任意权限

支持

SYSTEM 权限 或 需要对应视图 或对应 db 或 ANY 的任意权限

支持

需要对应视图 或对应 db 或 ANY 的任意权限

需要对应视图 或对应 db 或 ANY 的任意权限

需要对应视图 或对应 db 或 ANY 的任意权限



删除

支持

需要对应视图的 DROP 权限

支持

SYSTEM 权限 或 对应视图的 DROP 权限

支持

对应视图的 DROP 权限

对应视图的 DROP 权限

对应视图的 DROP 权限

设备管理

展示

支持

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

支持

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限



删除


支持

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限

支持

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限

Load 



支持

需要对应 table（或所属DB，或ANY）的 INSERT 权限
如果触发 Database 自动创建时，需要对应 database 的 CREATE 权限 (相比写入的增量)
如果写入自动创建表，则需要对应 table（或所属 DB，或 ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或 ANY） 的 ALTER 权限

支持


需要对应 table（或所属DB，或ANY）的 INSERT 权限
如果触发 Database 自动创建时，需要对应 database 的 CREATE 权限 (相比写入的增量)
如果写入自动创建表，则需要对应 table（或所属 DB，或 ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或 ANY） 的 ALTER 权限

需要对应 table（或所属DB，或ANY）的 INSERT 权限
如果触发 Database 自动创建时，需要对应 database 的 CREATE 权限 (相比写入的增量)
如果写入自动创建表，则需要对应 table（或所属 DB，或 ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或 ANY） 的 ALTER 权限

需要对应 table（或所属DB，或ANY）的 INSERT 权限
如果触发 Database 自动创建时，需要对应 database 的 CREATE 权限 (相比写入的增量)
如果写入自动创建表，则需要对应 table（或所属 DB，或 ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或 ANY） 的 ALTER 权限

需要对应 table（或所属DB，或ANY）的 INSERT 权限
如果触发 Database 自动创建时，需要对应 database 的 CREATE 权限 (相比写入的增量)
如果写入自动创建表，则需要对应 table（或所属 DB，或 ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或 ANY） 的 ALTER 权限

需要对应 table（或所属DB，或ANY）的 INSERT 权限
如果触发 Database 自动创建时，需要对应 database 的 CREATE 权限 (相比写入的增量)
如果写入自动创建表，则需要对应 table（或所属 DB，或 ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或 ANY） 的 ALTER 权限

写入数据



支持

insertTablet、sql 写入都需要对应 table（或所属DB，或ANY）的 INSERT 权限
insertTablet 自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
insertTablet 触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

支持

insertTablet、sql 写入都需要对应 table（或所属DB，或ANY）的 INSERT 权限
insertTablet 自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
insertTablet 触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限


insertTablet、sql 写入都需要对应 table（或所属DB，或ANY）的 INSERT 权限
insertTablet 自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
insertTablet 触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

insertTablet、sql 写入都需要对应 table（或所属DB，或ANY）的 INSERT 权限
insertTablet 自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
insertTablet 触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

insertTablet、sql 写入都需要对应 table（或所属DB，或ANY）的 INSERT 权限
insertTablet 自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
insertTablet 触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

insertTablet、sql 写入都需要对应 table（或所属DB，或ANY）的 INSERT 权限
insertTablet 自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
insertTablet 触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

删除数据



支持

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限 

支持

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限 


需要对应 table（或所属DB，或 ANY） 的 DELETE 权限 

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限 

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限 

需要对应 table（或所属DB，或 ANY） 的 DELETE 权限 

更新数据



支持

需要对应 table（或所属DB，或ANY） 的 INSERT 权限

支持

需要对应 table（或所属DB，或ANY） 的 INSERT 权限

需要对应 table（或所属DB，或ANY） 的 INSERT 权限

需要对应 table（或所属DB，或ANY） 的 INSERT 权限

需要对应 table（或所属DB，或ANY） 的 INSERT 权限

需要对应 table（或所属DB，或ANY） 的 INSERT 权限

查询数据

Query

支持

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

支持

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限



ExplainStatement

支持

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

支持

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限



ExplainAnalyzeStatement


支持


需要对应 table（或所属DB，或ANY） 的 SELECT 权限

支持

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限



查询写回

支持


需要源表（或所属DB，或ANY） 的 SELECT 权限以及目标表（或所属DB，或ANY）的INSERT权限

支持

需要源表（或所属DB，或ANY） 的 SELECT 权限以及目标表（或所属DB，或ANY）的INSERT权限

需要源表（或所属DB，或ANY） 的 SELECT 权限以及目标表（或所属DB，或ANY）的INSERT权限

需要源表（或所属DB，或ANY） 的 SELECT 权限以及目标表（或所属DB，或ANY）的INSERT权限

需要源表（或所属DB，或ANY） 的 SELECT 权限以及目标表（或所属DB，或ANY）的INSERT权限

需要源表（或所属DB，或ANY） 的 SELECT 权限以及目标表（或所属DB，或ANY）的INSERT权限

Pipe 运行时

IoTDB-Source


支持


需要对应 table（或所属DB，或ANY） 的 SELECT 权限

支持

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限

需要对应 table（或所属DB，或ANY） 的 SELECT 权限



Write-back-sink

支持


需要对应 table（或所属DB，或ANY）的 INSERT 权限
自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

支持

需要对应 table（或所属DB，或ANY）的 INSERT 权限
自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

需要对应 table（或所属DB，或ANY）的 INSERT 权限
自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

需要对应 table（或所属DB，或ANY）的 INSERT 权限
自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

需要对应 table（或所属DB，或ANY）的 INSERT 权限
自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

需要对应 table（或所属DB，或ANY）的 INSERT 权限
自动创建表时需要对应 table（或所属DB，或ANY） 的 CREATE 权限
触发标识列、属性列和物理量列的自动扩展时，需要对应 table （或所属DB，或ANY） 的 ALTER 权限

特别说明
树模型：
不能对以 root.__audit. 开头的前缀路径赋权
对 root.** 开头赋权的操作不会对 root.__audit_log 的可见性造成影响
root.__audit下的数据只对拥有 AUDIT 权限的用户可见
root.__audit 外部用户不可写
表模型：
不能对__audit database 以及下属的table/view 赋权
__audit database 以及下属的table/view 只对拥有 AUDIT 权限的用户可见可查
__audit database 对所有外部用户都不可修改

本次改动后，部分操作的鉴权会延迟到执行阶段进行


操作

鉴权方式

鉴权失败的处理

Kill query

在规划阶段仅检查用户是否可以 kill 任何人的 query，如果无权 kill 其他人的 query 时，在 rpc 参数中传入用户名，执行时根据用户名和执行 query 的用户名进行比较

对于 kill all query 的情况，只能 kill 用户自己的；
对于指定 query id 时，如果没有权限则报错







非功能定义
性能要求
三权分立打开前后，普通用户的写入和查询的性能不受影响

兼容性要求
不影响升级前任何用户的权限，但会对之前一些不合理的权限设计做修正
安全性要求
关键设计决策：
支持关 -> 开切换，不支持开 -> 关切换
普通包：默认关
安全包：默认开




IoTDB

GaussDB

PolarDB

OB

DB2

是否有明确的三权分立的三个角色的划分

有

有

有

有

无

三权分立由谁开启


通过修改配置项进行（配置文件未加密时），此种途径不涉及任何用户
enable_separation_of_powers 配置项只能通过超级管理员从 false 修改为 true
不支持任何人将 enable_separation_of_powers 从 true 修改为 false

未提及，猜测是初始用户


开启：RAM 用户
关闭：RAM 用户登录控制台，高权限账号（系统管理员）密码进行二次验证

SYS 用户


管理员自行分配权限人工设计

三权分立开启与关闭，能否来回切换

只能由关闭到打开，不能由打开到关闭

能，不建议

能，不建议


没有这项配置

没有这项配置

三权分立开启后，对于开启前的用户已分配的权限如何做处理？


不做任何处理，用户拥有开启前的所有权限，即使这些权限的组合不满足三权分立的要求

依赖用户在开启三权分立前，对所有用户权限手动裁剪


不做任何处理，用户拥有开启前的所有权限，即使这些权限的组合不满足三权分立的要求

需要注意的是，当需从非三权分立权限管理模型切换至三权分立权限管理模型时，应重新审视已有用户的权限集合。如用户具备系统管理员权限和审计管理员权限，则需要进行权限裁剪。

由于安全管理员和审计管理员是开启三权分立时才创建的，且无法对系统管理员、安全管理员、审计管理员赋权和撤回权限，所以不会有任何问题

没有这项配置


没有这项配置

三权分立的打开和关闭是否支持热加载


支持

未知

支持，官网提到需要等待 3~5 秒才能生效

没有这项配置

没有这项配置

三种管理员能否有多个


能


能

不能

未提及，推测可以通过创建用户并赋予相关权限做到

能

是否有内置的三种管理员

有，
原 超级管理员（root ）变为没有任何权限的普通用户
内置 sys_admin（只拥有SYST 权限）
内置 security_admin 用户为安全管理员（只拥有SECURITY 权限）
内置 audit_admin 用户为审计管理员（只拥有 AUDIT 权限）

无，需要开启后创建


无，开启时强制用户手动创建


有，但需要开启后手动解锁

无


系统管理员拥有的权限

DDL 权限（数据库管理、表管理、UDF 管理、Trigger、TTL管理等）
运维权限
集群管理权限



仅有对表空间有创建、修改、删除、访问、分配操作的权限、系统对象（类似于系统表）的权限

并没有运维权限，因为它有单独的运维管理员分类

仅 DDL 权限

配置参数、创建数据库对象、分配自主访问权限、导入导出数据等

分配自主访问权限：能够通过 GRANT 将拥有的权限赋予其他用户

文档中称为数据库管理员的用户有 DBADM 权限，此权限拥有创建对象和发出数据库命令的权限

安全管理员拥有的权限

用户、角色以及权限管理


用户、角色以及权限管理

用户、角色以及权限管理


设置系统安全等级、范围和组

概述文档中还写出了具有一些审计管理员的权限，不确定描述是否正确

文档中称为安全管理员的用户有 SECADM 权限，此权限可以创建和管理与安全相关的数据库对象，还有审计权限

审计管理员拥有的权限

维护审计规则
查询审计日志


维护审计规则
查询审计日志

查询审计日志


设置需要审计的对象、定义新的数据库审计员、查看和分析审计记录

概述文档中还写出了具有一些安全管理员的权限，不确定描述是否正确

没有审计管理员的说法

三种管理员名字是否可变

能，只能被自己或对应的初始管理员修改

能

不能

未知

能

三种管理员密码能够被谁修改


只能被自己或对应的初始管理员修改

初始XX管理员的密码只能由他自己修改


只能被对应的一类管理员自己或者初始用户


只能被他们自己


有修改密码权限的用户（如 SYS）或他们自己

任意有修改密码权限的用户或他们自己

普通用户能够被谁创建

安全管理员

安全管理员/初始用户

安全管理员

有创建用户权限的用户，内置用户中为 SYS 用户

外部安全机制（如操作系统中的用户管理）

系统管理员能够被谁创建

这里的创建隐含意思就是赋予某个用户系统管理员的权限

初始系统管理员



初始用户/其他系统管理员

三权分立后没有提及还是否能由系统管理员创建，也没有提及是否能由安全管理员创建

RAM 用户

有创建用户权限的用户，内置用户中为 SYS 用户

外部安全机制（如操作系统中的用户管理）


安全管理员能够被谁创建

这里的创建隐含意思就是赋予某个用户安全管理员的权限

初始安全管理员


三权分立打开时，只能由安全管理员创建
没有提到初始用户，但推断初始用户在任何情况下都应该可以创建安全管理员，不然第一个安全管理员哪里来？

RAM 用户

有创建用户权限的用户，内置用户中为 SYS 

外部安全机制（如操作系统中的用户管理）

审计管理员能够被谁创建

这里的创建隐含意思就是赋予某个用户审计管理员的权限


初始审计管理员


三权分立打开时，只能由审计管理员创建
没有提到初始用户，但推断初始用户在任何情况下都应该可以创建审计管理员，不然第一个安全管理员哪里来？

此处官方文档自相矛盾，详见 GaussDB 的调研文档

RAM 用户


有创建用户权限的用户，三种内置用户都能够创建

概述文档中写安全管理员和数据库审计员能够定义新的审计员，不确定描述是否正确

外部安全机制（如操作系统中的用户管理）

三种管理员是否还能被 GRANT/REVOKE

即三种管理员还能否被安全管理员赋予其他对象权限，去查询用户数据


能，只能被安全管理员赋予其他普通的对象权限


能，只能被安全管理员赋予其他普通的对象权限


否


能


能


三种管理员的权限是否在系统层面保证互斥

即某一种管理员只能拥有自己的一种全局权限

是


是

是

否


否

安全功能自查清单


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

不涉及



是否提供安全配置指引，如提醒用户修改默认密码、限制端口访问范围？

不涉及

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

安全测试

该功能是否支持安全漏洞扫描？

是



该功能是否便于开展渗透测试？

是



该功能上线前是否需通过专项安全测试？

是

场景示例
无法给任何一个用户赋予两个及以上的系统权限

./sbin/start-cli.sh -u security_admin -pw TimechoDB@2021 -sql_dialect table
create user system1 'timechotimecho';
create user security1 'timechotimecho';
create user audit1 'timechotimecho';
grant security to user security1;

./sbin/start-cli.sh -u sys_admin -pw TimechoDB@2021 -sql_dialect table
grant system to user system1;

./sbin/start-cli.sh -u audit_admin -pw TimechoDB@2021 -sql_dialect table
grant audit to user audit1;


-- 下面会报错
./sbin/start-cli.sh -u sys_admin -pw TimechoDB@2021 -sql_dialect table
grant system to user security1;
grant system to user audit1;

./sbin/start-cli.sh -u security_admin -pw TimechoDB@2021 -sql_dialect table
grant security to user system1;
grant security to user audit1;

./sbin/start-cli.sh -u audit_admin -pw TimechoDB@2021 -sql_dialect table
grant audit to user system1;
grant audit to user security1;
三权分立打开时，仅三个初始用户能够赋予相应的系统权限

./sbin/start-cli.sh -u security_admin -pw timechotimecho -sql_dialect table
create user system2 'timechotimecho';
create user security2 'timechotimecho';
create user audit2 'timechotimecho';

-- 下面会报错
./sbin/start-cli.sh -u system1 -pw timechotimecho -sql_dialect table
grant system to user system2;

./sbin/start-cli.sh -u security1 -pw timechotimecho -sql_dialect table
grant security to user security2;

./sbin/start-cli.sh -u audit1 -pw timechotimecho -sql_dialect table
grant audit to user audit2;

安全管理员、审计管理员无法创建db、table等，系统管理员可以

./sbin/start-cli.sh -u sys_admin -pw TimechoDB@2021 -sql_dialect table
create database test;
create table test.t1(device_id STRING tag, s1 float field);

-- 下面会报错
./sbin/start-cli.sh -u security_admin -pw TimechoDB@2021 -sql_dialect table
create database test;
create table test.t1(device_id STRING tag, s1 float field);

./sbin/start-cli.sh -u audit_admin -pw TimechoDB@2021 -sql_dialect table
create database test;
create table test.t1(device_id STRING tag, s1 float field);
系统管理员、审计管理员无法创建用户、赋予用户权限等，安全管理员可以

./sbin/start-cli.sh -u sys_admin -pw TimechoDB@2021 -sql_dialect table
create user tytyty 'tytytytytyty'

./sbin/start-cli.sh -u audit_admin -pw TimechoDB@2021 -sql_dialect table
create user tytyty 'tytytytytyty'

./sbin/start-cli.sh -u security_admin -pw TimechoDB@2021 -sql_dialect table
create user tytyty 'tytytytytyty'
系统管理员、安全管理员看不到审计日志，审计管理员能够看到

./sbin/start-cli.sh -u sys_admin -pw TimechoDB@2021 -sql_dialect table
-- 看不到 __audit
show databases;
-- 报错
use __audit;

./sbin/start-cli.sh -u security_admin -pw TimechoDB@2021 -sql_dialect table
-- 看不到 __audit
show databases;
-- 报错
use __audit;

./sbin/start-cli.sh -u audit_admin -pw TimechoDB@2021 -sql_dialect table
-- 能看到 __audit
show databases;
-- 不报错
use __audit;

show/set configuration，只有对应的管理员能够查看/修改他们相关的配置
具体参考 3.1.2.1.1 小节

./sbin/start-cli.sh -u sys_admin -pw TimechoDB@2021 -sql_dialect table
show all configuration;

./sbin/start-cli.sh -u security_admin -pw TimechoDB@2021 -sql_dialect table
show all configuration;

./sbin/start-cli.sh -u audit_admin -pw TimechoDB@2021 -sql_dialect table
show all configuration;
系统管理员、审计管理员们只有自己能够修改自己的密码和用户名，初始安全管理员可以修改所有安全管理员的密码和用户名，其他安全管理员只能修改自己的用户名和密码，所有安全管理员均可修改普通用户的密码和用户名


./sbin/start-cli.sh -u security_admin -pw TimechoDB@2021 -sql_dialect table
create user normal1 'timechotimecho'

./sbin/start-cli.sh -u sys_admin -pw TimechoDB@2021 -sql_dialect table
-- 失败
alter user system1 set password 'timechotimecho'
-- 失败
alter user normal1 set password 'timechotimecho'
-- 成功
alter user sys_admin set password 'timechotimecho'

./sbin/start-cli.sh -u system1 -pw timechotimecho -sql_dialect table
-- 失败
alter user sys_admin set password 'timechotimecho'
-- 失败
alter user normal1 set password 'timechotimecho'
-- 成功
alter user system1 set password 'timechotimecho'


./sbin/start-cli.sh -u security_admin -pw TimechoDB@2021 -sql_dialect table
-- 失败
alter user system1 set password 'timechotimecho'
-- 失败
alter user sys_admin set password 'timechotimecho'
-- 失败
alter user audit1 set password 'timechotimecho'
-- 失败
alter user audit_admin set password 'timechotimecho'
-- 成功
alter user normal1 set password 'timechotimecho'
-- 成功
alter user security1 set password 'timechotimecho'
-- 成功
alter user security_admin set password 'timechotimecho'

./sbin/start-cli.sh -u security1 -pw timechotimecho -sql_dialect table
-- 失败
alter user security_admin set password 'timechotimecho'
-- 失败
alter user system1 set password 'timechotimecho'
-- 失败
alter user sys_admin set password 'timechotimecho'
-- 失败
alter user audit1 set password 'timechotimecho'
-- 失败
alter user audit_admin set password 'timechotimecho'
-- 成功
alter user normal1 set password 'timechotimecho'
-- 成功
alter user security1 set password 'timechotimecho'


./sbin/start-cli.sh -u audit_admin -pw TimechoDB@2021 -sql_dialect table
-- 失败
alter user audit1 set password 'timechotimecho'
-- 失败
alter user normal1 set password 'timechotimecho'
-- 成功
alter user audit_admin set password 'timechotimecho'

./sbin/start-cli.sh -u audit1 -pw timechotimecho -sql_dialect table
-- 失败
alter user audit_admin set password 'timechotimecho'
-- 失败
alter user normal1 set password 'timechotimecho'
-- 成功
alter user audit1 set password 'timechotimecho'

所有管理员默认无法查询用户的数据

./sbin/start-cli.sh -u sys_admin -pw timechotimecho -sql_dialect table
-- 报错
select * from test.t1

./sbin/start-cli.sh -u security_admin -pw timechotimecho -sql_dialect table
-- 报错
select * from test.t1

./sbin/start-cli.sh -u audit_admin -pw timechotimecho -sql_dialect table
-- 报错
select * from test.t1

安全管理员可以授予对象权限给其他管理员，从而其他管理员能够查询到用户数据

./sbin/start-cli.sh -u security_admin -pw timechotimecho -sql_dialect table
grant select on test.t1 to user system1;

./sbin/start-cli.sh -u system1 -pw timechotimecho -sql_dialect table
-- 成功
select * from test.t1


完成计划


功能内容

人员

预计排期

三权分立关闭



三权分立打开









开发状态

自测状态

开发状态

自测状态

新增三个全局权限

拆出一个 pr 往 master 提，但入口处暂时不禁止之前的全局权限的授予和回收

@舒文炜

V2.0.7.1

完成

完成

完成

完成

梳理所有代码里的鉴权发生点，放到一个抽象的接口里

开源版只有一个三权分立关闭时的实现类
企业版增加三权分立打开时的实现类

@舒文炜
@田原

V2.0.7.1

完成

完成

完成

完成

内置初始管理员的创建

@舒文炜

V2.0.7.1

完成

完成

完成

完成

管理员支持赋权和回收

@舒文炜

V2.0.7.1

完成

完成

完成

完成

用户管理 V1

@舒文炜

V2.0.7.1

完成

完成

完成

完成

用户管理 V2

支持修改用户名

@陈荣钊

V2.0.7.1

完成

完成

完成

完成

角色管理

@舒文炜

V2.0.7.1

完成

完成

完成

完成

权限管理V1

@舒文炜

V2.0.7.1

完成

完成

完成

完成

权限管理V2

实现普通用户只能撤销由他自己直接授权出去的权限

TBD

暂不实现










审计日志相关：
1. 鉴权
内置表视图的建立（让表模型用户也能查询审计日志）

@陈荣钊
@朱锦涛

V2.0.7.1

完成

完成

完成

完成

集群管理

@舒文炜

V2.0.7.1

完成

完成

完成

完成

运维语句

@舒文炜

V2.0.7.1

完成

完成

完成

完成

新增 showAvailableUrls

树和表


@舒文炜

V2.0.7.1

完成

完成

完成

完成

UDF 管理

@田原

V2.0.7.1

完成

完成

完成

完成

模板管理

@田原

V2.0.7.1

完成

完成

完成

完成

TRIGGER 管理 V1

不应该能对root.__aduit 触发

@田原

V2.0.7.1

完成

完成

完成

完成

TRIGGER 管理 V2

修改为路径权限

TBD

暂不实现









CQ 管理 V1

@田原

V2.0.7.1

完成

完成

完成

完成

CQ 管理 V2

修改CQ语法，三权分立打开时，普通用户也应该能够有方式创建CQ

TBD

暂不实现









PIPE 管理 V1

@田原

V2.0.7.1

完成

完成

完成

完成

PIPE 管理 V2

用户可以看到任何source/sink 用户指向他自己的pipes

@陈哲涵

V2.0.7.1

完成

完成

完成

完成

PIPE 插件管理

@田原

V2.0.7.1

完成

完成

完成

完成

订阅管理 V1

@田原

V2.0.7.1

完成

完成

完成

完成

订阅管理 V2

精细化订阅权限

@陈哲涵

暂不实现









模型管理 V1

@田原

V2.0.7.1

完成

完成

完成

完成

模型管理 V2

创建训练任务和训练任务的运行时应该进一步细化权限

@陈荣钊

暂不实现









TTL 管理

@舒文炜

V2.0.7.1

完成

完成

完成

完成

数据库管理

对于root.__audit/__audit 需要做特殊处理
树和表

@田原

V2.0.7.1


完成

完成

完成

完成

设备管理

对于root.__audit 需要做特殊处理
树和表

@田原

V2.0.7.1

完成

完成

完成

完成

序列管理

对于root.__audit 需要做特殊处理

@田原

V2.0.7.1

完成

完成

完成

完成

序列视图管理

对于root.__audit 需要做特殊处理

@田原

V2.0.7.1

完成

完成

完成

完成

表管理

需要对 __audit 做特殊处理

@田原

V2.0.7.1

完成

完成

完成

完成

表视图管理

对于root.__audit_log 需要做特殊处理

@田原

V2.0.7.1

完成

完成

完成

完成

Load 

树和表
对于root.__audit_log 需要做特殊处理

@田原

V2.0.7.1

完成

完成

完成

完成

写入数据

树和表
对于root.__audit_log 需要做特殊处理

@田原

V2.0.7.1

完成


完成

完成


完成

删除数据

树和表
对于root.__audit_log 需要做特殊处理

@田原

V2.0.7.1

完成

完成

完成

完成

修改数据

树和表
对于root.__audit_log 需要做特殊处理

@田原

V2.0.7.1


完成

完成

完成

完成

查询数据

树和表
包含审计日志查询

@田原

V2.0.7.1

完成

完成

完成

完成

工具的开发，扫描三权分立从关闭到打开时哪些用户可能丧失哪些操作权限

@田原

暂不实现








四、自测及测试场景建议
三权分立打开时，仅三个初始用户能够赋予相应的系统权限
无法给任何一个用户赋予两个及以上的系统权限
安全管理员、审计管理员无法创建db、table等，系统管理员可以
系统管理员、审计管理员无法创建用户、赋予用户权限等，安全管理员可以
系统管理员、安全管理员看不到审计日志，审计管理员能够看到
show/set configuration，只有对应的管理员能够查看/修改他们相关的配置
具体参考 3.1.2.1.1 小节
管理员们只有自己能够修改自己的密码和用户名，但安全管理员可以修改普通用户的密码和用户名
所有管理员默认无法查询用户的数据
安全管理员可以授予对象权限给其他管理员，从而其他管理员能够查询到用户数据

附录：历史内容及讨论记录
2025年9月3日 内部讨论
讨论录屏：
讨论关键记录及结论：
先调研各个数据库的情况
田原：GaussDB、PolarDB、Oracle
舒文炜：OceanBase、TiDB、DB2
2025年9月4日 内部讨论
讨论录屏：
讨论关键记录及结论：
田原、舒文炜集中交流各自阶段性进展，统一文档编写风格，汇总调研对比表
2025年9月9日 内部讨论
讨论录屏：
讨论关键记录及结论：
挨个对一遍所有鉴权细节，确保没有互相矛盾的点

2025年9月10日 小范围评审
讨论录屏：
讨论关键记录及结论：
需要支持支持关 -> 开切换，不支持开 -> 关切换
普通包：默认关
安全包：默认开
初始系统管理员、初始安全管理员、初始审计管理员的初始姓名目前由配置项指定
初始管理员用户名和密码只能由他自己修改
其他管理员的用户名和密码可以由他自己和对应的初始管理员修改
初始管理员不能被删除
系统管理员、安全管理员、审计管理员可以有多个
三权分立打开后
SYSTEM 权限只能由初始系统管理员赋予
SECURITY 权限只能由初始安全管理员赋予
AUDIT 权限只能由初始审计管理员赋予
三权分立开启后，对于开启前的用户已分配的权限不做任何处理，用户拥有开启前的所有权限，即使这些权限的组合不满足三权分立的要求，依赖用户在开启三权分立前，对所有用户权限手动裁剪


2025年9月12日 小范围评审

讨论关键记录及结论：
三类管理员能否被赋予其他对象权限？
能
三权分立打开后，原来的超级管理员作何处理？
当做一个没有任何权限的且不可修改（改密码用户名、赋权、撤销权限、赋予角色、撤销角色）的普通用户，也不能登录
但可以被 list user 看到
保留 enable_separation_of_powers 配置项
理由是能够通过不同配置项的初始值去定制化用户不同的需求
打开三权分立仍然是通过 set configuration 去修改，只能由 false 改成 true
Set configuration 中包含 enable_separation_of_powers 配置项时，有且仅能包含这一个配置项
若包含多个则报错
若指定了 node-id，则报错
仅 seed cn 第一次启动时读取该配置项，并进行共识写
删除 dba_name、dsa_name、daa_name 这三个配置项
自动创建 sys_admin、security_admin 和 audit_admin 这三个初始管理员，后续支持通过 alter user XXX rename to YYY 去修改


安全包的原则
安全包不在代码里写死安全相关的配置
可以通过配置文件去配置出对应的安全包

