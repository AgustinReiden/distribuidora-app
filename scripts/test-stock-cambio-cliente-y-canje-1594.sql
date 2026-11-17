-- Ensayo de la migración del cambio de cliente y el canje (reauditoría del 15/11: STK-1 y STK-2 de
-- #1594 y sus bajos 1594-b2 y 1594-b4; 1595-b3 y 1595-b8 de #1595; tarjeta M3 de #1603).
--
-- Corre contra una base con el schema de prod SIN dejar rastro (salvo valores de secuencia): un
-- único DO que termina SIEMPRE en una excepción. Cada caso usa sus propios productos y clientes.
--
-- Personas (salen de la base): un admin activo de una sucursal activa. Lo demás lo crea el ensayo.
-- Con bolsa 0 la bajada cae en el lote por FEFO y un error así no se ve (migrations/CLAUDE.md):
-- cada caso de lotes arranca con bolsa.
--
-- STK-1 · el cambio de cliente conserva la huella y no pasa unidades de la bolsa al lote.
--   C1 · L1 (+10) 100 con 50, L2 (+40) 100 con 100, bolsa 20. B vende 20 (de la bolsa), A vende 30
--        (de L1), se cancela B (la bolsa vuelve a 20) y se cambia el cliente de A. Queda
--        stock=140 lotes=[20,100] bolsa=20 y el pedido nuevo con L1:30; cancelar el nuevo vuelve a
--        stock=170 lotes=[50,100] bolsa=20. Antes: lotes=[40,100] bolsa=0 y L1:10.
--   C2 · la huella en dos lotes: bolsa 15, B vende 15, A vende 70 (L1:50, L2:20), se cancela B.
--        Queda lotes=[0,80] bolsa=15 y el nuevo con L1:50 y L2:20. Antes: [15,80] bolsa 0.
--   C3 · un regalo que mueve stock (modo A): el regalo de S salió de L1 (L1:2); con la bolsa de S
--        en 5 el cambio deja S en lotes=[48] bolsa=5 y el regalo nuevo con L1:2. Antes: [50] y 3.
--   C4 · regresión, la bolsa no cambió: A vende 30 con bolsa 20 (20 de la bolsa, 10 de L1). Queda
--        igual, lotes=[40,100] bolsa=0, y el nuevo con L1:10.
-- STK-2 · lo que vuelve en buen estado en un canje no entra a un lote vencido.
--   K1 · L0 venció hace 5 días (100 con 30), L1 (+60) 100 con 50, bolsa 20: el canje 'erroneo'
--        de 10 deja lotes=[30,60] bolsa=20 (al lote vigente con hueco). Antes: [40,50].
--   K2 · sin lote vigente con hueco (L1 lleno): va a la bolsa, lotes=[30,100] bolsa=30. Antes [40,100].
--   K3 · el mismo producto, devuelve 12 y se lleva 2: las 10 de diferencia van a L1, [30,60]. Antes [40,50].
--   K4 · regresión, la primera pasada: una cancelación vuelve a SU lote por la huella aunque ese
--        lote haya vencido después de la venta (lotes=[50,50] bolsa=0).
-- 1594-b2 · K5 · el canje del mismo producto que reingresa pide stock por la diferencia: con 5 en
--        stock, devolver 10 y llevarse 12 entra (stock 3). Antes: «Stock insuficiente».
-- 1594-b4 · K6 · la merma del canje: la subida queda 'cambio_producto_merma' del canje, la bajada
--        'merma' de su fila de mermas_stock (como la merma manual, la salvedad y la cancelación por
--        falta de stock), y la fila nombra el canje. Antes: las dos patas 'cambio_producto_merma'.
-- 1595-b3 · G1 · después de un cambio de cliente, los GUC de la reatribución (conservar pagos, el
--        envío forzado y su estado, omitir el mínimo del pedido) vuelven a lo que tenían. G2 · un
--        cambio rechazado (el mismo cliente) no deja ninguno prendido. Antes: quedaban en '1' / el cargo.
-- 1595-b8 · V1 · el costo de cada línea del pedido nuevo es el de la línea de X (60), no el de hoy
--        (90). V2 · la comanda de un canje (canal 'cambio') no cambia de cliente. Antes: costo 90, y
--        la comanda se cancelaba y se volvía a dar de alta como venta.
-- A1 · los checks de stock, lotes, mermas, costo y canje de auditoria_integridad() no suman
--      violaciones.
--
-- Sin la migración tiene que FALLAR en C1–C3, K1–K3, K5, K6, G1, G2, V1 y V2. C4 y K4 son regresión.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   psql "$DATABASE_URL" -f scripts/test-stock-cambio-cliente-y-canje-1594.sql

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_cli    bigint;
  v_cli2   bigint;
  p        bigint;
  q        bigint;
  a        bigint;
  s        bigint;
  v_promo  bigint;
  v_a      bigint;
  v_b      bigint;
  v_nuevo  bigint;
  v_cid    bigint;
  v_mid    bigint;
  v_l0     bigint;
  v_j      jsonb;
  v_t      text;
  v_res    text;
  v_items  jsonb;
  v_guc    text[];
  v_guc2   text[];
  v_antes  jsonb;
  v_checks jsonb;
  v_fallas text[] := '{}';
  k        text;
BEGIN
  SET LOCAL lock_timeout = '5s';
  SET CONSTRAINTS ALL IMMEDIATE;

  -- ------------------------------------------------------------- personas ---
  SELECT us.sucursal_id, us.usuario_id INTO v_suc, v_adm
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.activo AND pf.rol = 'admin'
    JOIN sucursales su ON su.id = us.sucursal_id AND su.activa
   ORDER BY us.sucursal_id, us.usuario_id
   LIMIT 1;
  IF v_adm IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('e1594.suc', v_suc::text, true);

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1594', 'ZZ ensayo 1594', 'calle 1', v_suc) RETURNING id INTO v_cli;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1594 b', 'ZZ ensayo 1594 b', 'calle 2', v_suc) RETURNING id INTO v_cli2;

  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_antes
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
   WHERE x->>'id' IN ('STK-A', 'STK-B', 'STK-D', 'STK-F', 'LOTE-A', 'LOTE-B', 'LOTE-D', 'MERMA-B',
                      'MERMA-H', 'MERMA-I', 'COSTO-D', 'CAMBIO-01', 'CAMBIO-03');

  -- ---------------------------------------------------------------- helpers -
  -- Un producto con lotes [{dias, cantidad, restante}] y p_bolsa unidades sin lote.
  CREATE FUNCTION pg_temp.prod(p_lotes jsonb, p_bolsa int) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_prod bigint; l jsonb; v_s bigint := current_setting('e1594.suc')::bigint;
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES ('ZZ ensayo 1594 ' || gen_random_uuid(), 100,
            p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
            60, 60, 60, 60, v_s) RETURNING id INTO v_prod;
    FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
      VALUES (v_prod, v_s, public._tablero_hoy() + (l->>'dias')::int,
              (l->>'cantidad')::int, (l->>'restante')::int, 'manual');
    END LOOP;
    RETURN v_prod;
  END $f$;

  -- La foto: 'stock=… lotes=[restante por vencimiento] bolsa=…'.
  CREATE FUNCTION pg_temp.f(p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('stock=%s lotes=[%s] bolsa=%s', p.stock,
      COALESCE((SELECT string_agg(cantidad_restante::text, ',' ORDER BY fecha_vencimiento, id)
                  FROM producto_lotes WHERE producto_id = p_prod), ''),
      p.stock - COALESCE((SELECT sum(cantidad_restante) FROM producto_lotes WHERE producto_id = p_prod), 0))
    FROM productos p WHERE p.id = p_prod;
  $f$;

  -- La huella de un pedido sobre un producto: 'L<orden del lote>:<cant>' por lote, sumada.
  CREATE FUNCTION pg_temp.h(p_ped bigint, p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(format('L%s:%s', x.n, x.c), ' ' ORDER BY x.n), '-')
      FROM (SELECT (SELECT count(*) FROM producto_lotes l2
                     WHERE l2.producto_id = p_prod
                       AND (l2.fecha_vencimiento, l2.id) <= (l.fecha_vencimiento, l.id)) AS n,
                   sum(pil.cantidad) AS c
              FROM pedido_item_lotes pil
              JOIN pedido_items pi ON pi.id = pil.pedido_item_id
              JOIN producto_lotes l ON l.id = pil.lote_id
             WHERE pi.pedido_id = p_ped AND pi.producto_id = p_prod
             GROUP BY l.id, l.fecha_vencimiento) x;
  $f$;

  -- '{}' si la foto es la esperada; si no, la falla.
  CREATE FUNCTION pg_temp.ver(p_caso text, p_prod bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.f(p_prod) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: %s (esperado %s)', p_caso, pg_temp.f(p_prod), p_espera)] END;
  $f$;
  CREATE FUNCTION pg_temp.verh(p_caso text, p_ped bigint, p_prod bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.h(p_ped, p_prod) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: huella %s (esperada %s)', p_caso, pg_temp.h(p_ped, p_prod), p_espera)] END;
  $f$;

  CREATE FUNCTION pg_temp.it(p_prod bigint, p_cant int) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
  $f$;

  CREATE FUNCTION pg_temp.alta(p_cli bigint, p_adm uuid, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb; v_tot numeric;
  BEGIN
    SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
      FROM jsonb_array_elements(p_items) e;
    v := public.crear_pedido_completo(p_cli, v_tot, p_adm, p_items, 'ensayo 1594');
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'ENSAYO FALLÓ · alta: %', v; END IF;
    RETURN (v->>'pedido_id')::bigint;
  END $f$;

  -- El cambio de cliente con los mismos items; devuelve el pedido nuevo o falla.
  CREATE FUNCTION pg_temp.cambio(p_ped bigint, p_cli bigint, p_adm uuid, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb; v_tot numeric;
  BEGIN
    SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
      FROM jsonb_array_elements(p_items) e;
    v := public.cambiar_cliente_pedido(p_ped, p_cli, p_adm, p_items, v_tot);
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'ENSAYO FALLÓ · cambio: %', v; END IF;
    RETURN (v->>'nuevo_pedido_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.cancelar(p_ped bigint, p_adm uuid) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    v := public.cancelar_pedido_con_stock(p_ped, 'ensayo 1594', p_adm, NULL);
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'ENSAYO FALLÓ · cancelar: %', v; END IF;
  END $f$;

  CREATE FUNCTION pg_temp.gucs() RETURNS text[] LANGUAGE sql AS $f$
    SELECT ARRAY[COALESCE(current_setting('app.cancelacion_conserva_pagos', true), ''),
                 COALESCE(current_setting('app.cargo_envio_forzado', true), ''),
                 COALESCE(current_setting('app.cargo_envio_estado_forzado', true), ''),
                 COALESCE(current_setting('app.omitir_minimo_pedido', true), '')];
  $f$;

  -- ------------------------------------------------------------ STK-1 · C1 ---
  p := pg_temp.prod('[{"dias":10,"cantidad":100,"restante":50},{"dias":40,"cantidad":100,"restante":100}]', 20);
  v_b := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(p, 20)));
  v_a := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(p, 30)));
  PERFORM pg_temp.cancelar(v_b, v_adm);
  v_fallas := v_fallas || pg_temp.ver('C1 antes del cambio', p, 'stock=140 lotes=[20,100] bolsa=20');
  v_nuevo := pg_temp.cambio(v_a, v_cli2, v_adm, jsonb_build_array(pg_temp.it(p, 30)));
  v_fallas := v_fallas || pg_temp.ver('C1 cambio de cliente', p, 'stock=140 lotes=[20,100] bolsa=20');
  v_fallas := v_fallas || pg_temp.verh('C1 pedido nuevo', v_nuevo, p, 'L1:30');
  PERFORM pg_temp.cancelar(v_nuevo, v_adm);
  v_fallas := v_fallas || pg_temp.ver('C1 cancelar el nuevo', p, 'stock=170 lotes=[50,100] bolsa=20');

  -- ------------------------------------------------------------ STK-1 · C2 ---
  p := pg_temp.prod('[{"dias":10,"cantidad":100,"restante":50},{"dias":40,"cantidad":100,"restante":100}]', 15);
  v_b := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(p, 15)));
  v_a := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(p, 70)));
  PERFORM pg_temp.cancelar(v_b, v_adm);
  v_nuevo := pg_temp.cambio(v_a, v_cli2, v_adm, jsonb_build_array(pg_temp.it(p, 70)));
  v_fallas := v_fallas || pg_temp.ver('C2 cambio de cliente', p, 'stock=95 lotes=[0,80] bolsa=15');
  v_fallas := v_fallas || pg_temp.verh('C2 pedido nuevo', v_nuevo, p, 'L1:50 L2:20');

  -- ------------------------------------------------------------ STK-1 · C3 ---
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 5);
  INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1594', 'bonificacion', public._tablero_hoy() - 1, v_suc, true, s)
  RETURNING id INTO v_promo;
  INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 2, v_suc);
  INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, a, v_suc);
  v_items := jsonb_build_array(
    pg_temp.it(a, 10),
    jsonb_build_object('producto_id', s, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo));
  v_b := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(s, 5)));
  v_a := pg_temp.alta(v_cli, v_adm, v_items);
  PERFORM pg_temp.cancelar(v_b, v_adm);
  v_fallas := v_fallas || pg_temp.ver('C3 antes del cambio', s, 'stock=53 lotes=[48] bolsa=5');
  v_nuevo := pg_temp.cambio(v_a, v_cli2, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('C3 cambio de cliente', s, 'stock=53 lotes=[48] bolsa=5');
  v_fallas := v_fallas || pg_temp.verh('C3 regalo del pedido nuevo', v_nuevo, s, 'L1:2');

  -- ------------------------------------------------------------ STK-1 · C4 ---
  p := pg_temp.prod('[{"dias":10,"cantidad":100,"restante":50},{"dias":40,"cantidad":100,"restante":100}]', 20);
  v_a := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(p, 30)));
  v_nuevo := pg_temp.cambio(v_a, v_cli2, v_adm, jsonb_build_array(pg_temp.it(p, 30)));
  v_fallas := v_fallas || pg_temp.ver('C4 cambio sin que la bolsa cambie', p, 'stock=140 lotes=[40,100] bolsa=0');
  v_fallas := v_fallas || pg_temp.verh('C4 pedido nuevo', v_nuevo, p, 'L1:10');

  -- ------------------------------------------------------------ STK-2 · K1 ---
  q := pg_temp.prod('[]', 100);
  p := pg_temp.prod('[{"dias":-5,"cantidad":100,"restante":30},{"dias":60,"cantidad":100,"restante":50}]', 20);
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 10, q, 10, 'ensayo 1594', 'erroneo');
  v_fallas := v_fallas || pg_temp.ver('K1 canje con un lote vencido', p, 'stock=110 lotes=[30,60] bolsa=20');

  -- ------------------------------------------------------------ STK-2 · K2 ---
  p := pg_temp.prod('[{"dias":-5,"cantidad":100,"restante":30},{"dias":60,"cantidad":100,"restante":100}]', 20);
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 10, q, 10, 'ensayo 1594', 'erroneo');
  v_fallas := v_fallas || pg_temp.ver('K2 canje sin lote vigente con hueco', p, 'stock=160 lotes=[30,100] bolsa=30');

  -- ------------------------------------------------------------ STK-2 · K3 ---
  p := pg_temp.prod('[{"dias":-5,"cantidad":100,"restante":30},{"dias":60,"cantidad":100,"restante":50}]', 20);
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 12, p, 2, 'ensayo 1594', 'erroneo');
  v_fallas := v_fallas || pg_temp.ver('K3 canje del mismo producto', p, 'stock=110 lotes=[30,60] bolsa=20');

  -- ------------------------------------------------------------ STK-2 · K4 ---
  p := pg_temp.prod('[{"dias":5,"cantidad":100,"restante":50},{"dias":60,"cantidad":100,"restante":50}]', 0);
  v_a := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(p, 10)));
  SELECT id INTO v_l0 FROM producto_lotes WHERE producto_id = p ORDER BY fecha_vencimiento LIMIT 1;
  UPDATE producto_lotes SET fecha_vencimiento = public._tablero_hoy() - 1 WHERE id = v_l0;
  PERFORM pg_temp.cancelar(v_a, v_adm);
  v_fallas := v_fallas || pg_temp.ver('K4 la devolución vuelve a su lote aunque venció', p, 'stock=100 lotes=[50,50] bolsa=0');

  -- ---------------------------------------------------------- 1594-b2 · K5 ---
  p := pg_temp.prod('[]', 5);
  BEGIN
    PERFORM public.registrar_cambio_producto(v_cli::int, p, 10, p, 12, 'ensayo 1594', 'erroneo');
    v_res := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_res := SQLERRM;
  END;
  IF v_res <> 'ok' THEN
    v_fallas := v_fallas || format('K5 canje del mismo producto rechazado: %s', v_res);
  END IF;
  v_fallas := v_fallas || pg_temp.ver('K5 canje del mismo producto', p, 'stock=3 lotes=[] bolsa=3');

  -- ---------------------------------------------------------- 1594-b4 · K6 ---
  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  v_cid := public.registrar_cambio_producto(v_cli::int, p, 3, q, 3, 'ensayo 1594', 'vencimiento');
  SELECT id INTO v_mid FROM mermas_stock WHERE producto_id = p;
  -- Sin la fila del alta del producto del ensayo (0->90 'alta_producto', 1594-b1 de la ola 2 de #1603).
  SELECT string_agg(format('%s->%s %s %s', stock_anterior, stock_nuevo, origen, referencia_tipo), ' | ' ORDER BY id) INTO v_t
    FROM stock_historico WHERE producto_id = p AND origen IS DISTINCT FROM 'alta_producto';
  IF v_t IS DISTINCT FROM '90->93 cambio_producto_merma cambios_productos | 93->90 merma mermas_stock' THEN
    v_fallas := v_fallas || format('K6: ledger del devuelto %s', COALESCE(v_t, '(nada)'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM stock_historico WHERE producto_id = p AND origen = 'cambio_producto_merma'
                    AND referencia_id = v_cid)
     OR NOT EXISTS (SELECT 1 FROM stock_historico WHERE producto_id = p AND origen = 'merma'
                    AND referencia_id = v_mid) THEN
    v_fallas := v_fallas || 'K6: las patas no apuntan al canje y a la merma'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM mermas_stock WHERE id = v_mid AND observaciones LIKE '%#' || v_cid || '%'
                    AND stock_nuevo = stock_anterior - cantidad) THEN
    v_fallas := v_fallas || format('K6: la merma no nombra el canje #%s: %s', v_cid,
                                   (SELECT observaciones FROM mermas_stock WHERE id = v_mid));
  END IF;
  v_fallas := v_fallas || pg_temp.ver('K6 devuelto', p, 'stock=90 lotes=[50] bolsa=40');

  -- --------------------------------------------------------- 1595-b3 · G1 ---
  p := pg_temp.prod('[]', 100);
  v_a := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(p, 5)));
  -- Los cambios de arriba corrieron en esta misma transacción: sin la migración los dejaron prendidos.
  PERFORM set_config('app.cancelacion_conserva_pagos', '', true), set_config('app.cargo_envio_forzado', '', true),
          set_config('app.cargo_envio_estado_forzado', '', true), set_config('app.omitir_minimo_pedido', '', true);
  v_guc := pg_temp.gucs();
  v_nuevo := pg_temp.cambio(v_a, v_cli2, v_adm, jsonb_build_array(pg_temp.it(p, 5)));
  v_guc2 := pg_temp.gucs();
  IF v_guc2 IS DISTINCT FROM v_guc THEN
    v_fallas := v_fallas || format('G1 GUC después del cambio %s (antes %s)', v_guc2, v_guc);
  END IF;

  -- --------------------------------------------------------- 1595-b3 · G2 ---
  PERFORM set_config('app.cancelacion_conserva_pagos', '', true), set_config('app.cargo_envio_forzado', '', true),
          set_config('app.cargo_envio_estado_forzado', '', true), set_config('app.omitir_minimo_pedido', '', true);
  v_j := public.cambiar_cliente_pedido(v_nuevo, v_cli2, v_adm, jsonb_build_array(pg_temp.it(p, 5)), 500);
  v_guc2 := pg_temp.gucs();
  IF COALESCE((v_j->>'success')::boolean, false) OR v_guc2 IS DISTINCT FROM v_guc THEN
    v_fallas := v_fallas || format('G2 cambio rechazado %s, GUC %s (antes %s)', v_j, v_guc2, v_guc);
  END IF;

  -- --------------------------------------------------------- 1595-b8 · V1 ---
  p := pg_temp.prod('[]', 100);
  v_a := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(p, 4)));
  UPDATE productos SET costo_promedio = 90, costo_real = 90 WHERE id = p;
  v_nuevo := pg_temp.cambio(v_a, v_cli2, v_adm, jsonb_build_array(pg_temp.it(p, 4)));
  SELECT string_agg(costo_unitario_al_crear::text, ',') INTO v_t FROM pedido_items WHERE pedido_id = v_nuevo;
  IF v_t IS DISTINCT FROM '60.0000' AND v_t IS DISTINCT FROM '60' AND v_t IS DISTINCT FROM '60.00' THEN
    v_fallas := v_fallas || format('V1 costo del pedido nuevo %s (esperado el de X, 60)', v_t);
  END IF;

  -- --------------------------------------------------------- 1595-b8 · V2 ---
  p := pg_temp.prod('[]', 100);
  v_a := public.crear_pedido_cambio_en_ruta(v_cli::int, p, 1, q, 1, 'ensayo 1594', 'erroneo');
  BEGIN
    v_j := public.cambiar_cliente_pedido(v_a, v_cli2, v_adm, jsonb_build_array(pg_temp.it(q, 1)), 100);
    v_res := COALESCE(v_j->>'error', 'ok');
  EXCEPTION WHEN OTHERS THEN
    v_res := 'excepción: ' || SQLERRM;
  END;
  IF v_res NOT ILIKE '%canje%' OR (SELECT estado FROM pedidos WHERE id = v_a) <> 'pendiente' THEN
    v_fallas := v_fallas || format('V2 la comanda de un canje cambió de cliente: %s (estado %s)', v_res,
                                   (SELECT estado FROM pedidos WHERE id = v_a));
  END IF;

  -- ------------------------------------------------------------------- A1 ---
  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_checks
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
   WHERE x->>'id' IN (SELECT jsonb_object_keys(v_antes));
  FOR k IN SELECT jsonb_object_keys(v_antes) LOOP
    IF (v_checks->>k)::bigint > (v_antes->>k)::bigint THEN
      v_fallas := v_fallas || format('A1 %s: %s violaciones (antes %s)', k, v_checks->>k, v_antes->>k);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · C1–C4, K1–K6, G1, G2, V1, V2 y A1';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
END
$ensayo$;
