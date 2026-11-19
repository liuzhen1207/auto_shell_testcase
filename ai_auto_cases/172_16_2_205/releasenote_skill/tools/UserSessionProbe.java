import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * TDB-1442 僵尸会话探测：
 *   1) 管理员创建用户 u 并授权；
 *   2) 用户 u 建立连接并执行语句（应成功）；
 *   3) 管理员 DROP USER u；
 *   4) 用**原连接**继续执行语句 → 应失败（802 会话失效），而不是继续成功；
 *   5) 管理员重建同名同密码用户并授权；
 *   6) 用**原连接**再执行 → 仍应失败（僵尸会话不能复活）；
 *   7) 新连接登录同名用户 → 应成功。
 *
 * 用法：java UserSessionProbe <host> <port> <adminUser> <adminPw> <user> <userPw>
 */
public class UserSessionProbe {
  public static void main(String[] args) throws Exception {
    String host = args[0];
    int port = Integer.parseInt(args[1]);
    String adminUser = args[2];
    String adminPw = args[3];
    String user = args[4];
    String userPw = args[5];
    String url = "jdbc:iotdb://" + host + ":" + port + "/?sql_dialect=table";
    Class.forName("org.apache.iotdb.jdbc.IoTDBDriver");

    Connection admin = null;
    Connection userCon = null;
    try {
      admin = DriverManager.getConnection(url, adminUser, adminPw);
      exec(admin, "DROP USER " + user, true);
      exec(admin, "CREATE USER " + user + " '" + userPw + "'", false);
      System.out.println("USER_CREATED=true");

      userCon = DriverManager.getConnection(url, user, userPw);
      System.out.println("USER_CONNECTED=true");
      System.out.println("BEFORE_DROP=" + query(userCon));

      exec(admin, "DROP USER " + user, false);
      System.out.println("DROPPED=true");
      Thread.sleep(3000);

      String afterDrop = query(userCon);
      System.out.println("AFTER_DROP=" + afterDrop);
      System.out.println("AFTER_DROP_STALE=" + isStale(afterDrop));

      exec(admin, "CREATE USER " + user + " '" + userPw + "'", false);
      System.out.println("RECREATED=true");
      Thread.sleep(3000);

      String afterRecreate = query(userCon);
      System.out.println("AFTER_RECREATE_OLD_SESSION=" + afterRecreate);
      System.out.println("AFTER_RECREATE_STALE=" + isStale(afterRecreate));

      Connection fresh = null;
      try {
        fresh = DriverManager.getConnection(url, user, userPw);
        System.out.println("NEW_SESSION=" + query(fresh));
        System.out.println("NEW_SESSION_OK=" + !query(fresh).startsWith("QUERY_ERR"));
      } catch (SQLException e) {
        System.out.println("NEW_SESSION_ERR=" + flat(e.getMessage()));
        System.out.println("NEW_SESSION_OK=false");
      } finally {
        if (fresh != null) {
          try {
            fresh.close();
          } catch (Exception ignore) {
          }
        }
      }
      exec(admin, "DROP USER " + user, true);
      System.out.println("CLEANUP=true");
    } catch (Exception e) {
      System.out.println("FATAL=" + flat(e.getMessage()));
    } finally {
      if (userCon != null) {
        try {
          userCon.close();
        } catch (Exception ignore) {
        }
      }
      if (admin != null) {
        try {
          admin.close();
        } catch (Exception ignore) {
        }
      }
      System.out.println("DONE");
    }
  }

  private static void exec(Connection c, String sql, boolean ignoreError) {
    try (Statement st = c.createStatement()) {
      st.execute(sql);
    } catch (SQLException e) {
      if (!ignoreError) {
        System.out.println("ADMIN_ERR[" + sql + "]=" + flat(e.getMessage()));
      }
    }
  }

  private static String query(Connection c) {
    try (Statement st = c.createStatement();
        ResultSet rs = st.executeQuery("show databases")) {
      int n = 0;
      while (rs.next()) {
        n++;
      }
      return "QUERY_OK rows=" + n;
    } catch (SQLException e) {
      return "QUERY_ERR " + flat(e.getMessage());
    }
  }

  private static boolean isStale(String r) {
    return r.startsWith("QUERY_ERR")
        && (r.contains("802") || r.toLowerCase().contains("session has timed out"));
  }

  private static String flat(String s) {
    return s == null ? "" : s.replace('\n', '|').replace('\r', ' ').trim();
  }
}
