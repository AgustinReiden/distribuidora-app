-- =========================================================================
-- mig 283 · EL CREDITO SE IMPUTA AL PEDIDO ELEGIDO
--
-- Un saldo a favor (pago sin pedido: sobrepago, cancelacion de la 235 o el
-- credito de una nota de credito de la 276) hoy solo se consume FIFO:
-- `aplicar_credito_cliente` lo tira contra la boleta impaga MAS VIEJA del
-- cliente. Dos problemas con eso:
--
--   1. No hay forma de elegir. Si el cliente dice "esta NC descontamela de la
--      boleta de hoy", la app no lo puede hacer: el credito se va a la boleta
--      mas vieja la proxima vez que algo dispare la reconciliacion.
--   2. El credito de una NC puede terminar imputado a SU PROPIO pedido de
--      referencia. La NC es por mercaderia de ese pedido que el cliente ya
--      acepto (y si estaba impago, lo que corresponde es la salvedad, no la
--      NC): imputarle el credito equivale a bajarle el total por la puerta de
--      atras, que es justo lo que la 276 queria evitar.
--
-- Lo que hace:
--
--   * `imputar_credito_a_pedido(pago, pedido, monto?, client_request_id?)`:
--     RPC nueva, wrapper con el mismo patron que las RPCs de pago (167):
--     `pago_solicitud_abrir` / `pago_solicitud_cerrar` sobre el ledger
--     `pagos_solicitudes`, con `idempotent_replay` en la repeticion.
--     La logica vive en `imputar_credito_a_pedido_impl` (server-only).
--     Imputa un pago sin pedido a la boleta elegida: si el monto cubre el
--     pago entero lo mueve (UPDATE pedido_id); si no, lo parte igual que
--     `aplicar_credito_cliente` (la fila nueva lleva lo imputado y la
--     original queda como saldo a favor con el resto). El monto se capea al
--     faltante de la boleta, asi que nunca la sobrepaga y
--     `desafectar_sobrepago_pedido` no tiene nada que recortar (ademas no se
--     dispara: `zzz_pedidos_reconciliar_pagos` es `UPDATE OF total` y aca solo
--     cambia `monto_pagado`).
--   * `aplicar_credito_cliente`: el credito de una NC ya no se imputa al
--     pedido de referencia de esa NC (`notas_credito_venta.pedido_id`). Si esa
--     es la unica boleta impaga, el credito queda de saldo a favor. Resto del
--     cuerpo identico al vivo (276).
--
-- ROL. Admin o encargado, mismo chequeo que `registrar_pago_cliente_fifo_impl`
-- (perfiles.rol, sucursal = current_sucursal_id()). La restriccion de fecha
-- del encargado de ese _impl ("solo fecha de hoy") no aplica: aca no se crea
-- plata ni se elige fecha, el pago conserva la suya. Lo que si importa es la
-- rendicion: `obtener_resumen_rendiciones` atribuye cada pago por
-- `COALESCE(pedidos.transportista_id, pagos.usuario_id)` y separa lo cobrado
-- en entregas de lo demas, asi que mover un pago de PLATA a una boleta cambia
-- como se lee la rendicion de la fecha del pago. Por eso el encargado no
-- puede reimputar un credito dinerario cuya fecha cae en una caja ya cerrada
-- (`ultima_fecha_caja_cerrada`, el mismo limite que `guard_pago_fecha_cerrada`)
-- y tiene que pedirselo a un admin, igual que en el cobro (230). El credito de
-- NC no es plata de ninguna rendicion (273/276 lo excluyen), asi que ese el
-- encargado lo imputa siempre. El admin pasa, como pasa hoy
-- `aplicar_credito_cliente` para cualquiera que dispare un cobro.
--
-- GUC. Los UPDATE/INSERT corren con `app.reimputacion_pagos = 'on'`, como en
-- `aplicar_credito_cliente`: es una reimputacion, no un cobro, y
-- `guard_pago_fecha_cerrada` la deja pasar (el control de caja ya lo hizo el
-- chequeo de rol de arriba). `set_config` es por transaccion: se guarda el
-- valor previo y se restaura al final, para no pisarle la etiqueta a un
-- eventual caller.
--
-- Triggers de `pagos` en contexto SECURITY DEFINER: current_user es el owner,
-- asi que `pagos_guard_nota_credito` trata la operacion como server (deja
-- bajar el monto del credito de NC y valida el INSERT del pedazo contra la NC:
-- no anulada, mismo cliente) y `pagos_forzar_usuario` no toca usuario_id. El
-- ensayo lo ejerce.
--
-- Permisos: wrapper → authenticated (REVOKE PUBLIC, anon); _impl → solo
-- server (REVOKE PUBLIC, anon, authenticated). `aplicar_credito_cliente`
-- conserva firma, SECURITY DEFINER y ACL (CREATE OR REPLACE no toca GRANTs).
--
-- Numero PROVISORIO: se reserva al aplicar (ver MANIFEST).
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · aplicar_credito_cliente: la NC no vuelve a su pedido de origen
-- -------------------------------------------------------------------------
-- Cuerpo VIVO (276) + v_excluir + FOR UPDATE en el cursor. Nada mas cambia.
CREATE OR REPLACE FUNCTION public.aplicar_credito_cliente(p_cliente_id bigint, p_sucursal_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_credito   RECORD;
  v_pedido    RECORD;
  v_restante  numeric;
  v_aplicar   numeric;
  v_aplicado  numeric := 0;
  v_vueltas   integer;
  v_excluir   bigint;
BEGIN
  IF p_cliente_id IS NULL OR p_sucursal_id IS NULL THEN
    RETURN 0;
  END IF;

  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  FOR v_credito IN
    SELECT id, monto, nota_credito_id
      FROM pagos
     WHERE cliente_id = p_cliente_id
       AND sucursal_id = p_sucursal_id
       AND pedido_id IS NULL
     ORDER BY fecha ASC, id ASC
     -- FOR UPDATE: sin lock, un credito que `imputar_credito_a_pedido` movio o
     -- partio mientras tanto se reimputaba igual con el monto viejo (el UPDATE
     -- filtra solo por id): pisaba la eleccion o dejaba un saldo negativo. Con
     -- el lock Postgres re-evalua `pedido_id IS NULL` sobre la version nueva.
       FOR UPDATE
  LOOP
    v_restante := v_credito.monto;
    v_vueltas  := 0;

    -- mig 283: el credito de una NC no se imputa al pedido que la origino
    -- (seria bajarle el total sin salvedad). NULL si no es de NC.
    v_excluir := NULL;
    IF v_credito.nota_credito_id IS NOT NULL THEN
      SELECT pedido_id INTO v_excluir
        FROM notas_credito_venta
       WHERE id = v_credito.nota_credito_id;
    END IF;

    LOOP
      EXIT WHEN v_restante <= 0.005;

      -- Se relee en cada vuelta a proposito: el trigger de monto_pagado ya actualizo
      -- la boleta anterior, asi que esta consulta ve el estado fresco.
      SELECT id, total - COALESCE(monto_pagado, 0) AS falta
        INTO v_pedido
        FROM pedidos
       WHERE cliente_id = p_cliente_id
         AND sucursal_id = p_sucursal_id
         AND estado NOT IN ('cancelado', 'anulado')
         AND total > COALESCE(monto_pagado, 0)
         AND id IS DISTINCT FROM v_excluir
       ORDER BY fecha ASC, id ASC
       LIMIT 1;

      EXIT WHEN NOT FOUND;

      v_vueltas := v_vueltas + 1;
      EXIT WHEN v_vueltas > 500;  -- backstop, no deberia alcanzarse nunca

      v_aplicar := LEAST(v_restante, v_pedido.falta);

      IF v_aplicar >= v_restante - 0.005 THEN
        UPDATE pagos
           SET pedido_id = v_pedido.id,
               notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
         WHERE id = v_credito.id;

        v_aplicado := v_aplicado + v_restante;
        v_restante := 0;
      ELSE
        UPDATE pagos SET monto = monto - v_aplicar WHERE id = v_credito.id;

        -- mig 276 (#833): nota_credito_id viaja con el pedazo.
        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, nota_credito_id
        )
        SELECT cliente_id, v_pedido.id, v_aplicar, forma_pago, fecha, referencia,
               NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
               usuario_id, sucursal_id, nota_credito_id
          FROM pagos
         WHERE id = v_credito.id;

        v_aplicado := v_aplicado + v_aplicar;
        v_restante := v_restante - v_aplicar;
      END IF;
    END LOOP;
  END LOOP;

  PERFORM set_config('app.reimputacion_pagos', 'off', true);

  RETURN v_aplicado;
END;
$function$;

-- -------------------------------------------------------------------------
-- 2 · imputar_credito_a_pedido_impl (server-only)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.imputar_credito_a_pedido_impl(
  p_pago_id   bigint,
  p_pedido_id bigint,
  p_monto     numeric DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_acting_user uuid   := auth.uid();
  v_rol         text;
  v_pago        RECORD;
  v_pedido      RECORD;
  v_nc          RECORD;
  v_limite      date;
  v_falta       numeric;
  v_aplicar     numeric;
  v_guc_previo  text;
  v_pago_imp_id bigint;
  v_resto_id    bigint;
  v_resto       numeric := 0;
BEGIN
  -- Rol y sucursal: mismo chequeo que registrar_pago_cliente_fifo_impl.
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = v_acting_user;
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden imputar un saldo a favor'
      USING ERRCODE = '42501';
  END IF;

  IF p_monto IS NOT NULL AND p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto a imputar tiene que ser mayor a 0' USING ERRCODE = '22023';
  END IF;

  -- Lock: primero el pago, despues el pedido (mismo orden que el cobro FIFO,
  -- donde aplicar_credito_cliente toca pagos antes del FOR UPDATE de pedidos).
  SELECT id, cliente_id, pedido_id, monto, forma_pago, fecha, nota_credito_id
    INTO v_pago
    FROM pagos
   WHERE id = p_pago_id AND sucursal_id = v_sucursal_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Saldo a favor no encontrado' USING ERRCODE = 'P0002';
  END IF;
  IF v_pago.pedido_id IS NOT NULL THEN
    RAISE EXCEPTION 'El pago #% ya esta imputado al pedido #%: no es saldo a favor',
      p_pago_id, v_pago.pedido_id USING ERRCODE = '22023';
  END IF;
  IF v_pago.monto IS NULL OR v_pago.monto <= 0.005 THEN
    RAISE EXCEPTION 'El saldo a favor #% no tiene monto para imputar', p_pago_id USING ERRCODE = '22023';
  END IF;

  SELECT id, cliente_id, estado, total, COALESCE(monto_pagado, 0) AS pagado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido no encontrado' USING ERRCODE = 'P0002';
  END IF;
  IF v_pedido.cliente_id IS DISTINCT FROM v_pago.cliente_id THEN
    RAISE EXCEPTION 'El pedido #% no es del cliente del saldo a favor', p_pedido_id USING ERRCODE = '22023';
  END IF;
  -- Mismo criterio de "impago y elegible" que aplicar_credito_cliente.
  IF NOT (v_pedido.estado NOT IN ('cancelado', 'anulado')) THEN
    RAISE EXCEPTION 'El pedido #% esta %: no se le puede imputar un credito', p_pedido_id, v_pedido.estado
      USING ERRCODE = '22023';
  END IF;
  v_falta := v_pedido.total - v_pedido.pagado;
  IF v_falta <= 0.005 THEN
    RAISE EXCEPTION 'El pedido #% ya esta pagado: no tiene saldo para imputar', p_pedido_id USING ERRCODE = '22023';
  END IF;

  IF v_pago.nota_credito_id IS NOT NULL THEN
    SELECT pedido_id, anulada INTO v_nc
      FROM notas_credito_venta
     WHERE id = v_pago.nota_credito_id;
    IF NOT FOUND OR v_nc.anulada THEN
      RAISE EXCEPTION 'La nota de credito #% no existe o esta anulada: su credito no se puede imputar',
        v_pago.nota_credito_id USING ERRCODE = '22023';
    END IF;
    IF v_nc.pedido_id = p_pedido_id THEN
      RAISE EXCEPTION 'La nota de credito #% es del pedido #%: su credito no se puede imputar a ese mismo pedido. Si hay que bajarle el total, es una salvedad.',
        v_pago.nota_credito_id, p_pedido_id USING ERRCODE = '22023';
    END IF;
  ELSIF v_rol = 'encargado' THEN
    -- Credito de plata: reimputarlo cambia como se lee la rendicion de su fecha
    -- (atribucion por transportista del pedido). Caja cerrada → admin.
    v_limite := public.ultima_fecha_caja_cerrada(v_sucursal_id);
    IF v_limite IS NOT NULL AND v_pago.fecha <= v_limite THEN
      RAISE EXCEPTION 'El saldo a favor es del % y la caja esta cerrada hasta el %. Pedi a un admin.',
        to_char(v_pago.fecha, 'DD/MM/YYYY'), to_char(v_limite, 'DD/MM/YYYY') USING ERRCODE = '42501';
    END IF;
  END IF;

  v_aplicar := round(LEAST(v_pago.monto, v_falta, COALESCE(p_monto, v_pago.monto)), 2);
  IF v_aplicar <= 0 THEN
    RAISE EXCEPTION 'El monto a imputar tiene que ser mayor a 0' USING ERRCODE = '22023';
  END IF;

  v_guc_previo := current_setting('app.reimputacion_pagos', true);
  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  IF v_aplicar >= v_pago.monto - 0.005 THEN
    -- Cubre el pago entero: se mueve (igual que aplicar_credito_cliente).
    UPDATE pagos
       SET pedido_id = p_pedido_id,
           notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
     WHERE id = p_pago_id;

    v_aplicar     := v_pago.monto;
    v_pago_imp_id := p_pago_id;
  ELSE
    -- Parcial: split igual que aplicar_credito_cliente. La fila nueva lleva lo
    -- imputado; la original queda de saldo a favor con el resto.
    UPDATE pagos SET monto = monto - v_aplicar WHERE id = p_pago_id;

    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id, nota_credito_id
    )
    SELECT cliente_id, p_pedido_id, v_aplicar, forma_pago, fecha, referencia,
           NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
           usuario_id, sucursal_id, nota_credito_id
      FROM pagos
     WHERE id = p_pago_id
    RETURNING id INTO v_pago_imp_id;

    v_resto_id := p_pago_id;
    v_resto    := v_pago.monto - v_aplicar;
  END IF;

  PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc_previo, ''), true);

  RETURN jsonb_build_object(
    'success',        true,
    'pago_id',        v_pago_imp_id,
    'pedido_id',      p_pedido_id,
    'monto_imputado', v_aplicar,
    'resto_a_favor',  v_resto,
    'pago_resto_id',  v_resto_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.imputar_credito_a_pedido_impl(bigint, bigint, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.imputar_credito_a_pedido_impl(bigint, bigint, numeric)
  TO service_role;

-- -------------------------------------------------------------------------
-- 3 · imputar_credito_a_pedido (wrapper idempotente, patron 167)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.imputar_credito_a_pedido(
  p_pago_id           bigint,
  p_pedido_id         bigint,
  p_monto             numeric DEFAULT NULL,
  p_client_request_id uuid    DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_previo    jsonb;
  v_resultado jsonb;
BEGIN
  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'imputar_credito_a_pedido');
  IF v_previo IS NOT NULL THEN
    RETURN v_previo || jsonb_build_object('idempotent_replay', true);
  END IF;

  v_resultado := public.imputar_credito_a_pedido_impl(p_pago_id, p_pedido_id, p_monto);

  PERFORM public.pago_solicitud_cerrar(p_client_request_id, v_resultado);
  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.imputar_credito_a_pedido(bigint, bigint, numeric, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.imputar_credito_a_pedido(bigint, bigint, numeric, uuid)
  TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 4 · Ensayo funcional (subtransaccion que se revierte; molde 236/241)
-- -------------------------------------------------------------------------
-- Cliente sintetico con tres boletas impagas (P0 la mas vieja, origen de una
-- NC de 400; P1 de 300; P2 de 500) y dos creditos: el de la NC y 200 en
-- efectivo. Casos:
--   d · la NC no se imputa a P0 (su origen)
--   b · NC → P1 por 100: split, resto 300 a favor
--   c · NC (resto) → P1 sin monto: capeado a los 200 que faltan, resto 100
--   a · efectivo 200 → P2 entero, por el wrapper con client_request_id
--   e · replay del mismo client_request_id: mismo resultado, sin filas nuevas
--   f · aplicar_credito_cliente con el resto de la NC: va a P2, no a P0
--   g · saldo_cuenta igual al de antes; CC-A y CC-B cierran para el cliente
DO $ensayo$
DECLARE
  v_uid    uuid;
  v_suc    bigint;
  v_fallas text := '';
  v_notas  text := '';
  v_d_err   text;
  v_b       jsonb;
  v_c       jsonb;
  v_a       jsonb;
  v_e       jsonb;
  v_e_filas int;
  v_a_filas int;
  v_f_p0    numeric;
  v_f_p2    numeric;
  v_f_nc_p0 int;
  v_f_apl   numeric;
  v_p1_pag  numeric;
  v_p1_est  text;
  v_a_notas text;
  v_saldo_0 numeric;
  v_saldo_1 numeric;
  v_cca     numeric;
  v_ccb     int;
  v_cero    text;
  v_guc     text;
BEGIN
  SELECT p.id, us.sucursal_id INTO v_uid, v_suc
    FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
   WHERE p.rol = 'admin'
   ORDER BY p.id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig283: no hay ningun admin con sucursal por defecto; el ensayo no puede correr.';
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    DECLARE
      v_cli bigint; v_p0 bigint; v_p1 bigint; v_p2 bigint;
      v_nc bigint; v_pago_nc bigint; v_pago_ef bigint;
      v_req uuid := gen_random_uuid();
    BEGIN
      INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
        VALUES ('ZZZ mig283', 'ZZZ mig283', 'ZZZ', v_suc) RETURNING id INTO v_cli;

      INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha)
        VALUES (v_cli, v_suc, v_uid, 1000, 'entregado', current_date - 3) RETURNING id INTO v_p0;
      INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha)
        VALUES (v_cli, v_suc, v_uid, 300, 'pendiente', current_date - 2) RETURNING id INTO v_p1;
      INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha)
        VALUES (v_cli, v_suc, v_uid, 500, 'pendiente', current_date - 1) RETURNING id INTO v_p2;

      INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, motivo, total, usuario_id)
        VALUES (v_suc, v_cli, v_p0, 'producto_vencido', 400, v_uid) RETURNING id INTO v_nc;
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, referencia, notas,
                         usuario_id, sucursal_id, nota_credito_id)
        VALUES (v_cli, NULL, 400, 'nota_credito', current_date, 'NC-' || v_nc,
                'Nota de credito #' || v_nc || ' [saldo a favor]', v_uid, v_suc, v_nc)
        RETURNING id INTO v_pago_nc;
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, notas, usuario_id, sucursal_id)
        VALUES (v_cli, NULL, 200, 'efectivo', current_date, '[saldo a favor]', v_uid, v_suc)
        RETURNING id INTO v_pago_ef;

      SELECT saldo_cuenta INTO v_saldo_0 FROM clientes WHERE id = v_cli;

      -- d
      BEGIN
        PERFORM imputar_credito_a_pedido(v_pago_nc, v_p0, NULL, NULL);
        v_d_err := '(paso)';
      EXCEPTION WHEN OTHERS THEN
        v_d_err := SQLERRM;
      END;

      -- b
      v_b := imputar_credito_a_pedido(v_pago_nc, v_p1, 100, NULL);
      -- c
      v_c := imputar_credito_a_pedido(v_pago_nc, v_p1, 999, NULL);
      SELECT monto_pagado, estado_pago INTO v_p1_pag, v_p1_est FROM pedidos WHERE id = v_p1;

      -- a + e
      v_a := imputar_credito_a_pedido(v_pago_ef, v_p2, NULL, v_req);
      SELECT notas INTO v_a_notas FROM pagos WHERE id = v_pago_ef;
      SELECT count(*) INTO v_a_filas FROM pagos WHERE cliente_id = v_cli;
      v_e := imputar_credito_a_pedido(v_pago_ef, v_p2, NULL, v_req);
      SELECT count(*) INTO v_e_filas FROM pagos WHERE cliente_id = v_cli;

      -- f (con un valor previo del GUC para ver que el _impl lo restaura)
      PERFORM set_config('app.reimputacion_pagos', 'marca', true);
      PERFORM imputar_credito_a_pedido(v_pago_nc, v_p2, 1, NULL);  -- 1 peso, solo para el GUC
      v_guc := current_setting('app.reimputacion_pagos', true);
      PERFORM set_config('app.reimputacion_pagos', '', true);
      v_f_apl := aplicar_credito_cliente(v_cli, v_suc);
      SELECT COALESCE(monto_pagado, 0) INTO v_f_p0 FROM pedidos WHERE id = v_p0;
      SELECT COALESCE(monto_pagado, 0) INTO v_f_p2 FROM pedidos WHERE id = v_p2;
      SELECT count(*) INTO v_f_nc_p0 FROM pagos WHERE nota_credito_id = v_nc AND pedido_id = v_p0;

      -- g
      SELECT saldo_cuenta INTO v_saldo_1 FROM clientes WHERE id = v_cli;
      SELECT abs(COALESCE(c.saldo_cuenta, 0) - (
               COALESCE((SELECT sum(p.total - COALESCE(p.monto_pagado, 0)) FROM pedidos p
                          WHERE p.cliente_id = c.id AND p.estado NOT IN ('cancelado', 'anulado')), 0)
             - COALESCE((SELECT sum(pg.monto) FROM pagos pg
                          WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL), 0)))
        INTO v_cca FROM clientes c WHERE c.id = v_cli;
      SELECT count(*) INTO v_ccb FROM pedidos p
        WHERE p.cliente_id = v_cli
          AND abs(COALESCE(p.monto_pagado, 0)
                  - COALESCE((SELECT sum(pg.monto) FROM pagos pg WHERE pg.pedido_id = p.id), 0)) > 0.01;
      v_cero := format('NC_resto=%s', (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE nota_credito_id = v_nc AND pedido_id IS NULL));
    END;

    RAISE EXCEPTION 'mig283_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig283_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig283 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  -- d
  IF v_d_err IS NULL OR v_d_err NOT LIKE '%no se puede imputar a ese mismo pedido%' THEN
    v_fallas := v_fallas || format(' [d: la NC no fue rechazada en su pedido de origen: %s]', v_d_err);
  END IF;
  -- b
  IF (v_b->>'monto_imputado')::numeric IS DISTINCT FROM 100 OR (v_b->>'resto_a_favor')::numeric IS DISTINCT FROM 300
     OR v_b->>'pago_resto_id' IS NULL OR v_b->>'pago_id' = v_b->>'pago_resto_id' THEN
    v_fallas := v_fallas || format(' [b: split mal: %s]', v_b);
  END IF;
  -- c
  IF (v_c->>'monto_imputado')::numeric IS DISTINCT FROM 200 OR (v_c->>'resto_a_favor')::numeric IS DISTINCT FROM 100
     OR v_p1_pag IS DISTINCT FROM 300 OR v_p1_est IS DISTINCT FROM 'pagado' THEN
    v_fallas := v_fallas || format(' [c: no se capeo al faltante: %s · P1 pagado=%s %s]', v_c, v_p1_pag, v_p1_est);
  END IF;
  -- a
  IF (v_a->>'monto_imputado')::numeric IS DISTINCT FROM 200 OR (v_a->>'resto_a_favor')::numeric IS DISTINCT FROM 0
     OR v_a->'pago_resto_id' <> 'null'::jsonb OR v_a_notas IS NOT NULL THEN
    v_fallas := v_fallas || format(' [a: imputacion total mal: %s · notas=%s]', v_a, v_a_notas);
  END IF;
  -- e
  IF COALESCE((v_e->>'idempotent_replay')::boolean, false) IS NOT TRUE
     OR (v_e - 'idempotent_replay') IS DISTINCT FROM v_a OR v_e_filas <> v_a_filas THEN
    v_fallas := v_fallas || format(' [e: replay: %s · filas %s→%s]', v_e, v_a_filas, v_e_filas);
  END IF;
  -- f
  IF v_f_p0 <> 0 OR v_f_nc_p0 <> 0 OR v_f_p2 IS DISTINCT FROM 300 OR v_f_apl IS DISTINCT FROM 99 THEN
    v_fallas := v_fallas || format(' [f: aplicar_credito_cliente: P0 pagado=%s pedazos NC en P0=%s P2 pagado=%s aplicado=%s]',
                                   v_f_p0, v_f_nc_p0, v_f_p2, v_f_apl);
  END IF;
  IF v_guc IS DISTINCT FROM 'marca' THEN
    v_fallas := v_fallas || format(' [GUC: el _impl no restauro app.reimputacion_pagos, quedo %s]', v_guc);
  END IF;
  -- g
  IF v_saldo_1 IS DISTINCT FROM v_saldo_0 OR v_cca > 0.01 OR v_ccb <> 0 THEN
    v_fallas := v_fallas || format(' [g: saldo %s→%s CC-A dif=%s CC-B=%s]', v_saldo_0, v_saldo_1, v_cca, v_ccb);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig283 · el ensayo funcional encontro:%', v_fallas;
  END IF;

  v_notas := format('a=%s · b=%s · c=%s P1=%s/%s · d="%s" · e filas %s→%s replay=%s · f P0=%s P2=%s aplicado=%s %s · GUC=%s · g saldo %s→%s CC-A=%s CC-B=%s',
                    v_a->>'monto_imputado', v_b->>'resto_a_favor', v_c->>'monto_imputado', v_p1_pag, v_p1_est,
                    v_d_err, v_a_filas, v_e_filas, v_e->>'idempotent_replay',
                    v_f_p0, v_f_p2, v_f_apl, v_cero, v_guc, v_saldo_0, v_saldo_1, v_cca, v_ccb);
  PERFORM set_config('mig283.ensayo', v_notas, true);
  RAISE NOTICE 'mig283 · ensayo funcional OK: %', v_notas;
END
$ensayo$;

COMMIT;
