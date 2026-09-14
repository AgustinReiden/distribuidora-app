-- =========================================================================
-- El bot mira el perfil en vivo
--
-- EL BUG
-- ---------------------------------------------------------------------------
-- `canjear_codigo_vinculacion_bot` (014) copiaba el rol y la sucursal de
-- `perfiles` a `bot_usuarios` al vincular, y desde ahi el bot no volvia a mirar
-- `perfiles` nunca mas: `resolveUserByTelegramId` era un SELECT plano sobre
-- `bot_usuarios` filtrando por `activo = true`, sin un solo JOIN.
--
-- La 206 ("activo bloquea el acceso") cerro la puerta de la web y no toco esta.
-- O sea: dar de baja a un empleado en la app, o bajarlo de admin a preventista,
-- no le cortaba ni le cambiaba nada por Telegram. Seguia creando pedidos y
-- viendo saldos con el rol que tenia el dia que se vinculo, hasta que un admin
-- se acordara de desactivarlo tambien en el panel del bot. Dos interruptores
-- para una sola decision, y el segundo no lo conoce nadie.
--
-- EL ARREGLO: bot_usuarios deja de ser la fuente del rol
-- ---------------------------------------------------------------------------
-- `bot_resolver_usuario(telegram_user_id)` resuelve en cada mensaje contra
-- `perfiles` y `usuario_sucursales`. Lo que queda en `bot_usuarios` es solo lo
-- que es de el: el mapping chat <-> perfil, el interruptor propio del bot
-- (`activo`, que maneja `bot_admin_toggle_usuario`) y la sucursal ACTIVA que el
-- usuario eligio con /sucursal.
--
-- Esa sucursal es un override, no un snapshot: el resolver la valida contra
-- `usuario_sucursales` en cada mensaje y cae a la default si el usuario dejo de
-- tenerla asignada o si la sucursal se desactivo. Antes se quedaba pegada para
-- siempre.
--
-- La columna `bot_usuarios.rol` NO se dropea: la edge function desplegada hoy la
-- selecciona, y el deploy de las functions va al mergear, no al aplicar esta
-- migracion. Queda como dato historico ("con que rol se vinculo"), con el
-- COMMENT que lo dice. Los dos lugares que la leian para decidir algo pasan a
-- leer `perfiles` en vivo: `bot_admin_listar_vinculados` (aca) y el cargador de
-- admins de `telegram-digest` (en la edge function).
--
-- EL OTP: 24 bits de hexa y sin contador de intentos
-- ---------------------------------------------------------------------------
-- El codigo se generaba con `upper(substring(encode(gen_random_bytes(4),'hex')
-- FROM 1 FOR 6))`. El alfabeto real de eso es hexadecimal -- 16 simbolos, no 36:
-- 16^6 = 16,8 millones, y los mensajes del bot decian "letras mayusculas y
-- numeros" sobre un codigo que nunca tuvo una letra arriba de la F. Con TTL de
-- 10 minutos y un canje que no contaba nada, un bot que prueba codigos tenia
-- todo el tiempo del mundo y ningun costo por errar.
--
-- Ahora son 8 caracteres de un alfabeto alfanumerico de 32 simbolos
-- (`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`, sin 0/O ni 1/I para que no se lean mal
-- al dictarlos): 32^8 = 1,1 billones, y 32 divide a 256 asi que el `% 32` sobre
-- cada byte del CSPRNG sale uniforme, sin el sesgo del modulo.
--
-- Y el canje lleva contador: `bot_intentos_vinculacion` cuenta fallos por
-- telegram_user_id en una ventana de 15 minutos y al quinto fallo bloquea 15
-- minutos. El sexto intento ya no llega a mirar el codigo.
--
-- Los codigos de 6 caracteres que estuvieran vivos se invalidan aca: el bot
-- nuevo no los acepta, y dejarlos vivos es hacerle gastar el intento a alguien.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · Que es de quien: los COMMENT de bot_usuarios
-- -------------------------------------------------------------------------

COMMENT ON TABLE bot_usuarios IS
  'Mapping de chat de Telegram a perfil de Supabase. Guarda SOLO lo que es del bot: el mapping, su propio interruptor (activo, que maneja bot_admin_toggle_usuario) y la sucursal activa elegida con /sucursal. El rol y el alta/baja del empleado viven en perfiles y los resuelve bot_resolver_usuario() en cada mensaje (mig 237).';

