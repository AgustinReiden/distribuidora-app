-- ============================================================================
-- NNN · El bot: el resumen perdido se recupera, el último pedido es el del
--       día, y el panel mira lo mismo que se manda (#1387, #1339; plan #1389,
--       tarjeta 7)
-- ============================================================================
-- El número se elige al aplicar, contra el ledger de prod y origin/main
-- (trampa 3 de CLAUDE.md). Aplicar desde el contenido LF.
--
-- QUÉ ES ESTO
-- -----------
-- #1387 · 1. Un día con el cron caído no se recuperaba. `bot_digest_pendientes`
--   miraba sólo el resumen de hoy (el día resumido = ayer): si ninguna corrida de
--   telegram-digest.yml caía entre la hora de alguien y las 23:59, a las 00:00 la
--   fecha pasaba a la siguiente y ese resumen no salía nunca. Decisión del dueño
--   (02/11): se recupera UN día atrás, y el mensaje dice de qué fecha es. Ahora
--   devuelve además el resumen que tocaba AYER (el de anteayer), con la misma
--   regla que el de hoy:
--     · desde la hora de la persona en adelante, también para el atrasado: sale
--       junto con el de hoy y no a la medianoche;
--     · el día de la semana es el del envío que se perdió (`p_fecha`), no hoy;
--     · sin marca, o con marca 'error'. Una marca en 'enviando' es una corrida
--       que murió en el medio y NO se reintenta (#1309, BOT-10): preferimos
--       perder un resumen, que el gate ve, a mandarlo dos veces. 'skipped' (403 o
--       sin contenido) tampoco.
--   Cada fila trae su `fecha` (el día resumido) y `atrasado`, y la edge function
--   arma el mensaje con esa fecha. El gate (`auditoria_bot`, 30 horas hacia atrás)
--   no cambia: ya esperaba el resumen de ayer y ahora la recuperación lo cumple.
-- #1387 · 2. `obtener_resumen_cuenta_cliente_bot.ultimo_pedido` era
--   `MAX(created_at)`, la hora de carga: un pedido cargado de noche o para otro
--   día no decía la fecha del pedido, y el formatter del bot, que corre en UTC, le
--   cambiaba el día a lo cargado entre las 21 y las 24. Ahora es `MAX(fecha)`.
-- #1387 · 3. El panel del resumen miraba `bot_usuarios.sucursal_id` (lo que
--   escribe /sucursal), y desde #1309 el resumen sale de `usuario_sucursales`.
--   `bot_admin_listar_config_digest` lista una fila por persona (el chat que usa
--   `bot_digest_suscripciones`, no una por chat) con sus sucursales activas
--   asignadas, y `bot_admin_guardar_config_digest` exige una para PRENDER el
--   resumen, a admin y a preventista, como la suscripción. Apagarlo se puede
--   siempre: antes, a un preventista sin /sucursal no se lo podía ni apagar.
-- #1339 · El panel distingue los dos apagados. `bot_admin_listar_vinculados`
--   devuelve si el perfil tiene la marca de `bot_apagados_por_admin` (y cuándo y
--   quién). `bot_admin_toggle_usuario(p_activo := false)` ya deja la marca sobre
--   una fila inactiva sin prenderla: no cambia, lo prueba el ensayo; el panel
--   ofrece esa acción.
--
-- QUÉ SE TOCA
-- -----------
-- Reemplazadas enteras (md5 del cuerpo vivo verificado): bot_digest_pendientes,
--   bot_admin_listar_config_digest.
-- Parcheadas por ancla (md5 verificado): obtener_resumen_cuenta_cliente_bot,
--   bot_admin_guardar_config_digest, bot_admin_listar_vinculados.
-- Ninguna cambia de firma ni de RETURNS: CREATE OR REPLACE conserva dueño,
--   SECURITY DEFINER, search_path y ACL (lo verifica el paso 4).
-- Se lee sin tocar: bot_digest_suscripciones.
--
-- ORDEN: ESTA MIGRACIÓN PUEDE IR ANTES DEL DEPLOY
-- -----------------------------------------------
-- La edge function vieja ignora `fecha` y `atrasado`: con un atrasado pendiente
-- recibe una fila más del mismo (perfil, sucursal) y la reserva con la fecha de
-- hoy, así que de las dos reservas gana una y no hay doble envío; el atrasado
-- sale recién con la función nueva, si todavía está en la ventana. El panel viejo
-- sigue leyendo `sucursal_nombre` (ahora la lista de sucursales) y no ve la marca.
-- ============================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig NNN · el texto de la migración trae CRLF: aplicarla desde la versión LF (git show HEAD:migrations/<archivo>)';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- 0 · Premisas: nada cambió en prod desde que se leyeron los cuerpos (03/11,
--     ledger en visitas_cliente)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.bot_digest_pendientes(date,integer,integer)',                           'ed1f656d62c14b359951514df8f0dda7'),
        ('public.obtener_resumen_cuenta_cliente_bot(integer)',                           '43993698c26ad78619c1e705ffbfa6cd'),
        ('public.bot_admin_listar_config_digest()',                                      'dde1803ca6115fd026aed29ff550039c'),
        ('public.bot_admin_guardar_config_digest(uuid,boolean,integer,integer[],text[])', 'bb60a0c6b0175c30120a2c9346ffadcd'),
        ('public.bot_admin_listar_vinculados()',                                         '07c2b4d2d23f041bea8c74abd7ad79a1')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5(prosrc) %, esperado %): rehacer los cambios sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · #1387.1: el resumen de hoy y, si no salió, el de ayer
