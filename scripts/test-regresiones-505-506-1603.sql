-- Ensayo de la tarjeta M10 del plan #1603: las regresiones que una revisión adversarial encontró
-- en la 505 (la fecha de entrega con rango, #1597) y la 506 (el regalo en la factura y los cargos
-- de una ZZ, #1593). Migración: 509_regresiones_fecha_entrega_y_total_zz.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la migración
-- falla en R1, B1, R3 y B4; B2 pasa en los dos (lo declara).
--
--   R1 · aplicar_cambio_de_parada con una fecha que la entrega rechaza: el chofer con hoy-10
--        (política de 2 días) y con mañana, el admin con hoy-61, dan el 22023 del rango y el
--        stock no se mueve. El chofer con hoy-1 y el admin con hoy-30 pasan, y la entrega
--        después también.
--   B1 · La regla lee la política de la sucursal sea quien sea el que llama: el depósito con el
--        rol extra de chofer (la policy le oculta la fila) no entrega con hoy-5 si la política
--        es de 2 días, y _fecha_entrega_fuera_de_rango y _fecha_pedido_fuera_de_rango le dan el
--        motivo. Un chofer de las dos sucursales, parado en la 1, recibe la política de la 2 (la
--        policy sólo deja ver la de la sucursal activa). Quien no es de la sucursal no la lee,
--        y un desactivado tampoco (M10-1 de la revisión, #1474).
--   R3 · Una ZZ con un flete en factura cargada por un front que manda total = subtotal (el PWA
--        de antes de la 506) guarda 1.300, no 1.000, en el alta y en la edición; COMPRA-A1 no
--        suma, y la NC de ajuste de 1.200 entra.
--   B4 · Una ZZ con un descuento en factura mayor que el subtotal se rechaza con un mensaje que
--        nombra el descuento, mande el front el total negativo o el subtotal, en el alta y en la
--        edición.
--   B2 · Un producto con stock y sin promedio, con un regalo y un renglón pagado en la misma
--        factura, queda en 66,67: el stock sin promedio toma el costo del renglón pagado y el
--        regalo diluye (declarado en migrations/CLAUDE.md).
--   D  · El bloque de datos de la migración (M10-3 de la revisión), copiado en
--        pg_temp.rehacer_totales_zz: tres ZZ guardadas como las dejaba un front viejo. Con un
--        flete el total sube a 1.300; con un descuento baja a 800; con un descuento y una NC de
--        ajuste de 1.000 queda en 1.000 (quedaría con más notas que total).
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-regresiones-505-506-1603.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_tra    uuid;
  v_dep    uuid;
  v_cli    bigint;
  v_pa     bigint;
  v_pb     bigint;
  v_rec    bigint;
  v_ped    bigint;
  v_k      bigint;
  v_c      bigint;
  v_j      jsonb;
  v_t      text;
  v_a1     int;
  v_lin    jsonb;
  v_flete  jsonb := jsonb_build_array(jsonb_build_object('concepto', 'Flete', 'monto', 300, 'condicion_iva', 'no_gravado',
                      'en_factura', true, 'prorratea_al_costo', true, 'base_prorrateo', 'unidades',
                      'pesos', jsonb_build_object('0', 10)));
  v_desc   jsonb := jsonb_build_array(jsonb_build_object('concepto', 'Descuento', 'monto', -1500, 'condicion_iva', 'no_gravado',
                      'en_factura', true, 'prorratea_al_costo', false, 'base_prorrateo', 'unidades',
                      'pesos', '{}'::jsonb));
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'm10-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'M10 ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
  END $f$;
  -- Corre p_sql como p_uid (authenticated, sucursal 1) y devuelve 'PASA <valor>' o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.intenta(p_uid uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text; x text;
  BEGIN
    PERFORM pg_temp.como(p_uid, 1);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql INTO x;
      r := 'PASA ' || COALESCE(x, '');
    EXCEPTION WHEN OTHERS THEN
      r := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  -- Una comanda de canje en la ruta en curso de p_tra: devuelve 3 de A y entrega 3 de B.
  CREATE FUNCTION pg_temp.canje(p_cli bigint, p_vend uuid, p_tra uuid, p_a bigint, p_b bigint) RETURNS bigint
  LANGUAGE plpgsql AS $f$
  DECLARE v bigint; r bigint;
  BEGIN
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura, transportista_id)
    VALUES (p_cli, 1, p_vend, 0, 'asignado', public._tablero_hoy(), 'cambio', 'ZZ', p_tra) RETURNING id INTO v;
    SELECT id INTO r FROM recorridos
     WHERE transportista_id = p_tra AND fecha = public._tablero_hoy() AND sucursal_id = 1;
    IF r IS NULL THEN
      INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id)
      VALUES (p_tra, public._tablero_hoy(), 'en_curso', 1) RETURNING id INTO r;
    END IF;
    INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, sucursal_id)
    VALUES (r, v, (SELECT COALESCE(max(orden_entrega), 0) + 1 FROM recorrido_pedidos WHERE recorrido_id = r), 1);
    INSERT INTO recorrido_cambios (pedido_id, cliente_id, producto_devuelto_id, cantidad_devuelta, producto_entregado_id,
                                   cantidad_entregada, sucursal_id)
    VALUES (v, p_cli, p_a, 3, p_b, 3, 1);
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.estado_canje(p bigint, p_a bigint, p_b bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('estado=%s aplicado=%s stockA=%s stockB=%s', pe.estado, rc.aplicado_at IS NOT NULL,
                  (SELECT stock FROM public.productos WHERE id = p_a), (SELECT stock FROM public.productos WHERE id = p_b))
      FROM public.pedidos pe JOIN public.recorrido_cambios rc ON rc.pedido_id = pe.id WHERE pe.id = p;
  $f$;
  CREATE FUNCTION pg_temp.patch_entrega(p bigint, p_dia date) RETURNS text LANGUAGE sql AS $f$
    SELECT format('UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = %L, updated_at = now() WHERE id = %s RETURNING id::text',
                  p_dia::text || 'T12:00:00-03:00', p);
  $f$;
  CREATE FUNCTION pg_temp.producto(p_nombre text, p_stock int, p_cpp numeric) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES ('M10 ' || p_nombre || ' ' || gen_random_uuid(), 100, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, 1) RETURNING id;
  $f$;
  -- renglones: defaults sin impuestos y el subtotal que cierra
  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(x || jsonb_build_object('subtotal',
             round((x->>'cantidad')::numeric * (x->>'costo_unitario')::numeric * (1 - (x->>'bonificacion')::numeric / 100), 2))
             ORDER BY o)
      FROM (SELECT jsonb_build_object('bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0) || e AS x, o
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)) s;
  $f$;
  CREATE FUNCTION pg_temp.alta(p_adm uuid, p_lin jsonb, p_total numeric, p_cargos jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.registrar_compra_completa(
      NULL, 'M10', 'M10-' || left(gen_random_uuid()::text, 8), public._tablero_hoy(),
      (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), 0, 0, p_total,
      'efectivo', 'm10', p_adm, p_lin, 'ZZ', p_cargos => p_cargos);
  END $f$;
  CREATE FUNCTION pg_temp.editar(p_adm uuid, p_c bigint, p_lin jsonb, p_total numeric, p_cargos jsonb) RETURNS jsonb
  LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.actualizar_compra_items(
      p_c, p_lin, (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), 0, p_total, p_adm,
      p_cargos => p_cargos, p_ii_declarado => '{}'::jsonb,
      p_renglones_vistos => (SELECT array_agg(id) FROM public.compra_items WHERE compra_id = p_c));
  END $f$;
  CREATE FUNCTION pg_temp.a1() RETURNS int LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::int FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     WHERE c->>'id' = 'COMPRA-A1';
  $f$;
  -- Copia del bloque $datos_zz$ de la migración (sin sus NOTICE): si cambia uno, cambia el otro.
  CREATE FUNCTION pg_temp.rehacer_totales_zz() RETURNS int LANGUAGE plpgsql AS $f$
  DECLARE n_hechas int;
  BEGIN
    CREATE TEMP TABLE m10_zz ON COMMIT DROP AS
    SELECT c.id, COALESCE(c.total, 0) AS antes, z.t AS nuevo, COALESCE(nc.acreditado, 0) AS acreditado
      FROM compras c
      JOIN LATERAL (SELECT sum(cc.monto) AS monto FROM compra_cargos cc
                     WHERE cc.compra_id = c.id AND cc.sucursal_id = c.sucursal_id AND cc.en_factura) cg
        ON cg.monto IS NOT NULL
     CROSS JOIN LATERAL (SELECT round(COALESCE(c.subtotal,0)+COALESCE(c.bonificaciones,0)+COALESCE(c.iva,0)
                                      +COALESCE(c.impuestos_internos,0)+COALESCE(c.percepcion_iva,0)
                                      +COALESCE(c.percepcion_iibb,0)+COALESCE(c.no_gravado,0)
                                      +COALESCE(c.otros_impuestos,0)+cg.monto, 2) AS t) z
      LEFT JOIN LATERAL (SELECT sum(n.total) AS acreditado FROM notas_credito n
                          WHERE n.compra_id = c.id AND n.sucursal_id = c.sucursal_id) nc ON true
     WHERE c.tipo_factura = 'ZZ' AND c.estado <> 'cancelada'
       AND abs(COALESCE(c.total, 0) - z.t) > 1.0;
    UPDATE compras c
       SET total = m.nuevo
      FROM m10_zz m
     WHERE c.id = m.id AND m.nuevo >= 0 AND m.acreditado <= m.nuevo;
    GET DIAGNOSTICS n_hechas = ROW_COUNT;
    DROP TABLE m10_zz;
    RETURN n_hechas;
  END $f$;

  -- ---------------------------------------------------------------- datos ---
  v_adm := pg_temp.u('admin', 1);
  v_tra := pg_temp.u('transportista', 1);
  v_dep := pg_temp.u('deposito', 1);
  INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_dep, 1, 'transportista');
  -- La política: 2 días en la sucursal 1, 1 en la 2.
  INSERT INTO politicas_comerciales (sucursal_id, dias_atras_fecha_pedido) VALUES (1, 2)
  ON CONFLICT (sucursal_id) DO UPDATE SET dias_atras_fecha_pedido = 2;
  INSERT INTO politicas_comerciales (sucursal_id, dias_atras_fecha_pedido) VALUES (2, 1)
  ON CONFLICT (sucursal_id) DO UPDATE SET dias_atras_fecha_pedido = 1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('M10 cliente', 'M10 cliente', 'calle m10', 1) RETURNING id INTO v_cli;
  INSERT INTO productos (nombre, precio, stock, sucursal_id) VALUES ('M10 A ' || gen_random_uuid(), 100, 50, 1) RETURNING id INTO v_pa;
  INSERT INTO productos (nombre, precio, stock, sucursal_id) VALUES ('M10 B ' || gen_random_uuid(), 100, 50, 1) RETURNING id INTO v_pb;

  -- ------------------------------------------------------------------- R1 ---
  v_ped := pg_temp.canje(v_cli, v_adm, v_tra, v_pa, v_pb);
  v_t := pg_temp.intenta(v_tra, format('SELECT public.aplicar_cambio_de_parada(%s, NULL, %L::date)::text', v_ped, v_hoy - 10));
  IF v_t NOT LIKE '22023 La fecha de entrega (%) no puede ser anterior al %' THEN
    v_fallas := v_fallas || format('R1 · chofer, aplicar con hoy-10 (política 2): esperaba el 22023 del rango y dio %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_tra, format('SELECT public.aplicar_cambio_de_parada(%s, NULL, %L::date)::text', v_ped, v_hoy + 1));
  IF v_t NOT LIKE '22023 La fecha de entrega (%) no puede ser posterior a hoy.%' THEN
    v_fallas := v_fallas || format('R1 · chofer, aplicar con mañana: esperaba el 22023 del techo y dio %s', v_t);
  END IF;
  v_t := pg_temp.estado_canje(v_ped, v_pa, v_pb);
  IF v_t IS DISTINCT FROM 'estado=asignado aplicado=f stockA=50 stockB=50' THEN
    v_fallas := v_fallas || format('R1 · el rechazo movió el canje: %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_tra, format('SELECT public.aplicar_cambio_de_parada(%s, NULL, %L::date)::text', v_ped, v_hoy - 1));
  IF v_t NOT LIKE 'PASA %' THEN
    v_fallas := v_fallas || format('R1 · chofer, aplicar con hoy-1: %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_tra, pg_temp.patch_entrega(v_ped, v_hoy - 1));
  IF v_t NOT LIKE 'PASA %' THEN
    v_fallas := v_fallas || format('R1 · chofer, entrega con hoy-1: %s', v_t);
  END IF;
  v_t := pg_temp.estado_canje(v_ped, v_pa, v_pb);
  IF v_t IS DISTINCT FROM 'estado=entregado aplicado=t stockA=53 stockB=47' THEN
    v_fallas := v_fallas || format('R1 · el canje con hoy-1 no quedó entregado y aplicado: %s', v_t);
  END IF;
  -- El admin: hasta 60 días.
  v_ped := pg_temp.canje(v_cli, v_adm, v_tra, v_pa, v_pb);
  v_t := pg_temp.intenta(v_adm, format('SELECT public.aplicar_cambio_de_parada(%s, NULL, %L::date)::text', v_ped, v_hoy - 61));
  IF v_t NOT LIKE '22023 La fecha de entrega (%) no puede ser anterior al %: hasta 60 días atrás.' THEN
    v_fallas := v_fallas || format('R1 · admin, aplicar con hoy-61: esperaba el 22023 del rango y dio %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm, format('SELECT public.aplicar_cambio_de_parada(%s, NULL, %L::date)::text', v_ped, v_hoy - 30));
  IF v_t NOT LIKE 'PASA %' THEN
    v_fallas := v_fallas || format('R1 · admin, aplicar con hoy-30: %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm, pg_temp.patch_entrega(v_ped, v_hoy - 30));
  IF v_t NOT LIKE 'PASA %' THEN
    v_fallas := v_fallas || format('R1 · admin, entrega con hoy-30: %s', v_t);
  END IF;

  -- ------------------------------------------------------------------- B1 ---
  v_t := pg_temp.intenta(v_dep, 'SELECT count(*)::text FROM public.politicas_comerciales');
  v_notas := v_notas || format('B1 · filas de la política que ve el depósito: %s', v_t);
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura, transportista_id)
  VALUES (v_cli, 1, v_adm, 100, 'asignado', v_hoy, 'app', 'ZZ', v_dep) RETURNING id INTO v_ped;
  v_t := pg_temp.intenta(v_dep, pg_temp.patch_entrega(v_ped, v_hoy - 5));
  IF v_t NOT LIKE '22023 La fecha de entrega (%) no puede ser anterior al %: hasta 2 días atrás.%' THEN
    v_fallas := v_fallas || format('B1 · depósito con el extra de chofer, entrega con hoy-5 (política 2): esperaba 22023 y dio %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_dep, format('SELECT public._fecha_entrega_fuera_de_rango(%L::date, 1, false)', v_hoy - 5));
  IF v_t NOT LIKE 'PASA La fecha de entrega%' THEN
    v_fallas := v_fallas || format('B1 · _fecha_entrega_fuera_de_rango como depósito, hoy-5: esperaba el motivo y dio %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_dep, format('SELECT public._fecha_pedido_fuera_de_rango(%L::date, 1)', v_hoy - 5));
  IF v_t NOT LIKE 'PASA La fecha del pedido%' THEN
    v_fallas := v_fallas || format('B1 · _fecha_pedido_fuera_de_rango como depósito, hoy-5: esperaba el motivo y dio %s', v_t);
  END IF;
  -- Quien no es de la sucursal 2 no lee su política (rige el 7); un chofer de las dos, parado en
  -- la 1, sí (la policy sólo le muestra la de la sucursal activa).
  v_t := pg_temp.intenta(v_tra, format('SELECT public._fecha_entrega_fuera_de_rango(%L::date, 2, false)', v_hoy - 2));
  IF v_t IS DISTINCT FROM 'PASA ' THEN
    v_fallas := v_fallas || format('B1 · un chofer que no es de la sucursal 2 leyó su política: %s', v_t);
  END IF;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_tra, 2);
  v_t := pg_temp.intenta(v_tra, format('SELECT public._fecha_entrega_fuera_de_rango(%L::date, 2, false)', v_hoy - 2));
  IF v_t NOT LIKE 'PASA La fecha de entrega (%) no puede ser anterior al %: hasta 1 día atrás.%' THEN
    v_fallas := v_fallas || format('B1 · chofer de las dos sucursales, regla de la 2 con hoy-2 (política 1): %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_tra, format('SELECT public._fecha_pedido_fuera_de_rango(%L::date, 2)', v_hoy - 2));
  IF v_t NOT LIKE 'PASA La fecha del pedido%' THEN
    v_fallas := v_fallas || format('B1 · chofer de las dos sucursales, fecha del pedido de la 2 con hoy-2 (política 1): %s', v_t);
  END IF;
  -- M10-1 · un desactivado (con el token vivo) no lee la política; uno activo sí.
  DECLARE v_prev uuid := pg_temp.u('preventista', 1);
  BEGIN
    v_t := pg_temp.intenta(v_prev, 'SELECT public._dias_atras_fecha_pedido(1)::text');
    IF v_t IS DISTINCT FROM 'PASA 2' THEN
      v_fallas := v_fallas || format('M10-1 · preventista activo de la sucursal 1, días de su política: %s', v_t);
    END IF;
    -- Sin los triggers de perfiles: el que banea en auth.users no tiene la columna en una base
    -- local con la semilla mínima, y lo que se prueba es sólo `activo` (el token sigue vivo).
    SET LOCAL session_replication_role = replica;
    UPDATE perfiles SET activo = false WHERE id = v_prev;
    SET LOCAL session_replication_role = origin;
    v_t := pg_temp.intenta(v_prev, 'SELECT public._dias_atras_fecha_pedido(1)::text');
    IF v_t IS DISTINCT FROM 'PASA ' THEN
      v_fallas := v_fallas || format('M10-1 · un desactivado leyó los días de su política: %s', v_t);
    END IF;
  EXCEPTION WHEN undefined_function THEN
    v_fallas := v_fallas || 'M10-1 · _dias_atras_fecha_pedido(bigint) no existe'::text;
  END;
  IF to_regprocedure('public._dias_atras_fecha_pedido(bigint)') IS NULL THEN
    v_fallas := v_fallas || 'B1 · _dias_atras_fecha_pedido(bigint) no existe'::text;
  ELSIF has_function_privilege('anon', 'public._dias_atras_fecha_pedido(bigint)', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                 WHERE p.oid = 'public._dias_atras_fecha_pedido(bigint)'::regprocedure AND a.grantee = 0)
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public._dias_atras_fecha_pedido(bigint)'::regprocedure) THEN
    v_fallas := v_fallas || '_dias_atras_fecha_pedido no es DEFINER o tiene EXECUTE para PUBLIC o anon'::text;
  END IF;

  -- ------------------------------------------------------------------- R3 ---
  v_a1 := pg_temp.a1();
  v_k := pg_temp.producto('R3', 0, NULL);
  v_lin := pg_temp.lineas(jsonb_build_array(jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100)));
  -- el front viejo: total = subtotal
  v_j := pg_temp.alta(v_adm, v_lin, 1000, v_flete);
  IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('R3 · alta ZZ del front viejo: %s', v_j);
  ELSE
    v_c := (v_j->>'compra_id')::bigint;
    IF (SELECT total FROM compras WHERE id = v_c) IS DISTINCT FROM 1300.00 THEN
      v_fallas := v_fallas || format('R3 · alta ZZ 10 x 100 + flete 300, total informado 1000: guardó %s y no 1300',
                                     (SELECT total FROM compras WHERE id = v_c));
    END IF;
    v_notas := v_notas || format('R3 · aviso del alta con el front viejo: %s', COALESCE(v_j->>'warning_descuadre', '-'));
    v_j := pg_temp.editar(v_adm, v_c, v_lin, 1000, v_flete);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT total FROM compras WHERE id = v_c) IS DISTINCT FROM 1300.00 THEN
      v_fallas := v_fallas || format('R3 · edición ZZ con total 1000: %s, total guardado %s', v_j,
                                     (SELECT total FROM compras WHERE id = v_c));
    END IF;
    IF pg_temp.a1() IS DISTINCT FROM v_a1 THEN
      v_fallas := v_fallas || format('R3 · COMPRA-A1 pasó de %s a %s', v_a1, pg_temp.a1());
    END IF;
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.registrar_nota_credito(v_c, 'M10-NC-' || left(gen_random_uuid()::text, 8), 'ajuste', 1200, 0, 1200, v_adm,
                                         '[]'::jsonb, 0);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('R3 · NC de ajuste de 1200 sobre la ZZ de 1300: %s', v_j);
    END IF;
  END IF;
  -- el front nuevo: total 1300, sin aviso
  v_j := pg_temp.alta(v_adm, v_lin, 1300, v_flete);
  IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_j->>'warning_descuadre' IS NOT NULL
     OR (SELECT total FROM compras WHERE id = (v_j->>'compra_id')::bigint) IS DISTINCT FROM 1300.00 THEN
    v_fallas := v_fallas || format('R3 · alta ZZ del front nuevo (1300): %s', v_j);
  END IF;

  -- ------------------------------------------------------------------- B4 ---
  v_j := pg_temp.alta(v_adm, v_lin, -500, v_desc);
  IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT ILIKE '%descuento%' THEN
    v_fallas := v_fallas || format('B4 · alta ZZ con descuento -1500 sobre 1000, total -500: %s', v_j);
  END IF;
  v_j := pg_temp.alta(v_adm, v_lin, 1000, v_desc);
  IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT ILIKE '%descuento%' THEN
    v_fallas := v_fallas || format('B4 · alta ZZ con descuento -1500 sobre 1000, total 1000 (front viejo): %s', v_j);
  END IF;
  v_j := pg_temp.alta(v_adm, v_lin, 1000, '[]'::jsonb);
  v_c := (v_j->>'compra_id')::bigint;
  v_j := pg_temp.editar(v_adm, v_c, v_lin, -500, v_desc);
  IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT ILIKE '%descuento%' THEN
    v_fallas := v_fallas || format('B4 · edición ZZ con descuento -1500, total -500: %s', v_j);
  END IF;
  v_j := pg_temp.editar(v_adm, v_c, v_lin, 1000, v_desc);
  IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT ILIKE '%descuento%' THEN
    v_fallas := v_fallas || format('B4 · edición ZZ con descuento -1500, total 1000 (front viejo): %s', v_j);
  END IF;
  IF (SELECT total FROM compras WHERE id = v_c) IS DISTINCT FROM 1000.00 THEN
    v_fallas := v_fallas || format('B4 · la edición rechazada cambió el total: %s', (SELECT total FROM compras WHERE id = v_c));
  END IF;
  IF pg_temp.a1() IS DISTINCT FROM v_a1 THEN
    v_fallas := v_fallas || format('R3/B4 · COMPRA-A1 pasó de %s a %s', v_a1, pg_temp.a1());
  END IF;

  -- ------------------------------------------------------------------- B2 ---
  v_k := pg_temp.producto('B2', 10, NULL);
  v_j := pg_temp.alta(v_adm, pg_temp.lineas(jsonb_build_array(
           jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100),
           jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100))), 1000, '[]'::jsonb);
  IF NOT COALESCE((v_j->>'success')::boolean, false)
     OR (SELECT round(costo_promedio, 4) FROM productos WHERE id = v_k) IS DISTINCT FROM 66.6667 THEN
    v_fallas := v_fallas || format('B2 · stock 10 sin promedio, regalo 10 y 10 a 100: %s, promedio %s', v_j->>'success',
                                   (SELECT costo_promedio FROM productos WHERE id = v_k));
  END IF;

  -- -------------------------------------------------------------------- D ---
  -- Tres ZZ guardadas como las dejaba un front viejo (el total que mandó, no el de COMPRA-A1).
  DECLARE
    v_k2 bigint := pg_temp.producto('D', 0, NULL);
    v_l2 jsonb := pg_temp.lineas(jsonb_build_array(jsonb_build_object('producto_id', v_k2, 'cantidad', 10, 'costo_unitario', 100)));
    v_d200 jsonb := jsonb_build_array(jsonb_build_object('concepto', 'Descuento', 'monto', -200, 'condicion_iva', 'no_gravado',
                      'en_factura', true, 'prorratea_al_costo', false, 'base_prorrateo', 'unidades', 'pesos', '{}'::jsonb));
    v_sube bigint; v_baja bigint; v_nc bigint; v_n int;
  BEGIN
    v_sube := (pg_temp.alta(v_adm, v_l2, 1000, v_flete)->>'compra_id')::bigint;
    v_baja := (pg_temp.alta(v_adm, v_l2, 1000, v_d200)->>'compra_id')::bigint;
    v_nc   := (pg_temp.alta(v_adm, v_l2, 1000, v_d200)->>'compra_id')::bigint;
    UPDATE compras SET total = 1000 WHERE id IN (v_sube, v_baja, v_nc);
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.registrar_nota_credito(v_nc, 'M10-D-' || left(gen_random_uuid()::text, 8), 'ajuste', 1000, 0, 1000, v_adm,
                                         '[]'::jsonb, 0);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('D · la NC de ajuste de 1000 no entró: %s', v_j);
    END IF;
    v_n := pg_temp.rehacer_totales_zz();
    v_t := format('sube=%s baja=%s nc=%s rehechas=%s',
                  (SELECT total FROM compras WHERE id = v_sube), (SELECT total FROM compras WHERE id = v_baja),
                  (SELECT total FROM compras WHERE id = v_nc), v_n);
    IF v_t IS DISTINCT FROM 'sube=1300.00 baja=800.00 nc=1000.00 rehechas=2' THEN
      v_fallas := v_fallas || format('D · el bloque de datos: esperaba sube=1300.00 baja=800.00 nc=1000.00 rehechas=2 y dio %s', v_t);
    END IF;
  END;

  RAISE EXCEPTION USING ERRCODE = 'ZZ001';
 EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas:\n  %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, E'\n  '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format(E'ENSAYO OK (todo revertido)\nnotas:\n  %s',
    array_to_string(v_notas, E'\n  '));
END
$ensayo$;
