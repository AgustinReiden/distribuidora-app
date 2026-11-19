-- Ensayo de la tarjeta C4b de la tanda 5 de la ola 2 del plan #1603
-- (migrations/NNN_catalogo_guardados_en_una_operacion.sql): 1561-b12 de #1561, 1599-b8 de #1599 y
-- 1598-b5 de #1598.
--
--   G1 · [F] Alta de una condición mayorista con tres productos, una escala clásica y una
--        combinada con dos mínimos: entra entera, en una llamada.
--   G2 · [F] El reintento con la misma clave devuelve la misma condición (replay) y no crea otra.
--   G3 · [F] La misma clave con otro contenido se rechaza con su motivo y no crea nada.
--   G4 · [F] Todo o nada en el alta: si falla el último paso (los mínimos), no queda la condición
--        ni sus productos ni sus escalas, ni la clave.
--   G5 · [F] Edición: sale un producto y entra otro, la escala de 10 cambia de precio y conserva
--        su id, la de 24 se va con sus mínimos y entra una de 48 combinada.
--   G6 · [F] Todo o nada en la edición: si fallan los mínimos, el nombre y los precios quedan como
--        estaban.
--   G7 · [F] Permisos: el encargado, el preventista, un admin desactivado, el admin parado en otra
--        sucursal y un producto de otra sucursal se rechazan; el admin de una sola sucursal edita
--        la condición de la suya (como por REST).
--   G8 · [F] Validaciones con motivo: cantidades repetidas, precio 0, regla combinada inalcanzable,
--        mínimo de un producto que no está, sin productos, precio en texto.
--   P1 · [F] Alta de una promo de unidad entera: la promo, sus dos productos y sus dos reglas;
--        replay con la misma clave; otro contenido con la misma clave, rechazado.
--   P2 · [F] Alta de una promo de fracción; sin descripción del regalo se rechaza.
--   P3 · [F] Todo o nada: si fallan las reglas, no queda la promo.
--   P4 · [F] Permisos: encargado, preventista, admin desactivado y un producto de otra sucursal.
--   P5 · [F] Versión: `cambiar_regalo_promocion` con el updated_at que vio quien edita pasa; con uno
--        viejo devuelve 'promocion_cambiada' y no cambia nada. Sin la clave (bundle viejo), pasa.
--   P6 · [F] La barra no mueve la versión: un UPDATE sólo de usos_pendientes deja updated_at; uno
--        del nombre lo mueve; uno que no cambia nada lo deja.
--   C1 · [F] `guardar_combo` con un updated_at viejo devuelve 'combo_cambiado' y no cambia nada; con
--        el actual, guarda. Sin la clave, guarda (bundle viejo).
--   C2 · [F] El orden: con la versión vieja de otro combo del orden devuelve 'orden_cambiado'; con
--        las de ahora reescribe el orden y les mueve el updated_at a los que cambiaron de prioridad
--        (al que no cambió, no).
--   C3 · [R] Un encargado sigue sin poder guardar un combo.
--   C4 · [F] Hallazgo de B15: con una temporal `_combo_resuelto` de quien llama, con un trigger que
--        deja una marca, `guardar_combo` no la usa (la marca no aparece); y dos llamadas seguidas en
--        la misma transacción siguen andando.
--   R1 · [F] Roles extra: el admin que abarca al usuario le pone y le saca «transportista»;
--        repetirlo no cambia nada; created_by es quien lo hizo.
--   R2 · [F] Permisos de los roles: el admin de una sola sucursal sobre un usuario de dos, el
--        encargado, un admin desactivado, un usuario que no es de la sucursal activa y un rol
--        desconocido se rechazan; el admin de una sola sucursal sí cambia a uno sólo de la suya.
--   D1 · [F] Descuentos por categoría: quedan como la lista (sin mirar mayúsculas ni bordes, la
--        última gana, sin categoría no cuenta); lista vacía los borra.
--   D2 · [F] Todo o nada: si falla el INSERT, quedan los de antes.
--   D3 · [F] Permisos y rango: encargado, preventista, admin desactivado, cliente de otra sucursal,
--        150 % y un porcentaje en texto se rechazan.
--   C5 · [F] v2: un combo que compite con éste y que quien edita no tenía en su lista (lo creó otro
--        mientras tanto) devuelve 'orden_cambiado' y no guarda; con la lista de ahora, guarda.
--   K1 · [F] v2 · guardar_cliente: el preventista da de alta un cliente y se lo asigna, en una
--        llamada; el reintento con la misma clave devuelve el mismo; otro contenido se rechaza.
--   K2 · [F] Todo o nada en el alta del admin con descuentos: si fallan los descuentos, no queda el
--        cliente ni su clave.
--   K3 · [F] Siguen las guardas de los triggers y las policies (corre como quien llama): el
--        preventista no crea un reservado ni fija descuento; nadie se asigna un cliente ajeno; el
--        duplicado bloquea.
--   K4 · [F] Versión: con la de antes devuelve 'cliente_cambiado' sin cambiar nada; con la de ahora
--        guarda. Un UPDATE sólo de saldo_cuenta no la mueve; uno que no cambia nada tampoco.
--   K5 · [F] Edición: el preventista no toca una columna protegida ni un cliente de otro; un admin
--        desactivado no edita.
--   K6 · [F] La zona manda: el alta en una zona con dueño le asigna el dueño (lo hace el trigger, no
--        la RPC), y una edición sin lista de preventistas no lo saca.
--   K7 · [F] Los preventistas se guardan como la diferencia (#1316): con los previos que cargó el
--        formulario, un dueño que puso otro en el medio se queda; sin previos, la lista vacía saca
--        a todos (el admin que destilda al dueño de la zona).
--   U1 · [F] v2 · guardar_usuario: el admin que abarca al usuario le cambia el nombre y el rol extra
--        en una llamada; si el rol extra es inválido no queda ni el nombre; el admin de una sola
--        sucursal no edita a uno de dos.
--   v3 (revisión adversarial):
--   P7 · [F] H2: la versión de la promo se mueve si cambian sólo productos, sólo reglas, sólo el
--        regalo o los tres; con la de antes, el guardado se rechaza y no borra lo del otro.
--   K8 · [F] H3: la del cliente se mueve si cambian sólo los descuentos o sólo los preventistas (la
--        ficha vieja no borra los descuentos del otro); el saldo no la mueve.
--   K9 · [R] D2: el admin no le asigna el cliente a un preventista de otra sucursal (#1374).
--   U2 · [F] D1: nadie se edita a sí mismo (perfil ni roles extra), como dice CLAUDE.md.
--   C6 · [F] H5: un nulo en `vistos` se rechaza (no apaga la guarda).
--   A1 · [F] H4: la clave de un alta guarda sólo un md5.
--   (H1, el deadlock con la venta, lo prueba scripts/concurrencia/c4b-combo-y-venta.sh.)
--   S1 · [F] Las cuatro RPC nuevas: definer, pg_temp al final del search_path, EXECUTE sólo para
--        authenticated (no PUBLIC ni anon); altas_por_clave con RLS, sin policies ni grants.
--   S2 · [F] guardar_combo y cambiar_regalo_promocion: una sola firma cada una y pg_temp en el
--        search_path; y también el trigger update_promociones_updated_at (B15 vale para toda
--        función con search_path).
--
-- [F] falla sin la migración y pasa con ella; [R] pasa antes y después.
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja nada (salvo valores
-- de secuencia). Veredicto: 'ENSAYO OK (n casos)' o 'ENSAYO FALLO (n fallas)' con la lista. En una
-- base local, nunca contra prod (escribe en auth.users y crea un trigger de prueba):
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-guardados-atomicos-ola2-1603.sql

SET client_min_messages = warning;

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_app    jsonb := '{"provider":"email","providers":["email"]}';
  v_adm    uuid;   -- admin de la 1 y la 2
  v_a1     uuid;   -- admin sólo de la 1
  v_enc    uuid;   -- encargado de la 1
  v_pre    uuid;   -- preventista de la 1
  v_des    uuid;   -- admin de la 1, desactivado
  v_u      uuid;   -- preventista de la 1 y la 2 (a quien se le cambian los roles)
  v_u2     uuid;   -- preventista sólo de la 2
  p1 bigint; p2 bigint; p3 bigint; p4 bigint; q1 bigint;
  c1 bigint; c2 bigint;
  k1 uuid := gen_random_uuid();
  k2 uuid := gen_random_uuid();
  kp1 uuid := gen_random_uuid();
  kp2 uuid := gen_random_uuid();
  kp3 uuid := gen_random_uuid();
  v_j      jsonb;
  v_t      text;
  v_g      bigint;
  v_e10    bigint;
  v_pr     bigint;
  v_ts     timestamptz;
  v_ca     bigint; v_cb bigint; v_cc bigint;
  v_n      bigint;
  v_fallas text[] := '{}';
  v_casos  int := 40;
  v_k      int;
  v_cl     bigint;
  v_cl2    bigint;
  v_zona   bigint;
  v_cd     bigint;
  kc1      uuid := gen_random_uuid();
  kc2      uuid := gen_random_uuid();
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_tag text, p_app jsonb) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'c4b-' || p_tag || '-' || v || '@ensayo.invalid', p_app, '{}', now(), now());
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
  -- Corre p_sql como p_uid (authenticated, sucursal p_suc): 'PASA <valor>' o '<SQLSTATE> <mensaje>'.
  CREATE FUNCTION pg_temp.intenta(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text; x text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
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
  CREATE FUNCTION pg_temp.cond(p_uid uuid, p_suc bigint, p_j jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_uid, p_suc, format('SELECT public.guardar_condicion_mayorista(%L::jsonb)::text', p_j))
  $f$;
  CREATE FUNCTION pg_temp.promo(p_uid uuid, p_suc bigint, p_j jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_uid, p_suc, format('SELECT public.crear_promocion(%L::jsonb)::text', p_j))
  $f$;
  CREATE FUNCTION pg_temp.roles(p_uid uuid, p_suc bigint, p_u uuid, p_r text[]) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_uid, p_suc, format('SELECT public.guardar_roles_extra(%L::uuid, %L::text[])::text', p_u, p_r))
  $f$;
  CREATE FUNCTION pg_temp.desc_(p_uid uuid, p_suc bigint, p_cli bigint, p_j jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_uid, p_suc, format('SELECT public.guardar_descuentos_categoria(%s, %L::jsonb)::text', p_cli, p_j))
  $f$;
  CREATE FUNCTION pg_temp.combo(p_uid uuid, p_suc bigint, p_j jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_uid, p_suc, format('SELECT public.guardar_combo(%L::jsonb)::text', p_j))
  $f$;
  -- El JSON de lo que devolvió una llamada que pasó (o null).
  CREATE FUNCTION pg_temp.j(p text) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT CASE WHEN p LIKE 'PASA {%' THEN substr(p, 6)::jsonb END
  $f$;
  -- ¿Quedó la clave de un alta? (sin la migración la tabla no existe: no quedó).
  CREATE FUNCTION pg_temp.hay_clave(p uuid) RETURNS boolean LANGUAGE plpgsql AS $f$
  DECLARE r boolean;
  BEGIN
    IF to_regclass('public.altas_por_clave') IS NULL THEN RETURN false; END IF;
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.altas_por_clave WHERE clave = $1)' INTO r USING p;
    RETURN r;
  END $f$;
  CREATE FUNCTION pg_temp.descuentos(p_cli bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(categoria || '=' || descuento_porcentaje::text, ',' ORDER BY categoria), '(ninguno)')
      FROM public.cliente_descuentos_categoria WHERE cliente_id = p_cli
  $f$;

  -- El paso que falla a propósito (todo o nada): un trigger que rechaza el INSERT en la tabla que
  -- diga c4b.falla. Se crea dentro del ensayo y se va con él.
  CREATE FUNCTION public.zz_c4b_falla() RETURNS trigger LANGUAGE plpgsql AS $f$
  BEGIN
    IF current_setting('c4b.falla', true) = TG_TABLE_NAME THEN
      RAISE EXCEPTION 'falla a propósito en %', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
  END $f$;
  CREATE TRIGGER zz_c4b_falla BEFORE INSERT ON public.grupo_precio_escala_minimos
    FOR EACH ROW EXECUTE FUNCTION public.zz_c4b_falla();
  CREATE TRIGGER zz_c4b_falla BEFORE INSERT ON public.promocion_reglas
    FOR EACH ROW EXECUTE FUNCTION public.zz_c4b_falla();
  CREATE TRIGGER zz_c4b_falla BEFORE INSERT ON public.cliente_descuentos_categoria
    FOR EACH ROW EXECUTE FUNCTION public.zz_c4b_falla();

  IF (SELECT count(*) FROM sucursales WHERE id IN (1, 2)) <> 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLO · hacen falta las sucursales 1 y 2';
  END IF;
  UPDATE sucursales SET activa = true WHERE id IN (1, 2);

  -- ---------------------------------------------------------------- datos ---
  v_adm := pg_temp.u('adm', v_app || '{"rol":"admin","sucursal_id":1}');
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_adm, 2, false);
  v_a1  := pg_temp.u('a1',  v_app || '{"rol":"admin","sucursal_id":1}');
  v_enc := pg_temp.u('enc', v_app || '{"rol":"encargado","sucursal_id":1}');
  v_pre := pg_temp.u('pre', v_app || '{"rol":"preventista","sucursal_id":1}');
  v_des := pg_temp.u('des', v_app || '{"rol":"admin","sucursal_id":1}');
  -- La baja sincroniza auth.users.banned_until (trg_perfiles_sync_acceso_auth); una base local sin
  -- esa columna la hace sin triggers.
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'auth.users'::regclass AND attname = 'banned_until' AND NOT attisdropped) THEN
    UPDATE perfiles SET activo = false WHERE id = v_des;
  ELSE
    SET LOCAL session_replication_role = replica;
    UPDATE perfiles SET activo = false WHERE id = v_des;
    SET LOCAL session_replication_role = origin;
  END IF;
  v_u   := pg_temp.u('u',   v_app || '{"rol":"preventista","sucursal_id":1}');
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_u, 2, false);
  v_u2  := pg_temp.u('u2',  v_app || '{"rol":"preventista","sucursal_id":2}');

  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
  VALUES ('ZZ C4b uno', 100, 50, 1, 'ZZ C4b') RETURNING id INTO p1;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
  VALUES ('ZZ C4b dos', 100, 50, 1, 'ZZ C4b') RETURNING id INTO p2;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
  VALUES ('ZZ C4b tres', 100, 50, 1, 'ZZ C4b') RETURNING id INTO p3;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
  VALUES ('ZZ C4b cuatro', 100, 50, 1, 'ZZ C4b') RETURNING id INTO p4;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
  VALUES ('ZZ C4b de la dos', 100, 50, 2, 'ZZ C4b') RETURNING id INTO q1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ C4b cliente', 'ZZ C4b cliente', 'Calle Falsa 123', 1) RETURNING id INTO c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ C4b cliente dos', 'ZZ C4b cliente dos', 'Calle Falsa 456', 2) RETURNING id INTO c2;

  -- ===================================================== condición mayorista -
  -- G1
  v_j := jsonb_build_object('clave', k1, 'nombre', 'ZZ C4b cond', 'descripcion', null,
    'producto_ids', jsonb_build_array(p1, p2, p3),
    'escalas', jsonb_build_array(
      jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 90, 'etiqueta', 'x10', 'min_productos_distintos', 1, 'minimos', '[]'::jsonb),
      jsonb_build_object('cantidad_minima', 24, 'precio_unitario', 80, 'min_productos_distintos', 2,
        'minimos', jsonb_build_array(jsonb_build_object('producto_id', p1, 'cantidad', 12),
                                     jsonb_build_object('producto_id', p2, 'cantidad', 12, 'precio_override', 78)))));
  v_t := pg_temp.cond(v_adm, 1, v_j);
  v_g := (pg_temp.j(v_t)->>'id')::bigint;
  IF v_g IS NULL
     OR (SELECT count(*) FROM grupos_precio WHERE nombre = 'ZZ C4b cond') <> 1
     OR (SELECT count(*) FROM grupo_precio_productos WHERE grupo_precio_id = v_g) <> 3
     OR (SELECT count(*) FROM grupo_precio_escalas WHERE grupo_precio_id = v_g) <> 2
     OR (SELECT count(*) FROM grupo_precio_escala_minimos m JOIN grupo_precio_escalas e ON e.id = m.escala_id
          WHERE e.grupo_precio_id = v_g AND e.cantidad_minima = 24) <> 2
     OR (SELECT precio_unitario_override FROM grupo_precio_escala_minimos m JOIN grupo_precio_escalas e ON e.id = m.escala_id
          WHERE e.grupo_precio_id = v_g AND m.producto_id = p2) IS DISTINCT FROM 78 THEN
    v_fallas := v_fallas || ('G1 · el alta de la condición no quedó entera: ' || v_t);
  END IF;

  -- G2
  v_t := pg_temp.cond(v_adm, 1, v_j);
  IF v_g IS NULL OR (pg_temp.j(v_t)->>'id')::bigint IS DISTINCT FROM v_g
     OR (pg_temp.j(v_t)->>'replay')::boolean IS DISTINCT FROM true
     OR (SELECT count(*) FROM grupos_precio WHERE nombre = 'ZZ C4b cond') <> 1 THEN
    v_fallas := v_fallas || ('G2 · el reintento no devolvió la misma condición: ' || v_t);
  END IF;

  -- G3
  v_t := pg_temp.cond(v_adm, 1, jsonb_set(v_j, '{nombre}', '"ZZ C4b cond otra"'));
  IF v_t NOT LIKE '%ya se creó con el intento anterior%'
     OR EXISTS (SELECT 1 FROM grupos_precio WHERE nombre = 'ZZ C4b cond otra') THEN
    v_fallas := v_fallas || ('G3 · la misma clave con otro contenido no se rechazó: ' || v_t);
  END IF;

  -- G4
  PERFORM set_config('c4b.falla', 'grupo_precio_escala_minimos', true);
  v_t := pg_temp.cond(v_adm, 1, jsonb_set(jsonb_set(v_j, '{clave}', to_jsonb(k2)), '{nombre}', '"ZZ C4b cond dos"'));
  PERFORM set_config('c4b.falla', '', true);
  IF v_t NOT LIKE '%falla a propósito%'
     OR EXISTS (SELECT 1 FROM grupos_precio WHERE nombre = 'ZZ C4b cond dos')
     OR pg_temp.hay_clave(k2) THEN
    v_fallas := v_fallas || ('G4 · un alta que falla en los mínimos dejó algo: ' || v_t);
  END IF;

  -- G5
  v_e10 := (SELECT id FROM grupo_precio_escalas WHERE grupo_precio_id = v_g AND cantidad_minima = 10);
  v_t := pg_temp.cond(v_adm, 1, jsonb_build_object('id', v_g, 'nombre', 'ZZ C4b cond editada',
    'producto_ids', jsonb_build_array(p1, p2, p4),
    'escalas', jsonb_build_array(
      jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 85, 'etiqueta', 'x10', 'min_productos_distintos', 1),
      jsonb_build_object('cantidad_minima', 48, 'precio_unitario', 70, 'min_productos_distintos', 2,
        'minimos', jsonb_build_array(jsonb_build_object('producto_id', p1, 'cantidad', 20),
                                     jsonb_build_object('producto_id', p4, 'cantidad', 20))))));
  IF v_g IS NULL OR v_t NOT LIKE 'PASA %'
     OR (SELECT nombre FROM grupos_precio WHERE id = v_g) IS DISTINCT FROM 'ZZ C4b cond editada'
     OR (SELECT array_agg(producto_id ORDER BY producto_id) FROM grupo_precio_productos WHERE grupo_precio_id = v_g)
        IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[p1, p2, p4]) x)
     OR (SELECT id FROM grupo_precio_escalas WHERE grupo_precio_id = v_g AND cantidad_minima = 10) IS DISTINCT FROM v_e10
     OR (SELECT precio_unitario FROM grupo_precio_escalas WHERE id = v_e10) IS DISTINCT FROM 85
     OR EXISTS (SELECT 1 FROM grupo_precio_escalas WHERE grupo_precio_id = v_g AND cantidad_minima = 24)
     OR (SELECT count(*) FROM grupo_precio_escala_minimos m JOIN grupo_precio_escalas e ON e.id = m.escala_id
          WHERE e.grupo_precio_id = v_g) <> 2
     OR (SELECT count(*) FROM grupo_precio_escala_minimos m JOIN grupo_precio_escalas e ON e.id = m.escala_id
          WHERE e.grupo_precio_id = v_g AND e.cantidad_minima = 48) <> 2 THEN
    v_fallas := v_fallas || ('G5 · la edición no concilió como se pidió: ' || v_t);
  END IF;

  -- G6
  PERFORM set_config('c4b.falla', 'grupo_precio_escala_minimos', true);
  v_t := pg_temp.cond(v_adm, 1, jsonb_build_object('id', v_g, 'nombre', 'ZZ C4b cond rota',
    'producto_ids', jsonb_build_array(p1, p2, p4),
    'escalas', jsonb_build_array(
      jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 60),
      jsonb_build_object('cantidad_minima', 48, 'precio_unitario', 70, 'min_productos_distintos', 2,
        'minimos', jsonb_build_array(jsonb_build_object('producto_id', p1, 'cantidad', 20),
                                     jsonb_build_object('producto_id', p2, 'cantidad', 20))))));
  PERFORM set_config('c4b.falla', '', true);
  IF v_t NOT LIKE '%falla a propósito%'
     OR (SELECT nombre FROM grupos_precio WHERE id = v_g) IS DISTINCT FROM 'ZZ C4b cond editada'
     OR (SELECT precio_unitario FROM grupo_precio_escalas WHERE id = v_e10) IS DISTINCT FROM 85 THEN
    v_fallas := v_fallas || ('G6 · una edición que falla en los mínimos dejó algo: ' || v_t);
  END IF;

  -- G7
  v_j := jsonb_build_object('id', v_g, 'nombre', 'ZZ C4b cond intrusa', 'producto_ids', jsonb_build_array(p1),
    'escalas', jsonb_build_array(jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 1)));
  v_t := pg_temp.cond(v_enc, 1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('G7 · el encargado editó la condición: ' || v_t); END IF;
  v_t := pg_temp.cond(v_pre, 1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('G7 · el preventista editó la condición: ' || v_t); END IF;
  v_t := pg_temp.cond(v_des, 1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('G7 · un admin desactivado editó la condición: ' || v_t); END IF;
  v_t := pg_temp.cond(v_adm, 2, jsonb_set(v_j, '{producto_ids}', jsonb_build_array(q1)));
  IF v_t NOT LIKE '%no existe en esta sucursal%' THEN
    v_fallas := v_fallas || ('G7 · el admin parado en la 2 editó la condición de la 1: ' || v_t);
  END IF;
  v_t := pg_temp.cond(v_adm, 1, jsonb_set(v_j, '{producto_ids}', jsonb_build_array(p1, q1)));
  IF v_t NOT LIKE '%no es de esta sucursal%' THEN
    v_fallas := v_fallas || ('G7 · entró un producto de otra sucursal: ' || v_t);
  END IF;
  IF (SELECT nombre FROM grupos_precio WHERE id = v_g) IS DISTINCT FROM 'ZZ C4b cond editada' THEN
    v_fallas := v_fallas || text 'G7 · un rechazo cambió la condición';
  END IF;
  v_t := pg_temp.cond(v_a1, 1, jsonb_build_object('id', v_g, 'nombre', 'ZZ C4b cond de a1',
    'producto_ids', jsonb_build_array(p1, p2, p4),
    'escalas', jsonb_build_array(jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 85, 'etiqueta', 'x10'))));
  IF v_t NOT LIKE 'PASA %' OR (SELECT nombre FROM grupos_precio WHERE id = v_g) IS DISTINCT FROM 'ZZ C4b cond de a1' THEN
    v_fallas := v_fallas || ('G7 · el admin de la 1 no pudo editar la condición de la 1: ' || v_t);
  END IF;

  -- G8
  v_j := jsonb_build_object('clave', gen_random_uuid(), 'nombre', 'ZZ C4b cond mala', 'producto_ids', jsonb_build_array(p1, p2));
  v_t := pg_temp.cond(v_adm, 1, v_j || jsonb_build_object('escalas', jsonb_build_array(
    jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 90), jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 80))));
  IF v_t NOT LIKE '%misma cantidad mínima%' THEN v_fallas := v_fallas || ('G8 · cantidades repetidas: ' || v_t); END IF;
  v_t := pg_temp.cond(v_adm, 1, v_j || jsonb_build_object('escalas', jsonb_build_array(
    jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 0))));
  IF v_t NOT LIKE '%precio tiene que ser mayor a 0%' THEN v_fallas := v_fallas || ('G8 · precio 0: ' || v_t); END IF;
  v_t := pg_temp.cond(v_adm, 1, v_j || jsonb_build_object('escalas', jsonb_build_array(
    jsonb_build_object('cantidad_minima', 24, 'precio_unitario', 80, 'min_productos_distintos', 2,
      'minimos', jsonb_build_array(jsonb_build_object('producto_id', p1, 'cantidad', 20), jsonb_build_object('producto_id', p2, 'cantidad', 20))))));
  IF v_t NOT LIKE '%inalcanzable%' THEN v_fallas := v_fallas || ('G8 · regla inalcanzable: ' || v_t); END IF;
  v_t := pg_temp.cond(v_adm, 1, v_j || jsonb_build_object('escalas', jsonb_build_array(
    jsonb_build_object('cantidad_minima', 24, 'precio_unitario', 80,
      'minimos', jsonb_build_array(jsonb_build_object('producto_id', p3, 'cantidad', 5))))));
  IF v_t NOT LIKE '%no está en la condición%' THEN v_fallas := v_fallas || ('G8 · mínimo de un producto ajeno: ' || v_t); END IF;
  v_t := pg_temp.cond(v_adm, 1, jsonb_set(v_j, '{producto_ids}', '[]') || jsonb_build_object('escalas', jsonb_build_array(
    jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 90))));
  IF v_t NOT LIKE '%al menos un producto%' THEN v_fallas := v_fallas || ('G8 · sin productos: ' || v_t); END IF;
  v_t := pg_temp.cond(v_adm, 1, v_j || jsonb_build_object('escalas', jsonb_build_array(
    jsonb_build_object('cantidad_minima', 10, 'precio_unitario', 'NaN'))));
  IF v_t NOT LIKE '%formato inválido%' THEN v_fallas := v_fallas || ('G8 · precio en texto: ' || v_t); END IF;
  IF EXISTS (SELECT 1 FROM grupos_precio WHERE nombre = 'ZZ C4b cond mala') THEN
    v_fallas := v_fallas || text 'G8 · un alta rechazada dejó la condición';
  END IF;

  -- ================================================================= promos -
  -- P1
  v_j := jsonb_build_object('clave', kp1, 'nombre', 'ZZ C4b promo', 'tipo', 'bonificacion', 'fecha_inicio', v_hoy,
    'producto_ids', jsonb_build_array(p1, p2), 'producto_regalo_id', p3, 'regalo_mueve_stock', true,
    'ajuste_automatico', false, 'modo_exclusion', 'acumulable', 'prioridad', 0,
    'reglas', jsonb_build_array(jsonb_build_object('clave', 'cantidad_compra', 'valor', 10),
                                jsonb_build_object('clave', 'cantidad_bonificacion', 'valor', 1)));
  v_t := pg_temp.promo(v_adm, 1, v_j);
  v_pr := (pg_temp.j(v_t)->>'id')::bigint;
  IF v_pr IS NULL
     OR (SELECT count(*) FROM promociones WHERE nombre = 'ZZ C4b promo') <> 1
     OR (SELECT count(*) FROM promocion_productos WHERE promocion_id = v_pr) <> 2
     OR (SELECT count(*) FROM promocion_reglas WHERE promocion_id = v_pr) <> 2
     OR (SELECT producto_regalo_id FROM promociones WHERE id = v_pr) IS DISTINCT FROM p3 THEN
    v_fallas := v_fallas || ('P1 · el alta de la promo no quedó entera: ' || v_t);
  END IF;
  v_t := pg_temp.promo(v_adm, 1, v_j);
  IF v_pr IS NULL OR (pg_temp.j(v_t)->>'id')::bigint IS DISTINCT FROM v_pr
     OR (SELECT count(*) FROM promociones WHERE nombre = 'ZZ C4b promo') <> 1 THEN
    v_fallas := v_fallas || ('P1 · el reintento de la promo no devolvió la misma: ' || v_t);
  END IF;
  v_t := pg_temp.promo(v_adm, 1, jsonb_set(v_j, '{nombre}', '"ZZ C4b promo otra"'));
  IF v_t NOT LIKE '%ya se creó con el intento anterior%' OR EXISTS (SELECT 1 FROM promociones WHERE nombre = 'ZZ C4b promo otra') THEN
    v_fallas := v_fallas || ('P1 · la misma clave con otra promo no se rechazó: ' || v_t);
  END IF;

  -- P2
  v_j := jsonb_build_object('clave', kp2, 'nombre', 'ZZ C4b fraccion', 'fecha_inicio', v_hoy,
    'producto_ids', jsonb_build_array(p1), 'producto_regalo_id', p4, 'regalo_mueve_stock', false,
    'ajuste_automatico', true, 'ajuste_producto_id', p4, 'unidades_por_bloque', 6, 'stock_por_bloque', 1,
    'descripcion_regalo', '1 botella',
    'reglas', jsonb_build_array(jsonb_build_object('clave', 'cantidad_compra', 'valor', 6),
                                jsonb_build_object('clave', 'cantidad_bonificacion', 'valor', 1)));
  v_t := pg_temp.promo(v_adm, 1, jsonb_set(v_j, '{descripcion_regalo}', 'null'));
  IF v_t NOT LIKE '%descripción del regalo%' THEN
    v_fallas := v_fallas || ('P2 · una promo de fracción sin descripción entró: ' || v_t);
  END IF;
  v_t := pg_temp.promo(v_adm, 1, v_j);
  IF pg_temp.j(v_t) IS NULL
     OR (SELECT (ajuste_automatico, ajuste_producto_id, unidades_por_bloque) FROM promociones WHERE nombre = 'ZZ C4b fraccion')
        IS DISTINCT FROM (true, p4, 6) THEN
    v_fallas := v_fallas || ('P2 · la promo de fracción no quedó: ' || v_t);
  END IF;

  -- P3
  PERFORM set_config('c4b.falla', 'promocion_reglas', true);
  v_t := pg_temp.promo(v_adm, 1, jsonb_set(jsonb_set(v_j, '{clave}', to_jsonb(kp3)), '{nombre}', '"ZZ C4b promo rota"'));
  PERFORM set_config('c4b.falla', '', true);
  IF v_t NOT LIKE '%falla a propósito%' OR EXISTS (SELECT 1 FROM promociones WHERE nombre = 'ZZ C4b promo rota') THEN
    v_fallas := v_fallas || ('P3 · un alta de promo que falla en las reglas dejó la promo: ' || v_t);
  END IF;

  -- P4
  v_j := jsonb_set(jsonb_set(v_j, '{clave}', to_jsonb(gen_random_uuid())), '{nombre}', '"ZZ C4b promo intrusa"');
  v_t := pg_temp.promo(v_enc, 1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('P4 · el encargado creó una promo: ' || v_t); END IF;
  v_t := pg_temp.promo(v_pre, 1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('P4 · el preventista creó una promo: ' || v_t); END IF;
  v_t := pg_temp.promo(v_des, 1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('P4 · un admin desactivado creó una promo: ' || v_t); END IF;
  v_t := pg_temp.promo(v_adm, 1, jsonb_set(v_j, '{producto_ids}', jsonb_build_array(p1, q1)));
  IF v_t NOT LIKE '%no existe en esta sucursal%' THEN v_fallas := v_fallas || ('P4 · entró un producto de otra sucursal: ' || v_t); END IF;
  IF EXISTS (SELECT 1 FROM promociones WHERE nombre = 'ZZ C4b promo intrusa') THEN
    v_fallas := v_fallas || text 'P4 · un rechazo dejó la promo';
  END IF;

  -- P5 · la versión de la promo. Todo el ensayo es una transacción (now() no cambia): la versión
  -- «que vio otro» se arma corriéndola un segundo.
  IF v_pr IS NOT NULL THEN
    v_ts := (SELECT updated_at FROM promociones WHERE id = v_pr);
    v_t := pg_temp.intenta(v_adm, 1, format(
      'SELECT public.cambiar_regalo_promocion(%s, %s, NULL, false, %L::jsonb)::text', v_pr, p3,
      jsonb_build_object('nombre', 'ZZ C4b promo vieja', 'updated_at_esperado', v_ts - interval '1 second')));
    IF pg_temp.j(v_t)->>'codigo' IS DISTINCT FROM 'promocion_cambiada'
       OR (SELECT nombre FROM promociones WHERE id = v_pr) IS DISTINCT FROM 'ZZ C4b promo' THEN
      v_fallas := v_fallas || ('P5 · una edición con la versión vieja pisó la promo: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format(
      'SELECT public.cambiar_regalo_promocion(%s, %s, NULL, false, %L::jsonb)::text', v_pr, p3,
      jsonb_build_object('nombre', 'ZZ C4b promo nueva', 'updated_at_esperado', v_ts)));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true
       OR (SELECT nombre FROM promociones WHERE id = v_pr) IS DISTINCT FROM 'ZZ C4b promo nueva' THEN
      v_fallas := v_fallas || ('P5 · una edición con la versión de ahora no guardó: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format(
      'SELECT public.cambiar_regalo_promocion(%s, %s, NULL, false, %L::jsonb)::text', v_pr, p3,
      jsonb_build_object('nombre', 'ZZ C4b promo sin version')));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true
       OR (SELECT nombre FROM promociones WHERE id = v_pr) IS DISTINCT FROM 'ZZ C4b promo sin version' THEN
      v_fallas := v_fallas || ('P5 · una edición sin versión (bundle viejo) no guardó: ' || v_t);
    END IF;
  ELSE
    v_fallas := v_fallas || text 'P5 · sin promo (P1 falló)';
  END IF;

  -- P6 · el trigger de la versión. Sin triggers, la versión se lleva a una fecha vieja.
  v_n := (SELECT id FROM promociones WHERE sucursal_id = 1 ORDER BY id DESC LIMIT 1);
  IF v_n IS NULL THEN
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id) VALUES ('ZZ C4b promo P6', 'bonificacion', v_hoy, 1)
    RETURNING id INTO v_n;
  END IF;
  SET LOCAL session_replication_role = replica;
  UPDATE promociones SET updated_at = '2020-01-01 00:00:00+00' WHERE id = v_n;
  SET LOCAL session_replication_role = origin;
  UPDATE promociones SET usos_pendientes = COALESCE(usos_pendientes, 0) + 3 WHERE id = v_n;
  IF (SELECT updated_at FROM promociones WHERE id = v_n) IS DISTINCT FROM '2020-01-01 00:00:00+00'::timestamptz THEN
    v_fallas := v_fallas || text 'P6 · un UPDATE sólo de usos_pendientes movió la versión de la promo';
  END IF;
  UPDATE promociones SET nombre = nombre WHERE id = v_n;
  IF (SELECT updated_at FROM promociones WHERE id = v_n) IS DISTINCT FROM '2020-01-01 00:00:00+00'::timestamptz THEN
    v_fallas := v_fallas || text 'P6 · un UPDATE que no cambia nada movió la versión de la promo';
  END IF;
  UPDATE promociones SET nombre = nombre || ' (P6)' WHERE id = v_n;
  IF (SELECT updated_at FROM promociones WHERE id = v_n) IS NOT DISTINCT FROM '2020-01-01 00:00:00+00'::timestamptz THEN
    v_fallas := v_fallas || text 'P6 · cambiar el nombre no movió la versión de la promo';
  END IF;

  -- ================================================================= combos -
  -- Tres combos que compiten (los mismos productos). Sin triggers de versión en combos: la versión
  -- «vieja» se escribe directo.
  v_j := jsonb_build_object('nombre', 'ZZ C4b combo A', 'precio', 180, 'fecha_inicio', v_hoy,
    'componentes', jsonb_build_array(jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p1)),
                                     jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p2))));
  v_ca := (pg_temp.j(pg_temp.combo(v_adm, 1, v_j))->>'id')::bigint;
  v_cb := (pg_temp.j(pg_temp.combo(v_adm, 1, jsonb_set(v_j, '{nombre}', '"ZZ C4b combo B"')))->>'id')::bigint;
  v_cc := (pg_temp.j(pg_temp.combo(v_adm, 1, jsonb_set(v_j, '{nombre}', '"ZZ C4b combo C"')))->>'id')::bigint;
  IF v_ca IS NULL OR v_cb IS NULL OR v_cc IS NULL THEN
    v_fallas := v_fallas || text 'C1 · no se pudieron armar los combos del ensayo';
  ELSE
    UPDATE combos SET updated_at = '2020-01-01 00:00:00+00', prioridad = 0 WHERE id IN (v_ca, v_cb, v_cc);
    UPDATE combos SET prioridad = 2 WHERE id = v_cb;   -- B arriba, A y C abajo

    -- C1
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca, 'precio', 160,
      'updated_at_esperado', '2019-12-31 00:00:00+00'));
    IF pg_temp.j(v_t)->>'codigo' IS DISTINCT FROM 'combo_cambiado' OR (SELECT precio FROM combos WHERE id = v_ca) <> 180 THEN
      v_fallas := v_fallas || ('C1 · un guardado con la versión vieja pisó el combo: ' || v_t);
    END IF;
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca, 'precio', 160,
      'updated_at_esperado', '2020-01-01 00:00:00+00'));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true OR (SELECT precio FROM combos WHERE id = v_ca) <> 160 THEN
      v_fallas := v_fallas || ('C1 · un guardado con la versión de ahora no guardó: ' || v_t);
    END IF;
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca, 'precio', 140));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true OR (SELECT precio FROM combos WHERE id = v_ca) <> 140 THEN
      v_fallas := v_fallas || ('C1 · un guardado sin versión (bundle viejo) no guardó: ' || v_t);
    END IF;

    -- C2 · el orden A, B, C (A arriba). B baja de 2 a 2: no cambia; C sube de 0 a 1.
    UPDATE combos SET updated_at = '2020-01-01 00:00:00+00' WHERE id IN (v_ca, v_cb, v_cc);
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca,
      'updated_at_esperado', '2020-01-01 00:00:00+00',
      'orden', jsonb_build_array(v_ca, v_cb, v_cc),
      'versiones', jsonb_build_object(v_cb::text, '2020-01-01 00:00:00+00', v_cc::text, '2019-12-31 00:00:00+00')));
    IF pg_temp.j(v_t)->>'codigo' IS DISTINCT FROM 'orden_cambiado' OR (SELECT prioridad FROM combos WHERE id = v_cc) <> 0 THEN
      v_fallas := v_fallas || ('C2 · un guardado con la versión vieja de otro combo del orden lo pisó: ' || v_t);
    END IF;
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca,
      'updated_at_esperado', '2020-01-01 00:00:00+00',
      'orden', jsonb_build_array(v_ca, v_cb, v_cc),
      'versiones', jsonb_build_object(v_cb::text, '2020-01-01 00:00:00+00', v_cc::text, '2020-01-01 00:00:00+00')));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true
       OR (SELECT array_agg(prioridad ORDER BY id) FROM combos WHERE id IN (v_ca, v_cb, v_cc))
          IS DISTINCT FROM (SELECT array_agg(p ORDER BY i) FROM (VALUES (v_ca, 3), (v_cb, 2), (v_cc, 1)) t(i, p))
       OR (SELECT updated_at FROM combos WHERE id = v_cc) = '2020-01-01 00:00:00+00'::timestamptz
       OR (SELECT updated_at FROM combos WHERE id = v_cb) <> '2020-01-01 00:00:00+00'::timestamptz THEN
      v_fallas := v_fallas || ('C2 · el orden no se reescribió o no movió la versión del que cambió de prioridad: ' || v_t);
    END IF;

    -- C4 · la temporal de quien llama. Las llamadas de arriba ya dejaron una en la sesión (ON
    -- COMMIT DROP, y el ensayo es una sola transacción): se tira y se arma la «del que llama».
    DROP TABLE IF EXISTS pg_temp._combo_resuelto;
    CREATE TEMP TABLE _combo_resuelto (lugar integer, producto bigint);
    CREATE TEMP TABLE _c4b_marcas (n integer);
    GRANT ALL ON pg_temp._combo_resuelto, pg_temp._c4b_marcas TO PUBLIC;
    CREATE FUNCTION pg_temp.c4b_marca() RETURNS trigger LANGUAGE plpgsql AS $f$
    BEGIN
      INSERT INTO pg_temp._c4b_marcas VALUES (1);
      RETURN NEW;
    END $f$;
    CREATE TRIGGER c4b_marca BEFORE INSERT ON pg_temp._combo_resuelto
      FOR EACH ROW EXECUTE FUNCTION pg_temp.c4b_marca();
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca, 'precio', 130));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true THEN
      v_fallas := v_fallas || ('C4 · guardar_combo con una temporal de quien llama no guardó: ' || v_t);
    END IF;
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca, 'precio', 120));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true OR (SELECT precio FROM combos WHERE id = v_ca) <> 120 THEN
      v_fallas := v_fallas || ('C4 · una segunda llamada en la misma transacción no guardó: ' || v_t);
    END IF;
    IF (SELECT count(*) FROM pg_temp._c4b_marcas) > 0 THEN
      v_fallas := v_fallas || text 'C4 · guardar_combo usó la temporal _combo_resuelto de quien llama (corrió su trigger)';
    END IF;

    -- C3
    v_t := pg_temp.combo(v_enc, 1, v_j || jsonb_build_object('id', v_ca, 'precio', 110));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM false OR (SELECT precio FROM combos WHERE id = v_ca) = 110 THEN
      v_fallas := v_fallas || ('C3 · el encargado guardó un combo: ' || v_t);
    END IF;
  END IF;

  -- ============================================================ roles extra -
  -- R1
  v_t := pg_temp.roles(v_adm, 1, v_u, ARRAY['transportista']);
  IF v_t NOT LIKE 'PASA %'
     OR (SELECT count(*) FROM perfil_roles WHERE usuario_id = v_u AND sucursal_id = 1 AND rol = 'transportista') <> 1
     OR (SELECT created_by FROM perfil_roles WHERE usuario_id = v_u AND sucursal_id = 1) IS DISTINCT FROM v_adm THEN
    v_fallas := v_fallas || ('R1 · el admin no pudo ponerle el rol extra: ' || v_t);
  END IF;
  v_t := pg_temp.roles(v_adm, 1, v_u, ARRAY['transportista', 'transportista']);
  IF v_t NOT LIKE 'PASA %' OR (SELECT count(*) FROM perfil_roles WHERE usuario_id = v_u) <> 1 THEN
    v_fallas := v_fallas || ('R1 · repetir el rol extra cambió algo: ' || v_t);
  END IF;
  v_t := pg_temp.roles(v_adm, 1, v_u, ARRAY[]::text[]);
  IF v_t NOT LIKE 'PASA %' OR EXISTS (SELECT 1 FROM perfil_roles WHERE usuario_id = v_u) THEN
    v_fallas := v_fallas || ('R1 · el admin no pudo sacarle el rol extra: ' || v_t);
  END IF;

  -- R2
  v_t := pg_temp.roles(v_a1, 1, v_u, ARRAY['transportista']);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('R2 · el admin de una sola sucursal cambió a uno de dos: ' || v_t); END IF;
  v_t := pg_temp.roles(v_enc, 1, v_pre, ARRAY['transportista']);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('R2 · el encargado cambió roles: ' || v_t); END IF;
  v_t := pg_temp.roles(v_des, 1, v_pre, ARRAY['transportista']);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('R2 · un admin desactivado cambió roles: ' || v_t); END IF;
  v_t := pg_temp.roles(v_adm, 1, v_u2, ARRAY['transportista']);
  IF v_t NOT LIKE '%no trabaja en esta sucursal%' THEN
    v_fallas := v_fallas || ('R2 · el admin le puso un rol de la 1 a uno sólo de la 2: ' || v_t);
  END IF;
  v_t := pg_temp.roles(v_adm, 1, v_pre, ARRAY['admin']);
  IF v_t NOT LIKE '%Rol extra desconocido%' THEN v_fallas := v_fallas || ('R2 · entró un rol extra desconocido: ' || v_t); END IF;
  IF EXISTS (SELECT 1 FROM perfil_roles WHERE usuario_id IN (v_u, v_u2, v_pre)) THEN
    v_fallas := v_fallas || text 'R2 · un rechazo dejó un rol extra';
  END IF;
  v_t := pg_temp.roles(v_a1, 1, v_pre, ARRAY['transportista']);
  IF v_t NOT LIKE 'PASA %' OR NOT EXISTS (SELECT 1 FROM perfil_roles WHERE usuario_id = v_pre AND sucursal_id = 1) THEN
    v_fallas := v_fallas || ('R2 · el admin de la 1 no pudo cambiar a uno sólo de la 1: ' || v_t);
  END IF;

  -- ============================================== descuentos por categoría -
  -- D1
  v_t := pg_temp.desc_(v_adm, 1, c1, '[{"categoria":"Bebidas","descuento_porcentaje":7},{"categoria":"Limpieza","descuento_porcentaje":3}]');
  IF v_t NOT LIKE 'PASA %' OR pg_temp.descuentos(c1) <> 'Bebidas=7.00,Limpieza=3.00' THEN
    v_fallas := v_fallas || ('D1 · los descuentos no quedaron: ' || v_t || ' → ' || pg_temp.descuentos(c1));
  END IF;
  v_t := pg_temp.desc_(v_adm, 1, c1, '[{"categoria":"Bebidas","descuento_porcentaje":5},{"categoria":" bebidas ","descuento_porcentaje":4},{"categoria":"","descuento_porcentaje":9},{"categoria":"Almacén","descuento_porcentaje":10}]');
  IF v_t NOT LIKE 'PASA %' OR pg_temp.descuentos(c1) <> 'Almacén=10.00,bebidas=4.00' THEN
    v_fallas := v_fallas || ('D1 · la lista no se aplicó como se pidió: ' || v_t || ' → ' || pg_temp.descuentos(c1));
  END IF;
  v_t := pg_temp.desc_(v_adm, 1, c1, '[]');
  IF v_t NOT LIKE 'PASA %' OR pg_temp.descuentos(c1) <> '(ninguno)' THEN
    v_fallas := v_fallas || ('D1 · la lista vacía no los borró: ' || v_t);
  END IF;

  -- D2
  PERFORM pg_temp.desc_(v_adm, 1, c1, '[{"categoria":"Bebidas","descuento_porcentaje":7},{"categoria":"Limpieza","descuento_porcentaje":3}]');
  PERFORM set_config('c4b.falla', 'cliente_descuentos_categoria', true);
  v_t := pg_temp.desc_(v_adm, 1, c1, '[{"categoria":"Bebidas","descuento_porcentaje":8},{"categoria":"Limpieza","descuento_porcentaje":3}]');
  PERFORM set_config('c4b.falla', '', true);
  IF v_t NOT LIKE '%falla a propósito%' OR pg_temp.descuentos(c1) <> 'Bebidas=7.00,Limpieza=3.00' THEN
    v_fallas := v_fallas || ('D2 · un guardado que falla dejó al cliente sin sus descuentos: ' || v_t || ' → ' || pg_temp.descuentos(c1));
  END IF;

  -- D3
  v_j := '[{"categoria":"Bebidas","descuento_porcentaje":50}]';
  v_t := pg_temp.desc_(v_enc, 1, c1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('D3 · el encargado cambió descuentos: ' || v_t); END IF;
  v_t := pg_temp.desc_(v_pre, 1, c1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('D3 · el preventista cambió descuentos: ' || v_t); END IF;
  v_t := pg_temp.desc_(v_des, 1, c1, v_j);
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('D3 · un admin desactivado cambió descuentos: ' || v_t); END IF;
  v_t := pg_temp.desc_(v_adm, 1, c2, v_j);
  IF v_t NOT LIKE '%no es de esta sucursal%' THEN v_fallas := v_fallas || ('D3 · cambió descuentos de un cliente de otra sucursal: ' || v_t); END IF;
  v_t := pg_temp.desc_(v_adm, 1, c1, '[{"categoria":"Bebidas","descuento_porcentaje":150}]');
  IF v_t NOT LIKE '%de 0 a 100%' THEN v_fallas := v_fallas || ('D3 · entró un 150 %: ' || v_t); END IF;
  v_t := pg_temp.desc_(v_adm, 1, c1, '[{"categoria":"Bebidas","descuento_porcentaje":"NaN"}]');
  IF v_t NOT LIKE '%de 0 a 100%' THEN v_fallas := v_fallas || ('D3 · entró un porcentaje en texto: ' || v_t); END IF;
  IF pg_temp.descuentos(c1) <> 'Bebidas=7.00,Limpieza=3.00' OR pg_temp.descuentos(c2) <> '(ninguno)' THEN
    v_fallas := v_fallas || text 'D3 · un rechazo cambió los descuentos';
  END IF;

  -- ===================================================== v2 · combo nuevo -
  -- C5 · otro crea un combo D que compite con A después de que el editor de A cargó su lista.
  v_j := jsonb_build_object('nombre', 'ZZ C4b combo A', 'precio', 180, 'fecha_inicio', v_hoy,
    'componentes', jsonb_build_array(jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p1)),
                                     jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p2))));
  IF v_ca IS NOT NULL THEN
    v_cd := (pg_temp.j(pg_temp.combo(v_adm, 1, jsonb_set(v_j, '{nombre}', '"ZZ C4b combo D"')))->>'id')::bigint;
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca, 'precio', 150,
      'vistos', jsonb_build_array(v_ca, v_cb, v_cc)));
    IF pg_temp.j(v_t)->>'codigo' IS DISTINCT FROM 'orden_cambiado' OR v_t NOT LIKE '%ZZ C4b combo D%'
       OR (SELECT precio FROM combos WHERE id = v_ca) = 150 THEN
      v_fallas := v_fallas || ('C5 · se guardó el combo sin ver al competidor nuevo: ' || v_t);
    END IF;
    v_t := pg_temp.combo(v_adm, 1, v_j || jsonb_build_object('id', v_ca, 'precio', 150,
      'vistos', jsonb_build_array(v_ca, v_cb, v_cc, v_cd)));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true OR (SELECT precio FROM combos WHERE id = v_ca) <> 150 THEN
      v_fallas := v_fallas || ('C5 · con la lista de ahora no guardó: ' || v_t);
    END IF;
  END IF;

  -- ============================================================ v2 · cliente -
  -- K1 · el preventista da de alta y se asigna.
  v_j := jsonb_build_object('clave', kc1, 'preventista_ids', jsonb_build_array(v_pre),
    'campos', jsonb_build_object('razon_social', 'ZZ C4b K1', 'nombre_fantasia', 'ZZ C4b K1',
                                 'direccion', 'Av. Siempreviva 742', 'latitud', -26.8, 'longitud', -65.2,
                                 'tipo_documento', 'CUIT'));
  v_t := pg_temp.intenta(v_pre, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text', v_j));
  v_cl := (pg_temp.j(v_t)->'cliente'->>'id')::bigint;
  IF v_cl IS NULL
     OR (SELECT count(*) FROM clientes WHERE razon_social = 'ZZ C4b K1') <> 1
     OR NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_cl AND preventista_id = v_pre) THEN
    v_fallas := v_fallas || ('K1 · el alta del preventista no quedó entera: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_pre, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text', v_j));
  IF (pg_temp.j(v_t)->'cliente'->>'id')::bigint IS DISTINCT FROM v_cl OR (pg_temp.j(v_t)->>'replay')::boolean IS DISTINCT FROM true
     OR (SELECT count(*) FROM clientes WHERE razon_social = 'ZZ C4b K1') <> 1 THEN
    v_fallas := v_fallas || ('K1 · el reintento del alta no devolvió el mismo cliente: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_pre, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_set(v_j, '{campos,notas}', '"otra"')));
  IF v_t NOT LIKE '%ya se creó con el intento anterior%' THEN
    v_fallas := v_fallas || ('K1 · la misma clave con otro contenido no se rechazó: ' || v_t);
  END IF;

  -- K2 · todo o nada: el admin da de alta con descuentos y fallan los descuentos.
  PERFORM set_config('c4b.falla', 'cliente_descuentos_categoria', true);
  v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('clave', kc2, 'campos', jsonb_build_object('razon_social', 'ZZ C4b K2', 'nombre_fantasia', 'ZZ C4b K2',
                                                                   'direccion', 'Calle Falsa 999', 'descuento_porcentaje', 5),
                       'descuentos_categoria', '[{"categoria":"Bebidas","descuento_porcentaje":7}]'::jsonb)));
  PERFORM set_config('c4b.falla', '', true);
  IF v_t NOT LIKE '%falla a propósito%' OR EXISTS (SELECT 1 FROM clientes WHERE razon_social = 'ZZ C4b K2')
     OR pg_temp.hay_clave(kc2) THEN
    v_fallas := v_fallas || ('K2 · un alta que falla en los descuentos dejó algo: ' || v_t);
  END IF;

  -- K3 · las guardas de los triggers y las policies siguen.
  v_t := pg_temp.intenta(v_pre, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('clave', gen_random_uuid(), 'campos', jsonb_build_object('razon_social', 'ZZ C4b K3a', 'nombre_fantasia', 'ZZ C4b K3a',
                                                                                 'direccion', 'Calle 1 100', 'reservado_admin', true))));
  IF v_t NOT LIKE '42501 %' OR EXISTS (SELECT 1 FROM clientes WHERE razon_social = 'ZZ C4b K3a') THEN
    v_fallas := v_fallas || ('K3 · el preventista creó un cliente reservado: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_pre, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('clave', gen_random_uuid(), 'campos', jsonb_build_object('razon_social', 'ZZ C4b K3b', 'nombre_fantasia', 'ZZ C4b K3b',
                                                                                 'direccion', 'Calle 2 200', 'descuento_porcentaje', 10))));
  IF v_t NOT LIKE '42501 %' THEN
    v_fallas := v_fallas || ('K3 · el preventista fijó el descuento de un cliente: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_u, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('id', v_cl, 'preventista_ids', jsonb_build_array(v_pre, v_u))));
  IF v_t NOT LIKE '42501 %' OR EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_cl AND preventista_id = v_u) THEN
    v_fallas := v_fallas || ('K3 · otro preventista se asignó un cliente ajeno: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('clave', gen_random_uuid(), 'campos', jsonb_build_object('razon_social', 'ZZ C4b K3c', 'nombre_fantasia', 'ZZ C4b K3c',
                                                                                 'direccion', 'Av. Siempreviva 742', 'latitud', -26.8, 'longitud', -65.2))));
  IF v_t NOT LIKE '%Ya hay un cliente en esa dirección%' OR EXISTS (SELECT 1 FROM clientes WHERE razon_social = 'ZZ C4b K3c') THEN
    v_fallas := v_fallas || ('K3 · entró un duplicado: ' || v_t);
  END IF;

  -- K4 · la versión del cliente (el ensayo es una transacción: la vieja se escribe sin triggers).
  IF v_cl IS NOT NULL THEN
    SET LOCAL session_replication_role = replica;
    UPDATE clientes SET updated_at = '2020-01-01 00:00:00+00' WHERE id = v_cl;
    SET LOCAL session_replication_role = origin;
    UPDATE clientes SET saldo_cuenta = saldo_cuenta + 10 WHERE id = v_cl;
    UPDATE clientes SET notas = notas WHERE id = v_cl;
    IF (SELECT updated_at FROM clientes WHERE id = v_cl) IS DISTINCT FROM '2020-01-01 00:00:00+00'::timestamptz THEN
      v_fallas := v_fallas || text 'K4 · el saldo (o un UPDATE que no cambia nada) movió la versión del cliente';
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl, 'updated_at_esperado', '2019-12-31 00:00:00+00', 'campos', jsonb_build_object('notas', 'pisada'))));
    IF pg_temp.j(v_t)->>'codigo' IS DISTINCT FROM 'cliente_cambiado' OR (SELECT notas FROM clientes WHERE id = v_cl) IS NOT DISTINCT FROM 'pisada' THEN
      v_fallas := v_fallas || ('K4 · una edición con la versión vieja pisó el cliente: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl, 'updated_at_esperado', '2020-01-01 00:00:00+00', 'campos', jsonb_build_object('notas', 'buena'))));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true OR (SELECT notas FROM clientes WHERE id = v_cl) IS DISTINCT FROM 'buena'
       OR (SELECT updated_at FROM clientes WHERE id = v_cl) = '2020-01-01 00:00:00+00'::timestamptz THEN
      v_fallas := v_fallas || ('K4 · una edición con la versión de ahora no guardó o no movió la versión: ' || v_t);
    END IF;
  ELSE
    v_fallas := v_fallas || text 'K4 · sin cliente (K1 falló)';
  END IF;

  -- K5 · las guardas de la edición.
  v_t := pg_temp.intenta(v_pre, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('id', v_cl, 'campos', jsonb_build_object('limite_credito', 999999))));
  IF v_t NOT LIKE '42501 %' THEN v_fallas := v_fallas || ('K5 · el preventista cambió el límite de crédito: ' || v_t); END IF;
  v_t := pg_temp.intenta(v_u, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('id', v_cl, 'campos', jsonb_build_object('notas', 'de otro'))));
  IF v_t NOT LIKE '%no lo podés editar%' THEN v_fallas := v_fallas || ('K5 · otro preventista editó un cliente ajeno: ' || v_t); END IF;
  v_t := pg_temp.intenta(v_des, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('id', v_cl, 'campos', jsonb_build_object('notas', 'desactivado'))));
  IF v_t LIKE 'PASA %' THEN v_fallas := v_fallas || ('K5 · un admin desactivado editó un cliente: ' || v_t); END IF;
  IF v_cl IS NOT NULL AND (SELECT notas FROM clientes WHERE id = v_cl) IS DISTINCT FROM 'buena' THEN
    v_fallas := v_fallas || text 'K5 · un rechazo cambió el cliente';
  END IF;

  -- K6 · la zona manda (lo hace el trigger, no la RPC).
  INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZZ C4b zona', 1) RETURNING id INTO v_zona;
  INSERT INTO preventista_zonas (perfil_id, zona_id, sucursal_id) VALUES (v_pre, v_zona, 1);
  v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('clave', gen_random_uuid(), 'campos', jsonb_build_object('razon_social', 'ZZ C4b K6', 'nombre_fantasia', 'ZZ C4b K6',
                                                                                 'direccion', 'Ruta 9 km 1300', 'zona_id', v_zona))));
  v_cl2 := (pg_temp.j(v_t)->'cliente'->>'id')::bigint;
  IF v_cl2 IS NULL OR NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_cl2 AND preventista_id = v_pre) THEN
    v_fallas := v_fallas || ('K6 · el alta en una zona con dueño no le asignó el dueño: ' || v_t);
  ELSE
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl2, 'campos', jsonb_build_object('telefono', '000'))));
    IF v_t NOT LIKE 'PASA %' OR NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_cl2 AND preventista_id = v_pre) THEN
      v_fallas := v_fallas || ('K6 · una edición sin lista de preventistas sacó al dueño de la zona: ' || v_t);
    END IF;
  END IF;

  -- K7 · la diferencia de preventistas.
  IF v_cl2 IS NOT NULL THEN
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl2, 'preventista_ids', jsonb_build_array(v_pre), 'preventista_ids_previos', jsonb_build_array(v_u))));
    IF v_t NOT LIKE 'PASA %'
       OR (SELECT array_agg(preventista_id) FROM cliente_preventistas WHERE cliente_id = v_cl2) IS DISTINCT FROM ARRAY[v_pre] THEN
      v_fallas := v_fallas || ('K7 · con previos no quedó sólo la diferencia: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl2, 'preventista_ids', '[]'::jsonb)));
    IF v_t NOT LIKE 'PASA %' OR EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_cl2) THEN
      v_fallas := v_fallas || ('K7 · sin previos, la lista vacía no sacó al dueño: ' || v_t);
    END IF;
  ELSE
    v_fallas := v_fallas || text 'K7 · sin cliente (K6 falló)';
  END IF;

  -- ============================================================ v2 · usuario -
  v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_usuario(%L::jsonb)::text',
    jsonb_build_object('id', v_u, 'campos', jsonb_build_object('nombre', 'ZZ C4b U nuevo'), 'roles_extra', jsonb_build_array('transportista'))));
  IF v_t NOT LIKE 'PASA %' OR (SELECT nombre FROM perfiles WHERE id = v_u) IS DISTINCT FROM 'ZZ C4b U nuevo'
     OR NOT EXISTS (SELECT 1 FROM perfil_roles WHERE usuario_id = v_u AND sucursal_id = 1 AND rol = 'transportista') THEN
    v_fallas := v_fallas || ('U1 · guardar el usuario no dejó el nombre y el rol extra: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_usuario(%L::jsonb)::text',
    jsonb_build_object('id', v_u, 'campos', jsonb_build_object('nombre', 'ZZ C4b U roto'), 'roles_extra', jsonb_build_array('admin'))));
  IF v_t NOT LIKE '%Rol extra desconocido%' OR (SELECT nombre FROM perfiles WHERE id = v_u) IS DISTINCT FROM 'ZZ C4b U nuevo' THEN
    v_fallas := v_fallas || ('U1 · con un rol extra inválido quedó el nombre: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_a1, 1, format('SELECT public.guardar_usuario(%L::jsonb)::text',
    jsonb_build_object('id', v_u, 'campos', jsonb_build_object('nombre', 'ZZ C4b U de a1'))));
  IF v_t NOT LIKE '%No podés editar a este usuario%' OR (SELECT nombre FROM perfiles WHERE id = v_u) IS DISTINCT FROM 'ZZ C4b U nuevo' THEN
    v_fallas := v_fallas || ('U1 · el admin de una sola sucursal editó a uno de dos: ' || v_t);
  END IF;

  -- ================================================ v3 · revisión adversarial -
  -- P7 (H2) · la versión de la promo se mueve si cambian sólo productos, sólo reglas, sólo el regalo o
  -- los tres; y con la versión de antes, el guardado se rechaza y no borra lo que puso el otro.
  IF v_pr IS NOT NULL THEN
    FOR v_k IN 1..4 LOOP
      v_ts := (SELECT updated_at FROM promociones WHERE id = v_pr);
      v_j := jsonb_build_object('updated_at_esperado', v_ts,
        'producto_ids', CASE WHEN v_k IN (1, 4) THEN jsonb_build_array(p1, p2, CASE WHEN v_k = 1 THEN p4 ELSE p3 END)
                             ELSE (SELECT jsonb_agg(producto_id ORDER BY producto_id) FROM promocion_productos WHERE promocion_id = v_pr) END,
        'reglas', CASE WHEN v_k IN (2, 4) THEN jsonb_build_array(jsonb_build_object('clave', 'cantidad_compra', 'valor', 10 + v_k),
                                                                  jsonb_build_object('clave', 'cantidad_bonificacion', 'valor', 1))
                       ELSE (SELECT jsonb_agg(jsonb_build_object('clave', clave, 'valor', valor) ORDER BY clave) FROM promocion_reglas WHERE promocion_id = v_pr) END);
      v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.cambiar_regalo_promocion(%s, %s, NULL, false, %L::jsonb)::text',
        v_pr, CASE WHEN v_k IN (3, 4) THEN p4 ELSE (SELECT producto_regalo_id FROM promociones WHERE id = v_pr) END, v_j));
      IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true
         OR (SELECT updated_at FROM promociones WHERE id = v_pr) IS NOT DISTINCT FROM v_ts THEN
        v_fallas := v_fallas || format('P7.%s · el cambio (%s) no movió la versión de la promo: %s', v_k,
          (ARRAY['sólo productos', 'sólo reglas', 'sólo el regalo', 'los tres'])[v_k], v_t);
      END IF;
      -- B, con la versión de antes, manda la lista de antes: se rechaza.
      v_n := (SELECT count(*) FROM promocion_productos WHERE promocion_id = v_pr);
      v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.cambiar_regalo_promocion(%s, %s, NULL, false, %L::jsonb)::text',
        v_pr, (SELECT producto_regalo_id FROM promociones WHERE id = v_pr),
        jsonb_build_object('updated_at_esperado', v_ts, 'producto_ids', jsonb_build_array(p1))));
      IF pg_temp.j(v_t)->>'codigo' IS DISTINCT FROM 'promocion_cambiada'
         OR (SELECT count(*) FROM promocion_productos WHERE promocion_id = v_pr) <> v_n THEN
        v_fallas := v_fallas || format('P7.%s · con la versión de antes pisó lo del otro: %s', v_k, v_t);
      END IF;
    END LOOP;
  ELSE
    v_fallas := v_fallas || text 'P7 · sin promo (P1 falló)';
  END IF;

  -- K8 (H3) · la versión del cliente se mueve si cambian sólo los descuentos o sólo los preventistas.
  IF v_cl IS NOT NULL THEN
    v_ts := (SELECT updated_at FROM clientes WHERE id = v_cl);
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl, 'updated_at_esperado', v_ts, 'descuentos_categoria', '[{"categoria":"Gaseosas","descuento_porcentaje":10}]'::jsonb)));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true
       OR (SELECT updated_at FROM clientes WHERE id = v_cl) IS NOT DISTINCT FROM v_ts THEN
      v_fallas := v_fallas || ('K8 · cambiar sólo los descuentos no movió la versión del cliente: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl, 'updated_at_esperado', v_ts, 'campos', jsonb_build_object('notas', 'pisa'),
                         'descuentos_categoria', '[]'::jsonb)));
    IF pg_temp.j(v_t)->>'codigo' IS DISTINCT FROM 'cliente_cambiado' OR pg_temp.descuentos(v_cl) <> 'Gaseosas=10.00' THEN
      v_fallas := v_fallas || ('K8 · la ficha vieja borró los descuentos del otro: ' || v_t);
    END IF;
    v_ts := (SELECT updated_at FROM clientes WHERE id = v_cl);
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl, 'updated_at_esperado', v_ts, 'preventista_ids', '[]'::jsonb,
                         'preventista_ids_previos', jsonb_build_array(v_pre))));
    IF (pg_temp.j(v_t)->>'success')::boolean IS DISTINCT FROM true
       OR (SELECT updated_at FROM clientes WHERE id = v_cl) IS NOT DISTINCT FROM v_ts THEN
      v_fallas := v_fallas || ('K8 · cambiar sólo los preventistas no movió la versión del cliente: ' || v_t);
    END IF;
    v_ts := (SELECT updated_at FROM clientes WHERE id = v_cl);
    UPDATE clientes SET saldo_cuenta = saldo_cuenta + 1 WHERE id = v_cl;
    IF (SELECT updated_at FROM clientes WHERE id = v_cl) IS DISTINCT FROM v_ts THEN
      v_fallas := v_fallas || text 'K8 · el saldo movió la versión del cliente';
    END IF;
  END IF;

  -- K9 (D2) · el admin elige a alguien de la sucursal del cliente (#1374): uno sólo de la 2, no.
  IF v_cl IS NOT NULL THEN
    v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_cliente(%L::jsonb)::text',
      jsonb_build_object('id', v_cl, 'preventista_ids', jsonb_build_array(v_u2), 'preventista_ids_previos', '[]'::jsonb)));
    IF v_t NOT LIKE '42501 %' OR EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_cl AND preventista_id = v_u2) THEN
      v_fallas := v_fallas || ('K9 · el admin asignó a un preventista de otra sucursal: ' || v_t);
    END IF;
  END IF;

  -- U2 (D1) · nadie se edita a sí mismo: ni el perfil ni los roles extra.
  v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.guardar_usuario(%L::jsonb)::text',
    jsonb_build_object('id', v_adm, 'campos', jsonb_build_object('nombre', 'ZZ C4b yo'))));
  IF v_t NOT LIKE '%No podés editar tu propio usuario%' OR (SELECT nombre FROM perfiles WHERE id = v_adm) = 'ZZ C4b yo' THEN
    v_fallas := v_fallas || ('U2 · el admin se editó a sí mismo: ' || v_t);
  END IF;
  v_t := pg_temp.roles(v_adm, 1, v_adm, ARRAY['transportista']);
  IF v_t NOT LIKE '%No podés cambiar tus propios roles%' OR EXISTS (SELECT 1 FROM perfil_roles WHERE usuario_id = v_adm) THEN
    v_fallas := v_fallas || ('U2 · el admin se dio un rol extra a sí mismo: ' || v_t);
  END IF;

  -- C6 (H5) · un nulo en `vistos` no apaga la guarda: se rechaza el formato.
  IF v_ca IS NOT NULL THEN
    v_t := pg_temp.combo(v_adm, 1, jsonb_build_object('id', v_ca, 'nombre', 'ZZ C4b combo A', 'precio', 150, 'fecha_inicio', v_hoy,
      'componentes', jsonb_build_array(jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p1)),
                                       jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p2))),
      'vistos', '[null]'::jsonb));
    IF v_t NOT LIKE '%formato inválido%' THEN
      v_fallas := v_fallas || ('C6 · un nulo en vistos no se rechazó: ' || v_t);
    END IF;
  END IF;

  -- A1 (H4) · la clave guarda sólo un md5.
  v_t := pg_temp.intenta(v_pre, 1, format('SELECT public._alta_cliente_tomar_clave(%L::uuid, %L)::text', gen_random_uuid(), repeat('x', 10000)));
  IF v_t NOT LIKE '%no tiene la forma esperada%' THEN
    v_fallas := v_fallas || ('A1 · la clave aceptó un contenido que no es un md5: ' || left(v_t, 200));
  END IF;
  IF to_regclass('public.altas_por_clave') IS NOT NULL THEN
    BEGIN
      EXECUTE format('INSERT INTO public.altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido) VALUES (%L, %L, %L, 1, %L)',
                     gen_random_uuid(), 'cliente', v_pre, repeat('x', 100));
      v_fallas := v_fallas || text 'A1 · altas_por_clave aceptó un contenido que no es un md5';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
  ELSE
    v_fallas := v_fallas || text 'A1 · no existe altas_por_clave';
  END IF;

  -- ============================================================= seguridad -
  -- S1
  FOR v_t IN SELECT unnest(ARRAY['public.guardar_condicion_mayorista(jsonb)', 'public.crear_promocion(jsonb)',
                                 'public.guardar_roles_extra(uuid,text[])', 'public.guardar_descuentos_categoria(bigint,jsonb)']) LOOP
    IF to_regprocedure(v_t) IS NULL THEN
      v_fallas := v_fallas || ('S1 · no existe ' || v_t);
      CONTINUE;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_t))
       OR NOT EXISTS (SELECT 1 FROM pg_proc, unnest(proconfig) c WHERE oid = to_regprocedure(v_t) AND c LIKE 'search_path=%pg_temp')
       OR has_function_privilege('anon', to_regprocedure(v_t), 'EXECUTE')
       OR NOT has_function_privilege('authenticated', to_regprocedure(v_t), 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc, aclexplode(proacl) a WHERE oid = to_regprocedure(v_t) AND a.grantee = 0) THEN
      v_fallas := v_fallas || ('S1 · ' || v_t || ' no es definer con pg_temp y EXECUTE sólo para authenticated');
    END IF;
  END LOOP;
  IF to_regclass('public.altas_por_clave') IS NULL
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.altas_por_clave'))
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = to_regclass('public.altas_por_clave'))
     OR EXISTS (SELECT 1 FROM information_schema.role_table_grants
                 WHERE table_schema = 'public' AND table_name = 'altas_por_clave' AND grantee IN ('anon', 'authenticated', 'PUBLIC')) THEN
    v_fallas := v_fallas || text 'S1 · altas_por_clave no es sólo de server';
  END IF;

  -- S2
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        AND proname IN ('guardar_combo', 'cambiar_regalo_promocion')) <> 2
     OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                  AND p.proname IN ('guardar_combo', 'cambiar_regalo_promocion', 'update_promociones_updated_at')
                  AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%pg_temp')) THEN
    v_fallas := v_fallas || text 'S2 · guardar_combo o cambiar_regalo_promocion: una sobrecarga o sin pg_temp en el search_path';
  END IF;

 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE 'ENSAYO%' THEN RAISE; END IF;
  RAISE EXCEPTION 'ENSAYO FALLO · se cortó con % %', SQLSTATE, SQLERRM;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (% casos)', v_casos;
END
$ensayo$;
