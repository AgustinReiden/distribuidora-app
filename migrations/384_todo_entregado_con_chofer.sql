-- 384 · Todo pedido entregado queda con su chofer (#1204).
--
-- En la oficina se marcaban como entregados pedidos sin chofer (de a uno por
-- REST, o en lote con marcar_entregas_masivo) y nada preguntaba quien los
-- repartio: en Taco Pozo, un tercio de lo entregado. El reporte de Rechazos
-- (383) los mostraba como "Sin chofer".
--
-- Decisiones del duenio (2026-10-16, en el issue):
--   - Todo pedido entregado que no sea vale blanco lleva chofer, salvo que lo
--     haya retirado el cliente en el deposito. Se bloquea en el server.
--   - El vale blanco no lleva chofer: es mercaderia que se retira del deposito.
--   - "Retiro en deposito" es una opcion propia (pedidos.retiro_deposito), y la
--     marcan solo admin y encargado. Todo VB es un retiro, pero no todo retiro
--     es un VB.
--   - El pasado no se toca: los entregados viejos sin chofer quedan como estan.
--
-- La regla vive en UN trigger, no en cada RPC: la entrega llega por REST (la
-- individual, el modal de pago, la salvedad, la ruta del chofer), por
-- marcar_entregas_masivo y por marcar_entrega_y_pago_masivo_impl, y un bundle
-- viejo del PWA no tiene que poder saltearla.
--
-- "Chofer" es un chofer de verdad: rol base transportista, o el rol extra
-- transportista en la sucursal del pedido. Sin admin ni encargado
-- (es_transportista() incluye al admin, trampa 4).

-- 1) La columna -------------------------------------------------------------

ALTER TABLE public.pedidos
  ADD COLUMN retiro_deposito boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.pedidos.retiro_deposito IS
  'El cliente retiro el pedido en el deposito: entregado sin chofer. Solo admin/encargado lo marca; se apaga solo al salir de entregado o al asignarle chofer. El VB no lo necesita (no lleva chofer por naturaleza). #1204.';

-- Un retiro no tiene chofer. El trigger de abajo lo normaliza; esto lo cierra.
ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_retiro_sin_chofer
  CHECK (NOT (retiro_deposito AND transportista_id IS NOT NULL));

-- La entrega individual va por REST: pedidos.UPDATE es por columna (#1135).
GRANT UPDATE (retiro_deposito) ON public.pedidos TO authenticated;

-- 2) Quien es chofer ----------------------------------------------------------

-- Espejo de _actua_como_preventista (377): rol base, o el extra de esa
-- sucursal, sin admin ni encargado. Es la misma lista que muestra el front
-- (fetchTransportistas). De server: sin EXECUTE para nadie.
CREATE FUNCTION public._actua_como_transportista(p_usuario uuid, p_sucursal bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles p
     WHERE p.id = p_usuario
       AND (p.rol = 'transportista'
            OR (p.rol NOT IN ('admin', 'encargado')
                AND EXISTS (SELECT 1 FROM public.perfil_roles pr
                             WHERE pr.usuario_id = p.id
                               AND pr.sucursal_id = p_sucursal
                               AND pr.rol = 'transportista'))));
$$;

REVOKE ALL ON FUNCTION public._actua_como_transportista(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._actua_como_transportista(uuid, bigint) TO service_role;

-- 3) El trigger ---------------------------------------------------------------

-- SECURITY DEFINER porque por REST corre como authenticated y tiene que leer
-- perfiles/perfil_roles sin RLS y llamar a la auxiliar de server. Por eso el
-- permiso del retiro mira auth.uid() y no current_user: con sesion (REST o una
-- RPC del front) tiene que ser admin o encargado; sin sesion (service_role,
-- el bot) pasa.
CREATE FUNCTION public.pedidos_entrega_con_chofer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_es_vb      boolean := NEW.tipo_factura IS NOT DISTINCT FROM 'VB';
  v_transicion boolean;
