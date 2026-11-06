-- Ensayo de la migración de la tarjeta 3 de #1477 (#1470): el mínimo de venta por producto, el
-- IVA de la foto en la edición y la posición fiscal sin II de la venta.
--
--   M1 · Alta con combo: A tiene mínimo 6. Combo A×2 + B×1 y 6 de A sueltas: A suma 8 y pasa
--        (antes, la línea del combo, con 2, se rechazaba).
--   M2 · Editar ese pedido a combo + 3 sueltas: A suma 5 y se rechaza al confirmar, con el total
--        del producto en el mensaje ("se cargaron 5"). La edición se deshace entera.
--   M3 · Alta de 5 de A sueltas, sin combo: se rechaza, como siempre.
--   M4 · Alta de un vale blanco con 2 de A: pasa. crear_pedido_completo apaga el escape del VB
--        antes de terminar, y el VB se reconoce por pedidos.tipo_factura al confirmar.
--   M5 · Salvedad de 3 de A sobre 8 sueltas: A queda en 5 y pasa (el escape de las salvedades
--        sigue prendido al confirmar).
--   I1 · IVA de la foto: un pedido FC con A al 21%. A y B pasan a 10,5% y se edita agregando B:
--        A conserva el 21% de su foto y B, nueva, toma el 10,5% de hoy. El neto y el IVA salen
--        del porcentaje de cada una, y el total_iva del pedido es su suma.
--   F1 · posicion_fiscal ya no devuelve ii_ventas_fc, y sigue devolviendo iva_debito.
--   T1 · trg_validar_minimo_venta_item es un constraint trigger diferido, y su función es DEFINER
--        y sin EXECUTE para anon ni authenticated.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre
-- en una excepción. Cada alta o edición se confirma dentro de su propio bloque (SET CONSTRAINTS
-- ... IMMEDIATE): si el trigger diferido la rechaza, el bloque la deshace entera, como el COMMIT
-- real. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el
-- COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ' por M1, M2, I1, F1
-- y T1; M3, M4 y M5 pasan igual con y sin la migración.
--
-- Fixtures: una sucursal activa con un admin activo. El resto nace en el ensayo. Los montos
-- superan el mínimo del pedido y el envío gratis.

CREATE OR REPLACE FUNCTION pg_temp.t_como(p_uid uuid, p_suc bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, condicion_iva, porcentaje_iva, sucursal_id)
  VALUES (p_nombre, 2000, 500, 1200, 'gravado', 21, p_suc)
  RETURNING id;
$fn$;

-- Los GUCs de stock son por transacción: cada RPC deja los suyos.
CREATE OR REPLACE FUNCTION pg_temp.t_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.omitir_minimo_venta', '', true);
END
$fn$;

-- Lo que haría el COMMIT con el trigger diferido. Sin la migración el trigger no es de
-- constraint y no hay nada que adelantar: el BEFORE ya corrió.
CREATE OR REPLACE FUNCTION pg_temp.t_confirmar()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedido_items'::regclass
                AND tgname = 'trg_validar_minimo_venta_item' AND tgconstraint <> 0) THEN
    SET CONSTRAINTS public.trg_validar_minimo_venta_item IMMEDIATE;
    SET CONSTRAINTS public.trg_validar_minimo_venta_item DEFERRED;
  END IF;
END
$fn$;

-- El alta, confirmada. 'ok:<id>', 'rechazo:<json>' o 'error:<mensaje>'.
CREATE OR REPLACE FUNCTION pg_temp.t_alta(p_cli bigint, p_adm uuid, p_items jsonb, p_tipo text DEFAULT 'ZZ')
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli,
    (SELECT sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_adm, p_items, 'ensayo 1470', 'efectivo', 'pendiente', NULL, p_tipo);
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RETURN 'rechazo:' || v_res::text;
  END IF;
  PERFORM pg_temp.t_confirmar();
  RETURN 'ok:' || (v_res->>'pedido_id');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t_reset();
  RETURN 'error:' || SQLERRM;
END
$fn$;

-- La edición, confirmada. Mismo formato, con 'ok' a secas.
CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm, NULL, NULL);
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RETURN 'rechazo:' || v_res::text;
  END IF;
  PERFORM pg_temp.t_confirmar();
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t_reset();
  RETURN 'error:' || SQLERRM;
END
$fn$;

