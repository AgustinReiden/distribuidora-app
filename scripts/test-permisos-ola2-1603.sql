-- Ensayo de la tarjeta B9 de la ola 2 del plan #1603: permisos, policies y funciones sin uso.
-- Migración: NNN_permisos_policies_y_funciones_sin_uso.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Cada caso corre
-- como cada rol (SET LOCAL ROLE authenticated + request.jwt.claims, parado en la sucursal 1):
-- admin de la 1, admin de las dos, encargado, preventista, chofer, depósito y un encargado
-- desactivado. Sin la migración fallan todos los casos menos los que dicen «regresión».
--
--   P1  · 1558-b3   mt_productos_update ya no nombra al depósito; el depósito sigue sin tocar productos.
--   P2  · 1561-b6   el preventista no crea un comodín ni el encargado lo marca; el admin sí; el
--                   encargado edita un comodín sin tocar la marca (regresión).
--   P3  · SEG-3, 1564-b10, SEG-4  las trece funciones sin llamador no existen; las cinco de server no
--                   las ejecuta authenticated, y el server sí (tablero_cobertura).
--   P4  · SEG-5     el admin de una sucursal no ve la auditoría de rendicion_faltantes (tiene
--                   empleado_id) ni la de empleados; ve la de clientes; el admin de las dos ve todo.
--   P5  · SEG-6     _empleado_visible sin CR (_guardar_gasto la recrea B8a).
--   P6  · 1564-b1   un desactivado no cambia de sucursal ni genera el código del bot; uno activo sí.
--   P7  · 1564-b4   el admin de una sola sucursal no crea ni edita un encuadre de II; el de las dos sí.
--   P8  · 1564-b5   la vista audit_logs_detallado no existe.
--   P9  · 1564-b6   politica_comercial_reservada() le da la fila a admin y encargado, y a nadie más
--                   (ni al desactivado). Los grants de lectura no cambian (la parte 2 va después): el
--                   preventista lee el select del front y, todavía, lo reservado por REST.
--   P10 · 1564-b7   no se hace (decisión de coordinación): no hay caso.
--   P11 · 1564-b11  auditoria_rol_sin_activo() devuelve las policies, y ninguna; el depósito sigue
--                   viendo proveedores y el desactivado no (regresión).
--   P12 · 1564-b12  el chofer ve sólo el cliente de su pedido; el preventista, los libres y los suyos;
--                   encargado y admin, todos; depósito y desactivado, ninguno; el depósito con el
--                   extra de chofer, el cliente de lo que reparte (H7).
--   P13 · 1601-b5   el historial de stock lo leen admin, encargado y depósito; preventista y chofer no.
--   P14 · 1541-1    auditoria_locks() ve el lock de la 447 de cancelar_pedido_con_stock, y los helpers
--                   de texto entienden un literal con -- adentro.
--   P15 · 1564-b12  obtener_resumen_cuenta_cliente sigue la misma regla (H4): el chofer recibe la cuenta
--                   del cliente que reparte y 42501 para cualquier otro (libre o reservado); el
--                   preventista, 42501 para el cliente de otro; el encargado, la de todos.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-permisos-ola2-1603.sql

