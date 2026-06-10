-- Migración 080: Restringir columnas editables de clientes para preventistas
--
-- La política RLS mt_clientes_update permite UPDATE a cualquier rol de
-- es_preventista() sobre TODAS las columnas. La UI (PR #359) acota el patch
-- del preventista a datos de contacto/atención, pero por API directa un
-- preventista podía modificar crédito, descuentos, zona, CUIT, etc.
--
-- Este trigger BEFORE UPDATE bloquea, solo para rol preventista /
-- preventista_taco, los cambios en columnas gestionadas por admin/encargado.
-- Se usa blacklist (no whitelist) a propósito: saldo_cuenta lo actualizan
-- RPCs/triggers de pagos (actualizar_saldo_pedido) que corren bajo el
-- auth.uid() del preventista y no deben romperse.
--
-- Aplicada en prod el 2026-06-10 vía MCP (apply_migration:
-- clientes_guard_update_preventista).

CREATE OR REPLACE FUNCTION public.clientes_guard_update_preventista()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rol text;
  -- Columnas que un preventista NO puede modificar
  v_bloqueadas text[] := ARRAY[
    'id','created_at','cuit','tipo_documento','nombre_fantasia','zona','zona_id',
    'limite_credito','dias_credito','descuento_porcentaje','preventista_id',
    'activo','codigo','sucursal_id','tp_import_id'
  ];
  v_old jsonb := to_jsonb(OLD);
  v_new jsonb := to_jsonb(NEW);
  v_cambiadas text[];
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();

  -- Sin perfil (service role, SQL editor) u otros roles: sin restricción
  IF v_rol IS NULL OR v_rol NOT IN ('preventista', 'preventista_taco') THEN
    RETURN NEW;
  END IF;

  SELECT array_agg(col) INTO v_cambiadas
  FROM unnest(v_bloqueadas) AS col
  WHERE (v_old -> col) IS DISTINCT FROM (v_new -> col);

  IF v_cambiadas IS NOT NULL THEN
    RAISE EXCEPTION 'Un preventista no puede modificar estas columnas de clientes: %',
      array_to_string(v_cambiadas, ', ')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS clientes_guard_update_preventista ON public.clientes;
CREATE TRIGGER clientes_guard_update_preventista
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.clientes_guard_update_preventista();
