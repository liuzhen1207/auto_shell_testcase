param(
  [Parameter(Mandatory=$true)][string]$Cases,
  [string]$Log = "D:\IDEA\deepseek\ip99_80\sec_skill\plm_import\import_batch.log"
)

$env:TIMECHO_PLM_TOKEN = "plm_pat_UH6jYnUX0skqxPZZ2D6U-uwlwigDojWFW76qr8bNevs"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$sk   = "C:\Users\admin\.codex\skills\timecho-plm-shell-testcase-import\scripts\shell_case_import.py"
$repo = "D:\IDEA\deepseek\_repo_auto_shell_testcase"
$out  = "D:\IDEA\deepseek\ip99_80\sec_skill\plm_import"

foreach ($c in $Cases.Split(",")) {
  $c = $c.Trim()
  $key = "192_168_99_80/sec_skill/$c"
  $stamp = Get-Date -Format "HH:mm:ss"
  "===== $stamp START $c =====" | Tee-Object -FilePath $Log -Append
  & python $sk $repo --skill sec_skill --only $key --accept-review `
      --feature-map "$out\feature-map.json" --name-map "$out\name-map.json" `
      --ledger "$out\ledger.json" --confirm-write --out-dir $out *>&1 |
    Tee-Object -FilePath $Log -Append |
    Select-String -Pattern 'apply|run=|->|FAIL|error|ERROR|Traceback' |
    ForEach-Object { "  " + $_.Line }
  $stamp = Get-Date -Format "HH:mm:ss"
  "----- $stamp END $c rc=$LASTEXITCODE -----" | Tee-Object -FilePath $Log -Append
}
