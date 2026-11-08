-- 475 · El reintento de una salvedad que un admin anuló avisa que está anulada (#1504, punto 2).
--
-- QUÉ PASABA
--   registrar_salvedad reconoce un reintento por su clave (client_request_id) y contesta lo que hizo la
--   primera vez, con idempotent_replay. anular_salvedad no borra la fila: le pone
--   estado_resolucion = 'anulada' y deshace el total y el stock. El replay no miraba ese estado. Con la
--   clave persistente de #1467, que dura 2 horas, pasaba esto:
--     1. la salvedad entra, pero la respuesta se pierde;
--     2. un admin la anula;
--     3. el chofer la vuelve a cargar con la misma clave;
--     4. el server contesta success con idempotent_replay, y no se mueve ni el total ni el stock.
--   El chofer veía "registrada" sobre una salvedad que ya no existe.
--
-- QUÉ CAMBIA
--   · El replay lee también estado_resolucion. Si la salvedad de esa clave está anulada, contesta
--     {success: false, codigo: 'salvedad_anulada'} con un mensaje para el chofer, y no mueve nada.
--   · No se registra una nueva con la misma clave: el índice único idx_salvedades_items_client_request_id
--     la sigue ocupando. El front olvida la clave de esa línea al recibir el código, así que si igual
--     corresponde, el próximo "Confirmar" la registra como una salvedad nueva, con otra clave.
--   · Va antes del chequeo de #1327 (otros datos con la misma clave): sobre una anulada, el aviso es
--     que está anulada, cambie o no el contenido.
--
-- QUÉ NO CAMBIA
--   El replay de una salvedad viva (con los mismos datos contesta idempotent_replay; con otros,
--   salvedad_ya_registrada), anular_salvedad, los permisos, el orden de locks ni los EXECUTE. Es un
--   parche por ancla sobre el cuerpo vivo, con premisa de md5.
--
-- Ensayo: scripts/test-salvedad-anulada-1504.sql. Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: el cuerpo vivo es el que se leyó de prod (07/11)
-- ---------------------------------------------------------------------------
DO $premisas$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure)
     <> '44d44c4746ae64d8499213c430e65037' THEN
    RAISE EXCEPTION 'mig 475 · registrar_salvedad cambió en prod desde que se leyó: rehacer sobre la definición vigente';
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
  v_ancla text := $a$    SELECT id, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id, recargo_combo,
           cantidad_afectada, motivo
      INTO v_existing
      FROM salvedades_items
     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal
       AND pedido_id = p_pedido_id;

    -- #1327: la clave es de la salvedad, no de su contenido.$a$;
  v_reemplazo text := $r$    SELECT id, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id, recargo_combo,
           cantidad_afectada, motivo, estado_resolucion
      INTO v_existing
      FROM salvedades_items
     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal
       AND pedido_id = p_pedido_id;

    -- #1504: una salvedad anulada no es un reintento que salió bien. anular_salvedad no
    -- borra la fila y la clave es única, así que esta clave ya no sirve: se le avisa al
    -- chofer, y el front la olvida para que, si igual corresponde, la nueva vaya con otra.
    IF FOUND AND v_existing.estado_resolucion = 'anulada' THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'salvedad_anulada', 'error',
        'Esta salvedad ya se había registrado y un admin la anuló. Si igual corresponde, confirmá de nuevo y se registra como una nueva.');
    END IF;

    -- #1327: la clave es de la salvedad, no de su contenido.$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 475 · el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: el cuerpo y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO r
    FROM pg_proc
   WHERE oid = 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure;
  IF r.h <> '2319b68994b913717cd3283d4123f823'
     OR r.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'registrar_salvedad no quedó como en el repo (md5 %, acl %, definer %)', r.h, r.a, r.def;
  END IF;
END
$post$;

COMMIT;
