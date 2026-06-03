-- Migración 077: Historial de pedidos — capturar el usuario real del cambio
--
-- Antes: los triggers que registran cambios en pedido_historial leían
-- current_setting('app.current_user_id'), una variable de sesión que la app
-- NUNCA setea → usuario_id quedaba NULL y el modal mostraba "Usuario desconocido".
--
-- Ahora: si esa GUC no está seteada, caen en auth.uid() (disponible dentro del
-- request autenticado de PostgREST/RPC). Cambios hechos por service-role (bot,
-- edge functions sin JWT) quedan con auth.uid()=NULL → el front los muestra como
-- "Sistema". Forward-only: las filas históricas con usuario NULL no se recuperan.

BEGIN;

CREATE OR REPLACE FUNCTION public.registrar_cambio_pedido()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  usuario_actual UUID;
BEGIN
  BEGIN
    usuario_actual := COALESCE(
      NULLIF(current_setting('app.current_user_id', true), '')::uuid,
      auth.uid()
    );
  EXCEPTION WHEN OTHERS THEN
    usuario_actual := auth.uid();
  END;

  IF OLD.estado IS DISTINCT FROM NEW.estado THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'estado', OLD.estado, NEW.estado, NEW.sucursal_id);
  END IF;

  IF OLD.transportista_id IS DISTINCT FROM NEW.transportista_id THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'transportista_id',
            COALESCE(OLD.transportista_id::TEXT, 'sin asignar'),
            COALESCE(NEW.transportista_id::TEXT, 'sin asignar'),
            NEW.sucursal_id);
  END IF;

  IF OLD.notas IS DISTINCT FROM NEW.notas THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'notas',
            COALESCE(OLD.notas, '(sin notas)'),
            COALESCE(NEW.notas, '(sin notas)'),
            NEW.sucursal_id);
  END IF;

  IF OLD.forma_pago IS DISTINCT FROM NEW.forma_pago THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'forma_pago',
            COALESCE(OLD.forma_pago, 'efectivo'),
            COALESCE(NEW.forma_pago, 'efectivo'),
            NEW.sucursal_id);
  END IF;

  IF OLD.estado_pago IS DISTINCT FROM NEW.estado_pago THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'estado_pago',
            COALESCE(OLD.estado_pago, 'pendiente'),
            COALESCE(NEW.estado_pago, 'pendiente'),
            NEW.sucursal_id);
  END IF;

  IF OLD.total IS DISTINCT FROM NEW.total THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'total',
            OLD.total::TEXT,
            NEW.total::TEXT,
            NEW.sucursal_id);
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_creacion_pedido()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  usuario_actual UUID;
BEGIN
  BEGIN
    usuario_actual := COALESCE(
      NULLIF(current_setting('app.current_user_id', true), '')::uuid,
      auth.uid()
    );
  EXCEPTION WHEN OTHERS THEN
    usuario_actual := NEW.usuario_id;
  END;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (NEW.id, COALESCE(usuario_actual, NEW.usuario_id), 'creacion', NULL, 'Pedido creado', NEW.sucursal_id);

  RETURN NEW;
END;
$function$;

COMMIT;
