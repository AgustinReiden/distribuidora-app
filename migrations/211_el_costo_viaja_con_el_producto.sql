-- El producto que nace en el destino se lleva su valuacion del origen
--
-- EL DEFECTO
-- ----------
-- `aceptar_movimiento_sucursal` sube el stock del destino y escribe
-- `costo_con_iva` / `costo_sin_iva` con GREATEST(origen, destino), pero cuando
-- el producto NO existe en el destino lo CREA sin `costo_real`, sin
-- `costo_promedio` y sin `ultimo_tipo_compra`. La funcion viene de la mig 076,
-- anterior a la 111 (costo_real) y a la 127 (costo_promedio): nadie volvio
-- sobre ella cuando aparecieron esas columnas.
--
-- POR QUE IMPORTA
-- ---------------
-- Toda la app valua por la cascada
--     COALESCE(snapshot, costo_promedio, costo_real,
--              costo_sin_iva * (1 + impuestos_internos/100))
-- (migs 130 y 131, y `costoCanonicoUnitario()` en JS). Un producto recien
-- creado por un movimiento entra a esa cascada por el ULTIMO escalon, que
-- tiene semantica FC: neto + impuestos internos. Si la ultima compra del
-- origen fue ZZ, lo pagado YA incluye IVA e impuestos internos (mig 111), asi
-- que sumarselos encima cuenta el impuesto dos veces — exactamente lo que la
-- 111 vino a arreglar. En una Manaos con neto ~5.365 e II 8,6956% son ~466
-- pesos por unidad de costo inventado. Y `ultimo_tipo_compra` en NULL borra
-- el unico dato que distingue FC de ZZ, asi que el error no se puede ni
-- detectar mirando la fila.
--
-- LA EVIDENCIA
-- ------------
-- En Taco Pozo hay 10 productos nacidos de un movimiento
-- (`movimiento_sucursal_items.resolucion = 'creado_nuevo'`). De esos, 3
-- siguen hoy con `costo_real` Y `costo_promedio` en NULL (ALFATUC BLANCO
-- DISPLAY X 18, ALFATUC NEGRO DISPLAY X 18, SAL FINA x 500 g x 10 u) y otros
-- 2 con `costo_promedio` en NULL (los FIDEO COTELLA). Los cinco tienen
-- `ultimo_tipo_compra` NULL. Sus origenes en Tucuman tenian los tres campos
-- cargados en el momento del envio: el dato existia y se tiraba.
-- Da la casualidad de que esos cinco tienen impuestos internos 0, asi que hoy
-- la cascada no infla nada; el proximo producto con II que se cree por un
-- movimiento si.
--
-- QUE CAMBIA Y QUE NO
-- -------------------
-- CAMBIA: al crear el producto en el destino se copian `costo_real`,
-- `costo_promedio` y `ultimo_tipo_compra` de la fila del origen.
--
-- NO CAMBIA la regla de costo del camino "match con un producto existente":
-- sigue siendo GREATEST(origen, destino) sobre costo_con_iva/costo_sin_iva.
-- Es una decision comercial tomada a proposito y documentada en la mig 076,
-- no un olvido; cambiarla por "promediar como una compra" es otra discusion,
-- y ademas obligaria a cambiar el texto del modal
-- (`ModalAceptarMovimiento.tsx`: "Costo destino quedara en X (el mayor)").
-- Corolario conocido: en ese camino `costo_real` y `costo_promedio` del
-- destino siguen sin moverse, asi que las unidades que entran quedan valuadas
-- al promedio viejo del destino. Queda igual que antes a proposito.
--
-- NO SE BACKFILLEAN los 5 productos de arriba. El costo del origen HOY no es
-- el costo de aquellas unidades (los FIDEO ya divergieron: 5.584,04 en el
-- origen contra 5.895,55 en el destino), y el promedio ponderado es
-- forward-only por diseño (mig 127). Inventarles un promedio retroactivo
-- seria peor que dejarlos con el fallback.
--
-- POR QUE EL PARCHE ES QUIRURGICO Y NO UN CREATE OR REPLACE
-- ---------------------------------------------------------
-- La mig 177 ya parcheo esta funcion IN SITU (le metio `condicion_iva` al
-- INSERT) leyendo `pg_get_functiondef`. Un CREATE OR REPLACE armado desde el
-- texto de `migrations/139` revertiria ese cambio EN SILENCIO. Se usa el mismo
-- patron: se lee la definicion VIVA del catalogo y se reemplaza sobre ella,
-- con un helper que falla si el ancla no aparece exactamente una vez.

