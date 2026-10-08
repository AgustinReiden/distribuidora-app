-- ============================================================================
-- 3XA — el vale blanco pasa de forma de pago a TIPO DE COMPROBANTE (lógica)
-- ============================================================================
-- El número real se pone al aplicar (Trampa 3 del CLAUDE.md): hoy la última en
-- prod es la 310 y hay otras sesiones con su propio 3XB/3XC/3XD abiertos.
--
-- QUÉ ES UN VB
-- ------------
-- Consumo interno hacia una empresa propia (Comercial TP, los Refugio, Crecer
-- Tucumán, "pérdidas y otros"). Hasta acá se cargaba como un ZZ a precio de
-- lista y se "cobraba" con un pago `forma_pago = 'vale_blanco'`: inflaba la
-- venta, el margen y las comisiones (mig 309), y el transportista "rendía" una
-- plata que no existía. Desde esta migración es el tercer valor de
-- `pedidos.tipo_factura` ('FC', 'ZZ', 'VB'):
--
--   · sin forma de pago: el comprobante ES el vale;
--   · a COSTO: cada línea vale `round(costo_valuacion(...), 2)` del producto al
--     crear, la misma expresión que escribe `costo_unitario_al_crear` (238/257);
--   · nunca es deuda: `monto_pagado = total`, `estado_pago = 'pagado'`, cero
--     filas en `pagos` ("saldado por naturaleza");
--   · nace entregado, sin transportista, no pasa por ruta ni por rendición;
--   · sin promos, regalos, bonificaciones, monto mínimo ni mínimo por producto;
--   · no se edita ni cambia de cliente: se cancela (sólo admin) y se recarga.
--
-- DESPLIEGUE EN TRES TANDAS — ésta es la primera
-- ----------------------------------------------
-- (A) esto, (front), (C) backfill de los ~193 históricos. Esta migración va
-- ANTES del front y no mueve ningún número: hoy no hay ningún pedido VB ni
-- ningún cliente con `tipo_factura_default = 'VB'`, así que un PWA viejo no
-- puede mandar un VB. Lo único que se nota apenas se aplica es N15: un pago o
-- un pedido con `forma_pago = 'vale_blanco'` se rechaza con un mensaje que
-- dice qué hacer. Los 195 pagos vale_blanco viejos siguen ahí hasta la C, y las
-- rendiciones los siguen sumando en su columna (§3.5 A).
--
-- REGLA DURA (B1 de la revisión) — vale para todo el que toque un VB
-- ------------------------------------------------------------------
-- Los AFTER `UPDATE OF total, monto_pagado` (saldo del cliente, recorrido,
-- reconciliación de pagos) disparan por la lista del SET, NO por lo que haya
-- cambiado un BEFORE. Es la familia de la Trampa 6. Por eso todo UPDATE que
-- cambie `tipo_factura` o el total de un VB nombra `total` (y, cuando lo fija,
-- `monto_pagado`) en el SET. Las salvedades nombran `total`, y con eso basta:
-- el BEFORE pone `monto_pagado := total` y los AFTER leen el NEW final.
--
-- CÓMO SE ESCRIBE: cirugía por ancla sobre el cuerpo VIVO
-- --------------------------------------------------------
-- La mayoría de las funciones cambian en uno o dos renglones. Se parchean con
-- el mismo andamio de la 229/236/240/241: se lee `pg_get_functiondef` AL
-- APLICAR, se reemplaza el ancla y se re-ejecuta. Si el ancla no aparece la
-- cantidad de veces esperada, la migración entera falla: si otra sesión cambió
-- el cuerpo, esto no entra a medias. Además así se compone con las otras
-- migraciones del paquete (3XB/3XD) en vez de pisarlas.
-- Se reescriben ENTERAS (copia literal de prod + el cambio) sólo las que
-- cambian de forma: calcular_desglose_venta, actualizar_estado_pago_pedido,
-- recalcular_monto_pagado_pedido, crear_pedido_completo y
-- cambiar_tipo_factura_pedido (ésta por pedido explícito del diseño, N10).
--
-- QUÉ NO SE TOCA ACÁ (es de otras migraciones del paquete)
-- --------------------------------------------------------
-- reporte_gerencial, posicion_fiscal, reporte_rentabilidad,
-- calcular_comisiones, reporte_ventas_por_preventista y todo lo de "venta"
-- (§3.4 del diseño, 3XB/3XD). `obtener_detalle_rendicion` tampoco: no tiene
-- lado "entregado" que filtrar y su columna vale_blanco sigue sumando los
-- pagos viejos hasta la C. Las columnas `total_vale_blanco`/`vale_blanco` de
-- las rendiciones se conservan (las dropea la C, cuando el front ya las lee
-- de forma tolerante).
--
-- ============================================================================
-- LOS BLOQUEOS DE LA CONVERSIÓN (N10), UNO POR UNO, PARA QUE EL DUEÑO DECIDA
-- ============================================================================
-- cambiar_tipo_factura_pedido, ZZ/FC → VB. Se rechaza si:
--   1. el cliente no tiene `tipo_factura_default = 'VB'`;
--   2. el pedido tiene pagos (con su pedido_id) o `monto_pagado > 0`
--      (eso cubre el crédito imputado);
--   3. tiene salvedades no anuladas;
--   4. tiene una nota de crédito vigente;
--   5. tiene líneas bonificadas o con promoción;
--   6. está entregado en un día de caja cerrada
--      (`fecha_entrega::date <= ultima_fecha_caja_cerrada` de su sucursal);
--   7. está en estado asignado/en_preparacion/en_camino o, si NO está
--      entregado, en un recorrido `en_curso` ("sacalo de la ruta primero").
--      Desvío del diseño (revisión, I4): el diseño pedía el recorrido
--      `en_curso` también para un entregado, pero los recorridos quedan
--      `en_curso` indefinidamente (69 desde junio, 1782 entregados) y el
--      bloqueo prohibía casi toda conversión de un entregado. PREGUNTA PARA EL
--      DUEÑO: ¿se puede convertir un entregado de un recorrido sin cerrar?;
--   8. rol: si no está entregado, admin o encargado; si está entregado, admin;
--   9. (agregado, conservador) es un pedido de canje (`canal = 'cambio'`);
--  10. (agregado, conservador) está cancelado o anulado;
--  11. (agregado, conservador) no está entregado y su fecha es futura: un VB
--      nace entregado y VENTA-E no admite entregados con fecha futura;
--  12. (agregado, N5) algún producto no tiene costo cargado.
-- cambiar_tipo_factura_pedido, VB → ZZ/FC. Se rechaza si:
--   1. quien lo pide no es admin;
--   2. está entregado en un día de caja cerrada (mismo criterio que arriba);
--   3. (agregado, conservador) tiene salvedades no anuladas: la salvedad
--      guarda el precio de la línea (costo) y anularla después la restituiría
--      a costo en un ZZ;
--   4. (agregado, conservador) algún producto no tiene precio de lista;
--   5. (agregado, conservador) está cancelado o anulado.
-- Otros rechazos nuevos del VB, fuera de la conversión:
--   · crear_pedido_completo rechaza un VB con p_total o algún precio_unitario
--     distinto de 0: es un PWA viejo que copió el default VB del cliente y
--     manda precios de lista mostrando "ZZ" (revisión, I2). El front nuevo
--     manda 0 y 0 (itemsVBParaCrear y la cola offline).
--   · cancelar_pedido_con_stock rechaza un VB con salvedades no anuladas: la
--     anulación posterior de la salvedad bajaría stock que no salió
--     (revisión, I1), y un VB con transportista en un día de caja cerrada.
--
-- ORDEN DE APLICACIÓN (obligatorio)
-- ---------------------------------
--   3XA → 3XB y 3XD (entre sí en cualquier orden, ninguna toca una función de
--   la otra ni de ésta) → front → 3XC, la C sin demora después del front.
--   · La 3XB corta si ya existe algún pedido VB: va junto con ésta, nunca
--     después del front ni de la C.
--   · Entre ésta y la C nadie puede cargar consumo interno: N15 ya rechaza
--     'vale_blanco' y ningún cliente es VB hasta la C (o hasta que un admin
--     habilite los 5 a mano). Lo que se cargue en esa ventana como ZZ a esos
--     clientes queda como venta y deuda: la C lo lista (WARNING) pero no lo
--     convierte.
--   · Los cuatro archivos llevan placeholder; `scripts/check-migrations.mjs`
--     lee `3XA_` como la migración 3 (filtra con /^\d+/): renombrar al número
--     real (elegido al aplicar, Trampa 3) antes de mergear.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0a · Premisas. Las cinco funciones que se reescriben ENTERAS son copia
--      literal del cuerpo de prod del 2026-10-08. Un CREATE OR REPLACE sobre un
--      cuerpo que otra sesión cambió después revertiría ese cambio en silencio:
--      si el md5 del cuerpo vivo no es el que se copió, la migración no entra
--      (molde de la 3XB). Las que se parchean por ancla no lo necesitan: el
--      ancla ya falla si el cuerpo cambió en ese renglón.
--      md5(prosrc) y no md5(pg_get_functiondef): el cuerpo, que es lo copiado.
--      (actualizar_estado_pago_pedido tiene fines de línea CRLF en prod; la
--      copia de abajo los escribe LF, sin efecto funcional.)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'b633c25cd84551488a143acee3d5ea8f'),
        ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)',   '98ae5486c84288b9d4a5b6bad31ed681'),
        ('public.actualizar_estado_pago_pedido()',                              '279837fa8ee9ee2a62c843a1292fec2a'),
        ('public.recalcular_monto_pagado_pedido()',                             'd12a09e76d019b4a7a7e5289dea03fcc'),
        ('public.calcular_desglose_venta(numeric,numeric,numeric,text)',        'a1d9aad9c2792cfd68ef713105427576')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION '3XA · % cambió en prod desde que se copió (md5 %, esperado %): rehacer la copia sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 0 · El andamio. Mismo helper que la 241, con un parámetro más: cuántas
--     veces se espera el ancla (algunas funciones repiten el mismo renglón en
--     el SELECT del bucle y en el del INSERT, y los dos tienen que cambiar).
--     Se reemplazan TODAS las apariciones; si no son exactamente p_veces, falla.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._migvb_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text,
  p_veces   int DEFAULT 1
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> p_veces THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaban %). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, p_veces, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;
REVOKE ALL ON FUNCTION public._migvb_ancla(regprocedure, text, text, int) FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- §3.1 · ESQUEMA
-- ===========================================================================

-- 1 · El dominio del comprobante de VENTA y del default del cliente. El lado
--     compras (compras_tipo_factura_check, compras_letra_solo_con_factura,
--     productos_ultimo_tipo_compra_check) NO se toca: un VB no existe en
--     compras (N1), y reusar el dominio ahí rompería el costo.
ALTER TABLE public.pedidos DROP CONSTRAINT pedidos_tipo_factura_check;
ALTER TABLE public.pedidos ADD CONSTRAINT pedidos_tipo_factura_check
  CHECK (((tipo_factura)::text = ANY ((ARRAY['ZZ'::character varying, 'FC'::character varying, 'VB'::character varying])::text[])));

ALTER TABLE public.clientes DROP CONSTRAINT clientes_tipo_factura_default_check;
ALTER TABLE public.clientes ADD CONSTRAINT clientes_tipo_factura_default_check
  CHECK (((tipo_factura_default)::text = ANY ((ARRAY['ZZ'::character varying, 'FC'::character varying, 'VB'::character varying])::text[])));

-- 2 · El origen del precio de una línea de VB. Sin esto el INSERT de un VB
--     falla con 23514. `comision_reglas_origen_check` NO se amplía a propósito:
--     si no, alguien podría configurar una comisión sobre consumo interno.
--     Ojo para reportes de descuentos: completar_origen_precio_item calcula
--     `descuento_pct` contra la lista, y en un VB da 20-40 % de "descuento" que
--     no es tal. Todo reporte de descuentos excluye `costo_interno`.
ALTER TABLE public.pedido_items DROP CONSTRAINT pedido_items_origen_precio_check;
ALTER TABLE public.pedido_items ADD CONSTRAINT pedido_items_origen_precio_check
  CHECK (((origen_precio IS NULL) OR ((origen_precio)::text = ANY ((ARRAY['lista'::character varying, 'mayorista'::character varying, 'desc_cliente'::character varying, 'desc_categoria'::character varying, 'manual'::character varying, 'bonificacion'::character varying, 'desconocido'::character varying, 'costo_interno'::character varying])::text[]))));

