-- Ensayo de #1050 sobre la compra editada: anular una salvedad que devolvió
-- stock saca las unidades del MISMO lote al que volvieron aunque, entre la
-- salvedad y la anulación, se haya editado la compra del lote.
--
-- Editar una compra (sincronizar_lotes_compra, que la app llama en cada
-- edición) BORRA sus lotes y los vuelve a crear con ids nuevos, conservando lo
-- consumido por (compra, producto, vencimiento). La 328 anota en
-- salvedades_items.lotes_devueltos el id del lote; con la compra editada ese id
-- ya no existe y la anulación come de la bolsa: lote +N, bolsa -N, el mismo bug
-- de #1050 por otra puerta. La 331 anota también la compra y el vencimiento y
-- busca el lote por esa clave cuando el id ya no está.
--
-- Corre contra prod SIN dejar rastro: todo termina en un RAISE EXCEPTION, así
-- que lo que crea (productos, lotes, compras, pedidos, salvedades) se deshace.
-- Las funciones auxiliares van en pg_temp. Bolsa 40, no 0: con bolsa 0 la
-- bajada cae en el lote por FEFO y da bien por casualidad (así se escondió el
-- bug en el ensayo de la 316).
--
-- Corre además toda la batería de #1050, para que la 331 no rompa nada:
--   M · los cinco motivos que devuelven stock, línea parcial (pedido 20,
--       salvedad 10). Después de anular, lote y bolsa = después del pedido.
--   T · línea entera (pedido 10, salvedad 10: la línea se borra y la anulación
--       la vuelve a insertar).
--   P · el lote tenía hueco para 5 de las 10: 5 vuelven al lote y 5 a la bolsa.
--   D · dos lotes: el que vence antes está lleno, la devolución entra al
--       segundo. Anular la saca del segundo, no del primero por FEFO.
--   C · la compra del lote se edita entre la salvedad y la anulación (el lote
--       se recrea con otro id): anular saca del lote igual. Contra la 328
--       sola: lote 60 / bolsa 10 en vez de 50 / 20.
--   L · una salvedad sin anotación (lotes_devueltos NULL, las anteriores a la
--       328): anular sigue funcionando por el camino de antes y el stock cierra.
--   R · el reintento idempotente: sin sesión no devuelve datos, y
--       `merma_registrada` dice lo que pasó.
--
-- Veredicto en el mensaje del error final: 'ENSAYO OK …' o 'ENSAYO FALLÓ …'.
--
--   psql "$DATABASE_URL" -f scripts/test-anular-salvedad-compra-editada.sql

