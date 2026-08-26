-- Compra minima en $ por pedido, configurable por sucursal
--
-- EL PEDIDO
-- ---------
-- "Poder configurar una compra minima en $ para todos los pedidos, que no quede
-- hardcodeado porque es una politica cambiante."
--
-- POR QUE POR SUCURSAL Y NO UN NUMERO GLOBAL
-- ------------------------------------------
-- Medido sobre los ultimos 90 dias, pedidos no cancelados:
--   Sucursal 1 (Tucuman)   2051 pedidos, mediana $22.200, p05 $9.220
--   Sucursal 2 (Taco Pozo)  852 pedidos, mediana $35.750, p05 $11.100
-- Un minimo unico de $10.000 habria frenado 147 pedidos en Tucuman (7%) y 26 en
-- Taco Pozo (3%). La misma cifra pega muy distinto en cada una, asi que un solo
-- numero global obliga a elegir entre quedarse corto en una o apretar de mas en
-- la otra.
--
-- POR QUE UNA TABLA Y NO UNA COLUMNA EN `sucursales`
-- --------------------------------------------------
-- `sucursales` es la tabla de identidad (nombre, direccion, tipo). La politica
-- comercial cambia seguido y la escribe otra gente: para que un encargado mueva
-- el minimo habria que darle UPDATE sobre la fila de identidad de la sucursal,
-- que es bastante mas de lo que se quiere. Aparte, cada politica nueva seria una
-- columna mas en una tabla que no es sobre eso.
--
-- POR QUE TIPADA Y NO CLAVE-VALOR EN JSONB
-- ----------------------------------------
-- Una tabla `configuracion(clave, valor jsonb)` es tentadora por lo extensible,
-- pero pierde el CHECK y el tipo: nada impide guardar un minimo negativo o un
-- string. Y este repo NO tiene tipos generados de la base (se escriben a mano),
-- asi que una clave mal escrita no la atrapa ni tsc, ni eslint, ni los tests --
-- se descubre en produccion cuando el minimo resulta ser NULL y no frena nada.
-- Una tabla angosta y tipada da CHECK, tipo y auditoria; sumar una politica
-- manana es una columna con su propio CHECK.
--
-- ARRANCA EN 0 = SIN POLITICA
-- ---------------------------
-- El seed pone 0 en todas las sucursales, que es exactamente la regla de hoy.
-- Aplicar esta migracion no le cambia el comportamiento a nadie: recien cuando
-- alguien carga un numero desde la pantalla de configuracion empieza a regir.
-- Es a proposito -- 736 pedidos de Tucuman en 90 dias estan por debajo de
-- $20.000, asi que un minimo mal elegido frena la operacion de una.
--
-- La validacion en si NO va aca: va en la mig 205, en el alta del pedido.

BEGIN;

