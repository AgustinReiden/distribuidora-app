-- Semilla de datos para correr los ensayos `scripts/test-*.sql` contra la base LOCAL (#1539, #1603 B13b).
--
-- Los ensayos eligen sus personas y sus datos de lo que hay en la base ("una sucursal con admin, encargado y tres
-- preventistas", "un cliente sin asignar", "una boleta entregada con saldo"…): están escritos para correr contra prod,
-- que los tiene. La base del arnés nace con un solo admin y dos sucursales, y 60 de los 173 ensayos terminaban en
-- "faltan fixtures". Este archivo siembra lo mínimo para que corran. Usa sólo la API de la propia app (el alta de
-- `auth.users` que dispara `handle_new_user`, `crear_pedido_completo`, INSERT de cobros): nada de saltarse triggers.
--
--   node scripts/concurrencia/docker-local.mjs semilla              # primero: el admin de las sucursales 1 y 2
--   node scripts/concurrencia/docker-local.mjs semilla-ensayos      # este archivo
--
-- NO se deshace y NUNCA va con la base de medición del arnés (esa nace sin datos; `sin-semilla` y `fixtures` dejan de
-- valer): es para correr los ensayos en una base que se tira (`down` + `up` + `dump` la devuelve a la de medición).
-- Idempotente: si ya está puesta, no hace nada. Todo lleva el sufijo `@ensayos.test` o el nombre `Ensayo ·`.
--
-- Qué deja:
--   · sucursales 1 y 2 (ya están), cada una con: admin sólo de ella (el de la 1 no está en la 2: es el «admin con una sucursal
--     sin asignar» que piden los ensayos de permisos; el de la semilla las tiene a las dos), encargado, depósito, tres preventistas (uno con el extra
--     «transportista» en la 1), dos transportistas, una zona, 6 clientes (2 asignados a un preventista), 8 productos
--     con stock, y 12 boletas (pendientes, asignadas, entregadas con saldo y cobradas) repartidas en los últimos 60 días;
--   · cinco boletas entregadas el mismo día en cada sucursal (el ensayo de cargo-5).
-- Lo que NO deja (los ensayos que lo piden corren sólo contra prod, ver el README): más de 500 mermas, los pagos y los
-- pedidos con id fijo de prod (1538-B2, 1098, 1146).

DO $semilla$
DECLARE
  v_n int;
  v_suc bigint;
  v_rol text;
  v_i int;
  v_uid uuid;
  v_admin uuid;
  v_zona bigint;
  v_cli bigint;
  v_prod bigint;
  v_t1 uuid;
  v_t2 uuid;
  v_p1 uuid;
  v_ped bigint;
  v_res jsonb;
  v_d int;
  v_total numeric;
  v_cli_ids bigint[];
  v_prod_ids bigint[];
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = 'ens-a1@ensayos.test') THEN
    RAISE NOTICE 'semilla-ensayos: ya está puesta';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sucursales WHERE id IN (1, 2) HAVING count(*) = 2) THEN
    RAISE EXCEPTION 'semilla-ensayos: primero `docker-local.mjs semilla` (sucursales 1 y 2 y su admin)';
  END IF;
  PERFORM set_config('app.stock_origen', '', true);

  -- ----------------------------------------------------------- personas ---
  -- (email, rol, sucursal): el alta de auth.users crea el perfil y la sucursal por handle_new_user.
  FOR v_suc IN 1..2 LOOP
    FOREACH v_rol IN ARRAY ARRAY['admin', 'encargado', 'deposito'] LOOP
      INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
              format('ens-%s%s@ensayos.test', CASE v_rol WHEN 'admin' THEN 'a' WHEN 'encargado' THEN 'e' ELSE 'd' END, v_suc), '',
              jsonb_build_object('rol', v_rol, 'sucursal_id', v_suc), jsonb_build_object('nombre', format('Ensayo · %s %s', v_rol, v_suc)), now(), now());
    END LOOP;
    FOR v_i IN 1..3 LOOP
      INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
              format('ens-p%s%s@ensayos.test', v_suc, v_i), '',
              jsonb_build_object('rol', 'preventista', 'sucursal_id', v_suc), jsonb_build_object('nombre', format('Ensayo · preventista %s.%s', v_suc, v_i)), now(), now());
    END LOOP;
    FOR v_i IN 1..2 LOOP
      INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
              format('ens-t%s%s@ensayos.test', v_suc, v_i), '',
              jsonb_build_object('rol', 'transportista', 'sucursal_id', v_suc), jsonb_build_object('nombre', format('Ensayo · chofer %s.%s', v_suc, v_i)), now(), now());
    END LOOP;
  END LOOP;

  -- Un preventista con el extra «transportista» en la 1 (reparte y vende).
  SELECT id INTO v_p1 FROM auth.users WHERE email = 'ens-p13@ensayos.test';
  INSERT INTO public.perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_p1, 1, 'transportista') ON CONFLICT DO NOTHING;

  -- --------------------------------------------- zonas, clientes, productos ---
  FOR v_suc IN 1..2 LOOP
    SELECT id INTO v_admin FROM auth.users WHERE email = format('ens-a%s@ensayos.test', v_suc);
    INSERT INTO public.zonas (nombre, sucursal_id) VALUES (format('Ensayo · zona %s', v_suc), v_suc) RETURNING id INTO v_zona;
    v_cli_ids := '{}'; v_prod_ids := '{}';
    FOR v_i IN 1..6 LOOP
      -- Coordenadas a ~220 m una de otra (los ensayos de duplicados piden un cliente con coordenadas y ninguno a menos de 40 m).
      -- El 5 no tiene límite de crédito ni descuento y paga a 30 días (los ensayos de columnas protegidas lo piden así).
      INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id, activo, limite_credito, dias_credito,
                                   descuento_porcentaje, latitud, longitud)
      VALUES (format('Ensayo · cliente %s.%s', v_suc, v_i), format('Ensayo · cliente %s.%s', v_suc, v_i), 'Calle de Ensayo 123', v_suc, v_zona, true,
              CASE WHEN v_i = 5 THEN 0 ELSE 1000000 END, CASE WHEN v_i = 5 THEN 30 ELSE 0 END, 0,
              -26.8000 - v_suc * 0.05 - v_i * 0.002, -65.2000 - v_suc * 0.05 - v_i * 0.002)
      RETURNING id INTO v_cli;
      v_cli_ids := v_cli_ids || v_cli;
    END LOOP;
    FOR v_i IN 1..8 LOOP
      INSERT INTO public.productos (nombre, precio, stock, stock_minimo, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id, porcentaje_iva)
      VALUES (format('Ensayo · producto %s.%s', v_suc, v_i), 100 + v_i, 500, 0, 60, 60, 50, 60, v_suc, 21)
      RETURNING id INTO v_prod;
      v_prod_ids := v_prod_ids || v_prod;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);   -- la vuelta anterior dejó los claims de otra sucursal
    PERFORM set_config('request.headers', '', true);
    -- El último cliente es del primer preventista de la sucursal; los demás quedan «sin asignar» (visibles para todos, lo que
    -- los ensayos que toman «el primer cliente» necesitan).
    SELECT id INTO v_uid FROM auth.users WHERE email = format('ens-p%s1@ensayos.test', v_suc);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cli_ids[6], v_uid) ON CONFLICT DO NOTHING;

    -- ------------------------------------------------------------ boletas ---
    SELECT id INTO v_t1 FROM auth.users WHERE email = format('ens-t%s1@ensayos.test', v_suc);
    SELECT id INTO v_t2 FROM auth.users WHERE email = format('ens-t%s2@ensayos.test', v_suc);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    FOR v_i IN 1..12 LOOP
      v_d := CASE WHEN v_i <= 5 THEN 20 ELSE 55 - v_i * 4 END;      -- las cinco primeras, el mismo día (cargo-5)
      v_total := 1000 + v_i * 100;
      v_res := public.crear_pedido_completo(
        v_cli_ids[1 + (v_i % 4)], v_total, v_admin,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod_ids[1 + (v_i % 3)], 'cantidad', 10, 'precio_unitario', v_total / 10)),
        'ensayo semilla', 'efectivo', 'pendiente', public._tablero_hoy() - v_d, 'ZZ');
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'semilla-ensayos: no se pudo crear la boleta %.%: %', v_suc, v_i, v_res;
      END IF;
      v_ped := (v_res->>'pedido_id')::bigint;
      PERFORM set_config('app.stock_origen', '', true);
      IF v_i <= 8 THEN        -- entregadas (las pares, cobradas a medias; las impares, sin cobrar: todas quedan con saldo)
        UPDATE public.pedidos SET estado = 'entregado', transportista_id = CASE WHEN v_i % 2 = 0 THEN v_t1 ELSE v_t2 END,
               fecha_entrega = (public._tablero_hoy() - v_d)::timestamptz + interval '12 hours'
         WHERE id = v_ped;
        IF v_i % 2 = 0 THEN
          INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id)
          SELECT cliente_id, id, sucursal_id, total / 2, 'efectivo', public._tablero_hoy() - v_d, usuario_id FROM public.pedidos WHERE id = v_ped;
        END IF;
      ELSIF v_i <= 10 THEN    -- asignadas a un chofer, sin parada
        UPDATE public.pedidos SET estado = 'asignado', transportista_id = v_t1 WHERE id = v_ped;
      END IF;                 -- 11 y 12: quedan pendientes y sin chofer
    END LOOP;

    -- Dos boletas cargadas por un preventista (a nombre suyo) sobre clientes sin asignar, una entregada y una pendiente.
    SELECT id INTO v_uid FROM auth.users WHERE email = format('ens-p%s2@ensayos.test', v_suc);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    FOR v_i IN 1..2 LOOP
      v_res := public.crear_pedido_completo(
        v_cli_ids[v_i], 1010, v_uid,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod_ids[1], 'cantidad', 10, 'precio_unitario', 101)),
        'ensayo semilla preventista', 'efectivo', 'pendiente', public._tablero_hoy() - 3 * v_i, 'ZZ');
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'semilla-ensayos: no se pudo crear la boleta del preventista %.%: %', v_suc, v_i, v_res;
      END IF;
      PERFORM set_config('app.stock_origen', '', true);
      IF v_i = 1 THEN
        UPDATE public.pedidos SET estado = 'entregado', transportista_id = v_t1,
               fecha_entrega = (public._tablero_hoy() - 3)::timestamptz + interval '12 hours'
         WHERE id = (v_res->>'pedido_id')::bigint;
      END IF;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'semilla-ensayos: puesta (personas, zonas, clientes, productos y boletas de las sucursales 1 y 2)';
