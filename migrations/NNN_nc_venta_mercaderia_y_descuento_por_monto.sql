-- =========================================================================
-- NNN · LA NOTA DE CRÉDITO DE VENTA MUEVE LA MERCADERÍA SEGÚN SU MOTIVO, Y EL
--       DESCUENTO COMERCIAL SE CARGA POR MONTO, SIN UNIDADES
--       (plan #1603, ola 2, tarjeta B22: pedidos del dueño del 17 y 18/11)
--
-- Ensayo: scripts/test-nc-stock-y-descuento-ola2-1603.sql. Dos sesiones:
-- scripts/concurrencia/b22-nota-con-mercaderia.sh. Tiempos:
-- scripts/tiempos-nc-stock-y-descuento-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · LA MERCADERÍA (17/11)
-- =========================================================================
-- «hay casos en los que la nota de crédito significa un reingreso de stock y
-- deberíamos estar preparados para eso». «Si anulamos una nota de crédito, sí
-- vuelve a volverse el stock.» B16 dejó definido en nc_venta_motivos() qué pasa
-- con la mercadería de cada motivo; desde acá se usa:
--   · reingresa (cliente_rechaza, error_pedido, error_entrega): las unidades de
--     cada renglón vuelven al stock y al LOTE del que salieron (la huella de su
--     línea), como la devolución de una salvedad: el origen
--     'nota_credito_venta' entra a la lista blanca de trg_lotes_sincronizar y
--     la línea va en app.stock_pedido_item_id. Lo que excede la huella salió de
--     la bolsa y vuelve a la bolsa. La huella de la línea baja (el cliente ya
--     no tiene esas unidades); la línea, su cantidad y el total de la boleta NO
--     cambian (la nota es un documento aparte).
--   · merma (producto_vencido, producto_danado): devolver y mermar en el mismo
--     movimiento, como la salvedad (234/#1127): neto 0 en stock y lotes, una
--     fila de mermas_stock (vencimiento / rotura, valuada como toda merma por
--     su trigger y por mermas_valorizadas) y la huella de la línea baja.
--   · nada (descuento_comercial, otro).
--   Lo que se hizo queda anotado en el renglón, como en la salvedad:
--   nota_credito_venta_items.lotes_devueltos (a qué lote volvió cada unidad y
--   cuánta huella perdió la línea) y nota_credito_venta_items.merma_id. NULL en
--   las dos: el renglón no movió nada (una nota anterior a esta migración, un
--   renglón por monto o un motivo que no mueve).
--   Anular la nota lo deshace (anular_nota_credito_venta): lo que reingresó
--   sale del lote al que volvió (lo que todavía tenga) y después baja el stock,
--   como anular_salvedad; si hoy hay menos stock que lo que reingresó (se
--   vendió o se dio de baja), se rechaza con el motivo. La merma se anula (el
--   stock no se toca: las unidades siguen vendidas) y la huella de la línea se
--   repone en los dos casos.
--   El costo promedio no se mueve: lo que vuelve entra al promedio vigente,
--   como la devolución de una salvedad o de una cancelación.
--
-- =========================================================================
-- 2 · EL DESCUENTO COMERCIAL POR MONTO (18/11)
-- =========================================================================
-- «lo prolijo sería poder aplicarlo a toda la boleta y que se prorratee el
-- monto en el caso estándar y en un caso avanzado aplicarlo a algún producto
-- en específico. Se puede cargar un descuento comercial sin unidades».
--   · Un renglón sin unidades es cantidad 0 con su plata en subtotal (la foto
--     del precio de la línea en precio_unitario). Los CHECK: cantidad >= 0 y
--     (cantidad > 0 OR subtotal > 0). Ninguna columna numeric nueva.
--   · p_items (misma firma, mismo wrapper: el monto entra en p_contenido):
--       [{pedido_item_id, cantidad}]   por unidades (lo de siempre);
--       [{monto}]                      toda la boleta, prorrateado;
--       [{pedido_item_id, monto}, …]   uno o más renglones, cada uno con su monto.
--     Por monto sólo con descuento_comercial.
--   · El prorrateo es prorratear_cargo (el de los cargos de compra: partes al
--     centavo y el residuo a la de mayor peso), con el peso de lo que cada
--     línea de venta vale hoy: su subtotal (ya neto de salvedades) menos los
--     renglones de las notas vigentes sobre ella. Los regalos (precio 0) y una
--     línea sin producto no reciben nada; ninguna parte pasa lo que le queda a
--     su línea.
--   · El neto y el IVA de cada parte salen de la foto de su línea
--     (_nc_venta_desglose): la nota guarda la suma, y una FC queda con
--     neto + iva = total al centavo.
--   · Una nota por unidades sobre una línea que ya tiene un descuento acredita
--     lo que le queda a la línea por unidad (la última unidad, lo que quede):
--     sin descuento en la línea es cantidad × precio, como siempre.
--   · Tope de toda nota: esta más las vigentes no pasa lo vendido en la boleta
--     (Σ de sus líneas de venta, sin el envío).
--   · Lo del vendedor no cambia de regla: cada parte resta de la clave de su
--     línea (_nc_resta_comision), así que lo que baja la comisión suma el monto.
--   · _ventas_nc: el ingreso real de un renglón cuyo subtotal no es
--     cantidad × precio (por monto, o con descuento previo) es proporcional a su
--     subtotal; con cantidad 0 daba 0.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- Las tablas con DDL, sus locks primero y sin esperar: nota_credito_venta_items
-- (columnas y CHECK) en ACCESS EXCLUSIVE; mermas_stock (la FK nueva hacia ella)
-- en SHARE ROW EXCLUSIVE.
LOCK TABLE public.nota_credito_venta_items IN ACCESS EXCLUSIVE MODE NOWAIT;
LOCK TABLE public.mermas_stock IN SHARE ROW EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 529.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
  v_n bigint;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'e8d17459ee31d40072d3ecc9db0f9e46'),
    ('public.crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)', 'e92f59da39844598b948b7da652977a0'),
    ('public.anular_nota_credito_venta(bigint,text)', 'd0b0d273d0bd089f3a441f566f433d48'),
    ('public.sincronizar_lotes_stock()', '94f541388723d5183b1e77a2c3534943'),
    ('public._ventas_nc(bigint[],date,date)', 'c44fdae60942de6e93649d62b2024d75'),
    ('public._restaurar_lotes_fefo(bigint,bigint,integer)', '359fb1708b4385f6947d1127a2b8e439'),
    ('public._mov_lotes_foto(bigint,bigint)', '6ca074b808d19facff8d224da4a97a5a'),
    ('public._mov_lotes_diff(bigint,bigint,jsonb,integer)', '087b6a5e247316cfb1128d15d5294f10'),
    ('public.prorratear_cargo(numeric,jsonb)', '3d96a1fb66ba9549ec72892eb5f3ed59'),
    ('public._monto_de_cobro(numeric)', 'c41436f32c24e5a81fcce533e86ea04b'),
    ('public.nc_venta_motivos()', 'ff6636880e4c0573e957cc9e0f8fc648'),
    ('public._credito_bloquea_boletas(bigint,bigint,bigint,numeric)', NULL),
    ('public._credito_bloquea_rutas_y_creditos(bigint[],bigint,bigint,bigint)', NULL),
    ('public._aplicar_credito_pagos(bigint,bigint,bigint[])', NULL)
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
  IF to_regproc('public._nc_venta_desglose') IS NOT NULL
     OR to_regproc('public._nc_venta_mover_mercaderia') IS NOT NULL
     OR to_regproc('public._nc_venta_deshacer_mercaderia') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · algo de esta migración ya existe: revisar a mano';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.nota_credito_venta_items'::regclass
                AND attname IN ('lotes_devueltos', 'merma_id') AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · las columnas nuevas de nota_credito_venta_items ya existen: revisar a mano';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'nota_credito_venta_items_cantidad_check'
                    AND conrelid = 'public.nota_credito_venta_items'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · falta el CHECK nota_credito_venta_items_cantidad_check: revisar a mano';
  END IF;
  -- Los datos: el CHECK nuevo es más ancho que el de hoy (cantidad > 0), así que
  -- todo renglón que existe lo cumple. Sólo se informa.
  SELECT count(*) INTO v_n FROM public.nota_credito_venta_items;
  RAISE NOTICE 'mig NNN · % renglones de notas de crédito de venta: ninguno movió mercadería (quedan con lotes_devueltos y merma_id en NULL)', v_n;
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
-- Tabla: el renglón sin unidades y la anotación de la mercadería
-- =========================================================================
ALTER TABLE public.nota_credito_venta_items
  DROP CONSTRAINT nota_credito_venta_items_cantidad_check,
  ADD CONSTRAINT nota_credito_venta_items_cantidad_check CHECK (cantidad >= 0),
  ADD CONSTRAINT nota_credito_venta_items_cantidad_o_monto CHECK (cantidad > 0 OR subtotal > 0),
  ADD COLUMN lotes_devueltos jsonb,
  ADD COLUMN merma_id bigint,
  ADD CONSTRAINT nota_credito_venta_items_merma_fkey
    FOREIGN KEY (merma_id, sucursal_id) REFERENCES public.mermas_stock (id, sucursal_id);

COMMENT ON COLUMN public.nota_credito_venta_items.cantidad IS
  'Unidades acreditadas. 0 = renglón por monto (un descuento comercial sin unidades, B22): la plata es subtotal.';
COMMENT ON COLUMN public.nota_credito_venta_items.lotes_devueltos IS
  'B22: lo que la nota hizo con la mercadería del renglón, para que anularla lo deshaga: a qué lote volvió cada unidad (cantidad) y cuánta huella perdió la línea (huella), como salvedades_items.lotes_devueltos. NULL: no movió nada. Sólo lo escribe el server.';
COMMENT ON COLUMN public.nota_credito_venta_items.merma_id IS
  'B22: la merma del renglón (motivos vencido y dañado). Anular la nota la anula.';

-- =========================================================================
-- El desglose de una parte en plata de una línea (neto e IVA de su foto)
-- =========================================================================
CREATE FUNCTION public._nc_venta_desglose(p_monto numeric, p_precio numeric, p_neto_u numeric, p_iva_u numeric,
                                          OUT neto numeric, OUT iva numeric)
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  -- B22 (#1603): una parte de p_monto de una línea de precio p_precio. El IVA y lo
  -- que la línea no declara ni como neto ni como IVA (impuestos internos fuera del
  -- neto, si los hay) salen en proporción, al centavo; el neto es el resto, así
  -- neto + iva + lo otro = la parte, y una FC (neto + iva = precio) cierra.
  SELECT p_monto - x.iva - x.otro, x.iva
    FROM (SELECT CASE WHEN COALESCE(p_precio, 0) > 0
                      THEN round(p_monto * COALESCE(p_iva_u, 0) / p_precio, 2) ELSE 0 END AS iva,
                 CASE WHEN COALESCE(p_precio, 0) > 0 AND p_neto_u IS NOT NULL
                      THEN round(p_monto * (p_precio - p_neto_u - COALESCE(p_iva_u, 0)) / p_precio, 2)
                      ELSE 0 END AS otro) x
$function$;

-- =========================================================================
-- Mover la mercadería de una nota recién creada
-- =========================================================================
CREATE FUNCTION public._nc_venta_mover_mercaderia(p_nota_credito_id bigint, p_usuario uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- B22 (#1603): lo que la nota hace con la mercadería según su motivo
-- (nc_venta_motivos().mercaderia), renglón por renglón con unidades. Son las
-- piezas de registrar_salvedad, sin cambiarle nada a ella:
--   · reingresa: la subida con un origen de la lista blanca y la línea en
--     app.stock_pedido_item_id, así _restaurar_lotes_fefo la devuelve al lote de
--     su huella (y baja la huella); lo que la excede vuelve a la bolsa. La foto
--     y la diferencia de los lotes (_mov_lotes_foto / _mov_lotes_diff) dicen a
--     qué lote volvió.
--   · merma: la huella de la línea baja FEFO sobre su propia huella (#1127), y
--     la devolución y la merma van en el mismo movimiento con la devolución
--     fuera de la lista blanca (234): neto 0 en stock y lotes.
-- La anotación es la de salvedades_items.lotes_devueltos; la lee
-- _nc_venta_deshacer_mercaderia. Quien llama ya tiene la boleta y los
-- productos (por id); los lotes y la huella se toman acá, después de su
-- producto. Los GUC se guardan y se restauran (son por transacción).
DECLARE
  v_nc            record;
  r               record;
  h               record;
  v_g_origen      text := current_setting('app.stock_origen', true);
  v_g_ref_tipo    text := current_setting('app.stock_ref_tipo', true);
  v_g_ref_id      text := current_setting('app.stock_ref_id', true);
  v_g_user        text := current_setting('app.stock_user_id', true);
  v_g_item        text := current_setting('app.stock_pedido_item_id', true);
  v_lotes_antes   jsonb;
  v_huella_antes  jsonb;
  v_diff          jsonb;
  v_anot          jsonb;
  v_merma_id      bigint;
  v_stock         integer;
  v_pend          integer;
  v_baja          integer;
  v_total         integer := 0;
BEGIN
  SELECT n.id, n.sucursal_id, n.pedido_id, n.motivo, m.mercaderia
    INTO v_nc
    FROM notas_credito_venta n
    JOIN public.nc_venta_motivos() m ON m.motivo = n.motivo
   WHERE n.id = p_nota_credito_id;
  IF NOT FOUND OR v_nc.mercaderia NOT IN ('reingresa', 'merma') THEN
    RETURN 0;
  END IF;

  PERFORM 1 FROM productos
   WHERE sucursal_id = v_nc.sucursal_id
     AND id IN (SELECT i.producto_id FROM nota_credito_venta_items i
                 WHERE i.nota_credito_id = p_nota_credito_id AND i.cantidad > 0)
   ORDER BY id
     FOR UPDATE;

  PERFORM set_config('app.stock_ref_tipo', 'nota_credito_venta', true);
  PERFORM set_config('app.stock_ref_id', p_nota_credito_id::text, true);
  PERFORM set_config('app.stock_user_id', COALESCE(p_usuario::text, ''), true);

  FOR r IN
    SELECT i.id, i.pedido_item_id, i.producto_id, i.cantidad
      FROM nota_credito_venta_items i
     WHERE i.nota_credito_id = p_nota_credito_id
       AND i.cantidad > 0
       AND i.lotes_devueltos IS NULL AND i.merma_id IS NULL
     ORDER BY i.id
  LOOP
    v_merma_id := NULL;
    v_diff := NULL;

    -- La huella de la línea antes de tocar nada: la diferencia con la de después
    -- es lo que anular le repone.
    SELECT COALESCE(jsonb_object_agg(x.lote_id::text, x.cantidad), '{}'::jsonb)
      INTO v_huella_antes
      FROM (SELECT pil.lote_id, SUM(pil.cantidad)::int AS cantidad
              FROM pedido_item_lotes pil
             WHERE pil.pedido_item_id = r.pedido_item_id
               AND pil.sucursal_id = v_nc.sucursal_id
             GROUP BY pil.lote_id) x;

    IF v_nc.mercaderia = 'reingresa' THEN
      v_lotes_antes := public._mov_lotes_foto(r.producto_id, v_nc.sucursal_id);
      PERFORM set_config('app.stock_origen', 'nota_credito_venta', true);
      PERFORM set_config('app.stock_pedido_item_id', COALESCE(r.pedido_item_id::text, ''), true);
      UPDATE productos
         SET stock = stock + r.cantidad
       WHERE id = r.producto_id AND sucursal_id = v_nc.sucursal_id;
      PERFORM set_config('app.stock_pedido_item_id', '', true);
      v_diff := public._mov_lotes_diff(r.producto_id, v_nc.sucursal_id, v_lotes_antes, 1);
    ELSE
      -- #1127: el cliente ya no tiene esas unidades; la huella baja primero por
      -- sus lotes, FEFO sobre la propia huella. Lo que la excede salió de la bolsa.
      v_pend := r.cantidad;
      FOR h IN
        SELECT pil.id, pil.cantidad
          FROM pedido_item_lotes pil
          JOIN producto_lotes l ON l.id = pil.lote_id
         WHERE pil.pedido_item_id = r.pedido_item_id
           AND pil.sucursal_id = v_nc.sucursal_id
         ORDER BY l.fecha_vencimiento, l.id, pil.id
           FOR UPDATE OF pil
      LOOP
        EXIT WHEN v_pend <= 0;
        v_baja := LEAST(v_pend, h.cantidad);
        IF v_baja >= h.cantidad THEN
          DELETE FROM pedido_item_lotes WHERE id = h.id;
        ELSE
          UPDATE pedido_item_lotes SET cantidad = cantidad - v_baja WHERE id = h.id;
        END IF;
        v_pend := v_pend - v_baja;
      END LOOP;

      -- 234: la devolución que se cancela sola no va etiquetada (a la bolsa), y la
      -- bajada es una merma que apunta a su fila, como registrar_merma_manual.
      PERFORM set_config('app.stock_origen', 'nota_credito_venta_merma', true);
      UPDATE productos
         SET stock = stock + r.cantidad
       WHERE id = r.producto_id AND sucursal_id = v_nc.sucursal_id;
      SELECT stock INTO v_stock
        FROM productos
       WHERE id = r.producto_id AND sucursal_id = v_nc.sucursal_id;
      INSERT INTO mermas_stock (
        producto_id, cantidad, motivo, observaciones,
        stock_anterior, stock_nuevo, usuario_id, sucursal_id
      ) VALUES (
        r.producto_id, r.cantidad,
        CASE v_nc.motivo WHEN 'producto_danado' THEN 'rotura' ELSE 'vencimiento' END,
        'Nota de crédito de venta #' || p_nota_credito_id || ' (pedido #' || v_nc.pedido_id || ')',
        v_stock, GREATEST(v_stock - r.cantidad, 0), p_usuario, v_nc.sucursal_id
      ) RETURNING id INTO v_merma_id;
      PERFORM set_config('app.stock_origen', 'merma', true);
      PERFORM set_config('app.stock_ref_tipo', 'mermas_stock', true);
      PERFORM set_config('app.stock_ref_id', v_merma_id::text, true);
      UPDATE productos
         SET stock = stock - r.cantidad
       WHERE id = r.producto_id AND sucursal_id = v_nc.sucursal_id;
      PERFORM set_config('app.stock_ref_tipo', 'nota_credito_venta', true);
      PERFORM set_config('app.stock_ref_id', p_nota_credito_id::text, true);
    END IF;

    -- La anotación, como la de registrar_salvedad: a qué lotes volvió (cantidad)
    -- y cuánta huella perdió la línea en cada lote (huella), con la clave de
    -- respaldo del lote (compra y vencimiento).
    WITH lotes AS (
      SELECT x.lote_id, x.cantidad
        FROM jsonb_to_recordset(COALESCE(v_diff, '[]'::jsonb)) AS x(lote_id bigint, cantidad integer)
    ), despues AS (
      SELECT pil.lote_id, SUM(pil.cantidad)::int AS cantidad
        FROM pedido_item_lotes pil
       WHERE pil.pedido_item_id = r.pedido_item_id
         AND pil.sucursal_id = v_nc.sucursal_id
       GROUP BY pil.lote_id
    ), huella AS (
      SELECT a.key::bigint AS lote_id, a.value::int - COALESCE(d.cantidad, 0) AS cantidad
        FROM jsonb_each_text(v_huella_antes) a
        LEFT JOIN despues d ON d.lote_id = a.key::bigint
       WHERE a.value::int - COALESCE(d.cantidad, 0) > 0
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'lote_id',  COALESCE(l.lote_id, hu.lote_id),
             'cantidad', COALESCE(l.cantidad, 0),
             'huella',   COALESCE(hu.cantidad, 0),
             'compra_id',         pl.compra_id,
             'fecha_vencimiento', pl.fecha_vencimiento)
           ORDER BY COALESCE(l.lote_id, hu.lote_id)), '[]'::jsonb)
      INTO v_anot
      FROM lotes l
      FULL JOIN huella hu ON hu.lote_id = l.lote_id
      LEFT JOIN producto_lotes pl ON pl.id = COALESCE(l.lote_id, hu.lote_id);

    UPDATE nota_credito_venta_items
       SET lotes_devueltos = v_anot,
           merma_id = v_merma_id
     WHERE id = r.id;
    v_total := v_total + r.cantidad;
  END LOOP;

  PERFORM set_config('app.stock_origen',         COALESCE(v_g_origen, ''),   true);
  PERFORM set_config('app.stock_ref_tipo',       COALESCE(v_g_ref_tipo, ''), true);
  PERFORM set_config('app.stock_ref_id',         COALESCE(v_g_ref_id, ''),   true);
  PERFORM set_config('app.stock_user_id',        COALESCE(v_g_user, ''),     true);
  PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_g_item, ''),     true);
  RETURN v_total;
END;
$function$;

-- =========================================================================
-- Deshacer la mercadería de una nota que se anula
-- =========================================================================
CREATE FUNCTION public._nc_venta_deshacer_mercaderia(p_nota_credito_id bigint, p_usuario uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- B22 (#1603): lo inverso de _nc_venta_mover_mercaderia, con las piezas de
-- anular_salvedad (#1050, #1073, #1142, mig 365), sin cambiarle nada a ella:
--   · lo que reingresó sale primero de cada lote al que volvió (lo que todavía
--     tenga: se pudo vender después), y recién después baja el stock: para el
--     trigger esas unidades ya son bolsa y la bajada se come esas. Lo que no
--     está en el lote sale de la bolsa y, si no alcanza, FEFO con huella para
--     la línea, como una venta.
--   · Si hoy hay menos stock que lo que reingresó, se rechaza con el motivo (y
--     no con el 23514 de productos_stock_no_negativo).
--   · La merma se anula y el stock no se toca: las unidades siguen vendidas.
--   · La huella que la línea perdió se le repone, con el tope de la línea
--     (LOTE-D) y el del lote (lo que consumió de verdad).
-- Un renglón sin anotación (nota anterior a B22, por monto, o un motivo que no
-- mueve) no hace nada. Quien llama ya tiene la boleta y los productos.
DECLARE
  v_nc          record;
  r             record;
  r_lote        record;
  r_l           record;
  v_item_id     bigint;
  v_g_origen    text := current_setting('app.stock_origen', true);
  v_g_ref_tipo  text := current_setting('app.stock_ref_tipo', true);
  v_g_ref_id    text := current_setting('app.stock_ref_id', true);
  v_g_user      text := current_setting('app.stock_user_id', true);
  v_g_item      text := current_setting('app.stock_pedido_item_id', true);
  v_pend        integer;
  v_saca        integer;
  v_cap         integer;
  v_huella      integer;
  v_i           integer;
  v_rep_lote    bigint[];
  v_rep_dev     integer[];
  v_rep_hue     integer[];
  v_total       integer := 0;
BEGIN
  SELECT n.id, n.sucursal_id, n.pedido_id, m.mercaderia
    INTO v_nc
    FROM notas_credito_venta n
    JOIN public.nc_venta_motivos() m ON m.motivo = n.motivo
   WHERE n.id = p_nota_credito_id;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM nota_credito_venta_items i
                               WHERE i.nota_credito_id = p_nota_credito_id
                                 AND (i.lotes_devueltos IS NOT NULL OR i.merma_id IS NOT NULL)) THEN
    RETURN 0;
  END IF;

  PERFORM 1 FROM productos
   WHERE sucursal_id = v_nc.sucursal_id
     AND id IN (SELECT i.producto_id FROM nota_credito_venta_items i
                 WHERE i.nota_credito_id = p_nota_credito_id
                   AND (i.lotes_devueltos IS NOT NULL OR i.merma_id IS NOT NULL))
   ORDER BY id
     FOR UPDATE;

  -- Antes de tocar nada: la merma está viva, y el stock alcanza para sacar lo que
  -- reingresó (con dos renglones del mismo producto, la suma).
  IF EXISTS (SELECT 1
               FROM nota_credito_venta_items i
               LEFT JOIN mermas_stock m ON m.id = i.merma_id AND m.sucursal_id = i.sucursal_id
              WHERE i.nota_credito_id = p_nota_credito_id
                AND i.merma_id IS NOT NULL
                AND (m.id IS NULL OR m.anulada_at IS NOT NULL)) THEN
    RAISE EXCEPTION 'No se puede anular la nota de crédito #%: generó una merma y la merma ya no está para anularla. Revisar a mano.',
      p_nota_credito_id USING ERRCODE = '22023';
  END IF;
  FOR r IN
    SELECT p.id, p.nombre, p.stock, SUM(i.cantidad)::int AS reingreso
      FROM nota_credito_venta_items i
      JOIN productos p ON p.id = i.producto_id AND p.sucursal_id = i.sucursal_id
     WHERE i.nota_credito_id = p_nota_credito_id
       AND i.lotes_devueltos IS NOT NULL AND i.merma_id IS NULL
     GROUP BY p.id, p.nombre, p.stock
    HAVING p.stock < SUM(i.cantidad)
     ORDER BY p.id
     LIMIT 1
  LOOP
    RAISE EXCEPTION 'No se puede anular la nota de crédito #%: con ella reingresaron % u. de «%» y hoy hay % en stock (se vendieron o se dieron de baja después). Para anularla, primero corregí el stock.',
      p_nota_credito_id, r.reingreso, r.nombre, r.stock USING ERRCODE = '22023';
  END LOOP;

  FOR r IN
    SELECT i.id, i.pedido_item_id, i.producto_id, i.cantidad, i.lotes_devueltos, i.merma_id
      FROM nota_credito_venta_items i
     WHERE i.nota_credito_id = p_nota_credito_id
       AND (i.lotes_devueltos IS NOT NULL OR i.merma_id IS NOT NULL)
     ORDER BY i.id
  LOOP
    SELECT pi.id INTO v_item_id
      FROM pedido_items pi
     WHERE pi.id = r.pedido_item_id AND pi.sucursal_id = v_nc.sucursal_id
       FOR UPDATE;
    v_rep_lote := '{}';
    v_rep_dev  := '{}';
    v_rep_hue  := '{}';
    v_pend := CASE WHEN r.merma_id IS NULL THEN r.cantidad ELSE 0 END;

    FOR r_lote IN
      SELECT l.id, l.cantidad, l.cantidad_restante, a.devuelto, a.huella
        FROM (
          SELECT l2.id,
                 SUM(COALESCE(x.cantidad, 0))::integer AS devuelto,
                 SUM(COALESCE(x.huella, 0))::integer   AS huella
            FROM jsonb_to_recordset(COALESCE(r.lotes_devueltos, '[]'::jsonb))
                 AS x(lote_id bigint, cantidad integer, huella integer,
                      compra_id bigint, fecha_vencimiento date)
            -- mig 331: por id, o por (compra, producto, vencimiento).
            JOIN producto_lotes l2
              ON (l2.id = x.lote_id
                  OR (x.compra_id IS NOT NULL
                      AND l2.compra_id = x.compra_id
                      AND l2.fecha_vencimiento = x.fecha_vencimiento))
             AND l2.producto_id = r.producto_id
             AND l2.sucursal_id = v_nc.sucursal_id
           GROUP BY l2.id
        ) a
        JOIN producto_lotes l ON l.id = a.id
       ORDER BY l.fecha_vencimiento, l.id
         FOR UPDATE OF l
    LOOP
      v_saca := GREATEST(LEAST(r_lote.devuelto, r_lote.cantidad_restante, v_pend), 0);
      IF v_saca > 0 THEN
        UPDATE producto_lotes
           SET cantidad_restante = cantidad_restante - v_saca
         WHERE id = r_lote.id;
        v_pend := v_pend - v_saca;
      END IF;
      v_rep_lote := v_rep_lote || r_lote.id;
      v_rep_dev  := v_rep_dev  || r_lote.devuelto;
      v_rep_hue  := v_rep_hue  || r_lote.huella;
    END LOOP;

    IF r.merma_id IS NULL THEN
      PERFORM set_config('app.stock_origen',   'nota_credito_venta_anulada', true);
      PERFORM set_config('app.stock_ref_tipo', 'nota_credito_venta',         true);
      PERFORM set_config('app.stock_ref_id',   p_nota_credito_id::text,      true);
      PERFORM set_config('app.stock_user_id',  COALESCE(p_usuario::text, ''), true);
      PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_id::text, ''), true);
      UPDATE productos
         SET stock = stock - r.cantidad
       WHERE id = r.producto_id AND sucursal_id = v_nc.sucursal_id;
      PERFORM set_config('app.stock_pedido_item_id', '', true);
    ELSE
      -- mig 244: la merma se anula y el stock no se toca.
      UPDATE mermas_stock
         SET anulada_at = now(), anulada_por = p_usuario
       WHERE id = r.merma_id AND sucursal_id = v_nc.sucursal_id;
    END IF;

    -- #1142 / #1073 (mig 365): la huella que la línea perdió, después de la bajada
    -- (si la bolsa no alcanzó, la bajada ya le escribió huella en otro lote), con
    -- el tope de la línea y el del lote. Un lote sólo para la traza se repone
    -- entero y su cantidad cubre la huella que lo apunta.
    IF v_item_id IS NOT NULL THEN
      v_cap := GREATEST(
        COALESCE((SELECT cantidad FROM pedido_items WHERE id = v_item_id), 0)
        - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE pedido_item_id = v_item_id), 0);
      FOR v_i IN 1 .. COALESCE(array_length(v_rep_lote, 1), 0) LOOP
        SELECT cantidad, cantidad_restante, solo_traza INTO r_l FROM producto_lotes WHERE id = v_rep_lote[v_i];
        IF r_l.solo_traza THEN
          v_huella := LEAST(v_rep_hue[v_i], v_cap);
        ELSE
          v_huella := LEAST(
            GREATEST(LEAST(
              LEAST(v_rep_hue[v_i], v_rep_dev[v_i]),
              (r_l.cantidad - r_l.cantidad_restante)
                - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = v_rep_lote[v_i])), 0)
              + GREATEST(v_rep_hue[v_i] - v_rep_dev[v_i], 0),
            v_cap);
        END IF;
        IF v_huella > 0 THEN
          INSERT INTO pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
          VALUES (v_item_id, v_rep_lote[v_i], v_huella, v_nc.sucursal_id)
          ON CONFLICT (pedido_item_id, lote_id)
            DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
          v_cap := v_cap - v_huella;
          IF r_l.solo_traza THEN
            UPDATE producto_lotes
               SET cantidad = GREATEST(cantidad,
                     (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = v_rep_lote[v_i]))
             WHERE id = v_rep_lote[v_i];
          END IF;
        END IF;
      END LOOP;
    END IF;
    v_total := v_total + r.cantidad;
  END LOOP;

  PERFORM set_config('app.stock_origen',         COALESCE(v_g_origen, ''),   true);
  PERFORM set_config('app.stock_ref_tipo',       COALESCE(v_g_ref_tipo, ''), true);
  PERFORM set_config('app.stock_ref_id',         COALESCE(v_g_ref_id, ''),   true);
  PERFORM set_config('app.stock_user_id',        COALESCE(v_g_user, ''),     true);
  PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_g_item, ''),     true);
  RETURN v_total;
