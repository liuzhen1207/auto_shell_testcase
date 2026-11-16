// TV-CLI-JDBC：通过 JDBC（Session 驱动）在树模型建序列并写入，用于验证视图自动补列
// 用法：java JdbcTv <host> <port> <user> <password> <sql1> [sql2 ...]
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Statement;

public class JdbcTv {
  public static void main(String[] args) throws Exception {
    String host = args[0], port = args[1], user = args[2], pw = args[3];
    Class.forName("org.apache.iotdb.jdbc.IoTDBDriver");
    String url = "jdbc:iotdb://" + host + ":" + port + "/";
    try (Connection conn = DriverManager.getConnection(url, user, pw);
        Statement st = conn.createStatement()) {
      for (int i = 4; i < args.length; i++) {
        st.execute(args[i]);
        System.out.println("OK: " + args[i]);
      }
    }
  }
}
