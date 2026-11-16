# Runbook: restaurar backup de Supabase

**RTO objetivo:** < 30 min desde decision hasta DB restaurada.
**RPO actual:** 24 h (ultimo backup diario, en el servidor Windows). Si el servidor no esta
disponible, el de Drive es mensual: hasta ~31 dias.

> **Restaurar no es sólo `pg_restore`.** Un proyecto Supabase nuevo le da `ALL` a `anon`,
> `authenticated` y `service_role` sobre todo lo que se crea en `public`. Restaurado tal cual,
> todas las funciones de `public` quedan ejecutables con la anon key (575 en el ensayo, 356 de
> ellas `SECURITY DEFINER`, que no pasan por RLS), se pierden los grants por columna y cualquier
> usuario logueado lee los costos de `productos`. Los pasos 6, 8 y 10
> lo evitan, y **ninguno se saltea**. Medido en el ensayo del 16/11: [drill-log.md](drill-log.md).

## Cuando ejecutar este runbook

| Caso | Accion |
|---|---|
| Drill mensual (dia 1) | Restaurar a proyecto staging y comparar conteos. Documentar tiempos. |
| Borrado accidental de datos | Restaurar a staging, exportar tablas afectadas, importar a produccion. NO sobreescribir produccion entera sin pensar. |
| Corrupcion total | Crear proyecto Supabase nuevo, restaurar, reapuntar `VITE_SUPABASE_URL` en deploys. |
| Migracion fallida | Restaurar a produccion si la corrida es muy reciente y no entraron datos nuevos. Sino, restore a staging y reconciliar diff. |

## Prerequisitos locales

- `pg_restore` y `psql` versión 17 instalados (`postgresql-client-17`).
- `gpg` instalado.
- `rclone` configurado con remote `gdrive` (ver [setup.md](setup.md) paso 3).
- Acceso al gestor de contraseñas con `BACKUP_PASSPHRASE distribuidora-app`.
- Acceso al dashboard de Supabase.
- Node 20+ y una copia del repo en `main` (para los chequeos del paso 10; no hace falta `npm ci`).

## Paso 1 — Crear proyecto Supabase de destino

**Para drill o corrupcion total:**
1. https://supabase.com/dashboard → **New project**.
2. Region: `sa-east-1` (mismo que prod, latencia menor).
3. Plan: Free tier OK para drill.
4. Anotar el **project ref** y el **DB password** generado.

**Para borrado accidental (recuperacion quirurgica):**
- Restaurar a un proyecto staging dedicado, no a produccion.

El proyecto tiene que estar **vacío**: el paso 6 va antes de crear cualquier cosa en `public`.

## Paso 2 — Descargar el backup

Decidir que dia restaurar:
- Para drill: el ultimo `daily/` disponible.
- Para incidente: el ultimo backup ANTES del evento que se quiere revertir.

**Desde el servidor Windows** (diarios, semanales y mensuales): estan en el `BackupRoot` de
`C:\ProgramData\distribuidora-backup\config.json`, con la misma estructura
`daily/`, `weekly/`, `monthly/`. Copiar el `.sql.gpg` a la maquina donde se restaura y
seguir desde el paso 3.

**Desde Drive** (solo mensuales):

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

## Paso 6 — Sacarle al destino los privilegios por defecto de fábrica

**Antes** del restore. Un proyecto nuevo trae, para todo lo que `postgres` cree en `public`,
`ALL` para `anon`, `authenticated` y `service_role`. Los GRANT/REVOKE del backup se escriben
contra el default de Postgres, no contra ese: si no se sacan acá, `anon` se queda con todo
aunque después se repongan los permisos (en el ensayo: 575 funciones y 102 tablas para `anon`).

```bash
psql "$DEST_DB_URL" -v ON_ERROR_STOP=1 <<'SQL'
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM postgres, anon, authenticated, service_role;
SQL
```

Los defaults de prod vuelven en el paso 8, con el resto de los permisos.

