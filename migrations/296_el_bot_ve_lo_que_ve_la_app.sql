-- =============================================================================
-- 296 · El bot ve lo que ve la app
-- =============================================================================
--
-- Hasta hoy ningun preventista estaba vinculado al bot, asi que nada de esto se
-- noto. Pero el dia que se vincule uno, cuatro herramientas le iban a mostrar
-- cosas que la app no le muestra. La regla de la app es `mt_pedidos_select`: un
-- rol que no sea admin ni encargado ve SOLO los pedidos donde
-- `usuario_id = el` o `transportista_id = el`. El bot corre con service_role,
-- asi que la RLS no lo frena y la regla tiene que estar escrita en cada RPC.
--
-- Decision del dueño (2026-10-07), "hechos si, montos no":
--   * Los HECHOS de un cliente que el preventista puede ver (cuando compro, si
--     sigue llevando un producto, cuantas veces lo llevo) salen de todos sus
--     pedidos. Si no, un cliente que pidio por la oficina le aparece perdido.
--   * Los MONTOS (pesos, unidades, ticket) salen solo de los pedidos propios.
--
-- Esta migracion:
--   1. bot_resolver_usuario devuelve tambien `roles`: el rol principal mas los
--      roles extra de `perfil_roles` EN LA SUCURSAL ACTIVA (perfil_roles es por
--      sucursal, igual que `tiene_rol_extra()`). El bot le da a cada usuario la
--      union de herramientas de sus roles.
--   2. canjear_codigo_vinculacion_bot: un chat por perfil. Al vincular uno nuevo
--      se desactivan los demas chats del mismo perfil, y se borra la memoria de
--      conversacion del chat que se vincula y de los que se desactivan.
--   3. bot_conversaciones guarda de que perfil, con que roles y en que sucursal
--      se escribio la memoria. Si cambia algo, el bot la descarta: la memoria
--      incluye resultados crudos de herramientas, y un admin degradado a
--      preventista (o alguien al que le sacan una sucursal) no tiene que poder
--      pedirle al modelo que le repita lo que vio antes.
--   4. bot_historico_pedidos_cliente: los pedidos (con montos e items) se
--      acotan como la RLS.
--   5. bot_productos_recurrentes_cliente: la frecuencia sale de todos los
--      pedidos; unidades y facturado, solo de los propios.
--   6. bot_sugerir_visitas_rfm: el ticket promedio sale solo de los propios.
--   7. Cupo de uso por usuario (bot_cupo_uso + bot_consumir_cupo): cada llamada
--      al modelo cuesta plata. Solo la ejecuta el servidor.
--
-- Los numeros de cada uno de estos reportes (que sea venta entregada, por fecha,
-- etc.) los corrige el PR de integridad. Aca solo cambia QUIEN ve QUE.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. bot_resolver_usuario: + roles
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_resolver_usuario(p_telegram_user_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_perfil_id     UUID;
  v_bot_activo    BOOLEAN;
  v_bot_sucursal  BIGINT;
  v_rol           TEXT;
  v_nombre        TEXT;
  v_perfil_activo BOOLEAN;
  v_sucursal_id   BIGINT;
  v_roles         TEXT[];
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

  -- Roles: el principal y los extra de la sucursal activa (296). Un rol extra de
  -- otra sucursal no cuenta, igual que en tiene_rol_extra().
  SELECT array_agg(DISTINCT r ORDER BY r)
    INTO v_roles
    FROM (
      SELECT v_rol AS r
      UNION
      SELECT pr.rol
        FROM perfil_roles pr
       WHERE pr.usuario_id = v_perfil_id
         AND pr.sucursal_id = v_sucursal_id
    ) x;

  RETURN jsonb_build_object(
    'ok',          true,
    'perfil_id',   v_perfil_id,
    'rol',         v_rol,
    'roles',       to_jsonb(v_roles),
    'nombre',      v_nombre,
    'sucursal_id', v_sucursal_id,
    'activo',      true
  );
END;
$function$;


-- -----------------------------------------------------------------------------
-- 2. canjear_codigo_vinculacion_bot: un chat por perfil + memoria limpia
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.canjear_codigo_vinculacion_bot(p_codigo text, p_telegram_user_id bigint, p_telegram_username text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- 6) Un chat por perfil (296). El chat viejo se apaga, no se borra: queda en
  --    el panel del bot. Si un admin lo vuelve a prender a mano desde el panel,
  --    el perfil queda con dos chats: es una decision explicita de un admin, no
  --    algo que pase solo. Su memoria si se borra, que es lo que podria filtrar.
  DELETE FROM bot_conversaciones bc
   USING bot_usuarios bu
   WHERE bc.telegram_user_id = bu.telegram_user_id
     AND bu.perfil_id = v_perfil_id
     AND bu.telegram_user_id <> p_telegram_user_id;

  UPDATE bot_usuarios
     SET activo = false
   WHERE perfil_id = v_perfil_id
     AND telegram_user_id <> p_telegram_user_id
     AND activo;

  -- La memoria del chat que se vincula tambien arranca vacia: puede venir de
  --    otro perfil (re-vinculacion) y traer resultados que este no puede ver.
  DELETE FROM bot_conversaciones WHERE telegram_user_id = p_telegram_user_id;

  -- 7) UPSERT en bot_usuarios (soporta re-vinculacion del mismo chat a otro
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

  -- 8) Vinculo bueno: el contador vuelve a cero.
  DELETE FROM bot_intentos_vinculacion WHERE telegram_user_id = p_telegram_user_id;

  RETURN jsonb_build_object(
    'success',     true,
    'perfil_id',   v_perfil_id,
    'rol',         v_perfil_rol,
    'sucursal_id', v_sucursal_id,
    'nombre',      v_perfil_nombre
  );
