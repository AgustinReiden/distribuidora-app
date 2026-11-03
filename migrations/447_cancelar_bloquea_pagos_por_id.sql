-- 447 · La cancelación bloquea los pagos de la boleta por id, como la foto (#1423).
--
-- QUÉ PASABA
--   cancelar_pedido_con_stock desimputa los pagos con un UPDATE ... WHERE pedido_id = ...,
--   que los toma en el orden de idx_pagos_pedido_id: para la misma clave, por la posición
--   física de cada entrada. Si un pago ya se editó y su versión nueva no fue HOT, su entrada
--   queda detrás de la de un pago más nuevo, y la cancelación los toma al revés que
--   _rendicion_tomar_foto (los pagos del día, ORDER BY id FOR SHARE). Contra la confirmación
--   de la rendición de ese día daba 40P01 (C6h del arnés, 3 de 100). No rompía datos.
--
-- QUÉ CAMBIA (sólo el orden de los locks)
--   Antes del UPDATE, los mismos pagos (el mismo filtro) se bloquean por id: el orden de la
--   foto y de la 439. La cancelación sigue tomando primero el pedido y los productos, y
--   después los pagos, como ya lo hacía el UPDATE.
--   · Va adentro del IF de app.cancelacion_conserva_pagos. Con '1', que sólo lo pone
--     cambiar_cliente_pedido con 'pedido_nuevo', la cancelación no toca los pagos, y
--     cambiar_cliente_pedido los bloquea por id antes de su propio UPDATE (439).
--   · FOR NO KEY UPDATE, el lock que ya toma el UPDATE: ni pedido_id ni notas están en un
--     índice único que pueda usar una FK (pagos tiene sólo el pkey y el único parcial de
--     client_request_id). Así cambia el orden y nada más: no hay subida de lock después y no
--     se suma ningún conflicto. FOR UPDATE sumaría uno contra FOR KEY SHARE, que hoy nadie
--     toma sobre pagos porque ninguna FK apunta a pagos (pago_origen_id y
--     rendicion_pagos_confirmados.pago_id no son FKs, y pago_padre_id, de #1359, tampoco).
--
-- QUÉ NO CAMBIA
--   Qué pagos se desimputan y cómo, el stock, los lotes, la firma, el EXECUTE y el resto del
--   cuerpo.
--
-- Ensayo: scripts/test-cancelar-pagos-por-id-1423.sql, y C6g y C6h del arnés
-- (scripts/concurrencia, #1422). Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $premisa$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure)
     <> 'c54ad2e0b35652a8ec399239f43ed791' THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
      (SELECT md5(prosrc) FROM pg_proc
        WHERE oid = 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);
  END IF;
END
$premisa$;

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
  v_falta_stock BOOLEAN := COALESCE(p_tipo = 'falta_stock', false);  -- mig 274: NULL no es falta de stock
  v_merma RECORD;
  v_stock_actual INTEGER;
  v_merma_id BIGINT;
  v_mermas INTEGER := 0;
  v_contenedor_faltante BOOLEAN;
  v_stock_antes INTEGER;
  v_fardo INTEGER;
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

  -- mig 276 (#833): el pedido de una NC vigente no se cancela.
  IF public.nota_credito_vigente_de_pedido(p_pedido_id) IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido tiene la nota de crédito #' || public.nota_credito_vigente_de_pedido(p_pedido_id)
      || ' vigente: anulala primero');
  END IF;

  IF v_pedido.estado = 'entregado' AND COALESCE(v_pedido.tipo_factura, 'ZZ') <> 'VB' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;

  -- mig 3XA (N9): el vale blanco entregado si se cancela (arriba), salvo que
  -- figure en la rendicion de un transportista con la caja de ese dia cerrada.
  IF v_pedido.estado = 'entregado'
     AND v_pedido.transportista_id IS NOT NULL
     AND v_pedido.fecha_entrega IS NOT NULL
     AND (v_pedido.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
           <= public.ultima_fecha_caja_cerrada(v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este vale blanco figura en la rendicion del ' || to_char((v_pedido.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, 'DD/MM/YYYY')
      || ' de su transportista y esa caja esta cerrada: cancelarlo la reabriria.');
  END IF;

  -- mig 3XA: un vale blanco con salvedades vivas no se cancela. La salvedad ya
  -- devolvio k unidades y dejo la linea en N-k; la cancelacion devuelve N-k.
  -- Si despues se anula la salvedad (anular_salvedad no mira el estado del
  -- pedido), la linea vuelve a N, el stock baja k sin que haya salido nada y
  -- el cancelado queda con total > 0 (VENTA-I en rojo). Antes no pasaba porque
  -- un entregado no se podia cancelar.
  IF COALESCE(v_pedido.tipo_factura, 'ZZ') = 'VB'
     AND EXISTS (SELECT 1 FROM salvedades_items
                  WHERE pedido_id = p_pedido_id AND estado_resolucion IS DISTINCT FROM 'anulada') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este vale blanco tiene salvedades: anulalas antes de cancelar el vale');
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

  -- #1296 · Los productos del pedido, en orden de id, todos antes de mover
  -- el primero: el orden de la venta. El loop de abajo los tomaba en el orden
  -- de las líneas, y una cancelación [B, A] contra una venta [A, B] se
  -- trababan (40P01, y la mutation no reintenta). Cubre las dos ramas, la
  -- devolución y la merma por falta de stock; los contenedores que mueve el
  -- motor de promos más abajo también entran acá (#1375).
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.producto_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                 UNION
                 SELECT c FROM public._contenedores_de_promos(
                   ARRAY(SELECT pi.promocion_id FROM pedido_items pi
                          WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                            AND pi.promocion_id IS NOT NULL), v_sucursal) c)
    ORDER BY id
      FOR UPDATE;

  IF NOT v_falta_stock THEN
    FOR v_item IN
      SELECT pi.id, pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id,
             -- #1324: el modo de la foto del pedido.
             COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF NOT v_item.es_bonificacion OR v_item.regalo_mueve_stock THEN
        -- #1085: la devolucion de ESTA linea, con su huella. Con la del pedido,
        -- la primera linea de un producto se comia la huella de las demas y
        -- esas caian por FEFO a cualquier lote. Por transaccion (229).
        DECLARE
          v_item_guc TEXT := current_setting('app.stock_pedido_item_id', true);
        BEGIN
          PERFORM set_config('app.stock_pedido_item_id', v_item.id::text, true);
          UPDATE productos SET stock = stock + v_item.cantidad
          WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
          PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
        END;
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
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND (NOT COALESCE(pi.es_bonificacion, false)
              OR COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE))
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

    -- #1127 (decision del dueño 2026-10-13): la misma regla que la merma de
    -- registrar_salvedad. Estas unidades se devolvieron y mermaron con
    -- 'pedido_cancelado_merma', fuera de la lista blanca: no vuelven a ningun
    -- lote y el contador no se mueve, pero el cliente no tiene nada de este
    -- pedido. Sin esto el cancelado quedaba con toda su huella y, en un retiro
    -- de lote, el cliente figuraba con unidades que nunca recibio. Se cancela
    -- entero, asi que no hace falta FEFO: se borra la huella de todas sus
    -- lineas, simetrico con la cancelacion normal, que la deja en 0 por la
    -- pasada 1 de _restaurar_lotes_fefo. Orden de locks: pedido, productos (la
    -- merma de arriba), huella.
    DELETE FROM pedido_item_lotes pil
     USING pedido_items pi
     WHERE pi.id = pil.pedido_item_id
       AND pi.sucursal_id = pil.sucursal_id
       AND pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal;

    -- set_config es por TRANSACCION (mig 229): se restauran las etiquetas de la
    -- cancelacion para lo que sigue (contenedores, y el caller si lo hubiera).
    PERFORM set_config('app.stock_origen',   'pedido_cancelado', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido',           true);
    PERFORM set_config('app.stock_ref_id',   p_pedido_id::TEXT,  true);
  END IF;

  -- mig 235: el fardo del regalo vuelve al contenedor. Aca habia un
  -- GREATEST(usos_pendientes - cantidad, 0) a mano: el clamp se comia el
  -- negativo y el bloque que se mermo al completarse no volvia NUNCA.
  --
  -- mig 294 (#840): por (promo, SABOR), contra la barra de ese sabor y con el
  -- mismo motor que el alta. Si las botellas que vuelven deshacen un bloque
  -- de ese sabor, el fardo vuelve al contenedor de esa barra.
  --
  -- El motor guarda y restaura los cuatro GUCs de app.stock_* alrededor de su
  -- UPDATE (mig 229), asi que el 'pedido_cancelado' de arriba sigue valiendo
  -- para el resto del cuerpo.
  --
  -- mig 269: se llama para todo motivo. Con 'falta_stock', si el contenedor es
  -- un producto del pedido (todos faltaron, por definicion del motivo), el
  -- fardo que repone el motor tampoco existia: vuelve con un origen fuera de
  -- la lista blanca (app.contenedor_origen) y se merma enseguida. El
  -- contenedor de la barra: el de la promo para el sabor default, el de la
  -- fila (o el propio sabor, si todavia no tiene) para los demas.
  FOR v_promo_rev IN
    SELECT pi.promocion_id AS promocion_id,
           pi.producto_id  AS producto_id,
           CASE WHEN pr.producto_regalo_id = pi.producto_id THEN pr.ajuste_producto_id
                ELSE COALESCE(pa.ajuste_producto_id, pi.producto_id) END AS contenedor_id,
           SUM(pi.cantidad)::INT AS cantidad
      FROM pedido_items pi
      LEFT JOIN promociones pr
        ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      LEFT JOIN promo_acumuladores pa
        ON pa.promocion_id = pi.promocion_id AND pa.producto_regalo_id = pi.producto_id
       AND pa.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
       -- #1324: una linea de otro modo no entro en la barra de la promo viva, y
       -- deshacerla devolveria un fardo que nunca salio.
       AND public._regalo_barra_vale(p_pedido_id, pi.promocion_id, v_sucursal)
     GROUP BY 1, 2, 3
     ORDER BY 1, 2
  LOOP
    v_contenedor_faltante := v_falta_stock
      AND v_promo_rev.contenedor_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM pedido_items pi
                   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                     AND pi.producto_id = v_promo_rev.contenedor_id);

    IF v_contenedor_faltante THEN
      SELECT stock INTO v_stock_antes
        FROM productos
       WHERE id = v_promo_rev.contenedor_id AND sucursal_id = v_sucursal
       FOR UPDATE;
      PERFORM set_config('app.contenedor_origen', 'pedido_cancelado_merma', true);
    END IF;

    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo_rev.promocion_id, v_promo_rev.producto_id, -v_promo_rev.cantidad,
      v_promo_rev.producto_id, v_sucursal, v_acting_user,
      'Cancelacion pedido #' || p_pedido_id);

    IF v_contenedor_faltante THEN
      -- Por transaccion: si no se limpia ya, cualquier otra reposicion de
      -- contenedor de este mismo caller saldria sin volver al lote.
      PERFORM set_config('app.contenedor_origen', '', true);

      SELECT stock INTO v_stock_actual
        FROM productos
       WHERE id = v_promo_rev.contenedor_id AND sucursal_id = v_sucursal
       FOR UPDATE;
      v_fardo := COALESCE(v_stock_actual, 0) - COALESCE(v_stock_antes, 0);

      -- 0 si el motor no deshizo ningun bloque (la barra del sabor lo absorbio).
      IF v_fardo > 0 THEN
        INSERT INTO mermas_stock (
          producto_id, cantidad, motivo, observaciones,
          stock_anterior, stock_nuevo, usuario_id, sucursal_id
        ) VALUES (
          v_promo_rev.contenedor_id, v_fardo, 'error_inventario',
          'Cancelacion por falta de stock, pedido #' || p_pedido_id
            || ': fardo de promo #' || v_promo_rev.promocion_id || ' que no existia',
          v_stock_actual, GREATEST(v_stock_actual - v_fardo, 0),
          v_acting_user, v_sucursal
        ) RETURNING id INTO v_merma_id;

        PERFORM set_config('app.stock_origen',   'merma',          true);
        PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',   true);
        PERFORM set_config('app.stock_ref_id',   v_merma_id::TEXT, true);

        UPDATE productos SET stock = stock - v_fardo
         WHERE id = v_promo_rev.contenedor_id AND sucursal_id = v_sucursal;

        PERFORM set_config('app.stock_origen',   'pedido_cancelado', true);
        PERFORM set_config('app.stock_ref_tipo', 'pedido',           true);
        PERFORM set_config('app.stock_ref_id',   p_pedido_id::TEXT,  true);

        v_mermas := v_mermas + 1;
      END IF;
    END IF;
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
    -- #1423: por id, como la foto de la rendicion (439). El UPDATE solo los toma
    -- en el orden del indice, y un pago editado fuera de su pagina queda detras
    -- de los mas nuevos. NO KEY UPDATE es el lock que ya toma el UPDATE: ni
    -- pedido_id ni notas son clave de una FK, y ninguna FK apunta a pagos.
    PERFORM 1
       FROM pagos
      WHERE pedido_id = p_pedido_id
        AND sucursal_id = v_sucursal
      ORDER BY id
        FOR NO KEY UPDATE;

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
      cargo_envio = 0,
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

-- El cuerpo que quedó es el del repo, y CREATE OR REPLACE conservó el EXECUTE.
DO $post$
DECLARE
  r record;
BEGIN
  SELECT md5(prosrc) AS h, proacl::text AS acl INTO r
    FROM pg_proc WHERE oid = 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure;
  IF r.h <> '083550ab7e3524525a667b9cb2a5d554'
     OR r.acl <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock no quedó como en el repo (md5 %, acl %)', r.h, r.acl;
  END IF;
END
$post$;

COMMIT;
