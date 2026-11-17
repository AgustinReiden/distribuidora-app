-- =========================================================================
-- NNN · LA EDICIÓN DE UN PEDIDO MUEVE SÓLO LA DIFERENCIA DE LA BARRA DE
--       REGALOS: NO PASA EL FARDO DEL CONTENEDOR DE LA BOLSA AL LOTE
--       (ola 2 del plan #1603, tarjeta B19: H1 de la revisión de la tarjeta B3)
--
-- Parcha por ancla `actualizar_pedido_items`, con premisa de md5 sobre el
-- cuerpo vivo (el de la 519). Toca sólo el tramo de la barra: el resto del
-- cuerpo (precios, piso y techo, versión del pedido, mínimos, promos, stock de
-- las líneas, huella) queda igual, y la poscondición lo comprueba. No cambia
-- firmas ni permisos, no toca tablas y no toca el motor de la barra
-- (`aplicar_uso_promo_acumulador`).
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
--
-- -------------------------------------------------------------------------
-- El arreglo
-- -------------------------------------------------------------------------
-- La edición ya no deshace y rehace: anota, por promo y producto (la barra de
-- ese sabor), lo que el pedido tenía en la barra (en negativo, con la misma
-- condición de siempre, `_regalo_barra_vale` antes de borrar las líneas) y lo
-- que le queda (cada línea de regalo reinsertada, con el producto y la
-- cantidad que quedaron en la fila y `_regalo_barra_vale` después de
-- insertarla). Con las líneas ya insertadas llama al motor UNA vez por barra
-- con la diferencia, si no es 0: primero las que bajan (abren los bloques de
-- esa barra del último al primero y cada fardo vuelve al lote o a la bolsa de
-- donde salió) y después las que suben (cierran bloques nuevos, que salen del
-- stock de hoy como en el alta). Así:
--   · una edición que no cambia el regalo de una promo no toca su barra, sus
--     bloques, el contenedor, sus lotes ni la bolsa, y no deja asientos;
--   · una que lo cambia mueve sólo la diferencia;
--   · los textos de los asientos son los de antes ('Edicion pedido #N' en la
--     baja, 'Auto-ajuste (Promo: …, Pedido #N, edicion)' en la suba).
-- Es el molde de `dividir_regalo_pedido`, que ya mueve el neto por producto.
-- El orden de locks no cambia: los productos (con los contenedores, por
-- `_contenedores_de_promos`) y las promos se toman arriba, por id, antes que
-- todo; las llamadas al motor son re-locks, y las dos listas las recorre en
-- orden de (baja/suba, promo, producto).
-- En las promos sin barra de fracción (la que mueve stock, la que no tiene
-- ajuste automático) el motor lleva un contador con piso en 0: la diferencia
-- da lo mismo que deshacer y rehacer salvo cuando el piso cortaba, y ahí una
-- edición sin cambios ya no lo sube.
--
-- Revertir: volver `actualizar_pedido_items` al cuerpo de la premisa (md5
-- 387beb9228d1751823bc2a6c710b9098, el de la 519).
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
-- Premisas: el cuerpo vivo de la edición (el de la 519) y el motor con el que
-- cuenta el arreglo (el de la 520: abre del último bloque al primero y
-- devuelve cada fardo a donde salió).
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '387beb9228d1751823bc2a6c710b9098'),
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'b55ff7a09db621f71f6e29d55bfea808')
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

