-- 269 — Cancelar por falta de stock no repone unidades que no existen (#827)
--
-- El stock de un pedido sale al CREARLO ('pedido_creado'). `cancelar_pedido_con_stock`
-- (mig 242) lo devolvia SIEMPRE con 'pedido_cancelado', sin mirar `p_tipo`. Si el
-- pedido se cancela porque la mercaderia no existe fisicamente, esa devolucion
-- fabrica unidades fantasma: el contador sube N y en la gondola no hay nada. Caso
-- #6415: se repuso 1 unidad y alguien la mermo a mano 31 s despues (merma #1051).
-- Es el unico caso en prod, asi que no hay datos que reparar.
--
-- QUE CAMBIA
--
--   · Motivo nuevo `falta_stock` en `pedidos_motivo_cancelacion_tipo_check`.
--     Aplica cuando NINGUN producto del pedido tiene stock (o el pedido es de uno
--     solo). Si falta uno de varios, se entrega con salvedad `faltante_stock`
--     sobre ese renglon (ver abajo).
--   · Con `p_tipo = 'falta_stock'`, cada renglon que movio stock se devuelve Y se
--     merma en el mismo movimiento: el patron de la salvedad por dañado/vencido
--     (mig 234). Neto CERO sobre `productos.stock`, y una fila de `mermas_stock`
--     por producto con motivo `error_inventario`.
--   · Cualquier otro motivo: identico a la 242, byte a byte en lo que hace.
--
-- POR QUE DEVOLVER Y MERMAR, Y NO SIMPLEMENTE NO DEVOLVER
--
--   No devolver deja el contador bien, pero las N unidades desaparecen sin
--   asiento: no son venta (el pedido esta cancelado, total 0) ni merma. El costo
--   de lo que el sistema creia tener y no tenia no aparece en ningun reporte. Con
--   la merma queda en `mermas_valorizadas` (mig 238) --valorizada por la cascada
--   unica, `costo_valuacion`-- y en el ledger como 'merma' con referencia a su
--   fila de `mermas_stock`, igual que `registrar_merma_manual` (mig 232).
--
-- POR QUE `error_inventario` Y NO UN MOTIVO DE MERMA NUEVO
--
--   Es literalmente eso: el contador decia que habia y no habia. Y
--   `merma_clasificacion` ya lo clasifica 'ajuste' (la clase que pide el issue),
--   separado de 'perdida' (rotura/vencimiento/robo...), que es mercaderia que
--   existio. Un motivo nuevo obligaba a tocar `mermas_stock_motivo_check`, el
--   check MERMA-A de `auditoria_integridad()`, la lista de
--   `registrar_merma_manual` y las etiquetas del front, para clasificarlo igual.
--   La trazabilidad al pedido va en `observaciones` ("Cancelacion por falta de
--   stock, pedido #N"): `mermas_stock` no tiene columna de pedido, y agregarla es
--   otra decision.
--
-- LA DEVOLUCION QUE SE CANCELA SOLA NO VA ETIQUETADA (CLAUDE.md, migs 229/234)
--
--   La devolucion previa a la merma sale con 'pedido_cancelado_merma', que a
--   proposito NO esta en la lista blanca de `sincronizar_lotes_stock` (223). Con
--   'pedido_cancelado' la devolucion volveria al lote por FEFO, pero la bajada
--   de la merma sale de la BOLSA primero --el camino de bajada no mira el
--   origen--: el lote terminaria +N y la bolsa -N en cada cancelacion, el
--   contador por lote mintiendo para arriba. Con el origen propio las dos patas
--   caen en la bolsa y lote y bolsa quedan exactamente como estaban antes de
--   cancelar. Lo mide el ensayo.
--
--   Y si la unidad fantasma habia salido de un lote al crear el pedido, ahi se
--   queda: el lote habia contado una unidad que no estaba, y el alta ya lo
--   corrigio. Devolverla al lote seria volver a inventarla.
--
-- `set_config` ES POR TRANSACCION (mig 229)
--
--   El bloque de la merma cambia las cuatro etiquetas dos veces
--   ('pedido_cancelado_merma', despues 'merma' con ref a `mermas_stock`) y al
--   final restaura las de la cancelacion, para que `revertir_bloques_auto_ajuste`
--   --que guarda y restaura por su cuenta-- y cualquier movimiento posterior del
--   mismo caller (p.ej. `cambiar_cliente_pedido`) sigan viendo 'pedido_cancelado'.
--
-- LOS CONTENEDORES DE REGALO NO CAMBIAN
--
--   `revertir_bloques_auto_ajuste` se llama igual que hoy para todo motivo: el
--   fardo del regalo vuelve al contenedor. Eso es una promo que deja de estar
--   comprometida, no mercaderia del pedido.
--
-- STK-F: la funcion sube stock y menciona `app.stock_origen` (como antes).
-- COSTO-D: no escribe `pedido_items.costo_unitario_al_crear`. El costo de la
-- merma lo congela `trg_mermas_snapshot_costo` (mig 119), como en toda merma.
-- MERMA-B: `stock_anterior` se lee DESPUES de la devolucion (FOR UPDATE) y
-- `stock_nuevo = GREATEST(stock_anterior - cantidad, 0)`. MERMA-I: el usuario es
-- el admin autenticado, nunca NULL (la funcion lo exige).
--
-- EL FALTANTE PARCIAL YA ESTABA BIEN (revisado, no se toca)
--
--   La salvedad `faltante_stock` existe y `registrar_salvedad` no la devuelve
--   (`stock_devuelto` solo se prende para cliente_rechaza / error_pedido /
--   diferencia_precio) ni la merma: la unidad que salio al crear el pedido se
--   queda afuera, que es lo correcto. `anular_salvedad` tampoco mueve stock para
--   ella. No se agrega motivo de salvedad nuevo.
--
-- Misma firma que la 242 => CREATE OR REPLACE conserva los GRANT/REVOKE vigentes.
-- No hay sobrecarga nueva (PGRST203).

ALTER TABLE public.pedidos
  DROP CONSTRAINT IF EXISTS pedidos_motivo_cancelacion_tipo_check;

ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_motivo_cancelacion_tipo_check
  CHECK (motivo_cancelacion_tipo IS NULL OR motivo_cancelacion_tipo::text = ANY (ARRAY[
    'cerrado', 'sin_dinero', 'cliente_rechaza', 'ausente', 'direccion_incorrecta',
    'clima', 'cliente_cancelo', 'error_de_carga', 'duplicado', 'unifica_pedidos',
    'prueba', 'cambio_de_cliente', 'otro',
    'falta_stock'
  ]::text[]));

CREATE OR REPLACE FUNCTION public.cancelar_pedido_con_stock(p_pedido_id bigint, p_motivo text, p_usuario_id uuid DEFAULT NULL::uuid, p_tipo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido RECORD;
  v_item RECORD;
  v_total_original DECIMAL;
  v_user_role TEXT;
  v_acting_user uuid;
  v_quitar jsonb;
  v_promo_rev RECORD;
  -- mig 269 (#827)
  v_falta_stock BOOLEAN := (p_tipo = 'falta_stock');
  v_merma RECORD;
  v_stock_actual INTEGER;
  v_merma_id BIGINT;
  v_mermas INTEGER := 0;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_acting_user := auth.uid();
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM v_acting_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_acting_user;
  IF v_user_role IS NULL OR v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cancelar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya esta cancelado');
  END IF;

  IF v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;

  v_total_original := v_pedido.total;

  -- mig 229: el trigger de lotes (223) solo devuelve al lote FEFO si el
  -- origen esta en su lista blanca. Sin estas cuatro lineas la cancelacion
  -- subia el stock con origen 'auto' y las unidades volvian a la bolsa "sin
  -- vencimiento" en vez de a su lote: el contador mentia para abajo.
  PERFORM set_config('app.stock_origen', 'pedido_cancelado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', COALESCE(v_acting_user::TEXT, ''), true);

  IF NOT v_falta_stock THEN
    FOR v_item IN
      SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF v_item.es_bonificacion THEN
        IF v_item.regalo_mueve_stock THEN
          UPDATE productos SET stock = stock + v_item.cantidad
          WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
        END IF;
      ELSE
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    END LOOP;
  ELSE
    /* mig 269 (#827): la mercaderia no existe fisicamente. Se devuelve y se
       merma en el mismo movimiento (patron de la salvedad por vencido, 234):
       neto cero sobre productos.stock y una fila de mermas_stock por producto.

       La devolucion lleva 'pedido_cancelado_merma', FUERA de la lista blanca
       de sincronizar_lotes_stock: con 'pedido_cancelado' volveria al lote por
       FEFO y la bajada de la merma saldria de la bolsa, dejando lote +N y
       bolsa -N. Con este origen las dos patas caen en la bolsa y lote y bolsa
       quedan como estaban.

       Mismo criterio que el loop de arriba para saber que movio stock: el
       regalo de una promo con regalo_mueve_stock = false nunca lo toco, asi
       que ni se devuelve ni se merma. Agrupado por producto: dos renglones del
       mismo producto son una sola merma. */
    FOR v_merma IN
      SELECT pi.producto_id, SUM(pi.cantidad)::INT AS cantidad
        FROM pedido_items pi
        LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND (NOT COALESCE(pi.es_bonificacion, false) OR COALESCE(pr.regalo_mueve_stock, FALSE))
       GROUP BY pi.producto_id
      HAVING SUM(pi.cantidad) > 0
       ORDER BY pi.producto_id
    LOOP
      PERFORM set_config('app.stock_origen',   'pedido_cancelado_merma', true);
      PERFORM set_config('app.stock_ref_tipo', 'pedido',                 true);
      PERFORM set_config('app.stock_ref_id',   p_pedido_id::TEXT,        true);

      UPDATE productos SET stock = stock + v_merma.cantidad
       WHERE id = v_merma.producto_id AND sucursal_id = v_sucursal;

      SELECT stock INTO v_stock_actual
        FROM productos
       WHERE id = v_merma.producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;

      INSERT INTO mermas_stock (
        producto_id, cantidad, motivo, observaciones,
        stock_anterior, stock_nuevo, usuario_id, sucursal_id
      ) VALUES (
        v_merma.producto_id, v_merma.cantidad, 'error_inventario',
        'Cancelacion por falta de stock, pedido #' || p_pedido_id
          || COALESCE(' -- ' || NULLIF(btrim(p_motivo), ''), ''),
        v_stock_actual, GREATEST(v_stock_actual - v_merma.cantidad, 0),
        v_acting_user, v_sucursal
      ) RETURNING id INTO v_merma_id;

      -- La bajada es una merma: el ledger lo dice y apunta a su fila, igual
      -- que registrar_merma_manual (mig 232). Resta exacta, sin GREATEST: es la
      -- inversa de la suma de arriba y el neto tiene que dar cero.
      PERFORM set_config('app.stock_origen',   'merma',          true);
      PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',   true);
      PERFORM set_config('app.stock_ref_id',   v_merma_id::TEXT, true);

      UPDATE productos SET stock = stock - v_merma.cantidad
       WHERE id = v_merma.producto_id AND sucursal_id = v_sucursal;

      v_mermas := v_mermas + 1;
    END LOOP;

    -- set_config es por TRANSACCION (mig 229): se restauran las etiquetas de la
    -- cancelacion para lo que sigue (contenedores, y el caller si lo hubiera).
    PERFORM set_config('app.stock_origen',   'pedido_cancelado', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido',           true);
    PERFORM set_config('app.stock_ref_id',   p_pedido_id::TEXT,  true);
  END IF;

  -- mig 235: el fardo del regalo vuelve al contenedor. Aca habia un
  -- GREATEST(usos_pendientes - cantidad, 0) a mano, adentro del loop: el clamp
  -- se comia el negativo, asi que el bloque que se mermo al completarse no
  -- volvia NUNCA. Los otros tres caminos que devuelven regalos
  -- --actualizar_pedido_items, eliminar_pedido_completo, registrar_salvedad--
  -- ya llamaban a revertir_bloques_auto_ajuste; este no.
  --
  -- Agrupado por promocion Y CONTENEDOR: dos renglones de la misma promo con
  -- sabores distintos salieron de fardos distintos, asi que son dos deltas y
  -- dejan un promo_ajustes cada uno. El contenedor se deriva por item con la
  -- misma formula del alta (mig 096/132).
  --
  -- El helper guarda y restaura los cuatro GUCs de app.stock_* alrededor de su
  -- UPDATE (mig 229), asi que el 'pedido_cancelado' de arriba sigue valiendo
  -- para el resto del cuerpo.
  --
  -- mig 269: igual para todo motivo, 'falta_stock' incluido.
  FOR v_promo_rev IN
    SELECT pi.promocion_id AS promocion_id,
           CASE WHEN pr.producto_regalo_id IS DISTINCT FROM pi.producto_id
                THEN pi.producto_id ELSE pr.ajuste_producto_id END AS contenedor_id,
           SUM(pi.cantidad)::INT AS cantidad
      FROM pedido_items pi
      LEFT JOIN promociones pr
        ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
     GROUP BY 1, 2
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_promo_rev.promocion_id, v_promo_rev.cantidad, v_sucursal,
      v_acting_user, 'Cancelacion pedido #' || p_pedido_id,
      v_promo_rev.contenedor_id);
  END LOOP;

  -- mig 235: el cobro de un pedido cancelado no se evapora, queda como saldo
  -- a favor. Antes esto ponia monto_pagado = 0 y no tocaba `pagos`: el pago
  -- seguia imputado al pedido cancelado, no reducia ninguna boleta viva ni
  -- contaba como credito, y la plata desaparecia de la cuenta corriente del
  -- cliente sin que fallara nada. `pedido_id = NULL` es la representacion de
  -- saldo a favor que ya usan registrar_pago_cliente_fifo_impl y
  -- aplicar_credito_cliente, y la que CC-A cuenta como credito.
  --
  -- Caja cerrada: guard_pago_fecha_cerrada es BEFORE UPDATE OF fecha, monto, y
  -- esto no toca ninguna de las dos. Esta bien que no se dispare -- el monto,
  -- la fecha y la forma de pago no cambian, asi que la caja de ese dia cierra
  -- por el mismo numero. Lo unico que cambia es a que boleta se imputa.
  --
  -- La excepcion es cambiar_cliente_pedido, que cancela el viejo y DESPUES
  -- reapunta los pagos al nuevo para que el cobro viaje con la venta. Si se
  -- desimputara primero, ese UPDATE no encontraria nada y el cobro quedaria de
  -- credito en el cliente equivocado mientras el pedido nuevo figura impago.
  -- Mismo escape hatch por transaccion que app.omitir_minimo_pedido (205).
  IF COALESCE(current_setting('app.cancelacion_conserva_pagos', true), '') <> '1' THEN
    UPDATE pagos
       SET pedido_id = NULL,
           notas = TRIM(BOTH ' ' FROM COALESCE(notas, '') || ' [saldo a favor por cancelacion]')
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  END IF;

  UPDATE pedidos
  SET estado = 'cancelado',
      motivo_cancelacion = p_motivo,
      motivo_cancelacion_tipo = COALESCE(p_tipo, motivo_cancelacion_tipo),
      total = 0,
      monto_pagado = 0,
      total_neto = 0,
      total_iva = 0,
      -- mig 235: faltaba. total_real es la base del margen y del CMV: una venta
      -- cancelada que sigue declarando ingreso real infla el gerencial.
      total_real = 0,
      updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  -- mig 180: la parada de un pedido cancelado no es una parada. Sin esto
  -- quedaban 118 colgadas, 115 en rutas en curso: contaban en total_pedidos y
  -- el chofer las veia en el mapa sin poder sacarselas de encima.
  v_quitar := public.quitar_pedido_de_recorridos_activos(p_pedido_id);
  IF NOT COALESCE((v_quitar->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'No se pudo quitar el pedido de las rutas activas: %',
      COALESCE(v_quitar->>'error', 'error desconocido');
  END IF;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    p_pedido_id,
    v_acting_user,
    'estado',
    v_pedido.estado,
    'cancelado - Motivo: ' || COALESCE(p_motivo, 'Sin motivo') || ' | Total original: $' || v_total_original
      || CASE WHEN v_falta_stock THEN ' | Falta de stock: sin reponer, ' || v_mermas || ' merma(s)' ELSE '' END,
    v_sucursal
  );

  RETURN jsonb_build_object(
    'success', true,
    'mensaje', CASE WHEN v_falta_stock
                    THEN 'Pedido cancelado por falta de stock: la mercaderia no volvio al stock y se registro como merma'
                    ELSE 'Pedido cancelado, stock restaurado, saldo ajustado' END,
    'total_original', v_total_original,
    'stock_restaurado', NOT v_falta_stock,
    'mermas_registradas', v_mermas
  );
END;
$function$;

-- Verificacion: firma unica, el origen de la devolucion fuera de la lista blanca,
-- y la funcion sigue sin ser alcanzable con la anon key.
DO $verif$
DECLARE
  v_def text;
  v_n   int;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'cancelar_pedido_con_stock';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock tiene % firmas (se esperaba 1): riesgo PGRST203', v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'cancelar_pedido_con_stock';
  IF v_def NOT LIKE '%''pedido_cancelado_merma''%' OR v_def NOT LIKE '%app.stock_origen%' THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock perdio el origen propio de la devolucion previa a la merma';
  END IF;

  SELECT pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure) INTO v_def;
  IF v_def LIKE '%''pedido_cancelado_merma''%' THEN
    RAISE EXCEPTION 'pedido_cancelado_merma NO puede estar en la lista blanca de lotes: lote +N / bolsa -N';
  END IF;

  IF has_function_privilege('anon', 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock quedo alcanzable con la anon key';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- Ensayo con datos reales (se deshace solo: termina en una excepcion atrapada).
--
--   P1: stock 90 = lote 50 vivas + bolsa 40. Pedido de 10 -> sale de la bolsa
--       (bolsa 30, lote 50). Es el caso que muerde: con una devolucion
--       whitelisteada volveria al lote (lote 60) y la merma saldria de la bolsa
--       (bolsa 20) -- +10/-10 cruzado.
--   P2: stock 90 = lote 50 + bolsa 40. Pedido de 45 -> consume toda la bolsa y
--       5 del lote (lote 45, bolsa 0). La unidad fantasma que salio del lote
--       no vuelve.
--   P1 y P2 van en el MISMO pedido, cancelado con 'falta_stock': stock, lote y
--   bolsa tienen que quedar exactamente como despues del alta, con una merma
--   'error_inventario' por producto, clasificada 'ajuste' en mermas_valorizadas.
--   P3: control, mismo arranque, pedido de 10 cancelado con 'cerrado': el
--   comportamiento vigente, sin tocar. 'pedido_cancelado' esta en la lista
--   blanca, asi que las 10 vuelven al lote por FEFO (lote 60, bolsa 30) aunque
--   hubieran salido de la bolsa, y no hay merma. Es exactamente el lote +N
--   que P1 tendria si su devolucion fuera etiquetada.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_p       bigint[] := ARRAY[]::bigint[];
  v_prod    bigint;
  v_res     jsonb;
  v_ped_a   bigint;
  v_ped_b   bigint;
  v_log     jsonb := '{}'::jsonb;
  v_foto    jsonb;
  v_i       int;
  v_n       int;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens269 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens269 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  BEGIN
    FOR v_i IN 1..3 LOOP
      INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
      VALUES ('ZZ ensayo mig269 P' || v_i, 100, 90, 60, v_suc) RETURNING id INTO v_prod;
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
      VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);
      v_p := v_p || v_prod;
    END LOOP;

    -- Pedido A: P1 x10 + P2 x45. Pedido B: P3 x10.
    v_res := public.crear_pedido_completo(
      v_cliente, 5500, v_admin,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_p[1], 'cantidad', 10, 'precio_unitario', 100),
        jsonb_build_object('producto_id', v_p[2], 'cantidad', 45, 'precio_unitario', 100)),
      'ensayo mig269 A');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens269 · no se pudo crear el pedido A: %', v_res;
    END IF;
    v_ped_a := (v_res->>'pedido_id')::bigint;

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_p[3], 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo mig269 B');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens269 · no se pudo crear el pedido B: %', v_res;
    END IF;
    v_ped_b := (v_res->>'pedido_id')::bigint;

    SELECT jsonb_object_agg('P' || array_position(v_p, pr.id),
             jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = ANY(v_p);
    v_log := v_log || jsonb_build_object('post_alta', v_foto);

    IF v_foto <> '{"P1":{"stock":80,"lote":50,"bolsa":30},
                  "P2":{"stock":45,"lote":45,"bolsa":0},
                  "P3":{"stock":80,"lote":50,"bolsa":30}}'::jsonb THEN
      RAISE EXCEPTION 'ens269 · el alta no dejo el punto de partida esperado: %', v_foto;
    END IF;

    -- Cancelaciones.
    v_res := public.cancelar_pedido_con_stock(v_ped_a, 'Falta de stock — ensayo', v_admin, 'falta_stock');
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR (v_res->>'stock_restaurado')::boolean
       OR (v_res->>'mermas_registradas')::int <> 2 THEN
      RAISE EXCEPTION 'ens269 · cancelar A (falta_stock): %', v_res;
    END IF;
    v_log := v_log || jsonb_build_object('rpc_a', v_res);

    v_res := public.cancelar_pedido_con_stock(v_ped_b, 'Estaba cerrado — ensayo', v_admin, 'cerrado');
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR NOT (v_res->>'stock_restaurado')::boolean
       OR (v_res->>'mermas_registradas')::int <> 0 THEN
      RAISE EXCEPTION 'ens269 · cancelar B (cerrado): %', v_res;
    END IF;

    SELECT jsonb_object_agg('P' || array_position(v_p, pr.id),
             jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = ANY(v_p);
    v_log := v_log || jsonb_build_object('post_cancelacion', v_foto);

    -- P1/P2: exactamente como despues del alta (nada vuelve, nada se cruza).
    -- P3: la devolucion de siempre, al lote por FEFO (comportamiento vigente).
    IF v_foto <> '{"P1":{"stock":80,"lote":50,"bolsa":30},
                  "P2":{"stock":45,"lote":45,"bolsa":0},
                  "P3":{"stock":90,"lote":60,"bolsa":30}}'::jsonb THEN
      RAISE EXCEPTION 'ens269 · la cancelacion movio stock/lote/bolsa: %', v_foto;
    END IF;

    SELECT jsonb_agg(jsonb_build_object(
             'P', 'P' || array_position(v_p, mv.producto_id), 'cantidad', mv.cantidad,
             'motivo', mv.motivo, 'clasificacion', mv.clasificacion,
             'costo_total', mv.costo_total, 'stock_anterior', mv.stock_anterior,
             'stock_nuevo', mv.stock_nuevo) ORDER BY mv.producto_id)
      INTO v_foto
      FROM public.mermas_valorizadas(v_hoy - 1, v_hoy + 1, ARRAY[v_suc]) mv
     WHERE mv.producto_id = ANY(v_p);
    v_log := v_log || jsonb_build_object('mermas', v_foto);

    IF v_foto IS NULL OR jsonb_array_length(v_foto) <> 2
       OR v_foto->0->>'P' <> 'P1' OR (v_foto->0->>'cantidad')::int <> 10
       OR v_foto->1->>'P' <> 'P2' OR (v_foto->1->>'cantidad')::int <> 45
       OR v_foto->0->>'motivo' <> 'error_inventario'
       OR v_foto->0->>'clasificacion' <> 'ajuste'
       OR (v_foto->0->>'costo_total')::numeric <> 600
       OR (v_foto->0->>'stock_anterior')::int <> 90 OR (v_foto->0->>'stock_nuevo')::int <> 80 THEN
      RAISE EXCEPTION 'ens269 · las mermas no quedaron como se esperaba: %', v_foto;
    END IF;

    -- Ledger del pedido A: +N 'pedido_cancelado_merma' y -N 'merma' por
    -- producto, sin ningun 'pedido_cancelado'.
    SELECT jsonb_agg(jsonb_build_object('P', 'P' || array_position(v_p, sh.producto_id),
             'origen', sh.origen, 'dif', sh.diferencia) ORDER BY sh.id)
      INTO v_foto
      FROM stock_historico sh
     WHERE sh.producto_id = ANY(v_p[1:2]) AND sh.origen <> 'pedido_creado';
    v_log := v_log || jsonb_build_object('ledger_a', v_foto);

    SELECT count(*) INTO v_n FROM stock_historico sh
     WHERE sh.producto_id = ANY(v_p[1:2]) AND sh.origen = 'pedido_cancelado';
    IF v_n <> 0 THEN
      RAISE EXCEPTION 'ens269 · el pedido A dejo % movimientos pedido_cancelado', v_n;
    END IF;

    SELECT motivo_cancelacion_tipo INTO v_res FROM (SELECT to_jsonb(motivo_cancelacion_tipo) AS motivo_cancelacion_tipo FROM pedidos WHERE id = v_ped_a) x;
    IF v_res <> '"falta_stock"'::jsonb THEN
      RAISE EXCEPTION 'ens269 · el pedido A no quedo con motivo falta_stock: %', v_res;
    END IF;

    RAISE EXCEPTION 'ens269-ok %', v_log USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM NOT LIKE 'ens269-ok%' THEN RAISE; END IF;
    RAISE NOTICE '%', SQLERRM;
  END;
END
$ensayo$;
