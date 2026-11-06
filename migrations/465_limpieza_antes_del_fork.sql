-- 465 · Limpieza antes del fork: los seis helpers viejos de rol, las transferencias viejas de
-- stock y registrar_ingreso_sucursal (#1475, SEG-F-5 y STK-F-9). Tarjeta 8 de #1477.
--
-- QUÉ SE VA
--   - is_admin(), is_preventista(), is_transportista(), get_user_role(), get_mi_rol() y
--     es_transportista_rendiciones(). Son DEFINER con EXECUTE para authenticated y significan
--     otra cosa que los es_* (no ven el multi-rol de perfil_roles, trampa 4 de CLAUDE.md): una
--     función nueva que llame a uno por error abre un agujero. Ninguna función, policy, vista,
--     trigger, default ni CHECK los nombra, y el front y las edge functions tampoco (05/11).
--   - transferencias_stock (5 filas) y su hija transferencia_items (13 líneas), el flujo viejo
--     de transferencias entre sucursales de un solo lado, reemplazado por movimientos_sucursal.
--     Nada las escribe desde #1108. El dueño decidió el 06/11 guardarlas y borrarlas: se
--     exportaron a CSV y se le entregaron. La premisa de datos exige que sigan siendo eso.
--     Los 13 productos de esas líneas tienen pedidos y compras, así que ninguno pasa a poder
--     borrarse cuando el trigger deja de mirar transferencia_items.
--   - registrar_ingreso_sucursal(...), la única que las escribía. Sin EXECUTE para
--     authenticated desde #1048 y sin caller. Si alguien la rehabilitaba, no validaba
--     cantidad > 0, decidía el rol con COALESCE(p_usuario_id, auth.uid()) y subía el stock en
--     current_sucursal_id() aunque guardara p_sucursal_id.
--   - La rama 'transferencias' de productos_rechazar_borrado_con_historial: sin la tabla, el
--     trigger fallaría en cada DELETE de productos (42P01).
--
-- QUÉ NO SE HACE
--   SEG-F-9 (el EXECUTE de anon sobre unaccent) no se puede desde una migración: las cuatro
--   funciones de la extensión son de supabase_admin, que les dio EXECUTE a PUBLIC y a anon, y
--   postgres no es superusuario ni miembro de supabase_admin. El REVOKE no hace nada (se probó
--   el 06/11 en una transacción revertida: anon siguió pudiendo). El dueño decidió dejarlo:
--   es inocuo, y la extensión no se mueve de schema porque rompe a las funciones que la llaman
--   sin calificar.
--
-- LOCKS
--   Los drops toman ACCESS EXCLUSIVE sobre las tablas que se van y, por sus FKs, sobre
--   productos, sucursales y perfiles. Mientras la migración espera un lock, la app entera queda
--   en cola detrás (casi todas las policies leen perfiles). Como en la 461: las premisas y las
--   guardas sólo leen y van primero, y después se toman todos los locks juntos, en orden fijo y
--   con NOWAIT, reintentando cada 200 ms hasta 50 veces. La premisa de datos va con los locks
--   tomados. No se aplica a las 03:00 (pg_dump diario de la .130).
--
-- Ensayo: scripts/test-limpieza-antes-del-fork-1475.sql, antes y después.
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos que se dropean o se parchean son los que se leyeron el 05/11
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.is_admin()',                                                   'fe6ae37d50dd67a4f3750f92413f217b'),
        ('public.is_preventista()',                                             '0c3a450a8e3d52051f947e02d90e51da'),
        ('public.is_transportista()',                                           '9d836dbab9b99e241bc0264f47a086e9'),
        ('public.get_user_role()',                                              '81cfbce09f6bfb1d121a5c6a9709f9b8'),
        ('public.get_mi_rol()',                                                 'd66e268ec5913a2d9fa4b5fb9bb95b1b'),
        ('public.es_transportista_rendiciones()',                               '4cb61db4cc4f7276aebb745d39c0236b'),
        ('public.registrar_ingreso_sucursal(bigint,date,text,numeric,uuid,jsonb)', 'f49054b3fe4297f86a09394c3ccb43e4'),
        ('public.productos_rechazar_borrado_con_historial()',                   '0e7466cb7dfa75c3611196a15605208c')
      ) AS x(firma, md5)
      LEFT JOIN pg_proc p ON p.oid = to_regprocedure(x.firma)
  LOOP
    IF v_f.md5_vivo IS DISTINCT FROM v_f.md5 THEN
      RAISE EXCEPTION 'mig 465 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, COALESCE(v_f.md5_vivo, 'no existe'), v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Guardas: abortan si apareció algo que nombre lo que se va