BEGIN
  -- Fuera de entregado no hay retiro, y con chofer tampoco: el retiro se apaga
  -- solo (revertir la entrega, volver a pendiente, asignarle chofer).
  IF NEW.estado IS DISTINCT FROM 'entregado' OR NEW.transportista_id IS NOT NULL THEN
    NEW.retiro_deposito := false;
  END IF;

  IF NEW.retiro_deposito
     AND (TG_OP = 'INSERT' OR NOT OLD.retiro_deposito)
     AND auth.uid() IS NOT NULL
     AND NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo un administrador o encargado puede marcar que el cliente retiró el pedido en el depósito.'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.estado IS DISTINCT FROM 'entregado' OR v_es_vb THEN
    RETURN NEW;
  END IF;

  v_transicion := TG_OP = 'INSERT' OR OLD.estado IS DISTINCT FROM 'entregado';

  -- Sin chofer y sin retiro: se rechaza al entregar, o al sacarle el chofer (o
  -- el retiro) a uno ya entregado. Un entregado viejo que ya estaba sin chofer
  -- no se toca: el pasado queda como esta (decision del duenio).
  IF NEW.transportista_id IS NULL AND NOT NEW.retiro_deposito
     AND (v_transicion OR OLD.transportista_id IS NOT NULL OR OLD.retiro_deposito) THEN
    RAISE EXCEPTION 'El pedido #% no tiene chofer: elegí quién lo repartió, o marcá que el cliente lo retiró en el depósito.',
      NEW.id USING ERRCODE = '23514';
  END IF;

  IF NEW.transportista_id IS NOT NULL
     AND (v_transicion OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id)
     AND NOT public._actua_como_transportista(NEW.transportista_id, NEW.sucursal_id) THEN
    RAISE EXCEPTION 'El pedido #% no se puede entregar a nombre de %: no es chofer en esta sucursal.',
      NEW.id, COALESCE((SELECT nombre FROM public.perfiles WHERE id = NEW.transportista_id), 'ese usuario')
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END
$$;

-- Funcion de trigger: la invoca el executor, no el caller. Sin EXECUTE.
REVOKE ALL ON FUNCTION public.pedidos_entrega_con_chofer() FROM PUBLIC, anon, authenticated;

-- Corre despues de pedidos_proteger_columnas (orden alfabetico), asi que lo
-- que normaliza aca no lo ve como una columna cambiada por el chofer.
CREATE TRIGGER trg_pedidos_entrega_con_chofer
  BEFORE INSERT OR UPDATE OF estado, transportista_id, retiro_deposito
  ON public.pedidos
  FOR EACH ROW EXECUTE FUNCTION public.pedidos_entrega_con_chofer();

