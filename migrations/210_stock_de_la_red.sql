-- Stock, costo y precio de la otra sucursal — solo lectura, para todo admin
--
-- EL PEDIDO
-- ---------
-- "Que cualquier admin pueda ver el stock, el costo y el precio de la otra
-- sucursal, en SOLO LECTURA."
--
-- POR QUE HACE FALTA CODIGO
-- -------------------------
-- De los 7 admins, solo dos (Agustin y Jorge) estan en `usuario_sucursales`
-- para las dos sucursales. Julio y Pablo son admin solo de Taco Pozo; Emilia,
-- Nacho y Virginia solo de Tucuman. Todo lo que hay hoy cruza contra
-- `usuario_sucursales`, asi que esos cinco no ven la otra sucursal por ningun
-- lado: `reporte_valuacion_inventario` (mig 131) INTERSECTA las sucursales
-- activas con las asignadas, y la policy `mt_productos_select` filtra por
-- `current_sucursal_id()`.
--
-- POR QUE NO SE LOS AGREGA A usuario_sucursales
-- ---------------------------------------------
-- Porque eso no es "ver": es acceso OPERATIVO completo a la otra sucursal
-- (crear pedidos, mover stock, editar productos, cambiar precios). El pedido
-- es de lectura.
--
-- POR QUE NO SE RELAJA mt_productos_select
-- ----------------------------------------
-- `fetchProductos` es `.from('productos').select('*')` SIN filtro de sucursal,
-- y ninguno de los 24 call sites de `.from('productos')` lleva
-- `.eq('sucursal_id')`: TODO el aislamiento lo pone la policy. Abrirla haria
-- que el selector de items del pedido, las categorias, las mermas,
-- ModalCrearMovimiento y el backup a Excel pasen a mostrar el catalogo de las
-- dos sucursales, en silencio y sin que falle ningun test. Y la policy es
-- sobre la FILA ENTERA: expondria costo_sin_iva, costo_con_iva, costo_real,
-- costo_promedio, precio y proveedor_id de una. Un RPC elige columna por
-- columna, y este devuelve solo stock, costo (promedio y reposicion) y precio.
--
-- POR QUE UN RPC NUEVO Y NO UN PARAMETRO EN LA 131
-- ------------------------------------------------
-- Agregarle un `p_todas boolean DEFAULT false` a
-- `reporte_valuacion_inventario(bigint)` deja dos sobrecargas con rangos
-- [obligatorios, total] superpuestos: PostgREST no sabria cual llamar y
-- tiraria PGRST203 en runtime, invisible para tsc, eslint y los tests
-- (precedente: mig 176). Nombre nuevo, sin sobrecarga.
--
-- EL GATE
-- -------
-- Rol CRUDO de `perfiles`, como las migs 130 y 131. Nunca `es_preventista()`
-- ni `es_transportista()`, que devuelven true tambien para admin y encargado.
-- Alcanza con ser admin en alguna sucursal asignada ademas de por rol global:
-- el front gatea `/reportes` con el rol EN LA SUCURSAL ACTIVA
-- (`App.tsx: currentSucursalRol ?? perfil.rol`), asi que si el RPC mirara
-- solo el rol global, un admin-en-la-sucursal-pero-no-global entraria a la
-- pantalla y recibiria "Acceso denegado". El gate del RPC es superset del
-- gate del front: todo el que ve la pestaña puede leer el dato.
--
-- Encargado NO entra. La 131 lo deja pasar para SU sucursal; cruzar de
-- sucursal es otra cosa y el pedido dijo admin.
--
-- QUE DEVUELVE
-- ------------
-- Una fila por producto de cada sucursal activa (TODAS, tambien las que no
-- estan asignadas al usuario), con stock, costo promedio, costo de reposicion
-- y precio de lista, mas agregados por sucursal. No filtra `stock <> 0` como
-- la 131: acá el "Taco Pozo tiene 0" es justamente el dato que se busca.
--
-- EL EMPAREJADO NO SE HACE ACA
-- ----------------------------
-- No hay clave que una un producto de Tucuman con "el mismo" de Taco Pozo:
-- filas independientes, ids distintos, sin tabla de equivalencias, y
-- `productos.codigo` no tiene UNIQUE. El RPC devuelve las filas planas y el
-- emparejado (codigo exacto o nombre exacto, el criterio estricto de
-- `sugerirMatchProducto`) vive en `src/utils/stockRed.ts`, con tests. Medido
-- hoy: de 176 productos en Tucuman y 111 en Taco Pozo emparejan 10. El resto
-- no es un error del emparejado: son catalogos distintos, y la vista los
-- muestra en su propia seccion en vez de esconderlos.

