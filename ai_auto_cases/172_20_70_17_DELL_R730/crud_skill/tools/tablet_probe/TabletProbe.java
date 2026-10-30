import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.apache.iotdb.session.Session;
import org.apache.tsfile.enums.TSDataType;
import org.apache.tsfile.file.metadata.IDeviceID;
import org.apache.tsfile.write.record.Tablet;
import org.apache.tsfile.write.schema.IMeasurementSchema;
import org.apache.tsfile.write.schema.MeasurementSchema;

/** 最小 Session/Tablet 探针：树模型 Tablet 写入 + 表模型 OBJECT 列写 NULL（RC5 NPE 探路）。 */
public class TabletProbe {
  public static void main(String[] args) throws Exception {
    String host = args.length > 0 ? args[0] : "127.0.0.1";
    int port = args.length > 1 ? Integer.parseInt(args[1]) : 6667;
    String user = args.length > 2 ? args[2] : "root";
    String pass = args.length > 3 ? args[3] : "TimechoDB@2021";
    String mode = args.length > 4 ? args[4] : "tree";
    String dialect = args.length > 8 ? args[8] : "tree";
    Session s = new Session.Builder().host(host).port(port).username(user).password(pass)
        .sqlDialect(dialect).build();
    s.open();
    System.out.println("SESSION_OPEN_OK");

    if (mode.equals("table")) {
      try {
        String db = args.length > 5 ? args[5] : "usr_crud_tabt";
        String tb = args.length > 6 ? args[6] : "t2";
        String tag = args.length > 7 ? args[7] : "d1";
        s.executeNonQueryStatement("use " + db);
        System.out.println("USED_DB=" + db);
        List<IDeviceID> cands = new ArrayList<>();
        try { cands.add(IDeviceID.Factory.DEFAULT_FACTORY.create(new String[] {db, tb, tag})); } catch (Throwable ignore) {}
        try { cands.add(IDeviceID.Factory.DEFAULT_FACTORY.create(db + "." + tb + "." + tag)); } catch (Throwable ignore) {}
        try { cands.add(IDeviceID.Factory.DEFAULT_FACTORY.create(new String[] {tb, tag})); } catch (Throwable ignore) {}
        try { cands.add(IDeviceID.Factory.DEFAULT_FACTORY.create(db + "." + tb + "." + tag + ".")); } catch (Throwable ignore) {}
        try { cands.add(IDeviceID.Factory.DEFAULT_FACTORY.create(new String[] {db + "." + tb, tag})); } catch (Throwable ignore) {}
        try { cands.add(IDeviceID.Factory.DEFAULT_FACTORY.create(tb + "." + tag)); } catch (Throwable ignore) {}
        for (int ci = 0; ci < cands.size(); ci++) { System.out.println("CAND[" + ci + "]=" + cands.get(ci)); }
        List<String> names = Arrays.asList("devid", "s1", "s2");
        List<TSDataType> types = Arrays.asList(TSDataType.STRING, TSDataType.INT32, TSDataType.INT32);
        boolean done = false;
        for (int ci = 0; ci < cands.size() && !done; ci++) {
          try {
            Tablet t2 = new Tablet(cands.get(ci), names, types, 3);
            for (int i = 0; i < 3; i++) {
              t2.addTimestamp(i, 1700030000000L + i * 1000L);
              t2.addValue(i, 0, tag);
              t2.addValue(i, 1, i);
              t2.addValue(i, 2, i + 1);
            }
            s.insertTablet(t2);
            done = true;
            System.out.println("TABLE_TABLET_OK form=" + ci);
          } catch (Throwable e) {
            System.out.println("TABLE_TABLET_ERR form=" + ci + ": " + e.getClass().getSimpleName() + ": " + e.getMessage());
          }
        }
      } catch (Throwable e) {
        System.out.println("TABLE_TABLET_ERR: " + e.getClass().getName() + ": " + e.getMessage());
      }
      s.close();
      System.out.println("SESSION_CLOSED");
      return;
    }
    if (mode.equals("empty")) {
      try {
        List<IMeasurementSchema> es = Arrays.asList(new MeasurementSchema("s1", TSDataType.DOUBLE));
        Tablet et = new Tablet("root.crud_probe.d3", es, 0);
        s.insertTablet(et);
        System.out.println("EMPTY_TABLET_OK");
      } catch (Throwable e) {
        System.out.println("EMPTY_TABLET_ERR: " + e.getClass().getName() + ": " + e.getMessage());
      }
      s.close();
      System.out.println("SESSION_CLOSED");
      return;
    }

    // 1) 树模型 Tablet 写入
    try {
      s.executeNonQueryStatement("CREATE DATABASE root.crud_probe");
    } catch (Exception ignore) { /* 已存在 */ }
    try {
      List<IMeasurementSchema> schema = Arrays.asList(new MeasurementSchema("s1", TSDataType.DOUBLE));
      Tablet t = new Tablet("root.crud_probe.d1", schema, 3);
      for (int i = 0; i < 3; i++) {
        t.addTimestamp(i, 1700010000000L + i * 1000L);
        t.addValue(i, 0, (double) i);
      }
      s.insertTablet(t);
      System.out.println("TREE_TABLET_OK");
    } catch (Throwable e) {
      System.out.println("TREE_TABLET_ERR: " + e.getClass().getName() + ": " + e.getMessage());
    }

    // 2) 树模型 OBJECT 列写 NULL（RC5 NPE 探路，走 Tablet 路径）
    try {
      try {
        s.executeNonQueryStatement("CREATE TIMESERIES root.crud_probe.d2.obj WITH DATATYPE=OBJECT");
      } catch (Exception ignore) { /* 已存在或自动建 */ }
      List<IMeasurementSchema> tschema = Arrays.asList(new MeasurementSchema("obj", TSDataType.OBJECT));
      Tablet tt = new Tablet("root.crud_probe.d2", tschema, 2);
      tt.addTimestamp(0, 1700020000000L);
      tt.addValue(0, 0, (byte[]) null);
      tt.addTimestamp(1, 1700020001000L);
      tt.addValue(1, 0, "abc".getBytes());
      s.insertTablet(tt);
      System.out.println("OBJECT_NULL_TABLET_OK");
    } catch (Throwable e) {
      System.out.println("OBJECT_NULL_TABLET_ERR: " + e.getClass().getName() + ": " + e.getMessage());
    }

    s.close();
    System.out.println("SESSION_CLOSED");
  }
}
