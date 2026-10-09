-- La salvedad "Otro" devuelve el stock y exige descripcion (#1022)
--
-- EL PROBLEMA
--
--   `registrar_salvedad` decide si devuelve el stock por el motivo, y "otro" no
--   estaba en la lista. Pero el modal de salvedad de un item le decia al chofer
--   "El stock se devolvera al inventario" (y el de entrega con salvedad, que
--   no). Habia 18 salvedades "otro" (56 u.) del 04/05 al 06/10, ninguna
--   devuelta. Casi todas dicen "no se cargo en el camion" o "error en carga":
--   mercaderia que nunca salio del deposito.
--
-- DECISIONES DEL DUEÑO (08/10)
--
--   · "Otro" devuelve el stock, como 'cliente_rechaza'. Sale con 'salvedad', que
--     esta en la lista blanca de trg_lotes_sincronizar: es una devolucion que
--     QUEDA devuelta, asi que vuelve a su lote por FEFO (CLAUDE.md).
--   · "Otro" exige una descripcion. Los dos modales ya la pedian (minimo 10
--     caracteres); ahora tambien el servidor, con la misma regla.
--   · El servidor es el unico que decide si se devuelve stock; `p_devolver_stock`
--     sigue ignorado (comentario en el cuerpo) y la UI lee el espejo
--     MOTIVOS_SALVEDAD_DEVUELVEN_STOCK, uno solo para los dos modales.
--   · Las 18 que ya estan quedan como estan (sin devolver). `anular_salvedad`
--     mira `stock_devuelto` de cada fila, asi que anular una vieja no resta
--     nada y anular una nueva revierte lo que devolvio.
--
-- Firma, SECURITY DEFINER y GRANTs de registrar_salvedad: como estaban (el
-- cuerpo se parchea en vivo; cada reemplazo tiene que aparecer exactamente una vez).

DO $registrar$
DECLARE
  v_fn  constant text := 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)';
  v_def text := pg_get_functiondef(v_fn::regprocedure);
  v_par text[][] := ARRAY[
    ARRAY[$q$IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio', 'entregado_otro_cliente') THEN$q$,
          $q$-- #1022: "otro" tambien (casi siempre es "no se cargo en el camion").
  -- Esta lista es la UNICA que decide si la salvedad devuelve stock.
  -- `p_devolver_stock` se ignora a proposito: si decidiera la app, un bundle
  -- viejo o con un error podria devolver stock de algo roto. Sigue en la firma
  -- porque sacarlo rompe los bundles viejos del PWA y la cola offline (la
  -- llamada con ese parametro daria PGRST202). El espejo para la UI es
  -- MOTIVOS_SALVEDAD_DEVUELVEN_STOCK (src/lib/schemas.ts).
  IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio', 'entregado_otro_cliente', 'otro') THEN$q$],
    ARRAY[$q$    RETURN jsonb_build_object('success', false, 'error', 'Cantidad debe ser mayor a 0');
  END IF;$q$,
          $q$    RETURN jsonb_build_object('success', false, 'error', 'Cantidad debe ser mayor a 0');
  END IF;

  -- #1022: "Otro" no dice nada por si solo; la descripcion es lo que explica
  -- que paso. La misma regla que los dos modales (minimo 10 caracteres).
  IF p_motivo = 'otro' AND length(btrim(COALESCE(p_descripcion, ''))) < 10 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Para el motivo "Otro" hay que describir que paso (minimo 10 caracteres)',
      'codigo', 'otro_sin_descripcion'
    );
  END IF;$q$]
  ];
  v_i int;
BEGIN
  FOR v_i IN 1..array_length(v_par, 1) LOOP
    IF (length(v_def) - length(replace(v_def, v_par[v_i][1], ''))) / length(v_par[v_i][1]) <> 1 THEN
      RAISE EXCEPTION 'registrar_salvedad: el fragmento % no aparece exactamente una vez: revisar a mano', v_i;
    END IF;
    v_def := replace(v_def, v_par[v_i][1], v_par[v_i][2]);
  END LOOP;
  EXECUTE v_def;
END
$registrar$;

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  IF v_def NOT LIKE '%''entregado_otro_cliente'', ''otro'') THEN%'
     OR v_def NOT LIKE '%''codigo'', ''otro_sin_descripcion''%'
     -- no entra al bloque devolver+mermar
     OR v_def NOT LIKE '%IN (''producto_danado'', ''producto_vencido'', ''faltante_stock'') AND v_mueve_stock%'
     OR v_def NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo como se esperaba';
  END IF;
  IF pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure) NOT LIKE '%''salvedad''%' THEN
    RAISE EXCEPTION 'salvedad salio de la lista blanca de sincronizar_lotes_stock';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- Ensayo #1022 con datos reales (se deshace solo: termina en una excepcion
