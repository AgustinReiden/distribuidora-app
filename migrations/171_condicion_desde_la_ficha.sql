-- =========================================================================
-- 171_condicion_desde_la_ficha.sql
--
-- Poner un precio por cantidad desde la ficha del producto, sin pasar por el
-- modal de condición.
--
-- Hasta acá, para que un producto suelto tuviera precio mayorista había que
-- salir de la ficha, abrir el modal, inventarle un nombre a la condición,
-- buscar el producto en la lista y recién ahí cargar la escala. Cinco pasos
-- para decir "de este sabor, a partir de 12, cobrás $850".
--
-- Va por RPC y no por tres inserts desde el cliente porque tiene que ser
-- atómico: crear el grupo, meterle el producto y agregar la escala son tres
-- pasos, y si falla el segundo queda un grupo huérfano. Eso ya pasó — son los
-- 3 grupos vacíos que hay en prod (ids 3, 23 y 24).
--
-- Si el producto ya tiene una condición propia (una donde es el único
-- producto), la reusa en vez de crear otra: es lo que evita que se repita el
-- patrón de "CODITO 1/2 FARDO" + "CODITO FARDO" como dos condiciones separadas
-- para el mismo sabor.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.crear_condicion_para_producto(
  p_producto_id     bigint,
  p_cantidad_minima integer,
  p_precio_unitario numeric,
  p_etiqueta        text DEFAULT NULL,
  p_nombre          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal bigint := current_sucursal_id();
  v_grupo    bigint;
  v_escala   bigint;
  v_producto text;
  v_creado   boolean := false;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede editar condiciones mayoristas'
      USING ERRCODE = '42501';
  END IF;

  IF p_cantidad_minima IS NULL OR p_cantidad_minima <= 0 THEN
    RAISE EXCEPTION 'La cantidad mínima debe ser mayor a 0';
  END IF;
  IF p_precio_unitario IS NULL OR p_precio_unitario <= 0 THEN
    RAISE EXCEPTION 'El precio mayorista debe ser mayor a 0';
  END IF;

  SELECT nombre INTO v_producto
    FROM productos
   WHERE id = p_producto_id AND sucursal_id = v_sucursal;
  IF v_producto IS NULL THEN
    RAISE EXCEPTION 'El producto no existe en esta sucursal';
  END IF;

  -- Condición propia del producto: activa y con él como único miembro.
  SELECT g.id INTO v_grupo
    FROM grupos_precio g
    JOIN grupo_precio_productos gpp ON gpp.grupo_precio_id = g.id
   WHERE g.sucursal_id = v_sucursal
     AND g.activo
     AND gpp.producto_id = p_producto_id
     AND (SELECT count(*) FROM grupo_precio_productos x
           WHERE x.grupo_precio_id = g.id) = 1
   ORDER BY g.id
   LIMIT 1;

  IF v_grupo IS NULL THEN
    INSERT INTO grupos_precio (nombre, descripcion, activo, sucursal_id)
    VALUES (left(COALESCE(nullif(btrim(p_nombre), ''), v_producto), 200), NULL, true, v_sucursal)
    RETURNING id INTO v_grupo;
    v_creado := true;
  END IF;

  INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id)
  VALUES (v_grupo, p_producto_id, v_sucursal)
  ON CONFLICT (grupo_precio_id, producto_id) DO NOTHING;

  BEGIN
    INSERT INTO grupo_precio_escalas
      (grupo_precio_id, cantidad_minima, precio_unitario, etiqueta,
       activo, min_productos_distintos, sucursal_id)
    VALUES
      (v_grupo, p_cantidad_minima, p_precio_unitario,
       nullif(btrim(COALESCE(p_etiqueta, '')), ''), true, 1, v_sucursal)
    RETURNING id INTO v_escala;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ya hay un precio para % unidades en esta condición', p_cantidad_minima
      USING ERRCODE = '23505';
  END;

  RETURN jsonb_build_object(
    'grupo_id',     v_grupo,
    'escala_id',    v_escala,
    'grupo_creado', v_creado
  );
END;
$fn$;

ALTER FUNCTION public.crear_condicion_para_producto(bigint, integer, numeric, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.crear_condicion_para_producto(bigint, integer, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_condicion_para_producto(bigint, integer, numeric, text, text) TO authenticated;

COMMENT ON FUNCTION public.crear_condicion_para_producto(bigint, integer, numeric, text, text) IS
  'Agrega un precio por cantidad a un producto desde su ficha. Reusa su condición propia o crea una con el nombre del producto. Atómico: evita los grupos huérfanos. Mig 171.';
