-- Ensayo de #1054 y #1073: la traza lote -> cliente sobrevive a la edicion de
-- la compra y a las salvedades.
--
-- #1054 · sincronizar_lotes_compra (la app la llama en CADA edicion de una
-- compra) borraba los lotes de la compra y los volvia a crear con ids nuevos.
-- Por el ON DELETE CASCADE de pedido_item_lotes se iba la traza de a que
-- cliente se vendio cada lote; por el ON DELETE SET NULL de
-- movimiento_sucursal_item_lotes, la de las transferencias. Y si la edicion
-- corregia un vencimiento, el lote "nuevo" nacia lleno (lo consumido se
-- buscaba por producto|fecha): lote +N, bolsa -N, y la anulacion de una
-- salvedad volvia a comer de la bolsa (#1050 por otra puerta).
--   A  · editar sin cambios conserva el lote (mismo id) y la traza del cliente.
--   B  · editar sin cambios conserva la traza de una transferencia.
--   C  · corregir el vencimiento (bolsa 40, no 0) cambia la fecha del MISMO
--        lote y conserva lo consumido: lote y bolsa no se mueven.
--   C2 · el vencimiento se corrige entre una salvedad y su anulacion: anular
--        vuelve lote y bolsa a donde estaban despues del pedido.
--   D  · corregir el vencimiento conserva la traza del cliente.
--   F  · fusion (dos vencimientos -> uno): lo consumido y la traza del lote que
--        se va pasan al que queda (el que vence primero).
--   F2 · fusion con una salvedad devuelta al lote que se va: anular la saca del
--        lote que queda, no de la bolsa.
--   F3 · se saca un vencimiento y el otro no crece: no es fusion; el que se va
--        queda solo para la traza y el otro no se toca.
--   D2 · fusion con una salvedad anotada en los dos lotes: anular saca y
--        repone la huella de las dos entradas que quedan sobre el mismo lote.
--   X  · se sacan todos los vencimientos de un producto con traza: el lote
--        queda solo para la traza (solo_traza, cantidad = lo que ya salio,
--        restante 0) y la traza sigue.
--   X2 · se saca un vencimiento sin traza: se borra, como siempre.
--   X3 · se sacan dos vencimientos con traza a la vez: quedan los dos solo
--        para la traza (ninguno absorbe al otro).
--   X4 · el lote solo para la traza no revive con devoluciones (con huella o
--        sin ella).
--   X5 · un lote al que solo apunta la anotacion de una salvedad viva no se
--        borra, y anular repone la huella.
--   X6 · reenviar el lote solo para la traza tal cual (bundle viejo) no hace
--        nada; volver a cargar la fecha con otra cantidad lo revive.
--   N  · un vencimiento nuevo crea un lote y no toca el que estaba.
--   Q  · corregir la cantidad del mismo vencimiento conserva id y consumido.
--
-- #1073 · cuatro bordes de trazabilidad de las salvedades.
--   S1 · merma sobre la linea entera: anular le repone la huella a la linea.
--   S2 · regalo del mismo producto: la resincronizacion del regalo descuenta
--        la huella del REGALO, no la de la linea principal.
--   S3 · registrar_salvedad y anular_salvedad bloquean en el mismo orden:
--        pedidos antes que pedido_items (estructural: en una sola sesion no se
--        puede provocar el deadlock).
--   S4 · la linea salio de L1 y otro lote (L2) vence antes y tiene hueco: la
--        devolucion vuelve a L1, y la huella de L1 baja.
--   S4b· lo mismo al cancelar el pedido entero.
--
-- Corre contra prod SIN dejar rastro: todo termina en un RAISE EXCEPTION, asi
-- que lo que crea (productos, compras, lotes, pedidos, salvedades,
-- movimientos) se deshace. Las funciones auxiliares van en pg_temp.
-- Veredicto en el mensaje del error final: 'ENSAYO OK' o 'ENSAYO FALLO', con
-- la tabla de pedido_item_lotes antes/despues de cada caso.
--
--   psql "$DATABASE_URL" -f scripts/test-lotes-trazabilidad-1054-1073.sql

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Un lote como {dias, cant, rest}; NULL si ya no existe.
CREATE OR REPLACE FUNCTION pg_temp.t_lote(p_id bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('dias', l.fecha_vencimiento - pg_temp.t_hoy(),
                            'cant', l.cantidad, 'rest', l.cantidad_restante)
    FROM public.producto_lotes l WHERE l.id = p_id;
$fn$;

-- El lote quedo solo para la traza (mig 338). Sin la columna, false.
CREATE OR REPLACE FUNCTION pg_temp.t_solo(p_id bigint)
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
  v boolean;
BEGIN
  EXECUTE 'SELECT solo_traza FROM public.producto_lotes WHERE id = $1' INTO v USING p_id;
  RETURN COALESCE(v, false);
EXCEPTION WHEN undefined_column THEN
  RETURN false;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_foto(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'stock', pr.stock,
    'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                         FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
    'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                    FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int)
    FROM public.productos pr WHERE pr.id = p_prod;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_huella(p_item bigint, p_lote bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_item_lotes
   WHERE pedido_item_id = p_item AND lote_id = p_lote;
$fn$;

-- pedido_item_lotes de las lineas de un producto: [{item, lote, cant}].
CREATE OR REPLACE FUNCTION pg_temp.t_huella_tabla(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('item', pil.pedido_item_id, 'lote', pil.lote_id,
                                               'cant', pil.cantidad)
                            ORDER BY pil.pedido_item_id, pil.lote_id), '[]'::jsonb)
    FROM public.pedido_item_lotes pil
    JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
   WHERE pi.producto_id = p_prod;
$fn$;

-- Producto con lotes de una compra ([{dias, cantidad, restante}]) y `p_bolsa`
-- unidades sin lote. Devuelve {prod, compra, lotes: [ids en el orden dado]}.
CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_admin uuid, p_lotes jsonb, p_bolsa int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
  v_id     bigint;
  v_ids    jsonb := '[]'::jsonb;
  l        jsonb;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1054', 100,
          p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;

  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;

  FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.t_hoy() + (l->>'dias')::int, (l->>'cantidad')::int,
            (l->>'restante')::int, p_admin, v_compra)
    RETURNING id INTO v_id;
    v_ids := v_ids || to_jsonb(v_id);
  END LOOP;

  RETURN jsonb_build_object('prod', v_prod, 'compra', v_compra, 'lotes', v_ids);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1054');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_prod));
END
$fn$;

-- La edicion de la compra, como la manda la app: la foto completa de los
-- vencimientos de la factura ([{dias, cantidad}] de un solo producto).
CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_compra bigint, p_prod bigint, p_lotes jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sincronizar_lotes_compra(p_compra, COALESCE((
    SELECT jsonb_agg(jsonb_build_object('producto_id', p_prod,
                                        'fecha_vencimiento', pg_temp.t_hoy() + (x->>'dias')::int,
                                        'cantidad', (x->>'cantidad')::int))
      FROM jsonb_array_elements(p_lotes) x), '[]'::jsonb));
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar la compra: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                     'ensayo 1054: descripcion del caso', NULL, true, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar %: %', p_motivo, v_res;
  END IF;
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_anular(p_salv bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.anular_salvedad(p_salv, 'ensayo 1054');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular: %', v_res;
  END IF;
END
$fn$;

-- Suma unidades a la bolsa con un origen fuera de la lista blanca (no van a
-- ningun lote). Sirve para que la bolsa no quede en 0 despues de un pedido que
-- llego a los lotes: con bolsa 0 la bajada cae en el lote por FEFO y da bien
-- por casualidad.
CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1054', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1054
-- ---------------------------------------------------------------------------

-- A · lote 100 con 50 vivas, bolsa 5. Pedido 20: 5 de la bolsa y 15 del lote
--     (huella 15). Editar la compra sin cambios.
CREATE OR REPLACE FUNCTION pg_temp.caso_a(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);
  IF pg_temp.t_huella(v_item, v_l) <> 15 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: huella %s', h0)));
  END IF;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":100}]');
  h1 := pg_temp.t_huella_tabla(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) IS NOT NULL,
                    'editar la compra sin cambios borro el lote y lo recreo con otro id');
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":90,"cant":100,"rest":35}',
                    format('el lote quedo %s, esperado {dias 90, cant 100, rest 35}', pg_temp.t_lote(v_l)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 15,
                    format('la huella del cliente en el lote era 15 y quedo %s', pg_temp.t_huella(v_item, v_l)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('lote %s · pedido_item_lotes antes %s / despues %s', v_l, h0, h1));
END
$fn$;

-- B · una transferencia salio del lote (movimiento_sucursal_item_lotes).
--     Editar la compra sin cambios.
CREATE OR REPLACE FUNCTION pg_temp.caso_b(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; v_mov bigint; v_mitem bigint; v_trl bigint;
  f text[] := '{}'; v_lote_traza bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;

  INSERT INTO public.movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, creado_por)
  VALUES (p_suc, p_otra, p_adm) RETURNING id INTO v_mov;
  INSERT INTO public.movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre)
  VALUES (v_mov, v_prod, 5, 'ZZ ensayo 1054') RETURNING id INTO v_mitem;
  INSERT INTO public.movimiento_sucursal_item_lotes (item_id, sucursal_id, lote_id, fecha_vencimiento, cantidad)
  VALUES (v_mitem, p_suc, v_l, pg_temp.t_hoy() + 90, 5) RETURNING id INTO v_trl;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":100}]');

  SELECT lote_id INTO v_lote_traza FROM public.movimiento_sucursal_item_lotes WHERE id = v_trl;
  f := pg_temp.t_si(f, v_lote_traza = v_l,
                    format('la traza de la transferencia apuntaba al lote %s y quedo en %s', v_l,
                           COALESCE(v_lote_traza::text, 'NULL')));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('movimiento_sucursal_item_lotes.lote_id antes %s / despues %s', v_l,
                      COALESCE(v_lote_traza::text, 'NULL')));
END
$fn$;

-- C · lote 100 con 50 vivas, bolsa 40 (stock 90). Se corrige el vencimiento
--     de 90 a 120 dias.
CREATE OR REPLACE FUNCTION pg_temp.caso_c(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":120,"cantidad":100}]');
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":120,"cant":100,"rest":50}',
                    format('el lote %s quedo %s, esperado el mismo lote con {dias 120, cant 100, rest 50}',
                           v_l, COALESCE(pg_temp.t_lote(v_l)::text, 'borrado')));
  f := pg_temp.t_si(f, v_foto = '{"stock":90,"lotes":[50],"bolsa":40}',
                    format('corregir el vencimiento dejo %s, antes era {stock 90, lotes [50], bolsa 40}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto despues %s', v_foto));
END
$fn$;

-- C2 · bolsa 40, pedido 20 de la bolsa {70,[50],20}, salvedad 10 al lote
--      {80,[60],20}, se corrige el vencimiento, se anula: {70,[50],20}.
CREATE OR REPLACE FUNCTION pg_temp.caso_c2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_salv bigint; f text[] := '{}';
  v_f1 jsonb; v_f2 jsonb; v_f3 jsonb; v_f4 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_f1 := pg_temp.t_foto(v_prod);
  v_salv := pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'cliente_rechaza');
  v_f2 := pg_temp.t_foto(v_prod);
  IF v_f1 <> '{"stock":70,"lotes":[50],"bolsa":20}' OR v_f2 <> '{"stock":80,"lotes":[60],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s, %s', v_f1, v_f2)));
  END IF;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":120,"cantidad":100}]');
  v_f3 := pg_temp.t_foto(v_prod);
  PERFORM pg_temp.t_anular(v_salv);
  v_f4 := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, v_f3 = v_f2, format('corregir el vencimiento movio lote y bolsa: %s -> %s', v_f2, v_f3));
  f := pg_temp.t_si(f, v_f4 = v_f1, format('anular dejo %s; despues del pedido era %s', v_f4, v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('pedido %s · salvedad %s · edicion %s · anulada %s', v_f1, v_f2, v_f3, v_f4));
END
$fn$;

-- D · huella 15 en el lote (como A) y se corrige el vencimiento.
CREATE OR REPLACE FUNCTION pg_temp.caso_d(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":120,"cantidad":100}]');
  h1 := pg_temp.t_huella_tabla(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":120,"cant":100,"rest":35}',
                    format('el lote %s quedo %s, esperado {dias 120, cant 100, rest 35}',
                           v_l, COALESCE(pg_temp.t_lote(v_l)::text, 'borrado')));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 15,
                    format('la huella del cliente era 15 y quedo %s', pg_temp.t_huella(v_item, v_l)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('lote %s · pedido_item_lotes antes %s / despues %s', v_l, h0, h1));
END
$fn$;

-- F · L1 (30 dias, 10/10) y L2 (90 dias, 10/10), bolsa 5. Pedido 20: 5 de la
--     bolsa, 10 de L1, 5 de L2. La edicion los fusiona en un vencimiento de
--     60 dias por 20: L1 cambia de fecha y absorbe lo consumido y la traza de L2.
CREATE OR REPLACE FUNCTION pg_temp.caso_f(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; v_l2 bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":10,"restante":10}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0; v_l2 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);
  IF pg_temp.t_huella(v_item, v_l1) <> 10 OR pg_temp.t_huella(v_item, v_l2) <> 5 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: huella %s', h0)));
  END IF;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":60,"cantidad":20}]');
  h1 := pg_temp.t_huella_tabla(v_prod);
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l1) = '{"dias":60,"cant":20,"rest":5}',
                    format('L1 quedo %s, esperado {dias 60, cant 20, rest 5}',
                           COALESCE(pg_temp.t_lote(v_l1)::text, 'borrado')));
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l2) IS NULL, 'L2 (el que se fusiono) sigue existiendo');
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('la huella del cliente era 10 en L1 + 5 en L2 y quedo %s en L1',
                           pg_temp.t_huella(v_item, v_l1)));
  f := pg_temp.t_si(f, v_foto = '{"stock":5,"lotes":[5],"bolsa":0}',
                    format('la fusion dejo %s, esperado {stock 5, lotes [5], bolsa 0}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L1 %s, L2 %s · pedido_item_lotes antes %s / despues %s', v_l1, v_l2, h0, h1));