-- ---------------------------------------------------------------------------
-- `p_fecha` es el día que resume el envío de hoy (ayer), `p_hora` y `p_dow` la
-- hora y el día de la semana de hoy (reloj.ts). El envío de ayer resumía
-- `p_fecha - 1` y su día de la semana es el de `p_fecha`.
CREATE OR REPLACE FUNCTION public.bot_digest_pendientes(p_fecha date, p_hora integer, p_dow integer)
RETURNS json
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH envios AS (
    SELECT p_fecha AS fecha, p_dow::SMALLINT AS dow, false AS atrasado
    UNION ALL
    -- #1387 (decisión del dueño 02/11): el de ayer, un día atrás y no más.
    SELECT p_fecha - 1, EXTRACT(ISODOW FROM p_fecha)::SMALLINT, true
  )
  SELECT COALESCE(
    json_agg(
      json_build_object(
        'telegram_user_id', t.telegram_user_id,
        'perfil_id',        t.perfil_id,
        'rol',              t.rol,
        'sucursal_id',      t.sucursal_id,
        'sucursal_nombre',  t.sucursal_nombre,
        'secciones',        t.secciones,
        'fecha',            e.fecha,
        'atrasado',         e.atrasado
      )
      -- El atrasado primero: la edge function lo manda antes que el de hoy.
      ORDER BY e.fecha, t.telegram_user_id, t.sucursal_id
    ),
    '[]'::json
  )
  FROM bot_digest_suscripciones() t
  CROSS JOIN envios e
  -- Desde su hora en adelante, también el atrasado: sale con el de hoy, no a la
  -- medianoche.
  WHERE t.hora_local <= p_hora::SMALLINT
    AND e.dow = ANY (t.dias_semana)
    -- Sin secciones no hay mensaje que mandar.
    AND array_length(t.secciones, 1) >= 1
    -- Un 'error' vuelve a salir; 'enviando' (una corrida que murió en el medio),
    -- 'ok' y 'skipped', no.
    AND NOT EXISTS (
      SELECT 1 FROM bot_digests_enviados d
       WHERE d.admin_perfil_id = t.perfil_id
         AND d.fecha = e.fecha
         AND d.sucursal_id = t.sucursal_id
         AND d.status <> 'error'
    );
$function$;

