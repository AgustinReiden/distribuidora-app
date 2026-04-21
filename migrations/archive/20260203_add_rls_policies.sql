-- =============================================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- =============================================================================
-- Este archivo contiene las políticas de seguridad a nivel de fila para
-- proteger los datos en la base de datos de Supabase.
--
-- IMPORTANTE: Este script es IDEMPOTENTE y SEGURO - verifica que cada tabla
-- exista antes de aplicar políticas.
-- =============================================================================

-- =============================================================================
-- FUNCIÓN HELPER: Obtener rol del usuario actual
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS TEXT AS $$
  SELECT rol FROM public.perfiles WHERE id = auth.uid();
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol = 'admin'
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_preventista()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'preventista')
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_transportista()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'transportista')
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

-- =============================================================================
-- TABLA: perfiles
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'perfiles') THEN
    ALTER TABLE public.perfiles ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "perfiles_select_all" ON public.perfiles;
    DROP POLICY IF EXISTS "perfiles_insert_admin" ON public.perfiles;
    DROP POLICY IF EXISTS "perfiles_update_admin" ON public.perfiles;
    DROP POLICY IF EXISTS "perfiles_delete_admin" ON public.perfiles;
    DROP POLICY IF EXISTS "perfiles_update_self" ON public.perfiles;

    CREATE POLICY "perfiles_select_all" ON public.perfiles
      FOR SELECT USING (true);

    CREATE POLICY "perfiles_insert_admin" ON public.perfiles
      FOR INSERT WITH CHECK (public.is_admin());

    CREATE POLICY "perfiles_update_admin" ON public.perfiles
      FOR UPDATE USING (public.is_admin());

    CREATE POLICY "perfiles_delete_admin" ON public.perfiles
      FOR DELETE USING (public.is_admin());

    CREATE POLICY "perfiles_update_self" ON public.perfiles
      FOR UPDATE USING (id = auth.uid())
      WITH CHECK (id = auth.uid());

    RAISE NOTICE 'RLS aplicado a: perfiles';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: perfiles';
  END IF;
END $$;

-- =============================================================================
-- TABLA: clientes
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'clientes') THEN
    ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "clientes_select" ON public.clientes;
    DROP POLICY IF EXISTS "clientes_select_transportista" ON public.clientes;
    DROP POLICY IF EXISTS "clientes_insert" ON public.clientes;
    DROP POLICY IF EXISTS "clientes_update" ON public.clientes;
    DROP POLICY IF EXISTS "clientes_delete" ON public.clientes;

    CREATE POLICY "clientes_select" ON public.clientes
      FOR SELECT USING (public.is_preventista());

    CREATE POLICY "clientes_select_transportista" ON public.clientes
      FOR SELECT USING (
        public.get_user_role() = 'transportista' AND
        EXISTS (
          SELECT 1 FROM public.pedidos
          WHERE pedidos.cliente_id = clientes.id
            AND pedidos.transportista_id = auth.uid()
        )
      );

    CREATE POLICY "clientes_insert" ON public.clientes
      FOR INSERT WITH CHECK (public.is_preventista());

    CREATE POLICY "clientes_update" ON public.clientes
      FOR UPDATE USING (public.is_preventista());

    CREATE POLICY "clientes_delete" ON public.clientes
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: clientes';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: clientes';
  END IF;
END $$;

