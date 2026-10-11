-- El reparto se mide en su raiz (#1090) y el reparto del alta se registra (#1091)
--
-- #1090: un reparto de regalo se conservaba al editar solo si la SUMA DE SUS
-- LINEAS era lo que da la promo (loop de la mig 275 en actualizar_pedido_items
-- y su espejo conservarRepartos en el front). Si una parte se cambia por
-- valor, su cantidad pasa a estar en la unidad del sustituto y la suma deja de
-- coincidir: la promo da 4, se reparte en X2 + Y2, la parte Y pasa a Z (2 -> 4,
-- otra categoria) y vuelve a Y (4 -> 3). Las partes suman 5 y en la proxima
-- edicion -- aunque sea de la fecha o de una nota -- el reparto se disolvia en
-- X4 sin cadena (en modo A, moviendo stock).
-- Decision del dueño (2026-10-10, opcion A): cada linea aporta su CANTIDAD DE
-- CORTE, la de la raiz de su clave: la fila de reparto da cantidad_sustituta y
-- un eslabon comun da cantidad_original (sin clave, o sin eslabones, su
-- cantidad). El reparto vive mientras la suma de los cortes sea lo que da la
-- promo. Lo calcula regalo_cantidad_base (nueva, de servidor) y su espejo
-- cantidadBaseDeLinea (src/utils/repartoRegalo.ts), con el gate de paridad
-- cadenaSustitucion.espejo.json. El precio de la opcion A: tres guardas en
-- dividir_regalo_pedido para que los cortes de un reparto anidado sigan en
-- unidades de la promo -- no se reparte una linea convertida por valor, ni una
-- parte de un reparto cuya cantidad ya no es su corte, ni una linea suelta a
-- la que se le cambio la cantidad a mano --.
--
-- #1091: crear_pedido_completo aceptaba varias lineas de regalo de una promo
-- (el reparto que elige el admin al cargar) sin dejar ninguna fila de reparto,
-- asi que regalo_elemento_con_cadena no las reconocia como reparto: si la
-- promo se caia y volvia, heredaba la clave de UNA parte (Y -> Z en k1) y la
-- promo entera pasaba a Z. Decision del dueño (opcion a): el alta registra el
-- reparto -- cada parte nace con su clave y una fila de reparto, como las de
-- dividir_regalo_pedido --. Todo lo que ya mira reparto_id lo reconoce sin
-- cambios. La restriccion de rol del alta con reparto va en un issue aparte.
--
-- Y PROMO-B de auditoria_integridad() deja de contar filas de reparto y
-- eslabones de cadenas sin linea viva: actualizar_pedido_items etiqueta sus
-- bajadas 'pedido_creado', asi que disolver un reparto del alta (o no heredar
-- la clave al volver la promo) lo ponia en rojo sin ningun bug. Sigue
-- detectando el bug de la 252: una cadena viva cuya linea quedo en el original.
--
-- Va DESPUES de 349_la_edicion_conserva_la_huella (#1094/#1097), que tambien
-- reescribe actualizar_pedido_items y dividir_regalo_pedido: los parches son
-- por ancla sobre pg_get_functiondef (cada fragmento tiene que aparecer
-- exactamente una vez o la migracion aborta) y ninguno toca lo que cambia
-- aquella. No mueven stock, ni GUCs, ni costo_unitario_al_crear (STK-F, STK-D
-- y COSTO-D iguales). Firmas, SECURITY DEFINER y GRANTs: como estaban.

-- ---------------------------------------------------------------------------
-- 0 - Foto de auditoria_integridad() antes de tocar nada (se compara al final)
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE rr_foto_auditoria ON COMMIT DROP AS
SELECT x->>'id' AS id, x->>'severidad' AS severidad, (x->>'ok')::boolean AS ok,
       COALESCE((x->>'violaciones')::numeric, 0) AS violaciones
  FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x;

-- ---------------------------------------------------------------------------
-- 1 - La cantidad de corte (#1090)
-- ---------------------------------------------------------------------------

-- regalo_eslabones suma las dos cantidades de cada eslabon. Los consumidores
-- (regalo_cadena_pasos, regalo_raiz_de_eslabones, regalo_raiz_descrita)
-- ignoran las claves de mas. Misma firma: conserva el ACL (postgres y
-- service_role).
CREATE OR REPLACE FUNCTION public.regalo_eslabones(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', s.id,
           'producto_original_id', s.producto_original_id,
           'producto_sustituto_id', s.producto_sustituto_id,
           'reparto_id', s.reparto_id,
           'cadena_id', s.cadena_id,
           'producto_raiz_id', s.producto_raiz_id,
           -- mig #1090: para la cantidad de corte (regalo_cantidad_base).
           'cantidad_original', s.cantidad_original,
           'cantidad_sustituta', s.cantidad_sustituta) ORDER BY s.id), '[]'::jsonb)
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id;
$function$;

-- La cantidad de una linea de regalo en la unidad de la raiz de su clave: lo
-- que la linea "vale" contra la promo. Sin clave, o con una clave sin
-- eslabones, su cantidad. Si la clave tiene una fila de reparto, la
-- cantidad_sustituta de la ultima (la parte que le toco en el reparto: lo
-- anterior ya no vale, mig 275). Si no, la cantidad_original de su primer
-- eslabon (la que tenia la linea antes de su primer cambio). Cada clave nace
-- en sustituir (primer cambio), en dividir o en el alta con reparto, asi que
-- la fila de reparto, si existe, es la primera; tomar la ultima solo importa
-- para datos anteriores a la 338.
-- Espejo EXACTO: cantidadBaseDeLinea (src/utils/repartoRegalo.ts), gate de
-- paridad cadenaSustitucion.espejo.json (campos cantidad y base).
-- No mueve stock: SECURITY INVOKER. Es de servidor (la llaman
-- actualizar_pedido_items, dividir_regalo_pedido y el gate con service_role).
CREATE OR REPLACE FUNCTION public.regalo_cantidad_base(p_eslabones jsonb, p_cadena uuid, p_cantidad numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  WITH e AS (
    SELECT x, (x->>'id')::bigint AS id
      FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) x
     WHERE p_cadena IS NOT NULL AND (x->>'cadena_id')::uuid = p_cadena
  )
  SELECT CASE
           WHEN p_cadena IS NULL OR NOT EXISTS (SELECT 1 FROM e) THEN p_cantidad
           WHEN EXISTS (SELECT 1 FROM e WHERE x->>'reparto_id' IS NOT NULL)
             THEN (SELECT (x->>'cantidad_sustituta')::numeric FROM e
                    WHERE x->>'reparto_id' IS NOT NULL ORDER BY id DESC LIMIT 1)
           ELSE (SELECT (x->>'cantidad_original')::numeric FROM e ORDER BY id LIMIT 1)
         END;
$function$;

REVOKE ALL ON FUNCTION public.regalo_cantidad_base(jsonb, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_cantidad_base(jsonb, uuid, numeric) TO service_role;

-- ---------------------------------------------------------------------------
-- 2 - Parches
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- 2a · actualizar_pedido_items: el loop de la 275 mide en cortes (#1090)
DO $actualizar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  -- mig 275 (#831): un regalo repartido en varios sabores sobrevive a la
$q$,
$q$  -- mig #1090: el total del reparto es la suma de las CANTIDADES DE CORTE de
  -- sus lineas (regalo_cantidad_base: la de la raiz de la clave de cada
  -- parte), no la suma de las lineas. Una parte cambiada por valor queda en la
  -- unidad del sustituto, y con la suma de lineas el reparto se disolvia en
  -- cualquier guardado. Un bundle viejo (manda la promo en una linea) y el
  -- front nuevo (manda el corte de cada parte) suman lo mismo.
  -- mig 275 (#831): un regalo repartido en varios sabores sobrevive a la
$q$, 'actualizar comentario');

  v_def := pg_temp.rr_parchar(v_def,
$q$           SUM(pi.cantidad)::INT AS total,
$q$,
$q$           SUM(public.regalo_cantidad_base(
                 public.regalo_eslabones(p_pedido_id, pi.promocion_id, v_sucursal),
                 pi.regalo_cadena_id, pi.cantidad)) AS total,
$q$, 'actualizar total');

  EXECUTE v_def;
END
$actualizar$;

-- 2b · dividir_regalo_pedido: tres guardas (#1090)
DO $dividir$
DECLARE
  v_def text := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  IF v_suma <> v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error',
      'La suma de las partes (' || v_suma || ') tiene que ser igual a la cantidad del regalo (' || v_item.cantidad || ')');
  END IF;
$q$,
$q$  IF v_suma <> v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error',
      'La suma de las partes (' || v_suma || ') tiene que ser igual a la cantidad del regalo (' || v_item.cantidad || ')');
  END IF;
  -- mig #1090: los cortes de un reparto tienen que quedar en unidades de la
  -- promo (el reparto se conserva al editar si la suma de los cortes es lo que
  -- da la promo). Sin mover nada todavia: {success:false} sin RAISE.
  -- (a) Una linea convertida por valor: recorrer su cadena desde la raiz con
  --     su cantidad no da su cantidad, asi que no esta en la unidad de la raiz.
  IF v_item.regalo_cadena_id IS NOT NULL
     AND (SELECT r.cantidad
            FROM public.regalo_sustitucion_resuelta(
                   v_item.pedido_id, v_item.promocion_id,
                   COALESCE(public.regalo_raiz_cadena(v_item.pedido_id, v_item.promocion_id, v_item.producto_id,
                                                      v_sucursal, v_item.regalo_cadena_id),
                            v_item.producto_id),
                   v_sucursal, v_item.cantidad, v_item.regalo_cadena_id) r)
         IS DISTINCT FROM v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este regalo ya se cambió por valor y su cantidad no está en la unidad de la promo: repartilo antes de cambiarlo por valor.');
  END IF;
  -- (b) Una parte de un reparto cuya cantidad ya no es su corte: sustituir
  --     acepta el mismo producto, o uno de la misma categoria, con cualquier
  --     cantidad, y ahi (a) no lo ve.
  IF EXISTS (SELECT 1 FROM pedido_item_sustituciones s
              WHERE s.pedido_id = v_item.pedido_id AND s.promocion_id = v_item.promocion_id
                AND s.sucursal_id = v_sucursal AND s.cadena_id = v_item.regalo_cadena_id
                AND s.reparto_id IS NOT NULL)
     AND public.regalo_cantidad_base(public.regalo_eslabones(v_item.pedido_id, v_item.promocion_id, v_sucursal),
                                     v_item.regalo_cadena_id, v_item.cantidad) <> v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Esta parte del reparto ya cambió de cantidad: para repartirla de nuevo, primero volvela a su cantidad (o rehacé el reparto desde el regalo completo).');
  END IF;
  -- (c) Una linea suelta a la que se le cambio la cantidad a mano (A4 -> B6 en
  --     la misma categoria): ni (a) la ve -- en la misma categoria el
  --     recorrido deja la cantidad como esta -- ni (b), que mira solo partes.
  --     Repartirla dejaria cortes que suman 6 contra una promo de 4 y el
  --     reparto se disolveria en el primer guardado. Se la reconoce porque su
  --     cantidad es la de recorrer la cadena desde su corte (el 4 vuelve 6).
  --     Si en cambio la promo paso despues de 4 a 5 (A4 -> B4 y la edicion la
  --     deja en B5), el corte sigue en 4 pero recorrerlo da B4 y no B5: la
  --     linea esta en la unidad de la promo y pasa. Rechazo de mas solo si la
  --     promo cambio justo a la cantidad tipeada a mano.
  IF v_item.regalo_cadena_id IS NOT NULL
     AND public.regalo_cantidad_base(public.regalo_eslabones(v_item.pedido_id, v_item.promocion_id, v_sucursal),
                                     v_item.regalo_cadena_id, v_item.cantidad) <> v_item.cantidad
     AND (SELECT r.cantidad
            FROM public.regalo_sustitucion_resuelta(
                   v_item.pedido_id, v_item.promocion_id,
                   COALESCE(public.regalo_raiz_cadena(v_item.pedido_id, v_item.promocion_id, v_item.producto_id,
                                                      v_sucursal, v_item.regalo_cadena_id),
                            v_item.producto_id),
                   v_sucursal,
                   public.regalo_cantidad_base(public.regalo_eslabones(v_item.pedido_id, v_item.promocion_id, v_sucursal),
                                               v_item.regalo_cadena_id, v_item.cantidad),
                   v_item.regalo_cadena_id) r) = v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error',
      'A este regalo ya se le cambió la cantidad (la promo daba ' ||
      public.regalo_cantidad_base(public.regalo_eslabones(v_item.pedido_id, v_item.promocion_id, v_sucursal),
                                  v_item.regalo_cadena_id, v_item.cantidad) ||
      '): para repartirlo, primero volvelo a esa cantidad. Si querés repartir y cambiar la cantidad, repartí primero.');
  END IF;
$q$, 'dividir guardas');

  EXECUTE v_def;
END
$dividir$;

-- 2c · crear_pedido_completo: el reparto del alta se registra (#1091)
DO $crear$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  v_omitir_minimo_previo TEXT;
BEGIN
$q$,
$q$  v_omitir_minimo_previo TEXT;
  -- mig #1091: las promos con 2 o mas lineas de regalo (un reparto del alta),
  -- la clave de cada parte y sus datos para la fila de reparto.
  v_promos_reparto BIGINT[] := '{}';
  v_cadena_alta UUID;
  v_partes_alta JSONB := '[]'::JSONB;
  v_reparto_alta RECORD;
BEGIN
$q$, 'crear declare');

  v_def := pg_temp.rr_parchar(v_def,
$q$  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
$q$,
$q$  -- mig #1091: un reparto del alta es una promo con varias lineas de regalo.
  SELECT COALESCE(array_agg(t.promo), '{}') INTO v_promos_reparto
    FROM (SELECT (e->>'promocion_id')::BIGINT AS promo
            FROM jsonb_array_elements(p_items) e
           WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
             AND NULLIF(e->>'promocion_id', '') IS NOT NULL
           GROUP BY 1
          HAVING count(*) > 1) t;

  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
$q$, 'crear promos');

  v_def := pg_temp.rr_parchar(v_def,
$q$    v_regalo_default_id := NULL;
$q$,
$q$    v_regalo_default_id := NULL;
    -- mig #1091: cada parte de un reparto del alta nace con su propia clave
    -- (la decide el server). Sin eslabones todavia: el trigger de pre-insert
    -- no hace nada con ella.
    v_cadena_alta := CASE WHEN v_es_bonificacion AND v_promocion_id IS NOT NULL
                               AND v_promocion_id = ANY(v_promos_reparto)
                          THEN gen_random_uuid() END;
$q$, 'crear clave');

  v_def := pg_temp.rr_parchar(v_def,
$q$      origen_precio
    ) VALUES ($q$,
$q$      origen_precio, regalo_cadena_id
    ) VALUES ($q$, 'crear insert columnas');

  v_def := pg_temp.rr_parchar(v_def,
$q$      CASE WHEN v_tipo_factura = 'VB' THEN 'costo_interno' END
    ) RETURNING id INTO v_item_id;
$q$,
$q$      CASE WHEN v_tipo_factura = 'VB' THEN 'costo_interno' END, v_cadena_alta
    ) RETURNING id INTO v_item_id;

    IF v_cadena_alta IS NOT NULL THEN
      v_partes_alta := v_partes_alta || jsonb_build_object(
        'item', v_item_id, 'promo', v_promocion_id, 'producto', v_producto_id,
        'cantidad', v_cantidad, 'cadena', v_cadena_alta);
    END IF;
