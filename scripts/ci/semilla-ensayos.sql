-- Datos mínimos para que los ensayos de SQL (scripts/test-*.sql) corran sobre la base local de CI,
-- que nace sin datos (esquema de prod + la semilla de docker-local.mjs: el admin de las
-- sucursales 1 y 2). Muchos ensayos fueron escritos contra prod y arrancan pidiendo «una
-- sucursal activa con admin, encargado, preventista y transportista» o «un cliente activo»:
-- sin esto fallan antes de probar nada (107 de 173 sobre la base vacía).
--
-- Lo aplica .github/workflows/sql-local.yml después de la semilla y de las migraciones. Todo es
-- inventado (correos @ensayo.invalid, nombres «CI …»); nada de prod. NUNCA contra prod.
-- Es idempotente por correo.
DO $semilla$
DECLARE
  v_suc bigint;
  v_rol text;
  v_k int;
  v_u uuid;
  v_zona bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sucursales WHERE id IN (1, 2) HAVING count(*) = 2) THEN
    RAISE EXCEPTION 'la semilla de ensayos necesita las sucursales 1 y 2 (docker-local.mjs semilla)';
  END IF;

  INSERT INTO public.politicas_comerciales (sucursal_id)
  SELECT s FROM unnest(ARRAY[1, 2]::bigint[]) s
   WHERE NOT EXISTS (SELECT 1 FROM public.politicas_comerciales p WHERE p.sucursal_id = s);

  FOR v_suc IN 1..2 LOOP
    -- Un usuario de cada rol, y un segundo preventista y un segundo transportista (los ensayos
    -- de reparto y de cartera piden dos).
    FOREACH v_rol IN ARRAY ARRAY['admin', 'encargado', 'preventista', 'preventista', 'transportista', 'transportista', 'deposito'] LOOP
      v_k := (SELECT count(*) FROM auth.users WHERE email LIKE format('ci-%s-s%s-%%@ensayo.invalid', v_rol, v_suc)) + 1;
      v_u := gen_random_uuid();
      INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              format('ci-%s-s%s-%s@ensayo.invalid', v_rol, v_suc, v_k),
              jsonb_build_object('rol', v_rol, 'sucursal_id', v_suc),
              jsonb_build_object('nombre', format('CI %s %s-%s', v_rol, v_suc, v_k)), now(), now());
    END LOOP;

    INSERT INTO public.zonas (nombre, sucursal_id) VALUES (format('CI zona %s', v_suc), v_suc) RETURNING id INTO v_zona;

    FOR v_k IN 1..4 LOOP
      INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
      VALUES (format('CI Cliente %s-%s', v_suc, v_k), format('CI Cliente %s-%s', v_suc, v_k), format('Calle %s %s', v_suc, v_k), v_suc, v_zona);
      INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
      VALUES (format('CI Producto %s-%s', v_suc, v_k), 100 * v_k, 1000, 60 * v_k, v_suc);
    END LOOP;
    INSERT INTO public.proveedores (nombre, sucursal_id) VALUES (format('CI Proveedor %s', v_suc), v_suc);
  END LOOP;
END
$semilla$;

-- Los 18 rubros de gastos de la migración 411 y «Faltantes de caja» (con su clave, de la 446 y la 488): la base de CI nace sin datos y
-- varios ensayos de gastos (test-gastos-1, test-gastos-personal-1521…) piden los 19 como en prod.
INSERT INTO public.gasto_rubros (nombre, grupo, palabras_busqueda, pide_litros_km, reparto_sugerido_meses, sugiere_mes_anterior)
VALUES
  ('Combustible',              'vehiculos',      'nafta gasoil gnc',     true,  NULL, false),
  ('Seguro',                   'vehiculos',      NULL,                   false, 12,   false),
  ('Patente',                  'vehiculos',      NULL,                   false, NULL, false),
  ('Mantenimiento y service',  'vehiculos',      'taller mecanico',      false, NULL, false),
  ('Peajes y estacionamiento', 'vehiculos',      NULL,                   false, NULL, false),
  ('Alquiler',                 'inmueble',       NULL,                   false, NULL, false),
  ('Expensas',                 'inmueble',       NULL,                   false, NULL, false),
  ('Luz, agua y gas',          'inmueble',       'servicios',            false, NULL, false),
  ('Ingresos brutos',          'impuestos',      'iibb rentas dgr',      false, NULL, true),
  ('Tasa municipal',           'impuestos',      'cisi',                 false, NULL, false),
  ('Librería',                 'administracion', 'papeleria',            false, NULL, false),
  ('Teléfono e internet',      'administracion', 'celular',              false, NULL, false),
  ('Limpieza',                 'administracion', NULL,                   false, NULL, false),
  ('Honorarios del contador',  'administracion', 'estudio contable',     false, NULL, false),
  ('Oficina central (parte de la distribuidora)', 'administracion', NULL, false, NULL, false),
  ('Vehículo',                 'bienes_de_uso',  'camioneta utilitario', false, 60,   false),
  ('Equipos y muebles',        'bienes_de_uso',  'heladera estanteria',  false, 36,   false),
  ('Varios',                   'otros',          NULL,                   false, NULL, false)
ON CONFLICT ((lower(btrim(nombre)))) DO NOTHING;
INSERT INTO public.gasto_rubros (nombre, grupo, palabras_busqueda, pide_litros_km, reparto_sugerido_meses, sugiere_mes_anterior, clave)
VALUES ('Faltantes de caja', 'otros', 'faltante robo perdida', false, NULL, false, 'faltantes_caja')
ON CONFLICT ((lower(btrim(nombre)))) DO NOTHING;