-- 4) Ensayo -------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.ens1204_pedido(p_cli bigint, p_admin uuid, p_prod bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(p_cli, 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', 1, 'precio_unitario', 100)),
    'ensayo 1204');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Devuelve el mensaje del error, o NULL si la sentencia paso.
CREATE OR REPLACE FUNCTION pg_temp.ens1204_falla(p_sql text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END
$fn$;

DO $ensayo1204$
DECLARE
  v_admin    uuid;
  v_suc      bigint;
  v_cliente  bigint;
  v_chofer   uuid;
  v_prev     uuid;
  v_prod     bigint;
  a bigint; b bigint; c bigint; d bigint; e bigint; g bigint;
  v_res      jsonb;
  v_err      text;
  v_viejo    bigint;
  f          text[] := '{}';
  v_fallas   text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE EXISTS (SELECT 1 FROM usuario_sucursales u2 JOIN perfiles p2 ON p2.id = u2.usuario_id
                  WHERE u2.sucursal_id = us.sucursal_id AND p2.activo
                    AND public._actua_como_transportista(p2.id, us.sucursal_id))
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens1204 · el ensayo necesita un admin activo en una sucursal con chofer';
  END IF;
  SELECT u.usuario_id INTO v_chofer FROM usuario_sucursales u JOIN perfiles p ON p.id = u.usuario_id
   WHERE u.sucursal_id = v_suc AND p.activo AND public._actua_como_transportista(p.id, v_suc)
   ORDER BY p.id LIMIT 1;
  SELECT u.usuario_id INTO v_prev FROM usuario_sucursales u JOIN perfiles p ON p.id = u.usuario_id
   WHERE u.sucursal_id = v_suc AND p.activo AND p.rol = 'preventista'
   ORDER BY p.id LIMIT 1;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL OR v_prev IS NULL THEN
    RAISE EXCEPTION 'ens1204 · el ensayo necesita un cliente activo y un preventista en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  BEGIN
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1204', 100, 100, 60, v_suc) RETURNING id INTO v_prod;
    a := pg_temp.ens1204_pedido(v_cliente, v_admin, v_prod);
    b := pg_temp.ens1204_pedido(v_cliente, v_admin, v_prod);
    c := pg_temp.ens1204_pedido(v_cliente, v_admin, v_prod);
    d := pg_temp.ens1204_pedido(v_cliente, v_admin, v_prod);
    e := pg_temp.ens1204_pedido(v_cliente, v_admin, v_prod);
    g := pg_temp.ens1204_pedido(v_cliente, v_admin, v_prod);

    -- A · la entrega individual (REST) sin chofer se rechaza...
    v_err := pg_temp.ens1204_falla(format('UPDATE public.pedidos SET estado = %L WHERE id = %s', 'entregado', a));
    IF v_err IS NULL OR v_err NOT LIKE '%no tiene chofer%' THEN
      f := f || format('A sin chofer no se rechazo (%s)', v_err);
    END IF;
    -- ...a nombre del admin tambien (no es chofer)...
    v_err := pg_temp.ens1204_falla(format('UPDATE public.pedidos SET estado = %L, transportista_id = %L WHERE id = %s',
                                          'entregado', v_admin, a));
    IF v_err IS NULL OR v_err NOT LIKE '%no es chofer%' THEN
      f := f || format('A a nombre del admin no se rechazo (%s)', v_err);
    END IF;
    -- ...y con un chofer de verdad pasa.
    v_err := pg_temp.ens1204_falla(format('UPDATE public.pedidos SET estado = %L, transportista_id = %L WHERE id = %s',
                                          'entregado', v_chofer, a));
    IF v_err IS NOT NULL THEN f := f || format('A con chofer fallo: %s', v_err); END IF;
    -- Sacarle el chofer a un entregado se rechaza.
    v_err := pg_temp.ens1204_falla(format('UPDATE public.pedidos SET transportista_id = NULL WHERE id = %s', a));
    IF v_err IS NULL THEN f := f || 'A entregado quedo sin chofer'::text; END IF;

    -- B · retiro en deposito por el admin: entregado, sin chofer.
    v_err := pg_temp.ens1204_falla(format('UPDATE public.pedidos SET estado = %L, retiro_deposito = true WHERE id = %s',
                                          'entregado', b));
    IF v_err IS NOT NULL THEN f := f || format('B retiro por el admin fallo: %s', v_err); END IF;
    IF NOT EXISTS (SELECT 1 FROM pedidos WHERE id = b AND estado = 'entregado' AND retiro_deposito AND transportista_id IS NULL) THEN
      f := f || 'B no quedo entregado como retiro'::text;
    END IF;
    -- Revertir la entrega apaga el retiro.
    UPDATE public.pedidos SET estado = 'pendiente', fecha_entrega = NULL WHERE id = b;
    IF (SELECT retiro_deposito FROM pedidos WHERE id = b) THEN
      f := f || 'B revertido siguio como retiro'::text;
    END IF;

    -- C · un preventista no puede marcar retiro.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev)::text, true);
    v_err := pg_temp.ens1204_falla(format('UPDATE public.pedidos SET estado = %L, retiro_deposito = true WHERE id = %s',
                                          'entregado', c));
    IF v_err IS NULL OR v_err NOT LIKE '%retiró el pedido en el depósito%' THEN
      f := f || format('C retiro por un preventista no se rechazo (%s)', v_err);
    END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

    -- D · el masivo sin chofer se rechaza; con chofer pasa.
    v_err := pg_temp.ens1204_falla(format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], NULL::uuid)', d));
    IF v_err IS NULL OR v_err NOT LIKE '%no tiene chofer%' THEN
      f := f || format('D masivo sin chofer no se rechazo (%s)', v_err);
    END IF;
    IF public.marcar_entregas_masivo(ARRAY[d], v_chofer) IS DISTINCT FROM 1 THEN
      f := f || 'D masivo con chofer no entrego'::text;
    END IF;

    -- E · entrega y pago masivos sin chofer tambien se rechaza.
    v_err := pg_temp.ens1204_falla(format('SELECT public.marcar_entrega_y_pago_masivo_impl(ARRAY[%s]::bigint[], NULL::uuid, %L)', e, 'efectivo'));
    IF v_err IS NULL OR v_err NOT LIKE '%no tiene chofer%' THEN
      f := f || format('E entrega y pago sin chofer no se rechazo (%s)', v_err);
    END IF;

    -- G · el vale blanco se entrega sin chofer.
    UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = v_cliente;
    v_res := public.cambiar_tipo_factura_pedido(g, 'VB', v_admin);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'VB en G: %', v_res; END IF;
    v_err := pg_temp.ens1204_falla(format('UPDATE public.pedidos SET estado = %L WHERE id = %s', 'entregado', g));
    IF v_err IS NOT NULL THEN f := f || format('G vale blanco sin chofer fallo: %s', v_err); END IF;

    -- El pasado no se toca: un entregado viejo sin chofer se sigue editando.
    SELECT id INTO v_viejo FROM pedidos
     WHERE estado = 'entregado' AND transportista_id IS NULL AND tipo_factura IS DISTINCT FROM 'VB'
     ORDER BY id LIMIT 1;
    IF v_viejo IS NOT NULL THEN
      v_err := pg_temp.ens1204_falla(format('UPDATE public.pedidos SET estado = estado, notas = notas WHERE id = %s', v_viejo));
      IF v_err IS NOT NULL THEN f := f || format('un entregado viejo sin chofer dejo de editarse: %s', v_err); END IF;
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('error: %s', SQLERRM);
  END;
  v_fallas := v_fallas || f;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ens1204 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1204$;

DROP FUNCTION pg_temp.ens1204_falla(text);
DROP FUNCTION pg_temp.ens1204_pedido(bigint, uuid, bigint);
