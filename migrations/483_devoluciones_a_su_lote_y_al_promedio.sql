-- =========================================================================
-- 483 · LO QUE VUELVE DE UN ENVÍO VUELVE DE DONDE SALIÓ; LA NC Y LOS ENVÍOS
--       CORRIGEN EL PROMEDIO; LA MERMA POR VENCIMIENTO SALE DEL LOTE VENCIDO
--       (tarjeta 5 de #1524: STK-1, STK-4, STK-5 y STK-10 de #1516)
--
-- Reemplaza el cuerpo entero de siete funciones, con premisa de md5 sobre el
-- cuerpo vivo leído el 10/11 y poscondición de md5, y crea tres helpers de
-- server. Ensayo: scripts/test-envios-promedio-merma-1516.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · STK-1 · CANCELAR, DENEGAR O ACHICAR UN ENVÍO
-- =========================================================================
-- `cancelar_movimiento_sucursal`, `denegar_movimiento_sucursal` y la rama que
-- achica de `editar_movimiento_sucursal` devolvían el stock con
-- 'movimiento_cancelado', 'movimiento_denegado' y 'movimiento_editado', que
-- están en la lista blanca de `sincronizar_lotes_stock`: el trigger repartía la
-- devolución por FEFO entre los huecos de los lotes, aunque el registro del
-- envío (`movimiento_sucursal_item_lotes`, mig 286) dice qué salió de cada lote
-- y qué de la bolsa. Ejemplo de #1516: un lote L de 60 con 40, más 60 en la
-- bolsa; se envían 30, que salen de la bolsa; al cancelar, L quedaba 60/60 y la
-- bolsa en 40. Es el +N/−N que #1085 y #1114 cerraron en los pedidos.
--
-- Ahora la subida va con una etiqueta que NO está en la lista blanca
-- ('movimiento_cancelado_a_su_lote', 'movimiento_denegado_a_su_lote',
-- 'movimiento_editado_a_su_lote'): entra a la bolsa. Después
-- `_mov_lotes_devolver` le devuelve a cada lote lo que el registro dice que le
-- sacó (nunca más que su hueco; un lote que ya no existe o que quedó sólo para
-- la traza no recibe nada). Lo demás salió de la bolsa y se queda en la bolsa.
-- Al achicar, lo que deja de viajar sigue la regla de la 286 sin su paso (1),
-- porque ningún lote recibió nada por FEFO: primero lo que vino de la bolsa, y
-- después el registro, el vencimiento más lejano primero; lo que el registro
-- pierde de cada lote vuelve a ese lote. La 286 había descartado esto porque
-- había envíos viejos sin registro; hoy no queda ninguno pendiente (los 14
-- envíos de prod están aceptados o denegados).
--
-- No se tocan `_restaurar_lotes_fefo` ni `sincronizar_lotes_stock`, que usan la
-- cancelación de pedidos y la salvedad. Las tres etiquetas viejas quedan en la
-- lista blanca del trigger sin que nadie las use. La bajada de la edición (sale
-- más) sigue igual. Orden de locks: los productos del envío, juntos y por id,
-- antes del primer lote (#1255); en la edición ya estaban tomados.
--
-- =========================================================================
-- 2 · STK-4 · LA NC DE DEVOLUCIÓN CORRIGE EL PROMEDIO
-- =========================================================================
-- Decisión del dueño (10/11): la NC de devolución al proveedor corrige el
-- costo promedio como una anulación parcial de la compra, por diferencia, desde
-- la foto del alta y con el arrastre de la 407. Ejemplo de #1516: 100 u. a 10 y
-- entra una compra de 100 a 20, el promedio queda en 15; se devuelven las 100 y
-- vuelve a 10. Hasta acá quedaba en 15.
--
-- `_cpp_devolucion_compra` es la anulación de la 407 con una parte de la
-- compra: recorre las líneas del producto desde la foto del alta dos veces, con
-- lo que quedaba antes de esta nota y con lo que queda después, y arrastra la
-- diferencia por lo que entró después con el stock corrido por lo devuelto.
-- La nota acredita cada producto al costo neto PROMEDIO de sus renglones
-- (#1471: la base no sabe de qué renglón sale cada unidad), así que lo devuelto
-- sale de cada renglón en proporción (`_cpp_recorrer_compra_parcial`), y con un
-- renglón (el caso normal) es exacto. Lo que ya devolvieron las notas
-- anteriores de la misma compra es el punto de partida. Sin foto (compra
-- anterior a la 236) no corrige y avisa, como la anulación. La reposición
-- (costo_real) no se toca: lo devuelto no cambia el precio de la factura.
-- Las notas anteriores a esta migración no corrigieron y no se corrigen ahora
-- (en prod hay una sola NC de devolución).
--
-- =========================================================================
-- 3 · STK-5 · EL ARRASTRE VE LOS INGRESOS POR ENVÍO
-- =========================================================================
-- Aceptar un envío mezcla el promedio del destino con el del origen (286), con
-- la misma cuenta que `_cpp_linea` con costo fijo. `_cpp_arrastrar` sólo
-- recorría compras: editar o anular una compra corregía mal el promedio de un
-- producto que después recibió un envío, y anular la primera compra lo dejaba
-- en NULL aunque el envío trajera costo. Ahora recorre también los envíos
-- aceptados en ese producto, por la hora de aceptación, con su stock de antes y
-- el costo del origen, y les pasa la foto del stock a la historia corregida,
-- como a las compras (#1294). Un ingreso sin costo (los 26 anteriores a la 286,
-- cuando aceptar no tocaba el promedio) no lo movió y no entra. Lo usan la
-- edición y la anulación de compras, el cambio de proveedor y ahora la NC.
--
-- Los dos productos que no cerraban (173 y 198 de la sucursal 2) quedan
-- explicados por esto: su promedio vivo es el correcto y la cadena de compras
-- sola no lo da porque después de la última compra entró un envío (el #57 y el
-- #18). No se toca ningún dato.
--
-- =========================================================================
-- 4 · STK-10 · LA MERMA POR VENCIMIENTO SALE DEL LOTE VENCIDO
-- =========================================================================
-- `registrar_merma_manual` bajaba el stock y el trigger comía la bolsa
-- primero: el lote vencido seguía contando las unidades que se tiraron. Con
-- motivo 'vencimiento' ahora sale primero de los lotes ya vencidos (antes de
-- hoy, el día argentino), el que venció antes primero, y antes del stock, como
-- `dar_de_baja_lote`. Lo que no cubren sigue el camino de siempre.
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
-- Premisa: los cuerpos vivos son los leídos el 10/11, y los helpers no existen
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cancelar_movimiento_sucursal(bigint,text)', '77ebfeff2e5e43788aea595c41971819'),
    ('public.denegar_movimiento_sucursal(bigint,text)', 'ab811d1116f642a3675a92a7b151189c'),
    ('public.editar_movimiento_sucursal(bigint,text,jsonb)', 'e2005a2061e79a6e00aea3ba4b13c7f4'),
    ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', 'b6f785535805e1345132c7a1909692c2'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)', '12229451da5e6757989fe45fced807c0'),
    ('public.registrar_nota_credito_lote(bigint,numeric,text,text)', 'acb406821131fdb5626af12580e8ed8d'),
    ('public.registrar_merma_manual(bigint,integer,text,text,bigint,jsonb)', '632faad8ebb2076300fa2f194c4ba247')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig 483 · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public._mov_lotes_devolver(bigint,jsonb)') IS NOT NULL
     OR to_regprocedure('public._cpp_recorrer_compra_parcial(bigint,bigint,bigint,numeric,numeric,integer)') IS NOT NULL
     OR to_regprocedure('public._cpp_devolucion_compra(bigint,bigint,bigint,integer,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 483 · un helper nuevo ya existe: revisar a mano';
  END IF;

  -- La 286 descartó devolver por el registro porque había envíos viejos sin
  -- registro. Si hubiera uno pendiente, cancelarlo ahora mandaría todo a la bolsa.
  IF EXISTS (SELECT 1 FROM movimientos_sucursal m
              WHERE m.estado = 'pendiente' AND m.stock_descontado
                AND m.created_at < '2026-10-05 21:09:04+00') THEN
    RAISE EXCEPTION 'mig 483 · hay un envío pendiente anterior a la 286 (sin registro de lotes): revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · Los helpers nuevos (de server: sin EXECUTE para nadie más que el dueño)
-- ---------------------------------------------------------------------------

-- STK-1 · Devuelve a cada lote lo que el registro de un envío dice que le sacó,
-- nunca más que su hueco. `p_por_lote` es [{lote_id, cantidad}]; las filas sin
-- lote (el lote se borró) y un lote sólo para la traza no reciben nada: esas
-- unidades quedan en la bolsa, que es adonde entró la subida del llamador. El
-- llamador ya tomó el producto; los lotes se toman por id (#1255). Devuelve
-- cuántas unidades fueron a algún lote.
CREATE FUNCTION public._mov_lotes_devolver(p_sucursal bigint, p_por_lote jsonb)
RETURNS integer
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  r       record;
  v_pone  integer;
  v_total integer := 0;
BEGIN
  FOR r IN
    SELECT l.id, l.solo_traza, l.cantidad - l.cantidad_restante AS hueco, d.cant
      FROM (SELECT x.lote_id, SUM(x.cantidad)::integer AS cant
              FROM jsonb_to_recordset(COALESCE(p_por_lote, '[]'::jsonb)) AS x(lote_id bigint, cantidad integer)
             WHERE x.lote_id IS NOT NULL AND x.cantidad > 0
             GROUP BY x.lote_id) d
      JOIN public.producto_lotes l ON l.id = d.lote_id AND l.sucursal_id = p_sucursal
     ORDER BY l.id
       FOR UPDATE OF l
  LOOP
    v_pone := CASE WHEN r.solo_traza THEN 0 ELSE LEAST(r.cant, GREATEST(r.hueco, 0)) END;
    IF v_pone > 0 THEN
      UPDATE public.producto_lotes SET cantidad_restante = cantidad_restante + v_pone WHERE id = r.id;
      v_total := v_total + v_pone;
    END IF;
  END LOOP;
  RETURN v_total;
END;
$fn$;

-- STK-4 · `_cpp_recorrer_compra` con una parte de la compra: recorre las líneas
-- del producto desde (p_stock, p_cpp) con `p_quedan` unidades de las que trajo,
-- repartidas entre los renglones en proporción (la nota acredita al costo neto
-- promedio: no sabe de qué renglón sale cada unidad). Con todas, es el recorrido
-- del alta; con cero, devuelve p_cpp, como la anulación.
CREATE FUNCTION public._cpp_recorrer_compra_parcial(
  p_compra   bigint,
  p_producto bigint,
  p_sucursal bigint,
  p_stock    numeric,
  p_cpp      numeric,
  p_quedan   integer
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $fn$
DECLARE
  r       record;
  v_s     numeric := p_stock;
  v_cpp   numeric := p_cpp;
  v_total numeric;
  v_q     numeric;
BEGIN
  SELECT SUM(ci.cantidad) INTO v_total
    FROM compra_items ci
   WHERE ci.compra_id = p_compra AND ci.producto_id = p_producto AND ci.sucursal_id = p_sucursal;
  IF COALESCE(v_total, 0) <= 0 OR COALESCE(p_quedan, 0) <= 0 THEN
    RETURN p_cpp;
  END IF;

  FOR r IN
    SELECT ci.cantidad,
           COALESCE(ci.costo_real_unitario, ci.costo_neto_unitario,
                    ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)) AS costo,
           public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario) AS fija
      FROM compra_items ci
     WHERE ci.compra_id = p_compra
       AND ci.producto_id = p_producto
       AND ci.sucursal_id = p_sucursal
     ORDER BY ci.id
  LOOP
    v_q := r.cantidad::numeric * LEAST(p_quedan, v_total) / v_total;
    CONTINUE WHEN v_q <= 0;
    v_cpp := public._cpp_linea(v_s, v_cpp, v_q, r.costo, r.fija);
    v_s   := v_s + v_q;
  END LOOP;
  RETURN v_cpp;
END;
$fn$;

-- STK-4 · La devolución de `p_devuelto` unidades de un producto de una compra
-- corrige el promedio como una anulación parcial (decisión del dueño, 10/11):
-- lo que deja la compra con lo que quedaba (sin lo que ya devolvieron las notas
-- anteriores, `p_antes`) contra lo que deja con lo que queda, las dos desde la
-- foto del alta, arrastrado por lo que entró después con el stock corrido por
-- lo devuelto, y sumado al vivo (`_cpp_corregido`), como `anular_compra_atomica`.
-- Devuelve NULL si corrigió (o no había nada que corregir) y 'sin_cpp_previo'
-- si la compra es anterior a la 236. El llamador ya tomó el producto y las
-- líneas de la compra.
CREATE FUNCTION public._cpp_devolucion_compra(
  p_compra   bigint,
  p_producto bigint,
  p_sucursal bigint,
  p_antes    integer,
  p_devuelto integer
)
RETURNS text
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  f        record;
  v_viejo  numeric;
  v_nuevo  numeric;
  v_cadena record;
BEGIN
  IF COALESCE(p_devuelto, 0) <= 0 THEN
    RETURN NULL;
  END IF;

  SELECT * INTO f FROM public._cpp_foto_compra(p_compra, p_sucursal) x WHERE x.producto_id = p_producto;
  IF NOT FOUND OR COALESCE(f.q, 0) <= 0 THEN
    RETURN NULL;
  END IF;
  IF f.c0 IS NULL THEN
    RETURN 'sin_cpp_previo';
  END IF;

  v_viejo := public._cpp_recorrer_compra_parcial(p_compra, p_producto, p_sucursal, f.s0, f.c0,
                                                 GREATEST(f.q - COALESCE(p_antes, 0), 0));
  v_nuevo := public._cpp_recorrer_compra_parcial(p_compra, p_producto, p_sucursal, f.s0, f.c0,
                                                 GREATEST(f.q - COALESCE(p_antes, 0) - p_devuelto, 0));

  SELECT * INTO v_cadena
    FROM public._cpp_arrastrar(p_producto, p_sucursal, p_compra, f.ts, -p_devuelto, v_viejo, v_nuevo);

  UPDATE productos p
     SET costo_promedio = public._cpp_corregido(p.costo_promedio, v_cadena.cpp_viejo, v_cadena.cpp_nuevo),
         updated_at     = now()
   WHERE p.id = p_producto AND p.sucursal_id = p_sucursal
     AND p.costo_promedio IS DISTINCT FROM
         public._cpp_corregido(p.costo_promedio, v_cadena.cpp_viejo, v_cadena.cpp_nuevo);
  RETURN NULL;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2 · STK-1 · cancelar, denegar y achicar un envío devuelven por el registro
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancelar_movimiento_sucursal(p_movimiento_id bigint, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE; v_origen bigint;
  v_item movimiento_sucursal_items%ROWTYPE; v_rows integer;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'El movimiento ya fue resuelto'); END IF;
  v_origen := v_mov.sucursal_origen_id;
  -- #1488: con NULL (no es de la sucursal del header, o está desactivado) el `<>`
  -- no cortaba. Primero la sucursal, después el rol, y los dos fallan cerrados.
  IF current_sucursal_id() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tu usuario no tiene acceso a la sucursal seleccionada'); END IF;
  IF current_sucursal_id() IS DISTINCT FROM v_origen THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo la sucursal que creó el envío puede cancelarlo'); END IF;
  IF COALESCE(public._rol_en_sucursal(auth.uid(), v_origen), '') <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo un admin puede cancelar un envío'); END IF;

  IF v_mov.stock_descontado THEN
    /* mig 483 (STK-1, #1516) · LO QUE VUELVE, VUELVE DE DONDE SALIÓ. La
       devolución iba con 'movimiento_cancelado', que está en la lista blanca
       del trigger de lotes: volvía por FEFO aunque el registro del envío
       (`movimiento_sucursal_item_lotes`) dice qué salió de cada lote. Lo que
       había salido de la bolsa rellenaba el hueco de un lote, y el lote
       quedaba +N y la bolsa −N (el mismo bug que #1085 cerró en los
       pedidos). Ahora la subida va con una etiqueta que NO está en la lista
       blanca (entra a la bolsa) y `_mov_lotes_devolver` le devuelve a cada
       lote lo que el registro dice que le sacó. Lo demás, que salió de la
       bolsa, se queda en la bolsa. Los productos, juntos y por id, antes del
       primer lote (#1255). */
    PERFORM 1 FROM productos
     WHERE sucursal_id = v_origen
       AND id IN (SELECT producto_origen_id FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id)
     ORDER BY id
       FOR UPDATE;

    PERFORM set_config('app.stock_origen', 'movimiento_cancelado_a_su_lote', true);
    PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
    PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
    PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

    FOR v_item IN SELECT * FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id ORDER BY producto_origen_id LOOP
      UPDATE productos SET stock = stock + v_item.cantidad, updated_at = now()
        WHERE id = v_item.producto_origen_id AND sucursal_id = v_origen;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'No se puede devolver "%" al stock: el producto ya no existe', v_item.origen_nombre;
      END IF;
      PERFORM public._mov_lotes_devolver(v_origen, (
        SELECT jsonb_agg(jsonb_build_object('lote_id', l.lote_id, 'cantidad', l.cantidad))
          FROM movimiento_sucursal_item_lotes l
         WHERE l.item_id = v_item.id));
    END LOOP;
  END IF;

  -- mig 286: el envio ya no lleva nada. La devolucion a los lotes ya la hizo
  -- el loop de arriba (mig 483).
  DELETE FROM movimiento_sucursal_item_lotes
   WHERE item_id IN (SELECT id FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id);

  UPDATE movimientos_sucursal SET estado = 'cancelada', stock_descontado = false, motivo_rechazo = p_motivo,
      resuelto_por = auth.uid(), resuelto_at = now()
    WHERE id = p_movimiento_id;

  PERFORM public._notificar_sucursal_roles(
    v_mov.sucursal_destino_id, auth.uid(), 'movimiento_cancelado',
    'Movimiento cancelado por el origen',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_origen), 'La sucursal origen')
      || ' canceló el movimiento #' || p_movimiento_id || COALESCE('. Motivo: ' || p_motivo, ''),
    'movimiento_sucursal', p_movimiento_id, jsonb_build_object('origen_id', v_origen, 'motivo', p_motivo)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $function$;

CREATE OR REPLACE FUNCTION public.denegar_movimiento_sucursal(p_movimiento_id bigint, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE; v_destino bigint;
  v_item movimiento_sucursal_items%ROWTYPE; v_rows integer;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'El movimiento ya fue resuelto'); END IF;
  v_destino := v_mov.sucursal_destino_id;
  -- #1488: con NULL (no es de la sucursal del header, o está desactivado) el `<>`
  -- no cortaba. Primero la sucursal, después el rol, y los dos fallan cerrados.
  IF current_sucursal_id() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tu usuario no tiene acceso a la sucursal seleccionada'); END IF;
  IF current_sucursal_id() IS DISTINCT FROM v_destino THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tenés que estar en la sucursal destino'); END IF;
  IF COALESCE(public._rol_en_sucursal(auth.uid(), v_destino), '') NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;

  IF v_mov.stock_descontado THEN
    -- mig 483 (STK-1, #1516): idem cancelar. La subida va a la bolsa del
    -- origen y cada lote recibe lo que el registro del envío dice que le sacó.
    PERFORM 1 FROM productos
     WHERE sucursal_id = v_mov.sucursal_origen_id
       AND id IN (SELECT producto_origen_id FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id)
     ORDER BY id
       FOR UPDATE;

    PERFORM set_config('app.stock_origen', 'movimiento_denegado_a_su_lote', true);
    PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
    PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
    PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

    FOR v_item IN SELECT * FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id ORDER BY producto_origen_id LOOP
      UPDATE productos SET stock = stock + v_item.cantidad, updated_at = now()
        WHERE id = v_item.producto_origen_id AND sucursal_id = v_mov.sucursal_origen_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'No se puede devolver "%" al origen: el producto ya no existe ahí', v_item.origen_nombre;
      END IF;
      PERFORM public._mov_lotes_devolver(v_mov.sucursal_origen_id, (
        SELECT jsonb_agg(jsonb_build_object('lote_id', l.lote_id, 'cantidad', l.cantidad))
          FROM movimiento_sucursal_item_lotes l
         WHERE l.item_id = v_item.id));
    END LOOP;
  END IF;

  -- mig 286: idem cancelar.
  DELETE FROM movimiento_sucursal_item_lotes
   WHERE item_id IN (SELECT id FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id);

  UPDATE movimientos_sucursal SET estado = 'denegada', stock_descontado = false, motivo_rechazo = p_motivo,
      resuelto_por = auth.uid(), resuelto_at = now()
    WHERE id = p_movimiento_id;

  PERFORM public._notificar_sucursal_roles(
    v_mov.sucursal_origen_id, auth.uid(), 'movimiento_denegado',
    'Movimiento denegado',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_destino), 'La sucursal destino') || ' denegó tu movimiento #' || p_movimiento_id
      || CASE WHEN v_mov.stock_descontado THEN '. Se devolvió el stock.' ELSE '' END
      || COALESCE(' Motivo: ' || p_motivo, ''),
    'movimiento_sucursal', p_movimiento_id, jsonb_build_object('destino_id', v_destino, 'motivo', p_motivo)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $function$;

CREATE OR REPLACE FUNCTION public.editar_movimiento_sucursal(p_movimiento_id bigint, p_notas text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE; v_origen bigint; v_agg record; v_prod productos%ROWTYPE;
  v_errores text[] := ARRAY[]::text[]; v_rows integer;
  v_total numeric := 0; v_count integer := 0; v_unidades integer := 0;
  v_foto jsonb; v_altas jsonb := '[]'::jsonb; v_viejos bigint[]; v_item_viejo record;
  v_reg jsonb;  -- mig 483: el registro del item por lote, antes de achicarlo
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'Solo se puede editar un envío pendiente'); END IF;
  v_origen := v_mov.sucursal_origen_id;
  -- #1488: con NULL (no es de la sucursal del header, o está desactivado) el `<>`
  -- no cortaba. Primero la sucursal, después el rol, y los dos fallan cerrados.
  IF current_sucursal_id() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tu usuario no tiene acceso a la sucursal seleccionada'); END IF;
  IF current_sucursal_id() IS DISTINCT FROM v_origen THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo la sucursal que creó el envío puede editarlo'); END IF;
  IF COALESCE(public._rol_en_sucursal(auth.uid(), v_origen), '') <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo un admin puede editar un envío'); END IF;
  IF NOT v_mov.stock_descontado THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Este envío es anterior al descuento preventivo. Cancelalo y creá uno nuevo.'); END IF;

  -- #1471 (STK-F-7): una línea con cantidad 0, negativa o con decimales, o sin
  -- un producto, se descartaba en silencio y el envío salía con menos de lo que
  -- se cargó. Ahora se rechaza el envío entero y se dice qué línea.
  IF jsonb_typeof(COALESCE(p_items, '[]'::jsonb)) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Los productos del envío tienen que ser una lista'); END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
    WHERE CASE WHEN COALESCE(e->>'producto_id', '') !~ '^\s*[0-9]+\s*$'
                 OR COALESCE(e->>'cantidad', '') !~ '^\s*-?[0-9]+\s*$' THEN true
               ELSE (e->>'cantidad')::numeric <= 0 END
  ) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Cada producto del envío necesita una cantidad entera mayor a 0: ' || (
        SELECT string_agg(COALESCE(pr.nombre, 'producto ' || COALESCE(e.val->>'producto_id', '?'))
                            || ' (' || COALESCE(e.val->>'cantidad', 'sin cantidad') || ')', ', ' ORDER BY e.n)
          FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) WITH ORDINALITY AS e(val, n)
          LEFT JOIN productos pr
            ON pr.id = CASE WHEN COALESCE(e.val->>'producto_id', '') ~ '^\s*[0-9]+\s*$'
                            THEN (e.val->>'producto_id')::bigint END
           AND pr.sucursal_id = v_origen
         WHERE CASE WHEN COALESCE(e.val->>'producto_id', '') !~ '^\s*[0-9]+\s*$'
                      OR COALESCE(e.val->>'cantidad', '') !~ '^\s*-?[0-9]+\s*$' THEN true
                    ELSE (e.val->>'cantidad')::numeric <= 0 END));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
    WHERE COALESCE((e->>'cantidad')::int, 0) > 0
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El envío no puede quedar sin productos. Usá Cancelar.');
  END IF;

  FOR v_agg IN
    WITH nuevas AS (
      SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
      FROM jsonb_array_elements(p_items) e WHERE COALESCE((e->>'cantidad')::int, 0) > 0 GROUP BY 1
    ), viejas AS (
      SELECT producto_origen_id AS pid, SUM(cantidad)::int AS cant
      FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id GROUP BY 1
    )
    SELECT COALESCE(n.pid, v.pid) AS pid,
           COALESCE(n.cant, 0) - COALESCE(v.cant, 0) AS delta
    FROM nuevas n FULL OUTER JOIN viejas v ON v.pid = n.pid
    ORDER BY 1
  LOOP
    CONTINUE WHEN v_agg.delta = 0;
    SELECT * INTO v_prod FROM productos WHERE id = v_agg.pid AND sucursal_id = v_origen FOR UPDATE;
    IF NOT FOUND THEN
      v_errores := array_append(v_errores, 'Producto ' || v_agg.pid || ' no existe en la sucursal origen');
    ELSIF v_agg.delta > 0 AND v_prod.stock < v_agg.delta THEN
      v_errores := array_append(v_errores,
        v_prod.nombre || ': stock insuficiente para agregar ' || v_agg.delta || ' (disponible ' || v_prod.stock || ')');
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', array_to_string(v_errores, ' · '), 'errores', to_jsonb(v_errores));
  END IF;

  PERFORM set_config('app.stock_origen', 'movimiento_editado', true);
  PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
  PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
  PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

  -- mig 286: los items de antes de la edicion (se borran al final).
  SELECT COALESCE(array_agg(id), '{}') INTO v_viejos
    FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id;

  FOR v_agg IN
    WITH nuevas AS (
      SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
      FROM jsonb_array_elements(p_items) e WHERE COALESCE((e->>'cantidad')::int, 0) > 0 GROUP BY 1
    ), viejas AS (
      SELECT producto_origen_id AS pid, SUM(cantidad)::int AS cant
      FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id GROUP BY 1
    )
    SELECT COALESCE(n.pid, v.pid) AS pid,
           COALESCE(n.cant, 0) - COALESCE(v.cant, 0) AS delta
    FROM nuevas n FULL OUTER JOIN viejas v ON v.pid = n.pid
    ORDER BY 1
  LOOP
    CONTINUE WHEN v_agg.delta = 0;
    /* mig 483 (STK-1, #1516) · la bajada (sale más) sigue con
       'movimiento_editado': el trigger come la bolsa y después FEFO, y la foto
       dice qué lotes consumió. La subida (sale menos) ya no: con esa etiqueta,
       que está en la lista blanca, volvía por FEFO al hueco más temprano
       aunque las unidades hubieran salido de la bolsa. Ahora entra a la bolsa
       y abajo cada lote recibe lo que el registro del item deja de llevar. */
    PERFORM set_config('app.stock_origen',
      CASE WHEN v_agg.delta > 0 THEN 'movimiento_editado' ELSE 'movimiento_editado_a_su_lote' END, true);
    v_foto := public._mov_lotes_foto(v_agg.pid, v_origen);
    UPDATE productos SET stock = stock - v_agg.delta, updated_at = now()
      WHERE id = v_agg.pid AND sucursal_id = v_origen;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
      RAISE EXCEPTION 'El producto % ya no existe en la sucursal origen', v_agg.pid;
    END IF;

    -- mig 286: lo que efectivamente paso con los lotes en este UPDATE.
    IF v_agg.delta > 0 THEN
      -- Sale mas: se agrega lo que consumio la re-bajada (al item nuevo, abajo).
      SELECT v_altas || COALESCE(jsonb_agg(d || jsonb_build_object('pid', v_agg.pid)), '[]'::jsonb)
        INTO v_altas
        FROM jsonb_array_elements(public._mov_lotes_diff(v_agg.pid, v_origen, v_foto, -1)) d;
    ELSE
      -- Sale menos: se descuenta del registro del item viejo.
      SELECT id, cantidad INTO v_item_viejo
        FROM movimiento_sucursal_items
       WHERE movimiento_id = p_movimiento_id AND producto_origen_id = v_agg.pid
       ORDER BY id LIMIT 1;
      IF FOUND THEN
        /* mig 483: ningún lote recibió nada por FEFO, así que la regla de la
           286 corre sin su paso (1): lo que deja de viajar sale primero de lo
           que vino de la bolsa, y después del registro, el vencimiento más
           lejano primero. Lo que el registro pierde de cada lote vuelve a ese
           lote. */
        SELECT COALESCE(jsonb_object_agg(t.lote_id::text, t.cant), '{}'::jsonb) INTO v_reg
          FROM (SELECT lote_id, SUM(cantidad)::integer AS cant
                  FROM movimiento_sucursal_item_lotes
                 WHERE item_id = v_item_viejo.id AND lote_id IS NOT NULL
                 GROUP BY lote_id) t;
        PERFORM public._mov_lotes_descontar(v_item_viejo.id, v_item_viejo.cantidad, -v_agg.delta, '[]'::jsonb);
        PERFORM public._mov_lotes_devolver(v_origen, (
          SELECT jsonb_agg(jsonb_build_object('lote_id', a.key::bigint,
                                              'cantidad', a.value::integer - COALESCE(t.cant, 0)))
            FROM jsonb_each_text(v_reg) a
            LEFT JOIN (SELECT lote_id, SUM(cantidad)::integer AS cant
                         FROM movimiento_sucursal_item_lotes
                        WHERE item_id = v_item_viejo.id AND lote_id IS NOT NULL
                        GROUP BY lote_id) t ON t.lote_id = a.key::bigint
           WHERE a.value::integer > COALESCE(t.cant, 0)));
      END IF;
    END IF;
  END LOOP;

  FOR v_agg IN
    SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
    FROM jsonb_array_elements(p_items) e
    WHERE COALESCE((e->>'cantidad')::int, 0) > 0
    GROUP BY 1 ORDER BY 1
  LOOP
    SELECT * INTO v_prod FROM productos WHERE id = v_agg.pid AND sucursal_id = v_origen;
    IF NOT FOUND THEN RAISE EXCEPTION 'El producto % ya no existe en la sucursal origen', v_agg.pid; END IF;

    INSERT INTO movimiento_sucursal_items (
      movimiento_id, producto_origen_id, cantidad,
      origen_nombre, origen_codigo, origen_tp_import_id, origen_categoria,
      origen_precio, origen_precio_sin_iva, origen_costo_sin_iva, origen_costo_con_iva,
      origen_impuestos_internos, origen_ii_encuadre_id, origen_porcentaje_iva, origen_condicion_iva, origen_stock_minimo,
      origen_unidades_por_fardo, origen_etiqueta_bulto,
      stock_origen_anterior, stock_origen_nuevo, origen_costo_promedio
    ) VALUES (
      p_movimiento_id, v_prod.id, v_agg.cant,
      v_prod.nombre, v_prod.codigo, v_prod.tp_import_id, v_prod.categoria,
      v_prod.precio, v_prod.precio_sin_iva, v_prod.costo_sin_iva, v_prod.costo_con_iva,
      v_prod.impuestos_internos, v_prod.ii_encuadre_id, v_prod.porcentaje_iva, v_prod.condicion_iva, v_prod.stock_minimo,
      v_prod.unidades_de_venta_por_fardo, v_prod.etiqueta_bulto,
      v_prod.stock + v_agg.cant, v_prod.stock, v_prod.costo_promedio
    );
    v_total := v_total + COALESCE(v_prod.costo_con_iva, v_prod.costo_sin_iva, 0) * v_agg.cant;
    v_count := v_count + 1;
    v_unidades := v_unidades + v_agg.cant;
  END LOOP;

  -- mig 286: el registro del item viejo pasa al nuevo del mismo producto; lo
  -- agregado por la re-bajada se cuelga del nuevo; los viejos se borran (un
  -- producto que salio del envio se lleva sus filas por el CASCADE).
  UPDATE movimiento_sucursal_item_lotes l
     SET item_id = n.id
    FROM movimiento_sucursal_items o
    JOIN movimiento_sucursal_items n
      ON n.movimiento_id = o.movimiento_id
     AND n.producto_origen_id = o.producto_origen_id
     AND NOT (n.id = ANY(v_viejos))
   WHERE l.item_id = o.id
     AND o.id = ANY(v_viejos);

  DELETE FROM movimiento_sucursal_items WHERE id = ANY(v_viejos);

  INSERT INTO movimiento_sucursal_item_lotes (item_id, sucursal_id, lote_id, fecha_vencimiento, cantidad)
  SELECT n.id, v_origen, a.lote_id, a.fecha_vencimiento, a.cantidad
    FROM jsonb_to_recordset(v_altas) AS a(pid bigint, lote_id bigint, fecha_vencimiento date, cantidad integer)
    JOIN movimiento_sucursal_items n
      ON n.movimiento_id = p_movimiento_id AND n.producto_origen_id = a.pid;

  UPDATE movimientos_sucursal
    SET notas = p_notas, total_costo = v_total, total_unidades = v_unidades,
        editado_por = auth.uid(), editado_at = now()
    WHERE id = p_movimiento_id;

  PERFORM public._notificar_sucursal_roles(
    v_mov.sucursal_destino_id, auth.uid(), 'movimiento_editado',
    'Movimiento modificado por el origen',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_origen), 'La sucursal origen')
      || ' modificó el movimiento #' || p_movimiento_id || ': ahora son ' || v_count || ' producto(s), ' || v_unidades || ' unidades.',
    'movimiento_sucursal', p_movimiento_id,
    jsonb_build_object('origen_id', v_origen, 'items', v_count, 'unidades', v_unidades)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $function$;

