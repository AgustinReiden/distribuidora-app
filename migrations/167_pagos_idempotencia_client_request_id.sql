-- 167_pagos_idempotencia_client_request_id.sql
--
-- PROBLEMA
-- El registro de pagos no tiene guarda de idempotencia. Si la request llega al
-- servidor pero la respuesta se pierde (PWA en mobile, "Load failed" de iOS,
-- red del reparto), el usuario ve un error, vuelve a apretar "Registrar" y se
-- inserta el pago de nuevo. No hay nada del lado del server que lo frene.
--
-- Caso testigo en prod: pedido 3602 (cliente 303 "MARCOS CHOFER") tiene el mismo
-- pago de $111.280 tres veces — pagos 3280/3281/3282, 2026-07-13 22:53:20 /
-- 22:53:27 / 22:53:37. Ventana de 17 segundos, montos y forma de pago identicos.
-- Es el unico sobrepago que la mig 166 dejo sin corregir a proposito (ver ahi la
-- seccion EXCLUSION): no es credito real del cliente, es un error de carga.
--
-- SOLUCION
-- El mismo patron que ya usa `registrar_salvedad` desde la mig 049: el cliente
-- genera un UUID por intento de escritura y lo manda; si el servidor ya vio ese
-- UUID devuelve el resultado de la primera vez en lugar de volver a escribir.
--
-- Hay dos caminos de escritura a `pagos` y cada uno necesita su mecanismo:
--
--   A) INSERT directo por PostgREST (usePagos.registrarPago / registrarPagosBatch,
--      que es el camino del cobro de una parada y del modal de pago del pedido).
--      Una fila por request => alcanza con `pagos.client_request_id` + indice
--      unico. El reintento choca contra el indice y el front resuelve leyendo la
--      fila que ya existe.
--
--   B) Las 4 RPCs (registrar_pago_cliente_fifo, registrar_pago_combinado_cliente_fifo,
--      marcar_pagos_masivo, marcar_entrega_y_pago_masivo). Todas pueden insertar
--      N filas por llamada, asi que no sirve una columna unica en `pagos`. Va un
--      ledger aparte, `pagos_solicitudes`, con el UUID como PK y el resultado de
--      la primera ejecucion guardado para poder devolverlo tal cual en el replay.
--
-- POR QUE WRAPPERS Y NO `CREATE OR REPLACE` DEL CUERPO
-- `migrations/` es una vista curada, no un espejo 1:1 de prod (ver MANIFEST.md), y
-- la mig 100 ya documenta que estas RPCs masivas habian driftado respecto del repo.
-- Reescribir los cuerpos desde el archivo del repo se llevaria puesto cualquier
-- cambio que solo viva en prod. Por eso cada RPC se **renombra** a `<nombre>_impl`
-- (el cuerpo queda intacto, sea cual sea) y se crea un wrapper con el nombre
-- original + `p_client_request_id`, que hace la dedup y delega. Cero riesgo de
-- clobber y el diff es auditable.
--
-- ORDEN DE DEPLOY: primero esta migracion, despues el frontend. Al reves el front
-- mandaria `p_client_request_id` a una funcion que todavia no lo acepta (PGRST202).
-- Al derecho no rompe nada: el parametro tiene DEFAULT NULL y sin UUID el
-- comportamiento es exactamente el de hoy.

-- ---------------------------------------------------------------------------
-- 1. Camino A: INSERT directo a `pagos`
-- ---------------------------------------------------------------------------
ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS client_request_id uuid;

COMMENT ON COLUMN public.pagos.client_request_id IS
  'UUID generado por el cliente para deduplicar reintentos del INSERT directo (mig 167). NULL en filas previas y en las que insertan las RPCs (esas deduplican por pagos_solicitudes).';

