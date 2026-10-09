-- =============================================================================
-- 325 · Cada admin gestiona lo suyo y el aviso semanal de atrasados
-- =============================================================================
--
-- Pedido del dueño (2026-10-09):
--
-- 1. PERMISOS DEL PANEL. Hasta acá cualquier admin veía y editaba el resumen
--    de TODOS los admins y preventistas. Ahora cada admin gestiona su propio
--    resumen y el de los preventistas de SUS sucursales (las de
--    usuario_sucursales). No ve ni toca el de otro admin. El gate es una
--    función, `bot_admin_puede_gestionar`, que usan el listado y los dos
--    guardados.
--
-- 2. AVISO SEMANAL DE CLIENTES ATRASADOS. El gerente: "quién dejó de comprar"
--    es un dato que el preventista no sale a consultar; hay que empujárselo.
--    Un mensaje aparte del resumen diario, sin IA (la lista de
--    bot_clientes_atrasados con un botón por cliente), con su propio día y
--    hora. ACTIVADO POR DEFECTO para todo preventista vinculado: lunes 8:00.
--    Se apaga o se cambia desde el panel. Las columnas viven en
--    bot_digest_config (una fila por persona) y NULL significa "el default".
--
--    OJO con la fila nueva: guardar el aviso de un preventista sin fila crea
--    una, y los defaults de la tabla son los del ADMIN (activo = true y sus
--    secciones). El guardado del aviso inserta el resumen diario APAGADO y
--    con las secciones del preventista, para no prenderle por la espalda un
--    resumen que nadie pidió.
-- =============================================================================

BEGIN;

-- 0 · Premisas: el cuerpo que se reemplaza es el vigente (md5 del 2026-10-09).
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.bot_admin_listar_config_digest()',                                  '8e6dff3c4571e93c27fac29a8f84bb27'),
        ('public.bot_admin_guardar_config_digest(uuid,boolean,integer,integer[],text[])', 'a2bff9551087720bca572deb71be6797')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION '325 · % cambió en prod desde que se copió (md5 %, esperado %)', v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;


-- ---------------------------------------------------------------------------
-- 1 · Columnas del aviso semanal
-- ---------------------------------------------------------------------------
ALTER TABLE public.bot_digest_config
  -- NULL = el default del rol: un preventista lo recibe, un admin no.
  ADD COLUMN IF NOT EXISTS aviso_atrasados_activo BOOLEAN,
  -- NULL = 8.
  ADD COLUMN IF NOT EXISTS aviso_atrasados_hora   SMALLINT,
  -- NULL = lunes. ISO: 1 = lunes … 7 = domingo.
  ADD COLUMN IF NOT EXISTS aviso_atrasados_dias   SMALLINT[];

ALTER TABLE public.bot_digest_config
  ADD CONSTRAINT bot_digest_config_aviso_hora_ck
    CHECK (aviso_atrasados_hora IS NULL OR aviso_atrasados_hora BETWEEN 0 AND 23),
  ADD CONSTRAINT bot_digest_config_aviso_dias_ck
    CHECK (aviso_atrasados_dias IS NULL OR (
      array_length(aviso_atrasados_dias, 1) BETWEEN 1 AND 7
      AND aviso_atrasados_dias <@ ARRAY[1,2,3,4,5,6,7]::SMALLINT[]));

-- Idempotencia del aviso: uno por persona y por día.
CREATE TABLE IF NOT EXISTS public.bot_avisos_atrasados_enviados (
  perfil_id        UUID NOT NULL REFERENCES public.perfiles(id) ON DELETE CASCADE,
  fecha            DATE NOT NULL,
  telegram_user_id BIGINT NOT NULL,
  status           TEXT NOT NULL CHECK (status IN ('ok', 'error', 'skipped')),
  error_meta       JSONB,
  sent_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (perfil_id, fecha)
);
ALTER TABLE public.bot_avisos_atrasados_enviados ENABLE ROW LEVEL SECURITY;
-- Sin políticas: la escribe la edge function con service_role.


