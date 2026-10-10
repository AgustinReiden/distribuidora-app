-- =========================================================================
-- El encargado ve las salvedades de su sucursal (#1072)
--
-- La ruta /salvedades deja entrar al encargado (guardasRutas, esAdminOrEncargado)
-- y resolver_salvedad lo deja resolver desde la 252, pero el SELECT de
-- salvedades_items sólo abría a es_admin() o al dueño/transportista del pedido.
-- En prod el encargado (sucursal 2) veía 2 de las 70 salvedades de su sucursal:
-- la pantalla le salía casi vacía, y por los mismos lectores REST el badge de
-- salvedades de Pedidos, el bloqueo de VB con salvedades y el filtro "Con
-- salvedad" le contaban de menos.
--
-- Cambio: es_admin() -> es_encargado_o_admin() en el SELECT de salvedades_items
-- y de salvedad_historial (el mismo hueco; src/ no lee el historial hoy). Nada
-- más:
--   - se conserva `sucursal_id = current_sucursal_id()` (aislamiento) y el
--     camino dueño/transportista del pedido;
--   - INSERT/UPDATE/DELETE no cambian: el encargado resuelve por la RPC
--     SECURITY DEFINER resolver_salvedad;
--   - trampa 4: es_encargado_o_admin() (perfiles.rol IN admin, encargado), NO
--     es_preventista(), que abriría todo al preventista.
--
-- El alcance de rol es el global de perfiles.rol, el mismo que usa
-- resolver_salvedad. El rol por sucursal (usuario_sucursales.rol, el que mira
-- guardasRutas) y el rol extra de perfil_roles quedan fuera a propósito: hoy no
-- muerde (toda usuario_sucursales.rol en prod es 'mismo') y el helper no se toca.
--
-- No crea funciones (no aplica el REVOKE ni check-permisos) ni toca stock.
--
-- Rollback (predicado previo, leído de pg_policies en prod el 2026-10-10):
--   ALTER POLICY mt_salvedades_items_select ON public.salvedades_items USING (
--     (es_admin() OR EXISTS (SELECT 1 FROM pedidos p
--        WHERE p.id = salvedades_items.pedido_id
--          AND (p.usuario_id = auth.uid() OR p.transportista_id = auth.uid())))
--     AND sucursal_id = current_sucursal_id());
--   ALTER POLICY mt_salvedad_historial_select ON public.salvedad_historial USING (
--     (es_admin() OR EXISTS (SELECT 1 FROM salvedades_items si
--        JOIN pedidos p ON p.id = si.pedido_id
--        WHERE si.id = salvedad_historial.salvedad_id
--          AND (p.usuario_id = auth.uid() OR p.transportista_id = auth.uid())))
--     AND sucursal_id = current_sucursal_id());
--
-- Ensayo: scripts/test-salvedades-encargado-1072.sql (falla antes, pasa
-- después).
-- =========================================================================

BEGIN;

ALTER POLICY mt_salvedades_items_select ON public.salvedades_items
USING (
  (es_encargado_o_admin() OR EXISTS (
     SELECT 1 FROM pedidos p
      WHERE p.id = salvedades_items.pedido_id
        AND (p.usuario_id = auth.uid() OR p.transportista_id = auth.uid())))
  AND sucursal_id = current_sucursal_id()
);

ALTER POLICY mt_salvedad_historial_select ON public.salvedad_historial
USING (
  (es_encargado_o_admin() OR EXISTS (
     SELECT 1 FROM salvedades_items si
       JOIN pedidos p ON p.id = si.pedido_id
      WHERE si.id = salvedad_historial.salvedad_id
        AND (p.usuario_id = auth.uid() OR p.transportista_id = auth.uid())))
  AND sucursal_id = current_sucursal_id()
);

COMMIT;
