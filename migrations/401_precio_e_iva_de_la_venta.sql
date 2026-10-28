-- NNN · Precio e IVA de la venta (#1257, #1258; tarjeta 5 del plan #1268).
--
-- 1) El precio entra redondeado (#1258, PRC-2). pedido_items.precio_unitario es
--    numeric(10,2), pero las RPCs de venta calculaban el subtotal, el control
--    del total y el desglose con el precio CRUDO del JSON: 10,005 x 100 en FC
--    guardaba precio 10,01 con subtotal 1.000,50, y neto + IVA por unidad daba
--    1.001,00. Ahora el JSON de items se normaliza al entrar con
--    _items_precio_redondeado: un precio con 3 o mas decimales pasa a 2, y todo
--    lo de abajo (control del total, piso/techo, combos, regalos, subtotal y
--    desglose) ve el mismo numero que se guarda. Un precio con 2 decimales o
--    menos no se toca: el JSON queda identico byte a byte. Lo llaman
--    crear_pedido_completo (p_items), actualizar_pedido_items (p_items_nuevos)
--    y crear_pedido_completo_bot (v_pendiente.items). El front ya redondea
--    (parsePrecio/redondear2) y las fuentes de precio del bot son numeric(12,2):
--    para el trafico real es un no-op. Una RPC directa con 10,005 y
--    p_total = 1.000,50 ahora se rechaza por "el total enviado no coincide".
--
-- 2) El IVA de la venta sale de condicion_iva (#1258, PRC-3). La venta hacia
--    COALESCE(porcentaje_iva, 21): un exento cargado sin porcentaje (el CHECK
--    productos_condicion_iva_coherente lo permite) se facturaba al 21%. La regla
--    vive en _alicuota_iva_venta(condicion, porcentaje): exento o no gravado -> 0;
--    gravado -> su porcentaje, y 21 si no tiene (es el default de la columna y
--    el de la ficha: useProductosQuery y claveCondicionIva). Espejo en el front:
--    src/utils/alicuotaIvaVenta.ts (PedidosContainer y ModalEditarPedido).
--    La usan crear_pedido_completo, actualizar_pedido_items,
--    crear_pedido_completo_bot y cambiar_tipo_factura_pedido.
--    Fuera de esta tarjeta quedan, anotadas en #1258: anular_salvedad y
--    registrar_nota_credito_lote (compras) en el server, y en el front
--    ModalCambiarCliente (tarjeta 6) y las pantallas de compra (tarjeta 3).
--
-- 3) cambiar_tipo_factura_pedido respeta la foto del IVA (#1258). Recalculaba
--    con el porcentaje de HOY del producto y pisaba pedido_items.porcentaje_iva.
--    Ahora usa la foto de la linea. Una foto 0 en una linea de venta es ambigua:
--    3.791 lineas anteriores al 2026-07-15 (ZZ, FC y VB) quedaron con el default
--    0 de la columna aunque el producto era gravado al 21. Esas caen a
--    _alicuota_iva_venta del producto, que es lo que hacia antes; una linea de un
--    exento tambien tiene foto 0 y cae a lo mismo mientras el producto siga
--    exento. Rige en los tres caminos (ZZ<->FC, a VB y desde VB).
--
-- 4) La NC de venta guarda su neto y su IVA (#1257, PRC-1).
--    notas_credito_venta.neto / .iva: lo que las lineas acreditadas tenian en el
--    pedido (cantidad x neto_unitario / iva_unitario: la foto), asi una NC por
--    el total de un FC devuelve exactamente el IVA que ese FC debito. Backfill
--    de las 3 NC que habia (todas sobre ZZ, IVA 0) desde sus lineas.
--    cambiar_tipo_factura_pedido ZZ<->FC ahora exige que no haya NC vigente
--    (como ya lo exigia el paso a VB): con el comprobante cambiado debajo, la NC
--    descontaria un IVA que el pedido ya no declara, o no descontaria el que
--    ahora declara.
--
-- 5) posicion_fiscal descuenta las NC de venta (#1257). Por la fecha de la NOTA
--    (como las de compra, mig 280), no anuladas, sobre pedidos que hoy cuentan
--    como venta (entregado, canal <> 'cambio'): fc_venta, fc_neto e iva_debito
--    restan las NC de FC; zz_venta resta las de ZZ (si no, pct_fc compararia una
--    venta FC neta contra una ZZ bruta). Informa aparte nc_fc_notas,
--    nc_fc_monto, nc_fc_neto, nc_fc_iva y nc_zz_monto.
--
-- No toca auditoria_integridad() (el check de neto + IVA = total lo arma la
-- tarjeta 4) ni las funciones de combos y promos (tarjeta 6). Los wrappers que
-- SEG-A tiene por md5 (crear_nota_credito_venta, crear_pedido_idempotente) no
-- cambian.
--
-- Ensayo: scripts/test-precio-iva-venta-1257-1258.sql.

-- ---------------------------------------------------------------------------
-- 1 · Helpers de server
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._alicuota_iva_venta(p_condicion text, p_porcentaje numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $fn$
  SELECT CASE WHEN p_condicion IN ('exento', 'no_gravado') THEN 0::numeric
              ELSE COALESCE(p_porcentaje, 21) END
$fn$;

COMMENT ON FUNCTION public._alicuota_iva_venta(text, numeric) IS
  'Alicuota de IVA con que se vende un producto: exento o no gravado -> 0; '
  'gravado -> su porcentaje (21 si no tiene). Espejo: src/utils/alicuotaIvaVenta.ts. #1258.';

CREATE OR REPLACE FUNCTION public._items_precio_redondeado(p_items jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $fn$
  SELECT CASE
    WHEN p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN p_items
    ELSE (
      SELECT COALESCE(jsonb_agg(
               CASE WHEN jsonb_typeof(x.e) = 'object'
                     AND jsonb_typeof(x.e->'precio_unitario') IN ('number', 'string')
                     AND x.e->>'precio_unitario' ~ '^\s*-?[0-9]*\.[0-9]{3,}\s*$'
                    THEN jsonb_set(x.e, '{precio_unitario}',
                                   to_jsonb(round((x.e->>'precio_unitario')::numeric, 2)))
                    ELSE x.e END
               ORDER BY x.o), '[]'::jsonb)
        FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, o))
  END
$fn$;

COMMENT ON FUNCTION public._items_precio_redondeado(jsonb) IS
  'Items de venta con precio_unitario a 2 decimales (lo que guarda pedido_items). '
  'Un precio con 2 decimales o menos no se toca. #1258.';

-- Funciones de server: las llaman RPCs DEFINER (como su dueno). Nadie de la API.
REVOKE ALL ON FUNCTION public._alicuota_iva_venta(text, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._items_precio_redondeado(jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2 · notas_credito_venta: neto e IVA
-- ---------------------------------------------------------------------------
ALTER TABLE public.notas_credito_venta
  ADD COLUMN IF NOT EXISTS neto numeric,
  ADD COLUMN IF NOT EXISTS iva  numeric NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.notas_credito_venta.neto IS
  'Neto acreditado: SUM(cantidad x neto_unitario) de las lineas del pedido (la foto). #1257.';
COMMENT ON COLUMN public.notas_credito_venta.iva IS
  'IVA acreditado: SUM(cantidad x iva_unitario) de las lineas del pedido. Lo resta posicion_fiscal. #1257.';

-- Backfill: al aplicar habia 3 NC, todas sobre ZZ (IVA 0), con sus lineas vivas.
UPDATE public.notas_credito_venta n
   SET neto = s.neto, iva = s.iva
  FROM (
    SELECT i.nota_credito_id,
           round(SUM(i.cantidad * COALESCE(pi.neto_unitario, i.precio_unitario - COALESCE(pi.iva_unitario, 0))), 2) AS neto,
           round(SUM(i.cantidad * COALESCE(pi.iva_unitario, 0)), 2) AS iva
      FROM public.nota_credito_venta_items i
      LEFT JOIN public.pedido_items pi ON pi.id = i.pedido_item_id AND pi.sucursal_id = i.sucursal_id
     GROUP BY i.nota_credito_id
  ) s
 WHERE s.nota_credito_id = n.id AND n.neto IS NULL;
-- Una NC sin items no deberia existir (la RPC exige uno); por las dudas, todo neto.
UPDATE public.notas_credito_venta SET neto = total - iva WHERE neto IS NULL;

ALTER TABLE public.notas_credito_venta ALTER COLUMN neto SET NOT NULL;
ALTER TABLE public.notas_credito_venta DROP CONSTRAINT IF EXISTS notas_credito_venta_desglose_no_negativo;
ALTER TABLE public.notas_credito_venta
  ADD CONSTRAINT notas_credito_venta_desglose_no_negativo CHECK (neto >= 0 AND iva >= 0);

-- ---------------------------------------------------------------------------
-- 3 · Parches por ancla sobre la definicion viva
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.prciva_parchar(p_def text, p_viejo text, p_nuevo text, p_que text, p_veces int DEFAULT 1)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_veces int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF v_veces <> p_veces THEN
    RAISE EXCEPTION '%: el ancla aparece % veces (se esperaba %). El cuerpo vivo cambio: revisar a mano', p_que, v_veces, p_veces;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- 3a · crear_pedido_completo (web, replay offline, cambiar_cliente_pedido)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.prciva_parchar(v_def,
$q$  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;$q$,
$q$  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  -- #1258: el precio entra a 2 decimales, lo que guarda pedido_items. Todo lo
  -- de abajo (el total, el piso/techo, los combos, el subtotal y el desglose)
  -- ve el mismo numero que se guarda.
  p_items := public._items_precio_redondeado(p_items);$q$,
    'crear_pedido_completo: precio redondeado');

  v_def := pg_temp.prciva_parchar(v_def,
$q$COALESCE(porcentaje_iva, 21), activo$q$,
$q$public._alicuota_iva_venta(condicion_iva, porcentaje_iva), activo -- #1258$q$,
    'crear_pedido_completo: alicuota');

  EXECUTE v_def;
END
$patch$;

-- 3b · actualizar_pedido_items (edicion)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text)'::regprocedure);
BEGIN
  v_def := pg_temp.prciva_parchar(v_def,
$q$  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se pudo determinar la sucursal activa']);
  END IF;$q$,
$q$  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se pudo determinar la sucursal activa']);
  END IF;
  -- #1258: el precio entra a 2 decimales, lo que guarda pedido_items.
  p_items_nuevos := public._items_precio_redondeado(p_items_nuevos);$q$,
    'actualizar_pedido_items: precio redondeado');

  v_def := pg_temp.prciva_parchar(v_def,
$q$COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)$q$,
$q$COALESCE(impuestos_internos, 0), public._alicuota_iva_venta(condicion_iva, porcentaje_iva) -- #1258$q$,
    'actualizar_pedido_items: alicuota');

  EXECUTE v_def;
END
$patch$;

-- 3c · crear_pedido_completo_bot (Telegram, siempre ZZ)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.prciva_parchar(v_def,
$q$  IF v_pendiente.perfil_id <> p_perfil_id THEN RETURN jsonb_build_object('success', false, 'error', 'Confirmación no pertenece al usuario'); END IF;$q$,
$q$  IF v_pendiente.perfil_id <> p_perfil_id THEN RETURN jsonb_build_object('success', false, 'error', 'Confirmación no pertenece al usuario'); END IF;
  -- #1258: el precio entra a 2 decimales, lo que guarda pedido_items.
  v_pendiente.items := public._items_precio_redondeado(v_pendiente.items);$q$,
    'crear_pedido_completo_bot: precio redondeado');

  v_def := pg_temp.prciva_parchar(v_def,
$q$COALESCE(porcentaje_iva, 21), activo$q$,
$q$public._alicuota_iva_venta(condicion_iva, porcentaje_iva), activo -- #1258$q$,
    'crear_pedido_completo_bot: alicuota');

  EXECUTE v_def;
END
$patch$;

-- 3d · cambiar_tipo_factura_pedido: la foto del IVA de la linea, y ZZ<->FC no
-- pasa por debajo de una NC vigente.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)'::regprocedure);
BEGIN
  -- Los tres caminos (a VB, desde VB y ZZ<->FC).
  v_def := pg_temp.prciva_parchar(v_def,
$q$COALESCE(pr.porcentaje_iva, 21) AS pct_iva$q$,
$q$COALESCE(NULLIF(pi.porcentaje_iva, 0), public._alicuota_iva_venta(pr.condicion_iva, pr.porcentaje_iva)) AS pct_iva /* #1258: la foto */$q$,
    'cambiar_tipo_factura_pedido: foto del IVA', 3);

  v_def := pg_temp.prciva_parchar(v_def,
$q$  -- ===================================================== ZZ ↔ FC (como antes)$q$,
$q$  -- #1257: la NC guarda el IVA de las lineas que acredita, con el comprobante
  -- con que se emitio. Cambiarlo debajo la dejaria descontando un IVA que el
  -- pedido ya no declara, o sin descontar el que ahora declara.
  IF public.nota_credito_vigente_de_pedido(p_pedido_id) IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido tiene la nota de crédito #' || public.nota_credito_vigente_de_pedido(p_pedido_id)
      || ' vigente: anulala primero');
  END IF;

  -- ===================================================== ZZ ↔ FC (como antes)$q$,
    'cambiar_tipo_factura_pedido: NC vigente');

  EXECUTE v_def;
