-- NNN · Limpieza, paso B: se dropean clientes.zona, clientes.preventista_id y el sistema viejo
-- de rendiciones, y sale la rama del vendedor de pedidos_proteger_columnas (#1336, #1368,
-- #1383). Tarjeta 10 de #1389.
--
-- VA DESPUÉS DEL PASO A Y DEL PLAZO DE LOS BUNDLES VIEJOS
--   Un bundle viejo del PWA que pide una columna dropeada rompe la consulta entera, no sólo
--   ese campo. Y uno que la manda en el body de un PATCH (el updateCliente de antes del paso
--   A manda `zona` y `preventista_id`) da PGRST204: no puede guardar un cliente. Los logs de
--   la API no muestran el body ni hay un header con la versión del front, pero todo bundle de
--   antes del paso A pide `zona,zona_id` en el embed del cliente de la lista de Pedidos al
--   cargar. Se aplica cuando esa marca no aparece en `edge_logs` durante 3 días seguidos con
--   la app en uso. Se mide sobre los GET (no los OPTIONS del preflight) con
--   `position(event_message, 'zona%2Czona_id') > 0`: con LIKE, el `%` y el `_` son
--   comodines. El PWA es `registerType: 'prompt'`: un bundle viejo vive hasta que el
--   usuario acepta la actualización. Las premisas exigen que el paso A esté aplicado.
--   Lo que esa marca no ve: un bundle viejo abierto directo en otra ruta (una pestaña
--   restaurada en /clientes), el uso offline, y quién de los que editan clientes ya cargó uno
--   nuevo (edge_logs no trae el usuario). Ese bundle falla a la vista (un 400 en la lista,
--   un PGRST204 al guardar) y no corrompe datos.
--   Y la ficha del bot de antes del paso A pide `zona` por REST: la última corrida de
--   deploy-functions.yml tiene que ser exitosa y posterior al merge del paso A.
--
-- ANTES DE APLICAR
--   1. Verificar la marca de los bundles y deploy-functions.yml (arriba).
--   2. Re-exportar lo que se pierde de clientes (la premisa 3 cambia con cada reasignación o
--      cambio de zona que haga un bundle viejo), entregarle el JSON al dueño y actualizar en
--      este archivo sólo la línea del md5 de esa premisa. El md5 que va al ledger es el del
--      archivo final.
--
-- QUÉ SE VA
--   - clientes.zona (texto) y clientes.preventista_id (uuid, con su índice y su FK a perfiles).
--     La zona sale de `zonas` por `zona_id` y el preventista de `cliente_preventistas` (#1314).
--     Lo que no se rearma desde esas tablas se exportó a JSON el 05/11 y se le entregó al
--     dueño: 129 textos de zona distintos del nombre de su zona o sin zona_id (uno solo sin
--     ninguna, 'ZONA 1. JOAQUIN', de un cliente inactivo) y 46 preventista_id sin fila en
--     cliente_preventistas (43 de Juan, inactivo; 2 de Guillermo, activo, sucursal 2; 1 de
--     preventista4.crecer). La premisa (3) exige que siga siendo lo exportado.
--   - rendiciones, rendicion_items y rendicion_ajustes, con sus policies, sus triggers
--     (trigger_rendiciones_updated_at, audit_rendiciones) y la vista vista_rendiciones. También
--     update_rendiciones_updated_at y las dos funciones que las usaban: crear_rendicion_por_fecha
--     y obtener_estadisticas_rendiciones. Las dos son sin EXECUTE para authenticated desde la
--     314 y nadie las llama. El sistema viejo no tiene funciones vivas desde la 429. Quedaba 1
--     rendición pendiente del 15/04 con 16 ítems y sin ajustes. El dueño decidió el 02/11
--     guardarla antes de borrarla: se exportó a JSON el 04/11 y se le entregó. La premisa (2)
--     exige que sea la misma que se exportó. rendicion_items tenía FK ON DELETE CASCADE a
--     pedidos: eliminar_pedido_completo ya no borra nada de ahí (#1329).
--   - La rama del vendedor de pedidos_proteger_columnas (416b): por REST pasaba su pedido a
--     pendiente y sin chofer, sin la hora de corte y sin sacarlo de la ruta. Desde #1372 (PR
--     #1377, 02/11) el front no la usa. La única vía queda en
--     volver_pedido_a_pendiente_por_edicion (DEFINER: no pasa por el trigger), y la llama
--     también actualizar_fechas_y_notas_pedido (455), cuyo UPDATE INVOKER ya no toca ni el
--     estado ni el chofer.
--
-- LOCKS
--   Los drops toman ACCESS EXCLUSIVE sobre las tablas que se van y, por sus FKs, sobre
--   recorridos, pedidos, sucursales y perfiles. El DROP COLUMN la toma sobre clientes y, por la
--   FK, sobre perfiles. Casi todas las policies leen perfiles, así que mientras la migración
--   espera un lock la app entera queda en cola detrás. Por eso:
--   - las premisas de código y las guardas van primero y sólo leen;
--   - después se toman todos los locks juntos (la vista primero), en un orden fijo y con
--     NOWAIT. Las premisas de datos van recién con los locks tomados: un PATCH que entre
--     mientras se reintenta no se pierde fuera del export. Si alguna tabla
--     está ocupada, el intento se deshace entero y se reintenta a los 200 ms, hasta 50 veces.
--     La migración nunca espera un lock: no traba la app más que lo que tardan los drops
--     (milisegundos), y no puede quedar en un 40P01 con un usuario. Si no consigue los
--     locks, aborta sin cambiar nada y se reintenta en otro momento;
--   - se aplica en una franja tranquila, a la noche. No a las 03:00: a esa hora corre el
--     pg_dump diario de la .130, que tiene todas las tablas tomadas.
--
-- QUÉ NO CAMBIA
--   rendiciones_control, rendicion_pagos_confirmados, rendicion_faltantes y sus funciones son
--   el sistema nuevo y no se tocan. pedidos_proteger_columnas sigue igual salvo esa rama.
--
-- Ensayo: scripts/test-limpieza-1336-1368-1383.sql, antes y después.
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
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Guardas: abortan si apareció un lector nuevo, o si cambió uno revisado, desde el
-- relevamiento del 04/11
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_revisadas (firma text PRIMARY KEY, md5 text NOT NULL) ON COMMIT DROP;

-- Todas las funciones y procedures de los schemas que no son del sistema que nombran `zona`
-- (sin _id), `preventista_id` o las tablas viejas, sin distinguir mayúsculas, con el md5 de
-- su cuerpo. Hoy son todas de public. En cada una se revisó que el nombre es un alias, una
-- clave de JSON, otra tabla, un comentario o un texto de mensaje ('Zona % inexistente',
-- "desde Rendiciones"). Las cinco de A van con su cuerpo de después de A. Las dos funciones
-- viejas de rendiciones no van: se dropean abajo. La firma es
-- format('%I.%I(%s)', schema, nombre, oidvectortypes(proargtypes)).
INSERT INTO _n_revisadas (firma, md5) VALUES
  ('public._anular_gasto(bigint, text, boolean)', 'b51c86655379fca2a68c6a8dc3233921'),
  ('public._asignar_clientes_a(bigint[], uuid)', '608c2d224294630ea95cec50ca08ea07'),
  ('public._comision_lineas(bigint[])', 'b20534d37d4a481d0154326fbbcccda8'),
  ('public._guardar_gasto(jsonb, boolean)', '624620059b3a847f902ec61904e91ffe'),
  ('public._pedido_en_caja_cerrada(bigint, bigint)', 'f8e28e851890364cacc15526cc1f05ba'),
  ('public._soltar_cartera(uuid, bigint)', 'fc97619e58897200f1ce3dcf64c50449'),
  ('public.actualizar_forma_pago_pago(bigint, text)', '635b6cb520d332bd543fec2043414500'),
  ('public.actualizar_preventista_pedido(bigint, uuid)', '111245f6fb109d8827264ad20458662b'),
  ('public.anular_control_por_cambio_fecha_entrega()', '00192ce77008c190570037f8a7f3849f'),
  ('public.aplicar_cambio_de_parada(bigint, uuid, date)', '9a7ac63c1f915a09d4064f85d7eb329e'),
  ('public.asignar_preventista_zona(bigint, uuid, boolean)', '33e67d03deb887225dc13c27fd62955b'),
  ('public.audit_cliente_preventistas()', '0b178069c65824b24219410d60c99389'),
  ('public.auditoria_integridad()', '89bed02a56b547e60fb052f48c47283a'),
  ('public.auditoria_reportes_join_interno()', '0bbe945ce0a9f42f094b53e3cb223cfd'),
  ('public.avance_metas_preventista(uuid, date)', '2e6695223c3add5fe1e23944884493a9'),
  ('public.bot_buscar_cliente(text, uuid, text, bigint, integer)', '1318738018edf75e4d19c8d02d165de8'),
  ('public.bot_clientes_atrasados(bigint, text, uuid, uuid, boolean, boolean, integer)', 'c71f023cda884934a4a2bdbe59a8a12e'),
  ('public.bot_historico_pedidos_cliente(bigint, uuid, text, bigint, integer, integer)', 'd9fe2cafcb20e5c99a2cec8d9806fde4'),
  ('public.bot_metricas_admin_dia(date, bigint)', '71ce6341364a568ef6d67b8a8fedaa3e'),
  ('public.bot_mis_clientes(uuid, bigint, boolean, integer, integer)', 'ed5779e0b332bb667eb83e455ecac6e9'),
  ('public.bot_mis_ventas(uuid, date, date, bigint, integer)', 'fff91e69cfa74fd6c95ac05b57a5299e'),
  ('public.bot_productos_dejados_cliente(bigint, uuid, text, bigint)', 'c561a7f8d138bf9f5c37a8901a4525b8'),
  ('public.bot_productos_recurrentes_cliente(bigint, uuid, text, bigint, integer, integer)', 'ae5a99e53110019012a8515bee7d8b1e'),
  ('public.bot_ranking_clientes(date, date, bigint, text, uuid, uuid, text, integer)', 'd82c8049f75778101a0f891896b5af09'),
  ('public.cliente_preventistas_no_ajeno()', '79501f926fd9b9e940bdb5acf94b14e4'),
  ('public.clientes_alta_en_zona_propia()', 'dcf34648d3a5bc87509b64f098a30219'),
  ('public.clientes_ritmo_compra(bigint, text, uuid, uuid, bigint)', 'a637f5ac54fa8c6f4fb77908c2124860'),
  ('public.desmarcar_rendicion_controlada(date, uuid)', 'eaa447cf71f857dadbb58aa42049cbde'),
  ('public.digest_secciones_del_rol(text)', '7cb5aad1f947a676722a49598967e943'),
  ('public.guard_pago_fecha_cerrada()', 'a763cdd5980b0e0f18cb549ee97629de'),
  ('public.guardar_comision_regla(bigint, bigint, uuid, text, numeric, date, date, bigint, uuid)', 'bc9025a19710c37e7055fcab728225fd'),
  ('public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint[], date)', '25c6d5f2bfaff8d934f73fbfd697180c'),
  ('public.hojas_de_ruta_deposito(date)', '16cf8fd128ece4d7fa8f66881c45812f'),
  ('public.jornadas_preventista(date, date, uuid)', 'ee5c4ea64ba52b98cb5e20d95ed692dd'),
  ('public.listar_visitas_hoy()', '2b01c13670d61b16ddcc89cacf3d65b0'),
  ('public.marcar_entrega_y_pago_masivo_impl(bigint[], uuid, text, date)', '9a32b73da6395bb29075c00d8c3b5469'),
  ('public.marcar_entregas_masivo(bigint[], uuid, date)', 'ac0c4a331c9876d5f33c778cbedc4fc8'),
  ('public.marcar_pagos_masivo_impl(bigint[], text, date)', '7dfde9f7b5f42e8bb1214e3649e28e09'),
  ('public.obtener_geolocalizacion_preventistas(date, date)', '5736d55dc4a2e8117d5613ec6e59a3f4'),
  ('public.obtener_resumen_cuenta_cliente(integer)', '7c55183dd55e7f8adb7670f8a0e5568f'),
  ('public.pedidos_cliente_asignado()', '44d1b9ec5113485845bcae37ac62af7c'),
  ('public.pedidos_proteger_columnas()', 'b1e8fb3ca55e86967c7d72eb72e0652c'),
  ('public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text)', 'a1fc32005cd3e34bebf712fce2c64c89'),
  ('public.rendicion_faltantes_guarda_gasto()', 'de6cc002c115576832070636b034fa3a'),
  ('public.rendimiento_preventistas(bigint, date)', 'de5da1d80c069e09e5d0b1cbccb36707'),
  ('public.reporte_cuentas_por_cobrar(bigint)', '24a7fb85efa3487cf4a3eb772aa5999b'),
  ('public.reporte_gerencial(bigint, date, date, boolean, boolean)', '99f728cbdd7cda81d212119836112dac'),
  ('public.reporte_ventas_por_cliente(date, date, uuid, bigint)', '1f0b4a5e561f0ddc78727a635a32c5ba'),
  ('public.resolver_rendicion(date, uuid, text, jsonb)', 'ecbb9b34771f5a706b6d00446377464d'),
  ('public.soltar_cartera_preventista_inactivo()', 'cabcdb5cba66ad96c75d4a7db07d22c7'),
  ('public.tablero_buscar_clientes(text, bigint, integer)', 'ec3d3ab6e5760dd8be3f75d09020133d'),
  ('public.tablero_clientes_inactivos(bigint, integer, boolean)', '7c5a6663b2201d0becdaa201f385d9d0'),
  ('public.tablero_cobertura(bigint, date)', 'b5e9c1a5bf664404035ba1b2f4ba4076'),
  ('public.tablero_contexto()', '220abf7e7977c0969f0eaf7e2bdbe16b'),
  ('public.tablero_ficha_cliente(bigint)', 'bbcba23471cb9ed4c0acdd30712c72ae'),
  ('public.tablero_guardar_meta_cobertura(bigint, date, numeric, integer)', '54c044ced11ee00fa6076357241c9d35'),
  ('public.tablero_productos_categoria(uuid, text, bigint, date, date, bigint)', '7d41f68f5489d97b1886bc93ff5474ab'),
  ('public.tablero_top_clientes_zona(bigint, date, date, integer, integer)', '8594ad0ce2f69e64ae842786b211c74f'),
  ('public.verificar_duplicado_cliente(numeric, numeric, text, bigint)', 'c431610338f04a2387264ee8638e48d7');

DO $guardas$
DECLARE
  v_nuevas text;
BEGIN
  -- (1) Ninguna revisada desapareció ni cambió de cuerpo. Una que cambió puede haber sumado
  -- una lectura con otro alias: revisarla de nuevo y actualizar su md5.
  SELECT string_agg(r.firma || COALESCE(' (md5 ' || md5(p.prosrc) || ')', ' (no existe)'), ', ') INTO v_nuevas
    FROM _n_revisadas r
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(r.firma)
   WHERE p.oid IS NULL OR md5(p.prosrc) <> r.md5;
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · funciones revisadas que cambiaron desde el 04/11: %', v_nuevas;
  END IF;

  -- (2) No hay funciones ni procedures nuevos, en ningún schema que no sea del sistema, que
  -- nombren esas columnas o esas tablas. Se compara por oid, con la firma calificada: no
  -- depende del search_path.
  SELECT string_agg(format('%I.%I(%s)', n.nspname, p.proname, oidvectortypes(p.proargtypes)), ', ') INTO v_nuevas
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
     AND p.prokind IN ('f', 'p') AND p.prolang NOT IN (12, 13)
     AND (p.prosrc ~* '\mzona\M(?!_)' OR p.prosrc ~* '\mpreventista_id\M'
          OR p.prosrc ~* '\mrendicion(es|_items|_ajustes)\M')
     AND p.oid NOT IN (SELECT to_regprocedure(firma) FROM _n_revisadas)
     AND p.oid NOT IN ('public.crear_rendicion_por_fecha(uuid,date)'::regprocedure,
                       'public.obtener_estadisticas_rendiciones(date,date,uuid)'::regprocedure);
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · funciones nuevas que nombran zona, preventista_id o las tablas viejas: %', v_nuevas;
  END IF;

  -- (3) Ninguna lee clientes.zona, escribe clientes.preventista_id ni usa las tablas viejas
  -- (salvo las dos que se dropean abajo). Con (1) es redundante: queda como red por si una
  -- revisada se actualiza sin mirarla.
  SELECT string_agg(format('%I.%I(%s)', n.nspname, p.proname, oidvectortypes(p.proargtypes)), ', ') INTO v_nuevas
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
     AND p.prokind IN ('f', 'p') AND p.prolang NOT IN (12, 13)
     AND (p.prosrc ~* '\m(c|clientes)\.zona\M(?!_)'
          OR p.prosrc ~* 'update\s+(public\.)?clientes\M[^;]*\mpreventista_id\M'
          OR p.prosrc ~* 'insert\s+into\s+(public\.)?clientes\s*\([^)]*\mpreventista_id\M'
          OR p.prosrc ~* '\m(FROM|JOIN|INTO|UPDATE)\s+(public\.)?rendicion(es|_items|_ajustes)\M')
     AND p.oid NOT IN ('public.crear_rendicion_por_fecha(uuid,date)'::regprocedure,
                       'public.obtener_estadisticas_rendiciones(date,date,uuid)'::regprocedure);
  IF v_nuevas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · todavía hay lectores o escritores: %', v_nuevas;
  END IF;

  -- (4) De las dos columnas sólo dependen su índice y su FK, y de las tablas viejas, fuera
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
-- Locks: todos juntos, en orden fijo, sin esperar (ver LOCKS en el encabezado)
-- ---------------------------------------------------------------------------
DO $locks$
BEGIN
  FOR i IN 1 .. 50 LOOP
    BEGIN
      LOCK TABLE public.vista_rendiciones, public.rendicion_ajustes, public.rendicion_items,
                 public.rendiciones, public.recorridos, public.pedidos, public.clientes,
                 public.sucursales, public.perfiles
        IN ACCESS EXCLUSIVE MODE NOWAIT;
      RETURN;
    EXCEPTION WHEN lock_not_available THEN
      PERFORM pg_sleep(0.2);
    END;
  END LOOP;
  RAISE EXCEPTION 'mig NNN · no se consiguieron los locks en 50 intentos: no cambió nada, reintentar en una franja más tranquila';
END
$locks$;

-- ---------------------------------------------------------------------------
-- Premisas de datos, con los locks tomados: nada las puede cambiar hasta el COMMIT
-- ---------------------------------------------------------------------------
DO $premisas_datos$
BEGIN
  -- (2) La rendición vieja es la que se exportó el 04/11: 1 cabecera, 16 ítems, 0 ajustes.
  IF md5(jsonb_build_object(
           'r', (SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM rendiciones r),
           'i', (SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM rendicion_items i),
           'a', (SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY id), '[]') FROM rendicion_ajustes a)
         )::text) <> 'ed678b71b78f6331539bc023458b46dd' THEN
    RAISE EXCEPTION 'mig NNN · las tablas viejas de rendiciones cambiaron desde la exportación del 04/11: exportar de nuevo antes de borrarlas';
  END IF;

  -- (3) Lo que se pierde de clientes es lo que se exportó: el texto de zona distinto del
  -- nombre de su zona (o sin zona_id) y el preventista_id sin fila en cliente_preventistas.
  -- Un bundle viejo todavía puede escribir esas columnas: si cambió, exportar de nuevo y
  -- actualizar esta línea (ver ANTES DE APLICAR).
  IF md5(COALESCE((
       SELECT jsonb_agg(jsonb_build_array(c.id, c.zona, c.preventista_id) ORDER BY c.id)
         FROM clientes c
         LEFT JOIN zonas z ON z.id = c.zona_id
        WHERE (NULLIF(btrim(c.zona), '') IS NOT NULL AND c.zona IS DISTINCT FROM z.nombre)
           OR (c.preventista_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp
                                WHERE cp.cliente_id = c.id AND cp.preventista_id = c.preventista_id))
     ), '[]')::text) <> '1301c6283af3f3de26a39cceae28e49a' THEN
    RAISE EXCEPTION 'mig NNN · lo que se pierde de clientes.zona o clientes.preventista_id cambió desde la última exportación: exportar de nuevo antes del drop';
  END IF;
END
$premisas_datos$;

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
