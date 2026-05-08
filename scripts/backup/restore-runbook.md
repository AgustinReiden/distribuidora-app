# Runbook: restaurar backup de Supabase

**RTO objetivo:** < 30 min desde decision hasta DB restaurada.
**RPO actual:** 24 h (ultimo backup diario).

## Cuando ejecutar este runbook

| Caso | Accion |
|---|---|
| Drill mensual (dia 1) | Restaurar a proyecto staging y comparar conteos. Documentar tiempos. |
| Borrado accidental de datos | Restaurar a staging, exportar tablas afectadas, importar a produccion. NO sobreescribir produccion entera sin pensar. |
| Corrupcion total | Crear proyecto Supabase nuevo, restaurar, reapuntar `VITE_SUPABASE_URL` en deploys. |
| Migracion fallida | Restaurar a produccion si la corrida es muy reciente y no entraron datos nuevos. Sino, restore a staging y reconciliar diff. |

## Prerequisitos locales

- `pg_restore` versión 17 instalado (`postgresql-client-17`).
- `gpg` instalado.
- `rclone` configurado con remote `gdrive` (ver [setup.md](setup.md) paso 3).
- Acceso al gestor de contraseñas con `BACKUP_PASSPHRASE distribuidora-app`.
- Acceso al dashboard de Supabase.

## Paso 1 — Crear proyecto Supabase de destino

**Para drill o corrupcion total:**
1. https://supabase.com/dashboard → **New project**.
2. Region: `sa-east-1` (mismo que prod, latencia menor).
3. Plan: Free tier OK para drill.
4. Anotar el **project ref** y el **DB password** generado.

**Para borrado accidental (recuperacion quirurgica):**
- Restaurar a un proyecto staging dedicado, no a produccion.

## Paso 2 — Descargar el backup

Decidir que dia restaurar:
- Para drill: el ultimo `daily/` disponible.
- Para incidente: el ultimo backup ANTES del evento que se quiere revertir.

```bash
# Listar backups disponibles
rclone ls gdrive:Backups/distribuidora-app/daily/
rclone ls gdrive:Backups/distribuidora-app/weekly/
rclone ls gdrive:Backups/distribuidora-app/monthly/

# Descargar
mkdir -p /tmp/restore && cd /tmp/restore
rclone copy gdrive:Backups/distribuidora-app/daily/YYYY-MM-DD.sql.gpg .
```

## Paso 3 — Verificar integridad

```bash
sha256sum YYYY-MM-DD.sql.gpg
```

Comparar contra el SHA256 que mando el bot a Telegram el dia que se hizo el backup. Si no coincide: archivo corrupto, intentar otro dia o investigar.

## Paso 4 — Desencriptar

```bash
gpg --batch --passphrase 'PEGAR_PASSPHRASE_AQUI' \
  --decrypt YYYY-MM-DD.sql.gpg > dump.sql
```

Verificar que `dump.sql` tenga tamaño razonable (debe ser comparable o un poco mayor que el `.gpg`).

## Paso 5 — Obtener connection string del destino

Dashboard del proyecto destino → **Settings → Database → Connection string → URI** (modo Session pooler).

```bash
export DEST_DB_URL='postgresql://postgres.REF:PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres'
```

## Paso 6 — pg_restore

```bash
pg_restore \
  --no-owner \
  --no-acl \
  --verbose \
  --dbname "$DEST_DB_URL" \
  dump.sql 2>&1 | tee restore.log
```

**Errores tolerables (esperados):**
- `role "supabase_admin" does not exist` — supabase_admin lo crea Supabase, no nuestro dump. Ignorar.
- Errores en extensiones ya creadas por Supabase (`extension "X" already exists`).
- Errores en schemas internos (`auth`, `storage`) — Supabase los maneja.

**Errores criticos (parar y diagnosticar):**
- Cualquier `ERROR` que mencione tablas de negocio (`pedidos`, `clientes`, `productos`, `pagos`, `audit_logs`, etc.).
- `connection refused` o `authentication failed`.

## Paso 7 — Validacion de sanidad

Ejecutar via Supabase SQL Editor o `psql "$DEST_DB_URL"`:

```sql
-- Conteos esperados (comparar con los reales de produccion)
SELECT 'perfiles' AS tabla, count(*) FROM perfiles
UNION ALL SELECT 'clientes', count(*) FROM clientes
UNION ALL SELECT 'productos', count(*) FROM productos
UNION ALL SELECT 'pedidos', count(*) FROM pedidos
UNION ALL SELECT 'pedido_items', count(*) FROM pedido_items
UNION ALL SELECT 'pagos', count(*) FROM pagos
UNION ALL SELECT 'compras', count(*) FROM compras
UNION ALL SELECT 'compra_items', count(*) FROM compra_items
UNION ALL SELECT 'notas_credito', count(*) FROM notas_credito
UNION ALL SELECT 'audit_logs', count(*) FROM audit_logs
ORDER BY tabla;

-- Validar que las RLS estan activas
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public' AND rowsecurity = false
  AND tablename NOT LIKE 'pg_%';
-- Esperado: 0 filas (todas las tablas con RLS habilitada).

-- Validar que las funciones criticas existen
SELECT count(*) AS funciones_publicas
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public';
-- Esperado: ~73 (segun baseline de migrations/000_baseline.sql).
```

## Paso 8 — Si era drill: documentar y limpiar

Agregar entrada a `scripts/backup/drill-log.md` con:
- Fecha del drill
- Backup usado (fecha del archivo)
- Tiempo total (descarga + decrypt + restore + validacion)
- Conteos: filas restauradas vs filas en prod ese dia
- Anomalias encontradas

Despues:
- Pausar el proyecto staging desde el dashboard (free tier permite proyectos pausados sin costo).
- O eliminarlo si no se reusara: dashboard → Settings → General → Delete project.

## Paso 9 — Si era incidente real

**Para corrupcion total:**
1. Validacion sanidad OK → reapuntar la app:
   - Vercel/Coolify env vars: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` al nuevo proyecto.
   - Edge functions secrets en el proyecto nuevo (`TELEGRAM_BOT_TOKEN`, `GEMINI_API_KEY`, etc.).
   - Re-deployar webhook de Telegram al nuevo proyecto.
2. Comunicar a usuarios la perdida desde el ultimo backup (RPO 24h max).
3. Pausar el proyecto viejo (no eliminar inmediatamente — por si hay datos rescatables).
4. Postmortem dentro de 48h.

**Para borrado accidental quirurgico:**
1. Identificar tablas/filas afectadas.
2. Exportar desde staging con `pg_dump --table=NOMBRE --data-only`.
3. Revisar manualmente antes de importar a produccion.
4. Importar con `psql "$PROD_DB_URL" < export.sql`.

## Tiempos esperados (referencia)

| Paso | Tiempo (volumen actual) |
|---|---|
| Crear proyecto Supabase | 2-3 min (provisioning) |
| Descargar de Drive | 30 s |
| Decrypt | 5 s |
| pg_restore | 1-3 min |
| Validacion | 2 min |
| **Total drill** | **~10 min** |
| **Total con app reapuntada (incidente real)** | **~30 min** |

A medida que crezca la DB, actualizar estas estimaciones.
