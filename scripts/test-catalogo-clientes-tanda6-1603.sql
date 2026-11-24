-- Ensayo de la tarjeta C de la tanda 6 del plan #1603 (reauditoría del núcleo del 24/11): permisos,
-- catálogo y clientes. Migración: NNN_catalogo_clientes_tanda6.
--
--   S1 · SEG-1        el preventista lee los descuentos por rubro sólo de los clientes que ve
--                     (`_cliente_visible`, por la RLS de clientes): no los de otro preventista ni los
--                     reservados a administración. El libre, el suyo y el que le vendió, sí; el admin y el
--                     encargado leen todos; el chofer y el depósito, ninguno (regresión).
--   S2 · catalogo-B1  un CUIT nuevo o cambiado tiene que tener 11 dígitos y el verificador bien (D37 de
--                     #1561), por guardar_cliente y por REST. Uno que ya estaba mal no traba la edición
--                     del cliente mientras no se toque (regresión); el DNI y el null no cambian (regresión).
--                     Sin ningún dígito ('', espacios, guiones) queda sin documento (NULL), por la RPC y
--                     por REST (H3 de la revisión); 'abc' se sigue rechazando.
--   S3 · catalogo-B2  la latitud va de -90 a 90 y la longitud de -180 a 180 (como pedidos y visitas).
--   S4 · catalogo-B3  actualizar_precios_masivo redondea al centavo antes de mirar que el precio sea > 0:
--                     0,004 se rechaza en vez de dejar el producto en $ 0,00.
--   S5 · catalogo-B5  por REST el precio neto no pasa al final y el nombre tiene hasta 200 caracteres; el
--                     stock mínimo vacío sigue valiendo (CAT-13: vacío es 10) (regresión).
--   S6 · catalogo-B9  el alta (y la edición que cambia la dirección o el punto) de guardar_cliente toma el
--                     lock de los duplicados de la sucursal antes de buscar el duplicado: dos altas a la vez
--                     se serializan. La carrera de verdad, con dos sesiones, está en
--                     scripts/concurrencia/t6c-alta-cliente-duplicada.sh.
--   S7 · catalogo-B10 el nombre de una marca es único por sucursal sin mirar mayúsculas ni los espacios de
--                     los bordes; en otra sucursal se repite (regresión).
--   S8 · catalogo-B11 un alta de 100 productos sin precio en una operación deja UN aviso por destinatario,
--                     con la cantidad; el alta de uno solo y el precio que pasa a 0 avisan como siempre
--                     (regresión).
--   S9 · permisos-B3  promo_ajustes y control_stock_sesiones las leen sólo el admin, el encargado y el
--                     depósito de la sucursal (decisión del dueño del 24/11); el preventista, el chofer y
--                     el depósito desactivado, no; en otra sucursal, nadie (regresión).
--   S10 · permisos-B5 un admin de las dos sucursales parado en la 1 no anula un gasto de la 2 (decisión
--                     del dueño del 24/11: toda rama admin mira la sucursal); parado en la 2, sí
--                     (regresión). El compartido sigue con su regla: lo anula quien lo cargó o un admin
--                     de todas, desde cualquier sucursal (regresión). Cancelar un envío de la 2 parado en
--                     la 1 ya se rechazaba (regresión: no hacía falta).
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo valores de
-- secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Cada caso corre como un usuario
-- (SET LOCAL ROLE authenticated + request.jwt.claims + el header de la sucursal). Datos inventados.
-- Sin la migración fallan todos los casos menos los que dicen «regresión».
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-catalogo-clientes-tanda6-1603.sql

DO $ensayo$
DECLARE
  v_adm    uuid;
  v_enc    uuid;
  v_pre    uuid;
  v_preb   uuid;
  v_tra    uuid;
  v_dep    uuid;
  c_libre  bigint;
  c_ajeno  bigint;
  c_res    bigint;
  c_vend   bigint;
  c_malo   bigint;
  v_p      bigint;
  v_p2     bigint;
  v_r      text;
  v_t      text;
  v_n      int;
  v_n2     int;
  v_dest   int;
  v_ver    timestamptz;
  v_adm12  uuid;
  v_depoff uuid;
  v_rubro  bigint;
  v_g      bigint;
  v_promo  bigint;
  v_mov    bigint;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6c-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'T6C ' || p_rol), now(), now());
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
  -- Corre p_sql como p_uid (authenticated) parado en p_suc; devuelve 'PASA <valor>' o 'SQLSTATE mensaje'.
  -- Los triggers diferidos se disparan antes de volver (como el COMMIT).
  CREATE FUNCTION pg_temp.intenta(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text; x text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql INTO x;
      SET CONSTRAINTS ALL IMMEDIATE;
      SET CONSTRAINTS ALL DEFERRED;
      r := 'PASA ' || COALESCE(x, '');
    EXCEPTION WHEN OTHERS THEN
      r := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  -- guardar_cliente (alta) como el admin, con los campos de p_extra.
  CREATE FUNCTION pg_temp.alta(p_uid uuid, p_dir text, p_extra text) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_uid, 1, format(
      $q$SELECT public.guardar_cliente(jsonb_build_object('clave', gen_random_uuid(), 'campos',
           '{"razon_social":"T6C %1$s","nombre_fantasia":"T6C %1$s","direccion":"%1$s"%2$s}'::jsonb))->'cliente'->>'id'$q$,
      p_dir, CASE WHEN p_extra = '' THEN '' ELSE ', ' || p_extra END));
  $f$;
  -- guardar_cliente (edición) como p_uid.
  CREATE FUNCTION pg_temp.edita(p_uid uuid, p_id bigint, p_campos text) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_uid, 1, format(
      $q$SELECT public.guardar_cliente(jsonb_build_object('id', %s, 'campos', '{%s}'::jsonb))->'cliente'->>'cuit'$q$,
      p_id, p_campos));
  $f$;

  -- --------------------------------------------------------------- fixtures -
  v_adm  := pg_temp.u('admin', 1);
  v_enc  := pg_temp.u('encargado', 1);
  v_pre  := pg_temp.u('preventista', 1);
  v_preb := pg_temp.u('preventista', 1);
  v_tra  := pg_temp.u('transportista', 1);
  v_dep  := pg_temp.u('deposito', 1);

  -- ------------------------------------------------------------------ S1 · SEG-1 -
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('T6C libre', 'T6C libre', 'T6C Calle Libre 1', 1) RETURNING id INTO c_libre;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('T6C ajeno', 'T6C ajeno', 'T6C Calle Ajena 2', 1) RETURNING id INTO c_ajeno;
  INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (c_ajeno, v_preb);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, reservado_admin)
  VALUES ('T6C reservado', 'T6C reservado', 'T6C Calle Reservada 3', 1, true) RETURNING id INTO c_res;
  -- Asignado a prevB, pero v_pre le vendió (historial, 358): lo ve y ve sus descuentos.
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('T6C vendido', 'T6C vendido', 'T6C Calle Vendida 4', 1) RETURNING id INTO c_vend;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura)
  VALUES (c_vend, 1, v_pre, 0, 'pendiente', public._tablero_hoy(), 'app', 'ZZ');
  INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (c_vend, v_preb);
  INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
  SELECT c, 'T6C rubro', 33 FROM unnest(ARRAY[c_libre, c_ajeno, c_res, c_vend]) c;

  FOR v_t IN
    SELECT format('%s ve los descuentos de %s: %s (esperado %s)', quien, de, s.visto, esperado) FROM (VALUES
        ('el preventista', v_pre,  'otro preventista', c_ajeno, '0'),
        ('el preventista', v_pre,  'un reservado',     c_res,   '0'),
        ('el preventista', v_pre,  'un libre (regresión)', c_libre, '1'),
        ('el preventista', v_pre,  'uno al que le vendió (regresión)', c_vend, '1'),
        ('el otro preventista', v_preb, 'el suyo (regresión)', c_ajeno, '1'),
        ('el otro preventista', v_preb, 'un reservado', c_res, '0'),
        ('el admin',     v_adm, 'un reservado (regresión)', c_res, '1'),
        ('el admin',     v_adm, 'uno asignado (regresión)', c_ajeno, '1'),
        ('el encargado', v_enc, 'un reservado (regresión)', c_res, '1'),
        ('el encargado', v_enc, 'uno asignado (regresión)', c_ajeno, '1'),
        ('el chofer',    v_tra, 'un libre (regresión)', c_libre, '0'),
        ('el depósito',  v_dep, 'un libre (regresión)', c_libre, '0')
      ) AS t(quien, u, de, cli, esperado),
      LATERAL (SELECT pg_temp.intenta(u, 1, format(
        'SELECT count(*)::text FROM cliente_descuentos_categoria WHERE cliente_id = %s', cli)) AS visto) s
     WHERE s.visto IS DISTINCT FROM 'PASA ' || esperado
  LOOP
    v_fallas := v_fallas || ('S1 · ' || v_t);
  END LOOP;
  -- El embed del front (clientes con sus descuentos): el preventista ve los de sus clientes (regresión).
  v_r := pg_temp.intenta(v_pre, 1, format(
    'SELECT count(*)::text FROM clientes c JOIN cliente_descuentos_categoria d ON d.cliente_id = c.id WHERE c.id IN (%s, %s, %s, %s)',
    c_libre, c_ajeno, c_res, c_vend));
  IF v_r IS DISTINCT FROM 'PASA 2' THEN
    v_fallas := v_fallas || ('S1 · el embed de clientes con sus descuentos, como el preventista: ' || v_r || ' (esperado 2)');
  END IF;

  -- -------------------------------------------------------------- S6 · catalogo-B9 -
  -- Va antes que S2: es el primer guardar_cliente del ensayo (un lock ya tomado no suma fila en pg_locks).
  -- Después del alta (y de la edición que mueve la dirección), quien guardó tiene tomado el lock de los
  -- duplicados de la sucursal hasta el COMMIT: otra alta de la misma sucursal espera y después ve la suya.
  SELECT count(*) INTO v_n FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid();
  v_r := pg_temp.alta(v_pre, 'T6C Lock 1', '');
  SELECT count(*) INTO v_n2 FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid();
  IF v_r NOT LIKE 'PASA %' OR v_n2 <= v_n THEN
    v_fallas := v_fallas || format('S6 · el alta no tomó el lock de los duplicados (locks %s -> %s): %s', v_n, v_n2, v_r);
  END IF;
  -- La misma dirección, otra vez (regresión: el duplicado sigue frenando).
  v_r := pg_temp.alta(v_pre, 'T6C Lock 1', '');
  IF v_r NOT LIKE '23505%' THEN
    v_fallas := v_fallas || ('S6 · la misma dirección otra vez (regresión): ' || v_r || ' (esperado 23505)');
  END IF;

  -- -------------------------------------------------------------- S2 · catalogo-B1 -
  -- 20-12345678-6 es válido (suma 148, resto 5, verificador 6).
  FOR v_t IN
    SELECT format('alta con cuit %s: %s (esperado %s)', cuit, s.visto, esperado) FROM (VALUES
        ('"20-12345678-0"', 'T6C Doc 1', '22023'),
        ('"20-12345678-9"', 'T6C Doc 2', '22023'),
        ('"abc"',           'T6C Doc 3', '22023'),
        ('"20-1234567-6"',  'T6C Doc 4', '22023'),
        ('"20-12345678-6"', 'T6C Doc 5', 'PASA'),
        ('"20123456786"',   'T6C Doc 6', 'PASA'),
        ('"00-12345678-0"', 'T6C Doc 7', 'PASA'),
        ('null',            'T6C Doc 8', 'PASA')
      ) AS t(cuit, dir, esperado),
      LATERAL (SELECT pg_temp.alta(v_adm, dir, '"cuit": ' || cuit) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || ('S2 · ' || v_t);
  END LOOP;
  -- El mensaje del verificador malo dice qué pasa.
  v_r := pg_temp.alta(v_adm, 'T6C Doc 9', '"cuit": "27-12345678-1"');
  IF v_r NOT LIKE '22023 %dígito verificador%' THEN
    v_fallas := v_fallas || ('S2 · el rechazo del verificador malo no lo dice: ' || v_r);
  END IF;
  -- H3 de la revisión: vacío o sólo espacios y guiones queda sin documento (antes se guardaba '' como CUIT).
  -- La lectura va en otra sentencia: una consulta que llama al alta ve la foto de antes de la llamada.
  FOREACH v_t IN ARRAY ARRAY['""', '"   "', '" - "'] LOOP
    v_r := pg_temp.alta(v_adm, 'T6C Doc vacío ' || left(md5(v_t), 8), '"cuit": ' || v_t);
    IF v_r NOT LIKE 'PASA %' THEN
      v_fallas := v_fallas || format('S2 · alta con cuit %s: %s (esperado sin documento)', v_t, v_r);
    ELSIF (SELECT c.cuit FROM clientes c WHERE c.id = substr(v_r, 6)::bigint) IS NOT NULL THEN
      v_fallas := v_fallas || format('S2 · alta con cuit %s: guardó %s (esperado sin documento)', v_t,
                                     (SELECT quote_literal(c.cuit) FROM clientes c WHERE c.id = substr(v_r, 6)::bigint));
    END IF;
  END LOOP;
  v_r := pg_temp.intenta(v_adm, 1, format($q$UPDATE clientes SET cuit = '' WHERE id = %s RETURNING COALESCE(cuit, 'NULL')$q$, c_ajeno));
  IF v_r IS DISTINCT FROM 'PASA NULL' THEN
    v_fallas := v_fallas || ('S2 · el CUIT vacío por REST: ' || v_r || ' (esperado sin documento)');
  END IF;
  -- Por REST, igual que por la RPC.
  v_r := pg_temp.intenta(v_adm, 1,
    $q$INSERT INTO clientes (razon_social, nombre_fantasia, direccion, cuit, sucursal_id) VALUES ('T6C R', 'T6C R', 'T6C Doc 10', '20-12345678-0', 1) RETURNING id::text$q$);
  IF v_r NOT LIKE '22023%' THEN
    v_fallas := v_fallas || ('S2 · un alta por REST con el verificador malo: ' || v_r || ' (esperado 22023)');
  END IF;
  -- Un cliente que ya tiene el CUIT mal (de antes de la regla): se arma con el trigger apagado.
  ALTER TABLE public.clientes DISABLE TRIGGER trg_clientes_tipo_documento_del_valor;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, cuit, tipo_documento, sucursal_id)
  VALUES ('T6C malo', 'T6C malo', 'T6C Doc Viejo 11', '20-12345678-0', 'CUIT', 1) RETURNING id INTO c_malo;
  ALTER TABLE public.clientes ENABLE TRIGGER trg_clientes_tipo_documento_del_valor;
  FOR v_t IN
    SELECT format('editar el cliente con el CUIT viejo mal (%s): %s (esperado %s)', que, s.visto, esperado) FROM (VALUES
        ('otro dato, el CUIT igual (regresión)', '"razon_social": "T6C malo bis", "cuit": "20-12345678-0"', 'PASA 20-12345678-0'),
        ('otro dato, el CUIT igual sin guiones (regresión)', '"notas": "T6C", "cuit": "20123456780"', 'PASA 20123456780'),
        ('el CUIT por otro malo', '"cuit": "20-12345679-0"', '22023'),
        ('el CUIT por uno bueno (regresión)', '"cuit": "20-12345678-6"', 'PASA 20-12345678-6')
      ) AS t(que, campos, esperado),
      LATERAL (SELECT pg_temp.edita(v_adm, c_malo, campos) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || ('S2 · ' || v_t);
  END LOOP;
  v_r := pg_temp.intenta(v_adm, 1, format(
    $q$UPDATE clientes SET cuit = '30-11111111-0' WHERE id = %s RETURNING cuit$q$, c_libre));
  IF v_r NOT LIKE '22023%' THEN
    v_fallas := v_fallas || ('S2 · cambiar el CUIT a uno malo por REST: ' || v_r || ' (esperado 22023)');
  END IF;

  -- -------------------------------------------------------------- S3 · catalogo-B2 -
  FOR v_t IN
    SELECT format('alta con %s: %s (esperado %s)', campo, s.visto, esperado) FROM (VALUES
        ('"latitud": 91',          'T6C Geo 1', '23514'),
        ('"latitud": -90.0000001', 'T6C Geo 2', '23514'),
        ('"longitud": 181',        'T6C Geo 3', '23514'),
        ('"longitud": -180.5',     'T6C Geo 4', '23514'),
        ('"latitud": "NaN"',       'T6C Geo 5', '23514'),
        ('"latitud": -90, "longitud": 180', 'T6C Geo 6', 'PASA'),
        ('"latitud": -26.8241, "longitud": -65.2226', 'T6C Geo 7', 'PASA')
      ) AS t(campo, dir, esperado),
      LATERAL (SELECT pg_temp.alta(v_adm, dir, campo) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || ('S3 · ' || v_t);
  END LOOP;
  v_r := pg_temp.intenta(v_adm, 1, format('UPDATE clientes SET latitud = 95 WHERE id = %s RETURNING id::text', c_libre));
  IF v_r NOT LIKE '23514%' THEN
    v_fallas := v_fallas || ('S3 · una latitud de 95 por REST: ' || v_r || ' (esperado 23514)');
  END IF;

  -- -------------------------------------------------------------- S4 · catalogo-B3 -
  INSERT INTO productos (nombre, precio, precio_sin_iva, stock, sucursal_id)
  VALUES ('T6C masivo', 100, NULL, 5, 1) RETURNING id INTO v_p;
  INSERT INTO productos (nombre, precio, precio_sin_iva, stock, sucursal_id)
  VALUES ('T6C masivo 2', 100, NULL, 5, 1) RETURNING id INTO v_p2;
  v_r := pg_temp.intenta(v_adm, 1, format(
    $q$SELECT public.actualizar_precios_masivo(jsonb_build_array(jsonb_build_object('producto_id', %s, 'precio_final', 0.004)))::text$q$, v_p));
  IF (SELECT precio FROM productos WHERE id = v_p) IS DISTINCT FROM 100.00 OR v_r NOT LIKE '%mayor que 0%' THEN
    v_fallas := v_fallas || format('S4 · precio_final 0,004: el producto quedó en %s (esperado 100, rechazado): %s',
                                   (SELECT precio FROM productos WHERE id = v_p), v_r);
  END IF;
  v_r := pg_temp.intenta(v_adm, 1, format(
    $q$SELECT public.actualizar_precios_masivo(jsonb_build_array(jsonb_build_object('producto_id', %s, 'precio_final', 50, 'precio_neto', 0.004)))::text$q$, v_p));
  IF (SELECT (precio, precio_sin_iva) FROM productos WHERE id = v_p) IS DISTINCT FROM (100.00::numeric, NULL::numeric) THEN
    v_fallas := v_fallas || format('S4 · precio_neto 0,004: el producto quedó en %s (esperado 100 sin neto, rechazado): %s',
                                   (SELECT (precio, precio_sin_iva)::text FROM productos WHERE id = v_p), v_r);
  END IF;
  -- Regresión: un precio con más de dos decimales se guarda al centavo.
  v_r := pg_temp.intenta(v_adm, 1, format(
    $q$SELECT public.actualizar_precios_masivo(jsonb_build_array(jsonb_build_object('producto_id', %s, 'precio_final', 150.505, 'precio_neto', 124.384)))::text$q$, v_p2));
  IF (SELECT (precio, precio_sin_iva) FROM productos WHERE id = v_p2) IS DISTINCT FROM (150.51::numeric, 124.38::numeric) THEN
    v_fallas := v_fallas || format('S4 · 150,505 / 124,384 (regresión): quedó %s: %s',
                                   (SELECT (precio, precio_sin_iva)::text FROM productos WHERE id = v_p2), v_r);
  END IF;

  -- -------------------------------------------------------------- S5 · catalogo-B5 -
  FOR v_t IN
    SELECT format('%s: %s (esperado %s)', que, s.visto, esperado) FROM (VALUES
        ('alta con el neto mayor que el final',
         $q$INSERT INTO productos (nombre, precio, precio_sin_iva, sucursal_id) VALUES ('T6C neto', 10, 500, 1) RETURNING id::text$q$, '23514'),
        ('bajar el final por debajo del neto',
         format($q$UPDATE productos SET precio = 50 WHERE id = %s RETURNING id::text$q$, v_p2), '23514'),
        ('alta con un nombre de 201 caracteres',
         format($q$INSERT INTO productos (nombre, precio, sucursal_id) VALUES (%L, 10, 1) RETURNING id::text$q$, repeat('n', 201)), '23514'),
        ('alta con un nombre de 200 caracteres (regresión)',
         format($q$INSERT INTO productos (nombre, precio, sucursal_id) VALUES (%L, 10, 1) RETURNING id::text$q$, repeat('m', 200)), 'PASA'),
        ('alta exenta con el neto igual al final (regresión)',
         $q$INSERT INTO productos (nombre, precio, precio_sin_iva, condicion_iva, porcentaje_iva, sucursal_id) VALUES ('T6C exento', 10, 10, 'exento', 0, 1) RETURNING id::text$q$, 'PASA'),
        ('alta gravada con el neto calculado (regresión)',
         $q$INSERT INTO productos (nombre, precio, precio_sin_iva, sucursal_id) VALUES ('T6C gravado', 121, 100, 1) RETURNING id::text$q$, 'PASA'),
        ('alta con el stock mínimo vacío (regresión, CAT-13)',
         $q$INSERT INTO productos (nombre, precio, stock_minimo, sucursal_id) VALUES ('T6C sin minimo', 10, NULL, 1) RETURNING id::text$q$, 'PASA')
      ) AS t(que, sql, esperado),
      LATERAL (SELECT pg_temp.intenta(v_adm, 1, sql) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || ('S5 · ' || v_t);
  END LOOP;

  -- ------------------------------------------------------------- S7 · catalogo-B10 -
  FOR v_t IN
    SELECT format('%s: %s (esperado %s)', que, s.visto, esperado) FROM (VALUES
        ('alta de «T6C Marca»', $q$INSERT INTO marcas (nombre, sucursal_id) VALUES ('T6C Marca', 1) RETURNING nombre$q$, 'PASA'),
        ('alta de «t6c marca»', $q$INSERT INTO marcas (nombre, sucursal_id) VALUES ('t6c marca', 1) RETURNING nombre$q$, '23505'),
        ('alta de « T6C MARCA »', $q$INSERT INTO marcas (nombre, sucursal_id) VALUES (' T6C MARCA ', 1) RETURNING nombre$q$, '23505'),
        ('alta de «T6C Otra»', $q$INSERT INTO marcas (nombre, sucursal_id) VALUES ('T6C Otra', 1) RETURNING nombre$q$, 'PASA'),
        ('renombrar «T6C Otra» a «T6C MARCA»', $q$UPDATE marcas SET nombre = 'T6C MARCA' WHERE nombre = 'T6C Otra' AND sucursal_id = 1 RETURNING nombre$q$, '23505'),
        ('renombrar «T6C Marca» a «T6C MARCA» (regresión: la misma)', $q$UPDATE marcas SET nombre = 'T6C MARCA' WHERE nombre = 'T6C Marca' AND sucursal_id = 1 RETURNING nombre$q$, 'PASA')
      ) AS t(que, sql, esperado),
      LATERAL (SELECT pg_temp.intenta(v_adm, 1, sql) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || ('S7 · ' || v_t);
  END LOOP;
  -- En otra sucursal el nombre se repite (regresión).
  BEGIN
    INSERT INTO marcas (nombre, sucursal_id) VALUES ('t6c marca', 2);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('S7 · la misma marca en la sucursal 2 (regresión): ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- ------------------------------------------------------------- S8 · catalogo-B11 -
  -- A quiénes avisa _notificar_sucursal_roles en la 1.
  SELECT count(DISTINCT us.usuario_id) INTO v_dest
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE us.sucursal_id = 1 AND p.rol IN ('admin', 'encargado') AND p.activo IS NOT FALSE;
  SELECT count(*) INTO v_n FROM notificaciones WHERE tipo = 'producto_sin_precio';
  v_r := pg_temp.intenta(v_adm, 1,
    $q$WITH x AS (INSERT INTO productos (nombre, precio, sucursal_id)
                  SELECT 'T6C sin precio ' || g, 0, 1 FROM generate_series(1, 100) g RETURNING id)
       SELECT count(*)::text FROM x$q$);
  SELECT count(*) INTO v_n2 FROM notificaciones WHERE tipo = 'producto_sin_precio';
  IF v_r IS DISTINCT FROM 'PASA 100' OR v_n2 - v_n IS DISTINCT FROM v_dest THEN
    v_fallas := v_fallas || format('S8 · 100 productos sin precio de una vez dejaron %s avisos (esperado %s, uno por destinatario): %s',
                                   v_n2 - v_n, v_dest, v_r);
  ELSIF NOT EXISTS (SELECT 1 FROM notificaciones WHERE tipo = 'producto_sin_precio' AND mensaje LIKE '100 productos%'
                       AND (payload->>'cantidad')::int = 100) THEN
    v_fallas := v_fallas || 'S8 · el aviso agrupado no dice que son 100 productos';
  END IF;
  -- Uno solo: el aviso de siempre, con el producto (regresión).
  v_n := v_n2;
  v_r := pg_temp.intenta(v_adm, 1,
    $q$INSERT INTO productos (nombre, precio, sucursal_id) VALUES ('T6C uno sin precio', 0, 1) RETURNING id::text$q$);
  SELECT count(*) INTO v_n2 FROM notificaciones
   WHERE tipo = 'producto_sin_precio' AND entidad_tipo = 'producto' AND entidad_id = substr(v_r, 6)::bigint
     AND mensaje = '«T6C uno sin precio» quedó sin precio de venta: no se puede vender hasta que lo cargues.';
  IF v_n2 IS DISTINCT FROM v_dest THEN
    v_fallas := v_fallas || format('S8 · el alta de uno sin precio (regresión): %s avisos con su producto (esperado %s): %s', v_n2, v_dest, v_r);
  END IF;
  -- Con precio, ninguno (regresión).
  SELECT count(*) INTO v_n FROM notificaciones WHERE tipo = 'producto_sin_precio';
  v_r := pg_temp.intenta(v_adm, 1,
    $q$INSERT INTO productos (nombre, precio, sucursal_id) SELECT 'T6C con precio ' || g, 10, 1 FROM generate_series(1, 3) g RETURNING id::text$q$);
  SELECT count(*) INTO v_n2 FROM notificaciones WHERE tipo = 'producto_sin_precio';
  IF v_n2 <> v_n THEN
    v_fallas := v_fallas || format('S8 · el alta de productos con precio avisó (regresión): %s avisos', v_n2 - v_n);
  END IF;
  -- El precio que pasa a 0 sigue avisando, uno por producto (regresión).
  v_r := pg_temp.intenta(v_adm, 1, format('UPDATE productos SET precio = 0, precio_sin_iva = NULL WHERE id = %s RETURNING id::text', v_p));
  SELECT count(*) INTO v_n2 FROM notificaciones WHERE tipo = 'producto_sin_precio' AND entidad_id = v_p;
  IF v_n2 IS DISTINCT FROM v_dest THEN
    v_fallas := v_fallas || format('S8 · el precio que pasa a 0 (regresión): %s avisos (esperado %s): %s', v_n2, v_dest, v_r);
  END IF;

  -- -------------------------------------------------------------- S9 · permisos-B3 -
  v_depoff := pg_temp.u('deposito', 1);
  -- El sync con auth.users (el ban) pide una columna que la base local no tiene: se apaga para esto.
  ALTER TABLE public.perfiles DISABLE TRIGGER trg_perfiles_sync_acceso_auth;
  UPDATE perfiles SET activo = false WHERE id = v_depoff;
  ALTER TABLE public.perfiles ENABLE TRIGGER trg_perfiles_sync_acceso_auth;
  INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock)
  VALUES ('T6C promo', 'bonificacion', public._tablero_hoy(), 1, false) RETURNING id INTO v_promo;
  INSERT INTO promo_ajustes (promocion_id, usos_ajustados, sucursal_id, observaciones)
  VALUES (v_promo, 1, 1, 'T6C ajuste');
  INSERT INTO control_stock_sesiones (sucursal_id, total_items, observaciones) VALUES (1, 3, 'T6C conteo');
  FOR v_t IN
    SELECT format('%s lee %s: %s (esperado %s)', quien, tabla, s.visto, esperado) FROM (VALUES
        ('el preventista', v_pre, 1, 'promo_ajustes', '0'),
        ('el preventista', v_pre, 1, 'control_stock_sesiones', '0'),
        ('el chofer', v_tra, 1, 'promo_ajustes', '0'),
        ('el chofer', v_tra, 1, 'control_stock_sesiones', '0'),
        ('el depósito desactivado', v_depoff, 1, 'control_stock_sesiones', '0'),
        ('el admin (regresión)', v_adm, 1, 'promo_ajustes', '1'),
        ('el admin (regresión)', v_adm, 1, 'control_stock_sesiones', '1'),
        ('el encargado (regresión)', v_enc, 1, 'promo_ajustes', '1'),
        ('el encargado (regresión)', v_enc, 1, 'control_stock_sesiones', '1'),
        ('el depósito (regresión)', v_dep, 1, 'promo_ajustes', '1'),
        ('el depósito (regresión)', v_dep, 1, 'control_stock_sesiones', '1')
      ) AS t(quien, u, suc, tabla, esperado),
      LATERAL (SELECT pg_temp.intenta(u, suc, format(
        $q$SELECT count(*)::text FROM %I WHERE observaciones LIKE 'T6C %%'$q$, tabla)) AS visto) s
     WHERE s.visto IS DISTINCT FROM 'PASA ' || esperado
  LOOP
    v_fallas := v_fallas || ('S9 · ' || v_t);
  END LOOP;

  -- ------------------------------------------------------------- S10 · permisos-B5 -
  v_adm12 := pg_temp.u('admin', 1);
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm12, 2) ON CONFLICT DO NOTHING;
  INSERT INTO gasto_rubros (nombre, grupo) VALUES ('T6C rubro gasto', 'otros') RETURNING id INTO v_rubro;
  INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, mes_imputado, creado_por)
  VALUES (2, public._tablero_hoy(), v_rubro, 1000, 'ticket', date_trunc('month', public._tablero_hoy())::date, v_adm)
  RETURNING id INTO v_g;
  v_r := pg_temp.intenta(v_adm12, 1, format($q$SELECT public.anular_gasto(%s, 'T6C')::text$q$, v_g));
  IF v_r NOT LIKE 'P0001 %sucursal%' OR (SELECT anulado_at FROM gastos WHERE id = v_g) IS NOT NULL THEN
    v_fallas := v_fallas || ('S10 · el admin de las dos, parado en la 1, anuló un gasto de la 2: ' || v_r);
  END IF;
  v_r := pg_temp.intenta(v_adm12, 2, format($q$SELECT public.anular_gasto(%s, 'T6C')::text$q$, v_g));
  IF v_r NOT LIKE 'PASA%' OR (SELECT anulado_at FROM gastos WHERE id = v_g) IS NULL THEN
    v_fallas := v_fallas || ('S10 · el admin de las dos, parado en la 2, no anuló el gasto de la 2 (regresión): ' || v_r);
  END IF;
  -- El compartido (cargado en la 2) lo anula quien lo cargó desde la 1 (regresión).
  INSERT INTO gastos (sucursal_id, compartido, fecha, rubro_id, monto_total, comprobante, mes_imputado, creado_por)
  VALUES (2, true, public._tablero_hoy(), v_rubro, 1000, 'ticket', date_trunc('month', public._tablero_hoy())::date, v_adm12)
  RETURNING id INTO v_g;
  v_r := pg_temp.intenta(v_adm12, 1, format($q$SELECT public.anular_gasto(%s, 'T6C')::text$q$, v_g));
  IF v_r NOT LIKE 'PASA%' THEN
    v_fallas := v_fallas || ('S10 · el compartido cargado por él, desde la 1 (regresión): ' || v_r);
  END IF;
  -- Un envío creado por la 2, cancelado desde la 1 (regresión: ya se rechazaba).
  INSERT INTO movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, estado, creado_por, stock_descontado, notas)
  VALUES (2, 1, 'pendiente', v_adm12, false, 'T6C envío') RETURNING id INTO v_mov;
  v_r := pg_temp.intenta(v_adm12, 1, format($q$SELECT public.cancelar_movimiento_sucursal(%s, 'T6C')::text$q$, v_mov));
  IF v_r NOT LIKE '%"success": false%' OR (SELECT estado FROM movimientos_sucursal WHERE id = v_mov) <> 'pendiente' THEN
    v_fallas := v_fallas || ('S10 · cancelar desde la 1 un envío de la 2 (regresión): ' || v_r);
  END IF;
  v_r := pg_temp.intenta(v_adm12, 2, format($q$SELECT public.cancelar_movimiento_sucursal(%s, 'T6C')::text$q$, v_mov));
  IF v_r NOT LIKE '%"success": true%' THEN
    v_fallas := v_fallas || ('S10 · cancelar desde la 2 su envío (regresión): ' || v_r);
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK' USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
    USING ERRCODE = 'P0001';
 END;
END
$ensayo$;
