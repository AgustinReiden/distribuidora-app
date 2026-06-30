-- ============================================================================
-- 105 · auditoria_integridad(): batería de invariantes de integridad de datos
-- ============================================================================
-- Corre todas las invariantes del plan (docs/plan-auditoria-integridad.md) y
-- devuelve un tablero JSONB: cada check con su conteo de violaciones (0 = OK).
-- overall_ok = true si NINGÚN check critical/high tiene violaciones.
-- Pensado para: panel /reportes-gerenciales, checklist pre-presentación y un
-- cron que alerta si algo critical/high se pone en rojo.
-- SECURITY DEFINER + admin-only (como reporte_gerencial); service_role libre.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.auditoria_integridad()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_checks jsonb;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  WITH checks(id, severidad, descripcion, viol) AS (
    VALUES
    -- ===== Ventas =====
    ('VENTA-A','critical','pedidos.total = SUM(pedido_items.subtotal) en no cancelados',
      (SELECT count(*) FROM (SELECT p.id FROM pedidos p LEFT JOIN pedido_items pi ON pi.pedido_id=p.id
        WHERE p.estado NOT IN ('cancelado','anulado') GROUP BY p.id,p.total
        HAVING abs(p.total-COALESCE(sum(pi.subtotal),0))>0.01) x)),
    ('VENTA-B','high','ningún pedido_items con subtotal<0',
      (SELECT count(*) FROM pedido_items WHERE subtotal<0)),
    ('VENTA-C','high','estados de pedido dentro del dominio permitido',
      (SELECT count(*) FROM pedidos WHERE estado NOT IN ('entregado','asignado','pendiente','cancelado','anulado'))),
    ('VENTA-D','medium','canal de pedido dentro del dominio permitido',
      (SELECT count(*) FROM pedidos WHERE canal NOT IN ('app','cambio','bot'))),
    ('VENTA-E','high','venta entregada/app sin fecha nula ni futura',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal='app' AND (fecha IS NULL OR fecha>CURRENT_DATE))),
    ('VENTA-F','high','ningún pedido con total<0',
      (SELECT count(*) FROM pedidos WHERE total<0)),
    ('VENTA-G','medium','ningún pedido_items con cantidad<=0',
      (SELECT count(*) FROM pedido_items WHERE cantidad<=0)),
    ('VENTA-H','high','pedido_items.sucursal_id = pedidos.sucursal_id',
      (SELECT count(*) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id WHERE pi.sucursal_id<>p.sucursal_id)),
    ('VENTA-I','low','pedido cancelado debe tener total=0 (4 legacy de abril)',
      (SELECT count(*) FROM pedidos WHERE estado='cancelado' AND total<>0)),
    ('VENTA-J','low','ningún pedido entregado sin items (id 652 legacy)',
      (SELECT count(*) FROM pedidos p WHERE estado='entregado' AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id=p.id))),
    ('VENTA-M','medium','coherencia estado_pago vs monto_pagado',
      (SELECT (SELECT count(*) FROM pedidos WHERE estado_pago='pagado' AND estado NOT IN ('cancelado','anulado') AND total>0 AND COALESCE(monto_pagado,0)<total-0.01)
            + (SELECT count(*) FROM pedidos WHERE estado_pago='pendiente' AND COALESCE(monto_pagado,0)>0.01))),
    -- ===== Costos / margen =====
    ('COSTO-A','high','pedidos de las últimas 2h: líneas no-bonif con costo congelado poblado (centinela del snapshot)',
      (SELECT count(*) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id
        WHERE NOT pi.es_bonificacion AND pi.costo_unitario_al_crear IS NULL AND p.created_at >= now()-interval '2 hours')),
    ('COSTO-B','medium','productos con ventas entregadas y costo NULL/0 (inflan margen)',
      (SELECT count(DISTINCT prod.id) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id JOIN productos prod ON prod.id=pi.producto_id
        WHERE p.estado='entregado' AND p.canal='app' AND NOT pi.es_bonificacion AND (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva=0))),
    ('COSTO-C','medium','productos con precio < costo real (venta bajo costo)',
      (SELECT count(*) FROM productos WHERE costo_sin_iva>0 AND precio>0 AND precio < costo_sin_iva*(1+COALESCE(impuestos_internos,0)/100))),
    -- ===== Bonificaciones / promos =====
    ('BONIF-A','high','bonificación con subtotal o precio_unitario <> 0',
      (SELECT count(*) FROM pedido_items WHERE es_bonificacion AND (COALESCE(subtotal,0)<>0 OR COALESCE(precio_unitario,0)<>0))),
    ('BONIF-B','medium','item no-bonif con subtotal=0 (venta gratis sin marcar)',
      (SELECT count(*) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id WHERE NOT pi.es_bonificacion AND COALESCE(pi.subtotal,0)=0 AND p.estado<>'cancelado')),
    ('BONIF-C','medium','promo_ajustes de consumo (Auto-ajuste) sin merma_id',
      (SELECT count(*) FROM promo_ajustes WHERE merma_id IS NULL AND COALESCE(observaciones,'') LIKE 'Auto-ajuste%')),
    ('BONIF-D','medium','promociones con usos_pendientes<0',
      (SELECT count(*) FROM promociones WHERE COALESCE(usos_pendientes,0)<0)),
    -- ===== Mermas =====
    ('MERMA-A','high','motivo de merma dentro del CHECK permitido',
      (SELECT count(*) FROM mermas_stock WHERE motivo IS NULL OR motivo NOT IN ('rotura','vencimiento','robo','decomiso','devolucion','error_inventario','muestra','otro','promociones','promociones_reversion'))),
    ('MERMA-B','high','asiento coherente: stock_nuevo = GREATEST(stock_anterior-cantidad,0) | reversión',
      (SELECT count(*) FROM mermas_stock WHERE stock_nuevo <> CASE WHEN cantidad>=0 THEN GREATEST(stock_anterior-cantidad,0) ELSE stock_anterior-cantidad END)),
    ('MERMA-C','medium','toda merma referencia un producto existente',
      (SELECT count(*) FROM mermas_stock m LEFT JOIN productos p ON p.id=m.producto_id WHERE p.id IS NULL)),
    ('MERMA-E','high','cantidad negativa solo en promociones_reversion',
      (SELECT count(*) FROM mermas_stock WHERE cantidad<0 AND motivo<>'promociones_reversion')),
    ('MERMA-H','medium','sin stock_anterior/stock_nuevo negativos',
      (SELECT count(*) FROM mermas_stock WHERE stock_anterior<0 OR stock_nuevo<0)),
    ('MERMA-I','medium','mermas reales sin usuario_id (trazabilidad pendiente P1)',
      (SELECT count(*) FROM mermas_stock WHERE usuario_id IS NULL AND motivo NOT IN ('promociones','promociones_reversion'))),
    -- ===== Stock / ledger =====
    ('STK-A','critical','productos.stock = última fila de stock_historico',
      (SELECT count(*) FROM productos p JOIN (SELECT DISTINCT ON (producto_id,sucursal_id) producto_id,sucursal_id,stock_nuevo
        FROM stock_historico ORDER BY producto_id,sucursal_id,created_at DESC,id DESC) u
        ON u.producto_id=p.id AND u.sucursal_id=p.sucursal_id WHERE p.stock<>u.stock_nuevo)),
    ('STK-B','critical','ningún producto con stock<0',
      (SELECT count(*) FROM productos WHERE stock<0)),
    ('STK-E','high','sucursal del movimiento = sucursal del producto',
      (SELECT count(*) FROM stock_historico s JOIN productos p ON p.id=s.producto_id WHERE s.sucursal_id<>p.sucursal_id)),
    ('STK-D','info','movimientos origen=auto sin referencia (trazabilidad pendiente P1)',
      (SELECT count(*) FROM stock_historico WHERE origen='auto' AND referencia_id IS NULL)),
    -- ===== Cuenta corriente / pagos =====
    ('CC-A','critical','saldo_cuenta = Σ(total-monto_pagado no cancelados) − Σ(pagos a cuenta sin pedido = saldo a favor)',
      (SELECT count(*) FROM clientes c WHERE abs(COALESCE(c.saldo_cuenta,0) - (
        COALESCE((SELECT sum(p.total-COALESCE(p.monto_pagado,0)) FROM pedidos p
          WHERE p.cliente_id=c.id AND p.estado NOT IN ('cancelado','anulado')),0)
        - COALESCE((SELECT sum(pg.monto) FROM pagos pg WHERE pg.cliente_id=c.id AND pg.pedido_id IS NULL),0)))>0.01)),
    ('CC-PAGOS-CANCEL','high','ningún pago imputado a un pedido cancelado',
      (SELECT count(*) FROM pagos pg JOIN pedidos p ON p.id=pg.pedido_id WHERE p.estado='cancelado')),
    -- ===== Compras =====
    ('COMPRA-A1','high','compras.total = subtotal+iva+otros_impuestos',
      (SELECT count(*) FROM compras WHERE estado<>'cancelada' AND abs(COALESCE(total,0)-(COALESCE(subtotal,0)+COALESCE(iva,0)+COALESCE(otros_impuestos,0)))>1.0)),
    ('COMPRA-A2','medium','compras.subtotal = SUM(compra_items.subtotal) (5 legacy)',
      (SELECT count(*) FROM compras c JOIN (SELECT compra_id, sum(subtotal) s FROM compra_items GROUP BY compra_id) it ON it.compra_id=c.id
        WHERE c.estado<>'cancelada' AND abs(COALESCE(c.subtotal,0)-it.s)>1.0)),
    ('COMPRA-B','high','compra ZZ con iva<>0',
      (SELECT count(*) FROM compras WHERE tipo_factura='ZZ' AND COALESCE(iva,0)<>0 AND estado<>'cancelada')),
    ('COMPRA-C','high','compra_item de compra activa con costo_unitario<=0',
      (SELECT count(*) FROM compra_items ci JOIN compras c ON c.id=ci.compra_id WHERE c.estado<>'cancelada' AND COALESCE(ci.costo_unitario,0)<=0)),
    ('COMPRA-E','medium','bonificación de compra fuera de [0,100)',
      (SELECT count(*) FROM compra_items WHERE bonificacion<0 OR bonificacion>=100)),
    ('COMPRA-G','high','compra_item.sucursal_id = compra.sucursal_id',
      (SELECT count(*) FROM compra_items ci JOIN compras c ON c.id=ci.compra_id WHERE ci.sucursal_id<>c.sucursal_id)),
    ('COMPRA-H','medium','cantidad de compra_item > 0',
      (SELECT count(*) FROM compra_items WHERE cantidad<=0)),
    -- ===== Cambios / comisiones =====
    ('CAMBIO-01','high','pedido canal=cambio debe tener total=0',
      (SELECT count(*) FROM pedidos WHERE canal='cambio' AND total<>0)),
    ('CAMBIO-03','high','cambio 1:1 con recorrido_cambios y sin colgar de venta app',
      (SELECT (SELECT count(*) FROM pedidos p WHERE p.canal='cambio' AND NOT EXISTS (SELECT 1 FROM recorrido_cambios rc WHERE rc.pedido_id=p.id))
            + (SELECT count(*) FROM recorrido_cambios rc JOIN pedidos p ON p.id=rc.pedido_id WHERE p.canal<>'cambio'))),
    ('COMIS-01','medium','venta entregada/app sin vendedor (usuario_id en perfiles)',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal='app' AND (usuario_id IS NULL OR usuario_id NOT IN (SELECT id FROM perfiles)))),
    ('COMIS-05','high','pedidos app de últimas 2h con creado_por poblado (centinela de atribución)',
      (SELECT count(*) FROM pedidos WHERE created_at >= now()-interval '2 hours' AND canal='app' AND creado_por IS NULL))
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))
    ORDER BY (viol=0), array_position(ARRAY['critical','high','medium','low','info'], severidad)
  ) INTO v_checks FROM checks;

  SELECT jsonb_build_object(
    'generado_at', now(),
    'overall_ok', NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_checks) c
      WHERE (c->>'ok')::boolean = false AND c->>'severidad' IN ('critical','high')),
    'total_checks', jsonb_array_length(v_checks),
    'con_violaciones', (SELECT count(*) FROM jsonb_array_elements(v_checks) c WHERE (c->>'ok')::boolean = false),
    'critical_high_en_rojo', (SELECT count(*) FROM jsonb_array_elements(v_checks) c WHERE (c->>'ok')::boolean=false AND c->>'severidad' IN ('critical','high')),
    'checks', v_checks
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.auditoria_integridad() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.auditoria_integridad() TO authenticated, service_role;

COMMENT ON FUNCTION public.auditoria_integridad() IS
  'Batería de invariantes de integridad (ver docs/plan-auditoria-integridad.md). Devuelve tablero JSONB; overall_ok=true si ningún check critical/high tiene violaciones. Admin-only.';
