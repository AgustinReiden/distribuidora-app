-- 408 · Los combos cobran exacto, la edición topa la fecha del combo a hoy y el
-- límite de usos de una promo se hace cumplir al vender (#1259, #1260, #1261).
--
-- 1 · #1259 · _combo_prorrateo cierra exacto. Cuando ninguna línea divide lo que
--     sobra (o falta) del redondeo —un 2 + 3, o un lugar partido entre
--     alternativas— el reparto daba un total corrido: "2 + 3 a $1.000,01"
--     cobraba $1.000,00. Ahora la que absorbe es la de menor cantidad, y antes
--     cada una de las otras, de la más cara a la más barata, toma el precio más
--     cercano a su proporción que deja el resto divisible por el mcd de las
--     cantidades que faltan (a igual distancia, el mayor). La última toma el
--     resto, que la divide. Si el mcd de TODAS las cantidades no divide el total
--     no hay precios unitarios que lo den ("2 por $999,99": dos unidades al
--     mismo precio dan un total par) y devuelve NULL; combo_fuera_de_regla lo
--     rechaza. Espejo: prorratearTotal (src/utils/combos.ts), fixture
--     combos.espejo.json. Cuando alguna línea divide el resto, el resultado es
--     el de siempre.
--
-- 2 · #1259 · guardar_combo no deja crear un combo cuyo precio no se reparte
--     exacto: el mcd de las cantidades de los lugares tiene que dividir el
--     precio en centavos. Con eso el reparto de (1) cierra para cualquier
--     cantidad de combos, cualquier mezcla de alternativas y también en un
--     acumulable (lo que resta la escala es múltiplo de cada cantidad). Espejo:
--     precioRepartible. Combos tiene 0 filas en prod: no hay combos viejos que
--     queden fuera de la regla.
--
-- 3 · combo_fuera_de_regla:
--     * #1259: compara lo que cobran las líneas (Σ cantidad × precio) contra el
--       total del combo, al centavo, además del reparto línea por línea.
--     * #1260: la vigencia se mide en LEAST(fecha, hoy) también en la edición
--       (la regla de #1152 en CLAUDE.md, como regalo_fuera_de_promo). Antes la
--       edición medía en la fecha del pedido sin tope, y un combo que empieza en
--       la fecha futura del pedido entraba al editarlo.
--
-- 4 · #1261 · El límite de usos de una promo se hace cumplir al vender. Decisión
--     del dueño (2026-10-28): un uso es una UNIDAD DE REGALO, contada en las
--     líneas de regalo de la promo de los pedidos no cancelados (en una promo
--     con fracción, subunidades: botellas sueltas, no fardos), y no lo pasa
--     nadie, tampoco el admin. Antes lo miraba sólo check_promo_limite_usos,
--     que apagaba la promo DESPUÉS del pedido que cruzaba el límite, sólo en
--     las promos sin fracción, y contando usos_pendientes, que baja con los
--     ajustes y en las de fracción es el resto de la barra.
--     Ahora un constraint trigger diferido sobre pedido_items cuenta al
--     confirmar la transacción, con la promo bloqueada (dos ventas a la vez se
--     cuentan de a una), y rechaza si se pasa. Diferido para ver el estado
--     final: editar, sustituir o dividir un regalo, o cambiar el cliente,
--     borran y vuelven a insertar líneas, y en el medio pueden contar de más.
--     Al llegar al límite apaga la promo, como prometía la pantalla; una
--     cancelación devuelve las unidades al cupo, pero no la reactiva sola.
--     Y el límite no se puede bajar por debajo de lo ya regalado (bajarlo
--     justo ahí la apaga): así el conteo nunca arranca pasado y sólo se
--     rechaza lo que suma, nunca una salvedad o una edición que no agrega.
--     Es un trigger y no una línea de crear_pedido_completo/actualizar_pedido_items
--     /crear_pedido_completo_bot porque así cubre todos los caminos que
--     escriben regalos sin tocarlas.

-- ===========================================================================
-- 1 · _combo_prorrateo
-- ===========================================================================

CREATE OR REPLACE FUNCTION public._combo_prorrateo(p_total numeric, p_lineas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ids   bigint[];
  v_q     numeric[];
  v_c     numeric[];
  v_u     numeric[];
  v_otras integer[];
  n       integer;
  i       integer;
  k       integer;
  m       integer;
  v_j     integer;
  v_t     numeric := round(p_total * 100);
  v_r     numeric := 0;
  v_suma  numeric := 0;
  v_resto numeric;
  v_g     numeric := 0;
  v_x     numeric;
  v_y     numeric;
  v_falta numeric;
BEGIN
  IF jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' OR v_t IS NULL OR v_t <= 0 THEN
    RETURN NULL;
  END IF;
  SELECT array_agg(NULLIF(e->>'producto_id', '')::bigint ORDER BY o),
         array_agg(NULLIF(e->>'cantidad', '')::numeric ORDER BY o),
         array_agg(round(NULLIF(e->>'ref', '')::numeric * 100) ORDER BY o)
    INTO v_ids, v_q, v_c
    FROM jsonb_array_elements(p_lineas) WITH ORDINALITY AS t(e, o);
  n := COALESCE(cardinality(v_ids), 0);
  IF n = 0 THEN RETURN NULL; END IF;
  FOR i IN 1..n LOOP
    IF v_ids[i] IS NULL OR v_q[i] IS NULL OR v_q[i] <= 0 OR v_q[i] <> trunc(v_q[i])
       OR v_c[i] IS NULL OR v_c[i] <= 0 THEN
      RETURN NULL;
    END IF;
    v_r := v_r + v_q[i] * v_c[i];
    v_g := gcd(v_g, v_q[i]);
  END LOOP;
  -- #1259: sin el mcd de las cantidades dividiendo el total, no hay precios
  -- unitarios que lo den exacto ("2 por $999,99").
  IF mod(v_t, v_g) <> 0 THEN
    RETURN NULL;
  END IF;

  v_u := array_fill(0::numeric, ARRAY[n]);
  FOR i IN 1..n LOOP
    v_u[i] := div(2 * v_t * v_c[i] + v_r, 2 * v_r);
    v_suma := v_suma + v_q[i] * v_u[i];
  END LOOP;

  v_resto := v_t - v_suma;
  IF v_resto <> 0 THEN
    SELECT s.i INTO v_j
      FROM generate_subscripts(v_ids, 1) AS s(i)
     WHERE mod(v_resto, v_q[s.i]) = 0
     ORDER BY v_c[s.i] DESC, v_ids[s.i]
     LIMIT 1;
    IF v_j IS NOT NULL THEN
      v_u[v_j] := v_u[v_j] + div(v_resto, v_q[v_j]);
    ELSE
      -- #1259: ninguna línea sola divide el resto. Absorbe la de menor cantidad
      -- (a igual, la más cara; después el id); antes, cada una de las otras, de
      -- la más cara a la más barata, toma el precio más cercano a su proporción
      -- (T·c/R) que deja el resto divisible por el mcd de las cantidades que
      -- vienen después. A igual distancia, el mayor.
      SELECT s.i INTO v_j
        FROM generate_subscripts(v_ids, 1) AS s(i)
       ORDER BY v_q[s.i], v_c[s.i] DESC, v_ids[s.i]
       LIMIT 1;
      SELECT array_agg(s.i ORDER BY v_c[s.i] DESC, v_ids[s.i]) INTO v_otras
        FROM generate_subscripts(v_ids, 1) AS s(i)
       WHERE s.i <> v_j;
      v_falta := v_t;
      FOR k IN 1..COALESCE(cardinality(v_otras), 0) LOOP
        i := v_otras[k];
        v_g := v_q[v_j];
        FOR m IN k + 1..cardinality(v_otras) LOOP
          v_g := gcd(v_g, v_q[v_otras[m]]);
        END LOOP;
        v_x := v_u[i];
        WHILE mod(v_falta - v_q[i] * v_x, v_g) <> 0 LOOP
          v_x := v_x + 1;
        END LOOP;
        v_y := v_x - div(v_g, gcd(v_q[i], v_g));
        IF abs(v_y * v_r - v_t * v_c[i]) < abs(v_x * v_r - v_t * v_c[i]) THEN
          v_x := v_y;
        END IF;
        v_u[i] := v_x;
        v_falta := v_falta - v_q[i] * v_x;
      END LOOP;
      v_u[v_j] := div(v_falta, v_q[v_j]);
    END IF;
  END IF;

  RETURN (SELECT jsonb_object_agg(v_ids[s.i]::text, round(v_u[s.i] / 100, 2))
            FROM generate_subscripts(v_ids, 1) AS s(i));
END
$function$;

-- ===========================================================================
-- 2 · guardar_combo
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.guardar_combo(p_combo jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_cant     integer;
  v_mcd      integer := 0;
  v_cent     bigint;
  v_abajo    bigint;
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

  -- #1259: el precio se tiene que poder repartir exacto entre las unidades, para
  -- cualquier cantidad de combos y cualquier mezcla de alternativas: el mcd de
  -- las cantidades de los lugares divide el precio en centavos. "2 por $999,99"
  -- no cierra (dos unidades al mismo precio dan un total par) y cobraba $999,98.
  -- Es la regla de precioRepartible (src/utils/combos.ts).
  FOR v_cant IN SELECT (c->>'cantidad')::integer FROM jsonb_array_elements(v_comp) c LOOP
    v_mcd := gcd(v_mcd, v_cant);
  END LOOP;
  v_cent := round(v_precio * 100)::bigint;
  IF mod(v_cent, v_mcd) <> 0 THEN
    v_abajo := v_cent - mod(v_cent, v_mcd);
    RETURN jsonb_build_object('success', false, 'error', format(
      'Con estas cantidades, el precio del combo tiene que ser múltiplo de $%s para repartirse exacto entre las unidades. Probá con %s$%s.',
      replace(to_char(v_mcd / 100.0, 'FM999999999990.00'), '.', ','),
      CASE WHEN v_abajo > 0
           THEN '$' || replace(to_char(v_abajo / 100.0, 'FM999999999990.00'), '.', ',') || ' o '
           ELSE '' END,
      replace(to_char((v_abajo + v_mcd) / 100.0, 'FM999999999990.00'), '.', ',')));
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
$function$;

-- ===========================================================================
-- 3 · combo_fuera_de_regla
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.combo_fuera_de_regla(p_items jsonb, p_sucursal bigint, p_fecha date, p_pedido_id bigint, p_validar_politica boolean)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_items    jsonb := CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  -- LEAST(fecha, hoy) en el alta y en la edición (#1152, #1260), como
  -- regalo_fuera_de_promo: un combo que empieza en la fecha futura del pedido
  -- todavía no está vigente.
  v_d        date;
  r          record;
  v_combo    record;
  v_vigente  boolean;
  v_def      jsonb;
  v_nombre   text;
  v_k        integer;
  v_k_foto   integer;
  v_lineas   jsonb;
  v_total    numeric;
  v_ref      numeric;
  v_prorr    jsonb;
  v_vendidos bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e WHERE NULLIF(e->>'combo_id', '') IS NOT NULL) THEN
    RETURN NULL;
  END IF;
  v_d := LEAST(COALESCE(p_fecha, v_hoy), v_hoy);

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e
              WHERE NULLIF(e->>'combo_id', '') IS NOT NULL
                AND COALESCE((e->>'es_bonificacion')::boolean, false)) THEN
    RETURN 'Un regalo no puede ir dentro de un combo.';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e
              WHERE NULLIF(e->>'combo_id', '') IS NOT NULL
              GROUP BY e->>'combo_id', e->>'producto_id'
             HAVING count(*) > 1) THEN
    RETURN 'Un combo trae dos líneas del mismo producto.';
  END IF;

  FOR r IN
    SELECT NULLIF(e->>'combo_id', '')::bigint AS combo_id,
           jsonb_agg(jsonb_build_object(
             'producto_id', NULLIF(e->>'producto_id', '')::bigint,
             'cantidad',    NULLIF(e->>'cantidad', '')::numeric,
             'ref',         NULLIF(e->>'precio_sin_combo_unitario', '')::numeric,
             'sin_escala',  NULLIF(e->>'precio_sin_escala_unitario', '')::numeric,
             'precio',      NULLIF(e->>'precio_unitario', '')::numeric)
             ORDER BY NULLIF(e->>'producto_id', '')::bigint) AS lineas
      FROM jsonb_array_elements(v_items) e
     WHERE NULLIF(e->>'combo_id', '') IS NOT NULL
     GROUP BY 1
     ORDER BY 1
  LOOP
    SELECT * INTO v_combo FROM combos WHERE id = r.combo_id AND sucursal_id = p_sucursal;
    IF NOT FOUND THEN
      RETURN format('El combo #%s no existe en esta sucursal.', r.combo_id);
    END IF;

    v_vigente := v_combo.activo
                 AND ((v_combo.fecha_inicio <= v_d AND (v_combo.fecha_fin IS NULL OR v_combo.fecha_fin >= v_d))
                      OR (v_combo.fecha_inicio <= v_hoy AND (v_combo.fecha_fin IS NULL OR v_combo.fecha_fin >= v_hoy)));

    -- Edicion: el combo que el pedido ya tenia se mide contra su foto.
    v_def := NULL;
    v_k_foto := NULL;
    IF p_pedido_id IS NOT NULL THEN
      SELECT jsonb_build_object('nombre', f.nombre, 'precio', f.precio,
                                'combina_escalas', f.combina_escalas, 'componentes', f.componentes),
             f.cantidad_combos
        INTO v_def, v_k_foto
        FROM pedido_combos f
       WHERE f.pedido_id = p_pedido_id AND f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal;
    END IF;
    IF v_def IS NULL THEN
      IF p_validar_politica AND NOT v_vigente THEN
        RETURN format('El combo "%s" no está vigente.', v_combo.nombre);
      END IF;
      v_def := public._combo_definicion(r.combo_id, p_sucursal);
    END IF;
    v_nombre := v_def->>'nombre';

    v_k := public._combo_cantidad(v_def->'componentes', r.lineas);
    IF v_k IS NULL THEN
      RETURN format('Las líneas del combo "%s" no forman un número entero de combos.', v_nombre);
    END IF;
    -- Un combo que ya no esta vigente se conserva con su foto, pero no crece.
    IF p_validar_politica AND v_k_foto IS NOT NULL AND NOT v_vigente AND v_k > v_k_foto THEN
      RETURN format('El combo "%s" ya no está vigente: el pedido puede conservar sus %s, no sumar más.',
                    v_nombre, v_k_foto);
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.lineas) x
                WHERE COALESCE((x->>'ref')::numeric, 0) <= 0 OR COALESCE((x->>'precio')::numeric, 0) <= 0) THEN
      RETURN format('Una línea del combo "%s" viene sin su precio sin combo.', v_nombre);
    END IF;

    CONTINUE WHEN NOT p_validar_politica;

    -- Acumulable: cada linea trae su precio sin escalas, no menor que el de
    -- referencia. Excluyente: no resta nada (se ignora si vino).
    IF (v_def->>'combina_escalas')::boolean THEN
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.lineas) x
                  WHERE (x->>'sin_escala') IS NULL OR (x->>'sin_escala')::numeric < (x->>'ref')::numeric) THEN
        RETURN format('Una línea del combo "%s" viene sin su precio sin escala.', v_nombre);
      END IF;
      v_lineas := r.lineas;
    ELSE
      SELECT jsonb_agg(x - 'sin_escala') INTO v_lineas FROM jsonb_array_elements(r.lineas) x;
    END IF;

    v_total := public._combo_total((v_def->>'precio')::numeric, v_k, v_lineas);
    SELECT sum((x->>'cantidad')::numeric * (x->>'ref')::numeric) INTO v_ref
      FROM jsonb_array_elements(v_lineas) x;
    IF v_total IS NULL OR v_total <= 0 THEN
      RETURN format('El combo "%s" no deja nada para cobrar.', v_nombre);
    END IF;
    IF v_total > v_ref + 0.005 THEN
      RETURN format('El combo "%s" sale más caro que comprar sus productos sueltos.', v_nombre);
    END IF;
    v_prorr := public._combo_prorrateo(v_total, v_lineas);
    IF v_prorr IS NULL
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_lineas) x
                   WHERE abs((x->>'precio')::numeric - (v_prorr->>(x->>'producto_id'))::numeric) > 0.001) THEN
      RETURN format('El precio de las líneas del combo "%s" no coincide con su reparto. Recargá la app y volvé a armar el pedido.', v_nombre);
    END IF;
    -- #1259: lo que cobran las líneas es el total del combo, al centavo.
    IF abs((SELECT sum((x->>'cantidad')::numeric * (x->>'precio')::numeric)
              FROM jsonb_array_elements(v_lineas) x) - v_total) >= 0.005 THEN
      RETURN format('Las líneas del combo "%s" no suman su precio. Recargá la app y volvé a armar el pedido.', v_nombre);
    END IF;

    IF v_combo.tope_combos IS NOT NULL THEN
      PERFORM 1 FROM combos WHERE id = r.combo_id AND sucursal_id = p_sucursal FOR UPDATE;
      SELECT COALESCE(sum(f.cantidad_combos), 0) INTO v_vendidos
        FROM pedido_combos f
        JOIN pedidos p ON p.id = f.pedido_id AND p.sucursal_id = f.sucursal_id
       WHERE f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal
         AND p.estado NOT IN ('cancelado', 'anulado')
         AND f.pedido_id IS DISTINCT FROM p_pedido_id;
      IF v_vendidos + v_k > v_combo.tope_combos THEN
        RETURN format('El combo "%s" llegó a su tope: quedan %s.', v_nombre,
                      GREATEST(v_combo.tope_combos - v_vendidos, 0));
      END IF;
    END IF;
  END LOOP;

  RETURN NULL;
