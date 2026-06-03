-- Migración 078: Control de stock por planilla (cargar → ajustar → histórico)
--
-- Ya existía la DESCARGA de la planilla (exportControlStock). Esto agrega la
-- CARGA: una RPC que aplica los ajustes, registra cada alta/baja en
-- stock_historico (origen='control_stock') y agrupa cada carga en una "sesión"
-- (control_stock_sesiones) para el histórico.
--
-- Permisos: solo admin puede aplicar (la RPC revalida es_admin()). Descargar y
-- ver histórico los puede admin y encargado (SELECT por sucursal vía RLS).
-- Regla de seguridad (en el front): solo se ajustan ítems con "Stock Real"
-- cargado; los vacíos se omiten (no se pisa a 0 lo no controlado).

BEGIN;

-- =========================================================================
-- TABLA CABECERA (una fila por carga de planilla)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.control_stock_sesiones (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fecha         timestamptz NOT NULL DEFAULT now(),
  usuario_id    uuid,
  sucursal_id   bigint NOT NULL REFERENCES public.sucursales(id) ON DELETE CASCADE,
  total_items   integer NOT NULL DEFAULT 0,
  total_altas   integer NOT NULL DEFAULT 0,
  total_bajas   integer NOT NULL DEFAULT 0,
  observaciones text
);

-- FK al perfil del usuario (para embeber el nombre del uploader vía PostgREST).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'control_stock_sesiones_usuario_id_fkey'
  ) THEN
    ALTER TABLE public.control_stock_sesiones
      ADD CONSTRAINT control_stock_sesiones_usuario_id_fkey
      FOREIGN KEY (usuario_id) REFERENCES public.perfiles(id) ON DELETE SET NULL;
  END IF;
END $$;

ALTER TABLE public.control_stock_sesiones ENABLE ROW LEVEL SECURITY;

-- SELECT: cualquier usuario de la sucursal (admin y encargado ven el histórico).
-- INSERT/UPDATE: solo vía RPC SECURITY DEFINER (no se exponen policies de escritura).
DROP POLICY IF EXISTS mt_control_stock_sesiones_select ON public.control_stock_sesiones;
CREATE POLICY mt_control_stock_sesiones_select ON public.control_stock_sesiones
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

-- Índice para traer el detalle de cada sesión (stock_historico) rápido.
CREATE INDEX IF NOT EXISTS idx_stock_historico_control_sesion
  ON public.stock_historico (referencia_id)
  WHERE origen = 'control_stock';

-- =========================================================================
-- RPC: aplicar los ajustes de una planilla completada
--   p_ajustes = [{ "producto_id": <bigint>, "stock_real": <int> }, ...]
-- Solo admin. Solo productos de la sucursal activa. Solo escribe si hay
-- diferencia. NOTA: stock_historico.diferencia es columna GENERADA (no se
-- inserta; la calcula la DB).
-- =========================================================================
CREATE OR REPLACE FUNCTION public.aplicar_control_stock(
  p_ajustes      jsonb,
  p_observaciones text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id   bigint;
  v_usuario_id    uuid;
  v_sesion_id     bigint;
  v_total_items   integer := 0;
  v_total_altas   integer := 0;
  v_total_bajas   integer := 0;
  v_ajuste        jsonb;
  v_producto_id   bigint;
  v_stock_real    integer;
  v_stock_actual  integer;
  v_diferencia    integer;
  v_aplicados     jsonb := '[]'::jsonb;
  v_no_encontrados jsonb := '[]'::jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede aplicar ajustes de control de stock';
  END IF;

  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa';
  END IF;
  v_usuario_id := auth.uid();

  INSERT INTO control_stock_sesiones (usuario_id, sucursal_id, observaciones)
  VALUES (v_usuario_id, v_sucursal_id, p_observaciones)
  RETURNING id INTO v_sesion_id;

  FOR v_ajuste IN SELECT * FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb))
  LOOP
    v_producto_id := (v_ajuste->>'producto_id')::bigint;
    -- stock_real vacío/null => ítem no contado => se saltea (no se ajusta a 0).
    IF (v_ajuste->>'stock_real') IS NULL OR btrim(v_ajuste->>'stock_real') = '' THEN
      CONTINUE;
    END IF;
    v_stock_real := round((v_ajuste->>'stock_real')::numeric)::integer;
    IF v_stock_real < 0 THEN
      CONTINUE;
    END IF;

    SELECT stock INTO v_stock_actual
    FROM productos
    WHERE id = v_producto_id AND sucursal_id = v_sucursal_id
    FOR UPDATE;

    IF NOT FOUND THEN
      v_no_encontrados := v_no_encontrados || jsonb_build_object('producto_id', v_producto_id);
      CONTINUE;
    END IF;

    v_diferencia := v_stock_real - v_stock_actual;

    IF v_diferencia <> 0 THEN
      UPDATE productos SET stock = v_stock_real, updated_at = now()
      WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;

      INSERT INTO stock_historico (
        producto_id, stock_anterior, stock_nuevo, origen,
        referencia_tipo, referencia_id, usuario_id, sucursal_id
      ) VALUES (
        v_producto_id, v_stock_actual, v_stock_real, 'control_stock',
        'control_stock_sesion', v_sesion_id, v_usuario_id, v_sucursal_id
      );

      v_total_items := v_total_items + 1;
      IF v_diferencia > 0 THEN
        v_total_altas := v_total_altas + v_diferencia;
      ELSE
        v_total_bajas := v_total_bajas + abs(v_diferencia);
      END IF;

      v_aplicados := v_aplicados || jsonb_build_object(
        'producto_id', v_producto_id,
        'stock_anterior', v_stock_actual,
        'stock_nuevo', v_stock_real,
        'diferencia', v_diferencia
      );
    END IF;
  END LOOP;

  UPDATE control_stock_sesiones
  SET total_items = v_total_items, total_altas = v_total_altas, total_bajas = v_total_bajas
  WHERE id = v_sesion_id;

  RETURN jsonb_build_object(
    'sesion_id', v_sesion_id,
    'total_items', v_total_items,
    'total_altas', v_total_altas,
    'total_bajas', v_total_bajas,
    'aplicados', v_aplicados,
    'no_encontrados', v_no_encontrados
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.aplicar_control_stock(jsonb, text) FROM public;
GRANT EXECUTE ON FUNCTION public.aplicar_control_stock(jsonb, text) TO authenticated;

COMMIT;
