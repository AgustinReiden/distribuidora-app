-- Comision por defecto segun el rol del vendedor, configurable por sucursal
--
-- EL PROBLEMA
-- -----------
-- El porcentaje por defecto era `c_default numeric := 2`, una constante en el
-- cuerpo de `calcular_comisiones` (mig 150), y se aplicaba a TODO el que tuviera
-- un pedido atribuido. Como `calcular_comisiones` agrupa por `pedidos.usuario_id`
-- y no mira rol, el sistema le venia liquidando $728.960 a siete personas sin rol
-- de preventista: un encargado y seis admins que cargan pedidos como parte de su
-- trabajo, no como venta comisionable.
--
-- POR QUE NO SE RESUELVE CON SIETE REGLAS INDIVIDUALES
-- ---------------------------------------------------
-- Se puede: `comision_reglas` ya permite cargarle un % a cualquiera. Pero obliga
-- a acordarse de cargar una regla cada vez que entra alguien nuevo, y el dia que
-- nadie se acuerde el admin nuevo cobra 2% sin que nadie lo haya decidido.
-- Invertirlo hace que el caso comun salga solo: el default depende del rol, y la
-- regla individual queda para la EXCEPCION, que es para lo que sirve.
--
-- POR QUE EN `politicas_comerciales` Y NO EN UNA CONSTANTE
-- -------------------------------------------------------
-- Es lo que manda CLAUDE.md: un parametro de negocio que cambia va en
-- `politicas_comerciales`, no en el codigo. El 2 ademas ya estaba duplicado en
-- `130_reporte_gerencial_cpp.sql:228`, que es exactamente el problema que la
-- regla previene. (Ese otro 2 NO se toca aca: es la semilla de un simulador
-- editable en la pantalla del gerencial, no el numero de la liquidacion.)
--
-- EL ROL SE LEE VIVO, NO SE CONGELA EN EL PEDIDO
-- ----------------------------------------------
-- Decision tomada: si alguien pasa de encargado a preventista, sus ventas viejas
-- pasan a liquidar 2%. Es el precio de leer `perfiles.rol` en vez de guardarlo en
-- el pedido, y se acepta a cambio de no sumar una columna que habria que llenar
-- en todos los caminos de alta.
--
-- OJO: el predicado es `perfiles.rol = 'preventista'` crudo. NO `es_preventista()`,
-- que devuelve true tambien para admin y encargado (trampa 4 de CLAUDE.md) y aca
-- seria exactamente la logica equivocada aunque parezca la obvia.
--
-- EFECTO MEDIDO (los mismos $728.960, en todos los meses):
--   mes        antes       despues
--   2026-01      6.132           0
--   2026-02     59.755           0
--   2026-03    200.245     154.600
--   2026-04    507.895     425.901
--   2026-05    585.556     488.627
--   2026-06    732.243     641.024
--   2026-07    856.321     659.092
--   2026-08    926.042     804.668
--   2026-09    186.155     157.472
--   TOTAL    4.060.343   3.331.383
-- Enero y febrero van a CERO, no bajan: en esos dos meses vendian solo admins,
-- antes de que hubiera preventistas. La linea de comision desaparece entera ahi.
--
-- NO HACE FALTA BACKFILL: `calcular_comisiones` recalcula contra `pedidos.fecha`
-- en cada consulta y no hay tabla de comisiones liquidadas.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Las dos columnas
-- ---------------------------------------------------------------------------

ALTER TABLE public.politicas_comerciales
  ADD COLUMN IF NOT EXISTS comision_pct_preventista numeric(5,2) NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS comision_pct_otros       numeric(5,2) NOT NULL DEFAULT 0;

-- Los CHECK van en un DO que mira pg_constraint para que la migracion se pueda
-- reaplicar sin explotar (patron de la mig 148).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'politicas_comerciales_comision_preventista_check') THEN
    ALTER TABLE public.politicas_comerciales
      ADD CONSTRAINT politicas_comerciales_comision_preventista_check
      CHECK (comision_pct_preventista >= 0 AND comision_pct_preventista <= 100);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'politicas_comerciales_comision_otros_check') THEN
    ALTER TABLE public.politicas_comerciales
      ADD CONSTRAINT politicas_comerciales_comision_otros_check
      CHECK (comision_pct_otros >= 0 AND comision_pct_otros <= 100);
  END IF;
