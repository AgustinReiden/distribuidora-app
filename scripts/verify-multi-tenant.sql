-- Multi-tenant migration verification script
--
-- Run this after applying migrations 057 → 063 to confirm every fix
-- from the audit plan (nested-gliding-crown) landed correctly.
--
-- Usage (local Supabase CLI):
--   cd .claude/worktrees/unruffled-borg
--   supabase start
--   supabase db reset              -- applies 001 → 063 in order
--   psql "$(supabase status -o json | jq -r '.DB_URL // .db_url')" \
--        -f scripts/verify-multi-tenant.sql
--
-- Or paste blocks into the Supabase SQL editor on a preview branch.
--
-- Each check RAISEs NOTICE on success and RAISE EXCEPTION on failure, so
-- the script aborts at the first broken invariant. If it finishes with
-- "🎉 All multi-tenant checks passed", you're clear to merge.

\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

-- =====================================================================
-- Migration 060 — structural fixups (C1/C2/C3, H6/H7/H8)
-- =====================================================================

-- C1: sucursales id=1 renamed, id=2 is TP Export, others are distribuidora
DO $$
DECLARE v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM sucursales
   WHERE id = 1 AND nombre = 'ManaosApp' AND tipo = 'principal';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'C1 FAILED: sucursal id=1 is not ManaosApp/principal (got % rows)', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
    FROM sucursales
   WHERE id = 2 AND nombre = 'TP Export' AND tipo = 'secundaria';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'C1 FAILED: sucursal id=2 is not TP Export/secundaria (got % rows)', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
    FROM sucursales
   WHERE id NOT IN (1, 2) AND tipo IS DISTINCT FROM 'distribuidora';
  IF v_count > 0 THEN
    RAISE EXCEPTION 'C1 FAILED: % sucursales with id>2 have tipo != distribuidora', v_count;
  END IF;

  RAISE NOTICE '✓ C1: sucursales tipos correctly seeded';
END $$;

-- stock_historico.usuario_id column exists (for 059 trigger)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'stock_historico' AND column_name = 'usuario_id'
  ) THEN
    RAISE EXCEPTION '060 FAILED: stock_historico.usuario_id column missing';
  END IF;
  RAISE NOTICE '✓ stock_historico.usuario_id column exists';
END $$;

-- C2: exactly one overload of registrar_compra_completa with 13 args
DO $$
DECLARE v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM pg_proc
   WHERE proname = 'registrar_compra_completa' AND pronargs = 13;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'C2 FAILED: expected 1 registrar_compra_completa(13 args), found %', v_count;
  END IF;
  RAISE NOTICE '✓ C2: registrar_compra_completa 13-arg overload is unique';
END $$;

-- H8: registrar_nota_credito has the es_encargado_o_admin check
DO $$
DECLARE v_src TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src
    FROM pg_proc WHERE proname = 'registrar_nota_credito';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'H8 FAILED: registrar_nota_credito not found';
  END IF;
  IF v_src NOT LIKE '%es_encargado_o_admin%' THEN
    RAISE EXCEPTION 'H8 FAILED: registrar_nota_credito missing role guard';
  END IF;
  RAISE NOTICE '✓ H8: registrar_nota_credito enforces es_encargado_o_admin';
END $$;

-- H7: audit_log_changes no longer COALESCEs to sucursal_id = 1
DO $$
DECLARE v_src TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src
    FROM pg_proc WHERE proname = 'audit_log_changes';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'H7 FAILED: audit_log_changes not found';
  END IF;
  IF v_src LIKE '%COALESCE(v_sucursal_id, 1)%' THEN
    RAISE EXCEPTION 'H7 FAILED: audit_log_changes still has silent fallback to sucursal_id=1';
  END IF;
  IF v_src NOT LIKE '%cannot determine sucursal_id for table%' THEN
    RAISE EXCEPTION 'H7 FAILED: audit_log_changes missing RAISE EXCEPTION for NULL sucursal_id';
  END IF;
  RAISE NOTICE '✓ H7: audit_log_changes fails loud instead of silent fallback';
END $$;

-- H6: no legacy (non-mt_) policies survived on the tenant-filtered tables
DO $$
DECLARE v_count INT; v_list TEXT;
BEGIN
  SELECT COUNT(*),
         string_agg(tablename || '.' || policyname, ', ')
    INTO v_count, v_list
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN (
       'clientes','productos','pedidos','pedido_items','pagos','compras','compra_items',
       'proveedores','mermas_stock','stock_historico','recorridos','recorrido_pedidos',
       'rendiciones','rendicion_items','rendicion_ajustes','salvedades_items','salvedad_historial',
       'notas_credito','nota_credito_items','transferencias_stock','transferencia_items',
       'promociones','promocion_productos','promocion_reglas','promo_ajustes',
       'grupos_precio','grupo_precio_productos','grupo_precio_escalas',
       'pedidos_eliminados','audit_logs','zonas','preventista_zonas','historial_cambios','pedido_historial'
     )
     AND policyname NOT LIKE 'mt\_%' ESCAPE '\'
     AND policyname NOT IN ('usuario_sucursales_select_own','usuario_sucursales_admin_all');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'H6 FAILED: % legacy policies survived: %', v_count, v_list;
  END IF;
  RAISE NOTICE '✓ H6: no legacy RLS policies leaking past tenant filter';
END $$;

-- =====================================================================
-- Migration 061 — session-scoped current_sucursal_id()
-- =====================================================================