END;
$function$;


-- -----------------------------------------------------------------------------
-- 3. bot_conversaciones: de quien es la memoria
-- -----------------------------------------------------------------------------
-- NULL en las filas viejas: el bot las trata como "no coincide" y arranca de
-- cero una vez. Es lo correcto, porque no se sabe con que roles se escribieron.
ALTER TABLE public.bot_conversaciones
  ADD COLUMN IF NOT EXISTS perfil_id UUID,
  ADD COLUMN IF NOT EXISTS firma     TEXT;

COMMENT ON COLUMN public.bot_conversaciones.perfil_id IS
  'Perfil con el que se escribio la memoria (296). Si el chat se re-vincula a otro perfil, el bot la descarta.';
COMMENT ON COLUMN public.bot_conversaciones.firma IS
  'Roles y sucursal con los que se escribio la memoria (296), p.ej. "preventista,transportista@2". Si cambian, el bot la descarta: la memoria trae resultados crudos de herramientas.';


-- -----------------------------------------------------------------------------
-- 4. bot_historico_pedidos_cliente: los pedidos se acotan como la RLS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_historico_pedidos_cliente(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint, p_dias integer DEFAULT 90, p_limit integer DEFAULT 20)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
  -- mt_pedidos_select: admin y encargado ven todos los pedidos de la sucursal;
  -- cualquier otro rol, solo los que cargo o reparte (296).
  v_ve_todo BOOLEAN := p_rol IN ('admin', 'encargado');
