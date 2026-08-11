#!/bin/bash
# Excel case: DPR_G02
# Generated as an independent entry; implementation is in manual_repair_excel_case_lib.sh.
set -uo pipefail
cur_dir="$(cd "$(dirname "$0")" && pwd)"
export DPR_CASE_ID="DPR_G02"
source "$cur_dir/manual_repair_excel_case_lib.sh"
run_case