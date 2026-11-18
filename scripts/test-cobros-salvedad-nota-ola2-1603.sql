-- Ensayo de la migración NNN_cobros_salvedad_y_nota_restos (plan #1603, ola 2, tanda 5, tarjeta C1).
--
-- Los casos L fallan sin la migración; los E pasan con y sin ella (regresión):
--
--   1595-b2 · el cobro repuesto por anular una salvedad conserva sus marcas
--   L1 · Un empleado con ficha de cliente; dos boletas suyas (60 y 40) pagadas con un adelanto de sueldo por el
--        FIFO de la ficha (dos pagos a cuenta). Una salvedad de toda la boleta de 40 borra su pago; anularla lo
--        repone como un cobro nuevo, que tiene que seguir a cuenta (a_cuenta) y que desimputar_pago acepta. La
--        cuenta del empleado vuelve a -100.
--   L2 · El adelanto deja 40 sueltos; una boleta nueva de 30 se los lleva como un pedazo (pago_origen_id y
--        pago_padre_id). Una salvedad de toda esa boleta borra el pedazo; el cobro repuesto es otra vez un pedazo
--        de la misma raíz y del mismo padre.
--   E1 · Un cobro común de la boleta (efectivo, por registrar_pagos_pedido) borrado por la salvedad vuelve sin
--        marcas, como siempre: desimputar_pago no lo acepta (se anula como un cobro).
--
--   COB-b6 · al aplicar un crédito se limpian todas las marcas de saldo a favor
--   L3 · Una boleta cobrada en efectivo se cancela con otra boleta del cliente impaga: el cobro pasa a la otra
--        sin «[saldo a favor por cancelacion]» en sus notas.
--   L4 · Un crédito suelto «x [saldo a favor por cambio de cliente]» imputado a mano (imputar_credito_a_pedido):
--        entero y en parte, el pago aplicado dice «x».
--   L5 · _notas_sin_saldo_a_favor saca las tres marcas y nada más.
--
--   1598-b4 · la marca «tiene salvedad vigente» de un pedido
--   L6 · Tres boletas: una con salvedad viva, una con la salvedad anulada y una sin salvedad. Como el admin
--        (authenticated), filtrar pedidos por tiene_salvedad_vigente da la primera con true y las otras dos con
--        false, igual que la lista de ids de antes.
--
--   N2 y N7 de la revisión de B22 · la nota por unidades
--   L7 · 3 × $ 100 con un descuento de $ 299,99 en la línea: 1 u. sola se rechaza con el mensaje de «casi toda su
--        plata»; 1 u. junto a otro renglón con plata, también (antes entraba con un renglón de $ 0,00).
--   E2 · Las 3 u. juntas (le quedan $ 0,01) entran: la parte no es 0.
--   L8 · Los mensajes de la rama por unidades nombran el producto y no el id de la línea: cantidad 0, un regalo,
--        más de lo entregado y un renglón que no es de la boleta.
--
-- Un único DO que termina siempre en una excepción (no deja nada), y cada caso en un sub-bloque que se revierte.
-- Corre en la primera sucursal activa con un admin propio. Sin la migración tiene que dar 'ENSAYO FALLÓ' por los L.

CREATE OR REPLACE FUNCTION pg_temp.c1_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.omitir_minimo_venta', '', true);
  PERFORM set_config('app.minimo_venta_previo', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_usuario(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c1-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'C1 ' || p_rol), now(), now());
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo C1', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_producto(p_suc bigint, p_nombre text, p_precio numeric)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, p_precio, 100000, 1, p_suc)
  RETURNING id;
$fn$;

-- Alta de una boleta (el JSON del alta) con el admin; la deja entregada (retiro en el depósito). Devuelve el id.
CREATE OR REPLACE FUNCTION pg_temp.c1_boleta(p_cli bigint, p_adm uuid, p_suc bigint, p_items jsonb, p_entregada boolean DEFAULT true)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  v_res := public.crear_pedido_completo(
    p_cli, (SELECT sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_adm, p_items, 'ensayo C1', 'efectivo', 'pendiente', public._tablero_hoy(), 'ZZ');
  PERFORM pg_temp.c1_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  IF p_entregada THEN
    UPDATE public.pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now() WHERE id = v_ped;
  END IF;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN v_ped;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_linea(p_prod bigint, p_cant int, p_precio numeric)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_item(p_ped bigint, p_prod bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT min(id) FROM public.pedido_items WHERE pedido_id = p_ped AND producto_id = p_prod;
$fn$;

-- Salvedad 'cliente_rechaza' de p_cant unidades de la primera línea.
CREATE OR REPLACE FUNCTION pg_temp.c1_salvedad(p_ped bigint, p_cant int, p_adm uuid, p_suc bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  v_res := public.registrar_salvedad(p_ped, (SELECT min(id) FROM public.pedido_items WHERE pedido_id = p_ped),
                                     p_cant, 'cliente_rechaza', 'ensayo C1', NULL, true, NULL);
  PERFORM pg_temp.c1_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la salvedad no entró: %', v_res;
  END IF;
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_anular(p_salv bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  v_res := public.anular_salvedad(p_salv, 'ensayo C1');
  PERFORM pg_temp.c1_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la anulación no entró: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

-- desimputar_pago como el admin: 'OK' o el error.
CREATE OR REPLACE FUNCTION pg_temp.c1_desimputar(p_pago bigint, p_ped bigint, p_adm uuid, p_suc bigint)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  PERFORM public.desimputar_pago(p_pago, p_ped);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END
$fn$;

-- Un empleado con ficha de cliente (el puesto, uno válido del CHECK de la tabla).
CREATE OR REPLACE FUNCTION pg_temp.c1_empleado(p_suc bigint, p_cli bigint, p_adm uuid)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_puesto text;
  v_e bigint;
BEGIN
  SELECT (regexp_match(pg_get_constraintdef(co.oid), '''([^'']+)'''))[1] INTO v_puesto
    FROM pg_constraint co
   WHERE co.conrelid = 'public.empleados'::regclass AND co.contype = 'c'
     AND pg_get_constraintdef(co.oid) ~ 'puesto'
   LIMIT 1;
  INSERT INTO public.empleados (sucursal_id, nombre, puesto, cliente_id, creado_por)
  VALUES (p_suc, 'C1 empleado', v_puesto, p_cli, p_adm)
  RETURNING id INTO v_e;
  RETURN v_e;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_fifo_adelanto(p_cli bigint, p_monto numeric, p_adm uuid, p_suc bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  PERFORM public.registrar_pago_cliente_fifo(p_cli, p_monto, 'adelanto_sueldo', public._tablero_hoy(), NULL, 'ensayo C1');
  PERFORM pg_temp.c1_reset();
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_cuenta(p_emp bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(sum(monto), 0) FROM public.empleado_movimientos WHERE empleado_id = p_emp;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_pagos(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(id || ':' || monto || ' a_cuenta=' || a_cuenta || ' origen=' || COALESCE(pago_origen_id::text, '-')
                             || ' padre=' || COALESCE(pago_padre_id::text, '-'), '; ' ORDER BY id), '(ninguno)')
    FROM public.pagos WHERE pedido_id = p_ped;
$fn$;

-- Nota de crédito de venta como el admin: 'OK' o el error.
CREATE OR REPLACE FUNCTION pg_temp.c1_nc(p_ped bigint, p_items jsonb, p_motivo text, p_adm uuid, p_suc bigint)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  v_res := public.crear_nota_credito_venta(p_ped, (SELECT cliente_id FROM public.pedidos WHERE id = p_ped),
                                           p_items, p_motivo, 'ensayo C1', gen_random_uuid());
  PERFORM pg_temp.c1_reset();
  IF v_res ? 'error' OR NOT COALESCE((v_res->>'success')::boolean, true) THEN
    RETURN 'ERR ' || v_res::text;
  END IF;
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.c1_reset();
  RETURN SQLSTATE || ' ' || SQLERRM;
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1595-b2
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l1(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 empleado L1');
  v_pr  bigint := pg_temp.c1_producto(v_suc, 'C1 L1 fardo', 10);
  v_emp bigint := pg_temp.c1_empleado(v_suc, v_cli, v_adm);
  v_b1  bigint;
  v_b2  bigint;
  v_pg  bigint;
  v_s   bigint;
  v_nuevo bigint;
  v_r   text;
BEGIN
  v_b1 := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 6, 10));
  v_b2 := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 4, 10));
  PERFORM pg_temp.c1_fifo_adelanto(v_cli, 100, v_adm, v_suc);
  SELECT id INTO v_pg FROM public.pagos WHERE pedido_id = v_b2;
  IF v_pg IS NULL OR NOT (SELECT a_cuenta FROM public.pagos WHERE id = v_pg) THEN
    RAISE EXCEPTION 'fixture · el adelanto no entró a cuenta en la boleta de 40: %', pg_temp.c1_pagos(v_b2);
  END IF;

  v_s := pg_temp.c1_salvedad(v_b2, 4, v_adm, v_suc);
  IF EXISTS (SELECT 1 FROM public.pagos WHERE id = v_pg) THEN
    RAISE EXCEPTION 'fixture · la salvedad no borró el adelanto: %', pg_temp.c1_pagos(v_b2);
  END IF;
  PERFORM pg_temp.c1_anular(v_s, v_adm, v_suc);

  SELECT max(id) INTO v_nuevo FROM public.pagos WHERE pedido_id = v_b2;
  f := pg_temp.c1_si(f, v_nuevo IS NOT NULL AND (SELECT monto = 40 AND forma_pago = 'adelanto_sueldo' FROM public.pagos WHERE id = v_nuevo),
                     format('el adelanto no volvió como un cobro de 40: %s', pg_temp.c1_pagos(v_b2)));
  f := pg_temp.c1_si(f, (SELECT a_cuenta FROM public.pagos WHERE id = v_nuevo),
                     format('el cobro repuesto perdió a_cuenta: %s', pg_temp.c1_pagos(v_b2)));
  f := pg_temp.c1_si(f, pg_temp.c1_cuenta(v_emp) = -100,
                     format('la cuenta del empleado quedó en %s y no en -100', pg_temp.c1_cuenta(v_emp)));
  f := pg_temp.c1_si(f, (SELECT (s.cobro_recortado->0->'marcas'->>'a_cuenta')::boolean
                           FROM public.salvedades_items s WHERE s.id = v_s),
                     format('el recorte no anotó las marcas: %s', (SELECT cobro_recortado FROM public.salvedades_items WHERE id = v_s)));
  v_r := pg_temp.c1_desimputar(v_nuevo, v_b2, v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r = 'OK', format('desimputar_pago no aceptó el cobro repuesto: %s', v_r));
  f := pg_temp.c1_si(f, v_r <> 'OK' OR (SELECT pedido_id IS NULL FROM public.pagos WHERE id = v_nuevo),
                     'el cobro repuesto no quedó suelto');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l2(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 empleado L2');
  v_pr  bigint := pg_temp.c1_producto(v_suc, 'C1 L2 fardo', 10);
  v_emp bigint := pg_temp.c1_empleado(v_suc, v_cli, v_adm);
  v_b1  bigint;
  v_b3  bigint;
  v_pz  record;
  v_s   bigint;
  v_nuevo record;
  v_cuenta numeric;
BEGIN
  v_b1 := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 6, 10));
  PERFORM pg_temp.c1_fifo_adelanto(v_cli, 100, v_adm, v_suc);   -- 60 a la boleta, 40 sueltos
  v_b3 := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 3, 10));  -- se lleva 30 del suelto
  SELECT id, pago_origen_id, pago_padre_id INTO v_pz FROM public.pagos WHERE pedido_id = v_b3;
  IF v_pz.id IS NULL OR v_pz.pago_origen_id IS NULL THEN
    RAISE EXCEPTION 'fixture · la boleta de 30 no se llevó un pedazo del adelanto: %', pg_temp.c1_pagos(v_b3);
  END IF;
  v_cuenta := pg_temp.c1_cuenta(v_emp);

  v_s := pg_temp.c1_salvedad(v_b3, 3, v_adm, v_suc);
  IF EXISTS (SELECT 1 FROM public.pagos WHERE id = v_pz.id) THEN
    RAISE EXCEPTION 'fixture · la salvedad no borró el pedazo: %', pg_temp.c1_pagos(v_b3);
  END IF;
  PERFORM pg_temp.c1_anular(v_s, v_adm, v_suc);

  SELECT id, monto, pago_origen_id, pago_padre_id INTO v_nuevo
    FROM public.pagos WHERE pedido_id = v_b3 ORDER BY id DESC LIMIT 1;
  f := pg_temp.c1_si(f, v_nuevo.monto = 30, format('el pedazo no volvió como un cobro de 30: %s', pg_temp.c1_pagos(v_b3)));
  f := pg_temp.c1_si(f, v_nuevo.pago_origen_id = v_pz.pago_origen_id AND v_nuevo.pago_padre_id = v_pz.pago_padre_id,
                     format('el cobro repuesto no es pedazo de la misma raíz (%s) y padre (%s): %s',
                            v_pz.pago_origen_id, v_pz.pago_padre_id, pg_temp.c1_pagos(v_b3)));
  f := pg_temp.c1_si(f, pg_temp.c1_cuenta(v_emp) = v_cuenta,
                     format('la cuenta del empleado quedó en %s y no en %s', pg_temp.c1_cuenta(v_emp), v_cuenta));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_e1(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 E1');
  v_pr  bigint := pg_temp.c1_producto(v_suc, 'C1 E1 fardo', 10);
  v_b   bigint;
  v_s   bigint;
  v_nuevo bigint;
  v_r   text;
  v_res jsonb;
BEGIN
  v_b := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 4, 10));
  PERFORM pg_temp.c1_claims(v_adm, v_suc);
  v_res := public.registrar_pagos_pedido(v_b, '[{"monto": 40, "forma_pago": "efectivo"}]'::jsonb, public._tablero_hoy());
  PERFORM pg_temp.c1_reset();
  v_s := pg_temp.c1_salvedad(v_b, 4, v_adm, v_suc);
  PERFORM pg_temp.c1_anular(v_s, v_adm, v_suc);
  SELECT max(id) INTO v_nuevo FROM public.pagos WHERE pedido_id = v_b;
  f := pg_temp.c1_si(f, (SELECT monto = 40 AND NOT a_cuenta AND pago_origen_id IS NULL AND pago_padre_id IS NULL
                           FROM public.pagos WHERE id = v_nuevo),
                     format('el cobro común no volvió como un cobro sin marcas: %s', pg_temp.c1_pagos(v_b)));
  v_r := pg_temp.c1_desimputar(v_nuevo, v_b, v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023%no figura como saldo a favor aplicado%',
                     format('desimputar_pago sobre un cobro común dio %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- COB-b6
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l3(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 L3');
  v_pr  bigint := pg_temp.c1_producto(v_suc, 'C1 L3 fardo', 10);
  v_a   bigint;
  v_b   bigint;
  v_pg  bigint;
  v_res jsonb;
BEGIN
  v_b := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 10, 10), false);   -- impaga, la más vieja
  v_a := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 10, 10), false);
  PERFORM pg_temp.c1_claims(v_adm, v_suc);
  v_res := public.registrar_pagos_pedido(v_a, '[{"monto": 100, "forma_pago": "efectivo"}]'::jsonb, public._tablero_hoy());
  SELECT id INTO v_pg FROM public.pagos WHERE pedido_id = v_a;
  PERFORM pg_temp.c1_claims(v_adm, v_suc);
  v_res := to_jsonb(public.cancelar_pedido_con_stock(v_a, 'ensayo C1', v_adm, NULL));
  PERFORM pg_temp.c1_reset();
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  IF (SELECT pedido_id FROM public.pagos WHERE id = v_pg) IS DISTINCT FROM v_b THEN
    RAISE EXCEPTION 'fixture · el cobro de la cancelada no pasó a la otra boleta: % (%)',
      (SELECT pedido_id FROM public.pagos WHERE id = v_pg), v_res;
  END IF;
  f := pg_temp.c1_si(f, position('[saldo a favor' in COALESCE((SELECT notas FROM public.pagos WHERE id = v_pg), '')) = 0,
                     format('el cobro aplicado a la otra boleta sigue diciendo: %s', (SELECT notas FROM public.pagos WHERE id = v_pg)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l4(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 L4');
  v_pr  bigint := pg_temp.c1_producto(v_suc, 'C1 L4 fardo', 10);
  v_b1  bigint;
  v_b2  bigint;
  v_cr  bigint;
  v_pz  bigint;
BEGIN
  -- El crédito suelto, como lo deja cambiar_cliente_pedido; las boletas, después (si no, el alta lo absorbe).
  v_b1 := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 3, 10), false);
  v_b2 := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 10, 10), false);
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas)
  VALUES (v_cli, NULL, v_suc, 50, 'efectivo', public._tablero_hoy(), v_adm, 'x [saldo a favor por cambio de cliente]')
  RETURNING id INTO v_cr;
  -- En parte: 30 a la boleta de 30; queda el crédito en 20 y el pedazo.
  PERFORM pg_temp.c1_claims(v_adm, v_suc);
  PERFORM public.imputar_credito_a_pedido(v_cr, v_b1, 30, gen_random_uuid());
  SELECT id INTO v_pz FROM public.pagos WHERE pedido_id = v_b1 AND pago_padre_id = v_cr;
  f := pg_temp.c1_si(f, (SELECT notas FROM public.pagos WHERE id = v_pz) = 'x',
                     format('el pedazo imputado dice «%s» y no «x»', (SELECT notas FROM public.pagos WHERE id = v_pz)));
  -- Entero: los 20 que quedan, a la otra.
  PERFORM pg_temp.c1_claims(v_adm, v_suc);
  PERFORM public.imputar_credito_a_pedido(v_cr, v_b2, NULL, gen_random_uuid());
  PERFORM pg_temp.c1_reset();
  f := pg_temp.c1_si(f, (SELECT pedido_id = v_b2 AND notas = 'x' FROM public.pagos WHERE id = v_cr),
                     format('el crédito imputado entero dice «%s» (boleta %s)',
                            (SELECT notas FROM public.pagos WHERE id = v_cr), (SELECT pedido_id FROM public.pagos WHERE id = v_cr)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l5(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  r record;
BEGIN
  IF to_regproc('public._notas_sin_saldo_a_favor') IS NULL THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array('no existe _notas_sin_saldo_a_favor'));
  END IF;
  FOR r IN SELECT * FROM (VALUES
    ('[saldo a favor]', ''),
    ('Cobro 5 [saldo a favor por cancelacion]', 'Cobro 5 '),
    ('x [saldo a favor por cambio de cliente]', 'x '),
    ('[quitado del pedido #7] [saldo a favor]', '[quitado del pedido #7] '),
    ('a [saldo a favor] b [saldo a favor por cancelacion]', 'a  b '),
    ('[saldo a favor aplicado]', '[saldo a favor aplicado]'),
    (NULL, '')
  ) AS t(entra, sale) LOOP
    f := pg_temp.c1_si(f, (SELECT public._notas_sin_saldo_a_favor(r.entra)) = r.sale,
                       format('«%s» dio «%s» y no «%s»', r.entra, (SELECT public._notas_sin_saldo_a_favor(r.entra)), r.sale));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1598-b4
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l6(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 L6');
  v_pr  bigint := pg_temp.c1_producto(v_suc, 'C1 L6 fardo', 10);
  v_viva bigint;
  v_anul bigint;
  v_sin  bigint;
  v_s    bigint;
  v_got  text;
  v_ids  text;
  v_prev uuid;
  v_bool boolean;
BEGIN
  IF to_regprocedure('public.tiene_salvedad_vigente(public.pedidos)') IS NULL THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array('no existe la columna calculada tiene_salvedad_vigente(pedidos)'));
  END IF;
  v_viva := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 5, 10));
  v_anul := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 5, 10));
  v_sin  := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 5, 10));
  PERFORM pg_temp.c1_salvedad(v_viva, 1, v_adm, v_suc);
  v_s := pg_temp.c1_salvedad(v_anul, 1, v_adm, v_suc);
  PERFORM pg_temp.c1_anular(v_s, v_adm, v_suc);

  -- Como lo pide PostgREST: authenticated, con la RLS de pedidos y de salvedades_items.
  PERFORM pg_temp.c1_claims(v_adm, v_suc);
  SET LOCAL ROLE authenticated;
  EXECUTE format($q$SELECT string_agg(p.id || '=' || public.tiene_salvedad_vigente(p), ',' ORDER BY p.id)
                     FROM public.pedidos p WHERE p.id IN (%s, %s, %s)$q$, v_viva, v_anul, v_sin) INTO v_got;
  EXECUTE format($q$SELECT string_agg(p.id::text, ',' ORDER BY p.id) FROM public.pedidos p
                     WHERE p.cliente_id = %s AND public.tiene_salvedad_vigente(p)$q$, v_cli) INTO v_ids;
  RESET ROLE;
  f := pg_temp.c1_si(f, v_got = format('%s=true,%s=false,%s=false', v_viva, v_anul, v_sin),
                     format('la marca dio %s', v_got));
  f := pg_temp.c1_si(f, v_ids = v_viva::text, format('el filtro «con salvedad» trajo %s y no %s', v_ids, v_viva));

  -- La RPC llamada directo con la fila: un preventista que no vendió ni reparte el pedido no ve su salvedad
  -- (la RLS de salvedades_items tampoco se la deja ver), y desde otra sucursal tampoco.
  v_prev := pg_temp.c1_usuario('preventista', v_suc);
  PERFORM pg_temp.c1_claims(v_prev, v_suc);
  SET LOCAL ROLE authenticated;
  EXECUTE format('SELECT public.tiene_salvedad_vigente(p) FROM public.pedidos p WHERE p.id = %s', v_viva) INTO v_bool;
  RESET ROLE;
  IF v_bool IS NULL THEN
    -- La RLS de pedidos no le deja leer la fila: se la pasa armada, como por la RPC.
    PERFORM pg_temp.c1_claims(v_prev, v_suc);
    SELECT public.tiene_salvedad_vigente(p) INTO v_bool FROM public.pedidos p WHERE p.id = v_viva;
  END IF;
  f := pg_temp.c1_si(f, v_bool IS FALSE, format('a un preventista ajeno le dio %s', v_bool));
  PERFORM pg_temp.c1_claims(v_adm, (a->>'suc_b')::bigint);
  SELECT public.tiene_salvedad_vigente(p) INTO v_bool FROM public.pedidos p WHERE p.id = v_viva;
  f := pg_temp.c1_si(f, v_bool IS FALSE, format('desde otra sucursal le dio %s', v_bool));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- N2 y N7
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l7(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 L7');
  v_pa  bigint := pg_temp.c1_producto(v_suc, 'C1 fardo centavos', 100);
  v_pb  bigint := pg_temp.c1_producto(v_suc, 'C1 fardo con plata', 100);
  v_b   bigint;
  v_ia  bigint;
  v_ib  bigint;
  v_r   text;
  v_msg text := '%A «C1 fardo centavos» ya se le acreditó casi toda su plata con un descuento. Para devolver la mercadería, anulá primero ese descuento.%';
BEGIN
  v_b := pg_temp.c1_boleta(v_cli, v_adm, v_suc,
           jsonb_build_array(jsonb_build_object('producto_id', v_pa, 'cantidad', 3, 'precio_unitario', 100),
                             jsonb_build_object('producto_id', v_pb, 'cantidad', 3, 'precio_unitario', 100)));
  v_ia := pg_temp.c1_item(v_b, v_pa);
  v_ib := pg_temp.c1_item(v_b, v_pb);
  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ia, 'monto', 299.99)),
                       'descuento_comercial', v_adm, v_suc);
  IF v_r <> 'OK' THEN
    RAISE EXCEPTION 'fixture · el descuento de 299,99 no entró: %', v_r;
  END IF;

  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ia, 'cantidad', 1)),
                       'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023' || v_msg, format('1 u. sola dio %s', v_r));

  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ib, 'cantidad', 1),
                                              jsonb_build_object('pedido_item_id', v_ia, 'cantidad', 1)),
                       'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023' || v_msg, format('1 u. junto a otro renglón dio %s', v_r));
  f := pg_temp.c1_si(f, NOT EXISTS (SELECT 1 FROM public.nota_credito_venta_items i
                                     JOIN public.notas_credito_venta n ON n.id = i.nota_credito_id
                                    WHERE n.pedido_id = v_b AND i.cantidad > 0 AND i.subtotal = 0),
                     'quedó un renglón por unidades de $ 0');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_e2(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 E2');
  v_pa  bigint := pg_temp.c1_producto(v_suc, 'C1 E2 fardo', 100);
  v_b   bigint;
  v_ia  bigint;
  v_r   text;
BEGIN
  v_b := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pa, 3, 100));
  v_ia := pg_temp.c1_item(v_b, v_pa);
  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ia, 'monto', 299.99)),
                       'descuento_comercial', v_adm, v_suc);
  IF v_r <> 'OK' THEN
    RAISE EXCEPTION 'fixture · el descuento de 299,99 no entró: %', v_r;
  END IF;
  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ia, 'cantidad', 3)),
                       'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r = 'OK', format('las 3 u. con $ 0,01 que quedan dieron %s', v_r));
  f := pg_temp.c1_si(f, (SELECT sum(i.subtotal) FROM public.nota_credito_venta_items i
                           JOIN public.notas_credito_venta n ON n.id = i.nota_credito_id
                          WHERE n.pedido_id = v_b AND i.cantidad = 3) = 0.01,
                     'las 3 u. no acreditaron $ 0,01');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l8(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 L8');
  v_pa  bigint := pg_temp.c1_producto(v_suc, 'C1 gaseosa', 100);
  v_b   bigint;
  v_ia  bigint;
  v_reg bigint;
  v_r   text;
BEGIN
  v_b := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pa, 3, 100));
  v_ia := pg_temp.c1_item(v_b, v_pa);
  -- Un regalo en la boleta (la línea a precio 0 que deja una promo): directo, para no armar la promo.
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, es_bonificacion)
  VALUES (v_b, v_pa, 1, 0, 0, v_suc, true)
  RETURNING id INTO v_reg;

  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ia, 'cantidad', 0)), 'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023%«C1 gaseosa»%' AND v_r NOT LIKE '%' || v_ia || '%', format('cantidad 0 dio %s', v_r));
  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_reg, 'cantidad', 1)), 'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023%«C1 gaseosa» es un regalo%' AND v_r NOT LIKE '%' || v_reg || '%', format('el regalo dio %s', v_r));
  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ia, 'cantidad', 5)), 'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023%«C1 gaseosa»: se entregaron 3 y ya se acreditaron 0%' AND v_r NOT LIKE '%' || v_ia || '%',
                     format('más de lo entregado dio %s', v_r));
  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', 999999999, 'cantidad', 1)), 'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023%no es de la boleta #' || v_b || '%' AND v_r NOT LIKE '%999999999%',
                     format('un renglón ajeno dio %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayoC1$
DECLARE
  v_suc    bigint;
  v_args   jsonb;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';
  SELECT min(id) INTO v_suc FROM sucursales WHERE activa;
  IF public.ultima_fecha_caja_cerrada(v_suc) >= public._tablero_hoy() THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · la caja de hoy de la sucursal % ya está cerrada', v_suc;
  END IF;
  v_args := jsonb_build_object('suc', v_suc, 'adm', pg_temp.c1_usuario('admin', v_suc),
                               'suc_b', (SELECT min(id) FROM sucursales WHERE activa AND id > v_suc));

  FOREACH v_caso IN ARRAY ARRAY['l1', 'l2', 'e1', 'l3', 'l4', 'l5', 'l6', 'l7', 'e2', 'l8'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.c1_reset();
      EXECUTE format('SELECT pg_temp.c1_caso_%s($1)', v_caso) INTO v_out USING v_args;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas):\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · 1595-b2, COB-b6, 1598-b4, N2 y N7 (tarjeta C1 de la tanda 5)';
END
$ensayoC1$;
