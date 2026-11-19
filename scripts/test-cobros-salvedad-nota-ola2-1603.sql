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
--   L11 · H4 de la revisión de C1 (decisión de la coordinadora): el empleado se da de baja entre la salvedad y la
--        anulación. Reponerle el adelanto se rechaza con «Ese cliente es la ficha de un empleado dado de baja…»,
--        sea la raíz, un pedazo o un adelanto vivo al que se le suma lo recortado; la cuenta no cambia (antes el
--        pedazo y el que se suma entraban y le volvían a cargar el adelanto al ex empleado).
--
--   COB-b6 · al aplicar un crédito se limpian todas las marcas de saldo a favor
--   L3 · Una boleta cobrada en efectivo se cancela con otra boleta del cliente impaga: el cobro pasa a la otra
--        sin «[saldo a favor por cancelacion]» en sus notas.
--   L4 · Un crédito suelto «x [saldo a favor por cambio de cliente]» imputado a mano (imputar_credito_a_pedido):
--        entero y en parte, el pago aplicado dice «x».
--   L5 · _notas_sin_saldo_a_favor saca las tres marcas y nada más.
--
--   1598-b4 · el filtro «con / sin salvedad» es un embed del front (sin SQL nuevo)
--   E4 · Lo mismo que el embed en SQL, como authenticated: «con» es un EXISTS sobre las salvedades vigentes y «sin»
--        el NOT EXISTS. El admin ve la boleta y el vale blanco con salvedad viva en «con» y la anulada en «sin»; el
--        transportista ve la boleta que reparte y no el vale blanco (la RLS de pedidos); un preventista ajeno y el
--        admin parado en otra sucursal no ven nada. Pasa con y sin la migración (la RLS corre sola).
--
--   N2 y N7 de la revisión de B22 · la nota por unidades
--   L7 · 3 × $ 100 con un descuento de $ 299,99 en la línea: 1 u. sola se rechaza con el mensaje de «casi toda su
--        plata»; 1 u. junto a otro renglón con plata, también (antes entraba con un renglón de $ 0,00).
--   E2 · Las 3 u. juntas (le quedan $ 0,01) entran: la parte no es 0.
--   L8 · Los mensajes de la rama por unidades nombran el producto y no el id de la línea: cantidad 0, un regalo,
--        más de lo entregado y un renglón que no es de la boleta.
--   L12 · H3 de la revisión de C1: una línea de venta a $ 0 sin la marca de regalo (de antes de la marca): 1 u.
--        sola o con otro renglón se rechaza con «“X” está a $ 0 en la boleta» (antes, con otro renglón entraba a $ 0).
--
--   1592-b5 residual (N1 de la revisión de M4) · una salvedad sobre el regalo no es un recorte
--   Promo 10 → 2 del mismo producto, venta 20 y regalo 4. Cada salvedad en su propia transacción (se corre la
--   hora de lo escrito, como en el ensayo de la tarjeta C2).
--   L9 · R baja el regalo 2; A rechaza 5 de la venta (le quedan 15, derecho 2: no recorta). Anular A entra
--        (antes se rechazaba porque la transacción de R bajó una línea de regalo).
--   L10 · R, A (5) y C (5) sin recorte. Anular A y después C, y en el otro orden C y después A (con una
--        anulada en el medio): las dos entran en los dos órdenes, y el pedido vuelve a venta 20 y regalo 2.
--   E3 · R, A (10, no recorta) y B (5 más: el regalo baja a 0, recorta). Anular A y después B, y B y después A:
--        las dos se rechazan en los dos órdenes (la regla conservadora, que no depende del orden).
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

-- anular_salvedad sin abortar: 'ok', el código del rechazo o el error.
CREATE OR REPLACE FUNCTION pg_temp.c1_anu_err(p_salv bigint, p_adm uuid, p_suc bigint)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  v_res := public.anular_salvedad(p_salv, 'ensayo C1');
  PERFORM pg_temp.c1_reset();
  RETURN CASE WHEN COALESCE((v_res->>'success')::boolean, false) THEN 'ok' ELSE COALESCE(v_res->>'codigo', v_res::text) END;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.c1_reset();
  RETURN SQLSTATE || ' ' || SQLERRM;
