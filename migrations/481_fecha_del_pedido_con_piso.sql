-- 481 · La fecha del pedido tiene piso y techo para quien no es admin, en el alta y en la edición
-- (#1514: SEG-01 y PAT-9-1; tarjeta 3 de #1524).
--
-- QUÉ PASABA
--   · SEG-01. crear_pedido_completo sólo frenaba la fecha futura de quien no es admin (#1319), sin piso.
--     regalo_fuera_de_promo y combo_fuera_de_regla miden la vigencia en LEAST(fecha, hoy), así que un
--     preventista que fechaba el pedido atrás armaba el regalo de una promo que ya había vencido (la 734
--     terminó el 04/11 y sigue activa), o un combo vencido, y el server lo aceptaba. La venta además quedaba
--     en ese mes. #1319 dejó entrar fechas pasadas por la cola offline, pero sin límite.
--   · PAT-9-1. actualizar_fechas_y_notas_pedido aceptaba cualquier p_fecha, futura incluida.
--     pedidos_proteger_columnas sólo le cierra la fecha a quien no es admin ni encargado: el encargado podía
--     mover un pedido a cualquier día, y con él la venta por vendedor, la comisión y la ventana de la promo.
--     Lo mismo por un PATCH directo: authenticated tiene UPDATE (fecha) sobre pedidos.
--
-- QUÉ CAMBIA (decisión del dueño, 10/11)
--   · politicas_comerciales.dias_atras_fecha_pedido: cuántos días antes de hoy puede ir la fecha de un pedido
--     para quien no es admin. Por sucursal, de 0 a 30, 7 por defecto. La lee authenticated con el SELECT de
--     tabla que ya tiene politicas_comerciales (no hay grants por columna), y no tiene escritura REST.
--   · actualizar_dias_atras_fecha_pedido(p_dias): la edita sólo el admin desde /configuracion, como la
--     ventana de precio anterior (368): el piso rige para el encargado, que si lo pudiera cambiar ampliaría
--     su propio margen. Decide con es_admin(), que mira activo (#1474).
--   · _fecha_pedido_fuera_de_rango(fecha, sucursal): la regla, una sola vez. NULL si la fecha entra; si no,
--     el motivo. Entra de hoy (el día argentino, _tablero_hoy) hasta hoy − los días de la política. Quien
--     llama decide si rige: el admin no tiene piso ni techo. Espejo en el front: src/utils/fechaPedido.ts.
--     Es INVOKER y authenticated la ejecuta: la llama pedidos_proteger_columnas, que corre como
--     authenticated. Lee la política con la RLS de quien llama (la de su sucursal activa); sin fila, 7.
--   · crear_pedido_completo: para quien no es admin, el control de #1319 pasa a ser el de la regla: el techo
--     de antes y el piso nuevo. Rechaza con success = false y el motivo, antes de escribir nada. Por la cola
--     offline (crear_pedido_idempotente) un pedido encolado más viejo que el piso falla al sincronizar con
--     ese motivo, que la cola toma como rechazo definitivo y deja a la vista: no se pierde. El replay de un
--     pedido que ya entró no pasa por acá (crear_pedido_idempotente contesta antes) y no cambia.
--   · pedidos_proteger_columnas (con OK de la coordinadora de #1524, por el PATCH directo): el encargado
--     mueve la fecha dentro de la misma regla. Es un bloque nuevo justo antes de su salida
--     (IF es_encargado_o_admin() THEN RETURN NEW), porque la rama de 'fecha' de #1155 no lo ve: a quien no
--     es admin ni encargado ya no lo deja tocarla, y eso no cambia. Cubre el PATCH por REST y
--     actualizar_fechas_y_notas_pedido (INVOKER), que pasan por el trigger como authenticated a profundidad
--     1. Sólo si la fecha cambia, así un pedido más viejo que el piso se sigue editando. El resto del
--     trigger queda byte a byte igual.
--
-- QUÉ NO CAMBIA
--   · crear_pedido_idempotente no se toca: su md5 sigue siendo el de la lista blanca de SEG-A (474).
--   · crear_pedido_completo_bot carga siempre con la fecha de hoy: cumple el piso y el techo por construcción.
--   · cambiar_cliente_pedido es sólo de admin: el pedido nuevo conserva la fecha del original sin piso.
--   · actualizar_fechas_y_notas_pedido no se toca: su UPDATE pasa por el trigger.
--   · El admin carga y mueve cualquier fecha, como hasta ahora, y el server (DEFINER, o un UPDATE que no
--     corre como authenticated) no pasa por el trigger. El vale blanco sigue sin fecha futura para nadie (su
--     control propio de la 317 no se toca).
--   · Las firmas y los EXECUTE de las dos funciones que se parchean.
--
-- Ensayo: scripts/test-fecha-pedido-piso-1514.sql (corre en prod sin dejar rastro).
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
-- Premisas: los cuerpos vivos son los que se leyeron de prod (10/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
         '56969128aba1e0125044c9afbd40846e'),
        ('public.pedidos_proteger_columnas()',
         '84dab2cd9958c1725904ed20b24093e9')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 481 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'politicas_comerciales'
                AND column_name = 'dias_atras_fecha_pedido') THEN
    RAISE EXCEPTION 'mig 481 · politicas_comerciales.dias_atras_fecha_pedido ya existe';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('_fecha_pedido_fuera_de_rango', 'actualizar_dias_atras_fecha_pedido')) THEN
    RAISE EXCEPTION 'mig 481 · _fecha_pedido_fuera_de_rango o actualizar_dias_atras_fecha_pedido ya existen';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- La política: cuántos días hacia atrás
-- ---------------------------------------------------------------------------
ALTER TABLE public.politicas_comerciales
  ADD COLUMN dias_atras_fecha_pedido integer NOT NULL DEFAULT 7
    CONSTRAINT politicas_dias_atras_fecha_pedido_rango
      CHECK (dias_atras_fecha_pedido >= 0 AND dias_atras_fecha_pedido <= 30);

COMMENT ON COLUMN public.politicas_comerciales.dias_atras_fecha_pedido IS
  'Cuántos días antes de hoy (día argentino) puede ir la fecha de un pedido para quien no es admin, en el alta y en la edición (#1514). La aplica _fecha_pedido_fuera_de_rango; la edita sólo el admin con actualizar_dias_atras_fecha_pedido.';

-- ---------------------------------------------------------------------------
-- La regla: NULL si la fecha entra; si no, el motivo
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._fecha_pedido_fuera_de_rango(p_fecha date, p_sucursal bigint)
RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  -- #1514: la fecha de un pedido para quien no es admin va de hoy (el día argentino) hasta
  -- politicas_comerciales.dias_atras_fecha_pedido días atrás, 7 sin fila. La misma regla en el
  -- alta (crear_pedido_completo) y en la edición (pedidos_proteger_columnas); quien llama decide
  -- si rige. Espejo en el front: src/utils/fechaPedido.ts. El texto del techo empieza como
  -- el de #1319 ("... no puede ser posterior a hoy."), que buscan los ensayos y el front.
  SELECT CASE
           WHEN p_fecha IS NULL THEN NULL
           WHEN p_fecha > r.hoy THEN format(
             'La fecha del pedido (%s) no puede ser posterior a hoy. Lo que se entrega más adelante va en la fecha de entrega.',
             to_char(p_fecha, 'DD/MM/YYYY'))
           WHEN p_fecha < r.hoy - r.dias AND r.dias = 0 THEN format(
             'La fecha del pedido (%s) no puede ser anterior a hoy. Si el pedido es de antes, lo carga un admin.',
             to_char(p_fecha, 'DD/MM/YYYY'))
           WHEN p_fecha < r.hoy - r.dias THEN format(
             'La fecha del pedido (%s) no puede ser anterior al %s: hasta %s %s atrás. Si el pedido es de antes, lo carga un admin.',
             to_char(p_fecha, 'DD/MM/YYYY'), to_char(r.hoy - r.dias, 'DD/MM/YYYY'), r.dias,
             CASE WHEN r.dias = 1 THEN 'día' ELSE 'días' END)
         END
    FROM (SELECT public._tablero_hoy() AS hoy,
                 COALESCE((SELECT pc.dias_atras_fecha_pedido
                             FROM public.politicas_comerciales pc
                            WHERE pc.sucursal_id = p_sucursal), 7) AS dias) r
$function$;

REVOKE ALL ON FUNCTION public._fecha_pedido_fuera_de_rango(date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._fecha_pedido_fuera_de_rango(date, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- La RPC del admin, con el molde de actualizar_ventana_precio_anterior (368)
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.actualizar_dias_atras_fecha_pedido(p_dias integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- Sólo admin (decisión del dueño, #1514), como la ventana de precio anterior (#1157): el
  -- piso rige para el encargado; si lo pudiera cambiar, ampliaría su propio margen.
  -- es_admin() mira activo (#1474).
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  IF p_dias IS NULL OR p_dias < 0 OR p_dias > 30 THEN
    RAISE EXCEPTION 'Los días hacia atrás de la fecha del pedido van de 0 a 30';
  END IF;

  INSERT INTO public.politicas_comerciales (sucursal_id, dias_atras_fecha_pedido, actualizado_por, actualizado_en)
  VALUES (v_sucursal, p_dias, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET dias_atras_fecha_pedido = EXCLUDED.dias_atras_fecha_pedido,
        actualizado_por         = EXCLUDED.actualizado_por,
        actualizado_en          = EXCLUDED.actualizado_en;

  RETURN p_dias;
END;
$function$;

REVOKE ALL ON FUNCTION public.actualizar_dias_atras_fecha_pedido(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_dias_atras_fecha_pedido(integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
-- crear_pedido_completo · la variable del motivo.
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 1,
$a$  v_saldo_favor JSONB := '{}'::JSONB;
BEGIN
$a$,
$r$  v_saldo_favor JSONB := '{}'::JSONB;
  -- #1514: por qué la fecha del pedido no entra (NULL: entra).
  v_motivo_fecha TEXT;
BEGIN
$r$),
-- crear_pedido_completo · el techo de #1319 pasa a ser la regla, con el piso.
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 2,
$a$  -- #1319 (decisión del dueño, 29/10): para quien no es admin, la fecha del
  -- pedido no pasa de hoy, el día argentino. Lo futuro va en la entrega
  -- programada. Una fecha pasada sigue entrando: el pedido que la cola offline
  -- encoló ayer llega hoy con la fecha de ayer.
  IF v_user_role <> 'admin' AND v_fecha_pedido > public._tablero_hoy() THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
      'La fecha del pedido (%s) no puede ser posterior a hoy. Si se entrega más adelante, cargalo con la fecha de hoy y elegí la fecha de entrega.',
      to_char(v_fecha_pedido, 'DD/MM/YYYY'))));
  END IF;
$a$,
$r$  -- #1319 y #1514 (decisiones del dueño, 29/10 y 10/11): para quien no es admin, la
  -- fecha del pedido va de hoy, el día argentino, hasta los días hacia atrás de la
  -- política de la sucursal (7 por defecto). Lo futuro va en la entrega programada.
  -- El piso es el margen de la cola offline: el pedido que se encoló ayer llega hoy
  -- con la fecha de ayer, y uno más viejo que el piso se rechaza con el motivo y
  -- queda a la vista en la cola. Sin piso, una fecha atrasada medía la promo y el
  -- combo en una vigencia ya vencida (LEAST(fecha, hoy)) y llevaba la venta de mes.
  IF v_user_role <> 'admin' THEN
    v_motivo_fecha := public._fecha_pedido_fuera_de_rango(v_fecha_pedido, v_sucursal);
    IF v_motivo_fecha IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(v_motivo_fecha));
    END IF;
  END IF;
$r$),
-- pedidos_proteger_columnas · la variable del motivo.
('public.pedidos_proteger_columnas()', 1,
$a$  v_bloqueadas text;
BEGIN
$a$,
$r$  v_bloqueadas text;
  -- #1514: por qué la fecha nueva del pedido no entra (NULL: entra).
  v_motivo_fecha text;
BEGIN
$r$),
-- pedidos_proteger_columnas · el encargado mueve la fecha dentro del piso y del techo del alta.
('public.pedidos_proteger_columnas()', 2,
$a$
  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;
$a$,
$r$
  -- #1514 (PAT-9-1): el encargado mueve la fecha del pedido dentro del piso y el techo
  -- del alta (_fecha_pedido_fuera_de_rango, la de crear_pedido_completo). Va antes de su
  -- salida de abajo porque la rama de 'fecha' de #1155 no lo ve; al resto esa rama ya no
  -- lo deja tocarla. Cubre el PATCH por REST y actualizar_fechas_y_notas_pedido (INVOKER),
  -- que llegan acá como authenticated a profundidad 1. Sólo si la fecha cambia: un pedido
  -- más viejo que el piso se sigue editando. El admin y el server no tienen piso.
  IF TG_OP = 'UPDATE' THEN
    IF NEW.fecha IS DISTINCT FROM OLD.fecha AND es_encargado_o_admin() AND NOT es_admin() THEN
      v_motivo_fecha := public._fecha_pedido_fuera_de_rango(NEW.fecha, OLD.sucursal_id);
      IF v_motivo_fecha IS NOT NULL THEN
        RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _n_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _n_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 481 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, t.definer, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM (VALUES
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
         'f28c79fcef03caf37d17f77f686342c3', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
        ('public.pedidos_proteger_columnas()',
         '7a96f8fad1e6efee59678ffbbdf67cd5', '{postgres=X/postgres,service_role=X/postgres}', false),
        ('public._fecha_pedido_fuera_de_rango(date,bigint)',
         'd66db7f86805a3123561c3d8726b0e1b', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', false),
        ('public.actualizar_dias_atras_fecha_pedido(integer)',
         '0559dc1913f61f2725165847fc1ba485', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true)
      ) AS t(firma, hash, acl, definer)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR r.def <> r.definer THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname IN ('crear_pedido_completo', 'pedidos_proteger_columnas',
                         '_fecha_pedido_fuera_de_rango', 'actualizar_dias_atras_fecha_pedido')) <> 4 THEN
    RAISE EXCEPTION 'mig 481 · alguna de las cuatro funciones tiene más de una sobrecarga';
  END IF;
  IF (SELECT count(*) FROM public.politicas_comerciales WHERE dias_atras_fecha_pedido <> 7) <> 0 THEN
    RAISE EXCEPTION 'mig 481 · alguna sucursal no quedó con los 7 días por defecto';
  END IF;
END
$post$;

COMMIT;
