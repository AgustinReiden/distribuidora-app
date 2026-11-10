-- 482 · Compras: la edición toma la compra primero, no se cruza con una nota de crédito, saca de
-- sus propios lotes lo que corrige a la baja, y el server valida el subtotal de cada renglón
-- (#1516: STK-2, STK-3, STK-6, STK-7, STK-9 y PAT-13-1). Tarjeta 4 de #1524.
--
-- QUÉ PASABA
--   · STK-2 (media). Bajar la cantidad de una compra con vencimientos la descontaba dos veces del
--     lote. actualizar_compra_items baja el stock ('compra_editada') y trg_lotes_sincronizar come la
--     bolsa y, si no alcanza, consume FEFO. Después la app llama a sincronizar_lotes_compra, que
--     conserva lo consumido de cada lote (cantidad − restante) y contaba como consumido lo que el
--     trigger acababa de sacar. Una compra de 100 con su lote de 100 y la bolsa en 0, corregida a
--     80, dejaba el lote en 60/80 y la bolsa en 20. Y si el lote que vence primero era de otra
--     compra, la bajada le comía a ése.
--   · STK-3 (media). Una compra con notas de crédito se podía editar sin tope: anular_compra_atomica
--     y cambiar_proveedor_compra la rechazan (#1095), la edición no. Corregir a 70 una compra de 100
--     con una nota de 30 descontaba la devolución dos veces; corregirla a 20 dejaba acreditado más
--     de lo comprado.
--   · STK-6. actualizar_compra_items no tomaba la compra primero: tomaba los productos y recién al
--     final la compra (el UPDATE de los totales). Contra la anulación, el cambio de proveedor,
--     sincronizar_lotes_compra o una nota (que ya tenían la compra y pedían un producto) era un
--     40P01. Y leía el estado sin esperar a una anulación en vuelo: podía editar una compra que se
--     acababa de anular.
--   · STK-7. sincronizar_lotes_compra no validaba los lotes contra la compra: un producto que no está
--     en la factura o más unidades de las compradas entraban; sólo los frenaba el front.
--   · STK-9. El server no validaba el subtotal de cada renglón. #1077 compara la cabecera con la suma
--     de los renglones, pero los dos números los manda el cliente. Hay 19 renglones de febrero a abril
--     de 2026 que no cierran por más de 1 peso (y 22 más por más de 0,01); desde el 16/04, ninguno.
--   · PAT-13-1. sincronizar_lotes_compra bloqueaba salvedades_items y producto_lotes sin ORDER BY id.
--
-- QUÉ CAMBIA
--   · actualizar_compra_items:
--     - toma la compra FOR UPDATE como primer lock, el mismo primer paso que la anulación, el cambio
--       de proveedor, sincronizar_lotes_compra y (FOR SHARE) las dos notas;
--     - rechaza una compra con notas de crédito, con el mismo conteo que anular_compra_atomica;
--     - rechaza un renglón cuyo subtotal no es cantidad × costo × (1 − bonificación/100), con
--       tolerancia 0,01 (el front manda floats sin redondear), después del control de #1077;
--     - antes de bajar el stock, lo que la bolsa no cubre lo saca de los lotes de ESTA compra, en
--       cantidad y en restante a la vez (el lote era más chico: no se vendió nada). Con eso el trigger
--       no consume ningún lote y sincronizar_lotes_compra deja cada lote en lo que manda la app menos
--       lo que de verdad salió: 100 corregida a 80 queda en 80/80 y bolsa 0. Los lotes se toman por
--       id después de los productos (el orden de la venta, #1255).
--   · sincronizar_lotes_compra: cada producto de los lotes tiene que estar en la compra y sus
--     vencimientos no pueden sumar más que lo comprado; y las dos tomas de locks van ORDER BY id.
--   · registrar_compra_completa: el mismo control de subtotal por renglón, después de los rangos de
--     #1471 (así la cantidad, el costo y la bonificación ya son números).
--
-- QUÉ NO CAMBIA
--   Las firmas, los EXECUTE, el SECURITY DEFINER, el costo promedio (_cpp_foto_compra,
--   _cpp_arrastrar y _cpp_linea son de la tarjeta 5), las etiquetas del ledger, los cargos, el
--   control de #1077 y todo lo demás de las tres funciones. Los renglones históricos que no cierran
--   no se tocan: el control rige el alta y la edición.
--
-- Ensayo: scripts/test-compras-edicion-lotes-1516.sql (una sesión, BEGIN … ROLLBACK) y el grupo b4
-- del arnés de concurrencia (scripts/concurrencia/), que mide la edición contra una nota, contra la
-- anulación y contra sincronizar_lotes_compra. Se aplica en LF, con parches por ancla sobre el cuerpo
-- vivo y premisa de md5.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos (leídos de prod el 10/11)
-- ---------------------------------------------------------------------------
DO $premisas$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid =
        'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure)
     <> '261d21ae4b6a5716ab7d0769b89483c9' THEN
    RAISE EXCEPTION 'mig 482 · actualizar_compra_items cambió en prod desde que se leyó: rehacer sobre la definición vigente';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid =
        'public.sincronizar_lotes_compra(bigint,jsonb)'::regprocedure)
     <> '0efb613f4d23d0804aa35d7b8ac942e4' THEN
    RAISE EXCEPTION 'mig 482 · sincronizar_lotes_compra cambió en prod desde que se leyó: rehacer sobre la definición vigente';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid =
        'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure)
     <> 'c72091f49e66a89ce413661e4c30c46e' THEN
    RAISE EXCEPTION 'mig 482 · registrar_compra_completa cambió en prod desde que se leyó: rehacer sobre la definición vigente';
  END IF;
END
$premisas$;

-- Reemplaza un ancla que tiene que aparecer exactamente una vez.
CREATE FUNCTION pg_temp.mig482_ancla(p_def text, p_ancla text, p_nuevo text, p_donde text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 482 · %: el ancla aparece % vez/veces y se esperaba 1', p_donde, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- ---------------------------------------------------------------------------
-- actualizar_compra_items
-- ---------------------------------------------------------------------------
DO $parche_edicion$
DECLARE
  v_def text := pg_get_functiondef(
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure);
BEGIN
  v_def := pg_temp.mig482_ancla(v_def,
$a$  v_warnings_repos   JSONB := '[]'::JSONB;
BEGIN
$a$,
$r$  v_warnings_repos   JSONB := '[]'::JSONB;
  -- mig 482 (#1516)
  v_nc_count         INTEGER;   -- STK-3
  v_subtotal_mal     TEXT;      -- STK-9
  v_baja             RECORD;    -- STK-2
  v_lote             RECORD;
  v_bolsa            INTEGER;
  v_falta            INTEGER;
  v_t                INTEGER;
  v_pasada           INTEGER;
BEGIN
$r$, 'actualizar_compra_items · declare');

  v_def := pg_temp.mig482_ancla(v_def,
$a$  SELECT id, estado, tipo_factura, created_at, fecha_compra, impuestos_internos, ii_declarado /* mig 194 */,
         letra_comprobante /* mig 293 */
    INTO v_compra
    FROM compras
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
$a$,
$r$  /* mig 482 (STK-6, #1516) · LA COMPRA PRIMERO, FOR UPDATE. Es el primer lock de
     anular_compra_atomica, de cambiar_proveedor_compra, de sincronizar_lotes_compra
     y (FOR SHARE) de las dos notas de credito. Sin el, la edicion tomaba los
     productos y recien al final la compra (el UPDATE de los totales): contra
     cualquiera de esos, que ya tenia la compra y pedia un producto, 40P01. Y leia
     el estado sin esperar a una anulacion en vuelo, asi que podia editar una
     compra que se acababa de anular: ahora la espera y la ve cancelada. */
  SELECT id, estado, tipo_factura, created_at, fecha_compra, impuestos_internos, ii_declarado /* mig 194 */,
         letra_comprobante /* mig 293 */
    INTO v_compra
    FROM compras
   WHERE id = p_compra_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF NOT FOUND THEN
$r$, 'actualizar_compra_items · la compra primero');

  v_def := pg_temp.mig482_ancla(v_def,
$a$      'No se puede editar una compra creada hace mas de 7 dias');
  END IF;
$a$,
$r$      'No se puede editar una compra creada hace mas de 7 dias');
  END IF;

  /* mig 482 (STK-3, #1516) · UNA COMPRA CON NOTAS DE CREDITO NO SE EDITA, como no
     se anula ni se le cambia el proveedor (#1095). Lo acreditado ya bajo el stock
     y los lotes de la compra (#1079), y la edicion lo volvia a restar: corregir a
     70 una compra de 100 con una nota de 30 descontaba la devolucion dos veces, y
     corregirla a 20 dejaba acreditado mas de lo comprado. Mismo conteo que
     anular_compra_atomica. La compra esta tomada FOR UPDATE arriba y las dos
     notas la toman FOR SHARE como primer paso: este conteo ve toda nota
     confirmada antes, y ninguna nota entra hasta que la edicion termine. */
  SELECT count(*) INTO v_nc_count
    FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;
  IF v_nc_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('La compra tiene %s nota(s) de crédito: no se puede editar. Una diferencia que quede se corrige con otra nota de crédito.',
             v_nc_count));
  END IF;
$r$, 'actualizar_compra_items · notas de credito');

  v_def := pg_temp.mig482_ancla(v_def,
$a$             COALESCE(round(p_subtotal, 2)::TEXT, 'sin informar'), v_suma_items));
  END IF;

  v_es_zz := (v_compra.tipo_factura = 'ZZ');