END $$;

COMMENT ON COLUMN public.politicas_comerciales.comision_pct_preventista IS
  'Comision por defecto de quien tiene perfiles.rol = preventista, en %. Se usa '
  'cuando NINGUNA regla de comision_reglas matchea; una regla individual '
  '(preventista_id, peso 8 en la precedencia) siempre le gana. Arranca en 2, que '
  'es el valor que estaba hardcodeado en calcular_comisiones. mig 207.';

COMMENT ON COLUMN public.politicas_comerciales.comision_pct_otros IS
  'Comision por defecto de quien NO es preventista (admin, encargado), en %. Se '
  'usa cuando ninguna regla matchea; la regla individual le gana. Arranca en 0: '
  'cargar un pedido siendo admin es parte del trabajo, no una venta comisionable. '
  'Para que un admin comisione se le carga su regla propia. mig 207.';

-- ---------------------------------------------------------------------------
-- 2. El default deja de ser una constante
--
-- MISMA FIRMA y CREATE OR REPLACE sin DROP: cambiarla dejaria dos sobrecargas
-- con rangos [obligatorios, total] superpuestos y PostgREST no sabria cual
-- llamar -> PGRST203 en runtime, invisible para tsc, eslint y los tests
-- (trampa 5 de CLAUDE.md).
--
-- Cuerpo tomado del vivo (pg_get_functiondef) y comparado contra la mig 150.
-- Cambios, y nada mas que estos:
--   . se va `c_default numeric := 2`
--   . el CTE `it` suma LEFT JOIN perfiles y arrastra el rol del vendedor
--   . `con_pct` suma LEFT JOIN politicas_comerciales y el CASE por rol
--   . la salida informa los dos porcentajes ademas de `comision_default`
-- La subconsulta de reglas NO se toca: es la que hace que la excepcion funcione.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.calcular_comisiones(
  p_desde        date,
  p_hasta        date,
  p_sucursal_ids bigint[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursales bigint[];
  v_pct_prev   numeric;
  v_pct_otros  numeric;
  v_out        jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el calculo de comisiones' USING ERRCODE = '42501';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido';
  END IF;

  -- Sin sucursales explicitas: las que el admin tiene asignadas.
  v_sucursales := COALESCE(
    p_sucursal_ids,
    ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid())
  );
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    v_sucursales := ARRAY(SELECT id FROM sucursales);
  END IF;

  -- Solo para informar en la salida: la liquidacion usa la politica de CADA
  -- pedido via el JOIN de abajo, no estos dos numeros. Con varias sucursales de
  -- politicas distintas la pantalla muestra la mas alta, que es un cartel
  -- informativo; los importes siguen siendo exactos por sucursal.
  SELECT COALESCE(MAX(pc.comision_pct_preventista), 2),
         COALESCE(MAX(pc.comision_pct_otros), 0)
    INTO v_pct_prev, v_pct_otros
    FROM politicas_comerciales pc
   WHERE pc.sucursal_id = ANY(v_sucursales);
  v_pct_prev  := COALESCE(v_pct_prev, 2);
  v_pct_otros := COALESCE(v_pct_otros, 0);

  WITH ped AS (
    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id
    FROM pedidos p
    WHERE p.estado <> 'cancelado'
      AND p.canal = 'app'
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.sucursal_id = ANY(v_sucursales)
      AND p.usuario_id IN (SELECT id FROM perfiles)
  ),
  it AS (
    SELECT ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal,
           pi.producto_id,
           pi.origen_precio,
           prod.categoria_id,
           -- Rol vivo del vendedor. `perfiles.rol` crudo y no es_preventista(),
           -- que devuelve true para admin y encargado.
           perf.rol AS rol_vendedor
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN perfiles perf ON perf.id = ped.usuario_id
    WHERE COALESCE(pi.es_bonificacion, false) = false
  ),
  con_pct AS (
    SELECT it.*,
      COALESCE((
        SELECT r.porcentaje FROM comision_reglas r
        WHERE r.activo
          AND (r.sucursal_id    IS NULL OR r.sucursal_id    = it.sucursal_id)
          AND (r.preventista_id IS NULL OR r.preventista_id = it.usuario_id)
          AND (r.origen_precio  IS NULL OR r.origen_precio  = it.origen_precio)
          AND (r.producto_id    IS NULL OR r.producto_id    = it.producto_id)
          AND (r.categoria_id   IS NULL OR r.categoria_id   = it.categoria_id)
          AND r.vigente_desde <= it.fecha
          AND (r.vigente_hasta IS NULL OR r.vigente_hasta >= it.fecha)
        ORDER BY
          (CASE WHEN r.preventista_id IS NOT NULL THEN 8 ELSE 0 END
         + CASE WHEN r.producto_id    IS NOT NULL THEN 4 ELSE 0 END
         + CASE WHEN r.categoria_id   IS NOT NULL THEN 2 ELSE 0 END
         + CASE WHEN r.origen_precio  IS NOT NULL THEN 1 ELSE 0 END) DESC,
          (r.sucursal_id IS NOT NULL) DESC,
          r.vigente_desde DESC,
          r.id DESC
        LIMIT 1
      ),
      -- El default, ahora por rol y por sucursal. El COALESCE interno cubre que
      -- a una sucursal le falte la fila de politica: cae a los valores de hoy
      -- en vez de hacer desaparecer la comision.
      CASE WHEN it.rol_vendedor = 'preventista'
           THEN COALESCE(pc.comision_pct_preventista, 2)
           ELSE COALESCE(pc.comision_pct_otros, 0)
      END) AS pct
    FROM it
    LEFT JOIN politicas_comerciales pc ON pc.sucursal_id = it.sucursal_id
  ),
  por_origen AS (
    SELECT usuario_id,
           COALESCE(origen_precio, 'sin_dato') AS origen,
           SUM(subtotal)                 AS base,
           SUM(subtotal * pct / 100.0)   AS comision,
           COUNT(*)                      AS items
    FROM con_pct
    GROUP BY usuario_id, COALESCE(origen_precio, 'sin_dato')
  ),
  por_preventista AS (
    SELECT c.usuario_id,
           COALESCE(pf.nombre, 'Sin nombre')                                  AS nombre,
           pf.email,
           SUM(c.subtotal)                                                    AS base,
           SUM(c.subtotal * c.pct / 100.0)                                    AS comision,
           COUNT(*)                                                           AS items,
           COUNT(*) FILTER (WHERE c.origen_precio IS NULL)                    AS items_sin_desglose,
           COALESCE(SUM(c.subtotal) FILTER (WHERE c.origen_precio IS NULL),0) AS base_sin_desglose
    FROM con_pct c
    LEFT JOIN perfiles pf ON pf.id = c.usuario_id
    GROUP BY c.usuario_id, pf.nombre, pf.email
  )
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    -- Se mantiene la clave vieja para no romper a quien la lea; ahora es el %
    -- de los preventistas, que es el caso mayoritario.
    'comision_default', v_pct_prev,
    'comision_pct_preventista', v_pct_prev,
    'comision_pct_otros', v_pct_otros,
    'preventistas', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'base')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'id', pp.usuario_id,
          'nombre', pp.nombre,
          'email', pp.email,
          'base', ROUND(pp.base, 2),
          'comision', ROUND(pp.comision, 2),
          'items', pp.items,
          'items_sin_desglose', pp.items_sin_desglose,
          'base_sin_desglose', ROUND(pp.base_sin_desglose, 2),
          'por_origen', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'origen', po.origen,
              'base', ROUND(po.base, 2),
              'comision', ROUND(po.comision, 2),
              'items', po.items
            ) ORDER BY po.base DESC)
            FROM por_origen po WHERE po.usuario_id = pp.usuario_id
          ), '[]'::jsonb)
        ) AS x
        FROM por_preventista pp
      ) s
    ), '[]'::jsonb),
    'totales', (
      SELECT jsonb_build_object(
        'base', COALESCE(ROUND(SUM(base), 2), 0),
        'comision', COALESCE(ROUND(SUM(comision), 2), 0),
        'items', COALESCE(SUM(items), 0),
        'items_sin_desglose', COALESCE(SUM(items_sin_desglose), 0),
        'base_sin_desglose', COALESCE(ROUND(SUM(base_sin_desglose), 2), 0)
      ) FROM por_preventista
    )
  ) INTO v_out;

  RETURN v_out;