END
$patch$;

-- 3e · crear_nota_credito_venta_impl: neto e IVA de lo acreditado. El wrapper
-- (crear_nota_credito_venta, md5 en SEG-A) no cambia.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.prciva_parchar(v_def,
$q$  v_total     numeric := 0;$q$,
$q$  v_total     numeric := 0;
  v_neto      numeric := 0; -- #1257
  v_iva       numeric := 0;$q$,
    'crear_nota_credito_venta_impl: declaracion');

  v_def := pg_temp.prciva_parchar(v_def,
$q$           pi.precio_unitario,
           COALESCE(pi.es_bonificacion, false) AS es_bonif,$q$,
$q$           pi.precio_unitario,
           pi.neto_unitario,
           pi.iva_unitario,
           COALESCE(pi.es_bonificacion, false) AS es_bonif,$q$,
    'crear_nota_credito_venta_impl: lectura de la linea');

  v_def := pg_temp.prciva_parchar(v_def,
$q$    v_total := v_total + v_it.cantidad_txt::integer * COALESCE(v_it.precio_unitario, 0);$q$,
$q$    v_total := v_total + v_it.cantidad_txt::integer * COALESCE(v_it.precio_unitario, 0);
    -- #1257: la foto de la linea (lo que el pedido declaro por esas unidades).
    v_iva  := v_iva  + v_it.cantidad_txt::integer * COALESCE(v_it.iva_unitario, 0);
    v_neto := v_neto + v_it.cantidad_txt::integer
                       * COALESCE(v_it.neto_unitario, COALESCE(v_it.precio_unitario, 0) - COALESCE(v_it.iva_unitario, 0));$q$,
    'crear_nota_credito_venta_impl: acumulado');

  v_def := pg_temp.prciva_parchar(v_def,
$q$    sucursal_id, cliente_id, pedido_id, fecha, motivo, observaciones, total, usuario_id
  ) VALUES ($q$,
$q$    sucursal_id, cliente_id, pedido_id, fecha, motivo, observaciones, total, usuario_id,
    neto, iva
  ) VALUES ($q$,
    'crear_nota_credito_venta_impl: columnas del INSERT');

  v_def := pg_temp.prciva_parchar(v_def,
$q$    v_total, v_user
  ) RETURNING id INTO v_nc_id;$q$,
