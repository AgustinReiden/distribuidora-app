-- ============================================================
-- Migration 058: Multi-tenant RLS Policies
-- ============================================================
--
-- Drops ALL existing RLS policies on tenant-scoped tables and replaces
-- them with new policies that enforce sucursal_id = current_sucursal_id()
-- filtering for multi-tenant isolation.
--
-- Depends on: 057_multi_tenant_schema.sql (current_sucursal_id() function)
--
-- Naming convention: mt_<tablename>_<operation>
-- All policies are PERMISSIVE, TO authenticated.
-- ============================================================


-- ============================================================
-- 1. CLIENTES
-- ============================================================

-- Drop all existing policies
DROP POLICY IF EXISTS "Clientes: lectura para usuarios autenticados" ON clientes;
DROP POLICY IF EXISTS "Clientes: insercion para admin/preventista" ON clientes;
DROP POLICY IF EXISTS "Clientes: actualizacion para admin/preventista" ON clientes;
DROP POLICY IF EXISTS "Clientes: eliminacion solo admin" ON clientes;
DROP POLICY IF EXISTS "Clientes: transportista ve su zona" ON clientes;

CREATE POLICY mt_clientes_select ON clientes
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_clientes_insert ON clientes
  FOR INSERT TO authenticated
  WITH CHECK (es_preventista() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_clientes_update ON clientes
  FOR UPDATE TO authenticated
  USING (es_preventista() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_preventista() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_clientes_delete ON clientes
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 2. PRODUCTOS
-- ============================================================

DROP POLICY IF EXISTS "Productos: lectura para usuarios autenticados" ON productos;
DROP POLICY IF EXISTS "Productos: insercion solo admin" ON productos;
DROP POLICY IF EXISTS "Productos: actualizacion solo admin" ON productos;
DROP POLICY IF EXISTS "Productos: eliminacion solo admin" ON productos;

CREATE POLICY mt_productos_select ON productos
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_productos_insert ON productos
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_productos_update ON productos
  FOR UPDATE TO authenticated
  USING (
    (es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  )
  WITH CHECK (
    (es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_productos_delete ON productos
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 3. PEDIDOS
-- ============================================================

DROP POLICY IF EXISTS "Pedidos: lectura segun rol" ON pedidos;
DROP POLICY IF EXISTS "Pedidos: insercion para admin/preventista" ON pedidos;
DROP POLICY IF EXISTS "Pedidos: actualizacion segun rol" ON pedidos;
DROP POLICY IF EXISTS "Pedidos: eliminacion solo admin" ON pedidos;

CREATE POLICY mt_pedidos_select ON pedidos
  FOR SELECT TO authenticated
  USING (
    (es_encargado_o_admin() OR usuario_id = auth.uid() OR transportista_id = auth.uid())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_pedidos_insert ON pedidos
  FOR INSERT TO authenticated
  WITH CHECK (es_preventista() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_pedidos_update ON pedidos
  FOR UPDATE TO authenticated
  USING (
    (es_encargado_o_admin() OR usuario_id = auth.uid() OR transportista_id = auth.uid())
    AND sucursal_id = current_sucursal_id()
  )
  WITH CHECK (
    (es_encargado_o_admin() OR usuario_id = auth.uid() OR transportista_id = auth.uid())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_pedidos_delete ON pedidos
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 4. PEDIDO_ITEMS
-- ============================================================

DROP POLICY IF EXISTS "PedidoItems: lectura vinculada a pedido" ON pedido_items;
DROP POLICY IF EXISTS "PedidoItems: insercion para admin/preventista" ON pedido_items;
DROP POLICY IF EXISTS "PedidoItems: actualizacion para admin/preventista" ON pedido_items;
DROP POLICY IF EXISTS "PedidoItems: eliminacion solo admin" ON pedido_items;

CREATE POLICY mt_pedido_items_select ON pedido_items
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM pedidos p
      WHERE p.id = pedido_items.pedido_id
        AND (es_encargado_o_admin() OR p.usuario_id = auth.uid() OR p.transportista_id = auth.uid())
    )
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_pedido_items_insert ON pedido_items
  FOR INSERT TO authenticated
  WITH CHECK (es_preventista() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_pedido_items_update ON pedido_items
  FOR UPDATE TO authenticated
  USING (es_preventista() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_preventista() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_pedido_items_delete ON pedido_items
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 5. PEDIDO_HISTORIAL
-- ============================================================

DROP POLICY IF EXISTS "PedidoHistorial: lectura vinculada a pedido" ON pedido_historial;
DROP POLICY IF EXISTS "PedidoHistorial: insercion usuarios autenticados" ON pedido_historial;

CREATE POLICY mt_pedido_historial_select ON pedido_historial
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_pedido_historial_insert ON pedido_historial
  FOR INSERT TO authenticated
  WITH CHECK (sucursal_id = current_sucursal_id());

CREATE POLICY mt_pedido_historial_update ON pedido_historial
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_pedido_historial_delete ON pedido_historial
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 6. PAGOS
-- ============================================================

DROP POLICY IF EXISTS "Allow authenticated users to view payments" ON pagos;
DROP POLICY IF EXISTS "Allow authenticated users to insert payments" ON pagos;
DROP POLICY IF EXISTS "Allow authenticated users to update payments" ON pagos;
DROP POLICY IF EXISTS "Allow authenticated users to delete payments" ON pagos;
DROP POLICY IF EXISTS "Pagos: lectura para admin/preventista" ON pagos;
DROP POLICY IF EXISTS "Pagos: insercion para admin/preventista" ON pagos;
DROP POLICY IF EXISTS "Pagos: actualizacion solo admin" ON pagos;
DROP POLICY IF EXISTS "Pagos: eliminacion solo admin" ON pagos;
DROP POLICY IF EXISTS "Pagos: actualizacion para admin/encargado" ON pagos;

CREATE POLICY mt_pagos_select ON pagos
  FOR SELECT TO authenticated
  USING (es_preventista() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_pagos_insert ON pagos
  FOR INSERT TO authenticated
  WITH CHECK (es_preventista() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_pagos_update ON pagos
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_pagos_delete ON pagos
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 7. COMPRAS
-- ============================================================

DROP POLICY IF EXISTS "Admin full access compras" ON compras;
DROP POLICY IF EXISTS "Users can view compras" ON compras;
DROP POLICY IF EXISTS "Compras: lectura solo admin" ON compras;
DROP POLICY IF EXISTS "Compras: insercion solo admin" ON compras;
DROP POLICY IF EXISTS "Compras: actualizacion solo admin" ON compras;
DROP POLICY IF EXISTS "Compras: eliminacion solo admin" ON compras;

CREATE POLICY mt_compras_select ON compras
  FOR SELECT TO authenticated
  USING (
    (es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_compras_insert ON compras
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_compras_update ON compras
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_compras_delete ON compras
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 8. COMPRA_ITEMS
-- ============================================================

DROP POLICY IF EXISTS "Admin full access compra_items" ON compra_items;
DROP POLICY IF EXISTS "Users can view compra_items" ON compra_items;
DROP POLICY IF EXISTS "CompraItems: lectura solo admin" ON compra_items;
DROP POLICY IF EXISTS "CompraItems: insercion solo admin" ON compra_items;
DROP POLICY IF EXISTS "CompraItems: actualizacion solo admin" ON compra_items;
DROP POLICY IF EXISTS "CompraItems: eliminacion solo admin" ON compra_items;

CREATE POLICY mt_compra_items_select ON compra_items
  FOR SELECT TO authenticated
  USING (
    (es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_compra_items_insert ON compra_items
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_compra_items_update ON compra_items
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_compra_items_delete ON compra_items
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 9. PROVEEDORES
-- ============================================================

DROP POLICY IF EXISTS "Admin full access proveedores" ON proveedores;
DROP POLICY IF EXISTS "Users can view proveedores" ON proveedores;
DROP POLICY IF EXISTS "Proveedores: lectura solo admin" ON proveedores;
DROP POLICY IF EXISTS "Proveedores: insercion solo admin" ON proveedores;
DROP POLICY IF EXISTS "Proveedores: actualizacion solo admin" ON proveedores;
DROP POLICY IF EXISTS "Proveedores: eliminacion solo admin" ON proveedores;

CREATE POLICY mt_proveedores_select ON proveedores
  FOR SELECT TO authenticated
  USING (
    (es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_proveedores_insert ON proveedores
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_proveedores_update ON proveedores
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_proveedores_delete ON proveedores
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 10. MERMAS_STOCK
-- ============================================================

DROP POLICY IF EXISTS "Admin full access mermas" ON mermas_stock;
DROP POLICY IF EXISTS "Users can view mermas" ON mermas_stock;
DROP POLICY IF EXISTS "Mermas: lectura para admin/transportista" ON mermas_stock;
DROP POLICY IF EXISTS "Mermas: insercion para admin/transportista" ON mermas_stock;
DROP POLICY IF EXISTS "Mermas: actualizacion solo admin" ON mermas_stock;
DROP POLICY IF EXISTS "Mermas: eliminacion solo admin" ON mermas_stock;

CREATE POLICY mt_mermas_stock_select ON mermas_stock
  FOR SELECT TO authenticated
  USING (
    (es_admin() OR es_transportista())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_mermas_stock_insert ON mermas_stock
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR es_transportista())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_mermas_stock_update ON mermas_stock
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_mermas_stock_delete ON mermas_stock
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 11. STOCK_HISTORICO
-- ============================================================

DROP POLICY IF EXISTS "stock_historico_select_authenticated" ON stock_historico;
DROP POLICY IF EXISTS "stock_historico_insert_admin" ON stock_historico;
DROP POLICY IF EXISTS "stock_historico_insert" ON stock_historico;

CREATE POLICY mt_stock_historico_select ON stock_historico
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_stock_historico_insert ON stock_historico
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );


-- ============================================================
-- 12. RECORRIDOS
-- ============================================================

DROP POLICY IF EXISTS "Admins pueden ver todos los recorridos" ON recorridos;
DROP POLICY IF EXISTS "Transportistas pueden ver sus recorridos" ON recorridos;
DROP POLICY IF EXISTS "Admins pueden insertar recorridos" ON recorridos;
DROP POLICY IF EXISTS "Admins pueden actualizar recorridos" ON recorridos;

CREATE POLICY mt_recorridos_select ON recorridos
  FOR SELECT TO authenticated
  USING (
    (es_admin() OR transportista_id = auth.uid())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_recorridos_insert ON recorridos
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_recorridos_update ON recorridos
  FOR UPDATE TO authenticated
  USING (
    (es_admin() OR transportista_id = auth.uid())
    AND sucursal_id = current_sucursal_id()
  )
  WITH CHECK (
    (es_admin() OR transportista_id = auth.uid())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_recorridos_delete ON recorridos
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 13. RECORRIDO_PEDIDOS
-- ============================================================

DROP POLICY IF EXISTS "Admins pueden ver detalles de recorridos" ON recorrido_pedidos;
DROP POLICY IF EXISTS "Transportistas pueden ver detalles de sus recorridos" ON recorrido_pedidos;
DROP POLICY IF EXISTS "Admins pueden insertar detalles de recorridos" ON recorrido_pedidos;
DROP POLICY IF EXISTS "Admins pueden actualizar detalles de recorridos" ON recorrido_pedidos;

CREATE POLICY mt_recorrido_pedidos_select ON recorrido_pedidos
  FOR SELECT TO authenticated
  USING (
    (
      es_admin()
      OR EXISTS (
        SELECT 1 FROM recorridos r
        WHERE r.id = recorrido_pedidos.recorrido_id
          AND r.transportista_id = auth.uid()
      )
    )
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_recorrido_pedidos_insert ON recorrido_pedidos
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_recorrido_pedidos_update ON recorrido_pedidos
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 14. RENDICIONES
-- ============================================================

DROP POLICY IF EXISTS "Admin full access rendiciones" ON rendiciones;
DROP POLICY IF EXISTS "Transportista ve sus rendiciones" ON rendiciones;
DROP POLICY IF EXISTS "Transportista crea sus rendiciones" ON rendiciones;
DROP POLICY IF EXISTS "Transportista actualiza sus rendiciones pendientes" ON rendiciones;

CREATE POLICY mt_rendiciones_select ON rendiciones
  FOR SELECT TO authenticated
  USING (
    (es_admin() OR transportista_id = auth.uid())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_rendiciones_insert ON rendiciones
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR transportista_id = auth.uid())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_rendiciones_update ON rendiciones
  FOR UPDATE TO authenticated
  USING (
    (es_admin() OR (transportista_id = auth.uid() AND estado = 'pendiente'))
    AND sucursal_id = current_sucursal_id()
  )
  WITH CHECK (
    (es_admin() OR (transportista_id = auth.uid() AND estado = 'pendiente'))
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_rendiciones_delete ON rendiciones
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 15. RENDICION_ITEMS
-- ============================================================

DROP POLICY IF EXISTS "Admin full access rendicion_items" ON rendicion_items;
DROP POLICY IF EXISTS "Transportista ve items de sus rendiciones" ON rendicion_items;
DROP POLICY IF EXISTS "Transportista crea items en sus rendiciones" ON rendicion_items;

CREATE POLICY mt_rendicion_items_select ON rendicion_items
  FOR SELECT TO authenticated
  USING (
    (
      es_admin()
      OR EXISTS (
        SELECT 1 FROM rendiciones r
        WHERE r.id = rendicion_items.rendicion_id
          AND r.transportista_id = auth.uid()
      )
    )
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_rendicion_items_insert ON rendicion_items
  FOR INSERT TO authenticated
  WITH CHECK (
    (
      es_admin()
      OR EXISTS (
        SELECT 1 FROM rendiciones r
        WHERE r.id = rendicion_items.rendicion_id
          AND r.transportista_id = auth.uid()
      )
    )
    AND sucursal_id = current_sucursal_id()
  );


-- ============================================================
-- 16. RENDICION_AJUSTES
-- ============================================================

DROP POLICY IF EXISTS "Admin full access rendicion_ajustes" ON rendicion_ajustes;
DROP POLICY IF EXISTS "Transportista ve ajustes de sus rendiciones" ON rendicion_ajustes;
DROP POLICY IF EXISTS "Transportista crea ajustes en sus rendiciones" ON rendicion_ajustes;

CREATE POLICY mt_rendicion_ajustes_select ON rendicion_ajustes
  FOR SELECT TO authenticated
  USING (
    (
      es_admin()
      OR EXISTS (
        SELECT 1 FROM rendiciones r
        WHERE r.id = rendicion_ajustes.rendicion_id
          AND r.transportista_id = auth.uid()
      )
    )
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_rendicion_ajustes_insert ON rendicion_ajustes
  FOR INSERT TO authenticated
  WITH CHECK (
    (
      es_admin()
      OR EXISTS (
        SELECT 1 FROM rendiciones r
        WHERE r.id = rendicion_ajustes.rendicion_id
          AND r.transportista_id = auth.uid()
      )
    )
    AND sucursal_id = current_sucursal_id()
  );


-- ============================================================
-- 17. SALVEDADES_ITEMS
-- ============================================================

DROP POLICY IF EXISTS "Admin full access salvedades" ON salvedades_items;
DROP POLICY IF EXISTS "Transportista ve salvedades de sus pedidos" ON salvedades_items;
DROP POLICY IF EXISTS "Transportista crea salvedades" ON salvedades_items;
DROP POLICY IF EXISTS "Preventista ve salvedades de sus pedidos" ON salvedades_items;

CREATE POLICY mt_salvedades_items_select ON salvedades_items
  FOR SELECT TO authenticated
  USING (
    (
      es_admin()
      OR EXISTS (
        SELECT 1 FROM pedidos p
        WHERE p.id = salvedades_items.pedido_id
          AND (p.usuario_id = auth.uid() OR p.transportista_id = auth.uid())
      )
    )
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_salvedades_items_insert ON salvedades_items
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR es_transportista())
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_salvedades_items_update ON salvedades_items
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_salvedades_items_delete ON salvedades_items
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 18. SALVEDAD_HISTORIAL
-- ============================================================

DROP POLICY IF EXISTS "Admin full access salvedad_historial" ON salvedad_historial;
DROP POLICY IF EXISTS "Ver historial de salvedades accesibles" ON salvedad_historial;
DROP POLICY IF EXISTS "Insertar historial" ON salvedad_historial;

CREATE POLICY mt_salvedad_historial_select ON salvedad_historial
  FOR SELECT TO authenticated
  USING (
    (
      es_admin()
      OR EXISTS (
        SELECT 1 FROM pedidos p
        WHERE p.id = salvedad_historial.pedido_id
          AND (p.usuario_id = auth.uid() OR p.transportista_id = auth.uid())
      )
    )
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_salvedad_historial_insert ON salvedad_historial
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR es_transportista())
    AND sucursal_id = current_sucursal_id()
  );


-- ============================================================
-- 19. NOTAS_CREDITO
-- ============================================================

DROP POLICY IF EXISTS "admin_notas_credito" ON notas_credito;
DROP POLICY IF EXISTS "read_notas_credito" ON notas_credito;

CREATE POLICY mt_notas_credito_select ON notas_credito
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_notas_credito_all ON notas_credito
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 20. NOTA_CREDITO_ITEMS
-- ============================================================

DROP POLICY IF EXISTS "admin_nota_credito_items" ON nota_credito_items;
DROP POLICY IF EXISTS "read_nota_credito_items" ON nota_credito_items;

CREATE POLICY mt_nota_credito_items_select ON nota_credito_items
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_nota_credito_items_all ON nota_credito_items
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 21. TRANSFERENCIAS_STOCK (uses tenant_sucursal_id!)
-- ============================================================

DROP POLICY IF EXISTS "admin_transferencias_stock" ON transferencias_stock;
DROP POLICY IF EXISTS "read_transferencias_stock" ON transferencias_stock;

CREATE POLICY mt_transferencias_stock_select ON transferencias_stock
  FOR SELECT TO authenticated
  USING (tenant_sucursal_id = current_sucursal_id());

CREATE POLICY mt_transferencias_stock_all ON transferencias_stock
  FOR ALL TO authenticated
  USING (es_admin() AND tenant_sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND tenant_sucursal_id = current_sucursal_id());


-- ============================================================
-- 22. TRANSFERENCIA_ITEMS
-- ============================================================

DROP POLICY IF EXISTS "admin_transferencia_items" ON transferencia_items;
DROP POLICY IF EXISTS "read_transferencia_items" ON transferencia_items;

CREATE POLICY mt_transferencia_items_select ON transferencia_items
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_transferencia_items_all ON transferencia_items
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 23. PROMOCIONES
-- ============================================================

DROP POLICY IF EXISTS "Admin full access promociones" ON promociones;
DROP POLICY IF EXISTS "Users can view promociones" ON promociones;

CREATE POLICY mt_promociones_select ON promociones
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_promociones_all ON promociones
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 24. PROMOCION_PRODUCTOS
-- ============================================================

DROP POLICY IF EXISTS "Admin full access promocion_productos" ON promocion_productos;
DROP POLICY IF EXISTS "Users can view promocion_productos" ON promocion_productos;

CREATE POLICY mt_promocion_productos_select ON promocion_productos
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_promocion_productos_all ON promocion_productos
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 25. PROMOCION_REGLAS
-- ============================================================

DROP POLICY IF EXISTS "Admin full access promocion_reglas" ON promocion_reglas;
DROP POLICY IF EXISTS "Users can view promocion_reglas" ON promocion_reglas;

CREATE POLICY mt_promocion_reglas_select ON promocion_reglas
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_promocion_reglas_all ON promocion_reglas
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 26. PROMO_AJUSTES
-- ============================================================

DROP POLICY IF EXISTS "Admin full access promo_ajustes" ON promo_ajustes;
DROP POLICY IF EXISTS "Users can view promo_ajustes" ON promo_ajustes;

CREATE POLICY mt_promo_ajustes_select ON promo_ajustes
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_promo_ajustes_all ON promo_ajustes
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 27. GRUPOS_PRECIO
-- ============================================================

DROP POLICY IF EXISTS "Admin full access grupos_precio" ON grupos_precio;
DROP POLICY IF EXISTS "Users can view grupos_precio" ON grupos_precio;

CREATE POLICY mt_grupos_precio_select ON grupos_precio
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_grupos_precio_all ON grupos_precio
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 28. GRUPO_PRECIO_PRODUCTOS
-- ============================================================

DROP POLICY IF EXISTS "Admin full access grupo_precio_productos" ON grupo_precio_productos;
DROP POLICY IF EXISTS "Users can view grupo_precio_productos" ON grupo_precio_productos;

CREATE POLICY mt_grupo_precio_productos_select ON grupo_precio_productos
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_grupo_precio_productos_all ON grupo_precio_productos
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 29. GRUPO_PRECIO_ESCALAS
-- ============================================================

DROP POLICY IF EXISTS "Admin full access grupo_precio_escalas" ON grupo_precio_escalas;
DROP POLICY IF EXISTS "Users can view grupo_precio_escalas" ON grupo_precio_escalas;

CREATE POLICY mt_grupo_precio_escalas_select ON grupo_precio_escalas
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_grupo_precio_escalas_all ON grupo_precio_escalas
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 30. PEDIDOS_ELIMINADOS
-- ============================================================

DROP POLICY IF EXISTS "Admin puede ver pedidos eliminados" ON pedidos_eliminados;
DROP POLICY IF EXISTS "Admin puede insertar pedidos eliminados" ON pedidos_eliminados;
DROP POLICY IF EXISTS "PedidosEliminados: lectura para admin/encargado" ON pedidos_eliminados;

CREATE POLICY mt_pedidos_eliminados_select ON pedidos_eliminados
  FOR SELECT TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_pedidos_eliminados_insert ON pedidos_eliminados
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 31. AUDIT_LOGS
-- ============================================================

DROP POLICY IF EXISTS "audit_logs_insert" ON audit_logs;

CREATE POLICY mt_audit_logs_select ON audit_logs
  FOR SELECT TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_audit_logs_insert ON audit_logs
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 32. ZONAS
-- ============================================================

DROP POLICY IF EXISTS "Zonas: lectura usuarios autenticados" ON zonas;
DROP POLICY IF EXISTS "Zonas: modificacion solo admin" ON zonas;
DROP POLICY IF EXISTS "zonas_select_authenticated" ON zonas;
DROP POLICY IF EXISTS "zonas_insert_authenticated" ON zonas;
DROP POLICY IF EXISTS "zonas_update_authenticated" ON zonas;

CREATE POLICY mt_zonas_select ON zonas
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_zonas_insert ON zonas
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_zonas_update ON zonas
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 33. PREVENTISTA_ZONAS
-- ============================================================

DROP POLICY IF EXISTS "prev_zonas_select_authenticated" ON preventista_zonas;
DROP POLICY IF EXISTS "prev_zonas_insert_authenticated" ON preventista_zonas;
DROP POLICY IF EXISTS "prev_zonas_update_authenticated" ON preventista_zonas;
DROP POLICY IF EXISTS "prev_zonas_delete_authenticated" ON preventista_zonas;

CREATE POLICY mt_preventista_zonas_select ON preventista_zonas
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

CREATE POLICY mt_preventista_zonas_insert ON preventista_zonas
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_preventista_zonas_update ON preventista_zonas
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_preventista_zonas_delete ON preventista_zonas
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());


-- ============================================================
-- 34. HISTORIAL_CAMBIOS
-- ============================================================

DROP POLICY IF EXISTS "Sistema puede insertar historial" ON historial_cambios;

CREATE POLICY mt_historial_cambios_select ON historial_cambios
  FOR SELECT TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());

CREATE POLICY mt_historial_cambios_insert ON historial_cambios
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());
