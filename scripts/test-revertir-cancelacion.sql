-- Ensayo de la migración NNN_revertir_cancelacion: el admin revierte la cancelación de un pedido.
--
--   A0 · revertir_cancelacion_pedido y pedido_cancelacion_foto existen; la foto es sólo de server.
--   A1 · Común, con bolsa (#1050): V×10 a $10 (total 100) sale de un lote L (bolsa 0: L 90, huella L:10),
--        asignado a un chofer; entra una compra sin vencimiento (+20 a la bolsa); cancelado ('otro'): L 100,
--        bolsa 20. Revertido: pendiente, sin chofer ni motivo, total 100, stock 110 con L 90, bolsa 20 y
--        huella L:10 (sin el arreglo: L 100, bolsa 10), el último movimiento 'pedido_cancelacion_revertida',
--        la foto cerrada y el historial con 'pendiente - Cancelación revertida'. Otra vez: «no está cancelado».
--   A2 · Cobros sueltos con sus marcas: un cobro de 60 (notas «cobro de mostrador») y un crédito de 20 que
--        se aplicó a la boleta (de_saldo_a_favor); cancelada (80 sueltos). Revertida: los dos vuelven
--        (80/100) como estaban: el de 60 sin de_saldo_a_favor ni a_cuenta y con su nota, el de 20 con
--        de_saldo_a_favor; nada suelto.
--   A3 · Cobro aplicado a otra boleta: B debe 40, X cobrada 100 y cancelada (40 van a B, 60 sueltos).
--        Revertida: vuelven los 60 (X 60/100) y B sigue 40/40.
--   A4 · Sin stock: cancelada y el stock bajado a 5. Revertir se rechaza con el producto y «faltan 5», y
--        el pedido sigue cancelado con el stock en 5.
--   A5 · Cambio de cliente (simulado en la foto y el pedido): se rechaza.
--   A6 · Vale blanco entregado y cancelado: se rechaza.
--   A7 · Falta de stock con un lote (bolsa 10, lote 30 después del alta): la cancelación merma 10 (neto
--        0). Revertida: la merma queda anulada, el stock y el lote no cambian, el pedido pendiente.
--   A8 · Regalo sin cupo: promo de límite 1, X con V×10 + R×1, cancelada; Y toma el cupo. Revertida: X
--        vuelve sin la línea de regalo (regalos_quitados = 1) y el stock de R no baja por ella.
--   A9 · No admin (encargado): se rechaza y el pedido sigue cancelado.
--   A10 · Un UPDATE directo cancelado → pendiente se sigue rechazando: como postgres sin la marca, y
--         como authenticated con la marca puesta.
--   A11 · Sin foto (una cancelación vieja): cobrada 50, cancelada y sin foto. Revertida: total 100 desde
--         las líneas, sin_foto, y el cobro sigue suelto.
--   A12 · Falta de stock con un regalo del mismo producto que se saca por cupo: A×10 + A×2 de regalo (mueve
--         stock, límite 2), cancelado por falta de stock (merma de 12); otro pedido toma el cupo. Revertido:
--         la merma de 12 se anula y queda una nueva de 2 (al mismo costo); el stock no cambia (sin el
--         arreglo: +2 fantasma y la merma de 2 desaparece).
--   A13 · Lo mismo con el regalo de otro producto R: la merma de R (2) se anula y vuelve a mermarse; el
--         stock de R no cambia y la de A (10) queda anulada.
--   A14 · La promo cambió de tipo (mueve stock → no mueve) después de cancelar: el regalo NO se saca, baja
--         su stock (la foto lo mueve) y la barra de la promo no cambia.
--   A15 · Llegar al cupo apaga la promo: límite 1, X con R×1 cancelado y la promo prendida. Revertido: la
--         promo queda apagada y la respuesta lo dice.
--   A16 · El fardo del contenedor vuelve a salir de su lote (M3-1): promo de fracción con R de contenedor
--         (un lote L de 5, bolsa 0); X con R×6 cierra un bloque (L 4); entra una compra a la bolsa (+3);
--         cancelado: el fardo vuelve a L (L 5). Revertido: L 4, R 7, y el bloque nuevo dice que salió de L
--         (sin el arreglo: L 5 y bolsa 2).
--   En cada caso con plata, clientes.saldo_cuenta cierra contra sus boletas y créditos; en A2, A3, A7, A8, A12 y A16
--   ningún check de auditoria_integridad() cambia (CC-A, CC-B, CC-C y STK-D siempre, y todo el que tenga
--   violaciones).
--
-- Corre sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción, y
-- cada caso en un sub-bloque que se revierte. Sin la migración da 'ENSAYO FALLÓ' en A0.
--
-- Fixtures: una sucursal activa con un admin y un encargado activos y la caja de hoy abierta. El resto nace
-- en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.rc_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_como(p_uid uuid)
RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo revertir', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_producto(p_suc bigint, p_nombre text, p_stock int)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo revertir ' || p_nombre, 10, p_stock, 5, p_suc)
  RETURNING id;