END
$function$;

-- ===========================================================================
-- 4 · El límite de usos de una promo se hace cumplir al vender
-- ===========================================================================

-- El trigger viejo apagaba la promo después del hecho y sólo sin fracción.
DROP TRIGGER IF EXISTS trg_check_promo_limite ON public.promociones;
DROP FUNCTION IF EXISTS public.check_promo_limite_usos();

-- Unidades de regalo de una promo en los pedidos no cancelados, al confirmar
-- la transacción y con la promo bloqueada. SECURITY DEFINER: tiene que contar
-- los pedidos de todos (con RLS, un preventista vería sólo los suyos).
CREATE OR REPLACE FUNCTION public.validar_limite_usos_promo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_promo  record;
  v_usos   bigint;
  v_pedido bigint;
BEGIN
  -- Dos ventas a la vez se cuentan de a una: la segunda espera acá y, ya con la
  -- promo, cuenta con lo que la primera confirmó.
  SELECT id, nombre, limite_usos, activo INTO v_promo
    FROM promociones WHERE id = NEW.promocion_id FOR UPDATE;
  IF NOT FOUND OR v_promo.limite_usos IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(sum(pi.cantidad), 0),
         COALESCE(sum(pi.cantidad) FILTER (WHERE pi.pedido_id = NEW.pedido_id), 0)
    INTO v_usos, v_pedido
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.promocion_id = NEW.promocion_id
     AND pi.es_bonificacion
     AND p.estado <> 'cancelado';

  IF v_usos > v_promo.limite_usos THEN
    RAISE EXCEPTION 'La promo «%» tiene un límite de % unidades de regalo: quedan % y este pedido lleva %.',
                    v_promo.nombre, v_promo.limite_usos,
                    GREATEST(v_promo.limite_usos - (v_usos - v_pedido), 0), v_pedido
      USING HINT = 'Sacá o achicá el regalo de esa promo, o pedile al admin que suba el límite.';
  END IF;
  -- Al llegar, se apaga. Una cancelación devuelve las unidades, pero no la
  -- reactiva sola: la vuelve a prender el admin.
  IF v_usos >= v_promo.limite_usos AND v_promo.activo THEN
    UPDATE promociones SET activo = false WHERE id = NEW.promocion_id;
  END IF;
  RETURN NULL;
