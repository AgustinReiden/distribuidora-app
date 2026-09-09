-- Migración 214: un cliente reservado a administración
--
-- Agrega el tercer estado de asignación: además de "sin asignar" y "asignado a
-- X" ahora existe "reservado a administración" (`clientes.reservado_admin`).
--
-- QUÉ SIGNIFICA (y qué NO). No es "invisible para todos menos admin":
--   * admin, encargado, transportista y depósito lo siguen viendo ENTERO, con
--     nombre y dirección. El transportista tiene que entregarle y cobrarle.
--   * el preventista que YA le vendió sigue viendo la ficha y sus pedidos
--     completos. Sin esta excepción el embed `cliente:clientes(*)` devolvería
--     NULL y los pedidos viejos se quedarían sin cliente — y peor, los
--     `!inner` de usePedidosQuery / usePedidoStatsQuery los harían DESAPARECER
--     de la lista y del count, en silencio.
--   * lo que se cierra es que un preventista lo tome como cliente NUEVO o lo
--     vea en sus listados operativos.
--
-- POR QUÉ UNA COLUMNA Y NO UNA ASIGNACIÓN. "Sin preventista asignado" ya
-- significa "visible para TODOS los preventistas" (mig 028), o sea justo lo
-- contrario. Y modelarlo dentro de `cliente_preventistas` no sirve: su policy
-- de INSERT (mig 002) deja auto-asignarse a cualquiera, así que un preventista
-- se agregaría solo con un INSERT y burlaría la restricción.
--
-- TERCER ESTADO EXCLUYENTE, no un flag que convive con asignaciones: un cliente
-- "reservado Y asignado a Juan" es una contradicción que alguien va a cargar.
-- Se enforcea en las dos direcciones (triggers 5 y 6 de abajo).
--
-- QUIÉN LO PONE Y LO SACA: solo admin. El encargado lo VE pero no lo administra,
-- igual que no edita las asignaciones (el bloque del modal es `{isAdmin && …}`)
-- ni los descuentos por categoría (RLS `es_admin()`). El trigger de la mig 080
-- no alcanza: sale por RETURN NEW para todo rol que no sea preventista, así que
-- el encargado necesita guard propio (trigger 4).
--
-- OJO es_preventista() / es_transportista(): devuelven true también para admin y
-- encargado. Acá se lee `perfiles.rol` CRUDO o se usa es_admin(), nunca
-- es_preventista().

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. La columna
-- ---------------------------------------------------------------------------

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS reservado_admin boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.clientes.reservado_admin IS
  'Tercer estado de asignación: el cliente lo atiende administración. Lo ven '
  'admin, encargado, transportista y depósito (con nombre y dirección), y el '
  'preventista que ya le vendió (historial). Ningún otro preventista lo ve ni '
  'puede tomarlo. Excluyente con cliente_preventistas: si es true, no hay '
  'asignaciones. Solo admin lo pone y lo saca.';

-- Índice para la excepción de historial (EXISTS pedidos propios) que aparece en
-- la RLS de SELECT y de UPDATE. Sin esto el chequeo cae en idx_pedidos_cliente_id
-- y filtra usuario_id fila por fila.
CREATE INDEX IF NOT EXISTS idx_pedidos_cliente_usuario
  ON public.pedidos (cliente_id, usuario_id);

-- ---------------------------------------------------------------------------
-- 2. RLS de SELECT
-- ---------------------------------------------------------------------------
-- La primera rama ("no soy preventista → veo todo") queda intacta: por eso
-- admin, encargado, transportista y depósito no se enteran de este cambio.
-- El predicado nuevo cuelga de la rama de preventista y SOLO RESTA: para un
-- cliente no reservado `NOT reservado_admin` es true y el comportamiento es
-- idéntico al de hoy, byte por byte.
--
-- `preventista_taco` no está: la mig 156 barrió el literal y el CHECK de
-- perfiles.rol (mig 040) ya no lo admite. Se mantiene el criterio de la policy
-- viva, que lee perfiles.rol crudo.

