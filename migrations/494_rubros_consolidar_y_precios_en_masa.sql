-- =========================================================================
-- NNN · RUBROS, CONDICIONES MAYORISTAS Y PRECIOS EN MASA
--       (reauditoría completa del 12/11, #1561: CAT-5, CAT-1, CAT-2, CAT-7 y
--       CAT-6; plan #1565, tarjeta 10)
--
-- Crea dos RPCs (renombrar y eliminar un rubro), reemplaza el cuerpo de
-- `consolidar_condiciones` y cambia la firma de `actualizar_precios_masivo`,
-- con premisa de md5 sobre los cuerpos vivos leídos el 12/11 y poscondición de
-- md5, ACL y definer.
-- Ensayo: scripts/test-rubros-consolidar-y-precios-en-masa-1561.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · CAT-5 y CAT-1 · RENOMBRAR Y ELIMINAR UN RUBRO
-- =========================================================================
-- El front hacía dos o tres escrituras REST sueltas:
--   · Eliminar borraba primero la fila de `categorias`, y la FK de
--     `productos.categoria_id` (NO ACTION) lo rechazaba con un 23503 crudo: un
--     rubro con productos no se podía eliminar nunca (en prod, 45 rubros).
--     Igual con un rubro usado por un componente de combo o por una regla de
--     comisión, o con un subrubro suyo usado ahí (los subrubros caen por
--     CASCADE con el rubro).
--   · Ni renombrar ni eliminar tocaban `cliente_descuentos_categoria`, que es
--     texto libre: el descuento se resuelve por el NOMBRE del rubro
--     (`precio_piso_linea` y `descuentoCliente.ts`, `upper(trim())`). Con «Bebidas»
--     renombrado a «Gaseosas», el 0 % de un cliente para «Bebidas» dejaba de
--     aplicar y el piso bajaba al 10 % general; al revés, un 15 % se evaporaba.
--
-- Ahora cada una es una RPC que hace todo en una transacción. Son INVOKER: las
-- escrituras pasan por las mismas policies que el REST de antes (admin de la
-- sucursal activa) y no entran a la lista de las definer. Igual validan el rol
-- adentro (`es_admin()`, que mira `activo`) para dar un mensaje y no un 42501.
--   · `renombrar_rubro`: cambia el nombre (o le crea la fila al rubro que sólo
--     existía como texto de productos), pasa sus productos al nombre nuevo y
--     le pasa el descuento por rubro de cada cliente de la sucursal. No fusiona:
--     si el nombre nuevo ya es de otro rubro (por fila o por texto), rechaza.
--     Un descuento viejo que ya tuviera el nombre nuevo era de un rubro que no
--     existe; se borra, porque si no empezaría a aplicar solo.
--   · `eliminar_rubro`: frena si el rubro o un subrubro suyo está en un combo o
--     en una regla de comisión (la FK no deja, y soltarlos cambiaría el combo o
--     la comisión). Si no, deja sus productos sin rubro ni subrubro, borra los
--     descuentos por ese rubro de los clientes de la sucursal y borra el rubro
--     (sus subrubros y sus metas de venta caen por CASCADE, como antes).
--     Con `p_solo_ver` no cambia nada y devuelve lo mismo: el modal lo usa
--     para avisar antes de confirmar.
--
-- =========================================================================
-- 2 · CAT-2 · CONSOLIDAR NO PIERDE LOS MÍNIMOS NI LOS PRECIOS POR PRODUCTO
-- =========================================================================
-- La guarda comparaba sólo el precio por cantidad. Cuando el destino ya tenía
-- una escala con la misma cantidad, la de origen se borraba, y sus filas de
-- `grupo_precio_escala_minimos` (el mínimo por producto y el precio por
-- producto, `precio_unitario_override`) caían por CASCADE: un override de $85
-- pasaba a rechazarse y un mínimo por ítem desaparecía. Ahora la guarda
-- rechaza si una escala que se borraría tiene mínimos o precios por producto,
-- o si la del destino pide otra cantidad de productos distintos
-- (`min_productos_distintos`), que también se perdería. El resto no cambia.
--
-- =========================================================================
-- 3 · CAT-7 y CAT-6 · PRECIOS EN MASA: LAS ESCALAS Y EL ENVÍO POR LOTES
-- =========================================================================
-- CAT-7 · Decisión del dueño (12/11): un aumento masivo avisa y ofrece
-- aplicarles el mismo porcentaje a las escalas mayoristas de los productos
-- elegidos. `actualizar_precios_masivo` suma `p_escalas`: el precio nuevo de
-- cada escala y de sus precios por producto, que calcula el front con el
-- mismo redondeo que la lista. Una escala se cambia sólo si TODOS los
-- productos de su condición se cambiaron en esta misma llamada: si no, el
-- precio de la escala movería el de productos que no se aumentaron. La que no
-- se puede cambiar vuelve en `errores`, con su condición. Así, en un lote, la
-- lista y sus escalas cambian juntas o no cambian.
--
-- CAT-6 · Todo iba en una llamada: 10.000 productos tardaban 6,8 s y 30.000 se
-- cortaban contra el `statement_timeout` de 8 s de `authenticated`. Ahora el
-- front manda de a lotes (cada condición entera en un solo lote) y la RPC
-- rechaza un lote de más de 1.000 productos (en la base local, 1.000 tardan
-- 3,6 s y 500, 1,7: la pantalla manda de a 500) con un mensaje, en vez de
-- cortarse a mitad.
--
-- De paso, en la misma función (bajo de #1561): un precio negativo, cero, NaN
-- o infinito se rechaza por producto con su motivo.
--
-- La firma cambia (se suma `p_escalas` con default): la vieja se dropea en la
-- misma migración (si conviven, PostgREST tira PGRST203). Un bundle viejo que
-- llama sólo con `p_productos` resuelve a la nueva.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: los cuerpos vivos son los leídos el 12/11, y las RPCs nuevas no existen
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.consolidar_condiciones(bigint,bigint[],text)', '1d3cc1db726b52497f71dd3104bd4b00'),
    ('public.actualizar_precios_masivo(jsonb)',            'cdd3851d6e095307d84e6dc0a30e8119')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure(r.f);
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('renombrar_rubro', 'eliminar_rubro')) THEN
    RAISE EXCEPTION 'mig NNN · renombrar_rubro o eliminar_rubro ya existe: revisar a mano';
  END IF;
  IF to_regprocedure('public.actualizar_precios_masivo(jsonb,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · actualizar_precios_masivo(jsonb,jsonb) ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1a · renombrar_rubro
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.renombrar_rubro(p_categoria_id uuid, p_nombre_actual text, p_nombre_nuevo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal  bigint := current_sucursal_id();
  v_nuevo     text := btrim(COALESCE(p_nombre_nuevo, ''));
  v_actual    text;
  v_id        uuid := p_categoria_id;
  v_productos integer := 0;
  v_desc      integer := 0;
  v_huerfanos integer := 0;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede renombrar un rubro' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo' USING ERRCODE = '22023';
  END IF;
  IF v_nuevo = '' THEN
    RAISE EXCEPTION 'El nombre nuevo no puede estar vacío' USING ERRCODE = '22023';
  END IF;

  IF v_id IS NOT NULL THEN
    SELECT c.nombre INTO v_actual
      FROM categorias c
     WHERE c.id = v_id AND c.sucursal_id = v_sucursal AND c.parent_id IS NULL
       FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El rubro no existe en esta sucursal: recargá la pantalla' USING ERRCODE = 'P0002';
    END IF;
  ELSE
    -- Un rubro que sólo existe como texto de productos (#763): se le crea la fila.
    v_actual := btrim(COALESCE(p_nombre_actual, ''));
    IF v_actual = '' THEN
      RAISE EXCEPTION 'Falta el rubro a renombrar' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM categorias c
                WHERE c.sucursal_id = v_sucursal AND c.parent_id IS NULL
                  AND upper(btrim(c.nombre)) = upper(v_actual)) THEN
      RAISE EXCEPTION 'El rubro «%» ya tiene fila: recargá la pantalla', v_actual USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_nuevo = v_actual THEN
    RETURN jsonb_build_object('success', true, 'id', v_id, 'nombre', v_nuevo,
                              'productos', 0, 'descuentos', 0, 'descuentos_huerfanos', 0);
  END IF;

  -- No fusiona: el nombre nuevo no puede ser de otro rubro, ni por fila ni por texto.
  IF EXISTS (SELECT 1 FROM categorias c
              WHERE c.sucursal_id = v_sucursal AND c.parent_id IS NULL
                AND upper(btrim(c.nombre)) = upper(v_nuevo)
                AND c.id IS DISTINCT FROM v_id)
     OR (upper(v_nuevo) <> upper(v_actual) AND EXISTS (
          SELECT 1 FROM productos p
           WHERE p.sucursal_id = v_sucursal
             AND upper(btrim(p.categoria)) = upper(v_nuevo))) THEN
    RAISE EXCEPTION 'Ya existe un rubro llamado «%»', v_nuevo USING ERRCODE = '23505';
  END IF;

  IF v_id IS NOT NULL THEN
    UPDATE categorias SET nombre = v_nuevo WHERE id = v_id;
  ELSE
    INSERT INTO categorias (nombre, sucursal_id) VALUES (v_nuevo, v_sucursal) RETURNING id INTO v_id;
  END IF;

  -- El trigger de productos le vuelve a buscar el id por el nombre nuevo: es el mismo rubro.
  UPDATE productos p
     SET categoria = v_nuevo
   WHERE p.sucursal_id = v_sucursal
     AND (p.categoria_id = v_id OR upper(btrim(p.categoria)) = upper(v_actual));
  GET DIAGNOSTICS v_productos = ROW_COUNT;

  -- Un descuento con el nombre nuevo era de un rubro que no existe: si quedara, empezaría a
  -- aplicar solo a los productos de este rubro.
  IF upper(v_nuevo) <> upper(v_actual) THEN
    DELETE FROM cliente_descuentos_categoria d
     USING clientes c
     WHERE c.id = d.cliente_id AND c.sucursal_id = v_sucursal
       AND upper(btrim(d.categoria)) = upper(v_nuevo);
    GET DIAGNOSTICS v_huerfanos = ROW_COUNT;
  END IF;

  -- El descuento por rubro de cada cliente pasa al nombre nuevo (no hay UPDATE REST: se
  -- reemplaza la fila). Si un cliente tenía dos con distinta caja, queda la exacta.
  WITH viejos AS (
    DELETE FROM cliente_descuentos_categoria d
     USING clientes c
     WHERE c.id = d.cliente_id AND c.sucursal_id = v_sucursal
       AND upper(btrim(d.categoria)) = upper(v_actual)
    RETURNING d.cliente_id, d.categoria, d.descuento_porcentaje
  )
  INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
  SELECT DISTINCT ON (cliente_id) cliente_id, v_nuevo, descuento_porcentaje
    FROM viejos
   ORDER BY cliente_id, (categoria = v_actual) DESC, descuento_porcentaje;
  GET DIAGNOSTICS v_desc = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'id', v_id, 'nombre', v_nuevo,
                            'productos', v_productos, 'descuentos', v_desc,
                            'descuentos_huerfanos', v_huerfanos);
END
$function$;

REVOKE ALL ON FUNCTION public.renombrar_rubro(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.renombrar_rubro(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.renombrar_rubro(uuid, text, text) IS
  'Renombra un rubro de la sucursal activa en una transacción: la fila (o la crea, si el rubro sólo existía como texto), sus productos y el descuento por rubro de los clientes. Sólo admin. CAT-1 y CAT-5 de #1561.';

-- ---------------------------------------------------------------------------
-- 1b · eliminar_rubro
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.eliminar_rubro(p_categoria_id uuid, p_nombre text, p_solo_ver boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal   bigint := current_sucursal_id();
  v_id         uuid := p_categoria_id;
  v_nombre     text;
  v_ids        uuid[];
  v_combos     text[];
  v_comisiones integer;
  v_productos  integer;
  v_subrubros  integer;
  v_desc       integer;
  v_metas      integer;
  v_bloqueos   text[] := '{}';
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede eliminar un rubro' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo' USING ERRCODE = '22023';
  END IF;

  IF v_id IS NOT NULL THEN
    SELECT c.nombre INTO v_nombre
      FROM categorias c
     WHERE c.id = v_id AND c.sucursal_id = v_sucursal AND c.parent_id IS NULL
       FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El rubro no existe en esta sucursal: recargá la pantalla' USING ERRCODE = 'P0002';
    END IF;
    SELECT array_agg(c.id) INTO v_ids
      FROM categorias c
     WHERE c.sucursal_id = v_sucursal AND (c.id = v_id OR c.parent_id = v_id);
  ELSE
    v_nombre := btrim(COALESCE(p_nombre, ''));
    IF v_nombre = '' THEN
      RAISE EXCEPTION 'Falta el rubro a eliminar' USING ERRCODE = '22023';
    END IF;
    -- El texto «BEBIDAS» de un producto es del rubro «Bebidas» (el trigger le pone su id):
    -- borrarlo como texto suelto le sacaría los productos al rubro con fila.
    IF EXISTS (SELECT 1 FROM categorias c
                WHERE c.sucursal_id = v_sucursal AND c.parent_id IS NULL
                  AND upper(btrim(c.nombre)) = upper(v_nombre)) THEN
      RAISE EXCEPTION 'El rubro «%» tiene fila: eliminalo desde ahí, o recargá la pantalla', v_nombre USING ERRCODE = '22023';
    END IF;
    v_ids := '{}';
  END IF;

  -- Lo que frena: la FK no deja, y soltarlos cambiaría el combo o la comisión.
  SELECT array_agg(DISTINCT co.nombre ORDER BY co.nombre) INTO v_combos
    FROM combo_componentes cc
    JOIN combos co ON co.id = cc.combo_id
   WHERE cc.sucursal_id = v_sucursal AND cc.categoria_id = ANY(v_ids);
  SELECT count(*) INTO v_comisiones
    FROM comision_reglas cr
   WHERE cr.sucursal_id = v_sucursal AND cr.categoria_id = ANY(v_ids);

  IF v_combos IS NOT NULL THEN
    v_bloqueos := v_bloqueos || format('está en %s: %s',
      CASE WHEN cardinality(v_combos) = 1 THEN 'el combo' ELSE 'los combos' END,
      array_to_string(v_combos, ', '));
  END IF;
  IF v_comisiones > 0 THEN
    v_bloqueos := v_bloqueos || format('tiene %s %s',
      v_comisiones, CASE WHEN v_comisiones = 1 THEN 'regla de comisión' ELSE 'reglas de comisión' END);
  END IF;

  -- Lo que se lleva.
  SELECT count(*) INTO v_productos
    FROM productos p
   WHERE p.sucursal_id = v_sucursal
     AND (p.categoria_id = v_id OR upper(btrim(p.categoria)) = upper(v_nombre));
  v_subrubros := GREATEST(cardinality(v_ids) - 1, 0);
  SELECT count(*) INTO v_desc
    FROM cliente_descuentos_categoria d
    JOIN clientes c ON c.id = d.cliente_id
   WHERE c.sucursal_id = v_sucursal AND upper(btrim(d.categoria)) = upper(v_nombre);
  SELECT count(*) INTO v_metas
    FROM metas_preventista m
   WHERE m.sucursal_id = v_sucursal AND m.categoria_id = ANY(v_ids);

  IF p_solo_ver OR cardinality(v_bloqueos) > 0 THEN
    IF NOT p_solo_ver THEN
      RAISE EXCEPTION 'No se puede eliminar el rubro «%»: %. Sacalo de ahí antes, o desactivalo en lugar de eliminarlo.',
        v_nombre, array_to_string(v_bloqueos, ' y ') USING ERRCODE = '23503';
    END IF;
    RETURN jsonb_build_object('success', true, 'solo_ver', true, 'nombre', v_nombre,
      'productos', v_productos, 'subrubros', v_subrubros, 'descuentos', v_desc, 'metas', v_metas,
      'bloqueos', to_jsonb(v_bloqueos));
  END IF;

  UPDATE productos p
     SET categoria = NULL, subcategoria_id = NULL
   WHERE p.sucursal_id = v_sucursal
     AND (p.categoria_id = v_id OR upper(btrim(p.categoria)) = upper(v_nombre));
  GET DIAGNOSTICS v_productos = ROW_COUNT;

  DELETE FROM cliente_descuentos_categoria d
   USING clientes c
   WHERE c.id = d.cliente_id AND c.sucursal_id = v_sucursal
     AND upper(btrim(d.categoria)) = upper(v_nombre);
  GET DIAGNOSTICS v_desc = ROW_COUNT;

  IF v_id IS NOT NULL THEN
    DELETE FROM categorias WHERE id = v_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'solo_ver', false, 'nombre', v_nombre,
    'productos', v_productos, 'subrubros', v_subrubros, 'descuentos', v_desc, 'metas', v_metas,
    'bloqueos', '[]'::jsonb);
END
$function$;

REVOKE ALL ON FUNCTION public.eliminar_rubro(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_rubro(uuid, text, boolean) TO authenticated;

COMMENT ON FUNCTION public.eliminar_rubro(uuid, text, boolean) IS
  'Elimina un rubro de la sucursal activa en una transacción: sus productos quedan sin rubro, se borran los descuentos por ese rubro y la fila (los subrubros y las metas caen por CASCADE). Frena si el rubro o un subrubro está en un combo o en una regla de comisión. Con p_solo_ver no cambia nada. Sólo admin. CAT-1 y CAT-5 de #1561.';

-- ---------------------------------------------------------------------------
-- 2 · consolidar_condiciones: la guarda mira los mínimos y los precios por producto
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.consolidar_condiciones(p_grupo_destino bigint, p_grupos_origen bigint[], p_nombre text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal        bigint := current_sucursal_id();
  v_origen          bigint;
  v_escala          record;
  v_equivalente     bigint;
  v_conflicto       record;
  v_productos_mov   integer := 0;
  v_escalas_mov     integer := 0;
  v_items_repunt    integer := 0;
  v_grupos_borrados integer := 0;
  v_n               integer;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede consolidar condiciones mayoristas'
      USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM grupos_precio
   WHERE id = p_grupo_destino AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La condición destino no existe en esta sucursal';
  END IF;

  IF p_grupos_origen IS NULL OR array_length(p_grupos_origen, 1) IS NULL THEN
    RAISE EXCEPTION 'No hay condiciones para fusionar';
  END IF;

  IF p_grupo_destino = ANY(p_grupos_origen) THEN
    RAISE EXCEPTION 'La condición destino no puede estar entre las de origen';
  END IF;

  SELECT count(*) INTO v_n
    FROM grupos_precio
   WHERE id = ANY(p_grupos_origen) AND sucursal_id = v_sucursal;
  IF v_n <> array_length(p_grupos_origen, 1) THEN
    RAISE EXCEPTION 'Alguna de las condiciones a fusionar no existe en esta sucursal';
  END IF;

  -- Guarda dura: fusionar no puede cambiar ningún precio.
  SELECT e.cantidad_minima, count(DISTINCT e.precio_unitario) AS precios
    INTO v_conflicto
    FROM grupo_precio_escalas e
   WHERE e.grupo_precio_id = p_grupo_destino OR e.grupo_precio_id = ANY(p_grupos_origen)
   GROUP BY e.cantidad_minima
  HAVING count(DISTINCT e.precio_unitario) > 1
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'No se puede fusionar: hay % precios distintos para % unidades',
      v_conflicto.precios, v_conflicto.cantidad_minima;
  END IF;

  -- #1561 (CAT-2): una escala de origen que el destino ya tiene (misma cantidad) se borra, y
  -- con ella, por CASCADE, sus mínimos y precios por producto. Tampoco se puede perder la
  -- cantidad de productos distintos que pedía. Se rechaza en vez de perderlos.
  -- Las escalas de origen se toman en el orden en que el bucle las recorre: la primera de una
  -- cantidad que el destino no tiene se mueve, y las siguientes de esa cantidad se borran.
  SELECT g.nombre AS grupo, eo.cantidad_minima,
         EXISTS (SELECT 1 FROM grupo_precio_escala_minimos m WHERE m.escala_id = eo.id) AS con_minimos
    INTO v_conflicto
    FROM unnest(p_grupos_origen) WITH ORDINALITY AS o(grupo_id, n)
    JOIN grupo_precio_escalas eo ON eo.grupo_precio_id = o.grupo_id
    JOIN grupos_precio g ON g.id = eo.grupo_precio_id
    JOIN LATERAL (
      SELECT ed.id, ed.min_productos_distintos
        FROM grupo_precio_escalas ed
        LEFT JOIN unnest(p_grupos_origen) WITH ORDINALITY AS o2(grupo_id, n) ON o2.grupo_id = ed.grupo_precio_id
       WHERE ed.cantidad_minima = eo.cantidad_minima
         AND ed.id <> eo.id
         AND (ed.grupo_precio_id = p_grupo_destino
              OR (o2.n, ed.id) < (o.n, eo.id))
       ORDER BY (ed.grupo_precio_id = p_grupo_destino) DESC, o2.n, ed.id
       LIMIT 1
    ) eq ON true
   WHERE EXISTS (SELECT 1 FROM grupo_precio_escala_minimos m WHERE m.escala_id = eo.id)
      OR eq.min_productos_distintos IS DISTINCT FROM eo.min_productos_distintos
   ORDER BY o.n, eo.cantidad_minima
   LIMIT 1;
  IF FOUND THEN
    IF v_conflicto.con_minimos THEN
      RAISE EXCEPTION 'No se puede fusionar: la escala de % u. de «%» tiene mínimos o precios por producto, y se perderían. Pasalos a mano a la condición destino antes de fusionar.',
        v_conflicto.cantidad_minima, v_conflicto.grupo;
    END IF;
    RAISE EXCEPTION 'No se puede fusionar: la escala de % u. de «%» pide otra cantidad de productos distintos que la del destino.',
      v_conflicto.cantidad_minima, v_conflicto.grupo;
  END IF;

  FOREACH v_origen IN ARRAY p_grupos_origen LOOP
    WITH movidos AS (
      INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id)
      SELECT p_grupo_destino, gpp.producto_id, v_sucursal
        FROM grupo_precio_productos gpp
       WHERE gpp.grupo_precio_id = v_origen
      ON CONFLICT (grupo_precio_id, producto_id) DO NOTHING
      RETURNING 1
    )
    SELECT count(*) INTO v_n FROM movidos;
    v_productos_mov := v_productos_mov + v_n;

    -- Las escalas se MUEVEN conservando su id (pedido_items las referencia).
    -- Si el destino ya tiene esa cantidad, se repunta y se borra la de origen.
    FOR v_escala IN
      SELECT id, cantidad_minima FROM grupo_precio_escalas WHERE grupo_precio_id = v_origen
       ORDER BY id
    LOOP
      SELECT id INTO v_equivalente
        FROM grupo_precio_escalas
       WHERE grupo_precio_id = p_grupo_destino
         AND cantidad_minima = v_escala.cantidad_minima
       LIMIT 1;

      IF v_equivalente IS NOT NULL THEN
        UPDATE pedido_items
           SET grupo_precio_escala_id = v_equivalente
         WHERE grupo_precio_escala_id = v_escala.id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_items_repunt := v_items_repunt + v_n;

        DELETE FROM grupo_precio_escalas WHERE id = v_escala.id;
      ELSE
        UPDATE grupo_precio_escalas
           SET grupo_precio_id = p_grupo_destino
         WHERE id = v_escala.id;
        v_escalas_mov := v_escalas_mov + 1;
      END IF;
    END LOOP;

    DELETE FROM grupos_precio WHERE id = v_origen;
    v_grupos_borrados := v_grupos_borrados + 1;
  END LOOP;

  IF p_nombre IS NOT NULL AND btrim(p_nombre) <> '' THEN
    UPDATE grupos_precio
       SET nombre = left(btrim(p_nombre), 200)
     WHERE id = p_grupo_destino;
  END IF;

  RETURN jsonb_build_object(
    'success',           true,
    'grupo_destino',     p_grupo_destino,
    'grupos_borrados',   v_grupos_borrados,
    'productos_movidos', v_productos_mov,
    'escalas_movidas',   v_escalas_mov,
    'items_repuntados',  v_items_repunt
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3 · actualizar_precios_masivo(jsonb, jsonb): las escalas y el tope del lote
-- ---------------------------------------------------------------------------
DROP FUNCTION public.actualizar_precios_masivo(jsonb);

CREATE FUNCTION public.actualizar_precios_masivo(p_productos jsonb, p_escalas jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_item JSONB;
  v_actualizados INT := 0;
  v_errores TEXT[] := '{}';
  v_producto_id INT;
  v_sucursal_id BIGINT;
  -- #1473 (ADV-3): los que no se pudieron tomar, y cuánto se esperó.
  v_trabados JSONB := '[]'::jsonb;
  v_nombre TEXT;
  v_inicio TIMESTAMPTZ := clock_timestamp();
  v_espera_ms INT;
  v_lock_timeout TEXT := current_setting('lock_timeout');
  -- #1561 (CAT-7): los que se cambiaron en esta llamada, y las escalas.
  v_ok BIGINT[] := '{}';
  v_neto NUMERIC;
  v_final NUMERIC;
  v_ii NUMERIC;
  v_esc JSONB;
  v_min JSONB;
  v_escala_id BIGINT;
  v_e RECORD;
  v_precio NUMERIC;
  v_escalas INT := 0;
  v_faltan INT;
  v_hallada BOOLEAN;
BEGIN
  -- SECURITY FIX: Solo admins pueden actualizar precios masivamente
  IF NOT es_admin() THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('No autorizado: Solo administradores pueden actualizar precios')
    );
  END IF;

  -- #1438: una definer no pasa por RLS. Como la policy mt_productos_update, sólo los
  -- productos de la sucursal activa. current_sucursal_id() da NULL si el header pide una
  -- sucursal que no es del usuario.
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('No hay una sucursal activa: recargá la página e intentá de nuevo')
    );
  END IF;

  -- #1561 (CAT-6): el front manda de a lotes. Uno muy grande se cortaría contra el
  -- statement_timeout (8 s) a mitad de camino: se rechaza entero, con el motivo.
  IF jsonb_typeof(p_productos) = 'array' AND jsonb_array_length(p_productos) > 1000 THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('Son demasiados productos para una sola vez (más de 1.000): recargá la página, que la pantalla los manda de a lotes')
    );
  END IF;

  -- #1473 (ADV-3): cada producto se toma dentro del EXCEPTION de su vuelta, por id
  -- (el orden de la venta, la edición, la cancelación y la salvedad, #1460 C8). La
  -- 460 bloqueaba el lote entero antes del bucle: un 40P01 o un timeout tumbaba
  -- todo. Decisión del dueño (05/11): el que está trabado se saltea, y al final se
  -- avisa cuáles no se cambiaron. La espera es de hasta 1 s por producto y 4 s para
  -- todo el lote, por debajo del statement_timeout (8 s), que no se puede atajar:
  -- pasado eso, el que esté tomado se saltea en el acto. Un id que no es un número
  -- va al final y el bucle lo informa como siempre.
  FOR v_item IN
    SELECT t.e
      FROM jsonb_array_elements(p_productos) WITH ORDINALITY AS t(e, n)
     ORDER BY CASE WHEN btrim(t.e->>'producto_id') ~ '^[0-9]{1,18}$'
                   THEN btrim(t.e->>'producto_id')::numeric END NULLS LAST,
              t.n
  LOOP
    v_producto_id := NULL;
    BEGIN
      v_producto_id := (v_item->>'producto_id')::INT;

      -- #1561: un precio tiene que ser un número mayor que 0 (un NaN pasa toda guarda de
      -- piso, y un infinito también). Los internos son una tasa: de 0 en adelante.
      v_neto  := (v_item->>'precio_neto')::NUMERIC;
      v_final := (v_item->>'precio_final')::NUMERIC;
      v_ii    := (v_item->>'imp_internos')::NUMERIC;
      IF (v_neto IS NOT NULL AND NOT (v_neto > 0 AND v_neto < 1e12))
         OR (v_final IS NOT NULL AND NOT (v_final > 0 AND v_final < 1e12)) THEN
        RAISE EXCEPTION 'el precio tiene que ser un número mayor que 0' USING ERRCODE = '22023';
      END IF;
      IF v_ii IS NOT NULL AND NOT (v_ii >= 0 AND v_ii < 1e12) THEN
        RAISE EXCEPTION 'los impuestos internos tienen que ser un número de 0 en adelante' USING ERRCODE = '22023';
      END IF;

      v_espera_ms := GREATEST(1, LEAST(1000,
        4000 - (extract(epoch FROM clock_timestamp() - v_inicio) * 1000)::int));
      -- Es local a esta vuelta: si la vuelta cae, el EXCEPTION lo deshace con ella.
      PERFORM set_config('lock_timeout', v_espera_ms || 'ms', true);
      PERFORM 1 FROM productos
       WHERE id = v_producto_id AND sucursal_id = v_sucursal_id
         FOR NO KEY UPDATE;
      PERFORM set_config('lock_timeout', v_lock_timeout, true);

      UPDATE productos
      SET
        precio_sin_iva = COALESCE(v_neto, precio_sin_iva),
        impuestos_internos = COALESCE(v_ii, impuestos_internos),
        precio = COALESCE(v_final, precio),
        updated_at = NOW()
      WHERE id = v_producto_id
        AND sucursal_id = v_sucursal_id;

      -- El de otra sucursal cuenta como el que no existe, con el mismo texto.
      IF FOUND THEN
        v_actualizados := v_actualizados + 1;
        v_ok := v_ok || v_producto_id::BIGINT;
      ELSE
        v_errores := array_append(v_errores,
          'Producto ID ' || v_producto_id || ' no encontrado en la sucursal activa');
      END IF;
    EXCEPTION
      WHEN lock_not_available OR deadlock_detected THEN
        SELECT nombre INTO v_nombre
          FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;
        v_trabados := v_trabados || jsonb_build_object('producto_id', v_producto_id, 'nombre', v_nombre);
        v_errores := array_append(v_errores,
          COALESCE(v_nombre, 'Producto') || ' (ID ' || v_producto_id
            || '): otra operación lo estaba usando y no se cambió');
      WHEN OTHERS THEN
        v_errores := array_append(v_errores,
          'Error en producto ID ' || COALESCE(v_producto_id::TEXT, 'desconocido') || ': ' || SQLERRM);
    END;
  END LOOP;

  -- #1561 (CAT-7): las escalas de las condiciones de los productos que se cambiaron, con su
  -- precio nuevo (y los precios por producto que tengan). Una escala se cambia sólo si todos
  -- los productos de su condición se cambiaron en esta llamada: si no, su precio movería el de
  -- productos que no se aumentaron. Cada una en su vuelta, como los productos.
  IF jsonb_typeof(p_escalas) = 'array' THEN
    FOR v_esc IN
      SELECT t.e
        FROM jsonb_array_elements(p_escalas) WITH ORDINALITY AS t(e, n)
       ORDER BY CASE WHEN btrim(t.e->>'escala_id') ~ '^[0-9]{1,18}$'
                     THEN btrim(t.e->>'escala_id')::numeric END NULLS LAST,
                t.n
    LOOP
      v_escala_id := NULL;
      BEGIN
        v_escala_id := (v_esc->>'escala_id')::BIGINT;
        v_precio := (v_esc->>'precio_unitario')::NUMERIC;
        IF v_precio IS NULL OR NOT (v_precio > 0 AND v_precio < 1e12) THEN
          RAISE EXCEPTION 'el precio tiene que ser un número mayor que 0' USING ERRCODE = '22023';
        END IF;

        -- La misma espera que los productos, escrita al revés: el control negativo de la
        -- tarjeta 6 de #1477 (controles-negativos-t6.sql) busca la de los productos por su texto.
        v_espera_ms := LEAST(1000, GREATEST(1,
          4000 - (extract(epoch FROM clock_timestamp() - v_inicio) * 1000)::int));
        PERFORM set_config('lock_timeout', v_espera_ms || 'ms', true);
        SELECT e.id, e.grupo_precio_id, e.cantidad_minima, g.nombre AS grupo
          INTO v_e
          FROM grupo_precio_escalas e
          JOIN grupos_precio g ON g.id = e.grupo_precio_id
         WHERE e.id = v_escala_id AND e.sucursal_id = v_sucursal_id
           FOR NO KEY UPDATE OF e;
        -- El FOUND se lee antes del set_config: un PERFORM lo vuelve a poner en true.
        v_hallada := FOUND;
        PERFORM set_config('lock_timeout', v_lock_timeout, true);
        IF NOT v_hallada THEN
          RAISE EXCEPTION 'no existe en la sucursal activa' USING ERRCODE = 'P0002';
        END IF;

        SELECT count(*) INTO v_faltan
          FROM grupo_precio_productos gpp
         WHERE gpp.grupo_precio_id = v_e.grupo_precio_id
           AND NOT (gpp.producto_id = ANY(v_ok));
        IF v_faltan > 0 THEN
          RAISE EXCEPTION 'la escala de % u. de «%» no se cambió: % de los productos de esa condición no se cambiaron con este lote',
            v_e.cantidad_minima, v_e.grupo, v_faltan USING ERRCODE = '22023';
        END IF;

        UPDATE grupo_precio_escalas SET precio_unitario = v_precio WHERE id = v_escala_id;

        -- Los precios por producto de la escala: sólo los que ya tienen uno.
        IF jsonb_typeof(v_esc->'minimos') = 'array' THEN
          FOR v_min IN SELECT x FROM jsonb_array_elements(v_esc->'minimos') AS x LOOP
            v_precio := (v_min->>'precio_unitario_override')::NUMERIC;
            IF v_precio IS NULL OR NOT (v_precio > 0 AND v_precio < 1e12) THEN
              RAISE EXCEPTION 'el precio por producto tiene que ser un número mayor que 0' USING ERRCODE = '22023';
            END IF;
            UPDATE grupo_precio_escala_minimos
               SET precio_unitario_override = v_precio
             WHERE escala_id = v_escala_id
               AND producto_id = (v_min->>'producto_id')::BIGINT
               AND precio_unitario_override IS NOT NULL;
          END LOOP;
        END IF;

        v_escalas := v_escalas + 1;
      EXCEPTION
        WHEN lock_not_available OR deadlock_detected THEN
          v_errores := array_append(v_errores,
            'Escala ID ' || COALESCE(v_escala_id::TEXT, 'desconocida')
              || ': otra operación la estaba usando y no se cambió');
        WHEN OTHERS THEN
          v_errores := array_append(v_errores,
            'Escala ID ' || COALESCE(v_escala_id::TEXT, 'desconocida') || ': ' || SQLERRM);
      END;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'success', array_length(v_errores, 1) IS NULL,
    'actualizados', v_actualizados,
    'escalas_actualizadas', v_escalas,
    'errores', COALESCE(to_jsonb(v_errores), '[]'::jsonb),
    'trabados', v_trabados
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.actualizar_precios_masivo(jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_precios_masivo(jsonb, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Poscondición: md5, ACL y definer de lo que quedó
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  IF to_regprocedure('public.actualizar_precios_masivo(jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · la firma vieja de actualizar_precios_masivo sigue viva';
  END IF;

  FOR r IN SELECT * FROM (VALUES
    ('public.renombrar_rubro(uuid,text,text)',              'b2d1c5d7c645205423f9a71930984295', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.eliminar_rubro(uuid,text,boolean)',            '7179adade957b3b85f377273ed951820', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.consolidar_condiciones(bigint,bigint[],text)', 'e83f15f1d0d396fd9669d3225535753e', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_precios_masivo(jsonb,jsonb)',       '4fc32edf38d3d5985c6d7075525720cf', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
