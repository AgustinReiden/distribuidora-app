-- La merma de la salvedad resta exacto (#1001)
--
-- EL PROBLEMA
--
--   El bloque devolver+mermar de `registrar_salvedad` (mig 234; desde la 297 lo
--   usan dañado, vencido y faltante de stock) suma +N con 'salvedad_merma' y
--   despues resta con `GREATEST(stock - N, 0)`. Si el stock ya era negativo el
--   neto no da cero: con stock -2 y una salvedad de 3, +3 lo lleva a 1 y la
--   resta con el clamp lo deja en 0. Dos unidades fantasma, sin que falle nada
--   (`productos.stock` no tiene CHECK). La cancelacion por falta de stock
--   (mig 269) ya restaba exacto, a proposito: la resta es la inversa de la suma.
--
-- LA REGLA
--
--   La resta de productos.stock pasa a ser exacta, como en la 269: -2 entra y
--   -2 sale. El stock negativo sigue a la vista donde ya estaba: STK-B
--   (critico, "ningun producto con stock<0") de `auditoria_integridad()`.
--
--   La fila de `mermas_stock` NO cambia y queda igual que la de la 269:
--   `stock_anterior` = el stock ya devuelto, `stock_nuevo` =
--   GREATEST(stock_anterior - N, 0). Es lo que define MERMA-B, que no se toca. El
--   stock real de cada momento esta en el ledger (stock_historico), que es lo que
--   compara STK-A. MERMA-H (sin negativos) tampoco se toca. Caso borde: si el
--   stock era tan negativo que sigue negativo despues de devolver (stock < -N),
--   `stock_anterior` sale negativo y MERMA-H lo marca. Es lo mismo que hace la
--   269.
--
--   Con stock >= 0 no cambia nada: despues de +N el stock es s+N >= N, y
--   GREATEST(s+N-N, 0) = s, asi que el delta (-N), el consumo FEFO, el ledger y
--   la fila de la merma son los mismos de antes. Con stock < 0 la bajada se
--   comporta como cualquier otra: consume FEFO lo que la bolsa no cubre. Si al
--   producto le quedaban unidades en lotes con el stock en negativo (LOTE-A ya
--   roto, se llega con una devolucion de la lista blanca sobre stock negativo),
--   esos lotes se vacian, y es correcto: el clamp los dejaba como estaban y
--   ademas, con stock < -N, SUBIA el stock a 0 con una fila 'merma' de
--   diferencia positiva en el ledger. La devolucion sigue con
--   'salvedad_merma', FUERA de la lista blanca: la devolucion que se cancela
--   sola no va etiquetada (CLAUDE.md, migs 229/234). El $verif$ lo vuelve a
--   comprobar.
--
--   Sin backfill: medido en prod (08/10), ninguna merma de salvedad
--   tiene en el ledger una 'merma' distinta de -cantidad, y no hay ninguna
--   'merma' con diferencia positiva. El clamp nunca llego a morder.
--
-- Firma, SECURITY DEFINER y GRANTs: como estaban (el cuerpo se parchea en vivo,
-- como la 269 y la 297; el reemplazo tiene que aparecer exactamente una vez).

DO $registrar$
DECLARE
  v_fn    constant text := 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)';
  v_def   text := pg_get_functiondef(v_fn::regprocedure);
  v_viejo constant text := $q$       SET stock = GREATEST(stock - p_cantidad_afectada, 0)$q$;
  v_nuevo constant text := $q$       -- #1001: resta exacta, como la 269. Es la inversa de la suma de
       -- arriba: con GREATEST, un stock que ya era negativo quedaba en 0 y
       -- aparecian unidades fantasma. La fila de mermas_stock sigue con el
       -- clamp (MERMA-B).
       SET stock = stock - p_cantidad_afectada$q$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo) <> 1 THEN
    RAISE EXCEPTION 'registrar_salvedad no tiene exactamente una resta con GREATEST: revisar a mano';
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
  IF v_def LIKE '%GREATEST(stock - p_cantidad_afectada, 0)%'
     OR v_def NOT LIKE '%SET stock = stock - p_cantidad_afectada%'
     -- la fila de la merma sigue con el clamp de MERMA-B
     OR v_def NOT LIKE '%v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0)%'
     -- lo que ya hacia, intacto
     OR v_def NOT LIKE '%''producto_danado'', ''producto_vencido'', ''faltante_stock'') AND v_mueve_stock%'
     OR v_def NOT LIKE '%''app.stock_origen'', ''salvedad_merma''%'
     OR v_def NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo como se esperaba';
  END IF;

  IF pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure) LIKE '%''salvedad_merma''%' THEN
    RAISE EXCEPTION 'salvedad_merma aparecio en la lista blanca de sincronizar_lotes_stock';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
              WHERE c->>'id' IN ('MERMA-B','MERMA-H','STK-A','STK-F')
                AND (c->>'violaciones')::int <> 0) THEN
    RAISE EXCEPTION 'un check de mermas/stock quedo en rojo';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- Ensayo #1001 con datos reales (se deshace solo: termina en una excepcion
