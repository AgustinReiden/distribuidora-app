-- =========================================================================
-- NNN · LA EDICIÓN DE UNA COMPRA GUARDA SUS VENCIMIENTOS EN LA MISMA
--       OPERACIÓN, Y LA NOTA DE CRÉDITO DE UNA FC CON UN DESCUENTO NO GRAVADO
--       EN FACTURA NO ACREDITA DE MÁS
--       (plan #1603, ola 2, tanda 5, tarjeta C3: STK-13 de #1542 y el resto
--       de 1590-b de #1590, H5 de la revisión de B2)
--
-- Ensayo: scripts/test-compras-edicion-lotes-y-nc-ola2-1603.sql. Dos sesiones:
-- scripts/concurrencia/c3-edicion-compra-y-venta.sh. Se aplica en LF.
-- Toma un lock de tabla: `LOCK TABLE compras ACCESS EXCLUSIVE NOWAIT` al principio, por el CHECK de
-- la sección 4 (o lo consigue al instante o falla y se reintenta). Crea una tabla sólo de server (la
-- del recálculo de la sección 5, con dos funciones sólo de server que lo hacen) y un trigger en
-- productos (sección 6). Se aplica sobre la 533 (o la 531 y la 532: los cuerpos que parcha son los mismos).
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
--   · Un descuento no gravado sólo puede caer sobre renglones no gravados (y uno
--     exento sobre exentos): la sección 4 le pone ese tope, así que «devolver todo»
--     cierra contra lo pagado.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La sección 4 cambia un CHECK de compras, y la 5 y la 6 escriben productos y le crean un
-- trigger: los locks de las dos tablas, primero, en el orden de la compra (compras, después
-- productos) y sin esperar. Productos en SHARE ROW EXCLUSIVE: alcanza para el trigger y el
-- recálculo, y deja leer el catálogo mientras tanto (frena las escrituras, segundos).
LOCK TABLE public.compras IN ACCESS EXCLUSIVE MODE NOWAIT;
LOCK TABLE public.productos IN SHARE ROW EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 533 (los mismos md5 que la 530, la 531 y la 532).
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
    ('public.prorratear_cargo(numeric,jsonb)', '3d96a1fb66ba9549ec72892eb5f3ed59'),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)', '9f1c391db98056da0d89de7d16a3e171'),
    ('public._reposicion_desde_ultima_compra(bigint,bigint)', '322d0edf2363c1ccf22785a1f8f54200'),
    ('public.costo_real_unitario(numeric,numeric,text,numeric)', 'ce489a035552349e45549cf70bca4c23'),
    ('public.costo_financiero_unitario(numeric,numeric,numeric,text)', NULL),
    ('public._tipo_compra_producto(text,text)', NULL),
    ('public._cpp_fija_costo(numeric,numeric,numeric)', NULL),
    ('public._compra_producto_devuelto(bigint,bigint,bigint)', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    IF r.h IS NULL THEN CONTINUE; END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regprocedure('public._compra_factor(bigint,bigint,bigint,boolean)') IS NOT NULL
     OR to_regprocedure('public._compra_factor_iva(bigint,bigint,bigint)') IS NOT NULL
     OR to_regprocedure('public._compra_iva_cargos(jsonb,jsonb)') IS NOT NULL
     OR to_regprocedure('public._compra_iva_cargos_de_linea(bigint)') IS NOT NULL
     OR to_regprocedure('public._costo_con_iva_unitario(numeric,numeric,numeric,boolean,numeric)') IS NOT NULL
     OR to_regprocedure('public._compra_descuento_fuera_de_tope(jsonb,jsonb,boolean)') IS NOT NULL
     OR to_regprocedure('public.productos_componer_costo_con_iva()') IS NOT NULL
     OR to_regprocedure('public._costo_con_iva_candidatos(bigint[])') IS NOT NULL
     OR to_regprocedure('public._recalcular_costo_con_iva(bigint[])') IS NOT NULL
     OR to_regclass('public.costo_con_iva_recalculos') IS NOT NULL
     OR (SELECT count(*) FROM pg_proc
          WHERE pronamespace = 'public'::regnamespace AND proname = 'actualizar_compra_items') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · algo de esta migración ya existe: revisar a mano';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure
                  AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
    RAISE EXCEPTION 'mig NNN · la base no está en la 531 (search_path sin pg_temp): aplicar sobre la 531';
  END IF;
  -- El CHECK de la cabecera de compras es el de la 530 (la sección 4 lo afloja en no_gravado).
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conname = 'compras_importes_validos' AND conrelid = 'public.compras'::regclass)
     IS DISTINCT FROM 'CHECK (((subtotal >= (0)::numeric) AND (subtotal <> ''NaN''::numeric) AND (iva >= (0)::numeric) AND (iva <> ''NaN''::numeric) AND (otros_impuestos >= (0)::numeric) AND (otros_impuestos <> ''NaN''::numeric) AND (impuestos_internos >= (0)::numeric) AND (impuestos_internos <> ''NaN''::numeric) AND (percepcion_iva >= (0)::numeric) AND (percepcion_iva <> ''NaN''::numeric) AND (percepcion_iibb >= (0)::numeric) AND (percepcion_iibb <> ''NaN''::numeric) AND (no_gravado >= (0)::numeric) AND (no_gravado <> ''NaN''::numeric) AND (total >= (0)::numeric) AND (total <> ''NaN''::numeric) AND (bonificaciones <> ''NaN''::numeric)))' THEN
    RAISE EXCEPTION 'mig NNN · compras_importes_validos no es el de la 530: rehacer la sección 4 sobre lo vigente';
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- mig NNN (1590-b, #1590; D16 y H5): el factor del NETO de una devolución, con todos los
  -- descuentos en factura (en una FC también los no gravados). Ver _compra_factor.
  SELECT public._compra_factor(p_compra, p_producto, p_sucursal, false);
$function$;

CREATE FUNCTION public._compra_factor_iva(p_compra bigint, p_producto bigint, p_sucursal bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
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
-- 3 · 1593-b1: el costo con IVA es el neto más el IVA de sus componentes
-- =========================================================================
-- El IVA de los cargos que entran al costo, por renglón: {id del renglón: IVA}. El reparto es
-- el de costo_real (prorratear_cargo sobre los pesos del cargo, que ya vienen entre los
-- renglones pagados). Un cargo gravado en factura lleva la alícuota del renglón en el que cae
-- (como la base de IVA del motor: en un renglón exento o no gravado, 0); uno fuera de la
-- factura con el comprobante de un tercero, su IVA cargado (iva_monto) en proporción; el
-- resto (no gravado, exento, o gravado sin IVA cargado), 0. Sólo los que prorratean al costo.
CREATE FUNCTION public._compra_iva_cargos(p_items jsonb, p_cargos jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(jsonb_object_agg(t.item_id::text, t.iva), '{}'::jsonb)
    FROM (
      SELECT r.item_id,
             SUM(r.monto * CASE
               WHEN COALESCE(c.val->>'condicion_iva', 'no_gravado') = 'gravado'
                    AND COALESCE(NULLIF(c.val->'en_factura', 'null'::jsonb), 'true'::jsonb) = 'true'::jsonb
                 THEN CASE WHEN COALESCE(i.val->>'condicion_iva', 'gravado') = 'gravado'
                           THEN COALESCE((i.val->>'porcentaje_iva')::numeric, 0) / 100 ELSE 0 END
               WHEN COALESCE(NULLIF(c.val->'comprobante_tercero', 'null'::jsonb), 'false'::jsonb) = 'true'::jsonb
                    AND COALESCE((c.val->>'monto')::numeric, 0) <> 0
                 THEN COALESCE((c.val->>'iva_monto')::numeric, 0) / abs((c.val->>'monto')::numeric)
               ELSE 0 END) AS iva
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_cargos) = 'array' THEN p_cargos ELSE '[]'::jsonb END) AS c(val)
       CROSS JOIN LATERAL public.prorratear_cargo(COALESCE((c.val->>'monto')::numeric, 0),
                                                  COALESCE(NULLIF(c.val->'pesos', 'null'::jsonb), '{}'::jsonb)) r
        JOIN jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END) AS i(val)
          ON (i.val->>'id')::bigint = r.item_id
       WHERE COALESCE(NULLIF(c.val->'prorratea_al_costo', 'null'::jsonb), 'true'::jsonb) = 'true'::jsonb
       GROUP BY r.item_id
    ) t;
