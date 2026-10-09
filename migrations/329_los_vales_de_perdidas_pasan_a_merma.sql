-- Los dos vales de "Distribuidora Crecer - pérdidas y otros" pasan a merma (#1032)
--
-- EL CASO
--
--   El cliente 591 (suc. Taco Pozo) es una cuenta interna para pérdidas. Tiene
--   dos pedidos cargados como venta y pagados con vale blanco, que la 320 (#1031)
--   convirtió a comprobante VB, o sea consumo interno a costo:
--
--     #1461  04/05  $19.575,25   "Son pérdidas porque están rotas."
--     #5598  04/09  $167.420,52  "Las latas estaban dañadas, la manaos tónica
--                                 2250 vencidas, las manaos lima x600 vencidas."
--
--   No son consumo interno: es mercadería rota o vencida. Va por mermas.
--
-- DECISIONES DEL DUEÑO (2026-10-09)
--
--   · Los dos vales se anulan y se cargan las mermas equivalentes, con la fecha
--     original y el motivo de cada línea según la nota del vale: #1461 todo
--     rotura; #5598 las latas rotura, la Tónica 2250 y la Lima Limón 600
--     vencimiento.
--   · La nota del #1461 dice "La Manaos Naranja no está en el sistema": el vale
--     se cargó con Pomelo, Cola y Manzana. La merma va con esos mismos productos
--     (su stock ya se descontó con el vale; cambiar de producto movería stock que
--     hoy cuadra).
--
-- QUÉ HACE
--
--   Por cada vale, el molde de la cancelación por falta de stock (269):
--   · cada línea vuelve al stock con 'pedido_cancelado_merma' —FUERA de la lista
--     blanca de sincronizar_lotes_stock— y se merma enseguida con 'merma'. Las dos
--     patas caen en la bolsa: stock, lote y bolsa quedan exactamente como hoy
--     (CLAUDE.md, "la devolución que se cancela sola NO va etiquetada"). Con
--     'pedido_cancelado' la devolución iría al lote por FEFO y la merma saldría de
--     la bolsa: lote +N, bolsa −N. Cuatro de los siete productos tienen lote.
--   · la merma lleva la fecha del vale (created_at del pedido: el corte de
--     mermas_valorizadas es por día argentino de created_at), el costo congelado
--     de la línea del vale (costo_unitario_al_crear: lo que sale de consumo
--     interno entra a mermas por el mismo monto), el usuario que cargó el vale
--     (MERMA-I) y la nota del vale en las observaciones.
--   · el vale queda cancelado con total y monto_pagado en 0 (VB-A; el UPDATE
--     nombra total y monto_pagado, CLAUDE.md). No tiene pagos, así que no hay
--     nada que pasar a saldo a favor.
--
--   Caja: el #1461 tiene transportista y entrega del 11/05. Cancelar un entregado
--   con transportista borra la fila de rendiciones_control de ese día (trigger
--   anular_control_por_cambio_fecha_entrega). Esa fila no existe (relevado el
--   2026-10-09); si aparece, la migración aborta en vez de reabrir una caja.
--
--   Todo se verifica antes de escribir: si cualquiera de los dos vales no está
--   exactamente como se relevó (estado, total, líneas, pagos, salvedades, NC),
--   la migración aborta sin tocar nada.

DO $vales$
DECLARE
  -- (pedido, producto) -> cantidad y motivo de la merma
  v_plan CONSTANT jsonb := '[
    {"pedido":1461, "producto":189, "cantidad":1,  "motivo":"rotura"},
    {"pedido":1461, "producto":178, "cantidad":1,  "motivo":"rotura"},
    {"pedido":1461, "producto":185, "cantidad":1,  "motivo":"rotura"},
    {"pedido":5598, "producto":180, "cantidad":2,  "motivo":"rotura"},
    {"pedido":5598, "producto":182, "cantidad":2,  "motivo":"rotura"},
    {"pedido":5598, "producto":214, "cantidad":5,  "motivo":"vencimiento"},
    {"pedido":5598, "producto":184, "cantidad":25, "motivo":"vencimiento"}
  ]'::jsonb;
  v_totales CONSTANT jsonb := '{"1461": 19575.25, "5598": 167420.52}'::jsonb;
  v_ped      record;
  v_lin      record;
  v_stock    integer;
  v_merma_id bigint;
  v_antes    jsonb;
  v_despues  jsonb;
  v_g_origen text := current_setting('app.stock_origen', true);
  v_g_tipo   text := current_setting('app.stock_ref_tipo', true);
  v_g_ref    text := current_setting('app.stock_ref_id', true);
  v_g_user   text := current_setting('app.stock_user_id', true);
BEGIN
  -- ---------------------------------------------------------------------------
  -- 1 · Guardas: los dos vales están como se relevaron
  -- ---------------------------------------------------------------------------
  FOR v_ped IN SELECT * FROM pedidos WHERE id IN (1461, 5598) ORDER BY id FOR UPDATE
  LOOP
    IF v_ped.cliente_id <> 591 OR v_ped.sucursal_id <> 2
       OR v_ped.tipo_factura IS DISTINCT FROM 'VB' OR v_ped.estado <> 'entregado'
       OR v_ped.total <> (v_totales->>v_ped.id::text)::numeric
       OR v_ped.monto_pagado <> v_ped.total THEN
      RAISE EXCEPTION 'El pedido % no esta como se relevo (cliente %, suc %, %, %, total %, pagado %): revisar a mano',
        v_ped.id, v_ped.cliente_id, v_ped.sucursal_id, v_ped.tipo_factura, v_ped.estado, v_ped.total, v_ped.monto_pagado;
    END IF;
    IF EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_ped.id) THEN
      RAISE EXCEPTION 'El vale % tiene pagos: revisar a mano', v_ped.id;
    END IF;
    IF EXISTS (SELECT 1 FROM salvedades_items WHERE pedido_id = v_ped.id
                AND estado_resolucion IS DISTINCT FROM 'anulada') THEN
      RAISE EXCEPTION 'El vale % tiene salvedades vivas: revisar a mano', v_ped.id;
    END IF;
    IF public.nota_credito_vigente_de_pedido(v_ped.id) IS NOT NULL THEN
      RAISE EXCEPTION 'El vale % tiene una nota de credito vigente: revisar a mano', v_ped.id;
    END IF;
    IF v_ped.transportista_id IS NOT NULL AND v_ped.fecha_entrega IS NOT NULL
       AND EXISTS (SELECT 1 FROM rendiciones_control
                    WHERE transportista_id = v_ped.transportista_id
                      AND sucursal_id = v_ped.sucursal_id
                      AND fecha = v_ped.fecha_entrega::date) THEN
      RAISE EXCEPTION 'El vale % esta en una rendicion controlada (%): cancelarlo la reabriria',
        v_ped.id, v_ped.fecha_entrega::date;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pedidos WHERE id IN (1461, 5598)) <> 2 THEN
    RAISE EXCEPTION 'No estan los dos vales';
  END IF;

  -- Las líneas son exactamente las del plan: mismos productos, mismas
  -- cantidades, ninguna bonificación y ninguna de más.
  IF EXISTS (
    SELECT 1
      FROM (SELECT pi.pedido_id, pi.producto_id, SUM(pi.cantidad)::int AS cantidad,
                   bool_or(COALESCE(pi.es_bonificacion, false)) AS bonif
              FROM pedido_items pi WHERE pi.pedido_id IN (1461, 5598)
             GROUP BY 1, 2) r
      FULL JOIN jsonb_to_recordset(v_plan) AS p(pedido bigint, producto bigint, cantidad int, motivo text)
        ON p.pedido = r.pedido_id AND p.producto = r.producto_id
     WHERE r.pedido_id IS NULL OR p.pedido IS NULL OR r.cantidad <> p.cantidad OR r.bonif
  ) THEN
    RAISE EXCEPTION 'Las lineas de los vales no coinciden con el plan: revisar a mano';
  END IF;

  -- Foto de stock y lotes de los siete productos, para exigir neto cero.
  SELECT jsonb_object_agg(p.producto::text, jsonb_build_object(
           'stock', pr.stock,
           'lotes', (SELECT COALESCE(SUM(cantidad_restante), 0) FROM producto_lotes l
                      WHERE l.producto_id = pr.id AND l.sucursal_id = pr.sucursal_id)))
    INTO v_antes
    FROM jsonb_to_recordset(v_plan) AS p(pedido bigint, producto bigint, cantidad int, motivo text)
    JOIN productos pr ON pr.id = p.producto AND pr.sucursal_id = 2;

  -- ---------------------------------------------------------------------------
  -- 2 · Devolver y mermar cada línea (neto cero, las dos patas en la bolsa)
  -- ---------------------------------------------------------------------------
  FOR v_lin IN
    SELECT p.pedido, p.producto, p.cantidad, p.motivo,
           pe.created_at, pe.usuario_id, pe.notas, pe.sucursal_id,
           pi.costo_unitario_al_crear
      FROM jsonb_to_recordset(v_plan) AS p(pedido bigint, producto bigint, cantidad int, motivo text)
      JOIN pedidos pe ON pe.id = p.pedido
      JOIN pedido_items pi ON pi.pedido_id = p.pedido AND pi.producto_id = p.producto
     ORDER BY p.pedido, p.producto
  LOOP
    PERFORM set_config('app.stock_origen',   'pedido_cancelado_merma', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido',                 true);
    PERFORM set_config('app.stock_ref_id',   v_lin.pedido::text,       true);
    PERFORM set_config('app.stock_user_id',  v_lin.usuario_id::text,   true);

    UPDATE productos SET stock = stock + v_lin.cantidad
     WHERE id = v_lin.producto AND sucursal_id = v_lin.sucursal_id;

    SELECT stock INTO v_stock FROM productos
     WHERE id = v_lin.producto AND sucursal_id = v_lin.sucursal_id
       FOR UPDATE;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id,
      costo_unitario, created_at
    ) VALUES (
      v_lin.producto, v_lin.cantidad, v_lin.motivo,
      'Vale blanco #' || v_lin.pedido || ' pasado a merma (#1032): ' || COALESCE(v_lin.notas, ''),
      v_stock, GREATEST(v_stock - v_lin.cantidad, 0), v_lin.usuario_id, v_lin.sucursal_id,
      v_lin.costo_unitario_al_crear, v_lin.created_at
    ) RETURNING id INTO v_merma_id;

    PERFORM set_config('app.stock_origen',   'merma',            true);
    PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',     true);
    PERFORM set_config('app.stock_ref_id',   v_merma_id::text,   true);

    -- Resta exacta: la inversa de la suma de arriba.
    UPDATE productos SET stock = stock - v_lin.cantidad
     WHERE id = v_lin.producto AND sucursal_id = v_lin.sucursal_id;
  END LOOP;

  -- set_config es por transacción (229): no dejarle 'merma' a lo que siga.
  PERFORM set_config('app.stock_origen',   COALESCE(v_g_origen, ''), true);
  PERFORM set_config('app.stock_ref_tipo', COALESCE(v_g_tipo, ''),   true);
  PERFORM set_config('app.stock_ref_id',   COALESCE(v_g_ref, ''),    true);
  PERFORM set_config('app.stock_user_id',  COALESCE(v_g_user, ''),   true);

  -- ---------------------------------------------------------------------------
  -- 3 · Anular los vales
  -- ---------------------------------------------------------------------------
  UPDATE pedidos
     SET estado = 'cancelado',
         motivo_cancelacion = 'No era consumo interno: mercaderia rota o vencida, pasada a merma con la fecha del vale (#1032)',
         motivo_cancelacion_tipo = 'error_de_carga',
         total = 0,
         monto_pagado = 0,
         total_neto = 0,
         total_iva = 0,
         total_real = 0,
         updated_at = now()
   WHERE id IN (1461, 5598);

  -- El historial (estado y total) lo escribe registrar_cambio_pedido; el
  -- motivo queda en motivo_cancelacion.

  -- ---------------------------------------------------------------------------
  -- 4 · Verificación
  -- ---------------------------------------------------------------------------
  SELECT jsonb_object_agg(p.producto::text, jsonb_build_object(
           'stock', pr.stock,
           'lotes', (SELECT COALESCE(SUM(cantidad_restante), 0) FROM producto_lotes l
                      WHERE l.producto_id = pr.id AND l.sucursal_id = pr.sucursal_id)))
    INTO v_despues
    FROM jsonb_to_recordset(v_plan) AS p(pedido bigint, producto bigint, cantidad int, motivo text)
    JOIN productos pr ON pr.id = p.producto AND pr.sucursal_id = 2;
  IF v_despues IS DISTINCT FROM v_antes THEN
    RAISE EXCEPTION 'El stock o los lotes se movieron: antes %, despues %', v_antes, v_despues;
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id IN (1461, 5598)
              AND (estado <> 'cancelado' OR total <> 0 OR monto_pagado <> 0 OR total_real <> 0
                   OR estado_pago IS DISTINCT FROM 'pagado')) THEN
    RAISE EXCEPTION 'Los vales no quedaron cancelados en cero';
  END IF;

  -- El costo congelado tiene 4 decimales y el total del vale esta redondeado a
  -- centavos: la merma vale lo que costaban las lineas, a menos de un centavo
  -- del total de cada vale.
  IF (SELECT count(*) FROM mermas_stock WHERE observaciones LIKE 'Vale blanco #% pasado a merma (#1032):%') <> 7
     OR (SELECT SUM(cantidad * costo_unitario) FROM mermas_stock
          WHERE observaciones LIKE 'Vale blanco #% pasado a merma (#1032):%')
        <> (SELECT SUM(cantidad * costo_unitario_al_crear) FROM pedido_items WHERE pedido_id IN (1461, 5598)) THEN
    RAISE EXCEPTION 'Las mermas no valen lo que costaban las lineas de los vales';
  END IF;
END
$vales$;