## Paso 7 — pg_restore

```bash
pg_restore \
  --no-owner \
  --no-acl \
  --verbose \
  --dbname "$DEST_DB_URL" \
  dump.sql 2>&1 | tee restore.log
```

`--no-acl` va igual con los backups nuevos, que sí traen los permisos: se aplican aparte en el
paso 8, sólo los de `public`, para no mezclar sus errores con los de este paso.

**Errores tolerables (esperados).** En el ensayo local fueron 57, todos fuera de `public`:
- `schema "X" already exists` (`auth`, `extensions`, `graphql`, `graphql_public`, `pgbouncer`,
  `realtime`, `storage`, `vault`) y `publication "supabase_realtime" already exists`.
- `must be owner of …` y `permission denied for schema auth` sobre objetos de `auth`: el schema es
  de Supabase.
- `Non-superuser owned event trigger must execute a non-superuser owned function` (los seis event
  triggers de Supabase) y `function … already exists` / `must be owner of function extensions.…`.
- `permission denied for table secrets` (`vault`).
- `role "supabase_admin" does not exist`, o `extension "X" already exists`, si aparecen.

**Errores criticos (parar y diagnosticar):**
- Cualquier `ERROR` sobre un objeto de `public`: tablas de negocio (`pedidos`, `clientes`,
  `productos`, `pagos`, `audit_logs`, etc.), funciones, policies o triggers.
- `connection refused` o `authentication failed`.

Para ver sobre qué objeto fue cada error (lo de `public` tiene que dar vacío):

```bash
awk '/^pg_restore: (creating|processing)/{obj=$0} /error:/{print obj}' restore.log | grep '"public\.'
```

## Paso 8 — Reponer los permisos de `public`

Salen de las entradas `ACL` y `DEFAULT ACL` de un dump: las del mismo backup si las trae, y si no,
de otro. Ningún archivo del repo los guarda.

**Elegir la fuente:**

```bash
pg_restore -l dump.sql | grep -c ' ACL public '
```

