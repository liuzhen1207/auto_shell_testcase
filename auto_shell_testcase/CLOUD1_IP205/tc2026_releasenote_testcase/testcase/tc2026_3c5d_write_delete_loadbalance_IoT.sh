#!/bin/bash
# 3C5D / IoTConsensus: tree + table(OBJECT), background Benchmark <= 20 min.
# At minute 10: tree LOAD BALANCE -> settle -> table LOAD BALANCE -> settle.
# Then quiesce writers/deletes, wait actual syncLag=0, compare full results with
# each DN stopped in turn, restore it, scan and COPY cluster logs on every exit.
# --check: prepare private runtime configs and compile JDBC helper only.
# Original Benchmark conf directories are never modified. Normal run retains
# the original case's destructive cluster clean/deploy/start preparation.

set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
CASE_ID="3c5d_write_delete_loadbalance_IoT"
conf_dir="${cur_dir}/../conf"
conf_file="${conf_dir}/test.conf"
clean_env_dir="${cur_dir}/../clean_env"
prepare_env_dir="${cur_dir}/../prepare_env"

cn_num=3
dn_num=5
total_node_num=$((cn_num + dn_num))
schema_replication_factor="${SCHEMA_REPLICATION_FACTOR:-3}"
data_replication_factor="${DATA_REPLICATION_FACTOR:-2}"
schema_region_group_num="${SCHEMA_REGION_GROUP_NUM:-10}"
data_region_group_num="${DATA_REGION_GROUP_NUM:-20}"
DN_HEAP_MEMORY="${DN_HEAP_MEMORY:-24G}"
CLUSTER_ID=$(grep ^CLUSTER_NAME "${conf_file}" | awk -F '=' '{print $2}' | sed 's/ //g')
v_consensus="IoTConsensus"
BM_DIR="${BM_DIR:-${cur_dir}/../benchmark/bm_20260812_e158c2c_jdk17}"
BM_DIR="$(cd "$BM_DIR" && pwd)"
BM_TREE_CONF="${BM_TREE_CONF:-${BM_DIR}/conf}"
BM_TABLE_CONF="${BM_TABLE_CONF:-${BM_DIR}/conf}"
QUERY_TIMEOUT_SEC="${QUERY_TIMEOUT_SEC:-180}"
MIGRATION_TIMEOUT_SEC="${MIGRATION_TIMEOUT_SEC:-1800}"
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-300}"
CLUSTER_READY_STABLE_CHECKS="${CLUSTER_READY_STABLE_CHECKS:-3}"
DN_STOP_TIMEOUT_SEC="${DN_STOP_TIMEOUT_SEC:-${READY_TIMEOUT_SEC}}"
DN_RECOVERY_TIMEOUT_SEC="${DN_RECOVERY_TIMEOUT_SEC:-${READY_TIMEOUT_SEC}}"
DN_STATE_POLL_SEC="${DN_STATE_POLL_SEC:-30}"
DN_STATE_STABLE_CHECKS="${DN_STATE_STABLE_CHECKS:-3}"
SYNC_TIMEOUT_SEC="${SYNC_TIMEOUT_SEC:-3600}"
SYNC_STABLE_CHECKS="${SYNC_STABLE_CHECKS:-3}"
DN_METRICS_PORT="${DN_METRICS_PORT:-9091}"

