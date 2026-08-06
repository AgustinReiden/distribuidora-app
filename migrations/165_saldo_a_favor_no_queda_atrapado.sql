-- 165_saldo_a_favor_no_queda_atrapado.sql
--
-- PROBLEMA
-- Cuando se baja el total de una boleta YA cobrada (por salvedad o por edicion
-- manual de los items), `pedidos.total` baja pero `pagos` y `pedidos.monto_pagado`
-- quedan intactos. El pedido queda con monto_pagado > total y ese excedente queda
-- enterrado en una boleta cerrada.
--
-- Efecto visible: la ficha del cliente y la lista de boletas dejan de coincidir.
--   saldo_cuenta   = SUM(pedidos: total - monto_pagado) - SUM(pagos sin pedido)
--   lista boletas  = SUM(pedidos: GREATEST(total - monto_pagado, 0))
-- La ficha netea el negativo, la lista lo clampa a cero. La diferencia es exactamente
-- el monto de la salvedad. Caso testigo: cliente 815 (#799 "Despensa Dalma"),
-- pedido 3329, salvedad de $8.300 el 2026-07-08 sobre una boleta ya cobrada.
--
-- Ademas `registrar_pago_cliente_fifo` solo recorre pedidos con total > monto_pagado,
-- asi que nunca consume el credito preexistente: el descuadre no se corrige solo.
--
-- SOLUCION
-- Invariante nuevo: ningun pedido vigente puede tener monto_pagado > total. El
-- excedente vive siempre como fila de `pagos` con pedido_id IS NULL (saldo a favor),
-- que es la unica representacion del credito. El saldo_cuenta del cliente NO cambia
-- al mover el excedente de una forma a la otra: -8300 via (total - monto_pagado)
-- pasa a ser -8300 via (pago sin pedido). Solo cambia donde vive el credito.
--
--   1. desafectar_sobrepago_pedido()  -> saca el excedente de la boleta a saldo a favor
--   2. aplicar_credito_cliente()      -> imputa el saldo a favor a boletas pendientes (FIFO)
--   3. trigger AFTER UPDATE OF total  -> corre 1 y 2 ante CUALQUIER cambio de total,
--                                        no solo salvedades (cubre la edicion manual)
--   4. las dos RPCs FIFO consumen el credito antes de imputar la plata nueva
--
-- Mover un pago ya cobrado entre boletas del mismo cliente preserva fecha, forma de
-- pago y monto total, asi que ni la caja del dia ni la rendicion cambian: solo cambia
-- a que boleta se aplica. Por eso el guard de caja cerrada acepta un escape explicito
-- para estas reimputaciones internas.

-- ---------------------------------------------------------------------------
-- 1. Escape del guard de caja cerrada para reimputaciones internas
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_pago_fecha_cerrada()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_limite date;
BEGIN
  IF NEW.sucursal_id IS NULL OR NEW.fecha IS NULL THEN
    RETURN NEW;
  END IF;

  -- Reimputacion interna (mig 165): mover plata ya cobrada entre boletas del mismo
  -- cliente no altera el total del dia ni la rendicion, solo a que boleta se aplica.
  -- El GUC es transaction-scoped y lo setean unicamente las funciones de abajo.
  IF current_setting('app.reimputacion_pagos', true) = 'on' THEN
    RETURN NEW;
  END IF;

  v_limite := public.ultima_fecha_caja_cerrada(NEW.sucursal_id);

  IF v_limite IS NOT NULL AND NEW.fecha <= v_limite THEN
    RAISE EXCEPTION 'La caja de la sucursal esta cerrada hasta el % (rendicion controlada). No se puede registrar/editar un pago con fecha %. Reabri la rendicion de ese dia para hacer cambios.',
      to_char(v_limite, 'DD/MM/YYYY'), to_char(NEW.fecha, 'DD/MM/YYYY')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. desafectar_sobrepago_pedido: excedente de la boleta -> saldo a favor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.desafectar_sobrepago_pedido(p_pedido_id bigint)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_pedido      RECORD;
  v_pago        RECORD;
  v_excedente   numeric;
  v_mover       numeric;
  v_desafectado numeric := 0;
BEGIN
  SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, estado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  -- En cancelados/anulados el pedido no aporta al saldo; su imputacion se resuelve
  -- por el flujo de cancelacion, no aca.
  IF v_pedido.estado IN ('cancelado', 'anulado') THEN
    RETURN 0;
  END IF;

  v_excedente := v_pedido.pagado - v_pedido.total;
  IF v_excedente <= 0.005 THEN
    RETURN 0;
  END IF;

  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  -- Se desafecta desde el pago mas nuevo: el excedente es lo ultimo que entro.
  FOR v_pago IN
    SELECT id, monto
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_mover := LEAST(v_pago.monto, v_excedente);

    IF v_mover >= v_pago.monto - 0.005 THEN
      -- el pago entero pasa a saldo a favor
      UPDATE pagos
         SET pedido_id = NULL,
             notas = trim(COALESCE(notas, '') || ' [saldo a favor]')
       WHERE id = v_pago.id;
    ELSE
      -- se parte: queda imputado lo que entra en el total, el resto va a saldo a favor
      UPDATE pagos SET monto = monto - v_mover WHERE id = v_pago.id;

      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id
      )
      SELECT cliente_id, NULL, v_mover, forma_pago, fecha,
             referencia, trim(COALESCE(notas, '') || ' [saldo a favor]'),
             usuario_id, sucursal_id
        FROM pagos
       WHERE id = v_pago.id;
    END IF;

    v_excedente   := v_excedente - v_mover;
    v_desafectado := v_desafectado + v_mover;
  END LOOP;

  PERFORM set_config('app.reimputacion_pagos', 'off', true);

  RETURN v_desafectado;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. aplicar_credito_cliente: saldo a favor -> boletas pendientes (FIFO)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aplicar_credito_cliente(
  p_cliente_id  bigint,
  p_sucursal_id bigint
)
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
BEGIN
  IF p_cliente_id IS NULL OR p_sucursal_id IS NULL THEN
    RETURN 0;
  END IF;

  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  FOR v_credito IN
    SELECT id, monto
      FROM pagos
     WHERE cliente_id = p_cliente_id
       AND sucursal_id = p_sucursal_id
       AND pedido_id IS NULL
     ORDER BY fecha ASC, id ASC
  LOOP
    v_restante := v_credito.monto;
    v_vueltas  := 0;

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
       ORDER BY fecha ASC, id ASC
       LIMIT 1;

      EXIT WHEN NOT FOUND;

      v_vueltas := v_vueltas + 1;
      EXIT WHEN v_vueltas > 500;  -- backstop, no deberia alcanzarse nunca

      v_aplicar := LEAST(v_restante, v_pedido.falta);

      IF v_aplicar >= v_restante - 0.005 THEN
        -- el credito entra entero en esta boleta
        UPDATE pagos
           SET pedido_id = v_pedido.id,
               notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
         WHERE id = v_credito.id;

        v_aplicado := v_aplicado + v_restante;
        v_restante := 0;
      ELSE
        -- alcanza para cerrar esta boleta y sobra: se parte
        UPDATE pagos SET monto = monto - v_aplicar WHERE id = v_credito.id;

        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id
        )
        SELECT cliente_id, v_pedido.id, v_aplicar, forma_pago, fecha, referencia,
               NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
               usuario_id, sucursal_id
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

