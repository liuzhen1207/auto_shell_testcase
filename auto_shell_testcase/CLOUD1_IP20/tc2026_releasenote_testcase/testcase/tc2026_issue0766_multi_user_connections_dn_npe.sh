#!/bin/bash
# TIMECHODB-0766 / V2-340
# Original Python topology: one 50-thread executor creates 1000 unique-user TableSessions,
# distributed evenly across four DataNodes (250 users per DN). Every client runs
# SHOW DATABASES and SELECT * FROM information_schema.connections, then remains connected.

set -uo pipefail

cur_dir="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
suite_dir="$(cd "${cur_dir}/.." && pwd)"
conf_file="${suite_dir}/conf/test.conf"
nodeinfo_dir="${suite_dir}/conf"
clean_env_dir="${suite_dir}/clean_env"
prepare_env_dir="${suite_dir}/prepare_env"

get_conf() {
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit}' "${conf_file}"
}

os_user_name="$(get_conf os_user_name)"
db_user_name="$(get_conf db_user_name)"
root_pw="$(get_conf root_pw)"
testdb="$(get_conf v_testdb)"
db_parent_dir="$(get_conf v_db_parent_dir)"
cn_db_parent_dir="$(get_conf v_cn_db_parent_dir)"
cli_parent_dir="$(get_conf v_shell_client_db_parent_dir)"
cli_dir="${cli_parent_dir}/${testdb}"
db_dir="${db_parent_dir}/${testdb}"
cn_db_dir="${cn_db_parent_dir}/${testdb}"
CLUSTER_ID="$(get_conf CLUSTER_NAME)"
CLUSTER_ID="${CLUSTER_ID:-ClusterID3}"
cn_file="${nodeinfo_dir}/confignode_3c.txt"
dn_file="${nodeinfo_dir}/datanode_5d.txt"
query_ip="${QUERY_IP:-$(head -1 "${dn_file}" | tr -d '[:space:]')}"

bm_dir="${BM_DIR:-/data2/benchmark/bm_20251017_b6be9bd_ssl}"
run_id="$(date +%Y_%m_%d_%H_%M_%S)"
short_id="$(date +%H%M%S)"
result_dir="${bm_dir}/${testdb}/${run_id}_issue0766"
log_file="${result_dir}/testcase.log"
baseline_file="${result_dir}/dn_npe.baseline"
worker_pid_file="${result_dir}/worker.pids"
java_src="${result_dir}/Issue0766Client.java"
java_classes="${result_dir}/classes"
user_prefix="v2340u${short_id}_"
user_password="${USER_PASSWORD:-TimechoDB@2021}"
user_count="${USER_COUNT:-1000}"
users_per_dn="${USERS_PER_DN:-250}"
hold_seconds="${HOLD_SECONDS:-3600}"
open_timeout_seconds="${OPEN_TIMEOUT_SECONDS:-90}"
concurrent_threads="${CONCURRENT_THREADS:-50}"
cli_timeout_seconds="${CLI_TIMEOUT_SECONDS:-45}"
target_pattern='Internal error processing openSession|Cannot invoke .*User.getMaxSessionPerUser.* because .* is null'
fail_flag=0
result_written=0
result_write_succeeded=0
node_logs_backed_up=0
users_created=0
cluster_pid=""
lock_dir="/tmp/tc2026_issue0766_connections_dn_npe.lock"
test_begin_sec="$(date +%s)"
v_consensus="IoTConsensus"
v_warnNum=0
v_warnMessage="result_dir=${result_dir}"

mkdir -p "${result_dir}" "${java_classes}"
: > "${baseline_file}"
: > "${worker_pid_file}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "${log_file}"; }
fail() { log ERROR "$1"; fail_flag=$((fail_flag + 1)); }

cli_table() {
  timeout "${cli_timeout_seconds}" "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" \
    -u "${db_user_name}" -pw "${root_pw}" -timeout 3600 -sql_dialect table -e "$1"
}

