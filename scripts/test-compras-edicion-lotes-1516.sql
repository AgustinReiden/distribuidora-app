-- Ensayo de la 482 (#1516: STK-2, STK-3, STK-7, STK-9): la edición de una compra con vencimientos
-- saca de sus propios lotes lo que corrige a la baja, no se edita una compra con notas de crédito,
-- sincronizar_lotes_compra valida los lotes contra la compra, y el server valida el subtotal de cada
-- renglón. STK-6 y PAT-13-1 (el orden de locks) los mide el grupo b4 del arnés de concurrencia.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE EXCEPTION, así que
-- todo lo que crea (productos, compras, lotes, notas) se deshace. Usa un admin activo de una sucursal
-- activa, como los ensayos de la 1079 y la 1095, y llama a las RPCs como authenticated (SET LOCAL ROLE
-- + request.jwt.claims + x-sucursal-id), como PostgREST.
--
-- Por qué hay bolsa y lotes con hueco: con la bolsa en 0 y un solo lote, la bajada del trigger no
-- tiene de dónde comer más que de ese lote y varias cosas dan bien por casualidad (así se escondió el
-- bug de la 316). El caso A es el del issue (bolsa 0); B, con hueco, bolsa y el lote de otra compra
-- que vence antes, es el que muerde: sin el arreglo la edición le come a ese otro lote.
--
-- Casos (lote = cantidad/restante; bolsa = stock − suma de los restantes):
--   A · STK-2, el del issue. Compra de 100 con su lote de 100, bolsa 0. Corregida a 80 y los
--       vencimientos a 80 (lo que manda la app): lote 80/80, bolsa 0, stock 80. Antes: 80/60, bolsa 20.
--   B · STK-2 con hueco y bolsa. Lote manual M (vence antes) 10/10, bolsa 5; la compra C de 50 con su
--       lote L, del que salieron 5 (L 50/45). Corregida a 30 (vencimientos 30): M 10/10, L 30/25,
--       bolsa 5, stock 40. Antes: la bajada consumía FEFO y M quedaba en 0.
--   C · STK-2 con dos vencimientos y la bolsa en 0. Compra de 100 en dos lotes de 50; corregida a 50,
--       con 25 y 25: los dos quedan 25/25 y la bolsa en 0 (la primera pasada no vacía ningún lote).
--   D · STK-2, sacar el producto de la compra. P con un lote de 20/20 y bolsa 0, la compra trae
--       también Q. Se edita dejando sólo Q y se mandan los vencimientos vacíos: P sin lotes, stock 0.
--   E · STK-2 al alza (no cambia). Compra de 100 con lote de 100, bolsa 0, corregida a 120 con
--       vencimientos 120: lote 120/120, bolsa 0.
--   F · STK-3. Una compra con una nota de crédito: la edición se rechaza por la nota y no toca nada.
--   G · STK-7. sincronizar_lotes_compra rechaza un producto que no está en la compra y vencimientos que
--       suman más que lo comprado, y no toca nada.
--   H · STK-9. El alta y la edición rechazan un renglón con el subtotal bruto (sin la bonificación) o
--       0,02 corrido, aunque la cabecera cierre; aceptan 0,01 (3 × 33,335 = 100,005 mandado como 100).
--
-- Veredicto: 'ENSAYO OK (todo revertido)', o 'ENSAYO FALLÓ …' con la lista de fallas. En los dos
-- casos no queda nada escrito.
--
--   psql "$DATABASE_URL" -f scripts/test-compras-edicion-lotes-1516.sql

DO $ensayo$
DECLARE
  v_admin    uuid;
  v_suc      bigint;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_p        bigint;
  v_q        bigint;
  v_c        bigint;
  v_m        bigint;
  v_l        bigint;
  v_l2       bigint;
  v_r        jsonb;
  v_foto     jsonb;
  v_txt      text;
  v_fallas   text[] := '{}';
BEGIN
 BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- stock / suma de los restantes / bolsa del producto
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('stock', pr.stock, 'lotes', l.r, 'bolsa', pr.stock - l.r)
      FROM public.productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM public.producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = p_prod;
  $f$;
  -- 'cantidad/restante' de un lote ('-' si no existe)
  CREATE FUNCTION pg_temp.lote(p_lote bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE((SELECT cantidad || '/' || cantidad_restante FROM public.producto_lotes WHERE id = p_lote), '-');
  $f$;
  -- el lote de una compra y un producto con ese vencimiento
  CREATE FUNCTION pg_temp.lote_de(p_compra bigint, p_prod bigint, p_vence date) RETURNS bigint LANGUAGE sql AS $f$
    SELECT id FROM public.producto_lotes WHERE compra_id = p_compra AND producto_id = p_prod AND fecha_vencimiento = p_vence;
  $f$;
  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text, p_bolsa int) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES (p_nombre, 100, p_bolsa, 10, p_suc) RETURNING id;
  $f$;
  -- un renglón de compra como lo arma la app: subtotal = cantidad × costo × (1 − bonif/100)
  CREATE FUNCTION pg_temp.renglon(p_prod bigint, p_cant int, p_costo numeric, p_bonif numeric DEFAULT 0,
                                  p_subtotal numeric DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'costo_unitario', p_costo,
                              'subtotal', COALESCE(p_subtotal, p_cant * p_costo * (1 - p_bonif / 100)),
                              'bonificacion', p_bonif, 'porcentaje_iva', 0, 'condicion_iva', 'gravado',
                              'impuestos_internos', 0);
  $f$;
  CREATE FUNCTION pg_temp.suma(p_items jsonb) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(SUM((e->>'subtotal')::numeric), 0) FROM jsonb_array_elements(p_items) e;
  $f$;
  -- el alta (ZZ: sin IVA, total = subtotal), como authenticated
  CREATE FUNCTION pg_temp.alta(p_admin uuid, p_items jsonb, p_fecha date) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v_r jsonb; v_sub numeric := pg_temp.suma(p_items);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_r := public.registrar_compra_completa(
      NULL, 'ENSAYO 1516', 'ENSAYO-1516-' || gen_random_uuid(), p_fecha,
      v_sub, 0, 0, v_sub, 'efectivo', 'ensayo #1516', p_admin, p_items, 'ZZ');
    EXECUTE 'RESET ROLE';
    RETURN v_r;
  END $f$;
  CREATE FUNCTION pg_temp.editar(p_admin uuid, p_compra bigint, p_items jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v_r jsonb; v_sub numeric := pg_temp.suma(p_items);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_r := public.actualizar_compra_items(
      p_compra, p_items, v_sub, 0, v_sub, p_admin,
      p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb);
    EXECUTE 'RESET ROLE';
    RETURN v_r;
  END $f$;
  -- los vencimientos de la compra: [[producto, días desde hoy, cantidad], ...]
  CREATE FUNCTION pg_temp.vencimientos(p_compra bigint, p_lotes jsonb, p_hoy date) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_r jsonb;
    v_lotes jsonb := (SELECT COALESCE(jsonb_agg(jsonb_build_object('producto_id', (x->>0)::bigint,
                                                                   'fecha_vencimiento', p_hoy + (x->>1)::int,
                                                                   'cantidad', (x->>2)::int)), '[]'::jsonb)
                        FROM jsonb_array_elements(p_lotes) x);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_r := public.sincronizar_lotes_compra(p_compra, v_lotes);
    EXECUTE 'RESET ROLE';
    RETURN v_r;
  END $f$;
  CREATE FUNCTION pg_temp.exigir(p_r jsonb, p_que text) RETURNS bigint LANGUAGE plpgsql AS $f$
  BEGIN
    IF NOT COALESCE((p_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ENSAYO FALLÓ · % no entró: %', p_que, p_r;
    END IF;
    RETURN (p_r->>'compra_id')::bigint;
  END $f$;

  -- -------------------------------------------------------------------------
  -- A · el del issue: 100 corregida a 80, bolsa 0
  -- -------------------------------------------------------------------------
  v_p := pg_temp.producto(v_suc, 'ZZ ensayo 1516 A', 0);
  v_c := pg_temp.exigir(pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 100, 10)), v_hoy), 'A · el alta');
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 60, 100)), v_hoy);
  v_l := pg_temp.lote_de(v_c, v_p, v_hoy + 60);
  IF pg_temp.lote(v_l) <> '100/100' OR pg_temp.foto(v_p) <> '{"stock":100,"lotes":100,"bolsa":0}'::jsonb THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · A · el punto de partida no es lote 100/100 y bolsa 0: lote %, %', pg_temp.lote(v_l), pg_temp.foto(v_p);
  END IF;

  PERFORM pg_temp.exigir(pg_temp.editar(v_admin, v_c, jsonb_build_array(pg_temp.renglon(v_p, 80, 10))), 'A · la edición');
  IF pg_temp.lote(v_l) <> '80/80' OR pg_temp.foto(v_p) <> '{"stock":80,"lotes":80,"bolsa":0}'::jsonb THEN
    v_fallas := v_fallas || format('A · tras la edición esperaba lote 80/80 y bolsa 0; quedó lote %s, %s',
                                   pg_temp.lote(v_l), pg_temp.foto(v_p));
  END IF;
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 60, 80)), v_hoy);
  IF pg_temp.lote(v_l) <> '80/80' OR pg_temp.foto(v_p) <> '{"stock":80,"lotes":80,"bolsa":0}'::jsonb THEN
    v_fallas := v_fallas || format('A · con los vencimientos en 80 esperaba lote 80/80 y bolsa 0; quedó lote %s, %s',
                                   pg_temp.lote(v_l), pg_temp.foto(v_p));
  END IF;

  -- -------------------------------------------------------------------------
  -- B · con hueco, bolsa y el lote de otra compra que vence antes
  -- -------------------------------------------------------------------------
  v_p := pg_temp.producto(v_suc, 'ZZ ensayo 1516 B', 15);
  INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
  VALUES (v_p, v_suc, v_hoy + 30, 10, 10, 'manual') RETURNING id INTO v_m;
  v_c := pg_temp.exigir(pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 50, 10)), v_hoy), 'B · el alta');
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 90, 50)), v_hoy);
  v_l := pg_temp.lote_de(v_c, v_p, v_hoy + 90);
  -- salen 5 de L (una venta que bajó a ese lote): primero el lote y después el stock, así el trigger
  -- las saca de la bolsa que se acaba de agrandar y no consume ningún otro lote.
  UPDATE public.producto_lotes SET cantidad_restante = cantidad_restante - 5 WHERE id = v_l;
  UPDATE public.productos SET stock = stock - 5 WHERE id = v_p;
  IF pg_temp.lote(v_m) <> '10/10' OR pg_temp.lote(v_l) <> '50/45' OR pg_temp.foto(v_p) <> '{"stock":60,"lotes":55,"bolsa":5}'::jsonb THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · B · el punto de partida no es M 10/10, L 50/45, bolsa 5: M %, L %, %',
      pg_temp.lote(v_m), pg_temp.lote(v_l), pg_temp.foto(v_p);
  END IF;

  PERFORM pg_temp.exigir(pg_temp.editar(v_admin, v_c, jsonb_build_array(pg_temp.renglon(v_p, 30, 10))), 'B · la edición');
  IF pg_temp.lote(v_m) <> '10/10' THEN
    v_fallas := v_fallas || format('B · la edición le comió al lote de otra compra: M %s (esperaba 10/10)', pg_temp.lote(v_m));
  END IF;
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 90, 30)), v_hoy);
  IF pg_temp.lote(v_m) <> '10/10' OR pg_temp.lote(v_l) <> '30/25' OR pg_temp.foto(v_p) <> '{"stock":40,"lotes":35,"bolsa":5}'::jsonb THEN
    v_fallas := v_fallas || format('B · esperaba M 10/10, L 30/25, bolsa 5, stock 40; quedó M %s, L %s, %s',
                                   pg_temp.lote(v_m), pg_temp.lote(v_l), pg_temp.foto(v_p));
  END IF;

  -- -------------------------------------------------------------------------
  -- C · dos vencimientos, bolsa 0, se corrige a la mitad y se reparten 25 y 25
  -- -------------------------------------------------------------------------
  v_p := pg_temp.producto(v_suc, 'ZZ ensayo 1516 C', 0);
  v_c := pg_temp.exigir(pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 100, 10)), v_hoy), 'C · el alta');
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 30, 50), jsonb_build_array(v_p, 60, 50)), v_hoy);
  v_l := pg_temp.lote_de(v_c, v_p, v_hoy + 30);
  v_l2 := pg_temp.lote_de(v_c, v_p, v_hoy + 60);
  PERFORM pg_temp.exigir(pg_temp.editar(v_admin, v_c, jsonb_build_array(pg_temp.renglon(v_p, 50, 10))), 'C · la edición');
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 30, 25), jsonb_build_array(v_p, 60, 25)), v_hoy);
  IF pg_temp.lote(v_l) <> '25/25' OR pg_temp.lote(v_l2) <> '25/25' OR pg_temp.foto(v_p) <> '{"stock":50,"lotes":50,"bolsa":0}'::jsonb THEN
    v_fallas := v_fallas || format('C · esperaba los dos lotes 25/25 y bolsa 0; quedó %s y %s, %s',
                                   pg_temp.lote(v_l), pg_temp.lote(v_l2), pg_temp.foto(v_p));
  END IF;

  -- -------------------------------------------------------------------------
  -- D · sacar de la compra un producto que tiene su lote entero
  -- -------------------------------------------------------------------------
  v_p := pg_temp.producto(v_suc, 'ZZ ensayo 1516 D-P', 0);
  v_q := pg_temp.producto(v_suc, 'ZZ ensayo 1516 D-Q', 0);
  v_c := pg_temp.exigir(pg_temp.alta(v_admin,
           jsonb_build_array(pg_temp.renglon(v_p, 20, 10), pg_temp.renglon(v_q, 10, 10)), v_hoy), 'D · el alta');
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 45, 20)), v_hoy);
  v_l := pg_temp.lote_de(v_c, v_p, v_hoy + 45);
  v_r := pg_temp.editar(v_admin, v_c, jsonb_build_array(pg_temp.renglon(v_q, 10, 10)));
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D · la edición que saca a P se rechazó: %s', v_r->>'error');
  ELSE
    PERFORM pg_temp.vencimientos(v_c, '[]'::jsonb, v_hoy);
    IF pg_temp.lote(v_l) <> '-' OR pg_temp.foto(v_p) <> '{"stock":0,"lotes":0,"bolsa":0}'::jsonb
       OR pg_temp.foto(v_q) <> '{"stock":10,"lotes":0,"bolsa":10}'::jsonb THEN
      v_fallas := v_fallas || format('D · esperaba P sin lotes y stock 0, Q 10 en la bolsa; quedó lote %s, P %s, Q %s',
                                     pg_temp.lote(v_l), pg_temp.foto(v_p), pg_temp.foto(v_q));
    END IF;
  END IF;

  -- -------------------------------------------------------------------------
  -- E · al alza: no cambia
  -- -------------------------------------------------------------------------
  v_p := pg_temp.producto(v_suc, 'ZZ ensayo 1516 E', 0);
  v_c := pg_temp.exigir(pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 100, 10)), v_hoy), 'E · el alta');
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 60, 100)), v_hoy);
  v_l := pg_temp.lote_de(v_c, v_p, v_hoy + 60);
  PERFORM pg_temp.exigir(pg_temp.editar(v_admin, v_c, jsonb_build_array(pg_temp.renglon(v_p, 120, 10))), 'E · la edición');
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 60, 120)), v_hoy);
  IF pg_temp.lote(v_l) <> '120/120' OR pg_temp.foto(v_p) <> '{"stock":120,"lotes":120,"bolsa":0}'::jsonb THEN
    v_fallas := v_fallas || format('E · esperaba lote 120/120 y bolsa 0; quedó lote %s, %s', pg_temp.lote(v_l), pg_temp.foto(v_p));
  END IF;

  -- -------------------------------------------------------------------------
  -- F · STK-3: una compra con una nota de crédito no se edita
  -- -------------------------------------------------------------------------
  v_p := pg_temp.producto(v_suc, 'ZZ ensayo 1516 F', 0);
  v_c := pg_temp.exigir(pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 100, 10)), v_hoy), 'F · el alta');
  v_r := public.registrar_nota_credito(v_c, 'NC-1516', 'ensayo 1516', 300, 0, 300, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 30, 'costo_unitario', 10, 'subtotal', 300)), 0);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · F · la nota no entró: %', v_r;
  END IF;
  v_foto := pg_temp.foto(v_p);
  v_r := pg_temp.editar(v_admin, v_c, jsonb_build_array(pg_temp.renglon(v_p, 70, 10)));
  IF COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || 'F · editó una compra con una nota de crédito'::text;
  ELSIF position('nota(s) de crédito' IN COALESCE(v_r->>'error', '')) = 0 THEN
    v_fallas := v_fallas || format('F · rechazó, pero no por la nota: %s', v_r->>'error');
  END IF;
  IF pg_temp.foto(v_p) <> v_foto OR (SELECT SUM(cantidad) FROM public.compra_items WHERE compra_id = v_c) <> 100 THEN
    v_fallas := v_fallas || format('F · la edición rechazada dejó rastro: %s → %s', v_foto, pg_temp.foto(v_p));
  END IF;

  -- -------------------------------------------------------------------------
  -- G · STK-7: los vencimientos se validan contra la compra
  -- -------------------------------------------------------------------------
  v_p := pg_temp.producto(v_suc, 'ZZ ensayo 1516 G-P', 0);
  v_q := pg_temp.producto(v_suc, 'ZZ ensayo 1516 G-Q', 0);
  v_c := pg_temp.exigir(pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 10, 10)), v_hoy), 'G · el alta');
  BEGIN
    PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_q, 60, 5)), v_hoy);
    v_fallas := v_fallas || 'G · aceptó vencimientos de un producto que no está en la compra'::text;
  EXCEPTION WHEN raise_exception THEN
    EXECUTE 'RESET ROLE';
    IF position('no está en la compra' IN SQLERRM) = 0 THEN
      v_fallas := v_fallas || format('G · rechazó el producto ajeno, pero por otra cosa: %s', SQLERRM);
    END IF;
  END;
  BEGIN
    PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 60, 8), jsonb_build_array(v_p, 90, 3)), v_hoy);
    v_fallas := v_fallas || 'G · aceptó vencimientos por 11 sobre una compra de 10'::text;
  EXCEPTION WHEN raise_exception THEN
    EXECUTE 'RESET ROLE';
    IF position('suman 11 u.' IN SQLERRM) = 0 THEN
      v_fallas := v_fallas || format('G · rechazó los 11, pero por otra cosa: %s', SQLERRM);
    END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.producto_lotes WHERE producto_id IN (v_p, v_q)) THEN
    v_fallas := v_fallas || 'G · los vencimientos rechazados dejaron lotes'::text;
  END IF;
  -- y lo justo entra
  PERFORM pg_temp.vencimientos(v_c, jsonb_build_array(jsonb_build_array(v_p, 60, 7), jsonb_build_array(v_p, 90, 3)), v_hoy);
  IF (SELECT SUM(cantidad_restante) FROM public.producto_lotes WHERE producto_id = v_p) <> 10 THEN
    v_fallas := v_fallas || 'G · los vencimientos por 10 sobre una compra de 10 no quedaron'::text;
  END IF;

  -- -------------------------------------------------------------------------
  -- H · STK-9: el subtotal de cada renglón
  -- -------------------------------------------------------------------------
  v_p := pg_temp.producto(v_suc, 'ZZ ensayo 1516 H', 0);
  -- el bruto de un renglón bonificado (10 × 100 con 10 %: 900, mandado 1000), con la cabecera que cierra
  v_r := pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 10, 100, 10, 1000)), v_hoy);
  IF COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || 'H · el alta aceptó un renglón con el subtotal bruto'::text;
  ELSIF position('subtotal mal calculado' IN COALESCE(v_r->>'error', '')) = 0 THEN
    v_fallas := v_fallas || format('H · el alta rechazó el bruto, pero por otra cosa: %s', v_r->>'error');
  END IF;
  -- 0,02 corrido
  v_r := pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 3, 33.335, 0, 99.99)), v_hoy);
  IF COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || 'H · el alta aceptó un renglón corrido 0,02'::text;
  END IF;
  IF (SELECT stock FROM public.productos WHERE id = v_p) <> 0 THEN
    v_fallas := v_fallas || 'H · un alta rechazada dejó stock'::text;
  END IF;
  -- 0,01 entra (100,005 mandado como 100)
  v_r := pg_temp.alta(v_admin, jsonb_build_array(pg_temp.renglon(v_p, 3, 33.335, 0, 100)), v_hoy);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('H · el alta rechazó 0,01 de redondeo: %s', v_r->>'error');
  ELSE
    v_c := (v_r->>'compra_id')::bigint;
    v_r := pg_temp.editar(v_admin, v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, 100, 10, 1000)));
    IF COALESCE((v_r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || 'H · la edición aceptó un renglón con el subtotal bruto'::text;
    ELSIF position('subtotal mal calculado' IN COALESCE(v_r->>'error', '')) = 0 THEN
      v_fallas := v_fallas || format('H · la edición rechazó el bruto, pero por otra cosa: %s', v_r->>'error');
    END IF;
    PERFORM pg_temp.exigir(pg_temp.editar(v_admin, v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, 100, 10))),
                           'H · la edición con el subtotal neto');
  END IF;

 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'ENSAYO FALLÓ%' THEN
    RAISE;
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ · error inesperado: %', SQLERRM;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (todo revertido) · A, B, C, D, E, F, G y H';
END
$ensayo$;