END
$fn$;

-- F2 · L1 (30 dias, 50/50) y L2 (90 dias, 50 con 40 vivas), bolsa 30.
--      Pedido 20 de la bolsa {100,[50,40],10}; salvedad 10 entra a L2
--      {110,[50,50],10}; la edicion fusiona todo en el vencimiento de L1 por
--      100 {110,[100],10}; anular saca las 10 del lote que quedo {100,[90],10}.
CREATE OR REPLACE FUNCTION pg_temp.caso_f2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_salv bigint; f text[] := '{}';
  v_f1 jsonb; v_f2 jsonb; v_f3 jsonb; v_f4 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":50},{"dias":90,"cantidad":50,"restante":40}]', 30);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_f1 := pg_temp.t_foto(v_prod);
  v_salv := pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'cliente_rechaza');
  v_f2 := pg_temp.t_foto(v_prod);
  IF v_f1 <> '{"stock":100,"lotes":[50,40],"bolsa":10}' OR v_f2 <> '{"stock":110,"lotes":[50,50],"bolsa":10}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s, %s', v_f1, v_f2)));
  END IF;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":30,"cantidad":100}]');
  v_f3 := pg_temp.t_foto(v_prod);
  PERFORM pg_temp.t_anular(v_salv);
  v_f4 := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, v_f3 = '{"stock":110,"lotes":[100],"bolsa":10}',
                    format('la fusion dejo %s, esperado {stock 110, lotes [100], bolsa 10}', v_f3));
  f := pg_temp.t_si(f, v_f4 = '{"stock":100,"lotes":[90],"bolsa":10}',
                    format('anular despues de la fusion dejo %s, esperado {stock 100, lotes [90], bolsa 10}', v_f4));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('pedido %s · salvedad %s · fusion %s · anulada %s', v_f1, v_f2, v_f3, v_f4));
