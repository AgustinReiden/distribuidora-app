-- Ensayo de la tarjeta B1c de la ola 2 del plan #1603
-- (migrations/NNN_promo_con_pedidos_no_se_borra_y_prorrateo_de_combos.sql):
-- 1556-b1 y 1556-b3 de #1556, 1592-b4 de #1592 y la foto de la línea que
-- `_combo_trasladar` borra (lo que dejó la ola 1).
--
--   P1 · [F] 1556-b1. Promo de unidad entera con un pedido abierto que lleva su
--        regalo. El admin la borra por REST: se rechaza con el mensaje que ofrece
--        desactivarla, la promo sigue, la línea conserva su promo y la foto del
--        pedido (pedido_promo_reglas) sigue ahí.
--   P2 · [F] una promo sin pedidos pero con un ajuste de stock: se rechaza.
--   P3 · [F] una promo cuyo regalo se lo llevó una salvedad (la línea ya no está;
--        queda la salvedad con la promo): se rechaza.
--   P4 · [R] una promo sin uso se borra, con sus reglas y sus productos; y una con
--        pedidos se puede desactivar (lo que ofrece el rechazo).
--   P5 · [F] la función de la guarda es de server: definer, sin EXECUTE para
--        authenticated ni anon, y el trigger es BEFORE DELETE.
--   K1 · [F] 1592-b4. Fernet $10.000 + caramelo $0,01 en un combo de $4.000:
--        3.999,99 + 0,01 (antes 4.000 + 0, el caramelo gratis).
--   K2 · [F] 3 Fernet + 2 caramelos a $1.500 (el reparto de #1259 con la
--        absorbente en la línea barata): 499,98 + 0,03.
--   K3 · [F] 2 Fernet + 3 caramelos de $0,02 a $8.000: 3.999,97 + 0,02.
--   K4 · [F] tres líneas, dos de centavos: 2.999,96 + 2 × 0,01 + 0,02.
--   K5 · [R] un solo componente (7 × $0,01 por $0,07; 3 × $1.000 por $2.400) y
--        una cantidad escrita 1.0: el reparto de siempre.
--   K6 · [R] sin reparto posible con un centavo por línea: NULL (2 × a + 3 × b
--        = 6 centavos no tiene solución con a, b >= 1; 4 líneas por $0,03).
--   K7 · [F] una grilla de 4.000 combos (1 a 3 líneas, cantidades 1 a 4,
--        referencias de centavos y de miles, totales de centavos y de miles):
--        todo reparto cierra al centavo contra el total y ninguna línea queda
--        por debajo de $0,01; y donde el cuerpo anterior no dejaba ninguna en
--        $0, el reparto es idéntico al de antes (una copia del cuerpo
--        anterior, pg_temp.k_prorrateo_viejo).
--   K8 · [F] el alta de un pedido con ese combo a 3.999,99 + 0,01 pasa (antes
--        el server recalculaba 4.000 + 0 y la rechazaba); ninguna línea en $0.
--   K9 · [F] H3 de la revisión. Un combo sin reparto (2 A + 3 B por $0,06): el
--        alta del encargado se rechaza diciendo que el combo no se puede
--        repartir a ese precio, no «recargá la app».
--   C1 · [F] 1556-b3. `_combo_cantidad` con cantidades escritas 1.0 y 2.0 da lo
--        mismo que con 1 y 2 (antes NULL; el TS ya las aceptaba).
--   C2 · [R] una cantidad 1.5 sigue dando NULL.
--   T1 · [F] la línea que `_combo_trasladar` borra guarda su foto. Tres combos
--        Fernet + Coca; el cliente rechaza 2 Fernet (la Coca queda 1 en el combo
--        y 2 afuera); S0 rompe 1 Coca de afuera; la Coca sube de costo; S1
--        rechaza 2 Cocas sobre la del combo (que tiene 1): la otra se le fusiona
--        y se borra. S0 tiene foto con el costo de la venta, y anularla devuelve
--        la Coca con ese costo, no con el de hoy.
--   G1 · los gates PRECIO-A, COSTO-D, STK-F y SEG-A en 0.
--
-- [F] falla sin la migración y pasa con ella; [R] pasa antes y después.
-- Arma su propio cliente, productos, promos y combos en la primera sucursal
-- activa de un admin activo (y un encargado en auth.users para K8). Cada caso
-- corre en un sub-bloque que se revierte, y el DO termina siempre en una
-- excepción: no deja nada. El veredicto es esa excepción, 'ENSAYO OK (18
-- casos)' o 'ENSAYO FALLO (n fallas)' con la lista. En una base local, nunca
-- contra prod (escribe en auth.users):
--
--   tr -d '\r' < scripts/test-promos-combos-ola2-1603.sql \
--     | docker exec -i <contenedor> psql -U postgres -d postgres -q

SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT public._tablero_hoy();
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$f$;

