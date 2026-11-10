-- Ensayo de la migración 481: la fecha del pedido tiene piso y techo para quien no es admin, en el alta y en la
-- edición (#1514: SEG-01 y PAT-9-1; tarjeta 3 de #1524).
--
-- Los casos E pasan con y sin la migración; los L fallan sin ella. "piso" es hoy − los días de la política de la
-- sucursal (7 por defecto), en el día argentino.
--
--   L1 · SEG-01 con una promo vencida equivalente a la 734 (activa, terminó hace 6 días): un preventista arma su
--        regalo fechando el pedido en piso − 1, dentro de la vigencia de la promo. Se rechaza por la fecha
--        (success = false y el motivo, sin escribir nada). Sin la migración entraba.
--   E1 · La misma promo con la fecha de hoy: la rechaza regalo_fuera_de_promo (la promo de verdad venció).
--   E2 · El preventista con la fecha del piso exacto y con la de hoy, sin promo: entran.
--   E3 · El preventista con la fecha de mañana: se rechaza por el techo de #1319 ("... no puede ser posterior a
--        hoy."), sin escribir nada.
--   E4 · El admin con piso − 23 y con regalo de la promo vencida: entra (el admin no tiene piso).
--   L2 · La cola offline: crear_pedido_idempotente del preventista con fecha piso − 1 falla con el motivo y no sella
--        la clave (no hay pedido con ese offline_id): reintentar da lo mismo y el pedido queda a la vista.
--   L3 · El replay de un pedido que entró dentro del piso sigue contestando idempotente aunque después el piso
--        se achique (crear_pedido_idempotente contesta antes de llegar a la regla).
--   L4 · La edición como authenticated (pedidos_proteger_columnas). El encargado no mueve la fecha a piso − 1 ni a
--        mañana, ni por actualizar_fechas_y_notas_pedido ni por un UPDATE directo (el PATCH): 22023, sin tocar
--        nada. Sí la mueve dentro del piso por las dos vías, y edita las notas de un pedido más viejo que el piso
--        sin tocarle la fecha (la rama sólo mira la fecha). El preventista sigue sin poder tocarla, aun dentro del
--        piso (42501 de #1155, como antes). El server (un UPDATE que no corre como authenticated) y el admin, por
--        la RPC y por un UPDATE directo, no tienen piso.
--   L5 · La política: actualizar_dias_atras_fecha_pedido como authenticated. El encargado no la cambia; el admin
--        no puede poner 31 y sí 2. Con 2, el alta del preventista en hoy − 3 se rechaza ("hasta 2 días atrás") y
--        en hoy − 2 entra, y la edición del encargado a hoy − 3 también se rechaza.
--   L6 · Las dos funciones nuevas tienen el cuerpo y los EXECUTE de la migración; crear_pedido_completo y
--        pedidos_proteger_columnas llevan su bloque de la 481 y conservan sus EXECUTE; anon no ejecuta ninguna, y
--        la columna nace en 7 con su CHECK de 0 a 30. De las dos que se parchearon se mira el bloque y no el md5
--        entero: otras migraciones las siguen tocando (la 480b, de la tarjeta 2, ya cambió crear_pedido_completo)
--        y el ensayo tiene que seguir diciendo algo después.
--   L7 · SEG-A (auditoria_definer_sin_rol) no ve nada nuevo y crear_pedido_idempotente no cambió (su md5 es el de
--        la lista blanca de la 474).
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo,
-- con el BEGIN y sin el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por
-- los L.
--
-- Fixtures: una sucursal activa con un admin, un encargado y un preventista activos. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_como(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true),
         set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1514', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, 1000, 1, p_suc)
  RETURNING id;
$fn$;

-- Una promo de bonificación (compra 3, regala 1 del mismo producto) entre p_inicio y p_fin, activa.
CREATE OR REPLACE FUNCTION pg_temp.t_promo(p_suc bigint, p_prod bigint, p_inicio date, p_fin date)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, fecha_fin, activo, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, modo_exclusion, prioridad)
  VALUES ('ZZ ensayo 1514', 'bonificacion', p_inicio, p_fin, true, p_suc, true, p_prod, false, 'acumulable', 0)
  RETURNING id INTO v;
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v, p_prod, p_suc);
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v, 'cantidad_compra', 3, p_suc), (v, 'cantidad_bonificacion', 1, p_suc);
  RETURN v;
