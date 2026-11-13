-- =========================================================================
-- 491 · QUIÉN MARCÓ LA ENTREGA DE UN PEDIDO, Y CUÁNDO (#1555)
--
-- Agrega `pedidos.entregado_por` y `pedidos.entregado_at`, las escribe con un
-- trigger en la transición a 'entregado' y completa los pedidos ya entregados
-- desde `pedido_historial`. No cambia ninguna función existente: la premisa
-- es sobre lo que este diseño da por sentado (los triggers de `pedidos` y las
-- dos funciones del historial), leído el 12/11.
-- Ensayo: scripts/test-quien-marco-la-entrega-1555.sql. Se aplica en LF.
--
-- POR QUÉ UN TRIGGER Y NO CADA RPC
-- Un pedido pasa a 'entregado' por cinco caminos: la escritura REST de
-- `estado` (siete llamadores en el front), `marcar_entregas_masivo`,
-- `marcar_entrega_y_pago_masivo_impl`, `cambiar_tipo_factura_pedido` (a vale
-- blanco) y el alta de un vale blanco, que nace entregado. Y sale de ese
-- estado por otros siete. Que cada uno escriba las columnas es la forma en que
-- una se olvida. Es el molde de `armado_por` y `armado_at` (mig 391).
--
-- QUÉ GUARDA
--   · `entregado_por`: el usuario de la sesión que hizo el cambio. Es el mismo
--     que `registrar_cambio_pedido` deja en la fila de `pedido_historial`
--     (misma expresión), así que las dos fuentes siempre coinciden. En el alta
--     de un vale blanco sin sesión cae en `usuario_id`, como
--     `registrar_creacion_pedido`. NO es el chofer: un admin que marca la
--     entrega de un chofer queda él, y el chofer sigue en `transportista_id`.
--   · `entregado_at`: el instante del cambio. NO es `fecha_entrega`, que es la
--     fecha DECLARADA de la entrega (anclada a mediodía, elegible hacia atrás):
--     en prod, 471 pedidos entregados desde el 01/10 tienen más de un día
--     entre una y otra.
--   · Las dos son NULL si el pedido no está 'entregado': al revertir la
--     entrega, al volver a pendiente o al cancelar se limpian, y una nueva
--     entrega las vuelve a escribir (hay 111 pedidos entregados más de una vez).
--
-- NO SE ESCRIBEN POR REST
-- `pedidos.UPDATE` es por columna y estas dos no entran en la lista
-- (`scripts/grants-rest.json` no cambia): un PATCH que las nombre da 42501. El
-- trigger es `BEFORE … OF estado`, así que tampoco las pisa un UPDATE que no
-- toque el estado. Se leen con el SELECT de tabla que `pedidos` ya tiene.
--
-- EL ORDEN DE LOS TRIGGERS
-- Los BEFORE de fila corren por nombre. `pedidos_proteger_columnas` compara la
-- fila vieja con la nueva y al chofer le rechaza toda columna que no sea
-- `estado`, `fecha_entrega` o `updated_at`: tiene que correr ANTES de que este
-- trigger escriba las suyas, o el chofer no podría entregar. Por eso el nombre
-- empieza con `trg_`, que ordena después de `pedidos_proteger_columnas`. Si
-- alguien lo renombra, el ensayo (caso E3) lo ve.
--
-- LOS PEDIDOS YA ENTREGADOS
-- Se completan desde el historial, con la última fila `estado → entregado` de
-- cada uno (por `id`, que es el orden real; #1473). El pedido que no la tiene
-- nació entregado (un vale blanco): se toma su fila de creación. Lo que queda
-- sin ninguna de las dos lleva `fecha_entrega` y sin usuario.
-- Leído en prod el 12/11: desde julio el 100 % tiene la fila con usuario; de
-- enero a junio la fila existe pero sin usuario (quedan con fecha y sin
-- nombre); sin fila hay 33, todos vales blancos con su fila de creación.
-- El UPDATE no nombra `estado`, `total`, `monto_pagado`, `fecha_entrega` ni
-- `transportista_id`: no dispara los AFTER … OF de saldo, recorrido ni control
-- de rendición. `audit_pedidos` se apaga durante el UPDATE (como la 451 con
-- `audit_pedido_items`): serían unas 8.500 filas en `audit_logs` sin ningún
-- cambio de negocio. `trg_historial_cambio_pedido` corre y no inserta nada.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Premisas
-- -------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
  n integer;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'pedidos'
                AND column_name IN ('entregado_por', 'entregado_at')) THEN
    RAISE EXCEPTION 'mig 491 · pedidos ya tiene entregado_por o entregado_at: revisar a mano';
  END IF;
  IF to_regprocedure('public.pedidos_registrar_entrega()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 491 · pedidos_registrar_entrega ya existe: revisar a mano';
  END IF;

  -- El usuario que guarda el historial y la regla del chofer: este diseño los espeja.
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_cambio_pedido()',   '5b6deb243016db84b767a2757746a0fa'),
    ('public.registrar_creacion_pedido()', '2f2262c1c0eb1b1cbf965c68e98135bb'),
    ('public.pedidos_proteger_columnas()', '7a96f8fad1e6efee59678ffbbdf67cd5')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig 491 · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  -- Los 19 triggers de pedidos, con su definición: el orden por nombre y las
  -- listas `OF` son las que se leyeron.
  SELECT md5(string_agg(t.tgname || '=' || pg_get_triggerdef(t.oid), '|' ORDER BY t.tgname)), count(*)
    INTO v, n
    FROM pg_trigger t
   WHERE t.tgrelid = 'public.pedidos'::regclass AND NOT t.tgisinternal;
  IF n <> 19 OR v IS DISTINCT FROM 'ede5262a6c3e210be2dcfff5fcae09af' THEN
    RAISE EXCEPTION 'mig 491 · los triggers de pedidos cambiaron desde que se leyeron (% triggers, md5 %): revisar el orden y las listas OF', n, v;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'audit_pedidos' AND tgenabled <> 'O') THEN
    RAISE EXCEPTION 'mig 491 · audit_pedidos no está habilitado: alguien lo dejó apagado';
  END IF;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · Las columnas
-- -------------------------------------------------------------------------
ALTER TABLE public.pedidos
  ADD COLUMN entregado_por uuid REFERENCES public.perfiles(id) ON DELETE SET NULL,
  ADD COLUMN entregado_at  timestamptz;

COMMENT ON COLUMN public.pedidos.entregado_por IS
  'Quien paso el pedido a "entregado": el usuario de la sesion (admin, encargado o el chofer), no el chofer del pedido, que va en transportista_id. Lo escribe trg_pedidos_registrar_entrega y se limpia al salir de entregado. NULL = lo hizo el servidor, o es anterior a julio de 2026 (sin registro). Sin escritura REST. #1555.';
COMMENT ON COLUMN public.pedidos.entregado_at IS
  'Cuando se paso el pedido a "entregado" (el instante del cambio). No es fecha_entrega, que es la fecha declarada de la entrega. Lo escribe trg_pedidos_registrar_entrega y se limpia al salir de entregado. Sin escritura REST. #1555.';

-- -------------------------------------------------------------------------
-- 2 · Los pedidos ya entregados, desde el historial
-- -------------------------------------------------------------------------
ALTER TABLE public.pedidos DISABLE TRIGGER audit_pedidos;

UPDATE public.pedidos p
   SET entregado_por = x.quien,
       entregado_at  = x.cuando
  FROM (
    SELECT pe.id,
           CASE WHEN h.id IS NOT NULL THEN h.usuario_id ELSE c.usuario_id END AS quien,
           COALESCE(h.created_at, c.created_at, pe.fecha_entrega, pe.created_at, now()) AS cuando
      FROM public.pedidos pe
      LEFT JOIN LATERAL (
        SELECT ph.id, ph.usuario_id, ph.created_at
          FROM public.pedido_historial ph
         WHERE ph.pedido_id = pe.id
           AND ph.campo_modificado = 'estado' AND ph.valor_nuevo = 'entregado'
         ORDER BY ph.id DESC
         LIMIT 1) h ON true
      LEFT JOIN LATERAL (
        SELECT ph.usuario_id, ph.created_at
          FROM public.pedido_historial ph
         WHERE ph.pedido_id = pe.id AND ph.campo_modificado = 'creacion'
         ORDER BY ph.id DESC
         LIMIT 1) c ON h.id IS NULL
     WHERE pe.estado = 'entregado'
  ) x
 WHERE p.id = x.id;

ALTER TABLE public.pedidos ENABLE TRIGGER audit_pedidos;

-- -------------------------------------------------------------------------
-- 3 · El trigger
-- -------------------------------------------------------------------------
CREATE FUNCTION public.pedidos_registrar_entrega()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_quien uuid;
BEGIN
  IF NEW.estado = 'entregado' AND (TG_OP = 'INSERT' OR OLD.estado IS DISTINCT FROM 'entregado') THEN
    -- El mismo usuario que registrar_cambio_pedido deja en pedido_historial.
    BEGIN
      v_quien := COALESCE(
        NULLIF(current_setting('app.current_user_id', true), '')::uuid,
        auth.uid()
      );
    EXCEPTION WHEN OTHERS THEN
      v_quien := auth.uid();
    END;
    -- El alta de un vale blanco sin sesión: quien lo cargó, como registrar_creacion_pedido.
    IF TG_OP = 'INSERT' THEN
      v_quien := COALESCE(v_quien, NEW.usuario_id);
    END IF;
    -- Por el perfil, no por el uuid pelado: la FK es a perfiles, y un usuario
    -- sin perfil no puede frenar una entrega (queda NULL, "sin registro").
    NEW.entregado_por := (SELECT pf.id FROM perfiles pf WHERE pf.id = v_quien);
    NEW.entregado_at  := now();
  ELSIF NEW.estado IS DISTINCT FROM 'entregado' THEN
    NEW.entregado_por := NULL;
    NEW.entregado_at  := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

ALTER FUNCTION public.pedidos_registrar_entrega() OWNER TO postgres;
-- Función de trigger: no necesita EXECUTE para nadie (CLAUDE.md).
REVOKE ALL ON FUNCTION public.pedidos_registrar_entrega() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pedidos_registrar_entrega() TO service_role;

-- El nombre ordena DESPUÉS de pedidos_proteger_columnas (ver el encabezado).
CREATE TRIGGER trg_pedidos_registrar_entrega
  BEFORE INSERT OR UPDATE OF estado ON public.pedidos
  FOR EACH ROW
  EXECUTE FUNCTION public.pedidos_registrar_entrega();

-- -------------------------------------------------------------------------
-- 4 · Poscondiciones
-- -------------------------------------------------------------------------
DO $post$
DECLARE
  x record;
  n bigint;
BEGIN
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
    FROM pg_proc WHERE oid = 'public.pedidos_registrar_entrega()'::regprocedure;
  IF x.h IS DISTINCT FROM 'ad789af7c454f6832096a1c1f9a16489'
     OR x.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}'
     OR x.def THEN
    RAISE EXCEPTION 'mig 491 · pedidos_registrar_entrega no quedó como en el repo (md5 %, acl %, definer %)', x.h, x.a, x.def;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'trg_pedidos_registrar_entrega'
                    AND tgenabled = 'O'
                    AND pg_get_triggerdef(oid) = 'CREATE TRIGGER trg_pedidos_registrar_entrega BEFORE INSERT OR UPDATE OF estado ON public.pedidos FOR EACH ROW EXECUTE FUNCTION pedidos_registrar_entrega()') THEN
    RAISE EXCEPTION 'mig 491 · trg_pedidos_registrar_entrega no quedó como se esperaba';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'audit_pedidos' AND tgenabled <> 'O') THEN
    RAISE EXCEPTION 'mig 491 · audit_pedidos quedó apagado';
  END IF;
  SELECT count(*) INTO n FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass AND NOT tgisinternal;
  IF n <> 20 THEN
    RAISE EXCEPTION 'mig 491 · pedidos tiene % triggers, se esperaban 20', n;
  END IF;

  -- Sin escritura REST, y sin nada para anon.
  IF has_column_privilege('authenticated', 'public.pedidos', 'entregado_por', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.pedidos', 'entregado_at', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.pedidos', 'entregado_por', 'INSERT')
     OR has_column_privilege('authenticated', 'public.pedidos', 'entregado_at', 'INSERT')
     OR has_column_privilege('anon', 'public.pedidos', 'entregado_por', 'SELECT')
     OR has_column_privilege('anon', 'public.pedidos', 'entregado_at', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.pedidos', 'entregado_por', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.pedidos', 'entregado_at', 'SELECT') THEN
    RAISE EXCEPTION 'mig 491 · los permisos de entregado_por / entregado_at no quedaron como se esperaba';
  END IF;

  -- El invariante: sello si y sólo si entregado.
  SELECT count(*) INTO n FROM public.pedidos WHERE estado = 'entregado' AND entregado_at IS NULL;
  IF n <> 0 THEN
    RAISE EXCEPTION 'mig 491 · quedaron % pedidos entregados sin entregado_at', n;
  END IF;
  SELECT count(*) INTO n FROM public.pedidos
   WHERE estado IS DISTINCT FROM 'entregado' AND (entregado_at IS NOT NULL OR entregado_por IS NOT NULL);
  IF n <> 0 THEN
    RAISE EXCEPTION 'mig 491 · quedaron % pedidos no entregados con sello de entrega', n;
  END IF;
END
$post$;

COMMIT;