$q$, 'crear insert valores');

  v_def := pg_temp.rr_parchar(v_def,
$q$  IF v_tipo_factura = 'VB' THEN
    PERFORM set_config('app.omitir_minimo_venta', COALESCE(v_omitir_minimo_previo, ''), true);
$q$,
$q$  -- mig #1091: las filas del reparto del alta, una por parte y con el mismo
  -- reparto_id, como las de dividir_regalo_pedido: el original es el regalo
  -- default de la promo y su cantidad la suma de las partes; cada parte
  -- describe su propio producto (producto_raiz_id). Despues de bajar el stock:
  -- la tabla no tiene triggers, asi que el GUC vivo no le hace nada.
  FOR v_reparto_alta IN
    SELECT (x->>'promo')::BIGINT AS promo, gen_random_uuid() AS reparto,
           SUM((x->>'cantidad')::NUMERIC) AS total,
           (array_agg((x->>'producto')::BIGINT ORDER BY o))[1] AS primero
      FROM jsonb_array_elements(v_partes_alta) WITH ORDINALITY AS t(x, o)
     GROUP BY 1
     ORDER BY 1
  LOOP
    INSERT INTO pedido_item_sustituciones (
      pedido_id, pedido_item_id, promocion_id, producto_original_id, producto_sustituto_id,
      cantidad_original, cantidad_sustituta, regalo_mueve_stock_snapshot, ajuste_producto_id_nuevo,
      motivo, autorizado_por, sucursal_id, reparto_id, cadena_id, producto_raiz_id
    )
    SELECT v_pedido_id, (t.x->>'item')::BIGINT, v_reparto_alta.promo,
           COALESCE(pr.producto_regalo_id, v_reparto_alta.primero), (t.x->>'producto')::BIGINT,
           v_reparto_alta.total, (t.x->>'cantidad')::NUMERIC, COALESCE(pr.regalo_mueve_stock, FALSE),
           CASE WHEN COALESCE(pr.regalo_mueve_stock, FALSE) THEN NULL
                WHEN (t.x->>'producto')::BIGINT = pr.producto_regalo_id THEN pr.ajuste_producto_id
                ELSE (t.x->>'producto')::BIGINT END,
           'Reparto al cargar el pedido', p_usuario_id, v_sucursal, v_reparto_alta.reparto,
           (t.x->>'cadena')::UUID, (t.x->>'producto')::BIGINT
      FROM jsonb_array_elements(v_partes_alta) WITH ORDINALITY AS t(x, o)
      LEFT JOIN promociones pr ON pr.id = v_reparto_alta.promo AND pr.sucursal_id = v_sucursal
     WHERE (t.x->>'promo')::BIGINT = v_reparto_alta.promo
     ORDER BY t.o;
  END LOOP;

  IF v_tipo_factura = 'VB' THEN
    PERFORM set_config('app.omitir_minimo_venta', COALESCE(v_omitir_minimo_previo, ''), true);
$q$, 'crear filas de reparto');

  EXECUTE v_def;
