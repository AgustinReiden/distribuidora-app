-- =========================================================================
-- NNN · EL REGALO ALCANZADO POR UN DESCUENTO, LA DEVOLUCIÓN QUE PASA EL
--       TOTAL DE LA COMPRA Y EL BOT QUE PARTE A UN PROVEEDOR RENOMBRADO
--       (cierre de la tanda #1565: los tres hallazgos medios de compras de
--        la lente adversarial; H3 es una regresión de la 499, H2 completa el
--        CMP-2 de la 496 y H1 lo causa la 496)
--
-- Parcha por ancla `_compra_costo_real_sin_piso`, `registrar_compra_completa`,
-- `actualizar_compra_items`, `registrar_nota_credito`,
-- `registrar_nota_credito_lote` y `bot_compras_periodo`, con premisa de md5
-- sobre los cuerpos vivos leídos el 13/11 (en LF) y poscondición de md5,
-- definer y ACL (no cambian ni las firmas ni los permisos).
-- Ensayo: scripts/test-compras-regalo-devolucion-y-bot-1565.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · H3 · EL REGALO QUE ALCANZA UN DESCUENTO PRORRATEADO (regresión de la 499)
-- =========================================================================
-- El piso de la 499 (CMP-3) rechazaba todo renglón que el motor dejaba con
-- costo real negativo, y también uno legítimo que antes entraba: 10 × 100
-- pagado más 5 × 100 de regalo (bonificación del 100 %) con un descuento de
-- −150 prorrateado por cantidad con los pesos que pre-llena el modal (10 y
-- 5). Al regalo le tocan −50 y queda en −10 por unidad, y la compra se
-- rechazaba culpando a un renglón que no pagó nada.
-- El regalo no fija costo: no pisa la reposición, no entra al promedio con su
-- costo (`_cpp_linea` con `fija = false` sólo diluye) y lo saltean
-- `_reposicion_desde_ultima_compra`, `_ninguna_compra_mas_nueva`, la foto de
-- la edición y el costo anterior del modal. Lo único que lee su costo real
-- es COMPRA-C (high), que desde la 499 cuenta todo costo real negativo.
--   · El piso ya no mira el costo real negativo de un renglón bonificado al
--     100 %. Un renglón pagado que queda negativo (el CMP-3 original) o en 0
--     se sigue rechazando.
--   · El alta y la edición guardan en 0 el costo real negativo de un regalo,
--     para no dejar un costo negativo en `compra_items` (COMPRA-C no cambia).
--     Sus cargos (`cargos_unitarios`) quedan como los reparte el motor: son
--     los que COMPRA-A3 compara contra los repartos.
-- Contra antes de la tanda, medido con el cuerpo de entonces: el renglón pagado
-- (costo real 90, cargos −10) y los productos (reposición 90, sin IVA 100,
-- promedio 90; el regalo suma 5 al stock sin costo) dan lo mismo. Cambia un
-- número: el costo real guardado del renglón de regalo, 0 en vez de −10.
--
-- =========================================================================
-- 2 · H2 · LA DEVOLUCIÓN NO PASA LO QUE LE QUEDA A LA COMPRA (CMP-2 de la 496)
-- =========================================================================
-- El tope de la 496 (la nota ≤ total de la compra − sus notas) vivía sólo en
-- la rama `ajuste` de `registrar_nota_credito`. Sobre una compra de 10 × 100
-- = 1.000 entraba un ajuste de 800 y después la devolución de las 10 u.: 1.800
-- acreditados sobre 1.000. Al revés ya se rechazaba.
-- Decisión del dueño (13/11): «Topearla: la devolución se rechaza si con ella
-- las notas superan el total de la compra, con un mensaje que dice cuánto le
-- queda. Para devolver todo hay que anular antes el ajuste.» Hoy una nota de
-- crédito de compra no se puede anular por ningún camino, y el dueño lo
-- confirmó sabiéndolo (13/11): se prioriza no acreditar de más. Lo que exceda
-- lo que le queda a la compra no se devuelve por nota hasta que exista esa
-- anulación (#1590).
--   · En los dos caminos que registran una devolución de compra
--     (`registrar_nota_credito` con renglones y `registrar_nota_credito_lote`),
--     con la misma cuenta y el mismo redondeo que el ajuste de la 496: lo que
--     le queda es el total de la compra menos todas sus notas (no hay notas
--     anuladas: las de compra no se anulan), y la devolución entra si su total
--     es ≤ eso (la que entra justo, pasa).
--   · Rige si la compra tiene una nota de ajuste. Sin ajustes, la devolución
--     de toda la mercadería tiene que entrar siempre, y puede acreditar más que
--     el total de la compra: no descuenta la bonificación de cabecera ni los
--     descuentos prorrateados, y el IVA va por renglón (medido: FC A con
--     bonificación de cabecera −100 acredita 1.296,96 sobre 1.255,96; ZZ con
--     un descuento de −150, 1.000 sobre 850; el IVA por renglón o la devolución
--     en dos partes, un centavo arriba). Sin ajustes, lo que acreditan las
--     devoluciones ya lo topa la cantidad comprada, como antes.
--   · La nota por lote toma ahora TODAS las líneas de la compra, como
--     `registrar_nota_credito`, y no sólo las de su producto: dos devoluciones
--     por lote de productos distintos de la misma compra no se esperaban, y
--     las dos podían contar las mismas notas. Mismo orden de locks que antes:
--     compra → producto → líneas de la compra (por id) → lote.
--
-- =========================================================================
-- 3 · H1 · EL BOT PARTÍA A UN PROVEEDOR RENOMBRADO (lo causa la 496)
-- =========================================================================
-- `bot_compras_periodo` agrupaba por `proveedor_id, pr.nombre,
-- proveedor_nombre, pr.cuit`. Desde la 496 cada compra guarda el nombre que
-- tenía el proveedor al comprar, y después de renombrarlo el top salía partido
-- en dos filas (y con el LIMIT se podía caer). Ahora es una fila por
-- proveedor: el vivo va por su id, con su nombre de hoy; las compras sin
-- proveedor (uno eliminado, o uno suelto) van por el nombre guardado. Sigue
-- siendo sólo de server: los permisos no cambian.
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
-- Premisa: los cuerpos vivos son los leídos el 13/11, en LF
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._compra_costo_real_sin_piso(jsonb,jsonb,bigint)', 'd0c17f7b147cbadb8fedfb6b0c76e572'),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     'eedd880741ed76435df7a36011443aff'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     '5932f8184bc0f0e19ed7ad9fe2d230ae'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
     '0d8e6a37766fc3f010e3fb34aeab14df'),
    ('public.registrar_nota_credito_lote(bigint,numeric,text,text)', '6f8b92d6b3cb32ceb1bcc4267bf0e752'),
    ('public.bot_compras_periodo(date,date,bigint,integer)', 'e0b3e70ecb3beb632ed4c05b2158749f')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- El parche por ancla: cada ancla aparece exactamente una vez
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.parchar(p_f text, p_par text[][]) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_def text := pg_get_functiondef(p_f::regprocedure);
  v_n int;
  i int;