CREATE TABLE IF NOT EXISTS public.politicas_comerciales (
  sucursal_id          bigint PRIMARY KEY REFERENCES public.sucursales(id) ON DELETE CASCADE,
  monto_minimo_pedido  numeric(12,2) NOT NULL DEFAULT 0
                       CHECK (monto_minimo_pedido >= 0),
  actualizado_por      uuid REFERENCES public.perfiles(id) ON DELETE SET NULL,
  actualizado_en       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.politicas_comerciales IS
  'Politica comercial por sucursal. Una fila por sucursal. Tipada a proposito '
  '(no clave-valor): el repo no tiene tipos generados de la base, asi que una '
  'clave mal escrita en un jsonb no la atraparia nada. mig 204.';

COMMENT ON COLUMN public.politicas_comerciales.monto_minimo_pedido IS
  'Monto minimo en $ que debe alcanzar un pedido para poder crearse. 0 = sin '
  'minimo (el valor con el que arranca todo). Se valida al CREAR el pedido, '
  'nunca como CHECK sobre pedidos.total: cancelar un pedido lo pone en 0 y el '
  'invariante VENTA-I exige que asi sea. mig 204/205.';

-- Una fila por sucursal, incluida la inactiva: si manana se reactiva, tiene su
-- politica y no hay que acordarse de crearla.
INSERT INTO public.politicas_comerciales (sucursal_id, monto_minimo_pedido)
SELECT s.id, 0 FROM public.sucursales s
ON CONFLICT (sucursal_id) DO NOTHING;

ALTER TABLE public.politicas_comerciales ENABLE ROW LEVEL SECURITY;

-- SELECT abierto a authenticated de la sucursal activa: lo necesita CUALQUIERA
-- que cargue un pedido, para poder avisar antes de confirmar en vez de comerse
-- el rechazo del servidor. Escritura solo admin/encargado.
-- Cuatro policies separadas y no una FOR ALL, por el criterio de la mig 192: una
-- FOR ALL que solo mirara la sucursal le daria escritura a preventistas.
DROP POLICY IF EXISTS mt_politicas_comerciales_select ON public.politicas_comerciales;
CREATE POLICY mt_politicas_comerciales_select ON public.politicas_comerciales
  FOR SELECT TO authenticated
  USING (sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS mt_politicas_comerciales_update ON public.politicas_comerciales;
CREATE POLICY mt_politicas_comerciales_update ON public.politicas_comerciales
  FOR UPDATE TO authenticated
  USING      (public.es_encargado_o_admin() AND sucursal_id = public.current_sucursal_id())
  WITH CHECK (public.es_encargado_o_admin() AND sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS mt_politicas_comerciales_insert ON public.politicas_comerciales;
CREATE POLICY mt_politicas_comerciales_insert ON public.politicas_comerciales
  FOR INSERT TO authenticated
  WITH CHECK (public.es_encargado_o_admin() AND sucursal_id = public.current_sucursal_id());

-- Sin policy de DELETE: una sucursal siempre tiene politica. Borrar la fila
-- dejaria el minimo indefinido, que no es un estado que queramos representar.

GRANT SELECT, INSERT, UPDATE ON public.politicas_comerciales TO authenticated;

-- ---------------------------------------------------------------------------
-- Lectura para el motor SQL y para el bot.
--
-- STABLE y no VOLATILE: se llama una vez por alta de pedido y el planner puede
-- cachearla dentro de la sentencia. Devuelve 0 (no NULL) cuando no hay fila:
-- "sin politica" y "sin fila" son lo mismo, y un NULL se propagaria a la
-- comparacion y la volveria NULL -- o sea, no frenaria nada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.monto_minimo_pedido(p_sucursal_id bigint)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    (SELECT pc.monto_minimo_pedido
       FROM public.politicas_comerciales pc
      WHERE pc.sucursal_id = p_sucursal_id),
    0
  );
$$;

COMMENT ON FUNCTION public.monto_minimo_pedido(bigint) IS
  'Minimo vigente de la sucursal, o 0 si no hay fila. mig 204.';

REVOKE ALL ON FUNCTION public.monto_minimo_pedido(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.monto_minimo_pedido(bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Escritura desde la pantalla de configuracion.
--
-- Va por RPC y no por UPDATE directo para poder sellar `actualizado_por` con
-- auth.uid() del lado del servidor: si lo mandara el cliente, seria un dato que
-- el cliente elige, y entonces la auditoria no auditaria nada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_monto_minimo_pedido(p_monto numeric)
RETURNS numeric
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $$
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

  IF p_monto IS NULL OR p_monto < 0 THEN
    RAISE EXCEPTION 'El monto minimo no puede ser negativo';
  END IF;

  INSERT INTO public.politicas_comerciales (sucursal_id, monto_minimo_pedido, actualizado_por, actualizado_en)
  VALUES (v_sucursal, p_monto, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET monto_minimo_pedido = EXCLUDED.monto_minimo_pedido,
        actualizado_por     = EXCLUDED.actualizado_por,
        actualizado_en      = EXCLUDED.actualizado_en;

  RETURN p_monto;
END;
$$;

COMMENT ON FUNCTION public.actualizar_monto_minimo_pedido(numeric) IS
  'Fija el minimo de la sucursal activa. Solo admin/encargado. mig 204.';

REVOKE ALL ON FUNCTION public.actualizar_monto_minimo_pedido(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_monto_minimo_pedido(numeric) TO authenticated;

DO $verif$
DECLARE
  v_acl text;
  v_fn  text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['monto_minimo_pedido', 'actualizar_monto_minimo_pedido'] LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_acl IS NULL THEN
      RAISE EXCEPTION '% quedo con ACL default (PUBLIC ejecuta)', v_fn;
    END IF;
    IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC: %', v_fn, v_acl;
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por anon: %', v_fn, v_acl;
    END IF;
    IF v_acl NOT LIKE '%authenticated=X%' THEN
      RAISE EXCEPTION '% no quedo ejecutable por authenticated: %', v_fn, v_acl;
    END IF;
  END LOOP;
END
$verif$;

COMMIT;

-- ROLLBACK (si hiciera falta):
--   DROP FUNCTION IF EXISTS public.actualizar_monto_minimo_pedido(numeric);
--   DROP FUNCTION IF EXISTS public.monto_minimo_pedido(bigint);
--   DROP TABLE IF EXISTS public.politicas_comerciales;
-- Nada mas depende de esto mientras la mig 205 no este aplicada.