write_result() {
  local result_ip status elapsed safe_message output
  [ "${result_written}" -eq 0 ] || return 0
  result_written=1
  result_ip="$(get_conf test_result_iotdb_ip)"
  [ -n "${result_ip}" ] || { log WARN "test_result_iotdb_ip is empty; keep evidence"; return 0; }
  status=PASS; [ "${fail_flag}" -eq 0 ] || status=FAIL
  elapsed=$(($(date +%s) - test_begin_sec))
  safe_message=$(printf '%s' "${v_warnMessage}" | sed "s/'/''/g")
  output=$(timeout "${cli_timeout_seconds}" "${cli_dir}/sbin/start-cli.sh" -h "${result_ip}" \
    -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage) values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','${status}',${elapsed},0,0,${v_warnNum},'${safe_message}');" 2>&1) || {
      log WARN "Failed to write ${status} result: ${output}"
      return 0
    }
  echo "${output}" >> "${log_file}"
  result_write_succeeded=1
  log INFO "Recorded ${status} result in root.test.${CLUSTER_ID} at ${result_ip}"
}

prepare_cluster_environment() {
  local ip seed_cn cluster_name prepare_log
  seed_cn="$(head -1 "${cn_file}" | tr -d '[:space:]'):10710"
  cluster_name="${CLUSTER_ID}"
  prepare_log="${result_dir}/prepare_cluster.log"
  log INFO "Preparing clean 3C5D cluster for TIMECHODB-0766"
  for script in stop_cluster.sh clean_cluster.sh reset_conf.sh clear_cache.sh; do
    [ -f "${clean_env_dir}/${script}" ] || { fail "Missing ${script}"; return 1; }
    sh "${clean_env_dir}/${script}" >> "${prepare_log}" 2>&1 || { fail "${script} failed"; return 1; }
  done
  # clean_env/reset_conf may recreate the node lists; copy them only after
  # cleanup so the subsequent configuration is applied to the final topology.
  cp -p "${cn_file}" "${nodeinfo_dir}/confignode.txt"
  cp -p "${dn_file}" "${nodeinfo_dir}/datanode.txt"

  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" bash -s -- "${cn_db_dir}" "${seed_cn}" "${ip}" "${cluster_name}" <<'REMOTE_CN' >> "${prepare_log}" 2>&1
set -eu
db=$1; seed=$2; ip=$3; cluster=$4; p="${db}/conf/iotdb-system.properties"; e="${db}/conf/confignode-env.sh"
sp(){ sed -i -E "/^[#[:space:]]*$1=/d" "$p"; printf '%s=%s\n' "$1" "$2" >> "$p"; }
sed -i -E '/^[#[:space:]]*ON_HEAP_MEMORY=/d; /^[#[:space:]]*OFF_HEAP_MEMORY=/d' "$e"
printf '%s\n' 'ON_HEAP_MEMORY="2G"' 'OFF_HEAP_MEMORY="1G"' >> "$e"
sp cn_seed_config_node "$seed"; sp cn_internal_address "$ip"; sp cn_metric_reporter_list PROMETHEUS
sp cn_metric_prometheus_reporter_port 9081; sp schema_replication_factor 3; sp data_replication_factor 2
sp data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
sp enable_auto_repair_compaction false; sp schema_region_group_extension_policy CUSTOM
sp default_schema_region_group_num_per_database 2; sp data_region_group_extension_policy CUSTOM
sp default_data_region_group_num_per_database 6; sp cluster_name "$cluster"
REMOTE_CN
    [ "$?" -eq 0 ] || { fail "Configure CN ${ip} failed"; return 1; }
  done < "${cn_file}"
  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "sed -i -E '/^[#[:space:]]*(cn_seed_config_node|cn_internal_address|cluster_name)=/d' '${cn_db_dir}/conf/iotdb-system.properties'; printf '%s\\n' 'cn_seed_config_node=${seed_cn}' 'cn_internal_address=${ip}' 'cluster_name=${cluster_name}' >> '${cn_db_dir}/conf/iotdb-system.properties'" || {
        fail "Direct CN ${ip} address write failed"; return 1;
      }
  done < "${cn_file}"
  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "grep -q '^cn_internal_address=${ip}$' '${cn_db_dir}/conf/iotdb-system.properties' && grep -q '^cn_seed_config_node=${seed_cn}$' '${cn_db_dir}/conf/iotdb-system.properties' && grep -q '^cluster_name=${cluster_name}$' '${cn_db_dir}/conf/iotdb-system.properties'" || {
        fail "CN ${ip} address/seed configuration was not applied"; return 1;
      }
  done < "${cn_file}"

  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" bash -s -- "${db_dir}" "${seed_cn}" "${ip}" "${cluster_name}" "${testdb}" <<'REMOTE_DN' >> "${prepare_log}" 2>&1
set -eu
db=$1; seed=$2; ip=$3; cluster=$4; testdb=$5; p="${db}/conf/iotdb-system.properties"; e="${db}/conf/datanode-env.sh"
sp(){ sed -i -E "/^[#[:space:]]*$1=/d" "$p"; printf '%s=%s\n' "$1" "$2" >> "$p"; }
sed -i -E '/^[#[:space:]]*ON_HEAP_MEMORY=/d; /^[#[:space:]]*OFF_HEAP_MEMORY=/d' "$e"
printf '%s\n' 'ON_HEAP_MEMORY="20G"' 'OFF_HEAP_MEMORY="4G"' >> "$e"
sp dn_seed_config_node "$seed"; sp dn_internal_address "$ip"; sp dn_rpc_address "$ip"
sp dn_metric_reporter_list PROMETHEUS; sp dn_metric_prometheus_reporter_port 9091
sp schema_replication_factor 3; sp data_replication_factor 2
sp data_region_consensus_protocol_class org.apache.iotdb.consensus.iot.IoTConsensus
sp enable_auto_repair_compaction false; sp schema_region_group_extension_policy CUSTOM
sp default_schema_region_group_num_per_database 2; sp data_region_group_extension_policy CUSTOM
sp default_data_region_group_num_per_database 6
sp dn_data_dirs "data/datanode/data,/data1/iotdb_data/${testdb}/data/datanode/data,/data3/iotdb_data/${testdb}/data/datanode/data"
sp dn_wal_dirs "data/datanode/wal,/data1/iotdb_data/${testdb}/data/datanode/wal,/data3/iotdb_data/${testdb}/data/datanode/wal"
sp load_active_listening_dirs "ext/load/pending,/data1/iotdb_data/${testdb}/ext/load/pending,/data3/iotdb_data/${testdb}/ext/load/pending"
sp cluster_name "$cluster"
REMOTE_DN
    [ "$?" -eq 0 ] || { fail "Configure DN ${ip} failed"; return 1; }
  done < "${dn_file}"
  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "sed -i -E '/^[#[:space:]]*(dn_seed_config_node|dn_internal_address|dn_rpc_address|cluster_name)=/d' '${db_dir}/conf/iotdb-system.properties'; printf '%s\\n' 'dn_seed_config_node=${seed_cn}' 'dn_internal_address=${ip}' 'dn_rpc_address=${ip}' 'cluster_name=${cluster_name}' >> '${db_dir}/conf/iotdb-system.properties'" || {
        fail "Direct DN ${ip} address write failed"; return 1;
      }
  done < "${dn_file}"
  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
    ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" \
      "grep -q '^dn_internal_address=${ip}$' '${db_dir}/conf/iotdb-system.properties' && grep -q '^dn_rpc_address=${ip}$' '${db_dir}/conf/iotdb-system.properties' && grep -q '^dn_seed_config_node=${seed_cn}$' '${db_dir}/conf/iotdb-system.properties' && grep -q '^cluster_name=${cluster_name}$' '${db_dir}/conf/iotdb-system.properties'" || {
        fail "DN ${ip} address/seed configuration was not applied"; return 1;
      }
  done < "${dn_file}"
  # start_cluster_v20 waits for all nodes; bound it so a partial startup cannot
  # leave this testcase (or its child processes) running indefinitely.
  setsid sh -c 'exec timeout --signal=TERM --kill-after=20 900 sh "$1" 1 8' _ \
    "${prepare_env_dir}/start_cluster_v20.sh" >> "${prepare_log}" 2>&1 &
  cluster_pid=$!
  if ! wait "${cluster_pid}"; then
    # setsid makes cluster_pid the process-group id; reap the whole group,
    # including start_cluster_v20 descendants, before reporting the failure.
    kill -- -"${cluster_pid}" 2>/dev/null || kill "${cluster_pid}" 2>/dev/null || true
    cluster_pid=""
    fail "Cluster start failed or timed out; see ${prepare_log}"
    return 1
  fi
  cluster_pid=""
}

