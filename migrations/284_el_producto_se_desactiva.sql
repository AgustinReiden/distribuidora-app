-- =========================================================================
-- mig 284 · EL PRODUCTO SE DESACTIVA (baja logica de productos)
--
-- Hasta aca un producto que se dejaba de vender tenia dos salidas, las dos
-- malas: dejarlo en el catalogo (y que siguiera apareciendo en el selector
-- de pedidos y en el bot) o borrarlo. Y borrarlo es peor de lo que parece:
-- las FKs de productos son CASCADE sobre compra_items, mermas_stock,
-- salvedades_items, transferencia_items, nota_credito_items, producto_lotes,
-- stock_historico... y SET NULL sobre pedido_items. Un DELETE se llevaba en
-- silencio las compras y mermas valorizadas del producto y dejaba los pedidos
-- con lineas sin producto: los reportes del mes pasado cambiaban de numero.
--
-- Mismo criterio que la baja logica de clientes (CLAUDE.md): el producto
-- inactivo NO se ofrece para operar —selectores de pedido, bot— y SI sigue
-- en todo lo que es historial: reportes, valuacion, lotes, exportes, backup.
--
--   A1 · productos.activo (default true: aplicar esto no cambia nada).
--   A2 · solo admin cambia `activo` (productos_proteger_columnas).
--   A3 · un trigger BEFORE DELETE rechaza borrar productos con historial.
--   A4 · crear_pedido_completo y crear_pedido_completo_bot rechazan vender
--        un inactivo (un cache offline viejo puede encolarlo igual), y
--        bot_productos_recurrentes_cliente deja de sugerirlos.
--   B1 · politicas_comerciales.mostrar_sin_stock (default true = ModalPedido
--        como hoy) y B2 · su RPC de escritura.
--
-- Las funciones existentes se parchean por ancla sobre el cuerpo VIVO de
-- prod (mismo contrato que _mig282_ancla): CREATE OR REPLACE conserva firma,
-- SECURITY DEFINER, search_path y GRANTs. Si un ancla no aparece exactamente
-- una vez, la migracion entera se cae y no se aplica nada.
--
-- NO se toca actualizar_pedido_items (la edicion de un pedido): agregar un
-- producto inactivo editando un pedido existente sigue pasando. Va aparte.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 0 · Helper de cirugia sobre el cuerpo vivo (mismo contrato que _mig282_ancla)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig_producto_activo_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- -------------------------------------------------------------------------
-- A1 · productos.activo
--
-- ADD COLUMN con DEFAULT constante no reescribe la tabla (PG11+). Ninguna
-- funcion de public hace RETURN QUERY SELECT * FROM productos contra un
-- RETURNS TABLE fijo (relevado en prod): las dos que usan productos%ROWTYPE
-- (crear/editar_movimiento_sucursal) se adaptan solas.
-- -------------------------------------------------------------------------
ALTER TABLE public.productos
  ADD COLUMN activo boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.productos.activo IS
  'Baja logica (mig 284). false = no se ofrece para vender (selectores de pedido, '
  'bot, sugerencias) y crear_pedido_completo / crear_pedido_completo_bot lo '
  'rechazan; pero sigue en historial, reportes, valuacion, lotes, exportes y '
  'backup. Solo admin lo cambia (productos_proteger_columnas). Un producto con '
  'historial no se puede borrar: se desactiva (productos_rechazar_borrado_con_historial).';

-- -------------------------------------------------------------------------
-- A2 · Solo admin cambia `activo`
--
-- productos_proteger_columnas es el lugar natural: ya es el BEFORE UPDATE que
-- decide que columnas puede tocar cada rol. Hoy la policy UPDATE deja pasar a
-- admin y a 'deposito', y el trigger ya le bloquea a deposito todo lo que no
-- sea stock / stock_minimo / etiqueta_bulto, asi que en los hechos `activo`
-- ya era de admin. La regla explicita va igual por dos razones: (1) el dia
-- que la policy sume otro rol (encargado, por ejemplo), `activo` no queda
-- abierto por omision; (2) deposito recibe un mensaje que dice que pasa, no
-- la lista generica de columnas bloqueadas.
--
-- Va DESPUES de los tres cortes existentes y los respeta: current_user <>
-- 'authenticated' (service_role, postgres y las RPC SECURITY DEFINER, que
-- corren como postgres) pasa; un UPDATE anidado de otro trigger pasa; admin
-- pasa. Todo lo demas que llegue con una sesion y cambie `activo`, rebota.
-- -------------------------------------------------------------------------
SELECT public._mig_producto_activo_ancla(
  'public.productos_proteger_columnas()'::regprocedure,
  $a$  IF es_admin() THEN
    RETURN NEW;
  END IF;
$a$,
  $a$  IF es_admin() THEN
    RETURN NEW;
  END IF;

  -- mig 284: la baja logica de un producto es solo de admin, sea cual sea el
  -- rol que la policy UPDATE deje pasar.
  IF NEW.activo IS DISTINCT FROM OLD.activo THEN
    RAISE EXCEPTION 'Solo un administrador puede activar o desactivar un producto'
      USING ERRCODE = '42501';
  END IF;
$a$);

