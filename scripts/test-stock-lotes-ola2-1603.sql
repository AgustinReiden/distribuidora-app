-- Ensayo de la migración de stock y lotes de la ola 2 del plan #1603 (tarjeta B3):
-- migrations/NNN_stock_lotes_y_cambio_de_cliente.sql.
--
-- Corre contra una base con el schema de prod SIN dejar rastro (salvo valores de secuencia): un
-- único DO que termina SIEMPRE en una excepción. Cada caso usa sus propios productos y promos.
-- En cada caso se mira el stock total, el stock por lote (y la bolsa) y el ledger: la última fila
-- de stock_historico es el stock, y cada fila arranca donde terminó la anterior (pg_temp.cierra).
--
-- Personas (salen de la base): un admin activo de una sucursal activa. Lo demás lo crea el ensayo.
--
-- M3-1 · el cambio de cliente no pasa el fardo del contenedor de la bolsa al lote.
--   Promo de barra: 2 regalos de S cada 10 de A; 1 fardo de C cada 2 regalos. X = A×10 + S×2.
--   M1 · C con un lote de 100 con 50 y bolsa 0: la venta saca el fardo del lote ([49]). La bolsa de
--        C sube 10 y se cambia el cliente con los mismos items: queda stock=59 lotes=[49] bolsa=10, y
--        el bloque nuevo dice que su fardo salió del lote. Cancelar el nuevo: lotes=[50] bolsa=10.
--        Antes: lotes=[50] bolsa=9 y el bloque nuevo decía {"lote_id": null}.
--   M2 · C también se vende como línea (C×5, del lote): lotes=[44] bolsa=10 y la huella L1:5 en el
--        pedido nuevo. Antes: [45] y 9.
--   M3 · regresión: el fardo de X salió de la bolsa (C con lote 100/50 y bolsa 5): el cambio deja
--        lotes=[50] bolsa=4 y el bloque nuevo con {"lote_id": null}.
--   M4 · el orden de la anotación (H2 de la revisión de B3): un bloque de 2 fardos [bolsa:1 L1:1]
--        (X = A×20 + S×4, C con lote 100/50 y bolsa 1). La bolsa sube 10 y se cambia el cliente: el
--        bloque nuevo queda [bolsa:1 L1:1], como lo anota el motor, y deshacer UN fardo con el motor
--        lo devuelve al lote (lotes=[50] bolsa=10), como sin el cambio. Con [L1:1 bolsa:1], a la bolsa.
-- 1556-c1 · el cambio de cliente de un pedido de un tramo anterior de la barra es neto 0.
--   Promo de fracción "10 V dan 4 R", contenedor Cont (lote 100/60 y bolsa 40; 6 R = 1 Cont).
--   X = V×10 + R×4; la promo pasa a mover stock y vuelve a fracción (la barra se reinicia y la foto
--   de X queda marcada); T = V×10 + R×4 después del reinicio (barra en 4).
--   C1 · cambiar el cliente de X: la barra sigue en 4, Cont=100 lotes=[60] bolsa=40, la foto del
--        pedido nuevo tiene la marca y no entra en la barra viva. Antes: la barra cerraba un fardo
--        (Cont=99, barra en 2) y la foto nacía sin marca.
--   C2 · cancelar el pedido nuevo no toca la barra ni el contenedor (barra 4, Cont=100).
--   C3 · regresión: el cambio de cliente de T (tramo nuevo) sí entra: barra 4, Cont=100, sin marca.
-- 1558-b5 · B5 · ajustar_lote deja una fila en el ledger: anterior = nuevo = stock, origen
--        'ajuste_lote', el lote y el admin. Un ajuste que no cambia nada no deja fila. Antes: nada.
-- 1558-b6 · B6 · dar_de_baja_lote: a · un lote que no venció, sin motivo, se rechaza y no cambia
--        nada (antes: se daba de baja como vencido); b · con motivo, anda: merma 'decomiso' con
--        el texto, que merma_clasificacion cuenta como 'perdida' (decisión del dueño del 17/11),
--        ledger 'lote_baja'; c · uno que vence hoy también pide motivo; d · regresión: un lote
--        vencido sin motivo anda como siempre ('vencimiento', 'lote_vencido').
-- 1558-b7 · B7 · aplicar_control_stock con un stock de planilla negativo se rechaza y no cambia el
--        stock. Antes: aplicaba la diferencia (contado − planilla) de más.
-- 1594-b1 · P1 · el alta de un producto por REST (como authenticated) con stock deja 0 → stock,
--        origen 'alta_producto'. Con stock 0, ninguna fila. Antes: ninguna fila.
-- A1 · ningún check de auditoria_integridad() suma violaciones.
--
-- Sin la migración tiene que FALLAR en M1, M2, M4, C1, C2, B5, B6a, B6b (la merma salía como
-- 'vencimiento'), B6c, B7 y P1. M3, C3 y B6d son regresión.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-stock-lotes-ola2-1603.sql

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_cli    bigint;
  v_cli2   bigint;
  a        bigint;
  s        bigint;
  c        bigint;
  p        bigint;
  v_promo  bigint;
  v_x      bigint;
  v_t      bigint;
  v_nuevo  bigint;
  v_lote   bigint;
  v_n      bigint;
  v_j      jsonb;
  v_items  jsonb;
  v_res    text;
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
  PERFORM set_config('e1603b3.suc', v_suc::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo B3', 'ZZ ensayo B3', 'calle 1', v_suc) RETURNING id INTO v_cli;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo B3 b', 'ZZ ensayo B3 b', 'calle 2', v_suc) RETURNING id INTO v_cli2;

  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_antes
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x;

  -- ---------------------------------------------------------------- helpers -
  -- Un producto con lotes [{dias, cantidad, restante}] y p_bolsa unidades sin lote.
  CREATE FUNCTION pg_temp.prod(p_lotes jsonb, p_bolsa int) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_prod bigint; l jsonb; v_s bigint := current_setting('e1603b3.suc')::bigint;
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva,
                           sucursal_id, categoria)
    VALUES ('ZZ ensayo B3 ' || gen_random_uuid(), 100,
            p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
            60, 60, 60, 60, v_s, 'ZZ ensayo B3 cat') RETURNING id INTO v_prod;
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

  -- Los lotes_pendientes del último bloque de una promo, con el lote por su orden ('L1', 'bolsa').
  CREATE FUNCTION pg_temp.bloque(p_promo bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE((
      SELECT string_agg(CASE WHEN e->>'lote_id' IS NULL THEN 'bolsa'
                             ELSE 'L' || (SELECT count(*) FROM producto_lotes l2
                                           WHERE l2.producto_id = pa.producto_id
                                             AND (l2.fecha_vencimiento, l2.id)
                                                 <= (SELECT l.fecha_vencimiento, l.id FROM producto_lotes l
                                                      WHERE l.id = (e->>'lote_id')::bigint)) END
                        || ':' || (e->>'cantidad'), ' ' ORDER BY o)
        FROM jsonb_array_elements(pa.lotes_pendientes) WITH ORDINALITY AS t(e, o)), '-')
      FROM promo_ajustes pa
     WHERE pa.promocion_id = p_promo AND pa.unidades_ajustadas > 0
     ORDER BY pa.id DESC
     LIMIT 1;
  $f$;

  -- El stock, los lotes y el ledger de un producto cierran entre sí. '{}' si cierran.
  CREATE FUNCTION pg_temp.cierra(p_caso text, p_prod bigint) RETURNS text[] LANGUAGE sql AS $f$
    SELECT ARRAY(
      SELECT format('%s: %s', p_caso, m) FROM (
        SELECT 'la última fila del ledger no es el stock' AS m
         WHERE (SELECT stock_nuevo FROM stock_historico WHERE producto_id = p_prod ORDER BY id DESC LIMIT 1)
               IS DISTINCT FROM (SELECT stock FROM productos WHERE id = p_prod)
           AND EXISTS (SELECT 1 FROM stock_historico WHERE producto_id = p_prod)
        UNION ALL
        SELECT format('la fila %s del ledger arranca en %s y la anterior terminó en %s', x.id, x.stock_anterior, x.prev)
          FROM (SELECT id, stock_anterior,
                       lag(stock_nuevo) OVER (ORDER BY id) AS prev
                  FROM stock_historico WHERE producto_id = p_prod) x
         WHERE x.prev IS NOT NULL AND x.prev <> x.stock_anterior
        UNION ALL
        SELECT 'los lotes suman más que el stock'
         WHERE (SELECT COALESCE(sum(cantidad_restante), 0) FROM producto_lotes WHERE producto_id = p_prod)
               > (SELECT stock FROM productos WHERE id = p_prod)) z);
  $f$;

  -- '{}' si la foto es la esperada y el ledger cierra; si no, la falla.
  CREATE FUNCTION pg_temp.ver(p_caso text, p_prod bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.f(p_prod) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: %s (esperado %s)', p_caso, pg_temp.f(p_prod), p_espera)] END
           || pg_temp.cierra(p_caso, p_prod);
  $f$;
  CREATE FUNCTION pg_temp.verh(p_caso text, p_ped bigint, p_prod bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.h(p_ped, p_prod) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: huella %s (esperada %s)', p_caso, pg_temp.h(p_ped, p_prod), p_espera)] END;
  $f$;
  CREATE FUNCTION pg_temp.verb(p_caso text, p_promo bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.bloque(p_promo) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: el último bloque dice %s (esperado %s)', p_caso, pg_temp.bloque(p_promo), p_espera)] END;
  $f$;

  CREATE FUNCTION pg_temp.it(p_prod bigint, p_cant int) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
  $f$;
  CREATE FUNCTION pg_temp.reg(p_prod bigint, p_cant int, p_promo bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                              'es_bonificacion', true, 'promocion_id', p_promo);
  $f$;

  -- Las llamadas pisan GUCs de stock por transacción: se limpian entre una y otra.
  CREATE FUNCTION pg_temp.limpiar() RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('app.stock_origen', '', true);
    PERFORM set_config('app.stock_ref_tipo', '', true);
    PERFORM set_config('app.stock_ref_id', '', true);
    PERFORM set_config('app.stock_user_id', '', true);
    PERFORM set_config('app.stock_pedido_item_id', '', true);
  END $f$;

  CREATE FUNCTION pg_temp.alta(p_cli bigint, p_adm uuid, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb; v_tot numeric;
  BEGIN
    SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
      FROM jsonb_array_elements(p_items) e;
    v := public.crear_pedido_completo(p_cli, v_tot, p_adm, p_items, 'ensayo B3');
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'ENSAYO FALLÓ · alta: %', v; END IF;
    RETURN (v->>'pedido_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.cambio(p_ped bigint, p_cli bigint, p_adm uuid, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb; v_tot numeric;
  BEGIN
    SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
      FROM jsonb_array_elements(p_items) e;
    v := public.cambiar_cliente_pedido(p_ped, p_cli, p_adm, p_items, v_tot);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'ENSAYO FALLÓ · cambio: %', v; END IF;
    RETURN (v->>'nuevo_pedido_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.cancelar(p_ped bigint, p_adm uuid) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    v := public.cancelar_pedido_con_stock(p_ped, 'ensayo B3', p_adm, NULL);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'ENSAYO FALLÓ · cancelar: %', v; END IF;
  END $f$;

  -- Suma unidades a la bolsa (origen fuera de la lista blanca).
  CREATE FUNCTION pg_temp.bolsa(p_prod bigint, n int) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('app.stock_origen', 'ajuste_manual', true);
    UPDATE productos SET stock = stock + n WHERE id = p_prod;
    PERFORM pg_temp.limpiar();
  END $f$;

  -- Promo de barra con contenedor: 2 regalos de s cada 10 de a; 1 fardo de c cada 2 regalos.
  CREATE FUNCTION pg_temp.promo_barra(a bigint, s bigint, c bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint; v_s bigint := current_setting('e1603b3.suc')::bigint;
  BEGIN
    -- Tanda 6 de #1603 (promos-B3, H6 de su lente), cambió de regla: la edición de una promo con ajuste
    -- automático pide, como el alta, la descripción del regalo: la promo del ensayo la trae.
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                             ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque,
                             descripcion_regalo)
    VALUES ('ZZ ensayo B3 barra', 'bonificacion', public._tablero_hoy() - 1, v_s, false, s, true, c, 2, 1,
            '1 botella de ensayo')
    RETURNING id INTO v;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v, 'cantidad_compra', 10, v_s), (v, 'cantidad_bonificacion', 2, v_s);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v, a, v_s);
    RETURN v;
  END $f$;

  -- Promo de fracción "10 V dan 4 R", contenedor c: 6 R = 1 contenedor.
  CREATE FUNCTION pg_temp.promo_fraccion(v_venta bigint, r bigint, c bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint; v_s bigint := current_setting('e1603b3.suc')::bigint;
  BEGIN
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                             ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque,
                             descripcion_regalo)
    VALUES ('ZZ ensayo B3 fraccion', 'bonificacion', public._tablero_hoy() - 1, v_s, false, r, true, c, 6, 1,
            '1 botella de ensayo')
    RETURNING id INTO v;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v, 'cantidad_compra', 10, v_s), (v, 'cantidad_bonificacion', 4, v_s);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v, v_venta, v_s);
    RETURN v;
  END $f$;

  -- ============================================================= M3-1 · M1 ===
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[]', 100);
  c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
  v_promo := pg_temp.promo_barra(a, s, c);
  v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
  v_x := pg_temp.alta(v_cli, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('M1 la venta', c, 'stock=49 lotes=[49] bolsa=0')
                       || pg_temp.verb('M1 la venta', v_promo, 'L1:1');
  PERFORM pg_temp.bolsa(c, 10);
  v_nuevo := pg_temp.cambio(v_x, v_cli2, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('M1 cambio de cliente', c, 'stock=59 lotes=[49] bolsa=10')
                       || pg_temp.verb('M1 cambio de cliente', v_promo, 'L1:1');
  PERFORM pg_temp.cancelar(v_nuevo, v_adm);
  v_fallas := v_fallas || pg_temp.ver('M1 cancelar el nuevo', c, 'stock=60 lotes=[50] bolsa=10');

  -- ============================================================= M3-1 · M2 ===
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[]', 100);
  c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
  v_promo := pg_temp.promo_barra(a, s, c);
  v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.it(c, 5), pg_temp.reg(s, 2, v_promo));
  v_x := pg_temp.alta(v_cli, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('M2 la venta', c, 'stock=44 lotes=[44] bolsa=0');
  PERFORM pg_temp.bolsa(c, 10);
  v_nuevo := pg_temp.cambio(v_x, v_cli2, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('M2 cambio de cliente', c, 'stock=54 lotes=[44] bolsa=10')
                       || pg_temp.verh('M2 pedido nuevo', v_nuevo, c, 'L1:5')
                       || pg_temp.verb('M2 cambio de cliente', v_promo, 'L1:1');

  -- ============================================================= M3-1 · M3 ===
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[]', 100);
  c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 5);
  v_promo := pg_temp.promo_barra(a, s, c);
  v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
  v_x := pg_temp.alta(v_cli, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('M3 la venta', c, 'stock=54 lotes=[50] bolsa=4')
                       || pg_temp.verb('M3 la venta', v_promo, 'bolsa:1');
  v_nuevo := pg_temp.cambio(v_x, v_cli2, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('M3 cambio de cliente', c, 'stock=54 lotes=[50] bolsa=4')
                       || pg_temp.verb('M3 cambio de cliente', v_promo, 'bolsa:1');

  -- ============================================================= M3-1 · M4 ===
  -- El orden de la anotación heredada (H2 de la revisión): un bloque de 2 fardos [bolsa:1 L1:1].
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[]', 100);
  c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 1);
  v_promo := pg_temp.promo_barra(a, s, c);
  v_items := jsonb_build_array(pg_temp.it(a, 20), pg_temp.reg(s, 4, v_promo));
  v_x := pg_temp.alta(v_cli, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('M4 la venta', c, 'stock=49 lotes=[49] bolsa=0')
                       || pg_temp.verb('M4 la venta', v_promo, 'bolsa:1 L1:1');
  PERFORM pg_temp.bolsa(c, 10);
  v_nuevo := pg_temp.cambio(v_x, v_cli2, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('M4 cambio de cliente', c, 'stock=59 lotes=[49] bolsa=10')
                       || pg_temp.verb('M4 cambio de cliente', v_promo, 'bolsa:1 L1:1');
  -- deshacer UN fardo con el motor (lo que hace una salvedad sobre la mitad del regalo): vuelve al
  -- lote, como sin el cambio de cliente.
  v_j := public.aplicar_uso_promo_acumulador(v_promo, s, -2, s, v_suc, v_adm, 'ensayo B3: deshacer un fardo');
  PERFORM pg_temp.limpiar();
  v_fallas := v_fallas || pg_temp.ver('M4 deshacer un fardo', c, 'stock=60 lotes=[50] bolsa=10');

  -- ========================================================== 1556-c1 · C1 ===
  a := pg_temp.prod('[]', 100);                                         -- V
  s := pg_temp.prod('[]', 100);                                         -- R
  c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":60}]', 40);  -- Cont
  v_promo := pg_temp.promo_fraccion(a, s, c);
  v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 4, v_promo));
  v_x := pg_temp.alta(v_cli, v_adm, v_items);
  v_j := public.cambiar_regalo_promocion(v_promo, s, NULL, false, '{"regalo_mueve_stock": true}'::jsonb);
  v_j := public.cambiar_regalo_promocion(v_promo, s, c, true, '{"regalo_mueve_stock": false}'::jsonb);
  PERFORM pg_temp.limpiar();
  v_t := pg_temp.alta(v_cli, v_adm, v_items);
  IF NOT COALESCE((SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = v_x AND promocion_id = v_promo), false)
     OR public._regalo_barra_vale(v_x, v_promo, v_suc)
     OR (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 4
     OR pg_temp.f(c) <> 'stock=100 lotes=[60] bolsa=40' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · C1 la premisa no se armó: marca %, barra %, %',
      (SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = v_x AND promocion_id = v_promo),
      (SELECT usos_pendientes FROM promociones WHERE id = v_promo), pg_temp.f(c);
  END IF;
  v_nuevo := pg_temp.cambio(v_x, v_cli2, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('C1 cambio de cliente del tramo anterior', c, 'stock=100 lotes=[60] bolsa=40');
  IF (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 4
     OR NOT COALESCE((SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = v_nuevo AND promocion_id = v_promo), false)
     OR public._regalo_barra_vale(v_nuevo, v_promo, v_suc) THEN
    v_fallas := v_fallas || format('C1 barra %s (esperada 4), marca del pedido nuevo %s (esperada true), entra en la barra viva %s',
      (SELECT usos_pendientes FROM promociones WHERE id = v_promo),
      (SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = v_nuevo AND promocion_id = v_promo),
      public._regalo_barra_vale(v_nuevo, v_promo, v_suc));
  END IF;

  -- ========================================================== 1556-c1 · C2 ===
  PERFORM pg_temp.cancelar(v_nuevo, v_adm);
  v_fallas := v_fallas || pg_temp.ver('C2 cancelar el pedido nuevo', c, 'stock=100 lotes=[60] bolsa=40');
  IF (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 4 THEN
    v_fallas := v_fallas || format('C2 la cancelación movió la barra: %s (esperada 4)',
      (SELECT usos_pendientes FROM promociones WHERE id = v_promo));
  END IF;

  -- ========================================================== 1556-c1 · C3 ===
  v_nuevo := pg_temp.cambio(v_t, v_cli2, v_adm, v_items);
  v_fallas := v_fallas || pg_temp.ver('C3 cambio de cliente del tramo nuevo', c, 'stock=100 lotes=[60] bolsa=40');
  IF (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 4
     OR COALESCE((SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = v_nuevo AND promocion_id = v_promo), true)
     OR NOT public._regalo_barra_vale(v_nuevo, v_promo, v_suc) THEN
    v_fallas := v_fallas || format('C3 barra %s (esperada 4), marca %s (esperada false)',
      (SELECT usos_pendientes FROM promociones WHERE id = v_promo),
      (SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = v_nuevo AND promocion_id = v_promo));
  END IF;

  -- ========================================================== 1558-b5 · B5 ===
  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 20);
  SELECT id INTO v_lote FROM producto_lotes WHERE producto_id = p;
  v_n := (SELECT count(*) FROM stock_historico WHERE producto_id = p);
  v_j := public.ajustar_lote(v_lote, 40);
  PERFORM pg_temp.limpiar();
  v_fallas := v_fallas || pg_temp.ver('B5 ajustar el lote', p, 'stock=70 lotes=[40] bolsa=30');
  IF NOT EXISTS (SELECT 1 FROM stock_historico
                  WHERE producto_id = p AND origen = 'ajuste_lote'
                    AND referencia_tipo = 'producto_lotes' AND referencia_id = v_lote
                    AND stock_anterior = 70 AND stock_nuevo = 70 AND usuario_id = v_adm) THEN
    v_fallas := v_fallas || format('B5 el ajuste no dejó su fila en el ledger: %s',
      (SELECT string_agg(format('%s %s->%s %s/%s', origen, stock_anterior, stock_nuevo, referencia_tipo, referencia_id), ' | ' ORDER BY id)
         FROM stock_historico WHERE producto_id = p));
  END IF;
  v_n := (SELECT count(*) FROM stock_historico WHERE producto_id = p);
  v_j := public.ajustar_lote(v_lote, 40);
  PERFORM pg_temp.limpiar();
  IF (SELECT count(*) FROM stock_historico WHERE producto_id = p) <> v_n THEN
    v_fallas := v_fallas || 'B5 un ajuste que no cambia nada dejó una fila';
  END IF;

  -- ========================================================== 1558-b6 · B6 ===
  -- a · el lote que no venció, sin motivo
  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 10);
  SELECT id INTO v_lote FROM producto_lotes WHERE producto_id = p;
  v_n := (SELECT count(*) FROM stock_historico WHERE producto_id = p);
  BEGIN
    v_j := public.dar_de_baja_lote(v_lote, 5, NULL);
    v_res := 'anduvo: ' || v_j::text;
  EXCEPTION WHEN OTHERS THEN
    v_res := SQLERRM;
  END;
  PERFORM pg_temp.limpiar();
  IF v_res NOT LIKE '%todavía no venció%motivo%' THEN
    v_fallas := v_fallas || format('B6a la baja de un lote que no venció, sin motivo, no se rechazó: %s', v_res);
  END IF;
  v_fallas := v_fallas || pg_temp.ver('B6a sin motivo', p, 'stock=60 lotes=[50] bolsa=10');
  -- b · con motivo
  BEGIN
    v_j := public.dar_de_baja_lote(v_lote, 5, '  Rotura en el depósito ');
    v_res := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_res := SQLERRM;
  END;
  PERFORM pg_temp.limpiar();
  IF v_res <> 'ok' THEN
    v_fallas := v_fallas || format('B6b la baja con motivo se rechazó: %s', v_res);
  ELSE
    v_fallas := v_fallas || pg_temp.ver('B6b con motivo', p, 'stock=55 lotes=[45] bolsa=10');
    IF NOT EXISTS (SELECT 1 FROM mermas_stock
                    WHERE id = (v_j->>'merma_id')::bigint AND cantidad = 5
                      AND motivo = 'decomiso'
                      AND public.merma_clasificacion(motivo) = 'perdida'
                      AND observaciones LIKE '%Rotura en el depósito')
       OR NOT EXISTS (SELECT 1 FROM stock_historico
                       WHERE producto_id = p AND stock_anterior = 60 AND stock_nuevo = 55
                         AND origen = 'lote_baja') THEN
      v_fallas := v_fallas || format('B6b la merma o el ledger no son los de una baja por otro motivo: %s / %s',
        (SELECT format('%s %s «%s»', motivo, cantidad, observaciones) FROM mermas_stock WHERE id = (v_j->>'merma_id')::bigint),
        (SELECT string_agg(format('%s %s->%s', origen, stock_anterior, stock_nuevo), ' | ' ORDER BY id)
           FROM stock_historico WHERE producto_id = p));
    END IF;
  END IF;
  -- c · un lote que vence hoy todavía no venció
  p := pg_temp.prod('[{"dias":0,"cantidad":100,"restante":50}]', 0);
  SELECT id INTO v_lote FROM producto_lotes WHERE producto_id = p;
  BEGIN
    v_j := public.dar_de_baja_lote(v_lote, 5, '');
    v_res := 'anduvo';
  EXCEPTION WHEN OTHERS THEN
    v_res := SQLERRM;
  END;
  PERFORM pg_temp.limpiar();
  IF v_res NOT LIKE '%todavía no venció%' THEN
    v_fallas := v_fallas || format('B6c la baja de un lote que vence hoy, sin motivo, no se rechazó: %s', v_res);
  END IF;
  v_fallas := v_fallas || pg_temp.ver('B6c vence hoy', p, 'stock=50 lotes=[50] bolsa=0');
  -- d · regresión: el lote vencido, sin motivo
  p := pg_temp.prod('[{"dias":-3,"cantidad":100,"restante":20}]', 10);
  SELECT id INTO v_lote FROM producto_lotes WHERE producto_id = p;
  BEGIN
    v_j := public.dar_de_baja_lote(v_lote, 5, NULL);
    v_res := 'ok';
  EXCEPTION WHEN OTHERS THEN
    v_res := SQLERRM;
  END;
  PERFORM pg_temp.limpiar();
  IF v_res <> 'ok' THEN
    v_fallas := v_fallas || format('B6d la baja de un lote vencido se rechazó: %s', v_res);
  ELSE
    v_fallas := v_fallas || pg_temp.ver('B6d vencido', p, 'stock=25 lotes=[15] bolsa=10');
    IF NOT EXISTS (SELECT 1 FROM mermas_stock
                    WHERE id = (v_j->>'merma_id')::bigint AND motivo = 'vencimiento'
                      AND observaciones LIKE 'Lote vencido el %')
       OR NOT EXISTS (SELECT 1 FROM stock_historico
                       WHERE producto_id = p AND stock_anterior = 30 AND stock_nuevo = 25
                         AND origen = 'lote_vencido') THEN
      v_fallas := v_fallas || 'B6d la baja del lote vencido ya no es una merma por vencimiento';
    END IF;
  END IF;

  -- ========================================================== 1558-b7 · B7 ===
  p := pg_temp.prod('[]', 20);
  BEGIN
    v_j := public.aplicar_control_stock(
      jsonb_build_array(jsonb_build_object('producto_id', p, 'stock_real', 5, 'stock_planilla', -3)),
      'ensayo B3', gen_random_uuid());
    v_res := 'anduvo: ' || v_j::text;
  EXCEPTION WHEN OTHERS THEN
    v_res := SQLERRM;
  END;
  PERFORM pg_temp.limpiar();
  IF v_res NOT LIKE '%mayor o igual a 0%' THEN
    v_fallas := v_fallas || format('B7 un stock de planilla negativo no se rechazó: %s', v_res);
  END IF;
  v_fallas := v_fallas || pg_temp.ver('B7 planilla negativa', p, 'stock=20 lotes=[] bolsa=20');

  -- ========================================================== 1594-b1 · P1 ===
  SET LOCAL ROLE authenticated;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
  VALUES ('ZZ ensayo B3 alta REST', 100, 12, v_suc, 'ZZ ensayo B3 cat') RETURNING id INTO p;
  INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria)
  VALUES ('ZZ ensayo B3 alta REST sin stock', 100, 0, v_suc, 'ZZ ensayo B3 cat') RETURNING id INTO v_n;
  RESET ROLE;
  IF NOT EXISTS (SELECT 1 FROM stock_historico
                  WHERE producto_id = p AND stock_anterior = 0 AND stock_nuevo = 12
                    AND origen = 'alta_producto' AND usuario_id = v_adm) THEN
    v_fallas := v_fallas || format('P1 el alta con stock no dejó 0 -> 12 en el ledger: %s',
      COALESCE((SELECT string_agg(format('%s %s->%s', origen, stock_anterior, stock_nuevo), ' | ' ORDER BY id)
                  FROM stock_historico WHERE producto_id = p), 'ninguna fila'));
  END IF;
  v_fallas := v_fallas || pg_temp.cierra('P1', p);
  IF EXISTS (SELECT 1 FROM stock_historico WHERE producto_id = v_n) THEN
    v_fallas := v_fallas || 'P1 el alta sin stock dejó una fila';
  END IF;

  -- ------------------------------------------------------------------- A1 ---
  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_checks
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x;
  FOR k IN SELECT jsonb_object_keys(v_antes) LOOP
    IF COALESCE((v_checks->>k)::bigint, 0) > COALESCE((v_antes->>k)::bigint, 0) THEN
      v_fallas := v_fallas || format('A1 %s: %s violaciones (antes %s)', k, v_checks->>k, v_antes->>k);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · M1–M4, C1–C3, B5, B6a–B6d, B7, P1 y A1';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
END
$ensayo$;