END
$function$;

COMMENT ON FUNCTION public.validar_limite_usos_promo() IS
  'Hace cumplir promociones.limite_usos al vender (#1261): un uso es una unidad de regalo '
  '(subunidad en una promo con fraccion) en los pedidos no cancelados, y no lo pasa nadie. '
  'Constraint trigger diferido: cuenta el estado final de la transaccion, con la promo '
  'bloqueada. Al llegar al limite apaga la promo.';

-- Funcion de trigger: no necesita EXECUTE para nadie (CLAUDE.md).
REVOKE ALL ON FUNCTION public.validar_limite_usos_promo() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.validar_limite_usos_promo() TO service_role;

CREATE CONSTRAINT TRIGGER trg_limite_usos_promo
  AFTER INSERT OR UPDATE OF cantidad, promocion_id, es_bonificacion ON public.pedido_items
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (NEW.es_bonificacion AND NEW.promocion_id IS NOT NULL)
  EXECUTE FUNCTION public.validar_limite_usos_promo();

-- Para contar los regalos de una promo sin recorrer todas las líneas.
CREATE INDEX IF NOT EXISTS idx_pedido_items_regalo_promocion
  ON public.pedido_items (promocion_id)
  WHERE es_bonificacion AND promocion_id IS NOT NULL;