$a$,
$r$             COALESCE(round(p_subtotal, 2)::TEXT, 'sin informar'), v_suma_items));
  END IF;

  /* mig 482 (STK-9, #1516) · EL SUBTOTAL DE CADA RENGLON ES LA CANTIDAD POR EL
     COSTO CON SU BONIFICACION. #1077 compara la cabecera con la suma de los
     renglones, pero los dos numeros los manda el cliente: un renglon mal calculado
     entraba igual (hay 19 de febrero a abril de 2026 que no cierran por mas de 1
     peso). Tolerancia 0,01: el front manda floats sin redondear y los dos lados se
     redondean a 2 decimales; desde el 16/04 ningun renglon se va de eso. Mismo
     control que registrar_compra_completa. */
  SELECT string_agg(format('%s (renglón %s): dice %s y la cantidad por el costo con su bonificación da %s',
                           COALESCE(pr.nombre, 'producto ' || COALESCE(r.val->>'producto_id', '?')),
                           r.n, r.dice, r.da), '; ' ORDER BY r.n)
    INTO v_subtotal_mal
    FROM (
      SELECT e.val, e.n,
             round(COALESCE((e.val->>'subtotal')::NUMERIC, 0), 2) AS dice,
             round((e.val->>'cantidad')::NUMERIC * COALESCE((e.val->>'costo_unitario')::NUMERIC, 0)
                   * (1 - COALESCE((e.val->>'bonificacion')::NUMERIC, 0) / 100), 2) AS da
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items_nuevos) = 'array'
                                       THEN p_items_nuevos ELSE '[]'::JSONB END) WITH ORDINALITY AS e(val, n)
    ) r
    LEFT JOIN productos pr
      ON pr.id = CASE WHEN COALESCE(r.val->>'producto_id', '') ~ '^\s*[0-9]+\s*$'
                      THEN (r.val->>'producto_id')::BIGINT END
     AND pr.sucursal_id = v_sucursal
   WHERE abs(r.dice - r.da) > 0.01;
  IF v_subtotal_mal IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay renglones con el subtotal mal calculado: ' || v_subtotal_mal
      || '. Revisá los renglones; si sigue igual, recargá la aplicación y volvé a guardarla.');
  END IF;

  v_es_zz := (v_compra.tipo_factura = 'ZZ');