COMMENT ON COLUMN bot_usuarios.rol IS
  'Historico: el rol que tenia el perfil el dia que se vinculo. NO es la fuente de verdad y no decide permisos -- el rol vivo sale de perfiles.rol via bot_resolver_usuario() (mig 237). Cualquier codigo nuevo que lea esta columna para decidir algo esta leyendo un rol viejo.';

COMMENT ON COLUMN bot_usuarios.sucursal_id IS
  'Sucursal ACTIVA elegida por el usuario con /sucursal. Es un override, no un snapshot: bot_resolver_usuario() lo valida contra usuario_sucursales en cada mensaje y cae a la default si el usuario dejo de tenerla asignada o si la sucursal se desactivo (mig 237).';

COMMENT ON COLUMN bot_usuarios.activo IS
  'Interruptor propio del bot (bot_admin_toggle_usuario / /desvincular). Es independiente de perfiles.activo: para entrar al bot tienen que estar los dos en true. Desactivar al empleado en la app lo corta igual, sin tocar esta columna.';

-- -------------------------------------------------------------------------
-- 2 · bot_resolver_usuario — quien sos, ahora
--
--     Una sola llamada por mensaje -- el mensaje mas barato del bot pasa por
--     aca -- en vez de un embed de PostgREST mas una segunda consulta para la
--     sucursal. La eleccion de sucursal es un IF con fallback: en SQL se lee, y
--     el edge no tiene que replicarla. Misma convencion que el resto de las
--     bot_*: SECURITY DEFINER y GRANT solo a service_role.
--
--     Devuelve {ok:false, motivo} en vez de NULL para que el edge pueda
--     loguear POR QUE no resolvio sin una segunda consulta.
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.bot_resolver_usuario(p_telegram_user_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_perfil_id     UUID;
  v_bot_activo    BOOLEAN;
  v_bot_sucursal  BIGINT;
  v_rol           TEXT;
  v_nombre        TEXT;
  v_perfil_activo BOOLEAN;
  v_sucursal_id   BIGINT;
BEGIN
  SELECT bu.perfil_id, bu.activo, bu.sucursal_id
    INTO v_perfil_id, v_bot_activo, v_bot_sucursal
    FROM bot_usuarios bu
   WHERE bu.telegram_user_id = p_telegram_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'no_vinculado');
  END IF;

  -- El interruptor del bot (panel de admin / /desvincular).
  IF v_bot_activo IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'bot_desactivado');
  END IF;

  -- El alta/baja del empleado, en vivo. Esto es lo que la 206 cerro para la web
  -- y hasta hoy no cerraba para Telegram.
  SELECT p.rol, p.nombre, p.activo
    INTO v_rol, v_nombre, v_perfil_activo
    FROM perfiles p
   WHERE p.id = v_perfil_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'perfil_inexistente');
  END IF;

  IF v_perfil_activo IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'perfil_inactivo');
  END IF;

  -- Sucursal activa: el override de /sucursal, si sigue valiendo.
  IF v_bot_sucursal IS NOT NULL THEN
    SELECT us.sucursal_id
      INTO v_sucursal_id
      FROM usuario_sucursales us
      JOIN sucursales s ON s.id = us.sucursal_id
     WHERE us.usuario_id = v_perfil_id
       AND us.sucursal_id = v_bot_sucursal
       AND s.activa IS TRUE
     LIMIT 1;
  END IF;

  -- Si no vale (se la desasignaron, o la sucursal se desactivo), la default.
  IF v_sucursal_id IS NULL THEN
    SELECT us.sucursal_id
      INTO v_sucursal_id
      FROM usuario_sucursales us
      JOIN sucursales s ON s.id = us.sucursal_id
     WHERE us.usuario_id = v_perfil_id
       AND s.activa IS TRUE
     ORDER BY (us.es_default IS TRUE) DESC, us.sucursal_id
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'perfil_id',   v_perfil_id,
    'rol',         v_rol,
    'nombre',      v_nombre,
    'sucursal_id', v_sucursal_id,
    'activo',      true
  );
END;
$fn$;

ALTER FUNCTION public.bot_resolver_usuario(BIGINT) OWNER TO postgres;