$function$;
REVOKE ALL ON FUNCTION public._compra_iva_cargos(jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._compra_iva_cargos(jsonb, jsonb) TO service_role;

-- Lo mismo leído de las filas de una compra guardada, por unidad del renglón: la reposición
-- recalcula desde acá, con la misma cuenta que el alta. Un renglón sin alícuota guardada (de antes
-- de la 113) toma la del producto, como el IVA del producto en la reposición (N3 de la revisión).
CREATE FUNCTION public._compra_iva_cargos_de_linea(p_item bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH l AS (
    SELECT ci.id, ci.compra_id, ci.sucursal_id, ci.cantidad FROM compra_items ci WHERE ci.id = p_item
  ), items AS (
    SELECT jsonb_agg(jsonb_build_object('id', ci.id, 'porcentaje_iva', COALESCE(ci.porcentaje_iva, pr.porcentaje_iva),
                                        'condicion_iva', ci.condicion_iva)) AS j
      FROM compra_items ci JOIN l ON ci.compra_id = l.compra_id AND ci.sucursal_id = l.sucursal_id
      LEFT JOIN productos pr ON pr.id = ci.producto_id AND pr.sucursal_id = ci.sucursal_id
  ), cargos AS (
    SELECT jsonb_agg(jsonb_build_object(
             'monto', cc.monto, 'condicion_iva', cc.condicion_iva, 'en_factura', cc.en_factura,
             'prorratea_al_costo', cc.prorratea_al_costo, 'comprobante_tercero', cc.comprobante_tercero,
             'iva_monto', cc.iva_monto,
             'pesos', COALESCE((SELECT jsonb_object_agg(r.compra_item_id::text, r.peso)
                                  FROM compra_cargo_repartos r WHERE r.cargo_id = cc.id), '{}'::jsonb))) AS j
      FROM compra_cargos cc JOIN l ON cc.compra_id = l.compra_id AND cc.sucursal_id = l.sucursal_id
  )
  SELECT CASE WHEN l.cantidad > 0
              THEN COALESCE((public._compra_iva_cargos(items.j, cargos.j)->>l.id::text)::numeric, 0) / l.cantidad
              ELSE 0 END
    FROM l, items, cargos;
$function$;
REVOKE ALL ON FUNCTION public._compra_iva_cargos_de_linea(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._compra_iva_cargos_de_linea(bigint) TO service_role;

-- El costo con IVA por unidad (decisión del dueño, 19/11): el costo neto (costo_real: neto del
-- producto + impuestos internos + cargos netos + flete neto) más el IVA de cada componente
-- que lo lleva: el del producto a su alícuota y el de los cargos (p_iva_cargos, por unidad).
-- Sin crédito fiscal (ZZ, FC B o C) lo pagado ya trae el IVA del producto y de sus cargos en
-- factura (el motor los ve a alícuota 0): se suma sólo el IVA que trae un cargo de un tercero
-- (H1 de la revisión: ZZ de 10 × 100 con un flete de un tercero de 100 + 21 da 112,10).
CREATE FUNCTION public._costo_con_iva_unitario(p_costo_real numeric, p_neto numeric, p_pct_iva numeric,
                                               p_sin_credito boolean, p_iva_cargos numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN p_sin_credito THEN round(p_costo_real + COALESCE(p_iva_cargos, 0), 4)
              ELSE round(p_costo_real + COALESCE(p_neto, 0) * COALESCE(p_pct_iva, 0) / 100
                         + COALESCE(p_iva_cargos, 0), 4) END;
$function$;
REVOKE ALL ON FUNCTION public._costo_con_iva_unitario(numeric, numeric, numeric, boolean, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._costo_con_iva_unitario(numeric, numeric, numeric, boolean, numeric) TO service_role;

-- H5 de la revisión: el tope de un descuento no gravado o exento de la factura. En una FC con
-- crédito fiscal, un descuento no gravado no pasa de lo que suman los renglones no gravados, y
-- uno exento, de los exentos: un descuento sobre renglones gravados va como bonificación gravada
-- (baja el neto y su IVA). Sin el tope, una FC A de 10 × 100 al 21 % con −1.100 no gravado
-- (pagó 110) cerraba COMPRA-A1 y devolver todo acreditaba 210. En una FC B o C (sin crédito, sus
-- renglones son todos «gravados» para el motor) la suma de esos descuentos no pasa del subtotal.
-- Devuelve el motivo, o NULL si está dentro del tope. Lo usan el alta y la edición.
CREATE FUNCTION public._compra_descuento_fuera_de_tope(p_items jsonb, p_cargos jsonb, p_sin_credito boolean)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH lin AS (
    SELECT CASE WHEN p_sin_credito THEN 'gravado'
                WHEN COALESCE(i.val->>'condicion_iva', 'gravado') IN ('exento', 'no_gravado') THEN i.val->>'condicion_iva'
                ELSE 'gravado' END AS cond,
           CASE WHEN jsonb_typeof(i.val->'subtotal') = 'number' THEN round((i.val->>'subtotal')::numeric, 2) ELSE 0 END AS neto
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END) AS i(val)
  ), des AS (
    SELECT COALESCE(c.val->>'condicion_iva', 'no_gravado') AS cond, -round((c.val->>'monto')::numeric, 2) AS monto
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_cargos) = 'array' THEN p_cargos ELSE '[]'::jsonb END) AS c(val)
     WHERE jsonb_typeof(c.val->'monto') = 'number' AND (c.val->>'monto')::numeric < 0
       AND COALESCE(c.val->>'condicion_iva', 'no_gravado') IN ('exento', 'no_gravado')
       AND COALESCE(NULLIF(c.val->'en_factura', 'null'::jsonb), 'true'::jsonb) = 'true'::jsonb
  ), por AS (
    SELECT k.cond,
           COALESCE((SELECT sum(d.monto) FROM des d WHERE p_sin_credito OR d.cond = k.cond), 0) AS descuento,
           COALESCE((SELECT sum(l.neto) FROM lin l WHERE p_sin_credito OR l.cond = k.cond), 0) AS renglones
      FROM (VALUES ('no_gravado'), ('exento')) AS k(cond)
  )
  SELECT CASE WHEN p_sin_credito
              THEN format('El descuento de la factura (%s) es mayor que lo que suman sus renglones (%s): revisá el monto.',
                          to_char(p.descuento, 'FM999999999990.00'), to_char(p.renglones, 'FM999999999990.00'))
              ELSE format('El descuento %s de la factura (%s) es mayor que lo que suman sus renglones %s (%s): un descuento sobre renglones gravados va como bonificación gravada.',
                          CASE p.cond WHEN 'exento' THEN 'exento' ELSE 'no gravado' END,
                          to_char(p.descuento, 'FM999999999990.00'),
                          CASE p.cond WHEN 'exento' THEN 'exentos' ELSE 'no gravados' END,
                          to_char(p.renglones, 'FM999999999990.00'))
         END
    FROM por p
   WHERE p.descuento > p.renglones
     AND (NOT p_sin_credito OR p.cond = 'no_gravado')
   ORDER BY p.cond DESC
   LIMIT 1;
$function$;
REVOKE ALL ON FUNCTION public._compra_descuento_fuera_de_tope(jsonb, jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._compra_descuento_fuera_de_tope(jsonb, jsonb, boolean) TO service_role;

-- La reposición desde la última compra (corregirla, anularla, una nota que la devuelve).
DO $rep$
DECLARE
  v_def text := pg_get_functiondef('public._reposicion_desde_ultima_compra(bigint,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
    $a$  SELECT c.tipo_factura, c.letra_comprobante, c.created_at, ci.costo_unitario, ci.bonificacion,$a$,
    $n$  SELECT ci.id AS item_id, c.tipo_factura, c.letra_comprobante, c.created_at, ci.costo_unitario, ci.bonificacion,$n$,
    '_reposicion_desde_ultima_compra (el renglón)');
  v_def := pg_temp.parche(v_def,
    $a$         costo_con_iva      = public.costo_financiero_unitario(
                                v_neto,
                                COALESCE(v_ult.iva_linea, p.porcentaje_iva),
                                COALESCE(v_ult.ii_linea, p.impuestos_internos),
                                v_tipo),$a$,
    $n$         -- mig NNN (1593-b1, #1593; decisión del dueño del 19/11): el costo neto más el IVA
         -- de cada componente, con la cuenta del alta.
         costo_con_iva      = public._costo_con_iva_unitario(
                                COALESCE(v_ult.costo_real_unitario,
                                  public.costo_real_unitario(v_neto, COALESCE(v_ult.ii_linea, p.impuestos_internos), v_tipo, 0)),
                                v_neto,
                                COALESCE(v_ult.iva_linea, p.porcentaje_iva),
                                v_tipo = 'ZZ',
                                public._compra_iva_cargos_de_linea(v_ult.item_id)),$n$,
    '_reposicion_desde_ultima_compra (el costo con IVA)');
  EXECUTE v_def;
END
$rep$;

-- =========================================================================
-- 3 y 4 · registrar_compra_completa: el costo con IVA y el no gravado negativo
-- =========================================================================
DO $rcc$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
    $a$  v_costos_por_linea    JSONB;       -- {indice: {costo_real, cargos, ...}}
$a$,
    $n$  v_costos_por_linea    JSONB;       -- {indice: {costo_real, cargos, ...}}
  v_iva_cargos          JSONB := '{}'::JSONB;  -- mig NNN (1593-b1): {indice: IVA de sus cargos}
$n$,
    'registrar_compra_completa (declaración)');
  v_def := pg_temp.parche(v_def,
    $a$    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);
$a$,
    $n$    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);
    v_iva_cargos := public._compra_iva_cargos(v_items_motor, v_cargos);  /* mig NNN (1593-b1) */
$n$,
    'registrar_compra_completa (el IVA de los cargos)');
  v_def := pg_temp.parche(v_def,
    $a$      v_costo_real  := costo_real_unitario(v_costo_neto, v_impuestos_internos, CASE WHEN v_sin_credito THEN 'ZZ' ELSE v_tipo_factura END, 0 /* mig 193: los cargos entran en la task 9 */);
    END IF;
$a$,
    $n$      v_costo_real  := costo_real_unitario(v_costo_neto, v_impuestos_internos, CASE WHEN v_sin_credito THEN 'ZZ' ELSE v_tipo_factura END, 0 /* mig 193: los cargos entran en la task 9 */);
    END IF;
    /* mig NNN (1593-b1, #1593; decision del dueño del 19/11) · EL COSTO CON IVA ES EL NETO
       MAS EL IVA DE SUS COMPONENTES: el costo real (neto, impuestos internos, cargos y flete
       netos) mas el IVA del producto y el de cada cargo que lo lleva. Sin credito, lo pagado. */
    v_costo_con_iva := public._costo_con_iva_unitario(v_costo_real, v_costo_neto, v_porcentaje_iva, v_sin_credito,
                         CASE WHEN v_cantidad > 0
                              THEN COALESCE((v_iva_cargos->>(v_idx - 1)::TEXT)::NUMERIC, 0) / v_cantidad
                              ELSE 0 END);
$n$,
    'registrar_compra_completa (el costo con IVA)');
  -- 4 · el no gravado de la cabecera puede bajar de 0 hasta los descuentos no gravados de la factura
  v_def := pg_temp.parche(v_def,
    $a$                                        p_impuestos_internos, p_percepcion_iva, p_percepcion_iibb,
                                        p_no_gravado]::NUMERIC[]) AS x
              WHERE x < 0) THEN$a$,
    $n$                                        p_impuestos_internos, p_percepcion_iva, p_percepcion_iibb
                                        ]::NUMERIC[]) AS x
              WHERE x < 0)
     /* mig NNN (#1590) · el no gravado puede bajar de 0 hasta lo que suman los descuentos no
        gravados o exentos que trae la factura: van ahi, con su signo. */
     OR (NOT v_es_zz AND COALESCE(p_no_gravado, 0) < LEAST(0, COALESCE((
           SELECT sum((c.val->>'monto')::NUMERIC)
             FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_cargos) = 'array' THEN p_cargos ELSE '[]'::JSONB END) AS c(val)
            WHERE jsonb_typeof(c.val->'monto') = 'number' AND (c.val->>'monto')::NUMERIC < 0
              AND COALESCE(c.val->>'condicion_iva', 'no_gravado') <> 'gravado'
              AND COALESCE(NULLIF(c.val->'en_factura', 'null'::JSONB), 'true'::JSONB) = 'true'::JSONB), 0))) THEN$n$,
    'registrar_compra_completa (el no gravado)');
  v_def := pg_temp.parche(v_def,
    $a$      'Hay un importe de la cabecera negativo: sólo la bonificación de la factura puede serlo. Revisá los importes.');
  END IF;
