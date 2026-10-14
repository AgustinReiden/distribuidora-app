-- El precio de venta tampoco SUBE de la lista para quien no es admin (#1159)
--
-- La 363 (#1139) le puso piso al precio de venta de quien no es admin, en el
-- alta y en la edicion, dentro de precio_fuera_de_politica. Techo no habia: en
-- el alta nadie lo tenia, y en la edicion solo el preventista (la regla "Como
-- preventista no puede aumentar precios" de actualizar_pedido_items, contra la
-- lista de hoy y sin ventana). El encargado podia cargar o editar una linea por
-- encima de la lista sin que nada lo frenara.
--
-- Decision del dueno (2026-10-14, #1159-O2): techo en el alta y en la edicion,
-- para todo no-admin, dentro de la misma funcion, simetrico al piso:
--   * Techo = GREATEST(lista de hoy, precio inmediatamente anterior), con el
--     anterior bajo las MISMAS condiciones que el piso: cambio dentro de
--     politicas_comerciales.ventana_precio_anterior_horas, > 0 y vigente al
--     menos 15 minutos. Es el replay offline compuesto antes de una BAJA de
--     lista: llega con el precio viejo, mas alto (66 bajas en 90 dias).
--   * En la edicion se conserva ademas el maximo guardado de la linea, sin
--     condicion: las escalas solo bajan el precio, asi que achicar un grupo no
--     puede legitimar uno mas alto que el que ya estaba aceptado.
--   * No aplica escalas ni descuentos (solo bajan el precio): no toca
--     precio_piso_linea ni su espejo (src/utils/pisoPrecio.espejo.json).
--   * Mensaje terminal, como el del piso: no calza PATRON_STOCK ni
--     pareceSesionVencida (src/utils/rechazoDeNegocio.ts).
--
-- Los llamadores no cambian (son de otra rama de trabajo): crear_pedido_completo
-- la llama bajo v_user_role <> 'admin' AND v_tipo_factura <> 'VB', y
-- actualizar_pedido_items bajo v_user_role <> 'admin'. El techo rige asi para
-- encargado y preventista en los dos caminos, nunca para el admin ni el VB.
-- Para el preventista la regla de la edicion de actualizar_pedido_items sigue
-- adelante y es mas estricta (lista de hoy, sin ventana): queda como esta.
--
-- Medido en prod (90 dias, sin bot, sin VB, sin cancelados, precio > 0) contra
-- precio_lista_al_crear: 0 de 10.403 lineas de preventista y 0 de 271 de
-- encargado quedan por encima de la lista + 0,01. Con la conservacion, ningun
-- pedido abierto queda bloqueado. Sin backfill.
--
-- CREATE OR REPLACE desde pg_get_functiondef de PROD (2026-10-14, mig 363,
-- md5 1709f284bc4365c424fd48c81cfc4638). Cambia solo: v_techo y
-- v_guardado_max en el DECLARE, precio_max en el SELECT del loop, el techo
-- junto a la lista de referencia, el max guardado en la rama de edicion y el
-- rechazo del techo despues del del piso. Firma, STABLE, search_path y ACL
-- (solo postgres y service_role: CREATE OR REPLACE la conserva) como estaban.
-- No hay GUCs, stock, triggers ni costo: STK-F, STK-D, COSTO-D y PRECIO-A no
-- se mueven.
--
-- Ensayo: scripts/test-politica-precios-1157-1159.sql. Regresion:
-- scripts/test-precio-servidor-1138-1139.sql entero.

CREATE OR REPLACE FUNCTION public.precio_fuera_de_politica(p_items jsonb, p_cliente_id bigint, p_sucursal bigint, p_pedido_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  -- Guarda TECNICA contra el tipeo corregido enseguida (0,10 -> 21 -> 2158),
  -- no politica comercial: un precio anterior cuenta para el replay solo si
  -- estuvo vigente al menos esto. Por eso no va en politicas_comerciales.
  c_vigencia_min CONSTANT interval := interval '15 minutes';
  v_items    jsonb := CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END;
  v_horas    integer;
  v_desde    timestamptz;
  v_cliente  jsonb;
  r          record;
  v_prod     record;
  v_lista    numeric;
  v_prev     numeric;
  v_prev_at  timestamptz;
  v_prev_id  uuid;
  v_grupos   jsonb;
  v_piso     numeric;
  v_guardado numeric;
  -- Techo (#1159): lista de hoy, o el anterior si califico, y en la edicion el
  -- maximo guardado; no aplica escalas porque solo bajan el precio.
  v_techo        numeric;
  v_guardado_max numeric;
BEGIN
  SELECT ventana_precio_anterior_horas INTO v_horas
    FROM politicas_comerciales WHERE sucursal_id = p_sucursal;
  v_desde := now() - make_interval(hours => COALESCE(v_horas, 24));

  -- El cliente del pedido, sin filtrar activo (es el del pedido).
  SELECT jsonb_build_object(
           'descuento_porcentaje', COALESCE(c.descuento_porcentaje, 0),
           'descuentos_categoria', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                                      'categoria', d.categoria,
                                                      'descuento_porcentaje', d.descuento_porcentaje) ORDER BY d.id)
                                               FROM cliente_descuentos_categoria d
                                              WHERE d.cliente_id = c.id), '[]'::jsonb))
    INTO v_cliente
    FROM clientes c
   WHERE c.id = p_cliente_id AND c.sucursal_id = p_sucursal;
  v_cliente := COALESCE(v_cliente, '{}'::jsonb);

  FOR r IN
    SELECT NULLIF(e->>'producto_id', '')::bigint AS producto,
           min(NULLIF(e->>'precio_unitario', '')::numeric) AS precio,
           max(NULLIF(e->>'precio_unitario', '')::numeric) AS precio_max,
           bool_or(NULLIF(e->>'precio_unitario', '') IS NULL) AS sin_precio
      FROM jsonb_array_elements(v_items) e
     WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
       AND NULLIF(e->>'producto_id', '') IS NOT NULL
     GROUP BY 1
     ORDER BY 1
  LOOP
    SELECT p.precio, p.nombre, p.categoria INTO v_prod
      FROM productos p WHERE p.id = r.producto AND p.sucursal_id = p_sucursal;
    -- Producto inexistente o sin lista: lo rechaza la RPC o el trigger de la
    -- linea con su propio mensaje.
    IF NOT FOUND OR v_prod.precio IS NULL OR v_prod.precio <= 0 THEN
      CONTINUE;
    END IF;

    -- Lista de referencia: la vigente, o el precio INMEDIATAMENTE anterior si
    -- cambio dentro de la ventana, era > 0 y estuvo vigente al menos
    -- c_vigencia_min. Si el anterior no califica no se busca otro.
    v_lista := v_prod.precio;
    v_techo := v_prod.precio;
    v_prev := NULL; v_prev_at := NULL; v_prev_id := NULL;
    SELECT NULLIF(a.old_data->>'precio', '')::numeric, a.created_at, a.id
      INTO v_prev, v_prev_at, v_prev_id
      FROM audit_logs a
     WHERE a.tabla = 'productos' AND a.registro_id = r.producto::text
       AND a.accion = 'UPDATE' AND 'precio' = ANY(a.campos_modificados)
       AND a.created_at >= v_desde
     ORDER BY a.created_at DESC
     LIMIT 1;
    IF v_prev_id IS NOT NULL AND v_prev > 0
       AND NOT EXISTS (SELECT 1 FROM audit_logs b
                        WHERE b.tabla = 'productos' AND b.registro_id = r.producto::text
                          AND b.id <> v_prev_id
                          AND (b.accion = 'INSERT' OR 'precio' = ANY(b.campos_modificados))
                          -- cerrado arriba: un empate (dos cambios en la misma
                          -- transaccion) no deja vigente a nadie.
                          AND b.created_at BETWEEN v_prev_at - c_vigencia_min AND v_prev_at) THEN
      v_lista := LEAST(v_prod.precio, v_prev);
      -- #1159: simetrico al piso. El replay compuesto antes de una BAJA llega
      -- con el precio viejo, mas alto; vale el mismo anterior y la misma guarda.
      v_techo := GREATEST(v_prod.precio, v_prev);
    END IF;

    -- Los grupos activos de la sucursal que contienen al producto, con todos
    -- sus productos y sus escalas candidatas: las activas de hoy mas la version
    -- inmediatamente anterior de cada escala que cambio en la ventana (UPDATE:
    -- la fila de hoy con los campos viejos encima; DELETE: la fila vieja
    -- entera), si estaba activa, con precio > 0 y vigente al menos
    -- c_vigencia_min. Minimos: los de hoy por id (una escala borrada queda sin
    -- minimos: mas permisivo).
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'grupo_id', g.id,
             'productos', (SELECT COALESCE(jsonb_agg(gp.producto_id ORDER BY gp.producto_id), '[]'::jsonb)
                             FROM grupo_precio_productos gp
                            WHERE gp.grupo_precio_id = g.id AND gp.sucursal_id = p_sucursal),
             'escalas', (SELECT COALESCE(jsonb_agg(x.e), '[]'::jsonb) FROM (
                 SELECT jsonb_build_object(
                          'cantidad_minima', es.cantidad_minima,
                          'precio_unitario', es.precio_unitario,
                          'min_productos_distintos', es.min_productos_distintos,
                          'minimos', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                                'producto_id', m.producto_id,
                                                'cantidad_minima_por_item', m.cantidad_minima_por_item,
                                                'precio_unitario_override', m.precio_unitario_override)), '[]'::jsonb)
                                        FROM grupo_precio_escala_minimos m WHERE m.escala_id = es.id)) AS e
                   FROM grupo_precio_escalas es
                  -- El front cuenta la escala con activo NULL (activo !== false).
                  WHERE es.grupo_precio_id = g.id AND COALESCE(es.activo, true)
                 UNION ALL
                 SELECT jsonb_build_object(
                          'cantidad_minima', NULLIF(v.d->>'cantidad_minima', '')::numeric,
                          'precio_unitario', NULLIF(v.d->>'precio_unitario', '')::numeric,
                          'min_productos_distintos', COALESCE(NULLIF(v.d->>'min_productos_distintos', '')::numeric, 1),
                          'minimos', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                                'producto_id', m.producto_id,
                                                'cantidad_minima_por_item', m.cantidad_minima_por_item,
                                                'precio_unitario_override', m.precio_unitario_override)), '[]'::jsonb)
                                        FROM grupo_precio_escala_minimos m WHERE m.escala_id::text = v.registro_id))
                   FROM (SELECT DISTINCT ON (a.registro_id) a.registro_id, a.id, a.created_at,
                                CASE WHEN a.accion = 'DELETE' THEN a.old_data
                                     ELSE to_jsonb(cur) || COALESCE(a.old_data, '{}'::jsonb) END AS d
                           FROM audit_logs a
                           LEFT JOIN grupo_precio_escalas cur ON cur.id::text = a.registro_id
                          WHERE a.tabla = 'grupo_precio_escalas'
                            AND a.accion IN ('UPDATE', 'DELETE')
                            AND a.created_at >= v_desde
                          ORDER BY a.registro_id, a.created_at DESC) v
                  WHERE NULLIF(v.d->>'grupo_precio_id', '')::bigint = g.id
                    AND COALESCE((v.d->>'activo')::boolean, true)
                    AND NULLIF(v.d->>'precio_unitario', '')::numeric > 0
                    AND NOT EXISTS (SELECT 1 FROM audit_logs b
                                     WHERE b.tabla = 'grupo_precio_escalas' AND b.registro_id = v.registro_id
                                       AND b.id <> v.id
                                       AND (b.accion = 'INSERT'
                                            OR b.campos_modificados && ARRAY['precio_unitario', 'cantidad_minima',
                                                                             'activo', 'grupo_precio_id',
                                                                             'min_productos_distintos'])
                                       AND b.created_at BETWEEN v.created_at - c_vigencia_min AND v.created_at)
               ) x)
           ) ORDER BY g.id), '[]'::jsonb)
      INTO v_grupos
      FROM grupos_precio g
     WHERE g.sucursal_id = p_sucursal AND COALESCE(g.activo, true)
       AND EXISTS (SELECT 1 FROM grupo_precio_productos gp
                    WHERE gp.grupo_precio_id = g.id AND gp.producto_id = r.producto
                      AND gp.sucursal_id = p_sucursal);

    v_piso := public.precio_piso_linea(v_items, v_grupos, r.producto, v_lista, v_cliente, v_prod.categoria);

    -- Edicion: el precio guardado se conserva si ningun grupo vigente del
    -- producto achica su total ni sus productos distintos (las reglas son
    -- monotonas: la escala que valia al guardar sigue valiendo). Sin grupo,
    -- siempre. Las lineas guardadas son las de antes del DELETE de la RPC.
    IF p_pedido_id IS NOT NULL THEN
      SELECT min(pi.precio_unitario), max(pi.precio_unitario) INTO v_guardado, v_guardado_max
        FROM pedido_items pi
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
         AND NOT COALESCE(pi.es_bonificacion, false) AND pi.producto_id = r.producto;
      -- El techo conserva el precio guardado sin condicion: las escalas solo
      -- bajan el precio, achicar un grupo no puede legitimar uno mas alto que
      -- el que ya estaba aceptado.
      IF v_guardado_max IS NOT NULL THEN
        v_techo := GREATEST(v_techo, v_guardado_max);
      END IF;
      IF v_guardado IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
             FROM grupos_precio g
             CROSS JOIN LATERAL (
               SELECT COALESCE(SUM(n.cantidad), 0) AS total_nuevo,
                      count(*) FILTER (WHERE n.cantidad > 0) AS distintos_nuevo
                 FROM (SELECT NULLIF(e->>'producto_id', '')::bigint AS producto,
                              SUM(COALESCE(NULLIF(e->>'cantidad', '')::numeric, 0)) AS cantidad
                         FROM jsonb_array_elements(v_items) e
                        WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
                        GROUP BY 1) n
                WHERE n.producto IN (SELECT gp.producto_id FROM grupo_precio_productos gp
                                      WHERE gp.grupo_precio_id = g.id AND gp.sucursal_id = p_sucursal)) nv
             CROSS JOIN LATERAL (
               SELECT COALESCE(SUM(o.cantidad), 0) AS total_guardado,
                      count(*) FILTER (WHERE o.cantidad > 0) AS distintos_guardado
                 FROM (SELECT pi.producto_id, SUM(pi.cantidad) AS cantidad
                         FROM pedido_items pi
                        WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
                          AND NOT COALESCE(pi.es_bonificacion, false)
                        GROUP BY 1) o
                WHERE o.producto_id IN (SELECT gp.producto_id FROM grupo_precio_productos gp
                                         WHERE gp.grupo_precio_id = g.id AND gp.sucursal_id = p_sucursal)) gv
            WHERE g.sucursal_id = p_sucursal AND COALESCE(g.activo, true)
              AND EXISTS (SELECT 1 FROM grupo_precio_productos gp
                           WHERE gp.grupo_precio_id = g.id AND gp.producto_id = r.producto
                             AND gp.sucursal_id = p_sucursal)
              AND (nv.total_nuevo < gv.total_guardado OR nv.distintos_nuevo < gv.distintos_guardado)) THEN
        v_piso := LEAST(v_piso, v_guardado);
      END IF;
    END IF;

    -- Un piso NULL con lista vigente > 0 rechaza: nunca se acepta a ciegas.
    IF v_piso IS NULL OR r.sin_precio OR r.precio < v_piso - 0.01 THEN
      RETURN format('El precio de %s (%s) está por debajo del que permite la lista para este pedido (%s). Solo un admin puede cargar otro precio.',
                    v_prod.nombre,
                    COALESCE(to_char(r.precio, 'FM$999G999G990D00'), 'sin precio'),
                    COALESCE(to_char(v_piso, 'FM$999G999G990D00'), 'sin piso'));
    END IF;

    -- Techo (#1159): la linea mas cara del producto contra la lista (o el
    -- anterior que califico, o el maximo guardado en la edicion).
    IF r.precio_max > v_techo + 0.01 THEN
      RETURN format('El precio de %s (%s) está por encima del que permite la lista para este pedido (%s). Solo un admin puede cargar otro precio.',
                    v_prod.nombre,
                    to_char(r.precio_max, 'FM$999G999G990D00'),
                    to_char(v_techo, 'FM$999G999G990D00'));
    END IF;
  END LOOP;

  RETURN NULL;
