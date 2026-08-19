-- ============================================================================
-- Migración 188: la anon key deja de ejecutar RPCs del schema public
-- ============================================================================
-- Proyecto: hmuchlzmuqqxcldbzkgc (ManaosApp). Auditoría de permisos 2026-08-19.
--
-- QUÉ PASA HOY
-- ------------
-- Supabase trae un ALTER DEFAULT PRIVILEGES que le concede EXECUTE a `anon` de
-- forma EXPLÍCITA en cada función nueva del schema public, ADEMÁS del grant
-- implícito a PUBLIC que pone Postgres. El ACL de una función recién creada es:
--
--     {=X/postgres, postgres=X/postgres, anon=X/postgres,
--      authenticated=X/postgres, service_role=X/postgres}
--      ^^^^^^^^^^^^ este es PUBLIC
--
-- Por eso ninguna de las dos mitades del REVOKE alcanza sola:
--
--     REVOKE ... FROM PUBLIC        -> sobrevive anon=X/postgres
--     REVOKE ... FROM anon          -> sobrevive =X/postgres (anon entra por PUBLIC)
--     REVOKE ... FROM PUBLIC, anon  -> la única que cierra
--
-- El repo usó las tres variantes. Las migraciones 103-131 lo hicieron bien; de
-- la 140 en adelante se estandarizó `REVOKE ALL ... FROM PUBLIC` a secas, que
-- no cierra nada.
--
-- El caso más nítido es la 089, que dice textual:
--
--     -- Solo lo llaman los wrappers DEFINER; no se expone a clientes.
--     REVOKE ALL ON FUNCTION public._aplicar_cambio_producto(...) FROM PUBLIC;
--
-- La intención era exactamente la correcta y el mecanismo la dejó pasar.
-- `_aplicar_cambio_producto` es SECURITY DEFINER, no tiene gate propio (recibe
-- p_sucursal_id y p_usuario_id por parámetro: quien llama declara quién es) y
-- mueve stock. Sus tres wrappers -- registrar_cambio_producto,
-- aplicar_cambio_de_parada, crear_pedido_cambio_en_ruta -- sí son SECURITY
-- DEFINER y sí chequean es_encargado_o_admin() / current_sucursal_id().
--
-- QUÉ HACE ESTA MIGRACIÓN
-- -----------------------
--   0. Saca `anon` del ALTER DEFAULT PRIVILEGES, para que las funciones NUEVAS
--      no nazcan con el grant explícito. OJO: NO se puede sacar a PUBLIC del
--      default (ver el paso 0, está medido) — la garantía de que esto no
--      recaiga es el gate de CI de la 189, no el default privilege.
--   1. Congela como grants EXPLÍCITOS el acceso que authenticated y
--      service_role tienen HOY. Es la red de seguridad del paso 2: hay
--      funciones cuyo único permiso vigente es el de PUBLIC (p.ej.
--      recalcular_recorrido, con ACL `=X/postgres`), y sacar PUBLIC sin este
--      paso previo también se lo quitaría a la app.
--   2. Barre PUBLIC + anon de todas las funciones de public.
--   3. A los internos les saca además authenticated: funciones `_*`, `*_impl` y
--      las que devuelven `trigger`. Sus llamadores son SECURITY DEFINER y las
--      ejecutan como owner, así que no necesitan permiso propio. El EXECUTE de
--      una función trigger se chequea en CREATE TRIGGER, no cuando dispara: la
--      069 ya hizo esto en prod y los triggers siguen andando. Acá alcanza a
--      las ~20 funciones trigger creadas después de aquella.
--   4. Verificación fail-closed en la MISMA transacción: si quedó algo abierto
--      a anon, o si alguna RPC que usa la app perdió authenticated, RAISE
--      EXCEPTION y rollback de todo.
--
-- QUIÉN DEPENDE DE ESTO (verificado contra el código, no supuesto)
-- ---------------------------------------------------------------
--   * Web: entra como `authenticated`; requiere login, no hay RPC pre-sesión.
--     Llama 96 RPCs (grep `.rpc(` sobre src/, excluidos los tests) -- la lista
--     está abajo, en el paso 4.
--   * Bot de Telegram y edge functions (optimizar-ruta, telegram-webhook,
--     telegram-digest): usan SUPABASE_SERVICE_ROLE_KEY.
--     Ver supabase/functions/_shared/supabase.ts.
--   * scripts/check-integridad.mjs y scripts/check-migrations.mjs: service_role.
--   Ningún consumidor conocido llama a PostgREST sin sesión.
--
-- SE EXCLUYEN del barrido las funciones que pertenecen a una extensión
-- (pg_depend.deptype = 'e'): pgcrypto, pg_trgm, unaccent, etc. Tocarles el ACL
-- rompe índices y operadores, y no son parte del problema.
--
-- CÓMO PROBARLA SIN APLICARLA
-- ---------------------------
-- Pegar este archivo entero en el SQL editor y agregarle al final:
--     DO $dry$ BEGIN RAISE EXCEPTION 'dry-run'; END $dry$;
-- La excepción garantiza el rollback; los NOTICE de los pasos 1-4 igual salen,
-- así que se ven los conteos reales sin dejar nada aplicado.
--
-- REVERSIÓN (si algo se rompe):
--     ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--       GRANT EXECUTE ON FUNCTIONS TO anon;
--     GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Default privileges: sacar el grant explícito a anon
-- ----------------------------------------------------------------------------
-- Sin esto, la próxima migración que cree una función le vuelve a dar EXECUTE a
-- anon de forma explícita. `authenticated` y `service_role` se mantienen en el
-- default: la app sigue andando sin que cada migración tenga que acordarse.
--
-- NO se puede sacar a PUBLIC del default, y conviene tenerlo claro. Medido
-- sobre Postgres 17:
--
--     ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
--
--   es un no-op: no crea fila en pg_default_acl, y cuando la fila existe (por
--   el GRANT de Supabase) el acldefault() built-in — que incluye `=X` para
--   PUBLIC — se concatena igual. Toda función nueva nace con `=X/postgres`.
--
-- Consecuencia práctica, y es la parte que importa: después de este paso, una
-- migración que escriba el patrón habitual del repo
--
--     REVOKE ALL ON FUNCTION public.mi_rpc(...) FROM PUBLIC;
--
--   SÍ cierra a anon, porque ya no queda un `anon=X/postgres` atrás. O sea que
--   esto convierte en correcto el patrón que hoy está roto en 40 migraciones.
--   Igual conviene escribir las dos mitades (`FROM PUBLIC, anon`): es
--   idempotente y sirve para las funciones viejas, que sí tienen el explícito.
--
-- La garantía real de no recaída es el gate de CI (mig 189 +
-- scripts/check-permisos.mjs), no este ALTER.
--
-- `FOR ROLE postgres` no es decorativo: en prod hay DOS entradas de default
-- privileges para funciones de public, una de `postgres` y otra de
-- `supabase_admin`. Postgres aplica **sólo la del rol que crea la función**, y
-- las migraciones corren como postgres (verificado: `current_user` = postgres,
-- `is_superuser` = off). La de supabase_admin es de la plataforma: no somos
-- superuser, no la podemos ni la debemos tocar.

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;


