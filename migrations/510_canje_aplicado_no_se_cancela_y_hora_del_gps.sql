-- =========================================================================
-- mig 510 · #1553 · un canje ya aplicado no se cancela, y la hora de captura
-- del GPS tiene piso y techo (lo que quedaba de RUT-3 y de VAR-01)
-- =========================================================================
--
--   1 · RUT-3. La comanda de un canje (`canal = 'cambio'`) no tiene líneas: lo
--       que mueve el stock es el cambio (`aplicar_cambio_de_parada`, que deja
--       `recorrido_cambios.aplicado_at`). `cancelar_pedido_con_stock` devuelve
--       el stock de las líneas, así que sobre un canje aplicado contestaba
--       `"stock_restaurado": true` y no devolvía nada: 50/50 → 58/42 → se
--       cancela → 58/42. Decisión del dueño (16/11): cancelar un canje ya
--       aplicado se rechaza con un mensaje claro. Si hay que revertirlo, se
--       registra el cambio inverso. Un canje sin aplicar se cancela como antes.
--       A la baja se entra sólo por esta función (`pedidos_guard_baja`), así
--       que el freno va acá y cubre todos los caminos.
--
--   2 · VAR-01, la hora. `registrar_geolocalizacion_pedido` y
--       `registrar_visita_cliente` guardaban cualquier `p_capturado_at`: uno de
--       2099 clavaba la «última ubicación» del preventista en el panel, y un GPS
--       `ok` no se puede pisar. La regla es una, `_gps_hora_de_captura`: una
--       hora nula, más de 5 minutos adelante de la del servidor (el reloj del
--       teléfono) o más de 60 días atrás se guarda como la hora del servidor.
--       No se rechaza: la hora es un dato de la captura y no puede costar la
--       ubicación. 60 días es el piso de las fechas tipeadas (#1545), y un
--       pedido encolado sin señal no espera más que eso. Las columnas `gps_*`
--       no tienen escritura REST: las escriben sólo estas dos funciones.
--
-- Parche con premisa: los cuerpos vivos son los de prod con el ledger en la 507.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos, y que la función nueva no exista
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', '9af5626c58c2e994a7968d74b62ad018'),
    ('public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)', '5c7e3295d8bf4c94d029fa775436f061'),
    ('public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)',          '7f017670fa2781a9b547b5517d078e0f')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure(r.f);
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig 510 · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public._gps_hora_de_captura(timestamp with time zone)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 510 · _gps_hora_de_captura ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · RUT-3 · cancelar_pedido_con_stock rechaza el canje ya aplicado
-- ---------------------------------------------------------------------------
DO $parche_cancelar$
DECLARE
  v_def text := pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);
  v_a text := $a$  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya esta cancelado');
  END IF;
$a$;
  v_r text := $r$  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya esta cancelado');
  END IF;

  -- #1553 (RUT-3): la comanda de un canje no tiene líneas; el stock lo movió el cambio
  -- (aplicar_cambio_de_parada) y esta función no lo devuelve. Decisión del dueño: no se cancela.
  IF v_pedido.canal IS NOT DISTINCT FROM 'cambio'
     AND EXISTS (SELECT 1 FROM recorrido_cambios
                  WHERE pedido_id = p_pedido_id AND aplicado_at IS NOT NULL) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El canje #' || p_pedido_id || ' ya se aplicó: el stock de los dos productos ya se movió y cancelarlo no lo devuelve. Si hay que revertirlo, registrá el cambio inverso.');
  END IF;
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 510 · cancelar_pedido_con_stock: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_cancelar$;

-- ---------------------------------------------------------------------------
-- 2 · VAR-01 · la hora de captura, una sola regla
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._gps_hora_de_captura(p_capturado_at timestamp with time zone)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- #1553 (VAR-01): la hora del teléfono vale si es creíble. Nula, más de 5 minutos
  -- adelante o más de 60 días atrás, se guarda la del servidor.
  SELECT CASE
           WHEN p_capturado_at IS NULL
             OR p_capturado_at > now() + interval '5 minutes'
             OR p_capturado_at < now() - interval '60 days'
           THEN now()
           ELSE p_capturado_at
         END;
$function$;

ALTER FUNCTION public._gps_hora_de_captura(timestamp with time zone) OWNER TO postgres;
-- Sólo de server: la llaman las dos RPC de GPS, que son DEFINER.
REVOKE ALL ON FUNCTION public._gps_hora_de_captura(timestamp with time zone) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._gps_hora_de_captura(timestamp with time zone) TO service_role;
COMMENT ON FUNCTION public._gps_hora_de_captura(timestamp with time zone) IS
  'La hora de captura de un GPS que se guarda (#1553): la del teléfono si está entre 60 días atrás y 5 minutos adelante de la del servidor; si no, la del servidor. La usan registrar_geolocalizacion_pedido y registrar_visita_cliente.';

DO $parche_gps$
DECLARE
  f text;
  v_def text;
  v_a CONSTANT text := 'COALESCE(p_capturado_at, now())';
  v_r CONSTANT text := 'public._gps_hora_de_captura(p_capturado_at)';
  v_n int;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)',
    'public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)'
  ] LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 510 · %: el ancla aparece % vez/veces y se esperaba 1', f, v_n;
    END IF;
    EXECUTE replace(v_def, v_a, v_r);
  END LOOP;
END
$parche_gps$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', '9101927774f8d3511ff7285fdf76af1d', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)', '85603f3b5d2ec9b05b4f4bcf378c6ead', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)', '12f29e709c505565bb86f589bf446dbd', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._gps_hora_de_captura(timestamp with time zone)', '06778cc612d24a8984c9ae94fb8d8636', false,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig 510 · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