COMMENT ON FUNCTION public.bot_resolver_usuario(BIGINT) IS
  'Resuelve un chat de Telegram a {ok, perfil_id, rol, nombre, sucursal_id} leyendo perfiles y usuario_sucursales EN VIVO. Exige bot_usuarios.activo y perfiles.activo. La sucursal es el override de /sucursal si sigue asignado y activo, si no la default. Devuelve {ok:false, motivo} con motivo en {no_vinculado, bot_desactivado, perfil_inexistente, perfil_inactivo}. Solo service_role. mig 237.';

-- -------------------------------------------------------------------------
-- 3 · bot_intentos_vinculacion — el contador de fallos del canje
--
--     Una fila por telegram_user_id que alguna vez erro un codigo, y solo una:
--     el upsert la pisa. No necesita retencion (el telegram_user_id sale del
--     webhook firmado, no se puede rociar con ids nuevos).
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS bot_intentos_vinculacion (
  telegram_user_id   BIGINT       PRIMARY KEY,
  fallidos           INT          NOT NULL DEFAULT 0,
  ventana_inicio_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  ultimo_intento_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  bloqueado_hasta    TIMESTAMPTZ
);

ALTER TABLE bot_intentos_vinculacion ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE bot_intentos_vinculacion IS
  'Contador de canjes de OTP fallidos por chat de Telegram. Ventana de 15 minutos: al quinto fallo se bloquea el canje 15 minutos y el sexto intento no llega a mirar el codigo. Un canje exitoso borra la fila. RLS habilitada sin policies: solo service_role, y solo a traves de canjear_codigo_vinculacion_bot(). mig 237.';

-- -------------------------------------------------------------------------
-- 4 · generar_codigo_vinculacion_bot — 8 caracteres, alfabeto de verdad
--
--     Forward-only sobre el cuerpo vivo (que trae el `extensions.` de la 020).
--     Lo unico que cambia es como se arma el codigo.
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.generar_codigo_vinculacion_bot()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  -- 32 simbolos: alfanumerico sin 0/O ni 1/I, que son los que se leen mal
  -- cuando alguien dicta el codigo por telefono. 32 divide a 256, asi que el
  -- `% 32` sobre cada byte sale uniforme (con 36 habria sesgo de modulo).
  c_alfabeto  CONSTANT TEXT := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  c_largo     CONSTANT INT  := 8;
  v_codigo    TEXT;
  v_bytes     BYTEA;
  v_expira_at TIMESTAMPTZ;
  v_intentos  INT := 0;
  i           INT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  UPDATE bot_codigos_vinculacion
     SET usado_at = now()
   WHERE perfil_id = auth.uid()
     AND usado_at IS NULL;

  v_expira_at := now() + interval '10 minutes';

  LOOP
    -- pgcrypto en schema `extensions` (default Supabase): qualified name.
    v_bytes  := extensions.gen_random_bytes(c_largo);
    v_codigo := '';
    FOR i IN 0 .. c_largo - 1 LOOP
      v_codigo := v_codigo || substr(c_alfabeto, (get_byte(v_bytes, i) % 32) + 1, 1);
    END LOOP;

    BEGIN
      INSERT INTO bot_codigos_vinculacion (codigo, perfil_id, expira_at)
        VALUES (v_codigo, auth.uid(), v_expira_at);
      RETURN jsonb_build_object('codigo', v_codigo, 'expira_at', v_expira_at);
    EXCEPTION WHEN unique_violation THEN
      v_intentos := v_intentos + 1;
      IF v_intentos >= 5 THEN
        RAISE EXCEPTION 'No se pudo generar código único';
      END IF;
    END;
  END LOOP;
END;
$fn$;

COMMENT ON FUNCTION public.generar_codigo_vinculacion_bot() IS
  'Genera un OTP de 8 caracteres (alfabeto de 32 simbolos: alfanumerico sin 0/O/1/I) con TTL de 10 minutos para vincular un chat de Telegram al perfil del usuario authenticated actual. Invalida los codigos activos previos del mismo perfil. Retorna { codigo, expira_at } con el expira_at del server para que el countdown del cliente no dependa del reloj del navegador. mig 237 (era hexa de 6 desde la 014).';