-- ----------------------------------------------------------------------------
-- 1. Piso: congelar el acceso vigente de authenticated / service_role
-- ----------------------------------------------------------------------------
-- has_function_privilege() responde por el permiso EFECTIVO, así que devuelve
-- true también cuando llega sólo por PUBLIC. Ese es justamente el caso que hay
-- que materializar antes de sacar PUBLIC.
--
-- Efecto colateral buscado: lo que la 069 y la 167 ya cerraron (RPCs del bot,
-- las 4 `*_impl`) da has_function_privilege = false y NO se vuelve a otorgar.
-- El barrido no revierte hardening previo.

DO $piso$
DECLARE
  r      RECORD;
  n_auth INT := 0;
  n_svc  INT := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig,
           has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_ok,
           has_function_privilege('service_role',  p.oid, 'EXECUTE') AS svc_ok
    FROM pg_proc p
    JOIN pg_type t ON t.oid = p.prorettype
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prokind IN ('f', 'p')
      AND t.typname <> 'trigger'
      AND p.proname NOT LIKE '\_%'
      AND p.proname NOT LIKE '%\_impl'
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.objid = p.oid
          AND d.classid = 'pg_proc'::regclass
          AND d.deptype = 'e'
      )
  LOOP
    IF r.auth_ok THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
      n_auth := n_auth + 1;
    END IF;
    IF r.svc_ok THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
      n_svc := n_svc + 1;
    END IF;
  END LOOP;

  RAISE NOTICE '[188/1] grants explícitos: authenticated=%, service_role=%', n_auth, n_svc;
END
$piso$;


-- ----------------------------------------------------------------------------
-- 2. Barrido: sacar PUBLIC y anon de TODAS las funciones de public
-- ----------------------------------------------------------------------------

