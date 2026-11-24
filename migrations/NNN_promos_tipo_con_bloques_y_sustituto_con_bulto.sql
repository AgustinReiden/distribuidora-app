-- =========================================================================
-- NNN · PROMOS: EL CAMBIO DE TIPO CON BLOQUES CERRADOS, EL SUSTITUTO DEL MISMO
--       RUBRO SIN SU BULTO Y LA EDICIÓN QUE VALIDA COMO EL ALTA
--       (tanda 6 del plan #1603, tarjeta B: PRM-1 y promos-B1, B2, B3 y B6 de la
--        reauditoría del 24/11)
--
-- Crea una función de trigger y su trigger sobre `promociones` (PRM-1) y la RPC
-- `regalo_referencia_de_linea` (B2), y parcha por ancla, con premisa de md5 sobre
-- los cuerpos vivos (los mismos en la 540 y la 541), cinco funciones:
-- `sustituir_regalo_pedido` y `dividir_regalo_pedido` (B1), `cambiar_regalo_promocion`
-- (B3), `regalo_fuera_de_promo` (B6) y `_regalo_de_la_promo` (B2). No cambia firmas ni
-- permisos de lo que existe: las tres primeras siguen SECURITY DEFINER y las dos
-- últimas INVOKER, todas con `search_path = public, pg_temp`.
-- Ensayo: scripts/test-promos-tanda6-1603.sql. Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- 1 · PRM-1 (medio): pasar a unidad entera una promo de fracción cuya barra ya
--     cerró bloques, con pedidos abiertos en esa barra, se rechaza
-- -------------------------------------------------------------------------
-- Decisión del dueño (24/11): «RECHAZAR el cambio de tipo (`regalo_mueve_stock`)
-- de una promo mientras haya pedidos abiertos con bloques vivos de esa promo»,
-- con el molde del cambio de factor (D2 de #1592). Promo «10 V dan 6 R» de
-- fracción, contenedor Cont (6 R = 1 Cont), Cont en 100. P1 = V×10 + R×6 cierra
-- un bloque (Cont 99) y P2 = V×10 + R×4 deja la barra en 4. Si el admin la pasaba
-- a unidad entera, la foto de fracción de P1 y P2 dejaba de valer para la barra
-- (`_regalo_barra_vale`) y cancelarlos, editarlos sin el regalo o registrarles
-- una salvedad ya no abría el bloque: Cont quedaba en 99 para siempre, con la
-- merma `promociones` sin su reversión. Ahora `trg_promo_tipo_con_bloques_vivos`
-- (BEFORE UPDATE OF regalo_mueve_stock, sólo de fracción a unidad entera)
-- rechaza si la promo tiene bloques vivos (`promo_ajustes.bloques_vivos > 0`) y
-- hay pedidos sin entregar ni cancelar con un regalo que entró en su barra (el
-- mismo filtro que D2: foto de fracción y sin la marca de un tramo anterior). El
-- mensaje dice el motivo, cuántos pedidos y cuáles. `cambiar_regalo_promocion`
-- lo devuelve como `{success:false, error}` (su EXCEPTION de `raise_exception`);
-- un UPDATE directo recibe el RAISE. Sigue como antes: pasar de unidad entera a
-- fracción, el cambio sin bloques cerrados (#1324) y el cambio con sólo pedidos
-- entregados. Lo que queda, igual que en D2 (H6 de su revisión): una salvedad
-- sobre un pedido ENTREGADO después del cambio no abre el bloque.
--
-- -------------------------------------------------------------------------
-- 2 · promos-B1: el sustituto del mismo rubro sin «unidades por bulto» no hereda
--     el empaque de la promo
-- -------------------------------------------------------------------------
-- En una promo de fracción con unidades por bloque, la barra de un sustituto
-- cuenta con el bulto de su contenedor y, sin el dato, con el N de la promo, que
-- es el empaque del regalo. La 295 (#950) pidió el dato sólo a un producto de
-- otra categoría: el del mismo rubro lo heredaba. R×4 (fardo x6) cambiado por
-- X×80 (X a $ 5, vendido por unidad) descontaba 13 X por 80 entregados. Ahora
-- `sustituir_regalo_pedido` lo pide también al del mismo rubro, y
-- `dividir_regalo_pedido` a cada sabor nuevo del reparto (la nota de stock-STK-4:
-- el reparto lo aceptaba). No lo piden el producto de la línea, un sustituto que
-- descuenta del contenedor de la promo (el regalo de la promo incluido: cuenta con
-- su N, como siempre) ni una promo sin unidades por bloque (cuenta de a una). El
-- mensaje es el de la 295. El front (`evaluarCambioRegalo`) dice lo mismo antes
-- de confirmar. El alta y la edición del pedido no cambian (lo dice el informe de
-- la tarjeta).
--
-- -------------------------------------------------------------------------
-- 3 · promos-B3: la edición de una promo valida lo que valida el alta
-- -------------------------------------------------------------------------
-- `cambiar_regalo_promocion` con `p_datos` (lo que manda el front) no pedía lo
-- que sí pide `crear_promocion`: con `reglas: []` borraba las reglas, con
-- `producto_ids: []` borraba los productos, con ajuste automático aceptaba una
-- promo sin contenedor, sin unidades por bloque o sin descripción del regalo, y sin
-- él una sin producto de regalo. Ahora lo rechaza con los mensajes del alta, antes
-- de escribir. Sin `p_datos` (un bundle de antes de la 472) no cambia nada.
--
-- -------------------------------------------------------------------------
-- 4 · promos-B6: el regalo de una promo que ya no rige se conserva pero no crece
-- -------------------------------------------------------------------------
-- Decisión del dueño (24/11): V×10 + R×4 con la promo apagada, editado a V×20,
-- sigue con R×4; bajar la venta lo recorta como siempre. `regalo_fuera_de_promo`
-- (paso 4, en la edición) topea en lo que el pedido ya tenía, en cortes. Espejo
-- en el front: `regaloQueNoCrece`. El admin no pasa por esa regla.
--
-- -------------------------------------------------------------------------
-- 5 · promos-B2: el tope del sustituto, contra el regalo del pedido
-- -------------------------------------------------------------------------
-- Decisión del dueño (24/11): el tope se mide contra el regalo que daba la promo y
-- lo que valía cuando nació el pedido, no contra el de hoy (un caramelo de $ 5
-- cambiado después por un perfume de $ 500 deja el pedido de antes topeado en $ 5).
-- `_regalo_de_la_promo` lo reconstruye por `audit_logs` desde `pedidos.created_at`
-- (que una edición no mueve), clave por clave. La pantalla lo lee con la RPC nueva
-- `regalo_referencia_de_linea` (admin y encargado, de su sucursal).
--
-- Revertir: volver las cinco funciones a los cuerpos de la premisa, y borrar el
-- trigger, su función y `regalo_referencia_de_linea`.
-- =========================================================================

BEGIN;

-- La única tabla con DDL (el CREATE TRIGGER): su lock primero, sin esperar (el
-- molde de la 521).
LOCK TABLE public.promociones IN SHARE ROW EXCLUSIVE MODE NOWAIT;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos (ledger en la 540), lo que el arreglo usa tal como
-- está, y que el trigger y su función todavía no existen.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', '9fcf5264eb15043ce24b91b4c69e5ae7'),
    ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', '8b084f84c9847ffb8960585b30407ed5'),
    ('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)', '500ca25bc79a22ac9355feaca0e20733'),
    ('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', '29f0aa33fd68e34746cb959550f6212f'),
    ('public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'bd3354c71bc4b681173f97dd1b009b69'),
    ('public.contenedor_de_barra(bigint,bigint,bigint,bigint)', NULL),
    ('public._regalo_modo_del_pedido(bigint,bigint,bigint)', NULL)
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
  IF to_regprocedure('public.promo_tipo_con_bloques_vivos()') IS NOT NULL
     OR to_regprocedure('public.regalo_referencia_de_linea(bigint)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_promo_tipo_con_bloques_vivos') THEN
    RAISE EXCEPTION 'mig NNN · el trigger trg_promo_tipo_con_bloques_vivos, su función o regalo_referencia_de_linea ya existen';
  END IF;
END
$premisas$;

-- =========================================================================
-- 1 · PRM-1: el trigger del cambio de tipo
-- =========================================================================
CREATE FUNCTION public.promo_tipo_con_bloques_vivos()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_pedidos int;
  v_ids     text;
BEGIN
  -- PRM-1 (tanda 6 de #1603), decisión del dueño (24/11): con la promo en unidad entera,
  -- la foto de fracción de un pedido abierto deja de valer para la barra
  -- (_regalo_barra_vale), y cancelarlo, editarlo sin el regalo o registrarle una salvedad
  -- ya no abre el bloque que cerró: el contenedor queda un fardo abajo. Mientras la barra
  -- tenga bloques vivos y algún pedido abierto haya entrado en ella, no se cambia el tipo
  -- (el molde del factor, D2 de #1592: promo_config_barra_con_pedidos). Sin bloques vivos,
  -- o con todos los pedidos entregados, se puede, como siempre (#1324). SECURITY DEFINER:
  -- cuenta lo que hay, no lo que la RLS deja ver al que guarda.
  IF NOT EXISTS (SELECT 1 FROM promo_ajustes pa
                  WHERE pa.promocion_id = NEW.id AND pa.sucursal_id = NEW.sucursal_id
                    AND pa.bloques_vivos > 0) THEN
    RETURN NEW;
  END IF;
  -- Los pedidos abiertos con un regalo que entró en la barra: los de D2 (foto de fracción,
  -- sin la marca de un tramo anterior; la promo de la tabla es la de antes del cambio).
  SELECT count(*), left(string_agg('#' || x.id, ', ' ORDER BY x.id), 200)
    INTO v_pedidos, v_ids
    FROM (SELECT DISTINCT pe.id
            FROM pedido_items pi
            JOIN pedidos pe ON pe.id = pi.pedido_id
           WHERE pi.promocion_id = NEW.id
             AND pi.sucursal_id = NEW.sucursal_id
             AND COALESCE(pi.es_bonificacion, false)
             AND pe.estado NOT IN ('entregado', 'cancelado')
             AND NOT COALESCE(public._regalo_modo_del_pedido(pe.id, NEW.id, NEW.sucursal_id), false)
             AND NOT EXISTS (SELECT 1 FROM pedido_promo_reglas f
                              WHERE f.pedido_id = pe.id AND f.promocion_id = NEW.id
                                AND f.sucursal_id = NEW.sucursal_id AND f.barra_anterior)) x;
  IF v_pedidos > 0 THEN
    RAISE EXCEPTION 'No se puede pasar la promo «%» a unidad entera: su barra ya cerró bloques del contenedor y hay % pedido(s) sin entregar con regalos que se contaron en ella (%). Si después se cancelaran o se editaran, esos bloques no volverían al contenedor. Esperá a que esos pedidos se entreguen o se cancelen, y cambialo después.',
      NEW.nombre, v_pedidos, v_ids;
  END IF;
  RETURN NEW;
END
$function$;

-- Una función de trigger no necesita EXECUTE para nadie (CLAUDE.md): postgres y service_role.
REVOKE ALL ON FUNCTION public.promo_tipo_con_bloques_vivos() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.promo_tipo_con_bloques_vivos() TO service_role;

CREATE TRIGGER trg_promo_tipo_con_bloques_vivos
  BEFORE UPDATE OF regalo_mueve_stock ON public.promociones
  FOR EACH ROW
  WHEN (OLD.regalo_mueve_stock IS FALSE AND NEW.regalo_mueve_stock IS TRUE)
  EXECUTE FUNCTION public.promo_tipo_con_bloques_vivos();

-- =========================================================================
-- 2 y 3 · Los tramos que se cambian: la función, el ancla y su reemplazo. La
-- poscondición los vuelve a poner al revés y compara con el md5 de la premisa.
-- =========================================================================
CREATE TEMP TABLE t6b_tramos (ord int PRIMARY KEY, fn text, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO t6b_tramos VALUES
-- 2 · promos-B1: la sustitución
(1, 'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 'el bulto del sustituto',
$a$  IF v_otra_categoria AND NOT v_regalo_mueve_stock
     AND (SELECT pc.unidades_por_bulto FROM productos pc
$a$,
$r$  -- promos-B1 (tanda 6 de #1603): también un sustituto del mismo rubro cuya barra no es la
  -- del contenedor de la promo. Sin su bulto contaba con el N de la promo, que es el empaque
  -- del regalo: X×80 sueltos (X a $ 5, vendido por unidad) en lugar de R×4 descontaba 13 X
  -- por 80 entregados. No lo piden un sustituto que descuenta del contenedor de la promo (el
  -- regalo de la promo incluido: cuenta con su N, como siempre) ni una promo sin unidades por
  -- bloque (cuenta de a una).
  IF p_producto_nuevo_id IS DISTINCT FROM v_item.producto_id AND NOT v_regalo_mueve_stock
     AND (v_otra_categoria
          OR (COALESCE(v_promo.unidades_por_bloque, 0) > 0
              AND public.contenedor_de_barra(v_promo.id, p_producto_nuevo_id,
                                             v_sucursal, v_ajuste_sustituto_efectivo)
                  IS DISTINCT FROM v_promo.ajuste_producto_id))
     AND (SELECT pc.unidades_por_bulto FROM productos pc
$r$),
-- 2 · promos-B1: el reparto (la nota de stock-STK-4)
(2, 'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 'el bulto de un sabor nuevo',
$a$    IF v_nombre IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error',
        v_nombre || ' viene en otro empaque que el regalo original: para cambiarlo por otro empaque usá el cambio simple (una sola fila)');
    END IF;
$a$,
$r$    IF v_nombre IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error',
        v_nombre || ' viene en otro empaque que el regalo original: para cambiarlo por otro empaque usá el cambio simple (una sola fila)');
    END IF;
    -- promos-B1 (tanda 6 de #1603; nota de stock-STK-4): un sabor nuevo cuya barra no es la del
    -- contenedor de la promo necesita su bulto, como en sustituir_regalo_pedido. Sin el dato,
    -- su barra contaba con el N de la promo y el chequeo de arriba lo daba por del mismo
    -- empaque. No lo piden el producto de la línea ni una promo sin unidades por bloque.
    IF COALESCE(v_promo.unidades_por_bloque, 0) > 0 THEN
      SELECT string_agg(pr.nombre, ', ' ORDER BY pr.nombre) INTO v_nombre
        FROM unnest(v_prod) AS r(producto_id)
        JOIN productos pr ON pr.id = r.producto_id AND pr.sucursal_id = v_sucursal
       WHERE r.producto_id IS DISTINCT FROM v_item.producto_id
         AND public.contenedor_de_barra(v_item.promocion_id, r.producto_id, v_sucursal, r.producto_id)
             IS DISTINCT FROM v_promo.ajuste_producto_id
         AND (SELECT pc.unidades_por_bulto FROM productos pc
               WHERE pc.id = public.contenedor_de_barra(v_item.promocion_id, r.producto_id,
                                                        v_sucursal, r.producto_id)
                 AND pc.sucursal_id = v_sucursal) IS NULL;
      IF v_nombre IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
          'Para regalar ' || v_nombre
          || ' hay que cargar en su ficha cuántas unidades sueltas trae cada unidad de stock (unidades por bulto)');
      END IF;
    END IF;
$r$),
-- 3 · promos-B3: al menos un producto
(3, 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)', 'al menos un producto',
$a$        FROM jsonb_array_elements(p_datos->'producto_ids') e;
      IF (SELECT count(*) FROM productos WHERE sucursal_id = v_sucursal AND id = ANY (v_prod_ids))
$a$,
$r$        FROM jsonb_array_elements(p_datos->'producto_ids') e;
      -- promos-B3 (tanda 6 de #1603): lo que pide el alta (crear_promocion). Con una lista
      -- vacía la edición le borraba todos los productos.
      IF cardinality(v_prod_ids) = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Elegí al menos un producto para la promoción');
      END IF;
      IF (SELECT count(*) FROM productos WHERE sucursal_id = v_sucursal AND id = ANY (v_prod_ids))
$r$),
-- 3 · promos-B3: las dos reglas, y el contenedor y el factor con ajuste automático
(4, 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)', 'las reglas y la fracción',
$a$        RETURN jsonb_build_object('success', false, 'error', 'Una regla de la promoción está repetida');
      END IF;
    END IF;
$a$,
$r$        RETURN jsonb_build_object('success', false, 'error', 'Una regla de la promoción está repetida');
      END IF;
      -- promos-B3 (tanda 6 de #1603): lo que pide el alta. Con `reglas: []` la edición le
      -- borraba las reglas.
      IF NOT (v_claves @> ARRAY['cantidad_compra', 'cantidad_bonificacion']) THEN
        RETURN jsonb_build_object('success', false, 'error', 'La promoción necesita la cantidad de compra y la de bonificación');
      END IF;
    END IF;
    -- promos-B3: con ajuste automático (fracción), la descripción del regalo, el contenedor y
    -- las unidades por bloque; sin él (unidad entera), el producto de regalo. Como en el alta:
    -- lo que manda el formulario o, si no lo manda, lo que la promo tiene.
    IF NOT v_ajuste AND p_producto_regalo_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Elegí el producto de regalo');
    END IF;
    IF v_ajuste THEN
      IF (CASE WHEN p_datos ? 'descripcion_regalo' THEN NULLIF(btrim(COALESCE(p_datos->>'descripcion_regalo', '')), '')
               ELSE (SELECT NULLIF(btrim(COALESCE(pr.descripcion_regalo, '')), '') FROM promociones pr
                      WHERE pr.id = p_promocion_id AND pr.sucursal_id = v_sucursal) END) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Escribí una descripción del regalo (ej: "1 botella Manaos Naranja 600cc")');
      END IF;
      IF p_ajuste_producto_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Elegí el producto del que se descuenta el stock (el contenedor)');
      END IF;
      IF (CASE WHEN p_datos ? 'unidades_por_bloque' THEN NULLIF(p_datos->>'unidades_por_bloque', '')
               ELSE (SELECT pr.unidades_por_bloque::text FROM promociones pr
                      WHERE pr.id = p_promocion_id AND pr.sucursal_id = v_sucursal) END) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Ingresá cuántas subunidades forman una unidad del producto contenedor');
      END IF;
    END IF;
$r$),
-- 4 · promos-B6: el regalo de una promo apagada no crece
(9, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'las declaraciones',
$a$  v_par      jsonb;
$a$,
$r$  v_par      jsonb;
  -- promos-B6 (tanda 6 de #1603): lo que el pedido ya tenía de regalo de la promo, en cortes.
  v_conservado int;
$r$),
(5, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'la promo apagada no crece',
$a$    v_tope := public.regalo_tope_promo(v_cant, r.productos, r.compra, r.bonif);
    IF v_suma > v_tope THEN
$a$,
$r$    v_tope := public.regalo_tope_promo(v_cant, r.productos, r.compra, r.bonif);
    -- promos-B6 (tanda 6 de #1603), decisión del dueño (24/11): el regalo de una promo que
    -- ya no rige (la exención de 2b) se conserva pero no crece. V×10 + R×4 con la promo
    -- apagada, editado a V×20, sigue con R×4 (no R×8); bajar la venta lo recorta como siempre
    -- (el tope de las reglas). Lo guardado se mide en cortes, la unidad de la promo.
    IF p_pedido_id IS NOT NULL
       AND NOT (COALESCE(r.activo, false)
                AND ((r.fecha_inicio <= v_d AND (r.fecha_fin IS NULL OR r.fecha_fin >= v_d))
                  OR (r.fecha_inicio <= v_hoy AND (r.fecha_fin IS NULL OR r.fecha_fin >= v_hoy)))) THEN
      SELECT floor(COALESCE(SUM(COALESCE(pi.regalo_corte, pi.cantidad)), 0))::int INTO v_conservado
        FROM pedido_items pi
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
         AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = v_promo.id;
      IF v_suma > LEAST(v_tope, v_conservado) THEN
        RETURN format('La promo "%s" ya no rige: el pedido conserva su regalo (%s), pero no puede crecer (vinieron %s). Dejá el regalo como estaba o bajalo.',
                      r.nombre, LEAST(v_tope, v_conservado), v_suma);
      END IF;
    END IF;
    IF v_suma > v_tope THEN
$r$),
-- 5 · promos-B2: el regalo de referencia del tope es el que daba la promo cuando nació el pedido
(6, 'public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'las declaraciones',
$a$BEGIN
  por_linea := COALESCE(public._regalo_modo_del_pedido(p_pedido_id, p_promocion_id, p_sucursal_id), true);
$a$,
$r$DECLARE
  -- promos-B2 (tanda 6 de #1603): cuándo nació el pedido, y el regalo y el contenedor de la
  -- promo en ese momento.
  v_nacio   timestamptz;
  v_regalo  bigint;
  v_cont    bigint;
  v_viejo   bigint;
  v_precio  numeric;
BEGIN
  por_linea := COALESCE(public._regalo_modo_del_pedido(p_pedido_id, p_promocion_id, p_sucursal_id), true);
$r$),
(7, 'public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'el regalo de cuando nació el pedido',
$a$  SELECT COALESCE(p.producto_regalo_id, p.ajuste_producto_id) INTO producto_id
    FROM promociones p WHERE p.id = p_promocion_id AND p.sucursal_id = p_sucursal_id;
$a$,
$r$  SELECT COALESCE(p.producto_regalo_id, p.ajuste_producto_id) INTO producto_id
    FROM promociones p WHERE p.id = p_promocion_id AND p.sucursal_id = p_sucursal_id;
  -- promos-B2 (tanda 6 de #1603), decisión del dueño (24/11): el tope se mide contra el
  -- regalo DEL PEDIDO, lo que daba la promo y lo que valía cuando el pedido nació, no
  -- contra el de hoy: si el admin cambió el regalo de la promo (un caramelo de $ 5 por un
  -- perfume de $ 500), el pedido de antes sigue topeado en $ 5. La hora es la del alta
  -- (`pedidos.created_at`), no la de la foto: cada edición reinserta las líneas y renueva
  -- `pedido_promo_reglas.tomada_at` (H1 de la lente de la tanda 6). `audit_logs.old_data`
  -- trae sólo las columnas que cambiaron (H2): cada una sale del primer cambio posterior que
  -- la trae, y la que ningún cambio trae, de la fila de hoy. Lo mismo con el precio de lista,
  -- abajo. «>=»: la fila de audit_logs lleva el now() de su transacción, y el alta no cambia
  -- ni la promo ni el precio de lista. Un pedido rehecho por un cambio de cliente nace de
  -- nuevo en ese momento.
  SELECT pe.created_at INTO v_nacio
    FROM pedidos pe WHERE pe.id = p_pedido_id AND pe.sucursal_id = p_sucursal_id;
  IF v_nacio IS NOT NULL THEN
    SELECT p.producto_regalo_id, p.ajuste_producto_id INTO v_regalo, v_cont
      FROM promociones p WHERE p.id = p_promocion_id AND p.sucursal_id = p_sucursal_id;
    SELECT NULLIF(a.old_data->>'producto_regalo_id', '')::bigint INTO v_viejo
      FROM audit_logs a
     WHERE a.tabla = 'promociones' AND a.registro_id = p_promocion_id::text AND a.accion = 'UPDATE'
       AND a.old_data ? 'producto_regalo_id' AND a.created_at >= v_nacio
     ORDER BY a.created_at, a.id
     LIMIT 1;
    IF FOUND THEN
      v_regalo := v_viejo;
    END IF;
    SELECT NULLIF(a.old_data->>'ajuste_producto_id', '')::bigint INTO v_viejo
      FROM audit_logs a
     WHERE a.tabla = 'promociones' AND a.registro_id = p_promocion_id::text AND a.accion = 'UPDATE'
       AND a.old_data ? 'ajuste_producto_id' AND a.created_at >= v_nacio
     ORDER BY a.created_at, a.id
     LIMIT 1;
    IF FOUND THEN
      v_cont := v_viejo;
    END IF;
    producto_id := COALESCE(v_regalo, v_cont);
  END IF;
$r$),
(8, 'public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'el precio de cuando nació el pedido',
$a$  SELECT pr.precio INTO precio FROM productos pr WHERE pr.id = producto_id AND pr.sucursal_id = p_sucursal_id;
$a$,
$r$  SELECT pr.precio INTO precio FROM productos pr WHERE pr.id = producto_id AND pr.sucursal_id = p_sucursal_id;
  -- promos-B2: lo que valía el regalo cuando nació el pedido.
  IF v_nacio IS NOT NULL AND producto_id IS NOT NULL THEN
    SELECT NULLIF(a.old_data->>'precio', '')::numeric INTO v_precio
      FROM audit_logs a
     WHERE a.tabla = 'productos' AND a.registro_id = producto_id::text AND a.accion = 'UPDATE'
       AND a.old_data ? 'precio' AND a.created_at >= v_nacio
     ORDER BY a.created_at, a.id
     LIMIT 1;
    IF FOUND THEN
      precio := v_precio;
    END IF;
  END IF;
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
  FOR f IN SELECT DISTINCT fn FROM t6b_tramos ORDER BY 1 LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    FOR r IN SELECT * FROM t6b_tramos WHERE fn = f ORDER BY ord LOOP
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

-- =========================================================================
-- 5 · promos-B2: el regalo de referencia de una línea, para la pantalla
-- =========================================================================
-- La pantalla de cambiar el regalo (ModalSustituirRegalo) sugiere y topea con la misma
-- cuenta que el server. El regalo de referencia sale ahora de la foto del pedido (por
-- audit_logs, que la pantalla no lee): se lo da esta RPC, a quien puede sustituir (admin
-- y encargado) y de su sucursal, como regalo_corte_de_linea. NULL si no corresponde.
CREATE FUNCTION public.regalo_referencia_de_linea(p_pedido_item_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_item record;
  v_r    record;
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RETURN NULL;
  END IF;
  SELECT pi.pedido_id, pi.promocion_id, pi.sucursal_id, pi.regalo_cadena_id, pi.producto_id,
         COALESCE(pi.regalo_corte, pi.cantidad) AS corte
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.sucursal_id = public.current_sucursal_id()
     AND COALESCE(pi.es_bonificacion, false)
     AND pi.promocion_id IS NOT NULL;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_r
    FROM public._regalo_de_la_promo(v_item.pedido_id, v_item.promocion_id, v_item.sucursal_id,
                                    v_item.regalo_cadena_id, v_item.producto_id, v_item.corte);
  RETURN jsonb_build_object('producto_id', v_r.producto_id, 'precio', v_r.precio, 'factor', v_r.factor);
END
$function$;

REVOKE ALL ON FUNCTION public.regalo_referencia_de_linea(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.regalo_referencia_de_linea(bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos nuevos son los del repo, el resto de cada cuerpo no
-- cambió (deshaciendo sus tramos vuelve el md5 de la premisa), y el definer, el
-- search_path y los EXECUTE son los de antes. La función nueva, sus EXECUTE y su
-- trigger, como dice este archivo.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text;
  r     record;
  t     record;
  x     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
     '2dcd9a227395213d785e1bc42d648973', '9fcf5264eb15043ce24b91b4c69e5ae7',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)',
     '6153913e3e7f63f2d7d3fce5791b7979', '8b084f84c9847ffb8960585b30407ed5',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)',
     '6c2eac9df3f7375aad69fbbc7c9ef341', '500ca25bc79a22ac9355feaca0e20733',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)',
     '7a5d67c746a4d5bb67b8d313d13584be', '29f0aa33fd68e34746cb959550f6212f',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)',
     '0ed07e72b5d047e60695d13bfae3d312', 'bd3354c71bc4b681173f97dd1b009b69',
     '{postgres=X/postgres,service_role=X/postgres}', false)
  ) AS v(fn, h, h_antes, acl, def) LOOP
    SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
    v_src := x.prosrc;
    FOR t IN SELECT * FROM t6b_tramos WHERE fn = r.fn ORDER BY ord DESC LOOP
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
    FROM pg_proc WHERE oid = 'public.promo_tipo_con_bloques_vivos()'::regprocedure;
  IF x.h IS DISTINCT FROM 'fb8f6b4b719de7010d16ea5eba4af07a'
     OR x.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}'
     OR NOT x.def OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
    RAISE EXCEPTION 'mig NNN · promo_tipo_con_bloques_vivos() no quedó como en el repo (md5 %, acl %, definer %, config %)', x.h, x.a, x.def, x.cfg;
  END IF;
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
    FROM pg_proc WHERE oid = 'public.regalo_referencia_de_linea(bigint)'::regprocedure;
  IF x.h IS DISTINCT FROM '30da8b84df8f6cd5c5394ed227a3fb3e'
     OR x.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
     OR NOT x.def OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
    RAISE EXCEPTION 'mig NNN · regalo_referencia_de_linea(bigint) no quedó como en el repo (md5 %, acl %, definer %, config %)', x.h, x.a, x.def, x.cfg;
  END IF;
  IF (SELECT pg_get_triggerdef(tg.oid) FROM pg_trigger tg
       WHERE tg.tgrelid = 'public.promociones'::regclass AND tg.tgname = 'trg_promo_tipo_con_bloques_vivos')
     IS DISTINCT FROM 'CREATE TRIGGER trg_promo_tipo_con_bloques_vivos BEFORE UPDATE OF regalo_mueve_stock ON public.promociones FOR EACH ROW WHEN (((old.regalo_mueve_stock IS FALSE) AND (new.regalo_mueve_stock IS TRUE))) EXECUTE FUNCTION promo_tipo_con_bloques_vivos()' THEN
    RAISE EXCEPTION 'mig NNN · el trigger trg_promo_tipo_con_bloques_vivos no quedó como en el repo';
  END IF;
END
$post$;

COMMIT;
