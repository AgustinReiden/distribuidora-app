-- Migration 069: import TP Export proveedores into main as sucursal_id=2.
--
-- Companion to migration 062 (which imported TP productos/pedidos). The TP
-- Export snapshot had 6 proveedor rows; they were deliberately left out of
-- 062 because no productos in TP referenced them (all 69 productos in
-- sucursal=2 have proveedor_id NULL) and no compras were being imported.
-- The user has since asked for the proveedor catalog itself so that Sucursal
-- Tucumán can register new compras against these suppliers post-launch.
--
-- Source: Supabase project distapp-tp, `public.proveedores`, 6 rows, all
-- manually copied into this migration as literals rather than linked via
-- FDW so the migration is self-contained and reproducible from a clean DB.
--
-- Design notes:
--   * IDs are NOT copied from TP — the main sequence allocates fresh ones,
--     which is required because proveedores.id is the PK and sucursal_id=1
--     already occupies low IDs (1,2,4,5,6,7,8,10). Same companies exist in
--     both tenants; each tenant maintains its own list.
--   * No productos in sucursal=2 reference any proveedor, so there is
--     nothing to re-link after insert — IDs can be anything.
--   * zona_id is NULL because TP had no zonas mapped to these suppliers.
--   * Idempotent via NOT EXISTS guard on (sucursal_id=2, cuit) so re-runs
--     against an already-seeded DB are no-ops.

INSERT INTO public.proveedores
  (sucursal_id, nombre, cuit, direccion, telefono, email, contacto, notas, activo, latitud, longitud)
SELECT 2, nombre, cuit, direccion, telefono, email, contacto, notas, activo, latitud, longitud
FROM (VALUES
  ('MANAOS//REFRES NOW S.A.',
   '30708668733',
   'Av. Brig. Gral. Juan Manuel de Rosas 25150, B1763 Virrey del Pino, Provincia de Buenos Aires, Argentina',
   '+5491133194735',
   NULL::varchar,
   'DIEGO GARCIA',
   NULL::text,
   true,
   -34.8647979::numeric,
   -58.66576540000001::numeric),
  ('MOLINOS JOSE LOPEZ//MOLINOS CONFIABLES SRL',
   '30707828133',
   'Manuel Alberti 782, T4000 San Miguel de Tucumán, Tucumán, Argentina',
   '3816495222//3814149465',
   NULL,
   'JUAN MARIA BLAS//RICARDO',
   NULL,
   true,
   NULL,
   NULL),
  ('PAPAS FACU//BE-GON S.R.L.',
   '30708066652',
   'Balcarce 3350, T4101 Tafí Viejo, Tucumán, Argentina',
   NULL,
   NULL,
   NULL,
   NULL,
   true,
   NULL,
   NULL),
  ('AZÚCAR CALIDAD',
   '30000000000',
   'RP301 5, T4105 San Miguel de Tucumán, Tucumán, Argentina',
   NULL,
   NULL,
   NULL,
   NULL,
   true,
   NULL,
   NULL),
  ('FABRICA DE FIDEOS RIVOLI S.A.',
   '33691776919',
   NULL,
   NULL,
   NULL,
   NULL,
   NULL,
   true,
   NULL,
   NULL),
  ('SALTA REFRESCO S.A.',
   '30518408689',
   NULL,
   NULL,
   NULL,
   NULL,
   NULL,
   true,
   NULL,
   NULL)
) AS src(nombre, cuit, direccion, telefono, email, contacto, notas, activo, latitud, longitud)
WHERE NOT EXISTS (
  SELECT 1 FROM public.proveedores p
  WHERE p.sucursal_id = 2 AND p.cuit = src.cuit
);
