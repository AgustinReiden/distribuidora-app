-- =========================================================================
-- 057_transferencias_rls_bidireccional.sql
--
-- Las transferencias entre sucursales involucran dos sucursales: la que
-- registra el movimiento (`tenant_sucursal_id`) y la contraparte
-- (`sucursal_id`). La RLS actual de SELECT solo permite ver filas donde
-- `tenant_sucursal_id = current_sucursal_id()`, lo cual deja CIEGA a la
-- contraparte:
--
--   * Egreso registrado por A hacia B: tenant=A, sucursal_id=B. Solo A ve.
--   * Ingreso registrado por B desde A: tenant=B, sucursal_id=A. Solo B ve.
--
-- Sintoma reportado: "no veo los movimientos entre sucursales que ya hicimos"
-- — el usuario en B no ve un egreso que le mando A, y viceversa.
--
-- Fix: la policy de SELECT acepta cualquiera de las dos columnas. Las
-- policies de INSERT/UPDATE/DELETE (`mt_transferencias_stock_all`) quedan
-- intactas — solo el tenant que registra puede modificar.
--
-- Tambien se amplia la RLS de `transferencia_items` para que el receptor
-- pueda leer los items via el join, no solo el header.
--
-- Index compuesto adicional sobre (sucursal_id, fecha DESC) para soportar
-- el filtro bidireccional + ORDER BY por fecha.
-- =========================================================================

BEGIN;

-- 1) RLS SELECT bidireccional sobre transferencias_stock
DROP POLICY IF EXISTS "mt_transferencias_stock_select" ON public.transferencias_stock;
CREATE POLICY "mt_transferencias_stock_select"
  ON public.transferencias_stock FOR SELECT TO authenticated
  USING (
    tenant_sucursal_id = public.current_sucursal_id()
    OR sucursal_id = public.current_sucursal_id()
  );

-- 2) RLS SELECT de transferencia_items: permitir lectura si el usuario tiene
--    acceso al header (origen o destino). El INSERT en transferencia_items
--    setea sucursal_id = v_tenant (mig archive 066 linea 620), asi que la
--    policy actual solo cubre al tenant. Aqui usamos EXISTS contra el header
--    para soportar ambas puntas.
DROP POLICY IF EXISTS "mt_transferencia_items_select" ON public.transferencia_items;
CREATE POLICY "mt_transferencia_items_select"
  ON public.transferencia_items FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.transferencias_stock ts
      WHERE ts.id = transferencia_items.transferencia_id
        AND (ts.tenant_sucursal_id = public.current_sucursal_id()
             OR ts.sucursal_id = public.current_sucursal_id())
    )
  );

-- 3) Index compuesto espejo: ya existe (tenant_sucursal_id) pero no
--    (sucursal_id, fecha). Lo agregamos para que la query bidireccional
--    + ORDER BY fecha DESC use index en ambas direcciones.
CREATE INDEX IF NOT EXISTS idx_transferencias_destino_fecha
  ON public.transferencias_stock (sucursal_id, fecha DESC);

COMMIT;
