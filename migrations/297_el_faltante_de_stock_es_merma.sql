-- El faltante de stock es merma, y en_preparacion es un estado (#847, #848)
--
-- #848 · VENTA-C OSCILABA PORQUE CONTABA UN ESTADO VIVO COMO ERROR
--
--   `auditoria_integridad()` VENTA-C contaba los pedidos con estado fuera de
--   ('entregado','asignado','pendiente','cancelado','anulado'). `en_preparacion`
--   no estaba, y es un estado vivo: el boton "Preparar" de la app
--   (PedidosContainer -> cambiarEstado) pasa pendiente -> en_preparacion, y
--   "Armar ruta" (aplicar_orden_ruta) lo pasa a asignado o lo devuelve a
--   en_preparacion. 730 transiciones en pedido_historial, 75 sólo el 29-30/09.
--   El check subia mientras el deposito preparaba y volvia a 0 cuando se
--   armaban las rutas: 31, 0, 42 en pocas horas, sin un solo dato roto.
--
--   El CHECK de la tabla (`pedidos_estado_check`) ya permitia en_preparacion,
--   y ademas 'listo' y 'en_camino', que nadie escribe: 0 filas, 0 transiciones
--   en el historial, ninguna funcion de public. Decision del dueño (07/10):
--   los dos quedan con el MISMO dominio de seis, y 'listo'/'en_camino' dejan de
--   ser escribibles. El VENTA-C queda como alarma de que alguien amplio el
--   CHECK sin pasar por aca.
--
-- #847 · LA SALVEDAD POR FALTANTE PARCIAL NO DEJABA ASIENTO
--
--   Con #827 (mig 269) cancelar un pedido por falta de stock devuelve y merma
--   las unidades en el mismo movimiento. El faltante PARCIAL va por salvedad
--   `faltante_stock`, y `registrar_salvedad` no le devolvia ni le mermaba
--   nada: el contador quedaba bien --las unidades salieron al cargar el pedido
--   y no existian-- pero no eran venta ni merma. Desaparecian sin asiento y
--   `mermas_valorizadas` no las veia.
--
--   Ahora el faltante entra al mismo bloque que dañado/vencido (mig 234):
--   +N con origen 'salvedad_merma' --FUERA de la lista blanca de
--   trg_lotes_sincronizar, el corolario de CLAUDE.md: la devolucion que se
--   cancela sola no va etiquetada-- y -N como merma 'error_inventario', la
--   misma que usa la 269 y que `merma_clasificacion` ya clasifica 'ajuste'.
--   Neto cero sobre productos.stock, sobre el lote y sobre la bolsa (el ensayo
--   lo mide con un lote de 50 vivas y bolsa 40).
--
--   `anular_salvedad` ya anulaba la merma de dañado/vencido (mig 244). Ahora
--   tambien la del faltante, con el mismo guard: si la fila no aparece, se
--   niega antes de restituir nada. No hace falta una excepcion para las
--   salvedades viejas sin merma: el backfill de abajo les crea la suya
--   (decision del dueño, 07/10), y las cinco que deja afuera tienen que
--   quedar trabadas hasta que se revisen. El guard sólo rige cuando la
--   linea movio stock (no es un regalo); un regalo de promo ni siquiera llega
--   aca --anular lo rechaza antes, 'anulacion_toca_promociones'--.
--
--   Backfill: habia 44 salvedades (89 unidades), todas de lineas que movieron
--   stock, ninguna anulada, ninguna con merma. Una merma 'error_inventario' por
--   salvedad, FECHADA el dia de la salvedad: los reportes de mayo a octubre
--   cambian, y eso es lo que se decidio.
--
--   Salvo CINCO (66, 86, 133, 232, 306), decision del dueño del 07/10: cada
--   una tiene una merma 'error_inventario' MANUAL del mismo producto cargada
--   entre 3 dias antes y 7 despues (mermas 140, 194, 464, 687, 1016). Si esa
--   merma ya dio de baja las unidades que faltaron, el backfill las contaria
--   dos veces. Quedan sin merma y anular_salvedad las rechaza
--   ('merma_no_encontrada') hasta que alguien las revise a mano: es lo que
--   pide el guard, no anular a ciegas. Unos $92.400 al costo de hoy, casi todo
--   la 133 (julio, S1). Sin movimiento de stock ni de ledger
--   (las unidades ya salieron hace meses). El costo lo congela
--   trg_mermas_snapshot_costo con la cascada de hoy: sólo 9 de las 44 lineas
--   siguen existiendo, no hay un costo historico confiable. Medido antes,
--   con las 44: $356.503 al costo de hoy (S1 may 8.600 · jun 19.187 ·
--   jul 77.063 · ago 19.523 · sep 61.074 · oct 2.276; S2 jun 4.368 ·
--   sep 135.853 · oct 28.559). Sin las cinco: 39 salvedades.
--
-- Firmas, SECURITY DEFINER y GRANTs: como estaban. Los cuerpos se parchean en
-- vivo --como la 269 con las jornadas--, cada reemplazo tiene que aparecer
-- exactamente una vez, y el $verif$ lo comprueba despues.

-- ---------------------------------------------------------------------------
-- #848 · el dominio de estados, uno solo
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedidos
  DROP CONSTRAINT pedidos_estado_check;
ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_estado_check
  CHECK (estado = ANY (ARRAY['pendiente', 'en_preparacion', 'asignado',
                             'entregado', 'cancelado', 'anulado']));

DO $venta_c$
DECLARE
  v_def   text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_viejo constant text := $q$estado NOT IN ('entregado','asignado','pendiente','cancelado','anulado')$q$;
  v_nuevo constant text := $q$estado NOT IN ('pendiente','en_preparacion','asignado','entregado','cancelado','anulado')$q$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo) <> 1 THEN
    RAISE EXCEPTION 'auditoria_integridad no tiene exactamente un dominio de VENTA-C: revisar a mano';
  END IF;
  EXECUTE replace(v_def, v_viejo, v_nuevo);
