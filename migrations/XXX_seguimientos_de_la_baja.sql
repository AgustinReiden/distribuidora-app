-- Seguimientos de la baja (#1147, #1149, #1150): tres cabos sueltos de la
-- tanda #1131-#1142, sin cambio de comportamiento para la app salvo el corte
-- de #1150.
--
-- #1147 · eliminar_pedido_completo se queda sin EXECUTE para la app.
--   Desde #1132 no la llama nada: ni el front, ni las edge functions, ni otra
--   funcion, vista o policy de prod, y no hay pg_cron. Pero authenticated
--   conservaba EXECUTE, asi que un admin podia borrar fisicamente un pedido por
--   REST (pedidos, pedido_items, pedido_historial) salteando la baja logica de
--   la 360. Decision del duenio (2026-10-14): revocar, no dropear. Se revoca a
--   las tres mitades (PUBLIC, anon, authenticated), la receta de CLAUDE.md para
--   una funcion que no llama el frontend. No se redefine el cuerpo (el de la
--   354) y no hay sobrecargas. service_role queda en el ACL por el default de
--   Supabase, pero no es un camino que funcione: la funcion exige
--   p_usuario_id = auth.uid() con rol admin, y por la service key auth.uid() es
--   NULL. Solo corre como postgres con los claims de un admin armados a mano
--   (SQL editor, y los ensayos 1125, 1085 y 1114, que la llaman asi). Es
--   reversible con un GRANT. pedidos_eliminados queda como historial de solo
--   lectura.
--
-- #1150 · guard_pago_fecha_cerrada deja seguir el reintento de un pago que ya
--   entro, como pagos_rechazar_pedido_de_baja desde la 360. El trigger es
--   BEFORE y corre antes que idx_pagos_client_request_id: si la caja se cerro
--   entre los dos intentos (o el reintento sin fecha cruzo medianoche y cayo en
--   un dia cerrado), el reintento recibia 42501 en vez del 23505 con el que el
--   front devuelve la fila existente (mig 167), y el usuario lo volvia a cargar
--   con otra fecha: cobro duplicado. El corte no deja entrar ninguna fila: con
--   el UUID ya presente el indice parcial lo rechaza siempre; solo cambia el
--   codigo. Solo en INSERT: en un UPDATE de fecha o monto el client_request_id
--   es el de la propia fila, y la caja manda.
--   Riesgo aceptado, el mismo de la 360: si otra transaccion borra el pago
--   original entre el EXISTS y el indice, el reintento entra sin el guard. Solo
--   lo puede borrar el server (desafectar_sobrepago_pedido): desde la app,
--   pagos_guard_anulacion_caja_cerrada impide anular un pago con fecha cerrada.
--
-- #1149 · la baja conserva pedidos.transportista_id a proposito. Decision del
--   duenio (2026-10-14): conservar y documentar. Es el historial de quien lo
--   llevo: jornadas_transportista y jornada_transportista_detalle muestran los
--   cancelados del chofer como 'rechazado', mt_pagos_insert lo pide para que el
--   reintento idempotente del chofer llegue al 23505 (limpiarlo reabria para
--   ese rol lo que cerro la 360), y cambiarlo dispara trg_pedidos_anular_control.
--   El transportista sigue viendo sus cancelados en /pedidos (Incluir
--   cancelados). Solo el COMMENT ON COLUMN. Esto NO deja la baja cerrada a
--   escritura: el transportista todavia puede cambiar fecha_entrega de sus
--   pedidos, cancelados incluidos (issue aparte).
--
-- No se tocan cancelar_pedido_con_stock, mt_pedidos_select, puede_leer_pedido,
-- la definicion del trigger trg_pagos_guard_fecha_cerrada (OF fecha, monto) ni
-- los otros triggers de pagos (pagos_guard_nota_credito, pagos_rechazar_pedido_vb).
-- No hay GUCs ni parametros nuevos, ningun UPDATE productos.stock ni escritura
-- de costo: STK-F, STK-D y COSTO-D no se mueven. check-permisos.mjs solo mira
-- anon, y aca solo se reduce.
--
-- guard_pago_fecha_cerrada se reescribe desde pg_get_functiondef de PROD del
-- 2026-10-14 (md5 1a0d30a9c84e1d149a5c5bbba6bdb1a2) sumando solo el bloque
-- #1150. La seccion 4 verifica que el diff contra el cuerpo previo sea
-- exactamente ese bloque: si prod cambio antes de aplicar, la migracion aborta.

-- ---------------------------------------------------------------------------
-- 0 - Foto previa
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE t_antes AS
SELECT pg_get_functiondef('public.guard_pago_fecha_cerrada()'::regprocedure) AS def_guard,
       (SELECT proacl::text FROM pg_proc WHERE oid = 'public.guard_pago_fecha_cerrada()'::regprocedure) AS acl_guard,
       md5(pg_get_functiondef('public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure)) AS md5_elim,
       (public.auditoria_permisos_execute()->>'expuestas_a_anon')::int AS expuestas_a_anon;

-- ---------------------------------------------------------------------------
-- 1 - #1147: eliminar_pedido_completo sin EXECUTE para la app
-- ---------------------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.eliminar_pedido_completo(bigint, uuid, text, boolean)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.eliminar_pedido_completo(bigint, uuid, text, boolean) IS
  '#1147: sin llamador desde #1132 y sin EXECUTE para la app. Borrado fisico solo invocable '
  'como postgres con los claims de un admin (SQL editor / ensayos 1125, 1085, 1114): exige '
  'p_usuario_id = auth.uid() con rol admin, asi que por la service key no corre. La app da de '
  'baja con cancelar_pedido_con_stock. pedidos_eliminados queda como historial de solo lectura.';

-- ---------------------------------------------------------------------------
-- 2 - #1150: guard_pago_fecha_cerrada deja seguir el reintento idempotente
-- ---------------------------------------------------------------------------

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

  -- Reimputacion interna (mig 165): mover plata ya cobrada entre boletas del mismo
  -- cliente no altera el total del dia ni la rendicion, solo a que boleta se aplica.
  -- El GUC es transaction-scoped y lo setean unicamente las funciones de abajo.
  IF current_setting('app.reimputacion_pagos', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- mig 276 (#833): un credito de NC no es plata de la rendicion (las RPCs de
  -- rendiciones lo excluyen), asi que emitirlo un dia con la caja controlada
  -- no la desbalancea. Quien lo puede crear lo decide pagos_guard_nota_credito.
  IF NEW.forma_pago = 'nota_credito' THEN
    RETURN NEW;
  END IF;

  -- #1150 (molde: pagos_rechazar_pedido_de_baja, mig 360). Reintento de un pago
  -- que ya entro (mig 167): se deja seguir hasta idx_pagos_client_request_id,
  -- que da el 23505 con el que el front devuelve la fila existente. Si la caja
  -- se cerro entre los dos intentos (o el reintento sin fecha cruzo medianoche
  -- y cayo en un dia cerrado), rechazarlo con 42501 invita a cargarlo de nuevo
  -- con otra fecha y duplica el cobro. No deja entrar ninguna fila: con el UUID
  -- ya presente el indice parcial lo rechaza siempre; solo cambia el codigo.
  -- Solo en INSERT: en un UPDATE de fecha o monto el client_request_id es el de
  -- la propia fila, y la caja manda.
  IF TG_OP = 'INSERT' AND NEW.client_request_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM pagos WHERE client_request_id = NEW.client_request_id) THEN
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

-- Funcion de trigger: sin EXECUTE para nadie (CLAUDE.md). CREATE OR REPLACE ya
-- conserva el ACL; se reafirma por las dudas.
REVOKE ALL ON FUNCTION public.guard_pago_fecha_cerrada() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3 - #1149: la baja conserva transportista_id, y queda dicho
-- ---------------------------------------------------------------------------

COMMENT ON COLUMN public.pedidos.transportista_id IS
  '#1149: la baja (cancelar_pedido_con_stock) lo conserva a proposito: es el historial de '
  'quien lo llevo. El transportista sigue viendo sus cancelados como historial en /pedidos '
  '(Incluir cancelados) y en su jornada (jornadas_transportista los rotula ''rechazado''). '
  'mt_pagos_insert lo pide para que el reintento idempotente del chofer llegue al 23505, y '
  'cambiarlo dispara trg_pedidos_anular_control.';

-- ---------------------------------------------------------------------------
-- 4 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_a     record;
  v_guard text := pg_get_functiondef('public.guard_pago_fecha_cerrada()'::regprocedure);
  v_elim  regprocedure := 'public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure;
  -- El bloque #1150 tal como queda en pg_get_functiondef, con la linea en
  -- blanco que lo separa de v_limite.
  v_bloque text := $b$  -- #1150 (molde: pagos_rechazar_pedido_de_baja, mig 360). Reintento de un pago
  -- que ya entro (mig 167): se deja seguir hasta idx_pagos_client_request_id,
  -- que da el 23505 con el que el front devuelve la fila existente. Si la caja
  -- se cerro entre los dos intentos (o el reintento sin fecha cruzo medianoche
  -- y cayo en un dia cerrado), rechazarlo con 42501 invita a cargarlo de nuevo
  -- con otra fecha y duplica el cobro. No deja entrar ninguna fila: con el UUID
  -- ya presente el indice parcial lo rechaza siempre; solo cambia el codigo.
  -- Solo en INSERT: en un UPDATE de fecha o monto el client_request_id es el de
  -- la propia fila, y la caja manda.
  IF TG_OP = 'INSERT' AND NEW.client_request_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM pagos WHERE client_request_id = NEW.client_request_id) THEN
    RETURN NEW;
  END IF;

$b$;
BEGIN
  SELECT * INTO v_a FROM t_antes;

  -- #1150: el diff contra el cuerpo previo es exactamente el bloque nuevo.
  IF (length(v_guard) - length(replace(v_guard, v_bloque, ''))) / length(v_bloque) <> 1
     OR replace(v_guard, v_bloque, '') IS DISTINCT FROM v_a.def_guard THEN
    RAISE EXCEPTION 'guard_pago_fecha_cerrada: el diff contra prod no es solo el bloque #1150 (prod cambio?): revisar a mano';
  END IF;
  -- El corte va antes de leer la caja.
  IF position('#1150' IN v_guard) > position('ultima_fecha_caja_cerrada' IN v_guard) THEN
    RAISE EXCEPTION 'guard_pago_fecha_cerrada: el corte #1150 quedo despues del chequeo de caja';
  END IF;
  -- Funcion de trigger: el ACL no cambio y nadie de la app la ejecuta.
  IF v_a.acl_guard IS DISTINCT FROM (SELECT proacl::text FROM pg_proc
                                      WHERE oid = 'public.guard_pago_fecha_cerrada()'::regprocedure) THEN
    RAISE EXCEPTION 'el ACL de guard_pago_fecha_cerrada cambio';
  END IF;
  IF has_function_privilege('public', 'public.guard_pago_fecha_cerrada()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.guard_pago_fecha_cerrada()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.guard_pago_fecha_cerrada()', 'EXECUTE') THEN
    RAISE EXCEPTION 'guard_pago_fecha_cerrada quedo ejecutable por la app';
  END IF;

  -- #1147: nadie de la app la ejecuta; el cuerpo es el de antes; una sola sobrecarga.
  IF has_function_privilege('public', v_elim, 'EXECUTE')
     OR has_function_privilege('anon', v_elim, 'EXECUTE')
     OR has_function_privilege('authenticated', v_elim, 'EXECUTE') THEN
    RAISE EXCEPTION 'eliminar_pedido_completo sigue ejecutable por PUBLIC, anon o authenticated';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
              WHERE p.oid = v_elim
                AND x.grantee NOT IN ('postgres'::regrole, 'service_role'::regrole)) THEN
    RAISE EXCEPTION 'eliminar_pedido_completo tiene EXECUTE para alguien mas que postgres y service_role';
  END IF;
  IF md5(pg_get_functiondef(v_elim)) IS DISTINCT FROM v_a.md5_elim THEN
    RAISE EXCEPTION 'el cuerpo de eliminar_pedido_completo cambio';
  END IF;
  IF COALESCE(obj_description(v_elim, 'pg_proc'), '') NOT LIKE '#1147:%' THEN
    RAISE EXCEPTION 'eliminar_pedido_completo sin su COMMENT de #1147';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = 'eliminar_pedido_completo') <> 1 THEN
    RAISE EXCEPTION 'hay mas de una sobrecarga de eliminar_pedido_completo';
  END IF;

  -- #1149
  IF COALESCE(col_description('public.pedidos'::regclass,
       (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.pedidos'::regclass
           AND attname = 'transportista_id')), '') NOT LIKE '#1149:%' THEN
    RAISE EXCEPTION 'pedidos.transportista_id sin su COMMENT de #1149';
  END IF;

  -- Lo expuesto a anon no cambio (aca solo se revoca).
  IF (public.auditoria_permisos_execute()->>'expuestas_a_anon')::int IS DISTINCT FROM v_a.expuestas_a_anon THEN
    RAISE EXCEPTION 'cambio la cantidad de funciones expuestas a anon';
  END IF;
END
$verif$;

DROP TABLE t_antes;
