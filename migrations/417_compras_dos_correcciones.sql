-- =========================================================================
-- NNN · COMPRAS · LA SEGUNDA CORRECCION ARRANCA DE LA PRIMERA (#1294)
--
-- Plan #1306, tarjeta 3. Sigue a la 407 (#1251/#1252/#1253), que hizo que
-- editar o anular una compra corrigiera el promedio por diferencia.
--
-- =========================================================================
-- 1 · LAS FOTOS DE LAS COMPRAS POSTERIORES QUEDABAN VIEJAS (CMP-N1)
-- =========================================================================
-- `_cpp_arrastrar` recorre las lineas del producto que entraron despues de la
-- compra corregida en dos historias: la vieja arranca cada linea de su foto
-- (`stock_anterior`, `costo_promedio_anterior`) y la nueva, de esa foto corrida
-- por la diferencia. Pero ni la edicion ni la anulacion pasaban esas fotos a
-- la historia corregida. Despues de la primera correccion, la foto de la
-- compra posterior seguia contando la historia de antes, y la segunda
-- correccion arrastraba desde ahi. Mientras la diferencia es lineal da igual;
-- si la segunda cambia los pesos (una cantidad, una anulacion, un reset por
-- stock 0) el error queda en el promedio. Con stock 100 a 10, A 100 a 10 y B
-- 100 a 20 (13,3333):
--   · A a 16 da 15,3333 (bien); anular B despues daba 12, y es 13.
--   · A a 16 y despues A a 50 u. daba 15,4, y es 15,2.
-- La 407 corrigio a mano las fotos de la 6321 por esto mismo (407 · 10.2).
--
-- Ahora `_cpp_arrastrar`, en el mismo recorrido, le escribe a cada linea
-- posterior la foto de la historia corregida: el stock corrido por las
-- unidades que cambiaron (y `stock_nuevo` con el), y el promedio con el que la
-- recorre la historia nueva. La correccion siguiente encuentra como historia
-- vieja la nueva de la anterior, y `vivo + (nuevo - viejo)` vuelve a ser
-- exacto. Hace falta tambien la foto del stock: si la primera correccion
-- cambio una cantidad, la segunda pesaria mal (anular B despues de pasar A a
-- 50 u. daria 12,5333 en vez de 12).
--   · Lo que no es de esta compra sigue en la foto: una correccion a mano en la
--     ficha entre A y B queda corrida por la diferencia, no se pisa.
--   · Una linea sin foto del promedio (anterior a la 236) sigue sin foto: se le
--     corre el stock y el promedio lo sigue tomando de la cadena.
--   · El stock corrido puede quedar en negativo (la cantidad bajo mas de lo
--     que habia en el medio): es la cuenta, y `_cpp_linea` lo trata como 0.
--     Guardarlo en 0 haria que la correccion siguiente pese mal.
--
-- `cambiar_proveedor_compra` clona las lineas con su foto. Ahora bloquea los
-- productos (por id) antes de clonar: si no, podia copiar la foto vieja
-- mientras la edicion de una compra anterior la reescribia, y la correccion
-- quedaba en la compra que se cancela. Es el mismo orden que el resto de
-- compras y que la venta: productos por id, y despues los lotes.
--
-- =========================================================================
-- 2 · EL CLON LE GANABA EL DESEMPATE A LA COMPRA POSTERIOR (CMP-N2)
-- =========================================================================
-- La reposicion es de la compra mas nueva por (fecha_compra, id). El clon de
-- `cambiar_proveedor_compra` nace con un id nuevo, asi que le ganaba a una
-- compra del mismo dia que en realidad era posterior. Con X (10/10, a 10) e Y
-- (misma fecha, despues, a 12), y X' el clon de X: editar X' sin cambios
-- pisaba la reposicion con 10, y anular Y no la devolvia a X'.
--
-- Ahora el desempate es por la hora del alta: (fecha_compra, created_at, id).
-- El clon ya conserva el `created_at` del original desde la 407, y una compra
-- comun tiene la hora en que se registro. Cambia en los dos lugares que eligen
-- la mas nueva, que tienen que ir juntos: `_ninguna_compra_mas_nueva` (¿esta
-- compra fija la reposicion?) y `_reposicion_desde_ultima_compra` (¿cual la
-- fija ahora?). Con solo el primero, X, Y y Z del mismo dia y el clon X',
-- anular Z devolvia la reposicion a X' en vez de a Y.
-- `registrar_compra_completa` no cambia: la compra que se registra es la mas
-- nueva por hora y por id, y gana el empate de fecha (`>=`) igual que antes.
--
-- =========================================================================
-- LO QUE NO SE TOCA
-- =========================================================================
-- · `actualizar_compra_items` y `anular_compra_atomica`: siguen llamando al
--   arrastre una vez por producto, con el producto bloqueado. Su md5 va en la
--   premisa porque el arreglo cuenta con eso.
-- · La cuenta de una linea (`_cpp_linea`), la foto de una compra
--   (`_cpp_foto_compra`) y la correccion del vivo (`_cpp_corregido`).
-- · El front (`fetchCompraQueFijaCosto`, `costoAnterior.ts`) sigue ordenando
--   por (fecha_compra, id): con un clon del mismo dia la ficha puede mostrar
--   otra "ultima compra" que la que fija la reposicion. Es solo de pantalla.
-- · Datos: no hay fotos viejas en prod. Desde la 407 no se anulo ni se cambio
--   de proveedor ninguna compra, y la unica tocada (6395, 29/10) no tiene
--   compras posteriores (verificado el 2026-10-29).
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Premisa: los cuerpos vivos son los de prod del 2026-10-29
-- -------------------------------------------------------------------------
-- Molde de la 413. Las cuatro primeras se reemplazan; las dos ultimas no se
-- tocan, pero el arreglo cuenta con que llamen al arrastre como hoy. Si otra
-- migracion cambio alguna en el medio, se aborta y se rehace sobre la viva.
DO $vivas$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', 'aa835da6189f1966048a8d0328e0dd15'),
      ('public._ninguna_compra_mas_nueva(bigint,bigint,bigint)', '8ba8e49fec041df0e78fc62ee7cbb967'),
      ('public._reposicion_desde_ultima_compra(bigint,bigint)', '20e42cb575671b900af090e2cb599dca'),
      ('public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)', '13418155ae11d63d0bc7e6dd2fb9bb3d'),
      ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)', '261d21ae4b6a5716ab7d0769b89483c9'),
      ('public.anular_compra_atomica(bigint,uuid)', '4828b2bd18931117ccae0120f9461eb8')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-10-29: rehacer la migracion sobre la definicion viva', r.firma;
    END IF;
  END LOOP;
