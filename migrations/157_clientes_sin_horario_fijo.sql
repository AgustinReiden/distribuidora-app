-- Migración 157: `clientes.sin_horario_fijo` — escape del horario obligatorio
--
-- CONTEXTO
-- Los preventistas no cargan el horario de atención porque hoy hay que salir
-- del pedido, entrar a la ficha del cliente, cargarlo y volver. Con el cliente
-- apurado, no lo hacen. El resultado es que 283/621 clientes quedaron sin
-- horario y el ruteo los manda a la barrida "flexible" (ver mig 140).
--
-- La solución es pedir el horario DENTRO del modal de pedido y no dejar
-- confirmar hasta resolverlo. Pero hay clientes que genuinamente no tienen
-- horario fijo (kioscos que abren "cuando pueden", puestos de feria). Para
-- esos, un flag explícito: el preventista declara "no atiende con horario
-- fijo" una vez y la app deja de pedírselo.
--
-- El flag NO es lo mismo que `horarios_atencion IS NULL`: la ausencia de dato
-- es "todavía no lo cargamos", el flag es "ya preguntamos, no aplica". Sin esa
-- distinción, el aviso reaparece en cada pedido y los preventistas aprenden a
-- ignorarlo.
--
-- CRÍTICO — el trigger allow-list:
-- `clientes_proteger_columnas_preventista` (mig 080, extendido en 140) es
-- fail-closed: una columna nueva queda bloqueada para el rol `preventista`
-- hasta que se la agregue explícitamente. Sin el punto 2 de esta migración, el
-- preventista que use el escape recibe 42501 y el flujo queda trabado — que es
-- exactamente el problema que esta feature viene a resolver.
--
-- El segundo guard de clientes (`clientes_guard_update_preventista`) es
-- deny-list, así que no hace falta tocarlo: la columna nueva ya está permitida.

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Columna
-- -------------------------------------------------------------------------
ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS sin_horario_fijo boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.clientes.sin_horario_fijo IS
  'true = el cliente declaró que no atiende con horario fijo. Distinto de horarios_atencion vacío ("todavía no se cargó"): este flag suprime el pedido de horario al cargar un pedido. El ruteo lo trata igual que un cliente sin franjas (barrida flexible). Mig 157.';

-- -------------------------------------------------------------------------
-- 2. Allow-list del trigger.
--
--    Se replica la función tal cual está en prod (verificada contra
--    pg_get_functiondef el 2026-08-03), agregando solo la columna nueva.
--    NO simplificar el cuerpo: las exenciones de current_user y
--    pg_trigger_depth sostienen las RPCs SECURITY DEFINER y las cascadas de
--    saldo_cuenta.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clientes_proteger_columnas_preventista()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_rol text;
  v_bloqueadas text;
BEGIN
  -- RPCs SECURITY DEFINER, service_role, conexiones directas: exentas.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- Cascadas desde otros triggers (saldo_cuenta desde pedidos): exentas.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();

  IF v_rol IS NULL OR v_rol NOT IN ('preventista') THEN
    RETURN NEW;  -- admin y encargado sin restricción
  END IF;

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key NOT IN (
      'razon_social', 'direccion', 'aclaracion_direccion', 'latitud',
      'longitud', 'telefono', 'contacto', 'horarios_atencion', 'rubro', 'notas',
      -- Mig 140: el horario canónico se carga junto con los días.
      'dias_atencion', 'horarios_atencion_original',
      -- Mig 157: escape del horario obligatorio al cargar un pedido.
      'sin_horario_fijo'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'El rol % no puede modificar estas columnas de clientes: %',
      v_rol, v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$fn$;

COMMIT;
