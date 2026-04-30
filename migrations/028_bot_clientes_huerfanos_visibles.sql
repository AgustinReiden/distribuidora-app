-- Migración 028 — Bot Telegram: preventistas pueden consultar clientes huérfanos
--
-- Regla nueva (decisión de negocio): un preventista, desde el bot, puede ver
-- los clientes que:
--   (a) están asignados a él en cliente_preventistas, O
--   (b) NO están asignados a NINGÚN preventista (huérfanos).
--
-- NO puede ver clientes asignados a OTRO preventista.
--
-- Motivo: en la práctica los preventistas venden a clientes de paso o sin
-- asignación formal (snapshot real: Christian vendió a 89 clientes en abril,
-- solo 3 figuran en cliente_preventistas). Sin esta regla el bot diría
-- "Cliente no asignado a este preventista" para 86 de esos 89, lo que
-- rompe la UX. La data muestra 401 huérfanos vs 26 asignados — casi todo
-- el universo es huérfano.
--
-- Cambios solo en RPCs (no toca tablas ni constraints):
--   * bot_buscar_cliente            → amplía la cláusula EXISTS de cliente_preventistas
--   * bot_historico_pedidos_cliente → idem en el guard inicial
--   * bot_productos_recurrentes_cliente → idem
--
-- IMPORTANTE — `bot_mis_clientes` y `bot_sugerir_visitas_rfm` NO cambian:
-- siguen mostrando solo los asignados (su "cartera"). El preventista PUEDE
-- consultar un huérfano si pregunta por él, pero NO aparece en la lista
-- automática de su cartera. Es la separación correcta: lookup vs cartera.

CREATE OR REPLACE FUNCTION public.bot_buscar_cliente(
  p_q          text,
  p_perfil_id  uuid,
  p_rol        text,
  p_sucursal_id bigint,
  p_limit      integer DEFAULT 10
)
RETURNS TABLE(
  id bigint, codigo integer, nombre_fantasia text, razon_social text,
  saldo_cuenta numeric, direccion text, zona text, sucursal_id bigint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
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
    AND (
      p_rol = 'admin'
      OR EXISTS(
        SELECT 1 FROM cliente_preventistas cp
        WHERE cp.cliente_id = c.id AND cp.preventista_id = p_perfil_id
      )
      -- Nuevo: huérfanos (sin asignación a ningún preventista) son visibles
      -- para cualquier preventista de la misma sucursal.
      OR NOT EXISTS(
        SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id
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
$$;

CREATE OR REPLACE FUNCTION public.bot_historico_pedidos_cliente(
  p_cliente_id  bigint,
  p_perfil_id   uuid,
  p_rol         text,
  p_sucursal_id bigint,
  p_dias        integer DEFAULT 90,
  p_limit       integer DEFAULT 20
)
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  -- Gate: si es preventista, debe estar asignado a este cliente O el cliente
  -- debe ser huérfano (sin asignación a ningún preventista). Asignados a otro
  -- preventista quedan bloqueados.
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
$$;

CREATE OR REPLACE FUNCTION public.bot_productos_recurrentes_cliente(
  p_cliente_id  bigint,
  p_perfil_id   uuid,
  p_rol         text,
  p_sucursal_id bigint,
  p_dias        integer DEFAULT 90,
  p_limit       integer DEFAULT 10
)
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE resultado JSON;
BEGIN
  -- Mismo gate que historico_pedidos_cliente: asignado a mí o huérfano.
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
$$;
