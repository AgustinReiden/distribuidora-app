-- Ensayo de la tarjeta B2 de la ola 2 del plan #1603: compras, notas de crédito de compra y
-- envíos entre sucursales. Migración: NNN_compras_notas_de_credito_y_envios.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la
-- migración falla en todos los casos menos S1 (regresión), SN (declarado) y B7V (lo de
-- hoy).
--
--   A   · 1590-a · Producto con 10 u. a 80 (bolsa) y una ZZ de 10 a 100 con su lote: promedio
--         90. Una NC de 4 u. sale del lote (lote 6, stock 16, promedio 87,5). Anularla deja
--         stock 20, lote 10, bolsa 10, promedio 90 y la nota anulada con su motivo; sin motivo
--         o dos veces se rechaza. Después se pueden volver a devolver las 10.
--   AJ  · 1590-a · Una ZZ de 1.000 con un ajuste de 800: la devolución de las 10 u. (1.000)
--         se rechaza por el tope; anulado el ajuste, entra.
--   B   · 1590-b · ZZ de 10 × 100 con un descuento en factura de −150 (total 850): devolver
--         todo acredita 850, no 1.000, mande la pantalla el bruto o el neto. FC A de 10 × 100
--         al 21 % con una bonificación de cabecera de −100 (total 1.089): acredita 1.089, no
--         1.210. La NC por lote de una ZZ con −150 de descuento también: 850.
--   B4W · 1590-b (H4) · ZZ con W1 y W2 de 10 × 100 y un descuento de −200 prorrateado sólo a
--         W1 (total 1.800): devolver W1 acredita 800 y W2 1.000 (con el factor parejo, 900 y 900).
--   B4R · 1590-b (H4-r) · FC A con P1 al 21 % y P2 exento, y un descuento gravado de −200 con pesos
--         sólo en P1 que no prorratea al costo: devolver todo da 968 + 500 = 1.468 de 1.468.
--   B4  · 1557-b4 · El ajuste de una ZZ con IVA se rechaza; sin IVA entra.
--   B5  · 1557-b5 · Compras de 10 a 100 (anteayer) y de 10 a 120 (ayer): reposición 120.
--         Devolver entera la de ayer la vuelve a 100; anular esa nota, a 120.
--   B7  · 1557-b7 · Una ZZ de 10 a 100, y un envío de un origen con costo real 150: el
--         destino queda en 150. Corregir la compra a 110 lo deja en 150, no en 110.
--   B7V · 1557-b7 (H3) · Lo mismo con un envío anterior a la migración (sin origen_costo_real):
--         corregir la compra deja la terna como hoy, 110 / 110 / 110, no 110 / 150 / 150.
--   B8  · 1558-b8 (H2) · Un envío a un producto desactivado sin la marca `reactivar` se rechaza
--         con el nombre del producto y no se reactiva; con la marca, se acepta y lo reactiva.
--   S16 · STK-16 · Un envío creado sin promedio del origen (NULL) y aceptado cuando el origen
--         tiene 50: el ítem guarda 50.
--   C1  · 1593-b1: FC A de 10 × 100 al 21 % con un flete no gravado de 100 prorrateado deja
--         costo real 110. El costo con IVA era 121 (H1: no iba en esta migración); desde la de
--         la tarjeta C3 (decisión del dueño del 19/11) es el neto más el IVA de sus componentes,
--         131: cambió de regla (los casos completos, en test-compras-edicion-lotes-y-nc-ola2-1603).
--   C3  · 1593-b3 · Una FC B con IVA 21 mandada directo se rechaza (antes entraba con
--         COMPRA-A1 en rojo).
--   C5  · 1593-b5 · Un número de nota de 60 caracteres se rechaza con su motivo, en las dos
--         puertas (antes, error crudo de varchar(50)).
--   K12 · STK-12 · Una ZZ de 100 con lotes de 60 y 40 (bolsa 0) corregida a 1: el lote que
--         la segunda pasada saca entero se borra (antes quedaba en 1/0); queda uno en 1/1.
--   K14 · STK-14 · sincronizar_lotes_compra rechaza una compra con NC vigente, una de más de
--         8 días (H9: una de 7 días y medio, al límite de la edición, pasa) y al encargado
--         sobre una compra que ya tiene lotes; el encargado sí carga los de una compra sin lotes.
--   H11 · Una NC de devolución anterior al 10/11/2026 19:21:45 UTC (la 483) no se anula: no
--         corrigió el promedio ni sus lotes. Un ajuste de esa fecha sí se anula.
--   P10 · 1557-b10 · Dos proveedores de la misma sucursal con «20-11111111-2» y
--         «20111111112» no entran; en otra sucursal sí.
--   S1  · SEG-1 · Un admin desactivado no edita una compra (regresión: ya lo cortaba la
--         sucursal).
--   SN  · El CHECK productos_stock_no_negativo existe: «stock negativo con varios renglones
--         pagados» (lo que dejó la ola 1) no puede pasar.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-compras-nc-envios-ola2-1603.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_enc    uuid;
  v_adm2   uuid;
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
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b2-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'B2 ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
  END $f$;
  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text, p_stock int, p_cpp numeric) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES ('B2 ' || p_nombre || ' ' || gen_random_uuid(), 1000, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, p_suc) RETURNING id;
  $f$;
  -- renglones: defaults sin impuestos y el subtotal que cierra
  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(x || jsonb_build_object('subtotal',
             round((x->>'cantidad')::numeric * (x->>'costo_unitario')::numeric * (1 - (x->>'bonificacion')::numeric / 100), 2))
             ORDER BY o)
      FROM (SELECT jsonb_build_object('bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0) || e AS x, o
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)) s;
  $f$;
  CREATE FUNCTION pg_temp.alta(p_adm uuid, p_lin jsonb, p_tipo text, p_fecha date, p_iva numeric, p_total numeric,
                               p_cargos jsonb DEFAULT '[]'::jsonb, p_letra text DEFAULT NULL, p_bonif numeric DEFAULT 0)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.registrar_compra_completa(
      NULL, 'B2', 'B2-' || left(gen_random_uuid()::text, 8), p_fecha,
      (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), p_iva, 0, p_total,
      'efectivo', 'b2', p_adm, p_lin, p_tipo, p_cargos => p_cargos, p_bonificaciones => p_bonif,
      p_letra_comprobante => p_letra);
  END $f$;
  -- La compra, o una excepción con lo que dijo la RPC.
  CREATE FUNCTION pg_temp.compra(p_adm uuid, p_lin jsonb, p_tipo text, p_fecha date, p_iva numeric, p_total numeric,
                                 p_cargos jsonb DEFAULT '[]'::jsonb, p_letra text DEFAULT NULL, p_bonif numeric DEFAULT 0)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb := pg_temp.alta(p_adm, p_lin, p_tipo, p_fecha, p_iva, p_total, p_cargos, p_letra, p_bonif);
  BEGIN
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra no se registró: %', v;
    END IF;
    RETURN (v->>'compra_id')::bigint;
  END $f$;
  CREATE FUNCTION pg_temp.editar(p_adm uuid, p_c bigint, p_lin jsonb, p_iva numeric, p_total numeric) RETURNS jsonb
  LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.actualizar_compra_items(
      p_c, p_lin, (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), p_iva, p_total, p_adm,
      p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb,
      p_renglones_vistos => (SELECT COALESCE(array_agg(id), '{}') FROM public.compra_items WHERE compra_id = p_c));
  END $f$;
  -- Una NC de devolución: p_items [{producto_id, cantidad, subtotal}], con lo que manda la pantalla.
  CREATE FUNCTION pg_temp.nc(p_adm uuid, p_c bigint, p_items jsonb, p_sub numeric, p_iva numeric,
                             p_numero text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.registrar_nota_credito(p_c, COALESCE(p_numero, 'B2-' || left(gen_random_uuid()::text, 8)), 'devolución b2',
                                         p_sub, p_iva, p_sub + p_iva, p_adm, p_items, NULL);
  END $f$;
  CREATE FUNCTION pg_temp.ajuste(p_adm uuid, p_c bigint, p_sub numeric, p_iva numeric) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.registrar_nota_credito(p_c, 'B2-' || left(gen_random_uuid()::text, 8), 'ajuste b2',
                                         p_sub, p_iva, p_sub + p_iva, p_adm, '[]'::jsonb, 0);
  END $f$;
  -- La anulación por SQL dinámico: antes de la migración la RPC no existe y el caso falla.
  CREATE FUNCTION pg_temp.anular(p_uid uuid, p_nota bigint, p_motivo text) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid, 1);
    EXECUTE 'SELECT public.anular_nota_credito_compra($1, $2)' INTO v USING p_nota, p_motivo;
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.lotes_compra(p_uid uuid, p_c bigint, p_lotes jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_uid, 1);
    RETURN public.sincronizar_lotes_compra(p_c, p_lotes);
  END $f$;
  CREATE FUNCTION pg_temp.estado(p bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('stock=%s lotes=%s bolsa=%s cpp=%s',
                  pr.stock,
                  COALESCE((SELECT string_agg(l.cantidad_restante || '/' || l.cantidad, ',' ORDER BY l.fecha_vencimiento, l.id)
                              FROM public.producto_lotes l WHERE l.producto_id = p), '-'),
                  pr.stock - COALESCE((SELECT sum(l.cantidad_restante) FROM public.producto_lotes l WHERE l.producto_id = p), 0),
                  round(pr.costo_promedio, 4))
      FROM public.productos pr WHERE pr.id = p;
  $f$;
  CREATE FUNCTION pg_temp.a1() RETURNS int LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::int FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     WHERE c->>'id' = 'COMPRA-A1';
  $f$;

  -- ---------------------------------------------------------------- datos ---
  v_adm  := pg_temp.u('admin', 1);
  v_enc  := pg_temp.u('encargado', 1);
  v_adm2 := pg_temp.u('admin', 1);
  -- El admin también es de la sucursal 2 (para enviar desde ahí).
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm, 2) ON CONFLICT DO NOTHING;

  -- ================================================================== A ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'A', 10, 80);
    v_c bigint; v_n bigint; v_e0 text; v_e1 text; v_e2 text;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_j := pg_temp.lotes_compra(v_adm, v_c, jsonb_build_array(jsonb_build_object(
             'producto_id', v_p, 'fecha_vencimiento', v_hoy + 90, 'cantidad', 10)));
    v_e0 := pg_temp.estado(v_p);
    v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 4, 'subtotal', 400)), 400, 0);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'A · la NC no entró: %', v_j;
    END IF;
    v_n := (v_j->>'nota_credito_id')::bigint;
    v_e1 := pg_temp.estado(v_p);
    IF v_e1 IS DISTINCT FROM 'stock=16 lotes=6/10 bolsa=10 cpp=87.5000' THEN
      v_fallas := v_fallas || format('A · la NC de 4: esperaba stock=16 lotes=6/10 bolsa=10 cpp=87.5000 y dio %s', v_e1);
    END IF;
    BEGIN
      v_j := pg_temp.anular(v_adm, v_n, '  ');
      IF COALESCE((v_j->>'success')::boolean, true) THEN
        v_fallas := v_fallas || format('A · anular sin motivo debía rechazarse y dio %s', v_j);
      END IF;
      v_j := pg_temp.anular(v_adm, v_n, 'se cargó en la compra equivocada');
      v_e2 := pg_temp.estado(v_p);
      v_t := format('%s | %s | anulada=%s motivo=%s', v_j->>'success', v_e2,
                    (SELECT anulada FROM notas_credito WHERE id = v_n),
                    (SELECT motivo_anulacion FROM notas_credito WHERE id = v_n));
      IF v_t IS DISTINCT FROM 'true | stock=20 lotes=10/10 bolsa=10 cpp=90.0000 | anulada=t motivo=se cargó en la compra equivocada' THEN
        v_fallas := v_fallas || format('A · anular: esperaba stock=20 lotes=10/10 bolsa=10 cpp=90 y la nota anulada, y dio %s (%s)', v_t, v_j);
      END IF;
      v_j := pg_temp.anular(v_adm, v_n, 'otra vez');
      IF COALESCE((v_j->>'success')::boolean, true) THEN
        v_fallas := v_fallas || format('A · anular dos veces debía rechazarse y dio %s', v_j);
      END IF;
      v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'subtotal', 1000)), 1000, 0);
      IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('A · tras anular, devolver las 10 debía entrar y dio %s', v_j);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('A · la anulación: %s %s', SQLSTATE, SQLERRM);
    END;
    v_notas := v_notas || format('A · antes de la NC %s; con la NC %s; anulada %s', v_e0, v_e1, v_e2);
  END;

  -- ================================================================= AJ ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'AJ', 0, NULL);
    v_c bigint; v_n bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_j := pg_temp.ajuste(v_adm, v_c, 800, 0);
    v_n := (v_j->>'nota_credito_id')::bigint;
    v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'subtotal', 1000)), 1000, 0);
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('AJ · con un ajuste de 800 la devolución de 1.000 debía rechazarse y dio %s', v_j);
    END IF;
    BEGIN
      v_j := pg_temp.anular(v_adm, v_n, 'el proveedor no hizo el descuento');
      v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'subtotal', 1000)), 1000, 0);
      IF NOT COALESCE((v_j->>'success')::boolean, false) OR (v_j->>'total')::numeric <> 1000 THEN
        v_fallas := v_fallas || format('AJ · anulado el ajuste, la devolución de 1.000 debía entrar y dio %s', v_j);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('AJ · %s %s', SQLSTATE, SQLERRM);
    END;
  END;

  -- ================================================================== B ====
  DECLARE
    v_p1 bigint := pg_temp.producto(1, 'B zz', 0, NULL);
    v_p2 bigint := pg_temp.producto(1, 'B fc', 0, NULL);
    v_p3 bigint := pg_temp.producto(1, 'B lote', 0, NULL);
    v_desc jsonb := jsonb_build_array(jsonb_build_object('concepto', 'Descuento', 'monto', -150, 'condicion_iva', 'no_gravado',
                      'en_factura', true, 'prorratea_al_costo', false, 'base_prorrateo', 'unidades', 'pesos', '{}'::jsonb));
    v_c1 bigint; v_c2 bigint; v_c3 bigint; v_lote bigint;
  BEGIN
    -- ZZ con descuento, la pantalla manda el bruto (un front de antes)
    v_c1 := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
              jsonb_build_object('producto_id', v_p1, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 850, v_desc);
    v_j := pg_temp.nc(v_adm, v_c1, jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'cantidad', 5, 'subtotal', 500)), 500, 0);
    v_t := format('%s %s', v_j->>'success', v_j->>'total');
    -- y el resto con lo que manda un front nuevo (el neto)
    v_j := pg_temp.nc(v_adm, v_c1, jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'cantidad', 5, 'subtotal', 425)), 425, 0);
    v_t := v_t || format(' + %s %s = %s de %s', v_j->>'success', v_j->>'total',
                         (SELECT sum(total) FROM notas_credito WHERE compra_id = v_c1),
                         (SELECT total FROM compras WHERE id = v_c1));
    IF v_t IS DISTINCT FROM 'true 425.00 + true 425.00 = 850.00 de 850.00' THEN
      v_fallas := v_fallas || format('B · ZZ con −150: esperaba 425 + 425 = 850 de 850 y dio %s', v_t);
    END IF;

    -- FC A con bonificación de cabecera de −100: 900 + 189 de IVA = 1.089
    v_c2 := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
              jsonb_build_object('producto_id', v_p2, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21,
                                 'condicion_iva', 'gravado'))), 'FC', v_hoy, 189, 1089, '[]'::jsonb, 'A', -100);
    v_j := pg_temp.nc(v_adm, v_c2, jsonb_build_array(jsonb_build_object('producto_id', v_p2, 'cantidad', 10, 'subtotal', 1000)), 1000, 210);
    v_t := format('%s sub=%s iva=%s total=%s de %s', v_j->>'success', v_j->>'subtotal', v_j->>'iva', v_j->>'total',
                  (SELECT total FROM compras WHERE id = v_c2));
    IF v_t IS DISTINCT FROM 'true sub=900.00 iva=189.00 total=1089.00 de 1089.00' THEN
      v_fallas := v_fallas || format('B · FC A con −100: esperaba sub=900 iva=189 total=1089 de 1089 y dio %s (%s)', v_t, v_j);
    END IF;

    -- la nota por lote de una ZZ con −150
    v_c3 := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
              jsonb_build_object('producto_id', v_p3, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 850, v_desc);
    v_j := pg_temp.lotes_compra(v_adm, v_c3, jsonb_build_array(jsonb_build_object(
             'producto_id', v_p3, 'fecha_vencimiento', v_hoy + 20, 'cantidad', 10)));
    SELECT id INTO v_lote FROM producto_lotes WHERE compra_id = v_c3;
    BEGIN
      PERFORM pg_temp.como(v_adm, 1);
      v_j := public.registrar_nota_credito_lote(v_lote, 10, 'B2-L-' || left(gen_random_uuid()::text, 6), 'vencido');
      IF (v_j->>'total')::numeric IS DISTINCT FROM 850 THEN
        v_fallas := v_fallas || format('B · NC por lote de una ZZ con −150: esperaba 850 y dio %s', v_j->>'total');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('B · NC por lote: %s %s', SQLSTATE, SQLERRM);
    END;
  END;

  -- ================================================================ B4W ====
  DECLARE
    v_w1 bigint := pg_temp.producto(1, 'B4W uno', 0, NULL);
    v_w2 bigint := pg_temp.producto(1, 'B4W dos', 0, NULL);
    v_c  bigint;
    v_d  jsonb := jsonb_build_array(jsonb_build_object('concepto', 'Descuento W1', 'monto', -200, 'condicion_iva', 'no_gravado',
                    'en_factura', true, 'prorratea_al_costo', true, 'base_prorrateo', 'unidades',
                    'pesos', jsonb_build_object('0', 10)));
    v_t1 text; v_t2 text;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_w1, 'cantidad', 10, 'costo_unitario', 100),
             jsonb_build_object('producto_id', v_w2, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1800, v_d);
    v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_w1, 'cantidad', 10, 'subtotal', 1000)), 1000, 0);
    v_t1 := format('%s %s', v_j->>'success', v_j->>'total');
    v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_w2, 'cantidad', 10, 'subtotal', 1000)), 1000, 0);
    v_t2 := format('%s %s', v_j->>'success', v_j->>'total');
    v_t := format('W1 %s | W2 %s | suma %s de %s', v_t1, v_t2,
                  (SELECT sum(total) FROM notas_credito WHERE compra_id = v_c), (SELECT total FROM compras WHERE id = v_c));
    IF v_t IS DISTINCT FROM 'W1 true 800.00 | W2 true 1000.00 | suma 1800.00 de 1800.00' THEN
      v_fallas := v_fallas || format('B4W · el descuento de −200 sólo sobre W1: esperaba W1 800, W2 1000, suma 1800 de 1800 y dio %s', v_t);
    END IF;
  END;

  -- ================================================================ B4R ====
  -- H4-r: un descuento gravado en factura con pesos sólo en P1 que NO prorratea al costo. El
  -- motor reparte la base del IVA por los pesos igual: devolver todo da 968 + 500 = 1.468 de
  -- 1.468 (con el descuento parejo daba 1.048,67 + 433,33 = 1.482).
  DECLARE
    v_p1 bigint := pg_temp.producto(1, 'B4R gravado', 0, NULL);
    v_p2 bigint := pg_temp.producto(1, 'B4R exento', 0, NULL);
    v_c  bigint;
    v_d  jsonb := jsonb_build_array(jsonb_build_object('concepto', 'Descuento P1', 'monto', -200, 'condicion_iva', 'gravado',
                    'en_factura', true, 'prorratea_al_costo', false, 'base_prorrateo', 'unidades',
                    'pesos', jsonb_build_object('0', 10)));
    v_t1 text; v_t2 text;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p1, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21,
                                'condicion_iva', 'gravado'),
             jsonb_build_object('producto_id', v_p2, 'cantidad', 10, 'costo_unitario', 50, 'porcentaje_iva', 0,
                                'condicion_iva', 'exento'))), 'FC', v_hoy, 168, 1468, v_d, 'A', -200);
    v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'cantidad', 10, 'subtotal', 1000)), 1000, 210);
    v_t1 := format('%s %s', v_j->>'success', v_j->>'total');
    v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p2, 'cantidad', 10, 'subtotal', 500)), 500, 0);
    v_t2 := format('%s %s', v_j->>'success', v_j->>'total');
    v_t := format('P1 %s | P2 %s | suma %s de %s', v_t1, v_t2,
                  (SELECT sum(total) FROM notas_credito WHERE compra_id = v_c), (SELECT total FROM compras WHERE id = v_c));
    IF v_t IS DISTINCT FROM 'P1 true 968.00 | P2 true 500.00 | suma 1468.00 de 1468.00' THEN
      v_fallas := v_fallas || format('B4R · el descuento gravado de −200 sólo sobre P1, sin prorratear al costo: esperaba P1 968, P2 500, suma 1468 de 1468 y dio %s', v_t);
    END IF;
  END;

  -- ================================================================= B4 ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'B4', 0, NULL);
    v_c bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_j := pg_temp.ajuste(v_adm, v_c, 100, 21);
    v_t := v_j->>'success';
    v_j := pg_temp.ajuste(v_adm, v_c, 100, 0);
    v_t := v_t || ' ' || (v_j->>'success');
    IF v_t IS DISTINCT FROM 'false true' THEN
      v_fallas := v_fallas || format('B4 · ajuste de una ZZ con IVA / sin IVA: esperaba false true y dio %s', v_t);
    END IF;
  END;

  -- ================================================================= B5 ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'B5', 0, NULL);
    v_ca bigint; v_cb bigint; v_n bigint; v_r1 numeric; v_r2 numeric; v_r3 numeric;
  BEGIN
    v_ca := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
              jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy - 2, 0, 1000);
    v_cb := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
              jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 120))), 'ZZ', v_hoy - 1, 0, 1200);
    v_r1 := (SELECT costo_real FROM productos WHERE id = v_p);
    v_j := pg_temp.nc(v_adm, v_cb, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'subtotal', 1200)), 1200, 0);
    v_n := (v_j->>'nota_credito_id')::bigint;
    v_r2 := (SELECT costo_real FROM productos WHERE id = v_p);
    BEGIN
      v_j := pg_temp.anular(v_adm, v_n, 'la devolución no salió');
      v_r3 := (SELECT costo_real FROM productos WHERE id = v_p);
    EXCEPTION WHEN OTHERS THEN
      v_r3 := NULL;
    END;
    v_t := format('%s → %s → %s', round(v_r1, 2), round(v_r2, 2), round(v_r3, 2));
    IF v_t IS DISTINCT FROM '120.00 → 100.00 → 120.00' THEN
      v_fallas := v_fallas || format('B5 · reposición con la compra de ayer devuelta entera y anulada la nota: esperaba 120.00 → 100.00 → 120.00 y dio %s', v_t);
    END IF;
  END;

  -- ========================================================== B7, B8, S16 ====
  DECLARE
    v_d   bigint := pg_temp.producto(1, 'B7 destino', 0, NULL);
    v_o   bigint := pg_temp.producto(2, 'B7 origen', 10, 150);
    v_d2  bigint := pg_temp.producto(1, 'B8 destino', 0, 40);
    v_o2  bigint := pg_temp.producto(2, 'B8 origen', 10, NULL);
    v_c bigint; v_mov bigint; v_item bigint; v_r1 numeric; v_r2 numeric; v_lin jsonb;
  BEGIN
    v_lin := pg_temp.lineas(jsonb_build_array(jsonb_build_object('producto_id', v_d, 'cantidad', 10, 'costo_unitario', 100)));
    v_c := pg_temp.compra(v_adm, v_lin, 'ZZ', v_hoy, 0, 1000);
    -- La compra se cargó hace una hora: acá todo nace en la misma transacción, y el envío se
    -- acepta después de la compra.
    UPDATE compras SET created_at = now() - interval '1 hour' WHERE id = v_c;
    -- el envío de 2 a 1, aceptado
    PERFORM pg_temp.como(v_adm, 2);
    v_j := public.crear_movimiento_sucursal(1, 'ensayo b2', jsonb_build_array(jsonb_build_object('producto_id', v_o, 'cantidad', 5)));
    v_mov := (v_j->>'movimiento_id')::bigint;
    SELECT id INTO v_item FROM movimiento_sucursal_items WHERE movimiento_id = v_mov;
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object(
             'item_id', v_item, 'accion', 'match_existente', 'producto_destino_id', v_d)));
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'B7 · el envío no se aceptó: %', v_j;
    END IF;
    v_r1 := (SELECT costo_real FROM productos WHERE id = v_d);
    v_j := pg_temp.editar(v_adm, v_c, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_d, 'cantidad', 10, 'costo_unitario', 110))), 0, 1100);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'B7 · la edición no entró: %', v_j;
    END IF;
    v_r2 := (SELECT costo_real FROM productos WHERE id = v_d);
    v_t := format('%s → %s', round(v_r1, 2), round(v_r2, 2));
    IF v_t IS DISTINCT FROM '150.00 → 150.00' THEN
      v_fallas := v_fallas || format('B7 · el envío de 150 y la compra corregida a 110: esperaba 150.00 → 150.00 y dio %s', v_t);
    END IF;
    BEGIN
      EXECUTE 'SELECT origen_costo_real FROM public.movimiento_sucursal_items WHERE id = $1' INTO v_r1 USING v_item;
      IF v_r1 IS DISTINCT FROM 150 THEN
        v_fallas := v_fallas || format('B7 · el ítem del envío debía guardar el costo real del origen (150) y guardó %s', v_r1);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('B7 · origen_costo_real: %s %s', SQLSTATE, SQLERRM);
    END;

    -- B8 y S16: un envío sin promedio del origen, a un destino desactivado
    UPDATE productos SET activo = false WHERE id = v_d2;
    PERFORM pg_temp.como(v_adm, 2);
    v_j := public.crear_movimiento_sucursal(1, 'ensayo b2 b8', jsonb_build_array(jsonb_build_object('producto_id', v_o2, 'cantidad', 5)));
    v_mov := (v_j->>'movimiento_id')::bigint;
    SELECT id INTO v_item FROM movimiento_sucursal_items WHERE movimiento_id = v_mov;
    UPDATE productos SET costo_promedio = 50 WHERE id = v_o2;
    PERFORM pg_temp.como(v_adm, 1);
    -- sin la marca: se rechaza y no se reactiva
    v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object(
             'item_id', v_item, 'accion', 'match_existente', 'producto_destino_id', v_d2)));
    v_t := format('%s activo=%s', v_j->>'success', (SELECT activo FROM productos WHERE id = v_d2));
    IF v_t IS DISTINCT FROM 'false activo=f' OR position('está desactivado en esta sucursal' in COALESCE(v_j->>'error', '')) = 0 THEN
      v_fallas := v_fallas || format('B8 · sin la marca, un destino desactivado debía rechazarse con su motivo y dio %s (%s)', v_t, v_j);
    END IF;
    -- con la marca: se acepta y se reactiva
    v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object(
             'item_id', v_item, 'accion', 'match_existente', 'producto_destino_id', v_d2, 'reactivar', true)));
    v_t := format('%s activo=%s reactivados=%s', v_j->>'success', (SELECT activo FROM productos WHERE id = v_d2),
                  COALESCE(v_j->'reactivados' = jsonb_build_array(v_d2), false));
    IF v_t IS DISTINCT FROM 'true activo=t reactivados=t' THEN
      v_fallas := v_fallas || format('B8 · con la marca, el destino desactivado debía aceptarse y reactivarse y dio %s (%s)', v_t, v_j);
    END IF;
    v_r1 := (SELECT origen_costo_promedio FROM movimiento_sucursal_items WHERE id = v_item);
    IF v_r1 IS DISTINCT FROM 50 THEN
      v_fallas := v_fallas || format('S16 · el envío sin foto del promedio debía guardar el que usó (50) y guardó %s', v_r1);
    END IF;
  END;

  -- ================================================================ B7V ====
  DECLARE
    v_d   bigint := pg_temp.producto(1, 'B7V destino', 0, NULL);
    v_o   bigint := pg_temp.producto(2, 'B7V origen', 10, 150);
    v_c bigint; v_mov bigint; v_item bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_d, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    UPDATE compras SET created_at = now() - interval '1 hour' WHERE id = v_c;
    PERFORM pg_temp.como(v_adm, 2);
    v_j := public.crear_movimiento_sucursal(1, 'ensayo b2 b7v', jsonb_build_array(jsonb_build_object('producto_id', v_o, 'cantidad', 5)));
    v_mov := (v_j->>'movimiento_id')::bigint;
    SELECT id INTO v_item FROM movimiento_sucursal_items WHERE movimiento_id = v_mov;
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object(
             'item_id', v_item, 'accion', 'match_existente', 'producto_destino_id', v_d)));
    -- como un envío aceptado antes de la migración: sin el costo real del origen
    BEGIN
      EXECUTE 'UPDATE public.movimiento_sucursal_items SET origen_costo_real = NULL WHERE id = $1' USING v_item;
    EXCEPTION WHEN undefined_column THEN NULL;
    END;
    v_j := pg_temp.editar(v_adm, v_c, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_d, 'cantidad', 10, 'costo_unitario', 110))), 0, 1100);
    v_t := (SELECT format('real=%s sin=%s con=%s', round(costo_real, 2), round(costo_sin_iva, 2), round(costo_con_iva, 2))
              FROM productos WHERE id = v_d);
    IF v_t IS DISTINCT FROM 'real=110.00 sin=110.00 con=110.00' THEN
      v_fallas := v_fallas || format('B7V · con un envío viejo, corregir la compra a 110: esperaba real=110.00 sin=110.00 con=110.00 (como hoy) y dio %s', v_t);
    END IF;
  END;

  -- ================================================================= C1 ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'C1', 0, NULL);
    v_flete jsonb;
  BEGIN
    v_flete := jsonb_build_array(jsonb_build_object('concepto', 'Flete', 'monto', 100, 'condicion_iva', 'no_gravado',
                 'en_factura', false, 'prorratea_al_costo', true, 'base_prorrateo', 'unidades',
                 'pesos', jsonb_build_object('0', 10)));
    PERFORM pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
              jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21,
                                 'condicion_iva', 'gravado'))), 'FC', v_hoy, 210, 1210, v_flete, 'A');
    v_t := (SELECT format('real=%s con_iva=%s', round(costo_real, 2), round(costo_con_iva, 2)) FROM productos WHERE id = v_p);
    IF v_t IS DISTINCT FROM 'real=110.00 con_iva=131.00' THEN
      v_fallas := v_fallas || format('C1 · FC A con un flete de 100: esperaba real=110.00 con_iva=131.00 (100 + 10 de flete + 21 de IVA del producto; el flete no lleva IVA) y dio %s', v_t);
    END IF;
  END;

  -- ================================================================= C3 ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'C3', 0, NULL);
  BEGIN
    v_j := pg_temp.alta(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'FC', v_hoy, 210, 1210,
             '[]'::jsonb, 'B');
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('C3 · una FC B con IVA 210 debía rechazarse y dio %s (COMPRA-A1 en %s)', v_j, pg_temp.a1());
    END IF;
  END;

  -- ================================================================= C5 ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'C5', 0, NULL);
    v_c bigint; v_lote bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    BEGIN
      v_j := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 1, 'subtotal', 100)),
                        100, 0, repeat('9', 60));
      IF COALESCE((v_j->>'success')::boolean, true) OR position('hasta 50' in v_j->>'error') = 0 THEN
        v_fallas := v_fallas || format('C5 · un número de 60 caracteres debía rechazarse con su motivo y dio %s', v_j);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('C5 · NC por factura, error crudo: %s %s', SQLSTATE, SQLERRM);
    END;
    v_j := pg_temp.lotes_compra(v_adm, v_c, jsonb_build_array(jsonb_build_object(
             'producto_id', v_p, 'fecha_vencimiento', v_hoy + 20, 'cantidad', 10)));
    SELECT id INTO v_lote FROM producto_lotes WHERE compra_id = v_c;
    BEGIN
      PERFORM pg_temp.como(v_adm, 1);
      v_j := public.registrar_nota_credito_lote(v_lote, 1, repeat('9', 60), 'vencido');
      v_fallas := v_fallas || format('C5 · NC por lote con 60 caracteres debía rechazarse y dio %s', v_j);
    EXCEPTION WHEN OTHERS THEN
      IF position('hasta 50' in SQLERRM) = 0 THEN
        v_fallas := v_fallas || format('C5 · NC por lote, error crudo: %s %s', SQLSTATE, SQLERRM);
      END IF;
    END;
  END;

  -- ================================================================ K12 ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'K12', 0, NULL);
    v_c bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 100, 'costo_unitario', 10))), 'ZZ', v_hoy, 0, 1000);
    v_j := pg_temp.lotes_compra(v_adm, v_c, jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 60),
             jsonb_build_object('producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 40)));
    v_j := pg_temp.editar(v_adm, v_c, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 1, 'costo_unitario', 10))), 0, 10);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'K12 · la edición no entró: %', v_j;
    END IF;
    v_t := pg_temp.estado(v_p);
    IF v_t IS DISTINCT FROM 'stock=1 lotes=1/1 bolsa=0 cpp=10.0000' THEN
      v_fallas := v_fallas || format('K12 · la compra de 100 con lotes 60 y 40 corregida a 1: esperaba stock=1 lotes=1/1 bolsa=0 y dio %s', v_t);
    END IF;
  END;

  -- ================================================================ K14 ====
  DECLARE
    v_p  bigint := pg_temp.producto(1, 'K14', 0, NULL);
    v_c1 bigint; v_c2 bigint; v_c3 bigint; v_r text := '';
    v_lin jsonb;
  BEGIN
    v_lin := pg_temp.lineas(jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 5, 'costo_unitario', 10)));
    -- con una NC vigente
    v_c1 := pg_temp.compra(v_adm, v_lin, 'ZZ', v_hoy, 0, 50);
    v_j := pg_temp.nc(v_adm, v_c1, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 1, 'subtotal', 10)), 10, 0);
    BEGIN
      v_j := pg_temp.lotes_compra(v_adm, v_c1, jsonb_build_array(jsonb_build_object(
               'producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 4)));
      v_r := v_r || 'nc:pasa ';
    EXCEPTION WHEN OTHERS THEN v_r := v_r || 'nc:no ';
    END;
    -- al límite de la edición (7 días y medio): pasa (H9)
    v_c2 := pg_temp.compra(v_adm, v_lin, 'ZZ', v_hoy, 0, 50);
    UPDATE compras SET created_at = now() - interval '7 days 12 hours' WHERE id = v_c2;
    BEGIN
      v_j := pg_temp.lotes_compra(v_adm, v_c2, jsonb_build_array(jsonb_build_object(
               'producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 5)));
      v_r := v_r || 'limite:pasa ';
    EXCEPTION WHEN OTHERS THEN v_r := v_r || 'limite:no ';
    END;
    -- de más de 8 días
    v_c2 := pg_temp.compra(v_adm, v_lin, 'ZZ', v_hoy, 0, 50);
    UPDATE compras SET created_at = now() - interval '9 days' WHERE id = v_c2;
    BEGIN
      v_j := pg_temp.lotes_compra(v_adm, v_c2, jsonb_build_array(jsonb_build_object(
               'producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 5)));
      v_r := v_r || 'vieja:pasa ';
    EXCEPTION WHEN OTHERS THEN v_r := v_r || 'vieja:no ';
    END;
    -- el encargado: la primera carga sí, cambiarla no
    v_c3 := pg_temp.compra(v_adm, v_lin, 'ZZ', v_hoy, 0, 50);
    BEGIN
      v_j := pg_temp.lotes_compra(v_enc, v_c3, jsonb_build_array(jsonb_build_object(
               'producto_id', v_p, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 5)));
      v_r := v_r || 'enc1:pasa ';
    EXCEPTION WHEN OTHERS THEN v_r := v_r || 'enc1:no(' || SQLERRM || ') ';
    END;
    BEGIN
      v_j := pg_temp.lotes_compra(v_enc, v_c3, jsonb_build_array(jsonb_build_object(
               'producto_id', v_p, 'fecha_vencimiento', v_hoy + 40, 'cantidad', 5)));
      v_r := v_r || 'enc2:pasa';
    EXCEPTION WHEN OTHERS THEN v_r := v_r || 'enc2:no';
    END;
    IF v_r IS DISTINCT FROM 'nc:no limite:pasa vieja:no enc1:pasa enc2:no' THEN
      v_fallas := v_fallas || format('K14 · sincronizar_lotes_compra: esperaba nc:no limite:pasa vieja:no enc1:pasa enc2:no y dio %s', v_r);
    END IF;
  END;

  -- ================================================================ H11 ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'H11', 0, NULL);
    v_c bigint; v_dev bigint; v_aj bigint; v_r text;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_dev := (pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 2, 'subtotal', 200)), 200, 0)
              ->>'nota_credito_id')::bigint;
    v_aj := (pg_temp.ajuste(v_adm, v_c, 100, 0)->>'nota_credito_id')::bigint;
    -- como las de prod: la devolución del 02/10 y el ajuste del 01/04
    UPDATE notas_credito SET created_at = timestamptz '2026-10-02 15:00:00+00' WHERE id = v_dev;
    UPDATE notas_credito SET created_at = timestamptz '2026-04-01 15:00:00+00' WHERE id = v_aj;
    BEGIN
      v_j := pg_temp.anular(v_adm, v_dev, 'prueba');
      v_r := format('dev:%s', v_j->>'success');
      IF COALESCE((v_j->>'success')::boolean, true) OR position('anterior al 10/11/2026' in COALESCE(v_j->>'error', '')) = 0 THEN
        v_fallas := v_fallas || format('H11 · una devolución anterior a la 483 debía rechazarse con su motivo y dio %s', v_j);
      END IF;
      v_j := pg_temp.anular(v_adm, v_aj, 'prueba');
      IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('H11 · un ajuste viejo debía anularse y dio %s', v_j);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('H11 · %s %s', SQLSTATE, SQLERRM);
    END;
  END;

  -- ================================================================ P10 ====
  BEGIN
    INSERT INTO proveedores (nombre, cuit, sucursal_id) VALUES ('B2 prov uno', '20-11111111-2', 1);
    INSERT INTO proveedores (nombre, cuit, sucursal_id) VALUES ('B2 prov otra suc', '20111111112', 2);
    BEGIN
      INSERT INTO proveedores (nombre, cuit, sucursal_id) VALUES ('B2 prov dos', '20111111112', 1);
      v_fallas := v_fallas || 'P10 · un segundo proveedor con el mismo CUIT sin guiones en la sucursal 1 entró'::text;
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
  EXCEPTION WHEN unique_violation THEN
    v_fallas := v_fallas || 'P10 · el mismo CUIT en otra sucursal no entró'::text;
  END;

  -- ================================================================= S1 ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'S1', 0, NULL);
    v_c bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 5, 'costo_unitario', 10))), 'ZZ', v_hoy, 0, 50);
    -- Una base local sin la columna del ban de Auth (la escribe el trigger que sincroniza el
    -- acceso): ahí el trigger se apaga para esta fila, y vuelve con el resto del ensayo.
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'banned_until') THEN
      EXECUTE (SELECT format('ALTER TABLE public.perfiles DISABLE TRIGGER %I', t.tgname)
                 FROM pg_trigger t WHERE t.tgrelid = 'public.perfiles'::regclass
                  AND t.tgfoid = 'public.perfiles_sync_acceso_auth'::regproc);
    END IF;
    UPDATE perfiles SET activo = false WHERE id = v_adm2;
    v_j := pg_temp.editar(v_adm2, v_c, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 4, 'costo_unitario', 10))), 0, 40);
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('S1 · un admin desactivado editó una compra: %s', v_j);
    END IF;
  END;

  -- ================================================================= SN ====
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'productos_stock_no_negativo'
                                              AND conrelid = 'public.productos'::regclass) THEN
    v_fallas := v_fallas || 'SN · falta el CHECK productos_stock_no_negativo'::text;
  END IF;

  RAISE EXCEPTION USING ERRCODE = 'ZZ001';
 EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas:\n  %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, E'\n  '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format(E'ENSAYO OK (todo revertido) · A AJ B B4W B4R B4 B5 B7 B8 S16 B7V C1 C3 C5 K12 K14 H11 P10 S1 SN\nnotas:\n  %s',
    array_to_string(v_notas, E'\n  '));
END
$ensayo$;