END
$fn$;

-- X · huella 15 en el lote (como A) y la edicion saca todos los vencimientos
--     del producto. El lote queda agotado: cantidad = lo que ya salio (65),
--     restante 0. La bolsa se queda con lo que el lote tenia vivo.
CREATE OR REPLACE FUNCTION pg_temp.caso_x(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');
  h1 := pg_temp.t_huella_tabla(v_prod);
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":90,"cant":65,"rest":0}' AND pg_temp.t_solo(v_l),
                    format('el lote quedo %s (solo_traza %s), esperado agotado {dias 90, cant 65, rest 0}',
                           COALESCE(pg_temp.t_lote(v_l)::text, 'borrado'), pg_temp.t_solo(v_l)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 15,
                    format('la huella del cliente era 15 y quedo %s', pg_temp.t_huella(v_item, v_l)));
  f := pg_temp.t_si(f, v_foto = '{"stock":35,"lotes":[0],"bolsa":35}',
                    format('sacar el vencimiento dejo %s, esperado {stock 35, lotes [0], bolsa 35}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('lote %s · pedido_item_lotes antes %s / despues %s', v_l, h0, h1));
END
$fn$;

-- X2 · sin traza: sacar el vencimiento borra el lote, como siempre.
CREATE OR REPLACE FUNCTION pg_temp.caso_x2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');
  v_foto := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) IS NULL, 'el lote sin traza no se borro');
  f := pg_temp.t_si(f, v_foto = '{"stock":90,"lotes":[],"bolsa":90}',
                    format('sacar el vencimiento dejo %s, esperado {stock 90, lotes [], bolsa 90}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto despues %s', v_foto));
END
$fn$;

-- X3 · dos vencimientos con traza y la edicion saca los dos: ninguno absorbe
--      al otro (los dos se van), quedan los dos agotados con su traza.
--      L1 (30 dias, 10/10), L2 (90 dias, 10/10), bolsa 5. Pedido 20: 5 de la
--      bolsa, 10 de L1, 5 de L2.
CREATE OR REPLACE FUNCTION pg_temp.caso_x3(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; v_l2 bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":10,"restante":10}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0; v_l2 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');
  h1 := pg_temp.t_huella_tabla(v_prod);
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l1) = '{"dias":30,"cant":10,"rest":0}'
                       AND pg_temp.t_lote(v_l2) = '{"dias":90,"cant":5,"rest":0}'
                       AND pg_temp.t_solo(v_l1) AND pg_temp.t_solo(v_l2),
                    format('L1 quedo %s y L2 %s, esperado agotados {30, 10, 0} y {90, 5, 0}',
                           COALESCE(pg_temp.t_lote(v_l1)::text, 'borrado'),
                           COALESCE(pg_temp.t_lote(v_l2)::text, 'borrado')));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 10 AND pg_temp.t_huella(v_item, v_l2) = 5,
                    format('la traza era 10 en L1 y 5 en L2, quedo %s', h1));
  f := pg_temp.t_si(f, v_foto = '{"stock":5,"lotes":[0,0],"bolsa":5}',
                    format('sacar los vencimientos dejo %s, esperado {stock 5, lotes [0,0], bolsa 5}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L1 %s, L2 %s · pedido_item_lotes antes %s / despues %s', v_l1, v_l2, h0, h1));