-- Las líneas de un combo A×2 + B×1 a $1.500 cada unidad (sin combo, $2.000), más las sueltas.
CREATE OR REPLACE FUNCTION pg_temp.t_lineas(p_combo bigint, p_a bigint, p_b bigint, p_sueltas_a int, p_c bigint, p_cant_c int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(
    jsonb_build_object('producto_id', p_a, 'cantidad', 2, 'precio_unitario', 1500,
                       'precio_sin_combo_unitario', 2000, 'combo_id', p_combo),
    jsonb_build_object('producto_id', p_b, 'cantidad', 1, 'precio_unitario', 1500,
                       'precio_sin_combo_unitario', 2000, 'combo_id', p_combo),
    jsonb_build_object('producto_id', p_a, 'cantidad', p_sueltas_a, 'precio_unitario', 2000),
    jsonb_build_object('producto_id', p_c, 'cantidad', p_cant_c, 'precio_unitario', 2000));
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_a      bigint;
  v_b      bigint;
  v_c      bigint;
  v_combo  bigint;
  v_cli    bigint;
  v_cli_vb bigint;
  v_ped    bigint;
  v_r      text;
  v_j      jsonb;
  v_txt    text;
  v_fallas text[] := '{}';
BEGIN
  SELECT s.id, adm.usuario_id INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin';
  END IF;
  PERFORM pg_temp.t_como(v_adm, v_suc);

  v_a := pg_temp.t_producto(v_suc, 'ZZ ensayo 1470 A');
  v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1470 B');
  v_c := pg_temp.t_producto(v_suc, 'ZZ ensayo 1470 C');
  UPDATE productos SET cantidad_minima_venta = 6 WHERE id = v_a;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1470', 'ZZ ensayo 1470', 'Ensayo 1470', v_suc) RETURNING id INTO v_cli;
  v_j := public.guardar_combo(jsonb_build_object(
    'nombre', 'ZZ ensayo 1470', 'precio', 4500, 'fecha_inicio', public._tablero_hoy() - 1,
    'componentes', jsonb_build_array(
      jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array(v_a)),
      jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_b)))));
  IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: no se pudo crear el combo: %', v_j;
  END IF;
  v_combo := (v_j->>'id')::bigint;

  -- M1 · alta con combo: 2 de A en el combo y 6 sueltas
  v_r := pg_temp.t_alta(v_cli, v_adm, pg_temp.t_lineas(v_combo, v_a, v_b, 6, v_c, 10));
  IF v_r NOT LIKE 'ok:%' THEN
    v_fallas := v_fallas || ('M1 el alta con combo (A suma 8, mínimo 6) dio ' || v_r);
  ELSE
    v_ped := substr(v_r, 4)::bigint;
    v_txt := (SELECT string_agg(cantidad || CASE WHEN combo_id IS NULL THEN 's' ELSE 'c' END, ',' ORDER BY combo_id NULLS LAST)
                FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_a);
    IF v_txt IS DISTINCT FROM '2c,6s' THEN
      v_fallas := v_fallas || ('M1 las líneas de A quedaron ' || COALESCE(v_txt, '(ninguna)'));
    END IF;

    -- M2 · editar a combo + 3 sueltas: A suma 5
    v_r := pg_temp.t_editar(v_ped, v_adm, pg_temp.t_lineas(v_combo, v_a, v_b, 3, v_c, 10));
    IF v_r IS DISTINCT FROM 'error:La compra mínima de "ZZ ensayo 1470 A" es 6 unidades (se cargaron 5)' THEN
      v_fallas := v_fallas || ('M2 la edición a 5 de A dio ' || v_r);
    END IF;
    v_txt := (SELECT string_agg(cantidad::text, ',' ORDER BY combo_id NULLS LAST)
                FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_a);
    IF v_txt IS DISTINCT FROM '2,6' THEN
      v_fallas := v_fallas || ('M2 la edición rechazada dejó A en ' || COALESCE(v_txt, '(ninguna)'));
    END IF;
  END IF;

  -- M3 · 5 sueltas, sin combo
  v_r := pg_temp.t_alta(v_cli, v_adm, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 5, 'precio_unitario', 2000),
    jsonb_build_object('producto_id', v_c, 'cantidad', 10, 'precio_unitario', 2000)));
  IF v_r IS DISTINCT FROM 'error:La compra mínima de "ZZ ensayo 1470 A" es 6 unidades (se cargaron 5)' THEN
    v_fallas := v_fallas || ('M3 el alta de 5 de A dio ' || v_r);
  END IF;

  -- M4 · un vale blanco con 2 de A
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, tipo_factura_default)
  VALUES ('ZZ ensayo 1470 VB', 'ZZ ensayo 1470 VB', 'Ensayo 1470', v_suc, 'VB') RETURNING id INTO v_cli_vb;
  v_r := pg_temp.t_alta(v_cli_vb, v_adm, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 2, 'precio_unitario', 0)), 'VB');
  IF v_r NOT LIKE 'ok:%' THEN
    v_fallas := v_fallas || ('M4 el VB con 2 de A dio ' || v_r);
  END IF;

  -- M5 · salvedad de 3 de A sobre 8 sueltas
  v_r := pg_temp.t_alta(v_cli, v_adm, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 8, 'precio_unitario', 2000)));
  IF v_r NOT LIKE 'ok:%' THEN
    v_fallas := v_fallas || ('M5 no se pudo crear el pedido de 8 de A: ' || v_r);
  ELSE
    v_ped := substr(v_r, 4)::bigint;
    BEGIN
      v_j := public.registrar_salvedad(v_ped, (SELECT id FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_a),
                                       3, 'cliente_rechaza', 'ensayo 1470', NULL, true, NULL);
      -- Se confirma ANTES de limpiar los GUCs: registrar_salvedad deja el escape
      -- prendido hasta el final de su transacción, y el COMMIT real lo ve así.
      PERFORM pg_temp.t_confirmar();
      PERFORM pg_temp.t_reset();
      v_txt := format('ok=%s A=%s', v_j->>'success',
                      (SELECT sum(cantidad) FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_a));
    EXCEPTION WHEN OTHERS THEN
      v_txt := 'error:' || SQLERRM;
    END;
    IF v_txt IS DISTINCT FROM 'ok=true A=5' THEN
      v_fallas := v_fallas || ('M5 la salvedad dio ' || v_txt);
    END IF;
  END IF;

  -- I1 · el IVA de la foto en la edición
  v_r := pg_temp.t_alta(v_cli, v_adm, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 8, 'precio_unitario', 2000)), 'FC');
  IF v_r NOT LIKE 'ok:%' THEN
    v_fallas := v_fallas || ('I1 no se pudo crear el pedido FC: ' || v_r);
  ELSE
    v_ped := substr(v_r, 4)::bigint;
    UPDATE productos SET porcentaje_iva = 10.5 WHERE id IN (v_a, v_b);
    v_r := pg_temp.t_editar(v_ped, v_adm, jsonb_build_array(
      jsonb_build_object('producto_id', v_a, 'cantidad', 8, 'precio_unitario', 2000),
      jsonb_build_object('producto_id', v_b, 'cantidad', 1, 'precio_unitario', 2000)));
    v_txt := (SELECT string_agg(format('%s:%s/%s/%s', CASE producto_id WHEN v_a THEN 'A' ELSE 'B' END,
                                       porcentaje_iva::numeric(5,2), neto_unitario, iva_unitario), ' ' ORDER BY producto_id)
                FROM pedido_items WHERE pedido_id = v_ped)
             || ' total_iva=' || (SELECT total_iva FROM pedidos WHERE id = v_ped);
    IF v_r IS DISTINCT FROM 'ok'
       OR v_txt IS DISTINCT FROM 'A:21.00/1652.89/347.11 B:10.50/1809.95/190.05 total_iva=2966.93' THEN
      v_fallas := v_fallas || ('I1 la edición dio ' || v_r || ' y dejó ' || COALESCE(v_txt, '(nada)'));
    END IF;
  END IF;

  -- F1 · la posición fiscal sin II de la venta
  v_j := public.posicion_fiscal(v_suc, public._tablero_hoy(), public._tablero_hoy());
  IF (v_j->'ventas') ? 'ii_ventas_fc' OR NOT (v_j->'ventas') ? 'iva_debito' THEN
    v_fallas := v_fallas || ('F1 posicion_fiscal devolvió ventas = ' || (v_j->'ventas')::text);
  END IF;

  -- T1 · el trigger y su función
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'public.pedido_items'::regclass AND t.tgname = 'trg_validar_minimo_venta_item'
                    AND t.tgconstraint <> 0 AND t.tgdeferrable AND t.tginitdeferred) THEN
    v_fallas := v_fallas || 'T1 trg_validar_minimo_venta_item no es un constraint trigger diferido'::text;
  ELSIF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.validar_minimo_venta_item()'::regprocedure)
        OR has_function_privilege('authenticated', 'public.validar_minimo_venta_item()', 'EXECUTE')
        OR has_function_privilege('anon', 'public.validar_minimo_venta_item()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'T1 validar_minimo_venta_item tiene que ser DEFINER y sin EXECUTE para anon ni authenticated'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · M1 M2 M3 M4 M5 I1 F1 T1';
END
$ensayo$;
