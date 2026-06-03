-- Migración 079: Descuentos por categoría por cliente
--
-- Hasta ahora un cliente tenía un único descuento general
-- (clientes.descuento_porcentaje). Esto agrega descuentos POR CATEGORÍA por
-- cliente. Regla de negocio (en el front): si un producto pertenece a una
-- categoría con descuento configurado para el cliente, ese descuento PREVALECE
-- sobre el general.
--
-- Se guarda `categoria` como texto (no FK uuid) porque el precio se calcula
-- sobre productos.categoria (texto libre); el match es por nombre normalizado.
-- Espeja el patrón de cliente_preventistas: junction hijo de cliente, sin
-- sucursal_id (la sucursal la da el cliente padre vía su RLS), escritura admin.

BEGIN;

CREATE TABLE IF NOT EXISTS public.cliente_descuentos_categoria (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id           bigint NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  categoria            text NOT NULL,
  descuento_porcentaje numeric(5,2) NOT NULL DEFAULT 0
                         CHECK (descuento_porcentaje >= 0 AND descuento_porcentaje <= 100),
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cliente_id, categoria)
);

CREATE INDEX IF NOT EXISTS idx_cliente_descuentos_categoria_cliente
  ON public.cliente_descuentos_categoria (cliente_id);

ALTER TABLE public.cliente_descuentos_categoria ENABLE ROW LEVEL SECURITY;

-- SELECT: cualquier autenticado (el embed bajo clientes ya queda acotado por la
-- RLS del cliente padre). Escritura: solo admin (editar descuentos es admin-only).
DROP POLICY IF EXISTS cdc_select ON public.cliente_descuentos_categoria;
CREATE POLICY cdc_select ON public.cliente_descuentos_categoria
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS cdc_insert ON public.cliente_descuentos_categoria;
CREATE POLICY cdc_insert ON public.cliente_descuentos_categoria
  FOR INSERT TO authenticated WITH CHECK (es_admin());

DROP POLICY IF EXISTS cdc_update ON public.cliente_descuentos_categoria;
CREATE POLICY cdc_update ON public.cliente_descuentos_categoria
  FOR UPDATE TO authenticated USING (es_admin()) WITH CHECK (es_admin());

DROP POLICY IF EXISTS cdc_delete ON public.cliente_descuentos_categoria;
CREATE POLICY cdc_delete ON public.cliente_descuentos_categoria
  FOR DELETE TO authenticated USING (es_admin());

COMMIT;
