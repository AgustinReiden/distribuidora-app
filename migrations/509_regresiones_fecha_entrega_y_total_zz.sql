-- =========================================================================
-- NNN · LAS REGRESIONES DE LA 505 Y LA 506: EL CANJE CON UNA FECHA QUE LA
--       ENTREGA RECHAZA, LA POLÍTICA QUE NO SE LEE POR RLS Y EL TOTAL DE
--       UNA ZZ QUE MANDA UN FRONT VIEJO
--       (plan #1603, tarjeta M10: R1, R3, B1, B2, B4 y R2 de la revisión
--        adversarial de la ola 1)
--
-- Una función nueva (`_dias_atras_fecha_pedido`) y parches por ancla a
-- `_fecha_entrega_fuera_de_rango`, `_fecha_pedido_fuera_de_rango`,
-- `aplicar_cambio_de_parada`, `registrar_compra_completa`,
-- `actualizar_compra_items` y la lista blanca de SEG-A
-- (`auditoria_definer_sin_rol`), con premisa de md5 sobre los cuerpos vivos (la
-- 505 y la 506 aplicadas) y poscondición de md5, definer y ACL. No cambia
-- tablas ni firmas. Rehace el total de las ZZ vivas que lo tienen corto.
-- Ensayo: scripts/test-regresiones-505-506-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- R1 (505) · EL CANJE SE APLICA SÓLO SI LA ENTREGA PUEDE ENTRAR
-- =========================================================================
-- `continuarEntrega` y `handleConfirmarEntregaConChofer` (PedidosContainer)
-- llaman a `aplicar_cambio_de_parada(p, chofer, fecha)` y después al PATCH de
-- la entrega. La 505 le puso rango a la fecha del PATCH y no a la del canje:
-- con una fecha fuera de rango el stock del canje se movía y la entrega daba
-- 22023, y la comanda quedaba sin entregar con el cambio aplicado. Rompía la
-- regla de #1343 que dice la misma función. Ahora `aplicar_cambio_de_parada`
-- pide `_fecha_entrega_fuera_de_rango(día, sucursal, es_admin())` antes de
-- tomar nada, con la misma condición que el PATCH (sólo si el día argentino
-- cambia respecto de `pedidos.fecha_entrega`) y el mismo motivo (22023).
-- Otros caminos con la misma forma (aplicar algo y fijar la fecha de entrega
-- en un segundo paso): no hay. Las masivas aplican el canje en la misma
-- transacción y miran el rango primero; la entrega con cobro entrega antes de
-- cobrar; la salvedad entrega con hoy.
--
-- =========================================================================
-- B1 (505, y la 481) · LA POLÍTICA DE LA SUCURSAL, SEA QUIEN SEA EL QUE LLAMA
-- =========================================================================
-- `_fecha_entrega_fuera_de_rango` y `_fecha_pedido_fuera_de_rango` son
-- INVOKER y leían `politicas_comerciales` bajo RLS: la policy le oculta la fila
-- al rol base depósito (que puede tener el extra de chofer) y muestra sólo la
-- de la sucursal activa. A ese usuario, o a un chofer de dos sucursales parado
-- en la otra, le regía el default de 7 días aunque la política dijera 2. Las
-- dos leen ahora `_dias_atras_fecha_pedido(sucursal)`, DEFINER y sólo de
-- lectura, acotada: el server (sin `auth.uid()`) o un usuario activo de esa
-- sucursal (`usuario_sucursales` y `perfiles.activo`, #1474). Otro recibe NULL
-- y la regla cae en el 7, como sin fila (no le llega un pedido de una sucursal
-- que no es suya, y a un desactivado lo cortan antes el alta y la RLS).
--
-- =========================================================================
-- R3 y B4 (506) · EL TOTAL DE UNA ZZ LO PONE EL SERVER
-- =========================================================================
-- Con la 506 el total de una ZZ es su subtotal más sus cargos en factura
-- (decisión del dueño, #1593), pero el alta guardaba `p_total` como llegaba
-- (sólo avisaba «Descuadre») y la edición lo guardaba sin mirar. Todo front
-- de antes de la 506 (y un PWA sin actualizar) manda total = subtotal: la ZZ
-- quedaba corta, COMPRA-A1 (high) en rojo, y el tope de la NC de ajuste (su
-- total menos sus notas) salía corto. En una ZZ no hay papel contra el cual
-- comparar: el alta y la edición lo calculan y lo guardan, mande lo que mande
-- el front. Es lo que suma COMPRA-A1: el subtotal, los otros impuestos y los
-- cargos `en_factura` (la ZZ guarda en 0 el IVA, el II, las percepciones, el
-- no gravado y la bonificación). El alta sigue devolviendo el aviso de
-- descuadre con el mismo texto cuando lo que llegó es otro número.
-- B4 · Un descuento en factura mayor que el subtotal deja ese total negativo:
-- se rechaza con un mensaje que nombra el descuento (antes, con el front nuevo,
-- «Hay un importe de la cabecera negativo»; con el viejo entraba en rojo). En
-- una ZZ el `p_total` ya no entra al control de importes negativos. El rechazo
-- va después del motor: un descuento que se prorratea y deja un renglón sin
-- costo sigue diciendo cuál (CMP-3, `_compra_costo_real_sin_piso`).
-- Datos: las ZZ vivas con cargos en factura cuyo total difiere en más de 1 del
-- de COMPRA-A1 (cargadas o editadas por un front viejo desde la 506; antes de
-- la 506 no había ninguna) se rehacen con ese total, en las dos direcciones: un
-- flete lo sube y un descuento lo baja (el total de una ZZ es lo pagado,
-- decisión del dueño). Quedan como están, y se cuentan: las que darían
-- negativo, y las que quedarían con más notas de crédito que total (lo
-- acreditado no se toca; las decide el dueño). Un NOTICE cuenta las que suben,
-- las que bajan, las que tienen notas de crédito y las que quedan.
--
-- =========================================================================
-- B2 (506) · STOCK SIN PROMEDIO, REGALO Y PAGADO EN LA MISMA FACTURA: 66,67
-- =========================================================================
-- No cambia nada: se declara. Stock 10 sin promedio, 10 de regalo y 10 a 100
-- daban 100 con la 503 y dan 66,67 con la 506. Es lo correcto según la regla
-- de `costo_promedio` (migrations/CLAUDE.md): el stock sin promedio no tiene
-- de dónde partir y `_cpp_linea` le da el costo del renglón pagado, y el
-- regalo de la misma factura entra después y diluye: 20 u. a 100 y 10 a 0. Con
-- la 503 el regalo iba primero, no tenía qué diluir y se perdía de la
-- valuación. Queda escrito en la regla y con un caso en el ensayo.
--
-- =========================================================================
-- R2 (506) · DECLARADO: EDITAR UNA COMPRA VIEJA CON UN CARGO SOBRE UN REGALO
-- =========================================================================
-- Antes de la 506 el modal pre-llenaba los pesos de un cargo por cantidad,
-- regalos incluidos. La primera edición de esa compra, aunque sea sin cambios,
-- le pasa al renglón pagado la parte del cargo que pesaba sobre el regalo: sube
-- su costo real y arrastra el promedio (y la reposición si es la última
-- compra). Es la regla de la 506 aplicada a lo viejo. Medido en producción el
-- 16/11: 6 compras vivas con cargos, ninguna con un renglón de regalo. La
-- premisa cuenta las vivas con un regalo que tiene peso en algún reparto y
-- avisa cuántas son.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos son los de la 505 y la 506, y los datos que se
-- midieron
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
  n bigint;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._fecha_entrega_fuera_de_rango(date,bigint,boolean)', '966abda7d4a2615071d23d130bb953ee'),
    ('public._fecha_pedido_fuera_de_rango(date,bigint)',          'd66db7f86805a3123561c3d8726b0e1b'),
    ('public.aplicar_cambio_de_parada(bigint,uuid,date)',         '9a7ac63c1f915a09d4064f85d7eb329e'),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     '9b3be23e2477446c6f9a413b8310cb16'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     '3e3dc133de5a10e30c72184232c5a5fd'),
    ('public.auditoria_definer_sin_rol()',                        '0273d33a122c2ab5c19b6ad17a8c57ab')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regprocedure('public._dias_atras_fecha_pedido(bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · _dias_atras_fecha_pedido ya existe';
  END IF;

  -- R2: compras vivas con un regalo que tiene peso en el reparto de un cargo. Su
  -- primera edición le pasa ese pedazo al renglón pagado (la regla de la 506).
  SELECT count(DISTINCT c.id) INTO n
    FROM compras c
    JOIN compra_cargo_repartos ccr ON ccr.compra_id = c.id
    JOIN compra_items ci ON ci.id = ccr.compra_item_id AND ci.compra_id = c.id
   WHERE c.estado <> 'cancelada' AND ccr.peso > 0
     AND NOT _cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario);
  RAISE NOTICE 'mig NNN · R2 · compras vivas con un regalo que pesa en el reparto de un cargo: % (su primera edición le pasa ese cargo al renglón pagado)', n;
  -- R3: las ZZ cuyo total se rehace se cuentan en su bloque, al final.
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- B1 · La política, con un helper DEFINER acotado
-- =========================================================================
CREATE FUNCTION public._dias_atras_fecha_pedido(p_sucursal bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- mig NNN (B1, #1603): politicas_comerciales.dias_atras_fecha_pedido de la sucursal, o NULL
  -- sin fila. Las reglas de la fecha del pedido y de la entrega (_fecha_pedido_fuera_de_rango,
  -- _fecha_entrega_fuera_de_rango) son INVOKER y corren como authenticated desde
  -- pedidos_proteger_columnas: por RLS, el depósito con el rol extra de chofer no veía la fila,
  -- y nadie veía la de otra sucursal que la activa, así que les regía el 7. Acotada: el server
  -- (sin sesión) o un usuario activo de esa sucursal; otro recibe NULL. Un desactivado no tiene
  -- ningún rol aunque su token siga vivo (#1474): tampoco lee esto.
  SELECT pc.dias_atras_fecha_pedido
    FROM public.politicas_comerciales pc
   WHERE pc.sucursal_id = p_sucursal
     AND (auth.uid() IS NULL
          OR (EXISTS (SELECT 1 FROM public.usuario_sucursales us
                       WHERE us.usuario_id = auth.uid() AND us.sucursal_id = p_sucursal)
              AND EXISTS (SELECT 1 FROM public.perfiles pf
                           WHERE pf.id = auth.uid() AND COALESCE(pf.activo, true))))
$function$;

-- La llaman las dos reglas, que corren como authenticated desde el trigger.
REVOKE ALL ON FUNCTION public._dias_atras_fecha_pedido(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._dias_atras_fecha_pedido(bigint) TO authenticated, service_role;

DO $parche_reglas$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public._fecha_entrega_fuera_de_rango(date,bigint,boolean)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$                      ELSE COALESCE((SELECT pc.dias_atras_fecha_pedido
                                       FROM public.politicas_comerciales pc
                                      WHERE pc.sucursal_id = p_sucursal), 7)
$a$,
$r$                      -- mig NNN (B1, #1603): la política de la sucursal sea quien sea el
                      -- que llama (por RLS, el depósito con el extra de chofer caía en el 7).
                      ELSE COALESCE(public._dias_atras_fecha_pedido(p_sucursal), 7)
$r$, '_fecha_entrega_fuera_de_rango (la política, sin RLS)');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public._fecha_pedido_fuera_de_rango(date,bigint)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$                 COALESCE((SELECT pc.dias_atras_fecha_pedido
                             FROM public.politicas_comerciales pc
                            WHERE pc.sucursal_id = p_sucursal), 7) AS dias) r
$a$,
$r$                 -- mig NNN (B1, #1603): la política de la sucursal sea quien sea el que
                 -- llama, no la que le deja ver la RLS.
                 COALESCE(public._dias_atras_fecha_pedido(p_sucursal), 7) AS dias) r
$r$, '_fecha_pedido_fuera_de_rango (la política, sin RLS)');
  EXECUTE v_def;
END
$parche_reglas$;

-- =========================================================================
-- R1 · aplicar_cambio_de_parada mira el rango de la entrega antes de aplicar
-- =========================================================================
DO $parche_canje$
DECLARE
  v_def text := pg_get_functiondef('public.aplicar_cambio_de_parada(bigint,uuid,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_dia DATE;
$a$,
$r$  v_dia DATE;
  v_motivo_fecha TEXT;  -- mig NNN (R1, #1603)
$r$, 'aplicar_cambio_de_parada (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  v_dia := COALESCE(p_fecha, public._tablero_hoy());
$a$,
$r$  v_dia := COALESCE(p_fecha, public._tablero_hoy());
  -- mig NNN (R1, #1603): la fecha de la entrega que viene tiene que entrar en su rango
  -- (GTO-15, #1597). Sin esto el canje movía el stock, el PATCH de la entrega daba 22023 y la
  -- comanda quedaba sin entregar con el cambio aplicado. La misma regla y la misma condición
  -- que pedidos_proteger_columnas: sólo si el día argentino cambia, con el piso del admin para
  -- el admin y el de la política para el resto. Antes de tomar nada.
  IF ((SELECT pe.fecha_entrega FROM pedidos pe WHERE pe.id = p_pedido_id)
        AT TIME ZONE 'America/Argentina/Buenos_Aires')::date IS DISTINCT FROM v_dia THEN
    v_motivo_fecha := public._fecha_entrega_fuera_de_rango(v_dia, v_ped.sucursal_id, public.es_admin());
    IF v_motivo_fecha IS NOT NULL THEN
      RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
    END IF;
  END IF;
$r$, 'aplicar_cambio_de_parada (rango de la fecha de entrega)');

  EXECUTE v_def;
END
$parche_canje$;

-- =========================================================================
-- R3 y B4 · el alta
-- =========================================================================
DO $parche_alta$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_subtotal_mal        TEXT;      -- mig 482 (STK-9, #1516)
$a$,
$r$  v_subtotal_mal        TEXT;      -- mig 482 (STK-9, #1516)
  v_total_zz            NUMERIC;   -- mig NNN (R3, #1603)
  v_cargos_zz           NUMERIC;   -- mig NNN (R3, #1603)
  v_desc_zz             NUMERIC;   -- mig NNN (B4, #1603)
$r$, 'registrar_compra_completa (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  IF EXISTS (SELECT 1 FROM unnest(ARRAY[p_subtotal, p_iva, p_otros_impuestos, p_total,
                                        p_impuestos_internos, p_percepcion_iva, p_percepcion_iibb,
                                        p_no_gravado]::NUMERIC[]) AS x
              WHERE x < 0) THEN
$a$,
$r$  /* mig NNN (R3 y B4, #1603) · EL TOTAL DE UNA ZZ LO PONE EL SERVER. Es el subtotal,
     los otros impuestos y los cargos en factura (decision del dueño, #1593; lo que suma
     COMPRA-A1): no hay papel contra el cual comparar. Un front de antes de la 506 manda
     total = subtotal y la ZZ quedaba corta. Se calcula aca, sobre los cargos crudos (los
     que no son un objeto con un monto numerico los rechaza despues su control), y se
     guarda en el INSERT. En una ZZ el p_total no entra al control de importes negativos:
     un descuento en factura que deja el total negativo se rechaza con su motivo al final,
     despues del motor, para que uno que se prorratea y deja un renglon sin costo diga
     antes cual (CMP-3, _compra_costo_real_sin_piso). */
  IF v_es_zz THEN
    SELECT COALESCE(sum(round((c.val->>'monto')::NUMERIC, 2)), 0),
           COALESCE(sum(round((c.val->>'monto')::NUMERIC, 2)) FILTER (WHERE (c.val->>'monto')::NUMERIC < 0), 0)
      INTO v_cargos_zz, v_desc_zz
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_cargos) = 'array' THEN p_cargos ELSE '[]'::JSONB END) AS c(val)
     WHERE jsonb_typeof(c.val) = 'object'
       AND jsonb_typeof(c.val->'monto') = 'number'
       AND COALESCE(NULLIF(c.val->'en_factura', 'null'::JSONB), 'true'::JSONB) = 'true'::JSONB;
    v_total_zz := round(p_subtotal, 2) + round(COALESCE(p_otros_impuestos, 0), 2) + v_cargos_zz;
  END IF;

  IF EXISTS (SELECT 1 FROM unnest(ARRAY[p_subtotal, p_iva, p_otros_impuestos,
                                        CASE WHEN v_es_zz THEN NULL ELSE p_total END,  /* mig NNN (B4) */
                                        p_impuestos_internos, p_percepcion_iva, p_percepcion_iibb,
                                        p_no_gravado]::NUMERIC[]) AS x
              WHERE x < 0) THEN
$r$, 'registrar_compra_completa (el total de una ZZ)');

  v_def := pg_temp.parche(v_def,
$a$    v_no_gravado_hdr, v_bonif_hdr, COALESCE(p_otros_impuestos, 0), p_total, p_forma_pago, p_notas,
$a$,
$r$    v_no_gravado_hdr, v_bonif_hdr, COALESCE(p_otros_impuestos, 0),
    /* mig NNN (R3) · el GREATEST, por el CHECK: el negativo lo rechaza el final */
    CASE WHEN v_es_zz THEN GREATEST(v_total_zz, 0) ELSE p_total END, p_forma_pago, p_notas,
$r$, 'registrar_compra_completa (el INSERT)');

  v_def := pg_temp.parche(v_def,
$a$  -- Control blando de cuadre contra el total informado
$a$,
$r$  /* mig NNN (B4, #1603) · un descuento en factura mayor que lo que suma la ZZ sin el
     deja su total negativo. RAISE y no RETURN: la compra ya se inserto y el EXCEPTION
     de abajo la deshace. */
  IF v_es_zz AND v_total_zz < 0 THEN
    RAISE EXCEPTION 'El descuento en factura (%) es mayor que lo que suma la compra sin él (%): el total quedaría en %. En una compra sin factura (ZZ) el total es el subtotal más los cargos en factura: revisá el monto del descuento.',
      -v_desc_zz, v_total_zz - v_desc_zz, v_total_zz;
  END IF;

  -- Control blando de cuadre contra el total informado
$r$, 'registrar_compra_completa (el descuento que deja el total negativo)');

  v_def := pg_temp.parche(v_def,
$a$    WHEN v_es_zz THEN COALESCE(p_subtotal, 0)
         + COALESCE((SELECT sum((c.val->>'monto')::NUMERIC) FROM jsonb_array_elements(v_cargos) AS c(val)
                      WHERE (c.val->>'en_factura')::BOOLEAN), 0)
$a$,
$r$    /* mig NNN (R3, #1603) · el que se guardo: el aviso dice que llego otro numero. */
    WHEN v_es_zz THEN v_total_zz
$r$, 'registrar_compra_completa (el aviso)');

  EXECUTE v_def;
END
$parche_alta$;

-- =========================================================================
-- R3 y B4 · la edición
-- =========================================================================
DO $parche_edicion$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_subtotal_mal     TEXT;      -- STK-9
$a$,
$r$  v_subtotal_mal     TEXT;      -- STK-9
  v_total_zz         NUMERIC;   -- mig NNN (R3, #1603)
  v_cargos_zz        NUMERIC;   -- mig NNN (R3, #1603)
  v_desc_zz          NUMERIC;   -- mig NNN (B4, #1603)
$r$, 'actualizar_compra_items (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  IF EXISTS (SELECT 1 FROM unnest(ARRAY[p_subtotal, p_iva, p_total, p_impuestos_internos,
                                        p_percepcion_iva, p_percepcion_iibb, p_no_gravado,
                                        p_otros_impuestos]::NUMERIC[]) AS x
              WHERE x < 0) THEN
$a$,
$r$  IF EXISTS (SELECT 1 FROM unnest(ARRAY[p_subtotal, p_iva,
                                        /* mig NNN (B4, #1603) · el total de una ZZ lo pone el server */
                                        CASE WHEN v_compra.tipo_factura = 'ZZ' THEN NULL ELSE p_total END,
                                        p_impuestos_internos,
                                        p_percepcion_iva, p_percepcion_iibb, p_no_gravado,
                                        p_otros_impuestos]::NUMERIC[]) AS x
              WHERE x < 0) THEN
$r$, 'actualizar_compra_items (importes negativos)');

  v_def := pg_temp.parche(v_def,
$a$  UPDATE compras
     SET ii_declarado = CASE WHEN v_ii_provisto THEN NULLIF(v_ii_declarado, '{}'::JSONB)
$a$,
$r$  /* mig NNN (R3 y B4, #1603) · EL TOTAL DE UNA ZZ LO PONE EL SERVER (ver el alta): el
     subtotal, los otros impuestos y los cargos en factura que quedaron. La edicion lo
     guardaba sin mirar: un front de antes de la 506 lo dejaba corto. RAISE y no RETURN:
     la edicion ya rehizo renglones, stock y cargos, y el EXCEPTION de abajo la deshace. */
  IF v_es_zz THEN
    SELECT COALESCE(sum(cc.monto), 0), COALESCE(sum(cc.monto) FILTER (WHERE cc.monto < 0), 0)
      INTO v_cargos_zz, v_desc_zz
      FROM compra_cargos cc
     WHERE cc.compra_id = p_compra_id AND cc.sucursal_id = v_sucursal AND cc.en_factura;
    v_total_zz := round(p_subtotal, 2)
      + COALESCE(round(p_otros_impuestos, 2),
                 (SELECT c.otros_impuestos FROM compras c WHERE c.id = p_compra_id AND c.sucursal_id = v_sucursal), 0)
      + v_cargos_zz;
    IF v_total_zz < 0 THEN
      RAISE EXCEPTION 'El descuento en factura (%) es mayor que lo que suma la compra sin él (%): el total quedaría en %. En una compra sin factura (ZZ) el total es el subtotal más los cargos en factura: revisá el monto del descuento.',
        -v_desc_zz, v_total_zz - v_desc_zz, v_total_zz;
    END IF;
  END IF;

  UPDATE compras
     SET ii_declarado = CASE WHEN v_ii_provisto THEN NULLIF(v_ii_declarado, '{}'::JSONB)
$r$, 'actualizar_compra_items (el total de una ZZ)');

  v_def := pg_temp.parche(v_def,
$a$         total = p_total,
$a$,
$r$         total = CASE WHEN v_es_zz THEN v_total_zz ELSE p_total END,  /* mig NNN (R3) */
$r$, 'actualizar_compra_items (el UPDATE)');

  EXECUTE v_def;
END
$parche_edicion$;

-- =========================================================================
-- B1 · SEG-A: el helper va a la lista blanca de auditoria_definer_sin_rol
-- =========================================================================
-- Es DEFINER, authenticated lo ejecuta y no mira el rol: lo lee cualquiera de
-- la sucursal, como la política por REST. Un número de días, sin montos.
DO $parche_seg_a$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    ('parametros_vencimiento()',                 '46629184d68b286d0f6fb8d0a73fa88e'),  -- días de alerta, sin montos
$a$,
$r$    ('parametros_vencimiento()',                 '46629184d68b286d0f6fb8d0a73fa88e'),  -- días de alerta, sin montos
    -- mig NNN (B1, #1603): los días atrás de la política de una sucursal del caller (o del
    -- server), sin montos. La leen las reglas de la fecha del pedido y de la entrega, que
    -- corren como el usuario.
    ('_dias_atras_fecha_pedido(bigint)',         'd9c04f85466d1a1cb9aa12a8fdac48bd'),
$r$, 'auditoria_definer_sin_rol (lista blanca)');
  EXECUTE v_def;
END
$parche_seg_a$;

-- =========================================================================
-- R3 · las ZZ vivas con cargos en factura toman el total de COMPRA-A1
-- =========================================================================
-- En las dos direcciones: un flete lo sube, un descuento lo baja (el total de
-- una ZZ es lo pagado). Quedan como están, contadas, las que darían negativo y
-- las que quedarían con más notas de crédito que total. Copia en el ensayo
-- (pg_temp.rehacer_totales_zz): si cambia uno, cambia el otro.
DO $datos_zz$
DECLARE
  n_sube int; n_baja int; n_con_nc int; n_queda_nc int; n_negativa int; n_hechas int;
BEGIN
  CREATE TEMP TABLE m10_zz ON COMMIT DROP AS
  SELECT c.id, COALESCE(c.total, 0) AS antes, z.t AS nuevo, COALESCE(nc.acreditado, 0) AS acreditado
    FROM compras c
    JOIN LATERAL (SELECT sum(cc.monto) AS monto FROM compra_cargos cc
                   WHERE cc.compra_id = c.id AND cc.sucursal_id = c.sucursal_id AND cc.en_factura) cg
      ON cg.monto IS NOT NULL
   CROSS JOIN LATERAL (SELECT round(COALESCE(c.subtotal,0)+COALESCE(c.bonificaciones,0)+COALESCE(c.iva,0)
                                    +COALESCE(c.impuestos_internos,0)+COALESCE(c.percepcion_iva,0)
                                    +COALESCE(c.percepcion_iibb,0)+COALESCE(c.no_gravado,0)
                                    +COALESCE(c.otros_impuestos,0)+cg.monto, 2) AS t) z
    LEFT JOIN LATERAL (SELECT sum(n.total) AS acreditado FROM notas_credito n
                        WHERE n.compra_id = c.id AND n.sucursal_id = c.sucursal_id) nc ON true
   WHERE c.tipo_factura = 'ZZ' AND c.estado <> 'cancelada'
     AND abs(COALESCE(c.total, 0) - z.t) > 1.0;

  SELECT count(*) FILTER (WHERE nuevo >= 0 AND acreditado <= nuevo AND nuevo > antes),
         count(*) FILTER (WHERE nuevo >= 0 AND acreditado <= nuevo AND nuevo < antes),
         count(*) FILTER (WHERE acreditado > 0),
         count(*) FILTER (WHERE nuevo >= 0 AND acreditado > nuevo),
         count(*) FILTER (WHERE nuevo < 0)
    INTO n_sube, n_baja, n_con_nc, n_queda_nc, n_negativa
    FROM m10_zz;

  UPDATE compras c
     SET total = m.nuevo
    FROM m10_zz m
   WHERE c.id = m.id AND m.nuevo >= 0 AND m.acreditado <= m.nuevo;
  GET DIAGNOSTICS n_hechas = ROW_COUNT;

  RAISE NOTICE 'mig NNN · R3 · ZZ vivas con cargos en factura y otro total: % suben y % bajan (% rehechas); % tienen notas de crédito, de las que % quedarían con más notas que total y quedan como están; % darían negativo y quedan como están',
    n_sube, n_baja, n_hechas, n_con_nc, n_queda_nc, n_negativa;
  DROP TABLE m10_zz;
END
$datos_zz$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
  v_mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._dias_atras_fecha_pedido(bigint)', 'd9c04f85466d1a1cb9aa12a8fdac48bd', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._fecha_entrega_fuera_de_rango(date,bigint,boolean)', 'fc084a8c422d38311dccb2e18b28c678', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._fecha_pedido_fuera_de_rango(date,bigint)', '622d138415e27e21724f5a15fd2269ee', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.aplicar_cambio_de_parada(bigint,uuid,date)', 'bd549595eab0d84e0dbd00b01e18dcdd', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     '0dcda74a5a6af9464a91734a964a441b', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     'b6758a13fe11c4df630f6596ec5b0994', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.auditoria_definer_sin_rol()', 'baa75494fe0a36ff59cb3398148f5f84', true, '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      v_mal := v_mal || format(E'\n  %s (md5 %s, acl %s, definer %s)', r.f, x.h, x.a, x.def);
    END IF;
  END LOOP;
  IF v_mal <> '' THEN
    RAISE EXCEPTION 'mig NNN · no quedaron como en el repo:%', v_mal;
  END IF;
END
$post$;

COMMIT;
