-- Ensayo de la tarjeta B22 de la ola 2 del plan #1603: la nota de crédito de venta mueve la mercadería
-- según su motivo (y anularla lo deshace), y el descuento comercial se carga por monto, sin unidades
-- (pedidos del dueño del 17 y 18/11). Migración: NNN_nc_venta_mercaderia_y_descuento_por_monto.
--
-- Un único DO con datos propios (una sucursal nueva, su vendedor, un cliente, productos con lotes y
-- boletas entregadas) que termina SIEMPRE en una excepción: no deja rastro (salvo valores de secuencia).
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Las notas se emiten por la RPC, como el admin
-- desde el front (authenticated, parado en la sucursal). Las boletas se arman a mano y la venta baja el
-- stock como el alta (origen 'pedido_creado' con la línea en app.stock_pedido_item_id): con la bolsa en
-- 0 el trigger consume FEFO y deja la huella de cada línea. La foto de un producto es
-- 'stock=… lotes=[restante por vencimiento] bolsa=…'; la huella de una línea, 'L<orden del lote>:<u>'.
--
--   R · REINGRESA (cliente_rechaza, error_pedido, error_entrega)
--     R1 A: L1 20, L2 20; venta A×10 (sale de L1), bolsa 5 aparte. Nota de rechazo A×4: vuelve a L1, no a
--        la bolsa (stock 39, lotes [14,20], bolsa 5), la huella de la línea baja a L1:6, la línea y la boleta
--        no cambian, el ledger dice 'nota_credito_venta' con la nota, y la anotación dice L1 4/4.
--     R2 anularla: vuelve a stock 35, lotes [10,20], bolsa 5, huella L1:10, ledger 'nota_credito_venta_anulada'.
--     R3 error_pedido A×2 y error_entrega A×1 también reingresan a L1.
--     R4 A2: la venta salió 5 de la bolsa y 1 de L1. Una nota de rechazo de las 6: 1 a L1 y 5 a la bolsa.
--        Anularla saca el 1 de L1 y 5 de la bolsa.
--   T · EL TOPE: con 3 ya acreditadas de 10, 8 se rechaza y 7 entra (L1 vuelve a 20, huella 0); una más se
--       rechaza; anular la de 7 la deja como antes. T3: el tope de la boleta (las notas vigentes más ésta no
--       pasan lo vendido) ve también una nota sin renglón de la boleta.
--   M · MERMA (producto_vencido, producto_danado): B: L1 20, venta B×10, bolsa 4. Vencido B×3: el stock y los
--       lotes no cambian (devolver y mermar en el mismo movimiento), una merma de 3 por vencimiento (stock
--       17 → 14), la huella baja a L1:7, el ledger dice +3 'nota_credito_venta_merma' y −3 'merma'. Dañado B×2:
--       merma por rotura. mermas_valorizadas las ve. Anular la de vencido anula su merma, no toca el stock y
--       repone la huella (L1:8).
--   N · NADA (descuento_comercial y otro, por unidades): el stock no se mueve y no hay anotación.
--   G · DOS LÍNEAS DEL MISMO PRODUCTO Y UN COMBO: K, L1 4 y L2 10; X = K×4 suelto (L1:4) e Y = K×3 de un
--       combo (L2:3). Una nota de rechazo de Y×2 vuelve a L2, no a L1; X no pierde huella. Anularla, al revés.
--       La barra de una promo con contenedor K no se mueve. Un regalo no se acredita.
--   L · EL LOTE DE ORIGEN: L1 borrado (compra cancelada): lo devuelto va a la bolsa (anotación vacía) y
--       anular lo saca de la bolsa. L1 vencido: vuelve igual a su lote (la huella no mira el vencimiento).
--       Lo reingresado se vendió después: anular se rechaza con el motivo; con stock, sale de la bolsa.
--   V · VALE BLANCO, CANJE Y PRODUCTO BORRADO: el vale blanco no admite nota y un canje no tiene qué
--       acreditar (su comanda no tiene líneas: ni unidades ni monto); una línea sin
--       producto no se acredita por unidades y el descuento sobre toda la boleta la saltea.
--   S · SALVEDAD ANTES: tras una salvedad de 3 sobre A×10, la nota de 8 se rechaza y la de 7 entra; con la
--       nota vigente, otra salvedad se rechaza.
--   D · EL DESCUENTO POR MONTO
--     D1 FC con G21 3×121, G105 2×110,50 y EX 1×100 (684): descuento de 100 sobre toda la boleta → 53,07 /
--        32,31 / 14,62 (cantidad 0), neto 87,72 e IVA 12,28 (neto + iva = total); el stock no se mueve.
--     D1b la comisión por clave baja exactamente cada parte (Σ 100); la posición fiscal resta neto e IVA;
--        el ingreso real de la venta (_ventas_nc) baja 87,72 (con cantidad 0 daba 0).
--     D2 avanzado: G105 50 y EX 20 (IVA 4,75 en G105). D3 EX 65,39 pasa lo que le queda (65,38). D4 514,01
--        pasa lo que le queda a la boleta (514). D5 al centavo: 0,01 va entero a la línea de más peso.
--     D6 unidades después del descuento: G21×1 acredita 103,31 y G21×2 lo que queda (206,61): la línea
--        suma 363. D7 lo que queda entero (204,07) entra, y después no queda nada.
--     D8 ZZ (sin IVA): 30 en dos líneas iguales → 15 / 15, neto 30 e IVA 0.
--     D9 un monto con otro motivo, mezclado con unidades, inválido, 0, NaN o dos montos sobre toda la
--        boleta se rechazan. D10 el reintento con la misma clave es la misma nota; con otro monto, 22023.
--     D11 anular un descuento no mueve stock y devuelve la comisión.
--   X · LO QUE DEJA CADA NOTA: una nota anulada no deja una merma viva ni unidades reingresadas en el stock
--       (su ledger suma 0), y una vigente deja exactamente las que reingresó.
--   (S2 es la regla en serie de la salvedad: con una nota vigente, la salvedad se rechaza. La carrera
--   —la nota en vuelo y la salvedad esperando la boleta— la prueba scripts/concurrencia/b22-nota-con-mercaderia.sh,
--   V3 y V3b.)
--   A · LA AUDITORÍA: STK-*, LOTE-*, MERMA-*, FISCAL-*, CC-*, VENTA-*, NC-A y PROMO-A no suman violaciones,
--       y el ledger de cada producto cierra.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-nc-stock-y-descuento-ola2-1603.sql

