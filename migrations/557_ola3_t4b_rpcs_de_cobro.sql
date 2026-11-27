-- =========================================================================
-- NNN · T4b · LAS RPCs DE COBRO CON QUIÉN COBRÓ (ola 3 de #1603, tanda T4; D1 de #1507, #1710)
--
-- Segunda de tres (ver la T4a). Pide la T4a aplicada. Ensayo: scripts/test-ola3-t4-cobro-de-quien.sql.
-- Se aplica en LF.
--
-- 1 · registrar_pagos_pedido, registrar_pago_cliente_fifo, registrar_pago_combinado_cliente_fifo y
--     marcar_pagos_masivo (wrapper y _impl) reciben p_cobrado_por (al final, con default: un PWA
--     viejo sigue andando y cobra a nombre de quien llama). La regla vive en el _impl
--     (_cobrador_de_cobro); el wrapper lo suma a p_contenido sólo si viene, así el contenido de una
--     solicitud de antes no cambia y un reintento con otro quién cobró da 22023. Se sacan las
--     firmas viejas (PGRST203). El pago a cuenta de la ficha es de quien lo carga (D1).
-- 2 · marcar_entrega_y_pago_masivo_impl: el cobro es del chofer elegido (la oficina carga la
--     entrega a su nombre).
-- 3 · desafectar_sobrepago_pedido guarda en cobro_recortado de qué caja era el cobro, y
--     anular_salvedad repone el cobro en esa caja (uno anterior a la T4: el chofer de la boleta o
--     quien lo cargó).
-- 4 · auditoria_definer_sin_rol: la lista blanca de SEG-A con las firmas y el md5 de los wrappers.
--
-- PREMISAS: la T4a, los cuerpos de la 555 (md5 de prosrc) de las doce funciones, una sola firma de
-- cada RPC de cobro. Todo se parchea por ancla (ver la T4a).
--
-- Revertir: volver las doce funciones a los cuerpos de las premisas (con sus firmas viejas).
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)', 'a7406466806b8e8465641580217df3ae'),
    ('public.registrar_pagos_pedido(bigint,jsonb,date,text,text,uuid)', '4ba5827629e9b48bf1fe72da2b1cebbb'),
    ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 'e7588424aae600abf8407b76d7da56b9'),
    ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', '3dd754478ee59e15e14cbeaad3d3e308'),
    ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 'b1f824a0c8f9713b8ba2c909a9ef3f5c'),
    ('public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)', '8497c398845f786dfbcff897d68acba0'),
    ('public.marcar_pagos_masivo_impl(bigint[],text,date)', 'd3a11592bf22f97275b9bd98ece355b7'),
    ('public.marcar_pagos_masivo(bigint[],text,date,uuid)', '1f13baa2aaba49f787c2198fb774e586'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', 'c83df3208d9b057fff7877dd519e1516'),
    ('public.desafectar_sobrepago_pedido(bigint)', 'b038256f1acf602b0ed20475215a3080'),
    ('public.anular_salvedad(bigint,text)', '66c0f0cf009d3ac552fba2e7046390c5'),
    ('public.auditoria_definer_sin_rol()', '7cc70e175cb0053031fccea759477348')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- La T4a: la columna y quién cobró.
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pagos'::regclass AND attname = 'cobrado_por')
     OR to_regprocedure('public._cobrador_de_cobro(uuid,bigint,uuid)') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pagos_zz_cobrado_por') THEN
    RAISE EXCEPTION 'mig NNN · falta la T4a (pagos.cobrado_por, _cobrador_de_cobro, el trigger): aplicarla antes';
  END IF;
  -- Una sola firma de cada RPC de cobro: la que se reemplaza.
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('registrar_pagos_pedido', 'registrar_pagos_pedido_impl',
                       'registrar_pago_cliente_fifo', 'registrar_pago_cliente_fifo_impl',
                       'registrar_pago_combinado_cliente_fifo', 'registrar_pago_combinado_cliente_fifo_impl',
                       'marcar_pagos_masivo', 'marcar_pagos_masivo_impl')) <> 8 THEN
    RAISE EXCEPTION 'mig NNN · hay más de una firma de una RPC de cobro';
  END IF;
