-- =========================================================================
-- mig 291 · EL RESUMEN DE COMPRAS NO MULTIPLICA POR LINEAS (#941)
--
-- `obtener_resumen_compras` sumaba y promediaba `compras.total` sobre un
-- LEFT JOIN a `compra_items`: cada compra entraba una vez por linea, asi que
-- `monto_total` (y `monto_facturas`) salian multiplicados por la cantidad de
-- items y `promedio_compra` quedaba ponderado por lineas.
--
-- Ahora el monto y el promedio salen de `compras` sola y las unidades de una
-- subconsulta aparte sobre `compra_items`. Firma, SECURITY, search_path, ACL y
-- el neto de transferencias de la 287 quedan iguales.
--
-- Hoy nada del repo ni de otra funcion la llama (por eso no se noto); se
-- arregla en vez de borrarla porque la 287 la extendio a proposito.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_resumen_compras(p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date)
 RETURNS TABLE(total_compras bigint, monto_total numeric, promedio_compra numeric, productos_comprados bigint, monto_facturas numeric, compras_transferencias numeric)
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

  -- mig 291 (#941): una fila por compra. El total y el promedio salen de
  -- `compras`; las unidades, de una subconsulta (antes un JOIN a los items
  -- repetia el total de cada compra una vez por linea).
  RETURN QUERY
  WITH c AS (
    SELECT c.id, c.total
      FROM compras c
     WHERE c.estado != 'cancelada'
       AND c.sucursal_id = current_sucursal_id()
       AND (p_fecha_desde IS NULL OR c.fecha_compra >= p_fecha_desde)
       AND (p_fecha_hasta IS NULL OR c.fecha_compra <= p_fecha_hasta)
  ),
  r AS (
    SELECT
      COUNT(*)::BIGINT                       AS total_compras,
      COALESCE(SUM(c.total), 0)::DECIMAL     AS monto_total,
      COALESCE(AVG(c.total), 0)::DECIMAL     AS promedio_compra,
      COALESCE((SELECT SUM(ci.cantidad) FROM compra_items ci
                 WHERE ci.compra_id IN (SELECT id FROM c)), 0)::BIGINT AS productos_comprados
    FROM c
  )
  SELECT r.total_compras, r.monto_total + v_transf, r.promedio_compra, r.productos_comprados,
         r.monto_total, v_transf
    FROM r;
END;
$function$;

-- -------------------------------------------------------------------------
-- Ensayo: contra un calculo independiente, sobre los datos reales de cada
-- sucursal (solo lectura; corre con un admin y su sucursal por defecto).
-- -------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_uid    uuid;
  v_suc    bigint;
  v_fallas text := '';
  r        record;
  e_n      bigint;
  e_monto  numeric;
  e_prom   numeric;
  e_unid   bigint;
  e_transf numeric;
BEGIN
  FOR v_uid, v_suc IN
    SELECT p.id, us.sucursal_id
      FROM perfiles p
      JOIN usuario_sucursales us ON us.usuario_id = p.id
     WHERE p.rol = 'admin'
     ORDER BY us.sucursal_id, p.id
  LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    SELECT count(*), COALESCE(sum(total), 0), COALESCE(avg(total), 0)
      INTO e_n, e_monto, e_prom
      FROM compras WHERE estado != 'cancelada' AND sucursal_id = v_suc;
    SELECT COALESCE(sum(ci.cantidad), 0) INTO e_unid
      FROM compra_items ci JOIN compras c ON c.id = ci.compra_id
     WHERE c.estado != 'cancelada' AND c.sucursal_id = v_suc;
    SELECT COALESCE(sum(monto), 0) INTO e_transf
      FROM compras_transferencias_netas('-infinity'::date, 'infinity'::date, ARRAY[v_suc]);

    SELECT * INTO r FROM public.obtener_resumen_compras(NULL, NULL);

    IF r.total_compras <> e_n OR r.monto_facturas <> e_monto OR r.promedio_compra <> e_prom
       OR r.productos_comprados <> e_unid OR r.compras_transferencias <> e_transf
       OR r.monto_total <> e_monto + e_transf THEN
      v_fallas := v_fallas || format(' [suc %s: obtenido n=%s monto=%s prom=%s unid=%s transf=%s; esperado n=%s monto=%s prom=%s unid=%s transf=%s]',
        v_suc, r.total_compras, r.monto_facturas, r.promedio_compra, r.productos_comprados, r.compras_transferencias,
        e_n, e_monto, e_prom, e_unid, e_transf);
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig291 · el ensayo encontro:%', v_fallas;
  END IF;
  RAISE NOTICE 'mig291 · ensayo OK';
END
$ensayo$;

COMMIT;