$r$, 'actualizar_compra_items · subtotal por renglon');

  v_def := pg_temp.mig482_ancla(v_def,
$a$  v_tipo_producto := _tipo_compra_producto(v_compra.tipo_factura, v_compra.letra_comprobante);  /* #1253 */
$a$,
$r$  v_tipo_producto := _tipo_compra_producto(v_compra.tipo_factura, v_compra.letra_comprobante);  /* #1253 */

  /* mig 482 (STK-2, #1516) · LO QUE LA EDICION LE SACA A UN PRODUCTO CON
     VENCIMIENTOS SALE DE LOS LOTES DE ESTA COMPRA, Y NO COMO CONSUMO.

     La bajada de stock de abajo pasa por trg_lotes_sincronizar: come la bolsa y,
     si no alcanza, consume FEFO. Despues la app llama a sincronizar_lotes_compra,
     que conserva lo consumido de cada lote (cantidad - restante) y contaba como
     consumido lo que el trigger acababa de sacar: una compra de 100 con su lote
     de 100 y la bolsa en 0, corregida a 80, dejaba el lote en 60/80 y la bolsa en
     20. Y si el lote que vence primero era de otra compra, le comia a ese.

     Ahora, antes de bajar, lo que la bolsa no cubre se saca de los lotes de esta
     compra, en cantidad y en restante a la vez: el lote era mas chico, no se
     vendio nada. La bolsa alcanza, el trigger no consume ningun lote, y
     sincronizar_lotes_compra deja cada lote en lo que manda la app menos lo que
     de verdad salio: la compra de 100 corregida a 80 queda en 80/80 y bolsa 0.
     Lo que la bolsa si cubre no toca los lotes: sincronizar_lotes_compra los
     pone en lo que manda la app y la diferencia vuelve a la bolsa.

     Primero los que vencen ultimo. La cantidad de un lote no puede ser 0
     (producto_lotes_cantidad_check): la primera pasada deja al menos 1 en cada
     lote intacto, y solo si no alcanza la segunda saca esa unidad como
     consumida (el lote queda 1/0, y sincronizar_lotes_compra lo borra o lo deja
     para la traza si la app ya no lo manda). Si los lotes de la compra no
     alcanzan (ya se vendio de ellos), lo que falta lo baja el trigger como
     siempre. Los productos ya estan tomados arriba, por id; los lotes van
     despues, por id: el orden de la venta (#1255). */
  PERFORM 1 FROM producto_lotes
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
   ORDER BY id
     FOR UPDATE;

  FOR v_baja IN
    WITH viejos AS (
      SELECT producto_id, SUM(cantidad)::INT AS qty_old
        FROM compra_items
       WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       GROUP BY producto_id
    ),
    nuevos AS (
      SELECT (item->>'producto_id')::BIGINT AS producto_id,
             SUM((item->>'cantidad')::INT)::INT AS qty_new
        FROM jsonb_array_elements(p_items_nuevos) AS item
       GROUP BY (item->>'producto_id')::BIGINT
    )
    SELECT v.producto_id, v.qty_old - COALESCE(n.qty_new, 0) AS unidades
      FROM viejos v LEFT JOIN nuevos n USING (producto_id)
     WHERE v.qty_old > COALESCE(n.qty_new, 0)
       AND EXISTS (SELECT 1 FROM producto_lotes l
                    WHERE l.compra_id = p_compra_id AND l.sucursal_id = v_sucursal
                      AND l.producto_id = v.producto_id AND l.cantidad_restante > 0)
     ORDER BY v.producto_id
  LOOP
    SELECT p.stock - COALESCE((SELECT SUM(l.cantidad_restante) FROM producto_lotes l
                                WHERE l.producto_id = p.id AND l.sucursal_id = v_sucursal), 0)
      INTO v_bolsa
      FROM productos p
     WHERE p.id = v_baja.producto_id AND p.sucursal_id = v_sucursal;
    v_falta := v_baja.unidades - GREATEST(COALESCE(v_bolsa, 0), 0);

    FOR v_pasada IN 1..2 LOOP
      EXIT WHEN v_falta <= 0;
      FOR v_lote IN
        SELECT id, cantidad, cantidad_restante
          FROM producto_lotes
         WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
           AND producto_id = v_baja.producto_id
           AND cantidad_restante > 0
         ORDER BY fecha_vencimiento DESC, id DESC
      LOOP
        v_t := LEAST(v_falta, v_lote.cantidad_restante
                     - CASE WHEN v_pasada = 1 AND v_lote.cantidad = v_lote.cantidad_restante THEN 1 ELSE 0 END);
        CONTINUE WHEN v_t <= 0;
        UPDATE producto_lotes
           SET cantidad          = GREATEST(cantidad - v_t, 1),
               cantidad_restante = cantidad_restante - v_t
         WHERE id = v_lote.id;
        v_falta := v_falta - v_t;
        EXIT WHEN v_falta <= 0;
      END LOOP;
    END LOOP;
  END LOOP;
$r$, 'actualizar_compra_items · la baja sale de los lotes de la compra');

  EXECUTE v_def;