-- El límite no baja de lo ya regalado. Así el conteo nunca arranca pasado y el
-- trigger de arriba rechaza sólo lo que suma: si el admin pudiera dejar una
-- promo en 15 de 10, toda edición que reinserta su regalo y toda salvedad que
-- lo achica cruzarían "más que el límite" sin sumar nada, y el chofer no
-- podría registrar un rechazo. Bajarlo justo a lo regalado la apaga, como
-- llegar.
CREATE OR REPLACE FUNCTION public.limite_usos_no_baja_de_lo_regalado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_usos bigint;
BEGIN
  SELECT COALESCE(sum(pi.cantidad), 0) INTO v_usos
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.promocion_id = NEW.id
     AND pi.es_bonificacion
     AND p.estado <> 'cancelado';
  IF NEW.limite_usos < v_usos THEN
    RAISE EXCEPTION 'La promo «%» ya regaló % unidades: el límite no puede ser menor.', NEW.nombre, v_usos;
  END IF;
  IF NEW.limite_usos = v_usos THEN
    NEW.activo := false;
  END IF;
  RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION public.limite_usos_no_baja_de_lo_regalado() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.limite_usos_no_baja_de_lo_regalado() TO service_role;

CREATE TRIGGER trg_limite_usos_no_baja
  BEFORE UPDATE OF limite_usos ON public.promociones
  FOR EACH ROW
  WHEN (NEW.limite_usos IS NOT NULL AND NEW.limite_usos IS DISTINCT FROM OLD.limite_usos)
  EXECUTE FUNCTION public.limite_usos_no_baja_de_lo_regalado();

-- La misma invariante sobre lo que ya hay: ninguna promo pasada de su límite
-- (hoy sólo la 34 tiene, 20, con 16 regaladas).
DO $invariante$
DECLARE
  v_pasadas text;
BEGIN
  SELECT string_agg(format('%s (%s de %s)', pr.id, u.usos, pr.limite_usos), ', ') INTO v_pasadas
    FROM promociones pr
    CROSS JOIN LATERAL (SELECT COALESCE(sum(pi.cantidad), 0) AS usos
                          FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id
                         WHERE pi.promocion_id = pr.id AND pi.es_bonificacion
                           AND p.estado <> 'cancelado') u
   WHERE pr.limite_usos IS NOT NULL AND u.usos > pr.limite_usos;
  IF v_pasadas IS NOT NULL THEN
    RAISE EXCEPTION 'Hay promos pasadas de su límite de usos: %', v_pasadas;
  END IF;
END
$invariante$;

COMMENT ON COLUMN public.promociones.limite_usos IS
  'Maximo de unidades de regalo (subunidades en una promo con fraccion) en pedidos no '
  'cancelados. Se hace cumplir al vender y apaga la promo al llegar (#1261). NULL = sin limite.';
