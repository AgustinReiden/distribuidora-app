-- ============================================================================
-- 050 — Rol "preventista_taco" + descuento_porcentaje en clientes
-- ============================================================================
-- Cambios:
--   1. Nuevo rol 'preventista_taco' en el CHECK constraint perfiles_rol_check.
--      Es operativamente como 'preventista' (carga pedidos, ve clientes), pero
--      la UI le oculta toda informacion comercial agregada (ventas, saldos,
--      historicos de compra). El gating duro de UI vive en permisos.ts; este
--      constraint solo habilita persistir el rol.
--
--   2. Nueva columna clientes.descuento_porcentaje (0..100). Solo admin la edita
--      desde la ficha. Se aplica como descuento por linea al precio_unitario
--      cuando un usuario arma un pedido para este cliente.
-- ============================================================================

BEGIN;

-- 1) Extender CHECK constraint para incluir preventista_taco
ALTER TABLE public.perfiles DROP CONSTRAINT IF EXISTS perfiles_rol_check;

ALTER TABLE public.perfiles
  ADD CONSTRAINT perfiles_rol_check
  CHECK (rol = ANY (ARRAY[
    'admin',
    'preventista',
    'preventista_taco',
    'transportista',
    'deposito',
    'encargado'
  ]::text[]));

-- 2) Columna descuento_porcentaje en clientes
ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS descuento_porcentaje numeric(5,2) NOT NULL DEFAULT 0
  CHECK (descuento_porcentaje >= 0 AND descuento_porcentaje <= 100);

COMMENT ON COLUMN public.clientes.descuento_porcentaje IS
  'Descuento porcentual precargado por el admin. Se aplica al precio_unitario al armar pedidos.';

COMMIT;
