-- Cargo de envio cuando el pedido queda por debajo del minimo (#1220)
--
-- LO QUE PIDIO EL DUENO
-- ---------------------
-- Unificar en el mismo panel (/configuracion) tres formas de tratar el minimo:
--   a · 'bloquear'  Bajo el minimo, el pedido se rechaza (lo que hace hoy, 204/205).
--   b · 'cargo'     Bajo el minimo, el pedido entra con un cargo de envio.
--   c · 'escalas'   Bajo xx se rechaza; entre xx y xxx entra con el cargo; desde
--                   xxx ni se rechaza ni se cobra envio.
-- Arranca en 'bloquear' con cargo 0 en las tres sucursales: aplicar esta
-- migracion no le cambia el comportamiento a nadie (el minimo tambien esta en 0).
--
-- COLUMNAS (politicas_comerciales)
-- --------------------------------
--   modo_minimo_pedido   'bloquear' | 'cargo' | 'escalas'
--   monto_minimo_pedido  (ya existia) es el "xx": el umbral de rechazo en
--                        'bloquear' y 'escalas', y el umbral del cargo en 'cargo'.
--   monto_envio_gratis   el "xxx": solo en 'escalas', desde este total no hay cargo.
--   cargo_envio_pedido   el cargo en $.
--
-- COMO SE REPRESENTA EN EL PEDIDO
-- -------------------------------
-- `pedidos.cargo_envio` (columna, NOT NULL default 0) y `pedidos.total` lo
-- INCLUYE: total = SUM(pedido_items.subtotal) + cargo_envio. Asi el cliente lo
-- debe (saldo, cobranza, CC-A) sin tocar nada de la cuenta corriente. Lo que NO
-- lo incluye, a proposito: total_neto, total_iva y total_real (la base fiscal y
-- del margen siguen siendo la mercaderia), las lineas de pedido_items (no hay
-- producto, ni stock, ni costo, ni huella de lote) y las comisiones y metas, que
-- salen de las lineas. Contrato de p_total: NO cambia. El front manda la suma de
-- los items y el SERVIDOR decide el cargo y lo suma al guardar (por eso el replay
-- offline cobra con la politica de cuando sincroniza, igual que el minimo).
--
-- DONDE SE DECIDE (Trampa 8: nunca CHECK sobre pedidos.total)
-- ----------------------------------------------------------
-- En el ALTA, en crear_pedido_completo y crear_pedido_completo_bot, con la
-- funcion pura-de-politica `pedido_cargo_envio(total, sucursal)`. Despues el
-- cargo es del pedido y la politica ya no lo mueve:
--   . actualizar_pedido_items lo conserva: total = items nuevos + cargo.
--   . registrar_salvedad / anular_salvedad lo conservan: el cargo es una tarifa de
--     entrega, no mercaderia; "el cliente rechaza" baja lo que se paga por la
--     mercaderia, no el envio. UNICA excepcion: sin ninguna linea viva (el cliente
--     rechazo el pedido entero) el total es 0 y el cargo no se cobra; anular la
--     salvedad lo devuelve. La regla es la misma en las cuatro funciones:
--         total = S + (CASE WHEN S > 0 THEN cargo_envio ELSE 0 END),  S = SUM(subtotal)
--   . cancelar_pedido_con_stock lo pone en 0 (VENTA-I exige total 0 en un cancelado).
--   . cambiar_tipo_factura_pedido a 'VB' lo pone en 0 (un vale blanco es consumo
--     interno a costo, saldado: no lleva envio).
--   . cambiar_cliente_pedido (reatribucion, admin) lo CONSERVA: lo pasa por el GUC
--     app.cargo_envio_forzado, porque con app.omitir_minimo_pedido el cargo de hoy
--     seria 0 y la reatribucion cambiaria lo que debe el cliente.
-- El cargo no traba la entrega: ninguna RPC de entrega ni de pago lo mira.
--
-- GATES
-- -----
--   VENTA-A  total = SUM(subtotal) + cargo efectivo (la formula de arriba).
--   VENTA-I  un cancelado tiene tambien cargo_envio = 0.
--   pedidos_proteger_columnas: cargo_envio entra en la lista de columnas que no
--     cambia un preventista/transportista por REST (igual que total).
--   Sin cambios en grants-rest.json: pedidos no tiene INSERT por REST y su UPDATE
--     es por columna; cargo_envio no se concede (lo escriben las RPCs DEFINER).
--
-- LAS FUNCIONES DE ABAJO SE PARCHEAN, NO SE COPIAN
-- ------------------------------------------------
-- Los cuerpos son grandes (hasta 43k) y pudieron driftar: se leen del catalogo
-- vivo con pg_get_functiondef y se les reemplaza un ancla que debe aparecer
-- EXACTAMENTE UNA VEZ (patron de la 205). Si el cuerpo vivo cambio, la migracion
-- se cae en vez de pisar algo.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 · Politica
-- ---------------------------------------------------------------------------
ALTER TABLE public.politicas_comerciales
  ADD COLUMN IF NOT EXISTS modo_minimo_pedido text NOT NULL DEFAULT 'bloquear',
  ADD COLUMN IF NOT EXISTS monto_envio_gratis numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cargo_envio_pedido numeric(12,2) NOT NULL DEFAULT 0;

ALTER TABLE public.politicas_comerciales
  DROP CONSTRAINT IF EXISTS politicas_modo_minimo_pedido_check,
  ADD CONSTRAINT politicas_modo_minimo_pedido_check
    CHECK (modo_minimo_pedido IN ('bloquear', 'cargo', 'escalas')),
  DROP CONSTRAINT IF EXISTS politicas_monto_envio_gratis_check,
  ADD CONSTRAINT politicas_monto_envio_gratis_check CHECK (monto_envio_gratis >= 0),
  DROP CONSTRAINT IF EXISTS politicas_cargo_envio_pedido_check,
  ADD CONSTRAINT politicas_cargo_envio_pedido_check CHECK (cargo_envio_pedido >= 0),
  -- En escalas, "xxx" tiene que estar por encima de "xx": si no, no hay tramo.
  DROP CONSTRAINT IF EXISTS politicas_escalas_envio_check,
  ADD CONSTRAINT politicas_escalas_envio_check
    CHECK (modo_minimo_pedido <> 'escalas' OR monto_envio_gratis > monto_minimo_pedido);

COMMENT ON COLUMN public.politicas_comerciales.modo_minimo_pedido IS
  'Que pasa con el pedido bajo el minimo: bloquear (se rechaza), cargo (entra con '
  'cargo de envio) o escalas (bajo monto_minimo_pedido se rechaza; hasta '
  'monto_envio_gratis entra con cargo; desde ahi, nada). Se decide al CREAR. mig 389, #1220.';
COMMENT ON COLUMN public.politicas_comerciales.monto_envio_gratis IS
  'Solo en modo escalas: desde este total el pedido no paga cargo de envio. mig 389.';
COMMENT ON COLUMN public.politicas_comerciales.cargo_envio_pedido IS
  'Cargo de envio en $ que se suma al pedido bajo el minimo (modos cargo y escalas). mig 389.';

-- Los tres valores y el monto minimo viajan juntos: son una sola decision.
CREATE OR REPLACE FUNCTION public.actualizar_politica_minimo_pedido(
  p_modo               text,
  p_monto_minimo       numeric,
  p_monto_envio_gratis numeric,
  p_cargo_envio        numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  IF p_modo IS NULL OR p_modo NOT IN ('bloquear', 'cargo', 'escalas') THEN
    RAISE EXCEPTION 'Modo de compra minima invalido: %', COALESCE(p_modo, 'NULL');
  END IF;
  IF p_monto_minimo IS NULL OR p_monto_minimo < 0 THEN
    RAISE EXCEPTION 'El monto minimo no puede ser negativo';
  END IF;
  IF p_monto_envio_gratis IS NULL OR p_monto_envio_gratis < 0 THEN
    RAISE EXCEPTION 'El monto desde el cual el envio es gratis no puede ser negativo';
  END IF;
  IF p_cargo_envio IS NULL OR p_cargo_envio < 0 THEN
    RAISE EXCEPTION 'El cargo de envio no puede ser negativo';
  END IF;
  IF p_modo = 'escalas' AND p_monto_envio_gratis <= p_monto_minimo THEN
    RAISE EXCEPTION 'En escalas, el monto desde el cual el envio es gratis tiene que superar al minimo';
  END IF;

  INSERT INTO public.politicas_comerciales
    (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido,
     actualizado_por, actualizado_en)
  VALUES (v_sucursal, p_modo, p_monto_minimo, p_monto_envio_gratis, p_cargo_envio, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET modo_minimo_pedido  = EXCLUDED.modo_minimo_pedido,
        monto_minimo_pedido = EXCLUDED.monto_minimo_pedido,
        monto_envio_gratis  = EXCLUDED.monto_envio_gratis,
        cargo_envio_pedido  = EXCLUDED.cargo_envio_pedido,
        actualizado_por     = EXCLUDED.actualizado_por,
        actualizado_en      = EXCLUDED.actualizado_en;
END;
$function$;

REVOKE ALL ON FUNCTION public.actualizar_politica_minimo_pedido(text, numeric, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_politica_minimo_pedido(text, numeric, numeric, numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2 · El pedido
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS cargo_envio numeric(12,2) NOT NULL DEFAULT 0;

ALTER TABLE public.pedidos
  DROP CONSTRAINT IF EXISTS pedidos_cargo_envio_check,
  ADD CONSTRAINT pedidos_cargo_envio_check CHECK (cargo_envio >= 0);

COMMENT ON COLUMN public.pedidos.cargo_envio IS
  'Cargo de envio por quedar bajo el minimo de la sucursal. pedidos.total lo incluye: '
  'total = SUM(subtotal) + cargo_envio (0 si no queda ninguna linea). No esta en '
  'total_neto/iva/real ni en las lineas. Lo fija el servidor al crear. mig 389, #1220.';

-- ---------------------------------------------------------------------------
-- 3 · La regla
-- ---------------------------------------------------------------------------
-- Rechazo: en 'cargo' nunca se rechaza. Es la misma funcion de la 205, con el modo.
CREATE OR REPLACE FUNCTION public.pedido_incumple_minimo(
  p_total       numeric,
  p_sucursal_id bigint
)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_minimo numeric;
  v_modo   text;
BEGIN
  -- Escape hatch: mismo criterio que app.omitir_minimo_venta (mig 174).
  IF COALESCE(current_setting('app.omitir_minimo_pedido', true), '') = '1' THEN
    RETURN NULL;
  END IF;

  SELECT pc.modo_minimo_pedido INTO v_modo
    FROM public.politicas_comerciales pc WHERE pc.sucursal_id = p_sucursal_id;

  -- #1220: en modo cargo el pedido bajo el minimo entra y paga el envio.
  IF COALESCE(v_modo, 'bloquear') = 'cargo' THEN
    RETURN NULL;
  END IF;

  v_minimo := public.monto_minimo_pedido(p_sucursal_id);

  IF v_minimo IS NULL OR v_minimo <= 0 THEN
    RETURN NULL;
  END IF;

  IF COALESCE(p_total, 0) >= v_minimo THEN
    RETURN NULL;
  END IF;

  -- El mensaje lleva los dos numeros a proposito: sale por caminos donde nadie
  -- va a ir a buscar cual era el minimo (el replay offline, el bot).
  RETURN format(
    'El pedido no alcanza la compra minima de %s. Total del pedido: %s.',
    to_char(v_minimo, 'FM$999G999G999D00'),
    to_char(COALESCE(p_total, 0), 'FM$999G999G999D00')
  );
END;
$fn$;

-- Cargo: lo que se le suma al pedido. p_total es la suma de los items (sin el
-- cargo). Espejo en src/utils/montoMinimo.ts (cargoEnvioPedido): si cambias esta
-- regla, cambia esa.
CREATE OR REPLACE FUNCTION public.pedido_cargo_envio(
  p_total       numeric,
  p_sucursal_id bigint
)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_forzado text := NULLIF(current_setting('app.cargo_envio_forzado', true), '');
  v_pol     public.politicas_comerciales%ROWTYPE;
BEGIN
  -- La reatribucion de cliente (cambiar_cliente_pedido) conserva el cargo que
  -- el pedido ya tenia, aunque la politica de hoy sea otra.
  IF v_forzado IS NOT NULL THEN
    RETURN GREATEST(v_forzado::numeric, 0);
  END IF;

  IF COALESCE(current_setting('app.omitir_minimo_pedido', true), '') = '1' THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_pol FROM public.politicas_comerciales WHERE sucursal_id = p_sucursal_id;
  IF NOT FOUND OR v_pol.cargo_envio_pedido <= 0 THEN
    RETURN 0;
  END IF;

  IF v_pol.modo_minimo_pedido = 'cargo' THEN
    -- Minimo 0 = sin umbral: nunca se cobra.
    IF v_pol.monto_minimo_pedido > 0 AND COALESCE(p_total, 0) < v_pol.monto_minimo_pedido THEN
      RETURN v_pol.cargo_envio_pedido;
    END IF;
  ELSIF v_pol.modo_minimo_pedido = 'escalas' THEN
    -- Bajo el minimo ya se rechazo (pedido_incumple_minimo); este es el tramo del medio.
    IF COALESCE(p_total, 0) >= v_pol.monto_minimo_pedido
       AND COALESCE(p_total, 0) < v_pol.monto_envio_gratis THEN
      RETURN v_pol.cargo_envio_pedido;
    END IF;
  END IF;

  RETURN 0;
END;
$fn$;

COMMENT ON FUNCTION public.pedido_cargo_envio(numeric, bigint) IS
  'Cargo de envio que le toca a un pedido nuevo (0 si ninguno). Solo del servidor: '
  'la llaman las RPCs de alta. Se evalua al CREAR. mig 389, #1220.';

-- Funcion de server: se revoca a las tres (CLAUDE.md). Los llamadores son DEFINER.
REVOKE ALL ON FUNCTION public.pedido_cargo_envio(numeric, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pedido_cargo_envio(numeric, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 4 · Helpers de parcheo (se borran al final)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig389_parchear(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text := pg_get_functiondef(p_funcion);
  v_veces int;
BEGIN
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, p_ancla;
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

CREATE OR REPLACE FUNCTION public._mig389_parchear_re(
  p_funcion regprocedure,
  p_patron  text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text := pg_get_functiondef(p_funcion);
  v_veces int;
BEGIN
  SELECT count(*) INTO v_veces FROM regexp_matches(v_def, p_patron, 'g');
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El patron aparece % veces en % (se esperaba 1). Patron: %', v_veces, p_funcion, p_patron;
  END IF;
  EXECUTE regexp_replace(v_def, p_patron, p_nuevo);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5 · crear_pedido_completo (web, replay offline, cambiar_cliente_pedido)
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  f regprocedure := 'public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date, uuid)'::regprocedure;
BEGIN
  PERFORM public._mig389_parchear(f,
    E'  v_omitir_minimo_previo TEXT;',
    E'  v_omitir_minimo_previo TEXT;\n  v_cargo_envio NUMERIC := 0; -- mig 389 (#1220)');

  -- Despues del rechazo (que sale primero) y sobre el total CALCULADO, no el declarado.
  PERFORM public._mig389_parchear(f,
    E'    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_sucursal);',
    E'    v_cargo_envio := public.pedido_cargo_envio(v_total_calc, v_sucursal); -- mig 389 (#1220)\n' ||
    E'    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_sucursal);');

  PERFORM public._mig389_parchear(f,
    E'stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id)\n  VALUES (p_cliente_id, v_fecha_pedido, p_total,',
    E'stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id, cargo_envio)\n  VALUES (p_cliente_id, v_fecha_pedido, p_total + v_cargo_envio,');

  PERFORM public._mig389_parchear(f,
    E'p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal)',
    E'p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal, v_cargo_envio)');

  PERFORM public._mig389_parchear(f,
    E'RETURN jsonb_build_object(''success'', true, ''pedido_id'', v_pedido_id)',
    E'RETURN jsonb_build_object(''success'', true, ''pedido_id'', v_pedido_id, ''cargo_envio'', v_cargo_envio)');
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · crear_pedido_completo_bot (Telegram)
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  f regprocedure := 'public.crear_pedido_completo_bot(uuid, uuid)'::regprocedure;
BEGIN
  PERFORM public._mig389_parchear(f,
    E'  v_total_neto_calc NUMERIC := 0;',
    E'  v_total_neto_calc NUMERIC := 0;\n  v_cargo_envio NUMERIC := 0; -- mig 389 (#1220)');

  PERFORM public._mig389_parchear(f,
    E'    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_pendiente.sucursal_id);',
    E'    v_cargo_envio := public.pedido_cargo_envio(v_total_calc, v_pendiente.sucursal_id); -- mig 389 (#1220)\n' ||
    E'    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_pendiente.sucursal_id);');

  PERFORM public._mig389_parchear(f,
    E'estado_pago, fecha_entrega_programada, sucursal_id, canal\n  )',
    E'estado_pago, fecha_entrega_programada, sucursal_id, canal, cargo_envio\n  )');

  PERFORM public._mig389_parchear(f,
    E'    v_pendiente.cliente_id, v_fecha_pedido, v_pendiente.total,\n    v_pendiente.total,\n    0,',
    E'    v_pendiente.cliente_id, v_fecha_pedido, v_pendiente.total + v_cargo_envio,\n    v_pendiente.total,\n    0,');

  PERFORM public._mig389_parchear(f,
    E'''pendiente'', v_fecha_entrega, v_pendiente.sucursal_id, ''bot''\n  )',
    E'''pendiente'', v_fecha_entrega, v_pendiente.sucursal_id, ''bot'', v_cargo_envio\n  )');

  PERFORM public._mig389_parchear(f,
    E'RETURN jsonb_build_object(''success'', true, ''pedido_id'', v_pedido_id, ''total'', v_pendiente.total);',
    E'RETURN jsonb_build_object(''success'', true, ''pedido_id'', v_pedido_id, ''total'', v_pendiente.total + v_cargo_envio, ''cargo_envio'', v_cargo_envio);');
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7 · actualizar_pedido_items: conserva el cargo
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  f regprocedure := 'public.actualizar_pedido_items(bigint, jsonb, uuid)'::regprocedure;
BEGIN
  PERFORM public._mig389_parchear(f,
    E'  v_total_anterior DECIMAL;',
    E'  v_total_anterior DECIMAL;\n  v_cargo_envio NUMERIC := 0; -- mig 389 (#1220)');

  -- v_total_anterior es "lo que valian los items": sin el cargo, para que el
  -- historial compare items contra items.
  PERFORM public._mig389_parchear(f,
    E'  SELECT total, usuario_id, created_at, COALESCE(tipo_factura, ''ZZ'')\n    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura',
    E'  SELECT GREATEST(total - cargo_envio, 0), usuario_id, created_at, COALESCE(tipo_factura, ''ZZ''), cargo_envio\n    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura, v_cargo_envio');

  PERFORM public._mig389_parchear(f,
    E'UPDATE pedidos SET total = v_total_nuevo, total_neto',
    E'UPDATE pedidos SET total = v_total_nuevo + CASE WHEN v_total_nuevo > 0 THEN v_cargo_envio ELSE 0 END, total_neto');
END
$patch$;

-- ---------------------------------------------------------------------------
-- 8 · Salvedades: el cargo sobrevive mientras quede alguna linea
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig389_parchear(
    (SELECT p.oid::regprocedure FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_salvedad'),
    E'     SET total = sub.total_recalc,',
    E'     SET total = sub.total_recalc + CASE WHEN sub.total_recalc > 0 THEN pedidos.cargo_envio ELSE 0 END,');

  PERFORM public._mig389_parchear(
    'public.anular_salvedad(bigint, text)'::regprocedure,
    E'    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),',
    E'    total = (SELECT COALESCE(SUM(subtotal), 0) + CASE WHEN COALESCE(SUM(subtotal), 0) > 0 THEN pedidos.cargo_envio ELSE 0 END\n' ||
    E'               FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),');
END
$patch$;

-- ---------------------------------------------------------------------------
-- 9 · Cancelar, vale blanco, reatribucion
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig389_parchear(
    'public.cancelar_pedido_con_stock(bigint, text, uuid, text)'::regprocedure,
    E'      total = 0,\n      monto_pagado = 0,',
    E'      total = 0,\n      cargo_envio = 0,\n      monto_pagado = 0,');

  PERFORM public._mig389_parchear(
    'public.cambiar_tipo_factura_pedido(bigint, character varying, uuid)'::regprocedure,
    E'         SET tipo_factura = ''VB'',\n             total        = round(v_total, 2),',
    E'         SET tipo_factura = ''VB'',\n             cargo_envio  = 0,\n             total        = round(v_total, 2),');

  PERFORM public._mig389_parchear(
    (SELECT p.oid::regprocedure FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'cambiar_cliente_pedido'),
    E'  PERFORM set_config(''app.omitir_minimo_pedido'', ''1'', true);',
    E'  PERFORM set_config(''app.omitir_minimo_pedido'', ''1'', true);\n' ||
    E'  -- mig 389 (#1220): la reatribucion conserva el cargo que el pedido ya tenia.\n' ||
    E'  PERFORM set_config(''app.cargo_envio_forzado'',\n' ||
    E'    COALESCE((SELECT cargo_envio::text FROM pedidos WHERE id = p_pedido_id), ''0''), true);');
END
$patch$;

-- ---------------------------------------------------------------------------
-- 10 · Gates
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig389_parchear_re(
    'public.auditoria_integridad()'::regprocedure,
    'HAVING\s+abs\(p\.total-COALESCE\(sum\(pi\.subtotal\),0\)\)>0\.01',
    'HAVING abs(p.total-COALESCE(sum(pi.subtotal),0)-CASE WHEN COALESCE(sum(pi.subtotal),0)>0 THEN p.cargo_envio ELSE 0 END)>0.01');

  PERFORM public._mig389_parchear_re(
    'public.auditoria_integridad()'::regprocedure,
    'COALESCE\(total_real,0\)<>0\)',
    'COALESCE(total_real,0)<>0 OR COALESCE(cargo_envio,0)<>0)');

  PERFORM public._mig389_parchear(
    'public.pedidos_proteger_columnas()'::regprocedure,
    E'''total'', ''total_neto'', ''total_iva'', ''total_real'', ''monto_pagado'',',
    E'''total'', ''total_neto'', ''total_iva'', ''total_real'', ''cargo_envio'', ''monto_pagado'',');
END
$patch$;

DROP FUNCTION public._mig389_parchear(regprocedure, text, text);
DROP FUNCTION public._mig389_parchear_re(regprocedure, text, text);

-- ---------------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_fn  text;
  v_def text;
  v_acl text;
  v_aud jsonb;
BEGIN
  -- Cada cuerpo quedo con su marca.
  FOREACH v_fn IN ARRAY ARRAY['crear_pedido_completo', 'crear_pedido_completo_bot',
                              'actualizar_pedido_items', 'registrar_salvedad', 'anular_salvedad',
                              'cancelar_pedido_con_stock', 'cambiar_tipo_factura_pedido',
                              'cambiar_cliente_pedido', 'pedidos_proteger_columnas'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_def NOT LIKE '%cargo_envio%' THEN
      RAISE EXCEPTION '% no quedo con el cargo de envio', v_fn;
    END IF;
    SELECT array_to_string(proacl, ',') INTO v_acl
      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_acl IS NOT NULL AND (v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' OR v_acl LIKE '%anon=%') THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC o anon: %', v_fn, v_acl;
    END IF;
  END LOOP;

  -- Funcion nueva de server: nadie de la API la alcanza.
  IF has_function_privilege('anon', 'public.pedido_cargo_envio(numeric, bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.pedido_cargo_envio(numeric, bigint)', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                 WHERE p.oid = 'public.pedido_cargo_envio(numeric, bigint)'::regprocedure AND a.grantee = 0) THEN
    RAISE EXCEPTION 'pedido_cargo_envio es alcanzable desde la API';
  END IF;
  -- La de la politica: authenticated si, anon y PUBLIC no.
  IF has_function_privilege('anon', 'public.actualizar_politica_minimo_pedido(text, numeric, numeric, numeric)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.actualizar_politica_minimo_pedido(text, numeric, numeric, numeric)', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                 WHERE p.oid = 'public.actualizar_politica_minimo_pedido(text, numeric, numeric, numeric)'::regprocedure AND a.grantee = 0) THEN
    RAISE EXCEPTION 'actualizar_politica_minimo_pedido tiene mal sus permisos';
  END IF;
  IF has_function_privilege('authenticated', 'public.pedido_incumple_minimo(numeric, bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'pedido_incumple_minimo volvio a ser ejecutable por authenticated (307)';
  END IF;

  -- Ningun cliente de la API escribe cargo_envio por REST.
  IF has_column_privilege('authenticated', 'public.pedidos', 'cargo_envio', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.pedidos', 'cargo_envio', 'INSERT')
     OR has_column_privilege('anon', 'public.pedidos', 'cargo_envio', 'SELECT') THEN
    RAISE EXCEPTION 'pedidos.cargo_envio tiene un grant de mas';
  END IF;

  -- Sin politica cargada, la regla no cobra ni frena nada.
  IF public.pedido_cargo_envio(1, 1) <> 0 THEN
    RAISE EXCEPTION 'Con la politica en su estado inicial no deberia haber cargo';
  END IF;
  IF EXISTS (SELECT 1 FROM public.politicas_comerciales
              WHERE modo_minimo_pedido <> 'bloquear' OR cargo_envio_pedido <> 0 OR monto_envio_gratis <> 0) THEN
    RAISE EXCEPTION 'La politica no arranco en bloquear / 0 / 0';
  END IF;

  -- Los dos gates tocados siguen en verde.
  v_aud := public.auditoria_integridad();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_aud->'checks') c
              WHERE c->>'id' IN ('VENTA-A', 'VENTA-I') AND (c->>'violaciones')::int <> 0) THEN
    RAISE EXCEPTION 'VENTA-A o VENTA-I quedaron en rojo con la formula nueva';
  END IF;
END
$verif$;

COMMIT;

-- ROLLBACK: volver a aplicar los cuerpos de las migraciones anteriores de las
-- funciones tocadas (sin cargo_envio), restaurar VENTA-A/VENTA-I y
-- pedidos_proteger_columnas, y DROP COLUMN pedidos.cargo_envio, las tres
-- columnas de politicas_comerciales, pedido_cargo_envio y
-- actualizar_politica_minimo_pedido. Con el cargo en 0 en todos los pedidos no
-- hay datos que perder.
