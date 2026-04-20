-- Migration 062: Import TP Export data into ManaosApp with sucursal_id=2
--
-- =====================================================================
--  DO NOT RUN THIS AS PART OF THE NORMAL MIGRATION CHAIN.
-- =====================================================================
--
-- This script is intentionally NOT idempotent and is intended to be run
-- ONCE, manually, in a maintenance window, AFTER:
--   1. Migrations 057 → 058 → 059 → 060 → 061 → 063 are applied.
--   2. All target users (the 7 TP Export perfiles) already exist in
--      ManaosApp's auth.users (same email — Supabase will assign a new UUID).
--   3. You have postgres_fdw-level credentials to read from the TP Export
--      Supabase project.
--
-- Expected volumes (Q1 2026 snapshot, per audit):
--   perfiles:       7
--   productos:     65
--   clientes:      86
--   pedidos:      142
--   pedido_items: 534
--
-- Strategy: map TP Export auth.uid values → ManaosApp auth.uid by JOINing
-- on email, then rewrite every user_id / usuario_id reference during
-- INSERT. All imported rows get sucursal_id = 2.
--
-- See scripts/export-tp-export-dump.md for the full runbook.

-- =====================================================================
-- STEP 0. Prerequisites
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- IMPORTANT: fill in the real connection details before running.
-- Use a read-only role on the source project.
--
-- CREATE SERVER tp_remote
--   FOREIGN DATA WRAPPER postgres_fdw
--   OPTIONS (host '<tp-project-db-host>', dbname 'postgres', port '5432', sslmode 'require');
--
-- CREATE USER MAPPING FOR postgres
--   SERVER tp_remote
--   OPTIONS (user 'postgres', password '<tp-project-password>');
--
-- CREATE SCHEMA IF NOT EXISTS tp_remote_schema;
--
-- IMPORT FOREIGN SCHEMA public
--   LIMIT TO (perfiles, clientes, productos, pedidos, pedido_items)
--   FROM SERVER tp_remote INTO tp_remote_schema;

-- Sanity check — the foreign schema must be importable.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.schemata WHERE schema_name = 'tp_remote_schema'
  ) THEN
    RAISE EXCEPTION 'tp_remote_schema not found — run IMPORT FOREIGN SCHEMA first (see header)';
  END IF;
END $$;

-- =====================================================================
-- STEP 1. UUID remap (auth.users: TP → ManaosApp by email)
-- =====================================================================
-- Uses auth.users from BOTH instances; source UUIDs are stored on foreign
-- rows (perfiles.id mirrors auth.users.id in Supabase).
CREATE TEMP TABLE uuid_remap ON COMMIT PRESERVE ROWS AS
SELECT
  tp.id     AS tp_uuid,
  local.id  AS local_uuid,
  local.email
FROM tp_remote_schema.perfiles AS tp
JOIN public.perfiles           AS local ON local.email = tp.email;

-- Fail loud if any TP user has no matching local account — importing rows
-- whose owner is NULL would strand them outside RLS.
DO $$
DECLARE v_missing INT;
BEGIN
  SELECT COUNT(*) INTO v_missing
    FROM tp_remote_schema.perfiles tp
   WHERE NOT EXISTS (SELECT 1 FROM public.perfiles p WHERE p.email = tp.email);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'TP Export has % perfiles without a matching local account — create those auth.users first and re-run', v_missing;
  END IF;
END $$;

-- =====================================================================
-- STEP 2. usuario_sucursales — grant TP users access to sucursal 2
-- =====================================================================
-- Role stays 'mismo' so they inherit their perfiles.rol; es_default=false
-- (admin can flip it later via asignar_usuario_sucursal from migration 063).
INSERT INTO public.usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
SELECT rm.local_uuid, 2, 'mismo', false
  FROM uuid_remap rm
ON CONFLICT (usuario_id, sucursal_id) DO NOTHING;

-- =====================================================================
-- STEP 3. Productos
-- =====================================================================
-- Match by codigo (the product SKU). Rows with a codigo that already
-- exists in sucursal 2 are assumed to have been imported previously.
--
-- TODO(operator): after running `SELECT column_name FROM
-- information_schema.columns WHERE table_name='productos'` on BOTH
-- projects, expand this SELECT to the actual column list that matches
-- between source and target. Keep it explicit — `SELECT *` across
-- postgres_fdw is a footgun because column order drift corrupts data.
INSERT INTO public.productos (
  nombre, codigo, stock, costo_sin_iva, costo_con_iva, precio_venta,
  activo, sucursal_id
  -- TODO: add remaining columns in schema order
)
SELECT
  src.nombre,
  src.codigo,
  src.stock,
  src.costo_sin_iva,
  src.costo_con_iva,
  src.precio_venta,
  COALESCE(src.activo, true),
  2
FROM tp_remote_schema.productos AS src
WHERE NOT EXISTS (
  SELECT 1 FROM public.productos p
   WHERE p.codigo = src.codigo AND p.sucursal_id = 2
);

-- Stash id remap so pedido_items can resolve new product IDs.
CREATE TEMP TABLE producto_remap ON COMMIT PRESERVE ROWS AS
SELECT src.id AS tp_id, local.id AS local_id
FROM tp_remote_schema.productos src
JOIN public.productos local
  ON local.codigo = src.codigo
 AND local.sucursal_id = 2;

