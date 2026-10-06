-- =========================================================================
-- mig 289 · EL INACTIVO NO SE REGALA NI SE AGREGA (#945)
--
-- La 284 dio de alta la baja logica de productos y cerro el ALTA de pedidos a
-- los inactivos, con dos huecos a proposito que el dueno decidio cerrar:
--
--   1 · Los REGALOS estaban exentos. Decision del dueno: un producto
--       desactivado tampoco puede regalarse. crear_pedido_completo y
--       crear_pedido_completo_bot rechazan el inactivo venga como venta o
--       como regalo, con el mismo mensaje de la 284.
--   2 · La EDICION (actualizar_pedido_items) dejaba agregar un inactivo
--       (#945). Ahora lo rechaza, pero SOLO si el pedido no lo tenia: la
--       edicion borra y reinserta todas las lineas, asi que exigir "activo"
--       a todas haria ineditable cualquier pedido viejo con un producto que
--       se desactivo despues.
--   3 · Los dos caminos que eligen un producto NUEVO para un regalo que ya
--       existe: sustituir_regalo_pedido y dividir_regalo_pedido. Rechazan un
--       sustituto / una parte inactiva, salvo que sea el producto original de
--       la linea (ver el por que en cada uno).
--
-- Mismo metodo que la 284: cirugia por ancla sobre el cuerpo VIVO de prod.
-- CREATE OR REPLACE conserva firma, SECURITY DEFINER, search_path y GRANTs;
-- el $verif$ del final lo comprueba contra proacl. Si un ancla no aparece
-- exactamente una vez, la migracion entera se cae y no se aplica nada.
--
-- COSTO-D: nada de esto escribe costo_unitario_al_crear ni toca las lineas
-- que lo hacen. STK-F: nada de esto sube stock. Los chequeos van todos ANTES
-- de mover stock, salvo la red final de la edicion, que es un RAISE (deshace
-- la transaccion entera).
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._mig_inactivo_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · Alta de pedido: el inactivo se rechaza tambien como regalo
--
-- El loop recorre v_cantidades_totales, que tiene TODOS los productos del
-- pedido (vendidos y regalados, muevan stock o no), asi que alcanza con
-- sacar la condicion de la 284 que miraba si aparecia en una linea vendida.
--
-- Consecuencia buscada, y que hay que saber: si el sabor default de una promo
-- (promociones.producto_regalo_id) se desactiva, todo pedido que dispare esa
-- promo falla con "<nombre> está desactivado y no se puede vender" hasta que
-- el admin le cambie el sabor a la promo. Es exactamente lo que la 284 queria
-- evitar; el dueno prefirio que el regalo de un discontinuado no salga.
-- -------------------------------------------------------------------------
SELECT public._mig_inactivo_ancla(
  'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure,
  $a$    -- mig 284: un inactivo no se vende (un cache offline viejo puede traerlo).
    -- Los regalos quedan exentos: los pone la promo, no el preventista.
    ELSIF NOT v_producto_activo AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_items) e
             WHERE (e->>'producto_id')::INT = v_producto_id
               AND NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)) THEN
$a$,
  $a$    -- mig 284: un inactivo no se vende (un cache offline viejo puede traerlo).
    -- mig 289: ni se regala. La 284 eximia a los regalos; el dueno decidio que
    -- un desactivado tampoco puede regalarse. Si el inactivo es el sabor
    -- default de una promo, el admin tiene que cambiarle el sabor a la promo.
    ELSIF NOT v_producto_activo THEN
$a$);

SELECT public._mig_inactivo_ancla(
  'public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure,
  $a$    -- mig 284: misma regla que crear_pedido_completo. La confirmacion pendiente
    -- puede ser de antes de la baja. Los regalos quedan exentos.
    ELSIF NOT v_producto_activo AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_pendiente.items) e
             WHERE (e->>'producto_id')::INT = v_producto_id
               AND NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)) THEN
$a$,
  $a$    -- mig 284: misma regla que crear_pedido_completo. La confirmacion pendiente
    -- puede ser de antes de la baja. mig 289: tampoco se regala (decision del
    -- dueno; la 284 eximia a los regalos).
    ELSIF NOT v_producto_activo THEN
$a$);

