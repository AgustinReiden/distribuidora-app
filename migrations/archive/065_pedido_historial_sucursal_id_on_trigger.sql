-- Migration 065: pedido_historial.sucursal_id must be set by trigger
--
-- Context: Migration 057 added `sucursal_id BIGINT NOT NULL` to
-- pedido_historial but left the two trigger functions that write into it
-- untouched. Any INSERT or UPDATE on public.pedidos after 057 therefore
-- fails with `null value in column "sucursal_id" of relation
-- "pedido_historial" violates not-null constraint`.
--
-- The regression was latent — no pedido traffic hit the codebase between
-- when 057 was applied and when the TP Export import started (the last
-- natural pedido was from just before 057's deployment), so the failure
-- only surfaced when migration 062 tried to INSERT imported pedidos.
-- Without this fix, 062 aborts after its first row.
--
-- Fix: both trigger functions append `NEW.sucursal_id` as the 6th column
-- to every INSERT INTO pedido_historial they emit. On UPDATE the tenant
-- is the current row's (NEW) sucursal; cross-tenant moves are not a
-- supported operation.
--
-- This migration was originally applied as an emergency hotfix directly
-- to production while preparing the TP Export import; it is recorded
-- here so the migration chain stays reproducible from a clean DB.

CREATE OR REPLACE FUNCTION public.registrar_creacion_pedido()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  usuario_actual UUID;
BEGIN
  BEGIN
    usuario_actual := current_setting('app.current_user_id', true)::UUID;
  EXCEPTION WHEN OTHERS THEN
    usuario_actual := NEW.usuario_id;
  END;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (NEW.id, COALESCE(usuario_actual, NEW.usuario_id), 'creacion', NULL, 'Pedido creado', NEW.sucursal_id);

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.registrar_cambio_pedido()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  usuario_actual UUID;
BEGIN
  BEGIN
    usuario_actual := current_setting('app.current_user_id', true)::UUID;
  EXCEPTION WHEN OTHERS THEN
    usuario_actual := NULL;
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
$$;
