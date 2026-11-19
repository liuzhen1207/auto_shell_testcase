import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;

/**
 * 连接数上限探测：维持 hold 个连接后，再尝试新建连接，输出错误文案；
 * 断言已有连接仍可用、释放一个后新连接可恢复。
 * 用法：java ConnLimitProbe <host> <port> <user> <password> <hold>
 */
public class ConnLimitProbe {
  public static void main(String[] args) throws Exception {
    String mode = args.length > 5 ? args[0] : "probe";
    int off = args.length > 5 ? 1 : 0;
    String host = args[off];
    int port = Integer.parseInt(args[off + 1]);
    String user = args[off + 2];
    String pw = args[off + 3];
    int hold = Integer.parseInt(args[off + 4]);
    if ("hold".equals(mode)) {
      int seconds = args.length > 6 ? Integer.parseInt(args[6]) : 60;
      List<Connection> hs = new ArrayList<>();
      for (int i = 0; i < hold; i++) {
        try {
          hs.add(DriverManager.getConnection("jdbc:iotdb://" + host + ":" + port + "/?sql_dialect=table", user, pw));
        } catch (SQLException e) {
          break;
        }
      }
      System.out.println("HOLDING=" + hs.size());
      System.out.flush();
      Thread.sleep(seconds * 1000L);
      for (Connection c : hs) { try { c.close(); } catch (Exception ignore) {} }
      System.out.println("HOLD_DONE");
      return;
    }
    String url = "jdbc:iotdb://" + host + ":" + port + "/?sql_dialect=table";

    Class.forName("org.apache.iotdb.jdbc.IoTDBDriver");
    List<Connection> held = new ArrayList<>();
    int okCount = 0;
    for (int i = 0; i < hold; i++) {
      try {
        held.add(DriverManager.getConnection(url, user, pw));
        okCount++;
      } catch (SQLException e) {
        System.out.println("HOLD_FAIL_AT=" + i + " MSG=" + flat(e.getMessage()));
        break;
      }
    }
    System.out.println("HOLD_OK=" + okCount);

    // 额外连接应被拒绝
    String extraMsg = "";
    boolean extraOk = false;
    try {
      Connection c = DriverManager.getConnection(url, user, pw);
      extraOk = true;
      c.close();
    } catch (SQLException e) {
      extraMsg = flat(e.getMessage());
    }
    System.out.println("EXTRA_OK=" + extraOk);
    System.out.println("EXTRA_MSG=" + extraMsg);
    System.out.println("HAS_RESOURCE_MSG=" + extraMsg.contains("not enough connection resources available"));
    System.out.println("HAS_OLD_MSG=" + extraMsg.contains("Check whether the server exists or is alive"));
    System.out.println("HAS_RESET=" + (extraMsg.contains("Connection reset") || extraMsg.contains("Socket is closed by peer")));
    System.out.println("HAS_POOL_MSG=" + extraMsg.contains("Insufficient connection pool resources"));
    System.out.println("HAS_CLEAR_MSG=" + (extraMsg.contains("not enough connection resources available") || extraMsg.contains("Insufficient connection pool resources")));

    // 已达上限时，已有连接应仍可执行
    boolean existingOk = false;
    if (!held.isEmpty()) {
      try (Statement st = held.get(0).createStatement();
          ResultSet rs = st.executeQuery("select 1")) {
        existingOk = rs.next();
      } catch (SQLException e) {
        System.out.println("EXISTING_ERR=" + flat(e.getMessage()));
      }
    }
    System.out.println("EXISTING_OK=" + existingOk);

    // 释放一个连接后应能新建
    if (!held.isEmpty()) {
      try {
        held.remove(0).close();
      } catch (Exception ignore) {
      }
      Thread.sleep(1500);
      boolean afterOk = false;
      try {
        Connection c = DriverManager.getConnection(url, user, pw);
        afterOk = true;
        c.close();
      } catch (SQLException e) {
        System.out.println("AFTER_RELEASE_ERR=" + flat(e.getMessage()));
      }
      System.out.println("AFTER_RELEASE_OK=" + afterOk);
    }

    for (Connection c : held) {
      try {
        c.close();
      } catch (Exception ignore) {
      }
    }
    System.out.println("DONE");
  }

  private static String flat(String s) {
    return s == null ? "" : s.replace('\n', '|').replace('\r', ' ').trim();
  }
}