END
$venta_c$;

-- ---------------------------------------------------------------------------
-- #847 · registrar_salvedad: el faltante devuelve y merma
-- ---------------------------------------------------------------------------
DO $registrar$
DECLARE
  v_fn  constant text := 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)';
  v_def text := pg_get_functiondef(v_fn::regprocedure);
  v_par text[][] := ARRAY[
    -- el replay idempotente informa lo mismo que la primera llamada
    ARRAY[$q$'merma_registrada', v_existing.motivo IN ('producto_danado', 'producto_vencido'),$q$,
          $q$'merma_registrada', v_existing.motivo IN ('producto_danado', 'producto_vencido', 'faltante_stock'),$q$],
    ARRAY[$q$IF p_motivo IN ('producto_danado', 'producto_vencido') AND v_mueve_stock THEN$q$,
          $q$/* #847: el faltante parcial tambien. Esas unidades salieron al cargar
     el pedido y no existian: no son venta, asi que son merma
     ('error_inventario', clase 'ajuste', la misma de la cancelacion por
     falta de stock de la 269). Mismo devolver+mermar, mismo origen fuera de
     la lista blanca: neto cero sobre stock, lote y bolsa. */
  IF p_motivo IN ('producto_danado', 'producto_vencido', 'faltante_stock') AND v_mueve_stock THEN$q$],
    ARRAY[$q$CASE p_motivo WHEN 'producto_danado' THEN 'rotura' WHEN 'producto_vencido' THEN 'vencimiento' END$q$,
          $q$CASE p_motivo WHEN 'producto_danado' THEN 'rotura' WHEN 'producto_vencido' THEN 'vencimiento'
                    WHEN 'faltante_stock' THEN 'error_inventario' END$q$]
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
-- #847 · anular_salvedad: la merma del faltante tambien se anula
-- ---------------------------------------------------------------------------
DO $anular$
DECLARE
  v_def   text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_viejo constant text := $q$IF v_salvedad.motivo IN ('producto_danado', 'producto_vencido') THEN$q$;
  v_nuevo constant text := $q$-- #847: el faltante por la misma razon, cuando la linea movio stock (un
  -- regalo de promo no llega aca: lo rechaza el guard de arriba). Las
  -- salvedades por faltante anteriores a #847 tienen su merma por backfill,
  -- salvo cinco que se revisan a mano (ver la migracion de #847).
  IF v_salvedad.motivo IN ('producto_danado', 'producto_vencido')
     OR (v_salvedad.motivo = 'faltante_stock' AND NOT COALESCE(v_salvedad.es_bonificacion, FALSE)) THEN$q$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo) <> 1 THEN
    RAISE EXCEPTION 'anular_salvedad no tiene exactamente un guard de merma: revisar a mano';
  END IF;
  EXECUTE replace(v_def, v_viejo, v_nuevo);