END
$parche_edicion$;

-- ---------------------------------------------------------------------------
-- sincronizar_lotes_compra
-- ---------------------------------------------------------------------------
DO $parche_lotes$
DECLARE
  v_def text := pg_get_functiondef('public.sincronizar_lotes_compra(bigint,jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.mig482_ancla(v_def,
$a$  v_prod      bigint;
  r           record;
$a$,
$r$  v_prod      bigint;
  r           record;
  -- mig 482 (STK-7, #1516)
  v_en_lotes  integer;
  v_comprado  integer;
$r$, 'sincronizar_lotes_compra · declare');

  v_def := pg_temp.mig482_ancla(v_def,
$a$      RAISE EXCEPTION 'El producto % no existe en esta sucursal', v_prod;
    END IF;
  END LOOP;
$a$,
$r$      RAISE EXCEPTION 'El producto % no existe en esta sucursal', v_prod;
    END IF;
  END LOOP;

  -- mig 482 (STK-7, #1516): los vencimientos son de las unidades de ESTA factura.
  -- Cada producto de los lotes tiene que estar en la compra, y sus vencimientos
  -- no pueden sumar mas que lo comprado. Hasta aca solo lo frenaba el front. Las
  -- lineas se leen con la compra ya tomada: si una edicion las esta cambiando,
  -- se espera a que termine y se ven las nuevas.
  SELECT n.producto_id, n.cantidad, COALESCE(c.cantidad, 0)
    INTO v_prod, v_en_lotes, v_comprado
    FROM (SELECT (e->>'producto_id')::bigint AS producto_id,
                 SUM((e->>'cantidad')::integer)::integer AS cantidad
            FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::jsonb)) e
           GROUP BY 1) n
    LEFT JOIN (SELECT producto_id, SUM(cantidad)::integer AS cantidad
                 FROM public.compra_items
                WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
                GROUP BY 1) c ON c.producto_id = n.producto_id
   WHERE n.cantidad > COALESCE(c.cantidad, 0)
   ORDER BY n.producto_id
   LIMIT 1;
  IF FOUND THEN
    IF v_comprado = 0 THEN
      RAISE EXCEPTION 'El producto % no está en la compra %: sus vencimientos van con la compra que lo trajo',
        COALESCE((SELECT nombre FROM public.productos WHERE id = v_prod), v_prod::text), p_compra_id;
    END IF;
    RAISE EXCEPTION 'Los vencimientos de % suman % u. y la compra % trae %',
      COALESCE((SELECT nombre FROM public.productos WHERE id = v_prod), v_prod::text),
      v_en_lotes, p_compra_id, v_comprado;
  END IF;
$r$, 'sincronizar_lotes_compra · lotes contra la compra');

  v_def := pg_temp.mig482_ancla(v_def,
$a$         WHERE l.compra_id = p_compra_id)
      FOR UPDATE OF s;