-- 3 · pedidos_eliminados no sabía de qué comprobante era el pedido. Un VB
--     eliminado quedaba como "efectivo / pagado / monto_pagado = total", que se
--     lee como una venta cobrada. Las filas viejas quedan en NULL (no se sabe).
ALTER TABLE public.pedidos_eliminados ADD COLUMN IF NOT EXISTS tipo_factura character varying(2);

-- 4 · Sólo un admin habilita o quita el vale blanco de un cliente (N2).
--     Hoy nada lo defendía: `mt_clientes_insert` deja a un preventista crear un
--     cliente con cualquier default, y trg_clientes_proteger_columnas es sólo
--     de UPDATE y deja libre al encargado. Molde: clientes_reservado_solo_admin.
--     A diferencia del molde, NO se exime `pg_trigger_depth() > 1`: así no hay
--     función intermedia que lo saltee. Las migraciones (current_user postgres)
--     pasan, que es lo que necesita el backfill de la C.
CREATE OR REPLACE FUNCTION public.clientes_vb_solo_admin()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.tipo_factura_default = 'VB' AND NOT es_admin() THEN
      RAISE EXCEPTION 'Sólo un admin puede habilitar o quitar el vale blanco de un cliente'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.tipo_factura_default IS DISTINCT FROM OLD.tipo_factura_default
     AND (NEW.tipo_factura_default = 'VB' OR OLD.tipo_factura_default = 'VB')
     AND NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede habilitar o quitar el vale blanco de un cliente'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;
-- Función de trigger: la invoca el executor, no necesita EXECUTE para nadie.
REVOKE ALL ON FUNCTION public.clientes_vb_solo_admin() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_clientes_vb_solo_admin
  BEFORE INSERT OR UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_vb_solo_admin();

-- 5 · N15: 'vale_blanco' deja de ser forma de pago, en `pagos` Y en `pedidos`.
--     Un trigger y no una lista blanca en cada RPC: entra por siete caminos
--     (los dos FIFO, los dos masivos, crear_pedido_completo/idempotente vía
--     p_forma_pago, la cola offline de un PWA viejo, un UPDATE directo).
--     Sólo rechaza ESCRIBIR el valor: un UPDATE que vuelve a mandar el
--     'vale_blanco' que ya tenía la fila (los 20 pedidos y 195 pagos viejos,
--     hasta la C) no se traba. El CHECK de dominio va en la C, después del
--     backfill. Nombre elegido para que corra ANTES que los guards de caja
--     de `pagos` (orden alfabético): el que ve primero el error tiene que ver
--     el mensaje que le dice qué hacer.
CREATE OR REPLACE FUNCTION public.rechazar_forma_pago_vale_blanco()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.forma_pago IS DISTINCT FROM 'vale_blanco' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.forma_pago IS NOT DISTINCT FROM NEW.forma_pago THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'El vale blanco ahora es un tipo de comprobante: actualizá la app y cargalo como comprobante VB'
    USING ERRCODE = '22023';
END;
$function$;
REVOKE ALL ON FUNCTION public.rechazar_forma_pago_vale_blanco() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_pagos_forma_vale_blanco
  BEFORE INSERT OR UPDATE OF forma_pago ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.rechazar_forma_pago_vale_blanco();

CREATE TRIGGER trg_pedidos_forma_vale_blanco
  BEFORE INSERT OR UPDATE OF forma_pago ON public.pedidos
  FOR EACH ROW EXECUTE FUNCTION public.rechazar_forma_pago_vale_blanco();

-- 6 · Un VB no admite pagos (N7). Cubre el INSERT y el UPDATE OF pedido_id:
--     la reimputación de cambiar_cliente_pedido e imputar_credito_a_pedido_impl
--     mueven pagos de pedido. La NC de venta NO pasa por acá (su crédito nace
--     sin pedido_id): esa la frena crear_nota_credito_venta_impl, más abajo.
--     SECURITY DEFINER para que la lectura de `pedidos` no dependa de la RLS
--     de quien inserta el pago.
CREATE OR REPLACE FUNCTION public.pagos_rechazar_pedido_vb()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.pedido_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.pedido_id IS NOT DISTINCT FROM NEW.pedido_id THEN
      RETURN NEW;
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = NEW.pedido_id AND tipo_factura = 'VB') THEN
    RAISE EXCEPTION 'El pedido #% es un vale blanco (consumo interno): no admite pagos', NEW.pedido_id
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.pagos_rechazar_pedido_vb() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_pagos_comprobante_vb
  BEFORE INSERT OR UPDATE OF pedido_id ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.pagos_rechazar_pedido_vb();

-- 7 · Un VB sólo nace o se convierte por las RPCs (agregado, conservador).
--     pedidos_proteger_columnas deja que admin/encargado escriban
--     `tipo_factura` por UPDATE directo, y no mira el INSERT. Por esas dos
--     puertas un VB saltearía todo lo que validan crear_pedido_completo y
--     cambiar_tipo_factura_pedido: cliente habilitado, precio a costo, sin
--     pagos, caja cerrada. Las RPCs son SECURITY DEFINER (current_user
--     postgres) y pasan; las migraciones también.
CREATE OR REPLACE FUNCTION public.pedidos_vb_por_rpc()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.tipo_factura = 'VB' THEN
      RAISE EXCEPTION 'Un vale blanco se carga desde la app (crear_pedido_completo), no con un INSERT directo'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.tipo_factura IS DISTINCT FROM OLD.tipo_factura
     AND (NEW.tipo_factura = 'VB' OR OLD.tipo_factura = 'VB') THEN
    RAISE EXCEPTION 'El vale blanco se pone o se saca con "cambiar tipo de comprobante" (cambiar_tipo_factura_pedido), no con un UPDATE directo'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.pedidos_vb_por_rpc() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_pedidos_vb_por_rpc
  BEFORE INSERT OR UPDATE OF tipo_factura ON public.pedidos
  FOR EACH ROW EXECUTE FUNCTION public.pedidos_vb_por_rpc();

-- ===========================================================================
-- §3.3 (parte) · calcular_desglose_venta — rama VB EXPLÍCITA
-- ===========================================================================
-- Antes, 'VB' caía en el ELSE: iva 0 e ingreso_real = precio (bien), pero el
-- neto salía SIN CASE como precio/(1+iva) — un neto teórico que en un consumo
-- interno a costo no existe. VB: neto = precio, iva = 0, ingreso_real = precio.
-- Copia literal de prod + la rama.
CREATE OR REPLACE FUNCTION public.calcular_desglose_venta(p_precio numeric, p_pct_iva numeric, p_pct_ii numeric, p_tipo_factura text)
 RETURNS TABLE(neto numeric, iva numeric, ingreso_real numeric)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT
    CASE WHEN p_tipo_factura = 'VB'
         THEN round(COALESCE(p_precio, 0), 2)
         ELSE round(COALESCE(p_precio, 0) / (1 + COALESCE(p_pct_iva, 0)/100), 2) END,
    CASE WHEN p_tipo_factura = 'FC'
         THEN round(COALESCE(p_precio, 0) / (1 + COALESCE(p_pct_iva, 0)/100) * COALESCE(p_pct_iva, 0)/100, 2)
         WHEN p_tipo_factura = 'VB'
         THEN 0::numeric
         ELSE 0::numeric END,
    CASE WHEN p_tipo_factura = 'FC'
         THEN round(COALESCE(p_precio, 0) / (1 + COALESCE(p_pct_iva, 0)/100), 2)
         WHEN p_tipo_factura = 'VB'
         THEN round(COALESCE(p_precio, 0), 2)
         ELSE round(COALESCE(p_precio, 0), 2) END;
$function$;

-- ===========================================================================
-- §3.2 · COBRANZA: un VB está "saldado por naturaleza"
-- ===========================================================================

-- 1 · actualizar_estado_pago_pedido (BEFORE de pedidos). Copia literal de
--     prod + la rama VB arriba de todo. No usa OLD, así que no necesita la
--     guarda de TG_OP (el trigger también corre en INSERT).
CREATE OR REPLACE FUNCTION public.actualizar_estado_pago_pedido()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- mig 3XA: un vale blanco no es deuda. El comprobante es el vale: queda
  -- saldado por su propio total, sin filas en `pagos`. Cancelado (total 0)
  -- queda en 0 y 0, como pide VENTA-I.
  IF NEW.tipo_factura = 'VB' THEN
    NEW.monto_pagado := NEW.total;
    NEW.estado_pago := 'pagado';
    RETURN NEW;
  END IF;

  -- Si el monto pagado es >= al total, marcar como pagado
  IF NEW.monto_pagado >= NEW.total THEN
    NEW.estado_pago := 'pagado';
  -- Si hay algo pagado pero no todo, marcar como parcial
  ELSIF NEW.monto_pagado > 0 THEN
    NEW.estado_pago := 'parcial';
  -- Si no hay nada pagado, marcar como pendiente
  ELSE
    NEW.estado_pago := 'pendiente';
  END IF;

  RETURN NEW;
END;
$function$;

-- 2 · El trigger existente (`BEFORE INSERT OR UPDATE OF monto_pagado, total`)
--     queda IGUAL. El diseño pedía ampliarle la lista OF a `tipo_factura,
--     estado_pago`; hacerlo así cambiaría a todos los ZZ/FC: un UPDATE directo
--     de `estado_pago` (usePedidosQuery.actualizarPago) dejaría de respetarse y
--     se recalcularía desde monto_pagado. Eso es otra discusión. Se agrega un
--     SEGUNDO trigger, acotado a los VB, con esas dos columnas: un UPDATE que
--     sólo toque `estado_pago` o `tipo_factura` de un VB vuelve a saldarlo. El
--     CHECK de abajo es la red si algo igual se escapa. Corre después del
--     original (orden alfabético), y los dos hacen lo mismo con un VB.
CREATE TRIGGER trigger_actualizar_estado_pago_vb
  BEFORE UPDATE OF tipo_factura, estado_pago ON public.pedidos
  FOR EACH ROW
  WHEN (NEW.tipo_factura = 'VB')
  EXECUTE FUNCTION public.actualizar_estado_pago_pedido();

-- 3 · recalcular_monto_pagado_pedido (AFTER de pagos): no toca un VB. Con el
--     guard de `pagos` un VB nuevo nunca tiene pagos; esto es para el DELETE
--     de los 195 pagos viejos en la C: sin la guarda, el borrado bajaría el
--     monto_pagado a 0 (el BEFORE lo volvería a total, pero dependeríamos del
--     orden). Copia literal de prod + `AND tipo_factura IS DISTINCT FROM 'VB'`
--     en cada UPDATE.
CREATE OR REPLACE FUNCTION public.recalcular_monto_pagado_pedido()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.pedido_id IS NOT NULL THEN
      UPDATE pedidos
         SET monto_pagado = COALESCE((
           SELECT SUM(monto) FROM pagos WHERE pedido_id = NEW.pedido_id
         ), 0)
       WHERE id = NEW.pedido_id
         AND tipo_factura IS DISTINCT FROM 'VB';  -- mig 3XA
    END IF;
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.pedido_id IS NOT NULL THEN
      UPDATE pedidos
         SET monto_pagado = COALESCE((
           SELECT SUM(monto) FROM pagos WHERE pedido_id = OLD.pedido_id
         ), 0)
       WHERE id = OLD.pedido_id
         AND tipo_factura IS DISTINCT FROM 'VB';  -- mig 3XA
    END IF;
    RETURN OLD;

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.pedido_id IS DISTINCT FROM NEW.pedido_id THEN
      IF OLD.pedido_id IS NOT NULL THEN
        UPDATE pedidos
           SET monto_pagado = COALESCE((
             SELECT SUM(monto) FROM pagos WHERE pedido_id = OLD.pedido_id
           ), 0)
         WHERE id = OLD.pedido_id
           AND tipo_factura IS DISTINCT FROM 'VB';  -- mig 3XA
      END IF;
      IF NEW.pedido_id IS NOT NULL THEN
        UPDATE pedidos
           SET monto_pagado = COALESCE((
             SELECT SUM(monto) FROM pagos WHERE pedido_id = NEW.pedido_id
           ), 0)
         WHERE id = NEW.pedido_id
           AND tipo_factura IS DISTINCT FROM 'VB';  -- mig 3XA
      END IF;
    ELSIF NEW.pedido_id IS NOT NULL THEN
      UPDATE pedidos
         SET monto_pagado = COALESCE((
           SELECT SUM(monto) FROM pagos WHERE pedido_id = NEW.pedido_id
         ), 0)
       WHERE id = NEW.pedido_id
         AND tipo_factura IS DISTINCT FROM 'VB';  -- mig 3XA
    END IF;
    RETURN NEW;
  END IF;

  RETURN NULL;
