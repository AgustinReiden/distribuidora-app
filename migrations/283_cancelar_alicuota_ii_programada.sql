-- =========================================================================
-- mig 283 · CANCELAR UNA ALICUOTA DE II PROGRAMADA A FUTURO (#914)
--
-- Desde la 282 se cargan alicuotas con `vigente_desde` futura:
-- `cambiar_alicuota_ii` cierra la anterior en `desde - 1` e inserta la nueva
-- (intercalada antes de la siguiente, si ya hay otra programada). Lo que no
-- habia era la vuelta atras. Borrar la fila a mano deja a la anterior cerrada
-- en `desde - 1` y un hueco: desde ese dia el encuadre queda sin tasa y el
-- refresco diario pondria el II de todas sus fichas en 0.
--
-- `cancelar_alicuota_programada(id)` hace las dos cosas en una transaccion:
--   1. borra la programada;
--   2. reabre la anterior del mismo encuadre —la que termina justo el dia
--      antes, `vigente_hasta = borrada.vigente_desde - 1`— poniendole el
--      `vigente_hasta` de la borrada: NULL si la borrada era la abierta, o el
--      dia antes de la siguiente programada si la borrada estaba intercalada.
--   El orden importa: primero el DELETE y despues el UPDATE. Al reves, el
--   trigger de superposicion (23P01) veria a la anterior pisando a la que
--   todavia no se borro.
--
-- SIN ANTERIOR. Si la programada era la primera fila del encuadre (encuadre
-- nuevo creado con fecha futura), solo se borra. El encuadre vuelve a estar
-- como antes de programarla: sin tasa en esas fechas. No hay nada que
-- reabrir, y abrir otra fila hacia atras inventaria una vigencia que nadie
-- cargo. Lo mismo si la anterior no termina pegada (hueco previo en la
-- historia): ese hueco ya estaba y no lo crea esta funcion.
--
-- SOLO FUTURAS. `vigente_desde > hoy` (fecha argentina, la misma que usa el
-- derivado). Una que ya empezo ya se aplico a las fichas y a los pedidos de
-- esos dias: eso se corrige cargando otra tasa, no borrando historia.
--
-- LAS FICHAS NO SE MUEVEN. El DELETE y el UPDATE disparan el refresco por
-- sentencia de `ii_alicuotas`, que recalcula con la efectiva de HOY. Hoy
-- seguia vigente la anterior (la borrada empezaba despues), y despues del
-- UPDATE la sigue cubriendo: el numero es el mismo.
--
-- CONCURRENCIA. Antes de tocar nada se bloquean TODAS las filas del encuadre.
-- Sin eso, dos cancelaciones de programadas contiguas (+10 y +30) en paralelo
-- dejan a la vigente cerrada en +29 y un hueco: la segunda buscaria a su
-- anterior (+10) ya borrada por la primera.
--
-- Permisos: SECURITY INVOKER con `es_admin()` adentro, igual que
-- `cambiar_alicuota_ii` (la RLS de ii_alicuotas tambien exige admin para
-- DELETE y UPDATE). Funcion nueva: se revoca a PUBLIC y anon en la misma
-- migracion; el frontend la llama, asi que authenticated la conserva.
-- =========================================================================

BEGIN;

CREATE FUNCTION public.cancelar_alicuota_programada(p_alicuota_id bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_hoy  date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_enc  bigint;
  v_fila public.ii_alicuotas%ROWTYPE;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede cancelar alicuotas de impuestos internos' USING ERRCODE = '42501';
  END IF;

  SELECT encuadre_id INTO v_enc FROM public.ii_alicuotas WHERE id = p_alicuota_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La alicuota % no existe (puede que ya la hayan cancelado)', p_alicuota_id USING ERRCODE = 'P0002';
  END IF;

  -- Todo el encuadre bloqueado: ver CONCURRENCIA en la cabecera de la mig 283.
  PERFORM 1 FROM public.ii_alicuotas WHERE encuadre_id = v_enc ORDER BY id FOR UPDATE;

  -- Se relee despues del bloqueo: otra cancelacion pudo haberla borrado.
  SELECT * INTO v_fila FROM public.ii_alicuotas WHERE id = p_alicuota_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La alicuota % no existe (puede que ya la hayan cancelado)', p_alicuota_id USING ERRCODE = 'P0002';
  END IF;

  IF v_fila.vigente_desde <= v_hoy THEN
    RAISE EXCEPTION 'Solo se puede cancelar una alicuota que todavia no empezo; esta rige desde %. Para corregirla, carga otra tasa.',
      to_char(v_fila.vigente_desde, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  -- Primero el DELETE: si se extendiera antes a la anterior, se superpondria
  -- con esta (23P01).
  DELETE FROM public.ii_alicuotas WHERE id = v_fila.id;

  -- La anterior pegada (si existe) hereda el final de la borrada.
  UPDATE public.ii_alicuotas
     SET vigente_hasta = v_fila.vigente_hasta
   WHERE encuadre_id = v_fila.encuadre_id
     AND vigente_hasta = v_fila.vigente_desde - 1;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.cancelar_alicuota_programada(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancelar_alicuota_programada(bigint) TO authenticated, service_role;

COMMENT ON FUNCTION public.cancelar_alicuota_programada(bigint) IS
  'mig 283 (#914): borra una alicuota de II con vigencia futura y reabre la anterior pegada. Solo admin.';

-- -------------------------------------------------------------------------
-- Verificacion (todo lo de prueba se deshace)
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_enc     bigint;
  v_admin   uuid;
  v_otro    uuid;
  v_vig     bigint;
  v_a       bigint;
  v_b       bigint;
  v_nuevo   bigint;
  v_antes   text;
  v_global  text;
  v_alic    text;
  v_log     text := '';
BEGIN
  -- Permisos.
  IF has_function_privilege('anon', 'public.cancelar_alicuota_programada(bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cancelar_alicuota_programada(bigint)', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                 WHERE p.oid = 'public.cancelar_alicuota_programada(bigint)'::regprocedure
                   AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'Permisos de cancelar_alicuota_programada mal puestos';
  END IF;
  v_log := v_log || 'permisos ok (anon no, PUBLIC no, authenticated si); ';

  SELECT p.ii_encuadre_id INTO v_enc
    FROM public.productos p
    JOIN public.ii_alicuotas a ON a.encuadre_id = p.ii_encuadre_id
                              AND a.vigente_desde <= v_hoy AND a.vigente_hasta IS NULL
   GROUP BY p.ii_encuadre_id ORDER BY count(*) DESC LIMIT 1;
  SELECT id INTO v_admin FROM public.perfiles WHERE rol = 'admin' LIMIT 1;
  SELECT id INTO v_otro FROM public.perfiles WHERE rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM public.perfil_roles r WHERE r.usuario_id = perfiles.id AND r.rol = 'admin')
   LIMIT 1;
  IF v_enc IS NULL OR v_admin IS NULL OR v_otro IS NULL THEN
    RAISE NOTICE 'Sin encuadre con fichas, admin o preventista: se salta la prueba de comportamiento';
    RETURN;
  END IF;

  SELECT md5(string_agg(id || ':' || coalesce(impuestos_internos::text, '-'), ',' ORDER BY id)) INTO v_global
    FROM public.productos;
  SELECT md5(string_agg(id || ':' || encuadre_id || ':' || tasa_nominal || ':' || vigente_desde || ':'
                        || coalesce(vigente_hasta::text, '-'), ',' ORDER BY id)) INTO v_alic
    FROM public.ii_alicuotas;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    SELECT id INTO v_vig FROM public.ii_alicuotas
     WHERE encuadre_id = v_enc AND vigente_desde <= v_hoy AND vigente_hasta IS NULL;
    SELECT string_agg(id || ':' || impuestos_internos, ',' ORDER BY id) INTO v_antes
      FROM public.productos WHERE ii_encuadre_id = v_enc;
    v_log := v_log || format('encuadre %s, vigente %s, %s fichas; ', v_enc, v_vig,
                             (SELECT count(*) FROM public.productos WHERE ii_encuadre_id = v_enc));

    -- (1) La unica programada: la vigente vuelve a quedar abierta.
    v_a := public.cambiar_alicuota_ii(v_enc, 0.37, v_hoy + 30);
    IF (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_vig) IS DISTINCT FROM v_hoy + 29 THEN
      RAISE EXCEPTION '(1) la programada no cerro la vigente';
    END IF;
    PERFORM public.cancelar_alicuota_programada(v_a);
    IF EXISTS (SELECT 1 FROM public.ii_alicuotas WHERE id = v_a)
       OR (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_vig) IS NOT NULL THEN
      RAISE EXCEPTION '(1) cancelar la unica programada no reabrio la vigente';
    END IF;
    IF (SELECT string_agg(id || ':' || impuestos_internos, ',' ORDER BY id) FROM public.productos WHERE ii_encuadre_id = v_enc)
       IS DISTINCT FROM v_antes THEN
      RAISE EXCEPTION '(1) las fichas se movieron';
    END IF;
    v_log := v_log || '(1) unica programada cancelada: vigente abierta, fichas iguales; ';

    -- (2) Dos programadas (+10, +30), se cancela +30: +10 queda abierta.
    v_a := public.cambiar_alicuota_ii(v_enc, 0.33, v_hoy + 10);
    v_b := public.cambiar_alicuota_ii(v_enc, 0.37, v_hoy + 30);
    IF (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_vig) IS DISTINCT FROM v_hoy + 9
       OR (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_a) IS DISTINCT FROM v_hoy + 29 THEN
      RAISE EXCEPTION '(2) armado: las programadas no quedaron encadenadas';
    END IF;
    PERFORM public.cancelar_alicuota_programada(v_b);
    IF EXISTS (SELECT 1 FROM public.ii_alicuotas WHERE id = v_b)
       OR (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_a) IS NOT NULL
       OR (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_vig) IS DISTINCT FROM v_hoy + 9 THEN
      RAISE EXCEPTION '(2) cancelar +30 no dejo abierta a +10';
    END IF;
    v_log := v_log || '(2) cancelar +30: +10 abierta, vigente hasta +9; ';

    -- (3) Otra vez +10 y +30, se cancela +10: la vigente se estira hasta +29.
    v_b := public.cambiar_alicuota_ii(v_enc, 0.37, v_hoy + 30);
    PERFORM public.cancelar_alicuota_programada(v_a);
    IF EXISTS (SELECT 1 FROM public.ii_alicuotas WHERE id = v_a)
       OR (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_vig) IS DISTINCT FROM v_hoy + 29
       OR (SELECT vigente_hasta FROM public.ii_alicuotas WHERE id = v_b) IS NOT NULL THEN
      RAISE EXCEPTION '(3) cancelar +10 no estiro la vigente hasta +29';
    END IF;
    IF (SELECT string_agg(id || ':' || impuestos_internos, ',' ORDER BY id) FROM public.productos WHERE ii_encuadre_id = v_enc)
       IS DISTINCT FROM v_antes THEN
      RAISE EXCEPTION '(3) las fichas se movieron';
    END IF;
    v_log := v_log || '(3) cancelar +10: vigente hasta +29, +30 abierta, fichas iguales; ';

    -- (4) Una que ya empezo no se cancela.
    BEGIN
      PERFORM public.cancelar_alicuota_programada(v_vig);
      RAISE EXCEPTION '(4) se cancelo una alicuota vigente';
    EXCEPTION WHEN invalid_parameter_value THEN
      v_log := v_log || '(4) vigente rechazada con 22023; ';
    END;

    -- (5) Inexistente.
    BEGIN
      PERFORM public.cancelar_alicuota_programada(-1);
      RAISE EXCEPTION '(5) se acepto un id inexistente';
    EXCEPTION WHEN no_data_found THEN
      v_log := v_log || '(5) inexistente rechazada con P0002; ';
    END;

    -- (6) Un no admin no puede.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_otro, 'role', 'authenticated')::text, true);
    IF public.es_admin() THEN RAISE EXCEPTION '(6) el preventista de prueba es admin'; END IF;
    BEGIN
      PERFORM public.cancelar_alicuota_programada(v_b);
      RAISE EXCEPTION '(6) un no admin cancelo';
    EXCEPTION WHEN insufficient_privilege THEN
      v_log := v_log || '(6) no admin rechazado con 42501; ';
    END;
    IF NOT EXISTS (SELECT 1 FROM public.ii_alicuotas WHERE id = v_b) THEN
      RAISE EXCEPTION '(6) la programada desaparecio';
    END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

    -- (7) La primera fila de un encuadre (programada sin anterior): solo se borra.
    INSERT INTO public.ii_encuadres (nombre) VALUES ('mig283 prueba') RETURNING id INTO v_nuevo;
    v_a := public.cambiar_alicuota_ii(v_nuevo, 0.1, v_hoy + 5);
    PERFORM public.cancelar_alicuota_programada(v_a);
    IF EXISTS (SELECT 1 FROM public.ii_alicuotas WHERE encuadre_id = v_nuevo) THEN
      RAISE EXCEPTION '(7) quedo algo en el encuadre sin anterior';
    END IF;
    v_log := v_log || '(7) programada sin anterior: solo se borra; ';

    -- Al final, las fichas de toda la base iguales.
    IF (SELECT md5(string_agg(id || ':' || coalesce(impuestos_internos::text, '-'), ',' ORDER BY id)) FROM public.productos)
       IS DISTINCT FROM v_global THEN
      RAISE EXCEPTION 'Las fichas de la base cambiaron';
    END IF;
    v_log := v_log || 'fichas de toda la base iguales; ';

    RAISE EXCEPTION 'mig283_deshacer';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig283_deshacer' THEN
      RAISE;
    END IF;
  END;

  -- Lo de prueba no quedo.
  IF (SELECT md5(string_agg(id || ':' || encuadre_id || ':' || tasa_nominal || ':' || vigente_desde || ':'
                            || coalesce(vigente_hasta::text, '-'), ',' ORDER BY id)) FROM public.ii_alicuotas)
     IS DISTINCT FROM v_alic
     OR EXISTS (SELECT 1 FROM public.ii_encuadres WHERE nombre = 'mig283 prueba') THEN
    RAISE EXCEPTION 'Quedaron datos de prueba';
  END IF;
  v_log := v_log || 'pruebas deshechas';

  RAISE NOTICE 'mig283: %', v_log;
  PERFORM set_config('mig283.log', v_log, true);
END
$verif$;

COMMIT;