CREATE OR REPLACE FUNCTION pg_temp.foto_1050(p_prod bigint)
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT jsonb_build_object(
    'stock', pr.stock,
    'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                         FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
    'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                    FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int)
    FROM public.productos pr
   WHERE pr.id = p_prod;
$fn$;

-- Arma un producto con `p_lotes` ([{dias, cantidad, restante}, ...]) y
-- `p_bolsa` unidades sin lote, carga un pedido de `p_pedido`, registra una
-- salvedad de `p_salv` con `p_motivo` y la anula. Devuelve las tres fotos.
-- Con `p_sin_huella` deja lotes_devueltos en NULL antes de anular, como si la
-- salvedad fuera anterior a la 328. Con `p_editar_compra` el lote cuelga de
-- una compra que se edita (mismos vencimientos) antes de anular.
CREATE OR REPLACE FUNCTION pg_temp.caso_1050(
  p_cliente bigint, p_admin uuid, p_suc bigint,
  p_motivo text, p_lotes jsonb, p_bolsa int, p_pedido int, p_salv int,
  p_sin_huella boolean DEFAULT false,
  p_editar_compra boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_hoy  date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_prod bigint;
  v_ped  bigint;
  v_item bigint;
  v_salv bigint;
  v_compra bigint;
  v_res  jsonb;
  v_out  jsonb := '{}'::jsonb;
  l      jsonb;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1050 ' || p_motivo, 100,
          p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;

  IF p_editar_compra THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
  END IF;

  FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante,
                                       usuario_id, compra_id)
    VALUES (v_prod, p_suc, v_hoy + (l->>'dias')::int, (l->>'cantidad')::int, (l->>'restante')::int,
            p_admin, v_compra);
  END LOOP;

  v_res := public.crear_pedido_completo(
    p_cliente, p_pedido * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', p_pedido, 'precio_unitario', 100)),
    'ensayo 1050');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ens1050 · no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO v_item FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  v_out := v_out || jsonb_build_object('pedido', pg_temp.foto_1050(v_prod));

  v_res := public.registrar_salvedad(v_ped, v_item, p_salv, p_motivo,
                                     'ensayo 1050: descripcion del caso', NULL, true, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false)
     OR NOT COALESCE((v_res->>'stock_devuelto')::boolean, false) THEN
    RAISE EXCEPTION 'ens1050 · registrar % : %', p_motivo, v_res;
  END IF;
  v_salv := (v_res->>'salvedad_id')::bigint;
  v_out := v_out || jsonb_build_object('salvedad', pg_temp.foto_1050(v_prod));

  IF p_sin_huella THEN
    UPDATE public.salvedades_items SET lotes_devueltos = NULL WHERE id = v_salv;
  END IF;

  -- Editar la compra con los mismos vencimientos: sincronizar_lotes_compra
  -- borra los lotes y los recrea con ids nuevos, conservando lo consumido.
  IF p_editar_compra THEN
    v_res := public.sincronizar_lotes_compra(v_compra, (
      SELECT jsonb_agg(jsonb_build_object('producto_id', producto_id,
                                          'fecha_vencimiento', fecha_vencimiento,
                                          'cantidad', cantidad))
        FROM public.producto_lotes WHERE compra_id = v_compra));
    IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'ens1050 · no se pudo editar la compra: %', v_res;
    END IF;
  END IF;

  v_res := public.anular_salvedad(v_salv, 'ensayo 1050');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ens1050 · anular % : %', p_motivo, v_res;
  END IF;
  v_out := v_out || jsonb_build_object(
    'anulada', pg_temp.foto_1050(v_prod),
    'linea', (SELECT COALESCE(SUM(cantidad), 0) FROM public.pedido_items
               WHERE pedido_id = v_ped AND producto_id = v_prod));
  RETURN v_out;
END;
$fn$;

DO $ensayo1050$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_fallas  text[] := '{}';
  v_caso    jsonb;
  v_motivo  text;
  v_res     jsonb;
  v_res2    jsonb;
  v_prod    bigint;
  v_promo   bigint;
  v_ped     bigint;
  v_item    bigint;
  v_uuid    uuid;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens1050 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1050 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  -- M · los cinco motivos. Lote 100 con 50 vivas, bolsa 40.
  --     Pedido 20 sale de la bolsa: {stock 70, lote 50, bolsa 20}.
  --     Salvedad 10 vuelve al lote:  {stock 80, lote 60, bolsa 20}.
  --     Anular tiene que volver a    {stock 70, lote 50, bolsa 20}.
  FOREACH v_motivo IN ARRAY ARRAY['otro', 'entregado_otro_cliente', 'cliente_rechaza',
                                  'error_pedido', 'diferencia_precio'] LOOP
    v_caso := NULL;
    BEGIN
      v_caso := pg_temp.caso_1050(v_cliente, v_admin, v_suc, v_motivo,
                                  '[{"dias":90,"cantidad":100,"restante":50}]', 40, 20, 10);
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('M %s · error: %s', v_motivo, SQLERRM);
    END;
    IF v_caso IS NOT NULL THEN
      IF v_caso->'pedido' <> '{"stock":70,"lotes":[50],"bolsa":20}'::jsonb
         OR v_caso->'salvedad' <> '{"stock":80,"lotes":[60],"bolsa":20}'::jsonb THEN
        v_fallas := v_fallas || format('M %s · el punto de partida no es el esperado: %s', v_motivo, v_caso);
      ELSIF v_caso->'anulada' <> v_caso->'pedido' OR (v_caso->>'linea')::int <> 20 THEN
        v_fallas := v_fallas || format('M %s · anular dejó %s; después del pedido era %s',
                                       v_motivo, v_caso->'anulada', v_caso->'pedido');
      END IF;
    END IF;
  END LOOP;

  -- T · la línea entera: pedido 10, salvedad 10. La línea se borra y la
  --     anulación la vuelve a insertar.
  v_caso := NULL;
  BEGIN
    v_caso := pg_temp.caso_1050(v_cliente, v_admin, v_suc, 'otro',
                                '[{"dias":90,"cantidad":100,"restante":50}]', 40, 10, 10);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('T · error: %s', SQLERRM);
  END;
  IF v_caso IS NOT NULL THEN
    IF v_caso->'pedido' <> '{"stock":80,"lotes":[50],"bolsa":30}'::jsonb
       OR v_caso->'salvedad' <> '{"stock":90,"lotes":[60],"bolsa":30}'::jsonb THEN
      v_fallas := v_fallas || format('T · el punto de partida no es el esperado: %s', v_caso);
    ELSIF v_caso->'anulada' <> v_caso->'pedido' OR (v_caso->>'linea')::int <> 10 THEN
      v_fallas := v_fallas || format('T · anular dejó %s; después del pedido era %s',
                                     v_caso->'anulada', v_caso->'pedido');
    END IF;
  END IF;

  -- P · hueco para 5: lote 100 con 95 vivas, bolsa 40. Pedido 10 de la bolsa:
  --     {125, [95], 30}. Salvedad 10: 5 al lote y 5 a la bolsa {135, [100], 35}.
  --     Anular: 5 de cada lado, {125, [95], 30}.
  v_caso := NULL;
  BEGIN
    v_caso := pg_temp.caso_1050(v_cliente, v_admin, v_suc, 'cliente_rechaza',
                                '[{"dias":90,"cantidad":100,"restante":95}]', 40, 10, 10);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P · error: %s', SQLERRM);
  END;
  IF v_caso IS NOT NULL THEN
    IF v_caso->'pedido' <> '{"stock":125,"lotes":[95],"bolsa":30}'::jsonb
       OR v_caso->'salvedad' <> '{"stock":135,"lotes":[100],"bolsa":35}'::jsonb THEN
      v_fallas := v_fallas || format('P · el punto de partida no es el esperado: %s', v_caso);
    ELSIF v_caso->'anulada' <> v_caso->'pedido' THEN
      v_fallas := v_fallas || format('P · anular dejó %s; después del pedido era %s',
                                     v_caso->'anulada', v_caso->'pedido');
    END IF;
  END IF;

  -- D · dos lotes: el que vence a 30 días está lleno (50/50), el de 90 tiene
  --     50 de 100. Bolsa 40. Pedido 20 de la bolsa: {120, [50,50], 20}.
  --     La salvedad entra al de 90 (el de 30 no tiene hueco): {130, [50,60], 20}.
  --     Anular la saca del de 90: {120, [50,50], 20}. Sacarla "por FEFO" la
  --     sacaría del de 30 y dejaría [40,60] con los totales bien.
  v_caso := NULL;
  BEGIN
    v_caso := pg_temp.caso_1050(v_cliente, v_admin, v_suc, 'error_pedido',
                                '[{"dias":30,"cantidad":50,"restante":50},{"dias":90,"cantidad":100,"restante":50}]',
                                40, 20, 10);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D · error: %s', SQLERRM);
  END;
  IF v_caso IS NOT NULL THEN
    IF v_caso->'pedido' <> '{"stock":120,"lotes":[50,50],"bolsa":20}'::jsonb
       OR v_caso->'salvedad' <> '{"stock":130,"lotes":[50,60],"bolsa":20}'::jsonb THEN
      v_fallas := v_fallas || format('D · el punto de partida no es el esperado: %s', v_caso);
    ELSIF v_caso->'anulada' <> v_caso->'pedido' THEN
      v_fallas := v_fallas || format('D · anular dejó %s; después del pedido era %s',
                                     v_caso->'anulada', v_caso->'pedido');
    END IF;
  END IF;

  -- C · la compra del lote se edita entre la salvedad y la anulación: el lote
  --     se recrea con otro id. Anular igual tiene que sacar del lote, por su
  --     clave (compra, producto, vencimiento).
  v_caso := NULL;
  BEGIN
    v_caso := pg_temp.caso_1050(v_cliente, v_admin, v_suc, 'cliente_rechaza',
                                '[{"dias":90,"cantidad":100,"restante":50}]', 40, 20, 10, false, true);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C · error: %s', SQLERRM);
  END;
  IF v_caso IS NOT NULL THEN
    IF v_caso->'pedido' <> '{"stock":70,"lotes":[50],"bolsa":20}'::jsonb
       OR v_caso->'salvedad' <> '{"stock":80,"lotes":[60],"bolsa":20}'::jsonb THEN
      v_fallas := v_fallas || format('C · el punto de partida no es el esperado: %s', v_caso);
    ELSIF v_caso->'anulada' <> v_caso->'pedido' THEN
      v_fallas := v_fallas || format('C · con la compra editada, anular dejó %s; después del pedido era %s',
                                     v_caso->'anulada', v_caso->'pedido');
    END IF;
  END IF;

  -- L · sin huella: el stock vuelve a 70 y la línea a 20, por el camino de
  --     siempre (bolsa primero). No se mira cómo quedan lote y bolsa: sin
  --     huella no hay de dónde saberlo.
  v_caso := NULL;
  BEGIN
    v_caso := pg_temp.caso_1050(v_cliente, v_admin, v_suc, 'otro',
                                '[{"dias":90,"cantidad":100,"restante":50}]', 40, 20, 10, true);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('L · error: %s', SQLERRM);
  END;
  IF v_caso IS NOT NULL
     AND ((v_caso->'anulada'->>'stock')::int <> 70 OR (v_caso->>'linea')::int <> 20) THEN
    v_fallas := v_fallas || format('L · sin huella, anular dejó %s (línea %s)', v_caso->'anulada', v_caso->>'linea');
  END IF;

  -- R · el reintento idempotente.
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1050 R', 100, 100, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
    VALUES ('ZZ ensayo 1050 R', 'bonificacion', CURRENT_DATE, v_suc, false, v_prod)
    RETURNING id INTO v_promo;

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo 1050 R');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens1050 · R · no se pudo crear el pedido: %', v_res;
    END IF;
    v_ped := (v_res->>'pedido_id')::bigint;

    -- El regalo de una promo con regalo_mueve_stock = false: nunca tocó stock.
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                              sucursal_id, es_bonificacion, promocion_id)
    VALUES (v_ped, v_prod, 2, 0, 0, v_suc, true, v_promo)
    RETURNING id INTO v_item;

    v_uuid := gen_random_uuid();
    v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado',
                                       'ensayo 1050 R: regalo roto', NULL, true, v_uuid);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ens1050 · R · registrar: %', v_res;
    END IF;
    IF COALESCE((v_res->>'merma_registrada')::boolean, true)
       OR EXISTS (SELECT 1 FROM mermas_stock WHERE producto_id = v_prod) THEN
      RAISE EXCEPTION 'ens1050 · R · el regalo que no mueve stock generó merma: %', v_res;
    END IF;

    -- R1 · el reintento dice lo mismo que la primera respuesta.
    v_res2 := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado',
                                        'ensayo 1050 R: regalo roto', NULL, true, v_uuid);
    IF NOT COALESCE((v_res2->>'idempotent_replay')::boolean, false) THEN
      v_fallas := v_fallas || format('R1 · el reintento no se reconoció como tal: %s', v_res2);
    ELSIF (v_res2->>'merma_registrada') IS DISTINCT FROM (v_res->>'merma_registrada') THEN
      v_fallas := v_fallas || format('R1 · merma_registrada: la primera respuesta dijo %s y el reintento %s',
                                     v_res->>'merma_registrada', v_res2->>'merma_registrada');
    END IF;

    -- R2 · sin sesión, el uuid solo no alcanza para leer la salvedad.
    PERFORM set_config('request.jwt.claims', '{}', true);
    v_res2 := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado',
                                        'ensayo 1050 R: regalo roto', NULL, true, v_uuid);
    IF COALESCE((v_res2->>'success')::boolean, false) OR v_res2 ? 'salvedad_id' THEN
      v_fallas := v_fallas || format('R2 · sin sesión el reintento devolvió la salvedad: %s', v_res2);
    END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R · error: %s', SQLERRM);
  END;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (todo revertido)';
END
$ensayo1050$;
