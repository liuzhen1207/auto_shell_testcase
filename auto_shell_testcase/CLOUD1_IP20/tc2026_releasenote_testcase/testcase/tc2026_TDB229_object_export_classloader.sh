#!/bin/bash
# TDB-229: OBJECT export regression for plugin ClassLoader/package conflict.
set -uo pipefail
cur_dir="$(cd "$(dirname "$0")" && pwd)"; suite_dir="$(cd "${cur_dir}/.." && pwd)"; conf_file="${suite_dir}/conf/test.conf"; SCRIPT_NAME="$(basename "$0")"
get_conf(){ awk -F= -v key="$1" '$1==key{sub(/^[^=]*=/,"");gsub(/[[:space:]]/,"");print;exit}' "${conf_file}"; }
os_user_name="$(get_conf os_user_name)"; db_user_name="$(get_conf db_user_name)"; root_pw="$(get_conf root_pw)"
testdb="$(get_conf v_testdb)"; db_parent_dir="$(get_conf v_db_parent_dir)"; cli_parent_dir="$(get_conf v_shell_client_db_parent_dir)"
db_dir="${db_parent_dir}/${testdb}"; cli_dir="${cli_parent_dir}/${testdb}"; CLUSTER_ID="$(get_conf CLUSTER_NAME)"; CLUSTER_ID="${CLUSTER_ID:-ClusterID3}"
query_ip="${QUERY_IP:-$(head -1 "${suite_dir}/conf/datanode_5d.txt"|tr -d '[:space:]')}"; result_db_ip="$(get_conf test_result_iotdb_ip)"
run_id="$(date +%Y_%m_%d_%H_%M_%S)"; result_root="${RESULT_ROOT:-${suite_dir}/result/${run_id}_tdb229}"; export_dir="${result_root}/export"
database_name="${TDB229_DATABASE:-tdb229_db}"; table_name="${TDB229_TABLE:-tdb229_object_export}"; plugin_jar="${PLUGIN_JAR:-}"; expected_rows="${EXPECTED_ROWS:-3}"
last_dn="$(awk 'NF {ip=$1} END {print ip}' "${suite_dir}/conf/datanode_5d.txt")"
SCP_HOST="${SCP_HOST:-${last_dn}}"; SCP_USER="${SCP_USER:-${os_user_name}}"; SCP_PASSWORD="${SCP_PASSWORD:-}"; SCP_REMOTE_PATH="${SCP_REMOTE_PATH:-/data1/iotdb/object_backup}"
fail_flag=0; result_written=0; pipe_name=""; plugin_was_registered=0; v_consensus="IoTConsensus"; v_warnNum=0; test_begin_sec="$(date +%s)"
mkdir -p "${result_root}" "${export_dir}"
log(){ echo "[$(date '+%F %T')] [$1] $2"|tee -a "${result_root}/testcase.log"; }; fail(){ log ERROR "$1"; fail_flag=$((fail_flag+1)); }
root_table(){ timeout "${CLI_TIMEOUT_SECONDS:-30}" "${cli_dir}/sbin/start-cli.sh" -h "${query_ip}" -u "${db_user_name}" -pw "${root_pw}" -sql_dialect table -e "$1"; }
write_result(){ [ "$result_written" -eq 0 ]||return 0; result_written=1; [ -n "${result_db_ip}" ]||return 0; local s e m o; s=PASS; [ "$fail_flag" -eq 0 ]||s=FAIL; e=$(( $(date +%s)-test_begin_sec )); m="result_dir=${result_root}"; m=$(printf '%s' "$m"|sed "s/'/''/g"); o=$(timeout "${CLI_TIMEOUT_SECONDS:-30}" "${cli_dir}/sbin/start-cli.sh" -h "${result_db_ip}" -e "insert into root.test.${CLUSTER_ID}(time,testTimechoDB,testCaseName,testConsensus,testResult,testElapsedTimeSeconds,maxBMTestTimeSec,sumBMTestTimeSec,warnNum,testOtherMessage) values(now(),'${testdb}','${SCRIPT_NAME}','${v_consensus}','${s}',${e},0,0,${v_warnNum},'${m}');" 2>&1)||{ log WARN "result write failed: ${o}"; return 0; }; echo "$o" >> "${result_root}/testcase.log"; }
backup_logs(){ local ip; while read -r ip; do ip="$(echo "$ip"|tr -d '[:space:]')"; [ -n "$ip" ]||continue; mkdir -p "${result_root}/dn_${ip}"; scp -q -o ConnectTimeout=10 "${os_user_name}@${ip}:${db_dir}/logs/datanode-all.log" "${result_root}/dn_${ip}/" 2>/dev/null||true; done < "${suite_dir}/conf/datanode_5d.txt"; }
cleanup(){
  [ -z "${pipe_name}" ] || root_table "DROP PIPE IF EXISTS ${pipe_name};" >> "${result_root}/cleanup.log" 2>&1 || true
  [ "${plugin_was_registered}" -eq 1 ] || root_table "DROP PIPEPLUGIN IF EXISTS TSFILE_REMOTE_SINK;" >> "${result_root}/cleanup.log" 2>&1 || true
  root_table "DROP TABLE IF EXISTS ${table_name}; DROP DATABASE IF EXISTS ${database_name};" >> "${result_root}/testcase.log" 2>&1||true
  backup_logs
  if [ -f "${result_root}/plugin_manifest" ]; then
    while IFS='|' read -r ip path; do
      [ -n "${ip}" ] && [ -n "${path}" ] || continue
      ssh "${os_user_name}@${ip}" "rm -f -- '${path}'" >> "${result_root}/cleanup.log" 2>&1 || true
    done < "${result_root}/plugin_manifest"
  fi
  write_result
}
trap cleanup EXIT INT TERM
log INFO "TDB-229 start: ${testdb}, ${database_name}.${table_name}"
for p in "${cli_dir}/sbin/start-cli.sh" "${cli_dir}/tools/tsfile-backup.sh" "${db_dir}/lib"; do [ -e "$p" ]||{ fail "required path missing: $p"; echo 'testcase TDB-229 fail'; exit 1; }; done
if [ -z "${plugin_jar}" ]; then
  plugin_jar_candidates=("${cur_dir}/pipe_plugin"/*tsfile-remote-sink*-jar-with-dependencies.jar)
  if [ "${#plugin_jar_candidates[@]}" -eq 1 ] && [ -f "${plugin_jar_candidates[0]}" ]; then
    plugin_jar="${plugin_jar_candidates[0]}"
  fi
fi
[ -f "$plugin_jar" ] || { fail "PLUGIN_JAR is required; expected ${cur_dir}/pipe_plugin/tsfile-remote-sink-*-jar-with-dependencies.jar"; echo 'testcase TDB-229 fail'; exit 1; }
[ -n "${SCP_HOST:-}" ] && [ -n "${SCP_USER:-}" ] && [ -n "${SCP_PASSWORD:-}" ] && [ -n "${SCP_REMOTE_PATH:-}" ] || { fail 'SCP_HOST, SCP_USER, SCP_PASSWORD and SCP_REMOTE_PATH are required'; echo 'testcase TDB-229 fail'; exit 1; }
n="$(basename "$plugin_jar")"; while read -r ip; do ip="$(echo "$ip"|tr -d '[:space:]')"; [ -n "$ip" ]||continue; target="${db_dir}/ext/pipe/${n}"; if ssh "${os_user_name}@${ip}" "test -e '${target}'"; then fail "refusing to overwrite existing plugin on ${ip}: ${target}"; continue; fi; ssh "${os_user_name}@${ip}" "mkdir -p '${db_dir}/ext/pipe'"; scp -q "$plugin_jar" "${os_user_name}@${ip}:${target}"||{ fail "plugin copy failed on $ip"; continue; }; echo "$ip|${target}" >> "${result_root}/plugin_manifest"; done < "${suite_dir}/conf/datanode_5d.txt"
lib_count=$(find "${db_dir}/lib" -maxdepth 1 -type f -iname '*tsfile*remote*sink*.jar'|wc -l|tr -d ' '); ext_count=$(find "${db_dir}/ext/pipe" -maxdepth 1 -type f -iname '*tsfile*remote*sink*.jar' 2>/dev/null|wc -l|tr -d ' '); echo "lib_plugin_count=${lib_count} ext_plugin_count=${ext_count}" >> "${result_root}/testcase.log"; [ "$lib_count" -eq 0 ]||fail 'tsfile-remote-sink jar is in DataNode lib/'
cluster_out=$(root_table "SHOW CLUSTER;" 2>&1 || true); printf '%s\n' "$cluster_out" > "${result_root}/show_cluster.out"; running_count=$(printf '%s\n' "$cluster_out" | awk -F'|' 'tolower($0)~/running/&&($0~/ConfigNode/||$0~/DataNode/){n++}END{print n+0}'); [ "$running_count" -eq 8 ] || fail "cluster is not fully Running: ${running_count}/8"
plugin_out=$(root_table "SHOW PIPEPLUGINS;" 2>&1 || true); printf '%s\n' "$plugin_out" > "${result_root}/show_pipeplugins_before.out"; printf '%s\n' "$plugin_out" | grep -qw TSFILE_REMOTE_SINK && plugin_was_registered=1
root_table "CREATE DATABASE IF NOT EXISTS ${database_name}; USE ${database_name}; CREATE TABLE IF NOT EXISTS ${table_name}(device STRING TAG,payload OBJECT FIELD); INSERT INTO ${table_name}(time,device,payload) VALUES(1,'d1',to_object(true,0,X'cafebabe01')); INSERT INTO ${table_name}(time,device,payload) VALUES(2,'d1',to_object(true,0,X'cafebabe02')); INSERT INTO ${table_name}(time,device,payload) VALUES(3,'d1',to_object(true,0,X'cafebabe03')); FLUSH;" > "${result_root}/prepare_sql.out" 2>&1||fail 'failed to prepare OBJECT data'
backup_out=$(timeout "${EXPORT_TIMEOUT_SECONDS:-300}" "${cli_dir}/tools/tsfile-backup.sh" -h "${query_ip}" -p "${TSFILE_BACKUP_PORT:-6667}" -u "${db_user_name}" -pw "${root_pw}" -sql_dialect table -db "${database_name}" -table "${table_name}" -t "${SCP_REMOTE_PATH}" -th "${SCP_HOST}" -tu "${SCP_USER}" -tpw "${SCP_PASSWORD}" -tp "${SCP_PORT:-22}" -plugin_jar "${db_dir}/ext/pipe/${n}" 2>&1); rc=$?; printf '%s\n' "$backup_out" | sed "s/${SCP_PASSWORD}/<redacted>/g" > "${result_root}/export.out"; [ "$rc" -eq 0 ]||fail "OBJECT tsfile-backup failed (rc=$rc)"
pipe_name=$(printf '%s\n' "$backup_out" | sed -n 's/^\[INFO\] Pipe name: //p' | tail -1)
[ -n "${pipe_name}" ] || fail 'tsfile-backup did not return a Pipe name'
deadline=$(( $(date +%s) + ${EXPORT_WAIT_SECONDS:-300} )); remote_listing=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  remote_listing=$(ssh "${SCP_USER}@${SCP_HOST}" "find '${SCP_REMOTE_PATH}' -type f -printf '%p %s\\n' 2>/dev/null | sort" 2>/dev/null || true)
  echo "$remote_listing" | grep -q '\.tsfile ' && echo "$remote_listing" | grep -qE '/[^ /]+\.bin ' && break
  sleep 2
done
printf '%s\n' "$remote_listing" > "${result_root}/remote_listing.out"
echo "$remote_listing" | grep -q '\.tsfile ' || fail 'no exported TsFile found on SCP target'
echo "$remote_listing" | grep -qE '(^|/)([0-9]+/)?[^ ]+\.bin ' || fail 'no exported OBJECT companion file found on SCP target'
backup_logs
if grep -RniE 'ClassCastException|NoClassDefFoundError|ClassNotFoundException|Multiple IObjectFileServiceProvider|loader constraint violation|cannot be cast to .*org\.apache\.iotdb' "${result_root}"/dn_* "${result_root}/export.out" 2>/dev/null > "${result_root}/classloader_errors.log"; then fail 'ClassLoader/Object service error found'; fi
if [ "$fail_flag" -gt 0 ]; then log ERROR "TDB-229 failed"; echo 'testcase TDB-229 fail'; exit 1; fi
log INFO 'TDB-229 passed'; echo 'testcase TDB-229 pass'; exit 0