os_user_name=$(awk -F= '/^os_user_name=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
testdb=$(awk -F= '/^v_testdb=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
db_parent_dir=$(awk -F= '/^v_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
cn_db_parent_dir=$(awk -F= '/^v_cn_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
shell_client_db_parent_dir=$(awk -F= '/^v_shell_client_db_parent_dir=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
case "$-" in *x*) xtrace_was_enabled=1; set +x ;; *) xtrace_was_enabled=0 ;; esac
root_pw=$(awk -F= '/^root_pw=/{gsub(/ /,"",$2);print $2}' "${conf_file}")
[ "${xtrace_was_enabled}" -eq 1 ] && set -x

db_dir="${db_parent_dir}/${testdb}"
cn_db_dir="${cn_db_parent_dir}/${testdb}"
cli_dir="${shell_client_db_parent_dir}/${testdb}"
case_tag="${testdb}_$(date +%Y%m%d_%H%M%S)_${CASE_ID}_$$"
bm_runtime_dir="${cur_dir}/${case_tag}"
case_log="${bm_runtime_dir}/case.log"
cluster_info_log="${bm_runtime_dir}/cluster_info.log"
delete_log="${bm_runtime_dir}/delete.log"
case_start_epoch=$(date +%s)
case_start_time=$(date '+%F %T')
fail_flag=0
v_warnNum=0
v_warnMessage=""
record_results=1
result_write_status=NOT_ATTEMPTED
declare -A bm_pids=()
declare -a dn_ips=() cn_ips=()
delete_pid=""
stopped_dn=""
dn_stop_confirmed=0
dn_restart_attempt=0
runtime_ready=0
cluster_touched=0

log() {
  local level=$1
  shift
  echo "[$(date '+%F %T')] [${level}] $*" | tee -a "${case_log}"
}

run_cli() {
  local restore_xtrace=0
  case "$-" in *x*) restore_xtrace=1; set +x ;; esac
  "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u root -pw "${root_pw}" "$@" </dev/null
  local rc=$?
  [ "${restore_xtrace}" -eq 1 ] && set -x
  return "${rc}"
}

require_file() {
  [ -f "$1" ] || { log ERROR "Missing required file: $1"; exit 2; }
}

set_property() {
  local node_ip=$1
  local file=$2
  local key=$3
  local value=$4
  ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
    "f='${file}'; if grep -qE '^[# ]*${key}=' \"\$f\"; then sed -i -E 's|^[# ]*${key}=.*|${key}=${value}|' \"\$f\"; else echo '${key}=${value}' >> \"\$f\"; fi"
}

set_cluster_name_on_existing_configs() {
  local node_ip=$1
  local file
  local found=0

  for file in "${cn_db_dir}/conf/iotdb-system.properties" "${db_dir}/conf/iotdb-system.properties"; do
    if ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" "test -f '${file}'"; then
      set_property "${node_ip}" "${file}" cluster_name "${CLUSTER_ID}" || return 1
      found=1
    fi
  done

  if [ "${found}" -ne 1 ]; then
    log ERROR "No iotdb-system.properties found for cluster_name on ${node_ip}"
    return 1
  fi
}

prepare_node_files() {
  require_file "${conf_dir}/confignode_${cn_num}c.txt"
  require_file "${conf_dir}/datanode_${dn_num}d.txt"
  cp -f "${conf_dir}/confignode_${cn_num}c.txt" "${conf_dir}/confignode.txt"
  cp -f "${conf_dir}/datanode_${dn_num}d.txt" "${conf_dir}/datanode.txt"
  query_ip=$(head -1 "${conf_dir}/datanode.txt" | tr -d '[:space:]')

  local actual_cn actual_dn
  actual_cn=$(grep -cvE '^[[:space:]]*(#|$)' "${conf_dir}/confignode.txt")
  actual_dn=$(grep -cvE '^[[:space:]]*(#|$)' "${conf_dir}/datanode.txt")
  if [ "${actual_cn}" -ne "${cn_num}" ] || [ "${actual_dn}" -ne "${dn_num}" ]; then
    log ERROR "Node list mismatch: expected ${cn_num}C${dn_num}D, got ${actual_cn}C${actual_dn}D"
    exit 2
  fi
  log INFO "Active topology: ${actual_cn}C${actual_dn}D, query_ip=${query_ip}"
}

ensure_version_deployed() {
  local package_zip node_ip remote_zip remote_extract target_dir node_type node_file
  package_zip=$(find "${cli_dir}" -maxdepth 1 -type f -name '*.zip' | head -1)
  [ -n "${package_zip}" ] && [ -f "${package_zip}" ] || {
    log ERROR "No release zip found under ${cli_dir}"
    return 1
  }

  for node_type in cn dn; do
    if [ "${node_type}" = "cn" ]; then
      target_dir="${cn_db_dir}"
      node_file="${conf_dir}/confignode.txt"
    else
      target_dir="${db_dir}"
      node_file="${conf_dir}/datanode.txt"
    fi

    while read -r node_ip; do
      node_ip=$(echo "${node_ip}" | tr -d '[:space:]')
      [ -z "${node_ip}" ] && continue
      if ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
        "test -f '${target_dir}/conf/iotdb-system.properties'"; then
        continue
      fi

      remote_zip="/tmp/${CASE_ID}_${testdb}.zip"
      remote_extract="/tmp/${CASE_ID}_${testdb}_extract"
      log INFO "Deploy ${testdb} to ${node_type} node ${node_ip}"
      scp -q "${package_zip}" "${os_user_name}@${node_ip}:${remote_zip}" || return 1
      ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
        "rm -rf '${remote_extract}' && mkdir -p '${remote_extract}' '${target_dir}' && (cd '${remote_extract}' && jar xf '${remote_zip}') && package_root=\$(find '${remote_extract}' -mindepth 1 -maxdepth 1 -type d | head -1) && [ -n \"\${package_root}\" ] && cp -rp \"\${package_root}/.\" '${target_dir}/' && chmod +x '${target_dir}'/sbin/*.sh && rm -rf '${target_dir}/conf_orig' && cp -rp '${target_dir}/conf' '${target_dir}/conf_orig' && rm -rf '${remote_extract}' '${remote_zip}'" || return 1
    done < "${node_file}"
  done
}

clean_cluster() {
  log INFO "Stop and clean the 3C5D cluster"
  sh -x "${clean_env_dir}/stop_cluster.sh" >> "${case_log}" 2>&1 || true
  sh -x "${clean_env_dir}/clean_cluster.sh" >> "${case_log}" 2>&1 || return 1
  sh -x "${clean_env_dir}/reset_conf.sh" >> "${case_log}" 2>&1 || return 1
}

configure_cluster() {
  local seed_cn_ip
  seed_cn_ip="$(head -1 "${conf_dir}/confignode.txt" | tr -d '[:space:]'):10710"
  log INFO "Configure ${cn_num} ConfigNodes and ${dn_num} DataNodes, seed=${seed_cn_ip}"

  while read -r node_ip; do
    node_ip=$(echo "${node_ip}" | tr -d '[:space:]')
    [ -z "${node_ip}" ] && continue
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" cn_seed_config_node "${seed_cn_ip}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" cn_internal_address "${node_ip}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" schema_replication_factor "${schema_replication_factor}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" data_replication_factor "${data_replication_factor}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" cn_metric_reporter_list "PROMETHEUS" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" schema_region_group_extension_policy CUSTOM || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" data_region_group_extension_policy CUSTOM || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" default_schema_region_group_num_per_database "${schema_region_group_num}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" default_data_region_group_num_per_database "${data_region_group_num}" || return 1
    set_property "${node_ip}" "${cn_db_dir}/conf/iotdb-system.properties" data_region_consensus_protocol_class "org.apache.iotdb.consensus.iot.${v_consensus}" || return 1
    set_cluster_name_on_existing_configs "${node_ip}" || return 1
  done < "${conf_dir}/confignode.txt"

  while read -r node_ip; do
    node_ip=$(echo "${node_ip}" | tr -d '[:space:]')
    [ -z "${node_ip}" ] && continue
    set_cluster_name_on_existing_configs "${node_ip}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_seed_config_node "${seed_cn_ip}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_internal_address "${node_ip}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_rpc_address "${node_ip}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_metric_reporter_list "PROMETHEUS" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" dn_metric_prometheus_reporter_port "${DN_METRICS_PORT}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" schema_replication_factor "${schema_replication_factor}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" data_replication_factor "${data_replication_factor}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" schema_region_group_extension_policy CUSTOM || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" data_region_group_extension_policy CUSTOM || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" default_schema_region_group_num_per_database "${schema_region_group_num}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" default_data_region_group_num_per_database "${data_region_group_num}" || return 1
    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" data_region_consensus_protocol_class "org.apache.iotdb.consensus.iot.${v_consensus}" || return 1

    set_property "${node_ip}" "${db_dir}/conf/iotdb-system.properties" lz4_use_jni false || return 1
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${node_ip}" \
      "sed -i -E 's|^[# ]*ON_HEAP_MEMORY=.*|ON_HEAP_MEMORY=\"${DN_HEAP_MEMORY}\"|; /IOTDB_JMX_OPTS=.*-XX:\\+UseParallelGC/d; /IOTDB_JMX_OPTS=.*-XX:\\+UseAdaptiveSizePolicy/a IOTDB_JMX_OPTS=\"\\\$IOTDB_JMX_OPTS -XX:+UseParallelGC\"' '${db_dir}/conf/datanode-env.sh'" || return 1
  done < "${conf_dir}/datanode.txt"
}


write_probe_source() {
  cat >"${bm_runtime_dir}/LoadBalanceProbe.java" <<'JAVA_PROBE'
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.sql.*;
import java.util.*;

/** Embedded by the shell case. JDBC failures propagate as nonzero process exits. */
public class LoadBalanceProbe {
  static Properties properties(String file) throws Exception {
    Properties p = new Properties();
    try (Reader r = Files.newBufferedReader(Path.of(file))) { p.load(r); }
    return p;
  }
  static String id(String s) { return "\"" + s.replace("\"", "\"\"") + "\""; }
  static String enc(String s) {
    return s == null ? "N" : "S" + Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
  }
  static List<String> firstColumn(Connection c, String sql) throws Exception {
    List<String> values = new ArrayList<>();
    try (Statement s = c.createStatement(); ResultSet r = s.executeQuery(sql)) {
      while (r.next()) values.add(r.getString(1));
    }
    Collections.sort(values);
    return values;
  }
  static List<String> databases(Connection c) throws Exception {
    List<String> dbs = firstColumn(c, "show databases");
    dbs.removeIf(db -> !db.startsWith("lb_table"));
    if (dbs.isEmpty()) throw new IOException("No Benchmark table database (lb_table*)");
    return dbs;
  }
  static void query(Connection c, String sql, String output) throws Exception {
    try (Statement s = c.createStatement(); BufferedWriter w = Files.newBufferedWriter(Path.of(output))) {
      s.setQueryTimeout(60);
      s.setFetchSize(1000);
      if (!s.execute(sql)) { w.write("SUCCESS\n"); return; }
      try (ResultSet r = s.getResultSet()) {
        int n = r.getMetaData().getColumnCount();
        for (int i = 1; i <= n; i++) { if (i > 1) w.write('\t'); w.write(r.getMetaData().getColumnLabel(i)); }
        w.newLine();
        while (r.next()) {
          for (int i = 1; i <= n; i++) {
            if (i > 1) w.write('\t');
            String v = r.getString(i);
            w.write(v == null ? "NULL" : v.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r"));
          }
          w.newLine();
        }
      }
    }
  }
  static long capture(Connection c, String sql, String label, List<String> lines) throws Exception {
    long count = 0;
    try (Statement s = c.createStatement()) {
      s.setFetchSize(1000); s.setQueryTimeout(120);
      try (ResultSet r = s.executeQuery(sql)) {
        ResultSetMetaData md = r.getMetaData();
        StringBuilder header = new StringBuilder("SCHEMA\t" + enc(label));
        for (int i = 1; i <= md.getColumnCount(); i++) header.append('\t').append(enc(md.getColumnLabel(i))).append(':').append(md.getColumnTypeName(i));
        lines.add(header.toString());
        while (r.next()) {
          StringBuilder row = new StringBuilder("ROW\t" + enc(label));
          for (int i = 1; i <= md.getColumnCount(); i++) {
            String type = md.getColumnTypeName(i);
            if (type.equalsIgnoreCase("BLOB") || type.equalsIgnoreCase("VARBINARY")) {
              byte[] b = r.getBytes(i);
              row.append('\t').append(b == null ? "N" : "B" + Base64.getEncoder().encodeToString(b));
            } else row.append('\t').append(enc(r.getString(i)));
          }
          lines.add(row.toString()); count++;
        }
      }
    }
    if (count == 0) throw new IOException("Empty baseline/result: " + label);
    lines.add("COUNT\t" + enc(label) + "\t" + count);
    return count;
  }
  static void snapshot(Connection c, String dialect, String output) throws Exception {
    List<String> lines = new ArrayList<>();
    long rows = 0;
    if (dialect.equals("tree")) {
      List<String> devices = firstColumn(c, "show devices root.lb_tree.**");
      if (devices.isEmpty()) throw new IOException("No tree Benchmark devices");
      for (String device : devices) rows += capture(c, "select * from " + device, device, lines);
    } else {
      int objectColumns = 0;
      long objectValues = 0;
      for (String db : databases(c)) {
        try (Statement s = c.createStatement()) { s.execute("use " + id(db)); }
        List<String> tables = firstColumn(c, "show tables");
        if (tables.isEmpty()) throw new IOException("No tables in " + db);
        for (String table : tables) {
          List<String> projection = new ArrayList<>();
          List<String> objects = new ArrayList<>();
          try (Statement s = c.createStatement(); ResultSet r = s.executeQuery("desc " + id(table))) {
            while (r.next()) {
              String col = r.getString(1), type = r.getString(2);
              lines.add("COLUMN\t" + enc(db + "." + table) + "\t" + enc(col) + "\t" + type + "\t" + r.getString(3));
              if (type.equalsIgnoreCase("OBJECT")) {
                projection.add("read_object(" + id(col) + ") as " + id(col));
                objects.add(col); objectColumns++;
              } else projection.add(id(col));
            }
          }
          if (projection.isEmpty()) throw new IOException("Missing columns: " + table);
          rows += capture(c, "select " + String.join(",", projection) + " from " + id(table), db + "." + table, lines);
          for (String col : objects) {
            try (Statement s = c.createStatement(); ResultSet r = s.executeQuery("select count(" + id(col) + ") from " + id(table))) {
              if (!r.next()) throw new IOException("Missing OBJECT count");
              objectValues += r.getLong(1);
            }
          }
        }
      }
      if (objectColumns == 0 || objectValues == 0) throw new IOException("Table workload has no non-null OBJECT data");
      lines.add("OBJECT_VALUES\t" + objectValues);
    }
    Collections.sort(lines);
    Files.write(Path.of(output), lines, StandardCharsets.UTF_8);
    System.out.println("SNAPSHOT " + dialect + " rows=" + rows + " records=" + lines.size());
  }
  static void delete(Connection c, String dialect, long cutoff) throws Exception {
    if (dialect.equals("tree")) {
      try (Statement s = c.createStatement()) { s.execute("delete from root.lb_tree.** where time <= " + cutoff); }
    } else {
      for (String db : databases(c)) {
        try (Statement s = c.createStatement()) { s.execute("use " + id(db)); }
        for (String table : firstColumn(c, "show tables")) {
          try (Statement s = c.createStatement()) { s.execute("delete from " + id(table) + " where time <= " + cutoff); }
        }
      }
    }
  }
  static void config(String[] a) throws Exception {
    Properties p = properties(a[1]);
    String dialect = a[3];
    String[][] common = {
      {"DB_SWITCH", "IoTDB-200-SESSION_BY_TABLET"}, {"IoTDB_DIALECT_MODE", dialect},
      {"HOST", a[4]}, {"PORT", a[5]}, {"USERNAME", "root"},
      {"PASSWORD", Files.readString(Path.of(a[6])).stripTrailing()},
      {"DB_NAME", "lb_" + dialect}, {"GROUP_NAME_PREFIX", dialect.equals("tree") ? "g_" : "lb_table_"},
      {"DEVICE_NAME_PREFIX", "d_"}, {"SENSOR_NAME_PREFIX", "s_"}, {"IoTDB_TABLE_NAME_PREFIX", "table_"},
      {"BENCHMARK_WORK_MODE", "testWithDefaultPath"}, {"IS_DOUBLE_WRITE", "false"},
      {"IS_COMPARISON", "false"}, {"IS_POINT_COMPARISON", "false"}, {"IS_DELETE_DATA", "false"},
      {"TEST_MAX_TIME", "1180000"}, {"LOOP", "100000000"}, {"CREATE_SCHEMA", "true"},
      {"DEVICE_NUMBER", "10"}, {"SENSOR_NUMBER", "11"}, {"GROUP_NUMBER", "1"},
      {"IoTDB_TABLE_NUMBER", "1"}, {"DATA_CLIENT_NUMBER", "1"}, {"SCHEMA_CLIENT_NUMBER", "1"},
      {"TAG_NUMBER", "0"}, {"REAL_INSERT_RATE", "1.0"}, {"IS_CLIENT_BIND", "true"},
      {"TEMPLATE", "false"}, {"VECTOR", "true"}, {"IS_SENSOR_TS_ALIGNMENT", "true"},
      {"BATCH_SIZE_PER_WRITE", "10"}, {"DEVICE_NUM_PER_WRITE", "1"},
      {"OP_MIN_INTERVAL", "10000"}, {"OP_MIN_INTERVAL_RANDOM", "false"}, {"INTERVAL_BETWEEN_WRITE_BATCH", "100"},
      {"START_TIME", "2026-01-01T00:00:00+08:00"}, {"POINT_STEP", "1000"},
      {"TIMESTAMP_PRECISION", "ms"}, {"IS_RECORD_CURRENT_REALLY_TIME", "false"}, {"IS_OUT_OF_ORDER", "false"},
      {"STRING_LENGTH", "16"}, {"OBJECT_LENGTH", "128"}, {"OBJECT_QUERY_FULL_CONTENT", "true"},
      {"INSERT_DATATYPE_PROPORTION", dialect.equals("tree") ? "1:1:1:1:1:1:1:1:1:1:0" : "1:1:1:1:1:1:1:1:1:1:1"},
      {"OPERATION_PROPORTION", "9:0:1:0:0:0:0:0:0:0:0:0:0"},
      {"QUERY_DEVICE_NUM", "1"}, {"QUERY_SENSOR_NUM", "11"}, {"IS_RECENT_QUERY", "true"},
      {"WRITE_OPERATION_TIMEOUT_MS", "60000"}, {"READ_OPERATION_TIMEOUT_MS", "10000"},
      {"TEST_DATA_PERSISTENCE", "None"}, {"CSV_OUTPUT", "true"}, {"USE_MEASUREMENT", "true"},
      {"RESULT_PRINT_INTERVAL", "60"}, {"LOG_PRINT_INTERVAL", "30"}, {"ENABLE_AUTO_FETCH", "true"}
    };
    for (String[] kv : common) p.setProperty(kv[0], kv[1]);
    try (Writer w = Files.newBufferedWriter(Path.of(a[2]))) { p.store(w, "Case runtime copy; original configuration unchanged"); }
  }
  public static void main(String[] a) throws Exception {
    if (a[0].equals("config")) { config(a); return; }
    if (a[0].equals("validate-config")) {
      System.setProperty("benchmark-conf", a[1]);
      Class<?> descriptor = Class.forName("cn.edu.tsinghua.iot.benchmark.conf.ConfigDescriptor");
      Object instance = descriptor.getMethod("getInstance").invoke(null);
      Object config = descriptor.getMethod("getConfig").invoke(instance);
      for (String name : new String[]{"getDEVICE_NUMBER", "getSENSOR_NUMBER", "getTEST_MAX_TIME"}) {
        System.out.println(name + "=" + config.getClass().getMethod(name).invoke(config));
      }
      System.out.println("BENCHMARK_CONFIG_VALID");
      return;
    }
    Properties p = properties(a[1]);
    Properties auth = new Properties();
    auth.setProperty("user", p.getProperty("USERNAME", "root"));
    auth.setProperty("password", p.getProperty("PASSWORD"));
    auth.setProperty("sql_dialect", a[3]);
    Class.forName("org.apache.iotdb.jdbc.IoTDBDriver");
    try (Connection c = DriverManager.getConnection("jdbc:iotdb://" + a[2] + ":6667/", auth)) {
      switch (a[0]) {
        case "query": query(c, a[4], a[5]); break;
        case "snapshot": snapshot(c, a[3], a[4]); break;
        case "delete": delete(c, a[3], Long.parseLong(a[4])); break;
        default: throw new IllegalArgumentException(a[0]);
      }
    }
  }
}
JAVA_PROBE
}

# Launch with bash even when an extracted archive did not preserve executable
# bits. Repair all sbin scripts for tools that invoke other scripts directly.
start_cluster() {
  local role ip dir parent kind output
  for role in cn dn; do
    if [ "$role" = cn ]; then
      nodes=("${cn_ips[@]}"); dir=$cn_db_dir; parent=$cn_db_parent_dir; kind=confignode
    else
      nodes=("${dn_ips[@]}"); dir=$db_dir; parent=$db_parent_dir; kind=datanode
    fi
    for ip in "${nodes[@]}"; do
      output="${bm_runtime_dir}/startup-${role}-${ip}.log"
      log INFO "Launch $role $ip; check permissions and JVM startup; evidence=$output"
      if ! timeout -k 2s 45s ssh -o BatchMode=yes -o ConnectTimeout=10 \
          -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "${os_user_name}@${ip}" \
          bash -s -- "$dir" "$parent" "$kind" "$case_tag" "$role" >"$output" 2>&1 <<'REMOTE_START'
source /etc/profile
dir=$1 parent=$2 kind=$3 tag=$4 role=$5
cd "$dir" || exit 1
test -f "sbin/start-${kind}.sh" || exit 1
chmod u+x sbin/*.sh || exit 1
if [ "$role" = cn ]; then
  if [ ! -f activation/license ] && [ -f "$parent/timecho_license_new" ]; then
    mkdir -p activation && cp -p "$parent/timecho_license_new" activation/license || exit 1
  fi
  if [ -f "$parent/.env" ]; then cp -p "$parent/.env" . || exit 1; fi
fi
startup_log="$dir/start_${role}_${tag}.log"
nohup bash "sbin/start-${kind}.sh" -f -H "$dir/${role}_${tag}_heapdump.hprof" >"$startup_log" 2>&1 </dev/null &
node_pid=$!
sleep 3
if ! kill -0 "$node_pid" 2>/dev/null; then
  printf 'STARTUP_FAILED role=%s pid=%s log=%s\n' "$role" "$node_pid" "$startup_log"
  tail -60 "$startup_log"
  exit 1
fi
printf 'STARTUP_ALIVE role=%s pid=%s log=%s\n' "$role" "$node_pid" "$startup_log"
REMOTE_START
      then
        tail -60 "$output" | tee -a "$case_log"
        fail "Node $role $ip startup failed; see $output"
        return 1
      fi
      tail -3 "$output" | tee -a "$case_log"
    done
  done
  log INFO "All 8 startup processes alive; polling authenticated JDBC for Running, deadline=${READY_TIMEOUT_SEC}s"
}

# Each JDBC invocation writes only result data to its output file. Exceptions and
# driver diagnostics go to the case log; an empty/failed query is never success.
probe() {
  timeout -k 5s "${QUERY_TIMEOUT_SEC}s" java -Xmx512m \
    -Dlogback.configurationFile="${bm_runtime_dir}/probe-logback.xml" \
    -cp "${bm_runtime_dir}:${BM_DIR}/lib/*" LoadBalanceProbe "$@"
}
sql() {
  local dialect=$1 statement=$2 output=$3 host=${4:-$query_ip}
  local rc
  probe query "${bm_runtime_dir}/${dialect}/conf/config.properties" "$host" "$dialect" "$statement" "$output" >"${output}.error" 2>&1; rc=$?
  cat "${output}.error" >>"${case_log}"
  last_sql_error=$(grep -m1 -E 'Exception|Error|Msg:' "${output}.error" || true)
  [ -n "$last_sql_error" ] || last_sql_error="JDBC process rc=$rc, evidence=${output}.error"
  return "$rc"
}
warn() { v_warnNum=$((v_warnNum + 1)); v_warnMessage="${v_warnMessage}${v_warnMessage:+; }$*"; log WARN "$*"; }
fail() { fail_flag=$((fail_flag + 1)); warn "$*"; }

prepare_runtime() {
  local model hosts ports source_conf key
  for key in DN_STOP_TIMEOUT_SEC DN_RECOVERY_TIMEOUT_SEC DN_STATE_POLL_SEC DN_STATE_STABLE_CHECKS CLUSTER_READY_STABLE_CHECKS; do
    if ! [[ ${!key} =~ ^[1-9][0-9]*$ ]]; then fail "$key must be a positive integer"; return 1; fi
  done
  for tool in java javac timeout setsid curl ssh sha256sum tar awk; do
    command -v "$tool" >/dev/null || { fail "Required command missing: $tool"; return 1; }
  done
  require_file "${BM_DIR}/benchmark.sh"
  require_file "${BM_DIR}/lib/core-1.0.0.jar"
  mkdir -p "${bm_runtime_dir}" || return 1
  chmod 700 "${bm_runtime_dir}"
  write_probe_source
  javac -encoding UTF-8 -d "${bm_runtime_dir}" "${bm_runtime_dir}/LoadBalanceProbe.java" >>"${case_log}" 2>&1 || return 1
  printf '%s\n' '<configuration><root level="ERROR"/></configuration>' >"${bm_runtime_dir}/probe-logback.xml"
  hosts=$(awk 'NF && $1 !~ /^#/ {gsub(/\r/, "");printf "%s%s",sep,$1;sep=","}' "${conf_dir}/datanode_5d.txt")
  ports=6667,6667,6667,6667,6667
  # The password is never expanded in xtrace or in a process argument.
  local restore_xtrace=0
  case "$-" in *x*) restore_xtrace=1; set +x ;; esac
  printf '%s' "${root_pw}" >"${bm_runtime_dir}/password"
  chmod 600 "${bm_runtime_dir}/password"
  [ "$restore_xtrace" -eq 0 ] || set -x
  for model in tree table; do
    source_conf="${BM_TREE_CONF}"
    [ "$model" != table ] || source_conf="${BM_TABLE_CONF}"
    require_file "${source_conf}/config.properties"
    mkdir -p "${bm_runtime_dir}/${model}/conf" "${bm_runtime_dir}/${model}/logs"
    cp -a "${source_conf}/." "${bm_runtime_dir}/${model}/conf/" || return 1
    sha256sum "${source_conf}/config.properties" >>"${bm_runtime_dir}/original-config.sha256"
    probe config "${source_conf}/config.properties" "${bm_runtime_dir}/${model}/conf/config.properties" "$model" "$hosts" "$ports" "${bm_runtime_dir}/password" >>"${case_log}" 2>&1 || return 1
    chmod 600 "${bm_runtime_dir}/${model}/conf/config.properties"
    probe validate-config "${bm_runtime_dir}/${model}/conf" >"${bm_runtime_dir}/${model}/config-validation.out" 2>&1 || return 1
    grep -q '^BENCHMARK_CONFIG_VALID$' "${bm_runtime_dir}/${model}/config-validation.out" || return 1
    # Private BENCHMARK_HOME gives each process isolated logs and output files.
    ln -s "${BM_DIR}/lib" "${bm_runtime_dir}/${model}/lib" || return 1
  done
  log INFO "Runtime configs created from unchanged originals; 10 devices/model, 11 sensors, OBJECT_LENGTH=128"
}

start_workloads() {
  workload_start=$(date +%s)
  for model in tree table; do
    (
      cd "${bm_runtime_dir}/${model}" || exit 1
      export BENCHMARK_HOME="${bm_runtime_dir}/${model}"
      exec setsid bash "${BM_DIR}/bin/startup.sh" -cf "${bm_runtime_dir}/${model}/conf" -heapsize 256M -maxheapsize 1G
    ) >"${bm_runtime_dir}/${model}/benchmark.out" 2>&1 &
    bm_pids[$model]=$!
  done
  log INFO "Background Benchmarks started: tree=${bm_pids[tree]}, table=${bm_pids[table]}; TEST_MAX_TIME=1180s; waiting for Benchmark completion"
  delete_data_loop & delete_pid=$!
}

delete_data_loop() {
  trap - EXIT INT TERM
  # Small progressive deletes overlap writes and balance; stop before baseline.
  local elapsed cutoff model
  sleep 60
  while [ ! -f "${bm_runtime_dir}/stop-delete" ] && [ $(( $(date +%s) - workload_start )) -lt 1190 ]; do
    elapsed=$(( $(date +%s) - workload_start ))
    cutoff=$((1767196800000 + elapsed * 100))
    for model in tree table; do
      probe delete "${bm_runtime_dir}/${model}/conf/config.properties" "$query_ip" "$model" "$cutoff" >>"${delete_log}" 2>&1 || printf '%s %s delete failed; see %s\n' "$(date '+%F %T')" "$model" "$delete_log" >>"${bm_runtime_dir}/delete.failures"
    done
    sleep 30
  done
}

wait_workloads() {
  local model rc
  for model in tree table; do
    [ -n "${bm_pids[$model]:-}" ] || continue
    wait "${bm_pids[$model]}"; rc=$?
    bm_pids[$model]=""
    printf '%s\n' "$rc" >"${bm_runtime_dir}/${model}/exit-code"
    case "$rc" in
      0) ;;
      *) warn "$model Benchmark exit code=$rc; see benchmark.out" ;;
    esac
  done
  touch "${bm_runtime_dir}/stop-delete"
  # Let an in-flight delete finish: no mutating process may outlive the baseline.
  if [ -n "$delete_pid" ]; then wait "$delete_pid" || warn "Delete worker exited abnormally"; delete_pid=""; fi
  if [ -s "${bm_runtime_dir}/delete.failures" ]; then
    fail "Concurrent delete failed $(wc -l <"${bm_runtime_dir}/delete.failures") times; see delete.failures"
  fi
}

regions_settled() {
  awk -F '\t' '
    NR==1 {for(i=1;i<=NF;i++) {if(tolower($i)=="status") s=i; if(tolower($i)=="type") t=i} next}
    {n++; if(!s || !t || $s!="Running") bad++}
    END {exit !(n>0 && s && t && !bad)}' "$1"
}

wait_migrations() {
  local model=$1 begin stable=0
  begin=$(date +%s)
  while [ $(( $(date +%s) - begin )) -lt "$MIGRATION_TIMEOUT_SEC" ]; do
    if sql "$model" 'show migrations' "${bm_runtime_dir}/${model}-migrations.tsv" &&
       sql "$model" 'show regions' "${bm_runtime_dir}/${model}-regions.tsv" &&
       [ "$(wc -l <"${bm_runtime_dir}/${model}-migrations.tsv")" -eq 1 ] &&
       grep -qi 'ProcedureId' "${bm_runtime_dir}/${model}-migrations.tsv" &&
       regions_settled "${bm_runtime_dir}/${model}-regions.tsv"; then
      stable=$((stable + 1))
      if [ "$stable" -ge 3 ]; then log INFO "$model: show migrations empty and all Region replicas Running (3 polls)"; return 0; fi
    else stable=0; fi
    sleep 10
  done
  fail "$model LOAD BALANCE completion timed out after ${MIGRATION_TIMEOUT_SEC}s (migrations/regions evidence retained)"
  return 1
}

balance_model() {
  local model=$1 submitted=1
  log INFO "Execute LOAD BALANCE in sql_dialect=$model at workload elapsed=$(( $(date +%s) - workload_start ))s"
  if ! sql "$model" 'load balance' "${bm_runtime_dir}/${model}-load-balance.tsv"; then
    fail "$model LOAD BALANCE failed: ${last_sql_error}; see ${bm_runtime_dir}/${model}-load-balance.tsv.error"
    submitted=0
  fi
  # A lost response can still have submitted procedures: always wait for settlement.
  wait_migrations "$model" || return 1
  [ "$submitted" -eq 1 ] || log WARN "$model balance request failed; cluster settled, continue table/consistency checks"
}

wait_cluster() {
  local offline=${1:-} begin remaining status limit stable=0
  begin=$(date +%s)
  while [ $(( $(date +%s) - begin )) -lt "$READY_TIMEOUT_SEC" ]; do
    remaining=$((READY_TIMEOUT_SEC - $(date +%s) + begin))
    limit=15; [ "$remaining" -ge "$limit" ] || limit=$remaining
    if QUERY_TIMEOUT_SEC="$limit" sql tree 'show cluster' "${bm_runtime_dir}/cluster.tsv" &&
      awk -F '\t' -v off="$offline" -v total="$total_node_num" '
      NR==1 {for(i=1;i<=NF;i++){k=tolower($i);if(k=="status")s=i;if(k=="internaladdress")a=i;if(k=="nodetype")t=i}next}
      {n++; if(!s||!a||!t)bad++; else if($t=="DataNode" && $a==off){seen++;if($s!="Unknown")bad++}else if($s!="Running")bad++}
      END{exit !(s&&a&&t&&n==total&&!bad&&(off==""||seen==1))}' "${bm_runtime_dir}/cluster.tsv"; then
        stable=$((stable + 1))
        log INFO "Cluster ready candidate: expected ${total_node_num} nodes, offline DN=${offline:-none}, stable=${stable}/${CLUSTER_READY_STABLE_CHECKS}"
        if [ "${stable}" -ge "${CLUSTER_READY_STABLE_CHECKS}" ]; then
          log INFO "Cluster ready: ${total_node_num} nodes all Running (stable for ${CLUSTER_READY_STABLE_CHECKS} polls), offline DN=${offline:-none}"
          return 0
        fi
    else
      stable=0
    fi
    status=$(awk -F '\t' 'NR==1{for(i=1;i<=NF;i++)if(tolower($i)=="status")s=i;next}s{n++;if($s=="Running")r++}END{printf "Running=%d/%d",r,n}' "${bm_runtime_dir}/cluster.tsv" 2>/dev/null || true)
    log INFO "Wait cluster: elapsed=$(( $(date +%s) - begin ))/${READY_TIMEOUT_SEC}s ${status}; last query: ${last_sql_error:-none}"
    remaining=$((READY_TIMEOUT_SEC - $(date +%s) + begin))
    [ "$remaining" -gt 0 ] || break
    limit=10; [ "$remaining" -ge "$limit" ] || limit=$remaining
    sleep "$limit"
  done
  fail "Cluster status timeout; expected ${total_node_num} nodes, offline DN=${offline:-none}; see cluster.tsv"
  return 1
}

wait_sync_zero() {
  local begin stable=0 ip expected all_zero sample
  begin=$(date +%s)
  while [ $(( $(date +%s) - begin )) -lt "$SYNC_TIMEOUT_SEC" ]; do
    all_zero=1
    # SHOW REGIONS is model-scoped too: include both tree and table replicas.
    for model in tree table; do
      sql "$model" 'show regions' "${bm_runtime_dir}/sync-${model}-regions.tsv" || all_zero=0
      regions_settled "${bm_runtime_dir}/sync-${model}-regions.tsv" || all_zero=0
    done
    cat "${bm_runtime_dir}/sync-tree-regions.tsv" >"${bm_runtime_dir}/sync-regions.tsv"
    tail -n +2 "${bm_runtime_dir}/sync-table-regions.tsv" >>"${bm_runtime_dir}/sync-regions.tsv"
    for ip in "${dn_ips[@]}"; do
      expected="${bm_runtime_dir}/expected-regions-${ip}.txt"
      awk -F '\t' -v ip="$ip" 'NR==1{for(i=1;i<=NF;i++){k=tolower($i);if(k=="type")t=i;if(k=="rpcaddress")a=i;if(k=="regionid")r=i}next} t&&a&&r&&$t=="DataRegion"&&$a==ip{print $r}' "${bm_runtime_dir}/sync-regions.tsv" | sort -u >"$expected"
      sample="${bm_runtime_dir}/metrics-${ip}.txt"
      if ! curl --fail --silent --show-error --max-time 10 "http://${ip}:${DN_METRICS_PORT}/metrics" >"$sample" 2>>"${case_log}"; then all_zero=0; continue; fi
      # Check every expected Region metric, not just a nonempty aggregate. Missing,
      # NaN, negative and nonzero samples all prevent synchronization success.
      if ! awk 'FILENAME==ARGV[1]{expected[$1]=1;next}
        /^iot_consensus[_{]/ && /type="syncLag"/ && /name="ioTConsensusServerImpl"/ {
          if(match($0,/region="[^"]+"/)){id=substr($0,RSTART,RLENGTH);gsub(/[^0-9]/,"",id);v=$2;
            if(id in expected){seen[id]=1;if(v !~ /^[0-9]+([.]0+)?([eE][+]?[0-9]+)?$/ || v+0!=0)bad=1}}
        } END{for(id in expected)if(!(id in seen))bad=1;exit bad}' "$expected" "$sample"; then all_zero=0; fi
    done
    # Reject absent/unknown SHOW REGIONS columns or a completely empty expected set.
    if ! cat "${bm_runtime_dir}"/expected-regions-*.txt | grep -q '[0-9]'; then all_zero=0; fi
    if [ "$all_zero" -eq 1 ]; then stable=$((stable + 1)); else stable=0; fi
    log INFO "Sync lag zero polls=${stable}/${SYNC_STABLE_CHECKS}"
    if [ "$stable" -ge "$SYNC_STABLE_CHECKS" ]; then return 0; fi
    sleep 10
  done
  fail "sync lag did not reach zero on all expected Region replicas within ${SYNC_TIMEOUT_SEC}s; see metrics files"
  return 1
}

capture_snapshot() {
  local model=$1 output=$2
  probe snapshot "${bm_runtime_dir}/${model}/conf/config.properties" "$query_ip" "$model" "$output" >>"${case_log}" 2>&1
}

# Query only the JVM belonging to this installation. Enterprise distributions use
# com.timecho.iotdb.DataNode and may have -DIOTDB_HOME=sbin/.. in /proc/cmdline.
# Return 0=present, 1=absent, 2=inspection failed (never treat SSH failure as exit).
dn_process_state() {
  local ip=$1 output=$2 rc
  timeout -k 2s 20s ssh -o BatchMode=yes -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "${os_user_name}@${ip}" \
    bash -s -- "$db_dir" >"$output" 2>"${output}.error" <<'REMOTE_DN_PROCESS'
target=$(readlink -e -- "$1") || exit 2
found=0
# The JVM's main thread may rename /proc/comm; identify the executable instead.
for proc in /proc/[0-9]*; do
  pid=${proc##*/}
  executable=$(readlink "$proc/exe" 2>/dev/null) || continue
  case "$executable" in */java|*/java\ \(deleted\)) ;; *) continue ;; esac
  args=()
  if ! { while IFS= read -r -d '' arg; do args+=("$arg"); done; } <"/proc/$pid/cmdline"; then
    [ ! -d "/proc/$pid" ] && continue
    exit 2
  fi
  is_dn=0 node_home=""
  for arg in "${args[@]}"; do
    case "$arg" in
      com.timecho.iotdb.DataNode|org.apache.iotdb.db.service.DataNode) is_dn=1 ;;
      -DIOTDB_HOME=*) node_home=${arg#-DIOTDB_HOME=} ;;
    esac
  done
  [ "$is_dn" -eq 1 ] || continue
  if ! cwd=$(readlink -e "/proc/$pid/cwd"); then
    [ ! -d "/proc/$pid" ] && continue
    exit 2
  fi
  case "$node_home" in
    /*) resolved=$(readlink -m -- "$node_home") || exit 2 ;;
    *) resolved=$(readlink -m -- "$cwd/${node_home:-.}") || exit 2 ;;
  esac
  if [ "$resolved" = "$target" ]; then
    printf 'PID=%s HOME=%s\n' "$pid" "$resolved"
    found=1
  fi
done
[ "$found" -eq 1 ]
REMOTE_DN_PROCESS
  rc=$?
  case "$rc" in 0|1) return "$rc" ;; *) return 2 ;; esac
}

dn_cluster_matches() {
  local file=$1 ip=$2 mode=$3
  awk -F '\t' -v ip="$ip" -v mode="$mode" -v total="$total_node_num" '
    NR==1 {for(i=1;i<=NF;i++){k=tolower($i);if(k=="status")s=i;if(k=="internaladdress")a=i;if(k=="nodetype")t=i}next}
    {n++;if(!s||!a||!t){bad++;next}
      if($t=="DataNode"&&$a==ip){target++;state=$s;if($s!=(mode=="offline"?"Unknown":"Running"))bad++}
      else if($s!="Running")bad++}
    END{printf "nodes=%d/%d target=%s invalid=%d\n",n,total,state,bad;exit !(s&&a&&t&&n==total&&target==1&&!bad)}' "$file"
}

# Keep the raw SHOW REGIONS result as evidence. System databases can create
# Regions during shutdown/metrics reporting and are not the workload inventory.
dn_business_regions() {
  local file=$1 model=$2 output=$3
  awk -F '\t' -v model="$model" '
    NR==1 {for(i=1;i<=NF;i++)if(tolower($i)=="database")d=i; print; next}
    d && ((model=="tree" && ($d=="root.lb_tree" || $d~/^root[.]lb_tree[.]/)) ||
          (model=="table" && $d~/^lb_table/)) {print; n++}
    END {exit !(d && n)}' "$file" >"$output"
}

dn_region_inventory() {
  awk -F '\t' '
    NR==1 {for(i=1;i<=NF;i++){k=tolower($i);if(k=="regionid")r=i;if(k=="type")t=i;if(k=="datanodeid")d=i}next}
    r&&t&&d {print $t "\t" $r "\t" $d;n++}
    END{if(!r||!t||!d||!n)exit 1}' "$1" | LC_ALL=C sort -u
}

dn_regions_match() {
  local file=$1 ip=$2 mode=$3 inventory=$4
  dn_region_inventory "$file" >"${file}.inventory" || return 1
  if ! cmp -s "$inventory" "${file}.inventory"; then
    diff -u "$inventory" "${file}.inventory" >"${file}.inventory.diff" || true
    echo "Business Region membership missing or changed; diff=${file}.inventory.diff"
    return 1
  fi
  awk -F '\t' -v ip="$ip" -v mode="$mode" '
    NR==1 {for(i=1;i<=NF;i++){k=tolower($i);if(k=="status")s=i;if(k=="internaladdress")a=i}next}
    {n++;if(!s||!a){bad++;next}if($a==ip){target++;if($s!=(mode=="offline"?"Unknown":"Running"))bad++}else if($s!="Running")bad++}
    END{printf "replicas=%d target=%d invalid=%d\n",n,target,bad;exit !(s&&a&&n&&!bad)}' "$file"
}

wait_dn_state() {
  local ip=$1 mode=$2 duration=$3 begin remaining pause stable=0 round=0
  local dir="${bm_runtime_dir}/dn-${ip}-${mode}" ok rc model proc cluster regions
  mkdir -p "$dir"
  begin=$(date +%s)
  while [ $(( $(date +%s) - begin )) -lt "$duration" ]; do
    round=$((round + 1)); ok=1; regions=""
    dn_process_state "$ip" "$dir/process.txt"; rc=$?
    case "$rc" in 0) proc=present ;; 1) proc=absent ;; *) proc=inspection_failed ;; esac
    if [ "$mode" = offline ]; then [ "$rc" -eq 1 ] || ok=0
    else [ "$rc" -eq 0 ] || ok=0; fi
    cluster=query_failed
    if QUERY_TIMEOUT_SEC=15 sql tree 'show cluster' "$dir/cluster.tsv"; then
      cluster=$(dn_cluster_matches "$dir/cluster.tsv" "$ip" "$mode") || ok=0
    else ok=0; fi
    for model in tree table; do
      if QUERY_TIMEOUT_SEC=15 sql "$model" 'show regions' "$dir/${model}-regions.tsv" &&
          dn_business_regions "$dir/${model}-regions.tsv" "$model" "$dir/${model}-regions.business.tsv"; then
        if ! dn_regions_match "$dir/${model}-regions.business.tsv" "$ip" "$mode" \
            "${bm_runtime_dir}/${model}-replica-inventory.tsv" >"$dir/${model}-region-state.txt"; then ok=0; fi
        regions="$regions $model:$(cat "$dir/${model}-region-state.txt")"
      else ok=0; regions="$regions $model:query_failed_or_no_business_regions"; fi
    done
    if [ "$ok" -eq 1 ]; then stable=$((stable + 1)); else stable=0; fi
    log INFO "DN $ip $mode elapsed=$(( $(date +%s) - begin ))/${duration}s JVM=$proc $cluster$regions stable=${stable}/${DN_STATE_STABLE_CHECKS}"
    # Keep every poll's results; final snapshots alone lose the failure timeline.
    for model in process.txt cluster.tsv tree-regions.tsv table-regions.tsv; do
      { date '+%F %T'; cat "$dir/$model" 2>/dev/null; } >>"$dir/${model}.history"
    done
    if [ "$stable" -ge "$DN_STATE_STABLE_CHECKS" ]; then
      log INFO "DN $ip $mode confirmed after $(( $(date +%s) - begin ))s; JVM, cluster and both models' Regions agree"
      return 0
    fi
    remaining=$((duration - $(date +%s) + begin))
    [ "$remaining" -gt 0 ] || break
    pause=$DN_STATE_POLL_SEC; [ "$remaining" -ge "$pause" ] || pause=$remaining
    sleep "$pause"
  done
  fail "DN $ip $mode timeout after ${duration}s: JVM=$proc $cluster$regions; see $dir"
  return 1
}

# Cleanup must be able to start a stopped DN even when a Region assertion failed.
# Only confirmed JVM absence makes it safe to launch; an SSH failure is not absence.
wait_dn_process_exit() {
  local ip=$1 duration=$2 begin remaining pause rc proc=unknown
  local output="${bm_runtime_dir}/dn-${ip}-exit-process.txt"
  begin=$(date +%s)
  while [ $(( $(date +%s) - begin )) -lt "$duration" ]; do
    dn_process_state "$ip" "$output"; rc=$?
    case "$rc" in
      0) proc=present ;;
      1) log INFO "DN $ip JVM exit confirmed; proceed with restart independently of Region assertions"; return 0 ;;
      *) proc=inspection_failed ;;
    esac
    { date '+%F %T'; cat "$output" 2>/dev/null; } >>"${output}.history"
    log INFO "Wait for DN $ip JVM exit before restart: elapsed=$(( $(date +%s) - begin ))/${duration}s JVM=$proc"
    remaining=$((duration - $(date +%s) + begin))
    [ "$remaining" -gt 0 ] || break
    pause=$DN_STATE_POLL_SEC; [ "$remaining" -ge "$pause" ] || pause=$remaining
    sleep "$pause"
  done
  fail "Cannot confirm DN $ip JVM exit within ${duration}s: JVM=$proc; restart not launched; see $output"
  return 1
}

restart_stopped_dn() {
  [ -n "$stopped_dn" ] || return 0
  local ip=$stopped_dn rc begin output
  begin=$(date +%s)
  # Region/cluster failures remain FAIL, but must not prevent cleanup restart.
  if [ "$dn_stop_confirmed" -ne 1 ]; then
    wait_dn_process_exit "$ip" "$DN_STOP_TIMEOUT_SEC" || return 1
    dn_stop_confirmed=1
  fi
  dn_process_state "$ip" "${bm_runtime_dir}/dn-${ip}-before-restart.txt"; rc=$?
  if [ "$rc" -eq 2 ]; then fail "Cannot inspect DN $ip JVM before restart"; return 1; fi
  if [ "$rc" -eq 1 ]; then
    dn_restart_attempt=$((dn_restart_attempt + 1))
    output="${bm_runtime_dir}/restart-${ip}-${dn_restart_attempt}.log"
    log INFO "Restore DataNode $ip attempt=$dn_restart_attempt; evidence=$output"
    if ! timeout -k 2s 45s ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "${os_user_name}@${ip}" \
        bash -s -- "$db_dir" "$case_tag" "$dn_restart_attempt" >"$output" 2>&1 <<'REMOTE_DN_RESTART'
source /etc/profile
dir=$1 tag=$2 attempt=$3
cd "$dir" || exit 1
startup_log="$dir/logs/${tag}_restart_${attempt}.out"
nohup bash sbin/start-datanode.sh -f >"$startup_log" 2>&1 </dev/null &
pid=$!
sleep 3
if ! kill -0 "$pid" 2>/dev/null; then
  printf 'STARTUP_FAILED pid=%s log=%s\n' "$pid" "$startup_log"
  tail -60 "$startup_log"
  exit 1
fi
printf 'STARTUP_ALIVE pid=%s log=%s\n' "$pid" "$startup_log"
REMOTE_DN_RESTART
    then
      tail -60 "$output" >>"$case_log"
      fail "DN $ip restart launcher failed; see $output"
      return 1
    fi
  else log INFO "DN $ip JVM already exists; continue checking recovery without launching another process"; fi
  wait_dn_state "$ip" recovered "$DN_RECOVERY_TIMEOUT_SEC" || return 1
  wait_sync_zero || return 1
  # Keep stopped_dn until both recovery and synchronization have succeeded, so
  # cleanup will still recover the same node and we never stop a second DN early.
  log INFO "DN $ip recovery and sync lag zero completed after $(( $(date +%s) - begin ))s"
  printf '%s\t%s\n' "$fault_start_time" "$(date '+%F %T')" >>"${bm_runtime_dir}/fault-windows.tsv"
  stopped_dn=""
  dn_stop_confirmed=0
}

verify_replicas() {
  local model ip peer output
  wait_cluster || return 1
  for model in tree table; do
    capture_snapshot "$model" "${bm_runtime_dir}/${model}-baseline.data" || { fail "$model all-online baseline failed or empty/OBJECT missing; see case log"; return 1; }
    sql "$model" 'show regions' "${bm_runtime_dir}/${model}-replica-regions.tsv" &&
      dn_business_regions "${bm_runtime_dir}/${model}-replica-regions.tsv" "$model" "${bm_runtime_dir}/${model}-replica-regions.business.tsv" &&
      regions_settled "${bm_runtime_dir}/${model}-replica-regions.business.tsv" &&
      dn_region_inventory "${bm_runtime_dir}/${model}-replica-regions.business.tsv" >"${bm_runtime_dir}/${model}-replica-inventory.tsv" || {
        fail "$model cannot capture healthy Region inventory before DN-stop checks"; return 1;
      }
  done
  for ip in "${dn_ips[@]}"; do
    # Use a live coordinator even when the original query DN is the stopped node.
    for peer in "${dn_ips[@]}"; do if [ "$peer" != "$ip" ]; then query_ip=$peer; break; fi; done
    stopped_dn=$ip
    dn_stop_confirmed=0
    fault_start_time=$(date '+%F %T')
    log INFO "Stop exactly one DN: $ip; query coordinator=$query_ip"
    if ! timeout -k 5s 90s ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${ip}" \
        "source /etc/profile; cd '${db_dir}' && bash sbin/stop-datanode.sh" >>"${case_log}" 2>&1; then
      fail "Failed to stop DN $ip"; restart_stopped_dn; return 1
    fi
    wait_dn_state "$ip" offline "$DN_STOP_TIMEOUT_SEC" || return 1
    dn_stop_confirmed=1
    for model in tree table; do
      output="${bm_runtime_dir}/${model}-without-${ip}.data"
      if ! capture_snapshot "$model" "$output"; then fail "$model query failed while DN $ip offline; see case log"
      elif ! cmp -s "${bm_runtime_dir}/${model}-baseline.data" "$output"; then
        fail "$model replica data differs from all-online baseline when DN $ip offline"
        diff -u "${bm_runtime_dir}/${model}-baseline.data" "$output" >"${output}.diff" || true
      else log INFO "$model complete result matches baseline with DN $ip offline"; fi
    done
    restart_stopped_dn || { fail "DN $ip failed to recover/synchronize; stop testing further nodes"; return 1; }
  done
}

check_benchmark_results() {
  local model file summary
  for model in tree table; do
    file="${bm_runtime_dir}/${model}/benchmark.out"
    [ -f "$file" ] || continue
    summary="${bm_runtime_dir}/${model}/failure-summary.txt"
    # Benchmark prints Operation / okOperation / okPoint / failOperation / failPoint.
    awk '
      /Operation/ && /failOperation/ {
        delete last
        fail_col=0
        for(i=1;i<=NF;i++)if($i=="failOperation")fail_col=i
        in_matrix=(fail_col>0)
        if(in_matrix)matrix_seen=1
        next
      }
      in_matrix && NF>fail_col && $1~/^[A-Z_]+$/ && $fail_col~/^[0-9]+([.][0-9]+)?$/ {
        last[$1]=$fail_col+0
        next
      }
      END {
        if(!matrix_seen){print "No Benchmark Result Matrix with failOperation column";exit}
        for(op in last)if(last[op]>0)print op " failOperation=" last[op]
      }
    ' "$file" >"$summary"
    if grep -q '^No Benchmark Result Matrix' "$summary"; then
      fail "$model Benchmark final result matrix missing; see $file"
    elif [ -s "$summary" ]; then
      fail "$model Benchmark final Result Matrix reports failed operations; see $summary"
    fi
    grep -q 'Test elapsed' "$file" || fail "$model Benchmark completion summary missing; see $file"
  done
  sha256sum -c "${bm_runtime_dir}/original-config.sha256" >>"${case_log}" 2>&1 || fail 'Original Benchmark configuration changed during test'
}

scan_and_backup_logs() {
  local role ip dir archive rc scan fatal_count error_count expected_count group_count file
  local pattern='ERROR|FATAL|Exception|OutOfMemoryError|Java heap space|GC overhead limit|DiskFull|readonly|Corrupt|Checksum|Unknown WALEntry type'
  mkdir -p "${bm_runtime_dir}/cluster-logs"
  touch "${bm_runtime_dir}/fault-windows.tsv"
  for role in cn dn; do
    if [ "$role" = cn ]; then dir=$cn_db_dir; nodes=("${cn_ips[@]}"); else dir=$db_dir; nodes=("${dn_ips[@]}"); fi
    for ip in "${nodes[@]}"; do
      archive="${bm_runtime_dir}/cluster-logs/${role}-${ip}.tar.gz"
      # Stream an archive; never move/delete the active logs directory.
      timeout -k 5s 300s ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${os_user_name}@${ip}" \
        "tar -czf - -C '${dir}' logs" >"${archive}" 2>"${archive}.stderr"; rc=$?
      if [ "$rc" -gt 1 ] || ! tar -tzf "$archive" > /dev/null 2>>"${archive}.stderr"; then
        fail "Cluster log backup failed: $role $ip rc=$rc"; continue
      fi
      [ "$rc" -ne 1 ] || warn "$role $ip logs changed while being archived; archive is readable"
      scan="${archive}.scan"
      # gz rotations are scanned as well; timestamp filtering excludes old runs.
      mkdir -p "${bm_runtime_dir}/cluster-logs/${role}-${ip}"
      tar -xzf "$archive" -C "${bm_runtime_dir}/cluster-logs/${role}-${ip}" || { fail "Log archive extraction failed: $ip"; continue; }
      : >"$scan"
      while IFS= read -r -d '' file; do
        { case "$file" in *.gz) gzip -cd "$file" ;; *) cat "$file" ;; esac; } |
          # Classify the entire event first, so stack frames cannot re-trigger
          # the generic Exception rule after its header was excluded.
          awk -v start="$case_start_time" -v pattern="$pattern" -v file="$file" '
          function flush_event(    count,lines,i,expected,severe) {
            if(!active || event=="")return
            severe=(event~/NullPointerException|IndexOutOfBoundsException|OutOfMemoryError|Java heap space|GC overhead limit|FATAL|Corrupt|Checksum|Unknown WALEntry type/)
            # Startup may attempt region extension before all DataNodes register.
            # This expected transient condition must not fail log quality gating.
            if(event~/NotEnoughDataNodeException/)return
            count=split(event,lines,"\n")
            if(!severe && event~/GroupMismatchException/) {
              print "ENVIRONMENT GroupMismatchException\t" lines[1] "\t" file ":" eventLine
              return
            }
            if(!severe && event~/Fail to read WALEntry|skip broken WALEntries/)return
            for(i=1;i<=count;i++)if(lines[i]~pattern) {
              expected=planned && lines[i]~/ConnectException|Connection refused|Connection reset|Broken pipe|TTransportException|SocketException|TimeoutException|timed out|TSocket/
              print (expected?"EXPECTED ":"UNEXPECTED ") file ":" (eventLine+i-1) ":" lines[i]
            }
          }
          FILENAME==ARGV[1]{split($0,p,"\t");starts[++n]=p[1];ends[n]=p[2];next}
          /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
            flush_event(); event=""; eventLine=FNR
            ts=substr($0,1,19);active=(ts>=start);planned=0
            for(i=1;i<=n;i++)if(ts>=starts[i]&&ts<=ends[i])planned=1
          }
          active {event=event (event==""?"":"\n") $0}
          END {flush_event()}' "${bm_runtime_dir}/fault-windows.tsv" - >>"$scan" || fail "Failed reading cluster log: $file"
      done < <(find "${bm_runtime_dir}/cluster-logs/${role}-${ip}/logs" -type f -print0)
      fatal_count=$(grep -cE 'NullPointerException|IndexOutOfBoundsException|OutOfMemoryError|Java heap space|GC overhead limit|FATAL|Corrupt|Checksum|Unknown WALEntry type' "$scan" || true)
      # Deduplicate copies of the same event in all/warn/error/startup logs.
      group_count=$(awk -F '\t' '/^ENVIRONMENT GroupMismatchException\t/{seen[$2]=1} END{for(k in seen)n++;print n+0}' "$scan")
      if [ "$group_count" -gt 0 ]; then
        warn "${role^^} $ip environment warning: GroupMismatchException=${group_count} events (does not increment fail_flag); see $scan"
      fi
      error_count=$(grep -cE '^(EXPECTED|UNEXPECTED) ' "$scan" || true)
      expected_count=$(grep -c '^EXPECTED ' "$scan" || true)
      if [ "$fatal_count" -gt 0 ]; then fail "$role $ip cluster logs contain $fatal_count fatal/NPE/OOM/corruption/WAL-recovery records; see $scan"
      elif grep -qE '^UNEXPECTED .*([[:space:]]ERROR[[:space:]]|Exception|DiskFull|readonly)' "$scan"; then fail "$role $ip cluster logs contain unexpected errors/exceptions; see $scan"
      elif [ "$error_count" -gt 0 ]; then warn "$role $ip cluster log records=$error_count, planned DN-stop connection records=$expected_count; see $scan"; fi
    done
  done
}

cleanup_local_jobs() {
  local model pid
  # Only signal process groups created by this case's setsid launcher.
  for model in tree table; do
    pid=${bm_pids[$model]:-}
    if [ -n "$pid" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      bm_pids[$model]=""
    fi
  done
  touch "${bm_runtime_dir}/stop-delete"
  if [ -n "$delete_pid" ]; then
    # Delete worker is bounded by probe timeout; wait avoids leaving a late mutation.
    wait "$delete_pid" 2>/dev/null || true; delete_pid=""
  fi
}

write_result() {
  local outcome=$1 elapsed timestamp rc
  elapsed=$(( $(date +%s) - ${workload_start:-$case_start_epoch} ))
  printf '%s' "${v_warnMessage:-No Warn.}" >"${bm_runtime_dir}/result-warning.txt"
  if [ ! -s "${bm_runtime_dir}/result-record-timestamp.txt" ]; then
    date +%s%3N >"${bm_runtime_dir}/result-record-timestamp.txt"
  fi
  timestamp=$(cat "${bm_runtime_dir}/result-record-timestamp.txt")
  write_result_recorder_source
  if ! timeout -k 2s 30s javac -encoding UTF-8 -d "${bm_runtime_dir}" \
      "${bm_runtime_dir}/LoadBalanceResultRecorder.java" >"${bm_runtime_dir}/result-write.log" 2>&1; then
    printf 'FAILED: result recorder compilation\n' >"${bm_runtime_dir}/result-write-status.txt"
    return 1
  fi
  # Credentials are read from test.conf inside Java; warnings go through a file.
  timeout -k 5s 90s java -Xmx256m -Dlogback.configurationFile="${bm_runtime_dir}/probe-logback.xml" \
    -cp "${bm_runtime_dir}:${BM_DIR}/lib/*" LoadBalanceResultRecorder write "$conf_file" \
    "$bm_runtime_dir" "$testdb" "$SCRIPT_NAME" "$v_consensus" "$outcome" "$elapsed" "$v_warnNum" "$timestamp" \
    >>"${bm_runtime_dir}/result-write.log" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAILED: result database write/readback rc=%s\n' "$rc" >"${bm_runtime_dir}/result-write-status.txt"
    return 1
  fi
  log INFO "Test result saved to IoTDB and verified; see ${bm_runtime_dir}/result-write.log"
}

finish() {
  local incoming=$? result
  trap - EXIT INT TERM
  [ "$incoming" -eq 0 ] || fail "Case aborted with exit code $incoming"
  cleanup_local_jobs
  if [ -n "$stopped_dn" ]; then restart_stopped_dn || fail "Cleanup could not restore DN $stopped_dn"; fi
  if [ "$runtime_ready" -eq 1 ]; then check_benchmark_results; fi
  if [ "$cluster_touched" -eq 1 ]; then scan_and_backup_logs; fi
  result=PASS; [ "$fail_flag" -eq 0 ] || result=FAIL
  if [ "$record_results" -eq 1 ]; then
    if write_result "$result"; then result_write_status=VERIFIED
    else
      result_write_status=FAILED
      fail "Test result database write/readback failed; see ${bm_runtime_dir}/result-write.log"
      result=FAIL
    fi
  else result_write_status=SKIPPED_CHECK; fi
  log INFO "RESULT case=${CASE_ID} status=$result fail_flag=$fail_flag v_warnMessage=$v_warnMessage"
  printf 'fail_flag=%s\nv_warnMessage=%s\nresult=%s\nwarnNum=%s\nresult_write_status=%s\n' \
    "$fail_flag" "$v_warnMessage" "$result" "$v_warnNum" "$result_write_status" >"${bm_runtime_dir}/result.txt"
  printf '%s %s.\n' "$SCRIPT_NAME" "${result,,}"
  if [ "$fail_flag" -eq 0 ]; then exit 0; else exit 1; fi
}

run_test() {
  local target remaining interval
  start_workloads
  target=$((workload_start + 600))
  while :; do
    remaining=$((target - $(date +%s)))
    [ "$remaining" -gt 0 ] || break
    interval=30
    [ "$remaining" -ge "$interval" ] || interval=$remaining
    sleep "$interval"
  done
  for model in tree table; do
    if ! kill -0 "${bm_pids[$model]}" 2>/dev/null; then warn "$model Benchmark exited before the 10-minute balance point; inspect its logs"; fi
  done
  balance_model tree || { wait_workloads; return 1; }
  balance_model table || { wait_workloads; return 1; }
  wait_workloads
  wait_cluster || return 1
  wait_sync_zero || return 1
  verify_replicas
}

main() {
  [ "${1:-}" != --check ] || record_results=0
  mkdir -p "${bm_runtime_dir}" || exit 2
  chmod 700 "${bm_runtime_dir}"
  : >"${case_log}"
  require_file "$conf_file"
  require_file "${conf_dir}/datanode_5d.txt"
  require_file "${conf_dir}/confignode_3c.txt"
  mapfile -t dn_ips < <(awk 'NF && $1 !~ /^#/ {gsub(/\r/, "");print $1}' "${conf_dir}/datanode_5d.txt")
  mapfile -t cn_ips < <(awk 'NF && $1 !~ /^#/ {gsub(/\r/, "");print $1}' "${conf_dir}/confignode_3c.txt")
  [ "${#dn_ips[@]}" -eq 5 ] && [ "${#cn_ips[@]}" -eq 3 ] || { fail 'Expected topology 3C5D'; return 1; }
  query_ip=${dn_ips[0]}
  prepare_runtime || { fail 'Runtime preflight/configuration compilation failed'; return 1; }
  runtime_ready=1
  if [ "${1:-}" = --check ]; then
    log INFO "Preflight passed; no cluster preparation, SQL, Benchmark or node stop was executed. Artifacts=$bm_runtime_dir"
    return 0
  fi
  require_file "${clean_env_dir}/clean_cluster.sh"
  [ "$data_replication_factor" -ge 2 ] || { fail 'Single-DN consistency checks require data replication >= 2'; return 1; }
  prepare_node_files
  cluster_touched=1
  if [ "${1:-}" = --resume-start ]; then
    log INFO 'Resume already prepared cluster at startup; retain data and configuration'
  else
    clean_cluster || { fail '3C5D cleanup/reset failed'; return 1; }
    ensure_version_deployed || { fail '3C5D deployment failed'; return 1; }
    configure_cluster || { fail '3C5D configuration failed'; return 1; }
  fi
  start_cluster || { fail '3C5D startup failed'; return 1; }
  wait_cluster || return 1
  run_test
}



write_result_recorder_source() {
  cat >"${bm_runtime_dir}/LoadBalanceResultRecorder.java" <<'JAVA_RECORDER'
import java.io.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.sql.*;
import java.util.*;
import java.util.regex.*;

/** Writes the same root.test fields as tc2026_March_0007, using separate result DB credentials. */
public class LoadBalanceResultRecorder {
  static final String[] FIELDS = {"testTimechoDB", "testCaseName", "testConsensus", "testResult",
      "testElapsedTimeSeconds", "maxBMTestTimeSec", "sumBMTestTimeSec", "warnNum", "testOtherMessage"};
  static Map<String, String> config(Path file) throws IOException {
    Map<String, String> values = new HashMap<>();
    for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
      line = line.trim();
      int equals = line.indexOf('=');
      if (!line.startsWith("#") && equals > 0)
        values.put(line.substring(0, equals).trim(), line.substring(equals + 1).trim());
    }
    return values;
  }
  static String required(Map<String, String> c, String key) {
    String v = c.getOrDefault(key, "");
    if (v.isEmpty()) throw new IllegalArgumentException("Missing result database config: " + key);
    return v;
  }
  static String device(Map<String, String> c) {
    String tick = String.valueOf((char) 96);
    return "root.test." + tick + required(c, "CLUSTER_NAME").replace(tick, tick + tick) + tick;
  }
  static String literal(String value) {
    // IoTDB tree string literals preserve backslashes and decode doubled quotes.
    return "'" + value.replace("'", "''") + "'";
  }
  static BigDecimal benchmarkSeconds(Path output) throws IOException {
    if (!Files.exists(output)) return BigDecimal.ZERO;
    Pattern elapsed = Pattern.compile("^Test elapsed time.*?:\\s*([0-9]+(?:\\.[0-9]+)?)\\s+second");
    BigDecimal max = BigDecimal.ZERO;
    try (BufferedReader r = Files.newBufferedReader(output)) {
      String line;
      while ((line = r.readLine()) != null) {
        Matcher match = elapsed.matcher(line);
        if (match.find()) max = max.max(new BigDecimal(match.group(1)));
      }
    }
    // These are cumulative progress summaries. Sum the two process totals, not every progress line.
    return max;
  }
  static String[] values(String[] a) throws IOException {
    if (!a[6].equals("PASS") && !a[6].equals("FAIL")) throw new IllegalArgumentException("Invalid result");
    long seconds = Long.parseLong(a[7]), warnings = Long.parseLong(a[8]);
    if (seconds < 0 || warnings < 0) throw new IllegalArgumentException("Negative result counter");
    Path runtime = Path.of(a[2]);
    BigDecimal tree = benchmarkSeconds(runtime.resolve("tree/benchmark.out"));
    BigDecimal table = benchmarkSeconds(runtime.resolve("table/benchmark.out"));
    String message = Files.readString(runtime.resolve("result-warning.txt"));
    return new String[]{a[3], a[4], a[5], a[6], Long.toString(seconds), tree.max(table).toPlainString(),
        tree.add(table).toPlainString(), Long.toString(warnings), message};
  }
  static String insertSql(String path, long timestamp, String[] values) {
    StringJoiner literals = new StringJoiner(",");
    literals.add(Long.toString(timestamp));
    for (int i = 0; i < values.length; i++) literals.add(i < 4 || i == 8 ? literal(values[i]) : values[i]);
    return "insert into " + path + "(time," + String.join(",", FIELDS) + ") values(" + literals + ")";
  }
  static Connection connect(Map<String, String> c) throws Exception {
    String host = required(c, "test_result_iotdb_ip");
    if (!host.matches("[a-zA-Z0-9._-]+")) throw new IllegalArgumentException("Invalid result database host");
    int port = Integer.parseInt(c.getOrDefault("test_result_iotdb_port", "6667"));
    if (port < 1 || port > 65535) throw new IllegalArgumentException("Invalid result database port");
    Properties auth = new Properties();
    // Read authentication from config, never put a password in shell arguments or logs.
    auth.setProperty("user", c.getOrDefault("test_result_iotdb_user", "root"));
    auth.setProperty("password", c.getOrDefault("test_result_iotdb_password", c.getOrDefault("root_pw", "root")));
    auth.setProperty("sql_dialect", "tree");
    Class.forName("org.apache.iotdb.jdbc.IoTDBDriver");
    return DriverManager.getConnection("jdbc:iotdb://" + host + ":" + port + "/", auth);
  }
  static void verify(Connection c, String path, long timestamp, String[] values) throws SQLException {
    try (Statement s = c.createStatement()) {
      s.setQueryTimeout(20);
      try (ResultSet r = s.executeQuery("select " + String.join(",", FIELDS) + " from " + path + " where time=" + timestamp)) {
        if (!r.next()) throw new SQLException("Result record missing after insert");
        for (int i = 0; i < values.length; i++) {
          String actual = r.getString(i + 2); // Tree query includes Time in column 1.
          boolean matches;
          if (i < 4 || i == 8) matches = values[i].equals(actual);
          else matches = actual != null && Math.abs(Double.parseDouble(actual) - Double.parseDouble(values[i])) < 0.01;
          if (!matches) throw new SQLException("Result readback mismatch for " + FIELDS[i]);
        }
        if (r.next()) throw new SQLException("Multiple result records at the chosen timestamp");
      }
    }
  }
  public static void main(String[] a) throws Exception {
    if (a.length < 2) throw new IllegalArgumentException("Expected check, plan or write plus config");
    Map<String, String> c = config(Path.of(a[1]));
    String path = device(c);
    if (a[0].equals("check")) {
      try (Connection conn = connect(c); Statement s = conn.createStatement()) {
        s.setQueryTimeout(20);
        try (ResultSet r = s.executeQuery("show timeseries " + path + ".*")) {
          while (r.next()) System.out.println(r.getString("Timeseries") + "\t" + r.getString("DataType"));
        }
      }
      System.out.println("RESULT_DATABASE_READ_OK " + path);
      return;
    }
    if (a.length != 10 || (!a[0].equals("plan") && !a[0].equals("write")))
      throw new IllegalArgumentException("Expected mode config runtime version case consensus status seconds warnings timestamp");
    Path runtime = Path.of(a[2]);
    long timestamp = Long.parseLong(a[9]);
    String[] values = values(a);
    String sql = insertSql(path, timestamp, values);
    Files.writeString(runtime.resolve("result-insert.sql"), sql + "\n");
    if (a[0].equals("plan")) return;
    try (Connection conn = connect(c); Statement s = conn.createStatement()) {
      s.setQueryTimeout(30);
      s.execute(sql);
      verify(conn, path, timestamp, values);
    }
    Files.writeString(runtime.resolve("result-write-status.txt"), "VERIFIED\npath=" + path + "\ntime=" + timestamp + "\n");
    System.out.println("RESULT_RECORDED path=" + path + " time=" + timestamp + " result=" + values[3]);
  }
}
JAVA_RECORDER
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  main "$@"
fi
