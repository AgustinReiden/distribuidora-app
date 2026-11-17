-- =========================================================================
-- NNN · LA EDICIÓN DE UN PEDIDO Y LA SUSTITUCIÓN DE UN REGALO MUEVEN SÓLO LA
--       DIFERENCIA DE LA BARRA DE REGALOS: NO PASAN EL FARDO DEL CONTENEDOR
--       DE LA BOLSA AL LOTE
--       (ola 2 del plan #1603, tarjeta B19: H1 de la revisión de la tarjeta B3;
--        v2: H1 a H6 de la revisión de la tarjeta B19)
--
-- Crea un helper de server (`_barra_mover_neto`) y parcha por ancla, con
-- premisa de md5 sobre los cuerpos vivos (ledger en la 525),
-- `actualizar_pedido_items` (el de la 519) y `sustituir_regalo_pedido`. En
-- las dos toca sólo el tramo de la barra: el resto del cuerpo (precios, piso y
-- techo, versión del pedido, mínimos, promos, stock de las líneas, huella)
-- queda igual, y la poscondición lo comprueba. No cambia firmas ni permisos,
-- no toca tablas y no toca el motor de la barra (`aplicar_uso_promo_acumulador`).
-- Ensayo: scripts/test-barra-edicion-ola2-1603.sql. Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- El problema
-- -------------------------------------------------------------------------
-- Una promo de fracción junta los regalos en una barra y cada N cierra un
-- bloque que saca un fardo del contenedor. El bloque anota de dónde salió el
-- fardo (`promo_ajustes.lotes_pendientes`: un lote, o {"lote_id": null} para
-- la bolsa), y deshacerlo se lo devuelve a ese lote (#1558, STK-19).
-- La edición deshacía la barra entera del pedido con el motor en negativo
-- (el fardo volvía al lote que nombraba el bloque) y, con las líneas nuevas,
-- la volvía a cerrar en positivo: esa bajada come primero la bolsa. Con un lote
-- de 100 con 49 (el fardo del pedido ya afuera) y la bolsa en 10, una edición
-- SIN CAMBIOS dejaba el lote en 50 y la bolsa en 9, y el bloque nuevo decía
-- que su fardo salió de la bolsa. El stock no cambiaba, así que LOTE-A no lo
-- ve; si el pedido se entregaba quedaba para siempre (el lote «tiene» un
-- fardo que no existe, y darlo de baja merma uno de más). Además cada edición
-- dejaba una ida y vuelta en `promo_ajustes` y en `mermas_stock`.
-- Lo mismo pasaba cuando el regalo cambia de barra y las dos barras descuentan
-- del mismo contenedor (otro sabor, o el regalo que pasa de una promo a otra
-- con el mismo fardo: en producción hay dos contenedores de los que descuentan
-- dos barras cada uno), y en la sustitución de un regalo (`-cantidad` en la
-- barra del original y `+cantidad` en la del sustituto).
--
-- -------------------------------------------------------------------------
-- El arreglo
-- -------------------------------------------------------------------------
-- `_barra_mover_neto(movimientos, sucursal, usuario)` recibe lo que una
-- operación le resta y le suma a cada barra (por promo y producto: la barra de
-- ese sabor) y:
--   1. suma por barra y llama al motor UNA vez por barra con la diferencia, si
--      no es 0: primero las que bajan (abren los bloques de esa barra del
--      último al primero y cada fardo vuelve al lote o a la bolsa de donde
--      salió) y después las que suben (cierran bloques nuevos, que salen del
--      stock de hoy como en el alta), por promo y producto;
--   2. si hay bajadas y subidas, lo que las bajadas le devolvieron a un lote de
--      un contenedor de esas promos vuelve a la bolsa antes de las subidas, la
--      parte {"lote_id": null} de los bloques que cierran las subidas hereda
--      esos lotes (en el orden del motor: la bolsa primero y los lotes por
--      vencimiento), y lo que no se vuelve a cerrar vuelve a su lote. Es el
--      molde M3-1 del cambio de cliente (517): un fardo que se abre en una
--      barra y se cierra en otra del mismo contenedor no se mueve. Sólo cambian
--      los contadores de los lotes; el stock y el ledger, no.
-- `actualizar_pedido_items` ya no deshace y rehace: anota lo que el pedido
-- tenía en cada barra (en negativo, con `_regalo_barra_vale` antes de borrar
-- las líneas, como siempre) y lo que le queda (cada regalo reinsertado, con el
-- producto y la cantidad que quedaron en la fila y `_regalo_barra_vale`
-- después de insertarlo), y con las líneas ya insertadas llama al helper.
-- `sustituir_regalo_pedido` (modo de fracción) le pasa la salida del original y
-- la entrada del sustituto en una sola llamada. Así:
--   · una edición que no cambia el regalo de una promo no toca su barra, sus
--     bloques, el contenedor, sus lotes ni la bolsa, y no deja asientos;
--   · una que lo cambia, o una sustitución, mueve sólo la diferencia, y un
--     regalo que pasa a otra barra del mismo contenedor conserva el lote de su
--     fardo;
--   · los textos de los asientos son los de antes ('Edicion pedido #N' en la
--     baja, 'Auto-ajuste (Promo: …, Pedido #N, edicion)' en la suba; los de la
--     sustitución, iguales).
-- El orden de locks no cambia: los productos (con los contenedores, por
-- `_contenedores_de_promos`) y las promos se toman arriba, por id, antes que
-- todo; el motor y el helper sólo re-bloquean.
--
-- -------------------------------------------------------------------------
-- Cambios de comportamiento que quedan (H3, H4 y H6 de la revisión)
-- -------------------------------------------------------------------------
--   · La barra «pasada de N» (la deja la 520 cuando el recierre de una baja no
--     tiene stock): antes, cualquier edición de un pedido con regalo de esa
--     promo deshacía y rehacía y cerraba el bloque atrasado; con el contenedor
--     vacío se rechazaba con «Auto-ajuste: stock insuficiente» aunque no tocara
--     el regalo. Ahora la edición que no cambia el regalo entra y no mueve
--     nada; el bloque atrasado lo cierra la próxima venta (o una edición que
--     suba el regalo), como dice la 520. La que sube el regalo sin stock se
--     sigue rechazando, igual que el alta.
--   · En las promos sin barra de fracción (la que mueve stock, la que no tiene
--     ajuste automático) el motor lleva un contador con piso en 0: la
--     diferencia da lo mismo que deshacer y rehacer salvo cuando el piso
--     cortaba (un contador puesto en 0 por el reinicio), y ahí una edición sin
--     cambios ya no lo sube. Nadie lo lee salvo la pantalla de la promo.
--   · El motor corre después de insertar todas las líneas y las subidas van por
--     (promo, producto), no en el orden del JSON: si una edición tiene a la vez
--     un fardo sin stock y otro error en una línea posterior, el aviso que llega
--     puede ser el otro (las dos rechazan entera), y con dos subidas sobre el
--     mismo contenedor y la bolsa justa cambia cuál bloque queda anotado en la
--     bolsa y cuál en un lote (los totales son los mismos).
--
-- Revertir: volver `actualizar_pedido_items` y `sustituir_regalo_pedido` a los
-- cuerpos de la premisa y `DROP FUNCTION public._barra_mover_neto(jsonb,bigint,uuid);`.
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
-- Premisas: los cuerpos vivos (ledger en la 525) y las piezas con las que
-- cuenta el arreglo: el motor de la 520 (abre del último bloque al primero y
-- devuelve cada fardo a donde salió), el reparto de un lote de la 483 y la
-- lista de contenedores de la 520.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '387beb9228d1751823bc2a6c710b9098'),
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', '243714f196f2dae7ae9cb8bdf43b54a1'),
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'b55ff7a09db621f71f6e29d55bfea808'),
    ('public._mov_lotes_devolver(bigint,jsonb)', '83ef22b3b0143bf318ead07069ac916e'),
    ('public._contenedores_de_promos(bigint[],bigint)', 'a9febeec0cb96eef6751cb16cc9da6bf')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regprocedure('public._barra_mover_neto(jsonb,bigint,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · _barra_mover_neto ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- =========================================================================
-- _barra_mover_neto: la diferencia de cada barra, y el fardo que pasa de una
-- barra a otra del mismo contenedor no se mueve
-- =========================================================================
-- p_movs: [{promocion_id, producto_id, delta, ajuste_def?, motivo}]. De server:
-- la llaman RPCs DEFINER que ya tomaron los productos (con los contenedores de
-- sus promos, `_contenedores_de_promos`) y las promos, por id.
CREATE FUNCTION public._barra_mover_neto(p_movs jsonb, p_sucursal_id bigint, p_usuario_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_netos      JSONB;
  m            RECORD;
  v_hay_baja   BOOLEAN;
  v_hay_suba   BOOLEAN;
  v_promos     BIGINT[];
  v_conts      BIGINT[];
  v_antes      JSONB;
  v_fardos     JSONB := '[]'::jsonb;
  v_ajuste_max BIGINT := 0;
  v_bloque     RECORD;
  v_el         JSONB;
  v_nuevos     JSONB;
  v_pend       INT;
  v_toma       INT;
  v_sobra      JSONB;
BEGIN
  -- La diferencia de cada barra (promo, producto). El contenedor para un
  -- acumulador que todavía no existe es el que diga la entrada que suma (la
  -- sustitución elige el del sustituto) y, si no, el producto. El texto del
  -- asiento es el de una entrada del mismo signo que la diferencia.
  WITH e AS (
    SELECT t.o,
           (t.x->>'promocion_id')::BIGINT AS promocion_id,
           NULLIF(t.x->>'producto_id', '')::BIGINT AS producto_id,
           (t.x->>'delta')::NUMERIC AS delta,
           NULLIF(t.x->>'ajuste_def', '')::BIGINT AS ajuste_def,
           t.x->>'motivo' AS motivo
      FROM jsonb_array_elements(COALESCE(p_movs, '[]'::jsonb)) WITH ORDINALITY AS t(x, o)
     WHERE COALESCE((t.x->>'delta')::NUMERIC, 0) <> 0
  ), n AS (
    SELECT e.promocion_id, e.producto_id, SUM(e.delta) AS delta
      FROM e
     GROUP BY e.promocion_id, e.producto_id
    HAVING SUM(e.delta) <> 0
  )
  SELECT jsonb_agg(jsonb_build_object(
           'promocion_id', n.promocion_id,
           'producto_id', n.producto_id,
           'delta', n.delta,
           'ajuste_def', COALESCE(
             (SELECT e.ajuste_def FROM e
               WHERE e.promocion_id = n.promocion_id AND e.producto_id IS NOT DISTINCT FROM n.producto_id
                 AND e.ajuste_def IS NOT NULL
               ORDER BY (e.delta > 0) DESC, e.o LIMIT 1),
             n.producto_id),
           'motivo', (SELECT e.motivo FROM e
                       WHERE e.promocion_id = n.promocion_id AND e.producto_id IS NOT DISTINCT FROM n.producto_id
                         AND sign(e.delta) = sign(n.delta)
                       ORDER BY e.o LIMIT 1)))
    INTO v_netos
    FROM n;
  IF v_netos IS NULL THEN
    RETURN;
  END IF;

  v_hay_baja := EXISTS (SELECT 1 FROM jsonb_array_elements(v_netos) x WHERE (x->>'delta')::NUMERIC < 0);
  v_hay_suba := EXISTS (SELECT 1 FROM jsonb_array_elements(v_netos) x WHERE (x->>'delta')::NUMERIC > 0);
  v_promos := ARRAY(SELECT DISTINCT (x->>'promocion_id')::BIGINT FROM jsonb_array_elements(v_netos) x ORDER BY 1);

  -- Con bajadas y subidas: los lotes de los contenedores de esas promos antes
  -- de las bajadas (las bajadas devuelven el fardo de un bloque vivo, y su
  -- contenedor está en la lista). Los productos están tomados por el llamador.
  IF v_hay_baja AND v_hay_suba THEN
    v_conts := ARRAY(SELECT c FROM public._contenedores_de_promos(v_promos, p_sucursal_id) c ORDER BY c);
    SELECT COALESCE(jsonb_object_agg(l.id::TEXT, l.cantidad_restante), '{}'::jsonb)
      INTO v_antes
      FROM producto_lotes l
     WHERE l.producto_id = ANY(v_conts) AND l.sucursal_id = p_sucursal_id;
  END IF;

  FOR m IN
    SELECT (x->>'promocion_id')::BIGINT AS promocion_id, (x->>'producto_id')::BIGINT AS producto_id,
           (x->>'delta')::NUMERIC AS delta, (x->>'ajuste_def')::BIGINT AS ajuste_def, x->>'motivo' AS motivo
      FROM jsonb_array_elements(v_netos) x
     WHERE (x->>'delta')::NUMERIC < 0
     ORDER BY 1, 2
  LOOP
    PERFORM public.aplicar_uso_promo_acumulador(
      m.promocion_id, m.producto_id, m.delta, m.ajuste_def, p_sucursal_id, p_usuario_id, m.motivo);
  END LOOP;

  IF v_hay_baja AND v_hay_suba THEN
    -- Lo que las bajadas le devolvieron a un lote del contenedor vuelve a la
    -- bolsa (sólo el contador del lote: el stock y el ledger no se mueven): las
    -- subidas lo comen primero, y abajo su bloque dice de qué lote salió.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'lote_id', l.id, 'producto_id', l.producto_id,
             'cantidad', l.cantidad_restante - (v_antes->>l.id::TEXT)::INT)
             ORDER BY l.fecha_vencimiento, l.id), '[]'::jsonb)
      INTO v_fardos
      FROM producto_lotes l
     WHERE l.producto_id = ANY(v_conts) AND l.sucursal_id = p_sucursal_id
       AND v_antes ? l.id::TEXT
       AND l.cantidad_restante > (v_antes->>l.id::TEXT)::INT;
    IF jsonb_array_length(v_fardos) > 0 THEN
      UPDATE producto_lotes l
         SET cantidad_restante = (v_antes->>l.id::TEXT)::INT
       WHERE l.producto_id = ANY(v_conts) AND l.sucursal_id = p_sucursal_id
         AND v_antes ? l.id::TEXT
         AND l.cantidad_restante > (v_antes->>l.id::TEXT)::INT;
    END IF;
    -- Los bloques que cierren las subidas son los de id mayor: las promos están
    -- tomadas y nadie más les escribe bloques.
    v_ajuste_max := COALESCE((SELECT max(pa.id) FROM promo_ajustes pa
                               WHERE pa.promocion_id = ANY(v_promos) AND pa.sucursal_id = p_sucursal_id), 0);
  END IF;

  FOR m IN
    SELECT (x->>'promocion_id')::BIGINT AS promocion_id, (x->>'producto_id')::BIGINT AS producto_id,
           (x->>'delta')::NUMERIC AS delta, (x->>'ajuste_def')::BIGINT AS ajuste_def, x->>'motivo' AS motivo
      FROM jsonb_array_elements(v_netos) x
     WHERE (x->>'delta')::NUMERIC > 0
     ORDER BY 1, 2
  LOOP
    PERFORM public.aplicar_uso_promo_acumulador(
      m.promocion_id, m.producto_id, m.delta, m.ajuste_def, p_sucursal_id, p_usuario_id, m.motivo);
  END LOOP;

  IF jsonb_array_length(v_fardos) > 0 THEN
    -- El bloque que cerró una subida hereda los lotes: la parte que su bajada
    -- sacó de la bolsa ({"lote_id": null}), donde quedó el fardo que abrió una
    -- bajada, pasa a decir el lote de donde salió, por contenedor y en el orden
    -- de los lotes (vencimiento, id). Como el cambio de cliente (517).
    FOR v_bloque IN
      SELECT pa.id, pa.producto_id, pa.lotes_pendientes
        FROM promo_ajustes pa
       WHERE pa.promocion_id = ANY(v_promos) AND pa.sucursal_id = p_sucursal_id
         AND pa.id > v_ajuste_max
         AND pa.lotes_pendientes IS NOT NULL
       ORDER BY pa.id
    LOOP
      v_nuevos := '[]'::jsonb;
      FOR v_el IN
        SELECT a.x FROM jsonb_array_elements(v_bloque.lotes_pendientes) WITH ORDINALITY AS a(x, ord)
         ORDER BY a.ord
      LOOP
        IF v_el->>'lote_id' IS NOT NULL THEN
          v_nuevos := v_nuevos || jsonb_build_array(v_el);
          CONTINUE;
        END IF;
        v_pend := (v_el->>'cantidad')::INT;
        FOR i IN 0 .. jsonb_array_length(v_fardos) - 1 LOOP
          EXIT WHEN v_pend <= 0;
          CONTINUE WHEN (v_fardos->i->>'producto_id')::BIGINT IS DISTINCT FROM v_bloque.producto_id
                     OR (v_fardos->i->>'cantidad')::INT <= 0;
          v_toma := LEAST(v_pend, (v_fardos->i->>'cantidad')::INT);
          v_nuevos := v_nuevos || jsonb_build_array(jsonb_build_object(
                        'lote_id', (v_fardos->i->>'lote_id')::BIGINT, 'cantidad', v_toma));
          v_fardos := jsonb_set(v_fardos, ARRAY[i::TEXT, 'cantidad'],
                                to_jsonb((v_fardos->i->>'cantidad')::INT - v_toma));
          v_pend := v_pend - v_toma;
        END LOOP;
        IF v_pend > 0 THEN
          v_nuevos := v_nuevos || jsonb_build_array(jsonb_build_object('lote_id', NULL, 'cantidad', v_pend));
        END IF;
      END LOOP;
      -- En el orden en que lo anota el motor: primero la bolsa y después los
      -- lotes por vencimiento (el motor deshace del final al principio).
      SELECT CASE WHEN COALESCE(sum((e->>'cantidad')::INT) FILTER (WHERE e->>'lote_id' IS NULL), 0) > 0
                  THEN jsonb_build_array(jsonb_build_object(
                         'lote_id', NULL,
                         'cantidad', sum((e->>'cantidad')::INT) FILTER (WHERE e->>'lote_id' IS NULL)))
                  ELSE '[]'::jsonb END
             || COALESCE((SELECT jsonb_agg(jsonb_build_object('lote_id', x.lote_id, 'cantidad', x.cantidad)
                                           ORDER BY l.fecha_vencimiento, l.id)
                            FROM (SELECT (y->>'lote_id')::BIGINT AS lote_id, sum((y->>'cantidad')::INT) AS cantidad
                                    FROM jsonb_array_elements(v_nuevos) y
                                   WHERE y->>'lote_id' IS NOT NULL
                                   GROUP BY 1) x
                            JOIN producto_lotes l ON l.id = x.lote_id AND l.sucursal_id = p_sucursal_id),
                         '[]'::jsonb)
        INTO v_nuevos
        FROM jsonb_array_elements(v_nuevos) e;
      IF v_nuevos IS DISTINCT FROM v_bloque.lotes_pendientes THEN
        UPDATE promo_ajustes SET lotes_pendientes = v_nuevos WHERE id = v_bloque.id;
      END IF;
    END LOOP;
    -- Lo que no se volvió a cerrar vuelve a su lote.
    SELECT jsonb_agg(jsonb_build_object('lote_id', (x->>'lote_id')::BIGINT, 'cantidad', (x->>'cantidad')::INT))
      INTO v_sobra
      FROM jsonb_array_elements(v_fardos) x
     WHERE (x->>'cantidad')::INT > 0;
    IF v_sobra IS NOT NULL THEN
      PERFORM public._mov_lotes_devolver(p_sucursal_id, v_sobra);
    END IF;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._barra_mover_neto(jsonb, bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._barra_mover_neto(jsonb, bigint, uuid) TO service_role;

COMMENT ON FUNCTION public._barra_mover_neto(jsonb, bigint, uuid) IS
  'mig NNN (B19, ola 2 de #1603): la diferencia de cada barra de regalos, en una llamada al motor por barra (primero las que bajan); el fardo que se abre en una barra y se cierra en otra del mismo contenedor conserva su lote (molde M3-1 de la 517). De server: la llaman actualizar_pedido_items y sustituir_regalo_pedido con los productos y las promos tomados.';

-- Los tramos que se cambian: la función, el ancla y su reemplazo. La
-- poscondición los vuelve a poner al revés y compara con el md5 de la premisa.
CREATE TEMP TABLE b19_tramos (ord int PRIMARY KEY, fn text, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO b19_tramos VALUES
(1, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'declaraciones',
$a$  v_canal        TEXT;
  v_updated_at   TIMESTAMPTZ;
BEGIN
$a$,
$r$  v_canal        TEXT;
  v_updated_at   TIMESTAMPTZ;
  -- B19 (ola 2 de #1603): lo que la edicion le cambia a cada barra, por
  -- "promo:producto": lo que el pedido tenia (en negativo) mas lo que le queda.
  v_barra_neto   JSONB := '{}'::jsonb;
BEGIN
$r$),
(2, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'la barra que el pedido tenía',
$a$  LOOP
    PERFORM public.aplicar_uso_promo_acumulador(
      v_bonif.promocion_id, v_bonif.producto_id, -v_bonif.total_cantidad,
      v_bonif.producto_id, v_sucursal, p_usuario_id,
      'Edicion pedido #' || p_pedido_id);
  END LOOP;
$a$,
$r$  LOOP
    -- B19 (ola 2 de #1603): no se deshace aca. Deshacer la barra entera y volver
    -- a cerrarla con las lineas nuevas devolvia el fardo al lote que nombraba el
    -- bloque y lo volvia a sacar de la bolsa (la bajada come la bolsa primero):
    -- una edicion sin cambios pasaba un fardo de la bolsa al lote. Se anota lo que
    -- el pedido tenia y, con las lineas nuevas insertadas, se mueve la diferencia.
    v_barra_neto := jsonb_set(v_barra_neto,
      ARRAY[v_bonif.promocion_id || ':' || COALESCE(v_bonif.producto_id::TEXT, '')],
      to_jsonb(COALESCE((v_barra_neto->>(v_bonif.promocion_id || ':' || COALESCE(v_bonif.producto_id::TEXT, '')))::NUMERIC, 0)
               - v_bonif.total_cantidad));
  END LOOP;
$r$),
(3, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'la barra que le queda',
$a$      IF public._regalo_barra_vale(p_pedido_id, v_promocion_id, v_sucursal) THEN
        PERFORM public.aplicar_uso_promo_acumulador(
          v_promocion_id, v_producto_guardado, v_cantidad_guardada, v_producto_guardado,
          v_sucursal, p_usuario_id,
          'Auto-ajuste (Promo: '
            || COALESCE((SELECT nombre FROM promociones
                          WHERE id = v_promocion_id AND sucursal_id = v_sucursal), '?')
            || ', Pedido #' || p_pedido_id || ', edicion)');
      END IF;
$a$,
$r$      IF public._regalo_barra_vale(p_pedido_id, v_promocion_id, v_sucursal) THEN
        -- B19: se suma a lo que la barra de ese sabor tiene que mover (abajo).
        v_barra_neto := jsonb_set(v_barra_neto,
          ARRAY[v_promocion_id || ':' || v_producto_guardado],
          to_jsonb(COALESCE((v_barra_neto->>(v_promocion_id || ':' || v_producto_guardado))::NUMERIC, 0)
                   + v_cantidad_guardada));
      END IF;
$r$),
(4, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'la diferencia',
$a$  -- 1559-b3: el precio conservado vale sólo para la reinserción.
  PERFORM set_config('app.edicion_precio_conservado', '', true);
$a$,
$r$  -- B19 (ola 2 de #1603): la barra mueve solo la diferencia, una vez por promo y
  -- producto (la barra de ese sabor), primero lo que baja; y el fardo que se abre
  -- en una barra y se cierra en otra del mismo contenedor conserva su lote
  -- (_barra_mover_neto). Una edicion que no cambia el regalo no toca la barra, los
  -- bloques ni el contenedor. Los productos y las promos ya estan tomados arriba
  -- (#1296, #1460): el motor solo re-bloquea.
  PERFORM public._barra_mover_neto(
    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'promocion_id', split_part(k.key, ':', 1)::BIGINT,
              'producto_id', NULLIF(split_part(k.key, ':', 2), '')::BIGINT,
              'delta', k.value::NUMERIC,
              'motivo', CASE WHEN k.value::NUMERIC < 0
                             THEN 'Edicion pedido #' || p_pedido_id
                             ELSE 'Auto-ajuste (Promo: '
                                  || COALESCE((SELECT pr.nombre FROM promociones pr
                                                WHERE pr.id = split_part(k.key, ':', 1)::BIGINT
                                                  AND pr.sucursal_id = v_sucursal), '?')
                                  || ', Pedido #' || p_pedido_id || ', edicion)' END)), '[]'::jsonb)
       FROM jsonb_each_text(v_barra_neto) k
      WHERE k.value::NUMERIC <> 0),
    v_sucursal, p_usuario_id);

  -- 1559-b3: el precio conservado vale sólo para la reinserción.
  PERFORM set_config('app.edicion_precio_conservado', '', true);
$r$),
(5, 'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 'la barra del original y la del sustituto',
$a$    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, v_item.producto_id, -v_item.cantidad,
      v_item.producto_id, v_sucursal, v_user_id,
      'sustitucion: salida del producto regalo original'
    );
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, p_producto_nuevo_id, p_cantidad_nueva,
      v_ajuste_sustituto_efectivo, v_sucursal, v_user_id,
      'sustitucion: entrada del producto regalo sustituto'
    );
$a$,
$r$    -- B19 (ola 2 de #1603): la salida del original y la entrada del sustituto en
    -- una llamada. Con el mismo producto mueve sólo la diferencia, y si las dos
    -- barras descuentan del mismo contenedor el fardo conserva su lote: antes el
    -- -cantidad lo devolvía al lote y el +cantidad lo volvía a sacar de la bolsa.
    PERFORM public._barra_mover_neto(jsonb_build_array(
      jsonb_build_object('promocion_id', v_promo.id, 'producto_id', v_item.producto_id,
                         'delta', -v_item.cantidad, 'ajuste_def', v_item.producto_id,
                         'motivo', 'sustitucion: salida del producto regalo original'),
      jsonb_build_object('promocion_id', v_promo.id, 'producto_id', p_producto_nuevo_id,
                         'delta', p_cantidad_nueva, 'ajuste_def', v_ajuste_sustituto_efectivo,
                         'motivo', 'sustitucion: entrada del producto regalo sustituto')),
      v_sucursal, v_user_id);
$r$);

-- =========================================================================
-- actualizar_pedido_items y sustituir_regalo_pedido: el tramo de la barra
-- =========================================================================
DO $parche$
DECLARE
  f     text;
  v_def text;
  r     record;
  v_n   int;
BEGIN
  FOR f IN SELECT DISTINCT fn FROM b19_tramos ORDER BY 1 LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    FOR r IN SELECT * FROM b19_tramos WHERE fn = f ORDER BY ord LOOP
      v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el ancla aparece % vez/veces y se esperaba 1', f, r.que, v_n;
      END IF;
      v_def := replace(v_def, r.ancla, r.nuevo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos nuevos son los del repo, el resto de cada cuerpo
-- no cambió (deshaciendo sus tramos vuelve el md5 de la premisa), el definer,
-- el search_path y los EXECUTE son los de antes, y ninguna de las dos llama
-- al motor por su cuenta.
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
     'ab1726cabaf6d2d324cf71cd522385ee', '387beb9228d1751823bc2a6c710b9098', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', 1, 0),
    -- La sustitución conserva su llamada del contador de una promo que mueve stock (1592-b3).
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
     '9fcf5264eb15043ce24b91b4c69e5ae7', '243714f196f2dae7ae9cb8bdf43b54a1', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', 1, 1),
    ('public._barra_mover_neto(jsonb,bigint,uuid)',
     'e9aad859c3fdc71eefb4b4f632f8bc1b', NULL, false,
     '{postgres=X/postgres,service_role=X/postgres}', 0, 2)
  ) AS v(fn, h, h_antes, def, acl, helper, motor) LOOP
    SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def
       OR x.cfg IS DISTINCT FROM '{search_path=public}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)',
        r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
    IF r.h_antes IS NOT NULL THEN
      v_src := x.prosrc;
      FOR t IN SELECT * FROM b19_tramos WHERE fn = r.fn ORDER BY ord DESC LOOP
        IF (length(v_src) - length(replace(v_src, t.nuevo, ''))) / length(t.nuevo) <> 1 THEN
          RAISE EXCEPTION 'mig NNN · % (%): el tramo nuevo no aparece una vez', r.fn, t.que;
        END IF;
        v_src := replace(v_src, t.nuevo, t.ancla);
      END LOOP;
      IF md5(v_src) IS DISTINCT FROM r.h_antes THEN
        RAISE EXCEPTION 'mig NNN · % cambió fuera del tramo de la barra (md5 sin el parche %)', r.fn, md5(v_src);
      END IF;
    END IF;
    IF (length(x.prosrc) - length(replace(x.prosrc, 'aplicar_uso_promo_acumulador(', '')))
         / length('aplicar_uso_promo_acumulador(') <> r.motor
       OR (length(x.prosrc) - length(replace(x.prosrc, '_barra_mover_neto(', ''))) / length('_barra_mover_neto(') <> r.helper THEN
      RAISE EXCEPTION 'mig NNN · % no pasa la barra por _barra_mover_neto una sola vez', r.fn;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
