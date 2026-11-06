-- 466 · Compras, notas de crédito de compra y movimientos: lo que se acredita lo calcula la base,
-- el orden global de locks, los rangos del alta y el CHECK de productos.stock (#1471, STK-F-1 a
-- STK-F-7). Tarjeta 4 de #1477.
--
-- QUÉ PASABA
--   · STK-F-3 (media). La nota de crédito de compra acreditaba el costo ANTES de la bonificación:
--     ModalNotaCredito (src/utils/notaCredito.ts) usaba `compra_items.costo_unitario` bruto, y
--     registrar_nota_credito guardaba lo que mandaba el front sin recalcularlo. Un regalo al 100 % se
--     acreditaba a precio lleno: el proveedor quedaba debiendo plata que nunca se pagó. La nota por
--     lote calculaba en la base, pero también sobre el bruto.
--   · STK-F-4 (media). El alta de compra no validaba rangos: una bonificación negativa o de 500, una
--     cantidad con decimales, un costo negativo o una fecha con el año mal tipeado entraban. La fecha
--     futura quedaba como la compra más nueva del producto, y las compras reales de después ya no le
--     movían el costo de reposición.
--   · STK-F-1. registrar_nota_credito_lote tomaba el lote antes que el producto: contra una venta con
--     la bolsa en 0 (que baja a ese lote con el producto ya tomado), 40P01.
--   · STK-F-2. registrar_nota_credito tomaba los productos de a uno, en el orden del JSON y después
--     de las líneas de la compra: contra una venta [A, B], una nota [B, A] daba 40P01. Y
--     actualizar_compra_items bloquea los productos y después borra las líneas de la compra, así que
--     contra la edición de la misma compra también.
--   · STK-F-5. Con el stock corto, registrar_nota_credito lo dejaba en 0 en silencio y la nota por
--     lote rechazaba: dos reglas para el mismo hecho.
--   · STK-F-6. productos.stock no tenía CHECK >= 0.
--   · STK-F-7. crear_movimiento_sucursal y editar_movimiento_sucursal descartaban sin avisar las
--     líneas con cantidad <= 0.
--
-- QUÉ CAMBIA
--   · Las dos notas acreditan cada producto al costo NETO PROMEDIO de sus renglones en la factura,
--     con la bonificación de cada uno (decisión del dueño, 05/11: la base no sabe de qué renglón sale
--     cada unidad, y el promedio nunca acredita más de lo pagado). El IVA va por la alícuota
--     ponderada por el neto. registrar_nota_credito calcula el subtotal, el IVA y el total, guarda un
--     item por producto y rechaza si lo que mandó el front no cierra (0,05 por producto, 1 en la
--     cabecera, como #1077). El ajuste sin mercadería no cambia.
--   · El orden de locks de las dos notas es compra (FOR SHARE) → productos por id → líneas de la
--     compra → lotes por id. Es el de la venta (productos antes que lotes, #1255) y el de
--     actualizar_compra_items (productos antes que líneas).
--   · registrar_nota_credito rechaza si el stock no alcanza (decisión del dueño, 05/11), como la de
--     lote. Ya no hay GREATEST(…, 0).
--   · registrar_compra_completa rechaza, antes de tocar nada: la fecha posterior a hoy o de más de un
--     año atrás (día argentino, decisión del dueño, 05/11); la cantidad que no es un entero > 0; el
--     costo negativo; la bonificación fuera de 0 a 100.
--   · Los dos movimientos rechazan el envío entero si una línea no tiene producto o su cantidad no es
--     un entero > 0, y dicen cuál.
--   · CHECK productos_stock_no_negativo (stock >= 0), después de verificar que no haya ninguno.
--
-- QUÉ NO CAMBIA
--   Las firmas, los EXECUTE, el tope de lo acreditable (por producto), los lotes que baja la nota
--   (los de la compra, FEFO, antes del stock), las etiquetas del ledger, el II
--   (ii_nota_credito_compra) y todo lo demás de registrar_compra_completa. actualizar_compra_items y
--   sincronizar_lotes_compra no se tocan.
--
-- Con el CHECK, un camino que hoy dejaría el stock negativo falla con 23514 en vez de dejarlo:
-- anular_salvedad y renormalizar_bloques_por_cambio_factor bajan sin chequear, y
-- actualizar_compra_items baja y chequea después (su mensaje propio pasa a ser el del CHECK).
--
-- Ensayo: scripts/test-compras-nc-movimientos-1471.sql, y el escenario a4 del arnés (scripts/concurrencia).
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos (05/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
         'e6bdf743a5e77be127f6ed17c053a008'),
        ('public.registrar_nota_credito_lote(bigint,numeric,text,text)',
         'b06393ecf1300f222a6c626f20ac3e3e'),
        ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
         '411289bdf110035bacc00aa429daaee3'),
        ('public.crear_movimiento_sucursal(bigint,text,jsonb)',
         '1d584ce9100f3c2931696ac770c5aae6'),
        ('public.editar_movimiento_sucursal(bigint,text,jsonb)',
         '4c350527a95324a9393721cb1ad9bbab')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 466 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.productos'::regclass AND conname = 'productos_stock_no_negativo') THEN
    RAISE EXCEPTION 'mig 466 · productos_stock_no_negativo ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- STK-F-4 y STK-F-7 · Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
('public.crear_movimiento_sucursal(bigint,text,jsonb)', 1,
$a$    RETURN jsonb_build_object('success', false, 'error', 'Sucursal destino inválida'); END IF;
$a$,
$r$    RETURN jsonb_build_object('success', false, 'error', 'Sucursal destino inválida'); END IF;
  -- #1471 (STK-F-7): una línea con cantidad 0, negativa o con decimales, o sin
  -- un producto, se descartaba en silencio y el envío salía con menos de lo que
  -- se cargó. Ahora se rechaza el envío entero y se dice qué línea.
  IF jsonb_typeof(COALESCE(p_items, '[]'::jsonb)) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Los productos del envío tienen que ser una lista'); END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
    WHERE CASE WHEN COALESCE(e->>'producto_id', '') !~ '^\s*[0-9]+\s*$'
                 OR COALESCE(e->>'cantidad', '') !~ '^\s*-?[0-9]+\s*$' THEN true
               ELSE (e->>'cantidad')::numeric <= 0 END
  ) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Cada producto del envío necesita una cantidad entera mayor a 0: ' || (
        SELECT string_agg(COALESCE(pr.nombre, 'producto ' || COALESCE(e.val->>'producto_id', '?'))
                            || ' (' || COALESCE(e.val->>'cantidad', 'sin cantidad') || ')', ', ' ORDER BY e.n)
          FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) WITH ORDINALITY AS e(val, n)
          LEFT JOIN productos pr
            ON pr.id = CASE WHEN COALESCE(e.val->>'producto_id', '') ~ '^\s*[0-9]+\s*$'
                            THEN (e.val->>'producto_id')::bigint END
           AND pr.sucursal_id = v_origen
         WHERE CASE WHEN COALESCE(e.val->>'producto_id', '') !~ '^\s*[0-9]+\s*$'
                      OR COALESCE(e.val->>'cantidad', '') !~ '^\s*-?[0-9]+\s*$' THEN true
                    ELSE (e.val->>'cantidad')::numeric <= 0 END));
  END IF;

