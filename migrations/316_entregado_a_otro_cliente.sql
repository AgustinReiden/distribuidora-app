-- Salvedad "entregado a otro cliente": devuelve stock, no es merma (#1015)
--
-- EL CASO
--
--   Las salvedades 378 y 380 (07/10) dicen "entregaron mal a otro cliente y se
--   quedaron sin". Se cargaron como 'faltante_stock' y desde la 297 cuentan como
--   merma 'error_inventario'. Pero la mercaderia existe: la tiene otro cliente.
--   Si despues se recupera o se le cobra al otro, queda un doble asiento.
--
-- DECISIONES DEL DUEÑO (08/10)
--
--   · Es un motivo de salvedad propio: 'entregado_otro_cliente'.
--   · La salvedad DEVUELVE las unidades al stock, igual que 'cliente_rechaza', y
--     NO genera merma. Si la mercaderia se recupera, ya esta en el contador. Si
--     se le cobra al otro cliente, se agrega a su pedido y sale de nuevo, ahora
--     como venta.
--   · La 378 y la 380 quedan como estan.
--
-- QUE CAMBIA
--
--   · `salvedades_items_motivo_check` suma el valor.
--   · `registrar_salvedad` lo suma a la lista que prende `v_stock_devuelto`. La
--     devolucion sale con 'salvedad', que esta en la lista blanca de
--     trg_lotes_sincronizar: es una devolucion que QUEDA devuelta, asi que vuelve
--     a su lote por FEFO (CLAUDE.md). No entra al bloque devolver+mermar.
--   · `anular_salvedad` no cambia: ya revierte toda salvedad con
--     `stock_devuelto` ('salvedad_anulada'), y el guard de merma no lo mira.
--   · Ningun reporte ni check de `auditoria_integridad()` enumera los motivos de
--     salvedad (relevado en prod).
--
-- Firma, SECURITY DEFINER y GRANTs de registrar_salvedad: como estaban (el
-- cuerpo se parchea en vivo; el reemplazo tiene que aparecer exactamente una vez).

ALTER TABLE public.salvedades_items
  DROP CONSTRAINT salvedades_items_motivo_check;
ALTER TABLE public.salvedades_items
  ADD CONSTRAINT salvedades_items_motivo_check
  CHECK (motivo::text = ANY (ARRAY[
    'faltante_stock', 'producto_danado', 'cliente_rechaza', 'error_pedido',
    'producto_vencido', 'diferencia_precio', 'otro',
    'entregado_otro_cliente'
  ]::text[]));

DO $registrar$
DECLARE
  v_fn    constant text := 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)';
  v_def   text := pg_get_functiondef(v_fn::regprocedure);
  v_viejo constant text := $q$IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN$q$;
  v_nuevo constant text := $q$-- #1015: lo entregado a otro cliente existe; vuelve al stock (y a su lote).
  IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio', 'entregado_otro_cliente') THEN$q$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo) <> 1 THEN
    RAISE EXCEPTION 'registrar_salvedad no tiene exactamente una lista de motivos que devuelven stock: revisar a mano';
  END IF;
  EXECUTE replace(v_def, v_viejo, v_nuevo);
END
$registrar$;

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  IF v_def NOT LIKE '%''diferencia_precio'', ''entregado_otro_cliente'') THEN%'
     -- no entra al bloque devolver+mermar
     OR v_def NOT LIKE '%IN (''producto_danado'', ''producto_vencido'', ''faltante_stock'') AND v_mueve_stock%'
     OR v_def NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo como se esperaba';
  END IF;
  IF pg_get_constraintdef((SELECT oid FROM pg_constraint
                            WHERE conrelid = 'public.salvedades_items'::regclass
                              AND conname = 'salvedades_items_motivo_check'))
     NOT LIKE '%entregado_otro_cliente%' THEN
    RAISE EXCEPTION 'salvedades_items_motivo_check no tiene el motivo nuevo';
  END IF;
  -- 'salvedad' sigue en la lista blanca: la devolucion vuelve a su lote.
  IF pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure) NOT LIKE '%''salvedad''%' THEN
    RAISE EXCEPTION 'salvedad salio de la lista blanca de sincronizar_lotes_stock';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- Ensayo #1015 con datos reales (se deshace solo: termina en una excepcion