-- ---------------------------------------------------------------------------
-- 2 · Quién puede gestionar a quién
-- ---------------------------------------------------------------------------
-- Un admin gestiona su propio resumen y el de los preventistas con los que
-- comparte alguna sucursal. Nada más: ni el de otro admin.
CREATE OR REPLACE FUNCTION public.bot_admin_puede_gestionar(p_admin UUID, p_perfil UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM perfiles a WHERE a.id = p_admin AND a.rol = 'admin' AND a.activo)
     AND (
       p_perfil = p_admin
       OR EXISTS (
         SELECT 1
           FROM perfiles pv
           JOIN usuario_sucursales us_p ON us_p.usuario_id = pv.id
           JOIN usuario_sucursales us_a ON us_a.usuario_id = p_admin AND us_a.sucursal_id = us_p.sucursal_id
          WHERE pv.id = p_perfil AND pv.rol = 'preventista' AND pv.activo
       )
     );
$function$;

COMMENT ON FUNCTION public.bot_admin_puede_gestionar(UUID, UUID) IS
  'Gate del panel del bot: un admin gestiona su propio resumen y el de los preventistas de sus sucursales (mig 325).';

REVOKE EXECUTE ON FUNCTION public.bot_admin_puede_gestionar(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_admin_puede_gestionar(UUID, UUID) TO service_role;


-- ---------------------------------------------------------------------------
-- 3 · Listado del panel: lo propio y los preventistas de sus sucursales
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_admin_listar_config_digest()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_rol       TEXT;
  v_resultado JSON;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede ver la configuración del digest';
  END IF;

  SELECT COALESCE(
    json_agg(
      json_build_object(
        'perfil_id',        bu.perfil_id,
        'perfil_nombre',    p.nombre,
        'rol',              p.rol,
        -- La fila del propio admin: el panel la muestra primero y la rotula "Vos".
        'es_propio',        (bu.perfil_id = auth.uid()),
        'telegram_user_id', bu.telegram_user_id,
        'sucursal_id',      bu.sucursal_id,
        'sucursal_nombre',  s.nombre,
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
      ORDER BY (bu.perfil_id <> auth.uid()), (p.rol <> 'admin'), p.nombre
    ),
    '[]'::json
  )
  INTO v_resultado
  FROM bot_usuarios bu
  JOIN perfiles p               ON p.id = bu.perfil_id
  LEFT JOIN sucursales s        ON s.id = bu.sucursal_id
  LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
  LEFT JOIN perfiles ap         ON ap.id = c.actualizado_por
  WHERE bu.activo AND p.activo AND p.rol IN ('admin', 'preventista')
    AND bot_admin_puede_gestionar(auth.uid(), bu.perfil_id);

  RETURN v_resultado;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- 4 · Guardar el resumen diario: con el mismo gate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_admin_guardar_config_digest(
  p_perfil_id  uuid,
  p_activo     boolean,
  p_hora_local integer,
  p_dias       integer[],
  p_secciones  text[]
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rol         TEXT;
  v_rol_destino TEXT;
  v_ajenas      TEXT[];
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede configurar el digest';
  END IF;
  -- Su propio resumen o el de un preventista de sus sucursales (mig 325).
  IF NOT bot_admin_puede_gestionar(auth.uid(), p_perfil_id) THEN
    RAISE EXCEPTION 'Sólo podés configurar tu propio resumen y el de los preventistas de tus sucursales';
  END IF;

  -- El destinatario tiene que ser un admin o un preventista vinculado al bot.
  SELECT p.rol INTO v_rol_destino
    FROM bot_usuarios bu
    JOIN perfiles p ON p.id = bu.perfil_id
   WHERE bu.perfil_id = p_perfil_id AND bu.activo AND p.activo
     AND p.rol IN ('admin', 'preventista')
     -- Mismo filtro que bot_digest_destinatarios: un preventista sin sucursal
     -- activa no recibe nada, y el panel no puede decir "Recibe" por el.
     AND (p.rol = 'admin' OR bu.sucursal_id IS NOT NULL)
   LIMIT 1;
  IF v_rol_destino IS NULL THEN
    RAISE EXCEPTION 'El perfil % no es un admin ni un preventista vinculado al bot con sucursal activa', p_perfil_id;
  END IF;

  SELECT array_agg(s ORDER BY s) INTO v_ajenas
    FROM unnest(p_secciones) s
   WHERE NOT (s = ANY (digest_secciones_del_rol(v_rol_destino)));
  IF v_ajenas IS NOT NULL THEN
    RAISE EXCEPTION 'Secciones que no corresponden al rol %: %', v_rol_destino, array_to_string(v_ajenas, ', ');
  END IF;

  INSERT INTO bot_digest_config (
    perfil_id, activo, hora_local, dias_semana, secciones,
    actualizado_at, actualizado_por
  )
  VALUES (
    p_perfil_id, p_activo, p_hora_local::SMALLINT, p_dias::SMALLINT[], p_secciones,
    now(), auth.uid()
  )
  ON CONFLICT (perfil_id) DO UPDATE SET
    activo          = EXCLUDED.activo,
    hora_local      = EXCLUDED.hora_local,
    dias_semana     = EXCLUDED.dias_semana,
    secciones       = EXCLUDED.secciones,
    actualizado_at  = now(),
    actualizado_por = auth.uid();

  RETURN json_build_object('success', true, 'perfil_id', p_perfil_id);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 5 · Guardar el aviso semanal (sólo preventistas)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_admin_guardar_aviso_atrasados(
  p_perfil_id UUID,
  p_activo    BOOLEAN,
  p_hora      INTEGER,
  p_dias      INTEGER[]
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rol TEXT;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede configurar el aviso de atrasados';
  END IF;
  IF NOT bot_admin_puede_gestionar(auth.uid(), p_perfil_id) THEN
    RAISE EXCEPTION 'Sólo podés configurar a los preventistas de tus sucursales';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM bot_usuarios bu JOIN perfiles p ON p.id = bu.perfil_id
     WHERE bu.perfil_id = p_perfil_id AND bu.activo AND p.activo AND p.rol = 'preventista'
  ) THEN
    RAISE EXCEPTION 'El aviso de atrasados es para preventistas vinculados al bot';
  END IF;

  -- Sin fila previa, el resumen diario nace APAGADO y con las secciones del
  -- preventista: los defaults de la tabla son los del admin.
  INSERT INTO bot_digest_config (
    perfil_id, activo, secciones,
    aviso_atrasados_activo, aviso_atrasados_hora, aviso_atrasados_dias,
    actualizado_at, actualizado_por
  )
  VALUES (
    p_perfil_id, FALSE, digest_secciones_default('preventista'),
    p_activo, p_hora::SMALLINT, p_dias::SMALLINT[],
    now(), auth.uid()
  )
  ON CONFLICT (perfil_id) DO UPDATE SET
    aviso_atrasados_activo = EXCLUDED.aviso_atrasados_activo,
    aviso_atrasados_hora   = EXCLUDED.aviso_atrasados_hora,
    aviso_atrasados_dias   = EXCLUDED.aviso_atrasados_dias,
    actualizado_at         = now(),
    actualizado_por        = auth.uid();

  RETURN json_build_object('success', true, 'perfil_id', p_perfil_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.bot_admin_guardar_aviso_atrasados(UUID, BOOLEAN, INTEGER, INTEGER[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_guardar_aviso_atrasados(UUID, BOOLEAN, INTEGER, INTEGER[]) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_admin_listar_config_digest() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_listar_config_digest() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_admin_guardar_config_digest(uuid, boolean, integer, integer[], text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_guardar_config_digest(uuid, boolean, integer, integer[], text[]) TO authenticated;


-- ---------------------------------------------------------------------------
-- 6 · A quién le toca el aviso en esta hora
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_aviso_atrasados_destinatarios(p_hora integer, p_dow integer)
RETURNS json
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(json_agg(json_build_object(
           'telegram_user_id', bu.telegram_user_id,
           'perfil_id',        bu.perfil_id,
           'sucursal_id',      bu.sucursal_id
         ) ORDER BY bu.telegram_user_id), '[]'::json)
    FROM bot_usuarios bu
    JOIN perfiles p ON p.id = bu.perfil_id
    LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
   WHERE bu.activo AND p.activo AND p.rol = 'preventista'
     AND bu.sucursal_id IS NOT NULL
     -- Activado por defecto (decisión del dueño, 2026-10-09).
     AND COALESCE(c.aviso_atrasados_activo, TRUE)
     AND COALESCE(c.aviso_atrasados_hora, 8) = p_hora::SMALLINT
     AND p_dow::SMALLINT = ANY (COALESCE(c.aviso_atrasados_dias, ARRAY[1]::SMALLINT[]));
$function$;

REVOKE EXECUTE ON FUNCTION public.bot_aviso_atrasados_destinatarios(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_aviso_atrasados_destinatarios(integer, integer) TO service_role;


-- ---------------------------------------------------------------------------
-- 7 · Ensayo
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin1  uuid;  -- admin con una sola sucursal
  v_suc1    bigint;
  v_admin2  uuid;  -- otro admin
  v_prev_in uuid;  -- preventista de la sucursal de admin1
  v_prev_out uuid; -- preventista de otra sucursal (sin compartir con admin1)
  v_n       int;
  v_j       json;
BEGIN
  SELECT a.id, us.sucursal_id INTO v_admin1, v_suc1
    FROM perfiles a JOIN usuario_sucursales us ON us.usuario_id = a.id
   WHERE a.rol = 'admin' AND a.activo
     AND (SELECT count(*) FROM usuario_sucursales x WHERE x.usuario_id = a.id) = 1
   LIMIT 1;
  SELECT a.id INTO v_admin2 FROM perfiles a WHERE a.rol = 'admin' AND a.activo AND a.id <> v_admin1 LIMIT 1;
  SELECT p.id INTO v_prev_in FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id
   WHERE p.rol = 'preventista' AND p.activo AND us.sucursal_id = v_suc1
     AND NOT EXISTS (SELECT 1 FROM bot_usuarios bu WHERE bu.perfil_id = p.id) LIMIT 1;
  SELECT p.id INTO v_prev_out FROM perfiles p
   WHERE p.rol = 'preventista' AND p.activo
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = v_suc1)
     AND NOT EXISTS (SELECT 1 FROM bot_usuarios bu WHERE bu.perfil_id = p.id) LIMIT 1;

  IF v_admin1 IS NULL OR v_prev_in IS NULL THEN
    RAISE NOTICE 'ensayo 325: sin datos para el ensayo de permisos';
    RETURN;
  END IF;

  -- 7a. El gate.
  IF NOT bot_admin_puede_gestionar(v_admin1, v_admin1) THEN
    RAISE EXCEPTION 'ensayo 325: un admin no puede gestionarse a sí mismo';
  END IF;
  IF v_admin2 IS NOT NULL AND bot_admin_puede_gestionar(v_admin1, v_admin2) THEN
    RAISE EXCEPTION 'ensayo 325: un admin gestiona a otro admin';
  END IF;
  IF NOT bot_admin_puede_gestionar(v_admin1, v_prev_in) THEN
    RAISE EXCEPTION 'ensayo 325: un admin no gestiona a un preventista de su sucursal';
  END IF;
  IF v_prev_out IS NOT NULL AND bot_admin_puede_gestionar(v_admin1, v_prev_out) THEN
    RAISE EXCEPTION 'ensayo 325: un admin gestiona a un preventista de otra sucursal';
  END IF;
  IF bot_admin_puede_gestionar(v_prev_in, v_prev_in) THEN
    RAISE EXCEPTION 'ensayo 325: un preventista pasa el gate de admin';
  END IF;

  -- 7b. Con preventistas vinculados de mentira (se deshace al final).
  BEGIN
    INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo)
    VALUES (-3001, v_prev_in, 'preventista', v_suc1, true);
    IF v_prev_out IS NOT NULL THEN
      INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo)
      VALUES (-3002, v_prev_out, 'preventista',
              (SELECT us.sucursal_id FROM usuario_sucursales us WHERE us.usuario_id = v_prev_out LIMIT 1), true);
    END IF;

    -- Activado por defecto: el lunes a las 8 le toca; el martes no; a otra hora no.
    IF NOT EXISTS (SELECT 1 FROM json_array_elements(bot_aviso_atrasados_destinatarios(8, 1)) d
                    WHERE (d ->> 'perfil_id')::uuid = v_prev_in) THEN
      RAISE EXCEPTION 'ensayo 325: el aviso no le llega por defecto el lunes a las 8';
    END IF;
    IF EXISTS (SELECT 1 FROM json_array_elements(bot_aviso_atrasados_destinatarios(8, 2)) d
                WHERE (d ->> 'perfil_id')::uuid = v_prev_in)
       OR EXISTS (SELECT 1 FROM json_array_elements(bot_aviso_atrasados_destinatarios(9, 1)) d
                   WHERE (d ->> 'perfil_id')::uuid = v_prev_in) THEN
      RAISE EXCEPTION 'ensayo 325: el aviso llega fuera del lunes a las 8';
    END IF;

    -- El listado de admin1: él y su preventista; nunca otro admin ni el de afuera.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin1)::text, true);
    v_j := bot_admin_listar_config_digest();
    IF NOT EXISTS (SELECT 1 FROM json_array_elements(v_j) l WHERE (l ->> 'perfil_id')::uuid = v_prev_in
                     AND (l -> 'aviso_atrasados' ->> 'activo')::boolean) THEN
      RAISE EXCEPTION 'ensayo 325: el panel no muestra al preventista de su sucursal con el aviso activo';
    END IF;
    IF EXISTS (SELECT 1 FROM json_array_elements(v_j) l
                WHERE (l ->> 'rol') = 'admin' AND (l ->> 'perfil_id')::uuid <> v_admin1)
       OR (v_prev_out IS NOT NULL AND EXISTS (SELECT 1 FROM json_array_elements(v_j) l
                WHERE (l ->> 'perfil_id')::uuid = v_prev_out)) THEN
      RAISE EXCEPTION 'ensayo 325: el panel de un admin muestra a quien no gestiona';
    END IF;

    -- Guardar el aviso de su preventista: crea la fila con el resumen diario APAGADO.
    PERFORM bot_admin_guardar_aviso_atrasados(v_prev_in, true, 9, ARRAY[1, 4]);
    SELECT count(*) INTO v_n FROM bot_digest_config
     WHERE perfil_id = v_prev_in AND activo = false AND aviso_atrasados_hora = 9
       AND secciones = digest_secciones_default('preventista');
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'ensayo 325: guardar el aviso le prendió el resumen diario o no guardó';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM json_array_elements(bot_aviso_atrasados_destinatarios(9, 4)) d
                    WHERE (d ->> 'perfil_id')::uuid = v_prev_in) THEN
      RAISE EXCEPTION 'ensayo 325: el aviso no sigue el día y la hora guardados';
    END IF;
    IF EXISTS (SELECT 1 FROM json_array_elements(bot_digest_destinatarios(7, 1)) d
                WHERE (d ->> 'perfil_id')::uuid = v_prev_in) THEN
      RAISE EXCEPTION 'ensayo 325: al preventista le llega el resumen diario sin pedirlo';
    END IF;

    -- Ni el aviso ni el resumen de alguien que no gestiona.
    IF v_prev_out IS NOT NULL THEN
      BEGIN
        PERFORM bot_admin_guardar_aviso_atrasados(v_prev_out, false, 8, ARRAY[1]);
        RAISE EXCEPTION 'ensayo 325: guardó el aviso de un preventista de otra sucursal';
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'ensayo 325%' THEN RAISE; END IF;
      END;
    END IF;
    IF v_admin2 IS NOT NULL THEN
      BEGIN
        PERFORM bot_admin_guardar_config_digest(v_admin2, false, 7, ARRAY[1], ARRAY['ventas']);
        RAISE EXCEPTION 'ensayo 325: un admin le cambió el resumen a otro admin';
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'ensayo 325%' THEN RAISE; END IF;
      END;
    END IF;

    RAISE EXCEPTION 'ensayo325_deshacer';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'ensayo325_deshacer' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'ensayo 325: permisos, aviso por defecto y guardado OK';
END;
$ensayo$;

COMMIT;
