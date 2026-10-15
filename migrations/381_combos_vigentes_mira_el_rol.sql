-- =========================================================================
-- 381 · combos_vigentes mira el rol (#1191, SEG-A)
--
-- La 380 dejó combos_vigentes como SECURITY DEFINER ejecutable por
-- authenticated sin guard de rol, y SEG-A (auditoria_definer_sin_rol, #1009)
-- se puso en rojo. Es DEFINER porque el tope que queda suma los pedidos de
-- todos los vendedores, que un preventista no ve por RLS. Ahora la contesta
-- sólo quien arma pedidos: es_preventista() da true para preventista,
-- encargado, admin y el rol extra (trampa 4: acá es justo lo que se quiere).
-- A cualquier otro le devuelve la lista vacía, como sin sesión. El resto del
-- cuerpo no cambia.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.combos_vigentes(p_fecha date DEFAULT NULL, p_pedido_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_d        date := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
BEGIN
  -- Sólo quien arma pedidos (es_preventista: preventista, encargado, admin y
  -- el rol extra).
  IF auth.uid() IS NULL OR v_sucursal IS NULL OR NOT public.es_preventista() THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'id', c.id,
             'nombre', c.nombre,
             'precio', c.precio,
             'combina_escalas', c.combina_escalas,
             'prioridad', c.prioridad,
             'producto_a_mover_id', c.producto_a_mover_id,
             'componentes', d.def->'componentes',
             'tope_restante', CASE WHEN c.tope_combos IS NULL THEN NULL ELSE GREATEST(c.tope_combos - COALESCE((
                                SELECT sum(f.cantidad_combos)
                                  FROM pedido_combos f
                                  JOIN pedidos p ON p.id = f.pedido_id AND p.sucursal_id = f.sucursal_id
                                 WHERE f.combo_id = c.id AND f.sucursal_id = c.sucursal_id
                                   AND p.estado NOT IN ('cancelado', 'anulado')
                                   AND f.pedido_id IS DISTINCT FROM p_pedido_id), 0), 0) END)
           ORDER BY c.prioridad DESC, c.id)
      FROM combos c
      CROSS JOIN LATERAL (SELECT public._combo_definicion(c.id, c.sucursal_id) AS def) d
     WHERE c.sucursal_id = v_sucursal
       AND c.activo
       AND c.fecha_inicio <= v_d
       AND (c.fecha_fin IS NULL OR c.fecha_fin >= v_d)
       AND d.def->'componentes' IS NOT NULL
       AND jsonb_typeof(d.def->'componentes') = 'array'), '[]'::jsonb);
END
$fn$;

-- Verificacion: SEG-A no la ve, y los EXECUTE siguen como en la 380.
DO $verif$
BEGIN
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() WHERE firma = 'combos_vigentes(date,bigint)') THEN
    RAISE EXCEPTION 'combos_vigentes sigue sin guard de rol para SEG-A';
  END IF;
  IF has_function_privilege('anon', 'public.combos_vigentes(date,bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.combos_vigentes(date,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'los EXECUTE de combos_vigentes cambiaron';
  END IF;
END
$verif$;
