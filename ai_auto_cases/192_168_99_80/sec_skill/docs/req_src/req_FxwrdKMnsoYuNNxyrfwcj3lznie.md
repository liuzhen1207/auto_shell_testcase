V1.0.0.1-安全模块-身份鉴别功能-技术设计
版本变更记录


操作日期

文档版本

操作人

内容

2022.04.05

V0.1（初始版本）

田原

创建初始文档

2022.04.20

V1.0（正式评审版本）

田原

正式评审版本
设计背景
需求关联：V2.0.7.1-安全模块-身份鉴别-需求分析 
身份鉴别模块是 IoTDB 安全架构的核心组成部分，负责验证用户身份，确保只有合法和授权的用户能够访问数据库。
设计目标
功能目标：
负责验证用户身份，确保只有合法和授权的用户能够访问数据库；
该模块需要支持 Thrift和JDBC，以适应不同的应用场景；
考虑性能影响和后续兼容性的问题；
整体设计
身份鉴别是数据库内验证的第一道防线。



身份鉴别对数据库外，需要完整承接各类协议（Thrift、MQTT、REST 等等）接口的请求接入，需要做到身份鉴别的不漏不缺。
身份鉴别对数据库内，需要提供基础的用户名、密码的管理和鉴权能力，它是权限管理的基础。
因此，本文中身份鉴别主要关注 3 点：
用户名密码的管理
基于用户名密码的身份鉴别行为定义
各类协议接入身份鉴别的方式定义
核心鉴别流程如下：
image.png

各模块详细设计
统一接口层
设计目标
接收和解析来自不同协议的请求。
接口设计
实现一个统一的请求解析器，根据不同协议的请求格式，将请求分解为用户名、密码和其他必要信息。
细节设计
开发一个协议适配器，用于将各种协议的请求转换为统一的内部请求格式。适配器将负责处理协议特有的认证头或消息体，并提取认证信息，调用身份鉴别层进行身份确认。如下所示，首先需要把协议相关代码接入到包 org.apache.iotdb.db.protocol 下，形成统一的代码管理环境，然后提供身份鉴别层接口供统一接口层调用。
image.png

安全性设计


自查内容

说明

自查结果

第三方依赖安全


该功能是否引入新的第三方库、框架、工具或服务？

无



引入的新依赖是否存在已知安全漏洞？

不涉及



第三方依赖是否有备选方案？

不涉及

可用性

该功能是否具备抗拒绝服务（DoS）能力？

是



若功能涉及核心数据处理，是否具备灾难恢复能力？

是

机密性


该功能是否涉及跨网络 / 跨服务的数据传输，传输链路是否启用加密协议？

是



该功能涉及的数据存储是是否需进行加密存储？

是



该功能处理的敏感数据是否需进行数据加密？

是



加密算法是否符合安全标准？

是
身份鉴别层
设计目标
验证用户的用户名和密码。
接口设计
在集群中提供一个中心化的认证服务，该服务负责用于验证凭证。
细节设计
开发一个认证服务，该服务将接收来自统一接口层的请求，并与用户数据库交互以验证凭证。服务将实现负载均衡和故障转移机制（借助 ConfigNode 的高可用能力），以确保服务整体的高可用性。该认证服务的接口核心可定义为下述接口：

public interface IAuthorityFetcher {

  TSStatus checkUser(String username, String password);
}
安全性设计


自查内容

说明

自查结果

第三方依赖安全

该功能是否引入新的第三方库、框架、工具或服务？

无



引入的新依赖是否存在已知安全漏洞？

不涉及



第三方依赖是否有备选方案？

不涉及

可用性

该功能是否具备抗拒绝服务（DoS）能力？

是



若功能涉及核心数据处理，是否具备灾难恢复能力？

是

机密性


该功能是否涉及跨网络 / 跨服务的数据传输，传输链路是否启用加密协议？

是



该功能涉及的数据存储是是否需进行加密存储？

是



该功能处理的敏感数据是否需进行数据加密？

是



加密算法是否符合安全标准？

是
用户管理组件模块
设计目标
管理用户信息，包括创建、删除和更新用户。
接口设计

public interface PermissionManager {

  // 执行用户管理操作
  TSStatus operatePermission(AuthorPlan authorPlan, boolean isGeneratedByPipe);

  // 查询用户操作
  PermissionInfoResp queryPermission(final AuthorReadPlan authorPlan)；

  // 其他接口
}
细节设计
开发一组 SQL 命令，包括CREATE USER、DROP USER、LIST USER和ALTER USER，用于管理用户信息。这些命令将被 ConfigNode 实际执行。在 ConfigNode 上，负责用户管理的组件可由下面的 manager 架构实现：
创建用户
命令：CREATE USER <userName> <password>
设计：在用户数据库中创建新用户记录，存储用户名和加密后的密码。
删除用户
命令：DROP USER <userName>
设计：从用户数据库中删除指定用户记录。
 列出所有用户
命令：LIST USER
设计：查询用户数据库，返回所有用户列表。
更新密码
命令：ALTER USER <username> SET PASSWORD <password>
设计：更新用户数据库中指定用户的密码记录。
image.png