END;
$function$;

-- 4 · El invariante, en el esquema. Un CHECK corre DESPUÉS de los BEFORE, así
--     que no depende del orden de los triggers. Hace imposibles tres puertas
--     que la UI no tiene que abrir pero el servidor tiene que cerrar:
--     "Revertir entrega" (UPDATE directo de estado: un VB no vuelve a
--     pendiente ni entra al pool de rutas), un estado_pago puesto a mano, y un
--     monto_pagado que no sea el total. La cancelación (total 0, monto 0,
--     'pagado') pasa. Hoy no hay ninguna fila VB: se valida al instante.
ALTER TABLE public.pedidos ADD CONSTRAINT pedidos_vb_coherente
  CHECK (tipo_factura IS DISTINCT FROM 'VB'
         OR (estado IN ('entregado','cancelado','anulado')
             AND estado_pago IS NOT DISTINCT FROM 'pagado'
             AND monto_pagado IS NOT DISTINCT FROM total));

-- ===========================================================================
-- §3.3 · CREACIÓN
-- ===========================================================================

-- 1 · validar_precio_item_pedido: en el alta exige `productos.precio > 0`. Un
--     VB no se vende a lista (N5: "sin precio de lista: permitido"): un insumo
--     interno sin precio puede salir por vale. El precio de la línea (> 0)
--     se sigue exigiendo igual.
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.validar_precio_item_pedido()'::regprocedure,
$ancla$IF TG_OP = 'INSERT' AND (v_precio_lista IS NULL OR v_precio_lista <= 0) THEN$ancla$,
$nuevo$IF TG_OP = 'INSERT' AND (v_precio_lista IS NULL OR v_precio_lista <= 0)
     -- mig 3XA: un vale blanco va a costo, no a lista (N5).
     AND NOT EXISTS (SELECT 1 FROM pedidos WHERE id = NEW.pedido_id AND tipo_factura = 'VB') THEN$nuevo$);
END
$patch$;

