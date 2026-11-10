-- 478 · El reintento de una salvedad espera a una anulación en vuelo (#1508, punto 2).
--
-- QUÉ PASABA
--   Desde la 475, el replay de registrar_salvedad contesta 'salvedad_anulada' si la salvedad de esa
--   clave está anulada. Pero el SELECT del replay corría sin lock. anular_salvedad toma la fila
--   FOR UPDATE y la pasa a 'anulada'. Si el reintento del chofer leía mientras la anulación todavía no
--   había hecho COMMIT, en READ COMMITTED veía la versión vieja y contestaba success con
--   idempotent_replay: "registrada" sobre una salvedad que, un instante después, ya no existía. Es el
--   síntoma de #1504, en una ventana que dura lo que la transacción de anular. La anulación terminaba
--   igual: no rompía datos.
--
-- QUÉ CAMBIA
--   · El SELECT del replay va FOR SHARE. Si la fila está tomada por una anulación (o una resolución)
--     en vuelo, espera a que termine y vuelve a leer la versión nueva: contesta 'salvedad_anulada'.
--   · FOR SHARE y no FOR KEY SHARE: anular cambia estado_resolucion, que es un NO KEY UPDATE, y con
--     KEY SHARE el replay no lo esperaría.
--
-- POR QUÉ NO ABRE UN 40P01
--   Hasta el replay la transacción no tomó ningún lock: antes sólo lee perfiles y pedidos, sin FOR.
--   Y los tres caminos que encuentran la fila (anulada, otros datos con la misma clave, replay vivo)
--   retornan sin pedir nada más. Así que, mientras espera la fila de la salvedad, no tiene nada que
--   otro pueda estar esperando. Si no la encuentra, FOR SHARE no toma nada y la función sigue como
--   antes.
--
-- QUÉ NO CAMBIA
--   Las respuestas del replay, anular_salvedad, el resto de registrar_salvedad, los permisos y los
--   EXECUTE. La función es SECURITY DEFINER de postgres, dueño de salvedades_items (sin FORCE ROW LEVEL
--   SECURITY): el lock no pide privilegios ni policies nuevos. Es un parche por ancla sobre el cuerpo
--   vivo, con premisa de md5.
--
-- Ensayo: scripts/test-salvedad-replay-lock-1508.sql (una sesión) y la variante S1 del arnés de
-- concurrencia (scripts/concurrencia/), que mide el cruce. Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: el cuerpo vivo es el de la poscondición de la 475 (leído el 10/11)
-- ---------------------------------------------------------------------------
DO $premisas$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure)
     <> '2319b68994b913717cd3283d4123f823' THEN
    RAISE EXCEPTION 'mig 478 · registrar_salvedad cambió en prod desde que se leyó: rehacer sobre la definición vigente';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parche por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
DO $parche$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_ancla text := $a$     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal
       AND pedido_id = p_pedido_id;

    -- #1504: una salvedad anulada no es un reintento que salió bien.$a$;
  v_reemplazo text := $r$     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal
       AND pedido_id = p_pedido_id
       -- #1508: espera a una anulación en vuelo de esta misma salvedad y relee la fila
       -- ya anulada (en READ COMMITTED, FOR SHARE vuelve a evaluar la versión nueva). Sin
       -- el lock, un reintento que llegaba mientras un admin la anulaba leía la fila vieja
       -- y contestaba idempotent_replay sobre una salvedad que ya no existe. No cruza con
       -- nadie: hasta acá la transacción no tomó ningún lock, y si encuentra la fila
       -- siempre retorna antes de pedir el pedido.
       FOR SHARE;

    -- #1504: una salvedad anulada no es un reintento que salió bien.$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 478 · el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: el cuerpo, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO r
    FROM pg_proc
   WHERE oid = 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure;
  IF r.h <> 'ce4dcadfe8f7bdeec5f10b2851efb031'
     OR r.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
     OR NOT r.def THEN
    RAISE EXCEPTION 'registrar_salvedad no quedó como en el repo (md5 %, acl %, definer %)', r.h, r.a, r.def;
  END IF;
END
$post$;

COMMIT;
