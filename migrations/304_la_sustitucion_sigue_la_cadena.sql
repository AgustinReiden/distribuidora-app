-- =========================================================================
-- mig 304 · LA SUSTITUCION SIGUE LA CADENA (#965)
--
-- EL PROBLEMA (medido en prod con un ensayo que se deshizo, 2026-10-07)
-- ----------------------------------------------------------------------
-- La edicion de un pedido borra y reinserta los items, y el trigger
-- `aplicar_sustituciones_regalo_pre_insert` vuelve a aplicar las
-- sustituciones de regalo. Pero solo las reconocia si el regalo llegaba con el
-- producto ORIGINAL, y solo el primer eslabon:
--
-- 1 · Se perdia la descripcion. ModalEditarPedido manda el regalo con el
--     producto que ya tiene la linea --el sustituto-- y el trigger no lo
--     encontraba: la linea quedaba con descripcion_regalo NULL (sin el
--     "[Sustituido por: ...]" que leen la hoja de ruta y la tarjeta).
-- 2 · Se perdia la cantidad. Con un cambio por valor (6 de A -> 19 de P),
--     editar el pedido SIN tocar nada lo dejaba en 6 de P: el modal mandaba P
--     con la cantidad de la promo, que esta en unidades de A.
-- 3 · Cadenas. Con A -> P -> Q, `regalo_sustituto_vigente(A)` devolvia P:
--     buscaba la fila mas nueva cuyo ORIGINAL fuera A, y la de P -> Q tiene
--     original P. Editar mandando A dejaba P x19.
--
-- LA REGLA (decision del dueno, 2026-10-07)
-- ------------------------------------------
-- Desde el producto que llega, la sustitucion mas nueva de ESE producto; de ahi
-- la siguiente, solo si es POSTERIOR a la anterior; y asi hasta que no haya
-- mas. Como cada paso es posterior al anterior, una vuelta A -> P -> A se corta
-- sola y queda lo ultimo que eligio el admin. Un reparto en sabores sigue
-- anulando todo lo anterior de su promo (mig 275): solo cuentan las filas
-- posteriores al ultimo reparto, y las del reparto no reescriben nada. La
-- cantidad se convierte en cada paso con la regla de la 295: si es la que se
-- sustituyo, va la elegida; si cambio y el sustituto es de otra categoria o de
-- otro empaque, proporcional; si no, la que vino.
--
-- QUE CAMBIA
-- ----------
-- · `regalo_sustitucion_resuelta(pedido, promo, producto, sucursal, cantidad)`
--   (nueva): la regla de arriba, en un solo lugar. Devuelve el producto final,
--   la cantidad convertida, cuantos pasos se aplicaron y si el producto que
--   llego YA es el sustituto de una cadena vigente.
-- · El trigger la usa. Si el regalo llega ya sustituido (pasos = 0 pero es el
--   final de una cadena: bundles viejos del PWA), le vuelve a poner la marca
--   "[Sustituido por: ...]" y deja la cantidad como vino: no hay forma de saber
--   en que unidad esta (una linea de reparto conservada viene en la del
--   sustituto; el modal viejo, en la del original).
-- · `regalo_sustituto_vigente` devuelve el final de la cadena.
-- · `actualizar_pedido_items`: el pre-chequeo de stock mira la cantidad
--   CONVERTIDA, no la del JSON, contra la linea de la misma promo. Comparaba
--   la cantidad de la promo (unidades del original) contra la linea del
--   sustituto (unidades del sustituto): en
--   modo A, con un cambio por valor, una edicion que subia la venta pasaba el
--   chequeo y dejaba el stock en negativo (productos.stock no tiene CHECK).
-- · Se dropea `regalo_sustitucion_vigente`: implementaba la regla vieja (el
--   primer eslabon) y no la llama nadie mas.
--
-- El front (ModalEditarPedido) pasa a mandar el regalo como lo calcula la
-- promo --el producto con el que arranco la cadena y la cantidad de la promo--
-- y el server aplica la sustitucion. src/utils/repartoRegalo.ts tiene el
-- espejo de la regla para mostrarla.
--
-- COSTO, STOCK, LOTES
-- -------------------
-- · COSTO-D: el trigger valua con `costo_valuacion` el producto que QUEDA, y
--   `actualizar_pedido_items` sigue valuando despues del INSERT ... RETURNING
--   (mig 257). No cambia de lugar.
-- · Stock y barra se siguen moviendo con lo que QUEDO en la fila (RETURNING,
--   migs 252/295). Ningun camino nuevo sube ni baja stock: STK-F no cambia.
--
-- Permisos: la funcion nueva corre solo desde el server (el trigger y
-- actualizar_pedido_items son SECURITY DEFINER) -> REVOKE a PUBLIC, anon y
-- authenticated. Las parchadas conservan su ACL (el $verif$ la compara).
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio. Se dropea al final.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _mig965_acl ON COMMIT DROP AS
SELECT p.oid::regprocedure::text AS fn, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('aplicar_sustituciones_regalo_pre_insert', 'actualizar_pedido_items',
                     'regalo_sustituto_vigente');

CREATE OR REPLACE FUNCTION public._mig965_ancla(
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
    RAISE EXCEPTION 'mig965 · el ancla aparece % veces en % (se esperaba 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(v_ancla, 160);
  END IF;
  EXECUTE replace(v_def, v_ancla, replace(p_nuevo, E'\r', ''));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · La regla, en un solo lugar.
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
  -- El ultimo reparto de la promo: lo anterior ya no vale (mig 275).
  v_corte_ts timestamptz;
  v_corte_id bigint;
  -- El ultimo eslabon aplicado: el siguiente tiene que ser posterior.
  v_ult_ts   timestamptz;
  v_ult_id   bigint;
  v_nodo     bigint  := p_producto_id;
  -- Contenedor del nodo, para su factor (el del original es el mismo producto,
  -- como en la 295; el de un sustituto, el que eligio el admin).
  v_ajuste   bigint  := p_producto_id;
  v_cant     numeric := p_cantidad;
  v_pasos    integer := 0;
  v_s        pedido_item_sustituciones%ROWTYPE;
BEGIN
  SELECT s.created_at, s.id INTO v_corte_ts, v_corte_id
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id
     AND s.reparto_id IS NOT NULL
   ORDER BY s.created_at DESC, s.id DESC
   LIMIT 1;
  v_ult_ts := v_corte_ts;
  v_ult_id := v_corte_id;

  LOOP
    SELECT s.* INTO v_s
      FROM pedido_item_sustituciones s
     WHERE s.pedido_id = p_pedido_id
       AND s.promocion_id = p_promocion_id
       AND s.sucursal_id = p_sucursal_id
       AND s.reparto_id IS NULL
       AND s.producto_original_id = v_nodo
       AND (v_ult_ts IS NULL OR (s.created_at, s.id) > (v_ult_ts, v_ult_id))
     ORDER BY s.created_at DESC, s.id DESC
     LIMIT 1;
    EXIT WHEN NOT FOUND;

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
    v_ult_ts := v_s.created_at;
    v_ult_id := v_s.id;
    v_pasos  := v_pasos + 1;
  END LOOP;

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

REVOKE ALL ON FUNCTION public.regalo_sustitucion_resuelta(bigint, bigint, bigint, bigint, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_sustitucion_resuelta(bigint, bigint, bigint, bigint, numeric) TO service_role;

-- ---------------------------------------------------------------------------
-- 2 · regalo_sustituto_vigente: el final de la cadena.
--     CREATE OR REPLACE conserva la ACL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.regalo_sustituto_vigente(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint, p_sucursal_id bigint
) RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  -- NULL = el regalo se guarda con el producto que vino.
  -- mig 304 (#965): el final de la cadena de sustituciones, no el primer
  -- eslabon. La regla vive en regalo_sustitucion_resuelta.
  SELECT CASE WHEN r.pasos > 0 THEN r.producto_id END
    FROM public.regalo_sustitucion_resuelta(p_pedido_id, p_promocion_id, p_producto_id, p_sucursal_id, NULL) r;
$fn$;

-- ---------------------------------------------------------------------------
-- 3 · El trigger. Cuerpo entero: es chico y cambia de punta a punta.
--     CREATE OR REPLACE conserva la ACL (postgres + service_role: es trigger).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aplicar_sustituciones_regalo_pre_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_r RECORD;
  v_nombre_sustituto TEXT;
BEGIN
  IF NOT COALESCE(NEW.es_bonificacion, FALSE) THEN
    RETURN NEW;
  END IF;
  IF NEW.promocion_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- mig 304 (#965): la cadena entera, no el primer eslabon, y con la cantidad
  -- convertida en cada paso. La cantidad que vino esta en la unidad del
  -- producto que vino (el original, si el que llama manda el regalo como lo
  -- calcula la promo).
  SELECT * INTO v_r
    FROM public.regalo_sustitucion_resuelta(NEW.pedido_id, NEW.promocion_id, NEW.producto_id,
                                            NEW.sucursal_id, NEW.cantidad);

  IF v_r.pasos > 0 THEN
    NEW.cantidad := v_r.cantidad;
  END IF;

  -- La marca que leen la hoja de ruta y la tarjeta: siempre que se aplico una
  -- sustitucion --tambien una auto-sustitucion P->P, que ajusta la cantidad--,
  -- y si el regalo llego YA sustituido (ya_sustituido): antes se perdia
  -- (borde 1 de #965).
  IF (v_r.pasos > 0 OR v_r.ya_sustituido)
     AND COALESCE(NEW.descripcion_regalo, '') NOT LIKE '%[Sustituido por:%' THEN
    SELECT nombre INTO v_nombre_sustituto
      FROM productos
     WHERE id = v_r.producto_id
       AND sucursal_id = NEW.sucursal_id;
    NEW.descripcion_regalo := COALESCE(NEW.descripcion_regalo, '') ||
                              ' [Sustituido por: ' || COALESCE(v_nombre_sustituto, '?') || ']';
  END IF;

  IF v_r.producto_id IS DISTINCT FROM NEW.producto_id THEN
    NEW.producto_id := v_r.producto_id;

    -- El costo tiene que seguir al producto (issue #537). Quien llamo al INSERT
    -- snapshoteo el costo del producto que mando, que a partir de esta linea ya
    -- no es el de la fila. mig 257 (#673): la cascada es la de costo_valuacion
    -- (mig 238) y no una copia. Sin snapshot previo: esto ES el snapshot. Si el
    -- sustituto no tiene ningun costo cargado queda NULL antes que el del
    -- original: NULL hace que el reporte caiga al costo vivo del producto
    -- correcto, y un numero equivocado no.
    SELECT public.costo_valuacion(NULL, costo_promedio, costo_real, costo_sin_iva,
                                  COALESCE(impuestos_internos, 0))
      INTO NEW.costo_unitario_al_crear
      FROM productos
     WHERE id = v_r.producto_id
       AND sucursal_id = NEW.sucursal_id;
  END IF;
  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4 · actualizar_pedido_items: el pre-chequeo de stock con la cantidad
--     convertida. El primer pre-chequeo (productos inactivos) ya usa
--     regalo_sustituto_vigente, que ahora sigue la cadena.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig965_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      v_producto_sustituto := public.regalo_sustituto_vigente(
        p_pedido_id, v_promocion_id, v_producto_id, v_sucursal);
      IF v_producto_sustituto IS NOT NULL THEN
        v_producto_id := v_producto_sustituto;
      END IF;
    END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
      AND sucursal_id = v_sucursal;$ancla$,
$nuevo$    -- mig 304 (#965): el producto Y la cantidad que van a quedar (la misma
    -- funcion que el trigger). Con la cantidad del JSON, un regalo cambiado
    -- por valor se comparaba en unidades del original contra la linea del
    -- sustituto, y en modo A el stock podia quedar negativo. Pisar
    -- v_cantidad_nueva es seguro por lo mismo que v_producto_id.
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT r.producto_id, r.cantidad INTO v_producto_id, v_cantidad_nueva
        FROM public.regalo_sustitucion_resuelta(p_pedido_id, v_promocion_id, v_producto_id,
                                                v_sucursal, v_cantidad_nueva) r;
    END IF;

    -- Un regalo se compara contra la linea de SU promo: dos promos cuyos
    -- regalos terminan en el mismo producto hacian que el INTO tomara
    -- cualquiera de las dos, y con la cantidad convertida eso puede frenar
    -- una edicion sin cambios.
    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
      AND (NOT v_es_bonificacion OR promocion_id IS NOT DISTINCT FROM v_promocion_id)
      AND sucursal_id = v_sucursal;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · La regla vieja no queda a mano.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.regalo_sustitucion_vigente(bigint, bigint, bigint, bigint);

-- ---------------------------------------------------------------------------
-- 6 · Verificacion.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n       int;
  v_def     text;
  v_audit   jsonb;
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_a bigint; v_p bigint; v_q bigint; v_r bigint; v_v bigint;
  v_promo   bigint;  -- modo B (fraccion), como la 295
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
BEGIN
  -- (a) Permisos y firmas.
  IF to_regprocedure('public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric)') IS NULL THEN
    RAISE EXCEPTION 'mig965 · falta regalo_sustitucion_resuelta';
  END IF;
  IF has_function_privilege('anon', 'public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig965 · regalo_sustitucion_resuelta quedo alcanzable desde afuera del server';
  END IF;
  IF to_regprocedure('public.regalo_sustitucion_vigente(bigint,bigint,bigint,bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig965 · regalo_sustitucion_vigente sigue existiendo';
  END IF;
  SELECT count(*) INTO v_n
    FROM _mig965_acl a
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(a.fn)
   WHERE p.oid IS NULL
      OR p.proacl::text IS DISTINCT FROM a.acl
      OR p.prosecdef IS DISTINCT FROM a.prosecdef OR p.proconfig::text IS DISTINCT FROM a.cfg;
  IF v_n > 0 OR (SELECT count(*) FROM _mig965_acl) <> 3 THEN
    RAISE EXCEPTION 'mig965 · cambio la firma, la ACL, el SECURITY DEFINER o el search_path de % funcion(es)', v_n;
  END IF;

  -- (b) Los cuerpos llevan lo nuevo.
  v_def := pg_get_functiondef('public.aplicar_sustituciones_regalo_pre_insert()'::regprocedure);
  IF v_def NOT LIKE '%regalo_sustitucion_resuelta(%' OR v_def NOT LIKE '%costo_valuacion(%' THEN
    RAISE EXCEPTION 'mig965 · el trigger no usa la regla nueva o perdio costo_valuacion';
  END IF;
  v_def := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  IF v_def NOT LIKE '%regalo_sustitucion_resuelta(p_pedido_id, v_promocion_id, v_producto_id,%'
     OR v_def NOT LIKE '%INTO v_pedido_item_guardado, v_producto_guardado, v_cantidad_guardada%' THEN
    RAISE EXCEPTION 'mig965 · actualizar_pedido_items no quedo como se esperaba';
  END IF;

  -- (c) Compuertas.
  v_audit := public.auditoria_integridad();
  SELECT count(*) INTO v_n
    FROM jsonb_array_elements(v_audit->'checks') c
   WHERE c->>'id' IN ('COSTO-D', 'STK-F', 'PROMO-A', 'PROMO-B', 'BONIF-C', 'BONIF-D', 'STK-B')
     AND NOT (c->>'ok')::boolean;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig965 · auditoria_integridad en rojo: %',
      (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_audit->'checks') c
        WHERE NOT (c->>'ok')::boolean
          AND c->>'id' IN ('COSTO-D','STK-F','PROMO-A','PROMO-B','BONIF-C','BONIF-D','STK-B'));
  END IF;

  -- (d) El ensayo, con productos y promos sinteticos, en un sub-bloque que se
  --     deshace solo (SQLSTATE centinela, como la 295).
  --     A = regalo default (gaseosa, bulto 6). P, Q = otra categoria (bulto
  --     12): cambiar a ellos convierte por valor. R = otra categoria para el
  --     modo A, con poco stock.
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig965 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig965 A', 6000, 50, v_suc, 'ZZ ensayo mig965 gaseosa', 6, 100) RETURNING id INTO v_a;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig965 P', 6000, 40, v_suc, 'ZZ ensayo mig965 snack', 12, 200) RETURNING id INTO v_p;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig965 Q', 6000, 40, v_suc, 'ZZ ensayo mig965 snack', 12, 300) RETURNING id INTO v_q;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig965 R', 6000, 25, v_suc, 'ZZ ensayo mig965 snack', 1, 400) RETURNING id INTO v_r;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig965 vendido', 100, 10, v_suc) RETURNING id INTO v_v;

    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      ajuste_producto_id, producto_regalo_id, unidades_por_bloque, stock_por_bloque,
      regalo_mueve_stock, usos_pendientes)
    VALUES ('ZZ ensayo mig965', 'bonificacion', CURRENT_DATE, v_suc, TRUE,
      v_a, v_a, 6, 1, FALSE, 0) RETURNING id INTO v_promo;
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      producto_regalo_id, regalo_mueve_stock)
    VALUES ('ZZ ensayo mig965 modo A', 'bonificacion', CURRENT_DATE, v_suc, FALSE,
      v_a, TRUE) RETURNING id INTO v_promo_a;

    -- ── Bordes 1 y 2: A 6 -> P 19 (por valor). ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig965');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig965', NULL, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig965 · el ensayo no pudo sustituir: %', v_res;
    END IF;

    -- El front nuevo: el regalo como lo calcula la promo (A 6) -> P 19.
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad, descripcion_regalo INTO v_prod, v_cant, v_desc
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p OR v_cant <> 19
       OR v_desc NOT LIKE '%[Sustituido por: ZZ ensayo mig965 P]%' THEN
      RAISE EXCEPTION 'mig965 · A6 sin cambios: % prod=% (P) cant=% (19) desc=%', v_res, v_prod, v_cant, v_desc;
    END IF;

    -- La venta crece: A 12 -> P 38 (12 * 19 / 6).
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 12, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad INTO v_prod, v_cant FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p OR v_cant <> 38 THEN
      RAISE EXCEPTION 'mig965 · A12: % prod=% (P) cant=% (38)', v_res, v_prod, v_cant;
    END IF;

    -- Un bundle viejo manda el sustituto (P 6): conserva la marca. La cantidad
    -- queda como vino (no se sabe en que unidad esta).
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_p, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad, descripcion_regalo INTO v_prod, v_cant, v_desc
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p OR v_cant <> 6
       OR v_desc NOT LIKE '%[Sustituido por: ZZ ensayo mig965 P]%' THEN
      RAISE EXCEPTION 'mig965 · P6 (bundle viejo): % prod=% cant=% desc=%', v_res, v_prod, v_cant, v_desc;
    END IF;

    -- ── Borde 3: A -> P (19) -> Q (19). ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig965 cadena');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig965 A->P', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_q, 19, 'ensayo mig965 P->Q', NULL, NULL);
    IF public.regalo_sustituto_vigente(v_ped, v_promo, v_a, v_suc) IS DISTINCT FROM v_q THEN
      RAISE EXCEPTION 'mig965 · regalo_sustituto_vigente(A) no es Q: %', public.regalo_sustituto_vigente(v_ped, v_promo, v_a, v_suc);
    END IF;

    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad, descripcion_regalo, costo_unitario_al_crear INTO v_prod, v_cant, v_desc, v_costo
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_q OR v_cant <> 19
       OR v_desc NOT LIKE '%[Sustituido por: ZZ ensayo mig965 Q]%'
       OR v_costo IS DISTINCT FROM (SELECT public.costo_valuacion(NULL, costo_promedio, costo_real, costo_sin_iva,
                                                                  COALESCE(impuestos_internos, 0))
                                      FROM productos WHERE id = v_q) THEN
      RAISE EXCEPTION 'mig965 · cadena A6: % prod=% (Q) cant=% (19) desc=% costo=%', v_res, v_prod, v_cant, v_desc, v_costo;
    END IF;

    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 12, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad INTO v_prod, v_cant FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_q OR v_cant <> 38 THEN
      RAISE EXCEPTION 'mig965 · cadena A12: % prod=% (Q) cant=% (38)', v_res, v_prod, v_cant;
    END IF;

    -- Un reparto posterior anula la cadena (mig 275): A vuelve a quedar A.
    INSERT INTO pedido_item_sustituciones (pedido_id, pedido_item_id, promocion_id, producto_original_id,
      producto_sustituto_id, cantidad_original, cantidad_sustituta, motivo, autorizado_por, sucursal_id, reparto_id)
    VALUES (v_ped, NULL, v_promo, v_q, v_q, 38, 38, 'ensayo mig965 reparto', v_admin, v_suc, gen_random_uuid());
    IF public.regalo_sustituto_vigente(v_ped, v_promo, v_a, v_suc) IS NOT NULL
       OR (SELECT r.ya_sustituido FROM public.regalo_sustitucion_resuelta(v_ped, v_promo, v_q, v_suc, 38) r) THEN
      RAISE EXCEPTION 'mig965 · un reparto posterior no anulo la cadena';
    END IF;

    -- ── Una vuelta A -> P -> A se corta sola: queda A (con la marca: hubo
    --    sustituciones, como con el trigger de antes). ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig965 ciclo');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig965 A->P', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_a, 6, 'ensayo mig965 P->A', NULL, NULL);
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad, descripcion_regalo INTO v_prod, v_cant, v_desc
      FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_a OR v_cant <> 6
       OR COALESCE(v_desc, '') NOT LIKE '%[Sustituido por: ZZ ensayo mig965 A]%' THEN
      RAISE EXCEPTION 'mig965 · ciclo: % prod=% (A) cant=% (6) desc=%', v_res, v_prod, v_cant, v_desc;
    END IF;

    -- ── Auto-sustitucion al final (patron real: pedido 3351, 79->80 y 80->80):
    --    A 6 -> P 19 -> P 18. El front nuevo manda A 6 -> P 18 con marca. Un
    --    bundle viejo manda P 18 (su mapa resolvia P->P) -> P 18 con marca. ──
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig965 auto');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig965 A->P', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 18, 'ensayo mig965 P->P', NULL, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig965 · el ensayo no pudo auto-sustituir: %', v_res;
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
         OR COALESCE(v_desc, '') NOT LIKE '%[Sustituido por: ZZ ensayo mig965 P]%' THEN
        RAISE EXCEPTION 'mig965 · auto-sustitucion (%): % prod=% (P) cant=% (18) desc=%',
          CASE v_n WHEN 0 THEN 'A 6' ELSE 'P 18' END, v_res, v_prod, v_cant, v_desc;
      END IF;
    END LOOP;

    -- ── Modo A: el pre-chequeo de stock mira la cantidad convertida. ──
    -- A 6 -> R 19: R 25 -> 6. Subir la venta a A 12 pide R 38: faltan 19 y hay
    -- 6. Antes pasaba (12 - 19 < 0) y R quedaba en -13.
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_a),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig965 modo A');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_r, 19, 'ensayo mig965 modo A', NULL, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig965 · el ensayo no pudo sustituir en modo A: %', v_res;
    END IF;
    SELECT stock INTO v_stock_a FROM productos WHERE id = v_a;
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 12, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_a),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    SELECT stock INTO v_stock FROM productos WHERE id = v_r;
    IF COALESCE((v_res->>'success')::boolean, false) OR v_res::text NOT LIKE '%stock insuficiente%' OR v_stock <> 6 THEN
      RAISE EXCEPTION 'mig965 · modo A, venta x2 sin stock del sustituto: % R=% (6)', v_res, v_stock;
    END IF;
    -- Sin cambios (A 6): queda R 19 y el stock no se mueve.
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_a),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, cantidad INTO v_prod, v_cant FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    SELECT stock INTO v_stock FROM productos WHERE id = v_r;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_r OR v_cant <> 19 OR v_stock <> 6
       OR (SELECT stock FROM productos WHERE id = v_a) <> v_stock_a THEN
      RAISE EXCEPTION 'mig965 · modo A sin cambios: % prod=% (R) cant=% (19) R=% (6) A=% (%)',
        v_res, v_prod, v_cant, v_stock, (SELECT stock FROM productos WHERE id = v_a), v_stock_a;
    END IF;

    RAISE EXCEPTION 'mig965-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'mig965-ok' THEN RAISE; END IF;
    RAISE NOTICE 'mig965 · ensayo OK: cadena, cantidad por valor, marca, ciclo, auto-sustitucion, reparto y stock en modo A';
  END;

  RAISE NOTICE 'mig965 · OK';
END
$verif$;

-- ---------------------------------------------------------------------------
-- 7 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig965_ancla(regprocedure, text, text);

COMMIT;