-- -------------------------------------------------------------------------
-- 5 · canjear_codigo_vinculacion_bot — con contador y lockout
--
--     Un solo punto de salida para los errores (v_error) para que no haya una
--     rama de fallo que se olvide de contar. El quinto fallo deja puesto el
--     bloqueo y devuelve igual SU error; el sexto intento ya ni mira el codigo.
--     Un canje exitoso borra el contador.
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.canjear_codigo_vinculacion_bot(
  p_codigo             TEXT,
  p_telegram_user_id   BIGINT,
  p_telegram_username  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  c_max_fallidos CONSTANT INT      := 5;
  c_ventana      CONSTANT INTERVAL := interval '15 minutes';
  c_lockout      CONSTANT INTERVAL := interval '15 minutes';

  v_codigo_row     bot_codigos_vinculacion%ROWTYPE;
  v_perfil_id      UUID;
  v_perfil_rol     TEXT;
  v_perfil_nombre  TEXT;
  v_perfil_activo  BOOLEAN;
  v_sucursal_id    BIGINT;
  v_error          TEXT := NULL;
  v_fallidos       INT;
  v_bloqueado      TIMESTAMPTZ;
BEGIN
  -- 0) Lockout. Se mira antes que el codigo: un intento bloqueado no tiene que
  --    poder distinguir un codigo existente de uno inventado.
  SELECT bi.bloqueado_hasta
    INTO v_bloqueado
    FROM bot_intentos_vinculacion bi
   WHERE bi.telegram_user_id = p_telegram_user_id
   FOR UPDATE;

  IF v_bloqueado IS NOT NULL AND v_bloqueado > now() THEN
    RETURN jsonb_build_object(
      'success',            false,
      'error',              'bloqueado',
      'bloqueado_hasta',    v_bloqueado,
      'segundos_restantes', ceil(extract(epoch FROM (v_bloqueado - now())))::int
    );
  END IF;

  -- 1) Lockear la fila del codigo (si existe) para canjeo atomico.
  SELECT *
    INTO v_codigo_row
    FROM bot_codigos_vinculacion
   WHERE codigo = p_codigo
   FOR UPDATE;

  IF NOT FOUND THEN
    v_error := 'no_encontrado';
  ELSIF v_codigo_row.usado_at IS NOT NULL THEN
    v_error := 'ya_usado';
  ELSIF v_codigo_row.expira_at <= now() THEN
    v_error := 'expirado';
  ELSE
    -- 2) Leer perfil asociado y validar que este activo.
    SELECT id, rol, nombre, activo
      INTO v_perfil_id, v_perfil_rol, v_perfil_nombre, v_perfil_activo
      FROM perfiles
     WHERE id = v_codigo_row.perfil_id;

    IF NOT FOUND OR v_perfil_activo IS NOT TRUE THEN
      v_error := 'perfil_invalido';
    END IF;
  END IF;

  -- 3) Cualquier fallo cuenta, sea cual sea el motivo.
  IF v_error IS NOT NULL THEN
    INSERT INTO bot_intentos_vinculacion AS bi (
      telegram_user_id, fallidos, ventana_inicio_at, ultimo_intento_at
    ) VALUES (
      p_telegram_user_id, 1, now(), now()
    )
    ON CONFLICT (telegram_user_id) DO UPDATE
       SET fallidos = CASE WHEN bi.ventana_inicio_at > now() - c_ventana
                           THEN bi.fallidos + 1 ELSE 1 END,
           ventana_inicio_at = CASE WHEN bi.ventana_inicio_at > now() - c_ventana
                                    THEN bi.ventana_inicio_at ELSE now() END,
           -- Ventana nueva: el bloqueo viejo ya no cuenta.
           bloqueado_hasta = CASE WHEN bi.ventana_inicio_at > now() - c_ventana
                                  THEN bi.bloqueado_hasta ELSE NULL END,
           ultimo_intento_at = now()
    RETURNING bi.fallidos INTO v_fallidos;

    IF v_fallidos >= c_max_fallidos THEN
      UPDATE bot_intentos_vinculacion
         SET bloqueado_hasta = now() + c_lockout
       WHERE telegram_user_id = p_telegram_user_id;
    END IF;

    RETURN jsonb_build_object('success', false, 'error', v_error);
  END IF;

  -- 4) Sucursal default del perfil (puede ser NULL si no tiene asignacion).
  --    Es solo el punto de partida: de aca en mas la sucursal activa la
  --    resuelve bot_resolver_usuario() en cada mensaje.
  SELECT sucursal_id
    INTO v_sucursal_id
    FROM usuario_sucursales
   WHERE usuario_id = v_perfil_id
     AND es_default = true
   LIMIT 1;

  -- 5) Marcar el codigo como usado.
  UPDATE bot_codigos_vinculacion
     SET usado_at = now(),
         usado_por_telegram_id = p_telegram_user_id
   WHERE codigo = p_codigo;

  -- 6) UPSERT en bot_usuarios (soporta re-vinculacion del mismo chat a otro
  --    perfil). `rol` se escribe como historico de la vinculacion; quien
  --    decide permisos es bot_resolver_usuario(), que lee perfiles en vivo.
  INSERT INTO bot_usuarios (
    telegram_user_id, telegram_username, perfil_id, rol, sucursal_id, vinculado_at, activo
  ) VALUES (
    p_telegram_user_id, p_telegram_username, v_perfil_id, v_perfil_rol, v_sucursal_id, now(), true
  )
  ON CONFLICT (telegram_user_id) DO UPDATE
     SET telegram_username = EXCLUDED.telegram_username,
         perfil_id         = EXCLUDED.perfil_id,
         rol               = EXCLUDED.rol,
         sucursal_id       = EXCLUDED.sucursal_id,
         vinculado_at      = now(),
         activo            = true;

  -- 7) Vinculo bueno: el contador vuelve a cero.
  DELETE FROM bot_intentos_vinculacion WHERE telegram_user_id = p_telegram_user_id;

  RETURN jsonb_build_object(
    'success',     true,
    'perfil_id',   v_perfil_id,
    'rol',         v_perfil_rol,
    'sucursal_id', v_sucursal_id,
    'nombre',      v_perfil_nombre
  );
