-- Ensayo de la migración que pone en el orden global el cambio de cliente, los precios en masa y el regalo de una
-- promo, y ordena el historial (#1473, tarjeta 6 de #1477).
--
-- Los 40P01 los mide el arnés (scripts/concurrencia, `t6`), porque hacen falta tres sesiones. Acá se prueba, en una
-- sola, que los caminos siguen haciendo lo mismo, y lo nuevo que sí se ve en una sesión. Los casos E pasan con y sin la
-- migración; los N y L fallan sin ella:
--
--   E1 · Pasar X (de C1, cobrada 100) a C2 con 'pedido_nuevo' y un total de 80, con W de C2 impaga: el pedido nuevo
--        queda 80/80, los 20 de excedente van a W, y C2 no queda con créditos. X queda cancelada y sin pagos.
--   E2 · Lo mismo con 'cliente_original': los 100 quedan a favor de C1, el pedido nuevo nace impago y W no cobra nada.
--   E3 · Pasar a C2 una X sin cobrar, con un crédito de 30 en C2 y W impaga: no se mueve ningún pago.
--   E4 · ADV-5: pasar X (de A) a C2 con un producto B que X no tenía: el stock de A vuelve y el de B baja.
--   E5 · Precios en masa sin nada trabado: [B, 'abc', A] cambia A y B, nombra al id que no es un número, y no deja
--        el lock_timeout cambiado.
--   E6 · Cambiar el regalo de una promo con ajuste automático y barra en 3: la barra rota igual que con el UPDATE
--        directo de antes (la misma fila en promo_acumuladores y la misma barra), y sin cambios no escribe nada.
--   En E1 a E4, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos (el predicado de CC-A) para cada
--   cliente que se toca, y las violaciones de CC-A de auditoria_integridad() en toda la base no cambian.
--   N1 · VTA-F-4: la línea de X dice 10,5 (la foto) y el producto hoy 21. El pedido nuevo (FC) lleva 10,5 en la
--        línea, su neto y su IVA, y el total_neto y total_iva del pedido cierran con ellos. Con la foto 0 (ambigua)
--        queda la de hoy.
--   N2 · ADV-3: la respuesta de los precios en masa trae `trabados` (vacío sin nada trabado).
--   N3 · ADV-4: editar X (cobrada 100) a 120 con un crédito de 30 del cliente deja en pedido_historial, por id, el
--        total, después el estado de pago que cambió el mismo UPDATE y después el que cambió la reimputación.
--        (actualizar_pedido_items suma después su propia fila del total.)
--   L1 · cambiar_cliente_pedido toma, antes de su lock de X: boletas → productos con contenedores → promos →
--        recorridos → pagos → clientes. El trigger del historial se llama trg_historial_cambio_pedido.
--        authenticated no tiene UPDATE REST de promociones.producto_regalo_id ni de ajuste_producto_id, sí del resto,
--        y tiene EXECUTE de cambiar_regalo_promocion (anon no). Ningún EXECUTE de antes cambió.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo,
-- sin el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', por N1 a N3 y L1
-- (E6 también: la RPC no existe).
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1473', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text, p_precio numeric DEFAULT 1)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, p_precio, 1000, 1, p_suc)
  RETURNING id;
$fn$;

-- Una boleta de p_cant unidades del producto a p_precio, del día p_fecha.
CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int, p_fecha date,
                                            p_precio numeric DEFAULT 1, p_tipo text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * p_precio, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio)),
    'ensayo 1473', 'efectivo', 'pendiente', p_fecha, p_tipo);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Pasar la boleta al cliente p_cli con p_cant unidades del producto a p_precio.
CREATE OR REPLACE FUNCTION pg_temp.t_cambiar(p_ped bigint, p_cli bigint, p_admin uuid, p_prod bigint, p_cant int, p_destino text,
                                             p_precio numeric DEFAULT 1)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.cambiar_cliente_pedido(
    p_ped, p_cli, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio)),
    p_cant * p_precio, NULL, 0, 'ensayo 1473', p_destino);
$fn$;

-- Un crédito (pago a cuenta sin boleta).
CREATE OR REPLACE FUNCTION pg_temp.t_credito(p_cli bigint, p_suc bigint, p_adm uuid, p_monto numeric, p_fecha date)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas, a_cuenta)
  VALUES (p_cli, NULL, p_suc, p_monto, 'efectivo', p_fecha, p_adm, '[saldo a favor]', true)
  RETURNING id;
$fn$;

-- '' si el saldo del cliente cierra contra sus boletas y sus créditos (el predicado de CC-A de
-- auditoria_integridad(), para un cliente); si no, el detalle.
CREATE OR REPLACE FUNCTION pg_temp.t_saldo(p_cli bigint)
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

