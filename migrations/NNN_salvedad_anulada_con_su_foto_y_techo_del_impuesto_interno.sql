-- =========================================================================
-- NNN · LA LÍNEA QUE VUELVE AL ANULAR UNA SALVEDAD TRAE SU FOTO, EL TECHO DEL
--       IMPUESTO INTERNO ES 99 % NOMINAL Y FUSIONAR CONDICIONES MIRA `activo`
--       (tarjeta M4 del plan #1603: VTA-1 de #1595, CAT-9 y CAT-10 de #1596,
--        y los bajos 1592-b5, 1559-c2 y 1561-c5)
--
-- Crea una tabla sólo de server (`salvedad_linea_foto`), cambia tres CHECK y
-- parcha por ancla, con premisa de md5 sobre el cuerpo vivo del 15/11 (ledger en
-- la 504) y poscondición de md5, definer y ACL: `registrar_salvedad` (sólo el
-- borrado de la línea), `anular_salvedad`, `consolidar_condiciones`,
-- `cambiar_alicuota_ii` y `_compra_renglones_fuera_de_rango`. Reescribe
-- `refrescar_ii_productos`. No cambia firmas ni grants de funciones.
-- Ensayos: scripts/test-salvedad-anulada-foto-1595.sql y
--          scripts/test-ii-techo-y-condiciones-1596.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · VTA-1 (#1595) · la línea que vuelve con anular_salvedad
-- =========================================================================
-- Cuando la salvedad deja la línea en 0, registrar_salvedad la borra. Anularla
-- la vuelve a insertar con el costo de hoy (`costo_valuacion` sin snapshot) y sin
-- `precio_lista_al_crear`, `origen_precio` ni `descuento_pct`, que completa el
-- trigger con la lista de hoy («desconocido» si el precio no coincide). El total,
-- el IVA (#1274, de audit_logs) y el stock vuelven exactos; el margen de esas
-- unidades no.
-- Ahora registrar_salvedad, justo antes de borrar la línea, guarda su foto en
-- `salvedad_linea_foto`: una fila por cada salvedad que apunta a la línea (la que
-- la borra y las anteriores que la recortaron, que el DELETE deja con
-- `pedido_item_id` NULL). Es lo único que cambia en registrar_salvedad.
-- La foto va en una tabla aparte y no en `salvedades_items` porque lleva el
-- costo: `salvedades_items` la lee por REST el que repartió el pedido, con `*`
-- (useSalvedadesQuery), y el costo no se lee por REST (#974). La tabla nace con
-- RLS, sin policies y sin grants para authenticated ni anon, como
-- `pedido_promo_reglas`.
-- anular_salvedad, en la rama que inserta, lee esa foto: el costo pasa por la
-- cascada como snapshot (COSTO-D: una foto NULL cae al costo de hoy, como en los
-- reportes), y la lista, el origen y el descuento van tal cual. Si la línea vuelve
-- como otra (era del combo y vuelve como la parte que salió de él, o al revés), el
-- origen y el descuento los completa el trigger, como hoy. Una salvedad
-- registrada antes de esta migración no tiene foto y sigue como hasta ahora.
-- La alícuota de IVA sigue saliendo de audit_logs (#1274): no cambia.
--
-- =========================================================================
-- 2 · 1592-b5 (#1592) · «toca promociones» sin regalo recortado
-- =========================================================================
-- anular_salvedad rechazaba toda restitución que cruzara un múltiplo de una promo
-- del pedido con el producto, diciendo que la salvedad había recortado el regalo.
-- La resincronización de registrar_salvedad sólo recorta si el pedido tenía más
-- regalo que el que le queda derecho, así que a menudo no recortó nada (el pedido
-- no tenía el regalo, o tenía menos). Ahora se mira si lo recortó: el recorte
-- deja en audit_logs, en la misma transacción que la salvedad (la misma
-- `created_at`), el UPDATE a la baja o el DELETE de una línea de regalo de esas
-- promos. Sin recorte, se anula y el pedido vuelve a como estaba. Si no está la
-- fila de la propia línea de la salvedad en el log (una salvedad sin rastro), no
-- se puede saber y se rechaza como antes, con un mensaje que no afirma el recorte.
--
-- =========================================================================
-- 3 · 1559-c2 (#1559) · orden de locks de anular_salvedad
-- =========================================================================
-- Bloqueaba los pagos de `cobro_recortado` antes que el producto. Si uno de esos
-- pagos se fue a otra boleta Y, una registrar_salvedad sobre Y con el mismo
-- producto toma el producto y después el pago: 40P01. Ahora el producto de la
-- salvedad se bloquea antes que los pagos, el orden de registrar_salvedad
-- (pedido, línea, productos, pagos).
--
-- =========================================================================
-- 4 · CAT-9 (#1596) · el techo del impuesto interno
-- =========================================================================
-- `productos.impuestos_internos` es la tasa EFECTIVA sobre el neto,
-- 100·n/(1−n), y el CHECK de la 493 la topaba en 100: un 50 % nominal o más no
-- se podía cargar, y un alza programada así hacía fallar entero
-- refrescar_ii_productos() (II-A en rojo para todos los encuadres).
-- Decisión del dueño (15/11): el techo es 99 % nominal. Entonces:
--   · ii_alicuotas_tasa_rango: 0 ≤ tasa_nominal ≤ 0,99 (era < 1). Deja afuera el NaN.
--   · cambiar_alicuota_ii (alta del encuadre y sus alzas programadas) lo rechaza
--     con un mensaje antes de escribir.
--   · productos_impuestos_internos_rango y compra_items_impuestos_internos_rango:
--     0 ≤ efectiva ≤ 9900, la de 99 % nominal. Siguen dejando afuera el NaN.
--   · _compra_renglones_fuera_de_rango (el validador de los renglones del alta y
--     de la edición de una compra) tenía el mismo techo de 100: pasa a 9900.
--   · refrescar_ii_productos() actualiza un encuadre por vez, cada uno en su
--     sub-bloque: si uno falla, avisa (WARNING) y sigue con los demás. Lo que
--     quede sin refrescar lo ve II-A, que no cambia (cuenta las fichas con la
--     efectiva distinta de la de hoy, y eso sigue siendo la deriva).
--
-- =========================================================================
-- 5 · CAT-10 (#1596) y 1561-c5 (#1561) · consolidar_condiciones
-- =========================================================================
-- La guarda comparaba sólo el precio por cantidad mínima. Fusionar un grupo
-- activo en uno inactivo le apagaba el precio mayorista a sus productos, y uno
-- inactivo en uno activo prendía un descuento apagado. Decisión del dueño
-- (15/11): fusionar condiciones con distinto `activo` se rechaza, con un mensaje
-- que pide igualarlas antes. Lo mismo con dos escalas de la misma cantidad (la de
-- origen se borra y queda la del destino). Y un id repetido en `p_grupos_origen`
-- es el mismo grupo: se fusiona una vez (antes respondía «alguna no existe»).
--
-- Revertir: volver los cuerpos y los tres CHECK a los de la premisa y borrar
-- `salvedad_linea_foto` (anular_salvedad vuelve al costo de hoy).
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
-- Premisas: los cuerpos vivos del 15/11, los CHECK de hoy y que los datos entran
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 'ce4dcadfe8f7bdeec5f10b2851efb031'),
    ('public.anular_salvedad(bigint,text)', 'c521503ea76283748fc1addcbc9f8842'),
    ('public.consolidar_condiciones(bigint,bigint[],text)', 'e83f15f1d0d396fd9669d3225535753e'),
    ('public.cambiar_alicuota_ii(bigint,numeric,date)', 'c7c0acfb3759ee82d5d928e16fedec18'),
    ('public.refrescar_ii_productos()', '068185da4bec3d88cb61c469c8558530'),
    ('public._compra_renglones_fuera_de_rango(jsonb,bigint)', '7c118bfbf192d5c2bd12e1e310cde963'),
    -- No cambian, pero lo de arriba cuenta con ellas como están: la efectiva y su
    -- derivación en la ficha, y la cascada del costo.
    ('public.ii_tasa_efectiva(bigint,date)', '5a78856954c54a9a12872a6fb0678743'),
    ('public.derivar_ii_producto()', '318c525f63dd9c1fabada459586da8b8')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  FOR r IN SELECT * FROM (VALUES
    ('public.productos'::regclass,    'productos_impuestos_internos_rango',
     'CHECK (((impuestos_internos >= (0)::numeric) AND (impuestos_internos <= (100)::numeric)))'),
    ('public.compra_items'::regclass, 'compra_items_impuestos_internos_rango',
     'CHECK (((impuestos_internos >= (0)::numeric) AND (impuestos_internos <= (100)::numeric)))'),
    ('public.ii_alicuotas'::regclass, 'ii_alicuotas_tasa_rango',
     'CHECK (((tasa_nominal >= (0)::numeric) AND (tasa_nominal < (1)::numeric)))')
  ) AS t(tabla, nombre, def) LOOP
    SELECT pg_get_constraintdef(c.oid) INTO v FROM pg_constraint c
     WHERE c.conrelid = r.tabla AND c.conname = r.nombre;
    IF v IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · el CHECK % de % cambió (%): rehacer sobre lo vigente', r.nombre, r.tabla, v;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM public.ii_alicuotas WHERE tasa_nominal > 0.99) THEN
    RAISE EXCEPTION 'mig NNN · hay alícuotas de impuesto interno por encima de 99 %% nominal: revisarlas antes';
  END IF;
  IF to_regclass('public.salvedad_linea_foto') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · salvedad_linea_foto ya existe';
  END IF;
  -- La foto se busca por la clave (id, sucursal_id) de la salvedad.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.salvedades_items'::regclass
                    AND conname = 'salvedades_items_id_sucursal_uk') THEN
    RAISE EXCEPTION 'mig NNN · salvedades_items_id_sucursal_uk no existe';
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
-- 1 · La foto de la línea que borra una salvedad (sólo de server)
-- =========================================================================
CREATE TABLE public.salvedad_linea_foto (
  salvedad_id             bigint      NOT NULL PRIMARY KEY,
  sucursal_id             bigint      NOT NULL,
  -- La línea que se borró: ya no existe, es para leer el log.
  pedido_item_id          bigint      NOT NULL,
  -- Copias de pedido_items al borrarse. Cada una con su freno de NaN: el costo
  -- es numeric sin precisión, así que deja afuera también el infinito.
  costo_unitario_al_crear numeric
    CONSTRAINT salvedad_linea_foto_costo_valido
    CHECK (costo_unitario_al_crear <> 'NaN'::numeric
           AND costo_unitario_al_crear <> 'Infinity'::numeric
           AND costo_unitario_al_crear <> '-Infinity'::numeric),
  precio_lista_al_crear   numeric(12,2)
    CONSTRAINT salvedad_linea_foto_lista_no_nan CHECK (precio_lista_al_crear <> 'NaN'::numeric),
  origen_precio           varchar(20),
  descuento_pct           numeric(5,2)
    CONSTRAINT salvedad_linea_foto_descuento_no_nan CHECK (descuento_pct <> 'NaN'::numeric),
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT salvedad_linea_foto_salvedad_fkey FOREIGN KEY (salvedad_id, sucursal_id)
    REFERENCES public.salvedades_items (id, sucursal_id) ON DELETE CASCADE
);

COMMENT ON TABLE public.salvedad_linea_foto IS
  'VTA-1 (#1595): la foto de la línea de pedido que borró una salvedad (costo, lista, origen y descuento de la venta), para que anular_salvedad la devuelva igual. La escribe registrar_salvedad al borrar la línea. Sólo de server: RLS sin policies y sin grants, porque lleva el costo.';

ALTER TABLE public.salvedad_linea_foto ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.salvedad_linea_foto FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 2 · registrar_salvedad: guarda la foto antes de borrar la línea
-- =========================================================================
DO $parche_registrar$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    DELETE FROM pedido_items
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
$a$,
$r$    -- VTA-1 (#1595): la foto de la linea, para que anular_salvedad la devuelva
    -- con el costo, la lista, el origen y el descuento de la venta. Para toda
    -- salvedad que apunta a ella (esta y las que la recortaron antes): el DELETE
    -- les pone pedido_item_id en NULL. Tabla solo de server: lleva el costo.
    -- COSTO-D: esto no escribe el costo de una linea de pedido, lo copia tal
    -- cual a la foto; quien lo vuelve a escribir (anular_salvedad) lo pasa por
    -- costo_valuacion.
    INSERT INTO salvedad_linea_foto (salvedad_id, sucursal_id, pedido_item_id, costo_unitario_al_crear,
                                     precio_lista_al_crear, origen_precio, descuento_pct)
    SELECT s.id, s.sucursal_id, pi.id, pi.costo_unitario_al_crear,
           pi.precio_lista_al_crear, pi.origen_precio, pi.descuento_pct
      FROM salvedades_items s
      JOIN pedido_items pi ON pi.id = s.pedido_item_id AND pi.sucursal_id = s.sucursal_id
     WHERE s.pedido_item_id = p_pedido_item_id AND s.sucursal_id = v_sucursal
     ORDER BY s.id
    ON CONFLICT (salvedad_id) DO NOTHING;
    DELETE FROM pedido_items
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
$r$, 'registrar_salvedad (foto de la linea borrada)');

  EXECUTE v_def;
END
$parche_registrar$;

-- =========================================================================
-- 3 · anular_salvedad: la foto, el regalo que de verdad se recortó y el orden
-- =========================================================================
DO $parche_anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  -- 3a · variables
  v_def := pg_temp.parche(v_def,
$a$  v_resultado     JSONB := '[]'::jsonb;
BEGIN
$a$,
$r$  v_resultado     JSONB := '[]'::jsonb;
  -- VTA-1 (#1595): la foto de la linea que la salvedad borro.
  v_foto_costo    NUMERIC;
  v_foto_lista    NUMERIC;
  v_foto_origen   TEXT;
  v_foto_desc     NUMERIC;
  -- 1592-b5: las promos a las que restituir la linea les devuelve el derecho.
  v_promos_toca   BIGINT[];
  v_log_linea     BOOLEAN;
BEGIN
$r$, 'anular_salvedad (variables)');

  -- 3b · 1592-b5: se rechaza si la salvedad recorto el regalo, no si cruza
  v_def := pg_temp.parche(v_def,
$a$  WITH promos AS (
    SELECT h.cantidad_compra AS cant_compra, h.cantidad_bonificacion AS cant_bonif, h.productos
      FROM public.promos_del_pedido(v_salvedad.pedido_id) h
     WHERE v_salvedad.producto_id = ANY (h.productos)
  ), disparadores AS (
    SELECT pm.cant_compra,
           (SELECT COALESCE(SUM(pi.cantidad), 0)::INT
              FROM pedido_items pi
             WHERE pi.pedido_id   = v_salvedad.pedido_id
               AND pi.sucursal_id = v_sucursal
               AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
               AND pi.producto_id = ANY (pm.productos)) AS qty
      FROM promos pm
     WHERE pm.cant_compra > 0 AND pm.cant_bonif > 0
  )
  SELECT EXISTS (
    SELECT 1 FROM disparadores
     WHERE (qty + v_salvedad.cantidad_afectada) / cant_compra <> qty / cant_compra
  ) INTO v_toca_promo;

  IF v_toca_promo THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Restituir esta linea vuelve a dar derecho a un regalo de promocion que la salvedad habia recortado. Reponerlo y volver a consumir el contenedor no esta implementado: corregir a mano.',
      'codigo', 'anulacion_toca_promociones'
    );
  END IF;
$a$,
$r$  WITH promos AS (
    SELECT h.promocion_id, h.cantidad_compra AS cant_compra, h.cantidad_bonificacion AS cant_bonif, h.productos
      FROM public.promos_del_pedido(v_salvedad.pedido_id) h
     WHERE v_salvedad.producto_id = ANY (h.productos)
  ), disparadores AS (
    SELECT pm.promocion_id, pm.cant_compra,
           (SELECT COALESCE(SUM(pi.cantidad), 0)::INT
              FROM pedido_items pi
             WHERE pi.pedido_id   = v_salvedad.pedido_id
               AND pi.sucursal_id = v_sucursal
               AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
               AND pi.producto_id = ANY (pm.productos)) AS qty
      FROM promos pm
     WHERE pm.cant_compra > 0 AND pm.cant_bonif > 0
  )
  SELECT array_agg(promocion_id ORDER BY promocion_id) INTO v_promos_toca
    FROM disparadores
   WHERE (qty + v_salvedad.cantidad_afectada) / cant_compra <> qty / cant_compra;
  v_toca_promo := v_promos_toca IS NOT NULL;

  /* 1592-b5 (#1592): cruzar un multiplo no quiere decir que la salvedad le haya
     sacado el regalo. La resincronizacion de registrar_salvedad solo recorta si
     el pedido tenia mas regalo del que le queda derecho; si no recorto nada,
     restituir deja el pedido como estaba antes de la salvedad. El recorte deja en
     audit_logs, en la transaccion de la salvedad (su misma created_at), el UPDATE
     a la baja o el DELETE de una linea de regalo de esas promos. La fila de la
     propia linea de la salvedad (la recorto o la borro) dice que el log de esa
     transaccion esta: sin ella no se sabe, y se rechaza como antes. Una linea de
     regalo actualizada que ya no existe cuenta como recorte (no se sabe de que
     promo era). */
  IF v_toca_promo THEN
    v_log_linea := EXISTS (
      SELECT 1 FROM audit_logs a
       WHERE a.tabla = 'pedido_items' AND a.sucursal_id = v_sucursal
         AND a.created_at = v_salvedad.created_at
         AND ((a.accion = 'DELETE'
               AND a.old_data->>'pedido_id' = v_salvedad.pedido_id::text
               AND a.old_data->>'producto_id' = v_salvedad.producto_id::text
               AND COALESCE((a.old_data->>'es_bonificacion')::boolean, FALSE) = COALESCE(v_salvedad.es_bonificacion, FALSE))
              OR (a.accion = 'UPDATE' AND a.registro_id = v_salvedad.pedido_item_id::text)));

    IF NOT v_log_linea THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Restituir esta linea vuelve a dar derecho a un regalo de promocion, y no se puede saber si la salvedad lo recorto. Reponerlo y volver a consumir el contenedor no esta implementado: corregir a mano.',
        'codigo', 'anulacion_toca_promociones'
      );
    END IF;

    IF EXISTS (
      SELECT 1 FROM audit_logs a
       WHERE a.tabla = 'pedido_items' AND a.sucursal_id = v_sucursal
         AND a.created_at = v_salvedad.created_at
         AND ((a.accion = 'DELETE'
               AND a.old_data->>'pedido_id' = v_salvedad.pedido_id::text
               AND COALESCE((a.old_data->>'es_bonificacion')::boolean, FALSE)
               AND (a.old_data->>'promocion_id')::bigint = ANY (v_promos_toca))
              OR (a.accion = 'UPDATE'
                  AND (a.new_data->>'cantidad')::numeric < (a.old_data->>'cantidad')::numeric
                  AND a.registro_id IS DISTINCT FROM v_salvedad.pedido_item_id::text
                  AND COALESCE((SELECT pi.pedido_id = v_salvedad.pedido_id
                                       AND COALESCE(pi.es_bonificacion, FALSE)
                                       AND pi.promocion_id = ANY (v_promos_toca)
                                  FROM pedido_items pi
                                 WHERE pi.id = a.registro_id::bigint), TRUE)))) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Restituir esta linea vuelve a dar derecho a un regalo de promocion que la salvedad habia recortado. Reponerlo y volver a consumir el contenedor no esta implementado: corregir a mano.',
        'codigo', 'anulacion_toca_promociones'
      );
    END IF;
  END IF;
$r$, 'anular_salvedad (regalo recortado, 1592-b5)');

  -- 3c · 1559-c2: el producto antes que los pagos
  v_def := pg_temp.parche(v_def,
$a$  -- La boleta ya esta bloqueada (arriba); los pagos, por id.
  IF jsonb_array_length(COALESCE(v_salvedad.cobro_recortado, '[]'::jsonb)) > 0 THEN
$a$,
$r$  -- La boleta ya esta bloqueada (arriba); los pagos, por id.
  -- 1559-c2 (#1559): y antes que los pagos, el producto de la salvedad, el orden
  -- de registrar_salvedad (pedido, linea, productos, pagos). Al reves, con un
  -- pago recortado que se fue a otra boleta y una salvedad sobre ella con el
  -- mismo producto, cada una esperaba a la otra (40P01).
  PERFORM 1 FROM productos
   WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF jsonb_array_length(COALESCE(v_salvedad.cobro_recortado, '[]'::jsonb)) > 0 THEN
$r$, 'anular_salvedad (orden de locks, 1559-c2)');

  -- 3d · VTA-1: la linea vuelve con su foto
  v_def := pg_temp.parche(v_def,
$a$    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario, costo_unitario_al_crear,
      es_bonificacion, promocion_id,
      combo_id, precio_sin_combo_unitario, combo_roto_id
    )
    VALUES (
      -- #1140: la linea no existe (esta en 0): vuelve lo de esta salvedad.
      v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_afectada,
      v_salvedad.precio_unitario, v_salvedad.cantidad_afectada * v_salvedad.precio_unitario, v_sucursal,
      v_neto, v_iva, 0, v_pct_iva,
      v_real,
      -- mig 257 (#673): la cascada unica de la 238, no una copia.
      public.costo_valuacion(NULL, v_costo_prom, v_costo_real, v_costo_sin, v_pct_ii),
$a$,
$r$    -- VTA-1 (#1595): la foto que registrar_salvedad guardo al borrar la linea:
    -- el costo, la lista, el origen y el descuento de la venta, no los de hoy.
    -- Sin foto (salvedades anteriores a la NNN), lo de antes: el costo de hoy, y
    -- la lista, el origen y el descuento que completa el trigger. El origen y el
    -- descuento son de la linea que era: si vuelve como otra (era del combo y
    -- vuelve como la parte que salio de el, o al reves), los completa el trigger.
    SELECT f.costo_unitario_al_crear, f.precio_lista_al_crear, f.origen_precio, f.descuento_pct
      INTO v_foto_costo, v_foto_lista, v_foto_origen, v_foto_desc
      FROM salvedad_linea_foto f
     WHERE f.salvedad_id = p_salvedad_id AND f.sucursal_id = v_sucursal;
    IF (v_foto_origen = 'combo') IS DISTINCT FROM (v_precio_combo IS NOT NULL) THEN
      v_foto_origen := NULL;
      v_foto_desc   := NULL;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario, costo_unitario_al_crear,
      precio_lista_al_crear, origen_precio, descuento_pct,
      es_bonificacion, promocion_id,
      combo_id, precio_sin_combo_unitario, combo_roto_id
    )
    VALUES (
      -- #1140: la linea no existe (esta en 0): vuelve lo de esta salvedad.
      v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_afectada,
      v_salvedad.precio_unitario, v_salvedad.cantidad_afectada * v_salvedad.precio_unitario, v_sucursal,
      v_neto, v_iva, 0, v_pct_iva,
      v_real,
      -- mig 257 (#673): la cascada unica de la 238, no una copia. VTA-1: la foto
      -- es el snapshot; una foto NULL cae al costo de hoy, como en los reportes.
      public.costo_valuacion(v_foto_costo, v_costo_prom, v_costo_real, v_costo_sin, v_pct_ii),
      v_foto_lista, v_foto_origen, v_foto_desc,
$r$, 'anular_salvedad (la linea vuelve con su foto, VTA-1)');

  EXECUTE v_def;
END
$parche_anular$;

-- =========================================================================
-- 4 · consolidar_condiciones: activo distinto se rechaza; un id repetido, una vez
-- =========================================================================
DO $parche_consolidar$
DECLARE
  v_def text := pg_get_functiondef('public.consolidar_condiciones(bigint,bigint[],text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF p_grupos_origen IS NULL OR array_length(p_grupos_origen, 1) IS NULL THEN
    RAISE EXCEPTION 'No hay condiciones para fusionar';
  END IF;
$a$,
$r$  IF p_grupos_origen IS NULL OR array_length(p_grupos_origen, 1) IS NULL THEN
    RAISE EXCEPTION 'No hay condiciones para fusionar';
  END IF;

  -- 1561-c5 (#1561): un id repetido es el mismo grupo y se fusiona una vez. Antes
  -- la cuenta de abajo no cerraba y respondia que alguna no existe. Conserva el
  -- orden de la primera aparicion, que decide que escala se mueve.
  p_grupos_origen := ARRAY(SELECT o.g FROM unnest(p_grupos_origen) WITH ORDINALITY AS o(g, n)
                            GROUP BY o.g ORDER BY min(o.n));
$r$, 'consolidar_condiciones (id repetido, 1561-c5)');

  v_def := pg_temp.parche(v_def,
$a$  IF FOUND THEN
    RAISE EXCEPTION 'No se puede fusionar: hay % precios distintos para % unidades',
      v_conflicto.precios, v_conflicto.cantidad_minima;
  END IF;
$a$,
$r$  IF FOUND THEN
    RAISE EXCEPTION 'No se puede fusionar: hay % precios distintos para % unidades',
      v_conflicto.precios, v_conflicto.cantidad_minima;
  END IF;

  -- CAT-10 (#1596, decision del dueño 15/11): fusionar condiciones con distinto
  -- activo se rechaza. Los productos de origen pasan al destino, asi que fusionar
  -- una activa en una inactiva les apagaba el precio mayorista, y una inactiva en
  -- una activa prendia un descuento apagado.
  SELECT o.nombre, o.activo, d.activo AS activo_destino
    INTO v_conflicto
    FROM grupos_precio o
    JOIN grupos_precio d ON d.id = p_grupo_destino
   WHERE o.id = ANY (p_grupos_origen) AND o.sucursal_id = v_sucursal
     AND o.activo IS DISTINCT FROM d.activo
   ORDER BY o.id
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'No se puede fusionar: «%» está % y la condición destino está %. Activalas o desactivalas a las dos antes de fusionar.',
      v_conflicto.nombre,
      CASE WHEN v_conflicto.activo THEN 'activa' ELSE 'inactiva' END,
      CASE WHEN v_conflicto.activo_destino THEN 'activa' ELSE 'inactiva' END;
  END IF;

  -- CAT-10: y lo mismo con dos escalas de la misma cantidad. Abajo, la de origen
  -- se borra y queda la del destino (o la primera de origen): si una esta apagada
  -- y la otra no, fusionar prende o apaga ese precio.
  SELECT e.cantidad_minima
    INTO v_conflicto
    FROM grupo_precio_escalas e
   WHERE e.grupo_precio_id = p_grupo_destino OR e.grupo_precio_id = ANY(p_grupos_origen)
   GROUP BY e.cantidad_minima
  HAVING count(DISTINCT COALESCE(e.activo::text, 'sin dato')) > 1
   ORDER BY e.cantidad_minima
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'No se puede fusionar: la escala de % u. está activa en una condición e inactiva en otra. Activalas o desactivalas a las dos antes de fusionar.',
      v_conflicto.cantidad_minima;
  END IF;
$r$, 'consolidar_condiciones (activo, CAT-10)');

  EXECUTE v_def;
END
$parche_consolidar$;

-- =========================================================================
-- 5 · CAT-9 · el techo del impuesto interno
-- =========================================================================
-- 5a · la tasa nominal de un encuadre, y las efectivas que salen de ella
ALTER TABLE public.ii_alicuotas
  DROP CONSTRAINT ii_alicuotas_tasa_rango,
  ADD CONSTRAINT ii_alicuotas_tasa_rango
  CHECK (tasa_nominal >= 0 AND tasa_nominal <= 0.99);

-- 100 · 0,99 / 0,01 = 9900: la efectiva de 99 % nominal. El techo deja afuera el NaN.
ALTER TABLE public.productos
  DROP CONSTRAINT productos_impuestos_internos_rango,
  ADD CONSTRAINT productos_impuestos_internos_rango
  CHECK (impuestos_internos >= 0 AND impuestos_internos <= 9900);

ALTER TABLE public.compra_items
  DROP CONSTRAINT compra_items_impuestos_internos_rango,
  ADD CONSTRAINT compra_items_impuestos_internos_rango
  CHECK (impuestos_internos >= 0 AND impuestos_internos <= 9900);

-- 5b · cambiar_alicuota_ii: el alta del encuadre y sus alzas programadas
DO $parche_alicuota$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_alicuota_ii(bigint,numeric,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    RAISE EXCEPTION 'Solo un administrador puede cambiar alicuotas de impuestos internos' USING ERRCODE = '42501';
  END IF;
$a$,
$r$    RAISE EXCEPTION 'Solo un administrador puede cambiar alicuotas de impuestos internos' USING ERRCODE = '42501';
  END IF;

  -- CAT-9 (#1596, decision del dueño 15/11): la tasa nominal va de 0 a 99 %.
  -- El techo deja afuera el NaN. Lo cierra tambien ii_alicuotas_tasa_rango.
  IF p_tasa_nominal IS NULL OR p_tasa_nominal < 0 OR p_tasa_nominal > 0.99 THEN
    RAISE EXCEPTION 'La tasa nominal de un impuesto interno va de 0 %% a 99 %%.' USING ERRCODE = '22023';
  END IF;
$r$, 'cambiar_alicuota_ii (techo de la tasa, CAT-9)');

  EXECUTE v_def;
END
$parche_alicuota$;

-- 5c · el validador de los renglones de una compra
DO $parche_renglones$
DECLARE
  v_def text := pg_get_functiondef('public._compra_renglones_fuera_de_rango(jsonb,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$               WHEN (e.val->>'impuestos_internos')::NUMERIC < 0 OR (e.val->>'impuestos_internos')::NUMERIC > 100
                 THEN 'el impuesto interno es un porcentaje, de 0 a 100'
$a$,
$r$               -- CAT-9 (#1596): es la efectiva sobre el neto; 9900 es la de 99 % nominal.
               WHEN (e.val->>'impuestos_internos')::NUMERIC < 0 OR (e.val->>'impuestos_internos')::NUMERIC > 9900
                 THEN 'el impuesto interno sobre el neto va de 0 a 9900 % (99 % nominal)'
$r$, '_compra_renglones_fuera_de_rango (techo del impuesto interno, CAT-9)');

  EXECUTE v_def;
END
$parche_renglones$;

-- 5d · refrescar_ii_productos: un encuadre que falla no frena a los demás
CREATE OR REPLACE FUNCTION public.refrescar_ii_productos()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_n   integer := 0;
  v_m   integer;
  r     record;
BEGIN
  -- CAT-9 (#1596): un encuadre por vez, cada uno en su sub-bloque. Antes era un
  -- solo UPDATE: una ficha que no entraba en un CHECK lo hacia fallar entero, y
  -- ningun encuadre se refrescaba (todos los dias, hasta corregirlo). Lo que
  -- quede sin refrescar lo ve II-A de auditoria_integridad().
  FOR r IN
    SELECT DISTINCT p.ii_encuadre_id AS id
      FROM public.productos p
     WHERE p.ii_encuadre_id IS NOT NULL
     ORDER BY 1
  LOOP
    BEGIN
      UPDATE public.productos p
         SET impuestos_internos = d.tasa
        FROM (SELECT COALESCE(round(public.ii_tasa_efectiva(r.id, v_hoy), 4), 0) AS tasa) d
       WHERE p.ii_encuadre_id = r.id
         AND p.impuestos_internos IS DISTINCT FROM d.tasa;
      GET DIAGNOSTICS v_m = ROW_COUNT;
      v_n := v_n + v_m;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'refrescar_ii_productos: el encuadre % no se pudo refrescar (%: %)', r.id, SQLSTATE, SQLERRM;
    END;
  END LOOP;
  RETURN v_n;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer, los EXECUTE, los CHECK y la tabla
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
  v_mal text[] := '{}';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 'a81b998f9b41164d1ad406ba01d06834', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.anular_salvedad(bigint,text)', '3aa465a34490312cd642a5508530873f', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.consolidar_condiciones(bigint,bigint[],text)', '686172fdb87e7c735a09d4b757001c34', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.cambiar_alicuota_ii(bigint,numeric,date)', '8dcbeb41fb5dcb5b505e5a28f8697f8b', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.refrescar_ii_productos()', 'aa8f4a9b7c12f61c9db0f8418144f9bf', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._compra_renglones_fuera_de_rango(jsonb,bigint)', 'ba4f21f6eed64903ad3137419446c0ad', false,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      v_mal := v_mal || format('%s (md5 %s, acl %s, definer %s)', r.f, x.h, x.a, x.def);
    END IF;
  END LOOP;

  FOR r IN SELECT * FROM (VALUES
    ('public.productos'::regclass,    'productos_impuestos_internos_rango',
     'CHECK (((impuestos_internos >= (0)::numeric) AND (impuestos_internos <= (9900)::numeric)))'),
    ('public.compra_items'::regclass, 'compra_items_impuestos_internos_rango',
     'CHECK (((impuestos_internos >= (0)::numeric) AND (impuestos_internos <= (9900)::numeric)))'),
    ('public.ii_alicuotas'::regclass, 'ii_alicuotas_tasa_rango',
     'CHECK (((tasa_nominal >= (0)::numeric) AND (tasa_nominal <= 0.99)))')
  ) AS t(tabla, nombre, def) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = r.tabla AND c.conname = r.nombre
                      AND c.convalidated AND pg_get_constraintdef(c.oid) = r.def) THEN
      v_mal := v_mal || format('el CHECK %s quedó %s', r.nombre,
                               (SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
                                 WHERE c.conrelid = r.tabla AND c.conname = r.nombre));
    END IF;
  END LOOP;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.salvedad_linea_foto'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.salvedad_linea_foto'::regclass)
     OR has_table_privilege('authenticated', 'public.salvedad_linea_foto', 'SELECT')
     OR has_table_privilege('anon', 'public.salvedad_linea_foto', 'SELECT')
     OR has_table_privilege('authenticated', 'public.salvedad_linea_foto', 'INSERT') THEN
    v_mal := v_mal || 'salvedad_linea_foto no quedó sólo de server (RLS sin policies y sin grants)'::text;
  END IF;

  IF array_length(v_mal, 1) > 0 THEN
    RAISE EXCEPTION 'mig NNN · no quedó como en el repo: %', array_to_string(v_mal, ' | ');
  END IF;
END
$post$;

COMMIT;