-- Corre p_sql como el front (rol authenticated, JWT de p_user): 'OK: <resultado>'
-- o 'ERR <sqlstate>: <mensaje>'.
CREATE OR REPLACE FUNCTION pg_temp.t_rest(p_user uuid, p_suc bigint, p_sql text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v text;
BEGIN
  PERFORM pg_temp.t_claims(p_user, p_suc);
  BEGIN
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN 'OK: ' || COALESCE(v, 'null');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN 'ERR ' || SQLSTATE || ': ' || SQLERRM;
  END;
END
$f$;

CREATE OR REPLACE FUNCTION pg_temp.t_cli(p_suc bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo B1c', 'ZZ ensayo B1c', 'Calle Falsa 123', p_suc)
  RETURNING id;
$fn$;

-- Un producto con lista p_lista, costo 60 % y un lote de 100 (bolsa 0).
CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_admin uuid, p_nombre text, p_lista numeric)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo B1c ' || p_nombre, p_lista, 100, round(p_lista * 0.6, 2), p_suc, 'ZZ ensayo B1c')
  RETURNING id INTO v_prod;
  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
  INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                     cantidad_restante, usuario_id, compra_id)
  VALUES (v_prod, p_suc, pg_temp.t_hoy() + 90, 100, 100, p_admin, v_compra);
  RETURN v_prod;
END
$fn$;

