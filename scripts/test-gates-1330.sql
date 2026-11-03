-- Ensayo de los checks de #1330 y del punto 3 de #1376 (mig 434_gates_de_la_auditoria).
--
-- Corre contra prod SIN dejar rastro, igual que scripts/test-comisiones-1320-1321.sql:
-- un único DO que termina SIEMPRE en una excepción, y cada caso en su propio bloque
-- que se deshace (ZZ001). Antes de aplicar la migración se corre pegado detrás de su
-- cuerpo sin el BEGIN/COMMIT; después, solo.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Cada check se mide por DIFERENCIA contra lo que daba al empezar: tiene que subir
-- con la violación armada a mano y no moverse con el caso legítimo. Un check que no
-- sube es un check que no muerde.
--
--   C1 · la lista: 79 checks, sin ids repetidos, y GASTO-A sigue ahí.
--   C2 · RUTA-A y RUTA-B: una parada 'no_entregado' de un pedido entregado es
--        historia y no se pone en rojo; una 'pendiente' sí. Con la cuenta vieja los
--        dos daban rojo en el primer caso.
--   C3 · ASG-A: sin el dueño, o con otro además del dueño.
--   C4 · ASG-B: un transportista con cartera; un preventista sin la sucursal.
--   C5 · EMP-A: cuadra; la suma cuadra pero el movimiento lleva otro cliente; el
--        pago pasó entre dos fichas del mismo empleado y no asentó nada; el neto
--        repartido entre dos empleados; un pago que no es adelanto; un pago
--        borrado, en cero y sin cerrar.
--   C6 · EMP-B: lo que asienta el trigger cuadra; otro empleado con reintegro; un
--        gasto de oficina con reintegro; un gasto de empleado sin movimiento.
--   C7 · COMIS-06: la vigencia de un mes cerrado, la base del 2000, una regla nacida
--        en un mes cerrado y una función que escribe sin pasar por las RPCs.
--   C8 · PROMO-C: una función que lee la columna, y que un comentario, una clave de
--        JSON o la foto no cuentan.
--   C9 · REPORTE-A: JOIN interno a productos, al vendedor y a zonas; LEFT no cuenta.
--   C10 · FISCAL-B: una NC vigente de un FC que no cierra; anulada no cuenta.
--   C11 · #1376: cambiar el tipo de la promo no mueve el gerencial ni rentabilidad,
--        sobre las líneas de regalo sin `unidades_por_bloque_al_crear`. Cambia sólo
--        el tipo: la pantalla además borra el factor, que no está en la foto (el
--        límite de la cabecera de la 434).
--   C12 · EMP-C: el cliente o el vehículo de otra sucursal; "de las dos" no cuenta.
--   C13 · VENTA-E: mañana en el día argentino, sin mirar CURRENT_DATE.

CREATE OR REPLACE FUNCTION pg_temp.v(p_id text) RETURNS bigint LANGUAGE sql AS $f$
  SELECT (c->>'violaciones')::bigint
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
   WHERE c->>'id' = p_id;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_msg text) RETURNS text[] LANGUAGE sql AS $f$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN '{}'::text[] ELSE ARRAY[p_msg] END;
