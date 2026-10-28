#!/usr/bin/env bash
set -uo pipefail

cur_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"
suite_dir="${cur_dir}/iotdb_snapshot_closing_regression"
runtime="${1:-}"
if [[ -z "$runtime" && -f "$conf_file" ]]; then
  parent=$(awk -F= '$1=="v_shell_client_db_parent_dir" {gsub(/[[:space:]]/,"",$2); print $2}' "$conf_file")
  version=$(awk -F= '$1=="v_testdb" {gsub(/[[:space:]]/,"",$2); print $2}' "$conf_file")
  runtime="${parent}/${version}"
fi
if [[ -z "$runtime" ]]; then
  echo "Usage: $0 [RUNTIME_HOME] [OUTPUT_DIR]" >&2
  printf '[%s] [INFO] RESULT fail_flag=1 msg=usage_or_runtime_argument_missing\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  exit 2
fi
runtime=$(realpath -e -- "$runtime") || { echo "Runtime not found: $runtime" >&2; printf '[%s] [INFO] RESULT fail_flag=1 msg=runtime_not_found\n' "$(date '+%Y-%m-%d %H:%M:%S')"; exit 2; }
if [[ $# -ge 2 ]]; then
  out=$(realpath -m -- "$2")
else
  out="${cur_dir}/tc2026_September_Migrate_0001_snapshot_closing_f1_f2_$(date +%Y%m%d_%H%M%S)"
fi
if [[ -e "$out" ]]; then
  echo "Refusing to reuse output directory: $out" >&2
  printf '[%s] [INFO] RESULT fail_flag=1 msg=output_directory_already_exists\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  exit 2
fi

set +e
bash "$suite_dir/run.sh" "$runtime" "$out" all
run_rc=$?
set -e
if [[ $run_rc -ne 0 ]]; then
  echo "ERROR: snapshot closing harness failed to execute (rc=$run_rc)"
  printf '[%s] [INFO] RESULT fail_flag=1 msg=harness_failed_rc_%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$run_rc"
  exit "$run_rc"
fi

python_bin="${PYTHON_BIN:-}"
if [[ -z "$python_bin" ]]; then
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
      python_bin="$(command -v "$candidate")"
      break
    fi
  done
fi
if [[ -n "$python_bin" ]]; then
  set +e
  "$python_bin" "$suite_dir/audit_regression.py" "$out"
  audit_rc=$?
  set -e
else
  echo "INFO: Python 3 is unavailable; using Java-result fallback audit"
  audit_rc=0
  source_count=0
  for source in "$out"/*-source; do
    [[ -d "$source" ]] || continue
    source_count=$((source_count + 1))
    case_name=$(basename "$source" -source)
    result="$source/result.json"
    race_result="$out/${case_name}-restored-race/result.json"
    control_result="$out/${case_name}-restored-control/result.json"
    if ! grep -Eq '"harnessAssertionsPassed"[[:space:]]*:[[:space:]]*true' "$result" "$race_result" "$control_result"; then
      echo "FAIL $case_name: harness or restore assertion failed"
      audit_rc=1
    elif ! grep -Eq '"integrityPassed"[[:space:]]*:[[:space:]]*true' "$result"; then
      missing=$(sed -n 's/.*"missingRows"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$result" | head -1)
      race_rows=$(sed -n 's/.*"raceRows"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$result" | head -1)
      source_rows=$(sed -n 's/.*"sourceRows"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$result" | head -1)
      echo "FAIL $case_name: race snapshot omitted ${missing:-unknown} rows (race=${race_rows:-unknown}, source=${source_rows:-unknown})"
      audit_rc=1
    else
      echo "PASS $case_name: race snapshot contains all rows"
    fi
  done
  if [[ $source_count -ne 4 ]]; then
    echo "FAIL: expected four scenarios, found $source_count"
    audit_rc=1
  fi
  [[ $audit_rc -eq 0 ]] && echo "PASS: all snapshot closing integrity scenarios passed" || echo "FAIL: snapshot closing integrity regression detected"
fi
echo "Artifacts: $out"
printf '[%s] [INFO] RESULT fail_flag=%s msg=snapshot_closing_audit_%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$audit_rc" "$(if [[ $audit_rc -eq 0 ]]; then printf PASS; else printf FAIL; fi)"
exit "$audit_rc"
