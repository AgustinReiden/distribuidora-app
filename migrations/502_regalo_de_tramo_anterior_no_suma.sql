-- =========================================================================
-- NNN · AL REGALO DE FRACCIÓN QUE NO ENTRA EN LA BARRA VIVA NO SE LE SUMA
--       (cierre de la tanda #1565: LV-1, regresión de la 500, PRM-B, y su
--        caso hermano de #1324, la promo que cambió de tipo)
--
-- Parcha por ancla tres funciones (`actualizar_pedido_items`,
-- `sustituir_regalo_pedido` y `dividir_regalo_pedido`), con premisa de md5
-- sobre el cuerpo vivo leído el 13/11 (la 500 aplicada) y poscondición de
-- md5, definer y ACL. No cambia tablas ni firmas.
-- Ensayo: scripts/test-regalo-tramo-anterior-1565.sql. Se aplica en LF.
--
-- =========================================================================
-- QUÉ PASABA
-- =========================================================================
-- Una promo de fracción no mueve el stock del regalo por línea: lo asienta la
-- barra (`aplicar_uso_promo_acumulador`), que consume un contenedor cada N
-- unidades. El modo de cada pedido es el de su foto (#1324), y la barra sólo
-- cuenta los pedidos que entran en la de la promo viva (`_regalo_barra_vale`).
-- Hay dos pedidos de fracción que no entran:
--   · LV-1 · el de un tramo anterior. Al pasar la promo de unidad entera a
--     fracción la barra arranca en 0 (`trg_promo_tipo_reinicia_barra`, 431a)
--     y, desde la 500 (PRM-B), marca las fotos de fracción que ya existían
--     (`pedido_promo_reglas.barra_anterior`): ese pedido no le resta ni le
--     suma a la barra nueva.
--   · #1324 · el de una promo que pasó a unidad entera después de cargarlo:
--     la foto sigue de fracción y la promo de hoy no tiene barra.
-- No restar es lo correcto. No sumar dejó un agujero: si después se le SUBE
-- el regalo a ese pedido (R×4 → R×8), las unidades nuevas no entran en ninguna
-- barra, no descuentan el contenedor ni mueven stock por ningún otro camino.
-- Salen gratis. Lo mismo al cambiarlo por otro producto o repartirlo: la barra
-- es por sabor (mig 294), y el producto nuevo no entró en ninguna. En el
-- tramo anterior, también al sacarle el regalo y volvérselo a poner.
--
-- =========================================================================
-- QUÉ CAMBIA
-- =========================================================================
-- Decisión del dueño (13/11): la edición que le suma regalo a un pedido de un
-- tramo anterior se rechaza, con un mensaje: lo nuevo se carga en un pedido
-- nuevo. Bajarle o sacarle el regalo sigue permitido. Y el mismo día, con la
-- misma regla, el pedido de fracción cuya promo cambió de tipo.
--
-- La condición es la de la barra: la foto de la promo en el pedido es de
-- fracción (`NOT regalo_mueve_stock`) y `_regalo_barra_vale` da false (la foto
-- está marcada, o la promo de hoy es de unidad entera). Se pide la foto: sin
-- foto no hay regla, y la foto existe sólo mientras exista la promo (su FK es
-- ON DELETE CASCADE; la de `pedido_items` pone `promocion_id` en NULL). El caso
-- inverso, foto de unidad entera con la promo hoy de fracción, mueve stock por
-- línea y no se toca.
-- «Sumar» se mide como la barra: por promo y por producto, en la unidad de la
-- línea. Ningún producto del regalo de esa promo le puede quedar al pedido con
-- más unidades de las que tiene hoy.
--   · `actualizar_pedido_items`: para cada promo así, el producto y la
--     cantidad que va a quedar en cada línea (la misma
--     `regalo_sustitucion_resuelta` que usan el pre-chequeo de stock y el
--     trigger de sustituciones; una línea conservada de un reparto, tal cual),
--     contra la suma de hoy de ese producto. Si alguno sube, rechaza antes de
--     escribir nada, con `codigo = 'regalo_de_tramo_anterior'`. Va después de
--     tomar las promos del pedido: el cambio de tipo (y el reinicio que marca
--     la foto) corre con la promo tomada, así que lo que se lee es lo que rige
--     la barra de abajo. Cubre subir, cambiar el producto del regalo y, en el
--     tramo anterior, sacarlo y volver a ponerlo (en dos ediciones: la segunda
--     ve 0). En el pedido de la promo que cambió de tipo, volver a ponerlo no
--     se rechaza porque ya no suma gratis: una foto sin regalo vivo arranca con
--     el modo de hoy (#1324, arriba en la misma función) y el regalo vuelto a
--     poner mueve stock por línea.
--   · `sustituir_regalo_pedido`: rechaza cambiar el regalo de esa línea por
--     otro producto o por más cantidad. Con el mismo producto y menos cantidad
--     sigue.
--   · `dividir_regalo_pedido`: rechaza siempre. Un reparto tiene dos productos
--     distintos o más y suma la cantidad de la línea: alguno es nuevo.
--   Lo demás no cambia: bajar o sacar el regalo, editar otras líneas sin
--   tocarlo, cancelar y eliminar el pedido, la salvedad.
--
-- Los otros caminos que podían sumarle regalo a un pedido así (el ensayo
-- muestra los de la marca):
--   · `anular_salvedad` no repone regalos de promo
--     (`anulacion_toca_promociones`): rechaza la anulación de una salvedad
--     sobre el regalo y la de una sobre la venta que le devuelve el derecho.
--   · `cambiar_cliente_pedido` exige el regalo del pedido original tal cual;
--     con la promo de otro tipo se rechaza (480, PRM-1), y con la foto marcada
--     el pedido nuevo nace con su foto (sin la marca): entra en la barra viva
--     como cualquier alta.
--   · `crear_pedido_completo` y el bot crean pedidos nuevos.
--   · `pedido_items` no tiene escritura REST.
--
-- En prod ninguna promo pasó de unidad entera a fracción (audit_logs, 12/11):
-- no hay fotos marcadas.
--
-- Revertir: volver los tres cuerpos a los de la premisa.
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
-- Premisas: los cuerpos vivos del 13/11 (la 500 aplicada) y la marca de la 500
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '9bf3c42b9d4447172b9c96999f65ea00'),
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', '0dc69aa6a22ad0ec698147008fd5b498'),
    ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', '81e56ea614d582b4719ff6f405884d53'),
    -- No cambian, pero el rechazo cuenta con ellas como están: la marca la pone
    -- el reinicio y la barra la decide _regalo_barra_vale.
    ('public.promo_tipo_reinicia_barra()', 'babeac68e20c09aff1fa55bffd038ace'),
    ('public._regalo_barra_vale(bigint,bigint,bigint)', 'f4ff91437fd7892000d71732f57daa13')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pedido_promo_reglas'::regclass
                    AND attname = 'barra_anterior' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · pedido_promo_reglas.barra_anterior no existe: falta la 500';
  END IF;
  -- Sin promo no hay foto: la regla pide la foto y así no rechaza un regalo de
  -- una promo borrada.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pedido_promo_reglas'::regclass
                    AND confrelid = 'public.promociones'::regclass AND confdeltype = 'c') THEN
    RAISE EXCEPTION 'mig NNN · la foto de la promo ya no se borra con la promo: revisar la regla';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 1 · actualizar_pedido_items: ningún producto del regalo sube
-- =========================================================================
DO $parche_editar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    ORDER BY id
      FOR UPDATE;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
$a$,
$r$    ORDER BY id
      FOR UPDATE;

  -- LV-1 (#1565): un regalo de fracción en la foto que no entra en la barra viva
  -- (foto marcada barra_anterior al reiniciarse la barra, PRM-B, o promo que pasó
  -- a unidad entera, #1324) no mueve stock por línea ni pasa por la barra: lo que
  -- se le sume saldría sin asentarse. Decisión del dueño (13/11): se rechaza, y
  -- lo nuevo va en un pedido nuevo; bajarlo o sacarlo sigue. Se mide como la
  -- barra, por producto (mig 294): el que va a quedar en cada línea y su
  -- cantidad (la misma función que el pre-chequeo de abajo y el trigger), contra
  -- lo que el pedido tiene hoy. Va después de tomar las promos: el cambio de tipo
  -- corre con la promo tomada. Sin foto (promo borrada: CASCADE) no hay regla.
  DECLARE
    v_tramo_anterior TEXT;
  BEGIN
    SELECT string_agg(DISTINCT format('«%s», que %s', COALESCE(pr.nombre, '#' || n.promocion_id),
                                      CASE WHEN f.barra_anterior THEN 'reinició su barra' ELSE 'cambió de tipo' END),
                      '; ')
      INTO v_tramo_anterior
      FROM (SELECT x.promocion_id, x.producto_id, sum(x.cantidad) AS cantidad
              FROM (SELECT (e->>'promocion_id')::BIGINT AS promocion_id,
                           CASE WHEN e->>'_reparto' IS NOT DISTINCT FROM v_marca_reparto
                                THEN (e->>'producto_id')::BIGINT
                                ELSE (SELECT r.producto_id
                                        FROM public.regalo_sustitucion_resuelta(
                                               p_pedido_id, (e->>'promocion_id')::BIGINT, (e->>'producto_id')::BIGINT,
                                               v_sucursal, (e->>'cantidad')::NUMERIC, (e->>'_cadena')::UUID) r)
                           END AS producto_id,
                           CASE WHEN e->>'_reparto' IS NOT DISTINCT FROM v_marca_reparto
                                THEN (e->>'cantidad')::NUMERIC
                                ELSE (SELECT r.cantidad
                                        FROM public.regalo_sustitucion_resuelta(
                                               p_pedido_id, (e->>'promocion_id')::BIGINT, (e->>'producto_id')::BIGINT,
                                               v_sucursal, (e->>'cantidad')::NUMERIC, (e->>'_cadena')::UUID) r)
                           END AS cantidad
                      FROM jsonb_array_elements(v_items) e
                     WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                       AND e->>'promocion_id' IS NOT NULL) x
             GROUP BY x.promocion_id, x.producto_id) n
      JOIN pedido_promo_reglas f
        ON f.pedido_id = p_pedido_id AND f.promocion_id = n.promocion_id AND f.sucursal_id = v_sucursal
       AND NOT f.regalo_mueve_stock
       AND NOT public._regalo_barra_vale(p_pedido_id, n.promocion_id, v_sucursal)
      LEFT JOIN promociones pr ON pr.id = n.promocion_id AND pr.sucursal_id = v_sucursal
     WHERE n.cantidad > COALESCE((SELECT sum(pi.cantidad)
                                    FROM pedido_items pi
                                   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                                     AND COALESCE(pi.es_bonificacion, false)
                                     AND pi.promocion_id = n.promocion_id
                                     AND pi.producto_id = n.producto_id), 0);
    IF v_tramo_anterior IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
        'El regalo de este pedido es de fracción y no entra en la barra de la promo %s después de cargarlo, así que lo que se le sume saldría sin descontarse. A este regalo se lo puede bajar o sacar, pero no sumarle ni cambiarle el producto: lo que quieras agregar cargalo en un pedido nuevo. El pedido no se modificó.',
        v_tramo_anterior)), 'codigo', 'regalo_de_tramo_anterior');
    END IF;
  END;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
