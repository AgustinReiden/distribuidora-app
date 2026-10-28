# Backup diario en el servidor Windows

El servidor hace el backup diario y lo guarda en su disco. A Google Drive va sólo el
mensual (el Action de GitHub corre el día 1), como copia fuera del local: si el servidor
se roba, se quema o se le muere el disco, quedan los mensuales en Drive.

Los archivos son los mismos que genera el Action (`pg_dump -Fc` encriptado con gpg AES256 y
la misma passphrase), así que se restauran con [restore-runbook.md](../restore-runbook.md).

Todo esto se hace **una sola vez**, en el servidor, en PowerShell **como Administrador**.

## Paso 1 — Instalar las herramientas

```powershell
winget install PostgreSQL.PostgreSQL.17
winget install GnuPG.Gpg4win
```

Del instalador de PostgreSQL alcanza con **Command Line Tools**: no hace falta el servidor
de base ni pgAdmin. Tiene que ser la **17**, la versión de producción: un `pg_dump` más
viejo se niega a dumpear una base más nueva.

Verificar:

```powershell
& 'C:\Program Files\PostgreSQL\17\bin\pg_dump.exe' --version
& 'C:\Program Files\GnuPG\bin\gpg.exe' --version
```

Si quedaron en otra ruta, anotala para `PgBinDir` / `GpgExe` del paso 3.

## Paso 2 — Instalar la tarea

Desde una copia del repo (o copiando la carpeta `scripts/backup/windows/` al servidor):

```powershell
cd scripts\backup\windows
powershell -ExecutionPolicy Bypass -File instalar-tarea.ps1
```

Copia `backup.ps1` a `C:\ProgramData\distribuidora-backup\`, deja esa carpeta legible sólo
por SYSTEM y Administradores, y registra la tarea **Backup Supabase distribuidora-app**:
todos los días a las 03:00, como SYSTEM (corre aunque nadie inicie sesión), y si la
máquina estaba apagada a esa hora corre apenas prende.

**Si los backups van a una carpeta de red** (por ejemplo `Y:\Backups Sistemas\Distribuidora`,
que es `\\192.168.0.12\OficinaCentral19\...`), SYSTEM no sirve: no tiene permiso en el
recurso compartido y no ve las unidades mapeadas. Instalar la tarea con una cuenta de
Windows que pueda escribir ahí, y poner su contraseña cuando la pida (la guarda el
Programador de tareas):

```powershell
powershell -ExecutionPolicy Bypass -File instalar-tarea.ps1 -Usuario "$env:USERDOMAIN\$env:USERNAME"
```

Si cambiás la contraseña de esa cuenta, hay que volver a correr este paso, o la tarea deja
de correr (y deja de llegar el mensaje a Telegram).

Si para entrar a la carpeta compartida la máquina pide un usuario y una contraseña **de la
otra máquina** (la que tiene la carpeta), guardalos para esa cuenta, logueado con ella:

```powershell
cmdkey /add:192.168.0.12 /user:USUARIO_DE_LA_12 /pass
```

Sin esto, a mano entra porque Windows recuerda la sesión del Explorador, pero la tarea
de las 03:00 no, y falla con "acceso denegado".

Si después cambia `backup.ps1` en el repo, volver a correr este paso lo actualiza.

## Paso 3 — Config y passphrase

Los dos archivos van en `C:\ProgramData\distribuidora-backup\`, **nunca en el repo**.

**passphrase.txt** — la misma `BACKUP_PASSPHRASE` que ya está en el gestor de contraseñas
(la de los backups de Drive). Escribirla así, sin salto de línea ni BOM, que gpg lee el
archivo byte por byte:

```powershell
Set-Content -Path C:\ProgramData\distribuidora-backup\passphrase.txt -Encoding ascii -NoNewline -Value 'PEGAR_PASSPHRASE'
```

**config.json** — copiar [config.example.json](config.example.json) y completar:

| Campo | Valor |
|---|---|
| `SupabaseDbUrl` | El mismo valor que el secret `SUPABASE_DB_URL` de GitHub (Session pooler, puerto 5432; ver [setup.md](../setup.md) paso 4) |
| `BackupRoot` | Dónde guardar. Una carpeta de red va con la ruta `\\servidor\recurso\...`, **nunca con la letra** (`Y:`): la tarea no ve las unidades mapeadas |
| `PgBinDir`, `GpgExe` | Sólo si quedaron en otra ruta en el paso 1 |
| `TelegramBotToken`, `TelegramChatId` | Los mismos que `TELEGRAM_BOT_TOKEN` y `TELEGRAM_BACKUP_CHAT_ID` de GitHub |
| `KeepDaily`, `KeepWeekly`, `KeepMonthly` | Cuántos guardar de cada uno (30 / 12 / 24 por defecto, ~1 GB) |

En JSON cada barra de la ruta va doble: `\\192.168.0.12\OficinaCentral19\Backups Sistemas\Distribuidora`
se escribe `"\\\\192.168.0.12\\OficinaCentral19\\Backups Sistemas\\Distribuidora"`.

## Paso 4 — Primera corrida

```powershell
Start-ScheduledTask -TaskName 'Backup Supabase distribuidora-app'
```

Tarda unos minutos. Verificar:

1. Llega a Telegram `[OK] Backup Supabase (servidor)` con tamaño y SHA256.
2. Existe `<BackupRoot>\daily\AAAA-MM-DD.sql.gpg` (~14 MB en octubre de 2026).
3. El log del día está en `<BackupRoot>\logs\AAAA-MM-DD.log`.

Si falla, el log dice por qué, y el error llega también a Telegram como `[FAIL]`.

## Paso 5 — Drill de restauración

Con un archivo de este servidor, seguir [restore-runbook.md](../restore-runbook.md) desde
el paso 3. Hasta que eso no ande, el backup del servidor no está validado.

## Paso 6 — Limpiar Drive

Cuando el servidor lleve unos días mandando el `[OK]`, borrar a mano las carpetas
`daily/` y `weekly/` de `Backups/distribuidora-app` en Drive (y vaciar la papelera). El
Action ya no escribe ahí; sólo sigue llenando `monthly/`.

## Qué vigilar

- **Si un día no llega ningún mensaje a Telegram**, ni OK ni FAIL, la tarea no corrió:
  el servidor está apagado, sin red, o se borró la tarea. Ese silencio es la alarma.
- El mensaje de OK trae el espacio libre del disco.
- Si se rota el password de la base, actualizar `SupabaseDbUrl` acá **y** el secret
  `SUPABASE_DB_URL` de GitHub.
