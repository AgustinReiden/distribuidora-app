-- NNN · Cargo de envio: la edicion recalcula o pregunta por el cargo (#1220).
--
-- Diseno: docs/superpowers/specs/2026-10-26-cargo-envio-faltantes-design.md, §1.
-- Segunda migracion del plan: requiere la anterior (cargo_1_base), que crea
-- pedidos.cargo_envio_estado, cargo_tras_edicion y cargo_envio_desglose.
--
-- Hasta aca actualizar_pedido_items CONSERVABA siempre el cargo (389, seccion
-- 7). Ahora:
--
--   * El cargo se reconsidera solo si la edicion CAMBIA LA FRANJA (debajo /
--     arriba del umbral de envio gratis, con la politica VIGENTE de la
--     sucursal). Sin cruce, el pedido conserva su cargo aunque el costo del
--     envio haya cambiado desde el alta.
--   * Preventista: automatico (debajo cobra el costo vigente, arriba gratis); si
--     manda una decision, se ignora.
--   * Admin o encargado (perfiles.rol): deciden. Sin decision, la RPC NO toca
--     nada (ni lineas ni stock) y contesta
--       {success:false, errores:[...], codigo:'requiere_decision_envio',
--        cargo, franja, total_productos}
--     para que el modal pregunte y reintente con p_decision_envio
--     ('cobrar' | 'no_cobrar'). 'no_cobrar' debajo del umbral deja el pedido
--     'bonificado'.
--   * Un pedido 'no_aplica' (nacio sin cargo de politica, VB, canje) nunca lo
--     gana, y si la sucursal hoy no cobra envio no se recalcula nada.
--   * Sin productos (total de productos <= 0) no se paga envio.
--   La regla es la pura cargo_tras_edicion (espejo cargoTrasEdicion): esta
--   funcion solo le pasa los datos. Los totales que recibe son de PRODUCTOS
--   (sin el cargo): el viejo es GREATEST(total - cargo_envio, 0), como ya leia
--   la 389.
--
-- El UPDATE final escribe total = productos + cargo efectivo, cargo_envio,
-- cargo_envio_estado, y el neto/IVA con el desglose del cargo efectivo
-- (cargo_envio_desglose: FC 21 % incluido, ZZ todo neto). Nombra monto_pagado
-- (trampa 6: los AFTER ... OF total, monto_pagado disparan por la lista del SET).
--
-- FIRMA. p_decision_envio text DEFAULT NULL es un cuarto parametro, asi que la
-- funcion se recrea: DROP de la de tres parametros en esta misma migracion
-- (trampa 5: dos sobrecargas con rangos superpuestos dan PGRST203). El front que
-- esta en produccion llama con tres argumentos con nombre y resuelve a esta por
-- el DEFAULT. Mismos permisos que la viva: EXECUTE para authenticated y
-- service_role; nada para PUBLIC ni anon.
--
-- El cuerpo NO se copia: se lee el vivo con pg_get_functiondef y se le
-- reemplazan anclas que tienen que aparecer exactamente una vez (molde 373 /
-- cargo_1_base). Si el cuerpo vivo cambio, la migracion se cae en vez de pisar.
--
-- Ensayo: scripts/test-cargo-2.sql (acumulado: cargo_1_base + esta).

SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION pg_temp.cargo2_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_veces int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF v_veces <> 1 THEN
    RAISE EXCEPTION '%: el ancla aparece % veces (se esperaba 1). El cuerpo vivo cambio: revisar a mano', p_que, v_veces;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  -- 1 · La firma: un cuarto parametro con DEFAULT.
  v_def := pg_temp.cargo2_parchar(v_def,
$q$CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(p_pedido_id bigint, p_items_nuevos jsonb, p_usuario_id uuid)$q$,
$q$CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(p_pedido_id bigint, p_items_nuevos jsonb, p_usuario_id uuid, p_decision_envio text DEFAULT NULL)$q$,
    'actualizar_pedido_items: firma');

  -- 2 · Declaraciones.
  v_def := pg_temp.cargo2_parchar(v_def,
$q$  v_cargo_envio NUMERIC := 0; -- mig 389 (#1220)$q$,
$q$  v_cargo_envio NUMERIC := 0; -- mig 389 (#1220)
  -- cargo_2_edicion: el estado del cargo, la politica vigente y el cargo tras
  -- la edicion (cargo_tras_edicion).
  v_cargo_estado     TEXT;
  v_pol              public.politicas_comerciales%ROWTYPE;
  v_es_preventista   BOOLEAN;
  v_total_proyectado NUMERIC;
  v_umbral_envio     NUMERIC;
  v_cargo_tras       RECORD;
  v_cargo_efectivo   NUMERIC;$q$,
    'actualizar_pedido_items: declaraciones');

  -- 3 · El estado se lee con el cargo, bajo el mismo FOR UPDATE.
  v_def := pg_temp.cargo2_parchar(v_def,
$q$COALESCE(tipo_factura, 'ZZ'), cargo_envio
    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura, v_cargo_envio$q$,
$q$COALESCE(tipo_factura, 'ZZ'), cargo_envio,
         cargo_envio_estado -- cargo_2_edicion
    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura, v_cargo_envio,
         v_cargo_estado$q$,
    'actualizar_pedido_items: lectura del pedido');

  -- 4 · Antes de tocar lineas o stock: si hace falta una decision del admin o
  --     del encargado, se pide y no se cambia nada.
  v_def := pg_temp.cargo2_parchar(v_def,
$q$  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;$q$,
$q$  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;

  -- cargo_2_edicion: el cargo de envio tras la edicion. Va antes de la primera
  -- escritura (hasta aca solo hay lecturas y locks): si el admin o el
  -- encargado tienen que decidir, el pedido queda como estaba. El total de
  -- productos que va a quedar es la misma cuenta que v_total_nuevo abajo
  -- (cantidad * precio de cada linea que no es regalo).
  IF p_decision_envio IS NOT NULL AND p_decision_envio NOT IN ('cobrar', 'no_cobrar') THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
      'Decisión de envío inválida: ' || p_decision_envio || '. El pedido no se modificó.'));
  END IF;
  v_es_preventista := v_user_role NOT IN ('admin', 'encargado');
  SELECT * INTO v_pol FROM public.politicas_comerciales WHERE sucursal_id = v_sucursal;
  SELECT COALESCE(SUM((e->>'cantidad')::NUMERIC * COALESCE(NULLIF(e->>'precio_unitario', '')::NUMERIC, 0)), 0)
    INTO v_total_proyectado
    FROM jsonb_array_elements(v_items) e
   WHERE NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false);
  SELECT * INTO v_cargo_tras
    FROM public.cargo_tras_edicion(v_cargo_estado, v_cargo_envio, v_total_anterior, v_total_proyectado,
                                   v_pol.modo_minimo_pedido, v_pol.monto_minimo_pedido,
                                   v_pol.monto_envio_gratis, v_pol.cargo_envio_pedido,
                                   v_es_preventista, p_decision_envio);
  IF v_cargo_tras.requiere_decision THEN
    -- Solo hay decision con cruce de franja: la franja nueva dice que se
    -- pregunta. Debajo: agregar el envio vigente; arriba: sacar el que tiene.
    v_umbral_envio := CASE v_pol.modo_minimo_pedido WHEN 'cargo' THEN v_pol.monto_minimo_pedido
                                                    ELSE v_pol.monto_envio_gratis END;
    IF v_total_proyectado > 0 AND v_total_proyectado < v_umbral_envio THEN
      RETURN jsonb_build_object('success', false,
        'errores', jsonb_build_array(format('El pedido quedó en %s. ¿Agregar envío de %s?',
          to_char(v_total_proyectado, 'FM$999G999G990D00'), to_char(v_pol.cargo_envio_pedido, 'FM$999G999G990D00'))),
        'codigo', 'requiere_decision_envio', 'franja', 'debajo',
        'cargo', v_pol.cargo_envio_pedido, 'total_productos', v_total_proyectado);
    END IF;
    RETURN jsonb_build_object('success', false,
      'errores', jsonb_build_array(format('El pedido quedó en %s. ¿Sacar el envío de %s?',
        to_char(v_total_proyectado, 'FM$999G999G990D00'), to_char(v_cargo_envio, 'FM$999G999G990D00'))),
      'codigo', 'requiere_decision_envio', 'franja', 'arriba',
      'cargo', v_cargo_envio, 'total_productos', v_total_proyectado);
  END IF;$q$,
    'actualizar_pedido_items: decision del envio');

  -- 5 · El UPDATE final: el cargo y su estado tras la edicion, con el total de
  --     productos que de verdad quedo, y el neto/IVA con el envio efectivo.
  v_def := pg_temp.cargo2_parchar(v_def,
$q$  UPDATE pedidos SET total = v_total_nuevo + CASE WHEN v_total_nuevo > 0 THEN v_cargo_envio ELSE 0 END, total_neto = round(v_total_neto_nuevo, 2), total_iva = round(v_total_iva_nuevo, 2), total_real = round(v_total_real_nuevo, 2), updated_at = NOW()$q$,
$q$  -- cargo_2_edicion: se recalcula con v_total_nuevo (el que quedo; es la
  -- misma cuenta que v_total_proyectado). Con la decision que ya vino no puede
  -- volver a pedir una; si pasara, se deshace todo en vez de guardar a medias.
  SELECT * INTO v_cargo_tras
    FROM public.cargo_tras_edicion(v_cargo_estado, v_cargo_envio, v_total_anterior, v_total_nuevo,
                                   v_pol.modo_minimo_pedido, v_pol.monto_minimo_pedido,
                                   v_pol.monto_envio_gratis, v_pol.cargo_envio_pedido,
                                   v_es_preventista, p_decision_envio);
  IF v_cargo_tras.requiere_decision THEN
    RAISE EXCEPTION 'El cargo de envío del pedido % cambió durante la edición: volvé a guardar', p_pedido_id;
  END IF;
  -- El efectivo: sin productos no se cobra (la formula de la 389, VENTA-A).
  v_cargo_efectivo := CASE WHEN v_total_nuevo > 0 THEN v_cargo_tras.cargo ELSE 0 END;
  UPDATE pedidos
     SET total = v_total_nuevo + v_cargo_efectivo,
         cargo_envio = v_cargo_tras.cargo,
         cargo_envio_estado = v_cargo_tras.estado,
         total_neto = round(v_total_neto_nuevo, 2)
                      + (public.cargo_envio_desglose(v_cargo_efectivo, v_tipo_factura)).neto,
         total_iva = round(v_total_iva_nuevo, 2)
                     + (public.cargo_envio_desglose(v_cargo_efectivo, v_tipo_factura)).iva,
         total_real = round(v_total_real_nuevo, 2),
         monto_pagado = monto_pagado,
         updated_at = NOW()$q$,
    'actualizar_pedido_items: UPDATE final');

  -- 6 · La respuesta: claves nuevas (el front en produccion lee solo success).
  v_def := pg_temp.cargo2_parchar(v_def,
$q$RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);$q$,
$q$RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo,
                            -- cargo_2_edicion
                            'total', v_total_nuevo + v_cargo_efectivo,
                            'cargo_envio', v_cargo_tras.cargo,
                            'cargo_envio_estado', v_cargo_tras.estado);$q$,
    'actualizar_pedido_items: respuesta');

  -- La de tres parametros se va; la nueva nace con los permisos de la viva.
  DROP FUNCTION public.actualizar_pedido_items(bigint, jsonb, uuid);
  EXECUTE v_def;
