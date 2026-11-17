-- =========================================================================
-- NNN · USUARIOS, SUCURSALES Y RETENCIÓN DE LA AUDITORÍA
--       (ola 2 del plan #1603, tarjeta B6b: #1525-1/2, 1596-b4, 1561-b3,
--        1596-b5, 1561-b10 y 1596-b10)
--
-- Parcha por ancla tres funciones (`handle_new_user`, `asignar_usuario_sucursal`
-- y `desasignar_usuario_sucursal`), con premisa de md5 sobre el cuerpo vivo del
-- 16/11 (ledger en la 512); dropea `usuario_sucursales.rol`; parte el trigger de
-- auditoría de `productos` en dos; y crea `purgar_retencion()`, sólo de server.
-- No cambia firmas. No borra ninguna fila: la purga la corre después
-- `.github/workflows/purgar-retencion.yml`, nunca esta migración.
-- Ensayo: scripts/test-usuarios-retencion-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · #1525 · LA SUCURSAL NO TIENE ROL: SE VA LA COLUMNA
-- =========================================================================
-- Desde la 486 (#1519) el rol es `perfiles.rol` en toda sucursal y
-- `usuario_sucursales.rol` quedó fija en 'mismo' por un CHECK. Decisión del dueño
-- (D54, 15/11, en #1525): se borra. Lo único que todavía la nombraba es
-- `handle_new_user()`, que se reescribe antes del DROP. El front (desde el
-- 10/11, 2d3fa891) y `escanear-factura` (desde su alta) ya no la piden. El DROP
-- se lleva el CHECK `usuario_sucursales_rol_mismo` y el default; sin CASCADE, así
-- que si una vista o una policy la nombrara, la migración entera aborta.
--
-- =========================================================================
-- 2 · 1596-b4 y 1561-b3 · QUIEN TIENE SUCURSALES TIENE UNA DEFAULT
-- =========================================================================
-- `asignar_usuario_sucursal(u, s, false)` sobre la sucursal que ya era la default
-- la ponía en false y el usuario quedaba sin ninguna; `desasignar` de la default
-- también. Sin default el front cae en la primera de la lista y `escanear-factura`
-- rechaza a quien tiene varias. Ahora, después de escribir, si el usuario no tiene
-- ninguna default, asignar y desasignar le pasan la marca a la primera que le queda
-- (una activa antes que una inactiva, por id). No
-- hay regla de negocio nueva: es la marca que ya existía, que nadie pierde.
--
-- =========================================================================
-- 3 · 1596-b5 · EL ALTA DEL PANEL VA A LA PRIMERA SUCURSAL ACTIVA
-- =========================================================================
-- `handle_new_user()` tenía la sucursal 1 fija, la única suposición del núcleo
-- sobre un id. Decisión del dueño (D39, 15/11, en #1596): un usuario creado desde
-- el panel sin datos va a la primera sucursal activa (la de menor id con
-- `activa`), no a la 1. Sin ninguna activa, el alta se rechaza: nadie queda sin
-- sucursal. El rol y la sucursal siguen saliendo SÓLO de `raw_app_meta_data`
-- (#1243); `scripts/check-auth.mjs` sigue mirando lo mismo.
--
-- =========================================================================
-- 4 · 1596-b10 · LA BAJA DE STOCK POR VENTA NO SE AUDITA EN PRODUCTOS
-- =========================================================================
-- Una venta de 20 líneas escribía 43 filas en `audit_logs`: la boleta, sus 20
-- líneas, su total neto, el saldo del cliente y 20 de `productos`, una por línea,
-- con sólo el stock cambiado. Decisión del dueño (D38, 15/11, en #1596): la baja
-- de stock por venta deja de auditarse en `productos`, porque ya está en
-- `stock_historico` (con su origen, su referencia y su usuario). El trigger
-- `audit_productos` queda para el alta y la baja del producto, y
-- `audit_productos_update` audita todo UPDATE salvo el que sólo baja el stock
-- (y mueve `updated_at`) con un origen de venta: `pedido_creado`,
-- `pedido_creado_bot` y `pedido_editado`. Una subida (la edición que devuelve, la
-- cancelación, la salvedad), cualquier otro origen y cualquier otra columna se
-- siguen auditando. `audit_log_changes()` no cambia.
--
-- =========================================================================
-- 5 · 1561-b10 y 1596-b10 · RETENCIÓN DE AVISOS Y AUDITORÍA
-- =========================================================================
-- Decisión del dueño (D38, 15/11, en #1561 y #1596): los avisos
-- (`notificaciones`) se guardan 90 días y el registro de auditoría
-- (`audit_logs`) 24 meses. `purgar_retencion(p_lote)` borra, de cada tabla, hasta
-- `p_lote` filas más viejas que su corte (de 1 a 50.000; 5.000 por defecto) y
-- dice si quedan más. Es INVOKER y sólo la ejecuta `service_role` (y postgres):
-- la llama el workflow diario por PostgREST, en un bucle hasta que no queden.
-- Nada más: ni `bot_audit_log` (tiene su retención desde la 016), ni otra tabla.
-- Esta migración no la ejecuta.
--
-- Revertir: volver los tres cuerpos a los de la premisa, `ALTER TABLE
-- usuario_sucursales ADD COLUMN rol varchar NOT NULL DEFAULT 'mismo'` con su
-- CHECK, el trigger `audit_productos` como estaba (INSERT OR DELETE OR UPDATE) sin
-- `audit_productos_update`, y `DROP FUNCTION purgar_retencion(integer)`.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- El DROP COLUMN y los triggers toman ACCESS EXCLUSIVE sobre las dos tablas hasta el
-- COMMIT. Tomados de a uno, contra un alta de pedido (que bloquea productos) pueden
-- cruzarse en un deadlock: se toman juntos y sin esperar. Si alguien los tiene, la
-- migración falla al instante y se reintenta.
LOCK TABLE public.usuario_sucursales, public.productos IN ACCESS EXCLUSIVE MODE NOWAIT;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 16/11 (ledger en la 512) y el catálogo
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.handle_new_user()', '07184c7145ae456bed446eb4c3415c40'),
    ('public.asignar_usuario_sucursal(uuid,bigint,boolean)', 'd8799feaf27a9e19294ca4e98a85bcfa'),
    ('public.desasignar_usuario_sucursal(uuid,bigint)', '944b11a38e804d35766ebc713da1cdfb')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- #1525: la columna existe y, salvo handle_new_user, ninguna función la nombra.
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.usuario_sucursales'::regclass
                   AND attname = 'rol' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · usuario_sucursales.rol ya no existe: revisar a mano';
  END IF;
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
     AND p.oid <> 'public.handle_new_user()'::regprocedure
     AND (p.prosrc ~* 'usuario_sucursales\.rol\M'
          OR p.prosrc ~* 'usuario_sucursales\s*\([^)]*\mrol\M'
          OR p.prosrc ~* 'UPDATE\s+(public\.)?usuario_sucursales\s+SET[^;]*\mrol\M'
          OR p.prosrc ~ '\mus\d?\.rol\M');
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · todavía nombran usuario_sucursales.rol: %', v;
  END IF;

  -- 1596-b5: el alta del panel necesita una sucursal activa.
  IF NOT EXISTS (SELECT 1 FROM public.sucursales WHERE activa) THEN
    RAISE EXCEPTION 'mig NNN · no hay ninguna sucursal activa: el alta del panel no tendría adónde ir';
  END IF;

  -- 1596-b10: el trigger de auditoría de productos es el de siempre, y la baja por
  -- venta llega a stock_historico (trg_stock_historico).
  IF to_regprocedure('public.audit_log_changes()') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.productos'::regclass
                     AND tgname = 'trg_stock_historico' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig NNN · faltan audit_log_changes() o trg_stock_historico en productos';
  END IF;
  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
       WHERE t.tgrelid = 'public.productos'::regclass AND t.tgname = 'audit_productos')
     IS DISTINCT FROM 'CREATE TRIGGER audit_productos AFTER INSERT OR DELETE OR UPDATE ON public.productos FOR EACH ROW EXECUTE FUNCTION audit_log_changes()' THEN
    RAISE EXCEPTION 'mig NNN · audit_productos no es el trigger de siempre: revisar a mano';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.productos'::regclass
              AND tgname = 'audit_productos_update')
     OR to_regproc('public.purgar_retencion') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · audit_productos_update o purgar_retencion ya existen: revisar a mano';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- handle_new_user: sin la sucursal 1 fija (1596-b5) y sin rol (#1525-2)
-- =========================================================================
DO $parche_alta$
DECLARE
  v_def text := pg_get_functiondef('public.handle_new_user()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_sucursal_id   BIGINT := 1;
$a$,
$r$  v_sucursal_id   BIGINT;
$r$, 'handle_new_user (sin la 1 fija)');

  v_def := pg_temp.parche(v_def,
$a$      RAISE EXCEPTION 'Alta de usuario: app_metadata.sucursal_id = % no es una sucursal', v_meta_sucursal;
    END IF;
  END IF;
$a$,
$r$      RAISE EXCEPTION 'Alta de usuario: app_metadata.sucursal_id = % no es una sucursal', v_meta_sucursal;
    END IF;
  ELSE
    -- 1596-b5 (decisión del dueño, D39): sin sucursal en app_metadata (el alta del
    -- panel), la primera sucursal activa; ninguna sucursal fija. Sin ninguna activa
    -- no hay alta: nadie queda sin sucursal.
    SELECT s.id INTO v_sucursal_id FROM public.sucursales s WHERE s.activa ORDER BY s.id LIMIT 1;
    IF v_sucursal_id IS NULL THEN
      RAISE EXCEPTION 'Alta de usuario: no hay ninguna sucursal activa a la que asignarlo';
    END IF;
  END IF;
$r$, 'handle_new_user (la primera activa)');

  v_def := pg_temp.parche(v_def,
$a$  INSERT INTO public.usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
  VALUES (NEW.id, v_sucursal_id, 'mismo', true)
$a$,
$r$  -- Sin rol: es perfiles.rol en toda sucursal (486, #1519; la columna se fue en #1525).
  INSERT INTO public.usuario_sucursales (usuario_id, sucursal_id, es_default)
  VALUES (NEW.id, v_sucursal_id, true)
$r$, 'handle_new_user (sin rol)');

  EXECUTE v_def;
END
$parche_alta$;

-- =========================================================================
-- asignar_usuario_sucursal: la default no se pierde (1596-b4)
-- =========================================================================
DO $parche_asignar$
DECLARE
  v_def text := pg_get_functiondef('public.asignar_usuario_sucursal(uuid,bigint,boolean)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF p_es_default THEN
    UPDATE usuario_sucursales SET es_default = false
     WHERE usuario_id = p_usuario_id AND sucursal_id <> p_sucursal_id;
  END IF;
$a$,
$r$  IF p_es_default THEN
    UPDATE usuario_sucursales SET es_default = false
     WHERE usuario_id = p_usuario_id AND sucursal_id <> p_sucursal_id;
  END IF;

  -- 1596-b4: asignar sin default la sucursal que ya lo era la dejaba sin ninguna.
  -- Quien tiene sucursales tiene una default: si no le queda, la primera de las
  -- suyas, una activa antes que una inactiva, por id (como desasignar).
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales
                  WHERE usuario_id = p_usuario_id AND es_default) THEN
    UPDATE usuario_sucursales SET es_default = true
     WHERE id = (SELECT us.id
                   FROM usuario_sucursales us
                   JOIN sucursales s ON s.id = us.sucursal_id
                  WHERE us.usuario_id = p_usuario_id
                  ORDER BY (s.activa IS TRUE) DESC, us.sucursal_id
                  LIMIT 1);
  END IF;
$r$, 'asignar_usuario_sucursal (default)');

  EXECUTE v_def;
END
$parche_asignar$;

-- =========================================================================
-- desasignar_usuario_sucursal: la default pasa a otra (1561-b3)
-- =========================================================================
DO $parche_desasignar$
DECLARE
  v_def text := pg_get_functiondef('public.desasignar_usuario_sucursal(uuid,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  DELETE FROM usuario_sucursales
   WHERE usuario_id = p_usuario_id AND sucursal_id = p_sucursal_id;
$a$,
$r$  DELETE FROM usuario_sucursales
   WHERE usuario_id = p_usuario_id AND sucursal_id = p_sucursal_id;

  -- 1561-b3: sacarlo de su default lo dejaba sin ninguna. La marca pasa a la
  -- primera que le queda: una activa antes que una inactiva, por id.
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales
                  WHERE usuario_id = p_usuario_id AND es_default) THEN
    UPDATE usuario_sucursales SET es_default = true
     WHERE id = (SELECT us.id
                   FROM usuario_sucursales us
                   JOIN sucursales s ON s.id = us.sucursal_id
                  WHERE us.usuario_id = p_usuario_id
                  ORDER BY (s.activa IS TRUE) DESC, us.sucursal_id
                  LIMIT 1);
  END IF;
$r$, 'desasignar_usuario_sucursal (default)');

  EXECUTE v_def;
END
$parche_desasignar$;

-- =========================================================================
-- #1525-1: el DROP (se lleva el CHECK usuario_sucursales_rol_mismo y el default)
-- =========================================================================
ALTER TABLE public.usuario_sucursales DROP COLUMN rol;

-- =========================================================================
-- 1596-b10: la baja de stock por venta no se audita en productos
-- =========================================================================
DROP TRIGGER audit_productos ON public.productos;

CREATE TRIGGER audit_productos
  AFTER INSERT OR DELETE ON public.productos
  FOR EACH ROW EXECUTE FUNCTION audit_log_changes();

-- Todo UPDATE salvo el que sólo baja el stock (y mueve updated_at) con un origen de
-- venta: ese ya queda en stock_historico (registrar_cambio_stock). El COALESCE hace
-- que un NULL (stock nulo) audite: ante la duda, se audita.
CREATE TRIGGER audit_productos_update
  AFTER UPDATE ON public.productos
  FOR EACH ROW
  WHEN (NOT COALESCE(
          new.stock < old.stock
          AND current_setting('app.stock_origen', true) IN ('pedido_creado', 'pedido_creado_bot', 'pedido_editado')
          AND (to_jsonb(old) - 'stock' - 'updated_at') = (to_jsonb(new) - 'stock' - 'updated_at'),
          false))
  EXECUTE FUNCTION audit_log_changes();

-- =========================================================================
-- 1561-b10 y 1596-b10: la retención (función de server; no se ejecuta acá)
-- =========================================================================
-- Decisión del dueño (D38): avisos 90 días, auditoría 24 meses. Borra de a lotes,
-- las más viejas primero, y dice si quedan más (el workflow la llama en un bucle).
-- INVOKER: service_role ya puede borrar las dos tablas.
CREATE FUNCTION public.purgar_retencion(p_lote integer DEFAULT 5000)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_lote           integer := LEAST(GREATEST(COALESCE(p_lote, 5000), 1), 50000);
  v_corte_avisos   timestamptz := now() - interval '90 days';
  v_corte_auditoria timestamptz := now() - interval '24 months';
  v_avisos         integer;
  v_auditoria      integer;
BEGIN
  DELETE FROM notificaciones
   WHERE id IN (SELECT n.id FROM notificaciones n
                 WHERE n.created_at < v_corte_avisos
                 ORDER BY n.created_at, n.id
                 LIMIT v_lote);
  GET DIAGNOSTICS v_avisos = ROW_COUNT;

  DELETE FROM audit_logs
   WHERE id IN (SELECT a.id FROM audit_logs a
                 WHERE a.created_at < v_corte_auditoria
                 ORDER BY a.created_at
                 LIMIT v_lote);
  GET DIAGNOSTICS v_auditoria = ROW_COUNT;

  RETURN jsonb_build_object(
    'notificaciones', v_avisos,
    'audit_logs', v_auditoria,
    'quedan', v_avisos = v_lote OR v_auditoria = v_lote,
    'corte_notificaciones', v_corte_avisos,
    'corte_audit_logs', v_corte_auditoria);
END
$function$;

REVOKE ALL ON FUNCTION public.purgar_retencion(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purgar_retencion(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.handle_new_user()', '8901c913f97888a4145fd954602994e1', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.asignar_usuario_sucursal(uuid,bigint,boolean)', '4a1ec2effd47f8eeccdc8f685e2739cf', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.desasignar_usuario_sucursal(uuid,bigint)', '7da4400c38ba229fa2ca8de856ecfc93', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.purgar_retencion(integer)', '5747284331e2cc4a116071910f5df329', false,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.usuario_sucursales'::regclass
               AND attname = 'rol' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · usuario_sucursales.rol sigue ahí';
  END IF;
  IF (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.productos'::regclass
       AND tgname IN ('audit_productos', 'audit_productos_update') AND tgenabled = 'O') <> 2 THEN
    RAISE EXCEPTION 'mig NNN · faltan los dos triggers de auditoría de productos';
  END IF;
END
$post$;

COMMIT;