-- =============================================================================
-- TABLA: productos
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'productos') THEN
    ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "productos_select" ON public.productos;
    DROP POLICY IF EXISTS "productos_insert" ON public.productos;
    DROP POLICY IF EXISTS "productos_update" ON public.productos;
    DROP POLICY IF EXISTS "productos_delete" ON public.productos;

    CREATE POLICY "productos_select" ON public.productos
      FOR SELECT USING (auth.uid() IS NOT NULL);

    CREATE POLICY "productos_insert" ON public.productos
      FOR INSERT WITH CHECK (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "productos_update" ON public.productos
      FOR UPDATE USING (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "productos_delete" ON public.productos
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: productos';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: productos';
  END IF;
END $$;

-- =============================================================================
-- TABLA: pedidos
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'pedidos') THEN
    ALTER TABLE public.pedidos ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "pedidos_select_admin" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_select_preventista" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_select_transportista" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_select_deposito" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_insert" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_update_admin" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_update_preventista" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_update_transportista" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_update_deposito" ON public.pedidos;
    DROP POLICY IF EXISTS "pedidos_delete" ON public.pedidos;

    CREATE POLICY "pedidos_select_admin" ON public.pedidos
      FOR SELECT USING (public.is_admin());

    CREATE POLICY "pedidos_select_preventista" ON public.pedidos
      FOR SELECT USING (
        public.get_user_role() = 'preventista' AND
        usuario_id = auth.uid()
      );

    CREATE POLICY "pedidos_select_transportista" ON public.pedidos
      FOR SELECT USING (
        public.get_user_role() = 'transportista' AND
        transportista_id = auth.uid()
      );

    CREATE POLICY "pedidos_select_deposito" ON public.pedidos
      FOR SELECT USING (
        public.get_user_role() = 'deposito' AND
        estado IN ('pendiente', 'en_preparacion', 'preparado')
      );

    CREATE POLICY "pedidos_insert" ON public.pedidos
      FOR INSERT WITH CHECK (public.is_preventista());

    CREATE POLICY "pedidos_update_admin" ON public.pedidos
      FOR UPDATE USING (public.is_admin());

    CREATE POLICY "pedidos_update_preventista" ON public.pedidos
      FOR UPDATE USING (
        public.get_user_role() = 'preventista' AND
        usuario_id = auth.uid() AND
        estado NOT IN ('entregado', 'cancelado')
      );

    CREATE POLICY "pedidos_update_transportista" ON public.pedidos
      FOR UPDATE USING (
        public.get_user_role() = 'transportista' AND
        transportista_id = auth.uid()
      );

    CREATE POLICY "pedidos_update_deposito" ON public.pedidos
      FOR UPDATE USING (
        public.get_user_role() = 'deposito' AND
        estado IN ('pendiente', 'en_preparacion')
      );

    CREATE POLICY "pedidos_delete" ON public.pedidos
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: pedidos';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: pedidos';
  END IF;
END $$;

-- =============================================================================
-- TABLA: pedido_items
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'pedido_items') THEN
    ALTER TABLE public.pedido_items ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "pedido_items_select" ON public.pedido_items;
    DROP POLICY IF EXISTS "pedido_items_insert" ON public.pedido_items;
    DROP POLICY IF EXISTS "pedido_items_update" ON public.pedido_items;
    DROP POLICY IF EXISTS "pedido_items_delete" ON public.pedido_items;

    CREATE POLICY "pedido_items_select" ON public.pedido_items
      FOR SELECT USING (
        EXISTS (
          SELECT 1 FROM public.pedidos
          WHERE pedidos.id = pedido_items.pedido_id
        )
      );

    CREATE POLICY "pedido_items_insert" ON public.pedido_items
      FOR INSERT WITH CHECK (public.is_preventista());

    CREATE POLICY "pedido_items_update" ON public.pedido_items
      FOR UPDATE USING (
        EXISTS (
          SELECT 1 FROM public.pedidos
          WHERE pedidos.id = pedido_items.pedido_id
            AND (public.is_admin() OR pedidos.usuario_id = auth.uid())
        )
      );

    CREATE POLICY "pedido_items_delete" ON public.pedido_items
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: pedido_items';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: pedido_items';
  END IF;
END $$;

-- =============================================================================
-- TABLA: pagos
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'pagos') THEN
    ALTER TABLE public.pagos ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "pagos_select_admin" ON public.pagos;
    DROP POLICY IF EXISTS "pagos_select_preventista" ON public.pagos;
    DROP POLICY IF EXISTS "pagos_insert" ON public.pagos;
    DROP POLICY IF EXISTS "pagos_update" ON public.pagos;
    DROP POLICY IF EXISTS "pagos_delete" ON public.pagos;

    CREATE POLICY "pagos_select_admin" ON public.pagos
      FOR SELECT USING (public.is_admin());

    CREATE POLICY "pagos_select_preventista" ON public.pagos
      FOR SELECT USING (
        public.get_user_role() = 'preventista' AND
        usuario_id = auth.uid()
      );

    CREATE POLICY "pagos_insert" ON public.pagos
      FOR INSERT WITH CHECK (public.is_preventista());

    CREATE POLICY "pagos_update" ON public.pagos
      FOR UPDATE USING (public.is_admin());

    CREATE POLICY "pagos_delete" ON public.pagos
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: pagos';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: pagos';
  END IF;