-- 2 · crear_pedido_completo — copia literal de prod + la rama VB.
--     Firma intacta (crear_pedido_idempotente sólo delega y no se toca).
--     En un VB:
--       · el cliente tiene que estar habilitado (N2);
--       · sin bonificaciones ni promociones (N6), con fecha <= hoy (N8/VENTA-E);
--       · cada línea a `round(costo_valuacion(...), 2)` — EL MISMO valor que
--         se guarda en costo_unitario_al_crear (snapshot de la 257); producto
--         sin costo → rechazo claro antes del INSERT;
--       · se IGNORAN p_total, p_total_neto, p_total_iva, p_forma_pago y
--         p_estado_pago: desde la mig 310 un preventista no puede leer costos,
--         así que el front no sabe el precio; el total lo calcula el servidor y
--         se devuelve en el jsonb de éxito para mostrarlo. p_total y cada
--         precio_unitario tienen que venir en 0: distinto es un PWA viejo
--         (ver "Otros rechazos" en el encabezado) y se rechaza;
--       · sin monto mínimo de pedido (se saltea pedido_incumple_minimo) ni
--         mínimo por producto (app.omitir_minimo_venta, el escape de la 174);
--       · nace entregado: fecha_entrega a las 12:00 ART del día del pedido
--         (como marcar_entregas_masivo), sin transportista,
--         fecha_entrega_programada = fecha, monto_pagado = total, 'pagado';
--       · forma_pago queda en 'efectivo', el default de la columna: un VB no
--         tiene forma de pago, 'vale_blanco' ya no se puede escribir, y es lo
--         mismo que deja la C a los históricos.
--     El stock baja igual que en cualquier pedido ('pedido_creado').
CREATE OR REPLACE FUNCTION public.crear_pedido_completo(p_cliente_id bigint, p_total numeric, p_usuario_id uuid, p_items jsonb, p_notas text DEFAULT NULL::text, p_forma_pago text DEFAULT 'efectivo'::text, p_estado_pago text DEFAULT 'pendiente'::text, p_fecha date DEFAULT NULL::date, p_tipo_factura text DEFAULT 'ZZ'::text, p_total_neto numeric DEFAULT NULL::numeric, p_total_iva numeric DEFAULT 0, p_fecha_entrega_programada date DEFAULT NULL::date, p_preventista_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido_id INT; item JSONB; v_producto_id INT; v_cantidad INT;
  v_precio_unitario DECIMAL; v_es_bonificacion BOOLEAN; v_promocion_id BIGINT;
  v_neto_unitario DECIMAL; v_iva_unitario DECIMAL; v_ingreso_real DECIMAL;
  v_porcentaje_iva DECIMAL; v_stock_actual INT; v_producto_nombre TEXT;
  errores TEXT[] := '{}'; v_user_role TEXT;
  v_producto_activo BOOLEAN; -- mig 284
  v_cantidades_totales JSONB := '{}'::JSONB; v_cant_acumulada INT;
  v_cantidades_stock JSONB := '{}'::JSONB; v_cant_stock INT;
  v_stock_snapshot JSONB := '{}'::JSONB;
  v_stock_al_crear INT;
  v_costo_actual NUMERIC; v_imp_int_actual NUMERIC; v_pct_iva_actual NUMERIC; v_costo_real_actual NUMERIC;
  v_costo_promedio_actual NUMERIC;
  v_costo_snapshot JSONB := '{}'::JSONB; v_costo_al_crear NUMERIC;
  v_pct_iva_snapshot JSONB := '{}'::JSONB;
  v_pct_ii_snapshot JSONB := '{}'::JSONB;
  v_tipo_factura TEXT := COALESCE(p_tipo_factura, 'ZZ');
  v_total_neto_calc NUMERIC := 0;
  v_total_iva_calc NUMERIC := 0;
  v_total_real_calc NUMERIC := 0;
  v_regalo_mueve_stock BOOLEAN;
  v_descripcion_regalo TEXT;
  v_regalo_default_id BIGINT;
  v_container_id INT;
  v_fecha_pedido DATE := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_fecha_entrega DATE := COALESCE(p_fecha_entrega_programada, (v_fecha_pedido + INTERVAL '1 day')::date);
  v_promo RECORD;
  v_usos_pendientes_actual INT;
  v_bloques_completos INT;
  v_ajustar_usos INT;
  v_ajustar_stock INT;
  v_stock_ajuste_anterior INT;
  v_stock_ajuste_nuevo INT;
  v_ajuste_producto_nombre TEXT;
  v_merma_id BIGINT;
  v_item_id BIGINT;
  v_pedidos_bundle TEXT;
  v_observacion TEXT;
  v_preventista_role TEXT;
  v_preventista_final UUID;
  -- mig 3XA (vale blanco)
  v_total_vb NUMERIC := 0;
  v_omitir_minimo_previo TEXT;
BEGIN
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('ID de usuario no coincide con la sesion autenticada')); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  -- mig 3XA · vale blanco: lo que se valida antes de tocar nada. Cualquiera que
  -- carga pedidos puede emitir un VB (N4), pero sólo a un cliente habilitado
  -- por un admin (N2). El default VB del cliente lo pone el FRONT; acá se
  -- valida, porque un PWA viejo o un request a mano pueden mandar cualquier cosa.
  IF v_tipo_factura = 'VB' THEN
    IF NOT EXISTS (SELECT 1 FROM clientes
                    WHERE id = p_cliente_id AND sucursal_id = v_sucursal
                      AND tipo_factura_default = 'VB') THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        'Este cliente no está habilitado para vale blanco (consumo interno). Cargá el pedido como ZZ o FC, o pedile a un admin que lo habilite.'));
    END IF;
    -- El front nuevo manda un VB con total 0 y precio 0 en cada línea (no ve
    -- costos). Un PWA viejo copiaba el `tipo_factura_default` del cliente al
    -- pedido y su selector no tiene la opción VB: muestra "ZZ" y manda 'VB'
    -- con los precios de lista. Sin esto, esa venta ZZ de verdad (N3) se
    -- convertiría en consumo interno a costo sin que nadie lo sepa. Precio o
    -- total distinto de 0 en un VB = bundle viejo: se rechaza sin escribir nada.
    --    (Va después del chequeo de que p_items es un array no vacío.)
    IF v_fecha_pedido > (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        'Un vale blanco nace entregado: no puede llevar una fecha futura.'));
    END IF;
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        'El vale blanco no tiene items.'));
    END IF;
    IF COALESCE(p_total, 0) <> 0
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
                   WHERE COALESCE(NULLIF(e->>'precio_unitario', '')::NUMERIC, 0) <> 0) THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        'Tu app está desactualizada: recargala para cargar vales blancos. El pedido no se creó.'));
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
                WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                   OR NULLIF(e->>'promocion_id', '') IS NOT NULL) THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        'Un vale blanco no lleva promociones ni regalos.'));
    END IF;
  END IF;

  -- El total lo calcula el servidor (mig 235). Antes se insertaba p_total tal
  -- cual y nadie lo comparaba con los items: items por $80.000 con p_total = 1
  -- descontaban el stock de verdad, salteaban la compra minima y dejaban al
  -- cliente debiendo $1. Se compara, no se pisa -- el contrato de p_total no
  -- cambia -- y la tolerancia de un centavo es la misma de VENTA-A.
  DECLARE
    v_total_calc    NUMERIC;
    v_motivo_minimo TEXT;
  BEGIN
    -- mig 3XA: un vale blanco no se compara contra p_total (el que lo carga no
    -- conoce el costo: lo precia el servidor) ni tiene compra minima (N6).
    IF v_tipo_factura <> 'VB' THEN
    SELECT COALESCE(SUM((e->>'cantidad')::INT * (e->>'precio_unitario')::NUMERIC), 0)
      INTO v_total_calc
      FROM jsonb_array_elements(p_items) e;

    IF abs(COALESCE(p_total, 0) - v_total_calc) > 0.01 THEN
      RETURN jsonb_build_object(
        'success', false,
        'errores', jsonb_build_array(format(
          'El total enviado (%s) no coincide con la suma de los items (%s). El pedido no se creo.',
          to_char(COALESCE(p_total, 0), 'FM$999G999G999D00'),
          to_char(v_total_calc, 'FM$999G999G999D00'))),
        'total_enviado',   COALESCE(p_total, 0),
        'total_calculado', v_total_calc);
    END IF;

    -- Compra minima de la sucursal (mig 204/205). Va aca, antes de tocar stock
    -- o promociones, para que un pedido que no llega no deje nada a medias.
    -- Contra el total CALCULADO: contra el declarado, el mismo p_total = 1 la
    -- salteaba.
    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_sucursal);
    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(v_motivo_minimo));
    END IF;
    END IF;
  END;


  IF p_preventista_id IS NULL OR p_preventista_id = p_usuario_id THEN
    v_preventista_final := p_usuario_id;
  ELSE
    IF v_user_role <> 'admin' THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('Solo admin puede asignar otro preventista al pedido'));
    END IF;
    SELECT p.rol INTO v_preventista_role
    FROM perfiles p
    WHERE p.id = p_preventista_id
      AND p.activo = true
      AND EXISTS (
        SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal
      );
    IF v_preventista_role IS NULL OR v_preventista_role NOT IN ('admin', 'preventista') THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('El usuario asignado no es admin ni preventista (o no pertenece a la sucursal)'));
    END IF;
    v_preventista_final := p_preventista_id;
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN errores := array_append(errores, 'Cantidad invalida para producto ID ' || v_producto_id); CONTINUE; END IF;

    v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
    v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);

    IF v_es_bonificacion THEN
      v_promocion_id := (item->>'promocion_id')::BIGINT;
      v_regalo_mueve_stock := NULL;
      IF v_promocion_id IS NOT NULL THEN
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      END IF;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        v_cantidades_stock := v_cantidades_stock || jsonb_build_object(v_producto_id::TEXT,
          COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0) + v_cantidad);
      END IF;
    ELSE
      v_cantidades_stock := v_cantidades_stock || jsonb_build_object(v_producto_id::TEXT,
        COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0) + v_cantidad);
    END IF;
  END LOOP;

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cant_stock := COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0);
    SELECT stock, nombre, costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21), activo
      INTO v_stock_actual, v_producto_nombre, v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual, v_producto_activo
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    -- mig 284: un inactivo no se vende (un cache offline viejo puede traerlo).
    -- mig 289: ni se regala. La 284 eximia a los regalos; el dueno decidio que
    -- un desactivado tampoco puede regalarse. Si el inactivo es el sabor
    -- default de una promo, el admin tiene que cambiarle el sabor a la promo.
    ELSIF NOT v_producto_activo THEN
      errores := array_append(errores, v_producto_nombre || ' está desactivado y no se puede vender');
    ELSIF v_stock_actual < v_cant_stock THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cant_stock || ')');
    END IF;
    IF v_stock_actual IS NOT NULL THEN
      v_stock_snapshot := v_stock_snapshot || jsonb_build_object(v_producto_id::TEXT, v_stock_actual);
      -- mig 257 (#673): la cascada unica de la 238. Sin snapshot previo: esto
      -- ES el snapshot que despues leen los reportes.
      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        public.costo_valuacion(NULL, v_costo_promedio_actual, v_costo_real_actual,
                               v_costo_actual, COALESCE(v_imp_int_actual, 0)));
      v_pct_iva_snapshot := v_pct_iva_snapshot || jsonb_build_object(v_producto_id::TEXT, v_pct_iva_actual);
      v_pct_ii_snapshot := v_pct_ii_snapshot || jsonb_build_object(v_producto_id::TEXT, v_imp_int_actual);
      -- mig 3XA (N5): el precio de un vale blanco ES este costo. Sin costo
      -- (cascada NULL, o que redondeado da 0) no hay precio: se rechaza aca con
      -- el nombre, y no con el "no puede venderse a precio 0" generico del
      -- trigger de la linea.
      IF v_tipo_factura = 'VB'
         AND COALESCE(round((v_costo_snapshot->>v_producto_id::TEXT)::NUMERIC, 2), 0) <= 0 THEN
        errores := array_append(errores, v_producto_nombre || ' no tiene costo cargado: no puede salir en un vale blanco');
      END IF;
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  -- mig 3XA: el total de un vale blanco, del lado del servidor, con el mismo
  -- redondeo por linea que va a quedar guardado (precio_unitario es
  -- numeric(10,2)): asi pedidos.total = SUM(subtotal) cierra (VENTA-A).
  IF v_tipo_factura = 'VB' THEN
    SELECT COALESCE(SUM((e->>'cantidad')::INT
             * round((v_costo_snapshot->>((e->>'producto_id')::INT)::TEXT)::NUMERIC, 2)), 0)
      INTO v_total_vb
      FROM jsonb_array_elements(p_items) e;

    INSERT INTO pedidos (cliente_id, fecha, total, total_neto, total_iva, total_real, tipo_factura, estado, usuario_id, creado_por, stock_descontado, notas, forma_pago, estado_pago, monto_pagado, fecha_entrega, fecha_entrega_programada, sucursal_id)
    VALUES (p_cliente_id, v_fecha_pedido, v_total_vb, v_total_vb, 0, v_total_vb, 'VB', 'entregado', v_preventista_final, p_usuario_id, true, p_notas, 'efectivo', 'pagado', v_total_vb,
            (v_fecha_pedido::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz,
            v_fecha_pedido, v_sucursal)
    RETURNING id INTO v_pedido_id;
  ELSE
  INSERT INTO pedidos (cliente_id, fecha, total, total_neto, total_iva, total_real, tipo_factura, estado, usuario_id, creado_por, stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id)
  VALUES (p_cliente_id, v_fecha_pedido, p_total, COALESCE(p_total_neto, p_total), COALESCE(p_total_iva, 0), p_total, v_tipo_factura, 'pendiente', v_preventista_final, p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal)
  RETURNING id INTO v_pedido_id;
  END IF;

  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

  -- mig 3XA (N6): un vale blanco no tiene minimo de venta por producto. Mismo
  -- escape por transaccion que usan las salvedades (mig 174); se restaura al
  -- salir del bucle para no dejarselo prendido al resto de la transaccion.
  IF v_tipo_factura = 'VB' THEN
    v_omitir_minimo_previo := current_setting('app.omitir_minimo_venta', true);
    PERFORM set_config('app.omitir_minimo_venta', '1', true);
  END IF;

  IF v_preventista_final IS DISTINCT FROM p_usuario_id THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_pedido_id, p_usuario_id, 'usuario_id', NULL, v_preventista_final::TEXT, v_sucursal);
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    v_stock_al_crear := (v_stock_snapshot->>v_producto_id::TEXT)::INT;
    v_costo_al_crear := (v_costo_snapshot->>v_producto_id::TEXT)::NUMERIC;

    -- mig 3XA (N5): en un vale blanco el precio que mando el front no cuenta.
    IF v_tipo_factura = 'VB' THEN
      v_precio_unitario := round(v_costo_al_crear, 2);
    END IF;

    IF v_es_bonificacion THEN
      v_neto_unitario := 0; v_iva_unitario := 0; v_ingreso_real := 0; v_porcentaje_iva := 0;
    ELSE
      SELECT d.neto, d.iva, d.ingreso_real
        INTO v_neto_unitario, v_iva_unitario, v_ingreso_real
        FROM calcular_desglose_venta(
          v_precio_unitario,
          (v_pct_iva_snapshot->>v_producto_id::TEXT)::NUMERIC,
          (v_pct_ii_snapshot->>v_producto_id::TEXT)::NUMERIC,
          v_tipo_factura) d;
      v_porcentaje_iva := (v_pct_iva_snapshot->>v_producto_id::TEXT)::NUMERIC;
      v_total_neto_calc := v_total_neto_calc + (v_cantidad * v_neto_unitario);
      v_total_iva_calc  := v_total_iva_calc  + (v_cantidad * v_iva_unitario);
      v_total_real_calc := v_total_real_calc + (v_cantidad * v_ingreso_real);
    END IF;

    v_descripcion_regalo := NULL;
    v_regalo_default_id := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo, producto_regalo_id
        INTO v_descripcion_regalo, v_regalo_default_id
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      -- mig 271 (#830): otro sabor -> la descripcion del producto entregado.
      IF v_regalo_default_id IS DISTINCT FROM v_producto_id AND v_descripcion_regalo IS NOT NULL THEN
        v_descripcion_regalo := COALESCE(substring(v_descripcion_regalo from '^\d+\s+\S+\s+'), '')
          || COALESCE((SELECT nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal), '');
      END IF;
    END IF;

    -- mig 3XA: origen_precio explicito en un VB ('costo_interno'). En el resto
    -- sigue NULL y lo completa completar_origen_precio_item, como hasta ahora.
    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario,
      sucursal_id, descripcion_regalo, stock_al_crear, costo_unitario_al_crear,
      origen_precio
    ) VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, 0, v_porcentaje_iva,
      v_ingreso_real,
      v_sucursal, v_descripcion_regalo, v_stock_al_crear, v_costo_al_crear,
      CASE WHEN v_tipo_factura = 'VB' THEN 'costo_interno' END
    ) RETURNING id INTO v_item_id;

    -- mig 256: de aca sale la huella lote -> linea (pedido_item_lotes). Se
    -- apaga apenas termina la bajada a proposito: el auto-ajuste de promo
    -- que viene despues tambien baja stock y es una merma del contenedor,
    -- no mercaderia que se llevo el cliente.
    PERFORM set_config('app.stock_pedido_item_id', v_item_id::TEXT, true);

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
    END IF;

    PERFORM set_config('app.stock_pedido_item_id', '', true);

    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      -- mig 294 (#840): un contador por sabor. La linea suma en la barra de SU
      -- producto y, si cierra un bloque, el fardo sale del contenedor de esa
      -- barra. Todo eso lo hace el motor, que es el mismo de la devolucion.
      SELECT nombre, COALESCE(ajuste_automatico, false) AS auto
        INTO v_promo
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      v_observacion := NULL;
      IF v_promo.auto THEN
        v_pedidos_bundle := public.pedido_bundle_para_promo(v_promocion_id, v_sucursal, 20);
        v_observacion := 'Auto-ajuste (Promo: ' || v_promo.nombre
                         || ', Pedidos: ' || COALESCE(v_pedidos_bundle, '#' || v_pedido_id) || ')';
      END IF;
      PERFORM public.aplicar_uso_promo_acumulador(
        v_promocion_id, v_producto_id, v_cantidad, v_producto_id,
        v_sucursal, p_usuario_id, v_observacion);
    END IF;
  END LOOP;

  IF v_tipo_factura = 'VB' THEN
    PERFORM set_config('app.omitir_minimo_venta', COALESCE(v_omitir_minimo_previo, ''), true);
  END IF;

  UPDATE pedidos
     SET total_neto = round(v_total_neto_calc, 2),
         total_iva  = round(v_total_iva_calc, 2),
         total_real = round(v_total_real_calc, 2)
   WHERE id = v_pedido_id AND sucursal_id = v_sucursal;

  -- mig 3XA: el que cargo un vale blanco no vio montos (no puede leer
  -- costos): el total se le muestra con lo que devuelve esto.
  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id)
    || CASE WHEN v_tipo_factura = 'VB'
            THEN jsonb_build_object('tipo_factura', 'VB', 'total', round(v_total_vb, 2))
            ELSE '{}'::jsonb END;
END;
$function$;

-- 3 · crear_pedido_completo_bot (N14): el bot no carga vales blancos. Un
--     cliente VB que llega por Telegram recibe el aviso; la previsualización
--     (supabase/functions/.../previsualizar_pedido.ts) lo rechaza antes, y
--     esto es la red de abajo, igual que el mínimo de compra.
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.crear_pedido_completo_bot(uuid, uuid)'::regprocedure,
$ancla$  -- El total lo calcula el servidor (mig 235), igual que en$ancla$,
$nuevo$  -- mig 3XA (N14): el vale blanco se carga desde la app, no desde el bot.
  IF EXISTS (SELECT 1 FROM clientes
              WHERE id = v_pendiente.cliente_id AND tipo_factura_default = 'VB') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este cliente es de consumo interno: el vale blanco se carga desde la app');
  END IF;

  -- El total lo calcula el servidor (mig 235), igual que en$nuevo$);
END
$patch$;

-- 4 · actualizar_pedido_items y cambiar_cliente_pedido: un VB no se edita ni
--     cambia de cliente (N9). Hoy ya rebotaban por "entregado", pero con un
--     mensaje que no dice qué hacer. Se cancela (admin) y se carga de nuevo, o
--     se corrige con una salvedad.
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.actualizar_pedido_items(bigint, jsonb, uuid)'::regprocedure,
$ancla$ARRAY['Pedido no encontrado']);
  END IF;$ancla$,
$nuevo$ARRAY['Pedido no encontrado']);
  END IF;

  -- mig 3XA (N9): un vale blanco no se edita.
  IF v_tipo_factura = 'VB' THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY[
      'Un vale blanco no se edita: cancelalo y cargalo de nuevo (o registrá una salvedad)']);
  END IF;$nuevo$);

  PERFORM public._migvb_ancla(
    'public.cambiar_cliente_pedido(bigint, bigint, uuid, jsonb, numeric, numeric, numeric, text)'::regprocedure,
$ancla$IF v_pedido.estado IN ('entregado', 'cancelado') THEN$ancla$,
$nuevo$IF COALESCE(v_pedido.tipo_factura, 'ZZ') = 'VB' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Un vale blanco no cambia de cliente: cancelalo y cargalo de nuevo al cliente correcto');
  END IF;

  IF v_pedido.estado IN ('entregado', 'cancelado') THEN$nuevo$);
