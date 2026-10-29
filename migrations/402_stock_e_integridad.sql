-- 402 · Stock e integridad (#1254, #1255 salvo compras, #1256).
--
-- #1254 · aplicar_control_stock pisaba el stock con el número contado. La
-- planilla trae el stock del sistema al descargarla (columna "Stock Sistema"),
-- pero nadie lo leía: lo vendido entre el conteo y la carga reaparecía como
-- 'control_stock' (planilla 12, se cuentan 10, se venden 3 → sistema 9,
-- góndola 7; aplicar el 10 dejaba 3 unidades fantasma). Ahora se aplica la
-- diferencia (contado − planilla) sobre el stock de ahora, se informa en qué
-- productos se movió el stock desde la descarga, y un conteo que no es un
-- entero ≥ 0 se rechaza en vez de redondearse.
--
-- #1255 · Orden de locks: producto antes que lote, y productos por id
-- ascendente (el orden de la venta). dar_de_baja_lote bloqueaba el lote antes
-- que el producto, y aplicar_control_stock en el orden de la planilla: los dos
-- podían cruzarse con una venta en un 40P01. ajustar_lote y
-- _clampear_lotes_a_stock leían el stock sin FOR UPDATE. El orden de las
-- compras (y que sincronizar_lotes_compra bloquee el producto antes que sus
-- lotes) es de la tarjeta 3; el reintento del 40P01 en el front, de la 9.
--
-- #1256 · auditoria_integridad(): STK-A por id (con lo importado de Taco Pozo
-- por fecha), STK-D a high, CC-B sin el corte de 30 días, y tres checks nuevos:
-- CC-C (monto_pagado > total), FISCAL-A (en FC, neto + IVA = total) y VENTA-N
-- (subtotal = cantidad × precio). Ids libres verificados en la función viva y
-- en el ledger: ni CC-C, ni FISCAL-*, ni VENTA-N se usaron nunca. Medidos en
-- prod antes de aplicar: los tres nuevos en 0, CC-B en 0 fuera de los 67
-- legacy, STK-A por id en 0 con la regla de lo importado (1 sin ella: el
-- producto 186), STK-D en 0. Quedan 69 checks.
--
-- Y auditoria_lectura_authenticated(): lo que authenticated puede leer de cada
-- tabla y vista, más las FKs, para que scripts/check-embeds.mjs (que corre con
-- la service_role, que se saltea los grants) vea un embed a una tabla o
-- columna que la app no puede leer. Sólo service_role la ejecuta.
--
-- Ensayo: scripts/test-stock-integridad-1254-1255-1256.sql