$a$,
    $n$      'Hay un importe de la cabecera negativo: sólo la bonificación de la factura puede serlo. Revisá los importes.');
  END IF;
  /* mig NNN (H5 de la revision de C3, #1590) · un descuento no gravado o exento no pasa de lo que
     suman los renglones de esa condicion: si no, devolver todo acreditaba mas que lo pagado. */
  v_motivo := CASE WHEN v_es_zz THEN NULL ELSE public._compra_descuento_fuera_de_tope(p_items, p_cargos, v_sin_credito) END;
  IF v_motivo IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', v_motivo);
  END IF;
$n$,
    'registrar_compra_completa (el tope de los descuentos)');
  EXECUTE v_def;
END
$rcc$;

-- =========================================================================
-- 1, 3 y 4 · actualizar_compra_items: los lotes, el costo con IVA y el no gravado
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
    $a$  v_fuera_de_rango   TEXT;      -- los rangos del renglon (los mismos que el alta)
$a$,
    $n$  v_fuera_de_rango   TEXT;      -- los rangos del renglon (los mismos que el alta)
  -- mig NNN (STK-13, #1542)
  v_lotes_res        JSONB;     -- lo que devolvio sincronizar_lotes_compra
  v_iva_cargos       JSONB := '{}'::JSONB;  -- mig NNN (1593-b1): {indice: IVA de sus cargos}
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
  v_def := pg_temp.parche(v_def,
    $a$    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);
$a$,
    $n$    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);
    v_iva_cargos := public._compra_iva_cargos(v_items_motor, v_cargos);  /* mig NNN (1593-b1) */