DO $barrido$
DECLARE
  r RECORD;
  n INT := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prokind IN ('f', 'p')
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.objid = p.oid
          AND d.classid = 'pg_proc'::regclass
          AND d.deptype = 'e'
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.sig);
    n := n + 1;
  END LOOP;

  RAISE NOTICE '[188/2] PUBLIC+anon revocados en % funciones', n;
END
$barrido$;


-- ----------------------------------------------------------------------------
-- 3. Internos: tampoco authenticated
-- ----------------------------------------------------------------------------
-- Convención del repo, ahora con efecto real:
--   `_nombre`      -> helper interno; sólo lo llaman wrappers SECURITY DEFINER
--   `nombre_impl`  -> cuerpo real detrás de un wrapper (idempotencia, mig 167)
--   RETURNS trigger-> lo dispara el motor; nadie lo invoca por nombre
-- Ninguna de las 96 RPCs que usa la app cae en estos patrones (verificado).

DO $internos$
DECLARE
  r RECORD;
  n INT := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_type t ON t.oid = p.prorettype
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prokind IN ('f', 'p')
      AND (
            p.proname LIKE '\_%'
         OR p.proname LIKE '%\_impl'
         OR t.typname = 'trigger'
      )
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.objid = p.oid
          AND d.classid = 'pg_proc'::regclass
          AND d.deptype = 'e'
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    n := n + 1;
  END LOOP;

  RAISE NOTICE '[188/3] internos cerrados también a authenticated: %', n;
END
$internos$;


-- ----------------------------------------------------------------------------
-- 4. Verificación fail-closed (misma transacción: si falla, rollback de todo)
-- ----------------------------------------------------------------------------

DO $verif$
DECLARE
  v_abiertas   TEXT;
  v_n_abiertas INT;
  v_rotas      TEXT;
  v_n_rotas    INT;
  v_faltantes  TEXT;
  -- Las 96 RPCs que llama src/ (grep `.rpc(`, excluidos archivos de test).
  v_app_rpcs   TEXT[] := ARRAY[
    'aceptar_movimiento_sucursal',
    'actualizar_barridas_recorrido',
    'actualizar_compra_items',
    'actualizar_forma_pago_pago',
    'actualizar_minimo_venta_masivo',
    'actualizar_pedido_items',
    'actualizar_precios_masivo',
    'actualizar_preventista_pedido',
    'ajustar_stock_promocion_completo',
    'anular_compra_atomica',
    'anular_salvedad',
    'aplicar_cambio_de_parada',
    'aplicar_control_stock',
    'aplicar_orden_ruta',
    'asignar_marca_masiva',
    'avance_metas_preventista',
    'bot_admin_audit_log',
    'bot_admin_audit_summary',
    'bot_admin_digests_enviados',
    'bot_admin_listar_vinculados',
    'bot_admin_toggle_usuario',
    'calcular_comisiones',
    'cambiar_cliente_pedido',
    'cambiar_proveedor_compra',
    'cambiar_sucursal',
    'cambiar_tipo_factura_pedido',
    'cambiar_transportista_recorrido',
    'cancelar_movimiento_sucursal',
    'cancelar_pedido_con_stock',
    'confirmar_rendicion',
    'consolidar_condiciones',
    'consultar_control_rendicion',
    'crear_condicion_para_producto',
    'crear_movimiento_sucursal',
    'crear_pedido_cambio_en_ruta',
    'crear_pedido_completo',
    'crear_pedido_idempotente',
    'crear_recorrido',
    'denegar_movimiento_sucursal',
    'desactivar_comision_regla',
    'desactivar_meta_preventista',
    'descontar_stock_atomico',
    'desmarcar_rendicion_controlada',
    'editar_movimiento_sucursal',
    'eliminar_pedido_completo',
    'eliminar_proveedor',
    'generar_codigo_vinculacion_bot',
    'get_deposito_sucursal',
    'get_destino_sucursal',
    'guardar_comision_regla',
    'guardar_horario_cliente_masivo',
    'guardar_meta_gerencial',
    'guardar_meta_preventista',
    'jornada_preventista_detalle',
    'jornadas_preventista',
    'listar_visitas_hoy',
    'marcar_entrega_y_pago_masivo',
    'marcar_entregas_masivo',
    'marcar_no_entregado',
    'marcar_notificacion_leida',
    'marcar_pagos_masivo',
    'marcar_rendicion_controlada',
    'marcar_todas_notificaciones_leidas',
    'obtener_detalle_rendicion',
    'obtener_deudores_mora',
    'obtener_estadisticas_pedidos',
    'obtener_geolocalizacion_preventistas',
    'obtener_pagos_rendicion_cliente',
    'obtener_pedidos_ctacte_pendientes',
    'obtener_resumen_cuenta_cliente',
    'obtener_resumen_rendiciones',
    'posicion_fiscal',
    'quitar_pedido_de_recorridos_activos',
    'registrar_cambio_producto',
    'registrar_compra_completa',
    'registrar_geolocalizacion_pedido',
    'registrar_nota_credito',
    'registrar_origen_precio_items',
    'registrar_pago_cliente_fifo',
    'registrar_pago_combinado_cliente_fifo',
    'registrar_salvedad',
    'registrar_visita_cliente',
    'rendicion_dia_cerrada',
    'rendimiento_preventistas',
    'reporte_alerta_detalle',
    'reporte_gerencial',
    'reporte_valuacion_inventario',
    'resolver_rendicion',
    'resolver_salvedad',
    'restaurar_stock_atomico',
    'set_deposito_sucursal',
    'set_destino_sucursal',
    'simular_salvedad_promo_impacto',
    'simular_salvedades_promo_impacto',
    'sustituir_regalo_pedido',
    'ultima_fecha_caja_cerrada'
  ];