END
$vivas$;

-- -------------------------------------------------------------------------
-- 1 · El arrastre pasa las fotos a la historia corregida (CMP-N1)
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
-- Y le deja a cada linea la foto de la historia nueva (#1294): la correccion
-- que venga despues la encuentra como historia vieja. El producto ya esta
-- bloqueado por el llamador, y todo el que escribe lineas de este producto
-- (o las clona) lo bloquea primero.
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
VOLATILE
SET search_path = public
AS $fn$
DECLARE
  r             record;
  v_antes_viejo numeric;
  v_antes_nuevo numeric;
  v_s_nuevo     integer;
  v_c_nuevo     numeric;
BEGIN
  cpp_viejo := p_cpp_viejo;
  cpp_nuevo := p_cpp_nuevo;

  FOR r IN
    SELECT ci.id, ci.stock_anterior, ci.costo_promedio_anterior, ci.cantidad,
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
    v_s_nuevo := r.stock_anterior + p_delta_stock;

    /* mig NNN (#1294) · la foto de la linea pasa a la historia corregida: el
       stock y el promedio con los que la recorre la historia nueva. Una linea
       sin foto del promedio (anterior a la 236) sigue sin ella. El stock no se
       recorta en 0: `_cpp_linea` ya lo trata como 0, y recortado pesaria mal
       en la correccion siguiente. */
    v_c_nuevo := CASE WHEN r.costo_promedio_anterior IS NOT NULL THEN v_antes_nuevo END;
    UPDATE compra_items
       SET stock_anterior          = v_s_nuevo,
           stock_nuevo             = v_s_nuevo + r.cantidad,
           costo_promedio_anterior = v_c_nuevo
     WHERE id = r.id
       AND (stock_anterior, costo_promedio_anterior) IS DISTINCT FROM (v_s_nuevo, v_c_nuevo);

    cpp_viejo := public._cpp_linea(r.stock_anterior, v_antes_viejo, r.cantidad, r.costo, r.fija);
    cpp_nuevo := public._cpp_linea(v_s_nuevo, v_antes_nuevo, r.cantidad, r.costo, r.fija);
  END LOOP;
END;
$fn$;

-- -------------------------------------------------------------------------
-- 2 · La compra mas nueva, por la hora del alta en el empate (CMP-N2)
-- -------------------------------------------------------------------------

-- ¿Ninguna otra compra viva tiene una linea de este producto que fije costo y
-- sea mas nueva que esta? Mas nueva es por (fecha_compra, created_at, id): en
-- el empate de fecha manda la hora del alta, que el clon de
-- `cambiar_proveedor_compra` conserva (#1294); el id solo desempata dos altas
-- en el mismo instante. Los regalos no cuentan (#1253).
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
       AND (c.fecha_compra, c.created_at, c.id) > (yo.fecha_compra, yo.created_at, yo.id)
  );
$fn$;

-- El costo de reposicion desde la ultima compra viva que fija costo, con el
-- mismo orden que `_ninguna_compra_mas_nueva`: (fecha_compra, created_at, id)
-- y, dentro de la compra, la ultima linea. Las B y C se calculan como lo
-- pagado (mig 293) y dejan 'FC B' / 'FC C'. Devuelve false si no hay ninguna.
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
   ORDER BY c.fecha_compra DESC, c.created_at DESC, c.id DESC, ci.id DESC
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
-- 3 · cambiar_proveedor_compra bloquea los productos antes de clonar
-- -------------------------------------------------------------------------
-- Parche por ancla sobre el cuerpo vivo (la premisa ya verifico que es el de
-- hoy): el ancla tiene que aparecer exactamente una vez.
DO $proveedor$
DECLARE
  v_f     regprocedure := 'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)';
  v_def   text := pg_get_functiondef('public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure);
  v_ancla text := $a$  -- 1) Clonar cabecera con el proveedor nuevo (todo lo demas identico)
$a$;
  v_nuevo text := $b$  /* mig NNN (#1294) · LOS PRODUCTOS SE BLOQUEAN ANTES DE CLONAR, en orden
     de id. Editar o anular una compra ANTERIOR reescribe las fotos de las
     lineas de esta (`_cpp_arrastrar`) con el producto bloqueado; sin este lock
     el clon podia copiar la foto vieja mientras se reescribia, y la correccion
     quedaba en la compra que se cancela. Mismo orden que el resto de compras
     y que la venta: productos por id, y despues los lotes (2.2). */
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT producto_id FROM compra_items
                 WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal)
   ORDER BY id
   FOR UPDATE;

  -- 1) Clonar cabecera con el proveedor nuevo (todo lo demas identico)