$a$,
$r$         WHERE l.compra_id = p_compra_id)
    ORDER BY s.id   -- mig 482 (PAT-13-1, #1516): por id, como todo lock de varias filas
      FOR UPDATE OF s;
$r$, 'sincronizar_lotes_compra · salvedades por id');

  v_def := pg_temp.mig482_ancla(v_def,
$a$  PERFORM 1 FROM public.producto_lotes
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     FOR UPDATE;
$a$,
$r$  PERFORM 1 FROM public.producto_lotes
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
   ORDER BY id   -- mig 482 (PAT-13-1, #1516)
     FOR UPDATE;
$r$, 'sincronizar_lotes_compra · lotes por id');

  EXECUTE v_def;
END
$parche_lotes$;

-- ---------------------------------------------------------------------------
-- registrar_compra_completa
-- ---------------------------------------------------------------------------
DO $parche_alta$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure);
BEGIN
  v_def := pg_temp.mig482_ancla(v_def,
$a$  v_fuera_de_rango      TEXT;      -- #1471
$a$,
$r$  v_fuera_de_rango      TEXT;      -- #1471
  v_subtotal_mal        TEXT;      -- mig 482 (STK-9, #1516)
$r$, 'registrar_compra_completa · declare');

  v_def := pg_temp.mig482_ancla(v_def,
$a$      'Hay renglones fuera de rango: ' || v_fuera_de_rango || '.');
  END IF;
$a$,
$r$      'Hay renglones fuera de rango: ' || v_fuera_de_rango || '.');
  END IF;

  /* mig 482 (STK-9, #1516) · EL SUBTOTAL DE CADA RENGLON ES LA CANTIDAD POR EL
     COSTO CON SU BONIFICACION. #1077 compara la cabecera con la suma de los
     renglones, pero los dos numeros los manda el cliente: un renglon mal calculado
     entraba igual (hay 19 de febrero a abril de 2026 que no cierran por mas de 1
     peso). Tolerancia 0,01: el front manda floats sin redondear y los dos lados se
     redondean a 2 decimales; desde el 16/04 ningun renglon se va de eso. Va
     despues de los rangos: la cantidad, el costo y la bonificacion ya son
     numeros. Mismo control que actualizar_compra_items. */
  SELECT string_agg(format('%s (renglón %s): dice %s y la cantidad por el costo con su bonificación da %s',
                           COALESCE(pr.nombre, 'producto ' || COALESCE(r.val->>'producto_id', '?')),
                           r.n, r.dice, r.da), '; ' ORDER BY r.n)
    INTO v_subtotal_mal
    FROM (
      SELECT e.val, e.n,
             round(COALESCE((e.val->>'subtotal')::NUMERIC, 0), 2) AS dice,
             round((e.val->>'cantidad')::NUMERIC * COALESCE((e.val->>'costo_unitario')::NUMERIC, 0)
                   * (1 - COALESCE((e.val->>'bonificacion')::NUMERIC, 0) / 100), 2) AS da
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                       THEN p_items ELSE '[]'::JSONB END) WITH ORDINALITY AS e(val, n)
    ) r
    LEFT JOIN productos pr
      ON pr.id = CASE WHEN COALESCE(r.val->>'producto_id', '') ~ '^\s*[0-9]+\s*$'
                      THEN (r.val->>'producto_id')::BIGINT END
     AND pr.sucursal_id = v_sucursal
   WHERE abs(r.dice - r.da) > 0.01;
  IF v_subtotal_mal IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay renglones con el subtotal mal calculado: ' || v_subtotal_mal
      || '. Revisá los renglones; si sigue igual, recargá la aplicación y volvé a cargarla.');
  END IF;
$r$, 'registrar_compra_completa · subtotal por renglon');

  EXECUTE v_def;
END
$parche_alta$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS f, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def,
           CASE p.proname
             WHEN 'actualizar_compra_items'   THEN '6d445a93278099e89c2724397e7daa80'
             WHEN 'sincronizar_lotes_compra'  THEN '426eb0b3e2e4997d277eb67af4546eaf'
             WHEN 'registrar_compra_completa' THEN '6f7a9484ede576f24e7650fe45921ff0'
           END AS esperado
      FROM pg_proc p
     WHERE p.oid IN (
       'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
       'public.sincronizar_lotes_compra(bigint,jsonb)'::regprocedure,
       'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure)
  LOOP
    IF r.h <> r.esperado
       OR r.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
       OR NOT r.def THEN
      RAISE EXCEPTION 'mig 482 · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, r.h, r.a, r.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
