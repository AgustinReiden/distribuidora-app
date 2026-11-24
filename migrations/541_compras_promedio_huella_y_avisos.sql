-- =========================================================================
-- NNN · COMPRAS: LA FOTO DEL 2.º RENGLÓN, LA HUELLA DE LO VENDIDO AL ANULAR,
--       EL DESCUADRE DE LA EDICIÓN, EL II DE VARIAS NOTAS Y LA COMPRA SIN
--       RENGLONES
--       (plan #1603, tanda 6, tarjeta A: CMP-1, compras-CMP-b1, compras-CMP-b4,
--        gestion-B5 y stock-STK-1 de la reauditoría del 24/11)
--
-- Parcha por ancla, con premisa de md5 sobre los cuerpos vivos de la 540, cinco
-- funciones: `_cpp_arrastrar`, `actualizar_compra_items`, `ii_nota_credito_compra`,
-- `registrar_compra_completa` y `anular_compra_atomica`. No crea funciones, no
-- cambia firmas ni permisos y no toca tablas (sin locks de tabla: un CREATE OR
-- REPLACE FUNCTION no los toma). Las cinco conservan su `search_path = public,
-- pg_temp`. Ensayo: scripts/test-compras-tanda6-1603.sql. Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- 1 · CMP-1 (medio): anular una NC deja mal la foto del 2.º renglón de un
--     producto en su compra, y la corrección siguiente deja mal el promedio
-- -------------------------------------------------------------------------
-- Producto con 20 u. a 6. A: 100 u. a 10. B: 100 u. a 20 más 20 u. de regalo
-- (13,0000). NC de 30 sobre B, NC de 40 sobre A (su arrastre pasa por B con la NC
-- vigente), anular la NC de B, anular la de A: la historia vuelve a ser la del
-- principio y el promedio tenía que volver a 13,0000; daba 12,9869. Con dos
-- renglones pagados (40 a 12 y 60 a 18), 12,1684 en vez de 12,1818.
-- Por qué: mientras B tiene una NC vigente, el arrastre le escribe al 2.º renglón
-- la foto del promedio de la historia «con la NC» (y no la usa: `dev_antes > 0`).
-- La anulación de la NC (`_cpp_devolucion_compra`) arrastra sólo las compras de
-- después de B, así que esa foto no se rehace nunca, y con la NC anulada el
-- arrastre siguiente la tomaba como buena.
-- Ahora `_cpp_arrastrar` no usa nunca la foto de un renglón que no es el primero
-- del producto en su compra: entre un renglón y el siguiente de la misma factura
-- no hay ventas ni otra compra, así que la cadena da exacto lo que esa foto tenía
-- que decir. La base de una compra ya era la foto de su primer renglón
-- (`_cpp_foto_compra`, la edición y la anulación), y nadie más lee las otras: una
-- que haya quedado mal en producción deja de pesar sin tocarla.
--
-- -------------------------------------------------------------------------
-- 2 · compras-CMP-b1: la edición de una compra avisa el descuadre, como el alta
-- -------------------------------------------------------------------------
-- `actualizar_compra_items` guardaba el total de una FC tal como llegaba, sin
-- compararlo con lo que suma su cabecera y sin aviso (2.472,25 guardado con
-- componentes que suman 2.772,25). Ahora, como `registrar_compra_completa`,
-- devuelve `warning_descuadre` («Descuadre: total calculado … vs total informado
-- …», tolerancia 1) cuando el total que llegó no es subtotal + IVA + II +
-- percepciones + no gravado + bonificaciones + otros impuestos de la cabecera que
-- quedó guardada (en una ZZ, el total que pone el server). Es un aviso blando: la
-- edición se guarda igual, como el alta. Un front de antes no lo lee y no cambia
-- nada para él.
--
-- -------------------------------------------------------------------------
-- 3 · compras-CMP-b4: varias NC parciales no acreditan más II que la compra
-- -------------------------------------------------------------------------
-- `ii_nota_credito_compra` redondea cada nota por su cuenta: una FC A con II de
-- 200 sobre 3 unidades y tres notas de 1 acreditaban 66,67 × 3 = 200,01. Ahora el
-- II de una devolución tiene tope en lo que le queda a la compra (su II menos el de
-- sus devoluciones vigentes): la tercera acredita 66,66 y la suma da 200. Una nota
-- anulada no cuenta. Un ajuste (el II lo declara quien lo carga) no cambia.
--
-- -------------------------------------------------------------------------
-- 4 · gestion-B5: una compra sin renglones se rechaza con su motivo
-- -------------------------------------------------------------------------
-- `registrar_compra_completa` aceptaba `p_items = '[]'` (o NULL) con total 0 y
-- dejaba una compra sin líneas; la edición (`actualizar_compra_items`) dejaba igual
-- una compra sin líneas si se la mandaba vacía. El front ya lo frenaba («Debe
-- agregar al menos un producto»): lo ve una llamada directa o un bundle viejo.
-- Ahora las dos rechazan, antes de tocar nada, con el motivo.
--
-- -------------------------------------------------------------------------
-- 5 · stock-STK-1: anular una compra de cuyo lote ya se vendió conserva la
--     huella de esa venta
-- -------------------------------------------------------------------------
-- Lote manual Lm (100 con 40) y bolsa 20. Una ZZ de 100 con su lote Lc (vence
-- antes) y una venta de 50 (20 de la bolsa y 30 de Lc, huella Lc:30). Anular la
-- compra borra Lc (`borrar_lotes_compra_cancelada`, la regla de la 229 sigue
-- igual) y la bajada de 100 come la bolsa y saca 30 de Lm por FEFO: la anulación
-- es «como si la compra nunca hubiera entrado» y le carga la venta a Lm. Pero el
-- CASCADE borraba la huella y cancelar la venta devolvía las 50 a la bolsa: Lm 10 y
-- bolsa 50 en vez de Lm 40 y bolsa 20 (Vencimientos mostraba 30 u. de menos). Ahora
-- `anular_compra_atomica` guarda, antes de cancelar, la huella que apunta a los
-- lotes de la compra y lo que le queda a cada lote de esos productos, y después de
-- la bajada le pasa esa huella a los lotes que la bajada consumió, en el orden en
-- que los consumió (FEFO) y hasta lo que sacó de cada uno: lo que la bajada tomó de
-- la bolsa no tenía lote y no lleva huella. Es lo que `sincronizar_lotes_compra` ya
-- hace con un lote que desaparece (reapuntar la traza, no perderla).
--
-- Revertir: volver las cinco funciones a los cuerpos de la premisa.
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
-- Premisas: los cuerpos vivos (ledger en la 540)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', '3cbb27fa967fad761c660aab300b3c2d'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)', 'cf4981e42cc21df3fa0f3dffcce30bf5'),
    ('public.ii_nota_credito_compra(bigint,bigint,jsonb)', '2d7e3fa9a5a9d5a42ab28d2cf179d564'),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)', '3da2558169424e6bf821fa1f2169436d'),
    ('public.anular_compra_atomica(bigint,uuid)', 'a0126c7c813395b6230f71b8560fba46'),
    -- lo que el arreglo usa tal como está: la base de una compra es su primer renglón
    ('public._cpp_foto_compra(bigint,bigint)', '22d40a9976dd131456ac38140a223daf')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  -- `_cpp_foto_compra` toma la foto del primer renglón de cada producto: es lo que
  -- deja sin lectores a las fotos de los demás (tramo 1).
  IF position('(array_agg(ci.costo_promedio_anterior ORDER BY ci.id))[1]' IN
              (SELECT prosrc FROM pg_proc WHERE oid = 'public._cpp_foto_compra(bigint,bigint)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'mig NNN · _cpp_foto_compra ya no toma la foto del primer renglón: revisar el tramo 1';
  END IF;
END
$premisas$;

-- Los tramos que se cambian: la función, el ancla y su reemplazo. La
-- poscondición los vuelve a poner al revés y compara con el md5 de la premisa.
CREATE TEMP TABLE t6a_tramos (ord int PRIMARY KEY, fn text, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO t6a_tramos VALUES
-- 1 · CMP-1
(1, 'public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', 'renglones anteriores',
$a$             CASE WHEN t.total > 0
                  THEN t.antes * LEAST(n.dev, t.total) / t.total
                  ELSE 0::numeric END AS dev_antes
        FROM compra_items ci
$a$,
$r$             CASE WHEN t.total > 0
                  THEN t.antes * LEAST(n.dev, t.total) / t.total
                  ELSE 0::numeric END AS dev_antes,
             t.antes AS antes_mismo  -- mig NNN (CMP-1): los renglones anteriores del producto en esa compra
        FROM compra_items ci
$r$),
(2, 'public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', 'el envío no tiene renglones anteriores',
$a$             mi.cantidad::numeric, 0::numeric
        FROM movimiento_sucursal_items mi
$a$,
$r$             mi.cantidad::numeric, 0::numeric, 0::numeric
        FROM movimiento_sucursal_items mi
$r$),
(3, 'public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', 'la foto del renglón',
$a$    v_antes_viejo := COALESCE(CASE WHEN r.dev_antes > 0 THEN NULL ELSE r.costo_promedio_anterior END, cpp_viejo);
$a$,
$r$    /* mig NNN (CMP-1, tanda 6 de #1603) · LA FOTO DE UN RENGLÓN QUE NO ES EL PRIMERO
       DEL PRODUCTO EN SU COMPRA NO SE USA: SE DERIVA DE LA CADENA. Con una NC vigente
       en esa compra, el arrastre le escribía la foto de la historia con la NC; anular
       la NC no la rehacía (`_cpp_devolucion_compra` arrastra sólo lo de después) y la
       corrección siguiente la tomaba como buena: un promedio de 13,0000 volvía como
       12,9869. Entre un renglón y el siguiente de la misma factura no hay ventas, así
       que la cadena da exacto lo que esa foto tenía que decir (con la NC, lo que le
       queda a cada renglón, como antes). La base de una compra es su primer renglón
       (`_cpp_foto_compra`): las fotos de los demás quedan informativas. */
    v_antes_viejo := COALESCE(CASE WHEN r.antes_mismo > 0 THEN NULL ELSE r.costo_promedio_anterior END, cpp_viejo);
$r$),
-- 2 y 4 · compras-CMP-b1 y gestion-B5 en la edición
(4, 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)', 'declaraciones',
$a$  v_iva_cargos       JSONB := '{}'::JSONB;  -- mig NNN (1593-b1): {indice: IVA de sus cargos}
$a$,
$r$  v_iva_cargos       JSONB := '{}'::JSONB;  -- mig NNN (1593-b1): {indice: IVA de sus cargos}
  v_warning_desc     TEXT;      -- mig NNN (CMP-b1, tanda 6 de #1603): el descuadre, como el alta
$r$),
(5, 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)', 'sin renglones',
$a$  /* #1077 · La cabecera es la suma de los renglones nuevos (la edicion reemplaza
$a$,
$r$  /* mig NNN (gestion-B5, tanda 6 de #1603) · UNA COMPRA SIN RENGLONES NO SE GUARDA.
     Mandada vacia (o sin renglones), la edicion borraba todas las lineas y dejaba
     la compra recibida con total 0. Para darla de baja entera esta la anulacion. */
  IF (CASE WHEN jsonb_typeof(p_items_nuevos) = 'array' THEN jsonb_array_length(p_items_nuevos) = 0
           ELSE true END) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'La compra tiene que quedar con al menos un renglón (un producto con su cantidad). Para darla de baja entera, anulala.');
  END IF;

  /* #1077 · La cabecera es la suma de los renglones nuevos (la edicion reemplaza
$r$),
(6, 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)', 'el descuadre',
$a$         total = CASE WHEN v_es_zz THEN v_total_zz ELSE p_total END,  /* mig NNN (R3) */
         updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;
$a$,
$r$         total = CASE WHEN v_es_zz THEN v_total_zz ELSE p_total END,  /* mig NNN (R3) */
         updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  /* mig NNN (CMP-b1, tanda 6 de #1603) · EL CONTROL BLANDO DE CUADRE DEL ALTA. El total
     de una FC se guarda como llega; se compara con lo que suma la cabecera que quedo
     guardada (subtotal, IVA, II, percepciones, no gravado, bonificaciones y otros
     impuestos) y, en una ZZ, con el total que pone el server. La misma cuenta y la
     misma tolerancia que registrar_compra_completa. No frena nada: avisa. */
  SELECT CASE WHEN abs(x.calc - COALESCE(p_total, 0)) > 1
              THEN format('Descuadre: total calculado %s vs total informado %s',
                          round(x.calc, 2), round(COALESCE(p_total, 0), 2)) END
    INTO v_warning_desc
    FROM (SELECT CASE WHEN v_es_zz THEN c.total
                      ELSE COALESCE(c.subtotal, 0) + COALESCE(c.iva, 0) + COALESCE(c.impuestos_internos, 0)
                           + COALESCE(c.percepcion_iva, 0) + COALESCE(c.percepcion_iibb, 0)
                           + COALESCE(c.no_gravado, 0) + COALESCE(c.bonificaciones, 0)
                           + COALESCE(c.otros_impuestos, 0) END AS calc
            FROM compras c
           WHERE c.id = p_compra_id AND c.sucursal_id = v_sucursal) x;
$r$),
(7, 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)', 'el aviso en la respuesta',
$a$    'warning_ii_declarado', v_warning_ii /* mig 194 */
  ) || CASE WHEN p_lotes IS NULL THEN '{}'::JSONB  /* mig NNN (STK-13) */
