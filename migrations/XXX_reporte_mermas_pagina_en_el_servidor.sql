-- El historial de mermas pagina en el servidor (#1146).
--
-- reporte_mermas devolvia como mucho `detalle_limite` filas (500 por defecto,
-- 2000 de tope) y la pantalla paginaba de a 20 EN EL CLIENTE sobre ese recorte:
-- lo que pasaba de 500 no se podia ver en /reportes, solo bajarlo en Excel (que
-- re-consultaba con 2000 y en un periodo mas largo seguia recortado). Hoy son
-- ~1189 mermas en total (1148 de una sucursal): un rango de un anio ya muerde.
--
-- Ahora la funcion recibe la pagina: `p_offset` (desde donde) y `p_busqueda`
-- (texto en producto, codigo u observaciones, el mismo `includes` que hacia el
-- cliente: sin comodines, sin normalizar acentos, por eso strpos y no ILIKE).
-- `p_limite_detalle` sigue siendo el tamanio de pagina con el mismo tope.
--
-- La invariante del gate (totales.costo == reporte_gerencial.kpis.mermas, mig
-- 238) no se mueve: `tot`, `por_motivo` y `por_procedencia` siguen sobre `calc`
-- COMPLETO. La busqueda y el offset solo entran en `lista` y `det`, o sea en la
-- lista del detalle; buscar o paginar acorta la lista, nunca mueve un total.
--
-- Salida: las claves de siempre mas `detalle_filtrado` (filas que pasan la
-- busqueda: la base de la paginacion) y `detalle_offset`. `detalle_total`
-- sigue siendo el periodo + filtro de motivo (promociones incluidas).
-- `detalle_truncado` ahora dice "hay mas despues de esta pagina"; con offset 0
-- y sin busqueda es el mismo valor de antes. Un offset pasado del final no es
-- error: `detalle` vuelve [] y `detalle_filtrado` dice el total, para que la
-- vista retroceda a la ultima pagina (como useSalvedadesQuery con PGRST103).
--
-- Firma nueva = DROP de la vieja en la misma migracion: dejarla conviviendo
-- da PGRST203 (los rangos [2,5] y [2,7] de argumentos se superponen). Sin
-- CASCADE: nada depende de ella (0 funciones la mencionan; el bot no la usa).
-- Un bundle viejo del PWA que llama con 4 o 5 parametros con nombre cae en la
-- nueva por los defaults. DROP + CREATE pierde owner, ACL y COMMENT: se reponen
-- abajo y el DO $verif$ los comprueba. La funcion sigue SECURITY DEFINER con el
-- mismo guard de rol y sucursal (no mueve stock ni escribe nada).
--
-- Cuerpo: pg_get_functiondef de PROD (md5 c2d0ca5226c1553f6519c4b248fa1056 al
-- escribir esto), con solo esos cambios.

DROP FUNCTION public.reporte_mermas(date, date, bigint, text, integer);

CREATE FUNCTION public.reporte_mermas(
  p_desde date,
  p_hasta date,
  p_sucursal_id bigint DEFAULT NULL::bigint,
  p_motivo text DEFAULT NULL::text,
  p_limite_detalle integer DEFAULT 500,
  -- INTEGER, nunca SMALLINT: por PostgREST todo numero llega como integer.
  p_offset integer DEFAULT 0,
  p_busqueda text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol         text;
  v_nombre      text;
  v_limite      integer := LEAST(GREATEST(COALESCE(p_limite_detalle, 500), 1), 2000);
  -- #1146: la pagina del detalle. La busqueda va en minusculas y recortada a
  -- 100 caracteres; vacia o solo espacios = sin busqueda.
  v_offset      integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_q           text    := lower(NULLIF(btrim(left(p_busqueda, 100)), ''));
  v_out         jsonb;
BEGIN
  -- Guard identico al de la 208: es la familia de /reportes, donde
  -- `reporte_rentabilidad` ya expone costos a encargado.
  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  -- Resolucion de sucursales calcada de la 130 (activas INTERSECT asignadas), NO
  -- de la 208 (todas las sucursales). Este reporte tiene que cerrar exacto contra
  -- kpis.mermas: si "Red" resuelve a conjuntos distintos, los dos numeros difieren
  -- y nadie sabe cual esta mal.
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas);
    END IF;
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no esta asignada al usuario', p_sucursal_id;
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;

  WITH
  -- #570: el criterio (cascada, dia argentino, clasificacion) sale de la MISMA
  -- funcion que consume `reporte_gerencial`. Aca las de promocion ENTRAN --para
  -- poder decir cuanto son y por que no cuentan-- y quedan fuera de los totales
  -- por `clasificacion <> 'promocion'`, que es el filtro que aplica el gerencial.
  calc AS (
    SELECT * FROM public.mermas_valorizadas(p_desde, p_hasta, v_sucursales)
    WHERE (p_motivo IS NULL OR motivo = p_motivo)
  ),
  -- Los totales y el corte por motivo se calculan sobre el CTE COMPLETO. Solo el
  -- detalle lleva LIMIT: truncar acorta la lista, nunca mueve un total. Ese era el
  -- defecto del modal que este reporte vino a reemplazar.
  tot AS (
    SELECT
      COUNT(*) FILTER (WHERE clasificacion <> 'promocion')                       AS registros,
      COALESCE(SUM(cantidad)     FILTER (WHERE clasificacion <> 'promocion'), 0) AS unidades,
      COALESCE(SUM(costo_total)  FILTER (WHERE clasificacion <> 'promocion'), 0) AS costo,
      COALESCE(SUM(precio_total) FILTER (WHERE clasificacion <> 'promocion'), 0) AS precio,
      COALESCE(SUM(costo_total)  FILTER (WHERE clasificacion = 'perdida'), 0)    AS costo_perdida,
      COALESCE(SUM(costo_total)  FILTER (WHERE clasificacion = 'ajuste'), 0)     AS costo_ajuste,
      COALESCE(SUM(costo_total)  FILTER (WHERE clasificacion = 'muestra'), 0)    AS costo_muestra,
      COUNT(*) FILTER (WHERE clasificacion = 'promocion')                        AS registros_ajuste_promocion,
      COALESCE(SUM(cantidad)    FILTER (WHERE clasificacion = 'promocion'), 0)   AS unidades_ajuste_promocion,
      COALESCE(SUM(costo_total) FILTER (WHERE clasificacion = 'promocion'), 0)   AS costo_ajuste_promocion,
      COUNT(*) FILTER (WHERE clasificacion <> 'promocion' AND origen_costo = 'estimado')  AS filas_costo_estimado,
      COUNT(*) FILTER (WHERE clasificacion <> 'promocion' AND origen_costo = 'sin_costo') AS filas_sin_costo
    FROM calc
  ),
  por_motivo AS (
    SELECT motivo, clasificacion,
           COUNT(*)                       AS registros,
           COALESCE(SUM(cantidad), 0)     AS unidades,
           COALESCE(SUM(costo_total), 0)  AS costo,
           COALESCE(SUM(precio_total), 0) AS precio,
           COUNT(*) FILTER (WHERE origen_costo = 'estimado')  AS filas_costo_estimado,
           COUNT(*) FILTER (WHERE origen_costo = 'sin_costo') AS filas_sin_costo
    FROM calc GROUP BY motivo, clasificacion
  ),
  -- mig 301 (#847): las MISMAS filas partidas por de donde vinieron. El
  -- faltante de una entrega deja de mezclarse con los ajustes a mano bajo
  -- "Error inventario". Suma lo mismo que por_motivo (lo exige el gate).
  por_procedencia AS (
    SELECT procedencia, motivo, clasificacion,
           COUNT(*)                       AS registros,
           COALESCE(SUM(cantidad), 0)     AS unidades,
           COALESCE(SUM(costo_total), 0)  AS costo,
           COALESCE(SUM(precio_total), 0) AS precio
    FROM calc GROUP BY procedencia, motivo, clasificacion
  ),
  -- #1146: la busqueda solo achica la LISTA. Ningun CTE de arriba la ve, y por
  -- eso buscar no mueve un total (lo que antes garantizaba el filtro en el
  -- cliente). strpos y no ILIKE: el texto no se escapa y % o _ son literales.
  lista AS (
    SELECT * FROM calc
    WHERE v_q IS NULL
       OR strpos(lower(producto_nombre), v_q) > 0
       OR strpos(lower(COALESCE(producto_codigo, '')), v_q) > 0
       OR strpos(lower(COALESCE(observaciones, '')), v_q) > 0
  ),
  -- La pagina: el orden (created_at DESC, id DESC) es total, asi que recorrer
  -- las paginas devuelve cada fila una vez.
  det AS (
    SELECT c.*, per.nombre AS usuario_nombre, suc.nombre AS sucursal_nombre
    FROM (SELECT * FROM lista ORDER BY created_at DESC, id DESC OFFSET v_offset LIMIT v_limite) c
    LEFT JOIN perfiles per   ON per.id = c.usuario_id
    LEFT JOIN sucursales suc ON suc.id = c.sucursal_id
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'sucursal_id', p_sucursal_id,
      'sucursal_nombre', COALESCE(v_nombre, 'Sucursal ' || p_sucursal_id),
      'desde', p_desde,
      'hasta', p_hasta,
      'generado_at', now(),
      'filtro_motivo', p_motivo,
      'criterio', 'Mermas por dia argentino de carga (created_at), valuadas al costo congelado al momento de la merma (mig 119); las anteriores al snapshot van al costo de hoy. El total EXCLUYE promociones y reversion de promocion: no son perdida, son la contrapartida de un regalo ya contabilizado como bonificacion. El criterio no se copia de reporte_gerencial: los dos consumen mermas_valorizadas() (mig 238), y por eso cierran exacto. El precio de venta es el de HOY: la base no guarda a cuanto se vendia el dia de la merma.'
    ),
    'totales', (SELECT to_jsonb(t) FROM tot t),
    'por_motivo', COALESCE((SELECT jsonb_agg(to_jsonb(pm) ORDER BY pm.costo DESC) FROM por_motivo pm), '[]'::jsonb),
    'por_procedencia', COALESCE((SELECT jsonb_agg(to_jsonb(pp) ORDER BY pp.costo DESC) FROM por_procedencia pp), '[]'::jsonb),
    'detalle', COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.created_at DESC, d.id DESC) FROM det d), '[]'::jsonb),
    -- Periodo + filtro de motivo, promociones incluidas: igual que antes.
    'detalle_total', (SELECT COUNT(*) FROM calc),
    -- Lo que pasa la busqueda: la base de la paginacion.
    'detalle_filtrado', (SELECT COUNT(*) FROM lista),
    'detalle_limite', v_limite,
    'detalle_offset', v_offset,
    -- Hay mas filas despues de esta pagina.
    'detalle_truncado', ((SELECT COUNT(*) FROM lista) > v_offset + v_limite)
  ) INTO v_out;

  RETURN v_out;
