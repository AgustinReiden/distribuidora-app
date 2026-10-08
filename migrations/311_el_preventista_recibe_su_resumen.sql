-- =============================================================================
-- 311 · El preventista recibe su resumen
-- =============================================================================
--
-- PR 2b del plan del bot (#978). Dos cosas que el resumen de la mañana no
-- hacía:
--
--   * El PREVENTISTA no recibía nada. Ahora puede recibir el suyo: lo que
--     vendió ayer y en el mes, y sus clientes atrasados con la plata en juego,
--     con un botón por cliente que abre el resumen de visita. OPT-IN: sin fila
--     de configuración no recibe nada (al revés que el admin), así que esta
--     migración no le manda un mensaje a nadie que no lo haya pedido.
--   * El ADMIN no veía la plata en riesgo por preventista. Sección nueva,
--     `riesgo_preventistas`, que entra en el default (el admin sin fila de
--     config la recibe desde mañana; el que ya eligió sus secciones, no, hasta
--     que la tilde en el panel).
--
-- NINGUNA de las dos secciones nuevas pasa por el modelo: son números, y un
-- número mal narrado se lee como un número equivocado. Las arma un formatter
-- de la edge function con la RPC de abajo, igual que la de vencimientos. El
-- resumen del preventista, entero, cuesta cero de IA.
--
-- La lista de secciones ahora depende del ROL. Vive en una función,
-- `digest_secciones_del_rol`, y la consumen las tres puntas que deciden: el
-- guardado (rechaza una sección que no es del rol), los destinatarios (la
-- descartan aunque esté en la fila) y el listado del panel (le dice al panel
-- qué ofrecer). Un preventista nunca recibe deuda de la sucursal ni ventas de
-- todos aunque alguien escriba la fila a mano.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 · Las secciones nuevas en la lista blanca
-- ---------------------------------------------------------------------------
-- Las TRES puntas se mueven juntas (ver 261): este CHECK, `SECCIONES` de
-- telegram-digest/secciones.ts y `SECCIONES_DIGEST` de src/utils/digestSecciones.ts.
ALTER TABLE public.bot_digest_config DROP CONSTRAINT bot_digest_config_secciones_ck;
ALTER TABLE public.bot_digest_config ADD CONSTRAINT bot_digest_config_secciones_ck
  CHECK (
    secciones <@ ARRAY[
      'ventas','top_clientes','top_productos','stock_critico','deuda',
      'pendientes_entrega','pendientes_pago','recorridos','rendiciones',
      'vencimientos','riesgo_preventistas','mis_ventas','mis_atrasados'
    ]::TEXT[]
  );

COMMENT ON TABLE public.bot_digest_config IS
  'Preferencias del resumen de Telegram por persona (admin o preventista). La fila es opcional: sin fila, el admin recibe el default de su rol y el preventista no recibe nada (opt-in, mig 311).';


-- ---------------------------------------------------------------------------
-- 2 · Qué secciones son de cada rol, y cuál es su default
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.digest_secciones_del_rol(p_rol TEXT)
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE p_rol
    WHEN 'admin' THEN ARRAY[
      'ventas','top_clientes','top_productos','stock_critico','deuda',
      'pendientes_entrega','pendientes_pago','recorridos','rendiciones',
      'vencimientos','riesgo_preventistas']::TEXT[]
    -- Sólo lo suyo: lo que vendió y su cartera. Nada de la sucursal.
    WHEN 'preventista' THEN ARRAY['mis_ventas','mis_atrasados']::TEXT[]
    ELSE ARRAY[]::TEXT[]
  END;
$function$;

COMMENT ON FUNCTION public.digest_secciones_del_rol(TEXT) IS
  'Secciones del resumen de Telegram que puede recibir cada rol (mig 311). Gate del guardado, de los destinatarios y del panel.';

CREATE OR REPLACE FUNCTION public.digest_secciones_default(p_rol TEXT)
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE p_rol
    -- El de siempre (261) mas la plata en riesgo por preventista.
    WHEN 'admin' THEN ARRAY['ventas','top_clientes','stock_critico','deuda','vencimientos',
                            'riesgo_preventistas']::TEXT[]
    WHEN 'preventista' THEN ARRAY['mis_ventas','mis_atrasados']::TEXT[]
    ELSE ARRAY[]::TEXT[]
  END;
$function$;

COMMENT ON FUNCTION public.digest_secciones_default(TEXT) IS
  'Secciones con las que arranca quien no tiene fila en bot_digest_config (mig 311). El preventista igual no recibe nada hasta que se lo active: el default de activo es por rol.';


-- ---------------------------------------------------------------------------
-- 3 · Quién recibe en esta hora: admins y preventistas que lo pidieron
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_digest_destinatarios(p_hora integer, p_dow integer)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    json_agg(
      json_build_object(
        'telegram_user_id', t.telegram_user_id,
        'perfil_id',        t.perfil_id,
        'rol',              t.rol,
        'sucursal_id',      t.sucursal_id,
        'secciones',        t.secciones
      )
      ORDER BY t.telegram_user_id
    ),
    '[]'::json
  )
  FROM (
    SELECT
      bu.telegram_user_id,
      bu.perfil_id,
      p.rol,
      bu.sucursal_id,
      -- Admin: sin fila recibe el default, como siempre. Preventista: sin fila,
      -- nada (opt-in).
      COALESCE(c.activo, p.rol = 'admin')                       AS activo,
      COALESCE(c.hora_local,  7::SMALLINT)                      AS hora_local,
      COALESCE(c.dias_semana, ARRAY[1,2,3,4,5,6,7]::SMALLINT[]) AS dias_semana,
      -- Lo que eligió, recortado a lo que su rol puede recibir: una fila
      -- escrita a mano con secciones de otro rol no le hace llegar nada ajeno.
      ARRAY(
        SELECT s FROM unnest(COALESCE(c.secciones, digest_secciones_default(p.rol))) s
         WHERE s = ANY (digest_secciones_del_rol(p.rol))
         ORDER BY s
      ) AS secciones
    FROM bot_usuarios bu
    JOIN perfiles p ON p.id = bu.perfil_id
    LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
    -- El rol y el alta salen de `perfiles`, no del snapshot de bot_usuarios
    -- (mig 237): el resumen le llega a quien HOY es admin o preventista.
    WHERE bu.activo AND p.activo AND p.rol IN ('admin', 'preventista')
      -- Un preventista sin sucursal activa no tiene cartera que contar.
      AND (p.rol = 'admin' OR bu.sucursal_id IS NOT NULL)
  ) t
  WHERE t.activo
    AND t.hora_local = p_hora::SMALLINT
    AND p_dow::SMALLINT = ANY(t.dias_semana)
    -- Sin secciones no hay mensaje que mandar.
    AND array_length(t.secciones, 1) >= 1;