END
$crear$;

-- 2d · auditoria_integridad: PROMO-B no cuenta repartos ni cadenas sin linea
DO $auditoria$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$        WHERE COALESCE(s.regalo_mueve_stock_snapshot, false)
          AND s.producto_original_id <> s.producto_sustituto_id
$q$,
$q$        WHERE COALESCE(s.regalo_mueve_stock_snapshot, false)
          AND s.producto_original_id <> s.producto_sustituto_id
          -- mig #1090/#1091: una fila de reparto no es un cambio del regalo
          -- de una linea, y un eslabon de una cadena sin linea viva (el
          -- reparto se disolvio, o la promo volvio sin heredar la clave) ya
          -- no describe nada del pedido.
          AND s.reparto_id IS NULL
          AND EXISTS (SELECT 1 FROM pedido_items pi
                       WHERE pi.pedido_id = s.pedido_id AND pi.sucursal_id = s.sucursal_id
                         AND pi.regalo_cadena_id = s.cadena_id)
$q$, 'auditoria PROMO-B');

  EXECUTE v_def;
END
$auditoria$;

DROP FUNCTION pg_temp.rr_parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- 3 - Backfill: los repartos del alta cargados antes de esta migracion
-- ---------------------------------------------------------------------------
-- Un (pedido abierto, promo) con 2 o mas lineas de regalo y ninguna fila de
-- reparto: cada linea sin clave recibe una nueva y se insertan sus filas con
-- las reglas del alta. Si alguna linea ya tiene eslabones comunes en su clave
-- no hay forma de saber que corte le toca: se aborta para resolverlo a mano.
-- No toca stock. La funcion queda en pg_temp para que el ensayo (E6) la
-- vuelva a correr sobre un pedido sintetico.

CREATE OR REPLACE FUNCTION pg_temp.rr_backfill(p_pedido bigint)
RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
  g         record;
  v_reparto uuid;
  v_n       int := 0;
