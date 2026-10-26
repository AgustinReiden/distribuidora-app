-- NNN · Cargo de envio: estado del cargo, regla sin productos, puras y desglose
-- fiscal (lo que falta del cargo de envio sobre la 389, #1220).
--
-- Diseno: docs/superpowers/specs/2026-10-26-cargo-envio-faltantes-design.md.
-- Primera de las migraciones del plan; la edicion (actualizar_pedido_items) va
-- en la siguiente.
--
-- 1) pedidos.cargo_envio_estado  'no_aplica' | 'cobrado' | 'gratis' | 'bonificado'.
--    La fija el ALTA: si la politica de la sucursal cobra envio (modo cargo o
--    escalas, cargo > 0 y umbral > 0) queda 'cobrado' (cargo > 0) o 'gratis';
--    si no, 'no_aplica'. Vale blanco y canje: 'no_aplica' (el default: el VB y
--    crear_pedido_cambio_en_ruta no la nombran). La cambia la edicion (la mig
--    siguiente), incluido 'bonificado' por decision del admin. El rechazo total
--    NO la cambia: lo resuelve la formula de la 389 (sin lineas, el cargo no se
--    cobra). Pasar a VB la deja en 'no_aplica' con el cargo en 0. Cancelar pone
--    el cargo en 0 y no la toca: el CHECK exime al cancelado y al anulado.
--    CHECK pedidos_cargo_estado_coherente: cobrado <=> cargo_envio > 0.
--    Hace falta para la regla de la edicion ("un pedido que nacio sin cargo de
--    politica nunca lo gana") y para las metricas ("gratis" no se deduce despues).
--    cambiar_cliente_pedido conserva el estado como ya conservaba el cargo: lo
--    pasa por app.cargo_envio_estado_forzado (sin eso un no_aplica o un
--    bonificado reatribuido nacerian 'gratis'). Un 'cobrado' forzado que se queda
--    sin cargo (el pedido nuevo no tiene productos) nace 'gratis', igual que en
--    cargo_tras_edicion: el CHECK cobrado <=> cargo > 0 vale siempre.
--
-- 2) Un pedido sin productos nunca paga envio. pedido_cargo_envio devuelve 0 si
--    el total de productos es <= 0, ANTES de todo, incluido el cargo forzado de la
--    reatribucion: un pedido sin productos no paga envio ni reatribuido (si no,
--    el cliente nuevo deberia un envio sin mercaderia, el neto/IVA lo llevaria y
--    VENTA-A quedaria en rojo, que su formula lo lleva a 0). Antes, un pedido de
--    puro regalo en modo cargo pagaba el envio y VENTA-A quedaba en rojo.
--
-- 3) Puras IMMUTABLE con espejo en src/utils/montoMinimo.ts (gate:
--    src/utils/cargoEnvio.espejo.json + scripts/espejo-cargo-envio.mjs):
--      cargo_envio_pedido_puro  <-> cargoEnvioPedido   (la regla del alta)
--      cargo_envio_desglose     <-> cargoDesglose      (neto/IVA del envio)
--      cargo_tras_edicion       <-> cargoTrasEdicion   (la usa la mig siguiente)
--    Si cambias una, cambia la otra y suma el caso al fixture. Son de server:
--    sin EXECUTE para PUBLIC/anon/authenticated, con EXECUTE para service_role
--    (el gate de paridad las llama con esa key).
--
-- 4) IVA del envio. El cargo es precio final: ZZ todo neto; FC neto =
--    round(cargo / 1.21, 2) e IVA = cargo - neto; VB nada. Entra en
--    total_neto/total_iva (asi posicion_fiscal declara el IVA del envio);
--    total_real NO lo incluye (sigue siendo la base del margen). Se usa el cargo
--    EFECTIVO: 0 si el pedido quedo sin productos. Lo suman el alta (web y bot),
--    registrar_salvedad, anular_salvedad y cambiar_tipo_factura_pedido (ZZ<->FC).
--    actualizar_pedido_items va en la mig siguiente.
--
-- 5) Respuestas (compatibles con el front en produccion: solo claves nuevas):
--    crear_pedido_completo agrega 'total' (el guardado, con el cargo);
--    crear_pedido_idempotente, en la rama idempotente, devuelve 'total' y
--    'cargo_envio' del pedido existente (el front compara el total guardado con
--    el enviado: con cargo no coinciden). Como cambia el cuerpo de
--    crear_pedido_idempotente, se actualiza su md5 en la lista blanca de
--    auditoria_definer_sin_rol (SEG-A, #1074): la funcion sigue sin abrir nada,
--    solo devuelve dos campos mas del pedido que ya devolvia por id.
--
-- Ninguna firma cambia. Las funciones grandes se PARCHEAN por ancla sobre la
-- definicion viva (molde de la 373): cada ancla tiene que aparecer exactamente
-- una vez, o la migracion se cae en vez de pisar algo.
--
-- Ensayo: scripts/test-cargo-1.sql.

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1 · La columna
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS cargo_envio_estado text NOT NULL DEFAULT 'no_aplica';

-- Backfill: el unico estado que se deduce del dato es 'cobrado' (hoy 0 filas).
UPDATE public.pedidos
   SET cargo_envio_estado = 'cobrado'
 WHERE cargo_envio > 0 AND cargo_envio_estado <> 'cobrado';

ALTER TABLE public.pedidos
  DROP CONSTRAINT IF EXISTS pedidos_cargo_envio_estado_check,
  ADD CONSTRAINT pedidos_cargo_envio_estado_check
    CHECK (cargo_envio_estado IN ('no_aplica', 'cobrado', 'gratis', 'bonificado')),
  DROP CONSTRAINT IF EXISTS pedidos_cargo_estado_coherente,
  ADD CONSTRAINT pedidos_cargo_estado_coherente
    CHECK (estado IN ('cancelado', 'anulado')
           OR ((cargo_envio_estado = 'cobrado') = (cargo_envio > 0)));

COMMENT ON COLUMN public.pedidos.cargo_envio_estado IS
  'Estado del cargo de envio: no_aplica (la politica no cobraba al crear, VB, canje), '
  'cobrado (cargo_envio > 0), gratis (la politica cobra y el pedido no pago) o '
  'bonificado (el admin decidio no cobrarlo al editar). Lo fija el alta y lo cambia '
  'la edicion; el rechazo total no lo toca. cobrado <=> cargo_envio > 0 salvo '
  'cancelado/anulado. Lo escriben solo las RPCs DEFINER. mig NNN (cargo_1_base).';

-- ---------------------------------------------------------------------------
-- 2 · Puras (espejo de src/utils/montoMinimo.ts)
-- ---------------------------------------------------------------------------

-- La regla del alta sin leer la tabla. p_total es la suma de los items, SIN el
-- cargo. Espejo: cargoEnvioPedido.
CREATE OR REPLACE FUNCTION public.cargo_envio_pedido_puro(
  p_total              numeric,
  p_modo               text,
  p_monto_minimo       numeric,
  p_monto_envio_gratis numeric,
  p_cargo              numeric
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  t numeric := COALESCE(p_total, 0);
BEGIN
  -- Sin productos no hay envio que cobrar.
  IF t <= 0 THEN
    RETURN 0;
  END IF;
  IF NOT (COALESCE(p_cargo, 0) > 0) THEN
    RETURN 0;
  END IF;
  IF p_modo = 'cargo' THEN
    -- Minimo 0 = sin umbral: nunca se cobra.
    RETURN CASE WHEN COALESCE(p_monto_minimo, 0) > 0 AND t < p_monto_minimo THEN p_cargo ELSE 0 END;
  ELSIF p_modo = 'escalas' THEN
    -- Bajo el minimo ya se rechazo (pedido_incumple_minimo); este es el tramo del medio.
    RETURN CASE WHEN t >= COALESCE(p_monto_minimo, 0) AND t < COALESCE(p_monto_envio_gratis, 0)
                THEN p_cargo ELSE 0 END;
  END IF;
  RETURN 0;
END;
$fn$;

COMMENT ON FUNCTION public.cargo_envio_pedido_puro(numeric, text, numeric, numeric, numeric) IS
  'Cargo de envio de un pedido nuevo segun la politica que se le pasa (0 si ninguno; '
  '0 sin productos). Espejo de cargoEnvioPedido (src/utils/montoMinimo.ts), gate '
  'cargoEnvio.espejo.json. mig NNN (cargo_1_base).';

-- Neto e IVA de un cargo. NULL o un tipo desconocido = ZZ. Espejo: cargoDesglose.
CREATE OR REPLACE FUNCTION public.cargo_envio_desglose(
  p_cargo        numeric,
  p_tipo_factura text,
  OUT neto       numeric,
  OUT iva        numeric
)
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $fn$
BEGIN
  IF NOT (COALESCE(p_cargo, 0) > 0) OR p_tipo_factura IS NOT DISTINCT FROM 'VB' THEN
    neto := 0;
    iva  := 0;
  ELSIF p_tipo_factura IS DISTINCT FROM 'FC' THEN
    neto := round(p_cargo, 2);
    iva  := 0;
  ELSE
    -- El cargo es precio final: el 21 % va incluido.
    neto := round(p_cargo / 1.21, 2);
    iva  := round(p_cargo - neto, 2);
  END IF;
END;
$fn$;

COMMENT ON FUNCTION public.cargo_envio_desglose(numeric, text) IS
  'Neto e IVA de un cargo de envio (precio final): FC 21 % incluido, ZZ (y NULL o '
  'desconocido) todo neto, VB nada. Espejo de cargoDesglose, gate '
  'cargoEnvio.espejo.json. mig NNN (cargo_1_base).';

-- El cargo tras editar los items. p_total_viejo y p_total_nuevo son totales de
-- PRODUCTOS (sin el cargo). Espejo: cargoTrasEdicion.
CREATE OR REPLACE FUNCTION public.cargo_tras_edicion(
  p_estado             text,
  p_cargo_actual       numeric,
  p_total_viejo        numeric,
  p_total_nuevo        numeric,
  p_modo               text,
  p_monto_minimo       numeric,
  p_monto_envio_gratis numeric,
  p_cargo_vigente      numeric,
  p_es_preventista     boolean,
  p_decision           text,
  OUT cargo             numeric,
  OUT estado            text,
  OUT requiere_decision boolean
)
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  -- Desde que total no se paga envio: el minimo en cargo, el "gratis" en escalas.
  v_umbral numeric := CASE p_modo WHEN 'cargo'   THEN COALESCE(p_monto_minimo, 0)
                                  WHEN 'escalas' THEN COALESCE(p_monto_envio_gratis, 0)
                                  ELSE 0 END;
  v_cobra  boolean;
  v_vieja  text;
  v_nueva  text;
BEGIN
  cargo := p_cargo_actual;
  estado := p_estado;
  requiere_decision := false;

  v_cobra := p_modo IN ('cargo', 'escalas') AND COALESCE(p_cargo_vigente, 0) > 0 AND v_umbral > 0;
  -- Un pedido que nacio sin cargo de politica nunca lo gana; y si la sucursal
  -- hoy no cobra, no se recalcula nada.
  IF p_estado IS NOT DISTINCT FROM 'no_aplica' OR NOT COALESCE(v_cobra, false) THEN
    RETURN;
  END IF;

  -- Sin productos nunca paga envio, sea quien sea el que edita.
  IF NOT (COALESCE(p_total_nuevo, 0) > 0) THEN
    cargo := 0;
    estado := 'gratis';
    RETURN;
  END IF;

  -- debajo <=> 0 < total < umbral.
  v_nueva := CASE WHEN p_total_nuevo > 0 AND p_total_nuevo < v_umbral THEN 'debajo' ELSE 'arriba' END;
  v_vieja := CASE WHEN COALESCE(p_total_viejo, 0) > 0 AND p_total_viejo < v_umbral THEN 'debajo' ELSE 'arriba' END;
  -- Sin cruce de franja, el pedido conserva lo que tenia.
  IF v_vieja = v_nueva THEN
    RETURN;
  END IF;

  -- Con cruce, solo se decide si hay algo para sacar o para agregar.
  IF v_nueva = 'arriba' THEN
    -- (a) Sube sin cargo (gratis o bonificado): no hay envio que sacar.
    -- (c) Sube con cargo: el preventista no decide; el admin lo saca o lo deja
    --     con el cargo del pedido (no el vigente: dejar no es volver a cobrar).
    IF NOT (COALESCE(p_cargo_actual, 0) > 0) OR COALESCE(p_es_preventista, false)
       OR p_decision IS NOT DISTINCT FROM 'no_cobrar' THEN
      cargo := 0;
      estado := 'gratis';
    ELSIF p_decision IS NOT DISTINCT FROM 'cobrar' THEN
      cargo := p_cargo_actual;
      estado := 'cobrado';
    ELSE
      -- Admin o encargado sin decision: queda como esta y se pide una.
      requiere_decision := true;
    END IF;
    RETURN;
  END IF;

  -- (b) Baja ya pagando (p. ej. tras cambiar el umbral): no hay envio que agregar.
  IF COALESCE(p_cargo_actual, 0) > 0 THEN
    RETURN;
  END IF;
  -- (d) Baja sin cargo: el preventista cobra el vigente; el admin decide.
  IF COALESCE(p_es_preventista, false) OR p_decision IS NOT DISTINCT FROM 'cobrar' THEN
    cargo := p_cargo_vigente;
    estado := 'cobrado';
  ELSIF p_decision IS NOT DISTINCT FROM 'no_cobrar' THEN
    cargo := 0;
    estado := 'bonificado';
  ELSE
    requiere_decision := true;
  END IF;
END;
$fn$;

COMMENT ON FUNCTION public.cargo_tras_edicion(text, numeric, numeric, numeric, text, numeric, numeric, numeric, boolean, text) IS
  'Cargo y estado del envio tras editar los items (totales de productos, sin el '
  'cargo): solo se reconsidera si el total cruza la franja. Espejo de '
  'cargoTrasEdicion, gate cargoEnvio.espejo.json. mig NNN (cargo_1_base).';

REVOKE ALL ON FUNCTION public.cargo_envio_pedido_puro(numeric, text, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cargo_envio_desglose(numeric, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cargo_tras_edicion(text, numeric, numeric, numeric, text, numeric, numeric, numeric, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cargo_envio_pedido_puro(numeric, text, numeric, numeric, numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.cargo_envio_desglose(numeric, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.cargo_tras_edicion(text, numeric, numeric, numeric, text, numeric, numeric, numeric, boolean, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3 · La regla con la politica de la sucursal
-- ---------------------------------------------------------------------------
-- Misma firma y mismo comportamiento que la 389, con dos cambios: sin productos
-- no hay cargo (antes que nada, tambien antes del forzado de la reatribucion) y
-- el calculo es la pura.
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
  -- mig NNN (cargo_1_base): un pedido sin productos (puro regalo) nunca paga
  -- envio, tampoco reatribuido.
  IF COALESCE(p_total, 0) <= 0 THEN
    RETURN 0;
  END IF;

  -- La reatribucion de cliente (cambiar_cliente_pedido) conserva el cargo que
  -- el pedido ya tenia, aunque la politica de hoy sea otra.
  IF v_forzado IS NOT NULL THEN
    RETURN GREATEST(v_forzado::numeric, 0);
  END IF;

  IF COALESCE(current_setting('app.omitir_minimo_pedido', true), '') = '1' THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_pol FROM public.politicas_comerciales WHERE sucursal_id = p_sucursal_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  RETURN public.cargo_envio_pedido_puro(p_total, v_pol.modo_minimo_pedido, v_pol.monto_minimo_pedido,
                                        v_pol.monto_envio_gratis, v_pol.cargo_envio_pedido);
END;
$fn$;

REVOKE ALL ON FUNCTION public.pedido_cargo_envio(numeric, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pedido_cargo_envio(numeric, bigint) TO service_role;

-- El estado con que nace un pedido no VB del alta (web, replay offline, bot).
-- cambiar_cliente_pedido lo fuerza con app.cargo_envio_estado_forzado.
CREATE OR REPLACE FUNCTION public._cargo_envio_estado_alta(
  p_cargo       numeric,
  p_sucursal_id bigint
)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_forzado text := NULLIF(current_setting('app.cargo_envio_estado_forzado', true), '');
  v_pol     public.politicas_comerciales%ROWTYPE;
BEGIN
  IF COALESCE(p_cargo, 0) > 0 THEN
    RETURN 'cobrado';
  END IF;
  -- Sin cargo, un 'cobrado' forzado (reatribuir un pedido que quedo sin
  -- productos) nace 'gratis', como en cargo_tras_edicion.
  IF v_forzado = 'cobrado' THEN
    RETURN 'gratis';
  END IF;
  IF v_forzado IN ('no_aplica', 'gratis', 'bonificado') THEN
    RETURN v_forzado;
  END IF;
  SELECT * INTO v_pol FROM public.politicas_comerciales WHERE sucursal_id = p_sucursal_id;
  -- La politica cobra envio: modo cargo o escalas, cargo > 0 y umbral > 0
  -- (politicaCobraCargo en el front).
  IF FOUND
     AND v_pol.modo_minimo_pedido IN ('cargo', 'escalas')
     AND v_pol.cargo_envio_pedido > 0
     AND (CASE v_pol.modo_minimo_pedido WHEN 'cargo' THEN v_pol.monto_minimo_pedido
                                        ELSE v_pol.monto_envio_gratis END) > 0 THEN
    RETURN 'gratis';
  END IF;
  RETURN 'no_aplica';
END;
$fn$;

COMMENT ON FUNCTION public._cargo_envio_estado_alta(numeric, bigint) IS
  'Estado del cargo de envio de un pedido nuevo (no VB): cobrado si hay cargo, '
  'gratis si la politica cobra envio, si no no_aplica. Solo del servidor. mig NNN.';

-- Funcion de server: la llaman RPCs DEFINER (como su dueno). Nadie de la API.
REVOKE ALL ON FUNCTION public._cargo_envio_estado_alta(numeric, bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4 · Parches por ancla sobre la definicion viva
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.cargo1_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_veces int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF v_veces <> 1 THEN
    RAISE EXCEPTION '%: el ancla aparece % veces (se esperaba 1). El cuerpo vivo cambio: revisar a mano', p_que, v_veces;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- 4a · crear_pedido_completo (web, replay offline, cambiar_cliente_pedido)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo1_parchar(v_def,
$q$  v_cargo_envio NUMERIC := 0; -- mig 389 (#1220)$q$,
$q$  v_cargo_envio NUMERIC := 0; -- mig 389 (#1220)
  v_cargo_estado TEXT := 'no_aplica'; -- cargo_1_base: VB queda en no_aplica$q$,
    'crear_pedido_completo: declaracion');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$    v_cargo_envio := public.pedido_cargo_envio(v_total_calc, v_sucursal); -- mig 389 (#1220)$q$,
$q$    v_cargo_envio := public.pedido_cargo_envio(v_total_calc, v_sucursal); -- mig 389 (#1220)
    v_cargo_estado := public._cargo_envio_estado_alta(v_cargo_envio, v_sucursal); -- cargo_1_base$q$,
    'crear_pedido_completo: estado');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$fecha_entrega_programada, sucursal_id, cargo_envio)$q$,
$q$fecha_entrega_programada, sucursal_id, cargo_envio, cargo_envio_estado)$q$,
    'crear_pedido_completo: columnas del INSERT');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$v_fecha_entrega, v_sucursal, v_cargo_envio)$q$,
$q$v_fecha_entrega, v_sucursal, v_cargo_envio, v_cargo_estado)$q$,
    'crear_pedido_completo: valores del INSERT');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$     SET total_neto = round(v_total_neto_calc, 2),
         total_iva  = round(v_total_iva_calc, 2),$q$,
$q$     SET total_neto = round(v_total_neto_calc, 2)
                      + (public.cargo_envio_desglose(v_cargo_envio, v_tipo_factura)).neto, -- cargo_1_base
         total_iva  = round(v_total_iva_calc, 2)
                      + (public.cargo_envio_desglose(v_cargo_envio, v_tipo_factura)).iva,$q$,
    'crear_pedido_completo: neto/IVA del cierre');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$'pedido_id', v_pedido_id, 'cargo_envio', v_cargo_envio)$q$,
$q$'pedido_id', v_pedido_id, 'cargo_envio', v_cargo_envio,
                            -- cargo_1_base: el total guardado, con el cargo.
                            'total', (SELECT total FROM pedidos WHERE id = v_pedido_id AND sucursal_id = v_sucursal))$q$,
    'crear_pedido_completo: respuesta');

  EXECUTE v_def;
END
$patch$;

-- 4b · crear_pedido_completo_bot (Telegram, siempre ZZ)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo1_parchar(v_def,
$q$estado_pago, fecha_entrega_programada, sucursal_id, canal, cargo_envio$q$,
$q$estado_pago, fecha_entrega_programada, sucursal_id, canal, cargo_envio, cargo_envio_estado$q$,
    'crear_pedido_completo_bot: columnas del INSERT');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$'pendiente', v_fecha_entrega, v_pendiente.sucursal_id, 'bot', v_cargo_envio$q$,
$q$'pendiente', v_fecha_entrega, v_pendiente.sucursal_id, 'bot', v_cargo_envio,
    public._cargo_envio_estado_alta(v_cargo_envio, v_pendiente.sucursal_id) -- cargo_1_base$q$,
    'crear_pedido_completo_bot: valores del INSERT');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$     SET total_neto = round(v_total_neto_calc, 2),
         total_real = round(v_total_real_calc, 2)$q$,
$q$     SET total_neto = round(v_total_neto_calc, 2)
                      + (public.cargo_envio_desglose(v_cargo_envio, 'ZZ')).neto, -- cargo_1_base
         total_iva  = (public.cargo_envio_desglose(v_cargo_envio, 'ZZ')).iva,
         total_real = round(v_total_real_calc, 2)$q$,
    'crear_pedido_completo_bot: neto/IVA del cierre');

  EXECUTE v_def;
END
$patch$;

-- 4c · crear_pedido_idempotente: el reintento devuelve el total y el cargo
-- guardados, y su md5 en la lista blanca de SEG-A.
DO $patch$
DECLARE
  f        regprocedure := 'public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)'::regprocedure;
  v_def    text := pg_get_functiondef(f);
  v_md5_ant text;
  v_md5_nvo text;
  v_lista  text;
BEGIN
  SELECT md5(prosrc) INTO v_md5_ant FROM pg_proc WHERE oid = f;

  v_def := pg_temp.cargo1_parchar(v_def,
$q$  v_existing_sucursal BIGINT;$q$,
$q$  v_existing_sucursal BIGINT;
  v_existing_total    NUMERIC; -- cargo_1_base
  v_existing_cargo    NUMERIC;$q$,
    'crear_pedido_idempotente: declaracion');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$    SELECT id, sucursal_id
      INTO v_existing, v_existing_sucursal$q$,
$q$    SELECT id, sucursal_id, total, cargo_envio
      INTO v_existing, v_existing_sucursal, v_existing_total, v_existing_cargo$q$,
    'crear_pedido_idempotente: lookup');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$RETURN jsonb_build_object('success', true, 'pedido_id', v_existing, 'idempotente', true);$q$,