$function$;


-- ---------------------------------------------------------------------------
-- 4 · Panel: listar y guardar, ahora con preventistas
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
        'telegram_user_id', bu.telegram_user_id,
        'sucursal_id',      bu.sucursal_id,
        'sucursal_nombre',  s.nombre,
        -- `configurado` distingue "eligió esto" de "nunca lo tocó y le quedó el
        -- default". Sin esa marca el panel no puede decir cuál es cuál.
        'configurado',      (c.perfil_id IS NOT NULL),
        'activo',           COALESCE(c.activo, p.rol = 'admin'),
        'hora_local',       COALESCE(c.hora_local, 7),
        'dias_semana',      COALESCE(c.dias_semana, ARRAY[1,2,3,4,5,6,7]::SMALLINT[]),
        'secciones',        COALESCE(c.secciones, digest_secciones_default(p.rol)),
        -- Lo que el panel puede ofrecerle a esta persona.
        'secciones_permitidas', digest_secciones_del_rol(p.rol),
        'actualizado_at',   c.actualizado_at,
        'actualizado_por',  ap.nombre
      )
      -- Admins primero, después preventistas.
      ORDER BY (p.rol <> 'admin'), p.nombre
    ),
    '[]'::json
  )
  INTO v_resultado
  FROM bot_usuarios bu
  JOIN perfiles p               ON p.id = bu.perfil_id
  LEFT JOIN sucursales s        ON s.id = bu.sucursal_id
  LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
  LEFT JOIN perfiles ap         ON ap.id = c.actualizado_por
  WHERE bu.activo AND p.activo AND p.rol IN ('admin', 'preventista');

  RETURN v_resultado;