$b$;
  v_veces int;
BEGIN
  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla del clon aparece % veces en % (se esperaba 1)', v_veces, v_f;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$proveedor$;

-- -------------------------------------------------------------------------
-- 4 · Permisos. CREATE OR REPLACE conserva los de la 407; se repiten por las
--     dudas. Los helpers son de server: los llaman las RPCs (SECURITY
--     DEFINER), nadie mas.
-- -------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._cpp_arrastrar(bigint, bigint, bigint, timestamptz, integer, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._ninguna_compra_mas_nueva(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._reposicion_desde_ultima_compra(bigint, bigint) FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 5 · Verificacion
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_edicion regprocedure := 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)';
  v_anular  regprocedure := 'public.anular_compra_atomica(bigint,uuid)';
  v_cambiar regprocedure := 'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)';
  v_arr     regprocedure := 'public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)';
  v_ning    regprocedure := 'public._ninguna_compra_mas_nueva(bigint,bigint,bigint)';
  v_repos   regprocedure := 'public._reposicion_desde_ultima_compra(bigint,bigint)';
  v_f       regprocedure;
BEGIN
  -- Las RPCs siguen siendo del front y de nadie anonimo.
  FOREACH v_f IN ARRAY ARRAY[v_edicion, v_anular, v_cambiar] LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo ejecutable por anon', v_f;
    END IF;
    IF NOT has_function_privilege('authenticated', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo sin EXECUTE para authenticated', v_f;
    END IF;
  END LOOP;

  -- Los helpers no los llama nadie desde afuera.
  FOREACH v_f IN ARRAY ARRAY[v_arr, v_ning, v_repos] LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE') OR has_function_privilege('authenticated', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo ejecutable desde afuera', v_f;
    END IF;
  END LOOP;

  -- El arrastre escribe: una funcion STABLE que hace UPDATE falla en runtime.
  IF (SELECT provolatile FROM pg_proc WHERE oid = v_arr) <> 'v'
     OR pg_get_functiondef(v_arr) !~ 'UPDATE compra_items\s+SET stock_anterior' THEN
    RAISE EXCEPTION '_cpp_arrastrar no pasa las fotos a la historia corregida';
  END IF;

  -- Las dos que eligen la mas nueva desempatan igual, por la hora del alta.
  IF pg_get_functiondef(v_ning) !~ '\(c\.fecha_compra, c\.created_at, c\.id\) > \(yo\.fecha_compra, yo\.created_at, yo\.id\)'
     OR pg_get_functiondef(v_repos) !~ 'ORDER BY c\.fecha_compra DESC, c\.created_at DESC, c\.id DESC, ci\.id DESC' THEN
    RAISE EXCEPTION 'la compra mas nueva no desempata por la hora del alta en los dos helpers';
  END IF;

  -- El clon bloquea los productos antes de clonar, y sigue copiando la foto.
  IF pg_get_functiondef(v_cambiar) !~ 'ORDER BY id\s+FOR UPDATE;\s+-- 1\) Clonar cabecera'
     OR pg_get_functiondef(v_cambiar) !~ 'v_item\.costo_promedio_anterior, v_item\.created_at' THEN
    RAISE EXCEPTION 'cambiar_proveedor_compra no bloquea los productos antes de clonar';
  END IF;

  -- La edicion y la anulacion no se tocaron y siguen llamando al arrastre.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = v_edicion) <> '261d21ae4b6a5716ab7d0769b89483c9'
     OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = v_anular) <> '4828b2bd18931117ccae0120f9461eb8'
     OR pg_get_functiondef(v_edicion) !~ '_cpp_arrastrar'
     OR pg_get_functiondef(v_anular) !~ '_cpp_arrastrar' THEN
    RAISE EXCEPTION 'cambio la edicion o la anulacion de compras';
  END IF;
END
$verif$;
