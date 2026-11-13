-- Ensayo de la migración del contenedor de una promo y del canje que devuelven a su lote
-- (reauditoría del 12/11: STK-19, STK-20 y STK-21 de #1558; tarjeta 4 de #1565).
--
-- Corre contra prod SIN dejar rastro (salvo valores de secuencia): un único DO que termina SIEMPRE
-- en una excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN
-- y el COMMIT; después, solo. Cada caso usa sus propios productos, su promo y su cliente.
--
-- Personas (salen de la base): un admin activo de una sucursal activa. Lo demás lo crea el ensayo.
--
-- Todos los productos tienen un lote de 100 con 50 vivas (hueco de 50) y, salvo donde se dice,
-- bolsa 40: con bolsa 0 la bajada cae en el lote por FEFO y un error así no se ve
-- (migrations/CLAUDE.md). La promo da 2 regalos cada 10 y cierra un bloque (1 fardo del
-- contenedor C) cada 2 regalos.
--
-- STK-19 · el fardo del contenedor vuelve a donde salió.
--   C1 · bolsa 40: la venta deja C en lote 50 y bolsa 39; tres ediciones sin cambios la dejan igual;
--        cancelar deja lote 50 y bolsa 40. Antes: 51, 52, 53 y bolsa 38, 37, 36.
--   C2 · bolsa 40: eliminar el pedido deja lote 50 y bolsa 40. Antes: 51 y 39.
--   C3 · bolsa 40: la salvedad del regalo (cliente_rechaza) deja lote 50 y bolsa 40. Antes: 51 y 39.
--   C4 · bolsa 40: editar a 20+4 (dos bloques) y volver a 10+2 deja lote 50 y bolsa 39. Antes: 53, 36.
--   C5 · bolsa 0: la venta saca el fardo del lote (49); tres ediciones sin cambios lo dejan en 49 y
--        cancelar lo devuelve a ese lote (50, bolsa 0). Con dos lotes, el fardo vuelve al que se le
--        sacó aunque el otro venza antes y tenga hueco.
--   C6 · el llamador pide otro origen para la subida (app.contenedor_origen, como la cancelación por
--        falta de stock): el fardo que salió del lote queda en la bolsa y el bloque se descuenta.
--   C7 · regresión: el contenedor también se vende como línea del pedido, con bolsa 0. La huella de
--        esa línea es su cantidad (no le suma el fardo), tres ediciones sin cambios no la mueven, y
--        cancelar deja todo como estaba.
-- STK-20 · el canje del mismo producto mueve sólo la diferencia.
--   K1 · 10 por 10: lote 50, bolsa 40, stock 90, sin renglones en el ledger. Antes: lote 60, bolsa 30.
--   K2 · devuelve 12 y se lleva 10: stock 92, los 2 de más al lote por FEFO (52), bolsa 40.
--   K3 · devuelve 10 y se lleva 13: stock 87, bolsa 37, lote 50.
--   K4 · regresión, productos distintos: el devuelto va al hueco por FEFO (por diseño) y el entregado
--        sale de la bolsa.
-- STK-21 · la merma del canje que no reingresa, con su asiento.
--   M1 · canje por vencimiento: la merma va con stock_anterior − cantidad = stock_nuevo, MERMA-B no
--        suma, el devuelto queda con el mismo stock y los mismos lotes, y el ledger tiene las dos patas
--        'cambio_producto_merma'.
--   M2 · rotura con el mismo producto: el stock baja lo entregado, de la bolsa, y el lote no se mueve.
-- Y al final, los checks de stock, lotes, mermas y promos de auditoria_integridad() no suman
-- violaciones (A1).
--
-- Sin la migración tiene que FALLAR en C1–C6, K1–K3, M1, M2 y A1. C7 y K4 son regresión.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   psql "$DATABASE_URL" -f scripts/test-contenedor-y-canje-a-su-lote-1558.sql

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_cli    bigint;
  a        bigint;
  s        bigint;
  c        bigint;
  p        bigint;
  q        bigint;
  v_promo  bigint;
  v_ped    bigint;
  v_reg    bigint;
  v_j      jsonb;
  v_t      text;
  v_n      bigint;
  v_l1     bigint;
  v_l2     bigint;
  m        record;
  v_checks jsonb;
  v_antes  jsonb;
  v_fallas text[] := '{}';
  k        int;
BEGIN
  SET LOCAL lock_timeout = '5s';

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
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('e1558.suc', v_suc::text, true);

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1558', 'ZZ ensayo 1558', 'calle 1', v_suc) RETURNING id INTO v_cli;

  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_antes
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
   WHERE x->>'id' IN ('STK-A', 'STK-B', 'STK-D', 'LOTE-A', 'LOTE-B', 'LOTE-D', 'MERMA-B', 'MERMA-H', 'PROMO-A');

  -- ---------------------------------------------------------------- helpers -
  -- Un producto con lotes [{dias, cantidad, restante}] y p_bolsa unidades sin lote.
  CREATE FUNCTION pg_temp.prod(p_lotes jsonb, p_bolsa int) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_prod bigint; l jsonb; v_s bigint := current_setting('e1558.suc')::bigint;
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES ('ZZ ensayo 1558 ' || gen_random_uuid(), 100,
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

  -- '' si la foto es la esperada; si no, la falla.
  CREATE FUNCTION pg_temp.ver(p_caso text, p_prod bigint, p_espera text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN pg_temp.f(p_prod) = p_espera THEN '{}'::text[]
                ELSE ARRAY[format('%s: %s (esperado %s)', p_caso, pg_temp.f(p_prod), p_espera)] END;
  $f$;

  -- Una promo de regalo con contenedor: 2 regalos de s cada 10 de a; 1 fardo de c cada 2 regalos.
  CREATE FUNCTION pg_temp.promo(a bigint, s bigint, c bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint; v_s bigint := current_setting('e1558.suc')::bigint;
  BEGIN
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                             ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque)
    VALUES ('ZZ ensayo 1558', 'bonificacion', public._tablero_hoy() - 1, v_s, false, s, true, c, 2, 1)
    RETURNING id INTO v;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v, 'cantidad_compra', 10, v_s), (v, 'cantidad_bonificacion', 2, v_s);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v, a, v_s);
    RETURN v;
  END $f$;

  CREATE FUNCTION pg_temp.items(a bigint, ca int, s bigint, cs int, pr bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_array(
      jsonb_build_object('producto_id', a, 'cantidad', ca, 'precio_unitario', 100),
      jsonb_build_object('producto_id', s, 'cantidad', cs, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', pr));
  $f$;

  CREATE FUNCTION pg_temp.alta(p_cli bigint, p_adm uuid, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb; v_tot numeric;
  BEGIN
    SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
      FROM jsonb_array_elements(p_items) e;
    v := public.crear_pedido_completo(p_cli, v_tot, p_adm, p_items, 'ensayo 1558');
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'ENSAYO FALLÓ · alta: %', v; END IF;
    RETURN (v->>'pedido_id')::bigint;
  END $f$;

  -- ¿Quedó algún bloque de la promo con lotes pendientes? Sin la migración la columna no existe: NULL.
  CREATE FUNCTION pg_temp.pendientes(p_promo bigint) RETURNS boolean LANGUAGE plpgsql AS $f$
  DECLARE v boolean;
  BEGIN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM promo_ajustes WHERE promocion_id = $1 AND lotes_pendientes IS NOT NULL)'
       INTO v USING p_promo;
    RETURN v;
  EXCEPTION WHEN undefined_column THEN
    RETURN NULL;
  END $f$;

  CREATE FUNCTION pg_temp.editar(p_ped bigint, p_items jsonb, p_adm uuid) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    v := public.actualizar_pedido_items(p_ped, p_items, p_adm);
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'ENSAYO FALLÓ · edición: %', v; END IF;
  END $f$;

  -- ------------------------------------------------- STK-19 · C1, C2 y C3 ---
  FOREACH k IN ARRAY ARRAY[1, 2, 3] LOOP
    a := pg_temp.prod('[]', 100);
    s := pg_temp.prod('[]', 100);
    c := pg_temp.prod('[{"dias":10,"cantidad":100,"restante":50}]', 40);
    v_promo := pg_temp.promo(a, s, c);
    v_ped := pg_temp.alta(v_cli, v_adm, pg_temp.items(a, 10, s, 2, v_promo));
    v_fallas := v_fallas || pg_temp.ver('C' || k || ' tras la venta', c, 'stock=89 lotes=[50] bolsa=39');
    IF k = 1 THEN
      FOR i IN 1..3 LOOP
        PERFORM pg_temp.editar(v_ped, pg_temp.items(a, 10, s, 2, v_promo), v_adm);
        v_fallas := v_fallas || pg_temp.ver('C1 edición sin cambios #' || i, c, 'stock=89 lotes=[50] bolsa=39');
      END LOOP;
      v_j := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1558', v_adm, NULL);
      v_t := 'C1 cancelar';
    ELSIF k = 2 THEN
      v_j := public.eliminar_pedido_completo(v_ped, v_adm, 'ensayo 1558', true);
      v_t := 'C2 eliminar';
    ELSE
      SELECT id INTO v_reg FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
      v_j := public.registrar_salvedad(v_ped, v_reg, 2, 'cliente_rechaza', 'ensayo 1558', NULL, true, NULL);
      v_t := 'C3 salvedad del regalo';
    END IF;
    IF v_j ? 'error' OR v_j->>'success' = 'false' THEN
      v_fallas := v_fallas || format('%s: %s', v_t, v_j);
    END IF;
    v_fallas := v_fallas || pg_temp.ver(v_t, c, 'stock=90 lotes=[50] bolsa=40');
  END LOOP;

  -- ------------------------------------------------------- STK-19 · C4 ---
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[]', 100);
  c := pg_temp.prod('[{"dias":10,"cantidad":100,"restante":50}]', 40);
  v_promo := pg_temp.promo(a, s, c);
  v_ped := pg_temp.alta(v_cli, v_adm, pg_temp.items(a, 10, s, 2, v_promo));
  PERFORM pg_temp.editar(v_ped, pg_temp.items(a, 20, s, 4, v_promo), v_adm);
  v_fallas := v_fallas || pg_temp.ver('C4 a 20+4', c, 'stock=88 lotes=[50] bolsa=38');
  PERFORM pg_temp.editar(v_ped, pg_temp.items(a, 10, s, 2, v_promo), v_adm);
  v_fallas := v_fallas || pg_temp.ver('C4 vuelta a 10+2', c, 'stock=89 lotes=[50] bolsa=39');

  -- ------------------------------------------------------- STK-19 · C5 ---
  -- Bolsa 0 y dos lotes: el de 10 días está lleno, el de 5 días tiene hueco. FEFO saca del de 5.
  -- Para que el fardo salga del de 10, el de 5 arranca en 0 (sólo hueco).
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[]', 100);
  c := pg_temp.prod('[{"dias":5,"cantidad":30,"restante":0},{"dias":10,"cantidad":100,"restante":50}]', 0);
  v_promo := pg_temp.promo(a, s, c);
  v_ped := pg_temp.alta(v_cli, v_adm, pg_temp.items(a, 10, s, 2, v_promo));
  v_fallas := v_fallas || pg_temp.ver('C5 tras la venta', c, 'stock=49 lotes=[0,49] bolsa=0');
  FOR i IN 1..3 LOOP
    PERFORM pg_temp.editar(v_ped, pg_temp.items(a, 10, s, 2, v_promo), v_adm);
    v_fallas := v_fallas || pg_temp.ver('C5 edición sin cambios #' || i, c, 'stock=49 lotes=[0,49] bolsa=0');
  END LOOP;
  v_j := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1558', v_adm, NULL);
  v_fallas := v_fallas || pg_temp.ver('C5 cancelar', c, 'stock=50 lotes=[0,50] bolsa=0');
  IF pg_temp.pendientes(v_promo) IS DISTINCT FROM false THEN
    v_fallas := v_fallas || 'C5: quedó un bloque con lotes pendientes después de cancelar (o la columna no existe)'::text;
  END IF;

  -- ------------------------------------------------------- STK-19 · C6 ---
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[]', 100);
  c := pg_temp.prod('[{"dias":10,"cantidad":100,"restante":50}]', 0);
  v_promo := pg_temp.promo(a, s, c);
  PERFORM public.aplicar_uso_promo_acumulador(v_promo, s, 2, s, v_suc, v_adm, 'ensayo 1558');
  v_fallas := v_fallas || pg_temp.ver('C6 bloque', c, 'stock=49 lotes=[49] bolsa=0');
  PERFORM set_config('app.contenedor_origen', 'pedido_cancelado_merma', true);
  PERFORM public.aplicar_uso_promo_acumulador(v_promo, s, -2, s, v_suc, v_adm, 'ensayo 1558');
  PERFORM set_config('app.contenedor_origen', '', true);
  v_fallas := v_fallas || pg_temp.ver('C6 subida con otro origen', c, 'stock=50 lotes=[49] bolsa=1');
  IF pg_temp.pendientes(v_promo) IS DISTINCT FROM false THEN
    v_fallas := v_fallas || 'C6: el bloque deshecho quedó con lotes pendientes (o la columna no existe)'::text;
  END IF;
  SELECT origen INTO v_t FROM stock_historico WHERE producto_id = c ORDER BY id DESC LIMIT 1;
  IF v_t IS DISTINCT FROM 'pedido_cancelado_merma' THEN
    v_fallas := v_fallas || format('C6: la subida salió con %s y no con el origen del llamador', v_t);
  END IF;

  -- ------------------------------------------------------- STK-19 · C7 ---
  a := pg_temp.prod('[]', 100);
  s := pg_temp.prod('[]', 100);
  c := pg_temp.prod('[{"dias":10,"cantidad":100,"restante":50}]', 0);
  v_promo := pg_temp.promo(a, s, c);
  v_ped := pg_temp.alta(v_cli, v_adm, jsonb_build_array(
    jsonb_build_object('producto_id', a, 'cantidad', 10, 'precio_unitario', 100),
    jsonb_build_object('producto_id', c, 'cantidad', 5, 'precio_unitario', 100),
    jsonb_build_object('producto_id', s, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo)));
  v_fallas := v_fallas || pg_temp.ver('C7 tras la venta', c, 'stock=44 lotes=[44] bolsa=0');
  SELECT COALESCE(SUM(pil.cantidad), 0) INTO v_n
    FROM pedido_item_lotes pil JOIN pedido_items pi ON pi.id = pil.pedido_item_id
   WHERE pi.pedido_id = v_ped AND pi.producto_id = c;
  IF v_n <> 5 THEN
    v_fallas := v_fallas || format('C7: la huella de la línea del contenedor es %s y la línea es de 5', v_n);
  END IF;
  v_j := jsonb_build_array(
    jsonb_build_object('producto_id', a, 'cantidad', 10, 'precio_unitario', 100),
    jsonb_build_object('producto_id', c, 'cantidad', 5, 'precio_unitario', 100),
    jsonb_build_object('producto_id', s, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo));
  FOR i IN 1..3 LOOP
    PERFORM pg_temp.editar(v_ped, v_j, v_adm);
    v_fallas := v_fallas || pg_temp.ver('C7 edición sin cambios #' || i, c, 'stock=44 lotes=[44] bolsa=0');
  END LOOP;
  SELECT COALESCE(SUM(pil.cantidad), 0) INTO v_n
    FROM pedido_item_lotes pil JOIN pedido_items pi ON pi.id = pil.pedido_item_id
   WHERE pi.pedido_id = v_ped AND pi.producto_id = c;
  IF v_n <> 5 THEN
    v_fallas := v_fallas || format('C7: tras editar, la huella de la línea del contenedor es %s y la línea es de 5', v_n);
  END IF;
  v_j := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1558', v_adm, NULL);
  v_fallas := v_fallas || pg_temp.ver('C7 cancelar', c, 'stock=50 lotes=[50] bolsa=0');

  -- ------------------------------------------------- STK-20 · K1, K2 y K3 ---
  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  SELECT count(*) INTO v_n FROM stock_historico WHERE producto_id = p;
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 10, p, 10, 'ensayo 1558', 'otro');
  v_fallas := v_fallas || pg_temp.ver('K1 10 por 10', p, 'stock=90 lotes=[50] bolsa=40');
  IF (SELECT count(*) FROM stock_historico WHERE producto_id = p) <> v_n THEN
    v_fallas := v_fallas || 'K1: un canje 10 por 10 del mismo producto dejó renglones en el ledger'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cambios_productos WHERE producto_devuelto_id = p AND cantidad_devuelta = 10) THEN
    v_fallas := v_fallas || 'K1: el canje no quedó en cambios_productos'::text;
  END IF;

  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 12, p, 10, 'ensayo 1558', 'erroneo');
  v_fallas := v_fallas || pg_temp.ver('K2 12 por 10', p, 'stock=92 lotes=[52] bolsa=40');

  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 10, p, 13, 'ensayo 1558', 'erroneo');
  v_fallas := v_fallas || pg_temp.ver('K3 10 por 13', p, 'stock=87 lotes=[50] bolsa=37');

  -- ------------------------------------------------------- STK-20 · K4 ---
  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  q := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 10, q, 10, 'ensayo 1558', 'erroneo');
  v_fallas := v_fallas || pg_temp.ver('K4 devuelto', p, 'stock=100 lotes=[60] bolsa=40');
  v_fallas := v_fallas || pg_temp.ver('K4 entregado', q, 'stock=80 lotes=[50] bolsa=30');

  -- ------------------------------------------------------- STK-21 · M1 ---
  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  q := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 3, q, 3, 'ensayo 1558', 'vencimiento');
  SELECT * INTO m FROM mermas_stock WHERE producto_id = p;
  IF m.id IS NULL THEN
    v_fallas := v_fallas || 'M1: el canje por vencimiento no dejó merma'::text;
  ELSIF m.cantidad <> 3 OR m.motivo <> 'vencimiento' OR m.stock_anterior <> 93 OR m.stock_nuevo <> 90 THEN
    v_fallas := v_fallas || format('M1: merma cantidad=%s motivo=%s %s->%s (esperado 3 vencimiento 93->90)',
                                   m.cantidad, m.motivo, m.stock_anterior, m.stock_nuevo);
  END IF;
  v_fallas := v_fallas || pg_temp.ver('M1 devuelto', p, 'stock=90 lotes=[50] bolsa=40');
  v_fallas := v_fallas || pg_temp.ver('M1 entregado', q, 'stock=87 lotes=[50] bolsa=37');
  SELECT string_agg(format('%s->%s %s', stock_anterior, stock_nuevo, origen), ' | ' ORDER BY id) INTO v_t
    FROM stock_historico WHERE producto_id = p AND referencia_tipo = 'cambios_productos';
  IF v_t IS DISTINCT FROM '90->93 cambio_producto_merma | 93->90 cambio_producto_merma' THEN
    v_fallas := v_fallas || format('M1: ledger del devuelto %s', COALESCE(v_t, '(nada)'));
  END IF;

  -- ------------------------------------------------------- STK-21 · M2 ---
  p := pg_temp.prod('[{"dias":30,"cantidad":100,"restante":50}]', 40);
  PERFORM public.registrar_cambio_producto(v_cli::int, p, 4, p, 4, 'ensayo 1558', 'rotura');
  v_fallas := v_fallas || pg_temp.ver('M2 rotura del mismo producto', p, 'stock=86 lotes=[50] bolsa=36');
  SELECT * INTO m FROM mermas_stock WHERE producto_id = p;
  IF m.id IS NULL OR m.stock_nuevo <> m.stock_anterior - m.cantidad THEN
    v_fallas := v_fallas || format('M2: merma %s->%s de %s', m.stock_anterior, m.stock_nuevo, m.cantidad);
  END IF;

  -- -------------------------------------------------------------------- A1 ---
  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_checks
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
   WHERE x->>'id' IN ('STK-A', 'STK-B', 'STK-D', 'LOTE-A', 'LOTE-B', 'LOTE-D', 'MERMA-B', 'MERMA-H', 'PROMO-A');
  FOR v_t IN SELECT jsonb_object_keys(v_antes) LOOP
    IF (v_checks->>v_t)::bigint > (v_antes->>v_t)::bigint THEN
      v_fallas := v_fallas || format('A1: %s pasó de %s a %s violaciones', v_t, v_antes->>v_t, v_checks->>v_t);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, E'\n · ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · C1 C2 C3 C4 C5 C6 C7 K1 K2 K3 K4 M1 M2 A1';
END
$ensayo$;
