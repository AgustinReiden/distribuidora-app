-- =========================================================================
-- NNN · EL REGALO DENTRO DE LA FACTURA Y LOS CARGOS DE UNA ZZ
--       (plan #1603, tarjeta M2: los medios CMP-A y CMP-B de #1593 y los
--        bajos 1593-b2, 1593-b4, 1557-c3 y 1557-c4)
--
-- Parcha por ancla `registrar_compra_completa`, `actualizar_compra_items`,
-- `calcular_costos_compra`, `_compra_renglones_fuera_de_rango` y
-- `auditoria_integridad`, con premisa de md5 sobre los cuerpos vivos (los de
-- la 503, en LF) y poscondición de md5, definer y ACL (no cambian ni las
-- firmas ni los permisos). Crea `_pesos_entre_pagados`.
-- Ensayo: scripts/test-compras-regalo-orden-y-cargos-zz-1593.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · CMP-A · EL PROMEDIO DE UNA FACTURA NO DEPENDE DEL ORDEN DE SUS RENGLONES
-- =========================================================================
-- `_cpp_linea` sin costo fijo (un regalo) sobre un producto agotado o sin
-- promedio devuelve el promedio tal cual: no hay nada que diluir. Las
-- unidades del regalo entraban al stock y el renglón pagado de después se
-- promediaba con ellas al promedio viejo: 10 u. de regalo y después 10 u. a
-- 100 daban 90 (agotado con un promedio de 80) o 100 (producto nuevo); en el
-- otro orden, 50, el prorrateo de la factura entera. `costo_valuacion`
-- congela ese número en la venta.
--   · El alta y la edición recorren los renglones de la factura con los que
--     fijan costo primero y los regalos después (el mismo umbral de la cadena,
--     `_cpp_fija_costo`), y los insertan en ese orden. Los pesos de los cargos
--     siguen yendo por el índice del payload.
--   · La cadena (`_cpp_recorrer_compra`, `_cpp_recorrer_compra_parcial`,
--     `_cpp_foto_compra`, `_cpp_arrastrar`) no cambia: recorre una compra por
--     id, y desde acá el id ya es ese orden. Una compra vieja se sigue
--     recorriendo como se registró, que es lo que tiene el promedio vivo: la
--     corrección por diferencia sigue cerrando contra él.
--   · Consecuencia visible: el detalle de la compra muestra los regalos
--     después de los renglones pagados.
-- En prod no hay ninguna compra viva con un regalo antes que un renglón pagado
-- del mismo producto (la premisa lo cuenta y lo avisa): no hay datos que rehacer.
--
-- =========================================================================
-- 2 · 1593-b4 · EL UMBRAL DE REGALO ES UNO
-- =========================================================================
-- Una bonificación de 99,999 % sobre un costo de 1 deja el costo neto en
-- 0,00001: el alta lo tomaba como renglón pagado (`v_costo_neto > 0`, sin
-- redondear) y le fijaba promedio y reposición en 0; la cadena, como regalo
-- (`_cpp_fija_costo`, sobre el neto guardado a 4 decimales). COMPRA-C (high)
-- lo contaba.
--   · El alta y la edición deciden con `_cpp_fija_costo` sobre el neto que se
--     guarda, como la cadena.
--   · Y los rangos del renglón rechazan una bonificación menor al 100 % que
--     deja el costo neto en 0 (a 4 decimales), como ya rechazaban el costo 0
--     (CMP-5): el regalo legal es la bonificación del 100 %.
--
-- =========================================================================
-- 3 · 1593-b2 / 1557-c4 · UN CARGO SE REPARTE ENTRE LOS RENGLONES PAGADOS
-- =========================================================================
-- El modal pre-llena los pesos de un cargo por cantidad, regalos incluidos. La
-- parte de un flete o de un descuento que le tocaba a un regalo se perdía: el
-- regalo no fija costo. 10 u. a 100 y 10 de regalo con un flete de 300 dejaban
-- el pagado en 115 (y no 130); con un descuento de −150 sobre 10 pagadas y 5
-- de regalo, en 90 (y no 85).
--   · `_pesos_entre_pagados(pesos, renglones)`: si el cargo pesa sobre algún
--     renglón pagado, los regalos salen de su reparto. Si sólo pesa sobre
--     regalos queda como está: no hay a quién dárselo.
--   · La aplica el motor (`calcular_costos_compra`, y su espejo en
--     `prorrateoCompra.ts`), y el alta y la edición guardan los pesos ya
--     repartidos: así `compra_cargo_repartos` dice lo que se repartió y
--     COMPRA-A3, que reparte de nuevo desde ahí, cierra.
--
-- =========================================================================
-- 4 · CMP-B · EL TOTAL DE UNA ZZ INCLUYE SUS CARGOS EN FACTURA (y 1557-c3)
-- =========================================================================
-- Decisión del dueño (15/11, en #1593): «el total de una compra ZZ incluye
-- sus cargos en factura (flete, descuento): es lo pagado. 10 × 100 más un
-- flete de 300 dan un total de 1.300». Hasta acá el total de una ZZ era su
-- subtotal: con el total del papel la RPC avisaba «Descuadre» y COMPRA-A1
-- (high) la contaba.
--   · El control blando del alta suma, en una ZZ, los cargos en factura.
--   · COMPRA-A1 suma, en una ZZ, los cargos en factura de la compra.
--   · El front (`calcularTotalesCompra`) manda ese total.
-- 1557-c3 (el aviso con un descuento en factura) es este mismo caso: en una FC
-- el descuento va a `bonificaciones` y el aviso no salta.
-- En prod no hay ninguna ZZ viva con cargos en factura (la premisa lo exige):
-- no hay totales que rehacer.
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
-- Premisas: los cuerpos vivos son los de la 503, en LF, y los datos son los
-- que se midieron
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
  n bigint;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     '4e9ff35ed6e79402471f91c1277ba124'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     '5d04d79637c0ff57d15213f9479dd2ce'),
    ('public.calcular_costos_compra(jsonb,jsonb,jsonb)', '4775003875f12d23ba57ebe58268971e'),
    ('public._compra_renglones_fuera_de_rango(jsonb,bigint)', '7c118bfbf192d5c2bd12e1e310cde963'),
    ('public.auditoria_integridad()', 'ec5c90af7995f70838e566a34374457b')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public._pesos_entre_pagados(jsonb,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · _pesos_entre_pagados ya existe';
  END IF;

  -- CMP-B: con una ZZ viva con cargos en factura, COMPRA-A1 la pondría en rojo
  -- (su total guardado es el subtotal). Hay que decidir antes qué total le va.
  SELECT count(DISTINCT c.id) INTO n
    FROM compras c
    JOIN compra_cargos cc ON cc.compra_id = c.id AND cc.sucursal_id = c.sucursal_id
   WHERE c.tipo_factura = 'ZZ' AND c.estado <> 'cancelada' AND cc.en_factura;
  IF n > 0 THEN
    RAISE EXCEPTION 'mig NNN · hay % compra(s) ZZ viva(s) con cargos en factura: su total no los incluye y COMPRA-A1 se pondría en rojo', n;
  END IF;

  -- CMP-A: una compra vieja con un regalo antes que un renglón pagado del mismo
  -- producto conserva el promedio con que se registró (no se rehace).
  SELECT count(DISTINCT g.compra_id) INTO n
    FROM compra_items g
    JOIN compras c ON c.id = g.compra_id AND c.sucursal_id = g.sucursal_id AND c.estado <> 'cancelada'
    JOIN compra_items p ON p.compra_id = g.compra_id AND p.producto_id = g.producto_id
                       AND p.sucursal_id = g.sucursal_id AND p.id > g.id
   WHERE NOT _cpp_fija_costo(g.bonificacion, g.costo_neto_unitario, g.costo_unitario)
     AND _cpp_fija_costo(p.bonificacion, p.costo_neto_unitario, p.costo_unitario);
  RAISE NOTICE 'mig NNN · compras vivas con un regalo antes que un renglón pagado del mismo producto: % (conservan su promedio)', n;

  -- 1593-b4: renglones vivos con una bonificación menor al 100 % que deja el
  -- costo neto en 0. Ya los cuenta COMPRA-C; desde acá una edición los rechaza.
  SELECT count(*) INTO n
    FROM compra_items ci
    JOIN compras c ON c.id = ci.compra_id AND c.sucursal_id = ci.sucursal_id AND c.estado <> 'cancelada'
   WHERE COALESCE(ci.bonificacion, 0) < 100 AND COALESCE(ci.costo_unitario, 0) > 0
     AND round(ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100), 4) = 0;
  RAISE NOTICE 'mig NNN · renglones vivos con una bonificación que deja el costo neto en 0: %', n;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 3 · El reparto de un cargo, entre los renglones pagados
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._pesos_entre_pagados(p_pesos jsonb, p_items jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'public'
AS $function$
  /* mig NNN (1593-b2, 1557-c4, #1593) · LOS PESOS DE UN CARGO, SIN LOS REGALOS.
     `p_pesos` es el vector {id de renglon: peso} de un cargo y `p_items` los
     renglones del motor ({id, costo_unitario, bonificacion}). Un regalo no fija
     costo, asi que la parte de un cargo que le tocara se perderia: si el cargo
     pesa sobre algun renglon pagado, los regalos salen del vector. Si solo pesa
     sobre regalos queda como esta. Un peso que no es un numero no negativo se
     deja, para que `prorratear_cargo` lo rechace con su mensaje.
     El regalo es el de la cadena: `_cpp_fija_costo(b, round(c * (1 - b/100), 4), c)`
     falso, escrito aca adentro porque el motor lo llama `authenticated` y
     `_cpp_fija_costo` es solo de server. Espejo: `pesosEntrePagados`
     (src/utils/prorrateoCompra.ts). */
  WITH l AS (
    SELECT e->>'id' AS id,
           NOT (x.b < 100 AND round(x.c * (1 - x.b / 100), 4) > 0) AS regalo
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END) e
     CROSS JOIN LATERAL (SELECT COALESCE((e->>'bonificacion')::numeric, 0)   AS b,
                                COALESCE((e->>'costo_unitario')::numeric, 0) AS c) x
  )
  SELECT CASE
    WHEN p_pesos IS NULL OR jsonb_typeof(p_pesos) <> 'object' THEN p_pesos
    WHEN NOT EXISTS (SELECT 1 FROM jsonb_each(p_pesos) w
                       JOIN l ON l.id = w.key AND NOT l.regalo
                      WHERE CASE WHEN jsonb_typeof(w.value) = 'number'
                                 THEN (w.value #>> '{}')::numeric > 0 ELSE false END)
      THEN p_pesos
    ELSE COALESCE((SELECT jsonb_object_agg(w.key, w.value) FROM jsonb_each(p_pesos) w
                    WHERE CASE WHEN jsonb_typeof(w.value) <> 'number' THEN true
                               WHEN (w.value #>> '{}')::numeric < 0 THEN true
                               ELSE NOT EXISTS (SELECT 1 FROM l WHERE l.id = w.key AND l.regalo) END),
                  '{}'::jsonb)
  END;
$function$;

REVOKE EXECUTE ON FUNCTION public._pesos_entre_pagados(jsonb, jsonb) FROM PUBLIC, anon;
-- como el motor que la llama (`calcular_costos_compra`, INVOKER)
GRANT EXECUTE ON FUNCTION public._pesos_entre_pagados(jsonb, jsonb) TO authenticated, service_role;

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
-- 3 · el motor reparte entre los renglones pagados
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public.calcular_costos_compra(jsonb,jsonb,jsonb)', ARRAY[
  [$a$           e->'pesos'                                          AS pesos$a$,
   $r$           /* mig NNN (1593-b2, 1557-c4) · el cargo, entre los renglones pagados */
           public._pesos_entre_pagados(e->'pesos', p_items)    AS pesos$r$]
]);

-- ---------------------------------------------------------------------------
-- 2 · 1593-b4 · los rangos: una bonificación que deja el costo en 0 es un regalo
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public._compra_renglones_fuera_de_rango(jsonb,bigint)', ARRAY[
  [$a$                 THEN 'el costo es 0: si viene sin cargo, cargalo con bonificación del 100 %'$a$,
   $r$                 THEN 'el costo es 0: si viene sin cargo, cargalo con bonificación del 100 %'
               /* mig NNN (1593-b4, #1593) · y la bonificacion que deja el costo neto
                  en 0 a 4 decimales (99,999 % sobre 1): el alta la tomaba como
                  renglon pagado y la cadena como regalo. El regalo es uno, el del
                  100 %. Espejo: motivoCostoCero (src/utils/rangosCompra.ts). */
               WHEN round(round(COALESCE((e.val->>'costo_unitario')::NUMERIC, 0), 2)
                          * (1 - COALESCE((e.val->>'bonificacion')::NUMERIC, 0) / 100), 4) = 0
                    AND COALESCE((e.val->>'bonificacion')::NUMERIC, 0) < 100
                 THEN 'la bonificación deja el costo en 0: si viene sin cargo, cargalo con bonificación del 100 %'$r$]
]);