- **Más de 0** (backups hechos sin `--no-acl`, desde que entró #1550): la fuente es el mismo
  `dump.sql`. Ver "Qué tiene que hacer el dueño" en [drill-log.md](drill-log.md) para saber desde
  qué fecha.
- **0** (backups viejos): la fuente es otro dump con permisos, en este orden:
  1. si prod sigue viva (borrado accidental, migración fallida):
     `pg_dump --schema-only --format=custom --no-owner --file=acl-fuente.dump "$PROD_DB_URL"`;
  2. si no, el backup con permisos más cercano en fecha (desencriptado como en el paso 4).

**Aplicar** (con `FUENTE=dump.sql` o `FUENTE=acl-fuente.dump`):

```bash
pg_restore -l "$FUENTE" | grep -E '^[0-9]+; [0-9]+ [0-9]+ (ACL|DEFAULT ACL) public ' > acl.list
wc -l < acl.list        # 843 en el ensayo del 16/11
pg_restore --no-owner --use-list=acl.list --dbname "$DEST_DB_URL" "$FUENTE" 2>&1 | tee acl.log
```

Errores esperados: **tres** `permission denied to change default privileges`, de los
`ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin`: esos defaults son de fábrica y no se cambian
desde `postgres`. Cualquier otro error es para mirar.

**Si la fuente no es el mismo backup**, puede no coincidir con él:
- una función del backup que no está en la fuente queda con el `EXECUTE` de `PUBLIC`: el paso 10
  la marca en rojo (`check-permisos`);
- una tabla del backup que no está en la fuente queda sin acceso para la app: falla cerrada
  (42501), y la ve `check-embeds` (paso 10);
- un objeto de la fuente que no está en el backup da `does not exist`: no importa.

**Si ya restauraste sin el paso 6** (por ejemplo, con la versión vieja de este runbook): no hace
falta empezar de cero. Dejá `public` sólo para su dueño, sacá los defaults y aplicá el paso 8:

```bash
psql "$DEST_DB_URL" -v ON_ERROR_STOP=1 <<'SQL'
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
SQL
# y después el bloque del paso 6 y este paso 8
```

(Los avisos `no privileges could be revoked for "unaccent…"` son de la extensión y no importan.)

## Paso 9 — Reponer lo que el backup no trae

El backup es la base. Esto vive afuera y se repone a mano:

**Auth** (lo vigila `check-auth`):
- Authentication → Sign In / Providers → **"Allow new users to sign up" en off**. Un proyecto nuevo
  nace con el signup abierto, y con la anon key cualquiera se registraría.
- Usuarios anónimos apagados.
- Site URL, redirect URLs y SMTP: **a confirmar** (no están en el repo).
- Los usuarios: en el ensayo local las filas de `auth.users` se restauraron (28 de 28) y el trigger
  `on_auth_user_created` quedó puesto, pero el `auth` de la imagen local es más chico que el de un
  proyecto real. Que los usuarios puedan loguearse en el proyecto nuevo: **a confirmar** en el
  primer ensayo real.

**El bucket `facturas`** (lo vigila `check-storage`):
- Crearlo privado (Storage → New bucket, `facturas`, sin "Public bucket") y dejarle la config de la
  migración 239 (`file_size_limit` 8 MB, `allowed_mime_types`).
- Sus tres policies sobre `storage.objects`: copiar el bloque §6 de
  `migrations/463_permisos_activo_storage_y_perfiles.sql` (`facturas_select_encargado_o_admin`,
  `facturas_insert_encargado_o_admin`, `facturas_delete_admin`).
- **Los archivos** (las facturas escaneadas) no están en el backup: viven en el storage del proyecto.
  Si el proyecto viejo sigue accesible, copiarlos; si no, se pierden. Si quedan filas de
  `storage.objects` restauradas sin su archivo: **a confirmar** en el primer ensayo real.
- Si prod tiene otros buckets: **a confirmar** (el front sólo usa `facturas`).

**Edge functions y sus secrets** (al reapuntar, paso 13):
- Deploy de `telegram-webhook`, `telegram-digest`, `optimizar-ruta` y `escanear-factura`:
  `supabase functions deploy --project-ref <ref-nuevo>`. `.github/workflows/deploy-functions.yml`
  tiene el ref de prod fijo (`PROJECT_REF`), igual que la URL de `telegram-digest.yml`.
- Secrets (los lee el código de `supabase/functions/`): `TELEGRAM_BOT_TOKEN`,
  `TELEGRAM_WEBHOOK_SECRET`, `TELEGRAM_DIGEST_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`,
  `GROQ_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_SA_KEY`, `APP_ORIGIN`, y los opcionales `GEMINI_MODEL`,
  `FACTURA_GEMINI_MODEL`, `OPENAI_BASE_URL` y `BOT_*`. `SUPABASE_URL`, `SUPABASE_ANON_KEY` y
  `SUPABASE_SERVICE_ROLE_KEY` los pone Supabase. Cuáles de los opcionales están cargados en prod:
  **a confirmar** (`supabase secrets list` en prod, si sigue viva).
- El webhook de Telegram apunta a la URL de la función: `setWebhook` como dice
  `supabase/functions/README.md`.

**Tareas programadas:** la base no tiene `pg_cron` ni `pg_net` (sus extensiones son
`pg_stat_statements`, `pgcrypto`, `supabase_vault`, `unaccent` y `uuid-ossp`). Las tareas son
workflows de GitHub (`telegram-digest`, `cerrar-recorridos`, `refrescar-ii`, `integridad`,
`eval-bot`, `backup`) y el backup del servidor Windows: al reapuntar, sus secrets
(`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET`, `SUPABASE_DB_URL`) y el
`SupabaseDbUrl` del `config.json` del servidor. Webhooks de base (Database → Webhooks): **a
confirmar** que no haya.

## Paso 10 — Chequeos en verde ANTES de reapuntar

Contra el proyecto restaurado, nunca contra prod. Desde la raíz del repo:

```bash
psql "$DEST_DB_URL" -c "NOTIFY pgrst, 'reload schema'"   # que PostgREST vea los permisos nuevos

export SUPABASE_URL='https://<ref-nuevo>.supabase.co'
export SUPABASE_SERVICE_ROLE_KEY='<service_role del proyecto nuevo: Settings → API>'

node scripts/check-permisos.mjs \
  && node scripts/check-grants-tablas.mjs \
  && node scripts/check-tablas-anon.mjs \
  && node scripts/check-auth.mjs \
  && node scripts/check-storage.mjs \
  && echo 'TODO EN VERDE'
```

Los cinco tienen que terminar en verde (exit 0). **Si uno da rojo, no se reapunta**: se vuelve al
paso que corresponde (permisos → 6 y 8; auth y storage → 9).

- `check-tablas-anon` solo **no** alcanza: con el restore tal cual dio verde (RLS y policies
  siguen frenando la lectura de tablas) mientras `anon` ejecutaba las 356 funciones definer. Los
  que lo ven son `check-permisos` y `check-grants-tablas`.
- `check-grants-tablas` compara contra `scripts/grants-rest.json` de tu copia del repo. Si el
  backup es viejo y el JSON cambió después, una diferencia puede ser del JSON y no del restore:
  compará con el JSON del commit de `main` de la fecha del backup
  (`git log -1 --before=YYYY-MM-DD origin/main`).
- Recomendado, además: `check-embeds` con `SUPABASE_JWT_SECRET` del proyecto nuevo (Settings → API
  → JWT Settings). Prueba cada `select` del front como `authenticated` y ve una tabla que quedó sin
  acceso. No se probó en el ensayo local (necesita PostgREST).
- Si prod sigue viva: correr la etapa 1 de `scripts/concurrencia/huella-esquema.sql` con `psql` en
  las dos bases. En el ensayo, después del paso 8, las 11 categorías dieron iguales.

## Paso 11 — Validacion de sanidad

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

-- Validar que las funciones existen
SELECT count(*) AS funciones_publicas
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public';
-- Esperado: el mismo número que prod (contalo ahí si sigue viva). Referencia: la base del
-- ensayo del 16/11 tenía 579 (575 propias y 4 de la extensión unaccent).
```

## Paso 12 — Si era drill: documentar y limpiar

Agregar entrada a `scripts/backup/drill-log.md` con:
- Fecha del drill
- Backup usado (fecha del archivo)
- Tiempo total (descarga + decrypt + restore + permisos + validacion)
- Conteos: filas restauradas vs filas en prod ese dia
- La salida de los chequeos del paso 10
- Anomalias encontradas

Despues:
- Pausar el proyecto staging desde el dashboard (free tier permite proyectos pausados sin costo).
- O eliminarlo si no se reusara: dashboard → Settings → General → Delete project.

## Paso 13 — Si era incidente real

**Para corrupcion total:**
1. Paso 10 en verde y validacion de sanidad OK → reapuntar la app:
   - Vercel/Coolify env vars: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` al nuevo proyecto.
   - Edge functions: deploy y secrets en el proyecto nuevo (paso 9).
   - Re-deployar webhook de Telegram al nuevo proyecto.
   - Secrets de GitHub, refs fijos de los workflows y `config.json` del servidor Windows (paso 9).
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
| Permisos (pasos 6 y 8) | < 1 min |
| Lo que el backup no trae (paso 9) | 10-15 min (a confirmar en el primer ensayo real) |
| Chequeos y validacion | 2-3 min |
| **Total drill** | **~15 min** |
| **Total con app reapuntada (incidente real)** | **~40 min** |

A medida que crezca la DB, actualizar estas estimaciones.
