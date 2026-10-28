# Backup diario de Supabase en el servidor Windows.
#
# pg_dump -> pg_restore --list (sanidad) -> gpg AES256 -> disco local -> retencion -> Telegram.
# Mismo formato que el Action de GitHub (.github/workflows/backup.yml): un .sql.gpg de este
# servidor se restaura con el mismo runbook (scripts/backup/restore-runbook.md).
#
# Lo corre la tarea programada que registra instalar-tarea.ps1. Para probarlo a mano:
#   powershell -ExecutionPolicy Bypass -File backup.ps1 [-Tier daily|weekly|monthly]
#
# Lee la config de $ConfigDir (fuera del repo, con permisos sólo para SYSTEM y
# Administradores). Ver setup-windows.md.
#
# Compatible con Windows PowerShell 5.1.

[CmdletBinding()]
param(
  [ValidateSet('auto', 'daily', 'weekly', 'monthly')]
  [string]$Tier = 'auto',
  [string]$ConfigDir = "$env:ProgramData\distribuidora-backup"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$configFile = Join-Path $ConfigDir 'config.json'
$passphraseFile = Join-Path $ConfigDir 'passphrase.txt'

if (-not (Test-Path $configFile)) { throw "No existe $configFile (ver setup-windows.md)" }
if (-not (Test-Path $passphraseFile)) { throw "No existe $passphraseFile (ver setup-windows.md)" }

$cfg = Get-Content -Raw -Path $configFile | ConvertFrom-Json

function Get-Cfg([string]$name, $default) {
  $prop = $cfg.PSObject.Properties[$name]
  if ($null -eq $prop -or $null -eq $prop.Value -or "$($prop.Value)" -eq '') { return $default }
  return $prop.Value
}

$dbUrl      = Get-Cfg 'SupabaseDbUrl' $null
$backupRoot = Get-Cfg 'BackupRoot' 'D:\Backups\distribuidora-app'
$pgBin      = Get-Cfg 'PgBinDir' 'C:\Program Files\PostgreSQL\17\bin'
$gpgExe     = Get-Cfg 'GpgExe' 'C:\Program Files\GnuPG\bin\gpg.exe'
$tgToken    = Get-Cfg 'TelegramBotToken' $null
$tgChat     = Get-Cfg 'TelegramChatId' $null
# En disco local sobra lugar (~14 MB por dump en 2026-10): se guarda más que en Drive.
$keep = @{
  daily   = [int](Get-Cfg 'KeepDaily' 30)
  weekly  = [int](Get-Cfg 'KeepWeekly' 12)
  monthly = [int](Get-Cfg 'KeepMonthly' 24)
}

if (-not $dbUrl) { throw 'Falta SupabaseDbUrl en config.json' }

$pgDump    = Join-Path $pgBin 'pg_dump.exe'
$pgRestore = Join-Path $pgBin 'pg_restore.exe'
foreach ($exe in @($pgDump, $pgRestore, $gpgExe)) {
  if (-not (Test-Path $exe)) { throw "No se encuentra $exe (ver setup-windows.md)" }
}

$logDir = Join-Path $backupRoot 'logs'
$workDir = Join-Path $backupRoot 'tmp'
New-Item -ItemType Directory -Force -Path $logDir, $workDir | Out-Null

# La fecha y el tier van en hora argentina, que es la del servidor.
$now = Get-Date
$dateTag = $now.ToString('yyyy-MM-dd')
$logFile = Join-Path $logDir "$dateTag.log"

function Write-Log([string]$msg) {
  $line = '{0} {1}' -f (Get-Date).ToString('HH:mm:ss'), $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

function Send-Telegram([string]$text) {
  if (-not $tgToken -or -not $tgChat) { Write-Log 'Telegram no configurado, skip'; return }
  # PowerShell 5.1 no negocia TLS 1.2 por defecto y api.telegram.org lo exige.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$tgToken/sendMessage" -Body @{
      chat_id                  = $tgChat
      text                     = $text
      disable_web_page_preview = 'true'
    } | Out-Null
  } catch {
    Write-Log "Telegram fallo: $($_.Exception.Message)"
  }
}

# Corre un ejecutable nativo sin pasar su stderr por PowerShell: en 5.1, `2>` sobre un
# nativo convierte cada línea en ErrorRecord y con ErrorActionPreference=Stop corta el
# script aunque el exe termine bien (pg_dump --verbose escribe todo a stderr).
function Invoke-Native([string]$exe, [string[]]$argList, [string]$stdoutFile, [string]$stderrFile) {
  $quoted = $argList | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }
  $p = @{
    FilePath               = $exe
    ArgumentList           = ($quoted -join ' ')
    PassThru               = $true
    NoNewWindow            = $true
    RedirectStandardError  = $stderrFile
  }
  if ($stdoutFile) { $p.RedirectStandardOutput = $stdoutFile }
  # Sin -Wait: Start-Process -Wait espera también a los descendientes, y gpg deja vivo el
  # gpg-agent, así que no volvía nunca. Leer .Handle antes de esperar hace que .ExitCode
  # tenga valor en 5.1.
  $proc = Start-Process @p
  $null = $proc.Handle
  if (-not $proc.WaitForExit(20 * 60 * 1000)) {
    $proc.Kill()
    throw "$exe no termino en 20 minutos"
  }
  return $proc.ExitCode
}