END
$patch$;

-- 5 · registrar_salvedad / anular_salvedad: la rama VB explícita en el
--     total_real (antes caía en el ELSE y daba bien por casualidad). La
--     salvedad sobre un VB está permitida (N9) y valoriza al precio de la
--     línea, que es el costo. El UPDATE de pedidos de las dos nombra `total`,
--     así que el BEFORE de estado de pago vuelve a saldar el VB (monto_pagado
--     := total) y los AFTER de saldo y recorrido disparan y leen eso (B1).
DO $patch$
BEGIN
  PERFORM public._migvb_ancla(
    'public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean, uuid)'::regprocedure,
$ancla$CASE WHEN v_tipo_factura = 'FC'$ancla$,
$nuevo$CASE WHEN v_tipo_factura = 'VB' THEN precio_unitario WHEN v_tipo_factura = 'FC'$nuevo$);

  PERFORM public._migvb_ancla('public.anular_salvedad(bigint, text)'::regprocedure,
$ancla$CASE WHEN v_tipo_factura = 'FC' THEN$ancla$,
$nuevo$CASE WHEN v_tipo_factura = 'VB' THEN precio_unitario WHEN v_tipo_factura = 'FC' THEN$nuevo$);
END
$patch$;

-- 6 · Los masivos dejan afuera a los VB, en el SELECT del bucle y en el UPDATE.
--     La UI ya no los ofrece (un VB está entregado y pagado), pero el UPDATE de
--     los masivos alcanzaba a TODOS los ids del lote: le ponía transportista,
--     fecha de entrega y forma de pago a un VB sin que nada lo frenara.
DO $patch$
DECLARE
  v_eyp regprocedure := 'public.marcar_entrega_y_pago_masivo_impl(bigint[], uuid, text, date)'::regprocedure;
  v_pag regprocedure := 'public.marcar_pagos_masivo_impl(bigint[], text, date)'::regprocedure;
BEGIN
  PERFORM public._migvb_ancla(v_eyp,
$ancla$AND total > COALESCE(monto_pagado, 0)$ancla$,
$nuevo$AND total > COALESCE(monto_pagado, 0)
      AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA$nuevo$);
  PERFORM public._migvb_ancla(v_eyp,
$ancla$AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado');$ancla$,
$nuevo$AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB';  -- mig 3XA$nuevo$);

  PERFORM public._migvb_ancla(v_pag,
$ancla$AND total > COALESCE(monto_pagado, 0)$ancla$,
$nuevo$AND total > COALESCE(monto_pagado, 0)
      AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA$nuevo$);
  PERFORM public._migvb_ancla(v_pag,
$ancla$AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado');$ancla$,
$nuevo$AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB';  -- mig 3XA$nuevo$);

  PERFORM public._migvb_ancla('public.marcar_entregas_masivo(bigint[], uuid, date)'::regprocedure,
$ancla$AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado');$ancla$,
$nuevo$AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB';  -- mig 3XA$nuevo$);
END
$patch$;

-- 7 · Nota de crédito e imputación de crédito (N7). La NC es el agujero que el
--     guard de `pagos` no ve: su crédito nace SIN pedido_id (saldo a favor), y
--     después aplicar_credito_cliente lo imputaría a una deuda ZZ real del
--     mismo cliente (N3): el consumo interno se volvería crédito de plata. Si
--     hay que bajarle el total a un VB, es una salvedad.
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.crear_nota_credito_venta_impl(bigint, bigint, jsonb, text, text)'::regprocedure,
$ancla$IF v_pedido.estado IS DISTINCT FROM 'entregado' THEN$ancla$,
$nuevo$IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND tipo_factura = 'VB') THEN
    RAISE EXCEPTION 'El pedido #% es un vale blanco (consumo interno): no admite nota de credito. Si hay que bajarle el total, es una salvedad.', p_pedido_id
      USING ERRCODE = '22023';
  END IF;
  IF v_pedido.estado IS DISTINCT FROM 'entregado' THEN$nuevo$);

  -- Un VB ya rebotaba por "ya esta pagado" (total = monto_pagado); el mensaje
  -- explícito dice por qué.
  PERFORM public._migvb_ancla('public.imputar_credito_a_pedido_impl(bigint, bigint, numeric)'::regprocedure,
$ancla$v_falta := v_pedido.total - v_pedido.pagado;$ancla$,
$nuevo$IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND tipo_factura = 'VB') THEN
    RAISE EXCEPTION 'El pedido #% es un vale blanco (consumo interno): no se le imputa credito', p_pedido_id
      USING ERRCODE = '22023';
  END IF;
  v_falta := v_pedido.total - v_pedido.pagado;$nuevo$);
END
$patch$;

-- 8 · eliminar_pedido_completo sigue funcionando con un VB: el DELETE resta
--     total - monto_pagado = 0 del saldo. Sólo se agrega a pedidos_eliminados
--     de qué comprobante era (ver la columna nueva arriba).
DO $patch$
DECLARE v_fn regprocedure := 'public.eliminar_pedido_completo(bigint, uuid, text, boolean)'::regprocedure;
BEGIN
  PERFORM public._migvb_ancla(v_fn,
$ancla$motivo_eliminacion, stock_restaurado, sucursal_id)$ancla$,
$nuevo$motivo_eliminacion, stock_restaurado, sucursal_id, tipo_factura)$nuevo$);
  PERFORM public._migvb_ancla(v_fn,
$ancla$p_usuario_id, v_eliminador_nombre, p_motivo, p_restaurar_stock, v_sucursal);$ancla$,
$nuevo$p_usuario_id, v_eliminador_nombre, p_motivo, p_restaurar_stock, v_sucursal, v_pedido.tipo_factura);$nuevo$);
END
$patch$;

-- ===========================================================================
-- N9 · cancelar_pedido_con_stock: un VB se cancela aunque esté entregado
-- ===========================================================================
-- Un VB nace entregado, y la cancelación rechazaba todo entregado: N9
-- ("cancelar devuelve el stock") era imposible. Se exime al VB; sigue siendo
-- sólo admin (la función ya lo exige) y devuelve el stock por el camino normal
-- ('pedido_cancelado', lista blanca del trigger de lotes), con total 0 y
-- monto_pagado 0 (el UPDATE de abajo ya los nombra).
-- Caja cerrada: un VB histórico (los ~75 que convierte la C) PUEDE tener
-- transportista. Cancelar un entregado con transportista dispara
-- anular_control_por_cambio_fecha_entrega, que BORRA la fila de
-- rendiciones_control de ese día: reabriría una caja cerrada. En ese caso se
-- rechaza (conservador). Un VB nuevo no tiene transportista y no llega acá.
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.cancelar_pedido_con_stock(bigint, text, uuid, text)'::regprocedure,
$ancla$IF v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;$ancla$,
$nuevo$IF v_pedido.estado = 'entregado' AND COALESCE(v_pedido.tipo_factura, 'ZZ') <> 'VB' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;

  -- mig 3XA (N9): el vale blanco entregado si se cancela (arriba), salvo que
  -- figure en la rendicion de un transportista con la caja de ese dia cerrada.
  IF v_pedido.estado = 'entregado'
     AND v_pedido.transportista_id IS NOT NULL
     AND v_pedido.fecha_entrega IS NOT NULL
     AND v_pedido.fecha_entrega::date <= public.ultima_fecha_caja_cerrada(v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este vale blanco figura en la rendicion del ' || to_char(v_pedido.fecha_entrega::date, 'DD/MM/YYYY')
      || ' de su transportista y esa caja esta cerrada: cancelarlo la reabriria.');
  END IF;

  -- mig 3XA: un vale blanco con salvedades vivas no se cancela. La salvedad ya
  -- devolvio k unidades y dejo la linea en N-k; la cancelacion devuelve N-k.
  -- Si despues se anula la salvedad (anular_salvedad no mira el estado del
  -- pedido), la linea vuelve a N, el stock baja k sin que haya salido nada y
  -- el cancelado queda con total > 0 (VENTA-I en rojo). Antes no pasaba porque
  -- un entregado no se podia cancelar.
  IF COALESCE(v_pedido.tipo_factura, 'ZZ') = 'VB'
     AND EXISTS (SELECT 1 FROM salvedades_items
                  WHERE pedido_id = p_pedido_id AND estado_resolucion IS DISTINCT FROM 'anulada') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este vale blanco tiene salvedades: anulalas antes de cancelar el vale');
  END IF;$nuevo$);
END
$patch$;