END
$fn$;

-- F3 · como F, pero la edicion solo SACA el vencimiento de 30 dias y deja el
--      de 90 como estaba (10). No es una fusion: el de 90 no crecio, asi que
--      no absorbe lo consumido del otro (si lo absorbiera, sus 5 vivas pasarian
--      a la bolsa). El de 30 tiene traza: queda solo para la traza.
CREATE OR REPLACE FUNCTION pg_temp.caso_f3(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; v_l2 bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":10,"restante":10}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0; v_l2 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":10}]');
  h1 := pg_temp.t_huella_tabla(v_prod);
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l2) = '{"dias":90,"cant":10,"rest":5}',
                    format('L2 quedo %s, esperado sin tocar {90, 10, 5}', COALESCE(pg_temp.t_lote(v_l2)::text, 'borrado')));
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l1) = '{"dias":30,"cant":10,"rest":0}' AND pg_temp.t_solo(v_l1),
                    format('L1 quedo %s (solo_traza %s), esperado solo para la traza {30, 10, 0}',
                           COALESCE(pg_temp.t_lote(v_l1)::text, 'borrado'), pg_temp.t_solo(v_l1)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 10 AND pg_temp.t_huella(v_item, v_l2) = 5,
                    format('la traza era 10 en L1 y 5 en L2, quedo %s', h1));
  f := pg_temp.t_si(f, v_foto = '{"stock":5,"lotes":[0,5],"bolsa":0}',
                    format('sacar el vencimiento dejo %s, esperado {stock 5, lotes [0,5], bolsa 0}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L1 %s, L2 %s · pedido_item_lotes antes %s / despues %s', v_l1, v_l2, h0, h1));