END
$fn$;

-- L11 · H4 de la revisión: el empleado se da de baja entre la salvedad y la anulación.
-- p_caso: 'raiz' (el adelanto de la boleta, borrado), 'pedazo' (el pedazo de una boleta posterior, borrado)
-- o 'sumar' (la salvedad recortó parte del adelanto, que sigue vivo: anular se lo vuelve a sumar).
CREATE OR REPLACE FUNCTION pg_temp.c1_l11(a jsonb, p_caso text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 empleado L11');
  v_pr  bigint := pg_temp.c1_producto(v_suc, 'C1 L11 fardo', 10);
  v_emp bigint := pg_temp.c1_empleado(v_suc, v_cli, v_adm);
  v_b1  bigint;
  v_b3  bigint;
  v_s   bigint;
  v_cuenta numeric;
  v_r   text;
BEGIN
  v_b1 := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 6, 10));
  PERFORM pg_temp.c1_fifo_adelanto(v_cli, 100, v_adm, v_suc);   -- 60 a la boleta (raíz), 40 sueltos
  v_b3 := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 3, 10));  -- un pedazo de 30
  v_s := CASE p_caso WHEN 'raiz' THEN pg_temp.c1_salvedad(v_b1, 6, v_adm, v_suc)
                     WHEN 'pedazo' THEN pg_temp.c1_salvedad(v_b3, 3, v_adm, v_suc)
                     ELSE pg_temp.c1_salvedad(v_b1, 2, v_adm, v_suc) END;
  UPDATE public.empleados SET activo = false, fecha_baja = public._tablero_hoy() WHERE id = v_emp;
  v_cuenta := pg_temp.c1_cuenta(v_emp);
  v_r := pg_temp.c1_anu_err(v_s, v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '%Ese cliente es la ficha de un empleado dado de baja: ya no se le dan adelantos de sueldo%',
                     format('%s: anular dio %s', p_caso, v_r));
  f := pg_temp.c1_si(f, pg_temp.c1_cuenta(v_emp) = v_cuenta,
                     format('%s: la cuenta del ex empleado pasó de %s a %s', p_caso, v_cuenta, pg_temp.c1_cuenta(v_emp)));
  RETURN f;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l11(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v_caso text;
BEGIN
  FOREACH v_caso IN ARRAY ARRAY['raiz', 'pedazo', 'sumar'] LOOP
    BEGIN
      f := f || pg_temp.c1_l11(a, v_caso);
      RAISE EXCEPTION USING ERRCODE = 'ZZ002';
    EXCEPTION WHEN SQLSTATE 'ZZ002' THEN NULL;
    END;
  END LOOP;
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
-- Lo que hace el embed del front, en SQL y como authenticated: «con» es un EXISTS sobre salvedades_items
-- vigentes (el !inner de PostgREST) y «sin» el NOT EXISTS (el anti-join), con la RLS de quien pregunta.
CREATE OR REPLACE FUNCTION pg_temp.c1_filtro(p_user uuid, p_suc bigint, p_ids bigint[], p_con boolean)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v text;
BEGIN
  PERFORM pg_temp.c1_claims(p_user, p_suc);
  SET LOCAL ROLE authenticated;
  EXECUTE format($q$SELECT COALESCE(string_agg(p.id::text, ',' ORDER BY p.id), '-')
                      FROM public.pedidos p
                     WHERE p.id = ANY (%L::bigint[])
                       AND %s EXISTS (SELECT 1 FROM public.salvedades_items s
                                       WHERE s.pedido_id = p.id AND s.sucursal_id = p.sucursal_id
                                         AND s.estado_resolucion <> 'anulada')$q$,
                 p_ids, CASE WHEN p_con THEN '' ELSE 'NOT' END) INTO v;
  RESET ROLE;
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_e4(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 E4');
  v_pr  bigint := pg_temp.c1_producto(v_suc, 'C1 E4 fardo', 10);
  v_tra uuid := pg_temp.c1_usuario('transportista', v_suc);
  v_prev uuid := pg_temp.c1_usuario('preventista', v_suc);
  v_viva bigint;
  v_anul bigint;
  v_sin  bigint;
  v_vb   bigint;
  v_cli_vb bigint;
  v_s    bigint;
  v_res  jsonb;
  v_ids  bigint[];
  v_r    text;
BEGIN
  v_viva := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 5, 10), false);
  v_anul := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 5, 10));
  v_sin  := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pr, 5, 10));
  -- Un vale blanco que reparte el transportista, con su salvedad.
  PERFORM pg_temp.c1_claims(v_adm, v_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  v_cli_vb := pg_temp.c1_cliente(v_suc, 'C1 E4 consumo interno');
  UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = v_cli_vb;
  v_res := public.crear_pedido_completo(v_cli_vb, 0, v_adm, pg_temp.c1_linea(v_pr, 5, 0), 'ensayo C1', 'efectivo',
                                        'pendiente', public._tablero_hoy(), 'VB');
  PERFORM pg_temp.c1_reset();
  v_vb := (v_res->>'pedido_id')::bigint;
  IF v_vb IS NULL THEN
    RAISE EXCEPTION 'fixture · no se pudo crear el vale blanco: %', v_res;
  END IF;
  UPDATE public.pedidos SET transportista_id = v_tra, estado = 'entregado', fecha_entrega = now()
   WHERE id IN (v_viva, v_vb);
  PERFORM pg_temp.c1_salvedad(v_viva, 1, v_adm, v_suc);
  PERFORM pg_temp.c1_salvedad(v_vb, 1, v_adm, v_suc);
  v_s := pg_temp.c1_salvedad(v_anul, 1, v_adm, v_suc);
  PERFORM pg_temp.c1_anular(v_s, v_adm, v_suc);
  v_ids := ARRAY[v_viva, v_anul, v_sin, v_vb];

  -- El admin ve las dos con salvedad vigente; la anulada cae en «sin».
  v_r := pg_temp.c1_filtro(v_adm, v_suc, v_ids, true);
  f := pg_temp.c1_si(f, v_r = format('%s,%s', least(v_viva, v_vb), greatest(v_viva, v_vb)), format('admin «con» dio %s', v_r));
  v_r := pg_temp.c1_filtro(v_adm, v_suc, v_ids, false);
  f := pg_temp.c1_si(f, v_r = format('%s,%s', v_anul, v_sin), format('admin «sin» dio %s', v_r));
  -- El transportista ve la boleta que reparte con su salvedad; el vale blanco no lo ve (la RLS de pedidos).
  v_r := pg_temp.c1_filtro(v_tra, v_suc, v_ids, true);
  f := pg_temp.c1_si(f, v_r = v_viva::text, format('transportista «con» dio %s (el VB no se ve)', v_r));
  v_r := pg_temp.c1_filtro(v_tra, v_suc, v_ids, false);
  f := pg_temp.c1_si(f, v_r = '-', format('transportista «sin» dio %s', v_r));
  -- Un preventista que no vendió ninguna: nada, ni con ni sin.
  v_r := pg_temp.c1_filtro(v_prev, v_suc, v_ids, true) || '|' || pg_temp.c1_filtro(v_prev, v_suc, v_ids, false);
  f := pg_temp.c1_si(f, v_r = '-|-', format('preventista ajeno dio %s', v_r));
  -- El admin parado en otra sucursal: nada.
  v_r := pg_temp.c1_filtro(v_adm, (a->>'suc_b')::bigint, v_ids, true) || '|' || pg_temp.c1_filtro(v_adm, (a->>'suc_b')::bigint, v_ids, false);
  f := pg_temp.c1_si(f, v_r = '-|-', format('desde otra sucursal dio %s', v_r));
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

-- ---------------------------------------------------------------------------
-- 1592-b5 residual
-- ---------------------------------------------------------------------------
-- Una promo «compra p_compra, lleva p_bonif» del mismo producto.
CREATE OR REPLACE FUNCTION pg_temp.c1_promo(p_suc bigint, p_prod bigint, p_compra int, p_bonif int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('C1 promo', 'bonificacion', public._tablero_hoy(), p_suc, true, p_prod) RETURNING id INTO v;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v, 'cantidad_compra', p_compra, p_suc), (v, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v, p_prod, p_suc);
  RETURN v;
END
$fn$;

-- Venta de 20 a $ 100 con 4 de regalo de la promo 10 → 2, entregada. Devuelve el pedido; el regalo en p_reg.
CREATE OR REPLACE FUNCTION pg_temp.c1_pedido_regalo(p_suc bigint, p_adm uuid, OUT o_ped bigint, OUT o_prod bigint, OUT o_reg bigint)
LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  o_prod := pg_temp.c1_producto(p_suc, 'C1 fardo con regalo', 100);
  o_ped := pg_temp.c1_boleta(pg_temp.c1_cliente(p_suc, 'C1 regalo'), p_adm, p_suc, pg_temp.c1_linea(o_prod, 20, 100), false);
  v_promo := pg_temp.c1_promo(p_suc, o_prod, 10, 2);
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, es_bonificacion, promocion_id)
  VALUES (o_ped, o_prod, 4, 0, 0, p_suc, true, v_promo) RETURNING id INTO o_reg;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', o_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', o_reg::text, true);
  UPDATE public.productos SET stock = stock - 4 WHERE id = o_prod;
  PERFORM pg_temp.c1_reset();
  UPDATE public.pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now() WHERE id = o_ped;
  PERFORM pg_temp.c1_otra_tx();