-- atrapada).
--
--   Stock 90 = lote 50 vivas + bolsa 40. Pedido de 60: la bolsa cubre 40 y el
--   lote 20 (stock 30, lote 30, bolsa 0).
--   (1) "Otro" sin descripcion: se niega ('otro_sin_descripcion') y no mueve
--       nada (ni la linea ni el stock).
--   (2) "Otro" con descripcion, 10 u.: el stock vuelve a 40 y las 10 vuelven al
--       LOTE (lote 40, bolsa 0), sin merma, con el ledger +10 'salvedad'.
--   (3) Anular: el stock, el lote y la linea quedan como despues del alta.
--
--   Medido contra el cuerpo vigente antes de esta migracion: (1) se aceptaba y
--   (2) dejaba el stock en 30 (stock_devuelto false).
-- ---------------------------------------------------------------------------
DO $ensayo1022$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_prod    bigint;
  v_res     jsonb;
  v_ped     bigint;
  v_item    bigint;
  v_salv    bigint;
  v_foto    jsonb;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens1022 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1022 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1022', 100, 90, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
    VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);

    v_res := public.crear_pedido_completo(
      v_cliente, 6000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 60, 'precio_unitario', 100)),
      'ensayo 1022');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens1022 · no se pudo crear el pedido: %', v_res;
    END IF;
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;

    -- (1) Sin descripcion: se niega y no toca nada.
    v_res := public.registrar_salvedad(v_ped, v_item, 10, 'otro', '  corto  ', NULL, true, NULL);
    IF COALESCE((v_res->>'success')::boolean, true)
       OR v_res->>'codigo' IS DISTINCT FROM 'otro_sin_descripcion' THEN
      RAISE EXCEPTION 'ens1022 · "otro" sin descripcion no se nego: %', v_res;
    END IF;
    SELECT jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r,
                              'linea', (SELECT cantidad FROM pedido_items WHERE id = v_item))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = v_prod;
    IF v_foto <> '{"stock":30,"lote":30,"bolsa":0,"linea":60}'::jsonb THEN
      RAISE EXCEPTION 'ens1022 · el rechazo movio algo: %', v_foto;
    END IF;

    -- (2) Con descripcion: devuelve al stock y al lote, sin merma.
    v_res := public.registrar_salvedad(v_ped, v_item, 10, 'otro', 'No se cargo en el camion', NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR NOT COALESCE((v_res->>'stock_devuelto')::boolean, false)
       OR COALESCE((v_res->>'merma_registrada')::boolean, true) THEN
      RAISE EXCEPTION 'ens1022 · registrar "otro": %', v_res;
    END IF;
    v_salv := (v_res->>'salvedad_id')::bigint;

    SELECT jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r)
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = v_prod;
    IF v_foto <> '{"stock":40,"lote":40,"bolsa":0}'::jsonb THEN
      RAISE EXCEPTION 'ens1022 · "otro" no devolvio al stock y al lote: %', v_foto;
    END IF;
    IF EXISTS (SELECT 1 FROM mermas_stock WHERE producto_id = v_prod) THEN
      RAISE EXCEPTION 'ens1022 · "otro" genero una merma';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('origen', sh.origen, 'dif', sh.diferencia) ORDER BY sh.id)
      INTO v_foto
      FROM stock_historico sh
     WHERE sh.producto_id = v_prod AND sh.origen NOT IN ('pedido_creado');
    IF v_foto IS DISTINCT FROM '[{"origen":"salvedad","dif":10}]'::jsonb THEN
      RAISE EXCEPTION 'ens1022 · el ledger no es +10 salvedad: %', v_foto;
    END IF;

    -- (3) Anular: todo como despues del alta.
    v_res := public.anular_salvedad(v_salv, 'ensayo 1022');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens1022 · anular: %', v_res;
    END IF;
    SELECT jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r,
                              'linea', (SELECT cantidad FROM pedido_items WHERE id = v_item))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = v_prod;
    IF v_foto <> '{"stock":30,"lote":30,"bolsa":0,"linea":60}'::jsonb
       OR EXISTS (SELECT 1 FROM mermas_stock WHERE producto_id = v_prod) THEN
      RAISE EXCEPTION 'ens1022 · anular no dejo todo como despues del alta: %', v_foto;
    END IF;

    RAISE EXCEPTION 'ens1022-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'ens1022-ok' THEN RAISE; END IF;
  END;
END
$ensayo1022$;