CREATE UNIQUE INDEX IF NOT EXISTS idx_pagos_client_request_id
  ON public.pagos (client_request_id)
  WHERE client_request_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Camino B: ledger de solicitudes para las RPCs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pagos_solicitudes (
  client_request_id uuid        PRIMARY KEY,
  operacion         text        NOT NULL,
  usuario_id        uuid,
  sucursal_id       bigint,
  resultado         jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.pagos_solicitudes IS
  'Ledger de idempotencia de las RPCs de pagos (mig 167). Una fila por client_request_id con el resultado de la primera ejecucion, que se devuelve tal cual ante un reintento.';

-- Solo la tocan las funciones SECURITY DEFINER de abajo (owner postgres, que
-- ignora RLS). RLS prendida y sin policies = nadie mas la lee ni la escribe.
ALTER TABLE public.pagos_solicitudes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pagos_solicitudes FROM PUBLIC, anon, authenticated;

-- Housekeeping: el ledger solo sirve para reintentos, que ocurren en segundos.
CREATE INDEX IF NOT EXISTS idx_pagos_solicitudes_created_at
  ON public.pagos_solicitudes (created_at);

-- ---------------------------------------------------------------------------
-- 3. Helpers del ledger
-- ---------------------------------------------------------------------------

-- Devuelve NULL  => es la primera vez (o no vino UUID): el caller sigue de largo.
-- Devuelve jsonb => es un reintento: el caller devuelve eso y no escribe nada.
--
-- El advisory lock serializa las llamadas concurrentes con el mismo UUID: el
-- segundo espera a que el primero commitee (el lock se suelta al final de la
-- transaccion) y recien ahi lee el resultado ya guardado. Sin el lock, dos
-- requests simultaneas podrian pasar las dos el chequeo y escribir dos veces.
CREATE OR REPLACE FUNCTION public.pago_solicitud_abrir(
  p_client_request_id uuid,
  p_operacion         text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_resultado jsonb;
  v_existe    boolean;
BEGIN
  IF p_client_request_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_client_request_id::text, 0));

  SELECT true, resultado
    INTO v_existe, v_resultado
    FROM pagos_solicitudes
   WHERE client_request_id = p_client_request_id;

  IF COALESCE(v_existe, false) THEN
    -- resultado NULL solo puede pasar si la ejecucion original quedo a medias sin
    -- abortar la transaccion (no deberia ocurrir: un error revierte tambien esta
    -- fila). Se deja seguir para no dejar el pago sin registrar por un ledger raro.
    RETURN v_resultado;
  END IF;

  INSERT INTO pagos_solicitudes (client_request_id, operacion, usuario_id, sucursal_id)
  VALUES (p_client_request_id, p_operacion, auth.uid(), current_sucursal_id());

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pago_solicitud_cerrar(
  p_client_request_id uuid,
  p_resultado         jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF p_client_request_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE pagos_solicitudes
     SET resultado = p_resultado
   WHERE client_request_id = p_client_request_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.pago_solicitud_abrir(uuid, text)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pago_solicitud_cerrar(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Renombrar las 4 RPCs a `_impl` (el cuerpo que haya en prod, intacto)
-- ---------------------------------------------------------------------------
DO $rename$
BEGIN
  IF to_regprocedure('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)') IS NULL THEN
    ALTER FUNCTION public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text)
      RENAME TO registrar_pago_cliente_fifo_impl;
  END IF;

  IF to_regprocedure('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)') IS NULL THEN
    ALTER FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text)
      RENAME TO registrar_pago_combinado_cliente_fifo_impl;
  END IF;

  IF to_regprocedure('public.marcar_pagos_masivo_impl(bigint[],text,date)') IS NULL THEN
    ALTER FUNCTION public.marcar_pagos_masivo(bigint[],text,date)
      RENAME TO marcar_pagos_masivo_impl;
  END IF;

  IF to_regprocedure('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)') IS NULL THEN
    ALTER FUNCTION public.marcar_entrega_y_pago_masivo(bigint[],uuid,text,date)
      RENAME TO marcar_entrega_y_pago_masivo_impl;
  END IF;
END
$rename$;

-- Las `_impl` dejan de ser invocables desde la app: el unico acceso es via wrapper,
-- que es quien deduplica.
REVOKE ALL ON FUNCTION public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marcar_pagos_masivo_impl(bigint[],text,date)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)
  FROM PUBLIC, anon, authenticated;

-- Por si alguna quedo dando vueltas con la firma vieja de 2 args (pre mig 003).
DROP FUNCTION IF EXISTS public.marcar_pagos_masivo(bigint[], text);

