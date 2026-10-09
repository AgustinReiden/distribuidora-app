-- =============================================================================
-- 321 · El ritmo de compra no tarda 8 segundos
-- =============================================================================
--
-- `clientes_ritmo_compra` (mig 308, con el vale blanco de la 319) tardaba 8 a
-- 10 segundos para una sucursal entera vista como admin, en el borde del
-- statement_timeout de la API. Lo encontró la evaluación de modelos (#979): la
-- primera llamada por PostgREST se cortó con "canceling statement due to
-- statement timeout".
--
-- Afectaba en prod a todo lo que la consume con la sucursal entera:
--   * clientes_atrasados / /atrasados de un admin o encargado;
--   * bot_riesgo_por_preventista, la seccion del resumen del admin (la llama
--     2 + N veces y quedaba vacia: es best-effort y no falla visible).
-- La cartera de un preventista tardaba ~1 s, y las pruebas de la 308 (con
-- valores literales, que usan un plan especifico) no lo vieron.
--
-- Causa: dentro de una funcion el plan es GENERICO. Con parametros, Postgres
-- inlinea el CTE `med` y lo mete en un nested loop contra `fechas`: recalcula
-- la mediana de todos los clientes una vez por cada fecha de compra (4.650
-- veces). Medido con `prepare` + `plan_cache_mode = force_generic_plan`:
-- 10,5 s antes, 0,26 s con `med`, `ritmo` y `montos` como MATERIALIZED.
--
-- El cuerpo es el VIGENTE en prod (308 + el vale blanco de la 319), sin otro
-- cambio que los tres MATERIALIZED. La premisa de abajo lo garantiza: si otra
-- sesion cambio la funcion despues de copiarla, la migracion no corre (un
-- CREATE OR REPLACE sobre un cuerpo viejo revierte ese cambio en silencio; ya
-- casi pasa con la 319). El ensayo compara fila por fila antes y despues.
-- =============================================================================

BEGIN;

-- 0 · Premisa: el cuerpo copiado es el que esta en prod (md5 del 2026-10-08).
DO $premisa$
DECLARE
  v_md5 text := (SELECT md5(prosrc) FROM pg_proc
                  WHERE oid = 'public.clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)'::regprocedure);
BEGIN
  IF v_md5 <> 'e972342e7c136c39fda987441a75a588' THEN
    RAISE EXCEPTION '321 · clientes_ritmo_compra cambio en prod desde que se copio (md5 %): rehacer la copia sobre la definicion vigente', v_md5;
  END IF;
END
$premisa$;

-- El resultado de la version vigente, para comparar despues.
CREATE TEMP TABLE _ritmo_antes ON COMMIT DROP AS
SELECT s.id AS sucursal_id, r.*
  FROM sucursales s, clientes_ritmo_compra(s.id, 'admin', NULL, NULL) r
 WHERE s.activa;

CREATE OR REPLACE FUNCTION public.clientes_ritmo_compra(p_sucursal_id bigint, p_rol text, p_perfil_id uuid, p_preventista_id uuid DEFAULT NULL::uuid, p_cliente_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(cliente_id bigint, codigo integer, nombre text, zona text, es_comodin boolean, saldo numeric, ultima_compra date, dias_sin_comprar integer, entregas_365 integer, frecuencia_dias numeric, ratio numeric, estado text, monto_mensual numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH params AS (
    SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS hoy,
           CASE WHEN p_rol IN ('admin', 'encargado') THEN p_preventista_id
                ELSE p_perfil_id END AS prev,
           p_rol NOT IN ('admin', 'encargado') AS solo_propio
  ),
  universo AS (
    SELECT c.id, c.codigo,
           COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), NULLIF(btrim(c.razon_social), ''), '(sin nombre)') AS nombre,
           -- La zona como la muestra la app (reporte_ventas_por_cliente): la de
           -- la tabla zonas, y el texto viejo sólo si no hay zona asignada.
           COALESCE(z.nombre, NULLIF(btrim(c.zona), ''), 'SIN ZONA') AS zona,
           c.es_comodin, c.saldo_cuenta
      FROM clientes c
      LEFT JOIN zonas z ON z.id = c.zona_id
      CROSS JOIN params pr
     WHERE c.sucursal_id = p_sucursal_id
       AND c.activo
       -- 3XD (N17): un cliente de consumo interno (vale blanco) no tiene ritmo
       -- de compra: no es atrasado ni perdido, no es cartera de nadie.
       AND c.tipo_factura_default <> 'VB'
       AND (p_cliente_id IS NULL OR c.id = p_cliente_id)
       AND (
             -- Toda la sucursal: solo admin/encargado sin filtro de preventista.
             (pr.prev IS NULL AND NOT pr.solo_propio)
             OR (pr.prev IS NOT NULL AND (
                  EXISTS (SELECT 1 FROM cliente_preventistas cp
                           WHERE cp.cliente_id = c.id AND cp.preventista_id = pr.prev)
                  OR (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
                      AND EXISTS (SELECT 1 FROM pedidos pe
                                   WHERE pe.cliente_id = c.id AND pe.usuario_id = pr.prev
                                     AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
                                     AND pe.tipo_factura IS DISTINCT FROM 'VB'
                                     AND pe.fecha >= pr.hoy - 179))
                ))
           )
       -- Reservado a administracion: fuera de la cartera de un preventista,
       -- salvo que ya le haya vendido (mig 214).
       AND (NOT c.reservado_admin OR pr.prev IS NULL
            OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = pr.prev))
  ),
  ventas AS (
    SELECT pe.cliente_id, pe.fecha, pe.total, pe.usuario_id
      FROM pedidos pe JOIN universo u ON u.id = pe.cliente_id, params pr
     WHERE pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND pe.tipo_factura IS DISTINCT FROM 'VB'
       AND pe.fecha >= pr.hoy - 364
  ),
  fechas AS (
    SELECT DISTINCT cliente_id, fecha FROM ventas
  ),
  gaps AS (
    SELECT cliente_id, (fecha - LAG(fecha) OVER (PARTITION BY cliente_id ORDER BY fecha)) AS gap
      FROM fechas
  ),
  -- Agrupado y no una subconsulta correlacionada: con 600 clientes la
  -- correlacionada recorria todas las fechas por cliente (255 ms contra 20).
  -- MATERIALIZED (mig 321): dentro de la funcion el plan es generico, y sin
  -- esto Postgres metia `med` en un nested loop y la recalculaba una vez por
  -- cada fecha de compra: 8 a 10 s para una sucursal, el techo del
  -- statement_timeout. Con las tres materializadas, 0,26 s.
  med AS MATERIALIZED (
    SELECT cliente_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY gap)::numeric AS frecuencia
      FROM gaps WHERE gap IS NOT NULL GROUP BY cliente_id
  ),
  ritmo AS MATERIALIZED (
    SELECT f.cliente_id,
           MAX(f.fecha) AS ultima,
           -- Dias distintos con entrega, no pedidos: dos pedidos el mismo dia son una visita.
           COUNT(*)::int AS entregas,
           MAX(m.frecuencia) AS frecuencia
      FROM fechas f LEFT JOIN med m ON m.cliente_id = f.cliente_id
     GROUP BY f.cliente_id
  ),
  montos AS MATERIALIZED (
    SELECT v.cliente_id, SUM(v.total) / 6 AS mensual
      FROM ventas v, params pr
     WHERE v.fecha >= pr.hoy - 179
       AND (NOT pr.solo_propio OR v.usuario_id = p_perfil_id)
     GROUP BY v.cliente_id
  )
  SELECT u.id, u.codigo, u.nombre, u.zona, u.es_comodin, u.saldo_cuenta,
         r.ultima,
         (pr.hoy - r.ultima)::int,
         COALESCE(r.entregas, 0),
         ROUND(r.frecuencia, 1),
         CASE WHEN r.frecuencia > 0 THEN ROUND((pr.hoy - r.ultima) / r.frecuencia, 2) END,
         CASE
           WHEN r.ultima IS NULL THEN 'sin_compras'
           WHEN pr.hoy - r.ultima > 180 THEN 'perdido'
           WHEN pr.hoy - r.ultima > 90 THEN 'inactivo'
           WHEN r.entregas < 3 OR r.frecuencia IS NULL OR r.frecuencia = 0 THEN
             CASE WHEN pr.hoy - r.ultima >= 45 THEN 'ocasional' ELSE 'al_dia' END
           WHEN pr.hoy - r.ultima >= GREATEST(2 * r.frecuencia, 14) THEN 'atrasado'
           WHEN pr.hoy - r.ultima >= GREATEST(1.5 * r.frecuencia, 7) THEN 'por_vencer'
           ELSE 'al_dia'
         END,
         ROUND(COALESCE(m.mensual, 0), 2)
    FROM universo u
    CROSS JOIN params pr
    LEFT JOIN ritmo r  ON r.cliente_id = u.id
    LEFT JOIN montos m ON m.cliente_id = u.id;
