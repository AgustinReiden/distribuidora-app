-- Ensayo de la migración NNN_edicion_lotes_bloques_y_mensajes (plan #1603, tanda 6 bis,
-- tarjeta J: dos defectos viejos de la edición del pedido y dos retoques de sus mensajes).
--
-- No deja rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una excepción.
-- Antes de aplicar la migración tiene que FALLAR en J1a, J1b, J1c, J1d, J1f, J3 y J4; después,
-- dar 'ENSAYO OK'. J1e y J2 son controles (pasan antes y después).
-- Corre en una base local con la semilla mínima (un admin activo de las sucursales 1 y 2) o en
-- una copia de prod, con o sin la migración de la tarjeta I (546). Usa el día argentino
-- (_tablero_hoy()) y no depende de la hora: las altas y las ediciones las hace un ENCARGADO (sin
-- el corte de las 15:30 del preventista); lo que tiene que pasar «antes» y «después» (el armado
-- de un combo, la salvedad, la edición) se corre hacia atrás a mano.
--
-- J1 · LOTE-A al editar (H-3 de la lente de H). Promo de fracción «10 A dan 2 S» (S no mueve
--   stock), contenedor C, 2 unidades de S por bloque y 1 C por bloque.
--   J1a · C con un lote de 5 y la bolsa en 0. Alta A×10 + S×2 + C×1 (un bloque; la línea con
--         huella en el lote: C 3, lote 3). Editar a A×20 + S×4 (saca la línea y cierra otro
--         bloque) deja C 3, lote 3, bolsa 0, sin huella, y el bloque nuevo dice el lote (antes:
--         lote 4 y bolsa −1).
--   J1b · volver a A×10 + S×2 + C×1 y cancelar deja C 3 / lote 3 / huella 1, y después C 5,
--         lote 5, bolsa 0, sin bloques vivos (antes: huella 2 en una línea de 1, y el lote en 4
--         con la bolsa en 1).
--   J1c · bajar la línea en vez de sacarla: alta A×10 + S×2 + C×3; editar a A×20 + S×4 + C×1 deja
--         C 2, lote 2, bolsa 0, huella 1 (antes: lote 3, bolsa −1).
--   J1d · la cadena desde el caso de la 545: C con un lote de 2; A×20 + S×4 (C en 0), A×10 + S×2
--         + C×1 (entra por el camino de STK-2), A×20 + S×4 deja C 0, lote 0, bolsa 0 (antes: lote
--         1, bolsa −1); cancelar deja C 2, lote 2, bolsa 0.
--   J1e · control: con bolsa en el contenedor (entró después del alta) la edición da lo de
--         siempre: el rehacer devuelve al lote y el bloque nuevo sale de la bolsa.
--   J1f · dos lotes y dos bloques nuevos: C con lotes de 2 y 3; A×10 + S×2 + C×3; editar a A×30
--         + S×6 + C×1 deja los lotes en 0 y 1 con la bolsa en 0, el bloque nuevo en los dos lotes;
--         volver y cancelar deja los lotes en 2 y 3.
-- J2 · COMBO-B después de una rotura (no hacía falta): combo 1 A + 1 B a $ 1.000, alta de 2
--   combos, la salvedad rechaza 1 B (el combo se rompe) y DESPUÉS se edita: 1 combo, A suelto y
--   un producto más. El plan del combo coincide con su foto (cantidad y recargo).
-- J3 · H-1: la promo tiene bloques vivos de OTRO pedido y esta edición no baja su barra (el admin
--   edita A×5 + S×1 a A×5 + S×1 + C×1 con C en 0): el rechazo de siempre, success=false con «stock insuficiente
--   (disponible: 0, adicional: 1)», no una excepción (antes: «…contando lo que devuelve la barra»).
-- J4 · N3: el rechazo del tope de la cadena nombra el regalo con el que mide. Promo «5 V dan 2 R»
--   que mueve stock; el encargado carga W (del rubro de R) como regalo; el admin lo cambia por Z
--   (perfume de $ 5.000); el encargado baja la venta a V×5: se rechaza y el mensaje dice
--   «…ahora («R» × 2)», no «W».
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-edicion-lotes-tanda6bis-1603.sql