END
$semilla$;

-- ------------------------------------------- proveedores, compras, lotes y bot ---
-- Lo que piden los ensayos de compras, de lotes y de permisos: un proveedor, una compra recibida con su renglón y un lote por
-- sucursal, y los vínculos del bot (uno de otra sucursal, uno de dos y uno de la del admin). Segundo bloque, con su propia
-- guarda: se puede correr sobre una base que ya tiene el primero.
DO $semilla2$
DECLARE
  v_suc bigint;
  v_prov bigint;
  v_compra bigint;
  v_prod bigint;
  v_uid uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM public.proveedores WHERE nombre LIKE 'Ensayo · %') THEN
    RAISE NOTICE 'semilla-ensayos (compras y bot): ya está puesta';
    RETURN;
  END IF;
  FOR v_suc IN 1..2 LOOP
    INSERT INTO public.proveedores (nombre, sucursal_id) VALUES (format('Ensayo · proveedor %s', v_suc), v_suc) RETURNING id INTO v_prov;
    SELECT id INTO v_prod FROM public.productos WHERE sucursal_id = v_suc AND nombre = format('Ensayo · producto %s.6', v_suc);
    SELECT id INTO v_uid FROM auth.users WHERE email = format('ens-a%s@ensayos.test', v_suc);
    INSERT INTO public.compras (sucursal_id, proveedor_id, proveedor_nombre, fecha_compra, fecha_recepcion, subtotal, iva, total, estado, usuario_id)
    VALUES (v_suc, v_prov, format('Ensayo · proveedor %s', v_suc), public._tablero_hoy() - 10, public._tablero_hoy() - 10, 1000, 210, 1210, 'recibida', v_uid)
    RETURNING id INTO v_compra;
    INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
    VALUES (v_compra, v_prod, 100, 10, 1000, v_suc);
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen)
    VALUES (v_prod, v_suc, public._tablero_hoy() + 90, 100, 100, v_compra, 'compra');
  END LOOP;

  INSERT INTO public.bot_usuarios (telegram_user_id, telegram_username, perfil_id, rol, sucursal_id, activo)
  SELECT 900000 + row_number() OVER (ORDER BY x.email), 'ens_' || split_part(x.email, '@', 1), x.id, pf.rol, us.sucursal_id, true
    FROM auth.users x
    JOIN public.perfiles pf ON pf.id = x.id
    JOIN public.usuario_sucursales us ON us.usuario_id = x.id AND us.es_default
   WHERE x.email IN ('ens-a1@ensayos.test', 'ens-p11@ensayos.test', 'ens-p21@ensayos.test', 'semilla@conc.test');
  RAISE NOTICE 'semilla-ensayos (compras y bot): puesta';
