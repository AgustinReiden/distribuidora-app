-- NNN · Frenos de NaN y CHECKs que faltaban (tarjeta B7 de la ola 2 de #1603: 1557-c1, 1559-c3, 1561-b13, 1562-c1,
--       1567-1 y 1567-5 a 1567-10, 1596-b1, y el H4 que dejó la ola 1 en lente-m4-v2).
--
-- Qué arregla:
--   'NaN'::numeric es mayor que todo número: pasa `x >= 0` y `x > 0`. Y una columna numeric sin precisión admite
--   además 'Infinity'. Estas columnas tenían un piso sin freno, o ningún CHECK:
--   · 1567-1 / 1562-c1. gastos.iva, percepcion_iva, percepcion_iibb y otros_impuestos (`>= 0`). Con uno en NaN,
--     gastos_neto_positivo (monto_total − todos > 0) también pasaba, y la columna generada neto quedaba en NaN.
--   · 1567-5. compra_cargos.iva_monto (`>= 0`).
--   · 1567-6 / 1559-c3. notas_credito_venta.neto, iva (`>= 0`) y total (`> 0`), numeric sin precisión: NaN e
--     infinito.
--   · 1567-7 / 1559-c3. nota_credito_venta_items.precio_unitario y subtotal (`>= 0`), sin precisión: NaN e infinito.
--   · 1567-8. pedido_combos.precio (`> 0`).
--   · 1567-9. pedido_item_sustituciones.cantidad_original y cantidad_sustituta (`> 0`).
--   · 1567-10. grupo_precio_escala_minimos.precio_unitario_override (`> 0`).
--   · 1557-c1. compra_items.bonificacion: numeric sin precisión y sin CHECK. Es un porcentaje: las RPCs de la compra
--     lo validan entre 0 y 100 (_compra_renglones_fuera_de_rango) y lo usan como `costo · (1 − b/100)`.
--   · 1596-b1. productos.precio y precio_sin_iva sin piso (el NaN ya lo frena productos_precios_no_nan, 487);
--     stock_minimo sin piso; cantidad_minima_venta sin techo; nombre vacío.
--   · 1561-b13. clientes.razon_social, nombre_fantasia y direccion vacíos (el alta del panel ya los pide).
--   · H4 (lente-m4-v2). Una salvedad sobre una línea con costo 'Infinity' falla al guardar la foto
--     (salvedad_linea_foto_costo_valido). El freno va en la columna de origen: pedido_items.costo_unitario_al_crear
--     (sin precisión) queda finito, y precio_lista_al_crear y descuento_pct sin NaN, como pide la foto.
--   · El barrido de todas las columnas numeric de public (16/11) encontró, fuera de la lista, seis pisos más sin
--     freno de NaN y diecinueve columnas sin precisión sin freno de infinito. Son del mismo tipo y van acá:
--       pisos: bot_costo_llm_mensual.usd, bot_pedidos_pendientes.cargo_mostrado, bot_presupuesto_llm.techo_usd_mes,
--              empleado_liquidaciones.pagado, gastos.litros, rendicion_faltantes.monto;
--       sin precisión (fotos y cálculos de server, sin piso): bot_pedidos_pendientes.total, total_iva y total_neto;
--              compra_items.costo_promedio_anterior; los nueve origen_*/costo_aplicado_destino de
--              movimiento_sucursal_items; movimientos_sucursal.total_costo; rendicion_pagos_confirmados.monto y
--              pedido_total; rendiciones_control.total_entregado_confirmado; y las coordenadas de sucursales
--              (deposito_lat/lng, destino_lat/lng), que carga el admin y llevan su rango.
--
-- Cómo:
--   El freno va en la columna (regla de CLAUDE.md): cubre la RPC, el REST y los triggers. No se toca ninguna función.
--   · Lo que viene del usuario lleva su rango: la bonificación de 0 a 100; el precio y el precio sin IVA >= 0; el
--     stock mínimo >= 0; el mínimo de venta hasta 99.999.999 (D36 de #1596); las coordenadas de la sucursal en ±90 / ±180.
--     Un techo deja afuera al NaN y al infinito.
--   · Lo que tiene piso suma `<> 'NaN'` (y `<> 'Infinity'` si la columna no tiene precisión; el '-Infinity' ya lo
--     deja afuera el piso).
--   · Lo calculado sin piso (fotos, totales de server) va sólo finito: puede salir negativo o en 0 legítimamente.
--   · Los textos de clientes y el nombre del producto: `btrim(x) <> ''`.
--   Los CHECK que se reemplazan conservan su nombre (DROP + ADD en el mismo ALTER, como la 493). `x <> 'NaN'` es
--   NULL con x NULL y un CHECK NULL pasa: las columnas que admiten NULL lo siguen admitiendo.
--   auditoria_nan() no cambia: ya recorre toda columna numeric de las tablas de public (pg_attribute), con NaN e
--   infinitos. Los textos vacíos no son de esa batería.
--
-- Premisa de datos: la migración cuenta antes las filas que violarían cada CHECK y aborta con el detalle. La misma
-- consulta, de sólo lectura, va en el informe de la tarjeta para medir prod antes de aplicar.
--
-- Ensayo: scripts/test-frenos-nan-ola2-1603.sql (un DO que termina en excepción; no deja nada). Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- Los ALTER TABLE toman ACCESS EXCLUSIVE mientras validan (pedido_items es la tabla grande). Si hay una transacción
-- larga adelante, mejor fallar y reintentar que dejar la cola de locks trabada detrás.
SET LOCAL lock_timeout = '5s';

-- Todos los locks juntos y al principio, sin esperar. Tomados tabla por tabla con cada ALTER, la migración retendría
-- pedido_items mientras espera productos o clientes, y el alta de un pedido (clientes → productos → pedido_items), la
-- compra y el bot los toman en otro orden: deadlock, y muere la transacción de la app. Con NOWAIT la migración nunca
-- espera: o los consigue todos ya, o falla en el acto sin haber bloqueado nada y se reintenta. Después de este LOCK
-- ningún ALTER espera. El lock_timeout queda como red.
LOCK TABLE public.gastos, public.compra_cargos, public.compra_items, public.notas_credito_venta,
           public.nota_credito_venta_items, public.pedido_combos, public.pedido_item_sustituciones, public.pedido_items,
           public.grupo_precio_escala_minimos, public.productos, public.clientes, public.bot_costo_llm_mensual,
           public.bot_pedidos_pendientes, public.bot_presupuesto_llm, public.empleado_liquidaciones,
           public.rendicion_faltantes, public.movimiento_sucursal_items, public.movimientos_sucursal,
           public.rendicion_pagos_confirmados, public.rendiciones_control, public.sucursales
  IN ACCESS EXCLUSIVE MODE NOWAIT;

-- ---------------------------------------------------------------------------
-- Premisas de esquema (leídas en el volcado del 16/11, ledger en la 512)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_distinto text;
  v_ya       text;
BEGIN
  -- Los CHECK que se reemplazan son los que se leyeron.
  SELECT string_agg(e.t || '.' || e.n, ', ') INTO v_distinto
    FROM (VALUES
      ('gastos', 'gastos_iva_check', 'CHECK ((iva >= (0)::numeric))'),
      ('gastos', 'gastos_percepcion_iva_check', 'CHECK ((percepcion_iva >= (0)::numeric))'),
      ('gastos', 'gastos_percepcion_iibb_check', 'CHECK ((percepcion_iibb >= (0)::numeric))'),
      ('gastos', 'gastos_otros_impuestos_check', 'CHECK ((otros_impuestos >= (0)::numeric))'),
      ('gastos', 'gastos_litros_check', 'CHECK (((litros IS NULL) OR (litros > (0)::numeric)))'),
      ('compra_cargos', 'compra_cargos_iva_monto_no_negativo', 'CHECK ((iva_monto >= (0)::numeric))'),
      ('notas_credito_venta', 'notas_credito_venta_desglose_no_negativo',
       'CHECK (((neto >= (0)::numeric) AND (iva >= (0)::numeric)))'),
      ('notas_credito_venta', 'notas_credito_venta_total_positivo', 'CHECK ((total > (0)::numeric))'),
      ('nota_credito_venta_items', 'nota_credito_venta_items_precio_unitario_check',
       'CHECK ((precio_unitario >= (0)::numeric))'),
      ('nota_credito_venta_items', 'nota_credito_venta_items_subtotal_check', 'CHECK ((subtotal >= (0)::numeric))'),
      ('pedido_combos', 'pedido_combos_precio_check', 'CHECK ((precio > (0)::numeric))'),
      ('pedido_item_sustituciones', 'pedido_item_sustituciones_cantidad_original_check',
       'CHECK ((cantidad_original > (0)::numeric))'),
      ('pedido_item_sustituciones', 'pedido_item_sustituciones_cantidad_sustituta_check',
       'CHECK ((cantidad_sustituta > (0)::numeric))'),
      ('grupo_precio_escala_minimos', 'grupo_precio_escala_minimos_precio_unitario_override_check',
       'CHECK (((precio_unitario_override IS NULL) OR (precio_unitario_override > (0)::numeric)))'),
      ('productos', 'productos_cantidad_minima_venta_check',
       'CHECK (((cantidad_minima_venta IS NULL) OR (cantidad_minima_venta > 0)))'),
      ('bot_costo_llm_mensual', 'bot_costo_llm_mensual_usd_check', 'CHECK ((usd >= (0)::numeric))'),
      ('bot_pedidos_pendientes', 'bot_pedidos_pendientes_cargo_mostrado_no_negativo',
       'CHECK ((cargo_mostrado >= (0)::numeric))'),
      ('bot_presupuesto_llm', 'bot_presupuesto_llm_techo_usd_mes_check', 'CHECK ((techo_usd_mes > (0)::numeric))'),
      ('empleado_liquidaciones', 'empleado_liquidaciones_pagado_check', 'CHECK ((pagado >= (0)::numeric))'),
      ('rendicion_faltantes', 'rendicion_faltantes_monto_check', 'CHECK ((monto > (0)::numeric))')
    ) AS e(t, n, d)
   WHERE (SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
           WHERE c.conrelid = ('public.' || e.t)::regclass AND c.conname = e.n) IS DISTINCT FROM e.d;
  IF v_distinto IS NOT NULL THEN
    RAISE EXCEPTION 'estos CHECK no son los que se leyeron: %', v_distinto;
  END IF;

  -- Los nuevos no existen.
  SELECT string_agg(conname, ', ') INTO v_ya
    FROM pg_constraint
   WHERE connamespace = 'public'::regnamespace
     AND conname IN ('compra_items_bonificacion_rango', 'compra_items_costo_promedio_anterior_finito',
                     'productos_precios_no_negativos', 'productos_stock_minimo_no_negativo',
                     'productos_nombre_no_vacio', 'clientes_textos_no_vacios', 'pedido_items_fotos_validas',
                     'bot_pedidos_pendientes_totales_finitos', 'movimiento_sucursal_items_valores_finitos',
                     'movimientos_sucursal_total_costo_finito', 'rendicion_pagos_confirmados_montos_finitos',
                     'rendiciones_control_total_entregado_finito', 'sucursales_coordenadas_rango');
  IF v_ya IS NOT NULL THEN
    RAISE EXCEPTION 'estos CHECK ya existen: %', v_ya;
  END IF;

  -- Las columnas tienen el tipo que se leyó: con precisión no admiten 'Infinity', y sin precisión el CHECK lo
  -- excluye a mano.
  SELECT string_agg(e.t || '.' || e.c, ', ') INTO v_distinto
    FROM (VALUES
      ('gastos', 'iva', 'numeric(14,2)'), ('gastos', 'percepcion_iva', 'numeric(14,2)'),
      ('gastos', 'percepcion_iibb', 'numeric(14,2)'), ('gastos', 'otros_impuestos', 'numeric(14,2)'),
      ('gastos', 'litros', 'numeric(10,2)'),
      ('compra_cargos', 'iva_monto', 'numeric(12,2)'),
      ('notas_credito_venta', 'neto', 'numeric'), ('notas_credito_venta', 'iva', 'numeric'),
      ('notas_credito_venta', 'total', 'numeric'),
      ('nota_credito_venta_items', 'precio_unitario', 'numeric'), ('nota_credito_venta_items', 'subtotal', 'numeric'),
      ('pedido_combos', 'precio', 'numeric(12,2)'),
      ('pedido_item_sustituciones', 'cantidad_original', 'numeric(10,2)'),
      ('pedido_item_sustituciones', 'cantidad_sustituta', 'numeric(10,2)'),
      ('grupo_precio_escala_minimos', 'precio_unitario_override', 'numeric(12,2)'),
      ('compra_items', 'bonificacion', 'numeric'), ('compra_items', 'costo_promedio_anterior', 'numeric'),
      ('productos', 'precio', 'numeric(10,2)'), ('productos', 'precio_sin_iva', 'numeric(12,2)'),
      ('productos', 'stock_minimo', 'integer'), ('productos', 'cantidad_minima_venta', 'integer'),
      ('productos', 'nombre', 'text'),
      ('clientes', 'razon_social', 'text'), ('clientes', 'nombre_fantasia', 'text'), ('clientes', 'direccion', 'text'),
      ('pedido_items', 'costo_unitario_al_crear', 'numeric'), ('pedido_items', 'precio_lista_al_crear', 'numeric(12,2)'),
      ('pedido_items', 'descuento_pct', 'numeric(5,2)'),
      ('bot_costo_llm_mensual', 'usd', 'numeric(12,6)'), ('bot_pedidos_pendientes', 'cargo_mostrado', 'numeric(12,2)'),
      ('bot_pedidos_pendientes', 'total', 'numeric'), ('bot_pedidos_pendientes', 'total_iva', 'numeric'),
      ('bot_pedidos_pendientes', 'total_neto', 'numeric'),
      ('bot_presupuesto_llm', 'techo_usd_mes', 'numeric(10,2)'),
      ('empleado_liquidaciones', 'pagado', 'numeric(14,2)'), ('rendicion_faltantes', 'monto', 'numeric(14,2)'),
      ('movimiento_sucursal_items', 'costo_aplicado_destino', 'numeric'),
      ('movimiento_sucursal_items', 'origen_costo_con_iva', 'numeric'),
      ('movimiento_sucursal_items', 'origen_costo_promedio', 'numeric'),
      ('movimiento_sucursal_items', 'origen_costo_sin_iva', 'numeric'),
      ('movimiento_sucursal_items', 'origen_impuestos_internos', 'numeric'),
      ('movimiento_sucursal_items', 'origen_porcentaje_iva', 'numeric'),
      ('movimiento_sucursal_items', 'origen_precio', 'numeric'),
      ('movimiento_sucursal_items', 'origen_precio_sin_iva', 'numeric'),
      ('movimiento_sucursal_items', 'origen_unidades_por_fardo', 'numeric'),
      ('movimientos_sucursal', 'total_costo', 'numeric'),
      ('rendicion_pagos_confirmados', 'monto', 'numeric'), ('rendicion_pagos_confirmados', 'pedido_total', 'numeric'),
      ('rendiciones_control', 'total_entregado_confirmado', 'numeric'),
      ('sucursales', 'deposito_lat', 'numeric'), ('sucursales', 'deposito_lng', 'numeric'),
      ('sucursales', 'destino_lat', 'numeric'), ('sucursales', 'destino_lng', 'numeric')
    ) AS e(t, c, ty)
   WHERE (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
           WHERE a.attrelid = ('public.' || e.t)::regclass AND a.attname = e.c AND NOT a.attisdropped)
         IS DISTINCT FROM e.ty;
  IF v_distinto IS NOT NULL THEN
    RAISE EXCEPTION 'estas columnas no tienen el tipo que se leyó: %', v_distinto;
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Premisa de datos: ninguna fila viola los CHECK nuevos. Se cuenta antes para que el error diga cuál; el
-- ADD CONSTRAINT valida igual. Es la misma consulta que se corre en prod antes de aplicar.
-- ---------------------------------------------------------------------------
DO $premisas_datos$
DECLARE
  v_malas text;
BEGIN
  SELECT string_agg(e.k || '=' || e.n, ', ') INTO v_malas
    FROM (VALUES
      ('gastos.iva_y_percepciones', (SELECT count(*) FROM public.gastos
                                      WHERE iva = 'NaN' OR percepcion_iva = 'NaN' OR percepcion_iibb = 'NaN'
                                         OR otros_impuestos = 'NaN')),
      ('gastos.litros', (SELECT count(*) FROM public.gastos WHERE litros = 'NaN')),
      ('compra_cargos.iva_monto', (SELECT count(*) FROM public.compra_cargos WHERE iva_monto = 'NaN')),
      ('notas_credito_venta', (SELECT count(*) FROM public.notas_credito_venta
                                WHERE neto IN ('NaN', 'Infinity') OR iva IN ('NaN', 'Infinity')
                                   OR total IN ('NaN', 'Infinity'))),
      ('nota_credito_venta_items', (SELECT count(*) FROM public.nota_credito_venta_items
                                     WHERE precio_unitario IN ('NaN', 'Infinity') OR subtotal IN ('NaN', 'Infinity'))),
      ('pedido_combos.precio', (SELECT count(*) FROM public.pedido_combos WHERE precio = 'NaN')),
      ('pedido_item_sustituciones', (SELECT count(*) FROM public.pedido_item_sustituciones
                                      WHERE cantidad_original = 'NaN' OR cantidad_sustituta = 'NaN')),
      ('grupo_precio_escala_minimos.precio_unitario_override',
       (SELECT count(*) FROM public.grupo_precio_escala_minimos WHERE precio_unitario_override = 'NaN')),
      ('compra_items.bonificacion', (SELECT count(*) FROM public.compra_items
                                      WHERE bonificacion < 0 OR bonificacion > 100)),
      ('compra_items.costo_promedio_anterior', (SELECT count(*) FROM public.compra_items
                                                 WHERE costo_promedio_anterior IN ('NaN', 'Infinity', '-Infinity'))),
      ('productos.precios', (SELECT count(*) FROM public.productos WHERE precio < 0 OR precio_sin_iva < 0)),
      ('productos.stock_minimo', (SELECT count(*) FROM public.productos WHERE stock_minimo < 0)),
      ('productos.cantidad_minima_venta', (SELECT count(*) FROM public.productos
                                            WHERE cantidad_minima_venta <= 0 OR cantidad_minima_venta > 99999999)),
      ('productos.nombre', (SELECT count(*) FROM public.productos WHERE btrim(nombre) = '')),
      ('clientes.textos', (SELECT count(*) FROM public.clientes
                            WHERE btrim(razon_social) = '' OR btrim(nombre_fantasia) = '' OR btrim(direccion) = '')),
      ('pedido_items.fotos', (SELECT count(*) FROM public.pedido_items
                               WHERE costo_unitario_al_crear IN ('NaN', 'Infinity', '-Infinity')
                                  OR precio_lista_al_crear = 'NaN' OR descuento_pct = 'NaN')),
      ('bot_costo_llm_mensual.usd', (SELECT count(*) FROM public.bot_costo_llm_mensual WHERE usd = 'NaN')),
      ('bot_pedidos_pendientes', (SELECT count(*) FROM public.bot_pedidos_pendientes
                                   WHERE cargo_mostrado = 'NaN'
                                      OR total IN ('NaN', 'Infinity', '-Infinity')
                                      OR total_iva IN ('NaN', 'Infinity', '-Infinity')
                                      OR total_neto IN ('NaN', 'Infinity', '-Infinity'))),
      ('bot_presupuesto_llm.techo_usd_mes', (SELECT count(*) FROM public.bot_presupuesto_llm
                                              WHERE techo_usd_mes = 'NaN')),
      ('empleado_liquidaciones.pagado', (SELECT count(*) FROM public.empleado_liquidaciones WHERE pagado = 'NaN')),
      ('rendicion_faltantes.monto', (SELECT count(*) FROM public.rendicion_faltantes WHERE monto = 'NaN')),
      ('movimiento_sucursal_items', (SELECT count(*) FROM public.movimiento_sucursal_items m
                                      WHERE EXISTS (SELECT 1 FROM unnest(ARRAY[m.costo_aplicado_destino,
                                                      m.origen_costo_con_iva, m.origen_costo_promedio,
                                                      m.origen_costo_sin_iva, m.origen_impuestos_internos,
                                                      m.origen_porcentaje_iva, m.origen_precio, m.origen_precio_sin_iva,
                                                      m.origen_unidades_por_fardo]) AS v(x)
                                                     WHERE v.x IN ('NaN', 'Infinity', '-Infinity')))),
      ('movimientos_sucursal.total_costo', (SELECT count(*) FROM public.movimientos_sucursal
                                             WHERE total_costo IN ('NaN', 'Infinity', '-Infinity'))),
      ('rendicion_pagos_confirmados', (SELECT count(*) FROM public.rendicion_pagos_confirmados
                                        WHERE monto IN ('NaN', 'Infinity', '-Infinity')
                                           OR pedido_total IN ('NaN', 'Infinity', '-Infinity'))),
      ('rendiciones_control.total_entregado_confirmado',
       (SELECT count(*) FROM public.rendiciones_control
         WHERE total_entregado_confirmado IN ('NaN', 'Infinity', '-Infinity'))),
      ('sucursales.coordenadas', (SELECT count(*) FROM public.sucursales
                                   WHERE NOT (deposito_lat BETWEEN -90 AND 90) OR NOT (destino_lat BETWEEN -90 AND 90)
                                      OR NOT (deposito_lng BETWEEN -180 AND 180)
                                      OR NOT (destino_lng BETWEEN -180 AND 180)))
    ) AS e(k, n)
   WHERE e.n > 0;
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'hay filas que violarían los CHECK nuevos: %', v_malas;
  END IF;
END
$premisas_datos$;

-- ---------------------------------------------------------------------------
-- 1 · Gastos (1567-1, 1562-c1) y el barrido (litros)
-- ---------------------------------------------------------------------------
-- Con los cuatro sin NaN, gastos_neto_positivo (monto_total − los cuatro > 0) y la columna generada neto también
-- quedan cerrados: monto_total ya excluye el NaN (493).
ALTER TABLE public.gastos
  DROP CONSTRAINT gastos_iva_check,
  ADD CONSTRAINT gastos_iva_check
  CHECK (iva >= 0 AND iva <> 'NaN'::numeric),
  DROP CONSTRAINT gastos_percepcion_iva_check,
  ADD CONSTRAINT gastos_percepcion_iva_check
  CHECK (percepcion_iva >= 0 AND percepcion_iva <> 'NaN'::numeric),
  DROP CONSTRAINT gastos_percepcion_iibb_check,
  ADD CONSTRAINT gastos_percepcion_iibb_check
  CHECK (percepcion_iibb >= 0 AND percepcion_iibb <> 'NaN'::numeric),
  DROP CONSTRAINT gastos_otros_impuestos_check,
  ADD CONSTRAINT gastos_otros_impuestos_check
  CHECK (otros_impuestos >= 0 AND otros_impuestos <> 'NaN'::numeric),
  DROP CONSTRAINT gastos_litros_check,
  ADD CONSTRAINT gastos_litros_check
  CHECK (litros IS NULL OR (litros > 0 AND litros <> 'NaN'::numeric));

-- ---------------------------------------------------------------------------
-- 2 · Compras (1567-5, 1557-c1)
-- ---------------------------------------------------------------------------
ALTER TABLE public.compra_cargos
  DROP CONSTRAINT compra_cargos_iva_monto_no_negativo,
  ADD CONSTRAINT compra_cargos_iva_monto_no_negativo
  CHECK (iva_monto >= 0 AND iva_monto <> 'NaN'::numeric);

ALTER TABLE public.compra_items
  -- Un porcentaje: las RPCs lo validan entre 0 y 100 (el 100 es el regalo). El techo deja afuera NaN e infinito.
  ADD CONSTRAINT compra_items_bonificacion_rango
  CHECK (bonificacion >= 0 AND bonificacion <= 100),
  -- La foto del costo promedio antes de la compra: calculada, sin piso.
  ADD CONSTRAINT compra_items_costo_promedio_anterior_finito
  CHECK (costo_promedio_anterior <> 'NaN'::numeric AND costo_promedio_anterior <> 'Infinity'::numeric
         AND costo_promedio_anterior <> '-Infinity'::numeric);

-- ---------------------------------------------------------------------------
-- 3 · Notas de crédito de venta (1567-6, 1567-7, 1559-c3): sin precisión, NaN e infinito
-- ---------------------------------------------------------------------------
ALTER TABLE public.notas_credito_venta
  DROP CONSTRAINT notas_credito_venta_desglose_no_negativo,
  ADD CONSTRAINT notas_credito_venta_desglose_no_negativo
  CHECK (neto >= 0 AND neto <> 'NaN'::numeric AND neto <> 'Infinity'::numeric
         AND iva >= 0 AND iva <> 'NaN'::numeric AND iva <> 'Infinity'::numeric),
  DROP CONSTRAINT notas_credito_venta_total_positivo,
  ADD CONSTRAINT notas_credito_venta_total_positivo
  CHECK (total > 0 AND total <> 'NaN'::numeric AND total <> 'Infinity'::numeric);

ALTER TABLE public.nota_credito_venta_items
  DROP CONSTRAINT nota_credito_venta_items_precio_unitario_check,
  ADD CONSTRAINT nota_credito_venta_items_precio_unitario_check
  CHECK (precio_unitario >= 0 AND precio_unitario <> 'NaN'::numeric AND precio_unitario <> 'Infinity'::numeric),
  DROP CONSTRAINT nota_credito_venta_items_subtotal_check,
  ADD CONSTRAINT nota_credito_venta_items_subtotal_check
  CHECK (subtotal >= 0 AND subtotal <> 'NaN'::numeric AND subtotal <> 'Infinity'::numeric);

-- ---------------------------------------------------------------------------
-- 4 · Pedido: combos, sustituciones y las fotos de la línea (1567-8, 1567-9, H4)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedido_combos
  DROP CONSTRAINT pedido_combos_precio_check,
  ADD CONSTRAINT pedido_combos_precio_check
  CHECK (precio > 0 AND precio <> 'NaN'::numeric);

ALTER TABLE public.pedido_item_sustituciones
  DROP CONSTRAINT pedido_item_sustituciones_cantidad_original_check,
  ADD CONSTRAINT pedido_item_sustituciones_cantidad_original_check
  CHECK (cantidad_original > 0 AND cantidad_original <> 'NaN'::numeric),
  DROP CONSTRAINT pedido_item_sustituciones_cantidad_sustituta_check,
  ADD CONSTRAINT pedido_item_sustituciones_cantidad_sustituta_check
  CHECK (cantidad_sustituta > 0 AND cantidad_sustituta <> 'NaN'::numeric);

-- Lo que registrar_salvedad copia a salvedad_linea_foto, con los mismos frenos que la foto: el costo finito (puede
-- ser negativo con un cargo negativo), la lista y el descuento sin NaN.
ALTER TABLE public.pedido_items
  ADD CONSTRAINT pedido_items_fotos_validas
  CHECK (costo_unitario_al_crear <> 'NaN'::numeric AND costo_unitario_al_crear <> 'Infinity'::numeric
         AND costo_unitario_al_crear <> '-Infinity'::numeric
         AND precio_lista_al_crear <> 'NaN'::numeric
         AND descuento_pct <> 'NaN'::numeric);

-- ---------------------------------------------------------------------------
-- 5 · Precios y catálogo (1567-10, 1596-b1)
-- ---------------------------------------------------------------------------
ALTER TABLE public.grupo_precio_escala_minimos
  DROP CONSTRAINT grupo_precio_escala_minimos_precio_unitario_override_check,
  ADD CONSTRAINT grupo_precio_escala_minimos_precio_unitario_override_check
  CHECK (precio_unitario_override IS NULL
         OR (precio_unitario_override > 0 AND precio_unitario_override <> 'NaN'::numeric));

-- El NaN de precio y precio_sin_iva ya lo frena productos_precios_no_nan (487).
ALTER TABLE public.productos
  ADD CONSTRAINT productos_precios_no_negativos
  CHECK (precio >= 0 AND precio_sin_iva >= 0),
  ADD CONSTRAINT productos_stock_minimo_no_negativo
  CHECK (stock_minimo >= 0),
  -- Techo del mínimo de venta: 99.999.999 (D36 de #1596, decisión del dueño). NULL es «sin mínimo».
  DROP CONSTRAINT productos_cantidad_minima_venta_check,
  ADD CONSTRAINT productos_cantidad_minima_venta_check
  CHECK (cantidad_minima_venta IS NULL OR (cantidad_minima_venta > 0 AND cantidad_minima_venta <= 99999999)),
  ADD CONSTRAINT productos_nombre_no_vacio
  CHECK (btrim(nombre) <> '');

-- ---------------------------------------------------------------------------
-- 6 · Clientes (1561-b13)
-- ---------------------------------------------------------------------------
ALTER TABLE public.clientes
  ADD CONSTRAINT clientes_textos_no_vacios
  CHECK (btrim(razon_social) <> '' AND btrim(nombre_fantasia) <> '' AND btrim(direccion) <> '');

-- ---------------------------------------------------------------------------
-- 7 · El barrido: pisos sin NaN y columnas sin precisión sin freno de infinito
-- ---------------------------------------------------------------------------
ALTER TABLE public.bot_costo_llm_mensual
  DROP CONSTRAINT bot_costo_llm_mensual_usd_check,
  ADD CONSTRAINT bot_costo_llm_mensual_usd_check
  CHECK (usd >= 0 AND usd <> 'NaN'::numeric);

ALTER TABLE public.bot_pedidos_pendientes
  DROP CONSTRAINT bot_pedidos_pendientes_cargo_mostrado_no_negativo,
  ADD CONSTRAINT bot_pedidos_pendientes_cargo_mostrado_no_negativo
  CHECK (cargo_mostrado >= 0 AND cargo_mostrado <> 'NaN'::numeric),
  ADD CONSTRAINT bot_pedidos_pendientes_totales_finitos
  CHECK (total <> 'NaN'::numeric AND total <> 'Infinity'::numeric AND total <> '-Infinity'::numeric
         AND total_iva <> 'NaN'::numeric AND total_iva <> 'Infinity'::numeric AND total_iva <> '-Infinity'::numeric
         AND total_neto <> 'NaN'::numeric AND total_neto <> 'Infinity'::numeric
         AND total_neto <> '-Infinity'::numeric);

ALTER TABLE public.bot_presupuesto_llm
  DROP CONSTRAINT bot_presupuesto_llm_techo_usd_mes_check,
  ADD CONSTRAINT bot_presupuesto_llm_techo_usd_mes_check
  CHECK (techo_usd_mes > 0 AND techo_usd_mes <> 'NaN'::numeric);

ALTER TABLE public.empleado_liquidaciones
  DROP CONSTRAINT empleado_liquidaciones_pagado_check,
  ADD CONSTRAINT empleado_liquidaciones_pagado_check
  CHECK (pagado >= 0 AND pagado <> 'NaN'::numeric);

ALTER TABLE public.rendicion_faltantes
  DROP CONSTRAINT rendicion_faltantes_monto_check,
  ADD CONSTRAINT rendicion_faltantes_monto_check
  CHECK (monto > 0 AND monto <> 'NaN'::numeric);

-- Fotos del producto de origen y del costo aplicado en el destino: calculadas, sin piso.
ALTER TABLE public.movimiento_sucursal_items
  ADD CONSTRAINT movimiento_sucursal_items_valores_finitos
  CHECK (costo_aplicado_destino NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND origen_costo_con_iva NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND origen_costo_promedio NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND origen_costo_sin_iva NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND origen_impuestos_internos NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND origen_porcentaje_iva NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND origen_precio NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND origen_precio_sin_iva NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND origen_unidades_por_fardo NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric));

ALTER TABLE public.movimientos_sucursal
  ADD CONSTRAINT movimientos_sucursal_total_costo_finito
  CHECK (total_costo NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric));