DROP POLICY IF EXISTS "mt_clientes_select" ON public.clientes;
CREATE POLICY "mt_clientes_select"
  ON public.clientes
  FOR SELECT TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      -- Roles que no son preventista ven todos los clientes de su sucursal
      NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol IN ('preventista')
      )
      OR (
        -- Regla de asignación de siempre: huérfanos + los míos
        (
          NOT EXISTS (
            SELECT 1 FROM public.cliente_preventistas cp
            WHERE cp.cliente_id = clientes.id
          )
          OR EXISTS (
            SELECT 1 FROM public.cliente_preventistas cp
            WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid()
          )
        )
        -- ...menos los reservados, salvo que tenga historial propio con él
        AND (
          NOT clientes.reservado_admin
          OR EXISTS (
            SELECT 1 FROM public.pedidos pe
            WHERE pe.cliente_id = clientes.id AND pe.usuario_id = auth.uid()
          )
        )
      )
    )
  );

-- ---------------------------------------------------------------------------
-- 3. RLS de UPDATE e INSERT
-- ---------------------------------------------------------------------------
-- mt_clientes_update es INDEPENDIENTE de la de SELECT: usa es_preventista(), así
-- que hoy un preventista que NO ve la fila igual puede hacerle UPDATE por id vía
-- PostgREST. El predicado va en USING y en WITH CHECK.
--
-- Acá es más estricto que el SELECT a propósito: el preventista con historial
-- LEE la ficha (para que sus pedidos viejos no se rompan) pero no la EDITA. El
-- cliente lo administra administración.

DROP POLICY IF EXISTS "mt_clientes_update" ON public.clientes;
CREATE POLICY "mt_clientes_update"
  ON public.clientes
  FOR UPDATE TO authenticated
  USING (
    public.es_preventista()
    AND sucursal_id = public.current_sucursal_id()
    AND (
      NOT reservado_admin
      OR NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol IN ('preventista')
      )
    )
  )
  WITH CHECK (
    public.es_preventista()
    AND sucursal_id = public.current_sucursal_id()
    AND (
      NOT reservado_admin
      OR NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol IN ('preventista')
      )
    )
  );

-- INSERT: si no, un preventista crea el cliente ya marcado y después se
-- auto-asigna. Nace reservado solo si lo crea un admin.
DROP POLICY IF EXISTS "mt_clientes_insert" ON public.clientes;
CREATE POLICY "mt_clientes_insert"
  ON public.clientes
  FOR INSERT TO authenticated
  WITH CHECK (
    public.es_preventista()
    AND sucursal_id = public.current_sucursal_id()
    AND (NOT reservado_admin OR public.es_admin())
  );

-- ---------------------------------------------------------------------------
-- 4. Solo admin pone y saca la marca
-- ---------------------------------------------------------------------------
-- El allow-list de la mig 080 ya deja la columna nueva protegida contra
-- preventistas (es fail-closed), pero sale por RETURN NEW para admin Y para
-- encargado. Este trigger cierra la mitad del encargado.
--
-- Exenciones, mismas que la 080: las RPC SECURITY DEFINER corren como postgres
-- y el bot con service_role — ahí `auth.uid()` no sirve para decidir.

CREATE OR REPLACE FUNCTION public.clientes_reservado_solo_admin()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.reservado_admin AND NOT es_admin() THEN
      RAISE EXCEPTION 'Solo un administrador puede crear un cliente reservado a administración'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.reservado_admin IS DISTINCT FROM OLD.reservado_admin AND NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede reservar un cliente a administración o liberarlo'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clientes_reservado_solo_admin ON public.clientes;
CREATE TRIGGER trg_clientes_reservado_solo_admin
  BEFORE INSERT OR UPDATE ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.clientes_reservado_solo_admin();

-- ---------------------------------------------------------------------------
-- 5. Reservado ⇒ sin asignaciones (al marcar, se limpian)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.clientes_reservado_limpia_asignaciones()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.reservado_admin THEN
    DELETE FROM cliente_preventistas WHERE cliente_id = NEW.id;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_clientes_reservado_limpia_asignaciones ON public.clientes;
CREATE TRIGGER trg_clientes_reservado_limpia_asignaciones
  AFTER INSERT OR UPDATE OF reservado_admin ON public.clientes
  FOR EACH ROW
  WHEN (NEW.reservado_admin)
  EXECUTE FUNCTION public.clientes_reservado_limpia_asignaciones();