END
$fn$;

-- Lo escrito en esta transacción pasa a ser de una transacción anterior (una hora antes), para que la
-- salvedad siguiente tenga su propia created_at, como si fuera otra llamada.
CREATE OR REPLACE FUNCTION pg_temp.c1_otra_tx()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  UPDATE public.audit_logs SET created_at = created_at - interval '1 hour' WHERE created_at > now() - interval '2 days';
  UPDATE public.salvedades_items SET created_at = created_at - interval '1 hour' WHERE created_at > now() - interval '2 days';
  UPDATE public.pedido_historial SET created_at = created_at - interval '1 hour' WHERE created_at > now() - interval '2 days';
END
$fn$;

-- Salvedad 'cliente_rechaza' sobre una línea dada, en su propia transacción.
CREATE OR REPLACE FUNCTION pg_temp.c1_salv_item(p_ped bigint, p_item bigint, p_cant int, p_adm uuid, p_suc bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, 'cliente_rechaza', 'ensayo C1', NULL, true, NULL);
  PERFORM pg_temp.c1_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la salvedad no entró: %', v_res;
  END IF;
  PERFORM pg_temp.c1_otra_tx();
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

-- Anular sin abortar: 'ok' o el código del rechazo.
CREATE OR REPLACE FUNCTION pg_temp.c1_anu(p_salv bigint, p_adm uuid, p_suc bigint)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.c1_claims(p_adm, p_suc);
  v_res := public.anular_salvedad(p_salv, 'ensayo C1');
  PERFORM pg_temp.c1_reset();
  PERFORM pg_temp.c1_otra_tx();
  RETURN CASE WHEN COALESCE((v_res->>'success')::boolean, false) THEN 'ok' ELSE COALESCE(v_res->>'codigo', v_res::text) END;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_venta_regalo(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT 'venta ' || COALESCE(sum(cantidad) FILTER (WHERE NOT COALESCE(es_bonificacion, false)), 0)
         || ' regalo ' || COALESCE(sum(cantidad) FILTER (WHERE es_bonificacion), 0)
    FROM public.pedido_items WHERE pedido_id = p_ped;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l9(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  x     record;
  v_a   bigint;
  v_r   text;
BEGIN
  x := pg_temp.c1_pedido_regalo(v_suc, v_adm);
  PERFORM pg_temp.c1_salv_item(x.o_ped, x.o_reg, 2, v_adm, v_suc);
  v_a := pg_temp.c1_salv_item(x.o_ped, pg_temp.c1_item(x.o_ped, x.o_prod), 5, v_adm, v_suc);
  IF pg_temp.c1_venta_regalo(x.o_ped) <> 'venta 15 regalo 2' THEN
    RAISE EXCEPTION 'fixture · tras R y A el pedido quedó %', pg_temp.c1_venta_regalo(x.o_ped);
  END IF;
  v_r := pg_temp.c1_anu(v_a, v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r = 'ok', format('anular A (no recortó nada) dio %s', v_r));
  f := pg_temp.c1_si(f, v_r <> 'ok' OR pg_temp.c1_venta_regalo(x.o_ped) = 'venta 20 regalo 2',
                     format('tras anular A el pedido quedó %s', pg_temp.c1_venta_regalo(x.o_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- p_orden: 'ac' anula A y después C; 'ca', al revés.
CREATE OR REPLACE FUNCTION pg_temp.c1_l10(a jsonb, p_orden text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  x     record;
  v_a   bigint;
  v_c   bigint;
  v_r1  text;
  v_r2  text;
BEGIN
  x := pg_temp.c1_pedido_regalo(v_suc, v_adm);
  PERFORM pg_temp.c1_salv_item(x.o_ped, x.o_reg, 2, v_adm, v_suc);
  v_a := pg_temp.c1_salv_item(x.o_ped, pg_temp.c1_item(x.o_ped, x.o_prod), 5, v_adm, v_suc);
  v_c := pg_temp.c1_salv_item(x.o_ped, pg_temp.c1_item(x.o_ped, x.o_prod), 5, v_adm, v_suc);
  IF pg_temp.c1_venta_regalo(x.o_ped) <> 'venta 10 regalo 2' THEN
    RAISE EXCEPTION 'fixture · tras R, A y C el pedido quedó %', pg_temp.c1_venta_regalo(x.o_ped);
  END IF;
  IF p_orden = 'ac' THEN
    v_r1 := pg_temp.c1_anu(v_a, v_adm, v_suc);
    v_r2 := pg_temp.c1_anu(v_c, v_adm, v_suc);
  ELSE
    v_r1 := pg_temp.c1_anu(v_c, v_adm, v_suc);
    v_r2 := pg_temp.c1_anu(v_a, v_adm, v_suc);
  END IF;
  f := pg_temp.c1_si(f, v_r1 = 'ok' AND v_r2 = 'ok', format('orden %s: la primera dio %s y la segunda %s', p_orden, v_r1, v_r2));
  f := pg_temp.c1_si(f, pg_temp.c1_venta_regalo(x.o_ped) = 'venta 20 regalo 2',
                     format('orden %s: el pedido quedó %s', p_orden, pg_temp.c1_venta_regalo(x.o_ped)));
  RETURN f;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l10(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  -- Cada orden en su sub-bloque, que se revierte.
  BEGIN
    f := f || pg_temp.c1_l10(a, 'ac');
    RAISE EXCEPTION USING ERRCODE = 'ZZ002', MESSAGE = array_to_string(f, ' | ');
  EXCEPTION WHEN SQLSTATE 'ZZ002' THEN NULL;
  END;
  BEGIN
    f := f || pg_temp.c1_l10(a, 'ca');
    RAISE EXCEPTION USING ERRCODE = 'ZZ002';
  EXCEPTION WHEN SQLSTATE 'ZZ002' THEN NULL;
  END;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_e3(a jsonb, p_orden text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  x     record;
  v_a   bigint;
  v_b   bigint;
  v_r1  text;
  v_r2  text;
BEGIN
  x := pg_temp.c1_pedido_regalo(v_suc, v_adm);
  PERFORM pg_temp.c1_salv_item(x.o_ped, x.o_reg, 2, v_adm, v_suc);
  v_a := pg_temp.c1_salv_item(x.o_ped, pg_temp.c1_item(x.o_ped, x.o_prod), 10, v_adm, v_suc);
  v_b := pg_temp.c1_salv_item(x.o_ped, pg_temp.c1_item(x.o_ped, x.o_prod), 5, v_adm, v_suc);
  IF pg_temp.c1_venta_regalo(x.o_ped) <> 'venta 5 regalo 0' THEN
    RAISE EXCEPTION 'fixture · tras R, A y B el pedido quedó %', pg_temp.c1_venta_regalo(x.o_ped);
  END IF;
  IF p_orden = 'ab' THEN
    v_r1 := pg_temp.c1_anu(v_a, v_adm, v_suc);
    v_r2 := pg_temp.c1_anu(v_b, v_adm, v_suc);
  ELSE
    v_r1 := pg_temp.c1_anu(v_b, v_adm, v_suc);
    v_r2 := pg_temp.c1_anu(v_a, v_adm, v_suc);
  END IF;
  f := pg_temp.c1_si(f, v_r1 = 'anulacion_toca_promociones' AND v_r2 = 'anulacion_toca_promociones',
                     format('orden %s: la primera dio %s y la segunda %s (las dos se rechazan)', p_orden, v_r1, v_r2));
  RETURN f;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.c1_caso_e3(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  BEGIN
    f := f || pg_temp.c1_e3(a, 'ab');
    RAISE EXCEPTION USING ERRCODE = 'ZZ002';
  EXCEPTION WHEN SQLSTATE 'ZZ002' THEN NULL;
  END;
  BEGIN
    f := f || pg_temp.c1_e3(a, 'ba');
    RAISE EXCEPTION USING ERRCODE = 'ZZ002';
  EXCEPTION WHEN SQLSTATE 'ZZ002' THEN NULL;
  END;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- L12 · H3 de la revisión: una línea de venta a $ 0 sin la marca de regalo (de antes de que el alta la guardara;
-- hoy no se puede crear, se inserta sin triggers). 1 u. de esa línea, sola o con otro renglón con plata, se rechaza
-- con su mensaje (antes, sola daba «el total tiene que ser mayor a 0» y con otro renglón entraba a $ 0,00).
CREATE OR REPLACE FUNCTION pg_temp.c1_caso_l12(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc')::bigint;
  v_adm uuid := (a->>'adm')::uuid;
  v_cli bigint := pg_temp.c1_cliente(v_suc, 'C1 L12');
  v_pa  bigint := pg_temp.c1_producto(v_suc, 'C1 legado a cero', 100);
  v_pb  bigint := pg_temp.c1_producto(v_suc, 'C1 L12 con plata', 100);
  v_b   bigint;
  v_cero bigint;
  v_ib  bigint;
  v_r   text;
  v_msg text := '%“C1 legado a cero” está a $ 0 en la boleta: no hay plata que acreditar%';
BEGIN
  v_b := pg_temp.c1_boleta(v_cli, v_adm, v_suc, pg_temp.c1_linea(v_pb, 3, 100));
  SET LOCAL session_replication_role = replica;
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, es_bonificacion)
  VALUES (v_b, v_pa, 2, 0, 0, v_suc, NULL) RETURNING id INTO v_cero;
  SET LOCAL session_replication_role = origin;
  v_ib := pg_temp.c1_item(v_b, v_pb);

  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_cero, 'cantidad', 1)), 'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023' || v_msg, format('la línea a $ 0 sola dio %s', v_r));
  v_r := pg_temp.c1_nc(v_b, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ib, 'cantidad', 1),
                                              jsonb_build_object('pedido_item_id', v_cero, 'cantidad', 1)),
                       'cliente_rechaza', v_adm, v_suc);
  f := pg_temp.c1_si(f, v_r LIKE '22023' || v_msg, format('la línea a $ 0 con otro renglón dio %s', v_r));
  f := pg_temp.c1_si(f, NOT EXISTS (SELECT 1 FROM public.nota_credito_venta_items i
                                     JOIN public.notas_credito_venta n ON n.id = i.nota_credito_id
                                    WHERE n.pedido_id = v_b AND i.cantidad > 0 AND i.subtotal = 0),
                     'quedó un renglón por unidades de $ 0');
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

  FOREACH v_caso IN ARRAY ARRAY['l1', 'l2', 'e1', 'l11', 'l3', 'l4', 'l5', 'e4', 'l7', 'e2', 'l8', 'l12', 'l9', 'l10', 'e3'] LOOP
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
  RAISE EXCEPTION 'ENSAYO OK · 1595-b2 (con H4), COB-b6, 1598-b4, N2, N7, H3 y 1592-b5 (tarjeta C1 de la tanda 5)';
END
$ensayoC1$;
