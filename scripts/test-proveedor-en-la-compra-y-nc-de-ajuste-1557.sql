-- Ensayo de la migración «la compra conserva el nombre del proveedor, la NC de ajuste cuadra y no
-- pasa lo que le queda a la compra, y el depósito no lee las cabeceras de compras» (reauditoría del
-- 12/11: CMP-4, CMP-2 y CMP-6 de #1557; tarjeta 2 de #1565).
--
-- Corre contra prod SIN dejar rastro (salvo valores de secuencia): un único DO que termina SIEMPRE
-- en una excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN
-- y el COMMIT; después, solo. Cada caso usa sus propios proveedores, productos y compras.
--
-- Personas (salen de la base): un admin activo de una sucursal activa. El encargado de P5 y el
-- depósito de D1 los crea el ensayo. Las compras son ZZ salvo la de N2 (FC A): en una ZZ el ajuste es sólo un total.
--
-- CMP-4 · la compra conserva el nombre del proveedor.
--   P1 · el alta con proveedor y sin nombre (como el modal) guarda el nombre; eliminar el
--        proveedor deja la compra sin id y con el nombre, el producto sin proveedor y la
--        equivalencia borrada, y la RPC lo cuenta.
--   P2 · un proveedor renombrado después de la compra: al eliminarlo la compra queda con el
--        nombre vigente, el que mostraba la pantalla.
--   P3 · el alta con proveedor y otro nombre guarda el del proveedor.
--   P4 · un DELETE que no pasa por la RPC: el SET NULL de la FK tampoco deja la compra sin nombre.
--   P5 · los permisos: el trigger no lo ejecuta la app, y eliminar sigue siendo sólo del admin.
--   P6 · ninguna compra de la base tiene id sin nombre.
-- CMP-2 · la NC de ajuste cuadra y tiene tope (compra ZZ de 10 × 121 = 1.210).
--   N1 · un ajuste de 50.000 no entra; uno de 1.000 sí; después uno de 300 no (quedan 210), uno de
--        210 sí, y uno de 0,01 ya no.
--   N2 · FC A de 10 × 1.000 = 10.000: un ajuste de 100 + 21 con total 9.999 no entra; con 121, sí.
--   N3 · un ajuste con subtotal 'NaN' no entra, ni uno con total 'NaN'.
--   N4 · una devolución también cuenta: compra de 10 × 100, NC de 3 u. (300); un ajuste de 800 no
--        entra, uno de 700 sí.
-- CMP-6 · el depósito no lee las cabeceras (decisión del dueño, 12/11).
--   D1 · una compra con un cargo prorrateado y una NC: el depósito no ve la compra, el cargo, su
--        reparto ni la NC; el encargado ve las cuatro.
-- Regresión que pasa con y sin la migración: la devolución de N4, el rechazo del no admin de P5 y lo
-- que ve el encargado en D1.
--
-- Sin la migración tiene que FALLAR en P1–P5, P6 (en una base con compras sin nombre), N1, N2, N4 y
-- D1, y en N3 si tampoco está la 493 (sus CHECK de `notas_credito` ya rechazan el NaN).
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.

DO $ensayo$
DECLARE
  v_ua uuid; v_suc bigint; v_enc uuid; v_dep uuid; v_cargos bigint[];
  v_fallas text := '';
  v_prov bigint; v_prov2 bigint; v_prod bigint; v_prod2 bigint;
  v_compra bigint; v_compra2 bigint;
  v_j jsonb; v_n int; v_t text;
BEGIN
  SET LOCAL lock_timeout = '5s';
  SELECT us.usuario_id, us.sucursal_id INTO v_ua, v_suc
    FROM usuario_sucursales us
    JOIN perfiles p ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.sucursal_id, us.usuario_id LIMIT 1;
  IF v_ua IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: no hay un admin activo de una sucursal activa';
  END IF;
  PERFORM set_config('ens.ua', v_ua::text, true);
  PERFORM set_config('ens.suc', v_suc::text, true);

  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  CREATE FUNCTION pg_temp.producto(p_nombre text) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, sucursal_id)
    VALUES (p_nombre || ' ' || gen_random_uuid(), 100, 0, current_setting('ens.suc')::bigint) RETURNING id;
  $f$;

  CREATE FUNCTION pg_temp.proveedor(p_nombre text) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.proveedores (nombre, sucursal_id, activo)
    VALUES (p_nombre || ' ' || gen_random_uuid(), current_setting('ens.suc')::bigint, true) RETURNING id;
  $f$;

  -- una compra de un renglón; con proveedor, el nombre va como lo manda el modal (o el que se pase)
  CREATE FUNCTION pg_temp.comprar(p_prov bigint, p_nombre text, p_prod bigint, p_cant int, p_costo numeric,
                                  p_tipo text DEFAULT 'ZZ', p_iva numeric DEFAULT 0)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_sub numeric := round(p_cant * p_costo, 2);
    v_iva numeric := round(v_sub * p_iva / 100, 2);
    v_r jsonb;
  BEGIN
    PERFORM pg_temp.como(current_setting('ens.ua')::uuid, current_setting('ens.suc')::bigint);
    v_r := public.registrar_compra_completa(
      p_prov, p_nombre, 'ENS-1557-' || gen_random_uuid(), public._tablero_hoy(),
      v_sub, v_iva, 0, v_sub + v_iva, 'efectivo', 'ensayo 1557', current_setting('ens.ua')::uuid,
      jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'costo_unitario', p_costo,
        'bonificacion', 0, 'porcentaje_iva', p_iva, 'impuestos_internos', 0, 'subtotal', v_sub)),
      p_tipo, p_letra_comprobante => CASE WHEN p_tipo = 'FC' THEN 'A' END);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra no se registró: %', v_r;
    END IF;
    RETURN (v_r->>'compra_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.ajuste(p_compra bigint, p_sub numeric, p_iva numeric, p_total numeric, p_ii numeric DEFAULT 0)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(current_setting('ens.ua')::uuid, current_setting('ens.suc')::bigint);
    RETURN public.registrar_nota_credito(p_compra, 'ENS-NC-' || gen_random_uuid(), 'ensayo 1557',
                                         p_sub, p_iva, p_total, current_setting('ens.ua')::uuid, '[]'::jsonb, p_ii);
  END $f$;

  CREATE FUNCTION pg_temp.paso(p_j jsonb) RETURNS boolean LANGUAGE sql AS $f$
    SELECT COALESCE((p_j->>'success')::boolean, false);
  $f$;

  -- ------------------------------------------------------------------ P1
  PERFORM pg_temp.como(v_ua, v_suc);
  v_prov := pg_temp.proveedor('ENS P1');
  v_prod := pg_temp.producto('ENS P1');
  UPDATE productos SET proveedor_id = v_prov WHERE id = v_prod;
  INSERT INTO producto_equivalencias_proveedor (sucursal_id, proveedor_id, producto_id, codigo_proveedor, descripcion_normalizada)
  VALUES (v_suc, v_prov, v_prod, 'ENS1557', 'ens 1557 ' || v_prov);
  v_compra := pg_temp.comprar(v_prov, NULL, v_prod, 10, 100);
  IF (SELECT proveedor_nombre FROM compras WHERE id = v_compra) IS DISTINCT FROM (SELECT nombre FROM proveedores WHERE id = v_prov) THEN
    v_fallas := v_fallas || format(E'\n P1: el alta no guardó el nombre (quedó %s)',
                                   COALESCE((SELECT proveedor_nombre FROM compras WHERE id = v_compra), 'NULL'));
  END IF;
  v_t := (SELECT nombre FROM proveedores WHERE id = v_prov);
  PERFORM pg_temp.como(v_ua, v_suc);
  v_j := public.eliminar_proveedor(v_prov);
  IF NOT pg_temp.paso(v_j) THEN
    v_fallas := v_fallas || E'\n P1: eliminar_proveedor no pasó: ' || v_j::text;
  END IF;
  IF (SELECT format('%s|%s', COALESCE(proveedor_id::text, 'NULL'), COALESCE(proveedor_nombre, 'NULL')) FROM compras WHERE id = v_compra)
     IS DISTINCT FROM 'NULL|' || v_t THEN
    v_fallas := v_fallas || E'\n P1: la compra quedó ' ||
      (SELECT format('proveedor_id=%s proveedor_nombre=%s', COALESCE(proveedor_id::text, 'NULL'), COALESCE(proveedor_nombre, 'NULL'))
         FROM compras WHERE id = v_compra);
  END IF;
  IF (SELECT proveedor_id FROM productos WHERE id = v_prod) IS NOT NULL
     OR EXISTS (SELECT 1 FROM producto_equivalencias_proveedor WHERE proveedor_id = v_prov) THEN
    v_fallas := v_fallas || E'\n P1: el producto sigue con proveedor o la equivalencia sigue';
  END IF;
  IF (v_j->>'compras')::int IS DISTINCT FROM 1 OR (v_j->>'productos_sin_proveedor')::int IS DISTINCT FROM 1
     OR (v_j->>'equivalencias_borradas')::int IS DISTINCT FROM 1 THEN
    v_fallas := v_fallas || E'\n P1: la RPC no cuenta lo que toca: ' || v_j::text;
  END IF;

  -- ------------------------------------------------------------------ P2
  v_prov := pg_temp.proveedor('ENS P2 viejo');
  v_prod := pg_temp.producto('ENS P2');
  v_compra := pg_temp.comprar(v_prov, NULL, v_prod, 5, 100);
  UPDATE proveedores SET nombre = 'ENS P2 nuevo ' || v_prov WHERE id = v_prov;
  PERFORM pg_temp.como(v_ua, v_suc);
  v_j := public.eliminar_proveedor(v_prov);
  IF (SELECT proveedor_nombre FROM compras WHERE id = v_compra) IS DISTINCT FROM 'ENS P2 nuevo ' || v_prov THEN
    v_fallas := v_fallas || format(E'\n P2: renombrado y eliminado, la compra quedó con %s',
                                   COALESCE((SELECT proveedor_nombre FROM compras WHERE id = v_compra), 'NULL'));
  END IF;

  -- ------------------------------------------------------------------ P3
  v_prov := pg_temp.proveedor('ENS P3');
  v_prod := pg_temp.producto('ENS P3');
  v_compra := pg_temp.comprar(v_prov, 'OTRO NOMBRE', v_prod, 5, 100);
  IF (SELECT proveedor_nombre FROM compras WHERE id = v_compra) IS DISTINCT FROM (SELECT nombre FROM proveedores WHERE id = v_prov) THEN
    v_fallas := v_fallas || format(E'\n P3: con proveedor y otro nombre, la compra guardó %s',
                                   COALESCE((SELECT proveedor_nombre FROM compras WHERE id = v_compra), 'NULL'));
  END IF;

  -- ------------------------------------------------------------------ P4
  -- un DELETE pelado (como el SQL a mano), con la compra todavía sin nombre (las de antes del relleno)
  v_prov := pg_temp.proveedor('ENS P4');
  v_prod := pg_temp.producto('ENS P4');
  v_compra := pg_temp.comprar(v_prov, NULL, v_prod, 5, 100);
  v_t := (SELECT nombre FROM proveedores WHERE id = v_prov);
  DELETE FROM proveedores WHERE id = v_prov;
  IF (SELECT proveedor_nombre FROM compras WHERE id = v_compra) IS DISTINCT FROM v_t THEN
    v_fallas := v_fallas || format(E'\n P4: tras un DELETE directo la compra quedó con %s',
                                   COALESCE((SELECT proveedor_nombre FROM compras WHERE id = v_compra), 'NULL'));
  END IF;

  -- ------------------------------------------------------------------ P5
  IF to_regprocedure('public.compras_guarda_proveedor_nombre()') IS NULL THEN
    v_fallas := v_fallas || E'\n P5: no existe compras_guarda_proveedor_nombre()';
  ELSIF has_function_privilege('anon', 'public.compras_guarda_proveedor_nombre()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.compras_guarda_proveedor_nombre()', 'EXECUTE') THEN
    v_fallas := v_fallas || E'\n P5: la función de trigger es ejecutable por la app';
  END IF;
  v_enc := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_enc, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ens-1557-' || v_enc || '@x.test', jsonb_build_object('rol', 'encargado', 'sucursal_id', v_suc), '{}'::jsonb, now(), now());
  v_prov := pg_temp.proveedor('ENS P5');
  PERFORM pg_temp.como(v_enc, v_suc);
  BEGIN
    v_j := public.eliminar_proveedor(v_prov);
    v_fallas := v_fallas || E'\n P5: un encargado eliminó un proveedor: ' || v_j::text;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- ------------------------------------------------------------------ P6
  SELECT count(*) INTO v_n FROM compras WHERE proveedor_id IS NOT NULL AND proveedor_nombre IS NULL;
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(E'\n P6: hay %s compras con proveedor y sin nombre', v_n);
  END IF;

  -- ------------------------------------------------------------------ N1
  v_prod := pg_temp.producto('ENS N1');
  v_compra := pg_temp.comprar(NULL, 'ENS N1', v_prod, 10, 121);
  IF pg_temp.paso(pg_temp.ajuste(v_compra, 50000, 0, 50000)) THEN
    v_fallas := v_fallas || E'\n N1: entró un ajuste de 50.000 sobre una compra de 1.210';
  END IF;
  v_j := pg_temp.ajuste(v_compra, 1000, 0, 1000);
  IF NOT pg_temp.paso(v_j) THEN
    v_fallas := v_fallas || E'\n N1: no entró un ajuste de 1.000 sobre 1.210: ' || v_j::text;
  END IF;
  IF pg_temp.paso(pg_temp.ajuste(v_compra, 300, 0, 300)) THEN
    v_fallas := v_fallas || E'\n N1: entró un ajuste de 300 con 210 por acreditar';
  END IF;
  v_j := pg_temp.ajuste(v_compra, 210, 0, 210);
  IF NOT pg_temp.paso(v_j) THEN
    v_fallas := v_fallas || E'\n N1: no entró el ajuste de los 210 que quedaban: ' || v_j::text;
  END IF;
  IF pg_temp.paso(pg_temp.ajuste(v_compra, 0.01, 0, 0.01)) THEN
    v_fallas := v_fallas || E'\n N1: entró un ajuste con la compra ya acreditada entera';
  END IF;

  -- ------------------------------------------------------------------ N2
  v_prod := pg_temp.producto('ENS N2');
  v_compra := pg_temp.comprar(NULL, 'ENS N2', v_prod, 10, 1000, 'FC', 21);
  IF pg_temp.paso(pg_temp.ajuste(v_compra, 100, 21, 9999)) THEN
    v_fallas := v_fallas || E'\n N2: entró un ajuste de 100 + 21 con total 9.999';
  END IF;
  v_j := pg_temp.ajuste(v_compra, 100, 21, 121);
  IF NOT pg_temp.paso(v_j) THEN
    v_fallas := v_fallas || E'\n N2: no entró un ajuste de 100 + 21 = 121: ' || v_j::text;
  END IF;

  -- ------------------------------------------------------------------ N3
  v_prod := pg_temp.producto('ENS N3');
  v_compra := pg_temp.comprar(NULL, 'ENS N3', v_prod, 10, 100);
  BEGIN
    IF pg_temp.paso(pg_temp.ajuste(v_compra, 'NaN', 0, 100)) THEN
      v_fallas := v_fallas || E'\n N3: entró un ajuste con subtotal NaN';
    END IF;
  EXCEPTION WHEN check_violation THEN NULL;  -- con el CHECK de la tarjeta 1 tampoco entra
  END;
  BEGIN
    IF pg_temp.paso(pg_temp.ajuste(v_compra, 'NaN', 0, 'NaN')) THEN
      v_fallas := v_fallas || E'\n N3: entró un ajuste con total NaN';
    END IF;
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- ------------------------------------------------------------------ N4
  v_prod := pg_temp.producto('ENS N4');
  v_compra := pg_temp.comprar(NULL, 'ENS N4', v_prod, 10, 100);
  PERFORM pg_temp.como(v_ua, v_suc);
  v_j := public.registrar_nota_credito(v_compra, 'ENS-NC-DEV-' || v_compra, 'ensayo 1557', 300, 0, 300, v_ua,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 3, 'subtotal', 300)), 0);
  IF NOT pg_temp.paso(v_j) THEN
    v_fallas := v_fallas || E'\n N4: no entró la devolución de 3 u.: ' || v_j::text;
  END IF;
  IF pg_temp.paso(pg_temp.ajuste(v_compra, 800, 0, 800)) THEN
    v_fallas := v_fallas || E'\n N4: entró un ajuste de 800 con 700 por acreditar (la devolución no contó)';
  END IF;
  v_j := pg_temp.ajuste(v_compra, 700, 0, 700);
  IF NOT pg_temp.paso(v_j) THEN
    v_fallas := v_fallas || E'\n N4: no entró el ajuste de los 700 que quedaban: ' || v_j::text;
  END IF;

  -- ------------------------------------------------------------------ D1
  v_prod := pg_temp.producto('ENS D1');
  PERFORM pg_temp.como(v_ua, v_suc);
  v_j := public.registrar_compra_completa(NULL, 'ENS D1', 'ENS-1557-D1-' || gen_random_uuid(), public._tablero_hoy(),
           1000, 0, 0, 1500, 'efectivo', 'ensayo 1557', v_ua,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'costo_unitario', 100,
             'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0, 'subtotal', 1000)), 'ZZ',
           p_cargos => jsonb_build_array(jsonb_build_object('concepto', 'flete', 'monto', 500, 'condicion_iva', 'no_gravado',
             'en_factura', true, 'prorratea_al_costo', true, 'base_prorrateo', 'unidades', 'pesos', jsonb_build_object('0', 10))));
  IF NOT pg_temp.paso(v_j) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: la compra de D1 no se registró: %', v_j;
  END IF;
  v_compra := (v_j->>'compra_id')::bigint;
  v_j := pg_temp.ajuste(v_compra, 100, 0, 100);
  IF NOT pg_temp.paso(v_j) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: la NC de D1 no se registró: %', v_j;
  END IF;
  SELECT array_agg(id) INTO v_cargos FROM compra_cargos WHERE compra_id = v_compra;
  IF COALESCE(array_length(v_cargos, 1), 0) = 0
     OR NOT EXISTS (SELECT 1 FROM compra_cargo_repartos WHERE cargo_id = ANY (v_cargos)) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: la compra de D1 no quedó con su cargo y su reparto';
  END IF;
  v_dep := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_dep, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ens-1557-dep-' || v_dep || '@x.test', jsonb_build_object('rol', 'deposito', 'sucursal_id', v_suc), '{}'::jsonb, now(), now());
  PERFORM pg_temp.como(v_dep, v_suc);
  SET LOCAL ROLE authenticated;
  v_t := concat_ws(', ',
    CASE WHEN EXISTS (SELECT 1 FROM compras WHERE id = v_compra) THEN 'la compra' END,
    CASE WHEN EXISTS (SELECT 1 FROM compra_cargos WHERE compra_id = v_compra) THEN 'el cargo' END,
    CASE WHEN EXISTS (SELECT 1 FROM compra_cargo_repartos WHERE cargo_id = ANY (v_cargos)) THEN 'el reparto' END,
    CASE WHEN EXISTS (SELECT 1 FROM notas_credito WHERE compra_id = v_compra) THEN 'la NC' END);
  RESET ROLE;
  IF v_t <> '' THEN
    v_fallas := v_fallas || E'\n D1: el depósito ve ' || v_t;
  END IF;
  PERFORM pg_temp.como(v_enc, v_suc);
  SET LOCAL ROLE authenticated;
  v_t := concat_ws(', ',
    CASE WHEN NOT EXISTS (SELECT 1 FROM compras WHERE id = v_compra) THEN 'la compra' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM compra_cargos WHERE compra_id = v_compra) THEN 'el cargo' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM compra_cargo_repartos WHERE cargo_id = ANY (v_cargos)) THEN 'el reparto' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM notas_credito WHERE compra_id = v_compra) THEN 'la NC' END);
  RESET ROLE;
  IF v_t <> '' THEN
    v_fallas := v_fallas || E'\n D1: el encargado no ve ' || v_t;
  END IF;

  IF v_fallas = '' THEN
    RAISE EXCEPTION 'ENSAYO OK: P1–P6, N1–N4 y D1';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ:%', v_fallas;
END
$ensayo$;