END
$semilla2$;

-- ------------------------------------- rubros de gasto, historia y mermas ---
-- Tercer bloque, con su guarda. Lo que miran los ensayos de gastos (los 18 rubros del spec de la 411: en prod los trae la
-- migración, la base nace con uno), de checks y de integridad (boletas con fecha de creación de verdad —la de la boleta, no la de
-- la semilla—, un producto vendido sólo hace más de 30 días, facturas FC, un cancelado y mermas con usuario), y de reportes.
DO $semilla3$
DECLARE
  v_suc bigint;
  v_admin uuid;
  v_cli bigint;
  v_prod4 bigint;
  v_prod2 bigint;
  v_prod7 bigint;
  v_t1 uuid;
  v_res jsonb;
  v_ped bigint;
  v_i int;
BEGIN
  IF EXISTS (SELECT 1 FROM public.gasto_rubros WHERE nombre = 'Expensas') THEN
    RAISE NOTICE 'semilla-ensayos (rubros e historia): ya está puesta';
    RETURN;
  END IF;

  INSERT INTO public.gasto_rubros (nombre, grupo, pide_litros_km, reparto_sugerido_meses, sugiere_mes_anterior, palabras_busqueda)
  SELECT * FROM (VALUES
    ('Combustible', 'vehiculos', true, NULL::int, false, 'nafta gasoil gnc'),
    ('Seguro', 'vehiculos', false, 12, false, NULL),
    ('Patente', 'vehiculos', false, NULL, false, NULL),
    ('Mantenimiento y service', 'vehiculos', false, NULL, false, 'taller mecanico'),
    ('Peajes y estacionamiento', 'vehiculos', false, NULL, false, NULL),
    ('Alquiler', 'inmueble', false, NULL, false, NULL),
    ('Expensas', 'inmueble', false, NULL, false, NULL),
    ('Luz, agua y gas', 'inmueble', false, NULL, false, 'servicios'),
    ('Ingresos brutos', 'impuestos', false, NULL, true, 'iibb rentas dgr'),
    ('Tasa municipal', 'impuestos', false, NULL, false, 'cisi'),
    ('Librería', 'administracion', false, NULL, false, 'papeleria'),
    ('Teléfono e internet', 'administracion', false, NULL, false, 'celular'),
    ('Limpieza', 'administracion', false, NULL, false, NULL),
    ('Honorarios del contador', 'administracion', false, NULL, false, 'estudio contable'),
    ('Oficina central (parte de la distribuidora)', 'administracion', false, NULL, false, NULL),
    ('Vehículo', 'bienes_de_uso', false, 60, false, 'camioneta utilitario'),
    ('Equipos y muebles', 'bienes_de_uso', false, 36, false, 'heladera estanteria'),
    ('Varios', 'otros', false, NULL, false, NULL)) v;

  -- La fecha de creación de cada boleta de la semilla es la de su fecha (nacieron todas hoy, al correr la semilla).
  UPDATE public.pedidos SET created_at = fecha::timestamptz + interval '9 hours' WHERE notas LIKE 'ensayo semilla%';

  FOR v_suc IN 1..2 LOOP
    SELECT id INTO v_admin FROM auth.users WHERE email = format('ens-a%s@ensayos.test', v_suc);
    SELECT id INTO v_t1 FROM auth.users WHERE email = format('ens-t%s1@ensayos.test', v_suc);
    SELECT id INTO v_prod2 FROM public.productos WHERE nombre = format('Ensayo · producto %s.2', v_suc);
    SELECT id INTO v_prod4 FROM public.productos WHERE nombre = format('Ensayo · producto %s.4', v_suc);
    SELECT id INTO v_prod7 FROM public.productos WHERE nombre = format('Ensayo · producto %s.7', v_suc);
    SELECT min(id) INTO v_cli FROM public.clientes WHERE sucursal_id = v_suc;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    -- Dos boletas viejas (45 y 50 días) con un producto que no se vendió después: «un producto vendido sólo hace más de 30 días».
    FOR v_i IN 1..2 LOOP
      v_res := public.crear_pedido_completo(v_cli, 1000, v_admin,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod4, 'cantidad', 10, 'precio_unitario', 100)),
        'ensayo semilla vieja', 'efectivo', 'pendiente', public._tablero_hoy() - (40 + 5 * v_i), 'ZZ');
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'semilla-ensayos: boleta vieja %.%: %', v_suc, v_i, v_res; END IF;
      v_ped := (v_res->>'pedido_id')::bigint;
      PERFORM set_config('app.stock_origen', '', true);
      UPDATE public.pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = (public._tablero_hoy() - (40 + 5 * v_i))::timestamptz + interval '12 hours',
             created_at = (public._tablero_hoy() - (40 + 5 * v_i))::timestamptz + interval '9 hours' WHERE id = v_ped;
    END LOOP;

    -- Dos facturas FC entregadas (neto + IVA = total).
    FOR v_i IN 1..2 LOOP
      v_res := public.crear_pedido_completo(v_cli, 1210, v_admin,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod2, 'cantidad', 10, 'precio_unitario', 121)),
        'ensayo semilla fc', 'efectivo', 'pendiente', public._tablero_hoy() - 8 - v_i, 'FC');
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'semilla-ensayos: boleta FC %.%: %', v_suc, v_i, v_res; END IF;
      v_ped := (v_res->>'pedido_id')::bigint;
      PERFORM set_config('app.stock_origen', '', true);
      UPDATE public.pedidos SET estado = 'entregado', transportista_id = v_t1,
             fecha_entrega = (public._tablero_hoy() - 8 - v_i)::timestamptz + interval '12 hours',
             created_at = (public._tablero_hoy() - 8 - v_i)::timestamptz + interval '9 hours' WHERE id = v_ped;
    END LOOP;

    -- Un pedido cancelado de un cliente que tiene pedidos vivos.
    v_res := public.crear_pedido_completo(v_cli, 1000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod2, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo semilla cancelada', 'efectivo', 'pendiente', public._tablero_hoy() - 2, 'ZZ');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'semilla-ensayos: boleta a cancelar %: %', v_suc, v_res; END IF;
    v_res := public.cancelar_pedido_con_stock((v_res->>'pedido_id')::bigint, 'ensayo semilla', v_admin, NULL);
    PERFORM set_config('app.stock_origen', '', true);

    -- Dos mermas con usuario.
    FOR v_i IN 1..2 LOOP
      INSERT INTO public.mermas_stock (producto_id, cantidad, motivo, stock_anterior, stock_nuevo, usuario_id, sucursal_id, costo_unitario)
      VALUES (v_prod7, 1, 'rotura', 500, 499, v_admin, v_suc, 60);
    END LOOP;
    PERFORM set_config('app.stock_origen', '', true);
  END LOOP;
  RAISE NOTICE 'semilla-ensayos (rubros e historia): puesta';
END
$semilla3$;

-- ------------------------------- boletas de un preventista en el mes anterior ---
-- Cuarto bloque, con su guarda. Los ensayos de comisiones piden un preventista con ventas ENTREGADAS en el mes anterior
-- cerrado: la historia de la semilla es de los últimos 60 días y está cargada por el admin, así que se suman dos boletas
-- entregadas, de los últimos días del mes anterior, a nombre de un preventista (p_preventista_id: el pedido es suyo, lo carga el admin).
DO $semilla4$
DECLARE
  v_suc bigint;
  v_admin uuid;
  v_prev uuid;
  v_cli bigint;
  v_prod bigint;
  v_t1 uuid;
  v_res jsonb;
  v_i int;
  v_f date;
BEGIN
  IF EXISTS (SELECT 1 FROM public.pedidos WHERE notas = 'ensayo semilla prev viejo') THEN
    RAISE NOTICE 'semilla-ensayos (preventista, mes anterior): ya está puesta';
    RETURN;
  END IF;
  FOR v_suc IN 1..2 LOOP
    SELECT id INTO v_admin FROM auth.users WHERE email = format('ens-a%s@ensayos.test', v_suc);
    SELECT id INTO v_prev FROM auth.users WHERE email = format('ens-p%s2@ensayos.test', v_suc);
    SELECT id INTO v_t1 FROM auth.users WHERE email = format('ens-t%s1@ensayos.test', v_suc);
    SELECT id INTO v_prod FROM public.productos WHERE nombre = format('Ensayo · producto %s.1', v_suc);
    SELECT min(id) INTO v_cli FROM public.clientes WHERE sucursal_id = v_suc;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    FOR v_i IN 1..2 LOOP
      v_f := date_trunc('month', public._tablero_hoy())::date - CASE v_i WHEN 1 THEN 6 ELSE 3 END;   -- siempre en el mes anterior
      v_res := public.crear_pedido_completo(v_cli, 1000, v_admin,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
        'ensayo semilla prev viejo', 'efectivo', 'pendiente', v_f, 'ZZ', NULL, NULL, NULL, v_prev);
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'semilla-ensayos: boleta del preventista %.%: %', v_suc, v_i, v_res; END IF;
      PERFORM set_config('app.stock_origen', '', true);
      UPDATE public.pedidos SET estado = 'entregado', transportista_id = v_t1,
             fecha_entrega = v_f::timestamptz + interval '12 hours',
             created_at = v_f::timestamptz + interval '9 hours'
       WHERE id = (v_res->>'pedido_id')::bigint;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'semilla-ensayos (preventista, mes anterior): puesta';
END
$semilla4$;

-- ---------------------------------------------- porcentajes de comisión ---
-- Quinto bloque, con su guarda. La 421 siembra la historia del % de comisión desde `politicas_comerciales` (en prod: 2 % para
-- el preventista y 0 para el resto, desde siempre); la base vacía no tiene ninguna fila de política y los ensayos de gastos y de
-- comisiones piden «2 % vigente» en la sucursal 1.
DO $semilla5$
BEGIN
  IF EXISTS (SELECT 1 FROM public.comision_pct_vigencias) THEN
    RAISE NOTICE 'semilla-ensayos (comisiones): ya está puesta';
    RETURN;
  END IF;
  -- actualizado_en anterior al corte de la 421 (30/10): una fila del 2000 escrita después de ese corte la marca COMIS-06 en rojo.
  INSERT INTO public.comision_pct_vigencias (sucursal_id, vigente_desde, pct_preventista, pct_otros, actualizado_en)
  SELECT s.id, DATE '2000-01-01', 2, 0, TIMESTAMPTZ '2026-10-01 00:00:00+00' FROM public.sucursales s WHERE s.id IN (1, 2);
  RAISE NOTICE 'semilla-ensayos (comisiones): puesta';
END
$semilla5$;