-- ---------------------------------------------------------------------------
DO $guardas$
DECLARE
  v_nuevas text;
  c_nombres constant text :=
    '\m(is_admin|is_preventista|is_transportista|get_user_role|get_mi_rol|es_transportista_rendiciones|transferencias_stock|transferencia_items|registrar_ingreso_sucursal)\M';
BEGIN
  -- (1) Ninguna función ni procedure, en ningún schema que no sea del sistema, nombra los
  -- helpers, las tablas o la RPC, salvo las que se dropean y el trigger que se parchea abajo.
  -- Se compara por oid: no depende del search_path.
  SELECT string_agg(format('%I.%I(%s)', n.nspname, p.proname, oidvectortypes(p.proargtypes)), ', ') INTO v_nuevas
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
     AND p.prokind IN ('f', 'p') AND p.prolang NOT IN (12, 13)
     AND p.prosrc ~* c_nombres
     AND p.oid NOT IN ('public.registrar_ingreso_sucursal(bigint,date,text,numeric,uuid,jsonb)'::regprocedure,
                       'public.productos_rechazar_borrado_con_historial()'::regprocedure);
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig 465 · funciones que nombran lo que se dropea: %', v_nuevas;
  END IF;

  -- (2) Ninguna policy los nombra, fuera de las de las dos tablas que se van.
  SELECT string_agg(schemaname || '.' || tablename || '.' || policyname, ', ') INTO v_nuevas
    FROM pg_policies
   WHERE NOT (schemaname = 'public' AND tablename IN ('transferencias_stock', 'transferencia_items'))
     AND COALESCE(qual, '') || ' ' || COALESCE(with_check, '') ~* c_nombres;
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig 465 · policies que nombran lo que se dropea: %', v_nuevas;
  END IF;

  -- (3) Ninguna vista o matview depende de las tablas ni las nombra, y ninguna FK de otra
  -- tabla apunta a ellas.
  SELECT string_agg(DISTINCT v.oid::regclass::text, ', ') INTO v_nuevas
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid
    JOIN pg_class v ON v.oid = r.ev_class
   WHERE d.classid = 'pg_rewrite'::regclass
     AND d.refobjid IN ('public.transferencias_stock'::regclass, 'public.transferencia_items'::regclass)
     AND v.oid NOT IN ('public.transferencias_stock'::regclass, 'public.transferencia_items'::regclass);
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig 465 · vistas sobre las tablas que se van: %', v_nuevas;
  END IF;

  SELECT string_agg(c.oid::regclass::text, ', ') INTO v_nuevas
    FROM pg_class c
   WHERE c.relkind IN ('v', 'm') AND pg_get_viewdef(c.oid) ~* c_nombres;
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig 465 · vistas que nombran lo que se dropea: %', v_nuevas;
  END IF;

  SELECT string_agg(conname || ' on ' || conrelid::regclass::text, ', ') INTO v_nuevas
    FROM pg_constraint
   WHERE contype = 'f'
     AND confrelid IN ('public.transferencias_stock'::regclass, 'public.transferencia_items'::regclass)
     AND conrelid NOT IN ('public.transferencias_stock'::regclass, 'public.transferencia_items'::regclass);
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig 465 · FKs de otras tablas hacia las que se van: %', v_nuevas;
  END IF;

  -- (4) Sobre las tablas que se van no hay triggers.
  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE NOT tgisinternal
                AND tgrelid IN ('public.transferencias_stock'::regclass, 'public.transferencia_items'::regclass)) THEN
    RAISE EXCEPTION 'mig 465 · hay triggers sobre las tablas que se van';
  END IF;
END
$guardas$;