BEGIN
  IF position(E'\r' in v_def) > 0 THEN
    RAISE EXCEPTION 'mig NNN · % viene en CRLF: las anclas son LF', p_f;
  END IF;
  FOR i IN 1 .. array_length(p_par, 1) LOOP
    v_n := (length(v_def) - length(replace(v_def, p_par[i][1], ''))) / length(p_par[i][1]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig NNN · %: el ancla % aparece % vez/veces y se esperaba 1', p_f, i, v_n;
    END IF;
    v_def := replace(v_def, p_par[i][1], p_par[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$f$;

-- ---------------------------------------------------------------------------
-- 1 · H3 · el piso no mira el costo real negativo del regalo
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public._compra_costo_real_sin_piso(jsonb,jsonb,bigint)', ARRAY[
  [$a$   WHERE round((l->>'costo_real')::NUMERIC, 4) < 0
      OR (round((l->>'costo_real')::NUMERIC, 4) = 0$a$,
   $r$   WHERE (round((l->>'costo_real')::NUMERIC, 4) < 0
          /* mig NNN (#1565) · el regalo (bonificacion del 100 %) no fija costo: la
             parte de un descuento prorrateado que le toca no lo rechaza (el alta
             y la edicion guardan su costo real en 0). */
          AND COALESCE((x.it->>'bonificacion')::NUMERIC, 0) < 100)
      OR (round((l->>'costo_real')::NUMERIC, 4) = 0$r$]
]);

-- ---------------------------------------------------------------------------
-- 1 · H3 · el alta y la edición guardan en 0 el costo real negativo del regalo
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar(f, ARRAY[
  [$a$      v_cargo_unit  := round((v_linea_costos->>'cargos')::NUMERIC, 4);
      v_costo_real  := round((v_linea_costos->>'costo_real')::NUMERIC, 4);$a$,
   $r$      v_cargo_unit  := round((v_linea_costos->>'cargos')::NUMERIC, 4);
      v_costo_real  := round((v_linea_costos->>'costo_real')::NUMERIC, 4);
      /* mig NNN (#1565) · el regalo (bonificacion del 100 %) no fija costo, y un
         descuento prorrateado que lo alcanza no le deja el costo real negativo:
         se guarda en 0. Sus cargos quedan como los reparte el motor (COMPRA-A3). */
      IF v_bonificacion >= 100 AND v_costo_real < 0 THEN
        v_costo_real := 0;
      END IF;$r$]
])
  FROM unnest(ARRAY[
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])'
  ]) AS f;

-- ---------------------------------------------------------------------------
-- 2 · H2 · registrar_nota_credito: la devolución, con el tope del ajuste
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)', ARRAY[
  [$a$    v_ii    := public.ii_nota_credito_compra(p_compra_id, v_sucursal, v_items);
    v_total := v_subtotal + v_iva + v_ii;
  END IF;$a$,
   $r$    v_ii    := public.ii_nota_credito_compra(p_compra_id, v_sucursal, v_items);
    v_total := v_subtotal + v_iva + v_ii;

    /* mig NNN (#1565) · LA DEVOLUCION NO PASA LO QUE LE QUEDA A LA COMPRA si la
       compra tiene un ajuste (decision del dueño, 13/11). Un ajuste de 800 y
       despues la devolucion de las 10 u. de una compra de 1.000 acreditaban
       1.800. La cuenta y el redondeo son los del ajuste (#1557): el total de la
       compra menos todas sus notas, y entra la que da justo. Sin ajustes no
       rige: devolver toda la mercaderia entra siempre, aunque acredite mas que
       el total (la bonificacion de cabecera y los descuentos no se descuentan,
       y el IVA va por renglon); ahi el tope es la cantidad, de mas arriba. El
       FOR UPDATE de las lineas de la compra serializa las notas. */
    IF EXISTS (SELECT 1 FROM notas_credito nc
                WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
                  AND nc.tipo = 'ajuste') THEN
      SELECT c.total - COALESCE((SELECT sum(nc.total) FROM notas_credito nc
                                  WHERE nc.compra_id = c.id AND nc.sucursal_id = c.sucursal_id), 0)
        INTO v_resta
        FROM compras c
       WHERE c.id = p_compra_id AND c.sucursal_id = v_sucursal;

      IF NOT (v_total <= v_resta) THEN
        RETURN jsonb_build_object('success', false, 'error',
          format('La devolución (%s) supera lo que le queda a la compra (%s, su total menos las notas que ya tiene, '
                 || 'contando los ajustes). Si la pantalla mostraba otro máximo, recargala: puede haber otra nota de crédito sobre esta compra.',
                 v_total, GREATEST(v_resta, 0)));
      END IF;
    END IF;
  END IF;$r$]
]);