BEGIN
  FOR g IN
    SELECT pi.pedido_id, pi.promocion_id, pi.sucursal_id,
           COALESCE(p.usuario_id, p.creado_por) AS autor,
           array_agg(pi.id ORDER BY pi.id) AS items,
           SUM(pi.cantidad) AS total,
           (array_agg(pi.producto_id ORDER BY pi.id))[1] AS primero
      FROM public.pedido_items pi
      JOIN public.pedidos p ON p.id = pi.pedido_id AND p.sucursal_id = pi.sucursal_id
     WHERE COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
       AND p.estado NOT IN ('entregado', 'cancelado', 'anulado')
       AND (p_pedido IS NULL OR pi.pedido_id = p_pedido)
     GROUP BY pi.pedido_id, pi.promocion_id, pi.sucursal_id, COALESCE(p.usuario_id, p.creado_por)
    HAVING count(*) > 1
       AND NOT EXISTS (SELECT 1 FROM public.pedido_item_sustituciones s
                        WHERE s.pedido_id = pi.pedido_id AND s.promocion_id = pi.promocion_id
                          AND s.sucursal_id = pi.sucursal_id AND s.reparto_id IS NOT NULL)
     ORDER BY pi.pedido_id, pi.promocion_id
  LOOP
    IF EXISTS (SELECT 1 FROM public.pedido_items pi
                 JOIN public.pedido_item_sustituciones s
                   ON s.pedido_id = pi.pedido_id AND s.sucursal_id = pi.sucursal_id
                  AND s.cadena_id = pi.regalo_cadena_id
                WHERE pi.id = ANY(g.items)) THEN
      RAISE EXCEPTION 'backfill #1091: el pedido % tiene la promo % en varias lineas y alguna ya tiene cambios de regalo: resolverlo a mano antes de aplicar',
        g.pedido_id, g.promocion_id;
    END IF;
    v_reparto := gen_random_uuid();
    UPDATE public.pedido_items SET regalo_cadena_id = gen_random_uuid()
     WHERE id = ANY(g.items) AND regalo_cadena_id IS NULL;
    INSERT INTO public.pedido_item_sustituciones (
      pedido_id, pedido_item_id, promocion_id, producto_original_id, producto_sustituto_id,
      cantidad_original, cantidad_sustituta, regalo_mueve_stock_snapshot, ajuste_producto_id_nuevo,
      motivo, autorizado_por, sucursal_id, reparto_id, cadena_id, producto_raiz_id
    )
    SELECT pi.pedido_id, pi.id, pi.promocion_id, COALESCE(pr.producto_regalo_id, g.primero), pi.producto_id,
           g.total, pi.cantidad, COALESCE(pr.regalo_mueve_stock, FALSE),
           CASE WHEN COALESCE(pr.regalo_mueve_stock, FALSE) THEN NULL
                WHEN pi.producto_id = pr.producto_regalo_id THEN pr.ajuste_producto_id
                ELSE pi.producto_id END,
           'Reparto al cargar el pedido (backfill)', g.autor, pi.sucursal_id, v_reparto,
           pi.regalo_cadena_id, pi.producto_id
      FROM public.pedido_items pi
      LEFT JOIN public.promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.id = ANY(g.items)
     ORDER BY pi.id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$fn$;

DO $backfill$
DECLARE
  v_n int := pg_temp.rr_backfill(NULL);
BEGIN
  RAISE NOTICE 'backfill #1091: % repartos del alta registrados', v_n;
END
$backfill$;

-- ---------------------------------------------------------------------------
-- 4 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_act  text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  v_div  text := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
  v_cre  text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
  v_aud  text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_esl  text := pg_get_functiondef('public.regalo_eslabones(bigint,bigint,bigint)'::regprocedure);
  f      text;
  r      record;