record_dn_baseline() {
  local ip count
  while read -r ip; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
    count=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" "grep -hEi '${target_pattern}' '${db_dir}'/logs/log_datanode_all.log 2>/dev/null | wc -l" || echo 0)
    echo "${ip}|${count}" >> "${baseline_file}"
  done < "${dn_file}"
}

check_new_dn_npe() {
  local ip baseline current evidence found=0
  while IFS='|' read -r ip baseline; do
    current=$(ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" "grep -hEi '${target_pattern}' '${db_dir}'/logs/log_datanode_all.log 2>/dev/null | wc -l" || echo 0)
    if [ "${current:-0}" -gt "${baseline:-0}" ]; then
      evidence="${result_dir}/dn_${ip}_new_npe.log"
      ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" "grep -hEin -A18 -B3 '${target_pattern}' '${db_dir}'/logs/log_datanode_all.log 2>/dev/null | tail -300" > "${evidence}" 2>&1 || true
      log ERROR "New DataNode openSession NPE on ${ip}: baseline=${baseline}, current=${current}, evidence=${evidence}"
      v_warnNum=$((v_warnNum + 1))
      v_warnMessage="${v_warnMessage}; DN ${ip} NPE: Cannot invoke User.getMaxSessionPerUser() because user is null (count=$((current - baseline)))"
      found=1
    fi
  done < "${baseline_file}"
  [ "${found}" -eq 0 ] || { fail_flag=$((fail_flag + 1)); return 1; }
}

create_users() {
  local i=1 batch="" batch_count=0 output
  log INFO "Creating ${user_count} independent users"
  users_created=1
  while [ "${i}" -le "${user_count}" ]; do
    batch="${batch} create user ${user_prefix}${i} '${user_password}'; grant system to user ${user_prefix}${i};"
    batch_count=$((batch_count + 1))
    if [ "${batch_count}" -eq 25 ] || [ "${i}" -eq "${user_count}" ]; then
      output=$(cli_table "${batch}" 2>&1) || { echo "${output}" >> "${result_dir}/create_users.log"; fail "Failed creating users near index ${i}"; return 1; }
      echo "${output}" >> "${result_dir}/create_users.log"
      batch=""; batch_count=0
    fi
    i=$((i + 1))
  done
}

drop_users() {
  local i=1 batch="" batch_count=0
  [ "${users_created}" -eq 1 ] || return 0
  log INFO "Dropping temporary TIMECHODB-0766 users"
  while [ "${i}" -le "${user_count}" ]; do
    batch="${batch} drop user ${user_prefix}${i};"
    batch_count=$((batch_count + 1))
    if [ "${batch_count}" -eq 25 ] || [ "${i}" -eq "${user_count}" ]; then
      cli_table "${batch}" >> "${result_dir}/drop_users.log" 2>&1 || true
      batch=""; batch_count=0
    fi
    i=$((i + 1))
  done
  users_created=0
}

write_java_driver() {
  cat > "${java_src}" <<'JAVA'
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.apache.iotdb.isession.ITableSession;
import org.apache.iotdb.isession.SessionDataSet;
import org.apache.iotdb.session.TableSessionBuilder;

public class Issue0766Client {
  public static void main(String[] args) throws Exception {
    String[] hosts=args[0].split(",");
    String prefix=args[1], password=args[2];
    int total=Integer.parseInt(args[3]), perNode=Integer.parseInt(args[4]);
    int threads=Integer.parseInt(args[5]), hold=Integer.parseInt(args[6]);
    int timeout=Integer.parseInt(args[7]);
    ExecutorService pool=Executors.newFixedThreadPool(threads);
    AtomicInteger opened=new AtomicInteger(), failed=new AtomicInteger();
    List<ITableSession> sessions=java.util.Collections.synchronizedList(new ArrayList<>());
    for (int i=1; i<=total; i++) {
      final int id=i;
      final String host=hosts[Math.min((id-1)/perNode, hosts.length-1)];
      pool.submit(() -> {
        ITableSession session=null;
        try {
          session=new TableSessionBuilder()
            .nodeUrls(java.util.Collections.singletonList(host+":6667"))
            .username(prefix+id).password(password)
            .connectionTimeoutInMs(timeout*1000).build();
          SessionDataSet validation=session.executeQueryStatement("show databases");
          while (validation.hasNext()) validation.next();
          SessionDataSet connections=session.executeQueryStatement(
            "SELECT * FROM information_schema.connections");
          while (connections.hasNext()) connections.next();
          sessions.add(session); opened.incrementAndGet();
          System.out.println("CLIENT_OK id="+id+" user="+prefix+id+" node="+host);
        } catch (Throwable t) {
          failed.incrementAndGet();
          System.err.println("OPEN_FAILED user="+prefix+id+" host="+host+" error="+t);
          if (session != null) try { session.close(); } catch (Throwable ignored) {}
        }
      });
    }
    pool.shutdown();
    pool.awaitTermination(Math.max(600L, total * timeout), TimeUnit.SECONDS);
    Thread.sleep(10_000L);
    System.out.println("OPEN_SUMMARY requested="+total+" opened="+opened+" failed="+failed);
    System.out.println("Holding active TableSessions for seconds="+hold);
    Thread.sleep(hold * 1000L);
    for (ITableSession s: sessions) try { s.close(); } catch (Throwable ignored) {}
    System.exit(failed.get()==0 ? 0 : 2);
  }
}
JAVA
  javac -cp "${cli_dir}/lib/*" -d "${java_classes}" "${java_src}" >> "${result_dir}/javac.log" 2>&1 || {
    fail "Failed compiling Java Session driver; see ${result_dir}/javac.log"; return 1;
  }
}

start_workers() {
  local ip hosts="" count=0
  while read -r ip && [ "${count}" -lt 4 ]; do
    ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
    hosts="${hosts}${hosts:+,}${ip}"; count=$((count + 1))
  done < "${dn_file}"
  [ "${count}" -eq 4 ] || { fail "Need four DataNodes for original issue topology"; return 1; }
  java -Xms256m -Xmx1g -cp "${java_classes}:${cli_dir}/lib/*" Issue0766Client \
    "${hosts}" "${user_prefix}" "${user_password}" "${user_count}" "${users_per_dn}" \
    "${concurrent_threads}" "${hold_seconds}" "${open_timeout_seconds}" \
    > "${result_dir}/table_session_clients.log" 2>&1 &
  echo "$!" >> "${worker_pid_file}"
}

wait_workers() {
  local pid rc=0 summary opened total=0
  while read -r pid; do wait "${pid}" || rc=1; done < "${worker_pid_file}"
  summary=$(grep -h 'OPEN_SUMMARY' "${result_dir}/table_session_clients.log" 2>/dev/null || true)
  opened=$(echo "${summary}" | sed -n 's/.* opened=\([0-9][0-9]*\).*/\1/p')
  total=${opened:-0}
  log INFO "Java workers opened ${total}/${user_count} unique-user sessions"
  [ "${total}" -ge $((user_count * 9 / 10)) ] || fail "Insufficient successful sessions: ${total}/${user_count}"
  [ "${rc}" -eq 0 ] || log WARN "At least one worker reported openSession failures; inspect worker logs"
}

stop_workers() {
  local pid
  [ -f "${worker_pid_file}" ] || return 0
  while read -r pid; do [ -n "${pid}" ] && kill "${pid}" 2>/dev/null || true; done < "${worker_pid_file}"
}

backup_node_logs() {
  local role ip remote_dir node_file archive
  [ "${node_logs_backed_up}" -eq 0 ] || return 0; node_logs_backed_up=1
  mkdir -p "${result_dir}/node_logs"
  for role in cn dn; do
    if [ "${role}" = cn ]; then remote_dir="${cn_db_dir}"; node_file="${cn_file}"; else remote_dir="${db_dir}"; node_file="${dn_file}"; fi
    while read -r ip; do
      ip="$(echo "${ip}" | tr -d '[:space:]')"; [ -n "${ip}" ] || continue
      archive="${result_dir}/node_logs/${role}_${ip}_logs.tar.gz"
      ssh -n -o ConnectTimeout=10 "${os_user_name}@${ip}" "tar -C '${remote_dir}' -czf - logs" > "${archive}" || { rm -f "${archive}"; log WARN "Failed backing up ${role} logs from ${ip}"; }
    done < "${node_file}"
  done
}

if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Another TIMECHODB-0766 run is already active: ${lock_dir}" >&2
  exit 2
fi
cleanup() {
  stop_workers
  if [ -n "${cluster_pid}" ] && kill -0 "${cluster_pid}" 2>/dev/null; then
    kill -- -"${cluster_pid}" 2>/dev/null || kill "${cluster_pid}" 2>/dev/null || true
  fi
  backup_node_logs || true
  drop_users || true
  rmdir "${lock_dir}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log INFO "TIMECHODB-0766 start: ${user_count} TableSessions, ${concurrent_threads} threads, four DNs x ${users_per_dn}, hold=${hold_seconds}s"
for f in "${cli_dir}/sbin/start-cli.sh" "${cli_dir}/lib"; do
  [ -e "${f}" ] || { fail "Required file missing: ${f}"; write_result; exit 1; }
done
[ "${user_count}" -eq $((users_per_dn * 4)) ] || { fail "USER_COUNT must equal USERS_PER_DN*4"; write_result; exit 1; }

prepare_cluster_environment || { write_result; echo "testcase TIMECHODB-0766 fail"; exit 1; }
cluster_output=$(cli_table "show cluster;" 2>&1 || true)
echo "${cluster_output}" > "${result_dir}/show_cluster_before.log"
running_count=$(echo "${cluster_output}" | awk -F'|' 'tolower($0) ~ /running/ && ($0 ~ /ConfigNode/ || $0 ~ /DataNode/) {n++} END{print n+0}')
[ "${running_count}" -eq 8 ] || { fail "Cluster is not fully Running: ${running_count}/8"; write_result; exit 1; }

record_dn_baseline
create_users || { write_result; echo "testcase TIMECHODB-0766 fail"; exit 1; }
write_java_driver || { write_result; echo "testcase TIMECHODB-0766 fail"; exit 1; }
start_workers || { write_result; echo "testcase TIMECHODB-0766 fail"; exit 1; }
wait_workers
check_new_dn_npe || true
cli_table "show cluster; select count(*) from information_schema.connections;" > "${result_dir}/final_health.log" 2>&1 || fail "Final health check failed"

if [ "${fail_flag}" -gt 0 ]; then
  log ERROR "TIMECHODB-0766 failed with fail_flag=${fail_flag}; result_dir=${result_dir}"
  write_result; echo "testcase TIMECHODB-0766 fail"; exit 1
fi
log INFO "TIMECHODB-0766 completed without target DataNode openSession NPE; result_dir=${result_dir}"
write_result; echo "testcase TIMECHODB-0766 pass"; exit 0
