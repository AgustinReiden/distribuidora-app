-- El reparto del regalo al cargar el pedido es del admin (#1112)
--
-- Desde la 350 (#1091), crear_pedido_completo registra el reparto que se elige
-- al cargar (dos o mas lineas de regalo de la misma promo) con filas en
-- pedido_item_sustituciones y autorizado_por = quien carga. Pero lo aceptaba de
-- cualquier rol que carga pedidos, y el front solo se lo ofrece al admin
-- (ModalPedido, puedeElegir = isAdmin): un preventista o un encargado con un
-- bundle PWA viejo, un rol cambiado o un request a mano dejaban un reparto
-- autorizado por ellos. Decision del dueño (2026-10-13): solo admin.
--
-- Una guarda, justo despues del chequeo de rol y ANTES de cualquier escritura:
-- si quien carga no es admin y alguna promo trae 2 o mas lineas de regalo, el
-- alta se rechaza entera (success = false, sin pedido, sin stock movido). El
-- predicado es el mismo de v_promos_reparto (es_bonificacion + promocion_id no
-- vacio, agrupado por promocion_id::BIGINT), asi las dos definiciones de
-- "reparto del alta" no se separan.
--
-- Que NO cubre: una sola linea de regalo con otro producto o cantidad la sigue
-- aceptando de cualquier rol (y validar_precio_item_pedido deja pasar
-- cualquier regalo a $0). Es otro problema, va en un issue aparte.
--
-- Criterio de rol: perfiles.rol del que carga (v_user_role, igual que el resto
-- de la funcion; no es_preventista(), trampa 4). No mira perfil_roles: al
-- 2026-10-13 tiene 5 filas, todas transportista, ninguna admin. Asimetria
-- deliberada: dividir_regalo_pedido y sustituir_regalo_pedido aceptan admin y
-- encargado, asi que el encargado puede repartir despues desde el pedido.
--
-- Llamadores que atraviesan la guarda: crear_pedido_idempotente (el wrapper
-- del front y del replay offline: no sella offline_id si success = false, y el
-- mensaje no calza con PATRON_STOCK ni pareceSesionVencida, asi que el rechazo
-- es terminal) y cambiar_cliente_pedido, que recrea el pedido con las lineas
-- ya repartidas y pasa porque es solo admin. Si se abre al encargado, hay que
-- revisar aca.
--
-- En prod, al 2026-10-13: 0 pedidos con mas de una linea de regalo por promo.
-- Sin backfill. Firma, SECURITY DEFINER y GRANTs: como estaban (CREATE OR
-- REPLACE con la misma firma los conserva). No mueve stock, ni GUCs, ni
-- costo_unitario_al_crear (STK-F, STK-D y COSTO-D iguales).
--
-- Ensayo: scripts/test-alta-reparto-rol-1112.sql.

CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

DO $crear$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;
$q$,
$q$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  -- mig #1112: repartir el regalo de una promo en varios productos al cargar
  -- es del admin (el front solo lo ofrece al admin, ModalPedido). Va ANTES de
  -- cualquier escritura: la 350 deja filas con autorizado_por = quien carga.
  -- Cubre SOLO el reparto; una sola linea de regalo con otro producto o
  -- cantidad sigue abierta para cualquier rol (issue aparte).
  -- Criterio: perfiles.rol del que carga (igual que el resto de la funcion);
  -- no mira perfil_roles. Asimetria deliberada: dividir_regalo_pedido y
  -- sustituir_regalo_pedido aceptan admin y encargado.
  -- Atraviesan esta guarda: crear_pedido_idempotente (el wrapper del front) y
  -- cambiar_cliente_pedido, que recrea el pedido con las lineas ya repartidas
  -- y hoy pasa porque es solo admin; si se abre al encargado, revisar aca.
  -- El predicado es el de v_promos_reparto, mas abajo: si cambia uno, el otro.
  IF v_user_role <> 'admin'
     AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array'
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
                  WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                    AND NULLIF(e->>'promocion_id', '') IS NOT NULL
                  GROUP BY (e->>'promocion_id')::BIGINT
                 HAVING count(*) > 1) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
      'Solo un admin puede repartir el regalo de una promo en varios productos al cargar el pedido. Cargalo con el regalo de la promo; el admin o el encargado lo reparte después desde el pedido.'));
  END IF;
$q$, 'crear_pedido_completo guarda de rol del reparto');
  EXECUTE v_def;
END
$crear$;

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  f     text := 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)';
  v_cre text := pg_get_functiondef(f::regprocedure);
BEGIN
  IF v_cre NOT LIKE '%Solo un admin puede repartir el regalo%'
     -- lo de #1091 y #1097 sigue ahi
     OR v_cre NOT LIKE '%Reparto al cargar el pedido%'
     OR v_cre NOT LIKE '%origen_precio, regalo_cadena_id%'
     OR v_cre NOT LIKE '%aplicar_uso_promo_acumulador%'
     -- la guarda va antes de la primera escritura
     OR strpos(v_cre, 'Solo un admin puede repartir') > strpos(v_cre, 'INSERT INTO') THEN
    RAISE EXCEPTION 'crear_pedido_completo no quedo como se esperaba';
  END IF;
  -- Una sola sobrecarga (PGRST203).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                                     AND proname = 'crear_pedido_completo') <> 1 THEN
    RAISE EXCEPTION 'crear_pedido_completo tiene mas de una sobrecarga';
  END IF;
  -- SECURITY DEFINER y EXECUTE: como estaban.
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN
    RAISE EXCEPTION 'crear_pedido_completo dejo de ser SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', f, 'EXECUTE') THEN
    RAISE EXCEPTION 'anon puede ejecutar crear_pedido_completo';
  END IF;
  IF NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated perdio EXECUTE sobre crear_pedido_completo';
  END IF;
END
$verif$;