-- ---------------------------------------------------------------------------
-- 4. Trigger: cualquier cambio de total reconcilia la imputacion de los pagos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pedidos_reconciliar_pagos()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Defensa contra reentrada. En la practica no se alcanza (las cascadas internas
  -- actualizan monto_pagado, no total), pero el trigger toca pagos y no conviene
  -- depender de eso.
  IF current_setting('app.reimputacion_pagos', true) = 'on' THEN
    RETURN NULL;
  END IF;

  -- Bajo el total: el excedente cobrado sale de la boleta.
  PERFORM public.desafectar_sobrepago_pedido(NEW.id);
  -- Subio el total (o quedo credito suelto): se consume contra lo que el cliente debe.
  PERFORM public.aplicar_credito_cliente(NEW.cliente_id, NEW.sucursal_id);

  RETURN NULL;
END;
$function$;

-- El nombre arranca con zzz_ a proposito: los triggers AFTER corren en orden
-- alfabetico y este tiene que ser el ultimo, cuando trigger_actualizar_saldo_pedido
-- ya contabilizo el cambio de total.
DROP TRIGGER IF EXISTS zzz_pedidos_reconciliar_pagos ON public.pedidos;
CREATE TRIGGER zzz_pedidos_reconciliar_pagos
AFTER UPDATE OF total ON public.pedidos
FOR EACH ROW
WHEN (NEW.total IS DISTINCT FROM OLD.total
      AND NEW.estado NOT IN ('cancelado', 'anulado'))
