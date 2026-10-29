-- Cobros 1 · #1249 · Una sola lista de formas de pago: `formas_pago()`.
--
-- La usan el CHECK de `pagos` y todas las RPCs que registran o cambian un pago;
-- el front la espeja con gate (src/constants/formasPago.espejo.json,
-- scripts/espejo-formas-pago.mjs).
--
-- Tarjeta 2 de #1268 (cobros y cuenta corriente), en cuatro migraciones que se
-- aplican en orden: 1 formas de pago (#1249), 2 cobro por RPC (#1246, #1247),
-- 3 cambio de cliente y rendicion congelada (#1248), 4 sin INSERT REST (#1246).
-- La 4 va despues de que el front nuevo este en prod: hasta entonces el bundle
-- viejo cobra por REST, y sin el INSERT no podria cobrar.
--
-- Prod antes de esto: 0 pagos con monto <= 0, 0 con cliente distinto del de su
-- pedido, 0 pedidos sobrepagados, 0 pagos con fecha futura. Formas en `pagos`:
-- las seis de la lista mas 5 'combinado' y 1 'cuenta_corriente' heredados, todos
-- de abril de 2026.
--
-- Ensayo: scripts/test-cobros-por-rpc-1246-1249.sql (F1, F2, P3).

-- =============================================================================
-- 1 · #1249 · La lista de formas de pago
-- =============================================================================

-- Cada valor que puede tener `pagos.forma_pago`:
--   se_registra  lo carga una persona (las RPCs de cobro). nota_credito no: la
--                crea crear_nota_credito_venta (CHECK pagos_nota_credito_coherente).
--   dineraria    es plata de la rendicion. adelanto_sueldo y nota_credito no
--                (migs 273 y 276): las rendiciones los excluyen.
-- Cambiar esta lista es cambiar tambien src/constants/formasPago.espejo.json:
-- el gate scripts/espejo-formas-pago.mjs compara las dos.
CREATE OR REPLACE FUNCTION public.formas_pago()
RETURNS TABLE (forma text, se_registra boolean, dineraria boolean)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path TO 'public'
AS $function$
  VALUES ('efectivo'::text,  true,  true),
         ('transferencia',   true,  true),
         ('cheque',          true,  true),
         ('tarjeta',         true,  true),
         ('adelanto_sueldo', true,  false),
         ('nota_credito',    false, false)
$function$;

CREATE OR REPLACE FUNCTION public.es_forma_pago(p_forma text)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.formas_pago() f WHERE f.forma = p_forma);
$function$;

-- La forma con que una persona registra un cobro, normalizada, o 22023.
-- p_solo_dineraria: el cobro de una boleta, los masivos y el cambio de forma
-- aceptan solo plata; el cobro FIFO desde la ficha acepta ademas el adelanto de
-- sueldo.
CREATE OR REPLACE FUNCTION public._forma_pago_de_cobro(p_forma text, p_solo_dineraria boolean)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_forma text := NULLIF(trim(p_forma), '');
  v_lista text;
BEGIN
  IF v_forma IS NULL THEN
    RAISE EXCEPTION 'Forma de pago obligatoria' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.formas_pago() f
                  WHERE f.forma = v_forma AND f.se_registra
                    AND (f.dineraria OR NOT p_solo_dineraria)) THEN
    SELECT string_agg(f.forma, ', ') INTO v_lista
      FROM public.formas_pago() f
     WHERE f.se_registra AND (f.dineraria OR NOT p_solo_dineraria);
    RAISE EXCEPTION 'Forma de pago invalida: %. Las validas son: %.', v_forma, v_lista
      USING ERRCODE = '22023';
  END IF;

  RETURN v_forma;
END;
$function$;

