-- Ensayo de la tarjeta C3 de la tanda 5 de la ola 2 del plan #1603: la edición de una compra
-- sincroniza sus lotes en la misma transacción (STK-13, #1542) y la nota de crédito de una FC
-- con un descuento NO gravado en factura no acredita de más (1590-b, H5 de la revisión de B2,
-- #1590). Migración: NNN_compras_edicion_con_lotes_y_nc_no_gravado.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la
-- migración fallan E1, E2, E4, H5 (con N1), C2 a C10, C12, C13, N2, H6, H10 y RC; E3, HG, HZ,
-- C1, C11, RP, ED, N3, N4 y N5 son regresiones (dan igual antes y después). También 1593-b1,
-- el no gravado negativo (#1590) y los hallazgos de la revisión adversarial (H1, H5, H6, H10).
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
--   H5  · 1590-b · FC A con P1 gravado (10 × 100 al 21 %) y P2 no gravado (10 × 20), y un
--         descuento no gravado de −150 en factura (no gravado −150, total 1.260): devolver todo
--         acredita 1.085 de P1 (875 + los 210 de IVA, que el descuento no gravado no bajó) y 175 de
--         P2: 1.260, lo pagado. Sin la migración la compra no se puede cargar.
--   H5P · lo mismo devolviendo 5 u. de P1: 542,50 (437,50 + 105).
--   H5L · lo mismo por lote (Vencimientos): las 10 u. de P1 acreditan 1.085.
--   HG  · FC A de 10 × 100 al 21 % con una bonificación de cabecera gravada de −100 (total
--         1.089): devolver todo acredita 1.089 (900 + 189), como antes (regresión).
--   HZ  · ZZ de 10 × 100 con un descuento en factura de −150 (total 850): 850 (regresión).
--
--   C*  · 1593-b1 (decisión del dueño del 19/11): el costo con IVA es el costo neto (neto del
--         producto + impuestos internos + cargos y flete netos: costo_real) más el IVA de cada
--         componente. FC A de 10 × 100 al 21 % salvo donde se dice; «antes» es lo de hoy.
--           caso                                                  costo_real  con IVA (antes)
--           C1  sin cargos                                          100,00    121,00 (121,00)
--           C2  II del 10 % con 80 declarados (8 por unidad)        108,00    129,00 (131,00)
--           C3  flete fuera de factura de 100, sin IVA              110,00    131,00 (121,00)
--           C4  flete de 100 de un tercero con su IVA de 21         110,00    133,10 (121,00)
--           C4B flete gravado fuera de factura sin IVA cargado      110,00    131,00 (121,00)
--           C5  cargo gravado en factura de +100                    110,00    133,10 (121,00)
--           C6  cargo no gravado en factura de +100                 110,00    131,00 (121,00)
--           C7  bonificación gravada en factura de −100              90,00    108,90 (121,00)
--           C8  II de 8 por unidad y flete de 100 sin IVA           118,00    139,00 (131,00)
--           C8T lo mismo con el flete de un tercero con IVA de 21   118,00    141,10 (131,00)
--           C9  ZZ con flete de 300 en factura                      130,00    130,00 (100,00)
--           C10 producto exento con cargo gravado en factura de 100 110,00    110,00 (100,00)
--           C11 FC B de 10 × 121 (lo pagado)                        121,00    121,00 (121,00)
--           C12 ZZ con flete de un tercero de 100 + IVA 21          110,00    112,10 (100,00)
--           C13 FC B de 10 × 121 con el mismo flete                 131,00    133,10 (121,00)
--         (C12 y C13: H1 de la revisión. Sin crédito, lo pagado ya trae el IVA del producto, pero
--         no el del flete de un tercero.)
--         Y el costo real y el promedio no cambian en ninguno (CR). La reposición recalculada
--         desde la compra (_reposicion_desde_ultima_compra) da lo mismo que el alta (RP, sobre
--         C8T), y editar la compra sin cambios también (ED, sobre C4).
--   N*  · Un descuento sobre renglones exentos o no gravados va a la cabecera «No gravado» con
--         su signo (antes se rechazaba: «importe de la cabecera negativo»), con tope.
--           N1  la compra de H5 entra, con no gravado −150 y total 1.260, y cierra COMPRA-A1.
--           N2  FC A con P1 gravado 10 × 100 y P2 exento 10 × 50, y −50 exento en factura sólo
--               sobre P2: no gravado −50, total 1.660; el costo de P2 queda en 45 (con IVA 45);
--               devolver todo P2 acredita 450 y P1 1.210 (suma 1.660).
--           N3  un no gravado de −200 con descuentos no gravados de −150: se rechaza.
--           N4  H5 de la revisión: −1.100 no gravado sobre renglones gravados (pagó 110): se
--               rechaza (antes entraba y devolver todo acreditaba 210).
--           N5  −300 no gravado con 200 de renglones no gravados: se rechaza con su motivo.
--   H6  · La ficha de un PWA viejo corrige el neto a 105 con el PATCH de siempre (costo con IVA
--         127,05, sin el flete): el server lo compone, 139,15. Un PATCH con sólo el costo con IVA
--         no lo cambia.
--   H6B · N4 de la segunda revisión: un producto sin compras (neto 100, costo con IVA 100) con el
--         neto corregido a 110 en la ficha queda en 133,10 (no conserva una diferencia sin compra).
--   H10 · Bajar una compra de 10 de la que salieron 8 a 5: «El stock de hoy de “…” no alcanza: no
--         se puede bajar la compra a menos de 8.» (antes, el mensaje crudo del CHECK); a 8 entra.
--   RC2 · El recálculo (_recalcular_costo_con_iva) sobre productos con el costo con IVA viejo: los
--         que quedan afuera de la regla conservan el «Costo total» de la ficha de antes (N1): envío
--         posterior (133), nacido por envío (133), costo real a mano (136), alícuota cambiada en la
--         ficha (120,50), renglón de otra época (131). Entran en la regla con un centavo de
--         tolerancia (N2: 9,06) y con la alícuota del producto para el IVA del cargo (N3: 133,10).
--         Otra corrida no cambia nada.
--   L*  · Tercera revisión: la segunda pasada no toca lo que ya está en la regla (L1: P06 queda en
--         131, Q1 en 121); sobre todo, el recálculo corre una sola vez (L3); un exento sin alícuota
--         se costea al 0 % al corregir el neto (L2: 120, no 122,10); y un producto sin compras al
--         que el recálculo le sumó cargos los conserva (L4: 131 y, con el neto a 110, 143,10).
--   RC  · La tabla del recálculo existe y es sólo de server.
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
  -- Un alta con todo lo de la cabecera. Devuelve la respuesta de la RPC.
  CREATE FUNCTION pg_temp.alta(p_adm uuid, p_lin jsonb, p_tipo text, p_iva numeric, p_total numeric,
                               p_cargos jsonb, p_letra text, p_bonif numeric, p_ii numeric, p_ii_decl jsonb,
                               p_no_gravado numeric)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    RETURN public.registrar_compra_completa(
      NULL, 'C3', 'C3-' || left(gen_random_uuid()::text, 8), public._tablero_hoy(),
      (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), p_iva, 0, p_total,
      'efectivo', 'c3', p_adm, p_lin, p_tipo, p_impuestos_internos => p_ii, p_no_gravado => p_no_gravado,
      p_cargos => p_cargos, p_ii_declarado => p_ii_decl, p_bonificaciones => p_bonif, p_letra_comprobante => p_letra);
  END $f$;
  -- Un cargo: monto, condición, en factura, y (si es de un tercero) su IVA. Prorratea por
  -- unidades sobre el renglón 0 (o sobre los pesos que se digan).
  CREATE FUNCTION pg_temp.cargo(p_monto numeric, p_cond text, p_en_factura boolean, p_iva_tercero numeric DEFAULT NULL,
                                p_pesos jsonb DEFAULT '{"0": 1}'::jsonb)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('concepto', 'Cargo c3', 'monto', p_monto, 'condicion_iva', p_cond,
             'en_factura', p_en_factura, 'prorratea_al_costo', true, 'base_prorrateo', 'unidades', 'pesos', p_pesos)
           || CASE WHEN p_iva_tercero IS NULL THEN '{}'::jsonb
                   ELSE jsonb_build_object('comprobante_tercero', true, 'iva_monto', p_iva_tercero) END;
  $f$;
  CREATE FUNCTION pg_temp.costos(p bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('real=%s con=%s cpp=%s', round(costo_real, 2), costo_con_iva, round(costo_promedio, 2))
      FROM public.productos WHERE id = p;
  $f$;
  -- COMPRA-A1 de una compra: el total contra la suma de su cabecera (en una ZZ, más sus cargos en factura).
  CREATE FUNCTION pg_temp.a1(p_c bigint) RETURNS boolean LANGUAGE sql AS $f$
    SELECT abs(c.total - CASE WHEN c.tipo_factura = 'ZZ'
                              THEN c.subtotal + c.otros_impuestos
                                   + COALESCE((SELECT sum(cc.monto) FROM public.compra_cargos cc
                                                WHERE cc.compra_id = c.id AND cc.en_factura), 0)
                              ELSE c.subtotal + c.bonificaciones + c.iva + c.impuestos_internos + c.percepcion_iva
                                   + c.percepcion_iibb + c.no_gravado + c.otros_impuestos END) <= 1
      FROM public.compras c WHERE c.id = p_c;
  $f$;
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
  -- Una FC A con P1 gravado (10 × 100 al 21 %) y P2 no gravado (10 × 20), y un descuento no
  -- gravado de −150 en la factura, sin reparto: no gravado −150, total 1.260 (lo pagado).
  DECLARE
    v_lin jsonb;
    v_c bigint; v_q1 bigint; v_q2 bigint; v_lote bigint;
    v_t1 text; v_t2 text;
  BEGIN
    FOR i IN 1..3 LOOP
      v_q1 := pg_temp.producto('H5 gravado ' || i);
      v_q2 := pg_temp.producto('H5 no gravado ' || i);
      v_lin := pg_temp.lineas(jsonb_build_array(
                 jsonb_build_object('producto_id', v_q1, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21, 'condicion_iva', 'gravado'),
                 jsonb_build_object('producto_id', v_q2, 'cantidad', 10, 'costo_unitario', 20, 'porcentaje_iva', 0, 'condicion_iva', 'no_gravado')));
      v_j := pg_temp.alta(v_adm, v_lin, 'FC', 210, 1260,
               jsonb_build_array(pg_temp.cargo(-150, 'no_gravado', true, NULL, '{}'::jsonb)
                                 || jsonb_build_object('prorratea_al_costo', false)),
               'A', 0, 0, '{}'::jsonb, -150);
      IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('H5 · la FC con P2 no gravado y −150 no gravado no entró: %s', v_j->>'error');
        EXIT;
      END IF;
      v_c := (v_j->>'compra_id')::bigint;
      IF i = 1 THEN
        -- N1: entra y cierra COMPRA-A1.
        v_t := format('no_gravado=%s total=%s A1=%s', (SELECT no_gravado FROM compras WHERE id = v_c),
                      (SELECT total FROM compras WHERE id = v_c), pg_temp.a1(v_c));
        IF v_t IS DISTINCT FROM 'no_gravado=-150.00 total=1260.00 A1=t' THEN
          v_fallas := v_fallas || format('N1 · esperaba no_gravado=-150 total=1260 A1 cerrado y dio %s', v_t);
        END IF;
        -- H5: devolver todo acredita lo pagado (P1 875 + 210 de IVA, P2 175).
        v_j := pg_temp.nc(v_adm, v_c, v_q1, 10, 1000, 210);
        v_t1 := v_j->>'total';
        v_j := pg_temp.nc(v_adm, v_c, v_q2, 10, 200, 0);
        v_t2 := v_j->>'total';
        v_t := format('P1=%s P2=%s suma=%s', v_t1, v_t2, COALESCE(v_t1::numeric, 0) + COALESCE(v_t2::numeric, 0));
        IF v_t IS DISTINCT FROM 'P1=1085.00 P2=175.00 suma=1260.00' THEN
          v_fallas := v_fallas || format('H5 · devolver todo debía acreditar 1.085 + 175 = 1.260 (lo pagado) y dio %s', v_t);
        END IF;
        v_notas := v_notas || format('H5 · %s', v_t);
      ELSIF i = 2 THEN
        v_j := pg_temp.nc(v_adm, v_c, v_q1, 5, 500, 105);
        v_t := format('sub=%s iva=%s total=%s', v_j->>'subtotal', v_j->>'iva', v_j->>'total');
        IF v_t IS DISTINCT FROM 'sub=437.50 iva=105.00 total=542.50' THEN
          v_fallas := v_fallas || format('H5P · devolver 5 de P1: esperaba sub=437,50 iva=105 total=542,50 y dio %s', v_t);
        END IF;
      ELSE
        v_j := pg_temp.lotes_compra(v_adm, v_c, jsonb_build_array(
                 jsonb_build_object('producto_id', v_q1, 'fecha_vencimiento', v_hoy + 30, 'cantidad', 10)));
        SELECT id INTO v_lote FROM producto_lotes WHERE compra_id = v_c;
        PERFORM pg_temp.como(v_adm, 1);
        BEGIN
          v_j := public.registrar_nota_credito_lote(v_lote, 10, 'C3-L-' || left(gen_random_uuid()::text, 8), 'vencido c3');
          v_t := format('sub=%s iva=%s total=%s', v_j->>'subtotal', v_j->>'iva', v_j->>'total');
        EXCEPTION WHEN OTHERS THEN
          v_t := 'error ' || SQLERRM;
        END;
        IF v_t IS DISTINCT FROM 'sub=875.00 iva=210.00 total=1085.00' THEN
          v_fallas := v_fallas || format('H5L · la nota por lote de las 10 u. de P1: esperaba sub=875 iva=210 total=1.085 y dio %s', v_t);
        END IF;
      END IF;
    END LOOP;
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

  -- ================================================================== C* ====
  DECLARE
    r record;
    v_p bigint;
    v_c bigint;
    v_lin jsonb;
    v_c8t bigint; v_p8t bigint; v_c4 bigint; v_p4 bigint;
    v_antes text;
  BEGIN
    FOR r IN SELECT * FROM (VALUES
      -- caso, renglón (costo, IVA %, II %, condición), tipo, letra, IVA, total, cargos, bonif., II, II declarado, no gravado, esperado
      ('C1',  100::numeric, 21::numeric, 0::numeric, 'gravado', 'FC', 'A', 210::numeric, 1210::numeric, '[]'::jsonb, 0::numeric, 0::numeric, '{}'::jsonb, 0::numeric, 'real=100.00 con=121.00 cpp=100.00'),
      ('C2',  100, 21, 10, 'gravado', 'FC', 'A', 210, 1290, '[]'::jsonb, 0, 80, '{"10": 80}'::jsonb, 0, 'real=108.00 con=129.00 cpp=108.00'),
      ('C3',  100, 21, 0, 'gravado', 'FC', 'A', 210, 1210, jsonb_build_array(pg_temp.cargo(100, 'no_gravado', false)), 0, 0, '{}'::jsonb, 0, 'real=110.00 con=131.00 cpp=110.00'),
      ('C4',  100, 21, 0, 'gravado', 'FC', 'A', 210, 1210, jsonb_build_array(pg_temp.cargo(100, 'gravado', false, 21)), 0, 0, '{}'::jsonb, 0, 'real=110.00 con=133.10 cpp=110.00'),
      ('C4B', 100, 21, 0, 'gravado', 'FC', 'A', 210, 1210, jsonb_build_array(pg_temp.cargo(100, 'gravado', false)), 0, 0, '{}'::jsonb, 0, 'real=110.00 con=131.00 cpp=110.00'),
      ('C5',  100, 21, 0, 'gravado', 'FC', 'A', 231, 1331, jsonb_build_array(pg_temp.cargo(100, 'gravado', true)), 100, 0, '{}'::jsonb, 0, 'real=110.00 con=133.10 cpp=110.00'),
      ('C6',  100, 21, 0, 'gravado', 'FC', 'A', 210, 1310, jsonb_build_array(pg_temp.cargo(100, 'no_gravado', true)), 0, 0, '{}'::jsonb, 100, 'real=110.00 con=131.00 cpp=110.00'),
      ('C7',  100, 21, 0, 'gravado', 'FC', 'A', 189, 1089, jsonb_build_array(pg_temp.cargo(-100, 'gravado', true)), -100, 0, '{}'::jsonb, 0, 'real=90.00 con=108.90 cpp=90.00'),
      ('C8',  100, 21, 10, 'gravado', 'FC', 'A', 210, 1290, jsonb_build_array(pg_temp.cargo(100, 'no_gravado', false)), 0, 80, '{"10": 80}'::jsonb, 0, 'real=118.00 con=139.00 cpp=118.00'),
      ('C8T', 100, 21, 10, 'gravado', 'FC', 'A', 210, 1290, jsonb_build_array(pg_temp.cargo(100, 'gravado', false, 21)), 0, 80, '{"10": 80}'::jsonb, 0, 'real=118.00 con=141.10 cpp=118.00'),
      ('C9',  100, 0, 0, 'gravado', 'ZZ', NULL, 0, 1300, jsonb_build_array(pg_temp.cargo(300, 'no_gravado', true)), 0, 0, '{}'::jsonb, 0, 'real=130.00 con=130.00 cpp=130.00'),
      ('C10', 100, 0, 0, 'exento', 'FC', 'A', 0, 1100, jsonb_build_array(pg_temp.cargo(100, 'gravado', true)), 100, 0, '{}'::jsonb, 0, 'real=110.00 con=110.00 cpp=110.00'),
      ('C11', 121, 0, 0, 'gravado', 'FC', 'B', 0, 1210, '[]'::jsonb, 0, 0, '{}'::jsonb, 0, 'real=121.00 con=121.00 cpp=121.00'),
      ('C12', 100, 0, 0, 'gravado', 'ZZ', NULL, 0, 1000, jsonb_build_array(pg_temp.cargo(100, 'gravado', false, 21)), 0, 0, '{}'::jsonb, 0, 'real=110.00 con=112.10 cpp=110.00'),
      ('C13', 121, 0, 0, 'gravado', 'FC', 'B', 0, 1210, jsonb_build_array(pg_temp.cargo(100, 'gravado', false, 21)), 0, 0, '{}'::jsonb, 0, 'real=131.00 con=133.10 cpp=131.00')
    ) AS t(caso, costo, pct, ii, cond, tipo, letra, iva, total, cargos, bonif, ii_hdr, ii_decl, no_grav, esperado) LOOP
      v_p := pg_temp.producto(r.caso);
      v_lin := pg_temp.lineas(jsonb_build_array(jsonb_build_object(
                 'producto_id', v_p, 'cantidad', 10, 'costo_unitario', r.costo, 'porcentaje_iva', r.pct,
                 'condicion_iva', r.cond, 'impuestos_internos', r.ii)));
      v_j := pg_temp.alta(v_adm, v_lin, r.tipo, r.iva, r.total, r.cargos, r.letra, r.bonif, r.ii_hdr, r.ii_decl, r.no_grav);
      IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('%s · la compra no entró: %s', r.caso, v_j);
        CONTINUE;
      END IF;
      v_c := (v_j->>'compra_id')::bigint;
      v_t := pg_temp.costos(v_p);
      IF v_t IS DISTINCT FROM r.esperado THEN
        v_fallas := v_fallas || format('%s · esperaba %s y dio %s', r.caso, r.esperado, v_t);
      END IF;
      v_notas := v_notas || format('%s · %s', r.caso, v_t);
      IF r.caso = 'C8T' THEN v_c8t := v_c; v_p8t := v_p; END IF;
      IF r.caso = 'C4' THEN v_c4 := v_c; v_p4 := v_p; END IF;
    END LOOP;

    -- RP · la reposición recalculada desde la compra da lo mismo que el alta.
    IF v_p8t IS NOT NULL THEN
      v_antes := pg_temp.costos(v_p8t);
      UPDATE public.productos SET costo_con_iva = 1, costo_real = 1, costo_sin_iva = 1 WHERE id = v_p8t;
      PERFORM public._reposicion_desde_ultima_compra(v_p8t, 1);
      v_t := pg_temp.costos(v_p8t);
      IF v_t IS DISTINCT FROM v_antes THEN
        v_fallas := v_fallas || format('RP · la reposición recalculada dio %s y el alta %s', v_t, v_antes);
      END IF;
    END IF;

    -- ED · editar la compra del C4 sin cambios (con sus cargos) deja el mismo costo.
    IF v_c4 IS NOT NULL THEN
      v_antes := pg_temp.costos(v_p4);
      PERFORM pg_temp.como(v_adm, 1);
      v_j := public.actualizar_compra_items(v_c4,
               (SELECT jsonb_agg(jsonb_build_object('producto_id', ci.producto_id, 'cantidad', ci.cantidad,
                         'costo_unitario', ci.costo_unitario, 'subtotal', ci.subtotal, 'bonificacion', ci.bonificacion,
                         'porcentaje_iva', ci.porcentaje_iva, 'condicion_iva', ci.condicion_iva, 'impuestos_internos', ci.impuestos_internos))
                  FROM public.compra_items ci WHERE ci.compra_id = v_c4),
               1000, 210, 1210, v_adm,
               p_cargos => jsonb_build_array(pg_temp.cargo(100, 'gravado', false, 21)),
               p_ii_declarado => '{}'::jsonb,
               p_renglones_vistos => (SELECT array_agg(id) FROM public.compra_items WHERE compra_id = v_c4));
      v_t := pg_temp.costos(v_p4);
      IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_t IS DISTINCT FROM v_antes THEN
        v_fallas := v_fallas || format('ED · editar la compra sin cambios: esperaba %s y dio %s (%s)', v_antes, v_t, v_j);
      END IF;
    END IF;
  END;

  -- ================================================================== N* ====
  DECLARE
    v_q1 bigint := pg_temp.producto('N2 gravado');
    v_q2 bigint := pg_temp.producto('N2 exento');
    v_c bigint;
    v_tot numeric := 0;
    v_mixta jsonb;
  BEGIN
    -- N2 · −50 exento sólo sobre el renglón exento.
    v_j := pg_temp.alta(v_adm, pg_temp.lineas(jsonb_build_array(
             jsonb_build_object('producto_id', v_q1, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21, 'condicion_iva', 'gravado'),
             jsonb_build_object('producto_id', v_q2, 'cantidad', 10, 'costo_unitario', 50, 'porcentaje_iva', 0, 'condicion_iva', 'exento'))),
             'FC', 210, 1660, jsonb_build_array(pg_temp.cargo(-50, 'exento', true, NULL, '{"1": 1}'::jsonb)),
             'A', 0, 0, '{}'::jsonb, -50);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('N2 · la FC con −50 exento no entró: %s', v_j->>'error');
    ELSE
      v_c := (v_j->>'compra_id')::bigint;
      v_t := format('%s | A1=%s', pg_temp.costos(v_q2), pg_temp.a1(v_c));
      IF v_t IS DISTINCT FROM 'real=45.00 con=45.00 cpp=45.00 | A1=t' THEN
        v_fallas := v_fallas || format('N2 · esperaba el exento a 45 (con IVA 45) y A1 cerrado, y dio %s', v_t);
      END IF;
      v_j := pg_temp.nc(v_adm, v_c, v_q2, 10, 500, 0);
      v_tot := v_tot + COALESCE((v_j->>'total')::numeric, 0);
      v_t := v_j->>'total';
      v_j := pg_temp.nc(v_adm, v_c, v_q1, 10, 1000, 210);
      v_tot := v_tot + COALESCE((v_j->>'total')::numeric, 0);
      v_t := format('exento=%s gravado=%s suma=%s', v_t, v_j->>'total', v_tot);
      IF v_t IS DISTINCT FROM 'exento=450.00 gravado=1210.00 suma=1660.00' THEN
        v_fallas := v_fallas || format('N2 · devolver todo: esperaba 450 + 1.210 = 1.660 y dio %s', v_t);
      END IF;
    END IF;

    -- Una FC A con P1 gravado 10 × 100 y P2 no gravado 10 × 20 (para N3 y N5).
    v_mixta := pg_temp.lineas(jsonb_build_array(
                 jsonb_build_object('producto_id', pg_temp.producto('N3 gravado'), 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21, 'condicion_iva', 'gravado'),
                 jsonb_build_object('producto_id', pg_temp.producto('N3 no gravado'), 'cantidad', 10, 'costo_unitario', 20, 'porcentaje_iva', 0, 'condicion_iva', 'no_gravado')));

    -- N3 · el no gravado de la cabecera (−200) no baja más que los descuentos no gravados (−150).
    v_j := pg_temp.alta(v_adm, v_mixta, 'FC', 210, 1210,
             jsonb_build_array(pg_temp.cargo(-150, 'no_gravado', true, NULL, '{}'::jsonb) || jsonb_build_object('prorratea_al_costo', false)),
             'A', 0, 0, '{}'::jsonb, -200);
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('N3 · un no gravado de −200 con −150 de descuentos debía rechazarse y dio %s', v_j);
    END IF;

    -- N4 · H5 de la revisión: −1.100 no gravado en una FC A sólo con renglones gravados (pagó 110).
    v_j := pg_temp.alta(v_adm, pg_temp.renglon(pg_temp.producto('N4'), 10, 100, 21), 'FC', 210, 110,
             jsonb_build_array(pg_temp.cargo(-1100, 'no_gravado', true, NULL, '{}'::jsonb) || jsonb_build_object('prorratea_al_costo', false)),
             'A', 0, 0, '{}'::jsonb, -1100);
    IF COALESCE((v_j->>'success')::boolean, true) THEN
      v_fallas := v_fallas || format('N4 · un descuento no gravado sobre renglones gravados debía rechazarse y dio %s', v_j);
    END IF;

    -- N5 · −300 no gravado con sólo 200 de renglones no gravados: se rechaza con su motivo.
    v_j := pg_temp.alta(v_adm, v_mixta, 'FC', 210, 1110,
             jsonb_build_array(pg_temp.cargo(-300, 'no_gravado', true, NULL, '{}'::jsonb) || jsonb_build_object('prorratea_al_costo', false)),
             'A', 0, 0, '{}'::jsonb, -300);
    IF COALESCE((v_j->>'success')::boolean, true)
       OR COALESCE(v_j->>'error', '') NOT LIKE 'El descuento no gravado de la factura (300.00) es mayor que lo que suman sus renglones no gravados (200.00)%' THEN
      v_fallas := v_fallas || format('N5 · −300 no gravado contra 200 de renglones no gravados debía rechazarse con su motivo y dio %s', v_j);
    END IF;
  END;

  -- ================================================================= H6 ====
  -- La ficha de un PWA viejo corrige el neto de un producto cuya compra dejó el flete de un
  -- tercero en el costo con IVA (100 + 10 de flete + 2,10 de su IVA: 133,10): manda el PATCH
  -- REST de siempre, con costo_con_iva = 105 × 1,21 = 127,05 (sin el flete). El server lo compone:
  -- 105 × 1,21 + 12,10 = 139,15. Y un PATCH que sólo trae costo_con_iva no lo cambia.
  DECLARE
    v_p bigint := pg_temp.producto('H6');
    v_lin jsonb;
  BEGIN
    v_lin := pg_temp.renglon(v_p, 10, 100, 21);
    v_j := pg_temp.alta(v_adm, v_lin, 'FC', 210, 1210, jsonb_build_array(pg_temp.cargo(100, 'gravado', false, 21)),
                        'A', 0, 0, '{}'::jsonb, 0);
    PERFORM pg_temp.como(v_adm, 1);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE format('UPDATE public.productos SET costo_sin_iva = 105, costo_con_iva = 127.05, costo_real = 115 WHERE id = %s', v_p);
    EXECUTE 'RESET ROLE';
    v_t := (SELECT format('sin=%s con=%s', costo_sin_iva, costo_con_iva) FROM productos WHERE id = v_p);
    IF v_t IS DISTINCT FROM 'sin=105.00 con=139.15' THEN
      v_fallas := v_fallas || format('H6 · la ficha vieja corrigió el neto a 105: esperaba con=139,15 (con el flete y su IVA) y dio %s', v_t);
    END IF;
    PERFORM pg_temp.como(v_adm, 1);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE format('UPDATE public.productos SET costo_con_iva = 127.05 WHERE id = %s', v_p);
    EXECUTE 'RESET ROLE';
    v_t := (SELECT format('sin=%s con=%s', costo_sin_iva, costo_con_iva) FROM productos WHERE id = v_p);
    IF v_t IS DISTINCT FROM 'sin=105.00 con=139.15' THEN
      v_fallas := v_fallas || format('H6 · un PATCH con sólo el costo con IVA no lo cambia: esperaba con=139,15 y dio %s', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    v_fallas := v_fallas || format('H6 · %s %s', SQLSTATE, SQLERRM);
  END;

  -- ================================================================ H10 ====
  -- Una ZZ de 10 u. de las que salieron 8: bajarla a 5 se rechaza con su motivo; a 8, entra.
  DECLARE
    v_p bigint := pg_temp.producto('H10');
    v_c bigint;
  BEGIN
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 10, 10, 0), 'ZZ', 0, 100);
    PERFORM set_config('app.stock_origen', 'ajuste_manual', true);
    PERFORM set_config('app.stock_ref_tipo', 'ensayo', true);
    PERFORM set_config('app.stock_ref_id', '1', true);
    PERFORM set_config('app.stock_user_id', v_adm::text, true);
    UPDATE public.productos SET stock = stock - 8 WHERE id = v_p;
    PERFORM set_config('app.stock_origen', '', true);
    v_j := pg_temp.editar(v_adm, v_c, pg_temp.renglon(v_p, 5, 10, 0), NULL);
    IF COALESCE((v_j->>'success')::boolean, true)
       OR COALESCE(v_j->>'error', '') NOT LIKE 'El stock de hoy de «C3 H10 %» no alcanza: no se puede bajar la compra a menos de 8.' THEN
      v_fallas := v_fallas || format('H10 · bajar a 5 una compra de la que salieron 8: esperaba el rechazo con su motivo y dio %s', v_j);
    END IF;
    v_j := pg_temp.editar(v_adm, v_c, pg_temp.renglon(v_p, 8, 10, 0), NULL);
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR (SELECT stock FROM productos WHERE id = v_p) <> 0 THEN
      v_fallas := v_fallas || format('H10 · bajarla a 8 debía entrar y dejar stock 0, y dio %s', v_j);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('H10 · %s %s', SQLSTATE, SQLERRM);
  END;

  -- ================================================================ H6B ====
  -- N4 de la revisión: un producto sin compras (importado: neto 100, costo con IVA 100) al que la
  -- ficha le corrige el neto a 110 y manda 133,10: queda 133,10 (no conserva una «diferencia» que
  -- no viene de ninguna compra).
  DECLARE
    v_p bigint;
  BEGIN
    INSERT INTO public.productos (nombre, precio, stock, sucursal_id, porcentaje_iva, costo_sin_iva, costo_con_iva, costo_real)
    VALUES ('C3 H6B ' || gen_random_uuid(), 1000, 0, 1, 21, 100, 100, 100) RETURNING id INTO v_p;
    PERFORM pg_temp.como(v_adm, 1);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE format('UPDATE public.productos SET costo_sin_iva = 110, costo_con_iva = 133.10, costo_real = 110 WHERE id = %s', v_p);
    EXECUTE 'RESET ROLE';
    v_t := (SELECT format('sin=%s con=%s', costo_sin_iva, costo_con_iva) FROM productos WHERE id = v_p);
    IF v_t IS DISTINCT FROM 'sin=110.00 con=133.10' THEN
      v_fallas := v_fallas || format('H6B · un producto sin compras con el neto corregido a 110: esperaba con=133,10 y dio %s', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    v_fallas := v_fallas || format('H6B · %s %s', SQLSTATE, SQLERRM);
  END;

  -- ================================================================ RC2 ====
  -- El recálculo (_recalcular_costo_con_iva) sobre productos con el costo con IVA de la regla vieja.
  -- Los que quedan afuera de la regla conservan el «Costo total» que mostraba la ficha de antes
  -- (costo con IVA + lo que la compra sumó al costo real): N1 de la revisión. Un caso por grupo.
  DECLARE
    v_ids bigint[] := '{}';
    v_casos jsonb := '{}';
    v_p bigint; v_o bigint; v_c bigint; v_mov bigint; v_item bigint; v_r jsonb;
    v_flete jsonb := jsonb_build_array(pg_temp.cargo(100, 'no_gravado', false));
    k text; v_antes numeric; v_despues numeric; v_esperado numeric;
  BEGIN
    CREATE FUNCTION pg_temp.ficha_vieja(p bigint) RETURNS numeric LANGUAGE sql AS $f$
      SELECT CASE WHEN COALESCE(costo_con_iva, 0) > 0 THEN round(costo_con_iva
               + CASE WHEN COALESCE(costo_sin_iva, 0) > 0 AND COALESCE(costo_real, 0) > 0
                      THEN costo_real - CASE WHEN ultimo_tipo_compra IN ('ZZ', 'FC B', 'FC C') THEN costo_sin_iva
                                             ELSE round(costo_sin_iva * (1 + COALESCE(impuestos_internos, 0) / 100), 4) END
                      ELSE 0 END, 2) END
        FROM public.productos WHERE id = p;
    $f$;
    -- Deja el costo con IVA como lo dejaba la regla vieja (neto + IVA + II del renglón).
    CREATE FUNCTION pg_temp.viejo(p bigint) RETURNS void LANGUAGE sql AS $f$
      UPDATE public.productos pr SET costo_con_iva = round(public.costo_financiero_unitario(
               ci.costo_neto_unitario, COALESCE(ci.porcentaje_iva, pr.porcentaje_iva), ci.impuestos_internos,
               CASE WHEN pr.ultimo_tipo_compra IN ('ZZ', 'FC B', 'FC C') THEN 'ZZ' ELSE 'FC' END), 2)
        FROM public.compra_items ci
       WHERE pr.id = p AND ci.id = (SELECT max(id) FROM public.compra_items WHERE producto_id = p);
    $f$;

    -- G1 · envío posterior: la compra (flete de 100) hace una hora, y un envío aceptado después.
    v_p := pg_temp.producto('RC2 envio');
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 10, 100, 21), 'FC', 210, 1210, v_flete, 'A');
    PERFORM pg_temp.viejo(v_p);
    UPDATE compras SET created_at = now() - interval '1 hour' WHERE id = v_c;
    UPDATE compra_items SET created_at = now() - interval '1 hour' WHERE compra_id = v_c;
    INSERT INTO public.productos (nombre, precio, stock, sucursal_id, porcentaje_iva, costo_sin_iva, costo_con_iva, costo_real, costo_promedio, ultimo_tipo_compra)
    VALUES ('C3 RC2 origen ' || gen_random_uuid(), 1000, 50, 2, 21, 100, 121, 112, 112, 'FC') RETURNING id INTO v_o;
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm, 2) ON CONFLICT DO NOTHING;
    PERFORM pg_temp.como(v_adm, 2);
    v_j := public.crear_movimiento_sucursal(1, 'rc2', jsonb_build_array(jsonb_build_object('producto_id', v_o, 'cantidad', 5)));
    v_mov := (v_j->>'movimiento_id')::bigint;
    SELECT id INTO v_item FROM movimiento_sucursal_items WHERE movimiento_id = v_mov;
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object(
             'item_id', v_item, 'accion', 'match_existente', 'producto_destino_id', v_p)));
    v_ids := v_ids || v_p; v_casos := v_casos || jsonb_build_object('G1 envío posterior', v_p);

    -- G2 · nació en su sucursal por un envío (crear_nuevo): trae el costo real del origen, con flete.
    PERFORM pg_temp.como(v_adm, 2);
    v_j := public.crear_movimiento_sucursal(1, 'rc2', jsonb_build_array(jsonb_build_object('producto_id', v_o, 'cantidad', 5)));
    v_mov := (v_j->>'movimiento_id')::bigint;
    SELECT id INTO v_item FROM movimiento_sucursal_items WHERE movimiento_id = v_mov;
    PERFORM pg_temp.como(v_adm, 1);
    v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object('item_id', v_item, 'accion', 'crear_nuevo')));
    SELECT p.id INTO v_p FROM productos p WHERE p.sucursal_id = 1 AND p.nombre = (SELECT nombre FROM productos WHERE id = v_o);
    v_ids := v_ids || v_p; v_casos := v_casos || jsonb_build_object('G2 nacido por envío', v_p);

    -- G3 · costo real corregido a mano (115).
    v_p := pg_temp.producto('RC2 real a mano');
    PERFORM pg_temp.compra(v_adm, pg_temp.renglon(v_p, 10, 100, 21), 'FC', 210, 1210, v_flete, 'A');
    PERFORM pg_temp.viejo(v_p);
    UPDATE productos SET costo_real = 115 WHERE id = v_p;
    v_ids := v_ids || v_p; v_casos := v_casos || jsonb_build_object('G3 real a mano', v_p);

    -- G4 · la ficha vieja pasó la alícuota a 10,5 (costo con IVA 110,50).
    v_p := pg_temp.producto('RC2 alicuota');
    PERFORM pg_temp.compra(v_adm, pg_temp.renglon(v_p, 10, 100, 21), 'FC', 210, 1210, v_flete, 'A');
    UPDATE productos SET porcentaje_iva = 10.5, costo_con_iva = 110.50 WHERE id = v_p;
    v_ids := v_ids || v_p; v_casos := v_casos || jsonb_build_object('G4 alícuota de la ficha', v_p);

    -- G5 · renglón sin costo_real_unitario (otra época), con flete.
    v_p := pg_temp.producto('RC2 sin real');
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 10, 100, 21), 'FC', 210, 1210, v_flete, 'A');
    PERFORM pg_temp.viejo(v_p);
    UPDATE compra_items SET costo_real_unitario = NULL WHERE compra_id = v_c;
    v_ids := v_ids || v_p; v_casos := v_casos || jsonb_build_object('G5 renglón de otra época', v_p);

    -- Los «Costo total» de la ficha de antes, y el recálculo.
    FOR k, v_p IN SELECT key, value::bigint FROM jsonb_each_text(v_casos) LOOP
      v_casos := jsonb_set(v_casos, ARRAY[k], jsonb_build_array(v_p, pg_temp.ficha_vieja(v_p)));
    END LOOP;

    -- R1 · N2: bonificación del 33,35049 % (doble redondeo) con flete de 1: entra en la regla, 9,06.
    v_p := pg_temp.producto('RC2 redondeo');
    PERFORM pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(jsonb_build_object(
              'producto_id', v_p, 'cantidad', 1, 'costo_unitario', 10, 'porcentaje_iva', 21, 'condicion_iva', 'gravado',
              'bonificacion', 33.35049))), 'FC', 1.40, 8.06,
            jsonb_build_array(pg_temp.cargo(1, 'no_gravado', false)), 'A');
    PERFORM pg_temp.viejo(v_p);
    v_ids := v_ids || v_p; v_casos := v_casos || jsonb_build_object('R1 redondeo', jsonb_build_array(v_p, 9.06));

    -- R2 · N3: renglón sin alícuota guardada con un cargo gravado en factura de 100: 133,10.
    v_p := pg_temp.producto('RC2 sin alicuota');
    v_c := pg_temp.compra(v_adm, pg_temp.renglon(v_p, 10, 100, 21), 'FC', 231, 1331,
             jsonb_build_array(pg_temp.cargo(100, 'gravado', true)), 'A', 100);
    PERFORM pg_temp.viejo(v_p);
    UPDATE compra_items SET porcentaje_iva = NULL WHERE compra_id = v_c;
    v_ids := v_ids || v_p; v_casos := v_casos || jsonb_build_object('R2 renglón sin alícuota', jsonb_build_array(v_p, 133.10));

    v_r := public._recalcular_costo_con_iva(v_ids);
    v_notas := v_notas || format('RC2 · %s', v_r);
    FOR k IN SELECT key FROM jsonb_each(v_casos) LOOP
      v_p := (v_casos->k->>0)::bigint;
      v_esperado := (v_casos->k->>1)::numeric;
      v_despues := (SELECT costo_con_iva FROM productos WHERE id = v_p);
      IF v_despues IS DISTINCT FROM v_esperado THEN
        v_fallas := v_fallas || format('RC2 · %s: el «Costo total» de la ficha era %s y la ficha nueva muestra %s', k, v_esperado, v_despues);
      END IF;
    END LOOP;
    -- Idempotente: otra corrida no cambia nada.
    v_r := public._recalcular_costo_con_iva(v_ids);
    IF (v_r->>'regla')::int <> 0 OR (v_r->>'ficha_igual')::int <> 0 THEN
      v_fallas := v_fallas || format('RC2 · la segunda corrida cambió algo: %s', v_r);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('RC2 · %s %s', SQLSTATE, SQLERRM);
  END;

  -- ================================================================== L* ====
  -- Tercera revisión. L1: lo que ya está en la regla no lo toca la segunda pasada (P06: II del 10 % en
  -- el renglón y no en la ficha, 131; Q1: al revés, 121). L3: sobre todo, el recálculo corre una sola
  -- vez. L2: un exento sin alícuota cargada se costea al 0 % (Q2: neto de 100 a 110 con flete de 10:
  -- 120). L4: un producto sin compras al que el recálculo le sumó cargos los conserva al corregir el
  -- neto (Q6: 131 y, con el neto a 110, 143,10).
  DECLARE
    v_p06 bigint; v_q1 bigint; v_q2 bigint; v_q6 bigint; v_c bigint; v_r jsonb;
  BEGIN
    -- P06 y Q1, con el costo con IVA de la regla vieja (que en los dos ya es la regla).
    v_p06 := pg_temp.producto('L1 P06');
    PERFORM pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(jsonb_build_object(
              'producto_id', v_p06, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21, 'condicion_iva', 'gravado',
              'impuestos_internos', 10))), 'FC', 210, 1310, '[]'::jsonb, 'A');
    v_q1 := pg_temp.producto('L1 Q1');
    PERFORM pg_temp.compra(v_adm, pg_temp.renglon(v_q1, 10, 100, 21), 'FC', 210, 1210, '[]'::jsonb, 'A');
    UPDATE public.productos SET impuestos_internos = 10 WHERE id = v_q1;
    -- Q6: sin compras, con un costo real por encima del neto.
    INSERT INTO public.productos (nombre, precio, stock, sucursal_id, porcentaje_iva, costo_sin_iva, costo_real, costo_con_iva)
    VALUES ('C3 L4 Q6 ' || gen_random_uuid(), 1000, 0, 1, 21, 100, 110, 121) RETURNING id INTO v_q6;

    v_r := public._recalcular_costo_con_iva(ARRAY[v_p06, v_q1, v_q6]);
    v_t := (SELECT string_agg(format('%s', costo_con_iva), ' ' ORDER BY ord)
              FROM unnest(ARRAY[v_p06, v_q1, v_q6]) WITH ORDINALITY u(id, ord) JOIN productos p ON p.id = u.id);
    IF v_t IS DISTINCT FROM '131.00 121.00 131.00' THEN
      v_fallas := v_fallas || format('L1/L4 · esperaba P06 131 y Q1 121 (sin tocar) y Q6 131 (con sus cargos), y dio %s (%s)', v_t, v_r);
    END IF;

    -- L3: sobre todo, con el rastro ya lleno, se rechaza.
    BEGIN
      v_r := public._recalcular_costo_con_iva(NULL);
      v_fallas := v_fallas || format('L3 · el recálculo sobre todo, con el rastro lleno, debía rechazarse y dio %s', v_r);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE 'El recálculo del costo con IVA ya corrió%' THEN
        v_fallas := v_fallas || format('L3 · %s', SQLERRM);
      END IF;
    END;

    -- L2: exento sin alícuota, FC A de 10 × 100 exento con un flete de 100 sin IVA (110).
    INSERT INTO public.productos (nombre, precio, stock, sucursal_id, condicion_iva, porcentaje_iva)
    VALUES ('C3 L2 Q2 ' || gen_random_uuid(), 1000, 0, 1, 'exento', NULL) RETURNING id INTO v_q2;
    PERFORM pg_temp.compra(v_adm, pg_temp.lineas(jsonb_build_array(jsonb_build_object(
              'producto_id', v_q2, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 0, 'condicion_iva', 'exento'))),
            'FC', 0, 1000, jsonb_build_array(pg_temp.cargo(100, 'no_gravado', false)), 'A');

    PERFORM pg_temp.como(v_adm, 1);
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- La ficha de un PWA viejo corrige el neto a 110 (manda 110 de costo con IVA, sin el flete).
    EXECUTE format('UPDATE public.productos SET costo_sin_iva = 110, costo_con_iva = 110 WHERE id = %s', v_q2);
    -- Y la de Q6 corrige el neto a 110 (manda 133,10, sin los cargos).
    EXECUTE format('UPDATE public.productos SET costo_sin_iva = 110, costo_con_iva = 133.10 WHERE id = %s', v_q6);
    EXECUTE 'RESET ROLE';
    v_t := format('Q2=%s Q6=%s', (SELECT costo_con_iva FROM productos WHERE id = v_q2),
                  (SELECT costo_con_iva FROM productos WHERE id = v_q6));
    IF v_t IS DISTINCT FROM 'Q2=120.00 Q6=143.10' THEN
      v_fallas := v_fallas || format('L2/L4 · con el neto corregido a 110: esperaba Q2=120 (exento, 0 %% de IVA) y Q6=143,10 (conserva sus cargos), y dio %s', v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    v_fallas := v_fallas || format('L* · %s %s', SQLSTATE, SQLERRM);
  END;

  -- ================================================================= RC ====
  -- El rastro del recálculo: sólo de server.
  IF to_regclass('public.costo_con_iva_recalculos') IS NULL
     OR has_table_privilege('authenticated', 'public.costo_con_iva_recalculos', 'SELECT')
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.costo_con_iva_recalculos')) THEN
    v_fallas := v_fallas || 'RC · falta la tabla del recálculo, o la ve la API'::text;
  END IF;

  RAISE EXCEPTION USING ERRCODE = 'ZZ001';
 EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas:\n  %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, E'\n  '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format(E'ENSAYO OK (todo revertido) · E1 E2 E3 E4 H5 H5P H5L HG HZ C1-C13 RP ED N1-N5 H6 H6B H10 RC2 L1-L4 RC\nnotas:\n  %s',
    array_to_string(v_notas, E'\n  '));
END
$ensayo$;
