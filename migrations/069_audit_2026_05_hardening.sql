-- Migración 069: hardening de seguridad/permisos (Auditoría 2026-05)
-- Cambios reversibles y SIN tocar datos. Ver docs/AUDIT_REPORT_2026-05.md.
-- Proyecto: hmuchlzmuqqxcldbzkgc (ManaosApp).
--
-- Resumen:
--   1) P0  Impide auto-escalada de rol/activo en perfiles (RLS perfiles_update_self
--          permite UPDATE de la propia fila sin restringir columnas).
--   2) P0  RPCs del bot -> solo service_role (la app web no las llama; el bot usa service_role).
--   3) P1  Funciones trigger sin EXECUTE directo (los triggers siguen disparándose).
--   4) P1  Cierra acceso anónimo a RPCs sensibles sin gate interno (se mantiene authenticated).
--   5) P2  search_path fijo en funciones marcadas mutables por el linter.
--   6) P3  Elimina índices duplicados (se conservan los _id).

-- ============================================================
-- 1) P0: anti auto-escalada de rol/activo en perfiles
-- ============================================================
CREATE OR REPLACE FUNCTION public.prevenir_autoescalada_perfil()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- auth.uid() IS NULL => contexto service_role/superuser (migraciones, backend de confianza)
  IF auth.uid() IS NOT NULL AND NOT es_admin()
     AND ( NEW.rol IS DISTINCT FROM OLD.rol
           OR COALESCE(NEW.activo, true) IS DISTINCT FROM COALESCE(OLD.activo, true) ) THEN
    RAISE EXCEPTION 'No autorizado: solo un administrador puede cambiar rol o estado activo';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevenir_autoescalada_perfil ON public.perfiles;
CREATE TRIGGER trg_prevenir_autoescalada_perfil
  BEFORE UPDATE ON public.perfiles
  FOR EACH ROW EXECUTE FUNCTION public.prevenir_autoescalada_perfil();

-- ============================================================
-- 2) P0/P1: RPCs del bot solo ejecutables por service_role
-- ============================================================
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN (
        'bot_buscar_cliente','bot_compras_periodo','bot_ficha_producto',
        'bot_historico_pagos_cliente','bot_historico_pedidos_cliente','bot_metricas_admin_dia',
        'bot_mi_recorrido','bot_mis_clientes','bot_mis_ventas','bot_pendientes_pago',
        'bot_productos_recurrentes_cliente','bot_ranking_preventistas_por_producto',
        'bot_recorrido_resumen','bot_sugerir_visitas_rfm','bot_ventas_periodo',
        'bot_ventas_por_preventista','crear_pedido_completo_bot',
        'canjear_codigo_vinculacion_bot','obtener_resumen_cuenta_cliente_bot')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
  END LOOP;
END $$;

-- ============================================================
-- 3) P1: funciones trigger sin EXECUTE directo (los triggers siguen funcionando)
-- ============================================================
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_type t ON t.oid = p.prorettype
    WHERE p.pronamespace = 'public'::regnamespace AND t.typname = 'trigger'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END $$;

-- ============================================================
-- 4) P1: cerrar acceso anónimo a RPCs sensibles sin gate interno
--    (se mantiene authenticated; el gate de rol/sucursal queda como follow-up; ver informe)
-- ============================================================
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN (
        'actualizar_orden_entrega_batch','aplicar_uso_promo_acumulador','limpiar_orden_entrega',
        'obtener_estadisticas_rendiciones','obtener_resumen_compras','pedido_bundle_para_promo',
        'revertir_bloques_auto_ajuste')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', r.sig);
  END LOOP;
END $$;

-- ============================================================
-- 5) P2: search_path fijo en funciones mutables
-- ============================================================
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('f_unaccent','categorias_set_updated_at','registrar_cambio_stock','haversine_m')
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', r.sig);
  END LOOP;
END $$;

-- ============================================================
-- 6) P3: eliminar índices duplicados (mismas columnas; se conservan los _id de la mig 054)
-- ============================================================
DROP INDEX IF EXISTS public.idx_compra_items_compra;
DROP INDEX IF EXISTS public.idx_mermas_producto;
DROP INDEX IF EXISTS public.idx_pagos_fecha;          -- duplicado de idx_pagos_created_at (ambos sobre created_at)
DROP INDEX IF EXISTS public.idx_pedido_items_pedido;
DROP INDEX IF EXISTS public.idx_pedidos_cliente;
DROP INDEX IF EXISTS public.idx_rendicion_items_rendicion;