-- ---------------------------------------------------------------------------
-- 1, 2 y 3 · el alta
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)', ARRAY[
  [$a$    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);$a$,
   $r$    /* mig NNN (1593-b2, 1557-c4, #1593) · el cargo se reparte entre los
       renglones pagados, y se guarda asi: los repartos dicen lo que se repartio
       y COMPRA-A3, que reparte de nuevo desde ellos, cierra. */
    IF v_hay_cargos THEN
      SELECT jsonb_agg(c.val || jsonb_build_object('pesos', public._pesos_entre_pagados(c.val->'pesos', v_items_motor))
                       ORDER BY c.ord)
        INTO v_cargos
        FROM jsonb_array_elements(v_cargos) WITH ORDINALITY AS c(val, ord);
    END IF;

    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);$r$],
  [$a$  /* mig 407 (#1255) · LOS PRODUCTOS SE BLOQUEAN TODOS, EN ORDEN DE ID, ANTES$a$,
   $r$  /* mig NNN (CMP-A, #1593) · el id de cada renglon va por su posicion en
     p_items: el loop de abajo ya no los recorre en ese orden. */
  v_item_ids := array_fill(NULL::BIGINT, ARRAY[v_n_items]);

  /* mig 407 (#1255) · LOS PRODUCTOS SE BLOQUEAN TODOS, EN ORDEN DE ID, ANTES$r$],
  [$a$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_idx := v_idx + 1;   /* mig 194 · posicion en p_items, base 1 */$a$,
   $r$  FOR v_item, v_idx IN
    SELECT e.val, e.ord::INTEGER
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(val, ord)
     ORDER BY NOT public._cpp_fija_costo(
                COALESCE((e.val->>'bonificacion')::NUMERIC, 0),
                round(COALESCE((e.val->>'costo_unitario')::NUMERIC, 0)
                      * (1 - COALESCE((e.val->>'bonificacion')::NUMERIC, 0) / 100), 4),
                COALESCE((e.val->>'costo_unitario')::NUMERIC, 0)),
              e.ord
  LOOP
    /* mig NNN (CMP-A, #1593) · LOS RENGLONES QUE FIJAN COSTO, PRIMERO. Un regalo
       sobre un producto agotado o sin promedio no tiene que diluir y entraba al
       stock sin moverlo: el pagado de despues se promediaba con esas unidades al
       promedio viejo (10 de regalo y 10 a 100 daban 90 o 100; al reves, 50). Con
       los pagados primero la factura da su prorrateo en cualquier orden. Se
       insertan en este orden, que es el de la cadena (por id). `v_idx` sigue
       siendo la posicion en p_items (base 1), la de los pesos y el motor. */$r$],
  [$a$    v_item_ids := v_item_ids || v_item_id;$a$,
   $r$    v_item_ids[v_idx] := v_item_id;   /* mig NNN: por la posicion en p_items */$r$],
  [$a$    v_actualiza_costo := (v_bonificacion < 100 AND v_costo_neto > 0);$a$,
   $r$    /* mig NNN (1593-b4) · el umbral de la cadena, sobre el neto que se guarda */
    v_actualiza_costo := _cpp_fija_costo(v_bonificacion, round(v_costo_neto, 4), v_costo_unitario);$r$],
  [$a$  v_total_calc := CASE
    WHEN v_es_zz THEN COALESCE(p_subtotal, 0)$a$,
   $r$  v_total_calc := CASE
    /* mig NNN (CMP-B, #1593) · el total de una ZZ incluye sus cargos en factura:
       es lo pagado (decision del dueño, 15/11). */
    WHEN v_es_zz THEN COALESCE(p_subtotal, 0)
         + COALESCE((SELECT sum((c.val->>'monto')::NUMERIC) FROM jsonb_array_elements(v_cargos) AS c(val)
                      WHERE (c.val->>'en_factura')::BOOLEAN), 0)$r$]
]);

