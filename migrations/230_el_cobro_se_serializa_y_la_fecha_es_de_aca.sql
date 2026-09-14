-- =========================================================================
-- El cobro se serializa y la fecha es de aca
--
-- Verificado contra pg_get_functiondef en PROD, no contra migrations/.
--
-- 1. CONCURRENCIA EN LAS DOS FIFO
-- ------------------------------
-- registrar_pago_cliente_fifo_impl y registrar_pago_combinado_cliente_fifo_impl
-- recorren los pedidos con saldo SIN `FOR UPDATE` e imputan
-- `LEAST(v_restante, total - pagado)` sobre el snapshot del record. Dos cobros
-- concurrentes al mismo cliente leen el mismo `pagado` y los dos imputan el
-- saldo entero: monto_pagado 20.000 sobre un total de 10.000.
-- La mig 181 arreglo exactamente este patron en marcar_pagos_masivo_impl y no
-- toco las FIFO. Se les pone el mismo `FOR UPDATE`.
-- De paso, el filtro era `estado <> 'cancelado'` en vez de
-- `NOT IN ('cancelado','anulado')`: un pedido anulado podia recibir imputacion.
--
-- 2. LA FECHA POR DEFECTO ERA LA DE UTC
-- -------------------------------------
-- La base corre en UTC (verificado: current_setting('TimeZone') = 'UTC'). Las
-- 4 RPCs de pago declaran `p_fecha date DEFAULT CURRENT_DATE` y los guards del
-- encargado comparan `p_fecha <> CURRENT_DATE`. Entre las 21:00 y las 24:00 ART
-- (00:00-03:00 UTC del dia siguiente) eso hace dos cosas a la vez:
--   - el DEFAULT fecha el cobro MAÑANA;
--   - el guard RECHAZA la fecha correcta, porque para el la de hoy es la de ayer.
-- Medido: a las 22:30 ART, CURRENT_DATE = 15 y la fecha ART = 14.
--
-- La mig 182 arreglo el DEFAULT de la COLUMNA pagos.fecha, que estas RPCs no
-- usan nunca porque siempre pasan la fecha explicita en el INSERT. Se corrige
-- el encabezado de la 182.
--
-- SON CUATRO GUARDS, NO TRES. marcar_pagos_masivo_impl tambien compara contra
-- CURRENT_DATE. Arreglar tres dejaba el camino de cobro masivo -- el mas usado
-- de los cuatro -- rechazando la fecha correcta de noche.
--
-- NO hace falta DROP + CREATE para cambiar un default. Probado en PROD dentro
-- de una transaccion con ROLLBACK: `CREATE OR REPLACE` cambia el default de un
-- parametro sin crear sobrecarga (Postgres solo prohibe cambiar nombre, tipos y
-- tipo de retorno). Como la identidad de los argumentos no cambia, no hay dos
-- firmas conviviendo y la Trampa 5 no aplica. Se usa REPLACE, que ademas evita
-- la ventana en la que la funcion no existe.
--
-- 3. marcar_entrega_y_pago_masivo_impl SEGUIA FIJANDO monto_pagado
-- ----------------------------------------------------------------
-- La mig 181 saco `monto_pagado = total` de marcar_pagos_masivo_impl y no de su
-- hermana. Ese UPDATE final alcanza a TODOS los ids del lote, incluidos los que
-- el bucle salteo por ya estar pagados: tapa un cobro concurrente y deja el
-- pedido "saldado" con dos pagos encima. El INSERT en pagos ya dispara
-- recalcular_monto_pagado_pedido, que lo deriva de SUM(pagos).
--
-- 4. NADIE VIGILABA monto_pagado CONTRA SUM(pagos)
-- ------------------------------------------------
-- auditoria_integridad() no tenia ningun check que los comparara. Medido en
-- PROD: 69 pedidos divergentes, TODOS con monto_pagado por ENCIMA de sus pagos,
-- por $2.459.670,02 en total, entre 2026-04-04 y 2026-05-05.
-- El check nuevo CC-B es un CENTINELA: mira solo los pedidos creados en los
-- ultimos 30 dias, asi nace en verde a pesar de esa cohorte historica.
-- La ventana es de 30 dias y no de 2 horas a proposito: el gate corre una vez
-- por dia, y una ventana de 2 h solo ve lo creado en las 2 h previas a la
-- corrida -- se le escapa casi cualquier regresion. Medido antes de elegirla:
-- el ultimo pedido divergente es del 2026-05-05 (132 dias atras) y las ventanas
-- de 7, 30, 60, 90 y 120 dias dan todas 0. 30 dias deja 100 dias de margen
-- contra la cohorte y aun asi mantiene una regresion visible un mes entero.
--
-- LOS 69 NO SE TOCAN. Corregirlos es una decision de negocio (implica bajar
-- monto_pagado de boletas cobradas hace cinco meses); van documentados en el PR.
--
-- Parches POR ANCLA sobre el cuerpo VIVO: cada ancla tiene que aparecer
-- exactamente una vez o la migracion aborta.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 - Andamio de parcheo por ancla (idiom de la 220/229). Se dropea al final.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._mig230_reemplazar_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);

  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, p_funcion;
  END IF;

  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

