-- =========================================================================
-- promociones se audita como las otras once
--
-- EL PROBLEMA (issue #536)
-- ------------------------
-- `audit_log_changes` cubre once tablas -- clientes, compras,
-- grupo_precio_escala_minimos, pagos, pedido_items, pedidos, perfiles,
-- productos, rendicion_gastos, rendiciones, rendiciones_control -- y
-- `promociones` no esta. Sus tres triggers no auditan nada: solo pisan
-- `updated_at`, setean la sucursal y apagan la promo al llegar al limite.
--
-- LO QUE COSTO
-- ------------
-- Para congelar el factor de fraccion (mig 212) no habia forma directa de
-- saber si alguna promo se habia editado alguna vez. Hubo que reconstruir el
-- historico MIDIENDO desde `promo_ajustes`, aprovechando que
-- `usos_ajustados = bloques * unidades_por_bloque` deja el factor vivo escrito
-- en cada fila. Funciona, pero es un rodeo, no una fuente.
--
-- Y peor: `promociones.updated_at` PARECE fecha de edicion y no lo es. El
-- trigger que la pisa no tiene `UPDATE OF` ni `WHEN`, y crear_pedido_completo
-- bumpea la fila en CADA bonificacion, asi que es fecha de ULTIMO USO. Leerla
-- como "cuando se edito esto" hizo perder una sesion entera creyendo que las 12
-- promos habian sido editadas cuando ninguna lo fue.
--
-- POR QUE EL TRIGGER VA PLANO Y NO CON LISTA DE COLUMNAS
-- ------------------------------------------------------
-- La tentacion es `AFTER UPDATE OF <columnas de config>` para no auditar los
-- bumps del contador. Se descarto por dos razones:
--
--   1. `UPDATE OF` no cubre lo que no nombra, y ademas mira la lista SET del
--      statement, NO lo que escriben los BEFORE triggers. `check_promo_limite_usos`
--      apaga `activo` desde un BEFORE cuando el statement solo nombraba
--      `usos_pendientes`: con lista de columnas, esa desactivacion automatica
--      NO quedaria auditada. Es exactamente la trampa 6 de CLAUDE.md.
--
--   2. El volumen no lo justifica. En los ultimos 30 dias hubo 324
--      bonificaciones y 172 filas de promo_ajustes, o sea ~500 UPDATE a
--      `promociones`, contra 29.601 filas que audit_logs ya escribe en el mismo
--      periodo. Es +1,7%.
--
-- Va plano, igual que las otras once. La consistencia tambien vale: el proximo
-- que mire no tiene que aprender un caso especial.
--
-- COMO SE FILTRAN LOS BUMPS DEL CONTADOR AL CONSULTAR
-- ---------------------------------------------------
--   SELECT * FROM audit_logs
--    WHERE tabla = 'promociones'
--      AND NOT (campos_modificados <@ ARRAY['usos_pendientes','updated_at']);
-- Queda como COMMENT ON TRIGGER, que es donde alguien lo va a buscar.
--
-- NO SE TOCA `updated_at`. Cambiarle la semantica es otra discusion y ninguna
-- de las nueve funciones que hacen UPDATE a `promociones` la lee, ni el front
-- tampoco. Se documenta la trampa en la columna y listo.
--
-- No hay funcion nueva: `audit_log_changes` ya existe con su ACL cerrado
-- (postgres + service_role, sin PUBLIC ni anon), que es lo que corresponde a
-- una funcion de trigger. Un trigger nuevo no cambia ningun ACL.
--
-- ESTO NO RECONSTRUYE EL PASADO. Previene la proxima vez.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 - El trigger, con el mismo nombre y forma que los otros once.
-- -------------------------------------------------------------------------
DROP TRIGGER IF EXISTS audit_promociones ON public.promociones;
CREATE TRIGGER audit_promociones
  AFTER INSERT OR DELETE OR UPDATE ON public.promociones
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_log_changes();

COMMENT ON TRIGGER audit_promociones ON public.promociones IS
  'Auditoria de promociones (issue #536). Audita TODO, incluidos los bumps de '
  'usos_pendientes que hace crear_pedido_completo en cada bonificacion. Para ver '
  'solo las ediciones de verdad: WHERE tabla = ''promociones'' AND NOT '
  '(campos_modificados <@ ARRAY[''usos_pendientes'',''updated_at'']).';

-- -------------------------------------------------------------------------
-- 2 - La trampa de updated_at, escrita donde se la busca.
-- -------------------------------------------------------------------------
COMMENT ON COLUMN public.promociones.updated_at IS
  'NO es fecha de edicion: es fecha de ULTIMO USO. El trigger que la pisa no '
  'tiene UPDATE OF ni WHEN, y crear_pedido_completo bumpea la fila en cada '
  'bonificacion. Para saber cuando se edito una promo, mirar audit_logs '
  '(trigger audit_promociones, issue #536).';

-- -------------------------------------------------------------------------
-- 3 - Verificacion.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_trg   int;
  v_def   text;
  v_acl   text;
  v_tablas int;
BEGIN
  SELECT count(*) INTO v_trg FROM pg_trigger t
   WHERE t.tgrelid = 'public.promociones'::regclass AND t.tgname = 'audit_promociones';
  IF v_trg <> 1 THEN
    RAISE EXCEPTION 'El trigger de auditoria no quedo creado.';
  END IF;

  -- Plano: sin lista de columnas y sin WHEN, o se pierde lo que escriben los
  -- BEFORE triggers (ver el encabezado).
  SELECT pg_get_triggerdef(t.oid) INTO v_def FROM pg_trigger t
   WHERE t.tgrelid = 'public.promociones'::regclass AND t.tgname = 'audit_promociones';
  IF v_def LIKE '%UPDATE OF%' OR v_def LIKE '%WHEN%' THEN
    RAISE EXCEPTION 'El trigger quedo filtrado y va plano a proposito: %', v_def;
  END IF;
  IF v_def NOT LIKE '%INSERT%' OR v_def NOT LIKE '%UPDATE%' OR v_def NOT LIKE '%DELETE%' THEN
    RAISE EXCEPTION 'El trigger no cubre las tres operaciones: %', v_def;
  END IF;

  -- Ahora son doce.
  SELECT count(DISTINCT c.relname) INTO v_tablas
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
   WHERE NOT t.tgisinternal AND pg_get_triggerdef(t.oid) LIKE '%audit_log_changes%';
  IF v_tablas <> 12 THEN
    RAISE EXCEPTION 'audit_log_changes cubre % tablas, se esperaban 12.', v_tablas;
  END IF;

  -- El ACL de la funcion de trigger sigue cerrado: no necesita EXECUTE para
  -- nadie porque la invoca el executor como parte del DML.
  SELECT array_to_string(array_agg(a::text), ' ') INTO v_acl
  FROM pg_proc p, unnest(p.proacl) a
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'audit_log_changes'
    AND (a::text LIKE '=%' OR a::text LIKE 'anon=%' OR a::text LIKE 'authenticated=%');
  IF v_acl IS NOT NULL THEN
    RAISE EXCEPTION 'audit_log_changes quedo ejecutable de mas (%).', v_acl;
  END IF;

  RAISE NOTICE 'OK: promociones se audita, ahora son 12 tablas.';
END
$verif$;

COMMIT;
