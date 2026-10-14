-- #1155, #1156 y #1151 (punto 5) · Columnas que un PATCH REST no puede mover:
-- la fecha del pedido, el saldo de cuenta y el crédito del cliente.
--
-- EL BUG
--   · #1155 · pedidos_proteger_columnas (mig 233) no bloquea `pedidos.fecha`:
--     el preventista dueño de un pedido la puede cambiar por PATCH. La venta
--     por vendedor y la comisión se atribuyen por esa fecha (migs 241/318), y
--     desde #1137 también la vigencia de la promo en la edición (mig 362).
--     En audit_logs ningún preventista ni encargado cambió jamás la fecha de
--     un pedido: los 158 cambios son de admin o de rol null.
--   · #1156 · clientes.descuento_porcentaje, limite_credito y dias_credito los
--     puede PATCHear cualquiera que pase mt_clientes_update: el encargado
--     siempre (clientes_proteger_columnas_preventista sólo frena a
--     perfiles.rol = 'preventista'), y el preventista en el ALTA, que no tiene
--     guard de columnas (puede crear un cliente con descuento 100). El UI dice
--     «Solo el administrador puede editar estos valores» y sólo un admin los
--     cambió en audit_logs (2, 4 y 30 veces). El descuento baja el piso de
--     precio que calcula precio_fuera_de_politica (mig 363).
--     cliente_descuentos_categoria ya es sólo del admin (cdc_insert /
--     cdc_delete exigen es_admin()): no se toca.
--   · #1151.5 · clientes.saldo_cuenta lo mantienen los pedidos y los pagos
--     (actualizar_saldo_cliente DEFINER, actualizar_saldo_pedido como cascada),
--     pero un admin o un encargado lo puede PATCHear, y cualquiera que dé de
--     alta un cliente lo puede crear con saldo ≠ 0. CC-A lo ve después.
--
-- EL ARREGLO (decisiones del dueño, 2026-10-14: #1155 opción a, #1156 opción a)
--   1 · Trigger nuevo BEFORE INSERT OR UPDATE en clientes,
--       clientes_saldo_y_credito_solo_admin():
--       · saldo_cuenta: nadie lo escribe por REST, admin incluido (UPDATE: no
--         cambia; INSERT: nace en 0).
--       · descuento_porcentaje, limite_credito, dias_credito: sólo es_admin()
--         (UPDATE: no cambian; INSERT: los defaults de columna 0 / 0 / 30).
--       · Exentos, como clientes_reservado_solo_admin: current_user distinto
--         de authenticated (RPC DEFINER, service_role del bot) y
--         pg_trigger_depth() > 1 (la cascada de saldo desde pedidos/pagos).
--       Se compara OLD con NEW: un PATCH que reenvía el valor vigente pasa.
--       El nombre lo hace disparar después de trg_clientes_proteger_columnas
--       (orden alfabético), así el preventista conserva su mensaje de siempre.
--       es_admin() y no es_preventista() / es_encargado_o_admin() (trampa 4).
--   2 · pedidos_proteger_columnas(): 'fecha' entra a la lista de columnas
--       bloqueadas de la rama general (quien no es admin, encargado ni
--       transportista). La rama del transportista ya la bloqueaba. El front le
--       esconde el input al preventista (otro cambio); sin eso, el que intente
--       cambiarla recibe este 42501. ModalEditarPedido manda la fecha aunque no
--       cambie: igual a la vigente, pasa.
--
-- NO CAMBIA
--   · clientes_proteger_columnas_preventista ni ningún otro trigger de
--     clientes; el trigger de pedidos (BEFORE INSERT OR UPDATE) y el ACL de
--     pedidos_proteger_columnas (CREATE OR REPLACE lo conserva).
--   · Ningún GRANT de tabla: el nivel de clientes queda como está.
--   · STK-F / STK-D / COSTO-D / CC-A: no se mueve stock, costo ni saldo.
--
-- Exposición en prod al escribir esto: 0 clientes con descuento > 0, 0 con
-- limite_credito > 0; CC-A en 0. Sin backfill.
--
-- Ensayo: scripts/test-columnas-protegidas-1151-1155-1156.sql (falla antes,
-- pasa después).

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------- 1 · trigger de clientes ---
CREATE FUNCTION public.clientes_saldo_y_credito_solo_admin()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
  -- RPC DEFINER (corren como postgres) y service_role (el bot): exentos.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- La cascada de saldo desde pedidos y pagos llega a profundidad > 1.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF COALESCE(NEW.saldo_cuenta, 0) <> 0 THEN
      RAISE EXCEPTION 'El saldo de cuenta lo calcula el sistema: un cliente nuevo nace con saldo 0'
        USING ERRCODE = '42501';
    END IF;
    -- #1156: los defaults de columna (0 / 0 / 30) son lo único que un
    -- no-admin puede mandar en el alta.
    IF NOT es_admin() AND (NEW.descuento_porcentaje <> 0
                           OR COALESCE(NEW.limite_credito, 0) <> 0
                           OR COALESCE(NEW.dias_credito, 30) <> 30) THEN
      RAISE EXCEPTION 'Sólo un administrador puede fijar descuento, límite o días de crédito de un cliente'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  -- #1151.5: el saldo lo mantienen los pedidos y los pagos, para todos.
  IF NEW.saldo_cuenta IS DISTINCT FROM OLD.saldo_cuenta THEN
    RAISE EXCEPTION 'El saldo de cuenta lo mantienen los pedidos y los pagos: no se edita a mano'
      USING ERRCODE = '42501';
  END IF;

  -- #1156: descuento, límite y días de crédito, sólo el admin.
  IF NOT es_admin() AND (NEW.descuento_porcentaje IS DISTINCT FROM OLD.descuento_porcentaje
                         OR NEW.limite_credito IS DISTINCT FROM OLD.limite_credito
                         OR NEW.dias_credito IS DISTINCT FROM OLD.dias_credito) THEN
    RAISE EXCEPTION 'Sólo un administrador puede cambiar descuento, límite o días de crédito de un cliente'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END
$fn$;

COMMENT ON FUNCTION public.clientes_saldo_y_credito_solo_admin() IS
  '#1151.5 / #1156 · Por REST nadie escribe saldo_cuenta, y descuento_porcentaje, limite_credito y dias_credito sólo el admin. Exentos: current_user <> authenticated y pg_trigger_depth() > 1.';

-- Función de trigger: la invoca el executor, no el caller. Queda en postgres +
-- service_role (CLAUDE.md).
REVOKE ALL ON FUNCTION public.clientes_saldo_y_credito_solo_admin() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_clientes_saldo_y_credito_solo_admin
  BEFORE INSERT OR UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_saldo_y_credito_solo_admin();

-- ------------------------------------------- 2 · pedidos_proteger_columnas ---
-- La de prod (= 233) con 'fecha' en la lista de la rama general.
CREATE OR REPLACE FUNCTION public.pedidos_proteger_columnas()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_bloqueadas text;
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  -- ---- Alta: la venta es de quien la carga (mig 219, issue #549) ----------
  IF TG_OP = 'INSERT' THEN
    IF NEW.usuario_id IS NOT NULL AND NEW.usuario_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Un pedido se atribuye a quien lo carga: no podés crear uno a nombre de otro usuario (usuario_id %). Solo un administrador o encargado puede hacerlo.',
        NEW.usuario_id
        USING ERRCODE = '42501';
    END IF;

    -- Mig 233 (a): `creado_por` es la autoría de la CARGA. Misma regla.
    IF NEW.creado_por IS NOT NULL AND NEW.creado_por IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'No podés registrar un pedido como cargado por otro usuario (creado_por %). Solo un administrador o encargado puede hacerlo.',
        NEW.creado_por
        USING ERRCODE = '42501';
    END IF;

    -- Mig 233 (b): se ASIGNA, no se rechaza (molde de pagos_forzar_usuario, 190b).
    IF NEW.usuario_id IS NULL THEN
      NEW.usuario_id := auth.uid();
    END IF;

    RETURN NEW;
  END IF;

  -- ---- De acá abajo es UPDATE (usa OLD) ----------------------------------
  IF es_transportista() THEN
    SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
    FROM jsonb_each(to_jsonb(OLD)) o
    JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
    WHERE o.value IS DISTINCT FROM n.value
      AND o.key NOT IN ('estado', 'fecha_entrega', 'updated_at');

    IF v_bloqueadas IS NOT NULL THEN
      RAISE EXCEPTION 'Un transportista solo puede confirmar la entrega. Columnas rechazadas: %',
        v_bloqueadas
        USING ERRCODE = '42501';
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado AND NEW.estado <> 'entregado' THEN
      RAISE EXCEPTION 'Un transportista solo puede marcar la entrega, no pasar el pedido a "%"',
        NEW.estado
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  -- #1155: 'fecha' (la del pedido, no la de entrega) sólo la cambian admin y
  -- encargado: la venta por vendedor y la comisión se atribuyen por ella
  -- (migs 241/318), y la vigencia de la promo en la edición también (#1137).
  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key IN (
      'total', 'total_neto', 'total_iva', 'total_real', 'monto_pagado',
      'estado_pago', 'cliente_id', 'sucursal_id', 'usuario_id', 'creado_por',
      'preventista_id', 'tipo_factura', 'stock_descontado', 'offline_id',
      'fecha'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'No tenes permiso para modificar estas columnas de pedidos: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

-- ------------------------------------------------ verificación post-DDL ---
DO $verif$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.clientes'::regclass
                    AND tgname = 'trg_clientes_saldo_y_credito_solo_admin'
                    AND tgfoid = 'public.clientes_saldo_y_credito_solo_admin()'::regprocedure
                    AND tgenabled = 'O'
                    -- BEFORE (2) | ROW (1) | INSERT (4) | UPDATE (16)
                    AND tgtype::int & (1 | 2 | 4 | 16) = (1 | 2 | 4 | 16)) THEN
    RAISE EXCEPTION '#1156 · trg_clientes_saldo_y_credito_solo_admin no quedó BEFORE INSERT OR UPDATE FOR EACH ROW';
  END IF;
  IF has_function_privilege('anon', 'public.clientes_saldo_y_credito_solo_admin()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.clientes_saldo_y_credito_solo_admin()', 'EXECUTE')
     OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.clientes_saldo_y_credito_solo_admin()'::regprocedure) THEN
    RAISE EXCEPTION '#1156 · clientes_saldo_y_credito_solo_admin tiene que ser INVOKER y sin EXECUTE para anon ni authenticated';
  END IF;
  IF has_function_privilege('anon', 'public.pedidos_proteger_columnas()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.pedidos_proteger_columnas()', 'EXECUTE') THEN
    RAISE EXCEPTION '#1155 · pedidos_proteger_columnas ganó EXECUTE para anon o authenticated';
  END IF;
  IF pg_get_functiondef('public.pedidos_proteger_columnas()'::regprocedure) !~ '''offline_id'',\s*''fecha''' THEN
    RAISE EXCEPTION '#1155 · pedidos_proteger_columnas no bloquea fecha';
  END IF;
END
$verif$;
