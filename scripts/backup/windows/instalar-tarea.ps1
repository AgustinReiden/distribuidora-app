# Registra la tarea programada que corre backup.ps1 todos los días a las 03:00.
#
# Correr UNA vez, en PowerShell como Administrador, desde esta carpeta:
#   powershell -ExecutionPolicy Bypass -File instalar-tarea.ps1
#
# Copia backup.ps1 a $InstallDir (así la tarea no depende de dónde esté el repo),
# protege la carpeta de config y registra la tarea. Corre aunque nadie haya iniciado
# sesión. Volver a correrlo actualiza el script y la tarea.
#
# Por defecto corre como SYSTEM, que alcanza si BackupRoot es un disco de esta máquina.
# Si BackupRoot es una carpeta de red (\\servidor\recurso\...), SYSTEM no tiene permiso
# ahí y no ve las unidades mapeadas (Y:, Z:): pasar -Usuario con una cuenta de Windows
# que pueda escribir en esa carpeta. Pide la contraseña una vez y la guarda el
# Programador de tareas, no este script.
#   powershell -ExecutionPolicy Bypass -File instalar-tarea.ps1 -Usuario "$env:USERDOMAIN\$env:USERNAME"

[CmdletBinding()]
param(
  [string]$InstallDir = "$env:ProgramData\distribuidora-backup",
  [string]$Hora = '03:00',
  [string]$TaskName = 'Backup Supabase distribuidora-app',
  [string]$Usuario
)

$ErrorActionPreference = 'Stop'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Correr como Administrador' }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'backup.ps1') -Destination $InstallDir -Force

# config.json y passphrase.txt tienen la URL con password de la base y la clave de los
# backups: sólo SYSTEM y Administradores leen la carpeta.
$grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
if ($Usuario) { $grants += "${Usuario}:(OI)(CI)R" }
& icacls $InstallDir /inheritance:r /grant:r @grants | Out-Null
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
if ($Usuario) {
  $cred = Get-Credential -UserName $Usuario -Message 'Contrasena de Windows de la cuenta que corre el backup'
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -User $cred.UserName -Password $cred.GetNetworkCredential().Password `
    -RunLevel Highest -Force | Out-Null
  $quien = $cred.UserName
} else {
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
  $quien = 'SYSTEM'
}

Write-Host "Tarea '$TaskName' registrada: todos los dias a las $Hora, como $quien."
Write-Host "Script: $script"
foreach ($f in @('config.json', 'passphrase.txt')) {
  if (-not (Test-Path (Join-Path $InstallDir $f))) {
    Write-Host "FALTA $InstallDir\$f (ver setup-windows.md, paso 3)" -ForegroundColor Yellow
  }
}
Write-Host "Probar ahora: Start-ScheduledTask -TaskName '$TaskName'"
