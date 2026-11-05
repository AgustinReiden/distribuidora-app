-- 462 · El digest vuelve a contar las rendiciones sin controlar, sobre el sistema nuevo (#1455).
--
-- QUÉ PASABA
--   `bot_metricas_admin_dia.rendiciones_pendientes` contaba filas de la tabla vieja
--   `rendiciones` sin `rendiciones_control`. La 458 lo dejó en {count: 0, dias_mas_vieja: 0}
--   fijo y la 461 dropeó la tabla: la sección Rendiciones del digest no mostraba nada.
--
-- QUÉ CAMBIA
--   Una rendición sin controlar es un día (chofer, fecha) de la grilla de Rendiciones cuyo
--   estado no es 'confirmada' ni 'resuelta', o sea sin fila, 'pendiente' o 'disconformidad'
--   (el `controlada` de obtener_resumen_rendiciones). Cuenta si es de hace más de 2 días
--   argentinos, como la métrica vieja, y de los últimos 7, el rango con el que abre la
--   pantalla (VistaRendiciones): el número del digest es el que el encargado ve al entrar, y
--   lo de antes no vuelve a ser una rendición fantasma de 200 días. Por eso `dias_mas_vieja`
--   llega hasta 7, y un día sin controlar deja de avisarse a la semana (decisión del dueño,
--   05/11).
--   El esqueleto de la grilla es el de obtener_resumen_rendiciones sin las cerradas, que
--   están controladas: cobros sin adelanto de sueldo (de _rendicion_pagos, que lee la foto
--   de un día cerrado y corre al día siguiente lo vivo que cae en uno, #1248 y #1328),
--   entregas, gastos pagados con la rendición, pagos al personal y faltantes.
--   Con p_sucursal_id NULL es la Red, `_sucursales_red()`. El digest siempre manda la
--   sucursal (#1309).
--   Medido el 05/11: Taco Pozo da 3 (la más vieja de hace 7 días), Tucumán 7 y la Red 10.
--   Tucumán nunca confirmó una rendición en el sistema nuevo, y el dueño decidió contarlo
--   igual (05/11). Ningún admin tiene hoy la sección prendida.
--
-- QUÉ NO CAMBIA
--   La firma, el JSON de salida, el EXECUTE (sólo postgres y service_role) y el resto del
--   cuerpo. Ni el bot ni el front cambian: `bloqueRendiciones` ya lee count y dias_mas_vieja.
--
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: el cuerpo vivo es el que dejó la 458 (leído el 05/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(p.prosrc) INTO v_md5
    FROM pg_proc p WHERE p.oid = 'public.bot_metricas_admin_dia(date,bigint)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '71ce6341364a568ef6d67b8a8fedaa3e' THEN
    RAISE EXCEPTION 'mig 462 · bot_metricas_admin_dia cambió en prod desde que se leyó (md5 %, esperado 71ce6341364a568ef6d67b8a8fedaa3e): rehacer sobre la definición vigente',
      v_md5;
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parche por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
('public.bot_metricas_admin_dia(date,bigint)', 1,
$a$  -- #1368: contaba la tabla vieja `rendiciones`, que se dropea y desde abril sólo tenía la
  -- del 15/04. Queda en 0 hasta que se rehaga sobre el sistema nuevo (#1455).
  rendiciones_pendientes AS (
    SELECT 0::int AS count, 0::int AS dias_mas_vieja
  ),
$a$,
$r$  -- #1455: los días (chofer, fecha) de la grilla de Rendiciones sin confirmar ni resolver,
  -- de hace más de 2 días argentinos y de los últimos 7 (el rango con el que abre la
  -- pantalla). El esqueleto es el de obtener_resumen_rendiciones, sin las cerradas. Con
  -- NULL, la Red.
  rend_sucursales AS (
    SELECT s.id AS sid
      FROM unnest(CASE WHEN p_sucursal_id IS NULL THEN public._sucursales_red()
                       ELSE ARRAY[p_sucursal_id] END) AS s(id)
  ),
  rend_dias AS (
    -- #1248: los cobros salen de _rendicion_pagos, que para un día cerrado lee su foto.
    SELECT rs.sid, x.t_id, x.f
      FROM rend_sucursales rs
     CROSS JOIN LATERAL public._rendicion_pagos(rs.sid, public._tablero_hoy() - 7,
                                                public._tablero_hoy() - 3) x
     WHERE x.t_id IS NOT NULL
       AND COALESCE(x.forma_pago, '') <> 'adelanto_sueldo'
    UNION
    SELECT rs.sid, e.t_id, e.f
      FROM rend_sucursales rs
     CROSS JOIN LATERAL public._rendicion_entregas(rs.sid, public._tablero_hoy() - 7,
                                                   public._tablero_hoy() - 3) e
    UNION
    SELECT g.sucursal_id, g.rendicion_transportista_id, g.rendicion_fecha
      FROM gastos g
      JOIN rend_sucursales rs ON rs.sid = g.sucursal_id
     WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
       AND g.rendicion_fecha BETWEEN public._tablero_hoy() - 7 AND public._tablero_hoy() - 3
    UNION
    SELECT m.rendicion_sucursal_id, m.rendicion_transportista_id, m.rendicion_fecha
      FROM empleado_movimientos m
      JOIN rend_sucursales rs ON rs.sid = m.rendicion_sucursal_id
     WHERE m.tipo IN ('pago', 'faltante')
       AND m.rendicion_fecha BETWEEN public._tablero_hoy() - 7 AND public._tablero_hoy() - 3
     GROUP BY m.rendicion_sucursal_id, m.rendicion_transportista_id, m.rendicion_fecha, m.tipo
    HAVING SUM(m.monto) <> 0
  ),
  rendiciones_pendientes AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(MAX(public._tablero_hoy() - d.f), 0)::int         AS dias_mas_vieja
    FROM rend_dias d
    JOIN perfiles tr ON tr.id = d.t_id
    LEFT JOIN rendiciones_control rc
      ON  rc.fecha = d.f
      AND rc.transportista_id = d.t_id
      AND rc.sucursal_id = d.sid
    WHERE COALESCE(rc.estado, 'pendiente') NOT IN ('confirmada', 'resuelta')
  ),
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _n_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _n_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 462 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondición: el cuerpo y el EXECUTE quedaron como en el repo, y la función corre para
-- cada sucursal activa y para la Red.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r     record;
  v_sid bigint;
  v_j   json;
BEGIN
  SELECT md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def INTO r
    FROM pg_proc p WHERE p.oid = 'public.bot_metricas_admin_dia(date,bigint)'::regprocedure;
  IF r.h <> 'd4a41fccc09211dad035a82200ee3d74' OR r.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' OR NOT r.def THEN
    RAISE EXCEPTION 'bot_metricas_admin_dia no quedó como en el repo (md5 %, acl %, definer %)', r.h, r.a, r.def;
  END IF;

  FOR v_sid IN SELECT NULL::bigint UNION ALL SELECT s.id FROM sucursales s WHERE s.activa LOOP
    v_j := public.bot_metricas_admin_dia(public._tablero_hoy() - 1, v_sid);
    IF (v_j -> 'rendiciones_pendientes' ->> 'count') IS NULL
       OR (v_j -> 'rendiciones_pendientes' ->> 'dias_mas_vieja') IS NULL THEN
      RAISE EXCEPTION 'mig 462 · rendiciones_pendientes vino vacío para la sucursal %: %', v_sid, v_j -> 'rendiciones_pendientes';
    END IF;
  END LOOP;
END
$post$;

COMMIT;