$q$    v_total, v_user,
    round(v_neto, 2), round(v_iva, 2)
  ) RETURNING id INTO v_nc_id;$q$,
    'crear_nota_credito_venta_impl: valores del INSERT');

  v_def := pg_temp.prciva_parchar(v_def,
$q$    'total', v_total,$q$,
$q$    'total', v_total,
    'neto', round(v_neto, 2),
    'iva', round(v_iva, 2),$q$,
    'crear_nota_credito_venta_impl: respuesta');

  EXECUTE v_def;
END
$patch$;

-- 3f · posicion_fiscal: las NC de venta bajan la venta y el debito.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure);
BEGIN
  v_def := pg_temp.prciva_parchar(v_def,
$q$  v_fc AS ($q$,
$q$  -- #1257: notas de credito de venta por la fecha de la NOTA (como las de
  -- compra, mig 280), no anuladas, sobre pedidos que hoy cuentan como venta.
  -- Neto e IVA son los que guardo la NC (la foto de las lineas acreditadas).
  nc_v AS (
    SELECT COUNT(*) FILTER (WHERE COALESCE(p.tipo_factura, 'ZZ') = 'FC') AS fc_notas,
           COALESCE(SUM(n.total) FILTER (WHERE COALESCE(p.tipo_factura, 'ZZ') = 'FC'), 0) AS fc_monto,
           COALESCE(SUM(n.neto)  FILTER (WHERE COALESCE(p.tipo_factura, 'ZZ') = 'FC'), 0) AS fc_neto,
           COALESCE(SUM(n.iva)   FILTER (WHERE COALESCE(p.tipo_factura, 'ZZ') = 'FC'), 0) AS fc_iva,
           COALESCE(SUM(n.total) FILTER (WHERE COALESCE(p.tipo_factura, 'ZZ') = 'ZZ'), 0) AS zz_monto
      FROM notas_credito_venta n
      JOIN pedidos p ON p.id = n.pedido_id AND p.sucursal_id = n.sucursal_id
     WHERE NOT n.anulada
       AND n.sucursal_id = ANY(v_sucursales)
       AND n.fecha BETWEEN p_desde AND p_hasta
       AND p.estado = 'entregado' AND p.canal <> 'cambio'
  ),
  v_fc AS ($q$,
    'posicion_fiscal: CTE de NC');

  v_def := pg_temp.prciva_parchar(v_def,
$q$           COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'), 0) AS fc_venta,$q$,
$q$           COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'), 0) - (SELECT fc_monto FROM nc_v) AS fc_venta,$q$,
    'posicion_fiscal: fc_venta');

  v_def := pg_temp.prciva_parchar(v_def,
$q$           COALESCE(SUM(total_neto) FILTER (WHERE tipo_factura='FC'), 0) AS fc_neto,$q$,
$q$           COALESCE(SUM(total_neto) FILTER (WHERE tipo_factura='FC'), 0) - (SELECT fc_neto FROM nc_v) AS fc_neto,$q$,
    'posicion_fiscal: fc_neto');

  v_def := pg_temp.prciva_parchar(v_def,
$q$           COALESCE(SUM(total_iva) FILTER (WHERE tipo_factura='FC'), 0) AS iva_debito,$q$,
$q$           COALESCE(SUM(total_iva) FILTER (WHERE tipo_factura='FC'), 0) - (SELECT fc_iva FROM nc_v) AS iva_debito,$q$,
    'posicion_fiscal: iva_debito');

  v_def := pg_temp.prciva_parchar(v_def,
$q$           COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'), 0) AS zz_venta,$q$,
$q$           COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'), 0) - (SELECT zz_monto FROM nc_v) AS zz_venta,$q$,
    'posicion_fiscal: zz_venta');

  v_def := pg_temp.prciva_parchar(v_def,
$q$        'iva_debito', v.iva_debito, 'ii_ventas_fc', f.ii_ventas,$q$,
$q$        'iva_debito', v.iva_debito, 'ii_ventas_fc', f.ii_ventas,
        'nc_fc_notas', n.fc_notas, 'nc_fc_monto', n.fc_monto, 'nc_fc_neto', n.fc_neto,
        'nc_fc_iva', n.fc_iva, 'nc_zz_monto', n.zz_monto,$q$,
    'posicion_fiscal: salida');

  v_def := pg_temp.prciva_parchar(v_def,
$q$      FROM ventas v, v_fc f),$q$,
$q$      FROM ventas v, v_fc f, nc_v n),$q$,
    'posicion_fiscal: FROM de la salida');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · Verificacion (sin llamar a auditoria_integridad: es cara y la corre el ensayo)
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_fn  text;
  v_def text;
  v_acl text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['crear_pedido_completo', 'actualizar_pedido_items', 'crear_pedido_completo_bot',
                              'cambiar_tipo_factura_pedido', 'crear_nota_credito_venta_impl', 'posicion_fiscal'] LOOP
    SELECT pg_get_functiondef(p.oid), array_to_string(p.proacl, ',') INTO v_def, v_acl
      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_def NOT LIKE '%#1257%' AND v_def NOT LIKE '%#1258%' THEN
      RAISE EXCEPTION '% no quedo parcheada', v_fn;
    END IF;
    IF v_def ~ 'COALESCE\((pr\.)?porcentaje_iva, 21\)' THEN
      RAISE EXCEPTION '% sigue inventando el 21%%', v_fn;
    END IF;
    IF v_acl IS NOT NULL AND (v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' OR v_acl LIKE '%anon=%') THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC o anon: %', v_fn, v_acl;
    END IF;
  END LOOP;

  -- Los helpers: nadie de la API.
  FOREACH v_fn IN ARRAY ARRAY['public._alicuota_iva_venta(text, numeric)',
                              'public._items_precio_redondeado(jsonb)'] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE')
       OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                   WHERE p.oid = v_fn::regprocedure AND a.grantee = 0) THEN
      RAISE EXCEPTION '% es alcanzable desde la API', v_fn;
    END IF;
  END LOOP;

  -- Humo de los helpers.
  IF public._alicuota_iva_venta('exento', NULL) <> 0
     OR public._alicuota_iva_venta('no_gravado', 0) <> 0
     OR public._alicuota_iva_venta('gravado', NULL) <> 21
     OR public._alicuota_iva_venta('gravado', 10.5) <> 10.5 THEN
    RAISE EXCEPTION '_alicuota_iva_venta no da la regla';
  END IF;
  IF public._items_precio_redondeado('[{"precio_unitario": 10.005, "cantidad": 100}]')->0->>'precio_unitario' <> '10.01'
     OR public._items_precio_redondeado('[{"precio_unitario": "10.004"}]')->0->>'precio_unitario' <> '10.00'
     OR public._items_precio_redondeado('[{"precio_unitario": 10}, {"precio_unitario": 7.5}]')
        IS DISTINCT FROM '[{"precio_unitario": 10}, {"precio_unitario": 7.5}]'::jsonb
     OR public._items_precio_redondeado(NULL) IS NOT NULL
     OR public._items_precio_redondeado('{}'::jsonb) IS DISTINCT FROM '{}'::jsonb THEN
    RAISE EXCEPTION '_items_precio_redondeado no redondea solo lo que tiene que redondear';
  END IF;

  -- Las NC quedaron con su desglose.
  IF EXISTS (SELECT 1 FROM public.notas_credito_venta WHERE neto IS NULL) THEN
    RAISE EXCEPTION 'notas_credito_venta: quedaron NC sin neto';
  END IF;
  IF has_column_privilege('anon', 'public.notas_credito_venta', 'iva', 'SELECT')
     OR has_column_privilege('authenticated', 'public.notas_credito_venta', 'iva', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.notas_credito_venta', 'iva', 'INSERT') THEN
    RAISE EXCEPTION 'notas_credito_venta.iva tiene un grant de mas';
  END IF;

  -- El wrapper de la NC sigue exento en SEG-A con su md5 (no se toco).
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() WHERE firma LIKE 'crear_nota_credito_venta(%') THEN
    RAISE EXCEPTION 'crear_nota_credito_venta quedo en rojo en SEG-A';
  END IF;
END
$verif$;

-- ROLLBACK: volver a aplicar las definiciones vivas antes de esta migracion de
-- crear_pedido_completo, actualizar_pedido_items, crear_pedido_completo_bot,
-- cambiar_tipo_factura_pedido, crear_nota_credito_venta_impl y posicion_fiscal
-- (sacarlas de pg_get_functiondef de un backup, o deshacer cada ancla de la
-- seccion 3 a mano); DROP de _alicuota_iva_venta y _items_precio_redondeado;
-- DROP CONSTRAINT notas_credito_venta_desglose_no_negativo y DROP COLUMN
-- notas_credito_venta.neto / .iva. Ninguna fila de pedidos ni de pedido_items
-- se toca.