END
$fn$;

-- X4 · el lote que quedo solo para la traza no revive. Como X (huella 15,
--      lote agotado con 65), y despues: un pedido de 10 que sale de la bolsa
--      y se cancela (devolucion sin huella: no va al lote), y se cancela el
--      pedido original (su huella baja, las unidades van a la bolsa).
CREATE OR REPLACE FUNCTION pg_temp.caso_x4(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; p2 jsonb; v_item bigint; v_res jsonb;
  f text[] := '{}'; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');

  p2 := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10);
  v_res := public.cancelar_pedido_con_stock((p2->>'pedido')::bigint, 'ensayo 1054', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar el segundo: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":35,"lotes":[0],"bolsa":35}',
                    format('cancelar un pedido sin huella dejo %s, esperado {stock 35, lotes [0], bolsa 35}', v_f1));

  v_res := public.cancelar_pedido_con_stock((p->>'pedido')::bigint, 'ensayo 1054', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar el original: %', v_res;
  END IF;
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = '{"stock":55,"lotes":[0],"bolsa":55}',
                    format('cancelar el pedido con huella dejo %s, esperado {stock 55, lotes [0], bolsa 55}', v_f2));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 0,
                    format('el pedido cancelado sigue con huella %s', pg_temp.t_huella(v_item, v_l)));
  f := pg_temp.t_si(f, pg_temp.t_solo(v_l), 'el lote dejo de ser solo para la traza');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f1, v_f2));
END
$fn$;

-- X5 · el lote al que solo apunta la anotacion de una salvedad viva no se
--      borra. Pedido 10 (5 de la bolsa, 5 del lote: huella 5), salvedad
--      cliente_rechaza por la linea entera (la linea se borra con su huella; la
--      anotacion la guarda), se sacan los vencimientos, se anula: la linea
--      repuesta vuelve a tener su huella 5 en el lote.
CREATE OR REPLACE FUNCTION pg_temp.caso_x5(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_ped bigint; v_salv bigint; v_item2 bigint;
  f text[] := '{}'; h2 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10); v_ped := p->>'pedido';
  v_salv := pg_temp.t_salvedad(v_ped, (p->>'item')::bigint, 10, 'cliente_rechaza');
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) IS NOT NULL,
                    'el lote con huella anotada en una salvedad viva se borro');
  PERFORM pg_temp.t_anular(v_salv);
  h2 := pg_temp.t_huella_tabla(v_prod); v_f2 := pg_temp.t_foto(v_prod);
  SELECT id INTO v_item2 FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item2, v_l) = 5,
                    format('anular repuso la linea con huella %s en el lote, esperado 5', pg_temp.t_huella(v_item2, v_l)));
  f := pg_temp.t_si(f, v_f2 = '{"stock":45,"lotes":[0],"bolsa":45}',
                    format('anular dejo %s, esperado {stock 45, lotes [0], bolsa 45}', v_f2));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('pedido_item_lotes anulada %s · foto %s', h2, v_f2));