DO $ensayo$
DECLARE
  v_adm1   uuid;
  v_admT   uuid;
  v_enc    uuid;
  v_pre    uuid;
  v_pre2   uuid;
  v_tra    uuid;
  v_dep    uuid;
  v_depT   uuid;
  v_des    uuid;
  v_libre  bigint;
  v_mio    bigint;
  v_otro   bigint;
  v_res    bigint;
  v_rep    bigint;
  v_com    bigint;
  v_cdep   bigint;
  v_prod   bigint;
  v_enc_ii bigint;
  v_ids    text;
  v_t      text;
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
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b9-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'B9 ' || p_rol), now(), now());
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

  -- --------------------------------------------------------------- fixtures -
  v_adm1 := pg_temp.u('admin', 1);
  v_admT := pg_temp.u('admin', 1);
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_admT, 2, false);
  v_enc  := pg_temp.u('encargado', 1);
  v_pre  := pg_temp.u('preventista', 1);
  v_pre2 := pg_temp.u('preventista', 1);
  v_tra  := pg_temp.u('transportista', 1);
  v_dep  := pg_temp.u('deposito', 1);
  v_depT := pg_temp.u('deposito', 1);
  INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_depT, 1, 'transportista');
  v_des  := pg_temp.u('encargado', 1);
  -- La copia local tiene un auth.users mínimo, sin la columna que escribe perfiles_sync_acceso_auth
  -- al desactivar: ahí ese trigger se apaga para este UPDATE (el ban de Auth no es lo que se prueba:
  -- el token del desactivado sigue vivo igual). Se deshace con el resto del ensayo.
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'auth.users'::regclass AND attname = 'banned_until') THEN
    ALTER TABLE public.perfiles DISABLE TRIGGER trg_perfiles_sync_acceso_auth;
    UPDATE perfiles SET activo = false WHERE id = v_des;
    ALTER TABLE public.perfiles ENABLE TRIGGER trg_perfiles_sync_acceso_auth;
  ELSE
    UPDATE perfiles SET activo = false WHERE id = v_des;
  END IF;

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('B9 libre', 'B9 libre', 'Calle Falsa 1', 1) RETURNING id INTO v_libre;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('B9 mio', 'B9 mio', 'Calle Falsa 2', 1) RETURNING id INTO v_mio;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('B9 otro', 'B9 otro', 'Calle Falsa 3', 1) RETURNING id INTO v_otro;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, reservado_admin)
  VALUES ('B9 reservado', 'B9 reservado', 'Calle Falsa 4', 1, true) RETURNING id INTO v_res;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('B9 reparto', 'B9 reparto', 'Calle Falsa 5', 1) RETURNING id INTO v_rep;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, es_comodin)
  VALUES ('B9 comodin', 'B9 comodin', 'Mostrador', 1, true) RETURNING id INTO v_com;
  INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_mio, v_pre), (v_otro, v_pre2), (v_rep, v_pre2);
  -- Un pedido de pre2 que reparte el chofer.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura, transportista_id)
  VALUES (v_rep, 1, v_pre2, 0, 'asignado', public._tablero_hoy(), 'app', 'ZZ', v_tra);
  -- Un cliente libre con un pedido que reparte el depósito con el extra de chofer.
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('B9 reparto dep', 'B9 reparto dep', 'Calle Falsa 6', 1) RETURNING id INTO v_cdep;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura, transportista_id)
  VALUES (v_cdep, 1, v_pre2, 0, 'asignado', public._tablero_hoy(), 'app', 'ZZ', v_depT);
  v_ids := format('(%s,%s,%s,%s,%s,%s,%s)', v_libre, v_mio, v_otro, v_res, v_rep, v_com, v_cdep);

  INSERT INTO productos (nombre, precio, stock, sucursal_id) VALUES ('B9 prod ' || gen_random_uuid(), 100, 10, 1)
  RETURNING id INTO v_prod;
  INSERT INTO stock_historico (producto_id, stock_anterior, stock_nuevo, sucursal_id, origen)
  VALUES (v_prod, 10, 12, 1, 'ajuste_manual');
  INSERT INTO proveedores (nombre, sucursal_id) VALUES ('B9 proveedor ' || gen_random_uuid(), 1);
  INSERT INTO politicas_comerciales (sucursal_id, monto_minimo_pedido, comision_pct_otros, combo_margen_minimo_pct)
  VALUES (1, 5000, 3, 12)
  ON CONFLICT (sucursal_id) DO UPDATE SET monto_minimo_pedido = 5000, comision_pct_otros = 3, combo_margen_minimo_pct = 12;
  INSERT INTO ii_encuadres (nombre) VALUES ('B9 encuadre ' || gen_random_uuid()) RETURNING id INTO v_enc_ii;
  INSERT INTO audit_logs (tabla, registro_id, accion, sucursal_id)
  VALUES ('rendicion_faltantes', 'b9', 'INSERT', 1), ('empleados', 'b9', 'INSERT', 1), ('clientes', 'b9', 'INSERT', 1);

  -- ------------------------------------------------------------ P1 · 1558-b3 -
  SELECT coalesce(qual, '') || coalesce(with_check, '') INTO v_t
    FROM pg_policies WHERE tablename = 'productos' AND policyname = 'mt_productos_update';
  IF v_t ~ 'deposito' THEN
    v_fallas := v_fallas || 'P1 · mt_productos_update todavía tiene la rama depósito'::text;
  END IF;
  v_t := pg_temp.intenta(v_dep, format('WITH u AS (UPDATE productos SET stock = 11 WHERE id = %s RETURNING 1) SELECT count(*) FROM u', v_prod));
  IF v_t NOT IN ('PASA 0') THEN
    v_fallas := v_fallas || ('P1 · el depósito tocó productos (regresión): ' || v_t);
  END IF;

  -- ------------------------------------------------------------ P2 · 1561-b6 -
  v_t := pg_temp.intenta(v_pre, $q$INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, es_comodin)
                                   VALUES ('B9 com pre', 'B9 com pre', 'X', 1, true) RETURNING 'ok'$q$);
  IF v_t NOT LIKE '42501%' THEN
    v_fallas := v_fallas || ('P2 · el preventista creó un comodín: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_enc, format('WITH u AS (UPDATE clientes SET es_comodin = true WHERE id = %s RETURNING 1) SELECT count(*) FROM u', v_libre));
  IF v_t NOT LIKE '42501%' THEN
    v_fallas := v_fallas || ('P2 · el encargado marcó un comodín: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_enc, format('WITH u AS (UPDATE clientes SET es_comodin = false WHERE id = %s RETURNING 1) SELECT count(*) FROM u', v_com));
  IF v_t NOT LIKE '42501%' THEN
    v_fallas := v_fallas || ('P2 · el encargado desmarcó un comodín: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_enc, format($q$WITH u AS (UPDATE clientes SET nombre_fantasia = 'B9 comodin 2' WHERE id = %s RETURNING 1) SELECT count(*) FROM u$q$, v_com));
  IF v_t <> 'PASA 1' THEN
    v_fallas := v_fallas || ('P2 · el encargado no pudo editar un comodín sin tocar la marca (regresión): ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm1, $q$INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, es_comodin)
                                    VALUES ('B9 com adm', 'B9 com adm', 'X', 1, true) RETURNING 'ok'$q$);
  IF v_t <> 'PASA ok' THEN
    v_fallas := v_fallas || ('P2 · el admin no pudo crear un comodín (regresión): ' || v_t);
  END IF;

  -- ------------------------------------------------- P3 · SEG-3, b10, SEG-4 -
  SELECT string_agg(f, ', ') INTO v_t FROM unnest(ARRAY[
      'public.tablero_buscar_clientes(text,bigint,integer)', 'public.tablero_clientes_inactivos(bigint,integer,boolean)',
      'public.tablero_contexto()', 'public.tablero_ficha_cliente(bigint)',
      'public.tablero_guardar_meta_cobertura(bigint,date,numeric,integer)', 'public.tablero_kpis(bigint,integer)',
      'public.tablero_productos_categoria(uuid,text,bigint,date,date,bigint)', 'public.guardar_horarios_clientes_masivo(jsonb)',
      'public.obtener_resumen_compras(date,date)', 'public.obtener_sucursales_usuario()',
      'public.desasignar_usuario_sucursal(uuid,bigint)', 'public.get_audit_history(text,text,integer)',
      'public.get_suspicious_activity(integer)']) AS f
   WHERE to_regprocedure(f) IS NOT NULL;
  IF v_t IS NOT NULL THEN
    v_fallas := v_fallas || ('P3 · siguen existiendo: ' || v_t);
  END IF;
  -- _tablero_cat_nombre (desde la 514 la llamaba sólo tablero_productos_categoria): si nadie la
  -- nombra, no queda huérfana.
  IF to_regprocedure('public._tablero_cat_nombre(text)') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                       AND p.proname <> '_tablero_cat_nombre' AND p.prosrc ~ '\m_tablero_cat_nombre\M') THEN
    v_fallas := v_fallas || 'P3 · _tablero_cat_nombre quedó huérfana'::text;
  END IF;
  SELECT string_agg(f, ', ') INTO v_t FROM unnest(ARRAY[
      'public.tablero_categorias(bigint,date,date,bigint)', 'public.tablero_facturacion_mensual(bigint,integer)',
      'public.tablero_top_clientes_zona(bigint,date,date,integer,integer)', 'public.tablero_cobertura(bigint,date)',
      'public.guardar_analisis_mensual(bigint,date,text,jsonb)']) AS f
   WHERE has_function_privilege('authenticated', f, 'EXECUTE');
  IF v_t IS NOT NULL THEN
    v_fallas := v_fallas || ('P3 · authenticated todavía ejecuta: ' || v_t);
  END IF;
  BEGIN
    PERFORM public.tablero_cobertura(1, date_trunc('month', public._tablero_hoy())::date);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P3 · el server no pudo llamar a tablero_cobertura (regresión): ' || SQLERRM);
  END;

  -- ------------------------------------------------------------ P4 · SEG-5 --
  v_t := pg_temp.intenta(v_adm1, $q$SELECT string_agg(tabla, ',' ORDER BY tabla) FROM audit_logs WHERE registro_id = 'b9'$q$);
  IF v_t <> 'PASA clientes' THEN
    v_fallas := v_fallas || ('P4 · el admin de una sucursal ve auditoría de personal: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_admT, $q$SELECT string_agg(tabla, ',' ORDER BY tabla) FROM audit_logs WHERE registro_id = 'b9'$q$);
  IF v_t <> 'PASA clientes,empleados,rendicion_faltantes' THEN
    v_fallas := v_fallas || ('P4 · el admin de las dos no ve toda la auditoría (regresión): ' || v_t);
  END IF;

  -- ------------------------------------------------------------ P5 · SEG-6 --
  SELECT string_agg(proname, ', ') INTO v_t FROM pg_proc
   WHERE proname IN ('_empleado_visible') AND position(E'\r' in prosrc) > 0;
  IF v_t IS NOT NULL THEN
    v_fallas := v_fallas || ('P5 · con CR: ' || v_t);
  END IF;

  -- ------------------------------------------------------------ P6 · 1564-b1 -
  v_t := pg_temp.intenta(v_des, $q$SELECT public.cambiar_sucursal(1)->>'success'$q$);
  IF v_t <> 'PASA false' THEN
    v_fallas := v_fallas || ('P6 · el desactivado cambió de sucursal: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_des, $q$SELECT public.generar_codigo_vinculacion_bot()->>'codigo'$q$);
  IF v_t NOT LIKE '42501%' THEN
    v_fallas := v_fallas || ('P6 · el desactivado generó un código del bot: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_pre, $q$SELECT public.cambiar_sucursal(1)->>'success'$q$);
  IF v_t <> 'PASA true' THEN
    v_fallas := v_fallas || ('P6 · un activo no pudo cambiar de sucursal (regresión): ' || v_t);
  END IF;

  -- ------------------------------------------------------------ P7 · 1564-b4 -
  v_t := pg_temp.intenta(v_adm1, $q$INSERT INTO ii_encuadres (nombre) VALUES ('B9 de una ' || gen_random_uuid()) RETURNING 'ok'$q$);
  IF v_t NOT LIKE '42501%' THEN
    v_fallas := v_fallas || ('P7 · el admin de una sola sucursal creó un encuadre: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm1, format($q$WITH u AS (UPDATE ii_encuadres SET criterio = 'x' WHERE id = %s RETURNING 1) SELECT count(*) FROM u$q$, v_enc_ii));
  IF v_t <> 'PASA 0' THEN
    v_fallas := v_fallas || ('P7 · el admin de una sola sucursal editó un encuadre: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_admT, format($q$WITH u AS (UPDATE ii_encuadres SET criterio = 'x' WHERE id = %s RETURNING 1) SELECT count(*) FROM u$q$, v_enc_ii));
  IF v_t <> 'PASA 1' THEN
    v_fallas := v_fallas || ('P7 · el admin de las dos no pudo editar un encuadre (regresión): ' || v_t);
  END IF;

  -- ------------------------------------------------------------ P8 · 1564-b5 -
  IF to_regclass('public.audit_logs_detallado') IS NOT NULL THEN
    v_fallas := v_fallas || 'P8 · la vista audit_logs_detallado sigue existiendo'::text;
  END IF;

  -- ------------------------------------------------------------ P9 · 1564-b6 -
  v_t := pg_temp.intenta(v_pre, 'SELECT count(*) FROM (SELECT monto_minimo_pedido, modo_minimo_pedido, monto_envio_gratis, '
                              || 'cargo_envio_pedido, mostrar_sin_stock, dias_atras_fecha_pedido, dias_alerta_vencimiento, '
                              || 'dias_critico_vencimiento, multiplo_redondeo_precio FROM politicas_comerciales) x');
  IF v_t <> 'PASA 1' THEN
    v_fallas := v_fallas || ('P9 · el preventista no lee lo de vender (regresión): ' || v_t);
  END IF;
  -- La parte 1 no toca los grants: un bundle viejo del PWA sigue leyendo lo reservado por REST.
  v_t := pg_temp.intenta(v_pre, 'SELECT comision_pct_otros::text FROM politicas_comerciales');
  IF v_t NOT LIKE 'PASA %' THEN
    v_fallas := v_fallas || ('P9 · la parte 1 no tenía que sacar el SELECT de lo reservado (bundle viejo): ' || v_t);
  END IF;
  IF to_regproc('public.politica_comercial_reservada') IS NULL THEN
    v_fallas := v_fallas || 'P9 · no existe politica_comercial_reservada()'::text;
  ELSE
    v_t := pg_temp.intenta(v_enc, 'SELECT (comision_pct_otros = 3 AND combo_margen_minimo_pct = 12)::text FROM public.politica_comercial_reservada()');
    IF v_t <> 'PASA true' THEN
      v_fallas := v_fallas || ('P9 · el encargado no recibe lo reservado: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm1, 'SELECT count(*) FROM public.politica_comercial_reservada()');
    IF v_t <> 'PASA 1' THEN
      v_fallas := v_fallas || ('P9 · el admin no recibe lo reservado: ' || v_t);
    END IF;
    FOR v_t IN SELECT pg_temp.intenta(u, 'SELECT count(*) FROM public.politica_comercial_reservada()')
                 FROM unnest(ARRAY[v_pre, v_tra, v_dep, v_des]) AS u LOOP
      IF v_t <> 'PASA 0' THEN
        v_fallas := v_fallas || ('P9 · alguien que no es admin ni encargado recibe lo reservado: ' || v_t);
      END IF;
    END LOOP;
  END IF;

  -- ---------------------------------------------------------- P11 · 1564-b11 -
  IF public.auditoria_rol_sin_activo()->'policies' IS NULL THEN
    v_fallas := v_fallas || 'P11 · auditoria_rol_sin_activo() no mira las policies'::text;
  ELSIF jsonb_array_length(public.auditoria_rol_sin_activo()->'policies') > 0 THEN
    v_fallas := v_fallas || ('P11 · policies que leen el rol sin activo: ' || (public.auditoria_rol_sin_activo()->'policies')::text);
  END IF;
  v_t := pg_temp.intenta(v_dep, $q$SELECT count(*) FROM proveedores WHERE nombre LIKE 'B9 proveedor%'$q$);
  IF v_t <> 'PASA 1' THEN
    v_fallas := v_fallas || ('P11 · el depósito no ve proveedores (regresión): ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_des, $q$SELECT count(*) FROM proveedores WHERE nombre LIKE 'B9 proveedor%'$q$);
  IF v_t <> 'PASA 0' THEN
    v_fallas := v_fallas || ('P11 · el desactivado ve proveedores (regresión): ' || v_t);
  END IF;

  -- ---------------------------------------------------------- P12 · 1564-b12 -
  FOR v_t IN
    SELECT format('%s:%s', quien, r) FROM (VALUES
        ('chofer', v_tra, format('%s', v_rep)),
        ('preventista', v_pre, format('%s,%s,%s,%s', v_libre, v_mio, v_com, v_cdep)),
        ('encargado', v_enc, format('%s,%s,%s,%s,%s,%s,%s', v_libre, v_mio, v_otro, v_res, v_rep, v_com, v_cdep)),
        ('admin', v_adm1, format('%s,%s,%s,%s,%s,%s,%s', v_libre, v_mio, v_otro, v_res, v_rep, v_com, v_cdep)),
        ('depósito', v_dep, ''),
        ('depósito con el extra de chofer', v_depT, format('%s', v_cdep)),
        ('desactivado', v_des, '')
      ) AS t(quien, u, esperado),
      LATERAL (SELECT pg_temp.intenta(u, format('SELECT COALESCE(string_agg(id::text, '','' ORDER BY id), '''') FROM clientes WHERE id IN %s', v_ids)) AS visto) s,
      LATERAL (SELECT CASE WHEN s.visto = 'PASA ' || esperado THEN NULL ELSE s.visto || ' (esperado ' || esperado || ')' END AS r) c
     WHERE c.r IS NOT NULL
  LOOP
    v_fallas := v_fallas || ('P12 · clientes visibles: ' || v_t);
  END LOOP;

  -- ----------------------------------------------------------- P13 · 1601-b5 -
  FOR v_t IN
    SELECT format('%s ve %s (esperado %s)', quien, s.visto, esperado) FROM (VALUES
        ('preventista', v_pre, 'PASA 0'), ('chofer', v_tra, 'PASA 0'), ('desactivado', v_des, 'PASA 0'),
        ('encargado', v_enc, 'PASA 1'), ('admin', v_adm1, 'PASA 1'), ('depósito', v_dep, 'PASA 1')
      ) AS t(quien, u, esperado),
      LATERAL (SELECT pg_temp.intenta(u, format('SELECT count(*) FROM stock_historico WHERE producto_id = %s', v_prod)) AS visto) s
     WHERE s.visto <> esperado
  LOOP
    v_fallas := v_fallas || ('P13 · historial de stock: ' || v_t);
  END LOOP;

  -- ------------------------------------------------------------ P14 · 1541-1 -
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_locks()->'sentencias') s
                  WHERE s->>'firma' LIKE 'cancelar_pedido_con_stock(%' AND s->>'sentencia' LIKE '%FOR NO KEY UPDATE%') THEN
    v_fallas := v_fallas || 'P14 · auditoria_locks() no ve el lock de la 447 de cancelar_pedido_con_stock'::text;
  END IF;
  IF to_regproc('public._sql_sin_comentarios_ni_literales') IS NULL THEN
    v_fallas := v_fallas || 'P14 · no existe _sql_sin_comentarios_ni_literales()'::text;
  ELSE
    EXECUTE $q$SELECT public._sql_sin_comentarios_ni_literales($x$a := ' -- ' || b; -- c
PERFORM 1 FROM t WHERE x = 'it''s' FOR UPDATE; /* d ' */ y := '/* no */';$x$)$q$ INTO v_t;
    IF v_t <> E'a := \'\' || b; \nPERFORM 1 FROM t WHERE x = \'\' FOR UPDATE;  y := \'\';' THEN
      v_fallas := v_fallas || ('P14 · _sql_sin_comentarios_ni_literales: ' || v_t);
    END IF;
    EXECUTE $q$SELECT public._sql_sin_comentarios($x$a := ' -- ' || b; -- c$x$)$q$ INTO v_t;
    IF v_t <> $x$a := ' -- ' || b; $x$ THEN
      v_fallas := v_fallas || ('P14 · _sql_sin_comentarios: ' || v_t);
    END IF;
  END IF;

  -- ---------------------------------------------------------- P15 · 1564-b12 -
  FOR v_t IN
    SELECT format('%s, cliente %s: %s (esperado %s)', quien, cli, s.visto, esperado) FROM (VALUES
        ('chofer', v_tra, v_rep, 'PASA'), ('chofer', v_tra, v_libre, '42501'), ('chofer', v_tra, v_res, '42501'),
        ('preventista', v_pre, v_otro, '42501'), ('preventista', v_pre, v_mio, 'PASA'),
        ('encargado', v_enc, v_otro, 'PASA'), ('encargado', v_enc, v_res, 'PASA'),
        ('depósito con el extra de chofer', v_depT, v_cdep, 'PASA'), ('depósito', v_dep, v_cdep, '42501'),
        ('desactivado', v_des, v_libre, '42501')
      ) AS t(quien, u, cli, esperado),
      LATERAL (SELECT pg_temp.intenta(u, format('SELECT (public.obtener_resumen_cuenta_cliente(%s)->>''saldo_actual'') IS NOT NULL', cli)) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || ('P15 · obtener_resumen_cuenta_cliente: ' || v_t);
  END LOOP;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK%', CASE WHEN cardinality(v_notas) > 0 THEN E'\n  nota: ' || array_to_string(v_notas, E'\n  nota: ') ELSE '' END
      USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
    || CASE WHEN cardinality(v_notas) > 0 THEN E'\n  nota: ' || array_to_string(v_notas, E'\n  nota: ') ELSE '' END
    USING ERRCODE = 'P0001';
 END;
END
$ensayo$;
