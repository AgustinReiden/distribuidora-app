-- =========================================================================
-- mig 295 · EL REGALO CAMBIA DE EMPAQUE (#950)
--
-- EL PROBLEMA
-- -----------
-- Una promo de fraccion (modo B) cuenta botellas y descuenta un bulto cada N.
-- Hasta aca N salia SIEMPRE de la promo (`promociones.unidades_por_bloque`).
-- Si el regalo de una "6 + 2" de Manaos 3L (fardo x6) se cambiaba por Placer
-- 500 (fardo x12) o por papas (paquete suelto), la barra del sustituto seguia
-- cerrando cada 6 y descontaba un fardo de Placer por cada 6 botellas: el
-- doble de lo que salio. Por eso #954 dejo una regla provisoria de pantalla
-- (misma categoria y subcategoria).
--
-- DECISIONES DEL DUENO (2026-10-06, #950)
-- ---------------------------------------
-- · Pasa poco. La equivalencia es aproximada, POR VALOR.
-- · Placer x12: se acumula y se descuenta un fardo cada 12 regaladas.
-- · Solo el admin puede cambiar a otro producto. Sin lista de permitidos.
--
-- QUE CAMBIA
-- ----------
-- 1 · FICHA: `productos.unidades_por_bulto` (INTEGER NULL, > 0): cuantas
--     unidades sueltas trae UNA unidad de stock. Manaos 3L = 6, Placer 500 =
--     12, papas = 1. NULL = no cargado. NO es `unidades_de_venta_por_fardo`
--     (mig 031): esa dice cuantas unidades DE VENTA hacen un fardo, para la
--     aclaracion de la boleta; esta dice cuantas sueltas trae una unidad de
--     stock, para las barras de regalo.
--
-- 2 · MOTOR (`aplicar_uso_promo_acumulador`): en una promo de FRACCION
--     (modo B: regalo_mueve_stock = false) N y el stock por bloque de cada
--     barra salen de SU CONTENEDOR. Si el contenedor tiene
--     `unidades_por_bulto`, N = ese valor y se descuenta 1 unidad por bloque;
--     si no, los de la promo, como hasta ahora. La puerta de entrada no
--     cambia: una promo que no fracciona (modo A, sin factor) sigue siendo un
--     contador de usos, y en modo A el bulto de la ficha no se mira (mismo
--     gate que `factor_regalo_de_linea`).
--
--     ALCANCE REAL HOY: con el seed (seccion 8), TODOS los contenedores de las
--     promos de fraccion actuales tienen su bulto cargado, asi que todas las
--     barras de hoy cuentan con el bulto de la ficha y
--     `promociones.unidades_por_bloque` queda como RESPALDO (para un contenedor
--     sin el dato). Cambiar el factor de la promo NO renormaliza esas barras
--     (seccion 4); ModalPromocion lo aclara junto al campo.
--
--     Para que todos digan lo mismo, la regla vive en dos helpers:
--       contenedor_de_barra(promo, sabor, sucursal, contenedor_def)
--       unidades_por_bloque_de_barra(promo, sabor, sucursal, contenedor_def)
--     y `factor_regalo_de_linea` (el factor que se congela en la linea, mig
--     212) los usa. El motor lo calcula inline sobre el contenedor que ya
--     resolvio (crea la fila si no existe); el $verif$ comprueba que coincida.
--
-- 3 · FACTOR CONGELADO (`pedido_items.unidades_por_bloque_al_crear`, 212):
--     · el trigger `completar_unidades_por_bloque_item` congela el N de la
--       barra del producto de la linea, no el de la promo. Dos cambios chicos
--       de paso: el gate pasa de `unidades_por_bloque > 1` a `> 0` (con factor
--       1 y sin bulto da 1, igual que antes; con factor 1 y bulto 12 congela
--       12), y la promo se busca por sucursal (la de la linea, o la de la promo
--       si la linea viniera sin sucursal_id);
--     · `sustituir_regalo_pedido` lo RECALCULA para el sustituto. Antes la
--       linea sustituida conservaba el factor del original: cambiar 6 botellas
--       de 3L por 6 paquetes de papas dejaba factor 6, y reporte_gerencial
--       valorizaba esas papas a 1/6 de su costo.
--
-- 4 · RENORMALIZACION por cambio de factor de la promo
--     (`renormalizar_bloques_por_cambio_factor`, `previsualizar_cambio_factor`):
--     una barra cuyo contenedor tiene `unidades_por_bulto` no depende del
--     factor de la promo, asi que no se renormaliza ni se previsualiza con el
--     factor nuevo. La rotacion del regalo default (`rotar_barra_default_de_promo`)
--     no se toca: mueve el resto junto con su contenedor, y N sigue al contenedor.
--
-- 5 · CAMBIAR `unidades_por_bulto` de un producto (trigger nuevo
--     `trg_validar_cambio_unidades_por_bulto`, decision del dueno). Se BLOQUEA:
--     · si alguna barra de la que es contenedor quedaria con un bloque completo
--       sin descontar (usos >= N nuevo). Si queda en [0, N nuevo) el cambio es
--       coherente sin mover nada: la barra cuenta "sueltas que salieron desde
--       el ultimo bulto", y el proximo cierra con el N nuevo;
--     · si hay pedidos NO entregados y no cancelados con regalos que cuentan
--       contra una barra cuyo contenedor es ese producto y cuyo N cambiaria.
--       Esas botellas entraron con el N viejo: una cancelacion posterior
--       desharia bloques con el N nuevo y devolveria stock de mas (P de 12 a 6
--       con la barra en 5: cancelar un P19 devolvia 3 fardos). Hay que esperar
--       a que esos pedidos se entreguen o se cancelen.
--     Renormalizar en silencio (descontar un bulto al tocar la ficha) es justo
--     lo que no queremos que pase sin que nadie lo vea.
--
-- 6 · GUARD DE ROL en `sustituir_regalo_pedido`: cambiar el regalo por un
--     producto de OTRA categoria/subcategoria es solo admin (antes admin o
--     encargado para cualquier cambio). Y en modo B, si el sustituto es de
--     otra categoria y su contenedor no tiene `unidades_por_bulto`, se rechaza
--     pidiendo que se cargue: sin el dato N caeria al de la promo, que es el
--     bug de arriba. El criterio de categoria es `regalo_misma_categoria`, el
--     mismo de src/utils/regaloCompatible.ts. El encargado SI puede cambiar a
--     otro empaque de la MISMA categoria (decision del dueno).
--
-- 7 · REPARTO (`dividir_regalo_pedido`): sigue en la misma unidad que el
--     original (la suma de las partes = la cantidad original), asi que ahora
--     rechaza una parte cuya barra cuente con otro N. Hoy la pantalla ya lo
--     impide (misma categoria y subcategoria); esto lo hace cumplir en el
--     server para que una parte no quede contada en la unidad equivocada.
--
-- 8 · LA SUSTITUCION SOBREVIVE A LA EDICION CON SU CANTIDAD
--     (`aplicar_sustituciones_regalo_pre_insert`, `actualizar_pedido_items`).
--     La edicion borra y reinserta: si el regalo llega con el producto
--     ORIGINAL (el front todavia no cargo las sustituciones, cambio el regalo
--     default, o cualquier llamador que no mapee), el trigger lo reescribia al
--     sustituto pero dejaba la cantidad que llegaba. Medido: sustituir A6 por
--     P19 y editar con A6 dejaba P6 y la barra de P contando 6. Ahora el
--     trigger lee la fila vigente (`regalo_sustitucion_vigente`, la fila mas
--     nueva gana, mig 275) y ajusta la cantidad:
--       · NEW.cantidad = cantidad_original -> cantidad_sustituta;
--       · si no, y el sustituto es de otra categoria o cuenta con otro factor,
--         se escala: GREATEST(1, round(NEW.cantidad * sust / orig));
--       · si no (mismo factor, misma categoria), la cantidad que vino.
--     Una linea de reparto (fila vigente con reparto_id) no se toca, como
--     siempre. Y `actualizar_pedido_items` mueve stock y barra con la cantidad
--     GUARDADA (RETURNING cantidad), no con la del JSON: la misma regla que la
--     252 le aplico al producto.
--     `regalo_sustituto_vigente` pasa a leer del helper nuevo: la regla de
--     cual fila manda vive en un solo lugar.
--
-- 9 · SEED: los productos que hoy son contenedor o regalo de una promo de
--     fraccion con stock_por_bloque = 1 quedan con unidades_por_bulto = N de
--     esa promo, salvo conflicto (dos promos con N distintos para el mismo
--     producto: no se carga y se avisa). Con eso ninguna barra existente
--     cambia de N.
--
-- LO QUE NO HACE
-- --------------
-- · No toca el alta (crear_pedido_completo, _bot): sigue pasando por el motor
--   y por el trigger del factor, que ya leen la regla nueva. De la edicion
--   solo cambia de que cantidad se cuelga el stock (seccion 8).
-- · No toca los GRANTs de las funciones parchadas (el $verif$ los compara).
--   `aplicar_uso_promo_acumulador` sigue SIN authenticated desde la 294.
-- · Los helpers nuevos: `regalo_misma_categoria` y el guard de la ficha solo
--   corren desde funciones del server -> revocados a PUBLIC, anon y
--   authenticated. `contenedor_de_barra`, `unidades_por_bloque_de_barra` y
--   `factor_regalo_de_linea` los llama tambien el trigger del factor, que es
--   SECURITY INVOKER: si algun dia una linea entra por un INSERT de un usuario
--   logueado, el trigger corre con sus permisos. Son de solo lectura (STABLE,
--   INVOKER, RLS aplica): se revocan a PUBLIC y anon y quedan para
--   authenticated.
--
-- Tecnica: cirugia por ancla y por tramo sobre el cuerpo VIVO de prod (molde
-- de las 284/289/294). Si un ancla no aparece exactamente una vez, la
-- migracion entera se cae.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio. Se dropea al final.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _mig950_acl ON COMMIT DROP AS
SELECT p.oid::regprocedure::text AS fn, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('aplicar_uso_promo_acumulador', 'sustituir_regalo_pedido',
                     'dividir_regalo_pedido', 'completar_unidades_por_bloque_item',
                     'renormalizar_bloques_por_cambio_factor', 'previsualizar_cambio_factor',
                     'aplicar_sustituciones_regalo_pre_insert', 'actualizar_pedido_items',
                     'regalo_sustituto_vigente');

CREATE OR REPLACE FUNCTION public._mig950_ancla(
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
    RAISE EXCEPTION 'mig950 · el ancla aparece % veces en % (se esperaba 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(v_ancla, 160);
  END IF;
  EXECUTE replace(v_def, v_ancla, replace(p_nuevo, E'\r', ''));
END;
$fn$;

CREATE OR REPLACE FUNCTION public._mig950_tramo(
  p_funcion regprocedure, p_desde text, p_hasta text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_desde text := replace(p_desde, E'\r', '');
  v_hasta text := replace(p_hasta, E'\r', '');
  v_i     int;
  v_j     int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  IF (length(v_def) - length(replace(v_def, v_desde, ''))) / length(v_desde) <> 1 THEN
    RAISE EXCEPTION 'mig950 · la marca de inicio no aparece exactamente una vez en %: %', p_funcion, left(v_desde, 160);
  END IF;
  IF (length(v_def) - length(replace(v_def, v_hasta, ''))) / length(v_hasta) <> 1 THEN
    RAISE EXCEPTION 'mig950 · la marca de fin no aparece exactamente una vez en %: %', p_funcion, left(v_hasta, 160);
  END IF;
  v_i := strpos(v_def, v_desde);
  v_j := strpos(v_def, v_hasta);
  IF v_j < v_i THEN
    RAISE EXCEPTION 'mig950 · en % la marca de fin esta antes que la de inicio', p_funcion;
  END IF;
  EXECUTE left(v_def, v_i - 1) || replace(p_nuevo, E'\r', '')
       || substr(v_def, v_j + length(v_hasta));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · La columna.
-- ---------------------------------------------------------------------------
ALTER TABLE public.productos
  ADD COLUMN unidades_por_bulto INTEGER NULL
  CONSTRAINT productos_unidades_por_bulto_check CHECK (unidades_por_bulto > 0);

COMMENT ON COLUMN public.productos.unidades_por_bulto IS
  'Cuantas unidades sueltas (botellas, paquetes) trae UNA unidad de stock de este producto. '
  'Manaos 3L = 6, Placer 500 = 12, papas = 1. NULL = no cargado. Lo usan las barras de regalo '
  'de las promos de fraccion (mig 295, #950): una barra cuyo contenedor lo tiene cargado cierra '
  'un bloque cada este numero de sueltas y descuenta 1 unidad. No confundir con '
  'unidades_de_venta_por_fardo (mig 031, aclaracion de la boleta).';

-- ---------------------------------------------------------------------------
-- 2 · Helpers.
-- ---------------------------------------------------------------------------

-- El criterio de src/utils/regaloCompatible.ts, en SQL:
--   · el original siempre es compatible consigo mismo;
--   · categoria: `categoria_id` si los dos lo tienen; si no, el texto
--     normalizado (sin acentos, sin espacios de borde, minusculas). Un
--     original sin categoria solo es compatible consigo mismo;
--   · si el original tiene subcategoria, el candidato tiene que tener la misma.
CREATE OR REPLACE FUNCTION public.regalo_misma_categoria(
  p_original_id bigint, p_candidato_id bigint, p_sucursal_id bigint
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT CASE
    WHEN p_original_id IS NOT DISTINCT FROM p_candidato_id THEN true
    WHEN o.id IS NULL OR c.id IS NULL THEN false
    ELSE
      (CASE WHEN o.categoria_id IS NOT NULL AND c.categoria_id IS NOT NULL
            THEN o.categoria_id = c.categoria_id
            ELSE COALESCE(lower(btrim(public.unaccent(o.categoria))), '') <> ''
                 AND lower(btrim(public.unaccent(o.categoria)))
                     = lower(btrim(public.unaccent(COALESCE(c.categoria, '')))) END)
      AND (o.subcategoria_id IS NULL OR o.subcategoria_id IS NOT DISTINCT FROM c.subcategoria_id)
  END
    FROM (SELECT 1) AS uno
    LEFT JOIN productos o ON o.id = p_original_id  AND o.sucursal_id = p_sucursal_id
    LEFT JOIN productos c ON c.id = p_candidato_id AND c.sucursal_id = p_sucursal_id;
$fn$;

COMMENT ON FUNCTION public.regalo_misma_categoria(bigint, bigint, bigint) IS
  'Mismo criterio que src/utils/regaloCompatible.ts (#950): misma categoria (id, o texto '
  'normalizado si falta) y, si el original tiene subcategoria, la misma. Un cambio de regalo '
  'fuera de este criterio es solo admin (sustituir_regalo_pedido).';

-- El contenedor de la barra (promo, sabor), con la misma regla que el motor:
-- el sabor default -> promociones.ajuste_producto_id; otro sabor -> el de su
-- fila de promo_acumuladores, o (si todavia no tiene) el contenedor por
-- defecto que le pasaria el llamador, o el propio sabor.
CREATE OR REPLACE FUNCTION public.contenedor_de_barra(
  p_promocion_id bigint, p_producto_regalo_id bigint, p_sucursal_id bigint,
  p_contenedor_def bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_promo RECORD;
  v_cont  bigint;
BEGIN
  SELECT producto_regalo_id, ajuste_producto_id INTO v_promo
    FROM promociones WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF p_producto_regalo_id IS NOT NULL AND p_producto_regalo_id = v_promo.producto_regalo_id THEN
    RETURN v_promo.ajuste_producto_id;
  END IF;
  SELECT ajuste_producto_id INTO v_cont
    FROM promo_acumuladores
   WHERE promocion_id = p_promocion_id AND producto_regalo_id = p_producto_regalo_id
     AND sucursal_id = p_sucursal_id;
  IF FOUND THEN
    RETURN v_cont;
  END IF;
  RETURN COALESCE(p_contenedor_def, p_producto_regalo_id);
END;
$fn$;

-- N de la barra: en una promo de fraccion (regalo_mueve_stock = false), el
-- unidades_por_bulto del contenedor si esta cargado; si no (o en modo A), el de
-- la promo. Es la regla del motor (seccion 3), dicha sin mover nada.
CREATE OR REPLACE FUNCTION public.unidades_por_bloque_de_barra(
  p_promocion_id bigint, p_producto_regalo_id bigint, p_sucursal_id bigint,
  p_contenedor_def bigint DEFAULT NULL
) RETURNS integer
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT COALESCE(
           CASE WHEN pr.regalo_mueve_stock IS FALSE THEN
             (SELECT pc.unidades_por_bulto FROM productos pc
               WHERE pc.id = public.contenedor_de_barra(p_promocion_id, p_producto_regalo_id,
                                                        p_sucursal_id, p_contenedor_def)
                 AND pc.sucursal_id = p_sucursal_id) END,
           pr.unidades_por_bloque)
    FROM promociones pr
   WHERE pr.id = p_promocion_id AND pr.sucursal_id = p_sucursal_id;
$fn$;

-- El factor que se congela en la linea (mig 212): mismo gate que tenia el
-- trigger (la promo fracciona: regalo_mueve_stock = false y factor cargado),
-- pero el numero es el N de la barra de ESE producto.
CREATE OR REPLACE FUNCTION public.factor_regalo_de_linea(
  p_promocion_id bigint, p_producto_id bigint, p_sucursal_id bigint,
  p_contenedor_def bigint DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_mueve_stock boolean;
  v_upb         integer;
BEGIN
  SELECT regalo_mueve_stock, unidades_por_bloque INTO v_mueve_stock, v_upb
    FROM promociones WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
  IF NOT FOUND OR v_mueve_stock IS NOT FALSE OR COALESCE(v_upb, 0) <= 0 THEN
    RETURN 1;
  END IF;
  RETURN GREATEST(COALESCE(public.unidades_por_bloque_de_barra(
           p_promocion_id, p_producto_id, p_sucursal_id, p_contenedor_def), 1), 1);
END;
$fn$;

REVOKE ALL ON FUNCTION public.regalo_misma_categoria(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.contenedor_de_barra(bigint, bigint, bigint, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unidades_por_bloque_de_barra(bigint, bigint, bigint, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.factor_regalo_de_linea(bigint, bigint, bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.contenedor_de_barra(bigint, bigint, bigint, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unidades_por_bloque_de_barra(bigint, bigint, bigint, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.factor_regalo_de_linea(bigint, bigint, bigint, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.regalo_misma_categoria(bigint, bigint, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 3 · EL motor: N y stock por bloque, del contenedor de la barra.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure;
BEGIN
  PERFORM public._mig950_ancla(v_fn,
$ancla$  v_acc_id         BIGINT;
$ancla$,
$nuevo$  v_acc_id         BIGINT;
  -- mig 295 (#950): el N y el stock por bloque de ESTA barra.
  v_n              INT;
  v_spb            INT;
  v_bulto          INT;
$nuevo$);

  PERFORM public._mig950_tramo(v_fn,
$desde$  v_usos_raw := v_resto_actual + p_delta;$desde$,
$hasta$    v_usos_ajustados := -(v_blocks * v_promo.unidades_por_bloque);
  END IF;$hasta$,
$nuevo$  -- mig 295 (#950): N y el stock por bloque salen del CONTENEDOR de esta
  -- barra. Con `unidades_por_bulto` cargado, N = ese numero y se descuenta 1
  -- unidad por bloque (el Placer 500 cierra cada 12 aunque la promo sea de 6);
  -- sin el dato, los de la promo, como hasta la 294. Misma regla que
  -- unidades_por_bloque_de_barra(). Solo en modo B (regalo_mueve_stock =
  -- false), con el mismo gate que factor_regalo_de_linea.
  SELECT unidades_por_bulto INTO v_bulto
    FROM productos WHERE id = v_contenedor AND sucursal_id = p_sucursal_id;
  IF v_bulto IS NOT NULL AND v_promo.regalo_mueve_stock IS FALSE THEN
    v_n   := v_bulto;
    v_spb := 1;
  ELSE
    v_n   := v_promo.unidades_por_bloque;
    v_spb := v_promo.stock_por_bloque;
  END IF;

  v_usos_raw := v_resto_actual + p_delta;
  IF v_usos_raw >= 0 THEN
    v_blocks      := FLOOR(v_usos_raw / v_n)::INT;
    v_usos_final  := v_usos_raw - (v_blocks * v_n);
    v_stock_delta := -(v_blocks * v_spb);
    v_usos_ajustados := v_blocks * v_n;
  ELSE
    v_blocks      := CEIL(ABS(v_usos_raw) / v_n)::INT;
    v_usos_final  := v_usos_raw + (v_blocks * v_n);
    v_stock_delta := (v_blocks * v_spb);
    v_usos_ajustados := -(v_blocks * v_n);
  END IF;$nuevo$);

  PERFORM public._mig950_ancla(v_fn,
$ancla$    'unidades_stock', -v_stock_delta
  );$ancla$,
$nuevo$    'unidades_stock', -v_stock_delta,
    'unidades_por_bloque', v_n
  );$nuevo$);
END
$patch$;

COMMENT ON FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT) IS
  'EL motor de las barras de regalo (mig 294, #840). Una barra por (promo, sabor): '
  'la del sabor default en promociones.usos_pendientes, las demas en promo_acumuladores. '
  'Delta + cierra bloques y descuenta del contenedor de ESE sabor; delta - los deshace y '
  'el fardo vuelve a ese mismo contenedor. N sale del contenedor (productos.unidades_por_bulto, '
  'con 1 unidad por bloque) y si no esta cargado, de la promo (mig 295, #950). '
  'En promos sin fraccion mueve el contador de usos.';

-- ---------------------------------------------------------------------------
-- 4 · El factor congelado de la linea: el N de la barra de su producto.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig950_tramo(
    'public.completar_unidades_por_bloque_item()'::regprocedure,
$desde$  SELECT regalo_mueve_stock, unidades_por_bloque$desde$,
$hasta$    NEW.unidades_por_bloque_al_crear := 1;
  END IF;$hasta$,
$nuevo$  -- mig 295 (#950): un solo numero que colapsa gate y divisor, como desde la
  -- 212, pero el divisor es el N de la barra de ESTE producto (el bulto de su
  -- contenedor, o el de la promo si no esta cargado). Si la promo no fracciona
  -- -- o la promocion_id no existe -- el factor es 1, que es neutro.
  -- Antes la promo se buscaba sin sucursal: si la linea llega sin sucursal_id,
  -- se usa la de la promo (los ids de promociones son unicos).
  NEW.unidades_por_bloque_al_crear := public.factor_regalo_de_linea(
    NEW.promocion_id, NEW.producto_id,
    COALESCE(NEW.sucursal_id, (SELECT pr.sucursal_id FROM promociones pr WHERE pr.id = NEW.promocion_id)),
    NEW.producto_id);$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · Cambio de factor de la promo: las barras con bulto propio no dependen
--     de el.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig950_ancla(
    'public.renormalizar_bloques_por_cambio_factor()'::regprocedure,
$ancla$    v_bloques := public.bloques_a_cerrar(v_barra.resto, v_n);$ancla$,
$nuevo$    -- mig 295 (#950): una barra cuyo contenedor tiene unidades_por_bulto
    -- cuenta con ESE numero, no con el de la promo: no cambio nada para ella.
    CONTINUE WHEN NEW.regalo_mueve_stock IS FALSE
              AND EXISTS (SELECT 1 FROM productos pb
                           WHERE pb.id = v_barra.contenedor AND pb.sucursal_id = NEW.sucursal_id
                             AND pb.unidades_por_bulto IS NOT NULL);
    v_bloques := public.bloques_a_cerrar(v_barra.resto, v_n);$nuevo$);

  PERFORM public._mig950_ancla(
    'public.previsualizar_cambio_factor(bigint,integer,integer)'::regprocedure,
$ancla$    SELECT b.*, public.bloques_a_cerrar(b.resto, p_unidades_por_bloque) AS bloques
      FROM barras b$ancla$,
$nuevo$    -- mig 295 (#950): con bulto propio en el contenedor, el factor de la
    -- promo no la toca (bloques_a_cerrar con NULL da 0).
    SELECT b.*, public.bloques_a_cerrar(
             b.resto,
             CASE WHEN (SELECT pr.regalo_mueve_stock FROM promociones pr
                         WHERE pr.id = p_promocion_id AND pr.sucursal_id = b.sucursal_id) IS FALSE
                       AND EXISTS (SELECT 1 FROM productos pb
                                    WHERE pb.id = b.cont_id AND pb.sucursal_id = b.sucursal_id
                                      AND pb.unidades_por_bulto IS NOT NULL)
                  THEN NULL ELSE p_unidades_por_bloque END) AS bloques
      FROM barras b$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · sustituir_regalo_pedido: guard de rol, factor obligatorio y factor
--     congelado del sustituto.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure;
BEGIN
  PERFORM public._mig950_ancla(v_fn,
$ancla$  v_ajuste_sustituto_efectivo BIGINT;
BEGIN$ancla$,
$nuevo$  v_ajuste_sustituto_efectivo BIGINT;
  v_otra_categoria     BOOLEAN;
BEGIN$nuevo$);

  PERFORM public._mig950_ancla(v_fn,
$ancla$  IF v_regalo_mueve_stock THEN
    SELECT stock INTO v_stock_nuevo$ancla$,
$nuevo$  -- mig 295 (#950): cambiar a un producto de OTRA categoria/subcategoria
  -- (criterio de regaloCompatible.ts) es decision del dueno: solo admin. Y en
  -- una promo de fraccion el contenedor del sustituto tiene que decir cuantas
  -- sueltas trae: sin ese dato la barra contaria con el N de la promo, que es
  -- el empaque del ORIGINAL (6 botellas de 3L no son 6 paquetes de papas).
  v_otra_categoria := p_producto_nuevo_id IS DISTINCT FROM v_item.producto_id
                      AND NOT public.regalo_misma_categoria(v_item.producto_id, p_producto_nuevo_id, v_sucursal);
  IF v_otra_categoria AND v_user_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Solo un admin puede cambiar el regalo por un producto de otra categoría');
  END IF;
  IF v_otra_categoria AND NOT v_regalo_mueve_stock
     AND (SELECT pc.unidades_por_bulto FROM productos pc
           WHERE pc.id = public.contenedor_de_barra(v_promo.id, p_producto_nuevo_id,
                                                    v_sucursal, v_ajuste_sustituto_efectivo)
             AND pc.sucursal_id = v_sucursal) IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Para regalar ' || COALESCE(v_nuevo_nombre, 'ese producto')
      || ' hay que cargar en su ficha cuántas unidades sueltas trae cada unidad de stock (unidades por bulto)');
  END IF;

  IF v_regalo_mueve_stock THEN
    SELECT stock INTO v_stock_nuevo$nuevo$);

  PERFORM public._mig950_ancla(v_fn,
$ancla$     SET producto_id = p_producto_nuevo_id, cantidad = p_cantidad_nueva, subtotal = 0,$ancla$,
$nuevo$     SET producto_id = p_producto_nuevo_id, cantidad = p_cantidad_nueva, subtotal = 0,
         -- mig 295 (#950): la linea pasa a contar en la unidad del SUSTITUTO.
         -- El factor congelado (mig 212) es el N de su barra; conservar el del
         -- original hacia que reporte_gerencial dividiera el costo de 6
         -- paquetes de papas por 6. En modo A no se fracciona: queda como estaba.
         unidades_por_bloque_al_crear = CASE WHEN v_regalo_mueve_stock THEN unidades_por_bloque_al_crear
                                             ELSE public.factor_regalo_de_linea(v_item.promocion_id, p_producto_nuevo_id,
                                                                                 v_sucursal, v_ajuste_sustituto_efectivo) END,
         origen_unidades_por_bloque = CASE WHEN v_regalo_mueve_stock THEN origen_unidades_por_bloque
                                           ELSE 'vivo' END,$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7 · dividir_regalo_pedido: todas las partes en la unidad del original.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig950_ancla(
    'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$  v_regalo_mueve_stock := COALESCE(v_promo.regalo_mueve_stock, TRUE);

  -- Consumo NETO por producto$ancla$,
$nuevo$  v_regalo_mueve_stock := COALESCE(v_promo.regalo_mueve_stock, TRUE);

  -- mig 295 (#950): un reparto es en la MISMA unidad que el regalo original
  -- (la suma de las partes es su cantidad), asi que cada parte tiene que
  -- contar con el mismo N de barra. Cambiar a otro empaque es la sustitucion
  -- simple, que convierte por valor.
  IF NOT v_regalo_mueve_stock THEN
    SELECT string_agg(pr.nombre, ', ' ORDER BY pr.nombre) INTO v_nombre
      FROM unnest(v_prod) AS r(producto_id)
      JOIN productos pr ON pr.id = r.producto_id AND pr.sucursal_id = v_sucursal
     WHERE public.unidades_por_bloque_de_barra(v_item.promocion_id, r.producto_id, v_sucursal, r.producto_id)
           IS DISTINCT FROM
           public.unidades_por_bloque_de_barra(v_item.promocion_id, v_item.producto_id, v_sucursal, v_item.producto_id);
    IF v_nombre IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error',
        v_nombre || ' viene en otro empaque que el regalo original: para cambiarlo por otro empaque usá el cambio simple (una sola fila)');
    END IF;
  END IF;

  -- Consumo NETO por producto$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7b · La sustitucion sobrevive a la edicion con su cantidad (cabecera §8).
-- ---------------------------------------------------------------------------
-- La fila de pedido_item_sustituciones que manda para (pedido, promo, producto
-- original): la MAS NUEVA, contando los repartos de la promo (mig 275). Quien
-- llama decide que hacer si es de un reparto (reparto_id no nulo).
CREATE OR REPLACE FUNCTION public.regalo_sustitucion_vigente(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint, p_sucursal_id bigint
) RETURNS SETOF public.pedido_item_sustituciones
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT s.*
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id
     AND (s.producto_original_id = p_producto_id OR s.reparto_id IS NOT NULL)
   ORDER BY s.created_at DESC, s.id DESC
   LIMIT 1;
$fn$;

REVOKE ALL ON FUNCTION public.regalo_sustitucion_vigente(bigint, bigint, bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.regalo_sustitucion_vigente(bigint, bigint, bigint, bigint) TO authenticated, service_role;

DO $patch$
BEGIN
  -- La regla de cual fila manda, en un solo lugar.
  PERFORM public._mig950_ancla(
    'public.regalo_sustituto_vigente(bigint,bigint,bigint,bigint)'::regprocedure,
$ancla$  SELECT CASE WHEN s.reparto_id IS NULL THEN s.producto_sustituto_id END
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id
     AND (s.producto_original_id = p_producto_id OR s.reparto_id IS NOT NULL)
   ORDER BY s.created_at DESC, s.id DESC
   LIMIT 1;$ancla$,
$nuevo$  -- mig 295 (#950): la fila vigente sale de regalo_sustitucion_vigente.
  SELECT CASE WHEN s.reparto_id IS NULL THEN s.producto_sustituto_id END
    FROM public.regalo_sustitucion_vigente(p_pedido_id, p_promocion_id, p_producto_id, p_sucursal_id) s;$nuevo$);

  PERFORM public._mig950_ancla(
    'public.aplicar_sustituciones_regalo_pre_insert()'::regprocedure,
$ancla$  v_costo_sustituto NUMERIC;
BEGIN$ancla$,
$nuevo$  v_costo_sustituto NUMERIC;
  -- mig 295 (#950)
  v_sust public.pedido_item_sustituciones%ROWTYPE;
BEGIN$nuevo$);

  PERFORM public._mig950_ancla(
    'public.aplicar_sustituciones_regalo_pre_insert()'::regprocedure,
$ancla$  v_sustituto := public.regalo_sustituto_vigente(
    NEW.pedido_id, NEW.promocion_id, NEW.producto_id, NEW.sucursal_id);
  IF v_sustituto IS NOT NULL THEN$ancla$,
$nuevo$  -- mig 295 (#950): la fila vigente entera, no solo el producto: la
  -- cantidad tambien se reescribe. Una fila de reparto no reescribe nada.
  SELECT * INTO v_sust
    FROM public.regalo_sustitucion_vigente(NEW.pedido_id, NEW.promocion_id, NEW.producto_id, NEW.sucursal_id);
  v_sustituto := CASE WHEN v_sust.reparto_id IS NULL THEN v_sust.producto_sustituto_id END;
  IF v_sustituto IS NOT NULL THEN
    -- La cantidad que vino esta en la unidad del ORIGINAL. Si es la misma que
    -- se sustituyo, va la sustituta (la que eligio el admin, quiza por valor).
    -- Si cambio y el sustituto es de otra categoria o cuenta con otro factor,
    -- se escala por la misma proporcion. Si no, queda la que vino.
    IF COALESCE(v_sust.cantidad_original, 0) > 0 AND v_sust.cantidad_sustituta IS NOT NULL THEN
      IF NEW.cantidad = v_sust.cantidad_original THEN
        NEW.cantidad := v_sust.cantidad_sustituta;
      ELSIF NOT public.regalo_misma_categoria(NEW.producto_id, v_sustituto, NEW.sucursal_id)
            OR public.factor_regalo_de_linea(NEW.promocion_id, NEW.producto_id, NEW.sucursal_id, NEW.producto_id)
               IS DISTINCT FROM
               public.factor_regalo_de_linea(NEW.promocion_id, v_sustituto, NEW.sucursal_id,
                                             COALESCE(v_sust.ajuste_producto_id_nuevo, v_sustituto)) THEN
        NEW.cantidad := GREATEST(1, round(NEW.cantidad * v_sust.cantidad_sustituta / v_sust.cantidad_original));
      END IF;
    END IF;$nuevo$);
END
$patch$;

DO $patch$
DECLARE v_fn regprocedure := 'public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure;
BEGIN
  PERFORM public._mig950_ancla(v_fn,
$ancla$  v_producto_sustituto BIGINT;
$ancla$,
$nuevo$  v_producto_sustituto BIGINT;
  -- mig 295 (#950): la cantidad que QUEDO en la fila (el trigger de
  -- sustituciones puede haberla reescrito, igual que el producto).
  v_cantidad_guardada INT;
$nuevo$);

  PERFORM public._mig950_ancla(v_fn,
$ancla$    RETURNING id, producto_id INTO v_pedido_item_guardado, v_producto_guardado;$ancla$,
$nuevo$    RETURNING id, producto_id, cantidad INTO v_pedido_item_guardado, v_producto_guardado, v_cantidad_guardada;$nuevo$);

  PERFORM public._mig950_ancla(v_fn,
$ancla$      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;$ancla$,
$nuevo$      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_guardada WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;$nuevo$);

  PERFORM public._mig950_ancla(v_fn,
$ancla$        v_promocion_id, v_producto_guardado, v_cantidad_nueva, v_producto_guardado,$ancla$,
$nuevo$        v_promocion_id, v_producto_guardado, v_cantidad_guardada, v_producto_guardado,$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 8 · SEED: unidades_por_bulto = N de la promo, para los contenedores y
--     regalos de promos de fraccion con 1 unidad por bloque.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _mig950_seed ON COMMIT DROP AS
WITH promos AS (
  SELECT id, sucursal_id, unidades_por_bloque AS n, producto_regalo_id, ajuste_producto_id
    FROM promociones
   WHERE regalo_mueve_stock IS FALSE
     AND COALESCE(ajuste_automatico, false)
     AND COALESCE(unidades_por_bloque, 0) > 0
     AND stock_por_bloque = 1
),
prods AS (
  SELECT sucursal_id, producto_regalo_id AS producto_id, n, id AS promocion_id FROM promos WHERE producto_regalo_id IS NOT NULL
  UNION SELECT sucursal_id, ajuste_producto_id, n, id FROM promos WHERE ajuste_producto_id IS NOT NULL
  UNION SELECT a.sucursal_id, a.producto_regalo_id, p.n, p.id
          FROM promo_acumuladores a JOIN promos p ON p.id = a.promocion_id AND p.sucursal_id = a.sucursal_id
  UNION SELECT a.sucursal_id, a.ajuste_producto_id, p.n, p.id
          FROM promo_acumuladores a JOIN promos p ON p.id = a.promocion_id AND p.sucursal_id = a.sucursal_id
         WHERE a.ajuste_producto_id IS NOT NULL
)
SELECT sucursal_id, producto_id,
       min(n) AS n, (count(DISTINCT n) > 1) AS conflicto,
       string_agg(DISTINCT promocion_id::text || ':' || n, ', ') AS promos
  FROM prods
 GROUP BY sucursal_id, producto_id;

UPDATE productos p
   SET unidades_por_bulto = s.n
  FROM _mig950_seed s
 WHERE NOT s.conflicto
   AND p.id = s.producto_id AND p.sucursal_id = s.sucursal_id
   AND p.unidades_por_bulto IS NULL;

DO $seed$
DECLARE v_r RECORD;
BEGIN
  FOR v_r IN SELECT s.*, p.nombre FROM _mig950_seed s
               LEFT JOIN productos p ON p.id = s.producto_id AND p.sucursal_id = s.sucursal_id
              ORDER BY s.conflicto DESC, s.producto_id LOOP
    RAISE NOTICE 'mig950 · seed % · % (%): %', CASE WHEN v_r.conflicto THEN 'CONFLICTO, no se carga' ELSE 'cargado' END,
      v_r.producto_id, v_r.nombre, CASE WHEN v_r.conflicto THEN 'promos ' || v_r.promos ELSE 'unidades_por_bulto = ' || v_r.n END;
  END LOOP;
END
$seed$;

-- ---------------------------------------------------------------------------
-- 9 · Cambiar unidades_por_bulto con una barra abierta o con pedidos en curso.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_cambio_unidades_por_bulto()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_b       RECORD;
  v_pedidos int;
  v_ids     text;
BEGIN
  -- (a) La barra cuenta "sueltas que salieron desde el ultimo bulto". Si con el N
  -- nuevo sigue en [0, N) el cambio es coherente sin mover nada: el proximo
  -- bulto cierra con el N nuevo. Si quedaria >= N habria un bulto completo
  -- sin descontar: no se renormaliza en silencio desde la ficha, se avisa.
  SELECT pr.nombre AS promo, pg.nombre AS sabor, b.usos,
         COALESCE(NEW.unidades_por_bulto, pr.unidades_por_bloque) AS n_nuevo
    INTO v_b
    FROM (SELECT p.id AS promocion_id, p.sucursal_id, p.producto_regalo_id AS sabor_id,
                 COALESCE(p.usos_pendientes, 0)::numeric AS usos
            FROM promociones p
           WHERE p.ajuste_producto_id = NEW.id AND p.sucursal_id = NEW.sucursal_id
          UNION ALL
          SELECT a.promocion_id, a.sucursal_id, a.producto_regalo_id, COALESCE(a.usos_pendientes, 0)
            FROM promo_acumuladores a
            JOIN promociones p2 ON p2.id = a.promocion_id AND p2.sucursal_id = a.sucursal_id
           WHERE a.ajuste_producto_id = NEW.id AND a.sucursal_id = NEW.sucursal_id
             AND a.producto_regalo_id IS DISTINCT FROM p2.producto_regalo_id) b
    JOIN promociones pr ON pr.id = b.promocion_id AND pr.sucursal_id = b.sucursal_id
    LEFT JOIN productos pg ON pg.id = b.sabor_id AND pg.sucursal_id = b.sucursal_id
   WHERE pr.regalo_mueve_stock IS FALSE
     AND COALESCE(pr.ajuste_automatico, false)
     AND COALESCE(pr.unidades_por_bloque, 0) > 0
     AND COALESCE(pr.stock_por_bloque, 0) > 0
     AND b.usos > 0
     AND b.usos >= COALESCE(NEW.unidades_por_bulto, pr.unidades_por_bloque)
   ORDER BY b.usos DESC
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'No se puede cambiar a % las unidades por bulto de %: la promo "%" ya lleva % de % sin descontar, y quedaría un bulto completo sin bajar del stock. Esperá a que esa barra cierre su bulto o ajustala desde Promociones, y cambialo después.',
      COALESCE(NEW.unidades_por_bulto::text, 'vacío'), NEW.nombre, v_b.promo, v_b.usos, COALESCE(v_b.sabor, '?');
  END IF;

  -- (b) Regalos de pedidos en curso (ni entregados ni cancelados) que cuentan
  -- contra una barra cuyo contenedor es este producto y cuyo N cambiaria. Esas
  -- sueltas entraron con el N viejo: si despues se cancela el pedido, la
  -- devolucion desharia bloques con el N nuevo y devolveria stock de mas (o de
  -- menos). Hasta que se entreguen o se cancelen, el N no se toca.
  SELECT count(DISTINCT pe.id), left(string_agg(DISTINCT '#' || pe.id, ', '), 200)
    INTO v_pedidos, v_ids
    FROM pedido_items pi
    JOIN pedidos pe ON pe.id = pi.pedido_id
    JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
   WHERE pi.sucursal_id = NEW.sucursal_id
     AND COALESCE(pi.es_bonificacion, false)
     AND pe.estado NOT IN ('entregado', 'cancelado', 'anulado')
     AND pr.regalo_mueve_stock IS FALSE
     AND COALESCE(pr.ajuste_automatico, false)
     AND COALESCE(pr.unidades_por_bloque, 0) > 0
     AND COALESCE(pr.stock_por_bloque, 0) > 0
     AND COALESCE(OLD.unidades_por_bulto, pr.unidades_por_bloque)
         IS DISTINCT FROM COALESCE(NEW.unidades_por_bulto, pr.unidades_por_bloque)
     AND public.contenedor_de_barra(pi.promocion_id, pi.producto_id, pi.sucursal_id, pi.producto_id) = NEW.id;
  IF v_pedidos > 0 THEN
    RAISE EXCEPTION 'No se puede cambiar a % las unidades por bulto de %: hay % pedido(s) sin entregar con regalos que se descuentan de este producto (%). Esos regalos se contaron con el valor actual. Esperá a que esos pedidos se entreguen o se cancelen, y cambialo después.',
      COALESCE(NEW.unidades_por_bulto::text, 'vacío'), NEW.nombre, v_pedidos, v_ids;
  END IF;
  RETURN NEW;
END;
$fn$;

REVOKE ALL ON FUNCTION public.validar_cambio_unidades_por_bulto() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.validar_cambio_unidades_por_bulto() TO service_role;

CREATE TRIGGER trg_validar_cambio_unidades_por_bulto
  BEFORE UPDATE OF unidades_por_bulto ON public.productos
  FOR EACH ROW
  WHEN (OLD.unidades_por_bulto IS DISTINCT FROM NEW.unidades_por_bulto)
  EXECUTE FUNCTION public.validar_cambio_unidades_por_bulto();

-- ---------------------------------------------------------------------------
-- 10 · Verificacion.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n        int;
  v_def      text;
  v_audit    jsonb;
  v_admin    uuid;
  v_suc      bigint;
  v_cliente  bigint;
  v_cat_a    text := 'ZZ ensayo mig950 gaseosa';
  v_cat_b    text := 'ZZ ensayo mig950 snack';
  v_a        bigint;  -- regalo default, bulto 6
  v_p        bigint;  -- otro empaque (de otra categoria), bulto 12
  v_s        bigint;  -- otra categoria, bulto 1
  v_v        bigint;  -- vendido
  v_promo    bigint;
  v_res      jsonb;
  v_ped1     bigint;
  v_ped2     bigint;
  v_ped3     bigint;
  v_promo_a  bigint;
  v_item     bigint;
  v_cant     int;
  v_sa int; v_sp int; v_ss int;
  v_bp numeric; v_ba numeric;
  v_factor   int;
BEGIN
  -- (a) La columna, su CHECK y su COMMENT.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'productos'
                    AND column_name = 'unidades_por_bulto' AND data_type = 'integer' AND is_nullable = 'YES') THEN
    RAISE EXCEPTION 'mig950 · falta productos.unidades_por_bulto INTEGER NULL';
  END IF;
  IF col_description('public.productos'::regclass,
       (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.productos'::regclass AND attname = 'unidades_por_bulto')) IS NULL THEN
    RAISE EXCEPTION 'mig950 · unidades_por_bulto sin COMMENT';
  END IF;

  -- (b) Firmas, SECURITY DEFINER, search_path y ACL de lo parchado: como estaban.
  SELECT count(*) INTO v_n
    FROM _mig950_acl a
    LEFT JOIN pg_proc p ON p.oid = a.fn::regprocedure
   WHERE p.oid IS NULL
      OR p.proacl::text IS DISTINCT FROM a.acl
      OR p.prosecdef IS DISTINCT FROM a.prosecdef OR p.proconfig::text IS DISTINCT FROM a.cfg;
  IF v_n > 0 OR (SELECT count(*) FROM _mig950_acl) <> 9 THEN
    RAISE EXCEPTION 'mig950 · cambio la firma, la ACL, el SECURITY DEFINER o el search_path de % funcion(es)', v_n;
  END IF;
  IF has_function_privilege('authenticated', 'public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig950 · el motor quedo abierto a authenticated';
  END IF;
  -- Ninguna funcion nueva alcanzable con la anon key; las de solo server
  -- tampoco con una sesion.
  IF has_function_privilege('anon', 'public.regalo_misma_categoria(bigint,bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.regalo_misma_categoria(bigint,bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.contenedor_de_barra(bigint,bigint,bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.unidades_por_bloque_de_barra(bigint,bigint,bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.factor_regalo_de_linea(bigint,bigint,bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.validar_cambio_unidades_por_bulto()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.validar_cambio_unidades_por_bulto()', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig950 · una funcion nueva quedo alcanzable de mas';
  END IF;

  -- (c) Los cuerpos llevan lo nuevo.
  v_def := pg_get_functiondef('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure);
  IF v_def NOT LIKE '%unidades_por_bulto%' OR v_def LIKE '%/ v_promo.unidades_por_bloque%'
     OR v_def NOT LIKE '%v_org_prev%' THEN
    RAISE EXCEPTION 'mig950 · el motor no toma N del contenedor (o perdio el guardado de GUCs)';
  END IF;
  IF pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure)
       NOT LIKE '%regalo_misma_categoria(%'
     OR pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure)
       NOT LIKE '%factor_regalo_de_linea(%'
     OR pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure)
       NOT LIKE '%costo_valuacion(%' THEN
    RAISE EXCEPTION 'mig950 · sustituir_regalo_pedido sin guard de categoria, sin factor del sustituto o sin costo_valuacion';
  END IF;
  IF pg_get_functiondef('public.completar_unidades_por_bloque_item()'::regprocedure) NOT LIKE '%factor_regalo_de_linea(%' THEN
    RAISE EXCEPTION 'mig950 · el trigger del factor no usa factor_regalo_de_linea';
  END IF;
  v_def := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  IF pg_get_functiondef('public.aplicar_sustituciones_regalo_pre_insert()'::regprocedure) NOT LIKE '%regalo_sustitucion_vigente(%'
     OR pg_get_functiondef('public.regalo_sustituto_vigente(bigint,bigint,bigint,bigint)'::regprocedure) NOT LIKE '%regalo_sustitucion_vigente(%'
     OR v_def NOT LIKE '%INTO v_pedido_item_guardado, v_producto_guardado, v_cantidad_guardada%'
     OR v_def NOT LIKE '%v_promocion_id, v_producto_guardado, v_cantidad_guardada, v_producto_guardado,%'
     -- La venta sigue con la cantidad del JSON; el regalo en modo A, con la guardada.
     OR (length(v_def) - length(replace(v_def, 'stock - v_cantidad_nueva WHERE id = v_producto_guardado', '')))
        / length('stock - v_cantidad_nueva WHERE id = v_producto_guardado') <> 1 THEN
    RAISE EXCEPTION 'mig950 · la edicion no conserva la cantidad de la sustitucion';
  END IF;
  IF has_function_privilege('anon', 'public.regalo_sustitucion_vigente(bigint,bigint,bigint,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig950 · regalo_sustitucion_vigente alcanzable con la anon key';
  END IF;

  -- (d) Seed: ninguna barra de hoy cambio de N, y todas quedan en [0, N).
  SELECT count(*) INTO v_n
    FROM _mig950_seed s
    JOIN productos p ON p.id = s.producto_id AND p.sucursal_id = s.sucursal_id
   WHERE NOT s.conflicto AND p.unidades_por_bulto IS DISTINCT FROM s.n;
  IF v_n > 0 THEN RAISE EXCEPTION 'mig950 · % productos del seed no quedaron con su N', v_n; END IF;

  SELECT count(*) INTO v_n FROM (
    SELECT p.usos_pendientes::numeric AS usos, p.unidades_por_bloque AS n_promo,
           public.unidades_por_bloque_de_barra(p.id, p.producto_regalo_id, p.sucursal_id) AS n_barra
      FROM promociones p
     WHERE COALESCE(p.ajuste_automatico, false) AND COALESCE(p.unidades_por_bloque, 0) > 0
       AND COALESCE(p.stock_por_bloque, 0) > 0 AND p.producto_regalo_id IS NOT NULL
    UNION ALL
    SELECT a.usos_pendientes, p.unidades_por_bloque,
           public.unidades_por_bloque_de_barra(a.promocion_id, a.producto_regalo_id, a.sucursal_id)
      FROM promo_acumuladores a
      JOIN promociones p ON p.id = a.promocion_id AND p.sucursal_id = a.sucursal_id
     WHERE COALESCE(p.ajuste_automatico, false) AND COALESCE(p.unidades_por_bloque, 0) > 0
       AND COALESCE(p.stock_por_bloque, 0) > 0
  ) x
   -- Fuera de rango, o una barra de hoy que el seed le cambio el N.
   WHERE x.usos < 0 OR x.usos >= x.n_barra OR x.n_barra <> x.n_promo;
  IF v_n > 0 THEN RAISE EXCEPTION 'mig950 · % barras fuera de [0, N) o con N distinto del de su promo despues del seed', v_n; END IF;

  -- (e) Compuertas.
  v_audit := public.auditoria_integridad();
  SELECT count(*) INTO v_n
    FROM jsonb_array_elements(v_audit->'checks') c
   WHERE c->>'id' IN ('COSTO-D', 'STK-F', 'PROMO-A', 'PROMO-B', 'BONIF-C', 'BONIF-D', 'MERMA-B', 'MERMA-E', 'STK-B')
     AND NOT (c->>'ok')::boolean;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig950 · auditoria_integridad en rojo: %',
      (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_audit->'checks') c
        WHERE NOT (c->>'ok')::boolean
          AND c->>'id' IN ('COSTO-D','STK-F','PROMO-A','PROMO-B','BONIF-C','BONIF-D','MERMA-B','MERMA-E','STK-B'));
  END IF;

  -- (f) El ensayo, con productos y promo sinteticos, en un sub-bloque que se
  --     deshace solo (SQLSTATE centinela, como la 242/294).
  --     Promo 6 + regalo, default A (bulto 6). P = otro empaque (bulto 12).
  --     Pedido 1: 6 de A -> 1 fardo de A. Sustituir por 6 de P -> vuelve el
  --     fardo de A, barra P = 6, P no se toca, factor de la linea 12.
  --     Pedido 2: igual -> barra P = 12 -> 1 fardo de P, barra P = 0.
  --     Cancelar los dos -> todo como estaba.
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig950 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto)
    VALUES ('ZZ ensayo mig950 3L', 6000, 50, v_suc, v_cat_a, 6) RETURNING id INTO v_a;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto)
    VALUES ('ZZ ensayo mig950 500', 6000, 40, v_suc, v_cat_b, 12) RETURNING id INTO v_p;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto)
    VALUES ('ZZ ensayo mig950 papas', 500, 30, v_suc, v_cat_b, 1) RETURNING id INTO v_s;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig950 vendido', 100, 10, v_suc) RETURNING id INTO v_v;

    INSERT INTO promociones (
      nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      ajuste_producto_id, producto_regalo_id, unidades_por_bloque,
      stock_por_bloque, regalo_mueve_stock, usos_pendientes
    ) VALUES (
      'ZZ ensayo mig950', 'bonificacion', CURRENT_DATE, v_suc, TRUE,
      v_a, v_a, 6, 1, FALSE, 0
    ) RETURNING id INTO v_promo;

    IF public.regalo_misma_categoria(v_a, v_p, v_suc) OR NOT public.regalo_misma_categoria(v_p, v_s, v_suc)
       OR NOT public.regalo_misma_categoria(v_a, v_a, v_suc) THEN
      RAISE EXCEPTION 'mig950 · regalo_misma_categoria no da lo esperado';
    END IF;

    -- En modo A el bulto de la ficha no se mira (mismo gate en el motor y en
    -- el factor de la linea).
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      producto_regalo_id, regalo_mueve_stock)
    VALUES ('ZZ ensayo mig950 modo A', 'bonificacion', CURRENT_DATE, v_suc, FALSE,
      v_p, TRUE) RETURNING id INTO v_promo_a;
    IF public.unidades_por_bloque_de_barra(v_promo_a, v_p, v_suc) IS NOT NULL
       OR public.factor_regalo_de_linea(v_promo_a, v_p, v_suc) <> 1
       OR public.unidades_por_bloque_de_barra(v_promo, v_p, v_suc) IS DISTINCT FROM 12 THEN
      RAISE EXCEPTION 'mig950 · el N de la barra no respeta el gate de modo B';
    END IF;

    FOR v_n IN 1..2 LOOP
      v_res := public.crear_pedido_completo(
        v_cliente, 100, v_admin,
        jsonb_build_array(
          jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0,
                             'es_bonificacion', true, 'promocion_id', v_promo),
          jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)),
        'ensayo mig950');
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'mig950 · el ensayo no pudo crear el pedido: %', v_res;
      END IF;
      IF v_n = 1 THEN v_ped1 := (v_res->>'pedido_id')::bigint; ELSE v_ped2 := (v_res->>'pedido_id')::bigint; END IF;
      SELECT id INTO v_item FROM pedido_items WHERE pedido_id = (v_res->>'pedido_id')::bigint AND es_bonificacion;
      v_res := public.sustituir_regalo_pedido(v_item, v_p, 6, 'ensayo mig950', NULL, NULL);
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'mig950 · el ensayo no pudo sustituir: %', v_res;
      END IF;
      SELECT unidades_por_bloque_al_crear INTO v_factor FROM pedido_items WHERE id = v_item;
      SELECT stock INTO v_sa FROM productos WHERE id = v_a;
      SELECT stock INTO v_sp FROM productos WHERE id = v_p;
      SELECT usos_pendientes INTO v_bp FROM promo_acumuladores WHERE promocion_id = v_promo AND producto_regalo_id = v_p;
      SELECT usos_pendientes INTO v_ba FROM promociones WHERE id = v_promo;
      IF v_factor <> 12 OR v_sa <> 50 OR v_ba <> 0
         OR (v_n = 1 AND (v_sp <> 40 OR v_bp <> 6))
         OR (v_n = 2 AND (v_sp <> 39 OR v_bp <> 0)) THEN
        RAISE EXCEPTION 'mig950 · sustitucion % por otro empaque: factor=% (12), A=% (50), P=% (%), barra P=% (%), barra A=% (0)',
          v_n, v_factor, v_sa, v_sp, CASE WHEN v_n = 1 THEN 40 ELSE 39 END, v_bp, CASE WHEN v_n = 1 THEN 6 ELSE 0 END, v_ba;
      END IF;
    END LOOP;

    -- Pedido 3: sustituir por valor (6 de A -> 19 de P) y editar mandando el
    -- regalo con el producto ORIGINAL (A 6): tiene que quedar P 19, factor 12,
    -- y la barra de P contar 19 (no 6). P 39 -> 38 al sustituir, la edicion
    -- devuelve y vuelve a tomar el mismo bloque: 38, barra 7.
    v_res := public.crear_pedido_completo(
      v_cliente, 100, v_admin,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0,
                           'es_bonificacion', true, 'promocion_id', v_promo),
        jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)),
      'ensayo mig950');
    v_ped3 := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped3 AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 19, 'ensayo mig950 por valor', NULL, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig950 · el ensayo no pudo sustituir por valor: %', v_res;
    END IF;
    v_res := public.actualizar_pedido_items(v_ped3,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'precio_unitario', 0,
                           'es_bonificacion', true, 'promocion_id', v_promo),
        jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)),
      v_admin);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig950 · el ensayo no pudo editar: %', v_res;
    END IF;
    SELECT producto_id, cantidad, unidades_por_bloque_al_crear INTO v_item, v_cant, v_factor
      FROM pedido_items WHERE pedido_id = v_ped3 AND es_bonificacion;
    SELECT stock INTO v_sp FROM productos WHERE id = v_p;
    SELECT stock INTO v_sa FROM productos WHERE id = v_a;
    SELECT usos_pendientes INTO v_bp FROM promo_acumuladores WHERE promocion_id = v_promo AND producto_regalo_id = v_p;
    IF v_item <> v_p OR v_cant <> 19 OR v_factor <> 12 OR v_sp <> 38 OR v_bp <> 7 OR v_sa <> 50 THEN
      RAISE EXCEPTION 'mig950 · la edicion perdio la sustitucion por valor: producto=% (P), cantidad=% (19), factor=% (12), P=% (38), barra P=% (7), A=% (50)',
        v_item, v_cant, v_factor, v_sp, v_bp, v_sa;
    END IF;

    -- Con pedidos en curso que cuentan contra P, su bulto no se cambia
    -- (la barra en 7 < 24 no lo frenaria).
    BEGIN
      UPDATE productos SET unidades_por_bulto = 24 WHERE id = v_p;
      RAISE EXCEPTION 'mig950 · el guard dejo cambiar el bulto con pedidos en curso';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM NOT LIKE '%sin entregar%' THEN RAISE; END IF;
    END;

    FOREACH v_item IN ARRAY ARRAY[v_ped1, v_ped2, v_ped3] LOOP
      v_res := public.cancelar_pedido_con_stock(v_item, 'ensayo mig950', v_admin, 'prueba');
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'mig950 · el ensayo no pudo cancelar: %', v_res;
      END IF;
    END LOOP;
    SELECT stock INTO v_sa FROM productos WHERE id = v_a;
    SELECT stock INTO v_sp FROM productos WHERE id = v_p;
    SELECT stock INTO v_ss FROM productos WHERE id = v_v;
    SELECT COALESCE(usos_pendientes, 0) INTO v_bp FROM promo_acumuladores WHERE promocion_id = v_promo AND producto_regalo_id = v_p;
    SELECT usos_pendientes INTO v_ba FROM promociones WHERE id = v_promo;
    IF v_sa <> 50 OR v_sp <> 40 OR v_ss <> 10 OR v_bp <> 0 OR v_ba <> 0 THEN
      RAISE EXCEPTION 'mig950 · cancelar no deshizo: A=% (50) P=% (40) vendido=% (10) barras P=% A=% (0)',
        v_sa, v_sp, v_ss, v_bp, v_ba;
    END IF;

    -- El guard de la ficha: una barra en 6 no deja bajar el bulto a 6.
    UPDATE promo_acumuladores SET usos_pendientes = 6 WHERE promocion_id = v_promo AND producto_regalo_id = v_p;
    BEGIN
      UPDATE productos SET unidades_por_bulto = 6 WHERE id = v_p;
      RAISE EXCEPTION 'mig950 · el guard dejo bajar unidades_por_bulto con la barra en 6';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM NOT LIKE 'No se puede cambiar a 6%' THEN RAISE; END IF;
    END;
    UPDATE productos SET unidades_por_bulto = 7 WHERE id = v_p;   -- 6 < 7: coherente, pasa

    RAISE EXCEPTION 'mig950-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'mig950-ok' THEN RAISE; END IF;
    RAISE NOTICE 'mig950 · ensayo OK: otro empaque cierra con su N, cancelar deshace, guard de la ficha';
  END;

  RAISE NOTICE 'mig950 · OK';
END
$verif$;

-- ---------------------------------------------------------------------------
-- 11 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig950_ancla(regprocedure, text, text);
DROP FUNCTION public._mig950_tramo(regprocedure, text, text, text);

COMMIT;