-- ---------------------------------------------------------------------------
-- 6. ...y no se le pueden agregar después
-- ---------------------------------------------------------------------------
-- Sin esto, cp_insert (mig 002: `es_admin() OR preventista_id = auth.uid()`)
-- deja que el preventista se auto-asigne y rompa la exclusividad. No le
-- alcanzaría para VER al cliente (la RLS de arriba pide además que no esté
-- reservado), pero deja la fila contradictoria en la base.

-- SECURITY DEFINER a proposito: como INVOKER el SELECT sobre `clientes` pasa por
-- la RLS del que inserta, que justamente NO ve al cliente reservado. El guard
-- devolveria "no existe" y dejaria pasar el INSERT: fail-open.
CREATE OR REPLACE FUNCTION public.cliente_preventistas_no_reservado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM clientes c WHERE c.id = NEW.cliente_id AND c.reservado_admin) THEN
    RAISE EXCEPTION 'El cliente % está reservado a administración: no admite preventistas asignados', NEW.cliente_id
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cliente_preventistas_no_reservado ON public.cliente_preventistas;
CREATE TRIGGER trg_cliente_preventistas_no_reservado
  BEFORE INSERT OR UPDATE ON public.cliente_preventistas
  FOR EACH ROW
  EXECUTE FUNCTION public.cliente_preventistas_no_reservado();

-- ---------------------------------------------------------------------------
-- 7. Ningún preventista le carga un pedido
-- ---------------------------------------------------------------------------
-- `crear_pedido_completo` NO valida ninguna regla de asignación (agujero
-- preexistente: hoy un preventista puede cargarle un pedido a un cliente
-- asignado a otro si conoce el id — ver issue). Esta feature lo volvería
-- visible: el front oculta el cliente y el RPC igual aceptaría el pedido.
--
-- Va como trigger sobre `pedidos` y no adentro del RPC a propósito:
--   * cubre `crear_pedido_completo` Y `crear_pedido_completo_bot` de una;
--   * no toca el cuerpo vivo de ninguno de los dos — la mig 205 le inyecta
--     código a `crear_pedido_completo` con `_mig205_insertar_tras_ancla`, así
--     que copiar el cuerpo del repo revertiría lógica viva;
--   * el bot corre con service_role y BYPASSEA la RLS, así que no se puede
--     exentar por `current_user` como hacen los guards de la 080.
-- Un trigger no necesita EXECUTE para nadie: lo invoca el executor como parte
-- del DML.
--
-- Se decide por `pedidos.usuario_id` (el autor de la venta), no por auth.uid():
-- en el camino del bot auth.uid() es NULL. Es además la columna a la que la
-- app le atribuye la venta.

-- SECURITY DEFINER por lo mismo: lee `clientes` (que la RLS le tapa al
-- preventista) y `perfiles` (donde solo ve el suyo). Como INVOKER los dos EXISTS
-- darian false y el guard dejaria pasar todo.
CREATE OR REPLACE FUNCTION public.pedidos_cliente_reservado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.cliente_id IS NULL OR NEW.usuario_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (SELECT 1 FROM clientes c WHERE c.id = NEW.cliente_id AND c.reservado_admin)
     AND EXISTS (SELECT 1 FROM perfiles p WHERE p.id = NEW.usuario_id AND p.rol IN ('preventista'))
  THEN
    RAISE EXCEPTION 'El cliente % está reservado a administración: no se le pueden cargar pedidos desde un preventista', NEW.cliente_id
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pedidos_cliente_reservado ON public.pedidos;
CREATE TRIGGER trg_pedidos_cliente_reservado
  BEFORE INSERT ON public.pedidos
  FOR EACH ROW
  EXECUTE FUNCTION public.pedidos_cliente_reservado();

-- ---------------------------------------------------------------------------
-- 8. El bot bypassea la RLS: cada filtro se repite a mano
-- ---------------------------------------------------------------------------
-- Misma familia de bug que la 203 (el bot seguía ofreciendo clientes inactivos).
-- Sin esto el preventista pide el cliente por Telegram y lo obtiene igual.
--
-- Un cliente reservado no tiene asignaciones, o sea que es HUÉRFANO: cae justo
-- en la rama `OR NOT EXISTS(...)` que estas funciones usan para mostrárselo a
-- cualquier preventista. Por eso hay que tocarlas.
--
-- NO hace falta tocar `bot_mis_clientes` ni `bot_sugerir_visitas_rfm`: las dos
-- hacen INNER JOIN contra cliente_preventistas, así que un cliente sin
-- asignaciones nunca aparece.
--
-- El conjunto nuevo va SUELTO, como AND aparte de la lógica de asignación, para
-- no alterar en nada el comportamiento actual de los clientes no reservados.
-- `p_rol` incluye 'encargado' porque en el bot el encargado NO entra por la
-- rama de admin (`p_rol = 'admin'`) y sin embargo tiene que ver al reservado.