$a$,
$r$    'warning_ii_declarado', v_warning_ii /* mig 194 */,
    'warning_descuadre', v_warning_desc  /* mig NNN (CMP-b1) */
  ) || CASE WHEN p_lotes IS NULL THEN '{}'::JSONB  /* mig NNN (STK-13) */
$r$),
-- 3 · compras-CMP-b4
(8, 'public.ii_nota_credito_compra(bigint,bigint,jsonb)', 'lo ya acreditado',
$a$  tot AS (SELECT SUM(ii_teorico) AS ii_teorico, SUM(neto) AS neto FROM lin),
$a$,
$r$  tot AS (SELECT SUM(ii_teorico) AS ii_teorico, SUM(neto) AS neto FROM lin),
  -- mig NNN (CMP-b4, tanda 6 de #1603): el II que ya acreditaron sus devoluciones vigentes
  ya AS (
    SELECT COALESCE(SUM(nc.impuestos_internos), 0) AS ii
      FROM notas_credito nc
     WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = p_sucursal_id
       AND nc.tipo = 'devolucion' AND NOT nc.anulada
  ),
$r$),
(9, 'public.ii_nota_credito_compra(bigint,bigint,jsonb)', 'el tope',
$a$  SELECT COALESCE(round(
           CASE WHEN cab.ii <= 0 THEN 0
                WHEN tot.ii_teorico > 0 THEN cab.ii * COALESCE(prop.ii_teorico, 0) / tot.ii_teorico
                WHEN tot.neto > 0       THEN cab.ii * COALESCE(prop.neto, 0) / tot.neto
                ELSE 0 END, 2), 0)
    FROM cab, tot, prop;
$a$,
$r$  -- mig NNN (CMP-b4): cada nota redondea por su cuenta (II 200 sobre 3 u. y tres notas
  -- de 1 daban 66,67 × 3 = 200,01): la devolucion no pasa lo que le queda del II.
  SELECT GREATEST(LEAST(COALESCE(round(
           CASE WHEN cab.ii <= 0 THEN 0
                WHEN tot.ii_teorico > 0 THEN cab.ii * COALESCE(prop.ii_teorico, 0) / tot.ii_teorico
                WHEN tot.neto > 0       THEN cab.ii * COALESCE(prop.neto, 0) / tot.neto
                ELSE 0 END, 2), 0),
           cab.ii - ya.ii), 0)
    FROM cab, tot, prop, ya;
$r$),
-- 4 · gestion-B5 en el alta
(10, 'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)', 'sin renglones',
$a$  v_tipo_factura   := COALESCE(p_tipo_factura, 'FC');
$a$,
$r$  /* mig NNN (gestion-B5, tanda 6 de #1603) · UNA COMPRA SIN RENGLONES NO SE REGISTRA.
     Con p_items vacio (o NULL) quedaba una compra sin lineas y con total 0. El front
     ya lo frenaba; esto lo cierra para una llamada directa o un bundle viejo. */
  IF (CASE WHEN jsonb_typeof(p_items) = 'array' THEN jsonb_array_length(p_items) = 0 ELSE true END) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'La compra no tiene renglones: agregá al menos un producto con su cantidad.');
  END IF;

  v_tipo_factura   := COALESCE(p_tipo_factura, 'FC');
$r$),
-- 5 · stock-STK-1
(11, 'public.anular_compra_atomica(bigint,uuid)', 'declaraciones',
$a$  v_cadena     RECORD;   -- mig 407
$a$,
$r$  v_cadena     RECORD;   -- mig 407
  v_huella     JSONB;    -- mig NNN (STK-1): la huella que apunta a los lotes de la compra
  v_lotes_antes JSONB;   -- mig NNN (STK-1): lo que le quedaba a cada otro lote de esos productos
$r$),
(12, 'public.anular_compra_atomica(bigint,uuid)', 'la huella, antes de cancelar',
$a$  -- mig 229: cancelar PRIMERO.$a$,
$r$  /* mig NNN (STK-1, tanda 6 de #1603) · LO VENDIDO DE SUS LOTES CONSERVA SU HUELLA.
     Cancelar borra los lotes de la compra (borrar_lotes_compra_cancelada) y el
     CASCADE se llevaba la huella de las ventas que habian salido de ellos; la bajada
     de abajo le carga esas unidades a otros lotes por FEFO («como si la compra nunca
     hubiera entrado»), pero sin huella cancelar la venta las devolvia a la bolsa: Lm
     quedaba 10 y la bolsa 50 en vez de 40 y 20. Antes de cancelar se guarda esa huella
     y lo que le queda a cada otro lote de esos productos (los productos ya estan
     tomados: nadie mueve sus lotes en el medio); despues de la bajada, la huella pasa
     a los lotes que la bajada consumio. */
  SELECT jsonb_agg(jsonb_build_object('item', h.item, 'producto_id', h.producto_id, 'cantidad', h.cantidad)
                   ORDER BY h.producto_id, h.item)
    INTO v_huella
    FROM (SELECT pil.pedido_item_id AS item, l.producto_id, SUM(pil.cantidad)::INT AS cantidad
            FROM pedido_item_lotes pil
            JOIN producto_lotes l ON l.id = pil.lote_id AND l.sucursal_id = pil.sucursal_id
           WHERE l.compra_id = p_compra_id AND l.sucursal_id = v_sucursal
           GROUP BY pil.pedido_item_id, l.producto_id) h;
  IF v_huella IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object('lote_id', l.id, 'restante', l.cantidad_restante) ORDER BY l.id)
      INTO v_lotes_antes
      FROM producto_lotes l
     WHERE l.sucursal_id = v_sucursal
       AND l.compra_id IS DISTINCT FROM p_compra_id
       AND l.producto_id IN (SELECT (e->>'producto_id')::BIGINT FROM jsonb_array_elements(v_huella) e);
  END IF;

  -- mig 229: cancelar PRIMERO.$r$),