END;
$function$;

REVOKE ALL ON FUNCTION public._nc_venta_desglose(numeric, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._nc_venta_mover_mercaderia(bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._nc_venta_deshacer_mercaderia(bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._nc_venta_desglose(numeric, numeric, numeric, numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public._nc_venta_mover_mercaderia(bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._nc_venta_deshacer_mercaderia(bigint, uuid) TO service_role;

-- =========================================================================
-- trg_lotes_sincronizar: el reingreso de una nota vuelve a su lote
-- =========================================================================
DO $sls$
DECLARE
  v_def text := pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
    $a$'movimiento_editado') THEN$a$,
    $n$'movimiento_editado', 'nota_credito_venta') THEN$n$,
    'sincronizar_lotes_stock');
  EXECUTE v_def;
END
$sls$;

-- =========================================================================
-- _ventas_nc: el ingreso real de un renglón que no es cantidad × precio
-- =========================================================================
CREATE OR REPLACE FUNCTION public._ventas_nc(p_sucs bigint[], p_desde date, p_hasta date)
 RETURNS TABLE(nota_credito_id bigint, fecha date, sucursal_id bigint, pedido_id bigint, cliente_id bigint, zona_id bigint, usuario_id uuid, tipo_factura text, pedido_item_id bigint, producto_id bigint, cantidad integer, monto numeric, iva numeric, ingreso_real numeric, costo_al_crear numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT n.id, n.fecha, n.sucursal_id, n.pedido_id, n.cliente_id, c.zona_id, pe.usuario_id,
         COALESCE(pe.tipo_factura, 'ZZ')::text, i.pedido_item_id, i.producto_id, i.cantidad,
         i.subtotal,
         i.subtotal * n.iva / n.total,
         -- B22 (#1603): un renglón por monto (cantidad 0) o uno por unidades que
         -- acredita menos que cantidad × precio (la línea tenía un descuento) da el
         -- ingreso real en proporción a su plata; los de siempre, como siempre.
         CASE WHEN pi.id IS NOT NULL AND i.subtotal = i.cantidad * pi.precio_unitario
              THEN i.cantidad * COALESCE(pi.ingreso_real_unitario,
                                         CASE WHEN pe.tipo_factura = 'FC'
                                              THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                              ELSE pi.precio_unitario END)
              WHEN pi.id IS NOT NULL AND pi.precio_unitario > 0
              THEN i.subtotal * COALESCE(pi.ingreso_real_unitario,
                                         CASE WHEN pe.tipo_factura = 'FC'
                                              THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                              ELSE pi.precio_unitario END)
                   / pi.precio_unitario
              ELSE i.subtotal * CASE WHEN pe.tipo_factura = 'FC' THEN n.neto ELSE n.total END / n.total
         END,
         pi.costo_unitario_al_crear
    FROM notas_credito_venta n
    JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
    JOIN pedidos pe ON pe.id = n.pedido_id
    LEFT JOIN pedido_items pi ON pi.id = i.pedido_item_id
    LEFT JOIN clientes c ON c.id = n.cliente_id
   WHERE NOT n.anulada
     AND n.total > 0
     AND n.sucursal_id = ANY(p_sucs)
     AND n.fecha BETWEEN p_desde AND p_hasta
     AND pe.estado = 'entregado'
     AND COALESCE(pe.canal, 'app') <> 'cambio'
     AND pe.tipo_factura IS DISTINCT FROM 'VB'
$function$;

-- =========================================================================
-- crear_nota_credito_venta_impl: los dos modos y la mercadería
-- =========================================================================
CREATE OR REPLACE FUNCTION public.crear_nota_credito_venta_impl(p_pedido_id bigint, p_cliente_id bigint, p_items jsonb, p_motivo text, p_observaciones text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal  bigint := current_sucursal_id();
  v_user      uuid   := auth.uid();
  v_rol       text;
  v_fecha     date   := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha_nc  date;     -- B16: la de imputación, la de la boleta
  v_resta_com boolean;  -- B16 v3: la foto del vendedor
  v_pedido    RECORD;
  v_it        RECORD;
  v_total     numeric := 0;
  v_neto      numeric := 0; -- #1257
  v_iva       numeric := 0;
  v_nc_id     bigint;
  v_pago_id   bigint;
  v_n         integer;
  v_n_dist    integer;
  -- #1512 (COB-1)
  v_estimado  numeric;
  v_falta     numeric;
  v_boletas   bigint[];
  v_aplicar   numeric;
  v_aplicado  numeric := 0;
  v_otras     numeric := 0;
  v_guc       text;
  v_extra     numeric := 0;
  -- B22 (#1603)
  v_modo        text;     -- 'unidades' | 'monto'
  v_mercaderia  text;     -- reingresa | merma | nada (nc_venta_motivos)
  v_n_con_id    integer;
  v_monto       numeric;
  v_filas       jsonb := '[]'::jsonb;
  v_pesos       jsonb;
  v_resto_m     numeric;
  v_resto_u     integer;
  v_cant        integer;
  v_sub         numeric;
  v_neto_r      numeric;
  v_iva_r       numeric;
  v_vendido     numeric;
  v_vigentes    numeric;
  v_movidas     integer := 0;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  -- Rol primario crudo, como registrar_pago_cliente_fifo_impl: es el espejo de
  -- puedeCrearNotaCreditoVenta (src/lib/permisos.ts).
  -- SEG-1 (#1545): un desactivado no tiene rol aunque su token siga vivo.
  SELECT rol INTO v_rol FROM perfiles WHERE id = v_user AND COALESCE(activo, true);
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden emitir notas de credito'
      USING ERRCODE = '42501';
  END IF;

  -- B16 v3: la lista es una, nc_venta_motivos().
  IF NOT public.es_motivo_nc_venta(COALESCE(p_motivo, '')) THEN
    RAISE EXCEPTION 'Motivo invalido: %', p_motivo USING ERRCODE = '22023';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'La nota de credito necesita al menos un item' USING ERRCODE = '22023';
  END IF;

  -- B22 (#1603, decisión del dueño del 18/11): una nota va por unidades (cada
  -- renglón con su cantidad, como siempre) o por monto (un descuento comercial:
  -- [{monto}] sobre toda la boleta, que se prorratea, o [{pedido_item_id, monto}]
  -- sobre uno o más renglones). No se mezclan.
  SELECT CASE WHEN bool_and(jsonb_typeof(e) = 'object' AND e ? 'cantidad' AND NOT e ? 'monto') THEN 'unidades'
              WHEN bool_and(jsonb_typeof(e) = 'object' AND e ? 'monto' AND NOT e ? 'cantidad') THEN 'monto' END
    INTO v_modo
    FROM jsonb_array_elements(p_items) e;
  IF v_modo IS NULL THEN
    RAISE EXCEPTION 'Cada renglón de la nota de crédito lleva una cantidad o un monto, no las dos cosas ni una mezcla'
      USING ERRCODE = '22023';
  END IF;
  SELECT m.mercaderia INTO v_mercaderia FROM public.nc_venta_motivos() m WHERE m.motivo = p_motivo;
  IF v_modo = 'monto' AND p_motivo IS DISTINCT FROM 'descuento_comercial' THEN
    RAISE EXCEPTION 'Un monto sin unidades es sólo para un descuento comercial: con otro motivo se acredita por unidades'
      USING ERRCODE = '22023';
  END IF;

  -- #1512 (COB-1): el credito baja esta boleta y lo que sobra va FIFO a las
  -- otras del cliente (aplicar_credito_cliente, al final). Las que puede
  -- alcanzar se toman ahora, por id y con esta, antes que sus rutas y los
  -- creditos (_credito_bloquea_boletas). Se lee sin lock: lo que sobra es a lo
  -- sumo lo que la NC pasa lo que debe esta boleta. Si el pedido no existe o no
  -- es del cliente, no se toma nada y lo dice el SELECT de abajo.
  SELECT GREATEST(p.total - COALESCE(p.monto_pagado, 0), 0)
    INTO v_falta
    FROM pedidos p
   WHERE p.id = p_pedido_id AND p.sucursal_id = v_sucursal AND p.cliente_id = p_cliente_id;
  IF FOUND THEN
    IF v_modo = 'unidades' THEN
      SELECT COALESCE(sum((e->>'cantidad')::numeric * COALESCE(pi.precio_unitario, 0)), 0)
        INTO v_estimado
        FROM jsonb_array_elements(p_items) e
        JOIN pedido_items pi
          ON pi.id::text = e->>'pedido_item_id'
         AND pi.pedido_id = p_pedido_id
         AND pi.sucursal_id = v_sucursal
       WHERE e->>'cantidad' ~ '^[0-9]{1,9}$';
    ELSE
      SELECT COALESCE(sum(round((e->>'monto')::numeric, 2)), 0)
        INTO v_estimado
        FROM jsonb_array_elements(p_items) e
       WHERE e->>'monto' ~ '^[0-9]{1,10}([.][0-9]{1,9})?$';
    END IF;
    v_extra := GREATEST(v_estimado - v_falta, 0);
    v_boletas := public._credito_bloquea_boletas(p_pedido_id, p_cliente_id, v_sucursal, v_extra);
  END IF;

  -- El lock del pedido serializa dos NCs simultaneas sobre las mismas lineas.
  SELECT id, cliente_id, estado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido no encontrado' USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND tipo_factura = 'VB') THEN
    RAISE EXCEPTION 'El pedido #% es un vale blanco (consumo interno): no admite nota de credito. Si hay que bajarle el total, es una salvedad.', p_pedido_id
      USING ERRCODE = '22023';
  END IF;
  IF v_pedido.estado IS DISTINCT FROM 'entregado' THEN
    RAISE EXCEPTION 'Solo se puede emitir una nota de credito sobre un pedido entregado (estado: %)',
      v_pedido.estado USING ERRCODE = '22023';
  END IF;
  IF v_pedido.cliente_id IS DISTINCT FROM p_cliente_id THEN
    RAISE EXCEPTION 'El pedido #% no es de este cliente', p_pedido_id USING ERRCODE = '22023';
  END IF;

  SELECT count(*), count(DISTINCT e->>'pedido_item_id'), count(e->>'pedido_item_id')
    INTO v_n, v_n_dist, v_n_con_id
    FROM jsonb_array_elements(p_items) e;
  IF v_modo = 'unidades' AND v_n <> v_n_dist THEN
    RAISE EXCEPTION 'Hay items repetidos en la nota de credito' USING ERRCODE = '22023';
  END IF;
  IF v_modo = 'monto' AND v_n_con_id = 0 AND v_n > 1 THEN
    RAISE EXCEPTION 'Un descuento sobre toda la boleta es un solo monto' USING ERRCODE = '22023';
  END IF;
  IF v_modo = 'monto' AND v_n_con_id > 0 AND (v_n_con_id <> v_n OR v_n_dist <> v_n) THEN
    RAISE EXCEPTION 'Un descuento por renglón lleva cada renglón una sola vez, y no se mezcla con uno sobre toda la boleta'
      USING ERRCODE = '22023';
  END IF;

  IF v_modo = 'unidades' THEN
    -- Validacion y total. El precio sale del pedido, nunca del cliente.
    FOR v_it IN
      SELECT r.pedido_item_id_txt,
             r.cantidad_txt,
             pi.id                             AS pi_id,
             pi.producto_id,
             pi.cantidad                       AS entregada,
             pi.precio_unitario,
             pi.neto_unitario,
             pi.iva_unitario,
             pi.subtotal,
             COALESCE(pi.es_bonificacion, false) AS es_bonif,
             COALESCE(a.cantidad, 0)           AS ya_acreditada,
             COALESCE(a.monto, 0)              AS ya_monto
        FROM (
          SELECT e->>'pedido_item_id' AS pedido_item_id_txt,
                 e->>'cantidad'       AS cantidad_txt,
                 o
            FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)
        ) r
        LEFT JOIN pedido_items pi
          ON pi.id::text = r.pedido_item_id_txt
         AND pi.pedido_id = p_pedido_id
         AND pi.sucursal_id = v_sucursal
        LEFT JOIN LATERAL (
          SELECT SUM(i.cantidad) AS cantidad, SUM(i.subtotal) AS monto
            FROM nota_credito_venta_items i
            JOIN notas_credito_venta n ON n.id = i.nota_credito_id
           WHERE i.pedido_item_id = pi.id AND NOT n.anulada
        ) a ON true
       ORDER BY r.o
    LOOP
      IF v_it.pi_id IS NULL THEN
        RAISE EXCEPTION 'El item % no pertenece al pedido #%', v_it.pedido_item_id_txt, p_pedido_id
          USING ERRCODE = '22023';
      END IF;
      IF v_it.cantidad_txt IS NULL OR v_it.cantidad_txt !~ '^[0-9]+$' OR v_it.cantidad_txt::integer <= 0 THEN
        RAISE EXCEPTION 'Cantidad invalida para el item %: %', v_it.pi_id, COALESCE(v_it.cantidad_txt, 'vacia')
          USING ERRCODE = '22023';
      END IF;
      IF v_it.es_bonif THEN
        RAISE EXCEPTION 'El item % es un regalo de promocion: no se cobro, no se acredita', v_it.pi_id
          USING ERRCODE = '22023';
      END IF;
      IF v_it.producto_id IS NULL THEN
        RAISE EXCEPTION 'El item % es de un producto que ya no existe: no se puede acreditar por unidades', v_it.pi_id
          USING ERRCODE = '22023';
      END IF;
      v_cant := v_it.cantidad_txt::integer;
      IF v_cant > v_it.entregada - v_it.ya_acreditada THEN
        RAISE EXCEPTION 'Item %: se entregaron % y ya se acreditaron %; no se pueden acreditar %',
          v_it.pi_id, v_it.entregada, v_it.ya_acreditada, v_it.cantidad_txt USING ERRCODE = '22023';
      END IF;
      v_resto_u := v_it.entregada - v_it.ya_acreditada;
      v_resto_m := COALESCE(v_it.subtotal, 0) - v_it.ya_monto;
      IF v_resto_m = v_resto_u * COALESCE(v_it.precio_unitario, 0) THEN
        -- Lo de siempre: cantidad × precio, y #1257: la foto de la linea (lo que el
        -- pedido declaro por esas unidades).
        v_sub   := v_cant * COALESCE(v_it.precio_unitario, 0);
        v_iva_r := v_cant * COALESCE(v_it.iva_unitario, 0);
        v_neto_r := v_cant * COALESCE(v_it.neto_unitario,
                                      COALESCE(v_it.precio_unitario, 0) - COALESCE(v_it.iva_unitario, 0));
      ELSE
        -- B22: la línea ya tiene un descuento por monto. Cada unidad acredita lo que
        -- le queda a la línea por unidad, y la última, lo que quede.
        v_sub := CASE WHEN v_cant = v_resto_u THEN GREATEST(v_resto_m, 0)
                      ELSE GREATEST(round(v_cant * v_resto_m / v_resto_u, 2), 0) END;
        SELECT d.neto, d.iva INTO v_neto_r, v_iva_r
          FROM public._nc_venta_desglose(v_sub, v_it.precio_unitario, v_it.neto_unitario, v_it.iva_unitario) d;
      END IF;
      v_filas := v_filas || jsonb_build_object(
        'pedido_item_id', v_it.pi_id, 'producto_id', v_it.producto_id, 'cantidad', v_cant,
        'precio_unitario', v_it.precio_unitario, 'subtotal', v_sub);
      v_total := v_total + v_sub;
      v_iva   := v_iva   + v_iva_r;
      v_neto  := v_neto  + v_neto_r;
    END LOOP;
  ELSE
    -- B22: por monto. Lo que vale hoy cada línea de venta: su subtotal (ya neto
    -- de las salvedades) menos los renglones de las notas vigentes sobre ella. Un
    -- regalo (precio 0) o una línea sin producto no reciben nada.
    -- Cada monto es un número de plata, al centavo y mayor que 0 (#1468: un NaN
    -- no pasa la expresión, y _monto_de_cobro lo redondea como a un cobro).
    FOR v_it IN
      SELECT e->>'monto' AS monto_txt
        FROM jsonb_array_elements(p_items) e
    LOOP
      IF v_it.monto_txt IS NULL OR v_it.monto_txt !~ '^[0-9]{1,10}([.][0-9]{1,9})?$' THEN
        RAISE EXCEPTION 'Monto invalido para el descuento: %', COALESCE(v_it.monto_txt, 'vacio')
          USING ERRCODE = '22023';
      ELSIF public._monto_de_cobro(v_it.monto_txt::numeric) <= 0 THEN
        RAISE EXCEPTION 'El monto del descuento tiene que ser mayor a 0 (llegó %)', v_it.monto_txt
          USING ERRCODE = '22023';
      END IF;
    END LOOP;

    IF v_n_con_id = 0 THEN
      -- Estándar: toda la boleta, en proporción a lo que vale hoy cada línea.
      SELECT public._monto_de_cobro((e->>'monto')::numeric) INTO v_monto FROM jsonb_array_elements(p_items) e;
      WITH lineas AS MATERIALIZED (
        SELECT pi.id, pi.subtotal - COALESCE(a.monto, 0) AS resto
          FROM pedido_items pi
          LEFT JOIN LATERAL (
            SELECT SUM(i.subtotal) AS monto
              FROM nota_credito_venta_items i
              JOIN notas_credito_venta n ON n.id = i.nota_credito_id
             WHERE i.pedido_item_id = pi.id AND NOT n.anulada
          ) a ON true
         WHERE pi.pedido_id = p_pedido_id
           AND pi.sucursal_id = v_sucursal
           AND NOT COALESCE(pi.es_bonificacion, false)
           AND pi.producto_id IS NOT NULL
           AND pi.precio_unitario > 0
      )
      SELECT jsonb_object_agg(l.id::text, l.resto), COALESCE(sum(l.resto), 0)
        INTO v_pesos, v_resto_m
        FROM lineas l
       WHERE l.resto > 0;
      IF v_pesos IS NULL THEN
        RAISE EXCEPTION 'No queda nada por acreditar en el pedido #%', p_pedido_id USING ERRCODE = '22023';
      END IF;
      IF v_monto > v_resto_m THEN
        RAISE EXCEPTION 'El descuento (%) pasa lo que le queda a la boleta (%)',
          to_char(v_monto, 'FM999999990.00'), to_char(v_resto_m, 'FM999999990.00') USING ERRCODE = '22023';
      END IF;
      FOR v_it IN
        SELECT pr.item_id, pr.monto AS parte, (v_pesos->>pr.item_id::text)::numeric AS resto,
               pi.producto_id, pi.precio_unitario, pi.neto_unitario, pi.iva_unitario
          FROM public.prorratear_cargo(v_monto, v_pesos) pr
          JOIN pedido_items pi ON pi.id = pr.item_id
         ORDER BY pr.item_id
      LOOP
        IF v_it.parte < 0 OR v_it.parte > v_it.resto THEN
          RAISE EXCEPTION 'No se pudo repartir el descuento: al renglón % le tocan % y le quedan %',
            v_it.item_id, v_it.parte, v_it.resto USING ERRCODE = '22023';
        END IF;
        CONTINUE WHEN v_it.parte = 0;
        SELECT d.neto, d.iva INTO v_neto_r, v_iva_r
          FROM public._nc_venta_desglose(v_it.parte, v_it.precio_unitario, v_it.neto_unitario, v_it.iva_unitario) d;
        v_filas := v_filas || jsonb_build_object(
          'pedido_item_id', v_it.item_id, 'producto_id', v_it.producto_id, 'cantidad', 0,
          'precio_unitario', v_it.precio_unitario, 'subtotal', v_it.parte);
        v_total := v_total + v_it.parte;
        v_iva   := v_iva   + v_iva_r;
        v_neto  := v_neto  + v_neto_r;
      END LOOP;
    ELSE
      -- Avanzado: cada renglón elegido con su monto, hasta lo que le queda.
      FOR v_it IN
        SELECT r.pedido_item_id_txt,
               public._monto_de_cobro(r.monto_txt::numeric) AS parte,
               pi.id AS pi_id, pi.producto_id, pi.precio_unitario, pi.neto_unitario, pi.iva_unitario,
               COALESCE(pi.es_bonificacion, false) AS es_bonif,
               pi.subtotal - COALESCE(a.monto, 0) AS resto
          FROM (
            SELECT e->>'pedido_item_id' AS pedido_item_id_txt, e->>'monto' AS monto_txt, o
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)
          ) r
          LEFT JOIN pedido_items pi
            ON pi.id::text = r.pedido_item_id_txt
           AND pi.pedido_id = p_pedido_id
           AND pi.sucursal_id = v_sucursal
          LEFT JOIN LATERAL (
            SELECT SUM(i.subtotal) AS monto
              FROM nota_credito_venta_items i
              JOIN notas_credito_venta n ON n.id = i.nota_credito_id
             WHERE i.pedido_item_id = pi.id AND NOT n.anulada
          ) a ON true
         ORDER BY r.o
      LOOP
        IF v_it.pi_id IS NULL THEN
          RAISE EXCEPTION 'El item % no pertenece al pedido #%', v_it.pedido_item_id_txt, p_pedido_id
            USING ERRCODE = '22023';
        END IF;
        IF v_it.es_bonif OR COALESCE(v_it.precio_unitario, 0) <= 0 THEN
          RAISE EXCEPTION 'El item % es un regalo de promocion: no se cobro, no se acredita', v_it.pi_id
            USING ERRCODE = '22023';
        END IF;
        IF v_it.producto_id IS NULL THEN
          RAISE EXCEPTION 'El item % es de un producto que ya no existe: el descuento va sobre toda la boleta', v_it.pi_id
            USING ERRCODE = '22023';
        END IF;
        IF v_it.parte > v_it.resto THEN
          RAISE EXCEPTION 'Item %: le quedan % por acreditar; no se le pueden descontar %',
            v_it.pi_id, to_char(GREATEST(v_it.resto, 0), 'FM999999990.00'), to_char(v_it.parte, 'FM999999990.00')
            USING ERRCODE = '22023';
        END IF;
        SELECT d.neto, d.iva INTO v_neto_r, v_iva_r
          FROM public._nc_venta_desglose(v_it.parte, v_it.precio_unitario, v_it.neto_unitario, v_it.iva_unitario) d;
        v_filas := v_filas || jsonb_build_object(
          'pedido_item_id', v_it.pi_id, 'producto_id', v_it.producto_id, 'cantidad', 0,
          'precio_unitario', v_it.precio_unitario, 'subtotal', v_it.parte);
        v_total := v_total + v_it.parte;
        v_iva   := v_iva   + v_iva_r;
        v_neto  := v_neto  + v_neto_r;
      END LOOP;
    END IF;
  END IF;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'El total de la nota de credito tiene que ser mayor a 0' USING ERRCODE = '22023';
  END IF;

  -- B22: tope de toda nota. Con las vigentes, no pasa lo vendido en la boleta (sus
  -- líneas de venta, sin el envío).
  SELECT COALESCE(SUM(subtotal), 0) INTO v_vendido
    FROM pedido_items
   WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal AND NOT COALESCE(es_bonificacion, false);
  SELECT COALESCE(SUM(total), 0) INTO v_vigentes
    FROM notas_credito_venta
   WHERE pedido_id = p_pedido_id AND NOT anulada;
  IF v_total + v_vigentes > v_vendido + 0.005 THEN
    RAISE EXCEPTION 'La boleta #% vendió %, y sus notas de crédito vigentes ya acreditan %: esta nota (%) la pasaría',
      p_pedido_id, to_char(v_vendido, 'FM999999990.00'), to_char(v_vigentes, 'FM999999990.00'),
      to_char(v_total, 'FM999999990.00') USING ERRCODE = '22023';
  END IF;

  -- B22: los productos que la nota mueve, todos y por id, después de la boleta y
  -- antes de las rutas y los créditos: el orden de la venta y de la salvedad.
  IF v_modo = 'unidades' AND v_mercaderia IN ('reingresa', 'merma') THEN
    PERFORM 1 FROM productos
     WHERE sucursal_id = v_sucursal
       AND id IN (SELECT (f->>'producto_id')::bigint FROM jsonb_array_elements(v_filas) f)
     ORDER BY id
       FOR UPDATE;
  END IF;

  -- #1512 (COB-1): el resto del orden global antes de la primera escritura que
  -- llega a una boleta: las rutas de esas boletas por id, y los creditos del
  -- cliente por id.
  -- COB-b1 (#1545): lo que falta de la boleta y el total de la NC se estimaron
  -- arriba sin lock. Un cobro que se espero en el FOR UPDATE de la boleta baja lo
  -- que falta, y lo que sobra de la NC llega mas lejos. Con la boleta tomada se
  -- mide de nuevo y, si sobra mas, se toman ya las boletas que alcanza.
  SELECT GREATEST(total - COALESCE(monto_pagado, 0), 0)
    INTO v_falta
    FROM pedidos
   WHERE id = p_pedido_id;
  IF GREATEST(v_total - v_falta, 0) > v_extra + 0.005 THEN
    v_boletas := public._credito_bloquea_boletas(p_pedido_id, p_cliente_id, v_sucursal,
                                                 GREATEST(v_total - v_falta, 0));
  END IF;

  PERFORM public._credito_bloquea_rutas_y_creditos(COALESCE(v_boletas, ARRAY[p_pedido_id]),
                                                   p_cliente_id, v_sucursal, NULL);

  -- B16 (#1545, decisión del dueño del 16/11): la nota se imputa al día de su
  -- boleta (trg_notas_credito_venta_fecha_de_boleta lo garantiza); cuándo se creó
  -- es created_at. Su crédito (el pago de abajo) es plata de hoy: v_fecha. Qué le
  -- resta al vendedor lo decide trg_notas_credito_venta_foto_vendedor (B16 v3).
  INSERT INTO notas_credito_venta (
    sucursal_id, cliente_id, pedido_id, fecha, motivo, observaciones, total, usuario_id,
    neto, iva
  ) VALUES (
    v_sucursal, p_cliente_id, p_pedido_id, (SELECT pb.fecha FROM pedidos pb WHERE pb.id = p_pedido_id),
    p_motivo, NULLIF(trim(p_observaciones), ''),
    v_total, v_user,
    round(v_neto, 2), round(v_iva, 2)
  ) RETURNING id, fecha, resta_comision INTO v_nc_id, v_fecha_nc, v_resta_com;

  INSERT INTO nota_credito_venta_items (
    nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad, precio_unitario, subtotal
  )
  SELECT v_nc_id, v_sucursal, (f->>'pedido_item_id')::bigint, (f->>'producto_id')::bigint,
         (f->>'cantidad')::integer, (f->>'precio_unitario')::numeric, (f->>'subtotal')::numeric
    FROM jsonb_array_elements(v_filas) WITH ORDINALITY AS t(f, o)
   ORDER BY o;

  -- B22 (decisión del dueño del 17/11): la mercadería según el motivo (reingresa
  -- a su lote / merma / nada). La nota sigue sin tocar el total ni las líneas de
  -- la boleta.
  IF v_modo = 'unidades' AND v_mercaderia IN ('reingresa', 'merma') THEN
    v_movidas := public._nc_venta_mover_mercaderia(v_nc_id, v_user);
  END IF;

  -- El credito: nace como pago sin pedido = saldo a favor (165/235).
  INSERT INTO pagos (
    cliente_id, pedido_id, monto, forma_pago, fecha,
    referencia, notas, usuario_id, sucursal_id, nota_credito_id
  ) VALUES (
    p_cliente_id, NULL, v_total, 'nota_credito', v_fecha,
    'NC-' || v_nc_id,
    'Nota de credito #' || v_nc_id || ' (pedido #' || p_pedido_id || ') [saldo a favor]',
    v_user, v_sucursal, v_nc_id
  ) RETURNING id INTO v_pago_id;

  -- #1512 (COB-1, decision del dueño 10/11): el credito baja primero esta boleta,
  -- si sigue impaga, como lo hace aplicar_credito_cliente con un credito: entero
  -- o en un pedazo que guarda la raiz y su padre (#1248, #1359). El trigger de la
  -- 463c lo marca de_saldo_a_favor. aplicar_credito_cliente no aplica el
  -- credito de una NC a su propia boleta (mig 283): por eso va aca.
  SELECT GREATEST(total - COALESCE(monto_pagado, 0), 0)
    INTO v_falta
    FROM pedidos
   WHERE id = p_pedido_id;
  v_aplicar := round(LEAST(v_total, v_falta), 2);

  IF v_aplicar > 0.005 THEN
    v_guc := current_setting('app.reimputacion_pagos', true);
    PERFORM set_config('app.reimputacion_pagos', 'on', true);

    IF v_aplicar >= v_total - 0.005 THEN
      UPDATE pagos
         SET pedido_id = p_pedido_id,
             -- #1329: un credito es plata que entro.
             a_cuenta = true,
             notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
       WHERE id = v_pago_id;
      v_aplicado := v_total;
    ELSE
      UPDATE pagos SET monto = monto - v_aplicar WHERE id = v_pago_id;

      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
        pago_padre_id
      )
      SELECT cliente_id, p_pedido_id, v_aplicar, forma_pago, fecha, referencia,
             NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
             usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id),
             id
        FROM pagos
       WHERE id = v_pago_id;
      v_aplicado := v_aplicar;
    END IF;

    PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);
  END IF;

  -- Lo que sobra va FIFO a las otras boletas abiertas, de la mas vieja a la mas
  -- nueva.
  -- #1538 (B1, decision del dueño 11/11): solo el credito de esta NC (su pago,
  -- con lo que quedo suelto despues de bajar su boleta), no los otros creditos
  -- sueltos del cliente: lo que se quito de una boleta queda suelto.
  IF v_total - v_aplicado > 0.005 THEN
    v_otras := COALESCE(public._aplicar_credito_pagos(p_cliente_id, v_sucursal, ARRAY[v_pago_id]), 0);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'nota_credito_id', v_nc_id,
    'pago_id', v_pago_id,
    'total', v_total,
    'neto', round(v_neto, 2),
    'iva', round(v_iva, 2),
    'fecha', v_fecha_nc,
    'creada_el', v_fecha,
    'resta_comision', v_resta_com,
    'metas_restadas', (SELECT count(*) FROM nota_credito_venta_metas WHERE nota_credito_id = v_nc_id),
    -- B22: el modo y lo que pasó con la mercadería.
    'modo', v_modo,
    'mercaderia', CASE WHEN v_movidas > 0 THEN v_mercaderia ELSE 'nada' END,
    'unidades_movidas', v_movidas,
    'renglones', jsonb_array_length(v_filas),
    'credito_aplicado_pedido', round(v_aplicado, 2),
    'credito_aplicado_otras', round(v_otras, 2),
    'credito_disponible', round(COALESCE((SELECT sum(monto) FROM pagos
                                           WHERE nota_credito_id = v_nc_id AND pedido_id IS NULL), 0), 2)
  );
END;
$function$;

-- =========================================================================
-- anular_nota_credito_venta: deshace la mercadería
-- =========================================================================
CREATE OR REPLACE FUNCTION public.anular_nota_credito_venta(p_nota_credito_id bigint, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal    bigint := current_sucursal_id();
  v_user        uuid   := auth.uid();
  v_rol         text;
  v_nc          RECORD;
  v_disponible  numeric;
  v_aplicado    numeric;
  v_borrados    integer;
  v_boletas     bigint[];
  v_revertidas  integer := 0; -- B22
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = v_user;
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede anular una nota de credito' USING ERRCODE = '42501';
  END IF;

  -- #1512 (COB-3): anular desimputa lo aplicado. Las boletas que pagaba el
  -- credito se toman antes, por id, y sus rutas por id: borrar sus pagos llega a
  -- cada una por el trigger de monto_pagado y a su ruta por el de la entrega. Es
  -- el orden global (boletas, rutas, pagos). Se lee sin lock; si en el medio el
  -- credito llega a otra boleta, el DELETE la toma al final.
  v_boletas := ARRAY(SELECT DISTINCT pg.pedido_id
                       FROM pagos pg
                      WHERE pg.nota_credito_id = p_nota_credito_id
                        AND pg.sucursal_id = v_sucursal
                        AND pg.pedido_id IS NOT NULL
                      ORDER BY 1);
  -- B16 (H1 de la revisión): y la boleta de la nota.
  PERFORM 1
     FROM pedidos
    WHERE (id = ANY(v_boletas)
           OR id = (SELECT n.pedido_id FROM notas_credito_venta n
                     WHERE n.id = p_nota_credito_id AND n.sucursal_id = v_sucursal))
      AND sucursal_id = v_sucursal
    ORDER BY id
      FOR UPDATE;
  -- B22 (#1603): los productos de la mercadería que la nota movió, por id,
  -- después de las boletas y antes de las rutas: el orden de crearla.
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT i.producto_id
                   FROM nota_credito_venta_items i
                   JOIN notas_credito_venta n ON n.id = i.nota_credito_id
                  WHERE i.nota_credito_id = p_nota_credito_id
                    AND n.sucursal_id = v_sucursal
                    AND (i.lotes_devueltos IS NOT NULL OR i.merma_id IS NOT NULL))
    ORDER BY id
      FOR UPDATE;
  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(v_boletas))
    ORDER BY id
      FOR NO KEY UPDATE;

  SELECT id, total, anulada, cliente_id
    INTO v_nc
    FROM notas_credito_venta
   WHERE id = p_nota_credito_id AND sucursal_id = v_sucursal
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de credito no encontrada' USING ERRCODE = 'P0002';
  END IF;
  IF v_nc.anulada THEN
    RAISE EXCEPTION 'La nota de credito #% ya esta anulada', p_nota_credito_id USING ERRCODE = '22023';
  END IF;

  -- Lock de los pedazos: aplicar_credito_cliente los actualiza, asi que una
  -- imputacion concurrente espera o nos hace esperar.
  -- #1424: por id, como la foto de la rendicion.
  PERFORM 1 FROM pagos WHERE nota_credito_id = p_nota_credito_id ORDER BY id FOR UPDATE;

  SELECT COALESCE(SUM(monto) FILTER (WHERE pedido_id IS NULL), 0),
         COALESCE(SUM(monto) FILTER (WHERE pedido_id IS NOT NULL), 0)
    INTO v_disponible, v_aplicado
    FROM pagos
   WHERE nota_credito_id = p_nota_credito_id;

  -- El credito de la NC, suelto o aplicado, suma su total: desafectar y los
  -- pedazos lo mueven, nunca lo crean ni lo borran.
  IF abs(v_disponible + v_aplicado - v_nc.total) > 0.005 THEN
    RAISE EXCEPTION 'No se puede anular: el credito de la nota (%) no coincide con su total (%). Revisar a mano.',
      to_char(v_disponible + v_aplicado, 'FM999999990.00'), to_char(v_nc.total, 'FM999999990.00')
      USING ERRCODE = '22023';
  END IF;

  -- B22 (decisión del dueño del 17/11: «Si anulamos una nota de crédito, sí
  -- vuelve a volverse el stock»): lo que reingresó sale del lote al que volvió y
  -- la merma se anula. Si lo que reingresó ya no está, se rechaza con el motivo.
  v_revertidas := public._nc_venta_deshacer_mercaderia(p_nota_credito_id, v_user);

  -- Se borra todo el credito: lo suelto y lo aplicado. Las boletas que pagaba
  -- vuelven a deber eso (el trigger de monto_pagado), y el saldo del cliente
  -- sube el total de la NC.
  PERFORM set_config('app.anulando_nota_credito', 'on', true);
  DELETE FROM pagos WHERE nota_credito_id = p_nota_credito_id;
  GET DIAGNOSTICS v_borrados = ROW_COUNT;
  PERFORM set_config('app.anulando_nota_credito', 'off', true);

  UPDATE notas_credito_venta
     SET anulada = true,
         anulada_por = v_user,
         anulada_at = now(),
         motivo_anulacion = NULLIF(trim(p_motivo), '')
   WHERE id = p_nota_credito_id;

  RETURN jsonb_build_object(
    'success', true,
    'nota_credito_id', p_nota_credito_id,
    'credito_revertido', round(v_disponible + v_aplicado, 2),
    'credito_desimputado', round(v_aplicado, 2),
    'pedidos_desimputados', to_jsonb(v_boletas),
    'pagos_borrados', v_borrados,
    'unidades_revertidas', v_revertidas
  );
END;
$function$;

-- =========================================================================
-- Poscondiciones
-- =========================================================================
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', '_nc_venta_mover_mercaderia(v_nc_id, v_user)', true),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'prorratear_cargo(v_monto, v_pesos)', true),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'es_motivo_nc_venta', true),
    ('public.anular_nota_credito_venta(bigint,text)', '_nc_venta_deshacer_mercaderia(p_nota_credito_id, v_user)', true),
    ('public.anular_nota_credito_venta(bigint,text)', 'OR id = (SELECT n.pedido_id FROM notas_credito_venta n', true),
    ('public.sincronizar_lotes_stock()', '''movimiento_editado'', ''nota_credito_venta'') THEN', true),
    ('public._ventas_nc(bigint[],date,date)', 'i.subtotal = i.cantidad * pi.precio_unitario', false),
    ('public._nc_venta_mover_mercaderia(bigint,uuid)', '''nota_credito_venta_merma''', true),
    ('public._nc_venta_deshacer_mercaderia(bigint,uuid)', '''nota_credito_venta_anulada''', true)
  ) AS t(f, marca, definer) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND position(r.marca in prosrc) > 0 AND prosecdef = r.definer) THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró', r.f;
    END IF;
  END LOOP;
  -- Las de server: sin EXECUTE para nadie de la API. La RPC y la anulación, sí.
  FOR r IN SELECT unnest(ARRAY['public._nc_venta_desglose(numeric,numeric,numeric,numeric)',
                               'public._nc_venta_mover_mercaderia(bigint,uuid)',
                               'public._nc_venta_deshacer_mercaderia(bigint,uuid)',
                               'public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)',
                               'public._ventas_nc(bigint[],date,date)']) AS f LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE') OR has_function_privilege('authenticated', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para la API', r.f;
    END IF;
  END LOOP;
  IF NOT has_function_privilege('authenticated', 'public.crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.anular_nota_credito_venta(bigint,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.anular_nota_credito_venta(bigint,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig NNN · los permisos de las RPC de la nota cambiaron';
  END IF;
  IF has_table_privilege('authenticated', 'public.nota_credito_venta_items', 'INSERT')
     OR has_table_privilege('authenticated', 'public.nota_credito_venta_items', 'UPDATE')
     OR has_table_privilege('anon', 'public.nota_credito_venta_items', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · nota_credito_venta_items quedó con escritura REST o lectura anónima';
  END IF;
  IF (SELECT count(*) FROM pg_constraint
       WHERE conrelid = 'public.nota_credito_venta_items'::regclass
         AND conname IN ('nota_credito_venta_items_cantidad_check', 'nota_credito_venta_items_cantidad_o_monto',
                         'nota_credito_venta_items_merma_fkey')) <> 3 THEN
    RAISE EXCEPTION 'mig NNN · faltan los CHECK o la FK de nota_credito_venta_items';
  END IF;
END
$post$;

COMMIT;