CREATE OR REPLACE FUNCTION public._mig230_fn(p_nombre text)
RETURNS regprocedure
LANGUAGE sql
AS $fn$
  SELECT p.oid::regprocedure FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_nombre;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 - La fecha por defecto pasa a ser la de Buenos Aires.
--     Las 8 firmas: las 4 RPCs publicas y los 4 _impl. El default del _impl hoy
--     es letra muerta -- el wrapper siempre pasa p_fecha explicita -- pero
--     dejarlo en CURRENT_DATE es una trampa para el que llame al _impl directo.
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'registrar_pago_cliente_fifo',        'registrar_pago_cliente_fifo_impl',
    'registrar_pago_combinado_cliente_fifo', 'registrar_pago_combinado_cliente_fifo_impl',
    'marcar_pagos_masivo',                'marcar_pagos_masivo_impl',
    'marcar_entrega_y_pago_masivo',       'marcar_entrega_y_pago_masivo_impl'
  ] LOOP
    PERFORM public._mig230_reemplazar_ancla(
      public._mig230_fn(v_fn),
      'p_fecha date DEFAULT CURRENT_DATE',
      'p_fecha date DEFAULT (now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date'
    );
  END LOOP;
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 2 - Los CUATRO guards del encargado comparan contra la misma fecha de aca.
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'registrar_pago_cliente_fifo_impl',
    'registrar_pago_combinado_cliente_fifo_impl',
    'marcar_pagos_masivo_impl',
    'marcar_entrega_y_pago_masivo_impl'
  ] LOOP
    PERFORM public._mig230_reemplazar_ancla(
      public._mig230_fn(v_fn),
      E'    IF p_fecha <> CURRENT_DATE THEN\n',
      E'    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las\n'
      || E'    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.\n'
      || E'    IF p_fecha <> (now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date THEN\n'
    );
  END LOOP;
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 3 - registrar_pago_cliente_fifo_impl: FOR UPDATE y el filtro de estado
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig230_reemplazar_ancla(
    public._mig230_fn('registrar_pago_cliente_fifo_impl'),
    E'      AND estado <> ''cancelado''\n',
    E'      AND COALESCE(estado, '''') NOT IN (''cancelado'', ''anulado'')\n'
  );

  PERFORM public._mig230_reemplazar_ancla(
    public._mig230_fn('registrar_pago_cliente_fifo_impl'),
    E'    ORDER BY fecha ASC, id ASC\n  LOOP\n',
    E'    ORDER BY fecha ASC, id ASC\n'
    || E'    -- mig 230: serializa la imputacion, igual que la 181 en\n'
    || E'    -- marcar_pagos_masivo_impl. Sin el lock, dos cobros concurrentes al mismo\n'
    || E'    -- cliente leen el mismo `pagado` y los dos imputan el saldo entero.\n'
    || E'    FOR UPDATE\n'
    || E'  LOOP\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 4 - registrar_pago_combinado_cliente_fifo_impl: lo mismo, un nivel adentro
--     (su bucle de pedidos vive dentro del bucle de metodos).
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig230_reemplazar_ancla(
    public._mig230_fn('registrar_pago_combinado_cliente_fifo_impl'),
    E'        AND estado <> ''cancelado''\n',
    E'        AND COALESCE(estado, '''') NOT IN (''cancelado'', ''anulado'')\n'
  );

  PERFORM public._mig230_reemplazar_ancla(
    public._mig230_fn('registrar_pago_combinado_cliente_fifo_impl'),
    E'      ORDER BY fecha ASC, id ASC\n    LOOP\n',
    E'      ORDER BY fecha ASC, id ASC\n'
    || E'      -- mig 230: ver registrar_pago_cliente_fifo_impl. Mismo lock, y aca\n'
    || E'      -- ademas cada metodo de pago vuelve a recorrer los pedidos.\n'
    || E'      FOR UPDATE\n'
    || E'    LOOP\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 5 - marcar_entrega_y_pago_masivo_impl deja de fijar monto_pagado a mano
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig230_reemplazar_ancla(
    public._mig230_fn('marcar_entrega_y_pago_masivo_impl'),
    E'         monto_pagado = total,\n',
    E'         -- mig 230: ya NO se escribe monto_pagado = total, igual que la 181 en\n'
    || E'         -- marcar_pagos_masivo_impl. El INSERT en pagos de arriba dispara\n'
    || E'         -- recalcular_monto_pagado_pedido, que lo deriva de SUM(pagos). Este\n'
    || E'         -- UPDATE alcanza a TODOS los ids del lote -- tambien los que el bucle\n'
    || E'         -- salteo por ya estar pagados -- asi que fijarlo a mano tapaba un\n'
    || E'         -- cobro concurrente y dejaba el pedido saldado con dos pagos encima.\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 6 - CC-B: el centinela de monto_pagado contra SUM(pagos)
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig230_reemplazar_ancla(
    public._mig230_fn('auditoria_integridad'),
    E'    (''CC-PAGOS-CANCEL'',''high'',''ningún pago imputado a un pedido cancelado'',\n'
    || E'      (SELECT count(*) FROM pagos pg JOIN pedidos p ON p.id=pg.pedido_id WHERE p.estado=''cancelado'')),\n',
    E'    (''CC-PAGOS-CANCEL'',''high'',''ningún pago imputado a un pedido cancelado'',\n'
    || E'      (SELECT count(*) FROM pagos pg JOIN pedidos p ON p.id=pg.pedido_id WHERE p.estado=''cancelado'')),\n'
    || E'    (''CC-B'',''high'',''pedidos de los ultimos 30 dias donde monto_pagado <> Σ pagos (centinela; los 69 de abril-mayo 2026 quedan fuera a proposito, mig 230)'',\n'
    || E'      (SELECT count(*) FROM pedidos p\n'
    || E'         JOIN LATERAL (SELECT COALESCE(SUM(pg.monto),0) AS suma FROM pagos pg WHERE pg.pedido_id=p.id) s ON TRUE\n'
    || E'        WHERE p.created_at > now() - interval ''30 days''\n'
    || E'          AND abs(COALESCE(p.monto_pagado,0) - s.suma) > 0.01)),\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 7 - Se saca el andamio
-- ---------------------------------------------------------------------------

DROP FUNCTION public._mig230_reemplazar_ancla(regprocedure, text, text);
DROP FUNCTION public._mig230_fn(text);

-- ---------------------------------------------------------------------------
-- 8 - Verificacion. Si algo no quedo, la migracion entera se revierte.
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_falta text;
  v_def   text;
  v_n     int;
  v_chk   jsonb;
BEGIN
  -- Ninguna de las 8 firmas quedo con el default de UTC.
  SELECT string_agg(t, ', ') INTO v_falta
  FROM unnest(ARRAY['registrar_pago_cliente_fifo','registrar_pago_cliente_fifo_impl',
                    'registrar_pago_combinado_cliente_fifo','registrar_pago_combinado_cliente_fifo_impl',
                    'marcar_pagos_masivo','marcar_pagos_masivo_impl',
                    'marcar_entrega_y_pago_masivo','marcar_entrega_y_pago_masivo_impl']) t
  WHERE EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace='public'::regnamespace AND p.proname = t
       AND pg_get_function_arguments(p.oid) LIKE '%p_fecha date DEFAULT CURRENT_DATE%');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron con DEFAULT CURRENT_DATE: %.', v_falta;
  END IF;

  -- Y las 8 quedaron con el default de Buenos Aires.
  SELECT string_agg(t, ', ') INTO v_falta
  FROM unnest(ARRAY['registrar_pago_cliente_fifo','registrar_pago_cliente_fifo_impl',
                    'registrar_pago_combinado_cliente_fifo','registrar_pago_combinado_cliente_fifo_impl',
                    'marcar_pagos_masivo','marcar_pagos_masivo_impl',
                    'marcar_entrega_y_pago_masivo','marcar_entrega_y_pago_masivo_impl']) t
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace='public'::regnamespace AND p.proname = t
       AND pg_get_function_arguments(p.oid) LIKE '%America/Argentina/Buenos_Aires%');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'No tomaron el default de Buenos Aires: %.', v_falta;
  END IF;

  -- Una sola firma de cada una: un DROP/CREATE mal hecho deja dos y da PGRST203.
  SELECT string_agg(proname || '=' || c, ', ') INTO v_falta
  FROM (SELECT proname, count(*) AS c FROM pg_proc
         WHERE pronamespace='public'::regnamespace
           AND proname IN ('registrar_pago_cliente_fifo','registrar_pago_cliente_fifo_impl',
                           'registrar_pago_combinado_cliente_fifo','registrar_pago_combinado_cliente_fifo_impl',
                           'marcar_pagos_masivo','marcar_pagos_masivo_impl',
                           'marcar_entrega_y_pago_masivo','marcar_entrega_y_pago_masivo_impl')
         GROUP BY proname HAVING count(*) <> 1) q;
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron sobrecargas duplicadas: %.', v_falta;
  END IF;

  -- Ningun guard compara ya contra CURRENT_DATE.
  SELECT string_agg(p.proname, ', ') INTO v_falta
  FROM pg_proc p
  WHERE p.pronamespace='public'::regnamespace
    AND p.proname IN ('registrar_pago_cliente_fifo_impl','registrar_pago_combinado_cliente_fifo_impl',
                      'marcar_pagos_masivo_impl','marcar_entrega_y_pago_masivo_impl')
    AND pg_get_functiondef(p.oid) LIKE '%p_fecha <> CURRENT_DATE%';
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Guards todavia contra CURRENT_DATE: %.', v_falta;
  END IF;

  -- Los cuatro guards existen y comparan contra la fecha de aca.
  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace
     AND p.proname IN ('registrar_pago_cliente_fifo_impl','registrar_pago_combinado_cliente_fifo_impl',
                       'marcar_pagos_masivo_impl','marcar_entrega_y_pago_masivo_impl')
     AND pg_get_functiondef(p.oid) LIKE '%p_fecha <> (now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date%';
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'Solo % de 4 guards quedaron con la fecha de Buenos Aires.', v_n;
  END IF;

  -- Las dos FIFO serializan y ya no miran solo 'cancelado'.
  SELECT string_agg(t, ', ') INTO v_falta
  FROM unnest(ARRAY['registrar_pago_cliente_fifo_impl','registrar_pago_combinado_cliente_fifo_impl']) t
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace='public'::regnamespace AND p.proname = t
       AND pg_get_functiondef(p.oid) LIKE '%FOR UPDATE%'
       AND pg_get_functiondef(p.oid) LIKE '%NOT IN (''cancelado'', ''anulado'')%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%AND estado <> ''cancelado''%');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Las FIFO no quedaron serializadas o siguen filtrando solo cancelado: %.', v_falta;
  END IF;

  -- marcar_entrega_y_pago_masivo_impl ya no fija monto_pagado.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='marcar_entrega_y_pago_masivo_impl';
  IF v_def LIKE '%         monto_pagado = total,%' THEN
    RAISE EXCEPTION 'marcar_entrega_y_pago_masivo_impl sigue fijando monto_pagado = total.';
  END IF;

  -- CC-B esta en la auditoria y nace en verde (post-condicion de la mig 225).
  SELECT c INTO v_chk
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
   WHERE c->>'id' = 'CC-B';
  IF v_chk IS NULL THEN
    RAISE EXCEPTION 'CC-B no aparece en la salida de auditoria_integridad(). El parche no entro.';
  END IF;
  IF (v_chk->>'violaciones')::integer <> 0 THEN
    RAISE EXCEPTION 'CC-B nace en rojo con % violaciones. Un check que nace rojo vuelve inutil al gate diario.',
      (v_chk->>'violaciones')::integer;
  END IF;

  -- El andamio no quedo vivo.
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace='public'::regnamespace AND p.proname LIKE '\_mig230\_%') THEN
    RAISE EXCEPTION 'Quedo viva una funcion andamio _mig230_*.';
  END IF;

  -- Ninguna de las RPCs tocadas quedo alcanzable con la anon key.
  SELECT string_agg(t, ', ') INTO v_falta
  FROM unnest(ARRAY['registrar_pago_cliente_fifo','registrar_pago_combinado_cliente_fifo',
                    'marcar_pagos_masivo','marcar_entrega_y_pago_masivo']) t
  WHERE has_function_privilege('anon', (SELECT p.oid FROM pg_proc p
          WHERE p.pronamespace='public'::regnamespace AND p.proname = t), 'EXECUTE');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron ejecutables por anon: %.', v_falta;
  END IF;
END;
$verif$;

COMMIT;
