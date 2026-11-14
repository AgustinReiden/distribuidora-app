-- Ensayo de la migración «el regalo con descuento, el tope de la devolución y el bot por
-- proveedor» (cierre de la tanda #1565: los tres hallazgos medios de compras de la lente
-- adversarial; H3 es una regresión de la 499, H2 completa el CMP-2 de la 496 y H1 lo causa la 496).
--
-- Un único DO que termina SIEMPRE en una excepción: no deja rastro (salvo valores de secuencia).
-- Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT;
-- después, solo. Cada caso usa sus propios productos, proveedores y compras.
--
-- Personas (salen de la base): un admin activo de una sucursal activa. Las compras son ZZ salvo
-- donde se dice.
--
-- H3 · el regalo (bonificación del 100 %) alcanzado por un descuento prorrateado.
--   R1 · 10 × 100 pagado + 5 × 100 de regalo, descuento −150 prorrateado por cantidad con los pesos
--        que pre-llena el modal (10 y 5): entra, como antes de la tanda. El renglón pagado queda en
--        costo real 90 y cargos −10, el regalo en costo real 0 (no −10) y cargos −10; el producto
--        pagado queda en reposición 90, sin IVA 100 y promedio 90, y el regalo suma 5 al stock sin
--        costo. Lo mismo con la base `unidades`.
--   R2 · editar esa compra sin cambios (con sus renglones vistos) entra y deja los mismos números.
--   R3 · COMPRA-C no cuenta esas compras.
--   R4 · el piso sigue: el mismo par con un descuento de −2.000 se rechaza nombrando al renglón
--        pagado (renglón 1, −33,33) y no al regalo, en el alta y en la edición; y el caso original
--        de CMP-3 (10 × 100 con −2.000) sigue rechazado.
-- H2 · la devolución no pasa lo que le queda a la compra cuando la compra tiene un ajuste.
--   D1 · 10 × 100 = 1.000 con un ajuste de 800: la devolución de las 10 u. (1.000) no entra y dice
--        cuánto queda (200,00); la de 2 u. (200, justo lo que queda) entra; una más ya no.
--   D2 · lo mismo por lote (`registrar_nota_credito_lote`): con un ajuste de 800 la devolución del
--        lote entero no entra y dice cuánto queda; la de 2 u. entra.
--   D3 · el orden inverso sigue rechazado (la 496): devolución total y después un ajuste de 800.
--   D4 · sin ajustes, la devolución total entra SIEMPRE, aunque pase el total de la compra:
--        FC A con IVA, II y percepciones; FC A con bonificación de cabecera; ZZ con un descuento
--        prorrateado; FC A con el IVA por renglón un centavo arriba del de la cabecera; ZZ en dos
--        partes con el centavo de redondeo; ZZ con flete y bonificación del renglón en dos partes;
--        y por lote, la compra con descuento entera.
-- H1 · el bot devuelve una fila por proveedor.
--   B1 · un proveedor renombrado entre dos compras: una fila, con el nombre de hoy, 2 compras y la
--        suma de las dos.
--   B2 · las compras sin proveedor van por el nombre guardado: dos de «X» son una fila y una de «Y»
--        otra; las de un proveedor eliminado (renombrado antes de eliminarlo) son una fila.
--   B3 · los permisos de bot_compras_periodo no cambian: sólo server.
--
-- Sin la migración tiene que FALLAR en R1, R2 (R1 no deja compra), R4 (el rechazo nombra también al
-- regalo), D1, D2 y B1.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   psql "$DATABASE_URL" -f scripts/test-compras-regalo-devolucion-y-bot-1565.sql

