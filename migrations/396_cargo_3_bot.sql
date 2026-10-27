-- NNN · Cargo de envio: el bot respeta el modo y muestra el cargo (#1220).
--
-- Diseno: docs/superpowers/specs/2026-10-26-cargo-envio-faltantes-design.md, §5.
-- Tercera migracion del plan: requiere cargo_1_base (pedido_cargo_envio con
-- "sin productos no hay envio" y el estado del cargo en crear_pedido_completo_bot).
--
-- La vista previa del bot (previsualizar_pedido, edge function) calcula el
-- cargo de envio con la politica vigente y se lo muestra al preventista. La
-- confirmacion vive 10 minutos: si en el medio el admin cambia la politica
-- (el costo del envio, el umbral o el modo), crear_pedido_completo_bot cobraria
-- un cargo distinto del que el preventista le dijo al cliente. Como la 373 con
-- la promo, la confirmacion se rechaza y pide volver a previsualizar.
--
-- 1) bot_pedidos_pendientes.cargo_mostrado numeric(12,2) NOT NULL DEFAULT 0:
--    el cargo que mostro la vista previa. Los grants son los de la tabla (solo
--    postgres y service_role, sin RLS policies): la columna los hereda y no se
--    concede nada por columna. No va en scripts/grants-rest.json (el front no
--    la toca; la escribe el bot con service_role).
--
-- 2) crear_pedido_completo_bot (firma igual): despues de la compra minima, si
--    pedido_cargo_envio(total, sucursal) difiere de cargo_mostrado en mas de
--    0,01 devuelve
--      {success:false, error:'El costo de envío cambió desde la vista previa.
--       Pedí la vista previa de nuevo.'}
--    ANTES de escribir nada: el pendiente no se consume.
--
-- Compatibilidad con el bot desplegado (edge functions viejas, que no escriben
-- cargo_mostrado): la columna nace en 0.
--   * En una sucursal que no cobra envio ('bloquear', o cargo 0) el cargo da 0
--     y el chequeo no muerde: el bot viejo sigue andando igual.
--   * En una sucursal que SI cobra (al 2026-10-27, Tucuman: escalas
--     8000/15000/500), entre esta migracion y el deploy del bot nuevo, el bot
--     viejo RECHAZA todo pedido de la franja que paga envio ([8000, 15000)) con
--     "El costo de envío cambió desde la vista previa. Pedí la vista previa de
--     nuevo.", y volver a previsualizar no lo arregla (el bot viejo vuelve a
--     guardar 0). Fuera de la franja (desde el gratis) crea normalmente. Es el
--     lado seguro: sin esta migracion el bot viejo crea el pedido cobrando un
--     envio que nunca le mostro al preventista.
--   * Al reves, el bot NUEVO antes de esta migracion rompe TODAS las vistas
--     previas: inserta cargo_mostrado, que no existe (PGRST204).
-- Por eso se despliega en UNA ventana: las migraciones del plan en orden y,
-- enseguida, el front y las edge functions del bot. Nunca el bot antes.
-- El $verif$ avisa (NOTICE) que sucursales cobran envio al aplicar.
--
-- Ensayo: scripts/test-cargo-3.sql.

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1 · La columna
-- ---------------------------------------------------------------------------
ALTER TABLE public.bot_pedidos_pendientes
  ADD COLUMN IF NOT EXISTS cargo_mostrado numeric(12,2) NOT NULL DEFAULT 0;

ALTER TABLE public.bot_pedidos_pendientes
  DROP CONSTRAINT IF EXISTS bot_pedidos_pendientes_cargo_mostrado_no_negativo;
ALTER TABLE public.bot_pedidos_pendientes
  ADD CONSTRAINT bot_pedidos_pendientes_cargo_mostrado_no_negativo CHECK (cargo_mostrado >= 0);

COMMENT ON COLUMN public.bot_pedidos_pendientes.cargo_mostrado IS
  'Cargo de envio que mostro la vista previa del bot. crear_pedido_completo_bot '
  'rechaza la confirmacion si la politica vigente da otro. mig NNN (cargo_3_bot).';

-- ---------------------------------------------------------------------------
-- 2 · Parche por ancla sobre la definicion viva
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.cargo3_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_veces int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF v_veces <> 1 THEN
    RAISE EXCEPTION '%: el ancla aparece % veces (se esperaba 1). El cuerpo vivo cambio: revisar a mano', p_que, v_veces;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo3_parchar(v_def,
$q$    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_pendiente.sucursal_id);
    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error', v_motivo_minimo);
    END IF;$q$,
