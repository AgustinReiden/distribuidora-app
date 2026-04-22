-- Permitir a admin/encargado ver las asignaciones usuario↔sucursal de su sucursal activa.
--
-- Antes:
--   - usuario_sucursales_admin_all: admin ve todas las filas (cualquier sucursal).
--   - usuario_sucursales_select_own: usuarios solo ven sus propias filas.
--
-- Problema: encargados no podían ver qué preventistas pertenecen a su sucursal,
-- por lo que el selector de preventista en ModalCliente y el panel de usuarios
-- traían perfiles sin filtro de sucursal (o vacío al intentar JOIN).
--
-- Fix: agregar policy de SELECT para admin/encargado que permita ver filas
-- cuya sucursal_id coincida con current_sucursal_id() (resuelto vía header
-- x-sucursal-id seteado por el frontend en cada request).
--
-- Efecto: el inner join `perfiles → usuario_sucursales` filtrado por sucursal
-- activa ahora devuelve los usuarios correctos para admin/encargado sin filtrar
-- data de otras sucursales.

DROP POLICY IF EXISTS "usuario_sucursales_select_sucursal_activa" ON public.usuario_sucursales;

CREATE POLICY "usuario_sucursales_select_sucursal_activa"
ON public.usuario_sucursales
FOR SELECT
TO authenticated
USING (
  sucursal_id = current_sucursal_id()
  AND EXISTS (
    SELECT 1 FROM perfiles p
    WHERE p.id = auth.uid()
      AND p.rol IN ('admin', 'encargado')
  )
);
