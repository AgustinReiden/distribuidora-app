-- =========================================================================
-- La devolucion dice de donde viene
--
-- EL BUG
-- ------
-- El modelo de vencimientos por lote (migs 223-225) devuelve unidades al lote
-- FEFO solo si `app.stock_origen` esta en la lista blanca de
-- sincronizar_lotes_stock. Verificado contra pg_get_functiondef en PROD (no
-- contra migrations/, que es vista curada): CUATRO funciones que SUBEN
-- productos.stock no setean ningun set_config, y por lo tanto suben con el
-- origen por defecto 'auto', que no esta -- ni tiene que estar -- en la lista:
--
--   cancelar_pedido_con_stock     el bucle de devolucion
--   actualizar_pedido_items       las dos restituciones
--   revertir_bloques_auto_ajuste  la devolucion del ajuste
--   restaurar_stock_atomico       la restauracion entera
--
-- Con origen 'auto' la rama de restauracion del trigger no corre: las unidades
-- suben al stock pero vuelven a la bolsa "sin vencimiento" en vez de a su lote.
-- Cada cancelacion y cada edicion a la baja vacia el contador de vencimientos,
-- para abajo, en silencio y sin que falle nada.
--
-- El comentario de la 223 afirmaba que actualizar_pedido_items ya etiquetaba
-- 'pedido_creado' en las dos direcciones. No era cierto. Se corrige el archivo.
--
-- Y DOS MAS QUE APARECIERON MIRANDO EL CUERPO VIVO
-- ------------------------------------------------
--   _aplicar_cambio_producto (091)  dos UPDATE de stock sin set_config: la
--     devolucion no vuelve al lote y el ledger queda con origen 'auto', sin
--     usuario ni referencia (engorda STK-D).
--   editar_movimiento_sucursal (139)  SI etiqueta, pero con 'movimiento_editado',
--     que no estaba en la lista blanca. Su UPDATE es bidireccional
--     (`stock - delta` sobre la sucursal ORIGEN): bajar la cantidad de un envio
--     devuelve stock que no volvia al lote.
--
-- Y EL ATAJO DEL TRIGGER
-- ----------------------
-- `IF v_asignado = 0 THEN RETURN NEW` cortaba antes de la rama de devolucion
-- cuando todos los lotes estaban consumidos a 0 -- que es exactamente cuando
-- hay que restaurar, porque _restaurar_lotes_fefo busca lotes con
-- cantidad_restante < cantidad. El atajo tiene que mirar si HAY lotes, no
-- cuanto les queda.
--
-- Y EL ORDEN DE anular_compra_atomica
-- -----------------------------------
-- Bajaba el stock ANTES de marcar la compra cancelada. El trigger de lotes
-- consumia FEFO -- o sea del lote que vence antes, que puede ser de OTRA
-- compra -- y recien despues borrar_lotes_compra_cancelada borraba los lotes
-- propios. Doble descuento en el ledger de lotes: con un lote ajeno de 50 que
-- vence antes y uno propio de 50, anular la compra dejaba el ajeno en 0 y
-- borraba el propio -- 100 unidades de trazabilidad perdidas habiendo salido 50.
-- Se invierte el orden: primero se cancela (se borran los lotes propios),
-- despues baja el stock, y el trigger ya no tiene de donde comerse lo ajeno.
--
-- PARA QUE NO VUELVA A PASAR
-- --------------------------
-- Check nuevo STK-F en auditoria_integridad(): falla si una funcion de `public`
-- sube productos.stock de forma incremental y no menciona app.stock_origen.
--
-- Todos los parches son POR ANCLA sobre el cuerpo VIVO: si el cuerpo cambio
-- desde que se escribio esta migracion, el ancla no aparece exactamente una vez
-- y la migracion aborta, en vez de pisar un cuerpo que nadie leyo.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 - El andamio de parcheo por ancla (mismo idiom que la mig 220).
--     Se dropea al final: es andamio, no API.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._mig229_reemplazar_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);

  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, p_funcion;
  END IF;

  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