END $$;

-- =============================================================================
-- TABLA: compras
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'compras') THEN
    ALTER TABLE public.compras ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "compras_select" ON public.compras;
    DROP POLICY IF EXISTS "compras_insert" ON public.compras;
    DROP POLICY IF EXISTS "compras_update" ON public.compras;
    DROP POLICY IF EXISTS "compras_delete" ON public.compras;

    CREATE POLICY "compras_select" ON public.compras
      FOR SELECT USING (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "compras_insert" ON public.compras
      FOR INSERT WITH CHECK (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "compras_update" ON public.compras
      FOR UPDATE USING (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "compras_delete" ON public.compras
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: compras';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: compras';
  END IF;
END $$;

-- =============================================================================
-- TABLA: compra_items
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'compra_items') THEN
    ALTER TABLE public.compra_items ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "compra_items_select" ON public.compra_items;
    DROP POLICY IF EXISTS "compra_items_insert" ON public.compra_items;
    DROP POLICY IF EXISTS "compra_items_update" ON public.compra_items;
    DROP POLICY IF EXISTS "compra_items_delete" ON public.compra_items;

    CREATE POLICY "compra_items_select" ON public.compra_items
      FOR SELECT USING (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "compra_items_insert" ON public.compra_items
      FOR INSERT WITH CHECK (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "compra_items_update" ON public.compra_items
      FOR UPDATE USING (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "compra_items_delete" ON public.compra_items
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: compra_items';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: compra_items';
  END IF;
END $$;

-- =============================================================================
-- TABLA: proveedores
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'proveedores') THEN
    ALTER TABLE public.proveedores ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "proveedores_select" ON public.proveedores;
    DROP POLICY IF EXISTS "proveedores_insert" ON public.proveedores;
    DROP POLICY IF EXISTS "proveedores_update" ON public.proveedores;
    DROP POLICY IF EXISTS "proveedores_delete" ON public.proveedores;

    CREATE POLICY "proveedores_select" ON public.proveedores
      FOR SELECT USING (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "proveedores_insert" ON public.proveedores
      FOR INSERT WITH CHECK (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "proveedores_update" ON public.proveedores
      FOR UPDATE USING (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "proveedores_delete" ON public.proveedores
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: proveedores';
  ELSE
    RAISE NOTICE 'Tabla no encontrada: proveedores';
  END IF;
END $$;

-- =============================================================================
-- TABLA: mermas (opcional)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'mermas') THEN
    ALTER TABLE public.mermas ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "mermas_select" ON public.mermas;
    DROP POLICY IF EXISTS "mermas_insert" ON public.mermas;
    DROP POLICY IF EXISTS "mermas_update" ON public.mermas;
    DROP POLICY IF EXISTS "mermas_delete" ON public.mermas;

    CREATE POLICY "mermas_select" ON public.mermas
      FOR SELECT USING (
        public.is_admin() OR public.get_user_role() = 'deposito'
      );

    CREATE POLICY "mermas_insert" ON public.mermas
      FOR INSERT WITH CHECK (
        public.is_admin() OR
        public.get_user_role() = 'deposito' OR
        public.get_user_role() = 'transportista'
      );

    CREATE POLICY "mermas_update" ON public.mermas
      FOR UPDATE USING (public.is_admin());

    CREATE POLICY "mermas_delete" ON public.mermas
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: mermas';
  ELSE
    RAISE NOTICE 'Tabla no encontrada (opcional): mermas';
  END IF;
END $$;

-- =============================================================================
-- TABLA: recorridos (opcional)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'recorridos') THEN
    ALTER TABLE public.recorridos ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "recorridos_select_admin" ON public.recorridos;
    DROP POLICY IF EXISTS "recorridos_select_transportista" ON public.recorridos;
    DROP POLICY IF EXISTS "recorridos_insert" ON public.recorridos;
    DROP POLICY IF EXISTS "recorridos_update" ON public.recorridos;
    DROP POLICY IF EXISTS "recorridos_delete" ON public.recorridos;

    CREATE POLICY "recorridos_select_admin" ON public.recorridos
      FOR SELECT USING (public.is_admin());

    CREATE POLICY "recorridos_select_transportista" ON public.recorridos
      FOR SELECT USING (
        public.get_user_role() = 'transportista' AND
        transportista_id = auth.uid()
      );

    CREATE POLICY "recorridos_insert" ON public.recorridos
      FOR INSERT WITH CHECK (public.is_admin());

    CREATE POLICY "recorridos_update" ON public.recorridos
      FOR UPDATE USING (
        public.is_admin() OR
        (public.get_user_role() = 'transportista' AND transportista_id = auth.uid())
      );

    CREATE POLICY "recorridos_delete" ON public.recorridos
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: recorridos';
  ELSE
    RAISE NOTICE 'Tabla no encontrada (opcional): recorridos';
  END IF;
END $$;

-- =============================================================================
-- TABLA: rendiciones (opcional)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'rendiciones') THEN
    ALTER TABLE public.rendiciones ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "rendiciones_select_admin" ON public.rendiciones;
    DROP POLICY IF EXISTS "rendiciones_select_transportista" ON public.rendiciones;
    DROP POLICY IF EXISTS "rendiciones_insert" ON public.rendiciones;
    DROP POLICY IF EXISTS "rendiciones_update" ON public.rendiciones;
    DROP POLICY IF EXISTS "rendiciones_delete" ON public.rendiciones;

    CREATE POLICY "rendiciones_select_admin" ON public.rendiciones
      FOR SELECT USING (public.is_admin());

    CREATE POLICY "rendiciones_select_transportista" ON public.rendiciones
      FOR SELECT USING (
        public.get_user_role() = 'transportista' AND
        transportista_id = auth.uid()
      );

    CREATE POLICY "rendiciones_insert" ON public.rendiciones
      FOR INSERT WITH CHECK (
        public.is_admin() OR
        (public.get_user_role() = 'transportista' AND transportista_id = auth.uid())
      );

    CREATE POLICY "rendiciones_update" ON public.rendiciones
      FOR UPDATE USING (
        public.is_admin() OR
        (public.get_user_role() = 'transportista' AND
         transportista_id = auth.uid() AND
         estado IN ('pendiente', 'con_observaciones'))
      );

    CREATE POLICY "rendiciones_delete" ON public.rendiciones
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: rendiciones';
  ELSE
    RAISE NOTICE 'Tabla no encontrada (opcional): rendiciones';
  END IF;
END $$;

-- =============================================================================
-- TABLA: salvedades (opcional)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'salvedades') THEN
    ALTER TABLE public.salvedades ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "salvedades_select_admin" ON public.salvedades;
    DROP POLICY IF EXISTS "salvedades_select_transportista" ON public.salvedades;
    DROP POLICY IF EXISTS "salvedades_insert" ON public.salvedades;
    DROP POLICY IF EXISTS "salvedades_update" ON public.salvedades;
    DROP POLICY IF EXISTS "salvedades_delete" ON public.salvedades;

    EXECUTE 'CREATE POLICY "salvedades_select_admin" ON public.salvedades FOR SELECT USING (public.is_admin())';

    EXECUTE 'CREATE POLICY "salvedades_select_transportista" ON public.salvedades
      FOR SELECT USING (
        public.get_user_role() = ''transportista'' AND
        EXISTS (
          SELECT 1 FROM public.pedidos
          WHERE pedidos.id = salvedades.pedido_id
            AND pedidos.transportista_id = auth.uid()
        )
      )';

    EXECUTE 'CREATE POLICY "salvedades_insert" ON public.salvedades
      FOR INSERT WITH CHECK (
        public.is_admin() OR public.get_user_role() = ''transportista''
      )';

    EXECUTE 'CREATE POLICY "salvedades_update" ON public.salvedades
      FOR UPDATE USING (public.is_admin())';

    EXECUTE 'CREATE POLICY "salvedades_delete" ON public.salvedades
      FOR DELETE USING (public.is_admin())';

    RAISE NOTICE 'RLS aplicado a: salvedades';
  ELSE
    RAISE NOTICE 'Tabla no encontrada (opcional): salvedades';
  END IF;
END $$;

-- =============================================================================
-- TABLA: salvedades_items (opcional)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'salvedades_items') THEN
    ALTER TABLE public.salvedades_items ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "salvedades_items_select" ON public.salvedades_items;
    DROP POLICY IF EXISTS "salvedades_items_insert" ON public.salvedades_items;
    DROP POLICY IF EXISTS "salvedades_items_update" ON public.salvedades_items;
    DROP POLICY IF EXISTS "salvedades_items_delete" ON public.salvedades_items;

    CREATE POLICY "salvedades_items_select" ON public.salvedades_items
      FOR SELECT USING (auth.uid() IS NOT NULL);

    EXECUTE 'CREATE POLICY "salvedades_items_insert" ON public.salvedades_items
      FOR INSERT WITH CHECK (public.is_admin() OR public.get_user_role() = ''transportista'')';

    CREATE POLICY "salvedades_items_update" ON public.salvedades_items
      FOR UPDATE USING (public.is_admin());

    CREATE POLICY "salvedades_items_delete" ON public.salvedades_items
      FOR DELETE USING (public.is_admin());

    RAISE NOTICE 'RLS aplicado a: salvedades_items';
  ELSE
    RAISE NOTICE 'Tabla no encontrada (opcional): salvedades_items';
  END IF;
END $$;

-- =============================================================================
-- TABLA: pedido_historial (opcional)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'pedido_historial') THEN
    ALTER TABLE public.pedido_historial ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "pedido_historial_select" ON public.pedido_historial;
    DROP POLICY IF EXISTS "pedido_historial_insert" ON public.pedido_historial;

    CREATE POLICY "pedido_historial_select" ON public.pedido_historial
      FOR SELECT USING (auth.uid() IS NOT NULL);

    CREATE POLICY "pedido_historial_insert" ON public.pedido_historial
      FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

    RAISE NOTICE 'RLS aplicado a: pedido_historial';
  ELSE
    RAISE NOTICE 'Tabla no encontrada (opcional): pedido_historial';
  END IF;
END $$;

-- =============================================================================
-- TABLA: historial_pedidos (alias, opcional)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'historial_pedidos') THEN
    ALTER TABLE public.historial_pedidos ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "historial_pedidos_select" ON public.historial_pedidos;
    DROP POLICY IF EXISTS "historial_pedidos_insert" ON public.historial_pedidos;

    CREATE POLICY "historial_pedidos_select" ON public.historial_pedidos
      FOR SELECT USING (auth.uid() IS NOT NULL);

    CREATE POLICY "historial_pedidos_insert" ON public.historial_pedidos
      FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

    RAISE NOTICE 'RLS aplicado a: historial_pedidos';
  ELSE
    RAISE NOTICE 'Tabla no encontrada (opcional): historial_pedidos';
  END IF;
END $$;

-- =============================================================================
-- TABLA: pedidos_eliminados (opcional)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'pedidos_eliminados') THEN
    ALTER TABLE public.pedidos_eliminados ENABLE ROW LEVEL SECURITY;

    DROP POLICY IF EXISTS "pedidos_eliminados_select" ON public.pedidos_eliminados;
    DROP POLICY IF EXISTS "pedidos_eliminados_insert" ON public.pedidos_eliminados;

    CREATE POLICY "pedidos_eliminados_select" ON public.pedidos_eliminados
      FOR SELECT USING (public.is_admin());

    CREATE POLICY "pedidos_eliminados_insert" ON public.pedidos_eliminados
      FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

    RAISE NOTICE 'RLS aplicado a: pedidos_eliminados';
  ELSE
    RAISE NOTICE 'Tabla no encontrada (opcional): pedidos_eliminados';
  END IF;
END $$;

-- =============================================================================
-- GRANT USAGE
-- =============================================================================

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;

-- =============================================================================
-- FIN DE MIGRACIÓN RLS
-- =============================================================================

DO $$
BEGIN
  RAISE NOTICE '===========================================';
  RAISE NOTICE 'Migración RLS completada exitosamente';
  RAISE NOTICE '===========================================';
END $$;