END
$premisas$;

-- Parche por ancla: cada ancla tiene que aparecer exactamente las veces que se espera.
CREATE FUNCTION pg_temp.t4_parche(p_def text, p_viejo text, p_nuevo text, p_veces int)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  n int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF n <> p_veces THEN
    RAISE EXCEPTION 'mig NNN · un ancla aparece % veces (esperaba %): %', n, p_veces, left(p_viejo, 100);
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$f$;

-- registrar_pagos_pedido_impl
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$p_referencia text DEFAULT NULL::text)
 RETURNS jsonb$o$,
    $n$p_referencia text DEFAULT NULL::text, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb$n$, 1);
  v := pg_temp.t4_parche(v, $o$  v_pago_ids    bigint[] := '{}';
$o$,
    $n$  v_pago_ids    bigint[] := '{}';
  v_cobrador    uuid;
$n$, 1);
  v := pg_temp.t4_parche(v, $o$      USING ERRCODE = '42501';
  END IF;

  -- Los mismos rechazos que los triggers$o$,
    $n$      USING ERRCODE = '42501';
  END IF;

  -- T4 (#1710, D1 de #1507): quien cobró. Lo decide _cobrador_de_cobro: el que llama,
  -- o el que elige el admin (el encargado, sólo el chofer de la boleta).
  v_cobrador := public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, v_pedido.transportista_id);

  -- Los mismos rechazos que los triggers$n$, 1);
  v := pg_temp.t4_parche(v, $o$      referencia, notas, usuario_id, sucursal_id
    )$o$,
    $n$      referencia, notas, usuario_id, sucursal_id, cobrado_por
    )$n$, 1);
  v := pg_temp.t4_parche(v, $o$NULLIF(trim(p_notas), ''), v_usuario, v_sucursal_id
    )$o$,
    $n$NULLIF(trim(p_notas), ''), v_usuario, v_sucursal_id, v_cobrador
    )$n$, 1);
  DROP FUNCTION public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text);
  EXECUTE v;
END
$t4$;
-- registrar_pagos_pedido
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.registrar_pagos_pedido(bigint,jsonb,date,text,text,uuid)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$p_client_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb$o$,
    $n$p_client_request_id uuid DEFAULT NULL::uuid, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb$n$, 1);
  v := pg_temp.t4_parche(v, $o$jsonb_build_object('pedido_id', p_pedido_id, 'metodos', p_metodos));$o$,
    $n$jsonb_build_object('pedido_id', p_pedido_id, 'metodos', p_metodos)
    -- T4: quién cobró es de qué caja es el cobro. Sin elegir, el contenido es el de antes.
    || CASE WHEN p_cobrado_por IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('cobrado_por', p_cobrado_por) END);$n$, 1);
  v := pg_temp.t4_parche(v, $o$p_pedido_id, p_metodos, p_fecha, p_notas, p_referencia
  );$o$,
    $n$p_pedido_id, p_metodos, p_fecha, p_notas, p_referencia, p_cobrado_por
  );$n$, 1);
  DROP FUNCTION public.registrar_pagos_pedido(bigint,jsonb,date,text,text,uuid);
  EXECUTE v;
END
$t4$;
-- registrar_pago_cliente_fifo_impl
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$p_notas text DEFAULT NULL::text)
 RETURNS jsonb$o$,
    $n$p_notas text DEFAULT NULL::text, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb$n$, 1);
  v := pg_temp.t4_parche(v, $o$  v_credito_aplicado numeric := 0;
$o$,
    $n$  v_credito_aplicado numeric := 0;
  v_cobrador uuid;
$n$, 1);
  v := pg_temp.t4_parche(v, $o$desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;
$o$,
    $n$desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  -- T4 (#1710, D1 de #1507): quien cobró. Lo decide _cobrador_de_cobro: el que llama,
  -- o el que elige el admin (el encargado, sólo el chofer de la boleta).
  -- El pago a cuenta de la ficha es de la caja de quien lo carga (D1), no del chofer
  -- de las boletas a las que lo imputa el FIFO.
  v_cobrador := public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, NULL);
$n$, 1);
  v := pg_temp.t4_parche(v, $o$referencia, notas, usuario_id, sucursal_id, a_cuenta
    )$o$,
    $n$referencia, notas, usuario_id, sucursal_id, a_cuenta, cobrado_por
    )$n$, 2);
  v := pg_temp.t4_parche(v, $o$v_acting_user, v_sucursal_id, true
    )$o$,
    $n$v_acting_user, v_sucursal_id, true, v_cobrador
    )$n$, 2);
  DROP FUNCTION public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text);
  EXECUTE v;
