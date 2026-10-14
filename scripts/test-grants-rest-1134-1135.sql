-- Ensayo de #1134 (stock_historico por REST) y #1135 (primera tanda del
-- barrido de grants): por REST se escribe sólo lo que el front escribe, anon no
-- tiene nada y las tablas nuevas nacen cerradas.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en una
-- excepción (el veredicto es el mensaje), y cada caso corre en su propio
-- sub-bloque que se revierte al terminar. No usa TRUNCATE ni DISABLE TRIGGER, y
-- no llama nextval (una secuencia no se revierte): para anon se lee
-- last_value.
--
-- Simula PostgREST como test-compras-rest-1124.sql: `SET LOCAL ROLE
-- authenticated` (o anon), el `sub` de un perfil real en request.jwt.claims y
-- la sucursal en x-sucursal-id. Usa una sucursal activa con admin, encargado,
-- preventista y transportista activos, y otra sucursal activa donde el
-- encargado no está asignado.
--
-- Sin la migración tiene que FALLAR en A, A2, C, D, E, F y H. B, G e I pasan
-- antes y después (regresiones). Con la migración (inline antes del DO, y el
-- sentinel de rollback al final) tiene que dar 'ENSAYO OK'.
--
-- #1134 · stock_historico
--   A  · admin, POST directo con origen 'compra' → 42501
--   A2 · admin, POST directo con la forma exacta de la ficha
--        ('ajuste_manual', usuario_id = auth.uid(), sin referencia) a
--        profundidad 0 → 42501
--   B  · regresión: admin, PATCH productos.stock + 3 → OK y una fila nueva
--        'ajuste_manual' con el admin y anterior/nuevo correctos; y
--        aplicar_control_stock (DEFINER) sigue dejando 'control_stock'
--   C  · admin, UPDATE y DELETE de stock_historico → 42501
-- #1135
--   D  · anon: SELECT de pedidos, de productos(id) y de vista_rendiciones,
--        INSERT en stock_historico y SELECT last_value de una secuencia →
--        42501; y por catálogo ninguna relación ni secuencia con privilegios
--        para anon
--   E  · catálogo: las escrituras de authenticated son exactamente la lista
--        blanca (que incluye TODA escritura REST del front, ver
--        scripts/grants-rest.json), sin TRUNCATE/REFERENCES/TRIGGER/MAINTAIN;
--        el UPDATE de pedidos y mt_pedidos_update siguen; las 4 RPC que pasan
--        a DEFINER no salen en auditoria_definer_sin_rol()
--   F  · caminos REST cerrados (42501): admin UPDATE pagos.monto, DELETE
--        pedido_items, DELETE pedidos, INSERT/UPDATE mermas_stock, INSERT
--        audit_logs, UPDATE salvedades_items, INSERT pedidos_eliminados,
--        UPDATE pedido_historial, DELETE de la alícuota vigente y UPDATE de su
--        tasa, UPDATE notificaciones.leida; preventista INSERT pedidos;
--        encargado INSERT producto_medidas (unidades_por 0) e INSERT
--        cargo_conceptos; y, con el mensaje del grant ('permission denied for
--        table …') y no otro 42501: DELETE de proveedores (admin y
--        encargado) y UPDATE de salvedades_items.lotes_devueltos
--   G  · regresiones REST: admin INSERT/UPDATE/DELETE de una marca; upsert de
--        grupo_precio_productos; el preventista dueño hace PATCH de
--        pedidos.notas (+1 en pedido_historial, saldo del cliente igual);
--        admin INSERT y DELETE de un pago; UPDATE de clientes y del perfil
--        propio
--   H  · default privileges: una tabla nueva de postgres nace sin nada para
--        anon (ni su secuencia) y con sólo SELECT para authenticated
--   I  · las 4 RPC que pasan a DEFINER (regresión): cambiar y cancelar una
--        alícuota programada; cancelar la vigente → 22023; preventista →
--        42501; guardar_producto_medidas del encargado (propio OK, de otra
--        sucursal → 23503, con x-sucursal-id ajeno → 22023);
--        asegurar_cargo_concepto (encargado OK, preventista → 42501)
--
-- Veredicto: el error 'ENSAYO OK (todo revertido)' o 'ENSAYO FALLÓ …' con la
-- lista de fallas. En los dos casos no queda nada escrito.
--
--   psql "$DATABASE_URL" -f scripts/test-grants-rest-1134-1135.sql