$function$;

COMMENT ON FUNCTION public.clientes_ritmo_compra(BIGINT, TEXT, UUID, UUID, BIGINT) IS
  'Ritmo de compra de cada cliente contra su propia frecuencia (migs 308, 319 y 321). Unica definicion de "atrasado": la consumen las herramientas del bot y sus digests.';

-- CREATE OR REPLACE conserva los permisos; se reafirman igual (server-only).
REVOKE EXECUTE ON FUNCTION public.clientes_ritmo_compra(BIGINT, TEXT, UUID, UUID, BIGINT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.clientes_ritmo_compra(BIGINT, TEXT, UUID, UUID, BIGINT) TO service_role;


DO $ensayo$
DECLARE
  s       RECORD;
  v_t0    timestamptz;
  v_ms    numeric;
  v_dif   bigint;
BEGIN
  -- 1. Mismo resultado que antes, fila por fila, en todas las sucursales.
  SELECT count(*) INTO v_dif FROM (
    (SELECT * FROM _ritmo_antes
     EXCEPT
     SELECT su.id, r.* FROM sucursales su, clientes_ritmo_compra(su.id, 'admin', NULL, NULL) r WHERE su.activa)
    UNION ALL
    (SELECT su.id, r.* FROM sucursales su, clientes_ritmo_compra(su.id, 'admin', NULL, NULL) r WHERE su.activa
     EXCEPT
     SELECT * FROM _ritmo_antes)
  ) d;
  IF v_dif <> 0 THEN
    RAISE EXCEPTION 'ensayo 321: el resultado cambio en % filas', v_dif;
  END IF;

  -- 2. Rapida con el plan generico, que es el que usa la funcion por PostgREST.
  SET LOCAL plan_cache_mode = force_generic_plan;
  FOR s IN SELECT id FROM sucursales WHERE activa LOOP
    v_t0 := clock_timestamp();
    PERFORM count(*) FROM clientes_ritmo_compra(s.id, 'admin', NULL, NULL);
    v_ms := EXTRACT(EPOCH FROM clock_timestamp() - v_t0) * 1000;
    IF v_ms > 3000 THEN
      RAISE EXCEPTION 'ensayo 321: la sucursal % tarda % ms', s.id, round(v_ms);
    END IF;
    v_t0 := clock_timestamp();
    PERFORM bot_riesgo_por_preventista(s.id);
    v_ms := EXTRACT(EPOCH FROM clock_timestamp() - v_t0) * 1000;
    IF v_ms > 6000 THEN
      RAISE EXCEPTION 'ensayo 321: el riesgo de la sucursal % tarda % ms', s.id, round(v_ms);
    END IF;
  END LOOP;

  RAISE NOTICE 'ensayo 321: mismo resultado y bajo 3 s';
END;
$ensayo$;

COMMIT;