CREATE OR REPLACE FUNCTION public.bot_buscar_cliente(
  p_q text, p_perfil_id uuid, p_rol text, p_sucursal_id bigint, p_limit integer DEFAULT 10
)
RETURNS TABLE(id bigint, codigo integer, nombre_fantasia text, razon_social text,
              saldo_cuenta numeric, direccion text, zona text, sucursal_id bigint)
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
    c.direccion, c.zona, c.sucursal_id
  FROM clientes c, terms t
  WHERE
    c.sucursal_id = p_sucursal_id
    -- Baja logica: un cliente desactivado no se ofrece para operar. Su historial
    -- sigue intacto y visible en los reportes, que no pasan por aca.
    AND c.activo = TRUE
    AND (
      p_rol = 'admin'
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

REVOKE ALL ON FUNCTION public.bot_buscar_cliente(text, uuid, text, bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_buscar_cliente(text, uuid, text, bigint, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.bot_historico_pedidos_cliente(
  p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint,
  p_dias integer DEFAULT 90, p_limit integer DEFAULT 20
)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
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
    'pedidos', COALESCE(
      (SELECT json_agg(row_to_json(p.*) ORDER BY p.created_at DESC) FROM pedidos_con_items p),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.bot_historico_pedidos_cliente(bigint, uuid, text, bigint, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_historico_pedidos_cliente(bigint, uuid, text, bigint, integer, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.bot_productos_recurrentes_cliente(
  p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint,
  p_dias integer DEFAULT 90, p_limit integer DEFAULT 10
)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE resultado JSON;
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
    SELECT pi.producto_id, pi.cantidad, pi.subtotal, pe.id AS pedido_id
    FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
    WHERE pe.cliente_id = p_cliente_id AND pe.sucursal_id = p_sucursal_id
      AND pe.created_at > now() - (p_dias || ' days')::INTERVAL
      AND COALESCE(pe.estado, '') NOT IN ('cancelado', 'anulado')
  ),
  ranked AS (
    SELECT p.id, p.codigo, p.nombre, p.precio,
      COUNT(DISTINCT ip.pedido_id) AS pedidos_con_producto,
      SUM(ip.cantidad) AS unidades_totales,
      SUM(ip.subtotal) AS facturado_total
    FROM items_periodo ip JOIN productos p ON p.id = ip.producto_id
    GROUP BY p.id, p.codigo, p.nombre, p.precio
    ORDER BY COUNT(DISTINCT ip.pedido_id) DESC, SUM(ip.cantidad) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id, 'rango_dias', p_dias,
    'productos', COALESCE((SELECT json_agg(row_to_json(r.*)) FROM ranked r), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.bot_productos_recurrentes_cliente(bigint, uuid, text, bigint, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_productos_recurrentes_cliente(bigint, uuid, text, bigint, integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Visitas: no se marca visita a un cliente reservado
-- ---------------------------------------------------------------------------
-- registrar_visita_cliente es SECURITY DEFINER y corre como postgres, o sea que
-- la RLS de clientes no la frena: replica la regla a mano, igual que el bot.

CREATE OR REPLACE FUNCTION public.registrar_visita_cliente(
  p_cliente_id bigint, p_status text, p_lat numeric DEFAULT NULL::numeric,
  p_lng numeric DEFAULT NULL::numeric, p_accuracy numeric DEFAULT NULL::numeric,
  p_capturado_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_motivo_omision text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_cliente RECORD;
  v_autorizado boolean;
  v_visita_id bigint;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_status NOT IN ('ok','denied','unavailable','timeout','error') THEN
    RETURN jsonb_build_object('success', false, 'error', 'gps_status invalido');
  END IF;
  IF p_status = 'ok' AND (p_lat IS NULL OR p_lng IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'lat y lng requeridos cuando status=ok');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role NOT IN ('preventista', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rol no autorizado para marcar visitas');
  END IF;

  SELECT id, sucursal_id, reservado_admin INTO v_cliente FROM clientes WHERE id = p_cliente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente no existe');
  END IF;
  IF v_cliente.sucursal_id IS DISTINCT FROM v_sucursal THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente fuera de la sucursal activa');
  END IF;

  IF v_user_role IN ('preventista') THEN
    SELECT (
      NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id)
      OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id AND cp.preventista_id = v_user_id)
    ) INTO v_autorizado;
    IF NOT v_autorizado THEN
      RETURN jsonb_build_object('success', false, 'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214). Sin excepcion de historial: marcar
    -- una visita es operar, no consultar el pasado.
    IF v_cliente.reservado_admin THEN
      RETURN jsonb_build_object('success', false, 'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  INSERT INTO visitas_cliente (
    preventista_id, cliente_id, sucursal_id,
    gps_lat, gps_lng, gps_accuracy, gps_capturado_at, gps_status, gps_motivo_omision
  ) VALUES (
    v_user_id, p_cliente_id, v_sucursal,
    CASE WHEN p_status = 'ok' THEN p_lat ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_lng ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_accuracy ELSE NULL END,
    COALESCE(p_capturado_at, now()),
    p_status,
    CASE WHEN p_status = 'ok' THEN NULL ELSE p_motivo_omision END
  ) RETURNING id INTO v_visita_id;

  RETURN jsonb_build_object('success', true, 'visita_id', v_visita_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 9bis. ACL de las funciones de trigger
-- ---------------------------------------------------------------------------
-- Toda funcion nueva de `public` nace con EXECUTE para PUBLIC (esa entrada
-- `=X/postgres` sin grantee) y Supabase le agrega `authenticated` por separado:
-- hay que revocar las dos mitades acá, en la misma migración. Es exactamente lo
-- que la mig 212 se olvidó y la 213 tuvo que venir a cerrar.
--
-- Una función de trigger no necesita EXECUTE para NADIE: la invoca el executor
-- como parte del DML, no el caller. Quedan en postgres + service_role, igual que
-- `clientes_proteger_columnas_preventista` (080) y `completar_origen_precio_item` (148).

REVOKE ALL ON FUNCTION public.clientes_reservado_solo_admin()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clientes_reservado_limpia_asignaciones()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cliente_preventistas_no_reservado()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pedidos_cliente_reservado()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 10. Verificación de ACL (gate de CI: scripts/check-permisos.mjs)
-- ---------------------------------------------------------------------------
-- Las funciones de trigger (4, 5, 6, 7) NO necesitan EXECUTE para nadie: las
-- invoca el executor como parte del DML, no el caller. Quedan en postgres.

DO $verif$
DECLARE
  v_nombre text;
  v_acl text;
  v_esperado text;
BEGIN
  FOR v_nombre, v_esperado IN
    SELECT * FROM (VALUES
      ('bot_buscar_cliente', 'service_role'),
      ('bot_historico_pedidos_cliente', 'service_role'),
      ('bot_productos_recurrentes_cliente', 'service_role'),
      ('registrar_visita_cliente', 'authenticated')
    ) AS t(nombre, esperado)
  LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_nombre;

    IF v_acl IS NULL THEN
      RAISE EXCEPTION '% quedo con ACL default (PUBLIC ejecuta)', v_nombre;
    END IF;
    IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC: %', v_nombre, v_acl;
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por anon: %', v_nombre, v_acl;
    END IF;
    IF v_acl NOT LIKE '%' || v_esperado || '=X%' THEN
      RAISE EXCEPTION '% no quedo ejecutable por %: %', v_nombre, v_esperado, v_acl;
    END IF;
  END LOOP;

  -- Las de trigger no deben tener EXECUTE para authenticated ni anon.
  FOR v_nombre IN
    SELECT unnest(ARRAY['clientes_reservado_solo_admin',
                        'clientes_reservado_limpia_asignaciones',
                        'cliente_preventistas_no_reservado',
                        'pedidos_cliente_reservado'])
  LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_nombre;

    IF v_acl IS NULL OR v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION 'trigger % quedo ejecutable por PUBLIC: %', v_nombre, coalesce(v_acl, '(default)');
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION 'trigger % quedo ejecutable por anon: %', v_nombre, v_acl;
    END IF;
  END LOOP;
END
$verif$;

COMMIT;