END;
$fn$;

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

  -- El destinatario tiene que ser un admin o un preventista vinculado al bot.
  -- Sin este chequeo se podrían crear filas de config para perfiles que nunca
  -- van a recibir nada, y el panel mostraría gente que no está en el bot.
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

  -- Cada rol, sus secciones: a un preventista no se le guarda la deuda de la
  -- sucursal, ni a un admin "mis ventas".
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
-- 5 · Los datos del resumen del preventista
-- ---------------------------------------------------------------------------
-- Consume las funciones que ya contestan esas preguntas en el bot: lo que
-- vendió (bot_mis_ventas, la venta de la 241) y sus atrasados
-- (bot_clientes_atrasados, la cartera y los montos propios de la 308). No hay
-- una tercera definición de nada.
CREATE OR REPLACE FUNCTION public.bot_digest_preventista(
  p_perfil_id   UUID,
  p_sucursal_id BIGINT,
  p_fecha       DATE
)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_inicio_mes DATE := date_trunc('month', p_fecha)::date;
  v_dia        json;
  v_mes        json;
  v_atrasados  json;
BEGIN
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'bot_digest_preventista: sucursal requerida';
  END IF;
  -- Falla cerrado: el resumen de cartera es de un preventista activo, nadie más.
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = p_perfil_id AND rol = 'preventista' AND activo) THEN
    RAISE EXCEPTION 'bot_digest_preventista: % no es un preventista activo', p_perfil_id;
  END IF;
  -- Y de ESTA sucursal hoy: bot_usuarios.sucursal_id es una foto que puede
  -- quedar vieja si lo pasan a otra.
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = p_perfil_id AND sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'bot_digest_preventista: % no pertenece a la sucursal %', p_perfil_id, p_sucursal_id;
  END IF;

  -- Lo de AYER son los pedidos que TOMÓ, no venta: la venta se reconoce con la
  -- entrega (241) y en prod el 72 % se entrega al dia siguiente (medido el
  -- 2026-10-08: de 45 pedidos del 7/10, 1 entregado a la mañana). Contado como
  -- venta, el resumen diria "ayer no vendiste" casi todos los dias.
  SELECT json_build_object('pedidos', COUNT(*), 'total', COALESCE(SUM(total), 0))
    INTO v_dia
    FROM pedidos
   WHERE usuario_id = p_perfil_id AND sucursal_id = p_sucursal_id
     AND fecha = p_fecha AND estado <> 'cancelado' AND canal <> 'cambio';
  -- Lo del mes si es venta, con la definicion de la 241.
  v_mes := bot_mis_ventas(p_perfil_id, v_inicio_mes, p_fecha, p_sucursal_id, 0);
  v_atrasados := bot_clientes_atrasados(p_sucursal_id, 'preventista', p_perfil_id, NULL, false, false, 5);

  RETURN json_build_object(
    'fecha', p_fecha,
    'mis_ventas', json_build_object(
      'dia_tomados_pedidos', (v_dia ->> 'pedidos')::int,
      'dia_tomados_total',   (v_dia ->> 'total')::numeric,
      'mes_desde',   v_inicio_mes,
      'mes_total',   (v_mes ->> 'total_ventas')::numeric,
      'mes_pedidos', (v_mes ->> 'pedidos_count')::int,
      'mes_clientes', (v_mes ->> 'clientes_distintos')::int
    ),
    'mis_atrasados', json_build_object(
      'clientes_en_cartera',     (v_atrasados ->> 'clientes_en_cartera')::int,
      'atrasados',               (v_atrasados ->> 'atrasados')::int,
      'monto_mensual_en_riesgo', (v_atrasados ->> 'monto_mensual_en_riesgo')::numeric,
      'clientes',                v_atrasados -> 'clientes'
    )
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 6 · La plata en riesgo por preventista (sección del admin)
-- ---------------------------------------------------------------------------
-- Cartera de cada preventista activo de la sucursal, vista como admin: montos
-- de todos los vendedores (es lo que el cliente compra por mes y se puede
-- perder). Un cliente puede estar en mas de una cartera (4 en prod al
-- 2026-10-08), asi que las filas no suman el total: el total va aparte, de la
-- sucursal entera.
CREATE OR REPLACE FUNCTION public.bot_riesgo_por_preventista(p_sucursal_id BIGINT)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'bot_riesgo_por_preventista: sucursal requerida';
  END IF;

  RETURN (
    WITH sucursal AS (
      SELECT COUNT(*) FILTER (WHERE estado = 'atrasado') AS atrasados,
             COALESCE(SUM(monto_mensual) FILTER (WHERE estado = 'atrasado'), 0) AS monto
        FROM clientes_ritmo_compra(p_sucursal_id, 'admin', NULL, NULL)
    ),
    -- Atrasados que no estan en la cartera de nadie: sin preventista asignado,
    -- no reservados a administracion (mig 214: reservado es lo contrario de
    -- "sin asignar") y sin venta de un preventista activo en 180 dias (esos
    -- huerfanos ya cuentan en la cartera de quien les vendio).
    sin_asignar AS (
      SELECT COUNT(*) AS atrasados, COALESCE(SUM(r.monto_mensual), 0) AS monto
        FROM clientes_ritmo_compra(p_sucursal_id, 'admin', NULL, NULL) r
        JOIN clientes c ON c.id = r.cliente_id
       WHERE r.estado = 'atrasado'
         AND NOT c.reservado_admin
         AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = r.cliente_id)
         AND NOT EXISTS (
               SELECT 1 FROM pedidos pe
                 JOIN perfiles pf ON pf.id = pe.usuario_id AND pf.rol = 'preventista' AND pf.activo
                WHERE pe.cliente_id = r.cliente_id AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
                  AND pe.fecha >= (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 179)
    ),
    reservados AS (
      SELECT COUNT(*) AS atrasados, COALESCE(SUM(r.monto_mensual), 0) AS monto
        FROM clientes_ritmo_compra(p_sucursal_id, 'admin', NULL, NULL) r
        JOIN clientes c ON c.id = r.cliente_id
       WHERE r.estado = 'atrasado' AND c.reservado_admin
    ),
    por_preventista AS (
      SELECT pf.id, pf.nombre,
             COUNT(*) FILTER (WHERE r.estado = 'atrasado') AS atrasados,
             COALESCE(SUM(r.monto_mensual) FILTER (WHERE r.estado = 'atrasado'), 0) AS monto,
             COUNT(r.cliente_id) AS clientes_en_cartera
        FROM perfiles pf
        JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = p_sucursal_id
        LEFT JOIN LATERAL clientes_ritmo_compra(p_sucursal_id, 'admin', NULL, pf.id) r ON true
       WHERE pf.rol = 'preventista' AND pf.activo
       GROUP BY pf.id, pf.nombre
    )
    SELECT json_build_object(
      'sucursal_id', p_sucursal_id,
      'criterio', 'Atrasados de la cartera de cada preventista (asignados mas huerfanos donde vendio en 180 dias), con lo que el cliente compra por mes a todos los vendedores. Un cliente en dos carteras cuenta en las dos: el total es el de la sucursal.',
      'total_atrasados', (SELECT atrasados FROM sucursal),
      'total_monto_mensual', (SELECT ROUND(monto, 2) FROM sucursal),
      'sin_asignar_atrasados', (SELECT atrasados FROM sin_asignar),
      'sin_asignar_monto_mensual', (SELECT ROUND(monto, 2) FROM sin_asignar),
      'reservados_atrasados', (SELECT atrasados FROM reservados),
      'reservados_monto_mensual', (SELECT ROUND(monto, 2) FROM reservados),
      'preventistas', COALESCE((
        SELECT json_agg(json_build_object(
                 'perfil_id', id, 'nombre', nombre, 'atrasados', atrasados,
                 'monto_mensual_en_riesgo', ROUND(monto, 2),
                 'clientes_en_cartera', clientes_en_cartera)
               ORDER BY monto DESC, nombre)
          FROM por_preventista
      ), '[]'::json)
    )
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 7 · Permisos: server-only, salvo el panel (authenticated, gate de admin)
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.digest_secciones_del_rol(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.digest_secciones_default(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_digest_preventista(UUID, BIGINT, DATE) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_riesgo_por_preventista(BIGINT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.digest_secciones_del_rol(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.digest_secciones_default(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_digest_preventista(UUID, BIGINT, DATE) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_riesgo_por_preventista(BIGINT) TO service_role;

-- Las que ya existian conservan sus permisos con CREATE OR REPLACE; se
-- reafirman por si alguna vez se recrean con DROP.
REVOKE EXECUTE ON FUNCTION public.bot_digest_destinatarios(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_digest_destinatarios(integer, integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.bot_admin_listar_config_digest() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_listar_config_digest() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_admin_guardar_config_digest(uuid, boolean, integer, integer[], text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_guardar_config_digest(uuid, boolean, integer, integer[], text[]) TO authenticated;


-- ---------------------------------------------------------------------------
-- 8 · BOT-B: las dos nuevas consumen las canonicas
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_bot_sin_funcion_canonica()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT count(*)
    FROM (VALUES
      ('public.bot_pendientes_pago(bigint,integer,integer)',                'reporte_cuentas_por_cobrar'),
      ('public.bot_ventas_por_preventista(date,date,bigint,boolean,integer)', 'reporte_ventas_por_preventista'),
      ('public.bot_ranking_clientes(date,date,bigint,text,uuid,uuid,text,integer)', 'reporte_ventas_por_cliente'),
      ('public.bot_clientes_atrasados(bigint,text,uuid,uuid,boolean,boolean,integer)', 'clientes_ritmo_compra'),
      ('public.bot_resumen_cliente_visita(bigint,uuid,text,bigint)',        'clientes_ritmo_compra'),
      ('public.bot_riesgo_por_preventista(bigint)',                         'clientes_ritmo_compra'),
      ('public.bot_digest_preventista(uuid,bigint,date)',                   'bot_clientes_atrasados'),
      ('public.bot_digest_preventista(uuid,bigint,date)',                   'bot_mis_ventas')
    ) AS m(funcion, canonica)
   WHERE to_regprocedure(m.funcion) IS NULL
      -- Sin comentarios: un "-- antes llamaba a reporte_x(" no cuenta como llamada.
      OR regexp_replace(pg_get_functiondef(to_regprocedure(m.funcion)), '--[^\n]*', '', 'g')
           NOT ILIKE '%' || m.canonica || '(%';
$function$;

COMMENT ON FUNCTION public.auditoria_bot_sin_funcion_canonica() IS
  'BOT-B (300, 308, 311). Cada funcion del bot que da un numero de una pantalla consume la funcion de esa pantalla (deuda, ventas por preventista, ventas por cliente), y las que hablan de "atrasado" consumen clientes_ritmo_compra (una sola definicion). El resumen del preventista consume bot_mis_ventas y bot_clientes_atrasados. Las que todavia copian la definicion de venta (bot_ventas_periodo, bot_mis_ventas, bot_ficha_producto, bot_historico_pedidos_cliente, obtener_resumen_cuenta_cliente_bot) no estan: no hay funcion canonica que consumir.';


-- ---------------------------------------------------------------------------
-- 9 · El ensayo
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  s          RECORD;
  pv         RECORD;
  v_j        json;
  v_r        json;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_admin    uuid;
  v_prev     uuid;
  v_suc      bigint;
  v_n        int;
BEGIN
  -- 9a. Riesgo por preventista: cada fila es la lista de atrasados de esa
  --     cartera vista por el admin, y el total es el de la sucursal.
  FOR s IN SELECT id FROM sucursales WHERE activa LOOP
    v_r := bot_riesgo_por_preventista(s.id);
    v_j := bot_clientes_atrasados(s.id, 'admin', NULL, NULL, false, false, 1);
    IF (v_r ->> 'total_atrasados')::int <> (v_j ->> 'atrasados')::int
       OR abs((v_r ->> 'total_monto_mensual')::numeric - (v_j ->> 'monto_mensual_en_riesgo')::numeric) > 1 THEN
      RAISE EXCEPTION 'ensayo 311: el total de riesgo de la sucursal % no es el de clientes_atrasados', s.id;
    END IF;
    FOR pv IN SELECT x.value AS e FROM json_array_elements(v_r -> 'preventistas') x LOOP
      v_j := bot_clientes_atrasados(s.id, 'admin', NULL, (pv.e ->> 'perfil_id')::uuid, false, false, 1);
      IF (pv.e ->> 'atrasados')::int <> (v_j ->> 'atrasados')::int
         OR abs((pv.e ->> 'monto_mensual_en_riesgo')::numeric - (v_j ->> 'monto_mensual_en_riesgo')::numeric) > 1 THEN
        RAISE EXCEPTION 'ensayo 311: riesgo del preventista % no coincide con su lista de atrasados', pv.e ->> 'nombre';
      END IF;
    END LOOP;

    -- 9b. El resumen del preventista: sus atrasados son los de la herramienta
    --     y su venta del mes es la de bot_mis_ventas (la 241).
    FOR pv IN SELECT pf.id FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
               WHERE pf.rol = 'preventista' AND pf.activo AND us.sucursal_id = s.id LOOP
      v_j := bot_digest_preventista(pv.id, s.id, v_hoy - 1);
      IF (v_j -> 'mis_atrasados' ->> 'atrasados')::int
         <> (bot_clientes_atrasados(s.id, 'preventista', pv.id, NULL, false, false, 1) ->> 'atrasados')::int THEN
        RAISE EXCEPTION 'ensayo 311: los atrasados del resumen de % no son los de su cartera', pv.id;
      END IF;
      IF abs((v_j -> 'mis_ventas' ->> 'mes_total')::numeric - COALESCE((
            SELECT SUM(total) FROM pedidos
             WHERE usuario_id = pv.id AND sucursal_id = s.id AND estado = 'entregado' AND canal <> 'cambio'
               AND fecha BETWEEN date_trunc('month', v_hoy - 1)::date AND v_hoy - 1), 0)) > 1 THEN
        RAISE EXCEPTION 'ensayo 311: la venta del mes del resumen de % no es la de la 241', pv.id;
      END IF;
    END LOOP;
  END LOOP;

  -- 9c. El resumen de cartera falla cerrado para quien no es preventista.
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo LIMIT 1;
  BEGIN
    PERFORM bot_digest_preventista(v_admin, (SELECT id FROM sucursales WHERE activa LIMIT 1), v_hoy - 1);
    RAISE EXCEPTION 'ensayo 311: bot_digest_preventista corrio para un admin';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'ensayo 311%' THEN RAISE; END IF;
  END;

  -- 9d. Destinatarios, guardado y listado con un preventista vinculado de
  --     mentira. Todo se deshace con la excepcion marcadora del final.
  SELECT pf.id, us.sucursal_id INTO v_prev, v_suc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'preventista' AND pf.activo
     AND NOT EXISTS (SELECT 1 FROM bot_usuarios bu WHERE bu.perfil_id = pf.id)
   LIMIT 1;
  IF v_prev IS NOT NULL THEN
    BEGIN
      INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo)
      VALUES (-311, v_prev, 'preventista', v_suc, true);

      -- Opt-in: sin fila no recibe nada, a ninguna hora.
      FOR v_n IN 0..23 LOOP
        IF EXISTS (SELECT 1 FROM json_array_elements(bot_digest_destinatarios(v_n, 3)) d
                    WHERE (d ->> 'perfil_id')::uuid = v_prev) THEN
          RAISE EXCEPTION 'ensayo 311: un preventista sin configuracion recibe resumen';
        END IF;
      END LOOP;

      -- El guardado, como admin: rechaza secciones de otro rol...
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
      BEGIN
        PERFORM bot_admin_guardar_config_digest(v_prev, true, 8, ARRAY[1,2,3,4,5], ARRAY['mis_ventas','deuda']);
        RAISE EXCEPTION 'ensayo 311: se le guardo la deuda de la sucursal a un preventista';
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'ensayo 311%' THEN RAISE; END IF;
      END;
      -- ...y acepta las suyas.
      PERFORM bot_admin_guardar_config_digest(v_prev, true, 8, ARRAY[1,2,3,4,5], ARRAY['mis_atrasados','mis_ventas']);
      IF NOT EXISTS (SELECT 1 FROM json_array_elements(bot_digest_destinatarios(8, 3)) d
                      WHERE (d ->> 'perfil_id')::uuid = v_prev AND d ->> 'rol' = 'preventista') THEN
        RAISE EXCEPTION 'ensayo 311: el preventista activado no aparece a su hora';
      END IF;
      IF EXISTS (SELECT 1 FROM json_array_elements(bot_digest_destinatarios(8, 6)) d
                  WHERE (d ->> 'perfil_id')::uuid = v_prev) THEN
        RAISE EXCEPTION 'ensayo 311: el preventista recibe un sabado que no eligio';
      END IF;

      -- Una fila escrita a mano con secciones ajenas: se recortan.
      UPDATE bot_digest_config SET secciones = ARRAY['deuda','mis_ventas','ventas'] WHERE perfil_id = v_prev;
      SELECT d -> 'secciones' INTO v_j
        FROM json_array_elements(bot_digest_destinatarios(8, 3)) d
       WHERE (d ->> 'perfil_id')::uuid = v_prev;
      IF v_j IS NULL OR v_j::jsonb <> '["mis_ventas"]'::jsonb THEN
        RAISE EXCEPTION 'ensayo 311: al preventista le llegan secciones ajenas: %', v_j;
      END IF;

      -- El panel lo lista con sus secciones permitidas.
      IF NOT EXISTS (SELECT 1 FROM json_array_elements(bot_admin_listar_config_digest()) l
                      WHERE (l ->> 'perfil_id')::uuid = v_prev AND l ->> 'rol' = 'preventista'
                        AND (l -> 'secciones_permitidas')::jsonb = '["mis_ventas", "mis_atrasados"]'::jsonb) THEN
        RAISE EXCEPTION 'ensayo 311: el panel no lista al preventista con sus secciones';
      END IF;

      -- Sin sucursal activa no recibe: el panel tampoco le puede guardar uno.
      UPDATE bot_usuarios SET sucursal_id = NULL WHERE telegram_user_id = -311;
      BEGIN
        PERFORM bot_admin_guardar_config_digest(v_prev, true, 8, ARRAY[1], ARRAY['mis_ventas']);
        RAISE EXCEPTION 'ensayo 311: se guardo el resumen de un preventista sin sucursal';
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'ensayo 311%' THEN RAISE; END IF;
      END;

      RAISE EXCEPTION 'ensayo311_deshacer';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'ensayo311_deshacer' THEN RAISE; END IF;
    END;
  END IF;

  -- 9e. Los admins siguen como estaban: el que no tiene fila recibe el default
  --     de siempre mas la seccion nueva; el que eligio, lo suyo.
  SELECT d -> 'secciones' INTO v_j
    FROM json_array_elements(bot_digest_destinatarios(7, 3)) d
    JOIN perfiles p ON p.id = (d ->> 'perfil_id')::uuid
   WHERE NOT EXISTS (SELECT 1 FROM bot_digest_config c WHERE c.perfil_id = p.id)
   LIMIT 1;
  IF v_j IS NOT NULL AND v_j::jsonb <> '["deuda","riesgo_preventistas","stock_critico","top_clientes","vencimientos","ventas"]'::jsonb THEN
    RAISE EXCEPTION 'ensayo 311: el default del admin cambio de forma inesperada: %', v_j;
  END IF;

  -- 9f. BOT-B sigue en verde con los pares nuevos.
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(auditoria_integridad() -> 'checks') c
                  WHERE c ->> 'id' = 'BOT-B' AND (c ->> 'ok')::boolean) THEN
    RAISE EXCEPTION 'ensayo 311: BOT-B en rojo';
  END IF;

  RAISE NOTICE 'ensayo 311: destinatarios, guardado, listado, riesgo y resumen del preventista OK';
END;
$ensayo$;

COMMIT;
