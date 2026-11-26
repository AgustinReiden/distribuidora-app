-- Ensayo de la migración de las salvedades que carga la oficina (#1700, Part of #1690).
--
-- Decisión del dueño (25/11): la salvedad que carga un admin o un encargado nace resuelta
-- («resuelto_otro», nota «Cargada y resuelta por la oficina», resuelta por quien la cargó y con la
-- fecha de la carga), sin mover plata. La que carga otro rol (un chofer, un preventista que
-- reparte) nace pendiente, como siempre. La oficina la puede anular después, como hoy, y una
-- resuelta no se vuelve a resolver (como hoy: 'Ya resuelta').
--
-- Casos (los L fallan sin la migración; los E pasan con y sin ella):
--   L1 · El admin carga una salvedad: nace resuelto_otro, con la nota, resuelto_por = el admin y
--        resolucion_fecha = created_at; el historial dice creación y resolución; la respuesta
--        dice estado_resolucion = resuelto_otro, y el reintento con la misma clave también. No
--        nace una nota de crédito ni un cargo a un empleado.
--   L2 · El encargado carga una: nace resuelta igual.
--   L3 · Un encargado con el rol extra de chofer: es la oficina (la regla es por el rol de quien
--        la carga), nace resuelta. Va sobre el pedido de un chofer: desde la T2 de la ola 3
--        (1601-b1) un pedido no se le asigna a un encargado (_actua_como_transportista no cuenta
--        el extra de admin ni encargado, como al entregar desde #1548).
--   L4 · El chofer carga una sobre su pedido: nace pendiente, sin nota ni resuelto_por, y la
--        respuesta dice estado_resolucion = pendiente.
--   L5 · Un preventista con el rol extra de chofer, sobre un pedido que él reparte: nace pendiente.
--   L6 · Una que nació resuelta no se vuelve a resolver (resolver_salvedad contesta 'Ya
--        resuelta', como con cualquier resuelta); la pendiente del chofer la resuelve el admin
--        como siempre.
--   E1 · El admin anula una que nació resuelta: queda anulada y el total de la boleta vuelve.
--   L7 · Sobre una boleta cobrada, la del admin baja el total y recorta el cobro, y el recorte
--        queda anotado en la salvedad (cobro_recortado, COB-1 de #1559) aunque nazca resuelta;
--        anularla lo repone.
--
-- Corre sobre la base de CI sin dejar rastro (salvo valores de secuencia): un único DO que termina
-- siempre en una excepción, y cada caso en un sub-bloque que se revierte. Fixtures: una sucursal
-- activa con un admin, un encargado, un chofer y un preventista activos, y un cliente activo que no
-- sea de vale blanco. Los productos y los pedidos nacen en el ensayo. El día es el argentino
-- (_tablero_hoy()).

CREATE OR REPLACE FUNCTION pg_temp.so_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.so_reset()
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

CREATE OR REPLACE FUNCTION pg_temp.so_como(p_uid uuid, p_suc bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.so_total(p_ped bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT total FROM public.pedidos WHERE id = p_ped;
$fn$;

-- Un producto de $100 con stock 50 y un pedido de 5 unidades que carga el admin, en camino
-- (asignado) y repartido por p_tra. Devuelve {producto, pedido, item}.
CREATE OR REPLACE FUNCTION pg_temp.so_pedido(p_cli bigint, p_adm uuid, p_suc bigint, p_tra uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint;
  v_res  jsonb;
  v_ped  bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1700 ' || gen_random_uuid(), 100, 50, 60, p_suc)
  RETURNING id INTO v_prod;
  PERFORM pg_temp.so_como(p_adm, p_suc);
  v_res := public.crear_pedido_completo(
    p_cli, 500, p_adm,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 5, 'precio_unitario', 100)),
    'ensayo 1700');
  PERFORM pg_temp.so_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  -- Como el server (sin sesión): en camino y con su chofer. Una salvedad va sólo sobre un pedido
  -- en camino o entregado (D23).
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = p_tra WHERE id = v_ped;
  RETURN jsonb_build_object('producto', v_prod, 'pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod ORDER BY id LIMIT 1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.so_salvedad(p_uid uuid, p_suc bigint, p_ped bigint, p_item bigint, p_clave uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.so_como(p_uid, p_suc);
  v_res := public.registrar_salvedad(p_ped, p_item, 1, 'cliente_rechaza', 'ensayo 1700', NULL, true, p_clave);
  PERFORM pg_temp.so_reset();
  RETURN v_res;
END
$fn$;

-- Lo que una salvedad que nació resuelta por la oficina tiene que tener.
CREATE OR REPLACE FUNCTION pg_temp.so_nacio_resuelta(p_f text[], p_res jsonb, p_uid uuid, p_ped bigint, p_quien text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f   text[] := p_f;
  s   record;
  v_s bigint := (p_res->>'salvedad_id')::bigint;
BEGIN
  IF NOT COALESCE((p_res->>'success')::boolean, false) THEN
    RETURN f || format('la salvedad %s no entró: %s', p_quien, p_res);
  END IF;
  SELECT * INTO s FROM public.salvedades_items WHERE id = v_s;
  f := pg_temp.so_si(f, s.estado_resolucion = 'resuelto_otro',
         format('la %s nació %s, no resuelto_otro', p_quien, s.estado_resolucion));
  f := pg_temp.so_si(f, s.resolucion_notas = 'Cargada y resuelta por la oficina',
         format('la %s tiene la nota %L', p_quien, s.resolucion_notas));
  f := pg_temp.so_si(f, s.resuelto_por = p_uid AND s.reportado_por = p_uid,
         format('la %s: resuelto_por %s, reportado_por %s', p_quien, s.resuelto_por, s.reportado_por));
  f := pg_temp.so_si(f, s.resolucion_fecha = s.created_at,
         format('la %s: resolucion_fecha %s y created_at %s', p_quien, s.resolucion_fecha, s.created_at));
  f := pg_temp.so_si(f, p_res->>'estado_resolucion' = 'resuelto_otro',
         format('la respuesta %s dice estado_resolucion %s', p_quien, p_res->>'estado_resolucion'));
  f := pg_temp.so_si(f,
         (SELECT array_agg(accion || ':' || COALESCE(estado_anterior, '-') || '>' || estado_nuevo ORDER BY id)
            FROM public.salvedad_historial WHERE salvedad_id = v_s)
           = ARRAY['creacion:->pendiente', 'resolucion:pendiente>resuelto_otro']
         AND (SELECT usuario_id FROM public.salvedad_historial WHERE salvedad_id = v_s AND accion = 'resolucion') = p_uid,
         format('el historial de la %s es %s', p_quien,
                (SELECT array_agg(accion || ':' || COALESCE(estado_anterior, '-') || '>' || estado_nuevo ORDER BY id)
                   FROM public.salvedad_historial WHERE salvedad_id = v_s)));
  -- No mueve plata: ni nota de crédito ni cargo a un empleado.
  f := pg_temp.so_si(f, NOT EXISTS (SELECT 1 FROM public.notas_credito_venta WHERE pedido_id = p_ped)
                        AND NOT EXISTS (SELECT 1 FROM public.empleado_movimientos WHERE salvedad_id = v_s),
         format('la %s movió plata (nota de crédito o cargo a un empleado)', p_quien));
  RETURN f;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.so_nacio_pendiente(p_f text[], p_res jsonb, p_uid uuid, p_quien text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f   text[] := p_f;
  s   record;
  v_s bigint := (p_res->>'salvedad_id')::bigint;
BEGIN
  IF NOT COALESCE((p_res->>'success')::boolean, false) THEN
    RETURN f || format('la salvedad %s no entró: %s', p_quien, p_res);
  END IF;
  SELECT * INTO s FROM public.salvedades_items WHERE id = v_s;
  f := pg_temp.so_si(f, s.estado_resolucion = 'pendiente' AND s.resolucion_notas IS NULL
                        AND s.resuelto_por IS NULL AND s.resolucion_fecha IS NULL AND s.reportado_por = p_uid,
         format('la %s nació %s (nota %L, resuelto_por %s)', p_quien, s.estado_resolucion,
                s.resolucion_notas, s.resuelto_por));
  f := pg_temp.so_si(f, p_res->>'estado_resolucion' = 'pendiente',
         format('la respuesta %s dice estado_resolucion %s', p_quien, p_res->>'estado_resolucion'));
  f := pg_temp.so_si(f, (SELECT count(*) FROM public.salvedad_historial WHERE salvedad_id = v_s AND accion = 'resolucion') = 0,
         format('la %s tiene una resolución en el historial', p_quien));
  RETURN f;
END
$fn$;

-- L1 · admin
CREATE OR REPLACE FUNCTION pg_temp.so_caso_l1(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_adm uuid := (r->>'adm')::uuid;
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb := pg_temp.so_pedido((r->>'cli')::bigint, v_adm, v_suc, (r->>'tra')::uuid);
  k     uuid := gen_random_uuid();
  v_res jsonb;
  v_rep jsonb;
BEGIN
  v_res := pg_temp.so_salvedad(v_adm, v_suc, (x->>'pedido')::bigint, (x->>'item')::bigint, k);
  f := pg_temp.so_nacio_resuelta(f, v_res, v_adm, (x->>'pedido')::bigint, 'del admin');
  f := pg_temp.so_si(f, pg_temp.so_total((x->>'pedido')::bigint) = 400,
         format('la salvedad del admin dejó el total en %s, no en 400', pg_temp.so_total((x->>'pedido')::bigint)));
  -- El reintento con la misma clave contesta la misma salvedad, con su estado.
  v_rep := pg_temp.so_salvedad(v_adm, v_suc, (x->>'pedido')::bigint, (x->>'item')::bigint, k);
  f := pg_temp.so_si(f, COALESCE((v_rep->>'success')::boolean, false)
                        AND v_rep->>'salvedad_id' = v_res->>'salvedad_id'
                        AND v_rep->>'estado_resolucion' = 'resuelto_otro',
         format('el reintento contestó %s', v_rep));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- L2 · encargado
CREATE OR REPLACE FUNCTION pg_temp.so_caso_l2(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_enc uuid := (r->>'enc')::uuid;
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb := pg_temp.so_pedido((r->>'cli')::bigint, (r->>'adm')::uuid, v_suc, (r->>'tra')::uuid);
BEGIN
  f := pg_temp.so_nacio_resuelta(f,
         pg_temp.so_salvedad(v_enc, v_suc, (x->>'pedido')::bigint, (x->>'item')::bigint, gen_random_uuid()),
         v_enc, (x->>'pedido')::bigint, 'del encargado');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- L3 · encargado con el rol extra de chofer
CREATE OR REPLACE FUNCTION pg_temp.so_caso_l3(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_enc uuid := (r->>'enc')::uuid;
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_enc, v_suc, 'transportista')
  ON CONFLICT DO NOTHING;
  x := pg_temp.so_pedido((r->>'cli')::bigint, (r->>'adm')::uuid, v_suc, (r->>'tra')::uuid);
  f := pg_temp.so_nacio_resuelta(f,
         pg_temp.so_salvedad(v_enc, v_suc, (x->>'pedido')::bigint, (x->>'item')::bigint, gen_random_uuid()),
         v_enc, (x->>'pedido')::bigint, 'del encargado con el extra de chofer');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- L4 · chofer
CREATE OR REPLACE FUNCTION pg_temp.so_caso_l4(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_tra uuid := (r->>'tra')::uuid;
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb := pg_temp.so_pedido((r->>'cli')::bigint, (r->>'adm')::uuid, v_suc, v_tra);
BEGIN
  f := pg_temp.so_nacio_pendiente(f,
         pg_temp.so_salvedad(v_tra, v_suc, (x->>'pedido')::bigint, (x->>'item')::bigint, gen_random_uuid()),
         v_tra, 'del chofer');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- L5 · preventista con el rol extra de chofer, sobre un pedido que él reparte
CREATE OR REPLACE FUNCTION pg_temp.so_caso_l5(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_pre uuid := (r->>'pre')::uuid;
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_pre, v_suc, 'transportista')
  ON CONFLICT DO NOTHING;
  x := pg_temp.so_pedido((r->>'cli')::bigint, (r->>'adm')::uuid, v_suc, v_pre);
  f := pg_temp.so_nacio_pendiente(f,
         pg_temp.so_salvedad(v_pre, v_suc, (x->>'pedido')::bigint, (x->>'item')::bigint, gen_random_uuid()),
         v_pre, 'del preventista que reparte');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- L6 · una resuelta no se vuelve a resolver; la pendiente del chofer sí se resuelve
CREATE OR REPLACE FUNCTION pg_temp.so_caso_l6(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_adm uuid := (r->>'adm')::uuid;
  v_tra uuid := (r->>'tra')::uuid;
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb := pg_temp.so_pedido((r->>'cli')::bigint, v_adm, v_suc, v_tra);
  y     jsonb := pg_temp.so_pedido((r->>'cli')::bigint, v_adm, v_suc, v_tra);
  v_of  jsonb;
  v_ch  jsonb;
  v_res jsonb;
BEGIN
  v_of := pg_temp.so_salvedad(v_adm, v_suc, (x->>'pedido')::bigint, (x->>'item')::bigint, gen_random_uuid());
  v_ch := pg_temp.so_salvedad(v_tra, v_suc, (y->>'pedido')::bigint, (y->>'item')::bigint, gen_random_uuid());
  PERFORM pg_temp.so_como(v_adm, v_suc);
  v_res := public.resolver_salvedad((v_of->>'salvedad_id')::bigint, 'absorcion_empresa', 'ensayo 1700', NULL, NULL);
  f := pg_temp.so_si(f, NOT COALESCE((v_res->>'success')::boolean, true) AND v_res->>'error' = 'Ya resuelta',
         format('resolver la que nació resuelta contestó %s', v_res));
  f := pg_temp.so_si(f, (SELECT estado_resolucion FROM public.salvedades_items
                          WHERE id = (v_of->>'salvedad_id')::bigint) = 'resuelto_otro',
         'resolver la que nació resuelta le cambió el estado');
  v_res := public.resolver_salvedad((v_ch->>'salvedad_id')::bigint, 'absorcion_empresa', 'ensayo 1700', NULL, NULL);
  f := pg_temp.so_si(f, COALESCE((v_res->>'success')::boolean, false)
                        AND (SELECT estado_resolucion FROM public.salvedades_items
                              WHERE id = (v_ch->>'salvedad_id')::bigint) = 'absorcion_empresa',
         format('resolver la pendiente del chofer contestó %s', v_res));
  PERFORM pg_temp.so_reset();
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- E1 · el admin anula una que nació resuelta
CREATE OR REPLACE FUNCTION pg_temp.so_caso_e1(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_adm uuid := (r->>'adm')::uuid;
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb := pg_temp.so_pedido((r->>'cli')::bigint, v_adm, v_suc, (r->>'tra')::uuid);
  v_ped bigint := (x->>'pedido')::bigint;
  v_s   jsonb;
  v_res jsonb;
BEGIN
  v_s := pg_temp.so_salvedad(v_adm, v_suc, v_ped, (x->>'item')::bigint, gen_random_uuid());
  IF NOT COALESCE((v_s->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la salvedad no entró: %', v_s;
  END IF;
  PERFORM pg_temp.so_como(v_adm, v_suc);
  v_res := public.anular_salvedad((v_s->>'salvedad_id')::bigint, 'ensayo 1700');
  PERFORM pg_temp.so_reset();
  f := pg_temp.so_si(f, COALESCE((v_res->>'success')::boolean, false)
                        AND (SELECT estado_resolucion FROM public.salvedades_items
                              WHERE id = (v_s->>'salvedad_id')::bigint) = 'anulada',
         format('anular la que nació resuelta contestó %s', v_res));
  f := pg_temp.so_si(f, pg_temp.so_total(v_ped) = 500,
         format('anularla dejó el total en %s, no en 500', pg_temp.so_total(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- L7 · sobre una boleta cobrada, el recorte del cobro queda en la salvedad que nace resuelta
CREATE OR REPLACE FUNCTION pg_temp.so_caso_l7(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_adm uuid := (r->>'adm')::uuid;
  v_tra uuid := (r->>'tra')::uuid;
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb := pg_temp.so_pedido((r->>'cli')::bigint, v_adm, v_suc, v_tra);
  v_ped bigint := (x->>'pedido')::bigint;
  v_s   jsonb;
  v_res jsonb;
  s     record;
BEGIN
  PERFORM pg_temp.so_como(v_tra, v_suc);
  v_res := public.registrar_pagos_pedido(v_ped, '[{"monto": 500, "forma_pago": "efectivo"}]'::jsonb,
                                         public._tablero_hoy());
  PERFORM pg_temp.so_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, true) OR v_res ? 'error' THEN
    RAISE EXCEPTION 'no se pudo cobrar: %', v_res;
  END IF;
  v_s := pg_temp.so_salvedad(v_adm, v_suc, v_ped, (x->>'item')::bigint, gen_random_uuid());
  f := pg_temp.so_nacio_resuelta(f, v_s, v_adm, v_ped, 'del admin sobre una boleta cobrada');
  SELECT * INTO s FROM public.salvedades_items WHERE id = (v_s->>'salvedad_id')::bigint;
  f := pg_temp.so_si(f, jsonb_typeof(s.cobro_recortado) = 'array'
                        AND (SELECT sum((e->>'monto')::numeric) FROM jsonb_array_elements(s.cobro_recortado) e) = 100,
         format('el recorte del cobro no quedó en la salvedad: cobro_recortado %s', s.cobro_recortado));
  f := pg_temp.so_si(f, (SELECT monto_pagado FROM public.pedidos WHERE id = v_ped) = 400,
         format('la boleta quedó con %s pagado, no 400', (SELECT monto_pagado FROM public.pedidos WHERE id = v_ped)));
  PERFORM pg_temp.so_como(v_adm, v_suc);
  v_res := public.anular_salvedad((v_s->>'salvedad_id')::bigint, 'ensayo 1700');
  PERFORM pg_temp.so_reset();
  f := pg_temp.so_si(f, COALESCE((v_res->>'success')::boolean, false)
                        AND (SELECT monto_pagado FROM public.pedidos WHERE id = v_ped) = 500
                        AND pg_temp.so_total(v_ped) = 500,
         format('anularla no repuso el cobro: %s, pagado %s, total %s', v_res,
                (SELECT monto_pagado FROM public.pedidos WHERE id = v_ped), pg_temp.so_total(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1700$
DECLARE
  v_suc    bigint;
  v_r      jsonb;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
BEGIN
  -- Una sucursal activa con un usuario activo de cada rol y un cliente que no sea de vale blanco.
  SELECT s.id INTO v_suc
    FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM clientes c WHERE c.sucursal_id = s.id AND c.activo
                                            AND c.tipo_factura_default IS DISTINCT FROM 'VB')
     AND (SELECT count(DISTINCT p.rol) FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
           WHERE us.sucursal_id = s.id AND p.activo
             AND p.rol IN ('admin', 'encargado', 'transportista', 'preventista')) = 4
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · hace falta una sucursal activa con admin, encargado, chofer y preventista activos y un cliente activo';
  END IF;
  SELECT jsonb_build_object(
           'suc', v_suc,
           'cli', (SELECT id FROM clientes WHERE sucursal_id = v_suc AND activo
                     AND tipo_factura_default IS DISTINCT FROM 'VB' ORDER BY id LIMIT 1),
           'adm', (SELECT p.id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
                    WHERE us.sucursal_id = v_suc AND p.activo AND p.rol = 'admin' ORDER BY p.id LIMIT 1),
           'enc', (SELECT p.id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
                    WHERE us.sucursal_id = v_suc AND p.activo AND p.rol = 'encargado' ORDER BY p.id LIMIT 1),
           'tra', (SELECT p.id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
                    WHERE us.sucursal_id = v_suc AND p.activo AND p.rol = 'transportista' ORDER BY p.id LIMIT 1),
           'pre', (SELECT p.id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
                    WHERE us.sucursal_id = v_suc AND p.activo AND p.rol = 'preventista' ORDER BY p.id LIMIT 1))
    INTO v_r;

  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'e1', 'l7'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.so_reset();
      EXECUTE format('SELECT pg_temp.so_caso_%s($1)', v_caso) INTO v_out USING v_r;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas):\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK';
END
$ensayo1700$;