$f$;

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_corte  date := date_trunc('month', public._tablero_hoy())::date;
  v_m_ini  date := (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date;
  v_adm    uuid;
  v_s      bigint;
  v_rubro  bigint;
  v_e1     bigint;
  v_e2     bigint;
  v_n0     bigint;
  v_n1     bigint;
  v_n2     bigint;
  v_id     bigint;
  v_cli    bigint;
  v_cli2   bigint;
  v_pago   record;
  v_rp     record;
  v_a      jsonb;
  v_x      jsonb;
  v_y      jsonb;
  v_promo  bigint;
  v_suc    bigint;
  v_fecha  date;
  v_prev   uuid;
  v_fallas text[] := '{}';
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT pf.id INTO v_adm FROM perfiles pf WHERE pf.activo AND pf.rol = 'admin' ORDER BY pf.id LIMIT 1;
  SELECT s.id INTO v_s FROM sucursales s WHERE s.activa ORDER BY s.id LIMIT 1;
  SELECT id INTO v_rubro FROM gasto_rubros WHERE activo ORDER BY id LIMIT 1;
  IF v_adm IS NULL OR v_s IS NULL OR v_rubro IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: admin %, sucursal %, rubro %', v_adm, v_s, v_rubro;
  END IF;

  -- ================================================================ C1 · lista
  v_a := public.auditoria_integridad();
  v_fallas := v_fallas || pg_temp.chk((v_a->>'total_checks')::int = 79,
                format('C1 hay %s checks, no 79', v_a->>'total_checks'));
  v_fallas := v_fallas || pg_temp.chk(
    (SELECT count(*) = count(DISTINCT c->>'id') FROM jsonb_array_elements(v_a->'checks') c), 'C1 ids repetidos');
  v_fallas := v_fallas || pg_temp.chk(
    (SELECT count(*) = 12 FROM jsonb_array_elements(v_a->'checks') c
      WHERE c->>'id' = ANY (ARRAY['GASTO-A', 'RUTA-A', 'RUTA-B', 'PROMO-C', 'ASG-A', 'ASG-B', 'COMIS-06',
                                  'REPORTE-A', 'EMP-A', 'EMP-B', 'EMP-C', 'FISCAL-B'])
        AND c->>'severidad' = 'high'),
    'C1 falta un check o no es high');

  -- ================================================================ C2 · rutas
  BEGIN
    SELECT rp.id, rp.recorrido_id INTO v_rp
      FROM recorrido_pedidos rp
      JOIN pedidos p ON p.id = rp.pedido_id
      JOIN recorridos r ON r.id = rp.recorrido_id
     WHERE rp.estado_entrega = 'entregado' AND p.estado = 'entregado' AND r.estado = 'completado'
     ORDER BY rp.id DESC LIMIT 1;
    v_n0 := pg_temp.v('RUTA-A');
    v_n1 := pg_temp.v('RUTA-B');

    UPDATE recorrido_pedidos SET estado_entrega = 'no_entregado' WHERE id = v_rp.id;
    UPDATE recorridos r SET pedidos_entregados = c.pedidos_entregados, total_cobrado = c.total_cobrado
      FROM public._recorrido_contadores(v_rp.recorrido_id) c WHERE r.id = v_rp.recorrido_id;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('RUTA-A') = v_n0, 'C2 una parada en historia pone rojo RUTA-A');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('RUTA-B') = v_n1, 'C2 una parada en historia pone rojo RUTA-B');

    UPDATE recorrido_pedidos SET estado_entrega = 'pendiente' WHERE id = v_rp.id;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('RUTA-A') = v_n0 + 1, 'C2 RUTA-A no ve la parada viva sin marcar');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('RUTA-B') = v_n1 + 1, 'C2 RUTA-B no ve el contador desfasado');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C2 · error: %s', SQLERRM);
  END;

  -- ===================================================================== C3 · ASG-A
  BEGIN
    SELECT c.id, public._duenio_zona(c.zona_id) INTO v_cli, v_prev
      FROM clientes c
     WHERE public._duenio_zona(c.zona_id) IS NOT NULL AND NOT c.reservado_admin
       AND EXISTS (SELECT 1 FROM cliente_preventistas cp
                    WHERE cp.cliente_id = c.id AND cp.preventista_id = public._duenio_zona(c.zona_id))
       AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp
                        WHERE cp.cliente_id = c.id AND cp.preventista_id <> public._duenio_zona(c.zona_id))
     ORDER BY c.id LIMIT 1;
    v_n0 := pg_temp.v('ASG-A');

    INSERT INTO cliente_preventistas (cliente_id, preventista_id)
    SELECT v_cli, pf.id FROM perfiles pf
     WHERE pf.rol = 'preventista' AND pf.activo AND pf.id <> v_prev
       AND public._actua_como_preventista(pf.id, (SELECT sucursal_id FROM clientes WHERE id = v_cli))
     ORDER BY pf.id LIMIT 1;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('ASG-A') = v_n0 + 1, 'C3 ASG-A no ve al segundo preventista');

    DELETE FROM cliente_preventistas WHERE cliente_id = v_cli AND preventista_id = v_prev;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('ASG-A') = v_n0 + 1, 'C3 ASG-A no ve a otro en lugar del dueño');

    DELETE FROM cliente_preventistas WHERE cliente_id = v_cli;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('ASG-A') = v_n0 + 1, 'C3 ASG-A no ve al cliente sin asignar');

    UPDATE clientes SET reservado_admin = true WHERE id = v_cli;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('ASG-A') = v_n0, 'C3 ASG-A cuenta a un reservado');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C3 · error: %s', SQLERRM);
  END;

  -- ===================================================================== C4 · ASG-B
  BEGIN
    SELECT c.id INTO v_cli FROM clientes c
     WHERE NOT c.reservado_admin AND c.zona_id IS NULL AND c.sucursal_id = v_s
       AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
     ORDER BY c.id LIMIT 1;
    v_n0 := pg_temp.v('ASG-B');

    INSERT INTO cliente_preventistas (cliente_id, preventista_id)
    SELECT v_cli, pf.id FROM perfiles pf
     WHERE pf.rol = 'transportista' AND pf.activo ORDER BY pf.id LIMIT 1;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('ASG-B') = v_n0 + 1, 'C4 ASG-B no ve al transportista con cartera');
    DELETE FROM cliente_preventistas WHERE cliente_id = v_cli;

    INSERT INTO cliente_preventistas (cliente_id, preventista_id)
    SELECT v_cli, pf.id FROM perfiles pf
     WHERE pf.rol = 'preventista' AND pf.activo
       AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id AND us.sucursal_id = v_s)
     ORDER BY pf.id LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'no hay un preventista de otra sucursal: el caso no muerde';
    END IF;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('ASG-B') = v_n0 + 1, 'C4 ASG-B no ve al preventista sin la sucursal');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C4 · error: %s', SQLERRM);
  END;

  -- ================================================================ empleados
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por) VALUES (v_s, 'ENSAYO 1330 a', 'ayudante', v_adm) RETURNING id INTO v_e1;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por) VALUES (v_s, 'ENSAYO 1330 b', 'ayudante', v_adm) RETURNING id INTO v_e2;

  -- ===================================================================== C5 · EMP-A
  BEGIN
    -- El caso no puede asumir clientes libres: empleados.cliente_id es UNIQUE y en
    -- prod el cliente de un adelanto ya es la ficha de un empleado real (el paso de
    -- la ficha de abajo lo liga al empleado de prueba). Se prefiere un pago cuyo
    -- cliente no tenga empleado ni movimientos; si no hay (prod), se libera el del
    -- primero DENTRO del caso (todo se deshace): se desliga el empleado real y se
    -- borran los movimientos del pago, para medir desde un pago limpio.
    SELECT p.id, p.monto, p.cliente_id INTO v_pago FROM pagos p
     WHERE p.forma_pago = 'adelanto_sueldo' AND p.pago_origen_id IS NULL
     ORDER BY EXISTS (SELECT 1 FROM empleados e WHERE e.cliente_id = p.cliente_id),
              EXISTS (SELECT 1 FROM empleado_movimientos m WHERE m.pago_id = p.id OR m.pago_raiz_id = p.id),
              p.id
     LIMIT 1;
    UPDATE empleados SET cliente_id = NULL WHERE cliente_id = v_pago.cliente_id;
    DELETE FROM empleado_movimientos WHERE pago_id = v_pago.id OR pago_raiz_id = v_pago.id;
    SELECT c.id INTO v_cli2 FROM clientes c
     WHERE c.id <> v_pago.cliente_id
       AND NOT EXISTS (SELECT 1 FROM empleados e WHERE e.cliente_id = c.id)
     ORDER BY c.id LIMIT 1;
    IF v_cli2 IS NULL THEN
      INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
      VALUES ('ENSAYO 1330 c', 'ENSAYO 1330 c', 'ensayo', v_s) RETURNING id INTO v_cli2;
    END IF;
    v_n0 := pg_temp.v('EMP-A');

    -- Cuadra: el neto entero, en el empleado del movimiento con el cliente del pago.
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, pago_id, pago_raiz_id, cliente_id, creado_por)
    VALUES (v_e1, v_hoy, 'mercaderia', -v_pago.monto, v_pago.id, v_pago.id, v_pago.cliente_id, v_adm) RETURNING id INTO v_id;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-A') = v_n0, 'C5 EMP-A marca un pago que cuadra');

    -- La suma cuadra, pero la plata está en la cuenta de otro cliente.
    UPDATE empleado_movimientos SET cliente_id = v_cli2 WHERE id = v_id;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-A') = v_n0 + 1, 'C5 EMP-A no ve el cliente equivocado');

    -- El mismo movimiento, pero el empleado hoy tiene la ficha del pago: la plata
    -- está bien, y conciliar no asienta nada.
    UPDATE empleados SET cliente_id = v_pago.cliente_id WHERE id = v_e1;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-A') = v_n0, 'C5 EMP-A marca un cambio de ficha del mismo empleado');
    UPDATE empleados SET cliente_id = NULL WHERE id = v_e1;
    UPDATE empleado_movimientos SET cliente_id = v_pago.cliente_id WHERE id = v_id;

    -- La suma cuadra, pero el neto está repartido entre dos empleados.
    UPDATE empleado_movimientos SET monto = -v_pago.monto + 1 WHERE id = v_id;
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, pago_id, pago_raiz_id, cliente_id, creado_por)
    VALUES (v_e2, v_hoy, 'mercaderia', -1, v_pago.id, v_pago.id, v_pago.cliente_id, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-A') = v_n0 + 1, 'C5 EMP-A no ve el neto en dos empleados');
    DELETE FROM empleado_movimientos WHERE pago_id = v_pago.id;

    -- Un pago que no es adelanto.
    SELECT p.id, p.monto, p.cliente_id INTO v_pago FROM pagos p
     WHERE p.forma_pago <> 'adelanto_sueldo' ORDER BY p.id LIMIT 1;
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, pago_id, pago_raiz_id, cliente_id, creado_por)
    VALUES (v_e1, v_hoy, 'mercaderia', -100, v_pago.id, v_pago.id, v_pago.cliente_id, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-A') = v_n0 + 1, 'C5 EMP-A no ve un pago que no es adelanto');
    DELETE FROM empleado_movimientos WHERE pago_id = v_pago.id;

    -- Un pago borrado: el movimiento queda, y la cuenta tiene que dar 0.
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, pago_id, pago_raiz_id, cliente_id, creado_por)
    VALUES (v_e1, v_hoy, 'mercaderia', -100, -1, -1, v_cli2, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-A') = v_n0 + 1, 'C5 EMP-A no ve un pago borrado sin cerrar');
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, pago_id, pago_raiz_id, cliente_id, creado_por)
    VALUES (v_e1, v_hoy, 'mercaderia', 100, -1, -1, v_cli2, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-A') = v_n0, 'C5 EMP-A marca un pago borrado en cero');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C5 · error: %s', SQLERRM);
  END;

  -- ===================================================================== C6 · EMP-B
  BEGIN
    v_n0 := pg_temp.v('EMP-B');

    -- El gasto de un empleado: lo asienta el trigger y cuadra.
    INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, mes_imputado, creado_por, origen_pago, empleado_id)
    VALUES (v_s, v_hoy, v_rubro, 8500, 'ticket', v_corte, v_adm, 'empleado', v_e1) RETURNING id INTO v_id;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-B') = v_n0, 'C6 EMP-B marca el reintegro del trigger');

    -- Otro empleado con parte del reintegro.
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, gasto_id, creado_por)
    VALUES (v_e2, v_hoy, 'reintegro', 100, v_id, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-B') = v_n0 + 1, 'C6 EMP-B no ve a otro empleado');

    -- Un gasto de empleado sin su movimiento.
    DELETE FROM empleado_movimientos WHERE gasto_id = v_id;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-B') = v_n0 + 1, 'C6 EMP-B no ve el gasto sin reintegro');

    -- Un gasto de oficina con reintegro.
    INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, mes_imputado, creado_por)
    VALUES (v_s, v_hoy, v_rubro, 8500, 'ticket', v_corte, v_adm) RETURNING id INTO v_id;
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, gasto_id, creado_por)
    VALUES (v_e1, v_hoy, 'reintegro', 8500, v_id, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-B') = v_n0 + 2, 'C6 EMP-B no ve el gasto de oficina');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C6 · error: %s', SQLERRM);
  END;

  -- ================================================================== C7 · COMIS-06
  BEGIN
    v_n0 := pg_temp.v('COMIS-06');

    -- El mes en curso se puede cambiar.
    INSERT INTO comision_pct_vigencias (sucursal_id, vigente_desde, pct_preventista, pct_otros)
    VALUES (v_s, v_corte, 3, 1) ON CONFLICT (sucursal_id, vigente_desde) DO UPDATE SET pct_preventista = 3;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('COMIS-06') = v_n0, 'C7 COMIS-06 marca el mes en curso');

    INSERT INTO comision_pct_vigencias (sucursal_id, vigente_desde, pct_preventista, pct_otros)
    VALUES (v_s, v_m_ini, 9, 9) ON CONFLICT (sucursal_id, vigente_desde) DO UPDATE SET pct_preventista = 9, actualizado_en = now();
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('COMIS-06') = v_n0 + 1, 'C7 COMIS-06 no ve la vigencia de un mes cerrado');
    DELETE FROM comision_pct_vigencias WHERE sucursal_id = v_s AND vigente_desde = v_m_ini;

    UPDATE comision_pct_vigencias SET pct_preventista = 9, actualizado_en = now()
     WHERE sucursal_id = v_s AND vigente_desde = DATE '2000-01-01';
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('COMIS-06') = v_n0 + 1, 'C7 COMIS-06 no ve la base tocada');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C7 · error: %s', SQLERRM);
  END;

  BEGIN
    v_n0 := pg_temp.v('COMIS-06');
    INSERT INTO comision_reglas (sucursal_id, porcentaje, vigente_desde, usuario_id) VALUES (v_s, 50, v_corte, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('COMIS-06') = v_n0, 'C7 COMIS-06 marca una regla del mes en curso');
    INSERT INTO comision_reglas (sucursal_id, porcentaje, vigente_desde, usuario_id) VALUES (v_s, 50, v_m_ini, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('COMIS-06') = v_n0 + 1, 'C7 COMIS-06 no ve la regla nacida en un mes cerrado');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C7 · error: %s', SQLERRM);
  END;

  BEGIN
    v_n0 := pg_temp.v('COMIS-06');
    EXECUTE $s$CREATE FUNCTION public.ensayo_1330_c() RETURNS void LANGUAGE sql AS
      'UPDATE comision_reglas SET porcentaje = 0'$s$;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('COMIS-06') = v_n0 + 1, 'C7 COMIS-06 no ve un camino nuevo');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C7 · error: %s', SQLERRM);
  END;

  -- =================================================================== C8 · PROMO-C
  BEGIN
    v_n0 := pg_temp.v('PROMO-C');
    EXECUTE $s$CREATE FUNCTION public.ensayo_1330_p1(p bigint) RETURNS boolean LANGUAGE sql AS $b$
      SELECT pr.regalo_mueve_stock FROM public.promociones pr WHERE pr.id = p $b$$s$;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('PROMO-C') = v_n0 + 1, 'C8 PROMO-C no ve la lectura viva');

    EXECUTE $s$CREATE FUNCTION public.ensayo_1330_p2(p bigint) RETURNS jsonb LANGUAGE sql AS $b$
      -- regalo_mueve_stock, en un comentario
      SELECT jsonb_build_object('regalo_mueve_stock', p) $b$$s$;
    EXECUTE $s$CREATE FUNCTION public.ensayo_1330_p3(p bigint) RETURNS boolean LANGUAGE sql AS $b$
      SELECT f.regalo_mueve_stock FROM public.pedido_promo_reglas f WHERE f.pedido_id = p LIMIT 1 $b$$s$;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('PROMO-C') = v_n0 + 1, 'C8 PROMO-C cuenta un comentario, un JSON o la foto');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C8 · error: %s', SQLERRM);
  END;

  -- ================================================================= C9 · REPORTE-A
  BEGIN
    v_n0 := pg_temp.v('REPORTE-A');
    EXECUTE $s$CREATE FUNCTION public.reporte_ensayo_1330_a() RETURNS bigint LANGUAGE sql AS $b$
      SELECT count(*) FROM public.pedido_items pi JOIN productos prod ON prod.id = pi.producto_id $b$$s$;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('REPORTE-A') = v_n0 + 1, 'C9 REPORTE-A no ve el JOIN a productos');
    EXECUTE $s$CREATE FUNCTION public.tablero_ensayo_1330_b() RETURNS bigint LANGUAGE sql AS $b$
      SELECT count(*) FROM public.pedidos p JOIN perfiles pf ON pf.id = p.usuario_id $b$$s$;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('REPORTE-A') = v_n0 + 2, 'C9 REPORTE-A no ve el JOIN al vendedor');
    EXECUTE $s$CREATE FUNCTION public.tablero_ensayo_1330_c() RETURNS bigint LANGUAGE sql AS $b$
      SELECT count(*) FROM public.clientes c JOIN zonas z ON z.id = c.zona_id $b$$s$;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('REPORTE-A') = v_n0 + 3, 'C9 REPORTE-A no ve el JOIN a zonas');
    EXECUTE $s$CREATE FUNCTION public.reporte_ensayo_1330_d() RETURNS bigint LANGUAGE sql AS $b$
      SELECT count(*) FROM public.pedido_items pi LEFT JOIN productos prod ON prod.id = pi.producto_id
        LEFT OUTER JOIN public.pedidos p ON p.id = pi.pedido_id LEFT JOIN perfiles pf ON pf.id = p.usuario_id $b$$s$;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('REPORTE-A') = v_n0 + 3, 'C9 REPORTE-A cuenta un LEFT JOIN');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C9 · error: %s', SQLERRM);
  END;

  -- ================================================================== C10 · FISCAL-B
  BEGIN
    v_n0 := pg_temp.v('FISCAL-B');
    INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, total, neto, iva)
    SELECT p.sucursal_id, p.cliente_id, p.id, 100, 50, 0 FROM pedidos p
     WHERE p.tipo_factura = 'FC' ORDER BY p.id LIMIT 1
    RETURNING id INTO v_id;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('FISCAL-B') = v_n0 + 1, 'C10 FISCAL-B no ve la NC que no cierra');
    UPDATE notas_credito_venta SET anulada = true, anulada_at = now(), anulada_por = v_adm, motivo_anulacion = 'ensayo'
     WHERE id = v_id;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('FISCAL-B') = v_n0, 'C10 FISCAL-B cuenta una anulada');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C10 · error: %s', SQLERRM);
  END;

  -- ===================================================== C11 · #1376, la foto manda
  BEGIN
    SELECT pi.promocion_id, p.sucursal_id, p.fecha INTO v_promo, v_suc, v_fecha
      FROM pedido_items pi
      JOIN pedidos p ON p.id = pi.pedido_id
      JOIN promociones pr ON pr.id = pi.promocion_id
     WHERE pi.es_bonificacion AND pi.unidades_por_bloque_al_crear IS NULL
       AND pr.unidades_por_bloque > 1 AND p.estado = 'entregado' AND p.canal <> 'cambio'
       AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND EXISTS (SELECT 1 FROM pedido_promo_reglas f
                    WHERE f.pedido_id = pi.pedido_id AND f.promocion_id = pi.promocion_id)
     ORDER BY p.fecha DESC LIMIT 1;
    IF v_promo IS NULL THEN
      RAISE EXCEPTION 'no hay una línea de regalo sin factor y con foto: el caso no muerde';
    END IF;

    v_x := reporte_gerencial(v_suc, v_fecha, v_fecha)->'kpis';
    v_y := reporte_rentabilidad(v_fecha, v_fecha, v_suc)->'totales';
    UPDATE promociones SET regalo_mueve_stock = NOT COALESCE(regalo_mueve_stock, false)
     WHERE id = v_promo;
    v_fallas := v_fallas || pg_temp.chk(reporte_gerencial(v_suc, v_fecha, v_fecha)->'kpis' = v_x,
                  'C11 cambiar el tipo de la promo mueve el gerencial');
    v_fallas := v_fallas || pg_temp.chk(reporte_rentabilidad(v_fecha, v_fecha, v_suc)->'totales' = v_y,
                  'C11 cambiar el tipo de la promo mueve rentabilidad');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C11 · error: %s', SQLERRM);
  END;

  -- ===================================================================== C12 · EMP-C
  BEGIN
    v_n0 := pg_temp.v('EMP-C');
    SELECT c.id INTO v_cli FROM clientes c WHERE c.sucursal_id <> v_s AND c.activo
       AND NOT EXISTS (SELECT 1 FROM empleados e WHERE e.cliente_id = c.id) ORDER BY c.id LIMIT 1;
    UPDATE empleados SET cliente_id = v_cli WHERE id = v_e1;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-C') = v_n0 + 1, 'C12 EMP-C no ve el cliente de otra sucursal');
    UPDATE empleados SET de_las_dos = true WHERE id = v_e1;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-C') = v_n0, 'C12 EMP-C cuenta a uno de las dos');
    UPDATE empleados SET cliente_id = NULL, de_las_dos = false WHERE id = v_e1;

    INSERT INTO vehiculos (sucursal_id, patente, descripcion)
    SELECT c.sucursal_id, 'ENS1330', 'ENSAYO 1330' FROM clientes c WHERE c.id = v_cli
    RETURNING id INTO v_id;
    UPDATE empleados SET vehiculo_id = v_id WHERE id = v_e2;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('EMP-C') = v_n0 + 1, 'C12 EMP-C no ve el vehículo de otra sucursal');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C12 · error: %s', SQLERRM);
  END;

  -- =================================================================== C13 · VENTA-E
  BEGIN
    v_n0 := pg_temp.v('VENTA-E');
    UPDATE pedidos SET fecha = v_hoy + 1
     WHERE id = (SELECT max(id) FROM pedidos WHERE estado = 'entregado' AND canal <> 'cambio');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.v('VENTA-E') = v_n0 + 1, 'C13 VENTA-E no ve una venta de mañana');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_fallas := v_fallas || format('C13 · error: %s', SQLERRM);
  END;
  v_fallas := v_fallas || pg_temp.chk(
    (SELECT p.prosrc !~ 'CURRENT_DATE' FROM pg_proc p WHERE p.oid = 'public.auditoria_integridad()'::regprocedure),
    'C13 auditoria_integridad sigue usando CURRENT_DATE');

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ (%): %', cardinality(v_fallas), array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · gates de #1330: 79 checks sin ids repetidos; RUTA-A y RUTA-B no se ponen rojos con una parada en historia; ASG-A, ASG-B, EMP-A, EMP-B, EMP-C, COMIS-06, PROMO-C, REPORTE-A y FISCAL-B suben con su violación y no con el caso legítimo; VENTA-E corta en el día argentino; el tipo de una promo no mueve los reportes de un pedido con foto';
END
$ensayo$;
