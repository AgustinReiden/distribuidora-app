-- Cobros 2 · #1246 y #1247 · El cobro de una boleta, por RPC.
--
-- `registrar_pagos_pedido` valida en el server el rol y la cartera, el monto, el
-- sobrepago, el cliente, la forma y la fecha. `CHECK (monto > 0)`, y
-- `mt_pagos_select` ya no le muestra al preventista pagos de clientes que la RLS
-- le oculta. #1247: `recalcular_monto_pagado_pedido` toma el lock del pedido
-- antes de sumar, y `aplicar_credito_cliente` lockea la boleta que elige. Y la
-- columna `pagos.pago_origen_id`, que la 3 usa para la foto de la rendicion.
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
-- Ensayos: scripts/test-cobros-por-rpc-1246-1249.sql y, a mano en una rama,
-- scripts/test-concurrencia-monto-pagado-1247.sql.

-- =============================================================================
-- 3 · #1248 · De que pago sale cada pedazo
-- =============================================================================

-- Al partir un pago (aplicar o imputar un credito en parte, devolver el
-- excedente de una boleta) el pedazo nuevo apunta a la raiz. Lo usa la foto de
-- la rendicion: un pedazo de un pago que una rendicion confirmada ya rindio
-- sigue siendo de esa rendicion, aunque ahora se impute a la boleta de otro
-- transportista.
ALTER TABLE public.pagos ADD COLUMN IF NOT EXISTS pago_origen_id bigint;
COMMENT ON COLUMN public.pagos.pago_origen_id IS
  'Pago raiz del que se partio este (#1248). NULL si no es un pedazo. Lo copian '
  'aplicar_credito_cliente, imputar_credito_a_pedido_impl, desafectar_sobrepago_pedido '
  'y _pagos_excedente_a_favor; lo lee _rendicion_pagos.';

-- =============================================================================
-- 4 · #1247 · El lock del pedido antes de sumar
-- =============================================================================

CREATE OR REPLACE FUNCTION public.recalcular_monto_pagado_pedido()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ids bigint[];
  v_id  bigint;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_ids := ARRAY[NEW.pedido_id];
  ELSIF TG_OP = 'DELETE' THEN
    v_ids := ARRAY[OLD.pedido_id];
  ELSIF OLD.pedido_id IS DISTINCT FROM NEW.pedido_id THEN
    v_ids := ARRAY[OLD.pedido_id, NEW.pedido_id];
  ELSE
    v_ids := ARRAY[NEW.pedido_id];
  END IF;

  -- #1247: el lock va en su propia sentencia y ANTES de sumar. En READ COMMITTED
  -- un UPDATE que espera el lock de la fila re-evalua el WHERE contra la version
  -- nueva, pero el subselect del SET sigue con la foto de su sentencia: si otra
  -- transaccion cargaba un pago al mismo pedido, la suma no lo veia y
  -- monto_pagado perdia ese pago. Despues del FOR UPDATE, el UPDATE de abajo
  -- arranca con una foto nueva, que ya ve el pago de la otra. En orden de id,
  -- para que mudar un pago entre dos boletas no se cruce con otra mudanza.
  FOR v_id IN SELECT DISTINCT x FROM unnest(v_ids) AS x WHERE x IS NOT NULL ORDER BY x LOOP
    PERFORM 1 FROM pedidos WHERE id = v_id FOR UPDATE;

    UPDATE pedidos
       SET monto_pagado = COALESCE((
         SELECT SUM(monto) FROM pagos WHERE pedido_id = v_id
       ), 0)
     WHERE id = v_id
       AND tipo_factura IS DISTINCT FROM 'VB';  -- mig 3XA
  END LOOP;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

-- =============================================================================
-- 7 · Credito: lock de la boleta, pedazos con raiz, CHECK (monto > 0)
-- =============================================================================

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
               notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
         WHERE id = v_credito.id;

        v_aplicado := v_aplicado + v_restante;
        v_restante := 0;
      ELSE
        UPDATE pagos SET monto = monto - v_aplicar WHERE id = v_credito.id;

        -- mig 276 (#833): nota_credito_id viaja con el pedazo. #1248: y la raiz.
        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id
        )
        SELECT cliente_id, v_pedido.id, v_aplicar, forma_pago, fecha, referencia,
               NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
               usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id)
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
           notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
     WHERE id = p_pago_id;

    v_aplicar     := v_pago.monto;
    v_pago_imp_id := p_pago_id;
  ELSE
    UPDATE pagos SET monto = monto - v_aplicar WHERE id = p_pago_id;

    -- #1248: el pedazo apunta a la raiz.
    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id
    )
    SELECT cliente_id, p_pedido_id, v_aplicar, forma_pago, fecha, referencia,
           NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
           usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id)
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

  -- Se recorta desde el pago mas nuevo: el excedente es lo ultimo que se cargo.
  FOR v_pago IN
    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id,
           sucursal_id, nota_credito_id, pago_origen_id
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_quitar := LEAST(v_pago.monto, v_excedente);
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
    -- por ese pedazo.
    IF v_pago.nota_credito_id IS NOT NULL THEN
      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id
      ) VALUES (
        v_pago.cliente_id, NULL, v_quitar, v_pago.forma_pago, v_pago.fecha,
        v_pago.referencia,
        'Nota de credito #' || v_pago.nota_credito_id || ': vuelve por baja de total del pedido '
          || p_pedido_id || ' [saldo a favor]',
        v_pago.usuario_id, v_pago.sucursal_id, v_pago.nota_credito_id,
        COALESCE(v_pago.pago_origen_id, v_pago.id)
      );
    END IF;

    v_excedente := v_excedente - v_quitar;
    v_quitado   := v_quitado + v_quitar;
  END LOOP;

  RETURN v_quitado;
