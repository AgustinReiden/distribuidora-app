-- =========================================================================
-- mig 313 · LA CADENA SE RECORRE EN ORDEN (#1010) Y EL HISTORIAL DICE COMO
--           QUEDO EL PEDIDO (#996)
--
-- #1010 · EL PROBLEMA
-- -------------------
-- `regalo_sustitucion_resuelta` (mig 304) tomaba en cada nodo la sustitucion
-- MAS NUEVA de ese producto, no la SIGUIENTE despues del ultimo eslabon. En
-- una cadena que vuelve a un producto anterior se salteaba los del medio:
--
--   A6 -> P19 (r1), P19 -> Q10 (r2), Q10 -> P25 (r3), P25 -> R30 (r4).
--   La linea es R x30. Editar sin cambios manda A x6: r1 lleva a P19; desde P
--   tomaba r4 (la mas nueva) y como 19 <> 25 guardaba R x23 (por valor) o R x19.
--
-- El producto final salia bien; la cantidad no, y en modo A eso mueve stock.
--
-- LA REGLA (decision del dueno, 2026-10-08): desde el producto que llega,
-- SIEMPRE el siguiente eslabon --el mas viejo posterior al ultimo aplicado cuyo
-- original sea el producto actual--, hasta que no haya mas. Reproduce la
-- historia real de la linea, porque sustituir_regalo_pedido anota como original
-- el producto que la linea tiene en ese momento. Tambien arregla la cadena que
-- vuelve a la RAIZ (A -> A 6 -> 8, despues A -> A 8 -> 9: daba A x6/7, no A x9).
-- El limite, aceptado con la regla: la cadena se recorre desde lo que LLEGA.
-- El front manda la raiz (regaloParaEditar) y desde ahi reproduce la historia
-- exacta. Quien mande el producto ACTUAL --un bundle del PWA anterior a la 304,
-- o una linea de reparto conservada-- y ese producto ya fue original antes en
-- una cadena con vuelta (A -> P -> Q -> P -> P), la recorre otra vez desde el
-- primer P y reconvierte la cantidad. Con la 304 salia bien en ese caso y mal
-- en el de arriba: no hay forma de saber desde el server si P llega como raiz o
-- como final. El 2026-10-08 ningun pedido sin entregar tenia sustituciones.
-- Lo demas de la 304 sigue: el reparto anula lo anterior de su promo (mig 275),
-- una vuelta A -> P -> A se corta sola, la cantidad se convierte con la regla
-- de la 295 en cada paso.
--
-- QUE CAMBIA
-- ----------
-- · `regalo_cadena_pasos(eslabones jsonb, producto)` (nueva, pura): el
--   recorrido, sin leer tablas. Devuelve los ids de los eslabones aplicados,
--   en orden. Su espejo es `pasosDeCadena()` de src/utils/repartoRegalo.ts y
--   las dos corren los casos de src/utils/cadenaSustitucion.espejo.json: el TS
--   en vitest, el SQL en scripts/espejo-cadena-regalo.mjs (gate de integridad).
--   Por eso es pura: el test de paridad no necesita escribir datos.
-- · `regalo_sustitucion_resuelta`: arma los eslabones de la promo y los recorre
--   con la funcion de arriba. La conversion de cantidad no cambia.
-- · `sustituir_regalo_pedido`: una sola marca "[Sustituido por: ...]". Se
--   acumulaba una por sustitucion (el pedido 3351 la tiene dos veces; no se
--   toca: esta entregado, decision del dueno). Saca las anteriores y deja el
--   mismo texto que pone el trigger al editar, para que una edicion sin cambios
--   no cambie la linea.
--
-- #996 · EL HISTORIAL
-- -------------------
-- `actualizar_pedido_items` registraba en pedido_historial ('items') el JSON de
-- entrada, de ANTES del trigger de sustituciones: desde la 304 el modal manda el
-- regalo como lo calcula la promo, asi que una linea P x19 figuraba como A x6, y
-- hasta una edicion sin cambios figuraba como cambio. Ahora:
-- · valor_nuevo se arma con las filas que QUEDARON (producto, cantidad, precio,
--   bonificacion y descripcion por linea), y valor_anterior con la misma
--   expresion, en un orden que no depende de los ids.
-- · La fila se registra solo si cambio algo, como la del total (decision del
--   dueno, 2026-10-08).
-- Nadie mas lee ese campo: el modal de historial muestra el texto tal cual.
--
-- COSTO, STOCK, LOTES
-- -------------------
-- · COSTO-D: el trigger sigue valuando con costo_valuacion el producto que
--   QUEDA, actualizar_pedido_items sigue valuando despues del INSERT ...
--   RETURNING (mig 257), y sustituir_regalo_pedido no cambia su costo.
-- · Stock: ningun camino nuevo sube ni baja stock. El trigger y
--   actualizar_pedido_items mueven stock con lo que QUEDO en la fila (RETURNING,
--   migs 252/295); lo unico que cambia es QUE queda, que ahora es lo correcto.
--   Las devoluciones de actualizar_pedido_items siguen etiquetadas como
--   'pedido_creado' (mig 229) y las de sustituir como 'sustitucion_regalo'. STK-F
--   no cambia.
--
-- Permisos: regalo_cadena_pasos corre solo desde el server y desde el gate de
-- integridad (service_role) -> REVOKE a PUBLIC, anon y authenticated. Las
-- parchadas conservan su ACL (el $verif$ la compara).
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio. Se dropea al final.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _mig1010_acl ON COMMIT DROP AS
SELECT p.oid::regprocedure::text AS fn, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('regalo_sustitucion_resuelta', 'sustituir_regalo_pedido', 'actualizar_pedido_items');

CREATE OR REPLACE FUNCTION public._mig1010_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_ancla text := replace(p_ancla, E'\r', '');
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig1010 · el ancla aparece % veces en % (se esperaba 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(v_ancla, 160);
  END IF;
  EXECUTE replace(v_def, v_ancla, replace(p_nuevo, E'\r', ''));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · El recorrido, puro. Espejo: pasosDeCadena() en repartoRegalo.ts.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.regalo_cadena_pasos(p_eslabones jsonb, p_producto_id bigint)
RETURNS bigint[]
LANGUAGE plpgsql
-- STABLE y no IMMUTABLE: el cast de created_at a timestamptz depende del
-- TimeZone de la sesion cuando el texto no trae offset.
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  -- Los eslabones de UNA promo, ordenados por (created_at, id) como siempre.
  v_ids   bigint[];
  v_orig  bigint[];
  v_sust  bigint[];
  v_rep   boolean[];
  v_n     int;
  -- Posicion del ultimo eslabon aplicado (o del ultimo reparto, al arrancar).
  v_desde int := 0;
  v_i     int;
  v_nodo  bigint := p_producto_id;
  v_pasos bigint[] := '{}';
BEGIN
  SELECT array_agg((e->>'id')::bigint
                   ORDER BY (e->>'created_at')::timestamptz, (e->>'id')::bigint),
         array_agg((e->>'producto_original_id')::bigint
                   ORDER BY (e->>'created_at')::timestamptz, (e->>'id')::bigint),
         array_agg((e->>'producto_sustituto_id')::bigint
                   ORDER BY (e->>'created_at')::timestamptz, (e->>'id')::bigint),
         array_agg((e->>'reparto_id') IS NOT NULL
                   ORDER BY (e->>'created_at')::timestamptz, (e->>'id')::bigint)
    INTO v_ids, v_orig, v_sust, v_rep
    FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) e;
  v_n := COALESCE(array_length(v_ids, 1), 0);

  -- Un reparto es la ultima decision sobre la composicion del regalo y anula
  -- lo anterior (mig 275): se arranca despues del ULTIMO, y sus filas no
  -- reescriben nada.
  FOR v_i IN 1..v_n LOOP
    IF v_rep[v_i] THEN
      v_desde := v_i;
    END IF;
  END LOOP;

  -- #1010: SIEMPRE el siguiente eslabon --el primero posterior al ultimo
  -- aplicado cuyo original sea el producto actual--, no el mas nuevo.
  LOOP
    v_i := v_desde + 1;
    WHILE v_i <= v_n AND (v_rep[v_i] OR v_orig[v_i] IS DISTINCT FROM v_nodo) LOOP
      v_i := v_i + 1;
    END LOOP;
    EXIT WHEN v_i > v_n;
    v_pasos := v_pasos || v_ids[v_i];
    v_nodo  := v_sust[v_i];
    v_desde := v_i;
  END LOOP;

  RETURN v_pasos;
END;
$fn$;

REVOKE ALL ON FUNCTION public.regalo_cadena_pasos(jsonb, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_cadena_pasos(jsonb, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 2 · regalo_sustitucion_resuelta recorre con la funcion de arriba.
--     Cuerpo entero (es chico). CREATE OR REPLACE conserva la ACL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.regalo_sustitucion_resuelta(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint,
  p_sucursal_id bigint, p_cantidad numeric
) RETURNS TABLE (producto_id bigint, cantidad numeric, pasos integer, ya_sustituido boolean)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_eslabones jsonb;
  v_id        bigint;
  -- El ultimo reparto de la promo: lo anterior ya no vale (mig 275).
  v_corte_ts  timestamptz;
  v_corte_id  bigint;
  v_nodo      bigint  := p_producto_id;
  -- Contenedor del nodo, para su factor (el del original es el mismo producto,
  -- como en la 295; el de un sustituto, el que eligio el admin).
  v_ajuste    bigint  := p_producto_id;
  v_cant      numeric := p_cantidad;
  v_pasos     integer := 0;
  v_s         pedido_item_sustituciones%ROWTYPE;
BEGIN
  -- mig 313 (#1010): QUE eslabones se aplican lo decide regalo_cadena_pasos,
  -- la misma regla que pasosDeCadena() en el front (test de paridad:
  -- src/utils/cadenaSustitucion.espejo.json).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', s.id, 'created_at', s.created_at,
           'producto_original_id', s.producto_original_id,
           'producto_sustituto_id', s.producto_sustituto_id,
           'reparto_id', s.reparto_id)), '[]'::jsonb)
    INTO v_eslabones
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id;

  FOREACH v_id IN ARRAY public.regalo_cadena_pasos(v_eslabones, p_producto_id) LOOP
    SELECT s.* INTO v_s FROM pedido_item_sustituciones s WHERE s.id = v_id;

    -- La cantidad, con la regla de la 295 aplicada a este eslabon.
    IF v_cant IS NOT NULL AND COALESCE(v_s.cantidad_original, 0) > 0
       AND v_s.cantidad_sustituta IS NOT NULL THEN
      IF v_cant = v_s.cantidad_original THEN
        v_cant := v_s.cantidad_sustituta;
      ELSIF NOT public.regalo_misma_categoria(v_nodo, v_s.producto_sustituto_id, p_sucursal_id)
            OR public.factor_regalo_de_linea(p_promocion_id, v_nodo, p_sucursal_id, v_ajuste)
               IS DISTINCT FROM
               public.factor_regalo_de_linea(p_promocion_id, v_s.producto_sustituto_id, p_sucursal_id,
                                             COALESCE(v_s.ajuste_producto_id_nuevo, v_s.producto_sustituto_id)) THEN
        v_cant := GREATEST(1, round(v_cant * v_s.cantidad_sustituta / v_s.cantidad_original));
      END IF;
    END IF;

    v_nodo   := v_s.producto_sustituto_id;
    v_ajuste := COALESCE(v_s.ajuste_producto_id_nuevo, v_s.producto_sustituto_id);
    v_pasos  := v_pasos + 1;
  END LOOP;

  SELECT s.created_at, s.id INTO v_corte_ts, v_corte_id
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id
     AND s.reparto_id IS NOT NULL
   ORDER BY s.created_at DESC, s.id DESC
   LIMIT 1;

  producto_id := v_nodo;
  cantidad    := v_cant;
  pasos       := v_pasos;
  -- Llego ya sustituido: es el sustituto de una fila vigente (no una
  -- auto-sustitucion) y no tiene eslabones para adelante.
  ya_sustituido := v_pasos = 0 AND EXISTS (
    SELECT 1
      FROM pedido_item_sustituciones s
     WHERE s.pedido_id = p_pedido_id
       AND s.promocion_id = p_promocion_id
       AND s.sucursal_id = p_sucursal_id
       AND s.reparto_id IS NULL
       AND s.producto_sustituto_id = p_producto_id
       AND s.producto_original_id <> p_producto_id
       AND (v_corte_ts IS NULL OR (s.created_at, s.id) > (v_corte_ts, v_corte_id)));
  RETURN NEXT;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3 · sustituir_regalo_pedido: una sola marca.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig1010_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$         descripcion_regalo = COALESCE(descripcion_regalo, '') || ' [Sustituido por: ' || COALESCE(v_nuevo_nombre, '?') || ']',$ancla$,
$nuevo$         -- mig 313 (#1010): una sola marca. En una cadena se acumulaba una
         -- por sustitucion. Se sacan las anteriores y queda el mismo texto que
         -- pone el trigger al editar: la base de la descripcion + la marca del
         -- final. La marca se agrega siempre con UN espacio adelante (o sin
         -- ninguno, la de dividir_regalo_pedido con btrim): sacar ' ?' y no
         -- '\s*' deja intacta la base aunque termine en espacio.
         descripcion_regalo = regexp_replace(COALESCE(descripcion_regalo, ''),
                                             ' ?\[Sustituido por:[^\]]*\]', '', 'g')
                              || ' [Sustituido por: ' || COALESCE(v_nuevo_nombre, '?') || ']',$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · actualizar_pedido_items: el historial con las filas que quedaron.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig1010_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  v_marca_reparto TEXT := gen_random_uuid()::text;$ancla$,
$nuevo$  v_marca_reparto TEXT := gen_random_uuid()::text;
  -- mig 313 (#996): las lineas como QUEDARON, para el historial.
  v_items_guardados JSONB;$nuevo$);

  PERFORM public._mig1010_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;$ancla$,
$nuevo$  -- mig 313 (#996): con la descripcion de cada linea y en un orden que no
  -- depende de los ids, para que el historial compare igual contra igual:
  -- v_items_guardados (abajo) se arma con la MISMA expresion. Las claves que
  -- leen los chequeos de productos inactivos no cambian.
  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false),
    'descripcion_regalo', descripcion_regalo))
    ORDER BY COALESCE(es_bonificacion, false), producto_id, cantidad, precio_unitario, descripcion_regalo)
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;$nuevo$);

  PERFORM public._mig1010_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  -- mig 275: se registra lo que se guardo (v_items), que puede diferir de lo
  -- que mando el front si se conservo un reparto.
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), v_items::TEXT, v_sucursal);$ancla$,
$nuevo$  -- mig 313 (#996): se registra como QUEDO cada linea, no el JSON de entrada.
  -- El trigger de sustituciones reescribe producto, cantidad y descripcion de
  -- un regalo, y el modal lo manda como lo calcula la promo (el original de la
  -- cadena): el historial decia A x6 cuando la linea era P x19. Misma expresion
  -- que v_items_originales. Y solo si cambio algo, como el total de abajo
  -- (decision del dueno, 2026-10-08).
  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false),
    'descripcion_regalo', descripcion_regalo))
    ORDER BY COALESCE(es_bonificacion, false), producto_id, cantidad, precio_unitario, descripcion_regalo)
  INTO v_items_guardados FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  IF COALESCE(v_items_originales, '[]'::jsonb) IS DISTINCT FROM COALESCE(v_items_guardados, '[]'::jsonb) THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'),
            COALESCE(v_items_guardados::TEXT, '[]'), v_sucursal);
  END IF;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · Verificacion.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n       int;
  v_def     text;
  v_audit   jsonb;
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_a bigint; v_p bigint; v_q bigint; v_r bigint; v_r2 bigint; v_v bigint;
  v_promo   bigint;  -- modo B (fraccion), como la 295 y la 304
  v_promo_a bigint;  -- modo A (mueve stock)
  v_res     jsonb;
  v_ped     bigint;
  v_item    bigint;
  v_prod    bigint;
  v_cant    int;
  v_desc    text;
  v_costo   numeric;
  v_stock   int;
  v_stock_a int;
  v_stocks  int[];
  v_hist    int;
  v_ant     jsonb;
  v_nuevo   jsonb;
  v_casos   jsonb;
  v_c       jsonb;