CREATE OR REPLACE FUNCTION public.reporte_stock_red(
  p_sucursal_id bigint DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[]; v_nombre text; v_result jsonb;
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol text; v_es_admin boolean;
BEGIN
  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true);
    -- Admin global, o admin en alguna sucursal asignada ('mismo' resuelve al
    -- rol global, igual que _rol_en_sucursal).
    v_es_admin := (v_rol = 'admin') OR EXISTS (
      SELECT 1 FROM usuario_sucursales us
      WHERE us.usuario_id = auth.uid()
        AND (CASE WHEN us.rol = 'mismo' THEN v_rol ELSE us.rol END) = 'admin');
    IF NOT COALESCE(v_es_admin, false) THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin'; END IF;
  END IF;

  -- SIN interseccion contra usuario_sucursales: es el punto del RPC.
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id ORDER BY id) INTO v_sucursales FROM sucursales WHERE activa;
    v_nombre := 'Red (consolidado)';
  ELSE
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
    IF v_nombre IS NULL THEN
      RAISE EXCEPTION 'La sucursal % no existe', p_sucursal_id; END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'No hay sucursales activas'; END IF;

  WITH
  base AS (
    SELECT p.id, p.nombre, p.codigo, p.stock, p.precio,
           p.sucursal_id, s.nombre AS sucursal_nombre,
           COALESCE(NULLIF(p.categoria,''),'(sin categoría)') AS categoria,
           -- Misma cascada que la 131 y que costoCanonicoUnitario(): en ZZ lo
           -- pagado ya incluye IVA e impuestos internos y quedó en costo_real,
           -- así que la fórmula (semántica FC) es el último recurso.
           COALESCE(p.costo_promedio, p.costo_real,
                    round(p.costo_sin_iva*(1+COALESCE(p.impuestos_internos,0)/100), 4)) AS cpp,
           COALESCE(p.costo_real,
                    round(p.costo_sin_iva*(1+COALESCE(p.impuestos_internos,0)/100), 4)) AS reposicion,
           p.ultimo_tipo_compra
    FROM productos p
    JOIN sucursales s ON s.id = p.sucursal_id
    WHERE p.sucursal_id = ANY(v_sucursales)
  ),
  productos_j AS (
    SELECT jsonb_agg(jsonb_build_object(
        'producto_id', id, 'nombre', nombre, 'codigo', codigo,
        'categoria', categoria,
        'sucursal_id', sucursal_id, 'sucursal_nombre', sucursal_nombre,
        'stock', stock, 'precio', precio,
        'costo_promedio', cpp, 'costo_reposicion', reposicion,
        'ultimo_tipo_compra', ultimo_tipo_compra
      ) ORDER BY nombre, sucursal_id) AS arr
    FROM base
  ),
  sucursales_j AS (
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.sucursal_nombre) AS arr FROM (
      SELECT sucursal_id, sucursal_nombre,
             COUNT(*) AS productos,
             COUNT(*) FILTER (WHERE stock > 0) AS productos_con_stock,
             COALESCE(SUM(GREATEST(stock,0)), 0) AS unidades,
             COALESCE(round(SUM(GREATEST(stock,0) * COALESCE(cpp,0)), 2), 0) AS valuacion_promedio
      FROM base GROUP BY sucursal_id, sucursal_nombre
    ) x
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre,'?'),
      'generado_at', now(),
      'criterio', 'costo promedio ponderado (fallback: costo reposición) · solo lectura'),
    'sucursales', (SELECT COALESCE(arr,'[]'::jsonb) FROM sucursales_j),
    'productos', (SELECT COALESCE(arr,'[]'::jsonb) FROM productos_j)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION public.reporte_stock_red(bigint) IS
  'Stock, costo y precio de TODAS las sucursales activas, solo lectura. Gate: admin (rol crudo). No cruza contra usuario_sucursales, a proposito. mig 210.';

REVOKE ALL ON FUNCTION public.reporte_stock_red(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_stock_red(bigint) TO authenticated, service_role;

-- Toda funcion nueva nace con EXECUTE para PUBLIC y el GRANT a authenticated
-- no lo revierte (ver README § Permisos y el gate scripts/check-permisos.mjs).
DO $verif$
DECLARE
  v_acl text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'reporte_stock_red';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'reporte_stock_red quedo con ACL default (PUBLIC ejecuta)'; END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'reporte_stock_red quedo ejecutable por PUBLIC: %', v_acl; END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'reporte_stock_red quedo ejecutable por anon: %', v_acl; END IF;
  IF v_acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'reporte_stock_red no quedo ejecutable por authenticated: %', v_acl; END IF;
END
$verif$;

-- VERIFICACION (post-aplicacion, con un admin de una sola sucursal):
--   SELECT jsonb_pretty(reporte_stock_red(NULL) -> 'sucursales');
--   -- tiene que traer las DOS sucursales activas, no solo la asignada.
-- Y con la anon key, tiene que dar 42501 (permission denied for function):
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/reporte_stock_red" \
--     -H "apikey: $ANON" -H "Content-Type: application/json" -d '{}'