END
$fn$;

-- X6 · como X (lote solo para la traza, cantidad 65). Un bundle viejo del PWA
--      que todavia lo precarga lo reenvia tal cual (90 dias, 65): no pasa nada.
--      Si el usuario vuelve a cargar esa fecha con otra cantidad (100), el lote
--      vuelve a ser un vencimiento de la compra, con lo consumido (65).
CREATE OR REPLACE FUNCTION pg_temp.caso_x6(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; f text[] := '{}'; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":65}]');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_solo(v_l) AND v_f1 = '{"stock":35,"lotes":[0],"bolsa":35}',
                    format('el reenvio de un bundle viejo cambio algo: %s (solo_traza %s)', v_f1, pg_temp.t_solo(v_l)));

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":100}]');
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, NOT pg_temp.t_solo(v_l) AND pg_temp.t_lote(v_l) = '{"dias":90,"cant":100,"rest":35}',
                    format('volver a cargar la fecha dejo el lote en %s (solo_traza %s), esperado {90, 100, 35}',
                           pg_temp.t_lote(v_l), pg_temp.t_solo(v_l)));
  f := pg_temp.t_si(f, v_f2 = '{"stock":35,"lotes":[35],"bolsa":0}',
                    format('volver a cargar la fecha dejo %s, esperado {stock 35, lotes [35], bolsa 0}', v_f2));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f1, v_f2));
END
$fn$;

-- D2 · como F, pero antes de fusionar hay una salvedad por la linea entera
--      (20) que devolvio 10 a L1 y 5 a L2 (a cada uno lo suyo). La fusion
--      reapunta la anotacion de L2 a L1: quedan dos entradas del mismo lote, y
--      anular tiene que sacar las 15 y reponer la huella 15, no 10.
CREATE OR REPLACE FUNCTION pg_temp.caso_d2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; p jsonb; v_ped bigint; v_salv bigint; v_item2 bigint;
  f text[] := '{}'; v_f3 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":10,"restante":10}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido';
  v_salv := pg_temp.t_salvedad(v_ped, (p->>'item')::bigint, 20, 'cliente_rechaza');
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":60,"cantidad":20}]');
  PERFORM pg_temp.t_anular(v_salv);
  v_f3 := pg_temp.t_foto(v_prod);

  SELECT id INTO v_item2 FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  f := pg_temp.t_si(f, v_f3 = '{"stock":5,"lotes":[5],"bolsa":0}',
                    format('anular despues de la fusion dejo %s, esperado {stock 5, lotes [5], bolsa 0}', v_f3));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item2, v_l1) = 15,
                    format('anular repuso huella %s en el lote fusionado, esperado 15', pg_temp.t_huella(v_item2, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f3));
END
$fn$;

-- N · se agrega un vencimiento nuevo (150 dias, 30): nace lleno y saca de la
--     bolsa; el lote que estaba no se toca.
CREATE OR REPLACE FUNCTION pg_temp.caso_n(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod,
                           '[{"dias":90,"cantidad":100},{"dias":150,"cantidad":30}]');
  v_foto := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":90,"cant":100,"rest":50}',
                    format('el lote que estaba quedo %s', COALESCE(pg_temp.t_lote(v_l)::text, 'borrado')));
  f := pg_temp.t_si(f, v_foto = '{"stock":90,"lotes":[50,30],"bolsa":10}',
                    format('agregar el vencimiento dejo %s, esperado {stock 90, lotes [50,30], bolsa 10}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto despues %s', v_foto));
END
$fn$;

-- Q · se corrige la cantidad del mismo vencimiento (100 -> 80): mismo lote,
--     lo consumido (50) se conserva.
CREATE OR REPLACE FUNCTION pg_temp.caso_q(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":80}]');
  v_foto := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":90,"cant":80,"rest":30}',
                    format('el lote quedo %s, esperado el mismo con {cant 80, rest 30}',
                           COALESCE(pg_temp.t_lote(v_l)::text, 'borrado')));
  f := pg_temp.t_si(f, v_foto = '{"stock":90,"lotes":[30],"bolsa":60}',
                    format('corregir la cantidad dejo %s, esperado {stock 90, lotes [30], bolsa 60}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto despues %s', v_foto));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1073