-- ===========================================================================
-- #1254 · aplicar_control_stock
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.aplicar_control_stock(p_ajustes jsonb, p_observaciones text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id    bigint;
  v_usuario_id     uuid;
  v_sesion_id      bigint;
  v_total_items    integer := 0;
  v_total_altas    integer := 0;
  v_total_bajas    integer := 0;
  v_movidos        integer := 0;
  v_ajuste         jsonb;
  v_num            numeric;
  v_ids            bigint[];
  v_producto_id    bigint;
  v_stock_real     integer;
  v_stock_planilla integer;
  v_stock_actual   integer;
  v_diferencia     integer;
  v_stock_nuevo    integer;
  v_aplicados      jsonb := '[]'::jsonb;
  v_no_encontrados jsonb := '[]'::jsonb;
  v_rechazados     jsonb := '[]'::jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede aplicar ajustes de control de stock';
  END IF;

  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa';
  END IF;
  v_usuario_id := auth.uid();

  IF jsonb_typeof(COALESCE(p_ajustes, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Los ajustes tienen que venir en una lista';
  END IF;

  /* #1254 · Todo o nada, antes de tocar el stock. Cada fila contada trae el
     conteo (stock_real) y el stock que tenía el sistema al descargar la
     planilla (stock_planilla, la columna "Stock Sistema"). Los dos tienen que
     ser enteros: un 2,5 quedaba en 3 sin aviso (redondeaban el front y esta
     función), y un conteo de unidades con decimales es un error de tipeo, no
     algo para adivinar. Una fila sin conteo (null o '') es un ítem que no se
     controló y se saltea, como siempre: no se ajusta a 0. Un bundle viejo del
     PWA no manda stock_planilla y choca acá, en vez de pisar el stock. */
  FOR v_ajuste IN SELECT e FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb)) e
  LOOP
    IF COALESCE(v_ajuste->>'producto_id', '') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'Hay un ajuste sin un producto válido: %', v_ajuste;
    END IF;
    CONTINUE WHEN v_ajuste->>'stock_real' IS NULL OR btrim(v_ajuste->>'stock_real') = '';

    IF jsonb_typeof(v_ajuste->'stock_real') <> 'number' THEN
      RAISE EXCEPTION 'El stock contado del producto % tiene que ser un número entero, y vino %',
        v_ajuste->>'producto_id', v_ajuste->'stock_real';
    END IF;
    v_num := (v_ajuste->>'stock_real')::numeric;
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'El stock contado del producto % tiene que ser un entero mayor o igual a 0, y vino %',
        v_ajuste->>'producto_id', v_num;
    END IF;

    IF jsonb_typeof(v_ajuste->'stock_planilla') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Falta el stock que traía la planilla para el producto % (columna "Stock Sistema"). Actualizá la app y volvé a cargar la planilla.',
        v_ajuste->>'producto_id';
    END IF;
    v_num := (v_ajuste->>'stock_planilla')::numeric;
    IF v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'El stock de la planilla del producto % tiene que ser un número entero, y vino %',
        v_ajuste->>'producto_id', v_num;
    END IF;
  END LOOP;

  -- Con la diferencia, una fila repetida se aplicaría dos veces.
  SELECT (e->>'producto_id')::bigint INTO v_producto_id
    FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb)) e
   WHERE e->>'stock_real' IS NOT NULL AND btrim(e->>'stock_real') <> ''
   GROUP BY 1
  HAVING count(*) > 1
   ORDER BY 1
   LIMIT 1;
  IF v_producto_id IS NOT NULL THEN
    RAISE EXCEPTION 'El producto % está más de una vez en la planilla', v_producto_id;
  END IF;

  INSERT INTO control_stock_sesiones (usuario_id, sucursal_id, observaciones)
  VALUES (v_usuario_id, v_sucursal_id, p_observaciones)
  RETURNING id INTO v_sesion_id;

  /* mig 240 · el ledger lo escribe el trigger, no esta funcion.
     Antes habia un INSERT a mano en stock_historico ADEMAS del que ya dejaba
     trg_stock_historico por el UPDATE: dos filas por diferencia, una util y
     una 'auto' anonima. Ahora se etiqueta el contexto y la unica fila que
     queda es la del trigger, con la sesion y el usuario adentro --lo mismo que
     lee fetchDetalle, que filtra origen='control_stock'--.
     'control_stock' NO esta en la lista blanca de sincronizar_lotes_stock a
     proposito: un conteo que encuentra unidades de mas no sabe de que lote
     son, y van a la bolsa sin vencimiento, igual que antes con 'auto'. El
     camino de BAJADA del trigger no mira el origen, asi que un conteo a la
     baja sigue consumiendo FEFO como siempre. */
  PERFORM set_config('app.stock_origen',   'control_stock', true);
  PERFORM set_config('app.stock_ref_tipo', 'control_stock_sesion', true);
  PERFORM set_config('app.stock_ref_id',   v_sesion_id::text, true);
  PERFORM set_config('app.stock_user_id',  COALESCE(v_usuario_id::text, ''), true);

  /* #1255 · Los productos en orden de id, todos antes de mover el primero:
     el orden de crear_pedido_completo. En el orden de la planilla, un control
     [B, A] y una venta [A, B] se bloqueaban entre sí (40P01). Cada UPDATE baja
     después a los lotes de su producto (trg_lotes_sincronizar): producto antes
     que lote, como la venta. */
  SELECT array_agg(DISTINCT (e->>'producto_id')::bigint ORDER BY (e->>'producto_id')::bigint)
    INTO v_ids
    FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb)) e
   WHERE e->>'stock_real' IS NOT NULL AND btrim(e->>'stock_real') <> '';

  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal_id AND id = ANY(COALESCE(v_ids, '{}'::bigint[]))
    ORDER BY id
      FOR UPDATE;

  FOR v_ajuste IN
    SELECT e FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb)) e
     WHERE e->>'stock_real' IS NOT NULL AND btrim(e->>'stock_real') <> ''
     ORDER BY (e->>'producto_id')::bigint
  LOOP
    v_producto_id    := (v_ajuste->>'producto_id')::bigint;
    v_stock_real     := (v_ajuste->>'stock_real')::numeric::integer;
    v_stock_planilla := (v_ajuste->>'stock_planilla')::numeric::integer;

    SELECT stock INTO v_stock_actual
      FROM productos
     WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;

    IF NOT FOUND THEN
      v_no_encontrados := v_no_encontrados || jsonb_build_object('producto_id', v_producto_id);
      CONTINUE;
    END IF;

    /* #1254 · El conteo entra como DIFERENCIA contra lo que decía la planilla,
       sobre el stock de ahora: lo vendido entre el conteo y la carga ya bajó
       el stock y no vuelve. Lo que se movió entre la DESCARGA y el conteo, en
       cambio, queda adentro de la diferencia (la planilla se descarga para
       contar enseguida): por eso cada ajuste dice si el stock se movió desde
       la descarga, y la pantalla lo avisa antes de aplicar. */
    v_diferencia := v_stock_real - v_stock_planilla;
    CONTINUE WHEN v_diferencia = 0;

    v_stock_nuevo := v_stock_actual + v_diferencia;
    IF v_stock_nuevo < 0 THEN
      -- Se contaron menos de los que se vendieron después: el conteo ya no
      -- dice nada del stock de hoy. No se aplica; hay que volver a contar.
      v_rechazados := v_rechazados || jsonb_build_object(
        'producto_id',    v_producto_id,
        'stock_planilla', v_stock_planilla,
        'stock_contado',  v_stock_real,
        'stock_actual',   v_stock_actual,
        'motivo',         'quedaria_negativo'
      );
      CONTINUE;
    END IF;

    UPDATE productos SET stock = v_stock_nuevo, updated_at = now()
    WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;

    v_total_items := v_total_items + 1;
    IF v_diferencia > 0 THEN
      v_total_altas := v_total_altas + v_diferencia;
    ELSE
      v_total_bajas := v_total_bajas + abs(v_diferencia);
    END IF;
    IF v_stock_actual <> v_stock_planilla THEN
      v_movidos := v_movidos + 1;
    END IF;

    v_aplicados := v_aplicados || jsonb_build_object(
      'producto_id', v_producto_id,
      'stock_planilla', v_stock_planilla,
      'stock_contado', v_stock_real,
      'stock_anterior', v_stock_actual,
      'stock_nuevo', v_stock_nuevo,
      'diferencia', v_diferencia,
      'movido_desde_descarga', v_stock_actual <> v_stock_planilla
    );
  END LOOP;

  UPDATE control_stock_sesiones
  SET total_items = v_total_items, total_altas = v_total_altas, total_bajas = v_total_bajas
  WHERE id = v_sesion_id;

  RETURN jsonb_build_object(
    'sesion_id', v_sesion_id,
    'total_items', v_total_items,
    'total_altas', v_total_altas,
    'total_bajas', v_total_bajas,
    'movidos_desde_descarga', v_movidos,
    'aplicados', v_aplicados,
    'no_encontrados', v_no_encontrados,
    'rechazados', v_rechazados
  );
END;
$function$;

-- ===========================================================================
-- #1255 · dar_de_baja_lote: el producto antes que el lote
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.dar_de_baja_lote(p_lote_id bigint, p_cantidad integer, p_observaciones text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal    bigint := public.current_sucursal_id();
  v_rol         text;
  v_producto_id bigint;
  v_lote        record;
  v_stock       integer;
  v_merma_id    bigint;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad a dar de baja tiene que ser mayor a 0';
  END IF;

  -- #1255 · el producto antes que el lote, el orden de la venta: bloquea el
  -- producto y el trigger, recién después, sus lotes por FEFO. Al revés, dar
  -- de baja un lote vencido mientras se vende ese producto con la bolsa en 0
  -- era exactamente el ciclo (40P01). El producto de un lote no cambia nunca
  -- (ninguna función reescribe producto_lotes.producto_id), así que se lee sin
  -- lock para saber cuál bloquear, y el lote se relee ya bloqueado.
  SELECT producto_id INTO v_producto_id
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;

  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = v_producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;
  IF p_cantidad > v_lote.cantidad_restante THEN
    RAISE EXCEPTION 'El lote tiene % unidades: no se pueden dar de baja %',
      v_lote.cantidad_restante, p_cantidad;
  END IF;

  IF v_stock < p_cantidad THEN
    RAISE EXCEPTION 'El stock del producto es % y la baja es de %: dejaria stock negativo',
      v_stock, p_cantidad;
  END IF;

  UPDATE public.producto_lotes
     SET cantidad_restante = cantidad_restante - p_cantidad
   WHERE id = p_lote_id;

  INSERT INTO public.mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    v_lote.producto_id, p_cantidad, 'vencimiento',
    COALESCE(NULLIF(btrim(COALESCE(p_observaciones, '')), ''),
             'Lote vencido el ' || to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY')),
    v_stock, GREATEST(v_stock - p_cantidad, 0), auth.uid(), v_sucursal
  )
  RETURNING id INTO v_merma_id;

  PERFORM set_config('app.stock_origen',   'lote_vencido',    true);
  PERFORM set_config('app.stock_ref_tipo', 'producto_lotes',  true);
  PERFORM set_config('app.stock_ref_id',   p_lote_id::text,   true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text,  true);

  UPDATE public.productos
     SET stock = stock - p_cantidad,
         updated_at = now()
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'ok',                true,
    'lote_id',           p_lote_id,
    'merma_id',          v_merma_id,
    'cantidad',          p_cantidad,
    'cantidad_restante', v_lote.cantidad_restante - p_cantidad,
    'stock',             v_stock - p_cantidad
  );