END
$anular$;

-- ---------------------------------------------------------------------------
-- #847 · backfill: una merma por cada faltante viejo, en su fecha
--
--   stock_anterior/stock_nuevo: el stock del producto en ese momento segun el
--   ledger, con el mismo encuadre que el camino vivo (medido contra el stock
--   ya "devuelto": anterior = s + N, nuevo = s), para que MERMA-B y MERMA-H
--   sigan en cero. usuario_id = quien reporto la salvedad (MERMA-I).
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
  v_esperadas int;
  v_insertadas int;
BEGIN
  SELECT count(*) INTO v_esperadas
    FROM salvedades_items s
    LEFT JOIN promociones pr ON pr.id = s.promocion_id
   WHERE s.motivo = 'faltante_stock'
     AND s.estado_resolucion <> 'anulada'
     AND (NOT COALESCE(s.es_bonificacion, FALSE) OR COALESCE(pr.regalo_mueve_stock, FALSE))
     AND s.id NOT IN (66, 86, 133, 232, 306)  -- posible doble conteo, ver cabecera
     AND NOT EXISTS (SELECT 1 FROM mermas_stock m WHERE m.salvedad_id = s.id);

  INSERT INTO mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id, salvedad_id, created_at
  )
  SELECT s.producto_id, s.cantidad_afectada, 'error_inventario',
         COALESCE(s.descripcion, 'Salvedad pedido #' || s.pedido_id || ': faltante_stock')
           || ' (asiento retroactivo, #847)',
         GREATEST(COALESCE(h.stock_nuevo, 0), 0) + s.cantidad_afectada,
         GREATEST(COALESCE(h.stock_nuevo, 0), 0),
         s.reportado_por, s.sucursal_id, s.id, s.created_at
    FROM salvedades_items s
    LEFT JOIN promociones pr ON pr.id = s.promocion_id
    LEFT JOIN LATERAL (
      SELECT sh.stock_nuevo
        FROM stock_historico sh
       WHERE sh.producto_id = s.producto_id
         AND sh.sucursal_id = s.sucursal_id
         AND sh.created_at <= s.created_at
       ORDER BY sh.created_at DESC, sh.id DESC
       LIMIT 1
    ) h ON TRUE
   WHERE s.motivo = 'faltante_stock'
     AND s.estado_resolucion <> 'anulada'
     AND (NOT COALESCE(s.es_bonificacion, FALSE) OR COALESCE(pr.regalo_mueve_stock, FALSE))
     AND s.id NOT IN (66, 86, 133, 232, 306)  -- posible doble conteo, ver cabecera
     AND NOT EXISTS (SELECT 1 FROM mermas_stock m WHERE m.salvedad_id = s.id);
  GET DIAGNOSTICS v_insertadas = ROW_COUNT;

  IF v_insertadas <> v_esperadas THEN
    RAISE EXCEPTION 'backfill #847: se esperaban % mermas y se insertaron %', v_esperadas, v_insertadas;
  END IF;
  RAISE NOTICE 'backfill #847: % mermas error_inventario retroactivas', v_insertadas;