-- ---------------------------------------------------------------------------

-- S1 · lote 100 con 50 vivas, bolsa 3. Pedido 10: 3 de la bolsa y 7 del lote
--      (huella 7). Salvedad producto_danado por las 10: la linea se borra.
--      Anular: la linea vuelve y su huella en el lote tambien (7).
CREATE OR REPLACE FUNCTION pg_temp.caso_s1(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_ped bigint; v_item bigint; v_salv bigint;
  v_item2 bigint; f text[] := '{}'; h0 jsonb; h1 jsonb; h2 jsonb; v_f0 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 3);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10); v_ped := p->>'pedido'; v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod); v_f0 := pg_temp.t_foto(v_prod);
  IF pg_temp.t_huella(v_item, v_l) <> 7 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: huella %s', h0)));
  END IF;

  v_salv := pg_temp.t_salvedad(v_ped, v_item, 10, 'producto_danado');
  h1 := pg_temp.t_huella_tabla(v_prod);
  PERFORM pg_temp.t_anular(v_salv);
  h2 := pg_temp.t_huella_tabla(v_prod);
  v_f2 := pg_temp.t_foto(v_prod);

  SELECT id INTO v_item2 FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item2, v_l) = 7,
                    format('anular repuso la linea pero su huella en el lote quedo %s (era 7)',
                           pg_temp.t_huella(v_item2, v_l)));
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular la merma movio stock o lotes: %s -> %s', v_f0, v_f2));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('pedido_item_lotes pedido %s / salvedad %s / anulada %s', h0, h1, h2));
END
$fn$;

-- S2 · lote 100 con 50 vivas, bolsa 3. Linea principal de 10 (3 de la bolsa,
--      7 del lote: huella 7) y regalo de 2 del MISMO producto (del lote:
--      huella 2), promo "10 + 2" que mueve stock. Salvedad de 1 sobre la
--      principal: cae el regalo (vuelven 2) y vuelve 1. La huella de la
--      principal tiene que quedar en 6, no en 4.
CREATE OR REPLACE FUNCTION pg_temp.caso_s2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_ped bigint; v_item bigint; v_promo bigint;
  v_regalo bigint; f text[] := '{}'; h0 jsonb; h1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 3);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10); v_ped := p->>'pedido'; v_item := p->>'item';

  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1073 S2', 'bonificacion', CURRENT_DATE, p_suc, true, v_prod) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, p_suc), (v_promo, 'cantidad_bonificacion', 2, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, v_prod, p_suc);

  -- El regalo, cargado como lo carga crear_pedido_completo: la linea y su
  -- bajada de stock con la linea en el GUC (deja huella).
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (v_ped, v_prod, 2, 0, 0, p_suc, true, v_promo) RETURNING id INTO v_regalo;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_regalo::text, true);
  UPDATE public.productos SET stock = stock - 2 WHERE id = v_prod;
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.stock_origen', '', true);

  h0 := pg_temp.t_huella_tabla(v_prod);
  IF pg_temp.t_huella(v_item, v_l) <> 7 OR pg_temp.t_huella(v_regalo, v_l) <> 2 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: huella %s', h0)));
  END IF;

  PERFORM pg_temp.t_salvedad(v_ped, v_item, 1, 'cliente_rechaza');
  h1 := pg_temp.t_huella_tabla(v_prod);

  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pedido_items WHERE id = v_regalo),
                    'el regalo no cayo: el ensayo no ejercita la resincronizacion');
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 6,
                    format('la huella de la linea principal quedo %s, esperado 6 (7 menos la unidad devuelta)',
                           pg_temp.t_huella(v_item, v_l)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('principal %s, regalo %s · pedido_item_lotes antes %s / despues %s',
                      v_item, v_regalo, h0, h1));
END
$fn$;