$q$RETURN jsonb_build_object('success', true, 'pedido_id', v_existing, 'idempotente', true,
                                  'total', v_existing_total, 'cargo_envio', v_existing_cargo);$q$,
    'crear_pedido_idempotente: respuesta idempotente');

  EXECUTE v_def;

  SELECT md5(prosrc) INTO v_md5_nvo FROM pg_proc WHERE oid = f;
  v_lista := pg_temp.cargo1_parchar(pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure),
    quote_literal(v_md5_ant), quote_literal(v_md5_nvo),
    'auditoria_definer_sin_rol: md5 de crear_pedido_idempotente');
  EXECUTE v_lista;
END
$patch$;

-- 4d · Salvedades: el envio efectivo entra al neto/IVA (0 sin lineas)
DO $patch$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_def := pg_temp.cargo1_parchar(v_def,
$q$         total_neto = sub.neto_recalc,
         total_iva = sub.iva_recalc,$q$,
$q$         -- cargo_1_base: el envio efectivo (0 si no quedo ninguna linea).
         total_neto = sub.neto_recalc
                      + (public.cargo_envio_desglose(CASE WHEN sub.total_recalc > 0 THEN pedidos.cargo_envio ELSE 0 END,
                                                     pedidos.tipo_factura)).neto,
         total_iva = sub.iva_recalc
                     + (public.cargo_envio_desglose(CASE WHEN sub.total_recalc > 0 THEN pedidos.cargo_envio ELSE 0 END,
                                                    pedidos.tipo_factura)).iva,$q$,
    'registrar_salvedad: neto/IVA');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_def := pg_temp.cargo1_parchar(v_def,
$q$    total_neto = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(neto_unitario, precio_unitario) ELSE 0 END), 0)$q$,
$q$    total_neto = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(neto_unitario, precio_unitario) ELSE 0 END), 0)
                         -- cargo_1_base: el envio efectivo (0 si no queda ninguna linea).
                         + (public.cargo_envio_desglose(CASE WHEN COALESCE(SUM(subtotal), 0) > 0 THEN pedidos.cargo_envio ELSE 0 END,
                                                       pedidos.tipo_factura)).neto$q$,
    'anular_salvedad: neto');
  v_def := pg_temp.cargo1_parchar(v_def,
$q$    total_iva = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(iva_unitario, 0) ELSE 0 END), 0)$q$,
$q$    total_iva = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(iva_unitario, 0) ELSE 0 END), 0)
                        + (public.cargo_envio_desglose(CASE WHEN COALESCE(SUM(subtotal), 0) > 0 THEN pedidos.cargo_envio ELSE 0 END,
                                                      pedidos.tipo_factura)).iva$q$,
    'anular_salvedad: IVA');
  EXECUTE v_def;
