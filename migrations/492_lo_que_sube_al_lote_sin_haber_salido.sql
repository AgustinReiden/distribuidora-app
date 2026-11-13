-- =========================================================================
-- NNN · LO QUE SUBE AL LOTE SIN HABER SALIDO DE ÉL: EL CONTENEDOR DE UNA
--       PROMO Y EL CANJE (reauditoría del 12/11: STK-19, STK-20 y STK-21 de
--       #1558; tarjeta 4 de #1565)
--
-- Agrega una columna a `promo_ajustes` y parcha por ancla
-- `aplicar_uso_promo_acumulador` y `_aplicar_cambio_producto`, con premisa de
-- md5 sobre el cuerpo vivo leído el 12/11 (los dos en LF) y poscondición de
-- md5, definer y ACL. No toca `sincronizar_lotes_stock` ni
-- `_restaurar_lotes_fefo`.
-- Ensayo: scripts/test-contenedor-y-canje-a-su-lote-1558.sql. Se aplica en LF.
--
-- La causa de los tres es una: una subida de stock con una etiqueta de la
-- lista blanca de `trg_lotes_sincronizar` vuelve a un lote por FEFO, aunque la
-- bajada que la compensa haya salido de la bolsa (la bajada come la bolsa
-- primero, mire el origen que mire). El stock total cierra, así que ningún
-- check lo ve.
--
-- =========================================================================
-- 1 · STK-19 · EL FARDO DEL CONTENEDOR VUELVE A DONDE SALIÓ
-- =========================================================================
-- `aplicar_uso_promo_acumulador` cierra un bloque bajando el contenedor (sale
-- de la bolsa primero) y lo deshace subiéndolo con 'auto_ajuste_promo', que va
-- al primer lote con hueco. Con un lote de 100 con 50 vivas y bolsa 40, cada
-- edición del pedido sin cambios (deshace el bloque y lo rehace) pasaba una
-- unidad de la bolsa al lote: 50 → 51 → 52 → 53. Cancelar, eliminar o la
-- salvedad del regalo dejaban el lote en 51 y la bolsa en 39.
--
-- Ahora el bloque dice de dónde salió, como el registro de un envío
-- (`movimiento_sucursal_item_lotes`, 286 y 483):
--   · al bajar, con la foto de los lotes de antes (`_mov_lotes_foto` y
--     `_mov_lotes_diff`, los de los envíos), `promo_ajustes.lotes_pendientes`
--     guarda cuánto salió de cada lote y cuánto de la bolsa (`lote_id` NULL);
--   · al subir, el contenedor entra a la bolsa ('auto_ajuste_promo_a_su_lote',
--     fuera de la lista blanca) y se deshacen los bloques de esa promo en ese
--     contenedor del último al primero: lo que salió de un lote vuelve a ese
--     lote (`_mov_lotes_devolver`, hasta su hueco) y lo que salió de la bolsa
--     queda en la bolsa. Lo deshecho se descuenta de `lotes_pendientes` (NULL
--     cuando no queda nada).
-- Así una edición sin cambios deja el lote y la bolsa como estaban, con la
-- bolsa en 40 o en 0.
--
-- Tres bordes, a propósito:
--   · si el llamador pidió otro origen para la subida (`app.contenedor_origen`,
--     mig 269: cancelar por falta de stock, el fardo vuelve y se merma enseguida),
--     el fardo queda en la bolsa y la merma la come de ahí. El bloque se
--     descuenta igual: no va a volver.
--   · un bloque sin registro (de antes de esta migración, de un contenedor que
--     no tenía lotes al cerrarse, o el consumo de
--     `renormalizar_bloques_por_cambio_factor`) no se deshace por acá: lo que
--     no encuentra registro vuelve a la bolsa. En prod hay 56 subidas
--     'auto_ajuste_promo' y ninguna sobre un producto con lotes (12/11).
--   · el registro apunta a un lote por id. Si el lote ya no existe (se borró
--     con su compra), lo suyo queda en la bolsa.
-- Además el UPDATE del contenedor va sin `app.stock_pedido_item_id`, por las
-- dudas: si el GUC viniera colgado de una línea del llamador del mismo
-- producto, la bajada le escribiría huella a esa línea (`_consumir_lotes_fefo`)
-- y el fardo volvería dos veces, por la huella y por el registro. No se
-- reprodujo en el alta ni en la edición (el ensayo C7 lo cubre).
-- 'auto_ajuste_promo' sigue en la lista blanca: la usa la bajada (que no mira
-- el origen) y ya ninguna subida.
--
-- =========================================================================
-- 2 · STK-20 · EL CANJE DEL MISMO PRODUCTO SÓLO MUEVE LA DIFERENCIA
-- =========================================================================
-- `_aplicar_cambio_producto` subía el devuelto con 'cambio_producto' (lista
-- blanca, FEFO al hueco) y bajaba el entregado de la bolsa. Con el mismo
-- producto (el front lo permite a propósito) y un lote de 100 con 50 y bolsa
-- 40, un canje de 10 por 10 dejaba lote 60 y bolsa 30. Ahora, con el mismo
-- producto y un motivo que reingresa, se mueve sólo la diferencia: si vuelve
-- más de lo que se lleva, la diferencia sube con 'cambio_producto', como el
-- devuelto de un canje entre productos distintos; si se lleva más, baja; si es
-- igual, el stock no se toca. El canje queda en `cambios_productos` igual.
-- En prod hubo 1 canje, de productos distintos (12/11).
--
-- =========================================================================
-- 3 · STK-21 · LA MERMA DEL CANJE QUE NO REINGRESA, CON SU ASIENTO
-- =========================================================================
-- Con vencimiento, rotura o mal estado el devuelto no reingresaba y la merma
-- se asentaba con `stock_anterior = stock_nuevo`: MERMA-B (high) exige
-- `stock_nuevo = stock_anterior − cantidad` y quedaba rojo. Ahora el devuelto
-- entra y se merma en el mismo movimiento, como la salvedad por dañado o
-- vencido (mig 234): las dos patas con 'cambio_producto_merma', fuera de la
-- lista blanca, así entran y salen de la bolsa y no tocan ningún lote. La
-- merma se asienta con el stock de antes y de después de su pata. En prod hay
-- 0 mermas de canje (12/11): no hay filas que corregir.
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
-- Premisa: los cuerpos vivos son los leídos el 12/11 y la columna no existe
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', '73f14080731f45d2e4ce95a8fda4a9d5'),
    ('public._aplicar_cambio_producto(integer,bigint,integer,bigint,integer,text,bigint,uuid,text)', '46db798a7bce7f7bba007e02bdc82300'),
    -- Las que se llaman y no se tocan: si cambian, revisar que sigan sirviendo.
    ('public._mov_lotes_foto(bigint,bigint)',          '6ca074b808d19facff8d224da4a97a5a'),
    ('public._mov_lotes_diff(bigint,bigint,jsonb,integer)', '087b6a5e247316cfb1128d15d5294f10'),
    ('public._mov_lotes_devolver(bigint,jsonb)',       '83ef22b3b0143bf318ead07069ac916e'),
    ('public.sincronizar_lotes_stock()',               '94f541388723d5183b1e77a2c3534943')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'promo_ajustes'
                AND column_name = 'lotes_pendientes') THEN
    RAISE EXCEPTION 'mig NNN · promo_ajustes.lotes_pendientes ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · STK-19 · el registro del bloque
