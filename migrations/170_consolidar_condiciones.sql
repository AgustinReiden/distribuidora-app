-- =========================================================================
-- 170_consolidar_condiciones.sql
--
-- Fusiona condiciones mayoristas que en realidad son un solo fardo surtido.
--
-- El modelo pide "creá una condición, ponele nombre, metéle productos", pero
-- el negocio se piensa al revés: "este fardo de fideos sale tanto". Resultado
-- en prod: 82 de 88 condiciones con un solo producto. Como escalaAplica suma
-- lo que el cliente lleve de los productos de UNA condición, un pedido de 4
-- coditos + 4 mostachos + 4 tirabuzones no llega al mínimo de 12 y se cobra a
-- precio de lista, cuando comercialmente es un fardo.
--
-- Casos detectados al escribir esto (2026-08-06): 5 Cotella comunes repartidos
-- en 10 condiciones, 3 Rosca en 6, 3 Ricatto en 3, más pares de cafés y
-- condimentos Alicante. En total ~37 condiciones que son 12.
--
-- El precio NO cambia. Para un producto con 6u@$890 y 12u@$850 en condiciones
-- separadas, un pedido de 12u resuelve $850 hoy (gana la más barata entre
-- condiciones) y $850 consolidado (gana la de mayor cantidad_minima). Lo único
-- que cambia es que ahora la mezcla entre sabores suma.
--
-- La RPC es idempotente por construcción: si los orígenes ya se fusionaron, no
-- existen y no hace nada.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.consolidar_condiciones(
  p_grupo_destino  bigint,
  p_grupos_origen  bigint[],
  p_nombre         text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
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

  -- Guarda dura: fusionar no puede cambiar ningún precio. Si dos escalas
  -- comparten cantidad mínima con precios distintos, una de las dos tendría
  -- que desaparecer y algún producto pasaría a cobrarse diferente.
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

  FOREACH v_origen IN ARRAY p_grupos_origen LOOP
    -- 1) Los productos pasan al destino. ON CONFLICT porque un producto puede
    --    estar en varias de las condiciones que se fusionan.
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

    -- 2) Las escalas: si el destino ya tiene una con esa cantidad, los pedidos
    --    viejos se repuntan a ella y la de origen se borra. Si no la tiene, la
    --    escala se MUEVE conservando su id, que es lo que pedido_items guarda
    --    para trazar qué escala fijó el precio (mig 148). Mover en vez de
    --    recrear es lo que evita sumar referencias huérfanas: ya hay 11 de 149.
    FOR v_escala IN
      SELECT id, cantidad_minima FROM grupo_precio_escalas WHERE grupo_precio_id = v_origen
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
$fn$;

ALTER FUNCTION public.consolidar_condiciones(bigint, bigint[], text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.consolidar_condiciones(bigint, bigint[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consolidar_condiciones(bigint, bigint[], text) TO authenticated;

COMMENT ON FUNCTION public.consolidar_condiciones(bigint, bigint[], text) IS
  'Fusiona condiciones mayoristas en una sola para que la mezcla entre sus productos sume (fardo surtido). Mueve las escalas conservando su id y repunta pedido_items cuando hay equivalente. Rechaza la fusión si cambiaría algún precio. Mig 170.';
