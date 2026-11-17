-- Ensayo de la tarjeta B4 de la ola 2 del plan #1603: pedidos, el alta y la edición.
-- Migración: migrations/NNN_pedidos_alta_y_edicion.sql.
--
-- Un único DO con datos propios en la sucursal 1 (y la 2 para lo ajeno) que termina SIEMPRE
-- en una excepción: no deja rastro (salvo valores de secuencia). Veredicto: 'ENSAYO OK' o
-- 'ENSAYO FALLÓ' con la lista. Cada caso va en su bloque: uno que revienta queda como falla
-- y los demás siguen.
--
--   T1   · 1559-b1  · un alta con p_total un centavo arriba de la suma guarda la suma.
--   S4   · 1561-b4  · con la sucursal inactiva el alta y el bot se rechazan con el motivo (D33).
--   C7   · 1559-b7  · el alta con un cliente inactivo de otra sucursal no dice su nombre.
--   F5   · 1559-b5  · forma de pago 'bitcoin' se rechaza; 'cuenta_corriente' y 'transferencia' entran.
--   E6   · 1559-b6  · la programada va de hoy a 60 días (D21): hoy+61 y ayer se rechazan en el
--                     alta; hoy+60 entra; un alta con fecha de hace 2 días y programada de ayer
--                     (la cola) entra. En la edición, hoy+61 y ayer dan 22023; el admin que
--                     atrasa la fecha a hoy-3 con la programada en hoy-2 pasa; cambiar sólo las
--                     notas de un pedido con la programada vieja anda.
--   B2   · 1558-b2  · un regalo sin promoción (D4): el alta del admin se rechaza con el código
--                     del replay; el bot también; la edición conserva el que el pedido ya tenía
--                     y no deja sumarle.
--   I4   · 1559-b4  · el replay de crear_pedido_idempotente con la clave de otro usuario no
--                     devuelve el pedido.
--   V8   · 1559-b8  · el admin no pasa un vale blanco a fecha futura.
--   P9   · 1559-b9  · actualizar_preventista_pedido devuelve la versión de antes y la nueva.
--   N10  · 1559-b10 · actualizar_fechas_y_notas_pedido con una versión vieja contesta
--                     'pedido_editado_por_otro' y no toca nada; con la buena guarda y la mueve.
--   G6   · 1595-b6  · un PATCH no repone la versión: sólo updated_at la deja como estaba; con
--                     otro cambio la mueve a now().
--   K9   · 1595-b9  · el preventista no edita el pedido de un cliente dado de baja (el
--                     encargado sí, D24) ni el de un cliente que ya atiende otro.
--   R10  · 1595-b10 · (regresión) una línea con la promo de otra sucursal no entra: la FK
--                     compuesta de pedido_items.promocion_id ya lo cubría.
--   Z11  · 1595-b11 · (regresión, D25) el pase ZZ → FC de un entregado: el encargado no, el
--                     admin sí.
--   A2   · 1543-b2  · con app.cambio_cliente_desde, un producto desactivado entra sólo como lo
--                     tenía el pedido original: más cantidad o como regalo se rechaza.
--   C1   · 1592-b1  · R×10 cambiado por valor a W×1: la edición que manda W×1 deja el corte
--                     en 10.
--   Z2   · 1559-b2  · el pase ZZ → FC con una línea sin producto la deja en el desglose.
--   P3   · 1559-b3  · un producto que hoy no tiene lista se conserva a su precio (D20): el
--                     encargado edita con la misma línea; más cantidad u otro precio, no.
--   O4   · 1601-b4  · registrar_origen_precio_items no escribe la escala de otra sucursal, y la
--                     FK compuesta rechaza ponerla a mano (1601-b9).
--   SG1  · SEG-1    · cambiar_tipo_factura_pedido lee el rol con activo (estructura).
--   M10  · M10-2    · dias_atras_fecha_pedido() le da al depósito con el extra de chofer la
--                     política de su sucursal (2), no el 7.
--
-- Sin la migración fallan todos salvo R10 y Z11 (regresiones) y SG1 no se puede ejecutar
-- distinto (current_sucursal_id ya frena al desactivado): se mira el texto.
--
--   tr -d '\r' < scripts/test-pedidos-alta-edicion-ola2-1603.sql | docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -q