-- ---------------------------------------------------------------------------
ALTER TABLE public.promo_ajustes ADD COLUMN lotes_pendientes jsonb;

COMMENT ON COLUMN public.promo_ajustes.lotes_pendientes IS
  '#1558 (STK-19): de un bloque que bajó el contenedor, lo que todavía no volvió: [{lote_id, cantidad}], lote_id NULL = la bolsa. NULL: nada pendiente, o un bloque sin registro. Lo escribe y lo descuenta sólo aplicar_uso_promo_acumulador.';

CREATE INDEX promo_ajustes_lotes_pendientes_idx
  ON public.promo_ajustes (promocion_id, producto_id, sucursal_id, id)
  WHERE lotes_pendientes IS NOT NULL;

-- aplicar_uso_promo_acumulador: las variables
DO $parche_promo_decl$
DECLARE
  v_def text := pg_get_functiondef('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure);
  v_a text := $a$  v_user_prev      TEXT;
BEGIN$a$;
  v_r text := $r$  v_user_prev      TEXT;
  -- #1558 (STK-19): de dónde salió el fardo de un bloque, y a dónde vuelve.
  v_item_prev      TEXT;
  v_origen_subida  TEXT;
  v_foto           JSONB;
  v_lotes          JSONB;
  v_de_lotes       INT;
  v_pendiente      INT;
  v_toma           INT;
  v_queda          JSONB;
  v_volver         JSONB := '[]'::jsonb;
  t                RECORD;
  e                RECORD;
BEGIN$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · aplicar_uso_promo_acumulador (variables): el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_promo_decl$;

-- aplicar_uso_promo_acumulador: el UPDATE del contenedor
DO $parche_promo_update$
DECLARE
  v_def text := pg_get_functiondef('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure);
  v_a text := $a$    v_user_prev     := current_setting('app.stock_user_id', true);

    -- 'auto_ajuste_promo' esta en la lista blanca de trg_lotes_sincronizar: el
    -- fardo que vuelve, vuelve a su lote (FEFO). La bajada no mira el origen.
    -- mig 269: el llamador puede pedir otro origen para la SUBIDA
    -- (cancelar por falta de stock: el fardo vuelve y se merma enseguida).
    PERFORM set_config('app.stock_origen',
      CASE WHEN v_stock_delta > 0
           THEN COALESCE(NULLIF(current_setting('app.contenedor_origen', true), ''), 'auto_ajuste_promo')
           ELSE 'auto_ajuste_promo' END, true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', COALESCE(p_usuario_id::TEXT, ''), true);

    UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
     WHERE id = v_contenedor AND sucursal_id = p_sucursal_id;

    PERFORM set_config('app.stock_origen',   COALESCE(v_org_prev, ''), true);
    PERFORM set_config('app.stock_ref_tipo', COALESCE(v_ref_tipo_prev, ''), true);
    PERFORM set_config('app.stock_ref_id',   COALESCE(v_ref_id_prev, ''), true);
    PERFORM set_config('app.stock_user_id',  COALESCE(v_user_prev, ''), true);
$a$;
  v_r text := $r$    v_user_prev     := current_setting('app.stock_user_id', true);
    v_item_prev     := current_setting('app.stock_pedido_item_id', true);

    -- #1558 (STK-19): el fardo vuelve a donde salió. La bajada come la bolsa
    -- primero (no mira el origen), así que una subida con una etiqueta de la
    -- lista blanca de trg_lotes_sincronizar mandaba al primer lote con hueco lo
    -- que había salido de la bolsa: el lote crecía en cada edición del pedido.
    -- Ahora la bajada anota de dónde salió (la foto de los lotes, como un
    -- envío) y la subida entra a la bolsa ('auto_ajuste_promo_a_su_lote', fuera
    -- de la lista blanca) y, más abajo, le devuelve a cada lote lo suyo.
    -- mig 269: el llamador puede pedir otro origen para la SUBIDA (cancelar
    -- por falta de stock: el fardo vuelve y se merma enseguida). Entonces queda
    -- en la bolsa, que es de donde lo come la merma.
    v_origen_subida := NULLIF(current_setting('app.contenedor_origen', true), '');
    IF v_stock_delta < 0 AND EXISTS (
         SELECT 1 FROM producto_lotes
          WHERE producto_id = v_contenedor AND sucursal_id = p_sucursal_id) THEN
      v_foto := public._mov_lotes_foto(v_contenedor, p_sucursal_id);
    END IF;

    PERFORM set_config('app.stock_origen',
      CASE WHEN v_stock_delta > 0
           THEN COALESCE(v_origen_subida, 'auto_ajuste_promo_a_su_lote')
           ELSE 'auto_ajuste_promo' END, true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', COALESCE(p_usuario_id::TEXT, ''), true);
    -- El contenedor no es ninguna línea: sin el GUC de la línea, la bajada no
    -- le escribe huella a una del mismo producto que viniera colgada del
    -- llamador (el fardo volvería dos veces, por la huella y por el registro).
    PERFORM set_config('app.stock_pedido_item_id', '', true);

    UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
     WHERE id = v_contenedor AND sucursal_id = p_sucursal_id;

    IF v_foto IS NOT NULL THEN
      -- Lo que salió de cada lote, FEFO; lo que falta para el bloque salió de
      -- la bolsa y va primero, que es como lo come la bajada.
      SELECT COALESCE(SUM(x.cantidad), 0)::INT,
             COALESCE(jsonb_agg(jsonb_build_object('lote_id', x.lote_id, 'cantidad', x.cantidad)
                                ORDER BY x.fecha_vencimiento, x.lote_id), '[]'::jsonb)
        INTO v_de_lotes, v_lotes
        FROM jsonb_to_recordset(public._mov_lotes_diff(v_contenedor, p_sucursal_id, v_foto, -1))
             AS x(lote_id BIGINT, fecha_vencimiento DATE, cantidad INT);
      IF -v_stock_delta > v_de_lotes THEN
        v_lotes := jsonb_build_array(jsonb_build_object('lote_id', NULL, 'cantidad', -v_stock_delta - v_de_lotes))
                   || v_lotes;
      END IF;
    ELSIF v_stock_delta > 0 THEN
      -- Se deshacen los bloques de esta promo en este contenedor del último al
      -- primero, y cada uno del final al principio (lo último que comió la
      -- bajada). Sin lock propio: estas filas sólo las escribe esta función, con
      -- la promo bloqueada desde el principio.
      v_pendiente := v_stock_delta;
      FOR t IN
        SELECT id, lotes_pendientes
          FROM promo_ajustes
         WHERE promocion_id = p_promocion_id
           AND producto_id = v_contenedor
           AND sucursal_id = p_sucursal_id
           AND lotes_pendientes IS NOT NULL
         ORDER BY id DESC
      LOOP
        EXIT WHEN v_pendiente <= 0;
        v_queda := t.lotes_pendientes;
        FOR e IN
          SELECT a.ord, (a.x->>'lote_id')::BIGINT AS lote_id, (a.x->>'cantidad')::INT AS cantidad
            FROM jsonb_array_elements(t.lotes_pendientes) WITH ORDINALITY AS a(x, ord)
           ORDER BY a.ord DESC
        LOOP
          EXIT WHEN v_pendiente <= 0;
          v_toma := LEAST(v_pendiente, e.cantidad);
          CONTINUE WHEN v_toma <= 0;
          IF e.lote_id IS NOT NULL AND v_origen_subida IS NULL THEN
            v_volver := v_volver || jsonb_build_array(jsonb_build_object('lote_id', e.lote_id, 'cantidad', v_toma));
          END IF;
          v_queda := jsonb_set(v_queda, ARRAY[(e.ord - 1)::TEXT, 'cantidad'], to_jsonb(e.cantidad - v_toma));
          v_pendiente := v_pendiente - v_toma;
        END LOOP;
        UPDATE promo_ajustes
           SET lotes_pendientes = (SELECT jsonb_agg(a.x ORDER BY a.ord)
                                     FROM jsonb_array_elements(v_queda) WITH ORDINALITY AS a(x, ord)
                                    WHERE (a.x->>'cantidad')::INT > 0)
         WHERE id = t.id;
      END LOOP;
      -- Lo que salió de un lote vuelve a ese lote, hasta su hueco; lo que no
      -- entra, y lo que salió de la bolsa, queda en la bolsa.
      IF jsonb_array_length(v_volver) > 0 THEN
        PERFORM public._mov_lotes_devolver(p_sucursal_id, v_volver);
      END IF;
    END IF;

    PERFORM set_config('app.stock_origen',   COALESCE(v_org_prev, ''), true);
    PERFORM set_config('app.stock_ref_tipo', COALESCE(v_ref_tipo_prev, ''), true);
    PERFORM set_config('app.stock_ref_id',   COALESCE(v_ref_id_prev, ''), true);
    PERFORM set_config('app.stock_user_id',  COALESCE(v_user_prev, ''), true);
    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_prev, ''), true);
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · aplicar_uso_promo_acumulador (update): el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_promo_update$;

-- aplicar_uso_promo_acumulador: el registro va en la fila del bloque
DO $parche_promo_insert$
DECLARE
  v_def text := pg_get_functiondef('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure);
  v_a text := $a$    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id
    ) VALUES (
      p_promocion_id, v_usos_ajustados, -v_stock_delta,
      v_contenedor, v_merma_id, p_usuario_id, COALESCE(p_motivo, 'Auto-ajuste'), p_sucursal_id
    );$a$;
  v_r text := $r$    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id,
      lotes_pendientes
    ) VALUES (
      p_promocion_id, v_usos_ajustados, -v_stock_delta,
      v_contenedor, v_merma_id, p_usuario_id, COALESCE(p_motivo, 'Auto-ajuste'), p_sucursal_id,
      v_lotes
    );$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · aplicar_uso_promo_acumulador (insert): el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_promo_insert$;

-- ---------------------------------------------------------------------------
-- 2 y 3 · STK-20 y STK-21 · el canje
-- ---------------------------------------------------------------------------
DO $parche_canje$
DECLARE
  v_def text := pg_get_functiondef('public._aplicar_cambio_producto(integer,bigint,integer,bigint,integer,text,bigint,uuid,text)'::regprocedure);
  v_a text := $a$  IF v_reingresa THEN
    UPDATE productos SET stock = stock + p_cantidad_devuelta
     WHERE id = p_producto_devuelto_id;
  END IF;
  UPDATE productos SET stock = stock - p_cantidad_entregada
   WHERE id = p_producto_entregado_id;

  IF NOT v_reingresa THEN
    SELECT stock INTO v_stock_dev_now
      FROM productos WHERE id = p_producto_devuelto_id AND sucursal_id = p_sucursal_id;
    v_merma_motivo := CASE COALESCE(p_motivo,'')
      WHEN 'vencimiento' THEN 'vencimiento'
      WHEN 'rotura' THEN 'rotura'
      ELSE 'decomiso'
    END;
    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      p_producto_devuelto_id, p_cantidad_devuelta, v_merma_motivo,
      'Cambio: producto devuelto no reingresado al stock (' || COALESCE(p_motivo,'') || ')',
      v_stock_dev_now, v_stock_dev_now, p_usuario_id, p_sucursal_id
    );
  END IF;$a$;
  v_r text := $r$  IF v_reingresa AND p_producto_devuelto_id = p_producto_entregado_id THEN
    -- #1558 (STK-20): con el mismo producto se mueve sólo la diferencia. Subir
    -- el devuelto con 'cambio_producto' (lista blanca, FEFO al hueco) y bajar el
    -- entregado (come la bolsa primero) pasaba unidades de la bolsa al lote: 10
    -- por 10 con lote 50/100 y bolsa 40 dejaba lote 60 y bolsa 30. Lo que vuelve
    -- de más sube como el devuelto de un canje entre productos distintos.
    IF p_cantidad_devuelta > p_cantidad_entregada THEN
      UPDATE productos SET stock = stock + (p_cantidad_devuelta - p_cantidad_entregada)
       WHERE id = p_producto_devuelto_id;
    ELSIF p_cantidad_devuelta < p_cantidad_entregada THEN
      UPDATE productos SET stock = stock - (p_cantidad_entregada - p_cantidad_devuelta)
       WHERE id = p_producto_entregado_id;
    END IF;
  ELSE
    IF v_reingresa THEN
      UPDATE productos SET stock = stock + p_cantidad_devuelta
       WHERE id = p_producto_devuelto_id;
    ELSE
      -- #1558 (STK-21): el devuelto entra y se merma en el mismo movimiento,
      -- como la salvedad por dañado o vencido (mig 234). Las dos patas van
      -- fuera de la lista blanca de trg_lotes_sincronizar: entran y salen de la
      -- bolsa sin tocar ningún lote. Antes la merma se asentaba con
      -- stock_anterior = stock_nuevo y MERMA-B quedaba rojo.
      PERFORM set_config('app.stock_origen', 'cambio_producto_merma', true);
      UPDATE productos SET stock = stock + p_cantidad_devuelta
       WHERE id = p_producto_devuelto_id
      RETURNING stock INTO v_stock_dev_now;
      UPDATE productos SET stock = stock - p_cantidad_devuelta
       WHERE id = p_producto_devuelto_id;
      PERFORM set_config('app.stock_origen', 'cambio_producto', true);
      v_merma_motivo := CASE COALESCE(p_motivo,'')
        WHEN 'vencimiento' THEN 'vencimiento'
        WHEN 'rotura' THEN 'rotura'
        ELSE 'decomiso'
      END;
      INSERT INTO mermas_stock (
        producto_id, cantidad, motivo, observaciones,
        stock_anterior, stock_nuevo, usuario_id, sucursal_id
      ) VALUES (
        p_producto_devuelto_id, p_cantidad_devuelta, v_merma_motivo,
        'Cambio: producto devuelto no reingresado al stock (' || COALESCE(p_motivo,'') || ')',
        v_stock_dev_now, v_stock_dev_now - p_cantidad_devuelta, p_usuario_id, p_sucursal_id
      );
    END IF;
    UPDATE productos SET stock = stock - p_cantidad_entregada
     WHERE id = p_producto_entregado_id;
  END IF;$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · _aplicar_cambio_producto: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_canje$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'd74e85aee404b38040059b67125e3175', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._aplicar_cambio_producto(integer,bigint,integer,bigint,integer,text,bigint,uuid,text)', '2f4e56e64fabf2e1e698fcf241dd0f6b', true,
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