-- ---------------------------------------------------------------------------
-- 5. Wrappers idempotentes con el nombre publico de siempre
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_pago_cliente_fifo(
  p_cliente_id        bigint,
  p_monto             numeric,
  p_forma_pago        text,
  p_fecha             date  DEFAULT CURRENT_DATE,
  p_referencia        text  DEFAULT NULL::text,
  p_notas             text  DEFAULT NULL::text,
  p_client_request_id uuid  DEFAULT NULL::uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_previo    jsonb;
  v_resultado jsonb;
BEGIN
  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'registrar_pago_cliente_fifo');
  IF v_previo IS NOT NULL THEN
    RETURN v_previo || jsonb_build_object('idempotent_replay', true);
  END IF;

  v_resultado := public.registrar_pago_cliente_fifo_impl(
    p_cliente_id, p_monto, p_forma_pago, p_fecha, p_referencia, p_notas
  );

  PERFORM public.pago_solicitud_cerrar(p_client_request_id, v_resultado);
  RETURN v_resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_pago_combinado_cliente_fifo(
  p_cliente_id        bigint,
  p_metodos           jsonb,
  p_fecha             date  DEFAULT CURRENT_DATE,
  p_referencia        text  DEFAULT NULL::text,
  p_notas             text  DEFAULT NULL::text,
  p_client_request_id uuid  DEFAULT NULL::uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_previo    jsonb;
  v_resultado jsonb;
BEGIN
  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'registrar_pago_combinado_cliente_fifo');
  IF v_previo IS NOT NULL THEN
    RETURN v_previo || jsonb_build_object('idempotent_replay', true);
  END IF;

  v_resultado := public.registrar_pago_combinado_cliente_fifo_impl(
    p_cliente_id, p_metodos, p_fecha, p_referencia, p_notas
  );

  PERFORM public.pago_solicitud_cerrar(p_client_request_id, v_resultado);
  RETURN v_resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION public.marcar_pagos_masivo(
  p_pedido_ids        bigint[],
  p_forma_pago        text,
  p_fecha             date DEFAULT CURRENT_DATE,
  p_client_request_id uuid DEFAULT NULL::uuid
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_previo    jsonb;
  v_afectados integer;
BEGIN
  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'marcar_pagos_masivo');
  IF v_previo IS NOT NULL THEN
    RETURN COALESCE((v_previo->>'afectados')::integer, 0);
  END IF;

  v_afectados := public.marcar_pagos_masivo_impl(p_pedido_ids, p_forma_pago, p_fecha);

  PERFORM public.pago_solicitud_cerrar(
    p_client_request_id, jsonb_build_object('afectados', v_afectados)
  );
  RETURN v_afectados;
END;
$function$;

CREATE OR REPLACE FUNCTION public.marcar_entrega_y_pago_masivo(
  p_pedido_ids        bigint[],
  p_transportista_id  uuid,
  p_forma_pago        text,
  p_fecha             date DEFAULT CURRENT_DATE,
  p_client_request_id uuid DEFAULT NULL::uuid
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_previo    jsonb;
  v_afectados integer;
BEGIN
  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'marcar_entrega_y_pago_masivo');
  IF v_previo IS NOT NULL THEN
    RETURN COALESCE((v_previo->>'afectados')::integer, 0);
  END IF;

  v_afectados := public.marcar_entrega_y_pago_masivo_impl(
    p_pedido_ids, p_transportista_id, p_forma_pago, p_fecha
  );

  PERFORM public.pago_solicitud_cerrar(
    p_client_request_id, jsonb_build_object('afectados', v_afectados)
  );
  RETURN v_afectados;
END;
$function$;

-- Los wrappers heredan el rol de siempre y los grants que tenian las originales.
ALTER FUNCTION public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid) OWNER TO postgres;
ALTER FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid) OWNER TO postgres;
ALTER FUNCTION public.marcar_pagos_masivo(bigint[],text,date,uuid) OWNER TO postgres;
ALTER FUNCTION public.marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.marcar_pagos_masivo(bigint[],text,date,uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid) IS
  'Wrapper idempotente (mig 167) de registrar_pago_cliente_fifo_impl. Con p_client_request_id, un reintento devuelve el resultado de la primera llamada sin volver a imputar.';
COMMENT ON FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid) IS
  'Wrapper idempotente (mig 167) de registrar_pago_combinado_cliente_fifo_impl. Con p_client_request_id, un reintento devuelve el resultado de la primera llamada sin volver a imputar.';
COMMENT ON FUNCTION public.marcar_pagos_masivo(bigint[],text,date,uuid) IS
  'Wrapper idempotente (mig 167) de marcar_pagos_masivo_impl. Con p_client_request_id, un reintento devuelve la cantidad afectada de la primera llamada sin volver a cobrar.';
COMMENT ON FUNCTION public.marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid) IS
  'Wrapper idempotente (mig 167) de marcar_entrega_y_pago_masivo_impl. Con p_client_request_id, un reintento devuelve la cantidad afectada de la primera llamada sin volver a entregar ni cobrar.';

-- ---------------------------------------------------------------------------
-- 6. Chequeos de que quedo una sola firma publica por RPC
-- ---------------------------------------------------------------------------
-- Dos overloads del mismo nombre harian que PostgREST no pueda resolver la
-- llamada (42725, "function is not unique") y romperia el cobro en prod.
DO $verificar$
DECLARE
  v_nombre text;
  v_cuantas integer;
BEGIN
  FOREACH v_nombre IN ARRAY ARRAY[
    'registrar_pago_cliente_fifo',
    'registrar_pago_combinado_cliente_fifo',
    'marcar_pagos_masivo',
    'marcar_entrega_y_pago_masivo'
  ] LOOP
    SELECT count(*) INTO v_cuantas
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_nombre;

    IF v_cuantas <> 1 THEN
      RAISE EXCEPTION 'ABORTA: public.% quedo con % definiciones (esperaba 1). PostgREST no podria resolver la llamada.',
        v_nombre, v_cuantas;
    END IF;
  END LOOP;
END
$verificar$;

NOTIFY pgrst, 'reload schema';