-- S3 · el orden de los locks: pedidos antes que pedido_items, en las dos.
CREATE OR REPLACE FUNCTION pg_temp.caso_s3(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_reg text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_anu text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_r_ped int; v_r_item int; v_r_lock int; v_a_ped int; v_a_item int;
  f text[] := '{}';
BEGIN
  v_r_ped  := regexp_instr(v_reg, 'FROM pedidos\s+WHERE id = p_pedido_id\s+AND sucursal_id = v_sucursal\s+FOR UPDATE');
  v_r_item := regexp_instr(v_reg, 'FROM pedido_items pi\s+WHERE pi\.id = p_pedido_item_id');
  v_r_lock := regexp_instr(v_reg, 'PERFORM 1 FROM pedido_items');
  v_a_ped  := regexp_instr(v_anu, 'FROM pedidos\s+WHERE id = v_salvedad\.pedido_id AND sucursal_id = v_sucursal\s+FOR UPDATE');
  v_a_item := regexp_instr(v_anu, 'UPDATE pedido_items SET');

  f := pg_temp.t_si(f, v_r_ped > 0 AND v_r_ped < v_r_item AND v_r_ped < v_r_lock,
                    format('registrar_salvedad no bloquea pedidos antes que pedido_items (pedidos en %s, linea en %s/%s)',
                           v_r_ped, v_r_item, v_r_lock));
  f := pg_temp.t_si(f, v_a_ped > 0 AND v_a_ped < v_a_item,
                    format('anular_salvedad no bloquea pedidos antes que pedido_items (%s, %s)', v_a_ped, v_a_item));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- S4 · L2 vence a 30 dias y esta vacio (50, 0 vivas); L1 vence a 90 (100, 50
--      vivas). Bolsa 5. Pedido 20: 5 de la bolsa y 15 de L1 (huella 15). Se
--      suman 20 a la bolsa. Salvedad de 10: vuelven a L1 (no a L2, que vence
--      antes y tiene hueco) y la huella de L1 baja a 5. Anular: todo como
--      despues del pedido.
CREATE OR REPLACE FUNCTION pg_temp.caso_s4(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; h2 jsonb; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  h0 := pg_temp.t_huella_tabla(v_prod); v_f0 := pg_temp.t_foto(v_prod);
  IF pg_temp.t_huella(v_item, v_l1) <> 15 OR v_f0 <> '{"stock":55,"lotes":[0,35],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s, huella %s', v_f0, h0)));
  END IF;

  v_salv := pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  h1 := pg_temp.t_huella_tabla(v_prod); v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":65,"lotes":[0,45],"bolsa":20}',
                    format('la devolucion dejo %s, esperado {stock 65, lotes [0,45], bolsa 20}: volver a L1', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 5,
                    format('la huella en L1 quedo %s, esperado 5 (15 menos las 10 devueltas)',
                           pg_temp.t_huella(v_item, v_l1)));

  PERFORM pg_temp.t_anular(v_salv);
  h2 := pg_temp.t_huella_tabla(v_prod); v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s; despues del pedido era %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('despues de anular la huella en L1 quedo %s, esperado 15', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L2 %s, L1 %s · pedido_item_lotes pedido %s / salvedad %s / anulada %s · fotos %s / %s / %s',
                      v_l2, v_l1, h0, h1, h2, v_f0, v_f1, v_f2));
END
$fn$;

-- S4b · lo mismo, pero se cancela el pedido entero: las 15 que salieron de L1
--       vuelven a L1 y la huella del pedido desaparece. Las 5 que salieron de
--       la bolsa no tienen lote y van por FEFO, como siempre (a L2).
CREATE OR REPLACE FUNCTION pg_temp.caso_s4b(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_res jsonb;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  h0 := pg_temp.t_huella_tabla(v_prod);

  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1054', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  h1 := pg_temp.t_huella_tabla(v_prod); v_f1 := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[5,50],"bolsa":20}',
                    format('cancelar dejo %s, esperado {stock 75, lotes [5,50], bolsa 20}: las 15 de L1 vuelven a L1', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 0,
                    format('el pedido cancelado sigue con huella %s en L1', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L2 %s, L1 %s · pedido_item_lotes pedido %s / cancelado %s · foto %s',
                      v_l2, v_l1, h0, h1, v_f1));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_otra    bigint;
  v_cliente bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
  v_rep     text[] := '{}';
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
  SELECT id INTO v_otra FROM sucursales WHERE id <> v_suc ORDER BY id LIMIT 1;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL OR v_otra IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal % y otra sucursal', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['a', 'b', 'c', 'c2', 'd', 'd2', 'f', 'f2', 'f3', 'x', 'x2', 'x3',
                                'x4', 'x5', 'x6', 'n', 'q',
                                's1', 's2', 's3', 's4', 's4b'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3, $4)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc, v_otra;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
      IF v_out ? 'reporte' THEN
        v_rep := v_rep || (upper(v_caso) || ' · ' || (v_out->>'reporte'));
      END IF;
    END IF;
  END LOOP;

  RAISE EXCEPTION E'%\n- %\n\nREPORTE\n%',
    CASE WHEN cardinality(v_fallas) = 0 THEN 'ENSAYO OK'
         ELSE format('ENSAYO FALLO (%s fallas)', cardinality(v_fallas)) END,
    array_to_string(v_fallas, E'\n- '),
    array_to_string(v_rep, E'\n');
END
$ensayo$;