$q$    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_pendiente.sucursal_id);
    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error', v_motivo_minimo);
    END IF;

    -- cargo_3_bot: el cargo que se cobra es el que mostro la vista previa. Si
    -- la politica cambio en los 10 minutos de la confirmacion, se pide otra
    -- vista previa, sin consumir el pendiente (como la 373 con la promo).
    IF abs(v_cargo_envio - COALESCE(v_pendiente.cargo_mostrado, 0)) > 0.01 THEN
      RETURN jsonb_build_object('success', false, 'error',
        'El costo de envío cambió desde la vista previa. Pedí la vista previa de nuevo.');
    END IF;$q$,
    'crear_pedido_completo_bot: chequeo del cargo mostrado');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · Verificacion
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text;
  v_acl text;
  v_col record;
  v_pol record;
  v_pos_calc   int;
  v_pos_check  int;
  v_pos_insert int;
  v_pos_consum int;
  v_total      numeric;
  v_cargo      numeric;
  v_cond       text;
  v_rechaza    boolean;
BEGIN
  SELECT pg_get_functiondef(p.oid), array_to_string(p.proacl, ',') INTO v_def, v_acl
    FROM pg_proc p WHERE p.oid = 'public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure;
  IF v_def NOT LIKE '%cargo_3_bot%' OR v_def NOT LIKE '%v_pendiente.cargo_mostrado%' THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot no quedo parcheada';
  END IF;
  -- El parche de cargo_1_base sigue (la mig 3 corre sobre la 1).
  IF v_def NOT LIKE '%cargo_1_base%' THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot no tiene el parche de cargo_1_base: aplicar antes esa migracion';
  END IF;
  -- Funcion de server: sigue sin EXECUTE para PUBLIC, anon ni authenticated.
  IF has_function_privilege('anon', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE')
     OR (v_acl IS NOT NULL AND (v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%'))
     OR NOT has_function_privilege('service_role', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot cambio de permisos: %', v_acl;
  END IF;

  SELECT c.is_nullable, c.column_default, c.numeric_precision, c.numeric_scale INTO v_col
    FROM information_schema.columns c
   WHERE c.table_schema = 'public' AND c.table_name = 'bot_pedidos_pendientes'
     AND c.column_name = 'cargo_mostrado';
  IF NOT FOUND OR v_col.is_nullable <> 'NO' OR v_col.column_default IS DISTINCT FROM '0'
     OR v_col.numeric_precision <> 12 OR v_col.numeric_scale <> 2 THEN
    RAISE EXCEPTION 'bot_pedidos_pendientes.cargo_mostrado no quedo numeric(12,2) NOT NULL DEFAULT 0: %', v_col;
  END IF;
  -- Nadie de la API la lee ni la escribe; el bot (service_role) si.
  IF has_column_privilege('anon', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'SELECT')
     OR has_column_privilege('authenticated', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'SELECT')
     OR has_column_privilege('anon', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'INSERT')
     OR has_column_privilege('authenticated', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'INSERT')
     OR has_column_privilege('authenticated', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'UPDATE') THEN
    RAISE EXCEPTION 'bot_pedidos_pendientes.cargo_mostrado tiene un grant de mas';
  END IF;
  IF NOT has_column_privilege('service_role', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'INSERT')
     OR NOT has_column_privilege('service_role', 'public.bot_pedidos_pendientes', 'cargo_mostrado', 'SELECT') THEN
    RAISE EXCEPTION 'service_role no puede escribir o leer bot_pedidos_pendientes.cargo_mostrado';
  END IF;

  -- El chequeo esta donde tiene que estar: despues de calcular el cargo y antes
  -- de crear el pedido y de consumir el pendiente (sin escribir nada).
  v_pos_calc   := strpos(v_def, 'v_cargo_envio := public.pedido_cargo_envio(v_total_calc, v_pendiente.sucursal_id)');
  v_pos_check  := strpos(v_def, 'IF abs(v_cargo_envio - COALESCE(v_pendiente.cargo_mostrado, 0)) > 0.01 THEN');
  v_pos_insert := strpos(v_def, 'INSERT INTO pedidos');
  v_pos_consum := strpos(v_def, 'UPDATE bot_pedidos_pendientes SET consumido = TRUE');
  IF v_pos_calc = 0 OR v_pos_check = 0 OR v_pos_insert = 0 OR v_pos_consum = 0
     OR NOT (v_pos_calc < v_pos_check AND v_pos_check < v_pos_insert AND v_pos_check < v_pos_consum) THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot: el chequeo del cargo mostrado no quedo entre el calculo del cargo y las escrituras (calc %, check %, insert %, consumido %)',
      v_pos_calc, v_pos_check, v_pos_insert, v_pos_consum;
  END IF;

  -- La condicion del chequeo, tomada del cuerpo vivo y evaluada (sin escribir)
  -- con el cargo de una politica que cobra (escalas 5000/15000/500, $12.000 de
  -- productos -> 500, la misma pura que usa pedido_cargo_envio): un pendiente
  -- del bot viejo (cargo_mostrado 0) se rechaza, uno que mostro 500 no, y una
  -- politica que no cobra (bloquear) deja pasar al bot viejo.
  v_cond := substring(v_def FROM v_pos_check + 3
                      FOR strpos(substring(v_def FROM v_pos_check), ' THEN') - 4);
  v_cond := replace(replace(v_cond, 'v_pendiente.cargo_mostrado', '$2'), 'v_cargo_envio', '$1');
  v_cargo := public.cargo_envio_pedido_puro(12000, 'escalas', 5000, 15000, 500);
  EXECUTE 'SELECT ' || v_cond INTO v_rechaza USING v_cargo, 0::numeric;
  IF v_cargo <> 500 OR NOT v_rechaza THEN
    RAISE EXCEPTION 'El chequeo (%) no rechaza un pendiente con cargo_mostrado 0 cuando la politica cobra % ', v_cond, v_cargo;
  END IF;
  EXECUTE 'SELECT ' || v_cond INTO v_rechaza USING v_cargo, 500::numeric;
  IF v_rechaza THEN
    RAISE EXCEPTION 'El chequeo (%) rechaza un pendiente que mostro el mismo cargo (%)', v_cond, v_cargo;
  END IF;
  v_cargo := public.cargo_envio_pedido_puro(12000, 'bloquear', 15000, 0, 500);
  EXECUTE 'SELECT ' || v_cond INTO v_rechaza USING v_cargo, 0::numeric;
  IF v_rechaza THEN
    RAISE EXCEPTION 'Con bloquear el chequeo (%) rechaza al bot desplegado (cargo %)', v_cond, v_cargo;
  END IF;

  -- Aviso (no error): las sucursales que hoy cobran envio. En ellas, hasta
  -- desplegar el bot nuevo, el bot viejo rechaza los pedidos de la franja que
  -- paga ("El costo de envío cambió..."). Se prueba con un total dentro de la
  -- franja contra la politica real.
  FOR v_pol IN
    SELECT pc.sucursal_id, pc.modo_minimo_pedido, pc.monto_minimo_pedido,
           pc.monto_envio_gratis, pc.cargo_envio_pedido
      FROM public.politicas_comerciales pc
     WHERE pc.modo_minimo_pedido <> 'bloquear'
     ORDER BY pc.sucursal_id
  LOOP
    v_total := CASE v_pol.modo_minimo_pedido
                 WHEN 'escalas' THEN GREATEST(v_pol.monto_minimo_pedido, 0.01)
                 ELSE 0.01 END;
    v_cargo := public.pedido_cargo_envio(v_total, v_pol.sucursal_id);
    RAISE NOTICE 'cargo_3_bot: la sucursal % esta en % (minimo %, gratis %, cargo %); un pedido de % paga %. Hasta desplegar el bot nuevo, el bot viejo rechaza los pedidos que pagan envio.',
      v_pol.sucursal_id, v_pol.modo_minimo_pedido, v_pol.monto_minimo_pedido,
      v_pol.monto_envio_gratis, v_pol.cargo_envio_pedido, v_total, v_cargo;
  END LOOP;
END
$verif$;

-- ROLLBACK: volver a aplicar la definicion de crear_pedido_completo_bot de
-- cargo_1_base (sin el bloque cargo_3_bot) y
--   ALTER TABLE public.bot_pedidos_pendientes DROP COLUMN cargo_mostrado;
-- (el CHECK se va con la columna). Las edge functions nuevas escriben la
-- columna: revertir primero el deploy del bot.
