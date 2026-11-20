-- =========================================================================
-- NNN · LOS RESIDUALES DE REGALOS Y PROMOS: EL TOPE DE UN REGALO CAMBIADO
--       POR VALOR EN LA EDICIÓN, EL SUSTITUTO DE OTRO RUBRO QUE VALE MÁS Y EL
--       CAMBIO DE FACTOR SIN STOCK
--       (ola 2 del plan #1603, tanda 5, tarjeta C2: PRM-1 y PRM-2 de #1592,
--        H3 de la revisión de B4, N2 de la revisión de B1, y H1 y H2 de la
--        revisión de C2)
--
-- Parcha por ancla, con premisa de md5 sobre los cuerpos vivos (ledger en la
-- 533, los mismos cuerpos de la 530), tres funciones: `actualizar_pedido_items`
-- (sólo su tramo de regalos), `_regalo_tope_de_cadena` y
-- `renormalizar_bloques_por_cambio_factor`. No crea funciones, no cambia firmas
-- ni permisos y no toca tablas (sin locks de tabla). Las tres quedan con
-- `search_path = public, pg_temp` (regla de la 531; la primera y la última son
-- SECURITY DEFINER). Ensayo: scripts/test-regalos-residuales-ola2-1603.sql.
-- Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- 1 · PRM-1 residual (#1592; H3 de la revisión de B4): el tope del regalo de la
--     promo se mide en su corte también cuando el llamador manda la línea
--     cambiada por valor tal como está
-- -------------------------------------------------------------------------
-- Regla del dueño (16/11): el regalo se mide siempre contra el regalo que da
-- la promo, en la cantidad del corte. Promo 2 V → 1 R; el pedido lleva V×20 y
-- R×10, cambiado por valor a W×1 (W vale lo que 10 R). El encargado baja la
-- venta a V×10 (le tocan R×5) y manda el regalo como está, W×1. 1592-b1 (la
-- 519) entiende esa línea como «la de hoy» y la guarda con su corte, 10; pero
-- el tope de `regalo_fuera_de_promo` se medía sobre lo crudo (1 ≤ 5) y
-- entraba: el pedido quedaba con un regalo que vale R×10 contra un derecho de
-- R×5, y el cupo de la promo contaba 10. Mandado en la unidad de la promo
-- (R×10, lo que manda el front) se rechazaba bien. Ahora la edición mide el
-- tope dos veces: sobre lo crudo, como antes, y, si 1592-b1 llevó algún regalo
-- a su corte, sobre lo que mandó el llamador con ese regalo en su corte (el paso
-- 4 de `regalo_fuera_de_promo`, con sus mismas reglas). El rechazo dice el
-- regalo de la promo, lo que se mandó y en qué unidad cuenta cada número: «El
-- regalo de la promo «P» es «R» y, con lo que lleva el pedido, no puede pasar de
-- 5. Mandaste «W» × 1, que lo reemplazó y cuenta como 10 de «R». …». El admin
-- sigue sin tope. El front de hoy manda el
-- corte (`cantidadBaseDeLinea`), así que no le cambia nada: lo ve un bundle
-- viejo o una llamada directa.
--
-- -------------------------------------------------------------------------
-- 2 · PRM-2 residual (#1592; N2 de la segunda revisión de B1): el cambio de
--     factor sin stock en el contenedor se rechaza con su motivo
-- -------------------------------------------------------------------------
-- Con la barra pasada de N (la deja la 520 cuando el recierre de una baja no
-- tiene stock) y el contenedor en 0, cambiar el factor de la promo cierra
-- bloques que no se pueden descontar. Desde la 472 el front guarda por
-- `cambiar_regalo_promocion`, que atrapa el CHECK `productos_stock_no_negativo`
-- y devuelve `contenedor_sin_stock` con el nombre del contenedor; un UPDATE
-- directo (un bundle anterior a la 472, o a mano) recibía el texto crudo del
-- CHECK. Ahora `renormalizar_bloques_por_cambio_factor` rechaza antes de bajar
-- el contenedor, con el motivo en castellano, y con el mismo código, la misma
-- restricción y el id del contenedor en el DETAIL: la RPC sigue devolviendo lo
-- de siempre. El comportamiento no cambia (el cambio de factor sin stock se
-- rechaza, como dice la 472). Que la renormalización cierre sólo lo que el
-- contenedor da y deje el resto en la barra es otro comportamiento, y queda
-- para el dueño. La venta con regalo de esa promo sigue rechazando por stock
-- mientras el contenedor esté en 0: es la regla escrita de la 520 («sólo el
-- alta rechaza por stock insuficiente»).
--
-- -------------------------------------------------------------------------
-- 3 · H1 de la revisión de C2 (#1592): el regalo cambiado por un producto de
--     otro rubro no puede valer más que lo que da la promo cuando la edición
--     la baja
-- -------------------------------------------------------------------------
-- Decisión del dueño (19/11), literal: «No deja guardar así: o vuelve al
-- regalo original (R) o el pedido queda como está. Este bloqueo no es
-- silencioso sino que se avisa». Promo 2 V → 1 R, R a $ 100: un admin cambió
-- R×10 por X×1 (X a $ 1.000, otro rubro). Si el encargado baja la venta a V×2
-- (derecho R×1 = $ 100) y guarda, el cliente se quedaba con X×1. Ahora
-- `_regalo_tope_de_cadena` no le da la exención de «lo que armó un admin se
-- conserva» cuando el corte de la edición es menor que el de la línea guardada
-- y el sustituto es de otro rubro: su tope es el de valor, y la edición se
-- rechaza con `regalo_sustituto_sobre_tope` («el regalo «X» × 1 vale más, a
-- precio de lista, que lo que da la promo «P» ahora («R» × 1). Volvé el regalo
-- a su producto o dejá el pedido como estaba…») y las promos en `promociones`.
-- Vale mandando la unidad de la promo (la pantalla), la línea como está y el
-- sustituto con otra cantidad. No cambia: el mismo rubro, el admin (sin tope,
-- #1592 16/11: «El admin sigue sin tope»), ni una edición que no baja lo que da
-- la promo. La salida del dueño: el regalo que llega con `regalo_original` no
-- hereda la cadena de la línea y entra como el regalo de la promo.
-- Segunda revisión de C2 (H1): tampoco en dos guardados. Sin línea guardada de
-- la cadena (el regalo se cayó y vuelve con la cadena enganchada) cuenta como que
-- bajó; y «volver al regalo original» deja la cadena cerrada con una fila de
-- reparto del regalo a sí mismo (la forma de la mig 275: «lo anterior ya no
-- vale»), así que si el regalo se cae y vuelve, vuelve el regalo de la promo.
-- `regalo_elemento_con_cadena` y su espejo `cadenaDelRegalo` ya no enganchan una
-- cadena con reparto (también un bundle viejo), y PROMO-B no cuenta repartos.
--
-- Revertir: volver las tres funciones a los cuerpos de la premisa (y su
-- `search_path` a `public`).
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos (ledger en la 533) y lo que el arreglo usa tal
-- como está (la regla del tope de la promo y la del sustituto).
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'ab1726cabaf6d2d324cf71cd522385ee'),
    ('public.renormalizar_bloques_por_cambio_factor()', '2b282b2a6629e3b067f4de39157889e9'),
    ('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', '29f0aa33fd68e34746cb959550f6212f'),
    ('public.regalo_tope_promo(jsonb,jsonb,numeric,numeric)', 'c075ce6f17844ba31466c6ccb9f4f5d1'),
    ('public.regalo_raiz_cadena(bigint,bigint,bigint,bigint,uuid)', '9300c56aeea585f3ae883c806e0e1062'),
    ('public._regalo_tope_de_cadena(bigint,bigint,bigint,bigint,numeric,uuid)', '82c25d84bb5a13efac0105c78f4d8c8a'),
    ('public.regalo_elemento_con_cadena(bigint,bigint,bigint,jsonb,integer)', 'fa8e411b125abd44bc2fcdc7acf8c9a1')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
END
$premisas$;

-- Los tramos que se cambian: la función, el ancla y su reemplazo. La
-- poscondición los vuelve a poner al revés y compara con el md5 de la premisa.
CREATE TEMP TABLE c2_tramos (ord int PRIMARY KEY, fn text, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO c2_tramos VALUES
-- 1 · PRM-1 residual
(1, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'declaraciones',
$a$  v_cadena       UUID;
$a$,
$r$  v_cadena       UUID;
  -- PRM-1 residual (#1592, C2 de la ola 2 de #1603): el JSON antes de 1592-b1, y lo
  -- que mandó el llamador con cada regalo que 1592-b1 llevó a su corte.
  v_items_pre    JSONB;
  v_conv         JSONB;
  v_cant_corte   JSONB;
  -- H1 de la segunda revisión de C2: las cadenas que esta edición devuelve al regalo original.
  v_cerrar       JSONB;
$r$),
(2, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'antes de 1592-b1',
$a$  SELECT COALESCE(jsonb_agg(CASE WHEN l.corte IS NOT NULL
$a$,
$r$  v_items_pre := v_items;
  SELECT COALESCE(jsonb_agg(CASE WHEN l.corte IS NOT NULL
$r$),
(3, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'después de 1592-b1',
$a$    ) l ON true;
$a$,
$r$    ) l ON true;

  -- PRM-1 residual (#1592; H3 de la revisión de B4): el tope de la promo va en su
  -- corte. Un regalo que 1592-b1 llevó a su corte (W×1 que vale R×10 queda con corte
  -- 10) se medía crudo (1) contra el tope: con la venta a la baja, R×5 de derecho,
  -- entraba con un regalo de R×10. v_cant_corte es lo que mandó el llamador con esos
  -- regalos en su corte (NULL si no hay ninguno). 1592-b1 sólo toca una promo con una
  -- línea en el pedido y una en el JSON, que no pasó por el reparto conservado: su
  -- elemento de v_items es el de p_items_nuevos.
  -- v_conv guarda, de cada uno, la promo, el producto que mandó, la cantidad que
  -- mandó, su corte y el regalo de la raíz de su cadena (para decirlo en el rechazo).
  SELECT jsonb_agg(jsonb_build_object(
           'o', b.o, 'e', b.e,
           'promo', (b.e->>'promocion_id')::BIGINT,
           'producto', (b.e->>'producto_id')::BIGINT,
           'enviado', (a.e->>'cantidad')::NUMERIC,
           'corte', (b.e->>'cantidad')::NUMERIC,
           'raiz', (SELECT public.regalo_raiz_cadena(p_pedido_id, pi.promocion_id, pi.producto_id,
                                                     v_sucursal, pi.regalo_cadena_id)
                      FROM pedido_items pi
                     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                       AND COALESCE(pi.es_bonificacion, false)
                       AND pi.promocion_id = (b.e->>'promocion_id')::BIGINT
                     ORDER BY pi.id LIMIT 1))
         ORDER BY b.o)
    INTO v_conv
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS b(e, o)
    JOIN jsonb_array_elements(v_items_pre) WITH ORDINALITY AS a(e, o) ON a.o = b.o
   WHERE a.e->>'cantidad' IS DISTINCT FROM b.e->>'cantidad';
  IF v_conv IS NOT NULL THEN
    SELECT COALESCE((SELECT jsonb_agg(x.e ORDER BY x.o)
                       FROM jsonb_array_elements(p_items_nuevos) WITH ORDINALITY AS x(e, o)
                      WHERE NOT (COALESCE((x.e->>'es_bonificacion')::BOOLEAN, false)
                                 AND NULLIF(x.e->>'promocion_id', '')::BIGINT IN
                                     (SELECT (c->>'promo')::BIGINT FROM jsonb_array_elements(v_conv) c))), '[]'::jsonb)
           || (SELECT jsonb_agg(c->'e' ORDER BY (c->>'o')::INT) FROM jsonb_array_elements(v_conv) c)
      INTO v_cant_corte;
  END IF;
$r$),
(4, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'el tope en el corte',
$a$      IF v_motivo_regalo IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_regalo || ' El pedido no se modificó.'));
      END IF;
$a$,
$r$      IF v_motivo_regalo IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_regalo || ' El pedido no se modificó.'));
      END IF;
      -- PRM-1 residual: y con el regalo cambiado por valor en su corte. Lo demás que
      -- mira regalo_fuera_de_promo (la promo, su vigencia, el producto, la exclusión)
      -- ya pasó arriba con lo mismo: sólo puede fallar su paso 4, la cantidad, que se
      -- repite acá (las mismas reglas vivas y regalo_tope_promo) para poder decir qué
      -- regalo, qué se mandó y en qué unidad cuenta cada número (H2 de la revisión de C2).
      IF v_cant_corte IS NOT NULL THEN
        SELECT format('El regalo de la promo «%s» es «%s» y, con lo que lleva el pedido, no puede pasar de %s. '
                      || 'Mandaste «%s» × %s, que lo reemplazó y cuenta como %s de «%s». Bajá el regalo o '
                      || 'volvelo a su producto; para dejarlo así, el pedido lo tiene que editar un admin.',
                      p.nombre, COALESCE(rp.nombre, 'el regalo de la promo'), t.tope,
                      COALESCE(sp.nombre, 'otro producto'), trim_scale(x.enviado), trim_scale(x.corte),
                      COALESCE(rp.nombre, 'el regalo de la promo'))
          INTO v_motivo_regalo
          FROM jsonb_to_recordset(v_conv) AS x(promo BIGINT, producto BIGINT, enviado NUMERIC, corte NUMERIC, raiz BIGINT)
          JOIN promociones p ON p.id = x.promo AND p.sucursal_id = v_sucursal
          CROSS JOIN LATERAL (
            SELECT public.regalo_tope_promo(
                     v_cant_corte,
                     COALESCE((SELECT jsonb_agg(pp.producto_id ORDER BY pp.producto_id)
                                 FROM promocion_productos pp
                                WHERE pp.promocion_id = p.id AND pp.sucursal_id = v_sucursal), '[]'::jsonb),
                     (SELECT rg.valor FROM promocion_reglas rg
                       WHERE rg.promocion_id = p.id AND rg.clave = 'cantidad_compra'),
                     (SELECT rg.valor FROM promocion_reglas rg
                       WHERE rg.promocion_id = p.id AND rg.clave = 'cantidad_bonificacion')) AS tope) t
          CROSS JOIN LATERAL (
            SELECT COALESCE(SUM(COALESCE(NULLIF(e->>'cantidad', '')::NUMERIC, 0)), 0) AS suma
              FROM jsonb_array_elements(v_cant_corte) e
             WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
               AND NULLIF(e->>'promocion_id', '')::BIGINT = p.id) s
          LEFT JOIN productos rp ON rp.id = x.raiz AND rp.sucursal_id = v_sucursal
          LEFT JOIN productos sp ON sp.id = x.producto AND sp.sucursal_id = v_sucursal
         WHERE s.suma > t.tope
         ORDER BY x.promo
         LIMIT 1;
        IF v_motivo_regalo IS NOT NULL THEN
          RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
            v_motivo_regalo || ' El pedido no se modificó.'));
        END IF;
      END IF;
$r$),
-- 3 · H1 de la revisión de C2 (decisión del dueño del 19/11): el regalo que vuelve a su producto
(6, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'volver al regalo original',
$a$             WHEN x.e->>'_reparto' IS NOT DISTINCT FROM v_marca_reparto
               THEN x.e
$a$,
$r$             WHEN x.e->>'_reparto' IS NOT DISTINCT FROM v_marca_reparto
               THEN x.e
             -- H1 de la revisión de C2 (#1592, decisión del dueño del 19/11): «o vuelve al
             -- regalo original (R) o el pedido queda como está». El regalo que llega con
             -- `regalo_original` no hereda la cadena de la línea: entra como el regalo de la
             -- promo, sin el cambio, y se mide como cualquier regalo (producto, tope, stock).
             WHEN COALESCE((x.e->>'regalo_original')::BOOLEAN, false)
               THEN (x.e - '_reparto' - '_cadena' - 'regalo_original') || jsonb_build_object('_cadena', NULL)
$r$),
(7, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'el rechazo del sustituto caro',
$a$      v_sobre_tope TEXT;
$a$,
$r$      v_sobre_tope TEXT;
      v_promos_tope JSONB;
$r$),
(8, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'el mensaje del sustituto caro',
$a$      SELECT string_agg(format('%s de %s, y quien no es admin puede llegar hasta %s',
                               round(t.cantidad_final)::bigint, COALESCE(pr.nombre, '#' || t.producto_final),
                               round(t.tope)::bigint),
                        '; ' ORDER BY t.producto_final)
        INTO v_sobre_tope
        FROM jsonb_array_elements(v_items) e
       CROSS JOIN LATERAL public._regalo_tope_de_cadena(
               p_pedido_id, (e->>'promocion_id')::BIGINT, (e->>'producto_id')::BIGINT, v_sucursal,
               (e->>'cantidad')::NUMERIC, (e->>'_cadena')::UUID) t
        LEFT JOIN productos pr ON pr.id = t.producto_final AND pr.sucursal_id = v_sucursal
       WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
         AND e->>'promocion_id' IS NOT NULL
         AND e->>'_reparto' IS DISTINCT FROM v_marca_reparto
         AND t.cantidad_final > t.tope;
      IF v_sobre_tope IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
          'Con este cambio, un regalo cambiado por otro producto pasaría a valer más, a precio de lista, que el regalo que da la promo: quedaría en %s. Sólo un admin puede dejarlo así: pedile que edite el pedido, o volvé el regalo a su producto. El pedido no se modificó.',
          v_sobre_tope)), 'codigo', 'regalo_sustituto_sobre_tope');
      END IF;
$a$,
$r$      -- H1 y H2 de la revisión de C2: el mensaje dice el regalo cambiado, lo que da la promo
      -- ahora (su regalo y la cantidad del corte) y las dos salidas del dueño, sin ids; y
      -- `promociones` le dice al front qué regalo puede volver a su producto.
      SELECT string_agg(format('el regalo «%s» × %s vale más, a precio de lista, que lo que da la promo «%s» ahora («%s» × %s)',
                               COALESCE(pr.nombre, 'cambiado'), trim_scale(t.cantidad_final),
                               COALESCE(pm.nombre, 'del pedido'), COALESCE(rg.nombre, 'su regalo'),
                               trim_scale((e->>'cantidad')::NUMERIC)),
                        '; ' ORDER BY t.producto_final),
             jsonb_agg(DISTINCT (e->>'promocion_id')::BIGINT)
        INTO v_sobre_tope, v_promos_tope
        FROM jsonb_array_elements(v_items) e
       CROSS JOIN LATERAL public._regalo_tope_de_cadena(
               p_pedido_id, (e->>'promocion_id')::BIGINT, (e->>'producto_id')::BIGINT, v_sucursal,
               (e->>'cantidad')::NUMERIC, (e->>'_cadena')::UUID) t
        LEFT JOIN productos pr ON pr.id = t.producto_final AND pr.sucursal_id = v_sucursal
        LEFT JOIN productos rg ON rg.id = (e->>'producto_id')::BIGINT AND rg.sucursal_id = v_sucursal
        LEFT JOIN promociones pm ON pm.id = (e->>'promocion_id')::BIGINT AND pm.sucursal_id = v_sucursal
       WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
         AND e->>'promocion_id' IS NOT NULL
         AND e->>'_reparto' IS DISTINCT FROM v_marca_reparto
         AND t.cantidad_final > t.tope;
      IF v_sobre_tope IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
          'Con este cambio, %s. Volvé el regalo a su producto o dejá el pedido como estaba; para dejarlo así, el pedido lo tiene que editar un admin. El pedido no se modificó.',
          v_sobre_tope)), 'codigo', 'regalo_sustituto_sobre_tope', 'promociones', v_promos_tope);
      END IF;
