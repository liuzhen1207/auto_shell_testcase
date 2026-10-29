import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Statement;

/**
 * Write one OBJECT point of {@code totalMiB} MiB in {@code chunkMiB} chunks.
 *
 * <p>A single OBJECT value is assembled from parts: {@code to_object(isEOF, offset, X'..')}
 * carries an 8-byte offset and an EOF flag, so a 4 GiB point is written as many INSERTs of
 * the same (device, time) with increasing offsets.  The content is a 1 MiB block repeating
 * 0,1,2..250, so the expected sha256 is easy to reproduce outside the database.
 */
public class SingleObjectWriter {
  private static final char[] HEX = "0123456789abcdef".toCharArray();

  private static String hex(byte[] b, int len) {
    char[] out = new char[len * 2];
    for (int i = 0; i < len; i++) {
      int v = b[i] & 0xff;
      out[i * 2] = HEX[v >>> 4];
      out[i * 2 + 1] = HEX[v & 0xf];
    }
    return new String(out);
  }

  public static void main(String[] args) throws Exception {
    Class.forName("org.apache.iotdb.jdbc.IoTDBDriver");
    String url = args[0];
    String table = args[1];
    String dev = args[2];
    long ts = Long.parseLong(args[3]);
    long total = Long.parseLong(args[4]) * 1024L * 1024L;
    int chunk = Integer.parseInt(args[5]) * 1024 * 1024;
    String user = args.length > 6 ? args[6] : "root";
    String pass = args.length > 7 ? args[7] : "TimechoDB@2021";
    byte[] buf = new byte[chunk];
    for (int i = 0; i < chunk; i++) {
      buf[i] = (byte) (i % 251);
    }
    long started = System.currentTimeMillis();
    try (Connection conn = DriverManager.getConnection(url, user, pass);
        Statement stmt = conn.createStatement()) {
      long off = 0;
      while (off < total) {
        int size = (int) Math.min(chunk, total - off);
        String eof = (off + size >= total) ? "true" : "false";
        StringBuilder sql = new StringBuilder(size * 2 + 256);
        sql.append("insert into ").append(table).append("(time,dev,o) values (")
            .append(ts).append(",'").append(dev).append("',to_object(").append(eof).append(',')
            .append(off).append(",X'").append(hex(buf, size)).append("'))");
        stmt.execute(sql.toString());
        off += size;
        double sec = (System.currentTimeMillis() - started) / 1000.0;
        System.out.printf("%.0f/%.0f MiB %.1f MiB/s%n", off / 1048576.0, total / 1048576.0,
            (off / 1048576.0) / Math.max(sec, 0.001));
      }
    }
    System.out.println("done " + (System.currentTimeMillis() - started) / 1000.0 + "s");
  }
}
