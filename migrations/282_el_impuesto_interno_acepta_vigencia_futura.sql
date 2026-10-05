-- =========================================================================
-- mig 282 · EL IMPUESTO INTERNO ACEPTA VIGENCIA FUTURA (#865)
--
-- La 277 dejo `productos.impuestos_internos` DERIVADO del encuadre: la
-- efectiva vigente HOY, que escriben `derivar_ii_producto` (al tocar la ficha)
-- y `refrescar_ii_productos()` (cuando se escribe `ii_alicuotas`). Una
-- alicuota cargada por adelantado no tenia quien la activara el dia que
-- empieza —en prod no hay pg_cron (#661)—, asi que `validar_ii_alicuota`
-- rechazaba `vigente_desde` posterior a hoy. Ahora hay quien:
--
--   .github/workflows/refrescar-ii.yml · todos los dias a las 00:15 ART llama
--     `refrescar_ii_productos()` por PostgREST con la service_role (la funcion
--     ya era server-only: postgres + service_role, nada mas). Actions arranca
--     los cron con horas de atraso, asi que la ficha puede quedar con la tasa
--     vieja unas horas del primer dia; por eso tambien:
--   II-A en `auditoria_integridad()` · cuenta fichas encuadradas cuyo derivado
--     no es la efectiva de hoy. Si el job se cae, el gate lo dice.
--
-- Con eso se saca SOLO el bloqueo de fechas futuras del trigger. El control
-- de superposicion (23P01) queda igual.
--
-- QUE HACE UNA ALICUOTA FUTURA HOY: nada sobre las fichas. Todo lo que escribe
-- el derivado lo calcula con la fecha argentina de hoy, y `ii_tasa_efectiva`
-- elige la fila cuya vigencia CONTIENE esa fecha. `cambiar_alicuota_ii` cierra
-- la vigente en `desde - 1`, que sigue cubriendo hoy, y el refresco por
-- sentencia que dispara la escritura no cambia ningun numero.
--
-- CAMBIAR_ALICUOTA_II CON UNA FUTURA YA CARGADA. Hasta aca el INSERT abria la
-- fila nueva siempre sin `vigente_hasta`. Con vigencias futuras eso deja de
-- alcanzar: si hay una programada para el 1/12 y se carga otra para el 1/11,
-- el UPDATE cierra la de hoy el 31/10, la del 1/12 no se toca (empieza
-- despues), y la nueva abierta se le superpone → 23P01. La fila nueva ahora
-- nace cerrada el dia antes de la siguiente que ya existe (si existe): queda
-- intercalada, igual que una retroactiva entre dos tramos de historia —que
-- antes tambien tiraba 23P01—. Misma fecha que una existente sigue siendo
-- "corregir la tasa de esa fila".
--
-- No cambia firmas ni permisos: parche por ancla sobre el cuerpo vivo de
-- `validar_ii_alicuota`, `cambiar_alicuota_ii` y `auditoria_integridad`
-- (CREATE OR REPLACE conserva los GRANT). No hay funciones nuevas.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 0 · Helper de cirugia sobre el cuerpo vivo (mismo contrato que _mig278_ancla)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig282_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · validar_ii_alicuota: fuera el bloqueo de fechas futuras
-- -------------------------------------------------------------------------
SELECT public._mig282_ancla(
  'public.validar_ii_alicuota()'::regprocedure,
  E'DECLARE\n  v_hoy date := (now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date;\nBEGIN\n  IF NEW.vigente_desde > v_hoy THEN\n    RAISE EXCEPTION ''Todavia no se pueden cargar alicuotas con vigencia futura (desde %): no hay quien refresque la tasa el dia que empieza.'',\n      NEW.vigente_desde\n      USING ERRCODE = ''22023'';\n  END IF;\n',
  E'BEGIN\n  -- mig 282 (#865): las vigencias futuras se aceptan. Las activa el job\n  -- diario refrescar-ii.yml y la deriva la ve II-A de auditoria_integridad().\n');

-- -------------------------------------------------------------------------
-- 2 · cambiar_alicuota_ii: la nueva se intercala antes de la siguiente
-- -------------------------------------------------------------------------
SELECT public._mig282_ancla(
  'public.cambiar_alicuota_ii(bigint,numeric,date)'::regprocedure,
  E'  INSERT INTO public.ii_alicuotas (encuadre_id, tasa_nominal, vigente_desde)\n  VALUES (p_encuadre_id, p_tasa_nominal, p_vigente_desde)\n',
  E'  -- mig 282 (#865): si ya hay una alicuota que empieza despues (una futura\n'
  || E'  -- programada, o el tramo siguiente de la historia), la nueva termina el\n'
  || E'  -- dia antes de esa. Abierta se le superpondria (23P01).\n'
  || E'  INSERT INTO public.ii_alicuotas (encuadre_id, tasa_nominal, vigente_desde, vigente_hasta)\n'
  || E'  VALUES (p_encuadre_id, p_tasa_nominal, p_vigente_desde,\n'
  || E'          (SELECT min(s.vigente_desde) - 1 FROM public.ii_alicuotas s\n'
  || E'            WHERE s.encuadre_id = p_encuadre_id AND s.vigente_desde > p_vigente_desde))\n');

-- -------------------------------------------------------------------------
-- 3 · auditoria_integridad: II-A
--
-- MEDIUM y no high, a proposito (como BOT-A): la deriva aparece sola el dia
-- que entra en vigencia una alicuota, entre las 00:00 y la corrida del job,
-- que Actions atrasa horas. En high eso tumbaria overall_ok —y con el el gate
-- de integridad entero— por un cron atrasado, sin nada roto. Lo que importa
-- es que se vea, y en medium se ve en la lista de checks en rojo.
-- -------------------------------------------------------------------------
SELECT public._mig282_ancla(
  'public.auditoria_integridad()'::regprocedure,
  E'      (SELECT public.auditoria_funciones_stock_sin_origen()))\n  )\n',
  E'      (SELECT public.auditoria_funciones_stock_sin_origen())),\n'
  || E'    -- mig 282 (#865): medium a proposito. La deriva aparece sola el dia que\n'
  || E'    -- entra en vigencia una alicuota futura, hasta que corre refrescar-ii.yml\n'
  || E'    -- (Actions lo atrasa horas). En high un cron atrasado tumbaria overall_ok.\n'
  || E'    (''II-A'',''medium'',''fichas encuadradas con impuestos_internos distinto de la efectiva de hoy (refresco diario, mig 282, #865)'',\n'
  || E'      (SELECT count(*) FROM productos\n'
  || E'        WHERE ii_encuadre_id IS NOT NULL\n'
  || E'          AND impuestos_internos IS DISTINCT FROM COALESCE(round(ii_tasa_efectiva(\n'
  || E'                ii_encuadre_id, (now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date), 4), 0)))\n'
  || E'  )\n');

DROP FUNCTION public._mig282_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 4 · Verificacion. Si algo de esto falla, no se aplica nada.
--
-- La parte de comportamiento corre en un sub-bloque que SIEMPRE termina en
-- excepcion: todo lo que escribe (alicuotas de prueba, refrescos) se deshace
-- con el savepoint implicito, haya andado o no.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def    text;
  v_n      integer;
  v_hoy    date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_enc    bigint;
  v_admin  uuid;
  v_vig    bigint;
  v_antes  text;
  v_despues text;
  v_f1     bigint;
  v_f2     bigint;
  v_m      bigint;
  v_checks jsonb;
BEGIN
  -- Estructura.
  v_def := pg_get_functiondef('public.validar_ii_alicuota()'::regprocedure);
  IF v_def LIKE '%vigencia futura%' OR v_def LIKE '%22023%' THEN
    RAISE EXCEPTION 'validar_ii_alicuota conserva el bloqueo de fechas futuras';
  END IF;
  IF v_def NOT LIKE '%23P01%' THEN
    RAISE EXCEPTION 'validar_ii_alicuota perdio el control de superposicion';
  END IF;
  v_def := pg_get_functiondef('public.cambiar_alicuota_ii(bigint,numeric,date)'::regprocedure);
  IF v_def NOT LIKE '%min(s.vigente_desde) - 1%' THEN
    RAISE EXCEPTION 'cambiar_alicuota_ii no intercala la nueva antes de la siguiente';
  END IF;
  v_def := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  IF (length(v_def) - length(replace(v_def, $q$('II-A'$q$, ''))) / length($q$('II-A'$q$) <> 1 THEN
    RAISE EXCEPTION 'auditoria_integridad no tiene II-A exactamente una vez';
  END IF;

  -- Permisos: nada cambio de manos.
  IF has_function_privilege('anon', 'public.refrescar_ii_productos()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.refrescar_ii_productos()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.refrescar_ii_productos()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cambiar_alicuota_ii(bigint, numeric, date)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.validar_ii_alicuota()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.auditoria_integridad()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Permisos de las funciones de impuestos internos mal puestos';
  END IF;

  -- II-A en la salida, medium.
  v_checks := public.auditoria_integridad() -> 'checks';
  SELECT count(*) INTO v_n FROM jsonb_array_elements(v_checks) c
   WHERE c->>'id' = 'II-A' AND c->>'severidad' = 'medium';
  IF v_n <> 1 THEN RAISE EXCEPTION 'II-A no aparece (o no es medium) en auditoria_integridad()'; END IF;
  RAISE NOTICE 'II-A al aplicar: % violaciones',
    (SELECT c->>'violaciones' FROM jsonb_array_elements(v_checks) c WHERE c->>'id' = 'II-A');

  -- Comportamiento: el encuadre con mas fichas que tenga tasa vigente abierta.
  SELECT p.ii_encuadre_id INTO v_enc
    FROM public.productos p
    JOIN public.ii_alicuotas a ON a.encuadre_id = p.ii_encuadre_id
                              AND a.vigente_desde <= v_hoy AND a.vigente_hasta IS NULL
   GROUP BY p.ii_encuadre_id ORDER BY count(*) DESC LIMIT 1;
  SELECT id INTO v_admin FROM public.perfiles WHERE rol = 'admin' LIMIT 1;
  IF v_enc IS NULL OR v_admin IS NULL THEN
    RAISE NOTICE 'Sin encuadre con fichas o sin admin: se salta la prueba de comportamiento';
    RETURN;
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    SELECT id INTO v_vig FROM public.ii_alicuotas
     WHERE encuadre_id = v_enc AND vigente_desde <= v_hoy AND vigente_hasta IS NULL;
    SELECT string_agg(id || ':' || impuestos_internos, ',' ORDER BY id) INTO v_antes
      FROM public.productos WHERE ii_encuadre_id = v_enc;

    -- (a) Una futura: cierra la vigente el dia antes, las fichas no se mueven.
    v_f1 := public.cambiar_alicuota_ii(v_enc, 0.37, v_hoy + 30);
    IF (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_vig) IS DISTINCT FROM v_hoy + 29 THEN
      RAISE EXCEPTION 'La vigente no quedo cerrada en desde-1';
    END IF;
    IF (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_f1) IS NOT NULL THEN
      RAISE EXCEPTION 'La futura no quedo abierta';
    END IF;
    SELECT string_agg(id || ':' || impuestos_internos, ',' ORDER BY id) INTO v_despues
      FROM public.productos WHERE ii_encuadre_id = v_enc;
    IF v_despues IS DISTINCT FROM v_antes THEN
      RAISE EXCEPTION 'Una alicuota futura movio las fichas hoy';
    END IF;
    IF round(public.ii_tasa_efectiva(v_enc, v_hoy + 30), 4) <> round(100 * 0.37 / 0.63, 4) THEN
      RAISE EXCEPTION 'ii_tasa_efectiva no ve la futura en su fecha';
    END IF;

    -- (b) Misma fecha: corrige esa fila.
    v_f2 := public.cambiar_alicuota_ii(v_enc, 0.41, v_hoy + 30);
    IF v_f2 IS DISTINCT FROM v_f1
       OR (SELECT tasa_nominal FROM public.ii_alicuotas WHERE id = v_f1) IS DISTINCT FROM 0.41 THEN
      RAISE EXCEPTION 'Misma fecha no corrigio la fila futura';
    END IF;

    -- (c) Otra en el medio: se intercala sin superponerse.
    v_m := public.cambiar_alicuota_ii(v_enc, 0.33, v_hoy + 10);
    IF (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_vig) IS DISTINCT FROM v_hoy + 9
       OR (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_m) IS DISTINCT FROM v_hoy + 29
       OR (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_f1) IS NOT NULL THEN
      RAISE EXCEPTION 'La intercalada no quedo entre la vigente y la futura';
    END IF;

    -- (d) La superposicion sigue rechazada.
    BEGIN
      INSERT INTO public.ii_alicuotas (encuadre_id, tasa_nominal, vigente_desde)
      VALUES (v_enc, 0.5, v_hoy + 5);
      RAISE EXCEPTION 'mig282: la superposicion no fue rechazada';
    EXCEPTION WHEN exclusion_violation THEN
      NULL;
    END;

    SELECT string_agg(id || ':' || impuestos_internos, ',' ORDER BY id) INTO v_despues
      FROM public.productos WHERE ii_encuadre_id = v_enc;
    IF v_despues IS DISTINCT FROM v_antes THEN
      RAISE EXCEPTION 'Las alicuotas futuras movieron las fichas hoy';
    END IF;

    RAISE EXCEPTION 'mig282_deshacer';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig282_deshacer' THEN
      RAISE;
    END IF;
  END;

  -- Lo de prueba no quedo.
  IF EXISTS (SELECT 1 FROM public.ii_alicuotas WHERE encuadre_id = v_enc AND vigente_desde > v_hoy) THEN
    RAISE EXCEPTION 'Quedaron alicuotas de prueba';
  END IF;
END
$verif$;

COMMIT;