END;
$function$;

-- =============================================================================
-- 2 · #1246 · CHECK (monto > 0)
-- =============================================================================

DO $$
DECLARE
  v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM public.pagos WHERE monto IS NULL OR monto <= 0;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'Hay % pagos con monto <= 0: revisarlos antes del CHECK', v_n;
  END IF;
END
$$;

ALTER TABLE public.pagos DROP CONSTRAINT IF EXISTS pagos_monto_positivo;
ALTER TABLE public.pagos ADD CONSTRAINT pagos_monto_positivo CHECK (monto > 0);

-- =============================================================================
-- 5 · #1246 · El cobro de una boleta, por RPC
-- =============================================================================

-- Reemplaza el INSERT REST de usePagos (alta con cobro, ModalPagoPedido, la
-- entrega con pago y el cobro de la parada del chofer). Lo que antes decidia la
-- policy mt_pagos_insert lo decide esto, y ademas lo que la policy no miraba:
--   · rol y cartera: admin y encargado, cualquier boleta de la sucursal; el
--     transportista, las que tiene asignadas; el preventista, las que vendio.
--     Un pago sin boleta es un pago a cuenta: va por el FIFO de la ficha, que
--     es solo de admin y encargado.
--   · el cliente es el de la boleta: no se recibe.
--   · cada monto > 0, y la suma no supera lo que falta (el excedente quedaba
--     atrapado en la boleta: aplicar_credito_cliente solo consume pagos sin
--     pedido y desafectar_sobrepago_pedido solo corre si cambia el total).
--   · forma: solo plata (formas_pago()).
--   · fecha: nunca futura, y solo el admin carga otra que hoy (la regla que las
--     cuatro RPCs de pago ya le ponian al encargado). La caja cerrada la sigue
--     cuidando guard_pago_fecha_cerrada.
--   · el que cobra es auth.uid(): pagos_forzar_usuario no corre adentro de una
--     DEFINER.
CREATE OR REPLACE FUNCTION public.registrar_pagos_pedido_impl(
  p_pedido_id  bigint,
  p_metodos    jsonb,
  p_fecha      date,
  p_notas      text DEFAULT NULL,
  p_referencia text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_usuario     uuid   := auth.uid();
  v_hoy         date   := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_pedido      RECORD;
  v_metodo      jsonb;
  v_monto       numeric;
  v_total       numeric := 0;
  v_falta       numeric;
  v_pago_id     bigint;
  v_pago_ids    bigint[] := '{}';
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;
  IF v_usuario IS NULL THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  IF p_pedido_id IS NULL THEN
    RAISE EXCEPTION 'Un pago sin pedido es un pago a cuenta: registralo desde la ficha del cliente.'
      USING ERRCODE = '22023';
  END IF;

  IF p_metodos IS NULL OR jsonb_typeof(p_metodos) <> 'array' OR jsonb_array_length(p_metodos) = 0 THEN
    RAISE EXCEPTION 'Debe enviar al menos una forma de pago' USING ERRCODE = '22023';
  END IF;

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    v_monto := NULLIF(v_metodo->>'monto', '')::numeric;
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'Cada forma de pago debe tener un monto mayor a 0' USING ERRCODE = '22023';
    END IF;
    PERFORM public._forma_pago_de_cobro(v_metodo->>'forma_pago', true);
    v_total := v_total + v_monto;
  END LOOP;

  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'La fecha del pago es obligatoria' USING ERRCODE = '22023';
  END IF;
  IF p_fecha > v_hoy THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;
  IF p_fecha <> v_hoy AND NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede registrar un pago con otra fecha que hoy'
      USING ERRCODE = '42501';
  END IF;

  -- Serializa contra los otros cobros de esta boleta (FIFO, masivos, otro
  -- operador): la cuenta de lo que falta es contra la version que queda.
  SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS pagado, estado,
         tipo_factura, usuario_id, transportista_id
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido no encontrado' USING ERRCODE = 'P0002';
  END IF;

  -- es_preventista() y es_transportista() dejan pasar a otros roles (trampa 4):
  -- aca solo importa que admin y encargado ya entraron por la primera rama.
  IF NOT es_encargado_o_admin()
     AND NOT (es_transportista() AND v_pedido.transportista_id IS NOT DISTINCT FROM v_usuario)
     AND NOT (es_preventista() AND v_pedido.usuario_id IS NOT DISTINCT FROM v_usuario) THEN
    RAISE EXCEPTION 'No autorizado: solo podes cobrar un pedido que vendiste o que tenes asignado'
      USING ERRCODE = '42501';
  END IF;

  -- Los mismos rechazos que los triggers (360 y 3XA), dichos antes de insertar.
  IF v_pedido.estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El pedido #% está %: no admite pagos. Registralo como pago a cuenta del cliente.',
      p_pedido_id, v_pedido.estado USING ERRCODE = '22023';
  END IF;
  IF v_pedido.tipo_factura = 'VB' THEN
    RAISE EXCEPTION 'El pedido #% es un vale blanco (consumo interno): no admite pagos', p_pedido_id
      USING ERRCODE = '22023';
  END IF;

  v_falta := v_pedido.total - v_pedido.pagado;
  IF v_total > v_falta + 0.005 THEN
    RAISE EXCEPTION 'El pago (%) supera lo que falta cobrar del pedido #% (%). Si el cliente deja plata de mas, registrala como pago a cuenta desde su ficha.',
      trim(to_char(v_total, 'FM999999990.00')), p_pedido_id,
      trim(to_char(GREATEST(v_falta, 0), 'FM999999990.00'))
      USING ERRCODE = '22023';
  END IF;

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id
    )
    VALUES (
      v_pedido.cliente_id, v_pedido.id, (v_metodo->>'monto')::numeric,
      public._forma_pago_de_cobro(v_metodo->>'forma_pago', true), p_fecha,
      NULLIF(trim(p_referencia), ''), NULLIF(trim(p_notas), ''), v_usuario, v_sucursal_id
    )
    RETURNING id INTO v_pago_id;

    v_pago_ids := v_pago_ids || v_pago_id;
  END LOOP;

  RETURN jsonb_build_object(
    'success',     true,
    'pedido_id',   v_pedido.id,
    'monto_total', v_total,
    'pago_ids',    to_jsonb(v_pago_ids),
    -- Las filas como las leia el front despues del INSERT REST
    -- (`*, usuario:perfiles(id, nombre)`): ModalRegistrarPago muestra el monto
    -- y arma el recibo con esto.
    'pagos', (
      SELECT jsonb_agg(to_jsonb(pg) || jsonb_build_object(
               'usuario', CASE WHEN u.id IS NULL THEN NULL
                               ELSE jsonb_build_object('id', u.id, 'nombre', u.nombre) END)
             ORDER BY pg.id)
        FROM pagos pg
        LEFT JOIN perfiles u ON u.id = pg.usuario_id
       WHERE pg.id = ANY (v_pago_ids)
    )
  );