-- Las violaciones de CC-A de toda la base, de auditoria_integridad().
CREATE OR REPLACE FUNCTION pg_temp.t_cca()
RETURNS int LANGUAGE sql AS $fn$
  SELECT (e->>'violaciones')::int
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
   WHERE e->>'id' = 'CC-A';
$fn$;

-- La barra de una promo, normalizada: la default y las de promo_acumuladores, sin ids.
CREATE OR REPLACE FUNCTION pg_temp.t_barra(p_promo bigint, p_s bigint, p_c bigint, p_q bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT 'default=' || COALESCE(pr.usos_pendientes, 0)
         || CASE pr.producto_regalo_id WHEN p_s THEN '/S' WHEN p_q THEN '/Q' ELSE '/?' END
         || ';acum=' || COALESCE((SELECT string_agg(
                          CASE a.producto_regalo_id WHEN p_s THEN 'S' WHEN p_q THEN 'Q' ELSE '?' END || ':'
                          || CASE a.ajuste_producto_id WHEN p_c THEN 'C' WHEN p_s THEN 'S' WHEN p_q THEN 'Q' ELSE '?' END || ':'
                          || a.usos_pendientes, ',' ORDER BY a.producto_regalo_id)
                        FROM public.promo_acumuladores a WHERE a.promocion_id = p_promo), '')
    FROM public.promociones pr WHERE pr.id = p_promo;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_prod   bigint;
  v_b      bigint;
  v_s      bigint;
  v_q      bigint;
  v_cont   bigint;
  v_p1     bigint;
  v_p2     bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_x      bigint;
  v_w      bigint;
  v_n      bigint;
  v_c      bigint;
  v_h0     bigint;
  v_txt    text;
  v_lt     text;
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

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473');
  v_cca := pg_temp.t_cca();

  -- E1 · pasar X cobrada a C2 con 'pedido_nuevo' y excedente
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 E1 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 E1 C2');
    v_w := pg_temp.t_pedido(v_c2, v_adm, v_prod, 100, v_hoy - 1);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 80, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'excedente_a_favor')::numeric IS DISTINCT FROM 20::numeric
       OR (SELECT estado FROM pedidos WHERE id = v_x) IS DISTINCT FROM 'cancelado'
       OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_x)
       OR (SELECT cliente_id::text || '/' || total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n)
          IS DISTINCT FROM v_c2::text || '/80.00/80.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_w) IS DISTINCT FROM 20::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id IN (v_c1, v_c2) AND pedido_id IS NULL)
       OR (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = v_c2) IS DISTINCT FROM 100::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E1 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · lo mismo con 'cliente_original'
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 E2 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 E2 C2');
    v_w := pg_temp.t_pedido(v_c2, v_adm, v_prod, 100, v_hoy - 1);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 80, 'cliente_original');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT estado FROM pedidos WHERE id = v_x) IS DISTINCT FROM 'cancelado'
       OR (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n) IS DISTINCT FROM '80.00/0.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_w) IS DISTINCT FROM 0::numeric
       OR (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = v_c1 AND pedido_id IS NULL) IS DISTINCT FROM 100::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c2)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E2 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E3 · pasar a C2 una X sin cobrar, con un crédito en C2
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 E3 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 E3 C2');
    v_w := pg_temp.t_pedido(v_c2, v_adm, v_prod, 100, v_hoy - 1);
    v_c := pg_temp.t_credito(v_c2, v_suc, v_adm, 30, v_hoy);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 80, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'excedente_a_favor')::numeric IS DISTINCT FROM 0::numeric
       OR (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n) IS DISTINCT FROM '80.00/0.00'
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS NOT NULL
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_w) IS DISTINCT FROM 0::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c1)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E3 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E4 · ADV-5: el pedido nuevo con un producto que X no tenía
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 E4 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 E4 C2');
    v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473 B');
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 10, v_hoy);
    v_txt := (SELECT stock::text FROM productos WHERE id = v_prod);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_b, 7, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT stock FROM productos WHERE id = v_prod) IS DISTINCT FROM v_txt::int + 10
       OR (SELECT stock FROM productos WHERE id = v_b) IS DISTINCT FROM 993
       OR (SELECT string_agg(producto_id::text || 'x' || cantidad, ',') FROM pedido_items WHERE pedido_id = v_n)
          IS DISTINCT FROM v_b::text || 'x7'
       OR pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2) <> '' THEN
      v_fallas := v_fallas || format('E4 dio %s%s', v_j, pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N1 · VTA-F-4: la foto del IVA de la línea de X, no el de hoy
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 N1 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 N1 C2');
    v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473 N1', 121);
    UPDATE productos SET porcentaje_iva = 21, condicion_iva = 'gravado' WHERE id = v_b;
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_b, 1, v_hoy, 121, 'FC');
    -- La línea se vendió al 10,5: es la foto (el producto hoy está al 21).
    UPDATE pedido_items SET porcentaje_iva = 10.5 WHERE pedido_id = v_x;
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_b, 1, 'pedido_nuevo', 121);
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT string_agg(porcentaje_iva::text || '/' || neto_unitario || '/' || iva_unitario || '/' || ingreso_real_unitario, ',')
             FROM pedido_items WHERE pedido_id = v_n) IS DISTINCT FROM '10.50/109.50/11.50/109.50'
       OR (SELECT tipo_factura || '/' || total || '/' || total_neto || '/' || total_iva || '/' || total_real FROM pedidos WHERE id = v_n)
          IS DISTINCT FROM 'FC/121.00/109.50/11.50/109.50' THEN
      v_fallas := v_fallas || format('N1 (foto 10,5) dio %s · %s · %s', v_j,
        (SELECT string_agg(porcentaje_iva::text || '/' || neto_unitario || '/' || iva_unitario || '/' || ingreso_real_unitario, ',')
           FROM pedido_items WHERE pedido_id = v_n),
        (SELECT tipo_factura || '/' || total || '/' || total_neto || '/' || total_iva || '/' || total_real FROM pedidos WHERE id = v_n));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N1b · con la foto 0 (ambigua) queda la de hoy, y los totales son los de crear_pedido_completo
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 N1b C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 N1b C2');
    v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473 N1b', 121);
    UPDATE productos SET porcentaje_iva = 21, condicion_iva = 'gravado' WHERE id = v_b;
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_b, 1, v_hoy, 121, 'FC');
    UPDATE pedido_items SET porcentaje_iva = 0 WHERE pedido_id = v_x;
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_b, 1, 'pedido_nuevo', 121);
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT string_agg(porcentaje_iva::text || '/' || neto_unitario || '/' || iva_unitario, ',')
             FROM pedido_items WHERE pedido_id = v_n) IS DISTINCT FROM '21.00/100.00/21.00'
       OR (SELECT total_neto || '/' || total_iva || '/' || total_real FROM pedidos WHERE id = v_n)
          IS DISTINCT FROM '100.00/21.00/100.00' THEN
      v_fallas := v_fallas || format('N1b (foto 0) dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N1b dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E5 y N2 · precios en masa sin nada trabado
  BEGIN
    v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473 E5 B');
    v_s := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473 E5 A');
    v_lt := current_setting('lock_timeout');
    v_j := public.actualizar_precios_masivo(jsonb_build_array(
      jsonb_build_object('producto_id', v_b, 'precio_final', 120),
      jsonb_build_object('producto_id', 'abc', 'precio_final', 1),
      jsonb_build_object('producto_id', v_s, 'precio_final', 110)));
    IF (v_j->>'actualizados')::int IS DISTINCT FROM 2
       OR (v_j->>'success')::boolean IS DISTINCT FROM false
       OR jsonb_array_length(v_j->'errores') <> 1
       OR (v_j->'errores'->>0) NOT LIKE 'Error en producto ID desconocido:%'
       OR (SELECT precio FROM productos WHERE id = v_b) IS DISTINCT FROM 120::numeric
       OR (SELECT precio FROM productos WHERE id = v_s) IS DISTINCT FROM 110::numeric
       OR current_setting('lock_timeout') IS DISTINCT FROM v_lt THEN
      v_fallas := v_fallas || format('E5 dio %s (lock_timeout %s, antes %s)', v_j, current_setting('lock_timeout'), v_lt);
    END IF;
    IF v_j->'trabados' IS DISTINCT FROM '[]'::jsonb THEN
      v_fallas := v_fallas || format('N2 la respuesta no trae trabados vacío: %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E6 · el regalo de una promo por la RPC rota la barra como el UPDATE directo de antes
  BEGIN
    v_s := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473 E6 S');
    v_q := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473 E6 Q');
    v_cont := pg_temp.t_producto(v_suc, 'ZZ ensayo 1473 E6 C');
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                             ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes)
    VALUES ('ZZ ensayo 1473 E6 rpc', 'bonificacion', v_hoy - 1, v_suc, false, v_s, true, v_cont, 6, 1, 3),
           ('ZZ ensayo 1473 E6 directo', 'bonificacion', v_hoy - 1, v_suc, false, v_s, true, v_cont, 6, 1, 3);
    v_p1 := (SELECT id FROM promociones WHERE nombre = 'ZZ ensayo 1473 E6 rpc' AND sucursal_id = v_suc);
    v_p2 := (SELECT id FROM promociones WHERE nombre = 'ZZ ensayo 1473 E6 directo' AND sucursal_id = v_suc);
    v_j := public.cambiar_regalo_promocion(v_p1, v_q, v_cont, true);
    UPDATE promociones SET producto_regalo_id = v_q, ajuste_producto_id = v_cont, ajuste_automatico = true WHERE id = v_p2;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'cambio')::boolean IS DISTINCT FROM true
       OR pg_temp.t_barra(v_p1, v_s, v_cont, v_q) IS DISTINCT FROM pg_temp.t_barra(v_p2, v_s, v_cont, v_q)
       OR pg_temp.t_barra(v_p1, v_s, v_cont, v_q) IS DISTINCT FROM 'default=0/Q;acum=S:C:3.00' THEN
      v_fallas := v_fallas || format('E6 dio %s · rpc %s · directo %s', v_j,
        pg_temp.t_barra(v_p1, v_s, v_cont, v_q), pg_temp.t_barra(v_p2, v_s, v_cont, v_q));
    END IF;
    v_j := public.cambiar_regalo_promocion(v_p1, v_q, v_cont, true);
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR (v_j->>'cambio')::boolean IS DISTINCT FROM false THEN
      v_fallas := v_fallas || format('E6 sin cambios dio %s', v_j);
    END IF;
    v_j := public.cambiar_regalo_promocion(v_p1, -1, v_cont, true);
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('E6 con un producto que no existe dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E6 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N3 · ADV-4: el total entra al historial antes que el estado de pago que causa
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1473 N3');
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_h0 := COALESCE((SELECT max(id) FROM pedido_historial WHERE pedido_id = v_x), 0);
    v_j := public.actualizar_pedido_items(v_x,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 120, 'precio_unitario', 1)), v_adm, NULL, NULL);
    v_txt := (SELECT string_agg(campo_modificado || ':' || valor_anterior || '>' || valor_nuevo, ' ' ORDER BY id)
                FROM pedido_historial
               WHERE pedido_id = v_x AND id > v_h0 AND campo_modificado IN ('total', 'estado_pago'));
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       -- La última es la fila que escribe actualizar_pedido_items por su cuenta, al final.
       OR v_txt IS DISTINCT FROM 'total:100.00>120.00 estado_pago:pagado>parcial estado_pago:parcial>pagado total:100.00>120' THEN
      v_fallas := v_fallas || format('N3 el historial quedó [%s] (%s)', v_txt, v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ473';
  EXCEPTION
    WHEN SQLSTATE 'ZZ473' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · el orden del pre-bloqueo, el trigger y los permisos
  v_txt := (SELECT prosrc FROM pg_proc
             WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure);
  IF v_txt !~ 'WHERE id = ANY\(v_alcanza\)\s+AND sucursal_id = v_sucursal\s+ORDER BY id\s+FOR UPDATE;.*FROM productos\s+WHERE sucursal_id = v_sucursal.*_contenedores_de_promos\(v_promos, v_sucursal\).*ORDER BY id\s+FOR UPDATE;\s+PERFORM 1\s+FROM promociones.*FOR UPDATE;\s+PERFORM 1\s+FROM recorridos.*FOR NO KEY UPDATE;\s+PERFORM 1\s+FROM pagos.*FOR UPDATE;\s+PERFORM 1\s+FROM clientes.*FOR NO KEY UPDATE;\s+SELECT \* INTO v_pedido FROM pedidos WHERE id = p_pedido_id' THEN
    v_fallas := v_fallas || 'L1 cambiar_cliente_pedido no toma boletas, productos, promos, rutas, pagos y clientes antes que X'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'trg_historial_cambio_pedido')
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'trigger_registrar_cambio_pedido') THEN
    v_fallas := v_fallas || 'L1 el trigger del historial no se llama trg_historial_cambio_pedido'::text;
  END IF;
  IF has_column_privilege('authenticated', 'public.promociones', 'producto_regalo_id', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.promociones', 'ajuste_producto_id', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.promociones', 'unidades_por_bloque', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.promociones', 'nombre', 'UPDATE')
     OR NOT has_table_privilege('authenticated', 'public.promociones', 'INSERT')
     OR NOT has_table_privilege('authenticated', 'public.promociones', 'DELETE') THEN
    v_fallas := v_fallas || 'L1 los grants REST de promociones no son los esperados'::text;
  END IF;
  IF to_regprocedure('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean)') IS NULL
     OR has_function_privilege('anon', 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 cambiar_regalo_promocion no existe o sus EXECUTE no son los esperados'::text;
  END IF;
  IF has_function_privilege('anon', 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.actualizar_precios_masivo(jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.actualizar_precios_masivo(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.registrar_cambio_pedido()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 los EXECUTE de cambiar_cliente_pedido, actualizar_precios_masivo o registrar_cambio_pedido cambiaron'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · E1 E2 E3 E4 E5 E6 N1 N1b N2 N3 L1';
 END;
END
$ensayo$;