(13, 'public.anular_compra_atomica(bigint,uuid)', 'la huella, después de la bajada',
$a$  /* mig 407 (#1252) · ANULAR DEVUELVE EL PROMEDIO (decision del dueño,
$a$,
$r$  /* mig NNN (STK-1) · la huella guardada pasa a los lotes que la bajada consumio, en el
     orden en que los consumio (vencimiento, id: el de _consumir_lotes_fefo) y hasta lo
     que saco de cada uno; las lineas en orden de id. Lo que la bajada tomo de la bolsa
     no tenia lote: esa parte de la huella no pasa a ningun lado, como una venta de la
     bolsa. Nunca pasa lo que tenia cada linea (LOTE-D). */
  IF v_lotes_antes IS NOT NULL THEN
    INSERT INTO pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
    SELECT h.item, t.lote_id,
           LEAST(h.hasta, t.hasta) - GREATEST(h.hasta - h.cantidad, t.hasta - t.tomado),
           v_sucursal
      FROM (SELECT x.item, x.producto_id, x.cantidad,
                   SUM(x.cantidad) OVER (PARTITION BY x.producto_id ORDER BY x.item) AS hasta
              FROM jsonb_to_recordset(v_huella) AS x(item BIGINT, producto_id BIGINT, cantidad INT)) h
      JOIN (SELECT l.id AS lote_id, l.producto_id, a.restante - l.cantidad_restante AS tomado,
                   SUM(a.restante - l.cantidad_restante)
                     OVER (PARTITION BY l.producto_id ORDER BY l.fecha_vencimiento, l.id) AS hasta
              FROM jsonb_to_recordset(v_lotes_antes) AS a(lote_id BIGINT, restante INT)
              JOIN producto_lotes l ON l.id = a.lote_id AND l.sucursal_id = v_sucursal
             WHERE a.restante > l.cantidad_restante) t
        ON t.producto_id = h.producto_id
     WHERE LEAST(h.hasta, t.hasta) > GREATEST(h.hasta - h.cantidad, t.hasta - t.tomado)
    ON CONFLICT (pedido_item_id, lote_id)
      DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
  END IF;

  /* mig 407 (#1252) · ANULAR DEVUELVE EL PROMEDIO (decision del dueño,
$r$);

-- =========================================================================
-- El parche: cada función con sus tramos. Las cinco ya tienen
-- `search_path = public, pg_temp` (531): pg_get_functiondef lo trae y se conserva.
-- =========================================================================
DO $parche$
DECLARE
  f     text;
  v_def text;
  r     record;
  v_n   int;
BEGIN
  FOR f IN SELECT DISTINCT fn FROM t6a_tramos ORDER BY 1 LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    IF position(E' SET search_path TO ''public'', ''pg_temp''\n' IN v_def) = 0 THEN
      RAISE EXCEPTION 'mig NNN · %: no encuentro su search_path con pg_temp', f;
    END IF;
    FOR r IN SELECT * FROM t6a_tramos WHERE fn = f ORDER BY ord LOOP
      v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el ancla aparece % vez/veces y se esperaba 1', f, r.que, v_n;
      END IF;
      v_def := replace(v_def, r.ancla, r.nuevo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos nuevos son los del repo, el resto de cada cuerpo no
-- cambió (deshaciendo sus tramos vuelve el md5 de la premisa), y el definer (o
-- no), el search_path y los EXECUTE son los de antes.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text;
  r     record;
  t     record;
  x     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)',
     'dbd2ac22d040624d73ef510a5de2ecd5', '3cbb27fa967fad761c660aab300b3c2d',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[],jsonb)',
     'f817624eacbd81d4731cbcb6b6ac6652', 'cf4981e42cc21df3fa0f3dffcce30bf5',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.ii_nota_credito_compra(bigint,bigint,jsonb)',
     '602e2c208fa9bd6e2c7f47c2c28a4ec6', '2d7e3fa9a5a9d5a42ab28d2cf179d564',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     'd99e17c3fcde2bfafe139b01ce948e38', '3da2558169424e6bf821fa1f2169436d',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.anular_compra_atomica(bigint,uuid)',
     '4832c6ace4c9596adad5b3c3ad2f9983', 'a0126c7c813395b6230f71b8560fba46',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true)
  ) AS v(fn, h, h_antes, acl, def) LOOP
    SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
    v_src := x.prosrc;
    FOR t IN SELECT * FROM t6a_tramos WHERE fn = r.fn ORDER BY ord DESC LOOP
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