END
$patch$;

-- 4e · cambiar_tipo_factura_pedido: a VB queda no_aplica; ZZ<->FC rehace el
-- desglose del envio con el tipo nuevo.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo1_parchar(v_def,
$q$             cargo_envio  = 0,$q$,
$q$             cargo_envio  = 0,
             cargo_envio_estado = 'no_aplica', -- cargo_1_base$q$,
    'cambiar_tipo_factura_pedido: a VB');

  v_def := pg_temp.cargo1_parchar(v_def,
$q$  UPDATE pedidos
     SET tipo_factura = p_tipo,
         total_neto = round(v_total_neto, 2),$q$,
$q$  -- cargo_1_base: el envio efectivo (total - venta de productos) entra al
  -- neto/IVA con el tipo nuevo; tambien en la respuesta.
  v_total_neto := v_total_neto + COALESCE((
    SELECT d.neto FROM pedidos p
     CROSS JOIN LATERAL public.cargo_envio_desglose(p.total - GREATEST(p.total - p.cargo_envio, 0), p_tipo) d
     WHERE p.id = p_pedido_id AND p.sucursal_id = v_sucursal), 0);
  v_total_iva := v_total_iva + COALESCE((
    SELECT d.iva FROM pedidos p
     CROSS JOIN LATERAL public.cargo_envio_desglose(p.total - GREATEST(p.total - p.cargo_envio, 0), p_tipo) d
     WHERE p.id = p_pedido_id AND p.sucursal_id = v_sucursal), 0);

  UPDATE pedidos
     SET tipo_factura = p_tipo,
         total_neto = round(v_total_neto, 2),$q$,
    'cambiar_tipo_factura_pedido: ZZ<->FC');

  EXECUTE v_def;
