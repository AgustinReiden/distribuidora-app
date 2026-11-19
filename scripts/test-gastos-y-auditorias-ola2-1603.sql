-- Ensayo de la tarjeta C5 (tanda 5 de la ola 2, #1603): gastos, personal, auditorías y los dos lectores
-- de ventas que con estadísticas viejas se iban a nested loop. Va con migrations/NNN_gastos_personal_auditorias_y_tiempos.sql.
--
--   G   1562-b2  guardar_gasto: un infinito (y los litros fuera de su columna) se rechazan con su motivo.
--   E   1597-b6  guardar_empleado: la fecha de ingreso no es futura ni 'infinity' (al cargarla y al cambiarla).
--   L   SEG-6    ninguna función de public con CRLF (eran 29), SEG-C la vigila, y las de personal andan.
--   R   1332-f   auditoria_integridad(): ROT-A, ROT-B y ROT-C en 0 con el camino de la app, y en rojo con
--                cada rotura mal armada a mano.
--   F   auditoria_fechas_utc(): un literal con dos guiones ya no esconde el día del servidor que lo sigue.
--   V   N8       _tablero_ventas y _ventas_nc dan las mismas filas que los cuerpos de la 530 (copiados acá).
--
-- Sólo pide la semilla de docker-local.mjs (el admin ...04e7 en las sucursales 1 y 2). Todo se deshace: el
-- ensayo termina en un RAISE. Una línea «ERROR: ENSAYO OK …» es éxito.
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-gastos-y-auditorias-ola2-1603.sql

DO $ensayo$
DECLARE
  v_adm    uuid := '00000000-0000-0000-0000-0000000004e7';
  v_s      bigint := 1;
  v_hoy    date := public._tablero_hoy();
  v_fallas text[] := '{}';
  v_txt    text;
  v_rubro  bigint;
  v_lib    bigint;
  v_e      bigint;
  v_e2     bigint;
  v_prod   bigint;
  v_merma  bigint;
  v_rot    bigint;
  v_comp   bigint;
  v_cli    bigint;
  v_cli2   bigint;
  v_zona   bigint;
  v_ped    bigint;
  v_salv   bigint;
  v_n      int;
  v_x      bigint;
  v_it     bigint;
  v_nc     bigint;
  k        int;
BEGIN
  SET LOCAL lock_timeout = '5s';

  CREATE FUNCTION pg_temp.como(p_sql text)
  RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000004e7', 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN 'ERROR: ' || SQLERRM;
  END
  $f$;

  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text)
  RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;

  -- Lo que la RPC tiene que contestar: el mensaje esperado (o un id, con '#id').
  CREATE FUNCTION pg_temp.espera(p_que text, p_sql text, p_msg text)
  RETURNS text[] LANGUAGE plpgsql AS $f$
  DECLARE
    v text := pg_temp.como(p_sql);
  BEGIN
    IF p_msg = '#id' THEN
      RETURN pg_temp.chk(v ~ '^[0-9]+$', format('%s: esperaba un id y dio %s', p_que, v));
    END IF;
    RETURN pg_temp.chk(v = 'ERROR: ' || p_msg, format('%s: esperaba «%s» y dio «%s»', p_que, p_msg, v));
  END
  $f$;

  CREATE FUNCTION pg_temp.gasto(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)::text', p);
  $f$;

  CREATE FUNCTION pg_temp.emp(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)::text', p);
  $f$;

  CREATE FUNCTION pg_temp.rot(p_id text)
  RETURNS int LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::int FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     WHERE c->>'id' = p_id;
  $f$;

  -- ------------------------------------------------------------ armado ---
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id) VALUES ('ZZ C5 producto', 1000, 50, 700, v_s)
    RETURNING id INTO v_prod;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES ('ZZ C5', 'ZZ C5', 'x', v_s) RETURNING id INTO v_cli;
  INSERT INTO gasto_rubros (nombre, grupo, pide_litros_km) VALUES ('ZZ C5 combustible', 'vehiculos', true) RETURNING id INTO v_rubro;
  INSERT INTO gasto_rubros (nombre, grupo, pide_litros_km) VALUES ('ZZ C5 libreria', 'administracion', false) RETURNING id INTO v_lib;

  -- ------------------------------------------------------- G · 1562-b2 ---
  v_fallas := v_fallas || pg_temp.espera('G1 litros Infinity',
    pg_temp.gasto(jsonb_build_object('fecha', v_hoy, 'rubro_id', v_rubro, 'monto_total', 1000, 'comprobante', 'ticket',
                                     'origen_pago', 'oficina', 'litros', 'Infinity')),
    'Hay un dato del gasto con un formato inválido');
  v_fallas := v_fallas || pg_temp.espera('G2 litros fuera de la columna',
    pg_temp.gasto(jsonb_build_object('fecha', v_hoy, 'rubro_id', v_rubro, 'monto_total', 1000, 'comprobante', 'ticket',
                                     'origen_pago', 'oficina', 'litros', 123456789)),
    'Los litros no pueden pasar de 99.999.999,99');
  v_fallas := v_fallas || pg_temp.espera('G3 IVA -Infinity en una factura A',
    pg_temp.gasto(jsonb_build_object('fecha', v_hoy, 'rubro_id', v_lib, 'monto_total', 1210, 'comprobante', 'factura_a',
                                     'origen_pago', 'oficina', 'iva', '-Infinity')),
    'Hay un dato del gasto con un formato inválido');
  v_fallas := v_fallas || pg_temp.espera('G4 total Infinity',
    pg_temp.gasto(jsonb_build_object('fecha', v_hoy, 'rubro_id', v_lib, 'monto_total', 'Infinity', 'comprobante', 'ticket',
                                     'origen_pago', 'oficina')),
    'Hay un dato del gasto con un formato inválido');
  v_fallas := v_fallas || pg_temp.espera('G5 sigue andando: 38,5 litros',
    pg_temp.gasto(jsonb_build_object('fecha', v_hoy, 'rubro_id', v_rubro, 'monto_total', 1000, 'comprobante', 'ticket',
                                     'origen_pago', 'oficina', 'litros', 38.5)),
    '#id');
  v_fallas := v_fallas || pg_temp.espera('G6 sigue andando: 99.999.999,99 litros',
    pg_temp.gasto(jsonb_build_object('fecha', v_hoy, 'rubro_id', v_rubro, 'monto_total', 1000, 'comprobante', 'ticket',
                                     'origen_pago', 'oficina', 'litros', 99999999.99)),
    '#id');

  -- ------------------------------------------------------- E · 1597-b6 ---
  CREATE TEMP TABLE c5e (clave text PRIMARY KEY, v jsonb) ON COMMIT DROP;
  INSERT INTO c5e VALUES ('base', jsonb_build_object(
    'nombre', 'ZZ C5 empleado', 'puesto', 'deposito', 'sucursal_id', v_s, 'de_las_dos', false,
    'arreglo', jsonb_build_object('vigente_desde', v_hoy, 'sueldo', 1000, 'frecuencia', 'mensual', 'comisiona', false)));
  v_fallas := v_fallas || pg_temp.espera('E1 ingreso mañana',
    pg_temp.emp((SELECT v FROM c5e WHERE clave = 'base') || jsonb_build_object('fecha_ingreso', v_hoy + 1)),
    'La fecha de ingreso no puede ser futura');
  v_fallas := v_fallas || pg_temp.espera('E2 ingreso infinity',
    pg_temp.emp((SELECT v FROM c5e WHERE clave = 'base') || jsonb_build_object('fecha_ingreso', 'infinity')),
    'Hay un dato del empleado con un formato inválido');
  v_fallas := v_fallas || pg_temp.espera('E3 ingreso -infinity',
    pg_temp.emp((SELECT v FROM c5e WHERE clave = 'base') || jsonb_build_object('fecha_ingreso', '-infinity')),
    'Hay un dato del empleado con un formato inválido');
  v_txt := pg_temp.como(pg_temp.emp((SELECT v FROM c5e WHERE clave = 'base') || jsonb_build_object('fecha_ingreso', v_hoy)));
  v_fallas := v_fallas || pg_temp.chk(v_txt ~ '^[0-9]+$', format('E4 ingreso hoy: esperaba un id y dio %s', v_txt));
  v_e := CASE WHEN v_txt ~ '^[0-9]+$' THEN v_txt::bigint END;
  IF v_e IS NOT NULL THEN
    -- Una ficha que ya tiene una fecha futura (anterior a la regla) se sigue editando sin tocarla, y no
    -- se le pone otra futura.
    UPDATE empleados SET fecha_ingreso = v_hoy + 10 WHERE id = v_e;
    v_fallas := v_fallas || pg_temp.espera('E5 edición sin tocar la fecha futura que ya tenía',
      pg_temp.emp(jsonb_build_object('id', v_e, 'nombre', 'ZZ C5 empleado editado', 'puesto', 'deposito',
                                     'fecha_ingreso', v_hoy + 10)),
      '#id');
    v_fallas := v_fallas || pg_temp.espera('E6 edición a otra fecha futura',
      pg_temp.emp(jsonb_build_object('id', v_e, 'nombre', 'ZZ C5 empleado editado', 'puesto', 'deposito',
                                     'fecha_ingreso', v_hoy + 11)),
      'La fecha de ingreso no puede ser futura');
    v_fallas := v_fallas || pg_temp.espera('E7 edición a una fecha pasada',
      pg_temp.emp(jsonb_build_object('id', v_e, 'nombre', 'ZZ C5 empleado editado', 'puesto', 'deposito',
                                     'fecha_ingreso', v_hoy - 400)),
      '#id');
  END IF;

  -- ---------------------------------------------------------- L · SEG-6 ---
  -- En la 530 eran 29 (gastos, personal, liquidaciones y cuatro triggers de updated_at).
  SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND position(E'\r' IN prosrc) > 0;
  v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('L1 quedan %s funciones de public con CRLF', v_n));
  -- SEG-C las cuenta, y se pone en rojo con una nueva.
  IF pg_temp.rot('SEG-C') IS NULL THEN
    v_fallas := v_fallas || 'L4 auditoria_integridad() no tiene el check SEG-C'::text;
  ELSE
    EXECUTE format('CREATE FUNCTION public.zz_c5_crlf() RETURNS int LANGUAGE sql AS %L', E'SELECT 1\r\n');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('SEG-C') = 1, format('L4 SEG-C con una función en CRLF da %s', pg_temp.rot('SEG-C')));
    DROP FUNCTION public.zz_c5_crlf();
  END IF;
  v_txt := pg_temp.como('SELECT jsonb_typeof(public.listar_personal())');
  v_fallas := v_fallas || pg_temp.chk(v_txt IN ('array', 'object'), format('L2 listar_personal dio %s', v_txt));
  v_txt := pg_temp.como(format('SELECT jsonb_typeof(to_jsonb(public.calcular_comisiones(%L::date, %L::date, ARRAY[1]::bigint[])))',
                               v_hoy - 30, v_hoy));
  v_fallas := v_fallas || pg_temp.chk(v_txt NOT LIKE 'ERROR%', format('L3 calcular_comisiones dio %s', v_txt));

  -- --------------------------------------------------------- R · 1332-f ---
  v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-A') IS NOT NULL AND pg_temp.rot('ROT-B') IS NOT NULL
                                       AND pg_temp.rot('ROT-C') IS NOT NULL,
                                       'R0 auditoria_integridad() no tiene los checks ROT-A, ROT-B y ROT-C');
  IF pg_temp.rot('ROT-A') IS NOT NULL AND v_e IS NOT NULL THEN
    v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-A') = 0 AND pg_temp.rot('ROT-B') = 0 AND pg_temp.rot('ROT-C') = 0,
                                        'R1 los checks ROT-* no arrancan en 0');
    -- El camino de la app: una baja de stock con cargo a un empleado.
    v_txt := pg_temp.como(format('SELECT public.registrar_merma_manual(p_producto_id => %s, p_cantidad => 2, p_motivo => %L, '
                                 'p_observaciones => %L, p_sucursal_id => %s, p_cargos => %L::jsonb)::text',
                                 v_prod, 'rotura', 'ensayo C5', v_s, jsonb_build_array(jsonb_build_object('empleado_id', v_e, 'monto', 1400))));
    SELECT id, merma_id INTO v_rot, v_merma FROM empleado_movimientos WHERE empleado_id = v_e AND tipo = 'rotura';
    v_fallas := v_fallas || pg_temp.chk(v_rot IS NOT NULL, format('R2 la baja de stock no cargó la rotura: %s', v_txt));
    IF v_rot IS NOT NULL THEN
      v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-A') = 0 AND pg_temp.rot('ROT-C') = 0,
                                          'R3 una rotura de la app pone ROT-A o ROT-C en rojo');
      -- Merma anulada con la rotura viva.
      UPDATE mermas_stock SET anulada_at = now() WHERE id = v_merma;
      v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-A') = 1, format('R4 merma anulada con rotura viva: ROT-A %s', pg_temp.rot('ROT-A')));
      UPDATE mermas_stock SET anulada_at = NULL WHERE id = v_merma;
      -- Una compensación que no es su espejo.
      INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, merma_id)
      VALUES (v_e, v_hoy, 'rotura', 1000, 'ZZ C5 mal', v_rot, v_merma) RETURNING id INTO v_comp;
      v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-C') = 1 AND pg_temp.rot('ROT-A') = 0,
                                          format('R5 compensación con otro monto: ROT-C %s, ROT-A %s', pg_temp.rot('ROT-C'), pg_temp.rot('ROT-A')));
      DELETE FROM empleado_movimientos WHERE id = v_comp;
      -- La reversión de la app (revertir_movimiento_empleado) es su espejo.
      v_txt := pg_temp.como(format('SELECT public.revertir_movimiento_empleado(%s, %L)::text', v_rot, 'ensayo C5'));
      v_fallas := v_fallas || pg_temp.chk(v_txt ~ '^[0-9]+$' AND pg_temp.rot('ROT-A') = 0 AND pg_temp.rot('ROT-C') = 0,
                                          format('R6 revertir desde la cuenta: %s, ROT-A %s, ROT-C %s', v_txt, pg_temp.rot('ROT-A'), pg_temp.rot('ROT-C')));
    END IF;
    -- Una salvedad «A cargo de empleados» sin rotura, y después con una rotura viva y anulada.
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura, retiro_deposito, fecha_entrega)
      VALUES (v_cli, v_s, v_adm, 2000, 'entregado', v_hoy, 'app', 'ZZ', true, now()) RETURNING id INTO v_ped;
    INSERT INTO salvedades_items (pedido_id, producto_id, cantidad_original, cantidad_afectada, motivo, monto_afectado,
                                  precio_unitario, reportado_por, sucursal_id, estado_resolucion)
      VALUES (v_ped, v_prod, 2, 1, 'producto_danado', 1000, 1000, v_adm, v_s, 'descuento_transportista') RETURNING id INTO v_salv;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-B') = 1, format('R7 salvedad a cargo sin rotura: ROT-B %s', pg_temp.rot('ROT-B')));
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, salvedad_id)
    VALUES (v_e, v_hoy, 'rotura', -700, 'ZZ C5', v_salv) RETURNING id INTO v_x;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-B') = 0 AND pg_temp.rot('ROT-A') = 0,
                                        format('R8 con su rotura: ROT-B %s, ROT-A %s', pg_temp.rot('ROT-B'), pg_temp.rot('ROT-A')));
    UPDATE salvedades_items SET estado_resolucion = 'anulada' WHERE id = v_salv;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-A') = 1 AND pg_temp.rot('ROT-B') = 0,
                                        format('R9 salvedad anulada con la rotura viva: ROT-A %s, ROT-B %s', pg_temp.rot('ROT-A'), pg_temp.rot('ROT-B')));
    -- Una compensación de una compensación.
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, salvedad_id)
    VALUES (v_e, v_hoy, 'rotura', 700, 'ZZ C5 comp', v_x, v_salv) RETURNING id INTO v_comp;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-A') = 0 AND pg_temp.rot('ROT-C') = 0,
                                        format('R10 la salvedad anulada con su rotura compensada: ROT-A %s, ROT-C %s', pg_temp.rot('ROT-A'), pg_temp.rot('ROT-C')));
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, salvedad_id)
    VALUES (v_e, v_hoy, 'rotura', -700, 'ZZ C5 comp de comp', v_comp, v_salv);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.rot('ROT-C') = 1, format('R11 compensación de una compensación: ROT-C %s', pg_temp.rot('ROT-C')));
  END IF;

  -- ------------------------------------------- F · auditoria_fechas_utc() ---
  -- El día del servidor se arma pegado: así este ensayo no lo nombra (ensayosDiaArgentino.contract.test.ts).
  EXECUTE format($q$CREATE FUNCTION public.zz_c5_fecha_tras_literal() RETURNS date LANGUAGE sql AS
    $f$ SELECT CASE WHEN '--' = 'x' THEN NULL ELSE %s END $f$$q$, 'CURRENT' || '_DATE');
  EXECUTE format($q$CREATE FUNCTION public.zz_c5_fecha_en_literal() RETURNS text LANGUAGE sql AS
    $f$ SELECT '%s no es código' $f$$q$, 'CURRENT' || '_DATE');
  v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_fechas_utc()->'funciones') f
                                               WHERE f->>'nombre' = 'zz_c5_fecha_tras_literal'),
                                      'F1 auditoria_fechas_utc no ve el día del servidor que sigue a un literal con dos guiones');
  v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_fechas_utc()->'funciones') f
                                                   WHERE f->>'nombre' = 'zz_c5_fecha_en_literal'),
                                      'F2 auditoria_fechas_utc ve el día del servidor dentro de un literal');
  -- H1 de la revisión: una cadena E'…' con \' no cierra en la comilla escapada.
  EXECUTE format($q$CREATE FUNCTION public.zz_c5_fecha_tras_e() RETURNS date LANGUAGE sql AS
    $f$ SELECT CASE WHEN E'it\'s -- ' = 'x' THEN NULL ELSE %s END $f$$q$, 'now()' || '::date');
  v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_fechas_utc()->'funciones') f
                                               WHERE f->>'nombre' = 'zz_c5_fecha_tras_e'),
                                      $m$F3 auditoria_fechas_utc no ve el día del servidor que sigue a E'it\'s -- '$m$);
  v_txt := public._sql_sin_comentarios_ni_literales($x$a := E'it\'s'; b := 'x'$x$);
  v_fallas := v_fallas || pg_temp.chk(v_txt = $x$a := ''; b := ''$x$, format('F4 el lector deja %s', v_txt));

  -- --------------------------------------------- V · las mismas filas ---
  -- Datos: boletas entregadas ZZ y FC, una VB, una del bot y una pendiente (un canje no se puede entregar a mano);
  -- un cliente con zona y otro sin; notas por unidades, por monto (sin línea), anulada, y sobre las
  -- boletas que no son venta.
  INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZZ C5 zona', v_s) RETURNING id INTO v_zona;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id) VALUES ('ZZ C5 b', 'ZZ C5 b', 'x', v_s, v_zona)
    RETURNING id INTO v_cli2;
  FOR k IN 1..6 LOOP
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura, retiro_deposito, fecha_entrega)
      VALUES (CASE WHEN k % 2 = 0 THEN v_cli ELSE v_cli2 END, v_s, v_adm, 3000,
              CASE WHEN k = 5 THEN 'pendiente' ELSE 'entregado' END, v_hoy,
              CASE WHEN k = 4 THEN 'bot' ELSE 'app' END,
              CASE k WHEN 2 THEN 'FC' WHEN 3 THEN 'VB' ELSE 'ZZ' END, true, CASE WHEN k <> 5 THEN now() END)
      RETURNING id INTO v_x;
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear,
                              neto_unitario)
      VALUES (v_x, v_prod, 3, 1000, 3000, v_s, 700,
              CASE WHEN k = 2 THEN 826.45 END)
      RETURNING id INTO v_it;
    INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
      VALUES (v_s, CASE WHEN k % 2 = 0 THEN v_cli ELSE v_cli2 END, v_x, v_hoy, 'cliente_rechaza', 1000, v_adm,
              CASE WHEN k = 2 THEN 826.45 ELSE 1000 END, CASE WHEN k = 2 THEN 173.55 ELSE 0 END)
      RETURNING id INTO v_nc;
    INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad, precio_unitario, subtotal)
      VALUES (v_nc, v_s, v_it, (SELECT producto_id FROM pedido_items WHERE id = v_it), 1, 1000, 1000);
    IF k = 1 THEN
      -- Otra nota, por monto y sin línea, y una anulada.
      INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
        VALUES (v_s, v_cli2, v_x, v_hoy, 'descuento_comercial', 500, v_adm, 500, 0) RETURNING id INTO v_nc;
      INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad, precio_unitario, subtotal)
        VALUES (v_nc, v_s, NULL, (SELECT producto_id FROM pedido_items WHERE id = v_it), 0, 0, 500);
      INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
        VALUES (v_s, v_cli2, v_x, v_hoy, 'otro', 300, v_adm, 300, 0) RETURNING id INTO v_nc;
      INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad, precio_unitario, subtotal)
        VALUES (v_nc, v_s, v_it, (SELECT producto_id FROM pedido_items WHERE id = v_it), 0, 0, 300);
      UPDATE notas_credito_venta SET anulada = true, anulada_at = now() WHERE id = v_nc;
    END IF;
  END LOOP;

  -- Los cuerpos de la 530, tal cual.
  SELECT count(*) INTO v_n FROM (
    (SELECT * FROM public._tablero_ventas(ARRAY[1, 2]::bigint[], v_hoy - 400, v_hoy)
     EXCEPT ALL
     SELECT pe.id, pe.cliente_id, pe.fecha, GREATEST(pe.total - pe.cargo_envio, 0), pe.sucursal_id, c.zona_id
       FROM pedidos pe LEFT JOIN clientes c ON c.id = pe.cliente_id
      WHERE pe.estado = 'entregado' AND COALESCE(pe.canal, 'app') <> 'cambio' AND pe.tipo_factura IS DISTINCT FROM 'VB'
        AND pe.fecha BETWEEN v_hoy - 400 AND v_hoy AND pe.sucursal_id = ANY(ARRAY[1, 2]::bigint[]))
    UNION ALL
    (SELECT pe.id, pe.cliente_id, pe.fecha, GREATEST(pe.total - pe.cargo_envio, 0), pe.sucursal_id, c.zona_id
       FROM pedidos pe LEFT JOIN clientes c ON c.id = pe.cliente_id
      WHERE pe.estado = 'entregado' AND COALESCE(pe.canal, 'app') <> 'cambio' AND pe.tipo_factura IS DISTINCT FROM 'VB'
        AND pe.fecha BETWEEN v_hoy - 400 AND v_hoy AND pe.sucursal_id = ANY(ARRAY[1, 2]::bigint[])
     EXCEPT ALL
     SELECT * FROM public._tablero_ventas(ARRAY[1, 2]::bigint[], v_hoy - 400, v_hoy))) d;
  v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('V1 _tablero_ventas difiere del cuerpo de la 530 en %s filas', v_n));
  v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM public._tablero_ventas(ARRAY[1]::bigint[], v_hoy, v_hoy)) >= 4,
                                      'V2 _tablero_ventas no trae las boletas del ensayo');

  CREATE TEMP TABLE c5_nc_530 ON COMMIT DROP AS
  SELECT n.id, n.fecha, n.sucursal_id, n.pedido_id, n.cliente_id, c.zona_id, pe.usuario_id,
         COALESCE(pe.tipo_factura, 'ZZ')::text AS tipo_factura, i.pedido_item_id, i.producto_id, i.cantidad,
         i.subtotal,
         i.subtotal * n.iva / n.total AS iva,
         CASE WHEN pi.id IS NOT NULL AND i.subtotal = i.cantidad * pi.precio_unitario
              THEN i.cantidad * COALESCE(pi.ingreso_real_unitario,
                                         CASE WHEN pe.tipo_factura = 'FC'
                                              THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                              ELSE pi.precio_unitario END)
              WHEN pi.id IS NOT NULL AND pi.precio_unitario > 0
              THEN i.subtotal
                   - round(i.subtotal * (pi.precio_unitario
                                         - COALESCE(pi.ingreso_real_unitario,
                                                    CASE WHEN pe.tipo_factura = 'FC'
                                                         THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                                         ELSE pi.precio_unitario END))
                           / pi.precio_unitario, 2)
              ELSE i.subtotal * CASE WHEN pe.tipo_factura = 'FC' THEN n.neto ELSE n.total END / n.total
         END AS ingreso_real,
         pi.costo_unitario_al_crear,
         CASE WHEN i.lotes_devueltos IS NOT NULL OR i.merma_id IS NOT NULL THEN i.cantidad ELSE 0 END AS cant_merc
    FROM notas_credito_venta n
    JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
    JOIN pedidos pe ON pe.id = n.pedido_id
    LEFT JOIN pedido_items pi ON pi.id = i.pedido_item_id
    LEFT JOIN clientes c ON c.id = n.cliente_id
   WHERE NOT n.anulada AND n.total > 0 AND n.sucursal_id = ANY(ARRAY[1, 2]::bigint[])
     AND n.fecha BETWEEN v_hoy - 400 AND v_hoy AND pe.estado = 'entregado'
     AND COALESCE(pe.canal, 'app') <> 'cambio' AND pe.tipo_factura IS DISTINCT FROM 'VB';
  SELECT count(*) INTO v_n FROM (
    (SELECT * FROM public._ventas_nc(ARRAY[1, 2]::bigint[], v_hoy - 400, v_hoy) EXCEPT ALL SELECT * FROM c5_nc_530)
    UNION ALL
    (SELECT * FROM c5_nc_530 EXCEPT ALL SELECT * FROM public._ventas_nc(ARRAY[1, 2]::bigint[], v_hoy - 400, v_hoy))) d;
  v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('V3 _ventas_nc difiere del cuerpo de la 530 en %s filas', v_n));
  v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM public._ventas_nc(ARRAY[1]::bigint[], v_hoy, v_hoy)) >= 3,
                                      'V4 _ventas_nc no trae las notas del ensayo');

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · % · %', cardinality(v_fallas), array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · C5: gastos con infinitos y litros fuera de la columna (G1-G6); fecha de ingreso (E1-E7); SEG-6 sin CRLF y SEG-C (L1-L4); ROT-A, ROT-B y ROT-C (R0-R11); auditoria_fechas_utc y el lector con literales y E-strings (F1-F4); _tablero_ventas y _ventas_nc con las mismas filas (V1-V4)';
END
$ensayo$;