SET client_min_messages = warning;

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_enc    uuid;
  v_pre    uuid;
  v_pre2   uuid;
  v_dep    uuid;
  v_cli    bigint;
  v_cli2   bigint;
  v_clivb  bigint;
  v_otro   bigint;
  v_a      bigint;
  v_b      bigint;
  v_d      bigint;
  v_x      bigint;
  v_promo2 bigint;
  v_ped    bigint;
  v_ped2   bigint;
  v_it     bigint;
  v_j      jsonb;
  v_t      text;
  v_v1     timestamptz;
  v_n      numeric;
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
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b4-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'B4 ' || p_rol), now(), now());
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
  CREATE FUNCTION pg_temp.prod(p_nombre text, p_precio numeric DEFAULT 100) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, sucursal_id, categoria)
    VALUES ('B4 ' || p_nombre || ' ' || gen_random_uuid(), p_precio, 500, 10, 10, 10, 1, 'B4 ensayo') RETURNING id;
  $f$;
  CREATE FUNCTION pg_temp.venta(p_prod bigint, p_cant int, p_precio numeric DEFAULT 100) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio);
  $f$;
  CREATE FUNCTION pg_temp.regalo(p_prod bigint, p_cant int, p_promo bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0, 'es_bonificacion', true)
           || CASE WHEN p_promo IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('promocion_id', p_promo) END;
  $f$;
  -- El alta como p_uid. p_total NULL: la suma de las líneas.
  CREATE FUNCTION pg_temp.alta(p_uid uuid, p_cli bigint, p_items jsonb, p_forma text DEFAULT 'efectivo',
                               p_fecha date DEFAULT NULL, p_prog date DEFAULT NULL, p_tipo text DEFAULT 'ZZ',
                               p_total numeric DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE r jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid, 1);
    r := public.crear_pedido_completo(
      p_cli,
      COALESCE(p_total, (SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
                           FROM jsonb_array_elements(p_items) e)),
      p_uid, p_items, 'ensayo B4', p_forma, 'pendiente', p_fecha, p_tipo, NULL, 0, p_prog, NULL);
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  CREATE FUNCTION pg_temp.ok(p jsonb) RETURNS boolean LANGUAGE sql AS $f$
    SELECT COALESCE((p->>'success')::boolean, false);
  $f$;
  CREATE FUNCTION pg_temp.editar(p_uid uuid, p_ped bigint, p_items jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE r jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid, 1);
    r := public.actualizar_pedido_items(p_ped, p_items, p_uid);
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;

  -- ---------------------------------------------------------------- datos ---
  v_adm  := pg_temp.u('admin', 1);
  v_enc  := pg_temp.u('encargado', 1);
  v_pre  := pg_temp.u('preventista', 1);
  v_pre2 := pg_temp.u('preventista', 1);
  v_dep  := pg_temp.u('deposito', 1);
  INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_dep, 1, 'transportista');
  INSERT INTO politicas_comerciales (sucursal_id, dias_atras_fecha_pedido) VALUES (1, 2)
  ON CONFLICT (sucursal_id) DO UPDATE SET dias_atras_fecha_pedido = 2, monto_minimo_pedido = 0, modo_minimo_pedido = 'bloquear';
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('B4 cliente', 'B4 cliente', 'calle b4', 1) RETURNING id INTO v_cli;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('B4 cliente dos', 'B4 cliente dos', 'calle b4', 1) RETURNING id INTO v_cli2;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, tipo_factura_default)
  VALUES ('B4 consumo', 'B4 consumo', 'calle b4', 1, 'VB') RETURNING id INTO v_clivb;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, activo)
  VALUES ('B4 Secreto SA', 'B4 Secreto', 'calle ajena', 2, false) RETURNING id INTO v_otro;
  v_a := pg_temp.prod('A');
  v_b := pg_temp.prod('B');

  -- =======================================================================
  -- T1 · 1559-b1 · el total guardado es la suma
  -- =======================================================================
  BEGIN
    v_j := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 3)), p_total => 300.01);
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('T1 · el alta con un centavo de más no entró: %s', v_j);
    ELSIF (SELECT total FROM pedidos WHERE id = (v_j->>'pedido_id')::bigint) <> 300 THEN
      v_fallas := v_fallas || format('T1 · el total guardado es %s y no la suma (300)',
                                     (SELECT total FROM pedidos WHERE id = (v_j->>'pedido_id')::bigint));
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('T1 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- S4 · 1561-b4 · la sucursal inactiva no acepta pedidos
  -- =======================================================================
  BEGIN
    UPDATE sucursales SET activa = false WHERE id = 1;
    v_j := pg_temp.alta(v_pre, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)));
    -- Y el bot (D33 no distingue canales; lo pidió la revisión de la tarjeta).
    INSERT INTO bot_pedidos_pendientes (id, perfil_id, sucursal_id, cliente_id, items, total)
    VALUES ('00000000-0000-0000-0000-0000000b4b05', v_pre, 1, v_cli,
            jsonb_build_array(pg_temp.venta(v_a, 1)), 100);
    v_t := public.crear_pedido_completo_bot(v_pre, '00000000-0000-0000-0000-0000000b4b05')::text;
    UPDATE sucursales SET activa = true WHERE id = 1;
    IF pg_temp.ok(v_j) OR v_j::text NOT LIKE '%dada de baja: no acepta pedidos%' THEN
      v_fallas := v_fallas || format('S4 · el alta en una sucursal inactiva: %s', v_j);
    END IF;
    IF pg_temp.ok(v_t::jsonb) OR v_t NOT LIKE '%"error": "La sucursal % está dada de baja: no acepta pedidos%' THEN
      v_fallas := v_fallas || format('S4 · el bot en una sucursal inactiva: %s', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('S4 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- C7 · 1559-b7 · el cliente de otra sucursal
  -- =======================================================================
  BEGIN
    v_j := pg_temp.alta(v_adm, v_otro, jsonb_build_array(pg_temp.venta(v_a, 1)));
    IF pg_temp.ok(v_j) OR v_j::text LIKE '%Secreto%' OR v_j::text NOT LIKE '%no existe en esta sucursal%' THEN
      v_fallas := v_fallas || format('C7 · el alta con un cliente de otra sucursal: %s', v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('C7 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- F5 · 1559-b5 · la forma de pago
  -- =======================================================================
  BEGIN
    v_j := pg_temp.alta(v_pre, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)), p_forma => 'bitcoin');
    IF pg_temp.ok(v_j) OR v_j::text NOT LIKE '%forma de pago%' THEN
      v_fallas := v_fallas || format('F5 · forma de pago bitcoin: %s', v_j);
    END IF;
    v_j := pg_temp.alta(v_pre, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)), p_forma => 'cuenta_corriente');
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('F5 · cuenta_corriente no entró: %s', v_j);
    END IF;
    v_j := pg_temp.alta(v_pre, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)), p_forma => 'transferencia');
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('F5 · transferencia no entró: %s', v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('F5 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- E6 · 1559-b6 · la entrega programada (D21)
  -- =======================================================================
  BEGIN
    v_j := pg_temp.alta(v_pre, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)), p_prog => v_hoy + 61);
    IF pg_temp.ok(v_j) OR v_j::text NOT LIKE '%60 días%' THEN
      v_fallas := v_fallas || format('E6 · alta con programada hoy+61: %s', v_j);
    END IF;
    v_j := pg_temp.alta(v_pre, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)), p_prog => v_hoy - 1);
    IF pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('E6 · alta de hoy con programada de ayer: %s', v_j);
    END IF;
    v_j := pg_temp.alta(v_pre, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)), p_prog => v_hoy + 60);
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('E6 · alta con programada hoy+60 no entró: %s', v_j);
    END IF;
    v_j := pg_temp.alta(v_pre, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)), p_fecha => v_hoy - 2, p_prog => v_hoy - 1);
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('E6 · alta encolada (fecha hoy-2, programada ayer) no entró: %s', v_j);
    END IF;
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)))->>'pedido_id')::bigint;
    v_t := pg_temp.intenta(v_adm, format('SELECT public.actualizar_fechas_y_notas_pedido(%s, NULL, NULL, NULL, %L)::text',
                                         v_ped, v_hoy + 61));
    IF v_t NOT LIKE '22023%60 días%' THEN
      v_fallas := v_fallas || format('E6 · edición con programada hoy+61: %s', v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, format('SELECT public.actualizar_fechas_y_notas_pedido(%s, NULL, NULL, NULL, %L)::text',
                                         v_ped, v_hoy - 1));
    IF v_t NOT LIKE '22023%' THEN
      v_fallas := v_fallas || format('E6 · edición con programada de ayer: %s', v_t);
    END IF;
    -- El admin atrasa la fecha del pedido y el modal corre la programada con ella.
    v_t := pg_temp.intenta(v_adm, format('SELECT public.actualizar_fechas_y_notas_pedido(%s, NULL, %L, NULL, %L)::text',
                                         v_ped, v_hoy - 3, v_hoy - 2));
    IF v_t NOT LIKE 'PASA%' THEN
      v_fallas := v_fallas || format('E6 · el admin atrasó la fecha y la programada juntas y no anduvo: %s', v_t);
    END IF;
    UPDATE pedidos SET fecha = v_hoy, fecha_entrega_programada = v_hoy - 20 WHERE id = v_ped;
    v_t := pg_temp.intenta(v_adm, format('SELECT public.actualizar_fechas_y_notas_pedido(%s, %L)::text', v_ped, 'sólo notas'));
    IF v_t NOT LIKE 'PASA%' THEN
      v_fallas := v_fallas || format('E6 · cambiar sólo las notas de un pedido con la programada vieja: %s', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('E6 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- B2 · 1558-b2 · un regalo sin promoción (D4)
  -- =======================================================================
  BEGIN
    v_j := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 2), pg_temp.regalo(v_b, 1, NULL)));
    IF pg_temp.ok(v_j) OR v_j->>'codigo' IS DISTINCT FROM 'regalo_fuera_de_promo' THEN
      v_fallas := v_fallas || format('B2 · el alta del admin con un regalo sin promoción: %s', v_j);
    END IF;
    -- El bot.
    INSERT INTO bot_pedidos_pendientes (id, perfil_id, sucursal_id, cliente_id, items, total)
    VALUES ('00000000-0000-0000-0000-0000000b4b04', v_adm, 1, v_cli,
            jsonb_build_array(pg_temp.venta(v_a, 2), pg_temp.regalo(v_b, 1, NULL)), 200);
    v_j := public.crear_pedido_completo_bot(v_adm, '00000000-0000-0000-0000-0000000b4b04');
    IF pg_temp.ok(v_j) OR v_j::text NOT LIKE '%promoción%' THEN
      v_fallas := v_fallas || format('B2 · el bot con un regalo sin promoción: %s', v_j);
    END IF;
    -- Un pedido viejo con un regalo sin promoción (de antes de la regla).
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 2)))->>'pedido_id')::bigint;
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, sucursal_id)
    VALUES (v_ped, v_b, 1, 0, 0, true, 1);
    v_j := pg_temp.editar(v_adm, v_ped, jsonb_build_array(pg_temp.venta(v_a, 3), pg_temp.regalo(v_b, 1, NULL)));
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('B2 · la edición que conserva el regalo viejo no anduvo: %s', v_j);
    END IF;
    v_j := pg_temp.editar(v_adm, v_ped, jsonb_build_array(pg_temp.venta(v_a, 3), pg_temp.regalo(v_b, 2, NULL)));
    IF pg_temp.ok(v_j) OR v_j->>'codigo' IS DISTINCT FROM 'regalo_fuera_de_promo' THEN
      v_fallas := v_fallas || format('B2 · la edición le sumó al regalo sin promoción: %s', v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('B2 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- I4 · 1559-b4 · el replay con la clave de otro usuario
  -- =======================================================================
  BEGIN
    PERFORM pg_temp.como(v_pre, 1);
    v_j := public.crear_pedido_idempotente(v_cli, 100, v_pre, jsonb_build_array(pg_temp.venta(v_a, 1)),
                                           p_offline_id => 'b4-clave-' || v_pre);
    IF NOT pg_temp.ok(v_j) THEN
      RAISE EXCEPTION 'el alta idempotente no entró: %', v_j;
    END IF;
    PERFORM pg_temp.como(v_pre2, 1);
    v_j := public.crear_pedido_idempotente(v_cli, 100, v_pre2, jsonb_build_array(pg_temp.venta(v_a, 1)),
                                           p_offline_id => 'b4-clave-' || v_pre);
    PERFORM pg_temp.como(NULL, NULL);
    IF pg_temp.ok(v_j) OR v_j ? 'pedido_id' THEN
      v_fallas := v_fallas || format('I4 · el replay de otro usuario devolvió: %s', v_j);
    END IF;
    PERFORM pg_temp.como(v_pre, 1);
    v_j := public.crear_pedido_idempotente(v_cli, 100, v_pre, jsonb_build_array(pg_temp.venta(v_a, 1)),
                                           p_offline_id => 'b4-clave-' || v_pre);
    PERFORM pg_temp.como(NULL, NULL);
    IF NOT pg_temp.ok(v_j) OR NOT COALESCE((v_j->>'idempotente')::boolean, false) THEN
      v_fallas := v_fallas || format('I4 · el replay de quien lo cargó no anduvo: %s', v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('I4 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- V8 · 1559-b8 · un vale blanco no pasa a fecha futura
  -- =======================================================================
  BEGIN
    v_j := pg_temp.alta(v_adm, v_clivb, jsonb_build_array(pg_temp.venta(v_a, 1, 0)), p_tipo => 'VB', p_total => 0);
    IF NOT pg_temp.ok(v_j) THEN
      RAISE EXCEPTION 'el vale blanco no entró: %', v_j;
    END IF;
    v_t := pg_temp.intenta(v_adm, format('SELECT public.actualizar_fechas_y_notas_pedido(%s, NULL, %L)::text',
                                         (v_j->>'pedido_id')::bigint, v_hoy + 1));
    IF v_t NOT LIKE '22023%vale blanco%' THEN
      v_fallas := v_fallas || format('V8 · el admin pasó un vale blanco a mañana: %s', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('V8 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- P9 · 1559-b9 · actualizar_preventista_pedido devuelve la versión
  -- =======================================================================
  BEGIN
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)))->>'pedido_id')::bigint;
    UPDATE pedidos SET updated_at = now() - interval '1 hour' WHERE id = v_ped RETURNING updated_at INTO v_v1;
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.actualizar_preventista_pedido(v_ped, v_pre2);
    PERFORM pg_temp.como(NULL, NULL);
    IF NOT pg_temp.ok(v_j) OR (v_j->>'updated_at_anterior')::timestamptz IS DISTINCT FROM v_v1
       OR (v_j->>'updated_at')::timestamptz IS DISTINCT FROM (SELECT updated_at FROM pedidos WHERE id = v_ped)
       OR (v_j->>'updated_at')::timestamptz = v_v1 THEN
      v_fallas := v_fallas || format('P9 · la respuesta no trae las dos versiones: %s', v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('P9 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- N10 · 1559-b10 · fechas y notas con control de versión
  -- =======================================================================
  BEGIN
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)))->>'pedido_id')::bigint;
    UPDATE pedidos SET updated_at = now() - interval '1 hour', notas = 'antes' WHERE id = v_ped RETURNING updated_at INTO v_v1;
    v_t := pg_temp.intenta(v_adm, format(
      'SELECT public.actualizar_fechas_y_notas_pedido(%s, %L, p_updated_at_esperado => %L)::text',
      v_ped, 'pisada', v_v1 - interval '1 minute'));
    IF v_t NOT LIKE 'PASA%pedido_editado_por_otro%' OR (SELECT notas FROM pedidos WHERE id = v_ped) <> 'antes' THEN
      v_fallas := v_fallas || format('N10 · con una versión vieja: %s (notas: %s)', v_t, (SELECT notas FROM pedidos WHERE id = v_ped));
    END IF;
    v_t := pg_temp.intenta(v_adm, format(
      'SELECT public.actualizar_fechas_y_notas_pedido(%s, %L, p_updated_at_esperado => %L)::text', v_ped, 'nueva', v_v1));
    IF v_t NOT LIKE 'PASA%' OR (SELECT notas FROM pedidos WHERE id = v_ped) <> 'nueva'
       OR (SELECT updated_at FROM pedidos WHERE id = v_ped) = v_v1 THEN
      v_fallas := v_fallas || format('N10 · con la versión buena: %s (notas %s, versión movida %s)', v_t,
                                     (SELECT notas FROM pedidos WHERE id = v_ped),
                                     (SELECT updated_at FROM pedidos WHERE id = v_ped) <> v_v1);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('N10 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- G6 · 1595-b6 · un PATCH no repone la versión
  -- =======================================================================
  BEGIN
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)))->>'pedido_id')::bigint;
    UPDATE pedidos SET updated_at = now() - interval '1 hour' WHERE id = v_ped RETURNING updated_at INTO v_v1;
    v_t := pg_temp.intenta(v_adm, format(
      'UPDATE public.pedidos SET updated_at = %L WHERE id = %s RETURNING updated_at::text', '2000-01-01 00:00:00+00', v_ped));
    IF v_t NOT LIKE 'PASA%' OR (SELECT updated_at FROM pedidos WHERE id = v_ped) IS DISTINCT FROM v_v1 THEN
      v_fallas := v_fallas || format('G6 · el PATCH de sólo la versión la cambió: %s', v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, format(
      'UPDATE public.pedidos SET notas = %L, updated_at = %L WHERE id = %s RETURNING updated_at::text',
      'patch', '2000-01-01 00:00:00+00', v_ped));
    IF v_t NOT LIKE 'PASA%' OR (SELECT updated_at FROM pedidos WHERE id = v_ped) IS DISTINCT FROM now() THEN
      v_fallas := v_fallas || format('G6 · el PATCH con un cambio no movió la versión a now(): %s', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('G6 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- K9 · 1595-b9 · el cliente del preventista (D24)
  -- =======================================================================
  BEGIN
    v_j := pg_temp.alta(v_pre, v_cli2, jsonb_build_array(pg_temp.venta(v_a, 2)));
    IF NOT pg_temp.ok(v_j) THEN
      RAISE EXCEPTION 'el alta del preventista no entró: %', v_j;
    END IF;
    v_ped := (v_j->>'pedido_id')::bigint;
    UPDATE clientes SET activo = false WHERE id = v_cli2;
    v_j := pg_temp.editar(v_pre, v_ped, jsonb_build_array(pg_temp.venta(v_a, 1)));
    IF pg_temp.ok(v_j) OR v_j::text NOT LIKE '%dado de baja%' THEN
      v_fallas := v_fallas || format('K9 · el preventista editó el pedido de un cliente dado de baja: %s', v_j);
    END IF;
    v_j := pg_temp.editar(v_enc, v_ped, jsonb_build_array(pg_temp.venta(v_a, 1)));
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('K9 · el encargado no pudo editar el pedido del cliente dado de baja: %s', v_j);
    END IF;
    UPDATE clientes SET activo = true WHERE id = v_cli2;
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_cli2, v_pre2);
    v_j := pg_temp.editar(v_pre, v_ped, jsonb_build_array(pg_temp.venta(v_a, 2)));
    IF pg_temp.ok(v_j) OR v_j::text NOT LIKE '%ya no está a tu cargo%' THEN
      v_fallas := v_fallas || format('K9 · el preventista editó el pedido de un cliente que atiende otro: %s', v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('K9 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- R10 · 1595-b10 · (regresión) la promo de otra sucursal en una línea de venta
  -- =======================================================================
  BEGIN
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id)
    VALUES ('B4 promo ajena', 'bonificacion', v_hoy - 1, 2) RETURNING id INTO v_promo2;
    BEGIN
      v_j := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1) || jsonb_build_object('promocion_id', v_promo2)));
      v_t := v_j::text;
    EXCEPTION WHEN OTHERS THEN
      v_t := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_t NOT LIKE '23503%' AND v_t NOT LIKE '%"success": false%' THEN
      v_fallas := v_fallas || format('R10 · una línea con la promo de otra sucursal entró: %s', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('R10 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- Z11 · 1595-b11 · (regresión, D25) el pase de un entregado
  -- =======================================================================
  BEGIN
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)))->>'pedido_id')::bigint;
    UPDATE pedidos SET estado = 'entregado', retiro_deposito = true,
                       fecha_entrega = ((v_hoy - 1)::text || ' 12:00:00-03')::timestamptz
     WHERE id = v_ped;
    PERFORM pg_temp.como(v_enc, 1);
    v_j := public.cambiar_tipo_factura_pedido(v_ped, 'FC', v_enc);
    PERFORM pg_temp.como(v_adm, 1);
    v_t := public.cambiar_tipo_factura_pedido(v_ped, 'FC', v_adm)::text;
    PERFORM pg_temp.como(NULL, NULL);
    IF pg_temp.ok(v_j) OR NOT pg_temp.ok(v_t::jsonb) THEN
      v_fallas := v_fallas || format('Z11 · encargado %s / admin %s', v_j, v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('Z11 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- A2 · 1543-b2 · el escape del cambio de cliente para un desactivado
  -- =======================================================================
  BEGIN
    v_d := pg_temp.prod('D');
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_d, 2)))->>'pedido_id')::bigint;
    UPDATE productos SET activo = false WHERE id = v_d;
    PERFORM set_config('app.cambio_cliente_desde', v_ped::text, true);
    v_j := pg_temp.alta(v_adm, v_cli2, jsonb_build_array(pg_temp.venta(v_d, 5)));
    IF pg_temp.ok(v_j) OR v_j::text NOT LIKE '%desactivado%' THEN
      v_fallas := v_fallas || format('A2 · el cambio de cliente subió la cantidad de un desactivado: %s', v_j);
    END IF;
    v_j := pg_temp.alta(v_adm, v_cli2, jsonb_build_array(pg_temp.venta(v_a, 1), pg_temp.regalo(v_d, 1, NULL)));
    IF pg_temp.ok(v_j) OR v_j::text NOT LIKE '%desactivado%' THEN
      v_fallas := v_fallas || format('A2 · el cambio de cliente pasó a regalo un desactivado que era venta: %s', v_j);
    END IF;
    v_j := pg_temp.alta(v_adm, v_cli2, jsonb_build_array(pg_temp.venta(v_d, 2)));
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('A2 · el cambio de cliente con la línea tal cual no entró: %s', v_j);
    END IF;
    PERFORM set_config('app.cambio_cliente_desde', '', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.cambio_cliente_desde', '', true);
    v_fallas := v_fallas || format('A2 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- C1 · 1592-b1 · el corte de un regalo cambiado por valor
  -- =======================================================================
  DECLARE
    v_v bigint; v_r bigint; v_w bigint; v_p bigint;
  BEGIN
    v_v := pg_temp.prod('V', 100);
    v_r := pg_temp.prod('R', 100);
    v_w := pg_temp.prod('W', 1000);
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
    VALUES ('B4 promo 2V1R', 'bonificacion', v_hoy - 1, 1, true, v_r) RETURNING id INTO v_p;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v_p, 'cantidad_compra', 2, 1), (v_p, 'cantidad_bonificacion', 1, 1);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_p, v_v, 1);
    v_j := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_v, 20), pg_temp.regalo(v_r, 10, v_p)));
    IF NOT pg_temp.ok(v_j) THEN
      RAISE EXCEPTION 'el alta con el regalo no entró: %', v_j;
    END IF;
    v_ped := (v_j->>'pedido_id')::bigint;
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.sustituir_regalo_pedido(v_it, v_w, 1, 'ensayo B4', NULL, NULL);
    PERFORM pg_temp.como(NULL, NULL);
    IF NOT pg_temp.ok(v_j) THEN
      RAISE EXCEPTION 'la sustitución R×10 → W×1 no anduvo: %', v_j;
    END IF;
    v_j := pg_temp.editar(v_adm, v_ped, jsonb_build_array(pg_temp.venta(v_v, 20), pg_temp.regalo(v_w, 1, v_p)));
    v_t := (SELECT format('producto=%s cantidad=%s corte=%s', CASE WHEN producto_id = v_w THEN 'W' ELSE producto_id::text END,
                          cantidad, regalo_corte)
              FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT pg_temp.ok(v_j) OR v_t IS DISTINCT FROM 'producto=W cantidad=1 corte=10' THEN
      v_fallas := v_fallas || format('C1 · la edición que manda W×1: %s (%s)', v_t, v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('C1 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- Z2 · 1559-b2 · el pase ZZ → FC con una línea sin producto
  -- =======================================================================
  BEGIN
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1), pg_temp.venta(v_b, 1)))->>'pedido_id')::bigint;
    UPDATE pedido_items SET producto_id = NULL WHERE pedido_id = v_ped AND producto_id = v_b;
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.cambiar_tipo_factura_pedido(v_ped, 'FC', v_adm);
    PERFORM pg_temp.como(NULL, NULL);
    SELECT total_neto + total_iva INTO v_n FROM pedidos WHERE id = v_ped;
    IF NOT pg_temp.ok(v_j) OR abs(v_n - 200) > 0.02 THEN
      v_fallas := v_fallas || format('Z2 · neto + IVA del FC = %s (el total es 200): %s', v_n, v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('Z2 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- P3 · 1559-b3 · un producto que hoy no tiene lista (D20)
  -- =======================================================================
  BEGIN
    v_x := pg_temp.prod('X');
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1), pg_temp.venta(v_x, 3)))->>'pedido_id')::bigint;
    UPDATE productos SET precio = 0 WHERE id = v_x;
    v_j := pg_temp.editar(v_enc, v_ped, jsonb_build_array(pg_temp.venta(v_a, 2), pg_temp.venta(v_x, 3)));
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || format('P3 · la edición que conserva la línea sin lista no anduvo: %s', v_j);
    END IF;
    BEGIN
      v_j := pg_temp.editar(v_enc, v_ped, jsonb_build_array(pg_temp.venta(v_a, 2), pg_temp.venta(v_x, 4)));
      v_t := v_j::text;
    EXCEPTION WHEN OTHERS THEN v_t := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_t NOT LIKE '%pendiente de carga de precio%' THEN
      v_fallas := v_fallas || format('P3 · la edición le subió la cantidad a un producto sin lista: %s', v_t);
    END IF;
    BEGIN
      v_j := pg_temp.editar(v_adm, v_ped, jsonb_build_array(pg_temp.venta(v_a, 2), pg_temp.venta(v_x, 3, 90)));
      v_t := v_j::text;
    EXCEPTION WHEN OTHERS THEN v_t := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_t NOT LIKE '%pendiente de carga de precio%' THEN
      v_fallas := v_fallas || format('P3 · la edición le cambió el precio a un producto sin lista: %s', v_t);
    END IF;
    IF current_setting('app.edicion_precio_conservado', true) IS DISTINCT FROM ''
       AND current_setting('app.edicion_precio_conservado', true) IS NOT NULL THEN
      v_fallas := v_fallas || format('P3 · app.edicion_precio_conservado quedó prendido: %s',
                                     current_setting('app.edicion_precio_conservado', true));
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('P3 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- O4 · 1601-b4 · la escala de otra sucursal
  -- =======================================================================
  DECLARE
    v_g bigint; v_e bigint;
  BEGIN
    INSERT INTO grupos_precio (nombre, sucursal_id) VALUES ('B4 condición ajena', 2) RETURNING id INTO v_g;
    INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, sucursal_id)
    VALUES (v_g, 10, 90, 2) RETURNING id INTO v_e;
    v_ped := (pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.venta(v_a, 1)))->>'pedido_id')::bigint;
    UPDATE pedido_items SET origen_precio = NULL WHERE pedido_id = v_ped;
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.registrar_origen_precio_items(v_ped, jsonb_build_array(jsonb_build_object(
             'producto_id', v_a, 'es_bonificacion', false, 'origen_precio', 'mayorista', 'grupo_precio_escala_id', v_e)));
    PERFORM pg_temp.como(NULL, NULL);
    IF (SELECT grupo_precio_escala_id FROM pedido_items WHERE pedido_id = v_ped) IS NOT NULL THEN
      v_fallas := v_fallas || format('O4 · se escribió la escala de otra sucursal: %s', v_j);
    END IF;
    BEGIN
      UPDATE pedido_items SET grupo_precio_escala_id = v_e WHERE pedido_id = v_ped;
      v_t := 'PASA';
    EXCEPTION WHEN OTHERS THEN v_t := SQLSTATE;
    END;
    IF v_t <> '23503' THEN
      v_fallas := v_fallas || format('O4 · la escala de otra sucursal entró a mano (%s)', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('O4 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- SG1 · SEG-1 · el rol con activo (estructura)
  -- =======================================================================
  IF pg_get_functiondef('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)'::regprocedure)
       NOT LIKE '%FROM perfiles WHERE id = p_usuario_id AND COALESCE(activo, true)%' THEN
    v_fallas := v_fallas || 'SG1 · cambiar_tipo_factura_pedido lee el rol sin activo'::text;
  END IF;

  -- =======================================================================
  -- M10 · M10-2 · los días de la política que ve el front
  -- =======================================================================
  BEGIN
    v_t := pg_temp.intenta(v_dep, 'SELECT public.dias_atras_fecha_pedido()::text');
    IF v_t IS DISTINCT FROM 'PASA 2' THEN
      v_fallas := v_fallas || format('M10 · el depósito con el extra de chofer recibe %s y no 2', v_t);
    END IF;
    v_t := pg_temp.intenta(v_dep, 'SELECT count(*)::text FROM public.politicas_comerciales');
    v_notas := v_notas || format('M10 · por REST el depósito ve %s filas de la política', v_t);
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('M10 · error: %s', SQLERRM);
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