-- -------------------------------------------------------------------------
-- A3 · No se borra un producto con historial
--
-- QUE CUENTA COMO HISTORIAL: todo lo que es un hecho economico o fisico que
-- un reporte, la valuacion o una cuenta corriente vuelven a leer:
--   pedido_items .............. ventas (la FK es SET NULL: el pedido quedaba
--                               con una linea sin producto)
--   compra_items .............. compras (CASCADE: se iba la compra valorizada)
--   mermas_stock .............. mermas (CASCADE; cubre tambien promo_ajustes,
--                               que siempre cuelga de una merma)
--   salvedades_items .......... rechazos en la entrega (CASCADE)
--   transferencia_items ....... transferencias (CASCADE)
--   nota_credito_items ........ NC de compra (CASCADE)
--   nota_credito_venta_items .. NC de venta (NO ACTION: ya fallaba, con 23503
--                               crudo)
-- y, porque ya trababan el DELETE con un 23503 sin explicacion (FK NO ACTION),
-- cambios_productos, recorrido_cambios, pedido_item_sustituciones y
-- movimiento_sucursal_items: mejor que el mensaje sea el mismo.
--
-- QUE NO CUENTA:
--   stock_historico · lo escribe registrar_cambio_stock en CUALQUIER UPDATE de
--     stock, incluido corregir a mano la carga inicial de un producto creado
--     por error. Si contara, ningun producto que alguna vez tuvo stock se
--     podria borrar, aunque nunca se haya vendido, comprado ni mermado. Lo que
--     importa del ledger es lo que lo movio, y eso (venta, compra, merma,
--     salvedad, transferencia) ya esta en la lista de arriba. El borrado mismo
--     queda en audit_log (audit_productos).
--   producto_lotes · un lote sale de una compra (que ya cuenta) o de una carga
--     manual de vencimientos; sin ventas ni compras no hay historia que perder.
--   producto_medidas, grupo_precio_*, promocion_productos, promociones,
--     comision_reglas, promo_acumuladores · configuracion, no historia. Ojo:
--     comision_reglas y promo_acumuladores son FK NO ACTION, asi que siguen
--     trabando el DELETE con el 23503 nativo de Postgres.
--
-- SECURITY DEFINER a proposito: el admin borra desde su sucursal y la RLS de
-- las tablas hijas le esconderia filas de otra (movimiento_sucursal_items
-- cruza sucursales). Un trigger no necesita EXECUTE para nadie (lo invoca el
-- executor como parte del DML): queda en postgres + service_role.
--
-- ERRCODE 23503 (foreign_key_violation): es el mismo que ya traduce el front
-- para el borrado de clientes con pedidos (useClientesQuery), y lo que de
-- hecho es: el producto esta referenciado.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.productos_rechazar_borrado_con_historial()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_donde text;
BEGIN
  SELECT string_agg(x.que, ', ' ORDER BY x.orden) INTO v_donde
  FROM (
    SELECT 1 AS orden, 'pedidos' AS que
     WHERE EXISTS (SELECT 1 FROM pedido_items WHERE producto_id = OLD.id)
    UNION ALL
    SELECT 2, 'compras'
     WHERE EXISTS (SELECT 1 FROM compra_items WHERE producto_id = OLD.id)
    UNION ALL
    SELECT 3, 'mermas'
     WHERE EXISTS (SELECT 1 FROM mermas_stock WHERE producto_id = OLD.id)
    UNION ALL
    SELECT 4, 'salvedades'
     WHERE EXISTS (SELECT 1 FROM salvedades_items WHERE producto_id = OLD.id)
    UNION ALL
    SELECT 5, 'transferencias'
     WHERE EXISTS (SELECT 1 FROM transferencia_items WHERE producto_id = OLD.id)
    UNION ALL
    SELECT 6, 'notas de credito de compra'
     WHERE EXISTS (SELECT 1 FROM nota_credito_items WHERE producto_id = OLD.id)
    UNION ALL
    SELECT 7, 'notas de credito de venta'
     WHERE EXISTS (SELECT 1 FROM nota_credito_venta_items WHERE producto_id = OLD.id)
    UNION ALL
    SELECT 8, 'cambios de producto'
     WHERE EXISTS (SELECT 1 FROM cambios_productos
                    WHERE producto_devuelto_id = OLD.id OR producto_entregado_id = OLD.id)
        OR EXISTS (SELECT 1 FROM recorrido_cambios
                    WHERE producto_devuelto_id = OLD.id OR producto_entregado_id = OLD.id)
    UNION ALL
    SELECT 9, 'sustituciones en pedidos'
     WHERE EXISTS (SELECT 1 FROM pedido_item_sustituciones
                    WHERE producto_original_id = OLD.id
                       OR producto_sustituto_id = OLD.id
                       OR ajuste_producto_id_nuevo = OLD.id)
    UNION ALL
    SELECT 10, 'movimientos entre sucursales'
     WHERE EXISTS (SELECT 1 FROM movimiento_sucursal_items
                    WHERE producto_origen_id = OLD.id OR producto_destino_id = OLD.id)
  ) x;

  IF v_donde IS NOT NULL THEN
    RAISE EXCEPTION 'No se puede borrar "%": tiene historial (%). Desactivalo en lugar de borrarlo.',
      OLD.nombre, v_donde
      USING ERRCODE = '23503';
  END IF;

  RETURN OLD;
