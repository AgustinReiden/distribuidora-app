# Registra la tarea programada que corre backup.ps1 todos los días a las 03:00.
#
# Correr UNA vez, en PowerShell como Administrador, desde esta carpeta:
#   powershell -ExecutionPolicy Bypass -File instalar-tarea.ps1
#
# Copia backup.ps1 a $InstallDir (así la tarea no depende de dónde esté el repo),
# protege la carpeta de config y registra la tarea como SYSTEM: corre aunque nadie
# haya iniciado sesión. Volver a correrlo actualiza el script y la tarea.

[CmdletBinding()]
param(
  [string]$InstallDir = "$env:ProgramData\distribuidora-backup",
  [string]$Hora = '03:00',
  [string]$TaskName = 'Backup Supabase distribuidora-app'
)

$ErrorActionPreference = 'Stop'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Correr como Administrador' }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'backup.ps1') -Destination $InstallDir -Force

# config.json y passphrase.txt tienen la URL con password de la base y la clave de los
# backups: sólo SYSTEM y Administradores leen la carpeta.
& icacls $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls fallo con codigo $LASTEXITCODE" }

$script = Join-Path $InstallDir 'backup.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Daily -At $Hora
# StartWhenAvailable: si la máquina estaba apagada a las 03:00, corre apenas prende.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
  -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 15) `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Tarea '$TaskName' registrada: todos los dias a las $Hora."
Write-Host "Script: $script"
foreach ($f in @('config.json', 'passphrase.txt')) {
  if (-not (Test-Path (Join-Path $InstallDir $f))) {
    Write-Host "FALTA $InstallDir\$f (ver setup-windows.md, paso 3)" -ForegroundColor Yellow
  }
}
Write-Host "Probar ahora: Start-ScheduledTask -TaskName '$TaskName'"
