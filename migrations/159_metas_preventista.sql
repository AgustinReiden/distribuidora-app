-- =========================================================================
-- 159_metas_preventista.sql
--
-- "Quiero ponerles objetivo a los preventistas y que los vean en la app en
--  tiempo real: 2 millones de Manaos al mes, y de esos 2 millones, 100
--  gaseosas de 3 litros. Después les pago un básico, la comisión y un monto
--  por objetivo cumplido."
--
-- `metas_gerenciales` (mig 108) no sirve para esto: sus dimensiones son
-- (sucursal, periodo, metrica ∈ {venta, margen_neto}). No tiene preventista ni
-- alcance por marca/categoría/producto.
--
-- Se sigue el precedente de `comision_reglas` (mig 150): lectura por RLS,
-- escritura sólo por RPC SECURITY DEFINER, baja lógica en vez de DELETE.
--
-- DIFERENCIA DELIBERADA con metas_gerenciales/comision_reglas: acá
-- `sucursal_id` es NOT NULL. Una meta "de toda la red" para una persona no
-- significa nada —un preventista trabaja en una sucursal— y con NULL el índice
-- único y el filtro del avance se complican al pedo.
--
-- DECISIÓN: no hay columna `unidad` ($ vs unidades). Se deduce de `tipo_meta`.
-- Una columna redundante con tipo_meta es una fuente garantizada de filas
-- inconsistentes.
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.metas_preventista (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sucursal_id    bigint NOT NULL REFERENCES sucursales(id),
  preventista_id uuid   NOT NULL REFERENCES perfiles(id),
  periodo        date   NOT NULL,          -- primer día del mes
  tipo_meta      text   NOT NULL,
  -- Alcance: como mucho UNO no nulo. Todos NULL = la meta es global.
  marca_id       uuid   REFERENCES marcas(id) ON DELETE CASCADE,
  categoria_id   uuid   REFERENCES categorias(id) ON DELETE CASCADE,
  producto_id    bigint REFERENCES productos(id) ON DELETE CASCADE,
  valor_objetivo numeric NOT NULL CHECK (valor_objetivo > 0),
  activo         boolean NOT NULL DEFAULT true,
  usuario_id     uuid,                     -- quién la cargó
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT metas_preventista_tipo_check CHECK (
    tipo_meta IN ('facturacion', 'unidades', 'cobertura', 'clientes_nuevos')
  ),
  -- Un solo eje de alcance: "Manaos gaseosas" se pide con dos metas, no con
  -- una fila ambigua cuya intersección nadie sabe leer.
  CONSTRAINT metas_preventista_alcance_unico CHECK (
    (marca_id IS NOT NULL)::int
    + (categoria_id IS NOT NULL)::int
    + (producto_id IS NOT NULL)::int <= 1
  ),
  -- Cobertura y clientes nuevos se cuentan sobre clientes, no sobre productos.
  CONSTRAINT metas_preventista_alcance_valido CHECK (
    tipo_meta IN ('facturacion', 'unidades')
    OR (marca_id IS NULL AND categoria_id IS NULL AND producto_id IS NULL)
  ),
  -- "100 unidades" sin decir de qué no es una meta.
  CONSTRAINT metas_preventista_unidades_check CHECK (
    tipo_meta <> 'unidades'
    OR marca_id IS NOT NULL OR categoria_id IS NOT NULL OR producto_id IS NOT NULL
  )
);

COMMENT ON TABLE public.metas_preventista IS
  'Objetivos mensuales por preventista. tipo_meta define la unidad ($ para facturacion, unidades para unidades, clientes para cobertura/clientes_nuevos). marca_id/categoria_id/producto_id: como mucho uno, NULL = meta global. Mig 159.';