END
$fn$;

-- Tres unidades a $1 y, con p_promo, una de regalo a $0.
CREATE OR REPLACE FUNCTION pg_temp.t_items(p_prod bigint, p_promo bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', 3, 'precio_unitario', 1))
         || CASE WHEN p_promo IS NULL THEN '[]'::jsonb
                 ELSE jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', 1, 'precio_unitario', 0,
                                                           'es_bonificacion', true, 'promocion_id', p_promo)) END;
$fn$;

-- El alta como p_user, con p_fecha. No aborta.
CREATE OR REPLACE FUNCTION pg_temp.t_alta(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb, p_fecha date)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM pg_temp.t_como(p_user, p_suc);
  RETURN public.crear_pedido_completo(
    p_cliente_id => p_cli, p_total => 3, p_usuario_id => p_user, p_items => p_items,
    p_notas => 'ensayo 1514', p_fecha => p_fecha);
END
$fn$;

-- El replay offline como p_user, con su clave. No aborta.
CREATE OR REPLACE FUNCTION pg_temp.t_replay(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb, p_fecha date,
                                            p_clave text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM pg_temp.t_como(p_user, p_suc);
  RETURN public.crear_pedido_idempotente(
    p_cliente_id => p_cli, p_total => 3, p_usuario_id => p_user, p_items => p_items,
    p_notas => 'ensayo 1514', p_fecha => p_fecha, p_offline_id => p_clave);
END
$fn$;

-- p_sql como p_user, con el rol authenticated (lo que llega por PostgREST). $1 es p_ped y $2 p_fecha. 'ok' si
-- entró; si no, el SQLSTATE y el mensaje, y no queda nada (el bloque se revierte y el rol vuelve).
CREATE OR REPLACE FUNCTION pg_temp.t_auth(p_user uuid, p_suc bigint, p_sql text, p_ped bigint, p_fecha date)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM pg_temp.t_como(p_user, p_suc);
  PERFORM set_config('role', 'authenticated', true);
  EXECUTE p_sql USING p_ped, p_fecha;
  PERFORM set_config('role', 'none', true);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END
$fn$;

-- El primer motivo de un rechazo del alta ('' si entró).
CREATE OR REPLACE FUNCTION pg_temp.t_motivo(p_res jsonb)
RETURNS text LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE((p_res->>'success')::boolean, false) THEN ''
              ELSE COALESCE(p_res->'errores'->>0, p_res->>'error', p_res::text) END;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_enc    uuid;
  v_pre    uuid;
  v_hoy    date := public._tablero_hoy();
  v_dias   int := 7;
  v_piso   date;
  v_prod   bigint;
  v_cli    bigint;
  v_promo  bigint;
  v_ped    bigint;
  v_viejo  bigint;
  v_pp     bigint;
  v_f      date;
  v_rpc    text := 'SELECT public.actualizar_fechas_y_notas_pedido($1, NULL, $2, NULL, NULL)';
  v_patch  text := 'UPDATE public.pedidos SET fecha = $2 WHERE id = $1';
  v_n      bigint;
  v_clave  text;
  v_j      jsonb;
  v_r      jsonb;
  v_txt    text;
  v_estado text;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id, enc.usuario_id, pre.usuario_id
    INTO v_suc, v_adm, v_enc, v_pre
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado'
                   ORDER BY us.usuario_id LIMIT 1) enc ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista'
                   ORDER BY us.usuario_id LIMIT 1) pre ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin, un encargado y un preventista activos';
  END IF;

  -- Los días de la política de la sucursal; sin la columna (antes de la 481), los 7 de la decisión.
  BEGIN
    EXECUTE 'SELECT dias_atras_fecha_pedido FROM public.politicas_comerciales WHERE sucursal_id = $1'
      INTO v_dias USING v_suc;
    v_dias := COALESCE(v_dias, 7);
  EXCEPTION WHEN undefined_column THEN v_dias := 7;
  END;
  v_piso := v_hoy - v_dias;

  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1514');
  v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1514');
  -- La vencida equivalente a la 734: activa, empezó hace un mes y terminó hace 6 días. Su vigencia cubre piso − 1
  -- mientras la política sea de 5 días o más (con menos, L1 usa la fecha de fin, que sigue debajo del piso).
  v_promo := pg_temp.t_promo(v_suc, v_prod, v_hoy - 30, v_hoy - 6);

  -- L1 · SEG-01: la promo vencida no se alcanza fechando atrás
  BEGIN
    v_n := (SELECT count(*) FROM pedidos WHERE cliente_id = v_cli);
    v_j := pg_temp.t_alta(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod, v_promo), LEAST(v_piso - 1, v_hoy - 6));
    v_txt := pg_temp.t_motivo(v_j);
    IF v_txt NOT LIKE 'La fecha del pedido (' || to_char(LEAST(v_piso - 1, v_hoy - 6), 'DD/MM/YYYY')
                       || ') no puede ser anterior a%'
       OR (SELECT count(*) FROM pedidos WHERE cliente_id = v_cli) <> v_n THEN
      v_fallas := v_fallas || format('L1 el preventista fechó en %s con el regalo de la promo vencida y dio %s',
                                     LEAST(v_piso - 1, v_hoy - 6), v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('L1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E1 · con la fecha de hoy la promo está vencida de verdad
  BEGIN
    v_j := pg_temp.t_alta(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod, v_promo), v_hoy);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'codigo' IS DISTINCT FROM 'regalo_fuera_de_promo' THEN
      v_fallas := v_fallas || format('E1 el regalo de la promo vencida con la fecha de hoy dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · el piso exacto y hoy entran
  BEGIN
    v_j := pg_temp.t_alta(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_piso);
    v_r := pg_temp.t_alta(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_hoy);
    IF pg_temp.t_motivo(v_j) <> '' OR pg_temp.t_motivo(v_r) <> ''
       OR (SELECT fecha FROM pedidos WHERE id = (v_j->>'pedido_id')::bigint) IS DISTINCT FROM v_piso THEN
      v_fallas := v_fallas || format('E2 el piso (%s) dio %s y hoy %s', v_piso, v_j, v_r);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E3 · el techo de #1319 sigue
  BEGIN
    v_n := (SELECT count(*) FROM pedidos WHERE cliente_id = v_cli);
    v_j := pg_temp.t_alta(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_hoy + 1);
    IF pg_temp.t_motivo(v_j) NOT LIKE 'La fecha del pedido (' || to_char(v_hoy + 1, 'DD/MM/YYYY')
                                     || ') no puede ser posterior a hoy.%'
       OR (SELECT count(*) FROM pedidos WHERE cliente_id = v_cli) <> v_n THEN
      v_fallas := v_fallas || format('E3 el preventista con fecha de mañana dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E4 · el admin no tiene piso
  BEGIN
    v_j := pg_temp.t_alta(v_cli, v_adm, v_suc, pg_temp.t_items(v_prod, v_promo), v_piso - 23);
    IF pg_temp.t_motivo(v_j) <> '' THEN
      v_fallas := v_fallas || format('E4 el admin en %s dio %s', v_piso - 23, v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L2 · la cola offline: un encolado más viejo que el piso falla con el motivo y no sella la clave
  BEGIN
    v_clave := 'ensayo-1514-' || gen_random_uuid();
    v_j := pg_temp.t_replay(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_piso - 1, v_clave);
    v_r := pg_temp.t_replay(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_piso - 1, v_clave);
    IF pg_temp.t_motivo(v_j) NOT LIKE 'La fecha del pedido (' || to_char(v_piso - 1, 'DD/MM/YYYY') || ') no puede ser anterior a%'
       OR pg_temp.t_motivo(v_r) IS DISTINCT FROM pg_temp.t_motivo(v_j)
       OR EXISTS (SELECT 1 FROM pedidos WHERE offline_id = v_clave) THEN
      v_fallas := v_fallas || format('L2 el encolado del %s dio %s y el reintento %s', v_piso - 1, v_j, v_r);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('L2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L3 · el replay de lo que ya entró no mira el piso
  BEGIN
    v_clave := 'ensayo-1514-' || gen_random_uuid();
    v_j := pg_temp.t_replay(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_hoy - 2, v_clave);
    EXECUTE 'UPDATE public.politicas_comerciales SET dias_atras_fecha_pedido = 1 WHERE sucursal_id = $1' USING v_suc;
    v_r := pg_temp.t_replay(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_hoy - 2, v_clave);
    IF pg_temp.t_motivo(v_j) <> ''
       OR NOT COALESCE((v_r->>'idempotente')::boolean, false)
       OR (v_r->>'pedido_id') IS DISTINCT FROM (v_j->>'pedido_id') THEN
      v_fallas := v_fallas || format('L3 el alta del %s dio %s y su replay con el piso en 1 día %s', v_hoy - 2, v_j, v_r);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('L3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L4 · la edición como authenticated: el PATCH directo y la RPC pasan por pedidos_proteger_columnas
  BEGIN
    v_ped := (pg_temp.t_alta(v_cli, v_adm, v_suc, pg_temp.t_items(v_prod), v_hoy)->>'pedido_id')::bigint;
    v_viejo := (pg_temp.t_alta(v_cli, v_adm, v_suc, pg_temp.t_items(v_prod), v_piso - 13)->>'pedido_id')::bigint;
    v_pp := (pg_temp.t_alta(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_hoy)->>'pedido_id')::bigint;
    IF v_ped IS NULL OR v_viejo IS NULL OR v_pp IS NULL THEN
      RAISE EXCEPTION 'las altas para L4 no entraron';
    END IF;

    -- El encargado no la mueve a piso − 1 ni a mañana, por ninguna de las dos vías.
    FOREACH v_txt IN ARRAY ARRAY[v_rpc, v_patch] LOOP
      FOREACH v_f IN ARRAY ARRAY[v_piso - 1, v_hoy + 1] LOOP
        v_estado := pg_temp.t_auth(v_enc, v_suc, v_txt, v_ped, v_f);
        IF v_estado NOT LIKE '22023 La fecha del pedido (' || to_char(v_f, 'DD/MM/YYYY') || ') no puede ser %'
           OR (SELECT fecha FROM pedidos WHERE id = v_ped) IS DISTINCT FROM v_hoy THEN
          v_fallas := v_fallas || format('L4 el encargado movió la fecha a %s con «%s»: %s', v_f, v_txt, v_estado);
        END IF;
      END LOOP;
    END LOOP;

    -- Dentro del piso entra: la RPC al piso y el UPDATE directo a hoy − 1.
    v_estado := pg_temp.t_auth(v_enc, v_suc, v_rpc, v_ped, v_piso);
    IF v_estado <> 'ok' OR (SELECT fecha FROM pedidos WHERE id = v_ped) IS DISTINCT FROM v_piso THEN
      v_fallas := v_fallas || format('L4 el encargado no pudo poner el piso por la RPC: %s', v_estado);
    END IF;
    v_estado := pg_temp.t_auth(v_enc, v_suc, v_patch, v_ped, v_hoy - 1);
    IF v_estado <> 'ok' OR (SELECT fecha FROM pedidos WHERE id = v_ped) IS DISTINCT FROM v_hoy - 1 THEN
      v_fallas := v_fallas || format('L4 el encargado no pudo poner hoy − 1 por un UPDATE directo: %s', v_estado);
    END IF;

    -- La rama sólo mira la fecha: las notas del pedido viejo, por la RPC con su misma fecha y por un UPDATE.
    v_estado := pg_temp.t_auth(v_enc, v_suc,
      'SELECT public.actualizar_fechas_y_notas_pedido($1, ''ensayo 1514 notas'', $2, NULL, NULL)', v_viejo, v_piso - 13);
    v_txt := pg_temp.t_auth(v_enc, v_suc,
      'UPDATE public.pedidos SET notas = ''ensayo 1514 notas bis'' WHERE id = $1 AND $2 IS NULL', v_viejo, NULL);
    IF v_estado <> 'ok' OR v_txt <> 'ok'
       OR (SELECT fecha::text || '/' || notas FROM pedidos WHERE id = v_viejo)
          IS DISTINCT FROM (v_piso - 13)::text || '/ensayo 1514 notas bis' THEN
      v_fallas := v_fallas || format('L4 las notas del pedido viejo dieron %s y %s', v_estado, v_txt);
    END IF;

    -- El preventista sigue sin tocar la fecha, aun dentro del piso: #1155, como antes.
    v_estado := pg_temp.t_auth(v_pre, v_suc, v_rpc, v_pp, v_hoy - 1);
    IF v_estado NOT LIKE '42501 %fecha%' OR (SELECT fecha FROM pedidos WHERE id = v_pp) IS DISTINCT FROM v_hoy THEN
      v_fallas := v_fallas || format('L4 el preventista movió la fecha de su pedido: %s', v_estado);
    END IF;

    -- El server (no corre como authenticated) no tiene piso.
    UPDATE pedidos SET fecha = v_piso - 5 WHERE id = v_ped;
    IF (SELECT fecha FROM pedidos WHERE id = v_ped) IS DISTINCT FROM v_piso - 5 THEN
      v_fallas := v_fallas || 'L4 el UPDATE del server no movió la fecha'::text;
    END IF;

    -- El admin tampoco, por la RPC ni por un UPDATE directo.
    v_estado := pg_temp.t_auth(v_adm, v_suc, v_rpc, v_ped, v_piso - 23);
    v_txt := pg_temp.t_auth(v_adm, v_suc, v_patch, v_viejo, v_piso - 20);
    IF v_estado <> 'ok' OR v_txt <> 'ok'
       OR (SELECT fecha FROM pedidos WHERE id = v_ped) IS DISTINCT FROM v_piso - 23
       OR (SELECT fecha FROM pedidos WHERE id = v_viejo) IS DISTINCT FROM v_piso - 20 THEN
      v_fallas := v_fallas || format('L4 el admin no movió las fechas: %s / %s', v_estado, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('L4 dio %s: %s', SQLSTATE, SQLERRM);
  END;
  PERFORM set_config('role', 'none', true);

  -- L5 · la política la cambia sólo el admin, y rige en el alta y en la edición
  BEGIN
    v_ped := (pg_temp.t_alta(v_cli, v_adm, v_suc, pg_temp.t_items(v_prod), v_hoy)->>'pedido_id')::bigint;
    -- El encargado no la cambia.
    v_estado := NULL;
    BEGIN
      PERFORM pg_temp.t_como(v_enc, v_suc);
      PERFORM set_config('role', 'authenticated', true);
      EXECUTE 'SELECT public.actualizar_dias_atras_fecha_pedido(2)';
      v_estado := 'entró';
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ515';
    EXCEPTION
      WHEN SQLSTATE 'ZZ515' THEN NULL;
      WHEN OTHERS THEN v_estado := SQLERRM;
    END;
    IF v_estado IS DISTINCT FROM 'Acceso denegado: se requiere rol admin' THEN
      v_fallas := v_fallas || format('L5 el encargado cambió la política: %s', v_estado);
    END IF;
    -- El admin no pone 31; sí 2.
    v_estado := NULL;
    BEGIN
      PERFORM pg_temp.t_como(v_adm, v_suc);
      PERFORM set_config('role', 'authenticated', true);
      EXECUTE 'SELECT public.actualizar_dias_atras_fecha_pedido(31)';
      v_estado := 'entró';
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ515';
    EXCEPTION
      WHEN SQLSTATE 'ZZ515' THEN NULL;
      WHEN OTHERS THEN v_estado := SQLERRM;
    END;
    IF v_estado IS DISTINCT FROM 'Los días hacia atrás de la fecha del pedido van de 0 a 30' THEN
      v_fallas := v_fallas || format('L5 el admin puso 31: %s', v_estado);
    END IF;
    v_n := NULL;
    PERFORM pg_temp.t_como(v_adm, v_suc);
    PERFORM set_config('role', 'authenticated', true);
    EXECUTE 'SELECT public.actualizar_dias_atras_fecha_pedido(2)' INTO v_n;
    PERFORM set_config('role', 'none', true);
    EXECUTE 'SELECT dias_atras_fecha_pedido FROM public.politicas_comerciales WHERE sucursal_id = $1' INTO v_dias USING v_suc;
    IF v_n IS DISTINCT FROM 2 OR v_dias IS DISTINCT FROM 2 THEN
      v_fallas := v_fallas || format('L5 el admin puso 2 y la RPC dio %s y la política %s', v_n, v_dias);
    END IF;
    -- Con 2: el alta en hoy − 3 no entra y en hoy − 2 sí.
    v_j := pg_temp.t_alta(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_hoy - 3);
    v_r := pg_temp.t_alta(v_cli, v_pre, v_suc, pg_temp.t_items(v_prod), v_hoy - 2);
    IF pg_temp.t_motivo(v_j) NOT LIKE '%no puede ser anterior al ' || to_char(v_hoy - 2, 'DD/MM/YYYY') || ': hasta 2 días atrás.%'
       OR pg_temp.t_motivo(v_r) <> '' THEN
      v_fallas := v_fallas || format('L5 con 2 días el alta en hoy − 3 dio %s y en hoy − 2 %s', v_j, v_r);
    END IF;
    -- Con 2: la edición del encargado a hoy − 3 tampoco, por ninguna de las dos vías.
    FOREACH v_txt IN ARRAY ARRAY[v_rpc, v_patch] LOOP
      v_estado := pg_temp.t_auth(v_enc, v_suc, v_txt, v_ped, v_hoy - 3);
      IF v_estado NOT LIKE '22023 %hasta 2 días atrás.%' THEN
        v_fallas := v_fallas || format('L5 con 2 días el encargado movió la fecha a hoy − 3 con «%s»: %s', v_txt, v_estado);
      END IF;
    END LOOP;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ514';
  EXCEPTION
    WHEN SQLSTATE 'ZZ514' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('L5 dio %s: %s', SQLSTATE, SQLERRM);
  END;
  PERFORM set_config('role', 'none', true);

  -- L6 · los cuerpos, los EXECUTE y la columna
  IF (SELECT string_agg(p.oid::regprocedure::text || '=' || md5(p.prosrc) || ' ' || p.proacl::text || ' ' || p.prosecdef::text,
                        ' | ' ORDER BY p.oid::regprocedure::text)
        FROM pg_proc p
       WHERE p.pronamespace = 'public'::regnamespace
         AND p.proname IN ('_fecha_pedido_fuera_de_rango', 'actualizar_dias_atras_fecha_pedido'))
     IS DISTINCT FROM
       '_fecha_pedido_fuera_de_rango(date,bigint)=d66db7f86805a3123561c3d8726b0e1b {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres} false'
       || ' | actualizar_dias_atras_fecha_pedido(integer)=0559dc1913f61f2725165847fc1ba485 {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres} true'
     OR NOT EXISTS (SELECT 1 FROM pg_proc
                     WHERE oid = 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure
                       AND prosrc LIKE '%v_motivo_fecha := public._fecha_pedido_fuera_de_rango(v_fecha_pedido, v_sucursal);%'
                       AND prosrc NOT LIKE '%v_fecha_pedido > public._tablero_hoy() THEN%'
                       AND prosecdef
                       AND proacl::text = '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
     OR NOT EXISTS (SELECT 1 FROM pg_proc
                     WHERE oid = 'public.pedidos_proteger_columnas()'::regprocedure
                       AND prosrc LIKE '%v_motivo_fecha := public._fecha_pedido_fuera_de_rango(NEW.fecha, OLD.sucursal_id);%'
                       AND NOT prosecdef
                       AND proacl::text = '{postgres=X/postgres,service_role=X/postgres}')
     OR (SELECT column_default || ' ' || is_nullable FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'politicas_comerciales' AND column_name = 'dias_atras_fecha_pedido')
        IS DISTINCT FROM '7 NO'
     OR (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'politicas_dias_atras_fecha_pedido_rango')
        IS DISTINCT FROM 'CHECK (((dias_atras_fecha_pedido >= 0) AND (dias_atras_fecha_pedido <= 30)))' THEN
    v_fallas := v_fallas || 'L6 los cuerpos, los EXECUTE o la columna no son los de la migración 481'::text;
  END IF;

  -- L7 · SEG-A no ve nada nuevo y el replay no cambió
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() h
              WHERE h.firma ~ '^(crear_pedido_idempotente|crear_pedido_completo|actualizar_dias_atras_fecha_pedido)\(')
     OR (SELECT md5(prosrc) FROM pg_proc
          WHERE oid = 'public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)'::regprocedure)
        IS DISTINCT FROM '63f0759223a668afdd04ce684aee18ef'
     OR to_regprocedure('public.actualizar_dias_atras_fecha_pedido(integer)') IS NULL THEN
    v_fallas := v_fallas || 'L7 SEG-A ve una función del alta o la RPC nueva, o crear_pedido_idempotente cambió'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · L1 E1 E2 E3 E4 L2 L3 L4 L5 L6 L7 (sucursal %, piso %)', v_suc, v_piso;
 END;
END
$ensayo$;