END;
$fn$;

COMMENT ON FUNCTION public.canjear_codigo_vinculacion_bot(TEXT, BIGINT, TEXT) IS
  'Canjea atomicamente un OTP de vinculacion del bot Telegram. Cuenta los fallos por telegram_user_id en bot_intentos_vinculacion: ventana de 15 minutos, al quinto fallo bloquea 15 minutos y a partir de ahi devuelve error=bloqueado con segundos_restantes sin mirar el codigo. Un canje exitoso borra el contador. Solo service_role. Errores: no_encontrado | expirado | ya_usado | perfil_invalido | bloqueado. mig 237 (contador) sobre la 014.';

-- -------------------------------------------------------------------------
-- 6 · bot_admin_listar_vinculados — el panel muestra el rol vivo
--
--     Era el otro lector de bot_usuarios.rol que decidia algo: un admin que
--     mira el panel para saber con que permisos entra alguien al bot veia el
--     rol del dia de la vinculacion. Ya hacia el LEFT JOIN a perfiles para el
--     nombre y el email; ahora el rol sale de ahi tambien.
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.bot_admin_listar_vinculados()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_rol TEXT;
  v_resultado JSON;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede listar usuarios vinculados al bot';
  END IF;

  SELECT COALESCE(
    json_agg(
      json_build_object(
        'telegram_user_id',   bu.telegram_user_id,
        'telegram_username',  bu.telegram_username,
        'perfil_id',          bu.perfil_id,
        'perfil_nombre',      p.nombre,
        'perfil_email',       p.email,
        -- Vivo, no el snapshot de bu.rol (mig 237).
        'rol',                p.rol,
        'sucursal_id',        bu.sucursal_id,
        'sucursal_nombre',    s.nombre,
        'vinculado_at',       bu.vinculado_at,
        'ultimo_uso_at',      bu.ultimo_uso_at,
        'activo',             bu.activo
      )
      ORDER BY bu.vinculado_at DESC
    ),
    '[]'::json
  )
  INTO v_resultado
  FROM bot_usuarios bu
  LEFT JOIN perfiles p   ON p.id = bu.perfil_id
  LEFT JOIN sucursales s ON s.id = bu.sucursal_id;

  RETURN v_resultado;
END;
$fn$;

COMMENT ON FUNCTION public.bot_admin_listar_vinculados() IS
  'Lista usuarios vinculados al bot Telegram con datos del perfil y sucursal. El rol que devuelve es el VIVO de perfiles, no el snapshot de bot_usuarios.rol (mig 237). Solo admin (auth.uid() debe tener perfiles.rol = admin). Retorna JSON array ordenado por vinculado_at DESC.';