BEGIN
  -- (a) Permisos y firmas.
  IF to_regprocedure('public.regalo_cadena_pasos(jsonb,bigint)') IS NULL THEN
    RAISE EXCEPTION 'mig1010 · falta regalo_cadena_pasos';
  END IF;
  IF has_function_privilege('anon', 'public.regalo_cadena_pasos(jsonb,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.regalo_cadena_pasos(jsonb,bigint)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.regalo_cadena_pasos(jsonb,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig1010 · regalo_cadena_pasos: tiene que ejecutarla solo service_role';
  END IF;
  SELECT count(*) INTO v_n
    FROM _mig1010_acl a
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(a.fn)
   WHERE p.oid IS NULL
      OR p.proacl::text IS DISTINCT FROM a.acl
      OR p.prosecdef IS DISTINCT FROM a.prosecdef OR p.proconfig::text IS DISTINCT FROM a.cfg;
  IF v_n > 0 OR (SELECT count(*) FROM _mig1010_acl) <> 3 THEN
    RAISE EXCEPTION 'mig1010 · cambio la firma, la ACL, el SECURITY DEFINER o el search_path de % funcion(es)', v_n;
  END IF;

  -- (b) Los cuerpos llevan lo nuevo y no perdieron lo de antes.
  v_def := pg_get_functiondef('public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric)'::regprocedure);
  IF v_def NOT LIKE '%regalo_cadena_pasos(v_eslabones, p_producto_id)%' THEN
    RAISE EXCEPTION 'mig1010 · regalo_sustitucion_resuelta no usa regalo_cadena_pasos';
  END IF;
  v_def := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
  IF v_def NOT LIKE '%regexp_replace(COALESCE(descripcion_regalo, %' OR v_def NOT LIKE '%costo_valuacion(%'
     OR v_def NOT LIKE '%''sustitucion_regalo''%' THEN
    RAISE EXCEPTION 'mig1010 · sustituir_regalo_pedido no quedo como se esperaba';
  END IF;
  v_def := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  IF v_def NOT LIKE '%INTO v_items_guardados FROM pedido_items%'
     OR v_def NOT LIKE '%INTO v_pedido_item_guardado, v_producto_guardado, v_cantidad_guardada%'
     OR v_def NOT LIKE '%costo_valuacion(%'
     OR v_def NOT LIKE '%regalo_sustitucion_resuelta(p_pedido_id, v_promocion_id, v_producto_id,%'
     OR v_def LIKE '%v_items::TEXT, v_sucursal%' THEN
    RAISE EXCEPTION 'mig1010 · actualizar_pedido_items no quedo como se esperaba';
  END IF;

  -- (c) Compuertas.
  v_audit := public.auditoria_integridad();
  SELECT count(*) INTO v_n
    FROM jsonb_array_elements(v_audit->'checks') c
   WHERE c->>'id' IN ('COSTO-D', 'STK-F', 'PROMO-A', 'PROMO-B', 'BONIF-C', 'BONIF-D', 'STK-B')
     AND NOT (c->>'ok')::boolean;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig1010 · auditoria_integridad en rojo: %',
      (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_audit->'checks') c
        WHERE NOT (c->>'ok')::boolean
          AND c->>'id' IN ('COSTO-D','STK-F','PROMO-A','PROMO-B','BONIF-C','BONIF-D','STK-B'));
  END IF;

  -- (d) El recorrido puro, sin datos. El juego completo de casos lo corre el
  --     gate (scripts/espejo-cadena-regalo.mjs); aca van los del issue.
  v_casos := jsonb_build_array(
    -- A-P-Q-P-R: los cuatro, en orden (antes: 11 y 14).
    jsonb_build_object('producto', 1, 'esperado', '[11,12,13,14]'::jsonb, 'eslabones', '[
      {"id":14,"created_at":"2026-10-04T10:00:00Z","producto_original_id":2,"producto_sustituto_id":4,"reparto_id":null},
      {"id":13,"created_at":"2026-10-03T10:00:00Z","producto_original_id":3,"producto_sustituto_id":2,"reparto_id":null},
      {"id":12,"created_at":"2026-10-02T10:00:00Z","producto_original_id":2,"producto_sustituto_id":3,"reparto_id":null},
      {"id":11,"created_at":"2026-10-01T10:00:00Z","producto_original_id":1,"producto_sustituto_id":2,"reparto_id":null}]'::jsonb),
    -- Vuelve a la raiz y sigue (antes: solo 12).
    jsonb_build_object('producto', 1, 'esperado', '[11,12]'::jsonb, 'eslabones', '[
      {"id":12,"created_at":"2026-10-02T10:00:00Z","producto_original_id":1,"producto_sustituto_id":1,"reparto_id":null},
      {"id":11,"created_at":"2026-10-01T10:00:00Z","producto_original_id":1,"producto_sustituto_id":1,"reparto_id":null}]'::jsonb),
    -- El reparto corta y sus filas no reescriben nada.
    jsonb_build_object('producto', 1, 'esperado', '[]'::jsonb, 'eslabones', '[
      {"id":13,"created_at":"2026-10-02T10:00:00Z","producto_original_id":2,"producto_sustituto_id":3,"reparto_id":"8b0d6f43-2a52-4d1c-9a51-6a3f8d0e5c11"},
      {"id":12,"created_at":"2026-10-02T10:00:00Z","producto_original_id":2,"producto_sustituto_id":2,"reparto_id":"8b0d6f43-2a52-4d1c-9a51-6a3f8d0e5c11"},
      {"id":11,"created_at":"2026-10-01T10:00:00Z","producto_original_id":1,"producto_sustituto_id":2,"reparto_id":null}]'::jsonb),
    -- Misma fecha: desempata por id.
    jsonb_build_object('producto', 1, 'esperado', '[12]'::jsonb, 'eslabones', '[
      {"id":12,"created_at":"2026-10-01T10:00:00Z","producto_original_id":1,"producto_sustituto_id":2,"reparto_id":null},
      {"id":11,"created_at":"2026-10-01T10:00:00Z","producto_original_id":2,"producto_sustituto_id":3,"reparto_id":null}]'::jsonb),
    -- Sin eslabones.
    jsonb_build_object('producto', 1, 'esperado', '[]'::jsonb, 'eslabones', '[]'::jsonb));
  FOR v_c IN SELECT * FROM jsonb_array_elements(v_casos) LOOP
    IF to_jsonb(public.regalo_cadena_pasos(v_c->'eslabones', (v_c->>'producto')::bigint))
       IS DISTINCT FROM v_c->'esperado' THEN
      RAISE EXCEPTION 'mig1010 · regalo_cadena_pasos: esperado % y dio %', v_c->'esperado',
        public.regalo_cadena_pasos(v_c->'eslabones', (v_c->>'producto')::bigint);
    END IF;
  END LOOP;

  -- (e) El ensayo, con productos y promos sinteticos, en un sub-bloque que se
  --     deshace solo (SQLSTATE centinela, como la 295 y la 304).
  --     A = regalo default (gaseosa, bulto 6). P, Q = otra categoria (bulto
  --     12): cambiar a ellos convierte por valor. R = otra categoria, bulto 1.
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig1010 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1010 A', 6000, 50, v_suc, 'ZZ ensayo mig1010 gaseosa', 6, 100) RETURNING id INTO v_a;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1010 P', 6000, 40, v_suc, 'ZZ ensayo mig1010 snack', 12, 200) RETURNING id INTO v_p;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1010 Q', 6000, 40, v_suc, 'ZZ ensayo mig1010 snack', 12, 300) RETURNING id INTO v_q;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1010 R', 6000, 100, v_suc, 'ZZ ensayo mig1010 snack', 1, 400) RETURNING id INTO v_r;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1010 R2', 6000, 25, v_suc, 'ZZ ensayo mig1010 snack', 1, 400) RETURNING id INTO v_r2;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig1010 vendido', 100, 100, v_suc) RETURNING id INTO v_v;

    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      ajuste_producto_id, producto_regalo_id, unidades_por_bloque, stock_por_bloque,
      regalo_mueve_stock, usos_pendientes)
    VALUES ('ZZ ensayo mig1010', 'bonificacion', CURRENT_DATE, v_suc, TRUE,
      v_a, v_a, 6, 1, FALSE, 0) RETURNING id INTO v_promo;
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      producto_regalo_id, regalo_mueve_stock, descripcion_regalo)
    VALUES ('ZZ ensayo mig1010 modo A', 'bonificacion', CURRENT_DATE, v_suc, FALSE,
      v_a, TRUE, 'ZZ seis de regalo') RETURNING id INTO v_promo_a;

    -- ── #1010: A6 -> P19 -> Q10 -> P25 -> R30, en modo A. ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_a),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1010 vuelta');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig1010 A->P', NULL, NULL);
    IF COALESCE((v_res->>'success')::boolean, false) THEN
      v_res := public.sustituir_regalo_pedido(v_item, v_q, 10, 'ensayo mig1010 P->Q', NULL, NULL);
    END IF;
    IF COALESCE((v_res->>'success')::boolean, false) THEN
      v_res := public.sustituir_regalo_pedido(v_item, v_p, 25, 'ensayo mig1010 Q->P', NULL, NULL);
    END IF;
    IF COALESCE((v_res->>'success')::boolean, false) THEN
      v_res := public.sustituir_regalo_pedido(v_item, v_r, 30, 'ensayo mig1010 P->R', NULL, NULL);
    END IF;
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig1010 · el ensayo no pudo armar la cadena: %', v_res;
    END IF;

    -- Una sola marca, sobre la descripcion de la promo.
    SELECT producto_id, cantidad, descripcion_regalo INTO v_prod, v_cant, v_desc
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF v_prod <> v_r OR v_cant <> 30
       OR v_desc IS DISTINCT FROM 'ZZ seis de regalo [Sustituido por: ZZ ensayo mig1010 R]' THEN
      RAISE EXCEPTION 'mig1010 · cadena armada: prod=% (R) cant=% (30) desc=%', v_prod, v_cant, v_desc;
    END IF;

    -- Editar sin cambios: queda R x30, con una marca, el costo de R, sin
    -- mover stock y sin fila de historial.
    SELECT array_agg(stock ORDER BY id) INTO v_stocks FROM productos WHERE id IN (v_a, v_p, v_q, v_r, v_v);
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items';
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_a),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad, descripcion_regalo, costo_unitario_al_crear INTO v_prod, v_cant, v_desc, v_costo
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_r OR v_cant <> 30
       OR v_desc IS DISTINCT FROM 'ZZ seis de regalo [Sustituido por: ZZ ensayo mig1010 R]'
       OR v_costo IS DISTINCT FROM (SELECT public.costo_valuacion(NULL, costo_promedio, costo_real, costo_sin_iva,
                                                                  COALESCE(impuestos_internos, 0))
                                      FROM productos WHERE id = v_r) THEN
      RAISE EXCEPTION 'mig1010 · vuelta sin cambios: % prod=% (R) cant=% (30) desc=% costo=%',
        v_res, v_prod, v_cant, v_desc, v_costo;
    END IF;
    IF (SELECT array_agg(stock ORDER BY id) FROM productos WHERE id IN (v_a, v_p, v_q, v_r, v_v)) IS DISTINCT FROM v_stocks THEN
      RAISE EXCEPTION 'mig1010 · vuelta sin cambios movio stock: antes % despues %', v_stocks,
        (SELECT array_agg(stock ORDER BY id) FROM productos WHERE id IN (v_a, v_p, v_q, v_r, v_v));
    END IF;
    IF (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items') <> v_hist THEN
      RAISE EXCEPTION 'mig1010 · una edicion sin cambios dejo una fila de historial';
    END IF;

    -- ── #996 y bordes de la 304: A 6 -> P 19 (por valor), modo B. ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1010');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig1010', NULL, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig1010 · el ensayo no pudo sustituir: %', v_res;
    END IF;

    -- Sin cambios: P 19 con marca, y sin fila de historial.
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items';
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad, descripcion_regalo INTO v_prod, v_cant, v_desc
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p OR v_cant <> 19
       OR v_desc NOT LIKE '%[Sustituido por: ZZ ensayo mig1010 P]%' THEN
      RAISE EXCEPTION 'mig1010 · A6 sin cambios: % prod=% (P) cant=% (19) desc=%', v_res, v_prod, v_cant, v_desc;
    END IF;
    IF (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items') <> v_hist THEN
      RAISE EXCEPTION 'mig1010 · A6 sin cambios dejo una fila de historial';
    END IF;

    -- La venta crece: A 12 -> P 38 (12 * 19 / 6). El historial dice P, no A.
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 12, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad INTO v_prod, v_cant FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p OR v_cant <> 38 THEN
      RAISE EXCEPTION 'mig1010 · A12: % prod=% (P) cant=% (38)', v_res, v_prod, v_cant;
    END IF;
    SELECT valor_anterior::jsonb, valor_nuevo::jsonb INTO v_ant, v_nuevo
      FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items'
     ORDER BY id DESC LIMIT 1;
    IF NOT FOUND
       OR NOT v_nuevo @> jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 38, 'es_bonificacion', true))
       OR NOT v_nuevo @> jsonb_build_array(jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'es_bonificacion', false))
       OR v_nuevo @> jsonb_build_array(jsonb_build_object('producto_id', v_a))
       OR jsonb_array_length(v_nuevo) <> 2
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_nuevo) e
                       WHERE (e->>'es_bonificacion')::boolean
                         AND e->>'descripcion_regalo' LIKE '%[Sustituido por: ZZ ensayo mig1010 P]%')
       OR NOT v_ant @> jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 19, 'es_bonificacion', true)) THEN
      RAISE EXCEPTION 'mig1010 · historial de A12: anterior=% nuevo=%', v_ant, v_nuevo;
    END IF;

    -- Un bundle viejo manda el sustituto (P 6): conserva la marca. La cantidad
    -- queda como vino (no se sabe en que unidad esta).
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_p, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad, descripcion_regalo INTO v_prod, v_cant, v_desc
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p OR v_cant <> 6
       OR v_desc NOT LIKE '%[Sustituido por: ZZ ensayo mig1010 P]%' THEN
      RAISE EXCEPTION 'mig1010 · P6 (bundle viejo): % prod=% cant=% desc=%', v_res, v_prod, v_cant, v_desc;
    END IF;

    -- ── A -> P (19) -> Q (19): una marca, la de Q. ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1010 cadena');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig1010 A->P', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_q, 19, 'ensayo mig1010 P->Q', NULL, NULL);
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE id = v_item;
    IF v_desc IS DISTINCT FROM ' [Sustituido por: ZZ ensayo mig1010 Q]' THEN
      RAISE EXCEPTION 'mig1010 · dos sustituciones, una marca: desc=%', v_desc;
    END IF;
    IF public.regalo_sustituto_vigente(v_ped, v_promo, v_a, v_suc) IS DISTINCT FROM v_q THEN
      RAISE EXCEPTION 'mig1010 · regalo_sustituto_vigente(A) no es Q: %', public.regalo_sustituto_vigente(v_ped, v_promo, v_a, v_suc);
    END IF;
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 12, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad INTO v_prod, v_cant FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_q OR v_cant <> 38 THEN
      RAISE EXCEPTION 'mig1010 · cadena A12: % prod=% (Q) cant=% (38)', v_res, v_prod, v_cant;
    END IF;

    -- Un reparto posterior anula la cadena (mig 275): A vuelve a quedar A.
    INSERT INTO pedido_item_sustituciones (pedido_id, pedido_item_id, promocion_id, producto_original_id,
      producto_sustituto_id, cantidad_original, cantidad_sustituta, motivo, autorizado_por, sucursal_id, reparto_id)
    VALUES (v_ped, NULL, v_promo, v_q, v_q, 38, 38, 'ensayo mig1010 reparto', v_admin, v_suc, gen_random_uuid());
    IF public.regalo_sustituto_vigente(v_ped, v_promo, v_a, v_suc) IS NOT NULL
       OR (SELECT r.ya_sustituido FROM public.regalo_sustitucion_resuelta(v_ped, v_promo, v_q, v_suc, 38) r) THEN
      RAISE EXCEPTION 'mig1010 · un reparto posterior no anulo la cadena';
    END IF;

    -- ── Una vuelta A -> P -> A se corta sola: queda A con la marca. ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1010 ciclo');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig1010 A->P', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_a, 6, 'ensayo mig1010 P->A', NULL, NULL);
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad, descripcion_regalo INTO v_prod, v_cant, v_desc
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_a OR v_cant <> 6
       OR v_desc IS DISTINCT FROM ' [Sustituido por: ZZ ensayo mig1010 A]' THEN
      RAISE EXCEPTION 'mig1010 · ciclo: % prod=% (A) cant=% (6) desc=%', v_res, v_prod, v_cant, v_desc;
    END IF;

    -- ── Vuelve a la raiz y sigue: A -> A (6 -> 8) y A -> A (8 -> 9). Editar
    --    sin cambios deja A 9 (antes: la mas nueva sola, A 6). ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1010 raiz');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_a, 8, 'ensayo mig1010 A->A 8', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_a, 9, 'ensayo mig1010 A->A 9', NULL, NULL);
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad INTO v_prod, v_cant FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_a OR v_cant <> 9 THEN
      RAISE EXCEPTION 'mig1010 · raiz A->A->A: % prod=% (A) cant=% (9)', v_res, v_prod, v_cant;
    END IF;

    -- ── Auto-sustitucion al final (patron del pedido 3351): A 6 -> P 19 -> P 18.
    --    El front manda A 6 -> P 18; un bundle viejo manda P 18 -> P 18. ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1010 auto');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig1010 A->P', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 18, 'ensayo mig1010 P->P', NULL, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig1010 · el ensayo no pudo auto-sustituir: %', v_res;
    END IF;
    FOREACH v_n IN ARRAY ARRAY[0, 1] LOOP
      v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
        jsonb_build_object('producto_id', CASE v_n WHEN 0 THEN v_a ELSE v_p END,
                           'cantidad', CASE v_n WHEN 0 THEN 6 ELSE 18 END,
                           'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
        jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
      SELECT producto_id, cantidad, descripcion_regalo INTO v_prod, v_cant, v_desc
        FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
      IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p OR v_cant <> 18
         OR v_desc IS DISTINCT FROM ' [Sustituido por: ZZ ensayo mig1010 P]' THEN
        RAISE EXCEPTION 'mig1010 · auto-sustitucion (%): % prod=% (P) cant=% (18) desc=%',
          CASE v_n WHEN 0 THEN 'A 6' ELSE 'P 18' END, v_res, v_prod, v_cant, v_desc;
      END IF;
    END LOOP;

    -- ── Modo A: el pre-chequeo de stock sigue mirando la cantidad convertida.
    --    A 6 -> R2 19 con R2 en 25 -> 6. Subir la venta a A 12 pide R2 38:
    --    faltan 19 y hay 6. ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_a),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1010 modo A');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_r2, 19, 'ensayo mig1010 modo A', NULL, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig1010 · el ensayo no pudo sustituir en modo A: %', v_res;
    END IF;
    SELECT stock INTO v_stock_a FROM productos WHERE id = v_a;
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 12, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_a),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    SELECT stock INTO v_stock FROM productos WHERE id = v_r2;
    IF COALESCE((v_res->>'success')::boolean, false) OR v_res::text NOT LIKE '%stock insuficiente%' OR v_stock <> 6 THEN
      RAISE EXCEPTION 'mig1010 · modo A, venta x2 sin stock del sustituto: % R2=% (6)', v_res, v_stock;
    END IF;
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_a),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad INTO v_prod, v_cant FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    SELECT stock INTO v_stock FROM productos WHERE id = v_r2;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_r2 OR v_cant <> 19 OR v_stock <> 6
       OR (SELECT stock FROM productos WHERE id = v_a) <> v_stock_a THEN
      RAISE EXCEPTION 'mig1010 · modo A sin cambios: % prod=% (R2) cant=% (19) R2=% (6) A=% (%)',
        v_res, v_prod, v_cant, v_stock, (SELECT stock FROM productos WHERE id = v_a), v_stock_a;
    END IF;

    RAISE EXCEPTION 'mig1010-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'mig1010-ok' THEN RAISE; END IF;
    RAISE NOTICE 'mig1010 · ensayo OK: cadena que vuelve, raiz, una marca, historial, ciclo, auto-sustitucion, reparto y stock en modo A';
  END;

  RAISE NOTICE 'mig1010 · OK';
END
$verif$;

-- ---------------------------------------------------------------------------
-- 6 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig1010_ancla(regprocedure, text, text);

COMMIT;
