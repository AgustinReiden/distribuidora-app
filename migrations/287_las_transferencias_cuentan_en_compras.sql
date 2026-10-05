-- =========================================================================
-- mig 287 · LAS TRANSFERENCIAS CUENTAN EN COMPRAS
--
-- Un movimiento aceptado entre sucursales es, para la que recibe, mercaderia
-- que entra igual que una compra; para la que envia, mercaderia comprada que
-- se fue. Hasta aca "compras" en los reportes era solo `compras` (facturas de
-- proveedores): Taco Pozo, que se abastece en buena parte desde Tucuman,
-- aparecia comprando de menos y Tucuman de mas.
--
-- Decision del dueño: la sucursal que RECIBE suma a compras y la que ENVIA
-- resta, valorizado a costo con IVA del origen × cantidad, en la FECHA DE
-- ACEPTACION. La red consolidada da neto 0.
--
--   * Valor: Σ item.cantidad × COALESCE(origen_costo_con_iva, origen_costo_sin_iva, 0),
--     el snapshot que guarda el item al crear/editar. Es exactamente
--     `movimientos_sucursal.total_costo` (verificado: en los 8 aceptados al
--     escribir esto, las dos sumas coinciden al centavo), pero se lee de los
--     items para no depender de que la cabecera este al dia.
--   * Fecha: `movimientos_sucursal.resuelto_at` de los `estado = 'aceptada'`,
--     cortado por DIA ARGENTINO (como mermas_valorizadas, 238): un envio
--     aceptado a las 23:30 del 31 es del 31. `resuelto_at` es la unica marca
--     de aceptacion que hay: aceptar la escribe junto con el estado, y un
--     aceptado no se vuelve a resolver (cancelar/denegar exigen 'pendiente').
--   * Una sola implementacion: `compras_transferencias_netas(desde, hasta,
--     sucursales[])` devuelve una fila por (movimiento, sucursal involucrada)
--     con el monto CON SIGNO (+ destino, − origen). Los consumidores suman y,
--     si quieren, agrupan por mes. Mismo molde que mermas_valorizadas.
--
-- Consumidores (posicion_fiscal NO: es fiscal, una transferencia no es una
-- factura ni genera IVA credito):
--   * reporte_gerencial: `kpis.compras` pasa a ser facturas + transferencias
--     netas, y se agregan `kpis.compras_facturas` y
--     `kpis.compras_transferencias` para el desglose. En `mensual[]`,
--     `compras` idem y se agrega `compras_transferencias`. Las claves viejas
--     siguen con el mismo nombre y tipo.
--   * bot_compras_periodo: `total_compras` = facturas + neto; se agregan
--     `compras_facturas` y `compras_transferencias`. `compras_count` y
--     `top_proveedores` siguen siendo solo facturas (son de proveedores).
--   * obtener_resumen_compras: `monto_total` = facturas + neto; columnas
--     nuevas al final `monto_facturas` y `compras_transferencias`. Cambiar el
--     RETURNS TABLE obliga a DROP + CREATE (no hay sobrecarga que conviva:
--     misma firma de entrada). Hoy no la llama ningun cliente del repo.
--
-- NO retroactivo (decision del dueño): cuentan solo los aceptados desde el
-- deploy, dia ARG >= 2026-10-05 (constante en la funcion). Los meses ya
-- cerrados no se reescriben: habia 8 envios Tucuman → Taco Pozo entre
-- 2026-06-24 y 2026-09-16 ($3.607.521,75) que siguen fuera de compras, igual
-- que en los informes mensuales ya guardados. Al escribir esto no habia
-- ninguno aceptado el 05/10 (el #18 sigue pendiente).
--
-- Permisos: la funcion nueva es SECURITY INVOKER. La llaman las tres
-- funciones DEFINER de abajo (como owner) y tambien la pantalla de Compras
-- por RPC, para leer el neto con esta misma definicion y no duplicarla en JS:
-- por eso EXECUTE a authenticated (REVOKE PUBLIC, anon). Con INVOKER rigen las
-- RLS de movimientos_sucursal / movimiento_sucursal_items (`mov_suc_select`,
-- `mov_items_select`: solo envios donde la sucursal activa es origen o
-- destino), asi que no expone nada que el usuario no pueda leer ya con un
-- SELECT directo. Parametros date/bigint[] (nunca SMALLINT, Trampa 5).
-- bot_compras_periodo y reporte_gerencial conservan ACL (CREATE OR REPLACE /
-- cirugia sobre el cuerpo vivo). obtener_resumen_compras se re-otorga a
-- authenticated.
--
-- reporte_gerencial se edita con cirugia sobre el cuerpo VIVO (patron 278/280):
-- cada ancla tiene que aparecer exactamente una vez o la migracion falla.
--
-- Numero PROVISORIO: se reserva al aplicar (ver MANIFEST).
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · compras_transferencias_netas
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compras_transferencias_netas(p_desde date, p_hasta date, p_sucursales bigint[])
 RETURNS TABLE(movimiento_id bigint, sucursal_id bigint, contraparte_id bigint, fecha_local date, sentido text, monto numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- Todo calificado: en una funcion SQL con RETURNS TABLE los nombres de salida
  -- son parametros (mismo cuidado que mermas_valorizadas).
  WITH mov AS (
    SELECT m.id,
           m.sucursal_origen_id,
           m.sucursal_destino_id,
           (m.resuelto_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS fecha_local,
           (SELECT COALESCE(SUM(i.cantidad * COALESCE(i.origen_costo_con_iva, i.origen_costo_sin_iva, 0)), 0)
              FROM public.movimiento_sucursal_items i
             WHERE i.movimiento_id = m.id) AS valor
      FROM public.movimientos_sucursal m
     WHERE m.estado = 'aceptada'
       AND m.resuelto_at IS NOT NULL
       AND (m.resuelto_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
       -- Desde el deploy (mig 287), no retroactivo: los meses cerrados no se
       -- reescriben. Los aceptados antes siguen fuera de compras.
       AND (m.resuelto_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date >= DATE '2026-10-05'
       AND (m.sucursal_origen_id = ANY(p_sucursales) OR m.sucursal_destino_id = ANY(p_sucursales))
  )
  SELECT x.movimiento_id, x.sucursal_id, x.contraparte_id, x.fecha_local, x.sentido, x.monto
    FROM (
      SELECT mov.id, mov.sucursal_destino_id, mov.sucursal_origen_id, mov.fecha_local, 'ingreso'::text, mov.valor
        FROM mov
      UNION ALL
      SELECT mov.id, mov.sucursal_origen_id, mov.sucursal_destino_id, mov.fecha_local, 'egreso'::text, -mov.valor
        FROM mov
    ) x(movimiento_id, sucursal_id, contraparte_id, fecha_local, sentido, monto)
   WHERE x.sucursal_id = ANY(p_sucursales);
$function$;

COMMENT ON FUNCTION public.compras_transferencias_netas(date, date, bigint[]) IS
  'Movimientos entre sucursales aceptados, como compras: + en el destino, - en el origen, a costo c/IVA del origen, por dia ARG de aceptacion. Unica implementacion; la consumen reporte_gerencial, bot_compras_periodo y obtener_resumen_compras. mig 287.';

REVOKE ALL ON FUNCTION public.compras_transferencias_netas(date, date, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compras_transferencias_netas(date, date, bigint[]) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 2 · reporte_gerencial (cirugia sobre el cuerpo vivo)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig287_sustituir(p_def text, p_ancla text, p_nuevo text)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_veces int;
BEGIN
  v_veces := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, left(p_ancla, 120);
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END;
$fn$;

CREATE OR REPLACE FUNCTION public._mig287_ancla(p_funcion regprocedure, p_ancla text, p_nuevo text)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  EXECUTE public._mig287_sustituir(pg_get_functiondef(p_funcion), p_ancla, p_nuevo);
END;
$fn$;

-- kpis: compras = facturas + neto de transferencias
SELECT public._mig287_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  E'  k_compra AS (SELECT COALESCE(SUM(total),0) AS compras FROM compras\n'
  || E'    WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta\n'
  || E'      AND COALESCE(estado,'''') <> ''cancelada''),\n',
  E'  -- mig 287: compras = facturas de proveedores + neto de transferencias entre\n'
  || E'  -- sucursales (aceptadas, a costo c/IVA del origen, por dia ARG de aceptacion).\n'
  || E'  -- En la Red el neto es 0 por construccion.\n'
  || E'  k_compra AS (SELECT f.compras_facturas + t.compras_transferencias AS compras,\n'
  || E'      f.compras_facturas, t.compras_transferencias\n'
  || E'    FROM (SELECT COALESCE(SUM(total),0) AS compras_facturas FROM compras\n'
  || E'      WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta\n'
  || E'        AND COALESCE(estado,'''') <> ''cancelada'') f,\n'
  || E'    (SELECT COALESCE(SUM(ct.monto),0) AS compras_transferencias\n'
  || E'       FROM public.compras_transferencias_netas(p_desde, p_hasta, v_sucursales) ct) t),\n');

-- mensual: idem por mes (mes del dia ARG de aceptacion)
SELECT public._mig287_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  E'  m_compra AS (SELECT to_char(fecha_compra,''YYYY-MM'') AS mes, SUM(total) AS compras\n'
  || E'    FROM compras WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta\n'
  || E'      AND COALESCE(estado,'''') <> ''cancelada'' GROUP BY 1),\n',
  E'  m_compra AS (SELECT mes, COALESCE(SUM(fact),0) + COALESCE(SUM(transf),0) AS compras,\n'
  || E'      COALESCE(SUM(transf),0) AS compras_transferencias FROM (\n'
  || E'      SELECT to_char(fecha_compra,''YYYY-MM'') AS mes, total AS fact, 0::numeric AS transf\n'
  || E'      FROM compras WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta\n'
  || E'        AND COALESCE(estado,'''') <> ''cancelada''\n'
  || E'      UNION ALL\n'
  || E'      SELECT to_char(ct.fecha_local,''YYYY-MM''), 0::numeric, ct.monto\n'
  || E'      FROM public.compras_transferencias_netas(p_desde, p_hasta, v_sucursales) ct\n'
  || E'    ) x GROUP BY 1),\n');

SELECT public._mig287_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  E'COALESCE(mc.compras,0) AS compras\n    FROM m_ped mp',
  E'COALESCE(mc.compras,0) AS compras,\n'
  || E'      COALESCE(mc.compras_transferencias,0) AS compras_transferencias\n    FROM m_ped mp');

SELECT public._mig287_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  '''compras'', kcp.compras,',
  E'''compras'', kcp.compras, ''compras_facturas'', kcp.compras_facturas,\n'
  || E'        ''compras_transferencias'', kcp.compras_transferencias,');

DROP FUNCTION public._mig287_ancla(regprocedure, text, text);
DROP FUNCTION public._mig287_sustituir(text, text, text);

-- -------------------------------------------------------------------------
-- 3 · bot_compras_periodo (cuerpo vivo + transferencias)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_compras_periodo(p_desde date, p_hasta date, p_sucursal_id bigint, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
BEGIN
  WITH compras_filtradas AS (
    SELECT id, proveedor_id, proveedor_nombre, total, fecha_compra
    FROM compras
    WHERE sucursal_id = p_sucursal_id
      AND fecha_compra >= p_desde AND fecha_compra <= p_hasta
      AND COALESCE(estado, '') <> 'cancelada'
  ),
  top_proveedores AS (
    SELECT cf.proveedor_id,
      COALESCE(pr.nombre, cf.proveedor_nombre, 'Sin nombre') AS nombre,
      pr.cuit, SUM(cf.total) AS total_comprado, COUNT(*) AS compras_count
    FROM compras_filtradas cf
    LEFT JOIN proveedores pr ON pr.id = cf.proveedor_id
    GROUP BY cf.proveedor_id, pr.nombre, cf.proveedor_nombre, pr.cuit
    ORDER BY SUM(cf.total) DESC LIMIT p_limit
  ),
  -- mig 287: neto de transferencias entre sucursales (+ recibido, − enviado).
  transf AS (
    SELECT COALESCE(SUM(ct.monto), 0) AS neto
    FROM public.compras_transferencias_netas(p_desde, p_hasta, ARRAY[p_sucursal_id]) ct
  )
  SELECT json_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM compras_filtradas) + (SELECT neto FROM transf),
    'compras_facturas', (SELECT COALESCE(SUM(total), 0) FROM compras_filtradas),
    'compras_transferencias', (SELECT neto FROM transf),
    'compras_count', (SELECT COUNT(*) FROM compras_filtradas),
    'top_proveedores', COALESCE((SELECT json_agg(row_to_json(tp.*)) FROM top_proveedores tp), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;

-- -------------------------------------------------------------------------
-- 4 · obtener_resumen_compras (cambia el RETURNS TABLE → DROP + CREATE)
-- -------------------------------------------------------------------------
-- La consulta de facturas es la viva, sin tocar (incluido el LEFT JOIN a
-- compra_items, que multiplica SUM/AVG(c.total) por la cantidad de lineas:
-- bug preexistente, fuera de alcance).
DROP FUNCTION public.obtener_resumen_compras(date, date);

CREATE FUNCTION public.obtener_resumen_compras(p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date)
 RETURNS TABLE(total_compras bigint, monto_total numeric, promedio_compra numeric, productos_comprados bigint,
               monto_facturas numeric, compras_transferencias numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_transf numeric;
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- mig 287: neto de transferencias de la sucursal activa en el rango
  -- (sin fechas = todo, como la consulta de facturas).
  SELECT COALESCE(SUM(ct.monto), 0) INTO v_transf
    FROM public.compras_transferencias_netas(COALESCE(p_fecha_desde, '-infinity'::date),
                                             COALESCE(p_fecha_hasta, 'infinity'::date),
                                             ARRAY[current_sucursal_id()]) ct;

  RETURN QUERY
  SELECT r.total_compras, r.monto_total + v_transf, r.promedio_compra, r.productos_comprados,
         r.monto_total, v_transf
  FROM (
    SELECT
      COUNT(DISTINCT c.id)::BIGINT as total_compras,
      COALESCE(SUM(c.total), 0)::DECIMAL as monto_total,
      COALESCE(AVG(c.total), 0)::DECIMAL as promedio_compra,
      COALESCE(SUM(ci.cantidad), 0)::BIGINT as productos_comprados
    FROM compras c
    LEFT JOIN compra_items ci ON c.id = ci.compra_id
    WHERE c.estado != 'cancelada'
      AND c.sucursal_id = current_sucursal_id()
      AND (p_fecha_desde IS NULL OR c.fecha_compra >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR c.fecha_compra <= p_fecha_hasta)
  ) r;
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_resumen_compras(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_compras(date, date) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 5 · Verificacion estatica
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text;
  v_n   integer;
BEGIN
  v_def := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  SELECT count(*) INTO v_n FROM regexp_matches(v_def, 'compras_transferencias_netas', 'g');
  IF v_n <> 2 OR v_def NOT LIKE '%''compras_transferencias'', kcp.compras_transferencias%'
     OR v_def NOT LIKE '%COALESCE(mc.compras_transferencias,0) AS compras_transferencias%' THEN
    RAISE EXCEPTION 'reporte_gerencial no quedo con las transferencias (llamadas=%)', v_n;
  END IF;
  -- posicion_fiscal no se toca: sigue sin mirar movimientos.
  IF pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure) LIKE '%movimiento%' THEN
    RAISE EXCEPTION 'posicion_fiscal no deberia mirar movimientos';
  END IF;
  IF has_function_privilege('anon', 'public.compras_transferencias_netas(date,date,bigint[])', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.compras_transferencias_netas(date,date,bigint[])', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.compras_transferencias_netas(date,date,bigint[])'::regprocedure AND prosecdef)
     OR has_function_privilege('anon', 'public.obtener_resumen_compras(date,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.obtener_resumen_compras(date,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.bot_compras_periodo(date,date,bigint,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.bot_compras_periodo(date,date,bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Permisos mal puestos en compras_transferencias_netas / obtener_resumen_compras / bot_compras_periodo';
  END IF;
END
$verif$;

-- -------------------------------------------------------------------------
-- 6 · Ensayo funcional (subtransaccion que se revierte; molde 283)
-- -------------------------------------------------------------------------
-- Admin con dos sucursales activas (O → D). Se miden reporte_gerencial (O, D
-- y Red), bot_compras_periodo (O, D) y obtener_resumen_compras (O, D) del dia
-- ARG de hoy, antes y despues de insertar:
--   * un movimiento O→D ACEPTADO hoy: 10 u. a c/IVA 121 = 1210
--   * uno PENDIENTE de 5 u. (no cuenta)
--   * uno ACEPTADO ayer a las 23:30 ARG (02:30 UTC de hoy): 500. No cuenta
--     hoy; cuenta ayer solo si ayer ya es >= 2026-10-05 (el corte)
-- Esperado: O −1210, D +1210, Red 0, facturas sin cambio; el de las 23:30
-- fuera de hoy; y todo lo aceptado en 2026 antes del 05/10 (los 8 envios
-- reales) da 0: no es retroactivo.
DO $ensayo$
DECLARE
  v_uid    uuid;
  v_o      bigint;
  v_d      bigint;
  v_obs    jsonb := '{}'::jsonb;
  v_esp    jsonb;
  v_fallas text := '';
  k        text;
BEGIN
  SELECT a.usuario_id, a.sucursal_id, b.sucursal_id INTO v_uid, v_o, v_d
    FROM usuario_sucursales a
    JOIN usuario_sucursales b ON b.usuario_id = a.usuario_id AND b.sucursal_id <> a.sucursal_id
    JOIN sucursales sa ON sa.id = a.sucursal_id AND sa.activa
    JOIN sucursales sb ON sb.id = b.sucursal_id AND sb.activa
   WHERE public._rol_en_sucursal(a.usuario_id, a.sucursal_id) = 'admin'
     AND public._rol_en_sucursal(a.usuario_id, b.sucursal_id) = 'admin'
     AND EXISTS (SELECT 1 FROM perfiles p WHERE p.id = a.usuario_id AND p.rol = 'admin')
   ORDER BY a.sucursal_id, b.sucursal_id, a.usuario_id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig287: no hay un admin con dos sucursales activas; el ensayo no puede correr.';
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

    DECLARE
      v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
      v_prod bigint;
      v_m bigint; v_mp bigint; v_my bigint;
      a_o jsonb; a_d jsonb; a_red jsonb; b_o json; b_d json; r_o record; r_d record;
      d_o jsonb; d_d jsonb; d_red jsonb; e_o json; e_d json; s_o record; s_d record;
    BEGIN
      SELECT id INTO v_prod FROM productos WHERE sucursal_id = v_o ORDER BY id LIMIT 1;

      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_o::text)::text, true);
      a_o   := public.reporte_gerencial(v_o, v_hoy, v_hoy, false, false)->'kpis';
      a_d   := public.reporte_gerencial(v_d, v_hoy, v_hoy, false, false)->'kpis';
      a_red := public.reporte_gerencial(NULL, v_hoy, v_hoy, false, false)->'kpis';
      b_o   := public.bot_compras_periodo(v_hoy, v_hoy, v_o, 10);
      b_d   := public.bot_compras_periodo(v_hoy, v_hoy, v_d, 10);
      SELECT * INTO r_o FROM public.obtener_resumen_compras(v_hoy, v_hoy);
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_d::text)::text, true);
      SELECT * INTO r_d FROM public.obtener_resumen_compras(v_hoy, v_hoy);

      INSERT INTO movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, estado, creado_por, stock_descontado,
                                        resuelto_por, resuelto_at, total_costo, total_unidades)
        VALUES (v_o, v_d, 'aceptada', v_uid, true, v_uid, now(), 1210, 10) RETURNING id INTO v_m;
      INSERT INTO movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre, origen_costo_con_iva, origen_costo_sin_iva)
        VALUES (v_m, v_prod, 10, 'ZZ mig287', 121, 100);
      INSERT INTO movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, estado, creado_por, stock_descontado, total_costo, total_unidades)
        VALUES (v_o, v_d, 'pendiente', v_uid, true, 605, 5) RETURNING id INTO v_mp;
      INSERT INTO movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre, origen_costo_con_iva)
        VALUES (v_mp, v_prod, 5, 'ZZ mig287 pend', 121);
      INSERT INTO movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, estado, creado_por, stock_descontado,
                                        resuelto_por, resuelto_at, total_costo, total_unidades)
        VALUES (v_o, v_d, 'aceptada', v_uid, true, v_uid,
                ((v_hoy - 1) + time '23:30') AT TIME ZONE 'America/Argentina/Buenos_Aires', 500, 5)
        RETURNING id INTO v_my;
      INSERT INTO movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre, origen_costo_con_iva)
        VALUES (v_my, v_prod, 5, 'ZZ mig287 ayer', 100);

      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_o::text)::text, true);
      d_o   := public.reporte_gerencial(v_o, v_hoy, v_hoy, false, false)->'kpis';
      d_d   := public.reporte_gerencial(v_d, v_hoy, v_hoy, false, false)->'kpis';
      d_red := public.reporte_gerencial(NULL, v_hoy, v_hoy, false, false)->'kpis';
      e_o   := public.bot_compras_periodo(v_hoy, v_hoy, v_o, 10);
      e_d   := public.bot_compras_periodo(v_hoy, v_hoy, v_d, 10);
      SELECT * INTO s_o FROM public.obtener_resumen_compras(v_hoy, v_hoy);
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_d::text)::text, true);
      SELECT * INTO s_d FROM public.obtener_resumen_compras(v_hoy, v_hoy);

      v_obs := jsonb_build_object(
        'rg_o_compras',  (d_o->>'compras')::numeric - (a_o->>'compras')::numeric,
        'rg_o_transf',   (d_o->>'compras_transferencias')::numeric - (a_o->>'compras_transferencias')::numeric,
        'rg_o_facturas', (d_o->>'compras_facturas')::numeric - (a_o->>'compras_facturas')::numeric,
        'rg_d_compras',  (d_d->>'compras')::numeric - (a_d->>'compras')::numeric,
        'rg_d_transf',   (d_d->>'compras_transferencias')::numeric - (a_d->>'compras_transferencias')::numeric,
        'rg_red_compras', (d_red->>'compras')::numeric - (a_red->>'compras')::numeric,
        'rg_red_transf',  (d_red->>'compras_transferencias')::numeric,
        'rg_cierra_o',   (d_o->>'compras')::numeric = (d_o->>'compras_facturas')::numeric + (d_o->>'compras_transferencias')::numeric,
        'bot_o', (e_o->>'total_compras')::numeric - (b_o->>'total_compras')::numeric,
        'bot_d', (e_d->>'total_compras')::numeric - (b_d->>'total_compras')::numeric,
        'bot_d_transf', (e_d->>'compras_transferencias')::numeric - (b_d->>'compras_transferencias')::numeric,
        'res_o', s_o.monto_total - r_o.monto_total,
        'res_d', s_d.monto_total - r_d.monto_total,
        'res_o_fact', s_o.monto_facturas - r_o.monto_facturas,
        'ayer_d', (SELECT COALESCE(SUM(ct.monto), 0) FROM public.compras_transferencias_netas(v_hoy - 1, v_hoy - 1, ARRAY[v_d]) ct
                    WHERE ct.movimiento_id = v_my),
        'historico_previo', (SELECT count(*) FROM public.compras_transferencias_netas(DATE '2026-01-01', DATE '2026-10-04', ARRAY[v_o, v_d]) ct),
        'ayer_esperado', CASE WHEN v_hoy - 1 >= DATE '2026-10-05' THEN 500 ELSE 0 END,
        'hoy_sin_ayer', NOT EXISTS (SELECT 1 FROM public.compras_transferencias_netas(v_hoy, v_hoy, ARRAY[v_o, v_d]) ct
                                     WHERE ct.movimiento_id IN (v_my, v_mp)),
        'filas_m', (SELECT string_agg(ct.sucursal_id || ':' || ct.sentido || ':' || round(ct.monto), ',' ORDER BY ct.monto)
                      FROM public.compras_transferencias_netas(v_hoy, v_hoy, ARRAY[v_o, v_d]) ct
                     WHERE ct.movimiento_id = v_m),
        'filas_esperadas', v_o || ':egreso:-1210,' || v_d || ':ingreso:1210');
    END;

    RAISE EXCEPTION 'mig287_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig287_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig287 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  v_esp := jsonb_build_object(
    'rg_o_compras', -1210, 'rg_o_transf', -1210, 'rg_o_facturas', 0,
    'rg_d_compras', 1210,  'rg_d_transf', 1210,
    'rg_red_compras', 0,   'rg_red_transf', 0, 'rg_cierra_o', true,
    'bot_o', -1210, 'bot_d', 1210, 'bot_d_transf', 1210,
    'res_o', -1210, 'res_d', 1210, 'res_o_fact', 0,
    'ayer_d', v_obs->'ayer_esperado', 'hoy_sin_ayer', true, 'historico_previo', 0,
    'filas_m', v_obs->'filas_esperadas');

  FOR k IN SELECT jsonb_object_keys(v_esp) LOOP
    IF (v_obs->k) IS DISTINCT FROM (v_esp->k) THEN
      v_fallas := v_fallas || format(' [%s: esperado %s, obtenido %s]', k, v_esp->k, COALESCE(v_obs->k, 'null'::jsonb));
    END IF;
  END LOOP;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig287 · el ensayo funcional encontro:% · observado=%', v_fallas, v_obs;
  END IF;

  PERFORM set_config('mig287.ensayo', v_obs::text, true);
  RAISE NOTICE 'mig287 · ensayo funcional OK: %', v_obs;
END
$ensayo$;

COMMIT;