-- ===========================================================================
-- N10 · cambiar_tipo_factura_pedido — reescrita entera
-- ===========================================================================
-- Copia de prod + los caminos VB. Tres cambios de forma, a propósito:
--   · Se va el `EXCEPTION WHEN OTHERS THEN RETURN {success:false}`. Tragaba
--     todo: un fallo del trigger de saldo o de un CHECK quedaba como un
--     "no se pudo" silencioso en el front, y peor, con lo de antes escrito.
--     Ahora las validaciones devuelven {success:false, error} con un mensaje
--     claro ANTES de escribir nada, y lo inesperado se propaga (la transacción
--     se revierte entera). El front tiene que manejar las dos cosas.
--   · ZZ/FC ↔ FC/ZZ sigue igual: redistribuye neto/IVA sin tocar el total.
--   · Hacia o desde VB RE-PRECIA las líneas: a costo vigente (hacia VB) o a
--     `productos.precio` vigente (desde VB), y cambia el total. El UPDATE de
--     pedidos nombra `total` y `monto_pagado` (B1): si no, los AFTER de saldo
--     no disparan y CC-A queda en rojo. Nunca toca el `transportista_id` de un
--     entregado: dispararía anular_control_por_cambio_fecha_entrega y borraría
--     controles de caja.
-- Los bloqueos están enumerados en el encabezado de la migración.
CREATE OR REPLACE FUNCTION public.cambiar_tipo_factura_pedido(p_pedido_id bigint, p_tipo character varying, p_usuario_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_user_role TEXT;
  v_pedido RECORD;
  v_item RECORD;
  v_neto NUMERIC; v_iva NUMERIC; v_real NUMERIC;
  v_total_neto NUMERIC := 0;
  v_total_iva NUMERIC := 0;
  v_total_real NUMERIC := 0;
  -- mig 3XA (vale blanco)
  v_tipo_actual TEXT;
  v_precio NUMERIC;
  v_total NUMERIC := 0;
  v_limite DATE;
  v_hoy DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_faltantes TEXT;
  v_mensaje TEXT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;
  IF p_tipo IS NULL OR p_tipo NOT IN ('ZZ', 'FC', 'VB') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tipo de comprobante inválido (ZZ, FC o VB)');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado');
  END IF;

  SELECT id, estado, tipo_factura, cliente_id, canal, fecha, fecha_entrega,
         transportista_id, total, monto_pagado
    INTO v_pedido
    FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;
  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cambiar el tipo de un pedido cancelado');
  END IF;
  IF v_user_role = 'encargado' AND v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede cambiar el tipo de un pedido entregado');
  END IF;
  v_tipo_actual := COALESCE(v_pedido.tipo_factura, 'ZZ');
  IF v_tipo_actual = p_tipo THEN
    RETURN jsonb_build_object('success', true, 'sin_cambio', true);
  END IF;

  -- =========================================================================
  -- mig 3XA · hacia o desde vale blanco
  -- =========================================================================
  IF p_tipo = 'VB' OR v_tipo_actual = 'VB' THEN
    IF v_pedido.estado = 'anulado' THEN
      RETURN jsonb_build_object('success', false, 'error', 'No se puede cambiar el tipo de un pedido anulado');
    END IF;

    -- Caja cerrada: cambiar el comprobante de un entregado cambia lo entregado
    -- (y, en un histórico con transportista, la rendición) de un día que ya se
    -- controló. Mismo criterio que imputar_credito_a_pedido_impl.
    IF v_pedido.estado = 'entregado' AND v_pedido.fecha_entrega IS NOT NULL THEN
      v_limite := public.ultima_fecha_caja_cerrada(v_sucursal);
      IF v_limite IS NOT NULL AND v_pedido.fecha_entrega::date <= v_limite THEN
        RETURN jsonb_build_object('success', false, 'error', format(
          'El pedido se entregó el %s y la caja está cerrada hasta el %s: no se puede cambiar su comprobante a o desde vale blanco.',
          to_char(v_pedido.fecha_entrega::date, 'DD/MM/YYYY'), to_char(v_limite, 'DD/MM/YYYY')));
      END IF;
    END IF;

    IF p_tipo = 'VB' THEN
      -- ---------------------------------------------------------------- ZZ/FC → VB
      IF v_pedido.canal = 'cambio' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Un pedido de canje no puede pasar a vale blanco');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM clientes
                      WHERE id = v_pedido.cliente_id AND tipo_factura_default = 'VB') THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El cliente no está habilitado para vale blanco: un admin tiene que habilitarlo en su ficha');
      END IF;
      IF COALESCE(v_pedido.monto_pagado, 0) > 0
         OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id = p_pedido_id) THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El pedido tiene pagos registrados (o crédito imputado): un vale blanco no admite pagos. Anulalos primero.');
      END IF;
      IF EXISTS (SELECT 1 FROM salvedades_items
                  WHERE pedido_id = p_pedido_id AND estado_resolucion IS DISTINCT FROM 'anulada') THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El pedido tiene salvedades: anulalas primero (guardan el precio de lista de la línea)');
      END IF;
      IF public.nota_credito_vigente_de_pedido(p_pedido_id) IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El pedido tiene la nota de crédito #' || public.nota_credito_vigente_de_pedido(p_pedido_id)
          || ' vigente: anulala primero');
      END IF;
      IF EXISTS (SELECT 1 FROM pedido_items
                  WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
                    AND (COALESCE(es_bonificacion, false) OR promocion_id IS NOT NULL)) THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El pedido tiene promociones o regalos: un vale blanco no los lleva');
      END IF;
      -- El chequeo de recorrido es sólo para lo que NO se entregó: convertir a
      -- VB marca entregada una parada que todavía no se hizo. Para un
      -- entregado "sacalo de la ruta" es imposible, y los recorridos quedan
      -- `en_curso` indefinidamente (al escribir: 69 recorridos desde junio con
      -- 1782 entregados adentro): el bloqueo prohibía casi toda conversión de
      -- un entregado. El entregado ya lo cubre el chequeo de caja cerrada de
      -- arriba, y total_cobrado del recorrido no cambia (era 0: sin pagos, y
      -- el VB se excluye). PREGUNTA PARA EL DUEÑO (bloqueo 7 del encabezado).
      IF v_pedido.estado IN ('asignado', 'en_preparacion', 'en_camino')
         OR (v_pedido.estado <> 'entregado'
             AND EXISTS (SELECT 1 FROM recorrido_pedidos rp
                           JOIN recorridos r ON r.id = rp.recorrido_id
                          WHERE rp.pedido_id = p_pedido_id AND r.estado = 'en_curso')) THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El pedido está en preparación o en una ruta armada: sacalo de la ruta primero');
      END IF;
      IF v_pedido.estado <> 'entregado' AND COALESCE(v_pedido.fecha, v_hoy) > v_hoy THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El pedido tiene fecha futura: un vale blanco nace entregado y no puede llevar fecha futura');
      END IF;

      -- N5: misma cascada que crear_pedido_completo (costo VIGENTE).
      -- `costo_unitario_al_crear` NO se reescribe a propósito: es la foto del
      -- costo cuando salió la mercadería (257), y si el VB vuelve a ZZ es el
      -- costo que tiene que ver el margen. Mientras sea VB la línea queda con
      -- precio = costo de hoy y snapshot = costo del alta; los reportes
      -- excluyen VB, así que esa diferencia no se ve en ningún número.
      SELECT string_agg(DISTINCT COALESCE(pr.nombre, 'producto #' || pi.producto_id), ', ')
        INTO v_faltantes
        FROM pedido_items pi
        LEFT JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND COALESCE(round(public.costo_valuacion(NULL, pr.costo_promedio, pr.costo_real,
                                                   pr.costo_sin_iva, COALESCE(pr.impuestos_internos, 0)), 2), 0) <= 0;
      IF v_faltantes IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
          v_faltantes || ': sin costo cargado, no puede salir en un vale blanco');
      END IF;

      FOR v_item IN
        SELECT pi.id, pi.cantidad,
               public.costo_valuacion(NULL, pr.costo_promedio, pr.costo_real,
                                      pr.costo_sin_iva, COALESCE(pr.impuestos_internos, 0)) AS costo,
               COALESCE(pr.porcentaje_iva, 21) AS pct_iva, COALESCE(pr.impuestos_internos, 0) AS pct_ii
          FROM pedido_items pi
          JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
         WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
      LOOP
        v_precio := round(v_item.costo, 2);
        SELECT d.neto, d.iva, d.ingreso_real INTO v_neto, v_iva, v_real
          FROM calcular_desglose_venta(v_precio, v_item.pct_iva, v_item.pct_ii, 'VB') d;
        UPDATE pedido_items
           SET precio_unitario = v_precio,
               subtotal = v_item.cantidad * v_precio,
               neto_unitario = v_neto,
               iva_unitario = v_iva,
               impuestos_internos_unitario = 0,
               porcentaje_iva = v_item.pct_iva,
               ingreso_real_unitario = v_real,
               origen_precio = 'costo_interno'
         WHERE id = v_item.id;
        v_total      := v_total      + v_item.cantidad * v_precio;
        v_total_neto := v_total_neto + v_item.cantidad * v_neto;
        v_total_iva  := v_total_iva  + v_item.cantidad * v_iva;
        v_total_real := v_total_real + v_item.cantidad * v_real;
      END LOOP;

      -- B1: `total` y `monto_pagado` en el SET. N8: si no estaba entregado,
      -- nace entregado a las 12:00 ART de su fecha y sin transportista. Si ya
      -- estaba entregado, fecha_entrega y transportista quedan como estaban.
      UPDATE pedidos
         SET tipo_factura = 'VB',
             total        = round(v_total, 2),
             total_neto   = round(v_total_neto, 2),
             total_iva    = round(v_total_iva, 2),
             total_real   = round(v_total_real, 2),
             monto_pagado = round(v_total, 2),
             estado       = 'entregado',
             fecha_entrega = CASE WHEN v_pedido.estado = 'entregado' THEN fecha_entrega
                                  ELSE (COALESCE(v_pedido.fecha, v_hoy)::text
                                        || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz END,
             transportista_id = CASE WHEN v_pedido.estado = 'entregado' THEN transportista_id
                                     ELSE NULL END,
             updated_at = NOW()
       WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

      v_mensaje := 'Quedó como vale blanco (consumo interno), a costo: '
        || to_char(round(v_total, 2), 'FM$999G999G999D00') || '. Ya no es deuda del cliente.';
    ELSE
      -- ---------------------------------------------------------------- VB → ZZ/FC
      IF v_user_role <> 'admin' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Solo un admin puede sacar un pedido de vale blanco');
      END IF;
      IF EXISTS (SELECT 1 FROM salvedades_items
                  WHERE pedido_id = p_pedido_id AND estado_resolucion IS DISTINCT FROM 'anulada') THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El vale blanco tiene salvedades: anulalas primero (guardan el precio a costo de la línea)');
      END IF;

      SELECT string_agg(DISTINCT COALESCE(pr.nombre, 'producto #' || pi.producto_id), ', ')
        INTO v_faltantes
        FROM pedido_items pi
        LEFT JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND NOT COALESCE(pi.es_bonificacion, false)
         AND COALESCE(round(pr.precio, 2), 0) <= 0;
      IF v_faltantes IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
          v_faltantes || ': sin precio de lista, cargalo antes de pasar el vale a ' || p_tipo);
      END IF;

      FOR v_item IN
        SELECT pi.id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonif,
               round(pr.precio, 2) AS precio_lista,
               COALESCE(pr.porcentaje_iva, 21) AS pct_iva, COALESCE(pr.impuestos_internos, 0) AS pct_ii
          FROM pedido_items pi
          JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
         WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
      LOOP
        IF v_item.es_bonif THEN
          UPDATE pedido_items
             SET neto_unitario = 0, iva_unitario = 0, impuestos_internos_unitario = 0,
                 porcentaje_iva = 0, ingreso_real_unitario = 0
           WHERE id = v_item.id;
        ELSE
          v_precio := v_item.precio_lista;
          SELECT d.neto, d.iva, d.ingreso_real INTO v_neto, v_iva, v_real
            FROM calcular_desglose_venta(v_precio, v_item.pct_iva, v_item.pct_ii, p_tipo) d;
          UPDATE pedido_items
             SET precio_unitario = v_precio,
                 subtotal = v_item.cantidad * v_precio,
                 neto_unitario = v_neto,
                 iva_unitario = v_iva,
                 impuestos_internos_unitario = 0,
                 porcentaje_iva = v_item.pct_iva,
                 ingreso_real_unitario = v_real,
                 origen_precio = 'lista'
           WHERE id = v_item.id;
          v_total      := v_total      + v_item.cantidad * v_precio;
          v_total_neto := v_total_neto + v_item.cantidad * v_neto;
          v_total_iva  := v_total_iva  + v_item.cantidad * v_iva;
          v_total_real := v_total_real + v_item.cantidad * v_real;
        END IF;
      END LOOP;

      -- B1: `total` y `monto_pagado` en el SET. Queda entregado y pendiente de
      -- cobro; el transportista no se toca (un VB nuevo no tiene).
      UPDATE pedidos
         SET tipo_factura = p_tipo,
             total        = round(v_total, 2),
             total_neto   = round(v_total_neto, 2),
             total_iva    = round(v_total_iva, 2),
             total_real   = round(v_total_real, 2),
             monto_pagado = 0,
             updated_at   = NOW()
       WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

      v_mensaje := 'Quedó como ' || p_tipo || ' entregado y pendiente de cobro por '
        || to_char(round(v_total, 2), 'FM$999G999G999D00') || '.'
        || CASE WHEN v_pedido.transportista_id IS NULL
                THEN ' No tiene transportista: el cobro no va a entrar en ninguna rendición de reparto.'
                ELSE '' END;
    END IF;

    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'tipo_factura', v_tipo_actual, p_tipo, v_sucursal);

    RETURN jsonb_build_object('success', true, 'pedido_id', p_pedido_id,
      'tipo_factura', p_tipo, 'total', round(v_total, 2), 'total_neto', round(v_total_neto, 2),
      'total_iva', round(v_total_iva, 2), 'total_real', round(v_total_real, 2),
      'mensaje', v_mensaje);
  END IF;

  -- ===================================================== ZZ ↔ FC (como antes)
  FOR v_item IN
    SELECT pi.id, pi.cantidad, pi.precio_unitario, COALESCE(pi.es_bonificacion, false) AS es_bonif,
           COALESCE(pr.porcentaje_iva, 21) AS pct_iva, COALESCE(pr.impuestos_internos, 0) AS pct_ii
      FROM pedido_items pi
      JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
  LOOP
    IF v_item.es_bonif THEN
      UPDATE pedido_items
         SET neto_unitario = 0, iva_unitario = 0, impuestos_internos_unitario = 0,
             porcentaje_iva = 0, ingreso_real_unitario = 0
       WHERE id = v_item.id;
    ELSE
      SELECT d.neto, d.iva, d.ingreso_real INTO v_neto, v_iva, v_real
        FROM calcular_desglose_venta(v_item.precio_unitario, v_item.pct_iva, v_item.pct_ii, p_tipo) d;
      UPDATE pedido_items
         SET neto_unitario = v_neto,
             iva_unitario = v_iva,
             impuestos_internos_unitario = 0,
             porcentaje_iva = v_item.pct_iva,
             ingreso_real_unitario = v_real
       WHERE id = v_item.id;
      v_total_neto := v_total_neto + v_item.cantidad * v_neto;
      v_total_iva  := v_total_iva  + v_item.cantidad * v_iva;
      v_total_real := v_total_real + v_item.cantidad * v_real;
    END IF;
  END LOOP;

  UPDATE pedidos
     SET tipo_factura = p_tipo,
         total_neto = round(v_total_neto, 2),
         total_iva  = round(v_total_iva, 2),
         total_real = round(v_total_real, 2),
         updated_at = NOW()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'tipo_factura', COALESCE(v_pedido.tipo_factura, 'ZZ'), p_tipo, v_sucursal);

  RETURN jsonb_build_object('success', true, 'pedido_id', p_pedido_id,
    'tipo_factura', p_tipo, 'total_neto', round(v_total_neto, 2),
    'total_iva', round(v_total_iva, 2), 'total_real', round(v_total_real, 2));