END;
$fn$;

REVOKE ALL ON FUNCTION public.productos_rechazar_borrado_con_historial() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER productos_rechazar_borrado_con_historial
  BEFORE DELETE ON public.productos
  FOR EACH ROW EXECUTE FUNCTION public.productos_rechazar_borrado_con_historial();

-- -------------------------------------------------------------------------
-- A4 · Al CREAR un pedido, un producto inactivo no se vende
--
-- El selector ya no lo va a ofrecer, pero el telefono puede tener el catalogo
-- en cache (PWA / cola offline) y encolar un pedido con un producto que se
-- desactivo despues. El rechazo va en el mismo loop que ya bloquea cada
-- producto FOR UPDATE y junta los errores en `errores`, asi que llega al
-- preventista con el mismo formato que "stock insuficiente".
--
-- REGALOS (es_bonificacion) EXENTOS, a proposito. El regalo no lo elige el
-- preventista: lo pone la promo (su sabor default, producto_regalo_id). Si el
-- sabor default de una promo se desactiva, rechazar el regalo haria fallar
-- TODO pedido que dispare esa promo, con un mensaje ("X esta desactivado y no
-- se puede vender") que el preventista no puede resolver desde la calle; lo
-- arregla el admin cambiando el sabor de la promo. Dar de regalo un producto
-- discontinuado mientras quede stock es ademas una salida legitima de
-- mercaderia. La red de stock sigue intacta: si el regalo mueve stock y no
-- hay, sigue fallando por "stock insuficiente". Por eso la condicion mira si
-- el producto aparece en alguna linea VENDIDA (no bonificada) del pedido: el
-- mismo producto vendido y regalado en el mismo pedido si se rechaza.
--
-- No cambia COSTO-D (sigue llamando costo_valuacion) ni STK-F (no sube stock).
-- -------------------------------------------------------------------------

-- crear_pedido_completo ---------------------------------------------------
SELECT public._mig_producto_activo_ancla(
  'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure,
  $a$  errores TEXT[] := '{}'; v_user_role TEXT;
$a$,
  $a$  errores TEXT[] := '{}'; v_user_role TEXT;
  v_producto_activo BOOLEAN; -- mig 284
$a$);

SELECT public._mig_producto_activo_ancla(
  'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure,
  $a$    SELECT stock, nombre, costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)
      INTO v_stock_actual, v_producto_nombre, v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
$a$,
  $a$    SELECT stock, nombre, costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21), activo
      INTO v_stock_actual, v_producto_nombre, v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual, v_producto_activo
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    -- mig 284: un inactivo no se vende (un cache offline viejo puede traerlo).
    -- Los regalos quedan exentos: los pone la promo, no el preventista.
    ELSIF NOT v_producto_activo AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_items) e
             WHERE (e->>'producto_id')::INT = v_producto_id
               AND NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)) THEN
      errores := array_append(errores, v_producto_nombre || ' está desactivado y no se puede vender');
$a$);

