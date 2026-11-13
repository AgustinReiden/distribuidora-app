-- Ensayo de la migración de rubros, condiciones mayoristas y precios en masa
-- (reauditoría completa del 12/11, #1561: CAT-5, CAT-1, CAT-2 y CAT-7; plan #1565, tarjeta 10).
-- CAT-6 (30.000 productos de a lotes, cada llamada contra el statement_timeout) va aparte, en
-- scripts/test-precios-masivo-30000-1561.sql: un DO es UNA sentencia y el timeout la mide entera.
--
-- Corre SIN dejar rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una
-- excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el
-- COMMIT; después, solo. Lo que se mide va como `authenticated`, con el JWT y la sucursal del header,
-- igual que por PostgREST.
--
-- Personas: un admin activo de una sucursal activa (sale de la base); el encargado y el preventista
-- los crea el ensayo.
--
-- CAT-5 · eliminar un rubro con productos.
--   E1 · rubro con dos productos, uno con subrubro: se elimina; los productos quedan sin rubro ni
--        subrubro, la fila y el subrubro desaparecen, y el descuento por ese rubro también.
--   E2 · con `p_solo_ver` devuelve lo que haría y no cambia nada.
--   E3 · un rubro en un combo (por un subrubro) y uno en una regla de comisión frenan con su
--        motivo, y no cambia nada.
--   E4 · un rubro que sólo existe como texto de productos se elimina igual; pero un texto que es
--        de un rubro con fila (otra caja) no se borra suelto: le sacaría los productos a ese rubro.
--   E5 · el encargado y el preventista no pueden (42501).
-- CAT-1 · renombrar un rubro conserva el descuento por rubro del cliente.
--   R1 · cliente con 10 % general y 0 % para «Bebidas»: antes y después de renombrar a «Gaseosas»
--        el piso de Coca es 100 (antes del arreglo bajaba a 90). Los productos siguen en el mismo
--        rubro (mismo categoria_id).
--   R2 · un descuento viejo con el nombre nuevo (de un rubro que no existe) se borra: no empieza
--        a aplicar solo.
--   R3 · renombrar a un nombre de otro rubro (por fila o por texto) se rechaza (23505).
--   R4 · un rubro que sólo existe como texto se renombra: le nace la fila y los productos la toman.
-- CAT-2 · consolidar no pierde mínimos ni precios por producto.
--   C1 · el guion de la auditoría (escala de 10 u. con override de $85 y mínimo 10 en Pa): se
--        rechaza, y el mínimo sigue.
--   C2 · sin mínimos, la fusión sigue andando (regresión).
--   C3 · misma cantidad y precio pero otra cantidad de productos distintos: se rechaza.
-- CAT-7 · el aumento masivo cambia las escalas de las condiciones de los productos elegidos.
--   M1 · condición con dos productos, los dos en el lote: la lista y la escala cambian, y el
--        precio por producto también.
--   M2 · condición con dos productos y sólo uno en el lote: la escala no cambia y vuelve el motivo.
--   M3 · un precio negativo, cero o NaN se rechaza por producto, sin cambiar nada.
--   M4 · un lote de más de 1.000 productos se rechaza entero, con el motivo.
--   M5 · un bundle viejo (sólo p_productos) sigue andando.

DO $t$
DECLARE
  v_adm uuid;
  v_suc bigint;
  v_enc uuid;
  v_pre uuid;
  r jsonb;
  t text;
  v_cat uuid; v_sub uuid; v_cat2 uuid; v_cat3 uuid; v_sub3 uuid;
  v_p1 bigint; v_p2 bigint; v_p3 bigint; v_p4 bigint;
  v_cli bigint;
  v_combo bigint;
  gA bigint; gB bigint; eA bigint; eB bigint;
  v_n integer;
  v_items jsonb;
BEGIN
  SET LOCAL lock_timeout = '5s';

  SELECT p.id, us.sucursal_id INTO v_adm, v_suc
    FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE p.rol = 'admin' AND p.activo
   ORDER BY us.sucursal_id, p.id
   LIMIT 1;
  IF v_adm IS NULL THEN RAISE EXCEPTION 'el ensayo necesita un admin activo de una sucursal activa'; END IF;

  CREATE FUNCTION pg_temp.como(p_user uuid, p_suc bigint) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true),
           set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  $f$;
  -- Corre p_sql como authenticated y devuelve el jsonb, o 'ERR[sqlstate] mensaje' en {"error": …}.
  CREATE FUNCTION pg_temp.rpc(p_user uuid, p_suc bigint, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_user, p_suc);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN jsonb_build_object('error', SQLSTATE, 'mensaje', SQLERRM);
  END $f$;
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ens1561-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), '{}', now(), now());
    RETURN v;
  END $f$;
  -- El piso de la política para una línea, como la ve el preventista.
  CREATE FUNCTION pg_temp.piso(p_pre uuid, p_suc bigint, p_prod bigint, p_precio numeric, p_cli bigint) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_pre, p_suc);
    RETURN COALESCE(public.precio_fuera_de_politica(
      jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', 1, 'precio_unitario', p_precio)),
      p_cli, p_suc, NULL), 'ACEPTA');
  END $f$;

  v_enc := pg_temp.u('encargado', v_suc);
  v_pre := pg_temp.u('preventista', v_suc);

  -- =========================================================================
  -- CAT-5 · eliminar
  -- =========================================================================
  INSERT INTO categorias (nombre, sucursal_id) VALUES ('ENS1561 Rubro E1', v_suc) RETURNING id INTO v_cat;
  INSERT INTO categorias (nombre, sucursal_id, parent_id) VALUES ('ENS1561 Sub E1', v_suc, v_cat) RETURNING id INTO v_sub;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, subcategoria_id)
    VALUES ('ENS1561 P1', 100, 0, v_suc, 'ENS1561 Rubro E1', v_sub) RETURNING id INTO v_p1;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
    VALUES ('ENS1561 P2', 100, 0, v_suc, 'ENS1561 Rubro E1') RETURNING id INTO v_p2;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, descuento_porcentaje)
    VALUES ('ENS1561 C', 'ENS1561 C', 'Calle 1561', v_suc, 10) RETURNING id INTO v_cli;
  INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje) VALUES (v_cli, 'ENS1561 Rubro E1', 5);
  IF (SELECT categoria_id FROM productos WHERE id = v_p1) IS DISTINCT FROM v_cat THEN
    RAISE EXCEPTION 'premisa: el trigger no le puso el rubro al producto';
  END IF;

  -- E2 · sólo ver
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.eliminar_rubro(%L, %L, true)', v_cat, 'ENS1561 Rubro E1'));
  IF r ? 'error' OR (r->>'productos')::int <> 2 OR (r->>'subrubros')::int <> 1 OR (r->>'descuentos')::int <> 1
     OR jsonb_array_length(r->'bloqueos') <> 0 THEN
    RAISE EXCEPTION 'E2 · sólo ver devolvió %', r;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM categorias WHERE id = v_cat)
     OR (SELECT categoria FROM productos WHERE id = v_p1) IS DISTINCT FROM 'ENS1561 Rubro E1' THEN
    RAISE EXCEPTION 'E2 · sólo ver cambió algo';
  END IF;

  -- E5 · roles
  r := pg_temp.rpc(v_enc, v_suc, format('SELECT public.eliminar_rubro(%L, %L)', v_cat, 'x'));
  IF r->>'error' IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'E5 · el encargado eliminó: %', r; END IF;
  r := pg_temp.rpc(v_pre, v_suc, format('SELECT public.renombrar_rubro(%L, %L, %L)', v_cat, 'x', 'y'));
  IF r->>'error' IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'E5 · el preventista renombró: %', r; END IF;

  -- E1 · eliminar de verdad
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.eliminar_rubro(%L, %L)', v_cat, 'ENS1561 Rubro E1'));
  IF r ? 'error' OR (r->>'productos')::int <> 2 THEN RAISE EXCEPTION 'E1 · eliminar devolvió %', r; END IF;
  IF EXISTS (SELECT 1 FROM categorias WHERE id IN (v_cat, v_sub)) THEN
    RAISE EXCEPTION 'E1 · el rubro o el subrubro siguen';
  END IF;
  IF EXISTS (SELECT 1 FROM productos WHERE id IN (v_p1, v_p2)
              AND (categoria IS NOT NULL OR categoria_id IS NOT NULL OR subcategoria_id IS NOT NULL)) THEN
    RAISE EXCEPTION 'E1 · algún producto quedó con rubro o subrubro';
  END IF;
  IF EXISTS (SELECT 1 FROM cliente_descuentos_categoria WHERE cliente_id = v_cli) THEN
    RAISE EXCEPTION 'E1 · el descuento por el rubro eliminado quedó';
  END IF;

  -- E3 · frena por combo (por un subrubro) y por comisión
  INSERT INTO categorias (nombre, sucursal_id) VALUES ('ENS1561 Rubro E3', v_suc) RETURNING id INTO v_cat2;
  INSERT INTO categorias (nombre, sucursal_id, parent_id) VALUES ('ENS1561 Sub E3', v_suc, v_cat2) RETURNING id INTO v_sub;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
    VALUES ('ENS1561 P3', 100, 0, v_suc, 'ENS1561 Rubro E3') RETURNING id INTO v_p3;
  INSERT INTO combos (sucursal_id, nombre, fecha_inicio, precio)
    VALUES (v_suc, 'ENS1561 Combo', current_date, 500) RETURNING id INTO v_combo;
  INSERT INTO combo_componentes (combo_id, sucursal_id, componente, cantidad, categoria_id)
    VALUES (v_combo, v_suc, 1, 2, v_sub);
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.eliminar_rubro(%L, %L)', v_cat2, 'x'));
  IF r->>'error' IS DISTINCT FROM '23503' OR r->>'mensaje' NOT LIKE '%ENS1561 Combo%' THEN
    RAISE EXCEPTION 'E3 · el rubro de un combo no frenó con su motivo: %', r;
  END IF;
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.eliminar_rubro(%L, %L, true)', v_cat2, 'x'));
  IF jsonb_array_length(r->'bloqueos') <> 1 THEN RAISE EXCEPTION 'E3 · sólo ver no mostró el bloqueo: %', r; END IF;
  DELETE FROM combo_componentes WHERE combo_id = v_combo;
  INSERT INTO comision_reglas (sucursal_id, porcentaje, categoria_id) VALUES (v_suc, 3, v_cat2);
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.eliminar_rubro(%L, %L)', v_cat2, 'x'));
  IF r->>'error' IS DISTINCT FROM '23503' OR r->>'mensaje' NOT LIKE '%regla de comisión%' THEN
    RAISE EXCEPTION 'E3 · el rubro de una comisión no frenó con su motivo: %', r;
  END IF;
  IF (SELECT categoria FROM productos WHERE id = v_p3) IS DISTINCT FROM 'ENS1561 Rubro E3'
     OR NOT EXISTS (SELECT 1 FROM categorias WHERE id = v_sub) THEN
    RAISE EXCEPTION 'E3 · el rechazo cambió algo';
  END IF;

  -- E4 · rubro que sólo es texto
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
    VALUES ('ENS1561 P4', 100, 0, v_suc, 'ENS1561 Solo texto') RETURNING id INTO v_p4;
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.eliminar_rubro(NULL, %L)', 'ENS1561 Solo texto'));
  IF r ? 'error' OR (r->>'productos')::int <> 1 OR (SELECT categoria FROM productos WHERE id = v_p4) IS NOT NULL THEN
    RAISE EXCEPTION 'E4 · el rubro de texto no se eliminó: %', r;
  END IF;
  UPDATE productos SET categoria = 'ENS1561 RUBRO E3' WHERE id = v_p4;
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.eliminar_rubro(NULL, %L)', 'ENS1561 RUBRO E3'));
  IF r->>'error' IS DISTINCT FROM '22023'
     OR (SELECT categoria_id FROM productos WHERE id = v_p4) IS DISTINCT FROM v_cat2
     OR (SELECT categoria FROM productos WHERE id = v_p3) IS DISTINCT FROM 'ENS1561 Rubro E3' THEN
    RAISE EXCEPTION 'E4 · el texto de un rubro con fila se borró suelto: %', r;
  END IF;

  -- =========================================================================
  -- CAT-1 · renombrar
  -- =========================================================================
  INSERT INTO categorias (nombre, sucursal_id) VALUES ('ENS1561 Bebidas', v_suc) RETURNING id INTO v_cat3;
  INSERT INTO categorias (nombre, sucursal_id, parent_id) VALUES ('ENS1561 Colas', v_suc, v_cat3) RETURNING id INTO v_sub3;
  UPDATE productos SET categoria = 'ENS1561 Bebidas', subcategoria_id = v_sub3 WHERE id = v_p1;
  UPDATE clientes SET descuento_porcentaje = 10 WHERE id = v_cli;
  INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje) VALUES (v_cli, 'ENS1561 Bebidas', 0);
  -- R2 · un descuento viejo con el nombre que va a tomar el rubro
  INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje) VALUES (v_cli, 'ENS1561 Gaseosas', 30);

  t := pg_temp.piso(v_pre, v_suc, v_p1, 90, v_cli);
  IF t = 'ACEPTA' THEN RAISE EXCEPTION 'R1 · premisa: antes de renombrar, 90 tenía que estar bajo el piso'; END IF;

  -- R3 · a un nombre de otro rubro, por fila y por texto
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.renombrar_rubro(%L, %L, %L)', v_cat3, 'x', 'ENS1561 RUBRO E3'));
  IF r->>'error' IS DISTINCT FROM '23505' THEN RAISE EXCEPTION 'R3 · renombró sobre otro rubro (fila): %', r; END IF;
  UPDATE productos SET categoria = 'ENS1561 Texto R3' WHERE id = v_p2;
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.renombrar_rubro(%L, %L, %L)', v_cat3, 'x', 'ENS1561 Texto R3'));
  IF r->>'error' IS DISTINCT FROM '23505' THEN RAISE EXCEPTION 'R3 · renombró sobre otro rubro (texto): %', r; END IF;

  -- R1 · el renombre
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.renombrar_rubro(%L, %L, %L)', v_cat3, 'ENS1561 Bebidas', 'ENS1561 Gaseosas'));
  IF r ? 'error' OR (r->>'productos')::int <> 1 OR (r->>'descuentos')::int <> 1 OR (r->>'descuentos_huerfanos')::int <> 1 THEN
    RAISE EXCEPTION 'R1 · renombrar devolvió %', r;
  END IF;
  IF (SELECT nombre FROM categorias WHERE id = v_cat3) <> 'ENS1561 Gaseosas'
     OR (SELECT categoria FROM productos WHERE id = v_p1) <> 'ENS1561 Gaseosas'
     OR (SELECT categoria_id FROM productos WHERE id = v_p1) IS DISTINCT FROM v_cat3
     OR (SELECT subcategoria_id FROM productos WHERE id = v_p1) IS DISTINCT FROM v_sub3 THEN
    RAISE EXCEPTION 'R1 · el producto no quedó en el mismo rubro con el nombre nuevo';
  END IF;
  IF (SELECT string_agg(categoria || '=' || descuento_porcentaje, ',') FROM cliente_descuentos_categoria WHERE cliente_id = v_cli)
     IS DISTINCT FROM 'ENS1561 Gaseosas=0.00' THEN
    RAISE EXCEPTION 'R1/R2 · descuentos del cliente: %',
      (SELECT string_agg(categoria || '=' || descuento_porcentaje, ',') FROM cliente_descuentos_categoria WHERE cliente_id = v_cli);
  END IF;
  t := pg_temp.piso(v_pre, v_suc, v_p1, 90, v_cli);
  IF t = 'ACEPTA' THEN RAISE EXCEPTION 'R1 · después de renombrar, el piso bajó a 90'; END IF;
  t := pg_temp.piso(v_pre, v_suc, v_p1, 100, v_cli);
  IF t <> 'ACEPTA' THEN RAISE EXCEPTION 'R1 · después de renombrar, la lista no pasa: %', t; END IF;

  -- R4 · rubro de texto
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.renombrar_rubro(NULL, %L, %L)', 'ENS1561 Texto R3', 'ENS1561 Texto R4'));
  IF r ? 'error' OR (SELECT categoria_id FROM productos WHERE id = v_p2) IS DISTINCT FROM (r->>'id')::uuid
     OR (SELECT nombre FROM categorias WHERE id = (r->>'id')::uuid) <> 'ENS1561 Texto R4' THEN
    RAISE EXCEPTION 'R4 · el rubro de texto no tomó fila: %', r;
  END IF;

  -- =========================================================================
  -- CAT-2 · consolidar
  -- =========================================================================
  INSERT INTO productos (nombre, precio, stock, sucursal_id) VALUES ('ENS1561 Pa', 100, 0, v_suc) RETURNING id INTO v_p1;
  INSERT INTO productos (nombre, precio, stock, sucursal_id) VALUES ('ENS1561 Pb', 100, 0, v_suc) RETURNING id INTO v_p2;
  INSERT INTO grupos_precio (nombre, sucursal_id) VALUES ('ENS1561 gA', v_suc) RETURNING id INTO gA;
  INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (gA, v_p1, v_suc);
  INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, sucursal_id) VALUES (gA, 10, 90, v_suc) RETURNING id INTO eA;
  INSERT INTO grupo_precio_escala_minimos (escala_id, producto_id, cantidad_minima_por_item, sucursal_id, precio_unitario_override)
    VALUES (eA, v_p1, 10, v_suc, 85);
  INSERT INTO grupos_precio (nombre, sucursal_id) VALUES ('ENS1561 gB', v_suc) RETURNING id INTO gB;
  INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (gB, v_p2, v_suc);
  INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, sucursal_id) VALUES (gB, 10, 90, v_suc) RETURNING id INTO eB;

  -- C1
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', gB, gA));
  IF NOT (r ? 'error') OR r->>'mensaje' NOT LIKE '%precios por producto%' THEN
    RAISE EXCEPTION 'C1 · consolidar no rechazó (se perdía el override y el mínimo): %', r;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM grupo_precio_escala_minimos WHERE escala_id = eA) OR NOT EXISTS (SELECT 1 FROM grupos_precio WHERE id = gA) THEN
    RAISE EXCEPTION 'C1 · el rechazo cambió algo';
  END IF;
  -- Al revés (A destino, B origen) no se pierde nada: B no tiene mínimos.
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', gA, gB));
  IF r ? 'error' OR (r->>'grupos_borrados')::int <> 1 OR NOT EXISTS (SELECT 1 FROM grupo_precio_escala_minimos WHERE escala_id = eA) THEN
    RAISE EXCEPTION 'C2 · la fusión sin mínimos que perder no anduvo: %', r;
  END IF;

  -- C3 · otra cantidad de productos distintos
  INSERT INTO grupos_precio (nombre, sucursal_id) VALUES ('ENS1561 gC', v_suc) RETURNING id INTO gB;
  INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, sucursal_id, min_productos_distintos)
    VALUES (gB, 10, 90, v_suc, 3);
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', gA, gB));
  IF NOT (r ? 'error') OR r->>'mensaje' NOT LIKE '%productos distintos%' THEN
    RAISE EXCEPTION 'C3 · consolidar no rechazó la escala con otro mínimo de productos distintos: %', r;
  END IF;

  -- =========================================================================
  -- CAT-7 · escalas en el aumento masivo (gA tiene Pa y Pb, escala 10 u. a 90, override de Pa 85)
  -- =========================================================================
  -- M2 · sólo Pa en el lote: la escala no se toca
  r := pg_temp.rpc(v_adm, v_suc, format(
    'SELECT public.actualizar_precios_masivo(%L::jsonb, %L::jsonb)',
    jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'precio_final', 110)),
    jsonb_build_array(jsonb_build_object('escala_id', eA, 'precio_unitario', 100,
      'minimos', jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'precio_unitario_override', 95))))));
  IF (r->>'actualizados')::int <> 1 OR (r->>'escalas_actualizadas')::int <> 0 OR (r->>'success')::boolean
     OR r->'errores'->>0 NOT LIKE '%no se cambiaron con este lote%' THEN
    RAISE EXCEPTION 'M2 · %', r;
  END IF;
  IF (SELECT precio_unitario FROM grupo_precio_escalas WHERE id = eA) <> 90 THEN
    RAISE EXCEPTION 'M2 · la escala cambió sin todos sus productos';
  END IF;

  -- M1 · los dos en el lote
  r := pg_temp.rpc(v_adm, v_suc, format(
    'SELECT public.actualizar_precios_masivo(%L::jsonb, %L::jsonb)',
    jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'precio_final', 200, 'precio_neto', 165.29),
                      jsonb_build_object('producto_id', v_p2, 'precio_final', 200)),
    jsonb_build_array(jsonb_build_object('escala_id', eA, 'precio_unitario', 180,
      'minimos', jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'precio_unitario_override', 170))))));
  IF NOT (r->>'success')::boolean OR (r->>'actualizados')::int <> 2 OR (r->>'escalas_actualizadas')::int <> 1 THEN
    RAISE EXCEPTION 'M1 · %', r;
  END IF;
  IF (SELECT precio_unitario FROM grupo_precio_escalas WHERE id = eA) <> 180
     OR (SELECT precio_unitario_override FROM grupo_precio_escala_minimos WHERE escala_id = eA AND producto_id = v_p1) <> 170
     OR (SELECT precio FROM productos WHERE id = v_p2) <> 200 THEN
    RAISE EXCEPTION 'M1 · la lista, la escala o el precio por producto no quedaron';
  END IF;
  -- La escala de otra sucursal cuenta como la que no existe.
  r := pg_temp.rpc(v_adm, v_suc, format(
    'SELECT public.actualizar_precios_masivo(%L::jsonb, %L::jsonb)', '[]',
    jsonb_build_array(jsonb_build_object('escala_id', -1, 'precio_unitario', 1))));
  IF (r->>'escalas_actualizadas')::int <> 0 OR r->'errores'->>0 NOT LIKE '%no existe en la sucursal activa%' THEN
    RAISE EXCEPTION 'M1 · escala inexistente: %', r;
  END IF;

  -- M3 · precios inválidos
  FOREACH t IN ARRAY ARRAY['-50', '0', '"NaN"', '"Infinity"'] LOOP
    r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.actualizar_precios_masivo(%L::jsonb)',
      format('[{"producto_id": %s, "precio_final": %s}]', v_p2, t)));
    IF (r->>'actualizados')::int <> 0 OR (r->>'success')::boolean THEN RAISE EXCEPTION 'M3 · % pasó: %', t, r; END IF;
  END LOOP;
  IF (SELECT precio FROM productos WHERE id = v_p2) <> 200 THEN RAISE EXCEPTION 'M3 · el precio cambió'; END IF;

  -- M4 · lote de más de 1.000
  SELECT jsonb_agg(jsonb_build_object('producto_id', v_p2, 'precio_final', 300)) INTO v_items FROM generate_series(1, 1001);
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.actualizar_precios_masivo(%L::jsonb)', v_items));
  IF (r->>'actualizados')::int <> 0 OR r->'errores'->>0 NOT LIKE '%de a lotes%' OR (SELECT precio FROM productos WHERE id = v_p2) <> 200 THEN
    RAISE EXCEPTION 'M4 · %', r;
  END IF;

  -- M5 · un bundle viejo, con el nombre del parámetro
  r := pg_temp.rpc(v_adm, v_suc, format('SELECT public.actualizar_precios_masivo(p_productos => %L::jsonb)',
    jsonb_build_array(jsonb_build_object('producto_id', v_p2, 'precio_final', 210))));
  IF NOT (r->>'success')::boolean OR (SELECT precio FROM productos WHERE id = v_p2) <> 210 THEN
    RAISE EXCEPTION 'M5 · %', r;
  END IF;

  RAISE EXCEPTION 'ENSAYO OK: CAT-5 (E1–E5), CAT-1 (R1–R4), CAT-2 (C1–C3) y CAT-7 (M1–M5)';
END
$t$;
