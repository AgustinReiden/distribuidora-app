-- Fix: Security audit - function search_path mutable + overly permissive RLS policies
--
-- Problems fixed:
-- 1. 46 functions missing SET search_path = public (search_path mutable vulnerability)
-- 2. 9 RLS policies using USING(true) or WITH CHECK(true) for INSERT/UPDATE/DELETE
--
-- Note: "Leaked Password Protection" must be enabled manually in Supabase Dashboard:
--   Auth > Providers > Email > "Prevent use of leaked passwords"
--   (Requires Pro Plan)

----------------------------------------------------------------------
-- PART 1: Fix search_path for all functions missing it
----------------------------------------------------------------------

-- Trigger functions (no args)
ALTER FUNCTION public.actualizar_estado_pago_pedido() SET search_path = public;
ALTER FUNCTION public.actualizar_recorrido_entrega() SET search_path = public;
ALTER FUNCTION public.actualizar_saldo_cliente() SET search_path = public;
ALTER FUNCTION public.actualizar_saldo_pedido() SET search_path = public;
ALTER FUNCTION public.audit_log_changes() SET search_path = public;
ALTER FUNCTION public.registrar_cambio_pedido() SET search_path = public;
ALTER FUNCTION public.registrar_cambio_stock() SET search_path = public;
ALTER FUNCTION public.registrar_creacion_pedido() SET search_path = public;
ALTER FUNCTION public.update_compras_updated_at() SET search_path = public;
ALTER FUNCTION public.update_grupos_precio_updated_at() SET search_path = public;
ALTER FUNCTION public.update_productos_updated_at() SET search_path = public;
ALTER FUNCTION public.update_rendiciones_updated_at() SET search_path = public;
ALTER FUNCTION public.update_salvedades_updated_at() SET search_path = public;
ALTER FUNCTION public.handle_new_user() SET search_path = public;

-- Role-checking helper functions (no args)
ALTER FUNCTION public.es_admin() SET search_path = public;
ALTER FUNCTION public.es_admin_rendiciones() SET search_path = public;
ALTER FUNCTION public.es_admin_salvedades() SET search_path = public;
ALTER FUNCTION public.es_preventista() SET search_path = public;
ALTER FUNCTION public.es_transportista() SET search_path = public;
ALTER FUNCTION public.es_transportista_rendiciones() SET search_path = public;
ALTER FUNCTION public.get_mi_rol() SET search_path = public;
ALTER FUNCTION public.get_user_role() SET search_path = public;
ALTER FUNCTION public.is_admin() SET search_path = public;
ALTER FUNCTION public.is_preventista() SET search_path = public;
ALTER FUNCTION public.is_transportista() SET search_path = public;

