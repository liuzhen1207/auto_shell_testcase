#!/bin/bash
# CAM_P1_15: verify that the released package accepts CANCEL ALL MIGRATIONS
# in table dialect, then verify successful and denied audit records.
# A parser error (especially status 700 / mismatched input CANCEL) is reported
# separately from an audit-record defect.

cur_dir="$( cd "$( dirname "$0" )" && pwd )"
. "${cur_dir}/tc2026_CancelAllMigrations_0018_cancel_audit_log_fields.sh"
CASE_ID="CAM_P1_15"

run_as_table_user() {
    local user=$1 password=$2 name=$3
    local out="${run_artifact_dir}/${name}.out"
    ${cli_dir}/sbin/start-cli.sh -u "${user}" -pw "${password}" -h "${query_ip}" \
        -sql_dialect table -e "CANCEL ALL MIGRATIONS;" > "${out}" 2>&1 || true
    trim_file_crlf "${out}"
}

main() {
    mkdir -p "${run_artifact_dir}"; : > "${log_file}"
    local test_begin_time probe_out show_out
    test_begin_time=$(date +%s)
    log "INFO" "Case: CAM_P1_15 table CANCEL syntax and audit records"
    start_db || { finalize_test "${test_begin_time}"; return 1; }

    # The probe is safe only when there is no migration to cancel.
    show_out="${run_artifact_dir}/table_show_migrations_before_probe.out"
    cli_table "${query_ip}" "SHOW MIGRATIONS;" > "${show_out}" 2>&1 || true
    trim_file_crlf "${show_out}"
    if ! grep -q "Empty set" "${show_out}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}precondition failed: SHOW MIGRATIONS is not empty; table CANCEL probe was not sent."
        finalize_test "${test_begin_time}"
        return 1
    fi

    probe_out="${run_artifact_dir}/table_cancel_syntax_probe.out"
    cli_table "${query_ip}" "CANCEL ALL MIGRATIONS;" > "${probe_out}" 2>&1 || true
    trim_file_crlf "${probe_out}"
    if grep -Eqi "700:|mismatched input[[:space:]]+'?CANCEL|parsing error|syntax error" "${probe_out}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}product bug: released table-dialect parser rejects CANCEL ALL MIGRATIONS with syntax status 700; audit verification is unreachable."
        log "ERROR" "Table CANCEL rejected by parser; see ${probe_out}"
        finalize_test "${test_begin_time}"
        return 1
    fi
    if ! grep -q "The statement is executed successfully." "${probe_out}"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}table CANCEL did not return success and was not classified as the known status-700 parser defect."
        finalize_test "${test_begin_time}"
        return 1
    fi

    # Users are created in tree dialect; table SYSTEM privilege uses its own
    # GRANT syntax. Use unique names so tree-audit and table-audit runs cannot
    # be confused in __audit.audit_log.
    cli_tree "${query_ip}" "CREATE USER cam_table_audit_ok 'TimechoDB@2021';" > "${run_artifact_dir}/create_table_audit_ok.out" 2>&1
    cli_tree "${query_ip}" "CREATE USER cam_table_audit_denied 'TimechoDB@2021';" > "${run_artifact_dir}/create_table_audit_denied.out" 2>&1
    cli_table "${query_ip}" "GRANT SYSTEM TO USER cam_table_audit_ok;" > "${run_artifact_dir}/grant_table_audit_ok.out" 2>&1
    check_cli_success "${run_artifact_dir}/grant_table_audit_ok.out" "grant table SYSTEM" || true

    run_as_table_user cam_table_audit_ok 'TimechoDB@2021' table_audit_success_client
    run_as_table_user cam_table_audit_denied 'TimechoDB@2021' table_audit_denied_client
    grep -q "The statement is executed successfully." "${run_artifact_dir}/table_audit_success_client.out" || { let fail_flag++; v_warnMessage="${v_warnMessage}authorized table user did not execute CANCEL successfully."; }
    grep -Eqi '803:|permission|privilege|access denied|not authorized' "${run_artifact_dir}/table_audit_denied_client.out" || { let fail_flag++; v_warnMessage="${v_warnMessage}unauthorized table user was not denied with 803."; }

    sleep 3
    collect_audit_records cam_table_audit_ok cam_table_audit_denied
    if ! grep -Eiq 'CANCEL[[:space:]]+ALL[[:space:]]+MIGRATIONS' "${run_artifact_dir}/cancel_audit_records.out"; then
        let fail_flag++
        v_warnMessage="${v_warnMessage}table CANCEL executes, but generated no CANCEL audit event for authorized success or 803 denial."
    else
        assert_audit_record cam_table_audit_ok 'true|success|succeed|executed successfully|status[=: ]*200' table_success
        assert_audit_record cam_table_audit_denied 'false|fail|denied|permission|privilege|not authorized|803|status[=: ]*(401|403|600|803)' table_denied
    fi

    finalize_test "${test_begin_time}"
    [ "${fail_flag}" -eq 0 ]
}

main "$@"
