-- ============================================================================
-- 108 · Metas gerenciales (objetivos mensuales) — BI Fase 2
-- ============================================================================
-- Tabla de metas por sucursal y mes (sucursal_id NULL = red consolidada) para
-- venta y margen_neto. El semáforo (cumplimiento) se calcula en el front contra
-- estas metas (prorrateadas por días si el mes está en curso). Escritura por RPC
-- admin-only; lectura por RLS admin. NO toca reporte_gerencial.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.metas_gerenciales (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sucursal_id bigint REFERENCES sucursales(id),         -- NULL = red consolidada
  periodo     date NOT NULL,                            -- primer día del mes
  metrica     text NOT NULL CHECK (metrica IN ('venta','margen_neto')),
  valor       numeric NOT NULL CHECK (valor >= 0),
  usuario_id  uuid,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);

COMMENT ON TABLE public.metas_gerenciales IS
  'Objetivos mensuales por sucursal (NULL=red) y métrica (venta/margen_neto). UNIQUE por (sucursal_id, periodo, metrica) tratando NULL como -1.';

CREATE UNIQUE INDEX IF NOT EXISTS metas_gerenciales_uidx
  ON public.metas_gerenciales (COALESCE(sucursal_id, -1), periodo, metrica);

ALTER TABLE public.metas_gerenciales ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS metas_gerenciales_admin_select ON public.metas_gerenciales;
CREATE POLICY metas_gerenciales_admin_select ON public.metas_gerenciales
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));
-- Escritura: sólo vía guardar_meta_gerencial (SECURITY DEFINER) o service_role.

-- ----------------------------------------------------------------------------
-- RPC upsert de meta (admin-only; valida sucursal asignada)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_meta_gerencial(
  p_sucursal_id bigint,
  p_periodo     date,
  p_metrica     text,
  p_valor       numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;
  IF auth.uid() IS NOT NULL AND p_sucursal_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal no está asignada al usuario';
  END IF;
  IF p_metrica NOT IN ('venta','margen_neto') THEN
    RAISE EXCEPTION 'Métrica inválida: %', p_metrica;
  END IF;
  IF p_valor IS NULL OR p_valor < 0 THEN
    RAISE EXCEPTION 'Valor inválido';
  END IF;

  INSERT INTO metas_gerenciales (sucursal_id, periodo, metrica, valor, usuario_id, updated_at)
  VALUES (p_sucursal_id, date_trunc('month', p_periodo)::date, p_metrica, p_valor, auth.uid(), now())
  ON CONFLICT (COALESCE(sucursal_id, -1), periodo, metrica) DO UPDATE
    SET valor = EXCLUDED.valor, usuario_id = EXCLUDED.usuario_id, updated_at = now();
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.guardar_meta_gerencial(bigint, date, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_meta_gerencial(bigint, date, text, numeric) TO authenticated, service_role;