END;
$function$;

-- ===========================================================================
-- #1255 · ajustar_lote: FOR UPDATE del producto, antes que el lote
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.ajustar_lote(p_lote_id bigint, p_cantidad_restante integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal    bigint := public.current_sucursal_id();
  v_rol         text;
  v_producto_id bigint;
  v_lote        record;
  v_stock       integer;
  v_otros       integer;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  IF p_cantidad_restante IS NULL OR p_cantidad_restante < 0 THEN
    RAISE EXCEPTION 'La cantidad restante no puede ser negativa';
  END IF;

  -- #1255 · el producto con FOR UPDATE y antes que el lote (el orden de la
  -- venta, ver dar_de_baja_lote). Sin el lock, una venta del producto sin
  -- commitear dejaba leer el stock de antes: stock 10 en la bolsa, la venta
  -- baja 5, el lote se ajusta a 10 → stock 5 y lotes 10, bolsa −5 (LOTE-A).
  SELECT producto_id INTO v_producto_id
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;

  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = v_producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;
  IF p_cantidad_restante > v_lote.cantidad THEN
    RAISE EXCEPTION 'El lote nacio con % unidades: no puede quedarle %',
      v_lote.cantidad, p_cantidad_restante;
  END IF;

  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_otros
    FROM public.producto_lotes
   WHERE producto_id = v_lote.producto_id
     AND sucursal_id = v_sucursal
     AND id <> p_lote_id;

  IF v_otros + p_cantidad_restante > v_stock THEN
    RAISE EXCEPTION 'No entra: el stock del producto es % y los otros lotes ya ocupan %',
      v_stock, v_otros;
  END IF;

  UPDATE public.producto_lotes
     SET cantidad_restante = p_cantidad_restante
   WHERE id = p_lote_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'lote_id',           p_lote_id,
    'cantidad_restante', p_cantidad_restante,
    'bolsa',             v_stock - v_otros - p_cantidad_restante
  );
END;
$function$;

