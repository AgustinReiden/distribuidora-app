-- Migración 080: Proteger columnas sensibles de clientes ante preventistas
--
-- La política mt_clientes_update usa es_preventista() (admin, preventista,
-- preventista_taco, encargado) en USING/WITH CHECK, así que un preventista
-- puede hacer UPDATE de CUALQUIER columna de clientes vía PostgREST
-- (limite_credito, dias_credito, descuento_porcentaje, zona_id, cuit,
-- preventista_id, etc.) aunque la UI (PR #359) solo patchea datos de contacto.
--
-- Este trigger BEFORE UPDATE rechaza, para los roles preventista y
-- preventista_taco, cualquier cambio fuera de la lista blanca de columnas de
-- contacto. Admin y encargado quedan sin restricción.
--
-- Exenciones (para no romper flujos existentes):
--  * current_user <> 'authenticated': las RPCs SECURITY DEFINER (corren como
--    postgres: crear_pedido_completo, registrar_pago_cliente_fifo,
--    registrar_cambio_producto, ...) y el service_role del bot quedan exentas.
--  * pg_trigger_depth() > 1: updates en cascada desde otros triggers — p.ej.
--    trigger_actualizar_saldo_pedido (pedidos) mantiene clientes.saldo_cuenta
--    con una función SECURITY INVOKER que hereda la identidad del preventista.
--
-- Lista blanca (allow-list, fail-closed): una columna nueva en clientes queda
-- protegida por defecto hasta que se agregue acá explícitamente.

BEGIN;

CREATE OR REPLACE FUNCTION public.clientes_proteger_columnas_preventista()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_rol text;
  v_bloqueadas text;
BEGIN
  -- RPCs SECURITY DEFINER, service_role, conexiones directas: exentas.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- Cascadas desde otros triggers (saldo_cuenta desde pedidos): exentas.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();

  IF v_rol IS NULL OR v_rol NOT IN ('preventista', 'preventista_taco') THEN
    RETURN NEW;  -- admin y encargado sin restricción
  END IF;

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key NOT IN (
      'razon_social', 'direccion', 'aclaracion_direccion', 'latitud',
      'longitud', 'telefono', 'contacto', 'horarios_atencion', 'rubro', 'notas'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'El rol % no puede modificar estas columnas de clientes: %',
      v_rol, v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clientes_proteger_columnas ON public.clientes;
CREATE TRIGGER trg_clientes_proteger_columnas
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.clientes_proteger_columnas_preventista();

COMMIT;