REVOKE ALL ON FUNCTION public.formas_pago() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.es_forma_pago(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._forma_pago_de_cobro(text, boolean) FROM PUBLIC, anon, authenticated;
-- Puras y sin datos: el CHECK de abajo las evalua como el que escribe.
GRANT EXECUTE ON FUNCTION public.formas_pago() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.es_forma_pago(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._forma_pago_de_cobro(text, boolean) TO service_role;

-- El CHECK reemplaza al NOT VALID de la 074 (`<> 'cuenta_corriente'`) y nace
-- VALID: los 6 heredados de abril quedan nombrados, no tolerados. Un NOT VALID
-- igual se evalua en cada UPDATE, asi que reimputar uno de esos pagos (cancelar
-- su boleta, aplicar su credito) fallaba.
ALTER TABLE public.pagos DROP CONSTRAINT IF EXISTS pagos_forma_pago_no_cuenta_corriente;
ALTER TABLE public.pagos DROP CONSTRAINT IF EXISTS pagos_forma_pago_valida;
ALTER TABLE public.pagos ADD CONSTRAINT pagos_forma_pago_valida CHECK (
  public.es_forma_pago(forma_pago::text)
  OR (forma_pago::text IN ('combinado', 'cuenta_corriente')
      AND created_at IS NOT NULL
      AND created_at < timestamptz '2026-05-01 00:00:00-03')
);

-- =============================================================================
-- 6 · #1249 · Las RPCs de pago usan la lista
-- =============================================================================

CREATE OR REPLACE FUNCTION public.registrar_pago_cliente_fifo_impl(p_cliente_id bigint, p_monto numeric, p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_referencia text DEFAULT NULL::text, p_notas text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_acting_user uuid := auth.uid();
  v_rol text;
  v_forma text;
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

  -- #1249: antes alcanzaba con un texto no vacio, y 'Efectivo' o 'mp' caian en
  -- "otros" de la rendicion. Desde la ficha tambien entra el adelanto de sueldo.
  v_forma := public._forma_pago_de_cobro(p_forma_pago, false);

  SELECT rol INTO v_rol FROM perfiles WHERE id = v_acting_user;
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
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
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND total > COALESCE(monto_pagado, 0)
    ORDER BY fecha ASC, id ASC
    -- mig 230: serializa la imputacion, igual que la 181 en
    -- marcar_pagos_masivo_impl. Sin el lock, dos cobros concurrentes al mismo
    -- cliente leen el mismo `pagado` y los dos imputan el saldo entero.
    FOR UPDATE
  LOOP
    EXIT WHEN v_restante <= 0;
    v_aplicar := LEAST(v_restante, v_pedido.total - v_pedido.pagado);

    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id
    )
    VALUES (
      p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
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
      p_cliente_id, NULL, v_restante, v_forma, p_fecha,
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

CREATE OR REPLACE FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(p_cliente_id bigint, p_metodos jsonb, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_referencia text DEFAULT NULL::text, p_notas text DEFAULT NULL::text)
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
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
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
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'Cada forma de pago debe tener un monto mayor a 0' USING ERRCODE = '22023';
    END IF;
    -- #1249: la lista es formas_pago(), no "cualquier texto no vacio".
    PERFORM public._forma_pago_de_cobro(v_metodo->>'forma_pago', false);
    v_monto_total := v_monto_total + v_monto;
  END LOOP;

  v_notas_imputado := NULLIF(trim(COALESCE(p_notas, '') || ' [pago combinado]'), '');

  -- Igual que en el FIFO simple: primero se gasta el credito preexistente (mig 165).
  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    v_monto := (v_metodo->>'monto')::numeric;
    v_forma := public._forma_pago_de_cobro(v_metodo->>'forma_pago', false);
    v_restante := v_monto;

    FOR v_pedido IN
      SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, fecha
      FROM pedidos
      WHERE cliente_id = p_cliente_id
        AND sucursal_id = v_sucursal_id
        AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
        AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
        AND total > COALESCE(monto_pagado, 0)
      ORDER BY fecha ASC, id ASC
      -- mig 230: ver registrar_pago_cliente_fifo_impl. Mismo lock, y aca
      -- ademas cada metodo de pago vuelve a recorrer los pedidos.
      FOR UPDATE
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

CREATE OR REPLACE FUNCTION public.marcar_pagos_masivo_impl(p_pedido_ids bigint[], p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
  v_rol TEXT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar pagos masivos'
      USING ERRCODE = '42501';
  END IF;

  -- #1249: antes no se validaba; ademas escribe pedidos.forma_pago.
  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);

  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();

  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
      AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
    -- mig 181: serializa el lote. Sin el lock, un cobro del chofer en la misma
    -- ventana quedaba tapado por el UPDATE de abajo.
    FOR UPDATE
  LOOP
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (
      v_pedido.cliente_id,
      v_pedido.id,
      v_pedido.total - v_pedido.ya_pagado,
      p_forma_pago,
      p_fecha,
      auth.uid(),
      v_sucursal_id
    );
  END LOOP;

  -- mig 181: ya NO se escribe monto_pagado = total. El trigger
  -- recalcular_monto_pagado_pedido lo deriva de SUM(pagos) tras el INSERT de
  -- arriba; fijarlo a mano tapaba un cobro concurrente y el pedido se veia
  -- saldado con dos pagos encima.
  UPDATE pedidos
     SET forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB';  -- mig 3XA

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$function$;

CREATE OR REPLACE FUNCTION public.marcar_entrega_y_pago_masivo_impl(p_pedido_ids bigint[], p_transportista_id uuid, p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
  v_rol TEXT;
  v_fecha_ts TIMESTAMPTZ;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar entrega y pago masivos'
      USING ERRCODE = '42501';
  END IF;

  -- #1249: antes no se validaba; ademas escribe pedidos.forma_pago.
  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);

  -- Mismo gate de rendición que marcar_pagos_masivo (esta RPC registra pagos)
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  -- 1) Registrar pago por el saldo pendiente (solo pedidos NO pagados)
  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
      AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
    FOR UPDATE
  LOOP
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (
      v_pedido.cliente_id,
      v_pedido.id,
      v_pedido.total - v_pedido.ya_pagado,
      p_forma_pago,
      p_fecha,
      auth.uid(),
      v_sucursal_id
    );
  END LOOP;

  -- 2) Entregar + saldar en un solo UPDATE (transportista_id SE asigna)
  -- mig 181: no revivir un pedido cancelado como entregado y pagado.
  UPDATE pedidos
     SET estado = 'entregado',
         fecha_entrega = v_fecha_ts,
         transportista_id = p_transportista_id,
         -- mig 230: ya NO se escribe monto_pagado = total, igual que la 181 en
         -- marcar_pagos_masivo_impl. El INSERT en pagos de arriba dispara
         -- recalcular_monto_pagado_pedido, que lo deriva de SUM(pagos). Este
         -- UPDATE alcanza a TODOS los ids del lote -- tambien los que el bucle
         -- salteo por ya estar pagados -- asi que fijarlo a mano tapaba un
         -- cobro concurrente y dejaba el pedido saldado con dos pagos encima.
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB';  -- mig 3XA

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$function$;

CREATE OR REPLACE FUNCTION public.actualizar_forma_pago_pago(p_pago_id bigint, p_forma_pago text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint;
  v_pago RECORD;
  v_forma_anterior text;
  v_nueva_forma_pedido text;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden modificar la forma de pago'
      USING ERRCODE = '42501';
  END IF;

  -- #1249: la lista es formas_pago(). Antes aceptaba 'cuenta_corriente', que
  -- el CHECK de pagos rechaza.
  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);

  SELECT id, pedido_id, fecha, forma_pago
    INTO v_pago
    FROM pagos
   WHERE id = p_pago_id
     AND sucursal_id = v_sucursal_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pago no encontrado' USING ERRCODE = 'P0002';
  END IF;

  v_forma_anterior := COALESCE(v_pago.forma_pago, 'efectivo');

  IF v_forma_anterior = 'adelanto_sueldo' THEN
    RAISE EXCEPTION 'Un adelanto de sueldo no se puede cambiar de forma de pago; anulalo y registra el pago correcto'
      USING ERRCODE = '22023';
  END IF;

  -- mig 276 (#833): el credito de una nota de credito tampoco. Se anula la NC.
  IF v_forma_anterior = 'nota_credito' THEN
    RAISE EXCEPTION 'El credito de una nota de credito no se puede cambiar de forma de pago; anula la nota de credito'
      USING ERRCODE = '22023';
  END IF;

  IF v_forma_anterior = p_forma_pago THEN
    RETURN jsonb_build_object(
      'success', true,
      'pago_id', v_pago.id,
      'forma_pago_anterior', v_forma_anterior,
      'forma_pago_nueva', p_forma_pago,
      'pedido_forma_pago', NULL
    );
  END IF;

  IF public.rendicion_dia_cerrada(v_pago.fecha, v_sucursal_id) THEN
    RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. No se puede modificar.'
      USING ERRCODE = '42501';
  END IF;

  UPDATE pagos
     SET forma_pago = p_forma_pago
   WHERE id = p_pago_id;

  IF v_pago.pedido_id IS NOT NULL THEN
    SELECT forma_pago
      INTO v_nueva_forma_pedido
      FROM pagos
     WHERE pedido_id = v_pago.pedido_id
       AND COALESCE(forma_pago, '') NOT IN ('adelanto_sueldo', 'nota_credito')
     ORDER BY monto DESC NULLS LAST, created_at DESC NULLS LAST
     LIMIT 1;

    UPDATE pedidos
       SET forma_pago = COALESCE(v_nueva_forma_pedido, p_forma_pago),
           updated_at = now()
     WHERE id = v_pago.pedido_id
       AND sucursal_id = v_sucursal_id;

    INSERT INTO pedido_historial (
      pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id
    )
    VALUES (
      v_pago.pedido_id,
      auth.uid(),
      'forma_pago_pago_' || v_pago.id::text,
      v_forma_anterior,
      p_forma_pago,
      v_sucursal_id
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'pago_id', v_pago.id,
    'forma_pago_anterior', v_forma_anterior,
    'forma_pago_nueva', p_forma_pago,
    'pedido_forma_pago', v_nueva_forma_pedido
  );
END;
$function$;
