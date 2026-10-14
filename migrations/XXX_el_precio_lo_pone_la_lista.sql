-- El precio de venta lo pone la lista, no quien carga el pedido (#1139), y el
-- regalo va a precio 0 (#1138)
--
-- Visto al cerrar #1123, que valida el regalo pero no la clase entera del
-- problema:
--
--   * #1139. En el alta, crear_pedido_completo no comparaba el precio de una
--     linea de venta con nada: solo que la suma diera p_total y la compra
--     minima. El trigger validar_precio_item_pedido exige precio > 0 y una
--     lista cargada, asi que V x10 a lista mas X x50 a $0,01 entraba para
--     preventista y encargado y bajaba el stock de X. En la edicion, al
--     preventista solo se le prohibia SUBIR el precio y al encargado no se le
--     controlaba nada. authenticated no tiene INSERT ni UPDATE sobre
--     pedido_items: la puerta son las dos RPCs.
--   * #1138. validar_precio_item_pedido hace RETURN NEW apenas ve
--     es_bonificacion, y crear_pedido_completo deja neto, IVA e ingreso real
--     del regalo en 0 aunque su precio no sea 0: el subtotal sumaba a
--     pedidos.total y no a total_neto ni a total_iva. En actualizar_pedido_items
--     al reves: el regalo se guardaba con subtotal = cantidad * precio pero
--     v_total_nuevo solo suma la venta, y pedidos.total dejaba de ser
--     SUM(subtotal) (VENTA-A). Hoy: 0 de 1.670 regalos.
--
-- Decisiones del dueno (2026-10-13):
--
--   * #1138: se rechaza en las dos RPCs, para cualquier rol, y se suma el CHECK
--     pedido_items_regalo_a_precio_cero. Forzar el 0 en silencio chocaba con el
--     chequeo de total de la 235 (p_total incluye el precio del regalo). No
--     tiene el problema de la trampa 8: el CHECK es sobre la linea de regalo y
--     cancelar no le toca el precio.
--   * #1139, para quien no es admin (perfiles.rol, como #1112 y #1123; no
--     es_preventista(), trampa 4) y fuera del VB (lo precia el server):
--       - Piso permisivo con 0% de margen: precio >= piso - 0,01, con
--         piso = round(LEAST(lista, menor escala aplicable) * (1 - % del
--         cliente), 2). Las escalas se evaluan sobre TODAS las lineas de venta
--         (un superconjunto de lo que mira el front, que saca las que reclamo
--         una promo) con las reglas 1 y 3, que son monotonas; la 2 se omite
--         (solo descalifica). Asi el piso nunca supera lo que cobra el front
--         (orquestarPrecios). Espejo: precio_piso_linea, con gate de paridad.
--       - Replay offline: vale SOLO el precio inmediatamente anterior al
--         vigente, si era > 0 y estuvo vigente al menos 15 minutos, durante N
--         horas desde el cambio (politicas_comerciales
--         .ventana_precio_anterior_horas, default 24). Medido en 180 dias: 13
--         cambios de precio desde 0 (los productos nacen a 0) y 18 de 470
--         cambios corregidos en menos de 15 minutos (tipeos como 0,10 -> 21 ->
--         2158); con el minimo de la ventana el piso quedaba en 0 o en un tipeo.
--         En 120 dias, el atraso de replay mas largo de un no-admin por app fue
--         de 1 dia, y el caso real (pedido 6959) de 5 minutos. La ventana la
--         puede usar tambien quien esta online: por eso es corta.
--       - Escalas: se audita grupo_precio_escalas y el cargador suma como
--         candidata la version inmediatamente anterior de cada escala del grupo
--         (UPDATE o DELETE en la ventana, activa, precio > 0 y vigente al menos
--         15 minutos). Cubre el cambio de precio, el DELETE + INSERT de la
--         reconciliacion por cantidad_minima (updateGrupoPrecio) y la
--         desactivacion. NO cubre un grupo desactivado ni un producto que salio
--         del grupo: ese replay se rechaza.
--       - Edicion: el precio guardado de una linea se conserva (aunque hoy
--         quede bajo el piso) si la edicion no achica nada de lo que se lo dio:
--         para cada grupo vigente del producto, ni el total ni los productos
--         distintos bajan respecto de lo guardado. Sin grupo, siempre. Nunca
--         depende de origen_precio (lo controla quien edita).
--       - Sin techo nuevo: el del preventista en la edicion queda como esta.
--
-- Escritores de pedido_items revisados en prod (2026-10-13) para el CHECK:
--   * crear_pedido_completo y actualizar_pedido_items: parchadas aca.
--   * crear_pedido_completo_bot: el precio viene de bot_pedidos_pendientes, que
--     arma orquestarPrecios con el regalo a 0.
--   * dividir_regalo_pedido: COALESCE(v_item.precio_unitario, 0) y subtotal 0.
--   * sustituir_regalo_pedido: subtotal 0 y conserva el precio (0).
--   * registrar_salvedad y anular_salvedad: cantidad * precio sobre el precio
--     de la linea, que es 0.
--   * cambiar_tipo_factura_pedido: el VB rechaza regalos y FC/ZZ solo pone en
--     0 el desglose del regalo.
--   * consolidar_condiciones (solo grupo_precio_escala_id) y
--     registrar_origen_precio_items (solo origen_precio): no tocan el precio.
--   Ninguno puede tirar 23514 con datos que cumplan el CHECK.
--
-- validar_precio_item_pedido NO se toca: #1139 necesita el pedido entero y el
-- rol, que el trigger no conoce. registrar_origen_precio_items tampoco: la
-- excepcion de la edicion ya no mira origen_precio.
--
-- No toca stock, GUCs, lotes, costo_unitario_al_crear ni la definicion de
-- venta: STK-F, STK-D, COSTO-D y "venta por vendedor" quedan iguales. No hay
-- embeds nuevos. Las guardas son de solo lectura y van antes de toda escritura.
-- Los mensajes no calzan con PATRON_STOCK ni con pareceSesionVencida
-- (src/utils/rechazoDeNegocio.ts): el replay offline los da por terminales, y
-- crear_pedido_idempotente no sella offline_id cuando success = false.
--
-- Va despues de la de promos (#1136/#1137), que parcha las mismas dos RPCs:
-- los parches son por ancla sobre la definicion viva y abortan si el ancla no
-- aparece exactamente una vez.
--
-- Ensayo: scripts/test-precio-servidor-1138-1139.sql. Espejo del piso:
-- src/utils/pisoPrecio.espejo.json (vitest) y scripts/espejo-piso-precio.mjs.

-- ---------------------------------------------------------------------------
-- 1a. #1138: el regalo va a precio 0 (CHECK). Antes, que no haya violaciones.
-- ---------------------------------------------------------------------------
DO $pre1138$
DECLARE
  v_n bigint;
BEGIN
  SELECT count(*) INTO v_n
    FROM public.pedido_items
   WHERE COALESCE(es_bonificacion, false)
     AND (precio_unitario <> 0 OR subtotal <> 0);
  IF v_n > 0 THEN
    RAISE EXCEPTION 'hay % lineas de regalo con precio o subtotal distinto de 0: revisarlas antes del CHECK', v_n;
  END IF;
END
$pre1138$;

ALTER TABLE public.pedido_items
  ADD CONSTRAINT pedido_items_regalo_a_precio_cero
  CHECK (NOT COALESCE(es_bonificacion, false) OR (precio_unitario = 0 AND subtotal = 0));

-- ---------------------------------------------------------------------------
-- 1b. #1139: la ventana del precio anterior es politica comercial (CLAUDE.md:
--     un parametro de negocio va en politicas_comerciales). Sin campo en
--     /configuracion por ahora. El SELECT es de tabla: la columna no necesita
--     grant propio. NOT NULL DEFAULT: un INSERT que no la nombra toma 24.
-- ---------------------------------------------------------------------------
ALTER TABLE public.politicas_comerciales
  ADD COLUMN ventana_precio_anterior_horas integer NOT NULL DEFAULT 24
  CONSTRAINT politicas_comerciales_ventana_precio_anterior_horas_check
  CHECK (ventana_precio_anterior_horas BETWEEN 0 AND 168);

-- ---------------------------------------------------------------------------
-- 1c. Auditoria de las escalas (mismo molde que audit_grupo_precio_escala_minimos):
--     sin ella el replay no ve el precio anterior de una escala.
-- ---------------------------------------------------------------------------
CREATE TRIGGER audit_grupo_precio_escalas
  AFTER INSERT OR DELETE OR UPDATE ON public.grupo_precio_escalas
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- ---------------------------------------------------------------------------
-- 1d. El piso de una linea de venta (pura). Espejo con gate de paridad:
--     src/utils/pisoPrecio.espejo.json corre en vitest contra orquestarPrecios
--     y en scripts/espejo-piso-precio.mjs contra esta funcion. Si cambia una,
--     cambia la otra y se suma el caso.
-- ---------------------------------------------------------------------------
-- p_items: las lineas del pedido como las manda el front (los regalos no
-- suman). p_grupos: [{grupo_id, productos: [ids], escalas: [{cantidad_minima,
-- precio_unitario, min_productos_distintos, minimos: [{producto_id,
-- cantidad_minima_por_item, precio_unitario_override}]}]}]. p_cliente:
-- {descuento_porcentaje, descuentos_categoria: [{categoria,
-- descuento_porcentaje}]}. Con p_lista NULL o <= 0 devuelve NULL (el cargador
-- rechaza).
--
-- Una escala aplica si cumple las reglas 1 y 3 de escalaAplica
-- (src/utils/precioMayorista.ts) sobre todas las lineas de venta: 1, el total
-- del grupo >= cantidad_minima; 3, los productos del grupo que cuentan
-- (cantidad > 0 y >= su minimo individual, si tiene) >= GREATEST(1,
-- min_productos_distintos). La regla 2 (un producto presente por debajo de su
-- minimo descalifica la escala) se omite A PROPOSITO: solo puede descalificar,
-- y omitirla deja el piso mas bajo o igual, nunca mas alto que el front. Las
-- reglas 1 y 3 son monotonas: con mas cantidad (el front saca las lineas que
-- reclamo una promo) aplican las mismas o mas escalas. Y se toma el MENOR
-- precio efectivo de todas las que aplican (el front elige la de mayor umbral).
-- Precio efectivo: el override del producto si es > 0; si no, el de la escala.
-- % del cliente: el de su categoria si coincide (upper(trim)), aunque sea 0;
-- si no, el general. Es resolverDescuentoPctCliente
-- (src/utils/descuentoCliente.ts).
CREATE OR REPLACE FUNCTION public.precio_piso_linea(
  p_items jsonb, p_grupos jsonb, p_producto_id bigint, p_lista numeric, p_cliente jsonb, p_categoria text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
  WITH ventas AS (
    SELECT NULLIF(e->>'producto_id', '')::numeric AS producto,
           SUM(COALESCE(NULLIF(e->>'cantidad', '')::numeric, 0)) AS cantidad
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                     THEN p_items ELSE '[]'::jsonb END) e
     WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
       AND NULLIF(e->>'producto_id', '') IS NOT NULL
     GROUP BY 1
  ), grupos AS (
    SELECT g,
           ARRAY(SELECT NULLIF(x, '')::numeric
                   FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(g->'productos') = 'array'
                                                       THEN g->'productos' ELSE '[]'::jsonb END) x) AS productos
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_grupos) = 'array'
                                     THEN p_grupos ELSE '[]'::jsonb END) g
  ), escalas AS (
    SELECT gr.productos, es,
           CASE WHEN jsonb_typeof(es->'minimos') = 'array' THEN es->'minimos' ELSE '[]'::jsonb END AS minimos
      FROM grupos gr
      CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(gr.g->'escalas') = 'array'
                                                   THEN gr.g->'escalas' ELSE '[]'::jsonb END) es
     WHERE p_producto_id::numeric = ANY(gr.productos)
  ), aplicables AS (
    SELECT CASE WHEN COALESCE(ov.precio, 0) > 0 THEN ov.precio
                ELSE NULLIF(s.es->>'precio_unitario', '')::numeric END AS precio
      FROM escalas s
      LEFT JOIN LATERAL (
        SELECT NULLIF(m->>'precio_unitario_override', '')::numeric AS precio
          FROM jsonb_array_elements(s.minimos) WITH ORDINALITY AS t(m, o)
         WHERE NULLIF(m->>'producto_id', '')::numeric = p_producto_id::numeric
         ORDER BY o
         LIMIT 1) ov ON true
     -- regla 1
     WHERE (SELECT COALESCE(SUM(v.cantidad), 0) FROM ventas v WHERE v.producto = ANY(s.productos))
             >= COALESCE(NULLIF(s.es->>'cantidad_minima', '')::numeric, 0)
       -- regla 3
       AND (SELECT count(*)
              FROM ventas v
             WHERE v.producto = ANY(s.productos)
               AND v.cantidad > 0
               AND v.cantidad >= COALESCE(
                     (SELECT NULLIF(m->>'cantidad_minima_por_item', '')::numeric
                        FROM jsonb_array_elements(s.minimos) WITH ORDINALITY AS t(m, o)
                       WHERE NULLIF(m->>'producto_id', '')::numeric = v.producto
                       ORDER BY o
                       LIMIT 1), 0))
             >= GREATEST(1, COALESCE(NULLIF(s.es->>'min_productos_distintos', '')::numeric, 1))
  ), pct AS (
    SELECT COALESCE(
             (SELECT COALESCE(NULLIF(d->>'descuento_porcentaje', '')::numeric, 0)
                FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_cliente->'descuentos_categoria') = 'array'
                                               THEN p_cliente->'descuentos_categoria' ELSE '[]'::jsonb END)
                     WITH ORDINALITY AS t(d, o)
               WHERE NULLIF(p_categoria, '') IS NOT NULL
                 AND upper(trim(COALESCE(d->>'categoria', ''))) = upper(trim(p_categoria))
               ORDER BY o
               LIMIT 1),
             COALESCE(NULLIF(p_cliente->>'descuento_porcentaje', '')::numeric, 0)) AS v
  ), base AS (
    -- LEAST ignora el NULL: sin escalas aplicables, la lista.
    SELECT LEAST(p_lista, (SELECT min(a.precio) FROM aplicables a)) AS v
  )
  SELECT CASE WHEN p_lista IS NULL OR p_lista <= 0 THEN NULL
              WHEN (SELECT v FROM pct) > 0 THEN round((SELECT v FROM base) * (1 - (SELECT v FROM pct) / 100), 2)
              ELSE (SELECT v FROM base) END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1e. El cargador: arma la lista de referencia, los grupos y el cliente de
