-- #1075 · Las metas no cruzan sucursales (lo que quedó de #1074)
--
-- 1 · La tabla metas_preventista se leía entre sucursales por REST: la policy
--     de admin/encargado no miraba la sucursal. Ahora admin y encargado leen
--     sólo las metas de las sucursales que tienen en usuario_sucursales, el
--     mismo cruce que guardar_meta_preventista y avance_metas_preventista
--     (mig 337). El admin de varias sucursales sigue leyendo todo lo que leía.
--     Qué roles leen la tabla no cambia: el encargado la sigue leyendo (en su
--     sucursal); la policy del preventista (las suyas) queda igual.
--
-- 2 · avance_metas_preventista devolvía el nombre de un preventista de otra
--     sucursal aunque no mostrara ninguna meta (sale de perfiles como
--     DEFINER). Ahora, si un admin mira a otro, no ve ninguna de sus metas y no
--     comparte sucursal con él, el nombre va en NULL.
--
-- 3 · rendimiento_preventistas(p_sucursal_id) embebía el avance completo del
--     preventista, con las metas de TODAS las sucursales del admin, mientras
--     metas_cargadas contaba sólo las de la sucursal pedida. Ahora las metas
--     embebidas se acotan a las sucursales del reporte y el resumen se cuenta
--     sobre ésas. Sin sucursal (todas las del admin) da lo mismo que antes.
--     Hoy ningún preventista tiene metas en dos sucursales: no cambia ningún
--     número visible.
--
-- El comportamiento lo prueba scripts/test-metas-sucursal-1075.sql.

BEGIN;

CREATE OR REPLACE FUNCTION public._mig1075_ancla(
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
-- 1 · La tabla: admin y encargado, en sus sucursales.
-- ---------------------------------------------------------------------------
ALTER POLICY metas_preventista_admin_select ON public.metas_preventista
  USING (
    EXISTS (SELECT 1 FROM perfiles
             WHERE perfiles.id = auth.uid()
               AND perfiles.rol = ANY (ARRAY['admin'::text, 'encargado'::text]))
    -- #1075: sólo las sucursales asignadas (usuario_sucursales_select_own
    -- deja leer las propias filas desde la policy).
    AND sucursal_id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                         WHERE us.usuario_id = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- 2 · avance_metas_preventista: el nombre tampoco cruza.
-- ---------------------------------------------------------------------------
SELECT public._mig1075_ancla('public.avance_metas_preventista(uuid,date)'::regprocedure,
$ancla$                             WHERE us.usuario_id = auth.uid()));

  IF v_sucursales IS NULL THEN$ancla$,
$nuevo$                             WHERE us.usuario_id = auth.uid()));

  -- #1075: si un admin mira a otro, no ve ninguna de sus metas y no comparte
  -- sucursal con él, tampoco se lleva el nombre.
  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND v_sucursales IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM usuario_sucursales mia
         JOIN usuario_sucursales suya ON suya.sucursal_id = mia.sucursal_id
        WHERE mia.usuario_id = auth.uid() AND suya.usuario_id = v_target) THEN
    v_nombre := NULL;
  END IF;

  IF v_sucursales IS NULL THEN$nuevo$);

REVOKE ALL ON FUNCTION public.avance_metas_preventista(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avance_metas_preventista(uuid, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3 · rendimiento_preventistas: las metas embebidas, de las sucursales pedidas.
-- ---------------------------------------------------------------------------
SELECT public._mig1075_ancla('public.rendimiento_preventistas(bigint,date)'::regprocedure,
$ancla$      'metas', COALESCE(av.detalle -> 'metas', '[]'::jsonb),
      'resumen_metas', COALESCE(av.detalle -> 'resumen',
                                jsonb_build_object('total', 0, 'cumplidas', 0, 'en_riesgo', 0)),$ancla$,
$nuevo$      'metas', avs.metas,
      'resumen_metas', avs.resumen,$nuevo$);

SELECT public._mig1075_ancla('public.rendimiento_preventistas(bigint,date)'::regprocedure,
$ancla$  LEFT JOIN LATERAL (
    SELECT avance_metas_preventista(b.usuario_id, v_periodo) AS detalle
    WHERE mt.total > 0
  ) av ON true;$ancla$,
$nuevo$  LEFT JOIN LATERAL (
    SELECT avance_metas_preventista(b.usuario_id, v_periodo) AS detalle
    WHERE mt.total > 0
  ) av ON true
  -- #1075: el avance trae las metas de todas las sucursales del admin; acá
  -- quedan las de v_sucursales, y el resumen se cuenta sobre ésas (como
  -- metas_cargadas). Sin avance, metas vacías y resumen en cero.
  LEFT JOIN LATERAL (
    SELECT COALESCE(jsonb_agg(x.e ORDER BY x.ord), '[]'::jsonb) AS metas,
           jsonb_build_object(
             'total',     count(*),
             'cumplidas', count(*) FILTER (WHERE x.e->>'estado' = 'cumplida'),
             'en_riesgo', count(*) FILTER (WHERE x.e->>'estado' = 'en_riesgo')) AS resumen
      FROM jsonb_array_elements(av.detalle -> 'metas') WITH ORDINALITY AS x(e, ord)
      JOIN metas_preventista mp ON mp.id = (x.e->>'id')::bigint
     WHERE mp.sucursal_id = ANY(v_sucursales)
  ) avs ON true;$nuevo$);

REVOKE ALL ON FUNCTION public.rendimiento_preventistas(bigint, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rendimiento_preventistas(bigint, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4 · Verificación. El comportamiento lo prueba scripts/test-metas-sucursal-1075.sql.
-- ---------------------------------------------------------------------------
DO $verif$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'metas_preventista'
                    AND policyname = 'metas_preventista_admin_select'
                    AND qual ~ 'usuario_sucursales') THEN
    RAISE EXCEPTION '#1075 · metas_preventista_admin_select no cruza con usuario_sucursales';
  END IF;

  IF pg_get_functiondef('public.avance_metas_preventista(uuid,date)'::regprocedure) !~ 'v_nombre := NULL'
     OR pg_get_functiondef('public.rendimiento_preventistas(bigint,date)'::regprocedure) !~ 'avs\.metas' THEN
    RAISE EXCEPTION '#1075 · los parches de avance/rendimiento no quedaron';
  END IF;

  IF has_function_privilege('anon', 'public.avance_metas_preventista(uuid,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rendimiento_preventistas(bigint,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.avance_metas_preventista(uuid,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rendimiento_preventistas(bigint,date)', 'EXECUTE') THEN
    RAISE EXCEPTION '#1075 · grants inesperados en avance_metas_preventista / rendimiento_preventistas';
  END IF;

  IF (SELECT count(*) FROM public.auditoria_definer_sin_rol()) <> 0 THEN
    RAISE EXCEPTION '#1075 · SEG-A no está en cero';
  END IF;
END
$verif$;

DROP FUNCTION public._mig1075_ancla(regprocedure, text, text);

COMMIT;