DO $ensayo$
DECLARE
  v_adm    uuid;
  v_enc    uuid := gen_random_uuid();
  v_cli    bigint;
  e        jsonb;
  v_j      jsonb;
  v_t      text;
  v_a      bigint;
  v_b      bigint;
  v_c      bigint;
  v_s      bigint;
  v_r      bigint;
  v_v      bigint;
  v_w      bigint;
  v_z      bigint;
  v_promo  bigint;
  v_combo  bigint;
  v_ped    bigint;
  v_ped2   bigint;
  v_item   bigint;
  v_lote   bigint;
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------------------------- personas ---
  SELECT p.id INTO v_adm
    FROM perfiles p
   WHERE p.rol = 'admin' AND p.activo
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = 1)
   ORDER BY p.id LIMIT 1;
  IF v_adm IS NULL OR NOT EXISTS (SELECT 1 FROM sucursales WHERE id = 1 AND activa) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de la sucursal 1, activa';
  END IF;
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_enc, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6j-' || v_enc || '@ensayo.invalid',
          jsonb_build_object('rol', 'encargado', 'sucursal_id', 1), '{}', now(), now());
  PERFORM set_config('et6j.adm', v_adm::text, true);

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.limpiar() RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('app.stock_origen', '', true), set_config('app.stock_ref_tipo', '', true),
           set_config('app.stock_ref_id', '', true), set_config('app.stock_user_id', '', true),
           set_config('app.stock_pedido_item_id', '', true), set_config('app.omitir_minimo_venta', '', true),
           set_config('app.regalo_corte_manual', '', true), set_config('app.cambio_cliente_desde', '', true);
  $f$;
  -- Una RPC como el front: rol authenticated, como p_uid (el admin si es NULL), parado en la sucursal 1.
  CREATE FUNCTION pg_temp.como(p_sql text, p_uid uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', COALESCE(p_uid, current_setting('et6j.adm')::uuid), 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;
  CREATE FUNCTION pg_temp.it(p_prod bigint, p_cant int, p_precio numeric DEFAULT 100) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio);
  $f$;
  CREATE FUNCTION pg_temp.reg(p_prod bigint, p_cant int, p_promo bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                              'es_bonificacion', true, 'promocion_id', p_promo);
  $f$;
  -- Producto con p_bolsa sin lote y un lote de 100 por cada restante de p_lotes (a 10, 30, … días).
  CREATE FUNCTION pg_temp.prod(p_precio numeric, p_bolsa int, p_lotes int[] DEFAULT '{}', p_cat text DEFAULT NULL)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v bigint;
    i int;
  BEGIN
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id, categoria)
    VALUES ('ZZ t6j ' || gen_random_uuid(), p_precio,
            p_bolsa + COALESCE((SELECT sum(x) FROM unnest(p_lotes) x), 0), 50, 50, 50, 50, 1, p_cat)
    RETURNING id INTO v;
    FOR i IN 1 .. COALESCE(cardinality(p_lotes), 0) LOOP
      INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
      VALUES (v, 1, public._tablero_hoy() + 10 + 20 * (i - 1), 100, p_lotes[i], 'manual');
    END LOOP;
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.cli() RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('ZZ t6j', 'ZZ t6j ' || gen_random_uuid(), 'calle 1', 1) RETURNING id;
  $f$;
  CREATE FUNCTION pg_temp.alta(p_uid uuid, p_cli bigint, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v jsonb;
  BEGIN
    v := pg_temp.como(format('SELECT public.crear_pedido_completo(p_cliente_id => %s, p_total => %s, p_usuario_id => %L, p_items => %L::jsonb)::text',
                             p_cli,
                             (SELECT COALESCE(sum((x->>'cantidad')::numeric * (x->>'precio_unitario')::numeric), 0)
                                FROM jsonb_array_elements(p_items) x),
                             p_uid, p_items), p_uid)::jsonb;
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ENSAYO FALLÓ · el alta de fixture no entró: %', v;
    END IF;
    RETURN (v->>'pedido_id')::bigint;
  END $f$;
  -- La edición como el front: el jsonb de la respuesta, o {"excepcion": "..."} si la RPC tiró.
  CREATE FUNCTION pg_temp.edit(p_uid uuid, p_ped bigint, p_items jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    RETURN pg_temp.como(format('SELECT public.actualizar_pedido_items(%s, %L::jsonb, %L)::text', p_ped, p_items, p_uid), p_uid)::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    RETURN jsonb_build_object('excepcion', SQLSTATE || ': ' || SQLERRM);
  END $f$;
  CREATE FUNCTION pg_temp.ok(p jsonb) RETURNS boolean LANGUAGE sql AS $f$
    SELECT COALESCE((p->>'success')::boolean, false);
  $f$;
  -- La cancelación la hace el admin: NULL si entró, si no el motivo.
  CREATE FUNCTION pg_temp.cancelar(p_ped bigint) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v jsonb;
  BEGIN
    v := pg_temp.como(format('SELECT public.cancelar_pedido_con_stock(%s, %L, %L, NULL)::text',
                             p_ped, 'ensayo t6j', current_setting('et6j.adm')))::jsonb;
    RETURN CASE WHEN pg_temp.ok(v) THEN NULL ELSE v::text END;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    RETURN SQLSTATE || ': ' || SQLERRM;
  END $f$;
  -- La foto de un producto: stock, lotes (restante, por vencimiento), bolsa, huella de sus
  -- líneas (suma) y si el ledger cierra.
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('stock=%s lotes=[%s] bolsa=%s huella=%s%s', p.stock,
      COALESCE((SELECT string_agg(cantidad_restante::text, ',' ORDER BY fecha_vencimiento, id)
                  FROM public.producto_lotes WHERE producto_id = p_prod), ''),
      p.stock - COALESCE((SELECT sum(cantidad_restante) FROM public.producto_lotes WHERE producto_id = p_prod), 0),
      COALESCE((SELECT sum(pil.cantidad) FROM public.pedido_item_lotes pil
                  JOIN public.producto_lotes l ON l.id = pil.lote_id
                 WHERE l.producto_id = p_prod), 0),
      CASE WHEN (SELECT stock_nuevo FROM public.stock_historico WHERE producto_id = p_prod ORDER BY id DESC LIMIT 1)
                IS DISTINCT FROM p.stock THEN ' LEDGER≠STOCK' ELSE '' END)
      FROM public.productos p WHERE p.id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.vivos(p_promo bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT COALESCE(sum(bloques_vivos), 0)::int FROM public.promo_ajustes WHERE promocion_id = p_promo AND bloques_vivos > 0;
  $f$;
  -- Los lotes de donde salió el último bloque de la promo, como «posición del lote:cantidad»
  -- (bolsa = 0), en el orden en que lo anota el motor.
  CREATE FUNCTION pg_temp.ultimo_bloque(p_promo bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(
             COALESCE((SELECT x.rn::text FROM (SELECT id, row_number() OVER (ORDER BY fecha_vencimiento, id) rn
                                                 FROM public.producto_lotes WHERE producto_id = pa.producto_id) x
                        WHERE x.id = (el->>'lote_id')::bigint), '0') || ':' || (el->>'cantidad'), ',' ORDER BY o), '-')
      FROM (SELECT * FROM public.promo_ajustes WHERE promocion_id = p_promo ORDER BY id DESC LIMIT 1) pa
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(pa.lotes_pendientes, '[]'::jsonb)) WITH ORDINALITY AS t(el, o);
  $f$;
  -- La promo de fracción «10 A dan 2 S» con contenedor C (2 S y 1 C por bloque, o p_k).
  CREATE FUNCTION pg_temp.barra(a bigint, s bigint, c bigint, p_k int DEFAULT 1) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    p bigint;
  BEGIN
    INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                                    ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque,
                                    descripcion_regalo)
    VALUES ('ZZ t6j barra', 'bonificacion', public._tablero_hoy() - 1, 1, false, s, true, c, 2, p_k, '1 unidad de ensayo')
    RETURNING id INTO p;
    INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (p, 'cantidad_compra', 10, 1), (p, 'cantidad_bonificacion', 2, 1);
    INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (p, a, 1);
    RETURN p;
  END $f$;

  v_cli := pg_temp.cli();

  -- ====================================================== J1 · LOTE-A ===
  -- J1a y J1b
  v_a := pg_temp.prod(100, 1000); v_s := pg_temp.prod(100, 100); v_c := pg_temp.prod(100, 0, ARRAY[5]);
  v_promo := pg_temp.barra(v_a, v_s, v_c);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_a, 10), pg_temp.reg(v_s, 2, v_promo), pg_temp.it(v_c, 1)));
  IF pg_temp.foto(v_c) <> 'stock=3 lotes=[3] bolsa=0 huella=1' OR pg_temp.vivos(v_promo) <> 1 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture J1a: C tenía que quedar 3 en el lote con la huella de la línea y un bloque: % (vivos %)',
      pg_temp.foto(v_c), pg_temp.vivos(v_promo);
  END IF;
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 20), pg_temp.reg(v_s, 4, v_promo)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j), 'J1a · A×20 + S×4 tenía que entrar: ' || v_j::text);
  v_fallas := v_fallas || pg_temp.chk(pg_temp.foto(v_c) = 'stock=3 lotes=[3] bolsa=0 huella=0',
    'J1a · C tenía que quedar stock 3, lote 3, bolsa 0 (el bloque nuevo toma el fardo que devolvió la línea): ' || pg_temp.foto(v_c));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.vivos(v_promo) = 2 AND pg_temp.ultimo_bloque(v_promo) = '1:1',
    'J1a · el bloque nuevo tenía que decir el lote de C: ' || pg_temp.ultimo_bloque(v_promo));
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 10), pg_temp.reg(v_s, 2, v_promo), pg_temp.it(v_c, 1)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j) AND pg_temp.foto(v_c) = 'stock=3 lotes=[3] bolsa=0 huella=1',
    'J1b · volver a A×10 + S×2 + C×1 tenía que dejar C 3, lote 3, huella 1: ' || v_j::text || ' ' || pg_temp.foto(v_c));
  v_t := pg_temp.cancelar(v_ped);
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND pg_temp.foto(v_c) = 'stock=5 lotes=[5] bolsa=0 huella=0' AND pg_temp.vivos(v_promo) = 0,
    'J1b · cancelar tenía que dejar C como antes del alta (5 en el lote): ' || COALESCE(v_t, '') || ' ' || pg_temp.foto(v_c)
      || ' vivos ' || pg_temp.vivos(v_promo));

  -- J1c: bajar la línea de C en vez de sacarla.
  v_a := pg_temp.prod(100, 1000); v_s := pg_temp.prod(100, 100); v_c := pg_temp.prod(100, 0, ARRAY[5]);
  v_promo := pg_temp.barra(v_a, v_s, v_c);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_a, 10), pg_temp.reg(v_s, 2, v_promo), pg_temp.it(v_c, 3)));
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 20), pg_temp.reg(v_s, 4, v_promo), pg_temp.it(v_c, 1)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j) AND pg_temp.foto(v_c) = 'stock=2 lotes=[2] bolsa=0 huella=1',
    'J1c · A×20 + S×4 + C×1 tenía que dejar C 2, lote 2, bolsa 0, huella 1: ' || v_j::text || ' ' || pg_temp.foto(v_c));

  -- J1d: la edición siguiente al caso de la 545.
  v_a := pg_temp.prod(100, 1000); v_s := pg_temp.prod(100, 100); v_c := pg_temp.prod(100, 0, ARRAY[2]);
  v_promo := pg_temp.barra(v_a, v_s, v_c);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_a, 20), pg_temp.reg(v_s, 4, v_promo)));
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 10), pg_temp.reg(v_s, 2, v_promo), pg_temp.it(v_c, 1)));
  IF NOT pg_temp.ok(v_j) OR pg_temp.foto(v_c) <> 'stock=0 lotes=[0] bolsa=0 huella=1' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture J1d: A×10 + S×2 + C×1 con C en 0 tenía que entrar (545): % %', v_j, pg_temp.foto(v_c);
  END IF;
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 20), pg_temp.reg(v_s, 4, v_promo)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j) AND pg_temp.foto(v_c) = 'stock=0 lotes=[0] bolsa=0 huella=0',
    'J1d · volver a A×20 + S×4 tenía que dejar C 0, lote 0, bolsa 0: ' || v_j::text || ' ' || pg_temp.foto(v_c));
  v_t := pg_temp.cancelar(v_ped);
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND pg_temp.foto(v_c) = 'stock=2 lotes=[2] bolsa=0 huella=0',
    'J1d · cancelar tenía que dejar C 2 en su lote: ' || COALESCE(v_t, '') || ' ' || pg_temp.foto(v_c));

  -- J1e (control): bolsa en el contenedor después del alta.
  v_a := pg_temp.prod(100, 1000); v_s := pg_temp.prod(100, 100); v_c := pg_temp.prod(100, 0, ARRAY[5]);
  v_promo := pg_temp.barra(v_a, v_s, v_c);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_a, 10), pg_temp.reg(v_s, 2, v_promo), pg_temp.it(v_c, 1)));
  PERFORM set_config('app.stock_origen', 'compra', true);
  PERFORM set_config('app.stock_ref_tipo', 'ensayo', true);
  UPDATE productos SET stock = stock + 3 WHERE id = v_c;
  PERFORM pg_temp.limpiar();
  IF pg_temp.foto(v_c) <> 'stock=6 lotes=[3] bolsa=3 huella=1' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture J1e: la compra tenía que ir a la bolsa: %', pg_temp.foto(v_c);
  END IF;
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 20), pg_temp.reg(v_s, 4, v_promo)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j) AND pg_temp.foto(v_c) = 'stock=6 lotes=[4] bolsa=2 huella=0'
                                      AND pg_temp.ultimo_bloque(v_promo) = '0:1',
    'J1e · con bolsa, la edición tenía que dar lo de siempre (lote 4, bolsa 2, el bloque nuevo de la bolsa): '
      || v_j::text || ' ' || pg_temp.foto(v_c) || ' bloque ' || pg_temp.ultimo_bloque(v_promo));

  -- J1f: dos lotes y dos bloques nuevos.
  v_a := pg_temp.prod(100, 1000); v_s := pg_temp.prod(100, 100); v_c := pg_temp.prod(100, 0, ARRAY[2, 3]);
  v_promo := pg_temp.barra(v_a, v_s, v_c);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_a, 10), pg_temp.reg(v_s, 2, v_promo), pg_temp.it(v_c, 3)));
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 30), pg_temp.reg(v_s, 6, v_promo), pg_temp.it(v_c, 1)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j) AND pg_temp.foto(v_c) = 'stock=1 lotes=[0,1] bolsa=0 huella=1'
                                      AND pg_temp.ultimo_bloque(v_promo) = '1:1,2:1',
    'J1f · A×30 + S×6 + C×1 tenía que dejar los lotes en 0 y 1, la bolsa en 0 y el bloque nuevo en los dos lotes: '
      || v_j::text || ' ' || pg_temp.foto(v_c) || ' bloque ' || pg_temp.ultimo_bloque(v_promo));
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 10), pg_temp.reg(v_s, 2, v_promo), pg_temp.it(v_c, 3)));
  v_t := pg_temp.cancelar(v_ped);
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j) AND v_t IS NULL AND pg_temp.foto(v_c) = 'stock=5 lotes=[2,3] bolsa=0 huella=0',
    'J1f · volver y cancelar tenía que dejar los lotes en 2 y 3: ' || v_j::text || ' ' || COALESCE(v_t, '') || ' ' || pg_temp.foto(v_c));

  -- ================================================ J2 · COMBO-B (control) ===
  v_a := pg_temp.prod(800, 500, '{}', 'ZZ t6j combos');
  v_b := pg_temp.prod(400, 500, '{}', 'ZZ t6j combos');
  v_c := pg_temp.prod(250, 500, '{}', 'ZZ t6j otros');
  v_j := pg_temp.como(format('SELECT public.guardar_combo(%L::jsonb)::text', jsonb_build_object(
           'nombre', 'ZZ t6j combo', 'precio', 1000, 'fecha_inicio', public._tablero_hoy() - 1, 'combina_escalas', false,
           'componentes', jsonb_build_array(jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_a)),
                                            jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_b))))))::jsonb;
  IF NOT pg_temp.ok(v_j) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture J2: el combo no se creó: %', v_j;
  END IF;
  v_combo := (v_j->>'id')::bigint;
  -- k combos de 1 A + 1 B, repartidos como el server.
  CREATE FUNCTION pg_temp.combo_items(p_combo bigint, p_k int, a bigint, b bigint) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_pr jsonb := public._combo_prorrateo(1000 * p_k, jsonb_build_array(
                    jsonb_build_object('producto_id', a, 'cantidad', p_k, 'ref', 800),
                    jsonb_build_object('producto_id', b, 'cantidad', p_k, 'ref', 400)));
  BEGIN
    RETURN jsonb_build_array(
      jsonb_build_object('producto_id', a, 'cantidad', p_k, 'precio_unitario', (v_pr->>a::text)::numeric,
                         'combo_id', p_combo, 'precio_sin_combo_unitario', 800),
      jsonb_build_object('producto_id', b, 'cantidad', p_k, 'precio_unitario', (v_pr->>b::text)::numeric,
                         'combo_id', p_combo, 'precio_sin_combo_unitario', 400));
  END $f$;
  -- El plan del combo (_combo_plan sobre su estado) contra su foto: NULL si coinciden.
  CREATE FUNCTION pg_temp.combo_b(p_ped bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(format('foto %s/%s, plan %s/%s', f.cantidad_combos, f.recargo, y.pl->>'combos', y.pl->>'recargo'), '; ')
      FROM public.pedido_combos f
      CROSS JOIN LATERAL (SELECT public._combo_estado(f.pedido_id, f.sucursal_id, f.combo_id, NULL) AS e) x
      CROSS JOIN LATERAL (SELECT public._combo_plan(x.e->'componentes', (x.e->>'armados')::int, x.e->'lineas',
                                                    x.e->'rechazos', x.e->'precios') AS pl) y
     WHERE f.pedido_id = p_ped
       AND ((y.pl->>'combos')::int IS DISTINCT FROM f.cantidad_combos OR (y.pl->>'recargo')::numeric IS DISTINCT FROM f.recargo);
  $f$;
  v_ped := pg_temp.alta(v_enc, v_cli, pg_temp.combo_items(v_combo, 2, v_a, v_b));
  -- La salvedad va sobre un pedido en camino (1595-b5). El armado del alta fue antes.
  UPDATE pedidos SET estado = 'asignado' WHERE id = v_ped;
  UPDATE pedido_combos SET armado_at = armado_at - interval '2 minutes' WHERE pedido_id = v_ped;
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_b AND combo_id IS NOT NULL;
  v_j := pg_temp.como(format('SELECT public.registrar_salvedad(%s, %s, 1, %L, %L, NULL, true, NULL)::text',
                             v_ped, v_item, 'cliente_rechaza', 'ensayo t6j'), v_enc)::jsonb;
  IF NOT pg_temp.ok(v_j) OR pg_temp.combo_b(v_ped) IS NOT NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture J2: la salvedad tenía que romper un combo: % %', v_j, pg_temp.combo_b(v_ped);
  END IF;
  -- La salvedad fue antes de la edición (en la app son dos llamadas).
  UPDATE salvedades_items SET created_at = created_at - interval '1 minute' WHERE pedido_id = v_ped;
  v_j := pg_temp.edit(v_enc, v_ped, pg_temp.combo_items(v_combo, 1, v_a, v_b)
                                    || jsonb_build_array(pg_temp.it(v_c, 1, 250), pg_temp.it(v_a, 1, 800)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j) AND pg_temp.combo_b(v_ped) IS NULL,
    'J2 · la edición después de la rotura tenía que dejar el combo como su foto (COMBO-B): ' || v_j::text || ' '
      || COALESCE(pg_temp.combo_b(v_ped), ''));

  -- ======================================================= J3 · H-1 ===
  v_a := pg_temp.prod(100, 1000); v_s := pg_temp.prod(100, 100); v_c := pg_temp.prod(100, 0, ARRAY[2]);
  v_promo := pg_temp.barra(v_a, v_s, v_c);
  -- Media barra (A×5 + S×1) sólo la carga el admin (regalo_fuera_de_promo).
  v_ped2 := pg_temp.alta(v_adm, pg_temp.cli(), jsonb_build_array(pg_temp.it(v_a, 20), pg_temp.reg(v_s, 4, v_promo)));
  v_ped := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.it(v_a, 5), pg_temp.reg(v_s, 1, v_promo)));
  v_j := pg_temp.edit(v_adm, v_ped, jsonb_build_array(pg_temp.it(v_a, 5), pg_temp.reg(v_s, 1, v_promo), pg_temp.it(v_c, 1)));
  v_fallas := v_fallas || pg_temp.chk(v_j ? 'success' AND NOT pg_temp.ok(v_j)
                                      AND v_j->'errores'->>0 LIKE '%: stock insuficiente (disponible: 0, adicional: 1)'
                                      AND pg_temp.foto(v_c) = 'stock=0 lotes=[0] bolsa=0 huella=0' AND pg_temp.vivos(v_promo) = 2,
    'J3 · sin bajar la barra, el rechazo de siempre (success=false, «stock insuficiente (disponible: 0, adicional: 1)»): '
      || v_j::text || ' ' || pg_temp.foto(v_c));

  -- ======================================================= J4 · N3 ===
  v_v := pg_temp.prod(100, 500, '{}', 'ZZ t6j venta');
  v_r := pg_temp.prod(100, 500, '{}', 'ZZ t6j rubro D');
  v_w := pg_temp.prod(50, 500, '{}', 'ZZ t6j rubro D');
  v_z := pg_temp.prod(5000, 500, '{}', 'ZZ t6j perfumes');
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ t6j promo', 'bonificacion', public._tablero_hoy() - 1, 1, true, v_r) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 5, 1), (v_promo, 'cantidad_bonificacion', 2, 1);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_v, 1);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_v, 10), pg_temp.reg(v_w, 4, v_promo)));
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
  v_j := pg_temp.como(format('SELECT public.sustituir_regalo_pedido(%s, %s, 4, %L, NULL, NULL)::text', v_item, v_z, 'ensayo t6j'))::jsonb;
  IF NOT pg_temp.ok(v_j) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture J4: el admin tenía que poder cambiar W×4 por Z×4: %', v_j;
  END IF;
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_v, 5),
           pg_temp.reg(v_w, 2, v_promo) || jsonb_build_object('_cadena',
             (SELECT regalo_cadena_id FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion))));
  v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.ok(v_j) AND v_j->>'codigo' = 'regalo_sustituto_sobre_tope'
                                      AND v_j->'errores'->>0 LIKE '%ahora («' || (SELECT nombre FROM productos WHERE id = v_r) || '» × 2)%',
    'J4 · el rechazo tenía que nombrar el regalo con el que mide (R), no el del renglón (W): ' || v_j::text);

  -- ------------------------------------------------------------- veredicto ---
  SET CONSTRAINTS ALL IMMEDIATE;
  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · tanda 6 bis, tarjeta J (J1a J1b J1c J1d J1e J1f J2 J3 J4)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ · %', array_to_string(v_fallas, E'\n  · ');
END
$ensayo$;