-- La foto de la rendición confirmada (trg_rendiciones_control_foto) y su total entregado.
ALTER TABLE public.rendicion_pagos_confirmados
  ADD CONSTRAINT rendicion_pagos_confirmados_montos_finitos
  CHECK (monto NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
         AND pedido_total NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric));

ALTER TABLE public.rendiciones_control
  ADD CONSTRAINT rendiciones_control_total_entregado_finito
  CHECK (total_entregado_confirmado NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric));

-- Las coordenadas del depósito y del destino de la sucursal las carga el admin: llevan su rango, como el GPS de
-- pedidos y visitas. El rango deja afuera NaN e infinito.
ALTER TABLE public.sucursales
  ADD CONSTRAINT sucursales_coordenadas_rango
  CHECK (deposito_lat BETWEEN -90 AND 90 AND destino_lat BETWEEN -90 AND 90
         AND deposito_lng BETWEEN -180 AND 180 AND destino_lng BETWEEN -180 AND 180);

-- ---------------------------------------------------------------------------
-- Poscondición
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_faltan text;
BEGIN
  SELECT string_agg(e.n, ', ') INTO v_faltan
    FROM unnest(ARRAY['gastos_iva_check', 'gastos_percepcion_iva_check', 'gastos_percepcion_iibb_check',
                      'gastos_otros_impuestos_check', 'gastos_litros_check', 'compra_cargos_iva_monto_no_negativo',
                      'compra_items_bonificacion_rango', 'compra_items_costo_promedio_anterior_finito',
                      'notas_credito_venta_desglose_no_negativo', 'notas_credito_venta_total_positivo',
                      'nota_credito_venta_items_precio_unitario_check', 'nota_credito_venta_items_subtotal_check',
                      'pedido_combos_precio_check', 'pedido_item_sustituciones_cantidad_original_check',
                      'pedido_item_sustituciones_cantidad_sustituta_check', 'pedido_items_fotos_validas',
                      'grupo_precio_escala_minimos_precio_unitario_override_check', 'productos_precios_no_negativos',
                      'productos_stock_minimo_no_negativo', 'productos_cantidad_minima_venta_check',
                      'productos_nombre_no_vacio', 'clientes_textos_no_vacios', 'bot_costo_llm_mensual_usd_check',
                      'bot_pedidos_pendientes_cargo_mostrado_no_negativo', 'bot_pedidos_pendientes_totales_finitos',
                      'bot_presupuesto_llm_techo_usd_mes_check', 'empleado_liquidaciones_pagado_check',
                      'rendicion_faltantes_monto_check', 'movimiento_sucursal_items_valores_finitos',
                      'movimientos_sucursal_total_costo_finito', 'rendicion_pagos_confirmados_montos_finitos',
                      'rendiciones_control_total_entregado_finito', 'sucursales_coordenadas_rango']) AS e(n)
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                      WHERE c.conname = e.n AND c.connamespace = 'public'::regnamespace
                        AND c.contype = 'c' AND c.convalidated);
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'faltan los CHECK (o no están validados): %', v_faltan;
  END IF;

  -- Cada columna con piso de esta migración tiene un CHECK que excluye el NaN de ESA columna (`<col> <> 'NaN'`).
  SELECT string_agg(e.t || '.' || e.c, ', ') INTO v_faltan
    FROM (VALUES ('gastos', 'iva'), ('gastos', 'percepcion_iva'), ('gastos', 'percepcion_iibb'),
                 ('gastos', 'otros_impuestos'), ('gastos', 'litros'), ('compra_cargos', 'iva_monto'),
                 ('notas_credito_venta', 'neto'), ('notas_credito_venta', 'iva'), ('notas_credito_venta', 'total'),
                 ('nota_credito_venta_items', 'precio_unitario'), ('nota_credito_venta_items', 'subtotal'),
                 ('pedido_combos', 'precio'), ('pedido_item_sustituciones', 'cantidad_original'),
                 ('pedido_item_sustituciones', 'cantidad_sustituta'),
                 ('grupo_precio_escala_minimos', 'precio_unitario_override'), ('bot_costo_llm_mensual', 'usd'),
                 ('bot_pedidos_pendientes', 'cargo_mostrado'), ('bot_presupuesto_llm', 'techo_usd_mes'),
                 ('empleado_liquidaciones', 'pagado'), ('rendicion_faltantes', 'monto')) AS e(t, c)
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint co
                      JOIN pg_attribute a ON a.attrelid = co.conrelid AND a.attnum = ANY (co.conkey)
                     WHERE co.conrelid = ('public.' || e.t)::regclass AND co.contype = 'c' AND a.attname = e.c
                       AND pg_get_constraintdef(co.oid) ~ ('\m' || e.c || '\M <> ''NaN''::numeric'));
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'estas columnas no quedaron con freno de NaN: %', v_faltan;
  END IF;
  -- auditoria_nan() no va acá: recorrería todas las tablas con los locks tomados. Se corre después del COMMIT.
END
$post$;

COMMIT;