CREATE OR REPLACE FUNCTION public._mig229_fn(p_nombre text)
RETURNS regprocedure
LANGUAGE sql
AS $fn$
  SELECT p.oid::regprocedure FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_nombre;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 - cancelar_pedido_con_stock: el bucle de devolucion
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('cancelar_pedido_con_stock'),
    E'  v_total_original := v_pedido.total;\n\n  FOR v_item IN\n',
    E'  v_total_original := v_pedido.total;\n'
    || E'\n'
    || E'  -- mig 229: el trigger de lotes (223) solo devuelve al lote FEFO si el\n'
    || E'  -- origen esta en su lista blanca. Sin estas cuatro lineas la cancelacion\n'
    || E'  -- subia el stock con origen ''auto'' y las unidades volvian a la bolsa "sin\n'
    || E'  -- vencimiento" en vez de a su lote: el contador mentia para abajo.\n'
    || E'  PERFORM set_config(''app.stock_origen'', ''pedido_cancelado'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_tipo'', ''pedido'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_id'', p_pedido_id::TEXT, true);\n'
    || E'  PERFORM set_config(''app.stock_user_id'', COALESCE(v_acting_user::TEXT, ''''), true);\n'
    || E'\n'
    || E'  FOR v_item IN\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 2 - actualizar_pedido_items: las dos restituciones
--     Un solo bloque antes de las dos: set_config es por transaccion.
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('actualizar_pedido_items'),
    E'  END IF;\n\n  UPDATE productos p\n  SET stock = p.stock + pi.cantidad\n  FROM pedido_items pi\n',
    E'  END IF;\n'
    || E'\n'
    || E'  -- mig 229: las dos restituciones de abajo devuelven stock. ''pedido_creado''\n'
    || E'  -- es el origen que la 223 ya esperaba de esta funcion -- su comentario decia\n'
    || E'  -- que la etiquetaba, y no era cierto hasta esta migracion.\n'
    || E'  PERFORM set_config(''app.stock_origen'', ''pedido_creado'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_tipo'', ''pedido'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_id'', p_pedido_id::TEXT, true);\n'
    || E'  PERFORM set_config(''app.stock_user_id'', COALESCE(p_usuario_id::TEXT, ''''), true);\n'
    || E'\n'
    || E'  UPDATE productos p\n  SET stock = p.stock + pi.cantidad\n  FROM pedido_items pi\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 3 - revertir_bloques_auto_ajuste: la devolucion del ajuste
--
--     Esta la llaman actualizar_pedido_items, registrar_salvedad y
--     eliminar_pedido_completo, y las tres declaran SU origen antes de llamarla.
--     set_config es por TRANSACCION, no por funcion: pisar el GUC sin devolverlo
--     dejaria el resto del cuerpo del que llamo etiquetado 'auto_ajuste_promo'.
--     registrar_salvedad y eliminar_pedido_completo hoy etiquetan bien y no se
--     los puede romper de rebote. Por eso guarda y restaura.
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('revertir_bloques_auto_ajuste'),
    E'  v_merma_id           BIGINT;\nBEGIN\n',
    E'  v_merma_id           BIGINT;\n'
    || E'  -- mig 229: set_config es por transaccion, asi que el GUC del que nos llamo\n'
    || E'  -- se guarda y se restaura alrededor del UPDATE. Ver la cabecera.\n'
    || E'  v_org_prev           text;\n'
    || E'  v_ref_tipo_prev      text;\n'
    || E'  v_ref_id_prev        text;\n'
    || E'  v_user_prev          text;\n'
    || E'BEGIN\n'
  );

  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('revertir_bloques_auto_ajuste'),
    E'  UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()\n   WHERE id = v_promo.ajuste_producto_id AND sucursal_id = p_sucursal_id;\n',
    E'  v_org_prev      := current_setting(''app.stock_origen'', true);\n'
    || E'  v_ref_tipo_prev := current_setting(''app.stock_ref_tipo'', true);\n'
    || E'  v_ref_id_prev   := current_setting(''app.stock_ref_id'', true);\n'
    || E'  v_user_prev     := current_setting(''app.stock_user_id'', true);\n'
    || E'\n'
    || E'  PERFORM set_config(''app.stock_origen'', ''auto_ajuste_promo'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_tipo'', ''promocion'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_id'', p_promocion_id::TEXT, true);\n'
    || E'  PERFORM set_config(''app.stock_user_id'', COALESCE(p_usuario_id::TEXT, ''''), true);\n'
    || E'\n'
    || E'  UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()\n   WHERE id = v_promo.ajuste_producto_id AND sucursal_id = p_sucursal_id;\n'
    || E'\n'
    || E'  PERFORM set_config(''app.stock_origen'',   COALESCE(v_org_prev, ''''), true);\n'
    || E'  PERFORM set_config(''app.stock_ref_tipo'', COALESCE(v_ref_tipo_prev, ''''), true);\n'
    || E'  PERFORM set_config(''app.stock_ref_id'',   COALESCE(v_ref_id_prev, ''''), true);\n'
    || E'  PERFORM set_config(''app.stock_user_id'',  COALESCE(v_user_prev, ''''), true);\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 4 - restaurar_stock_atomico
--
--     No tiene pedido ni compra que referenciar, asi que va sin ref_tipo/ref_id
--     pero con usuario. Los limpia explicitamente: el GUC es por transaccion y
--     una referencia vieja de otra llamada se colaria en el ledger.
--     Origen nuevo 'restauracion_manual', que se agrega a la lista blanca: lo
--     que restaura son unidades que ya habian salido y tienen que volver al lote.
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('restaurar_stock_atomico'),
    E'  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP\n',
    E'  PERFORM set_config(''app.stock_origen'', ''restauracion_manual'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_tipo'', '''', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_id'', '''', true);\n'
    || E'  PERFORM set_config(''app.stock_user_id'', COALESCE(auth.uid()::TEXT, ''''), true);\n'
    || E'  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 5 - _aplicar_cambio_producto (091)