-- The function body reads request.headers and validates against usuario_sucursales.
DO $$
DECLARE v_src TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src
    FROM pg_proc WHERE proname = 'current_sucursal_id';
  IF v_src NOT LIKE '%request.headers%' THEN
    RAISE EXCEPTION 'H10 FAILED: current_sucursal_id does not read request.headers';
  END IF;
  IF v_src NOT LIKE '%x-sucursal-id%' THEN
    RAISE EXCEPTION 'H10 FAILED: current_sucursal_id does not parse x-sucursal-id';
  END IF;
  IF v_src NOT LIKE '%usuario_sucursales%' THEN
    RAISE EXCEPTION 'H10 FAILED: current_sucursal_id missing usuario_sucursales authorization check';
  END IF;
  RAISE NOTICE '✓ H10 (DB): current_sucursal_id reads header and validates ownership';
END $$;

-- Functional test: header present + authorized → returns the value
-- (Requires an auth.users row + usuario_sucursales row. Only runs if we
-- can find one; otherwise noted and skipped.)
DO $$
DECLARE v_user UUID; v_sucursal BIGINT; v_result BIGINT;
BEGIN
  SELECT us.usuario_id, us.sucursal_id
    INTO v_user, v_sucursal
    FROM usuario_sucursales us
   LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE '– H10 functional test skipped: no usuario_sucursales rows to simulate';
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.headers', format('{"x-sucursal-id":"%s"}', v_sucursal), true);
  v_result := current_sucursal_id();
  IF v_result IS DISTINCT FROM v_sucursal THEN
    RAISE EXCEPTION 'H10 FAILED: header %s → expected %, got %', v_sucursal, v_sucursal, v_result;
  END IF;

  -- Now simulate a forged header for a sucursal the user does NOT have.
  PERFORM set_config('request.headers', '{"x-sucursal-id":"99999"}', true);
  v_result := current_sucursal_id();
  IF v_result IS NOT NULL THEN
    RAISE EXCEPTION 'H10 FAILED: unauthorized header returned % instead of NULL', v_result;
  END IF;

  RAISE NOTICE '✓ H10 functional: header authorized → %, forged → NULL', v_sucursal;
END $$;

-- =====================================================================
-- Migration 063 — admin RPCs for usuario_sucursales
-- =====================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'asignar_usuario_sucursal') THEN
    RAISE EXCEPTION '063 FAILED: asignar_usuario_sucursal not found';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'desasignar_usuario_sucursal') THEN
    RAISE EXCEPTION '063 FAILED: desasignar_usuario_sucursal not found';
  END IF;
  RAISE NOTICE '✓ 063: admin RPCs present';
END $$;

-- Both should be SECURITY DEFINER + gated by es_admin()
DO $$
DECLARE v_src TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src FROM pg_proc WHERE proname = 'asignar_usuario_sucursal';
  IF v_src NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION '063 FAILED: asignar_usuario_sucursal is not SECURITY DEFINER';
  END IF;
  IF v_src NOT LIKE '%es_admin()%' THEN
    RAISE EXCEPTION '063 FAILED: asignar_usuario_sucursal missing es_admin() guard';
  END IF;

  SELECT pg_get_functiondef(oid) INTO v_src FROM pg_proc WHERE proname = 'desasignar_usuario_sucursal';
  IF v_src NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION '063 FAILED: desasignar_usuario_sucursal is not SECURITY DEFINER';
  END IF;
  IF v_src NOT LIKE '%es_admin()%' THEN
    RAISE EXCEPTION '063 FAILED: desasignar_usuario_sucursal missing es_admin() guard';
  END IF;
  RAISE NOTICE '✓ 063: admin RPCs are SECURITY DEFINER and gated by es_admin()';
END $$;

-- =====================================================================
-- Cross-migration sanity
-- =====================================================================

-- Every public table that stores per-tenant rows must have a sucursal_id column.
-- This catches drift where a new table was added without the tenant column.
DO $$
DECLARE v_missing TEXT;
BEGIN
  SELECT string_agg(t.table_name, ', ')
    INTO v_missing
    FROM information_schema.tables t
   WHERE t.table_schema = 'public'
     AND t.table_type = 'BASE TABLE'
     AND t.table_name IN (
       'clientes','productos','pedidos','pedido_items','pagos','compras','compra_items',
       'mermas_stock','stock_historico','recorridos','rendiciones','rendicion_items',
       'salvedades_items','notas_credito','nota_credito_items',
       'transferencias_stock','transferencia_items',
       'promociones','grupos_precio','pedidos_eliminados','audit_logs'
     )
     AND NOT EXISTS (
       SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = t.table_schema
          AND c.table_name = t.table_name
          AND c.column_name = 'sucursal_id'
     );
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'SCHEMA DRIFT: tables without sucursal_id: %', v_missing;
  END IF;
  RAISE NOTICE '✓ All expected tenant tables have sucursal_id';
END $$;

-- usuario_sucursales has the unique (usuario_id, sucursal_id) constraint
-- needed by the ON CONFLICT in asignar_usuario_sucursal.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'usuario_sucursales'::regclass
       AND contype = 'u'
       AND (SELECT array_agg(attname ORDER BY attname) FROM pg_attribute
             WHERE attrelid = 'usuario_sucursales'::regclass
               AND attnum = ANY(conkey)) = ARRAY['sucursal_id','usuario_id']::name[]
  ) THEN
    RAISE EXCEPTION '063 FAILED: usuario_sucursales missing UNIQUE(usuario_id, sucursal_id) for ON CONFLICT';
  END IF;
  RAISE NOTICE '✓ usuario_sucursales has UNIQUE(usuario_id, sucursal_id)';
END $$;

-- =====================================================================
-- Done
-- =====================================================================
DO $$
BEGIN
  RAISE NOTICE '🎉 All multi-tenant checks passed';
END $$;