-- ---------------------------------------------------------------------------
-- 1, 2 y 3 · la edición
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])', ARRAY[
  [$a$    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);$a$,
   $r$    /* mig NNN (1593-b2, 1557-c4, #1593) · el cargo, entre los renglones
       pagados, y guardado asi (ver el alta). */
    IF v_hay_cargos THEN
      SELECT jsonb_agg(c.val || jsonb_build_object('pesos', public._pesos_entre_pagados(c.val->'pesos', v_items_motor))
                       ORDER BY c.ord)
        INTO v_cargos
        FROM jsonb_array_elements(v_cargos) WITH ORDINALITY AS c(val, ord);
    END IF;

    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);$r$],
  [$a$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_idx := v_idx + 1;   /* mig 194 · posicion en p_items_nuevos, base 1 */$a$,
   $r$  /* mig NNN (CMP-A, #1593) · los renglones que fijan costo, primero (ver el
     alta): la foto de cada renglon y el promedio corrido salen en ese orden, y
     se insertan asi. `v_idx` sigue siendo la posicion en p_items_nuevos. */
  v_item_ids := array_fill(NULL::BIGINT, ARRAY[v_n_items]);
  FOR v_item, v_idx IN
    SELECT e.val, e.ord::INTEGER
      FROM jsonb_array_elements(p_items_nuevos) WITH ORDINALITY AS e(val, ord)
     ORDER BY NOT public._cpp_fija_costo(
                COALESCE((e.val->>'bonificacion')::NUMERIC, 0),
                round(COALESCE((e.val->>'costo_unitario')::NUMERIC, 0)
                      * (1 - COALESCE((e.val->>'bonificacion')::NUMERIC, 0) / 100), 4),
                COALESCE((e.val->>'costo_unitario')::NUMERIC, 0)),
              e.ord
  LOOP$r$],
  [$a$    v_item_ids := v_item_ids || v_item_id;$a$,
   $r$    v_item_ids[v_idx] := v_item_id;   /* mig NNN: por la posicion en p_items_nuevos */$r$],
  [$a$    v_actualiza_costo := (v_bonificacion < 100 AND v_costo_neto > 0);$a$,
   $r$    /* mig NNN (1593-b4) · el umbral de la cadena, sobre el neto que se guarda */
    v_actualiza_costo := _cpp_fija_costo(v_bonificacion, round(v_costo_neto, 4), v_costo_unitario);$r$]
]);