END
$backfill$;

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text;
BEGIN
  -- #848: CHECK y VENTA-C con el mismo dominio, y ningun pedido afuera.
  IF pg_get_constraintdef((SELECT oid FROM pg_constraint
                            WHERE conrelid = 'public.pedidos'::regclass
                              AND conname = 'pedidos_estado_check'))
     NOT LIKE '%''pendiente''%''en_preparacion''%''asignado''%''entregado''%''cancelado''%''anulado''%'
     OR pg_get_constraintdef((SELECT oid FROM pg_constraint
                               WHERE conrelid = 'public.pedidos'::regclass
                                 AND conname = 'pedidos_estado_check')) ~ '(listo|en_camino)' THEN
    RAISE EXCEPTION 'pedidos_estado_check no quedo con el dominio de seis';
  END IF;
  IF pg_get_functiondef('public.auditoria_integridad()'::regprocedure)
     NOT LIKE '%estado NOT IN (''pendiente'',''en_preparacion'',''asignado'',''entregado'',''cancelado'',''anulado'')%' THEN
    RAISE EXCEPTION 'VENTA-C no quedo con el dominio de seis';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
              WHERE c->>'id' = 'VENTA-C' AND (c->>'violaciones')::int <> 0) THEN
    RAISE EXCEPTION 'VENTA-C sigue en rojo despues de alinear el dominio';
  END IF;

  -- #847: los dos cuerpos con su cambio, y sin perder lo que ya hacian.
  v_def := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  IF v_def NOT LIKE '%''producto_danado'', ''producto_vencido'', ''faltante_stock'') AND v_mueve_stock%'
     OR v_def NOT LIKE '%WHEN ''faltante_stock'' THEN ''error_inventario''%'
     OR v_def NOT LIKE '%''app.stock_origen'', ''salvedad_merma''%'
     OR v_def NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo como se esperaba';
  END IF;
  v_def := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  IF v_def NOT LIKE '%v_salvedad.motivo = ''faltante_stock'' AND NOT COALESCE(v_salvedad.es_bonificacion, FALSE)%'
     OR v_def NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'anular_salvedad no quedo como se esperaba';
  END IF;

  -- 'salvedad_merma' sigue FUERA de la lista blanca de los lotes.
  IF pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure) LIKE '%''salvedad_merma''%' THEN
    RAISE EXCEPTION 'salvedad_merma aparecio en la lista blanca de sincronizar_lotes_stock';
  END IF;

  -- Ningun faltante vivo que movio stock queda sin su merma, salvo las cinco
  -- que se dejaron afuera a proposito.
  IF EXISTS (SELECT 1 FROM salvedades_items s
               LEFT JOIN promociones pr ON pr.id = s.promocion_id
              WHERE s.motivo = 'faltante_stock' AND s.estado_resolucion <> 'anulada'
                AND (NOT COALESCE(s.es_bonificacion, FALSE) OR COALESCE(pr.regalo_mueve_stock, FALSE))
                AND s.id NOT IN (66, 86, 133, 232, 306)
                AND NOT EXISTS (SELECT 1 FROM mermas_stock m WHERE m.salvedad_id = s.id)) THEN
    RAISE EXCEPTION 'quedo una salvedad por faltante sin su merma';
  END IF;
  IF (SELECT count(*) FROM mermas_stock
       WHERE salvedad_id IN (66, 86, 133, 232, 306) AND anulada_at IS NULL) <> 0 THEN
    RAISE EXCEPTION 'el backfill le creo merma a una de las cinco excluidas';
  END IF;

  -- Los checks que estas mermas podrian ensuciar, en cero.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
              WHERE c->>'id' IN ('MERMA-A','MERMA-B','MERMA-E','MERMA-H','SALV-A','STK-F','COSTO-D')
                AND (c->>'violaciones')::int <> 0) THEN
    RAISE EXCEPTION 'un check de mermas/stock/costo quedo en rojo';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- Ensayo #848 (se deshace solo). Un pedido sintetico pasa a en_preparacion,
-- como lo hace el boton "Preparar": VENTA-C no lo cuenta. Despues a
-- 'en_camino', que ya no es escribible. Medido contra el cuerpo vigente antes
-- de esta migracion: VENTA-C = 1 y 'en_camino' aceptado.
-- ---------------------------------------------------------------------------
DO $ensayo848$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_prod    bigint;
  v_res     jsonb;
  v_ped     bigint;
  v_venta_c int;
  v_base    int;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  BEGIN
    SELECT (c->>'violaciones')::int INTO v_base
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-C';

    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 848', 100, 10, 60, v_suc) RETURNING id INTO v_prod;
    v_res := public.crear_pedido_completo(
      v_cliente, 100, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 100)),
      'ensayo 848');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens848 · no se pudo crear el pedido: %', v_res;
    END IF;
    v_ped := (v_res->>'pedido_id')::bigint;

    UPDATE pedidos SET estado = 'en_preparacion' WHERE id = v_ped;
    SELECT (c->>'violaciones')::int INTO v_venta_c
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-C';
    IF v_venta_c <> v_base THEN
      RAISE EXCEPTION 'ens848 · VENTA-C cuenta un pedido en_preparacion (% -> %)', v_base, v_venta_c;
    END IF;

    BEGIN
      UPDATE pedidos SET estado = 'en_camino' WHERE id = v_ped;
      RAISE EXCEPTION 'ens848 · el CHECK sigue aceptando en_camino';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    RAISE EXCEPTION 'ens848-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'ens848-ok' THEN RAISE; END IF;
  END;
END
$ensayo848$;