-- Los tramos que se cambian: el ancla y su reemplazo. La poscondición los
-- vuelve a poner al revés y compara con el md5 de la premisa.
CREATE TEMP TABLE b19_tramos (ord int PRIMARY KEY, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO b19_tramos VALUES
(1, 'declaraciones',
$a$  v_canal        TEXT;
  v_updated_at   TIMESTAMPTZ;
BEGIN
$a$,
$r$  v_canal        TEXT;
  v_updated_at   TIMESTAMPTZ;
  -- B19 (ola 2 de #1603): lo que la edicion le cambia a cada barra, por
  -- "promo:producto": lo que el pedido tenia (en negativo) mas lo que le queda.
  v_barra_neto   JSONB := '{}'::jsonb;
  v_barra_mov    RECORD;
BEGIN
$r$),
(2, 'la barra que el pedido tenía',
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
(3, 'la barra que le queda',
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
(4, 'la diferencia',
$a$  -- 1559-b3: el precio conservado vale sólo para la reinserción.
  PERFORM set_config('app.edicion_precio_conservado', '', true);
$a$,
$r$  -- B19 (ola 2 de #1603): la barra mueve solo la diferencia, una vez por promo y
  -- producto (la barra de ese sabor). Primero lo que baja: abre los bloques de
  -- esa barra del ultimo al primero y cada fardo vuelve al lote o a la bolsa de
  -- donde salio. Despues lo que sube: cierra bloques nuevos, que salen del stock
  -- de hoy, como en el alta. Una edicion que no cambia el regalo no toca la
  -- barra, los bloques ni el contenedor. Los productos y las promos ya estan
  -- tomados arriba (#1296, #1460): el motor solo re-bloquea.
  FOR v_barra_mov IN
    SELECT split_part(k.key, ':', 1)::BIGINT AS promocion_id,
           NULLIF(split_part(k.key, ':', 2), '')::BIGINT AS producto_id,
           k.value::NUMERIC AS delta
      FROM jsonb_each_text(v_barra_neto) k
     WHERE k.value::NUMERIC <> 0
     ORDER BY k.value::NUMERIC > 0, 1, 2
  LOOP
    PERFORM public.aplicar_uso_promo_acumulador(
      v_barra_mov.promocion_id, v_barra_mov.producto_id, v_barra_mov.delta,
      v_barra_mov.producto_id, v_sucursal, p_usuario_id,
      CASE WHEN v_barra_mov.delta < 0
           THEN 'Edicion pedido #' || p_pedido_id
           ELSE 'Auto-ajuste (Promo: '
                || COALESCE((SELECT nombre FROM promociones
                              WHERE id = v_barra_mov.promocion_id AND sucursal_id = v_sucursal), '?')
                || ', Pedido #' || p_pedido_id || ', edicion)' END);
  END LOOP;

  -- 1559-b3: el precio conservado vale sólo para la reinserción.
  PERFORM set_config('app.edicion_precio_conservado', '', true);
$r$);

-- =========================================================================
-- actualizar_pedido_items: el tramo de la barra
-- =========================================================================
DO $parche_edicion$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
  r     record;
  v_n   int;
BEGIN
  FOR r IN SELECT * FROM b19_tramos ORDER BY ord LOOP
    v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig NNN · actualizar_pedido_items (%): el ancla aparece % vez/veces y se esperaba 1', r.que, v_n;
    END IF;
    v_def := replace(v_def, r.ancla, r.nuevo);
  END LOOP;
  EXECUTE v_def;
END
$parche_edicion$;

-- ---------------------------------------------------------------------------
-- Poscondición: el cuerpo nuevo es el del repo, el resto del cuerpo no cambió
-- (deshaciendo los cuatro tramos vuelve el md5 de la premisa) y el definer, el
-- search_path y los EXECUTE son los de antes.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text;
  r     record;
  x     record;
BEGIN
  SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
    FROM pg_proc
   WHERE oid = 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure;
  IF x.h IS DISTINCT FROM 'c0f975290ab517f535d0a91ee22bc410'
     OR x.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
     OR x.def IS DISTINCT FROM true
     OR x.cfg IS DISTINCT FROM '{search_path=public}' THEN
    RAISE EXCEPTION 'mig NNN · actualizar_pedido_items no quedó como en el repo (md5 %, acl %, definer %, config %)',
      x.h, x.a, x.def, x.cfg;
  END IF;
  v_src := x.prosrc;
  FOR r IN SELECT * FROM b19_tramos ORDER BY ord DESC LOOP
    IF (length(v_src) - length(replace(v_src, r.nuevo, ''))) / length(r.nuevo) <> 1 THEN
      RAISE EXCEPTION 'mig NNN · actualizar_pedido_items (%): el tramo nuevo no aparece una vez', r.que;
    END IF;
    v_src := replace(v_src, r.nuevo, r.ancla);
  END LOOP;
  IF md5(v_src) IS DISTINCT FROM '387beb9228d1751823bc2a6c710b9098' THEN
    RAISE EXCEPTION 'mig NNN · actualizar_pedido_items cambió fuera del tramo de la barra (md5 sin el parche %)', md5(v_src);
  END IF;
  -- El motor se llama una sola vez, desde el tramo de la diferencia.
  IF (length(x.prosrc) - length(replace(x.prosrc, 'aplicar_uso_promo_acumulador(', '')))
     / length('aplicar_uso_promo_acumulador(') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · actualizar_pedido_items llama al motor de la barra más de una vez';
  END IF;
END
$post$;

COMMIT;
