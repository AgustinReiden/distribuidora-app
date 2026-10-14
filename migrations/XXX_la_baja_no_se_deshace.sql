-- La baja no se deshace (#1131) y los dos pedidos que quedaron mal (#1131, #1133)
--
-- Hasta aca nada impedia sacar un pedido de 'cancelado' o 'anulado', ni
-- ponerlo ahi sin pasar por cancelar_pedido_con_stock:
--   - pedidos_proteger_columnas sale con RETURN NEW cuando current_user no es
--     'authenticated' y tambien para admin y encargado; al transportista le
--     deja escribir estado (a 'entregado', desde cualquier estado, cancelado
--     incluido) y al preventista duenio no le bloquea estado ni el motivo.
--   - El unico trigger que mira el estado es trg_pedidos_guard_nota_credito,
--     que solo vigila salir de 'entregado'.
-- Caso real: el pedido 1856 se cancelo (devolvio +2 del 72 y +8 del 126),
-- volvio a 'asignado' por REST cuatro minutos despues, tuvo una salvedad y quedo
-- entregado y cobrado sin volver a descontar, con motivo_cancelacion vivo. Y la
-- 354 (#1125) usa "motivo_cancelacion no nulo" como senial de "ya devuelto":
-- un REST que escribiera el motivo en un pedido vivo la falsificaba.
--
-- Hay ademas un camino hermano por el lado del dinero: ningun trigger de pagos
-- miraba el estado del pedido, y mt_pagos_insert deja al transportista imputar
-- a un pedido con su transportista_id (275 de los 366 cancelados lo
-- conservan). El flujo del chofer con la hoja vieja (registrarPago por REST y
-- despues marcar entregado) imputaba el pago al cancelado y despues lo
-- resucitaba. Con la regla 1 de abajo el segundo paso falla, y sin el guard de
-- pagos el primero dejaba el cobro imputado a un cancelado con total 0, que es
-- el estado que la 235 elimino.
--
-- Decisiones del duenio (2026-10-13):
--   #1131, opcion A: un trigger con dos grupos de reglas y dos CHECK, mas el
--     guard de pagos en esta misma migracion.
--   #1131, pedido 1856: se limpia motivo_cancelacion, con fila en
--     pedido_historial, y NO se ajusta stock. Segun el ledger el desvio (+2 del
--     72, +8 del 126) ya lo absorbieron los conteos: el 126 se edito a mano de
--     25 a 1 el 18/06 y quedo en 0 tres veces entre junio y septiembre; el 72
--     se edito 6 -> 12 -> 8 el 28/09 y quedo en 0 tres veces despues. Con el
--     desvio vivo esos ceros implicarian stock real negativo.
--   #1133, pedido 629: se cancelo por el REST viejo 62 s despues de cargarse
--     (cancelar_pedido_con_stock nacio cuatro horas despues, commit 2ee02c8d) y
--     su cancelacion no devolvio nada. Ajuste +1 del 134 y +1 del 92
--     (sucursal 1), origen 'correccion_incidente', referencia pedido 629, con
--     fila en pedido_historial. Ninguno de los dos tiene lotes y el origen esta
--     fuera de la lista blanca de sincronizar_lotes_stock: va a la bolsa, que
--     es donde van unidades anteriores a los lotes. STK-D no se mueve (va
--     etiquetado y con referencia) y STK-F no aplica (un DO no es una funcion).
--
-- Reglas de pedidos_guard_baja (SECURITY INVOKER a proposito: si fuera
-- DEFINER, current_user seria su duenio y las reglas de API desaparecerian
-- sin que fallara nada):
--   1 · todos (tambien las RPC DEFINER y las migraciones): un UPDATE no saca un
--       pedido de 'cancelado' o 'anulado'. Ningun camino legitimo lo hace
--       (aplicar_orden_ruta, marcar_entregas_masivo, marcar_entrega_y_pago_
--       masivo_impl y marcar_no_entregado ya los filtran).
--   2 · API (authenticated, anon, service_role): un INSERT no nace de baja ni
--       con motivo o motivo_tipo.
--   3 · API: un UPDATE no entra en baja.
--   4 · API: un UPDATE no escribe motivo_cancelacion ni motivo_cancelacion_tipo.
--   5 · todos: no se entra en 'cancelado' sin motivo (cancelar_pedido_con_stock
--       no lo valida; asi da un error legible sin redefinir la RPC).
-- service_role entra en las reglas de API porque ninguna edge function escribe
-- pedidos (solo hay selects en ficha_cliente y resolver_preventista): no rompe
-- nada y un camino futuro del bot no puede dar de baja sin la RPC. Fuera de
-- estas reglas solo el duenio de las funciones (las RPC DEFINER:
-- cancelar_pedido_con_stock y cambiar_cliente_pedido, que la llama) y las
-- migraciones entran en baja.
--
-- Dos CHECK cierran la senial de la 354 en los dos sentidos para 'cancelado':
--   pedidos_motivo_cancelacion_solo_en_baja: motivo => baja.
--   pedidos_cancelado_con_motivo: cancelado => motivo no vacio.
-- Con eso la rama "cancelado sin motivo => restaurar" de
-- eliminar_pedido_completo queda solo para datos legados (hoy no hay ninguno);
-- 'anulado' sin motivo sigue siendo construible como postgres y cubre la misma
-- rama. eliminar_pedido_completo y cancelar_pedido_con_stock NO se redefinen
-- (nada de refactors de paso). Trampa 8: ninguno es un CHECK sobre total, asi
-- que VENTA-I y la cancelacion (total = 0) no chocan.
--
-- pagos_rechazar_pedido_de_baja (molde pagos_rechazar_pedido_vb, DEFINER para
-- leer pedidos sin RLS): un pago no se imputa a un pedido cancelado o anulado,
-- para ningun rol. Siguen pasando la desimputacion de la cancelacion (NEW.
-- pedido_id NULL) y el reapunte de cambiar_cliente_pedido (al pedido nuevo,
-- vivo). Las funciones que insertan en pagos ya filtran la baja o van sobre un
-- entregado. En prod hay 0 pagos sobre pedidos de baja. A diferencia del
-- molde, lee el pedido FOR KEY SHARE: choca con el FOR UPDATE de
-- cancelar_pedido_con_stock (el pago espera a la cancelacion y relee
-- 'cancelado', o la cancelacion espera al pago y lo desimputa) y no con el
-- NO KEY UPDATE de recalcular_monto_pagado_pedido (dos pagos concurrentes al
-- mismo pedido no se bloquean entre si). Es el mismo lock que ya toma la FK.
-- Un INSERT cuyo client_request_id ya existe pasa de largo: es el reintento de
-- un pago que ya entro y tiene que chocar con el indice unico (23505), no con
-- este guard.
--
-- Las dos funciones son de trigger: no necesitan EXECUTE para nadie (CLAUDE.md)
-- y quedan en postgres y service_role.
--
-- Ensayo: scripts/test-pedido-baja-1131.sql (manual, contra prod). Cambian de
-- sentido a proposito E7 y E9 de test-eliminar-cancelado-1125.sql y B3 de
-- test-salvedad-huella-1126-1127.sql: el estado que construian ya no se puede
-- construir.
--
-- Se aplica en UN solo apply_migration con name = el stem de este archivo
-- (check-migrations exige 1:1).

-- ---------------------------------------------------------------------------
-- Foto de auditoria_integridad() antes de tocar nada (1e la compara).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _baja_auditoria_antes AS
SELECT x->>'id' AS id, COALESCE((x->>'violaciones')::bigint, 0) AS violaciones
  FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x;

-- ---------------------------------------------------------------------------
-- 1a · Datos (corre como postgres: pedidos_proteger_columnas y
--      productos_proteger_columnas salen; registrar_cambio_stock respeta el
--      origen). Las guardas abortan si prod cambio desde el relevamiento.
-- ---------------------------------------------------------------------------
DO $datos$
DECLARE
  v_p    record;
  v_n    int;
BEGIN
  -- 1856 (#1131): entregado, cobrado, con el motivo de una cancelacion que el
  -- REST deshizo. Un UPDATE que solo nombra motivo_cancelacion dispara
  -- pedidos_proteger_columnas (sale), audit_pedidos (fila de auditoria) y
  -- trigger_registrar_cambio_pedido (no registra el motivo, sin duplicado). No
  -- dispara guard_nota_credito (OF estado), saldo, recorrido, estado_pago ni
  -- reconciliar (OF total / monto_pagado), ni anular_control.
  SELECT id, estado, motivo_cancelacion, motivo_cancelacion_tipo, sucursal_id
    INTO v_p FROM public.pedidos WHERE id = 1856 FOR UPDATE;
  IF NOT FOUND OR v_p.estado IS DISTINCT FROM 'entregado'
     OR v_p.motivo_cancelacion IS DISTINCT FROM 'CLIENTE RECHAZA'
     OR v_p.motivo_cancelacion_tipo IS NOT NULL
     OR v_p.sucursal_id IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'pedido 1856: no esta como se relevo (%): revisar a mano', to_jsonb(v_p);
  END IF;

  UPDATE public.pedidos SET motivo_cancelacion = NULL WHERE id = 1856 AND sucursal_id = 1;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'pedido 1856: el UPDATE toco % filas', v_n;
  END IF;

  INSERT INTO public.pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (1856, NULL, 'motivo_cancelacion', 'CLIENTE RECHAZA',
          'NULL (#1131: el pedido volvio de cancelado por REST y se entrego; el motivo era de una baja deshecha. '
          || 'Sin ajuste de stock: los conteos posteriores del 72 y el 126 ya absorbieron la devolucion)',
          1);

  -- 629 (#1133): cancelado sin que su stock volviera.
  SELECT id, estado, sucursal_id INTO v_p FROM public.pedidos WHERE id = 629 FOR UPDATE;
  IF NOT FOUND OR v_p.estado IS DISTINCT FROM 'cancelado' OR v_p.sucursal_id IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'pedido 629: no esta como se relevo (%): revisar a mano', to_jsonb(v_p);
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_historico
              WHERE referencia_tipo = 'pedido' AND referencia_id = 629
                AND origen = 'correccion_incidente') THEN
    RAISE EXCEPTION 'pedido 629: la correccion ya esta en el ledger';
  END IF;
  IF EXISTS (SELECT 1 FROM public.producto_lotes
              WHERE producto_id IN (92, 134) AND cantidad_restante > 0) THEN
    RAISE EXCEPTION 'pedido 629: el 92 o el 134 tienen lotes vivos: revisar a mano';
  END IF;

  PERFORM set_config('app.stock_origen', 'correccion_incidente', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', '629', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);

  UPDATE public.productos SET stock = stock + 1 WHERE id IN (92, 134) AND sucursal_id = 1;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'pedido 629: el ajuste toco % productos, se esperaban 2', v_n;
  END IF;

  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);

  INSERT INTO public.pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (629, NULL, 'stock',
          'cancelado sin devolver: -1 del 134 y -1 del 92 del alta',
          '+1 del 134 y +1 del 92 (#1133: se cancelo por REST 62 s despues de cargarse y no devolvio; '
          || 'origen correccion_incidente)',
          1);
END
$datos$;

-- ---------------------------------------------------------------------------
-- 1b · pedidos_guard_baja
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pedidos_guard_baja()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $function$
DECLARE
  -- #1131. INVOKER a proposito: current_user es el rol de la llamada. Dentro
  -- de una RPC DEFINER es su duenio y las reglas de API no aplican.
  v_api        boolean := current_user IN ('authenticated', 'anon', 'service_role');
  v_entra_baja boolean;
BEGIN
  -- Regla 1 (todos): una baja no se deshace. La cancelacion ya devolvio el
  -- stock, puso el total en 0 y desimputo los pagos; volver a otro estado
  -- resucita una venta que no descuenta nada (el pedido 1856).
  IF TG_OP = 'UPDATE'
     AND OLD.estado IN ('cancelado', 'anulado')
     AND NEW.estado IS DISTINCT FROM OLD.estado THEN
    RAISE EXCEPTION 'El pedido #% está %: una baja no se deshace (la cancelación ya devolvió el stock). Si hay que entregarlo, cargá un pedido nuevo.',
      OLD.id, OLD.estado
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_entra_baja := COALESCE(NEW.estado IN ('cancelado', 'anulado'), false);
  ELSE
    v_entra_baja := COALESCE(NEW.estado IN ('cancelado', 'anulado'), false)
                    AND NEW.estado IS DISTINCT FROM OLD.estado;
  END IF;

  IF v_api THEN
    -- Reglas 2 y 3 (API): a la baja se entra solo por cancelar_pedido_con_stock.
    IF v_entra_baja THEN
      RAISE EXCEPTION 'Un pedido se da de baja con "Cancelar pedido", que devuelve el stock; no cambiando el estado.'
        USING ERRCODE = '42501';
    END IF;

    -- Regla 4 (API): el motivo lo escribe la cancelacion. La 354 lo usa como
    -- senial de "ya devuelto".
    IF TG_OP = 'INSERT' THEN
      IF NEW.motivo_cancelacion IS NOT NULL OR NEW.motivo_cancelacion_tipo IS NOT NULL THEN
        RAISE EXCEPTION 'El motivo de cancelación lo escribe "Cancelar pedido": un pedido nuevo no lo trae.'
          USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.motivo_cancelacion IS DISTINCT FROM OLD.motivo_cancelacion
          OR NEW.motivo_cancelacion_tipo IS DISTINCT FROM OLD.motivo_cancelacion_tipo THEN
      RAISE EXCEPTION 'El motivo de cancelación lo escribe "Cancelar pedido": no se edita a mano.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Regla 5 (todos): a 'cancelado' se entra con motivo. cancelar_pedido_con_stock
  -- no lo valida; el CHECK pedidos_cancelado_con_motivo lo cierra igual, esto
  -- es para que el error se entienda.
  IF NEW.estado = 'cancelado'
     AND (TG_OP = 'INSERT' OR OLD.estado IS DISTINCT FROM 'cancelado')
     AND COALESCE(btrim(NEW.motivo_cancelacion), '') = '' THEN
    RAISE EXCEPTION 'Un pedido se cancela con motivo (pedido #%).', NEW.id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.pedidos_guard_baja() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_pedidos_guard_baja ON public.pedidos;
CREATE TRIGGER trg_pedidos_guard_baja
  BEFORE INSERT OR UPDATE OF estado, motivo_cancelacion, motivo_cancelacion_tipo ON public.pedidos
  FOR EACH ROW EXECUTE FUNCTION public.pedidos_guard_baja();

-- ---------------------------------------------------------------------------
-- 1c · Dos CHECK (validan contra todas las filas: hoy 0 violaciones despues
--      de 1a)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_motivo_cancelacion_solo_en_baja
  CHECK (estado IN ('cancelado', 'anulado')
         OR (motivo_cancelacion IS NULL AND motivo_cancelacion_tipo IS NULL));

ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_cancelado_con_motivo
  CHECK (estado <> 'cancelado' OR COALESCE(btrim(motivo_cancelacion), '') <> '');

-- ---------------------------------------------------------------------------
-- 1d · pagos_rechazar_pedido_de_baja
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pagos_rechazar_pedido_de_baja()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_estado text;
BEGIN
  -- #1131. Molde: pagos_rechazar_pedido_vb.
  IF NEW.pedido_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.pedido_id IS NOT DISTINCT FROM NEW.pedido_id THEN
      RETURN NEW;
    END IF;
  END IF;

  -- Reintento de un pago que ya entro (mig 167): se deja seguir hasta
  -- idx_pagos_client_request_id, que da el 23505 con el que el front devuelve
  -- la fila existente. Si el pedido se cancelo entre los dos intentos, el pago
  -- original ya quedo desimputado como saldo a favor; rechazarlo aca con 22023
  -- invita a cargarlo de nuevo a cuenta y duplica el cobro. Solo en INSERT: en
  -- un UPDATE el client_request_id es el de la propia fila.
  IF TG_OP = 'INSERT' AND NEW.client_request_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM pagos WHERE client_request_id = NEW.client_request_id) THEN
    RETURN NEW;
  END IF;

  -- FOR KEY SHARE: espera a una cancelacion en curso (FOR UPDATE) y relee el
  -- estado; no choca con el UPDATE de monto_pagado de otro pago concurrente.
  SELECT estado INTO v_estado FROM pedidos WHERE id = NEW.pedido_id FOR KEY SHARE;

  IF v_estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El pedido #% está %: no admite pagos. Registralo como pago a cuenta del cliente.',
      NEW.pedido_id, v_estado
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.pagos_rechazar_pedido_de_baja() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_pagos_pedido_de_baja ON public.pagos;
CREATE TRIGGER trg_pagos_pedido_de_baja
  BEFORE INSERT OR UPDATE OF pedido_id ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.pagos_rechazar_pedido_de_baja();

-- ---------------------------------------------------------------------------
-- 1e · Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_p    record;
  v_n    int;
  v_bad  text;
BEGIN
  SELECT motivo_cancelacion, estado, estado_pago, monto_pagado INTO v_p FROM public.pedidos WHERE id = 1856;
  IF v_p.motivo_cancelacion IS NOT NULL OR v_p.estado <> 'entregado'
     OR v_p.estado_pago <> 'pagado' OR v_p.monto_pagado <> 31200 THEN
    RAISE EXCEPTION '1e: el 1856 quedo %', to_jsonb(v_p);
  END IF;
  SELECT count(*) INTO v_n FROM public.pedido_historial
   WHERE pedido_id = 1856 AND campo_modificado = 'motivo_cancelacion';
  IF v_n <> 1 THEN
    RAISE EXCEPTION '1e: el 1856 tiene % filas de historial de motivo_cancelacion, se esperaba 1', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM public.stock_historico
   WHERE referencia_tipo = 'pedido' AND referencia_id = 629 AND origen = 'correccion_incidente'
     AND stock_nuevo - stock_anterior = 1 AND producto_id IN (92, 134);
  IF v_n <> 2 OR (SELECT count(DISTINCT producto_id) FROM public.stock_historico
                   WHERE referencia_tipo = 'pedido' AND referencia_id = 629
                     AND origen = 'correccion_incidente') <> 2 THEN
    RAISE EXCEPTION '1e: el 629 tiene % filas de correccion en el ledger, se esperaban 2 (92 y 134)', v_n;
  END IF;

  IF (SELECT count(*) FROM pg_trigger
       WHERE NOT tgisinternal AND tgenabled = 'O'
         AND ((tgrelid = 'public.pedidos'::regclass AND tgname = 'trg_pedidos_guard_baja')
           OR (tgrelid = 'public.pagos'::regclass AND tgname = 'trg_pagos_pedido_de_baja'))) <> 2 THEN
    RAISE EXCEPTION '1e: faltan los triggers';
  END IF;

  IF (SELECT prosecdef OR proconfig IS DISTINCT FROM ARRAY['search_path=public']
        FROM pg_proc WHERE oid = 'public.pedidos_guard_baja()'::regprocedure) THEN
    RAISE EXCEPTION '1e: pedidos_guard_baja tiene que ser INVOKER con search_path=public';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.pagos_rechazar_pedido_de_baja()'::regprocedure) THEN
    RAISE EXCEPTION '1e: pagos_rechazar_pedido_de_baja tiene que ser DEFINER';
  END IF;

  IF has_function_privilege('anon', 'public.pedidos_guard_baja()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.pedidos_guard_baja()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.pagos_rechazar_pedido_de_baja()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.pagos_rechazar_pedido_de_baja()', 'EXECUTE') THEN
    RAISE EXCEPTION '1e: anon o authenticated pueden ejecutar una funcion de trigger';
  END IF;

  IF (SELECT count(*) FROM pg_constraint
       WHERE conrelid = 'public.pedidos'::regclass AND convalidated
         AND conname IN ('pedidos_motivo_cancelacion_solo_en_baja', 'pedidos_cancelado_con_motivo')) <> 2 THEN
    RAISE EXCEPTION '1e: faltan los CHECK validados';
  END IF;

  SELECT string_agg(format('%s %s -> %s', a.id, a.violaciones, d.violaciones), ', ') INTO v_bad
    FROM _baja_auditoria_antes a
    JOIN (SELECT x->>'id' AS id, COALESCE((x->>'violaciones')::bigint, 0) AS violaciones
            FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x) d ON d.id = a.id
   WHERE d.violaciones > a.violaciones;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '1e: auditoria_integridad() con violaciones nuevas: %', v_bad;
  END IF;
END
$verif$;

DROP TABLE _baja_auditoria_antes;
