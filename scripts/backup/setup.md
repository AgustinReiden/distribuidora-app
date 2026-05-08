# Setup inicial de backups Supabase

Esto se hace **una sola vez**. Despues el workflow corre solo todos los dias a las 03:00 ART.

## Paso 1 — Crear estructura en Google Drive

En tu cuenta personal de Drive, crea las carpetas:

```
Backups/
  distribuidora-app/
    daily/
    weekly/
    monthly/
```

## Paso 2 — Generar passphrase de encriptacion

**Critico:** sin la passphrase los dumps son irrecuperables. Guardala en al menos 2 lugares (gestor de contraseñas + segundo backup, ej. sobre fisico o segundo gestor).

```bash
openssl rand -base64 32
```

Guardar en gestor de contraseñas con label exacto: `BACKUP_PASSPHRASE distribuidora-app`.

## Paso 3 — Configurar rclone localmente

Esto es solo para generar el archivo de config que despues va como secret a GitHub.

### 3.1 Instalar rclone

- Linux/Mac: `curl https://rclone.org/install.sh | sudo bash`
- Windows: descargar de https://rclone.org/downloads/ o `winget install Rclone.Rclone`

### 3.2 Configurar remote `gdrive`

```bash
rclone config
```

Responder:
- `n` (new remote)
- name: `gdrive`
- Storage: buscar `drive` (Google Drive)
- `client_id` / `client_secret`: dejar vacios (usa los publicos de rclone, OK para uso personal)
- scope: `1` (Full access — necesario para escribir y borrar)
- service_account_file: vacio
- Edit advanced config: `n`
- Use auto config: `y` (abre browser para OAuth)
- Configure as Shared Drive: `n`
- Confirmar `y`

### 3.3 Verificar

```bash
rclone lsd gdrive:Backups/distribuidora-app
```

Deberias ver `daily`, `weekly`, `monthly`.

### 3.4 Exportar config como base64

**Linux/Mac:**
```bash
base64 -w 0 ~/.config/rclone/rclone.conf
```

**Windows PowerShell:**
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:APPDATA\rclone\rclone.conf"))
```

Copiar el string resultante. Es lo que va al secret `RCLONE_CONFIG_BASE64`.

## Paso 4 — Obtener connection string de Supabase

1. Ir a https://supabase.com/dashboard/project/hmuchlzmuqqxcldbzkgc/settings/database
2. En **Connection string**, elegir tab **URI** y modo **Session pooler** (NO Transaction — `pg_dump` requiere session).
3. Reemplazar `[YOUR-PASSWORD]` por el password de la DB (esta en el dashboard, **Database password**).
4. El string completo va al secret `SUPABASE_DB_URL`.

Formato esperado: `postgresql://postgres.PROJECTREF:PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres`

## Paso 5 — Configurar bot de Telegram para notificaciones

Reusar el bot existente del proyecto (`TELEGRAM_BOT_TOKEN` ya existe en Supabase Edge Functions).

Para obtener el chat ID:
1. Crear un canal o chat privado para alertas (recomendado: canal "Backups Distribuidora").
2. Agregar el bot como admin.
3. Mandar un mensaje cualquiera al canal.
4. `curl https://api.telegram.org/bot<TOKEN>/getUpdates` y leer `chat.id`.

## Paso 6 — Cargar secrets en GitHub

Ir a **Settings → Secrets and variables → Actions → New repository secret**.

| Nombre | Valor |
|---|---|
| `SUPABASE_DB_URL` | Connection string del paso 4 |
| `BACKUP_PASSPHRASE` | Passphrase del paso 2 |
| `RCLONE_CONFIG_BASE64` | Base64 del paso 3.4 |
| `TELEGRAM_BOT_TOKEN` | Token del bot existente (ya en Supabase Edge Functions) |
| `TELEGRAM_BACKUP_CHAT_ID` | Chat ID del paso 5 |

## Paso 7 — Primera corrida

```bash
gh workflow run backup.yml
```

O desde la UI: **Actions → Backup Supabase DB → Run workflow**.

Verificar:
1. Workflow termina en verde (~2-5 min con datos actuales).
2. Aparece mensaje en Telegram con tamaño y SHA256.
3. En Drive: `Backups/distribuidora-app/daily/YYYY-MM-DD.sql.gpg` existe y pesa similar al reportado.

## Paso 8 — Drill de restauracion (no skipear)

Seguir [restore-runbook.md](restore-runbook.md) en un proyecto Supabase staging vacio.
Sin este drill, el backup no esta validado.

## Mantenimiento

- **Mensual:** ejecutar drill de restore (runbook).
- **Cuando rotes el password de DB:** actualizar el secret `SUPABASE_DB_URL`.
- **Cuando expire el OAuth de rclone (raro, ~6 meses inactivo):** repetir paso 3 y actualizar `RCLONE_CONFIG_BASE64`.
- **Si las notificaciones dejan de llegar:** revisar `Actions` en GitHub. Si workflow no corre durante 60 dias, GitHub auto-deshabilita los crons en repos privados — re-habilitar manualmente.
