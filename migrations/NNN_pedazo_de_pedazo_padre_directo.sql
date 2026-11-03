-- NNN · Un pedazo de un pedazo se mide contra el pago del que salió, no contra la raíz
-- (#1359, #1369).
--
-- QUÉ PASABA
--   Desde la 423 (#1292), un pedazo que nace después del corte de una foto se da por
--   rendido si la foto tiene su raíz (`pago_origen_id`). Pero un pedazo puede salir de
--   otro pedazo, y la raíz no dice de cuál:
--   · Pérdida: la foto de A rinde la raíz R (300) y no el pedazo Y (200, de la boleta
--     de B), que ya existía. La boleta de B baja: Y queda en 150 y nace Z (50). Z se
--     mide contra R, que está en la foto, y desaparece de todas las rendiciones.
--   · Doble conteo: la foto de A rinde el pedazo Q (200) y no su raíz R. Q se aplica en
--     parte a otra boleta y nace P (100). P se mide contra R, que no está en ninguna
--     foto, y aparece vivo además de los 200 que la foto le guardó a Q.
--
-- QUÉ CAMBIA
--   · `pagos.pago_padre_id`: el pago del que salió cada pedazo. `pago_origen_id` sigue
--     siendo la raíz (la usa la cuenta del empleado, 430), y un CHECK pide los dos o
--     ninguno. Sin FK, como la raíz: un pago se puede borrar (anularlo, o el recorte de
--     una NC en desafectar_sobrepago_pedido) y su pedazo sigue siendo un pedazo.
--   · `_rendicion_pagos`: un pago está rendido si está en una foto, o si una foto
--     tiene al ancestro que guardaba su plata al corte: el último de su cadena que ya
--     existía. Como los ids crecen por la cadena, es el ancestro cuyo hijo en la cadena
--     tiene id mayor que el corte. Se sube por `pago_padre_id` con un CTE recursivo,
--     una vez por llamada para todos los pedazos de la sucursal (un índice parcial los
--     encuentra sin leer el resto), no por fila: correlacionado, recorría `pagos`
--     entero por cada pedazo y cada nivel. Medir sólo contra el padre no alcanza: un
--     crédito rendido que se parte dos veces después de la foto (ensayo K10) dejaría
--     vivo al nieto.
--   · Los cuatro caminos que parten un pago guardan el padre: aplicar_credito_cliente,
--     imputar_credito_a_pedido_impl, _pagos_excedente_a_favor y
--     desafectar_sobrepago_pedido (sus dos ramas). Sólo suman la columna al INSERT.
--
-- QUÉ NO CAMBIA
--   · `_rendicion_tomar_foto`: decide por `_rendicion_pagos`, y su FOR SHARE sobre los
--     pagos de la foto ya cubre al padre directo, que es el que bloquea quien parte.
--   · Los locks: el orden por id de la 439, el pre-bloqueo de desafectar y su recorte
--     `ORDER BY fecha DESC, id DESC`. Las fotos ya congeladas.
--   · Un pedazo de un solo nivel da lo mismo que antes: su padre es su raíz.
--
-- FILAS VIEJAS
--   Prod tiene 0 pedazos (03/11). En otra base, el pedazo viejo toma su raíz como padre:
--   es lo que suponía la 423, así que nada cambia para él.
--
-- Revertir: reaplicar los cuerpos de la 428 (_rendicion_pagos), la 429
-- (aplicar_credito_cliente, imputar_credito_a_pedido_impl), la 406
-- (_pagos_excedente_a_favor) y la 439 (desafectar_sobrepago_pedido), y
-- `ALTER TABLE public.pagos DROP COLUMN pago_padre_id` (se lleva el CHECK).
--
-- Ensayo: scripts/test-rendicion-congelada-1248.sql (K8 a K11 y C1), y C6 del arnés
-- (scripts/concurrencia). Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos (03/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public._rendicion_pagos(bigint,date,date,bigint)', '0f3130f6d44b588983335804e998dd10'),
      ('public.aplicar_credito_cliente(bigint,bigint)', 'df6c8d45f437564006ae184be7eae994'),
      ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', '5305010585d1a18a9a9b5f8ee3e5d84b'),
      ('public._pagos_excedente_a_favor(bigint)', '5537678b67850bc2f2606fa2c74a9397'),
      ('public.desafectar_sobrepago_pedido(bigint)', 'd959ac33c325f004d7b8bba181b53e83')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1. La columna
-- ---------------------------------------------------------------------------
ALTER TABLE public.pagos ADD COLUMN pago_padre_id bigint;

COMMENT ON COLUMN public.pagos.pago_padre_id IS
  'El pago del que salió este pedazo (#1359). pago_origen_id es la raíz de la cadena. '
  'Los dos o ninguno (pagos_pedazo_con_padre). Sin FK: el padre se puede borrar.';

UPDATE public.pagos
   SET pago_padre_id = pago_origen_id
 WHERE pago_origen_id IS NOT NULL
   AND pago_padre_id IS NULL;

ALTER TABLE public.pagos
  ADD CONSTRAINT pagos_pedazo_con_padre
  CHECK ((pago_origen_id IS NULL) = (pago_padre_id IS NULL));

-- _rendicion_pagos arranca la cadena desde los pedazos de la sucursal: con este
-- índice, sin pedazos no lee nada.
CREATE INDEX pagos_pedazos_sucursal_idx ON public.pagos (sucursal_id) WHERE pago_padre_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. _rendicion_pagos: el pedazo se mide contra el que tenía su plata al corte
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._rendicion_pagos(p_sucursal_id bigint, p_desde date, p_hasta date, p_foto_de bigint DEFAULT NULL::bigint)
 RETURNS TABLE(t_id uuid, f date, pago_id bigint, cliente_id bigint, usuario_id uuid, monto numeric, forma_pago text, referencia text, notas text, pedido_id bigint, pedido_fecha date, pedido_estado text, pedido_total numeric, es_entrega_del_dia boolean, pago_created_at timestamp with time zone, congelado boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- #1328: p_foto_de es la rendicion que esta tomando su foto. El trigger corre
  -- con ella ya confirmada y su dia, para ella, sigue abierto.
  WITH RECURSIVE cerradas AS MATERIALIZED (
    SELECT rc.transportista_id, rc.fecha
      FROM rendiciones_control rc
     WHERE rc.sucursal_id = p_sucursal_id
       AND rc.estado IN ('confirmada', 'resuelta')
       AND rc.id IS DISTINCT FROM p_foto_de
  ),
  -- #1359/#1369: cada pedazo de la sucursal con cada uno de sus ancestros, y el
  -- hijo de ese ancestro en la cadena. Se sube por el padre: la raiz no alcanza,
  -- el pedazo pudo salir de otro pedazo.
  cadena (pago_id, ancestro_id, hijo_id) AS (
    SELECT p.id::bigint, p.pago_padre_id, p.id::bigint
      FROM pagos p
     WHERE p.sucursal_id = p_sucursal_id
       AND p.pago_padre_id IS NOT NULL
    UNION ALL
    SELECT c.pago_id, a.pago_padre_id, c.ancestro_id
      FROM cadena c
      JOIN pagos a ON a.id = c.ancestro_id
     WHERE a.pago_padre_id IS NOT NULL
  ),
  -- Un pedazo esta rendido si una foto tiene al ancestro que guardaba su plata al
  -- corte: el ultimo de la cadena que ya existia, o sea el que tiene a su hijo en
  -- la cadena despues del corte (los ids crecen por la cadena).
  rendidos_por_cadena AS MATERIALIZED (
    SELECT DISTINCT c.pago_id
      FROM cadena c
      JOIN rendicion_pagos_confirmados fo ON fo.pago_id = c.ancestro_id
      JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
     WHERE c.hijo_id > fo.ultimo_pago_id
       AND rc.estado IN ('confirmada', 'resuelta')
  )
  SELECT rc.transportista_id, rc.fecha, fo.pago_id, fo.cliente_id, fo.usuario_id,
         fo.monto, fo.forma_pago, fo.referencia, fo.notas,
         fo.pedido_id, fo.pedido_fecha, fo.pedido_estado, fo.pedido_total,
         fo.es_entrega_del_dia, fo.pago_created_at, true
    FROM rendiciones_control rc
    JOIN rendicion_pagos_confirmados fo ON fo.rendicion_id = rc.id
   WHERE rc.sucursal_id = p_sucursal_id
     AND rc.fecha BETWEEN p_desde AND p_hasta
     AND rc.estado IN ('confirmada', 'resuelta')
  UNION ALL
  SELECT dueno.t, COALESCE(dia.abierto, pg.fecha), pg.id::bigint,
         pg.cliente_id::bigint, pg.usuario_id,
         pg.monto, pg.forma_pago::text, pg.referencia::text, pg.notas,
         pg.pedido_id::bigint, pd.fecha, pd.estado::text, pd.total,
         COALESCE(pg.pedido_id IS NOT NULL
                  AND dia.abierto IS NULL
                  AND pd.estado = 'entregado'
                  AND COALESCE((pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                               pg.fecha) = pg.fecha, false),
         pg.created_at, false
    FROM pagos pg
    LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
   CROSS JOIN LATERAL (SELECT COALESCE(pd.transportista_id, pg.usuario_id) AS t) dueno
    -- #1328: el dia del pago esta cerrado para su chofer y la foto no lo tiene: va
    -- al dia siguiente al ultimo que cerro ese chofer, no a un hueco viejo.
    LEFT JOIN LATERAL (
      SELECT max(c.fecha) + 1 AS abierto
        FROM cerradas c
       WHERE c.transportista_id = dueno.t
         AND EXISTS (SELECT 1 FROM cerradas d
                      WHERE d.transportista_id = dueno.t AND d.fecha = pg.fecha)
    ) dia ON true
   WHERE pg.sucursal_id = p_sucursal_id
     AND pg.fecha <= p_hasta
     AND COALESCE(dia.abierto, pg.fecha) BETWEEN p_desde AND p_hasta
     AND COALESCE(pg.forma_pago, '') <> 'nota_credito'
     AND NOT EXISTS (
       SELECT 1
         FROM rendicion_pagos_confirmados fo
         JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
        WHERE fo.pago_id = pg.id
          AND rc.estado IN ('confirmada', 'resuelta'))
     AND NOT EXISTS (SELECT 1 FROM rendidos_por_cadena r WHERE r.pago_id = pg.id);
$function$;

-- ---------------------------------------------------------------------------
-- 3. Los caminos que parten un pago guardan el padre
-- ---------------------------------------------------------------------------
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
      -- #1247: FOR UPDATE. Sin lock, un cobro de esta misma boleta en otra
      -- transaccion (registrar_pagos_pedido la lockea y la salda) no se veia:
      -- el credito entraba igual y la dejaba sobrepagada. Con el lock se espera
      -- a ese cobro y se re-evalua `total > monto_pagado` sobre la version nueva;
      -- si ya no falta nada, la boleta sale y el LIMIT trae la siguiente.
      SELECT id, total - COALESCE(monto_pagado, 0) AS falta
        INTO v_pedido
        FROM pedidos
       WHERE cliente_id = p_cliente_id
         AND sucursal_id = p_sucursal_id
         AND estado NOT IN ('cancelado', 'anulado')
         AND total > COALESCE(monto_pagado, 0)
         AND id IS DISTINCT FROM v_excluir
       ORDER BY fecha ASC, id ASC
       LIMIT 1
       FOR UPDATE;

      EXIT WHEN NOT FOUND;

      v_vueltas := v_vueltas + 1;
      EXIT WHEN v_vueltas > 500;  -- backstop, no deberia alcanzarse nunca

      v_aplicar := LEAST(v_restante, v_pedido.falta);

      IF v_aplicar >= v_restante - 0.005 THEN
        UPDATE pagos
           SET pedido_id = v_pedido.id,
               -- #1329: un credito es plata que entro.
               a_cuenta = true,
               notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
         WHERE id = v_credito.id;

        v_aplicado := v_aplicado + v_restante;
        v_restante := 0;
      ELSE
        UPDATE pagos SET monto = monto - v_aplicar WHERE id = v_credito.id;

        -- mig 276 (#833): nota_credito_id viaja con el pedazo. #1248: y la raiz.
        -- #1359: y el padre directo.
        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
          pago_padre_id
        )
        SELECT cliente_id, v_pedido.id, v_aplicar, forma_pago, fecha, referencia,
               NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
               usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id),
               id
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

CREATE OR REPLACE FUNCTION public.imputar_credito_a_pedido_impl(p_pago_id bigint, p_pedido_id bigint, p_monto numeric DEFAULT NULL::numeric)
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
  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND tipo_factura = 'VB') THEN
    RAISE EXCEPTION 'El pedido #% es un vale blanco (consumo interno): no se le imputa credito', p_pedido_id
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
    -- Credito de plata con la caja de su fecha cerrada → admin. La rendicion
    -- confirmada ya no cambia (se lee de su foto, #1248), pero imputar sigue
    -- siendo una decision sobre plata de un dia cerrado.
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
    UPDATE pagos
       SET pedido_id = p_pedido_id,
           -- #1329: un credito es plata que entro.
           a_cuenta = true,
           notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
     WHERE id = p_pago_id;

    v_aplicar     := v_pago.monto;
    v_pago_imp_id := p_pago_id;
  ELSE
    UPDATE pagos SET monto = monto - v_aplicar WHERE id = p_pago_id;

    -- #1248: el pedazo apunta a la raiz. #1359: y a su padre directo.
    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
      pago_padre_id
    )
    SELECT cliente_id, p_pedido_id, v_aplicar, forma_pago, fecha, referencia,
           NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
           usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id),
           id
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

CREATE OR REPLACE FUNCTION public._pagos_excedente_a_favor(p_pedido_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pedido    RECORD;
  v_pago      RECORD;
  v_excedente numeric;
  v_mover     numeric;
  v_movido    numeric := 0;
  v_guc       text;
  v_marca     text;
BEGIN
  SELECT id, total, COALESCE(monto_pagado, 0) AS pagado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_excedente := v_pedido.pagado - v_pedido.total;
  IF v_excedente <= 0.005 THEN
    RETURN 0;
  END IF;

  v_marca := ' [excedente del pedido #' || p_pedido_id || '] [saldo a favor]';
  v_guc := current_setting('app.reimputacion_pagos', true);
  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  FOR v_pago IN
    SELECT id, monto
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
     FOR UPDATE
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_mover := LEAST(v_pago.monto, v_excedente);

    IF v_mover >= v_pago.monto - 0.005 THEN
      UPDATE pagos
         SET pedido_id = NULL,
             notas = trim(COALESCE(notas, '') || v_marca)
       WHERE id = v_pago.id;
      v_mover := v_pago.monto;
    ELSE
      UPDATE pagos SET monto = monto - v_mover WHERE id = v_pago.id;

      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
        pago_padre_id
      )
      SELECT cliente_id, NULL, v_mover, forma_pago, fecha, referencia,
             trim(COALESCE(notas, '') || v_marca),
             usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id),
             id
        FROM pagos
       WHERE id = v_pago.id;
    END IF;

    v_excedente := v_excedente - v_mover;
    v_movido    := v_movido + v_mover;
  END LOOP;

  PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);
  RETURN v_movido;