--     cada producto de venta y devuelve el motivo del primer precio que cae
--     bajo el piso, o NULL. Solo lectura. Lo llaman las RPCs para quien no es
--     admin.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.precio_fuera_de_politica(
  p_items jsonb, p_cliente_id bigint, p_sucursal bigint, p_pedido_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
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
      SELECT min(pi.precio_unitario) INTO v_guardado
        FROM pedido_items pi
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
         AND NOT COALESCE(pi.es_bonificacion, false) AND pi.producto_id = r.producto;
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
  END LOOP;

  RETURN NULL;
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1f. El helper del check PRECIO-A (molde: auditoria_funciones_costo_sin_valuacion,
--     mig 257): funciones de public que insertan pedido_items sin llamar a
--     precio_fuera_de_politica. Excepciones, a proposito:
--       * crear_pedido_completo_bot: corre como service_role y precia del lado
--         del server (orquestarPrecios en el edge function).
--       * dividir_regalo_pedido: solo inserta regalos (precio 0, por CHECK).
--       * anular_salvedad: reinserta la linea original con el precio guardado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_funciones_pedido_items_sin_piso()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
  SELECT count(*)
    FROM pg_proc f
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.prokind = 'f'
     AND f.proname NOT IN ('crear_pedido_completo_bot', 'dividir_regalo_pedido', 'anular_salvedad')
     AND pg_get_functiondef(f.oid) ~* 'INSERT\s+INTO\s+(public\.)?pedido_items[\s(]'
     AND pg_get_functiondef(f.oid) NOT ILIKE '%precio_fuera_de_politica%';
$fn$;

-- ---------------------------------------------------------------------------
-- 1g. Grants (CLAUDE.md): las tres son de server. Las llaman las RPCs
--     SECURITY DEFINER, auditoria_integridad y los gates como service_role.
--     Ningun parametro es SMALLINT (trampa 5).
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.precio_piso_linea(jsonb, jsonb, bigint, numeric, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.precio_fuera_de_politica(jsonb, bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.auditoria_funciones_pedido_items_sin_piso() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.precio_piso_linea(jsonb, jsonb, bigint, numeric, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.precio_fuera_de_politica(jsonb, bigint, bigint, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.auditoria_funciones_pedido_items_sin_piso() TO service_role;

-- ---------------------------------------------------------------------------
-- 1h-1j. Parches por ancla sobre la definicion viva.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- 1h. crear_pedido_completo: despues del total de la 235 y de la compra
--     minima, antes de toda escritura.
DO $crear$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  IF p_preventista_id IS NULL OR p_preventista_id = p_usuario_id THEN
$q$,
$q$  -- mig #1138: el regalo va a precio 0, para cualquier rol (y CHECK
  -- pedido_items_regalo_a_precio_cero). Con otro precio sumaba a pedidos.total
  -- y no al neto ni al IVA.
  IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_regalo_caro JSONB;
    BEGIN
      SELECT e INTO v_regalo_caro
        FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, o)
       WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
         AND COALESCE(NULLIF(e->>'precio_unitario', '')::NUMERIC, 0) <> 0
       ORDER BY o
       LIMIT 1;
      IF v_regalo_caro IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
          'Un regalo va a precio 0: el regalo de %s vino a %s. El pedido no se creó.',
          COALESCE((SELECT nombre FROM productos
                     WHERE id = NULLIF(v_regalo_caro->>'producto_id', '')::BIGINT AND sucursal_id = v_sucursal),
                   'el producto ID ' || COALESCE(v_regalo_caro->>'producto_id', '?')),
          to_char(NULLIF(v_regalo_caro->>'precio_unitario', '')::NUMERIC, 'FM$999G999G990D00'))));
      END IF;
    END;
  END IF;

  -- mig #1139: el precio de venta de quien no es admin no baja del piso de la
  -- lista (precio_fuera_de_politica: lista o escala aplicable menos el
  -- descuento del cliente, con el precio inmediatamente anterior para el
  -- replay). El VB lo precia el server. Mismo criterio de rol que #1112 y
  -- #1123 (perfiles.rol). crear_pedido_idempotente pasa por aca.
  IF v_user_role <> 'admin' AND v_tipo_factura <> 'VB'
     AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_motivo_precio TEXT;
    BEGIN
      v_motivo_precio := public.precio_fuera_de_politica(p_items, p_cliente_id, v_sucursal, NULL);
      IF v_motivo_precio IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_precio || ' El pedido no se creó.'));
      END IF;
    END;
  END IF;

  IF p_preventista_id IS NULL OR p_preventista_id = p_usuario_id THEN