-- =====================================================================
-- STEP 4. Clientes
-- =====================================================================
-- TODO(operator): expand column list (see productos TODO above). cuit
-- is assumed unique within the tenant; adjust if collisions occur.
INSERT INTO public.clientes (
  razon_social, nombre_fantasia, direccion, telefono, cuit, zona,
  sucursal_id, usuario_id
  -- TODO: remaining columns
)
SELECT
  src.razon_social,
  src.nombre_fantasia,
  src.direccion,
  src.telefono,
  src.cuit,
  src.zona,
  2,
  rm.local_uuid
FROM tp_remote_schema.clientes AS src
LEFT JOIN uuid_remap rm ON rm.tp_uuid = src.usuario_id
WHERE NOT EXISTS (
  SELECT 1 FROM public.clientes c
   WHERE c.cuit = src.cuit AND c.sucursal_id = 2
);

CREATE TEMP TABLE cliente_remap ON COMMIT PRESERVE ROWS AS
SELECT src.id AS tp_id, local.id AS local_id
FROM tp_remote_schema.clientes src
JOIN public.clientes local
  ON local.cuit = src.cuit
 AND local.sucursal_id = 2;

-- =====================================================================
-- STEP 5. Pedidos
-- =====================================================================
-- Pedidos carry cliente_id (FK) and usuario_id (auth.uid). Both must be
-- remapped. `numero_pedido` is kept as-is so operators can cross-reference
-- the old system by ticket number; if ManaosApp generates its own sequence,
-- remove it and let the INSERT default pick a new one.
--
-- TODO(operator): expand column list. The fields below are the minimum
-- known to exist from migrations 001/008; verify with information_schema.
INSERT INTO public.pedidos (
  cliente_id, usuario_id, numero_pedido, fecha, estado, total,
  sucursal_id
  -- TODO: remaining columns (notas, forma_pago, etc.)
)
SELECT
  cr.local_id,
  rm.local_uuid,
  src.numero_pedido,
  src.fecha,
  src.estado,
  src.total,
  2
FROM tp_remote_schema.pedidos AS src
JOIN cliente_remap cr ON cr.tp_id = src.cliente_id
LEFT JOIN uuid_remap rm ON rm.tp_uuid = src.usuario_id
WHERE NOT EXISTS (
  -- Skip already-imported pedidos. If `numero_pedido` is not unique across
  -- tenants, replace with a dedicated tp_import_marker column.
  SELECT 1 FROM public.pedidos p
   WHERE p.numero_pedido = src.numero_pedido AND p.sucursal_id = 2
);

CREATE TEMP TABLE pedido_remap ON COMMIT PRESERVE ROWS AS
SELECT src.id AS tp_id, local.id AS local_id
FROM tp_remote_schema.pedidos src
JOIN public.pedidos local
  ON local.numero_pedido = src.numero_pedido
 AND local.sucursal_id = 2;

-- =====================================================================
-- STEP 6. Pedido_items (534 rows)
-- =====================================================================
-- Both pedido_id and producto_id need remapping. If a producto was not
-- imported (missing codigo on source), the row is dropped — inspect the
-- RAISE NOTICE below before the COMMIT to confirm zero orphans.
WITH dropped AS (
  SELECT src.id
    FROM tp_remote_schema.pedido_items AS src
   WHERE NOT EXISTS (
     SELECT 1 FROM producto_remap pr WHERE pr.tp_id = src.producto_id
   )
     OR NOT EXISTS (
     SELECT 1 FROM pedido_remap pe   WHERE pe.tp_id = src.pedido_id
   )
)
SELECT COUNT(*) AS orphan_items FROM dropped;  -- inspect before COMMIT

INSERT INTO public.pedido_items (
  pedido_id, producto_id, cantidad, precio_unitario, sucursal_id
  -- TODO: remaining columns (bonificacion, subtotal, etc.)
)
SELECT
  pe.local_id,
  pr.local_id,
  src.cantidad,
  src.precio_unitario,
  2
FROM tp_remote_schema.pedido_items AS src
JOIN producto_remap pr ON pr.tp_id = src.producto_id
JOIN pedido_remap   pe ON pe.tp_id = src.pedido_id;

-- =====================================================================
-- STEP 7. Post-import verification (run BEFORE COMMIT in psql)
-- =====================================================================
-- Each SELECT should return >0 and match the expected volume from the
-- header comment, except orphan_items which should be 0.
--
-- SELECT 'productos' AS tabla, COUNT(*) FROM public.productos WHERE sucursal_id = 2
-- UNION ALL SELECT 'clientes',  COUNT(*) FROM public.clientes  WHERE sucursal_id = 2
-- UNION ALL SELECT 'pedidos',   COUNT(*) FROM public.pedidos   WHERE sucursal_id = 2
-- UNION ALL SELECT 'pedido_items', COUNT(*) FROM public.pedido_items WHERE sucursal_id = 2
-- UNION ALL SELECT 'usuario_sucursales (sucursal 2)', COUNT(*) FROM public.usuario_sucursales WHERE sucursal_id = 2;
--
-- If numbers match: COMMIT;
-- If not: ROLLBACK; and investigate with the orphan_items CTE above.