-- ---------------------------------------------------------------------------
-- Locks: todos juntos, en orden fijo, sin esperar (ver LOCKS en el encabezado)
-- ---------------------------------------------------------------------------
DO $locks$
BEGIN
  FOR i IN 1 .. 50 LOOP
    BEGIN
      LOCK TABLE public.transferencia_items, public.transferencias_stock,
                 public.productos, public.sucursales, public.perfiles
        IN ACCESS EXCLUSIVE MODE NOWAIT;
      RETURN;
    EXCEPTION WHEN lock_not_available THEN
      PERFORM pg_sleep(0.2);
    END;
  END LOOP;
  RAISE EXCEPTION 'mig 465 · no se consiguieron los locks en 50 intentos: no cambió nada, reintentar en una franja más tranquila';
END
$locks$;

-- ---------------------------------------------------------------------------
-- Premisa de datos, con los locks tomados: las tablas son las que se exportaron el 06/11
-- ---------------------------------------------------------------------------
DO $premisas_datos$
BEGIN
  IF (SELECT md5(string_agg(to_jsonb(t)::text, E'\n' ORDER BY id)) FROM public.transferencias_stock t)
       IS DISTINCT FROM 'd39d6cf5e0080eb13f4160675532b812'
     OR (SELECT md5(string_agg(to_jsonb(t)::text, E'\n' ORDER BY id)) FROM public.transferencia_items t)
       IS DISTINCT FROM 'e9393696ec8cda746782af3c27e04f63' THEN
    RAISE EXCEPTION 'mig 465 · transferencias_stock o transferencia_items cambiaron desde la exportación del 06/11: exportar de nuevo antes de borrarlas';
  END IF;
END
$premisas_datos$;

-- ---------------------------------------------------------------------------
-- STK-F-9 · Las transferencias viejas
-- ---------------------------------------------------------------------------
-- Primero el trigger: así no hay un instante en que mire una tabla que no existe.
DO $parche$
DECLARE
  v_def   text := pg_get_functiondef('public.productos_rechazar_borrado_con_historial()'::regprocedure);
  v_ancla text := $a$    UNION ALL
    SELECT 5, 'transferencias'
     WHERE EXISTS (SELECT 1 FROM transferencia_items WHERE producto_id = OLD.id)
$a$;
  v_n int := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 465 · productos_rechazar_borrado_con_historial: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, '');
END
$parche$;

DROP FUNCTION public.registrar_ingreso_sucursal(bigint, date, text, numeric, uuid, jsonb);
DROP TABLE public.transferencia_items;
DROP TABLE public.transferencias_stock;

-- ---------------------------------------------------------------------------
-- SEG-F-5 · Los seis helpers viejos de rol (sin CASCADE: si algo depende, falla)
-- ---------------------------------------------------------------------------
DROP FUNCTION public.is_admin();
DROP FUNCTION public.is_preventista();
DROP FUNCTION public.is_transportista();
DROP FUNCTION public.get_user_role();
DROP FUNCTION public.get_mi_rol();
DROP FUNCTION public.es_transportista_rendiciones();

-- ---------------------------------------------------------------------------
-- Poscondición
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  IF to_regclass('public.transferencias_stock') IS NOT NULL
     OR to_regclass('public.transferencia_items') IS NOT NULL
     OR to_regclass('public.transferencias_stock_id_seq') IS NOT NULL
     OR to_regclass('public.transferencia_items_id_seq') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public'
                   AND p.proname IN ('is_admin', 'is_preventista', 'is_transportista', 'get_user_role',
                                     'get_mi_rol', 'es_transportista_rendiciones', 'registrar_ingreso_sucursal')) THEN
    RAISE EXCEPTION 'mig 465 · quedó algo de lo que se dropea';
  END IF;

  SELECT md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def INTO r
    FROM pg_proc p WHERE p.oid = 'public.productos_rechazar_borrado_con_historial()'::regprocedure;
  IF r.h <> '781025173330d3e58aff853ae8de9855'
     OR r.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' OR NOT r.def THEN
    RAISE EXCEPTION 'productos_rechazar_borrado_con_historial no quedó como se esperaba (md5 %, acl %, definer %)', r.h, r.a, r.def;
  END IF;
END
$post$;

COMMIT;
