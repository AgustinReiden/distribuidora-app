-- =========================================================================
-- mig 407 · LA COMPRA CORREGIDA CORRIGE EL PROMEDIO
--           (#1251, #1252, #1253 y el orden de locks de compras de #1255)
--
-- PARCHE POR ANCLA, como la 236 y la 293: las cuatro RPCs de compras vienen
-- parchadas in situ por una cadena larga y `migrations/` no tiene su cuerpo
-- vivo. Los helpers de abajo leen `pg_get_functiondef` y fallan si un ancla no
-- aparece exactamente una vez.
--
-- =========================================================================
-- 1 · EDITAR UNA COMPRA RECALCULABA EL PROMEDIO CON EL STOCK DE HOY (#1251)
-- =========================================================================
-- `actualizar_compra_items` armaba la base del promedio con `p.stock - las
-- unidades de esta compra` (el stock VIVO) y `costo_promedio_anterior` (la foto
-- del ALTA). Todo lo que pasaba en el medio contaminaba la cuenta, y si el stock
-- de hoy menos la compra daba <= 0 el promedio saltaba entero al costo de la
-- factura. Medido en prod: la compra 6319 dejo el 275 en 3.420,01 (1 u. a
-- 3.231,91 + 12 a 3.435,69), se vendieron 2, y una edicion SIN CAMBIOS lo llevo a
-- 3.435,69. Ademas la edicion pisaba `stock_anterior` con el stock vivo y la foto
-- del alta se perdia; el producto que salia de la compra se quedaba con su
-- promedio y su reposicion; y el empate de fecha no desempataba por id.
--
-- Ahora:
--   · La base es la foto del alta: `stock_anterior` y `costo_promedio_anterior`
--     de la primera linea del producto. La edicion no la pisa, y las lineas
--     nuevas conservan el `created_at` del alta, que es su lugar en la cadena.
--   · El promedio se corrige POR DIFERENCIA: lo que dejan las lineas nuevas
--     menos lo que dejaban las viejas, las dos recorridas desde la misma foto. La
--     diferencia se arrastra por las compras del producto que entraron despues
--     (`_cpp_arrastrar`, con el stock corrido por las unidades que cambiaron) y
--     se le suma al promedio vivo. Lo que no es de esta compra —otra compra, una
--     correccion a mano en la ficha— queda como esta. Sin otros cambios en el
--     medio, el resultado es exactamente el promedio de la cadena corregida.
--   · El promedio deja de depender de que la compra sea la ultima por fecha: es
--     de la cadena de compras, no de la fecha de la factura. La REPOSICION si
--     sigue siendo de la ultima, ahora por (fecha, id) y sin contar regalos.
--   · Un producto que sale de la compra (o que queda solo como regalo) devuelve
--     el promedio por el mismo camino y, si esta compra fijaba su reposicion, la
--     reposicion vuelve a la compra anterior.
--
-- =========================================================================
-- 2 · ANULAR REVIERTE EL PROMEDIO (#1252, decision del dueño 2026-10-28)
-- =========================================================================
-- Anular es la edicion que saca todas las lineas: el promedio vuelve a la foto
-- del alta y la diferencia se arrastra por lo que entro despues. La reposicion
-- se restaura solo si esta compra era la que la fijaba (hasta aca se pisaba
-- siempre). Una compra anterior a la 236 no tiene foto: se avisa y el promedio
-- queda como esta, igual que en la edicion.
--
-- `cambiar_proveedor_compra` clonaba las lineas sin `costo_promedio_anterior`
-- (el clon quedaba "anterior a la 236" y no se podia corregir) y con
-- `created_at = now()`, que reiniciaba la ventana de 7 dias para editar. Ahora
-- copia la foto y las dos fechas de alta.
--
-- =========================================================================
-- 3 · LA REPOSICION Y LAS FACTURAS B Y C (#1253)
-- =========================================================================
-- · En `registrar_compra_completa`, la compra mas nueva que fija costo contaba
--   tambien los regalos: un regalo con fecha posterior trababa la reposicion.
-- · Las B y C cuestan lo pagado (mig 293) pero el producto quedaba con
--   `ultimo_tipo_compra = 'FC'`, y la ficha le recalculaba `costo_con_iva` como
--   a una FC: neto x (1 + IVA + II) sobre algo que se pago neto. Ahora el
--   producto guarda 'FC B' / 'FC C' (la columna pasa a varchar(4)) y la ficha
--   usa la formula de lo pagado. `aceptar_movimiento_sucursal` copia la columna
--   tal cual, asi que el producto que nace por transferencia la hereda.
--
-- =========================================================================
-- 4 · ORDEN DE LOCKS (#1255, la parte de compras)
-- =========================================================================
-- `registrar_compra_completa` bloqueaba los productos de a uno, en el orden de
-- la factura; la venta los bloquea juntos y en orden de id. Una compra [B, A]
-- contra una venta [A, B] se trababan (40P01). Ahora los bloquea todos, en orden
-- de id, antes del loop. `actualizar_compra_items` y `anular_compra_atomica` ya
-- lo hacian. El arrastre solo LEE las lineas de las otras compras: no toma
-- locks nuevos.
--
-- =========================================================================
-- 5 · LOS PROMEDIOS QUE YA QUEDARON MAL (decision del dueño 2026-10-28)
-- =========================================================================
-- Desde la 236 se editaron 6 compras. Reconstruido desde audit_logs:
--   · 6319 (editada el 20/10 sin cambiar ninguna linea): 12 productos con el
--     promedio corrido; vuelven al del alta. Nada entro despues.
--   · 298 (editada el 06/10 y el 07/10; las lineas solo cambiaron en el cuarto
--     decimal del costo): 6 productos corridos, y la compra 6321 (20/10) se armo
--     sobre ese promedio. 140, 142, 144 y 147 se recalculan con la 6321
--     arriba; en 139 y 145 la 6321 entro sobre stock 0 y ya los habia reseteado.
--     Las fotos de la 6321 pasan al promedio corregido.
--   · 285, 6320, 6326 y 6330: el promedio quedo bien.
-- Y las lineas de toda compra editada recuperan la foto del alta (stock y
-- created_at), sacada de la auditoria de esa misma transaccion.
--
-- LO QUE NO SE TOCA
-- -----------------
-- · El motor de prorrateo (`calcular_costos_compra`, `prorratear_cargo`,
--   `src/utils/prorrateoCompra.ts`) ni su espejo: el bloque de verificacion
--   comprueba que su cuerpo no cambio.
-- · `sincronizar_lotes_compra`, `_clampear_lotes_a_stock` y
--   `auditoria_integridad()` (tarjeta 4 de #1268).
-- · El orden de la 229 en la anulacion (cancelar antes de bajar el stock).
-- · Transferencias entre sucursales: el arrastre no las ve. Una transferencia
--   que entro despues de la compra corregida diluiria la diferencia y aca no la
--   diluye; queda sumada entera.
-- =========================================================================

BEGIN;

-- El ALTER TABLE productos de la seccion 11 espera el lock exclusivo: si una
-- transaccion larga lo tiene, que falle en vez de dejar la tabla trabada.
SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Los helpers de cirugia sobre el cuerpo vivo (mismo molde que la 293).
-- -------------------------------------------------------------------------

-- Varios reemplazos de anclas exactas sobre el MISMO cuerpo, aplicados en
-- memoria y ejecutados una sola vez. Cada ancla tiene que aparecer exactamente
-- una vez en el cuerpo que va quedando.
CREATE OR REPLACE FUNCTION public._mig407_anclas(p_funcion regprocedure, p_pares text[])
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
  i       int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  FOR i IN 1 .. array_length(p_pares, 1) / 2 LOOP
    v_veces := (length(v_def) - length(replace(v_def, p_pares[2*i - 1], ''))) / length(p_pares[2*i - 1]);
    IF v_veces <> 1 THEN
      RAISE EXCEPTION 'El ancla % aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
        i, v_veces, p_funcion, left(p_pares[2*i - 1], 120);
    END IF;
    v_def := replace(v_def, p_pares[2*i - 1], p_pares[2*i]);
  END LOOP;
  EXECUTE v_def;
END;
$fn$;

-- Reemplazo de una REGION: desde la marca de apertura (incluida) hasta la de
-- cierre (excluida). Las dos marcas son de un renglon y tienen que aparecer una
-- sola vez; el texto del medio se toma del cuerpo vivo, no se transcribe.
CREATE OR REPLACE FUNCTION public._mig407_region(
  p_funcion regprocedure,
  p_desde   text,
  p_hasta   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_ini   int;
  v_fin   int;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);

  v_veces := (length(v_def) - length(replace(v_def, p_desde, ''))) / length(p_desde);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'La marca de apertura aparece % veces en % (se esperaba 1): %',
      v_veces, p_funcion, left(p_desde, 120);
  END IF;
  v_veces := (length(v_def) - length(replace(v_def, p_hasta, ''))) / length(p_hasta);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'La marca de cierre aparece % veces en % (se esperaba 1): %',
      v_veces, p_funcion, left(p_hasta, 120);
  END IF;

  v_ini := position(p_desde in v_def);
  v_fin := position(p_hasta in v_def);
  IF v_fin <= v_ini THEN
    RAISE EXCEPTION 'En % la marca de cierre esta antes de la de apertura.', p_funcion;
  END IF;

  EXECUTE left(v_def, v_ini - 1) || p_nuevo || substr(v_def, v_fin);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · El tipo de la ultima compra sabe de la letra (#1253). La columna se
--     ensancha al final (seccion 11): el ALTER TABLE toma un lock exclusivo de
--     productos hasta el COMMIT, y asi lo tiene lo menos posible.
-- -------------------------------------------------------------------------

-- Lo que se guarda en productos.ultimo_tipo_compra para una compra.
CREATE OR REPLACE FUNCTION public._tipo_compra_producto(p_tipo_factura text, p_letra text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = public
AS $fn$
  SELECT CASE
    WHEN p_tipo_factura = 'ZZ' THEN 'ZZ'
    WHEN upper(btrim(COALESCE(p_letra, ''))) IN ('B', 'C') THEN 'FC ' || upper(btrim(p_letra))
    ELSE 'FC'
  END;
$fn$;

-- -------------------------------------------------------------------------
-- 2 · La formula del promedio, una sola vez.
-- -------------------------------------------------------------------------

-- ¿La linea fija costo? Un regalo (bonificacion 100%) o un costo 0 suma stock
-- y diluye el promedio, pero no es costo de reposicion de nadie. Es el
-- `v_actualiza_costo` de las RPCs, leido de una linea guardada.
CREATE OR REPLACE FUNCTION public._cpp_fija_costo(p_bonificacion numeric, p_costo_neto numeric, p_costo_unitario numeric)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = public
AS $fn$
  SELECT COALESCE(p_bonificacion, 0) < 100
     AND COALESCE(p_costo_neto,
                  COALESCE(p_costo_unitario, 0) * (1 - COALESCE(p_bonificacion, 0) / 100)) > 0;
$fn$;

-- El promedio despues de UNA linea, desde el stock y el promedio de justo antes.
-- Es la cuenta del alta desde la 128 (y la de los regalos desde la 227), sin
-- cambiar un decimal: la usan el alta, la edicion, la anulacion y el arrastre,
-- asi que las cuatro cuentan igual por construccion.
--   · fija costo: sin stock o sin promedio previo, el promedio es el costo de la
--     linea; si no, el ponderado.
--   · regalo: diluye el promedio que habia; sin promedio que diluir, no lo toca.
CREATE OR REPLACE FUNCTION public._cpp_linea(
  p_stock      numeric,
  p_cpp        numeric,
  p_cantidad   numeric,
  p_costo_real numeric,
  p_fija_costo boolean
) RETURNS numeric
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = public
AS $fn$
  SELECT CASE
    WHEN p_fija_costo THEN
      CASE WHEN p_stock <= 0 OR p_cpp IS NULL OR p_cpp <= 0 THEN p_costo_real
           ELSE round((p_stock * p_cpp + p_cantidad * p_costo_real) / (p_stock + p_cantidad), 4)
      END
    WHEN p_stock > 0 AND COALESCE(p_cpp, 0) > 0
      THEN round((p_stock * p_cpp) / (p_stock + p_cantidad), 4)
    ELSE p_cpp
  END;
$fn$;

-- -------------------------------------------------------------------------
-- 3 · La foto de una compra.
-- -------------------------------------------------------------------------

-- El promedio que dejan las lineas GUARDADAS de un producto en una compra,
-- recorridas desde un stock y un promedio de partida.
CREATE OR REPLACE FUNCTION public._cpp_recorrer_compra(
  p_compra   bigint,
  p_producto bigint,
  p_sucursal bigint,
  p_stock    numeric,
  p_cpp      numeric
) RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $fn$
DECLARE
  r     record;
  v_s   numeric := p_stock;
  v_cpp numeric := p_cpp;
BEGIN
  FOR r IN
    SELECT ci.cantidad,
           COALESCE(ci.costo_real_unitario, ci.costo_neto_unitario,
                    ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)) AS costo,
           public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario) AS fija
      FROM compra_items ci
     WHERE ci.compra_id = p_compra
       AND ci.producto_id = p_producto
       AND ci.sucursal_id = p_sucursal
     ORDER BY ci.id
  LOOP
    v_cpp := public._cpp_linea(v_s, v_cpp, r.cantidad, r.costo, r.fija);
    v_s   := v_s + r.cantidad;
  END LOOP;
  RETURN v_cpp;
END;
$fn$;

-- Por producto de una compra: la foto del alta (de su PRIMERA linea), su lugar
-- en la cadena (`created_at` de sus lineas, que la edicion conserva), las
-- unidades, el promedio que dejan sus lineas recorridas desde la foto, y si
-- alguna fija costo. `c0` NULL es una compra anterior a la 236: no hay foto.
CREATE OR REPLACE FUNCTION public._cpp_foto_compra(p_compra bigint, p_sucursal bigint)
RETURNS TABLE (
  producto_id bigint,
  s0          integer,
  c0          numeric,
  ts          timestamptz,
  q           integer,
  cpp_despues numeric,
  pagaba      boolean
)
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT f.producto_id, f.s0, f.c0, f.ts, f.q,
         CASE WHEN f.c0 IS NOT NULL
              THEN public._cpp_recorrer_compra(p_compra, f.producto_id, p_sucursal, f.s0, f.c0)
         END,
         f.pagaba
    FROM (
      SELECT ci.producto_id,
             (array_agg(ci.stock_anterior ORDER BY ci.id))[1]          AS s0,
             (array_agg(ci.costo_promedio_anterior ORDER BY ci.id))[1] AS c0,
             min(ci.created_at)                                        AS ts,
             sum(ci.cantidad)::integer                                 AS q,
             bool_or(public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario)) AS pagaba
        FROM compra_items ci
       WHERE ci.compra_id = p_compra
         AND ci.sucursal_id = p_sucursal
       GROUP BY ci.producto_id
    ) f;
$fn$;

-- -------------------------------------------------------------------------
-- 4 · El arrastre por las compras posteriores, y la correccion del vivo.
-- -------------------------------------------------------------------------

-- Recorre las lineas del producto que entraron DESPUES de esta compra (por
-- `created_at`, y por compra en el empate), en dos historias a la vez:
--   · la vieja, la que paso: cada linea arranca de su propia foto;
--   · la nueva, la corregida: la misma foto corrida por la diferencia que trae
--     la cadena, y el stock corrido por las unidades que cambiaron.
-- Devuelve el promedio final de las dos. El llamador le suma al promedio vivo
-- la diferencia (`_cpp_corregido`). Arrancar cada linea de su foto, y no del
-- valor de la cadena, es lo que respeta lo que no es de esta compra: una
-- correccion a mano en la ficha queda en la foto de la compra siguiente.
-- Solo lee: el producto ya esta bloqueado por el llamador, y todo el que
-- escribe lineas de este producto lo bloquea primero.
CREATE OR REPLACE FUNCTION public._cpp_arrastrar(
  p_producto    bigint,
  p_sucursal    bigint,
  p_compra      bigint,
  p_desde       timestamptz,
  p_delta_stock integer,
  p_cpp_viejo   numeric,
  p_cpp_nuevo   numeric,
  OUT cpp_viejo numeric,
  OUT cpp_nuevo numeric
)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $fn$
DECLARE
  r             record;
  v_antes_viejo numeric;
  v_antes_nuevo numeric;
BEGIN
  cpp_viejo := p_cpp_viejo;
  cpp_nuevo := p_cpp_nuevo;

  FOR r IN
    SELECT ci.stock_anterior, ci.costo_promedio_anterior, ci.cantidad,
           COALESCE(ci.costo_real_unitario, ci.costo_neto_unitario,
                    ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)) AS costo,
           public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario) AS fija
      FROM compra_items ci
      JOIN compras c ON c.id = ci.compra_id AND c.sucursal_id = ci.sucursal_id
     WHERE ci.producto_id = p_producto
       AND ci.sucursal_id = p_sucursal
       AND ci.compra_id <> p_compra
       AND c.estado <> 'cancelada'
       AND (ci.created_at, ci.compra_id) > (p_desde, p_compra)
     ORDER BY ci.created_at, ci.compra_id, ci.id
  LOOP
    -- La foto de la linea; una linea anterior a la 236 no la tiene y toma el
    -- valor de la cadena.
    v_antes_viejo := COALESCE(r.costo_promedio_anterior, cpp_viejo);
    v_antes_nuevo := CASE
      -- la historia nueva no tiene promedio: la linea arranca de cero
      WHEN COALESCE(cpp_nuevo, 0) <= 0 THEN 0
      -- la vieja no tenia: no hay diferencia que sumar, vale la nueva
      WHEN COALESCE(cpp_viejo, 0) <= 0 OR v_antes_viejo IS NULL THEN cpp_nuevo
      ELSE GREATEST(v_antes_viejo + (cpp_nuevo - cpp_viejo), 0)
    END;
    cpp_viejo := public._cpp_linea(r.stock_anterior, v_antes_viejo, r.cantidad, r.costo, r.fija);
    cpp_nuevo := public._cpp_linea(r.stock_anterior + p_delta_stock, v_antes_nuevo, r.cantidad, r.costo, r.fija);
  END LOOP;
END;
$fn$;

-- El promedio vivo corregido por la diferencia entre la historia nueva y la
-- vieja. Sin otros cambios en el medio el vivo ES el viejo y queda el nuevo
-- exacto. Si la historia nueva no tiene promedio (se anulo la unica compra que
-- lo daba), NULL: un 0 lo leeria `costo_valuacion` como costo cero.
CREATE OR REPLACE FUNCTION public._cpp_corregido(p_vivo numeric, p_viejo numeric, p_nuevo numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = public
AS $fn$
  SELECT CASE
    WHEN p_nuevo IS NULL OR p_nuevo <= 0 THEN NULL
    WHEN p_vivo IS NULL OR p_vivo <= 0 OR p_viejo IS NULL OR p_viejo <= 0 THEN p_nuevo
    WHEN p_vivo + (p_nuevo - p_viejo) <= 0 THEN p_nuevo
    ELSE round(p_vivo + (p_nuevo - p_viejo), 4)
  END;
$fn$;

-- -------------------------------------------------------------------------
-- 5 · La reposicion: de la ultima compra que fija costo, por (fecha, id).
-- -------------------------------------------------------------------------

-- ¿Ninguna otra compra viva tiene una linea de este producto que fije costo y
-- sea mas nueva que esta? Mas nueva es por (fecha_compra, id), como la mig 400 y
-- `desgloseCostoCompra`; los regalos no cuentan (#1253).
CREATE OR REPLACE FUNCTION public._ninguna_compra_mas_nueva(p_compra bigint, p_producto bigint, p_sucursal bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT NOT EXISTS (
    SELECT 1
      FROM compras yo
      JOIN compras c ON c.sucursal_id = yo.sucursal_id
      JOIN compra_items ci ON ci.compra_id = c.id AND ci.sucursal_id = c.sucursal_id
     WHERE yo.id = p_compra
       AND ci.producto_id = p_producto
       AND ci.sucursal_id = p_sucursal
       AND c.id <> p_compra
       AND c.estado <> 'cancelada'
       AND public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario)
       AND (c.fecha_compra, c.id) > (yo.fecha_compra, yo.id)
  );
$fn$;

-- El costo de reposicion desde la ultima compra viva que fija costo. Es el
-- cuerpo que tenia `anular_compra_atomica` (mig 115) con dos cambios: el orden
-- desempata tambien por linea, y las B y C se calculan como lo pagado (mig 293)
-- y dejan 'FC B' / 'FC C'. Devuelve false si no hay ninguna.
CREATE OR REPLACE FUNCTION public._reposicion_desde_ultima_compra(p_producto bigint, p_sucursal bigint)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_ult  record;
  v_neto numeric;
  v_tipo text;
BEGIN
  SELECT c.tipo_factura, c.letra_comprobante, ci.costo_unitario, ci.bonificacion,
         ci.impuestos_internos AS ii_linea, ci.porcentaje_iva AS iva_linea,
         ci.costo_neto_unitario, ci.costo_real_unitario
    INTO v_ult
    FROM compra_items ci
    JOIN compras c ON c.id = ci.compra_id AND c.sucursal_id = ci.sucursal_id
   WHERE ci.producto_id = p_producto
     AND ci.sucursal_id = p_sucursal
     AND c.estado <> 'cancelada'
     AND public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario)
   ORDER BY c.fecha_compra DESC, c.id DESC, ci.id DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_neto := COALESCE(v_ult.costo_neto_unitario,
                     v_ult.costo_unitario * (1 - COALESCE(v_ult.bonificacion, 0) / 100));
  -- el tipo que ven las formulas: 'ZZ' cuando lo pagado es el costo (ZZ, B, C)
  v_tipo := CASE WHEN public._tipo_compra_producto(v_ult.tipo_factura, v_ult.letra_comprobante) = 'FC'
                 THEN 'FC' ELSE 'ZZ' END;

  UPDATE productos p
     SET costo_sin_iva      = v_neto,
         costo_real         = COALESCE(v_ult.costo_real_unitario,
                                public.costo_real_unitario(v_neto, COALESCE(v_ult.ii_linea, p.impuestos_internos), v_tipo, 0)),
         costo_con_iva      = public.costo_financiero_unitario(
                                v_neto,
                                COALESCE(v_ult.iva_linea, p.porcentaje_iva),
                                COALESCE(v_ult.ii_linea, p.impuestos_internos),
                                v_tipo),
         ultimo_tipo_compra = public._tipo_compra_producto(v_ult.tipo_factura, v_ult.letra_comprobante),
         updated_at         = NOW()
   WHERE p.id = p_producto AND p.sucursal_id = p_sucursal;

  RETURN true;
END;
$fn$;

-- -------------------------------------------------------------------------
-- 6 · registrar_compra_completa
-- -------------------------------------------------------------------------
SELECT public._mig407_anclas(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure,
  ARRAY[
-- 6.1 · los productos, todos juntos y en orden de id, antes del loop (#1255)
$a$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
$a$,
$b$  /* mig 407 (#1255) · LOS PRODUCTOS SE BLOQUEAN TODOS, EN ORDEN DE ID, ANTES
     DEL LOOP. La venta los bloquea asi (crear_pedido_completo); aca se tomaban
     de a uno en el orden de la factura, y una compra [B, A] contra una venta
     [A, B] se trababan (40P01). El SELECT ... FOR UPDATE del loop queda: ya
     tiene el lock y no espera. */
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT (e->>'producto_id')::BIGINT
                  FROM jsonb_array_elements(p_items) AS e)
   ORDER BY id
   FOR UPDATE;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
$b$,
-- 6.2 · la compra mas nueva que fija costo no cuenta regalos (#1253)
$a$       AND c.estado <> 'cancelada'
       AND c.id <> v_compra_id;
$a$,
$b$       AND c.estado <> 'cancelada'
       AND c.id <> v_compra_id
       /* mig 407 (#1253) · solo las lineas que fijan costo: un regalo con
          fecha posterior no es el costo de reposicion de nadie. */
       AND _cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario);
$b$,
-- 6.3 · la formula del promedio, de _cpp_linea
$a$      IF v_stock_anterior <= 0 OR v_producto.costo_promedio IS NULL OR v_producto.costo_promedio <= 0 THEN
        v_costo_promedio := v_costo_real;
      ELSE
        v_costo_promedio := round(
          (v_stock_anterior::NUMERIC * v_producto.costo_promedio + v_cantidad * v_costo_real)
          / (v_stock_anterior + v_cantidad), 4);
      END IF;
$a$,
$b$      /* mig 407 · la cuenta vive en _cpp_linea: la misma que recorren la
         edicion, la anulacion y el arrastre. */
      v_costo_promedio := _cpp_linea(v_stock_anterior, v_producto.costo_promedio, v_cantidad, v_costo_real, true);
$b$,
$a$      IF v_stock_anterior > 0 AND COALESCE(v_producto.costo_promedio, 0) > 0 THEN
        v_costo_promedio := round(
          (v_stock_anterior::NUMERIC * v_producto.costo_promedio)
          / (v_stock_anterior + v_cantidad), 4);
      ELSE
        v_costo_promedio := v_producto.costo_promedio;
      END IF;
$a$,
$b$      v_costo_promedio := _cpp_linea(v_stock_anterior, v_producto.costo_promedio, v_cantidad, v_costo_real, false);
$b$,
-- 6.4 · el producto guarda la letra B/C (#1253)
$a$               ultimo_tipo_compra = v_tipo_factura,
$a$,
$b$               ultimo_tipo_compra = _tipo_compra_producto(v_tipo_factura, v_letra),  /* mig 407 */
$b$
  ]
);

-- -------------------------------------------------------------------------
-- 7 · actualizar_compra_items
-- -------------------------------------------------------------------------

-- 7.1 · Las variables nuevas, y el lugar en la cadena de las lineas nuevas.
SELECT public._mig407_anclas(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  ARRAY[
$a$  v_suma_items       NUMERIC;   -- #1077
$a$,
$b$  v_suma_items       NUMERIC;   -- #1077
  -- mig 407 (#1251)
  v_base             JSONB := '{}'::JSONB;  -- producto -> _cpp_foto_compra de las lineas viejas
  v_b                JSONB;
  v_prod_txt         TEXT;
  v_cadena           RECORD;
  v_cpp_final        NUMERIC;
  v_tipo_producto    TEXT;
  v_warnings_repos   JSONB := '[]'::JSONB;
$b$,
$a$      costo_promedio_anterior /* mig 236 */
    ) VALUES (
$a$,
$b$      costo_promedio_anterior /* mig 236 */,
      created_at /* mig 407: el lugar en la cadena */
    ) VALUES (
$b$,
$a$      v_cpp_persistir /* mig 236 */
    )
    RETURNING id INTO v_item_id;
$a$,
$b$      v_cpp_persistir /* mig 236 */,
      COALESCE((v_base -> v_prod_txt ->> 'ts')::TIMESTAMPTZ, now())
    )
    RETURNING id INTO v_item_id;
$b$,
$a$    'warnings', NULL,
$a$,
$b$    'warnings', CASE WHEN jsonb_array_length(v_warnings_repos) > 0
                     THEN v_warnings_repos ELSE NULL END,  /* mig 407 */
$b$
  ]
);

-- 7.2 · La base del promedio: la foto del alta.
SELECT public._mig407_region(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
$a$  /* mig 236 · EL PROMEDIO PREVIO A ESTA COMPRA.
$a$,
$a$  WITH viejos AS (
$a$,
$b$  /* mig 407 (#1251) · LA BASE DEL PROMEDIO ES LA FOTO DEL ALTA, NO EL STOCK DE
     HOY.

     Hasta la 407 la base era `p.stock - las unidades de esta compra` —el stock
     de HOY— con `costo_promedio_anterior`, que es la foto del ALTA: las ventas,
     mermas y compras del medio contaminaban la cuenta, y con el stock de hoy
     menos la compra <= 0 el promedio saltaba al costo de la factura. Medido: la
     6319 dejo el 275 en 3.420,01, se vendieron 2, y una edicion sin cambios lo
     llevo a 3.435,69.

     Ahora, por producto de la compra vieja: la foto de su primera linea
     (`stock_anterior` y `costo_promedio_anterior`, las dos del alta), su lugar
     en la cadena y el promedio que dejaban sus lineas viejas recorridas desde
     esa foto. Las lineas nuevas se recorren desde la MISMA foto, y despues del
     loop la diferencia se arrastra por lo que entro despues y se le suma al
     promedio vivo.

     Un producto que se agrega en esta edicion entra AHORA, no en el alta: su
     base es el stock y el promedio de hoy, como en el alta. */
  SELECT COALESCE(jsonb_object_agg(f.producto_id::TEXT, to_jsonb(f)), '{}'::JSONB)
    INTO v_base
    FROM _cpp_foto_compra(p_compra_id, v_sucursal) f;

  SELECT COALESCE(jsonb_object_agg(e.key, COALESCE(v_base -> e.key -> 's0', e.value)), '{}'::JSONB)
    INTO v_stock_previo_map
    FROM jsonb_each(COALESCE(v_snapshot_stock, '{}'::JSONB)) e;

  SELECT COALESCE(jsonb_object_agg(e.key,
           CASE WHEN v_base ? e.key THEN v_base -> e.key -> 'c0' ELSE e.value END), '{}'::JSONB)
    INTO v_cpp_map
    FROM jsonb_each(COALESCE(v_cpp_map, '{}'::JSONB)) e;

  v_tipo_producto := _tipo_compra_producto(v_compra.tipo_factura, v_compra.letra_comprobante);  /* #1253 */

$b$
);

-- 7.3 · La foto de cada linea nueva.
SELECT public._mig407_region(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
$a$    v_stock_anterior := COALESCE((v_snapshot_stock->>v_producto_id::TEXT)::INTEGER, 0);
$a$,
$a$    v_costo_neto    := v_costo_unitario * (1 - v_bonificacion / 100);
$a$,
$b$    /* mig 407 (#1251) · la foto de la linea es el estado JUSTO ANTES de ella
       en la cadena del producto: la del alta, corrida por las lineas anteriores
       del mismo producto en esta compra (o la de hoy si el producto entra en
       esta edicion). Ya no se pisa con el stock vivo. `v_cpp_hay_previo` es
       falso solo si el producto ya estaba en la compra y su linea vieja no
       guardo el promedio (compra anterior a la mig 236). */
    v_prod_txt       := v_producto_id::TEXT;
    v_stock_previo   := COALESCE((v_stock_previo_map->>v_prod_txt)::NUMERIC, 0);
    v_cpp_hay_previo := COALESCE(jsonb_typeof(v_cpp_map -> v_prod_txt) = 'number', false);
    v_cpp_persistir  := CASE WHEN v_cpp_hay_previo THEN (v_cpp_map->>v_prod_txt)::NUMERIC END;
    v_stock_anterior := v_stock_previo::INTEGER;
    v_stock_nuevo    := v_stock_anterior + v_cantidad;

$b$
);

-- 7.4 · El promedio corrido y la reposicion de cada linea.
SELECT public._mig407_region(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
$a$    SELECT MAX(c.fecha_compra) INTO v_max_fecha
$a$,
$a$    v_items_procesados := v_items_procesados || jsonb_build_object(
$a$,
$b$    /* mig 407 (#1251) · el promedio corrido. Al producto se le aplica una sola
       vez, despues del loop, con lo que entro despues arrastrado. Ya no depende
       de que esta sea la ultima compra: el promedio es de la cadena de compras,
       no de la fecha de la factura. La linea, haya fijado costo o no, pesa en la
       base de la siguiente linea del mismo producto. */
    IF v_cpp_hay_previo THEN
      v_costo_promedio := _cpp_linea(v_stock_previo, v_cpp_persistir, v_cantidad, v_costo_real, v_actualiza_costo);
      v_cpp_map := jsonb_set(v_cpp_map, ARRAY[v_prod_txt], COALESCE(to_jsonb(v_costo_promedio), '0'::JSONB));
    END IF;
    v_stock_previo_map := jsonb_set(v_stock_previo_map, ARRAY[v_prod_txt],
                                    to_jsonb(v_stock_previo + v_cantidad));

    /* La REPOSICION es de la ultima compra que fija costo, por (fecha, id) y
       sin contar regalos (#1251 CMP-4, #1253 CMP-6). Hasta la 407 era
       `fecha >= max(fecha)`: dos facturas del mismo dia se pisaban. */
    v_es_mas_reciente := _ninguna_compra_mas_nueva(p_compra_id, v_producto_id, v_sucursal);

    IF v_es_mas_reciente AND v_actualiza_costo THEN
      UPDATE productos
         SET costo_sin_iva      = v_costo_neto,
             costo_con_iva      = v_costo_con_iva,
             costo_real         = v_costo_real,
             ultimo_tipo_compra = v_tipo_producto,
             updated_at         = NOW()
       WHERE id = v_producto_id AND sucursal_id = v_sucursal;

      v_costo_actualizado := v_costo_actualizado || jsonb_build_object(
        'producto_id', v_producto_id,
        'costo_sin_iva', v_costo_neto,
        'costo_con_iva', v_costo_con_iva,
        'costo_real', v_costo_real
      );
    ELSIF v_actualiza_costo THEN
      -- Hay una compra mas nueva: la reposicion es la de ella. Avisar si el
      -- costo de esta cambio materialmente (> 1%).
      v_costo_old := NULLIF((v_costo_old_map->>v_prod_txt)::NUMERIC, 0);
      IF v_costo_old IS NOT NULL
         AND abs(v_costo_real - v_costo_old) / v_costo_old > 0.01 THEN
        v_warning_cpp := v_warning_cpp || jsonb_build_object(
          'producto_id', v_producto_id,
          'costo_real_anterior', v_costo_old,
          'costo_real_nuevo', v_costo_real,
          'motivo', 'no_es_la_ultima' /* mig 236 */
        );
      END IF;
    END IF;

$b$
);

-- 7.5 · Despues del loop: el promedio de cada producto, una sola vez, y la
--       reposicion del producto que se fue.
SELECT public._mig407_anclas(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  ARRAY[
$a$  END LOOP;

  /* mig 194 · los cargos, ya con los ids reales de las lineas nuevas. */
$a$,
$b$  END LOOP;

  /* mig 407 (#1251) · EL PROMEDIO DE CADA PRODUCTO, UNA SOLA VEZ, CON TODAS LAS
     LINEAS NUEVAS ADENTRO. Los productos son los de la compra vieja y los de la
     nueva (las claves de v_snapshot_stock).
     · Se agrego en esta edicion: su base fue el estado de hoy, asi que el
       promedio corrido ya es el nuevo, como en el alta.
     · Ya estaba, sin foto (compra anterior a la 236): no hay de donde
       arrancar; queda como esta y se avisa.
     · Ya estaba, con foto: la diferencia entre lo que dejan las lineas nuevas
       y lo que dejaban las viejas, arrastrada por las compras que entraron
       despues, se le suma al promedio vivo. Es tambien el camino del producto
       que SALE de la compra: sus lineas nuevas no existen y la cuenta nueva es
       la foto del alta, como si nunca hubiera entrado.
     Y si la compra fijaba la reposicion de un producto que ya no tiene una
     linea que fije costo (salio, o paso a regalo), la reposicion vuelve a la
     compra anterior (#1251 CMP-3). */
  FOR v_prod_txt IN SELECT jsonb_object_keys(COALESCE(v_snapshot_stock, '{}'::JSONB)) LOOP
    v_producto_id := v_prod_txt::BIGINT;
    v_b := v_base -> v_prod_txt;

    IF v_b IS NULL THEN
      v_cpp_final := NULLIF((v_cpp_map ->> v_prod_txt)::NUMERIC, 0);
      IF v_cpp_final IS NOT NULL THEN
        UPDATE productos
           SET costo_promedio = v_cpp_final,
               updated_at     = NOW()
         WHERE id = v_producto_id AND sucursal_id = v_sucursal
           AND costo_promedio IS DISTINCT FROM v_cpp_final;
      END IF;
    ELSIF jsonb_typeof(v_b -> 'c0') <> 'number' THEN
      v_warning_cpp := v_warning_cpp || jsonb_build_object(
        'producto_id', v_producto_id,
        'motivo', 'sin_cpp_previo'
      );
    ELSE
      SELECT * INTO v_cadena
        FROM _cpp_arrastrar(
               v_producto_id, v_sucursal, p_compra_id,
               (v_b ->> 'ts')::TIMESTAMPTZ,
               ((v_stock_previo_map ->> v_prod_txt)::NUMERIC
                 - (v_b ->> 's0')::NUMERIC - (v_b ->> 'q')::NUMERIC)::INTEGER,
               (v_b ->> 'cpp_despues')::NUMERIC,
               (v_cpp_map ->> v_prod_txt)::NUMERIC);

      UPDATE productos p
         SET costo_promedio = _cpp_corregido(p.costo_promedio, v_cadena.cpp_viejo, v_cadena.cpp_nuevo),
             updated_at     = NOW()
       WHERE p.id = v_producto_id AND p.sucursal_id = v_sucursal
         AND p.costo_promedio IS DISTINCT FROM
             _cpp_corregido(p.costo_promedio, v_cadena.cpp_viejo, v_cadena.cpp_nuevo);
    END IF;

    IF v_b IS NOT NULL AND (v_b ->> 'pagaba')::BOOLEAN
       AND NOT EXISTS (
         SELECT 1 FROM compra_items ci
          WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = v_sucursal
            AND ci.producto_id = v_producto_id
            AND _cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario))
       AND _ninguna_compra_mas_nueva(p_compra_id, v_producto_id, v_sucursal) THEN
      IF NOT _reposicion_desde_ultima_compra(v_producto_id, v_sucursal) THEN
        v_warnings_repos := v_warnings_repos || jsonb_build_object(
          'producto_id', v_producto_id,
          'warning', 'costo_no_restaurado: sin otra compra válida de referencia');
      END IF;
    END IF;
  END LOOP;

  /* mig 194 · los cargos, ya con los ids reales de las lineas nuevas. */
$b$
  ]
);

-- -------------------------------------------------------------------------
-- 8 · anular_compra_atomica
-- -------------------------------------------------------------------------
SELECT public._mig407_anclas(
  'public.anular_compra_atomica(bigint,uuid)'::regprocedure,
  ARRAY[
$a$  v_nc_count   INTEGER;  -- #1095
$a$,
$b$  v_nc_count   INTEGER;  -- #1095
  v_cadena     RECORD;   -- mig 407
$b$
  ]
);

SELECT public._mig407_region(
  'public.anular_compra_atomica(bigint,uuid)'::regprocedure,
$a$  FOR v_row IN
    SELECT DISTINCT ci.producto_id
$a$,
$a$  RETURN jsonb_build_object(
    'success', true,
    'compra_id', p_compra_id,
$a$,
$b$  /* mig 407 (#1252) · ANULAR DEVUELVE EL PROMEDIO (decision del dueño,
     2026-10-28). Es la edicion que saca todas las lineas: la cuenta nueva es la
     foto del alta, como si la compra nunca hubiera entrado, y la diferencia se
     arrastra por las compras que entraron despues con el stock corrido por las
     unidades que se van. Hasta la 407 el promedio quedaba como estaba y se
     corregia a mano desde la ficha.

     La REPOSICION vuelve a la compra anterior solo si esta era la que la
     fijaba (la ultima por (fecha, id) que fija costo). Hasta la 407 se pisaba
     siempre con la ultima restante, aunque esta no hubiera sido la que la
     fijaba. */
  FOR v_row IN
    SELECT * FROM _cpp_foto_compra(p_compra_id, v_sucursal) ORDER BY producto_id
  LOOP
    IF v_row.c0 IS NULL THEN
      v_warnings := v_warnings || jsonb_build_object(
        'producto_id', v_row.producto_id,
        'motivo', 'sin_cpp_previo',
        'warning', 'costo_promedio_no_revertido: la compra es anterior a que se guardara el promedio previo');
    ELSE
      SELECT * INTO v_cadena
        FROM _cpp_arrastrar(v_row.producto_id, v_sucursal, p_compra_id, v_row.ts,
                            -v_row.q, v_row.cpp_despues, v_row.c0);

      UPDATE productos p
         SET costo_promedio = _cpp_corregido(p.costo_promedio, v_cadena.cpp_viejo, v_cadena.cpp_nuevo),
             updated_at     = NOW()
       WHERE p.id = v_row.producto_id AND p.sucursal_id = v_sucursal
         AND p.costo_promedio IS DISTINCT FROM
             _cpp_corregido(p.costo_promedio, v_cadena.cpp_viejo, v_cadena.cpp_nuevo);
    END IF;

    IF v_row.pagaba AND _ninguna_compra_mas_nueva(p_compra_id, v_row.producto_id, v_sucursal) THEN
      IF NOT _reposicion_desde_ultima_compra(v_row.producto_id, v_sucursal) THEN
        v_warnings := v_warnings || jsonb_build_object(
          'producto_id', v_row.producto_id,
          'warning', 'costo_no_restaurado: sin otra compra válida de referencia');
      END IF;
    END IF;
  END LOOP;

$b$
);

-- -------------------------------------------------------------------------
-- 9 · cambiar_proveedor_compra: el clon conserva la foto y las fechas de alta.
-- -------------------------------------------------------------------------
SELECT public._mig407_anclas(
  'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure,
  ARRAY[
$a$    letra_comprobante /* mig 293 */
  )
  SELECT
$a$,
$b$    letra_comprobante, /* mig 293 */
    created_at /* mig 407 (#1252): la ventana de 7 dias sigue contando desde el alta */
  )
  SELECT
$b$,
$a$    c.letra_comprobante /* mig 293 */
  FROM compras c
$a$,
$b$    c.letra_comprobante, /* mig 293 */
    c.created_at /* mig 407 */
  FROM compras c
$b$,
$a$      condicion_iva, cargos_unitarios
    ) VALUES (
$a$,
$b$      condicion_iva, cargos_unitarios,
      costo_promedio_anterior, created_at /* mig 407 (#1252): la foto del alta y su lugar en la cadena */
    ) VALUES (
$b$,
$a$      v_item.costo_real_unitario, v_item.condicion_iva, v_item.cargos_unitarios
    )
$a$,
$b$      v_item.costo_real_unitario, v_item.condicion_iva, v_item.cargos_unitarios,
      v_item.costo_promedio_anterior, v_item.created_at
    )
$b$
  ]
);

-- -------------------------------------------------------------------------
-- 10 · Datos.
-- -------------------------------------------------------------------------

-- 10.1 · Las lineas de toda compra editada recuperan la foto del alta. La
-- edicion las borraba y las recreaba con `stock_anterior` = el stock vivo y
-- `created_at` = la hora de la edicion. El stock del alta sale de la auditoria
-- de productos de la MISMA transaccion (created_at = el now() del alta): el
-- primer UPDATE de cada producto tiene el stock de antes en old_data, y el
-- minimo es el de la primera linea porque cada linea suma. Un producto que no
-- aparece en esa auditoria se agrego en una edicion: entro en ese momento y su
-- foto ya es la de ese momento. Idempotente: aplicada, la linea ya tiene el
-- created_at del alta y vuelve a dar lo mismo.
DO $fotos$
DECLARE
  v_n int;
BEGIN
  WITH editadas AS (
    SELECT c.id AS compra_id, c.created_at AS alta
      FROM compras c
     WHERE EXISTS (SELECT 1 FROM compra_items ci
                    WHERE ci.compra_id = c.id
                      AND ci.created_at > c.created_at + interval '1 minute')
  ), del_alta AS (
    SELECT e.compra_id, a.registro_id::BIGINT AS producto_id,
           min((a.old_data ->> 'stock')::INTEGER) AS s0
      FROM editadas e
      JOIN audit_logs a ON a.tabla = 'productos'
                       AND a.created_at = e.alta
                       AND 'stock' = ANY (a.campos_modificados)
     GROUP BY e.compra_id, a.registro_id
  ), lineas AS (
    SELECT ci.id, e.alta,
           d.s0 + COALESCE(sum(ci.cantidad) OVER (
                    PARTITION BY ci.compra_id, ci.producto_id ORDER BY ci.id
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS s_ant
      FROM compra_items ci
      JOIN editadas e ON e.compra_id = ci.compra_id
      JOIN del_alta d ON d.compra_id = ci.compra_id AND d.producto_id = ci.producto_id
  )
  UPDATE compra_items ci
     SET stock_anterior = l.s_ant,
         stock_nuevo    = l.s_ant + ci.cantidad,
         created_at     = l.alta
    FROM lineas l
   WHERE ci.id = l.id
     AND (ci.stock_anterior, ci.created_at) IS DISTINCT FROM (l.s_ant, l.alta);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'mig 407 · % lineas de compras editadas recuperaron la foto del alta', v_n;
END
$fotos$;

-- 10.2 · Los promedios que dejaron mal las ediciones (reconstruidos desde
-- audit_logs el 2026-10-28). Cada uno se corrige solo si sigue en el valor
-- medido: si algo lo movio despues, se avisa y queda como esta.
--   · compra 6319, editada el 20/10 sin cambiar ninguna linea y sin nada
--     despues: vuelve al promedio que dejo el alta.
--   · compra 298, editada el 06/10 y el 07/10 (las lineas cambiaron solo en el
--     cuarto decimal del costo): el promedio corregido es el del alta, y la 6321
--     (20/10) entro arriba. Es su cuenta desde su foto con el promedio del alta.
DO $promedios$
DECLARE
  r   record;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      (271::BIGINT, 2109.2938::NUMERIC, 2109.3983::NUMERIC),
      (272, 3709.8184, 3708.2783),
      (274, 1898.6915, 1897.4880),
      (275, 3435.6900, 3420.0143),
      (278, 1900.0565, 1899.8366),
      (280, 3269.3349, 3270.6250),
      (287,  956.5967,  956.7054),
      (288, 2150.7688, 2149.0122),
      (289, 2164.5716, 2163.2554),
      (301,  572.5500,  572.1377),
      (307, 3049.0400, 3049.8018),
      (334,  846.8896,  846.1328),
      (140,  648.2617,  645.6126),
      (142,  760.1321,  760.0946),
      (144,  950.1044,  950.0934),
      (147, 6201.4283, 6184.7210)
    ) AS v(producto_id, medido, correcto)
  LOOP
    UPDATE productos
       SET costo_promedio = r.correcto,
           updated_at     = NOW()
     WHERE id = r.producto_id
       AND costo_promedio = r.medido;
    IF FOUND THEN
      v_n := v_n + 1;
    ELSE
      RAISE NOTICE 'mig 407 · producto %: el promedio ya no es % y se dejo como esta', r.producto_id, r.medido;
    END IF;
  END LOOP;

  -- Las fotos de la 6321 se armaron sobre el promedio corrido de la 298: pasan
  -- al corregido, para que anularla o corregirla arranque de la base buena.
  UPDATE compra_items ci
     SET costo_promedio_anterior = v.correcto
    FROM (VALUES
      (139::BIGINT,  655.2910::NUMERIC,  631.5902::NUMERIC),
      (140,  620.8747,  607.9046),
      (142,  760.1321,  759.9875),
      (144,  948.2138,  947.8722),
      (145,  950.1583,  949.9040),
      (147, 6172.1905, 6134.5990)
    ) AS v(producto_id, medido, correcto)
   WHERE ci.compra_id = 6321
     AND ci.producto_id = v.producto_id
     AND ci.costo_promedio_anterior = v.medido;

  RAISE NOTICE 'mig 407 · % promedios corregidos', v_n;
END
$promedios$;

-- -------------------------------------------------------------------------
-- 11 · La columna de la letra, permisos y limpieza. Los helpers son de server:
-- los llaman las RPCs (SECURITY DEFINER), nadie mas.
-- -------------------------------------------------------------------------
ALTER TABLE public.productos DROP CONSTRAINT productos_ultimo_tipo_compra_check;
-- Ensanchar un varchar no reescribe la tabla ni pierde los GRANT por columna.
ALTER TABLE public.productos ALTER COLUMN ultimo_tipo_compra TYPE varchar(4);
ALTER TABLE public.productos ADD CONSTRAINT productos_ultimo_tipo_compra_check
  CHECK (ultimo_tipo_compra IN ('ZZ', 'FC', 'FC B', 'FC C'));

COMMENT ON COLUMN public.productos.ultimo_tipo_compra IS
  'El comprobante de la ultima compra que fijo el costo de reposicion: ''FC'' '
  '(factura A o M: el IVA es credito y el costo es el neto), ''FC B'' / ''FC C'' '
  '(el IVA no es credito: el costo es lo pagado, como en ZZ) o ''ZZ'' (sin '
  'factura). La ficha decide con esto la formula del costo total (mig 407).';

DROP FUNCTION public._mig407_anclas(regprocedure, text[]);
DROP FUNCTION public._mig407_region(regprocedure, text, text, text);

REVOKE ALL ON FUNCTION public._tipo_compra_producto(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cpp_fija_costo(numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cpp_linea(numeric, numeric, numeric, numeric, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cpp_recorrer_compra(bigint, bigint, bigint, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cpp_foto_compra(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cpp_arrastrar(bigint, bigint, bigint, timestamptz, integer, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cpp_corregido(numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._ninguna_compra_mas_nueva(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._reposicion_desde_ultima_compra(bigint, bigint) FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 12 · Verificacion.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_alta    regprocedure := 'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)';
  v_edicion regprocedure := 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)';
  v_anular  regprocedure := 'public.anular_compra_atomica(bigint,uuid)';
  v_cambiar regprocedure := 'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)';
  v_f       regprocedure;
BEGIN
  -- Las RPCs siguen siendo del front y de nadie anonimo.
  FOREACH v_f IN ARRAY ARRAY[v_alta, v_edicion, v_anular, v_cambiar] LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo ejecutable por anon', v_f;
    END IF;
    IF NOT has_function_privilege('authenticated', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo sin EXECUTE para authenticated', v_f;
    END IF;
  END LOOP;

  -- Los helpers no los llama nadie desde afuera.
  FOR v_f IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('_tipo_compra_producto', '_cpp_fija_costo', '_cpp_linea', '_cpp_recorrer_compra',
                         '_cpp_foto_compra', '_cpp_arrastrar', '_cpp_corregido',
                         '_ninguna_compra_mas_nueva', '_reposicion_desde_ultima_compra')
  LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE') OR has_function_privilege('authenticated', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo ejecutable desde afuera', v_f;
    END IF;
  END LOOP;

  -- La edicion ya no arma la base con el stock vivo, y las tres llaman al arrastre.
  IF pg_get_functiondef(v_edicion) ~ 'p\.stock - COALESCE\(v\.qty_old, 0\)' THEN
    RAISE EXCEPTION 'actualizar_compra_items sigue armando la base con el stock vivo';
  END IF;
  IF pg_get_functiondef(v_edicion) !~ '_cpp_arrastrar' OR pg_get_functiondef(v_anular) !~ '_cpp_arrastrar' THEN
    RAISE EXCEPTION 'la edicion o la anulacion no arrastran el promedio';
  END IF;
  IF pg_get_functiondef(v_alta) !~ 'ORDER BY id\s+FOR UPDATE;\s+FOR v_item IN' THEN
    RAISE EXCEPTION 'registrar_compra_completa no bloquea los productos en orden de id antes del loop';
  END IF;
  IF pg_get_functiondef(v_alta) !~ '_cpp_linea' OR pg_get_functiondef(v_alta) ~ 'v_stock_anterior::NUMERIC \* v_producto\.costo_promedio' THEN
    RAISE EXCEPTION 'registrar_compra_completa no usa _cpp_linea';
  END IF;
  IF pg_get_functiondef(v_cambiar) !~ 'v_item\.costo_promedio_anterior' THEN
    RAISE EXCEPTION 'cambiar_proveedor_compra no copia la foto del promedio';
  END IF;
  IF pg_get_functiondef(v_alta) ~ 'ultimo_tipo_compra = v_tipo_factura'
     OR pg_get_functiondef(v_edicion) ~ 'ultimo_tipo_compra = v_compra\.tipo_factura'
     OR pg_get_functiondef(v_anular) ~ 'ultimo_tipo_compra = v_ult\.tipo_factura' THEN
    RAISE EXCEPTION 'quedo un camino que graba ultimo_tipo_compra sin la letra';
  END IF;

  -- El motor de prorrateo y su espejo no se tocaron.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.calcular_costos_compra(jsonb,jsonb,jsonb)'::regprocedure)
       <> '4775003875f12d23ba57ebe58268971e'
     OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.espejo_motor_compras(jsonb,integer)'::regprocedure)
       <> 'cbaef6d5d2011732231ffe5a83be38cd' THEN
    RAISE EXCEPTION 'cambio el motor de prorrateo o su espejo';
  END IF;

  -- La formula comun da lo mismo que la que reemplaza (mig 128 y 227).
  IF _cpp_linea(100, 10, 100, 20, true) <> 15
     OR _cpp_linea(0, 10, 100, 20, true) <> 20
     OR _cpp_linea(100, 0, 100, 20, true) <> 20
     OR _cpp_linea(100, 10, 100, 0, false) <> 5
     OR _cpp_linea(0, 10, 100, 0, false) <> 10
     OR _cpp_linea(100, NULL, 100, 0, false) IS NOT NULL THEN
    RAISE EXCEPTION '_cpp_linea no reproduce la cuenta del alta';
  END IF;
END
$verif$;

COMMIT;