END;
$fn$;

ALTER FUNCTION public.calcular_comisiones(date, date, bigint[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.calcular_comisiones(date, date, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.calcular_comisiones(date, date, bigint[]) TO authenticated;

COMMENT ON FUNCTION public.calcular_comisiones(date, date, bigint[]) IS
  'Comision por vendedor con desglose por origen del precio. El % sale de la '
  'regla vigente mas especifica (comision_reglas) y, si no hay ninguna, del '
  'default por ROL de politicas_comerciales: preventista o resto. Misma base '
  'que reporte_gerencial.base_comision. Migs 150 y 207.';

-- ---------------------------------------------------------------------------
-- 3. Escritura desde la pantalla de configuracion
--
-- Va por RPC y no por UPDATE directo por el mismo motivo que el monto minimo
-- (mig 204): que `actualizado_por` lo selle el servidor con auth.uid(). Si lo
-- mandara el cliente seria un dato que el cliente elige.
--
-- admin/encargado, igual que `actualizar_monto_minimo_pedido` y que la policy
-- de UPDATE de la tabla. Pedir admin-only aca daria una falsa sensacion de
-- cierre: un encargado podria hacer el UPDATE directo por PostgREST igual,
-- porque la policy de la mig 204 se lo permite. Si se quiere que solo un admin
-- toque los porcentajes, hay que apretar la RLS, no este IF.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.actualizar_comisiones_default(
  p_pct_preventista numeric,
  p_pct_otros       numeric
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $$
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

  IF p_pct_preventista IS NULL OR p_pct_preventista < 0 OR p_pct_preventista > 100 THEN
    RAISE EXCEPTION 'El porcentaje de preventista debe estar entre 0 y 100';
  END IF;
  IF p_pct_otros IS NULL OR p_pct_otros < 0 OR p_pct_otros > 100 THEN
    RAISE EXCEPTION 'El porcentaje del resto debe estar entre 0 y 100';
  END IF;

  INSERT INTO public.politicas_comerciales (
    sucursal_id, comision_pct_preventista, comision_pct_otros, actualizado_por, actualizado_en
  )
  VALUES (v_sucursal, p_pct_preventista, p_pct_otros, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET comision_pct_preventista = EXCLUDED.comision_pct_preventista,
        comision_pct_otros       = EXCLUDED.comision_pct_otros,
        actualizado_por          = EXCLUDED.actualizado_por,
        actualizado_en           = EXCLUDED.actualizado_en;

  RETURN jsonb_build_object(
    'comision_pct_preventista', p_pct_preventista,
    'comision_pct_otros', p_pct_otros
  );
END;
$$;

COMMENT ON FUNCTION public.actualizar_comisiones_default(numeric, numeric) IS
  'Fija los dos % de comision por defecto de la sucursal activa. Solo '
  'admin/encargado. mig 207.';

REVOKE ALL ON FUNCTION public.actualizar_comisiones_default(numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_comisiones_default(numeric, numeric) TO authenticated;

-- Misma verificacion de ACL que la mig 204: una funcion SECURITY DEFINER nace
-- con EXECUTE para PUBLIC y el GRANT a authenticated no lo revierte.
DO $verif$
DECLARE
  v_acl text;
  v_fn  text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['actualizar_comisiones_default', 'calcular_comisiones'] LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_acl IS NULL THEN
      RAISE EXCEPTION '% quedo con ACL default (PUBLIC ejecuta)', v_fn;
    END IF;
    IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC: %', v_fn, v_acl;
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por anon: %', v_fn, v_acl;
    END IF;
    IF v_acl NOT LIKE '%authenticated=X%' THEN
      RAISE EXCEPTION '% no quedo ejecutable por authenticated: %', v_fn, v_acl;
    END IF;
  END LOOP;
END
$verif$;

COMMIT;

-- ROLLBACK (si hiciera falta):
--   Volver a aplicar el cuerpo de calcular_comisiones de la mig 150 (con
--   c_default := 2) y despues:
--     ALTER TABLE public.politicas_comerciales
--       DROP COLUMN IF EXISTS comision_pct_preventista,
--       DROP COLUMN IF EXISTS comision_pct_otros;
--     DROP FUNCTION IF EXISTS public.actualizar_comisiones_default(numeric, numeric);
--   El orden importa: la funcion lee las columnas.