BEGIN
  -- 4a. Nada de public queda ejecutable por anon.
  --     Si algo sobrevive suele ser por owner distinto de postgres: el REVOKE
  --     emite WARNING y sigue. Por eso el reporte incluye el owner.
  SELECT count(*), string_agg(sig || ' [owner=' || owner || ']', E'\n  ' ORDER BY sig)
    INTO v_n_abiertas, v_abiertas
  FROM (
    SELECT p.oid::regprocedure::text     AS sig,
           pg_get_userbyid(p.proowner)   AS owner
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prokind IN ('f', 'p')
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.objid = p.oid
          AND d.classid = 'pg_proc'::regclass
          AND d.deptype = 'e'
      )
  ) s;

  IF v_n_abiertas > 0 THEN
    RAISE EXCEPTION E'[188] Quedaron % funciones ejecutables por anon:\n  %',
      v_n_abiertas, v_abiertas;
  END IF;

  -- 4b. Ninguna RPC que usa la app perdió authenticated.
  SELECT count(*), string_agg(sig, ', ' ORDER BY sig)
    INTO v_n_rotas, v_rotas
  FROM (
    SELECT p.oid::regprocedure::text AS sig
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prokind IN ('f', 'p')
      AND p.proname = ANY (v_app_rpcs)
      AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) s;

  IF v_n_rotas > 0 THEN
    RAISE EXCEPTION E'[188] % RPCs de la app quedaron sin EXECUTE para authenticated:\n  %',
      v_n_rotas, v_rotas;
  END IF;

  -- 4c. Drift informativo: nombres que la app llama y no existen en el catálogo.
  --     No aborta (puede ser una RPC de una rama sin mergear), pero conviene verlo.
  SELECT string_agg(a, ', ' ORDER BY a) INTO v_faltantes
  FROM unnest(v_app_rpcs) AS a
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = a
  );

  IF v_faltantes IS NOT NULL THEN
    RAISE NOTICE '[188/4c] la app llama RPCs que no existen en public: %', v_faltantes;
  END IF;

  -- 4d. El paso 0 quedó grabado: el default de `postgres` ya no le da EXECUTE a anon.
  --     Se filtra por defaclrole: hay DOS entradas de default privileges para
  --     funciones de public, una de `postgres` y otra de `supabase_admin`, y
  --     sólo aplica la del rol que CREA la función. Las migraciones corren como
  --     postgres, así que la de supabase_admin no nos toca (y es de Supabase:
  --     no somos superuser, no podemos ni deberíamos modificarla).
  IF EXISTS (
    SELECT 1
    FROM pg_default_acl d, aclexplode(d.defaclacl) a
    WHERE d.defaclobjtype = 'f'
      AND d.defaclnamespace = 'public'::regnamespace
      AND d.defaclrole = 'postgres'::regrole
      AND a.grantee = 'anon'::regrole
      AND a.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION '[188] El default privilege de postgres sigue otorgándole EXECUTE a anon; el paso 0 no quedó.';
  END IF;

  RAISE NOTICE '[188/4] OK — 0 funciones abiertas a anon, RPCs de la app intactas, default cerrado para anon.';
  RAISE NOTICE '[188/!] Recordá: las funciones NUEVAS igual nacen con PUBLIC (=X/postgres). Cada migración debe revocarlo. Lo vigila scripts/check-permisos.mjs.';
END
$verif$;
