-- Ensayo de la migración NNN_venta_edicion_alta_cobro_y_dashboard (plan #1603, tanda 6 bis,
-- tarjeta H: lo que la tanda 6 dejó sin hacer en la edición del pedido, el alta, el cobro
-- combinado y el Dashboard del preventista).
--
-- No deja rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una excepción.
-- Antes de aplicar la migración tiene que FALLAR en H1a, H3a, H3b, H4 y H5; después, dar
-- 'ENSAYO OK'. H1b (la cancelación después de H1a), H1c, H1d, H1e y H2 son controles: pasan antes
-- (H1b, sobre el pedido que H1a no pudo editar) y después.
-- Corre en una base local con la semilla mínima (un admin activo de las sucursales 1 y 2) o en
-- una copia de prod. Usa el día argentino (_tablero_hoy()) y no depende de la hora: las altas y
-- las ediciones las hace un ENCARGADO (sin el corte de las 15:30 del preventista).
--
-- H1 · stock-STK-2: la edición rechazaba un cambio de neto 0 cuando el contenedor de la barra
--   estaba en 0. Promo de fracción «10 A dan 2 S» (S no mueve stock), contenedor C con un lote de
--   2 y la bolsa en 0, 2 unidades de S por bloque y 1 C por bloque. El alta A×20 + S×4 cierra dos
--   bloques: C queda en 0.
--   H1a · editar a A×10 + S×2 + C×1 (la barra devuelve un fardo y la línea vende uno: neto 0)
--         ENTRA: C sigue en 0, su lote en 0 y la bolsa en 0; la línea de C lleva la huella de ese
--         lote (1); queda un bloque vivo; el ledger cierra y A queda en 990.
--   H1b · cancelar ese pedido deja todo como antes del alta: C 2 (lote 2, bolsa 0), A 1000, sin
--         bloques vivos ni huella.
--   H1c · control: editar a A×10 + S×2 + C×2 (la barra devuelve 1 y hacen falta 2) se sigue
--         rechazando por stock, y el pedido, C y la barra no cambian.
--   H1d · control (lo que hoy entra da lo mismo): editar a A×10 + S×2, sin C, entra; el fardo
--         vuelve a su lote (C 1, lote 1, bolsa 0) y queda un bloque vivo.
--   H1e · control: la falta de stock de un producto que no es contenedor se sigue rechazando con
--         el mensaje de siempre, sin tocar nada.
-- H2 · residual de promos-B6 (no hacía falta: el segundo chequeo mide el corte guardado, que es lo
--   que el paso 4 conserva). Promo de unidad entera «10 V dan 10 R» que mueve stock; V×10 + R×10;
--   R×10 cambiado por valor a W×1 (corte 10); la promo se apaga.
--   H2a · V×20 + W×1 entra y el regalo sigue W×1 con corte 10 (no crece a 20).
--   H2b · V×20 + R×20 se rechaza («ya no rige»).
--   H2c · V×5 + W×1 se rechaza (bajar la venta lo recorta, como siempre). W sigue en 499.
-- H3 · venta-B4 en el alta: un renglón sin producto.
--   H3a · crear_pedido_completo contesta success=false con «Hay un renglón sin producto…» y no crea
--         el pedido (antes: «key must not be null», crudo).
--   H3b · crear_pedido_completo_bot, igual (en su clave 'error'), y la confirmación no se consume.
-- H4 · gemelo de cobros-B4: el FIFO combinado de la ficha con un cliente de otra sucursal dice
--   «Cliente no encontrado» (P0002) y no un 23503. Control: con un cliente de la sucursal, entra.
-- H5 · Dashboard del preventista neto (decisión del dueño del 24/11). La RPC
--   notas_credito_venta_del_vendedor le da a quien actúa como preventista la fecha, el cliente y
--   el total de cada nota vigente de una boleta que es venta y que ÉL vendió, en la sucursal activa.
--   P vende B1 ($ 1.050, entregada) con una nota de $ 350; Q vende B2 con una nota de $ 100; P
--   tiene además una nota anulada en B3, una nota en B4 (sin entregar) y una en B5 (vale blanco).
--   H5a · P ve sólo la de $ 350 (fecha, cliente, total; nada más), con y sin filtro de cliente.
--   H5b · fuera de rango, con otro cliente o parado en otra sucursal, nada.
--   H5c · admin, encargado y transportista: nada (los dos primeros leen por REST).
--   H5d · anon no la puede llamar; P desactivado no ve nada.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-venta-tanda6bis-1603.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_enc    uuid := gen_random_uuid();
  v_tra    uuid := gen_random_uuid();
  v_pre    uuid := gen_random_uuid();
  v_pre2   uuid := gen_random_uuid();
  v_cli    bigint;
  v_cli2   bigint;
  v_clib   bigint;
  e        jsonb;
  v_ped    bigint;
  v_b      bigint[];
  v_a      bigint;
  v_v      bigint;
  v_r      bigint;
  v_w      bigint;
  v_x      bigint;
  v_promo  bigint;
  v_item   bigint;
  v_n      int;
  v_t      text;
  v_j      jsonb;
  v_antes  text;
  v_conf   uuid;
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------------------------- personas ---
  SELECT p.id INTO v_adm
    FROM perfiles p
   WHERE p.rol = 'admin' AND p.activo
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = 1)
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = 2)
   ORDER BY p.id LIMIT 1;
  IF v_adm IS NULL OR (SELECT count(*) FROM sucursales WHERE id IN (1, 2) AND activa) < 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de las sucursales 1 y 2, activas';
  END IF;
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6h-' || u.id || '@ensayo.invalid',
         jsonb_build_object('rol', u.rol, 'sucursal_id', 1), '{}', now(), now()
    FROM (VALUES (v_enc, 'encargado'), (v_tra, 'transportista'), (v_pre, 'preventista'), (v_pre2, 'preventista')) AS u(id, rol);
  PERFORM set_config('et6h.adm', v_adm::text, true);

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.limpiar() RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('app.stock_origen', '', true), set_config('app.stock_ref_tipo', '', true),
           set_config('app.stock_ref_id', '', true), set_config('app.stock_user_id', '', true),
           set_config('app.stock_pedido_item_id', '', true), set_config('app.omitir_minimo_venta', '', true),
           set_config('app.regalo_corte_manual', '', true), set_config('app.cambio_cliente_desde', '', true);
  $f$;
  -- Una RPC como el front: rol authenticated (anon si p_anon), como p_uid (el admin si es NULL), parado en p_suc.
  CREATE FUNCTION pg_temp.como(p_sql text, p_uid uuid DEFAULT NULL, p_suc bigint DEFAULT 1, p_anon boolean DEFAULT false)
  RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', COALESCE(p_uid, current_setting('et6h.adm')::uuid),
                        'role', CASE WHEN p_anon THEN 'anon' ELSE 'authenticated' END)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    IF p_anon THEN SET LOCAL ROLE anon; ELSE SET LOCAL ROLE authenticated; END IF;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    RETURN v;
  END $f$;
  -- NULL si anda; si no, 'SQLSTATE: mensaje' (y lo que hizo se deshace).
  CREATE FUNCTION pg_temp.err(p_sql text, p_uid uuid DEFAULT NULL, p_suc bigint DEFAULT 1, p_anon boolean DEFAULT false)
  RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_sql, p_uid, p_suc, p_anon);
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    RETURN SQLSTATE || ': ' || SQLERRM;
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
  -- Producto con p_bolsa sin lote y, si p_lote > 0, un lote de 100 con p_lote restantes.
  CREATE FUNCTION pg_temp.prod(p_precio numeric, p_bolsa int, p_lote int DEFAULT 0, p_cat text DEFAULT NULL)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v bigint;
  BEGIN
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id, categoria)
    VALUES ('ZZ t6h ' || gen_random_uuid(), p_precio, p_bolsa + p_lote, 50, 50, 50, 50, 1, p_cat) RETURNING id INTO v;
    IF p_lote > 0 THEN
      INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
      VALUES (v, 1, public._tablero_hoy() + 30, 100, p_lote, 'manual');
    END IF;
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.cli(p_suc bigint DEFAULT 1) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('ZZ t6h', 'ZZ t6h ' || gen_random_uuid(), 'calle 1', p_suc) RETURNING id;
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
  -- La cancelación la hace el admin (es el único que cancela): NULL si entró, si no el motivo.
  CREATE FUNCTION pg_temp.cancelar(p_ped bigint) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v jsonb;
  BEGIN
    v := pg_temp.como(format('SELECT public.cancelar_pedido_con_stock(%s, %L, %L, NULL)::text',
                             p_ped, 'ensayo t6h', current_setting('et6h.adm')))::jsonb;
    RETURN CASE WHEN pg_temp.ok(v) THEN NULL ELSE v::text END;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    RETURN SQLSTATE || ': ' || SQLERRM;
  END $f$;
  -- La foto de un producto: stock, lotes (restante), bolsa, huella por lote, y si el ledger cierra.
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('stock=%s lotes=[%s] bolsa=%s huella=[%s]%s', p.stock,
      COALESCE((SELECT string_agg(cantidad_restante::text, ',' ORDER BY fecha_vencimiento, id)
                  FROM public.producto_lotes WHERE producto_id = p_prod), ''),
      p.stock - COALESCE((SELECT sum(cantidad_restante) FROM public.producto_lotes WHERE producto_id = p_prod), 0),
      COALESCE((SELECT string_agg(x.c::text, ',' ORDER BY x.lote_id)
                  FROM (SELECT pil.lote_id, sum(pil.cantidad) c FROM public.pedido_item_lotes pil
                          JOIN public.producto_lotes l ON l.id = pil.lote_id
                         WHERE l.producto_id = p_prod GROUP BY 1) x), ''),
      CASE WHEN (SELECT stock_nuevo FROM public.stock_historico WHERE producto_id = p_prod ORDER BY id DESC LIMIT 1)
                IS DISTINCT FROM p.stock THEN ' LEDGER≠STOCK' ELSE '' END)
      FROM public.productos p WHERE p.id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.vivos(p_promo bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT COALESCE(sum(bloques_vivos), 0)::int FROM public.promo_ajustes WHERE promocion_id = p_promo AND bloques_vivos > 0;
  $f$;
  CREATE FUNCTION pg_temp.lin(p_ped bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(format('%s×%s%s', producto_id, cantidad, CASE WHEN es_bonificacion THEN 'R' ELSE '' END), ' '
                      ORDER BY producto_id, cantidad)
      FROM public.pedido_items WHERE pedido_id = p_ped;
  $f$;
  -- H1: A, S y C; la promo de fracción y el alta A×20 + S×4 del encargado. C queda en 0.
  CREATE FUNCTION pg_temp.h1(p_enc uuid, p_cli bigint) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    a bigint := pg_temp.prod(100, 1000);
    s bigint := pg_temp.prod(100, 100);
    c bigint := pg_temp.prod(100, 0, 2);
    p bigint;
    ped bigint;
  BEGIN
    INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                                    ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque,
                                    descripcion_regalo)
    VALUES ('ZZ t6h barra', 'bonificacion', public._tablero_hoy() - 1, 1, false, s, true, c, 2, 1, '1 unidad de ensayo')
    RETURNING id INTO p;
    INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (p, 'cantidad_compra', 10, 1), (p, 'cantidad_bonificacion', 2, 1);
    INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (p, a, 1);
    ped := pg_temp.alta(p_enc, p_cli, jsonb_build_array(pg_temp.it(a, 20), pg_temp.reg(s, 4, p)));
    RETURN jsonb_build_object('a', a, 's', s, 'c', c, 'p', p, 'ped', ped);
  END $f$;

  v_cli  := pg_temp.cli(1);
  v_cli2 := pg_temp.cli(2);

  -- ==================================================== H1 · stock-STK-2 ===
  e := pg_temp.h1(v_enc, v_cli);
  IF pg_temp.foto((e->>'c')::bigint) <> 'stock=0 lotes=[0] bolsa=0 huella=[]' OR pg_temp.vivos((e->>'p')::bigint) <> 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture H1: C tenía que quedar en 0 con 2 bloques vivos: % (vivos %)',
      pg_temp.foto((e->>'c')::bigint), pg_temp.vivos((e->>'p')::bigint);
  END IF;
  -- H1a: neto 0 sobre el contenedor.
  v_j := pg_temp.edit(v_enc, (e->>'ped')::bigint, jsonb_build_array(
           pg_temp.it((e->>'a')::bigint, 10), pg_temp.reg((e->>'s')::bigint, 2, (e->>'p')::bigint), pg_temp.it((e->>'c')::bigint, 1)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j),
    'H1a · A×10 + S×2 + C×1 (la barra devuelve un fardo y la línea vende uno) tenía que entrar: ' || v_j::text);
  v_fallas := v_fallas || pg_temp.chk(pg_temp.foto((e->>'c')::bigint) = 'stock=0 lotes=[0] bolsa=0 huella=[1]',
    'H1a · C tenía que quedar stock 0, lote 0, bolsa 0 y la huella de la línea en su lote: ' || pg_temp.foto((e->>'c')::bigint));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.vivos((e->>'p')::bigint) = 1,
    'H1a · tenía que quedar un bloque vivo: ' || pg_temp.vivos((e->>'p')::bigint));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.foto((e->>'a')::bigint) = 'stock=990 lotes=[] bolsa=990 huella=[]',
    'H1a · A tenía que quedar en 990: ' || pg_temp.foto((e->>'a')::bigint));
  -- H1b: cancelar deja todo como antes del alta.
  v_t := pg_temp.cancelar((e->>'ped')::bigint);
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'H1b · la cancelación tenía que entrar: ' || COALESCE(v_t, ''));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.foto((e->>'c')::bigint) = 'stock=2 lotes=[2] bolsa=0 huella=[]'
                                      AND pg_temp.vivos((e->>'p')::bigint) = 0
                                      AND pg_temp.foto((e->>'a')::bigint) = 'stock=1000 lotes=[] bolsa=1000 huella=[]',
    format('H1b · cancelar tenía que dejar C 2 en su lote, A 1000 y ningún bloque vivo: C %s · A %s · vivos %s',
           pg_temp.foto((e->>'c')::bigint), pg_temp.foto((e->>'a')::bigint), pg_temp.vivos((e->>'p')::bigint)));

  -- H1c (control): la barra devuelve 1 y hacen falta 2: se sigue rechazando por stock.
  e := pg_temp.h1(v_enc, v_cli);
  v_antes := pg_temp.lin((e->>'ped')::bigint) || ' | ' || pg_temp.foto((e->>'c')::bigint) || ' | ' || pg_temp.vivos((e->>'p')::bigint);
  v_j := pg_temp.edit(v_enc, (e->>'ped')::bigint, jsonb_build_array(
           pg_temp.it((e->>'a')::bigint, 10), pg_temp.reg((e->>'s')::bigint, 2, (e->>'p')::bigint), pg_temp.it((e->>'c')::bigint, 2)));
  v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.ok(v_j) AND v_j::text LIKE '%stock insuficiente%',
    'H1c · A×10 + S×2 + C×2 tenía que rechazarse por stock: ' || v_j::text);
  v_fallas := v_fallas || pg_temp.chk(pg_temp.lin((e->>'ped')::bigint) || ' | ' || pg_temp.foto((e->>'c')::bigint) || ' | '
                                      || pg_temp.vivos((e->>'p')::bigint) = v_antes,
    'H1c · el pedido, C y la barra no tenían que cambiar: antes ' || v_antes || ' · después '
    || pg_temp.lin((e->>'ped')::bigint) || ' | ' || pg_temp.foto((e->>'c')::bigint) || ' | ' || pg_temp.vivos((e->>'p')::bigint));
  PERFORM pg_temp.cancelar((e->>'ped')::bigint);

  -- H1d (control): sin C, como siempre: el fardo vuelve a su lote.
  e := pg_temp.h1(v_enc, v_cli);
  v_j := pg_temp.edit(v_enc, (e->>'ped')::bigint, jsonb_build_array(
           pg_temp.it((e->>'a')::bigint, 10), pg_temp.reg((e->>'s')::bigint, 2, (e->>'p')::bigint)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j)
                                      AND pg_temp.foto((e->>'c')::bigint) = 'stock=1 lotes=[1] bolsa=0 huella=[]'
                                      AND pg_temp.vivos((e->>'p')::bigint) = 1,
    format('H1d · A×10 + S×2 tenía que entrar y devolver el fardo a su lote: %s · C %s · vivos %s',
           v_j, pg_temp.foto((e->>'c')::bigint), pg_temp.vivos((e->>'p')::bigint)));
  PERFORM pg_temp.cancelar((e->>'ped')::bigint);

  -- H1e (control): un producto sin stock que no es contenedor, con el mensaje de siempre.
  e := pg_temp.h1(v_enc, v_cli);
  v_x := pg_temp.prod(100, 0);
  v_antes := pg_temp.lin((e->>'ped')::bigint) || ' | ' || pg_temp.foto((e->>'c')::bigint) || ' | ' || pg_temp.vivos((e->>'p')::bigint);
  v_j := pg_temp.edit(v_enc, (e->>'ped')::bigint, jsonb_build_array(
           pg_temp.it((e->>'a')::bigint, 10), pg_temp.reg((e->>'s')::bigint, 2, (e->>'p')::bigint), pg_temp.it(v_x, 1)));
  v_fallas := v_fallas || pg_temp.chk(v_j ? 'success' AND NOT pg_temp.ok(v_j)
                                      AND v_j::text LIKE '%stock insuficiente (disponible: 0, adicional: 1)%'
                                      AND pg_temp.lin((e->>'ped')::bigint) || ' | ' || pg_temp.foto((e->>'c')::bigint) || ' | '
                                          || pg_temp.vivos((e->>'p')::bigint) = v_antes,
    'H1e · la falta de stock de un producto que no es contenedor tenía que rechazarse como siempre, sin tocar nada: ' || v_j::text);
  PERFORM pg_temp.cancelar((e->>'ped')::bigint);

  -- ================================================ H2 · residual promos-B6 ===
  v_v := pg_temp.prod(100, 500, 0, 'ZZ t6h venta');
  v_r := pg_temp.prod(10, 500, 0, 'ZZ t6h regalo');
  v_w := pg_temp.prod(100, 500, 0, 'ZZ t6h regalo');
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ t6h apagada', 'bonificacion', v_hoy - 1, 1, true, v_r) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, 1), (v_promo, 'cantidad_bonificacion', 10, 1);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_v, 1);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_v, 10), pg_temp.reg(v_r, 10, v_promo)));
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
  v_t := pg_temp.err(format('SELECT public.sustituir_regalo_pedido(%s, %s, 1, %L, NULL, NULL)::text', v_item, v_w, 'ensayo t6h'), v_enc);
  IF v_t IS NOT NULL OR NOT EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion
                                       AND producto_id = v_w AND cantidad = 1 AND regalo_corte = 10) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture H2: R×10 tenía que quedar W×1 con corte 10: % · %', v_t, pg_temp.lin(v_ped);
  END IF;
  UPDATE promociones SET activo = false WHERE id = v_promo;
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_v, 20), pg_temp.reg(v_w, 1, v_promo)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j)
                                      AND EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion
                                                     AND producto_id = v_w AND cantidad = 1 AND regalo_corte = 10)
                                      AND (SELECT count(*) FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion) = 1,
    format('H2a · V×20 + W×1 con la promo apagada tenía que entrar y conservar W×1 con corte 10: %s · %s', v_j, pg_temp.lin(v_ped)));
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_v, 20), pg_temp.reg(v_r, 20, v_promo)));
  v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.ok(v_j) AND v_j::text LIKE '%ya no rige%',
    'H2b · V×20 + R×20 con la promo apagada no puede crecer: ' || v_j::text);
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_v, 5), pg_temp.reg(v_w, 1, v_promo)));
  v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.ok(v_j),
    'H2c · V×5 + W×1 (corte 10) tenía que rechazarse: ' || v_j::text);
  v_fallas := v_fallas || pg_temp.chk((SELECT stock FROM productos WHERE id = v_w) = 499 AND (SELECT stock FROM productos WHERE id = v_r) = 500,
    format('H2 · W tenía que seguir en 499 y R en 500: W %s · R %s',
           (SELECT stock FROM productos WHERE id = v_w), (SELECT stock FROM productos WHERE id = v_r)));

  -- ===================================================== H3 · venta-B4 alta ===
  v_a := pg_temp.prod(100, 1000);
  v_clib := pg_temp.cli(1);
  BEGIN
    v_j := pg_temp.como(format('SELECT public.crear_pedido_completo(p_cliente_id => %s, p_total => 200, p_usuario_id => %L, p_items => %L::jsonb)::text',
                               v_clib, v_enc, jsonb_build_array(pg_temp.it(v_a, 1),
                                                                jsonb_build_object('producto_id', NULL, 'cantidad', 1, 'precio_unitario', 100))),
                        v_enc)::jsonb;
    v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.ok(v_j) AND v_j::text LIKE '%Hay un renglón sin producto%',
                                        'H3a · el alta con un renglón sin producto tenía que rechazarse con su motivo: ' || v_j::text);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    v_fallas := v_fallas || ('H3a · el alta con un renglón sin producto dio un error crudo: ' || SQLERRM);
  END;
  v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM pedidos WHERE cliente_id = v_clib)
                                      AND (SELECT stock FROM productos WHERE id = v_a) = 1000,
                                      'H3a · no tenía que crearse ningún pedido ni moverse el stock');
  -- El bot: la confirmación pendiente con un renglón sin producto.
  INSERT INTO bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total, cargo_mostrado)
  VALUES (v_enc, 1, v_clib,
          jsonb_build_array(pg_temp.it(v_a, 1), jsonb_build_object('cantidad', 1, 'precio_unitario', 100)),
          200, public.pedido_cargo_envio(200, 1))
  RETURNING id INTO v_conf;
  BEGIN
    v_j := public.crear_pedido_completo_bot(v_enc, v_conf);
    PERFORM pg_temp.limpiar();
    v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.ok(v_j) AND COALESCE(v_j->>'error', '') LIKE '%Hay un renglón sin producto%',
                                        'H3b · el bot con un renglón sin producto tenía que rechazarse con su motivo: ' || v_j::text);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.limpiar();
    v_fallas := v_fallas || ('H3b · el bot con un renglón sin producto dio un error crudo: ' || SQLERRM);
  END;
  v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM pedidos WHERE cliente_id = v_clib)
                                      AND NOT (SELECT consumido FROM bot_pedidos_pendientes WHERE id = v_conf),
                                      'H3b · el bot no tenía que crear el pedido ni consumir la confirmación');

  -- ================================================ H4 · cobro combinado ===
  v_t := pg_temp.err(format('SELECT public.registrar_pago_combinado_cliente_fifo(%s, %L::jsonb)::text', v_cli2,
                            jsonb_build_array(jsonb_build_object('forma_pago', 'efectivo', 'monto', 100))));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE 'P0002:%Cliente no encontrado%',
    'H4 · el FIFO combinado con un cliente de otra sucursal tenía que decir «Cliente no encontrado» (P0002): ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('SELECT public.registrar_pago_combinado_cliente_fifo(%s, %L::jsonb)::text', v_clib,
                            jsonb_build_array(jsonb_build_object('forma_pago', 'efectivo', 'monto', 100))));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = v_clib) = 100,
    'H4 · el FIFO combinado con un cliente de la sucursal tenía que entrar: ' || COALESCE(v_t, ''));

  -- ======================================== H5 · Dashboard del preventista ===
  v_a := pg_temp.prod(350, 1000);
  v_b := '{}';
  -- B1 (P, entregada, $ 1.050), B2 (Q, entregada), B3 (P, entregada), B4 (P, sin entregar), B5 (P, vale blanco).
  FOR v_n IN 1..5 LOOP
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura, retiro_deposito, fecha_entrega)
    VALUES (v_cli, 1, CASE WHEN v_n = 2 THEN v_pre2 ELSE v_pre END, 1050,
            CASE WHEN v_n = 4 THEN 'pendiente' ELSE 'entregado' END, v_hoy, 'app',
            CASE WHEN v_n = 5 THEN 'VB' ELSE 'ZZ' END, true, CASE WHEN v_n <> 4 THEN now() END)
    RETURNING id INTO v_ped;
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
    VALUES (v_ped, v_a, 3, 350, 1050, 1, 50) RETURNING id INTO v_item;
    v_b := v_b || v_ped;
    INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
    VALUES (1, v_cli, v_ped, v_hoy, 'otro', CASE WHEN v_n = 2 THEN 100 ELSE 350 END, v_adm,
            CASE WHEN v_n = 2 THEN 100 ELSE 350 END, 0)
    RETURNING id INTO v_x;
    INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad, precio_unitario, subtotal)
    VALUES (v_x, 1, v_item, v_a, 1, 350, CASE WHEN v_n = 2 THEN 100 ELSE 350 END);
    IF v_n = 3 THEN
      UPDATE notas_credito_venta SET anulada = true, anulada_at = now() WHERE id = v_x;
    END IF;
  END LOOP;
  SET CONSTRAINTS ALL IMMEDIATE;
  -- H5a
  v_t := pg_temp.err(format('SELECT jsonb_agg(to_jsonb(x))::text FROM public.notas_credito_venta_del_vendedor(%L::date, NULL) x', v_hoy - 7), v_pre);
  IF v_t IS NOT NULL THEN
    v_fallas := v_fallas || ('H5 · la RPC del Dashboard del preventista no anda: ' || v_t);
  ELSE
    v_j := pg_temp.como(format('SELECT jsonb_agg(to_jsonb(x))::text FROM public.notas_credito_venta_del_vendedor(%L::date, NULL) x', v_hoy - 7), v_pre)::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j = jsonb_build_array(jsonb_build_object('fecha', v_hoy, 'cliente_id', v_cli, 'total', 350.00)),
      'H5a · P tenía que ver sólo la nota de $ 350 de B1 (fecha, cliente y total): ' || COALESCE(v_j::text, 'nada'));
    v_j := pg_temp.como(format('SELECT jsonb_agg(to_jsonb(x))::text FROM public.notas_credito_venta_del_vendedor(NULL, NULL, %s) x', v_cli), v_pre)::jsonb;
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(COALESCE(v_j, '[]')) = 1 AND (v_j->0->>'total')::numeric = 350,
      'H5a · con el filtro del cliente, la misma nota: ' || COALESCE(v_j::text, 'nada'));
    v_fallas := v_fallas || pg_temp.chk(pg_get_function_result('public.notas_credito_venta_del_vendedor(date,date,bigint)'::regprocedure)
                                        = 'TABLE(fecha date, cliente_id bigint, total numeric)',
      'H5a · la RPC devuelve sólo fecha, cliente y total: '
      || pg_get_function_result('public.notas_credito_venta_del_vendedor(date,date,bigint)'::regprocedure));
    -- H5b
    v_fallas := v_fallas || pg_temp.chk(
      pg_temp.como(format('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor(%L::date, NULL)', v_hoy + 1), v_pre) = '0'
      AND pg_temp.como(format('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor(NULL, %L::date)', v_hoy - 1), v_pre) = '0'
      AND pg_temp.como(format('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor(NULL, NULL, %s)', v_clib), v_pre) = '0',
      'H5b · fuera del rango o con otro cliente no tenía que ver nada');
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_pre, 2) ON CONFLICT DO NOTHING;
    v_fallas := v_fallas || pg_temp.chk(
      pg_temp.como('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor()', v_pre, 2) = '0',
      'H5b · parado en la sucursal 2 no tenía que ver las notas de la 1');
    -- H5c
    v_fallas := v_fallas || pg_temp.chk(
      pg_temp.como('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor()', v_adm) = '0'
      AND pg_temp.como('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor()', v_enc) = '0'
      AND pg_temp.como('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor()', v_tra) = '0'
      AND pg_temp.como('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor()', v_pre2) = '1',
      'H5c · admin, encargado y transportista no ven nada por la RPC; Q ve la suya');
    -- H5d
    v_t := pg_temp.err('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor()', v_pre, 1, true);
    v_fallas := v_fallas || pg_temp.chk(v_t LIKE '42501:%', 'H5d · anon no la puede llamar: ' || COALESCE(v_t, 'entró'));
    -- La baja la da el admin (prevenir_autoescalada_perfil mira quién la da). El sync con
    -- auth.users (el ban) pide una columna que la base local no tiene: se apaga para esto.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
    ALTER TABLE public.perfiles DISABLE TRIGGER trg_perfiles_sync_acceso_auth;
    UPDATE perfiles SET activo = false WHERE id = v_pre;
    ALTER TABLE public.perfiles ENABLE TRIGGER trg_perfiles_sync_acceso_auth;
    v_fallas := v_fallas || pg_temp.chk(
      pg_temp.como('SELECT count(*)::text FROM public.notas_credito_venta_del_vendedor()', v_pre) = '0',
      'H5d · un preventista desactivado no ve nada');
  END IF;

  -- ------------------------------------------------------------- veredicto ---
  SET CONSTRAINTS ALL IMMEDIATE;
  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · tanda 6 bis, tarjeta H (H1a H1b H1c H1d H1e H2 H3a H3b H4 H5)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ · %', array_to_string(v_fallas, E'\n  · ');
END
$ensayo$;