$q$, 'crear_pedido_completo ancla del preventista');
  EXECUTE v_def;
END
$crear$;

-- 1i. actualizar_pedido_items: despues de la guarda de #1123 y del bloque del
--     preventista, antes del DELETE (las lineas guardadas todavia estan).
DO $editar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  -- mig 313 (#996): con la descripcion de cada linea y en un orden que no
$q$,
$q$  -- mig #1138: el regalo va a precio 0, para cualquier rol. Se mira lo que
  -- mando el llamador y lo que se va a guardar (las lineas conservadas de un
  -- reparto ya van a 0). Con otro precio, pedidos.total dejaba de ser
  -- SUM(subtotal) (VENTA-A).
  DECLARE
    v_regalo_caro JSONB;
  BEGIN
    SELECT e INTO v_regalo_caro
      FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(p_items_nuevos) = 'array' THEN p_items_nuevos ELSE '[]'::jsonb END
             || COALESCE(v_items, '[]'::jsonb)) WITH ORDINALITY AS x(e, o)
     WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
       AND COALESCE(NULLIF(e->>'precio_unitario', '')::NUMERIC, 0) <> 0
     ORDER BY o
     LIMIT 1;
    IF v_regalo_caro IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
        'Un regalo va a precio 0: el regalo de %s vino a %s. El pedido no se modificó.',
        COALESCE((SELECT nombre FROM productos
                   WHERE id = NULLIF(v_regalo_caro->>'producto_id', '')::BIGINT AND sucursal_id = v_sucursal),
                 'el producto ID ' || COALESCE(v_regalo_caro->>'producto_id', '?')),
        to_char(NULLIF(v_regalo_caro->>'precio_unitario', '')::NUMERIC, 'FM$999G999G990D00'))));
    END IF;
  END;

  -- mig #1139: el precio de venta de quien no es admin no baja del piso de la
  -- lista, tambien al editar (incluye al encargado; el techo del preventista
  -- de arriba queda igual). Con p_pedido_id: el precio guardado se conserva
  -- si la edicion no achica ningun grupo del producto.
  IF v_user_role <> 'admin' THEN
    DECLARE
      v_motivo_precio TEXT;
    BEGIN
      v_motivo_precio := public.precio_fuera_de_politica(
        v_items,
        (SELECT cliente_id FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal),
        v_sucursal, p_pedido_id);
      IF v_motivo_precio IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_precio || ' El pedido no se modificó.'));
      END IF;
    END;
  END IF;

  -- mig 313 (#996): con la descripcion de cada linea y en un orden que no
$q$, 'actualizar_pedido_items ancla de la mig 313');
  EXECUTE v_def;
