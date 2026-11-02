import org.apache.iotdb.session.Session;
import org.apache.iotdb.isession.SessionDataSet;
import java.util.List;

public class SessionShow {
  public static void main(String[] args) throws Exception {
    String host = args[0];
    int port = Integer.parseInt(args[1]);
    String dialect = args[2];
    String sql = args[3];
    Session s = new Session.Builder()
        .host(host).port(port).username("root").password("TimechoDB@2021").build();
    s.open(false);
    if ("table".equals(dialect)) {
      s.executeNonQueryStatement("SET SQL_DIALECT=TABLE");
    }
    try (SessionDataSet ds = s.executeQueryStatement(sql)) {
      List<String> cols = ds.getColumnNames();
      System.out.println("COLS=" + cols.size() + " " + String.join(",", cols));
      int n = 0;
      while (ds.hasNext()) {
        var r = ds.next();
        n++;
        if (n <= 2) System.out.println("ROW " + r);
      }
      System.out.println("ROWS=" + n);
    }
    s.close();
  }
}
