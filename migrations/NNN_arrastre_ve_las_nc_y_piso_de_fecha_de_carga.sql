-- =========================================================================
-- NNN · EL ARRASTRE DEL PROMEDIO VE LAS NC DE DEVOLUCIÓN DE LAS COMPRAS
--       POSTERIORES, Y LA FECHA DE UN GASTO, DE UN MOVIMIENTO DE EMPLEADO Y
--       DEL PAGO DE UNA LIQUIDACIÓN TIENE PISO
--       (reauditoría final del 12/11: STK-11 de #1542 y GTO-A de #1545)
--
-- Reemplaza el cuerpo entero de `_cpp_arrastrar`, crea un helper de server y
-- parcha por ancla tres funciones, con premisa de md5 sobre el cuerpo vivo
-- leído el 12/11 y poscondición de md5 y ACL.
-- Ensayo: scripts/test-arrastre-nc-y-piso-de-fecha-1542-1545.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · STK-11 · EL ARRASTRE NO VEÍA LAS NC DE LAS COMPRAS POSTERIORES
-- =========================================================================
-- Desde la 483 la NC de devolución corrige el promedio como una anulación
-- parcial de su compra (decisión del dueño, 10/11): la compra pasa a pesar lo
-- que le queda. Pero `_cpp_arrastrar`, que recorre las compras que entraron
-- después de la que se está corrigiendo, las seguía recorriendo con
-- `compra_items.cantidad`, la cantidad entera de la factura. Corregir, anular
-- o devolver una compra ANTERIOR a otra que ya tiene una NC diluía la
-- diferencia como si la posterior siguiera entera.
--
-- Ejemplo (producto con 50 u. a 8): compra B de 100 a 10 → 9,3333; compra A
-- de 100 a 20 → 13,6; NC de 50 de A → 12. Se anula B: quedan las 50 de antes
-- a 8 y las 50 de A a 20, el promedio es 14. Daba 14,4: el arrastre recorría
-- A con 100.
--
-- Ahora cada renglón de una compra posterior entra con lo que le queda:
-- `cantidad × (total − devuelto) / total`, donde `total` son las unidades de
-- ese producto en esa compra y `devuelto`, las de sus NC. Es el mismo reparto
-- proporcional de `_cpp_recorrer_compra_parcial` (483), y con un renglón (el
-- caso normal) es exacto. Con varios renglones del mismo producto, el stock
-- de antes de cada uno se corre por lo devuelto de los renglones anteriores
-- de su compra, como hace ese recorrido, y su promedio de antes sale de la
-- cadena y no de su foto, que se tomó con el renglón anterior entero. Un
-- renglón devuelto entero no mueve
-- el promedio: la cadena sigue con el promedio de antes de ese renglón (con
-- cantidad 0 `_cpp_linea` devolvería el costo del renglón si no había stock).
-- Las fotos (`stock_anterior`, `stock_nuevo`, `costo_promedio_anterior`) se
-- siguen reescribiendo igual que antes: son las de la factura.
--
-- Las dos historias (la vieja y la nueva) usan la misma cantidad, así que la
-- corrección sigue siendo por diferencia: la NC anterior a la 483, que no
-- corrigió el promedio, no se corrige ahora. En prod no hay nada que
-- reparar: hay una NC de devolución (3 productos) y ninguna compra anterior
-- de esos productos se corrigió ni se anuló después (leído el 12/11).
--
-- =========================================================================
-- 2 · GTO-A · EL PISO DE LA FECHA
-- =========================================================================
-- `_guardar_gasto`, `registrar_movimiento_empleado` y `liquidar_empleado`
-- sólo rechazaban la fecha futura. Un «2016» por «2026» pasaba, y como el mes
-- imputado se ata a la fecha (de −12 a +1 meses), el gasto caía en 2016 y
-- desaparecía de los meses corrientes; un adelanto, de la cuenta del período.
--
-- Decisión del dueño (12/11): la fecha puede ir hasta 60 días antes de hoy
-- (el día argentino), para todos, admin incluido. Es el tope que la 488 les
-- puso a los arreglos. La regla es una, `_fecha_carga_validar_piso`, con
-- espejo en `errorDeFechaVieja` (src/utils/personal.ts).
--   · El gasto: al cargarlo y al cambiarle la fecha. Un gasto viejo se sigue
--     pudiendo corregir sin tocarla.
--   · La fecha que sale de una rendición no se tipea, y no tiene piso: el
--     gasto de una rendición fechado en el día de esa rendición, y el pago
--     (suelto o de una liquidación) que sale de una rendición, cuya fecha es
--     el día de la rendición.
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
-- Premisa: los cuerpos vivos son los leídos el 12/11, y el helper no existe
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', 'df2a42359ed44361dcf7ff3c993c1e1a'),
    ('public._guardar_gasto(jsonb,boolean)',               '74d9dad6ee948932b1ca92f78f60fbdc'),
    ('public.registrar_movimiento_empleado(bigint,jsonb)', '1f86518d3219e900d71f0896aba69ad3'),
    ('public.liquidar_empleado(bigint,jsonb)',             '2661a83fdf94768f3f462148d1004afd')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public._fecha_carga_validar_piso(date,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · _fecha_carga_validar_piso ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · STK-11 · el arrastre recorre cada compra posterior con lo que le queda
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._cpp_arrastrar(p_producto bigint, p_sucursal bigint, p_compra bigint, p_desde timestamp with time zone, p_delta_stock integer, p_cpp_viejo numeric, p_cpp_nuevo numeric, OUT cpp_viejo numeric, OUT cpp_nuevo numeric)
 RETURNS record
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  r             record;
  v_antes_viejo numeric;
  v_antes_nuevo numeric;
  v_s_nuevo     integer;
  v_c_nuevo     numeric;
BEGIN
  cpp_viejo := p_cpp_viejo;
  cpp_nuevo := p_cpp_nuevo;

  /* mig 483 (STK-5, #1516) · LOS INGRESOS POR ENVÍO TAMBIÉN SON LA CADENA.
     Aceptar un envío mezcla el promedio del destino con el del origen
     (mig 286), con la misma cuenta que `_cpp_linea` con costo fijo: el stock
     de antes es `stock_destino_anterior` y el costo, `origen_costo_promedio`.
     El arrastre sólo recorría compras: editar o anular una compra corregía
     mal el promedio de un producto que después recibió un envío, y anular
     la primera compra lo dejaba en NULL aunque el envío trajera costo. Un
     ingreso sin costo (los anteriores a la 286, cuando aceptar no tocaba el
     promedio) no lo movió, así que no entra. No tiene foto del promedio: toma
     el valor de la cadena, como una línea anterior a la 236. Su lugar es la
     hora en que se aceptó. */
  /* #1542 (STK-11) · UNA COMPRA CON NC DE DEVOLUCIÓN PESA LO QUE LE QUEDA.
     La NC corrige el promedio como una anulación parcial de su compra
     (`_cpp_devolucion_compra`, 483): desde ahí esa compra es más chica. Acá se
     la recorría con la cantidad entera de la factura, y corregir una compra
     anterior diluía la diferencia de más. `q_queda` es lo que le queda a cada
     renglón, con lo devuelto repartido en proporción, como
     `_cpp_recorrer_compra_parcial`; `dev_antes`, lo devuelto de los renglones
     anteriores del mismo producto en esa compra, que corre el stock de antes
     de éste. Sin NC son la cantidad y 0. */
  FOR r IN
    SELECT x.* FROM (
      SELECT 'compra'::text AS tipo, ci.id, ci.created_at AS ts, ci.compra_id AS orden,
             ci.stock_anterior, ci.costo_promedio_anterior, ci.cantidad,
             COALESCE(ci.costo_real_unitario, ci.costo_neto_unitario,
                      ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)) AS costo,
             public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario) AS fija,
             CASE WHEN t.total > 0
                  THEN ci.cantidad::numeric * GREATEST(t.total - n.dev, 0) / t.total
                  ELSE ci.cantidad::numeric END AS q_queda,
             CASE WHEN t.total > 0
                  THEN t.antes * LEAST(n.dev, t.total) / t.total
                  ELSE 0::numeric END AS dev_antes
        FROM compra_items ci
        JOIN compras c ON c.id = ci.compra_id AND c.sucursal_id = ci.sucursal_id
       CROSS JOIN LATERAL (
              SELECT COALESCE(SUM(o.cantidad), 0)::numeric AS total,
                     COALESCE(SUM(o.cantidad) FILTER (WHERE o.id < ci.id), 0)::numeric AS antes
                FROM compra_items o
               WHERE o.compra_id = ci.compra_id
                 AND o.producto_id = ci.producto_id
                 AND o.sucursal_id = ci.sucursal_id) t
       CROSS JOIN LATERAL (
              SELECT COALESCE(SUM(nci.cantidad), 0)::numeric AS dev
                FROM nota_credito_items nci
                JOIN notas_credito nc ON nc.id = nci.nota_credito_id AND nc.sucursal_id = nci.sucursal_id
               WHERE nc.compra_id = ci.compra_id
                 AND nc.sucursal_id = ci.sucursal_id
                 AND nci.producto_id = ci.producto_id) n
       WHERE ci.producto_id = p_producto
         AND ci.sucursal_id = p_sucursal
         AND ci.compra_id <> p_compra
         AND c.estado <> 'cancelada'
         AND (ci.created_at, ci.compra_id) > (p_desde, p_compra)
      UNION ALL
      SELECT 'envio'::text, mi.id, m.resuelto_at, m.id,
             mi.stock_destino_anterior, NULL::numeric, mi.cantidad,
             mi.origen_costo_promedio, true,
             mi.cantidad::numeric, 0::numeric
        FROM movimiento_sucursal_items mi
        JOIN movimientos_sucursal m ON m.id = mi.movimiento_id
       WHERE mi.producto_destino_id = p_producto
         AND m.sucursal_destino_id = p_sucursal
         AND m.estado = 'aceptada'
         AND m.resuelto_at > p_desde
         AND mi.origen_costo_promedio > 0
         AND mi.stock_destino_anterior IS NOT NULL
    ) x
     ORDER BY x.ts, x.tipo, x.orden, x.id
  LOOP
    -- La foto de la linea; una linea anterior a la 236 no la tiene y toma el
    -- valor de la cadena. #1542: tampoco vale la foto de un renglón que viene
    -- después de otro del mismo producto y de la misma compra al que una NC le
    -- sacó unidades: se tomó con ese renglón entero.
    v_antes_viejo := COALESCE(CASE WHEN r.dev_antes > 0 THEN NULL ELSE r.costo_promedio_anterior END, cpp_viejo);
    v_antes_nuevo := CASE
      -- la historia nueva no tiene promedio: la linea arranca de cero
      WHEN COALESCE(cpp_nuevo, 0) <= 0 THEN 0
      -- la vieja no tenia: no hay diferencia que sumar, vale la nueva
      WHEN COALESCE(cpp_viejo, 0) <= 0 OR v_antes_viejo IS NULL THEN cpp_nuevo
      ELSE GREATEST(v_antes_viejo + (cpp_nuevo - cpp_viejo), 0)
    END;
    v_s_nuevo := r.stock_anterior + p_delta_stock;

    /* mig 417 (#1294) · la foto de la linea pasa a la historia corregida: el
       stock y el promedio con los que la recorre la historia nueva. Una linea
       sin foto del promedio (anterior a la 236) sigue sin ella. El stock no se
       recorta en 0: `_cpp_linea` ya lo trata como 0, y recortado pesaria mal
       en la correccion siguiente. */
    v_c_nuevo := CASE WHEN r.costo_promedio_anterior IS NOT NULL THEN v_antes_nuevo END;
    IF r.tipo = 'compra' THEN
      UPDATE compra_items
         SET stock_anterior          = v_s_nuevo,
             stock_nuevo             = v_s_nuevo + r.cantidad,
             costo_promedio_anterior = v_c_nuevo
       WHERE id = r.id
         AND (stock_anterior, costo_promedio_anterior) IS DISTINCT FROM (v_s_nuevo, v_c_nuevo);
    ELSE
      -- mig 483: el ingreso, igual: su stock de antes pasa a la historia
      -- corregida, o la segunda corrección lo pesaría con el de la primera.
      UPDATE movimiento_sucursal_items
         SET stock_destino_anterior = v_s_nuevo,
             stock_destino_nuevo    = v_s_nuevo + r.cantidad
       WHERE id = r.id
         AND stock_destino_anterior IS DISTINCT FROM v_s_nuevo;
    END IF;

    IF r.q_queda > 0 THEN
      cpp_viejo := public._cpp_linea(r.stock_anterior - r.dev_antes, v_antes_viejo, r.q_queda, r.costo, r.fija);
      cpp_nuevo := public._cpp_linea(v_s_nuevo - r.dev_antes, v_antes_nuevo, r.q_queda, r.costo, r.fija);
    ELSE
      -- #1542: el renglón se devolvió entero y no mueve el promedio.
      cpp_viejo := v_antes_viejo;
      cpp_nuevo := v_antes_nuevo;
    END IF;
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 · GTO-A · el piso de la fecha de carga
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._fecha_carga_validar_piso(p_fecha date, p_de_que text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
-- #1545 (GTO-A): la fecha de un gasto, de un movimiento de empleado y del pago de una liquidación
-- va hasta 60 días antes de hoy, el día argentino (decisión del dueño, 12/11), para todos. Un año
-- mal tipeado dejaba el gasto fuera de los meses corrientes. `p_de_que` completa el mensaje («del
-- gasto», «del movimiento», «del pago»). El espejo del front es errorDeFechaVieja
-- (src/utils/personal.ts), con el mismo mensaje.
DECLARE
  v_piso date := public._tablero_hoy() - 60;
BEGIN
  IF p_fecha < v_piso THEN
    RAISE EXCEPTION 'La fecha % no puede ser anterior al % (hasta 60 días antes de hoy)',
      p_de_que, to_char(v_piso, 'DD/MM/YYYY');
  END IF;
END
$function$;

REVOKE ALL ON FUNCTION public._fecha_carga_validar_piso(date, text) FROM PUBLIC, anon, authenticated;

-- _guardar_gasto: al cargar y al cambiar la fecha. El cuerpo vivo viene en CRLF: el ancla y el
-- reemplazo se escriben en LF y se pasan a CRLF.
DO $parche_gasto$
DECLARE
  v_def text := pg_get_functiondef('public._guardar_gasto(jsonb,boolean)'::regprocedure);
  v_a text := replace($a$  IF v_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del gasto no puede ser futura';
  END IF;$a$, E'\n', E'\r\n');
  v_r text := replace($r$  IF v_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del gasto no puede ser futura';
  END IF;
  -- #1545 (GTO-A): ni anterior a 60 días. Rige al cargar y al cambiar la fecha: un gasto viejo se
  -- sigue pudiendo corregir sin tocarla. La fecha de un gasto de una rendición que es el día de
  -- esa rendición no se tipea, y no tiene piso.
  IF (v_id IS NULL OR v_viejo.fecha IS DISTINCT FROM v_fecha)
     AND NOT (v_origen = 'rendicion' AND v_rend_f IS NOT NULL AND v_fecha = v_rend_f) THEN
    PERFORM public._fecha_carga_validar_piso(v_fecha, 'del gasto');
  END IF;$r$, E'\n', E'\r\n');
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · _guardar_gasto: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_gasto$;

-- registrar_movimiento_empleado: el cuerpo vivo está en LF.
DO $parche_movimiento$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_movimiento_empleado(bigint,jsonb)'::regprocedure);
  v_a text := $a$  IF v_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del movimiento no puede ser futura';
  END IF;$a$;
  v_r text := $r$  IF v_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del movimiento no puede ser futura';
  END IF;
  -- #1545 (GTO-A): ni anterior a 60 días. El pago que sale de una rendición lleva el día de esa
  -- rendición (arriba), que no se tipea: no tiene piso.
  IF v_rf IS NULL THEN
    PERFORM public._fecha_carga_validar_piso(v_fecha, 'del movimiento');
  END IF;$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · registrar_movimiento_empleado: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_movimiento$;

-- liquidar_empleado: el cuerpo vivo viene en CRLF. El piso va después de saber de qué plata sale:
-- con una rendición la fecha del pago es el día de la rendición.
DO $parche_liquidar$
DECLARE
  v_def text := pg_get_functiondef('public.liquidar_empleado(bigint,jsonb)'::regprocedure);
  v_a text := replace($a$  IF v_pago > 0 THEN
    SELECT * INTO v_rend FROM public._pago_de_rendicion(p_liquidacion);
    v_fpago := COALESCE(v_rend.fecha, v_fpago);
  END IF;$a$, E'\n', E'\r\n');
  v_r text := replace($r$  IF v_pago > 0 THEN
    SELECT * INTO v_rend FROM public._pago_de_rendicion(p_liquidacion);
    v_fpago := COALESCE(v_rend.fecha, v_fpago);
    -- #1545 (GTO-A): ni anterior a 60 días, salvo el día de la rendición de la que sale, que no
    -- se tipea.
    IF v_rend.fecha IS NULL THEN
      PERFORM public._fecha_carga_validar_piso(v_fpago, 'del pago');
    END IF;
  ELSE
    -- #1545 (GTO-A): sin pago la fecha queda igual en la liquidación.
    PERFORM public._fecha_carga_validar_piso(v_fpago, 'del pago');
  END IF;$r$, E'\n', E'\r\n');
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · liquidar_empleado: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_liquidar$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', '7c8743b01b69353d8ae70097dc248232', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._fecha_carga_validar_piso(date,text)', '5ebf1dc12c2c1b4b2875aebb9692a74a', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._guardar_gasto(jsonb,boolean)', '093729c4cdcb0fcedc148ecdaeb2e4b3', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.registrar_movimiento_empleado(bigint,jsonb)', '86f8222bfa56d02fd9955177e39f7718', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.liquidar_empleado(bigint,jsonb)', 'c29edc547e9b788a1e30e89a7f37b51f', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