$r$),

('public.editar_movimiento_sucursal(bigint,text,jsonb)', 1,
$a$  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
$a$,
$r$  -- #1471 (STK-F-7): una línea con cantidad 0, negativa o con decimales, o sin
  -- un producto, se descartaba en silencio y el envío salía con menos de lo que
  -- se cargó. Ahora se rechaza el envío entero y se dice qué línea.
  IF jsonb_typeof(COALESCE(p_items, '[]'::jsonb)) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Los productos del envío tienen que ser una lista'); END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
    WHERE CASE WHEN COALESCE(e->>'producto_id', '') !~ '^\s*[0-9]+\s*$'
                 OR COALESCE(e->>'cantidad', '') !~ '^\s*-?[0-9]+\s*$' THEN true
               ELSE (e->>'cantidad')::numeric <= 0 END
  ) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Cada producto del envío necesita una cantidad entera mayor a 0: ' || (
        SELECT string_agg(COALESCE(pr.nombre, 'producto ' || COALESCE(e.val->>'producto_id', '?'))
                            || ' (' || COALESCE(e.val->>'cantidad', 'sin cantidad') || ')', ', ' ORDER BY e.n)
          FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) WITH ORDINALITY AS e(val, n)
          LEFT JOIN productos pr
            ON pr.id = CASE WHEN COALESCE(e.val->>'producto_id', '') ~ '^\s*[0-9]+\s*$'
                            THEN (e.val->>'producto_id')::bigint END
           AND pr.sucursal_id = v_origen
         WHERE CASE WHEN COALESCE(e.val->>'producto_id', '') !~ '^\s*[0-9]+\s*$'
                      OR COALESCE(e.val->>'cantidad', '') !~ '^\s*-?[0-9]+\s*$' THEN true
                    ELSE (e.val->>'cantidad')::numeric <= 0 END));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
$r$),

('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)', 1,
$a$  v_suma_items          NUMERIC;   -- #1077
$a$,
$r$  v_suma_items          NUMERIC;   -- #1077
  v_fuera_de_rango      TEXT;      -- #1471
$r$),