END
$patch$;

-- 4f · cambiar_cliente_pedido: conserva el estado como conserva el cargo.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo1_parchar(v_def,
$q$    COALESCE((SELECT cargo_envio::text FROM pedidos WHERE id = p_pedido_id), '0'), true);$q$,
$q$    COALESCE((SELECT cargo_envio::text FROM pedidos WHERE id = p_pedido_id), '0'), true);
  -- cargo_1_base: y su estado (un no_aplica o un bonificado no renacen gratis).
  PERFORM set_config('app.cargo_envio_estado_forzado',
    COALESCE((SELECT cargo_envio_estado FROM pedidos WHERE id = p_pedido_id), ''), true);$q$,
    'cambiar_cliente_pedido: estado forzado');
  EXECUTE v_def;
END
$patch$;

-- 4g · pedidos_proteger_columnas: el estado no lo cambia un preventista o un
-- transportista por REST (igual que cargo_envio; hoy ademas no tiene grant).
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.pedidos_proteger_columnas()'::regprocedure);
BEGIN
  v_def := pg_temp.cargo1_parchar(v_def,
$q$'cargo_envio', 'monto_pagado',$q$,
$q$'cargo_envio', 'cargo_envio_estado', 'monto_pagado',$q$,
    'pedidos_proteger_columnas');
  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · Verificacion (sin llamar a auditoria_integridad: es cara y la corre el ensayo)
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_fn  text;
  v_def text;
  v_acl text;
  v_d   record;