function Remove-Viejos([string]$dir, [string]$pattern, [int]$keepN) {
  if (-not (Test-Path $dir)) { return }
  # Los nombres son YYYY-MM-DD: el orden alfabético es el cronológico.
  $files = @(Get-ChildItem -Path $dir -Filter $pattern -File | Sort-Object Name)
  $sobran = $files.Count - $keepN
  if ($sobran -le 0) { return }
  $files | Select-Object -First $sobran | ForEach-Object {
    Write-Log "  borrando $($_.FullName)"
    Remove-Item -LiteralPath $_.FullName -Force
  }
}

$dumpFile = Join-Path $workDir "$dateTag.dump"
$encTmp = "$dumpFile.gpg"
$exitCode = 1

try {
  Write-Log "=== Backup Supabase $dateTag ==="

  if ($Tier -eq 'auto') {
    if ($now.Day -eq 1) { $Tier = 'monthly' }
    elseif ($now.DayOfWeek -eq [DayOfWeek]::Sunday) { $Tier = 'weekly' }
    else { $Tier = 'daily' }
  }
  Write-Log "Tier: $Tier"

  # -Fc = custom format (comprimido + restaurable selectivamente)
  # --no-owner / --no-acl = portable a otro proyecto Supabase
  $pgLog = Join-Path $workDir 'pg_dump.log'
  $code = Invoke-Native $pgDump @('--format=custom', '--no-owner', '--no-acl', '--verbose',
    "--file=$dumpFile", "--dbname=$dbUrl") $null $pgLog
  if ($code -ne 0) {
    $tail = (Get-Content $pgLog -Tail 30) -join "`n"
    throw "pg_dump salio con codigo $code`n$tail"
  }

  $size = (Get-Item $dumpFile).Length
  Write-Log "Dump: $size bytes"
  # Un dump < 100KB casi seguro indica falla parcial.
  if ($size -lt 102400) { throw "Dump menor a 100KB ($size bytes), probablemente fallo" }

  # El Action no lo hace: confirma que el archivo se puede leer antes de encriptarlo.
  $listOut = Join-Path $workDir 'pg_restore_list.txt'
  $listErr = Join-Path $workDir 'pg_restore_list.err'
  $code = Invoke-Native $pgRestore @('--list', $dumpFile) $listOut $listErr
  if ($code -ne 0) { throw "pg_restore --list fallo (codigo $code): el dump esta corrupto" }
  $tablas = @(Select-String -Path $listOut -Pattern ' TABLE DATA public ').Count
  Write-Log "pg_restore --list OK ($tablas tablas de public con datos)"

  $gpgErr = Join-Path $workDir 'gpg.err'
  $code = Invoke-Native $gpgExe @('--batch', '--yes', '--quiet', '--pinentry-mode', 'loopback',
    '--passphrase-file', $passphraseFile, '--symmetric', '--cipher-algo', 'AES256',
    '--output', $encTmp, $dumpFile) $null $gpgErr
  if ($code -ne 0) {
    throw "gpg fallo (codigo $code): $((Get-Content $gpgErr) -join ' ')"
  }
  Remove-Item -LiteralPath $dumpFile -Force

  $tierDir = Join-Path $backupRoot $Tier
  New-Item -ItemType Directory -Force -Path $tierDir | Out-Null
  $finalFile = Join-Path $tierDir "$dateTag.sql.gpg"
  Move-Item -LiteralPath $encTmp -Destination $finalFile -Force

  $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $finalFile).Hash.ToLower()
  $encSize = (Get-Item $finalFile).Length
  $sizeHuman = '{0:N1} MB' -f ($encSize / 1MB)
  Write-Log "Guardado: $finalFile ($sizeHuman, sha256 $sha)"

  Write-Log 'Retencion:'
  foreach ($t in @('daily', 'weekly', 'monthly')) {
    Remove-Viejos (Join-Path $backupRoot $t) '*.sql.gpg' $keep[$t]
  }
  Remove-Viejos $logDir '*.log' 60

  $libre = (Get-PSDrive -Name ($backupRoot.Substring(0, 1))).Free
  $libreHuman = '{0:N1} GB' -f ($libre / 1GB)
  Write-Log "Espacio libre en el disco: $libreHuman"

  Send-Telegram ("[OK] Backup Supabase (servidor)`nFecha: $dateTag`nTier: $Tier`n" +
    "Tamano: $sizeHuman`nSHA256: $sha`nPath: $finalFile`nLibre en disco: $libreHuman")
  Write-Log 'OK'
  $exitCode = 0
} catch {
  $err = $_.Exception.Message
  Write-Log "ERROR: $err"
  Send-Telegram ("[FAIL] Backup Supabase (servidor) fallo`nFecha: $dateTag`n" +
    "Error: $($err.Substring(0, [Math]::Min(500, $err.Length)))`nLog: $logFile")
} finally {
  # El dump sin encriptar nunca queda en disco.
  foreach ($f in @($dumpFile, $encTmp)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
  }
}

exit $exitCode
