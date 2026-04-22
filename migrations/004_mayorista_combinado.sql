-- 004_mayorista_combinado.sql
--
-- Habilita escalas de precio mayorista con "activacion combinada":
--   * El grupo puede exigir que la escala solo aplique si hay N productos
--     distintos del grupo presentes en el pedido cumpliendo un minimo
--     individual configurable por producto.
--   * La forma clasica (total del grupo >= cantidad_minima) se mantiene
--     intacta y es el comportamiento default (min_productos_distintos=1,
--     sin filas en grupo_precio_escala_minimos).
--
-- Retrocompat: las escalas existentes quedan como "clasicas" (default 1 y
-- tabla nueva vacia). Sin cambios de comportamiento hasta que el admin
-- marque "Requiere combinacion" en una escala.

BEGIN;

-- 1. Columna: minimo de productos distintos que deben contar para activar
ALTER TABLE public.grupo_precio_escalas
  ADD COLUMN IF NOT EXISTS min_productos_distintos INTEGER NOT NULL DEFAULT 1
    CHECK (min_productos_distintos >= 1);

COMMENT ON COLUMN public.grupo_precio_escalas.min_productos_distintos IS
  'Cantidad minima de productos DISTINTOS del grupo presentes en el pedido (cada uno cumpliendo su minimo individual) para que la escala aplique. Default 1 = comportamiento clasico.';

-- 2. Tabla: minimo individual por producto dentro de una escala combinada
CREATE TABLE IF NOT EXISTS public.grupo_precio_escala_minimos (
  escala_id BIGINT NOT NULL
    REFERENCES public.grupo_precio_escalas(id) ON DELETE CASCADE,
  producto_id BIGINT NOT NULL
    REFERENCES public.productos(id) ON DELETE CASCADE,
  cantidad_minima_por_item INTEGER NOT NULL CHECK (cantidad_minima_por_item > 0),
  sucursal_id BIGINT NOT NULL REFERENCES public.sucursales(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (escala_id, producto_id)
);

COMMENT ON TABLE public.grupo_precio_escala_minimos IS
  'Minimo individual por producto para que cuente hacia la activacion de una escala combinada. Ausencia = sin minimo para ese producto (basta con cantidad > 0 para contar).';

CREATE INDEX IF NOT EXISTS idx_gpem_escala ON public.grupo_precio_escala_minimos(escala_id);
CREATE INDEX IF NOT EXISTS idx_gpem_producto ON public.grupo_precio_escala_minimos(producto_id);

-- 3. RLS: mismo patron que grupo_precio_escalas (admin escribe, todos leen en su sucursal)
ALTER TABLE public.grupo_precio_escala_minimos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "mt_gpem_all" ON public.grupo_precio_escala_minimos;
CREATE POLICY "mt_gpem_all" ON public.grupo_precio_escala_minimos
  TO authenticated
  USING (public.es_admin() AND sucursal_id = public.current_sucursal_id())
  WITH CHECK (public.es_admin() AND sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS "mt_gpem_select" ON public.grupo_precio_escala_minimos;
CREATE POLICY "mt_gpem_select" ON public.grupo_precio_escala_minimos
  FOR SELECT TO authenticated
  USING (sucursal_id = public.current_sucursal_id());

-- 4. Audit trigger (consistente con el resto del sistema)
DROP TRIGGER IF EXISTS audit_grupo_precio_escala_minimos ON public.grupo_precio_escala_minimos;
CREATE TRIGGER audit_grupo_precio_escala_minimos
  AFTER INSERT OR UPDATE OR DELETE ON public.grupo_precio_escala_minimos
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- 5. Grants (mismos que grupo_precio_escalas)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.grupo_precio_escala_minimos TO authenticated;

COMMIT;
