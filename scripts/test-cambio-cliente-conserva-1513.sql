-- Ensayo de la 480: el cambio de cliente conserva lo que el pedido tenía (#1513 entero; COB-1 de #1512
-- y PRM-2 de #1515 en el cambio de cliente; gate 3 de #1520). Tarjeta 2 de #1524.
--
-- C1 es el cliente original de la boleta X; C2, el nuevo; N, el pedido nuevo. Todos los casos fallan sin
-- la migración salvo C3 y R7, que son testigos:
--
--   V1 · X la cargó otro usuario (un encargado si hay, o cualquier perfil que no es el admin): N conserva
--        su usuario_id, creado_por es el admin y queda el renglón 'usuario_id' en pedido_historial.
--   V2 · X no tiene vendedor (usuario_id NULL): N tampoco.
--   V3 · X la cargó el mismo admin: N es suyo y no hay renglón 'usuario_id'.
--   R1 · El regalo de X es B, no el default A de la promo, y la promo bajó su regalo de 5 a 3 después del
--        alta. Con el regalo de X tal cual, N lleva B×5, hereda la foto de X (5, su origen y su hora) y el
--        stock de A y de B no se mueve.
--   R2 · X tiene una sustitución por valor A×5 → B×7. N lleva B×7 con una clave nueva, los eslabones de X
--        copiados, la descripción de X, y cuenta 5 usos de la promo, como X.
--   R3 · X tiene un reparto del alta (A×2 + B×3). N tiene las mismas filas de reparto que X, con un solo
--        reparto_id nuevo y una clave nueva por parte.
--   R4 · Se manda el regalo recalculado (A×5 en vez de B×5): se rechaza y X sigue pendiente.
--   R5 · X no tiene regalo (la promo se quitó) y se manda uno: se rechaza y X sigue pendiente (PRM-2).
--   R6 · La promo de X cambió de tipo desde el alta: se rechaza y X sigue pendiente.
--   R7 · Testigo: el regalo de X tal cual, sin cambios en la promo: pasa, y el cupo cuenta lo mismo.
--   A1 · C2 está dado de baja: se rechaza con su motivo antes de cancelar, y X sigue pendiente (PAT-8-1).
--   M1 · El mínimo de venta del producto subió a 20 y X lleva 10: el cambio pasa, también con el trigger
--        diferido disparado. M1b, el control: un alta nueva de 10 se rechaza.
--   M2 · El producto quedó sin precio de lista: el cambio pasa al precio de X. M2b, el control: un alta
--        nueva de ese producto se rechaza.
--   C1 · COB-1, 'cliente_original': C1 tiene otra boleta Y impaga y X tiene un cobro de 300. Los 300 pagan
--        Y (FIFO) y C1 no queda con crédito suelto; aplicado_cliente_original = 300. El pago que llega a Y queda
--        marcado de_saldo_a_favor, que la rendición excluye (#1507, #1492). Lo mismo en C2.
--   C2 · COB-1, 'pedido_nuevo': X absorbió un crédito de 400 de C1, y después nació Y. Los 400 vuelven y
--        pagan Y; a_favor_cliente_original = 400 y aplicado_cliente_original = 400.
--   C3 · Testigo: C1 sin otra boleta, 'cliente_original' con un cobro de 300: queda suelto en C1.
--   En C1 a C3, el saldo de C1 y de C2 cierra (el predicado de CC-A) y CC-A de la base no cambia.
--   L1 · Los EXECUTE de cambiar_cliente_pedido no cambiaron, y la respuesta ya no trae preventista_fallback.
--   G1 · auditoria_pedidos_cliente_activo(): las funciones que insertan en pedidos miran activo, y no se
--        puede llamar desde la API.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una
-- excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado
-- detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar
-- 'ENSAYO FALLÓ'.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.c13_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c13_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1513', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c13_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1513 ' || p_nombre, 100, 1000, 60, p_suc)
  RETURNING id;
$fn$;

-- Promo que mueve stock: 10 de p_venta dan 5 de p_regalo.
CREATE OR REPLACE FUNCTION pg_temp.c13_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_hoy date)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1513', 'bonificacion', p_hoy - 1, p_suc, true, p_regalo)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, p_suc), (v_promo, 'cantidad_bonificacion', 5, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_venta, p_suc);
  RETURN v_promo;