-- Business logic functions (with args)
ALTER FUNCTION public.actualizar_orden_entrega_batch(ordenes jsonb) SET search_path = public;
ALTER FUNCTION public.actualizar_orden_entrega_batch(ordenes orden_entrega_item[]) SET search_path = public;
ALTER FUNCTION public.actualizar_pedido_items(p_pedido_id bigint, p_items_nuevos jsonb, p_usuario_id uuid) SET search_path = public;
ALTER FUNCTION public.actualizar_precios_masivo(p_productos jsonb) SET search_path = public;
ALTER FUNCTION public.anular_salvedad(p_salvedad_id bigint, p_notas text) SET search_path = public;
ALTER FUNCTION public.crear_recorrido(p_transportista_id uuid, p_pedidos jsonb, p_distancia numeric, p_duracion integer) SET search_path = public;
ALTER FUNCTION public.crear_rendicion_recorrido(p_recorrido_id bigint, p_transportista_id uuid) SET search_path = public;
ALTER FUNCTION public.eliminar_pedido_completo(p_pedido_id bigint, p_restaurar_stock boolean, p_usuario_id uuid, p_motivo text) SET search_path = public;
ALTER FUNCTION public.eliminar_proveedor(p_proveedor_id bigint) SET search_path = public;
ALTER FUNCTION public.get_audit_history(p_tabla text, p_registro_id text, p_limit integer) SET search_path = public;
ALTER FUNCTION public.get_suspicious_activity(p_days integer) SET search_path = public;
ALTER FUNCTION public.limpiar_orden_entrega(p_transportista_id uuid) SET search_path = public;
ALTER FUNCTION public.obtener_estadisticas_pedidos(p_fecha_desde timestamptz, p_fecha_hasta timestamptz, p_usuario_id uuid) SET search_path = public;
ALTER FUNCTION public.obtener_estadisticas_rendiciones(p_fecha_desde date, p_fecha_hasta date, p_transportista_id uuid) SET search_path = public;
ALTER FUNCTION public.obtener_resumen_compras(p_fecha_desde date, p_fecha_hasta date) SET search_path = public;
ALTER FUNCTION public.presentar_rendicion(p_rendicion_id bigint, p_monto_rendido numeric, p_justificacion text) SET search_path = public;
ALTER FUNCTION public.registrar_compra_completa(p_proveedor_id bigint, p_proveedor_nombre varchar, p_numero_factura varchar, p_fecha_compra date, p_subtotal numeric, p_iva numeric, p_otros_impuestos numeric, p_total numeric, p_forma_pago varchar, p_notas text, p_usuario_id uuid, p_items jsonb) SET search_path = public;
ALTER FUNCTION public.registrar_salvedad(p_pedido_id bigint, p_pedido_item_id bigint, p_cantidad_afectada integer, p_motivo varchar, p_descripcion text, p_foto_url text, p_devolver_stock boolean) SET search_path = public;
ALTER FUNCTION public.resolver_salvedad(p_salvedad_id bigint, p_estado_resolucion varchar, p_notas text, p_pedido_reprogramado_id bigint) SET search_path = public;
ALTER FUNCTION public.revisar_rendicion(p_rendicion_id bigint, p_accion varchar, p_observaciones text) SET search_path = public;
ALTER FUNCTION public.run_sql(query text) SET search_path = public;

----------------------------------------------------------------------
-- PART 2: Fix overly permissive RLS policies
----------------------------------------------------------------------

-- audit_logs: INSERT restricted to admin (trigger functions are SECURITY DEFINER, bypass RLS)
DROP POLICY IF EXISTS "audit_logs_insert" ON public.audit_logs;
CREATE POLICY "audit_logs_insert" ON public.audit_logs
  FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  );

-- historial_cambios: INSERT restricted to admin (trigger functions bypass RLS)
DROP POLICY IF EXISTS "Sistema puede insertar historial" ON public.historial_cambios;
CREATE POLICY "Sistema puede insertar historial" ON public.historial_cambios
  FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  );

-- salvedad_historial: INSERT restricted to admin/transportista
DROP POLICY IF EXISTS "Insertar historial" ON public.salvedad_historial;
CREATE POLICY "Insertar historial" ON public.salvedad_historial
  FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol IN ('admin', 'transportista'))
  );

-- stock_historico: INSERT restricted to admin/deposito (trigger functions bypass RLS)
DROP POLICY IF EXISTS "stock_historico_insert" ON public.stock_historico;
CREATE POLICY "stock_historico_insert" ON public.stock_historico
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol IN ('admin', 'deposito'))
  );

-- preventista_zonas: INSERT/UPDATE/DELETE restricted to admin only
DROP POLICY IF EXISTS "prev_zonas_insert_authenticated" ON public.preventista_zonas;
CREATE POLICY "prev_zonas_insert_authenticated" ON public.preventista_zonas
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  );

DROP POLICY IF EXISTS "prev_zonas_update_authenticated" ON public.preventista_zonas;
CREATE POLICY "prev_zonas_update_authenticated" ON public.preventista_zonas
  FOR UPDATE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  );

DROP POLICY IF EXISTS "prev_zonas_delete_authenticated" ON public.preventista_zonas;
CREATE POLICY "prev_zonas_delete_authenticated" ON public.preventista_zonas
  FOR DELETE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  );

-- zonas: INSERT/UPDATE restricted to admin only
DROP POLICY IF EXISTS "zonas_insert_authenticated" ON public.zonas;
CREATE POLICY "zonas_insert_authenticated" ON public.zonas
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  );

DROP POLICY IF EXISTS "zonas_update_authenticated" ON public.zonas;
CREATE POLICY "zonas_update_authenticated" ON public.zonas
  FOR UPDATE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'admin')
  );