BEGIN
  IF v_act NOT LIKE '%SUM(public.regalo_cantidad_base(%' OR v_act LIKE '%SUM(pi.cantidad)::INT AS total,%'
     -- lo de #1097 sigue ahi
     OR v_act NOT LIKE '%_rehacer_huella_lineas(v_foto, v_lineas_stock)%' THEN
    RAISE EXCEPTION 'actualizar_pedido_items no quedo como se esperaba';
  END IF;
  IF v_div NOT LIKE '%ya se cambió por valor%' OR v_div NOT LIKE '%ya cambió de cantidad%'
     OR v_div NOT LIKE '%ya se le cambió la cantidad%'
     OR v_div NOT LIKE '%_rehacer_huella_lineas(v_foto, v_item_ids)%' THEN
    RAISE EXCEPTION 'dividir_regalo_pedido no quedo como se esperaba';
  END IF;
  IF v_cre NOT LIKE '%Reparto al cargar el pedido%' OR v_cre NOT LIKE '%origen_precio, regalo_cadena_id%' THEN
    RAISE EXCEPTION 'crear_pedido_completo no quedo como se esperaba';
  END IF;
  IF v_aud NOT LIKE '%AND s.reparto_id IS NULL%' OR (length(v_aud) - length(replace(v_aud, '''PROMO-B''', ''))) / 9 <> 1 THEN
    RAISE EXCEPTION 'auditoria_integridad no quedo como se esperaba';
  END IF;
  IF v_esl NOT LIKE '%''cantidad_sustituta''%' THEN
    RAISE EXCEPTION 'regalo_eslabones no quedo como se esperaba';
  END IF;

  -- Una sola sobrecarga de cada una (PGRST203).
  FOREACH f IN ARRAY ARRAY['actualizar_pedido_items', 'dividir_regalo_pedido', 'crear_pedido_completo',
                           'auditoria_integridad', 'regalo_eslabones', 'regalo_cantidad_base'] LOOP
    IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = f) <> 1 THEN
      RAISE EXCEPTION '% tiene mas de una sobrecarga', f;
    END IF;
  END LOOP;

  -- SECURITY DEFINER y EXECUTE de las RPCs: como estaban.
  FOREACH f IN ARRAY ARRAY['public.actualizar_pedido_items(bigint,jsonb,uuid)',
                           'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)',
                           'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
                           'public.auditoria_integridad()'] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN
      RAISE EXCEPTION '% dejo de ser SECURITY DEFINER', f;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'anon puede ejecutar %', f;
    END IF;
    IF NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'authenticated perdio EXECUTE sobre %', f;
    END IF;
  END LOOP;

  -- Las dos puras: de servidor, sin SECURITY DEFINER.
  FOREACH f IN ARRAY ARRAY['public.regalo_eslabones(bigint,bigint,bigint)',
                           'public.regalo_cantidad_base(jsonb,uuid,numeric)'] LOOP
    IF (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN
      RAISE EXCEPTION '% no tiene que ser SECURITY DEFINER', f;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% la puede ejecutar anon o authenticated, y es de servidor', f;
    END IF;
    IF NOT has_function_privilege('service_role', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'service_role no puede ejecutar % (la usa el gate de paridad)', f;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
              WHERE p.oid = 'public.regalo_cantidad_base(jsonb,uuid,numeric)'::regprocedure
                AND a.grantee = 0) THEN
    RAISE EXCEPTION 'regalo_cantidad_base quedo con EXECUTE para PUBLIC';
  END IF;

  -- auditoria_integridad check por check contra la foto del paso 0: ninguno
  -- empeora y ninguno high/critical en rojo.
  FOR r IN
    SELECT x->>'id' AS id, x->>'severidad' AS severidad, (x->>'ok')::boolean AS ok,
           COALESCE((x->>'violaciones')::numeric, 0) AS violaciones
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
  LOOP
    IF EXISTS (SELECT 1 FROM rr_foto_auditoria a WHERE a.id = r.id AND r.violaciones > a.violaciones) THEN
      RAISE EXCEPTION 'auditoria_integridad: % empeoro con la migracion', r.id;
    END IF;
    IF NOT r.ok AND r.severidad IN ('high', 'critical') THEN
      RAISE EXCEPTION 'auditoria_integridad: % (%) en rojo', r.id, r.severidad;
    END IF;
  END LOOP;
END
$verif$;

-- ---------------------------------------------------------------------------
-- 5 - Ensayo con datos reales: los casos de
--     scripts/test-repartos-regalo-1090-1091.sql (ver ahi cada uno). La
--     corrida de aca solo aborta si algo falla. Corre con la funcion de
--     backfill todavia en pg_temp, asi E6 la prueba.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.rr_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- set_config es por transaccion (CLAUDE.md): entre llamada y llamada se
-- limpian los GUCs de stock, asi una RPC no hereda la etiqueta de otra.
CREATE OR REPLACE FUNCTION pg_temp.rr_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- Stock, lotes y bolsa de unos productos.
CREATE OR REPLACE FUNCTION pg_temp.rr_fotos(p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_object_agg(pr.id::text, jsonb_build_object(
           'stock', pr.stock,
           'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                                FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
           'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                           FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int))
    FROM public.productos pr WHERE pr.id = ANY(p_prods);
$fn$;

-- Un producto sintetico con un lote (90 dias, 100, p_restante vivas) y
-- p_bolsa sin lote. Bolsa distinta de 0 a proposito (nota de la 316).
CREATE OR REPLACE FUNCTION pg_temp.rr_prod(p_suc bigint, p_admin uuid, p_cat text, p_bolsa int,
                                           p_restante int, p_bulto int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria, unidades_por_bulto)
  VALUES ('ZZ ensayo 1090 ' || p_cat, 100, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1090 ' || p_cat, p_bulto)
  RETURNING id INTO v_prod;
  IF p_restante > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.rr_hoy() + 90, 100, p_restante, p_admin, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_promo(p_suc bigint, p_regalo bigint, p_mueve boolean,
                                            p_auto boolean, p_upb int, p_ajuste bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, unidades_por_bloque,
                                  stock_por_bloque, ajuste_producto_id)
  VALUES ('ZZ ensayo 1090', 'bonificacion', CURRENT_DATE, p_suc, p_mueve, p_regalo, p_auto, p_upb,
          CASE WHEN p_upb IS NOT NULL THEN 1 END, p_ajuste)
  RETURNING id INTO v;
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

-- El alta: V x10 a $100 mas los regalos que vengan.
CREATE OR REPLACE FUNCTION pg_temp.rr_alta(p_cli bigint, p_admin uuid, p_venta bigint, p_regalos jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, 1000, p_admin, jsonb_build_array(pg_temp.rr_v(p_venta, 10)) || p_regalos, 'ensayo 1090');
  PERFORM pg_temp.rr_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_editar(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm);
  PERFORM pg_temp.rr_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar el pedido: %', v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_linea(p_ped bigint, p_prod bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false)
   ORDER BY id LIMIT 1;
$fn$;

-- Las lineas de regalo de un pedido: [{p, c, k}] por producto.
CREATE OR REPLACE FUNCTION pg_temp.rr_lineas(p_ped bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('p', producto_id, 'c', cantidad, 'k', regalo_cadena_id)
                            ORDER BY producto_id, id), '[]'::jsonb)
    FROM public.pedido_items
   WHERE pedido_id = p_ped AND COALESCE(es_bonificacion, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_dividir(p_item bigint, p_partes jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.dividir_regalo_pedido(p_item, p_partes, 'ensayo 1090');
  PERFORM pg_temp.rr_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_sustituir(p_item bigint, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sustituir_regalo_pedido(p_item, p_prod, p_cant, 'ensayo 1090');
  PERFORM pg_temp.rr_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo sustituir el regalo: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_parte(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant);
$fn$;

-- El estado de los acumuladores de una promo (modo B).
CREATE OR REPLACE FUNCTION pg_temp.rr_barras(p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'default', (SELECT usos_pendientes FROM public.promociones WHERE id = p_promo),
    'sabores', COALESCE((SELECT jsonb_object_agg(producto_regalo_id::text, usos_pendientes)
                           FROM public.promo_acumuladores WHERE promocion_id = p_promo), '{}'::jsonb));
$fn$;

-- El predicado de PROMO-B ANTES de esta migracion, sobre un pedido.
CREATE OR REPLACE FUNCTION pg_temp.rr_promo_b_viejo(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT count(*) FROM public.pedido_item_sustituciones s
   WHERE s.pedido_id = p_ped
     AND COALESCE(s.regalo_mueve_stock_snapshot, false)
     AND s.producto_original_id <> s.producto_sustituto_id
     AND EXISTS (SELECT 1 FROM public.stock_historico h
                  WHERE h.referencia_tipo='pedido' AND h.referencia_id=s.pedido_id
                    AND h.sucursal_id=s.sucursal_id AND h.producto_id=s.producto_original_id
                    AND h.origen='pedido_creado' AND h.created_at > s.created_at
                    AND h.diferencia < 0)
     AND NOT EXISTS (SELECT 1 FROM public.stock_historico h
                  WHERE h.referencia_tipo='pedido' AND h.referencia_id=s.pedido_id
                    AND h.sucursal_id=s.sucursal_id AND h.producto_id=s.producto_sustituto_id
                    AND h.origen='pedido_creado' AND h.created_at > s.created_at
                    AND h.diferencia < 0);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_promo_b_auditoria()
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE((x->>'violaciones')::numeric, -1)
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
   WHERE x->>'id' = 'PROMO-B';
$fn$;

-- ---------------------------------------------------------------------------
-- E1/E4 · #1090: alta X4 -> dividir X2+Y2 -> Y->Z (2->4, otra categoria) ->
-- Z->Y (4->3). Quedan X2 + Y3 (suman 5, la promo da 4). Editar con [X4] (un
-- bundle viejo) y con [X2, Y2] (el front nuevo, los cortes) conserva X2 + Y3
-- con sus claves y sin mover stock ni lotes (ni las barras por sabor, en modo
-- B); con [X5] la promo cambio
-- y se disuelve en X5 sin cadena. Modo A (E1) y modo B con barras por sabor (E4).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_e1_modo(p_cli bigint, p_adm uuid, p_suc bigint, p_mueve boolean)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; z bigint; c bigint; v_promo bigint; v_ped bigint;
  v_res jsonb; v_l0 jsonb; v_l1 jsonb; v_f0 jsonb; v_f1 jsonb; v_b0 jsonb; v_b1 jsonb;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  -- En modo B, Y y Z tienen que decir cuantas sueltas trae su contenedor para
  -- cambiar de categoria (mig 295); con 6, la barra de cada sabor cuenta igual.
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, CASE WHEN p_mueve THEN NULL ELSE 6 END);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, CASE WHEN p_mueve THEN NULL ELSE 6 END);
  IF p_mueve THEN
    v_promo := pg_temp.rr_promo(p_suc, x, true, false, NULL, NULL);
  ELSE
    c := pg_temp.rr_prod(p_suc, p_adm, 'contenedor', 20, 50, NULL);
    v_promo := pg_temp.rr_promo(p_suc, x, false, true, 6, c);
  END IF;

  v_ped := pg_temp.rr_alta(p_cli, p_adm, v, jsonb_build_array(pg_temp.rr_r(x, 4, v_promo)));
  v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, x),
                              jsonb_build_array(pg_temp.rr_parte(x, 2), pg_temp.rr_parte(y, 2)));
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo repartir: %', v_res;
  END IF;
  PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, y), z, 4);
  PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, z), y, 3);

  v_l0 := pg_temp.rr_lineas(v_ped);
  IF jsonb_array_length(v_l0) <> 2 OR (v_l0->0->>'c')::int <> 2 OR (v_l0->1->>'c')::int <> 3
     OR v_l0->0->>'k' IS NULL OR v_l0->1->>'k' IS NULL OR v_l0->0->>'k' = v_l0->1->>'k' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_l0)));
  END IF;
  v_f0 := pg_temp.rr_fotos(ARRAY[v, x, y, z, c]);
  v_b0 := pg_temp.rr_barras(v_promo);

  -- Un bundle viejo: la promo en una linea.
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 4, v_promo)));
  v_l1 := pg_temp.rr_lineas(v_ped); v_f1 := pg_temp.rr_fotos(ARRAY[v, x, y, z, c]); v_b1 := pg_temp.rr_barras(v_promo);
  f := pg_temp.rr_si(f, v_l1 = v_l0, format('editar con [X4] dejo %s, antes %s', v_l1, v_l0));
  f := pg_temp.rr_si(f, v_f1 = v_f0, format('editar con [X4] movio stock: %s, antes %s', v_f1, v_f0));
  -- Las barras por sabor son del modo B. En modo A usos_pendientes es un
  -- contador de usos que sustituir y dividir no tocan y la edicion recuenta
  -- por lineas (4 del alta -> 5 de X2 + Y3): no es stock ni es de este issue.
  f := pg_temp.rr_si(f, p_mueve OR v_b1 = v_b0, format('editar con [X4] movio las barras: %s, antes %s', v_b1, v_b0));

  -- El front nuevo: el corte de cada parte.
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 2, v_promo),
                                                            pg_temp.rr_r(y, 2, v_promo)));
  v_l1 := pg_temp.rr_lineas(v_ped); v_f1 := pg_temp.rr_fotos(ARRAY[v, x, y, z, c]); v_b1 := pg_temp.rr_barras(v_promo);
  f := pg_temp.rr_si(f, v_l1 = v_l0, format('editar con [X2, Y2] dejo %s, antes %s', v_l1, v_l0));
  f := pg_temp.rr_si(f, v_f1 = v_f0, format('editar con [X2, Y2] movio stock: %s, antes %s', v_f1, v_f0));
  f := pg_temp.rr_si(f, p_mueve OR v_b1 = v_b0, format('editar con [X2, Y2] movio las barras: %s, antes %s', v_b1, v_b0));

  -- La promo cambio: se disuelve.
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 5, v_promo)));
  v_l1 := pg_temp.rr_lineas(v_ped);
  f := pg_temp.rr_si(f, v_l1 = jsonb_build_array(jsonb_build_object('p', x, 'c', 5, 'k', NULL)),
                     format('con la promo en 5 quedo %s, esperado X5 sin cadena', v_l1));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.rr_e1_modo(p_cli, p_adm, p_suc, true);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.rr_e1_modo(p_cli, p_adm, p_suc, false);
