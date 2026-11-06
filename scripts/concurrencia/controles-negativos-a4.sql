-- Controles negativos de la tarjeta 4 de #1477 (#1471, STK-F-1 y STK-F-2). Se corren sobre la copia LOCAL de Docker con
-- la migración de la tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
-- Vuelve a poner los DOS cuerpos que tenía prod antes de la migración (copiados literal del ledger), cada uno con su
-- orden de locks de antes. Cada variante de `a4` cruza una sola función contra la venta, así que no se pisan:
--   · registrar_nota_credito_lote: compra (FOR SHARE) → LOTE FOR UPDATE → líneas de la compra → producto. Contra una
--     venta con la bolsa de A en 0 (que baja a ese lote con el producto ya tomado), A4a vuelve a dar 40P01.
--   · registrar_nota_credito: toma los productos de a uno, en el orden del JSON y después de las líneas de la compra
--     (y no recalcula los importes ni rechaza el stock corto: el mismo payload de A4b sirve para los dos cuerpos).
--     Con items [B, A] contra una venta [A, B], A4b vuelve a dar 40P01.
--
--   psql -f controles-negativos-a4.sql   (o docker-local.mjs aplicar scripts/concurrencia/controles-negativos-a4.sql)
--   node run.mjs a4 --out <dir>   (otra carpeta que la de la corrida limpia)
--   RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: igual que antes de mutar (la base tiene la migración de
--   la tarjeta, así que se compara contra la huella de antes de la mutación y no contra la de prod).

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('registrar_nota_credito', 'registrar_nota_credito_lote')
ON CONFLICT DO NOTHING;

-- Cuerpo de prod de registrar_nota_credito (antes de la migración).
CREATE OR REPLACE FUNCTION public.registrar_nota_credito(p_compra_id bigint, p_numero_nota character varying DEFAULT NULL::character varying, p_motivo text DEFAULT NULL::text, p_subtotal numeric DEFAULT 0, p_iva numeric DEFAULT 0, p_total numeric DEFAULT 0, p_usuario_id uuid DEFAULT NULL::uuid, p_items jsonb DEFAULT '[]'::jsonb, p_impuestos_internos numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_nota_id BIGINT; v_item JSONB; v_stock_actual INTEGER;
  v_producto_id BIGINT; v_cantidad INTEGER; v_costo DECIMAL; v_sub DECIMAL;
  v_exceso TEXT;  -- mig 236
  v_tipo TEXT; v_ii NUMERIC; v_total NUMERIC;  -- mig 280
  v_de_lotes INTEGER; v_toma INTEGER; v_lote RECORD;  -- #1079
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
                FROM jsonb_array_elements(p_items) i
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
     devolucion (baja stock y acredita el II de esas lineas, calculado aca);
     sin items es un ajuste sobre la factura —descuento, diferencia de precio,
     II mal liquidado— y no toca stock, costos ni fichas. El II del ajuste lo
     declara quien lo carga, porque no hay lineas de donde sacarlo.

     En la devolucion el total del caller se respeta salvo el II, que se
     recalcula: total = p_total − p_impuestos_internos + II calculado. Un front
     que no manda II (el anterior a esta migracion) queda igual de bien. */
  v_tipo := CASE WHEN jsonb_array_length(COALESCE(p_items, '[]'::jsonb)) > 0
                 THEN 'devolucion' ELSE 'ajuste' END;

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
    v_ii    := round(COALESCE(p_impuestos_internos, 0), 2);
    v_total := p_total;
  ELSE
    v_ii    := public.ii_nota_credito_compra(p_compra_id, v_sucursal, p_items);
    v_total := COALESCE(p_total, 0) - COALESCE(p_impuestos_internos, 0) + v_ii;
  END IF;

  -- `fecha` en hora argentina (como registrar_nota_credito_lote): decide el
  -- periodo de posicion_fiscal y del gerencial.
  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id,
                             impuestos_internos, tipo)
  VALUES (p_compra_id, p_numero_nota, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
          p_subtotal, p_iva, v_total, p_motivo, auth.uid(), v_sucursal,
          v_ii, v_tipo)
  RETURNING id INTO v_nota_id;

  -- #1043: la devolución baja stock etiquetada para el ledger; la referencia es
  -- la nota, como en registrar_nota_credito_lote. Antes entraba como 'auto'.
  PERFORM set_config('app.stock_origen',   'nota_credito',   true);
  PERFORM set_config('app.stock_ref_tipo', 'notas_credito',  true);
  PERFORM set_config('app.stock_ref_id',   v_nota_id::text,  true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text, true);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (v_item->>'producto_id')::BIGINT;
    v_cantidad := (v_item->>'cantidad')::INTEGER;
    v_costo := (v_item->>'costo_unitario')::DECIMAL;
    v_sub := (v_item->>'subtotal')::DECIMAL;
    SELECT stock INTO v_stock_actual FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN RAISE EXCEPTION 'Producto % no encontrado', v_producto_id; END IF;
    INSERT INTO nota_credito_items (nota_credito_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, sucursal_id)
    VALUES (v_nota_id, v_producto_id, v_cantidad, v_costo, v_sub, v_stock_actual, GREATEST(v_stock_actual - v_cantidad, 0), v_sucursal);
    -- #1079: lo devuelto sale de los lotes de ESTA compra, el que vence antes
    -- primero, y ANTES del stock (como registrar_nota_credito_lote). Si no,
    -- el trigger come la bolsa y después FEFO global, y el lote de la compra
    -- sigue contando unidades que ya se devolvieron. Hasta lo que de verdad
    -- baja el stock, que se clampea a 0. Lo que a estos lotes no les alcance
    -- sale de la bolsa: con el lote ya descontado, el trigger ve la bolsa
    -- crecer en lo mismo y no toca otros lotes.
    v_de_lotes := GREATEST(LEAST(v_cantidad, v_stock_actual), 0);
    FOR v_lote IN
      SELECT id, cantidad_restante
        FROM producto_lotes
       WHERE compra_id = p_compra_id
         AND producto_id = v_producto_id
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

    UPDATE productos SET stock = GREATEST(stock - v_cantidad, 0) WHERE id = v_producto_id AND sucursal_id = v_sucursal;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'nota_credito_id', v_nota_id,
                            'tipo', v_tipo, 'impuestos_internos', v_ii, 'total', v_total);