$n$,
    'actualizar_compra_items (el IVA de los cargos)');
  v_def := pg_temp.parche(v_def,
    $a$      v_costo_real  := costo_real_unitario(v_costo_neto, v_impuestos_internos, CASE WHEN v_sin_credito THEN 'ZZ' ELSE v_compra.tipo_factura END, 0 /* mig 193: los cargos entran en la task 9 */);
    END IF;
$a$,
    $n$      v_costo_real  := costo_real_unitario(v_costo_neto, v_impuestos_internos, CASE WHEN v_sin_credito THEN 'ZZ' ELSE v_compra.tipo_factura END, 0 /* mig 193: los cargos entran en la task 9 */);
    END IF;
    /* mig NNN (1593-b1, #1593; decision del dueño del 19/11) · el costo con IVA es el neto mas
       el IVA de sus componentes (ver el alta). */
    v_costo_con_iva := public._costo_con_iva_unitario(v_costo_real, v_costo_neto, v_porcentaje_iva, v_sin_credito,
                         CASE WHEN v_cantidad > 0
                              THEN COALESCE((v_iva_cargos->>(v_idx - 1)::TEXT)::NUMERIC, 0) / v_cantidad
                              ELSE 0 END);
$n$,
    'actualizar_compra_items (el costo con IVA)');
  v_def := pg_temp.parche(v_def,
    $a$                                        p_percepcion_iva, p_percepcion_iibb, p_no_gravado,
                                        p_otros_impuestos]::NUMERIC[]) AS x
              WHERE x < 0) THEN$a$,
    $n$                                        p_percepcion_iva, p_percepcion_iibb,
                                        p_otros_impuestos]::NUMERIC[]) AS x
              WHERE x < 0)
     /* mig NNN (#1590) · el no gravado puede bajar de 0 hasta lo que suman los descuentos no
        gravados o exentos que trae la factura (ver el alta). */
     OR (v_compra.tipo_factura <> 'ZZ' AND COALESCE(p_no_gravado, 0) < LEAST(0, COALESCE((
           SELECT sum((c.val->>'monto')::NUMERIC)
             FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_cargos) = 'array' THEN p_cargos ELSE '[]'::JSONB END) AS c(val)
            WHERE jsonb_typeof(c.val->'monto') = 'number' AND (c.val->>'monto')::NUMERIC < 0
              AND COALESCE(c.val->>'condicion_iva', 'no_gravado') <> 'gravado'
              AND COALESCE(NULLIF(c.val->'en_factura', 'null'::JSONB), 'true'::JSONB) = 'true'::JSONB), 0))) THEN$n$,
    'actualizar_compra_items (el no gravado)');
  v_def := pg_temp.parche(v_def,
    $a$      'Hay un importe de la cabecera negativo: sólo la bonificación de la factura puede serlo. Revisá los importes.');
  END IF;
$a$,
    $n$      'Hay un importe de la cabecera negativo: sólo la bonificación de la factura puede serlo. Revisá los importes.');
  END IF;
  /* mig NNN (H5 de la revision de C3, #1590) · el tope de los descuentos no gravados o exentos (ver el alta). */
  v_motivo := CASE WHEN v_compra.tipo_factura = 'ZZ' THEN NULL
                   ELSE public._compra_descuento_fuera_de_tope(p_items_nuevos, p_cargos,
                          COALESCE(v_compra.letra_comprobante, 'A') IN ('B', 'C')) END;
  IF v_motivo IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', v_motivo);
  END IF;