-- ===========================================================================
-- #1255 · _clampear_lotes_a_stock: FOR UPDATE del producto
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._clampear_lotes_a_stock(p_producto_id bigint, p_sucursal_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_stock     integer;
  v_asignado  integer;
  v_exceso    integer;
  v_saca      integer;
  v_total     integer := 0;
  r           record;
BEGIN
  -- #1255 · con FOR UPDATE: sin el lock, una venta del producto sin commitear
  -- deja leer el stock de antes y el recorte se queda corto (LOTE-A). Su
  -- llamador, sincronizar_lotes_compra, tiene que haber bloqueado el producto
  -- ANTES que los lotes de la compra: si no, este lock invierte el orden
  -- (lote → producto) contra la venta.
  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = p_producto_id AND sucursal_id = p_sucursal_id
     FOR UPDATE;

  IF v_stock IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_asignado
    FROM public.producto_lotes
   WHERE producto_id = p_producto_id AND sucursal_id = p_sucursal_id;

  v_exceso := v_asignado - v_stock;
  IF v_exceso <= 0 THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT id, cantidad_restante
      FROM public.producto_lotes
     WHERE producto_id = p_producto_id
       AND sucursal_id = p_sucursal_id
       AND cantidad_restante > 0
     ORDER BY fecha_vencimiento DESC, id DESC
     FOR UPDATE
  LOOP
    EXIT WHEN v_exceso <= 0;
    v_saca := LEAST(v_exceso, r.cantidad_restante);
    UPDATE public.producto_lotes
       SET cantidad_restante = cantidad_restante - v_saca
     WHERE id = r.id;
    v_exceso := v_exceso - v_saca;
    v_total  := v_total + v_saca;
  END LOOP;

  RETURN v_total;
END;
$function$;

-- ===========================================================================
-- #1256 · auditoria_integridad()
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.auditoria_integridad()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_checks jsonb;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  WITH checks(id, severidad, descripcion, viol) AS (
    VALUES
    ('VENTA-A','critical','pedidos.total = SUM(pedido_items.subtotal) en no cancelados',
      (SELECT count(*) FROM (SELECT p.id FROM pedidos p LEFT JOIN pedido_items pi ON pi.pedido_id=p.id
        WHERE p.estado NOT IN ('cancelado','anulado') GROUP BY p.id,p.total
        HAVING abs(p.total-COALESCE(sum(pi.subtotal),0)-CASE WHEN COALESCE(sum(pi.subtotal),0)>0 THEN p.cargo_envio ELSE 0 END)>0.01) x)),
    ('VENTA-B','high','ningún pedido_items con subtotal<0',
      (SELECT count(*) FROM pedido_items WHERE subtotal<0)),
    ('VENTA-C','high','estados de pedido dentro del dominio permitido',
      (SELECT count(*) FROM pedidos WHERE estado NOT IN ('pendiente','en_preparacion','asignado','entregado','cancelado','anulado'))),
    ('VENTA-D','medium','canal de pedido dentro del dominio permitido',
      (SELECT count(*) FROM pedidos WHERE canal NOT IN ('app','cambio','bot'))),
    -- mig 245 (#633) · canal EN NEGATIVO, como la 241: el universo de la venta
    -- es todo canal menos la comanda de canje. Medido antes de ampliar: 0 y 0.
    ('VENTA-E','high','venta entregada (cualquier canal de venta) sin fecha nula ni futura',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal<>'cambio' AND (fecha IS NULL OR fecha>CURRENT_DATE))),
    ('VENTA-F','high','ningún pedido con total<0',
      (SELECT count(*) FROM pedidos WHERE total<0)),
    ('VENTA-G','medium','ningún pedido_items con cantidad<=0',
      (SELECT count(*) FROM pedido_items WHERE cantidad<=0)),
    ('VENTA-H','high','pedido_items.sucursal_id = pedidos.sucursal_id',
      (SELECT count(*) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id WHERE pi.sucursal_id<>p.sucursal_id)),
    -- #1043: los 4 cancelados de abril que la 235 había dejado se pusieron en 0.
    ('VENTA-I','low','pedido cancelado debe tener total, total_neto, total_iva y total_real en 0',
      (SELECT count(*) FROM pedidos WHERE estado='cancelado'
         AND (total<>0 OR COALESCE(total_neto,0)<>0 OR COALESCE(total_iva,0)<>0 OR COALESCE(total_real,0)<>0 OR COALESCE(cargo_envio,0)<>0))),
    -- #1043: el canje (canal 'cambio') nace sin ítems por diseño: lo canjeado
    -- vive en recorrido_cambios, y eso lo cuida CAMBIO-03.
    -- #1098: el pedido que el cliente rechazó entero en la entrega queda sin
    -- líneas (registrar_salvedad borra la que queda en 0; el CHECK de cantidad
    -- no la deja en 0) y con total 0. Se exime por la huella de la salvedad
    -- vigente: cantidad_entregada 0 y la línea borrada. Así eran el 652 y el
    -- 7604 (salvedades 52 y 703). Si se anula la salvedad, la línea vuelve.
    ('VENTA-J','low','ninguna venta entregada sin items (salvo el pedido que el cliente rechazó entero por salvedad)',
      (SELECT count(*) FROM pedidos p WHERE estado='entregado' AND canal<>'cambio'
         AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id=p.id)
         AND NOT EXISTS (SELECT 1 FROM salvedades_items s
                          WHERE s.pedido_id = p.id AND s.sucursal_id = p.sucursal_id
                            AND p.total = 0
                            AND s.estado_resolucion IS DISTINCT FROM 'anulada'
                            AND s.cantidad_entregada = 0
                            AND s.pedido_item_id IS NULL))),
    ('VENTA-M','medium','coherencia estado_pago vs monto_pagado',
      (SELECT (SELECT count(*) FROM pedidos WHERE estado_pago='pagado' AND estado NOT IN ('cancelado','anulado') AND total>0 AND COALESCE(monto_pagado,0)<total-0.01)
            + (SELECT count(*) FROM pedidos WHERE estado_pago='pendiente' AND COALESCE(monto_pagado,0)>0.01))),
    -- #1256 · el desglose de una FC cierra con su total (#1258). El envío va
    -- adentro de los dos (cargo_4), así que la igualdad es al centavo. Un
    -- precio con más de dos decimales que entra crudo la rompe: 10,005 × 100
    -- guarda total 1.000,50 y neto + IVA 1.001,00.
    ('FISCAL-A','high','pedidos FC donde total_neto + total_iva <> total (#1258)',
      (SELECT count(*) FROM pedidos WHERE tipo_factura='FC'
         AND abs(COALESCE(total_neto,0) + COALESCE(total_iva,0) - total) > 0.005)),
    -- #1256 · cada línea vale cantidad × precio_unitario (#1258). precio es
    -- numeric(10,2) y cantidad entera, así que la cuenta es exacta: un subtotal
    -- calculado con el precio crudo y guardado con el redondeado se separa, y
    -- la nota de crédito acredita cantidad × precio, más de lo cobrado.
    ('VENTA-N','high','pedido_items donde subtotal <> cantidad × precio_unitario (#1258)',
      (SELECT count(*) FROM pedido_items
        WHERE abs(COALESCE(subtotal,0) - cantidad * COALESCE(precio_unitario,0)) > 0.005)),
    ('COSTO-A','high','pedidos de las últimas 2h: líneas no-bonif con costo congelado poblado (centinela del snapshot)',
      (SELECT count(*) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id
        WHERE NOT pi.es_bonificacion AND pi.costo_unitario_al_crear IS NULL AND p.created_at >= now()-interval '2 hours')),
    -- #1043: "sin costo" es costo_valuacion(...) IS NULL con el snapshot de la
    -- línea, lo mismo que deciden los reportes (238, #511); costo_sin_iva
    -- suelto no lo es. La línea 2401 (pedido 895, producto 186, suc. 2) es
    -- legacy: una venta del 2026-03-21 de un producto que nunca se compró;
    -- decisión del dueño (2026-10-09): se excluye la línea, no el producto.
    ('COSTO-B','medium','productos con ventas entregadas valuadas sin costo (inflan margen)',
      (SELECT count(DISTINCT prod.id) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id JOIN productos prod ON prod.id=pi.producto_id
        WHERE p.estado='entregado' AND p.canal<>'cambio' AND COALESCE(p.tipo_factura,'ZZ')<>'VB' AND NOT pi.es_bonificacion AND pi.id<>2401
          AND public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                     prod.costo_sin_iva, prod.impuestos_internos) IS NULL)),
    ('COSTO-C','medium','productos con precio < costo real (venta bajo costo)',
      (SELECT count(*) FROM productos WHERE costo_sin_iva>0 AND precio>0 AND precio < costo_sin_iva*(1+COALESCE(impuestos_internos,0)/100))),
    ('BONIF-A','high','bonificación con subtotal o precio_unitario <> 0',
      (SELECT count(*) FROM pedido_items WHERE es_bonificacion AND (COALESCE(subtotal,0)<>0 OR COALESCE(precio_unitario,0)<>0))),
    ('BONIF-B','medium','item no-bonif con subtotal=0 (venta gratis sin marcar)',
      (SELECT count(*) FROM pedido_items pi JOIN pedidos p ON p.id=pi.pedido_id WHERE NOT pi.es_bonificacion AND COALESCE(pi.subtotal,0)=0 AND p.estado<>'cancelado')),
    ('BONIF-C','medium','promo_ajustes de consumo (Auto-ajuste) sin merma_id',
      (SELECT count(*) FROM promo_ajustes WHERE merma_id IS NULL AND COALESCE(observaciones,'') LIKE 'Auto-ajuste%')),
    ('BONIF-D','medium','promociones con usos_pendientes<0',
      (SELECT count(*) FROM promociones WHERE COALESCE(usos_pendientes,0)<0)),
    ('MERMA-A','high','motivo de merma dentro del CHECK permitido',
      (SELECT count(*) FROM mermas_stock WHERE motivo IS NULL OR motivo NOT IN ('rotura','vencimiento','robo','decomiso','devolucion','error_inventario','muestra','otro','promociones','promociones_reversion'))),
    ('MERMA-B','high','asiento coherente: stock_nuevo = GREATEST(stock_anterior-cantidad,0) | reversión',
      (SELECT count(*) FROM mermas_stock WHERE stock_nuevo <> CASE WHEN cantidad>=0 THEN GREATEST(stock_anterior-cantidad,0) ELSE stock_anterior-cantidad END)),
    ('MERMA-C','medium','toda merma referencia un producto existente',
      (SELECT count(*) FROM mermas_stock m LEFT JOIN productos p ON p.id=m.producto_id WHERE p.id IS NULL)),
    ('MERMA-E','high','cantidad negativa solo en promociones_reversion',
      (SELECT count(*) FROM mermas_stock WHERE cantidad<0 AND motivo<>'promociones_reversion')),
    ('MERMA-H','medium','sin stock_anterior/stock_nuevo negativos',
      (SELECT count(*) FROM mermas_stock WHERE stock_anterior<0 OR stock_nuevo<0)),
    -- #1043: las 96 de abril a septiembre se completaron desde audit_logs.
    ('MERMA-I','medium','mermas reales sin usuario_id',
      (SELECT count(*) FROM mermas_stock WHERE usuario_id IS NULL AND motivo NOT IN ('promociones','promociones_reversion'))),
    -- #1256 · la última fila es la de mayor id, no la de created_at más nuevo.
    -- created_at es la hora de INICIO de la transacción, y el INSERT del
    -- ledger corre con el lock de la fila del producto (trigger AFTER UPDATE):
    -- dentro de un producto, el orden real es el de la secuencia. Por
    -- created_at, cuatro ventas del producto 127 que empezaron en el mismo
    -- milisegundo (31/03/2026, filas 1320 a 1323) quedan desordenadas, y con
    -- varias cajas eso tumbaría overall_ok sin nada roto. La excepción es lo
    -- importado de Taco Pozo (tp_import_id): se grabó con el created_at del
    -- sistema viejo y los ids al revés (producto 186, filas 2949 a 2951).
    -- Siempre precede a lo vivo (medido el 28/10/2026: ninguna fila importada
    -- después de una viva, ni por fecha ni por id), así que lo vivo va primero
    -- por id, y lo importado, sólo si no hay nada vivo, por fecha.
    ('STK-A','critical','productos.stock = última fila de stock_historico (por id; lo importado de Taco Pozo, por fecha)',
      (SELECT count(*) FROM productos p JOIN (SELECT DISTINCT ON (producto_id,sucursal_id) producto_id,sucursal_id,stock_nuevo
        FROM stock_historico
        ORDER BY producto_id,sucursal_id,(tp_import_id IS NULL) DESC,
                 CASE WHEN tp_import_id IS NULL THEN id END DESC NULLS LAST,created_at DESC,id DESC) u
        ON u.producto_id=p.id AND u.sucursal_id=p.sucursal_id WHERE p.stock<>u.stock_nuevo)),
    ('STK-B','critical','ningún producto con stock<0',
      (SELECT count(*) FROM productos WHERE stock<0)),
    ('STK-E','high','sucursal del movimiento = sucursal del producto',
      (SELECT count(*) FROM stock_historico s JOIN productos p ON p.id=s.producto_id WHERE s.sucursal_id<>p.sucursal_id)),
    -- #1043: hasta la fila 30646 son legacy, de caminos que las migs 229, 232,
    -- 240, 245 y la de #1043 etiquetaron (la ficha de producto por REST quedó
    -- como 'ajuste_manual'). Un 'auto' sin referencia nuevo es un camino que
    -- mueve stock sin declarar app.stock_origen.
    -- #1256: high, no info. En info no hacía fallar nada (check-integridad.mjs
    -- corta con critical o high) y STK-F sólo ve subidas, así que una función
    -- que BAJA stock sin etiqueta pasaba CI en verde. Es de runtime: se pone
    -- rojo cuando el camino corre en prod, no cuando se aplica. Si se pone
    -- rojo, se etiqueta el camino y, en la misma migración, se sube el piso de
    -- id a la última fila 'auto' que dejó.
    ('STK-D','high','movimientos origen=auto sin referencia (un camino que mueve stock sin declarar el origen)',
      (SELECT count(*) FROM stock_historico WHERE origen='auto' AND referencia_id IS NULL AND id > 30646)),
    ('CC-A','critical','saldo_cuenta = Σ(total-monto_pagado no cancelados) − Σ(pagos a cuenta sin pedido = saldo a favor)',
      (SELECT count(*) FROM clientes c WHERE abs(COALESCE(c.saldo_cuenta,0) - (
        COALESCE((SELECT sum(p.total-COALESCE(p.monto_pagado,0)) FROM pedidos p
          WHERE p.cliente_id=c.id AND p.estado NOT IN ('cancelado','anulado')),0)
        - COALESCE((SELECT sum(pg.monto) FROM pagos pg WHERE pg.cliente_id=c.id AND pg.pedido_id IS NULL),0)))>0.01)),
    ('CC-PAGOS-CANCEL','high','ningún pago imputado a un pedido cancelado',
      (SELECT count(*) FROM pagos pg JOIN pedidos p ON p.id=pg.pedido_id WHERE p.estado='cancelado')),
    -- #1256 · sin el corte de 30 días: una cobranza FIFO, o un saldo a favor
    -- que se aplica después, imputa a pedidos de cualquier edad, y el
    -- centinela no los veía. Quedan fuera, por id, los 67 de abril-mayo 2026
    -- que la 230 ya dejaba afuera (eran 69; dos se corrigieron después): todos
    -- con monto_pagado y ninguna fila en pagos. Por id y no por fecha, para
    -- que un pedido viejo que hoy cobra mal se vea.
    ('CC-B','high','pedidos donde monto_pagado <> Σ pagos (los 67 de abril-mayo 2026 sin filas en pagos quedan fuera a propósito, mig 230)',
      (SELECT count(*) FROM pedidos p
         JOIN LATERAL (SELECT COALESCE(SUM(pg.monto),0) AS suma FROM pagos pg WHERE pg.pedido_id=p.id) s ON TRUE
        WHERE p.id <> ALL ('{535,536,559,601,606,630,638,639,641,644,716,1063,1083,1107,
                            1114,1120,1167,1198,1200,1204,1240,1241,1275,1279,1320,1332,1333,1341,
                            1362,1363,1364,1365,1368,1369,1370,1371,1372,1374,1376,1378,1380,1381,
                            1382,1385,1386,1387,1388,1389,1390,1391,1392,1395,1396,1397,1411,1415,
                            1423,1429,1441,1442,1449,1452,1458,1462,1478,1491,1510}'::bigint[])
          AND COALESCE(p.tipo_factura,'ZZ') <> 'VB'  /* mig 3XA: un VB no tiene pagos */
          AND abs(COALESCE(p.monto_pagado,0) - s.suma) > 0.01)),
    -- #1256 · sobrepago (#1246): lo cobrado de un pedido no pasa su total. Dos
    -- cobros a la vez sobre el mismo saldo dejaban el excedente atrapado en la
    -- boleta, donde ni aplicar_credito_cliente ni el FIFO lo ven. Todos los
    -- estados: un cancelado tiene total 0 y nada cobrado.
    ('CC-C','high','ningún pedido con monto_pagado > total (#1246)',
      (SELECT count(*) FROM pedidos WHERE COALESCE(monto_pagado,0) > total + 0.005)),
    -- ===== Vale blanco (mig 3XA) =====
    ('VB-A','high','vale blanco coherente: entregado/cancelado/anulado, pagado y monto_pagado = total',
      (SELECT count(*) FROM pedidos WHERE tipo_factura='VB'
         AND NOT (estado IN ('entregado','cancelado','anulado')
                  AND estado_pago IS NOT DISTINCT FROM 'pagado'
                  AND monto_pagado IS NOT DISTINCT FROM total))),
    ('VB-B','high','ningún pago imputado a un vale blanco',
      (SELECT count(*) FROM pagos pg JOIN pedidos p ON p.id=pg.pedido_id WHERE p.tipo_factura='VB')),
    ('VB-C','medium','vale blanco nacido como VB sin transportista (históricos y convertidos quedan fuera a propósito)',
      (SELECT count(*) FROM pedidos p WHERE p.tipo_factura='VB' AND p.transportista_id IS NOT NULL
         AND p.created_at >= '2026-10-08 20:20:19.65559+00'::timestamptz
         AND NOT EXISTS (SELECT 1 FROM pedido_historial ph
                          WHERE ph.pedido_id=p.id AND ph.campo_modificado='tipo_factura'))),
    ('COMPRA-A1','high','compras.total = subtotal+bonificaciones+iva+ii+percepciones+no gravado+otros (mig 195)',
      (SELECT count(*) FROM compras WHERE estado<>'cancelada' AND abs(COALESCE(total,0)-(
        COALESCE(subtotal,0)+COALESCE(bonificaciones,0)+COALESCE(iva,0)+COALESCE(impuestos_internos,0)
        +COALESCE(percepcion_iva,0)+COALESCE(percepcion_iibb,0)
        +COALESCE(no_gravado,0)+COALESCE(otros_impuestos,0)))>1.0)),
    ('COMPRA-A3','high','cargos_unitarios guardado = lo que hoy reparten los cargos no gravados (mig 194)',
      (SELECT count(*) FROM compra_items ci
         JOIN compras c ON c.id=ci.compra_id AND c.estado<>'cancelada'
         LEFT JOIN (
           SELECT r.item_id, sum(r.monto) AS monto
             FROM (SELECT cc.monto AS m,
                          (SELECT jsonb_object_agg(x.compra_item_id::text, x.peso)
                             FROM compra_cargo_repartos x WHERE x.cargo_id=cc.id) AS pesos
                     FROM compra_cargos cc
                     JOIN compras cx ON cx.id=cc.compra_id AND cx.estado<>'cancelada'
                    WHERE cc.condicion_iva<>'gravado' AND cc.prorratea_al_costo) g
             CROSS JOIN LATERAL prorratear_cargo(g.m, g.pesos) r
            GROUP BY r.item_id) rep ON rep.item_id=ci.id
        WHERE abs(COALESCE(rep.monto,0) - COALESCE(ci.cargos_unitarios,0)*ci.cantidad)
              > 0.01 + 0.0001*ci.cantidad)),
    -- #1043: las compras 5, 6, 19, 39 y 40 (ene-mar 2026) son legacy de carga
    -- incompleta: la 40 tiene la cabecera en el doble de sus renglones y la 39
    -- cuenta uno dos veces. Arreglarlas pide la factura física; se excluyen para
    -- que una compra NUEVA desfasada se note.
    ('COMPRA-A2','medium','compras.subtotal = SUM(compra_items.subtotal)',
      (SELECT count(*) FROM compras c JOIN (SELECT compra_id, sum(subtotal) s FROM compra_items GROUP BY compra_id) it ON it.compra_id=c.id
        WHERE c.estado<>'cancelada' AND c.id NOT IN (5,6,19,39,40) AND abs(COALESCE(c.subtotal,0)-it.s)>1.0)),
    ('COMPRA-B','high','compra sin credito fiscal (ZZ, o FC con letra B/C) con iva<>0',
      (SELECT count(*) FROM compras WHERE (tipo_factura='ZZ' OR letra_comprobante IN ('B','C'))
         AND COALESCE(iva,0)<>0 AND estado<>'cancelada')),  /* mig 293 */
    ('COMPRA-C','high','compra_item de compra activa con costo_unitario<=0',
      (SELECT count(*) FROM compra_items ci JOIN compras c ON c.id=ci.compra_id WHERE c.estado<>'cancelada' AND COALESCE(ci.costo_unitario,0)<=0)),
    ('COMPRA-E','medium','bonificación de compra fuera de [0,100)',
      (SELECT count(*) FROM compra_items WHERE bonificacion<0 OR bonificacion>=100)),
    ('COMPRA-G','high','compra_item.sucursal_id = compra.sucursal_id',
      (SELECT count(*) FROM compra_items ci JOIN compras c ON c.id=ci.compra_id WHERE ci.sucursal_id<>c.sucursal_id)),
    ('COMPRA-H','medium','cantidad de compra_item > 0',
      (SELECT count(*) FROM compra_items WHERE cantidad<=0)),
    ('CAMBIO-01','high','pedido canal=cambio debe tener total=0',
      (SELECT count(*) FROM pedidos WHERE canal='cambio' AND total<>0)),
    ('CAMBIO-03','high','cambio 1:1 con recorrido_cambios y sin colgar de venta app',
      (SELECT (SELECT count(*) FROM pedidos p WHERE p.canal='cambio' AND NOT EXISTS (SELECT 1 FROM recorrido_cambios rc WHERE rc.pedido_id=p.id))
            + (SELECT count(*) FROM recorrido_cambios rc JOIN pedidos p ON p.id=rc.pedido_id WHERE p.canal<>'cambio'))),
    -- mig 245 (#633) · el mas importante de los cuatro: desde la 241 la venta
    -- del bot suma al gerencial y comisiona, asi que un pedido 'bot' con
    -- usuario_id fuera de perfiles alimentaria los reportes sin que el check lo
    -- vea. Medido antes de ampliar: 2 y 2 (pedidos 872 y 904, los dos del
    -- canal de la app, de marzo 2026, o sea que ya estaban adentro).
    -- #1043: el 872 y el 904 (suc. 2, 2026-03-25) vienen de la importación de
    -- Taco Pozo (062) y su vendedor no tuvo match. Decisión del dueño
    -- (2026-10-09): quedan sin vendedor y se excluyen.
    ('COMIS-01','medium','venta entregada sin vendedor (usuario_id en perfiles)',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal<>'cambio' AND id NOT IN (872,904) AND (usuario_id IS NULL OR usuario_id NOT IN (SELECT id FROM perfiles)))),
    -- mig 245 (#633) · el issue pedia verificar que escribe
    -- crear_pedido_completo_bot en creado_por antes de tocar este check. Se leyo
    -- el cuerpo VIVO: su INSERT INTO pedidos nombra la columna creado_por y le
    -- pone p_perfil_id --el mismo valor que a usuario_id--, asi que el bot puebla
    -- la atribucion igual que la app y el centinela vale para los dos caminos.
    -- Quedaba afuera por el filtro de canal, no porque el bot dejara la columna
    -- en NULL. Medido antes de ampliar: 0 y 0.
    ('COMIS-05','high','pedidos de venta de últimas 2h con creado_por poblado (centinela de atribución)',
      (SELECT count(*) FROM pedidos WHERE created_at >= now()-interval '2 hours' AND canal<>'cambio' AND creado_por IS NULL)),
    -- ===== Rutas (mig 180) =====
    ('RUTA-A','high','paradas de pedidos entregados que quedaron sin marcar',
      (SELECT count(*) FROM recorrido_pedidos rp JOIN pedidos p ON p.id=rp.pedido_id
        WHERE p.estado='entregado' AND COALESCE(rp.estado_entrega,'pendiente')<>'entregado')),
    ('RUTA-B','high','recorridos con pedidos_entregados/total_cobrado distintos del recalculo',
      (SELECT count(*) FROM recorridos r
         LEFT JOIN LATERAL (
           SELECT COUNT(*) FILTER (WHERE p.estado='entregado') AS ent,
                  COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado='entregado' AND COALESCE(p.tipo_factura,'ZZ')<>'VB'),0) AS cob
             FROM recorrido_pedidos rp JOIN pedidos p ON p.id=rp.pedido_id
            WHERE rp.recorrido_id=r.id) s ON TRUE
        WHERE r.pedidos_entregados IS DISTINCT FROM s.ent
           OR COALESCE(r.total_cobrado,0) IS DISTINCT FROM COALESCE(s.cob,0))),
    ('RUTA-C','medium','paradas de pedidos cancelados/anulados en una ruta en curso',
      (SELECT count(*) FROM recorrido_pedidos rp
         JOIN pedidos p    ON p.id = rp.pedido_id
         JOIN recorridos r ON r.id = rp.recorrido_id
        WHERE p.estado IN ('cancelado','anulado') AND r.estado='en_curso')),
    -- ===== Vencimientos por lote (mig 225) =====
    ('LOTE-A','high','productos donde la suma de los lotes supera el stock',
      (SELECT count(*) FROM (
         SELECT l.producto_id AS pid, l.sucursal_id AS sid,
                SUM(l.cantidad_restante) AS asignado
           FROM producto_lotes l GROUP BY 1,2
       ) a
       JOIN productos p ON p.id=a.pid AND p.sucursal_id=a.sid
      WHERE a.asignado > p.stock)),
    ('LOTE-B','high','lotes con el contador fuera de rango',
      (SELECT count(*) FROM producto_lotes
        WHERE cantidad_restante < 0 OR cantidad_restante > cantidad OR cantidad <= 0)),
    ('LOTE-C','high','lotes cuya sucursal no coincide con la del producto',
      (SELECT count(*) FROM producto_lotes l
         JOIN productos p ON p.id=l.producto_id
        WHERE p.sucursal_id <> l.sucursal_id)),
    -- #1142: la huella en lotes de una linea no supera su cantidad (#1127, y
    -- el tope de anular_salvedad de la misma migracion). Todos los estados.
    ('LOTE-D','high','lineas de pedido cuya huella en lotes supera la cantidad de la linea (#1142)',
      (SELECT count(*) FROM (SELECT pil.pedido_item_id FROM pedido_item_lotes pil
         JOIN pedido_items pi ON pi.id = pil.pedido_item_id
        GROUP BY pil.pedido_item_id, pi.cantidad HAVING SUM(pil.cantidad) > pi.cantidad) x)),
    ('PROMO-A','high','promo_ajustes: ningun (promo, contenedor) devolvio mas fardos de los que se le descontaron (mig 242)',
      (SELECT count(*) FROM (
         SELECT promocion_id, sucursal_id, producto_id
           FROM promo_ajustes
          WHERE producto_id IS NOT NULL
          GROUP BY 1,2,3
         HAVING SUM(COALESCE(unidades_ajustadas,0)) < 0) x)),
    ('SALV-A','high','salvedad anulada con su merma todavia viva (mig 244)',
      (SELECT count(*) FROM mermas_stock m
         JOIN salvedades_items s ON s.id = m.salvedad_id AND s.sucursal_id = m.sucursal_id
        WHERE s.estado_resolucion = 'anulada' AND m.anulada_at IS NULL)),
    ('PROMO-B','high','sustitucion de regalo: el alta descuenta del sustituto, no del original (mig 252, #653)',
      (SELECT count(*) FROM pedido_item_sustituciones s
        WHERE COALESCE(s.regalo_mueve_stock_snapshot, false)
          AND s.producto_original_id <> s.producto_sustituto_id
          -- mig #1090/#1091: una fila de reparto no es un cambio del regalo
          -- de una linea, y un eslabon de una cadena sin linea viva (el
          -- reparto se disolvio, o la promo volvio sin heredar la clave) ya
          -- no describe nada del pedido.
          AND s.reparto_id IS NULL
          AND EXISTS (SELECT 1 FROM pedido_items pi
                       WHERE pi.pedido_id = s.pedido_id AND pi.sucursal_id = s.sucursal_id
                         AND pi.regalo_cadena_id = s.cadena_id)
          AND EXISTS (SELECT 1 FROM stock_historico h
                       WHERE h.referencia_tipo='pedido' AND h.referencia_id=s.pedido_id
                         AND h.sucursal_id=s.sucursal_id AND h.producto_id=s.producto_original_id
                         AND h.origen='pedido_creado' AND h.created_at > s.created_at
                         AND h.diferencia < 0)
          AND NOT EXISTS (SELECT 1 FROM stock_historico h
                       WHERE h.referencia_tipo='pedido' AND h.referencia_id=s.pedido_id
                         AND h.sucursal_id=s.sucursal_id AND h.producto_id=s.producto_sustituto_id
                         AND h.origen='pedido_creado' AND h.created_at > s.created_at
                         AND h.diferencia < 0))),
    -- mig 254: medium y no high a proposito. El barrido corre AL ESCRIBIR
    -- (trg_bot_audit_log_retencion), asi que un bot callado mas de 100 dias
    -- pone esto en rojo sin que haya nada roto. En high eso tumbaba overall_ok
    -- y trababa el merge de cualquier rama por un bot apagado.
    ('BOT-A','medium','bot_audit_log sin filas de mas de 100 dias: la retencion al escribir sigue viva (mig 252, #661)',
      (SELECT count(*) FROM bot_audit_log WHERE created_at < now() - INTERVAL '100 days')),
    ('BOT-B','high','funciones del bot que dejaron de consumir la funcion de la pantalla que muestra el mismo numero (mig 300, #977)',
      (SELECT public.auditoria_bot_sin_funcion_canonica())),
    ('PRECIO-A','high','funciones de public que insertan pedido_items sin pasar por precio_fuera_de_politica (#1139)',
      (SELECT public.auditoria_funciones_pedido_items_sin_piso())),
    ('COSTO-D','high','funciones de public que escriben costo_unitario_al_crear sin pasar por costo_valuacion (mig 238, #673)',
      (SELECT public.auditoria_funciones_costo_sin_valuacion())),
    ('SEG-A','high','funciones SECURITY DEFINER de public que authenticated ejecuta sin chequear el rol (#1009)',
      (SELECT count(*) FROM public.auditoria_definer_sin_rol())),
    ('SEG-B','high','mt_pedidos_select y sus copias en funciones DEFINER dicen lo mismo (#1020)',
      (SELECT count(*) FROM public.auditoria_predicado_pedidos())),
    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',
      (SELECT public.auditoria_funciones_stock_sin_origen())),
    -- mig 282 (#865): medium a proposito. La deriva aparece sola el dia que
    -- entra en vigencia una alicuota futura, hasta que corre refrescar-ii.yml
    -- (Actions lo atrasa horas). En high un cron atrasado tumbaria overall_ok.
    ('II-A','medium','fichas encuadradas con impuestos_internos distinto de la efectiva de hoy (refresco diario, mig 282, #865)',
      (SELECT count(*) FROM productos
        WHERE ii_encuadre_id IS NOT NULL
          AND impuestos_internos IS DISTINCT FROM COALESCE(round(ii_tasa_efectiva(
                ii_encuadre_id, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date), 4), 0))),
    -- #1191 · cada linea de combo de un pedido vivo tiene su foto, su producto
    -- es de un lugar del combo y la suma del lugar no pasa de k x su cantidad
    -- (una salvedad puede bajarla, nunca subirla).
    ('COMBO-A','high','líneas de combo coherentes con la foto del pedido (#1191)',
      (SELECT count(*) FROM pedido_items pi
         JOIN pedidos p ON p.id = pi.pedido_id AND p.sucursal_id = pi.sucursal_id
         LEFT JOIN pedido_combos f
           ON f.pedido_id = pi.pedido_id AND f.combo_id = pi.combo_id AND f.sucursal_id = pi.sucursal_id
         LEFT JOIN LATERAL (SELECT c FROM jsonb_array_elements(f.componentes) c
                             WHERE c->'productos' @> to_jsonb(pi.producto_id) LIMIT 1) lug ON true
        WHERE pi.combo_id IS NOT NULL AND p.estado NOT IN ('cancelado','anulado')
          AND (f.pedido_id IS NULL OR lug.c IS NULL
               OR (SELECT COALESCE(sum(pj.cantidad), 0) FROM pedido_items pj
                    WHERE pj.pedido_id = pi.pedido_id AND pj.combo_id = pi.combo_id
                      AND lug.c->'productos' @> to_jsonb(pj.producto_id))
                  > f.cantidad_combos * (lug.c->>'cantidad')::int))),
    -- #1192 · cada combo de un pedido vivo esta en el punto fijo de la regla de
    -- la salvedad: rehacerlo no moveria nada (los combos vivos, el recargo y
    -- lo que hay en el combo de cada producto son los del plan), y toda linea
    -- que salio de un combo roto tiene la foto de su combo.
    ('COMBO-B','high','combos de pedidos vivos en el reparto que manda la salvedad (#1192)',
      (SELECT count(*) FROM pedido_combos f
         JOIN pedidos p ON p.id = f.pedido_id AND p.sucursal_id = f.sucursal_id
         CROSS JOIN LATERAL (SELECT public._combo_estado(f.pedido_id, f.sucursal_id, f.combo_id, NULL) AS e) x
         CROSS JOIN LATERAL (SELECT public._combo_plan(x.e->'componentes', (x.e->>'armados')::int, x.e->'lineas',
                                                       x.e->'rechazos', x.e->'precios') AS pl) y
        WHERE p.estado NOT IN ('cancelado','anulado')
          AND (y.pl IS NULL
               OR f.cantidad_combos IS DISTINCT FROM (y.pl->>'combos')::int
               OR f.recargo IS DISTINCT FROM (y.pl->>'recargo')::numeric
               OR EXISTS (SELECT 1 FROM jsonb_array_elements(x.e->'lineas') l
                           WHERE (l->>'en_combo')::int
                                 IS DISTINCT FROM (y.pl->'productos'->(l->>'producto_id')->>'en_combo')::int)))
       + (SELECT count(*) FROM pedido_items pi
           WHERE pi.combo_roto_id IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pedido_combos f
                              WHERE f.pedido_id = pi.pedido_id AND f.combo_id = pi.combo_roto_id
                                AND f.sucursal_id = pi.sucursal_id)))
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))
    ORDER BY (viol=0), array_position(ARRAY['critical','high','medium','low','info'], severidad)
  ) INTO v_checks FROM checks;

  SELECT jsonb_build_object(
    'generado_at', now(),
    'overall_ok', NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_checks) c
      WHERE (c->>'ok')::boolean = false AND c->>'severidad' IN ('critical','high')),
    'total_checks', jsonb_array_length(v_checks),
    'con_violaciones', (SELECT count(*) FROM jsonb_array_elements(v_checks) c WHERE (c->>'ok')::boolean = false),
    'critical_high_en_rojo', (SELECT count(*) FROM jsonb_array_elements(v_checks) c WHERE (c->>'ok')::boolean=false AND c->>'severidad' IN ('critical','high')),
    'checks', v_checks
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- ===========================================================================
-- #1256 · auditoria_lectura_authenticated(): para scripts/check-embeds.mjs
-- ===========================================================================
-- El gate de embeds corre con la service_role, que se saltea grants y RLS:
-- un select a una tabla o columna que authenticated no puede leer pasaba
-- verde y en la app tiraba 42501 para todos (la trampa de productos(*), que
-- se concede columna por columna). Esta función le dice qué puede leer
-- authenticated de cada tabla y vista de public (has_column_privilege cuenta
-- también el grant de tabla) y las FKs, para resolver a qué tabla apunta un
-- embed con hint. Es de server: sólo service_role, ni authenticated ni anon.
CREATE OR REPLACE FUNCTION public.auditoria_lectura_authenticated()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'tablas', (
      SELECT COALESCE(jsonb_object_agg(c.relname, jsonb_build_object(
               'columnas', (SELECT COALESCE(jsonb_agg(a.attname ORDER BY a.attnum), '[]'::jsonb)
                              FROM pg_attribute a
                             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
               'legibles', (SELECT COALESCE(jsonb_agg(a.attname ORDER BY a.attnum), '[]'::jsonb)
                              FROM pg_attribute a
                             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                               AND has_column_privilege('authenticated', c.oid, a.attnum, 'SELECT'))
             )), '{}'::jsonb)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
    ),
    'fks', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'nombre',       con.conname,
               'tabla',        cl.relname,
               'columnas',     (SELECT jsonb_agg(a.attname ORDER BY k.ord)
                                  FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                                  JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum),
               'ref_tabla',    rf.relname,
               'ref_columnas', (SELECT jsonb_agg(a.attname ORDER BY k.ord)
                                  FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
                                  JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum)
             ) ORDER BY con.conname), '[]'::jsonb)
        FROM pg_constraint con
        JOIN pg_class cl ON cl.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = cl.relnamespace
        JOIN pg_class rf ON rf.oid = con.confrelid
       WHERE con.contype = 'f' AND n.nspname = 'public'
    )
  );
$function$;

REVOKE ALL ON FUNCTION public.auditoria_lectura_authenticated() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_lectura_authenticated() TO service_role;