$fn$;

-- ---------------------------------------------------------------------------
-- E2 · las guardas de dividir_regalo_pedido (#1090). Cada subcaso en su pedido.
--   a · A4 -> Z8 por valor (otra categoria): repartir Z8 se rechaza.
--   b · A4 -> B4 misma categoria, la promo pasa a 5 (B5): repartir B5 pasa.
--   c · A4 -> Z8 -> A4: repartir A4 pasa.
--   d · parte Y2 -> Y3 (mismo producto): repartirla se rechaza.
--   e · parte Y2 -> W3 (misma categoria): repartirla se rechaza.
--   f · parte Y2 sin cambios: repartirla pasa.
--   g · parte Y2 -> Z4 (otra categoria): repartirla se rechaza.
--   h · A4 -> B6 a mano (misma categoria): repartir B6 en B3 + W3 se rechaza
--       (sus cortes sumarian 6 contra una promo de 4).
--   i · A4 -> B6 -> B4: repartir B4 pasa.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; a bigint; b bigint; w bigint; z bigint; v_promo bigint; v_ped bigint;
  v_res jsonb; s text;
BEGIN
  -- 9 altas de V10: la bolsa alcanza para todas.
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 60, 50, NULL);
  a := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  b := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, NULL);
  v_promo := pg_temp.rr_promo(p_suc, a, true, false, NULL, NULL);

  FOREACH s IN ARRAY ARRAY['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'] LOOP
    v_ped := pg_temp.rr_alta(p_cli, p_adm, v, jsonb_build_array(pg_temp.rr_r(a, 4, v_promo)));
    IF s = 'a' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, a), z, 8);
      v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, z), jsonb_build_array(pg_temp.rr_parte(z, 4), pg_temp.rr_parte(w, 4)));
      f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%se cambió por valor%',
                         format('a · repartir Z8 que salio de A4 por valor dio %s, esperado el rechazo', v_res));
    ELSIF s = 'b' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, a), b, 4);
      PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(a, 5, v_promo)));
      IF pg_temp.rr_lineas(v_ped)->0->>'p' <> b::text OR (pg_temp.rr_lineas(v_ped)->0->>'c')::int <> 5 THEN
        f := f || format('b · punto de partida: %s, esperado B5', pg_temp.rr_lineas(v_ped));
      ELSE
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, b), jsonb_build_array(pg_temp.rr_parte(b, 3), pg_temp.rr_parte(a, 2)));
        f := pg_temp.rr_si(f, COALESCE((v_res->>'success')::boolean, false),
                           format('b · repartir B5 (A4->B4, misma categoria, promo en 5) dio %s, esperado que pase', v_res));
      END IF;
    ELSIF s = 'c' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, a), z, 8);
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, z), a, 4);
      v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, a), jsonb_build_array(pg_temp.rr_parte(a, 2), pg_temp.rr_parte(w, 2)));
      f := pg_temp.rr_si(f, COALESCE((v_res->>'success')::boolean, false),
                         format('c · repartir A4 (A4->Z8->A4) dio %s, esperado que pase', v_res));
    ELSIF s = 'h' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, a), b, 6);
      v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, b), jsonb_build_array(pg_temp.rr_parte(b, 3), pg_temp.rr_parte(w, 3)));
      f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%ya se le cambió la cantidad%',
                         format('h · repartir B6 (A4->B6 a mano, misma categoria) dio %s, esperado el rechazo', v_res));
      f := pg_temp.rr_si(f, pg_temp.rr_lineas(v_ped) = jsonb_build_array(jsonb_build_object('p', b, 'c', 6, 'k', pg_temp.rr_lineas(v_ped)->0->>'k'))
                            AND pg_temp.rr_lineas(v_ped)->0->>'k' IS NOT NULL,
                         format('h · tras el rechazo las lineas quedaron %s, esperado B6 con su clave', pg_temp.rr_lineas(v_ped)));
    ELSIF s = 'i' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, a), b, 6);
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, b), b, 4);
      v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, b), jsonb_build_array(pg_temp.rr_parte(b, 2), pg_temp.rr_parte(w, 2)));
      f := pg_temp.rr_si(f, COALESCE((v_res->>'success')::boolean, false),
                         format('i · repartir B4 (A4->B6->B4) dio %s, esperado que pase', v_res));
    ELSE
      v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, a), jsonb_build_array(pg_temp.rr_parte(a, 2), pg_temp.rr_parte(b, 2)));
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        RAISE EXCEPTION '% · no se pudo repartir: %', s, v_res;
      END IF;
      IF s = 'd' THEN
        PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, b), b, 3);
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, b), jsonb_build_array(pg_temp.rr_parte(b, 2), pg_temp.rr_parte(w, 1)));
        f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%ya cambió de cantidad%',
                           format('d · repartir la parte Y2->Y3 dio %s, esperado el rechazo', v_res));
      ELSIF s = 'e' THEN
        PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, b), w, 3);
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, w), jsonb_build_array(pg_temp.rr_parte(w, 2), pg_temp.rr_parte(b, 1)));
        f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%ya cambió de cantidad%',
                           format('e · repartir la parte Y2->W3 (misma categoria) dio %s, esperado el rechazo', v_res));
      ELSIF s = 'f' THEN
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, b), jsonb_build_array(pg_temp.rr_parte(b, 1), pg_temp.rr_parte(w, 1)));
        f := pg_temp.rr_si(f, COALESCE((v_res->>'success')::boolean, false),
                           format('f · repartir la parte Y2 sin cambios dio %s, esperado que pase', v_res));
      ELSE
        PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, b), z, 4);
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, z), jsonb_build_array(pg_temp.rr_parte(z, 2), pg_temp.rr_parte(w, 2)));
        f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%se cambió por valor%',
                           format('g · repartir la parte Y2->Z4 (otra categoria) dio %s, esperado el rechazo', v_res));
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- E3 · #1091: alta Y2 + W2 de una promo (default X): dos filas de reparto con
-- el mismo reparto_id, claves distintas, original X por 4 y cada parte
-- describiendose a si misma; el stock del alta es el de siempre (V -10, Y -2,
-- W -2, 'pedido_creado'). Despues Y -> Z, la promo se cae y vuelve con Y4: no
-- hereda la clave de la parte (quedaria Z8).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; z bigint; v_promo bigint; v_ped bigint;
  v_l jsonb; v_filas jsonb; v_hist jsonb; v_esperado jsonb;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, NULL);
  v_promo := pg_temp.rr_promo(p_suc, x, true, false, NULL, NULL);

  v_ped := pg_temp.rr_alta(p_cli, p_adm, v, jsonb_build_array(pg_temp.rr_r(y, 2, v_promo), pg_temp.rr_r(w, 2, v_promo)));

  v_l := pg_temp.rr_lineas(v_ped);
  f := pg_temp.rr_si(f, jsonb_array_length(v_l) = 2 AND v_l->0->>'k' IS NOT NULL AND v_l->1->>'k' IS NOT NULL
                        AND v_l->0->>'k' <> v_l->1->>'k',
                     format('las partes del alta quedaron %s, esperado una clave propia cada una', v_l));
  SELECT jsonb_agg(jsonb_build_object('item', s.pedido_item_id, 'orig', s.producto_original_id,
                                      'sust', s.producto_sustituto_id, 'co', s.cantidad_original,
                                      'cs', s.cantidad_sustituta, 'raiz', s.producto_raiz_id,
                                      'cadena', s.cadena_id, 'reparto', s.reparto_id, 'motivo', s.motivo,
                                      'snap', s.regalo_mueve_stock_snapshot)
                   ORDER BY s.producto_sustituto_id)
    INTO v_filas
    FROM public.pedido_item_sustituciones s WHERE s.pedido_id = v_ped;
  f := pg_temp.rr_si(f,
         jsonb_array_length(COALESCE(v_filas, '[]')) = 2
         AND v_filas->0->>'reparto' IS NOT NULL AND v_filas->0->>'reparto' = v_filas->1->>'reparto'
         AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(v_filas) e
            WHERE (e->>'orig')::bigint <> x OR (e->>'co')::numeric <> 4 OR (e->>'cs')::numeric <> 2
               OR (e->>'raiz')::bigint <> (e->>'sust')::bigint OR e->>'motivo' <> 'Reparto al cargar el pedido'
               OR NOT (e->>'snap')::boolean
               OR NOT EXISTS (SELECT 1 FROM public.pedido_items pi
                               WHERE pi.id = (e->>'item')::bigint AND pi.producto_id = (e->>'sust')::bigint
                                 AND pi.regalo_cadena_id = (e->>'cadena')::uuid)),
         format('las filas de reparto del alta quedaron %s', v_filas));
  f := pg_temp.rr_si(f, NOT EXISTS (SELECT 1 FROM public.pedido_items
                                     WHERE pedido_id = v_ped AND descripcion_regalo LIKE '%[Sustituido por:%'),
                     'una parte del alta quedo marcada como sustituida');
  -- El stock del alta, el de un alta Y2 + W2 sin el parche.
  SELECT jsonb_agg(jsonb_build_array(h.producto_id, h.diferencia, h.origen) ORDER BY h.producto_id, h.id)
    INTO v_hist
    FROM public.stock_historico h WHERE h.referencia_tipo = 'pedido' AND h.referencia_id = v_ped;
  SELECT jsonb_agg(e ORDER BY (e->>0)::bigint)
    INTO v_esperado
    FROM jsonb_array_elements(jsonb_build_array(jsonb_build_array(v, -10, 'pedido_creado'),
                                                jsonb_build_array(y, -2, 'pedido_creado'),
                                                jsonb_build_array(w, -2, 'pedido_creado'))) e;
  f := pg_temp.rr_si(f, v_hist = v_esperado, format('el stock del alta fue %s, esperado %s', v_hist, v_esperado));

  -- Y -> Z, la promo se cae y vuelve.
  PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, y), z, 4);
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10)));
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(y, 4, v_promo)));
  v_l := pg_temp.rr_lineas(v_ped);
  f := pg_temp.rr_si(f, v_l = jsonb_build_array(jsonb_build_object('p', y, 'c', 4, 'k', NULL)),
                     format('la promo que volvio quedo %s, esperado Y4 sin cadena', v_l));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- E5 · PROMO-B. now() es el mismo en toda la transaccion, asi que las filas