END;
$function$;

-- ===========================================================================
-- N15 (parte) · actualizar_forma_pago_pago: 'vale_blanco' sale de la lista
-- blanca. Un pago vale_blanco viejo se puede pasar a otra forma (eso sí); lo
-- que no se puede es elegirla.
-- ===========================================================================
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.actualizar_forma_pago_pago(bigint, text)'::regprocedure,
$ancla$'cuenta_corriente', 'tarjeta', 'vale_blanco'$ancla$,
$nuevo$'cuenta_corriente', 'tarjeta'$nuevo$);
END
$patch$;

-- ===========================================================================
-- §3.2 · consumidores de monto_pagado como "cobrado" (lado cobranza)
-- ===========================================================================
-- En un VB monto_pagado = total sin un peso detrás. Donde ese número se lee
-- como plata cobrada, un VB lo inflaría. (Lo que lo lee como DEUDA,
-- total - monto_pagado, queda bien solo: da 0.)
--
-- 1 · Recorridos: `total_cobrado` excluye VB en el trigger y en el recálculo
--     (y RUTA-B, más abajo, recalcula con el mismo criterio). Los
--     entregados y lo facturado no cambian.
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.actualizar_recorrido_entrega()'::regprocedure,
$ancla$SUM(p.monto_pagado) FILTER (WHERE p.estado = 'entregado')$ancla$,
$nuevo$SUM(p.monto_pagado) FILTER (WHERE p.estado = 'entregado' AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB')$nuevo$);

  PERFORM public._migvb_ancla('public.recalcular_recorrido(bigint)'::regprocedure,
$ancla$SUM(p.monto_pagado) FILTER (WHERE p.estado = 'entregado')$ancla$,
$nuevo$SUM(p.monto_pagado) FILTER (WHERE p.estado = 'entregado' AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB')$nuevo$);
END
$patch$;

-- 2 · Rendiciones legacy (sin llamadores según la 273, pero viven): suman
--     monto_pagado por pedidos.forma_pago. Un VB entraba como "efectivo". Se
--     filtra en el SELECT del bucle y en el del INSERT de rendicion_items
--     (el mismo renglón, dos veces).
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.crear_rendicion_por_fecha(uuid, date)'::regprocedure,
$ancla$AND COALESCE(p.fecha_entrega, p.updated_at)::date = p_fecha$ancla$,
$nuevo$AND COALESCE(p.fecha_entrega, p.updated_at)::date = p_fecha AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'$nuevo$,
    2);

  PERFORM public._migvb_ancla('public.crear_rendicion_recorrido(bigint, uuid)'::regprocedure,
$ancla$AND p.estado = 'entregado' AND p.sucursal_id = v_sucursal$ancla$,
$nuevo$AND p.estado = 'entregado' AND p.sucursal_id = v_sucursal AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'$nuevo$,
    2);
END
$patch$;

-- ===========================================================================
-- §3.5 A · obtener_resumen_rendiciones: el VB sale de lo ENTREGADO
-- ===========================================================================
-- Sólo el filtro por tipo en `entregas_agg` (N12). Un VB nuevo no tiene
-- transportista y ya no entraba; esto es para los ~75 históricos con
-- transportista que convierte la C: así lo entregado y lo cobrado bajan juntos
-- y la diferencia de los días ya controlados no cambia.
-- La columna `total_vale_blanco` SE CONSERVA y el bucket vale_blanco sigue
-- sumando los pagos viejos igual que hoy: hasta la C esos pedidos siguen
-- siendo ZZ con su pago, y sacarlos ahora cambiaría rendiciones cerradas
-- antes de tiempo. La C recrea la función sin la columna (cambia el RETURNS
-- TABLE: DROP + CREATE). Grants: CREATE OR REPLACE conserva los de hoy
-- (authenticated, service_role; sin PUBLIC ni anon).
DO $patch$
BEGIN
  PERFORM public._migvb_ancla('public.obtener_resumen_rendiciones(date, date, uuid)'::regprocedure,
$ancla$WHERE pd.estado = 'entregado'$ancla$,
$nuevo$WHERE pd.estado = 'entregado'
      AND COALESCE(pd.tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA (N12)$nuevo$);
END
$patch$;

-- ===========================================================================
-- §3.2 · auditoria_integridad: CC-B, COSTO-B, RUTA-B y la familia VB-
-- ===========================================================================
-- Ids tomados al escribir esto: VENTA-A..J y M, COSTO-A..D, BONIF-A..D,
-- MERMA-*, STK-*, CC-A, CC-B, CC-PAGOS-CANCEL, COMPRA-*, CAMBIO-*, COMIS-*,
-- RUTA-A..C, LOTE-*, PROMO-*, SALV-A, BOT-*, II-A. La familia VB- está libre
-- entera (la salida es una lista, no un mapa: un id repetido no falla).
--   · CC-B  (monto_pagado = Σ pagos): un VB tiene monto_pagado = total y cero
--           pagos por diseño → fuera.
--   · COSTO-B (productos vendidos sin costo inflan el margen): el VB no está
--           en el margen → fuera.
--   · RUTA-B: recalcula total_cobrado con el mismo criterio nuevo del trigger.
--   · VB-A coherencia (la garantiza pedidos_vb_coherente; el check lo reporta
--           igual), VB-B cero pagos en un VB, VB-C un VB NACIDO VB después de
--           esta migración no tiene transportista. Los históricos (la C) y los
--           convertidos con cambiar_tipo_factura_pedido (que conservan el
--           transportista de un entregado a propósito) quedan fuera: el
--           corte es por created_at y por no tener historial de tipo_factura.
--           El instante se fija al aplicar.
--   · VB-D (¿el cliente era VB al crear?) se omite: un cliente puede
--           deshabilitarse después y el VB sigue siendo válido.
-- OJO para 3XB: esto parchea por ancla. Si otra migración reescribe
-- auditoria_integridad ENTERA a partir del cuerpo de hoy, borra estos checks.
DO $patch$
DECLARE v_fn regprocedure := 'public.auditoria_integridad()'::regprocedure;
BEGIN
  PERFORM public._migvb_ancla(v_fn,
$ancla$AND abs(COALESCE(p.monto_pagado,0) - s.suma) > 0.01)),$ancla$,
    format($nuevo$AND COALESCE(p.tipo_factura,'ZZ') <> 'VB'  /* mig 3XA: un VB no tiene pagos */
          AND abs(COALESCE(p.monto_pagado,0) - s.suma) > 0.01)),
    -- ===== Vale blanco (mig 3XA) =====
    ('VB-A','high','vale blanco coherente: entregado/cancelado/anulado, pagado y monto_pagado = total',
      (SELECT count(*) FROM pedidos WHERE tipo_factura='VB'
         AND NOT (estado IN ('entregado','cancelado','anulado')
                  AND estado_pago IS NOT DISTINCT FROM 'pagado'
                  AND monto_pagado IS NOT DISTINCT FROM total))),
    ('VB-B','high','ningún pago imputado a un vale blanco',
      (SELECT count(*) FROM pagos pg JOIN pedidos p ON p.id=pg.pedido_id WHERE p.tipo_factura='VB')),
    ('VB-C','medium','vale blanco nacido como VB sin transportista (históricos y convertidos quedan fuera a propósito)',
      (SELECT count(*) FROM pedidos p WHERE p.tipo_factura='VB' AND p.transportista_id IS NOT NULL
         AND p.created_at >= %L::timestamptz
         AND NOT EXISTS (SELECT 1 FROM pedido_historial ph
                          WHERE ph.pedido_id=p.id AND ph.campo_modificado='tipo_factura'))),$nuevo$,
      now()));

  PERFORM public._migvb_ancla(v_fn,
$ancla$WHERE p.estado='entregado' AND p.canal<>'cambio' AND NOT pi.es_bonificacion AND (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva=0)$ancla$,
$nuevo$WHERE p.estado='entregado' AND p.canal<>'cambio' AND COALESCE(p.tipo_factura,'ZZ')<>'VB' AND NOT pi.es_bonificacion AND (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva=0)$nuevo$);

  PERFORM public._migvb_ancla(v_fn,
$ancla$COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado='entregado'),0) AS cob$ancla$,
$nuevo$COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado='entregado' AND COALESCE(p.tipo_factura,'ZZ')<>'VB'),0) AS cob$nuevo$);
END
$patch$;

DROP FUNCTION public._migvb_ancla(regprocedure, text, text, int);

-- ===========================================================================
-- El ensayo: los caminos del VB con datos sintéticos, y se revierte todo.
-- ===========================================================================
-- Corre como el admin activo con sucursal default de id más chico (las RPCs
-- exigen auth.uid() y current_sucursal_id()). Todo pasa dentro de un bloque
-- que termina SIEMPRE con una excepción centinela: Postgres revierte el
-- subbloque entero (pedidos, stock, saldos, GUCs) y las variables de plpgsql
-- sobreviven para reportar. Lo único que no vuelve atrás son los valores de
-- las secuencias (quedan huecos de ids en clientes/productos/pedidos/pagos).
-- Si alguna comprobación falla, la migración entera se cae, como en la 241.
-- Caminos: rechazo de un VB con precios (PWA viejo) · crear VB · cancelar VB ·
-- ZZ→VB y VB→ZZ con saldo y CC-A ·
-- rechazo de pago a un VB · rechazo de 'vale_blanco' (pago y pedido) ·
-- rechazo de VB a un cliente no habilitado.
DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_caja    date;
  v_cli_vb  bigint;
  v_cli_zz  bigint;
  v_prod    bigint;
  v_res     jsonb;
  v_vb1     bigint;
  v_vb2     bigint;
  v_zz      bigint;
  v_ped     record;
  v_it      record;
  v_num     numeric;
  v_int     integer;
  v_err     text;
  v_fallas  text := '';
  v_pasos   int  := 0;
