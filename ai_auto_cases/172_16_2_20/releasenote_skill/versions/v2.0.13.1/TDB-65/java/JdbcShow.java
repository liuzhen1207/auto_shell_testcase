import java.sql.*;

public class JdbcShow {
  public static void main(String[] args) throws Exception {
    String host = args[0];
    int port = Integer.parseInt(args[1]);
    String dialect = args[2];
    String sql = args[3];
    Class.forName("org.apache.iotdb.jdbc.IoTDBDriver");
    String url = "jdbc:iotdb://" + host + ":" + port + "/"
        + ("table".equals(dialect) ? "?sql_dialect=table" : "");
    try (Connection c = DriverManager.getConnection(url, "root", "TimechoDB@2021");
         Statement st = c.createStatement()) {
      try { st.execute("SET SQL_DIALECT=" + ("table".equals(dialect) ? "TABLE" : "TREE")); } catch (Exception ignore) {}
      try (ResultSet rs = st.executeQuery(sql)) {
        ResultSetMetaData md = rs.getMetaData();
        StringBuilder sb = new StringBuilder();
        for (int i = 1; i <= md.getColumnCount(); i++) {
          if (i > 1) sb.append(",");
          sb.append(md.getColumnName(i));
        }
        System.out.println("COLS=" + md.getColumnCount() + " " + sb);
        int n = 0;
        while (rs.next()) {
          n++;
          if (n <= 2) {
            StringBuilder row = new StringBuilder("ROW ");
            for (int i = 1; i <= md.getColumnCount(); i++) {
              if (i > 1) row.append(" | ");
              row.append(md.getColumnName(i)).append("=").append(rs.getString(i));
            }
            System.out.println(row);
          }
        }
        System.out.println("ROWS=" + n);
      }
    }
  }
}
