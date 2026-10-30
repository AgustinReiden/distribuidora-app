-- Ensayo de #1251, #1252, #1253 y #1294: el costo promedio y la reposición
-- después de editar, anular y cambiar el proveedor de una compra, una vez o
-- varias sobre la misma cadena.
--
-- Hasta este ensayo ninguno miraba costo_promedio después de editar o anular.
-- La edición armaba la base con el stock de HOY (p.stock − la compra) y la
-- foto del alta del promedio; anular no tocaba el promedio; el clon del cambio
-- de proveedor perdía la foto; el empate de fecha y los regalos trababan la
-- reposición; y una factura B quedaba como 'FC'.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en
-- RAISE EXCEPTION, así que todo lo que crea (productos, compras) se deshace.
-- Usa un admin real de una sucursal activa y productos propios del ensayo.
-- Las compras son ZZ salvo donde se dice: el costo real es el costo unitario.
--
-- Casos (cada uno con sus productos). "P" es la compra que se edita o anula.
--   E1 · editar sin cambios no mueve el promedio (el 275 de la 6319). 100 u. a
--        10 + P 100 a 20 = 15; se venden 50; editar sin cambios: sigue 15 y la
--        línea conserva el stock del alta (100). Antes: 16,6667 y stock 150.
--   E2 · editar el costo con una compra posterior del mismo día. 100 a 10;
--        P 100 a 20 → 15; P2 100 a 30 → 20; P pasa a 14 → 12 y P2 arriba = 18.
--        La reposición sigue siendo la de P2 (30): el empate es por id.
--   E3 · editar la cantidad con venta y compra posterior. 100 a 10; P 100 a 20
--        → 15; se venden 100; P2 100 a 30 → 22,5; P pasa a 50 u. → 13,3333 y
--        P2 arriba (con 50 de base) = 24,4444. Stock 150.
--   E4 · el producto que sale de la compra devuelve el promedio y la
--        reposición. P0: 100 a 10; P: 100 a 20 (→ 15, costo 20) más otro
--        producto; se saca de P: promedio 10, costo real 10, stock 100.
--   E5 · el producto que se agrega en la edición entra ahora: 50 a 8, se agrega
--        50 a 12 → 10.
--   E6 · compra anterior a la 236 (sin foto): la edición avisa sin_cpp_previo
--        y no mueve el promedio.
--   A1 · anular devuelve el promedio: 100 a 10 + P 100 a 20 = 15 → anular: 10.
--   A2 · anular con una compra posterior: 100 a 10; P 100 a 20 → 15; P2 50 a
--        30 → 18; anular P → (100 × 10 + 50 × 30) / 150 = 16,6667. Stock 150.
--   A3 · anular respeta una corrección a mano: 15 corregido a 16 en la ficha;
--        anular P → 16 + (10 − 15) = 11.
--   A4 · anular la única compra de un producto nuevo: sin promedio (NULL), y
--        avisa que no hay costo de referencia.
--   A5 · anular una compra que no fijaba la reposición no la toca: P0 (hace 2
--        días) a 10, P1 (hoy) a 20; anular P0: el costo real sigue en 20.
--   C1 · cambiar el proveedor conserva la foto y la fecha de alta: el clon
--        tiene costo_promedio_anterior 10, stock_anterior 100 y el created_at
--        de la original; editarlo recalcula sin aviso (100 a 10 + 100 a 14 = 12).
--   R1 · un regalo con fecha posterior no traba la reposición: A (hace 10
--        días) a 10, regalo (hoy), C (hace 5 días) a 15 → costo real 15.
--   R2 · la factura B queda 'FC B' con costo con IVA = lo pagado (121); anular
--        la FC A que vino después la devuelve a 'FC B' y 121.
--   R3 · registrar_compra_completa bloquea los productos en orden de id antes
--        del loop (#1255).
--
-- Dos correcciones sobre la misma cadena (#1294 CMP-N1). La primera tiene que
-- pasar las fotos de las compras posteriores a la historia corregida; si no,
-- la segunda arrastra desde la historia vieja. Todas arrancan de "stock 100 a
-- 10" salvo D3.
--   D1 · editar y después anular la posterior. A 100 a 10 y B 100 a 20 =
--        13,3333; A pasa a 16 → 15,3333 y la foto de B a 13; anular B → 13
--        (antes 12).
--   D2 · editar el costo y después la cantidad. Igual que D1; A a 16 →
--        15,3333; A a 50 u. → 15,2 (antes 15,4), con la foto de B en 150 y 12;
--        anular B → 12. Es la tercera corrección y prueba la foto del stock.
--   D3 · la primera compra del producto, editada dos veces y anulada. A 100 a
--        10 y B 100 a 30 = 20; A a 50 u. → 23,3333; A a 20 → 26,6667 (antes
--        28,3333); anular A → 30.
--   D4 · una corrección a mano entre A y B sobrevive a dos correcciones. A 100
--        a 10, la ficha lo pasa a 12, B 100 a 20 → 14,6667; A a 16 → 16,6667;
--        anular B → 15 (13 + los 2 de la ficha; antes 14).
--   D5 · B entró con stock 0 y reseteó el promedio. A 100 a 20 → 15, se vende
--        todo, B 100 a 30 → 30; A a 150 u. → 25,3333 (B ya no entra sobre 0);
--        anular B → 16 (antes 10,3333).
--   D6 · la posterior es el clon de un cambio de proveedor. Igual que D1, pero
--        a B se le cambia el proveedor antes de editar A; anular el clon → 13.
--
-- El desempate de la reposición con un clon del mismo día (#1294 CMP-N2). En
-- prod cada compra tiene la hora de su alta; acá todas nacen en la misma
-- transacción, así que se les fija a mano.
--   N1 · X (hace 2 h) a 10 e Y (hace 1 h) a 12, del mismo día: reposición 12.
--        Se le cambia el proveedor a X y se edita el clon sin cambios: sigue
--        12 (antes 10).
--   N2 · igual, y se anula Y: vuelve a 10, la del clon (antes quedaba 12).
--   N3 · X, Y y Z (a 14) del mismo día, clon de X, se anula Z: vuelve a 12, la
--        de Y (antes 14, y con sólo el desempate arreglado, 10).
--
-- Veredicto: NOTICE 'ENSAYO OK (todo revertido)', o el error 'ENSAYO FALLÓ …'
-- con la lista de fallas. En los dos casos no queda nada escrito.
--
--   psql "$DATABASE_URL" -f scripts/test-promedio-compras-1251-1252-1253.sql

DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_x       bigint;
  v_y       bigint;
  v_p0      bigint;
  v_p       bigint;
  v_p2      bigint;
  v_p3      bigint;
  v_clon    bigint;
  v_res     jsonb;
  v_fila    record;
  v_fallas  text[] := '{}';
BEGIN
 BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- Un producto con stock y promedio (el costo de reposición, igual al promedio).
  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text, p_stock int, p_cpp numeric)
  RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real,
                                  costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES (p_nombre, 100, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, p_suc) RETURNING id;
  $f$;

  -- Las líneas en el formato de las RPCs: [{producto_id, cantidad, costo_unitario,
  -- bonificacion?}], con el subtotal y la alícuota de IVA.
  CREATE FUNCTION pg_temp.lineas(p_items jsonb, p_iva numeric) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(e || jsonb_build_object(
             'bonificacion',       COALESCE((e->>'bonificacion')::numeric, 0),
             'porcentaje_iva',     p_iva,
             'impuestos_internos', 0,
             'subtotal', round((e->>'cantidad')::numeric * (e->>'costo_unitario')::numeric
                               * (1 - COALESCE((e->>'bonificacion')::numeric, 0) / 100), 2))
             ORDER BY o)
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o);
  $f$;
  CREATE FUNCTION pg_temp.subtotal(p_lineas jsonb) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum((e->>'subtotal')::numeric), 0) FROM jsonb_array_elements(p_lineas) e;
  $f$;

  -- Registra una compra y devuelve su id (falla si la RPC no la acepta).
  CREATE FUNCTION pg_temp.comprar(p_admin uuid, p_ref text, p_fecha date, p_items jsonb,
                                  p_tipo text DEFAULT 'ZZ', p_letra text DEFAULT NULL,
                                  p_iva numeric DEFAULT 0)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_lin jsonb := pg_temp.lineas(p_items, p_iva);
    v_sub numeric := pg_temp.subtotal(v_lin);
    v_iva numeric := round(pg_temp.subtotal(v_lin) * p_iva / 100, 2);
    v_r   jsonb;
  BEGIN
    v_r := public.registrar_compra_completa(
      NULL, 'ENSAYO 1251', 'ENSAYO-1251-' || p_ref, p_fecha,
      v_sub, v_iva, 0, v_sub + v_iva, 'efectivo', 'ensayo 1251', p_admin, v_lin, p_tipo,
      p_letra_comprobante => p_letra);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra % no se registró: %', p_ref, v_r;
    END IF;
    RETURN (v_r->>'compra_id')::bigint;
  END $f$;

  -- Edita una compra ZZ con las líneas nuevas y devuelve la respuesta.
  CREATE FUNCTION pg_temp.editar(p_admin uuid, p_compra bigint, p_items jsonb)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_lin jsonb := pg_temp.lineas(p_items, 0);
    v_r   jsonb;
  BEGIN
    v_r := public.actualizar_compra_items(
      p_compra, v_lin, pg_temp.subtotal(v_lin), 0, pg_temp.subtotal(v_lin), p_admin,
      p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la edición de % no pasó: %', p_compra, v_r;
    END IF;
    RETURN v_r;
  END $f$;

  CREATE FUNCTION pg_temp.linea(p_prod bigint, p_cant int, p_costo numeric, p_bonif numeric DEFAULT 0)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant,
                              'costo_unitario', p_costo, 'bonificacion', p_bonif);
  $f$;

  CREATE FUNCTION pg_temp.cpp(p_prod bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT costo_promedio FROM public.productos WHERE id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.real(p_prod bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT costo_real FROM public.productos WHERE id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.stock(p_prod bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT stock FROM public.productos WHERE id = p_prod;
  $f$;
  -- Una venta: baja el stock sin tocar el promedio.
  CREATE FUNCTION pg_temp.vender(p_prod bigint, p_cant int) RETURNS void LANGUAGE sql AS $f$
    UPDATE public.productos SET stock = stock - p_cant WHERE id = p_prod;
  $f$;

  -- #1294 · anula una compra (falla si la RPC no la acepta).
  CREATE FUNCTION pg_temp.anular(p_admin uuid, p_compra bigint) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_r jsonb := public.anular_compra_atomica(p_compra, p_admin);
  BEGIN
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la anulación de % no pasó: %', p_compra, v_r;
    END IF;
    RETURN v_r;
  END $f$;
  -- #1294 · cambia el proveedor y devuelve el id del clon.
  CREATE FUNCTION pg_temp.clonar(p_admin uuid, p_compra bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_r jsonb := public.cambiar_proveedor_compra(p_compra, p_admin, NULL, 'ENSAYO 1294 OTRO', 'ensayo 1294');
  BEGIN
    IF (v_r->>'nueva_compra_id') IS NULL THEN
      RAISE EXCEPTION 'el cambio de proveedor de % no pasó: %', p_compra, v_r;
    END IF;
    RETURN (v_r->>'nueva_compra_id')::bigint;
  END $f$;
  -- #1294 · la foto de la primera línea de un producto en una compra: el stock
  -- y el promedio de justo antes, y el texto "stock antes → después @ promedio"
  -- para los mensajes.
  CREATE FUNCTION pg_temp.foto_s(p_compra bigint, p_prod bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT stock_anterior FROM public.compra_items
     WHERE compra_id = p_compra AND producto_id = p_prod ORDER BY id LIMIT 1;
  $f$;
  CREATE FUNCTION pg_temp.foto_c(p_compra bigint, p_prod bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT costo_promedio_anterior FROM public.compra_items
     WHERE compra_id = p_compra AND producto_id = p_prod ORDER BY id LIMIT 1;
  $f$;
  CREATE FUNCTION pg_temp.foto(p_compra bigint, p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT stock_anterior || ' → ' || stock_nuevo || ' @ ' || COALESCE(costo_promedio_anterior::text, 'NULL')
      FROM public.compra_items WHERE compra_id = p_compra AND producto_id = p_prod
     ORDER BY id LIMIT 1;
  $f$;
  -- #1294 · la hora del alta de una compra y de sus líneas, como en prod.
  CREATE FUNCTION pg_temp.alta_en(p_compra bigint, p_ts timestamptz) RETURNS void LANGUAGE sql AS $f$
    UPDATE public.compras SET created_at = p_ts WHERE id = p_compra;
    UPDATE public.compra_items SET created_at = p_ts WHERE compra_id = p_compra;
  $f$;

  -- -------------------------------------------------------------------------
  -- E1 · editar sin cambios no mueve el promedio
  -- -------------------------------------------------------------------------
  v_x := pg_temp.producto(v_suc, 'ZZ ensayo 1251 E1', 100, 10);
  v_p := pg_temp.comprar(v_admin, 'E1', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  PERFORM pg_temp.vender(v_x, 50);
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  SELECT stock_anterior, stock_nuevo INTO v_fila FROM compra_items WHERE compra_id = v_p;
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 15 OR v_fila.stock_anterior <> 100 OR v_fila.stock_nuevo <> 200 THEN
    v_fallas := v_fallas || format('E1 · esperaba promedio 15 y la línea 100 → 200; quedó %s y %s → %s',
                                   pg_temp.cpp(v_x), v_fila.stock_anterior, v_fila.stock_nuevo);
  END IF;

  -- -------------------------------------------------------------------------
  -- E2 · editar el costo con una compra posterior del mismo día
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1251 E2', 100, 10);
  v_p  := pg_temp.comprar(v_admin, 'E2-P',  v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  v_p2 := pg_temp.comprar(v_admin, 'E2-P2', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 30)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 20 THEN
    v_fallas := v_fallas || format('E2 · antes de editar esperaba 20; quedó %s', pg_temp.cpp(v_x));
  END IF;
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 100, 14)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 18 OR pg_temp.real(v_x) IS DISTINCT FROM 30 THEN
    v_fallas := v_fallas || format('E2 · esperaba promedio 18 y reposición 30 (la de la compra posterior); quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.real(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- E3 · editar la cantidad con venta y compra posterior
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1251 E3', 100, 10);
  v_p  := pg_temp.comprar(v_admin, 'E3-P',  v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  PERFORM pg_temp.vender(v_x, 100);
  v_p2 := pg_temp.comprar(v_admin, 'E3-P2', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 30)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 22.5 THEN
    v_fallas := v_fallas || format('E3 · antes de editar esperaba 22,5; quedó %s', pg_temp.cpp(v_x));
  END IF;
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 50, 20)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 24.4444 OR pg_temp.stock(v_x) <> 150 THEN
    v_fallas := v_fallas || format('E3 · esperaba promedio 24,4444 y stock 150; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- E4 · el producto que sale de la compra
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1251 E4 X', 0, NULL);
  v_y  := pg_temp.producto(v_suc, 'ZZ ensayo 1251 E4 Y', 0, NULL);
  v_p0 := pg_temp.comprar(v_admin, 'E4-P0', v_hoy - 1, jsonb_build_array(pg_temp.linea(v_x, 100, 10)));
  v_p  := pg_temp.comprar(v_admin, 'E4-P',  v_hoy,
            jsonb_build_array(pg_temp.linea(v_x, 100, 20), pg_temp.linea(v_y, 10, 5)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 15 OR pg_temp.real(v_x) IS DISTINCT FROM 20 THEN
    v_fallas := v_fallas || format('E4 · antes de editar esperaba 15 y 20; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.real(v_x));
  END IF;
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_y, 10, 5)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 10 OR pg_temp.real(v_x) IS DISTINCT FROM 10 OR pg_temp.stock(v_x) <> 100 THEN
    v_fallas := v_fallas || format('E4 · esperaba promedio 10, reposición 10 y stock 100; quedó %s, %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.real(v_x), pg_temp.stock(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- E5 · el producto que se agrega en la edición
  -- -------------------------------------------------------------------------
  v_x := pg_temp.producto(v_suc, 'ZZ ensayo 1251 E5 X', 0, NULL);
  v_y := pg_temp.producto(v_suc, 'ZZ ensayo 1251 E5 Y', 50, 8);
  v_p := pg_temp.comprar(v_admin, 'E5', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 5)));
  PERFORM pg_temp.editar(v_admin, v_p,
            jsonb_build_array(pg_temp.linea(v_x, 10, 5), pg_temp.linea(v_y, 50, 12)));
  IF pg_temp.cpp(v_y) IS DISTINCT FROM 10 OR pg_temp.stock(v_y) <> 100 THEN
    v_fallas := v_fallas || format('E5 · esperaba promedio 10 y stock 100; quedó %s y %s',
                                   pg_temp.cpp(v_y), pg_temp.stock(v_y));
  END IF;

  -- -------------------------------------------------------------------------
  -- E6 · compra anterior a la 236: sin foto, avisa y no mueve el promedio
  -- -------------------------------------------------------------------------
  v_x := pg_temp.producto(v_suc, 'ZZ ensayo 1251 E6', 100, 10);
  v_p := pg_temp.comprar(v_admin, 'E6', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  UPDATE compra_items SET costo_promedio_anterior = NULL WHERE compra_id = v_p;
  v_res := pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 100, 14)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 15
     OR NOT COALESCE(v_res->'warning_costo_promedio' @> jsonb_build_array(
              jsonb_build_object('producto_id', v_x, 'motivo', 'sin_cpp_previo')), false) THEN
    v_fallas := v_fallas || format('E6 · esperaba promedio 15 y el aviso sin_cpp_previo; quedó %s y %s',
                                   pg_temp.cpp(v_x), v_res->'warning_costo_promedio');
  END IF;

  -- -------------------------------------------------------------------------
  -- A1 · anular devuelve el promedio
  -- -------------------------------------------------------------------------
  v_x := pg_temp.producto(v_suc, 'ZZ ensayo 1251 A1', 100, 10);
  v_p := pg_temp.comprar(v_admin, 'A1', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  v_res := public.anular_compra_atomica(v_p, v_admin);
  IF NOT COALESCE((v_res->>'success')::boolean, false)
     OR pg_temp.cpp(v_x) IS DISTINCT FROM 10 OR pg_temp.stock(v_x) <> 100 THEN
    v_fallas := v_fallas || format('A1 · esperaba promedio 10 y stock 100; quedó %s y %s (%s)',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x), v_res);
  END IF;

  -- -------------------------------------------------------------------------
  -- A2 · anular con una compra posterior
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1251 A2', 100, 10);
  v_p  := pg_temp.comprar(v_admin, 'A2-P',  v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  v_p2 := pg_temp.comprar(v_admin, 'A2-P2', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 50, 30)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 18 THEN
    v_fallas := v_fallas || format('A2 · antes de anular esperaba 18; quedó %s', pg_temp.cpp(v_x));
  END IF;
  v_res := public.anular_compra_atomica(v_p, v_admin);
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 16.6667 OR pg_temp.stock(v_x) <> 150 OR pg_temp.real(v_x) IS DISTINCT FROM 30 THEN
    v_fallas := v_fallas || format('A2 · esperaba promedio 16,6667, stock 150 y reposición 30; quedó %s, %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x), pg_temp.real(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- A3 · anular respeta una corrección a mano
  -- -------------------------------------------------------------------------
  v_x := pg_temp.producto(v_suc, 'ZZ ensayo 1251 A3', 100, 10);
  v_p := pg_temp.comprar(v_admin, 'A3', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  UPDATE productos SET costo_promedio = 16 WHERE id = v_x;
  v_res := public.anular_compra_atomica(v_p, v_admin);
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 11 THEN
    v_fallas := v_fallas || format('A3 · esperaba 16 + (10 − 15) = 11; quedó %s', pg_temp.cpp(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- A4 · anular la única compra de un producto nuevo
  -- -------------------------------------------------------------------------
  v_x := pg_temp.producto(v_suc, 'ZZ ensayo 1251 A4', 0, NULL);
  v_p := pg_temp.comprar(v_admin, 'A4', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 20)));
  v_res := public.anular_compra_atomica(v_p, v_admin);
  IF pg_temp.cpp(v_x) IS NOT NULL
     OR NOT COALESCE(v_res->'warnings' @> jsonb_build_array(jsonb_build_object('producto_id', v_x)), false) THEN
    v_fallas := v_fallas || format('A4 · esperaba promedio NULL y el aviso de costo no restaurado; quedó %s y %s',
                                   pg_temp.cpp(v_x), v_res->'warnings');
  END IF;

  -- -------------------------------------------------------------------------
  -- A5 · anular una compra que no fijaba la reposición no la toca
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1251 A5', 0, NULL);
  v_p0 := pg_temp.comprar(v_admin, 'A5-P0', v_hoy - 2, jsonb_build_array(pg_temp.linea(v_x, 10, 10)));
  v_p  := pg_temp.comprar(v_admin, 'A5-P1', v_hoy,     jsonb_build_array(pg_temp.linea(v_x, 10, 20)));
  UPDATE productos SET costo_real = 21 WHERE id = v_x;   -- corregido a mano en la ficha
  v_res := public.anular_compra_atomica(v_p0, v_admin);
  IF pg_temp.real(v_x) IS DISTINCT FROM 21 THEN
    v_fallas := v_fallas || format('A5 · la reposición no era de la anulada y tenía que quedar en 21; quedó %s',
                                   pg_temp.real(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- C1 · cambiar el proveedor conserva la foto y la fecha de alta
  -- -------------------------------------------------------------------------
  v_x := pg_temp.producto(v_suc, 'ZZ ensayo 1251 C1', 100, 10);
  v_p := pg_temp.comprar(v_admin, 'C1', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  UPDATE compras SET created_at = now() - interval '3 days' WHERE id = v_p;
  v_res := public.cambiar_proveedor_compra(v_p, v_admin, NULL, 'ENSAYO 1251 OTRO', 'ensayo 1251');
  v_clon := (v_res->>'nueva_compra_id')::bigint;
  IF v_clon IS NULL THEN
    v_fallas := v_fallas || format('C1 · el cambio de proveedor no pasó: %s', v_res);
  ELSE
    SELECT ci.costo_promedio_anterior, ci.stock_anterior, ci.created_at, c.created_at AS alta
      INTO v_fila
      FROM compra_items ci JOIN compras c ON c.id = ci.compra_id
     WHERE ci.compra_id = v_clon;
    IF v_fila.costo_promedio_anterior IS DISTINCT FROM 10 OR v_fila.stock_anterior <> 100
       OR v_fila.alta <> (SELECT created_at FROM compras WHERE id = v_p)
       OR v_fila.created_at <> (SELECT created_at FROM compra_items WHERE compra_id = v_p) THEN
      v_fallas := v_fallas || format('C1 · el clon tenía que conservar foto 10, stock 100 y las fechas de alta; quedó %s',
                                     row_to_json(v_fila));
    END IF;
    v_res := pg_temp.editar(v_admin, v_clon, jsonb_build_array(pg_temp.linea(v_x, 100, 14)));
    IF pg_temp.cpp(v_x) IS DISTINCT FROM 12 OR v_res->>'warning_costo_promedio' IS NOT NULL THEN
      v_fallas := v_fallas || format('C1 · editar el clon tenía que dejar 12 sin aviso; quedó %s y %s',
                                     pg_temp.cpp(v_x), v_res->'warning_costo_promedio');
    END IF;
  END IF;

  -- -------------------------------------------------------------------------
  -- R1 · un regalo con fecha posterior no traba la reposición
  -- -------------------------------------------------------------------------
  v_x := pg_temp.producto(v_suc, 'ZZ ensayo 1251 R1', 0, NULL);
  PERFORM pg_temp.comprar(v_admin, 'R1-A', v_hoy - 10, jsonb_build_array(pg_temp.linea(v_x, 10, 10)));
  PERFORM pg_temp.comprar(v_admin, 'R1-B', v_hoy,      jsonb_build_array(pg_temp.linea(v_x, 5, 10, 100)));
  PERFORM pg_temp.comprar(v_admin, 'R1-C', v_hoy - 5,  jsonb_build_array(pg_temp.linea(v_x, 10, 15)));
  IF pg_temp.real(v_x) IS DISTINCT FROM 15 THEN
    v_fallas := v_fallas || format('R1 · esperaba la reposición de C (15); quedó %s', pg_temp.real(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- R2 · la factura B es lo pagado y queda 'FC B'
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1251 R2', 0, NULL);
  v_p0 := pg_temp.comprar(v_admin, 'R2-B', v_hoy - 1, jsonb_build_array(pg_temp.linea(v_x, 10, 121)), 'FC', 'B', 0);
  SELECT ultimo_tipo_compra, costo_con_iva, costo_sin_iva INTO v_fila FROM productos WHERE id = v_x;
  IF v_fila.ultimo_tipo_compra IS DISTINCT FROM 'FC B' OR v_fila.costo_con_iva IS DISTINCT FROM 121
     OR v_fila.costo_sin_iva IS DISTINCT FROM 121 THEN
    v_fallas := v_fallas || format('R2 · la B tenía que dejar FC B y 121 / 121; quedó %s', row_to_json(v_fila));
  END IF;
  v_p := pg_temp.comprar(v_admin, 'R2-A', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 100)), 'FC', 'A', 21);
  SELECT ultimo_tipo_compra, costo_con_iva INTO v_fila FROM productos WHERE id = v_x;
  IF v_fila.ultimo_tipo_compra IS DISTINCT FROM 'FC' OR v_fila.costo_con_iva IS DISTINCT FROM 121 THEN
    v_fallas := v_fallas || format('R2 · la A tenía que dejar FC y 121 (100 + IVA); quedó %s', row_to_json(v_fila));
  END IF;
  v_res := public.anular_compra_atomica(v_p, v_admin);
  SELECT ultimo_tipo_compra, costo_con_iva INTO v_fila FROM productos WHERE id = v_x;
  IF v_fila.ultimo_tipo_compra IS DISTINCT FROM 'FC B' OR v_fila.costo_con_iva IS DISTINCT FROM 121 THEN
    v_fallas := v_fallas || format('R2 · anular la A tenía que volver a FC B y 121; quedó %s', row_to_json(v_fila));
  END IF;

  -- -------------------------------------------------------------------------
  -- R3 · el alta bloquea en orden de id antes del loop
  -- -------------------------------------------------------------------------
  IF pg_get_functiondef('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure)
     !~ 'ORDER BY id\s+FOR UPDATE;\s+FOR v_item IN' THEN
    v_fallas := v_fallas || 'R3 · registrar_compra_completa no bloquea los productos en orden de id antes del loop'::text;
  END IF;

  -- -------------------------------------------------------------------------
  -- D1 · editar y después anular la posterior (#1294)
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1294 D1', 100, 10);
  v_p  := pg_temp.comprar(v_admin, 'D1-A', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 10)));
  v_p2 := pg_temp.comprar(v_admin, 'D1-B', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 13.3333 THEN
    v_fallas := v_fallas || format('D1 · antes de corregir esperaba 13,3333; quedó %s', pg_temp.cpp(v_x));
  END IF;
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 100, 16)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 15.3333
     OR pg_temp.foto_s(v_p2, v_x) IS DISTINCT FROM 200 OR pg_temp.foto_c(v_p2, v_x) IS DISTINCT FROM 13 THEN
    v_fallas := v_fallas || format('D1 · editar A tenía que dejar 15,3333 y la foto de B en 200 @ 13; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.foto(v_p2, v_x));
  END IF;
  PERFORM pg_temp.anular(v_admin, v_p2);
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 13 OR pg_temp.stock(v_x) <> 200 THEN
    v_fallas := v_fallas || format('D1 · anular B tenía que dejar 13 y stock 200; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- D2 · editar el costo, después la cantidad, y anular la posterior (#1294)
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1294 D2', 100, 10);
  v_p  := pg_temp.comprar(v_admin, 'D2-A', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 10)));
  v_p2 := pg_temp.comprar(v_admin, 'D2-B', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 100, 16)));
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 50, 16)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 15.2 OR pg_temp.stock(v_x) <> 250
     OR pg_temp.foto_s(v_p2, v_x) IS DISTINCT FROM 150 OR pg_temp.foto_c(v_p2, v_x) IS DISTINCT FROM 12 THEN
    v_fallas := v_fallas || format('D2 · la cantidad de A tenía que dejar 15,2, stock 250 y la foto de B en 150 @ 12; quedó %s, %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x), pg_temp.foto(v_p2, v_x));
  END IF;
  PERFORM pg_temp.anular(v_admin, v_p2);
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 12 OR pg_temp.stock(v_x) <> 150 THEN
    v_fallas := v_fallas || format('D2 · anular B tenía que dejar 12 (100 a 10 + 50 a 16) y stock 150; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- D3 · la primera compra del producto, editada dos veces y anulada (#1294)
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1294 D3', 0, NULL);
  v_p  := pg_temp.comprar(v_admin, 'D3-A', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 10)));
  v_p2 := pg_temp.comprar(v_admin, 'D3-B', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 30)));
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 50, 10)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 23.3333 OR pg_temp.stock(v_x) <> 150 THEN
    v_fallas := v_fallas || format('D3 · la cantidad de A tenía que dejar 23,3333 y stock 150; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x));
  END IF;
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 50, 20)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 26.6667 THEN
    v_fallas := v_fallas || format('D3 · el costo de A tenía que dejar 26,6667 (50 a 20 + 100 a 30); quedó %s',
                                   pg_temp.cpp(v_x));
  END IF;
  PERFORM pg_temp.anular(v_admin, v_p);
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 30 OR pg_temp.stock(v_x) <> 100 THEN
    v_fallas := v_fallas || format('D3 · anular A tenía que dejar el costo de B (30) y stock 100; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- D4 · una corrección a mano entre A y B sobrevive a dos correcciones (#1294)
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1294 D4', 100, 10);
  v_p  := pg_temp.comprar(v_admin, 'D4-A', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 10)));
  UPDATE productos SET costo_promedio = 12 WHERE id = v_x;   -- corregido a mano en la ficha
  v_p2 := pg_temp.comprar(v_admin, 'D4-B', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 100, 16)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 16.6667 THEN
    v_fallas := v_fallas || format('D4 · editar A tenía que dejar 16,6667; quedó %s', pg_temp.cpp(v_x));
  END IF;
  PERFORM pg_temp.anular(v_admin, v_p2);
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 15 THEN
    v_fallas := v_fallas || format('D4 · anular B tenía que dejar 15 (13 + los 2 de la ficha); quedó %s', pg_temp.cpp(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- D5 · la posterior entró con stock 0 y reseteó el promedio (#1294)
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1294 D5', 100, 10);
  v_p  := pg_temp.comprar(v_admin, 'D5-A', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  PERFORM pg_temp.vender(v_x, 200);
  v_p2 := pg_temp.comprar(v_admin, 'D5-B', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 30)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 30 THEN
    v_fallas := v_fallas || format('D5 · antes de corregir esperaba 30 (B entró sobre stock 0); quedó %s', pg_temp.cpp(v_x));
  END IF;
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 150, 20)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 25.3333 OR pg_temp.stock(v_x) <> 150
     OR pg_temp.foto_s(v_p2, v_x) IS DISTINCT FROM 50 OR pg_temp.foto_c(v_p2, v_x) IS DISTINCT FROM 16 THEN
    v_fallas := v_fallas || format('D5 · A a 150 u. tenía que dejar 25,3333, stock 150 y la foto de B en 50 @ 16; quedó %s, %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x), pg_temp.foto(v_p2, v_x));
  END IF;
  PERFORM pg_temp.anular(v_admin, v_p2);
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 16 OR pg_temp.stock(v_x) <> 50 THEN
    v_fallas := v_fallas || format('D5 · anular B tenía que dejar 16 y stock 50; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- D6 · la posterior es el clon de un cambio de proveedor (#1294)
  -- -------------------------------------------------------------------------
  v_x    := pg_temp.producto(v_suc, 'ZZ ensayo 1294 D6', 100, 10);
  v_p    := pg_temp.comprar(v_admin, 'D6-A', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 10)));
  v_p2   := pg_temp.comprar(v_admin, 'D6-B', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 100, 20)));
  v_clon := pg_temp.clonar(v_admin, v_p2);
  PERFORM pg_temp.editar(v_admin, v_p, jsonb_build_array(pg_temp.linea(v_x, 100, 16)));
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 15.3333 OR pg_temp.foto_c(v_clon, v_x) IS DISTINCT FROM 13 THEN
    v_fallas := v_fallas || format('D6 · editar A tenía que dejar 15,3333 y la foto del clon en 13; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.foto(v_clon, v_x));
  END IF;
  PERFORM pg_temp.anular(v_admin, v_clon);
  IF pg_temp.cpp(v_x) IS DISTINCT FROM 13 OR pg_temp.stock(v_x) <> 200 THEN
    v_fallas := v_fallas || format('D6 · anular el clon tenía que dejar 13 y stock 200; quedó %s y %s',
                                   pg_temp.cpp(v_x), pg_temp.stock(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- N1 · editar el clon no le gana a la compra posterior del mismo día (#1294)
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1294 N1', 0, NULL);
  v_p  := pg_temp.comprar(v_admin, 'N1-X', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 10)));
  v_p2 := pg_temp.comprar(v_admin, 'N1-Y', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 12)));
  PERFORM pg_temp.alta_en(v_p,  now() - interval '2 hours');
  PERFORM pg_temp.alta_en(v_p2, now() - interval '1 hour');
  v_clon := pg_temp.clonar(v_admin, v_p);
  PERFORM pg_temp.editar(v_admin, v_clon, jsonb_build_array(pg_temp.linea(v_x, 10, 10)));
  IF pg_temp.real(v_x) IS DISTINCT FROM 12 THEN
    v_fallas := v_fallas || format('N1 · editar el clon de X tenía que dejar la reposición de Y (12); quedó %s', pg_temp.real(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- N2 · anular la del mismo día devuelve la reposición al clon (#1294)
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1294 N2', 0, NULL);
  v_p  := pg_temp.comprar(v_admin, 'N2-X', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 10)));
  v_p2 := pg_temp.comprar(v_admin, 'N2-Y', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 12)));
  PERFORM pg_temp.alta_en(v_p,  now() - interval '2 hours');
  PERFORM pg_temp.alta_en(v_p2, now() - interval '1 hour');
  v_clon := pg_temp.clonar(v_admin, v_p);
  PERFORM pg_temp.anular(v_admin, v_p2);
  IF pg_temp.real(v_x) IS DISTINCT FROM 10 THEN
    v_fallas := v_fallas || format('N2 · anular Y tenía que devolver la reposición al clon de X (10); quedó %s', pg_temp.real(v_x));
  END IF;

  -- -------------------------------------------------------------------------
  -- N3 · con tres del mismo día, la reposición vuelve a la anterior por la
  --      hora del alta, no por el id del clon (#1294)
  -- -------------------------------------------------------------------------
  v_x  := pg_temp.producto(v_suc, 'ZZ ensayo 1294 N3', 0, NULL);
  v_p  := pg_temp.comprar(v_admin, 'N3-X', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 10)));
  v_p2 := pg_temp.comprar(v_admin, 'N3-Y', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 12)));
  v_p3 := pg_temp.comprar(v_admin, 'N3-Z', v_hoy, jsonb_build_array(pg_temp.linea(v_x, 10, 14)));
  PERFORM pg_temp.alta_en(v_p,  now() - interval '3 hours');
  PERFORM pg_temp.alta_en(v_p2, now() - interval '2 hours');
  PERFORM pg_temp.alta_en(v_p3, now() - interval '1 hour');
  v_clon := pg_temp.clonar(v_admin, v_p);
  PERFORM pg_temp.anular(v_admin, v_p3);
  IF pg_temp.real(v_x) IS DISTINCT FROM 12 THEN
    v_fallas := v_fallas || format('N3 · anular Z tenía que devolver la reposición a Y (12); quedó %s', pg_temp.real(v_x));
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ensayo-1251-ok' USING ERRCODE = 'ZZ0OK';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' THEN
  RAISE NOTICE 'ENSAYO OK (todo revertido)';
 END;
END
$ensayo$;