-- atrapada).
--
--   P1: stock 10, pedido de 10 (queda en 0), se fuerza a -2 (el inventario ya
--       estaba mal) y faltante de 3. Tiene que quedar en -2: neto cero. Con el
--       GREATEST de la 234 quedaba en 0, dos fantasmas.
--   P2: lo mismo con 'producto_danado': mismo bloque, misma regla.
--   P3: el caso normal no cambia. Stock 90 = lote 50 + bolsa 40, pedido de 10
--       (bolsa 30), faltante de 3: stock, lote y bolsa quedan EXACTAMENTE como
--       despues del alta (el ensayo de la 297).
--   En los tres: ledger +3 'salvedad_merma' / -3 'merma', fila de mermas_stock
--   con el clamp, y MERMA-B / MERMA-H / STK-A sin violaciones nuevas.
--
--   Medido contra el cuerpo vigente antes de esta migracion: P1 y P2 terminan
--   en 0, y P3 queda igual.
-- ---------------------------------------------------------------------------
DO $ensayo1001$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_p       bigint[] := ARRAY[]::bigint[];
  v_prod    bigint;
  v_res     jsonb;
  v_ped     bigint;
  v_item    bigint;
  v_salv    bigint[] := ARRAY[]::bigint[];
  v_motivo  text;
  v_foto    jsonb;
  v_base    jsonb;
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
    RAISE EXCEPTION 'ens1001 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1001 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  BEGIN
    SELECT jsonb_object_agg(c->>'id', (c->>'violaciones')::int) INTO v_base
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     WHERE c->>'id' IN ('MERMA-B', 'MERMA-H', 'STK-A');

    FOR v_i IN 1..3 LOOP
      INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
      VALUES ('ZZ ensayo 1001 P' || v_i, 100, CASE WHEN v_i = 3 THEN 90 ELSE 10 END, 60, v_suc)
      RETURNING id INTO v_prod;
      IF v_i = 3 THEN
        INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
        VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);
      END IF;
      v_p := v_p || v_prod;
    END LOOP;

    v_res := public.crear_pedido_completo(
      v_cliente, 3000, v_admin,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_p[1], 'cantidad', 10, 'precio_unitario', 100),
        jsonb_build_object('producto_id', v_p[2], 'cantidad', 10, 'precio_unitario', 100),
        jsonb_build_object('producto_id', v_p[3], 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo 1001');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens1001 · no se pudo crear el pedido: %', v_res;
    END IF;
    v_ped := (v_res->>'pedido_id')::bigint;

    -- El inventario ya estaba mal: P1 y P2 quedan en -2.
    UPDATE productos SET stock = -2 WHERE id IN (v_p[1], v_p[2]);

    SELECT jsonb_object_agg('P' || array_position(v_p, pr.id),
             jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = ANY(v_p);
    IF v_foto <> '{"P1":{"stock":-2,"lote":0,"bolsa":-2},
                  "P2":{"stock":-2,"lote":0,"bolsa":-2},
                  "P3":{"stock":80,"lote":50,"bolsa":30}}'::jsonb THEN
      RAISE EXCEPTION 'ens1001 · el alta no dejo el punto de partida esperado: %', v_foto;
    END IF;

    FOR v_i IN 1..3 LOOP
      v_motivo := CASE v_i WHEN 2 THEN 'producto_danado' ELSE 'faltante_stock' END;
      SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_p[v_i];
      v_res := public.registrar_salvedad(v_ped, v_item, 3, v_motivo, NULL, NULL, true, NULL);
      IF NOT COALESCE((v_res->>'success')::boolean, false)
         OR NOT COALESCE((v_res->>'merma_registrada')::boolean, false) THEN
        RAISE EXCEPTION 'ens1001 · registrar % sobre P%: %', v_motivo, v_i, v_res;
      END IF;
      v_salv := v_salv || (v_res->>'salvedad_id')::bigint;
    END LOOP;

    -- Neto cero: el stock, el lote y la bolsa quedan como antes de la salvedad.
    SELECT jsonb_object_agg('P' || array_position(v_p, pr.id),
             jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r))
      INTO v_foto
      FROM productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = ANY(v_p);
    IF v_foto <> '{"P1":{"stock":-2,"lote":0,"bolsa":-2},
                  "P2":{"stock":-2,"lote":0,"bolsa":-2},
                  "P3":{"stock":80,"lote":50,"bolsa":30}}'::jsonb THEN
      RAISE EXCEPTION 'ens1001 · la salvedad no dejo el neto en cero: %', v_foto;
    END IF;

    -- La fila de la merma: medida contra el stock ya devuelto, con el clamp.
    SELECT jsonb_object_agg('P' || array_position(v_p, m.producto_id),
             jsonb_build_object('motivo', m.motivo, 'cantidad', m.cantidad,
                                'ant', m.stock_anterior, 'nuevo', m.stock_nuevo))
      INTO v_foto
      FROM mermas_stock m WHERE m.salvedad_id = ANY(v_salv);
    IF v_foto IS DISTINCT FROM
       '{"P1":{"motivo":"error_inventario","cantidad":3,"ant":1,"nuevo":0},
         "P2":{"motivo":"rotura","cantidad":3,"ant":1,"nuevo":0},
         "P3":{"motivo":"error_inventario","cantidad":3,"ant":83,"nuevo":80}}'::jsonb THEN
      RAISE EXCEPTION 'ens1001 · las mermas no quedaron como se esperaba: %', v_foto;
    END IF;

    -- Ledger: +3 fuera de la lista blanca, -3 como merma. Exacto, en los tres.
    SELECT jsonb_object_agg(k, v) INTO v_foto
      FROM (SELECT 'P' || array_position(v_p, sh.producto_id) AS k,
                   jsonb_agg(jsonb_build_object('origen', sh.origen, 'dif', sh.diferencia) ORDER BY sh.id) AS v
              FROM stock_historico sh
             WHERE sh.producto_id = ANY(v_p) AND sh.origen IN ('salvedad_merma', 'merma')
             GROUP BY sh.producto_id) x;
    IF v_foto IS DISTINCT FROM
       '{"P1":[{"origen":"salvedad_merma","dif":3},{"origen":"merma","dif":-3}],
         "P2":[{"origen":"salvedad_merma","dif":3},{"origen":"merma","dif":-3}],
         "P3":[{"origen":"salvedad_merma","dif":3},{"origen":"merma","dif":-3}]}'::jsonb THEN
      RAISE EXCEPTION 'ens1001 · el ledger no es +3 salvedad_merma / -3 merma: %', v_foto;
    END IF;

    -- Ningun check de mermas/stock suma violaciones.
    SELECT jsonb_object_agg(c->>'id', (c->>'violaciones')::int) INTO v_foto
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     WHERE c->>'id' IN ('MERMA-B', 'MERMA-H', 'STK-A');
    IF v_foto IS DISTINCT FROM v_base THEN
      RAISE EXCEPTION 'ens1001 · un check cambio: antes % despues %', v_base, v_foto;
    END IF;

    RAISE EXCEPTION 'ens1001-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'ens1001-ok' THEN RAISE; END IF;
  END;
END
$ensayo1001$;