CREATE OR REPLACE FUNCTION public._mig211_reemplazo_unico(
  p_texto text, p_ancla text, p_nuevo text, p_donde text
) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $helper$
DECLARE
  v_veces integer;
BEGIN
  v_veces := (length(p_texto) - length(replace(p_texto, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 211 · % : el ancla "%" aparece % veces (se esperaba 1). El cuerpo derivo del texto conocido; revisa el parche antes de aplicar.',
      p_donde, left(p_ancla, 70), v_veces;
  END IF;
  RETURN replace(p_texto, p_ancla, p_nuevo);
END;
$helper$;

DO $mig$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.aceptar_movimiento_sucursal(bigint, jsonb)'::regprocedure);
  IF v_def LIKE '%v_orig_costo_real%' THEN RETURN; END IF;

  v_def := public._mig211_reemplazo_unico(v_def,
    $a$  v_items_count integer;$a$,
    $a$  v_items_count integer;
  v_orig_costo_real numeric; v_orig_costo_promedio numeric; v_orig_tipo_compra varchar;$a$,
    'aceptar_movimiento_sucursal/declare');

  -- Si el producto del origen ya no existe, el SELECT INTO deja los tres en
  -- NULL y el INSERT queda como estaba: nunca es peor que hoy.
  v_def := public._mig211_reemplazo_unico(v_def,
    $a$    IF v_accion = 'crear_nuevo' THEN
      INSERT INTO productos ($a$,
    $a$    IF v_accion = 'crear_nuevo' THEN
      -- mig 211: el producto nace en el destino con la valuacion del origen.
      SELECT o.costo_real, o.costo_promedio, o.ultimo_tipo_compra
        INTO v_orig_costo_real, v_orig_costo_promedio, v_orig_tipo_compra
        FROM productos o
        WHERE o.id = v_item.producto_origen_id AND o.sucursal_id = v_mov.sucursal_origen_id;
      INSERT INTO productos ($a$,
    'aceptar_movimiento_sucursal/select-origen');

  v_def := public._mig211_reemplazo_unico(v_def,
    $a$        unidades_de_venta_por_fardo, etiqueta_bulto, tp_import_id, sucursal_id
      ) VALUES ($a$,
    $a$        unidades_de_venta_por_fardo, etiqueta_bulto, tp_import_id, sucursal_id,
        costo_real, costo_promedio, ultimo_tipo_compra
      ) VALUES ($a$,
    'aceptar_movimiento_sucursal/insert-columnas');

  v_def := public._mig211_reemplazo_unico(v_def,
    $a$        v_item.origen_unidades_por_fardo, v_item.origen_etiqueta_bulto, v_item.origen_tp_import_id, v_destino
      ) RETURNING id, stock INTO v_dest_id, v_stock_d;$a$,
    $a$        v_item.origen_unidades_por_fardo, v_item.origen_etiqueta_bulto, v_item.origen_tp_import_id, v_destino,
        v_orig_costo_real, v_orig_costo_promedio, v_orig_tipo_compra
      ) RETURNING id, stock INTO v_dest_id, v_stock_d;$a$,
    'aceptar_movimiento_sucursal/insert-valores');

  EXECUTE v_def;
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig211_reemplazo_unico(text, text, text, text);

-- La funcion parcheada conserva sus permisos (ALTER/REPLACE no los toca) y no
-- se crea ninguna funcion nueva que quede abierta a PUBLIC: el helper se
-- dropea arriba. Verificacion de que el parche entro y de que no se perdio lo
-- que puso la 177:
DO $verif$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.aceptar_movimiento_sucursal(bigint, jsonb)'::regprocedure);
  IF v_def NOT LIKE '%v_orig_costo_real%' THEN
    RAISE EXCEPTION 'el parche de la mig 211 no quedo aplicado'; END IF;
  IF v_def NOT LIKE '%condicion_iva%' THEN
    RAISE EXCEPTION 'se perdio el parche de la mig 177 (condicion_iva)'; END IF;
END
$verif$;

-- VERIFICACION MANUAL (no hay tests de aceptar_movimiento_sucursal):
--   1. Mover a la otra sucursal un producto que NO exista alla, aceptarlo con
--      "crear nuevo", y mirar la fila creada:
--        SELECT nombre, costo_sin_iva, costo_real, costo_promedio, ultimo_tipo_compra
--          FROM productos WHERE id = <nuevo>;
--      Los tres ultimos tienen que venir del origen, no NULL.
--   2. SELECT * FROM auditoria_integridad();
