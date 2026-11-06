-- Ensayo de #1490 (tarjeta 13 de #1477): un desactivado con el token vivo no entra a las RPCs
-- que decidían el permiso leyendo perfiles.rol sin mirar activo, un activo entra igual, y los
-- reportes dan lo mismo antes y después de la migración.
--
-- Corre contra prod SIN dejar rastro: las tablas de huellas son temporales (ON COMMIT DROP), el
-- bloque de huellas sólo llama a funciones de lectura, y el veredicto es un DO que termina
-- SIEMPRE en una excepción, con cada caso en su propio sub-bloque que se revierte al terminar.
--
-- Simula PostgREST como test-permisos-1474.sql: `SET LOCAL ROLE authenticated`, el `sub` de un
-- perfil real en request.jwt.claims y la sucursal en x-sucursal-id. El desactivado es un perfil
-- activo al que se le pone activo = false dentro del sub-bloque: su JWT sigue siendo el mismo,
-- que es justo el token vivo del issue. Personas de prod: un admin de la 1 y la 2, y un encargado.
--
-- Casos
--   H  · huellas: la salida (md5 del texto) de 16 lecturas como el admin y de las 8 de /reportes
--        como el encargado. La primera vez que corre en una transacción las guarda; la segunda
--        las compara. Sin la primera, no compara (lo dice en las notas).
--   G  · los 22 guards de la migración: el activo no choca con el guard (pasa, o falla por otra
--        cosa: un argumento, un dato), y el mismo usuario desactivado choca con el guard.
--   E  · las 35 de scripts/rol-sin-activo-permitidas.json (leen el rol sin activo, pero algo
--        anterior ya frena al desactivado): el admin desactivado no pasa (error, o nada que leer).
--   E2 · las ramas de encargado y depósito de las que las tienen: el encargado desactivado, y el
--        mismo pasado a depósito, frenan en la sucursal (o en el guard, la de las 22).
--   A  · el gate: auditoria_rol_sin_activo() no la ejecuta ni anon ni authenticated, marca una
--        función que lee el rol de auth.uid() o de un alias sin activo, y no marca la que mira
--        activo ni la que sólo dice "rol" en un mensaje.
--
-- Sin la migración tiene que FALLAR en G (los 22 desactivados entran) y en A (no existe el gate).
-- E pasa antes y después.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenar).
--
-- El antes y después, en una sola transacción que se revierte:
--   BEGIN;
--   SELECT set_config('ensayo.continuar', '1', true);
--   \i scripts/test-desactivado-sin-rol-1490.sql      -- guarda las huellas; G y A fallan
--   -- (el cuerpo de la migración, sin BEGIN/COMMIT)
--   \i scripts/test-desactivado-sin-rol-1490.sql      -- compara las huellas; da 'ENSAYO OK'
--   ROLLBACK;
-- Después de aplicar, una corrida sola: psql "$DATABASE_URL" -f scripts/test-desactivado-sin-rol-1490.sql