BEGIN
  -- Cada cuerpo quedo con su parche.
  FOREACH v_fn IN ARRAY ARRAY['crear_pedido_completo', 'crear_pedido_completo_bot', 'crear_pedido_idempotente',
                              'registrar_salvedad', 'anular_salvedad', 'cambiar_tipo_factura_pedido',
                              'cambiar_cliente_pedido'] LOOP
    SELECT pg_get_functiondef(p.oid), array_to_string(p.proacl, ',') INTO v_def, v_acl
      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_def NOT LIKE '%cargo_1_base%' THEN
      RAISE EXCEPTION '% no quedo parcheada', v_fn;
    END IF;
    IF v_acl IS NOT NULL AND (v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' OR v_acl LIKE '%anon=%') THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC o anon: %', v_fn, v_acl;
    END IF;
  END LOOP;
  IF pg_get_functiondef('public.pedidos_proteger_columnas()'::regprocedure) NOT LIKE '%''cargo_envio_estado''%' THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas no protege cargo_envio_estado';
  END IF;

  -- Las puras: solo service_role. El helper del estado: nadie de la API.
  FOREACH v_fn IN ARRAY ARRAY[
      'public.cargo_envio_pedido_puro(numeric, text, numeric, numeric, numeric)',
      'public.cargo_envio_desglose(numeric, text)',
      'public.cargo_tras_edicion(text, numeric, numeric, numeric, text, numeric, numeric, numeric, boolean, text)',
      'public.pedido_cargo_envio(numeric, bigint)',
      'public._cargo_envio_estado_alta(numeric, bigint)'] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE')
       OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                   WHERE p.oid = v_fn::regprocedure AND a.grantee = 0) THEN
      RAISE EXCEPTION '% es alcanzable desde la API', v_fn;
    END IF;
    IF v_fn NOT LIKE '%_cargo_envio_estado_alta%' AND NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% no la puede ejecutar service_role (gate de paridad)', v_fn;
    END IF;
  END LOOP;

  -- crear_pedido_idempotente sigue exenta en SEG-A con su md5 nuevo.
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() WHERE firma LIKE 'crear_pedido_idempotente(%') THEN
    RAISE EXCEPTION 'crear_pedido_idempotente quedo en rojo en SEG-A (md5 de la lista blanca)';
  END IF;

  -- La columna: nadie de la API la escribe por REST, anon no la lee.
  IF has_column_privilege('authenticated', 'public.pedidos', 'cargo_envio_estado', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.pedidos', 'cargo_envio_estado', 'INSERT')
     OR has_column_privilege('anon', 'public.pedidos', 'cargo_envio_estado', 'SELECT') THEN
    RAISE EXCEPTION 'pedidos.cargo_envio_estado tiene un grant de mas';
  END IF;

  -- Humo de las puras.
  SELECT * INTO v_d FROM public.cargo_envio_desglose(500, 'FC');
  IF v_d.neto <> 413.22 OR v_d.iva <> 86.78 THEN
    RAISE EXCEPTION 'cargo_envio_desglose(500, FC) = %/%, esperado 413.22/86.78', v_d.neto, v_d.iva;
  END IF;
  IF public.cargo_envio_pedido_puro(0, 'cargo', 15000, 0, 500) <> 0
     OR public.cargo_envio_pedido_puro(14999.99, 'cargo', 15000, 0, 500) <> 500 THEN
    RAISE EXCEPTION 'cargo_envio_pedido_puro no da la regla del alta';
  END IF;

  -- Con las politicas de hoy (bloquear en las tres) nadie paga envio.
  IF EXISTS (SELECT 1 FROM public.politicas_comerciales pc
              WHERE public.pedido_cargo_envio(1, pc.sucursal_id) <> 0
                AND pc.modo_minimo_pedido = 'bloquear') THEN
    RAISE EXCEPTION 'Con la politica en bloquear no deberia haber cargo';
  END IF;

  -- Sin productos no hay cargo ni forzado, y un 'cobrado' forzado sin cargo nace
  -- 'gratis' (el CHECK de coherencia vale siempre).
  PERFORM set_config('app.cargo_envio_forzado', '500', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', 'cobrado', true);
  IF public.pedido_cargo_envio(0, 1) <> 0 OR public.pedido_cargo_envio(100, 1) <> 500
     OR public._cargo_envio_estado_alta(0, 1) <> 'gratis'
     OR public._cargo_envio_estado_alta(500, 1) <> 'cobrado' THEN
    RAISE EXCEPTION 'El cargo forzado de la reatribucion no respeta "sin productos no hay envio"';
  END IF;
  PERFORM set_config('app.cargo_envio_forzado', '', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', '', true);
END
$verif$;

-- ROLLBACK: volver a aplicar las definiciones de la 389 de las funciones
-- parcheadas (crear_pedido_completo, crear_pedido_completo_bot,
-- crear_pedido_idempotente y su md5 en auditoria_definer_sin_rol,
-- registrar_salvedad, anular_salvedad, cambiar_tipo_factura_pedido,
-- cambiar_cliente_pedido, pedidos_proteger_columnas) y de pedido_cargo_envio;
-- DROP de cargo_envio_pedido_puro, cargo_envio_desglose, cargo_tras_edicion y
-- _cargo_envio_estado_alta; DROP CONSTRAINT de los dos CHECK y DROP COLUMN
-- pedidos.cargo_envio_estado. Los total_neto/total_iva de los pedidos con
-- cargo (hoy ninguno) quedarian con el envio adentro.
