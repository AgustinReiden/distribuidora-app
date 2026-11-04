-- NNN · Limpieza, paso B: se dropean clientes.zona, clientes.preventista_id y el sistema viejo
-- de rendiciones, y sale la rama del vendedor de pedidos_proteger_columnas (#1336, #1368,
-- #1383). Tarjeta 10 de #1389.
--
-- VA DESPUÉS DEL PASO A Y DEL PLAZO DE LOS BUNDLES VIEJOS
--   Un bundle viejo del PWA que pide una columna dropeada rompe la consulta entera, no sólo
--   ese campo. Antes de la tarjeta 10, la lista de Pedidos pedía `zona` en el embed del
--   cliente. Se aplica cuando los logs de la API no muestran más consultas con `zona` en un
--   embed o un select de clientes. Las premisas exigen que el paso A esté aplicado.
--
-- QUÉ SE VA
--   - clientes.zona (texto) y clientes.preventista_id (uuid, con su índice y su FK a perfiles).
--     La zona sale de `zonas` por `zona_id` y el preventista de `cliente_preventistas` (#1314).
--   - rendiciones, rendicion_items y rendicion_ajustes, con sus policies, sus triggers
--     (trigger_rendiciones_updated_at, audit_rendiciones) y la vista vista_rendiciones. También
--     update_rendiciones_updated_at y las dos funciones que las usaban: crear_rendicion_por_fecha
--     y obtener_estadisticas_rendiciones. Las dos son sin EXECUTE para authenticated desde la
--     314 y nadie las llama. El sistema viejo no tiene funciones vivas desde la 429. Quedaba 1
--     rendición pendiente del 15/04 con 16 ítems y sin ajustes: se exportó a JSON antes de
--     borrarla (decisión del dueño, 02/11), y la premisa exige que sea la misma que se exportó.
--     rendicion_items tenía FK ON DELETE CASCADE a pedidos: eliminar_pedido_completo ya no
--     borra nada de ahí (#1329).
--   - La rama del vendedor de pedidos_proteger_columnas (416b): por REST pasaba su pedido a
--     pendiente y sin chofer, sin la hora de corte y sin sacarlo de la ruta. Desde #1372 (PR
--     #1377, 02/11) el front no la usa. La única vía queda en
--     volver_pedido_a_pendiente_por_edicion (DEFINER: no pasa por el trigger), y la llama
--     también actualizar_fechas_y_notas_pedido (455), cuyo UPDATE INVOKER ya no toca ni el
--     estado ni el chofer.
--
-- QUÉ NO CAMBIA
--   rendiciones_control, rendicion_pagos_confirmados, rendicion_faltantes y sus funciones son
--   el sistema nuevo y no se tocan. pedidos_proteger_columnas sigue igual salvo esa rama.
--
-- Aplicar desde el contenido LF.

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  -- (1) El paso A está aplicado y nada cambió desde que se leyeron los cuerpos.
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public._asignar_clientes_a(bigint[],uuid)',                      '608c2d224294630ea95cec50ca08ea07'),
        ('public.bot_buscar_cliente(text,uuid,text,bigint,integer)',       '1318738018edf75e4d19c8d02d165de8'),
        ('public.bot_mis_clientes(uuid,bigint,boolean,integer,integer)',   'ed5779e0b332bb667eb83e455ecac6e9'),
        ('public.clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)',     'a637f5ac54fa8c6f4fb77908c2124860'),
        ('public.bot_metricas_admin_dia(date,bigint)',                     '71ce6341364a568ef6d67b8a8fedaa3e'),
        ('public.pedidos_proteger_columnas()',                             'b1e8fb3ca55e86967c7d72eb72e0652c'),
        ('public.crear_rendicion_por_fecha(uuid,date)',                    '20ed95da9b65daa322b00c29472953a1'),
        ('public.obtener_estadisticas_rendiciones(date,date,uuid)',        '7063a7ffa07128f780590df028ec9639'),
        ('public.update_rendiciones_updated_at()',                         '10ff09e0d1433006b865e7959e736c46')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  -- (2) La rendición vieja es la que se exportó el 04/11: 1 cabecera, 16 ítems, 0 ajustes.
  IF md5(jsonb_build_object(
           'r', (SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM rendiciones r),
           'i', (SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM rendicion_items i),
           'a', (SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY id), '[]') FROM rendicion_ajustes a)
         )::text) <> 'ed678b71b78f6331539bc023458b46dd' THEN
    RAISE EXCEPTION 'mig NNN · las tablas viejas de rendiciones cambiaron desde la exportación del 04/11: exportar de nuevo antes de borrarlas';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Guardas: abortan si apareció un lector nuevo desde el relevamiento del 04/11
-- ---------------------------------------------------------------------------
DO $guardas$
DECLARE
  v_nuevas text;
BEGIN
  -- (1) El conjunto de funciones de public que nombran `zona` (sin _id), `preventista_id`
  -- o las tablas viejas no creció. En todas las de la lista se revisó que el nombre es un
  -- alias, una clave de JSON, otra tabla o un comentario. Una función nueva en el
  -- conjunto aborta: revisarla y sumarla, o corregirla.
  SELECT string_agg(f, ', ') INTO v_nuevas FROM (
    SELECT p.oid::regprocedure::text AS f
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosrc ~ '\mzona\M(?!_)'
       AND p.oid::regprocedure::text NOT IN (
         'asignar_preventista_zona(bigint,uuid,boolean)', 'auditoria_integridad()',
         'auditoria_reportes_join_interno()', 'bot_buscar_cliente(text,uuid,text,bigint,integer)',
         'bot_clientes_atrasados(bigint,text,uuid,uuid,boolean,boolean,integer)',
         'bot_mis_clientes(uuid,bigint,boolean,integer,integer)',
         'bot_ranking_clientes(date,date,bigint,text,uuid,uuid,text,integer)',
         'cliente_preventistas_no_ajeno()', 'clientes_alta_en_zona_propia()',
         'clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)', 'hojas_de_ruta_deposito(date)',
         'reporte_cuentas_por_cobrar(bigint)', 'reporte_ventas_por_cliente(date,date,uuid,bigint)',
         'tablero_buscar_clientes(text,bigint,integer)', 'tablero_clientes_inactivos(bigint,integer,boolean)',
         'tablero_cobertura(bigint,date)', 'tablero_ficha_cliente(bigint)',
         'tablero_productos_categoria(uuid,text,bigint,date,date,bigint)',
         'tablero_top_clientes_zona(bigint,date,date,integer,integer)')
    UNION ALL
    SELECT p.oid::regprocedure::text
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosrc ~ '\mpreventista_id\M'
       AND p.oid::regprocedure::text NOT IN (
         '_asignar_clientes_a(bigint[],uuid)', '_comision_lineas(bigint[])', '_soltar_cartera(uuid,bigint)',
         'actualizar_preventista_pedido(bigint,uuid)', 'asignar_preventista_zona(bigint,uuid,boolean)',
         'audit_cliente_preventistas()', 'auditoria_integridad()', 'avance_metas_preventista(uuid,date)',
         'bot_buscar_cliente(text,uuid,text,bigint,integer)',
         'bot_historico_pedidos_cliente(bigint,uuid,text,bigint,integer,integer)',
         'bot_mis_clientes(uuid,bigint,boolean,integer,integer)', 'bot_mis_ventas(uuid,date,date,bigint,integer)',
         'bot_productos_dejados_cliente(bigint,uuid,text,bigint)',
         'bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)',
         'cliente_preventistas_no_ajeno()', 'clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)',
         'guardar_comision_regla(bigint,bigint,uuid,text,numeric,date,date,bigint,uuid)',
         'guardar_meta_preventista(bigint,bigint,uuid,date,text,numeric,uuid,uuid,bigint[],date)',
         'jornadas_preventista(date,date,uuid)', 'listar_visitas_hoy()',
         'obtener_geolocalizacion_preventistas(date,date)', 'obtener_resumen_cuenta_cliente(integer)',
         'pedidos_cliente_asignado()', 'pedidos_proteger_columnas()',
         'registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)',
         'rendimiento_preventistas(bigint,date)', 'reporte_ventas_por_cliente(date,date,uuid,bigint)',
         'soltar_cartera_preventista_inactivo()', 'tablero_clientes_inactivos(bigint,integer,boolean)',
         'tablero_contexto()', 'tablero_ficha_cliente(bigint)', 'verificar_duplicado_cliente(numeric,numeric,text,bigint)')
    UNION ALL
    SELECT p.oid::regprocedure::text
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosrc ~ '\mrendicion(es|_items|_ajustes)\M'
       AND p.oid::regprocedure::text NOT IN (
         '_guardar_gasto(jsonb,boolean)', '_pedido_en_caja_cerrada(bigint,bigint)',
         'actualizar_forma_pago_pago(bigint,text)', 'auditoria_integridad()',
         'bot_metricas_admin_dia(date,bigint)', 'crear_rendicion_por_fecha(uuid,date)',
         'digest_secciones_del_rol(text)', 'guard_pago_fecha_cerrada()',
         'marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)',
         'marcar_entregas_masivo(bigint[],uuid,date)', 'marcar_pagos_masivo_impl(bigint[],text,date)',
         'obtener_estadisticas_rendiciones(date,date,uuid)', 'reporte_gerencial(bigint,date,date,boolean,boolean)',
         'resolver_rendicion(date,uuid,text,jsonb)')
  ) s;
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · funciones nuevas que nombran zona, preventista_id o las tablas viejas: %', v_nuevas;
  END IF;

  -- (2) Ninguna función de las de la lista lee clientes.zona, escribe clientes.preventista_id
  -- ni usa las tablas viejas (salvo las dos que se dropean abajo).
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_nuevas
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f'
     AND (p.prosrc ~ '\m(c|clientes)\.zona\M(?!_)'
          OR p.prosrc ~* 'update\s+(public\.)?clientes\M[^;]*\mpreventista_id\M'
          OR p.prosrc ~* 'insert\s+into\s+(public\.)?clientes\s*\([^)]*\mpreventista_id\M'
          OR p.prosrc ~ '\m(FROM|JOIN|INTO|UPDATE)\s+(public\.)?rendicion(es|_items|_ajustes)\M')
     AND p.oid NOT IN ('public.crear_rendicion_por_fecha(uuid,date)'::regprocedure,
                       'public.obtener_estadisticas_rendiciones(date,date,uuid)'::regprocedure);
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · todavía hay lectores o escritores: %', v_nuevas;
  END IF;

  -- (3) De las dos columnas sólo dependen su índice y su FK, y de las tablas viejas, fuera
  -- de ellas mismas, sólo vista_rendiciones. Una vista, policy o FK nueva aborta.
  SELECT string_agg(d.classid::regclass::text || ' ' || d.objid, ', ') INTO v_nuevas
    FROM pg_depend d
    JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
   WHERE d.refobjid = 'public.clientes'::regclass
     AND a.attname IN ('zona', 'preventista_id')
     AND NOT (d.classid = 'pg_class'::regclass AND d.objid = 'public.idx_clientes_preventista_id'::regclass)
     AND NOT (d.classid = 'pg_constraint'::regclass
              AND d.objid = (SELECT oid FROM pg_constraint WHERE conname = 'clientes_preventista_id_fkey'
                                                             AND conrelid = 'public.clientes'::regclass));
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · dependen de clientes.zona o clientes.preventista_id: %', v_nuevas;
  END IF;

  SELECT string_agg(DISTINCT v.relname, ', ') INTO v_nuevas
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid
    JOIN pg_class v ON v.oid = r.ev_class
   WHERE d.classid = 'pg_rewrite'::regclass
     AND d.refobjid IN ('public.rendiciones'::regclass, 'public.rendicion_items'::regclass,
                        'public.rendicion_ajustes'::regclass)
     AND v.oid NOT IN ('public.rendiciones'::regclass, 'public.rendicion_items'::regclass,
                       'public.rendicion_ajustes'::regclass, 'public.vista_rendiciones'::regclass);
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · vistas nuevas sobre las tablas viejas: %', v_nuevas;
  END IF;

  SELECT string_agg(conname || ' on ' || conrelid::regclass::text, ', ') INTO v_nuevas
    FROM pg_constraint
   WHERE contype = 'f'
     AND confrelid IN ('public.rendiciones'::regclass, 'public.rendicion_items'::regclass,
                       'public.rendicion_ajustes'::regclass)
     AND conrelid NOT IN ('public.rendiciones'::regclass, 'public.rendicion_items'::regclass,
                          'public.rendicion_ajustes'::regclass);
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · FKs de otras tablas hacia las tablas viejas: %', v_nuevas;
  END IF;

  SELECT string_agg(schemaname || '.' || tablename || '.' || policyname, ', ') INTO v_nuevas
    FROM pg_policies
   WHERE tablename NOT IN ('rendiciones', 'rendicion_items', 'rendicion_ajustes')
     AND COALESCE(qual, '') || COALESCE(with_check, '') ~ '\m(rendicion(es|_items|_ajustes)|zona)\M(?!_)';
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · policies que nombran zona o las tablas viejas: %', v_nuevas;
  END IF;
END
$guardas$;

-- ---------------------------------------------------------------------------
-- #1368 · El sistema viejo de rendiciones
-- ---------------------------------------------------------------------------
DROP VIEW public.vista_rendiciones;
DROP FUNCTION public.crear_rendicion_por_fecha(uuid, date);
DROP FUNCTION public.obtener_estadisticas_rendiciones(date, date, uuid);
DROP TABLE public.rendicion_ajustes;
DROP TABLE public.rendicion_items;
DROP TABLE public.rendiciones;
DROP FUNCTION public.update_rendiciones_updated_at();

-- ---------------------------------------------------------------------------
-- #1336 · Las dos columnas viejas de clientes (el índice y la FK se van con la columna)
-- ---------------------------------------------------------------------------
ALTER TABLE public.clientes DROP COLUMN zona, DROP COLUMN preventista_id;

-- ---------------------------------------------------------------------------
-- #1383 · La rama del vendedor de pedidos_proteger_columnas
-- ---------------------------------------------------------------------------
DO $parche$
DECLARE
  v_def   text := pg_get_functiondef('public.pedidos_proteger_columnas()'::regprocedure);
  v_ancla text := $a$    ELSIF OLD.usuario_id = auth.uid()
          AND OLD.estado IN ('pendiente', 'en_preparacion', 'asignado')
          AND NEW.estado = 'pendiente'
          AND NEW.transportista_id IS NULL
          AND NEW.fecha_entrega IS NOT DISTINCT FROM OLD.fecha_entrega THEN
      -- El vendedor saca de la ruta su pedido no entregado: es lo que hace la
      -- edición cuando le cambia la fecha a un pedido en camino. No mueve
      -- stock ni plata.
      NULL;
    ELSE
$a$;
  v_reemplazo text := $r$    -- #1383: el vendedor ya no saca su pedido de la ruta por REST. La única vía
    -- es volver_pedido_a_pendiente_por_edicion (DEFINER, no pasa por acá), que
    -- mira la hora de corte y saca el pedido de la ruta.
    ELSE
$r$;
  v_n int := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · pedidos_proteger_columnas: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  IF to_regclass('public.rendiciones') IS NOT NULL OR to_regclass('public.rendicion_items') IS NOT NULL
     OR to_regclass('public.rendicion_ajustes') IS NOT NULL OR to_regclass('public.vista_rendiciones') IS NOT NULL
     OR to_regprocedure('public.update_rendiciones_updated_at()') IS NOT NULL
     OR to_regprocedure('public.crear_rendicion_por_fecha(uuid,date)') IS NOT NULL
     OR to_regprocedure('public.obtener_estadisticas_rendiciones(date,date,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · quedó algo del sistema viejo de rendiciones';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_attribute
              WHERE attrelid = 'public.clientes'::regclass AND attnum > 0 AND NOT attisdropped
                AND attname IN ('zona', 'preventista_id')) THEN
    RAISE EXCEPTION 'mig NNN · clientes todavía tiene zona o preventista_id';
  END IF;

  SELECT md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def INTO r
    FROM pg_proc p WHERE p.oid = 'public.pedidos_proteger_columnas()'::regprocedure;
  IF r.h <> '84dab2cd9958c1725904ed20b24093e9' OR r.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' OR r.def THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas no quedó como en el repo (md5 %, acl %, definer %)', r.h, r.a, r.def;
  END IF;
END
$post$;

COMMIT;