END;
$function$;

COMMENT ON FUNCTION public.reporte_mermas(date, date, bigint, text, integer, integer, text) IS
  'Mermas agregadas por motivo + detalle paginado. El criterio (cascada de costo, dia argentino, clasificacion) sale de mermas_valorizadas(), la MISMA funcion que consume reporte_gerencial: totales.costo cierra EXACTO contra kpis.mermas por construccion. La pagina (p_offset, p_limite_detalle) y la busqueda (p_busqueda) solo tocan el detalle, nunca un total. migs 226, 238 y XXX (#1146).';

ALTER FUNCTION public.reporte_mermas(date, date, bigint, text, integer, integer, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reporte_mermas(date, date, bigint, text, integer, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_mermas(date, date, bigint, text, integer, integer, text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_oid oid := 'public.reporte_mermas(date,date,bigint,text,integer,integer,text)'::regprocedure;
BEGIN
  -- Una sola sobrecarga, la de 7 argumentos (PGRST203).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = 'reporte_mermas') <> 1
     OR (SELECT pronargs FROM pg_proc WHERE oid = v_oid) <> 7 THEN
    RAISE EXCEPTION 'reporte_mermas: tiene que quedar una sola sobrecarga, de 7 argumentos';
  END IF;

  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid)
     OR (SELECT proowner::regrole::text FROM pg_proc WHERE oid = v_oid) <> 'postgres' THEN
    RAISE EXCEPTION 'reporte_mermas: tiene que ser SECURITY DEFINER de postgres';
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'reporte_mermas: anon tiene EXECUTE';
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'reporte_mermas: authenticated o service_role perdio EXECUTE';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
              WHERE p.oid = v_oid AND x.grantee = 0) THEN
    RAISE EXCEPTION 'reporte_mermas: PUBLIC tiene EXECUTE';
  END IF;

  IF obj_description(v_oid, 'pg_proc') IS NULL THEN
    RAISE EXCEPTION 'reporte_mermas: se perdio el COMMENT';
  END IF;
END
$verif$;