-- ---------------------------------------------------------------------------
-- 4 · CMP-B · COMPRA-A1 suma, en una ZZ, los cargos en factura
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchar('public.auditoria_integridad()', ARRAY[
  [$a$    ('COMPRA-A1','high','compras.total = subtotal+bonificaciones+iva+ii+percepciones+no gravado+otros (mig 195)',$a$,
   $r$    ('COMPRA-A1','high','compras.total = subtotal+bonificaciones+iva+ii+percepciones+no gravado+otros (mig 195); en una ZZ, más sus cargos en factura (#1593)',$r$],
  [$a$        +COALESCE(no_gravado,0)+COALESCE(otros_impuestos,0)))>1.0)),$a$,
   $r$        +COALESCE(no_gravado,0)+COALESCE(otros_impuestos,0)
        /* mig NNN (CMP-B, #1593) · decision del dueño (15/11): el total de una ZZ
           incluye sus cargos en factura, es lo pagado. */
        +CASE WHEN tipo_factura = 'ZZ'
              THEN COALESCE((SELECT sum(cc.monto) FROM compra_cargos cc
                              WHERE cc.compra_id = compras.id AND cc.sucursal_id = compras.sucursal_id
                                AND cc.en_factura), 0)
              ELSE 0 END))>1.0)),$r$]
]);

DROP FUNCTION pg_temp.parchar(text, text[]);

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
  v_mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._pesos_entre_pagados(jsonb,jsonb)', '2cc41a31559964d09f11855c40784bbb', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.calcular_costos_compra(jsonb,jsonb,jsonb)', 'c02ad04c2c30735a0992bb4a3b0c1f20', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._compra_renglones_fuera_de_rango(jsonb,bigint)', 'c81c3a459d4bf55d99593c3585fe3803', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     '9b3be23e2477446c6f9a413b8310cb16', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     '3e3dc133de5a10e30c72184232c5a5fd', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.auditoria_integridad()', '089547f4be0fcd8ed8dfbe0c8f69f2d7', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      v_mal := v_mal || format(E'\n  %s (md5 %s, acl %s, definer %s)', r.f, x.h, x.a, x.def);
    END IF;
  END LOOP;
  IF v_mal <> '' THEN
    RAISE EXCEPTION 'mig NNN · no quedaron como en el repo:%', v_mal;
  END IF;
END
$post$;

COMMIT;
