-- 464 · Venta: el mínimo por producto, el IVA de la foto en la edición y sin II en la posición
-- fiscal (#1470: VTA-F-1, VTA-F-4 de la edición y VTA-F-3). Tarjeta 3 de #1477.
--
-- QUÉ PASABA
--   · VTA-F-1. El mínimo de venta (productos.cantidad_minima_venta, mig 147) se medía por LÍNEA
--     en el server (validar_minimo_venta_item, BEFORE de fila) y por PRODUCTO en el front
--     (validarMOQPedido, sobre el carrito, antes de armar los combos). Un combo parte el producto
--     en dos líneas (la del combo y la suelta, #1191): con mínimo 6 y 8 en el carrito, de las que
--     el combo toma 2, el front dejaba pasar y el server rechazaba la línea de 2 con un
--     check_violation. Hoy hay 0 combos y 61 productos con mínimo.
--   · VTA-F-4. actualizar_pedido_items borra y reinserta las líneas, y el IVA de cada una salía
--     de la alícuota de HOY del producto. cambiar_tipo_factura_pedido y anular_salvedad usan la
--     foto de la línea (pedido_items.porcentaje_iva), como pide CLAUDE.md ("El IVA de una
--     venta"). Sin efecto hoy: los 355 productos son 21% gravado.
--   · VTA-F-3. posicion_fiscal devolvía ii_ventas_fc, y la pantalla mostraba siempre "II
--     contenido en FC: $0". Que dé 0 es correcto: la distribuidora no es sujeto de impuestos
--     internos, así que el impuesto es costo de compra y no se traslada en la venta (mig 122,
--     PR #424; calcular_desglose_venta ignora esa tasa a propósito).
--
-- QUÉ CAMBIA
--   · El mínimo es del producto en el pedido (decisión del dueño, 06/11): la suma de sus líneas
--     de venta, la del combo incluida, que es lo que ya prometía el front. Para sumar hay que
--     esperar a que estén todas, así que trg_validar_minimo_venta_item pasa a ser un constraint
--     trigger diferido (AFTER, de fila, DEFERRABLE INITIALLY DEFERRED), como
--     trg_limite_usos_promo: corre al confirmar, cuando el alta, la edición o la salvedad ya
--     escribieron todas las líneas. Un producto sin líneas de venta no tiene mínimo que cumplir.
--     El mensaje es el de siempre, con el total del producto ("se cargaron 5" son las 5 del
--     pedido, no las de una línea), y sigue siendo check_violation.
--     El escape app.omitir_minimo_venta (las salvedades, mig 174) se lee al confirmar: las
--     salvedades lo dejan prendido hasta el final de su transacción, así que no cambia nada.
--     crear_pedido_completo lo prendía sólo mientras insertaba las líneas de un vale blanco y lo
--     apagaba antes de terminar: al confirmar ya no está, así que el VB se reconoce por
--     pedidos.tipo_factura. Un vale blanco no tiene mínimo, tampoco al editarlo (decisión del
--     dueño, 06/11: es consumo interno). El front no edita un VB.
--     La función pasa a SECURITY DEFINER, como validar_limite_usos_promo: corre al confirmar,
--     fuera del RPC definer, como el usuario de la sesión, y una suma de líneas no puede depender
--     de qué columnas o qué filas le deja ver RLS. Sigue sin EXECUTE para la app: es de trigger.
--   · actualizar_pedido_items: una línea de venta que ya estaba en el pedido conserva su foto de
--     IVA. Antes del DELETE guarda la foto por producto + combo (la línea del combo y la suelta
--     son dos líneas, #1191), y la línea que vuelve con esa clave se desglosa con
--     COALESCE(NULLIF(foto, 0), alícuota de hoy): la regla de cambiar_tipo_factura_pedido (una
--     foto 0 es ambigua, miles de líneas anteriores a julio 2026 la tienen por default, y cae
--     al producto). Una línea nueva usa la de hoy, como siempre. El precio que se desglosa es el
--     del JSON, como siempre.
--   · posicion_fiscal: sale ii_ventas_fc (y su CTE v_fc). Nadie más la lee: ni otra función de
--     public ni el bot. La pantalla deja de mostrar la fila (mismo PR).
--
-- QUÉ NO CAMBIA
--   El resto de las dos funciones, las firmas, los EXECUTE, el resto de la posición fiscal, y la
--   misma parte de cambiar_cliente_pedido (tarjeta 6). crear_pedido_completo no se toca
--   (tarjeta 2): su escape del VB queda como está, y ya no hace falta.
--
-- Ensayo: scripts/test-venta-minimo-iva-1470.sql. Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos (06/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.validar_minimo_venta_item()',
         '4d09b7da586cba3229389f8e1ac085c9'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
         '3462f61e5646aaec6f4a041a7000dc0e'),
        ('public.posicion_fiscal(bigint,date,date)',
         '5f2101c16f4de105e888727f7b20e95f')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 464 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
       WHERE t.tgrelid = 'public.pedido_items'::regclass AND t.tgname = 'trg_validar_minimo_venta_item')
     IS DISTINCT FROM 'CREATE TRIGGER trg_validar_minimo_venta_item BEFORE INSERT OR UPDATE OF cantidad, producto_id, es_bonificacion ON public.pedido_items FOR EACH ROW EXECUTE FUNCTION validar_minimo_venta_item()' THEN
    RAISE EXCEPTION 'mig 464 · trg_validar_minimo_venta_item no es el BEFORE de fila que se leyó';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- VTA-F-1 · El mínimo de venta es del producto en el pedido
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_minimo_venta_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_nombre text;
  v_minimo integer;
  v_total  bigint;
BEGIN
  -- #1470: el mínimo es del PRODUCTO en el pedido, no de la línea (decisión del
  -- dueño, 06/11): la suma de sus líneas de venta, la de un combo incluida. Un
  -- combo parte el producto en la línea del combo y la suelta (#1191), y
  -- cualquiera de las dos puede quedar debajo del mínimo sin que el producto lo
  -- esté. Es lo que mide validarMOQPedido en el front. Por eso corre diferido,
  -- al confirmar: recién ahí están todas las líneas.

  -- Los RPCs de salvedad prenden este flag (local a la transaccion): lo que
  -- se entrega de menos no puede quedar trabado por el minimo de compra.
  IF COALESCE(current_setting('app.omitir_minimo_venta', true), '') = '1' THEN
    RETURN NULL;
  END IF;

  IF COALESCE(NEW.es_bonificacion, false) THEN
    RETURN NULL;
  END IF;

  SELECT nombre, cantidad_minima_venta INTO v_nombre, v_minimo
  FROM productos WHERE id = NEW.producto_id AND sucursal_id = NEW.sucursal_id;

  IF v_minimo IS NULL THEN
    RETURN NULL;
  END IF;

  -- Un vale blanco no tiene minimo de venta por producto (N6), ni en el alta ni
  -- en la edicion (decision del dueño, 06/11). crear_pedido_completo prende el
  -- flag de arriba solo mientras inserta las lineas de un VB y lo apaga antes
  -- de terminar: al confirmar ya no esta, y el VB se reconoce por el pedido.
  IF EXISTS (SELECT 1 FROM pedidos
              WHERE id = NEW.pedido_id AND sucursal_id = NEW.sucursal_id
                AND tipo_factura = 'VB') THEN
    RETURN NULL;
  END IF;

  -- La fila del trigger puede haberse borrado despues (la edicion borra y
  -- reinserta): se suma lo que hay al confirmar. Sin lineas de venta del
  -- producto no hay minimo que cumplir.
  SELECT COALESCE(SUM(pi.cantidad), 0) INTO v_total
    FROM pedido_items pi
   WHERE pi.pedido_id = NEW.pedido_id AND pi.sucursal_id = NEW.sucursal_id
     AND pi.producto_id = NEW.producto_id
     AND NOT COALESCE(pi.es_bonificacion, false);

  IF v_total > 0 AND v_total < v_minimo THEN
    RAISE EXCEPTION 'La compra mínima de "%" es % unidades (se cargaron %)',
      COALESCE(v_nombre, NEW.producto_id::text), v_minimo, v_total
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NULL;
END;
$function$;

-- Una función de trigger no necesita EXECUTE para nadie de la app (la invoca el executor). El
-- CREATE OR REPLACE conserva los grants; se repite el REVOKE para que quede escrito.
REVOKE EXECUTE ON FUNCTION public.validar_minimo_venta_item() FROM PUBLIC, anon, authenticated;

DROP TRIGGER trg_validar_minimo_venta_item ON public.pedido_items;
CREATE CONSTRAINT TRIGGER trg_validar_minimo_venta_item
  AFTER INSERT OR UPDATE OF cantidad, producto_id, es_bonificacion ON public.pedido_items
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (NOT COALESCE(new.es_bonificacion, false))
  EXECUTE FUNCTION public.validar_minimo_venta_item();

-- ---------------------------------------------------------------------------
-- VTA-F-4 y VTA-F-3 · Parches por ancla
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, veces int, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _n_parche VALUES
-- VTA-F-4: la variable de la foto.
('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 1, 1,
$a$  v_costo_promedio_actual DECIMAL;
$a$,
$r$  v_costo_promedio_actual DECIMAL;
  -- #1470: la foto de IVA de cada linea de venta que ya estaba, por
  -- "producto:combo".
  v_iva_fotos JSONB;
$r$),

-- VTA-F-4: la foto, antes del DELETE.
('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 2, 1,
$a$  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
$a$,
$r$  -- #1470 (VTA-F-4): la foto de IVA de cada linea de venta que ya estaba, antes
  -- de borrarlas. La clave es producto + combo: la linea del combo y la suelta
  -- del mismo producto son dos lineas (#1191). Con dos lineas de la misma clave,
  -- la mas vieja.
  SELECT COALESCE(jsonb_object_agg(x.clave, x.pct), '{}'::jsonb)
    INTO v_iva_fotos
    FROM (SELECT DISTINCT ON (pi.producto_id, pi.combo_id)
                 pi.producto_id || ':' || COALESCE(pi.combo_id::text, '') AS clave,
                 pi.porcentaje_iva AS pct
            FROM pedido_items pi
           WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
             AND NOT COALESCE(pi.es_bonificacion, false)
           ORDER BY pi.producto_id, pi.combo_id, pi.id) x;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
$r$),

-- VTA-F-4: la línea que ya estaba se desglosa con su foto.
('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 3, 1,
$a$    ELSE
      SELECT d.neto, d.iva, d.ingreso_real
        INTO v_neto_unitario, v_iva_unitario, v_ingreso_real
        FROM calcular_desglose_venta(v_precio_unitario, v_pct_iva_actual, v_imp_int_actual, v_tipo_factura) d;
$a$,
$r$    ELSE
      -- #1470 (VTA-F-4): una linea que ya estaba conserva el IVA de su foto; una
      -- nueva usa el de hoy. Una foto 0 es ambigua (default de las lineas
      -- anteriores a julio 2026) y cae al producto, como en
      -- cambiar_tipo_factura_pedido (#1258).
      v_pct_iva_actual := COALESCE(
        NULLIF((v_iva_fotos ->> (v_producto_id || ':' || COALESCE(NULLIF(v_item_nuevo->>'combo_id', ''), '')))::numeric, 0),
        v_pct_iva_actual);
      SELECT d.neto, d.iva, d.ingreso_real
        INTO v_neto_unitario, v_iva_unitario, v_ingreso_real
        FROM calcular_desglose_venta(v_precio_unitario, v_pct_iva_actual, v_imp_int_actual, v_tipo_factura) d;
$r$),

-- VTA-F-3: sin la CTE de II de la venta.
('public.posicion_fiscal(bigint,date,date)', 1, 1,
$a$  v_fc AS (
    SELECT COALESCE(SUM(pi.cantidad * COALESCE(pi.impuestos_internos_unitario, 0)), 0) AS ii_ventas
    FROM ped p JOIN pedido_items pi ON pi.pedido_id = p.id
    WHERE p.tipo_factura = 'FC' AND NOT COALESCE(pi.es_bonificacion, false)
  ),
$a$,
$r$  -- #1470 (VTA-F-3): la venta no lleva impuestos internos. La distribuidora no
  -- es sujeto de II (decision del dueño, 05/11): el impuesto es costo de compra
  -- (ii_compras, abajo) y no se traslada al cliente (mig 122, PR #424), y por
  -- eso calcular_desglose_venta ignora esa tasa. La fila "II contenido en FC"
  -- daba siempre 0 y se saco, con su CTE.
$r$),

('public.posicion_fiscal(bigint,date,date)', 2, 1,
$a$'iva_debito', v.iva_debito, 'ii_ventas_fc', f.ii_ventas,
$a$,
$r$'iva_debito', v.iva_debito,
$r$),

('public.posicion_fiscal(bigint,date,date)', 3, 1,
$a$FROM ventas v, v_fc f, nc_v n),
$a$,
$r$FROM ventas v, nc_v n),
$r$);

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
        RAISE EXCEPTION 'mig 464 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, los EXECUTE y el trigger quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM (VALUES
        ('public.validar_minimo_venta_item()',
         '4395467ecaf14a7db9fea593f143ff04', '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
         '65ce7ebc6a57b3175228c06f80f6764e', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.posicion_fiscal(bigint,date,date)',
         'e1f7f9bec3e171b71d545b5be6a5dfab', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
      ) AS t(firma, hash, acl)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR NOT r.def THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;
  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
       WHERE t.tgrelid = 'public.pedido_items'::regclass AND t.tgname = 'trg_validar_minimo_venta_item')
     IS DISTINCT FROM 'CREATE CONSTRAINT TRIGGER trg_validar_minimo_venta_item AFTER INSERT OR UPDATE OF cantidad, producto_id, es_bonificacion ON public.pedido_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((NOT COALESCE(new.es_bonificacion, false))) EXECUTE FUNCTION validar_minimo_venta_item()' THEN
    RAISE EXCEPTION 'trg_validar_minimo_venta_item no quedó diferido: %',
      (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
        WHERE t.tgrelid = 'public.pedido_items'::regclass AND t.tgname = 'trg_validar_minimo_venta_item');
  END IF;
END
$post$;

COMMIT;