-- ---------------------------------------------------------------------------
-- Ensayo #847 con datos reales (se deshace solo: termina en una excepcion atrapada).
--
--   P1: stock 90 = lote 50 vivas + bolsa 40. Pedido de 10 -> sale de la bolsa
--       (bolsa 30, lote 50). Salvedad por faltante de 3: stock, lote y bolsa
--       tienen que quedar EXACTAMENTE como despues del alta, con una merma
--       'error_inventario' de 3 clasificada 'ajuste' en mermas_valorizadas.
--       Es el caso que muerde: si la devolucion llevara un origen de la lista
--       blanca ('salvedad') volveria al lote por FEFO (lote 53) y la merma
--       saldria de la bolsa (bolsa 27) -- +3/-3 cruzado, el corolario de la 234.
--       Despues se anula: la merma queda anulada, la linea vuelve a 10 y el
--       stock no se mueve.
--   P2: mismo arranque, faltante de 2 cuya merma se borra a mano: anular tiene
--       que negarse ('merma_no_encontrada') sin restituir nada.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_p       bigint[] := ARRAY[]::bigint[];
  v_prod    bigint;
  v_res     jsonb;
  v_ped     bigint;
  v_item1   bigint;
  v_item2   bigint;
  v_salv1   bigint;
  v_salv2   bigint;
  v_merma1  bigint;
  v_log     jsonb := '{}'::jsonb;
  v_foto    jsonb;
  v_i       int;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens847 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens847 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  BEGIN
    FOR v_i IN 1..2 LOOP
      INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
      VALUES ('ZZ ensayo 847 P' || v_i, 100, 90, 60, v_suc) RETURNING id INTO v_prod;
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
      VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);
      v_p := v_p || v_prod;
    END LOOP;

    v_res := public.crear_pedido_completo(
      v_cliente, 2000, v_admin,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_p[1], 'cantidad', 10, 'precio_unitario', 100),
        jsonb_build_object('producto_id', v_p[2], 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo 847');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens847 · no se pudo crear el pedido: %', v_res;
    END IF;
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item1 FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_p[1];
    SELECT id INTO v_item2 FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_p[2];

    SELECT jsonb_object_agg('P' || array_position(v_p, pr.id),
             jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = ANY(v_p);
    v_log := v_log || jsonb_build_object('post_alta', v_foto);
    IF v_foto <> '{"P1":{"stock":80,"lote":50,"bolsa":30},
                  "P2":{"stock":80,"lote":50,"bolsa":30}}'::jsonb THEN
      RAISE EXCEPTION 'ens847 · el alta no dejo el punto de partida esperado: %', v_foto;
    END IF;

    -- (1) Faltante de 3 sobre P1.
    v_res := public.registrar_salvedad(v_ped, v_item1, 3, 'faltante_stock', NULL, NULL, true, NULL);
    v_log := v_log || jsonb_build_object('rpc_salv1', v_res);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR COALESCE((v_res->>'stock_devuelto')::boolean, true)
       OR NOT COALESCE((v_res->>'merma_registrada')::boolean, false) THEN
      RAISE EXCEPTION 'ens847 · registrar faltante P1: %', v_res;
    END IF;
    v_salv1 := (v_res->>'salvedad_id')::bigint;

    -- (2) Faltante de 2 sobre P2.
    v_res := public.registrar_salvedad(v_ped, v_item2, 2, 'faltante_stock', NULL, NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens847 · registrar faltante P2: %', v_res;
    END IF;
    v_salv2 := (v_res->>'salvedad_id')::bigint;

    SELECT jsonb_object_agg('P' || array_position(v_p, pr.id),
             jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = ANY(v_p);
    v_log := v_log || jsonb_build_object('post_salvedad', v_foto);
    -- Neto cero: ni el stock, ni el lote, ni la bolsa se mueven.
    IF v_foto <> '{"P1":{"stock":80,"lote":50,"bolsa":30},
                  "P2":{"stock":80,"lote":50,"bolsa":30}}'::jsonb THEN
      RAISE EXCEPTION 'ens847 · la salvedad por faltante movio stock/lote/bolsa: %', v_foto;
    END IF;

    -- La merma: una fila, error_inventario, medida contra el stock ya devuelto
    -- (MERMA-B), con usuario (MERMA-I) y colgada de su salvedad.
    SELECT jsonb_agg(jsonb_build_object('motivo', m.motivo, 'cantidad', m.cantidad,
             'ant', m.stock_anterior, 'nuevo', m.stock_nuevo,
             'usuario', m.usuario_id IS NOT NULL) ORDER BY m.id)
      INTO v_foto
      FROM mermas_stock m WHERE m.salvedad_id = v_salv1;
    v_log := v_log || jsonb_build_object('merma1', v_foto);
    IF v_foto IS DISTINCT FROM
       '[{"motivo":"error_inventario","cantidad":3,"ant":83,"nuevo":80,"usuario":true}]'::jsonb THEN
      RAISE EXCEPTION 'ens847 · la merma del faltante no quedo como se esperaba: %', v_foto;
    END IF;
    SELECT id INTO v_merma1 FROM mermas_stock WHERE salvedad_id = v_salv1;

    -- mermas_valorizadas la ve como ajuste, con costo.
    SELECT jsonb_agg(jsonb_build_object('clasif', mv.clasificacion, 'costo', mv.costo_total IS NOT NULL))
      INTO v_foto
      FROM public.mermas_valorizadas(v_hoy, v_hoy, ARRAY[v_suc]) mv WHERE mv.id = v_merma1;
    IF v_foto IS DISTINCT FROM '[{"clasif":"ajuste","costo":true}]'::jsonb THEN
      RAISE EXCEPTION 'ens847 · mermas_valorizadas no ve la merma del faltante como ajuste: %', v_foto;
    END IF;

    -- Ledger de P1: +3 fuera de la lista blanca, -3 como merma de esa fila.
    SELECT jsonb_agg(jsonb_build_object('origen', sh.origen, 'dif', sh.diferencia) ORDER BY sh.id)
      INTO v_foto
      FROM stock_historico sh
     WHERE sh.producto_id = v_p[1] AND sh.origen IN ('salvedad_merma', 'merma');
    v_log := v_log || jsonb_build_object('ledger1', v_foto);
    IF v_foto IS DISTINCT FROM '[{"origen":"salvedad_merma","dif":3},{"origen":"merma","dif":-3}]'::jsonb THEN
      RAISE EXCEPTION 'ens847 · el ledger del faltante no es +3 salvedad_merma / -3 merma: %', v_foto;
    END IF;

    -- (3) P2 con la merma perdida: anular se niega antes de restituir nada.
    DELETE FROM mermas_stock WHERE salvedad_id = v_salv2;
    v_res := public.anular_salvedad(v_salv2, 'ensayo 847');
    v_log := v_log || jsonb_build_object('rpc_anular2', v_res);
    IF COALESCE((v_res->>'success')::boolean, true)
       OR v_res->>'codigo' IS DISTINCT FROM 'merma_no_encontrada'
       OR (SELECT cantidad FROM pedido_items WHERE id = v_item2) <> 8 THEN
      RAISE EXCEPTION 'ens847 · anular un faltante sin su merma no se nego: %', v_res;
    END IF;

    -- (4) Anular P1: merma anulada, linea restituida, stock quieto.
    v_res := public.anular_salvedad(v_salv1, 'ensayo 847');
    v_log := v_log || jsonb_build_object('rpc_anular1', v_res);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens847 · anular faltante P1: %', v_res;
    END IF;
    IF (SELECT anulada_at FROM mermas_stock WHERE id = v_merma1) IS NULL
       OR EXISTS (SELECT 1 FROM public.mermas_valorizadas(v_hoy, v_hoy, ARRAY[v_suc]) mv WHERE mv.id = v_merma1)
       OR (SELECT cantidad FROM pedido_items WHERE id = v_item1) <> 10 THEN
      RAISE EXCEPTION 'ens847 · anular no anulo la merma o no restituyo la linea';
    END IF;

    SELECT jsonb_object_agg('P' || array_position(v_p, pr.id),
             jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = ANY(v_p);
    v_log := v_log || jsonb_build_object('post_anular', v_foto);
    IF v_foto <> '{"P1":{"stock":80,"lote":50,"bolsa":30},
                  "P2":{"stock":80,"lote":50,"bolsa":30}}'::jsonb THEN
      RAISE EXCEPTION 'ens847 · anular movio stock/lote/bolsa: %', v_foto;
    END IF;

    RAISE EXCEPTION 'ens847-ok %', v_log USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM NOT LIKE 'ens847-ok%' THEN RAISE; END IF;
    RAISE NOTICE '%', SQLERRM;
  END;
END
$ensayo$;