-- Promo de unidad entera "p_compra de p_venta dan p_bonif de p_regalo".
CREATE OR REPLACE FUNCTION pg_temp.t_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_compra int, p_bonif int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo B1c promo', 'bonificacion', pg_temp.t_hoy() - 1, p_suc, true, p_regalo)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc), (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_venta, p_suc);
  RETURN v_promo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_combo(p_precio numeric, p_comp jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.guardar_combo(jsonb_build_object('nombre', 'ZZ ensayo B1c', 'precio', p_precio,
                                                   'fecha_inicio', pg_temp.t_hoy(), 'componentes', p_comp));
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el combo: %', v_res;
  END IF;
  RETURN (v_res->>'id')::bigint;
END
$fn$;

-- Alta como p_user; las líneas en el formato de crear_pedido_completo.
CREATE OR REPLACE FUNCTION pg_temp.t_alta(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_tot numeric;
BEGIN
  PERFORM pg_temp.t_claims(p_user, p_suc);
  SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
    FROM jsonb_array_elements(p_items) e;
  v_res := public.crear_pedido_completo(p_cli, v_tot, p_user, p_items, 'ensayo B1c');
  PERFORM pg_temp.t_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_alta_ok(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb := pg_temp.t_alta(p_cli, p_user, p_suc, p_items);
BEGIN
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'alta fallo: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Una salvedad es de un pedido que ya salió: con la regla de B1 (D23 del dueño)
-- registrar_salvedad rechaza uno pendiente o en preparación (pedido_sin_salir).
-- Los casos que registran salvedades pasan el pedido a 'asignado' antes.
CREATE OR REPLACE FUNCTION pg_temp.t_asignar(p_ped bigint)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.pedidos SET estado = 'asignado' WHERE id = p_ped;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                     'ensayo B1c: descripcion del caso', NULL, true, NULL);
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar % (item %, %): %', p_motivo, p_item, p_cant, v_res;
  END IF;
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_anular(p_salv bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.anular_salvedad(p_salv, 'ensayo B1c');
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular %: %', p_salv, v_res;
  END IF;
END
$fn$;

-- Las líneas de venta de un producto: "cantidad@precio[c|r]" por id.
CREATE OR REPLACE FUNCTION pg_temp.t_lineas(p_ped bigint, p_prod bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(cantidad || '@' || trim(to_char(precio_unitario, 'FM999999990.00'))
                             || CASE WHEN combo_id IS NOT NULL THEN 'c'
                                     WHEN combo_roto_id IS NOT NULL THEN 'r' ELSE '' END,
                             ' ' ORDER BY id), '-')
    FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND NOT COALESCE(es_bonificacion, false);
$fn$;

-- Un reparto: el mapa de _combo_prorrateo como "id=precio" ordenado por id.
CREATE OR REPLACE FUNCTION pg_temp.t_reparto(p_total numeric, p_lineas jsonb)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE((SELECT string_agg(key || '=' || trim(to_char((value #>> '{}')::numeric, 'FM999999990.00')), ' '
                                     ORDER BY key::bigint)
                     FROM jsonb_each(public._combo_prorrateo(p_total, p_lineas))), 'null');
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_l(p_id int, p_q numeric, p_ref numeric)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_id, 'cantidad', p_q, 'ref', p_ref);
$fn$;

-- El cuerpo de _combo_prorrateo de antes de la NNN (md5 3eff1124...), para K7:
-- donde no dejaba ninguna línea en $0, el reparto nuevo tiene que ser idéntico.
CREATE OR REPLACE FUNCTION pg_temp.k_prorrateo_viejo(p_total numeric, p_lineas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_ids   bigint[];
  v_q     numeric[];
  v_c     numeric[];
  v_u     numeric[];
  v_otras integer[];
  n       integer;
  i       integer;
  k       integer;
  m       integer;
  v_j     integer;
  v_t     numeric := round(p_total * 100);
  v_r     numeric := 0;
  v_suma  numeric := 0;
  v_resto numeric;
  v_g     numeric := 0;
  v_x     numeric;
  v_y     numeric;
  v_falta numeric;
BEGIN
  IF jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' OR v_t IS NULL OR v_t <= 0 THEN
    RETURN NULL;
  END IF;
  SELECT array_agg(NULLIF(e->>'producto_id', '')::bigint ORDER BY o),
         array_agg(NULLIF(e->>'cantidad', '')::numeric ORDER BY o),
         array_agg(round(NULLIF(e->>'ref', '')::numeric * 100) ORDER BY o)
    INTO v_ids, v_q, v_c
    FROM jsonb_array_elements(p_lineas) WITH ORDINALITY AS t(e, o);
  n := COALESCE(cardinality(v_ids), 0);
  IF n = 0 THEN RETURN NULL; END IF;
  FOR i IN 1..n LOOP
    IF v_ids[i] IS NULL OR v_q[i] IS NULL OR v_q[i] <= 0 OR v_q[i] <> trunc(v_q[i])
       OR v_c[i] IS NULL OR v_c[i] <= 0 THEN
      RETURN NULL;
    END IF;
    v_r := v_r + v_q[i] * v_c[i];
    v_g := gcd(v_g, v_q[i]);
  END LOOP;
  -- #1259: sin el mcd de las cantidades dividiendo el total, no hay precios
  -- unitarios que lo den exacto ("2 por $999,99").
  IF mod(v_t, v_g) <> 0 THEN
    RETURN NULL;
  END IF;

  v_u := array_fill(0::numeric, ARRAY[n]);
  FOR i IN 1..n LOOP
    v_u[i] := div(2 * v_t * v_c[i] + v_r, 2 * v_r);
    v_suma := v_suma + v_q[i] * v_u[i];
  END LOOP;

  v_resto := v_t - v_suma;
  IF v_resto <> 0 THEN
    SELECT s.i INTO v_j
      FROM generate_subscripts(v_ids, 1) AS s(i)
     WHERE mod(v_resto, v_q[s.i]) = 0
     ORDER BY v_c[s.i] DESC, v_ids[s.i]
     LIMIT 1;
    IF v_j IS NOT NULL THEN
      v_u[v_j] := v_u[v_j] + div(v_resto, v_q[v_j]);
    ELSE
      -- #1259: ninguna línea sola divide el resto. Absorbe la de menor cantidad
      -- (a igual, la más cara; después el id); antes, cada una de las otras, de
      -- la más cara a la más barata, toma el precio más cercano a su proporción
      -- (T·c/R) que deja el resto divisible por el mcd de las cantidades que
      -- vienen después. A igual distancia, el mayor.
      SELECT s.i INTO v_j
        FROM generate_subscripts(v_ids, 1) AS s(i)
       ORDER BY v_q[s.i], v_c[s.i] DESC, v_ids[s.i]
       LIMIT 1;
      SELECT array_agg(s.i ORDER BY v_c[s.i] DESC, v_ids[s.i]) INTO v_otras
        FROM generate_subscripts(v_ids, 1) AS s(i)
       WHERE s.i <> v_j;
      v_falta := v_t;
      FOR k IN 1..COALESCE(cardinality(v_otras), 0) LOOP
        i := v_otras[k];
        v_g := v_q[v_j];
        FOR m IN k + 1..cardinality(v_otras) LOOP
          v_g := gcd(v_g, v_q[v_otras[m]]);
        END LOOP;
        v_x := v_u[i];
        WHILE mod(v_falta - v_q[i] * v_x, v_g) <> 0 LOOP
          v_x := v_x + 1;
        END LOOP;
        v_y := v_x - div(v_g, gcd(v_q[i], v_g));
        IF abs(v_y * v_r - v_t * v_c[i]) < abs(v_x * v_r - v_t * v_c[i]) THEN
          v_x := v_y;
        END IF;
        v_u[i] := v_x;
        v_falta := v_falta - v_q[i] * v_x;
      END LOOP;
      v_u[v_j] := div(v_falta, v_q[v_j]);
    END IF;
  END IF;

  RETURN (SELECT jsonb_object_agg(v_ids[s.i]::text, round(v_u[s.i] / 100, 2))
            FROM generate_subscripts(v_ids, 1) AS s(i));
END
$function$
;

CREATE OR REPLACE FUNCTION pg_temp.t_usuario(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b1c-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'b1c ' || p_rol), now(), now());
  RETURN v;
END
$f$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- Una promo 10 + 2 y un pedido abierto con su regalo.
CREATE OR REPLACE FUNCTION pg_temp.t_promo_con_pedido(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_v bigint; v_r bigint; v_promo bigint; v_ped bigint;
BEGIN
  v_v := pg_temp.t_prod(p_suc, p_adm, 'Venta', 100);
  v_r := pg_temp.t_prod(p_suc, p_adm, 'Regalo', 100);
  v_promo := pg_temp.t_promo(p_suc, v_v, v_r, 10, 2);
  v_ped := pg_temp.t_alta_ok(p_cli, p_adm, p_suc, jsonb_build_array(
    jsonb_build_object('producto_id', v_v, 'cantidad', 10, 'precio_unitario', 100),
    jsonb_build_object('producto_id', v_r, 'cantidad', 2, 'precio_unitario', 0,
                       'es_bonificacion', true, 'promocion_id', v_promo)));
  RETURN jsonb_build_object('v', v_v, 'r', v_r, 'promo', v_promo, 'pedido', v_ped,
    'regalo', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_r));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; f text[] := '{}'; v text;
BEGIN
  b := pg_temp.t_promo_con_pedido(p_cli, p_adm, p_suc);
  v := pg_temp.t_rest(p_adm, p_suc, format('WITH d AS (DELETE FROM public.promociones WHERE id = %s RETURNING 1) SELECT count(*)::text FROM d', b->>'promo'));
  f := pg_temp.t_si(f, v LIKE 'ERR P0001: No se puede eliminar la promoción «ZZ ensayo B1c promo»: la usan 1 pedido.%Desactivala%',
                    format('borrar la promo con un pedido abierto: %s; esperado el rechazo que ofrece desactivarla', v));
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.promociones WHERE id = (b->>'promo')::bigint),
                    'la promo ya no está');
  f := pg_temp.t_si(f, (SELECT promocion_id FROM public.pedido_items WHERE id = (b->>'regalo')::bigint) = (b->>'promo')::bigint,
                    'la línea de regalo perdió su promo');
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.pedido_promo_reglas
                                WHERE pedido_id = (b->>'pedido')::bigint AND promocion_id = (b->>'promo')::bigint),
                    'el pedido perdió la foto de la promo (pedido_promo_reglas)');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_v bigint; v_promo bigint; f text[] := '{}'; v text;
BEGIN
  v_v := pg_temp.t_prod(p_suc, p_adm, 'Venta', 100);
  v_promo := pg_temp.t_promo(p_suc, v_v, v_v, 10, 1);
  INSERT INTO public.promo_ajustes (promocion_id, usos_ajustados, usuario_id, observaciones, sucursal_id)
  VALUES (v_promo, 1, p_adm, 'ensayo B1c', p_suc);
  v := pg_temp.t_rest(p_adm, p_suc, format('WITH d AS (DELETE FROM public.promociones WHERE id = %s RETURNING 1) SELECT count(*)::text FROM d', v_promo));
  f := pg_temp.t_si(f, v LIKE 'ERR P0001: No se puede eliminar la promoción%la usan 1 ajuste de stock.%',
                    format('borrar una promo con un ajuste de stock: %s', v));
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.promo_ajustes WHERE promocion_id = v_promo) = 1,
                    'se perdió el ajuste de stock');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; f text[] := '{}'; v text; v_salv bigint;
