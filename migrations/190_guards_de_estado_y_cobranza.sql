-- =========================================================================
-- 190_guards_de_estado_y_cobranza.sql
--
-- Defensa en profundidad del flujo de entrega y cobro. Nada de esto lo ofrece
-- la UI: son caminos que el token del usuario habilita igual, y que hoy nadie
-- frena. Cierra los hallazgos #5, #6 y #11 de la auditoria adversarial.
--
-- La mig 181 acoto QUE COLUMNAS puede tocar cada rol. Esta acota QUE VALORES
-- puede escribir, y quien puede imputar un cobro contra que boleta.
--
-- NOTA DE LEDGER: en prod esto son DOS filas, `190_guards_de_estado_y_cobranza`
-- y `190b_pagos_forzar_usuario_no_definer`. La segunda corrige el punto 3, que
-- salio SECURITY DEFINER y por eso no forzaba nada (ver el comentario ahi). Este
-- archivo consolida el estado final, como manda migrations/MANIFEST.md.
-- =========================================================================


-- -------------------------------------------------------------------------
-- 1 · `pedidos.estado` no tenia CHECK: cualquier string entraba  (#5)
-- -------------------------------------------------------------------------
-- Sin constraint, un typo o un cliente viejo puede dejar un pedido en
-- 'Entregado' o 'entregado ' y ese pedido desaparece de TODOS los filtros de la
-- app sin error: no esta entregado, no esta pendiente, no esta en ningun lado.
--
-- Los ocho valores salen de cruzar lo que hay en la tabla (entregado,
-- cancelado, asignado, pendiente), lo que escriben las RPCs y el front
-- (los mismos cuatro + en_preparacion) y lo que las queries filtran aunque hoy
-- no se escriba (listo, en_camino, anulado). Se incluyen los tres ultimos a
-- proposito: no cuestan nada y evitan romper un camino que no se ve.
--
-- Verificado antes de aplicar: 0 filas fuera de esta lista.
ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_estado_check
  CHECK (estado IN (
    'pendiente', 'en_preparacion', 'listo', 'asignado',
    'en_camino', 'entregado', 'cancelado', 'anulado'
  ))
  NOT VALID;

-- Se valida aparte para que el ADD no tome un lock largo sobre la tabla.
ALTER TABLE public.pedidos VALIDATE CONSTRAINT pedidos_estado_check;


-- -------------------------------------------------------------------------
-- 2 · El chofer solo puede ENTREGAR, no cambiar el estado a lo que quiera (#5)
-- -------------------------------------------------------------------------
-- `pedidos_proteger_columnas` (mig 181) le permite al transportista escribir la
-- columna `estado`, pero no dice con QUE valor. Con su sesion normal y la
-- consola del navegador podia mandar `estado = 'cancelado'` y borrar de la ruta
-- una entrega que no quiso hacer, o devolverla a 'pendiente'.
--
-- Su pantalla solo escribe 'entregado' (RutaActivaTransportista →
-- onMarcarEntregado → cambiarEstado). El resto de sus acciones —marcar no
-- entregado, salvedades, geolocalizacion— van por RPC SECURITY DEFINER, que
-- esta exenta de este trigger. Asi que restringir el valor no le saca nada.
--
-- QUE **NO** SE TOCA: `fecha_entrega`. La UI ofrece a proposito elegir una fecha
-- anterior ("define en que dia se contabiliza") y el chofer pasa por ese mismo
-- modal. Restringirla romperia una funcion real. El lado plata ya esta cubierto
-- por `guard_pago_fecha_cerrada`, que rechaza cobros contra una caja cerrada.
CREATE OR REPLACE FUNCTION public.pedidos_proteger_columnas()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_bloqueadas text;
BEGIN
  -- RPCs SECURITY DEFINER, service_role, conexiones directas: exentas.
  -- Sin esto se romperia marcar_no_entregado / registrar_salvedad /
  -- registrar_geolocalizacion_pedido, que son del chofer y escriben otras columnas.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- Cascadas desde otros triggers (monto_pagado desde pagos): exentas.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  IF es_transportista() THEN
    -- Lista blanca: es exactamente lo que escribe `actualizarEstado` en el front.
    SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
    FROM jsonb_each(to_jsonb(OLD)) o
    JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
    WHERE o.value IS DISTINCT FROM n.value
      AND o.key NOT IN ('estado', 'fecha_entrega', 'updated_at');

    IF v_bloqueadas IS NOT NULL THEN
      RAISE EXCEPTION 'Un transportista solo puede confirmar la entrega. Columnas rechazadas: %',
        v_bloqueadas
        USING ERRCODE = '42501';
    END IF;

    -- NUEVO (mig 190): ademas del que columnas, el que valores. Confirmar una
    -- entrega es lo unico que su pantalla hace; cancelar o revertir no.
    IF NEW.estado IS DISTINCT FROM OLD.estado AND NEW.estado <> 'entregado' THEN
      RAISE EXCEPTION 'Un transportista solo puede marcar la entrega, no pasar el pedido a "%"',
        NEW.estado
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  -- Resto de los no-admin (preventista): lista NEGRA de plata e identidad. Lo
  -- operativo (notas, fechas) sigue abierto porque es lo que la UI les ofrece.
  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key IN (
      'total', 'total_neto', 'total_iva', 'total_real', 'monto_pagado',
      'estado_pago', 'cliente_id', 'sucursal_id', 'usuario_id', 'creado_por',
      'preventista_id', 'tipo_factura', 'stock_descontado', 'offline_id'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'No tenes permiso para modificar estas columnas de pedidos: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;


-- -------------------------------------------------------------------------
-- 3 · Quien cobro lo decide el servidor, no el navegador  (#6)
-- -------------------------------------------------------------------------
-- `pagos.usuario_id` es nullable, sin default y sin trigger: la atribucion del
-- cobro viajaba desde el front (`registrarPago` manda `pago.usuarioId`). En una
-- operacion de efectivo con rendicion por chofer, eso significa que quien
-- registra elige a nombre de quien queda la plata — o de nadie. Hay 61 pagos
-- historicos con `usuario_id` NULL (el ultimo del 2026-04-22; la practica ya se
-- corrigio sola, pero el mecanismo seguia abierto).
--
-- Se exime a las RPCs SECURITY DEFINER, que ya resuelven el actor server-side,
-- y se le deja al admin poder imputar explicitamente a otro (cargar el cobro de
-- un chofer que rindio en papel).
-- NO es SECURITY DEFINER, y eso es deliberado: adentro de una funcion DEFINER
-- `current_user` pasa a ser el dueño de la funcion, nunca 'authenticated', asi
-- que la exencion de abajo se cumpliria SIEMPRE y el trigger no forzaria nada.
-- (Se escribio DEFINER primero y el test lo agarro: el insert con un usuario_id
-- inventado paso derecho hasta chocar contra la FK.) Mismo motivo por el que
-- `pedidos_proteger_columnas` tampoco lo es. `es_admin()` sigue funcionando
-- porque esa SI es DEFINER.
CREATE OR REPLACE FUNCTION public.pagos_forzar_usuario()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  -- RPCs SECURITY DEFINER y service_role: ya resuelven el actor server-side.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- El admin puede atribuir a otro; el resto, no.
  IF es_admin() AND NEW.usuario_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  NEW.usuario_id := auth.uid();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_pagos_forzar_usuario ON public.pagos;
CREATE TRIGGER trg_pagos_forzar_usuario
  BEFORE INSERT ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.pagos_forzar_usuario();

COMMENT ON FUNCTION public.pagos_forzar_usuario() IS
  'Fuerza pagos.usuario_id = auth.uid(): la atribucion del cobro la decide el '
  'servidor, no el navegador. Exentas las RPCs SECURITY DEFINER; el admin puede '
  'imputar a otro explicitamente. Ver mig 190.';


-- -------------------------------------------------------------------------
-- 4 · Un preventista solo cobra SUS boletas  (#11)
-- -------------------------------------------------------------------------
-- `mt_pagos_insert` acota bien al transportista (solo pedidos donde el es el
-- chofer) y no acota nada en la otra rama: alcanzaba `es_preventista()` para
-- insertar un pago contra CUALQUIER pedido de la sucursal, de cualquier
-- vendedor. Los triggers lo propagan al saldo del cliente, y deshacerlo
-- requiere un admin porque `pagos` solo admite UPDATE/DELETE de admin.
--
-- OJO CON `es_preventista()`: devuelve true tambien para admin y encargado, asi
-- que "la rama del preventista" es en realidad la de los tres. Acotarla a secas
-- habria roto los cobros de oficina, que son la mayoria (admin: 3.169 pagos
-- contra pedidos ajenos; encargado: 718). Por eso admin/encargado salen
-- explicitos por `es_encargado_o_admin()` y el acote cae solo sobre el
-- preventista puro — que en 60 pagos nunca imputo contra un pedido ajeno, o sea
-- que no se le saca nada que hoy use.
DROP POLICY IF EXISTS mt_pagos_insert ON public.pagos;
CREATE POLICY mt_pagos_insert ON public.pagos
  FOR INSERT TO authenticated
  WITH CHECK (
    sucursal_id = current_sucursal_id()
    AND (
      -- Oficina: cobra cualquier boleta de su sucursal.
      es_encargado_o_admin()
      -- Chofer: solo las boletas que el lleva.
      OR (
        es_transportista()
        AND pedido_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM pedidos pd
          WHERE pd.id = pagos.pedido_id
            AND pd.transportista_id = auth.uid()
            AND pd.sucursal_id = current_sucursal_id()
        )
      )
      -- Preventista: solo las boletas que el vendio. Un pago a cuenta del
      -- cliente (sin pedido) sigue permitido: es cobranza legitima de su ruta.
      OR (
        es_preventista()
        AND (
          pedido_id IS NULL
          OR EXISTS (
            SELECT 1 FROM pedidos pd
            WHERE pd.id = pagos.pedido_id
              AND pd.usuario_id = auth.uid()
              AND pd.sucursal_id = current_sucursal_id()
          )
        )
      )
    )
  );
