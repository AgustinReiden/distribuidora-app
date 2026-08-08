-- =========================================================================
-- 172_cambiar_transportista_de_una_ruta.sql
--
-- Reasignar una ruta YA ARMADA a otro transportista, sin rearmarla.
--
-- EL CASO
-- -------
-- En Taco Pozo la ruta del dia la arma el admin la tarde anterior. El 08/08
-- Pablo armo la ruta del 09/08 (18 paradas) a nombre del transportista que
-- estaba disponible en el picker; media hora despues se le habilito a Juan
-- —preventista que acompaña al camion— la capacidad `transportista` (mig 155).
-- La ruta quedo a nombre de quien NO la iba a repartir, y no habia forma de
-- corregirlo: el unico camino era cancelarla y armarla de nuevo.
--
-- POR QUE NO ALCANZABA CON aplicar_orden_ruta
-- -------------------------------------------
-- Esa RPC busca el recorrido por (transportista_id, fecha, estado='en_curso',
-- sucursal_id): el transportista es parte de la IDENTIDAD de la ruta, no un
-- atributo editable. Elegir otro chofer y volver a armar no mueve la ruta,
-- crea una SEGUNDA — y la original queda viva, con sus pedidos en `asignado`,
-- fuera del pool de disponibles.
--
-- QUE HACE ESTA RPC
-- -----------------
-- Mueve la ruta entera de un chofer al otro en una sola transaccion:
-- `recorridos.transportista_id` + el `transportista_id` de cada pedido de sus
-- paradas. No toca el orden de entrega, la optimizacion ni las polylines: la
-- ruta es la misma, cambia quien la reparte.
--
-- GUARDAS
-- -------
--   · es_encargado_o_admin(), igual gate que aplicar_orden_ruta.
--   · La ruta y el destino tienen que ser de la sucursal activa.
--   · El destino tiene que ser transportista HABILITADO ahi: rol base o
--     capacidad extra de la mig 155. Es la misma condicion que arma el picker
--     en el front (fetchTransportistas), replicada server-side para que no
--     dependa de la UI.
--   · Ruta en_curso. Una completada ya se rindio; reabrirla no es un cambio de
--     chofer, es reabrir la caja del dia.
--   · CERO entregas hechas. Si el chofer ya entrego y cobro una parada, la
--     plata de ese dia es suya: mover la ruta partiria la rendicion entre dos
--     personas. Paradas marcadas "no entregado" NO bloquean: no mueven plata y
--     el caso real (se rompio el camion a media mañana) es justamente ese.
--   · El destino no puede tener otra ruta en_curso esa fecha — es
--     `uq_recorrido_vigente`. Se chequea explicito para devolver un mensaje
--     util en vez de un 23505 crudo.
--
-- Idempotente: reasignar al mismo chofer que ya la tiene devuelve el id sin
-- tocar nada, asi un doble click no es un error en pantalla.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.cambiar_transportista_recorrido(
  p_recorrido_id     bigint,
  p_transportista_id uuid
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal   bigint := current_sucursal_id();
  v_recorrido  recorridos%ROWTYPE;
  v_entregadas integer;
  v_conflicto  bigint;
  v_nombre     text;
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado para cambiar el transportista de una ruta'
      USING ERRCODE = '42501';
  END IF;

  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sucursal no resuelta para el usuario actual';
  END IF;

  IF p_transportista_id IS NULL THEN
    RAISE EXCEPTION 'Hay que elegir un transportista';
  END IF;

  -- FOR UPDATE: sin el lock, dos admins reasignando en paralelo pueden pasar
  -- los dos el chequeo de uq_recorrido_vigente y uno se come el 23505.
  SELECT * INTO v_recorrido
  FROM recorridos
  WHERE id = p_recorrido_id
    AND sucursal_id = v_sucursal
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La ruta #% no existe en esta sucursal', p_recorrido_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_recorrido.transportista_id = p_transportista_id THEN
    RETURN p_recorrido_id;  -- ya esta a su nombre: no-op
  END IF;

  IF v_recorrido.estado <> 'en_curso' THEN
    RAISE EXCEPTION 'La ruta #% esta %, solo se puede reasignar una ruta en curso',
      p_recorrido_id, v_recorrido.estado;
  END IF;

  -- Habilitado como transportista EN ESTA SUCURSAL (rol base o mig 155),
  -- activo y asignado aca. Espeja fetchTransportistas() del front.
  SELECT p.nombre INTO v_nombre
  FROM perfiles p
  WHERE p.id = p_transportista_id
    AND p.activo
    AND EXISTS (
      SELECT 1 FROM usuario_sucursales us
      WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal
    )
    AND (
      p.rol = 'transportista'
      OR EXISTS (
        SELECT 1 FROM perfil_roles pr
        WHERE pr.usuario_id  = p.id
          AND pr.sucursal_id = v_sucursal
          AND pr.rol         = 'transportista'
      )
    );

  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El usuario elegido no esta habilitado como transportista en esta sucursal';
  END IF;

  -- Entregas ya hechas: la rendicion del dia quedaria partida entre dos.
  SELECT COUNT(*) INTO v_entregadas
  FROM recorrido_pedidos rp
  JOIN pedidos p ON p.id = rp.pedido_id
  WHERE rp.recorrido_id = p_recorrido_id
    AND (rp.estado_entrega = 'entregado' OR p.estado = 'entregado');

  IF v_entregadas > 0 THEN
    RAISE EXCEPTION
      'La ruta #% ya tiene % entrega(s) hecha(s) por %. Sacale esas paradas o armale una ruta nueva al otro chofer.',
      p_recorrido_id,
      v_entregadas,
      COALESCE((SELECT nombre FROM perfiles WHERE id = v_recorrido.transportista_id), 'el chofer actual');
  END IF;

  -- uq_recorrido_vigente (transportista_id, fecha, sucursal_id) WHERE en_curso
  SELECT id INTO v_conflicto
  FROM recorridos
  WHERE transportista_id = p_transportista_id
    AND fecha            = v_recorrido.fecha
    AND sucursal_id      = v_sucursal
    AND estado           = 'en_curso'
  LIMIT 1;

  IF v_conflicto IS NOT NULL THEN
    RAISE EXCEPTION
      '% ya tiene la ruta #% armada para el %. Pasale las paradas a esa en vez de duplicarla.',
      v_nombre, v_conflicto, to_char(v_recorrido.fecha, 'DD/MM/YYYY');
  END IF;

  UPDATE recorridos
  SET transportista_id = p_transportista_id
  WHERE id = p_recorrido_id;

  -- Los pedidos tambien: `pedidos.transportista_id` es lo que leen la PWA del
  -- chofer, las policies de `pagos` (mig 155) y la rendicion. Sin esto la ruta
  -- cambia de nombre en el listado y el chofer nuevo no la ve.
  -- `estado <> 'entregado'` es defensivo: arriba ya garantizamos que no hay
  -- ninguno, pero deja explicito que una entrega hecha nunca cambia de dueño.
  UPDATE pedidos p
  SET transportista_id = p_transportista_id
  FROM recorrido_pedidos rp
  WHERE rp.recorrido_id = p_recorrido_id
    AND p.id            = rp.pedido_id
    AND p.sucursal_id   = v_sucursal
    AND p.estado <> 'entregado';

  RETURN p_recorrido_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.cambiar_transportista_recorrido(bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cambiar_transportista_recorrido(bigint, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.cambiar_transportista_recorrido(bigint, uuid) IS
  'Reasigna una ruta en_curso a otro transportista de la misma sucursal: '
  'actualiza recorridos.transportista_id y el de los pedidos de sus paradas. '
  'No cambia el orden ni la optimizacion. Rechaza si la ruta ya tiene entregas '
  'hechas o si el destino ya tiene ruta armada esa fecha (uq_recorrido_vigente).';

COMMIT;
