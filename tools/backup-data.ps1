# Dumps the live database's DATA to a dated file outside this repository.
#
# Why not a GitHub Action: this repository is public, and workflow artifacts
# on a public repo are downloadable by anyone. A dump contains members' email
# addresses, bays, swap history and credit balances. Automating it into CI
# would publish exactly the thing it is meant to protect.
#
# Why not commit the dumps: same reason, plus git never forgets. The terms
# promise members they can ask to have their data erased, and a dump sitting
# in history forever makes that promise hard to keep. Dated files you can
# delete are the right shape for this.
#
# Schema is NOT included: it already lives in supabase/migrations, in version
# control, where it belongs. This is the half that cannot be rebuilt.
#
# Usage, from anywhere:
#
#   powershell -ExecutionPolicy Bypass -File tools\backup-data.ps1
#
# It asks for the database password, or reads $env:SUPABASE_DB_PASSWORD if
# you have set it. Find it in the dashboard under Settings -> Database. It is
# not the publishable key and not your account password.

param(
  [string] $OutDir  = (Join-Path $env:USERPROFILE 'SwapSpot-backups'),
  [int]    $Keep    = 14,
  [string] $ProjectRef = 'woxumfxyghqpesooobjq'
)

$ErrorActionPreference = 'Stop'

# Refuse to write inside the repo: that is how private data ends up public.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ((Resolve-Path -LiteralPath $OutDir -ErrorAction SilentlyContinue).Path -like "$repoRoot*") {
  Write-Host "Refusing to write backups inside the repository ($repoRoot)." -ForegroundColor Red
  Write-Host "This repo is public. Choose an -OutDir somewhere else." -ForegroundColor Red
  exit 1
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$password = $env:SUPABASE_DB_PASSWORD
if (-not $password) {
  $secure = Read-Host -Prompt 'Supabase database password' -AsSecureString
  $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if (-not $password) { Write-Host 'No password given.' -ForegroundColor Red; exit 1 }

$stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
$file  = Join-Path $OutDir "swapspot-data-$stamp.sql"

Write-Host ''
Write-Host "Dumping data from $ProjectRef ..." -ForegroundColor Cyan

npx.cmd --yes supabase db dump --project-ref $ProjectRef --data-only --use-copy -p $password -f $file

if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host "Dump failed with exit code $LASTEXITCODE. Nothing was written." -ForegroundColor Red
  if (Test-Path $file) { Remove-Item $file -Force }
  exit $LASTEXITCODE
}

$size = [math]::Round((Get-Item $file).Length / 1KB, 1)
Write-Host ''
Write-Host "Wrote $file  ($size KB)" -ForegroundColor Green

# Keep the most recent $Keep dumps, delete the rest.
$all = Get-ChildItem -Path $OutDir -Filter 'swapspot-data-*.sql' | Sort-Object LastWriteTime -Descending
if ($all.Count -gt $Keep) {
  $old = $all | Select-Object -Skip $Keep
  $old | ForEach-Object { Remove-Item $_.FullName -Force }
  Write-Host ("Pruned " + $old.Count + " older backup(s), keeping $Keep.") -ForegroundColor Yellow
}

Write-Host ("Backups in $OutDir : " + (Get-ChildItem -Path $OutDir -Filter 'swapspot-data-*.sql').Count)
Write-Host ''
Write-Host 'To restore: apply supabase/migrations to a fresh project first, then psql this file into it.' -ForegroundColor Yellow