--
--     El id del cambio se reserva ANTES de los UPDATE porque el INSERT en
--     cambios_productos va al final: sin reservarlo, el ledger de stock no
--     tendria a que apuntar. La columna es un serial comun, asi que nextval +
--     INSERT explicito es equivalente al default.
--     Un solo origen para los dos UPDATE: la salida es delta negativo (la lista
--     blanca no la mira) y el reingreso positivo (ahi si).
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('_aplicar_cambio_producto'),
    E'  IF v_reingresa THEN\n    UPDATE productos SET stock = stock + p_cantidad_devuelta\n     WHERE id = p_producto_devuelto_id;\n  END IF;\n',
    E'  -- mig 229: el id se reserva antes para que el ledger pueda referenciar el\n'
    || E'  -- cambio que todavia no se inserto.\n'
    || E'  v_cambio_id := nextval(''cambios_productos_id_seq'');\n'
    || E'\n'
    || E'  PERFORM set_config(''app.stock_origen'', ''cambio_producto'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_tipo'', ''cambios_productos'', true);\n'
    || E'  PERFORM set_config(''app.stock_ref_id'', v_cambio_id::TEXT, true);\n'
    || E'  PERFORM set_config(''app.stock_user_id'', COALESCE(p_usuario_id::TEXT, ''''), true);\n'
    || E'\n'
    || E'  IF v_reingresa THEN\n    UPDATE productos SET stock = stock + p_cantidad_devuelta\n     WHERE id = p_producto_devuelto_id;\n  END IF;\n'
  );

  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('_aplicar_cambio_producto'),
    E'  INSERT INTO cambios_productos (\n'
    || E'    cliente_id, producto_devuelto_id, cantidad_devuelta, precio_devuelto,\n'
    || E'    producto_entregado_id, cantidad_entregada, precio_entregado,\n'
    || E'    diferencia_monto, observaciones, usuario_id, sucursal_id, motivo\n'
    || E'  ) VALUES (\n'
    || E'    p_cliente_id, p_producto_devuelto_id, p_cantidad_devuelta, v_precio_devuelto,\n'
    || E'    p_producto_entregado_id, p_cantidad_entregada, v_precio_entregado,\n'
    || E'    v_diferencia, p_observaciones, p_usuario_id, p_sucursal_id, COALESCE(p_motivo,''erroneo'')\n'
    || E'  ) RETURNING id INTO v_cambio_id;\n',
    E'  INSERT INTO cambios_productos (\n'
    || E'    id,\n'
    || E'    cliente_id, producto_devuelto_id, cantidad_devuelta, precio_devuelto,\n'
    || E'    producto_entregado_id, cantidad_entregada, precio_entregado,\n'
    || E'    diferencia_monto, observaciones, usuario_id, sucursal_id, motivo\n'
    || E'  ) VALUES (\n'
    || E'    v_cambio_id,\n'
    || E'    p_cliente_id, p_producto_devuelto_id, p_cantidad_devuelta, v_precio_devuelto,\n'
    || E'    p_producto_entregado_id, p_cantidad_entregada, v_precio_entregado,\n'
    || E'    v_diferencia, p_observaciones, p_usuario_id, p_sucursal_id, COALESCE(p_motivo,''erroneo'')\n'
    || E'  );\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 6 y 7 - sincronizar_lotes_stock: la lista blanca y el atajo
--
--     La lista solo se consulta en la rama POSITIVA (el ELSIF), o sea que sumar
--     origenes solo afecta devoluciones. Los tres que entran devuelven
--     mercaderia que ya habia salido de esta misma sucursal:
--       cambio_producto      el producto que el cliente devuelve en un cambio
--       movimiento_editado   bajar la cantidad de un envio, sobre la sucursal ORIGEN
--       restauracion_manual  restaurar_stock_atomico
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('sincronizar_lotes_stock'),
    E'                     ''movimiento_cancelado'') THEN\n',
    E'                     ''movimiento_cancelado'', ''cambio_producto'',\n'
    || E'                     ''movimiento_editado'', ''restauracion_manual'') THEN\n'
  );

  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('sincronizar_lotes_stock'),
    E'  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_asignado\n'
    || E'    FROM public.producto_lotes\n'
    || E'   WHERE producto_id = NEW.id AND sucursal_id = NEW.sucursal_id;\n'
    || E'\n'
    || E'  IF v_asignado = 0 THEN\n    RETURN NEW;\n  END IF;\n',
    E'  -- mig 229: el atajo era `IF v_asignado = 0 THEN RETURN NEW`, y cortaba justo\n'
    || E'  -- en el caso que hay que atender: lotes que existen pero estan consumidos a\n'
    || E'  -- 0. _restaurar_lotes_fefo busca lotes con cantidad_restante < cantidad, o\n'
    || E'  -- sea que ahi es cuando mas hace falta. Ahora mira si HAY lotes, no cuanto\n'
    || E'  -- les queda; el barrido por producto sin lotes sigue sin pagarse.\n'
    || E'  IF NOT EXISTS (\n'
    || E'    SELECT 1 FROM public.producto_lotes\n'
    || E'     WHERE producto_id = NEW.id AND sucursal_id = NEW.sucursal_id\n'
    || E'  ) THEN\n'
    || E'    RETURN NEW;\n'
    || E'  END IF;\n'
    || E'\n'
    || E'  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_asignado\n'
    || E'    FROM public.producto_lotes\n'
    || E'   WHERE producto_id = NEW.id AND sucursal_id = NEW.sucursal_id;\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 8 - anular_compra_atomica: primero cancelar, despues descontar
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('anular_compra_atomica'),
    E'  UPDATE productos p\n'
    || E'     SET stock = p.stock - q.qty,\n'
    || E'         updated_at = NOW()\n'
    || E'    FROM (SELECT producto_id, SUM(cantidad)::INT AS qty\n'
    || E'            FROM compra_items\n'
    || E'           WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal\n'
    || E'           GROUP BY producto_id) q\n'
    || E'   WHERE p.id = q.producto_id AND p.sucursal_id = v_sucursal;\n'
    || E'\n'
    || E'  UPDATE compras\n'
    || E'     SET estado = ''cancelada'', updated_at = NOW()\n'
    || E'   WHERE id = p_compra_id AND sucursal_id = v_sucursal;\n',
    E'  -- mig 229: cancelar PRIMERO. El UPDATE de compras dispara\n'
    || E'  -- borrar_lotes_compra_cancelada, que borra los lotes de esta compra. Si el\n'
    || E'  -- stock bajaba antes, el trigger de lotes consumia FEFO -- el que vence\n'
    || E'  -- antes, que puede ser de OTRA compra -- y despues se borraban ademas los\n'
    || E'  -- propios: doble descuento en el ledger de lotes.\n'
    || E'  UPDATE compras\n'
    || E'     SET estado = ''cancelada'', updated_at = NOW()\n'
    || E'   WHERE id = p_compra_id AND sucursal_id = v_sucursal;\n'
    || E'\n'
    || E'  UPDATE productos p\n'
    || E'     SET stock = p.stock - q.qty,\n'
    || E'         updated_at = NOW()\n'
    || E'    FROM (SELECT producto_id, SUM(cantidad)::INT AS qty\n'
    || E'            FROM compra_items\n'
    || E'           WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal\n'
    || E'           GROUP BY producto_id) q\n'
    || E'   WHERE p.id = q.producto_id AND p.sucursal_id = v_sucursal;\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 9 - El check que evita la proxima vez: STK-F
--
--     La deteccion vive en su propia funcion para no meter una regex dentro del
--     cuerpo de auditoria_integridad(), que ya es una lista de VALUES larga.
--
--     DOS EXCEPCIONES CONOCIDAS, a proposito:
--       registrar_compra_completa  y  registrar_ingreso_sucursal
--     Las dos suben stock sin etiquetar. NO es el bug de esta migracion: lo que
--     suben es mercaderia NUEVA (una compra, un ingreso entre sucursales), que
--     por diseno va a la bolsa "sin vencimiento" y no a un lote -- el origen que
--     les falta es de trazabilidad del ledger (STK-D), no de lotes. Tocarlas es
--     cambiar RPCs de compras, que queda fuera del alcance de esta migracion.
--     Van por issue aparte. Se listan aca para que el gate arranque en verde y
--     lo que se ponga rojo sea siempre algo nuevo.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.auditoria_funciones_stock_sin_origen()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT count(*)
    FROM pg_proc f
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.prokind = 'f'
     AND f.proname NOT IN ('registrar_compra_completa', 'registrar_ingreso_sucursal')
     AND pg_get_functiondef(f.oid) ~* 'UPDATE\s+productos\s+(AS\s+)?(\w+\s+)?SET[^;]*\ystock\s*=\s*(\w+\.)?stock\s*\+'
     AND pg_get_functiondef(f.oid) NOT LIKE '%app.stock_origen%';
$fn$;

COMMENT ON FUNCTION public.auditoria_funciones_stock_sin_origen() IS
  'Cuenta funciones de public que suben productos.stock sin declarar '
  'app.stock_origen. Alimenta el check STK-F. mig 229.';

-- Toda funcion nueva de public nace con EXECUTE para PUBLIC, y Supabase ademas
-- se lo concede a anon por separado: hay que revocar las dos mitades.
REVOKE ALL ON FUNCTION public.auditoria_funciones_stock_sin_origen() FROM PUBLIC, anon;

DO $patch$
BEGIN
  PERFORM public._mig229_reemplazar_ancla(
    public._mig229_fn('auditoria_integridad'),
    E'    (''LOTE-C'',''high'',''lotes cuya sucursal no coincide con la del producto'',\n'
    || E'      (SELECT count(*) FROM producto_lotes l\n'
    || E'         JOIN productos p ON p.id=l.producto_id\n'
    || E'        WHERE p.sucursal_id <> l.sucursal_id))\n',
    E'    (''LOTE-C'',''high'',''lotes cuya sucursal no coincide con la del producto'',\n'
    || E'      (SELECT count(*) FROM producto_lotes l\n'
    || E'         JOIN productos p ON p.id=l.producto_id\n'
    || E'        WHERE p.sucursal_id <> l.sucursal_id)),\n'
    || E'    (''STK-F'',''high'',''funciones de public que suben stock sin declarar app.stock_origen (mig 229)'',\n'
    || E'      (SELECT public.auditoria_funciones_stock_sin_origen()))\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 10 - Se saca el andamio
-- ---------------------------------------------------------------------------

DROP FUNCTION public._mig229_reemplazar_ancla(regprocedure, text, text);
DROP FUNCTION public._mig229_fn(text);

-- ---------------------------------------------------------------------------
-- 11 - Verificacion. Si algo de esto no quedo, la migracion entera se revierte.
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_falta text;
  v_def   text;
  v_n     int;
BEGIN
  -- Las funciones que tenian que quedar etiquetadas.
  SELECT string_agg(t, ', ') INTO v_falta
  FROM unnest(ARRAY['cancelar_pedido_con_stock','actualizar_pedido_items',
                    'revertir_bloques_auto_ajuste','restaurar_stock_atomico',
                    '_aplicar_cambio_producto']) t
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace='public'::regnamespace AND p.proname = t
       AND pg_get_functiondef(p.oid) LIKE '%app.stock_origen%');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron sin etiquetar: %.', v_falta;
  END IF;

  -- Cada una con SU origen, no con cualquiera.
  SELECT string_agg(t.fn, ', ') INTO v_falta
  FROM (VALUES
    ('cancelar_pedido_con_stock','pedido_cancelado'),
    ('actualizar_pedido_items','pedido_creado'),
    ('revertir_bloques_auto_ajuste','auto_ajuste_promo'),
    ('restaurar_stock_atomico','restauracion_manual'),
    ('_aplicar_cambio_producto','cambio_producto')
  ) AS t(fn, origen)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace='public'::regnamespace AND p.proname = t.fn
       AND pg_get_functiondef(p.oid) LIKE ('%set_config(''app.stock_origen'', ''' || t.origen || '''%'));
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Etiquetadas con el origen equivocado: %.', v_falta;
  END IF;

  -- revertir_bloques_auto_ajuste restaura el GUC del que la llamo. Sin esto
  -- rompe a registrar_salvedad y a eliminar_pedido_completo, que hoy andan bien.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='revertir_bloques_auto_ajuste';
  IF v_def NOT LIKE '%COALESCE(v_org_prev%' THEN
    RAISE EXCEPTION 'revertir_bloques_auto_ajuste no restaura el GUC del caller.';
  END IF;

  -- La lista blanca del trigger tiene los tres origenes nuevos y sigue teniendo
  -- los nueve viejos.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='sincronizar_lotes_stock';
  SELECT count(*) INTO v_n FROM unnest(ARRAY[
    'pedido_creado','pedido_creado_bot','pedido_cancelado','pedido_eliminado',
    'salvedad','sustitucion_regalo','auto_ajuste_promo','movimiento_denegado',
    'movimiento_cancelado','cambio_producto','movimiento_editado','restauracion_manual']) o
   WHERE v_def LIKE ('%''' || o || '''%');
  IF v_n <> 12 THEN
    RAISE EXCEPTION 'La lista blanca del trigger quedo con % de 12 origenes.', v_n;
  END IF;

  -- El atajo mira si HAY lotes, no cuanto les queda. Se busca la SENTENCIA
  -- vieja (dos lineas), no el texto suelto: el comentario nuevo la cita, y
  -- buscar '%IF v_asignado = 0 THEN%' se encuentra a si mismo.
  IF v_def LIKE ('%IF v_asignado = 0 THEN' || chr(10) || '    RETURN NEW;%')
     OR v_def NOT LIKE '%IF NOT EXISTS (%' THEN
    RAISE EXCEPTION 'El atajo del trigger no quedo reemplazado.';
  END IF;

  -- anular_compra_atomica cancela antes de descontar.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='anular_compra_atomica';
  IF position('SET estado = ''cancelada''' in v_def) > position('SET stock = p.stock - q.qty' in v_def) THEN
    RAISE EXCEPTION 'anular_compra_atomica sigue descontando antes de cancelar.';
  END IF;

  -- El check nuevo esta en la auditoria y arranca en verde.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='auditoria_integridad';
  IF v_def NOT LIKE '%STK-F%' THEN
    RAISE EXCEPTION 'El check STK-F no quedo en auditoria_integridad().';
  END IF;

  SELECT public.auditoria_funciones_stock_sin_origen() INTO v_n;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'STK-F arranca en rojo: % funcion(es) suben stock sin origen.', v_n;
  END IF;

  -- El andamio no quedo vivo.
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace='public'::regnamespace AND p.proname LIKE '\_mig229\_%') THEN
    RAISE EXCEPTION 'Quedo viva una funcion andamio _mig229_*.';
  END IF;

  -- Ninguna funcion nueva alcanzable con la anon key.
  IF has_function_privilege('anon', 'public.auditoria_funciones_stock_sin_origen()', 'EXECUTE') THEN
    RAISE EXCEPTION 'auditoria_funciones_stock_sin_origen quedo ejecutable por anon.';
  END IF;
END;
$verif$;

COMMIT;