END;
$function$
;

-- Cuerpo de prod de registrar_nota_credito_lote (antes de la migración).
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
  SELECT compra_id INTO v_compra_id
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
  IF v_lote.compra_id IS DISTINCT FROM v_compra_id THEN
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
  -- `ModalNotaCredito` para una compra entera: `costo_unitario` bruto
  -- pre-bonificacion, y el IVA por la alicuota que tenia CADA linea (mig 177),
  -- no un 21% fijo. Contra una factura mixta, acreditar 21% sobre una linea
  -- exenta inventa credito fiscal que el proveedor nunca facturo.
  --
  -- La misma factura puede traer el mismo producto en dos renglones con costos
  -- distintos, y `producto_lotes` habla de producto y fecha, no de renglon: no
  -- hay forma de saber de cual salio. El promedio ponderado de esos renglones
  -- es la respuesta honesta, y es la misma plata cuando hay un solo renglon
  -- (el caso normal). Los COALESCE espejan los defaults del front:
  -- `porcentaje_iva ?? 21` para las lineas previas a la mig 113.
  SELECT SUM(ci.cantidad)::integer,
         SUM(ci.cantidad * ci.costo_unitario) / NULLIF(SUM(ci.cantidad), 0),
         SUM(ci.cantidad * ci.costo_unitario
             * CASE WHEN ci.condicion_iva = 'gravado'
                    THEN COALESCE(ci.porcentaje_iva, 21) ELSE 0 END)
           / NULLIF(SUM(ci.cantidad * ci.costo_unitario), 0)
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
    v_nota_id, v_lote.producto_id, v_cant, round(v_costo, 2), v_subtotal,
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
$function$
;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
