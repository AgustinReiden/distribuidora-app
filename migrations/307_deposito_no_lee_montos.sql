-- #999 · Depósito deja de leer por REST saldos, precios y la política comercial
--
-- La RLS filtra filas, no columnas: con la fila de `clientes` venían
-- `saldo_cuenta` / `limite_credito`, con la de `productos` el `precio`, y con la
-- de `politicas_comerciales` el monto mínimo y las comisiones. Un REVOKE por
-- columna no distingue roles de la app (todos son `authenticated`), así que la
-- palanca es la policy: depósito sale del SELECT de las tres tablas, y lo que
-- necesita para trabajar le llega por RPC sin plata. Decisión del dueño
-- (2026-10-07): depósito no ve montos.
--
-- Depósito por ROL PRINCIPAL (`perfiles.rol`), con el EXISTS inline como todas
-- las policies que lo nombran (no existe es_deposito(), migs 192 y 223). Es un
-- subquery sin correlación: Postgres lo evalúa una vez por consulta, no por fila.
--
-- `compras` / `compra_items` NO se tocan, a propósito: depósito las lee y carga
-- porque es quien recibe la mercadería (migs 192/224). Decisión del dueño.
--
-- Efecto colateral conocido: `mt_productos_update` todavía nombra a depósito
-- (mig 233), pero un UPDATE necesita ver la fila por la policy de SELECT, así
-- que ese permiso queda sin efecto. Ninguna pantalla de depósito actualiza
-- productos por REST; lo que mueve stock desde depósito (lotes) va por RPCs
-- SECURITY DEFINER, que no pasan por esta RLS.