-- -------------------------------------------------------------------------
-- 7 · Los OTP de 6 caracteres que estuvieran vivos no sirven mas
--
--     El bot nuevo pide 8. Dejarlos abiertos es hacerle gastar un intento del
--     lockout a alguien con un codigo que nunca iba a entrar.
-- -------------------------------------------------------------------------

UPDATE bot_codigos_vinculacion
   SET usado_at = now()
 WHERE usado_at IS NULL
   AND length(codigo) <> 8;

-- -------------------------------------------------------------------------
-- 8 · Permisos. Una funcion nueva de `public` nace con EXECUTE para PUBLIC y
--     Supabase ademas se lo concede a `anon` y a `authenticated` por default
--     privileges: hay que revocar las tres mitades. Las dos `bot_*` que solo
--     llama la edge function con la service_role key no le dejan nada a
--     `authenticated` -- lo midio la verificacion de abajo, que en la primera
--     corrida de esta migracion salio roja justo por esto.
-- -------------------------------------------------------------------------

REVOKE ALL    ON FUNCTION public.bot_resolver_usuario(BIGINT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_resolver_usuario(BIGINT) TO service_role;

REVOKE ALL    ON FUNCTION public.canjear_codigo_vinculacion_bot(TEXT, BIGINT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.canjear_codigo_vinculacion_bot(TEXT, BIGINT, TEXT) TO service_role;

REVOKE ALL    ON FUNCTION public.generar_codigo_vinculacion_bot() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generar_codigo_vinculacion_bot() TO authenticated;

REVOKE ALL    ON FUNCTION public.bot_admin_listar_vinculados() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_listar_vinculados() TO authenticated;

-- -------------------------------------------------------------------------
-- 9 · Verificacion estatica: ACLs, firma unica y RLS de la tabla nueva.
-- -------------------------------------------------------------------------

DO $verif$
DECLARE
  v_acl    text;
  v_n      int;
  v_fallas text := '';
  r        record;
BEGIN
  FOR r IN
    SELECT unnest(ARRAY[
      'bot_resolver_usuario',
      'canjear_codigo_vinculacion_bot',
      'generar_codigo_vinculacion_bot',
      'bot_admin_listar_vinculados'
    ]) AS fn
  LOOP
    SELECT count(*) INTO v_n
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = r.fn;

    -- Dos sobrecargas con rangos [obligatorios, total] superpuestos hacen que
    -- PostgREST tire PGRST203 en runtime, invisible para tsc y para los tests.
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format(' [%s quedo con %s firmas]', r.fn, v_n);
      CONTINUE;
    END IF;

    SELECT array_to_string(proacl, ',') INTO v_acl
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = r.fn;

    IF v_acl IS NULL THEN
      v_fallas := v_fallas || format(' [%s quedo con ACL default (PUBLIC ejecuta)]', r.fn);
    ELSIF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      v_fallas := v_fallas || format(' [%s quedo ejecutable por PUBLIC: %s]', r.fn, v_acl);
    ELSIF v_acl LIKE '%anon=%' THEN
      v_fallas := v_fallas || format(' [%s quedo ejecutable por anon: %s]', r.fn, v_acl);
    END IF;
  END LOOP;

  -- Las dos que solo llama el bot con la service_role key: de nadie mas.
  FOR r IN
    SELECT unnest(ARRAY['bot_resolver_usuario', 'canjear_codigo_vinculacion_bot']) AS fn
  LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = r.fn;
    IF v_acl NOT LIKE '%service_role=X%' THEN
      v_fallas := v_fallas || format(' [%s no quedo ejecutable por service_role: %s]', r.fn, v_acl);
    END IF;
    IF v_acl LIKE '%authenticated=X%' THEN
      v_fallas := v_fallas || format(' [%s quedo ejecutable por authenticated: %s]', r.fn, v_acl);
    END IF;
  END LOOP;

  -- La tabla del contador tiene que nacer con RLS y sin policies.
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'bot_intentos_vinculacion' AND c.relrowsecurity
  ) THEN
    v_fallas := v_fallas || ' [bot_intentos_vinculacion quedo sin RLS]';
  END IF;
  SELECT count(*) INTO v_n FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'bot_intentos_vinculacion';
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format(' [bot_intentos_vinculacion quedo con %s policies]', v_n);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig237 · verificacion estatica encontro:%', v_fallas;
  END IF;

  RAISE NOTICE 'mig237 · verificacion estatica OK.';
END
$verif$;


-- -------------------------------------------------------------------------
-- 10 · ENSAYO FUNCIONAL, contra las funciones que se acaban de escribir.
--
--      Corre adentro de una subtransaccion que se revierte SIEMPRE: vincula dos
--      chats inventados (telegram_user_id negativo, que Telegram no usa) a
--      perfiles reales y quema seis intentos de canje. No deja una sola fila.
--      Las variables de plpgsql no son transaccionales, asi que lo medido
--      sobrevive al rollback.
--
--      Para el perfil dado de baja usa uno que YA este inactivo si lo hay --
--      tocar `perfiles.activo` dispara `perfiles_sync_acceso_auth` (206), que
--      banea al usuario y le borra las sesiones; se revierte con el rollback,
--      pero no hace falta pasar por ahi si la base ya tiene un caso real.
--
--      Es la prueba de aceptacion de la migracion: un perfil con activo=false
--      no resuelve usuario, y el sexto intento fallido devuelve bloqueado.
-- -------------------------------------------------------------------------

DO $ensayo$
DECLARE
  c_chat     CONSTANT bigint := -987654321;
  c_chat_off CONSTANT bigint := -987654322;
  v_uid     uuid;
  v_rol     text;
  v_uid_off uuid;
  v_flip    boolean := false;
  v_suc_ajena bigint;
  v_fallas  text := '';
  v_notas   text := '';
  -- lo que se mide adentro de la subtransaccion
  v_res_ok       jsonb;
  v_res_inactivo jsonb;
  v_res_botoff   jsonb;
  v_res_suc      jsonb;
  v_canjes       text[] := '{}';
  v_codigo       text;
  v_i            int;
BEGIN
  -- Un perfil activo, prefiriendo uno que no sea admin: si hubiera que darlo de
  -- baja, `perfiles_guard_desactivacion` (206) frena al ultimo admin activo.
  SELECT p.id, p.rol INTO v_uid, v_rol
    FROM perfiles p
   WHERE p.activo IS TRUE
   ORDER BY (p.rol = 'admin'), p.id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig237: no hay ningun perfil activo; el ensayo no puede correr.';
  END IF;

  -- Uno dado de baja de verdad, si existe.
  SELECT p.id INTO v_uid_off
    FROM perfiles p
   WHERE p.activo IS NOT TRUE
   ORDER BY p.id
   LIMIT 1;

  IF v_uid_off IS NULL THEN
    v_uid_off := v_uid;
    v_flip    := true;
  END IF;

  BEGIN
    -- Snapshot del rol DISTINTO del vivo a proposito: si el resolver devolviera
    -- el snapshot en vez de perfiles.rol, se ve en el resultado.
    INSERT INTO bot_usuarios (telegram_user_id, telegram_username, perfil_id, rol, sucursal_id, activo)
    VALUES (c_chat, 'ensayo_mig237', v_uid,
            CASE WHEN v_rol = 'deposito' THEN 'transportista' ELSE 'deposito' END,
            NULL, true);

    -- A · resuelve, y el rol que devuelve es el de perfiles, no el snapshot.
    v_res_ok := bot_resolver_usuario(c_chat);

    -- B · un perfil dado de baja en la app no resuelve por Telegram.
    IF v_flip THEN
      UPDATE perfiles SET activo = false WHERE id = v_uid_off;
    END IF;
    INSERT INTO bot_usuarios (telegram_user_id, telegram_username, perfil_id, rol, sucursal_id, activo)
    VALUES (c_chat_off, 'ensayo_mig237_off', v_uid_off, 'preventista', NULL, true)
    ON CONFLICT (telegram_user_id) DO NOTHING;
    v_res_inactivo := bot_resolver_usuario(c_chat_off);
    IF v_flip THEN
      UPDATE perfiles SET activo = true WHERE id = v_uid_off;
    END IF;

    -- C · el interruptor propio del bot sigue cortando.
    UPDATE bot_usuarios SET activo = false WHERE telegram_user_id = c_chat;
    v_res_botoff := bot_resolver_usuario(c_chat);
    UPDATE bot_usuarios SET activo = true WHERE telegram_user_id = c_chat;

    -- D · un override de sucursal que el perfil no tiene cae a la default.
    --     Tiene que ser una sucursal que exista (hay FK); si el perfil las
    --     tiene todas, queda NULL y se prueba el mismo fallback.
    SELECT s.id INTO v_suc_ajena
      FROM sucursales s
     WHERE NOT EXISTS (
             SELECT 1 FROM usuario_sucursales us
              WHERE us.usuario_id = v_uid AND us.sucursal_id = s.id
           )
     ORDER BY s.id
     LIMIT 1;
    UPDATE bot_usuarios SET sucursal_id = v_suc_ajena WHERE telegram_user_id = c_chat;
    v_res_suc := bot_resolver_usuario(c_chat);

    -- E · seis canjes fallidos seguidos: los cinco primeros con su error, el
    --     sexto bloqueado sin llegar a mirar el codigo.
    FOR v_i IN 1 .. 6 LOOP
      v_canjes := v_canjes || (
        canjear_codigo_vinculacion_bot('ZZZZZZZZ', c_chat, 'ensayo')->>'error'
      );
    END LOOP;

    -- F · el OTP nuevo: 8 caracteres del alfabeto de 32.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_codigo := generar_codigo_vinculacion_bot()->>'codigo';

    RAISE EXCEPTION 'mig237_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig237_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig237 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  -- A
  IF (v_res_ok->>'ok') IS DISTINCT FROM 'true' THEN
    v_fallas := v_fallas || format(' [A: no resolvio un vinculo sano: %s]', v_res_ok);
  END IF;
  IF (v_res_ok->>'rol') IS DISTINCT FROM v_rol THEN
    v_fallas := v_fallas || format(' [A: devolvio el rol %s (el snapshot) en vez del vivo %s]',
                                   v_res_ok->>'rol', v_rol);
  END IF;
  -- B
  IF (v_res_inactivo->>'ok') IS DISTINCT FROM 'false'
     OR (v_res_inactivo->>'motivo') IS DISTINCT FROM 'perfil_inactivo' THEN
    v_fallas := v_fallas || format(' [B: un perfil con activo=false siguio resolviendo: %s]', v_res_inactivo);
  END IF;
  -- C
  IF (v_res_botoff->>'motivo') IS DISTINCT FROM 'bot_desactivado' THEN
    v_fallas := v_fallas || format(' [C: bot_usuarios.activo=false no corto: %s]', v_res_botoff);
  END IF;
  -- D
  IF (v_res_suc->>'sucursal_id') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                      WHERE us.usuario_id = v_uid
                        AND us.sucursal_id = (v_res_suc->>'sucursal_id')::bigint) THEN
    v_fallas := v_fallas || format(' [D: devolvio una sucursal que el perfil no tiene: %s]', v_res_suc);
  END IF;
  IF v_suc_ajena IS NOT NULL
     AND (v_res_suc->>'sucursal_id')::bigint IS NOT DISTINCT FROM v_suc_ajena THEN
    v_fallas := v_fallas || format(' [D: se quedo con el override ajeno %s en vez de caer a la default]', v_suc_ajena);
  END IF;
  -- E
  FOR v_i IN 1 .. 5 LOOP
    IF v_canjes[v_i] IS DISTINCT FROM 'no_encontrado' THEN
      v_fallas := v_fallas || format(' [E: el intento %s devolvio %s en vez de no_encontrado]', v_i, v_canjes[v_i]);
    END IF;
  END LOOP;
  IF v_canjes[6] IS DISTINCT FROM 'bloqueado' THEN
    v_fallas := v_fallas || format(' [E: el sexto intento devolvio %s en vez de bloqueado]', v_canjes[6]);
  END IF;
  -- F
  IF v_codigo !~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$' THEN
    v_fallas := v_fallas || format(' [F: el OTP quedo como "%s" y tenia que ser 8 chars del alfabeto de 32]', v_codigo);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig237 · el ensayo funcional encontro:%', v_fallas;
  END IF;

  v_notas := format('A rol_vivo=%s · B %s · C %s · D sucursal=%s · E %s · F otp=%s',
                    v_res_ok->>'rol', v_res_inactivo->>'motivo', v_res_botoff->>'motivo',
                    COALESCE(v_res_suc->>'sucursal_id', 'null'),
                    array_to_string(v_canjes, ','), v_codigo);
  RAISE NOTICE 'mig237 · ensayo funcional OK: %', v_notas;
END
$ensayo$;

COMMIT;