BEGIN
  b := pg_temp.t_promo_con_pedido(p_cli, p_adm, p_suc);
  PERFORM pg_temp.t_claims(p_adm, p_suc);
  PERFORM pg_temp.t_asignar((b->>'pedido')::bigint);
  v_salv := pg_temp.t_salvedad((b->>'pedido')::bigint, (b->>'regalo')::bigint, 2, 'faltante_stock');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pedido_items WHERE promocion_id = (b->>'promo')::bigint),
                    'el regalo tendría que haberse ido de pedido_items');
  v := pg_temp.t_rest(p_adm, p_suc, format('WITH d AS (DELETE FROM public.promociones WHERE id = %s RETURNING 1) SELECT count(*)::text FROM d', b->>'promo'));
  f := pg_temp.t_si(f, v LIKE 'ERR P0001: No se puede eliminar la promoción%la usan 1 salvedad.%',
                    format('borrar una promo cuyo regalo está en una salvedad: %s', v));
  f := pg_temp.t_si(f, (SELECT promocion_id FROM public.salvedades_items WHERE id = v_salv) = (b->>'promo')::bigint,
                    'la salvedad perdió su promo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_v bigint; v_promo bigint; f text[] := '{}'; v text;
BEGIN
  v_v := pg_temp.t_prod(p_suc, p_adm, 'Venta', 100);
  v_promo := pg_temp.t_promo(p_suc, v_v, v_v, 10, 1);
  v := pg_temp.t_rest(p_adm, p_suc, format('WITH d AS (DELETE FROM public.promociones WHERE id = %s RETURNING 1) SELECT count(*)::text FROM d', v_promo));
  f := pg_temp.t_si(f, v = 'OK: 1', format('borrar una promo sin uso: %s, esperado OK: 1', v));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.promocion_reglas WHERE promocion_id = v_promo)
                       AND NOT EXISTS (SELECT 1 FROM public.promocion_productos WHERE promocion_id = v_promo),
                    'las reglas o los productos de la promo borrada siguen ahí');
  b := pg_temp.t_promo_con_pedido(p_cli, p_adm, p_suc);
  v := pg_temp.t_rest(p_adm, p_suc, format('WITH u AS (UPDATE public.promociones SET activo = false WHERE id = %s RETURNING 1) SELECT count(*)::text FROM u', b->>'promo'));
  f := pg_temp.t_si(f, v = 'OK: 1', format('desactivar una promo con pedidos: %s, esperado OK: 1', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  f := pg_temp.t_si(f, to_regprocedure('public.promocion_no_se_borra_con_uso()') IS NOT NULL
                       AND (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.promocion_no_se_borra_con_uso()'))
                       AND NOT has_function_privilege('authenticated', 'public.promocion_no_se_borra_con_uso()', 'EXECUTE')
                       AND NOT has_function_privilege('anon', 'public.promocion_no_se_borra_con_uso()', 'EXECUTE'),
                    'la función de la guarda no existe, no es definer o la ejecutan authenticated o anon');
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM pg_trigger t
                                WHERE t.tgrelid = 'public.promociones'::regclass
                                  AND t.tgname = 'trg_promocion_no_se_borra_con_uso'
                                  AND t.tgtype & 2 = 2 AND t.tgtype & 8 = 8 AND t.tgtype & 1 = 1),
                    'falta el trigger BEFORE DELETE FOR EACH ROW de promociones');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_k1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v text;
BEGIN
  v := pg_temp.t_reparto(4000, jsonb_build_array(pg_temp.t_l(1, 1, 10000), pg_temp.t_l(2, 1, 0.01)));
  f := pg_temp.t_si(f, v = '1=3999.99 2=0.01', format('Fernet + caramelo a 4000: %s, esperado 1=3999.99 2=0.01', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_k2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v text;
BEGIN
  v := pg_temp.t_reparto(1500, jsonb_build_array(pg_temp.t_l(1, 3, 10000), pg_temp.t_l(2, 2, 0.01)));
  f := pg_temp.t_si(f, v = '1=499.98 2=0.03', format('3 Fernet + 2 caramelos a 1500: %s, esperado 1=499.98 2=0.03', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_k3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v text;
BEGIN
  v := pg_temp.t_reparto(8000, jsonb_build_array(pg_temp.t_l(1, 2, 10000), pg_temp.t_l(2, 3, 0.02)));
  f := pg_temp.t_si(f, v = '1=3999.97 2=0.02', format('2 Fernet + 3 caramelos de 0,02 a 8000: %s, esperado 1=3999.97 2=0.02', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_k4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v text;
BEGIN
  v := pg_temp.t_reparto(3000, jsonb_build_array(pg_temp.t_l(1, 1, 10000), pg_temp.t_l(2, 2, 0.01), pg_temp.t_l(3, 1, 0.03)));
  f := pg_temp.t_si(f, v = '1=2999.96 2=0.01 3=0.02', format('tres líneas a 3000: %s, esperado 1=2999.96 2=0.01 3=0.02', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_k5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v text;
BEGIN
  v := pg_temp.t_reparto(0.07, jsonb_build_array(pg_temp.t_l(1, 7, 0.01)));
  f := pg_temp.t_si(f, v = '1=0.01', format('un componente, 7 × 0,01 por 0,07: %s', v));
  v := pg_temp.t_reparto(2400, jsonb_build_array(pg_temp.t_l(1, 3, 1000)));
  f := pg_temp.t_si(f, v = '1=800.00', format('un componente, 3 × 1000 por 2400: %s', v));
  v := pg_temp.t_reparto(9800, jsonb_build_array(pg_temp.t_l(1, '1.0'::numeric, 10000), pg_temp.t_l(2, 1, 2500)));
  f := pg_temp.t_si(f, v = '1=7840.00 2=1960.00', format('cantidad 1.0: %s, esperado 1=7840.00 2=1960.00', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_k6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v text;
BEGIN
  v := pg_temp.t_reparto(0.06, jsonb_build_array(pg_temp.t_l(1, 2, 0.01), pg_temp.t_l(2, 3, 0.01)));
  f := pg_temp.t_si(f, v = 'null' OR v NOT LIKE '%=0.00%', format('2 + 3 por 0,06: %s, esperado null o sin línea en 0', v));
  v := pg_temp.t_reparto(0.03, jsonb_build_array(pg_temp.t_l(1, 1, 0.01), pg_temp.t_l(2, 1, 0.01),
                                                 pg_temp.t_l(3, 1, 0.01), pg_temp.t_l(4, 1, 0.01)));
  f := pg_temp.t_si(f, v = 'null', format('4 líneas por 0,03: %s, esperado null', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- La grilla: n combos de 1 a 3 líneas, deterministas.
CREATE OR REPLACE FUNCTION pg_temp.caso_k7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; r record;
  v_malos int := 0; v_cambiados int := 0; v_ceros_antes int := 0; v_iguales int := 0; v_n int := 0;
  v_ej_malo text; v_ej_cambio text;
BEGIN
  FOR r IN
    WITH g AS (
      SELECT s,
             CASE WHEN s % 2 = 0 THEN 1 + (s * 12345) % 300 ELSE 1 + (s::bigint * 987654) % 3000000 END AS t_c
        FROM generate_series(1, 4000) s
    )
    SELECT g.s, g.t_c / 100.0 AS total,
           (SELECT jsonb_agg(jsonb_build_object(
                     'producto_id', i,
                     'cantidad', 1 + (g.s * 7 + i * 3) % 4,
                     'ref', CASE WHEN (g.s + i) % 3 = 0
                                 THEN (100 + (g.s::bigint * 7919 + i * 104729) % 2000000) / 100.0
                                 ELSE (1 + (g.s * 31 + i) % 9) / 100.0 END) ORDER BY i)
              FROM generate_series(1, 1 + g.s % 3) i) AS lineas
      FROM g
  LOOP
    DECLARE
      v_nuevo jsonb := public._combo_prorrateo(r.total, r.lineas);
      v_viejo jsonb := pg_temp.k_prorrateo_viejo(r.total, r.lineas);
      v_suma  numeric;
      v_min   numeric;
    BEGIN
      v_n := v_n + 1;
      IF v_viejo IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_each(v_viejo) WHERE (value #>> '{}')::numeric < 0.01) THEN
        v_ceros_antes := v_ceros_antes + 1;
      END IF;
      IF v_nuevo IS NOT NULL THEN
        SELECT sum((l->>'cantidad')::numeric * (v_nuevo->>(l->>'producto_id'))::numeric),
               min((v_nuevo->>(l->>'producto_id'))::numeric)
          INTO v_suma, v_min
          FROM jsonb_array_elements(r.lineas) l;
        IF v_suma <> r.total OR v_min < 0.01 THEN
          v_malos := v_malos + 1;
          v_ej_malo := COALESCE(v_ej_malo, format('%s %s -> %s', r.total, r.lineas, v_nuevo));
        END IF;
      END IF;
      IF v_viejo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_each(v_viejo) WHERE (value #>> '{}')::numeric < 0.01) THEN
        IF v_nuevo IS DISTINCT FROM v_viejo THEN
          v_cambiados := v_cambiados + 1;
          v_ej_cambio := COALESCE(v_ej_cambio, format('%s %s: antes %s, ahora %s', r.total, r.lineas, v_viejo, v_nuevo));
        ELSE
          v_iguales := v_iguales + 1;
        END IF;
      END IF;
    END;
  END LOOP;
  f := pg_temp.t_si(f, v_malos = 0,
                    format('%s de %s repartos no cierran contra el total o dejan una línea por debajo de 0,01 (ej.: %s)',
                           v_malos, v_n, v_ej_malo));
  f := pg_temp.t_si(f, v_cambiados = 0,
                    format('%s repartos sanos cambiaron respecto del cuerpo anterior (ej.: %s)', v_cambiados, v_ej_cambio));
  f := pg_temp.t_si(f, v_ceros_antes > 100 AND v_iguales > 1000,
                    format('la grilla no prueba lo que dice: %s con una línea en 0 antes, %s sanos', v_ceros_antes, v_iguales));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_k8(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_f bigint; v_c bigint; v_combo bigint; v_enc uuid; v_res jsonb; v_ped bigint;
BEGIN
  v_f := pg_temp.t_prod(p_suc, p_adm, 'Fernet', 10000);
  v_c := pg_temp.t_prod(p_suc, p_adm, 'Caramelo', 0.01);
  PERFORM pg_temp.t_claims(p_adm, p_suc);
  v_combo := pg_temp.t_combo(4000, jsonb_build_array(
    jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_f)),
    jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_c))));
  v_enc := pg_temp.t_usuario('encargado', p_suc);
  -- El reparto de antes (el caramelo gratis) ya no es el del server.
  v_res := pg_temp.t_alta(p_cli, v_enc, p_suc, jsonb_build_array(
    jsonb_build_object('producto_id', v_f, 'cantidad', 1, 'precio_unitario', 4000,
                       'combo_id', v_combo, 'precio_sin_combo_unitario', 10000),
    jsonb_build_object('producto_id', v_c, 'cantidad', 1, 'precio_unitario', 0,
                       'combo_id', v_combo, 'precio_sin_combo_unitario', 0.01)));
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false),
                    format('el alta con el caramelo a $0 pasó: %s', v_res));
  v_res := pg_temp.t_alta(p_cli, v_enc, p_suc, jsonb_build_array(
    jsonb_build_object('producto_id', v_f, 'cantidad', 1, 'precio_unitario', 3999.99,
                       'combo_id', v_combo, 'precio_sin_combo_unitario', 10000),
    jsonb_build_object('producto_id', v_c, 'cantidad', 1, 'precio_unitario', 0.01,
                       'combo_id', v_combo, 'precio_sin_combo_unitario', 0.01)));
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false),
                    format('el alta con el reparto nuevo (3999,99 + 0,01) se rechazó: %s', v_res));
  v_ped := (v_res->>'pedido_id')::bigint;
  IF v_ped IS NOT NULL THEN
    f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, v_f) = '1@3999.99c' AND pg_temp.t_lineas(v_ped, v_c) = '1@0.01c'
                         AND (SELECT total FROM public.pedidos WHERE id = v_ped) = 4000,
                      format('lineas %s y %s, total %s; esperado 1@3999.99c, 1@0.01c y 4000',
                             pg_temp.t_lineas(v_ped, v_f), pg_temp.t_lineas(v_ped, v_c),
                             (SELECT total FROM public.pedidos WHERE id = v_ped)));
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_k9(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_combo bigint; v_enc uuid; v_res jsonb;
BEGIN
  v_a := pg_temp.t_prod(p_suc, p_adm, 'Chicle A', 0.02);
  v_b := pg_temp.t_prod(p_suc, p_adm, 'Chicle B', 0.02);
  PERFORM pg_temp.t_claims(p_adm, p_suc);
  v_combo := pg_temp.t_combo(0.06, jsonb_build_array(
    jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array(v_a)),
    jsonb_build_object('cantidad', 3, 'productos', jsonb_build_array(v_b))));
  v_enc := pg_temp.t_usuario('encargado', p_suc);
  v_res := pg_temp.t_alta(p_cli, v_enc, p_suc, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 2, 'precio_unitario', 0.01,
                       'combo_id', v_combo, 'precio_sin_combo_unitario', 0.02),
    jsonb_build_object('producto_id', v_b, 'cantidad', 3, 'precio_unitario', 0.01,
                       'combo_id', v_combo, 'precio_sin_combo_unitario', 0.02)));
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false)
                       AND v_res::text LIKE '%no se puede repartir entre sus productos a ese precio%'
                       AND v_res::text NOT LIKE '%Recargá la app%',
                    format('alta con un combo sin reparto: %s; esperado el rechazo que dice que no se puede repartir', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_ent int; v_dec int;
BEGIN
  v_ent := public._combo_cantidad(
    jsonb_build_array(jsonb_build_object('componente', 1, 'cantidad', 1, 'productos', jsonb_build_array(10)),
                      jsonb_build_object('componente', 2, 'cantidad', 2, 'productos', jsonb_build_array(20, 21))),
    jsonb_build_array(jsonb_build_object('producto_id', 10, 'cantidad', 2),
                      jsonb_build_object('producto_id', 20, 'cantidad', 3),
                      jsonb_build_object('producto_id', 21, 'cantidad', 1)));
  v_dec := public._combo_cantidad(
    jsonb_build_array(jsonb_build_object('componente', 1, 'cantidad', '1.0'::numeric, 'productos', jsonb_build_array(10)),
                      jsonb_build_object('componente', 2, 'cantidad', '2.00'::numeric, 'productos', jsonb_build_array(20, 21))),
    jsonb_build_array(jsonb_build_object('producto_id', 10, 'cantidad', '2.0'::numeric),
                      jsonb_build_object('producto_id', 20, 'cantidad', '3.0'::numeric),
                      jsonb_build_object('producto_id', 21, 'cantidad', 1)));
  f := pg_temp.t_si(f, v_ent = 2 AND v_dec IS NOT DISTINCT FROM v_ent,
                    format('con enteros %s, con .0 %s; esperado 2 y 2', v_ent, v_dec));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v int;
BEGIN
  v := public._combo_cantidad(
    jsonb_build_array(jsonb_build_object('componente', 1, 'cantidad', 1, 'productos', jsonb_build_array(10))),
    jsonb_build_array(jsonb_build_object('producto_id', 10, 'cantidad', '1.5'::numeric)));
  f := pg_temp.t_si(f, v IS NULL, format('cantidad 1.5: %s, esperado null', v));
  v := public._combo_cantidad(
    jsonb_build_array(jsonb_build_object('componente', 1, 'cantidad', '1.5'::numeric, 'productos', jsonb_build_array(10))),
    jsonb_build_array(jsonb_build_object('producto_id', 10, 'cantidad', 3)));
  f := pg_temp.t_si(f, v IS NULL, format('lugar de 1.5: %s, esperado null', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_t1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_f bigint; v_c bigint; v_combo bigint; v_ped bigint;
  v_lf bigint; v_lc bigint; v_lb bigint; v_s0 bigint; v_s1 bigint; v_foto record; v_costo numeric;
BEGIN
  v_f := pg_temp.t_prod(p_suc, p_adm, 'Fernet', 10000);
  v_c := pg_temp.t_prod(p_suc, p_adm, 'Coca', 2500);
  PERFORM pg_temp.t_claims(p_adm, p_suc);
  v_combo := pg_temp.t_combo(9800, jsonb_build_array(
    jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_f)),
    jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_c))));
  v_ped := pg_temp.t_alta_ok(p_cli, p_adm, p_suc, jsonb_build_array(
    jsonb_build_object('producto_id', v_f, 'cantidad', 3, 'precio_unitario', 7840,
                       'combo_id', v_combo, 'precio_sin_combo_unitario', 10000),
    jsonb_build_object('producto_id', v_c, 'cantidad', 3, 'precio_unitario', 1960,
                       'combo_id', v_combo, 'precio_sin_combo_unitario', 2500)));
  PERFORM pg_temp.t_claims(p_adm, p_suc);
  PERFORM pg_temp.t_asignar(v_ped);
  SELECT id INTO v_lf FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_f;
  PERFORM pg_temp.t_salvedad(v_ped, v_lf, 2, 'cliente_rechaza');
  SELECT id INTO v_lc FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_c AND combo_id IS NOT NULL;
  SELECT id INTO v_lb FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_c AND combo_roto_id IS NOT NULL;
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, v_c) = '1@1960.00c 2@2500.00r',
                    format('después de rechazar 2 Fernet, la Coca: %s; esperado 1@1960.00c 2@2500.00r',
                           pg_temp.t_lineas(v_ped, v_c)));
  v_s0 := pg_temp.t_salvedad(v_ped, v_lb, 1, 'producto_danado');
  UPDATE public.productos SET costo_promedio = 1900, precio = 2800 WHERE id = v_c;
  v_s1 := pg_temp.t_salvedad(v_ped, v_lc, 2, 'cliente_rechaza');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pedido_items WHERE id = v_lb)
                       AND (SELECT pedido_item_id FROM public.salvedades_items WHERE id = v_s0) IS NULL,
                    'la línea de afuera tendría que haberse fusionado y borrado (el caso no reproduce)');
  SELECT * INTO v_foto FROM public.salvedad_linea_foto WHERE salvedad_id = v_s0;
  f := pg_temp.t_si(f, v_foto.salvedad_id IS NOT NULL AND v_foto.pedido_item_id = v_lb
                       AND v_foto.costo_unitario_al_crear = 1500 AND v_foto.precio_lista_al_crear = 2500,
                    format('foto de S0: %s; esperado la de la línea borrada con costo 1500 y lista 2500',
                           CASE WHEN v_foto.salvedad_id IS NULL THEN 'no hay'
                                ELSE format('línea %s, costo %s, lista %s', v_foto.pedido_item_id,
                                            v_foto.costo_unitario_al_crear, v_foto.precio_lista_al_crear) END));
  PERFORM pg_temp.t_anular(v_s0);
  SELECT costo_unitario_al_crear INTO v_costo
    FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_c ORDER BY id DESC LIMIT 1;
  f := pg_temp.t_si(f, v_costo = 1500,
                    format('anular S0 devolvió la Coca con costo %s; esperado 1500 (el de la venta, no el de hoy)', v_costo));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_g1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  f := pg_temp.t_si(f, public.auditoria_funciones_pedido_items_sin_piso() = 0,
                    format('PRECIO-A: %s', public.auditoria_funciones_pedido_items_sin_piso()));
  f := pg_temp.t_si(f, public.auditoria_funciones_costo_sin_valuacion() = 0,
                    format('COSTO-D: %s', public.auditoria_funciones_costo_sin_valuacion()));
  f := pg_temp.t_si(f, public.auditoria_funciones_stock_sin_origen() = 0,
                    format('STK-F: %s', public.auditoria_funciones_stock_sin_origen()));
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.auditoria_definer_sin_rol()) = 0,
                    format('SEG-A: %s', (SELECT string_agg(firma || ' ' || motivo, '; ') FROM public.auditoria_definer_sin_rol())));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
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
  v_cliente := pg_temp.t_cli(v_suc);

  PERFORM pg_temp.t_claims(v_admin, v_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['p1', 'p2', 'p3', 'p4', 'p5', 'k1', 'k2', 'k3', 'k4', 'k5', 'k6', 'k7', 'k8', 'k9',
                                'c1', 'c2', 't1', 'g1'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.t_claims(v_admin, v_suc);
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc;
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

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  -- Termina siempre en una excepción: nada de lo de arriba queda escrito.
  RAISE EXCEPTION 'ENSAYO OK (18 casos)';
END
$ensayo$;