$n$,
    'actualizar_compra_items (el tope de los descuentos)');
  -- H10 de la revisión: bajar la compra por debajo de lo que ya salió, con su motivo y antes de tocar nada.
  v_def := pg_temp.parche(v_def,
    $a$  /* mig 482 (STK-2, #1516) · LO QUE LA EDICION LE SACA A UN PRODUCTO CON$a$,
    $n$  /* mig NNN (H10 de la revision de C3) · BAJAR LA COMPRA POR DEBAJO DE LO QUE YA SALIO.
     Daba el mensaje crudo del CHECK productos_stock_no_negativo (el chequeo amable de mas
     abajo mira despues del UPDATE y nunca llegaba). Con los productos ya tomados: si lo que
     la edicion le saca a un producto es mas que su stock de hoy, ya salieron unidades de
     esta compra que la edicion no puede devolver. */
  SELECT format('el stock de hoy de «%s» no alcanza: no se puede bajar la compra a menos de %s',
                pr.nombre, b.viejas - pr.stock)
    INTO v_motivo
    FROM (SELECT v.producto_id, v.qty_old AS viejas, COALESCE(n.qty_new, 0) AS nuevas
            FROM (SELECT producto_id, SUM(cantidad)::INT AS qty_old
                    FROM compra_items
                   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
                   GROUP BY producto_id) v
            LEFT JOIN (SELECT (item->>'producto_id')::BIGINT AS producto_id,
                              SUM((item->>'cantidad')::INT)::INT AS qty_new
                         FROM jsonb_array_elements(p_items_nuevos) AS item
                        GROUP BY 1) n USING (producto_id)) b
    JOIN productos pr ON pr.id = b.producto_id AND pr.sucursal_id = v_sucursal
   WHERE b.viejas - b.nuevas > pr.stock
   ORDER BY pr.id
   LIMIT 1;
  IF v_motivo IS NOT NULL THEN
    RAISE EXCEPTION '%', upper(left(v_motivo, 1)) || substr(v_motivo, 2) || '.';
  END IF;

  /* mig 482 (STK-2, #1516) · LO QUE LA EDICION LE SACA A UN PRODUCTO CON$n$,
    'actualizar_compra_items (lo ya vendido)');
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

-- =========================================================================
-- 4 · el no gravado de la cabecera, con el signo de sus descuentos
-- =========================================================================
-- Era `no_gravado >= 0`. Ahora sólo el freno de NaN (la columna es numeric(12,2): sin
-- infinitos); el piso lo ponen el alta y la edición (lo que suman los descuentos no gravados
-- o exentos de la factura) y COMPRA-A1 cierra con el número con signo. Todo valor que hoy
-- cumple el CHECK viejo cumple el nuevo.
ALTER TABLE public.compras
  DROP CONSTRAINT compras_importes_validos,
  ADD CONSTRAINT compras_importes_validos CHECK (
    subtotal >= 0 AND subtotal <> 'NaN' AND iva >= 0 AND iva <> 'NaN'
    AND otros_impuestos >= 0 AND otros_impuestos <> 'NaN'
    AND impuestos_internos >= 0 AND impuestos_internos <> 'NaN'
    AND percepcion_iva >= 0 AND percepcion_iva <> 'NaN'
    AND percepcion_iibb >= 0 AND percepcion_iibb <> 'NaN'
    AND no_gravado <> 'NaN'
    AND total >= 0 AND total <> 'NaN' AND bonificaciones <> 'NaN');
COMMENT ON COLUMN public.compras.no_gravado IS
  'Los conceptos no gravados o exentos de la factura, con el signo de sus descuentos (mig NNN, #1590): un descuento sobre renglones exentos o no gravados lo baja, y puede quedar negativo.';

-- =========================================================================
-- 5 · El recálculo de los productos que ya existen (decisión del dueño, 19/11: «Sí, recalculalos»)
-- =========================================================================
-- Primera pasada: cada producto toma el costo con IVA que le dejaría volver a guardar su última
-- compra con la regla nueva: la misma cuenta que _reposicion_desde_ultima_compra (la compra más
-- nueva que fija costo, sin las devueltas enteras; la alícuota y el II del renglón, o los del
-- producto si el renglón no los guardó). Sólo costo_con_iva: el neto, el real y el promedio no se
-- tocan. Resguardos (H2, H3 y H4 de la primera revisión; N2 de la segunda):
--   · Sólo un producto cuyos tres costos de hoy son los que dejó esa compra con la regla vieja:
--     costo_real = el costo real del renglón (exacto: el alta guarda el mismo número de 4
--     decimales en los dos), costo_sin_iva = round(neto del renglón, 2) y costo_con_iva =
--     round(costo_financiero_unitario del renglón, 2), estos dos con un centavo de tolerancia (el
--     doble redondeo de una bonificación de 3 o más decimales). Uno corregido a mano en la ficha,
--     o con costos de otra época, no cierra con su compra y queda para la segunda pasada.
--   · Uno que tomó su costo de un envío aceptado después de esa compra, a la segunda pasada.
-- Segunda pasada (N1 de la segunda revisión): ningún producto ve bajar su «Costo total» por el
-- front nuevo. La ficha de antes mostraba costo_con_iva + lo que el costo real tiene por encima
-- de neto + II (los cargos de la compra); la nueva muestra costo_con_iva tal cual. A todo producto
-- que la primera pasada no tocó y tiene esa diferencia (los de envío, los que no cierran con su
-- compra, los que nacieron en su sucursal por un envío), se la suma al costo con IVA: la ficha
-- nueva muestra exactamente lo que mostraba la vieja. No es la regla (no sabe el IVA de esos
-- cargos): es no mover lo que se ve.
-- Rastro: cada cambio queda en costo_con_iva_recalculos (antes, después, la compra y el renglón
-- de los que salió en la primera pasada, y el motivo de cada pasada) y, como todo UPDATE de
-- productos, en audit_logs. Idempotente: un producto del rastro no se vuelve a tocar. El UPDATE
-- dispara de productos sólo trigger_update_productos_timestamp (updated_at) y
-- audit_productos_update; productos_proteger_columnas, trg_validar_subcategoria_producto,
-- trg_lotes_sincronizar y trg_stock_historico no hacen nada (el dueño de la migración, sin cambio
-- de subcategoría ni de stock). Ninguno de precios.
CREATE TABLE public.costo_con_iva_recalculos (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  producto_id            bigint NOT NULL,
  sucursal_id            bigint NOT NULL,
  costo_con_iva_antes    numeric(12,2),
  costo_con_iva_despues  numeric(12,2) NOT NULL,
  compra_id              bigint,
  compra_item_id         bigint,
  motivo                 text NOT NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT costo_con_iva_recalculos_no_nan CHECK (costo_con_iva_antes <> 'NaN' AND costo_con_iva_despues <> 'NaN')
);
ALTER TABLE public.costo_con_iva_recalculos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.costo_con_iva_recalculos FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.costo_con_iva_recalculos TO service_role;
COMMENT ON TABLE public.costo_con_iva_recalculos IS
  'Rastro del recálculo de productos.costo_con_iva de la migración NNN (1593-b1, #1593): un producto por fila, con el valor de antes y el nuevo, la compra de la que salió (primera pasada) y el motivo de cada pasada. Sólo de server (RLS sin policies, sin grants para la API). Deshacer: scratchpad de la tarjeta C3 (deshacer-recalculo.sql).';

-- Los candidatos de la primera pasada (la última compra de cada producto y si sus costos de hoy
-- son los de esa compra). p_productos acota a unos productos (los ensayos); NULL, todos.
CREATE FUNCTION public._costo_con_iva_candidatos(p_productos bigint[])
 RETURNS TABLE(producto_id bigint, sucursal_id bigint, compra_id bigint, item_id bigint, p_con numeric,
               con_nuevo numeric, envio_posterior boolean, de_la_compra boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH ult AS (
    SELECT DISTINCT ON (ci.producto_id, ci.sucursal_id)
           ci.id AS item_id, ci.compra_id, ci.producto_id, ci.sucursal_id, ci.costo_neto_unitario,
           ci.costo_unitario, ci.bonificacion, ci.costo_real_unitario,
           ci.porcentaje_iva AS iva_linea, ci.impuestos_internos AS ii_linea,
           c.tipo_factura, c.letra_comprobante, c.created_at
      FROM public.compra_items ci
      JOIN public.compras c ON c.id = ci.compra_id AND c.sucursal_id = ci.sucursal_id
     WHERE c.estado <> 'cancelada'
       AND (p_productos IS NULL OR ci.producto_id = ANY (p_productos))
       AND public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario)
       AND NOT public._compra_producto_devuelto(c.id, ci.producto_id, ci.sucursal_id)
     ORDER BY ci.producto_id, ci.sucursal_id, c.fecha_compra DESC, c.created_at DESC, c.id DESC, ci.id DESC
  ), base AS (
    SELECT u.*, p.costo_sin_iva AS p_sin, p.costo_real AS p_real, p.costo_con_iva AS p_con,
           CASE WHEN public._tipo_compra_producto(u.tipo_factura, u.letra_comprobante) = 'FC' THEN 'FC' ELSE 'ZZ' END AS tipo,
           COALESCE(u.costo_neto_unitario, u.costo_unitario * (1 - COALESCE(u.bonificacion, 0) / 100)) AS neto,
           COALESCE(u.iva_linea, p.porcentaje_iva) AS pct,
           COALESCE(u.ii_linea, p.impuestos_internos) AS ii
      FROM ult u
      JOIN public.productos p ON p.id = u.producto_id AND p.sucursal_id = u.sucursal_id
  ), calc AS (
    SELECT b.*,
           COALESCE(b.costo_real_unitario, public.costo_real_unitario(b.neto, b.ii, b.tipo, 0)) AS real_compra,
           round(public.costo_financiero_unitario(b.neto, b.pct, b.ii, b.tipo), 2) AS con_viejo
      FROM base b
  )
  SELECT c.producto_id, c.sucursal_id, c.compra_id, c.item_id, c.p_con,
         round(public._costo_con_iva_unitario(c.real_compra, c.neto, c.pct, c.tipo = 'ZZ',
                                              public._compra_iva_cargos_de_linea(c.item_id)), 2),
         EXISTS (SELECT 1
                   FROM public.movimiento_sucursal_items mi
                   JOIN public.movimientos_sucursal m ON m.id = mi.movimiento_id
                  WHERE mi.producto_destino_id = c.producto_id AND m.sucursal_destino_id = c.sucursal_id
                    AND m.estado = 'aceptada' AND m.resuelto_at > c.created_at),
         (c.p_real IS NOT DISTINCT FROM c.real_compra
          AND abs(c.p_sin - round(c.neto, 2)) <= 0.01
          AND abs(c.p_con - c.con_viejo) <= 0.01)
    FROM calc c;
$function$;
REVOKE ALL ON FUNCTION public._costo_con_iva_candidatos(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._costo_con_iva_candidatos(bigint[]) TO service_role;

-- Las dos pasadas. Devuelve lo que hizo. p_productos acota (los ensayos); NULL, todos. Vale sólo
-- sobre productos con el costo con IVA de la regla vieja: es idempotente mientras no entre nada, pero
-- un producto que después recibe una compra con cargos ya los tiene en su costo con IVA, y la segunda
-- pasada se los volvería a sumar (L3 de la revisión). Por eso, sobre todo (p_productos NULL) corre
-- una sola vez: la de la migración.
CREATE FUNCTION public._recalcular_costo_con_iva(p_productos bigint[] DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r record;
  v_p1 int;
  v_p2 int;
  v_p2_suben int;
  v_p2_bajan int;
BEGIN
  IF p_productos IS NULL AND EXISTS (SELECT 1 FROM public.costo_con_iva_recalculos) THEN
    RAISE EXCEPTION 'El recálculo del costo con IVA ya corrió (migración NNN): sobre los productos de hoy contaría dos veces los cargos de una compra nueva.';
  END IF;
  SELECT count(*) AS candidatos,
         count(*) FILTER (WHERE x.de_la_compra AND NOT x.envio_posterior AND x.con_nuevo IS DISTINCT FROM x.p_con) AS cambian,
         count(*) FILTER (WHERE x.de_la_compra AND NOT x.envio_posterior AND x.con_nuevo > x.p_con) AS suben,
         count(*) FILTER (WHERE x.de_la_compra AND NOT x.envio_posterior AND x.con_nuevo < x.p_con) AS bajan,
         count(*) FILTER (WHERE x.de_la_compra AND NOT x.envio_posterior AND x.con_nuevo IS NOT DISTINCT FROM x.p_con) AS iguales,
         count(*) FILTER (WHERE x.envio_posterior) AS por_envio,
         count(*) FILTER (WHERE NOT x.envio_posterior AND NOT x.de_la_compra) AS no_son_de_su_compra,
         COALESCE(max(abs(x.con_nuevo - x.p_con)) FILTER (WHERE x.de_la_compra AND NOT x.envio_posterior), 0) AS dif_max
    INTO r
    FROM public._costo_con_iva_candidatos(p_productos) x
   WHERE NOT EXISTS (SELECT 1 FROM public.costo_con_iva_recalculos k
                      WHERE k.producto_id = x.producto_id AND k.sucursal_id = x.sucursal_id);

  -- Primera pasada: la regla.
  WITH upd AS (
    UPDATE public.productos p
       SET costo_con_iva = x.con_nuevo
      FROM public._costo_con_iva_candidatos(p_productos) x
     WHERE p.id = x.producto_id AND p.sucursal_id = x.sucursal_id
       AND x.de_la_compra AND NOT x.envio_posterior
       AND x.con_nuevo IS DISTINCT FROM x.p_con
       AND NOT EXISTS (SELECT 1 FROM public.costo_con_iva_recalculos k
                        WHERE k.producto_id = p.id AND k.sucursal_id = p.sucursal_id)
    RETURNING p.id, p.sucursal_id, x.p_con, p.costo_con_iva, x.compra_id, x.item_id
  )
  INSERT INTO public.costo_con_iva_recalculos
         (producto_id, sucursal_id, costo_con_iva_antes, costo_con_iva_despues, compra_id, compra_item_id, motivo)
  SELECT u.*, '1593-b1: la regla del dueño (19/11), desde la última compra' FROM upd u;
  GET DIAGNOSTICS v_p1 = ROW_COUNT;
  IF v_p1 <> r.cambian THEN
    RAISE EXCEPTION 'el recálculo escribió % productos en la primera pasada y se esperaban %', v_p1, r.cambian;
  END IF;

  -- Segunda pasada: el resto conserva el «Costo total» que mostraba la ficha (costo con IVA + lo
  -- que el costo real tiene por encima de neto + II, con el tipo con el que la ficha costea).
  WITH dif AS (
    SELECT p.id, p.sucursal_id, p.costo_con_iva AS con,
           p.costo_real - CASE WHEN p.ultimo_tipo_compra IN ('ZZ', 'FC B', 'FC C') THEN p.costo_sin_iva
                               ELSE round(p.costo_sin_iva * (1 + COALESCE(p.impuestos_internos, 0) / 100), 4) END AS adicional
      FROM public.productos p
     WHERE (p_productos IS NULL OR p.id = ANY (p_productos))
       AND COALESCE(p.costo_sin_iva, 0) > 0 AND COALESCE(p.costo_real, 0) > 0 AND COALESCE(p.costo_con_iva, 0) > 0
       AND p.costo_sin_iva <> 'NaN' AND p.costo_real <> 'NaN' AND p.costo_con_iva <> 'NaN'
       AND NOT EXISTS (SELECT 1 FROM public.costo_con_iva_recalculos k
                        WHERE k.producto_id = p.id AND k.sucursal_id = p.sucursal_id)
       -- L1 de la revisión: lo que ya está en la regla (los «ya iguales») no se toca. Su adicional se
       -- mediría con el II de la ficha, que puede no ser el del renglón, y lo contaría dos veces.
       AND NOT EXISTS (SELECT 1 FROM public._costo_con_iva_candidatos(p_productos) x
                        WHERE x.producto_id = p.id AND x.sucursal_id = p.sucursal_id
                          AND x.de_la_compra AND NOT x.envio_posterior)
  ), upd AS (
    UPDATE public.productos p
       SET costo_con_iva = round(d.con + d.adicional, 2)
      FROM dif d
     WHERE p.id = d.id AND p.sucursal_id = d.sucursal_id
       AND abs(d.adicional) >= 0.01 AND round(d.con + d.adicional, 2) > 0
    RETURNING p.id, p.sucursal_id, d.con, p.costo_con_iva
  )
  INSERT INTO public.costo_con_iva_recalculos
         (producto_id, sucursal_id, costo_con_iva_antes, costo_con_iva_despues, motivo)
  SELECT u.*, '1593-b1: la ficha no cambia (costo con IVA + lo que la compra sumó al costo real; N1)' FROM upd u;
  GET DIAGNOSTICS v_p2 = ROW_COUNT;

  SELECT count(*) FILTER (WHERE k.costo_con_iva_despues > k.costo_con_iva_antes),
         count(*) FILTER (WHERE k.costo_con_iva_despues < k.costo_con_iva_antes)
    INTO v_p2_suben, v_p2_bajan
    FROM public.costo_con_iva_recalculos k
   WHERE k.motivo LIKE '%N1)' AND (p_productos IS NULL OR k.producto_id = ANY (p_productos))
     AND k.created_at = now();

  RETURN jsonb_build_object(
    'candidatos', r.candidatos, 'regla', r.cambian, 'regla_suben', r.suben, 'regla_bajan', r.bajan,
    'regla_dif_max', r.dif_max, 'ya_iguales', r.iguales, 'por_envio', r.por_envio,
    'no_son_de_su_compra', r.no_son_de_su_compra,
    'ficha_igual', v_p2, 'ficha_igual_suben', v_p2_suben, 'ficha_igual_bajan', v_p2_bajan);
END
$function$;
REVOKE ALL ON FUNCTION public._recalcular_costo_con_iva(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._recalcular_costo_con_iva(bigint[]) TO service_role;

DO $recalculo$
DECLARE
  v jsonb := public._recalcular_costo_con_iva(NULL);
BEGIN
  RAISE NOTICE 'mig NNN · recálculo del costo con IVA: % productos con compra; con la regla cambió % (suben %, bajan %, diferencia máxima %); afuera de la regla: % ya iguales, % con el costo de un envío posterior, % cuyos costos de hoy no son los de su última compra; para que la ficha no cambie, a % más se les sumó lo que la compra sumó al costo real (suben %, bajan %)',
    v->'candidatos', v->'regla', v->'regla_suben', v->'regla_bajan', v->'regla_dif_max', v->'ya_iguales',
    v->'por_envio', v->'no_son_de_su_compra', v->'ficha_igual', v->'ficha_igual_suben', v->'ficha_igual_bajan';
END
$recalculo$;

-- =========================================================================
-- 6 · La ficha no le saca los cargos al costo con IVA (H6 de la revisión)
-- =========================================================================
-- La ficha escribe productos por REST. Una ficha de antes de esta migración (un PWA viejo) guarda
-- costo_con_iva = neto + IVA + II sin los cargos cuando se corrige el neto, el IVA o el II. Desde
-- acá el server compone el costo con IVA de lo que guarda la ficha, mande lo que mande: el de los
-- datos nuevos más lo que el guardado tenía por encima de neto + IVA + II (los cargos y su IVA de
-- la compra), si el producto tuvo una compra o su costo real tiene cargos. Sin neto, deja lo que
-- mandó la ficha. Sólo para la escritura directa de la ficha
-- (authenticated, sin un trigger o una RPC en el medio): las compras y los envíos escriben el
-- costo con IVA ellos mismos. Es la cuenta de la ficha nueva (adicionalConIvaDeCompra), así que con
-- la ficha nueva no cambia nada.
CREATE FUNCTION public.productos_componer_costo_con_iva()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tipo text;
  v_adicional numeric := 0;
  v_iva_old numeric;
  v_iva_new numeric;
BEGIN
  IF current_user <> 'authenticated' OR pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;
  IF (NEW.costo_sin_iva, NEW.porcentaje_iva, NEW.impuestos_internos, NEW.costo_con_iva, NEW.condicion_iva)
     IS NOT DISTINCT FROM (OLD.costo_sin_iva, OLD.porcentaje_iva, OLD.impuestos_internos, OLD.costo_con_iva, OLD.condicion_iva) THEN
    RETURN NEW;
  END IF;
  -- Sin neto, o con un dato que no es un número o está fuera de rango, deja lo que mandó la ficha:
  -- los CHECK de productos lo rechazan con su nombre (test-nan-y-rangos-1565-t1, P1).
  IF COALESCE(NEW.costo_sin_iva, 0) <= 0
     OR 'NaN' IN (NEW.costo_sin_iva, NEW.porcentaje_iva, NEW.impuestos_internos, NEW.costo_con_iva,
                  OLD.costo_sin_iva, OLD.porcentaje_iva, OLD.impuestos_internos, OLD.costo_con_iva)
     OR COALESCE(NEW.porcentaje_iva, 21) NOT BETWEEN 0 AND 100
     OR COALESCE(NEW.impuestos_internos, 0) NOT BETWEEN 0 AND 9900 THEN
    RETURN NEW;
  END IF;
  -- El tipo con el que la ficha costea (tipoParaCostoDeProducto): ZZ, B y C son lo pagado.
  v_tipo := CASE WHEN NEW.ultimo_tipo_compra IN ('ZZ', 'FC B', 'FC C') THEN 'ZZ' ELSE 'FC' END;
  -- La alícuota con la que se costea: un exento o no gravado es 0 aunque no tenga alícuota cargada
  -- (una importación: L2 de la revisión), como alicuotaIvaVenta en la ficha. En línea y no con
  -- _alicuota_iva_venta, que no es de authenticated (este trigger corre como quien guarda la ficha).
  v_iva_old := CASE WHEN OLD.condicion_iva IN ('exento', 'no_gravado') THEN 0 ELSE COALESCE(OLD.porcentaje_iva, 21) END;
  v_iva_new := CASE WHEN NEW.condicion_iva IN ('exento', 'no_gravado') THEN 0 ELSE COALESCE(NEW.porcentaje_iva, 21) END;
  -- Se conserva la diferencia si el producto tuvo una compra (N4 de la revisión: la de una
  -- importación o una carga a mano no es un cargo, y corregir el neto la limpiaba) o si su costo
  -- real tiene algo por encima de neto + II (L4: un producto sin compra al que el recálculo le sumó
  -- esos cargos, para que la ficha no los suelte).
  IF COALESCE(OLD.costo_sin_iva, 0) > 0 AND COALESCE(OLD.costo_con_iva, 0) > 0
     AND (OLD.ultimo_tipo_compra IS NOT NULL
          OR COALESCE(OLD.costo_real, 0) > CASE WHEN v_tipo = 'ZZ' THEN OLD.costo_sin_iva
                                                ELSE round(OLD.costo_sin_iva * (1 + COALESCE(OLD.impuestos_internos, 0) / 100), 4) END) THEN
    v_adicional := OLD.costo_con_iva
      - public.costo_financiero_unitario(OLD.costo_sin_iva, v_iva_old, COALESCE(OLD.impuestos_internos, 0), v_tipo);
  END IF;
  NEW.costo_con_iva := round(public.costo_financiero_unitario(NEW.costo_sin_iva, v_iva_new,
                                                              COALESCE(NEW.impuestos_internos, 0), v_tipo)
                             + v_adicional, 2);
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.productos_componer_costo_con_iva() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.productos_componer_costo_con_iva() TO service_role;
-- Después de trg_ii_derivado (que deriva el II del encuadre): los BEFORE van por nombre.
CREATE TRIGGER trg_productos_costo_con_iva
  BEFORE UPDATE OF costo_sin_iva, costo_con_iva, porcentaje_iva, impuestos_internos, ii_encuadre_id, condicion_iva
  ON public.productos
  FOR EACH ROW EXECUTE FUNCTION public.productos_componer_costo_con_iva();

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
    ('public._compra_factor(bigint,bigint,bigint,boolean)', 'NOT p_para_iva OR cc.condicion_iva = ''gravado''', false),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     'v_costo_con_iva := public._costo_con_iva_unitario(v_costo_real, v_costo_neto, v_porcentaje_iva, v_sin_credito,', true),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     'OR (NOT v_es_zz AND COALESCE(p_no_gravado, 0) < LEAST(0,', true),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
     'v_costo_con_iva := public._costo_con_iva_unitario(v_costo_real, v_costo_neto, v_porcentaje_iva, v_sin_credito,', true),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
     'OR (v_compra.tipo_factura <> ''ZZ'' AND COALESCE(p_no_gravado, 0) < LEAST(0,', true),
    ('public._reposicion_desde_ultima_compra(bigint,bigint)', 'public._compra_iva_cargos_de_linea(v_ult.item_id)', false),
    ('public._compra_iva_cargos_de_linea(bigint)', 'COALESCE(ci.porcentaje_iva, pr.porcentaje_iva)', false),
    ('public.productos_componer_costo_con_iva()', 'AND (OLD.ultimo_tipo_compra IS NOT NULL', false),
    ('public._recalcular_costo_con_iva(bigint[])', 'la ficha no cambia', false),
    ('public._recalcular_costo_con_iva(bigint[])', 'El recálculo del costo con IVA ya corrió', false),
    ('public.productos_componer_costo_con_iva()', 'OLD.condicion_iva IN (''exento'', ''no_gravado'')', false),
    ('public._costo_con_iva_unitario(numeric,numeric,numeric,boolean,numeric)', 'THEN round(p_costo_real + COALESCE(p_iva_cargos, 0), 4)', false),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     'public._compra_descuento_fuera_de_tope(p_items, p_cargos, v_sin_credito)', true),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
     'public._compra_descuento_fuera_de_tope(p_items_nuevos, p_cargos,', true),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
     'no alcanza: no se puede bajar la compra a menos de %s', true)
  ) AS t(f, marca, definer) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND position(r.marca in prosrc) > 0 AND prosecdef = r.definer) THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró', r.f;
    END IF;
  END LOOP;
  -- Toda función que la migración crea o reescribe termina su search_path en pg_temp (B15).
  FOR r IN SELECT unnest(ARRAY[
      'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
      'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
      'public.registrar_nota_credito_lote(bigint,numeric,text,text)',
      'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
      'public._reposicion_desde_ultima_compra(bigint,bigint)',
      'public._compra_factor(bigint,bigint,bigint,boolean)',
      'public._compra_factor_neto(bigint,bigint,bigint)',
      'public._compra_factor_iva(bigint,bigint,bigint)',
      'public._compra_iva_cargos(jsonb,jsonb)',
      'public._compra_iva_cargos_de_linea(bigint)',
      'public._costo_con_iva_unitario(numeric,numeric,numeric,boolean,numeric)',
      'public._compra_descuento_fuera_de_tope(jsonb,jsonb,boolean)',
      'public.productos_componer_costo_con_iva()',
      'public._costo_con_iva_candidatos(bigint[])',
      'public._recalcular_costo_con_iva(bigint[])']) AS f LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
      RAISE EXCEPTION 'mig NNN · % quedó sin pg_temp en su search_path', r.f;
    END IF;
  END LOOP;
  IF position('no_gravado >= ' in (SELECT pg_get_constraintdef(oid) FROM pg_constraint
                                     WHERE conname = 'compras_importes_validos' AND conrelid = 'public.compras'::regclass)) > 0 THEN
    RAISE EXCEPTION 'mig NNN · compras_importes_validos sigue frenando el no gravado negativo';
  END IF;
  -- La tabla del recálculo: sólo de server.
  IF has_table_privilege('authenticated', 'public.costo_con_iva_recalculos', 'SELECT')
     OR has_table_privilege('anon', 'public.costo_con_iva_recalculos', 'SELECT')
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.costo_con_iva_recalculos'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · costo_con_iva_recalculos quedó a la vista de la API o sin RLS';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_productos_costo_con_iva'
                    AND tgrelid = 'public.productos'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · falta el trigger trg_productos_costo_con_iva';
  END IF;
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
                               'public._compra_factor_iva(bigint,bigint,bigint)',
                               'public._compra_iva_cargos(jsonb,jsonb)',
                               'public._compra_iva_cargos_de_linea(bigint)',
                               'public._costo_con_iva_unitario(numeric,numeric,numeric,boolean,numeric)',
                               'public._compra_descuento_fuera_de_tope(jsonb,jsonb,boolean)',
                               'public.productos_componer_costo_con_iva()',
                               'public._costo_con_iva_candidatos(bigint[])',
                               'public._recalcular_costo_con_iva(bigint[])']) AS f LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE') OR has_function_privilege('authenticated', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para la API', r.f;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