DO $ensayo$
DECLARE
  v_s1     bigint;
  v_ua     uuid;
  v_p      bigint;
  v_q      bigint;
  v_r2     bigint;
  v_c      bigint;
  v_prov   bigint;
  v_lote   bigint;
  v_j      jsonb;
  v_t      text;
  v_r      record;
  v_cc0    bigint;
  v_base   text;
  v_pre    text;
  v_hoy    date := public._tablero_hoy();
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';

  SELECT us.usuario_id, us.sucursal_id INTO v_ua, v_s1
    FROM usuario_sucursales us
    JOIN perfiles p ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.sucursal_id, us.usuario_id
   LIMIT 1;
  IF v_ua IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay un admin activo de una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ua, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_s1::text)::text, true);

  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, sucursal_id)
    VALUES (p_nombre || ' ' || gen_random_uuid(), 100, 0, p_suc) RETURNING id;
  $f$;

  -- un renglón ZZ; lo que traiga pisa el default
  CREATE FUNCTION pg_temp.renglon(p_prod bigint, p_cant numeric, p_costo numeric, p_extra jsonb DEFAULT '{}')
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'costo_unitario', p_costo,
             'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0, 'condicion_iva', 'gravado',
             'subtotal', round(p_cant * p_costo * (1 - COALESCE((p_extra->>'bonificacion')::numeric, 0) / 100), 2))
           || p_extra;
  $f$;

  CREATE FUNCTION pg_temp.cargo(p_concepto text, p_monto numeric, p_base text, p_pesos jsonb,
                                p_cond text DEFAULT 'no_gravado') RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('concepto', p_concepto, 'monto', p_monto, 'condicion_iva', p_cond,
             'en_factura', true, 'prorratea_al_costo', true, 'base_prorrateo', p_base, 'pesos', p_pesos);
  $f$;

  -- alta ZZ: el total es el subtotal más los cargos en factura (el subtotal si eso da negativo,
  -- para que el rechazo sea el del piso y no el de la cabecera)
  CREATE FUNCTION pg_temp.alta(p_prov bigint, p_nombre text, p_items jsonb, p_cargos jsonb DEFAULT '[]',
                               p_fecha date DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_items) e);
    v_car numeric := COALESCE((SELECT sum((e->>'monto')::numeric) FROM jsonb_array_elements(p_cargos) e), 0);
  BEGIN
    RETURN public.registrar_compra_completa(
      p_prov, p_nombre, 'ENS-1565-' || gen_random_uuid(), COALESCE(p_fecha, public._tablero_hoy()), v_sub, 0, 0,
      CASE WHEN v_sub + v_car < 0 THEN v_sub ELSE v_sub + v_car END, 'efectivo', 'ensayo 1565', (current_setting('request.jwt.claims')::json->>'sub')::uuid,
      p_items, 'ZZ', p_cargos => p_cargos);
  END $f$;

  CREATE FUNCTION pg_temp.vistos(p_compra bigint) RETURNS bigint[] LANGUAGE sql AS $f$
    SELECT array_agg(id ORDER BY id) FROM public.compra_items WHERE compra_id = p_compra;
  $f$;

  CREATE FUNCTION pg_temp.editar(p_compra bigint, p_items jsonb, p_cargos jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_items) e);
    v_car numeric := COALESCE((SELECT sum((e->>'monto')::numeric) FROM jsonb_array_elements(p_cargos) e), 0);
  BEGIN
    RETURN public.actualizar_compra_items(
      p_compra, p_items, v_sub, 0, CASE WHEN v_sub + v_car < 0 THEN v_sub ELSE v_sub + v_car END, (current_setting('request.jwt.claims')::json->>'sub')::uuid,
      p_cargos => p_cargos, p_ii_declarado => '{}'::jsonb, p_renglones_vistos => pg_temp.vistos(p_compra));
  END $f$;

  CREATE FUNCTION pg_temp.ajuste(p_compra bigint, p_total numeric) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT public.registrar_nota_credito(p_compra, 'ENS-1565-NCA-' || gen_random_uuid(), 'ensayo 1565',
             p_total, 0, p_total, NULL, '[]'::jsonb, 0);
  $f$;

  -- la devolución como la arma el modal: por producto, cantidad × costo neto promedio de la
  -- factura, y el IVA a la alícuota ponderada (notaCredito.ts)
  CREATE FUNCTION pg_temp.devolver(p_compra bigint, p_items jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    e jsonb; o jsonb := '[]'; v_sub numeric; v_tasa numeric; s numeric := 0; i numeric := 0;
  BEGIN
    FOR e IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      SELECT round((e->>'cantidad')::int * sum(ci.cantidad * ci.costo_unitario * (1 - ci.bonificacion / 100)) / sum(ci.cantidad), 2),
             COALESCE(sum(ci.cantidad * ci.costo_unitario * (1 - ci.bonificacion / 100)
                          * CASE WHEN ci.condicion_iva = 'gravado' THEN ci.porcentaje_iva ELSE 0 END)
                      / NULLIF(sum(ci.cantidad * ci.costo_unitario * (1 - ci.bonificacion / 100)), 0), 0)
        INTO v_sub, v_tasa
        FROM public.compra_items ci
       WHERE ci.compra_id = p_compra AND ci.producto_id = (e->>'producto_id')::bigint;
      o := o || jsonb_build_array(e || jsonb_build_object('subtotal', v_sub));
      s := s + v_sub;
      i := i + round(v_sub * v_tasa / 100, 2);
    END LOOP;
    RETURN public.registrar_nota_credito(p_compra, 'ENS-1565-NCD-' || gen_random_uuid(), 'ensayo 1565',
                                         s, i, s + i, NULL, o, NULL);
  END $f$;

  CREATE FUNCTION pg_temp.ok(p_j jsonb) RETURNS boolean LANGUAGE sql AS $f$
    SELECT COALESCE((p_j->>'success')::boolean, false);
  $f$;

  CREATE FUNCTION pg_temp.chk(p_id text) RETURNS bigint LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::bigint FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     WHERE c->>'id' = p_id;
  $f$;

  -- la foto de una compra de regalo: renglones y productos
  CREATE FUNCTION pg_temp.foto_regalo(p_compra bigint, p_pago bigint, p_regalo bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('pago %s/%s regalo %s/%s · prod pago %s %s %s %s · prod regalo %s %s %s',
             (SELECT costo_real_unitario FROM public.compra_items WHERE compra_id = p_compra AND producto_id = p_pago),
             (SELECT cargos_unitarios    FROM public.compra_items WHERE compra_id = p_compra AND producto_id = p_pago),
             (SELECT costo_real_unitario FROM public.compra_items WHERE compra_id = p_compra AND producto_id = p_regalo),
             (SELECT cargos_unitarios    FROM public.compra_items WHERE compra_id = p_compra AND producto_id = p_regalo),
             a.stock, a.costo_real, a.costo_sin_iva, a.costo_promedio,
             b.stock, COALESCE(b.costo_real::text, 'NULL'), COALESCE(b.costo_promedio::text, 'NULL'))
      FROM public.productos a, public.productos b WHERE a.id = p_pago AND b.id = p_regalo;
  $f$;

  v_cc0 := pg_temp.chk('COMPRA-C');

  -- ---------------------------------------------------------------- R1 · R2 · R3
  -- Lo de antes de la tanda (el cuerpo del 12/11, sin el piso de la 499), medido: renglón pagado 90 / −10,
  -- regalo −10 / −10, producto pagado 10 · 90 · 100 · 90, regalo 5 sin costo. Ahora el regalo
  -- guarda 0 en vez de −10; todo lo demás, igual.
  FOREACH v_base IN ARRAY ARRAY['cantidad', 'unidades'] LOOP
    BEGIN
      v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 R1 pago');
      v_q := pg_temp.producto(v_s1, 'ZZ ensayo 1565 R1 regalo');
      v_j := pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100),
                                                    pg_temp.renglon(v_q, 5, 100, '{"bonificacion": 100}')),
                          jsonb_build_array(pg_temp.cargo('pronto pago', -150, v_base, '{"0": 10, "1": 5}')));
      v_c := (v_j->>'compra_id')::bigint;
      v_t := pg_temp.foto_regalo(v_c, v_p, v_q);
      IF NOT pg_temp.ok(v_j)
         OR v_t IS DISTINCT FROM 'pago 90.0000/-10.0000 regalo 0.0000/-10.0000 · prod pago 10 90.0000 100.00 90.0000 · prod regalo 5 NULL NULL' THEN
        v_fallas := v_fallas || format('R1 (%s) alta: %s · %s', v_base, v_j, v_t);
      ELSE
        v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, 100),
                                                     pg_temp.renglon(v_q, 5, 100, '{"bonificacion": 100}')),
                              jsonb_build_array(pg_temp.cargo('pronto pago', -150, v_base, '{"0": 10, "1": 5}')));
        v_t := pg_temp.foto_regalo(v_c, v_p, v_q);
        IF NOT pg_temp.ok(v_j)
           OR v_t IS DISTINCT FROM 'pago 90.0000/-10.0000 regalo 0.0000/-10.0000 · prod pago 10 90.0000 100.00 90.0000 · prod regalo 5 NULL NULL' THEN
          v_fallas := v_fallas || format('R2 (%s) edición sin cambios: %s · %s', v_base, v_j, v_t);
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('R1/R2 (%s) %s', v_base, SQLERRM);
    END;
  END LOOP;
  IF pg_temp.chk('COMPRA-C') <> v_cc0 THEN
    v_fallas := v_fallas || format('R3 COMPRA-C cuenta las compras con regalo: %s → %s', v_cc0, pg_temp.chk('COMPRA-C'));
  END IF;

  -- ---------------------------------------------------------------- R4
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 R4 pago');
    v_q := pg_temp.producto(v_s1, 'ZZ ensayo 1565 R4 regalo');
    v_j := pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100),
                                                  pg_temp.renglon(v_q, 5, 100, '{"bonificacion": 100}')),
                        jsonb_build_array(pg_temp.cargo('pronto pago', -2000, 'cantidad', '{"0": 10, "1": 5}')));
    IF pg_temp.ok(v_j) OR v_j->>'error' NOT LIKE 'Los cargos dejan sin costo: %R4 pago% (renglón 1) queda en -33.33.%'
       OR v_j->>'error' LIKE '%renglón 2%' THEN
      v_fallas := v_fallas || ('R4 alta con −2.000: ' || v_j::text);
    END IF;
    -- en la edición: la compra de −150 entra, y editarla a −2.000 se rechaza igual
    v_j := pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100),
                                                  pg_temp.renglon(v_q, 5, 100, '{"bonificacion": 100}')),
                        jsonb_build_array(pg_temp.cargo('pronto pago', -150, 'cantidad', '{"0": 10, "1": 5}')));
    v_c := (v_j->>'compra_id')::bigint;
    IF v_c IS NOT NULL THEN
      v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, 100),
                                                   pg_temp.renglon(v_q, 5, 100, '{"bonificacion": 100}')),
                            jsonb_build_array(pg_temp.cargo('pronto pago', -2000, 'cantidad', '{"0": 10, "1": 5}')));
      IF pg_temp.ok(v_j) OR v_j->>'error' NOT LIKE 'Los cargos dejan sin costo: %(renglón 1) queda en -33.33.%'
         OR v_j->>'error' LIKE '%renglón 2%' THEN
        v_fallas := v_fallas || ('R4 edición a −2.000: ' || v_j::text);
      END IF;
    END IF;
    -- el caso original de CMP-3
    v_j := pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)),
                        jsonb_build_array(pg_temp.cargo('bonif', -2000, 'unidades', '{"0": 10}')));
    IF pg_temp.ok(v_j) OR v_j->>'error' NOT LIKE '%(renglón 1) queda en -100.00%' THEN
      v_fallas := v_fallas || ('R4 CMP-3 original: ' || v_j::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('R4 ' || SQLERRM);
  END;

  -- ---------------------------------------------------------------- D1
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D1');
    v_c := (pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)))->>'compra_id')::bigint;
    v_j := pg_temp.ajuste(v_c, 800);
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || ('D1 el ajuste de 800: ' || v_j::text);
    END IF;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10)));
    IF pg_temp.ok(v_j) OR v_j->>'error' NOT LIKE 'La devolución (1000.00) supera lo que le queda a la compra (200.00,%' THEN
      v_fallas := v_fallas || ('D1 devolución de 1.000 con 200 por acreditar: ' || v_j::text);
    END IF;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 2)));
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || ('D1 devolución de 200, justo lo que queda: ' || v_j::text);
    END IF;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 1)));
    IF pg_temp.ok(v_j) OR v_j->>'error' NOT LIKE 'La devolución (100.00) supera lo que le queda a la compra (0.00,%' THEN
      v_fallas := v_fallas || ('D1 devolución con la compra ya acreditada entera: ' || v_j::text);
    END IF;
    IF (SELECT sum(total) FROM public.notas_credito WHERE compra_id = v_c) IS DISTINCT FROM 1000.00 THEN
      v_fallas := v_fallas || format('D1 lo acreditado es %s sobre 1.000', (SELECT sum(total) FROM public.notas_credito WHERE compra_id = v_c));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('D1 ' || SQLERRM);
  END;

  -- ---------------------------------------------------------------- D2
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D2');
    v_c := (pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)))->>'compra_id')::bigint;
    v_j := public.sincronizar_lotes_compra(v_c, jsonb_build_array(jsonb_build_object(
             'producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 10)));
    SELECT id INTO v_lote FROM public.producto_lotes WHERE compra_id = v_c AND producto_id = v_p;
    IF v_lote IS NULL THEN
      RAISE EXCEPTION 'la compra de D2 no quedó con su lote: %', v_j;
    END IF;
    v_j := pg_temp.ajuste(v_c, 800);
    BEGIN
      v_j := public.registrar_nota_credito_lote(v_lote, 10, 'ENS-1565-NCL', 'ensayo 1565');
      v_fallas := v_fallas || ('D2 entró la devolución del lote entero (1.000) con 200 por acreditar: ' || v_j::text);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE 'La devolución (1000.00) supera lo que le queda a la compra (200.00,%' THEN
        v_fallas := v_fallas || ('D2 el rechazo dice otra cosa: ' || SQLERRM);
      END IF;
    END;
    BEGIN
      v_j := public.registrar_nota_credito_lote(v_lote, 2, 'ENS-1565-NCL', 'ensayo 1565');
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || ('D2 no entró la devolución de 2 u. del lote (200, justo lo que queda): ' || SQLERRM);
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('D2 ' || SQLERRM);
  END;

  -- ---------------------------------------------------------------- D3
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D3');
    v_c := (pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)))->>'compra_id')::bigint;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10)));
    IF NOT pg_temp.ok(v_j) THEN
      v_fallas := v_fallas || ('D3 la devolución total: ' || v_j::text);
    END IF;
    IF pg_temp.ok(pg_temp.ajuste(v_c, 800)) THEN
      v_fallas := v_fallas || 'D3 entró un ajuste después de la devolución total'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('D3 ' || SQLERRM);
  END;

  -- ---------------------------------------------------------------- D4
  -- sin ajustes, la devolución total entra siempre (antes y después de la migración)
  BEGIN
    -- a · FC A con IVA, II y percepciones (lo devuelto queda abajo del total)
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4a');
    v_j := public.registrar_compra_completa(NULL, 'ensayo 1565', 'ENS-1565-' || gen_random_uuid(), v_hoy,
             1000, 210, 0, 1000 + 210 + 86.96 + 50 + 30, 'efectivo', 'ensayo 1565', v_ua,
             jsonb_build_array(pg_temp.renglon(v_p, 10, 100, '{"porcentaje_iva": 21, "impuestos_internos": 8.6957}')),
             'FC', 86.96, 50, 30, 0, '[]'::jsonb, '{}'::jsonb, 0, 'A');
    v_j := pg_temp.devolver((v_j->>'compra_id')::bigint, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10)));
    IF NOT pg_temp.ok(v_j) THEN v_fallas := v_fallas || ('D4a FC A IVA, II y percepciones: ' || v_j::text); END IF;

    -- b · FC A con bonificación de cabecera −100 (lo devuelto, 1.296,96, pasa el total, 1.255,96)
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4b');
    v_j := public.registrar_compra_completa(NULL, 'ensayo 1565', 'ENS-1565-' || gen_random_uuid(), v_hoy,
             1000, 189, 0, 1000 - 100 + 189 + 86.96 + 50 + 30, 'efectivo', 'ensayo 1565', v_ua,
             jsonb_build_array(pg_temp.renglon(v_p, 10, 100, '{"porcentaje_iva": 21, "impuestos_internos": 8.6957}')),
             'FC', 86.96, 50, 30, 0,
             jsonb_build_array(pg_temp.cargo('bonif factura', -100, 'monto', '{"0": 1000}', 'gravado')),
             '{}'::jsonb, -100, 'A');
    IF NOT pg_temp.ok(v_j) THEN RAISE EXCEPTION 'la compra de D4b no entró: %', v_j; END IF;
    v_j := pg_temp.devolver((v_j->>'compra_id')::bigint, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10)));
    IF NOT pg_temp.ok(v_j) THEN v_fallas := v_fallas || ('D4b FC A con bonificación de cabecera: ' || v_j::text); END IF;

    -- c · ZZ con un descuento prorrateado de −150 (lo devuelto, 1.000, pasa el total, 850)
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4c');
    v_j := pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)),
                        jsonb_build_array(pg_temp.cargo('desc', -150, 'unidades', '{"0": 10}')));
    v_c := (v_j->>'compra_id')::bigint;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10)));
    IF NOT pg_temp.ok(v_j) THEN v_fallas := v_fallas || ('D4c ZZ con descuento: ' || v_j::text); END IF;

    -- d · FC A, 3 × 2,50 al 21 %: el IVA por renglón (1,59) pasa en un centavo al de la cabecera (1,58)
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4d1');
    v_q := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4d2');
    v_r2 := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4d3');
    v_j := public.registrar_compra_completa(NULL, 'ensayo 1565', 'ENS-1565-' || gen_random_uuid(), v_hoy,
             7.50, 1.58, 0, 9.08, 'efectivo', 'ensayo 1565', v_ua,
             jsonb_build_array(pg_temp.renglon(v_p, 1, 2.5, '{"porcentaje_iva": 21}'),
                               pg_temp.renglon(v_q, 1, 2.5, '{"porcentaje_iva": 21}'),
                               pg_temp.renglon(v_r2, 1, 2.5, '{"porcentaje_iva": 21}')),
             'FC', p_letra_comprobante => 'A');
    v_j := pg_temp.devolver((v_j->>'compra_id')::bigint, jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 1), jsonb_build_object('producto_id', v_q, 'cantidad', 1),
             jsonb_build_object('producto_id', v_r2, 'cantidad', 1)));
    IF NOT pg_temp.ok(v_j) THEN v_fallas := v_fallas || ('D4d IVA por renglón: ' || v_j::text); END IF;

    -- e · ZZ, 1 × 0,33 y 1 × 0,34 del mismo producto, devueltas de a una (0,34 + 0,34 sobre 0,67)
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4e');
    v_c := (pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 1, 0.33), pg_temp.renglon(v_p, 1, 0.34)))->>'compra_id')::bigint;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 1)));
    IF NOT pg_temp.ok(v_j) THEN v_fallas := v_fallas || ('D4e primera parte: ' || v_j::text); END IF;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 1)));
    IF NOT pg_temp.ok(v_j) THEN v_fallas := v_fallas || ('D4e segunda parte: ' || v_j::text); END IF;

    -- f · ZZ con flete de 500 y bonificación del renglón del 7 %, en dos partes (4 + 3)
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4f');
    v_c := (pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 7, 33.33, '{"bonificacion": 7}')),
                         jsonb_build_array(pg_temp.cargo('flete', 500, 'unidades', '{"0": 7}')))->>'compra_id')::bigint;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 4)));
    IF NOT pg_temp.ok(v_j) THEN v_fallas := v_fallas || ('D4f primera parte: ' || v_j::text); END IF;
    v_j := pg_temp.devolver(v_c, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 3)));
    IF NOT pg_temp.ok(v_j) THEN v_fallas := v_fallas || ('D4f segunda parte: ' || v_j::text); END IF;

    -- g · por lote, la compra con descuento entera (1.000 sobre 850)
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 D4g');
    v_c := (pg_temp.alta(NULL, 'ensayo 1565', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)),
                         jsonb_build_array(pg_temp.cargo('desc', -150, 'unidades', '{"0": 10}')))->>'compra_id')::bigint;
    PERFORM public.sincronizar_lotes_compra(v_c, jsonb_build_array(jsonb_build_object(
              'producto_id', v_p, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 10)));
    SELECT id INTO v_lote FROM public.producto_lotes WHERE compra_id = v_c AND producto_id = v_p;
    BEGIN
      v_j := public.registrar_nota_credito_lote(v_lote, 10, 'ENS-1565-NCL', 'ensayo 1565');
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || ('D4g por lote: ' || SQLERRM);
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('D4 ' || SQLERRM);
  END;

  -- ---------------------------------------------------------------- B1 · B2
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1565 B');
    v_pre := 'ENS1565 ' || gen_random_uuid();   -- prefijo de los nombres de este caso
    INSERT INTO proveedores (nombre, sucursal_id) VALUES (v_pre || ' Norte', v_s1) RETURNING id INTO v_prov;
    PERFORM pg_temp.alta(v_prov, NULL, jsonb_build_array(pg_temp.renglon(v_p, 10, 100)), '[]', v_hoy - 2);
    UPDATE proveedores SET nombre = v_pre || ' Norte S.A.' WHERE id = v_prov;
    PERFORM pg_temp.alta(v_prov, NULL, jsonb_build_array(pg_temp.renglon(v_p, 5, 100)), '[]', v_hoy - 1);
    -- sin proveedor: dos de X y una de Y
    PERFORM pg_temp.alta(NULL, v_pre || ' X', jsonb_build_array(pg_temp.renglon(v_p, 1, 100)), '[]', v_hoy - 1);
    PERFORM pg_temp.alta(NULL, v_pre || ' X', jsonb_build_array(pg_temp.renglon(v_p, 2, 100)), '[]', v_hoy - 1);
    PERFORM pg_temp.alta(NULL, v_pre || ' Y', jsonb_build_array(pg_temp.renglon(v_p, 4, 100)), '[]', v_hoy - 1);
    -- un proveedor eliminado, renombrado entre sus dos compras
    INSERT INTO proveedores (nombre, sucursal_id) VALUES (v_pre || ' Sur', v_s1) RETURNING id INTO v_q;
    PERFORM pg_temp.alta(v_q, NULL, jsonb_build_array(pg_temp.renglon(v_p, 3, 100)), '[]', v_hoy - 2);
    UPDATE proveedores SET nombre = v_pre || ' Sur SRL' WHERE id = v_q;
    PERFORM pg_temp.alta(v_q, NULL, jsonb_build_array(pg_temp.renglon(v_p, 6, 100)), '[]', v_hoy - 1);
    v_j := public.eliminar_proveedor(v_q);
    IF NOT pg_temp.ok(v_j) THEN RAISE EXCEPTION 'eliminar_proveedor no pasó: %', v_j; END IF;

    v_j := public.bot_compras_periodo(v_hoy - 3, v_hoy, v_s1, 1000)::jsonb;
    SELECT string_agg(format('%s|%s|%s|%s', COALESCE(e->>'proveedor_id', '-'), replace(e->>'nombre', v_pre || ' ', ''),
                             e->>'compras_count', e->>'total_comprado'), '; ' ORDER BY e->>'nombre')
      INTO v_t
      FROM jsonb_array_elements(v_j->'top_proveedores') e
     WHERE e->>'nombre' LIKE v_pre || ' %';
    IF v_t IS DISTINCT FROM format('%s|Norte S.A.|2|1500.00; -|Sur SRL|2|900.00; -|X|2|300.00; -|Y|1|400.00', v_prov) THEN
      v_fallas := v_fallas || ('B1/B2 top_proveedores: ' || COALESCE(v_t, '(nada)'));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('B1/B2 ' || SQLERRM);
  END;

  -- ---------------------------------------------------------------- B3
  IF has_function_privilege('authenticated', 'public.bot_compras_periodo(date,date,bigint,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.bot_compras_periodo(date,date,bigint,integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.bot_compras_periodo(date,date,bigint,integer)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'B3 bot_compras_periodo cambió de permisos'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · R1 R2 R3 R4 D1 D2 D3 D4 B1 B2 B3';
END
$ensayo$;