-- ---------------------------------------------------------------------------
-- 2 · #1387.3: el panel del resumen mira lo que mira la suscripción
-- ---------------------------------------------------------------------------
-- Una fila por persona: el chat es el que elige `bot_digest_suscripciones` (el
-- último vinculado de los prendidos), y las sucursales, las activas asignadas.
-- `sucursal_nombre` queda como la lista de nombres, para el panel viejo.
CREATE OR REPLACE FUNCTION public.bot_admin_listar_config_digest()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rol       TEXT;
  v_resultado JSON;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede ver la configuración del digest';
  END IF;

  WITH chats AS (
    -- El mismo chat que bot_digest_suscripciones: uno por persona.
    SELECT DISTINCT ON (bu.perfil_id) bu.perfil_id, bu.telegram_user_id
      FROM bot_usuarios bu
     WHERE bu.activo
     ORDER BY bu.perfil_id, bu.vinculado_at DESC, bu.telegram_user_id DESC
  )
  SELECT COALESCE(
    json_agg(
      json_build_object(
        'perfil_id',        ch.perfil_id,
        'perfil_nombre',    p.nombre,
        'rol',              p.rol,
        -- La fila del propio admin: el panel la muestra primero y la rotula "Vos".
        'es_propio',        (ch.perfil_id = auth.uid()),
        'telegram_user_id', ch.telegram_user_id,
        -- #1387: las sucursales que resume (usuario_sucursales, desde #1309), no
        -- la de /sucursal. Vacía = no le llega ningún resumen.
        'sucursales',       suc.lista,
        'sucursal_nombre',  suc.nombres,
        'configurado',      (c.perfil_id IS NOT NULL),
        'activo',           COALESCE(c.activo, p.rol = 'admin'),
        'hora_local',       COALESCE(c.hora_local, 7),
        'dias_semana',      COALESCE(c.dias_semana, ARRAY[1,2,3,4,5,6,7]::SMALLINT[]),
        'secciones',        COALESCE(c.secciones, digest_secciones_default(p.rol)),
        'secciones_permitidas', digest_secciones_del_rol(p.rol),
        -- Aviso semanal de atrasados: sólo preventistas (NULL para un admin).
        'aviso_atrasados', CASE WHEN p.rol = 'preventista' THEN json_build_object(
            'activo', COALESCE(c.aviso_atrasados_activo, TRUE),
            'hora',   COALESCE(c.aviso_atrasados_hora, 8),
            'dias',   COALESCE(c.aviso_atrasados_dias, ARRAY[1]::SMALLINT[])
          ) END,
        'actualizado_at',   c.actualizado_at,
        'actualizado_por',  ap.nombre
      )
      ORDER BY (ch.perfil_id <> auth.uid()), (p.rol <> 'admin'), p.nombre
    ),
    '[]'::json
  )
  INTO v_resultado
  FROM chats ch
  JOIN perfiles p               ON p.id = ch.perfil_id
  CROSS JOIN LATERAL (
    SELECT COALESCE(json_agg(json_build_object('id', s.id, 'nombre', s.nombre) ORDER BY s.id), '[]'::json) AS lista,
           string_agg(s.nombre::text, ' · ' ORDER BY s.id) AS nombres
      FROM usuario_sucursales us
      JOIN sucursales s ON s.id = us.sucursal_id AND s.activa IS TRUE
     WHERE us.usuario_id = ch.perfil_id
  ) suc
  LEFT JOIN bot_digest_config c ON c.perfil_id = ch.perfil_id
  LEFT JOIN perfiles ap         ON ap.id = c.actualizado_por
  WHERE p.activo AND p.rol IN ('admin', 'preventista')
    AND bot_admin_puede_gestionar(auth.uid(), ch.perfil_id);

  RETURN v_resultado;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3 · Parches por ancla sobre el cuerpo vivo (md5 verificado en el paso 0)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _bot_parche (
  orden     serial,
  firma     text NOT NULL,
  veces     int  NOT NULL,
  ancla     text NOT NULL,
  reemplazo text NOT NULL
) ON COMMIT DROP;