安全性设计


自查内容

说明

自查结果

第三方依赖安全

该功能是否引入新的第三方库、框架、工具或服务？

无



引入的新依赖是否存在已知安全漏洞？

不涉及



第三方依赖是否有备选方案？

不涉及

可用性

该功能是否具备抗拒绝服务（DoS）能力？

是



若功能涉及核心数据处理，是否具备灾难恢复能力？

是

机密性


该功能是否涉及跨网络 / 跨服务的数据传输，传输链路是否启用加密协议？

是



该功能涉及的数据存储是是否需进行加密存储？

是



该功能处理的敏感数据是否需进行数据加密？

是



加密算法是否符合安全标准？

是
凭证验证模块
设计目标
比对用户提供的凭证与数据库中存储的凭证。
接口设计

public interface PermissionManager {

  // 其他接口
  // ...
  
  // 用户凭证验证接口
  TPermissionInfoResp login(String username, String password);
}
细节设计
选择一个安全的哈希算法，用于存储和验证密码。开发一个密码哈希服务，负责在用户创建和密码更新时生成哈希值，并在登录时验证哈希值。这些过程将被 ConfigNode 实际执行。在 ConfigNode 上，负责用户管理登录的组件可由下面的 manager 架构实现：
image.png

安全性设计


自查内容

说明

自查结果

第三方依赖安全

该功能是否引入新的第三方库、框架、工具或服务？

无



引入的新依赖是否存在已知安全漏洞？

不涉及



第三方依赖是否有备选方案？

不涉及

可用性

该功能是否具备抗拒绝服务（DoS）能力？

是



若功能涉及核心数据处理，是否具备灾难恢复能力？

是

机密性


该功能是否涉及跨网络 / 跨服务的数据传输，传输链路是否启用加密协议？

是



该功能涉及的数据存储是是否需进行加密存储？

是



该功能处理的敏感数据是否需进行数据加密？

是



加密算法是否符合安全标准？

是
协议接入身份鉴别模块
设计目标
实现各协议接入身份鉴别。
接口设计
public static boolean Connect(String username, String password))
细节设计
Thrift
设计：在 Thrift 会话构造时，要求用户提供用户名和密码，并通过 Thrift 框架传递给服务器。

session = 
    new Session.Builder()
        .fetchSize(int fetchSize)
        .username(String username)
        .password(String password)
        .thriftDefaultBufferSize(int thriftDefaultBufferSize)
        .thriftMaxFrameSize(int thriftMaxFrameSize)
        .enableRedirection(boolean enableRedirection)
        .version(Version version)
        .build();
JDBC
设计：在 JDBC 连接字符串中包含用户名和密码，通过 JDBC 驱动程序传递给服务器。

public static Connection getConnection() {
    // JDBC driver name and database URL
    String driver = "org.apache.iotdb.jdbc.IoTDBDriver";
    String url = "jdbc:iotdb://127.0.0.1:6667/";
    // set rpc compress mode
    // String url = "jdbc:iotdb://127.0.0.1:6667?rpc_compress=true";

    // Database credentials
    String username = "root";
    String password = "root";

    Connection connection = null;
    try {
      Class.forName(driver);
      connection = DriverManager.getConnection(url, username, password);
    } catch (ClassNotFoundException e) {
      e.printStackTrace();
    } catch (SQLException e) {
      e.printStackTrace();
    }
    return connection;
  }
安全性设计


自查内容

说明

自查结果

第三方依赖安全

该功能是否引入新的第三方库、框架、工具或服务？

是



引入的新依赖是否存在已知安全漏洞？

无



第三方依赖是否有备选方案？

有

可用性

该功能是否具备抗拒绝服务（DoS）能力？

是



若功能涉及核心数据处理，是否具备灾难恢复能力？

是

机密性


该功能是否涉及跨网络 / 跨服务的数据传输，传输链路是否启用加密协议？

是



该功能涉及的数据存储是是否需进行加密存储？

是



该功能处理的敏感数据是否需进行数据加密？

是



加密算法是否符合安全标准？

是
缓存模块
设计目标
实现一个缓存系统，缓存频繁访问的用户凭证，减少非必要的向 ConfigNode 的网络 IO 次数。
接口设计
image.png

细节设计
image.png

安全性设计


自查内容

说明

自查结果

第三方依赖安全

该功能是否引入新的第三方库、框架、工具或服务？

无



引入的新依赖是否存在已知安全漏洞？

不涉及



第三方依赖是否有备选方案？

不涉及

可用性

该功能是否具备抗拒绝服务（DoS）能力？

不涉及



若功能涉及核心数据处理，是否具备灾难恢复能力？

不涉及

机密性


该功能是否涉及跨网络 / 跨服务的数据传输，传输链路是否启用加密协议？

不涉及



该功能涉及的数据存储是是否需进行加密存储？

不涉及



该功能处理的敏感数据是否需进行数据加密？

不涉及



加密算法是否符合安全标准？

不涉及
附录：历史内容及讨论记录