-- 1 · clientes ----------------------------------------------------------------
-- Mismo predicado que antes (preventista: asignado o sin asignar, reservado
-- sólo si le vendió) + depósito afuera. Lo que depósito necesita de un cliente
-- (nombre y dirección para preparar) le llega por hojas_de_ruta_deposito (#782).
ALTER POLICY mt_clientes_select ON public.clientes
  USING (
    (sucursal_id = public.current_sucursal_id())
    AND (
      (NOT EXISTS (SELECT 1 FROM public.perfiles p
                    WHERE p.id = auth.uid() AND p.rol = 'preventista'))
      OR (
        (
          (NOT EXISTS (SELECT 1 FROM public.cliente_preventistas cp WHERE cp.cliente_id = clientes.id))
          OR EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                      WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid())
        )
        AND (
          (NOT clientes.reservado_admin)
          OR EXISTS (SELECT 1 FROM public.pedidos pe
                      WHERE pe.cliente_id = clientes.id AND pe.usuario_id = auth.uid())
        )
      )
    )
    AND NOT EXISTS (SELECT 1 FROM public.perfiles pd
                     WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  );

-- 2 · productos ---------------------------------------------------------------
ALTER POLICY mt_productos_select ON public.productos
  USING (
    sucursal_id = public.current_sucursal_id()
    AND NOT EXISTS (SELECT 1 FROM public.perfiles pd
                     WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  );

-- 3 · politicas_comerciales ---------------------------------------------------
ALTER POLICY mt_politicas_comerciales_select ON public.politicas_comerciales
  USING (
    sucursal_id = public.current_sucursal_id()
    AND NOT EXISTS (SELECT 1 FROM public.perfiles pd
                     WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  );

-- 3b · precios mayoristas -----------------------------------------------------
-- grupo_precio_escalas.precio_unitario y grupo_precio_escala_minimos.
-- precio_unitario_override son precios de venta, igual que productos.precio.
-- Depósito no tiene ninguna pantalla que los lea (las condiciones mayoristas
-- son de admin, puedeAccederCondicionesMayoristas).
ALTER POLICY mt_grupo_precio_escalas_select ON public.grupo_precio_escalas
  USING (
    sucursal_id = public.current_sucursal_id()
    AND NOT EXISTS (SELECT 1 FROM public.perfiles pd
                     WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  );

ALTER POLICY mt_gpem_select ON public.grupo_precio_escala_minimos
  USING (
    sucursal_id = public.current_sucursal_id()
    AND NOT EXISTS (SELECT 1 FROM public.perfiles pd
                     WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  );

-- 3c · el monto mínimo por RPC suelta ------------------------------------------
-- monto_minimo_pedido(sucursal) y pedido_incumple_minimo(total, sucursal) son
-- SECURITY DEFINER sin chequeo de rol y aceptan CUALQUIER sucursal: cualquier
-- sesión leía el mínimo de cualquier sucursal por REST. Sólo las llaman, desde
-- adentro, las RPCs de alta (crear_pedido_completo y _bot), que son DEFINER del
-- mismo dueño y no necesitan EXECUTE del caller. Funciones de server: se
-- revocan a las tres (CLAUDE.md). El front espeja la regla en utils/montoMinimo.ts
-- con el valor de la política, no llamando a estas.
REVOKE EXECUTE ON FUNCTION public.monto_minimo_pedido(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.pedido_incumple_minimo(numeric, bigint) FROM PUBLIC, anon, authenticated;

-- 4 · obtener_resumen_cuenta_cliente ------------------------------------------
-- Copia el predicado de mt_clientes_select (mig 298: "si cambia uno, cambia el
-- otro"). Es SECURITY DEFINER, así que sin esto depósito seguía leyendo saldo,
-- límite y crédito disponible por la RPC.
CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente(p_cliente_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN json_build_object('error', 'No autenticado');
  END IF;

  -- Mismo predicado que la política mt_clientes_select (migs 298 y #999).
  IF NOT EXISTS (
    SELECT 1 FROM clientes c
    WHERE c.id = p_cliente_id
      AND c.sucursal_id = current_sucursal_id()
      AND (
        NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.rol = 'preventista')
        OR (
          (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
            OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                       WHERE cp.cliente_id = c.id AND cp.preventista_id = auth.uid())
          )
          AND (
            NOT c.reservado_admin
            OR EXISTS (SELECT 1 FROM pedidos pe
                       WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())
          )
        )
      )
      AND NOT EXISTS (SELECT 1 FROM perfiles pd WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  ) THEN
    RAISE EXCEPTION 'Cliente % no encontrado o sin permiso para ver su cuenta', p_cliente_id
      USING ERRCODE = '42501';
  END IF;

  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id AND estado_pago != 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos WHERE cliente_id = p_cliente_id),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id)
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente(integer) TO authenticated;

-- 5 · catalogo_deposito(): lo que /productos le muestra a depósito ------------
-- Las columnas de PRODUCTO_COLUMNAS (src/lib/productoColumnas.ts) MENOS las de
-- plata: sin precio, precio_sin_iva, costos, impuestos internos ni IVA.
-- Depósito o admin/encargado (que no la usan, pero no ven nada nuevo); a
-- cualquier otro rol, cero filas, como costos_productos (mig 299).
CREATE OR REPLACE FUNCTION public.catalogo_deposito()
 RETURNS TABLE (
   id bigint,
   nombre text,
   codigo character varying,
   stock integer,
   stock_minimo integer,
   categoria text,
   categoria_id uuid,
   subcategoria_id uuid,
   proveedor_id bigint,
   marca_id uuid,
   unidades_de_venta_por_fardo numeric,
   etiqueta_bulto text,
   unidades_por_bulto integer,
   cantidad_minima_venta integer,
   activo boolean,
   created_at timestamp with time zone,
   updated_at timestamp with time zone
 )
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.id, p.nombre, p.codigo, p.stock, p.stock_minimo, p.categoria,
         p.categoria_id, p.subcategoria_id, p.proveedor_id, p.marca_id,
         p.unidades_de_venta_por_fardo, p.etiqueta_bulto, p.unidades_por_bulto,
         p.cantidad_minima_venta, p.activo, p.created_at, p.updated_at
    FROM public.productos p
   WHERE p.sucursal_id = public.current_sucursal_id()
     AND (public.es_encargado_o_admin()
          OR EXISTS (SELECT 1 FROM public.perfiles pd
                      WHERE pd.id = auth.uid() AND pd.rol = 'deposito'))
   ORDER BY p.nombre;
$function$;

REVOKE EXECUTE ON FUNCTION public.catalogo_deposito() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.catalogo_deposito() TO authenticated;

-- 6 · parametros_vencimiento(): los días de alerta, sin el resto de la política -
-- Lo único que /vencimientos lee de politicas_comerciales. Cualquier sesión de
-- la sucursal: son los mismos números para todos. Sin fila, los defaults de la
-- mig 223 (60 y 15), igual que el front.
CREATE OR REPLACE FUNCTION public.parametros_vencimiento()
 RETURNS TABLE (dias_alerta_vencimiento integer, dias_critico_vencimiento integer)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(pc.dias_alerta_vencimiento, 60), COALESCE(pc.dias_critico_vencimiento, 15)
    FROM (SELECT public.current_sucursal_id() AS sucursal_id) s
    LEFT JOIN public.politicas_comerciales pc ON pc.sucursal_id = s.sucursal_id
   WHERE auth.uid() IS NOT NULL AND s.sucursal_id IS NOT NULL;
$function$;

REVOKE EXECUTE ON FUNCTION public.parametros_vencimiento() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.parametros_vencimiento() TO authenticated;

DO $verif$
DECLARE
  f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.obtener_resumen_cuenta_cliente(integer)',
    'public.catalogo_deposito()',
    'public.parametros_vencimiento()'
  ] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION '#999 · anon puede ejecutar %', f;
    END IF;
    IF NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '#999 · authenticated no puede ejecutar %', f;
    END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
    'public.monto_minimo_pedido(bigint)',
    'public.pedido_incumple_minimo(numeric, bigint)'
  ] LOOP
    IF has_function_privilege('authenticated', f, 'EXECUTE')
       OR has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION '#999 · % sigue alcanzable desde una sesión', f;
    END IF;
  END LOOP;
END
$verif$;
