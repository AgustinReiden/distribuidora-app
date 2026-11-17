-- Ensayo de la tarjeta B18 de la ola 2 del plan #1603: una nota de crédito de COMPRA anulada
-- (`anular_nota_credito_compra`, mig 523) deja de contar en todo lo que suma notas, y deja de
-- bloquear la compra. Migración: NNN_nc_compra_anulada_lectores.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la
-- migración fallan PF, RG, RGA, BOT, ED, AN, CP y TR; REG (regresión) pasa igual.
--
--   PF  · posicion_fiscal: una FC A de 10 × 100 al 21 % y una devolución de 4 (IVA 84) más un
--         ajuste con IVA 10,50 e II 5. Anuladas las dos, el IVA y el II de las notas de compra
--         vuelven a lo de antes de cargarlas (antes de la migración seguían restando).
--   RG  · reporte_gerencial: la devolución anulada deja de restar de «Compras del período»
--         (kpis.compras_notas_credito y kpis.compras), también en mensual[].
--   RGA · reporte_gerencial: el ajuste anulado deja de sumar a «Descuentos de proveedores»
--         (kpis.descuentos_proveedores y mensual[].descuentos_proveedores).
--   BOT · bot_compras_periodo: la nota anulada deja de restar de compras_notas_credito.
--   ED  · H13 · una compra ZZ de 10 × 100 con una devolución de 4 anulada se edita a 8
--         (actualizar_compra_items): stock y promedio quedan como si la nota no hubiera existido.
--   AN  · H13 · una compra con una devolución anulada se anula (anular_compra_atomica): el stock
--         vuelve al de antes de la compra y sus lotes se borran.
--   CP  · H13 · una compra con un ajuste anulado cambia de proveedor (cambiar_proveedor_compra:
--         clona y cancela la original, por el trigger compras_proteger_cancelacion).
--   TR  · H13 · el trigger compras_proteger_cancelacion deja cancelar por UPDATE directo una
--         compra cuya única nota está anulada.
--   REG · Regresión: con una nota VIGENTE las cuatro siguen rechazando, y la nota vigente sigue
--         restando en posicion_fiscal, reporte_gerencial y el bot.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-nc-compra-anulada-ola2-1603.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_mes    text := to_char(public._tablero_hoy(), 'YYYY-MM');
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
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b18-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'B18 ' || p_rol), now(), now());
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
    VALUES ('B18 ' || p_nombre || ' ' || gen_random_uuid(), 1000, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, p_suc) RETURNING id;
  $f$;
  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(x || jsonb_build_object('subtotal',
             round((x->>'cantidad')::numeric * (x->>'costo_unitario')::numeric * (1 - (x->>'bonificacion')::numeric / 100), 2))
             ORDER BY o)
      FROM (SELECT jsonb_build_object('bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0) || e AS x, o
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)) s;
  $f$;
  CREATE FUNCTION pg_temp.compra(p_adm uuid, p_lin jsonb, p_tipo text, p_fecha date, p_iva numeric, p_total numeric,
                                 p_letra text DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    v := public.registrar_compra_completa(
      NULL, 'B18', 'B18-' || left(gen_random_uuid()::text, 8), p_fecha,
      (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), p_iva, 0, p_total,
      'efectivo', 'b18', p_adm, p_lin, p_tipo, p_cargos => '[]'::jsonb, p_bonificaciones => 0,
      p_letra_comprobante => p_letra);
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
  -- Una NC de devolución: p_items [{producto_id, cantidad, subtotal}]. La nota, o una excepción.
  CREATE FUNCTION pg_temp.nc(p_adm uuid, p_c bigint, p_items jsonb, p_sub numeric, p_iva numeric) RETURNS bigint
  LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    v := public.registrar_nota_credito(p_c, 'B18-' || left(gen_random_uuid()::text, 8), 'devolución b18',
                                       p_sub, p_iva, p_sub + p_iva, p_adm, p_items, NULL);
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la NC no entró: %', v;
    END IF;
    RETURN (v->>'nota_credito_id')::bigint;
  END $f$;
  CREATE FUNCTION pg_temp.ajuste(p_adm uuid, p_c bigint, p_sub numeric, p_iva numeric, p_ii numeric) RETURNS bigint
  LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    v := public.registrar_nota_credito(p_c, 'B18-' || left(gen_random_uuid()::text, 8), 'ajuste b18',
                                       p_sub, p_iva, p_sub + p_iva + p_ii, p_adm, '[]'::jsonb, p_ii);
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'el ajuste no entró: %', v;
    END IF;
    RETURN (v->>'nota_credito_id')::bigint;
  END $f$;
  CREATE FUNCTION pg_temp.anular(p_uid uuid, p_nota bigint) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid, 1);
    v := public.anular_nota_credito_compra(p_nota, 'ensayo b18');
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la anulación no entró: %', v;
    END IF;
  END $f$;
  -- Lo que dicen los tres lectores de la sucursal 1 para hoy, como el servidor (sin sesión).
  CREATE FUNCTION pg_temp.pf() RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    v := public.posicion_fiscal(1, public._tablero_hoy(), public._tablero_hoy())->'compras';
    RETURN jsonb_build_object('iva_nc', v->'iva_notas_credito', 'ii_nc', v->'ii_notas_credito',
                              'iva_credito', v->'iva_credito', 'ii_compras', v->'ii_compras');
  END $f$;
  CREATE FUNCTION pg_temp.rg() RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb; m jsonb;
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    v := public.reporte_gerencial(1, public._tablero_hoy(), public._tablero_hoy());
    SELECT e INTO m FROM jsonb_array_elements(v->'mensual') e WHERE e->>'mes' = to_char(public._tablero_hoy(), 'YYYY-MM');
    RETURN jsonb_build_object('nc', v->'kpis'->'compras_notas_credito', 'compras', v->'kpis'->'compras',
                              'desc', v->'kpis'->'descuentos_proveedores',
                              'm_nc', m->'compras_notas_credito', 'm_compras', m->'compras',
                              'm_desc', m->'descuentos_proveedores');
  END $f$;
  CREATE FUNCTION pg_temp.bot() RETURNS numeric LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    RETURN (public.bot_compras_periodo(public._tablero_hoy(), public._tablero_hoy(), 1)->>'compras_notas_credito')::numeric;
  END $f$;
  CREATE FUNCTION pg_temp.estado(p bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('stock=%s lotes=%s cpp=%s',
                  pr.stock,
                  COALESCE((SELECT string_agg(l.cantidad_restante || '/' || l.cantidad, ',' ORDER BY l.fecha_vencimiento, l.id)
                              FROM public.producto_lotes l WHERE l.producto_id = p), '-'),
                  round(pr.costo_promedio, 4))
      FROM public.productos pr WHERE pr.id = p;
  $f$;

  -- ---------------------------------------------------------------- datos ---
  v_adm := pg_temp.u('admin', 1);

  -- ============================================================ PF RG BOT ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'PF', 0, NULL);
    v_c bigint; v_n bigint; v_a bigint;
    v_pf0 jsonb; v_pf1 jsonb; v_pf2 jsonb; v_rg0 jsonb; v_rg1 jsonb; v_rg2 jsonb;
    v_b0 numeric; v_b1 numeric; v_b2 numeric;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21,
                                'condicion_iva', 'gravado'))), 'FC', v_hoy, 210, 1210, 'A');
    v_pf0 := pg_temp.pf(); v_rg0 := pg_temp.rg(); v_b0 := pg_temp.bot();

    v_n := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 4, 'subtotal', 400)), 400, 84);
    v_a := pg_temp.ajuste(v_adm, v_c, 50, 10.5, 5);
    v_pf1 := pg_temp.pf(); v_rg1 := pg_temp.rg(); v_b1 := pg_temp.bot();
    -- Las dos vigentes cuentan (REG): 84 + 10,50 de IVA y 5 de II; 484 + 65,50 de notas; 55 de descuento.
    IF (v_pf1->>'iva_nc')::numeric - (v_pf0->>'iva_nc')::numeric <> 94.5
       OR (v_pf1->>'ii_nc')::numeric - (v_pf0->>'ii_nc')::numeric <> 5 THEN
      v_fallas := v_fallas || format('REG · posicion_fiscal con las dos notas vigentes: esperaba +94.5 de IVA y +5 de II; antes %s, después %s', v_pf0, v_pf1);
    END IF;
    IF (v_rg1->>'nc')::numeric - (v_rg0->>'nc')::numeric <> 549.5
       OR (v_rg1->>'m_nc')::numeric - (v_rg0->>'m_nc')::numeric <> 549.5
       OR (v_rg1->>'desc')::numeric - (v_rg0->>'desc')::numeric <> 55 THEN
      v_fallas := v_fallas || format('REG · reporte_gerencial con las dos notas vigentes: esperaba +549.5 de notas y +55 de descuentos; antes %s, después %s', v_rg0, v_rg1);
    END IF;
    IF v_b1 - v_b0 <> 549.5 THEN
      v_fallas := v_fallas || format('REG · bot_compras_periodo con las dos notas vigentes: esperaba +549.5 y dio %s → %s', v_b0, v_b1);
    END IF;

    PERFORM pg_temp.anular(v_adm, v_n);
    PERFORM pg_temp.anular(v_adm, v_a);
    v_pf2 := pg_temp.pf(); v_rg2 := pg_temp.rg(); v_b2 := pg_temp.bot();

    IF v_pf2 IS DISTINCT FROM v_pf0 THEN
      v_fallas := v_fallas || format('PF · posicion_fiscal con las dos notas anuladas tenía que volver a %s y dio %s', v_pf0, v_pf2);
    END IF;
    IF (v_rg2->>'nc') IS DISTINCT FROM (v_rg0->>'nc') OR (v_rg2->>'compras') IS DISTINCT FROM (v_rg0->>'compras')
       OR (v_rg2->>'m_nc') IS DISTINCT FROM (v_rg0->>'m_nc') OR (v_rg2->>'m_compras') IS DISTINCT FROM (v_rg0->>'m_compras') THEN
      v_fallas := v_fallas || format('RG · «Compras del período» con las notas anuladas tenía que volver a %s y dio %s', v_rg0, v_rg2);
    END IF;
    IF (v_rg2->>'desc') IS DISTINCT FROM (v_rg0->>'desc') OR (v_rg2->>'m_desc') IS DISTINCT FROM (v_rg0->>'m_desc') THEN
      v_fallas := v_fallas || format('RGA · «Descuentos de proveedores» con el ajuste anulado tenía que volver a %s/%s y dio %s/%s',
                                     v_rg0->>'desc', v_rg0->>'m_desc', v_rg2->>'desc', v_rg2->>'m_desc');
    END IF;
    IF v_b2 IS DISTINCT FROM v_b0 THEN
      v_fallas := v_fallas || format('BOT · bot_compras_periodo con las notas anuladas tenía que volver a %s y dio %s', v_b0, v_b2);
    END IF;
    v_notas := v_notas || format('PF/RG/BOT · antes %s %s %s · vigentes %s %s %s · anuladas %s %s %s',
                                 v_pf0, v_rg0, v_b0, v_pf1, v_rg1, v_b1, v_pf2, v_rg2, v_b2);
  END;

  -- ================================================================== ED ====
  -- 10 u. a 80 en la bolsa, ZZ de 10 × 100 con su lote: promedio 90. Devolución de 4 y su
  -- anulación. Editar la compra a 8 deja stock 18 y promedio (10 × 80 + 8 × 100) / 18 = 88,8889,
  -- lo mismo que editar una compra que nunca tuvo nota (la referencia, sobre otro producto).
  DECLARE
    v_p bigint := pg_temp.producto(1, 'ED', 10, 80);
    v_r bigint := pg_temp.producto(1, 'EDref', 10, 80);
    v_c bigint; v_cr bigint; v_n bigint; v_e text; v_er text;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_cr := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_r, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_n := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 4, 'subtotal', 400)), 400, 0);

    -- REG: con la nota vigente no se edita.
    v_j := pg_temp.editar(v_adm, v_c, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 8, 'costo_unitario', 100))), 0, 800);
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('REG · editar una compra con una nota vigente debía rechazarse y dio %s', v_j);
    END IF;

    PERFORM pg_temp.anular(v_adm, v_n);
    v_j := pg_temp.editar(v_adm, v_c, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 8, 'costo_unitario', 100))), 0, 800);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('ED · editar una compra cuya nota está anulada debía entrar y dio %s', v_j);
    ELSE
      v_j := pg_temp.editar(v_adm, v_cr, pg_temp.lineas(jsonb_build_array(
               jsonb_build_object('producto_id', v_r, 'cantidad', 8, 'costo_unitario', 100))), 0, 800);
      v_e := pg_temp.estado(v_p);
      v_er := pg_temp.estado(v_r);
      IF v_e IS DISTINCT FROM 'stock=18 lotes=- cpp=88.8889' OR v_e IS DISTINCT FROM v_er THEN
        v_fallas := v_fallas || format('ED · la compra editada a 8 tenía que quedar como la de referencia (%s) y quedó %s', v_er, v_e);
      END IF;
    END IF;
  END;

  -- ================================================================== AN ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'AN', 10, 80);
    v_c bigint; v_n bigint; v_e text;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.sincronizar_lotes_compra(v_c, jsonb_build_array(jsonb_build_object(
             'producto_id', v_p, 'fecha_vencimiento', v_hoy + 90, 'cantidad', 10)));
    v_n := pg_temp.nc(v_adm, v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 4, 'subtotal', 400)), 400, 0);

    -- REG: con la nota vigente no se anula.
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.anular_compra_atomica(v_c, v_adm);
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('REG · anular una compra con una nota vigente debía rechazarse y dio %s', v_j);
    END IF;

    PERFORM pg_temp.anular(v_adm, v_n);
    PERFORM pg_temp.como(v_adm, 1);
    BEGIN
      v_j := public.anular_compra_atomica(v_c, v_adm);
    EXCEPTION WHEN OTHERS THEN
      v_j := jsonb_build_object('success', false, 'error', SQLERRM);
    END;
    v_e := pg_temp.estado(v_p);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('AN · anular una compra cuya nota está anulada debía entrar y dio %s', v_j);
    ELSIF v_e IS DISTINCT FROM 'stock=10 lotes=- cpp=80.0000' THEN
      v_fallas := v_fallas || format('AN · anulada la compra esperaba stock=10 lotes=- cpp=80.0000 y quedó %s', v_e);
    END IF;
  END;

  -- ================================================================== CP ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'CP', 0, NULL);
    v_c bigint; v_a bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_a := pg_temp.ajuste(v_adm, v_c, 100, 0, 0);

    -- REG: con el ajuste vigente no se cambia el proveedor.
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.cambiar_proveedor_compra(v_c, v_adm, NULL, 'Otro B18');
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('REG · cambiar el proveedor de una compra con una nota vigente debía rechazarse y dio %s', v_j);
    END IF;

    PERFORM pg_temp.anular(v_adm, v_a);
    PERFORM pg_temp.como(v_adm, 1);
    BEGIN
      v_j := public.cambiar_proveedor_compra(v_c, v_adm, NULL, 'Otro B18');
    EXCEPTION WHEN OTHERS THEN
      v_j := jsonb_build_object('success', false, 'error', SQLERRM);
    END;
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('CP · cambiar el proveedor de una compra cuyo ajuste está anulado debía entrar y dio %s', v_j);
    ELSIF (SELECT estado FROM compras WHERE id = v_c) IS DISTINCT FROM 'cancelada'
       OR (SELECT stock FROM productos WHERE id = v_p) IS DISTINCT FROM 10 THEN
      v_fallas := v_fallas || format('CP · la original tenía que quedar cancelada y el stock en 10: %s, stock %s',
                                     (SELECT estado FROM compras WHERE id = v_c), (SELECT stock FROM productos WHERE id = v_p));
    END IF;
  END;

  -- ================================================================== TR ====
  DECLARE
    v_p bigint := pg_temp.producto(1, 'TR', 0, NULL);
    v_c bigint; v_a bigint; v_c2 bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_c2 := pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100))), 'ZZ', v_hoy, 0, 1000);
    v_a := pg_temp.ajuste(v_adm, v_c, 100, 0, 0);
    PERFORM pg_temp.ajuste(v_adm, v_c2, 100, 0, 0);
    PERFORM pg_temp.anular(v_adm, v_a);
    PERFORM pg_temp.como(NULL, NULL);
    BEGIN
      UPDATE compras SET estado = 'cancelada' WHERE id = v_c;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('TR · cancelar por UPDATE una compra cuya única nota está anulada debía entrar y dio: %s', SQLERRM);
    END;
    -- REG: con la nota vigente el trigger sigue rechazando.
    BEGIN
      UPDATE compras SET estado = 'cancelada' WHERE id = v_c2;
      v_fallas := v_fallas || 'REG · el trigger dejó cancelar una compra con una nota vigente'::text;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END;

  RAISE EXCEPTION USING ERRCODE = 'ZZ001';
 EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas:\n  %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, E'\n  '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format(E'ENSAYO OK (todo revertido) · PF RG RGA BOT ED AN CP TR REG\nnotas:\n  %s',
    array_to_string(v_notas, E'\n  '));
END
$ensayo$;