END
$t4$;
-- registrar_pago_cliente_fifo
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$p_client_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb$o$,
    $n$p_client_request_id uuid DEFAULT NULL::uuid, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb$n$, 1);
  v := pg_temp.t4_parche(v, $o$'monto', p_monto, 'forma_pago', p_forma_pago));$o$,
    $n$'monto', p_monto, 'forma_pago', p_forma_pago)
    || CASE WHEN p_cobrado_por IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('cobrado_por', p_cobrado_por) END);$n$, 1);
  v := pg_temp.t4_parche(v, $o$p_cliente_id, p_monto, p_forma_pago, p_fecha, p_referencia, p_notas
  );$o$,
    $n$p_cliente_id, p_monto, p_forma_pago, p_fecha, p_referencia, p_notas, p_cobrado_por
  );$n$, 1);
  DROP FUNCTION public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid);
  EXECUTE v;
END
$t4$;
-- registrar_pago_combinado_cliente_fifo_impl
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$p_notas text DEFAULT NULL::text)
 RETURNS jsonb$o$,
    $n$p_notas text DEFAULT NULL::text, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb$n$, 1);
  v := pg_temp.t4_parche(v, $o$  v_credito_aplicado numeric := 0;
$o$,
    $n$  v_credito_aplicado numeric := 0;
  v_cobrador uuid;
$n$, 1);
  v := pg_temp.t4_parche(v, $o$desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;
$o$,
    $n$desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  -- T4 (#1710, D1 de #1507): quien cobró. Lo decide _cobrador_de_cobro: el que llama,
  -- o el que elige el admin (el encargado, sólo el chofer de la boleta).
  v_cobrador := public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, NULL);
$n$, 1);
  v := pg_temp.t4_parche(v, $o$referencia, notas, usuario_id, sucursal_id, a_cuenta
      )$o$,
    $n$referencia, notas, usuario_id, sucursal_id, a_cuenta, cobrado_por
      )$n$, 2);
  v := pg_temp.t4_parche(v, $o$v_acting_user, v_sucursal_id, true
      )$o$,
    $n$v_acting_user, v_sucursal_id, true, v_cobrador
      )$n$, 2);
  DROP FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text);
  EXECUTE v;
END
$t4$;
-- registrar_pago_combinado_cliente_fifo
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$p_client_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb$o$,
    $n$p_client_request_id uuid DEFAULT NULL::uuid, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb$n$, 1);
  v := pg_temp.t4_parche(v, $o$jsonb_build_object('cliente_id', p_cliente_id, 'metodos', p_metodos));$o$,
    $n$jsonb_build_object('cliente_id', p_cliente_id, 'metodos', p_metodos)
    || CASE WHEN p_cobrado_por IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('cobrado_por', p_cobrado_por) END);$n$, 1);
  v := pg_temp.t4_parche(v, $o$p_cliente_id, p_metodos, p_fecha, p_referencia, p_notas
  );$o$,
    $n$p_cliente_id, p_metodos, p_fecha, p_referencia, p_notas, p_cobrado_por
  );$n$, 1);
  DROP FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid);
  EXECUTE v;
END
$t4$;
-- marcar_pagos_masivo_impl
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.marcar_pagos_masivo_impl(bigint[],text,date)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$::date)
 RETURNS integer$o$,
    $n$::date, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS integer$n$, 1);
  v := pg_temp.t4_parche(v, $o$    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
$o$,
    $n$    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado, transportista_id
$n$, 1);
  v := pg_temp.t4_parche(v, $o$    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
$o$,
    $n$    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id,
                       cobrado_por)