-- de sustitucion y el stock del alta se corren un dia para atras antes de la
-- edicion: si no, el "posterior a la fila" del predicado no separa el alta de
-- la edicion y el ensayo no muerde.
--   a · alta Y2 + W2 (default X), la promo pasa a 5: X5. El predicado viejo
--       cuenta las filas de reparto; PROMO-B queda en 0.
--   b · alta Y2 + W2, Y -> Z, la promo se cae y vuelve con Y4: el predicado
--       viejo cuenta el eslabon Y -> Z de una clave sin linea; PROMO-B en 0.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; z bigint; v_promo bigint; v_ped bigint;
  v_viejo bigint; v_nuevo numeric; s text;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, NULL);
  v_promo := pg_temp.rr_promo(p_suc, x, true, false, NULL, NULL);

  FOREACH s IN ARRAY ARRAY['a', 'b'] LOOP
    v_ped := pg_temp.rr_alta(p_cli, p_adm, v, jsonb_build_array(pg_temp.rr_r(y, 2, v_promo), pg_temp.rr_r(w, 2, v_promo)));
    IF s = 'b' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, y), z, 4);
    END IF;
    -- El alta (y el cambio de b) pasaron ayer: sus filas y su stock.
    UPDATE public.pedido_item_sustituciones SET created_at = now() - interval '1 day' WHERE pedido_id = v_ped;
    UPDATE public.stock_historico SET created_at = now() - interval '1 day'
     WHERE referencia_tipo = 'pedido' AND referencia_id = v_ped;
    IF s = 'a' THEN
      PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 5, v_promo)));
    ELSE
      PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10)));
      PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(y, 4, v_promo)));
    END IF;
    v_viejo := pg_temp.rr_promo_b_viejo(v_ped);
    v_nuevo := pg_temp.rr_promo_b_auditoria();
    f := pg_temp.rr_si(f, v_viejo > 0, format('%s · el predicado viejo de PROMO-B dio %s: el ensayo no muerde', s, v_viejo));
    f := pg_temp.rr_si(f, v_nuevo = 0, format('%s · PROMO-B de auditoria_integridad dio %s, esperado 0', s, v_nuevo));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- E6 · el backfill de la migracion (pg_temp.rr_backfill, solo existe adentro
-- de ella): a · dos lineas de regalo de una promo sin claves -> dos claves y
-- dos filas de reparto; b · si una ya tiene un eslabon comun, aborta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_linea_regalo_suelta(p_ped bigint, p_prod bigint, p_suc bigint,
                                                          p_cant int, p_promo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_item bigint;
BEGIN
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (p_ped, p_prod, p_cant, 0, 0, p_suc, true, p_promo)
  RETURNING id INTO v_item;
  RETURN v_item;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; z bigint; v_promo bigint; v_ped bigint;
  v_n int; v_l jsonb; v_filas int; v_item bigint; v_err text;
BEGIN
  IF to_regprocedure('pg_temp.rr_backfill(bigint)') IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'sin rr_backfill: E6 solo corre adentro de la migracion');
  END IF;
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, NULL);
  v_promo := pg_temp.rr_promo(p_suc, x, true, false, NULL, NULL);

  -- a
  v_ped := pg_temp.rr_alta(p_cli, p_adm, v, '[]'::jsonb);
  PERFORM pg_temp.rr_linea_regalo_suelta(v_ped, y, p_suc, 2, v_promo);
  PERFORM pg_temp.rr_linea_regalo_suelta(v_ped, w, p_suc, 2, v_promo);
  v_n := pg_temp.rr_backfill(v_ped);
  v_l := pg_temp.rr_lineas(v_ped);
  SELECT count(*) INTO v_filas FROM public.pedido_item_sustituciones s
   WHERE s.pedido_id = v_ped AND s.reparto_id IS NOT NULL AND s.cantidad_original = 4
     AND s.producto_original_id = x AND s.motivo = 'Reparto al cargar el pedido (backfill)'
     AND EXISTS (SELECT 1 FROM public.pedido_items pi WHERE pi.id = s.pedido_item_id
                    AND pi.regalo_cadena_id = s.cadena_id AND pi.producto_id = s.producto_sustituto_id
                    AND pi.cantidad = s.cantidad_sustituta);
  f := pg_temp.rr_si(f, v_n = 1 AND v_filas = 2 AND v_l->0->>'k' IS NOT NULL AND v_l->1->>'k' IS NOT NULL
                        AND v_l->0->>'k' <> v_l->1->>'k',
                     format('a · el backfill dio %s grupos, %s filas y lineas %s', v_n, v_filas, v_l));

  -- b
  v_ped := pg_temp.rr_alta(p_cli, p_adm, v, '[]'::jsonb);
  v_item := pg_temp.rr_linea_regalo_suelta(v_ped, y, p_suc, 2, v_promo);
  PERFORM pg_temp.rr_linea_regalo_suelta(v_ped, w, p_suc, 2, v_promo);
  UPDATE public.pedido_items SET regalo_cadena_id = gen_random_uuid() WHERE id = v_item;
  INSERT INTO public.pedido_item_sustituciones (pedido_id, pedido_item_id, promocion_id, producto_original_id,
                                                producto_sustituto_id, cantidad_original, cantidad_sustituta,
                                                regalo_mueve_stock_snapshot, motivo, autorizado_por, sucursal_id,
                                                cadena_id)
  SELECT v_ped, v_item, v_promo, z, y, 4, 2, true, 'ensayo 1090', p_adm, p_suc, regalo_cadena_id
    FROM public.pedido_items WHERE id = v_item;
  BEGIN
    PERFORM pg_temp.rr_backfill(v_ped);
    v_err := NULL;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  f := pg_temp.rr_si(f, v_err LIKE '%resolverlo a mano%',
                     format('b · el backfill con un eslabon comun dio %s, esperado que aborte', COALESCE(v_err, 'OK')));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1090$
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
    RAISE EXCEPTION 'ens1090 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1090 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada,
  -- asi que no deja nada; si alguno falla, la migracion entera aborta.
  FOREACH v_caso IN ARRAY ARRAY['e1', 'e2', 'e3', 'e4', 'e5', 'e6'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.rr_reset();
      EXECUTE format('SELECT pg_temp.rr_caso_%s($1, $2, $3)', v_caso)
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
    RAISE EXCEPTION E'ens1090 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1090$;

-- Las auxiliares del ensayo (y el backfill) no se quedan en la sesion.
DO $limpieza1090$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS f
      FROM pg_proc p
     WHERE p.pronamespace = pg_my_temp_schema()
       AND p.proname LIKE 'rr\_%'
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.f::text;
  END LOOP;
END
$limpieza1090$;
