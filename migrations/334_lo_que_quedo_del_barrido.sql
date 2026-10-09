-- #1056 · Lo que quedó del barrido de #1048
--
-- 1 · ROL NULL. Mismo molde que registrar_geolocalizacion_pedido (mig 330): con
--     rol NULL, `<>` y `NOT IN` dan NULL y el IF no corta. Hoy no se alcanza
--     (perfiles.rol es NOT NULL y sin perfil no hay sucursal activa, que las tres
--     exigen), pero el guard tiene que decir lo que quiere decir:
--       obtener_geolocalizacion_preventistas, registrar_visita_cliente,
--       sustituir_regalo_pedido.
--
-- 2 · limpiar_orden_entrega(p_transportista_id). Un transportista borraba el
--     orden de entrega de los pedidos de OTRO transportista de su sucursal:
--     nunca comparaba el parámetro con auth.uid(). Nadie la llama (ni src/, ni
--     edge functions, ni otra función; pg_stat_statements: 0 llamadas): se
--     revoca a las tres mitades, como las de la 330.
--
-- 3 · registrar_nota_credito: `p_usuario_id` iba directo al INSERT, así que un
--     encargado podía firmar la nota a nombre de otro. El front manda siempre
--     el propio user.id: ahora un uuid ajeno se rechaza y la nota queda a
--     nombre de auth.uid() (también cuando el parámetro viene NULL, que antes
--     dejaba la nota sin autor).
--
-- 4 · RECORRIDOS QUE NUNCA SE CIERRAN. Antes los cerraba la aprobación de la
--     rendición (revisar_rendicion); hoy la rendición se controla por fecha y
--     chofer (rendiciones_control) y nada los cierra. El último cierre fue la
--     corrida a mano de la 183 (2026-08-18); desde entonces hay 70 "en curso"
--     de días pasados sin ninguna parada pendiente. Decisión del dueño
--     (2026-10-09): cerrarlos ahora y que se cierren solos.
--       · cerrar_recorridos_vencidos corta por el día ARGENTINO. Con
--         CURRENT_DATE (UTC), una corrida a mano después de las 21:00 cerraba la
--         ruta que el chofer está haciendo.
--       · Se corre una vez acá (como postgres: auth.uid() es NULL y el guard de
--         la 330 lo deja pasar).
--       · El cierre diario lo hace .github/workflows/cerrar-recorridos.yml con
--         service_role (en prod no hay pg_cron, decisión de #661).
--     Un recorrido con una parada todavía 'asignado' queda abierto: eso lo
--     resuelve una persona.

BEGIN;

CREATE OR REPLACE FUNCTION public._mig1056_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
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

-- ---------------------------------------------------------------------------
-- 1 · Rol NULL.
-- ---------------------------------------------------------------------------
SELECT public._mig1056_ancla('public.obtener_geolocalizacion_preventistas(date,date)'::regprocedure,
$ancla$  IF v_user_role <> 'admin' THEN$ancla$,
$nuevo$  -- #1056: con `<>` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS DISTINCT FROM 'admin' THEN$nuevo$);

SELECT public._mig1056_ancla('public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)'::regprocedure,
$ancla$  IF v_user_role NOT IN ('preventista', 'admin') THEN$ancla$,
$nuevo$  -- #1056: con `NOT IN` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS NULL OR v_user_role NOT IN ('preventista', 'admin') THEN$nuevo$);

SELECT public._mig1056_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$  IF v_user_role NOT IN ('admin', 'encargado') THEN$ancla$,
$nuevo$  -- #1056: con `NOT IN` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN$nuevo$);

-- ---------------------------------------------------------------------------
-- 2 · limpiar_orden_entrega: sin EXECUTE para la app.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.limpiar_orden_entrega(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.limpiar_orden_entrega(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3 · registrar_nota_credito: la nota es de quien la carga.
-- ---------------------------------------------------------------------------
SELECT public._mig1056_ancla('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure,
$ancla$    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para registrar notas de credito');
  END IF;$ancla$,
$nuevo$    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para registrar notas de credito');
  END IF;

  -- #1056: la nota la firma quien la carga. El parámetro queda por la firma
  -- de la RPC; si viene, tiene que ser el mismo usuario.
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'La nota de credito se registra a nombre de quien la carga');
  END IF;$nuevo$);

SELECT public._mig1056_ancla('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure,
$ancla$p_motivo, p_usuario_id, v_sucursal,$ancla$,
$nuevo$p_motivo, auth.uid(), v_sucursal,$nuevo$);

-- ---------------------------------------------------------------------------
-- 4 · Recorridos vencidos: el día argentino, y el cierre de lo acumulado.
-- ---------------------------------------------------------------------------
SELECT public._mig1056_ancla('public.cerrar_recorridos_vencidos(bigint)'::regprocedure,
$ancla$      AND r.fecha < CURRENT_DATE$ancla$,
$nuevo$      -- #1056: el día argentino. CURRENT_DATE es UTC: pasadas las 21:00
      -- cerraba la ruta que el chofer está haciendo.
      AND r.fecha < (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date$nuevo$);

-- El patch hace CREATE OR REPLACE, que conserva los grants; se reafirman.
REVOKE ALL ON FUNCTION public.cerrar_recorridos_vencidos(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerrar_recorridos_vencidos(bigint) TO service_role;

SELECT * FROM public.cerrar_recorridos_vencidos(NULL);

-- ---------------------------------------------------------------------------
-- 5 · Verificación. El comportamiento lo prueba scripts/test-seg-menores-1056.sql.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_fn text;
  v_n  int;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.limpiar_orden_entrega(uuid)',
    'public.cerrar_recorridos_vencidos(bigint)'
  ] LOOP
    IF has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1056 · % sigue ejecutable por authenticated o anon', v_fn;
    END IF;
    IF NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1056 · % quedó sin EXECUTE para service_role', v_fn;
    END IF;
  END LOOP;

  FOREACH v_fn IN ARRAY ARRAY[
    'public.obtener_geolocalizacion_preventistas(date,date)',
    'public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)',
    'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
    'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'
  ] LOOP
    IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1056 · % perdió el EXECUTE de authenticated', v_fn;
    END IF;
    IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1056 · % quedó ejecutable por anon', v_fn;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_n FROM recorridos rec
   WHERE rec.estado = 'en_curso'
     AND rec.fecha < (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
     AND NOT EXISTS (SELECT 1 FROM recorrido_pedidos rp JOIN pedidos p ON p.id = rp.pedido_id
                      WHERE rp.recorrido_id = rec.id AND p.estado = 'asignado');
  IF v_n > 0 THEN
    RAISE EXCEPTION '#1056 · quedaron % recorridos vencidos sin pendientes en curso', v_n;
  END IF;

  IF (SELECT count(*) FROM public.auditoria_definer_sin_rol()) <> 0 THEN
    RAISE EXCEPTION '#1056 · SEG-A no está en cero';
  END IF;
END
$verif$;

DROP FUNCTION public._mig1056_ancla(regprocedure, text, text);

COMMIT;
