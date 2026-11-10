-- 480b · El cambio de cliente conserva las líneas de un producto desactivado (VTA-05 de #1513, la parte que
-- esperaba a la tarjeta 3 de #1524).
--
-- QUÉ PASABA
--   Cambiar el cliente de un pedido que tenía un producto desactivado después del alta fallaba:
--   cambiar_cliente_pedido recrea el pedido con crear_pedido_completo, que lo revalida como un alta y rechaza
--   el producto inactivo (mig 284, y también como regalo desde la 289). La edición conserva esas líneas (#945).
--
-- QUÉ CAMBIA
--   crear_pedido_completo, sólo la guarda del producto desactivado: no rechaza un producto que el pedido
--   original ya tenía, vendido o regalado, cuando la llama cambiar_cliente_pedido. La 480 deja ese pedido en
--   app.cambio_cliente_desde mientras crea el nuevo (y lo apaga después), como ya hace validar_precio_item_pedido
--   con el precio de lista. Para el alta, el bot y el replay nada cambia: no prenden esa marca.
--
-- QUÉ NO CAMBIA
--   El resto de crear_pedido_completo (la fecha de la 481 incluida), su firma y sus EXECUTE. Va por ancla sobre
--   el cuerpo que dejó la 481 (tarjeta 3): si la tarjeta 3 lo vuelve a tocar, la premisa frena.
--
-- Ensayo: scripts/test-cambio-cliente-desactivado-1513.sql (corre en prod sin dejar rastro; pide la 480 y la 480b).
-- Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: el cuerpo vivo es el de la 481 y la 480 ya está aplicada
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc
   WHERE oid = 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure;
  IF v_md5 IS DISTINCT FROM 'f28c79fcef03caf37d17f77f686342c3' THEN
    RAISE EXCEPTION 'mig 480b · crear_pedido_completo cambió en prod desde que se leyó (md5 %, esperado f28c79fc…, el de la 481): rehacer sobre la definición vigente', v_md5;
  END IF;
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc
   WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '0768802558d380da8f17fd0c0e6c173c' THEN
    RAISE EXCEPTION 'mig 480b · cambiar_cliente_pedido no es la de la 480 (md5 %): aplicar la 480 primero', v_md5;
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- El parche, por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
DO $parche$
DECLARE
  c_ancla CONSTANT text := $a$    ELSIF NOT v_producto_activo THEN
      errores := array_append(errores, v_producto_nombre || ' está desactivado y no se puede vender');
$a$;
  c_nuevo CONSTANT text := $r$    -- mig 480b (VTA-05, #1513): el cambio de cliente recrea las lineas que el
    -- pedido original ya tenia, vendidas o regaladas (cambiar_cliente_pedido deja
    -- ese pedido en app.cambio_cliente_desde mientras crea el nuevo). No es una
    -- venta nueva, y la edicion tambien conserva esas lineas (#945).
    ELSIF NOT v_producto_activo
          AND NOT EXISTS (SELECT 1 FROM pedido_items o
                           WHERE o.pedido_id = NULLIF(current_setting('app.cambio_cliente_desde', true), '')::bigint
                             AND o.sucursal_id = v_sucursal
                             AND o.producto_id = v_producto_id) THEN
      errores := array_append(errores, v_producto_nombre || ' está desactivado y no se puede vender');
$r$;
  v_def text;
  v_n   int;
BEGIN
  v_def := pg_get_functiondef('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
  v_n := (length(v_def) - length(replace(v_def, c_ancla, ''))) / length(c_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 480b · el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, c_ancla, c_nuevo);
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: el cuerpo es el del repo y los permisos no cambiaron
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_md5 text;
  v_acl text;
BEGIN
  SELECT md5(prosrc), proacl::text || '/' || prosecdef::text INTO v_md5, v_acl FROM pg_proc
   WHERE oid = 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '06de31250f5ef0437f68625f6f46401e'
     OR v_acl IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true' THEN
    RAISE EXCEPTION 'mig 480b · crear_pedido_completo no quedó como en el repo (md5 %, acl %)', v_md5, v_acl;
  END IF;
END
$post$;

COMMIT;