$n$, 1);
  v := pg_temp.t4_parche(v, $o$      auth.uid(),
      v_sucursal_id
    );$o$,
    $n$      auth.uid(),
      v_sucursal_id,
      -- T4 (#1710): el cobro masivo de la oficina es de quien lo carga; el admin elige otro,
      -- y el encargado sólo el chofer de cada boleta.
      public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, v_pedido.transportista_id)
    );$n$, 1);
  DROP FUNCTION public.marcar_pagos_masivo_impl(bigint[],text,date);
  EXECUTE v;
END
$t4$;
-- marcar_pagos_masivo
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.marcar_pagos_masivo(bigint[],text,date,uuid)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$p_client_request_id uuid DEFAULT NULL::uuid)
 RETURNS integer$o$,
    $n$p_client_request_id uuid DEFAULT NULL::uuid, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS integer$n$, 1);
  v := pg_temp.t4_parche(v, $o$                       'forma_pago', p_forma_pago));$o$,
    $n$                       'forma_pago', p_forma_pago)
    || CASE WHEN p_cobrado_por IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('cobrado_por', p_cobrado_por) END);$n$, 1);
  v := pg_temp.t4_parche(v, $o$marcar_pagos_masivo_impl(p_pedido_ids, p_forma_pago, p_fecha);$o$,
    $n$marcar_pagos_masivo_impl(p_pedido_ids, p_forma_pago, p_fecha, p_cobrado_por);$n$, 1);
  DROP FUNCTION public.marcar_pagos_masivo(bigint[],text,date,uuid);
  EXECUTE v;
END
$t4$;
-- marcar_entrega_y_pago_masivo_impl
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
$o$,
    $n$    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id,
                       cobrado_por)
$n$, 1);
  v := pg_temp.t4_parche(v, $o$      auth.uid(),
      v_sucursal_id
    );$o$,
    $n$      auth.uid(),
      v_sucursal_id,
      -- T4 (#1710): la oficina carga la entrega a nombre del chofer elegido: el cobro es suyo.
      COALESCE(p_transportista_id, auth.uid())
    );$n$, 1);
  EXECUTE v;
END
$t4$;
-- desafectar_sobrepago_pedido
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.desafectar_sobrepago_pedido(bigint)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id,
$o$,
    $n$    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id, cobrado_por,
$n$, 1);
  v := pg_temp.t4_parche(v, $o$                    'usuario_id', v_pago.usuario_id))$o$,
    $n$                    'usuario_id', v_pago.usuario_id,
                    -- T4: de qué caja era, para que el cobro que repone anular_salvedad vuelva a ella.
                    'cobrado_por', v_pago.cobrado_por))$n$, 1);
  EXECUTE v;
END
$t4$;
-- anular_salvedad
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$                         a_cuenta, pago_origen_id, pago_padre_id)
$o$,
    $n$                         a_cuenta, pago_origen_id, pago_padre_id, cobrado_por)