BEGIN
  BEGIN
    SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
      FROM usuario_sucursales us
      JOIN perfiles pf ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
     WHERE us.es_default
     ORDER BY us.sucursal_id, us.usuario_id
     LIMIT 1;
    IF v_admin IS NULL THEN
      RAISE EXCEPTION 'migvb · el ensayo necesita un admin activo con sucursal default';
    END IF;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    -- El mínimo de compra de la sucursal no es lo que se ensaya (el ZZ de prueba
    -- es chico). Un VB no lo necesita: lo saltea solo.
    PERFORM set_config('app.omitir_minimo_pedido', '1', true);
    v_caja := public.ultima_fecha_caja_cerrada(v_suc);

    INSERT INTO clientes (nombre_fantasia, razon_social, direccion, sucursal_id, tipo_factura_default)
    VALUES ('migvb ensayo VB', 'migvb ensayo VB', 's/d', v_suc, 'VB') RETURNING id INTO v_cli_vb;
    INSERT INTO clientes (nombre_fantasia, razon_social, direccion, sucursal_id, tipo_factura_default)
    VALUES ('migvb ensayo ZZ', 'migvb ensayo ZZ', 's/d', v_suc, 'ZZ') RETURNING id INTO v_cli_zz;
    -- Costo con tres decimales a propósito: el precio del VB es round(costo, 2).
    INSERT INTO productos (nombre, precio, sucursal_id, stock, costo_promedio, porcentaje_iva, activo)
    VALUES ('migvb ensayo producto', 1000, v_suc, 100, 612.345, 21, true) RETURNING id INTO v_prod;

    -- ---- 0 · un VB con precios (PWA viejo) se rechaza sin escribir nada
    v_res := public.crear_pedido_completo(v_cli_vb, 2000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2, 'precio_unitario', 1000)),
      'ensayo', 'efectivo', 'pendiente', v_hoy, 'VB', NULL, 0, NULL, NULL);
    v_pasos := v_pasos + 1;
    IF COALESCE((v_res->>'success')::boolean, true)
       OR COALESCE(v_res->>'errores', '') NOT ILIKE '%desactualizada%'
       OR EXISTS (SELECT 1 FROM pedidos WHERE cliente_id = v_cli_vb) THEN
      v_fallas := v_fallas || ' [0 VB con precios de un PWA viejo: ' || v_res::text || ']';
    END IF;

    -- ---- 1 · crear un VB (como el front nuevo: total 0 y precio 0; forma y
    --          estado de pago del caller se ignoran)
    v_res := public.crear_pedido_completo(v_cli_vb, 0, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2, 'precio_unitario', 0)),
      'ensayo', 'transferencia', 'pendiente', v_hoy, 'VB', NULL, 0, NULL, NULL);
    v_pasos := v_pasos + 1;
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      v_fallas := v_fallas || ' [1 crear VB: ' || v_res::text || ']';
    ELSE
      v_vb1 := (v_res->>'pedido_id')::bigint;
      IF (v_res->>'total')::numeric IS DISTINCT FROM 1224.70 THEN
        v_fallas := v_fallas || ' [1 total devuelto ' || COALESCE(v_res->>'total', 'NULL') || ' <> 1224.70]';
      END IF;
      SELECT * INTO v_ped FROM pedidos WHERE id = v_vb1;
      IF v_ped.tipo_factura <> 'VB' OR v_ped.estado <> 'entregado' OR v_ped.estado_pago <> 'pagado'
         OR v_ped.total <> 1224.70 OR v_ped.monto_pagado <> v_ped.total OR v_ped.total_iva <> 0
         OR v_ped.total_real <> v_ped.total OR v_ped.total_neto <> v_ped.total
         OR v_ped.transportista_id IS NOT NULL OR v_ped.fecha_entrega IS NULL
         OR v_ped.fecha_entrega_programada IS DISTINCT FROM v_hoy
         OR v_ped.forma_pago IS DISTINCT FROM 'efectivo' THEN
        v_fallas := v_fallas || ' [1 pedido VB incoherente: ' || to_jsonb(v_ped)::text || ']';
      END IF;
      SELECT * INTO v_it FROM pedido_items WHERE pedido_id = v_vb1;
      IF v_it.precio_unitario <> 612.35 OR v_it.subtotal <> 1224.70
         OR v_it.origen_precio IS DISTINCT FROM 'costo_interno'
         OR v_it.costo_unitario_al_crear IS DISTINCT FROM 612.345
         OR v_it.iva_unitario <> 0 OR v_it.neto_unitario <> 612.35 OR v_it.ingreso_real_unitario <> 612.35 THEN
        v_fallas := v_fallas || ' [1 linea VB: ' || to_jsonb(v_it)::text || ']';
      END IF;
      SELECT stock INTO v_int FROM productos WHERE id = v_prod;
      IF v_int <> 98 THEN v_fallas := v_fallas || ' [1 stock ' || v_int || ' <> 98]'; END IF;
      SELECT COALESCE(saldo_cuenta, 0) INTO v_num FROM clientes WHERE id = v_cli_vb;
      IF v_num <> 0 THEN v_fallas := v_fallas || ' [1 saldo del cliente VB ' || v_num || ' <> 0]'; END IF;
    END IF;

    -- ---- 2 · cancelar el VB (admin, aunque esté entregado): stock vuelve, 0 y 0
    IF v_vb1 IS NOT NULL THEN
      v_res := public.cancelar_pedido_con_stock(v_vb1, 'ensayo migvb', v_admin, NULL);
      v_pasos := v_pasos + 1;
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        v_fallas := v_fallas || ' [2 cancelar VB: ' || v_res::text || ']';
      ELSE
        SELECT * INTO v_ped FROM pedidos WHERE id = v_vb1;
        IF v_ped.estado <> 'cancelado' OR v_ped.total <> 0 OR v_ped.monto_pagado <> 0
           OR v_ped.estado_pago <> 'pagado' THEN
          v_fallas := v_fallas || ' [2 VB cancelado incoherente: ' || to_jsonb(v_ped)::text || ']';
        END IF;
        SELECT stock INTO v_int FROM productos WHERE id = v_prod;
        IF v_int <> 100 THEN v_fallas := v_fallas || ' [2 stock ' || v_int || ' <> 100]'; END IF;
      END IF;
    END IF;

    -- ---- 3 · ZZ → VB: un ZZ normal a un cliente VB (N3), y después se convierte
    v_res := public.crear_pedido_completo(v_cli_vb, 3000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 3, 'precio_unitario', 1000)),
      'ensayo', 'efectivo', 'pendiente', v_hoy, 'ZZ', NULL, 0, NULL, NULL);
    v_pasos := v_pasos + 1;
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      v_fallas := v_fallas || ' [3 crear ZZ: ' || v_res::text || ']';
    ELSE
      v_zz := (v_res->>'pedido_id')::bigint;
      SELECT COALESCE(saldo_cuenta, 0) INTO v_num FROM clientes WHERE id = v_cli_vb;
      IF v_num <> 3000 THEN v_fallas := v_fallas || ' [3 saldo con el ZZ ' || v_num || ' <> 3000]'; END IF;

      v_res := public.cambiar_tipo_factura_pedido(v_zz, 'VB', v_admin);
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        v_fallas := v_fallas || ' [3 ZZ->VB: ' || v_res::text || ']';
      ELSE
        SELECT * INTO v_ped FROM pedidos WHERE id = v_zz;
        IF v_ped.tipo_factura <> 'VB' OR v_ped.estado <> 'entregado' OR v_ped.estado_pago <> 'pagado'
           OR v_ped.total <> 1837.05 OR v_ped.monto_pagado <> v_ped.total
           OR v_ped.transportista_id IS NOT NULL OR v_ped.fecha_entrega IS NULL THEN
          v_fallas := v_fallas || ' [3 ZZ->VB incoherente: ' || to_jsonb(v_ped)::text || ']';
        END IF;
        IF EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_zz
                    AND (origen_precio IS DISTINCT FROM 'costo_interno' OR precio_unitario <> 612.35)) THEN
          v_fallas := v_fallas || ' [3 lineas no quedaron a costo]';
        END IF;
        SELECT COALESCE(saldo_cuenta, 0) INTO v_num FROM clientes WHERE id = v_cli_vb;
        IF v_num <> 0 THEN v_fallas := v_fallas || ' [3 saldo tras ZZ->VB ' || v_num || ' <> 0]'; END IF;
      END IF;
    END IF;

    -- ---- 4 · VB → ZZ: vuelve a lista, monto_pagado 0, pendiente, deuda 3000
    IF v_zz IS NOT NULL THEN
      v_res := public.cambiar_tipo_factura_pedido(v_zz, 'ZZ', v_admin);
      v_pasos := v_pasos + 1;
      IF v_caja IS NOT NULL AND v_caja >= v_hoy THEN
        -- La caja de hoy ya está cerrada en esta sucursal: lo correcto es el rechazo.
        IF COALESCE((v_res->>'success')::boolean, false) OR COALESCE(v_res->>'error', '') NOT ILIKE '%caja%' THEN
          v_fallas := v_fallas || ' [4 VB->ZZ con caja cerrada debia rechazarse: ' || v_res::text || ']';
        END IF;
      ELSIF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        v_fallas := v_fallas || ' [4 VB->ZZ: ' || v_res::text || ']';
      ELSE
        SELECT * INTO v_ped FROM pedidos WHERE id = v_zz;
        IF v_ped.tipo_factura <> 'ZZ' OR v_ped.estado <> 'entregado' OR v_ped.estado_pago <> 'pendiente'
           OR v_ped.total <> 3000 OR v_ped.monto_pagado <> 0 THEN
          v_fallas := v_fallas || ' [4 VB->ZZ incoherente: ' || to_jsonb(v_ped)::text || ']';
        END IF;
        IF EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_zz
                    AND (origen_precio IS DISTINCT FROM 'lista' OR precio_unitario <> 1000)) THEN
          v_fallas := v_fallas || ' [4 lineas no volvieron a lista]';
        END IF;
        SELECT COALESCE(saldo_cuenta, 0) INTO v_num FROM clientes WHERE id = v_cli_vb;
        IF v_num <> 3000 THEN v_fallas := v_fallas || ' [4 saldo tras VB->ZZ ' || v_num || ' <> 3000]'; END IF;
      END IF;
    END IF;

    -- CC-A de los dos clientes de prueba, con la fórmula del check.
    v_pasos := v_pasos + 1;
    IF EXISTS (
      SELECT 1 FROM clientes c
       WHERE c.id IN (v_cli_vb, v_cli_zz)
         AND abs(COALESCE(c.saldo_cuenta,0) - (
               COALESCE((SELECT sum(p.total-COALESCE(p.monto_pagado,0)) FROM pedidos p
                          WHERE p.cliente_id=c.id AND p.estado NOT IN ('cancelado','anulado')),0)
             - COALESCE((SELECT sum(pg.monto) FROM pagos pg WHERE pg.cliente_id=c.id AND pg.pedido_id IS NULL),0))) > 0.01) THEN
      v_fallas := v_fallas || ' [CC-A en rojo para un cliente de prueba]';
    END IF;

    -- ---- 5 · un pago a un VB se rechaza
    v_res := public.crear_pedido_completo(v_cli_vb, 0, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 0)),
      NULL, 'efectivo', 'pendiente', v_hoy, 'VB', NULL, 0, NULL, NULL);
    v_vb2 := (v_res->>'pedido_id')::bigint;
    v_pasos := v_pasos + 1;
    IF v_vb2 IS NULL THEN
      v_fallas := v_fallas || ' [5 crear el segundo VB: ' || v_res::text || ']';
    ELSE
      v_err := NULL;
      BEGIN
        INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
        VALUES (v_cli_vb, v_vb2, 10, 'efectivo', v_hoy, v_admin, v_suc);
      EXCEPTION WHEN OTHERS THEN
        v_err := SQLERRM;
      END;
      IF v_err IS NULL OR v_err NOT ILIKE '%vale blanco%' THEN
        v_fallas := v_fallas || ' [5 el pago a un VB no se rechazo (' || COALESCE(v_err, 'sin error') || ')]';
      END IF;
    END IF;

    -- ---- 6 · 'vale_blanco' ya no es forma de pago: ni en pagos ni en pedidos
    v_pasos := v_pasos + 1;
    v_err := NULL;
    BEGIN
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
      VALUES (v_cli_zz, NULL, 10, 'vale_blanco', v_hoy, v_admin, v_suc);
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
    END;
    IF v_err IS NULL OR v_err NOT ILIKE '%tipo de comprobante%' THEN
      v_fallas := v_fallas || ' [6 un pago vale_blanco no se rechazo (' || COALESCE(v_err, 'sin error') || ')]';
    END IF;

    v_err := NULL;
    BEGIN
      v_res := public.crear_pedido_completo(v_cli_zz, 1000, v_admin,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 1000)),
        NULL, 'vale_blanco', 'pendiente', v_hoy, 'ZZ', NULL, 0, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
    END;
    IF v_err IS NULL OR v_err NOT ILIKE '%tipo de comprobante%' THEN
      v_fallas := v_fallas || ' [6 un pedido con forma vale_blanco no se rechazo (' || COALESCE(v_err, v_res::text) || ')]';
    END IF;

    -- ---- 7 · un VB a un cliente no habilitado se rechaza, sin escribir nada
    v_res := public.crear_pedido_completo(v_cli_zz, 0, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 0)),
      NULL, 'efectivo', 'pendiente', v_hoy, 'VB', NULL, 0, NULL, NULL);
    v_pasos := v_pasos + 1;
    IF COALESCE((v_res->>'success')::boolean, true)
       OR COALESCE(v_res->>'errores', '') NOT ILIKE '%habilitado%'
       OR EXISTS (SELECT 1 FROM pedidos WHERE cliente_id = v_cli_zz) THEN
      v_fallas := v_fallas || ' [7 VB a cliente no habilitado: ' || v_res::text || ']';
    END IF;

    RAISE EXCEPTION 'migvb_ensayo_revertir';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM 'migvb_ensayo_revertir' THEN
      v_fallas := v_fallas || ' [error inesperado: ' || SQLERRM || ']';
    END IF;
  END;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'migvb · el ensayo FALLO:%', v_fallas;
  END IF;
  RAISE NOTICE 'migvb · ensayo OK: % caminos del vale blanco verificados y revertidos', v_pasos;
END
$ensayo$;

COMMIT;