$r$),
(9, 'public._regalo_tope_de_cadena(bigint,bigint,bigint,bigint,numeric,uuid)', 'declaraciones',
$a$  v_t         numeric;
$a$,
$r$  v_t         numeric;
  v_reg       bigint;
  v_corte_g   numeric;
$r$),
(10, 'public._regalo_tope_de_cadena(bigint,bigint,bigint,bigint,numeric,uuid)', 'sin la exención cuando baja el derecho',
$a$  SELECT t.tope INTO v_t
    FROM public._regalo_tope_de_linea(p_pedido_id, p_promocion_id, p_sucursal_id, p_cadena, p_producto_id,
                                      p_cantidad, v_s.producto_sustituto_id, v_s.ajuste_producto_id_nuevo) t;
  producto_final := v_s.producto_sustituto_id;
  cantidad_final := v_cant;
  tope := GREATEST(v_s.cantidad_sustituta, COALESCE(v_t, 0) + array_length(v_pasos, 1));
$a$,
$r$  SELECT t.regalo, t.tope INTO v_reg, v_t
    FROM public._regalo_tope_de_linea(p_pedido_id, p_promocion_id, p_sucursal_id, p_cadena, p_producto_id,
                                      p_cantidad, v_s.producto_sustituto_id, v_s.ajuste_producto_id_nuevo) t;
  producto_final := v_s.producto_sustituto_id;
  cantidad_final := v_cant;
  -- H1 de la revisión de C2 (#1592, decisión del dueño del 19/11: «No deja guardar así: o
  -- vuelve al regalo original (R) o el pedido queda como está»). Lo que armó un admin se
  -- conserva y no crece, SALVO que el corte de esta edición sea menor que el de la línea
  -- guardada (bajó lo que da la promo), o que no haya línea guardada, y el sustituto sea de
  -- otro rubro: ahí no tiene la
  -- exención y su tope es el de valor. El mismo rubro no cambia (igual o menor cantidad).
  SELECT SUM(COALESCE(pi.regalo_corte,
                      public.regalo_usos_de_linea(public.regalo_eslabones(p_pedido_id, p_promocion_id, p_sucursal_id),
                                                  pi.regalo_cadena_id, pi.cantidad)))
    INTO v_corte_g
    FROM pedido_items pi
   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal_id
     AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = p_promocion_id
     AND pi.regalo_cadena_id = p_cadena;
  -- Sin línea guardada de esa cadena (el regalo se cayó y vuelve, y la cadena se volvió a
  -- enganchar) tampoco hay exención: cuenta como que bajó (H1 de la segunda revisión de C2).
  IF (v_corte_g IS NULL OR p_cantidad < v_corte_g)
     AND v_reg IS DISTINCT FROM v_s.producto_sustituto_id
     AND NOT COALESCE(public.regalo_misma_categoria(v_reg, v_s.producto_sustituto_id, p_sucursal_id), false) THEN
    tope := COALESCE(v_t, 0);
  ELSE
    tope := GREATEST(v_s.cantidad_sustituta, COALESCE(v_t, 0) + array_length(v_pasos, 1));
  END IF;
$r$),
(11, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'qué cadena vuelve al original',
$a$  -- mig 338 (#1057): la clave de cadena de cada regalo (ver
$a$,
$r$  -- H1 de la segunda revisión de C2 (decisión del dueño del 19/11): el regalo que vuelve al
  -- original deja su cadena CERRADA, para que si después se cae y vuelve, vuelva el regalo
  -- de la promo y no el cambio. Se anota acá qué cadena habría heredado (la misma cuenta que
  -- la CASE de abajo) y se cierra al final, cuando la edición ya no se puede rechazar.
  SELECT jsonb_agg(jsonb_build_object(
           'promo', (x.e->>'promocion_id')::BIGINT,
           'cadena', z.c->>'_cadena',
           'raiz', (z.c->>'producto_id')::BIGINT,
           'corte', (z.c->>'cantidad')::NUMERIC))
    INTO v_cerrar
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o)
   CROSS JOIN LATERAL (
     SELECT public.regalo_elemento_con_cadena(
              p_pedido_id, (x.e->>'promocion_id')::BIGINT, v_sucursal, x.e - '_reparto' - 'regalo_original',
              (SELECT count(*)::INT FROM jsonb_array_elements(v_items) j
                WHERE COALESCE((j->>'es_bonificacion')::BOOLEAN, false)
                  AND j->>'promocion_id' = x.e->>'promocion_id'
                  AND j->>'_reparto' IS DISTINCT FROM v_marca_reparto)) AS c) z
   WHERE COALESCE((x.e->>'es_bonificacion')::BOOLEAN, false)
     AND x.e->>'promocion_id' IS NOT NULL
     AND x.e->>'_reparto' IS DISTINCT FROM v_marca_reparto
     AND COALESCE((x.e->>'regalo_original')::BOOLEAN, false)
     AND z.c->>'_cadena' IS NOT NULL;

  -- mig 338 (#1057): la clave de cadena de cada regalo (ver
$r$),
(12, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'la cadena queda cerrada',
$a$  PERFORM public._guardar_combos_pedido(p_pedido_id, v_sucursal);
$a$,
$r$  PERFORM public._guardar_combos_pedido(p_pedido_id, v_sucursal);

  -- H1 de la segunda revisión de C2: la cadena que volvió al regalo original queda cerrada
  -- con una fila de reparto (la forma que ya existe: «lo anterior ya no vale», mig 275) del
  -- regalo de la promo a sí mismo con su corte. Así `regalo_elemento_con_cadena` (sin línea
  -- de la promo) y su espejo `cadenaDelRegalo` no la vuelven a enganchar: si el regalo se
  -- cae y vuelve, vuelve el regalo de la promo. PROMO-B no cuenta filas de reparto.
  IF v_cerrar IS NOT NULL THEN
    INSERT INTO pedido_item_sustituciones (
      pedido_id, pedido_item_id, promocion_id, producto_original_id, producto_sustituto_id,
      cantidad_original, cantidad_sustituta, motivo, autorizado_por, sucursal_id,
      reparto_id, cadena_id, producto_raiz_id)
    SELECT p_pedido_id, NULL, (c->>'promo')::BIGINT, (c->>'raiz')::BIGINT, (c->>'raiz')::BIGINT,
           (c->>'corte')::NUMERIC, (c->>'corte')::NUMERIC,
           'Volvió al regalo original al editar el pedido', p_usuario_id, v_sucursal,
           gen_random_uuid(), (c->>'cadena')::UUID, (c->>'raiz')::BIGINT
      FROM jsonb_array_elements(v_cerrar) c
     ORDER BY (c->>'promo')::BIGINT;
  END IF;
$r$),
-- 2 · PRM-2 residual
(5, 'public.renormalizar_bloques_por_cambio_factor()', 'el rechazo con su motivo',
$a$    v_stock_nue := COALESCE(v_stock_ant, 0) - v_unidades;
$a$,
$r$    v_stock_nue := COALESCE(v_stock_ant, 0) - v_unidades;
    -- PRM-2 residual (#1592; N2 de la revisión de B1): el contenedor no alcanza para los
    -- bloques que cierra el factor nuevo. Se rechaza como siempre, pero con su motivo y no
    -- con el texto crudo del CHECK. Va como ese CHECK (23514, productos_stock_no_negativo, y
    -- el id del contenedor en el DETAIL), que es lo que mira cambiar_regalo_promocion (472)
    -- para devolver su contenedor_sin_stock.
    IF v_stock_nue < 0 THEN
      RAISE EXCEPTION USING
        ERRCODE    = 'check_violation',
        CONSTRAINT = 'productos_stock_no_negativo',
        MESSAGE    = format('El contenedor «%s» no tiene stock para el factor nuevo de la promoción (hay %s, y el cambio cierra %s %s que %s %s). No se guardó el cambio: reponé el contenedor o elegí otro factor.',
                            COALESCE((SELECT nombre FROM productos
                                       WHERE id = v_barra.contenedor AND sucursal_id = NEW.sucursal_id),
                                     'ID ' || v_barra.contenedor),
                            COALESCE(v_stock_ant, 0), v_bloques,
                            CASE WHEN v_bloques = 1 THEN 'bloque' ELSE 'bloques' END,
                            CASE WHEN v_bloques = 1 THEN 'descuenta' ELSE 'descuentan' END, v_unidades),
        DETAIL     = format('Contenedor (%s, stock %s, pide %s).', v_barra.contenedor, COALESCE(v_stock_ant, 0), v_unidades);
    END IF;
$r$);

-- =========================================================================
-- El parche: cada función con sus tramos, y su search_path con pg_temp al final
-- =========================================================================
DO $parche$
DECLARE
  f     text;
  v_def text;
  r     record;
  v_n   int;
BEGIN
  FOR f IN SELECT DISTINCT fn FROM c2_tramos ORDER BY 1 LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    FOR r IN SELECT * FROM c2_tramos WHERE fn = f ORDER BY ord LOOP
      v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el ancla aparece % vez/veces y se esperaba 1', f, r.que, v_n;
      END IF;
      v_def := replace(v_def, r.ancla, r.nuevo);
    END LOOP;
    -- 531 (B15): una definer lleva pg_temp al final de su search_path. Un CREATE OR
    -- REPLACE sin la cláusula SET la borraría: va la de antes, con pg_temp.
    v_n := (length(v_def) - length(replace(v_def, E' SET search_path TO ''public''\n', ''))) / length(E' SET search_path TO ''public''\n');
    IF v_n = 1 THEN
      v_def := replace(v_def, E' SET search_path TO ''public''\n', E' SET search_path TO ''public'', ''pg_temp''\n');
    ELSIF position(E' SET search_path TO ''public'', ''pg_temp''\n' IN v_def) = 0 THEN
      RAISE EXCEPTION 'mig NNN · %: no encuentro su search_path', f;
    END IF;
    EXECUTE v_def;
  END LOOP;
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos nuevos son los del repo, el resto de cada cuerpo no
-- cambió (deshaciendo sus tramos vuelve el md5 de la premisa), y el definer (o no), el
-- search_path y los EXECUTE son los de antes, con pg_temp.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text;
  r     record;
  t     record;
  x     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
     '11693bc941b3ae7f38eccc1748853f1a', 'ab1726cabaf6d2d324cf71cd522385ee',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.renormalizar_bloques_por_cambio_factor()',
     '61e0ed9c7ab53c79e95c9ebfaf64e446', '2b282b2a6629e3b067f4de39157889e9',
     '{postgres=X/postgres,service_role=X/postgres}', true),
    ('public._regalo_tope_de_cadena(bigint,bigint,bigint,bigint,numeric,uuid)',
     'cd46ab61ac31683dd3d3910493e44744', '82c25d84bb5a13efac0105c78f4d8c8a',
     '{postgres=X/postgres,service_role=X/postgres}', false)
  ) AS v(fn, h, h_antes, acl, def) LOOP
    SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
    v_src := x.prosrc;
    FOR t IN SELECT * FROM c2_tramos WHERE fn = r.fn ORDER BY ord DESC LOOP
      IF (length(v_src) - length(replace(v_src, t.nuevo, ''))) / length(t.nuevo) <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el tramo nuevo no aparece una vez', r.fn, t.que;
      END IF;
      v_src := replace(v_src, t.nuevo, t.ancla);
    END LOOP;
    IF md5(v_src) IS DISTINCT FROM r.h_antes THEN
      RAISE EXCEPTION 'mig NNN · % cambió fuera de sus tramos (md5 sin el parche %)', r.fn, md5(v_src);
    END IF;
  END LOOP;
END
$post$;

COMMIT;
