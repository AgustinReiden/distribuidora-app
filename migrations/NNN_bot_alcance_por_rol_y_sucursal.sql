-- =========================================================================
-- NNN · EL BOT RESPETA EL ALCANCE QUE EL USUARIO TIENE EN LA APP
--       (auditoría de lo ajeno al núcleo del 12/11: B-1 a B-4 de #1552)
--
-- Agrega una columna y un trigger a `bot_audit_log`, reemplaza el cuerpo
-- entero de seis funciones y parcha por ancla otras dos, con premisa de md5
-- sobre el cuerpo vivo leído el 12/11 y poscondición de md5, ACL y definer.
-- Ninguna firma cambia: las RPC nuevas andan con el TypeScript viejo y el
-- TypeScript nuevo, con las RPC viejas.
-- Ensayo: scripts/test-bot-alcance-1552.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · B-4 · EL REGISTRO DEL BOT SE FILTRA POR LA SUCURSAL DEL EVENTO
-- =========================================================================
-- `bot_admin_audit_log` y `bot_admin_audit_summary` (#1244) mostraban un evento
-- si el admin compartía ALGUNA sucursal con el usuario que lo generó. Un admin
-- de A y B parado en B con /sucursal preguntaba "cuánto nos deben" y el admin
-- sólo de A leía la pregunta y la respuesta, con la plata de B.
--
-- Ahora cada fila guarda su sucursal (`bot_audit_log.sucursal_id`) y el admin
-- ve las de sus sucursales. La pone un trigger y no la edge function, para
-- que valga con cualquier versión desplegada del bot:
--   · la que el evento declara en `resultado_meta.sucursal_id` (el resumen
--     diario es de una sucursal, que no tiene por qué ser la activa del chat);
--   · si no declara ninguna, la sucursal activa del chat en ese momento, la de
--     `bot_resolver_usuario`, que es con la que el bot contestó.
-- Sin FK a `sucursales`: el log es fail-closed en la edge function y una id
-- rara no puede tirar el INSERT; una id que no es de nadie sólo esconde la
-- fila.
--
-- Las filas de antes no tienen sucursal (salvo las del resumen, que la traen
-- en el meta y se completan acá). Se ven sólo si el admin tiene TODAS las
-- sucursales del usuario (el criterio de `admin_abarca_sucursales_de`): con
-- una sola sucursal da lo mismo que antes; con varias, nadie sabe de cuál era.
--
-- B-9 (bajo): antes cada fila llamaba a `admin_comparte_sucursal_con`. Ahora
-- las sucursales del admin y los usuarios que abarca se calculan una vez y la
-- fila se compara contra dos arrays.
--
-- =========================================================================
-- 2 · B-1 · EL DEPÓSITO NO LEE CLIENTES POR EL BOT
-- =========================================================================
-- En la app `mt_clientes_select` deja al depósito en 0 clientes. Por el bot,
-- `bot_buscar_cliente` con p_rol 'deposito' caía en la rama de los huérfanos y
-- devolvía saldo y dirección. Las RPC de cliente que reciben el rol ahora sólo
-- atienden a admin, encargado, preventista y transportista (el transportista
-- ve clientes en la app y `saldo.ts` lo admite a propósito): un rol que no es
-- ninguno de esos, el depósito incluido, no ve ninguno.
--   · `bot_buscar_cliente`: no devuelve filas.
--   · `bot_productos_recurrentes_cliente` (y con ella
--     `bot_resumen_cliente_visita`, que la usa de gate y devolvía saldo, límite,
--     teléfono y dirección) y `bot_productos_dejados_cliente`: devuelven el
--     error "Tu rol no tiene acceso a clientes", con la forma de sus otros
--     rechazos.
-- La otra capa es la edge function: `buscar_cliente` y `ficha_cliente` ya no
-- aceptan al depósito y `/cliente` es de los cuatro roles.
-- `bot_historico_pedidos_cliente` no se toca acá (está en #1522, PAT-5-1):
-- para quien no es admin ni encargado ya muestra sólo los pedidos que cargó o
-- reparte, y el depósito no carga ni reparte.
--
-- =========================================================================
-- 3 · B-2 · EL RESUMEN DEL RECORRIDO SIN FECHA ES EL DE HOY
-- =========================================================================
-- PostgREST pasa el `p_fecha: null` tal cual y no aplica el DEFAULT:
-- `r.fecha = NULL` no encontraba nada y el chofer leía "No tenés recorrido
-- cargado para hoy". NULL ahora es hoy, el día argentino (`_tablero_hoy()`),
-- en `bot_recorrido_resumen` y en `bot_mi_recorrido`.
--
-- =========================================================================
-- 4 · B-3 · EL AVISO DE ATRASADOS VA A LAS SUCURSALES VIVAS
-- =========================================================================
-- `bot_aviso_atrasados_destinatarios` leía `bot_usuarios.sucursal_id`, la foto
-- del día en que se vinculó: al preventista que pasó de A a B le seguía
-- llegando la lista de A. Ahora sale como el resumen diario
-- (`bot_digest_suscripciones`): una fila por cada sucursal ACTIVA que tiene
-- asignada en `usuario_sucursales`, con el último chat vinculado, y sin
-- sucursal no hay aviso. El rol y el alta son los de `perfiles` y el chat,
-- prendido (`bu.activo`: el apagado por un admin no se puede prender,
-- `bot_usuarios_respeta_apagado`). Suma `sucursal_nombre`.
-- La marca sigue siendo una por perfil y día (`bot_avisos_atrasados_enviados`):
-- el bot nuevo junta las sucursales de un mismo perfil en un solo mensaje; el
-- viejo, con dos filas del mismo perfil, manda la de la que reserva primero.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: los cuerpos vivos son los leídos el 12/11; la columna y el trigger
-- no existen
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.bot_admin_audit_log(date,date,text,uuid,integer)', '8b9bd14f553cc3ace7b23490c40bf68e'),
    ('public.bot_admin_audit_summary(date,date)',               'c2e394018712a44fc504845534785954'),
    ('public.bot_buscar_cliente(text,uuid,text,bigint,integer)', '1318738018edf75e4d19c8d02d165de8'),
    ('public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)', 'ae5a99e53110019012a8515bee7d8b1e'),
    ('public.bot_productos_dejados_cliente(bigint,uuid,text,bigint)', 'c561a7f8d138bf9f5c37a8901a4525b8'),
    ('public.bot_recorrido_resumen(uuid,bigint,date)',          '498655fd4ffaaa733458404a7f8c084f'),
    ('public.bot_mi_recorrido(uuid,bigint,date)',               '247d248f4bdb8dcd9bae07f08589d48b'),
    ('public.bot_aviso_atrasados_destinatarios(integer,integer)', 'efb8759e79b68f7f5ec5b43b9cc885ef'),
    -- Las usa el trigger y no cambian.
    ('public.bot_resolver_usuario(bigint)',                     '368b8bc34245526f871cb709c2324521')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_attribute
              WHERE attrelid = 'public.bot_audit_log'::regclass AND attname = 'sucursal_id' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · bot_audit_log.sucursal_id ya existe: revisar a mano';
  END IF;
  IF to_regprocedure('public.bot_audit_log_sucursal()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · bot_audit_log_sucursal() ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · B-4 · la sucursal de cada evento
-- ---------------------------------------------------------------------------
ALTER TABLE public.bot_audit_log ADD COLUMN sucursal_id bigint;

COMMENT ON COLUMN public.bot_audit_log.sucursal_id IS
  'Sucursal del evento (#1552): la de resultado_meta.sucursal_id o la activa del chat al guardarlo. '
  'La pone trg_bot_audit_log_sucursal. NULL en las filas anteriores a la mig NNN y en las de quien no está vinculado.';

CREATE FUNCTION public.bot_audit_log_sucursal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_meta text := NEW.resultado_meta ->> 'sucursal_id';
  v_usr  jsonb;
BEGIN
  -- #1552 (B-4). Primero la que el evento declara (el resumen diario es de una
  -- sucursal que no tiene por qué ser la activa del chat). Sólo un entero: una
  -- id rara no puede tirar el INSERT, que en la edge function es fail-closed.
  IF NEW.sucursal_id IS NULL AND v_meta ~ '^[0-9]{1,18}$' THEN
    NEW.sucursal_id := v_meta::bigint;
  END IF;

  -- Si no, la sucursal activa del chat ahora, la misma con la que el bot
  -- contestó: la de bot_resolver_usuario, y sólo si el chat es de ese perfil.
  IF NEW.sucursal_id IS NULL AND NEW.telegram_user_id IS NOT NULL AND NEW.perfil_id IS NOT NULL THEN
    v_usr := public.bot_resolver_usuario(NEW.telegram_user_id);
    IF (v_usr ->> 'ok') = 'true' AND (v_usr ->> 'perfil_id') = NEW.perfil_id::text THEN
      NEW.sucursal_id := (v_usr ->> 'sucursal_id')::bigint;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- De trigger: la invoca el executor, nadie necesita EXECUTE.
REVOKE ALL ON FUNCTION public.bot_audit_log_sucursal() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_bot_audit_log_sucursal
  BEFORE INSERT ON public.bot_audit_log
  FOR EACH ROW EXECUTE FUNCTION public.bot_audit_log_sucursal();

-- Las filas viejas del resumen traen la sucursal en el meta.
UPDATE public.bot_audit_log
   SET sucursal_id = (resultado_meta ->> 'sucursal_id')::bigint
 WHERE sucursal_id IS NULL
   AND resultado_meta ->> 'sucursal_id' ~ '^[0-9]{1,18}$';

CREATE OR REPLACE FUNCTION public.bot_admin_audit_log(p_desde date, p_hasta date, p_tipo text DEFAULT NULL::text, p_perfil_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 200)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rol       TEXT;
  v_limit     INT;
  v_resultado JSON;
  v_sucs      BIGINT[];
  v_abarcados UUID[];
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Solo admin puede leer el audit log del bot';
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 200), 1000), 1);

  -- #1552 (B-4): los eventos de sus sucursales, por la sucursal del EVENTO y no
  -- por las del usuario que lo generó. Una fila anterior a esta migración no tiene
  -- sucursal: se ve si el admin tiene todas las del usuario (el criterio de
  -- admin_abarca_sucursales_de). Las dos listas se arman una vez (B-9).
  SELECT COALESCE(array_agg(us.sucursal_id), '{}')
    INTO v_sucs
    FROM usuario_sucursales us
   WHERE us.usuario_id = auth.uid();
  SELECT COALESCE(array_agg(x.usuario_id), '{}')
    INTO v_abarcados
    FROM (SELECT us.usuario_id
            FROM usuario_sucursales us
           GROUP BY us.usuario_id
          HAVING bool_and(us.sucursal_id = ANY (v_sucs))) x;

  SELECT COALESCE(
    json_agg(row_to_json(t) ORDER BY t.created_at DESC),
    '[]'::json
  )
  INTO v_resultado
  FROM (
    SELECT
      al.id,
      al.telegram_user_id,
      al.perfil_id,
      p.nombre AS perfil_nombre,
      al.rol,
      al.tipo,
      al.tool_name,
      al.parametros,
      al.resultado_meta,
      al.texto_usuario,
      al.texto_bot,
      al.created_at
    FROM bot_audit_log al
    LEFT JOIN perfiles p ON p.id = al.perfil_id
    -- mig 245 (#639) · created_at es timestamptz y p_desde/p_hasta son DATE:
    -- Postgres los promovia a medianoche UTC y el rango cortaba el dia tres
    -- horas tarde. Mismo corte por dia argentino que mermas_valorizadas (238).
    WHERE (al.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
      AND (p_tipo      IS NULL OR al.tipo      = p_tipo)
      AND (p_perfil_id IS NULL OR al.perfil_id = p_perfil_id)
      -- #1244 y #1552: los de sus sucursales.
      AND al.perfil_id IS NOT NULL
      AND (al.sucursal_id = ANY (v_sucs)
           OR (al.sucursal_id IS NULL AND al.perfil_id = ANY (v_abarcados)))
    ORDER BY al.created_at DESC
    LIMIT v_limit
  ) t;

  RETURN v_resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_admin_audit_summary(p_desde date, p_hasta date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rol               TEXT;
  v_total             BIGINT;
  v_por_tipo          JSON;
  v_por_perfil        JSON;
  v_tools_top         JSON;
  v_errores_recientes BIGINT;
  v_sucs              BIGINT[];
  v_abarcados         UUID[];
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Solo admin puede leer el resumen de auditoría del bot';
  END IF;

  -- #1244 y #1552: todo el resumen cuenta sólo los eventos de sus sucursales,
  -- los mismos que lista bot_admin_audit_log y con las mismas dos listas.
  SELECT COALESCE(array_agg(us.sucursal_id), '{}')
    INTO v_sucs
    FROM usuario_sucursales us
   WHERE us.usuario_id = auth.uid();
  SELECT COALESCE(array_agg(x.usuario_id), '{}')
    INTO v_abarcados
    FROM (SELECT us.usuario_id
            FROM usuario_sucursales us
           GROUP BY us.usuario_id
          HAVING bool_and(us.sucursal_id = ANY (v_sucs))) x;

  SELECT COUNT(*)
    INTO v_total
    FROM bot_audit_log
   -- mig 245 (#639) · corte por dia argentino, como en bot_admin_audit_log.
   WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
     AND perfil_id IS NOT NULL
     AND (sucursal_id = ANY (v_sucs) OR (sucursal_id IS NULL AND perfil_id = ANY (v_abarcados)));

  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.count DESC), '[]'::json)
    INTO v_por_tipo
    FROM (
      SELECT tipo, COUNT(*)::int AS count
        FROM bot_audit_log
       WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
         AND perfil_id IS NOT NULL
         AND (sucursal_id = ANY (v_sucs) OR (sucursal_id IS NULL AND perfil_id = ANY (v_abarcados)))
       GROUP BY tipo
    ) t;

  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.count DESC), '[]'::json)
    INTO v_por_perfil
    FROM (
      SELECT
        al.perfil_id,
        p.nombre AS perfil_nombre,
        COUNT(*)::int AS count
      FROM bot_audit_log al
      LEFT JOIN perfiles p ON p.id = al.perfil_id
      WHERE (al.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
        AND al.perfil_id IS NOT NULL
        AND (al.sucursal_id = ANY (v_sucs)
             OR (al.sucursal_id IS NULL AND al.perfil_id = ANY (v_abarcados)))
      GROUP BY al.perfil_id, p.nombre
      ORDER BY COUNT(*) DESC
      LIMIT 10
    ) t;

  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.count DESC), '[]'::json)
    INTO v_tools_top
    FROM (
      SELECT tool_name, COUNT(*)::int AS count
        FROM bot_audit_log
       WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
         AND tool_name IS NOT NULL
         AND perfil_id IS NOT NULL
         AND (sucursal_id = ANY (v_sucs) OR (sucursal_id IS NULL AND perfil_id = ANY (v_abarcados)))
       GROUP BY tool_name
       ORDER BY COUNT(*) DESC
       LIMIT 10
    ) t;

  SELECT COUNT(*)
    INTO v_errores_recientes
    FROM bot_audit_log
   WHERE tipo = 'error'
     AND created_at >= now() - interval '24 hours'
     AND perfil_id IS NOT NULL
     AND (sucursal_id = ANY (v_sucs) OR (sucursal_id IS NULL AND perfil_id = ANY (v_abarcados)));

  RETURN json_build_object(
    'total_eventos',       v_total,
    'por_tipo',            v_por_tipo,
    'por_perfil',          v_por_perfil,
    'tools_top',           v_tools_top,
    'errores_recientes',   v_errores_recientes
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 · B-1 · el depósito no lee clientes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_buscar_cliente(p_q text, p_perfil_id uuid, p_rol text, p_sucursal_id bigint, p_limit integer DEFAULT 10)
 RETURNS TABLE(id bigint, codigo integer, nombre_fantasia text, razon_social text, saldo_cuenta numeric, direccion text, zona text, sucursal_id bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH terms AS (
    SELECT array_remove(
      string_to_array(
        trim(lower(f_unaccent(coalesce(p_q, '')))),
        ' '
      ),
      ''
    ) AS words
  )
  SELECT
    c.id, c.codigo, c.nombre_fantasia, c.razon_social, c.saldo_cuenta,
    -- #1336: la zona sale de zonas por zona_id; la columna de texto se dropea.
    c.direccion, (SELECT z.nombre FROM zonas z WHERE z.id = c.zona_id) AS zona, c.sucursal_id
  FROM clientes c, terms t
  WHERE
    c.sucursal_id = p_sucursal_id
    -- #1552 (B-1): como mt_clientes_select, el deposito (o un rol que no es
    -- ninguno de estos) no ve clientes. El transportista si, como en la app.
    AND p_rol IN ('admin', 'encargado', 'preventista', 'transportista')
    -- Baja logica: un cliente desactivado no se ofrece para operar. Su historial
    -- sigue intacto y visible en los reportes, que no pasan por aca.
    AND c.activo = TRUE
    AND (
      p_rol IN ('admin', 'encargado')  -- #1311 (BOT-6): como la rama de reservado y la ficha
      OR EXISTS(
        SELECT 1 FROM cliente_preventistas cp
        WHERE cp.cliente_id = c.id AND cp.preventista_id = p_perfil_id
      )
      -- Huerfanos (sin asignacion a ningun preventista) visibles para cualquier
      -- preventista de la misma sucursal (mig 028).
      OR NOT EXISTS(
        SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id
      )
    )
    -- Reservado a administracion (mig 214): el reservado es huerfano, asi que
    -- sin esto la rama de arriba se lo muestra a cualquier preventista.
    AND (
      p_rol IN ('admin', 'encargado')
      OR NOT c.reservado_admin
      OR EXISTS(
        SELECT 1 FROM pedidos pe
        WHERE pe.cliente_id = c.id AND pe.usuario_id = p_perfil_id
      )
    )
    AND (
      array_length(t.words, 1) IS NULL
      OR (
        SELECT bool_and(
          lower(f_unaccent(coalesce(c.nombre_fantasia, ''))) LIKE '%' || w || '%'
          OR lower(f_unaccent(coalesce(c.razon_social, ''))) LIKE '%' || w || '%'
          OR lower(coalesce(c.codigo::TEXT, '')) LIKE '%' || w || '%'
        )
        FROM unnest(t.words) AS w
      )
    )
  ORDER BY c.nombre_fantasia
  LIMIT p_limit;
$function$;

-- Recurrentes (y con ella el resumen de visita, que la usa de gate) y dejados:
-- el mismo rechazo, antes del gate de cartera del preventista.
DO $parche_rol_clientes$
DECLARE
  f text;
  v_def text;
  v_a CONSTANT text := $a$BEGIN
  IF p_rol = 'preventista' THEN
$a$;
  v_r CONSTANT text := $r$BEGIN
  -- #1552 (B-1): como mt_clientes_select, el deposito (o un rol que no es
  -- ninguno de estos) no ve clientes. El transportista si, como en la app.
  IF p_rol IS NULL OR p_rol NOT IN ('admin', 'encargado', 'preventista', 'transportista') THEN
    RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::JSON,
      'error', 'Tu rol no tiene acceso a clientes');
  END IF;

  IF p_rol = 'preventista' THEN