('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)', 2,
$a$  INSERT INTO compras (
    proveedor_id,$a$,
$r$  /* #1471 (STK-F-4) · LOS RANGOS DEL ALTA. La edición (actualizar_compra_items)
     ya los exigía y el alta no: una bonificación de 500 o negativa, una cantidad
     con decimales o un costo negativo entraban, y una fecha con el año mal
     tipeado quedaba como la compra más nueva del producto, así que las compras
     reales de después ya no le movían el costo de reposición. La fecha va entre
     un año atrás y hoy, en el día argentino (decisión del dueño, 05/11). */
  IF p_fecha_compra > public._tablero_hoy() THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('La fecha de la compra (%s) es posterior a hoy. Revisá el año.', to_char(p_fecha_compra, 'DD/MM/YYYY')));
  END IF;
  IF p_fecha_compra < (public._tablero_hoy() - INTERVAL '1 year')::DATE THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('La fecha de la compra (%s) tiene más de un año. Revisá el año.', to_char(p_fecha_compra, 'DD/MM/YYYY')));
  END IF;

  SELECT string_agg(format('%s (renglón %s): %s', COALESCE(pr.nombre, 'producto ' || COALESCE(r.val->>'producto_id', '?')),
                           r.n, r.motivo), '; ' ORDER BY r.n)
    INTO v_fuera_de_rango
    FROM (
      SELECT e.val, e.n,
             CASE
               WHEN COALESCE(e.val->>'cantidad', '') !~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
                 THEN 'la cantidad no es un número'
               WHEN (e.val->>'cantidad')::NUMERIC <> trunc((e.val->>'cantidad')::NUMERIC)
                 THEN 'la cantidad tiene que ser entera'
               WHEN (e.val->>'cantidad')::NUMERIC <= 0
                 THEN 'la cantidad tiene que ser mayor a 0'
               WHEN e.val->>'costo_unitario' IS NOT NULL
                    AND (e.val->>'costo_unitario') !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                 THEN 'el costo no es un número'
               WHEN (e.val->>'costo_unitario')::NUMERIC < 0
                 THEN 'el costo no puede ser negativo'
               WHEN e.val->>'bonificacion' IS NOT NULL
                    AND (e.val->>'bonificacion') !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                 THEN 'la bonificación no es un número'
               WHEN (e.val->>'bonificacion')::NUMERIC < 0 OR (e.val->>'bonificacion')::NUMERIC > 100
                 THEN 'la bonificación es un porcentaje, de 0 a 100'
             END AS motivo
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                       THEN p_items ELSE '[]'::JSONB END) WITH ORDINALITY AS e(val, n)
    ) r
    LEFT JOIN productos pr
      ON pr.id = CASE WHEN COALESCE(r.val->>'producto_id', '') ~ '^\s*[0-9]+\s*$'
                      THEN (r.val->>'producto_id')::BIGINT END
     AND pr.sucursal_id = v_sucursal
   WHERE r.motivo IS NOT NULL;
  IF v_fuera_de_rango IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay renglones fuera de rango: ' || v_fuera_de_rango || '.');
  END IF;

  INSERT INTO compras (
    proveedor_id,$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _n_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _n_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 466 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- STK-F-2, STK-F-3 y STK-F-5 · registrar_nota_credito
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_nota_credito(p_compra_id bigint, p_numero_nota character varying DEFAULT NULL::character varying, p_motivo text DEFAULT NULL::text, p_subtotal numeric DEFAULT 0, p_iva numeric DEFAULT 0, p_total numeric DEFAULT 0, p_usuario_id uuid DEFAULT NULL::uuid, p_items jsonb DEFAULT '[]'::jsonb, p_impuestos_internos numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_nota_id BIGINT;
  v_exceso TEXT;  -- mig 236
  v_tipo TEXT; v_ii NUMERIC; v_total NUMERIC;  -- mig 280
  v_de_lotes INTEGER; v_toma INTEGER; v_lote RECORD;  -- #1079
  v_items JSONB;          -- #1471: p_items, o [] si no vino
  v_lineas JSONB;         -- #1471: lo que acredita la nota, calculado acá
  v_linea RECORD;         -- #1471
  v_mal TEXT;             -- #1471
  v_subtotal NUMERIC; v_iva NUMERIC;  -- #1471
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF NOT (es_encargado_o_admin()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para registrar notas de credito');
  END IF;

  -- #1056: la nota la firma quien la carga. El parámetro queda por la firma
  -- de la RPC; si viene, tiene que ser el mismo usuario.
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'La nota de credito se registra a nombre de quien la carga');
  END IF;

  v_items := COALESCE(p_items, '[]'::jsonb);
  IF jsonb_typeof(v_items) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Los items de la nota de credito tienen que ser una lista');
  END IF;

  -- #1471: cada renglón dice un producto y una cantidad entera mayor a 0. Antes
  -- un "2.5" o un id que no es un número cortaba con un error de cast.
  SELECT string_agg(format('renglón %s', e.n), ', ' ORDER BY e.n)
    INTO v_mal
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS e(val, n)
   WHERE CASE WHEN COALESCE(e.val->>'producto_id', '') !~ '^\s*[0-9]+\s*$'
                OR COALESCE(e.val->>'cantidad', '') !~ '^\s*[0-9]+\s*$' THEN true
              ELSE (e.val->>'cantidad')::NUMERIC <= 0 END;
  IF v_mal IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Cada producto de la nota de credito necesita una cantidad entera mayor a 0 (' || v_mal || ')');
  END IF;

  -- #1095: la compra se toma FOR SHARE, primer lock de la nota. Serializa
  -- contra anular_compra_atomica (que la toma FOR UPDATE): si la anulación va
  -- primero, acá se reevalúa y se ve cancelada; si la nota va primero, la
  -- anulación espera y cuenta esta nota.
  PERFORM 1 FROM compras
   WHERE id = p_compra_id AND estado <> 'cancelada' AND sucursal_id = v_sucursal
     FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada o cancelada');
  END IF;

  /* #1471 (STK-F-2) · EL ORDEN GLOBAL: compra → productos por id → líneas de
     la compra → lotes. Los productos se tomaban de a uno en el orden del JSON,
     y DESPUÉS de las líneas de la compra: contra una venta [A, B] una nota
     [B, A] daba 40P01, y contra actualizar_compra_items (que bloquea los
     productos y después borra las líneas) también. Los FOR UPDATE de abajo
     vuelven a pedir filas ya tomadas. */
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT (i->>'producto_id')::BIGINT FROM jsonb_array_elements(v_items) i)
   ORDER BY id
     FOR UPDATE;

  /* mig 236 · EL TOPE DE LO ACREDITABLE.

     Hasta aca el unico tope vivia en `ModalNotaCredito` (`maxCreditable`, sobre
     una query con staleTime de 5 minutos). Dos notas simultaneas sobre la misma
     compra leian las dos el mismo "ya acreditado", acreditaban el doble y
     descontaban el stock dos veces; y nada impedia acreditar un producto que la
     compra ni siquiera tenia.

     El FOR UPDATE sobre las lineas de la compra es lo que SERIALIZA: la segunda
     nota espera a que la primera termine y recien entonces cuenta lo acreditado,
     que ya la incluye. Va antes de leer los totales, no despues.

     El corte es POR PRODUCTO, igual que el del modal: la base no sabe de que
     renglon salio cada unidad, y repartir por linea seria inventar una
     convencion que el reparto de la pantalla ya hace para mostrar. */
  PERFORM 1 FROM compra_items
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
   ORDER BY id
     FOR UPDATE;

  SELECT string_agg(
           COALESCE(pr.nombre, '#' || d.producto_id) || ' (' ||
           CASE WHEN d.comprado IS NULL              THEN 'no esta en esta compra'
                WHEN d.pedido IS NULL OR d.pedido <= 0 THEN 'cantidad invalida'
                ELSE format('se piden %s y quedan %s', d.pedido,
                            d.comprado - COALESCE(d.acreditado, 0)) END || ')',
           '; ' ORDER BY d.producto_id)
    INTO v_exceso
    FROM (
      SELECT pe.producto_id, pe.pedido, co.comprado, ac.acreditado
        FROM (SELECT (i->>'producto_id')::BIGINT AS producto_id,
                     SUM((i->>'cantidad')::INTEGER) AS pedido
                FROM jsonb_array_elements(v_items) i
               GROUP BY 1) pe
        LEFT JOIN (SELECT producto_id, SUM(cantidad)::INT AS comprado
                     FROM compra_items
                    WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
                    GROUP BY 1) co ON co.producto_id = pe.producto_id
        LEFT JOIN (SELECT nci.producto_id, SUM(nci.cantidad)::INT AS acreditado
                     FROM nota_credito_items nci
                     JOIN notas_credito nc ON nc.id = nci.nota_credito_id
                                          AND nc.sucursal_id = nci.sucursal_id
                    WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
                    GROUP BY 1) ac ON ac.producto_id = pe.producto_id
    ) d
    LEFT JOIN productos pr ON pr.id = d.producto_id AND pr.sucursal_id = v_sucursal
   WHERE d.comprado IS NULL
      OR d.pedido IS NULL
      OR d.pedido <= 0
      OR d.pedido > d.comprado - COALESCE(d.acreditado, 0);

  IF v_exceso IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No se puede acreditar: ' || v_exceso ||
      '. Si la pantalla mostraba otro maximo, recargala: puede haber otra nota de credito sobre esta compra.');
  END IF;

  /* mig 280 (#867) · DEVOLUCION O AJUSTE.

     El tipo lo decide la forma de la nota, no el caller: con items es una
     devolucion (baja stock y acredita lo devuelto, calculado aca); sin items es
     un ajuste sobre la factura —descuento, diferencia de precio, II mal
     liquidado— y no toca stock, costos ni fichas. Los importes del ajuste los
     declara quien lo carga, porque no hay lineas de donde sacarlos. */
  v_tipo := CASE WHEN jsonb_array_length(v_items) > 0 THEN 'devolucion' ELSE 'ajuste' END;

  IF v_tipo = 'ajuste' THEN
    IF COALESCE(p_subtotal, 0) < 0 OR COALESCE(p_iva, 0) < 0 OR COALESCE(p_impuestos_internos, 0) < 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Los importes de la nota de credito no pueden ser negativos');
    END IF;
    IF COALESCE(p_total, 0) <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Una nota de credito sin mercaderia tiene que tener un total mayor a cero');
    END IF;
    IF NULLIF(btrim(COALESCE(p_motivo, '')), '') IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Una nota de credito sin mercaderia necesita un motivo');
    END IF;
    v_subtotal := p_subtotal;
    v_iva      := p_iva;
    v_ii       := round(COALESCE(p_impuestos_internos, 0), 2);
    v_total    := p_total;
  ELSE
    /* #1471 (STK-F-3) · LO QUE SE ACREDITA LO CALCULA LA BASE.

       Se tomaban del front el costo y el subtotal de cada renglón, y el front
       usaba `costo_unitario`, el costo ANTES de la bonificación: un regalo al
       100 % se acreditaba a precio lleno. Ahora cada producto se acredita al
       costo neto PROMEDIO de sus renglones en la factura (decisión del dueño,
       05/11): la base no sabe de qué renglón sale cada unidad, y el promedio
       nunca acredita más de lo que se pagó aunque haya varias notas. Es la
       misma cuenta que registrar_nota_credito_lote y que `notaCredito.ts`:
         costo   = Σ cantidad·costo·(1 − bonif/100) / Σ cantidad
         importe = round(devuelto · costo, 2)
         IVA     = round(importe · alícuota ponderada por el neto / 100, 2)
       Lo que mandó el front se compara contra esto y se rechaza si no cierra
       (un bundle viejo del PWA, o una pantalla con la compra desactualizada). */
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.producto_id)
      INTO v_lineas
      FROM (
        SELECT pe.producto_id, pe.cantidad, pe.sub_front, pr.stock, pr.nombre,
               co.neto / co.comprado AS costo,
               round(pe.cantidad * co.neto / co.comprado, 2) AS subtotal,
               round(round(pe.cantidad * co.neto / co.comprado, 2)
                     * COALESCE(co.base_iva / NULLIF(co.neto, 0), 0) / 100, 2) AS iva
          FROM (SELECT (i->>'producto_id')::BIGINT AS producto_id,
                       SUM((i->>'cantidad')::INTEGER)::INTEGER AS cantidad,
                       SUM(NULLIF(i->>'subtotal', '')::NUMERIC) AS sub_front
                  FROM jsonb_array_elements(v_items) i
                 GROUP BY 1) pe
          JOIN (SELECT ci.producto_id,
                       SUM(ci.cantidad) AS comprado,
                       SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)) AS neto,
                       SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)
                           * CASE WHEN ci.condicion_iva = 'gravado'
                                  THEN COALESCE(ci.porcentaje_iva, 21) ELSE 0 END) AS base_iva
                  FROM compra_items ci
                 WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = v_sucursal
                 GROUP BY 1) co ON co.producto_id = pe.producto_id
          JOIN productos pr ON pr.id = pe.producto_id AND pr.sucursal_id = v_sucursal
      ) x;

    -- #1471 (STK-F-5): lo devuelto sale del stock. Si no alcanza, se rechaza
    -- (decisión del dueño, 05/11), como en la nota por lote. Se clampeaba a 0
    -- en silencio y el ledger decía otra cosa que la nota.
    SELECT string_agg(format('%s (hay %s y se devuelven %s)', l.nombre, COALESCE(l.stock, 0), l.cantidad),
                      '; ' ORDER BY l.producto_id)
      INTO v_mal
      FROM jsonb_to_recordset(v_lineas) AS l(producto_id BIGINT, cantidad INTEGER, stock INTEGER, nombre TEXT)
     WHERE COALESCE(l.stock, 0) < l.cantidad;
    IF v_mal IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error',
        'No alcanza el stock para devolver: ' || v_mal || '. La nota no se registró.');
    END IF;

    SELECT COALESCE(sum(l.subtotal), 0), COALESCE(sum(l.iva), 0)
      INTO v_subtotal, v_iva
      FROM jsonb_to_recordset(v_lineas) AS l(subtotal NUMERIC, iva NUMERIC);

    SELECT string_agg(format('%s (la pantalla dice %s y la factura da %s)', l.nombre,
                             COALESCE(round(l.sub_front, 2)::TEXT, 'nada'), l.subtotal),
                      '; ' ORDER BY l.producto_id)
      INTO v_mal
      FROM jsonb_to_recordset(v_lineas) AS l(producto_id BIGINT, nombre TEXT, sub_front NUMERIC, subtotal NUMERIC)
     WHERE l.sub_front IS NULL OR abs(l.sub_front - l.subtotal) > 0.05;
    IF v_mal IS NULL AND (abs(COALESCE(p_subtotal, 0) - v_subtotal) > 1 OR abs(COALESCE(p_iva, 0) - v_iva) > 1) THEN
      v_mal := format('subtotal %s e IVA %s, y la factura da %s y %s',
                      round(COALESCE(p_subtotal, 0), 2), round(COALESCE(p_iva, 0), 2), v_subtotal, v_iva);
    END IF;
    IF v_mal IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error',
        'El importe de la nota no coincide con el costo neto de la factura (con su bonificación): ' || v_mal ||
        '. Recargá la aplicación y volvé a cargarla.');
    END IF;

    v_ii    := public.ii_nota_credito_compra(p_compra_id, v_sucursal, v_items);
    v_total := v_subtotal + v_iva + v_ii;
  END IF;

  -- `fecha` en hora argentina (como registrar_nota_credito_lote): decide el
  -- periodo de posicion_fiscal y del gerencial.
  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id,
                             impuestos_internos, tipo)
  VALUES (p_compra_id, p_numero_nota, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
          v_subtotal, v_iva, v_total, p_motivo, auth.uid(), v_sucursal,
          v_ii, v_tipo)
  RETURNING id INTO v_nota_id;

  IF v_tipo = 'devolucion' THEN
    -- #1043: la devolución baja stock etiquetada para el ledger; la referencia es
    -- la nota, como en registrar_nota_credito_lote. Antes entraba como 'auto'.
    PERFORM set_config('app.stock_origen',   'nota_credito',   true);
    PERFORM set_config('app.stock_ref_tipo', 'notas_credito',  true);
    PERFORM set_config('app.stock_ref_id',   v_nota_id::text,  true);
    PERFORM set_config('app.stock_user_id',  auth.uid()::text, true);

    -- #1471: los lotes de la compra, después de los productos y por id.
    PERFORM 1 FROM producto_lotes
     WHERE compra_id = p_compra_id
       AND sucursal_id = v_sucursal
       AND producto_id IN (SELECT l.producto_id FROM jsonb_to_recordset(v_lineas) AS l(producto_id BIGINT))
     ORDER BY id
       FOR UPDATE;

    -- #1471: un item por producto, con lo que calculó la base, en orden de id.
    FOR v_linea IN
      SELECT * FROM jsonb_to_recordset(v_lineas)
               AS l(producto_id BIGINT, cantidad INTEGER, stock INTEGER, costo NUMERIC, subtotal NUMERIC)
       ORDER BY l.producto_id
    LOOP
      INSERT INTO nota_credito_items (nota_credito_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, sucursal_id)
      VALUES (v_nota_id, v_linea.producto_id, v_linea.cantidad, round(v_linea.costo, 4), v_linea.subtotal,
              v_linea.stock, v_linea.stock - v_linea.cantidad, v_sucursal);
      -- #1079: lo devuelto sale de los lotes de ESTA compra, el que vence antes
      -- primero, y ANTES del stock (como registrar_nota_credito_lote). Si no,
      -- el trigger come la bolsa y después FEFO global, y el lote de la compra
      -- sigue contando unidades que ya se devolvieron. Lo que a estos lotes no
      -- les alcance sale de la bolsa: con el lote ya descontado, el trigger ve la
      -- bolsa crecer en lo mismo y no toca otros lotes.
      v_de_lotes := v_linea.cantidad;
      FOR v_lote IN
        SELECT id, cantidad_restante
          FROM producto_lotes
         WHERE compra_id = p_compra_id
           AND producto_id = v_linea.producto_id
           AND sucursal_id = v_sucursal
           AND cantidad_restante > 0
         ORDER BY fecha_vencimiento, id
           FOR UPDATE
      LOOP
        EXIT WHEN v_de_lotes <= 0;
        v_toma := LEAST(v_de_lotes, v_lote.cantidad_restante);
        UPDATE producto_lotes SET cantidad_restante = cantidad_restante - v_toma WHERE id = v_lote.id;
        v_de_lotes := v_de_lotes - v_toma;
      END LOOP;

      UPDATE productos SET stock = stock - v_linea.cantidad WHERE id = v_linea.producto_id AND sucursal_id = v_sucursal;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'nota_credito_id', v_nota_id,
                            'tipo', v_tipo, 'impuestos_internos', v_ii, 'total', v_total,
                            'subtotal', v_subtotal, 'iva', v_iva);