END;
$function$;

CREATE OR REPLACE FUNCTION public.desafectar_sobrepago_pedido(p_pedido_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pedido     RECORD;
  v_pago       RECORD;
  v_excedente  numeric;
  v_quitar     numeric;
  v_quitado    numeric := 0;
  v_nota       text;
  v_guc        text;
  v_marca      text;
BEGIN
  SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, estado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF v_pedido.estado IN ('cancelado', 'anulado') THEN
    RETURN 0;
  END IF;

  v_excedente := v_pedido.pagado - v_pedido.total;
  IF v_excedente <= 0.005 THEN
    RETURN 0;
  END IF;

  -- #1375: los pagos se bloquean por id, como la foto de la rendicion, los
  -- creditos y los UPDATE por pedido. El orden del bucle de abajo es de negocio y
  -- no cambia; si bloqueara el, se cruzaria con la foto con dos pagos del dia.
  PERFORM 1
     FROM pagos
    WHERE pedido_id = p_pedido_id
    ORDER BY id
      FOR UPDATE;

  -- Se recorta desde el pago mas nuevo: el excedente es lo ultimo que se cargo.
  FOR v_pago IN
    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id,
           sucursal_id, nota_credito_id, pago_origen_id, a_cuenta
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
     FOR UPDATE
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_quitar := LEAST(v_pago.monto, v_excedente);

    -- #1329: un pago a cuenta es plata que entro, no un cobro por el total de la
    -- boleta: lo que sobra queda a favor del cliente, y la caja del dia no se
    -- mueve (por eso va con el escape del guard, como la reimputacion). Decision
    -- del dueño. El credito de una NC sigue por su rama de abajo, y un adelanto de
    -- sueldo no es plata que entro: se recorta.
    IF v_pago.nota_credito_id IS NULL
       AND COALESCE(v_pago.forma_pago, '') <> 'adelanto_sueldo'
       AND (v_pago.a_cuenta OR v_pago.pago_origen_id IS NOT NULL) THEN
      v_marca := ' [baja de total del pedido #' || p_pedido_id || '] [saldo a favor]';
      v_guc := current_setting('app.reimputacion_pagos', true);
      PERFORM set_config('app.reimputacion_pagos', 'on', true);

      IF v_quitar >= v_pago.monto - 0.005 THEN
        UPDATE pagos
           SET pedido_id = NULL,
               notas = trim(COALESCE(notas, '') || v_marca)
         WHERE id = v_pago.id;
        v_quitar := v_pago.monto;
      ELSE
        UPDATE pagos SET monto = monto - v_quitar WHERE id = v_pago.id;

        -- #1359: el pedazo guarda la raiz y su padre directo.
        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, pago_origen_id, a_cuenta,
          pago_padre_id
        )
        SELECT cliente_id, NULL, v_quitar, forma_pago, fecha, referencia,
               trim(COALESCE(notas, '') || v_marca),
               usuario_id, sucursal_id, COALESCE(pago_origen_id, id), true,
               id
          FROM pagos
         WHERE id = v_pago.id;
      END IF;

      PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);

      v_excedente := v_excedente - v_quitar;
      v_quitado   := v_quitado + v_quitar;
      CONTINUE;
    END IF;
    v_nota := ' [ajustado -' || trim(to_char(v_quitar, 'FM999999990.00')) ||
              ' por baja de total del pedido ' || p_pedido_id || ']';

    IF v_pago.monto - v_quitar > 0.005 THEN
      UPDATE pagos
         SET monto = monto - v_quitar,
             notas = trim(COALESCE(notas, '') || v_nota)
       WHERE id = v_pago.id;
    ELSE
      -- CHECK pagos_monto_positivo (#1246): el pago entero se borra en vez de
      -- pasar por monto 0. El UPDATE sin cambio de monto es a proposito: pasa
      -- por la misma guarda de caja que el recorte (guard_pago_fecha_cerrada es
      -- BEFORE UPDATE OF monto y el DELETE no la dispara), asi que borrarlo
      -- entero con la caja cerrada sigue rechazado igual que antes.
      UPDATE pagos
         SET monto = monto,
             notas = trim(COALESCE(notas, '') || v_nota)
       WHERE id = v_pago.id;
      DELETE FROM pagos WHERE id = v_pago.id;
    END IF;

    -- mig 276 (#833): un credito de NC no es plata que se devuelve, es un
    -- documento. Lo que la boleta ya no necesita vuelve a saldo a favor con el
    -- mismo documento (pago sin pedido), en vez de evaporarse. La proxima
    -- imputacion (aplicar_credito_cliente, que el trigger de reconciliacion
    -- llama enseguida) lo aplica a otra boleta, y la NC vuelve a ser anulable
    -- por ese pedazo. #1359: su padre es el pago recortado, aunque se haya borrado.
    IF v_pago.nota_credito_id IS NOT NULL THEN
      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
        pago_padre_id
      ) VALUES (
        v_pago.cliente_id, NULL, v_quitar, v_pago.forma_pago, v_pago.fecha,
        v_pago.referencia,
        'Nota de credito #' || v_pago.nota_credito_id || ': vuelve por baja de total del pedido '
          || p_pedido_id || ' [saldo a favor]',
        v_pago.usuario_id, v_pago.sucursal_id, v_pago.nota_credito_id,
        COALESCE(v_pago.pago_origen_id, v_pago.id),
        v_pago.id
      );
    END IF;

    v_excedente := v_excedente - v_quitar;
    v_quitado   := v_quitado + v_quitar;
  END LOOP;

  RETURN v_quitado;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Comprobaciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  -- Todo camino que escribe pago_origen_id escribe tambien pago_padre_id.
  FOR r IN
    SELECT p.oid::regprocedure AS firma
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosrc ~ 'COALESCE\((v_pago\.)?pago_origen_id'
       AND p.prosrc !~ 'pago_padre_id'
  LOOP
    RAISE EXCEPTION '% parte pagos y no guarda pago_padre_id', r.firma;
  END LOOP;

  -- El orden de los locks de desafectar (#1375) sigue en pie.
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.desafectar_sobrepago_pedido(bigint)'::regprocedure)
       !~ 'ORDER BY id\s+FOR UPDATE'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.desafectar_sobrepago_pedido(bigint)'::regprocedure)
       !~ 'ORDER BY fecha DESC, id DESC\s+FOR UPDATE' THEN
    RAISE EXCEPTION 'desafectar_sobrepago_pedido perdio el pre-bloqueo por id o el recorte por fecha DESC';
  END IF;

  IF EXISTS (SELECT 1 FROM public.pagos WHERE (pago_origen_id IS NULL) <> (pago_padre_id IS NULL)) THEN
    RAISE EXCEPTION 'hay pedazos sin padre';
  END IF;
END
$post$;

COMMIT;
