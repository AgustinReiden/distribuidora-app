-- Ensayo de la migración de la ola 2 del plan #1603, tarjeta B19 (H1 de la revisión de B3, y en
-- la v2 H1 a H5 de la revisión de B19): migrations/527_edicion_mueve_solo_la_diferencia_de_la_barra.sql
-- (aplicada en producción el 17/11; adentro sigue diciendo NNN, como se aplicó).
--
-- La edición de un pedido (`actualizar_pedido_items`) deshacía la barra de regalos entera con
-- `aplicar_uso_promo_acumulador(-c)` —que devuelve el fardo al lote que nombra el bloque— y la
-- volvía a cerrar con `+c`, cuya bajada come primero la bolsa: una edición sin cambios pasaba un
-- fardo del contenedor de la bolsa al lote (en los papeles). Con la migración la barra mueve sólo
-- la diferencia por promo y producto (lo que baja primero), y una edición que no cambia el regalo
-- no toca la barra, los bloques ni el contenedor.
--
-- Corre contra una base con el schema de prod SIN dejar rastro (salvo valores de secuencia): un
-- único DO que termina SIEMPRE en una excepción. Cada caso usa sus propios productos y promos.
-- Notación: 'stock=… lotes=[restante por vencimiento] bolsa=…'; un bloque vivo se muestra por de
-- dónde salió su fardo ('L1' es el primer lote por vencimiento, 'bolsa' es {"lote_id": null}).
-- En cada paso se mira además el ledger del contenedor (la última fila es el stock y cada fila
-- arranca donde terminó la anterior) y que los lotes no sumen más que el stock.
--
-- Promo de barra: 2 regalos de S cada 10 de A; 1 fardo de C cada 2 regalos. Contenedor C con un
-- lote de 100 con 50 y bolsa 0: la venta saca el fardo del lote. Después la bolsa de C sube 10.
--   E1 · la edición sin cambios (el caso de la ficha): C queda stock=59 lotes=[49] bolsa=10, y la
--        pila de bloques de la promo, la barra y las mermas del contenedor quedan idénticas. Una
--        segunda edición, igual. Cancelar: stock=60 lotes=[50] bolsa=10.
--        Antes: lotes=[50] bolsa=9 y el bloque nuevo decía {"lote_id": null}.
--   E2 · la edición que agrega regalo (A×20 + S×4): cierra un bloque más, que sale de la bolsa
--        (stock=58 lotes=[49] bolsa=9), y el bloque de la venta sigue diciendo L1. Cancelar:
--        stock=60 lotes=[50] bolsa=10. Antes: [50] y 8.
--   E3 · la edición que saca regalo (de A×20 + S×4 a A×10 + S×2; los dos fardos del lote): abre un
--        solo bloque y su fardo vuelve al lote (stock=59 lotes=[49] bolsa=10). Antes: [50] y 9.
--        (Los dos fardos son una fila de la pila con dos bloques vivos: queda uno, L1:1.)
--   E4 · la edición que cambia el producto de venta por otro de la promo (A×10 → A2×10, el mismo
--        regalo): nada se mueve, stock=59 lotes=[49] bolsa=10. Antes: [50] y 9.
--   E5 · el bloque salió de un lote que después se agotó (lote 100/1): la edición deja
--        stock=10 lotes=[0] bolsa=10. Antes: [1] y 9.
--   E6 · el bloque salió de un lote que después venció: la edición deja stock=59 lotes=[49]
--        bolsa=10. Antes: [50] y 9.
--   E7 · edición y después salvedad sobre el regalo entero (pedido en camino): después de la
--        edición [49] y 10; la salvedad abre el bloque y el fardo vuelve al lote: stock=60
--        lotes=[50] bolsa=10.
--   E8 · edición después de un cambio de cliente (M3-1 de la 517): el cambio deja [49] y 10, y la
--        edición del pedido nuevo también, con el bloque en L1. Antes: [50] y 9. Cancelar el
--        nuevo: [50] y 10.
--   E9 · dos promos de fracción que comparten el contenedor C (P1: A→S, P2: B→T), el pedido
--        cierra un fardo de cada una (C con lote 100/50: [48]). La edición sin cambios deja
--        stock=58 lotes=[48] bolsa=10; la que saca lo de P2 abre sólo su bloque y su fardo vuelve
--        al lote: stock=59 lotes=[49] bolsa=10, la pila de P1 intacta. Cancelar: [50] y 10.
--        Antes: [50] y 8 tras la primera edición.
--   E10 · regresión: el fardo de la venta salió de la bolsa (C con lote 100/50 y bolsa 5): la
--        edición sin cambios deja stock=54 lotes=[50] bolsa=4 y el bloque en la bolsa.
--   E11 · regresión: la edición que agrega regalo sin stock en el contenedor se rechaza con
--        «Auto-ajuste: stock insuficiente» y el pedido y el contenedor quedan como estaban.
-- v2 (H1 a H5 de la revisión de B19):
--   H1 · el regalo pasa a otra barra que descuenta del MISMO contenedor; el fardo conserva su lote.
--     E12 · otro sabor (S×2 → S2×2; la barra de S2 descuenta de C): stock=59 lotes=[49] bolsa=10 y
--           el bloque de S2 en L1. Cancelar: [50] y 10. Antes: [50] y 9, el bloque en la bolsa.
--     E13 · otra promo (A×10 + S×2 de P1 → B×10 + T×2 de P2, las dos descuentan de C): [49] y 10,
--           el bloque de P2 en L1 y P1 sin bloques. Antes: [50] y 9.
--   H2 · la sustitución de un regalo de fracción.
--     S1 · por el mismo producto con más cantidad (S×2 → S×3, N = 2): mueve sólo la diferencia,
--          [49] y 10, el bloque intacto y la barra en 1. Antes: [50] y 9, el bloque en la bolsa.
--     S2 · por otro producto cuya barra descuenta de C (S×2 → S2×2): [49] y 10, el bloque nuevo
--          en L1. Antes: [50] y 9.
--   H5 · los casos que muestran el cambio.
--     E14 · N = 4 y el bloque lo cierra OTRO pedido (X e Y con S×2 cada uno): la edición sin
--           cambios de X no toca nada ([49] y 10, la pila igual). Antes: abría el bloque de Y.
--     E15 · la barra «pasada de N» (en 3 con N = 2): con el contenedor en 0, la edición sin cambios
--           entra y no mueve nada (antes: «Auto-ajuste: stock insuficiente»); con bolsa, tampoco
--           (el bloque atrasado lo cierra la próxima venta, como dice la 520; antes lo cerraba).
--     E16 · el contador de una promo que mueve stock, puesto en 0: la edición sin cambios lo deja
--           en 0 (antes lo subía a 2).
--     E17 · salvedad primero y edición después: salvedad de 2 de los 4 regalos (A×20 + S×4, dos
--           fardos de L1) y la edición sin cambios deja [49] y 10 con el bloque en L1. Antes: [50] y 9.
-- v3 · el reparto de un regalo entre sabores (`dividir_regalo_pedido`). A×20 + S×4: dos fardos de
--   L1 ([48] y bolsa 0, después la bolsa sube 10). La barra de S2 descuenta de C salvo en R2.
--     R1 · S×4 repartido en S×2 + S2×2: stock=58 lotes=[48] bolsa=10, los dos bloques vivos en L1.
--          Antes: [49] y 9, el bloque de S2 en la bolsa.
--     R2 · regresión: la barra de S2 descuenta de otro contenedor C2 (lote 100/50 y bolsa 10): el
--          fardo de S vuelve a su lote de C ([49] y 10) y el de S2 sale de la bolsa de C2 ([50] y 9),
--          como hoy.
--     R3 · reparto y después edición sin cambios: [48] y 10, la pila igual. Antes: [49] y 9.
--     R4 · reparto y después cancelar: todo vuelve a su lote, [50] y 10 (antes también, porque
--          la cancelación corregía la deriva; el paso del reparto sí fallaba).
--   A1 · ningún check de auditoria_integridad() suma violaciones.
--
-- Sin la migración tiene que FALLAR en E1–E9 (en E7, el paso de la edición), E12–E17, S1, S2,
-- R1, R3 y R4 (el paso del reparto) (E17 también derivaba: [50] y 9). E10, E11 y R2 son
-- regresión.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-barra-edicion-ola2-1603.sql

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_cli    bigint;
  v_cli2   bigint;
  a        bigint;
  a2       bigint;
  b        bigint;
  s        bigint;
  s2       bigint;
  t        bigint;
  c        bigint;
  v_y      bigint;
  v_promo  bigint;
  v_promo2 bigint;
  v_x      bigint;
  v_nuevo  bigint;
  v_items  jsonb;
  v_items2 jsonb;
  v_pila   text;
  v_pila2  text;
  v_j      jsonb;
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
  PERFORM set_config('e1603b19.suc', v_suc::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo B19', 'ZZ ensayo B19', 'calle 1', v_suc) RETURNING id INTO v_cli;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo B19 b', 'ZZ ensayo B19 b', 'calle 2', v_suc) RETURNING id INTO v_cli2;

  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_antes
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x;

  -- ---------------------------------------------------------------- helpers -
  -- Un producto con lotes [{dias, cantidad, restante}] y p_bolsa unidades sin lote.
  CREATE FUNCTION pg_temp.prod(p_lotes jsonb, p_bolsa int) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_prod bigint; l jsonb; v_s bigint := current_setting('e1603b19.suc')::bigint;
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva,
                           sucursal_id, categoria)
    VALUES ('ZZ ensayo B19 ' || gen_random_uuid(), 100,
            p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
            60, 60, 60, 60, v_s, 'ZZ ensayo B19 cat') RETURNING id INTO v_prod;
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

  -- El lote por su orden de vencimiento ('L1', 'L2'), o 'bolsa'.
  CREATE FUNCTION pg_temp.lote_n(p_lote bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT CASE WHEN p_lote IS NULL THEN 'bolsa' ELSE
      'L' || (SELECT count(*) FROM producto_lotes l2 JOIN producto_lotes l ON l.id = p_lote
               WHERE l2.producto_id = l.producto_id
                 AND (l2.fecha_vencimiento, l2.id) <= (l.fecha_vencimiento, l.id)) END;
  $f$;

  -- Los bloques vivos de una promo, en orden: de dónde salió el fardo de cada uno.
  CREATE FUNCTION pg_temp.vivos(p_promo bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(
             COALESCE((SELECT string_agg(pg_temp.lote_n((e->>'lote_id')::bigint) || ':' || (e->>'cantidad'), ' ' ORDER BY o)
                         FROM jsonb_array_elements(pa.lotes_pendientes) WITH ORDINALITY AS x(e, o)), '-'),
             ' | ' ORDER BY pa.id), '-')
      FROM promo_ajustes pa WHERE pa.promocion_id = p_promo AND pa.bloques_vivos > 0;
  $f$;

  -- La pila entera de una promo (cada fila), su barra y sus mermas: lo que una edición sin
  -- cambios no tiene que tocar. (El ledger del contenedor lo mira pg_temp.ver.)
  CREATE FUNCTION pg_temp.pila(p_promo bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE((SELECT string_agg(format('%s:%s:%s:%s', pa.id, pa.unidades_ajustadas,
                                              COALESCE(pa.bloques_vivos::text, '-'),
                                              COALESCE(pa.lotes_pendientes::text, '-')), ' | ' ORDER BY pa.id)
                       FROM promo_ajustes pa WHERE pa.promocion_id = p_promo), '-')
        || ' barra=' || COALESCE((SELECT usos_pendientes::text FROM promociones WHERE id = p_promo), '?')
        || ' mermas=' || (SELECT count(*) FROM mermas_stock m
                           WHERE m.id IN (SELECT pa.merma_id FROM promo_ajustes pa WHERE pa.promocion_id = p_promo));
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
  CREATE FUNCTION pg_temp.verv(p_caso text, p_promo bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.vivos(p_promo) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: los bloques vivos dicen %s (esperado %s)', p_caso, pg_temp.vivos(p_promo), p_espera)] END;
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
    v := public.crear_pedido_completo(p_cli, v_tot, p_adm, p_items, 'ensayo B19');
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'alta: %', v; END IF;
    RETURN (v->>'pedido_id')::bigint;
  END $f$;

  -- La edición; devuelve 'ok' o el rechazo.
  CREATE FUNCTION pg_temp.editar(p_ped bigint, p_adm uuid, p_items jsonb) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    v := public.actualizar_pedido_items(p_ped, p_items, p_adm, NULL, NULL);
    PERFORM pg_temp.limpiar();
    IF COALESCE((v->>'success')::boolean, false) THEN RETURN 'ok'; END IF;
    RETURN v::text;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.limpiar();
    RETURN SQLERRM;
  END $f$;

  CREATE FUNCTION pg_temp.cambio(p_ped bigint, p_cli bigint, p_adm uuid, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb; v_tot numeric;
  BEGIN
    SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
      FROM jsonb_array_elements(p_items) e;
    v := public.cambiar_cliente_pedido(p_ped, p_cli, p_adm, p_items, v_tot);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'cambio: %', v; END IF;
    RETURN (v->>'nuevo_pedido_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.cancelar(p_ped bigint, p_adm uuid) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    v := public.cancelar_pedido_con_stock(p_ped, 'ensayo B19', p_adm, NULL);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'cancelar: %', v; END IF;
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
  DECLARE v bigint; v_s bigint := current_setting('e1603b19.suc')::bigint;
  BEGIN
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                             ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque)
    VALUES ('ZZ ensayo B19 barra', 'bonificacion', public._tablero_hoy() - 1, v_s, false, s, true, c, 2, 1)
    RETURNING id INTO v;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v, 'cantidad_compra', 10, v_s), (v, 'cantidad_bonificacion', 2, v_s);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v, a, v_s);
    RETURN v;
  END $f$;

  -- ==================================================================== E1 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E1 la venta', c, 'stock=49 lotes=[49] bolsa=0')
                         || pg_temp.verv('E1 la venta', v_promo, 'L1:1');
    PERFORM pg_temp.bolsa(c, 10);
    v_pila := pg_temp.pila(v_promo);
    v_pila2 := (SELECT count(*)::text FROM stock_historico WHERE producto_id = c);
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E1 la edición se rechazó: %s', v_res);
    END IF;
    IF (SELECT count(*)::text FROM stock_historico WHERE producto_id = c) <> v_pila2 THEN
      v_fallas := v_fallas || 'E1 la edición sin cambios dejó filas en el ledger del contenedor'::text;
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E1 edición sin cambios', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E1 edición sin cambios', v_promo, 'L1:1');
    IF pg_temp.pila(v_promo) <> v_pila THEN
      v_fallas := v_fallas || format('E1 la edición sin cambios tocó la pila: %s (antes %s)', pg_temp.pila(v_promo), v_pila);
    END IF;
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E1 segunda edición', c, 'stock=59 lotes=[49] bolsa=10');
    IF pg_temp.pila(v_promo) <> v_pila THEN
      v_fallas := v_fallas || format('E1 la segunda edición tocó la pila: %s (antes %s)', pg_temp.pila(v_promo), v_pila);
    END IF;
    PERFORM pg_temp.cancelar(v_x, v_adm);
    v_fallas := v_fallas || pg_temp.ver('E1 cancelar', c, 'stock=60 lotes=[50] bolsa=10');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E1 error: %s', SQLERRM);
  END;

  -- ==================================================================== E2 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.editar(v_x, v_adm, jsonb_build_array(pg_temp.it(a, 20), pg_temp.reg(s, 4, v_promo)));
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E2 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E2 edición que agrega regalo', c, 'stock=58 lotes=[49] bolsa=9')
                         || pg_temp.verv('E2 edición que agrega regalo', v_promo, 'L1:1 | bolsa:1');
    PERFORM pg_temp.cancelar(v_x, v_adm);
    v_fallas := v_fallas || pg_temp.ver('E2 cancelar', c, 'stock=60 lotes=[50] bolsa=10');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E2 error: %s', SQLERRM);
  END;

  -- ==================================================================== E3 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 20), pg_temp.reg(s, 4, v_promo)));
    v_fallas := v_fallas || pg_temp.ver('E3 la venta', c, 'stock=48 lotes=[48] bolsa=0');
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.editar(v_x, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E3 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E3 edición que saca regalo', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E3 edición que saca regalo', v_promo, 'L1:1');
    PERFORM pg_temp.cancelar(v_x, v_adm);
    v_fallas := v_fallas || pg_temp.ver('E3 cancelar', c, 'stock=60 lotes=[50] bolsa=10');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E3 error: %s', SQLERRM);
  END;

  -- ==================================================================== E4 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    a2 := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, a2, v_suc);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    PERFORM pg_temp.bolsa(c, 10);
    v_pila := pg_temp.pila(v_promo);
    v_res := pg_temp.editar(v_x, v_adm, jsonb_build_array(pg_temp.it(a2, 10), pg_temp.reg(s, 2, v_promo)));
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E4 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E4 cambia el producto de venta', c, 'stock=59 lotes=[49] bolsa=10');
    IF pg_temp.pila(v_promo) <> v_pila THEN
      v_fallas := v_fallas || format('E4 la edición tocó la pila: %s (antes %s)', pg_temp.pila(v_promo), v_pila);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E4 error: %s', SQLERRM);
  END;

  -- ==================================================================== E5 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":1}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E5 la venta', c, 'stock=0 lotes=[0] bolsa=0');
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E5 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E5 lote agotado', c, 'stock=10 lotes=[0] bolsa=10')
                         || pg_temp.verv('E5 lote agotado', v_promo, 'L1:1');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E5 error: %s', SQLERRM);
  END;

  -- ==================================================================== E6 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    UPDATE producto_lotes SET fecha_vencimiento = public._tablero_hoy() - 1 WHERE producto_id = c;
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E6 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E6 lote vencido', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E6 lote vencido', v_promo, 'L1:1');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E6 error: %s', SQLERRM);
  END;

  -- ==================================================================== E7 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E7 edición', c, 'stock=59 lotes=[49] bolsa=10');
    UPDATE pedidos SET estado = 'asignado' WHERE id = v_x;
    v_j := public.registrar_salvedad(v_x,
             (SELECT id FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion),
             2, 'cliente_rechaza', 'ensayo B19', NULL, true, NULL);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('E7 la salvedad se rechazó: %s', v_j);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E7 salvedad sobre el regalo', c, 'stock=60 lotes=[50] bolsa=10')
                         || pg_temp.verv('E7 salvedad sobre el regalo', v_promo, '-');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E7 error: %s', SQLERRM);
  END;

  -- ==================================================================== E8 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    PERFORM pg_temp.bolsa(c, 10);
    v_nuevo := pg_temp.cambio(v_x, v_cli2, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E8 cambio de cliente', c, 'stock=59 lotes=[49] bolsa=10');
    v_res := pg_temp.editar(v_nuevo, v_adm, v_items);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E8 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E8 edición del pedido nuevo', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E8 edición del pedido nuevo', v_promo, 'L1:1');
    PERFORM pg_temp.cancelar(v_nuevo, v_adm);
    v_fallas := v_fallas || pg_temp.ver('E8 cancelar el nuevo', c, 'stock=60 lotes=[50] bolsa=10');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E8 error: %s', SQLERRM);
  END;

  -- ==================================================================== E9 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    b := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    t := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_promo2 := pg_temp.promo_barra(b, t, c);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.it(b, 10),
                                 pg_temp.reg(s, 2, v_promo), pg_temp.reg(t, 2, v_promo2));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E9 la venta', c, 'stock=48 lotes=[48] bolsa=0');
    PERFORM pg_temp.bolsa(c, 10);
    v_pila := pg_temp.pila(v_promo);
    v_pila2 := pg_temp.pila(v_promo2);
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E9 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E9 edición sin cambios', c, 'stock=58 lotes=[48] bolsa=10');
    IF pg_temp.pila(v_promo) <> v_pila OR pg_temp.pila(v_promo2) <> v_pila2 THEN
      v_fallas := v_fallas || format('E9 la edición sin cambios tocó la pila: %s / %s',
                                     pg_temp.pila(v_promo), pg_temp.pila(v_promo2));
    END IF;
    v_res := pg_temp.editar(v_x, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E9 la edición que saca P2 se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E9 edición que saca P2', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E9 edición que saca P2 (P1)', v_promo, 'L1:1')
                         || pg_temp.verv('E9 edición que saca P2 (P2)', v_promo2, '-');
    IF pg_temp.pila(v_promo) <> v_pila THEN
      v_fallas := v_fallas || format('E9 sacar P2 tocó la pila de P1: %s (antes %s)', pg_temp.pila(v_promo), v_pila);
    END IF;
    PERFORM pg_temp.cancelar(v_x, v_adm);
    v_fallas := v_fallas || pg_temp.ver('E9 cancelar', c, 'stock=60 lotes=[50] bolsa=10');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E9 error: %s', SQLERRM);
  END;

  -- =================================================================== E10 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 5);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E10 la venta', c, 'stock=54 lotes=[50] bolsa=4');
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E10 edición sin cambios', c, 'stock=54 lotes=[50] bolsa=4')
                         || pg_temp.verv('E10 edición sin cambios', v_promo, 'bolsa:1');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E10 error: %s', SQLERRM);
  END;

  -- =================================================================== E11 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":1}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    v_pila := pg_temp.pila(v_promo);
    v_res := pg_temp.editar(v_x, v_adm, jsonb_build_array(pg_temp.it(a, 20), pg_temp.reg(s, 4, v_promo)));
    IF v_res NOT LIKE '%Auto-ajuste: stock insuficiente%' THEN
      v_fallas := v_fallas || format('E11 la edición sin stock en el contenedor no se rechazó como antes: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E11 rechazada', c, 'stock=0 lotes=[0] bolsa=0');
    IF pg_temp.pila(v_promo) <> v_pila
       OR (SELECT sum(cantidad) FROM pedido_items WHERE pedido_id = v_x) <> 12 THEN
      v_fallas := v_fallas || 'E11 la edición rechazada dejó algo escrito'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E11 error: %s', SQLERRM);
  END;

  -- La sustitución del regalo de un pedido; devuelve 'ok' o el rechazo.
  CREATE FUNCTION pg_temp.sustituir(p_ped bigint, p_prod bigint, p_cant int, p_ajuste bigint) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    v := public.sustituir_regalo_pedido((SELECT id FROM pedido_items WHERE pedido_id = p_ped AND es_bonificacion),
                                        p_prod, p_cant, 'ensayo B19', p_ajuste, NULL);
    PERFORM pg_temp.limpiar();
    IF COALESCE((v->>'success')::boolean, false) THEN RETURN 'ok'; END IF;
    RETURN v::text;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.limpiar();
    RETURN SQLERRM;
  END $f$;

  -- =================================================================== E12 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    s2 := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    INSERT INTO promo_acumuladores (promocion_id, producto_regalo_id, ajuste_producto_id, usos_pendientes, sucursal_id)
    VALUES (v_promo, s2, c, 0, v_suc);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.editar(v_x, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s2, 2, v_promo)));
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E12 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E12 otro sabor, mismo contenedor', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E12 otro sabor, mismo contenedor', v_promo, 'L1:1');
    PERFORM pg_temp.cancelar(v_x, v_adm);
    v_fallas := v_fallas || pg_temp.ver('E12 cancelar', c, 'stock=60 lotes=[50] bolsa=10');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E12 error: %s', SQLERRM);
  END;

  -- =================================================================== E13 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    b := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    t := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_promo2 := pg_temp.promo_barra(b, t, c);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.editar(v_x, v_adm, jsonb_build_array(pg_temp.it(b, 10), pg_temp.reg(t, 2, v_promo2)));
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E13 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E13 otra promo, mismo contenedor', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E13 otra promo (P2)', v_promo2, 'L1:1')
                         || pg_temp.verv('E13 otra promo (P1)', v_promo, '-');
    PERFORM pg_temp.cancelar(v_x, v_adm);
    v_fallas := v_fallas || pg_temp.ver('E13 cancelar', c, 'stock=60 lotes=[50] bolsa=10');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E13 error: %s', SQLERRM);
  END;

  -- ==================================================================== S1 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.sustituir(v_x, s, 3, NULL);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('S1 la sustitución se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('S1 sustitución por el mismo producto', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('S1 sustitución por el mismo producto', v_promo, 'L1:1');
    IF (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 1 THEN
      v_fallas := v_fallas || format('S1 la barra quedó en %s (esperado 1)',
                                     (SELECT usos_pendientes FROM promociones WHERE id = v_promo));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('S1 error: %s', SQLERRM);
  END;

  -- ==================================================================== S2 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    s2 := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo)));
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.sustituir(v_x, s2, 2, c);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('S2 la sustitución se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('S2 sustitución con el mismo contenedor', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('S2 sustitución con el mismo contenedor', v_promo, 'L1:1');
    PERFORM pg_temp.cancelar(v_x, v_adm);
    v_fallas := v_fallas || pg_temp.ver('S2 cancelar', c, 'stock=60 lotes=[50] bolsa=10');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('S2 error: %s', SQLERRM);
  END;

  -- =================================================================== E14 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    UPDATE promociones SET unidades_por_bloque = 4 WHERE id = v_promo;
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    v_y := pg_temp.alta(v_cli2, v_adm, v_items);
    PERFORM pg_temp.bolsa(c, 10);
    v_pila := pg_temp.pila(v_promo);
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E14 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E14 el bloque es de otro pedido', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E14 el bloque es de otro pedido', v_promo, 'L1:1');
    IF pg_temp.pila(v_promo) <> v_pila THEN
      v_fallas := v_fallas || format('E14 la edición sin cambios tocó la pila: %s (antes %s)', pg_temp.pila(v_promo), v_pila);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E14 error: %s', SQLERRM);
  END;

  -- =================================================================== E15 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":1}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    -- La barra pasada de N: el estado que deja la 520 cuando el recierre de una baja no tiene stock.
    UPDATE promociones SET usos_pendientes = 3 WHERE id = v_promo;
    v_pila := pg_temp.pila(v_promo);
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E15 con el contenedor en 0 la edición sin cambios se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E15 pasada de N, contenedor en 0', c, 'stock=0 lotes=[0] bolsa=0');
    IF pg_temp.pila(v_promo) <> v_pila THEN
      v_fallas := v_fallas || format('E15 la edición sin cambios tocó la pila: %s (antes %s)', pg_temp.pila(v_promo), v_pila);
    END IF;
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    v_fallas := v_fallas || pg_temp.ver('E15 pasada de N, con bolsa', c, 'stock=10 lotes=[0] bolsa=10');
    IF pg_temp.pila(v_promo) <> v_pila THEN
      v_fallas := v_fallas || format('E15 con bolsa la edición sin cambios tocó la pila: %s (antes %s)', pg_temp.pila(v_promo), v_pila);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E15 error: %s', SQLERRM);
  END;

  -- =================================================================== E16 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
    VALUES ('ZZ ensayo B19 mueve stock', 'bonificacion', public._tablero_hoy() - 1, v_suc, true, s)
    RETURNING id INTO v_promo;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 2, v_suc);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, a, v_suc);
    v_items := jsonb_build_array(pg_temp.it(a, 10), pg_temp.reg(s, 2, v_promo));
    v_x := pg_temp.alta(v_cli, v_adm, v_items);
    UPDATE promociones SET usos_pendientes = 0 WHERE id = v_promo;
    v_res := pg_temp.editar(v_x, v_adm, v_items);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E16 la edición se rechazó: %s', v_res);
    END IF;
    IF (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 0 THEN
      v_fallas := v_fallas || format('E16 el contador quedó en %s (esperado 0)',
                                     (SELECT usos_pendientes FROM promociones WHERE id = v_promo));
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E16 el regalo que mueve stock', s, 'stock=98 lotes=[] bolsa=98');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E16 error: %s', SQLERRM);
  END;

  -- =================================================================== E17 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    v_promo := pg_temp.promo_barra(a, s, c);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 20), pg_temp.reg(s, 4, v_promo)));
    PERFORM pg_temp.bolsa(c, 10);
    UPDATE pedidos SET estado = 'asignado' WHERE id = v_x;
    v_j := public.registrar_salvedad(v_x,
             (SELECT id FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion),
             2, 'cliente_rechaza', 'ensayo B19', NULL, true, NULL);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('E17 la salvedad se rechazó: %s', v_j);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E17 salvedad', c, 'stock=59 lotes=[49] bolsa=10');
    v_res := pg_temp.editar(v_x, v_adm,
               (SELECT jsonb_agg(CASE WHEN es_bonificacion THEN pg_temp.reg(producto_id, cantidad, promocion_id)
                                      ELSE pg_temp.it(producto_id, cantidad) END ORDER BY id)
                  FROM pedido_items WHERE pedido_id = v_x));
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('E17 la edición se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('E17 edición después de la salvedad', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.verv('E17 edición después de la salvedad', v_promo, 'L1:1');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E17 error: %s', SQLERRM);
  END;

  -- El reparto del regalo de un pedido en dos sabores; devuelve 'ok' o el rechazo.
  CREATE FUNCTION pg_temp.repartir(p_ped bigint, p_s bigint, p_s2 bigint) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    v := public.dividir_regalo_pedido((SELECT id FROM pedido_items WHERE pedido_id = p_ped AND es_bonificacion),
           jsonb_build_array(jsonb_build_object('producto_id', p_s, 'cantidad', 2),
                             jsonb_build_object('producto_id', p_s2, 'cantidad', 2)),
           'ensayo B19', NULL);
    PERFORM pg_temp.limpiar();
    IF COALESCE((v->>'success')::boolean, false) THEN RETURN 'ok'; END IF;
    RETURN v::text;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.limpiar();
    RETURN SQLERRM;
  END $f$;

  -- ============================================================ R1 · R3 · R4 ===
  FOR k IN SELECT unnest(ARRAY['R1', 'R3', 'R4']) LOOP
    BEGIN
      a := pg_temp.prod('[]', 100);
      s := pg_temp.prod('[]', 100);
      s2 := pg_temp.prod('[]', 100);
      c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
      v_promo := pg_temp.promo_barra(a, s, c);
      INSERT INTO promo_acumuladores (promocion_id, producto_regalo_id, ajuste_producto_id, usos_pendientes, sucursal_id)
      VALUES (v_promo, s2, c, 0, v_suc);
      v_items := jsonb_build_array(pg_temp.it(a, 20), pg_temp.reg(s, 4, v_promo));
      v_x := pg_temp.alta(v_cli, v_adm, v_items);
      PERFORM pg_temp.bolsa(c, 10);
      v_res := pg_temp.repartir(v_x, s, s2);
      IF v_res <> 'ok' THEN
        v_fallas := v_fallas || format('%s el reparto se rechazó: %s', k, v_res);
      END IF;
      v_fallas := v_fallas || pg_temp.ver(k || ' reparto, mismo contenedor', c, 'stock=58 lotes=[48] bolsa=10')
                           || pg_temp.verv(k || ' reparto, mismo contenedor', v_promo, 'L1:1 | L1:1');
      IF k = 'R3' THEN
        v_pila := pg_temp.pila(v_promo);
        v_res := pg_temp.editar(v_x, v_adm, v_items);
        IF v_res <> 'ok' THEN
          v_fallas := v_fallas || format('R3 la edición se rechazó: %s', v_res);
        END IF;
        v_fallas := v_fallas || pg_temp.ver('R3 edición después del reparto', c, 'stock=58 lotes=[48] bolsa=10');
        IF pg_temp.pila(v_promo) <> v_pila THEN
          v_fallas := v_fallas || format('R3 la edición sin cambios tocó la pila: %s (antes %s)', pg_temp.pila(v_promo), v_pila);
        END IF;
      ELSIF k = 'R4' THEN
        PERFORM pg_temp.cancelar(v_x, v_adm);
        v_fallas := v_fallas || pg_temp.ver('R4 cancelar después del reparto', c, 'stock=60 lotes=[50] bolsa=10')
                             || pg_temp.verv('R4 cancelar después del reparto', v_promo, '-');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('%s error: %s', k, SQLERRM);
    END;
  END LOOP;

  -- ==================================================================== R2 ===
  BEGIN
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    s2 := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 0);
    t := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 10);
    v_promo := pg_temp.promo_barra(a, s, c);
    INSERT INTO promo_acumuladores (promocion_id, producto_regalo_id, ajuste_producto_id, usos_pendientes, sucursal_id)
    VALUES (v_promo, s2, t, 0, v_suc);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(a, 20), pg_temp.reg(s, 4, v_promo)));
    PERFORM pg_temp.bolsa(c, 10);
    v_res := pg_temp.repartir(v_x, s, s2);
    IF v_res <> 'ok' THEN
      v_fallas := v_fallas || format('R2 el reparto se rechazó: %s', v_res);
    END IF;
    v_fallas := v_fallas || pg_temp.ver('R2 reparto, contenedores distintos (C)', c, 'stock=59 lotes=[49] bolsa=10')
                         || pg_temp.ver('R2 reparto, contenedores distintos (C2)', t, 'stock=59 lotes=[50] bolsa=9')
                         || pg_temp.verv('R2 reparto, contenedores distintos', v_promo, 'L1:1 | bolsa:1');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('R2 error: %s', SQLERRM);
  END;

  -- ------------------------------------------------------------------- A1 ---
  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_checks
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x;
  FOR k IN SELECT jsonb_object_keys(v_checks) LOOP
    IF COALESCE((v_checks->>k)::bigint, 0) > COALESCE((v_antes->>k)::bigint, 0) THEN
      v_fallas := v_fallas || format('A1 %s: %s violaciones (antes %s)', k, v_checks->>k, v_antes->>k);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · E1–E17, S1, S2, R1–R4 y A1 (la edición, la sustitución y el reparto mueven sólo la diferencia de la barra, y el fardo que cambia de barra en el mismo contenedor conserva su lote)';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
END
$ensayo$;
