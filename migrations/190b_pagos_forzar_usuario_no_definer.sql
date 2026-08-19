-- ============================================================================
-- 190b · pagos_forzar_usuario deja de ser SECURITY DEFINER
-- ============================================================================
-- ARCHIVO ESCRITO DESPUÉS DE APLICAR. La migración se aplicó a prod el
-- 2026-08-19 (ledger `20260819200704 190b_pagos_forzar_usuario_no_definer`) sin
-- dejar archivo en el repo. El drift-check lo detectó al día siguiente de que el
-- gate empezara a correr de verdad — que es exactamente para lo que está.
--
-- El cuerpo de abajo NO está reconstruido de memoria: sale de
-- `pg_get_functiondef()` contra prod, que es la regla de este repo para tocar
-- algo que ya está vivo (ver MANIFEST y la nota de la 167).
--
-- QUÉ ARREGLA. El trigger de la 190 nació `SECURITY DEFINER`, y eso rompe en
-- silencio el guard que la propia función usa: adentro de una SECURITY DEFINER
-- `current_user` es SIEMPRE el dueño, nunca 'authenticated', así que la primera
-- rama tomaba de largo para todo el mundo y `usuario_id` dejaba de forzarse.
-- Es la misma trampa que documenta la 181 para `pedidos_proteger_columnas` y
-- `clientes_proteger_columnas_preventista` (mig 080): **un trigger dispara
-- igual aunque quien escriba sea SECURITY DEFINER —eso saltea RLS, no
-- triggers—, así que la exención se hace con `current_user`, y para que
-- `current_user` sirva la función NO puede ser DEFINER.**
--
-- Idempotente: es un CREATE OR REPLACE del estado que ya está vivo.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.pagos_forzar_usuario()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF es_admin() AND NEW.usuario_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  NEW.usuario_id := auth.uid();
  RETURN NEW;
END;
$function$;

COMMIT;

-- ----------------------------------------------------------------------------
-- Verificación
--
--   -- Tiene que decir false. Si vuelve a decir true, el guard de current_user
--   -- dejó de filtrar y no lo va a avisar nadie.
--   SELECT proname, prosecdef FROM pg_proc p
--     JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
--    WHERE proname = 'pagos_forzar_usuario';   -- pagos_forzar_usuario | f
-- ----------------------------------------------------------------------------