END
$patch$;

REVOKE ALL ON FUNCTION public.actualizar_pedido_items(bigint, jsonb, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_pedido_items(bigint, jsonb, uuid, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f     regprocedure := to_regprocedure('public.actualizar_pedido_items(bigint,jsonb,uuid,text)');
  v_def text;
BEGIN
  IF f IS NULL THEN
    RAISE EXCEPTION 'actualizar_pedido_items(bigint, jsonb, uuid, text) no existe';
  END IF;
  -- Una sola: la vieja no puede convivir (PGRST203).
  IF (SELECT count(*) FROM pg_proc
       WHERE pronamespace = 'public'::regnamespace AND proname = 'actualizar_pedido_items') <> 1 THEN
    RAISE EXCEPTION 'Quedo mas de una actualizar_pedido_items';
  END IF;
  v_def := pg_get_functiondef(f);
  IF v_def NOT LIKE '%cargo_2_edicion%' OR v_def NOT LIKE '%cargo_tras_edicion%'
     OR v_def NOT LIKE '%cargo_envio_desglose%' OR v_def NOT LIKE '%p_decision_envio text DEFAULT NULL%' THEN
    RAISE EXCEPTION 'actualizar_pedido_items no quedo parcheada';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f)
     OR NOT ('search_path=public' = ANY (SELECT unnest(proconfig) FROM pg_proc WHERE oid = f)) THEN
    RAISE EXCEPTION 'actualizar_pedido_items perdio SECURITY DEFINER o su search_path';
  END IF;
  -- Permisos: los de la viva.
  IF has_function_privilege('anon', f, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = f AND a.grantee = 0)
     OR NOT has_function_privilege('authenticated', f, 'EXECUTE')
     OR NOT has_function_privilege('service_role', f, 'EXECUTE') THEN
    RAISE EXCEPTION 'actualizar_pedido_items quedo con permisos distintos de la viva';
  END IF;
  -- Sigue validando el rol (SEG-A).
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() WHERE firma LIKE 'actualizar_pedido_items(%') THEN
    RAISE EXCEPTION 'actualizar_pedido_items quedo en rojo en SEG-A';
  END IF;
END
$verif$;

-- ROLLBACK: DROP FUNCTION public.actualizar_pedido_items(bigint, jsonb, uuid, text)
-- y volver a crear la de tres parametros con el cuerpo vivo de antes de esta
-- migracion (la 389 seccion 7 sobre la 275 y sus parches), con EXECUTE para
-- authenticated y service_role. Los pedidos que esta version dejo 'bonificado'
-- o con el cargo recalculado quedan como estan (son datos validos para la
-- version anterior: total = productos + cargo).