END
$function$;

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_fue text := 'public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)';
  v_fue text := pg_get_functiondef(f_fue::regprocedure);
  v_cre text;
  v_act text;
BEGIN
  -- La ACL de server se conservo: solo service_role (y postgres).
  IF has_function_privilege('anon', f_fue, 'EXECUTE') OR has_function_privilege('authenticated', f_fue, 'EXECUTE')
     OR NOT has_function_privilege('service_role', f_fue, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = f_fue::regprocedure AND a.grantee = 0) THEN
    RAISE EXCEPTION 'los EXECUTE de % cambiaron (tiene que ser solo service_role)', f_fue;
  END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = f_fue::regprocedure)
     OR (SELECT provolatile FROM pg_proc WHERE oid = f_fue::regprocedure) <> 's'
     OR (SELECT proconfig FROM pg_proc WHERE oid = f_fue::regprocedure) IS DISTINCT FROM ARRAY['search_path=public'] THEN
    RAISE EXCEPTION '% dejo de ser invoker STABLE con search_path=public', f_fue;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                                     AND proname = 'precio_fuera_de_politica') <> 1 THEN
    RAISE EXCEPTION 'precio_fuera_de_politica quedo con mas de una sobrecarga';
  END IF;
  IF v_fue NOT LIKE '%por debajo del que permite la lista%' OR v_fue NOT LIKE '%por encima del que permite la lista%' THEN
    RAISE EXCEPTION 'precio_fuera_de_politica no tiene el piso y el techo';
  END IF;

  -- Los llamadores siguen como estaban: el alta exime al admin y al VB, la
  -- edicion al admin (el techo hereda esas exenciones).
  SELECT pg_get_functiondef(p.oid) INTO v_cre FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'crear_pedido_completo';
  SELECT pg_get_functiondef(p.oid) INTO v_act FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'actualizar_pedido_items';
  IF strpos(v_cre, 'IF v_user_role <> ''admin'' AND v_tipo_factura <> ''VB''') = 0
     OR strpos(substr(v_cre, strpos(v_cre, 'IF v_user_role <> ''admin'' AND v_tipo_factura <> ''VB'''), 300),
               'public.precio_fuera_de_politica(p_items, p_cliente_id, v_sucursal, NULL)') = 0 THEN
    RAISE EXCEPTION 'crear_pedido_completo ya no llama a precio_fuera_de_politica bajo no-admin y no-VB';
  END IF;
  IF v_act NOT LIKE '%public.precio_fuera_de_politica(%v_items,%v_sucursal, p_pedido_id);%' THEN
    RAISE EXCEPTION 'actualizar_pedido_items ya no llama a precio_fuera_de_politica';
  END IF;
END
$verif$;
