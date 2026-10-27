-- Ensayo de la migracion cargo_3_bot (el bot respeta el modo y muestra el
-- cargo de envio; lo que falta de #1220, spec §5).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe (un producto propio, la politica de la
-- sucursal, las confirmaciones pendientes, los pedidos) se deshace. Cada caso va
-- ademas en su subbloque, que se revierte con el SQLSTATE centinela P0099.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR (no existe cargo_mostrado y
-- crear_pedido_completo_bot cobra el cargo vigente aunque la vista previa haya
-- mostrado otro); despues, pasar. Requiere cargo_1_base y cargo_2_edicion
-- (acumulado). Ensayo en seco:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/NNN_cargo_1_base.sql>
--   <migrations/NNN_cargo_2_edicion.sql>
--   <migrations/NNN_cargo_3_bot.sql>
--   <este archivo>
--   ROLLBACK;
--
-- crear_pedido_completo_bot se llama COMO EL BOT: SET LOCAL ROLE service_role
-- y sin claims de sesion (pg_temp.bot). La confirmacion pendiente se arma como
-- la arma previsualizar_pedido (items + total), y cargo_mostrado se escribe
-- aparte solo si la columna existe: antes de la migracion cada canario falla
-- por lo suyo, no por la columna que falta.
--
-- Casos (politica forzada en cada uno; 12 u. a $1.000 = $12.000 de productos):
--   A · cargo 15000/500, mostrado 500 -> crea: cargo 500, total 12500,
--       'cobrado', respuesta con total 12500 y cargo_envio 500, pendiente consumido
--   B · mostrado 500 y la politica pasa a 700 -> error exacto, el pendiente
--       sigue sin consumir y no se crea ningun pedido
--   C · bloquear con todo en 0, pendiente SIN cargo_mostrado (el bot desplegado)
--       -> crea: cargo 0, total 12000, 'no_aplica'
--   D · cargo 15000/500 y pendiente SIN cargo_mostrado (el bot viejo con una
--       sucursal que ya cobra) -> error: no cobra un envio que no mostro
--   E · escalas 5000/15000/500, $12.000, mostrado 500 -> crea con cargo 500
--   F · la columna: numeric(12,2) NOT NULL DEFAULT 0, CHECK >= 0 muerde, sin
--       grants para anon/authenticated; la funcion sin EXECUTE para la API
--
--   psql "$DATABASE_URL" -f scripts/test-cargo-3.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_admin   uuid;
  v_suc     bigint;
  v_cli     bigint;
  v_prod    bigint;
  v_items12 jsonb;
  v_hay_col boolean;
  v_conf    uuid;
  v_ped     bigint;
  v_antes   int;
  v_despues int;
  v_consumido boolean;
  r         jsonb;
  p         record;
  v_col     record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- --------------------------------------------------------- contexto ---
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un admin activo con una sucursal activa';
  END IF;
  -- Sin saldo a favor (un credito se imputaria al pedido) y no VB (el bot no
  -- carga vale blanco).
  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo
     AND c.tipo_factura_default IS DISTINCT FROM 'VB'
     AND NOT COALESCE(c.reservado_admin, false)
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un cliente activo en la sucursal %', v_suc;
  END IF;

  v_hay_col := EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'public' AND table_name = 'bot_pedidos_pendientes'
                          AND column_name = 'cargo_mostrado');

  PERFORM set_config('app.omitir_minimo_pedido', '', true);
  PERFORM set_config('app.cargo_envio_forzado', '', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', '', true);

  -- Un producto propio: $1.000, IVA 21, sin internos, costo 600, sin lotes.
  INSERT INTO productos (nombre, precio, stock, costo_promedio, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo cargo 3', 1000, 1000, 600, 21, 0, v_suc)
  RETURNING id INTO v_prod;
  v_items12 := jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 12, 'precio_unitario', 1000));

  -- La confirmacion pendiente, como la deja previsualizar_pedido. p_mostrado
  -- NULL = el bot desplegado, que no escribe la columna.
  CREATE FUNCTION pg_temp.pendiente(p_perfil uuid, p_suc bigint, p_cli bigint, p_items jsonb,
                                    p_total numeric, p_mostrado numeric, p_hay_col boolean)
  RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE
    v_id uuid;
  BEGIN
    INSERT INTO public.bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total)
    VALUES (p_perfil, p_suc, p_cli, p_items, p_total)
    RETURNING id INTO v_id;
    IF p_mostrado IS NOT NULL AND p_hay_col THEN
      EXECUTE 'UPDATE public.bot_pedidos_pendientes SET cargo_mostrado = $1 WHERE id = $2'
        USING p_mostrado, v_id;
    END IF;
    RETURN v_id;
  END
  $f$;

  -- crear_pedido_completo_bot como lo llama el bot: service_role, sin sesion.
  CREATE FUNCTION pg_temp.bot(p_perfil uuid, p_conf uuid)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_claims text := current_setting('request.jwt.claims', true);
    v_r jsonb;
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    SET LOCAL ROLE service_role;
    v_r := public.crear_pedido_completo_bot(p_perfil, p_conf);
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
    -- Los GUC de stock son por transaccion: que no le lleguen al caso siguiente.
    PERFORM set_config('app.stock_origen', '', true);
    PERFORM set_config('app.stock_ref_tipo', '', true);
    PERFORM set_config('app.stock_ref_id', '', true);
    PERFORM set_config('app.stock_user_id', '', true);
    RETURN v_r;
  END
  $f$;

  CREATE FUNCTION pg_temp.politica(p_suc bigint, p_modo text, p_min numeric, p_gratis numeric, p_cargo numeric)
  RETURNS void LANGUAGE sql AS $f$
    INSERT INTO public.politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (p_suc, p_modo, p_min, p_gratis, p_cargo)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
  $f$;

  -- ============================================ A · mostrado = vigente ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'cargo', 15000, 0, 500);
    v_conf := pg_temp.pendiente(v_admin, v_suc, v_cli, v_items12, 12000, 500, v_hay_col);
    r := pg_temp.bot(v_admin, v_conf);
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('A cargo 500 mostrado 500: %s', r);
    ELSE
      v_ped := (r->>'pedido_id')::bigint;
      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      IF p.cargo_envio <> 500 OR p.total <> 12500 OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado'
         OR (r->>'total')::numeric IS DISTINCT FROM 12500 OR (r->>'cargo_envio')::numeric IS DISTINCT FROM 500 THEN
        v_fallas := v_fallas || format('A: cargo %s, total %s, estado %s, respuesta %s; esperado 500, 12500, cobrado',
                                       p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado', r);
      END IF;
      SELECT consumido INTO v_consumido FROM bot_pedidos_pendientes WHERE id = v_conf;
      IF NOT v_consumido THEN
        v_fallas := v_fallas || 'A: el pendiente no quedo consumido'::text;
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('A · error: %s', SQLERRM);
  END;

  -- ================================== B · la politica cambio en el medio ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'cargo', 15000, 0, 500);
    v_conf := pg_temp.pendiente(v_admin, v_suc, v_cli, v_items12, 12000, 500, v_hay_col);
    PERFORM pg_temp.politica(v_suc, 'cargo', 15000, 0, 700);
    SELECT count(*) INTO v_antes FROM pedidos WHERE cliente_id = v_cli;
    r := pg_temp.bot(v_admin, v_conf);
    SELECT count(*) INTO v_despues FROM pedidos WHERE cliente_id = v_cli;
    SELECT consumido INTO v_consumido FROM bot_pedidos_pendientes WHERE id = v_conf;
    IF COALESCE((r->>'success')::boolean, true)
       OR (r->>'error') IS DISTINCT FROM 'El costo de envío cambió desde la vista previa. Pedí la vista previa de nuevo.' THEN
      v_fallas := v_fallas || format('B mostrado 500, vigente 700: %s; esperado el rechazo por el cargo', r);
    END IF;
    IF v_consumido THEN
      v_fallas := v_fallas || 'B: el pendiente quedo consumido'::text;
    END IF;
    IF v_despues <> v_antes THEN
      v_fallas := v_fallas || format('B: se crearon %s pedidos', v_despues - v_antes);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B · error: %s', SQLERRM);
  END;

  -- ===================================== C · bloquear y el bot desplegado ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'bloquear', 0, 0, 0);
    v_conf := pg_temp.pendiente(v_admin, v_suc, v_cli, v_items12, 12000, NULL, v_hay_col);
    r := pg_temp.bot(v_admin, v_conf);
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('C bloquear sin cargo_mostrado: %s', r);
    ELSE
      v_ped := (r->>'pedido_id')::bigint;
      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      IF p.cargo_envio <> 0 OR p.total <> 12000 OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'no_aplica'
         OR (r->>'cargo_envio')::numeric IS DISTINCT FROM 0 THEN
        v_fallas := v_fallas || format('C: cargo %s, total %s, estado %s, respuesta %s; esperado 0, 12000, no_aplica',
                                       p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado', r);
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C · error: %s', SQLERRM);
  END;

  -- ========================== D · bot viejo con una sucursal que ya cobra ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'cargo', 15000, 0, 500);
    v_conf := pg_temp.pendiente(v_admin, v_suc, v_cli, v_items12, 12000, NULL, v_hay_col);
    r := pg_temp.bot(v_admin, v_conf);
    SELECT consumido INTO v_consumido FROM bot_pedidos_pendientes WHERE id = v_conf;
    IF COALESCE((r->>'success')::boolean, true) OR v_consumido THEN
      v_fallas := v_fallas || format('D cargo 500 sin cargo_mostrado: %s (consumido %s); esperado el rechazo sin consumir', r, v_consumido);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D · error: %s', SQLERRM);
  END;

  -- ================================================== E · escalas cobra ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);
    v_conf := pg_temp.pendiente(v_admin, v_suc, v_cli, v_items12, 12000, 500, v_hay_col);
    r := pg_temp.bot(v_admin, v_conf);
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('E escalas mostrado 500: %s', r);
    ELSE
      SELECT * INTO p FROM pedidos WHERE id = (r->>'pedido_id')::bigint;
      IF p.cargo_envio <> 500 OR p.total <> 12500 THEN
        v_fallas := v_fallas || format('E: cargo %s, total %s; esperado 500, 12500', p.cargo_envio, p.total);
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E · error: %s', SQLERRM);
  END;

  -- ======================================== F · la columna y los permisos ===
  BEGIN
    SELECT c.is_nullable, c.column_default, c.numeric_precision, c.numeric_scale INTO v_col
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = 'bot_pedidos_pendientes'
       AND c.column_name = 'cargo_mostrado';
    IF NOT FOUND OR v_col.is_nullable <> 'NO' OR v_col.column_default IS DISTINCT FROM '0'
       OR v_col.numeric_precision <> 12 OR v_col.numeric_scale <> 2 THEN
      v_fallas := v_fallas || 'F cargo_mostrado no es numeric(12,2) NOT NULL DEFAULT 0'::text;
    ELSE
      IF has_column_privilege('anon', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'SELECT')
         OR has_column_privilege('authenticated', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'SELECT')
         OR has_column_privilege('authenticated', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'INSERT')
         OR has_column_privilege('authenticated', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'UPDATE') THEN
        v_fallas := v_fallas || 'F cargo_mostrado tiene grants para la API'::text;
      END IF;
      -- El CHECK >= 0 muerde.
      BEGIN
        v_conf := pg_temp.pendiente(v_admin, v_suc, v_cli, v_items12, 12000, -1, v_hay_col);
        v_fallas := v_fallas || 'F el CHECK dejo un cargo_mostrado negativo'::text;
        RAISE EXCEPTION USING ERRCODE = 'P0099';
      EXCEPTION WHEN check_violation THEN NULL;
        WHEN SQLSTATE 'P0099' THEN NULL;
      END;
    END IF;
    IF has_function_privilege('anon', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE')
       OR NOT has_function_privilege('service_role', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE') THEN
      v_fallas := v_fallas || 'F permisos de crear_pedido_completo_bot'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('F · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · bot: cargo mostrado = vigente crea (cargo y escalas), politica cambiada rechaza sin consumir, bloquear y el bot desplegado siguen andando, bot viejo con cargo rechaza, columna, CHECK y permisos';
END
$ensayo$;