-- COALESCE en el índice único (patrón de metas_gerenciales_uidx): sin esto, dos
-- metas globales del mismo tipo y mes se duplicarían, porque NULL <> NULL.
CREATE UNIQUE INDEX IF NOT EXISTS metas_preventista_uidx
  ON public.metas_preventista (
    preventista_id, periodo, tipo_meta,
    COALESCE(marca_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(categoria_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(producto_id, -1)
  );

CREATE INDEX IF NOT EXISTS metas_preventista_periodo_idx
  ON public.metas_preventista (sucursal_id, periodo, activo);

-- El avance se calcula filtrando pedidos por (usuario_id, fecha, estado). El
-- gerencial indexa por sucursal_id, que no sirve para esta consulta.
CREATE INDEX IF NOT EXISTS pedidos_usuario_fecha_idx
  ON public.pedidos (usuario_id, fecha, estado);

CREATE OR REPLACE FUNCTION public.metas_preventista_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_metas_preventista_updated_at ON public.metas_preventista;
CREATE TRIGGER trg_metas_preventista_updated_at
  BEFORE UPDATE ON public.metas_preventista
  FOR EACH ROW
  EXECUTE FUNCTION public.metas_preventista_set_updated_at();

-- -------------------------------------------------------------------------
-- RLS. Dos policies de SELECT: se combinan con OR, así que el admin ve todo y
-- el preventista exclusivamente sus filas. Sin policies de INSERT/UPDATE: la
-- escritura va sólo por los RPCs de abajo (igual que comision_reglas).
-- -------------------------------------------------------------------------
ALTER TABLE public.metas_preventista ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS metas_preventista_admin_select ON public.metas_preventista;
CREATE POLICY metas_preventista_admin_select ON public.metas_preventista
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol IN ('admin', 'encargado')
  ));

DROP POLICY IF EXISTS metas_preventista_propio_select ON public.metas_preventista;
CREATE POLICY metas_preventista_propio_select ON public.metas_preventista
  FOR SELECT TO authenticated
  USING (preventista_id = auth.uid());

-- -------------------------------------------------------------------------
-- Alta / edición (admin-only)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_meta_preventista(
  p_id             bigint,
  p_sucursal_id    bigint,
  p_preventista_id uuid,
  p_periodo        date,
  p_tipo_meta      text,
  p_valor_objetivo numeric,
  p_marca_id       uuid   DEFAULT NULL,
  p_categoria_id   uuid   DEFAULT NULL,
  p_producto_id    bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_id      bigint;
  v_periodo date := date_trunc('month', COALESCE(p_periodo, current_date))::date;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede definir objetivos' USING ERRCODE = '42501';
  END IF;

  IF p_valor_objetivo IS NULL OR p_valor_objetivo <= 0 THEN
    RAISE EXCEPTION 'El objetivo debe ser mayor a 0';
  END IF;

  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Indicá la sucursal del objetivo';
  END IF;

  -- El admin sólo carga metas en sucursales que tiene asignadas.
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RAISE EXCEPTION 'No tenés acceso a esa sucursal' USING ERRCODE = '42501';
  END IF;

  -- Sin este chequeo se cargan metas contra usuarios que nunca van a aparecer
  -- en el reporte, y el gerente ve un objetivo que jamás avanza.
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales us
    WHERE us.usuario_id = p_preventista_id AND us.sucursal_id = p_sucursal_id
  ) THEN
    RAISE EXCEPTION 'Ese usuario no trabaja en la sucursal elegida';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO metas_preventista (
      sucursal_id, preventista_id, periodo, tipo_meta,
      marca_id, categoria_id, producto_id, valor_objetivo, usuario_id
    ) VALUES (
      p_sucursal_id, p_preventista_id, v_periodo, p_tipo_meta,
      p_marca_id, p_categoria_id, p_producto_id, p_valor_objetivo, auth.uid()
    )
    -- Re-cargar la misma meta del mismo mes actualiza el valor en vez de
    -- explotar con un unique violation críptico.
    ON CONFLICT (
      preventista_id, periodo, tipo_meta,
      COALESCE(marca_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(categoria_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(producto_id, -1)
    ) DO UPDATE SET
      valor_objetivo = EXCLUDED.valor_objetivo,
      activo         = true,
      usuario_id     = EXCLUDED.usuario_id
    RETURNING id INTO v_id;
  ELSE
    UPDATE metas_preventista SET
      preventista_id = p_preventista_id,
      periodo        = v_periodo,
      tipo_meta      = p_tipo_meta,
      marca_id       = p_marca_id,
      categoria_id   = p_categoria_id,
      producto_id    = p_producto_id,
      valor_objetivo = p_valor_objetivo
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'El objetivo % no existe', p_id USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  RETURN v_id;
END;
$fn$;

ALTER FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint) TO authenticated;

-- -------------------------------------------------------------------------
-- Baja lógica: el pasado no se reescribe. Si en octubre se borra la meta de
-- agosto, el histórico de agosto tiene que seguir mostrando contra qué se
-- midió.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.desactivar_meta_preventista(p_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede dar de baja objetivos' USING ERRCODE = '42501';
  END IF;

  UPDATE metas_preventista SET activo = false WHERE id = p_id;
END;
$fn$;

ALTER FUNCTION public.desactivar_meta_preventista(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.desactivar_meta_preventista(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.desactivar_meta_preventista(bigint) TO authenticated;
