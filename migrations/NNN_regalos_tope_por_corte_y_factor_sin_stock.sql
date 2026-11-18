-- =========================================================================
-- NNN · LOS RESIDUALES DE REGALOS Y PROMOS: EL TOPE DE UN REGALO CAMBIADO
--       POR VALOR EN LA EDICIÓN Y LA RENORMALIZACIÓN DE LA BARRA SIN STOCK
--       (ola 2 del plan #1603, tanda 5, tarjeta C2: PRM-1 y PRM-2 de #1592,
--        H3 de la revisión de B4 y N2 de la revisión de B1)
--
-- Parcha por ancla, con premisa de md5 sobre los cuerpos vivos (ledger en la
-- 530), dos funciones: `actualizar_pedido_items` (sólo su tramo de regalos) y
-- `renormalizar_bloques_por_cambio_factor`. No crea funciones, no cambia firmas
-- ni permisos y no toca tablas (sin locks de tabla). Las dos son SECURITY
-- DEFINER y quedan con `search_path = public, pg_temp` (regla de la 531). Ensayo: scripts/test-regalos-residuales-ola2-1603.sql.
-- Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- 1 · PRM-1 residual (#1592; H3 de la revisión de B4): el tope del regalo de la
--     promo se mide en su corte también cuando el llamador manda la línea
--     cambiada por valor tal como está
-- -------------------------------------------------------------------------
-- Regla del dueño (16/11): el regalo se mide siempre contra el regalo que da
-- la promo, en la cantidad del corte. Promo 2 V → 1 R; el pedido lleva V×20 y
-- R×10, cambiado por valor a W×1 (W vale lo que 10 R). El encargado baja la
-- venta a V×10 (le tocan R×5) y manda el regalo como está, W×1. 1592-b1 (la
-- 519) entiende esa línea como «la de hoy» y la guarda con su corte, 10; pero
-- el tope de `regalo_fuera_de_promo` se medía sobre lo crudo (1 ≤ 5) y
-- entraba: el pedido quedaba con un regalo que vale R×10 contra un derecho de
-- R×5, y el cupo de la promo contaba 10. Mandado en la unidad de la promo
-- (R×10, lo que manda el front) se rechazaba bien. Ahora la edición mide el
-- tope dos veces: sobre lo crudo, como antes, y, si 1592-b1 llevó algún regalo
-- a su corte, sobre lo que mandó el llamador con ese regalo en su corte. El
-- rechazo lo explica («un regalo cambiado por otro producto cuenta como el
-- regalo que reemplazó»). El admin sigue sin tope. El front de hoy manda el
-- corte (`cantidadBaseDeLinea`), así que no le cambia nada: lo ve un bundle
-- viejo o una llamada directa.
--
-- -------------------------------------------------------------------------
-- 2 · PRM-2 residual (#1592; N2 de la segunda revisión de B1): el cambio de
--     factor sin stock en el contenedor se rechaza con su motivo
-- -------------------------------------------------------------------------
-- Con la barra pasada de N (la deja la 520 cuando el recierre de una baja no
-- tiene stock) y el contenedor en 0, cambiar el factor de la promo cierra
-- bloques que no se pueden descontar. Desde la 472 el front guarda por
-- `cambiar_regalo_promocion`, que atrapa el CHECK `productos_stock_no_negativo`
-- y devuelve `contenedor_sin_stock` con el nombre del contenedor; un UPDATE
-- directo (un bundle anterior a la 472, o a mano) recibía el texto crudo del
-- CHECK. Ahora `renormalizar_bloques_por_cambio_factor` rechaza antes de bajar
-- el contenedor, con el motivo en castellano, y con el mismo código, la misma
-- restricción y el id del contenedor en el DETAIL: la RPC sigue devolviendo lo
-- de siempre. El comportamiento no cambia (el cambio de factor sin stock se
-- rechaza, como dice la 472). Que la renormalización cierre sólo lo que el
-- contenedor da y deje el resto en la barra es otro comportamiento, y queda
-- para el dueño. La venta con regalo de esa promo sigue rechazando por stock
-- mientras el contenedor esté en 0: es la regla escrita de la 520 («sólo el
-- alta rechaza por stock insuficiente»).
--
-- Revertir: volver las dos funciones a los cuerpos de la premisa (y su
-- `search_path` a `public`).
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
-- Premisas: los cuerpos vivos (ledger en la 530) y lo que el arreglo usa tal
-- como está (la regla del tope de la promo y la del sustituto).
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'ab1726cabaf6d2d324cf71cd522385ee'),
    ('public.renormalizar_bloques_por_cambio_factor()', '2b282b2a6629e3b067f4de39157889e9'),
    ('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', '29f0aa33fd68e34746cb959550f6212f')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
END
$premisas$;

-- Los tramos que se cambian: la función, el ancla y su reemplazo. La
-- poscondición los vuelve a poner al revés y compara con el md5 de la premisa.
CREATE TEMP TABLE c2_tramos (ord int PRIMARY KEY, fn text, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO c2_tramos VALUES
-- 1 · PRM-1 residual
(1, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'declaraciones',
$a$  v_cadena       UUID;
$a$,
$r$  v_cadena       UUID;
  -- PRM-1 residual (#1592, C2 de la ola 2 de #1603): el JSON antes de 1592-b1, y lo
  -- que mandó el llamador con cada regalo que 1592-b1 llevó a su corte.
  v_items_pre    JSONB;
  v_cant_corte   JSONB;
$r$),
(2, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'antes de 1592-b1',
$a$  SELECT COALESCE(jsonb_agg(CASE WHEN l.corte IS NOT NULL
$a$,
$r$  v_items_pre := v_items;
  SELECT COALESCE(jsonb_agg(CASE WHEN l.corte IS NOT NULL
$r$),
(3, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'después de 1592-b1',
$a$    ) l ON true;
$a$,
$r$    ) l ON true;

  -- PRM-1 residual (#1592; H3 de la revisión de B4): el tope de la promo va en su
  -- corte. Un regalo que 1592-b1 llevó a su corte (W×1 que vale R×10 queda con corte
  -- 10) se medía crudo (1) contra el tope: con la venta a la baja, R×5 de derecho,
  -- entraba con un regalo de R×10. v_cant_corte es lo que mandó el llamador con esos
  -- regalos en su corte (NULL si no hay ninguno). 1592-b1 sólo toca una promo con una
  -- línea en el pedido y una en el JSON, que no pasó por el reparto conservado: su
  -- elemento de v_items es el de p_items_nuevos.
  WITH conv AS (
    SELECT b.e, b.o
      FROM jsonb_array_elements(v_items) WITH ORDINALITY AS b(e, o)
      JOIN jsonb_array_elements(v_items_pre) WITH ORDINALITY AS a(e, o) ON a.o = b.o
     WHERE a.e->>'cantidad' IS DISTINCT FROM b.e->>'cantidad')
  SELECT CASE WHEN EXISTS (SELECT 1 FROM conv) THEN
           COALESCE((SELECT jsonb_agg(x.e ORDER BY x.o)
                       FROM jsonb_array_elements(p_items_nuevos) WITH ORDINALITY AS x(e, o)
                      WHERE NOT (COALESCE((x.e->>'es_bonificacion')::BOOLEAN, false)
                                 AND NULLIF(x.e->>'promocion_id', '')::BIGINT IN
                                     (SELECT (c.e->>'promocion_id')::BIGINT FROM conv c))), '[]'::jsonb)
           || (SELECT jsonb_agg(c.e ORDER BY c.o) FROM conv c)
         END
    INTO v_cant_corte;
$r$),
(4, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'el tope en el corte',
$a$      IF v_motivo_regalo IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_regalo || ' El pedido no se modificó.'));
      END IF;
$a$,
$r$      IF v_motivo_regalo IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_regalo || ' El pedido no se modificó.'));
      END IF;
      -- PRM-1 residual: y con el regalo cambiado por valor en su corte. Lo demás que
      -- mira (la promo, su vigencia, el producto, la exclusión) ya pasó arriba con lo
      -- mismo: sólo puede fallar la cantidad.
      IF v_cant_corte IS NOT NULL THEN
        v_motivo_regalo := public.regalo_fuera_de_promo(
          (SELECT COALESCE(jsonb_agg(x.e ORDER BY x.o), '[]'::jsonb)
             FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o)
            WHERE x.e->>'_reparto' IS DISTINCT FROM v_marca_reparto),
          v_cant_corte, v_sucursal, p_pedido_id,
          (SELECT fecha FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal));
        IF v_motivo_regalo IS NOT NULL THEN
          RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
            'Un regalo cambiado por otro producto cuenta, para el tope de la promo, como el regalo que reemplazó: '
            || v_motivo_regalo || ' El pedido no se modificó.'));
        END IF;
      END IF;
