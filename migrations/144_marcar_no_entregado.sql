-- =========================================================================
-- 144_marcar_no_entregado.sql
--
-- Le da al chofer la acción que no existía: "no pude entregar", con motivo.
--
-- El pedido NO se cancela: se libera (vuelve a 'pendiente', sin transportista
-- ni orden) para que entre al pool de "Armar ruta" del día siguiente. La venta
-- sigue viva; hoy en cambio se perdía porque alguien la cancelaba a mano.
--
-- La parada queda en el recorrido con estado_entrega='no_entregado' + motivo:
-- es el registro de que se intentó y falló, que es lo que permite medir
-- rechazos por barrida y saber si el ruteo nuevo sirvió.
--
-- Además notifica al preventista dueño del pedido (pedidos.usuario_id) con el
-- motivo, que es el pedido explícito del dueño: "que vean el detalle de por
-- qué ha sido cancelado, para evitar el choque entre preventa y reparto".
-- =========================================================================

CREATE OR REPLACE FUNCTION public.marcar_no_entregado(
  p_pedido_id bigint,
  p_motivo    varchar,
  p_nota      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal      bigint := current_sucursal_id();
  v_rol           text;
  v_uid           uuid := auth.uid();
  v_transportista uuid;
  v_usuario_id    uuid;
  v_estado        text;
  v_cliente       text;
  v_paradas       int;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF p_motivo IS NULL OR p_motivo NOT IN (
    'cerrado', 'sin_dinero', 'cliente_rechaza', 'ausente',
    'direccion_incorrecta', 'clima', 'otro'
  ) THEN
    RAISE EXCEPTION 'Motivo de no entrega inválido: %', COALESCE(p_motivo, '(vacío)');
  END IF;

  -- "otro" sin explicación no sirve para nada: es el que después nadie entiende.
  IF p_motivo = 'otro' AND (p_nota IS NULL OR length(trim(p_nota)) < 3) THEN
    RAISE EXCEPTION 'Si el motivo es "otro" hay que escribir qué pasó';
  END IF;

  SELECT p.transportista_id, p.usuario_id, p.estado, c.nombre_fantasia
    INTO v_transportista, v_usuario_id, v_estado, v_cliente
  FROM pedidos p
  LEFT JOIN clientes c ON c.id = p.cliente_id
  WHERE p.id = p_pedido_id AND p.sucursal_id = v_sucursal;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido % no encontrado en esta sucursal', p_pedido_id;
  END IF;

  IF v_estado = 'entregado' THEN
    RAISE EXCEPTION 'El pedido % ya figura entregado', p_pedido_id;
  END IF;

  -- Lo puede marcar el chofer al que se le asignó, o un admin/encargado.
  SELECT rol INTO v_rol FROM perfiles WHERE id = v_uid;
  IF NOT (v_transportista = v_uid OR v_rol IN ('admin', 'encargado')) THEN
    RAISE EXCEPTION 'Solo el transportista asignado o un encargado puede marcar la no entrega'
      USING ERRCODE = '42501';
  END IF;

  -- 1) Queda el registro del intento fallido en la ruta.
  UPDATE recorrido_pedidos rp
  SET estado_entrega    = 'no_entregado',
      motivo_no_entrega = p_motivo,
      nota_no_entrega   = NULLIF(trim(COALESCE(p_nota, '')), ''),
      hora_entrega      = now()
  FROM recorridos r
  WHERE rp.recorrido_id = r.id
    AND rp.pedido_id = p_pedido_id
    AND rp.sucursal_id = v_sucursal
    AND r.estado = 'en_curso';
  GET DIAGNOSTICS v_paradas = ROW_COUNT;

  -- 2) Se libera el pedido para poder re-rutearlo. No se cancela.
  UPDATE pedidos
  SET estado           = 'pendiente',
      transportista_id = NULL,
      orden_entrega    = NULL
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  -- 3) Aviso al preventista dueño de la venta, con el motivo.
  IF v_usuario_id IS NOT NULL AND v_usuario_id <> v_uid THEN
    INSERT INTO notificaciones (
      usuario_id, sucursal_id, tipo, titulo, mensaje, entidad_tipo, entidad_id, payload
    ) VALUES (
      v_usuario_id, v_sucursal, 'pedido_no_entregado',
      'Pedido no entregado',
      format('El pedido #%s de %s no se pudo entregar: %s',
             p_pedido_id, COALESCE(v_cliente, 'cliente'),
             CASE p_motivo
               WHEN 'cerrado'              THEN 'el local estaba cerrado'
               WHEN 'sin_dinero'           THEN 'el cliente no tenía dinero'
               WHEN 'cliente_rechaza'      THEN 'el cliente rechazó el pedido'
               WHEN 'ausente'              THEN 'no había nadie'
               WHEN 'direccion_incorrecta' THEN 'la dirección es incorrecta'
               WHEN 'clima'                THEN 'por el clima'
               ELSE COALESCE(NULLIF(trim(COALESCE(p_nota, '')), ''), 'otro motivo')
             END),
      'pedido', p_pedido_id,
      jsonb_build_object('pedido_id', p_pedido_id, 'motivo', p_motivo, 'nota', p_nota)
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'pedido_id', p_pedido_id,
    'motivo', p_motivo,
    'paradas_marcadas', v_paradas
  );
END;
$fn$;

ALTER FUNCTION public.marcar_no_entregado(bigint, varchar, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.marcar_no_entregado(bigint, varchar, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marcar_no_entregado(bigint, varchar, text) TO authenticated;

COMMENT ON FUNCTION public.marcar_no_entregado(bigint, varchar, text) IS
  'El chofer marca que no pudo entregar, con motivo tipificado. Libera el pedido para re-rutear y avisa al preventista. Mig 144.';
