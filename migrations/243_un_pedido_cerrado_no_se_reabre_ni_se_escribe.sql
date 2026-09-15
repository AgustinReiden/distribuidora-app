-- =========================================================================
-- 243_un_pedido_cerrado_no_se_reabre_ni_se_escribe.sql
--
-- Cuatro guards de permisos y de estado. Ninguno cambia un número: todos
-- cierran un camino que la UI no ofrece y la base aceptaba. Issues #636, #637
-- y #638.
--
-- ---------------------------------------------------------------------------
-- 1 · marcar_no_entregado revivía un cancelado como venta viva de $0  (#636)
-- ---------------------------------------------------------------------------
-- La 144 sólo rechaza `v_estado = 'entregado'`. Todo lo demás pasa, y el UPDATE
-- que sigue es incondicional: `estado='pendiente', transportista_id=NULL,
-- orden_entrega=NULL`. Sobre un pedido cancelado eso lo devuelve al pool de
-- "Armar ruta" con `total = 0`, `total_real = 0` y los pagos ya desimputados
-- (mig 235): una venta viva de cero pesos que la compra mínima nunca va a
-- validar, porque el mínimo se valida AL CREAR y no como constraint ni como
-- trigger sobre el total (trampa 8 de CLAUDE.md, migs 204/205). Ningún trigger
-- de `pedidos` valida transiciones de estado, así que no hay segunda red.
-- El estado terminal se lee de la lista que ya usa `actualizar_pedido_items`
-- desde la 181: `('cancelado', 'anulado')`.
--
-- Y de paso el `v_paradas = 0` silencioso. El UPDATE sobre `recorrido_pedidos`
-- está acotado a `r.estado = 'en_curso'`: si el pedido no es parada de ninguna
-- hoja de ruta en curso no toca ninguna fila, el ROW_COUNT queda en 0 y la
-- función igual libera el pedido, notifica al preventista y devuelve
-- `success: true` con `paradas_marcadas: 0`. O sea: se pierde el registro del
-- intento fallido —que es la razón de ser de la 144, medir rechazos por
-- barrida— y el llamador no se entera. El único caller es
-- `RutaActivaTransportista` sobre una parada de la ruta activa, así que un 0 acá
-- no es un caso de uso: es la señal de que la ruta ya se cerró o de que la
-- llamada no vino de donde dice venir.
--
-- ---------------------------------------------------------------------------
-- 2 · pedido_items: el INSERT no tenía guard de estado ni de ventana  (#637)
-- ---------------------------------------------------------------------------
-- La 233 dejó `mt_pedido_items_insert` bien: `sucursal_id =
-- current_sucursal_id() AND (es_encargado_o_admin() OR EXISTS (pedido propio))`.
-- La policy no se toca — acota QUÉ FILAS y eso ya está resuelto. Lo que falta es
-- CUÁNDO, y ahí la 233 sólo puso `pedido_items_proteger_columnas`, que es BEFORE
-- **UPDATE**. Su comentario lo dice con todas las letras: "Sólo UPDATE: en el
-- alta no hay nada que comparar, y quién puede insertar contra qué pedido ya lo
-- decide el WITH CHECK de arriba". El WITH CHECK decide el quién y el dónde; no
-- mira el estado del pedido ni el reloj.
--
-- Entonces un preventista puede, a cualquier hora, hacer
-- `POST /pedido_items {pedido_id: <uno suyo, ya entregado>, producto_id,
-- cantidad, precio_unitario}`. Los dos triggers que ya corren en el alta no lo
-- frenan: `validar_minimo_venta_item` mira la unidad mínima del producto y
-- `validar_precio_item_pedido` mira el precio contra la lista; ninguno mira
-- `pedidos.estado` ni la ventana. `pedidos.total` no se mueve
-- (`pedidos_proteger_columnas`, mig 181), así que el pedido no "vale" más — pero
-- `calcular_comisiones` y `avance_metas_preventista` suman el subtotal de los
-- ITEMS, no el total del pedido. Es plata, y es la propia.
--
-- El guard va en trigger y no en la policy a propósito: la policy sólo la evalúa
-- PostgREST, y el trigger cubre además cualquier camino por RPC que no sea
-- SECURITY DEFINER. Hoy los cuatro escritores de `pedido_items`
-- (`crear_pedido_completo`, `crear_pedido_completo_bot`,
-- `actualizar_pedido_items`, `anular_salvedad`) SÍ son SECURITY DEFINER y por
-- eso quedan exentos por `current_user <> 'authenticated'` — el mismo mecanismo
-- y la misma razón que documenta la 181 §1 —, así que el alta legítima (incluida
-- la de después de las 15:30, que la ventana rige la EDICIÓN y no la carga) no
-- cambia en nada. El que queda cubierto es el INSERT crudo, que no tiene un solo
-- caller legítimo.
--
-- El criterio es copiado del cuerpo VIVO de `actualizar_pedido_items`, no del
-- archivo 033: la 181 le agregó los estados terminales y la ruta en curso, y la
-- 045 bajó el corte de las 17:00 a las 15:30. Las cuatro partes:
--   a) no 'entregado'                          (033)
--   b) no 'cancelado' ni 'anulado'             (181)
--   c) no en una hoja de ruta 'en_curso'       (181, sólo para los no encargado/admin)
--   d) mismo día ARG que `created_at` y hora ARG < 15:30   (033 + 045)
-- La quinta —"sólo el preventista que creó el pedido"— no se repite acá porque
-- es exactamente el EXISTS del WITH CHECK de la 233, que ya corre sobre el mismo
-- INSERT.
--
-- Dos notas sobre la lectura dentro del trigger:
--   * la función NO es SECURITY DEFINER, o `current_user` sería siempre el dueño
--     y la exención de arriba no filtraría nada (181 §1). Corolario: sus SELECT
--     corren con la RLS del caller. Sobre `pedidos` eso es fail-closed —si no ve
--     el pedido, rechaza—; sobre `recorridos` no, y por eso (c) es una red
--     adicional y no el guard principal: el que manda es (d).
--   * se llama `pedido_items_guard_estado` y no `trg_*` para que el orden
--     alfabético de los BEFORE INSERT lo ponga primero, antes de los cuatro
--     `trg_*` que completan y validan la fila.
--
-- ---------------------------------------------------------------------------
-- 3 · cdc_select: acotado por sucursal, no por rol  (#638)
-- ---------------------------------------------------------------------------
-- La 228 cambió `cdc_select` de `USING (true)` a
-- `cliente_de_sucursal_activa(cliente_id)`, que era la fuga grande (cualquier
-- logueado de cualquier sucursal leía los descuentos pactados de todos los
-- clientes). Quedó sin criterio de rol, así que un transportista lee lo que cada
-- cliente de su sucursal tiene pactado.
--
-- En `cp_select` la propia 228 explica por qué NO filtra por rol: si un
-- preventista deja de ver las filas de sus colegas, el `NOT EXISTS` de
-- `mt_clientes_select` (mig 028) da true y los clientes ajenos se le vuelven
-- huérfanos → visibles. Medido: de 209 a 588 clientes. Acá ese argumento no
-- aplica: ninguna otra policy consulta `cliente_descuentos_categoria`. Por eso
-- se toca ésta y no `cp_select`.
--
-- Quién necesita los descuentos PARA OPERAR: el preventista al armar o editar el
-- pedido (`resolverDescuentoPctCliente` / `aplicarDescuentoClienteItems`, que
-- usan `ModalPedido`, `ModalEditarPedido` y `ModalCambiarCliente`), el encargado
-- y el admin (el panel de clientes). El transportista no: en la app no hay un
-- solo consumidor de `descuentos_categoria` que él pueda abrir — la comanda y la
-- hoja de ruta imprimen los precios GUARDADOS en `pedido_items`, no los
-- recotizan.
--
-- Verificado en los logs de prod (edge_logs, 24 h): las filas viajan hoy por dos
-- embeds que el transportista sí dispara —`PEDIDO_SELECT` en `/rest/v1/pedidos`
-- y en `/rest/v1/recorridos?transportista_id=eq.…`, que es su ruta activa—, pero
-- viajan y no se leen. Con la policy nueva ese embed anidado devuelve `[]` en vez
-- de filas; no rompe la consulta (un embed vacío por RLS no es el `PGRST201` de
-- la trampa 5, que es otra cosa: dos FKs a la misma tabla).
--
-- `es_preventista()` incluye a admin y encargado (trampa 4) y también a quien
-- tenga el rol extra en `perfil_roles`, que es justo lo que se quiere: el
-- transportista que además vende lo sigue viendo. Se deja igual
-- `es_encargado_o_admin()` al frente para que la intención quede escrita.
--
-- ---------------------------------------------------------------------------
-- 4 · es_admin() y es_encargado_o_admin() eran VOLATILE  (#638)
-- ---------------------------------------------------------------------------
-- Las nombran 99 y 22 policies. VOLATILE le prohíbe al planner cachear el
-- resultado dentro de la consulta, así que cada fila evaluada repite el SELECT
-- sobre `perfiles`. Sus tres hermanas (`es_preventista`, `es_transportista`,
-- `current_sucursal_id`) ya son STABLE.
--
-- Va por `ALTER FUNCTION`, NO por `CREATE OR REPLACE`: reescribir el cuerpo de
-- un helper de rol es exactamente como se revierte el multi-rol en silencio
-- (trampa 4). `ALTER FUNCTION ... STABLE` cambia `provolatile` y no toca ni una
-- línea del body.
-- =========================================================================

-- ── 1 · marcar_no_entregado ────────────────────────────────────────────────
-- Anclada sobre el cuerpo vivo (idéntico al archivo 144). Cambian dos cosas:
-- el IF de estados terminales y el IF de v_paradas. El resto es literal.

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

  -- Mig 243: un cancelado/anulado ya tiene el stock devuelto, el total en 0 y
  -- los pagos desimputados (mig 235). Volverlo a 'pendiente' lo resucita como
  -- venta viva de $0, que es lo que la compra mínima no puede validar después
  -- (se valida al crear, trampa 8). Si hay que re-entregarlo, se crea uno nuevo
  -- — la misma salida que da `actualizar_pedido_items` desde la 181.
  IF v_estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El pedido % está % y no se puede reabrir desde el reparto: creá uno nuevo',
      p_pedido_id, v_estado
      USING ERRCODE = '42501';
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

  -- Mig 243: sin parada marcada no hay nada que registrar, y liberar el pedido
  -- igual deja el intento fallido sin rastro (que es lo que la 144 vino a medir)
  -- devolviendo success: true. Aborta en vez de seguir de largo.
  IF v_paradas = 0 THEN
    RAISE EXCEPTION 'El pedido % no es una parada de ninguna hoja de ruta en curso de esta sucursal: no hay no-entrega que registrar',
      p_pedido_id
      USING ERRCODE = '42501';
  END IF;

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
REVOKE ALL ON FUNCTION public.marcar_no_entregado(bigint, varchar, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_no_entregado(bigint, varchar, text) TO authenticated;

COMMENT ON FUNCTION public.marcar_no_entregado(bigint, varchar, text) IS
  'El chofer marca que no pudo entregar, con motivo tipificado. Libera el pedido para re-rutear y avisa al preventista. Mig 144; guards de estado terminal y de parada inexistente en la 243.';

-- ── 2 · pedido_items: guard de estado y de ventana en el alta ──────────────

CREATE OR REPLACE FUNCTION public.pedido_items_guard_estado()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_estado     text;
  v_created_at timestamptz;
  v_hora_corte CONSTANT time := TIME '15:30';
  v_tz         CONSTANT text := 'America/Argentina/Buenos_Aires';
BEGIN
  -- Las cuatro RPCs que escriben items son SECURITY DEFINER y corren como el
  -- dueño: quedan exentas, cada una con su propio criterio. Ver 181 §1.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  SELECT p.estado, p.created_at
    INTO v_estado, v_created_at
    FROM pedidos p
   WHERE p.id = NEW.pedido_id;

  -- Fail-closed: el SELECT corre con la RLS del caller (esta función no puede
  -- ser SECURITY DEFINER). Si no ve el pedido, tampoco le agrega items.
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No tenes permiso para agregarle items al pedido %', NEW.pedido_id
      USING ERRCODE = '42501';
  END IF;

  IF v_estado = 'entregado' THEN
    RAISE EXCEPTION 'No se le pueden agregar items a un pedido ya entregado (#%). Lo que cambia despues de la entrega se registra como salvedad.',
      NEW.pedido_id
      USING ERRCODE = '42501';
  END IF;

  IF v_estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'No se le pueden agregar items a un pedido % (#%). Crea uno nuevo.',
      v_estado, NEW.pedido_id
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM recorrido_pedidos rp
      JOIN recorridos r ON r.id = rp.recorrido_id
     WHERE rp.pedido_id = NEW.pedido_id
       AND r.estado = 'en_curso'
  ) THEN
    RAISE EXCEPTION 'El pedido #% ya esta en una hoja de ruta armada. Pedile a un encargado que lo modifique.',
      NEW.pedido_id
      USING ERRCODE = '42501';
  END IF;

  IF (v_created_at AT TIME ZONE v_tz)::date IS DISTINCT FROM (now() AT TIME ZONE v_tz)::date
     OR (now() AT TIME ZONE v_tz)::time >= v_hora_corte
  THEN
    RAISE EXCEPTION 'Solo se le pueden agregar items a un pedido del dia actual antes de las 15:30 (ARG). El pedido #% es del %.',
      NEW.pedido_id, to_char(v_created_at AT TIME ZONE v_tz, 'DD/MM/YYYY')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$fn$;

ALTER FUNCTION public.pedido_items_guard_estado() OWNER TO postgres;

-- Una función de trigger no necesita EXECUTE para nadie: la invoca el executor
-- como parte del DML, no el caller. Igual que `completar_origen_precio_item`.
REVOKE ALL ON FUNCTION public.pedido_items_guard_estado() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS pedido_items_guard_estado ON public.pedido_items;
CREATE TRIGGER pedido_items_guard_estado
  BEFORE INSERT ON public.pedido_items
  FOR EACH ROW
  EXECUTE FUNCTION public.pedido_items_guard_estado();

COMMENT ON FUNCTION public.pedido_items_guard_estado() IS
  'Guard de estado y de ventana para el INSERT crudo de pedido_items. Copia el criterio vivo de actualizar_pedido_items (033 + 045 + 181). Mig 243, issue #637.';

-- ── 3 · cdc_select: quien necesita los descuentos para operar ──────────────

DROP POLICY IF EXISTS "cdc_select" ON public.cliente_descuentos_categoria;
CREATE POLICY "cdc_select" ON public.cliente_descuentos_categoria
  FOR SELECT TO authenticated
  USING (
    public.cliente_de_sucursal_activa(cliente_id)
    AND (public.es_encargado_o_admin() OR public.es_preventista())
  );

-- ── 4 · los dos helpers de rol pasan a STABLE ──────────────────────────────

ALTER FUNCTION public.es_admin() STABLE;
ALTER FUNCTION public.es_encargado_o_admin() STABLE;
