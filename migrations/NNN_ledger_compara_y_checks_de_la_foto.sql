-- NNN · Restos de cobros: el ledger compara la solicitud, la clave vieja de pagos se congela, y checks de la foto y de los pedazos (#1399, #1440).
--
-- QUÉ PASABA
--   · Punto 2 de #1440. pago_solicitud_abrir devolvía el resultado guardado de cualquier clave,
--     sin mirar de qué operación ni de qué usuario era. Con UUID v4 y claves por usuario (#1410)
--     no se reusa ninguna, pero si algún día se reusara, la segunda solicitud recibía el resultado
--     de la primera como si fuera suyo y no se registraba nada.
--   · #1399. Desde #1246 nada escribe pagos.client_request_id (la última fila con clave es la
--     8049, del 29/10), y quedaron sin camino de entrada la rama de reintento de
--     guard_pago_fecha_cerrada (#1150), la de pagos_rechazar_pedido_de_baja y el índice único
--     idx_pagos_client_request_id. Las 1082 filas viejas conservan su clave.
--   · Punto 3 de #1440. auditoria_integridad() no tenía ningún check sobre la foto de la rendición
--     (rendicion_pagos_confirmados) ni sobre los pedazos (pago_padre_id, pago_origen_id).
--
-- QUÉ CAMBIA
--   1 · pago_solicitud_abrir: una clave guardada con otra operación o por otro usuario se rechaza
--       (22023) y no se registra nada. El replay legítimo es la misma operación del mismo usuario
--       y sigue devolviendo lo guardado. Los siete que la llaman le pasan su propio nombre (el
--       ensayo lo comprueba), así que su replay no cambia y ninguno de sus cuerpos se toca.
--       La sucursal no se compara: current_sucursal_id() es la sucursal activa de la pantalla (el
--       front manda X-Sucursal-ID en cada request, src/lib/supabase.ts), y el usuario la puede
--       cambiar entre el intento y el reintento. Ese reintento es el mismo cobro: rechazarlo
--       invitaría a cargarlo de nuevo con otra clave.
--   2 · #1399, decisión del dueño (04/11): limpiar y congelar. Salen las dos ramas y el índice. La
--       columna queda con sus claves como historia, y el CHECK pagos_client_request_id_historico no
--       deja que una fila nueva (id > 8049) la cargue.
--   3 · auditoria_integridad(), por ancla sobre el cuerpo vivo: REND-A a REND-D (la foto) y PAGO-A
--       (los pedazos). Medidos en prod el 04/11, los cinco dan 0: 327 rendiciones, 1797 filas de
--       foto y ningún pedazo. PAGO-A sólo mira pedazos con el padre vivo: un admin puede borrar en
--       un día abierto lo que quedó de un pago partido, y su pedazo sigue siendo plata que entró.
--
-- QUÉ NO CAMBIA
--   Los wrappers de cobro y sus _impl (167, 405b), pago_solicitud_cerrar, la tabla
--   pagos_solicitudes, el resto de los dos triggers y de los checks, las firmas y los EXECUTE.
--
-- El índice y el CHECK van al final: toman un ACCESS EXCLUSIVE sobre pagos hasta el COMMIT, y
-- así no lo tienen mientras corre auditoria_integridad() (3 s). Si no lo consiguen en 10 s,
-- la migración falla y se aplica de nuevo, en vez de dejar los cobros encolados detrás.
--
-- Ensayo: scripts/test-idempotencia-cobro-1440.sql. Aplicar desde el contenido LF.

BEGIN;

SELECT set_config('lock_timeout', '10s', true);

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $premisa$
DECLARE
  v_f record;
BEGIN
  -- Los cuerpos vivos que se leyeron el 04/11 (ledger en la 449).
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.pago_solicitud_abrir(uuid,text)',   '81b89f5c4b9376fd942348dc3b877859'),
        ('public.guard_pago_fecha_cerrada()',         'fd2c1a022783d7a84063f9345c0c55cc'),
        ('public.pagos_rechazar_pedido_de_baja()',    '04c8389d4c316f776e50d6dd58239990'),
        ('public.auditoria_integridad()',             '842d80cc3a5e60f189feec630e7fa350')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION '% cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  -- #1399: nada escribe la columna. Es texto, como STK-F: alcanza para lo que hay hoy.
  IF EXISTS (SELECT 1 FROM pg_proc f
              WHERE f.pronamespace = 'public'::regnamespace
                AND (f.prosrc ~* 'INSERT\s+INTO\s+(public\.)?pagos\s*\([^)]*\yclient_request_id\y'
                     OR f.prosrc ~* 'UPDATE\s+(public\.)?pagos\s+SET[^;]*\yclient_request_id\s*=')) THEN
    RAISE EXCEPTION 'una función de public vuelve a escribir pagos.client_request_id: revisar #1399 antes de congelarla';
  END IF;
  IF (SELECT max(id) FROM pagos WHERE client_request_id IS NOT NULL) > 8049 THEN
    RAISE EXCEPTION 'hay un pago con client_request_id posterior al 8049: revisar #1399 antes de congelarla';
  END IF;
  IF to_regclass('public.idx_pagos_client_request_id') IS NULL THEN
    RAISE EXCEPTION 'idx_pagos_client_request_id ya no está: la migración no es la que se escribió';
  END IF;
END
$premisa$;

-- ----------------------------------------------------------------------------
-- 1 · El ledger compara la solicitud (punto 2 de #1440)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pago_solicitud_abrir(p_client_request_id uuid, p_operacion text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_previa pagos_solicitudes%ROWTYPE;
BEGIN
  IF p_client_request_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_client_request_id::text, 0));

  SELECT * INTO v_previa
    FROM pagos_solicitudes
   WHERE client_request_id = p_client_request_id;

  IF FOUND THEN
    -- #1440: el replay es de la misma solicitud, la misma operacion del mismo
    -- usuario. Una clave que ya uso otra no es un reintento: devolverle ese
    -- resultado le haria creer que entro, y no entraria nada. La sucursal no se
    -- compara: es la activa de la pantalla (el front manda X-Sucursal-ID en cada
    -- request), y si el usuario la cambia entre el intento y el reintento, sigue
    -- siendo el mismo cobro.
    IF v_previa.operacion IS DISTINCT FROM p_operacion
       OR v_previa.usuario_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'La clave % ya es de otra solicitud: no se registró nada', p_client_request_id
        USING ERRCODE = '22023',
              DETAIL = format('Se guardó para %s%s; esta es %s.',
                              v_previa.operacion,
                              CASE WHEN v_previa.usuario_id IS DISTINCT FROM auth.uid()
                                   THEN ', de otro usuario' ELSE '' END,
                              p_operacion);
    END IF;

    -- resultado NULL solo puede pasar si la ejecucion original quedo a medias sin
    -- abortar la transaccion (no deberia ocurrir: un error revierte tambien esta
    -- fila). Se deja seguir para no dejar el pago sin registrar por un ledger raro.
    RETURN v_previa.resultado;
  END IF;

  INSERT INTO pagos_solicitudes (client_request_id, operacion, usuario_id, sucursal_id)
  VALUES (p_client_request_id, p_operacion, auth.uid(), current_sucursal_id());

  RETURN NULL;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2 · #1399: sin las ramas de client_request_id (el índice y el CHECK, en el 5)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_pago_fecha_cerrada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_limite date;
BEGIN
  IF NEW.sucursal_id IS NULL OR NEW.fecha IS NULL THEN
    RETURN NEW;
  END IF;

  -- Reimputacion interna (mig 165): mover plata ya cobrada entre boletas del
  -- mismo cliente no cambia el total del dia, solo a que boleta se aplica. El
  -- desglose por chofer de una rendicion confirmada tampoco cambia: se lee de su
  -- foto (rendicion_pagos_confirmados, #1248). El GUC es transaction-scoped y lo
  -- setean unicamente las funciones de reimputacion (aplicar_credito_cliente,
  -- imputar_credito_a_pedido_impl, _pagos_excedente_a_favor).
  IF current_setting('app.reimputacion_pagos', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- mig 276 (#833): un credito de NC no es plata de la rendicion (las RPCs de
  -- rendiciones lo excluyen), asi que emitirlo un dia con la caja controlada
  -- no la desbalancea. Quien lo puede crear lo decide pagos_guard_nota_credito.
  IF NEW.forma_pago = 'nota_credito' THEN
    RETURN NEW;
  END IF;

  v_limite := public.ultima_fecha_caja_cerrada(NEW.sucursal_id);

  IF v_limite IS NOT NULL AND NEW.fecha <= v_limite THEN
    RAISE EXCEPTION 'La caja de la sucursal esta cerrada hasta el % (rendicion controlada). No se puede registrar/editar un pago con fecha %. Reabri la rendicion de ese dia para hacer cambios.',
      to_char(v_limite, 'DD/MM/YYYY'), to_char(NEW.fecha, 'DD/MM/YYYY')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pagos_rechazar_pedido_de_baja()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_estado text;
BEGIN
  -- #1131. Molde: pagos_rechazar_pedido_vb.
  IF NEW.pedido_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.pedido_id IS NOT DISTINCT FROM NEW.pedido_id THEN
      RETURN NEW;
    END IF;
  END IF;

  -- FOR KEY SHARE: espera a una cancelacion en curso (FOR UPDATE) y relee el
  -- estado; no choca con el UPDATE de monto_pagado de otro pago concurrente.
  SELECT estado INTO v_estado FROM pedidos WHERE id = NEW.pedido_id FOR KEY SHARE;

  IF v_estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El pedido #% está %: no admite pagos. Registralo como pago a cuenta del cliente.',
      NEW.pedido_id, v_estado
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3 · auditoria_integridad(): la foto de la rendición y los pedazos (punto 3 de #1440)
-- ----------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def    text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_cierre text := E'\n  )\n  SELECT jsonb_agg(\n';
  v_nuevos text := $a$,
    -- #1248 · la foto acompaña al estado: se toma al cerrar la rendición y se
    -- descarta al reabrirla (rendicion_control_foto), con sus totales. Una
    -- cerrada sin totales no pasó por la foto; una abierta con foto o con
    -- totales no la soltó. Una cerrada sin filas es un día sin cobros.
    ('REND-A','high','rendiciones cuya foto no acompaña al estado: abierta con foto o con totales, o cerrada sin totales (#1248)',
      (SELECT count(*) FROM rendiciones_control rc
        WHERE CASE WHEN rc.estado IN ('confirmada','resuelta')
                   THEN rc.total_entregado_confirmado IS NULL OR rc.cantidad_pedidos_confirmada IS NULL
                   ELSE rc.total_entregado_confirmado IS NOT NULL OR rc.cantidad_pedidos_confirmada IS NOT NULL
                        OR EXISTS (SELECT 1 FROM rendicion_pagos_confirmados fo WHERE fo.rendicion_id = rc.id)
              END)),
    -- #1248 · un pago entra a lo sumo a una foto cerrada: _rendicion_pagos lee
    -- cada foto entera, y en dos el día cerrado lo cuenta dos veces.
    ('REND-B','high','pagos que están en la foto de dos rendiciones cerradas (#1248)',
      (SELECT count(*) FROM (
         SELECT fo.pago_id
           FROM rendicion_pagos_confirmados fo
           JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
          WHERE rc.estado IN ('confirmada','resuelta')
          GROUP BY fo.pago_id
         HAVING count(*) > 1) x)),
    -- #1292 · el corte de una foto es uno, el último pago que existía al
    -- tomarla, y ningún pago de la foto nació después: con eso _rendicion_pagos
    -- sabe si un pedazo ya estaba o salió de la plata que la foto guardó.
    ('REND-C','high','fotos de rendición con más de un corte o con un pago posterior a su corte (#1292)',
      (SELECT count(*) FROM (
         SELECT fo.rendicion_id
           FROM rendicion_pagos_confirmados fo
          GROUP BY fo.rendicion_id
         HAVING count(DISTINCT fo.ultimo_pago_id) > 1
             OR max(fo.pago_id) > min(fo.ultimo_pago_id)) x)),
    -- #833 y #1248 · un crédito de NC no es plata de la rendición, y un pago no
    -- cambia de sucursal: la foto no tiene ni uno ni otro. Un pago borrado
    -- después queda en la foto, que es lo que se rindió.
    ('REND-D','high','fotos de rendición con un crédito de NC o con un pago de otra sucursal (#833, #1248)',
      (SELECT count(*) FROM rendicion_pagos_confirmados fo
         JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
         LEFT JOIN pagos pg ON pg.id = fo.pago_id
        WHERE fo.forma_pago = 'nota_credito' OR pg.sucursal_id <> rc.sucursal_id)),
    -- #1292 y #1359 · un pedazo nace de su padre, en su sucursal y con su raíz
    -- (COALESCE(pago_origen_id, id)), y nada reescribe esas dos columnas.
    -- _rendicion_pagos sube la cadena por el padre: con una raíz cruzada, un
    -- pedazo de un día cerrado vuelve a contarse vivo. Un padre borrado no es
    -- rojo: en un día abierto el admin puede borrar lo que quedó de un pago
    -- partido, y su pedazo sigue siendo plata que entró.
    ('PAGO-A','high','pedazos de pago con otra raíz que la de su padre o con el padre en otra sucursal (#1292, #1359)',
      (SELECT count(*) FROM pagos h
         JOIN pagos pa ON pa.id = h.pago_padre_id
        WHERE pa.sucursal_id <> h.sucursal_id
           OR h.pago_origen_id IS DISTINCT FROM COALESCE(pa.pago_origen_id, pa.id)))$a$;
  v_id     text;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_cierre, ''))) / length(v_cierre) <> 1 THEN
    RAISE EXCEPTION 'auditoria_integridad: el cierre de la lista de checks no está una vez';
  END IF;
  -- La salida es una lista: un id repetido no falla ni se nota.
  FOREACH v_id IN ARRAY ARRAY['REND-A', 'REND-B', 'REND-C', 'REND-D', 'PAGO-A'] LOOP
    IF position('''' || v_id || '''' in v_def) > 0 THEN
      RAISE EXCEPTION 'auditoria_integridad ya tiene el id %', v_id;
    END IF;
  END LOOP;

  EXECUTE replace(v_def, v_cierre, v_nuevos || v_cierre);
END
$patch$;

-- ----------------------------------------------------------------------------
-- 4 · Verificación
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
  v_a     jsonb := public.auditoria_integridad();
  v_rojos text;
  r       record;
BEGIN
  -- Ningún id repetido, en toda la lista.
  SELECT string_agg(i, ', ') INTO v_rojos
    FROM (SELECT c->>'id' AS i FROM jsonb_array_elements(v_a->'checks') c
           GROUP BY 1 HAVING count(*) > 1) x;
  IF v_rojos IS NOT NULL THEN
    RAISE EXCEPTION 'ids repetidos en auditoria_integridad: %', v_rojos;
  END IF;
  IF (v_a->>'total_checks')::int <> 84 THEN
    RAISE EXCEPTION 'auditoria_integridad quedó con % checks, no 84', v_a->>'total_checks';
  END IF;

  -- Cada check nuevo nace en 0.
  SELECT string_agg(format('%s = %s', c->>'id', c->>'violaciones'), ', ') INTO v_rojos
    FROM jsonb_array_elements(v_a->'checks') c
   WHERE c->>'id' = ANY (ARRAY['REND-A', 'REND-B', 'REND-C', 'REND-D', 'PAGO-A'])
     AND (c->>'violaciones')::bigint <> 0;
  IF v_rojos IS NOT NULL THEN
    RAISE EXCEPTION 'checks nuevos en rojo al aplicar: %', v_rojos;
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_a->'checks') c
       WHERE c->>'id' = ANY (ARRAY['REND-A', 'REND-B', 'REND-C', 'REND-D', 'PAGO-A'])) <> 5 THEN
    RAISE EXCEPTION 'falta algún check nuevo en auditoria_integridad';
  END IF;

  -- Los cuerpos que quedaron son los del repo, y CREATE OR REPLACE conservó el EXECUTE.
  FOR r IN
    SELECT x.firma, x.md5, x.acl, md5(p.prosrc) AS md5_vivo, p.proacl::text AS acl_vivo
      FROM (VALUES
        ('public.pago_solicitud_abrir(uuid,text)', '8448a3629708a5b92d9db264ded848f3',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.guard_pago_fecha_cerrada()', 'a763cdd5980b0e0f18cb549ee97629de',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.pagos_rechazar_pedido_de_baja()', 'e2b11d330a549e4978428b231f10649a',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.auditoria_integridad()', '89bed02a56b547e60fb052f48c47283a',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
      ) AS x(firma, md5, acl)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF r.md5_vivo <> r.md5 OR r.acl_vivo <> r.acl THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %)', r.firma, r.md5_vivo, r.acl_vivo;
    END IF;
  END LOOP;
END
$post$;

-- ----------------------------------------------------------------------------
-- 5 · #1399: sin el índice, y la columna congelada
-- ----------------------------------------------------------------------------
DROP INDEX public.idx_pagos_client_request_id;

ALTER TABLE public.pagos
  ADD CONSTRAINT pagos_client_request_id_historico
  CHECK (client_request_id IS NULL OR id <= 8049);

COMMENT ON COLUMN public.pagos.client_request_id IS
  'Histórica (mig 167): la clave de idempotencia de los pagos hasta #1246. Desde entonces la idempotencia es pagos_solicitudes y nada escribe esta columna; el CHECK pagos_client_request_id_historico la congela (#1399).';

DO $post_pagos$
BEGIN
  IF to_regclass('public.idx_pagos_client_request_id') IS NOT NULL THEN
    RAISE EXCEPTION 'idx_pagos_client_request_id sigue en pie';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pagos'::regclass
                    AND conname = 'pagos_client_request_id_historico'
                    AND contype = 'c' AND convalidated) THEN
    RAISE EXCEPTION 'falta el CHECK pagos_client_request_id_historico';
  END IF;
END
$post_pagos$;

COMMIT;
