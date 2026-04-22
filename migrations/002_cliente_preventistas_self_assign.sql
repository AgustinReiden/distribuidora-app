-- 002_cliente_preventistas_self_assign.sql
--
-- Fix sobre 001: la policy cp_insert exigia es_admin(), lo cual bloqueaba el
-- flujo de auto-asignacion cuando un preventista crea un cliente nuevo (el
-- frontend inserta (cliente_id, auth.uid()) inmediatamente despues del INSERT
-- en clientes).
-- Se relaja INSERT para permitir que cualquier usuario autenticado se
-- auto-asigne (preventista_id = auth.uid()). Los admins siguen pudiendo
-- asignar a terceros. UPDATE y DELETE siguen siendo admin-only.

BEGIN;

DROP POLICY IF EXISTS "cp_insert" ON public.cliente_preventistas;
CREATE POLICY "cp_insert"
  ON public.cliente_preventistas
  FOR INSERT TO authenticated
  WITH CHECK (
    public.es_admin()
    OR preventista_id = auth.uid()
  );

COMMIT;