$r$;
  v_n int;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)',
    'public.bot_productos_dejados_cliente(bigint,uuid,text,bigint)'
  ] LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', f, v_n;
    END IF;
    EXECUTE replace(v_def, v_a, v_r);
  END LOOP;
END
$parche_rol_clientes$;

-- ---------------------------------------------------------------------------
-- 3 · B-2 · sin fecha, el recorrido de hoy
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_recorrido_resumen(p_transportista_id uuid, p_sucursal_id bigint, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
BEGIN
  SELECT json_build_object(
    'recorrido_id', r.id, 'fecha', r.fecha, 'estado', r.estado,
    'total_pedidos', r.total_pedidos,
    'pedidos_entregados', r.pedidos_entregados,
    'pedidos_pendientes', GREATEST(r.total_pedidos - r.pedidos_entregados, 0),
    'total_facturado', r.total_facturado,
    'total_cobrado', r.total_cobrado,
    'porcentaje_cobrado', CASE
      WHEN r.total_facturado > 0 THEN ROUND((r.total_cobrado / r.total_facturado) * 100, 1)
      ELSE 0 END,
    'completed_at', r.completed_at
  ) INTO resultado
  FROM recorridos r
  WHERE r.transportista_id = p_transportista_id
    -- #1552 (B-2): PostgREST pasa el NULL tal cual y no aplica el DEFAULT.
    AND r.sucursal_id = p_sucursal_id AND r.fecha = COALESCE(p_fecha, public._tablero_hoy())
  -- #1310 (BOT-7): con dos recorridos en el día, el mismo que bot_mi_recorrido.
  ORDER BY r.id DESC
  LIMIT 1;
  RETURN resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_mi_recorrido(p_transportista_id uuid, p_sucursal_id bigint, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH r AS (
    SELECT
      id,
      fecha::text AS fecha,
      estado,
      total_pedidos,
      pedidos_entregados,
      total_facturado,
      total_cobrado
    FROM recorridos
    WHERE transportista_id = p_transportista_id
      -- #1552 (B-2): PostgREST pasa el NULL tal cual y no aplica el DEFAULT.
      AND fecha = COALESCE(p_fecha, public._tablero_hoy())
      AND sucursal_id = p_sucursal_id
    ORDER BY id DESC
    LIMIT 1
  )
  SELECT json_build_object(
    'recorrido', COALESCE((SELECT row_to_json(r.*) FROM r), 'null'::json),
    'pedidos', COALESCE(
      (
        SELECT json_agg(
          json_build_object(
            'pedido_id',      rp.pedido_id,
            'orden_entrega',  rp.orden_entrega,
            'estado_entrega', rp.estado_entrega,
            'cliente_id',     p.cliente_id,
            'cliente_nombre', COALESCE(c.nombre_fantasia, c.razon_social, '(sin nombre)'),
            'direccion',      c.direccion,
            'total',          p.total,
            'estado_pago',    p.estado_pago
          )
          ORDER BY rp.orden_entrega ASC NULLS LAST, rp.id ASC
        )
        FROM recorrido_pedidos rp
        JOIN pedidos p ON p.id = rp.pedido_id
        LEFT JOIN clientes c ON c.id = p.cliente_id
        WHERE rp.recorrido_id = (SELECT id FROM r)
          -- mig 332 (#1034): el total de un VB es su costo. El que lo repartió
          -- no lo ve, salvo que lo haya cargado él (mt_pedidos_select).
          AND (p.tipo_factura IS DISTINCT FROM 'VB' OR p.usuario_id = p_transportista_id)
      ),
      '[]'::json
    )
  );
$function$;

-- ---------------------------------------------------------------------------
-- 4 · B-3 · el aviso de atrasados, por las sucursales vivas
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_aviso_atrasados_destinatarios(p_hora integer, p_dow integer)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(json_agg(json_build_object(
           'telegram_user_id', d.telegram_user_id,
           'perfil_id',        d.perfil_id,
           'sucursal_id',      d.sucursal_id,
           'sucursal_nombre',  d.sucursal_nombre
         ) ORDER BY d.telegram_user_id, d.sucursal_id), '[]'::json)
    FROM (
      -- #1552 (B-3): como bot_digest_suscripciones, una fila por cada sucursal
      -- ACTIVA asignada (usuario_sucursales), no la foto de bot_usuarios.sucursal_id,
      -- y un chat por perfil y sucursal: el último vinculado. Sin sucursal, nada.
      SELECT DISTINCT ON (bu.perfil_id, s.id)
             bu.telegram_user_id,
             bu.perfil_id,
             s.id            AS sucursal_id,
             s.nombre::text  AS sucursal_nombre
        FROM bot_usuarios bu
        JOIN perfiles p ON p.id = bu.perfil_id
        JOIN usuario_sucursales us ON us.usuario_id = bu.perfil_id
        JOIN sucursales s ON s.id = us.sucursal_id AND s.activa IS TRUE
        LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
       WHERE bu.activo AND p.activo AND p.rol = 'preventista'
         -- Activado por defecto (decisión del dueño, 2026-10-09).
         AND COALESCE(c.aviso_atrasados_activo, TRUE)
         -- #1309: desde su hora, no sólo dentro de ella. El cron horario de GitHub
         -- se saltea horas.
         AND COALESCE(c.aviso_atrasados_hora, 8) <= p_hora::SMALLINT
         AND p_dow::SMALLINT = ANY (COALESCE(c.aviso_atrasados_dias, ARRAY[1]::SMALLINT[]))
         AND NOT EXISTS (
           SELECT 1 FROM bot_avisos_atrasados_enviados a
            WHERE a.perfil_id = bu.perfil_id
              AND a.fecha = public._tablero_hoy()
              AND a.status <> 'error'
         )
       ORDER BY bu.perfil_id, s.id, bu.vinculado_at DESC, bu.telegram_user_id DESC
    ) d;
$function$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.bot_audit_log_sucursal()', 'b9e1295fb1f9611f292b5be9a50b0383', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.bot_admin_audit_log(date,date,text,uuid,integer)', '5b5e08f8d6878fedfd40e7fb5389bb11', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.bot_admin_audit_summary(date,date)', 'e8a0427f16ed788dfca7a62b11395508', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.bot_buscar_cliente(text,uuid,text,bigint,integer)', '96199ddd7e32d9cddcde7beeff073a78', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)', '693a945cceb8e366d084806c840a6996', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.bot_productos_dejados_cliente(bigint,uuid,text,bigint)', 'dee1aec873749b81e21e989f473f70e3', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.bot_recorrido_resumen(uuid,bigint,date)', '2696807d7a5f5576af703fa2cca579b7', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.bot_mi_recorrido(uuid,bigint,date)', '254f94595f46f3c5dfaf6628dfa1c6bc', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.bot_aviso_atrasados_destinatarios(integer,integer)', '938b47b8da5006778112bbdb364a016c', true,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.bot_audit_log'::regclass AND tgname = 'trg_bot_audit_log_sucursal'
                    AND tgfoid = 'public.bot_audit_log_sucursal()'::regprocedure AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig NNN · falta el trigger trg_bot_audit_log_sucursal';
  END IF;
  -- La tabla sigue sin grants para el front: la lee sólo el panel, por RPC.
  IF has_table_privilege('authenticated', 'public.bot_audit_log', 'SELECT')
     OR has_table_privilege('anon', 'public.bot_audit_log', 'SELECT')
     OR has_column_privilege('authenticated', 'public.bot_audit_log', 'sucursal_id', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · bot_audit_log quedó legible por REST';
  END IF;
END
$post$;

COMMIT;
