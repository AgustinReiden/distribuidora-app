-- Ensayo de la tarjeta C3 de la tanda 5 de la ola 2 del plan #1603: la edición de una compra
-- sincroniza sus lotes en la misma transacción (STK-13, #1542) y la nota de crédito de una FC
-- con un descuento NO gravado en factura no acredita de más (1590-b, H5 de la revisión de B2,
-- #1590). Migración: NNN_compras_edicion_con_lotes_y_nc_no_gravado.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la
-- migración fallan E1, E2, E4, H5, H5P y H5L; E3, HG y HZ son regresiones (dan igual antes y
-- después).
--
--   E1  · STK-13 · Una ZZ de 100 u. con lotes de 60 y 40 (bolsa 0) corregida a 80 en UNA
--         llamada que trae los lotes (50 y 30): stock 80, lotes 50/50 y 30/30, bolsa 0, y la
--         respuesta dice que los sincronizó. Sin la migración, la RPC no recibe los lotes.
--   E2  · STK-13 · La misma corrección con lotes que suman 90 (más que las 80 de la compra):
--         la edición entera se rechaza con el motivo de los lotes, y la compra, el stock y los
--         lotes quedan como estaban (100, 60/60 y 40/40).
--   E3  · STK-13 · Un PWA de antes (dos llamadas): la edición sin lotes y después
--         sincronizar_lotes_compra deja lo mismo que E1 (regresión).
--   E4  · STK-13 · Después de E1, repetir sincronizar_lotes_compra con la misma foto (el
--         «Reintentar» de un PWA de antes) no cambia nada: es inocua.
--   H5  · 1590-b · FC A de 10 × 100 al 21 % con un descuento NO gravado de −150 en factura
--         (total 1.060, mandado directo: el front no la deja cargar): devolver todo acredita
--         1.060 (850 de neto y los 210 de IVA, que el descuento no gravado no bajó), no 1.210.
--   H5P · lo mismo devolviendo 5 u.: 530 (425 + 105).
--   H5L · lo mismo por lote (Vencimientos): las 10 u. del lote acreditan 1.060.
--   HG  · FC A de 10 × 100 al 21 % con una bonificación de cabecera gravada de −100 (total
--         1.089): devolver todo acredita 1.089 (900 + 189), como antes (regresión).
--   HZ  · ZZ de 10 × 100 con un descuento en factura de −150 (total 850): 850 (regresión).
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-compras-edicion-lotes-y-nc-ola2-1603.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_j      jsonb;
  v_t      text;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c3-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'C3 ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  CREATE FUNCTION pg_temp.producto(p_nombre text) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, sucursal_id)
    VALUES ('C3 ' || p_nombre || ' ' || gen_random_uuid(), 1000, 0, 1) RETURNING id;
  $f$;
  -- Renglones: sin impuestos por defecto y con el subtotal que cierra.
  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(x || jsonb_build_object('subtotal',
             round((x->>'cantidad')::numeric * (x->>'costo_unitario')::numeric * (1 - (x->>'bonificacion')::numeric / 100), 2))
             ORDER BY o)
      FROM (SELECT jsonb_build_object('bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0) || e AS x, o
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)) s;
  $f$;
  CREATE FUNCTION pg_temp.compra(p_adm uuid, p_lin jsonb, p_tipo text, p_iva numeric, p_total numeric,
                                 p_cargos jsonb DEFAULT '[]'::jsonb, p_letra text DEFAULT NULL, p_bonif numeric DEFAULT 0)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    v := public.registrar_compra_completa(
      NULL, 'C3', 'C3-' || left(gen_random_uuid()::text, 8), public._tablero_hoy(),
      (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), p_iva, 0, p_total,
      'efectivo', 'c3', p_adm, p_lin, p_tipo, p_cargos => p_cargos, p_bonificaciones => p_bonif,
      p_letra_comprobante => p_letra);
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra no se registró: %', v;
    END IF;
    RETURN (v->>'compra_id')::bigint;
  END $f$;
  CREATE FUNCTION pg_temp.lotes_compra(p_adm uuid, p_c bigint, p_lotes jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.sincronizar_lotes_compra(p_c, p_lotes);
  END $f$;
  -- La edición de una ZZ. p_lotes NULL = un PWA de antes, que no los manda. Con lotes va por
  -- SQL dinámico: sin la migración la RPC no tiene ese parámetro y el caso falla.
  CREATE FUNCTION pg_temp.editar(p_adm uuid, p_c bigint, p_lin jsonb, p_lotes jsonb) RETURNS jsonb
  LANGUAGE plpgsql AS $f$
  DECLARE
    v jsonb;
    v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e);
    v_vistos bigint[] := (SELECT COALESCE(array_agg(id), '{}') FROM public.compra_items WHERE compra_id = p_c);
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    IF p_lotes IS NULL THEN
      RETURN public.actualizar_compra_items(p_c, p_lin, v_sub, 0, v_sub, p_adm,
        p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb, p_renglones_vistos => v_vistos);
    END IF;
    EXECUTE 'SELECT public.actualizar_compra_items($1, $2, $3, 0, $3, $4, p_cargos => ''[]''::jsonb,
               p_ii_declarado => ''{}''::jsonb, p_renglones_vistos => $5, p_lotes => $6)'
       INTO v USING p_c, p_lin, v_sub, p_adm, v_vistos, p_lotes;
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.estado(p bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('stock=%s lotes=%s bolsa=%s', pr.stock,
                  COALESCE((SELECT string_agg(l.cantidad_restante || '/' || l.cantidad, ',' ORDER BY l.fecha_vencimiento, l.id)
                              FROM public.producto_lotes l WHERE l.producto_id = p), '-'),
                  pr.stock - COALESCE((SELECT sum(l.cantidad_restante) FROM public.producto_lotes l WHERE l.producto_id = p), 0))
      FROM public.productos pr WHERE pr.id = p;
  $f$;
  -- Una NC de devolución con lo que manda la pantalla (el bruto: el front no tiene el factor).
  CREATE FUNCTION pg_temp.nc(p_adm uuid, p_c bigint, p_prod bigint, p_cant int, p_sub numeric, p_iva numeric)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.registrar_nota_credito(p_c, 'C3-' || left(gen_random_uuid()::text, 8), 'devolución c3',
             p_sub, p_iva, p_sub + p_iva, p_adm,
             jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'subtotal', p_sub)), NULL);
  END $f$;
  CREATE FUNCTION pg_temp.renglon(p_prod bigint, p_cant int, p_costo numeric, p_iva numeric) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.lineas(jsonb_build_array(jsonb_build_object(
             'producto_id', p_prod, 'cantidad', p_cant, 'costo_unitario', p_costo,
             'porcentaje_iva', p_iva, 'condicion_iva', 'gravado')));
  $f$;

  v_adm := pg_temp.u('admin', 1);

  -- ================================================================= E1 ====
  DECLARE
    v_p bigint := pg_temp.producto('E1');
    v_c bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 100, 10, 0), 'ZZ', 0, 1000);
    v_j := pg_temp.lotes_compra(v_adm, v_c, jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 60),
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 40)));
    BEGIN
      v_j := pg_temp.editar(v_adm, v_c, pg_temp.renglon(v_p, 80, 10, 0), jsonb_build_array(
               jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 50),
               jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 30)));
      v_t := format('%s | %s | lotes_sincronizados=%s', v_j->>'success', pg_temp.estado(v_p), v_j->>'lotes_sincronizados');
      IF v_t IS DISTINCT FROM 'true | stock=80 lotes=50/50,30/30 bolsa=0 | lotes_sincronizados=true' THEN
        v_fallas := v_fallas || format('E1 · editar a 80 con los lotes en la misma llamada: esperaba stock=80 lotes=50/50,30/30 bolsa=0 y dio %s (%s)', v_t, v_j);
      END IF;

      -- E4: el «Reintentar» de un PWA de antes repite la foto: no cambia nada.
      v_j := pg_temp.lotes_compra(v_adm, v_c, jsonb_build_array(
               jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 50),
               jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 30)));
      IF pg_temp.estado(v_p) IS DISTINCT FROM 'stock=80 lotes=50/50,30/30 bolsa=0' THEN
        v_fallas := v_fallas || format('E4 · repetir la sincronización con la misma foto cambió los lotes: %s', pg_temp.estado(v_p));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('E1 · la edición no recibe los lotes: %s %s', SQLSTATE, SQLERRM);
      v_fallas := v_fallas || 'E4 · no se pudo probar (E1 falló)'::text;
    END;
  END;

  -- ================================================================= E2 ====
  DECLARE
    v_p bigint := pg_temp.producto('E2');
    v_c bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 100, 10, 0), 'ZZ', 0, 1000);
    v_j := pg_temp.lotes_compra(v_adm, v_c, jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 60),
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 40)));
    BEGIN
      v_j := pg_temp.editar(v_adm, v_c, pg_temp.renglon(v_p, 80, 10, 0), jsonb_build_array(
               jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 60),
               jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 30)));
      v_t := format('%s | %s | renglón=%s', v_j->>'success', pg_temp.estado(v_p),
                    (SELECT sum(cantidad) FROM compra_items WHERE compra_id = v_c));
      IF v_t IS DISTINCT FROM 'false | stock=100 lotes=60/60,40/40 bolsa=0 | renglón=100'
         OR COALESCE(v_j->>'error', '') NOT LIKE '%suman 90 u.%' THEN
        v_fallas := v_fallas || format('E2 · lotes que no entran en la compra: esperaba el rechazo de toda la edición (100, 60/60 y 40/40) con el motivo de los lotes, y dio %s (%s)', v_t, v_j);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('E2 · la edición no recibe los lotes: %s %s', SQLSTATE, SQLERRM);
    END;
  END;

  -- ================================================================= E3 ====
  DECLARE
    v_p bigint := pg_temp.producto('E3');
    v_c bigint;
    v_l jsonb;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 100, 10, 0), 'ZZ', 0, 1000);
    v_j := pg_temp.lotes_compra(v_adm, v_c, jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 60),
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 40)));
    v_j := pg_temp.editar(v_adm, v_c, pg_temp.renglon(v_p, 80, 10, 0), NULL);
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_j ? 'lotes_sincronizados' THEN
      v_fallas := v_fallas || format('E3 · la edición de un PWA de antes (sin lotes): %s', v_j);
    END IF;
    v_l := jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 50),
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 30));
    v_j := pg_temp.lotes_compra(v_adm, v_c, v_l);
    IF pg_temp.estado(v_p) IS DISTINCT FROM 'stock=80 lotes=50/50,30/30 bolsa=0' THEN
      v_fallas := v_fallas || format('E3 · las dos llamadas de un PWA de antes: esperaba stock=80 lotes=50/50,30/30 bolsa=0 y dio %s', pg_temp.estado(v_p));
    END IF;
    v_j := pg_temp.lotes_compra(v_adm, v_c, v_l);
    IF pg_temp.estado(v_p) IS DISTINCT FROM 'stock=80 lotes=50/50,30/30 bolsa=0' THEN
      v_fallas := v_fallas || format('E3 · repetir la segunda llamada cambió los lotes: %s', pg_temp.estado(v_p));
    END IF;
  END;

  -- ======================================================== H5, H5P, H5L ====
  DECLARE
    v_desc jsonb := jsonb_build_array(jsonb_build_object('concepto', 'Descuento', 'monto', -150, 'condicion_iva', 'no_gravado',
                      'en_factura', true, 'prorratea_al_costo', false, 'base_prorrateo', 'unidades', 'pesos', '{}'::jsonb));
    v_p1 bigint := pg_temp.producto('H5');
    v_p2 bigint := pg_temp.producto('H5P');
    v_p3 bigint := pg_temp.producto('H5L');
    v_c1 bigint; v_c2 bigint; v_c3 bigint; v_lote bigint;
  BEGIN
    -- Directo a la RPC, como lo dejó la revisión de B2: el no gravado de la cabecera en 0 y el
    -- total del papel (1.060). La compra nace con el aviso de descuadre (y COMPRA-A1 la cuenta).
    v_c1 := pg_temp.compra(v_adm, pg_temp.renglon(v_p1, 10, 100, 21), 'FC', 210, 1060, v_desc, 'A');
    v_j := pg_temp.nc(v_adm, v_c1, v_p1, 10, 1000, 210);
    v_t := format('%s | sub=%s iva=%s total=%s', v_j->>'success', v_j->>'subtotal', v_j->>'iva', v_j->>'total');
    IF v_t IS DISTINCT FROM 'true | sub=850.00 iva=210.00 total=1060.00' THEN
      v_fallas := v_fallas || format('H5 · devolver toda la FC A con −150 no gravado (total 1.060): esperaba sub=850 iva=210 total=1.060 y dio %s', v_t);
    END IF;
    v_notas := v_notas || format('H5 · %s', v_t);

    v_c2 := pg_temp.compra(v_adm, pg_temp.renglon(v_p2, 10, 100, 21), 'FC', 210, 1060, v_desc, 'A');
    v_j := pg_temp.nc(v_adm, v_c2, v_p2, 5, 500, 105);
    v_t := format('%s | sub=%s iva=%s total=%s', v_j->>'success', v_j->>'subtotal', v_j->>'iva', v_j->>'total');
    IF v_t IS DISTINCT FROM 'true | sub=425.00 iva=105.00 total=530.00' THEN
      v_fallas := v_fallas || format('H5P · devolver 5 de la FC A con −150 no gravado: esperaba sub=425 iva=105 total=530 y dio %s', v_t);
    END IF;

    v_c3 := pg_temp.compra(v_adm, pg_temp.renglon(v_p3, 10, 100, 21), 'FC', 210, 1060, v_desc, 'A');
    v_j := pg_temp.lotes_compra(v_adm, v_c3, jsonb_build_array(
             jsonb_build_object('producto_id', v_p3, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 10)));
    SELECT id INTO v_lote FROM producto_lotes WHERE compra_id = v_c3;
    PERFORM pg_temp.como(v_adm, 1);
    BEGIN
      v_j := public.registrar_nota_credito_lote(v_lote, 10, 'C3-L-' || left(gen_random_uuid()::text, 8), 'vencido c3');
      v_t := format('sub=%s iva=%s total=%s', v_j->>'subtotal', v_j->>'iva', v_j->>'total');
    EXCEPTION WHEN OTHERS THEN
      v_t := 'error ' || SQLERRM;
    END;
    IF v_t IS DISTINCT FROM 'sub=850.00 iva=210.00 total=1060.00' THEN
      v_fallas := v_fallas || format('H5L · la nota por lote de las 10 u.: esperaba sub=850 iva=210 total=1.060 y dio %s', v_t);
    END IF;
  END;

  -- ================================================================= HG ====
  DECLARE
    v_p bigint := pg_temp.producto('HG');
    v_c bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 10, 100, 21), 'FC', 189, 1089, '[]'::jsonb, 'A', -100);
    v_j := pg_temp.nc(v_adm, v_c, v_p, 10, 1000, 210);
    v_t := format('%s | sub=%s iva=%s total=%s', v_j->>'success', v_j->>'subtotal', v_j->>'iva', v_j->>'total');
    IF v_t IS DISTINCT FROM 'true | sub=900.00 iva=189.00 total=1089.00' THEN
      v_fallas := v_fallas || format('HG · FC A con bonificación gravada de −100: esperaba sub=900 iva=189 total=1.089 y dio %s', v_t);
    END IF;
  END;

  -- ================================================================= HZ ====
  DECLARE
    v_p bigint := pg_temp.producto('HZ');
    v_c bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 10, 100, 0), 'ZZ', 0, 850,
             jsonb_build_array(jsonb_build_object('concepto', 'Descuento', 'monto', -150, 'condicion_iva', 'no_gravado',
               'en_factura', true, 'prorratea_al_costo', false, 'base_prorrateo', 'unidades', 'pesos', '{}'::jsonb)));
    v_j := pg_temp.nc(v_adm, v_c, v_p, 10, 1000, 0);
    v_t := format('%s | sub=%s iva=%s total=%s', v_j->>'success', v_j->>'subtotal', v_j->>'iva', v_j->>'total');
    IF v_t IS DISTINCT FROM 'true | sub=850.00 iva=0.00 total=850.00' THEN
      v_fallas := v_fallas || format('HZ · ZZ con −150 de descuento: esperaba 850 y dio %s', v_t);
    END IF;
  END;

  RAISE EXCEPTION USING ERRCODE = 'ZZ001';
 EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas:\n  %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, E'\n  '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format(E'ENSAYO OK (todo revertido) · E1 E2 E3 E4 H5 H5P H5L HG HZ\nnotas:\n  %s',
    array_to_string(v_notas, E'\n  '));
END
$ensayo$;