BEGIN
  IF p_rol = 'preventista' THEN
    IF NOT (
      EXISTS(SELECT 1 FROM cliente_preventistas
             WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id)
      OR NOT EXISTS(SELECT 1 FROM cliente_preventistas
                    WHERE cliente_id = p_cliente_id)
    ) THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'pedidos_count', 0,
        'pedidos', '[]'::JSON, 'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214). El historial propio SI se ve: es la
    -- excepcion que evita que sus pedidos viejos queden sin cliente.
    IF EXISTS(SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.reservado_admin)
       AND NOT EXISTS(SELECT 1 FROM pedidos pe
                      WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = p_perfil_id)
    THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'pedidos_count', 0,
        'pedidos', '[]'::JSON, 'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  WITH ultimos_pedidos AS (
    SELECT id, fecha, total, estado, estado_pago, created_at
    FROM pedidos
    WHERE cliente_id = p_cliente_id AND sucursal_id = p_sucursal_id
      AND created_at > now() - (p_dias || ' days')::INTERVAL
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND (v_ve_todo OR usuario_id = p_perfil_id OR transportista_id = p_perfil_id)
    ORDER BY created_at DESC LIMIT p_limit
  ),
  pedidos_con_items AS (
    SELECT up.id, up.fecha, up.total, up.estado, up.estado_pago, up.created_at,
      (SELECT json_agg(json_build_object('producto_id', p.id, 'codigo', p.codigo,
        'nombre', p.nombre, 'cantidad', pi.cantidad, 'subtotal', pi.subtotal)
        ORDER BY pi.subtotal DESC)
       FROM pedido_items pi JOIN productos p ON p.id = pi.producto_id
       WHERE pi.pedido_id = up.id) AS items
    FROM ultimos_pedidos up
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id,
    'pedidos_count', (SELECT COUNT(*) FROM pedidos_con_items),
    'rango_dias', p_dias,
    'total_periodo', (SELECT COALESCE(SUM(total), 0) FROM pedidos_con_items),
    'alcance', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END,
    'pedidos', COALESCE(
      (SELECT json_agg(row_to_json(p.*) ORDER BY p.created_at DESC) FROM pedidos_con_items p),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- -----------------------------------------------------------------------------
-- 5. bot_productos_recurrentes_cliente: frecuencia de todos, montos propios
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_productos_recurrentes_cliente(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint, p_dias integer DEFAULT 90, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
  -- Hechos si, montos no (296): cuantas veces el cliente llevo el producto sale
  -- de todos sus pedidos; unidades y facturado, solo de los que el ve en la app.
  v_ve_todo BOOLEAN := p_rol IN ('admin', 'encargado');
BEGIN
  IF p_rol = 'preventista' THEN
    IF NOT (
      EXISTS(SELECT 1 FROM cliente_preventistas
             WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id)
      OR NOT EXISTS(SELECT 1 FROM cliente_preventistas
                    WHERE cliente_id = p_cliente_id)
    ) THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::JSON,
        'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214), con la misma excepcion de historial.
    IF EXISTS(SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.reservado_admin)
       AND NOT EXISTS(SELECT 1 FROM pedidos pe
                      WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = p_perfil_id)
    THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::JSON,
        'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  WITH items_periodo AS (
    SELECT pi.producto_id, pi.cantidad, pi.subtotal, pe.id AS pedido_id,
      (v_ve_todo OR pe.usuario_id = p_perfil_id OR pe.transportista_id = p_perfil_id) AS visible
    FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
    WHERE pe.cliente_id = p_cliente_id AND pe.sucursal_id = p_sucursal_id
      AND pe.created_at > now() - (p_dias || ' days')::INTERVAL
      AND COALESCE(pe.estado, '') NOT IN ('cancelado', 'anulado')
  ),
  ranked AS (
    SELECT p.id, p.codigo, p.nombre, p.precio,
      COUNT(DISTINCT ip.pedido_id) AS pedidos_con_producto,
      COALESCE(SUM(ip.cantidad) FILTER (WHERE ip.visible), 0) AS unidades_totales,
      COALESCE(SUM(ip.subtotal) FILTER (WHERE ip.visible), 0) AS facturado_total
    FROM items_periodo ip JOIN productos p ON p.id = ip.producto_id
    WHERE p.activo -- mig 284: un inactivo no se sugiere para volver a vender
    GROUP BY p.id, p.codigo, p.nombre, p.precio
    -- El desempate va por las unidades visibles: ordenar por las de todos
    -- dejaria inferir el volumen ajeno por el orden de la lista.
    ORDER BY COUNT(DISTINCT ip.pedido_id) DESC,
             COALESCE(SUM(ip.cantidad) FILTER (WHERE ip.visible), 0) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id, 'rango_dias', p_dias,
    'montos', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END,
    'productos', COALESCE((SELECT json_agg(row_to_json(r.*)) FROM ranked r), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- -----------------------------------------------------------------------------
-- 6. bot_sugerir_visitas_rfm: el ticket promedio, solo de lo propio
-- -----------------------------------------------------------------------------
-- El ritmo (ultima compra, frecuencia, cantidad de pedidos) sigue saliendo de
-- todos los pedidos del cliente: son hechos. El ticket es plata.
CREATE OR REPLACE FUNCTION public.bot_sugerir_visitas_rfm(p_preventista_id uuid, p_sucursal_id bigint, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH mis_clientes AS (
    SELECT
      c.id,
      c.codigo,
      COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, '(sin nombre)') AS nombre,
      c.saldo_cuenta,
      c.zona
    FROM clientes c
    JOIN cliente_preventistas cp ON cp.cliente_id = c.id
    WHERE cp.preventista_id = p_preventista_id
      AND c.sucursal_id = p_sucursal_id
      AND c.activo = TRUE
  ),
  intervalos AS (
    SELECT
      p.cliente_id,
      p.fecha,
      p.total,
      (p.usuario_id = p_preventista_id OR p.transportista_id = p_preventista_id) AS propio,
      (p.fecha - LAG(p.fecha) OVER (PARTITION BY p.cliente_id ORDER BY p.fecha))::int AS gap_dias
    FROM pedidos p
    JOIN mis_clientes mc ON mc.id = p.cliente_id
    WHERE p.fecha >= CURRENT_DATE - INTERVAL '180 days'
      AND p.estado <> 'cancelado'
      AND p.sucursal_id = p_sucursal_id
  ),
  metricas AS (
    SELECT
      mc.id            AS cliente_id,
      mc.codigo,
      mc.nombre,
      mc.zona,
      mc.saldo_cuenta,
      MAX(i.fecha)     AS ultima_compra,
      AVG(i.gap_dias)  AS frecuencia_dias,
      AVG(i.total) FILTER (WHERE i.propio) AS ticket_promedio,
      COUNT(i.fecha)   AS n_pedidos
    FROM mis_clientes mc
    LEFT JOIN intervalos i ON i.cliente_id = mc.id
    GROUP BY mc.id, mc.codigo, mc.nombre, mc.zona, mc.saldo_cuenta
  ),
  scored AS (
    SELECT
      m.*,
      COALESCE((CURRENT_DATE - m.ultima_compra)::int, 9999) AS dias_desde_ultima,
      CASE
        WHEN m.n_pedidos < 3 OR m.frecuencia_dias IS NULL THEN 21::numeric
        ELSE m.frecuencia_dias
      END AS freq_efectiva
    FROM metricas m
  ),
  ranking AS (
    SELECT
      s.*,
      LEAST(
        s.dias_desde_ultima::numeric / NULLIF(s.freq_efectiva, 0),
        5
      ) AS r_norm,
      PERCENT_RANK() OVER (ORDER BY s.n_pedidos)                   AS f_norm,
      PERCENT_RANK() OVER (ORDER BY s.ticket_promedio NULLS FIRST) AS m_norm
    FROM scored s
  ),
  final AS (
    SELECT
      cliente_id,
      codigo,
      nombre,
      zona,
      saldo_cuenta,
      ultima_compra,
      dias_desde_ultima,
      ROUND(freq_efectiva, 1)               AS frecuencia_dias,
      ROUND(COALESCE(ticket_promedio, 0), 2) AS ticket_promedio,
      n_pedidos,
      ROUND((r_norm * 0.5 + f_norm * 0.25 + m_norm * 0.25)::numeric, 3) AS score,
      (n_pedidos > 0 AND dias_desde_ultima > freq_efectiva * 1.3) AS vencido,
      CASE
        WHEN n_pedidos = 0 OR ultima_compra IS NULL THEN
          'Cliente sin pedidos en últimos 180 días — priorizar primer contacto'
        WHEN dias_desde_ultima > freq_efectiva * 2 THEN
          format('Atrasado: %s días sin comprar (compra cada ~%s)', dias_desde_ultima, ROUND(freq_efectiva))
        WHEN dias_desde_ultima > freq_efectiva * 1.3 THEN
          format('Próximo a re-pedido (cada ~%s días, lleva %s)', ROUND(freq_efectiva), dias_desde_ultima)
        WHEN saldo_cuenta > 0 THEN
          format('Tiene saldo $%s pendiente', ROUND(saldo_cuenta))
        WHEN n_pedidos >= 5 THEN
          'Cliente top por frecuencia'
        ELSE
          'Cliente activo'
      END AS motivo
    FROM ranking
    ORDER BY score DESC NULLS LAST
    LIMIT p_limit
  )
  SELECT json_build_object(
    'total', (SELECT COUNT(*) FROM final),
    'sugerencias', COALESCE(
      (SELECT json_agg(row_to_json(f) ORDER BY f.score DESC) FROM final f),
      '[]'::json
    )
  );
$function$;


-- -----------------------------------------------------------------------------
-- 7. Cupo de uso por usuario
-- -----------------------------------------------------------------------------
-- Una fila por chat, ventana fija por minuto y por dia argentino. Los limites
-- los pasa el bot (son constantes tecnicas, no politica comercial): asi se
-- ajustan sin migracion. Cuenta tambien los intentos rechazados, para que
-- insistir no abra el cupo.
CREATE TABLE IF NOT EXISTS public.bot_cupo_uso (
  telegram_user_id BIGINT PRIMARY KEY,
  minuto_inicio    TIMESTAMPTZ NOT NULL,
  conteo_minuto    INTEGER NOT NULL,
  dia              DATE NOT NULL,
  conteo_dia       INTEGER NOT NULL
);

ALTER TABLE public.bot_cupo_uso ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bot_cupo_uso FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.bot_cupo_uso IS
  'Cupo de mensajes al modelo por chat de Telegram (296). La escribe solo bot_consumir_cupo().';

CREATE OR REPLACE FUNCTION public.bot_consumir_cupo(
  p_telegram_user_id BIGINT,
  p_max_por_minuto   INTEGER,
  p_max_por_dia      INTEGER
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_minuto TIMESTAMPTZ := date_trunc('minute', now());
  v_dia    DATE        := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_min    INTEGER;
  v_dia_n  INTEGER;
BEGIN
  INSERT INTO bot_cupo_uso AS c (telegram_user_id, minuto_inicio, conteo_minuto, dia, conteo_dia)
  VALUES (p_telegram_user_id, v_minuto, 1, v_dia, 1)
  ON CONFLICT (telegram_user_id) DO UPDATE
     SET conteo_minuto = CASE WHEN c.minuto_inicio = v_minuto THEN c.conteo_minuto + 1 ELSE 1 END,
         minuto_inicio = v_minuto,
         conteo_dia    = CASE WHEN c.dia = v_dia THEN c.conteo_dia + 1 ELSE 1 END,
         dia           = v_dia
  RETURNING c.conteo_minuto, c.conteo_dia INTO v_min, v_dia_n;

  IF v_dia_n > p_max_por_dia THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'por_dia', 'conteo', v_dia_n);
  END IF;
  IF v_min > p_max_por_minuto THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'por_minuto', 'conteo', v_min);
  END IF;
  RETURN jsonb_build_object('ok', true, 'conteo_dia', v_dia_n);
END;
$function$;

-- Solo el servidor (el webhook) la llama: las tres mitades, no dos (CLAUDE.md).
REVOKE EXECUTE ON FUNCTION public.bot_consumir_cupo(BIGINT, INTEGER, INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_consumir_cupo(BIGINT, INTEGER, INTEGER) TO service_role;


-- -----------------------------------------------------------------------------
-- 8. El ensayo: un preventista no ve montos ajenos, el admin si
-- -----------------------------------------------------------------------------
-- Corre contra los datos reales. Los cambios de prueba (vinculaciones, cupos)
-- van dentro de un bloque que se deshace solo al final.
DO $ensayo$
DECLARE
  r            RECORD;
  v_json       JSON;
  v_jsonb      JSONB;
  v_ped        JSON;
  v_ajenos     INT;
  v_casos      INT := 0;
  v_prod       JSON;
  v_esperado   NUMERIC;
  v_admin_n    INT;
  v_prev_n     INT;
  c_marca CONSTANT TEXT := '__ensayo_296_se_deshace__';
BEGIN
  -- 8a. Historial y productos recurrentes, por cada preventista y cada cliente
  --     visible para el con pedidos de otro vendedor.
  -- Hasta 15 clientes por preventista, primero los que tienen pedidos propios
  -- Y ajenos (el caso que importa): asi entran todos los preventistas.
  FOR r IN
    SELECT perfil_id, cliente_id, sucursal_id
      FROM (
        SELECT pf.id AS perfil_id, c.id AS cliente_id, c.sucursal_id,
               row_number() OVER (
                 PARTITION BY pf.id
                 ORDER BY EXISTS (SELECT 1 FROM pedidos pp
                                   WHERE pp.cliente_id = c.id AND pp.usuario_id = pf.id) DESC,
                          c.id
               ) AS n
          FROM perfiles pf
          JOIN usuario_sucursales us ON us.usuario_id = pf.id
          JOIN clientes c ON c.sucursal_id = us.sucursal_id
         WHERE pf.rol = 'preventista' AND pf.activo
           AND NOT c.reservado_admin
           AND (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
                OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                            WHERE cp.cliente_id = c.id AND cp.preventista_id = pf.id))
           AND EXISTS (SELECT 1 FROM pedidos pe
                        WHERE pe.cliente_id = c.id
                          AND pe.sucursal_id = c.sucursal_id
                          AND pe.usuario_id IS DISTINCT FROM pf.id
                          AND pe.transportista_id IS DISTINCT FROM pf.id
                          AND pe.created_at > now() - interval '365 days'
                          AND COALESCE(pe.estado, '') NOT IN ('cancelado', 'anulado'))
      ) x
     WHERE n <= 15
  LOOP
    v_casos := v_casos + 1;

    v_json := bot_historico_pedidos_cliente(r.cliente_id, r.perfil_id, 'preventista',
                                            r.sucursal_id, 365, 50);
    SELECT count(*) INTO v_ajenos
      FROM json_array_elements(v_json -> 'pedidos') x
      JOIN pedidos pe ON pe.id = (x ->> 'id')::bigint
     WHERE pe.usuario_id IS DISTINCT FROM r.perfil_id
       AND pe.transportista_id IS DISTINCT FROM r.perfil_id;
    IF v_ajenos > 0 THEN
      RAISE EXCEPTION 'ensayo 296: historico le muestra % pedidos ajenos al preventista % (cliente %)',
        v_ajenos, r.perfil_id, r.cliente_id;
    END IF;

    -- El admin, para el mismo cliente, ve al menos lo mismo.
    v_admin_n := json_array_length(
      bot_historico_pedidos_cliente(r.cliente_id, r.perfil_id, 'admin', r.sucursal_id, 365, 50) -> 'pedidos');
    v_prev_n := json_array_length(v_json -> 'pedidos');
    IF v_admin_n < v_prev_n OR v_admin_n = 0 THEN
      RAISE EXCEPTION 'ensayo 296: el admin ve % pedidos y el preventista % (cliente %)',
        v_admin_n, v_prev_n, r.cliente_id;
    END IF;

    v_json := bot_productos_recurrentes_cliente(r.cliente_id, r.perfil_id, 'preventista',
                                                r.sucursal_id, 365, 25);
    FOR v_prod IN SELECT * FROM json_array_elements(v_json -> 'productos') LOOP
      SELECT COALESCE(SUM(pi.subtotal), 0) INTO v_esperado
        FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
       WHERE pe.cliente_id = r.cliente_id AND pe.sucursal_id = r.sucursal_id
         AND pi.producto_id = (v_prod ->> 'id')::bigint
         AND pe.created_at > now() - interval '365 days'
         AND COALESCE(pe.estado, '') NOT IN ('cancelado', 'anulado')
         AND (pe.usuario_id = r.perfil_id OR pe.transportista_id = r.perfil_id);
      IF (v_prod ->> 'facturado_total')::numeric <> v_esperado THEN
        RAISE EXCEPTION 'ensayo 296: recurrentes le muestra $% de facturado al preventista % y lo suyo es $% (cliente %, producto %)',
          v_prod ->> 'facturado_total', r.perfil_id, v_esperado, r.cliente_id, v_prod ->> 'id';
      END IF;
    END LOOP;
  END LOOP;

  IF v_casos = 0 THEN
    RAISE EXCEPTION 'ensayo 296: no encontre ningun cliente compartido para probar; el ensayo no probo nada';
  END IF;
  RAISE NOTICE 'ensayo 296: % casos de historial y recurrentes sin montos ajenos', v_casos;

  -- 8b. Roles, un chat por perfil y cupo. Todo se deshace al final.
  BEGIN
    -- Un preventista con rol extra de transportista en su sucursal default.
    SELECT pf.id, us.sucursal_id INTO r
      FROM perfiles pf
      JOIN perfil_roles pr ON pr.usuario_id = pf.id AND pr.rol = 'transportista'
      JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = pr.sucursal_id
     WHERE pf.activo AND pf.rol = 'preventista'
     ORDER BY us.es_default IS TRUE DESC
     LIMIT 1;

    IF FOUND THEN
      INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo)
      VALUES (-296001, r.id, 'preventista', r.sucursal_id, true);
      v_jsonb := bot_resolver_usuario(-296001);
      IF NOT (v_jsonb -> 'roles') ? 'transportista' OR NOT (v_jsonb -> 'roles') ? 'preventista' THEN
        RAISE EXCEPTION 'ensayo 296: bot_resolver_usuario no devuelve los dos roles: %', v_jsonb;
      END IF;

      -- Un segundo chat del mismo perfil, con memoria: al canjear un codigo
      -- desde ese chat, el primero se apaga y las dos memorias se borran.
      INSERT INTO bot_conversaciones (telegram_user_id, mensajes) VALUES (-296001, '[]'::jsonb);
      INSERT INTO bot_conversaciones (telegram_user_id, mensajes) VALUES (-296002, '[]'::jsonb);
      INSERT INTO bot_codigos_vinculacion (codigo, perfil_id) VALUES ('ENSAYO296', r.id);
      v_jsonb := canjear_codigo_vinculacion_bot('ENSAYO296', -296002, NULL);
      IF (v_jsonb ->> 'success')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'ensayo 296: el canje de prueba fallo: %', v_jsonb;
      END IF;
      IF EXISTS (SELECT 1 FROM bot_usuarios WHERE telegram_user_id = -296001 AND activo) THEN
        RAISE EXCEPTION 'ensayo 296: el chat viejo del perfil sigue activo';
      END IF;
      IF EXISTS (SELECT 1 FROM bot_conversaciones WHERE telegram_user_id IN (-296001, -296002)) THEN
        RAISE EXCEPTION 'ensayo 296: quedo memoria de conversacion despues de vincular';
      END IF;
    ELSE
      RAISE NOTICE 'ensayo 296: no hay preventista con rol extra; se salta la prueba de roles';
    END IF;

    -- Cupo: con 2 por minuto, el tercero se rechaza.
    PERFORM bot_consumir_cupo(-296003, 2, 100);
    PERFORM bot_consumir_cupo(-296003, 2, 100);
    v_jsonb := bot_consumir_cupo(-296003, 2, 100);
    IF (v_jsonb ->> 'ok')::boolean OR v_jsonb ->> 'motivo' <> 'por_minuto' THEN
      RAISE EXCEPTION 'ensayo 296: el cupo no corta en el tercer mensaje: %', v_jsonb;
    END IF;

    RAISE EXCEPTION '%', c_marca;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> c_marca THEN
      RAISE;
    END IF;
  END;

  RAISE NOTICE 'ensayo 296: roles, un chat por perfil y cupo, OK';
END;
$ensayo$;