$fn$;

-- Un pedido con las líneas dadas (jsonb), del día p_fecha.
CREATE OR REPLACE FUNCTION pg_temp.rc_alta(p_cli bigint, p_adm uuid, p_items jsonb, p_total numeric, p_fecha date,
                                           p_tipo text DEFAULT 'ZZ')
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(p_cli, p_total, p_adm, p_items, 'ensayo revertir', 'efectivo', 'pendiente',
                                        p_fecha, p_tipo);
  PERFORM pg_temp.rc_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_linea(p_prod bigint, p_cant int, p_precio numeric)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_cobro(p_ped bigint, p_monto numeric)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id)
  SELECT cliente_id, id, sucursal_id, p_monto, 'efectivo', public._tablero_hoy(), usuario_id
    FROM public.pedidos WHERE id = p_ped
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_cancelar(p_ped bigint, p_tipo text DEFAULT 'otro')
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cancelar_pedido_con_stock(p_ped, 'ensayo revertir', NULL, p_tipo);
  PERFORM pg_temp.rc_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo cancelar el pedido %: %', p_ped, v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_revertir(p_ped bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.revertir_cancelacion_pedido(p_ped, NULL);
  PERFORM pg_temp.rc_reset();
  RETURN v_res;
END
$fn$;

-- Una promo de regalo p_regalo. Sin fracción: mueve stock. Con fracción: bloques de 6 con el propio
-- regalo de contenedor (1 por bloque).
CREATE OR REPLACE FUNCTION pg_temp.rc_promo(p_suc bigint, p_regalo bigint, p_limite int, p_fraccion boolean)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, unidades_por_bloque,
                                  stock_por_bloque, ajuste_producto_id, limite_usos)
  VALUES ('ZZ ensayo revertir', 'bonificacion', public._tablero_hoy() - 1, p_suc, NOT p_fraccion, p_regalo,
          p_fraccion, CASE WHEN p_fraccion THEN 6 END, CASE WHEN p_fraccion THEN 1 END,
          CASE WHEN p_fraccion THEN p_regalo END, p_limite)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_regalo(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                                              'es_bonificacion', true, 'promocion_id', p_promo));
$fn$;