END
$fn$;

-- Una línea de venta a $100 y, si p_regalos no es NULL, sus líneas de regalo: [[producto, cantidad], …].
CREATE OR REPLACE FUNCTION pg_temp.c13_lineas(p_venta bigint, p_cant int, p_promo bigint, p_regalos jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_venta, 'cantidad', p_cant, 'precio_unitario', 100))
      || COALESCE((SELECT jsonb_agg(jsonb_build_object('producto_id', (r->>0)::bigint, 'cantidad', (r->>1)::int,
                                                       'precio_unitario', 0, 'es_bonificacion', true,
                                                       'promocion_id', p_promo) ORDER BY o)
                     FROM jsonb_array_elements(p_regalos) WITH ORDINALITY AS t(r, o)), '[]'::jsonb);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c13_alta(p_cli bigint, p_adm uuid, p_items jsonb, p_fecha date)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli,
    (SELECT sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_adm, p_items, 'ensayo 1513', 'efectivo', 'pendiente', p_fecha, NULL);
  PERFORM pg_temp.c13_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Las líneas de X como las manda el front: la venta por producto, a su precio, y el regalo tal cual.
CREATE OR REPLACE FUNCTION pg_temp.c13_items_de(p_ped bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_agg(s.e ORDER BY s.g, s.o)
    FROM (SELECT 1 AS g, min(pi.id) AS o,
                 jsonb_build_object('producto_id', pi.producto_id, 'cantidad', sum(pi.cantidad),
                                    'precio_unitario', max(pi.precio_unitario)) AS e
            FROM public.pedido_items pi
           WHERE pi.pedido_id = p_ped AND NOT COALESCE(pi.es_bonificacion, false)
           GROUP BY pi.producto_id
          UNION ALL
          SELECT 2, pi.id,
                 jsonb_build_object('producto_id', pi.producto_id, 'cantidad', pi.cantidad, 'precio_unitario', 0,
                                    'es_bonificacion', true, 'promocion_id', pi.promocion_id)
            FROM public.pedido_items pi
           WHERE pi.pedido_id = p_ped AND COALESCE(pi.es_bonificacion, false)) s;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c13_cambiar(p_ped bigint, p_cli bigint, p_adm uuid, p_items jsonb, p_destino text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cambiar_cliente_pedido(
    p_ped, p_cli, p_adm, p_items,
    (SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
       FROM jsonb_array_elements(p_items) e WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)),
    NULL, 0, 'ensayo 1513', p_destino);
  PERFORM pg_temp.c13_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c13_saldo(p_cli bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT CASE WHEN abs(COALESCE(c.saldo_cuenta, 0) - (b.deuda - f.favor)) <= 0.01 THEN ''
              ELSE format(' saldo_cuenta de %s=%s esperado=%s', p_cli, c.saldo_cuenta, b.deuda - f.favor) END
    FROM public.clientes c,
         LATERAL (SELECT COALESCE(sum(total - COALESCE(monto_pagado, 0)), 0) AS deuda FROM public.pedidos
                   WHERE cliente_id = p_cli AND estado NOT IN ('cancelado', 'anulado')) b,
         LATERAL (SELECT COALESCE(sum(monto), 0) AS favor FROM public.pagos
                   WHERE cliente_id = p_cli AND pedido_id IS NULL) f
   WHERE c.id = p_cli;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c13_cca()
RETURNS int LANGUAGE sql AS $fn$
  SELECT (e->>'violaciones')::int
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
   WHERE e->>'id' = 'CC-A';
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c13_favor(p_cli bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(sum(monto), 0) FROM public.pagos WHERE cliente_id = p_cli AND pedido_id IS NULL;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c13_usos(p_promo bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT usos FROM public._promo_usos(p_promo, NULL);
$fn$;

-- Las líneas de regalo de un pedido, en orden: producto×cantidad.
CREATE OR REPLACE FUNCTION pg_temp.c13_regalo(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(producto_id || 'x' || cantidad, ',' ORDER BY id), '')
    FROM public.pedido_items WHERE pedido_id = p_ped AND COALESCE(es_bonificacion, false);
$fn$;

-- Los eslabones de un pedido sin las claves ni el pedido: lo que tiene que heredar N.
CREATE OR REPLACE FUNCTION pg_temp.c13_eslabones(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(format('%s:%s>%s:%s>%s|%s|%s|%s', promocion_id, producto_original_id, producto_sustituto_id,
                                    cantidad_original, cantidad_sustituta, motivo, producto_raiz_id, created_at),
                             ',' ORDER BY created_at, id), '')
    FROM public.pedido_item_sustituciones WHERE pedido_id = p_ped;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_otro   uuid;
  v_hoy    date := public._tablero_hoy();
  v_v      bigint;
  v_a      bigint;
  v_b      bigint;
  v_p      bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_x      bigint;
  v_y      bigint;
  v_n      bigint;
  v_k      bigint;
  v_i      bigint;
  v_s0     text;
  v_s1     text;
  v_txt    text;
  v_j      jsonb;
  v_fallas text[] := '{}';
  v_cca    int;
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id
    INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
     AND COALESCE(public.ultima_fecha_caja_cerrada(s.id), v_hoy - 1) < v_hoy
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin y la caja de hoy abierta';
  END IF;
  -- Cualquier perfil que no es el admin: el cambio conserva al vendedor sin mirar su rol.
  SELECT pf.id INTO v_otro FROM perfiles pf
   WHERE pf.id <> v_adm
   ORDER BY (pf.rol = 'encargado') DESC, pf.activo, pf.id
   LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  v_v := pg_temp.c13_producto(v_suc, 'venta');
  v_a := pg_temp.c13_producto(v_suc, 'regalo A');
  v_b := pg_temp.c13_producto(v_suc, 'regalo B');
  v_cca := pg_temp.c13_cca();

  -- V1 · otro vendedor
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 V1 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 V1 C2');
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 3, NULL, NULL), v_hoy);
    UPDATE pedidos SET usuario_id = v_otro WHERE id = v_x;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT usuario_id FROM pedidos WHERE id = v_n) IS DISTINCT FROM v_otro
       OR (SELECT creado_por FROM pedidos WHERE id = v_n) IS DISTINCT FROM v_adm
       OR NOT EXISTS (SELECT 1 FROM pedido_historial WHERE pedido_id = v_n AND campo_modificado = 'usuario_id'
                         AND valor_nuevo = v_otro::text) THEN
      v_fallas := v_fallas || format('V1 dio %s; vendedor de N %s, se esperaba %s', v_j,
        (SELECT usuario_id FROM pedidos WHERE id = v_n), v_otro);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- V2 · sin vendedor
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 V2 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 V2 C2');
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 3, NULL, NULL), v_hoy);
    UPDATE pedidos SET usuario_id = NULL WHERE id = v_x;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT usuario_id FROM pedidos WHERE id = v_n) IS NOT NULL THEN
      v_fallas := v_fallas || format('V2 dio %s; vendedor de N %s', v_j, (SELECT usuario_id FROM pedidos WHERE id = v_n));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- V3 · el mismo admin
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 V3 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 V3 C2');
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 3, NULL, NULL), v_hoy);
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT usuario_id FROM pedidos WHERE id = v_n) IS DISTINCT FROM v_adm
       OR EXISTS (SELECT 1 FROM pedido_historial WHERE pedido_id = v_n AND campo_modificado = 'usuario_id') THEN
      v_fallas := v_fallas || format('V3 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R1 · el sabor elegido y la foto de la promo
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R1 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R1 C2');
    v_p := pg_temp.c13_promo(v_suc, v_v, v_a, v_hoy);
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, v_p, jsonb_build_array(jsonb_build_array(v_b, 5))), v_hoy);
    UPDATE promocion_reglas SET valor = 3 WHERE promocion_id = v_p AND clave = 'cantidad_bonificacion';
    v_s0 := (SELECT string_agg(id || ':' || stock, ',' ORDER BY id) FROM productos WHERE id IN (v_a, v_b));
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_s1 := (SELECT string_agg(id || ':' || stock, ',' ORDER BY id) FROM productos WHERE id IN (v_a, v_b));
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.c13_regalo(v_n) IS DISTINCT FROM v_b || 'x5'
       OR (SELECT row(n.cantidad_compra, n.cantidad_bonificacion, n.regalo_mueve_stock, n.productos, n.origen, n.tomada_at)::text
             FROM pedido_promo_reglas n WHERE n.pedido_id = v_n AND n.promocion_id = v_p)
          IS DISTINCT FROM
          (SELECT row(o.cantidad_compra, o.cantidad_bonificacion, o.regalo_mueve_stock, o.productos, o.origen, o.tomada_at)::text
             FROM pedido_promo_reglas o WHERE o.pedido_id = v_x AND o.promocion_id = v_p)
       OR (SELECT cantidad_bonificacion FROM pedido_promo_reglas WHERE pedido_id = v_n AND promocion_id = v_p) IS DISTINCT FROM 5
       OR (SELECT descripcion_regalo FROM pedido_items WHERE pedido_id = v_n AND es_bonificacion)
          IS DISTINCT FROM (SELECT descripcion_regalo FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion)
       OR v_s1 IS DISTINCT FROM v_s0 THEN
      v_fallas := v_fallas || format('R1 dio %s; regalo de N %s; foto de N %s; stock %s → %s', v_j, pg_temp.c13_regalo(v_n),
        (SELECT row(n.cantidad_compra, n.cantidad_bonificacion, n.origen, n.tomada_at)::text FROM pedido_promo_reglas n
          WHERE n.pedido_id = v_n AND n.promocion_id = v_p), v_s0, v_s1);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R2 · la cadena de una sustitución por valor
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R2 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R2 C2');
    v_p := pg_temp.c13_promo(v_suc, v_v, v_a, v_hoy);
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, v_p, jsonb_build_array(jsonb_build_array(v_a, 5))), v_hoy);
    v_i := (SELECT id FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion);
    v_j := public.sustituir_regalo_pedido(v_i, v_b, 7, 'ensayo 1513', NULL, NULL);
    PERFORM pg_temp.c13_reset();
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR pg_temp.c13_regalo(v_x) IS DISTINCT FROM v_b || 'x7' THEN
      RAISE EXCEPTION 'precondición: no se pudo sustituir: % (regalo de X %)', v_j, pg_temp.c13_regalo(v_x);
    END IF;
    v_k := pg_temp.c13_usos(v_p);
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.c13_regalo(v_n) IS DISTINCT FROM v_b || 'x7'
       OR (SELECT regalo_cadena_id FROM pedido_items WHERE pedido_id = v_n AND es_bonificacion) IS NULL
       OR (SELECT regalo_cadena_id FROM pedido_items WHERE pedido_id = v_n AND es_bonificacion)
          = (SELECT regalo_cadena_id FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion)
       OR EXISTS (SELECT 1 FROM pedido_item_sustituciones s
                   WHERE s.pedido_id = v_n
                     AND (s.cadena_id IS DISTINCT FROM (SELECT regalo_cadena_id FROM pedido_items
                                                         WHERE pedido_id = v_n AND es_bonificacion)
                          OR s.pedido_item_id IS DISTINCT FROM (SELECT id FROM pedido_items
                                                                 WHERE pedido_id = v_n AND es_bonificacion)))
       OR pg_temp.c13_eslabones(v_n) IS DISTINCT FROM pg_temp.c13_eslabones(v_x)
       OR pg_temp.c13_eslabones(v_n) = ''
       OR (SELECT descripcion_regalo FROM pedido_items WHERE pedido_id = v_n AND es_bonificacion)
          IS DISTINCT FROM (SELECT descripcion_regalo FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion)
       OR pg_temp.c13_usos(v_p) IS DISTINCT FROM v_k THEN
      v_fallas := v_fallas || format('R2 dio %s; regalo de N %s; eslabones N [%s] X [%s]; usos %s → %s', v_j,
        pg_temp.c13_regalo(v_n), pg_temp.c13_eslabones(v_n), pg_temp.c13_eslabones(v_x), v_k, pg_temp.c13_usos(v_p));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R3 · el reparto del alta
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R3 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R3 C2');
    v_p := pg_temp.c13_promo(v_suc, v_v, v_a, v_hoy);
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, v_p,
             jsonb_build_array(jsonb_build_array(v_a, 2), jsonb_build_array(v_b, 3))), v_hoy);
    IF (SELECT count(*) FROM pedido_item_sustituciones WHERE pedido_id = v_x AND reparto_id IS NOT NULL) <> 2 THEN
      RAISE EXCEPTION 'precondición: el alta no armó el reparto (%)', pg_temp.c13_eslabones(v_x);
    END IF;
    UPDATE pedido_item_sustituciones SET motivo = 'reparto de X' WHERE pedido_id = v_x;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.c13_regalo(v_n) IS DISTINCT FROM v_a || 'x2,' || v_b || 'x3'
       OR pg_temp.c13_eslabones(v_n) IS DISTINCT FROM pg_temp.c13_eslabones(v_x)
       OR (SELECT count(DISTINCT reparto_id) FROM pedido_item_sustituciones WHERE pedido_id = v_n) <> 1
       OR EXISTS (SELECT 1 FROM pedido_item_sustituciones n JOIN pedido_item_sustituciones o ON o.reparto_id = n.reparto_id
                   WHERE n.pedido_id = v_n AND o.pedido_id = v_x)
       OR (SELECT count(DISTINCT regalo_cadena_id) FROM pedido_items WHERE pedido_id = v_n AND es_bonificacion) <> 2
       OR EXISTS (SELECT 1 FROM pedido_items pi
                   WHERE pi.pedido_id = v_n AND pi.es_bonificacion
                     AND NOT EXISTS (SELECT 1 FROM pedido_item_sustituciones s
                                      WHERE s.cadena_id = pi.regalo_cadena_id AND s.pedido_item_id = pi.id)) THEN
      v_fallas := v_fallas || format('R3 dio %s; eslabones N [%s] X [%s]', v_j, pg_temp.c13_eslabones(v_n), pg_temp.c13_eslabones(v_x));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R4 · el regalo recalculado se rechaza
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R4 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R4 C2');
    v_p := pg_temp.c13_promo(v_suc, v_v, v_a, v_hoy);
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, v_p, jsonb_build_array(jsonb_build_array(v_b, 5))), v_hoy);
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm,
             pg_temp.c13_lineas(v_v, 10, v_p, jsonb_build_array(jsonb_build_array(v_a, 5))), 'pedido_nuevo');
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE '%tal cual%'
       OR (SELECT estado FROM pedidos WHERE id = v_x) <> 'pendiente' THEN
      v_fallas := v_fallas || format('R4 dio %s; X %s', v_j, (SELECT estado FROM pedidos WHERE id = v_x));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R5 · PRM-2: un regalo que X no tenía se rechaza
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R5 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R5 C2');
    v_p := pg_temp.c13_promo(v_suc, v_v, v_a, v_hoy);
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, NULL, NULL), v_hoy);
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm,
             pg_temp.c13_lineas(v_v, 10, v_p, jsonb_build_array(jsonb_build_array(v_a, 5))), 'pedido_nuevo');
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE '%tal cual%'
       OR (SELECT estado FROM pedidos WHERE id = v_x) <> 'pendiente' THEN
      v_fallas := v_fallas || format('R5 dio %s; X %s', v_j, (SELECT estado FROM pedidos WHERE id = v_x));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R6 · la promo de X cambió de tipo desde el alta (X se cargó cuando no movía stock)
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R6 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R6 C2');
    v_p := pg_temp.c13_promo(v_suc, v_v, v_a, v_hoy);
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, v_p, jsonb_build_array(jsonb_build_array(v_a, 5))), v_hoy);
    UPDATE pedido_promo_reglas SET regalo_mueve_stock = false WHERE pedido_id = v_x AND promocion_id = v_p;
    UPDATE pedido_items SET regalo_mueve_stock_foto = false WHERE pedido_id = v_x AND es_bonificacion;
    IF (SELECT regalo_mueve_stock_foto FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion) IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'precondición: la línea de X no quedó con la foto de otro tipo';
    END IF;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE '%cambio de tipo%'
       OR (SELECT estado FROM pedidos WHERE id = v_x) <> 'pendiente' THEN
      v_fallas := v_fallas || format('R6 dio %s; X %s', v_j, (SELECT estado FROM pedidos WHERE id = v_x));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R6 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R7 · testigo: el regalo de X tal cual pasa, y el cupo cuenta lo mismo
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R7 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 R7 C2');
    v_p := pg_temp.c13_promo(v_suc, v_v, v_a, v_hoy);
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, v_p, jsonb_build_array(jsonb_build_array(v_a, 5))), v_hoy);
    v_k := pg_temp.c13_usos(v_p);
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.c13_regalo(v_n) IS DISTINCT FROM v_a || 'x5'
       OR pg_temp.c13_usos(v_p) IS DISTINCT FROM v_k THEN
      v_fallas := v_fallas || format('R7 dio %s; regalo de N %s; usos %s → %s', v_j, pg_temp.c13_regalo(v_n), v_k, pg_temp.c13_usos(v_p));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R7 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- A1 · el destino dado de baja
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 A1 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 A1 C2');
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 3, NULL, NULL), v_hoy);
    UPDATE clientes SET activo = false WHERE id = v_c2;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE '%dado de baja%'
       OR (SELECT estado FROM pedidos WHERE id = v_x) <> 'pendiente' THEN
      v_fallas := v_fallas || format('A1 dio %s; X %s', v_j, (SELECT estado FROM pedidos WHERE id = v_x));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('A1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- M1 · el mínimo de venta que subió
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 M1 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 M1 C2');
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, NULL, NULL), v_hoy);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    UPDATE productos SET cantidad_minima_venta = 20 WHERE id = v_v;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('M1 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('M1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- M1b · el control: un alta nueva por debajo del mínimo se rechaza
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 M1b C1');
    UPDATE productos SET cantidad_minima_venta = 20 WHERE id = v_v;
    v_txt := NULL;
    BEGIN
      v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, NULL, NULL), v_hoy);
      SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN v_txt := SQLERRM;
    END;
    IF v_txt IS NULL OR v_txt NOT LIKE '%compra mínima%' THEN
      v_fallas := v_fallas || format('M1b el alta de 10 con mínimo 20 dio %s', COALESCE(v_txt, 'éxito'));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('M1b dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- M2 · el producto quedó sin precio de lista
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 M2 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 M2 C2');
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 3, NULL, NULL), v_hoy);
    UPDATE productos SET precio = 0 WHERE id = v_v;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT precio_unitario FROM pedido_items WHERE pedido_id = v_n) IS DISTINCT FROM 100::numeric THEN
      v_fallas := v_fallas || format('M2 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('M2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- M2b · el control: un alta nueva de un producto sin precio de lista se rechaza
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 M2b C1');
    UPDATE productos SET precio = 0 WHERE id = v_v;
    v_txt := NULL;
    BEGIN
      v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 3, NULL, NULL), v_hoy);
    EXCEPTION WHEN OTHERS THEN v_txt := SQLERRM;
    END;
    IF v_txt IS NULL OR v_txt NOT LIKE '%pendiente de carga de precio%' THEN
      v_fallas := v_fallas || format('M2b el alta sin precio de lista dio %s', COALESCE(v_txt, 'éxito'));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('M2b dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C1 · COB-1 con 'cliente_original': el cobro de X paga la otra boleta de C1
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 C1 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 C1 C2');
    v_y := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, NULL, NULL), v_hoy);
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, NULL, NULL), v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":300,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    IF (SELECT monto_pagado FROM pedidos WHERE id = v_x) IS DISTINCT FROM 300::numeric THEN
      RAISE EXCEPTION 'precondición: el cobro de X no entró: %', v_j;
    END IF;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'cliente_original');
    v_txt := pg_temp.c13_saldo(v_c1) || pg_temp.c13_saldo(v_c2)
          || CASE WHEN pg_temp.c13_cca() IS DISTINCT FROM v_cca THEN format(' CC-A %s, antes %s', pg_temp.c13_cca(), v_cca) ELSE '' END;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 300::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_y AND NOT de_saldo_a_favor)
       OR pg_temp.c13_favor(v_c1) <> 0
       OR (v_j->>'aplicado_cliente_original')::numeric IS DISTINCT FROM 300::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('C1 dio %s; Y pagada %s; a favor de C1 %s%s', v_j,
        (SELECT monto_pagado FROM pedidos WHERE id = v_y), pg_temp.c13_favor(v_c1), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C2 · COB-1 con 'pedido_nuevo': lo absorbido vuelve a C1 y paga su otra boleta
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 C2 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 C2 C2');
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas, a_cuenta)
    VALUES (v_c1, NULL, v_suc, 400, 'efectivo', v_hoy, v_adm, '[saldo a favor]', true)
    RETURNING id INTO v_k;
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, NULL, NULL), v_hoy);
    v_y := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, NULL, NULL), v_hoy);
    IF (SELECT pedido_id FROM pagos WHERE id = v_k) IS DISTINCT FROM v_x
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 0::numeric THEN
      RAISE EXCEPTION 'precondición: X no absorbió el crédito de C1, o Y nació pagada';
    END IF;
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'pedido_nuevo');
    v_txt := pg_temp.c13_saldo(v_c1) || pg_temp.c13_saldo(v_c2)
          || CASE WHEN pg_temp.c13_cca() IS DISTINCT FROM v_cca THEN format(' CC-A %s, antes %s', pg_temp.c13_cca(), v_cca) ELSE '' END;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 400::numeric
       OR (SELECT pedido_id FROM pagos WHERE id = v_k) IS DISTINCT FROM v_y
       OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_y AND NOT de_saldo_a_favor)
       OR pg_temp.c13_favor(v_c1) <> 0
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c2)
       OR (v_j->>'a_favor_cliente_original')::numeric IS DISTINCT FROM 400::numeric
       OR (v_j->>'aplicado_cliente_original')::numeric IS DISTINCT FROM 400::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('C2 dio %s; Y pagada %s; pago K en %s; a favor de C1 %s%s', v_j,
        (SELECT monto_pagado FROM pedidos WHERE id = v_y), (SELECT pedido_id FROM pagos WHERE id = v_k),
        pg_temp.c13_favor(v_c1), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C3 · testigo: sin otra boleta, el cobro queda suelto en C1
  BEGIN
    v_c1 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 C3 C1');
    v_c2 := pg_temp.c13_cliente(v_suc, 'ZZ ensayo 1513 C3 C2');
    v_x := pg_temp.c13_alta(v_c1, v_adm, pg_temp.c13_lineas(v_v, 10, NULL, NULL), v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":300,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_j := pg_temp.c13_cambiar(v_x, v_c2, v_adm, pg_temp.c13_items_de(v_x), 'cliente_original');
    v_txt := pg_temp.c13_saldo(v_c1) || pg_temp.c13_saldo(v_c2)
          || CASE WHEN pg_temp.c13_cca() IS DISTINCT FROM v_cca THEN format(' CC-A %s, antes %s', pg_temp.c13_cca(), v_cca) ELSE '' END;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.c13_favor(v_c1) IS DISTINCT FROM 300::numeric
       OR COALESCE((v_j->>'aplicado_cliente_original')::numeric, 0) <> 0
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('C3 dio %s; a favor de C1 %s%s', v_j, pg_temp.c13_favor(v_c1), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · los EXECUTE no cambiaron, y la respuesta ya no trae preventista_fallback
  IF has_function_privilege('anon', 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 los EXECUTE de cambiar_cliente_pedido cambiaron'::text;
  END IF;
  IF (SELECT prosrc FROM pg_proc
       WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure)
     ~ 'preventista_fallback' THEN
    v_fallas := v_fallas || 'L1 la respuesta sigue trayendo preventista_fallback'::text;
  END IF;

  -- G1 · el gate 3 de #1520
  BEGIN
    v_j := public.auditoria_pedidos_cliente_activo();
    IF (v_j->>'funciones')::int < 3 OR jsonb_array_length(v_j->'sin_activo') > 0
       OR has_function_privilege('anon', 'public.auditoria_pedidos_cliente_activo()', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.auditoria_pedidos_cliente_activo()', 'EXECUTE') THEN
      v_fallas := v_fallas || format('G1 dio %s', v_j);
    END IF;
  EXCEPTION
    WHEN OTHERS THEN v_fallas := v_fallas || format('G1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · V1 V2 V3 R1 R2 R3 R4 R5 R6 R7 A1 M1 M1b M2 M2b C1 C2 C3 L1 G1';
 END;
END
$ensayo$;
