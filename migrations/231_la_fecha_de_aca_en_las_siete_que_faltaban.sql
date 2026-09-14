-- =========================================================================
-- La fecha de aca, en las siete que faltaban
--
-- La mig 230 paso a hora argentina los defaults de las 4 RPCs de pago (y sus
-- 4 _impl) y los 4 guards del encargado. Quedaron SIETE funciones mas con el
-- mismo `p_fecha date DEFAULT CURRENT_DATE`, que en una base que corre en UTC
-- devuelve la fecha de MAÑANA entre las 21:00 y las 24:00 ART.
--
-- Censo completo, hecho con pg_get_function_arguments sobre `public` (no
-- leyendo archivos), mas los callers vivos en `src/` y `supabase/functions/`:
--
--   funcion                        el default, ¿se evalua?        escribe fecha
--   ---------------------------------------------------------------------------
--   marcar_entregas_masivo         SI - usePedidosQuery OMITE      SI fecha_entrega
--                                  p_fecha cuando no se elige
--   crear_rendicion_por_fecha      sin caller en el front          SI
--   registrar_ingreso_sucursal     sin rpc() vivo                  SI
--   registrar_transferencia        sin rpc() vivo                  SI
--   bot_mi_recorrido               NO - el bot manda               no, filtra
--                                  hoyEnArgentina()
--   bot_recorrido_resumen          NO - el bot manda null          no, filtra
--                                  explicito
--   obtener_resumen_rendiciones    NO - useRendiciones manda       no, filtra
--                                  las dos fechas
--
-- EL UNICO BUG VIVO DEMOSTRADO es `marcar_entregas_masivo`: el front hace
-- `if (fecha) rpcArgs.p_fecha = fecha` (usePedidosQuery), asi que cuando el
-- usuario no elige fecha el argumento se OMITE, el default se evalua, y la
-- entrega queda fechada mañana -- `v_fecha_ts` se arma como
-- `p_fecha || ' 12:00:00 America/Argentina/Buenos_Aires'`, o sea que el pedido
-- aparece entregado al mediodia del dia siguiente.
--
-- POR QUE SE TOCAN LAS SIETE Y NO SOLO ESA
-- ----------------------------------------
-- Porque cambiar un default es un no-op comprobable cuando el default no se
-- evalua: Postgres solo lo evalua si el argumento se OMITE. Para las cuatro
-- cuyos callers mandan la fecha siempre, esto no cambia una sola ejecucion; les
-- saca la trampa de encima para el dia que alguien agregue un caller que la
-- omita -- que es exactamente como llego hasta aca este bug: la 182 arreglo el
-- default de la COLUMNA, la 230 el de los PARAMETROS de pago, y estas siete
-- quedaron porque nadie hizo el censo.
--
-- Ninguna de las siete tiene CURRENT_DATE en el CUERPO: se verifico que la
-- unica aparicion esta en la linea de la firma. No hay ningun
-- `COALESCE(p_fecha, CURRENT_DATE)` escondido.
--
-- Como en la 230, se usa CREATE OR REPLACE: cambia el default sin crear
-- sobrecarga y sin la ventana en que la funcion no existe.
--
-- Parches POR ANCLA sobre el cuerpo VIVO: cada ancla tiene que aparecer
-- exactamente una vez o la migracion aborta.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 - Andamio de parcheo por ancla (idiom de la 220/229/230). Se dropea al final.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._mig231_reemplazar_ancla(
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

CREATE OR REPLACE FUNCTION public._mig231_fn(p_nombre text)
RETURNS regprocedure
LANGUAGE sql
AS $fn$
  SELECT p.oid::regprocedure FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_nombre;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 - Las seis con un solo `p_fecha`
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'marcar_entregas_masivo',
    'crear_rendicion_por_fecha',
    'registrar_ingreso_sucursal',
    'registrar_transferencia',
    'bot_mi_recorrido',
    'bot_recorrido_resumen'
  ] LOOP
    PERFORM public._mig231_reemplazar_ancla(
      public._mig231_fn(v_fn),
      'p_fecha date DEFAULT CURRENT_DATE',
      'p_fecha date DEFAULT (now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date'
    );
  END LOOP;
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 2 - obtener_resumen_rendiciones tiene dos, y la de `desde` es la de `hasta`
--     menos 30 dias: se mueve la base, la resta queda igual.
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig231_reemplazar_ancla(
    public._mig231_fn('obtener_resumen_rendiciones'),
    'p_fecha_hasta date DEFAULT CURRENT_DATE',
    'p_fecha_hasta date DEFAULT (now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date'
  );

  PERFORM public._mig231_reemplazar_ancla(
    public._mig231_fn('obtener_resumen_rendiciones'),
    'p_fecha_desde date DEFAULT ((CURRENT_DATE - ''30 days''::interval))::date',
    'p_fecha_desde date DEFAULT (((now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date - ''30 days''::interval))::date'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 3 - Se saca el andamio
-- ---------------------------------------------------------------------------

DROP FUNCTION public._mig231_reemplazar_ancla(regprocedure, text, text);
DROP FUNCTION public._mig231_fn(text);

-- ---------------------------------------------------------------------------
-- 4 - Verificacion. Si algo no quedo, la migracion entera se revierte.
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_falta text;
  v_n     int;
BEGIN
  -- No queda NINGUNA funcion de public con un default CURRENT_DATE. Este check
  -- es global a proposito: es el censo el que faltaba, no el arreglo.
  SELECT string_agg(p.proname, ', ') INTO v_falta
  FROM pg_proc p
  WHERE p.pronamespace='public'::regnamespace
    AND pg_get_function_arguments(p.oid) LIKE '%DEFAULT CURRENT_DATE%';
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Todavia hay defaults CURRENT_DATE en: %.', v_falta;
  END IF;

  -- Y las siete quedaron con la fecha de Buenos Aires.
  SELECT string_agg(t, ', ') INTO v_falta
  FROM unnest(ARRAY['marcar_entregas_masivo','crear_rendicion_por_fecha',
                    'registrar_ingreso_sucursal','registrar_transferencia',
                    'bot_mi_recorrido','bot_recorrido_resumen',
                    'obtener_resumen_rendiciones']) t
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace='public'::regnamespace AND p.proname = t
       AND pg_get_function_arguments(p.oid) LIKE '%America/Argentina/Buenos_Aires%');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'No tomaron el default de Buenos Aires: %.', v_falta;
  END IF;

  -- obtener_resumen_rendiciones conserva la ventana de 30 dias.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace='public'::regnamespace AND p.proname='obtener_resumen_rendiciones'
       AND pg_get_function_arguments(p.oid) LIKE '%30 days%') THEN
    RAISE EXCEPTION 'obtener_resumen_rendiciones perdio la ventana de 30 dias.';
  END IF;

  -- Una sola firma de cada una: dos sobrecargas dan PGRST203 en runtime.
  SELECT string_agg(proname || '=' || c, ', ') INTO v_falta
  FROM (SELECT proname, count(*) AS c FROM pg_proc
         WHERE pronamespace='public'::regnamespace
           AND proname IN ('marcar_entregas_masivo','crear_rendicion_por_fecha',
                           'registrar_ingreso_sucursal','registrar_transferencia',
                           'bot_mi_recorrido','bot_recorrido_resumen',
                           'obtener_resumen_rendiciones')
         GROUP BY proname HAVING count(*) <> 1) q;
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron sobrecargas duplicadas: %.', v_falta;
  END IF;

  -- El andamio no quedo vivo.
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace='public'::regnamespace AND p.proname LIKE '\_mig231\_%') THEN
    RAISE EXCEPTION 'Quedo viva una funcion andamio _mig231_*.';
  END IF;

  -- Ninguna de las siete quedo alcanzable con la anon key.
  SELECT string_agg(t, ', ') INTO v_falta
  FROM unnest(ARRAY['marcar_entregas_masivo','crear_rendicion_por_fecha',
                    'registrar_ingreso_sucursal','registrar_transferencia',
                    'bot_mi_recorrido','bot_recorrido_resumen',
                    'obtener_resumen_rendiciones']) t
  WHERE has_function_privilege('anon', (SELECT p.oid FROM pg_proc p
          WHERE p.pronamespace='public'::regnamespace AND p.proname = t), 'EXECUTE');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron ejecutables por anon: %.', v_falta;
  END IF;

  -- La auditoria sigue en verde.
  SELECT (public.auditoria_integridad()->>'critical_high_en_rojo')::int INTO v_n;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'auditoria_integridad() quedo con % check(s) critical/high en rojo.', v_n;
  END IF;
END;
$verif$;

COMMIT;
