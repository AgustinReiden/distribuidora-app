-- =========================================================================
-- NNN · PROMOS Y COMBOS: EL OTRO SABOR SIN SU BULTO EN EL ALTA Y LA EDICIÓN, EL
--       COMBO CON UN COMPONENTE SIN LISTA, EL COMBO QUE CAMBIÓ DE PRECIO NO CRECE
--       Y EL REGALO DEL PEDIDO EN LA EDICIÓN Y EN EL CAMBIO DE CLIENTE
--       (tanda 6 bis del plan #1603, tarjeta I: promos-B1, B4 y B5 de la
--        reauditoría del 24/11 y las notas N1 y N2 de la segunda lente de promos)
--
-- Crea `_regalo_sin_bulto` y parcha por ancla, con premisa de md5 sobre los cuerpos
-- vivos de la 545, `regalo_fuera_de_promo`, `_regalo_de_la_promo`,
-- `combo_fuera_de_regla` y `_guardar_combos_pedido`, y en la rama del admin de
-- `crear_pedido_completo` y `actualizar_pedido_items` (de la tarjeta H, ya aplicadas en
-- la 545) suma una llamada a `_regalo_sin_bulto`. No cambia firmas, permisos ni tablas:
-- no hay DDL de tabla ni LOCK TABLE.
-- Ensayo: scripts/test-promos-combos-tanda6bis-1603.sql. Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- 1 · promos-B1 en el alta y la edición: otro sabor del mismo rubro sin «unidades
--     por bulto» no hereda el empaque de la promo
-- -------------------------------------------------------------------------
-- La 544 se lo pidió a la sustitución y al reparto. En el alta y la edición del pedido
-- se podía cargar como regalo otro sabor del mismo rubro (el admin desde el selector;
-- cualquiera con un request armado a mano), y su barra contaba con el N de la promo,
-- que es el empaque del regalo. `_regalo_sin_bulto` es la regla: un regalo de una promo
-- de fracción con unidades por bloque cuya barra (contenedor_de_barra) no es la del
-- contenedor de la promo, y cuyo contenedor no tiene bulto, se rechaza. No la piden el
-- regalo de la promo, un producto que el pedido (o el original de un cambio de cliente)
-- ya tenía como regalo de esa promo, una línea con su cadena de sustitución, una promo
-- sin unidades por bloque ni una que mueve stock. La llama `regalo_fuera_de_promo` (su
-- paso 4b: quien no es admin, y el bot) y, decisión de la coordinadora con el molde de la
-- 544 (es un dato que falta para contar la barra, no un permiso), la rama del admin del
-- alta y de la edición. El selector del admin en ModalPedido dice lo mismo antes de
-- confirmar, con el contenedor de la barra de cada sabor.
--
-- -------------------------------------------------------------------------
-- 2 · promos-B4: el combo acumulable con un componente sin precio de lista
-- -------------------------------------------------------------------------
-- `precio_fuera_de_politica` no valida una línea sin lista: en la edición, la que
-- conserva su precio (1559-b3) podía declarar un `precio_sin_escala_unitario` más alto
-- o un `precio_sin_combo_unitario` más bajo, y el descuento de escala de más le bajaba
-- el total del combo y el precio a las otras líneas. Ahora `combo_fuera_de_regla` publica
-- el sin escala que declaró cada línea (`app.combo_sin_escala`), `_guardar_combos_pedido`
-- lo guarda en `pedido_combos.precios` (`sin_escala`, junto a `combo` y `sin_combo`), y a
-- una línea sin lista no se le acepta un descuento de escala por unidad (sin escala −
-- sin combo) mayor que el guardado: 0 si la foto no lo tiene (una foto de antes, o un
-- producto que no estaba en el combo).
--
-- -------------------------------------------------------------------------
-- 3 · promos-B5: el combo que cambió de precio no crece
-- -------------------------------------------------------------------------
-- Decisión del dueño (25/11, reemplaza «un renglón, precio promedio»): a un pedido que
-- ya tiene un combo cuyo precio cambió, quien no es admin no le puede sumar más de ese
-- combo. El que ya estaba queda a su precio; conservar y bajar siguen andando; sumar se
-- rechaza con el motivo (el combo, lo que valía y lo que vale): «los combos nuevos
-- cargalos en otro pedido». El admin sí suma (decide el precio, como hoy). Si el precio
-- no cambió, sumar anda como siempre. `combo_fuera_de_regla` compara al centavo el
-- precio de la foto con el de hoy (`_combo_definicion`). La pantalla de edición no lo
-- arma y lo avisa con el mismo texto.
--
-- -------------------------------------------------------------------------
-- 4 · N1 y N2: el regalo del pedido
-- -------------------------------------------------------------------------
-- N1 · Decisión del dueño: el regalo del pedido es el que la promo daba cuando nació. La
-- edición que vuelve a ese regalo (un reparto que ya no cierra, en la pantalla) mandaba
-- el regalo de hoy; ahora manda el del pedido, y `regalo_fuera_de_promo` (paso 3) lo
-- acepta en una promo que el pedido ya tenía: el regalo de referencia
-- (`_regalo_de_la_promo`) o uno de su rubro, además del de hoy como siempre.
-- N2 · El pedido rehecho por un cambio de cliente nace de nuevo, pero su regalo es el del
-- original: `_regalo_de_la_promo` sigue el `pedido_historial` del cambio de cliente
-- («(cambio de cliente desde pedido #N)», que escribe cambiar_cliente_pedido) hasta el
-- primer pedido y mide desde su alta. Sin columna nueva.
--
-- Revertir: volver las seis funciones a los cuerpos de la premisa y borrar
-- `_regalo_sin_bulto`.
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
-- Premisas: los cuerpos vivos (ledger en la 545), lo que el arreglo usa tal como está, y
-- que la función nueva todavía no existe.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', '7a5d67c746a4d5bb67b8d313d13584be'),
    ('public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', '0ed07e72b5d047e60695d13bfae3d312'),
    ('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', '589942c33c244c752112bf7712d1fe84'),
    ('public._guardar_combos_pedido(bigint,bigint)', '3279e74715f9b580e7323bb66a085d55'),
    ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'e163e8f2bb16ec4c71243eeb77fd7761'),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '7e04bbbcb8876573286ef5d819f6dfe8'),
    ('public.contenedor_de_barra(bigint,bigint,bigint,bigint)', NULL),
    ('public._regalo_modo_del_pedido(bigint,bigint,bigint)', NULL),
    ('public._combo_definicion(bigint,bigint)', NULL),
    ('public.regalo_misma_categoria(bigint,bigint,bigint)', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    IF r.h IS NOT NULL THEN
      SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
      IF v IS DISTINCT FROM r.h THEN
        RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
      END IF;
    END IF;
  END LOOP;
  IF to_regprocedure('public._regalo_sin_bulto(jsonb,bigint,bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · _regalo_sin_bulto ya existe';
  END IF;
END
$premisas$;

-- =========================================================================
-- 1 · promos-B1: la regla del bulto, en una función
-- =========================================================================
CREATE FUNCTION public._regalo_sin_bulto(p_items jsonb, p_sucursal bigint, p_pedido_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path = public, pg_temp
AS $function$
DECLARE
  -- promos-B1 (tanda 6 bis de #1603): el pedido cuyos regalos ya están, también el
  -- original de un cambio de cliente (el pedido nuevo recrea sus líneas tal cual).
  v_ped    bigint := COALESCE(p_pedido_id, NULLIF(current_setting('app.cambio_cliente_desde', true), '')::bigint);
  v_nombre text;
BEGIN
  -- Un regalo de una promo de fracción con unidades por bloque cuenta en la barra de SU
  -- contenedor (contenedor_de_barra, como el alta y el motor), con el bulto de ese
  -- contenedor o, sin el dato, con el N de la promo, que es el empaque del regalo. Así
  -- un sabor suelto contaba como si viniera en el fardo del regalo. Como en
  -- sustituir_regalo_pedido y dividir_regalo_pedido (544), sin el bulto no entra. No lo
  -- piden el regalo de la promo (su barra es la del contenedor), un producto que el
  -- pedido ya tenía como regalo de esa promo, una línea con su cadena (la sustitución ya
  -- lo pidió), una promo sin unidades por bloque ni una que mueve stock.
  SELECT string_agg(DISTINCT pr.nombre, ', ' ORDER BY pr.nombre) INTO v_nombre
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END) e
    JOIN promociones p ON p.id = NULLIF(e->>'promocion_id', '')::bigint AND p.sucursal_id = p_sucursal
    JOIN productos pr ON pr.id = NULLIF(e->>'producto_id', '')::bigint AND pr.sucursal_id = p_sucursal
   WHERE COALESCE((e->>'es_bonificacion')::boolean, false)
     AND NOT (p_pedido_id IS NOT NULL AND e->>'_cadena' IS NOT NULL)
     AND COALESCE(p.unidades_por_bloque, 0) > 0
     AND NOT COALESCE(CASE WHEN v_ped IS NULL THEN p.regalo_mueve_stock
                           ELSE public._regalo_modo_del_pedido(v_ped, p.id, p_sucursal) END, true)
     AND NOT (v_ped IS NOT NULL
              AND EXISTS (SELECT 1 FROM pedido_items pi
                           WHERE pi.pedido_id = v_ped AND pi.sucursal_id = p_sucursal
                             AND COALESCE(pi.es_bonificacion, false)
                             AND pi.promocion_id = p.id AND pi.producto_id = pr.id))
     AND public.contenedor_de_barra(p.id, pr.id, p_sucursal, pr.id) IS DISTINCT FROM p.ajuste_producto_id
     AND (SELECT pc.unidades_por_bulto FROM productos pc
           WHERE pc.id = public.contenedor_de_barra(p.id, pr.id, p_sucursal, pr.id)
             AND pc.sucursal_id = p_sucursal) IS NULL;
  IF v_nombre IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN 'Para regalar ' || v_nombre
         || ' hay que cargar en su ficha cuántas unidades sueltas trae cada unidad de stock (unidades por bulto).';
END
$function$;

-- Sólo de server: la llaman regalo_fuera_de_promo y las RPC del alta y la edición.
REVOKE ALL ON FUNCTION public._regalo_sin_bulto(jsonb, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._regalo_sin_bulto(jsonb, bigint, bigint) TO service_role;

-- =========================================================================
-- Los tramos que se cambian por ancla: la función, el ancla y su reemplazo. La
-- poscondición los vuelve a poner al revés y compara con el md5 de la premisa.
-- =========================================================================
CREATE TEMP TABLE t6bi_tramos (ord int PRIMARY KEY, fn text, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO t6bi_tramos VALUES
(1, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'las declaraciones',
$a$  v_conservado int;
$a$,
$r$  v_conservado int;
  -- N1 (tanda 6 bis de #1603): el regalo de referencia del pedido para la promo.
  v_ref        bigint;
  -- promos-B1 (tanda 6 bis de #1603): el motivo de _regalo_sin_bulto.
  v_sin_bulto  text;
$r$),
(2, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'el regalo de referencia',
$a$         AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = v_promo.id;
    END IF;
    IF EXISTS (
$a$,
$r$         AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = v_promo.id;
    END IF;
    -- N1 (tanda 6 bis de #1603), decisión del dueño: el regalo del pedido es el que la promo
    -- daba cuando nació (_regalo_de_la_promo, promos-B2). La edición que vuelve a él (o a
    -- uno de su rubro) en una promo que el pedido ya tenía entra aunque hoy la promo dé
    -- otro de otro rubro; el de hoy sigue entrando como siempre.
    v_ref := NULL;
    IF v_n_lineas > 0 THEN
      SELECT x.producto_id INTO v_ref
        FROM public._regalo_de_la_promo(p_pedido_id, v_promo.id, p_sucursal, NULL, NULL, NULL) x;
    END IF;
    IF EXISTS (
$r$),
(3, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'el regalo de referencia entra',
$a$               OR (p_pedido_id IS NOT NULL AND v_n_lineas = 1
                   AND v_prod_unica = NULLIF(e->>'producto_id', '')::bigint), false)) THEN
$a$,
$r$               OR (p_pedido_id IS NOT NULL AND v_n_lineas = 1
                   AND v_prod_unica = NULLIF(e->>'producto_id', '')::bigint)
               OR (v_ref IS NOT NULL
                   AND (v_ref = NULLIF(e->>'producto_id', '')::bigint
                        OR public.regalo_misma_categoria(v_ref, NULLIF(e->>'producto_id', '')::bigint, p_sucursal))),
               false)) THEN
$r$),
(4, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'el bulto del regalo',
$a$  -- 5. Exclusion (#1136): una sola promo con regalo por grupo excluyente.
$a$,
$r$  -- 4b. promos-B1 (tanda 6 bis de #1603): un regalo cuya barra no es la del contenedor de
  --     la promo, sin su bulto (_regalo_sin_bulto). Lo mismo le pide al admin la rama del
  --     admin del alta y de la edición.
  v_sin_bulto := public._regalo_sin_bulto(v_prod, p_sucursal, p_pedido_id);
  IF v_sin_bulto IS NOT NULL THEN
    RETURN v_sin_bulto;
  END IF;

  -- 5. Exclusion (#1136): una sola promo con regalo por grupo excluyente.
$r$),
-- 4 · N2: _regalo_de_la_promo,
(5, 'public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'las declaraciones',
$a$  v_precio  numeric;
BEGIN
$a$,
$r$  v_precio  numeric;
  -- N2 (tanda 6 bis de #1603): el pedido original de un cambio de cliente.
  v_desde   bigint;
  v_previo  bigint;
  v_vueltas int := 0;
  v_alta    timestamptz;
BEGIN
$r$),
(6, 'public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'el alta del pedido original',
$a$  SELECT pe.created_at INTO v_nacio
    FROM pedidos pe WHERE pe.id = p_pedido_id AND pe.sucursal_id = p_sucursal_id;
$a$,
$r$  SELECT pe.created_at INTO v_nacio
    FROM pedidos pe WHERE pe.id = p_pedido_id AND pe.sucursal_id = p_sucursal_id;
  -- N2 (tanda 6 bis de #1603): el pedido que rehízo un cambio de cliente nace de nuevo,
  -- pero su regalo es el del original: se sigue el pedido_historial que escribe
  -- cambiar_cliente_pedido («(cambio de cliente desde pedido #N)») hasta el primero, y se
  -- mide desde su alta. Un cambio sobre un pedido ya cambiado repite el paso (tope 20).
  v_desde := p_pedido_id;
  WHILE v_nacio IS NOT NULL AND v_vueltas < 20 LOOP
    v_vueltas := v_vueltas + 1;
    SELECT substring(h.valor_nuevo FROM '\(cambio de cliente desde pedido #([0-9]+)\)$')::bigint INTO v_previo
      FROM pedido_historial h
     WHERE h.pedido_id = v_desde AND h.sucursal_id = p_sucursal_id
       AND h.campo_modificado = 'cliente_id'
       AND h.valor_nuevo ~ '\(cambio de cliente desde pedido #[0-9]+\)$'
     ORDER BY h.id
     LIMIT 1;
    EXIT WHEN v_previo IS NULL OR v_previo = v_desde;
    SELECT pe.created_at INTO v_alta
      FROM pedidos pe WHERE pe.id = v_previo AND pe.sucursal_id = p_sucursal_id;
    EXIT WHEN v_alta IS NULL;
    v_nacio := LEAST(v_nacio, v_alta);
    v_desde := v_previo;
    v_previo := NULL;
  END LOOP;
$r$),
-- 2 y 3 · combo_fuera_de_regla,
(7, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'las declaraciones',
$a$  v_vendidos bigint;
$a$,
$r$  v_vendidos bigint;
  -- promos-B4 (tanda 6 bis de #1603): los precios de la foto.
  v_precios  jsonb;
  -- promos-B5 (tanda 6 bis de #1603): el precio de hoy del combo.
  v_precio_hoy numeric;
$r$),
(8, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'lo publicado empieza vacío',
$a$BEGIN
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e WHERE NULLIF(e->>'combo_id', '') IS NOT NULL) THEN
$a$,
$r$BEGIN
  -- promos-B4 (tanda 6 bis de #1603): lo que esta validación le publica a
  -- _guardar_combos_pedido arranca vacío.
  PERFORM set_config('app.combo_sin_escala', '', true);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e WHERE NULLIF(e->>'combo_id', '') IS NOT NULL) THEN
$r$),
(9, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'los precios de la foto',
$a$    v_def := NULL;
    v_k_foto := NULL;
    IF v_foto_de IS NOT NULL THEN
      SELECT jsonb_build_object('nombre', f.nombre, 'precio', f.precio,
                                'combina_escalas', f.combina_escalas, 'componentes', f.componentes),
             f.cantidad_combos
        INTO v_def, v_k_foto
$a$,
$r$    v_def := NULL;
    v_k_foto := NULL;
    v_precios := NULL;
    IF v_foto_de IS NOT NULL THEN
      SELECT jsonb_build_object('nombre', f.nombre, 'precio', f.precio,
                                'combina_escalas', f.combina_escalas, 'componentes', f.componentes),
             f.cantidad_combos, f.precios
        INTO v_def, v_k_foto, v_precios
$r$),
(10, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'publicar el sin escala',
$a$    CONTINUE WHEN NOT p_validar_politica;
$a$,
$r$    -- promos-B4 (tanda 6 bis de #1603): el sin escala que declara cada línea de un combo
    -- acumulable, para que _guardar_combos_pedido lo guarde en la foto (también el del
    -- admin, que no se valida).
    IF (v_def->>'combina_escalas')::boolean THEN
      PERFORM set_config('app.combo_sin_escala',
        (COALESCE(NULLIF(current_setting('app.combo_sin_escala', true), '')::jsonb, '{}'::jsonb)
         || jsonb_build_object(r.combo_id::text,
              COALESCE((SELECT jsonb_object_agg(x->>'producto_id', (x->>'sin_escala')::numeric)
                          FROM jsonb_array_elements(r.lineas) x
                         WHERE x->>'sin_escala' IS NOT NULL), '{}'::jsonb)))::text,
        true);
    END IF;

    CONTINUE WHEN NOT p_validar_politica;
$r$),
(11, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'la línea sin lista',
$a$        RETURN format('Una línea del combo "%s" viene sin su precio sin escala.', v_nombre);
      END IF;
      v_lineas := r.lineas;
$a$,
$r$        RETURN format('Una línea del combo "%s" viene sin su precio sin escala.', v_nombre);
      END IF;
      -- promos-B4 (tanda 6 bis de #1603): precio_fuera_de_politica no valida una línea sin
      -- precio de lista (la que conserva su precio en la edición, 1559-b3), así que su sin
      -- escala y su sin combo vienen sin control: no puede descontar por escala, por unidad,
      -- más de lo que descontaba en la foto del pedido (0 si la foto no lo tiene).
      IF EXISTS (SELECT 1
                   FROM jsonb_array_elements(r.lineas) x
                   JOIN productos pr ON pr.id = (x->>'producto_id')::bigint AND pr.sucursal_id = p_sucursal
                  WHERE (pr.precio IS NULL OR pr.precio <= 0)
                    AND (x->>'sin_escala')::numeric - (x->>'ref')::numeric
                        > COALESCE((v_precios->(x->>'producto_id')->>'sin_escala')::numeric
                                   - (v_precios->(x->>'producto_id')->>'sin_combo')::numeric, 0) + 0.005) THEN
        RETURN format('Una línea del combo "%s" es de un producto sin precio de lista y descuenta por escala más que en el pedido. Recargá la app y volvé a armar el pedido.', v_nombre);
      END IF;
      v_lineas := r.lineas;
$r$),
(12, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'el combo que cambió de precio no crece',
$a$    IF p_validar_politica AND v_k_foto IS NOT NULL AND NOT v_vigente AND v_k > v_k_foto THEN
      RETURN format('El combo "%s" ya no está vigente: el pedido puede conservar sus %s, no sumar más.',
                    v_nombre, v_k_foto);
    END IF;
$a$,
$r$    IF p_validar_politica AND v_k_foto IS NOT NULL AND NOT v_vigente AND v_k > v_k_foto THEN
      RETURN format('El combo "%s" ya no está vigente: el pedido puede conservar sus %s, no sumar más.',
                    v_nombre, v_k_foto);
    END IF;
    -- promos-B5 (tanda 6 bis de #1603), decisión del dueño del 25/11: a un combo que cambió
    -- de precio desde que se armó el pedido, quien no es admin no le suma más. El que ya
    -- estaba queda a su precio (la foto); conservar y bajar andan; sin cambio de precio,
    -- sumar anda como siempre. Al centavo, contra el precio de hoy del combo.
    IF p_validar_politica AND v_k_foto IS NOT NULL AND v_k > v_k_foto THEN
      v_precio_hoy := (public._combo_definicion(r.combo_id, p_sucursal)->>'precio')::numeric;
      IF round(v_precio_hoy * 100) IS DISTINCT FROM round((v_def->>'precio')::numeric * 100) THEN
        RETURN format('El combo "%s" cambió de precio desde que se armó el pedido: valía $ %s y hoy vale $ %s. Este pedido puede conservar sus %s o bajarlos; los combos nuevos cargalos en otro pedido.',
                      v_nombre,
                      translate(to_char((v_def->>'precio')::numeric, 'FM999,999,990.00'), ',.', '.,'),
                      translate(to_char(v_precio_hoy, 'FM999,999,990.00'), ',.', '.,'),
                      v_k_foto);
      END IF;
    END IF;
$r$),
(13, 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'el bulto del regalo del admin',
$a$  IF v_user_role <> 'admin' AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_motivo_regalo TEXT;
$a$,
$r$  -- promos-B1 (tanda 6 bis de #1603): el admin no pasa por regalo_fuera_de_promo, pero el
  -- bulto de un regalo cuya barra no es la del contenedor de la promo es un dato que falta
  -- para contar la barra, no un permiso (el molde de la 544): también se le pide a él.
  IF v_user_role = 'admin' AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_sin_bulto TEXT := public._regalo_sin_bulto(p_items, v_sucursal, NULL);
    BEGIN
      IF v_sin_bulto IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_sin_bulto || ' El pedido no se creó.'), 'codigo', 'regalo_fuera_de_promo');
      END IF;
    END;
  END IF;

  IF v_user_role <> 'admin' AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_motivo_regalo TEXT;
$r$),
(14, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'el bulto del regalo del admin',
$a$  -- Incluye al encargado. El admin queda exento.
  IF v_user_role <> 'admin' THEN
    DECLARE
      v_motivo_regalo TEXT;
$a$,
$r$  -- Incluye al encargado. El admin queda exento.
  -- promos-B1 (tanda 6 bis de #1603): salvo del bulto de un regalo nuevo cuya barra no es la
  -- del contenedor de la promo, que es un dato y no un permiso (el molde de la 544).
  IF v_user_role = 'admin' THEN
    DECLARE
      v_sin_bulto TEXT := public._regalo_sin_bulto(v_items, v_sucursal, p_pedido_id);
    BEGIN
      IF v_sin_bulto IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_sin_bulto || ' El pedido no se modificó.'));
      END IF;
    END;
  END IF;
  IF v_user_role <> 'admin' THEN
    DECLARE
      v_motivo_regalo TEXT;
$r$),
(15, 'public._guardar_combos_pedido(bigint,bigint)', 'las declaraciones',
$a$  v_original bigint := NULLIF(current_setting('app.combo_foto_pedido', true), '')::bigint;
$a$,
$r$  v_original bigint := NULLIF(current_setting('app.combo_foto_pedido', true), '')::bigint;
  -- promos-B4 (tanda 6 bis de #1603): el sin escala que declaró cada línea de un combo
  -- acumulable, como lo publicó combo_fuera_de_regla ({combo: {producto: sin escala}}).
  v_sin      jsonb := COALESCE(NULLIF(current_setting('app.combo_sin_escala', true), '')::jsonb, '{}'::jsonb);
$r$),
(16, 'public._guardar_combos_pedido(bigint,bigint)', 'el sin escala en la foto',
$a$           jsonb_object_agg(pi.producto_id::text,
                            jsonb_build_object('combo', pi.precio_unitario,
                                               'sin_combo', pi.precio_sin_combo_unitario)) AS precios
$a$,
$r$           jsonb_object_agg(pi.producto_id::text,
                            jsonb_strip_nulls(jsonb_build_object(
                              'combo', pi.precio_unitario,
                              'sin_combo', pi.precio_sin_combo_unitario,
                              'sin_escala', (v_sin->(pi.combo_id::text)->>(pi.producto_id::text))::numeric))) AS precios
$r$),
(17, 'public._guardar_combos_pedido(bigint,bigint)', 'lo publicado vale para este guardado',
$a$  END LOOP;
END
$a$,
$r$  END LOOP;
  -- promos-B4: lo publicado vale para este guardado y nada más.
  PERFORM set_config('app.combo_sin_escala', '', true);
END
$r$);

-- =========================================================================
-- El parche: cada función con sus tramos (su search_path ya termina en pg_temp)
-- =========================================================================
DO $parche$
DECLARE
  f     text;
  v_def text;
  r     record;
  v_n   int;
BEGIN
  FOR f IN SELECT DISTINCT fn FROM t6bi_tramos ORDER BY 1 LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    FOR r IN SELECT * FROM t6bi_tramos WHERE fn = f ORDER BY ord LOOP
      v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el ancla aparece % vez/veces y se esperaba 1', f, r.que, v_n;
      END IF;
      v_def := replace(v_def, r.ancla, r.nuevo);
    END LOOP;
    -- 531 (B15): el CREATE OR REPLACE lleva la cláusula SET; sin ella la borraría.
    IF position(E' SET search_path TO ''public'', ''pg_temp''\n' IN v_def) = 0 THEN
      RAISE EXCEPTION 'mig NNN · %: no encuentro su search_path', f;
    END IF;
    EXECUTE v_def;
  END LOOP;
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos son los del repo y no cambiaron fuera de sus tramos
-- (deshaciéndolos vuelve el md5 de la premisa); el definer, el search_path y los
-- EXECUTE, los de antes. La función nueva, como dice este archivo.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text;
  r     record;
  t     record;
  x     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)',
     '59ed33b778a9fac3e74a80935f6edf5b', '7a5d67c746a4d5bb67b8d313d13584be',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)',
     '3aa97e8704a400fc675ac77ec4073b74', '0ed07e72b5d047e60695d13bfae3d312',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)',
     'aa01d4500c61a4ada5ac6685c4894aef', '589942c33c244c752112bf7712d1fe84',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public._guardar_combos_pedido(bigint,bigint)',
     'b66a29e1ceba1a6f91f29b2cdf9c7a7b', '3279e74715f9b580e7323bb66a085d55',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
     '18a774b42cba9bcb9cbfb7fbee0f0680', 'e163e8f2bb16ec4c71243eeb77fd7761',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
     'daed6db30d98970e80858ebd106fe7af', '7e04bbbcb8876573286ef5d819f6dfe8',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true)
  ) AS v(fn, h, h_antes, acl, def) LOOP
    SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
    v_src := x.prosrc;
    FOR t IN SELECT * FROM t6bi_tramos WHERE fn = r.fn ORDER BY ord DESC LOOP
      IF (length(v_src) - length(replace(v_src, t.nuevo, ''))) / length(t.nuevo) <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el tramo nuevo no aparece una vez', r.fn, t.que;
      END IF;
      v_src := replace(v_src, t.nuevo, t.ancla);
    END LOOP;
    IF md5(v_src) IS DISTINCT FROM r.h_antes THEN
      RAISE EXCEPTION 'mig NNN · % cambió fuera de sus tramos (md5 sin el parche %)', r.fn, md5(v_src);
    END IF;
  END LOOP;

  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
    FROM pg_proc WHERE oid = 'public._regalo_sin_bulto(jsonb,bigint,bigint)'::regprocedure;
  IF x.h IS DISTINCT FROM 'b1bd188fea2bc5e03b3b8ac68399a73d' OR x.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}'
     OR x.def OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
    RAISE EXCEPTION 'mig NNN · _regalo_sin_bulto no quedó como en el repo (md5 %, acl %, definer %, config %)', x.h, x.a, x.def, x.cfg;
  END IF;
END
$post$;

COMMIT;