-- atrapada).
--
--   Stock 90 = lote 50 vivas + bolsa 40. Pedido de 60: la bolsa cubre 40 y el
--   lote 20 (stock 30, lote 30, bolsa 0). Salvedad 'entregado_otro_cliente'
--   de 10: el stock vuelve a 40 y las 10 vuelven al LOTE (lote 40, bolsa 0),
--   sin merma, con el ledger +10 'salvedad'. Despues se anula: el stock y el
--   lote quedan exactamente como despues del alta, y sigue sin haber merma.
--
--   Medido contra el cuerpo vigente antes de esta migracion: el CHECK rechaza el
--   motivo y registrar_salvedad devuelve success=false.
-- ---------------------------------------------------------------------------
DO $ensayo1015$
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
    RAISE EXCEPTION 'ens1015 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1015 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1015', 100, 90, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
    VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);

    v_res := public.crear_pedido_completo(
      v_cliente, 6000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 60, 'precio_unitario', 100)),
      'ensayo 1015');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens1015 · no se pudo crear el pedido: %', v_res;
    END IF;
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;

    SELECT jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r)
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = v_prod;
    IF v_foto <> '{"stock":30,"lote":30,"bolsa":0}'::jsonb THEN
      RAISE EXCEPTION 'ens1015 · el alta no dejo el punto de partida esperado: %', v_foto;
    END IF;

    v_res := public.registrar_salvedad(v_ped, v_item, 10, 'entregado_otro_cliente', NULL, NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR NOT COALESCE((v_res->>'stock_devuelto')::boolean, false)
       OR COALESCE((v_res->>'merma_registrada')::boolean, true) THEN
      RAISE EXCEPTION 'ens1015 · registrar: %', v_res;
    END IF;
    v_salv := (v_res->>'salvedad_id')::bigint;

    -- Vuelve al stock y a su lote; la bolsa no se mueve.
    SELECT jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r)
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = v_prod;
    IF v_foto <> '{"stock":40,"lote":40,"bolsa":0}'::jsonb THEN
      RAISE EXCEPTION 'ens1015 · la salvedad no devolvio al stock y al lote: %', v_foto;
    END IF;

    -- Sin merma, y el ledger dice 'salvedad'.
    IF EXISTS (SELECT 1 FROM mermas_stock WHERE producto_id = v_prod) THEN
      RAISE EXCEPTION 'ens1015 · la salvedad genero una merma';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('origen', sh.origen, 'dif', sh.diferencia) ORDER BY sh.id)
      INTO v_foto
      FROM stock_historico sh
     WHERE sh.producto_id = v_prod AND sh.origen NOT IN ('pedido_creado');
    IF v_foto IS DISTINCT FROM '[{"origen":"salvedad","dif":10}]'::jsonb THEN
      RAISE EXCEPTION 'ens1015 · el ledger no es +10 salvedad: %', v_foto;
    END IF;

    -- Anular: el stock y el lote vuelven a como estaban despues del alta.
    v_res := public.anular_salvedad(v_salv, 'ensayo 1015');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens1015 · anular: %', v_res;
    END IF;
    SELECT jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r)
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = v_prod;
    IF v_foto <> '{"stock":30,"lote":30,"bolsa":0}'::jsonb
       OR (SELECT cantidad FROM pedido_items WHERE id = v_item) <> 60
       OR EXISTS (SELECT 1 FROM mermas_stock WHERE producto_id = v_prod) THEN
      RAISE EXCEPTION 'ens1015 · anular no dejo todo como despues del alta: %', v_foto;
    END IF;

    RAISE EXCEPTION 'ens1015-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'ens1015-ok' THEN RAISE; END IF;
  END;
END
$ensayo1015$;