$n$, 1);
  v := pg_temp.t4_parche(v, $o$COALESCE((r_rec.e->'marcas'->>'pago_padre_id')::bigint, (r_rec.e->'marcas'->>'pago_origen_id')::bigint)
$o$,
    $n$COALESCE((r_rec.e->'marcas'->>'pago_padre_id')::bigint, (r_rec.e->'marcas'->>'pago_origen_id')::bigint),
             -- T4 (#1710): la caja del cobro recortado. Un recorte anterior a la T4 no la guardó:
             -- la de antes, el chofer de la boleta o quien lo cargó.
             COALESCE((r_rec.e->>'cobrado_por')::uuid, p.transportista_id, (r_rec.e->>'usuario_id')::uuid)
$n$, 1);
  EXECUTE v;
END
$t4$;
-- auditoria_definer_sin_rol
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$    ('registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)',             '3dd754478ee59e15e14cbeaad3d3e308'),
$o$,
    $n$    -- T4 (#1710): con p_cobrado_por.
    ('registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid,uuid)',        '683067bbb0713631ed085ab9abc583f2'),
$n$, 1);
  v := pg_temp.t4_parche(v, $o$    ('registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)',          '8497c398845f786dfbcff897d68acba0'),
$o$,
    $n$    ('registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid,uuid)',     '8ce481f5badb52f3290df590b0ee36e9'),
$n$, 1);
  v := pg_temp.t4_parche(v, $o$    ('marcar_pagos_masivo(bigint[],text,date,uuid)',                                     '1f13baa2aaba49f787c2198fb774e586'),
$o$,
    $n$    ('marcar_pagos_masivo(bigint[],text,date,uuid,uuid)',                                '3f0c0664a5f79426e2820bea1df5f592'),
$n$, 1);
  EXECUTE v;
END
$t4$;


REVOKE ALL ON FUNCTION public.registrar_pagos_pedido(bigint, jsonb, date, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pagos_pedido(bigint, jsonb, date, text, text, uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.registrar_pago_cliente_fifo(bigint, numeric, text, date, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pago_cliente_fifo(bigint, numeric, text, date, text, text, uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint, jsonb, date, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint, jsonb, date, text, text, uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.marcar_pagos_masivo(bigint[], text, date, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_pagos_masivo(bigint[], text, date, uuid, uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.registrar_pagos_pedido_impl(bigint, jsonb, date, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_pagos_pedido_impl(bigint, jsonb, date, text, text, uuid) TO service_role;
REVOKE ALL ON FUNCTION public.registrar_pago_cliente_fifo_impl(bigint, numeric, text, date, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_pago_cliente_fifo_impl(bigint, numeric, text, date, text, text, uuid) TO service_role;
REVOKE ALL ON FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(bigint, jsonb, date, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(bigint, jsonb, date, text, text, uuid) TO service_role;
REVOKE ALL ON FUNCTION public.marcar_pagos_masivo_impl(bigint[], text, date, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_pagos_masivo_impl(bigint[], text, date, uuid) TO service_role;


-- -------------------------------------------------------------------------
-- Poscondiciones
-- -------------------------------------------------------------------------
DO $pos$
DECLARE
  r record;
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('registrar_pagos_pedido', 'registrar_pagos_pedido_impl',
                       'registrar_pago_cliente_fifo', 'registrar_pago_cliente_fifo_impl',
                       'registrar_pago_combinado_cliente_fifo', 'registrar_pago_combinado_cliente_fifo_impl',
                       'marcar_pagos_masivo', 'marcar_pagos_masivo_impl')
       AND pg_get_function_identity_arguments(oid) LIKE '%p_cobrado_por uuid') <> 8
     OR (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
          AND proname IN ('registrar_pagos_pedido', 'registrar_pagos_pedido_impl',
                          'registrar_pago_cliente_fifo', 'registrar_pago_cliente_fifo_impl',
                          'registrar_pago_combinado_cliente_fifo', 'registrar_pago_combinado_cliente_fifo_impl',
                          'marcar_pagos_masivo', 'marcar_pagos_masivo_impl')) <> 8 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: las ocho RPCs de cobro no quedaron con p_cobrado_por y una sola firma';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname IN ('registrar_pagos_pedido_impl', 'registrar_pago_cliente_fifo_impl',
                                  'registrar_pago_combinado_cliente_fifo_impl', 'marcar_pagos_masivo_impl')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('authenticated', p.oid, 'EXECUTE')))
     OR EXISTS (SELECT 1 FROM pg_proc p
                 WHERE p.pronamespace = 'public'::regnamespace
                   AND p.proname IN ('registrar_pagos_pedido', 'registrar_pago_cliente_fifo',
                                     'registrar_pago_combinado_cliente_fifo', 'marcar_pagos_masivo')
                   AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                        OR NOT has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'mig NNN · poscondición: los EXECUTE de las RPCs de cobro quedaron mal';
  END IF;
  -- La lista blanca de SEG-A tiene el md5 de los wrappers que quedaron.
  FOR r IN SELECT p.oid::regprocedure::text AS f, md5(p.prosrc) AS h FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace
              AND p.proname IN ('registrar_pago_cliente_fifo', 'registrar_pago_combinado_cliente_fifo', 'marcar_pagos_masivo')
  LOOP
    IF position(r.h IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_definer_sin_rol()'::regprocedure)) = 0 THEN
      RAISE EXCEPTION 'mig NNN · poscondición: la lista blanca de SEG-A no tiene el md5 de %', r.f;
    END IF;
  END LOOP;
END
$pos$;

COMMIT;