EXECUTE FUNCTION public.pedidos_reconciliar_pagos();

-- ---------------------------------------------------------------------------
-- 5. Las RPCs FIFO consumen el credito antes de imputar la plata nueva
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_pago_cliente_fifo(
  p_cliente_id bigint,
  p_monto numeric,
  p_forma_pago text,
  p_fecha date DEFAULT CURRENT_DATE,
  p_referencia text DEFAULT NULL::text,
  p_notas text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_acting_user uuid := auth.uid();
  v_rol text;
  v_restante numeric := p_monto;
  v_aplicar numeric;
  v_pedido record;
  v_pago_id bigint;
  v_pago_ids jsonb := '[]'::jsonb;
  v_aplicaciones jsonb := '[]'::jsonb;
  v_credito_aplicado numeric := 0;
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'Monto debe ser mayor a 0' USING ERRCODE = '22023';
  END IF;

  IF p_forma_pago IS NULL OR length(trim(p_forma_pago)) = 0 THEN
    RAISE EXCEPTION 'Forma de pago obligatoria' USING ERRCODE = '22023';
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = v_acting_user;
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  IF v_rol = 'encargado' THEN
    IF p_fecha <> CURRENT_DATE THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Primero se gasta el saldo a favor que el cliente ya tenia (mig 165), recien
  -- despues se imputa la plata nueva. Sin esto el credito no se consume nunca.
  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);

  FOR v_pedido IN
    SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, fecha
    FROM pedidos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = v_sucursal_id
      AND estado <> 'cancelado'
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND total > COALESCE(monto_pagado, 0)
    ORDER BY fecha ASC, id ASC
  LOOP
    EXIT WHEN v_restante <= 0;
    v_aplicar := LEAST(v_restante, v_pedido.total - v_pedido.pagado);

    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id
    )
    VALUES (
      p_cliente_id, v_pedido.id, v_aplicar, p_forma_pago, p_fecha,
      p_referencia, p_notas, v_acting_user, v_sucursal_id
    )
    RETURNING id INTO v_pago_id;

    v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
    v_aplicaciones := v_aplicaciones || jsonb_build_object(
      'pago_id', v_pago_id,
      'pedido_id', v_pedido.id,
      'pedido_fecha', v_pedido.fecha,
      'monto', v_aplicar
    );

    v_restante := v_restante - v_aplicar;
  END LOOP;

  IF v_restante > 0 THEN
    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id
    )
    VALUES (
      p_cliente_id, NULL, v_restante, p_forma_pago, p_fecha,
      p_referencia,
      COALESCE(NULLIF(p_notas, '') || ' ', '') || '[saldo a favor]',
      v_acting_user, v_sucursal_id
    )
    RETURNING id INTO v_pago_id;

    v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
    v_aplicaciones := v_aplicaciones || jsonb_build_object(
      'pago_id', v_pago_id,
      'pedido_id', NULL,
      'monto', v_restante,
      'saldo_a_favor', true
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'monto_total', p_monto,
    'sobrante', v_restante,
    'credito_aplicado', v_credito_aplicado,
    'pago_ids', v_pago_ids,
    'aplicaciones', v_aplicaciones
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_pago_combinado_cliente_fifo(
  p_cliente_id bigint,
  p_metodos jsonb,
  p_fecha date DEFAULT CURRENT_DATE,
  p_referencia text DEFAULT NULL::text,
  p_notas text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_acting_user uuid := auth.uid();
  v_rol text;
  v_metodo jsonb;
  v_forma text;
  v_monto numeric;
  v_restante numeric;
  v_aplicar numeric;
  v_pedido record;
  v_pago_id bigint;
  v_pago_ids jsonb := '[]'::jsonb;
  v_aplicaciones jsonb := '[]'::jsonb;
  v_monto_total numeric := 0;
  v_sobrante_total numeric := 0;
  v_notas_imputado text;
  v_credito_aplicado numeric := 0;
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF p_metodos IS NULL OR jsonb_typeof(p_metodos) <> 'array' OR jsonb_array_length(p_metodos) = 0 THEN
    RAISE EXCEPTION 'Debe enviar al menos una forma de pago' USING ERRCODE = '22023';
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = v_acting_user;
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  IF v_rol = 'encargado' THEN
    IF p_fecha <> CURRENT_DATE THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    v_monto := NULLIF(v_metodo->>'monto', '')::numeric;
    v_forma := v_metodo->>'forma_pago';
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'Cada forma de pago debe tener un monto mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF v_forma IS NULL OR length(trim(v_forma)) = 0 THEN
      RAISE EXCEPTION 'Forma de pago obligatoria' USING ERRCODE = '22023';
    END IF;
    v_monto_total := v_monto_total + v_monto;
  END LOOP;

  v_notas_imputado := NULLIF(trim(COALESCE(p_notas, '') || ' [pago combinado]'), '');

  -- Igual que en el FIFO simple: primero se gasta el credito preexistente (mig 165).
  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    v_monto := (v_metodo->>'monto')::numeric;
    v_forma := trim(v_metodo->>'forma_pago');
    v_restante := v_monto;

    FOR v_pedido IN
      SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, fecha
      FROM pedidos
      WHERE cliente_id = p_cliente_id
        AND sucursal_id = v_sucursal_id
        AND estado <> 'cancelado'
        AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
        AND total > COALESCE(monto_pagado, 0)
      ORDER BY fecha ASC, id ASC
    LOOP
      EXIT WHEN v_restante <= 0;
      v_aplicar := LEAST(v_restante, v_pedido.total - v_pedido.pagado);

      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id
      )
      VALUES (
        p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
        p_referencia, v_notas_imputado, v_acting_user, v_sucursal_id
      )
      RETURNING id INTO v_pago_id;

      v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
      v_aplicaciones := v_aplicaciones || jsonb_build_object(
        'pago_id', v_pago_id,
        'pedido_id', v_pedido.id,
        'pedido_fecha', v_pedido.fecha,
        'forma_pago', v_forma,
        'monto', v_aplicar
      );

      v_restante := v_restante - v_aplicar;
    END LOOP;

    IF v_restante > 0 THEN
      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id
      )
      VALUES (
        p_cliente_id, NULL, v_restante, v_forma, p_fecha,
        p_referencia,
        trim(COALESCE(p_notas, '') || ' [pago combinado] [saldo a favor]'),
        v_acting_user, v_sucursal_id
      )
      RETURNING id INTO v_pago_id;

      v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
      v_aplicaciones := v_aplicaciones || jsonb_build_object(
        'pago_id', v_pago_id,
        'pedido_id', NULL,
        'forma_pago', v_forma,
        'monto', v_restante,
        'saldo_a_favor', true
      );

      v_sobrante_total := v_sobrante_total + v_restante;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'monto_total', v_monto_total,
    'sobrante', v_sobrante_total,
    'credito_aplicado', v_credito_aplicado,
    'pago_ids', v_pago_ids,
    'aplicaciones', v_aplicaciones
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Helpers internos: solo se llaman desde triggers y RPCs SECURITY DEFINER
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.desafectar_sobrepago_pedido(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.aplicar_credito_cliente(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pedidos_reconciliar_pagos() FROM PUBLIC, anon, authenticated;
