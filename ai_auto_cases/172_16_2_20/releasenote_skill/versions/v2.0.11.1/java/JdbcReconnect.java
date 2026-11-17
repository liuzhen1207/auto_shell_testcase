import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

/**
 * TDB-728: 查询执行过程中重启 DataNode，JDBC 是否自动重连并可复用 statement。
 * 用法：java -cp "<server.jar>:/tmp/rnjdbc" JdbcReconnect <host> <seconds>
 */
public class JdbcReconnect {
  public static void main(String[] args) throws Exception {
    String host = args.length > 0 ? args[0] : "172.16.2.19";
    int seconds = args.length > 1 ? Integer.parseInt(args[1]) : 60;
    Class.forName("org.apache.iotdb.jdbc.IoTDBDriver");
    String url = "jdbc:iotdb://" + host + ":6667/";
    int ok = 0, fail = 0;
    Connection conn = DriverManager.getConnection(url, "root", "TimechoDB@2021");
    Statement st = conn.createStatement();
    st.execute("SET SQL_DIALECT=TABLE");
    long end = System.currentTimeMillis() + seconds * 1000L;
    int i = 0;
    while (System.currentTimeMillis() < end) {
      i++;
      try {
        ResultSet rs = st.executeQuery("SELECT count(*) FROM rn_jdbc.t");
        rs.next();
        rs.getLong(1);
        rs.close();
        ok++;
        System.out.println("OK " + i + " at " + System.currentTimeMillis());
      } catch (Exception e) {
        fail++;
        System.out.println("FAIL " + i + " at " + System.currentTimeMillis() + " : " + e.getClass().getSimpleName() + " " + String.valueOf(e.getMessage()).replace('\n', ' '));
        try {
          Thread.sleep(1000);
        } catch (InterruptedException ignored) {
        }
      }
      try {
        Thread.sleep(300);
      } catch (InterruptedException ignored) {
      }
    }
    System.out.println("RESULT ok=" + ok + " fail=" + fail);
    try {
      st.close();
      conn.close();
    } catch (Exception ignored) {
    }
  }
}