END;
$function$;

-- Wrapper de idempotencia, como los de la 167: un reintento con el mismo
-- p_client_request_id devuelve el resultado guardado y no cobra dos veces.
CREATE OR REPLACE FUNCTION public.registrar_pagos_pedido(
  p_pedido_id         bigint,
  p_metodos           jsonb,
  p_fecha             date,
  p_notas             text DEFAULT NULL,
  p_referencia        text DEFAULT NULL,
  p_client_request_id uuid DEFAULT NULL
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
  -- La regla entera esta en el _impl. Esto corta antes de abrir la solicitud a
  -- quien no cobra nunca (deposito).
  IF NOT (es_preventista() OR es_transportista()) THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'registrar_pagos_pedido');
  IF v_previo IS NOT NULL THEN
    RETURN v_previo || jsonb_build_object('idempotent_replay', true);
  END IF;

  v_resultado := public.registrar_pagos_pedido_impl(
    p_pedido_id, p_metodos, p_fecha, p_notas, p_referencia
  );

  PERFORM public.pago_solicitud_cerrar(p_client_request_id, v_resultado);
  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.registrar_pagos_pedido_impl(bigint, jsonb, date, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_pagos_pedido_impl(bigint, jsonb, date, text, text)
  TO service_role;
REVOKE ALL ON FUNCTION public.registrar_pagos_pedido(bigint, jsonb, date, text, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pagos_pedido(bigint, jsonb, date, text, text, uuid)
  TO authenticated, service_role;

-- El preventista ve los pagos de los clientes que ve. El EXISTS sobre clientes
-- corre con la RLS de clientes del que lee (mt_clientes_select): la cartera, el
-- reservado y el historial (358) los decide esa policy, no una copia aca.
DROP POLICY IF EXISTS mt_pagos_select ON public.pagos;
CREATE POLICY mt_pagos_select ON public.pagos
  FOR SELECT TO authenticated
  USING (
    sucursal_id = current_sucursal_id()
    AND (
      es_encargado_o_admin()
      OR (es_transportista() AND pedido_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM pedidos pd
             WHERE pd.id = pagos.pedido_id
               AND pd.transportista_id = auth.uid()
               AND pd.sucursal_id = current_sucursal_id()))
      OR (es_preventista() AND EXISTS (
            SELECT 1 FROM clientes c WHERE c.id = pagos.cliente_id))
    )
  );