$r$, 'actualizar_pedido_items (regalo de un tramo anterior)');

  EXECUTE v_def;
END
$parche_editar$;

-- =========================================================================
-- 2 · sustituir_regalo_pedido: ni otro producto ni más cantidad
-- =========================================================================
DO $parche_sustituir$
DECLARE
  v_def text := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  -- #1324: el modo de la foto del pedido.
  v_regalo_mueve_stock := COALESCE(public._regalo_modo_del_pedido(v_item.pedido_id, v_item.promocion_id, v_sucursal), TRUE);
$a$,
$r$  -- #1324: el modo de la foto del pedido.
  v_regalo_mueve_stock := COALESCE(public._regalo_modo_del_pedido(v_item.pedido_id, v_item.promocion_id, v_sucursal), TRUE);
  -- LV-1 (#1565): un regalo de fracción en la foto que no entra en la barra viva
  -- (tramo anterior, PRM-B, o promo que pasó a unidad entera, #1324): otro
  -- producto o más cantidad saldrían sin asentarse. Decisión del dueño (13/11):
  -- se rechaza.
  IF EXISTS (SELECT 1 FROM pedido_promo_reglas f
              WHERE f.pedido_id = v_item.pedido_id AND f.promocion_id = v_item.promocion_id
                AND f.sucursal_id = v_sucursal AND NOT f.regalo_mueve_stock)
     AND NOT public._regalo_barra_vale(v_item.pedido_id, v_item.promocion_id, v_sucursal)
     AND (p_producto_nuevo_id IS DISTINCT FROM v_item.producto_id OR p_cantidad_nueva > v_item.cantidad) THEN
    RETURN jsonb_build_object('success', false, 'codigo', 'regalo_de_tramo_anterior', 'error', format(
      'El regalo de este pedido es de fracción y no entra en la barra de la promo «%s», que %s después de cargarlo, así que otro producto o más cantidad saldrían sin descontarse. A este regalo se lo puede bajar o sacar editando el pedido, pero no cambiar ni agrandar: el regalo nuevo cargalo en un pedido nuevo.',
      COALESCE((SELECT nombre FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal),
               '#' || v_item.promocion_id),
      CASE WHEN EXISTS (SELECT 1 FROM pedido_promo_reglas f
                         WHERE f.pedido_id = v_item.pedido_id AND f.promocion_id = v_item.promocion_id
                           AND f.sucursal_id = v_sucursal AND f.barra_anterior)
           THEN 'reinició su barra' ELSE 'cambió de tipo' END));
  END IF;
$r$, 'sustituir_regalo_pedido (regalo de un tramo anterior)');

  EXECUTE v_def;
END
$parche_sustituir$;

-- =========================================================================
-- 3 · dividir_regalo_pedido: un reparto siempre trae un producto nuevo
-- =========================================================================
DO $parche_dividir$
DECLARE
  v_def text := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  -- #1324: el modo de la foto del pedido.
  v_regalo_mueve_stock := COALESCE(public._regalo_modo_del_pedido(v_item.pedido_id, v_item.promocion_id, v_sucursal), TRUE);
$a$,
$r$  -- #1324: el modo de la foto del pedido.
  v_regalo_mueve_stock := COALESCE(public._regalo_modo_del_pedido(v_item.pedido_id, v_item.promocion_id, v_sucursal), TRUE);
  -- LV-1 (#1565): un regalo de fracción en la foto que no entra en la barra viva
  -- (tramo anterior, PRM-B, o promo que pasó a unidad entera, #1324). Un reparto
  -- tiene dos productos distintos o más y suma la cantidad de la línea: alguno
  -- es nuevo y saldría sin asentarse. Decisión del dueño (13/11): se rechaza.
  IF EXISTS (SELECT 1 FROM pedido_promo_reglas f
              WHERE f.pedido_id = v_item.pedido_id AND f.promocion_id = v_item.promocion_id
                AND f.sucursal_id = v_sucursal AND NOT f.regalo_mueve_stock)
     AND NOT public._regalo_barra_vale(v_item.pedido_id, v_item.promocion_id, v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'codigo', 'regalo_de_tramo_anterior', 'error', format(
      'El regalo de este pedido es de fracción y no entra en la barra de la promo «%s», que %s después de cargarlo, así que un producto nuevo saldría sin descontarse. A este regalo se lo puede bajar o sacar editando el pedido, pero no repartir: el regalo nuevo cargalo en un pedido nuevo.',
      COALESCE((SELECT nombre FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal),
               '#' || v_item.promocion_id),
      CASE WHEN EXISTS (SELECT 1 FROM pedido_promo_reglas f
                         WHERE f.pedido_id = v_item.pedido_id AND f.promocion_id = v_item.promocion_id
                           AND f.sucursal_id = v_sucursal AND f.barra_anterior)
           THEN 'reinició su barra' ELSE 'cambió de tipo' END));
  END IF;
$r$, 'dividir_regalo_pedido (regalo de un tramo anterior)');

  EXECUTE v_def;
END
$parche_dividir$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'c15aa49005a602eb48b7d527e698b748', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 'd7af267910f5372e13434c80ee98c4b7', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', '0c574aefbe8d6e9d97fba2c553adc2d0', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
