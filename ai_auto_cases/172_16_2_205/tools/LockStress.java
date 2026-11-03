import org.apache.iotdb.session.Session;
import org.apache.iotdb.isession.SessionDataSet;
import org.apache.iotdb.isession.SessionDataSet.DataIterator;

import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/**
 * TDB-453 复现压测器：并发查询 + 持续写入，测查询/写入 P99。
 *
 * 用法:
 *   java -cp <jar>:. LockStress setup <host> <port> <user> <pw> [devices] [rowsPerDevice]
 *   java -cp <jar>:. LockStress load  <host> <port> <user> <pw> [qThreads] [wThreads] [seconds]
 */
public class LockStress {
    static final String DB = "root.tdb453";
    static final int DEVICES = 40;

    public static void main(String[] args) throws Exception {
        String mode = args[0];
        String host = args[1];
        int port = Integer.parseInt(args[2]);
        String user = args[3];
        String pw = args[4];
        if (mode.equals("setup")) {
            int devices = args.length > 5 ? Integer.parseInt(args[5]) : DEVICES;
            int rows = args.length > 6 ? Integer.parseInt(args[6]) : 20000;
            setup(host, port, user, pw, devices, rows);
        } else if (mode.equals("load")) {
            int qt = args.length > 5 ? Integer.parseInt(args[5]) : 96;
            int wt = args.length > 6 ? Integer.parseInt(args[6]) : 8;
            int sec = args.length > 7 ? Integer.parseInt(args[7]) : 90;
            load(host, port, user, pw, qt, wt, sec);
        } else {
            System.out.println("unknown mode");
            System.exit(2);
        }
    }

    static void setup(String host, int port, String user, String pw, int devices, int rows) throws Exception {
        Session s = new Session(host, port, user, pw);
        s.open(false);
        try { s.executeNonQueryStatement("DROP DATABASE " + DB); } catch (Exception ignore) {}
        s.executeNonQueryStatement("CREATE DATABASE " + DB);
        long t0 = System.currentTimeMillis();
        int batch = 500;
        for (int d = 0; d < devices; d++) {
            for (int start = 0; start < rows; start += batch) {
                StringBuilder sb = new StringBuilder();
                sb.append("INSERT INTO ").append(DB).append(".d").append(d)
                  .append("(time,s1,s2,s3,s4) VALUES ");
                for (int i = 0; i < batch; i++) {
                    long ts = start + i;
                    if (i > 0) sb.append(',');
                    sb.append('(').append(ts).append(",1.1,2.2,3.3,4.4)");
                }
                s.executeNonQueryStatement(sb.toString());
            }
            s.executeNonQueryStatement("FLUSH");
        }
        System.out.println("SETUP_DONE devices=" + devices + " rows/device=" + rows
                + " elapsedMs=" + (System.currentTimeMillis() - t0));
        s.close();
    }

    static void load(String host, int port, String user, String pw,
                     int qThreads, int wThreads, int seconds) throws Exception {
        final List<Long> qLat = Collections.synchronizedList(new ArrayList<>());
        final List<Long> wLat = Collections.synchronizedList(new ArrayList<>());
        final AtomicInteger qErr = new AtomicInteger();
        final AtomicInteger wErr = new AtomicInteger();
        final AtomicBoolean stop = new AtomicBoolean(false);
        ExecutorService pool = Executors.newFixedThreadPool(qThreads + wThreads);

        for (int i = 0; i < qThreads; i++) {
            pool.submit(new Runnable() {
                public void run() {
                    try (Session s = new Session(host, port, user, pw)) {
                        s.open(false);
                        Random rnd = new Random();
                        while (!stop.get()) {
                            int dev = rnd.nextInt(DEVICES);
                            long st = System.nanoTime();
                            try {
                                SessionDataSet ds = s.executeQueryStatement(
                                        "SELECT s1,s2,s3,s4 FROM " + DB + ".d" + dev);
                                DataIterator it = ds.iterator();
                                while (it.next()) { }
                                ds.close();
                                qLat.add((System.nanoTime() - st) / 1000000L);
                            } catch (Exception e) {
                                if (qErr.incrementAndGet() <= 3) {
                                    System.out.println("QERR " + e.getClass().getSimpleName() + ": " + e.getMessage());
                                }
                                try { Thread.sleep(50); } catch (InterruptedException ignore) {}
                            }
                        }
                    } catch (Exception e) {
                        qErr.incrementAndGet();
                    }
                }
            });
        }

        for (int i = 0; i < wThreads; i++) {
            final int id = i;
            pool.submit(new Runnable() {
                public void run() {
                    try (Session s = new Session(host, port, user, pw)) {
                        s.open(false);
                        long seq = 0;
                        while (!stop.get()) {
                            long st = System.nanoTime();
                            try {
                                String dev = DB + ".w" + id + "_" + (seq / 1000);
                                StringBuilder sb = new StringBuilder();
                                sb.append("INSERT INTO ").append(dev).append("(time,s1,s2,s3,s4) VALUES ");
                                for (int k = 0; k < 1000; k++) {
                                    if (k > 0) sb.append(',');
                                    sb.append('(').append(seq * 1000 + k).append(",1.0,2.0,3.0,4.0)");
                                }
                                s.executeNonQueryStatement(sb.toString());
                                seq++;
                                if (seq % 5 == 0) s.executeNonQueryStatement("FLUSH");
                                wLat.add((System.nanoTime() - st) / 1000000L);
                            } catch (Exception e) {
                                if (wErr.incrementAndGet() <= 3) {
                                    System.out.println("WERR " + e.getClass().getSimpleName() + ": " + e.getMessage());
                                }
                                try { Thread.sleep(50); } catch (InterruptedException ignore) {}
                            }
                        }
                    } catch (Exception e) {
                        wErr.incrementAndGet();
                    }
                }
            });
        }

        Thread.sleep(seconds * 1000L);
        stop.set(true);
        pool.shutdown();
        pool.awaitTermination(30, TimeUnit.SECONDS);
        System.out.println(stat("QUERY", qLat, qErr.get()));
        System.out.println(stat("WRITE", wLat, wErr.get()));
    }

    static String stat(String tag, List<Long> data, int errs) {
        long[] a = new long[data.size()];
        for (int i = 0; i < a.length; i++) a[i] = data.get(i);
        Arrays.sort(a);
        if (a.length == 0) return tag + " count=0 errors=" + errs;
        return String.format("%s count=%d p50=%dms p95=%dms p99=%dms max=%dms errors=%d",
                tag, a.length, pct(a, 50), pct(a, 95), pct(a, 99), a[a.length - 1], errs);
    }

    static long pct(long[] a, int p) {
        int idx = (int) Math.ceil(a.length * p / 100.0) - 1;
        if (idx < 0) idx = 0;
        if (idx >= a.length) idx = a.length - 1;
        return a[idx];
    }
}
