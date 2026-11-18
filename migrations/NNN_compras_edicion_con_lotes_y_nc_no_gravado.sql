-- =========================================================================
-- NNN · LA EDICIÓN DE UNA COMPRA GUARDA SUS VENCIMIENTOS EN LA MISMA
--       OPERACIÓN, Y LA NOTA DE CRÉDITO DE UNA FC CON UN DESCUENTO NO GRAVADO
--       EN FACTURA NO ACREDITA DE MÁS
--       (plan #1603, ola 2, tanda 5, tarjeta C3: STK-13 de #1542 y el resto
--       de 1590-b de #1590, H5 de la revisión de B2)
--
-- Ensayo: scripts/test-compras-edicion-lotes-y-nc-ola2-1603.sql. Dos sesiones:
-- scripts/concurrencia/c3-edicion-compra-y-venta.sh. Se aplica en LF.
-- Sólo reemplaza funciones: ninguna tabla cambia y no toma locks de tabla.
--
-- =========================================================================
-- 1 · STK-13: LA EDICIÓN Y SUS LOTES, UNA SOLA TRANSACCIÓN
-- =========================================================================
-- Editar una compra eran dos llamadas: actualizar_compra_items y después
-- sincronizar_lotes_compra con la foto de los vencimientos. Si la segunda
-- fallaba (la señal, un vencimiento que no entra en la compra), la compra
-- quedaba editada y sus lotes como antes: corregida a la baja, un lote podía
-- tener más unidades que la compra. El front avisaba y ofrecía «Reintentar»
-- (#1643), pero el desparejo quedaba hasta que alguien lo hiciera.
--   · actualizar_compra_items recibe los vencimientos en `p_lotes` (la misma foto
--     que mandaba a sincronizar_lotes_compra: [{producto_id, fecha_vencimiento,
--     cantidad}], la lista vacía borra los que había) y los sincroniza al final,
--     en su misma transacción, con sincronizar_lotes_compra. Si los lotes no
--     entran, se rechaza la edición ENTERA con el motivo, y la compra, el stock y
--     los lotes quedan como estaban. La respuesta dice `lotes_sincronizados` y
--     trae el `warning_clamp` de la sincronización.
--   · El orden de locks es el de sincronizar_lotes_compra: la compra, las
--     salvedades que anotaron lotes de la compra, los productos por id y los
--     lotes por id. Con lotes, la edición toma esas salvedades antes que los
--     productos: si no, contra anular_salvedad (que toma su salvedad antes que
--     el producto) el orden se invertía.
--   · Sin `p_lotes` (un PWA de antes de esta migración) hace lo de siempre: no
--     toca los lotes, y ese PWA los manda después con sincronizar_lotes_compra,
--     que no cambia. Repetir esa llamada con la misma foto (el «Reintentar» de un
--     PWA de antes, sobre una edición que ya sincronizó) no cambia nada.
--   · La firma cambia (un parámetro más, con DEFAULT): se dropea la vieja en la
--     misma migración, para que PostgREST no vea dos (PGRST203). Un PWA de antes
--     llama con los parámetros de siempre y resuelve a la nueva.
--
-- =========================================================================
-- 2 · 1590-b (H5): EL DESCUENTO NO GRAVADO EN FACTURA DE UNA FC
-- =========================================================================
-- D16 (#1590): la devolución se valúa neta de la bonificación y de los
-- descuentos de cabecera, y nunca acredita más que lo pagado. En una FC el
-- factor (_compra_factor_neto) sólo miraba los cargos GRAVADOS en factura: una
-- FC A de 10 × 100 al 21 % con un descuento no gravado de −150 en factura
-- (pagado 1.060) acreditaba 1.210 al devolver todo. Ahora:
--   · El neto de la nota (subtotal) baja con todos los descuentos en factura,
--     gravados o no (_compra_factor_neto, para la FC igual que ya era para la ZZ).
--   · El IVA de la nota baja sólo con los gravados (_compra_factor_iva): un
--     descuento no gravado no le bajó el IVA a la factura. Es el factor que la
--     FC usaba hasta hoy para todo.
--   · El ejemplo acredita 850 de neto y 210 de IVA: 1.060, lo pagado. Sin
--     descuentos no gravados en factura los dos factores son el de hoy: nada
--     cambia para el resto de las compras.
--   · Las dos puertas: la nota por compra (registrar_nota_credito) y la nota
--     por lote de Vencimientos (registrar_nota_credito_lote). La cuenta vive en
--     una función, _compra_factor(compra, producto, sucursal, para_iva).
--   · Desde el front de hoy esa compra no se puede cargar: el front suma el
--     descuento a la cabecera «No gravado», que no puede ser negativa, y la RPC
--     la rechaza. Se llega mandándola directo (o tipeando el no gravado a mano),
--     y nace con el aviso de descuadre (COMPRA-A1 la cuenta, como siempre).
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 530.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])', '4d84f90bdb8f6c30ebcbf60aba74097c'),
    ('public.sincronizar_lotes_compra(bigint,jsonb)', 'b998975ddf3aff9038150fc583d0acdf'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)', 'b589e283f8ce0d611b1c2661890c2cfe'),
    ('public.registrar_nota_credito_lote(bigint,numeric,text,text)', '6a3b2d6a88e7cc7dc36ca1680f849888'),
    ('public._compra_factor_neto(bigint,bigint,bigint)', 'd7a38e7073d194fc170c57e08ba1144b'),
    ('public.prorratear_cargo(numeric,jsonb)', '3d96a1fb66ba9549ec72892eb5f3ed59')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regprocedure('public._compra_factor(bigint,bigint,bigint,boolean)') IS NOT NULL
     OR to_regprocedure('public._compra_factor_iva(bigint,bigint,bigint)') IS NOT NULL
     OR (SELECT count(*) FROM pg_proc
          WHERE pronamespace = 'public'::regnamespace AND proname = 'actualizar_compra_items') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · algo de esta migración ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 2 · El factor de la devolución: uno para el neto y otro para el IVA
-- =========================================================================
CREATE FUNCTION public._compra_factor(p_compra bigint, p_producto bigint, p_sucursal bigint, p_para_iva boolean)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- mig NNN (1590-b, #1590; decisión del dueño D16): lo que vale cada peso del neto de los
  -- renglones de un producto después de los descuentos de cabecera. Una devolución se valúa
  -- con esto: nunca acredita más que lo pagado. Descuentos (en negativo): sus cargos en factura
  -- negativos —en una FC, para el IVA (p_para_iva), sólo los gravados: un descuento no gravado
  -- (H5 de la revisión de B2) baja el neto de la nota pero no el IVA que se pagó— y, en una FC,
  -- la parte de `bonificaciones` que no explican sus cargos gravados, si es negativa. Un
  -- descuento con reparto (pesos) le baja el neto sólo a sus renglones, con `prorratear_cargo`
  -- (la cuenta del motor y de COMPRA-A3), prorratee o no al costo: el motor reparte por los
  -- pesos la base del IVA igual (H4-r); el resto se reparte parejo en proporción al neto (H4).
  -- Un flete no suma: el factor no pasa de 1. Los llamadores: _compra_factor_neto (el neto de
  -- la nota) y _compra_factor_iva (su IVA).
  WITH c AS (
    SELECT c.id, c.sucursal_id, c.tipo_factura, COALESCE(c.bonificaciones, 0) AS bonif
      FROM compras c
     WHERE c.id = p_compra AND c.sucursal_id = p_sucursal
  ), lin AS (
    SELECT ci.id, ci.producto_id,
           ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100) AS neto
      FROM compra_items ci
     WHERE ci.compra_id = p_compra AND ci.sucursal_id = p_sucursal
  ), descuento AS (
    SELECT cc.id, cc.monto,
           EXISTS (SELECT 1 FROM compra_cargo_repartos r WHERE r.cargo_id = cc.id AND r.peso > 0) AS repartido
      FROM compra_cargos cc
      JOIN c ON cc.compra_id = c.id AND cc.sucursal_id = c.sucursal_id
     WHERE cc.en_factura AND cc.monto < 0
       AND (c.tipo_factura = 'ZZ' OR NOT p_para_iva OR cc.condicion_iva = 'gravado')
  ), reparto AS (
    SELECT pr.item_id, SUM(pr.monto) AS monto
      FROM descuento d
     CROSS JOIN LATERAL public.prorratear_cargo(d.monto,
             (SELECT jsonb_object_agg(r.compra_item_id::text, r.peso)
                FROM compra_cargo_repartos r WHERE r.cargo_id = d.id)) pr
     WHERE d.repartido
     GROUP BY pr.item_id
  ), aj AS (
    SELECT l.producto_id, l.neto, GREATEST(l.neto + COALESCE(rp.monto, 0), 0) AS neto_rep
      FROM lin l LEFT JOIN reparto rp ON rp.item_id = l.id
  ), parejo AS (
    SELECT COALESCE((SELECT SUM(d.monto) FROM descuento d WHERE NOT d.repartido), 0)
           + CASE WHEN c.tipo_factura = 'ZZ' THEN 0
                  ELSE LEAST(c.bonif - COALESCE((SELECT SUM(cc.monto) FROM compra_cargos cc
                                                  WHERE cc.compra_id = c.id AND cc.sucursal_id = c.sucursal_id
                                                    AND cc.en_factura AND cc.condicion_iva = 'gravado'), 0), 0) END AS monto
      FROM c
  ), f AS (
    SELECT CASE WHEN t.neto_rep > 0 THEN LEAST(GREATEST(t.neto_rep + pj.monto, 0) / t.neto_rep, 1) ELSE 1 END AS f
      FROM (SELECT SUM(neto_rep) AS neto_rep FROM aj) t, parejo pj
  )
  SELECT COALESCE((SELECT CASE WHEN SUM(aj.neto) > 0 THEN LEAST(SUM(aj.neto_rep) * (SELECT f FROM f) / SUM(aj.neto), 1) END
                     FROM aj WHERE aj.producto_id = p_producto), 1);
$function$;
REVOKE ALL ON FUNCTION public._compra_factor(bigint, bigint, bigint, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._compra_factor(bigint, bigint, bigint, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public._compra_factor_neto(p_compra bigint, p_producto bigint, p_sucursal bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- mig NNN (1590-b, #1590; D16 y H5): el factor del NETO de una devolución, con todos los
  -- descuentos en factura (en una FC también los no gravados). Ver _compra_factor.
  SELECT public._compra_factor(p_compra, p_producto, p_sucursal, false);
$function$;

CREATE FUNCTION public._compra_factor_iva(p_compra bigint, p_producto bigint, p_sucursal bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- mig NNN (1590-b, #1590; H5): el factor del IVA de una devolución: en una FC, sólo los
  -- descuentos gravados le bajaron el IVA a la factura. Ver _compra_factor.
  SELECT public._compra_factor(p_compra, p_producto, p_sucursal, true);
$function$;
REVOKE ALL ON FUNCTION public._compra_factor_iva(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._compra_factor_iva(bigint, bigint, bigint) TO service_role;

-- registrar_nota_credito: el IVA de cada producto, con su factor de IVA.
DO $nc$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
    $a$ SET search_path TO 'public'
$a$,
    $n$ SET search_path TO 'public', 'pg_temp'
$n$,
    'registrar_nota_credito (search_path)');
  v_def := pg_temp.parche(v_def,
    $a$               round(round(pe.cantidad * co.neto / co.comprado * fx.f, 2)
                     * COALESCE(co.base_iva / NULLIF(co.neto, 0), 0) / 100, 2) AS iva,$a$,
    $n$               -- mig NNN (H5): el IVA con su factor; un descuento no gravado no lo bajó.
               round(round(pe.cantidad * co.neto / co.comprado * fx.fi, 2)
                     * COALESCE(co.base_iva / NULLIF(co.neto, 0), 0) / 100, 2) AS iva,$n$,
    'registrar_nota_credito (el IVA)');
  v_def := pg_temp.parche(v_def,
    $a$CROSS JOIN LATERAL (SELECT public._compra_factor_neto(p_compra_id, pe.producto_id, v_sucursal) AS f) fx$a$,
    $n$CROSS JOIN LATERAL (SELECT public._compra_factor_neto(p_compra_id, pe.producto_id, v_sucursal) AS f,
                                    public._compra_factor_iva(p_compra_id, pe.producto_id, v_sucursal) AS fi) fx$n$,
    'registrar_nota_credito (los factores)');
  EXECUTE v_def;
END
$nc$;

-- registrar_nota_credito_lote: lo mismo en la nota por lote (Vencimientos).
DO $ncl$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
    $a$ SET search_path TO 'public'
$a$,
    $n$ SET search_path TO 'public', 'pg_temp'
$n$,
    'registrar_nota_credito_lote (search_path)');
  v_def := pg_temp.parche(v_def,
    $a$  v_aviso_rep  text;     -- mig NNN (1557-b5)
$a$,
    $n$  v_aviso_rep  text;     -- mig NNN (1557-b5)
  v_costo_iva  numeric;  -- mig NNN (H5): el costo que lleva IVA
$n$,
    'registrar_nota_credito_lote (declaración)');
  v_def := pg_temp.parche(v_def,
    $a$  v_costo := v_costo * public._compra_factor_neto(v_lote.compra_id, v_lote.producto_id, v_sucursal);
$a$,
    $n$  -- mig NNN (H5): el IVA, sólo con los descuentos gravados (un no gravado no lo bajó).
  v_costo_iva := v_costo * public._compra_factor_iva(v_lote.compra_id, v_lote.producto_id, v_sucursal);
  v_costo := v_costo * public._compra_factor_neto(v_lote.compra_id, v_lote.producto_id, v_sucursal);
$n$,
    'registrar_nota_credito_lote (los factores)');
  v_def := pg_temp.parche(v_def,
    $a$  v_iva      := round(v_subtotal * v_tasa_iva / 100, 2);
$a$,
    $n$  v_iva      := round(round(v_cant * v_costo_iva, 2) * v_tasa_iva / 100, 2);  -- mig NNN (H5)
$n$,
    'registrar_nota_credito_lote (el IVA)');
  EXECUTE v_def;
END
$ncl$;

-- =========================================================================
-- 1 · actualizar_compra_items: los lotes, en la misma transacción
-- =========================================================================
DO $acu$
DECLARE
  v_def text := pg_get_functiondef(
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
    $a$p_renglones_vistos bigint[] DEFAULT NULL::bigint[])$a$,
    $n$p_renglones_vistos bigint[] DEFAULT NULL::bigint[], p_lotes jsonb DEFAULT NULL::jsonb)$n$,
    'actualizar_compra_items (firma)');
  v_def := pg_temp.parche(v_def,
    $a$ SET search_path TO 'public'
$a$,
    $n$ SET search_path TO 'public', 'pg_temp'
$n$,
    'actualizar_compra_items (search_path)');
  v_def := pg_temp.parche(v_def,
    $a$  v_fuera_de_rango   TEXT;      -- los rangos del renglon (los mismos que el alta)
$a$,
    $n$  v_fuera_de_rango   TEXT;      -- los rangos del renglon (los mismos que el alta)
  -- mig NNN (STK-13, #1542)
  v_lotes_res        JSONB;     -- lo que devolvio sincronizar_lotes_compra
$n$,
    'actualizar_compra_items (declaración)');
  v_def := pg_temp.parche(v_def,
    $a$  PERFORM set_config('app.stock_origen', 'compra_editada', true);
$a$,
    $n$  /* mig NNN (STK-13, #1542) · LOS VENCIMIENTOS VIAJAN CON LA EDICION. Eran una
     segunda llamada (sincronizar_lotes_compra) y, si fallaba, la compra quedaba
     editada con los lotes de antes: corregida a la baja, un lote con mas unidades
     que la compra. Con `p_lotes` (la foto completa, como la recibe
     sincronizar_lotes_compra) se sincronizan al final, en esta misma transaccion: si
     no entran, se rechaza la edicion entera. NULL = un PWA de antes, que los manda
     despues por separado. Las salvedades que anotaron lotes de esta compra se toman
     ACA, antes que los productos: es el orden de sincronizar_lotes_compra (compra,
     salvedades, productos, lotes), y anular_salvedad toma su salvedad antes que el
     producto. */
  IF p_lotes IS NOT NULL AND jsonb_typeof(p_lotes) <> 'array' THEN
    RAISE EXCEPTION 'p_lotes tiene que ser la lista de los vencimientos de la compra y llego %.', jsonb_typeof(p_lotes);
  END IF;
  IF p_lotes IS NOT NULL THEN
    PERFORM 1
       FROM salvedades_items s
      WHERE s.sucursal_id = v_sucursal
        AND s.estado_resolucion <> 'anulada'
        AND EXISTS (
          SELECT 1
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.lotes_devueltos) = 'array'
                                           THEN s.lotes_devueltos ELSE '[]'::JSONB END) e
            JOIN producto_lotes l ON l.id = (e->>'lote_id')::BIGINT
           WHERE l.compra_id = p_compra_id)
      ORDER BY s.id
        FOR UPDATE OF s;
  END IF;

  PERFORM set_config('app.stock_origen', 'compra_editada', true);
$n$,
    'actualizar_compra_items (las salvedades)');
  v_def := pg_temp.parche(v_def,
    $a$  RETURN jsonb_build_object(
    'success', true,
    'compra_id', p_compra_id,
$a$,
    $n$  /* mig NNN (STK-13, #1542) · los vencimientos, con las lineas y el stock ya
     editados. Un rechazo de sincronizar_lotes_compra (un vencimiento que no entra en
     la compra) cae en el EXCEPTION de abajo y deshace la edicion entera. */
  IF p_lotes IS NOT NULL THEN
    v_lotes_res := public.sincronizar_lotes_compra(p_compra_id, p_lotes);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'compra_id', p_compra_id,
$n$,
    'actualizar_compra_items (la sincronización)');
  v_def := pg_temp.parche(v_def,
    $a$    'warning_ii_declarado', v_warning_ii /* mig 194 */
  );
$a$,
    $n$    'warning_ii_declarado', v_warning_ii /* mig 194 */
  ) || CASE WHEN p_lotes IS NULL THEN '{}'::JSONB  /* mig NNN (STK-13) */
            ELSE jsonb_build_object('lotes_sincronizados', true,
                                    'warning_clamp', COALESCE(v_lotes_res->'warning_clamp', '[]'::JSONB)) END;
$n$,
    'actualizar_compra_items (la respuesta)');
  EXECUTE v_def;
END
$acu$;

DROP FUNCTION public.actualizar_compra_items(bigint, jsonb, numeric, numeric, numeric, uuid, numeric, numeric, numeric,
                                             numeric, numeric, jsonb, jsonb, numeric, bigint[]);
REVOKE ALL ON FUNCTION public.actualizar_compra_items(bigint, jsonb, numeric, numeric, numeric, uuid, numeric, numeric,
                                                      numeric, numeric, numeric, jsonb, jsonb, numeric, bigint[], jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_compra_items(bigint, jsonb, numeric, numeric, numeric, uuid, numeric, numeric,
                                                         numeric, numeric, numeric, jsonb, jsonb, numeric, bigint[], jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Poscondición
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
     'v_lotes_res := public.sincronizar_lotes_compra(p_compra_id, p_lotes);', true),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
     'FOR UPDATE OF s;', true),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
     'public._compra_factor_iva(p_compra_id, pe.producto_id, v_sucursal) AS fi', true),
    ('public.registrar_nota_credito_lote(bigint,numeric,text,text)',
     'v_iva      := round(round(v_cant * v_costo_iva, 2) * v_tasa_iva / 100, 2);', true),
    ('public._compra_factor_neto(bigint,bigint,bigint)', 'public._compra_factor(p_compra, p_producto, p_sucursal, false)', false),
    ('public._compra_factor_iva(bigint,bigint,bigint)', 'public._compra_factor(p_compra, p_producto, p_sucursal, true)', false),
    ('public._compra_factor(bigint,bigint,bigint,boolean)', 'NOT p_para_iva OR cc.condicion_iva = ''gravado''', false)
  ) AS t(f, marca, definer) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND position(r.marca in prosrc) > 0 AND prosecdef = r.definer) THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró', r.f;
    END IF;
  END LOOP;
  -- Las tres definers que se reescribieron llevan pg_temp al final del search_path (B15).
  FOR r IN SELECT unnest(ARRAY[
      'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
      'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
      'public.registrar_nota_credito_lote(bigint,numeric,text,text)']) AS f LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
      RAISE EXCEPTION 'mig NNN · % quedó sin pg_temp en su search_path', r.f;
    END IF;
  END LOOP;
  -- Una sola firma de la edición.
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'actualizar_compra_items') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · quedó más de una firma de actualizar_compra_items';
  END IF;
  -- Los permisos: la edición y las dos notas, de authenticated y no de anon; los factores, sólo de server.
  FOR r IN SELECT unnest(ARRAY[
      'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
      'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
      'public.registrar_nota_credito_lote(bigint,numeric,text,text)']) AS f LOOP
    IF NOT has_function_privilege('authenticated', r.f, 'EXECUTE') OR has_function_privilege('anon', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · los permisos de % cambiaron', r.f;
    END IF;
  END LOOP;
  FOR r IN SELECT unnest(ARRAY['public._compra_factor(bigint,bigint,bigint,boolean)',
                               'public._compra_factor_neto(bigint,bigint,bigint)',
                               'public._compra_factor_iva(bigint,bigint,bigint)']) AS f LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE') OR has_function_privilege('authenticated', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para la API', r.f;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