-- ---------------------------------------------------------------------------
-- 2 · H2 · registrar_nota_credito_lote: las líneas de toda la compra, y el tope
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public.registrar_nota_credito_lote(bigint,numeric,text,text)', ARRAY[
  [$a$  v_aviso      text;     -- mig 483$a$,
   $r$  v_aviso      text;     -- mig 483
  v_resta      numeric;  -- mig NNN (#1565)$r$],
  [$a$    IF v_compra_id IS NOT NULL THEN
      PERFORM 1 FROM public.compra_items
       WHERE compra_id = v_compra_id
         AND producto_id = v_producto_id
         AND sucursal_id = v_sucursal
       ORDER BY id
         FOR UPDATE;
    END IF;$a$,
   $r$    IF v_compra_id IS NOT NULL THEN
      -- mig NNN (#1565): TODAS las lineas de la compra, como registrar_nota_credito:
      -- el tope de lo que le queda a la compra cuenta las notas de todos sus
      -- productos, y dos notas por lote de productos distintos no se esperaban.
      PERFORM 1 FROM public.compra_items
       WHERE compra_id = v_compra_id
         AND sucursal_id = v_sucursal
       ORDER BY id
         FOR UPDATE;
    END IF;$r$],
  [$a$  v_ii       := public.ii_nota_credito_compra(v_lote.compra_id, v_sucursal,
                  jsonb_build_array(jsonb_build_object('producto_id', v_lote.producto_id, 'cantidad', v_cant)));$a$,
   $r$  v_ii       := public.ii_nota_credito_compra(v_lote.compra_id, v_sucursal,
                  jsonb_build_array(jsonb_build_object('producto_id', v_lote.producto_id, 'cantidad', v_cant)));

  -- mig NNN (#1565): la devolucion no pasa lo que le queda a la compra si la
  -- compra tiene un ajuste (decision del dueño, 13/11), con la cuenta de
  -- registrar_nota_credito. Sin ajustes no rige: el tope es la cantidad.
  IF EXISTS (SELECT 1 FROM public.notas_credito nc
              WHERE nc.compra_id = v_lote.compra_id AND nc.sucursal_id = v_sucursal
                AND nc.tipo = 'ajuste') THEN
    SELECT c.total - COALESCE((SELECT sum(nc.total) FROM public.notas_credito nc
                                WHERE nc.compra_id = c.id AND nc.sucursal_id = c.sucursal_id), 0)
      INTO v_resta
      FROM public.compras c
     WHERE c.id = v_lote.compra_id AND c.sucursal_id = v_sucursal;

    IF NOT (v_subtotal + v_iva + v_ii <= v_resta) THEN
      RAISE EXCEPTION 'La devolución (%) supera lo que le queda a la compra (%, su total menos las notas que ya tiene, contando los ajustes). Si la pantalla mostraba otro máximo, recargala: puede haber otra nota de crédito sobre esta compra.',
        v_subtotal + v_iva + v_ii, GREATEST(v_resta, 0);
    END IF;
  END IF;$r$]
]);

-- ---------------------------------------------------------------------------
-- 3 · H1 · bot_compras_periodo: una fila por proveedor
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public.bot_compras_periodo(date,date,bigint,integer)', ARRAY[
  [$a$    SELECT cf.proveedor_id,
      COALESCE(pr.nombre, cf.proveedor_nombre, 'Sin nombre') AS nombre,
      pr.cuit, SUM(cf.total) AS total_comprado, COUNT(*) AS compras_count
    FROM compras_filtradas cf
    LEFT JOIN proveedores pr ON pr.id = cf.proveedor_id
    GROUP BY cf.proveedor_id, pr.nombre, cf.proveedor_nombre, pr.cuit$a$,
   $r$    /* mig NNN (#1565) · UNA FILA POR PROVEEDOR. Desde la 496 cada compra guarda
       el nombre que tenia el proveedor al comprar, y agrupar por ese nombre
       partia en dos a un proveedor renombrado. El vivo va por su id, con el
       nombre de hoy; una compra sin proveedor (eliminado o suelto), por el
       nombre guardado. */
    SELECT cf.proveedor_id,
      COALESCE(pr.nombre, max(cf.proveedor_nombre), 'Sin nombre') AS nombre,
      pr.cuit, SUM(cf.total) AS total_comprado, COUNT(*) AS compras_count
    FROM compras_filtradas cf
    LEFT JOIN proveedores pr ON pr.id = cf.proveedor_id
    GROUP BY cf.proveedor_id, pr.nombre, pr.cuit,
             CASE WHEN cf.proveedor_id IS NULL THEN cf.proveedor_nombre END$r$]
]);

DROP FUNCTION pg_temp.parchar(text, text[]);

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._compra_costo_real_sin_piso(jsonb,jsonb,bigint)', 'ad3e7fcd2410715579c40a9423cfc24f', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     '4e9ff35ed6e79402471f91c1277ba124', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     '5d04d79637c0ff57d15213f9479dd2ce', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
     '6f1ef71ffd327350df3155c349566670', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_nota_credito_lote(bigint,numeric,text,text)', 'ef8ac9ee30035f126cde426684a9ceb3', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.bot_compras_periodo(date,date,bigint,integer)', '0dfd5cce59b338cefdad132eaa33638c', true,
     '{postgres=X/postgres,service_role=X/postgres}')
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
