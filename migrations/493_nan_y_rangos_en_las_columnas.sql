-- NNN · NaN y rangos en las columnas (tarjeta 1 de #1565; VTA-A de #1559, CMP-1 de #1557, CAT-4 de #1561 y el bajo
--       de NaN de gastos y personal de #1562).
--
-- Qué arregla:
--   · VTA-A (#1559). La edición de un pedido por un admin acepta un precio 'NaN': actualizar_pedido_items no corre
--     precio_fuera_de_politica para el admin, _items_precio_redondeado deja pasar el NaN y validar_precio_item_pedido
--     compara con `<= 0`. La línea, pedidos.total y clientes.saldo_cuenta quedaban en NaN. pedido_items.precio_unitario,
--     subtotal y pedidos.total no tenían CHECK, y pedidos_cargo_envio_check y pedido_items_combo_coherente tenían piso
--     sin excluir el NaN.
--   · CMP-1 (#1557). En el alta y la edición de una compra entraba 'NaN' por impuestos_internos y porcentaje_iva del
--     renglón y por los importes de la cabecera; en la NC de ajuste, por subtotal, IVA, II y total. El producto quedaba
--     con costo_promedio, costo_real y costo_con_iva en NaN, y las ventas congelaban ese costo.
--   · CAT-4 (#1561). productos.porcentaje_iva, los cuatro costos, unidades_de_venta_por_fardo e impuestos_internos, y
--     clientes.limite_credito, aceptaban 'NaN' y valores fuera de rango (IVA −50 o 999, costo −10, fardo 0, II 500).
--     Con el IVA en NaN el alta dejaba total_neto en NaN. Y clientes.dias_credito = 2147483647 rompe
--     reporte_cuentas_por_cobrar y obtener_deudores_mora para todos (`date out of range`).
--   · El bajo de #1562: gastos.monto_total, empleado_movimientos.monto y empleado_arreglos.sueldo aceptaban 'NaN'
--     escrito directo.
--
-- Cómo:
--   El freno va en la columna (regla de CLAUDE.md): así cubre la RPC, el REST y los triggers. No se toca el cuerpo de
--   ninguna RPC; el mensaje amable de cada una es de su tarjeta (la 3 en compras, la 6 en la edición). Con el CHECK
--   solo, el rechazo ya está: la RPC devuelve el 23514 con el nombre del CHECK.
--   'NaN'::numeric es mayor que todo número: pasa `>= 0` y `> 0`, así que cada piso suma `<> 'NaN'`. Un techo
--   (`<= 100`) ya lo deja afuera. Las columnas numeric con precisión no admiten 'Infinity'; la única sin precisión
--   (notas_credito.impuestos_internos) lo excluye a mano. `x <> 'NaN'` es NULL con x NULL y un CHECK NULL pasa: las
--   columnas que admiten NULL lo siguen admitiendo.
--
--   Los rangos, con su premisa contada en prod el 12/11 (sólo SELECT): 0 filas violan cada CHECK.
--     · pedido_items: precio_unitario y subtotal >= 0 (el regalo va a 0). pedido_items_combo_coherente suma el NaN a
--       precio_sin_combo_unitario > 0 (0 filas con combo hoy).
--     · pedidos: total >= 0 (el cancelado va a 0, VENTA-I) y pedidos_cargo_envio_check suma el NaN.
--     · productos: porcentaje_iva e impuestos_internos entre 0 y 100 (son alícuotas: hoy 21 y hasta 8,6957);
--       costo_sin_iva y costo_con_iva >= 0 (salen de un costo y una bonificación de 0 a 100, nunca de un cargo);
--       unidades_de_venta_por_fardo > 0 (hoy hasta 2, y 355 NULL). costo_real y costo_promedio, sólo sin NaN: un cargo
--       negativo mayor que su renglón los deja negativos (CMP-3), y ese piso lo pone la tarjeta 3 en la RPC.
--     · clientes: limite_credito >= 0 (hoy todos en 0) y dias_credito entre 0 y 365 (hoy hasta 30).
--     · compras: la cabecera >= 0, salvo bonificaciones, que se guarda en negativo (las 3 que hay: 303, 304 y 6535) y
--       queda sólo sin NaN.
--     · compra_items: porcentaje_iva e impuestos_internos entre 0 y 100 (hoy 0, 10,5 y 21; II hasta 9,18), y
--       costo_real_unitario sólo sin NaN, como costo_real.
--     · notas_credito: subtotal, IVA y total >= 0, y el II (ya >= 0) sin NaN ni infinito.
--     · gastos.monto_total (> 0), empleado_movimientos.monto (<> 0, su signo depende del tipo) y
--       empleado_arreglos.sueldo (>= 0) suman el NaN a su CHECK.
--   auditoria_nan() no cambia: ya recorre toda columna numeric de las tablas de public (pg_attribute), así que cuenta
--   las de esta migración. El ensayo lo comprueba columna por columna.
--
-- Ensayo: scripts/test-nan-y-rangos-1565-t1.sql (un DO que termina en excepción; no deja nada). Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- Los ALTER TABLE toman ACCESS EXCLUSIVE mientras validan. Si hay una transacción larga adelante, mejor fallar y
-- reintentar que dejar la cola de locks de pedidos y productos trabada detrás.
SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- Premisas (leídas en prod el 12/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_distinto text;
  v_ya       text;
BEGIN
  -- Los seis CHECK que se reemplazan son los que se leyeron.
  SELECT string_agg(e.t || '.' || e.n, ', ') INTO v_distinto
    FROM (VALUES
      ('pedidos', 'pedidos_cargo_envio_check',
       'CHECK ((cargo_envio >= (0)::numeric))'),
      ('pedido_items', 'pedido_items_combo_coherente',
       'CHECK ((((combo_id IS NULL) AND (precio_sin_combo_unitario IS NULL)) OR ((combo_id IS NOT NULL) AND (precio_sin_combo_unitario > (0)::numeric) AND (NOT COALESCE(es_bonificacion, false)) AND ((origen_precio)::text = ''combo''::text))))'),
      ('notas_credito', 'notas_credito_ii_no_negativo',
       'CHECK ((impuestos_internos >= (0)::numeric))'),
      ('gastos', 'gastos_monto_total_check',
       'CHECK ((monto_total > (0)::numeric))'),
      ('empleado_movimientos', 'empleado_movimientos_monto_check',
       'CHECK ((monto <> (0)::numeric))'),
      ('empleado_arreglos', 'empleado_arreglos_sueldo_check',
       'CHECK ((sueldo >= (0)::numeric))')
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
     AND conname IN ('pedido_items_precio_unitario_valido', 'pedido_items_subtotal_valido', 'pedidos_total_valido',
                     'productos_porcentaje_iva_rango', 'productos_impuestos_internos_rango',
                     'productos_costos_de_lista_validos', 'productos_costos_calculados_no_nan',
                     'productos_unidades_de_venta_por_fardo_valida', 'clientes_limite_credito_valido',
                     'clientes_dias_credito_rango', 'compras_importes_validos', 'compra_items_porcentaje_iva_rango',
                     'compra_items_impuestos_internos_rango', 'compra_items_costo_real_no_nan',
                     'notas_credito_importes_validos');
  IF v_ya IS NOT NULL THEN
    RAISE EXCEPTION 'estos CHECK ya existen: %', v_ya;
  END IF;

  -- Las columnas tienen el tipo que se leyó. Con precisión no admiten 'Infinity'; la única sin precisión es el II de
  -- notas_credito, y su CHECK lo excluye a mano.
  SELECT string_agg(e.t || '.' || e.c, ', ') INTO v_distinto
    FROM (VALUES
      ('pedido_items', 'precio_unitario', 'numeric(10,2)'), ('pedido_items', 'subtotal', 'numeric(10,2)'),
      ('pedidos', 'total', 'numeric(10,2)'), ('pedidos', 'cargo_envio', 'numeric(12,2)'),
      ('productos', 'porcentaje_iva', 'numeric(5,2)'), ('productos', 'impuestos_internos', 'numeric(12,4)'),
      ('productos', 'costo_sin_iva', 'numeric(12,2)'), ('productos', 'costo_con_iva', 'numeric(12,2)'),
      ('productos', 'costo_real', 'numeric(12,4)'), ('productos', 'costo_promedio', 'numeric(12,4)'),
      ('productos', 'unidades_de_venta_por_fardo', 'numeric(10,2)'),
      ('clientes', 'limite_credito', 'numeric(12,2)'), ('clientes', 'dias_credito', 'integer'),
      ('compras', 'subtotal', 'numeric(12,2)'), ('compras', 'iva', 'numeric(12,2)'),
      ('compras', 'otros_impuestos', 'numeric(12,2)'), ('compras', 'total', 'numeric(12,2)'),
      ('compras', 'impuestos_internos', 'numeric(12,2)'), ('compras', 'percepcion_iva', 'numeric(12,2)'),
      ('compras', 'percepcion_iibb', 'numeric(12,2)'), ('compras', 'no_gravado', 'numeric(12,2)'),
      ('compras', 'bonificaciones', 'numeric(12,2)'),
      ('compra_items', 'porcentaje_iva', 'numeric(5,2)'), ('compra_items', 'impuestos_internos', 'numeric(8,4)'),
      ('compra_items', 'costo_real_unitario', 'numeric(12,4)'),
      ('notas_credito', 'subtotal', 'numeric(12,2)'), ('notas_credito', 'iva', 'numeric(12,2)'),
      ('notas_credito', 'total', 'numeric(12,2)'), ('notas_credito', 'impuestos_internos', 'numeric'),
      ('gastos', 'monto_total', 'numeric(14,2)'), ('empleado_movimientos', 'monto', 'numeric(14,2)'),
      ('empleado_arreglos', 'sueldo', 'numeric(12,2)')
    ) AS e(t, c, ty)
   WHERE (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
           WHERE a.attrelid = ('public.' || e.t)::regclass AND a.attname = e.c AND NOT a.attisdropped)
         IS DISTINCT FROM e.ty;
  IF v_distinto IS NOT NULL THEN
    RAISE EXCEPTION 'estas columnas no tienen el tipo que se leyó: %', v_distinto;
  END IF;
END
$premisas$;

-- Premisa de datos: ninguna fila viola los CHECK nuevos (en prod el 12/11: 0 en cada uno). Se cuenta antes para que el
-- error diga cuál; el ADD CONSTRAINT valida igual.
DO $premisas_datos$
DECLARE
  v_malas text;
BEGIN
  SELECT string_agg(e.k || '=' || e.n, ', ') INTO v_malas
    FROM (VALUES
      ('pedido_items.precio_unitario', (SELECT count(*) FROM public.pedido_items
                                         WHERE precio_unitario < 0 OR precio_unitario = 'NaN')),
      ('pedido_items.subtotal', (SELECT count(*) FROM public.pedido_items WHERE subtotal < 0 OR subtotal = 'NaN')),
      ('pedido_items.precio_sin_combo_unitario', (SELECT count(*) FROM public.pedido_items
                                                   WHERE precio_sin_combo_unitario = 'NaN')),
      ('pedidos.total', (SELECT count(*) FROM public.pedidos WHERE total < 0 OR total = 'NaN')),
      ('pedidos.cargo_envio', (SELECT count(*) FROM public.pedidos WHERE cargo_envio = 'NaN')),
      ('productos.porcentaje_iva', (SELECT count(*) FROM public.productos
                                     WHERE porcentaje_iva < 0 OR porcentaje_iva > 100)),
      ('productos.impuestos_internos', (SELECT count(*) FROM public.productos
                                         WHERE impuestos_internos < 0 OR impuestos_internos > 100)),
      ('productos.costos_de_lista', (SELECT count(*) FROM public.productos
                                      WHERE costo_sin_iva < 0 OR costo_sin_iva = 'NaN'
                                         OR costo_con_iva < 0 OR costo_con_iva = 'NaN')),
      ('productos.costos_calculados', (SELECT count(*) FROM public.productos
                                        WHERE costo_real = 'NaN' OR costo_promedio = 'NaN')),
      ('productos.unidades_de_venta_por_fardo', (SELECT count(*) FROM public.productos
                                                  WHERE unidades_de_venta_por_fardo <= 0
                                                     OR unidades_de_venta_por_fardo = 'NaN')),
      ('clientes.limite_credito', (SELECT count(*) FROM public.clientes
                                    WHERE limite_credito < 0 OR limite_credito = 'NaN')),
      ('clientes.dias_credito', (SELECT count(*) FROM public.clientes WHERE dias_credito < 0 OR dias_credito > 365)),
      ('compras', (SELECT count(*) FROM public.compras
                    WHERE subtotal < 0 OR subtotal = 'NaN' OR iva < 0 OR iva = 'NaN'
                       OR otros_impuestos < 0 OR otros_impuestos = 'NaN' OR total < 0 OR total = 'NaN'
                       OR impuestos_internos < 0 OR impuestos_internos = 'NaN'
                       OR percepcion_iva < 0 OR percepcion_iva = 'NaN' OR percepcion_iibb < 0 OR percepcion_iibb = 'NaN'
                       OR no_gravado < 0 OR no_gravado = 'NaN' OR bonificaciones = 'NaN')),
      ('compra_items.porcentaje_iva', (SELECT count(*) FROM public.compra_items
                                        WHERE porcentaje_iva < 0 OR porcentaje_iva > 100)),
      ('compra_items.impuestos_internos', (SELECT count(*) FROM public.compra_items
                                            WHERE impuestos_internos < 0 OR impuestos_internos > 100)),
      ('compra_items.costo_real_unitario', (SELECT count(*) FROM public.compra_items
                                             WHERE costo_real_unitario = 'NaN')),
      ('notas_credito', (SELECT count(*) FROM public.notas_credito
                          WHERE subtotal < 0 OR subtotal = 'NaN' OR iva < 0 OR iva = 'NaN' OR total < 0 OR total = 'NaN'
                             OR impuestos_internos IN ('NaN', 'Infinity'))),
      ('gastos.monto_total', (SELECT count(*) FROM public.gastos WHERE monto_total = 'NaN')),
      ('empleado_movimientos.monto', (SELECT count(*) FROM public.empleado_movimientos WHERE monto = 'NaN')),
      ('empleado_arreglos.sueldo', (SELECT count(*) FROM public.empleado_arreglos WHERE sueldo = 'NaN'))
    ) AS e(k, n)
   WHERE e.n > 0;
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'hay filas que violarían los CHECK nuevos: %', v_malas;
  END IF;
END
$premisas_datos$;

-- ---------------------------------------------------------------------------
-- 1 · Venta: la línea y el pedido (VTA-A)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedido_items
  ADD CONSTRAINT pedido_items_precio_unitario_valido
  CHECK (precio_unitario >= 0 AND precio_unitario <> 'NaN'::numeric),
  ADD CONSTRAINT pedido_items_subtotal_valido
  CHECK (subtotal >= 0 AND subtotal <> 'NaN'::numeric),
  DROP CONSTRAINT pedido_items_combo_coherente,
  ADD CONSTRAINT pedido_items_combo_coherente
  CHECK ((combo_id IS NULL AND precio_sin_combo_unitario IS NULL)
         OR (combo_id IS NOT NULL
             AND precio_sin_combo_unitario > 0 AND precio_sin_combo_unitario <> 'NaN'::numeric
             AND NOT COALESCE(es_bonificacion, false)
             AND origen_precio::text = 'combo'::text));

ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_total_valido
  CHECK (total >= 0 AND total <> 'NaN'::numeric),
  DROP CONSTRAINT pedidos_cargo_envio_check,
  ADD CONSTRAINT pedidos_cargo_envio_check
  CHECK (cargo_envio >= 0 AND cargo_envio <> 'NaN'::numeric);

-- ---------------------------------------------------------------------------
-- 2 · Catálogo y clientes (CAT-4)
-- ---------------------------------------------------------------------------
-- El techo de 100 deja afuera al NaN. productos_precios_no_nan (487) queda: cubre precio y precio_sin_iva.
ALTER TABLE public.productos
  ADD CONSTRAINT productos_porcentaje_iva_rango
  CHECK (porcentaje_iva >= 0 AND porcentaje_iva <= 100),
  ADD CONSTRAINT productos_impuestos_internos_rango
  CHECK (impuestos_internos >= 0 AND impuestos_internos <= 100),
  ADD CONSTRAINT productos_costos_de_lista_validos
  CHECK (costo_sin_iva >= 0 AND costo_sin_iva <> 'NaN'::numeric
         AND costo_con_iva >= 0 AND costo_con_iva <> 'NaN'::numeric),
  -- Sin piso: un cargo negativo los puede dejar negativos (CMP-3); ese freno es de la RPC de la compra (tarjeta 3).
  ADD CONSTRAINT productos_costos_calculados_no_nan
  CHECK (costo_real <> 'NaN'::numeric AND costo_promedio <> 'NaN'::numeric),
  ADD CONSTRAINT productos_unidades_de_venta_por_fardo_valida
  CHECK (unidades_de_venta_por_fardo > 0 AND unidades_de_venta_por_fardo <> 'NaN'::numeric);

ALTER TABLE public.clientes
  ADD CONSTRAINT clientes_limite_credito_valido
  CHECK (limite_credito >= 0 AND limite_credito <> 'NaN'::numeric),
  -- Un año como techo: con 2147483647 los reportes de deuda suman días a una fecha y dan `date out of range`.
  ADD CONSTRAINT clientes_dias_credito_rango
  CHECK (dias_credito >= 0 AND dias_credito <= 365);

-- ---------------------------------------------------------------------------
-- 3 · Compras y notas de crédito (CMP-1)
-- ---------------------------------------------------------------------------
ALTER TABLE public.compras
  ADD CONSTRAINT compras_importes_validos
  CHECK (subtotal >= 0 AND subtotal <> 'NaN'::numeric
         AND iva >= 0 AND iva <> 'NaN'::numeric
         AND otros_impuestos >= 0 AND otros_impuestos <> 'NaN'::numeric
         AND impuestos_internos >= 0 AND impuestos_internos <> 'NaN'::numeric
         AND percepcion_iva >= 0 AND percepcion_iva <> 'NaN'::numeric
         AND percepcion_iibb >= 0 AND percepcion_iibb <> 'NaN'::numeric
         AND no_gravado >= 0 AND no_gravado <> 'NaN'::numeric
         AND total >= 0 AND total <> 'NaN'::numeric
         -- La bonificación de la cabecera se guarda en negativo: sólo se excluye el NaN.
         AND bonificaciones <> 'NaN'::numeric);

ALTER TABLE public.compra_items
  ADD CONSTRAINT compra_items_porcentaje_iva_rango
  CHECK (porcentaje_iva >= 0 AND porcentaje_iva <= 100),
  ADD CONSTRAINT compra_items_impuestos_internos_rango
  CHECK (impuestos_internos >= 0 AND impuestos_internos <= 100),
  ADD CONSTRAINT compra_items_costo_real_no_nan
  CHECK (costo_real_unitario <> 'NaN'::numeric);

ALTER TABLE public.notas_credito
  ADD CONSTRAINT notas_credito_importes_validos
  CHECK (subtotal >= 0 AND subtotal <> 'NaN'::numeric
         AND iva >= 0 AND iva <> 'NaN'::numeric
         AND total >= 0 AND total <> 'NaN'::numeric),
  DROP CONSTRAINT notas_credito_ii_no_negativo,
  ADD CONSTRAINT notas_credito_ii_no_negativo
  CHECK (impuestos_internos >= 0 AND impuestos_internos <> 'NaN'::numeric
         AND impuestos_internos <> 'Infinity'::numeric);

-- ---------------------------------------------------------------------------
-- 4 · Gastos y personal (bajo de #1562)
-- ---------------------------------------------------------------------------
ALTER TABLE public.gastos
  DROP CONSTRAINT gastos_monto_total_check,
  ADD CONSTRAINT gastos_monto_total_check
  CHECK (monto_total > 0 AND monto_total <> 'NaN'::numeric);

ALTER TABLE public.empleado_movimientos
  DROP CONSTRAINT empleado_movimientos_monto_check,
  ADD CONSTRAINT empleado_movimientos_monto_check
  CHECK (monto <> 0 AND monto <> 'NaN'::numeric);

ALTER TABLE public.empleado_arreglos
  DROP CONSTRAINT empleado_arreglos_sueldo_check,
  ADD CONSTRAINT empleado_arreglos_sueldo_check
  CHECK (sueldo >= 0 AND sueldo <> 'NaN'::numeric);

-- ---------------------------------------------------------------------------
-- Poscondición
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_faltan text;
  v_no_ve  text;
BEGIN
  SELECT string_agg(e.n, ', ') INTO v_faltan
    FROM unnest(ARRAY['pedido_items_precio_unitario_valido', 'pedido_items_subtotal_valido',
                      'pedido_items_combo_coherente', 'pedidos_total_valido', 'pedidos_cargo_envio_check',
                      'productos_porcentaje_iva_rango', 'productos_impuestos_internos_rango',
                      'productos_costos_de_lista_validos', 'productos_costos_calculados_no_nan',
                      'productos_unidades_de_venta_por_fardo_valida', 'clientes_limite_credito_valido',
                      'clientes_dias_credito_rango', 'compras_importes_validos', 'compra_items_porcentaje_iva_rango',
                      'compra_items_impuestos_internos_rango', 'compra_items_costo_real_no_nan',
                      'notas_credito_importes_validos', 'notas_credito_ii_no_negativo', 'gastos_monto_total_check',
                      'empleado_movimientos_monto_check', 'empleado_arreglos_sueldo_check']) AS e(n)
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                      WHERE c.conname = e.n AND c.connamespace = 'public'::regnamespace
                        AND c.contype = 'c' AND c.convalidated);
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'faltan los CHECK (o no están validados): %', v_faltan;
  END IF;

  -- Cada CHECK reemplazado ahora excluye el NaN.
  SELECT string_agg(conname, ', ') INTO v_faltan
    FROM pg_constraint
   WHERE connamespace = 'public'::regnamespace
     AND conname IN ('pedido_items_combo_coherente', 'pedidos_cargo_envio_check', 'notas_credito_ii_no_negativo',
                     'gastos_monto_total_check', 'empleado_movimientos_monto_check', 'empleado_arreglos_sueldo_check')
     AND position('''NaN''::numeric' in pg_get_constraintdef(oid)) = 0;
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'estos CHECK no quedaron excluyendo el NaN: %', v_faltan;
  END IF;

  -- auditoria_nan() recorre las columnas numeric de public: todas las de esta migración tienen que ser numeric.
  SELECT string_agg(e.t || '.' || e.c, ', ') INTO v_no_ve
    FROM (VALUES ('pedido_items', 'precio_unitario'), ('pedido_items', 'subtotal'), ('pedidos', 'total'),
                 ('productos', 'porcentaje_iva'), ('productos', 'costo_sin_iva'), ('productos', 'costo_con_iva'),
                 ('productos', 'costo_real'), ('productos', 'costo_promedio'),
                 ('productos', 'unidades_de_venta_por_fardo'), ('clientes', 'limite_credito'),
                 ('compras', 'total'), ('compra_items', 'porcentaje_iva'), ('compra_items', 'impuestos_internos'),
                 ('notas_credito', 'total'), ('notas_credito', 'impuestos_internos'), ('gastos', 'monto_total'),
                 ('empleado_movimientos', 'monto'), ('empleado_arreglos', 'sueldo')) AS e(t, c)
   WHERE (SELECT a.atttypid FROM pg_attribute a
           WHERE a.attrelid = ('public.' || e.t)::regclass AND a.attname = e.c) <> 'numeric'::regtype;
  IF v_no_ve IS NOT NULL THEN
    RAISE EXCEPTION 'auditoria_nan() no ve estas columnas: %', v_no_ve;
  END IF;
  IF jsonb_array_length(public.auditoria_nan()->'con_nan') <> 0 THEN
    RAISE EXCEPTION 'hay filas en NaN o infinito: %', public.auditoria_nan()->'con_nan';
  END IF;
END
$post$;

COMMIT;