INSERT INTO _bot_parche (firma, veces, ancla, reemplazo) VALUES
-- #1387.2: el último pedido es el día del pedido, no la hora de carga.
('public.obtener_resumen_cuenta_cliente_bot(integer)', 1,
$a$    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos$a$,
$r$    'ultimo_pedido', (SELECT MAX(fecha) FROM pedidos  -- #1387: el día del pedido, no la hora de carga$r$),
-- #1387.3: para prender el resumen hace falta una sucursal activa asignada, a
-- admin y a preventista, como en bot_digest_suscripciones. Apagarlo, no.
('public.bot_admin_guardar_config_digest(uuid,boolean,integer,integer[],text[])', 1,
$a$     -- Mismo filtro que bot_digest_destinatarios: un preventista sin sucursal
     -- activa no recibe nada, y el panel no puede decir "Recibe" por el.
     AND (p.rol = 'admin' OR bu.sucursal_id IS NOT NULL)
   LIMIT 1;
  IF v_rol_destino IS NULL THEN
    RAISE EXCEPTION 'El perfil % no es un admin ni un preventista vinculado al bot con sucursal activa', p_perfil_id;
  END IF;
$a$,
$r$   LIMIT 1;
  IF v_rol_destino IS NULL THEN
    RAISE EXCEPTION 'El perfil % no es un admin ni un preventista vinculado al bot', p_perfil_id;
  END IF;
  -- #1387: la sucursal del resumen es la de bot_digest_suscripciones
  -- (usuario_sucursales, #1309), no la de /sucursal, y vale para los dos roles:
  -- sin ninguna activa asignada no le llega nada, y el panel no puede decir
  -- "Recibe" por él. Apagarlo se puede siempre.
  IF p_activo AND NOT EXISTS (
    SELECT 1 FROM usuario_sucursales us
      JOIN sucursales s ON s.id = us.sucursal_id AND s.activa IS TRUE
     WHERE us.usuario_id = p_perfil_id
  ) THEN
    RAISE EXCEPTION 'No tiene ninguna sucursal activa asignada, así que no le llegaría ningún resumen: asignale una antes de prenderlo';
  END IF;
$r$),
-- #1339: el panel distingue "apagado por un admin" (con marca) de "desvinculado".
('public.bot_admin_listar_vinculados()', 1,
$a$        'activo',             bu.activo
$a$,
$r$        'activo',             bu.activo,
        -- #1339: la marca es del perfil (#1311). Sin marca, un inactivo se
        -- desvinculó solo y vuelve con un código; con marca, lo prende un admin.
        'apagado_por_admin',  (a.perfil_id IS NOT NULL),
        'apagado_at',         a.apagado_at,
        'apagado_por_nombre', ap.nombre
$r$),
('public.bot_admin_listar_vinculados()', 1,
$a$  LEFT JOIN sucursales s ON s.id = bu.sucursal_id
$a$,
$r$  LEFT JOIN sucursales s ON s.id = bu.sucursal_id
  LEFT JOIN bot_apagados_por_admin a ON a.perfil_id = bu.perfil_id
  LEFT JOIN perfiles ap ON ap.id = a.apagado_por
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _bot_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _bot_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig NNN · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 4 · Lo cambiado quedó cambiado, y los permisos como estaban
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.marca, x.auth FROM (VALUES
      ('public.bot_digest_pendientes(date,integer,integer)',                           '''atrasado''',               false),
      ('public.obtener_resumen_cuenta_cliente_bot(integer)',                           'MAX(fecha) FROM pedidos',    false),
      ('public.bot_admin_listar_config_digest()',                                      '''sucursales''',             true),
      ('public.bot_admin_guardar_config_digest(uuid,boolean,integer,integer[],text[])', 'IF p_activo AND NOT EXISTS', true),
      ('public.bot_admin_listar_vinculados()',                                         'apagado_por_admin',          true)
    ) AS x(firma, marca, auth)
  LOOP
    IF position(v_f.marca in pg_get_functiondef(v_f.firma::regprocedure)) = 0 THEN
      RAISE EXCEPTION 'mig NNN · % no quedó cambiada', v_f.firma;
    END IF;
    IF has_function_privilege('anon', v_f.firma, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó ejecutable con la anon key', v_f.firma;
    END IF;
    IF has_function_privilege('authenticated', v_f.firma, 'EXECUTE') <> v_f.auth THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para authenticated = %, se esperaba %',
        v_f.firma, NOT v_f.auth, v_f.auth;
    END IF;
    IF NOT has_function_privilege('service_role', v_f.firma, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó sin EXECUTE para service_role', v_f.firma;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_f.firma::regprocedure) THEN
      RAISE EXCEPTION 'mig NNN · % dejó de ser SECURITY DEFINER', v_f.firma;
    END IF;
  END LOOP;
END
$post$;

-- ---------------------------------------------------------------------------
-- 5 · Ensayo, dentro de la transacción
-- ---------------------------------------------------------------------------
-- Lo que hace falta que sea cierto antes del COMMIT. El ensayo largo, con datos
-- armados, es scripts/test-bot-1387-1339.sql.
DO $ensayo$
DECLARE
  v_n int;
BEGIN
  -- Ni hoy ni ayer devuelve algo que ya tiene marca que no sea 'error'.
  SELECT count(*) INTO v_n
    FROM json_array_elements(public.bot_digest_pendientes(public._tablero_hoy() - 1, 23,
           EXTRACT(ISODOW FROM public._tablero_hoy())::int)) e
    JOIN bot_digests_enviados d
      ON d.admin_perfil_id = (e->>'perfil_id')::uuid
     AND d.sucursal_id = (e->>'sucursal_id')::bigint
     AND d.fecha = (e->>'fecha')::date
     AND d.status <> 'error';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig NNN · ensayo: bot_digest_pendientes devuelve % ya enviados', v_n;
  END IF;

  -- Nunca más de un día atrás.
  SELECT count(*) INTO v_n
    FROM json_array_elements(public.bot_digest_pendientes(public._tablero_hoy() - 1, 23,
           EXTRACT(ISODOW FROM public._tablero_hoy())::int)) e
   WHERE (e->>'fecha')::date NOT IN (public._tablero_hoy() - 1, public._tablero_hoy() - 2)
      OR ((e->>'fecha')::date = public._tablero_hoy() - 2) IS DISTINCT FROM (e->>'atrasado')::boolean;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig NNN · ensayo: bot_digest_pendientes devuelve % filas fuera de hoy y ayer', v_n;
  END IF;

  RAISE NOTICE 'mig NNN · ensayo ok';
END
$ensayo$;

COMMIT;
