# TP Export → ManaosApp Data Import Runbook

Manual, one-shot procedure to migrate the TP Export project's business
data into ManaosApp under `sucursal_id = 2`. Pairs with
`migrations/062_import_tp_export.sql`.

> **Run this ONCE, in a maintenance window, AFTER migrations 057–061 + 063
> are applied in production.** The SQL file is explicitly not idempotent
> and is not part of the normal migration chain.

## Expected volumes (Q1 2026 audit snapshot)

| Entity        | Rows |
|---------------|-----:|
| perfiles      |    7 |
| productos     |   65 |
| clientes      |   86 |
| pedidos       |  142 |
| pedido_items  |  534 |

If live counts are wildly off from these, pause and investigate before
running the import.

## Preconditions

1. **Backups taken.** `pg_dump` on ManaosApp AND TP Export before starting.
2. **Migrations applied.** Verify on ManaosApp:
   ```sql
   SELECT name FROM supabase_migrations.schema_migrations
    WHERE name IN ('060_multi_tenant_fixups','061_session_scoped_tenant','063_usuario_sucursales_admin_rpcs');
   ```
   All three rows must be present.
3. **Users created.** Every TP Export `perfiles.email` must already exist
   in ManaosApp's `auth.users`. Create them via the admin dashboard OR
   Supabase CLI; re-running after creating missing accounts is safe.
4. **FDW credentials.** You have read-only Postgres credentials for the
   TP Export Supabase project. Use the direct connection string from
   Supabase → Project Settings → Database → Connection string → URI.
5. **Sucursal 2 is clean.** Confirm no prior import leftovers:
   ```sql
   SELECT COUNT(*) FROM productos WHERE sucursal_id = 2;
   SELECT COUNT(*) FROM pedidos   WHERE sucursal_id = 2;
   ```
   If non-zero and unintentional, roll back before continuing.

## Procedure

### 1. Open a psql session to ManaosApp

```bash
psql "postgres://postgres.<proj-ref>:<password>@aws-0-us-east-1.pooler.supabase.com:5432/postgres"
```

### 2. Configure FDW

Fill in the placeholders in the header of
`migrations/062_import_tp_export.sql` with real TP credentials, then run
only the `CREATE SERVER` / `CREATE USER MAPPING` / `IMPORT FOREIGN SCHEMA`
block:

```sql
BEGIN;

CREATE EXTENSION IF NOT EXISTS postgres_fdw;

CREATE SERVER tp_remote
  FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '<tp-host>', dbname 'postgres', port '5432', sslmode 'require');

CREATE USER MAPPING FOR postgres
  SERVER tp_remote
  OPTIONS (user 'postgres', password '<tp-password>');

CREATE SCHEMA IF NOT EXISTS tp_remote_schema;

IMPORT FOREIGN SCHEMA public
  LIMIT TO (perfiles, clientes, productos, pedidos, pedido_items)
  FROM SERVER tp_remote INTO tp_remote_schema;

-- Sanity
SELECT COUNT(*) FROM tp_remote_schema.perfiles;

COMMIT;
```

### 3. Fill in the column TODOs in 062

Before running the INSERTs, the skeleton has `-- TODO` markers where the
exact column list must be expanded. Run on BOTH projects:

```sql
SELECT column_name
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND table_name = 'productos'
 ORDER BY ordinal_position;
```

and for each of `productos`, `clientes`, `pedidos`, `pedido_items`. Align
the INSERT column list in 062 with columns that exist on both sides.
Skip columns that exist only on one side — PostgREST will fill defaults.

### 4. Run the import inside a single transaction

```bash
psql "<manaos-uri>" -f migrations/062_import_tp_export.sql --single-transaction
```

The file starts with `BEGIN` implicit via `--single-transaction`. All
INSERTs and temp-table operations happen atomically.

### 5. Verify BEFORE commit

The psql session will leave you at the `\echo` prompt after running the
file. Paste the verification block from the bottom of 062:

```sql
SELECT 'productos'    AS tabla, COUNT(*) FROM public.productos    WHERE sucursal_id = 2
UNION ALL SELECT 'clientes',     COUNT(*) FROM public.clientes     WHERE sucursal_id = 2
UNION ALL SELECT 'pedidos',      COUNT(*) FROM public.pedidos      WHERE sucursal_id = 2
UNION ALL SELECT 'pedido_items', COUNT(*) FROM public.pedido_items WHERE sucursal_id = 2
UNION ALL SELECT 'usuario_sucursales', COUNT(*) FROM public.usuario_sucursales WHERE sucursal_id = 2;
```

Expected: all match the volumes in the header (±10% for rows added
between the audit snapshot and import day). `orphan_items` from the
pedido_items CTE should be 0.

- **If numbers match:** `COMMIT;`
- **If not:** `ROLLBACK;` — the temp tables (`uuid_remap`, `*_remap`) are
  dropped on transaction end anyway. Fix the issue and re-run.

### 6. Smoke test from the app

Log in as a TP Export user (same email, ManaosApp password). The app
should:

1. Show the user with TWO sucursales in the `SucursalSelector` dropdown
   — provided that user was also in ManaosApp — OR only "TP Export" if
   they're new. If they see zero sucursales, step 2 of "Preconditions"
   failed; check `usuario_sucursales` for their local UUID.
2. Switch to TP Export → pedidos list populates with the imported rows.
3. Open one imported pedido — cliente and items render correctly (cliente
   and producto names match the source).

### 7. Clean up FDW

After the import is validated, drop the FDW wiring so service credentials
don't linger:

```sql
DROP SERVER tp_remote CASCADE;
DROP SCHEMA tp_remote_schema CASCADE;
-- postgres_fdw extension can stay; it's harmless without a configured SERVER.
```

## Rollback

Because everything ran inside one transaction, `ROLLBACK;` during step 5
undoes the whole import with no trace. If commit already happened and
rollback is needed:

```sql
BEGIN;
DELETE FROM public.pedido_items      WHERE sucursal_id = 2;
DELETE FROM public.pedidos           WHERE sucursal_id = 2;
DELETE FROM public.clientes          WHERE sucursal_id = 2;
DELETE FROM public.productos         WHERE sucursal_id = 2;
DELETE FROM public.usuario_sucursales WHERE sucursal_id = 2;
-- ^ this last one revokes access; confirm no legitimate non-TP users were
--   also assigned to sucursal 2 before running.
COMMIT;
```

## Known gotchas

- **`numero_pedido` collision.** The dedup in step 5 uses
  `numero_pedido + sucursal_id`. If ManaosApp already issued `numero_pedido`
  values that collide with TP Export's sequence for sucursal 2 (possible
  if sucursal 2 existed before 057), add a `tp_import_marker TEXT` column
  to `pedidos`, set it to `'tp_<src_id>'` during import, and use that for
  dedup instead.
- **Stock drift.** Products imported with a stock value that reflects
  TP Export's closing inventory — not the live warehouse state in sucursal
  2. Plan a stock recount separately.
- **Audit log pollution.** Every INSERT fires `audit_log_changes`. Expect
  ~840 new audit rows. The trigger (post-migration 060) correctly stamps
  them with `sucursal_id = 2` — no cross-tenant leak.
