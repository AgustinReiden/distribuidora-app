-- #974 (1/2) · costos_productos(): los costos de productos para admin y encargado
--
-- Primera mitad de #974. Crea la RPC por la que el front pide los costos;
-- la segunda mitad (la otra migración de #974, va en un PR aparte) le saca a authenticated y
-- anon el SELECT sobre las columnas de costo de `productos`.
--
-- Van separadas por el ORDEN DE DESPLIEGUE, que no es opcional:
--   * el front nuevo llama a esta RPC y, si falla, el catálogo da error (a
--     propósito: la ficha del producto guardada sin costos los pisa con NULL).
--     Así que esta mitad se aplica ANTES de desplegar el front.
--   * el front viejo pide `select('*')` sobre productos, que con el revoke
--     falla para todos los roles. Así que la otra mitad se aplica DESPUÉS de
--     desplegar el front, y de que las PWA abiertas hayan tomado el bundle nuevo.
--
-- Esta mitad sola no cambia nada visible: la RPC existe y nadie más pierde nada.
--
-- Para cualquier rol que no sea admin o encargado devuelve cero filas, sin
-- error: el front la llama sin preguntar el rol y el preventista recibe el
-- catálogo sin costos.

-- La RPC --------------------------------------------------------

CREATE OR REPLACE FUNCTION public.costos_productos(p_ids bigint[] DEFAULT NULL)
 RETURNS TABLE (
   id bigint,
   costo_real numeric,
   costo_promedio numeric,
   costo_sin_iva numeric,
   costo_con_iva numeric
 )
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Admin o encargado por ROL PRINCIPAL (`es_encargado_o_admin()` mira
  -- `perfiles.rol`). No `es_preventista()`, que da true también para ellos y
  -- dejaría la puerta abierta al revés (CLAUDE.md, trampa 4).
  -- Mismo alcance de filas que la RLS de productos: la sucursal actual.
  SELECT p.id, p.costo_real, p.costo_promedio, p.costo_sin_iva, p.costo_con_iva
    FROM public.productos p
   WHERE public.es_encargado_o_admin()
     AND p.sucursal_id = public.current_sucursal_id()
     AND (p_ids IS NULL OR p.id = ANY (p_ids));
$function$;

REVOKE EXECUTE ON FUNCTION public.costos_productos(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.costos_productos(bigint[]) TO authenticated;

DO $verif$
BEGIN
  IF has_function_privilege('anon', 'public.costos_productos(bigint[])', 'EXECUTE') THEN
    RAISE EXCEPTION '#974 · anon puede ejecutar costos_productos';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.costos_productos(bigint[])', 'EXECUTE') THEN
    RAISE EXCEPTION '#974 · authenticated no puede ejecutar costos_productos';
  END IF;
END
$verif$;