-- -------------------------------------------------------------------------
-- 2 · Edicion de pedido (#945): no se AGREGA un inactivo
--
-- QUE ES "NUEVO": un par (producto, es_bonificacion) que no estaba entre las
-- lineas del pedido ANTES de la edicion. La foto es v_items_originales, que
-- la funcion ya arma desde pedido_items antes del DELETE (es la que va a
-- pedido_historial), asi que no hace falta otra lectura.
--   · Por producto Y rol, no solo por producto: si X estaba como regalo y la
--     edicion lo agrega como venta, eso es VENDER un inactivo que antes no se
--     vendia, y al reves. Las dos cosas estan prohibidas para un inactivo.
--   · Cambiar la cantidad de una linea que ya estaba NO se rechaza: es la
--     misma linea, y el pedido se armo cuando el producto era legal.
--   · La foto guarda el producto que QUEDO en cada linea (el sustituto, si lo
--     hubo), y del lado nuevo se compara tambien el producto que va a quedar:
--     regalo_sustituto_vigente, la MISMA funcion que llama el trigger
--     aplicar_sustituciones_regalo_pre_insert. Asi un regalo sustituido que
--     vuelve a viajar con el sabor original de la promo se reconoce como la
--     linea que ya estaba.
--
-- Dos lugares:
--   a · Un pre-chequeo junto al de stock, ANTES de devolver nada: el error
--       llega en `errores` con el mismo formato que "stock insuficiente".
--   b · Una red despues del INSERT ... RETURNING producto_id, sobre el
--       producto que el trigger dejo de verdad en la fila (la regla de la
--       252/257). Si alguna vez el trigger y el pre-chequeo divergen, gana
--       la fila: RAISE y se deshace toda la edicion.
-- -------------------------------------------------------------------------
SELECT public._mig_inactivo_ancla(
  'public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
  $a$  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
$a$,
  $a$  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  -- mig 289 (#945): un producto inactivo no se AGREGA al editar. "Agregar" es
  -- un par (producto, es_bonificacion) que no estaba en v_items_originales;
  -- del lado nuevo, el producto que va a quedar (el sustituto vigente de un
  -- regalo, misma funcion que el trigger). Las lineas que ya estaban siguen,
  -- aunque su producto se haya desactivado despues.
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      v_producto_sustituto := public.regalo_sustituto_vigente(
        p_pedido_id, v_promocion_id, v_producto_id, v_sucursal);
      IF v_producto_sustituto IS NOT NULL THEN
        v_producto_id := v_producto_sustituto;
      END IF;
    END IF;
    v_producto_nombre := NULL;
    SELECT nombre INTO v_producto_nombre
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal AND NOT activo;
    IF v_producto_nombre IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_items_originales, '[]'::jsonb)) o
                        WHERE (o->>'producto_id')::BIGINT = v_producto_id
                          AND (o->>'es_bonificacion')::BOOLEAN = v_es_bonificacion)
       AND NOT (v_producto_nombre || ' está desactivado y no se puede vender') = ANY(v_errores) THEN
      v_errores := array_append(v_errores, v_producto_nombre || ' está desactivado y no se puede vender');
    END IF;
  END LOOP;
$a$);

SELECT public._mig_inactivo_ancla(
  'public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
  $a$    RETURNING id, producto_id INTO v_pedido_item_guardado, v_producto_guardado;
$a$,
  $a$    RETURNING id, producto_id INTO v_pedido_item_guardado, v_producto_guardado;

    -- mig 289 (#945): red final sobre el producto que QUEDO en la fila. El
    -- pre-chequeo de arriba ya deberia haberlo frenado con el mismo criterio;
    -- si no, RAISE deshace la edicion entera (stock devuelto incluido).
    v_producto_nombre := NULL;
    SELECT nombre INTO v_producto_nombre
      FROM productos WHERE id = v_producto_guardado AND sucursal_id = v_sucursal AND NOT activo;
    IF v_producto_nombre IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_items_originales, '[]'::jsonb)) o
                        WHERE (o->>'producto_id')::BIGINT = v_producto_guardado
                          AND (o->>'es_bonificacion')::BOOLEAN = v_es_bonificacion) THEN
      RAISE EXCEPTION '% está desactivado y no se puede vender', v_producto_nombre;
    END IF;
$a$);

-- -------------------------------------------------------------------------
-- 3a · sustituir_regalo_pedido: el sustituto no puede estar inactivo
--
-- Salvo que sea el producto que la linea YA tiene: "sustituir" por el mismo
-- producto es cambiar la cantidad de una linea existente, que es lo mismo que
-- la edicion deja hacer. Va antes de mover stock o acumuladores, con el
-- {success:false, error} de las demas validaciones.
-- -------------------------------------------------------------------------
SELECT public._mig_inactivo_ancla(
  'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
  $a$  SELECT nombre INTO v_nuevo_nombre FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
$a$,
  $a$  SELECT nombre INTO v_nuevo_nombre FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
  -- mig 289: un producto desactivado no puede regalarse.
  IF p_producto_nuevo_id IS DISTINCT FROM v_item.producto_id
     AND EXISTS (SELECT 1 FROM productos
                  WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal AND NOT activo) THEN
    RETURN jsonb_build_object('success', false, 'error',
      v_nuevo_nombre || ' está desactivado y no se puede regalar');
  END IF;
$a$);