END;
$function$;

-- ---------------------------------------------------------------------------
-- STK-F-1 y STK-F-3 · registrar_nota_credito_lote
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_nota_credito_lote(p_lote_id bigint, p_cantidad numeric, p_numero_nota text, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal   bigint := public.current_sucursal_id();
  v_rol        text;
  v_lote       record;
  v_cant       integer;
  v_stock      integer;
  v_costo      numeric;
  v_tasa_iva   numeric;
  v_subtotal   numeric;
  v_iva        numeric;
  v_comprado   integer;
  v_acreditado integer;
  v_nota_id    bigint;
  v_compra_id  bigint;  -- #1095
  v_ii         numeric;  -- mig 280
  v_producto_id bigint;  -- #1471
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- Mismo gate que dar_de_baja_lote: ver y sacar de circulacion son dos
  -- permisos distintos. Deposito mira lo que se le vence; administracion
  -- decide si se tira o se devuelve.
  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  -- numeric en la firma porque PostgREST manda los numeros de JSON sin tipo,
  -- pero las unidades son enteras: `nota_credito_items.cantidad` es integer y
  -- `producto_lotes.cantidad_restante` tambien. Redondear en silencio haria que
  -- el lote y la nota digan cosas distintas.
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad a devolver tiene que ser mayor a 0';
  END IF;
  IF p_cantidad <> trunc(p_cantidad) THEN
    RAISE EXCEPTION 'La cantidad a devolver tiene que ser un numero entero de unidades: %', p_cantidad;
  END IF;
  v_cant := p_cantidad::integer;

  -- #1095: la compra del lote se toma FOR SHARE ANTES que el lote, el mismo
  -- primer paso que registrar_nota_credito y que anular_compra_atomica (que la
  -- toma FOR UPDATE). Así la nota y la anulación se serializan en la compra y
  -- ninguna anulación pasa con esta nota a medio registrar. El compra_id se lee
  -- sin lock y se vuelve a comparar abajo, con el lote ya tomado. Un lote
  -- manual o inexistente sigue de largo y cae en los errores de siempre.
  SELECT compra_id, producto_id INTO v_compra_id, v_producto_id
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal;
  IF v_compra_id IS NOT NULL THEN
    PERFORM 1 FROM public.compras
     WHERE id = v_compra_id AND sucursal_id = v_sucursal AND estado <> 'cancelada'
       FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'La compra % de este lote está cancelada: no se le puede generar una nota de crédito', v_compra_id;
    END IF;
  END IF;

  -- #1471 (STK-F-1): el producto antes que el lote, el orden de la venta
  -- (#1255, como dar_de_baja_lote y ajustar_lote), y las líneas de la compra
  -- entre los dos, como registrar_nota_credito y actualizar_compra_items. Se
  -- tomaba el lote primero, y contra una venta con la bolsa en 0 (que baja a
  -- ese lote con el producto ya tomado) daba 40P01. El lote se vuelve a leer
  -- abajo, ya bloqueado, y se compara contra lo leído sin lock.
  IF v_producto_id IS NOT NULL THEN
    PERFORM 1 FROM public.productos
     WHERE id = v_producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;
    IF v_compra_id IS NOT NULL THEN
      PERFORM 1 FROM public.compra_items
       WHERE compra_id = v_compra_id
         AND producto_id = v_producto_id
         AND sucursal_id = v_sucursal
       ORDER BY id
         FOR UPDATE;
    END IF;
  END IF;

  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;

  -- Un lote manual es stock que ya estaba cuando se prendio la feature: no
  -- nacio de una factura, asi que no hay proveedor a quien acreditarle ni costo
  -- de compra del cual sacar el importe. Inventar cualquiera de los dos seria
  -- peor que no poder hacerlo.
  IF v_lote.compra_id IS NULL THEN
    RAISE EXCEPTION 'Este lote no tiene compra de origen: no se le puede generar una nota de crédito, sólo dar de baja';
  END IF;

  IF v_cant > v_lote.cantidad_restante THEN
    RAISE EXCEPTION 'El lote tiene % unidades: no se pueden devolver %',
      v_lote.cantidad_restante, v_cant;
  END IF;

  -- #1095: que la compra no esté cancelada ya se chequeó arriba, con la
  -- compra tomada. Falta que el lote siga siendo de esa compra:
  -- cambiar_proveedor_compra reapunta los lotes al clon, y si lo hizo entre la
  -- lectura sin lock y el lock del lote, la nota iría contra la compra
  -- equivocada.
  IF v_lote.compra_id IS DISTINCT FROM v_compra_id
     OR v_lote.producto_id IS DISTINCT FROM v_producto_id THEN
    RAISE EXCEPTION 'El lote cambió de compra mientras se registraba la nota: reintentá';
  END IF;

  -- El FOR UPDATE sobre las lineas de la compra es lo que SERIALIZA contra la
  -- otra puerta: dos notas simultaneas sobre la misma compra -- una por lote y
  -- una por factura entera -- leerian el mismo "ya acreditado" y acreditarian
  -- el doble. Es el mismo candado que la mig 236 le puso a
  -- `registrar_nota_credito`, y por eso las dos puertas se ven entre si.
  PERFORM 1 FROM public.compra_items
   WHERE compra_id = v_lote.compra_id
     AND producto_id = v_lote.producto_id
     AND sucursal_id = v_sucursal
   ORDER BY id
     FOR UPDATE;

  -- El costo sale de la factura de origen, que es la misma lectura que hace
  -- `ModalNotaCredito` para una compra entera: el costo neto de la bonificacion
  -- (#1471), y el IVA por la alicuota que tenia CADA linea (mig 177),
  -- no un 21% fijo. Contra una factura mixta, acreditar 21% sobre una linea
  -- exenta inventa credito fiscal que el proveedor nunca facturo.
  --
  -- La misma factura puede traer el mismo producto en dos renglones con costos
  -- distintos, y `producto_lotes` habla de producto y fecha, no de renglon: no
  -- hay forma de saber de cual salio. El promedio ponderado de esos renglones
  -- es la respuesta honesta, y es la misma plata cuando hay un solo renglon
  -- (el caso normal). Los COALESCE espejan los defaults del front:
  -- `porcentaje_iva ?? 21` para las lineas previas a la mig 113.
  --
  -- #1471 (STK-F-3): el costo es el NETO, con la bonificación de cada renglón.
  -- Se tomaba `costo_unitario` bruto y un regalo al 100 % se acreditaba a precio
  -- lleno. La alícuota se pondera por el neto. Es la misma cuenta que
  -- registrar_nota_credito y que `notaCredito.ts`.
  SELECT SUM(ci.cantidad)::integer,
         SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100))
           / NULLIF(SUM(ci.cantidad), 0),
         COALESCE(
           SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)
               * CASE WHEN ci.condicion_iva = 'gravado'
                      THEN COALESCE(ci.porcentaje_iva, 21) ELSE 0 END)
             / NULLIF(SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)), 0),
           0)
    INTO v_comprado, v_costo, v_tasa_iva
    FROM public.compra_items ci
   WHERE ci.compra_id = v_lote.compra_id
     AND ci.producto_id = v_lote.producto_id
     AND ci.sucursal_id = v_sucursal;

  IF v_comprado IS NULL THEN
    RAISE EXCEPTION 'La compra % ya no tiene ninguna línea de este producto: no se puede resolver el costo de la nota de crédito',
      v_lote.compra_id;
  END IF;

  -- El tope de lo acreditable es el mismo que el de la factura entera: no se
  -- puede acreditar mas unidades de las que se compraron. Sin esto, acreditar
  -- la compra completa por un lado y el lote por el otro acreditaria el doble.
  -- (Desde #1079 la nota por factura entera tambien baja los lotes de la
  -- compra, pero solo lo que les queda vivo; lo demas sale de la bolsa. El
  -- tope que cierra la segunda vuelta sigue siendo este.)
  SELECT COALESCE(SUM(nci.cantidad), 0)::integer INTO v_acreditado
    FROM public.nota_credito_items nci
    JOIN public.notas_credito nc
      ON nc.id = nci.nota_credito_id AND nc.sucursal_id = nci.sucursal_id
   WHERE nc.compra_id = v_lote.compra_id
     AND nc.sucursal_id = v_sucursal
     AND nci.producto_id = v_lote.producto_id;

  IF v_cant > v_comprado - v_acreditado THEN
    RAISE EXCEPTION 'La compra trajo % unidades de este producto y ya se acreditaron %: no se pueden acreditar %',
      v_comprado, v_acreditado, v_cant;
  END IF;

  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_stock IS NULL THEN
    RAISE EXCEPTION 'El producto % no existe en esta sucursal', v_lote.producto_id;
  END IF;
  IF v_stock < v_cant THEN
    RAISE EXCEPTION 'El stock del producto es % y la devolución es de %: dejaría stock negativo',
      v_stock, v_cant;
  END IF;

  v_subtotal := round(v_cant * v_costo, 2);
  v_iva      := round(v_subtotal * v_tasa_iva / 100, 2);
  -- mig 280 (#867): el II de lo devuelto, con el mismo reparto que la nota
  -- por factura entera (ii_nota_credito_compra).
  v_ii       := public.ii_nota_credito_compra(v_lote.compra_id, v_sucursal,
                  jsonb_build_array(jsonb_build_object('producto_id', v_lote.producto_id, 'cantidad', v_cant)));

  -- `fecha` en hora argentina y no CURRENT_DATE: la base corre en UTC y despues
  -- de las 21:00 ART el default fecharia la nota al dia siguiente (mig 182). No
  -- se toca el default de la tabla ni la RPC de compras: fuera de alcance.
  INSERT INTO public.notas_credito (
    compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id,
    impuestos_internos, tipo
  ) VALUES (
    v_lote.compra_id,
    NULLIF(btrim(COALESCE(p_numero_nota, '')), ''),
    (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
    v_subtotal, v_iva, v_subtotal + v_iva + v_ii,
    COALESCE(NULLIF(btrim(COALESCE(p_motivo, '')), ''),
             'Devolución al proveedor del lote vencido el '
               || to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY')),
    auth.uid(), v_sucursal,
    v_ii, 'devolucion'
  )
  RETURNING id INTO v_nota_id;

  INSERT INTO public.nota_credito_items (
    nota_credito_id, producto_id, cantidad, costo_unitario, subtotal,
    stock_anterior, stock_nuevo, sucursal_id
  ) VALUES (
    v_nota_id, v_lote.producto_id, v_cant, round(v_costo, 4), v_subtotal,
    v_stock, GREATEST(v_stock - v_cant, 0), v_sucursal
  );

  -- 1) el lote. ANTES del stock: ver el encabezado.
  UPDATE public.producto_lotes
     SET cantidad_restante = cantidad_restante - v_cant
   WHERE id = p_lote_id;

  -- 2) el stock, etiquetado para el ledger. La referencia apunta a la NOTA y no
  --    al lote: la nota es el comprobante, y desde ella se llega al lote por la
  --    compra. `registrar_nota_credito` no etiqueta nada y sus bajas entran como
  --    'auto'; esta puerta no repite ese hueco.
  PERFORM set_config('app.stock_origen',   'lote_devuelto_proveedor', true);
  PERFORM set_config('app.stock_ref_tipo', 'notas_credito',           true);
  PERFORM set_config('app.stock_ref_id',   v_nota_id::text,           true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text,          true);

  UPDATE public.productos
     SET stock = stock - v_cant,
         updated_at = now()
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'ok',                true,
    'lote_id',           p_lote_id,
    'nota_credito_id',   v_nota_id,
    'compra_id',         v_lote.compra_id,
    'cantidad',          v_cant,
    'cantidad_restante', v_lote.cantidad_restante - v_cant,
    'stock',             v_stock - v_cant,
    'costo_unitario',    round(v_costo, 2),
    'subtotal',          v_subtotal,
    'iva',               v_iva,
    'impuestos_internos', v_ii,
    'total',             v_subtotal + v_iva + v_ii
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- STK-F-6 · CHECK productos.stock >= 0
-- ---------------------------------------------------------------------------
DO $negativos$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM public.productos WHERE stock < 0;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig 466 · hay % producto(s) con stock negativo: corregirlos antes de agregar el CHECK', v_n;
  END IF;
END
$negativos$;

-- La caja de un súper puede necesitar stock negativo (trampa del fork, 28/10): si el fork lo
-- decide, este CHECK se revisa ahí.
ALTER TABLE public.productos
  ADD CONSTRAINT productos_stock_no_negativo CHECK (stock >= 0);

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, los EXECUTE y el CHECK quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM (VALUES
        ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
         '12229451da5e6757989fe45fced807c0', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.registrar_nota_credito_lote(bigint,numeric,text,text)',
         'acb406821131fdb5626af12580e8ed8d', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
         'c72091f49e66a89ce413661e4c30c46e', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.crear_movimiento_sucursal(bigint,text,jsonb)',
         'a463d2a9c6debc35dca8a3e971921491', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.editar_movimiento_sucursal(bigint,text,jsonb)',
         '16914ee1b3026d940a8a45428604668a', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
      ) AS t(firma, hash, acl)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR NOT r.def THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.productos'::regclass AND conname = 'productos_stock_no_negativo'
                    AND contype = 'c' AND convalidated) THEN
    RAISE EXCEPTION 'productos_stock_no_negativo no quedó creado y validado';
  END IF;
END
$post$;

COMMIT;