$r$),
-- 2 · PRM-2 residual
(5, 'public.renormalizar_bloques_por_cambio_factor()', 'el rechazo con su motivo',
$a$    v_stock_nue := COALESCE(v_stock_ant, 0) - v_unidades;
$a$,
$r$    v_stock_nue := COALESCE(v_stock_ant, 0) - v_unidades;
    -- PRM-2 residual (#1592; N2 de la revisión de B1): el contenedor no alcanza para los
    -- bloques que cierra el factor nuevo. Se rechaza como siempre, pero con su motivo y no
    -- con el texto crudo del CHECK. Va como ese CHECK (23514, productos_stock_no_negativo, y
    -- el id del contenedor en el DETAIL), que es lo que mira cambiar_regalo_promocion (472)
    -- para devolver su contenedor_sin_stock.
    IF v_stock_nue < 0 THEN
      RAISE EXCEPTION USING
        ERRCODE    = 'check_violation',
        CONSTRAINT = 'productos_stock_no_negativo',
        MESSAGE    = format('El contenedor «%s» no tiene stock para el factor nuevo de la promoción (hay %s, y el cambio cierra %s %s que %s %s). No se guardó el cambio: reponé el contenedor o elegí otro factor.',
                            COALESCE((SELECT nombre FROM productos
                                       WHERE id = v_barra.contenedor AND sucursal_id = NEW.sucursal_id),
                                     'ID ' || v_barra.contenedor),
                            COALESCE(v_stock_ant, 0), v_bloques,
                            CASE WHEN v_bloques = 1 THEN 'bloque' ELSE 'bloques' END,
                            CASE WHEN v_bloques = 1 THEN 'descuenta' ELSE 'descuentan' END, v_unidades),
        DETAIL     = format('Contenedor (%s, stock %s, pide %s).', v_barra.contenedor, COALESCE(v_stock_ant, 0), v_unidades);
    END IF;
$r$);

-- =========================================================================
-- El parche: cada función con sus tramos, y su search_path con pg_temp al final
-- =========================================================================
DO $parche$
DECLARE
  f     text;
  v_def text;
  r     record;
  v_n   int;
BEGIN
  FOR f IN SELECT DISTINCT fn FROM c2_tramos ORDER BY 1 LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    FOR r IN SELECT * FROM c2_tramos WHERE fn = f ORDER BY ord LOOP
      v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el ancla aparece % vez/veces y se esperaba 1', f, r.que, v_n;
      END IF;
      v_def := replace(v_def, r.ancla, r.nuevo);
    END LOOP;
    -- 531 (B15): una definer lleva pg_temp al final de su search_path. Un CREATE OR
    -- REPLACE sin la cláusula SET la borraría: va la de antes, con pg_temp.
    v_n := (length(v_def) - length(replace(v_def, E' SET search_path TO ''public''\n', ''))) / length(E' SET search_path TO ''public''\n');
    IF v_n = 1 THEN
      v_def := replace(v_def, E' SET search_path TO ''public''\n', E' SET search_path TO ''public'', ''pg_temp''\n');
    ELSIF position(E' SET search_path TO ''public'', ''pg_temp''\n' IN v_def) = 0 THEN
      RAISE EXCEPTION 'mig NNN · %: no encuentro su search_path', f;
    END IF;
    EXECUTE v_def;
  END LOOP;
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos nuevos son los del repo, el resto de cada cuerpo no
-- cambió (deshaciendo sus tramos vuelve el md5 de la premisa), y el definer, el
-- search_path y los EXECUTE son los de antes, con pg_temp.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text;
  r     record;
  t     record;
  x     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
     '9d30c7d5b133a8c560daa0081ae52694', 'ab1726cabaf6d2d324cf71cd522385ee',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.renormalizar_bloques_por_cambio_factor()',
     '61e0ed9c7ab53c79e95c9ebfaf64e446', '2b282b2a6629e3b067f4de39157889e9',
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS v(fn, h, h_antes, acl) LOOP
    SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR NOT x.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
    v_src := x.prosrc;
    FOR t IN SELECT * FROM c2_tramos WHERE fn = r.fn ORDER BY ord DESC LOOP
      IF (length(v_src) - length(replace(v_src, t.nuevo, ''))) / length(t.nuevo) <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el tramo nuevo no aparece una vez', r.fn, t.que;
      END IF;
      v_src := replace(v_src, t.nuevo, t.ancla);
    END LOOP;
    IF md5(v_src) IS DISTINCT FROM r.h_antes THEN
      RAISE EXCEPTION 'mig NNN · % cambió fuera de sus tramos (md5 sin el parche %)', r.fn, md5(v_src);
    END IF;
  END LOOP;
END
$post$;

COMMIT;
