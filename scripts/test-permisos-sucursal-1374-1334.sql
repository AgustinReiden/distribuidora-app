-- Ensayo de #1374 y #1334 (tarjeta 3 del plan #1378, mig *_permisos_por_sucursal).
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en una
-- excepción, y cada caso en su bloque que se deshace (ZZ001). Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR. Antes de aplicarla se corre pegado detrás
-- de su cuerpo, sin el BEGIN/COMMIT; después, solo.
--
-- Los casos con "de cada sucursal" corren dos veces, con un admin que es sólo de
-- esa sucursal: A y B son las dos activas, y cada una es "la ajena" de la otra.
--
--   1 · Asignar un cliente (#1374), en la forma del front: un INSERT por fila.
--       El admin de la sucursal asigna a uno de la sucursal; no a uno de otra; no
--       se asigna a sí mismo un cliente ajeno. El preventista se asigna un huérfano
--       de su sucursal y no uno ajeno. El server no pasa por acá.
--   2 · La reasignación por zona no se frena (trigger a profundidad 2), aunque el
--       dueño de la zona ya no sea de la sucursal.
--   3 · Planilla (#1374): de otra sucursal, sin el detalle; de la propia, con él.
--   4 · guardar_analisis_mensual (#1334): la propia sí, la ajena y la Red no. El
--       admin de todas y el server, sí.
--   5 · Regresión: guardar_meta_gerencial y registrar_origen_precio_items ya
--       rechazan la sucursal ajena (#1321, #1329).
--   6 · Las tres de la caja (#1334): admin, preventista y transportista de la
--       sucursal contestan por la suya y no por la ajena. El admin de todas y el
--       server contestan por las dos, con el dato real.
--   7 · Los guards siguen cortando con su mensaje, como el usuario y no como
--       postgres: FIFO, cambiar la forma de pago, borrar un pago (INVOKER), el
--       trigger de pagos y pedidos_proteger_columnas (INVOKER). Si una sucursal
--       ajena llegara a un guard, levanta: no pasa.
--   8 · reporte_ventas_por_cliente (#1334): el nombre de un perfil ajeno no sale
--       ni por sucursal ni por la Red; el propio sí, y también el de quien vendió en
--       la sucursal aunque ya no sea de ella. Encargado y server incluidos.
--   9 · Gates: SEG-A en 0, los parámetros sin acotar son exactamente los del JSON,
--       reporte_stock_red sigue global, cp_insert no cambió y los grants tampoco.

DO $ensayo$
DECLARE
  v_a       bigint;
  v_b       bigint;
  v_caja    bigint;    -- la sucursal con cajas cerradas
  v_sin     bigint;    -- la otra
  v_adm_a   uuid;      -- admin sólo de A
  v_adm_b   uuid;      -- admin sólo de B
  v_adm_t   uuid;      -- admin de todas
  v_prev_a  uuid;
  v_prev_b  uuid;
  v_tr_a    uuid;
  v_tr_b    uuid;
  v_enc     uuid;
  v_enc_s   bigint;
  v_cli_a   bigint;
  v_cli_b   bigint;
  v_ped_a   bigint;
  v_ped_b   bigint;
  v_limite  date;
  v_pago    bigint;
  v_cli_p   bigint;
  v_ped_ch  record;
  v_x       uuid;
  v_y       uuid;
  v_r       text;
  v_txt     text;
  v_esp     text;
  v_hoy     date := _tablero_hoy();
  v_mes     date := date_trunc('month', _tablero_hoy())::date;
  v_d1      date := (_tablero_hoy() - 400);
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
 BEGIN
  -- ---------------------------------------------------------------- personas -
  SELECT min(id), max(id) INTO v_a, v_b FROM sucursales WHERE activa;
  IF (SELECT count(*) FROM sucursales WHERE activa) <> 2 THEN
    RAISE EXCEPTION 'ENSAYO · espera dos sucursales activas';
  END IF;

  CREATE OR REPLACE FUNCTION pg_temp.ps_solo(p_rol text, p_s bigint) RETURNS uuid LANGUAGE sql AS $f$
    SELECT pf.id
      FROM perfiles pf
      JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = p_s
     WHERE pf.activo AND pf.rol = p_rol
       AND NOT EXISTS (SELECT 1 FROM usuario_sucursales x
                        WHERE x.usuario_id = pf.id AND x.sucursal_id <> p_s)
     ORDER BY pf.id LIMIT 1;
  $f$;

  v_adm_a  := pg_temp.ps_solo('admin', v_a);
  v_adm_b  := pg_temp.ps_solo('admin', v_b);
  v_prev_a := pg_temp.ps_solo('preventista', v_a);
  v_prev_b := pg_temp.ps_solo('preventista', v_b);
  v_tr_a   := pg_temp.ps_solo('transportista', v_a);
  v_tr_b   := pg_temp.ps_solo('transportista', v_b);

  SELECT pf.id INTO v_adm_t
    FROM perfiles pf
   WHERE pf.activo AND pf.rol = 'admin'
     AND NOT EXISTS (SELECT 1 FROM sucursales s WHERE s.activa
                       AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                                        WHERE us.usuario_id = pf.id AND us.sucursal_id = s.id))
   ORDER BY pf.id LIMIT 1;

  SELECT pf.id, us.sucursal_id INTO v_enc, v_enc_s
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.activo AND pf.rol = 'encargado'
   ORDER BY pf.id LIMIT 1;

  SELECT c.id INTO v_cli_a FROM clientes c
   WHERE c.sucursal_id = v_a AND c.activo AND NOT COALESCE(c.reservado_admin, false) ORDER BY c.id LIMIT 1;
  SELECT c.id INTO v_cli_b FROM clientes c
   WHERE c.sucursal_id = v_b AND c.activo AND NOT COALESCE(c.reservado_admin, false) ORDER BY c.id LIMIT 1;
  SELECT max(id) INTO v_ped_a FROM pedidos WHERE sucursal_id = v_a;
  SELECT max(id) INTO v_ped_b FROM pedidos WHERE sucursal_id = v_b;

  SELECT sucursal_id, max(fecha) INTO v_caja, v_limite
    FROM rendiciones_control WHERE estado IN ('confirmada', 'resuelta')
   GROUP BY sucursal_id ORDER BY max(fecha) DESC LIMIT 1;
  v_sin := CASE WHEN v_caja = v_a THEN v_b ELSE v_a END;

  SELECT pa.id, pa.cliente_id INTO v_pago, v_cli_p
    FROM pagos pa
   WHERE pa.sucursal_id = v_caja AND pa.forma_pago = 'efectivo' AND pa.fecha <= v_limite
   ORDER BY pa.id DESC LIMIT 1;

  SELECT pe.id, pe.transportista_id INTO v_ped_ch
    FROM pedidos pe
    JOIN rendiciones_control rc
      ON rc.transportista_id = pe.transportista_id AND rc.sucursal_id = pe.sucursal_id
     AND rc.fecha = (pe.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
     AND rc.estado IN ('confirmada', 'resuelta')
    JOIN perfiles pf ON pf.id = pe.transportista_id AND pf.activo AND pf.rol = 'transportista'
    JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = pe.sucursal_id
   WHERE pe.sucursal_id = v_caja AND pe.estado = 'entregado'
   ORDER BY pe.id DESC LIMIT 1;

  IF v_adm_a IS NULL OR v_adm_b IS NULL OR v_adm_t IS NULL OR v_prev_a IS NULL OR v_prev_b IS NULL
     OR v_tr_a IS NULL OR v_tr_b IS NULL OR v_enc IS NULL OR v_cli_a IS NULL OR v_cli_b IS NULL
     OR v_ped_a IS NULL OR v_ped_b IS NULL OR v_caja IS NULL OR v_pago IS NULL OR v_ped_ch.id IS NULL THEN
    RAISE EXCEPTION 'ENSAYO · faltan datos: adm % % %, prev % %, tr % %, enc %, cli % %, ped % %, caja %, pago %, ped_ch %',
      v_adm_a, v_adm_b, v_adm_t, v_prev_a, v_prev_b, v_tr_a, v_tr_b, v_enc, v_cli_a, v_cli_b,
      v_ped_a, v_ped_b, v_caja, v_pago, v_ped_ch.id;
  END IF;

  v_notas := v_notas || format('A %s, B %s, caja %s hasta %s, pago %s, pedido %s',
                               v_a, v_b, v_caja, v_limite, v_pago, v_ped_ch.id);

  -- ----------------------------------------------------------------- helpers -
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
    IF p_uid IS NULL THEN
      EXECUTE 'RESET ROLE';
    ELSE
      EXECUTE 'SET LOCAL ROLE authenticated';
    END IF;
  END $f$;
  -- 'PASA', o el código y el mensaje del error.
  CREATE OR REPLACE FUNCTION pg_temp.intenta(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE p_sql;
    RETURN 'PASA';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- El valor de una consulta, o el error.
  CREATE OR REPLACE FUNCTION pg_temp.valor(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    EXECUTE p_sql INTO v;
    RETURN COALESCE(v, '(null)');
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.ins(p_c bigint, p_p uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', p_c, p_p);
  $f$;
  -- Sumá el caso a la lista si el resultado no es el esperado (regex).
  CREATE OR REPLACE FUNCTION pg_temp.ve(p_f text[], p_caso text, p_r text, p_re text) RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    IF p_r ~ p_re THEN RETURN p_f; END IF;
    RETURN p_f || format('%s: dio «%s», esperaba /%s/', p_caso, left(p_r, 140), p_re);
  END $f$;

  -- ------------------------------------- 1 · asignar un cliente, de cada sucursal -
  CREATE OR REPLACE FUNCTION pg_temp.ps_asignar(
    p_s bigint, p_adm uuid, p_prev uuid, p_cli bigint,
    p_prev_o uuid, p_cli_o bigint) RETURNS text[] LANGUAGE plpgsql AS $f$
  DECLARE
    f text[] := '{}';
    c text := format('1 (suc %s) ', p_s);
  BEGIN
    DELETE FROM public.cliente_preventistas WHERE cliente_id IN (p_cli, p_cli_o);

    PERFORM pg_temp.como(p_adm, p_s);
    f := pg_temp.ve(f, c || 'admin + preventista de la sucursal',
                    pg_temp.intenta(pg_temp.ins(p_cli, p_prev)), '^PASA$');
    f := pg_temp.ve(f, c || 'admin + preventista de otra sucursal',
                    pg_temp.intenta(pg_temp.ins(p_cli, p_prev_o)), '^42501 .*no es de la sucursal del cliente');
    f := pg_temp.ve(f, c || 'admin se asigna un cliente ajeno',
                    pg_temp.intenta(pg_temp.ins(p_cli_o, p_adm)), '^42501 .*no es de la sucursal del cliente');
    f := pg_temp.ve(f, c || 'admin, cliente y preventista ajenos',
                    pg_temp.intenta(pg_temp.ins(p_cli_o, p_prev_o)), '^42501 ');

    PERFORM pg_temp.como(NULL, NULL);
    DELETE FROM public.cliente_preventistas WHERE cliente_id IN (p_cli, p_cli_o);

    PERFORM pg_temp.como(p_prev, p_s);
    f := pg_temp.ve(f, c || 'preventista se asigna un huérfano',
                    pg_temp.intenta(pg_temp.ins(p_cli, p_prev)), '^PASA$');
    f := pg_temp.ve(f, c || 'preventista se asigna un cliente ajeno',
                    pg_temp.intenta(pg_temp.ins(p_cli_o, p_prev)), '^42501 ');
    f := pg_temp.ve(f, c || 'preventista le asigna a otro',
                    pg_temp.intenta(pg_temp.ins(p_cli, p_prev_o)), '^42501 ');

    PERFORM pg_temp.como(NULL, NULL);
    f := pg_temp.ve(f, c || 'el server no pasa por el trigger',
                    pg_temp.intenta(pg_temp.ins(p_cli_o, p_prev)), '^PASA$');
    RETURN f;
  END $f$;

  BEGIN
    v_fallas := v_fallas || pg_temp.ps_asignar(v_a, v_adm_a, v_prev_a, v_cli_a, v_prev_b, v_cli_b);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  PERFORM pg_temp.como(NULL, NULL);
  BEGIN
    v_fallas := v_fallas || pg_temp.ps_asignar(v_b, v_adm_b, v_prev_b, v_cli_b, v_prev_a, v_cli_a);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  PERFORM pg_temp.como(NULL, NULL);

  -- ----------------------------------------------- 2 · la reasignación por zona -
  DECLARE
    v_z bigint;
  BEGIN
    -- El dueño de la zona ya no es de la sucursal: el cambio de zona lo pone igual.
    INSERT INTO public.zonas (nombre, sucursal_id) VALUES ('ensayo 1374', v_a) RETURNING id INTO v_z;
    INSERT INTO public.preventista_zonas (perfil_id, zona_id, sucursal_id) VALUES (v_prev_b, v_z, v_a);
    DELETE FROM public.cliente_preventistas WHERE cliente_id = v_cli_a;

    PERFORM pg_temp.como(v_adm_a, v_a);
    v_fallas := pg_temp.ve(v_fallas, '2 · cambio de zona a una con dueño ajeno',
                           pg_temp.intenta(format('UPDATE public.clientes SET zona_id = %s WHERE id = %s', v_z, v_cli_a)),
                           '^PASA$');
    PERFORM pg_temp.como(NULL, NULL);
    IF NOT EXISTS (SELECT 1 FROM public.cliente_preventistas
                    WHERE cliente_id = v_cli_a AND preventista_id = v_prev_b) THEN
      v_fallas := v_fallas || '2 · el trigger de la zona no asignó al dueño'::text;
    END IF;

    -- Y la RPC, a profundidad 1, con el preventista de la sucursal.
    PERFORM pg_temp.como(v_adm_a, v_a);
    v_fallas := pg_temp.ve(v_fallas, '2 · asignar_preventista_zona',
                           pg_temp.intenta(format('SELECT public.asignar_preventista_zona(%s, %L, false)', v_z, v_prev_a)),
                           '^PASA$');
    PERFORM pg_temp.como(NULL, NULL);
    IF NOT EXISTS (SELECT 1 FROM public.cliente_preventistas
                    WHERE cliente_id = v_cli_a AND preventista_id = v_prev_a) THEN
      v_fallas := v_fallas || '2 · asignar_preventista_zona no asignó'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  PERFORM pg_temp.como(NULL, NULL);

  -- --------------------------------------------------------------- 3 · planilla -
  BEGIN
    v_x := gen_random_uuid();
    v_y := gen_random_uuid();

    PERFORM pg_temp.como(v_adm_a, v_a);
    v_fallas := pg_temp.ve(v_fallas, '3 · primera carga en A',
                           pg_temp.intenta(format('SELECT public.aplicar_control_stock(''[]''::jsonb, ''ensayo'', %L)', v_x)),
                           '^PASA$');
    v_r := pg_temp.intenta(format('SELECT public.aplicar_control_stock(''[]''::jsonb, ''ensayo'', %L)', v_x));
    v_fallas := pg_temp.ve(v_fallas, '3 · la misma sucursal ve el detalle', v_r, 'ya se cargó el .*control N°');

    PERFORM pg_temp.como(v_adm_b, v_b);
    v_r := pg_temp.intenta(format('SELECT public.aplicar_control_stock(''[]''::jsonb, ''ensayo'', %L)', v_x));
    v_fallas := pg_temp.ve(v_fallas, '3 · de A, cargada desde B', v_r, 'ya se cargó en otra sucursal');
    IF v_r ~ 'control N°' THEN
      v_fallas := v_fallas || '3 · B ve el número de control de A'::text;
    END IF;

    v_fallas := pg_temp.ve(v_fallas, '3 · primera carga en B',
                           pg_temp.intenta(format('SELECT public.aplicar_control_stock(''[]''::jsonb, ''ensayo'', %L)', v_y)),
                           '^PASA$');
    PERFORM pg_temp.como(v_adm_a, v_a);
    v_r := pg_temp.intenta(format('SELECT public.aplicar_control_stock(''[]''::jsonb, ''ensayo'', %L)', v_y));
    v_fallas := pg_temp.ve(v_fallas, '3 · de B, cargada desde A', v_r, 'ya se cargó en otra sucursal');
    IF v_r ~ 'control N°' THEN
      v_fallas := v_fallas || '3 · A ve el número de control de B'::text;
    END IF;
    PERFORM pg_temp.como(NULL, NULL);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  PERFORM pg_temp.como(NULL, NULL);

  -- -------------------------------------------------- 4 y 5 · escrituras, de cada sucursal -
  CREATE OR REPLACE FUNCTION pg_temp.ps_escribe(
    p_s bigint, p_adm uuid, p_o bigint, p_ped_s bigint, p_ped_o bigint, p_mes date) RETURNS text[] LANGUAGE plpgsql AS $f$
  DECLARE
    f text[] := '{}';
    c text := format('(suc %s) ', p_s);
  BEGIN
    PERFORM pg_temp.como(p_adm, p_s);
    f := pg_temp.ve(f, '4 ' || c || 'análisis de la propia',
                    pg_temp.intenta(format('SELECT public.guardar_analisis_mensual(%s, %L, ''ensayo'')', p_s, p_mes)), '^PASA$');
    f := pg_temp.ve(f, '4 ' || c || 'análisis de la ajena',
                    pg_temp.intenta(format('SELECT public.guardar_analisis_mensual(%s, %L, ''ensayo'')', p_o, p_mes)), '^42501 ');
    f := pg_temp.ve(f, '4 ' || c || 'análisis de la Red',
                    pg_temp.intenta(format('SELECT public.guardar_analisis_mensual(NULL, %L, ''ensayo'')', p_mes)), '^42501 ');

    f := pg_temp.ve(f, '5 ' || c || 'meta de la ajena',
                    pg_temp.intenta(format('SELECT public.guardar_meta_gerencial(%s, %L, ''venta'', 1)', p_o, p_mes)), '^(42501|P0001) .*Acceso denegado');
    f := pg_temp.ve(f, '5 ' || c || 'meta de la Red',
                    pg_temp.intenta(format('SELECT public.guardar_meta_gerencial(NULL, %L, ''venta'', 1)', p_mes)), '^42501 .*Acceso denegado');
    f := pg_temp.ve(f, '5 ' || c || 'origen de precio de un pedido ajeno',
                    pg_temp.intenta(format('SELECT public.registrar_origen_precio_items(%s, ''[]''::jsonb)', p_ped_o)), '^42501 ');
    f := pg_temp.ve(f, '5 ' || c || 'origen de precio de un pedido propio',
                    pg_temp.intenta(format('SELECT public.registrar_origen_precio_items(%s, ''[]''::jsonb)', p_ped_s)), '^PASA$');
    PERFORM pg_temp.como(NULL, NULL);
    RETURN f;
  END $f$;

  BEGIN
    v_fallas := v_fallas || pg_temp.ps_escribe(v_a, v_adm_a, v_b, v_ped_a, v_ped_b, v_mes)
                         || pg_temp.ps_escribe(v_b, v_adm_b, v_a, v_ped_b, v_ped_a, v_mes);

    PERFORM pg_temp.como(v_adm_t, v_a);
    v_fallas := pg_temp.ve(v_fallas, '4 · admin de todas, la Red',
                           pg_temp.intenta(format('SELECT public.guardar_analisis_mensual(NULL, %L, ''ensayo'')', v_mes)), '^PASA$');
    v_fallas := pg_temp.ve(v_fallas, '4 · admin de todas, la otra sucursal',
                           pg_temp.intenta(format('SELECT public.guardar_analisis_mensual(%s, %L, ''ensayo'')', v_b, v_mes)), '^PASA$');
    PERFORM pg_temp.como(NULL, NULL);
    v_fallas := pg_temp.ve(v_fallas, '4 · el server',
                           pg_temp.intenta(format('SELECT public.guardar_analisis_mensual(%s, %L, ''ensayo server'')', v_a, v_mes)), '^PASA$');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  PERFORM pg_temp.como(NULL, NULL);

  -- ------------------------------------------------- 6 · las tres de la caja -
  CREATE OR REPLACE FUNCTION pg_temp.ps_caja(
    p_quien text, p_u uuid, p_s bigint, p_o bigint, p_tr uuid, p_tr_o uuid, p_d date) RETURNS text[] LANGUAGE plpgsql AS $f$
  DECLARE
    f text[] := '{}';
    c text := format('6 · %s de %s ', p_quien, p_s);
    re text := '^42501 .*no está asignada al usuario';
  BEGIN
    PERFORM pg_temp.como(p_u, p_s);
    f := pg_temp.ve(f, c || 'ultima, la propia', pg_temp.intenta(format('SELECT public.ultima_fecha_caja_cerrada(%s)', p_s)), '^PASA$');
    f := pg_temp.ve(f, c || 'ultima, la ajena', pg_temp.intenta(format('SELECT public.ultima_fecha_caja_cerrada(%s)', p_o)), re);
    f := pg_temp.ve(f, c || 'día, la propia', pg_temp.intenta(format('SELECT public.rendicion_dia_cerrada(%L, %s)', p_d, p_s)), '^PASA$');
    f := pg_temp.ve(f, c || 'día, sin sucursal (la activa)', pg_temp.intenta(format('SELECT public.rendicion_dia_cerrada(%L)', p_d)), '^PASA$');
    f := pg_temp.ve(f, c || 'día, la ajena', pg_temp.intenta(format('SELECT public.rendicion_dia_cerrada(%L, %s)', p_d, p_o)), re);
    f := pg_temp.ve(f, c || 'control, la propia', pg_temp.intenta(format('SELECT public.control_rendicion_cerrado(%L, %s, %L)', p_tr, p_s, p_d)), '^PASA$');
    f := pg_temp.ve(f, c || 'control, la ajena', pg_temp.intenta(format('SELECT public.control_rendicion_cerrado(%L, %s, %L)', p_tr_o, p_o, p_d)), re);
    PERFORM pg_temp.como(NULL, NULL);
    RETURN f;
  END $f$;

  v_fallas := v_fallas
    || pg_temp.ps_caja('admin',         v_adm_a,  v_a, v_b, v_tr_a, v_tr_b, v_hoy)
    || pg_temp.ps_caja('admin',         v_adm_b,  v_b, v_a, v_tr_b, v_tr_a, v_hoy)
    || pg_temp.ps_caja('preventista',   v_prev_a, v_a, v_b, v_tr_a, v_tr_b, v_hoy)
    || pg_temp.ps_caja('preventista',   v_prev_b, v_b, v_a, v_tr_b, v_tr_a, v_hoy)
    || pg_temp.ps_caja('transportista', v_tr_a,   v_a, v_b, v_tr_a, v_tr_b, v_hoy)
    || pg_temp.ps_caja('transportista', v_tr_b,   v_b, v_a, v_tr_b, v_tr_a, v_hoy);

  -- El dato real, para el admin de todas y para el server, en las dos sucursales.
  v_esp := v_limite::text;
  PERFORM pg_temp.como(v_adm_t, v_sin);
  v_fallas := pg_temp.ve(v_fallas, '6 · admin de todas, la última de la otra',
                         pg_temp.valor(format('SELECT public.ultima_fecha_caja_cerrada(%s)', v_caja)), '^' || v_esp || '$');
  v_fallas := pg_temp.ve(v_fallas, '6 · admin de todas, el día cerrado de la otra',
                         pg_temp.valor(format('SELECT public.rendicion_dia_cerrada(%L, %s)', v_limite, v_caja)), '^true$');
  PERFORM pg_temp.como(NULL, NULL);
  v_fallas := pg_temp.ve(v_fallas, '6 · server, la última',
                         pg_temp.valor(format('SELECT public.ultima_fecha_caja_cerrada(%s)', v_caja)), '^' || v_esp || '$');
  v_fallas := pg_temp.ve(v_fallas, '6 · server, el día cerrado',
                         pg_temp.valor(format('SELECT public.rendicion_dia_cerrada(%L, %s)', v_limite, v_caja)), '^true$');
  v_fallas := pg_temp.ve(v_fallas, '6 · server, el control cerrado',
                         pg_temp.valor(format(
                           'SELECT public.control_rendicion_cerrado(%L, %s, (SELECT (fecha_entrega AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date FROM public.pedidos WHERE id = %s))',
                           v_ped_ch.transportista_id, v_caja, v_ped_ch.id)), '^true$');
  v_fallas := pg_temp.ve(v_fallas, '6 · server, sin sucursal ni sesión',
                         pg_temp.valor(format('SELECT public.rendicion_dia_cerrada(%L)', v_limite)), '^false$');
  -- Con el header de una sucursal ajena no hay sucursal activa: false, como siempre.
  PERFORM pg_temp.como(pg_temp.ps_solo('admin', v_sin), v_caja);
  v_fallas := pg_temp.ve(v_fallas, '6 · sin sucursal activa, por defecto',
                         pg_temp.valor(format('SELECT public.rendicion_dia_cerrada(%L)', v_limite)), '^false$');
  PERFORM pg_temp.como(NULL, NULL);

  -- --------------------------------------------------------- 7 · los guards -
  DECLARE
    v_adm_c  uuid := CASE WHEN v_caja = v_a THEN v_adm_a ELSE v_adm_b END;
    v_adm_s  uuid := CASE WHEN v_caja = v_a THEN v_adm_b ELSE v_adm_a END;
  BEGIN
    PERFORM pg_temp.como(v_adm_c, v_caja);
    v_fallas := pg_temp.ve(v_fallas, '7 · FIFO en un día cerrado (rendicion_dia_cerrada)',
      pg_temp.intenta(format('SELECT public.registrar_pago_cliente_fifo(%s, 1, ''efectivo'', %L)', v_cli_p, v_limite)),
      '(?i)cerrad|controlad');
    v_fallas := pg_temp.ve(v_fallas, '7 · cambiar la forma de un pago cerrado (ultima_fecha)',
      pg_temp.intenta(format('SELECT public.actualizar_forma_pago_pago(%s, ''transferencia'')', v_pago)),
      '(?i)cerrad|controlad');
    v_fallas := pg_temp.ve(v_fallas, '7 · borrar un pago cerrado (trigger INVOKER)',
      pg_temp.intenta(format('DELETE FROM public.pagos WHERE id = %s', v_pago)),
      'No se puede anular un pago');

    PERFORM pg_temp.como(v_ped_ch.transportista_id, v_caja);
    v_fallas := pg_temp.ve(v_fallas, '7 · el chofer mueve un pedido de un control cerrado (trigger INVOKER)',
      pg_temp.intenta(format('UPDATE public.pedidos SET fecha_entrega = fecha_entrega + interval ''1 day'' WHERE id = %s', v_ped_ch.id)),
      'ya fue controlada');

    -- El trigger DEFINER de pagos: la sesión del usuario sin SET ROLE, porque pagos
    -- no tiene UPDATE REST. Da lo mismo: mira auth.uid(), no el rol.
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm_c, 'role', 'authenticated')::text, true);
    v_fallas := pg_temp.ve(v_fallas, '7 · trigger de pagos, de la sucursal',
      pg_temp.intenta(format('UPDATE public.pagos SET fecha = fecha WHERE id = %s', v_pago)),
      'cerrada hasta');
    -- Una sucursal ajena que llegue a un guard no pasa: levanta.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm_s, 'role', 'authenticated')::text, true);
    v_fallas := pg_temp.ve(v_fallas, '7 · trigger de pagos, usuario ajeno',
      pg_temp.intenta(format('UPDATE public.pagos SET fecha = fecha WHERE id = %s', v_pago)),
      '^42501 .*no está asignada al usuario');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fallas := pg_temp.ve(v_fallas, '7 · trigger de pagos, server',
      pg_temp.intenta(format('UPDATE public.pagos SET fecha = fecha WHERE id = %s', v_pago)),
      'cerrada hasta');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  PERFORM pg_temp.como(NULL, NULL);

  -- --------------------------------------------- 8 · el nombre del reporte -
  CREATE OR REPLACE FUNCTION pg_temp.ps_nombre(p_d1 date, p_d2 date, p_p uuid, p_s bigint) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    RETURN pg_temp.valor(format(
      'SELECT public.reporte_ventas_por_cliente(%L, %L, %L, %s)->''meta''->>''preventista_nombre''',
      p_d1, p_d2, p_p, COALESCE(p_s::text, 'NULL')));
  END $f$;

  DECLARE
    v_ajeno  uuid := v_prev_b;   -- de B, sin ventas en A
    v_nom_aj text;
    v_nom_pr text;
    v_ped    bigint;
  BEGIN
    SELECT nombre INTO v_nom_aj FROM perfiles WHERE id = v_ajeno;
    SELECT nombre INTO v_nom_pr FROM perfiles WHERE id = v_prev_a;
    IF EXISTS (SELECT 1 FROM pedidos WHERE usuario_id = v_ajeno AND sucursal_id = v_a) THEN
      v_notas := v_notas || 'el perfil ajeno tiene ventas en A: el caso 8 no sirve'::text;
    END IF;

    PERFORM pg_temp.como(v_adm_a, v_a);
    v_fallas := pg_temp.ve(v_fallas, '8 · admin de A, perfil ajeno', pg_temp.ps_nombre(v_d1, v_hoy, v_ajeno, v_a), '^Todos$');
    v_fallas := pg_temp.ve(v_fallas, '8 · admin de A, perfil ajeno, por la Red', pg_temp.ps_nombre(v_d1, v_hoy, v_ajeno, NULL), '^Todos$');
    IF pg_temp.ps_nombre(v_d1, v_hoy, v_prev_a, v_a) IS DISTINCT FROM v_nom_pr THEN
      v_fallas := v_fallas || '8 · admin de A, perfil propio: no salió el nombre'::text;
    END IF;

    PERFORM pg_temp.como(v_adm_t, v_a);
    IF pg_temp.ps_nombre(v_d1, v_hoy, v_ajeno, NULL) IS DISTINCT FROM v_nom_aj THEN
      v_fallas := v_fallas || '8 · admin de todas, por la Red: no salió el nombre'::text;
    END IF;

    -- El encargado, contra el preventista de la otra sucursal.
    PERFORM pg_temp.como(v_enc, v_enc_s);
    v_fallas := pg_temp.ve(v_fallas, '8 · encargado, perfil ajeno',
                           pg_temp.ps_nombre(v_d1, v_hoy, CASE WHEN v_enc_s = v_a THEN v_prev_b ELSE v_prev_a END, v_enc_s), '^Todos$');

    PERFORM pg_temp.como(NULL, NULL);
    IF pg_temp.ps_nombre(v_d1, v_hoy, v_ajeno, v_a) IS DISTINCT FROM v_nom_aj THEN
      v_fallas := v_fallas || '8 · el server: no salió el nombre'::text;
    END IF;

    -- Vendió en A y ya no es de A: el nombre sigue, como en el desplegable.
    SELECT min(id) INTO v_ped FROM pedidos WHERE sucursal_id = v_a;
    UPDATE public.pedidos SET usuario_id = v_ajeno WHERE id = v_ped;
    PERFORM pg_temp.como(v_adm_a, v_a);
    IF pg_temp.ps_nombre(v_d1, v_hoy, v_ajeno, v_a) IS DISTINCT FROM v_nom_aj THEN
      v_fallas := v_fallas || '8 · el que vendió y se fue: no salió el nombre'::text;
    END IF;
    PERFORM pg_temp.como(NULL, NULL);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  PERFORM pg_temp.como(NULL, NULL);

  -- --------------------------------------------------------------- 9 · gates -
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()) THEN
    v_fallas := v_fallas || format('9 · SEG-A: %s',
      (SELECT string_agg(firma || ' · ' || motivo, ' | ') FROM public.auditoria_definer_sin_rol()));
  END IF;

  SELECT string_agg(k, ' | ' ORDER BY k) INTO v_txt
    FROM (SELECT x->>'firma' || '.' || (x->>'parametro') AS k
            FROM jsonb_array_elements(public.auditoria_rpcs_definer()->'parametros') x
           WHERE NOT (x->>'acotado')::boolean
          EXCEPT
          SELECT unnest(ARRAY[
            'aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date).p_transportista_id',
            'asignar_preventista_zona(bigint,uuid,boolean).p_preventista_id',
            'bot_admin_audit_log(date,date,text,uuid,integer).p_perfil_id',
            'consultar_control_rendicion(uuid,date).p_transportista_id',
            'control_rendicion_cerrado(uuid,bigint,date).p_transportista_id',
            'crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text).p_preventista_id',
            'crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text).p_usuario_id',
            'marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid).p_transportista_id',
            'marcar_entregas_masivo(bigint[],uuid,date).p_transportista_id',
            'obtener_pedidos_ctacte_pendientes(date,date,uuid).p_transportista_id',
            'reporte_stock_red(bigint).p_sucursal_id'])) t;
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('9 · sin acotar y fuera del JSON: %s', v_txt);
  END IF;

  PERFORM pg_temp.como(v_adm_a, v_a);
  v_fallas := pg_temp.ve(v_fallas, '9 · reporte_stock_red sigue global',
                         pg_temp.intenta(format('SELECT public.reporte_stock_red(%s)', v_b)), '^PASA$');
  PERFORM pg_temp.como(NULL, NULL);

  IF (SELECT md5(pg_get_expr(polwithcheck, polrelid)) FROM pg_policy
       WHERE polrelid = 'public.cliente_preventistas'::regclass AND polname = 'cp_insert')
     <> '5a45d0563051492fcdfb7ebb30002bc7' THEN
    v_fallas := v_fallas || '9 · cp_insert cambió'::text;
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.ultima_fecha_caja_cerrada(bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rendicion_dia_cerrada(date,bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.ultima_fecha_caja_cerrada(bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rendicion_dia_cerrada(date,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_definer_sin_rol()', 'EXECUTE') THEN
    v_fallas := v_fallas || '9 · un grant cambió'::text;
  END IF;

  IF array_length(v_fallas, 1) IS NULL THEN
    RAISE EXCEPTION 'ENSAYO OK · %', array_to_string(v_notas, ' | ');
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ (%)\n%\n%', array_length(v_fallas, 1),
    array_to_string(v_fallas, E'\n'), array_to_string(v_notas, ' | ');
 END;
END
$ensayo$;