-- Una compra sin vencimiento: entra a la bolsa.
CREATE OR REPLACE FUNCTION pg_temp.rc_compra_bolsa(p_prod bigint, p_cant int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'compra', true);
  UPDATE public.productos SET stock = stock + p_cant WHERE id = p_prod;
  PERFORM pg_temp.rc_reset();
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_lote(p_lote bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT cantidad_restante FROM public.producto_lotes WHERE id = p_lote;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_stock(p_prod bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT stock FROM public.productos WHERE id = p_prod;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_estado(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT estado || ' ' || COALESCE(monto_pagado, 0)::numeric(12,2)::text || '/' || total::numeric(12,2)::text
    FROM public.pedidos WHERE id = p_ped;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_saldo(p_cli bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT CASE WHEN abs(COALESCE(c.saldo_cuenta, 0) - (b.deuda - f.favor)) <= 0.01 THEN ''
              ELSE format(' saldo_cuenta de %s=%s esperado=%s', p_cli, c.saldo_cuenta, b.deuda - f.favor) END
    FROM public.clientes c,
         LATERAL (SELECT COALESCE(sum(total - COALESCE(monto_pagado, 0)), 0) AS deuda FROM public.pedidos
                   WHERE cliente_id = p_cli AND estado <> 'cancelado') b,
         LATERAL (SELECT COALESCE(sum(monto), 0) AS favor FROM public.pagos
                   WHERE cliente_id = p_cli AND pedido_id IS NULL) f
   WHERE c.id = p_cli;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_suelto(p_cli bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(sum(monto), 0) FROM public.pagos WHERE cliente_id = p_cli AND pedido_id IS NULL;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rc_checks()
RETURNS text LANGUAGE sql AS $fn$
  SELECT string_agg(c->>'id' || '=' || (c->>'violaciones'), ' ' ORDER BY c->>'id')
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
   WHERE (c->>'violaciones')::bigint > 0 OR c->>'id' IN ('CC-A', 'CC-B', 'CC-C', 'STK-D');
$fn$;

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_suc    bigint;
  v_adm    uuid;
  v_enc    uuid;
  v_chofer uuid;
  v_cli    bigint;
  v_cli2   bigint;
  v_p      bigint;
  v_r      bigint;
  v_promo  bigint;
  v_x      bigint;
  v_y      bigint;
  v_b      bigint;
  v_pago   bigint;
  v_lote   bigint;
  v_j      jsonb;
  v_txt    text;
  v_n      bigint;
  v_n2     bigint;
  v_fallas text[] := '{}';
  v_checks text;
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id, enc.usuario_id
    INTO v_suc, v_adm, v_enc
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado'
                   ORDER BY us.usuario_id LIMIT 1) enc ON true
   WHERE s.activa
     AND COALESCE(public.ultima_fecha_caja_cerrada(s.id), v_hoy - 1) < v_hoy
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin, un encargado y la caja de hoy abierta';
  END IF;
  SELECT us.usuario_id INTO v_chofer
    FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.activo AND pf.rol = 'transportista'
   ORDER BY us.usuario_id LIMIT 1;

  PERFORM pg_temp.rc_como(v_adm);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- A0 · lo que crea la migración
  IF to_regprocedure('public.revertir_cancelacion_pedido(bigint,uuid)') IS NULL
     OR to_regclass('public.pedido_cancelacion_foto') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · A0 falta revertir_cancelacion_pedido o pedido_cancelacion_foto';
  END IF;
  IF has_function_privilege('anon', 'public.revertir_cancelacion_pedido(bigint,uuid)', 'EXECUTE')
     OR has_table_privilege('authenticated', 'public.pedido_cancelacion_foto', 'SELECT')
     OR has_table_privilege('anon', 'public.pedido_cancelacion_foto', 'SELECT') THEN
    v_fallas := v_fallas || 'A0 la RPC es de anon o la foto se lee por la API'::text;
  END IF;

  v_checks := pg_temp.rc_checks();

  -- A1 · común
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A1');
    v_p := pg_temp.rc_producto(v_suc, 'A1', 100);
    -- Todo en un lote (bolsa 0): el alta y la reversión salen del lote y dejan huella.
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
    VALUES (v_p, v_suc, v_hoy + 90, 100, 100, 'manual')
    RETURNING id INTO v_lote;
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    IF v_chofer IS NOT NULL THEN
      UPDATE pedidos SET estado = 'asignado', transportista_id = v_chofer WHERE id = v_x;
    END IF;
    -- Con bolsa (un ensayo de lotes con bolsa 0 no prueba nada): +20 sin vencimiento.
    PERFORM pg_temp.rc_compra_bolsa(v_p, 20);
    PERFORM pg_temp.rc_cancelar(v_x);
    IF pg_temp.rc_stock(v_p) <> 120 OR pg_temp.rc_lote(v_lote) <> 100 THEN
      v_fallas := v_fallas || format('A1 la cancelación dejó el stock en %s y el lote en %s', pg_temp.rc_stock(v_p),
                                     pg_temp.rc_lote(v_lote));
    END IF;
    v_j := pg_temp.rc_revertir(v_x);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('A1 no revirtió: %s', v_j);
    ELSE
      SELECT count(*) INTO v_n FROM pedidos
       WHERE id = v_x AND estado = 'pendiente' AND total = 100 AND transportista_id IS NULL
         AND motivo_cancelacion IS NULL AND motivo_cancelacion_tipo IS NULL AND total_real = 100;
      IF v_n <> 1 OR pg_temp.rc_stock(v_p) <> 110 THEN
        v_fallas := v_fallas || format('A1 quedó %s con stock %s (se esperaba pendiente 0/100 sin chofer ni motivo y 110)',
                                       pg_temp.rc_estado(v_x), pg_temp.rc_stock(v_p));
      END IF;
      SELECT origen || ':' || COALESCE(referencia_id::text, '') INTO v_txt
        FROM stock_historico WHERE producto_id = v_p ORDER BY id DESC LIMIT 1;
      IF v_txt IS DISTINCT FROM 'pedido_cancelacion_revertida:' || v_x THEN
        v_fallas := v_fallas || format('A1 el último movimiento de stock es %s', v_txt);
      END IF;
      SELECT COALESCE(sum(pil.cantidad), 0) INTO v_n
        FROM pedido_item_lotes pil JOIN pedido_items pi ON pi.id = pil.pedido_item_id
       WHERE pi.pedido_id = v_x AND pil.lote_id = v_lote;
      IF v_n <> 10 OR pg_temp.rc_lote(v_lote) <> 90 THEN
        v_fallas := v_fallas || format('A1 la huella quedó en %s y el lote en %s, bolsa %s (se esperaba 10, 90 y 20)', v_n,
                                       pg_temp.rc_lote(v_lote), pg_temp.rc_stock(v_p) - pg_temp.rc_lote(v_lote));
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pedido_cancelacion_foto WHERE pedido_id = v_x AND revertida_at IS NOT NULL
                       AND revertida_por = v_adm AND estado_anterior IN ('asignado', 'pendiente')) THEN
        v_fallas := v_fallas || 'A1 la foto no quedó cerrada'::text;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pedido_historial WHERE pedido_id = v_x AND valor_anterior = 'cancelado'
                       AND valor_nuevo LIKE 'pendiente - Cancelación revertida%') THEN
        v_fallas := v_fallas || 'A1 falta la fila del historial'::text;
      END IF;
      v_j := pg_temp.rc_revertir(v_x);
      IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE '%no está cancelado%' THEN
        v_fallas := v_fallas || format('A1 revertir dos veces dio %s', v_j);
      END IF;
    END IF;
    IF pg_temp.rc_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || ('A1' || pg_temp.rc_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC1';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC1' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A1 error: ' || SQLERRM);
  END;

  -- A2 · el cobro suelto vuelve
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A2');
    v_p := pg_temp.rc_producto(v_suc, 'A2', 100);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    v_pago := pg_temp.rc_cobro(v_x, 60);
    UPDATE pagos SET notas = 'cobro de mostrador' WHERE id = v_pago;
    -- Un crédito suelto que se aplicó a la boleta: queda de_saldo_a_favor (lo pone su trigger).
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas, a_cuenta)
    VALUES (v_cli, NULL, v_suc, 20, 'efectivo', v_hoy, v_adm, '[saldo a favor]', true)
    RETURNING id INTO v_b;
    UPDATE pagos SET pedido_id = v_x, notas = NULL WHERE id = v_b;
    PERFORM pg_temp.rc_cancelar(v_x);
    IF pg_temp.rc_suelto(v_cli) <> 80 THEN
      v_fallas := v_fallas || format('A2 la cancelación dejó %s sueltos', pg_temp.rc_suelto(v_cli));
    END IF;
    v_j := pg_temp.rc_revertir(v_x);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.rc_estado(v_x) <> 'pendiente 80.00/100.00'
       OR pg_temp.rc_suelto(v_cli) <> 0
       OR (v_j->>'cobro_vuelto')::numeric <> 80
       OR NOT EXISTS (SELECT 1 FROM pagos WHERE id = v_pago AND pedido_id = v_x AND NOT de_saldo_a_favor
                        AND NOT COALESCE(a_cuenta, false) AND notas = 'cobro de mostrador')
       OR NOT EXISTS (SELECT 1 FROM pagos WHERE id = v_b AND pedido_id = v_x AND de_saldo_a_favor AND a_cuenta
                        AND notas IS NULL) THEN
      v_fallas := v_fallas || format('A2 quedó %s, %s sueltos (%s); pagos: %s', pg_temp.rc_estado(v_x), pg_temp.rc_suelto(v_cli), v_j,
                                     (SELECT jsonb_agg(jsonb_build_object('id', id, 'pedido', pedido_id, 'sf', de_saldo_a_favor,
                                                                          'ac', a_cuenta, 'notas', notas) ORDER BY id)
                                        FROM pagos WHERE id IN (v_pago, v_b)));
    END IF;
    IF pg_temp.rc_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || ('A2' || pg_temp.rc_saldo(v_cli));
    END IF;
    IF pg_temp.rc_checks() IS DISTINCT FROM v_checks THEN
      v_fallas := v_fallas || format('A2 los checks pasaron de %s a %s', v_checks, pg_temp.rc_checks());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC2';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC2' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A2 error: ' || SQLERRM);
  END;

  -- A3 · lo aplicado a otra boleta no vuelve
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A3');
    v_p := pg_temp.rc_producto(v_suc, 'A3', 100);
    v_b := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 4, 10), 40, v_hoy - 1);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    PERFORM pg_temp.rc_cobro(v_x, 100);
    PERFORM pg_temp.rc_cancelar(v_x);
    IF pg_temp.rc_estado(v_b) <> 'pendiente 40.00/40.00' OR pg_temp.rc_suelto(v_cli) <> 60 THEN
      v_fallas := v_fallas || format('A3 la cancelación dejó B %s y %s sueltos', pg_temp.rc_estado(v_b), pg_temp.rc_suelto(v_cli));
    END IF;
    v_j := pg_temp.rc_revertir(v_x);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.rc_estado(v_x) <> 'pendiente 60.00/100.00'
       OR pg_temp.rc_estado(v_b) <> 'pendiente 40.00/40.00'
       OR pg_temp.rc_suelto(v_cli) <> 0 THEN
      v_fallas := v_fallas || format('A3 quedó X %s, B %s, %s sueltos (%s)', pg_temp.rc_estado(v_x),
                                     pg_temp.rc_estado(v_b), pg_temp.rc_suelto(v_cli), v_j);
    END IF;
    IF pg_temp.rc_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || ('A3' || pg_temp.rc_saldo(v_cli));
    END IF;
    IF pg_temp.rc_checks() IS DISTINCT FROM v_checks THEN
      v_fallas := v_fallas || format('A3 los checks pasaron de %s a %s', v_checks, pg_temp.rc_checks());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC3';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC3' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A3 error: ' || SQLERRM);
  END;

  -- A4 · sin stock se rechaza
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A4');
    v_p := pg_temp.rc_producto(v_suc, 'A4', 100);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x);
    PERFORM set_config('app.stock_origen', 'ajuste_manual', true);
    UPDATE productos SET stock = 5 WHERE id = v_p;
    PERFORM pg_temp.rc_reset();
    v_j := pg_temp.rc_revertir(v_x);
    IF COALESCE((v_j->>'success')::boolean, true)
       OR v_j->>'error' NOT LIKE '%stock insuficiente%faltan 5%'
       OR pg_temp.rc_estado(v_x) NOT LIKE 'cancelado %'
       OR pg_temp.rc_stock(v_p) <> 5 THEN
      v_fallas := v_fallas || format('A4 dio %s y quedó %s con stock %s', v_j, pg_temp.rc_estado(v_x), pg_temp.rc_stock(v_p));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC4';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC4' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A4 error: ' || SQLERRM);
  END;

  -- A5 · cambio de cliente (simulado: la foto y el pedido lo dicen)
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A5');
    v_p := pg_temp.rc_producto(v_suc, 'A5', 100);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x);
    UPDATE pedido_cancelacion_foto SET tipo = 'cambio_de_cliente' WHERE pedido_id = v_x;
    UPDATE pedidos SET motivo_cancelacion_tipo = 'cambio_de_cliente' WHERE id = v_x;
    v_j := pg_temp.rc_revertir(v_x);
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE '%cambio de cliente%'
       OR pg_temp.rc_stock(v_p) <> 100 THEN
      v_fallas := v_fallas || format('A5 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC5';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC5' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A5 error: ' || SQLERRM);
  END;

  -- A6 · vale blanco entregado
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A6');
    UPDATE clientes SET tipo_factura_default = 'VB' WHERE id = v_cli;
    v_p := pg_temp.rc_producto(v_suc, 'A6', 100);
    -- El vale nace entregado, a precio 0 (mig 317).
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 0), 0, v_hoy, 'VB');
    UPDATE pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now()
     WHERE id = v_x AND estado <> 'entregado';
    PERFORM pg_temp.rc_cancelar(v_x);
    v_j := pg_temp.rc_revertir(v_x);
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE '%vale blanco%'
       OR pg_temp.rc_estado(v_x) NOT LIKE 'cancelado %' THEN
      v_fallas := v_fallas || format('A6 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC6';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC6' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A6 error: ' || SQLERRM);
  END;

  -- A7 · falta de stock: la merma se anula, el stock y el lote no cambian
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A7');
    v_p := pg_temp.rc_producto(v_suc, 'A7', 50);
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
    VALUES (v_p, v_suc, v_hoy + 90, 30, 30, 'manual')
    RETURNING id INTO v_lote;
    -- bolsa 20, lote 30: el alta come 10 de la bolsa.
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x, 'falta_stock');
    SELECT count(*) INTO v_n FROM mermas_stock WHERE producto_id = v_p AND anulada_at IS NULL;
    IF v_n <> 1 OR pg_temp.rc_stock(v_p) <> 40 THEN
      v_fallas := v_fallas || format('A7 la cancelación dejó %s mermas y stock %s', v_n, pg_temp.rc_stock(v_p));
    END IF;
    v_j := pg_temp.rc_revertir(v_x);
    SELECT count(*) INTO v_n FROM mermas_stock WHERE producto_id = v_p AND anulada_at IS NULL;
    SELECT count(*) INTO v_n2 FROM mermas_stock WHERE producto_id = v_p AND anulada_at IS NOT NULL AND anulada_por = v_adm;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'mermas_anuladas')::int <> 1 OR v_n <> 0 OR v_n2 <> 1
       OR pg_temp.rc_stock(v_p) <> 40
       OR (SELECT cantidad_restante FROM producto_lotes WHERE id = v_lote) <> 30
       OR pg_temp.rc_estado(v_x) NOT LIKE 'pendiente %' THEN
      v_fallas := v_fallas || format('A7 dio %s: %s mermas vivas, %s anuladas, stock %s, lote %s, %s', v_j, v_n, v_n2,
                                     pg_temp.rc_stock(v_p), (SELECT cantidad_restante FROM producto_lotes WHERE id = v_lote),
                                     pg_temp.rc_estado(v_x));
    END IF;
    IF pg_temp.rc_checks() IS DISTINCT FROM v_checks THEN
      v_fallas := v_fallas || format('A7 los checks pasaron de %s a %s', v_checks, pg_temp.rc_checks());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC7';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC7' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A7 error: ' || SQLERRM);
  END;

  -- A8 · el regalo sin cupo no vuelve
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A8');
    v_cli2 := pg_temp.rc_cliente(v_suc, 'ZZ revertir A8 otro');
    v_p := pg_temp.rc_producto(v_suc, 'A8 venta', 100);
    v_r := pg_temp.rc_producto(v_suc, 'A8 regalo', 100);
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                             ajuste_automatico, limite_usos)
    VALUES ('ZZ ensayo revertir A8', 'bonificacion', v_hoy - 1, v_suc, true, v_r, false, 1)
    RETURNING id INTO v_promo;
    v_j := pg_temp.rc_linea(v_p, 10, 10) || jsonb_build_array(jsonb_build_object(
             'producto_id', v_r, 'cantidad', 1, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo));
    v_x := pg_temp.rc_alta(v_cli, v_adm, v_j, 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x);
    v_y := pg_temp.rc_alta(v_cli2, v_adm, v_j, 100, v_hoy);
    -- R: 100 − 1 de Y.
    v_j := pg_temp.rc_revertir(v_x);
    SELECT count(*) INTO v_n FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR jsonb_array_length(v_j->'regalos_quitados') <> 1 OR v_n <> 0
       OR pg_temp.rc_stock(v_r) <> 99 OR pg_temp.rc_stock(v_p) <> 80
       OR pg_temp.rc_estado(v_x) <> 'pendiente 0.00/100.00' THEN
      v_fallas := v_fallas || format('A8 dio %s: %s regalos en X, R en %s, V en %s, %s', v_j, v_n,
                                     pg_temp.rc_stock(v_r), pg_temp.rc_stock(v_p), pg_temp.rc_estado(v_x));
    END IF;
    IF pg_temp.rc_checks() IS DISTINCT FROM v_checks THEN
      v_fallas := v_fallas || format('A8 los checks pasaron de %s a %s', v_checks, pg_temp.rc_checks());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC8';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC8' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A8 error: ' || SQLERRM);
  END;

  -- A9 · no admin
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A9');
    v_p := pg_temp.rc_producto(v_suc, 'A9', 100);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x);
    PERFORM pg_temp.rc_como(v_enc);
    v_j := pg_temp.rc_revertir(v_x);
    PERFORM pg_temp.rc_como(v_adm);
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE '%No autorizado%'
       OR pg_temp.rc_estado(v_x) NOT LIKE 'cancelado %' OR pg_temp.rc_stock(v_p) <> 100 THEN
      v_fallas := v_fallas || format('A9 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRC9';
  EXCEPTION
    WHEN SQLSTATE 'ZZRC9' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A9 error: ' || SQLERRM);
  END;
  PERFORM pg_temp.rc_como(v_adm);

  -- A10 · el UPDATE directo sigue rechazado
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A10');
    v_p := pg_temp.rc_producto(v_suc, 'A10', 100);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x);
    v_txt := NULL;
    BEGIN
      UPDATE pedidos SET estado = 'pendiente', motivo_cancelacion = NULL, motivo_cancelacion_tipo = NULL WHERE id = v_x;
    EXCEPTION WHEN OTHERS THEN v_txt := SQLSTATE;
    END;
    IF v_txt IS DISTINCT FROM '42501' THEN
      v_fallas := v_fallas || format('A10 el UPDATE como postgres sin la marca dio %s', COALESCE(v_txt, 'OK'));
    END IF;
    v_txt := NULL;
    BEGIN
      PERFORM set_config('app.revertir_cancelacion', v_x::text, true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      UPDATE pedidos SET estado = 'pendiente', motivo_cancelacion = NULL, motivo_cancelacion_tipo = NULL WHERE id = v_x;
      RAISE EXCEPTION 'paso' USING ERRCODE = 'ZZRCP';
    EXCEPTION
      WHEN SQLSTATE 'ZZRCP' THEN v_txt := 'OK';
      WHEN OTHERS THEN v_txt := SQLSTATE;
    END;
    PERFORM set_config('app.revertir_cancelacion', '', true);
    IF v_txt IS DISTINCT FROM '42501' THEN
      v_fallas := v_fallas || format('A10 el UPDATE como authenticated con la marca dio %s', COALESCE(v_txt, 'nada'));
    END IF;
    IF pg_temp.rc_estado(v_x) NOT LIKE 'cancelado %' THEN
      v_fallas := v_fallas || format('A10 el pedido quedó %s', pg_temp.rc_estado(v_x));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRCA';
  EXCEPTION
    WHEN SQLSTATE 'ZZRCA' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A10 error: ' || SQLERRM);
  END;

  -- A11 · una cancelación sin foto
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A11');
    v_p := pg_temp.rc_producto(v_suc, 'A11', 100);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10), 100, v_hoy);
    PERFORM pg_temp.rc_cobro(v_x, 50);
    PERFORM pg_temp.rc_cancelar(v_x);
    DELETE FROM pedido_cancelacion_foto WHERE pedido_id = v_x;
    v_j := pg_temp.rc_revertir(v_x);
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR NOT (v_j->>'sin_foto')::boolean
       OR pg_temp.rc_estado(v_x) <> 'pendiente 0.00/100.00'
       OR pg_temp.rc_suelto(v_cli) <> 50 OR pg_temp.rc_stock(v_p) <> 90 THEN
      v_fallas := v_fallas || format('A11 dio %s: %s, %s sueltos, stock %s', v_j, pg_temp.rc_estado(v_x),
                                     pg_temp.rc_suelto(v_cli), pg_temp.rc_stock(v_p));
    END IF;
    IF pg_temp.rc_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || ('A11' || pg_temp.rc_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRCB';
  EXCEPTION
    WHEN SQLSTATE 'ZZRCB' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A11 error: ' || SQLERRM);
  END;

  -- A12 · falta de stock con un regalo del mismo producto que se saca por cupo
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A12');
    v_cli2 := pg_temp.rc_cliente(v_suc, 'ZZ revertir A12 otro');
    v_p := pg_temp.rc_producto(v_suc, 'A12', 100);
    v_promo := pg_temp.rc_promo(v_suc, v_p, 2, false);
    v_j := pg_temp.rc_linea(v_p, 10, 10) || pg_temp.rc_regalo(v_p, 2, v_promo);
    v_x := pg_temp.rc_alta(v_cli, v_adm, v_j, 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x, 'falta_stock');
    v_y := pg_temp.rc_alta(v_cli2, v_adm, v_j, 100, v_hoy);
    v_n := pg_temp.rc_stock(v_p);
    v_j := pg_temp.rc_revertir(v_x);
    SELECT count(*) FILTER (WHERE anulada_at IS NOT NULL AND cantidad = 12),
           count(*) FILTER (WHERE anulada_at IS NULL AND cantidad = 2
                              AND observaciones LIKE 'Cancelacion revertida, pedido #' || v_x || '%')
      INTO v_n2, v_lote
      FROM mermas_stock WHERE producto_id = v_p;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR jsonb_array_length(v_j->'regalos_quitados') <> 1
       OR pg_temp.rc_stock(v_p) <> v_n
       OR v_n2 <> 1 OR v_lote <> 1
       OR (SELECT sum(cantidad) FROM mermas_stock WHERE producto_id = v_p AND anulada_at IS NULL) <> 2
       OR (SELECT costo_unitario FROM mermas_stock WHERE producto_id = v_p AND anulada_at IS NULL)
          IS DISTINCT FROM (SELECT costo_unitario FROM mermas_stock WHERE producto_id = v_p AND anulada_at IS NOT NULL) THEN
      v_fallas := v_fallas || format('A12 dio %s: stock %s (antes %s), mermas %s', v_j, pg_temp.rc_stock(v_p), v_n,
                                     (SELECT jsonb_agg(jsonb_build_object('c', cantidad, 'anulada', anulada_at IS NOT NULL,
                                                                          'costo', costo_unitario) ORDER BY id)
                                        FROM mermas_stock WHERE producto_id = v_p));
    END IF;
    IF pg_temp.rc_checks() IS DISTINCT FROM v_checks THEN
      v_fallas := v_fallas || format('A12 los checks pasaron de %s a %s', v_checks, pg_temp.rc_checks());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRCC';
  EXCEPTION
    WHEN SQLSTATE 'ZZRCC' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A12 error: ' || SQLERRM);
  END;

  -- A13 · lo mismo con el regalo de otro producto
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A13');
    v_cli2 := pg_temp.rc_cliente(v_suc, 'ZZ revertir A13 otro');
    v_p := pg_temp.rc_producto(v_suc, 'A13 venta', 100);
    v_r := pg_temp.rc_producto(v_suc, 'A13 regalo', 100);
    v_promo := pg_temp.rc_promo(v_suc, v_r, 2, false);
    v_j := pg_temp.rc_linea(v_p, 10, 10) || pg_temp.rc_regalo(v_r, 2, v_promo);
    v_x := pg_temp.rc_alta(v_cli, v_adm, v_j, 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x, 'falta_stock');
    v_y := pg_temp.rc_alta(v_cli2, v_adm, v_j, 100, v_hoy);
    v_n := pg_temp.rc_stock(v_r);
    v_n2 := pg_temp.rc_stock(v_p);
    v_j := pg_temp.rc_revertir(v_x);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.rc_stock(v_r) <> v_n OR pg_temp.rc_stock(v_p) <> v_n2
       OR (SELECT COALESCE(sum(cantidad), 0) FROM mermas_stock WHERE producto_id = v_r AND anulada_at IS NULL) <> 2
       OR (SELECT COALESCE(sum(cantidad), 0) FROM mermas_stock WHERE producto_id = v_p AND anulada_at IS NULL) <> 0 THEN
      v_fallas := v_fallas || format('A13 dio %s: R %s (antes %s), V %s (antes %s), mermas R %s', v_j,
                                     pg_temp.rc_stock(v_r), v_n, pg_temp.rc_stock(v_p), v_n2,
                                     (SELECT jsonb_agg(jsonb_build_object('c', cantidad, 'anulada', anulada_at IS NOT NULL) ORDER BY id)
                                        FROM mermas_stock WHERE producto_id = v_r));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRCD';
  EXCEPTION
    WHEN SQLSTATE 'ZZRCD' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A13 error: ' || SQLERRM);
  END;

  -- A14 · la promo cambió de tipo: el regalo vuelve, baja su stock y no toca la barra
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A14');
    v_p := pg_temp.rc_producto(v_suc, 'A14 venta', 100);
    v_r := pg_temp.rc_producto(v_suc, 'A14 regalo', 100);
    v_promo := pg_temp.rc_promo(v_suc, v_r, NULL, false);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10) || pg_temp.rc_regalo(v_r, 1, v_promo), 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x);
    UPDATE promociones SET regalo_mueve_stock = false WHERE id = v_promo;
    v_n := (SELECT usos_pendientes FROM promociones WHERE id = v_promo);
    v_j := pg_temp.rc_revertir(v_x);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR jsonb_array_length(v_j->'regalos_quitados') <> 0
       OR NOT EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion AND producto_id = v_r)
       OR pg_temp.rc_stock(v_r) <> 99
       OR (SELECT usos_pendientes FROM promociones WHERE id = v_promo) IS DISTINCT FROM v_n::int THEN
      v_fallas := v_fallas || format('A14 dio %s: R %s, barra %s (antes %s)', v_j, pg_temp.rc_stock(v_r),
                                     (SELECT usos_pendientes FROM promociones WHERE id = v_promo), v_n);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRCE';
  EXCEPTION
    WHEN SQLSTATE 'ZZRCE' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A14 error: ' || SQLERRM);
  END;

  -- A15 · llegar al cupo apaga la promo
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A15');
    v_p := pg_temp.rc_producto(v_suc, 'A15 venta', 100);
    v_r := pg_temp.rc_producto(v_suc, 'A15 regalo', 100);
    v_promo := pg_temp.rc_promo(v_suc, v_r, 1, false);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10) || pg_temp.rc_regalo(v_r, 1, v_promo), 100, v_hoy);
    PERFORM pg_temp.rc_cancelar(v_x);
    UPDATE promociones SET activo = true WHERE id = v_promo;
    v_j := pg_temp.rc_revertir(v_x);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT activo FROM promociones WHERE id = v_promo)
       OR jsonb_array_length(v_j->'promos_apagadas') <> 1
       OR NOT EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion) THEN
      v_fallas := v_fallas || format('A15 dio %s y la promo quedó activo=%s', v_j,
                                     (SELECT activo FROM promociones WHERE id = v_promo));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRCF';
  EXCEPTION
    WHEN SQLSTATE 'ZZRCF' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A15 error: ' || SQLERRM);
  END;

  -- A16 · el fardo del contenedor vuelve a salir de su lote (M3-1)
  BEGIN
    v_cli := pg_temp.rc_cliente(v_suc, 'ZZ revertir A16');
    v_p := pg_temp.rc_producto(v_suc, 'A16 venta', 100);
    v_r := pg_temp.rc_producto(v_suc, 'A16 regalo', 5);
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
    VALUES (v_r, v_suc, v_hoy + 90, 5, 5, 'manual')
    RETURNING id INTO v_lote;
    v_promo := pg_temp.rc_promo(v_suc, v_r, NULL, true);
    v_x := pg_temp.rc_alta(v_cli, v_adm, pg_temp.rc_linea(v_p, 10, 10) || pg_temp.rc_regalo(v_r, 6, v_promo), 100, v_hoy);
    IF pg_temp.rc_lote(v_lote) <> 4 OR pg_temp.rc_stock(v_r) <> 4 THEN
      v_fallas := v_fallas || format('A16 el alta dejó R en %s y L en %s (se esperaba 4 y 4)', pg_temp.rc_stock(v_r),
                                     pg_temp.rc_lote(v_lote));
    END IF;
    PERFORM pg_temp.rc_compra_bolsa(v_r, 3);
    PERFORM pg_temp.rc_cancelar(v_x);
    IF pg_temp.rc_lote(v_lote) <> 5 OR pg_temp.rc_stock(v_r) <> 8 THEN
      v_fallas := v_fallas || format('A16 la cancelación dejó R en %s y L en %s (se esperaba 8 y 5)', pg_temp.rc_stock(v_r),
                                     pg_temp.rc_lote(v_lote));
    END IF;
    v_j := pg_temp.rc_revertir(v_x);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.rc_lote(v_lote) <> 4 OR pg_temp.rc_stock(v_r) <> 7
       OR NOT EXISTS (SELECT 1 FROM promo_ajustes pa, jsonb_array_elements(pa.lotes_pendientes) e
                       WHERE pa.promocion_id = v_promo
                         AND pa.id = (SELECT max(id) FROM promo_ajustes WHERE promocion_id = v_promo)
                         AND (e->>'lote_id')::bigint = v_lote AND (e->>'cantidad')::int = 1) THEN
      v_fallas := v_fallas || format('A16 dio %s: R %s, L %s, bloque %s', v_j, pg_temp.rc_stock(v_r), pg_temp.rc_lote(v_lote),
                                     (SELECT lotes_pendientes FROM promo_ajustes WHERE promocion_id = v_promo ORDER BY id DESC LIMIT 1));
    END IF;
    IF pg_temp.rc_checks() IS DISTINCT FROM v_checks THEN
      v_fallas := v_fallas || format('A16 los checks pasaron de %s a %s', v_checks, pg_temp.rc_checks());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZRCG';
  EXCEPTION
    WHEN SQLSTATE 'ZZRCG' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A16 error: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · A0 A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 A11 A12 A13 A14 A15 A16 y checks (%)', v_checks;
 END;
END
$ensayo$;