-- crear_pedido_completo_bot -----------------------------------------------
SELECT public._mig_producto_activo_ancla(
  'public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure,
  $a$  errores TEXT[] := '{}';
$a$,
  $a$  errores TEXT[] := '{}';
  v_producto_activo BOOLEAN; -- mig 284
$a$);

SELECT public._mig_producto_activo_ancla(
  'public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure,
  $a$    SELECT stock, nombre, costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)
      INTO v_stock_actual, v_producto_nombre, v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
$a$,
  $a$    SELECT stock, nombre, costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21), activo
      INTO v_stock_actual, v_producto_nombre, v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual, v_producto_activo
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    -- mig 284: misma regla que crear_pedido_completo. La confirmacion pendiente
    -- puede ser de antes de la baja. Los regalos quedan exentos.
    ELSIF NOT v_producto_activo AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_pendiente.items) e
             WHERE (e->>'producto_id')::INT = v_producto_id
               AND NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)) THEN
      errores := array_append(errores, v_producto_nombre || ' está desactivado y no se puede vender');
$a$);

-- bot_productos_recurrentes_cliente ---------------------------------------
-- Le sugiere al preventista que volver a venderle al cliente: es un camino
-- para OPERAR, asi que un inactivo no se sugiere. El filtro va antes del
-- LIMIT, para que el top N salga de los que se pueden vender. La politica de
-- mostrar_sin_stock NO aplica aca (es de ModalPedido).
SELECT public._mig_producto_activo_ancla(
  'public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)'::regprocedure,
  $a$    FROM items_periodo ip JOIN productos p ON p.id = ip.producto_id
$a$,
  $a$    FROM items_periodo ip JOIN productos p ON p.id = ip.producto_id
    WHERE p.activo -- mig 284: un inactivo no se sugiere para volver a vender
$a$);

DROP FUNCTION public._mig_producto_activo_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- B1 · politicas_comerciales.mostrar_sin_stock
--
-- true = ModalPedido muestra los productos sin stock, como hoy: aplicar esto
-- no le cambia nada a nadie. La fila por sucursal ya existe (mig 204).
-- -------------------------------------------------------------------------
ALTER TABLE public.politicas_comerciales
  ADD COLUMN mostrar_sin_stock boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.politicas_comerciales.mostrar_sin_stock IS
  'Si el selector de productos del pedido (ModalPedido) muestra los productos '
  'sin stock. true = comportamiento previo a la mig 284. Solo es visual: no '
  'cambia la validacion de stock de crear_pedido_completo. Se escribe con '
  'actualizar_mostrar_sin_stock(boolean).';