DO $ensayo$
DECLARE
  v_hoy     date := public._tablero_hoy();
  v_adm     uuid := '00000000-0000-0000-0000-0000000004e7';
  v_s       bigint;
  v_ven     uuid;
  v_c1      bigint;
  a         bigint;
  a2        bigint;
  b         bigint;
  n         bigint;
  k         bigint;
  rg        bigint;
  lb        bigint;
  lv        bigint;
  lz        bigint;
  sp        bigint;
  pd        bigint;
  tp        bigint;
  g21       bigint;
  g105      bigint;
  ex        bigint;
  z1        bigint;
  z2        bigint;
  v_promo   bigint;
  v_combo   bigint;
  v_p       bigint;
  v_p2      bigint;
  v_i       bigint;
  v_i2      bigint;
  v_lote    bigint;
  v_nc      bigint;
  v_nc2     bigint;
  v_nc3     bigint;
  v_r       jsonb;
  v_j       jsonb;
  v_t       text;
  v_n       numeric;
  v_m       numeric;
  v_rid     uuid;
  v_base    jsonb;
  v_antes   jsonb;
  v_fallas  text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';
  SET CONSTRAINTS ALL IMMEDIATE;

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b22-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'B22 ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  -- Corre p_sql como p_uid (authenticated, parado en p_suc) y devuelve su resultado; un error sale tal cual.
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE x text;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql INTO x;
    EXCEPTION WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      PERFORM set_config('request.headers', '', true);
      RAISE;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.headers', '', true);
    RETURN x;
  END $f$;
  CREATE FUNCTION pg_temp.igual(x numeric, y numeric) RETURNS boolean LANGUAGE sql AS $f$
    SELECT x IS NOT NULL AND y IS NOT NULL AND abs(x - y) < 0.005
  $f$;
  -- Un producto con lotes [{dias, cantidad, restante}] y p_bolsa unidades sin lote.
  CREATE FUNCTION pg_temp.prod(p_suc bigint, p_nombre text, p_precio numeric, p_lotes jsonb, p_bolsa int,
                               p_cond text DEFAULT 'gravado', p_iva numeric DEFAULT 21) RETURNS bigint
  LANGUAGE plpgsql AS $f$
  DECLARE v_prod bigint; l jsonb;
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva,
                           sucursal_id, categoria, condicion_iva, porcentaje_iva)
    VALUES ('B22 ' || p_nombre, p_precio,
            p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
            60, 60, 60, 60, p_suc, 'B22 cat', p_cond, CASE WHEN p_cond = 'gravado' THEN p_iva ELSE 0 END)
    RETURNING id INTO v_prod;
    FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
      VALUES (v_prod, p_suc, public._tablero_hoy() + (l->>'dias')::int,
              (l->>'cantidad')::int, (l->>'restante')::int, 'manual');
    END LOOP;
    RETURN v_prod;
  END $f$;
  CREATE FUNCTION pg_temp.limpiar() RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('app.stock_origen', '', true);
    PERFORM set_config('app.stock_ref_tipo', '', true);
    PERFORM set_config('app.stock_ref_id', '', true);
    PERFORM set_config('app.stock_user_id', '', true);
    PERFORM set_config('app.stock_pedido_item_id', '', true);
  END $f$;
  -- Una boleta entregada de hoy con sus líneas [{p, c, pr, n (neto u.), i (iva u.), combo, psc}], vendidas
  -- en orden como el alta: la bajada con la línea en el GUC deja su huella.
  CREATE FUNCTION pg_temp.bol(p_cli bigint, p_ven uuid, p_tipo text, p_lineas jsonb, p_canal text DEFAULT 'app')
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_id bigint; v_suc bigint; l jsonb; v_it bigint; v_tot numeric; v_neto numeric; v_iva numeric;
  BEGIN
    SELECT sucursal_id INTO v_suc FROM clientes WHERE id = p_cli;
    SELECT COALESCE(sum((x->>'c')::int * (x->>'pr')::numeric), 0),
           COALESCE(sum((x->>'c')::int * COALESCE((x->>'n')::numeric, (x->>'pr')::numeric)), 0),
           COALESCE(sum((x->>'c')::int * COALESCE((x->>'i')::numeric, 0)), 0)
      INTO v_tot, v_neto, v_iva
      FROM jsonb_array_elements(p_lineas) x;
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, total_neto, total_iva, estado, fecha,
                         fecha_entrega, canal, retiro_deposito, tipo_factura, monto_pagado, estado_pago)
      VALUES (p_cli, v_suc, p_ven, v_tot, v_neto, v_iva, 'entregado', public._tablero_hoy(),
              (public._tablero_hoy() + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', p_canal, true,
              p_tipo, CASE WHEN p_tipo = 'VB' THEN v_tot ELSE 0 END,
              CASE WHEN p_tipo = 'VB' THEN 'pagado' ELSE 'pendiente' END)
      RETURNING id INTO v_id;
    FOR l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
      INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,
                                costo_unitario_al_crear, neto_unitario, iva_unitario, es_bonificacion, promocion_id,
                                combo_id, precio_sin_combo_unitario, origen_precio)
        VALUES (v_id, (l->>'p')::bigint, (l->>'c')::int, (l->>'pr')::numeric,
                (l->>'c')::int * (l->>'pr')::numeric, v_suc, 60,
                COALESCE((l->>'n')::numeric, (l->>'pr')::numeric), COALESCE((l->>'i')::numeric, 0),
                COALESCE((l->>'regalo')::boolean, false), (l->>'promo')::bigint,
                (l->>'combo')::bigint, (l->>'psc')::numeric,
                CASE WHEN l ? 'combo' THEN 'combo' WHEN COALESCE((l->>'regalo')::boolean, false) THEN 'bonificacion'
                     ELSE 'lista' END)
        RETURNING id INTO v_it;
      IF NOT COALESCE((l->>'regalo')::boolean, false) THEN
        PERFORM set_config('app.stock_origen', 'pedido_creado', true);
        PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
        PERFORM set_config('app.stock_ref_id', v_id::text, true);
        PERFORM set_config('app.stock_pedido_item_id', v_it::text, true);
        UPDATE productos SET stock = stock - (l->>'c')::int WHERE id = (l->>'p')::bigint;
        PERFORM pg_temp.limpiar();
      END IF;
    END LOOP;
    RETURN v_id;
  END $f$;
  CREATE FUNCTION pg_temp.linea(p_ped bigint, p_n int DEFAULT 1) RETURNS bigint LANGUAGE sql AS $f$
    SELECT id FROM pedido_items WHERE pedido_id = p_ped ORDER BY id OFFSET p_n - 1 LIMIT 1
  $f$;
  -- La nota por la RPC, como el front (el admin parado en la sucursal de la boleta).
  CREATE FUNCTION pg_temp.nc(p_ped bigint, p_items jsonb, p_motivo text, p_rid uuid DEFAULT NULL) RETURNS jsonb
  LANGUAGE sql AS $f$
    SELECT pg_temp.como('00000000-0000-0000-0000-0000000004e7', (SELECT sucursal_id FROM pedidos WHERE id = p_ped), format(
      'SELECT public.crear_nota_credito_venta(%s, %s, %L::jsonb, %L, %L, %L::uuid)::text',
      p_ped, (SELECT cliente_id FROM pedidos WHERE id = p_ped), p_items, p_motivo, 'ensayo B22',
      COALESCE(p_rid, gen_random_uuid())))::jsonb;
  $f$;
  -- Lo mismo, y devuelve el error (o 'OK').
  CREATE FUNCTION pg_temp.nc_err(p_ped bigint, p_items jsonb, p_motivo text, p_rid uuid DEFAULT NULL) RETURNS text
  LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.nc(p_ped, p_items, p_motivo, p_rid);
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  CREATE FUNCTION pg_temp.u1(p_item bigint, p_cant int) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_array(jsonb_build_object('pedido_item_id', p_item, 'cantidad', p_cant))
  $f$;
  CREATE FUNCTION pg_temp.anular(p_nc bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como('00000000-0000-0000-0000-0000000004e7', (SELECT sucursal_id FROM notas_credito_venta WHERE id = p_nc), format(
      'SELECT public.anular_nota_credito_venta(%s, %L)::text', p_nc, 'ensayo B22'))::jsonb;
  $f$;
  CREATE FUNCTION pg_temp.anular_err(p_nc bigint) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.anular(p_nc);
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  CREATE FUNCTION pg_temp.f(p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('stock=%s lotes=[%s] bolsa=%s', p.stock,
      COALESCE((SELECT string_agg(cantidad_restante::text, ',' ORDER BY fecha_vencimiento, id)
                  FROM producto_lotes WHERE producto_id = p_prod), ''),
      p.stock - COALESCE((SELECT sum(cantidad_restante) FROM producto_lotes WHERE producto_id = p_prod), 0))
    FROM productos p WHERE p.id = p_prod;
  $f$;
  -- La huella de una línea: 'L<orden del lote>:<cant>'.
  CREATE FUNCTION pg_temp.hl(p_item bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(format('L%s:%s', x.n, x.c), ' ' ORDER BY x.n), '-')
      FROM (SELECT (SELECT count(*) FROM producto_lotes l2
                     WHERE l2.producto_id = l.producto_id
                       AND (l2.fecha_vencimiento, l2.id) <= (l.fecha_vencimiento, l.id)) AS n,
                   sum(pil.cantidad) AS c
              FROM pedido_item_lotes pil
              JOIN producto_lotes l ON l.id = pil.lote_id
             WHERE pil.pedido_item_id = p_item
             GROUP BY l.id, l.producto_id, l.fecha_vencimiento) x;
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
          FROM (SELECT id, stock_anterior, lag(stock_nuevo) OVER (ORDER BY id) AS prev
                  FROM stock_historico WHERE producto_id = p_prod) x
         WHERE x.prev IS NOT NULL AND x.prev <> x.stock_anterior
        UNION ALL
        SELECT 'los lotes suman más que el stock'
         WHERE (SELECT COALESCE(sum(cantidad_restante), 0) FROM producto_lotes WHERE producto_id = p_prod)
               > (SELECT stock FROM productos WHERE id = p_prod)
        UNION ALL
        SELECT format('la huella de la línea %s (%s) supera su cantidad (%s)', pi.id, h.s, pi.cantidad)
          FROM pedido_items pi
          JOIN (SELECT pedido_item_id, sum(cantidad) AS s FROM pedido_item_lotes GROUP BY 1) h
            ON h.pedido_item_id = pi.id
         WHERE pi.producto_id = p_prod AND h.s > pi.cantidad) z);
  $f$;
  CREATE FUNCTION pg_temp.ver(p_caso text, p_prod bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.f(p_prod) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: %s (esperado %s)', p_caso, pg_temp.f(p_prod), p_espera)] END
           || pg_temp.cierra(p_caso, p_prod);
  $f$;
  CREATE FUNCTION pg_temp.verh(p_caso text, p_item bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.hl(p_item) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: huella %s (esperada %s)', p_caso, pg_temp.hl(p_item), p_espera)] END;
  $f$;
  -- Suma unidades a la bolsa (origen fuera de la lista blanca).
  CREATE FUNCTION pg_temp.bolsa(p_prod bigint, p_n int) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('app.stock_origen', 'ajuste_manual', true);
    UPDATE productos SET stock = stock + p_n WHERE id = p_prod;
    PERFORM pg_temp.limpiar();
  END $f$;
  -- La última fila del ledger de un producto: 'origen ref_tipo ref_id diferencia'.
  CREATE FUNCTION pg_temp.ult(p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('%s %s %s %s', origen, referencia_tipo, referencia_id, diferencia)
      FROM stock_historico WHERE producto_id = p_prod ORDER BY id DESC LIMIT 1
  $f$;
  CREATE FUNCTION pg_temp.base(p_ped bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT COALESCE(jsonb_object_agg(x.clave, x.b), '{}'::jsonb)
      FROM (SELECT clave, sum(base) AS b FROM public._comision_lineas(ARRAY[p_ped]) GROUP BY clave) x
  $f$;
  CREATE FUNCTION pg_temp.auditoria() RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint)
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
     WHERE x->>'id' ~ '^(STK|LOTE|MERMA|FISCAL|CC|VENTA|NC|PROMO-A)'
  $f$;

  -- ------------------------------------------------------------------- datos -
  INSERT INTO sucursales (nombre) VALUES ('B22 ensayo ' || left(gen_random_uuid()::text, 8)) RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm, v_s) ON CONFLICT DO NOTHING;
  v_ven := pg_temp.u('preventista', v_s);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B22 uno', 'B22 uno', 'Calle 1', v_s) RETURNING id INTO v_c1;
  v_antes := pg_temp.auditoria();

  a   := pg_temp.prod(v_s, 'A',   100, '[{"dias":30,"cantidad":20,"restante":20},{"dias":60,"cantidad":20,"restante":20}]', 0);
  a2  := pg_temp.prod(v_s, 'A2',  100, '[{"dias":30,"cantidad":20,"restante":20},{"dias":60,"cantidad":20,"restante":20}]', 5);
  b   := pg_temp.prod(v_s, 'B',   100, '[{"dias":30,"cantidad":20,"restante":20}]', 0);
  n   := pg_temp.prod(v_s, 'N',   100, '[]', 50);
  k   := pg_temp.prod(v_s, 'K',   100, '[{"dias":30,"cantidad":4,"restante":4},{"dias":60,"cantidad":10,"restante":10}]', 0);
  rg  := pg_temp.prod(v_s, 'R',   50,  '[]', 50);
  lb  := pg_temp.prod(v_s, 'Lb',  100, '[{"dias":30,"cantidad":10,"restante":10}]', 0);
  lv  := pg_temp.prod(v_s, 'Lv',  100, '[{"dias":-5,"cantidad":10,"restante":10},{"dias":30,"cantidad":10,"restante":10}]', 0);
  lz  := pg_temp.prod(v_s, 'Lz',  100, '[{"dias":30,"cantidad":5,"restante":5}]', 0);
  sp  := pg_temp.prod(v_s, 'S',   100, '[]', 100);
  pd  := pg_temp.prod(v_s, 'Pd',  100, '[]', 100);
  tp  := pg_temp.prod(v_s, 'T',   100, '[]', 100);
  g21 := pg_temp.prod(v_s, 'G21', 121, '[]', 100, 'gravado', 21);
  g105 := pg_temp.prod(v_s, 'G105', 110.50, '[]', 100, 'gravado', 10.5);
  ex  := pg_temp.prod(v_s, 'EX',  100, '[]', 100, 'exento', 0);
  z1  := pg_temp.prod(v_s, 'Z1',  50,  '[]', 100);
  z2  := pg_temp.prod(v_s, 'Z2',  100, '[]', 100);

  -- ============================================================ R · reingresa
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', a, 'c', 10, 'pr', 100)));
  v_i := pg_temp.linea(v_p);
  v_fallas := v_fallas || pg_temp.ver('R0 la venta', a, 'stock=30 lotes=[10,20] bolsa=0') || pg_temp.verh('R0', v_i, 'L1:10');
  PERFORM pg_temp.bolsa(a, 5);
  v_r := pg_temp.nc(v_p, pg_temp.u1(v_i, 4), 'cliente_rechaza');
  v_nc := (v_r->>'nota_credito_id')::bigint;
  v_fallas := v_fallas || pg_temp.ver('R1 rechazo A×4 vuelve a L1', a, 'stock=39 lotes=[14,20] bolsa=5')
                       || pg_temp.verh('R1', v_i, 'L1:6');
  IF (SELECT cantidad FROM pedido_items WHERE id = v_i) <> 10 OR (SELECT total FROM pedidos WHERE id = v_p) <> 1000 THEN
    v_fallas := v_fallas || text 'R1 la nota no toca la línea ni el total de la boleta';
  END IF;
  IF pg_temp.ult(a) IS DISTINCT FROM format('nota_credito_venta nota_credito_venta %s 4', v_nc) THEN
    v_fallas := v_fallas || format('R1 el ledger dice %s', pg_temp.ult(a));
  END IF;
  IF (v_r->>'unidades_movidas')::int IS DISTINCT FROM 4 OR v_r->>'mercaderia' IS DISTINCT FROM 'reingresa' THEN
    v_fallas := v_fallas || format('R1 la respuesta: %s', v_r);
  END IF;
  SELECT lotes_devueltos INTO v_j FROM nota_credito_venta_items WHERE nota_credito_id = v_nc;
  IF jsonb_array_length(COALESCE(v_j, '[]')) <> 1 OR (v_j->0->>'cantidad')::int <> 4 OR (v_j->0->>'huella')::int <> 4 THEN
    v_fallas := v_fallas || format('R1 la anotación: %s', v_j);
  END IF;
  v_r := pg_temp.anular(v_nc);
  v_fallas := v_fallas || pg_temp.ver('R2 anular el rechazo', a, 'stock=35 lotes=[10,20] bolsa=5')
                       || pg_temp.verh('R2', v_i, 'L1:10');
  IF pg_temp.ult(a) IS DISTINCT FROM format('nota_credito_venta_anulada nota_credito_venta %s -4', v_nc)
     OR (v_r->>'unidades_revertidas')::int IS DISTINCT FROM 4 THEN
    v_fallas := v_fallas || format('R2 el ledger dice %s; la respuesta %s', pg_temp.ult(a), v_r);
  END IF;
  PERFORM pg_temp.nc(v_p, pg_temp.u1(v_i, 2), 'error_pedido');
  PERFORM pg_temp.nc(v_p, pg_temp.u1(v_i, 1), 'error_entrega');
  v_fallas := v_fallas || pg_temp.ver('R3 error de pedido y de entrega reingresan', a, 'stock=38 lotes=[13,20] bolsa=5')
                       || pg_temp.verh('R3', v_i, 'L1:7');

  -- ================================================================= T · tope
  v_t := pg_temp.nc_err(v_p, pg_temp.u1(v_i, 8), 'cliente_rechaza');
  IF v_t NOT LIKE '%ya se acreditaron 3%' THEN
    v_fallas := v_fallas || format('T1 8 de 7 que quedan: %s', v_t);
  END IF;
  v_r := pg_temp.nc(v_p, pg_temp.u1(v_i, 7), 'cliente_rechaza');
  v_nc := (v_r->>'nota_credito_id')::bigint;
  v_fallas := v_fallas || pg_temp.ver('T1 las 7 que quedan', a, 'stock=45 lotes=[20,20] bolsa=5')
                       || pg_temp.verh('T1', v_i, '-');
  v_t := pg_temp.nc_err(v_p, pg_temp.u1(v_i, 1), 'cliente_rechaza');
  IF v_t NOT LIKE '%ya se acreditaron 10%' THEN
    v_fallas := v_fallas || format('T1 una más: %s', v_t);
  END IF;
  PERFORM pg_temp.anular(v_nc);
  v_fallas := v_fallas || pg_temp.ver('T2 anular la de 7', a, 'stock=38 lotes=[13,20] bolsa=5')
                       || pg_temp.verh('T2', v_i, 'L1:7');

  -- R4 · la venta salió 5 de la bolsa y 1 de L1
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', a2, 'c', 6, 'pr', 100)));
  v_i := pg_temp.linea(v_p);
  PERFORM pg_temp.bolsa(a2, 3);
  v_fallas := v_fallas || pg_temp.ver('R4 la venta', a2, 'stock=42 lotes=[19,20] bolsa=3') || pg_temp.verh('R4', v_i, 'L1:1');
  v_nc := (pg_temp.nc(v_p, pg_temp.u1(v_i, 6), 'cliente_rechaza')->>'nota_credito_id')::bigint;
  v_fallas := v_fallas || pg_temp.ver('R4 1 a L1 y 5 a la bolsa', a2, 'stock=48 lotes=[20,20] bolsa=8')
                       || pg_temp.verh('R4', v_i, '-');
  PERFORM pg_temp.anular(v_nc);
  v_fallas := v_fallas || pg_temp.ver('R4 anular', a2, 'stock=42 lotes=[19,20] bolsa=3') || pg_temp.verh('R4 anular', v_i, 'L1:1');

  -- T3 · el tope de la boleta: una nota cargada por el server sin renglón de la boleta (150 sobre T×2 = 200)
  -- no la ve el tope por renglón; el de la boleta sí: una nota de T×1 (100) la pasaría.
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', tp, 'c', 2, 'pr', 100)));
  INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
    VALUES (v_s, v_c1, v_p, v_hoy, 'otro', 150, v_adm, 150, 0) RETURNING id INTO v_nc;
  INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                        precio_unitario, subtotal)
    VALUES (v_nc, v_s, NULL, tp, 1, 150, 150);
  INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, nota_credito_id)
    VALUES (v_c1, NULL, v_s, 150, 'nota_credito', v_hoy, v_adm, v_nc);
  v_t := pg_temp.nc_err(v_p, pg_temp.u1(pg_temp.linea(v_p), 1), 'otro');
  IF v_t NOT LIKE '%vendió 200.00%ya acreditan 150.00%(100.00) la pasaría%' THEN
    v_fallas := v_fallas || format('T3 el tope de la boleta: %s', v_t);
  END IF;
  v_t := pg_temp.nc_err(v_p, '[{"monto": 50.01}]', 'descuento_comercial');
  IF v_t NOT LIKE '%la pasaría%' THEN
    v_fallas := v_fallas || format('T3 el tope de la boleta por monto: %s', v_t);
  END IF;
  v_t := pg_temp.nc_err(v_p, '[{"monto": 50}]', 'descuento_comercial');
  IF v_t <> 'OK' THEN
    v_fallas := v_fallas || format('T3 hasta lo vendido sí: %s', v_t);
  END IF;

  -- ================================================================ M · merma
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', b, 'c', 10, 'pr', 100)));
  v_i := pg_temp.linea(v_p);
  PERFORM pg_temp.bolsa(b, 4);
  v_r := pg_temp.nc(v_p, pg_temp.u1(v_i, 3), 'producto_vencido');
  v_nc := (v_r->>'nota_credito_id')::bigint;
  v_fallas := v_fallas || pg_temp.ver('M1 vencido B×3 no mueve el stock', b, 'stock=14 lotes=[10] bolsa=4')
                       || pg_temp.verh('M1', v_i, 'L1:7');
  SELECT jsonb_build_object('motivo', m.motivo, 'cantidad', m.cantidad, 'antes', m.stock_anterior, 'despues', m.stock_nuevo,
                            'viva', m.anulada_at IS NULL, 'usuario', m.usuario_id IS NOT NULL)
    INTO v_j
    FROM nota_credito_venta_items i JOIN mermas_stock m ON m.id = i.merma_id
   WHERE i.nota_credito_id = v_nc;
  IF v_j IS DISTINCT FROM '{"motivo":"vencimiento","cantidad":3,"antes":17,"despues":14,"viva":true,"usuario":true}'::jsonb THEN
    v_fallas := v_fallas || format('M1 la merma: %s', v_j);
  END IF;
  IF (SELECT string_agg(origen || ' ' || diferencia, ', ' ORDER BY id) FROM stock_historico
       WHERE producto_id = b AND origen IN ('nota_credito_venta_merma', 'merma'))
     IS DISTINCT FROM 'nota_credito_venta_merma 3, merma -3' THEN
    v_fallas := v_fallas || text 'M1 el ledger de la merma';
  END IF;
  SELECT lotes_devueltos INTO v_j FROM nota_credito_venta_items WHERE nota_credito_id = v_nc;
  IF jsonb_array_length(COALESCE(v_j, '[]')) <> 1 OR (v_j->0->>'cantidad')::int <> 0 OR (v_j->0->>'huella')::int <> 3 THEN
    v_fallas := v_fallas || format('M1 la anotación: %s', v_j);
  END IF;
  v_nc2 := (pg_temp.nc(v_p, pg_temp.u1(v_i, 2), 'producto_danado')->>'nota_credito_id')::bigint;
  IF (SELECT m.motivo FROM nota_credito_venta_items i JOIN mermas_stock m ON m.id = i.merma_id
       WHERE i.nota_credito_id = v_nc2) IS DISTINCT FROM 'rotura' THEN
    v_fallas := v_fallas || text 'M1 dañado es merma por rotura';
  END IF;
  v_fallas := v_fallas || pg_temp.ver('M1 dañado', b, 'stock=14 lotes=[10] bolsa=4') || pg_temp.verh('M1 dañado', v_i, 'L1:5');
  IF (SELECT count(*) FROM public.mermas_valorizadas(v_hoy, v_hoy, ARRAY[v_s]) mv WHERE mv.producto_id = b) <> 2 THEN
    v_fallas := v_fallas || text 'M1 mermas_valorizadas ve las dos mermas';
  END IF;
  v_r := pg_temp.anular(v_nc);
  v_fallas := v_fallas || pg_temp.ver('M2 anular el vencido', b, 'stock=14 lotes=[10] bolsa=4')
                       || pg_temp.verh('M2', v_i, 'L1:8');
  IF (SELECT m.anulada_at IS NULL FROM nota_credito_venta_items i JOIN mermas_stock m ON m.id = i.merma_id
       WHERE i.nota_credito_id = v_nc) IS DISTINCT FROM false THEN
    v_fallas := v_fallas || text 'M2 anular la nota anula su merma';
  END IF;

  -- ================================================================= N · nada
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', n, 'c', 5, 'pr', 100)));
  v_i := pg_temp.linea(v_p);
  v_nc := (pg_temp.nc(v_p, pg_temp.u1(v_i, 1), 'descuento_comercial')->>'nota_credito_id')::bigint;
  v_nc2 := (pg_temp.nc(v_p, pg_temp.u1(v_i, 1), 'otro')->>'nota_credito_id')::bigint;
  v_fallas := v_fallas || pg_temp.ver('N1 descuento y otro no mueven nada', n, 'stock=45 lotes=[] bolsa=45');
  IF EXISTS (SELECT 1 FROM nota_credito_venta_items WHERE nota_credito_id IN (v_nc, v_nc2)
              AND (lotes_devueltos IS NOT NULL OR merma_id IS NOT NULL)) THEN
    v_fallas := v_fallas || text 'N1 sin anotación';
  END IF;

  -- ============================================ G · dos líneas, combo, barra
  INSERT INTO combos (sucursal_id, nombre, fecha_inicio, precio) VALUES (v_s, 'B22 combo', v_hoy - 1, 240)
    RETURNING id INTO v_combo;
  INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                           ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque)
    VALUES ('B22 barra', 'bonificacion', v_hoy - 1, v_s, false, rg, true, k, 2, 1) RETURNING id INTO v_promo;
  INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v_promo, 'cantidad_compra', 10, v_s), (v_promo, 'cantidad_bonificacion', 2, v_s);
  INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, n, v_s);
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(
           jsonb_build_object('p', k, 'c', 4, 'pr', 100),
           jsonb_build_object('p', k, 'c', 3, 'pr', 80, 'combo', v_combo, 'psc', 100)));
  INSERT INTO pedido_combos (pedido_id, combo_id, sucursal_id, cantidad_combos, nombre, precio, combina_escalas,
                             componentes, cantidad_combos_armados)
    VALUES (v_p, v_combo, v_s, 1, 'B22 combo', 240, false,
            jsonb_build_array(jsonb_build_object('productos', jsonb_build_array(k), 'cantidad', 3)), 1);
  v_i := pg_temp.linea(v_p, 1);
  v_i2 := pg_temp.linea(v_p, 2);
  PERFORM pg_temp.bolsa(k, 2);
  v_fallas := v_fallas || pg_temp.ver('G0 la venta', k, 'stock=9 lotes=[0,7] bolsa=2')
                       || pg_temp.verh('G0 X', v_i, 'L1:4') || pg_temp.verh('G0 Y', v_i2, 'L2:3');
  v_r := pg_temp.nc(v_p, pg_temp.u1(v_i2, 2), 'cliente_rechaza');
  v_nc := (v_r->>'nota_credito_id')::bigint;
  v_fallas := v_fallas || pg_temp.ver('G1 Y×2 vuelve a L2', k, 'stock=11 lotes=[0,9] bolsa=2')
                       || pg_temp.verh('G1 X', v_i, 'L1:4') || pg_temp.verh('G1 Y', v_i2, 'L2:1');
  IF NOT pg_temp.igual((v_r->>'total')::numeric, 160) THEN
    v_fallas := v_fallas || format('G1 el combo acredita su precio (160): %s', v_r->>'total');
  END IF;
  PERFORM pg_temp.anular(v_nc);
  v_fallas := v_fallas || pg_temp.ver('G2 anular', k, 'stock=9 lotes=[0,7] bolsa=2')
                       || pg_temp.verh('G2 X', v_i, 'L1:4') || pg_temp.verh('G2 Y', v_i2, 'L2:3');
  IF EXISTS (SELECT 1 FROM promo_ajustes WHERE promocion_id = v_promo)
     OR (SELECT usos_pendientes FROM promociones WHERE id = v_promo) IS DISTINCT FROM 0 THEN
    v_fallas := v_fallas || text 'G3 la barra con contenedor K no se mueve';
  END IF;
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(
           jsonb_build_object('p', n, 'c', 10, 'pr', 100),
           jsonb_build_object('p', rg, 'c', 2, 'pr', 0, 'regalo', true, 'promo', v_promo)));
  v_t := pg_temp.nc_err(v_p, pg_temp.u1(pg_temp.linea(v_p, 2), 1), 'cliente_rechaza');
  IF v_t NOT LIKE '%regalo%' THEN
    v_fallas := v_fallas || format('G4 un regalo no se acredita: %s', v_t);
  END IF;

  -- ===================================================== L · el lote de origen
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', lb, 'c', 4, 'pr', 100)));
  v_i := pg_temp.linea(v_p);
  DELETE FROM producto_lotes WHERE producto_id = lb;
  v_nc := (pg_temp.nc(v_p, pg_temp.u1(v_i, 3), 'cliente_rechaza')->>'nota_credito_id')::bigint;
  v_fallas := v_fallas || pg_temp.ver('L1 lote borrado: a la bolsa', lb, 'stock=9 lotes=[] bolsa=9');
  IF (SELECT lotes_devueltos FROM nota_credito_venta_items WHERE nota_credito_id = v_nc) IS DISTINCT FROM '[]'::jsonb THEN
    v_fallas := v_fallas || text 'L1 la anotación de lo que fue a la bolsa es []';
  END IF;
  PERFORM pg_temp.anular(v_nc);
  v_fallas := v_fallas || pg_temp.ver('L1 anular', lb, 'stock=6 lotes=[] bolsa=6');

  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', lv, 'c', 4, 'pr', 100)));
  v_i := pg_temp.linea(v_p);
  PERFORM pg_temp.bolsa(lv, 3);
  PERFORM pg_temp.nc(v_p, pg_temp.u1(v_i, 2), 'cliente_rechaza');
  v_fallas := v_fallas || pg_temp.ver('L2 el lote vencido recibe lo suyo', lv, 'stock=21 lotes=[8,10] bolsa=3')
                       || pg_temp.verh('L2', v_i, 'L1:2');

  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', lz, 'c', 5, 'pr', 100)));
  v_i := pg_temp.linea(v_p);
  v_nc := (pg_temp.nc(v_p, pg_temp.u1(v_i, 5), 'cliente_rechaza')->>'nota_credito_id')::bigint;
  v_fallas := v_fallas || pg_temp.ver('L3 vuelve al lote agotado', lz, 'stock=5 lotes=[5] bolsa=0');
  v_p2 := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', lz, 'c', 5, 'pr', 100)));
  v_t := pg_temp.anular_err(v_nc);
  IF v_t NOT LIKE '%reingresaron 5 u.%hoy hay 0 en stock%' THEN
    v_fallas := v_fallas || format('L3 lo reingresado se vendió: anular se rechaza con el motivo (%s)', v_t);
  END IF;
  PERFORM pg_temp.bolsa(lz, 5);
  v_t := pg_temp.anular_err(v_nc);
  v_fallas := v_fallas || CASE WHEN v_t = 'OK' THEN '{}'::text[] ELSE ARRAY['L3 con stock, anular: ' || v_t] END
                       || pg_temp.ver('L3 anular sale de la bolsa', lz, 'stock=0 lotes=[0] bolsa=0');

  -- ======================================= V · vale blanco, canje y producto borrado
  v_p := pg_temp.bol(v_c1, v_ven, 'VB', jsonb_build_array(jsonb_build_object('p', n, 'c', 1, 'pr', 100)));
  v_t := pg_temp.nc_err(v_p, pg_temp.u1(pg_temp.linea(v_p), 1), 'cliente_rechaza');
  IF v_t NOT LIKE '%vale blanco%' THEN
    v_fallas := v_fallas || format('V1 vale blanco: %s', v_t);
  END IF;
  -- La comanda de un canje no tiene líneas y su total es 0 (CAMBIO-01); se entrega aplicando el cambio
  -- (#1343): acá se le anota el cambio aplicado y se la entrega.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, transportista_id, tipo_factura)
    VALUES (v_c1, v_s, v_ven, 0, 'asignado', v_hoy, 'cambio', pg_temp.u('transportista', v_s), 'ZZ') RETURNING id INTO v_p;
  INSERT INTO recorrido_cambios (pedido_id, cliente_id, producto_devuelto_id, cantidad_devuelta, producto_entregado_id,
                                 cantidad_entregada, sucursal_id, aplicado_at)
    VALUES (v_p, v_c1, n, 1, n, 1, v_s, now());
  UPDATE pedidos SET estado = 'entregado', fecha_entrega = now() WHERE id = v_p;
  v_t := pg_temp.nc_err(v_p, '[{"monto": 10}]', 'descuento_comercial');
  IF v_t NOT LIKE '%No queda nada por acreditar%' THEN
    v_fallas := v_fallas || format('V2 canje por monto: %s', v_t);
  END IF;
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', pd, 'c', 2, 'pr', 100),
                                                          jsonb_build_object('p', n, 'c', 2, 'pr', 100)));
  UPDATE pedido_items SET producto_id = NULL WHERE id = pg_temp.linea(v_p, 1);
  v_t := pg_temp.nc_err(v_p, pg_temp.u1(pg_temp.linea(v_p, 1), 1), 'cliente_rechaza');
  IF v_t NOT LIKE '%ya no existe%' THEN
    v_fallas := v_fallas || format('V3 línea sin producto por unidades: %s', v_t);
  END IF;
  v_r := pg_temp.nc(v_p, '[{"monto": 50}]', 'descuento_comercial');
  IF (SELECT string_agg(pedido_item_id::text || ':' || subtotal, ',') FROM nota_credito_venta_items
       WHERE nota_credito_id = (v_r->>'nota_credito_id')::bigint) IS DISTINCT FROM pg_temp.linea(v_p, 2) || ':50.00' THEN
    v_fallas := v_fallas || text 'V3 el descuento sobre toda la boleta saltea la línea sin producto';
  END IF;

  -- ============================================================ S · salvedad
  v_p := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', sp, 'c', 10, 'pr', 100)));
  v_i := pg_temp.linea(v_p);
  v_r := pg_temp.como(v_adm, v_s, format(
           'SELECT public.registrar_salvedad(%s, %s, 3, %L, %L)::text', v_p, v_i, 'cliente_rechaza', 'ensayo B22'))::jsonb;
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('S0 la salvedad: %s', v_r);
  END IF;
  v_t := pg_temp.nc_err(v_p, pg_temp.u1(v_i, 8), 'cliente_rechaza');
  IF v_t NOT LIKE '%se entregaron 7%' THEN
    v_fallas := v_fallas || format('S1 tras la salvedad quedan 7: %s', v_t);
  END IF;
  v_t := pg_temp.nc_err(v_p, pg_temp.u1(v_i, 7), 'cliente_rechaza');
  v_fallas := v_fallas || CASE WHEN v_t = 'OK' THEN '{}'::text[] ELSE ARRAY['S1 las 7: ' || v_t] END
                       || pg_temp.ver('S1', sp, 'stock=100 lotes=[] bolsa=100');
  v_r := pg_temp.como(v_adm, v_s, format(
           'SELECT public.registrar_salvedad(%s, %s, 1, %L, %L)::text', v_p, v_i, 'cliente_rechaza', 'ensayo B22'))::jsonb;
  IF COALESCE((v_r->>'success')::boolean, true) THEN
    v_fallas := v_fallas || format('S2 con la nota vigente no hay salvedad: %s', v_r);
  END IF;

  -- ================================================ D · el descuento por monto
  v_p := pg_temp.bol(v_c1, v_ven, 'FC', jsonb_build_array(
           jsonb_build_object('p', g21, 'c', 3, 'pr', 121, 'n', 100, 'i', 21),
           jsonb_build_object('p', g105, 'c', 2, 'pr', 110.50, 'n', 100, 'i', 10.50),
           jsonb_build_object('p', ex, 'c', 1, 'pr', 100, 'n', 100, 'i', 0)));
  v_base := pg_temp.base(v_p);
  v_n := (SELECT COALESCE(sum(ingreso_real), 0) FROM public._ventas_nc(ARRAY[v_s], v_hoy, v_hoy) x WHERE x.pedido_id = v_p);
  v_r := pg_temp.nc(v_p, '[{"monto": 100}]', 'descuento_comercial');
  v_nc := (v_r->>'nota_credito_id')::bigint;
  IF (SELECT string_agg(format('%s:%s:%s', p.nombre, i.cantidad, i.subtotal), ' ' ORDER BY i.id)
        FROM nota_credito_venta_items i JOIN productos p ON p.id = i.producto_id WHERE i.nota_credito_id = v_nc)
     IS DISTINCT FROM 'B22 G21:0:53.07 B22 G105:0:32.31 B22 EX:0:14.62' THEN
    v_fallas := v_fallas || format('D1 el prorrateo de 100: %s', (SELECT string_agg(format('%s:%s:%s', p.nombre, i.cantidad, i.subtotal), ' ' ORDER BY i.id)
        FROM nota_credito_venta_items i JOIN productos p ON p.id = i.producto_id WHERE i.nota_credito_id = v_nc));
  END IF;
  IF (SELECT format('%s|%s|%s', total, neto, iva) FROM notas_credito_venta WHERE id = v_nc) IS DISTINCT FROM '100.00|87.72|12.28' THEN
    v_fallas := v_fallas || format('D1 la nota: %s', (SELECT format('%s|%s|%s', total, neto, iva) FROM notas_credito_venta WHERE id = v_nc));
  END IF;
  IF pg_temp.f(g21) <> 'stock=97 lotes=[] bolsa=97' OR pg_temp.f(ex) <> 'stock=99 lotes=[] bolsa=99' THEN
    v_fallas := v_fallas || text 'D1 el descuento no mueve stock';
  END IF;
  SELECT jsonb_object_agg(k2, round((v_base->>k2)::numeric - COALESCE((pg_temp.base(v_p)->>k2)::numeric, 0), 2))
    INTO v_j
    FROM jsonb_object_keys(v_base) k2;
  IF (SELECT sum(value::numeric) FROM jsonb_each_text(v_j)) IS DISTINCT FROM 100.00
     OR (v_j->>(g21::text || '|-|lista'))::numeric IS DISTINCT FROM 53.07
     OR (v_j->>(g105::text || '|-|lista'))::numeric IS DISTINCT FROM 32.31
     OR (v_j->>(ex::text || '|-|lista'))::numeric IS DISTINCT FROM 14.62 THEN
    v_fallas := v_fallas || format('D1b la comisión por clave baja cada parte y suma 100: %s', v_j);
  END IF;
  v_m := (SELECT COALESCE(sum(ingreso_real), 0) FROM public._ventas_nc(ARRAY[v_s], v_hoy, v_hoy) x WHERE x.pedido_id = v_p);
  IF NOT (abs(v_m - v_n - 87.72) < 0.01) THEN
    v_fallas := v_fallas || format('D1b el ingreso real de la nota (%s) es su neto (87.72)', v_m - v_n);
  END IF;
  -- Hasta acá, la única nota de una FC de la sucursal es ésta.
  v_r := pg_temp.como(v_adm, v_s, format('SELECT public.posicion_fiscal(%s, %L, %L)::text', v_s, v_hoy, v_hoy))::jsonb;
  IF NOT pg_temp.igual((v_r#>>'{ventas,nc_fc_iva}')::numeric, 12.28)
     OR NOT pg_temp.igual((v_r#>>'{ventas,nc_fc_neto}')::numeric, 87.72) THEN
    v_fallas := v_fallas || format('D1b la posición fiscal resta 87,72 + 12,28: %s', v_r->'ventas');
  END IF;

  v_r := pg_temp.nc(v_p, jsonb_build_array(jsonb_build_object('pedido_item_id', pg_temp.linea(v_p, 2), 'monto', 50),
                                           jsonb_build_object('pedido_item_id', pg_temp.linea(v_p, 3), 'monto', '20.00')),
                    'descuento_comercial');
  v_nc2 := (v_r->>'nota_credito_id')::bigint;
  IF (SELECT format('%s|%s|%s', total, neto, iva) FROM notas_credito_venta WHERE id = v_nc2) IS DISTINCT FROM '70.00|65.25|4.75' THEN
    v_fallas := v_fallas || format('D2 avanzado: %s', (SELECT format('%s|%s|%s', total, neto, iva) FROM notas_credito_venta WHERE id = v_nc2));
  END IF;
  v_t := pg_temp.nc_err(v_p, jsonb_build_array(jsonb_build_object('pedido_item_id', pg_temp.linea(v_p, 3), 'monto', 65.39)),
                        'descuento_comercial');
  IF v_t NOT LIKE '%le quedan 65.38%' THEN
    v_fallas := v_fallas || format('D3 EX 65,39: %s', v_t);
  END IF;
  v_t := pg_temp.nc_err(v_p, '[{"monto": 514.01}]', 'descuento_comercial');
  IF v_t NOT LIKE '%pasa lo que le queda a la boleta (514.00)%' THEN
    v_fallas := v_fallas || format('D4 514,01: %s', v_t);
  END IF;
  v_r := pg_temp.nc(v_p, '[{"monto": 0.01}]', 'descuento_comercial');
  IF (SELECT string_agg(pedido_item_id::text || ':' || subtotal, ',') FROM nota_credito_venta_items
       WHERE nota_credito_id = (v_r->>'nota_credito_id')::bigint) IS DISTINCT FROM pg_temp.linea(v_p, 1) || ':0.01' THEN
    v_fallas := v_fallas || text 'D5 un centavo va entero a la línea de más peso';
  END IF;
  v_r := pg_temp.nc(v_p, pg_temp.u1(pg_temp.linea(v_p, 1), 1), 'cliente_rechaza');
  v_nc3 := (v_r->>'nota_credito_id')::bigint;
  v_r := pg_temp.nc(v_p, pg_temp.u1(pg_temp.linea(v_p, 1), 2), 'cliente_rechaza');
  IF (SELECT string_agg(i.subtotal::text, ',' ORDER BY i.id) FROM nota_credito_venta_items i
       WHERE i.nota_credito_id IN (v_nc3, (v_r->>'nota_credito_id')::bigint)) IS DISTINCT FROM '103.31,206.61'
     OR (SELECT sum(i.subtotal) FROM nota_credito_venta_items i JOIN notas_credito_venta x ON x.id = i.nota_credito_id
          WHERE i.pedido_item_id = pg_temp.linea(v_p, 1) AND NOT x.anulada) IS DISTINCT FROM 363.00
     OR (SELECT format('%s|%s', neto, iva) FROM notas_credito_venta WHERE id = v_nc3) IS DISTINCT FROM '85.38|17.93' THEN
    v_fallas := v_fallas || format('D6 unidades tras el descuento: %s',
      (SELECT string_agg(i.subtotal::text, ',' ORDER BY i.id) FROM nota_credito_venta_items i
        WHERE i.nota_credito_id IN (v_nc3, (v_r->>'nota_credito_id')::bigint)));
  END IF;
  v_fallas := v_fallas || pg_temp.ver('D6 reingresan a la bolsa', g21, 'stock=100 lotes=[] bolsa=100');
  v_t := pg_temp.nc_err(v_p, '[{"monto": 204.07}]', 'descuento_comercial');
  IF v_t <> 'OK' THEN
    v_fallas := v_fallas || format('D7 lo que queda entero: %s', v_t);
  END IF;
  v_t := pg_temp.nc_err(v_p, '[{"monto": 0.01}]', 'descuento_comercial');
  IF v_t NOT LIKE '%No queda nada por acreditar%' THEN
    v_fallas := v_fallas || format('D7 ya no queda nada: %s', v_t);
  END IF;
  IF (SELECT sum(total) FROM notas_credito_venta WHERE pedido_id = v_p AND NOT anulada) IS DISTINCT FROM 684.00 THEN
    v_fallas := v_fallas || text 'D7 las notas suman lo vendido (684)';
  END IF;
  IF EXISTS (SELECT 1 FROM notas_credito_venta WHERE pedido_id = v_p AND abs(neto + iva - total) > 0.005) THEN
    v_fallas := v_fallas || text 'D7 cada nota de la FC con neto + iva = total';
  END IF;

  v_p2 := pg_temp.bol(v_c1, v_ven, 'ZZ', jsonb_build_array(jsonb_build_object('p', z1, 'c', 2, 'pr', 50),
                                                           jsonb_build_object('p', z2, 'c', 1, 'pr', 100)));
  v_r := pg_temp.nc(v_p2, '[{"monto": 30}]', 'descuento_comercial');
  IF (SELECT string_agg(subtotal::text, ',' ORDER BY id) FROM nota_credito_venta_items
       WHERE nota_credito_id = (v_r->>'nota_credito_id')::bigint) IS DISTINCT FROM '15.00,15.00'
     OR (SELECT format('%s|%s', neto, iva) FROM notas_credito_venta WHERE id = (v_r->>'nota_credito_id')::bigint)
        IS DISTINCT FROM '30.00|0.00' THEN
    v_fallas := v_fallas || format('D8 ZZ: %s', v_r);
  END IF;

  FOR v_t IN SELECT x FROM unnest(ARRAY[
      pg_temp.nc_err(v_p2, '[{"monto": 10}]', 'otro') || ' :: sólo para un descuento comercial',
      pg_temp.nc_err(v_p2, jsonb_build_array(jsonb_build_object('monto', 10),
                                             jsonb_build_object('pedido_item_id', pg_temp.linea(v_p2), 'cantidad', 1)),
                     'descuento_comercial') || ' :: ni una mezcla',
      pg_temp.nc_err(v_p2, '[{"monto": "abc"}]', 'descuento_comercial') || ' :: Monto invalido',
      pg_temp.nc_err(v_p2, '[{"monto": 0}]', 'descuento_comercial') || ' :: mayor a 0',
      pg_temp.nc_err(v_p2, '[{"monto": "NaN"}]', 'descuento_comercial') || ' :: Monto invalido',
      pg_temp.nc_err(v_p2, '[{"monto": 10}, {"monto": 5}]', 'descuento_comercial') || ' :: un solo monto',
      pg_temp.nc_err(v_p2, jsonb_build_array(jsonb_build_object('pedido_item_id', pg_temp.linea(v_p2), 'monto', 1, 'cantidad', 1)),
                     'descuento_comercial') || ' :: no las dos cosas']) x
  LOOP
    IF split_part(v_t, ' :: ', 1) NOT LIKE '%' || split_part(v_t, ' :: ', 2) || '%' THEN
      v_fallas := v_fallas || ('D9 ' || v_t);
    END IF;
  END LOOP;

  v_rid := gen_random_uuid();
  v_r := pg_temp.nc(v_p2, '[{"monto": 10}]', 'descuento_comercial', v_rid);
  v_j := pg_temp.nc(v_p2, '[{"monto": 10}]', 'descuento_comercial', v_rid);
  v_t := pg_temp.nc_err(v_p2, '[{"monto": 11}]', 'descuento_comercial', v_rid);
  IF (v_j->>'idempotent_replay')::boolean IS DISTINCT FROM true
     OR v_j->>'nota_credito_id' IS DISTINCT FROM v_r->>'nota_credito_id'
     OR v_t NOT LIKE '22023%' THEN
    v_fallas := v_fallas || format('D10 la clave es de la nota: %s / %s', v_j, v_t);
  END IF;

  v_base := pg_temp.base(v_p2);
  v_r := pg_temp.anular((v_r->>'nota_credito_id')::bigint);
  IF (v_r->>'unidades_revertidas')::int IS DISTINCT FROM 0
     OR NOT pg_temp.igual((SELECT sum(value::numeric) FROM jsonb_each_text(pg_temp.base(v_p2)))
                          - (SELECT sum(value::numeric) FROM jsonb_each_text(v_base)), 10) THEN
    v_fallas := v_fallas || format('D11 anular un descuento: %s', v_r);
  END IF;
  v_fallas := v_fallas || pg_temp.ver('D11', z1, 'stock=98 lotes=[] bolsa=98');

  -- ================================== X · lo que deja cada nota de la sucursal
  -- (no es un check de auditoria_integridad: lo mira el ensayo sobre todas las notas que armó)
  -- X1 una nota anulada no deja una merma viva.
  v_fallas := v_fallas || ARRAY(
    SELECT format('X1 la nota #%s está anulada y su merma #%s sigue viva', n.id, i.merma_id)
      FROM notas_credito_venta n
      JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
      JOIN mermas_stock m ON m.id = i.merma_id
     WHERE n.sucursal_id = v_s AND n.anulada AND m.anulada_at IS NULL);
  -- X2 una nota anulada que reingresó no deja unidades en el stock (su ledger suma 0), y una vigente
  -- deja exactamente las que reingresó; y lo que reingresó a un lote salió de él o de la bolsa: el
  -- lote no queda con más de lo que tiene el stock (LOTE-A, arriba).
  v_fallas := v_fallas || ARRAY(
    SELECT format('X2 la nota #%s (%s) deja %s u. en el ledger y reingresó %s', x.id,
                  CASE WHEN x.anulada THEN 'anulada' ELSE 'vigente' END, x.ledger, x.reingreso)
      FROM (SELECT n.id, n.anulada,
                   (SELECT COALESCE(sum(i.cantidad), 0) FROM nota_credito_venta_items i
                     WHERE i.nota_credito_id = n.id AND i.lotes_devueltos IS NOT NULL AND i.merma_id IS NULL) AS reingreso,
                   (SELECT COALESCE(sum(h.diferencia), 0) FROM stock_historico h
                     WHERE h.referencia_tipo = 'nota_credito_venta' AND h.referencia_id = n.id
                       AND h.origen IN ('nota_credito_venta', 'nota_credito_venta_anulada')) AS ledger
              FROM notas_credito_venta n
             WHERE n.sucursal_id = v_s) x
     WHERE x.ledger <> CASE WHEN x.anulada THEN 0 ELSE x.reingreso END);
  -- X3 hubo notas de todas las clases para que X1 y X2 digan algo.
  IF (SELECT count(*) FILTER (WHERE n.anulada AND i.merma_id IS NOT NULL) > 0
             AND count(*) FILTER (WHERE n.anulada AND i.lotes_devueltos IS NOT NULL AND i.merma_id IS NULL) > 0
             AND count(*) FILTER (WHERE NOT n.anulada AND i.lotes_devueltos IS NOT NULL AND i.merma_id IS NULL) > 0
        FROM notas_credito_venta n JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
       WHERE n.sucursal_id = v_s) IS NOT TRUE THEN
    v_fallas := v_fallas || text 'X3 faltan notas anuladas con merma, anuladas con reingreso o vigentes con reingreso';
  END IF;

  -- ============================================================ A · auditoría
  v_fallas := v_fallas || ARRAY(
    SELECT format('A %s: %s → %s', d.key, v_antes->>d.key, d.value)
      FROM jsonb_each_text(pg_temp.auditoria()) d
     WHERE d.value::bigint > COALESCE((v_antes->>d.key)::bigint, 0)
     ORDER BY d.key);
  FOREACH v_lote IN ARRAY ARRAY[a, a2, b, n, k, lb, lv, lz, sp, tp, g21, g105, ex, z1, z2] LOOP
    v_fallas := v_fallas || pg_temp.cierra('A ledger ' || (SELECT nombre FROM productos WHERE id = v_lote), v_lote);
  END LOOP;
 EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_t = PG_EXCEPTION_CONTEXT;
    v_fallas := v_fallas || format('el ensayo cortó: %s %s (%s)', SQLSTATE, SQLERRM, left(v_t, 400));
 END;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · B22: la nota de crédito de venta reingresa a su lote, merma o no mueve según el motivo y anularla lo deshace; el descuento comercial va por monto, prorrateado al centavo (FC con tres alícuotas y ZZ) y por clave de comisión';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ · % caso(s):\n  - %', cardinality(v_fallas), array_to_string(v_fallas, E'\n  - ');
END
$ensayo$;
