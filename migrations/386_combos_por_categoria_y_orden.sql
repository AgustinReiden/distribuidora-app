-- =========================================================================
-- 386 · Combos: un lugar puede ser una categoría, y la prioridad es un orden
-- (#1213, parte de #1190)
--
-- 1. Un lugar del combo puede apuntar a una categoría o subcategoría, además
--    de productos sueltos. La categoría es VIVA: el combo guarda la categoría,
--    no la lista del día. `_combo_definicion` la resuelve a los productos
--    activos de la sucursal con `categoria_id` o `subcategoria_id` igual, así
--    que todo lo que vende (`combos_vigentes`, `combo_fuera_de_regla`, la foto
--    de `_guardar_combos_pedido`) sigue recibiendo una lista de productos: el
--    motor del front y el espejo no cambian. Un producto que cae en dos
--    lugares (un cambio de catálogo después de guardar) queda en el de número
--    más bajo. Un combo con un lugar sin productos activos no se ofrece.
-- 2. `guardar_combo` acepta `categorias` por lugar y un `orden` opcional: los
--    ids del grupo que compite, de arriba (gana) a abajo, con 0 = este combo.
--    Reescribe `prioridad` de esos combos en la misma transacción. El orden lo
--    calcula el front (`src/utils/comboOrden.ts`); el server sólo lo aplica.
--
-- Los EXECUTE de las tres funciones no cambian (CREATE OR REPLACE los
-- conserva): guardar_combo y combos_vigentes para authenticated, sin anon;
-- _combo_definicion sólo de server.
-- =========================================================================

ALTER TABLE public.combo_componentes
  ALTER COLUMN producto_id DROP NOT NULL,
  ADD COLUMN categoria_id uuid;

-- Compuesta, como el resto del aislamiento por sucursal (trampa 6). Sin
-- CASCADE: borrar una categoría que usa un combo se frena y no le vacía un
-- lugar al combo en silencio.
ALTER TABLE public.combo_componentes
  ADD CONSTRAINT combo_componentes_categoria_fkey
    FOREIGN KEY (categoria_id, sucursal_id) REFERENCES public.categorias (id, sucursal_id),
  ADD CONSTRAINT combo_componentes_producto_o_categoria
    CHECK (num_nonnulls(producto_id, categoria_id) = 1),
  ADD CONSTRAINT combo_componentes_categoria_key UNIQUE (combo_id, categoria_id);

CREATE INDEX IF NOT EXISTS combo_componentes_categoria_idx
  ON public.combo_componentes (categoria_id) WHERE categoria_id IS NOT NULL;


CREATE OR REPLACE FUNCTION public._combo_definicion(p_combo_id bigint, p_sucursal bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  WITH miembros AS (
    -- Productos sueltos, tal cual (como hasta ahora: también un inactivo).
    SELECT cc.componente, cc.producto_id AS producto
      FROM combo_componentes cc
     WHERE cc.combo_id = p_combo_id AND cc.sucursal_id = p_sucursal AND cc.producto_id IS NOT NULL
    UNION
    -- Categorías: los productos activos de hoy.
    SELECT cc.componente, p.id
      FROM combo_componentes cc
      JOIN productos p ON p.sucursal_id = cc.sucursal_id AND p.activo
                      AND (p.categoria_id = cc.categoria_id OR p.subcategoria_id = cc.categoria_id)
     WHERE cc.combo_id = p_combo_id AND cc.sucursal_id = p_sucursal AND cc.categoria_id IS NOT NULL
  ), unico AS (
    -- Un producto en un solo lugar: el de número más bajo.
    SELECT producto, min(componente) AS componente FROM miembros GROUP BY producto
  ), lugares AS (
    SELECT cc.componente, min(cc.cantidad) AS cantidad
      FROM combo_componentes cc
     WHERE cc.combo_id = p_combo_id AND cc.sucursal_id = p_sucursal
     GROUP BY cc.componente
  )
  SELECT jsonb_build_object(
           'nombre', c.nombre,
           'precio', c.precio,
           'combina_escalas', c.combina_escalas,
           'componentes', (SELECT jsonb_agg(jsonb_build_object(
                                    'componente', l.componente,
                                    'cantidad', l.cantidad,
                                    'productos', COALESCE((SELECT jsonb_agg(u.producto ORDER BY u.producto)
                                                             FROM unico u WHERE u.componente = l.componente),
                                                          '[]'::jsonb))
                                  ORDER BY l.componente)
                             FROM lugares l))
    FROM combos c
   WHERE c.id = p_combo_id AND c.sucursal_id = p_sucursal;
$fn$;


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
       AND jsonb_typeof(d.def->'componentes') = 'array'
       -- #1213: una categoría que se quedó sin productos activos deja el lugar
       -- vacío, y ese combo no se puede armar.
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(d.def->'componentes') x
                        WHERE jsonb_array_length(x->'productos') = 0)), '[]'::jsonb);