-- ---------------------------------------------------------------------------
-- 3 · STK-5 · el arrastre ve los ingresos por envío
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
  FOR r IN
    SELECT x.* FROM (
      SELECT 'compra'::text AS tipo, ci.id, ci.created_at AS ts, ci.compra_id AS orden,
             ci.stock_anterior, ci.costo_promedio_anterior, ci.cantidad,
             COALESCE(ci.costo_real_unitario, ci.costo_neto_unitario,
                      ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)) AS costo,
             public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario) AS fija
        FROM compra_items ci
        JOIN compras c ON c.id = ci.compra_id AND c.sucursal_id = ci.sucursal_id
       WHERE ci.producto_id = p_producto
         AND ci.sucursal_id = p_sucursal
         AND ci.compra_id <> p_compra
         AND c.estado <> 'cancelada'
         AND (ci.created_at, ci.compra_id) > (p_desde, p_compra)
      UNION ALL
      SELECT 'envio'::text, mi.id, m.resuelto_at, m.id,
             mi.stock_destino_anterior, NULL::numeric, mi.cantidad,
             mi.origen_costo_promedio, true
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
    -- valor de la cadena.
    v_antes_viejo := COALESCE(r.costo_promedio_anterior, cpp_viejo);
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

    cpp_viejo := public._cpp_linea(r.stock_anterior, v_antes_viejo, r.cantidad, r.costo, r.fija);
    cpp_nuevo := public._cpp_linea(v_s_nuevo, v_antes_nuevo, r.cantidad, r.costo, r.fija);
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4 · STK-4 · las dos puertas de la NC de devolución corrigen el promedio
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_nota_credito(p_compra_id bigint, p_numero_nota character varying DEFAULT NULL::character varying, p_motivo text DEFAULT NULL::text, p_subtotal numeric DEFAULT 0, p_iva numeric DEFAULT 0, p_total numeric DEFAULT 0, p_usuario_id uuid DEFAULT NULL::uuid, p_items jsonb DEFAULT '[]'::jsonb, p_impuestos_internos numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_nota_id BIGINT;
  v_exceso TEXT;  -- mig 236
  v_tipo TEXT; v_ii NUMERIC; v_total NUMERIC;  -- mig 280
  v_de_lotes INTEGER; v_toma INTEGER; v_lote RECORD;  -- #1079
  v_items JSONB;          -- #1471: p_items, o [] si no vino
  v_lineas JSONB;         -- #1471: lo que acredita la nota, calculado acá
  v_linea RECORD;         -- #1471
  v_mal TEXT;             -- #1471
  v_subtotal NUMERIC; v_iva NUMERIC;  -- #1471
  v_aviso TEXT; v_avisos JSONB := '[]'::JSONB;  -- mig 483
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF NOT (es_encargado_o_admin()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para registrar notas de credito');
  END IF;

  -- #1056: la nota la firma quien la carga. El parámetro queda por la firma
  -- de la RPC; si viene, tiene que ser el mismo usuario.
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'La nota de credito se registra a nombre de quien la carga');
  END IF;

  v_items := COALESCE(p_items, '[]'::jsonb);
  IF jsonb_typeof(v_items) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Los items de la nota de credito tienen que ser una lista');
  END IF;

  -- #1471: cada renglón dice un producto y una cantidad entera mayor a 0. Antes
  -- un "2.5" o un id que no es un número cortaba con un error de cast.
  SELECT string_agg(format('renglón %s', e.n), ', ' ORDER BY e.n)
    INTO v_mal
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS e(val, n)
   WHERE CASE WHEN COALESCE(e.val->>'producto_id', '') !~ '^\s*[0-9]+\s*$'
                OR COALESCE(e.val->>'cantidad', '') !~ '^\s*[0-9]+\s*$' THEN true
              ELSE (e.val->>'cantidad')::NUMERIC <= 0 END;
  IF v_mal IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Cada producto de la nota de credito necesita una cantidad entera mayor a 0 (' || v_mal || ')');
  END IF;

  -- #1095: la compra se toma FOR SHARE, primer lock de la nota. Serializa
  -- contra anular_compra_atomica (que la toma FOR UPDATE): si la anulación va
  -- primero, acá se reevalúa y se ve cancelada; si la nota va primero, la
  -- anulación espera y cuenta esta nota.
  PERFORM 1 FROM compras
   WHERE id = p_compra_id AND estado <> 'cancelada' AND sucursal_id = v_sucursal
     FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada o cancelada');
  END IF;

  /* #1471 (STK-F-2) · EL ORDEN GLOBAL: compra → productos por id → líneas de
     la compra → lotes. Los productos se tomaban de a uno en el orden del JSON,
     y DESPUÉS de las líneas de la compra: contra una venta [A, B] una nota
     [B, A] daba 40P01, y contra actualizar_compra_items (que bloquea los
     productos y después borra las líneas) también. Los FOR UPDATE de abajo
     vuelven a pedir filas ya tomadas. */
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT (i->>'producto_id')::BIGINT FROM jsonb_array_elements(v_items) i)
   ORDER BY id
     FOR UPDATE;

  /* mig 236 · EL TOPE DE LO ACREDITABLE.

     Hasta aca el unico tope vivia en `ModalNotaCredito` (`maxCreditable`, sobre
     una query con staleTime de 5 minutos). Dos notas simultaneas sobre la misma
     compra leian las dos el mismo "ya acreditado", acreditaban el doble y
     descontaban el stock dos veces; y nada impedia acreditar un producto que la
     compra ni siquiera tenia.

     El FOR UPDATE sobre las lineas de la compra es lo que SERIALIZA: la segunda
     nota espera a que la primera termine y recien entonces cuenta lo acreditado,
     que ya la incluye. Va antes de leer los totales, no despues.

     El corte es POR PRODUCTO, igual que el del modal: la base no sabe de que
     renglon salio cada unidad, y repartir por linea seria inventar una
     convencion que el reparto de la pantalla ya hace para mostrar. */
  PERFORM 1 FROM compra_items
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
   ORDER BY id
     FOR UPDATE;

  SELECT string_agg(
           COALESCE(pr.nombre, '#' || d.producto_id) || ' (' ||
           CASE WHEN d.comprado IS NULL              THEN 'no esta en esta compra'
                WHEN d.pedido IS NULL OR d.pedido <= 0 THEN 'cantidad invalida'
                ELSE format('se piden %s y quedan %s', d.pedido,
                            d.comprado - COALESCE(d.acreditado, 0)) END || ')',
           '; ' ORDER BY d.producto_id)
    INTO v_exceso
    FROM (
      SELECT pe.producto_id, pe.pedido, co.comprado, ac.acreditado
        FROM (SELECT (i->>'producto_id')::BIGINT AS producto_id,
                     SUM((i->>'cantidad')::INTEGER) AS pedido
                FROM jsonb_array_elements(v_items) i
               GROUP BY 1) pe
        LEFT JOIN (SELECT producto_id, SUM(cantidad)::INT AS comprado
                     FROM compra_items
                    WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
                    GROUP BY 1) co ON co.producto_id = pe.producto_id
        LEFT JOIN (SELECT nci.producto_id, SUM(nci.cantidad)::INT AS acreditado
                     FROM nota_credito_items nci
                     JOIN notas_credito nc ON nc.id = nci.nota_credito_id
                                          AND nc.sucursal_id = nci.sucursal_id
                    WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
                    GROUP BY 1) ac ON ac.producto_id = pe.producto_id
    ) d
    LEFT JOIN productos pr ON pr.id = d.producto_id AND pr.sucursal_id = v_sucursal
   WHERE d.comprado IS NULL
      OR d.pedido IS NULL
      OR d.pedido <= 0
      OR d.pedido > d.comprado - COALESCE(d.acreditado, 0);

  IF v_exceso IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No se puede acreditar: ' || v_exceso ||
      '. Si la pantalla mostraba otro maximo, recargala: puede haber otra nota de credito sobre esta compra.');
  END IF;

  /* mig 280 (#867) · DEVOLUCION O AJUSTE.

     El tipo lo decide la forma de la nota, no el caller: con items es una
     devolucion (baja stock y acredita lo devuelto, calculado aca); sin items es
     un ajuste sobre la factura —descuento, diferencia de precio, II mal
     liquidado— y no toca stock, costos ni fichas. Los importes del ajuste los
     declara quien lo carga, porque no hay lineas de donde sacarlos. */
  v_tipo := CASE WHEN jsonb_array_length(v_items) > 0 THEN 'devolucion' ELSE 'ajuste' END;

  IF v_tipo = 'ajuste' THEN
    IF COALESCE(p_subtotal, 0) < 0 OR COALESCE(p_iva, 0) < 0 OR COALESCE(p_impuestos_internos, 0) < 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Los importes de la nota de credito no pueden ser negativos');
    END IF;
    IF COALESCE(p_total, 0) <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Una nota de credito sin mercaderia tiene que tener un total mayor a cero');
    END IF;
    IF NULLIF(btrim(COALESCE(p_motivo, '')), '') IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Una nota de credito sin mercaderia necesita un motivo');
    END IF;
    v_subtotal := p_subtotal;
    v_iva      := p_iva;
    v_ii       := round(COALESCE(p_impuestos_internos, 0), 2);
    v_total    := p_total;
  ELSE
    /* #1471 (STK-F-3) · LO QUE SE ACREDITA LO CALCULA LA BASE.

       Se tomaban del front el costo y el subtotal de cada renglón, y el front
       usaba `costo_unitario`, el costo ANTES de la bonificación: un regalo al
       100 % se acreditaba a precio lleno. Ahora cada producto se acredita al
       costo neto PROMEDIO de sus renglones en la factura (decisión del dueño,
       05/11): la base no sabe de qué renglón sale cada unidad, y el promedio
       nunca acredita más de lo que se pagó aunque haya varias notas. Es la
       misma cuenta que registrar_nota_credito_lote y que `notaCredito.ts`:
         costo   = Σ cantidad·costo·(1 − bonif/100) / Σ cantidad
         importe = round(devuelto · costo, 2)
         IVA     = round(importe · alícuota ponderada por el neto / 100, 2)
       Lo que mandó el front se compara contra esto y se rechaza si no cierra
       (un bundle viejo del PWA, o una pantalla con la compra desactualizada). */
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.producto_id)
      INTO v_lineas
      FROM (
        SELECT pe.producto_id, pe.cantidad, pe.sub_front, pr.stock, pr.nombre,
               co.neto / co.comprado AS costo,
               round(pe.cantidad * co.neto / co.comprado, 2) AS subtotal,
               round(round(pe.cantidad * co.neto / co.comprado, 2)
                     * COALESCE(co.base_iva / NULLIF(co.neto, 0), 0) / 100, 2) AS iva
          FROM (SELECT (i->>'producto_id')::BIGINT AS producto_id,
                       SUM((i->>'cantidad')::INTEGER)::INTEGER AS cantidad,
                       SUM(NULLIF(i->>'subtotal', '')::NUMERIC) AS sub_front
                  FROM jsonb_array_elements(v_items) i
                 GROUP BY 1) pe
          JOIN (SELECT ci.producto_id,
                       SUM(ci.cantidad) AS comprado,
                       SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)) AS neto,
                       SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)
                           * CASE WHEN ci.condicion_iva = 'gravado'
                                  THEN COALESCE(ci.porcentaje_iva, 21) ELSE 0 END) AS base_iva
                  FROM compra_items ci
                 WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = v_sucursal
                 GROUP BY 1) co ON co.producto_id = pe.producto_id
          JOIN productos pr ON pr.id = pe.producto_id AND pr.sucursal_id = v_sucursal
      ) x;

    -- #1471 (STK-F-5): lo devuelto sale del stock. Si no alcanza, se rechaza
    -- (decisión del dueño, 05/11), como en la nota por lote. Se clampeaba a 0
    -- en silencio y el ledger decía otra cosa que la nota.
    SELECT string_agg(format('%s (hay %s y se devuelven %s)', l.nombre, COALESCE(l.stock, 0), l.cantidad),
                      '; ' ORDER BY l.producto_id)
      INTO v_mal
      FROM jsonb_to_recordset(v_lineas) AS l(producto_id BIGINT, cantidad INTEGER, stock INTEGER, nombre TEXT)
     WHERE COALESCE(l.stock, 0) < l.cantidad;
    IF v_mal IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error',
        'No alcanza el stock para devolver: ' || v_mal || '. La nota no se registró.');
    END IF;

    SELECT COALESCE(sum(l.subtotal), 0), COALESCE(sum(l.iva), 0)
      INTO v_subtotal, v_iva
      FROM jsonb_to_recordset(v_lineas) AS l(subtotal NUMERIC, iva NUMERIC);

    SELECT string_agg(format('%s (la pantalla dice %s y la factura da %s)', l.nombre,
                             COALESCE(round(l.sub_front, 2)::TEXT, 'nada'), l.subtotal),
                      '; ' ORDER BY l.producto_id)
      INTO v_mal
      FROM jsonb_to_recordset(v_lineas) AS l(producto_id BIGINT, nombre TEXT, sub_front NUMERIC, subtotal NUMERIC)
     WHERE l.sub_front IS NULL OR abs(l.sub_front - l.subtotal) > 0.05;
    IF v_mal IS NULL AND (abs(COALESCE(p_subtotal, 0) - v_subtotal) > 1 OR abs(COALESCE(p_iva, 0) - v_iva) > 1) THEN
      v_mal := format('subtotal %s e IVA %s, y la factura da %s y %s',
                      round(COALESCE(p_subtotal, 0), 2), round(COALESCE(p_iva, 0), 2), v_subtotal, v_iva);
    END IF;
    IF v_mal IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error',
        'El importe de la nota no coincide con el costo neto de la factura (con su bonificación): ' || v_mal ||
        '. Recargá la aplicación y volvé a cargarla.');
    END IF;

    v_ii    := public.ii_nota_credito_compra(p_compra_id, v_sucursal, v_items);
    v_total := v_subtotal + v_iva + v_ii;
  END IF;

  -- `fecha` en hora argentina (como registrar_nota_credito_lote): decide el
  -- periodo de posicion_fiscal y del gerencial.
  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id,
                             impuestos_internos, tipo)
  VALUES (p_compra_id, p_numero_nota, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
          v_subtotal, v_iva, v_total, p_motivo, auth.uid(), v_sucursal,
          v_ii, v_tipo)
  RETURNING id INTO v_nota_id;

  IF v_tipo = 'devolucion' THEN
    -- #1043: la devolución baja stock etiquetada para el ledger; la referencia es
    -- la nota, como en registrar_nota_credito_lote. Antes entraba como 'auto'.
    PERFORM set_config('app.stock_origen',   'nota_credito',   true);
    PERFORM set_config('app.stock_ref_tipo', 'notas_credito',  true);
    PERFORM set_config('app.stock_ref_id',   v_nota_id::text,  true);
    PERFORM set_config('app.stock_user_id',  auth.uid()::text, true);

    -- #1471: los lotes de la compra, después de los productos y por id.
    PERFORM 1 FROM producto_lotes
     WHERE compra_id = p_compra_id
       AND sucursal_id = v_sucursal
       AND producto_id IN (SELECT l.producto_id FROM jsonb_to_recordset(v_lineas) AS l(producto_id BIGINT))
     ORDER BY id
       FOR UPDATE;

    -- #1471: un item por producto, con lo que calculó la base, en orden de id.
    FOR v_linea IN
      SELECT * FROM jsonb_to_recordset(v_lineas)
               AS l(producto_id BIGINT, cantidad INTEGER, stock INTEGER, costo NUMERIC, subtotal NUMERIC)
       ORDER BY l.producto_id
    LOOP
      INSERT INTO nota_credito_items (nota_credito_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, sucursal_id)
      VALUES (v_nota_id, v_linea.producto_id, v_linea.cantidad, round(v_linea.costo, 4), v_linea.subtotal,
              v_linea.stock, v_linea.stock - v_linea.cantidad, v_sucursal);
      -- #1079: lo devuelto sale de los lotes de ESTA compra, el que vence antes
      -- primero, y ANTES del stock (como registrar_nota_credito_lote). Si no,
      -- el trigger come la bolsa y después FEFO global, y el lote de la compra
      -- sigue contando unidades que ya se devolvieron. Lo que a estos lotes no
      -- les alcance sale de la bolsa: con el lote ya descontado, el trigger ve la
      -- bolsa crecer en lo mismo y no toca otros lotes.
      v_de_lotes := v_linea.cantidad;
      FOR v_lote IN
        SELECT id, cantidad_restante
          FROM producto_lotes
         WHERE compra_id = p_compra_id
           AND producto_id = v_linea.producto_id
           AND sucursal_id = v_sucursal
           AND cantidad_restante > 0
         ORDER BY fecha_vencimiento, id
           FOR UPDATE
      LOOP
        EXIT WHEN v_de_lotes <= 0;
        v_toma := LEAST(v_de_lotes, v_lote.cantidad_restante);
        UPDATE producto_lotes SET cantidad_restante = cantidad_restante - v_toma WHERE id = v_lote.id;
        v_de_lotes := v_de_lotes - v_toma;
      END LOOP;

      UPDATE productos SET stock = stock - v_linea.cantidad WHERE id = v_linea.producto_id AND sucursal_id = v_sucursal;

      -- mig 483 (STK-4, #1516; decisión del dueño, 10/11): la devolución corrige
      -- el promedio como una anulación parcial de la compra. Lo que ya
      -- devolvieron las notas anteriores de esta compra es el punto de partida.
      v_aviso := public._cpp_devolucion_compra(p_compra_id, v_linea.producto_id, v_sucursal,
        (SELECT COALESCE(SUM(nci.cantidad), 0)::INTEGER
           FROM nota_credito_items nci
           JOIN notas_credito nc ON nc.id = nci.nota_credito_id AND nc.sucursal_id = nci.sucursal_id
          WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
            AND nci.producto_id = v_linea.producto_id AND nc.id <> v_nota_id),
        v_linea.cantidad);
      IF v_aviso IS NOT NULL THEN
        v_avisos := v_avisos || jsonb_build_object(
          'producto_id', v_linea.producto_id, 'motivo', v_aviso,
          'warning', 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo');
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'nota_credito_id', v_nota_id,
                            'tipo', v_tipo, 'impuestos_internos', v_ii, 'total', v_total,
                            'subtotal', v_subtotal, 'iva', v_iva,
                            'warnings', CASE WHEN jsonb_array_length(v_avisos) > 0 THEN v_avisos END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_nota_credito_lote(p_lote_id bigint, p_cantidad numeric, p_numero_nota text, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal   bigint := public.current_sucursal_id();
  v_rol        text;
  v_lote       record;
  v_cant       integer;
  v_stock      integer;
  v_costo      numeric;
  v_tasa_iva   numeric;
  v_subtotal   numeric;
  v_iva        numeric;
  v_comprado   integer;
  v_acreditado integer;
  v_nota_id    bigint;
  v_compra_id  bigint;  -- #1095
  v_ii         numeric;  -- mig 280
  v_producto_id bigint;  -- #1471
  v_aviso      text;     -- mig 483
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- Mismo gate que dar_de_baja_lote: ver y sacar de circulacion son dos
  -- permisos distintos. Deposito mira lo que se le vence; administracion
  -- decide si se tira o se devuelve.
  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  -- numeric en la firma porque PostgREST manda los numeros de JSON sin tipo,
  -- pero las unidades son enteras: `nota_credito_items.cantidad` es integer y
  -- `producto_lotes.cantidad_restante` tambien. Redondear en silencio haria que
  -- el lote y la nota digan cosas distintas.
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad a devolver tiene que ser mayor a 0';
  END IF;
  IF p_cantidad <> trunc(p_cantidad) THEN
    RAISE EXCEPTION 'La cantidad a devolver tiene que ser un numero entero de unidades: %', p_cantidad;
  END IF;
  v_cant := p_cantidad::integer;

  -- #1095: la compra del lote se toma FOR SHARE ANTES que el lote, el mismo
  -- primer paso que registrar_nota_credito y que anular_compra_atomica (que la
  -- toma FOR UPDATE). Así la nota y la anulación se serializan en la compra y
  -- ninguna anulación pasa con esta nota a medio registrar. El compra_id se lee
  -- sin lock y se vuelve a comparar abajo, con el lote ya tomado. Un lote
  -- manual o inexistente sigue de largo y cae en los errores de siempre.
  SELECT compra_id, producto_id INTO v_compra_id, v_producto_id
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal;
  IF v_compra_id IS NOT NULL THEN
    PERFORM 1 FROM public.compras
     WHERE id = v_compra_id AND sucursal_id = v_sucursal AND estado <> 'cancelada'
       FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'La compra % de este lote está cancelada: no se le puede generar una nota de crédito', v_compra_id;
    END IF;
  END IF;

  -- #1471 (STK-F-1): el producto antes que el lote, el orden de la venta
  -- (#1255, como dar_de_baja_lote y ajustar_lote), y las líneas de la compra
  -- entre los dos, como registrar_nota_credito y actualizar_compra_items. Se
  -- tomaba el lote primero, y contra una venta con la bolsa en 0 (que baja a
  -- ese lote con el producto ya tomado) daba 40P01. El lote se vuelve a leer
  -- abajo, ya bloqueado, y se compara contra lo leído sin lock.
  IF v_producto_id IS NOT NULL THEN
    PERFORM 1 FROM public.productos
     WHERE id = v_producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;
    IF v_compra_id IS NOT NULL THEN
      PERFORM 1 FROM public.compra_items
       WHERE compra_id = v_compra_id
         AND producto_id = v_producto_id
         AND sucursal_id = v_sucursal
       ORDER BY id
         FOR UPDATE;
    END IF;
  END IF;

  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;

  -- Un lote manual es stock que ya estaba cuando se prendio la feature: no
  -- nacio de una factura, asi que no hay proveedor a quien acreditarle ni costo
  -- de compra del cual sacar el importe. Inventar cualquiera de los dos seria
  -- peor que no poder hacerlo.
  IF v_lote.compra_id IS NULL THEN
    RAISE EXCEPTION 'Este lote no tiene compra de origen: no se le puede generar una nota de crédito, sólo dar de baja';
  END IF;

  IF v_cant > v_lote.cantidad_restante THEN
    RAISE EXCEPTION 'El lote tiene % unidades: no se pueden devolver %',
      v_lote.cantidad_restante, v_cant;
  END IF;

  -- #1095: que la compra no esté cancelada ya se chequeó arriba, con la
  -- compra tomada. Falta que el lote siga siendo de esa compra:
  -- cambiar_proveedor_compra reapunta los lotes al clon, y si lo hizo entre la
  -- lectura sin lock y el lock del lote, la nota iría contra la compra
  -- equivocada.
  IF v_lote.compra_id IS DISTINCT FROM v_compra_id
     OR v_lote.producto_id IS DISTINCT FROM v_producto_id THEN
    RAISE EXCEPTION 'El lote cambió de compra mientras se registraba la nota: reintentá';
  END IF;

  -- El FOR UPDATE sobre las lineas de la compra es lo que SERIALIZA contra la
  -- otra puerta: dos notas simultaneas sobre la misma compra -- una por lote y
  -- una por factura entera -- leerian el mismo "ya acreditado" y acreditarian
  -- el doble. Es el mismo candado que la mig 236 le puso a
  -- `registrar_nota_credito`, y por eso las dos puertas se ven entre si.
  PERFORM 1 FROM public.compra_items
   WHERE compra_id = v_lote.compra_id
     AND producto_id = v_lote.producto_id
     AND sucursal_id = v_sucursal
   ORDER BY id
     FOR UPDATE;

  -- El costo sale de la factura de origen, que es la misma lectura que hace
  -- `ModalNotaCredito` para una compra entera: el costo neto de la bonificacion
  -- (#1471), y el IVA por la alicuota que tenia CADA linea (mig 177),
  -- no un 21% fijo. Contra una factura mixta, acreditar 21% sobre una linea
  -- exenta inventa credito fiscal que el proveedor nunca facturo.
  --
  -- La misma factura puede traer el mismo producto en dos renglones con costos
  -- distintos, y `producto_lotes` habla de producto y fecha, no de renglon: no
  -- hay forma de saber de cual salio. El promedio ponderado de esos renglones
  -- es la respuesta honesta, y es la misma plata cuando hay un solo renglon
  -- (el caso normal). Los COALESCE espejan los defaults del front:
  -- `porcentaje_iva ?? 21` para las lineas previas a la mig 113.
  --
  -- #1471 (STK-F-3): el costo es el NETO, con la bonificación de cada renglón.
  -- Se tomaba `costo_unitario` bruto y un regalo al 100 % se acreditaba a precio
  -- lleno. La alícuota se pondera por el neto. Es la misma cuenta que
  -- registrar_nota_credito y que `notaCredito.ts`.
  SELECT SUM(ci.cantidad)::integer,
         SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100))
           / NULLIF(SUM(ci.cantidad), 0),
         COALESCE(
           SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)
               * CASE WHEN ci.condicion_iva = 'gravado'
                      THEN COALESCE(ci.porcentaje_iva, 21) ELSE 0 END)
             / NULLIF(SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)), 0),
           0)
    INTO v_comprado, v_costo, v_tasa_iva
    FROM public.compra_items ci
   WHERE ci.compra_id = v_lote.compra_id
     AND ci.producto_id = v_lote.producto_id
     AND ci.sucursal_id = v_sucursal;

  IF v_comprado IS NULL THEN
    RAISE EXCEPTION 'La compra % ya no tiene ninguna línea de este producto: no se puede resolver el costo de la nota de crédito',
      v_lote.compra_id;
  END IF;

  -- El tope de lo acreditable es el mismo que el de la factura entera: no se
  -- puede acreditar mas unidades de las que se compraron. Sin esto, acreditar
  -- la compra completa por un lado y el lote por el otro acreditaria el doble.
  -- (Desde #1079 la nota por factura entera tambien baja los lotes de la
  -- compra, pero solo lo que les queda vivo; lo demas sale de la bolsa. El
  -- tope que cierra la segunda vuelta sigue siendo este.)
  SELECT COALESCE(SUM(nci.cantidad), 0)::integer INTO v_acreditado
    FROM public.nota_credito_items nci
    JOIN public.notas_credito nc
      ON nc.id = nci.nota_credito_id AND nc.sucursal_id = nci.sucursal_id
   WHERE nc.compra_id = v_lote.compra_id
     AND nc.sucursal_id = v_sucursal
     AND nci.producto_id = v_lote.producto_id;

  IF v_cant > v_comprado - v_acreditado THEN
    RAISE EXCEPTION 'La compra trajo % unidades de este producto y ya se acreditaron %: no se pueden acreditar %',
      v_comprado, v_acreditado, v_cant;
  END IF;

  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_stock IS NULL THEN
    RAISE EXCEPTION 'El producto % no existe en esta sucursal', v_lote.producto_id;
  END IF;
  IF v_stock < v_cant THEN
    RAISE EXCEPTION 'El stock del producto es % y la devolución es de %: dejaría stock negativo',
      v_stock, v_cant;
  END IF;

  v_subtotal := round(v_cant * v_costo, 2);
  v_iva      := round(v_subtotal * v_tasa_iva / 100, 2);
  -- mig 280 (#867): el II de lo devuelto, con el mismo reparto que la nota
  -- por factura entera (ii_nota_credito_compra).
  v_ii       := public.ii_nota_credito_compra(v_lote.compra_id, v_sucursal,
                  jsonb_build_array(jsonb_build_object('producto_id', v_lote.producto_id, 'cantidad', v_cant)));

  -- `fecha` en hora argentina y no CURRENT_DATE: la base corre en UTC y despues
  -- de las 21:00 ART el default fecharia la nota al dia siguiente (mig 182). No
  -- se toca el default de la tabla ni la RPC de compras: fuera de alcance.
  INSERT INTO public.notas_credito (
    compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id,
    impuestos_internos, tipo
  ) VALUES (
    v_lote.compra_id,
    NULLIF(btrim(COALESCE(p_numero_nota, '')), ''),
    (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
    v_subtotal, v_iva, v_subtotal + v_iva + v_ii,
    COALESCE(NULLIF(btrim(COALESCE(p_motivo, '')), ''),
             'Devolución al proveedor del lote vencido el '
               || to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY')),
    auth.uid(), v_sucursal,
    v_ii, 'devolucion'
  )
  RETURNING id INTO v_nota_id;

  INSERT INTO public.nota_credito_items (
    nota_credito_id, producto_id, cantidad, costo_unitario, subtotal,
    stock_anterior, stock_nuevo, sucursal_id
  ) VALUES (
    v_nota_id, v_lote.producto_id, v_cant, round(v_costo, 4), v_subtotal,
    v_stock, GREATEST(v_stock - v_cant, 0), v_sucursal
  );

  -- 1) el lote. ANTES del stock: ver el encabezado.
  UPDATE public.producto_lotes
     SET cantidad_restante = cantidad_restante - v_cant
   WHERE id = p_lote_id;

  -- 2) el stock, etiquetado para el ledger. La referencia apunta a la NOTA y no
  --    al lote: la nota es el comprobante, y desde ella se llega al lote por la
  --    compra. `registrar_nota_credito` no etiqueta nada y sus bajas entran como
  --    'auto'; esta puerta no repite ese hueco.
  PERFORM set_config('app.stock_origen',   'lote_devuelto_proveedor', true);
  PERFORM set_config('app.stock_ref_tipo', 'notas_credito',           true);
  PERFORM set_config('app.stock_ref_id',   v_nota_id::text,           true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text,          true);

  UPDATE public.productos
     SET stock = stock - v_cant,
         updated_at = now()
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal;

  -- 3) mig 483 (STK-4, #1516; decisión del dueño, 10/11): el promedio, como una
  --    anulación parcial de la compra, igual que la nota por factura entera.
  --    `v_acreditado` es lo que ya devolvieron las notas anteriores.
  v_aviso := public._cpp_devolucion_compra(v_lote.compra_id, v_lote.producto_id, v_sucursal,
                                           v_acreditado, v_cant);

  RETURN jsonb_build_object(
    'ok',                true,
    'warnings',          CASE WHEN v_aviso IS NOT NULL THEN jsonb_build_array(jsonb_build_object(
                           'producto_id', v_lote.producto_id, 'motivo', v_aviso,
                           'warning', 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo')) END,
    'lote_id',           p_lote_id,
    'nota_credito_id',   v_nota_id,
    'compra_id',         v_lote.compra_id,
    'cantidad',          v_cant,
    'cantidad_restante', v_lote.cantidad_restante - v_cant,
    'stock',             v_stock - v_cant,
    'costo_unitario',    round(v_costo, 2),
    'subtotal',          v_subtotal,
    'iva',               v_iva,
    'impuestos_internos', v_ii,
    'total',             v_subtotal + v_iva + v_ii
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5 · STK-10 · la merma por vencimiento sale del lote vencido
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_merma_manual(p_producto_id bigint, p_cantidad integer, p_motivo text, p_observaciones text DEFAULT NULL::text, p_sucursal_id bigint DEFAULT NULL::bigint, p_cargos jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
  v_obs      text;
  v_stock    integer;
  v_merma    public.mermas_stock%ROWTYPE;
  v_nombre   text;
  v_cargos   bigint[] := '{}';
  v_resta    integer;  -- mig 483
  v_lote     record;   -- mig 483
  v_toma     integer;  -- mig 483
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- p_sucursal_id NO elige la sucursal: la elige current_sucursal_id(), que
  -- valida la membresia contra usuario_sucursales. El parametro esta para que
  -- el replay offline -- que reenvia una merma cargada en otra sucursal --
  -- choque con un error claro en vez de escribir en la sucursal equivocada.
  IF p_sucursal_id IS NOT NULL AND p_sucursal_id <> v_sucursal THEN
    RAISE EXCEPTION 'La merma es de la sucursal % y la sesion esta en la %: cambia de sucursal y reintenta',
      p_sucursal_id, v_sucursal;
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol <> 'admin' THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad a dar de baja tiene que ser mayor a 0';
  END IF;

  IF p_motivo IS NULL OR p_motivo NOT IN ('rotura', 'vencimiento', 'robo', 'decomiso',
                                          'devolucion', 'error_inventario', 'muestra', 'otro') THEN
    RAISE EXCEPTION 'Motivo de merma invalido: %', COALESCE(p_motivo, '(vacio)');
  END IF;

  v_obs := NULLIF(btrim(COALESCE(p_observaciones, '')), '');

  -- El FOR UPDATE es todo el arreglo: la segunda merma concurrente espera aca
  -- y lee el stock que dejo la primera, en vez de pisarla con su snapshot.
  SELECT stock, nombre INTO v_stock, v_nombre
    FROM public.productos
   WHERE id = p_producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_stock IS NULL THEN
    RAISE EXCEPTION 'El producto % no existe en esta sucursal', p_producto_id;
  END IF;

  IF v_stock < p_cantidad THEN
    RAISE EXCEPTION 'El stock del producto es % y la baja es de %: dejaria stock negativo',
      v_stock, p_cantidad;
  END IF;

  -- stock_anterior/stock_nuevo salen del valor LOCKEADO, no del cliente.
  -- stock_nuevo = GREATEST(stock_anterior - cantidad, 0) es el invariante
  -- MERMA-B; usuario_id nunca NULL es MERMA-I. El costo lo congela solo
  -- trg_mermas_snapshot_costo (mig 119).
  INSERT INTO public.mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    p_producto_id, p_cantidad, p_motivo, v_obs,
    v_stock, GREATEST(v_stock - p_cantidad, 0), auth.uid(), v_sucursal
  )
  RETURNING * INTO v_merma;

  /* mig 483 (STK-10, #1516) · LA MERMA POR VENCIMIENTO SALE DEL LOTE VENCIDO.
     La bajada del trigger come la bolsa primero: una merma por vencimiento
     sacaba unidades "sin vencimiento" y el lote vencido seguía contando las
     que ya se tiraron. Ahora sale primero de los lotes ya vencidos (vencen
     antes de hoy, el día argentino), el que venció antes primero, y ANTES del
     stock, como dar_de_baja_lote y la NC: con el lote ya descontado, el
     trigger ve la bolsa crecer en lo mismo y no toca otros lotes. Lo que los
     vencidos no cubren sigue el camino de siempre (la bolsa y después FEFO).
     Un lote que vence hoy todavía no está vencido. Los lotes se toman por id,
     con el producto ya tomado arriba (#1255). */
  IF p_motivo = 'vencimiento' THEN
    PERFORM 1 FROM public.producto_lotes
     WHERE producto_id = p_producto_id AND sucursal_id = v_sucursal
       AND NOT solo_traza AND cantidad_restante > 0
       AND fecha_vencimiento < public._tablero_hoy()
     ORDER BY id
       FOR UPDATE;
    v_resta := p_cantidad;
    FOR v_lote IN
      SELECT id, cantidad_restante FROM public.producto_lotes
       WHERE producto_id = p_producto_id AND sucursal_id = v_sucursal
         AND NOT solo_traza AND cantidad_restante > 0
         AND fecha_vencimiento < public._tablero_hoy()
       ORDER BY fecha_vencimiento, id
    LOOP
      EXIT WHEN v_resta <= 0;
      v_toma := LEAST(v_resta, v_lote.cantidad_restante);
      UPDATE public.producto_lotes SET cantidad_restante = cantidad_restante - v_toma WHERE id = v_lote.id;
      v_resta := v_resta - v_toma;
    END LOOP;
  END IF;

  -- Incremental, nunca absoluto, y etiquetado para el ledger.
  PERFORM set_config('app.stock_origen',   'merma',           true);
  PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',    true);
  PERFORM set_config('app.stock_ref_id',   v_merma.id::text,  true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text,  true);

  UPDATE public.productos
     SET stock = stock - p_cantidad,
         updated_at = now()
   WHERE id = p_producto_id AND sucursal_id = v_sucursal;

  -- gastos 7: el cargo a empleados, en la misma transaccion. Si falla, no hay
  -- merma. JSON null o [] es «sin cargo».
  IF p_cargos IS NOT NULL AND jsonb_typeof(p_cargos) <> 'null'
     AND NOT (jsonb_typeof(p_cargos) = 'array' AND jsonb_array_length(p_cargos) = 0) THEN
    v_cargos := public._cargar_roturas(p_cargos, v_sucursal, v_merma.id, NULL,
                                       'Rotura: ' || p_cantidad || ' u. de ' || COALESCE(v_nombre, 'producto #' || p_producto_id));
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'merma',  to_jsonb(v_merma),
    'stock',  v_stock - p_cantidad,
    'cargos', to_jsonb(v_cargos)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6 · Permisos: los helpers nuevos son de server (los llaman funciones
--     SECURITY DEFINER); las RPCs reemplazadas conservan firma y ACL.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._mov_lotes_devolver(bigint, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cpp_recorrer_compra_parcial(bigint, bigint, bigint, numeric, numeric, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cpp_devolucion_compra(bigint, bigint, bigint, integer, integer) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cancelar_movimiento_sucursal(bigint,text)', '0d68b9e39798caa063d75e79390ff7f8', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.denegar_movimiento_sucursal(bigint,text)', '29bc11bb7e656a14e9070129ff0d434d', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.editar_movimiento_sucursal(bigint,text,jsonb)', '34ca113ca444befe8da34b7cfa525c06', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', 'df2a42359ed44361dcf7ff3c993c1e1a', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)', '545ef1c0cabf4e71d1b1096fde53b49a', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_nota_credito_lote(bigint,numeric,text,text)', '6f8b92d6b3cb32ceb1bcc4267bf0e752', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_merma_manual(bigint,integer,text,text,bigint,jsonb)', '3d90ddd4b862e45794d613c8ae70a78a', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._mov_lotes_devolver(bigint,jsonb)', '83ef22b3b0143bf318ead07069ac916e', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._cpp_recorrer_compra_parcial(bigint,bigint,bigint,numeric,numeric,integer)', 'e4b2d0e7e2e2f182a1c2d811ab2a68c8', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._cpp_devolucion_compra(bigint,bigint,bigint,integer,integer)', 'c895b266e0b95b539c9e17bbf180d507', false,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig 483 · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