END
$editar$;

-- 1j. auditoria_integridad: el check PRECIO-A (la familia PRECIO-* estaba
--     libre). Sus grants quedan como estan (CREATE OR REPLACE los conserva).
DO $auditoria$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
BEGIN
  IF strpos(v_def, '''PRECIO-') > 0 THEN
    RAISE EXCEPTION 'auditoria_integridad ya tiene un check PRECIO-*: elegir otro id';
  END IF;
  v_def := pg_temp.rr_parchar(v_def,
$q$    ('COSTO-D','high',$q$,
$q$    ('PRECIO-A','high','funciones de public que insertan pedido_items sin pasar por precio_fuera_de_politica (#1139)',
      (SELECT public.auditoria_funciones_pedido_items_sin_piso())),
    ('COSTO-D','high',$q$, 'auditoria_integridad ancla de COSTO-D');
  EXECUTE v_def;
END
$auditoria$;

-- ---------------------------------------------------------------------------
-- 1k. Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_cre text := 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)';
  f_act text := 'public.actualizar_pedido_items(bigint,jsonb,uuid)';
  f_aud text := 'public.auditoria_integridad()';
  f_piso text := 'public.precio_piso_linea(jsonb,jsonb,bigint,numeric,jsonb,text)';
  f_fue text := 'public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)';
  f_hlp text := 'public.auditoria_funciones_pedido_items_sin_piso()';
  v_cre text := pg_get_functiondef(f_cre::regprocedure);
  v_act text := pg_get_functiondef(f_act::regprocedure);
  v_aud text := pg_get_functiondef(f_aud::regprocedure);
  f     text;
  v_chk jsonb;
BEGIN
  -- Las llamadas y el mensaje de #1138, antes de la primera escritura.
  IF v_cre NOT LIKE '%public.precio_fuera_de_politica(p_items, p_cliente_id, v_sucursal, NULL)%'
     OR v_cre NOT LIKE '%Un regalo va a precio 0%'
     OR strpos(v_cre, 'precio_fuera_de_politica') > strpos(v_cre, 'INSERT INTO pedidos')
     OR strpos(v_cre, 'Un regalo va a precio 0') > strpos(v_cre, 'INSERT INTO pedidos')
     -- despues del total de la 235
     OR strpos(v_cre, 'precio_fuera_de_politica') < strpos(v_cre, 'pedido_incumple_minimo') THEN
    RAISE EXCEPTION 'crear_pedido_completo no quedo como se esperaba';
  END IF;
  IF v_act NOT LIKE '%public.precio_fuera_de_politica(%v_items,%v_sucursal, p_pedido_id);%'
     OR v_act NOT LIKE '%Un regalo va a precio 0%'
     OR strpos(v_act, 'precio_fuera_de_politica') > strpos(v_act, 'DELETE FROM pedido_items')
     OR strpos(v_act, 'Un regalo va a precio 0') > strpos(v_act, 'DELETE FROM pedido_items')
     -- despues de la guarda del regalo (#1123)
     OR strpos(v_act, 'precio_fuera_de_politica') < strpos(v_act, 'regalo_fuera_de_promo') THEN
    RAISE EXCEPTION 'actualizar_pedido_items no quedo como se esperaba';
  END IF;

  FOREACH f IN ARRAY ARRAY[f_cre, f_act] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure)
       OR (SELECT proconfig FROM pg_proc WHERE oid = f::regprocedure) IS DISTINCT FROM ARRAY['search_path=public'] THEN
      RAISE EXCEPTION '% dejo de ser SECURITY DEFINER con search_path=public', f;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'los EXECUTE de % cambiaron', f;
    END IF;
  END LOOP;

  -- Las tres nuevas: de server.
  FOREACH f IN ARRAY ARRAY[f_piso, f_fue, f_hlp] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE')
       OR NOT has_function_privilege('service_role', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'los EXECUTE de % no quedaron como se esperaba (solo service_role)', f;
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure)
       OR (SELECT proconfig FROM pg_proc WHERE oid = f::regprocedure) IS DISTINCT FROM ARRAY['search_path=public'] THEN
      RAISE EXCEPTION '% no quedo invoker con search_path=public', f;
    END IF;
  END LOOP;

  -- Una sola sobrecarga de cada una (PGRST203).
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('crear_pedido_completo', 'actualizar_pedido_items', 'auditoria_integridad',
                                'precio_piso_linea', 'precio_fuera_de_politica',
                                'auditoria_funciones_pedido_items_sin_piso')
              GROUP BY proname HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'alguna de las funciones quedo con mas de una sobrecarga';
  END IF;

  -- El CHECK, la columna y el trigger.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pedido_items'::regclass
                    AND conname = 'pedido_items_regalo_a_precio_cero' AND convalidated) THEN
    RAISE EXCEPTION 'falta el CHECK pedido_items_regalo_a_precio_cero validado';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.grupo_precio_escalas'::regclass
                    AND tgname = 'audit_grupo_precio_escalas' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'falta el trigger audit_grupo_precio_escalas';
  END IF;
  IF NOT has_column_privilege('authenticated', 'public.politicas_comerciales', 'ventana_precio_anterior_horas', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated no puede leer politicas_comerciales.ventana_precio_anterior_horas';
  END IF;

  -- PRECIO-A una sola vez y en 0.
  IF (length(v_aud) - length(replace(v_aud, '''PRECIO-A''', ''))) / length('''PRECIO-A''') <> 1 THEN
    RAISE EXCEPTION 'PRECIO-A no aparece exactamente una vez en auditoria_integridad';
  END IF;
  SELECT c INTO v_chk
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
   WHERE c->>'id' = 'PRECIO-A';
  IF v_chk IS NULL OR (v_chk->>'violaciones')::bigint IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'PRECIO-A no da 0: %', v_chk;
  END IF;
END
$verif$;