-- -------------------------------------------------------------------------
-- 3b · dividir_regalo_pedido: ninguna parte puede estar inactiva, salvo el
-- producto original de la linea
--
-- Por que se deja quedar parte del original aunque este inactivo: el reparto
-- exige al menos dos productos distintos que sumen la cantidad original, asi
-- que la parte que se queda con el original es SIEMPRE menor que lo que la
-- linea ya regalaba. No agrega regalo de un desactivado: lo achica. Rechazarlo
-- obligaria a sacar todo el original de una vez, que se puede hacer igual con
-- sustituir_regalo_pedido; y es el mismo criterio que la edicion (una linea
-- que ya estaba sigue). Lo que no se puede es sumar un sabor inactivo que la
-- linea no tenia. Va antes del chequeo de stock, sin haber movido nada.
-- -------------------------------------------------------------------------
SELECT public._mig_inactivo_ancla(
  'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
  $a$    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto del reparto que no existe en esta sucursal');
  END IF;
$a$,
  $a$    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto del reparto que no existe en esta sucursal');
  END IF;
  -- mig 289: un producto desactivado no puede regalarse. El original de la
  -- linea si puede quedar como parte: el reparto siempre lo achica.
  SELECT CASE WHEN count(*) = 1 THEN min(pr.nombre) || ' está desactivado y no se puede regalar'
              WHEN count(*) > 1 THEN 'No se pueden regalar productos desactivados: '
                                     || string_agg(pr.nombre, ', ' ORDER BY pr.nombre) END
    INTO v_nombre
    FROM unnest(v_prod) AS r(producto_id)
    JOIN productos pr ON pr.id = r.producto_id AND pr.sucursal_id = v_sucursal
   WHERE NOT pr.activo
     AND r.producto_id IS DISTINCT FROM v_item.producto_id;
  IF v_nombre IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', v_nombre);
  END IF;
$a$);

DROP FUNCTION public._mig_inactivo_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- V · Verificacion. Si algo de esto falla, no se aplica nada.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text;
  r     record;
BEGIN
  -- 1 · las altas ya no eximen regalos y siguen con COSTO-D / ledger.
  FOR r IN SELECT unnest(ARRAY[
             'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
             'public.crear_pedido_completo_bot(uuid,uuid)']) AS f LOOP
    v_def := pg_get_functiondef(r.f::regprocedure);
    IF v_def NOT LIKE '%ELSIF NOT v_producto_activo THEN%'
       OR v_def LIKE '%Los regalos quedan exentos%'
       OR v_def NOT LIKE '%desactivado y no se puede vender%' THEN
      RAISE EXCEPTION '% sigue eximiendo a los regalos inactivos', r.f;
    END IF;
    IF v_def NOT LIKE '%costo_valuacion%' OR v_def NOT LIKE '%app.stock_origen%' THEN
      RAISE EXCEPTION '% perdio costo_valuacion o app.stock_origen', r.f;
    END IF;
  END LOOP;

  -- 2 · la edicion tiene el pre-chequeo y la red.
  v_def := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  IF v_def NOT LIKE '%mig 289 (#945): un producto inactivo no se AGREGA%'
     OR v_def NOT LIKE '%mig 289 (#945): red final%'
     OR v_def NOT LIKE '%costo_valuacion%' OR v_def NOT LIKE '%app.stock_origen%' THEN
    RAISE EXCEPTION 'actualizar_pedido_items no quedo como se esperaba';
  END IF;

  -- 3 · sustituir y dividir.
  v_def := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
  IF v_def NOT LIKE '%no se puede regalar%' OR v_def NOT LIKE '%costo_valuacion%'
     OR v_def NOT LIKE '%app.stock_origen%' THEN
    RAISE EXCEPTION 'sustituir_regalo_pedido no quedo como se esperaba';
  END IF;
  v_def := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
  IF v_def NOT LIKE '%no se puede regalar%' OR v_def NOT LIKE '%costo_valuacion%'
     OR v_def NOT LIKE '%app.stock_origen%' THEN
    RAISE EXCEPTION 'dividir_regalo_pedido no quedo como se esperaba';
  END IF;

  -- Firma, SECURITY DEFINER, search_path y GRANTs exactos (CREATE OR REPLACE
  -- no deberia tocarlos; se comprueba igual).
  FOR r IN
    SELECT p.oid::regprocedure::text AS f, p.prosecdef, p.proconfig, p.proacl::text AS acl, e.acl AS esperado
      FROM (VALUES
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.crear_pedido_completo_bot(uuid,uuid)',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid)',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
      ) AS e(sig, acl)
      JOIN pg_proc p ON p.oid = e.sig::regprocedure
  LOOP
    IF NOT r.prosecdef OR r.proconfig IS DISTINCT FROM ARRAY['search_path=public']
       OR r.acl IS DISTINCT FROM r.esperado THEN
      RAISE EXCEPTION '% cambio de SECURITY DEFINER / search_path / permisos: % %', r.f, r.proconfig, r.acl;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = '_mig_inactivo_ancla') THEN
    RAISE EXCEPTION 'Quedo el helper de la migracion';
  END IF;
END
$verif$;

COMMIT;