END
$fn$;


CREATE OR REPLACE FUNCTION public.guardar_combo(p_combo jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_id       bigint;
  v_nombre   text;
  v_precio   numeric;
  v_inicio   date;
  v_fin      date;
  v_activo   boolean;
  v_escalas  boolean;
  v_prior    integer;
  v_tope     integer;
  v_mover    bigint;
  v_comp     jsonb;
  v_unidades integer;
  v_prods    bigint[];
  v_cats     uuid[];
  v_orden    bigint[];
  v_resueltos bigint[];
  v_err      text;
  v_lugar    integer;
  v_nombre_rep text;
BEGIN
  IF NOT public.es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo un admin puede crear o editar combos.');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa.');
  END IF;
  IF jsonb_typeof(p_combo) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Faltan los datos del combo.');
  END IF;

  BEGIN
    v_id      := NULLIF(p_combo->>'id', '')::bigint;
    v_nombre  := btrim(COALESCE(p_combo->>'nombre', ''));
    v_precio  := NULLIF(p_combo->>'precio', '')::numeric;
    v_inicio  := NULLIF(p_combo->>'fecha_inicio', '')::date;
    v_fin     := NULLIF(p_combo->>'fecha_fin', '')::date;
    v_activo  := COALESCE((p_combo->>'activo')::boolean, true);
    v_escalas := COALESCE((p_combo->>'combina_escalas')::boolean, false);
    v_prior   := COALESCE(NULLIF(p_combo->>'prioridad', '')::integer, 0);
    v_tope    := NULLIF(p_combo->>'tope_combos', '')::integer;
    v_mover   := NULLIF(p_combo->>'producto_a_mover_id', '')::bigint;
    IF jsonb_typeof(p_combo->'orden') = 'array' THEN
      SELECT array_agg(x::bigint ORDER BY o) INTO v_orden
        FROM jsonb_array_elements_text(p_combo->'orden') WITH ORDINALITY AS e(x, o);
    END IF;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay un dato del combo con un formato inválido.');
  END;
  v_comp := CASE WHEN jsonb_typeof(p_combo->'componentes') = 'array' THEN p_combo->'componentes' ELSE '[]'::jsonb END;

  v_err := CASE
    WHEN v_nombre = '' THEN 'El combo necesita un nombre.'
    WHEN v_precio IS NULL OR NOT (v_precio > 0 AND v_precio <= 9999999999.99) THEN 'El precio del combo tiene que ser mayor que cero.'
    WHEN v_precio <> round(v_precio, 2) THEN 'El precio del combo va con dos decimales como máximo.'
    WHEN v_inicio IS NULL THEN 'El combo necesita una fecha de inicio.'
    WHEN v_fin IS NOT NULL AND v_fin < v_inicio THEN 'La fecha de fin no puede ser anterior a la de inicio.'
    WHEN v_tope IS NOT NULL AND v_tope <= 0 THEN 'El tope de combos tiene que ser mayor que cero.'
    WHEN jsonb_array_length(v_comp) = 0 THEN 'El combo necesita al menos un producto.'
    WHEN jsonb_array_length(v_comp) > 20 THEN 'Un combo puede tener hasta 20 lugares.'
  END;
  IF v_err IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', v_err);
  END IF;

  -- Cada lugar: una cantidad y al menos un producto o una categoría.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_comp) c
              WHERE COALESCE(c->>'cantidad', '') !~ '^[0-9]{1,4}$'
                 OR (c->>'cantidad')::integer NOT BETWEEN 1 AND 1000
                 OR jsonb_typeof(COALESCE(c->'productos', '[]'::jsonb)) IS DISTINCT FROM 'array'
                 OR jsonb_typeof(COALESCE(c->'categorias', '[]'::jsonb)) IS DISTINCT FROM 'array'
                 OR jsonb_array_length(COALESCE(c->'productos', '[]'::jsonb))
                    + jsonb_array_length(COALESCE(c->'categorias', '[]'::jsonb)) = 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Cada lugar del combo necesita una cantidad entre 1 y 1000 y al menos un producto o una categoría.');
  END IF;
  SELECT COALESCE(sum((c->>'cantidad')::integer), 0) INTO v_unidades FROM jsonb_array_elements(v_comp) c;
  IF v_unidades < 2 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Un combo junta al menos dos unidades.');
  END IF;
  BEGIN
    SELECT array_agg(p::bigint) INTO v_prods
      FROM jsonb_array_elements(v_comp) c
     CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(c->'productos', '[]'::jsonb)) p;
    SELECT array_agg(g::uuid) INTO v_cats
      FROM jsonb_array_elements(v_comp) c
     CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(c->'categorias', '[]'::jsonb)) g;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto o una categoría del combo con un formato inválido.');
  END;
  v_prods := COALESCE(v_prods, '{}');
  v_cats := COALESCE(v_cats, '{}');
  IF cardinality(v_prods) <> (SELECT count(DISTINCT x) FROM unnest(v_prods) x) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Un producto no puede estar dos veces en el mismo combo.');
  END IF;
  IF cardinality(v_cats) <> (SELECT count(DISTINCT x) FROM unnest(v_cats) x) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Una categoría no puede estar dos veces en el mismo combo.');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_prods) x
              WHERE NOT EXISTS (SELECT 1 FROM productos pr WHERE pr.id = x AND pr.sucursal_id = v_sucursal)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto del combo que no es de esta sucursal.');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_cats) x
              WHERE NOT EXISTS (SELECT 1 FROM categorias ca
                                 WHERE ca.id = x AND ca.sucursal_id = v_sucursal AND ca.activa)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay una categoría del combo que no es de esta sucursal o está inactiva.');
  END IF;

  -- Lo que el combo vende hoy, lugar por lugar, con la misma regla que
  -- _combo_definicion: sueltos tal cual, categorías por sus productos activos.
  CREATE TEMP TABLE IF NOT EXISTS _combo_resuelto (lugar integer, producto bigint) ON COMMIT DROP;
  TRUNCATE _combo_resuelto;
  INSERT INTO _combo_resuelto
  SELECT DISTINCT l.o::integer, m.producto
    FROM jsonb_array_elements(v_comp) WITH ORDINALITY AS l(x, o)
   CROSS JOIN LATERAL (
     SELECT p::bigint AS producto FROM jsonb_array_elements_text(COALESCE(l.x->'productos', '[]'::jsonb)) p
     UNION
     SELECT pr.id FROM jsonb_array_elements_text(COALESCE(l.x->'categorias', '[]'::jsonb)) g
       JOIN productos pr ON pr.sucursal_id = v_sucursal AND pr.activo
                        AND (pr.categoria_id = g::uuid OR pr.subcategoria_id = g::uuid)) m;

  SELECT pr.nombre INTO v_nombre_rep
    FROM _combo_resuelto r JOIN productos pr ON pr.id = r.producto
   GROUP BY pr.id, pr.nombre HAVING count(DISTINCT r.lugar) > 1
   ORDER BY pr.id LIMIT 1;
  IF v_nombre_rep IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('«%s» queda en dos lugares del combo (por un producto o una categoría). Un producto va en un solo lugar.', v_nombre_rep));
  END IF;
  SELECT l.o::integer INTO v_lugar
    FROM jsonb_array_elements(v_comp) WITH ORDINALITY AS l(x, o)
   WHERE NOT EXISTS (SELECT 1 FROM _combo_resuelto r WHERE r.lugar = l.o)
   ORDER BY l.o LIMIT 1;
  IF v_lugar IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('El lugar %s del combo no tiene ningún producto activo.', v_lugar));
  END IF;
  SELECT array_agg(producto) INTO v_resueltos FROM _combo_resuelto;
  IF v_mover IS NOT NULL AND NOT (v_mover = ANY(v_resueltos)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El producto a mover tiene que ser uno de los del combo.');
  END IF;

  -- El orden: ids distintos, de esta sucursal, y este combo una sola vez (0
  -- si es nuevo).
  IF v_orden IS NOT NULL THEN
    IF cardinality(v_orden) <> (SELECT count(DISTINCT x) FROM unnest(v_orden) x)
       OR (SELECT count(*) FROM unnest(v_orden) x WHERE x = 0 OR x = v_id) <> 1
       OR EXISTS (SELECT 1 FROM unnest(v_orden) x
                   WHERE x <> 0 AND x IS DISTINCT FROM v_id
                     AND NOT EXISTS (SELECT 1 FROM combos co WHERE co.id = x AND co.sucursal_id = v_sucursal)) THEN
      RETURN jsonb_build_object('success', false, 'error', 'El orden de los combos no es válido. Recargá e intentá de nuevo.');
    END IF;
    v_prior := cardinality(v_orden) + 1
               - COALESCE(array_position(v_orden, v_id), array_position(v_orden, 0::bigint));
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO combos (sucursal_id, nombre, activo, fecha_inicio, fecha_fin, precio, combina_escalas,
                        prioridad, tope_combos, producto_a_mover_id, creado_por)
    VALUES (v_sucursal, v_nombre, v_activo, v_inicio, v_fin, v_precio, v_escalas,
            v_prior, v_tope, v_mover, auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE combos
       SET nombre = v_nombre, activo = v_activo, fecha_inicio = v_inicio, fecha_fin = v_fin,
           precio = v_precio, combina_escalas = v_escalas, prioridad = v_prior,
           tope_combos = v_tope, producto_a_mover_id = v_mover, updated_at = now()
     WHERE id = v_id AND sucursal_id = v_sucursal;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'El combo no existe en esta sucursal.');
    END IF;
    DELETE FROM combo_componentes WHERE combo_id = v_id AND sucursal_id = v_sucursal;
  END IF;

  -- Los demás del grupo: prioridad = posición contando desde abajo.
  IF v_orden IS NOT NULL THEN
    UPDATE combos co
       SET prioridad = cardinality(v_orden) - e.o::integer + 1
      FROM unnest(v_orden) WITH ORDINALITY AS e(x, o)
     WHERE co.id = e.x AND co.sucursal_id = v_sucursal AND e.x <> 0 AND e.x <> v_id;
  END IF;

  INSERT INTO combo_componentes (combo_id, sucursal_id, componente, producto_id, cantidad)
  SELECT v_id, v_sucursal, c.o::integer, p::bigint, (c.x->>'cantidad')::integer
    FROM jsonb_array_elements(v_comp) WITH ORDINALITY AS c(x, o)
   CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(c.x->'productos', '[]'::jsonb)) p;
  INSERT INTO combo_componentes (combo_id, sucursal_id, componente, categoria_id, cantidad)
  SELECT v_id, v_sucursal, c.o::integer, g::uuid, (c.x->>'cantidad')::integer
    FROM jsonb_array_elements(v_comp) WITH ORDINALITY AS c(x, o)
   CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(c.x->'categorias', '[]'::jsonb)) g;

  RETURN jsonb_build_object('success', true, 'id', v_id);
END
$fn$;


-- Verificación: los EXECUTE siguen como antes y la definición de un combo
-- sólo de productos no cambió de forma.
DO $verif$
BEGIN
  IF has_function_privilege('anon', 'public.guardar_combo(jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.combos_vigentes(date,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._combo_definicion(bigint,bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.guardar_combo(jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.combos_vigentes(date,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'los EXECUTE de las funciones de combos cambiaron';
  END IF;
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
              WHERE firma IN ('combos_vigentes(date,bigint)', 'guardar_combo(jsonb)')) THEN
    RAISE EXCEPTION 'SEG-A ve una función de combos sin guard de rol';
  END IF;
END
$verif$;