DO $ensayo$
DECLARE
  v_suc     bigint;
  v_otra    bigint;
  v_admin   uuid;
  v_enc     uuid;
  v_prev    uuid;
  v_trans   uuid;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_ps      bigint;   -- producto de v_suc
  v_po      bigint;   -- producto de v_otra
  v_med     bigint;   -- una medida activa
  v_encu    bigint;   -- encuadre con alícuota vigente
  v_aliv    bigint;   -- su alícuota vigente
  v_cli     bigint;   -- cliente activo de v_suc
  v_notif   bigint;   -- notificación del admin
  v_grupo   bigint;   -- grupo de precio de v_suc
  v_err     text;
  v_errs    text[];
  v_res     text;
  v_n       bigint;
  v_n2      bigint;
  v_t       text;
  v_txt     text[];
  r         record;
  v_fallas  text[] := '{}';
  -- La lista blanca de escrituras de authenticated (= scripts/grants-rest.json).
  v_lista   text[] := ARRAY[
    'categorias.DELETE', 'categorias.INSERT', 'categorias.UPDATE',
    'cliente_descuentos_categoria.DELETE', 'cliente_descuentos_categoria.INSERT',
    'cliente_preventistas.DELETE', 'cliente_preventistas.INSERT',
    'clientes.DELETE', 'clientes.INSERT', 'clientes.UPDATE',
    'grupo_precio_escala_minimos.DELETE', 'grupo_precio_escala_minimos.INSERT', 'grupo_precio_escala_minimos.UPDATE',
    'grupo_precio_escalas.DELETE', 'grupo_precio_escalas.INSERT', 'grupo_precio_escalas.UPDATE',
    'grupo_precio_productos.DELETE', 'grupo_precio_productos.INSERT', 'grupo_precio_productos.UPDATE',
    'grupos_precio.DELETE', 'grupos_precio.INSERT', 'grupos_precio.UPDATE',
    'ii_encuadres.INSERT', 'ii_encuadres.UPDATE',
    'marcas.DELETE', 'marcas.INSERT', 'marcas.UPDATE',
    'pagos.DELETE', 'pagos.INSERT',
    'pedido_historial.INSERT',
    'pedidos.UPDATE',
    'perfil_roles.DELETE', 'perfil_roles.INSERT',
    'perfiles.UPDATE',
    'productos.DELETE', 'productos.INSERT', 'productos.UPDATE',
    'promocion_productos.DELETE', 'promocion_productos.INSERT',
    'promocion_reglas.DELETE', 'promocion_reglas.INSERT', 'promocion_reglas.UPDATE',
    'promociones.DELETE', 'promociones.INSERT', 'promociones.UPDATE',
    'proveedores.INSERT', 'proveedores.UPDATE',
    'recorridos.UPDATE',
    'stock_historico.INSERT',
    'zonas.DELETE', 'zonas.INSERT', 'zonas.UPDATE'];
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT s.id, a.usuario_id, e.usuario_id, p.usuario_id, t.usuario_id
    INTO v_suc, v_admin, v_enc, v_prev, v_trans
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin' ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado' ORDER BY us.usuario_id LIMIT 1) e ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista' ORDER BY us.usuario_id LIMIT 1) p ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista' ORDER BY us.usuario_id LIMIT 1) t ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con admin, encargado, preventista y transportista activos';
  END IF;
  SELECT s.id INTO v_otra FROM sucursales s
   WHERE s.activa AND s.id <> v_suc
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.sucursal_id = s.id AND us.usuario_id = v_enc)
   ORDER BY s.id LIMIT 1;
  IF v_otra IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita otra sucursal activa donde el encargado % no esté asignado', v_enc;
  END IF;

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  -- Una sentencia como PostgREST: NULL si pasó, o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest(p_sql text, p_rol text DEFAULT 'authenticated') RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I', p_rol);
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Filas afectadas como PostgREST, o el error.
  CREATE FUNCTION pg_temp.rest_n(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    RETURN v::text;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Un SELECT escalar como PostgREST, o 'ERR SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest_val(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN COALESCE(v, '(null)');
  EXCEPTION WHEN OTHERS THEN
    RETURN 'ERR ' || SQLSTATE || ' ' || SQLERRM;
  END $f$;
  CREATE FUNCTION pg_temp.es_42501(p_err text) RETURNS boolean LANGUAGE sql AS $f$
    SELECT p_err IS NOT NULL AND p_err LIKE '42501%';
  $f$;

  -- ---------------------------------------------------------------- fixture -
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1135 S', 100, 40, 10, v_suc) RETURNING id INTO v_ps;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1135 O', 100, 40, 10, v_otra) RETURNING id INTO v_po;
  SELECT id INTO v_med FROM cargo_medidas WHERE activo ORDER BY id LIMIT 1;
  SELECT a.encuadre_id, a.id INTO v_encu, v_aliv
    FROM ii_alicuotas a
   WHERE a.vigente_desde <= v_hoy AND (a.vigente_hasta IS NULL OR a.vigente_hasta >= v_hoy)
     AND NOT EXISTS (SELECT 1 FROM ii_alicuotas b WHERE b.encuadre_id = a.encuadre_id AND b.vigente_desde > v_hoy)
   ORDER BY a.id LIMIT 1;
  SELECT id INTO v_cli FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  INSERT INTO notificaciones (usuario_id, sucursal_id, tipo, titulo)
  VALUES (v_admin, v_suc, 'ensayo', 'ensayo 1135') RETURNING id INTO v_notif;
  INSERT INTO grupos_precio (nombre, sucursal_id) VALUES ('ZZ ensayo 1135', v_suc) RETURNING id INTO v_grupo;
  IF v_med IS NULL OR v_encu IS NULL OR v_cli IS NULL THEN
    RAISE EXCEPTION 'fixture · falta medida (%), encuadre con alícuota vigente (%) o cliente (%)', v_med, v_encu, v_cli;
  END IF;

  -- ============================================================ #1134 =======
  -- A · POST directo con un origen que no es de la ficha
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_err := pg_temp.rest(format(
      'INSERT INTO public.stock_historico (producto_id, stock_anterior, stock_nuevo, origen, usuario_id, sucursal_id) VALUES (%s, 40, 99, %L, %L, %s)',
      v_ps, 'compra', v_admin, v_suc));
    IF NOT pg_temp.es_42501(v_err) THEN
      v_fallas := v_fallas || format('A · un admin insertó por REST una fila de stock_historico con origen compra (error %s)', COALESCE(v_err, '(ninguno)'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A · error inesperado: ' || SQLERRM);
  END;

  -- A2 · la forma exacta de la ficha, pero sin UPDATE de productos detrás
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_err := pg_temp.rest(format(
      'INSERT INTO public.stock_historico (producto_id, stock_anterior, stock_nuevo, origen, usuario_id, sucursal_id) VALUES (%s, 40, 99, %L, %L, %s)',
      v_ps, 'ajuste_manual', v_admin, v_suc));
    IF NOT pg_temp.es_42501(v_err) THEN
      v_fallas := v_fallas || format('A2 · un admin insertó por REST una fila con forma de ficha a profundidad 0 (error %s)', COALESCE(v_err, '(ninguno)'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A2 · error inesperado: ' || SQLERRM);
  END;

  -- B · la ficha sigue editando stock, y la RPC DEFINER sigue etiquetando
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    SELECT count(*) INTO v_n FROM stock_historico WHERE producto_id = v_ps;
    v_res := pg_temp.rest_n(format('UPDATE public.productos SET stock = stock + 3 WHERE id = %s', v_ps));
    SELECT * INTO r FROM stock_historico WHERE producto_id = v_ps ORDER BY id DESC LIMIT 1;
    SELECT count(*) INTO v_n2 FROM stock_historico WHERE producto_id = v_ps;
    IF v_res IS DISTINCT FROM '1' OR v_n2 <> v_n + 1
       OR r.origen IS DISTINCT FROM 'ajuste_manual' OR r.usuario_id IS DISTINCT FROM v_admin
       OR r.stock_anterior IS DISTINCT FROM 40 OR r.stock_nuevo IS DISTINCT FROM 43
       OR r.referencia_tipo IS NOT NULL OR r.sucursal_id IS DISTINCT FROM v_suc THEN
      v_fallas := v_fallas || format('B · la ficha por REST: %s, filas %s → %s, última %s/%s/%s→%s',
                                     v_res, v_n, v_n2, r.origen, r.usuario_id, r.stock_anterior, r.stock_nuevo);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('B · error inesperado: ' || SQLERRM);
  END;
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_res := pg_temp.rest_val(format('SELECT public.aplicar_control_stock(%L::jsonb, %L)::text',
               jsonb_build_array(jsonb_build_object('producto_id', v_ps, 'stock_real', 35)), 'ensayo 1135'));
    SELECT * INTO r FROM stock_historico WHERE producto_id = v_ps ORDER BY id DESC LIMIT 1;
    IF v_res LIKE 'ERR%' OR r.origen IS DISTINCT FROM 'control_stock' OR r.usuario_id IS DISTINCT FROM v_admin
       OR r.stock_nuevo IS DISTINCT FROM 35 THEN
      v_fallas := v_fallas || format('B · aplicar_control_stock: %s, última fila %s/%s/%s', v_res, r.origen, r.usuario_id, r.stock_nuevo);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('B · aplicar_control_stock, error inesperado: ' || SQLERRM);
  END;

  -- C · el ledger no se reescribe ni se borra por REST
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    SELECT id INTO v_n FROM stock_historico WHERE sucursal_id = v_suc ORDER BY id DESC LIMIT 1;
    v_errs := ARRAY[
      pg_temp.rest(format('UPDATE public.stock_historico SET stock_nuevo = stock_nuevo + 1 WHERE id = %s', v_n)),
      pg_temp.rest(format('DELETE FROM public.stock_historico WHERE id = %s', v_n))];
    IF NOT pg_temp.es_42501(v_errs[1]) OR NOT pg_temp.es_42501(v_errs[2]) THEN
      v_fallas := v_fallas || format('C · UPDATE / DELETE de stock_historico por REST tenían que dar 42501: %s / %s',
                                     COALESCE(v_errs[1], '(ninguno)'), COALESCE(v_errs[2], '(ninguno)'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C · error inesperado: ' || SQLERRM);
  END;

  -- ============================================================ #1135 =======
  -- D · anon no tiene nada
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    PERFORM set_config('request.headers', '{}', true);
    v_errs := ARRAY[
      pg_temp.rest('SELECT count(*) FROM public.pedidos', 'anon'),
      pg_temp.rest('SELECT count(id) FROM public.productos', 'anon'),
      pg_temp.rest('SELECT count(*) FROM public.vista_rendiciones', 'anon'),
      pg_temp.rest(format('INSERT INTO public.stock_historico (producto_id, stock_anterior, stock_nuevo, origen, sucursal_id) VALUES (%s, 1, 2, %L, %s)',
                          v_ps, 'ajuste_manual', v_suc), 'anon'),
      pg_temp.rest('SELECT last_value FROM public.pedidos_id_seq', 'anon')];
    FOR v_n IN 1 .. cardinality(v_errs) LOOP
      IF NOT pg_temp.es_42501(v_errs[v_n]) THEN
        v_fallas := v_fallas || format('D · anon, %s, tenía que dar 42501; error %s',
          (ARRAY['SELECT pedidos', 'SELECT productos(id)', 'SELECT vista_rendiciones',
                 'INSERT stock_historico', 'SELECT pedidos_id_seq'])[v_n], COALESCE(v_errs[v_n], '(ninguno)'));
      END IF;
    END LOOP;
    SELECT array_agg(DISTINCT c.relname::text ORDER BY c.relname::text) INTO v_txt
      FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
       AND (EXISTS (SELECT 1 FROM aclexplode(c.relacl) x WHERE x.grantee = 'anon'::regrole)
            OR EXISTS (SELECT 1 FROM pg_attribute a, aclexplode(a.attacl) x
                        WHERE a.attrelid = c.oid AND a.attacl IS NOT NULL AND x.grantee = 'anon'::regrole));
    IF v_txt IS NOT NULL THEN
      v_fallas := v_fallas || format('D · %s relaciones con privilegios para anon (p. ej. %s)', cardinality(v_txt),
                                     array_to_string(v_txt[1:5], ', '));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D · error inesperado: ' || SQLERRM);
  END;

  -- E · catálogo de authenticated
  BEGIN
    -- Escrituras (tabla o columna) = lista blanca, en las dos direcciones.
    SELECT array_agg(DISTINCT t ORDER BY t) INTO v_txt FROM (
      SELECT c.relname || '.' || x.privilege_type AS t
        FROM pg_class c, aclexplode(c.relacl) x
       WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
         AND x.grantee = 'authenticated'::regrole AND x.privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
      UNION
      SELECT c.relname || '.' || x.privilege_type
        FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attacl IS NOT NULL, aclexplode(a.attacl) x
       WHERE c.relnamespace = 'public'::regnamespace
         AND x.grantee = 'authenticated'::regrole AND x.privilege_type IN ('INSERT', 'UPDATE', 'DELETE')) s;
    IF v_txt IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(v_lista) x) THEN
      -- De las que sobran sólo la cuenta: antes de la migración son 174.
      v_fallas := v_fallas || format('E · escrituras de authenticated ≠ lista blanca: sobran %s; faltan (front o trigger roto) %s',
        cardinality(ARRAY(SELECT unnest(v_txt) EXCEPT SELECT unnest(v_lista) ORDER BY 1)),
        ARRAY(SELECT unnest(v_lista) EXCEPT SELECT unnest(v_txt) ORDER BY 1));
    END IF;
    -- Extras.
    SELECT count(*) INTO v_n
      FROM pg_class c, aclexplode(c.relacl) x
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND x.grantee = 'authenticated'::regrole
       AND x.privilege_type IN ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN');
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('E · authenticated conserva %s grants de TRUNCATE/REFERENCES/TRIGGER/MAINTAIN', v_n);
    END IF;
    -- El UPDATE de pedidos (el nivel lo decide #1131) y su policy siguen.
    IF NOT has_any_column_privilege('authenticated', 'public.pedidos', 'UPDATE')
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'pedidos'
                                                  AND policyname = 'mt_pedidos_update') THEN
      v_fallas := v_fallas || 'E · se perdió el UPDATE de pedidos o mt_pedidos_update'::text;
    END IF;
    -- Las 4 RPC no salen como DEFINER sin rol.
    SELECT array_agg(firma) INTO v_txt FROM public.auditoria_definer_sin_rol()
     WHERE firma IN ('cambiar_alicuota_ii(bigint,numeric,date)', 'cancelar_alicuota_programada(bigint)',
                     'guardar_producto_medidas(jsonb)',
                     'asegurar_cargo_concepto(text,integer,text,boolean,boolean,text,bigint)');
    IF v_txt IS NOT NULL THEN
      v_fallas := v_fallas || format('E · auditoria_definer_sin_rol() lista %s', v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E · error inesperado: ' || SQLERRM);
  END;

  -- F · caminos REST que saltean una RPC: 42501
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_txt := ARRAY[
      'admin UPDATE pagos.monto',
      'admin DELETE pedido_items',
      'admin DELETE pedidos',
      'admin INSERT mermas_stock',
      'admin UPDATE mermas_stock',
      'admin INSERT audit_logs',
      'admin UPDATE salvedades_items',
      'admin INSERT pedidos_eliminados',
      'admin UPDATE pedido_historial',
      'admin DELETE de la alícuota vigente',
      'admin UPDATE de la tasa de la alícuota vigente',
      'admin UPDATE notificaciones.leida'];
    v_errs := ARRAY[
      pg_temp.rest(format('UPDATE public.pagos SET monto = monto + 1 WHERE id = (SELECT max(id) FROM public.pagos WHERE sucursal_id = %s)', v_suc)),
      pg_temp.rest(format('DELETE FROM public.pedido_items WHERE id = (SELECT max(id) FROM public.pedido_items WHERE sucursal_id = %s)', v_suc)),
      pg_temp.rest(format('DELETE FROM public.pedidos WHERE id = (SELECT max(id) FROM public.pedidos WHERE sucursal_id = %s)', v_suc)),
      pg_temp.rest(format('INSERT INTO public.mermas_stock (producto_id, cantidad, motivo, stock_anterior, stock_nuevo, sucursal_id, usuario_id, costo_unitario) VALUES (%s, 1, %L, 40, 40, %s, %L, 1)',
                          v_ps, 'otro', v_suc, v_admin)),
      pg_temp.rest(format('UPDATE public.mermas_stock SET cantidad = cantidad + 1 WHERE id = (SELECT max(id) FROM public.mermas_stock WHERE sucursal_id = %s)', v_suc)),
      pg_temp.rest(format('INSERT INTO public.audit_logs (tabla, registro_id, accion, usuario_id, sucursal_id) VALUES (%L, %L, %L, %L, %s)',
                          'pedidos', '1', 'UPDATE', v_admin, v_suc)),
      pg_temp.rest(format('UPDATE public.salvedades_items SET cantidad_afectada = cantidad_afectada WHERE id = (SELECT max(id) FROM public.salvedades_items WHERE sucursal_id = %s)', v_suc)),
      pg_temp.rest(format('INSERT INTO public.pedidos_eliminados (pedido_id, eliminado_por_id, sucursal_id) VALUES (-1, %L, %s)', v_admin, v_suc)),
      pg_temp.rest(format('UPDATE public.pedido_historial SET valor_nuevo = %L WHERE id = (SELECT max(id) FROM public.pedido_historial WHERE sucursal_id = %s)', 'ensayo 1135', v_suc)),
      pg_temp.rest(format('DELETE FROM public.ii_alicuotas WHERE id = %s', v_aliv)),
      pg_temp.rest(format('UPDATE public.ii_alicuotas SET tasa_nominal = tasa_nominal + 1 WHERE id = %s', v_aliv)),
      pg_temp.rest(format('UPDATE public.notificaciones SET leida = true, leida_at = now() WHERE id = %s', v_notif))];
    PERFORM pg_temp.como(v_prev, v_suc);
    v_txt := v_txt || 'preventista INSERT pedidos'::text;
    v_errs := v_errs || pg_temp.rest(format(
      'INSERT INTO public.pedidos (cliente_id, total, estado, usuario_id, sucursal_id) VALUES (%s, 0, %L, %L, %s)',
      v_cli, 'pendiente', v_prev, v_suc));
    PERFORM pg_temp.como(v_enc, v_suc);
    v_txt := v_txt || ARRAY['encargado INSERT producto_medidas (unidades_por 0)', 'encargado INSERT cargo_conceptos'];
    v_errs := v_errs || pg_temp.rest(format(
      'INSERT INTO public.producto_medidas (producto_id, sucursal_id, medida_id, unidades_por) VALUES (%s, %s, %s, 0)',
      v_ps, v_suc, v_med));
    v_errs := v_errs || pg_temp.rest(format(
      'INSERT INTO public.cargo_conceptos (nombre, signo, condicion_iva, en_factura, prorratea_al_costo, base_prorrateo) VALUES (%L, 1, %L, true, true, %L)',
      'ZZ ensayo 1135 F', 'no_gravado', 'monto'));
    FOR v_n IN 1 .. cardinality(v_errs) LOOP
      IF NOT pg_temp.es_42501(v_errs[v_n]) THEN
        v_fallas := v_fallas || format('F · %s por REST tenía que dar 42501; error %s', v_txt[v_n], COALESCE(v_errs[v_n], '(ninguno)'));
      END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM ii_alicuotas WHERE id = v_aliv)
       OR EXISTS (SELECT 1 FROM notificaciones WHERE id = v_notif AND leida) THEN
      v_fallas := v_fallas || 'F · la alícuota vigente o la notificación cambiaron por REST'::text;
    END IF;
    -- Dos vallas que antes eran una policy o un trigger y ahora son el grant
    -- (los ensayos de esas reglas, test-permisos-menores-1074.sql 4.3 y
    -- test-anular-salvedad-lote-bolsa.sql G, prueban el resultado y el trigger;
    -- éste prueba el corte): el 42501 tiene que ser el del grant, no otro.
    INSERT INTO proveedores (nombre, sucursal_id) VALUES ('ZZ ensayo 1135 F', v_suc) RETURNING id INTO v_n;
    v_txt := ARRAY['admin DELETE proveedores', 'encargado DELETE proveedores',
                   'admin UPDATE salvedades_items.lotes_devueltos'];
    PERFORM pg_temp.como(v_admin, v_suc);
    v_errs := ARRAY[pg_temp.rest(format('DELETE FROM public.proveedores WHERE id = %s', v_n))];
    PERFORM pg_temp.como(v_enc, v_suc);
    v_errs := v_errs || pg_temp.rest(format('DELETE FROM public.proveedores WHERE id = %s', v_n));
    PERFORM pg_temp.como(v_admin, v_suc);
    v_errs := v_errs || pg_temp.rest(format(
      'UPDATE public.salvedades_items SET lotes_devueltos = COALESCE(lotes_devueltos, %L::jsonb) WHERE id = (SELECT max(id) FROM public.salvedades_items WHERE sucursal_id = %s)',
      '[]', v_suc));
    FOR v_i IN 1 .. 3 LOOP
      -- (Sin CASE adentro del IF: el THEN del CASE le corta la condición.)
      v_t := (ARRAY['proveedores', 'proveedores', 'salvedades_items'])[v_i];
      IF COALESCE(v_errs[v_i], '') NOT LIKE '42501 permission denied for table ' || v_t || '%' THEN
        v_fallas := v_fallas || format('F · %s tenía que cortar por grant (42501 permission denied); error %s',
                                       v_txt[v_i], COALESCE(v_errs[v_i], '(ninguno)'));
      END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id = v_n) THEN
      v_fallas := v_fallas || 'F · el proveedor se borró por REST'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('F · error inesperado: ' || SQLERRM);
  END;

  -- G · lo que el front escribe por REST sigue andando
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_errs := ARRAY[
      pg_temp.rest_n(format('INSERT INTO public.marcas (nombre, sucursal_id) VALUES (%L, %s)', 'ZZ ensayo 1135', v_suc)),
      pg_temp.rest_n(format('UPDATE public.marcas SET nombre = %L WHERE nombre = %L AND sucursal_id = %s', 'ZZ ensayo 1135 b', 'ZZ ensayo 1135', v_suc)),
      pg_temp.rest_n(format('DELETE FROM public.marcas WHERE nombre = %L AND sucursal_id = %s', 'ZZ ensayo 1135 b', v_suc)),
      pg_temp.rest_n(format('INSERT INTO public.grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (%s, %s, %s) ON CONFLICT (grupo_precio_id, producto_id) DO UPDATE SET sucursal_id = EXCLUDED.sucursal_id',
                            v_grupo, v_ps, v_suc)),
      pg_temp.rest_n(format('INSERT INTO public.grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (%s, %s, %s) ON CONFLICT (grupo_precio_id, producto_id) DO UPDATE SET sucursal_id = EXCLUDED.sucursal_id',
                            v_grupo, v_ps, v_suc)),
      pg_temp.rest_n(format('UPDATE public.clientes SET notas = notas WHERE id = %s', v_cli))];
    v_txt := ARRAY['INSERT marca', 'UPDATE marca', 'DELETE marca', 'upsert grupo_precio_productos (alta)',
                   'upsert grupo_precio_productos (conflicto)', 'UPDATE clientes'];
    FOR v_n IN 1 .. cardinality(v_errs) LOOP
      IF v_errs[v_n] IS DISTINCT FROM '1' THEN
        v_fallas := v_fallas || format('G · admin %s por REST: %s', v_txt[v_n], v_errs[v_n]);
      END IF;
    END LOOP;
    -- Un pago y su anulación.
    v_res := pg_temp.rest_val(format(
      'WITH i AS (INSERT INTO public.pagos (cliente_id, monto, forma_pago, usuario_id, sucursal_id, notas) VALUES (%s, 1, %L, %L, %s, %L) RETURNING id) SELECT id::text FROM i',
      v_cli, 'efectivo', v_admin, v_suc, 'ensayo 1135'));
    IF v_res LIKE 'ERR%' THEN
      v_fallas := v_fallas || format('G · admin INSERT pagos por REST: %s', v_res);
    ELSE
      v_err := pg_temp.rest_n(format('DELETE FROM public.pagos WHERE id = %s', v_res));
      IF v_err IS DISTINCT FROM '1' THEN
        v_fallas := v_fallas || format('G · admin DELETE pagos por REST: %s', v_err);
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('G · error inesperado: ' || SQLERRM);
  END;
  -- G · el preventista: notas de su pedido (trigger INVOKER a pedido_historial,
  --     saldo del cliente) y su perfil.
  BEGIN
    -- De cualquier sucursal: el preventista de v_suc puede tener además el rol
    -- de transportista, y entonces pedidos_proteger_columnas sólo le deja
    -- confirmar la entrega.
    SELECT pe.id, pe.usuario_id, pe.cliente_id, pe.sucursal_id INTO r
      FROM pedidos pe
      JOIN perfiles pf ON pf.id = pe.usuario_id AND pf.activo AND pf.rol = 'preventista'
      JOIN usuario_sucursales us ON us.usuario_id = pe.usuario_id AND us.sucursal_id = pe.sucursal_id
     WHERE NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pe.usuario_id AND pr.rol = 'transportista')
       AND pe.transportista_id IS DISTINCT FROM pe.usuario_id
     ORDER BY pe.id DESC LIMIT 1;
    IF r.id IS NULL THEN
      v_fallas := v_fallas || 'G · no hay pedido de un preventista (sin rol de transportista) para el PATCH de notas'::text;
    ELSE
      PERFORM pg_temp.como(r.usuario_id, r.sucursal_id);
      SELECT count(*) INTO v_n FROM pedido_historial WHERE pedido_id = r.id;
      SELECT saldo_cuenta INTO v_res FROM clientes WHERE id = r.cliente_id;
      v_err := pg_temp.rest_n(format('UPDATE public.pedidos SET notas = COALESCE(notas, %L) || %L WHERE id = %s', '', ' [ensayo 1135]', r.id));
      SELECT count(*) INTO v_n2 FROM pedido_historial WHERE pedido_id = r.id;
      IF v_err IS DISTINCT FROM '1' OR v_n2 <> v_n + 1
         OR (SELECT saldo_cuenta::text FROM clientes WHERE id = r.cliente_id) IS DISTINCT FROM v_res THEN
        v_fallas := v_fallas || format('G · el preventista dueño, PATCH de notas: %s, historial %s → %s, saldo %s → %s',
          v_err, v_n, v_n2, v_res, (SELECT saldo_cuenta FROM clientes WHERE id = r.cliente_id));
      END IF;
      v_err := pg_temp.rest_n('UPDATE public.perfiles SET nombre = nombre WHERE id = auth.uid()');
      IF v_err IS DISTINCT FROM '1' THEN
        v_fallas := v_fallas || format('G · el preventista no actualiza su perfil por REST: %s', v_err);
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('G · preventista, error inesperado: ' || SQLERRM);
  END;

  -- H · una tabla nueva de postgres nace cerrada
  BEGIN
    CREATE TABLE public.__ensayo_grants_1135 (id bigserial PRIMARY KEY);
    v_txt := '{}';
    FOREACH v_t IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'] LOOP
      IF has_table_privilege('anon', 'public.__ensayo_grants_1135', v_t) THEN
        v_txt := v_txt || ('anon ' || v_t);
      END IF;
      IF v_t <> 'SELECT' AND has_table_privilege('authenticated', 'public.__ensayo_grants_1135', v_t) THEN
        v_txt := v_txt || ('authenticated ' || v_t);
      END IF;
    END LOOP;
    IF NOT has_table_privilege('authenticated', 'public.__ensayo_grants_1135', 'SELECT') THEN
      v_txt := v_txt || 'authenticated sin SELECT'::text;
    END IF;
    FOREACH v_t IN ARRAY ARRAY['SELECT', 'UPDATE', 'USAGE'] LOOP
      IF has_sequence_privilege('anon', 'public.__ensayo_grants_1135_id_seq', v_t) THEN
        v_txt := v_txt || ('anon secuencia ' || v_t);
      END IF;
    END LOOP;
    IF cardinality(v_txt) > 0 THEN
      v_fallas := v_fallas || format('H · una tabla nueva nace con: %s', array_to_string(v_txt, ', '));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('H · error inesperado: ' || SQLERRM);
  END;

  -- I · las 4 RPC que pasan a DEFINER siguen haciendo lo suyo, y sólo eso
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_res := pg_temp.rest_val(format('SELECT public.cambiar_alicuota_ii(%s, 0.075, %L::date)::text', v_encu, v_hoy + 400));
    IF v_res LIKE 'ERR%' THEN
      v_fallas := v_fallas || format('I · admin cambiar_alicuota_ii programada: %s', v_res);
    ELSIF NOT EXISTS (SELECT 1 FROM ii_alicuotas WHERE id = v_res::bigint AND vigente_desde = v_hoy + 400) THEN
      v_fallas := v_fallas || format('I · admin cambiar_alicuota_ii devolvió %s y no está la alícuota', v_res);
    ELSE
      v_err := pg_temp.rest_val(format('SELECT public.cancelar_alicuota_programada(%s)::text', v_res));
      IF v_err LIKE 'ERR%' OR EXISTS (SELECT 1 FROM ii_alicuotas WHERE id = v_res::bigint)
         OR NOT EXISTS (SELECT 1 FROM ii_alicuotas WHERE id = v_aliv AND vigente_hasta IS NULL) THEN
        v_fallas := v_fallas || format('I · admin cancelar_alicuota_programada: %s', v_err);
      END IF;
    END IF;
    v_err := pg_temp.rest_val(format('SELECT public.cancelar_alicuota_programada(%s)::text', v_aliv));
    IF v_err NOT LIKE 'ERR 22023%' THEN
      v_fallas := v_fallas || format('I · cancelar la alícuota vigente tenía que dar 22023: %s', v_err);
    END IF;
    PERFORM pg_temp.como(v_prev, v_suc);
    v_err := pg_temp.rest_val(format('SELECT public.cambiar_alicuota_ii(%s, 0.09, %L::date)::text', v_encu, v_hoy + 401));
    IF v_err NOT LIKE 'ERR 42501%' THEN
      v_fallas := v_fallas || format('I · preventista cambiar_alicuota_ii tenía que dar 42501: %s', v_err);
    END IF;
    v_err := pg_temp.rest_val(format('SELECT public.asegurar_cargo_concepto(%L, 1, %L, true, true, %L)::text',
                                     'ZZ ensayo 1135 prev', 'no_gravado', 'monto'));
    IF v_err NOT LIKE 'ERR 42501%' THEN
      v_fallas := v_fallas || format('I · preventista asegurar_cargo_concepto tenía que dar 42501: %s', v_err);
    END IF;
    PERFORM pg_temp.como(v_enc, v_suc);
    v_res := pg_temp.rest_val(format('SELECT public.guardar_producto_medidas(%L::jsonb)::text',
               jsonb_build_array(jsonb_build_object('producto_id', v_ps, 'medida_id', v_med, 'unidades_por', 12))));
    IF v_res LIKE 'ERR%' OR NOT EXISTS (SELECT 1 FROM producto_medidas
                                         WHERE producto_id = v_ps AND sucursal_id = v_suc AND medida_id = v_med AND unidades_por = 12) THEN
      v_fallas := v_fallas || format('I · encargado guardar_producto_medidas propio: %s', v_res);
    END IF;
    v_err := pg_temp.rest_val(format('SELECT public.guardar_producto_medidas(%L::jsonb)::text',
               jsonb_build_array(jsonb_build_object('producto_id', v_po, 'medida_id', v_med, 'unidades_por', 6))));
    IF v_err NOT LIKE 'ERR 23503%' OR EXISTS (SELECT 1 FROM producto_medidas WHERE producto_id = v_po) THEN
      v_fallas := v_fallas || format('I · encargado guardar_producto_medidas de otra sucursal tenía que dar 23503: %s', v_err);
    END IF;
    v_res := pg_temp.rest_val(format('SELECT public.asegurar_cargo_concepto(%L, 1, %L, true, true, %L)::text',
                                     'ZZ ensayo 1135 enc', 'no_gravado', 'monto'));
    IF v_res LIKE 'ERR%' OR v_res = '(null)' THEN
      v_fallas := v_fallas || format('I · encargado asegurar_cargo_concepto: %s', v_res);
    ELSIF NOT EXISTS (SELECT 1 FROM cargo_conceptos WHERE id = v_res::bigint) THEN
      v_fallas := v_fallas || format('I · asegurar_cargo_concepto devolvió %s y no está el concepto', v_res);
    END IF;
    PERFORM pg_temp.como(v_enc, v_otra);
    v_err := pg_temp.rest_val(format('SELECT public.guardar_producto_medidas(%L::jsonb)::text',
               jsonb_build_array(jsonb_build_object('producto_id', v_po, 'medida_id', v_med, 'unidades_por', 6))));
    IF v_err NOT LIKE 'ERR 22023%' OR EXISTS (SELECT 1 FROM producto_medidas WHERE producto_id = v_po) THEN
      v_fallas := v_fallas || format('I · encargado con x-sucursal-id ajeno tenía que dar 22023: %s', v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('I · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = 'ENSAYO OK (todo revertido)';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió: el DO termina en error y la
  -- transacción entera se revierte también si alguien lo corre suelto.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  RAISE EXCEPTION '%', v_t;
 END;
END
$ensayo$;