-- -------------------------------------------------------------------------
-- B2 · actualizar_mostrar_sin_stock: mismo molde que
-- actualizar_monto_minimo_pedido / actualizar_alertas_vencimiento en prod
-- (gate admin/encargado, sucursal activa, sello actualizado_por/en, upsert).
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_mostrar_sin_stock(p_mostrar boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  IF p_mostrar IS NULL THEN
    RAISE EXCEPTION 'Hay que indicar si se muestran o no los productos sin stock';
  END IF;

  INSERT INTO public.politicas_comerciales (sucursal_id, mostrar_sin_stock, actualizado_por, actualizado_en)
  VALUES (v_sucursal, p_mostrar, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET mostrar_sin_stock = EXCLUDED.mostrar_sin_stock,
        actualizado_por   = EXCLUDED.actualizado_por,
        actualizado_en    = EXCLUDED.actualizado_en;

  RETURN p_mostrar;
END;
$function$;

REVOKE ALL ON FUNCTION public.actualizar_mostrar_sin_stock(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_mostrar_sin_stock(boolean) TO authenticated;

-- -------------------------------------------------------------------------
-- V · Verificacion. Si algo de esto falla, no se aplica nada.
--
-- La prueba de comportamiento del borrado corre en un sub-bloque que SIEMPRE
-- termina en excepcion: si el trigger no frenara el DELETE, el CASCADE se
-- desharia igual con el savepoint implicito.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def  text;
  v_prod bigint;
  v_ok   boolean := false;
BEGIN
  -- Columnas: tipo, default y NOT NULL.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'productos'
                    AND column_name = 'activo' AND data_type = 'boolean'
                    AND is_nullable = 'NO' AND column_default = 'true') THEN
    RAISE EXCEPTION 'productos.activo no quedo boolean NOT NULL DEFAULT true';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'politicas_comerciales'
                    AND column_name = 'mostrar_sin_stock' AND data_type = 'boolean'
                    AND is_nullable = 'NO' AND column_default = 'true') THEN
    RAISE EXCEPTION 'politicas_comerciales.mostrar_sin_stock no quedo boolean NOT NULL DEFAULT true';
  END IF;
  IF EXISTS (SELECT 1 FROM public.productos WHERE NOT activo) THEN
    RAISE EXCEPTION 'Hay productos inactivos al aplicar: el default no se aplico';
  END IF;

  -- A2: el trigger de columnas conoce `activo`.
  v_def := pg_get_functiondef('public.productos_proteger_columnas()'::regprocedure);
  IF v_def NOT LIKE '%NEW.activo IS DISTINCT FROM OLD.activo%' THEN
    RAISE EXCEPTION 'productos_proteger_columnas no protege activo';
  END IF;

  -- A4: las dos altas de pedido rechazan inactivos y siguen pasando COSTO-D.
  v_def := pg_get_functiondef('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
  IF v_def NOT LIKE '%v_producto_activo%' OR v_def NOT LIKE '%desactivado y no se puede vender%' THEN
    RAISE EXCEPTION 'crear_pedido_completo no rechaza productos inactivos';
  END IF;
  IF v_def NOT LIKE '%costo_valuacion%' OR v_def NOT LIKE '%app.stock_origen%' THEN
    RAISE EXCEPTION 'crear_pedido_completo perdio costo_valuacion o app.stock_origen (COSTO-D / ledger)';
  END IF;
  v_def := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
  IF v_def NOT LIKE '%v_producto_activo%' OR v_def NOT LIKE '%desactivado y no se puede vender%' THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot no rechaza productos inactivos';
  END IF;
  IF v_def NOT LIKE '%costo_valuacion%' OR v_def NOT LIKE '%app.stock_origen%' THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot perdio costo_valuacion o app.stock_origen (COSTO-D / ledger)';
  END IF;
  v_def := pg_get_functiondef('public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)'::regprocedure);
  IF v_def NOT LIKE '%WHERE p.activo%' THEN
    RAISE EXCEPTION 'bot_productos_recurrentes_cliente sigue sugiriendo productos inactivos';
  END IF;

  -- A3: el trigger existe y es BEFORE DELETE.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.productos'::regclass
                    AND tgname = 'productos_rechazar_borrado_con_historial'
                    AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Falta el trigger productos_rechazar_borrado_con_historial';
  END IF;

  -- Permisos.
  IF has_function_privilege('public', 'public.actualizar_mostrar_sin_stock(boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.actualizar_mostrar_sin_stock(boolean)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.actualizar_mostrar_sin_stock(boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'actualizar_mostrar_sin_stock: permisos mal puestos';
  END IF;
  IF has_function_privilege('public', 'public.productos_rechazar_borrado_con_historial()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.productos_rechazar_borrado_con_historial()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.productos_rechazar_borrado_con_historial()', 'EXECUTE') THEN
    RAISE EXCEPTION 'productos_rechazar_borrado_con_historial: una funcion de trigger no lleva EXECUTE para nadie';
  END IF;
  -- Las parcheadas conservan sus GRANTs (CREATE OR REPLACE no los toca).
  IF has_function_privilege('anon', 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.crear_pedido_completo_bot(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.productos_proteger_columnas()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.productos_proteger_columnas()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Una funcion parcheada cambio de permisos';
  END IF;

  -- Comportamiento del borrado: un producto con ventas no se borra.
  SELECT pi.producto_id INTO v_prod
    FROM public.pedido_items pi WHERE pi.producto_id IS NOT NULL LIMIT 1;
  IF v_prod IS NULL THEN
    RAISE NOTICE 'Sin pedido_items: se salta la prueba de borrado';
    RETURN;
  END IF;

  BEGIN
    BEGIN
      DELETE FROM public.productos WHERE id = v_prod;
      RAISE EXCEPTION 'mig: el DELETE de un producto con ventas no fue rechazado';
    EXCEPTION WHEN foreign_key_violation THEN
      IF SQLERRM NOT LIKE '%Desactivalo en lugar de borrarlo%' THEN
        RAISE EXCEPTION 'El DELETE fallo por otra FK, no por el trigger: %', SQLERRM;
      END IF;
      v_ok := true;
    END;
    RAISE EXCEPTION 'mig_producto_activo_deshacer';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig_producto_activo_deshacer' THEN
      RAISE;
    END IF;
  END;

  IF NOT v_ok OR NOT EXISTS (SELECT 1 FROM public.productos WHERE id = v_prod) THEN
    RAISE EXCEPTION 'La prueba de borrado no dio lo esperado';
  END IF;
END
$verif$;

COMMIT;