CREATE TEMP TABLE IF NOT EXISTS ensayo_1490_huellas (
  caso text PRIMARY KEY,
  huella text NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE IF NOT EXISTS ensayo_1490_notas (
  orden serial,
  falla boolean NOT NULL,
  texto text NOT NULL
) ON COMMIT DROP;

-- Como PostgREST: 'OK <md5 del resultado>' o 'ERR <sqlstate> <mensaje>'. Las de TABLE van como
-- un SELECT entero; las escalares, como la llamada.
CREATE OR REPLACE FUNCTION pg_temp.e1490_como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
END $f$;
CREATE OR REPLACE FUNCTION pg_temp.e1490_servidor() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  PERFORM set_config('request.headers', '{}', true);
END $f$;
CREATE OR REPLACE FUNCTION pg_temp.e1490_llamar(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE format('SELECT md5(COALESCE((%s)::text, %L))', p_sql, '<null>') INTO v;
  EXECUTE 'RESET ROLE';
  RETURN 'OK ' || v;
EXCEPTION WHEN OTHERS THEN
  RETURN 'ERR ' || SQLSTATE || ' ' || SQLERRM;
END $f$;

-- Igual, pero con el resultado entero: varias RPCs rechazan devolviendo
-- {"success": false, "error": …} en lugar de una excepción.
CREATE OR REPLACE FUNCTION pg_temp.e1490_texto(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE format('SELECT COALESCE((%s)::text, %L)', p_sql, '<null>') INTO v;
  EXECUTE 'RESET ROLE';
  RETURN 'OK ' || v;
EXCEPTION WHEN OTHERS THEN
  RETURN 'ERR ' || SQLSTATE || ' ' || SQLERRM;
END $f$;

-- ------------------------------------------------------------------ H ---
DO $huellas$
DECLARE
  v_a     uuid;
  v_e     uuid;
  v_e_suc bigint;
  r       record;
  v_res   text;
  v_antes text;
  v_hay   boolean := EXISTS (SELECT 1 FROM ensayo_1490_huellas);
BEGIN
  SELECT p.id INTO v_a FROM perfiles p
   WHERE p.rol = 'admin' AND p.activo
     AND (SELECT string_agg(sucursal_id::text, ',' ORDER BY sucursal_id)
            FROM usuario_sucursales WHERE usuario_id = p.id) = '1,2'
   ORDER BY p.id LIMIT 1;
  SELECT p.id, us.sucursal_id INTO v_e, v_e_suc
    FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id
   WHERE p.rol = 'encargado' AND p.activo ORDER BY p.id, us.sucursal_id LIMIT 1;
  IF v_a IS NULL OR v_e IS NULL THEN
    INSERT INTO ensayo_1490_notas (falla, texto) VALUES (true, 'H · sin fixtures (admin de la 1 y la 2, encargado)');
    RETURN;
  END IF;

  FOR r IN
    SELECT * FROM (VALUES
      ('admin', 'reporte_gerencial red',        'public.reporte_gerencial(NULL, DATE ''2026-10-01'', DATE ''2026-10-31'', false, false)'),
      ('admin', 'reporte_gerencial 1 comparar', 'public.reporte_gerencial(1, DATE ''2026-10-01'', DATE ''2026-10-31'', true, true)'),
      ('admin', 'posicion_fiscal',              'public.posicion_fiscal(NULL, DATE ''2026-10-01'', DATE ''2026-10-31'')'),
      ('admin', 'reporte_alerta_detalle',       'public.reporte_alerta_detalle(NULL, ''cobranza_vencida'', DATE ''2026-10-01'', DATE ''2026-10-31'', false)'),
      ('admin', 'auditoria_sucursal_cruzada',   'SELECT string_agg(t::text, ''|'' ORDER BY t::text) FROM public.auditoria_sucursal_cruzada() t'),
      ('admin', 'migraciones_aplicadas',        'SELECT string_agg(t::text, ''|'' ORDER BY t::text) FROM public.migraciones_aplicadas() t'),
      ('admin', 'bot_admin_audit_log',          'public.bot_admin_audit_log(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, NULL, 200)'),
      ('admin', 'bot_admin_audit_summary',      'public.bot_admin_audit_summary(DATE ''2026-10-01'', DATE ''2026-10-31'')'),
      ('admin', 'bot_admin_digests_enviados',   'public.bot_admin_digests_enviados(DATE ''2026-10-01'', DATE ''2026-10-31'')'),
      ('admin', 'bot_admin_listar_vinculados',  'public.bot_admin_listar_vinculados()'),
      ('admin', 'reporte_bonificaciones',       'public.reporte_bonificaciones(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, 2000)'),
      ('admin', 'reporte_cuentas_por_cobrar',   'public.reporte_cuentas_por_cobrar(NULL)'),
      ('admin', 'reporte_mermas',               'public.reporte_mermas(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, NULL, 500, 0, NULL)'),
      ('admin', 'reporte_rechazos',             'public.reporte_rechazos(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL)'),
      ('admin', 'reporte_rentabilidad',         'public.reporte_rentabilidad(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, ''incluir'')'),
      ('admin', 'reporte_valuacion_inventario', 'public.reporte_valuacion_inventario(NULL)'),
      ('admin', 'reporte_ventas_por_cliente',   'public.reporte_ventas_por_cliente(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, NULL)'),
      ('admin', 'reporte_ventas_por_preventista', 'public.reporte_ventas_por_preventista(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL)'),
      ('enc',   'reporte_bonificaciones',       'public.reporte_bonificaciones(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, 2000)'),
      ('enc',   'reporte_cuentas_por_cobrar',   'public.reporte_cuentas_por_cobrar(NULL)'),
      ('enc',   'reporte_mermas',               'public.reporte_mermas(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, NULL, 500, 0, NULL)'),
      ('enc',   'reporte_rechazos',             'public.reporte_rechazos(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL)'),
      ('enc',   'reporte_rentabilidad',         'public.reporte_rentabilidad(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, ''incluir'')'),
      ('enc',   'reporte_valuacion_inventario', 'public.reporte_valuacion_inventario(NULL)'),
      ('enc',   'reporte_ventas_por_cliente',   'public.reporte_ventas_por_cliente(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, NULL)'),
      ('enc',   'reporte_ventas_por_preventista', 'public.reporte_ventas_por_preventista(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL)')
    ) AS t(persona, nombre, llamada)
  LOOP
    IF r.persona = 'admin' THEN PERFORM pg_temp.e1490_como(v_a, 1);
    ELSE PERFORM pg_temp.e1490_como(v_e, v_e_suc);
    END IF;
    v_res := pg_temp.e1490_llamar(r.llamada);
    PERFORM pg_temp.e1490_servidor();
    IF v_res NOT LIKE 'OK %' THEN
      INSERT INTO ensayo_1490_notas (falla, texto)
      VALUES (true, format('H · %s como %s no corre: %s', r.nombre, r.persona, v_res));
      CONTINUE;
    END IF;
    IF NOT v_hay THEN
      INSERT INTO ensayo_1490_huellas VALUES (r.persona || ' · ' || r.nombre, v_res);
    ELSE
      SELECT huella INTO v_antes FROM ensayo_1490_huellas WHERE caso = r.persona || ' · ' || r.nombre;
      IF v_antes IS DISTINCT FROM v_res THEN
        INSERT INTO ensayo_1490_notas (falla, texto)
        VALUES (true, format('H · %s como %s cambió: antes %s, después %s', r.nombre, r.persona, v_antes, v_res));
      END IF;
    END IF;
  END LOOP;

  INSERT INTO ensayo_1490_notas (falla, texto)
  VALUES (false, CASE WHEN v_hay THEN 'H · huellas comparadas contra la corrida anterior'
                      ELSE 'H · huellas guardadas (primera corrida: no hay antes con qué comparar)' END);
END
$huellas$;

-- ------------------------------------------------------------- G, E, A ---
DO $ensayo$
DECLARE
  c_guard CONSTANT text := '^ERR \S+ (Acceso denegado: se requiere rol admin|Solo admin puede|Solo quien carga compras)';
  v_a       uuid;
  v_e       uuid;
  v_e_suc   bigint;
  v_prev    uuid;
  v_tg      bigint;
  v_tg_act  boolean;
  v_pedido  bigint;
  v_entreg  bigint;
  v_item_e  bigint;
  v_regalo  bigint;
  v_cli     bigint;
  v_cli2    bigint;
  v_prod    bigint;
  v_lote    bigint;
  v_lote_suc bigint;
  v_compra  bigint;
  v_prov    bigint;
  v_nc      bigint;
  v_zona    bigint;
  r         record;
  v_res     text;
  v_lec     jsonb;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT p.id INTO v_a FROM perfiles p
   WHERE p.rol = 'admin' AND p.activo
     AND (SELECT string_agg(sucursal_id::text, ',' ORDER BY sucursal_id)
            FROM usuario_sucursales WHERE usuario_id = p.id) = '1,2'
   ORDER BY p.id LIMIT 1;
  SELECT p.id, us.sucursal_id INTO v_e, v_e_suc
    FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id
   WHERE p.rol = 'encargado' AND p.activo ORDER BY p.id, us.sucursal_id LIMIT 1;
  SELECT p.id INTO v_prev FROM perfiles p
   WHERE p.rol = 'preventista' AND p.activo
     AND EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = p.id AND sucursal_id = 1)
   ORDER BY p.id LIMIT 1;
  SELECT telegram_user_id, activo INTO v_tg, v_tg_act FROM bot_usuarios ORDER BY telegram_user_id LIMIT 1;
  -- Datos de la sucursal 1 para llamar a las escudadas con argumentos que existen: si rechazan,
  -- es por el escudo y no por un id inexistente.
  SELECT id INTO v_pedido FROM pedidos WHERE sucursal_id = 1 AND estado IN ('asignado', 'pendiente') ORDER BY id DESC LIMIT 1;
  SELECT id INTO v_entreg FROM pedidos WHERE sucursal_id = 1 AND estado = 'entregado' ORDER BY id DESC LIMIT 1;
  SELECT pi.id INTO v_item_e FROM pedido_items pi WHERE pi.pedido_id = v_entreg ORDER BY pi.id LIMIT 1;
  SELECT pi.id INTO v_regalo FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id
   WHERE p.sucursal_id = 1 AND pi.es_bonificacion AND p.estado IN ('asignado', 'pendiente') ORDER BY pi.id DESC LIMIT 1;
  SELECT id INTO v_cli  FROM clientes WHERE sucursal_id = 1 AND activo ORDER BY id LIMIT 1;
  SELECT id INTO v_cli2 FROM clientes WHERE sucursal_id = 1 AND activo ORDER BY id DESC LIMIT 1;
  SELECT id INTO v_prod FROM productos WHERE sucursal_id = 1 ORDER BY id LIMIT 1;
  -- Los lotes viven sólo en algunas sucursales (hoy, en la 2): el lote va con la suya, y las
  -- tres de lotes se llaman con esa sucursal activa.
  SELECT l.id, p.sucursal_id INTO v_lote, v_lote_suc FROM producto_lotes l JOIN productos p ON p.id = l.producto_id
   WHERE p.sucursal_id IN (1, 2) ORDER BY (p.sucursal_id = 1) DESC, l.id DESC LIMIT 1;
  SELECT id INTO v_compra FROM compras WHERE sucursal_id = 1 AND estado <> 'cancelada' ORDER BY id DESC LIMIT 1;
  SELECT id INTO v_prov FROM proveedores WHERE sucursal_id = 1 ORDER BY id LIMIT 1;
  SELECT id INTO v_nc   FROM notas_credito_venta WHERE sucursal_id = 1 ORDER BY id DESC LIMIT 1;
  SELECT id INTO v_zona FROM zonas WHERE sucursal_id = 1 ORDER BY id LIMIT 1;
  IF v_a IS NULL OR v_e IS NULL OR v_prev IS NULL OR v_tg IS NULL OR v_pedido IS NULL OR v_entreg IS NULL
     OR v_item_e IS NULL OR v_cli IS NULL OR v_prod IS NULL OR v_lote IS NULL OR v_compra IS NULL
     OR v_prov IS NULL OR v_zona IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: a % e % prev % tg % pedido % entregado % item % cli % prod % lote % compra % prov % zona %',
      v_a, v_e, v_prev, v_tg, v_pedido, v_entreg, v_item_e, v_cli, v_prod, v_lote, v_compra, v_prov, v_zona;
  END IF;

  -- -------------------------------------------------------------------- G ---
  -- persona: 'admin' (el de la 1 y la 2, en la 1) o 'enc' (el encargado, en su sucursal).
  FOR r IN
    SELECT * FROM (VALUES
      ('admin', 'auditoria_integridad()',            'public.auditoria_integridad()'),
      ('admin', 'auditoria_sucursal_cruzada()',      'SELECT count(*) FROM public.auditoria_sucursal_cruzada()'),
      ('admin', 'guardar_analisis_mensual',          'public.guardar_analisis_mensual(1, DATE ''2026-11-01'', ''ensayo 1490'', NULL)'),
      ('admin', 'guardar_meta_gerencial',            'public.guardar_meta_gerencial(1, DATE ''2026-11-01'', ''venta'', 1)'),
      ('admin', 'migraciones_aplicadas()',           'SELECT count(*) FROM public.migraciones_aplicadas()'),
      ('admin', 'posicion_fiscal',                   'public.posicion_fiscal(NULL, DATE ''2026-10-01'', DATE ''2026-10-31'')'),
      ('admin', 'reporte_gerencial',                 'public.reporte_gerencial(NULL, DATE ''2026-10-01'', DATE ''2026-10-31'', false, false)'),
      ('admin', 'reporte_alerta_detalle',            'public.reporte_alerta_detalle(NULL, ''cobranza_vencida'', NULL, NULL, false)'),
      ('admin', 'bot_admin_audit_log',               'public.bot_admin_audit_log(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, NULL, 200)'),
      ('admin', 'bot_admin_audit_summary',           'public.bot_admin_audit_summary(DATE ''2026-10-01'', DATE ''2026-10-31'')'),
      ('admin', 'bot_admin_digests_enviados',        'public.bot_admin_digests_enviados(DATE ''2026-10-01'', DATE ''2026-10-31'')'),
      ('admin', 'bot_admin_listar_vinculados()',     'public.bot_admin_listar_vinculados()'),
      ('admin', 'bot_admin_toggle_usuario',          format('public.bot_admin_toggle_usuario(%s, %L)', v_tg, v_tg_act)),
      ('enc',   'reporte_bonificaciones',            'public.reporte_bonificaciones(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, 2000)'),
      ('enc',   'reporte_cuentas_por_cobrar',        'public.reporte_cuentas_por_cobrar(NULL)'),
      ('enc',   'reporte_mermas',                    'public.reporte_mermas(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, NULL, 500, 0, NULL)'),
      ('enc',   'reporte_rechazos',                  'public.reporte_rechazos(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL)'),
      ('enc',   'reporte_rentabilidad',              'public.reporte_rentabilidad(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, ''incluir'')'),
      ('enc',   'reporte_valuacion_inventario',      'public.reporte_valuacion_inventario(NULL)'),
      ('enc',   'reporte_ventas_por_cliente',        'public.reporte_ventas_por_cliente(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL, NULL)'),
      ('enc',   'reporte_ventas_por_preventista',    'public.reporte_ventas_por_preventista(DATE ''2026-10-01'', DATE ''2026-10-31'', NULL)'),
      ('enc',   'asegurar_cargo_concepto',           'public.asegurar_cargo_concepto(''Ensayo 1490'', 1, ''gravado'', false, false, ''monto'', NULL)')
    ) AS t(persona, nombre, llamada)
  LOOP
    BEGIN
      IF r.persona = 'admin' THEN PERFORM pg_temp.e1490_como(v_a, 1);
      ELSE PERFORM pg_temp.e1490_como(v_e, v_e_suc);
      END IF;
      v_res := pg_temp.e1490_llamar(r.llamada);
      IF v_res ~ c_guard THEN
        v_fallas := v_fallas || format('G · %s: el %s activo choca con el guard: %s', r.nombre, r.persona, v_res);
      ELSIF v_res NOT LIKE 'OK %' THEN
        v_notas := v_notas || format('G · %s: el %s activo pasa el guard y falla por otra cosa: %s', r.nombre, r.persona, v_res);
      END IF;

      PERFORM pg_temp.e1490_servidor();
      UPDATE perfiles SET activo = false WHERE id = CASE r.persona WHEN 'admin' THEN v_a ELSE v_e END;
      IF r.persona = 'admin' THEN PERFORM pg_temp.e1490_como(v_a, 1);
      ELSE PERFORM pg_temp.e1490_como(v_e, v_e_suc);
      END IF;
      v_res := pg_temp.e1490_llamar(r.llamada);
      IF v_res !~ c_guard THEN
        v_fallas := v_fallas || format('G · %s: el %s desactivado no choca con el guard: %s', r.nombre, r.persona, left(v_res, 160));
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('G · %s: error inesperado: %s', r.nombre, SQLERRM);
    END;
  END LOOP;

  -- -------------------------------------------------------------------- E ---
  -- El admin de la 1 y la 2, desactivado, en la 1 (las de lotes, en la sucursal del lote): con
  -- el rol leído a pelo pasaría por admin.
  -- Tiene que salir con error (una excepción, o {"success": false, …}), o sin nada que leer
  -- ('vacio': '[]', '{}', 0 filas o NULL).
  BEGIN
    PERFORM pg_temp.e1490_servidor();
    UPDATE perfiles SET activo = false WHERE id = v_a;
    PERFORM pg_temp.e1490_como(v_a, 1);
    FOR r IN
      SELECT * FROM (VALUES
        ('actualizar_alertas_combos',            'public.actualizar_alertas_combos(10, 30)', false),
        ('actualizar_alertas_vencimiento',       'public.actualizar_alertas_vencimiento(30, 7)', false),
        ('actualizar_monto_minimo_pedido',       'public.actualizar_monto_minimo_pedido(0)', false),
        ('actualizar_mostrar_sin_stock',         'public.actualizar_mostrar_sin_stock(true)', false),
        ('actualizar_politica_minimo_pedido',    'public.actualizar_politica_minimo_pedido(''ninguno'', 0, 0, 0)', false),
        ('actualizar_ventana_precio_anterior',   'public.actualizar_ventana_precio_anterior(24)', false),
        ('ajustar_lote',                         format('public.ajustar_lote(%s, 0)', v_lote), false),
        ('bot_admin_guardar_aviso_atrasados',    format('public.bot_admin_guardar_aviso_atrasados(%L, false, 9, ARRAY[1])', v_prev), false),
        ('bot_admin_guardar_config_digest',      format('public.bot_admin_guardar_config_digest(%L, false, 9, ARRAY[1], ARRAY[]::text[])', v_prev), false),
        ('bot_admin_listar_config_digest',       'public.bot_admin_listar_config_digest()', true),
        ('crear_lote_manual',                    format('public.crear_lote_manual(%s, DATE ''2027-01-01'', 1)', v_prod), false),
        ('dar_de_baja_lote',                     format('public.dar_de_baja_lote(%s, 1, NULL)', v_lote), false),
        ('guardar_producto_medidas',             'public.guardar_producto_medidas(''[]''::jsonb)', false),
        ('hojas_de_ruta_deposito',               'public.hojas_de_ruta_deposito(NULL)', false),
        ('obtener_resumen_cuenta_cliente',       format('public.obtener_resumen_cuenta_cliente(%s)', v_cli), false),
        ('quitar_pedido_de_recorridos_activos',  format('public.quitar_pedido_de_recorridos_activos(%s)', v_pedido), false),
        ('registrar_equivalencias_proveedor',    format('public.registrar_equivalencias_proveedor(%s, ''[]''::jsonb)', v_prov), false),
        ('registrar_merma_manual',               format('public.registrar_merma_manual(%s, 1, ''rotura'', NULL, NULL, NULL)', v_prod), false),
        ('registrar_nota_credito_lote',          format('public.registrar_nota_credito_lote(%s, 1, ''E1490'', ''ensayo'')', v_lote), false),
        ('reporte_vencimientos',                 'SELECT count(*) FROM public.reporte_vencimientos(3650)', true),
        ('sincronizar_lotes_compra',             format('public.sincronizar_lotes_compra(%s, ''[]''::jsonb)', v_compra), false),
        ('tablero_guardar_meta_cobertura',       format('public.tablero_guardar_meta_cobertura(%s, DATE ''2026-11-01'', 50, NULL)', v_zona), false),
        ('actualizar_preventista_pedido',        format('public.actualizar_preventista_pedido(%s, %L)', v_pedido, v_prev), false),
        ('anular_nota_credito_venta',            format('public.anular_nota_credito_venta(%s, ''ensayo'')', COALESCE(v_nc, 0)), false),
        ('cambiar_cliente_pedido',               format('public.cambiar_cliente_pedido(%s, %s, %L, ''[]''::jsonb, 0)', v_pedido, v_cli2, v_a), false),
        ('cambiar_proveedor_compra',             format('public.cambiar_proveedor_compra(%s, %L, %s, NULL, ''ensayo'')', v_compra, v_a, v_prov), false),
        ('cancelar_pedido_con_stock',            format('public.cancelar_pedido_con_stock(%s, ''ensayo'', %L, NULL)', v_pedido, v_a), false),
        ('dividir_regalo_pedido',                format('public.dividir_regalo_pedido(%s, ''[]''::jsonb, ''ensayo'', NULL)', COALESCE(v_regalo, v_item_e)), false),
        ('marcar_no_entregado',                  format('public.marcar_no_entregado(%s, ''cerrado'', NULL)', v_pedido), false),
        ('obtener_geolocalizacion_preventistas', 'public.obtener_geolocalizacion_preventistas(NULL, NULL)', false),
        ('registrar_geolocalizacion_pedido',     format('public.registrar_geolocalizacion_pedido(%s, ''denied'', NULL, NULL, NULL, NULL, ''ensayo'')', v_pedido), false),
        ('registrar_salvedad',                   format('public.registrar_salvedad(%s, %s, 1, ''dañado'', NULL, NULL, false, NULL)', v_entreg, v_item_e), false),
        ('registrar_visita_cliente',             format('public.registrar_visita_cliente(%s, ''omitido'', NULL, NULL, NULL, NULL, ''ensayo'')', v_cli), false),
        ('sustituir_regalo_pedido',              format('public.sustituir_regalo_pedido(%s, %s, 1, ''ensayo'', NULL, NULL)', COALESCE(v_regalo, v_item_e), v_prod), false),
        ('verificar_duplicado_cliente',          'public.verificar_duplicado_cliente(-26.8, -65.2, ''calle falsa 123'', NULL)', false)
      ) AS t(nombre, llamada, puede_vacio)
    LOOP
      PERFORM pg_temp.e1490_como(v_a, CASE WHEN r.nombre IN ('ajustar_lote', 'dar_de_baja_lote', 'registrar_nota_credito_lote')
                                           THEN v_lote_suc ELSE 1 END);
      v_res := pg_temp.e1490_texto(r.llamada);
      IF v_res LIKE 'ERR %' THEN
        v_notas := v_notas || format('E · %s: %s', r.nombre, left(v_res, 140));
      ELSIF substr(v_res, 4) ~ '^\{.*"success": false' THEN
        v_notas := v_notas || format('E · %s: %s', r.nombre, left(substr(v_res, 4), 140));
      ELSIF r.puede_vacio AND substr(v_res, 4) IN ('[]', '{}', '0', '<null>') THEN
        v_notas := v_notas || format('E · %s: vacío', r.nombre);
      ELSE
        v_fallas := v_fallas || format('E · %s: el admin desactivado entra (%s)', r.nombre, left(v_res, 160));
      END IF;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- E2 ---
  -- Las ramas de encargado y depósito: el admin desactivado choca antes con es_admin(), así que
  -- no las prueba. El encargado desactivado, y el mismo pasado a 'deposito' (en prod no hay
  -- ninguno), pasan el rol leído a pelo y tienen que frenar en el escudo (sin sucursal activa).
  -- asegurar_cargo_concepto es de las 22: tiene que chocar con el guard.
  FOR r IN
    SELECT * FROM (VALUES
      ('encargado', 'guardar_producto_medidas',          'public.guardar_producto_medidas(''[]''::jsonb)'),
      ('encargado', 'registrar_equivalencias_proveedor', format('public.registrar_equivalencias_proveedor(%s, ''[]''::jsonb)', v_prov)),
      ('deposito',  'guardar_producto_medidas',          'public.guardar_producto_medidas(''[]''::jsonb)'),
      ('deposito',  'registrar_equivalencias_proveedor', format('public.registrar_equivalencias_proveedor(%s, ''[]''::jsonb)', v_prov)),
      ('deposito',  'hojas_de_ruta_deposito',            'public.hojas_de_ruta_deposito(NULL)'),
      ('deposito',  'asegurar_cargo_concepto',           'public.asegurar_cargo_concepto(''Ensayo 1490'', 1, ''gravado'', false, false, ''monto'', NULL)')
    ) AS t(rol, nombre, llamada)
  LOOP
    BEGIN
      PERFORM pg_temp.e1490_servidor();
      UPDATE perfiles SET activo = false, rol = r.rol WHERE id = v_e;
      PERFORM pg_temp.e1490_como(v_e, v_e_suc);
      v_res := pg_temp.e1490_texto(r.llamada);
      IF r.nombre = 'asegurar_cargo_concepto' THEN
        IF v_res !~ c_guard THEN
          v_fallas := v_fallas || format('E2 · %s: el %s desactivado no choca con el guard: %s', r.nombre, r.rol, left(v_res, 160));
        END IF;
      ELSIF v_res !~* '^ERR \S+ (No hay sucursal activa|Sin sucursal activa)' THEN
        v_fallas := v_fallas || format('E2 · %s: el %s desactivado no frena en la sucursal: %s', r.nombre, r.rol, left(v_res, 160));
      ELSE
        v_notas := v_notas || format('E2 · %s como %s: %s', r.nombre, r.rol, left(v_res, 140));
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('E2 · %s como %s: error inesperado: %s', r.nombre, r.rol, SQLERRM);
    END;
  END LOOP;

  -- -------------------------------------------------------------------- A ---
  BEGIN
    PERFORM pg_temp.e1490_servidor();
    IF to_regprocedure('public.auditoria_rol_sin_activo()') IS NULL THEN
      v_fallas := v_fallas || text 'A · no existe auditoria_rol_sin_activo()';
    ELSE
      IF has_function_privilege('anon', 'public.auditoria_rol_sin_activo()', 'EXECUTE')
         OR has_function_privilege('authenticated', 'public.auditoria_rol_sin_activo()', 'EXECUTE') THEN
        v_fallas := v_fallas || text 'A · auditoria_rol_sin_activo() es ejecutable desde la API';
      END IF;
      -- Cuatro sondas (nacen con EXECUTE para PUBLIC, o sea para authenticated) y se revierten.
      EXECUTE $s$CREATE FUNCTION public.e1490_sonda_directa() RETURNS boolean LANGUAGE sql AS
        'SELECT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = ''admin'')'$s$;
      EXECUTE $s$CREATE FUNCTION public.e1490_sonda_alias() RETURNS boolean LANGUAGE plpgsql AS $b$
        DECLARE v_yo uuid := auth.uid(); v_r text;
        BEGIN SELECT rol INTO v_r FROM perfiles WHERE id = v_yo; RETURN v_r = 'admin'; END $b$$s$;
      EXECUTE $s$CREATE FUNCTION public.e1490_sonda_activo() RETURNS boolean LANGUAGE sql AS
        'SELECT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = ''admin'' AND COALESCE(activo, true))'$s$;
      EXECUTE $s$CREATE FUNCTION public.e1490_sonda_mensaje() RETURNS void LANGUAGE plpgsql AS $b$
        BEGIN
          -- un comentario que nombra perfiles, rol y auth.uid() no cuenta
          IF NOT public.es_admin() THEN RAISE EXCEPTION 'perfiles: falta rol para %', auth.uid(); END IF;
        END $b$$s$;
      v_lec := public.auditoria_rol_sin_activo()->'lecturas';
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lec) e WHERE e->>'firma' = 'e1490_sonda_directa()') THEN
        v_fallas := v_fallas || text 'A · no marca la lectura directa del rol de auth.uid()';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lec) e WHERE e->>'firma' = 'e1490_sonda_alias()') THEN
        v_fallas := v_fallas || text 'A · no marca la lectura del rol por un alias de auth.uid()';
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lec) e WHERE e->>'firma' IN ('e1490_sonda_activo()', 'e1490_sonda_mensaje()')) THEN
        v_fallas := v_fallas || text 'A · marca una función que mira activo, o que sólo dice "rol" en un mensaje o un comentario';
      END IF;
      v_notas := v_notas || format('A · el gate marca %s lecturas en %s funciones (sin las sondas)',
        (SELECT count(*) FROM jsonb_array_elements(v_lec) e WHERE e->>'firma' NOT LIKE 'e1490_sonda%'),
        (SELECT count(DISTINCT e->>'firma') FROM jsonb_array_elements(v_lec) e WHERE e->>'firma' NOT LIKE 'e1490_sonda%'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A · error inesperado: ' || SQLERRM);
  END;

  -- ---------------------------------------------------------------- veredicto ---
  v_fallas := v_fallas || ARRAY(SELECT texto FROM ensayo_1490_notas WHERE falla ORDER BY orden);
  v_notas  := v_notas  || ARRAY(SELECT texto FROM ensayo_1490_notas WHERE NOT falla ORDER BY orden);
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, E'\n  ')
      USING DETAIL = array_to_string(v_notas, E'\n  ');
  END IF;
  IF current_setting('ensayo.continuar', true) = '1' THEN
    RAISE NOTICE 'ENSAYO OK%', E'\n  ' || array_to_string(v_notas, E'\n  ');
  ELSE
    RAISE EXCEPTION 'ENSAYO OK%', E'\n  ' || array_to_string(v_notas, E'\n  ');
  END IF;
 END;
END
$ensayo$;
