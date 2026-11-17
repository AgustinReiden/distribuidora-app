-- =========================================================================
-- NNN · COMPRAS, NOTAS DE CRÉDITO DE COMPRA Y ENVÍOS ENTRE SUCURSALES
--       (plan #1603, ola 2, tarjeta B2: 1590-a, 1590-b, 1557-b4, 1557-b5,
--        1557-b7, 1557-b10, 1558-b8, 1593-b1, 1593-b3, 1593-b5, STK-12,
--        STK-14, STK-16 y SEG-1 de actualizar_compra_items)
--
-- Columnas nuevas en `notas_credito` (la anulación y los lotes que tomó la
-- nota) y en `movimiento_sucursal_items` (el costo real del origen al
-- aceptar), un índice único por CUIT limpio en `proveedores`, cinco funciones
-- nuevas (una RPC y cuatro helpers de server) y parches por ancla, con
-- premisa de md5 sobre los cuerpos vivos (ledger en la 512), a
-- `registrar_compra_completa`, `actualizar_compra_items`,
-- `registrar_nota_credito`, `registrar_nota_credito_lote`,
-- `aceptar_movimiento_sucursal`, `sincronizar_lotes_compra`, `_cpp_arrastrar`,
-- `_cpp_devolucion_compra`, `_reposicion_desde_ultima_compra` y
-- `_ninguna_compra_mas_nueva`. No cambia firmas. No corrige filas.
-- Ensayo: scripts/test-compras-nc-envios-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1590-a · UNA NOTA DE CRÉDITO DE COMPRA SE ANULA (decisión del dueño, D15)
-- =========================================================================
-- `anular_nota_credito_compra(nota, motivo)`, de admin y encargado (los mismos
-- que la registran), con motivo obligatorio. La nota NO se borra (es un
-- comprobante del proveedor: `notas_credito_proteger_vinculo` y
-- `nota_credito_items_inmutable` siguen igual): queda `anulada`, con quién,
-- cuándo y por qué, y todo lo que suma las notas de una compra la deja afuera.
-- Una devolución anulada deshace lo que hizo la nota:
--   · el stock vuelve (origen 'nota_credito_anulada', a la bolsa) y cada lote
--     recibe lo que la nota le sacó (`notas_credito.lotes_tomados`, que desde
--     acá anotan las dos puertas; `_mov_lotes_devolver`, con tope en su
--     hueco). Una nota de antes de esta migración no anotó sus lotes: lo suyo
--     vuelve a la bolsa;
--   · el promedio, con la misma cuenta que la nota, al revés
--     (`_cpp_devolucion_compra` con lo devuelto en negativo);
--   · la reposición, si la nota había devuelto entero el producto (1557-b5).
-- Un ajuste anulado sólo libera lo que le quedaba a la compra: con un ajuste
-- de 800 sobre 1.000, anularlo deja devolver toda la mercadería (el tope de
-- la 501 sigue, ahora sin las anuladas).
-- Elegí anular y no la valuación neta de los ajustes: es lo que decidió el
-- dueño. Y la anulación como marca, no como borrado, porque la nota es un
-- comprobante y su historia (el ledger de stock la referencia) no se pierde.
-- Lo que NO es de esta tarjeta y tiene que filtrar `NOT anulada` antes de que
-- el front ofrezca anular (los números de esas pantallas contarían la nota
-- anulada): `reporte_gerencial` (B8b), `posicion_fiscal`, y el front
-- (`notaCredito.ts`, `ModalNotaCredito`: lo que le queda a la compra).
-- `actualizar_compra_items`, `anular_compra_atomica`, `cambiar_proveedor_compra`
-- y `compras_proteger_cancelacion` siguen contando toda nota, anulada o no:
-- una compra que tuvo una nota no se edita ni se anula (lo conservador).
--
-- =========================================================================
-- 1590-b · LA DEVOLUCIÓN SE VALÚA NETA DE LOS DESCUENTOS DE CABECERA (D16)
-- =========================================================================
-- Cada producto se acreditaba al costo neto promedio de sus renglones, sin
-- la bonificación de la factura ni los descuentos en factura: devolver todo
-- acreditaba más que lo pagado (ZZ de 10 × 100 con un descuento de −150:
-- 1.000 sobre 850). Ahora ese costo se multiplica por
-- `_compra_factor_neto(compra)` = (neto de los renglones + descuentos) / neto,
-- con los descuentos de cabecera en negativo: en una ZZ, sus cargos en factura
-- negativos; en una FC, sus cargos gravados en factura negativos más la parte
-- de `compras.bonificaciones` que no explican sus cargos (si es negativa). Un
-- flete no suma (el factor no pasa de 1). El IVA sale del subtotal neto; el
-- impuesto interno ya era el de la cabecera, prorrateado. La ZZ de arriba
-- acredita 850. Las dos puertas (factura entera y por lote).
-- El front sigue mandando el importe sin el factor (lo valúa
-- `notaCredito.ts`): `registrar_nota_credito` acepta lo que mande la pantalla
-- con o sin el factor, y guarda el neto. Un front viejo y uno nuevo andan.
--
-- =========================================================================
-- 1557-b4 · EL AJUSTE DE UNA COMPRA SIN CRÉDITO FISCAL NO LLEVA IVA NI II
-- =========================================================================
-- Sobre una ZZ, B o C la nota de ajuste aceptaba IVA e impuestos internos (el
-- cuadre sólo pedía subtotal + IVA + II = total). Se rechaza con el motivo.
--
-- =========================================================================
-- 1557-b5 · UNA COMPRA DEVUELTA ENTERA YA NO ES LA REPOSICIÓN (D10)
-- =========================================================================
-- Si las notas vigentes devuelven todas las unidades de un producto de una
-- compra (`_compra_producto_devuelto`), esa compra deja de ser la «más nueva»
-- para la reposición en los tres lugares que la eligen
-- (`_reposicion_desde_ultima_compra`, `_ninguna_compra_mas_nueva` y el alta),
-- y la nota que la deja devuelta vuelve la reposición a la compra anterior
-- (`_reposicion_tras_nota`, si esta compra era la que la fijaba). Sin otra
-- compra, la reposición queda y la nota avisa. Va por producto: devolver toda
-- la compra es el caso de todos sus productos. Anular la nota la repone.
--
-- =========================================================================
-- 1557-b7 · LA CORRECCIÓN DE LA ÚLTIMA COMPRA NO PISA EL ENVÍO (D12)
-- =========================================================================
-- Aceptar un envío deja en el destino el mayor de los dos costos de reposición
-- (como hoy), pero corregir después la última compra, anularla o la nota que
-- la devuelve recalculaban la reposición desde la compra sola. Ahora se aplica
-- encima el mayor de los envíos aceptados después de esa compra
-- (`_reposicion_aplicar_envios`): el costo real del origen al aceptar (columna
-- nueva `origen_costo_real`, que guarda `aceptar_movimiento_sucursal`) y los
-- costos con y sin IVA de la foto del envío. Un envío aceptado antes de esta
-- migración no guardó el costo real: aplica sólo los otros dos.
--
-- =========================================================================
-- 1558-b8 · UN ENVÍO A UN PRODUCTO DESACTIVADO LO REACTIVA (D7)
-- =========================================================================
-- La decisión: es normal que la otra sucursal lo tenga desactivado, y se puede.
-- `aceptar_movimiento_sucursal` ya lo aceptaba; ahora lo reactiva (el front
-- pide confirmarlo, B11a) y lo devuelve en `reactivados`.
--
-- =========================================================================
-- STK-16 · EL ENVÍO GUARDA SIEMPRE LA FOTO DEL PROMEDIO CON QUE SE MEZCLÓ
-- =========================================================================
-- Sin foto del promedio del origen, aceptar mezclaba con el promedio vivo del
-- origen y `_cpp_arrastrar` descartaba ese envío de la cadena. Aceptar guarda
-- ahora en `origen_costo_promedio` el que usó. Los anteriores quedan como
-- están (no se sabe con qué promedio se mezclaron).
--
-- =========================================================================
-- 1593-b1 · EL COSTO CON IVA LLEVA LOS CARGOS Y EL FACTOR DEL II DECLARADO
-- =========================================================================
-- `productos.costo_con_iva` se calculaba con el neto del renglón, sin lo que
-- el motor le suma al costo real (cargos prorrateados y el ajuste del II
-- declarado). Ahora suma esa diferencia (costo real del motor menos el costo
-- real sin cargos): FC A de 10 × 100 al 21 % con un flete de 100 da 131, no
-- 121. El IVA del cargo no entra. En el alta, la edición y la reposición.
--
-- =========================================================================
-- 1593-b3 · UNA FC B O C NO TRAE IVA NI II DISCRIMINADOS
-- =========================================================================
-- Mandada directo a la RPC con IVA o II, la compra guardaba el total tipeado
-- con el IVA en 0 y COMPRA-A1 la contaba. El alta y la edición la rechazan.
--
-- =========================================================================
-- 1593-b5 · EL NÚMERO DE LA NOTA, CON SU MOTIVO
-- =========================================================================
-- `notas_credito.numero_nota` es varchar(50): uno más largo salía como error
-- crudo. Las dos puertas lo rechazan antes, con el motivo.
--
-- =========================================================================
-- STK-12 · LA BAJA DE UNA COMPRA NO DEJA UN LOTE EN 1/0
-- =========================================================================
-- La segunda pasada del recorte (482) dejaba un lote intacto que se sacaba
-- entero en cantidad 1 y restante 0 (el CHECK no deja cantidad 0): una unidad
-- «consumida» que no se vendió, que pasaba a la bolsa si la app volvía a
-- mandar ese lote. Ahora ese lote se borra, si nada lo referencia (traza de
-- pedidos, de envíos, salvedades o promos); si algo lo referencia, queda como
-- antes.
--
-- =========================================================================
-- STK-14 · SINCRONIZAR LOS LOTES DE UNA COMPRA TIENE LAS REGLAS DE EDITARLA
-- =========================================================================
-- Por llamada directa aceptaba una compra con notas de crédito, fuera de los
-- 7 días y de un encargado. Ahora: no con notas vigentes; no con más de 7 días;
-- y el encargado sólo carga los vencimientos de una compra que todavía no
-- tiene lotes (el alta). Cambiar los de una que ya los tiene es editarla, y
-- eso es del admin. El rol sale de `es_encargado_o_admin()` (mira `activo`).
--
-- =========================================================================
-- 1557-b10 · EL CUIT DE UN PROVEEDOR ES ÚNICO POR SUCURSAL, SIN GUIONES (D13)
-- =========================================================================
-- Índice único sobre (sucursal, sólo los dígitos del CUIT), para los que
-- tienen CUIT. La premisa aborta con el listado si hoy hay duplicados.
--
-- =========================================================================
-- SEG-1 (#1545) · `actualizar_compra_items` lee el rol mirando `activo`
-- =========================================================================
-- No se reproduce: a un desactivado ya lo corta `current_sucursal_id()`. Es la
-- regla de CLAUDE.md, y queda.
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
-- Premisas: los cuerpos vivos son los de la 512, lo nuevo no existe, y los
-- CUIT no se repiten
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
  n bigint;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     '0dcda74a5a6af9464a91734a964a441b'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     'b6758a13fe11c4df630f6596ec5b0994'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
     '6f1ef71ffd327350df3155c349566670'),
    ('public.registrar_nota_credito_lote(bigint,numeric,text,text)',        'ef8ac9ee30035f126cde426684a9ceb3'),
    ('public.aceptar_movimiento_sucursal(bigint,jsonb)',                    'cb4b0f2b893789f17d0b262d46502dcb'),
    ('public.sincronizar_lotes_compra(bigint,jsonb)',                       '426eb0b3e2e4997d277eb67af4546eaf'),
    ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)',
     '7c8743b01b69353d8ae70097dc248232'),
    ('public._cpp_devolucion_compra(bigint,bigint,bigint,integer,integer)', 'c895b266e0b95b539c9e17bbf180d507'),
    ('public._reposicion_desde_ultima_compra(bigint,bigint)',               'b6a62cf44019d612066791478f003b9a'),
    ('public._ninguna_compra_mas_nueva(bigint,bigint,bigint)',              'dd181864a52dd1a429ef59031f4c5a9a'),
    ('public._mov_lotes_devolver(bigint,jsonb)',                            '83ef22b3b0143bf318ead07069ac916e')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  FOR r IN SELECT * FROM (VALUES
    ('public.anular_nota_credito_compra(bigint,text)'),
    ('public._compra_producto_devuelto(bigint,bigint,bigint)'),
    ('public._compra_factor_neto(bigint,bigint)'),
    ('public._reposicion_aplicar_envios(bigint,bigint,timestamp with time zone)'),
    ('public._reposicion_tras_nota(bigint,bigint,bigint)')
  ) AS t(f) LOOP
    IF to_regprocedure(r.f) IS NOT NULL THEN
      RAISE EXCEPTION 'mig NNN · % ya existe', r.f;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public'
                AND ((table_name = 'notas_credito'
                      AND column_name IN ('anulada', 'anulada_at', 'anulada_por', 'motivo_anulacion', 'lotes_tomados'))
                  OR (table_name = 'movimiento_sucursal_items' AND column_name = 'origen_costo_real'))) THEN
    RAISE EXCEPTION 'mig NNN · alguna columna nueva ya existe';
  END IF;

  -- 1557-b10: el índice único no entra si hoy hay dos proveedores de una
  -- sucursal con el mismo CUIT (sólo los dígitos). Se listan para que el dueño
  -- decida cuál queda.
  SELECT string_agg(format('sucursal %s, CUIT %s: %s', d.sucursal_id, d.cuit, d.cuales), '; ' ORDER BY d.sucursal_id, d.cuit)
    INTO v
    FROM (SELECT p.sucursal_id, regexp_replace(p.cuit, '[^0-9]', '', 'g') AS cuit,
                 string_agg(format('#%s %s (%s)', p.id, p.nombre, CASE WHEN COALESCE(p.activo, true) THEN 'activo' ELSE 'inactivo' END),
                            ', ' ORDER BY p.id) AS cuales
            FROM proveedores p
           WHERE regexp_replace(COALESCE(p.cuit, ''), '[^0-9]', '', 'g') <> ''
           GROUP BY 1, 2
          HAVING count(*) > 1) d;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · 1557-b10 · hay proveedores con el mismo CUIT en la misma sucursal: %. Que el dueño decida cuál queda (y le cambie el CUIT o lo elimine al otro) antes de aplicar.', v;
  END IF;

  SELECT count(*) INTO n
    FROM movimiento_sucursal_items mi JOIN movimientos_sucursal m ON m.id = mi.movimiento_id
   WHERE m.estado = 'aceptada' AND mi.origen_costo_promedio IS NULL;
  RAISE NOTICE 'mig NNN · STK-16 · envíos aceptados sin foto del promedio del origen (quedan como están): %', n;
  SELECT count(*) INTO n FROM notas_credito WHERE tipo = 'devolucion';
  RAISE NOTICE 'mig NNN · 1590-a · notas de devolución sin los lotes anotados (anularlas devuelve a la bolsa): %', n;
END
$premisas$;

-- Reemplaza las p_n apariciones de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text, p_n int DEFAULT 1)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> p_n THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba %', p_que, v_n, p_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- Las columnas y el índice
-- =========================================================================
ALTER TABLE public.notas_credito
  ADD COLUMN anulada          boolean     NOT NULL DEFAULT false,
  ADD COLUMN anulada_at       timestamptz,
  ADD COLUMN anulada_por      uuid REFERENCES public.perfiles(id) ON DELETE SET NULL,
  ADD COLUMN motivo_anulacion text,
  ADD COLUMN lotes_tomados    jsonb;

ALTER TABLE public.notas_credito
  ADD CONSTRAINT notas_credito_anulacion_coherente
  CHECK (anulada = (anulada_at IS NOT NULL) AND (NOT anulada OR motivo_anulacion IS NOT NULL));

COMMENT ON COLUMN public.notas_credito.anulada IS
  'mig NNN (1590-a, #1590): la nota se anuló con anular_nota_credito_compra. No se borra (es un comprobante); todo lo que suma las notas de una compra la deja afuera.';
COMMENT ON COLUMN public.notas_credito.lotes_tomados IS
  'mig NNN (1590-a, #1590): [{producto_id, lote_id, cantidad}] que la devolución le sacó a cada lote de su compra. Anularla se lo devuelve. NULL en las notas de antes.';

-- Un número calculado (el costo real del origen al aceptar): sin piso, sin NaN
-- ni infinito (numeric sin precisión).
ALTER TABLE public.movimiento_sucursal_items
  ADD COLUMN origen_costo_real numeric
  CONSTRAINT movimiento_sucursal_items_origen_costo_real_numero
  CHECK (origen_costo_real <> 'NaN' AND origen_costo_real <> 'Infinity' AND origen_costo_real <> '-Infinity');

COMMENT ON COLUMN public.movimiento_sucursal_items.origen_costo_real IS
  'mig NNN (1557-b7, #1557): el costo real del producto de origen cuando se aceptó el envío (el que entra en el GREATEST del destino). NULL en los de antes.';

CREATE UNIQUE INDEX proveedores_cuit_unico_por_sucursal
  ON public.proveedores (sucursal_id, (regexp_replace(cuit, '[^0-9]', '', 'g')))
  WHERE regexp_replace(COALESCE(cuit, ''), '[^0-9]', '', 'g') <> '';

COMMENT ON INDEX public.proveedores_cuit_unico_por_sucursal IS
  'mig NNN (1557-b10, decisión del dueño D13): el CUIT de un proveedor es único por sucursal, comparado sólo por sus dígitos.';

-- =========================================================================
-- Los helpers nuevos (de server)
-- =========================================================================
CREATE FUNCTION public._compra_producto_devuelto(p_compra bigint, p_producto bigint, p_sucursal bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- mig NNN (1557-b5, #1557): las notas de crédito vigentes de la compra devuelven todas las
  -- unidades que trajo de este producto. Una compra así ya no es la reposición de nadie (D10).
  SELECT COALESCE(c.comprado > 0 AND d.devuelto >= c.comprado, false)
    FROM (SELECT SUM(ci.cantidad) AS comprado
            FROM compra_items ci
           WHERE ci.compra_id = p_compra AND ci.producto_id = p_producto AND ci.sucursal_id = p_sucursal) c,
         (SELECT COALESCE(SUM(nci.cantidad), 0) AS devuelto
            FROM nota_credito_items nci
            JOIN notas_credito nc ON nc.id = nci.nota_credito_id AND nc.sucursal_id = nci.sucursal_id
           WHERE nc.compra_id = p_compra AND nc.sucursal_id = p_sucursal AND NOT nc.anulada
             AND nci.producto_id = p_producto) d;
$function$;

CREATE FUNCTION public._compra_factor_neto(p_compra bigint, p_sucursal bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- mig NNN (1590-b, #1590; decisión del dueño D16): lo que vale cada peso del neto de los
  -- renglones después de los descuentos de cabecera. Una devolución se valúa con esto: nunca
  -- acredita más que lo pagado. Descuentos (en negativo): en una ZZ, sus cargos en factura
  -- negativos (su total los incluye, #1593); en una FC, sus cargos gravados en factura
  -- negativos (van a `bonificaciones`) más la parte de `bonificaciones` que no explican sus
  -- cargos, si es negativa. Un flete no suma: el factor no pasa de 1.
  SELECT COALESCE((
    SELECT CASE WHEN l.neto > 0 THEN LEAST(GREATEST(l.neto + d.descuento, 0) / l.neto, 1) ELSE 1 END
      FROM (SELECT COALESCE(SUM(ci.cantidad * ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)), 0) AS neto
              FROM compra_items ci
             WHERE ci.compra_id = p_compra AND ci.sucursal_id = p_sucursal) l
     CROSS JOIN (
       SELECT CASE WHEN c.tipo_factura = 'ZZ'
                   THEN COALESCE(g.neg_todos, 0)
                   ELSE COALESCE(g.neg_gravados, 0)
                        + LEAST(COALESCE(c.bonificaciones, 0) - COALESCE(g.gravados, 0), 0) END AS descuento
         FROM compras c
         LEFT JOIN LATERAL (
           SELECT SUM(cc.monto) FILTER (WHERE cc.monto < 0)                                AS neg_todos,
                  SUM(cc.monto) FILTER (WHERE cc.monto < 0 AND cc.condicion_iva = 'gravado') AS neg_gravados,
                  SUM(cc.monto) FILTER (WHERE cc.condicion_iva = 'gravado')                  AS gravados
             FROM compra_cargos cc
            WHERE cc.compra_id = c.id AND cc.sucursal_id = c.sucursal_id AND cc.en_factura) g ON true
        WHERE c.id = p_compra AND c.sucursal_id = p_sucursal) d), 1);
$function$;

CREATE FUNCTION public._reposicion_aplicar_envios(p_producto bigint, p_sucursal bigint, p_desde timestamptz)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  e record;
BEGIN
  -- mig NNN (1557-b7, #1557; decisión del dueño D12): aceptar un envío deja en el destino el
  -- mayor de los dos costos de reposición. Lo que recalcula la reposición desde una compra
  -- (corregirla, anularla, la nota que la devuelve) le aplica encima, con la misma cuenta, los
  -- envíos aceptados después de esa compra: si no, los pisaba. Un envío anterior a esta
  -- migración no guardó el costo real del origen (NULL: GREATEST lo ignora).
  SELECT count(*) AS n,
         max(mi.origen_costo_real)    AS costo_real,
         max(mi.origen_costo_con_iva) AS costo_con_iva,
         max(mi.origen_costo_sin_iva) AS costo_sin_iva
    INTO e
    FROM movimiento_sucursal_items mi
    JOIN movimientos_sucursal m ON m.id = mi.movimiento_id
   WHERE mi.producto_destino_id = p_producto
     AND m.sucursal_destino_id = p_sucursal
     AND m.estado = 'aceptada'
     AND m.resuelto_at > p_desde;
  IF e.n = 0 THEN
    RETURN;
  END IF;

  UPDATE productos p
     SET costo_real    = GREATEST(p.costo_real, e.costo_real),
         costo_con_iva = GREATEST(COALESCE(p.costo_con_iva, 0), COALESCE(e.costo_con_iva, 0)),
         costo_sin_iva = GREATEST(COALESCE(p.costo_sin_iva, 0), COALESCE(e.costo_sin_iva, 0)),
         updated_at    = now()
   WHERE p.id = p_producto AND p.sucursal_id = p_sucursal
     AND (p.costo_real, p.costo_con_iva, p.costo_sin_iva) IS DISTINCT FROM
         (GREATEST(p.costo_real, e.costo_real),
          GREATEST(COALESCE(p.costo_con_iva, 0), COALESCE(e.costo_con_iva, 0)),
          GREATEST(COALESCE(p.costo_sin_iva, 0), COALESCE(e.costo_sin_iva, 0)));
END;
$function$;

-- =========================================================================
-- 1557-b5 · la «más nueva» no es una compra devuelta entera (los dos helpers)
-- =========================================================================
DO $parche_reposicion$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public._ninguna_compra_mas_nueva(bigint,bigint,bigint)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$       AND (c.fecha_compra, c.created_at, c.id) > (yo.fecha_compra, yo.created_at, yo.id)
$a$,
$r$       AND (c.fecha_compra, c.created_at, c.id) > (yo.fecha_compra, yo.created_at, yo.id)
       -- mig NNN (1557-b5, #1557): una compra devuelta entera por sus notas ya no es la más nueva.
       AND NOT public._compra_producto_devuelto(c.id, ci.producto_id, ci.sucursal_id)
$r$, '_ninguna_compra_mas_nueva (sin las devueltas)');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public._reposicion_desde_ultima_compra(bigint,bigint)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  SELECT c.tipo_factura, c.letra_comprobante, ci.costo_unitario, ci.bonificacion,
$a$,
$r$  SELECT c.tipo_factura, c.letra_comprobante, c.created_at, ci.costo_unitario, ci.bonificacion,
$r$, '_reposicion_desde_ultima_compra (la hora de la compra)');
  v_def := pg_temp.parche(v_def,
$a$     AND public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario)
   ORDER BY c.fecha_compra DESC, c.created_at DESC, c.id DESC, ci.id DESC
$a$,
$r$     AND public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario)
     -- mig NNN (1557-b5, #1557; D10): una compra devuelta entera ya no es la reposición.
     AND NOT public._compra_producto_devuelto(c.id, ci.producto_id, ci.sucursal_id)
   ORDER BY c.fecha_compra DESC, c.created_at DESC, c.id DESC, ci.id DESC
$r$, '_reposicion_desde_ultima_compra (sin las devueltas)');
  v_def := pg_temp.parche(v_def,
$a$         costo_con_iva      = public.costo_financiero_unitario(
                                v_neto,
                                COALESCE(v_ult.iva_linea, p.porcentaje_iva),
                                COALESCE(v_ult.ii_linea, p.impuestos_internos),
                                v_tipo),
$a$,
$r$         costo_con_iva      = public.costo_financiero_unitario(
                                v_neto,
                                COALESCE(v_ult.iva_linea, p.porcentaje_iva),
                                COALESCE(v_ult.ii_linea, p.impuestos_internos),
                                v_tipo)
                              -- mig NNN (1593-b1, #1593): lo que el motor le sumó al costo
                              -- real (cargos, factor del II declarado), como el alta.
                              + COALESCE(v_ult.costo_real_unitario
                                  - public.costo_real_unitario(v_neto, COALESCE(v_ult.ii_linea, p.impuestos_internos), v_tipo, 0), 0),
$r$, '_reposicion_desde_ultima_compra (el costo con IVA)');
  v_def := pg_temp.parche(v_def,
$a$   WHERE p.id = p_producto AND p.sucursal_id = p_sucursal;

  RETURN true;
$a$,
$r$   WHERE p.id = p_producto AND p.sucursal_id = p_sucursal;

  -- mig NNN (1557-b7, #1557; D12): los envíos aceptados después de esa compra, encima.
  PERFORM public._reposicion_aplicar_envios(p_producto, p_sucursal, v_ult.created_at);

  RETURN true;
$r$, '_reposicion_desde_ultima_compra (los envíos)');
  EXECUTE v_def;
END
$parche_reposicion$;

CREATE FUNCTION public._reposicion_tras_nota(p_compra bigint, p_producto bigint, p_sucursal bigint)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- mig NNN (1557-b5, #1557; D10): una nota que devuelve entero un producto de su compra, o
  -- la anulación de esa nota, cambia cuál es la última compra del producto. Si esta compra
  -- tiene un renglón pagado de él y ninguna compra vigente más nueva, la reposición se
  -- recalcula desde la última compra (con los envíos de después). Devuelve el aviso si no
  -- queda ninguna.
  IF EXISTS (SELECT 1 FROM compra_items ci
              WHERE ci.compra_id = p_compra AND ci.producto_id = p_producto AND ci.sucursal_id = p_sucursal
                AND public._cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario))
     AND public._ninguna_compra_mas_nueva(p_compra, p_producto, p_sucursal) THEN
    IF NOT public._reposicion_desde_ultima_compra(p_producto, p_sucursal) THEN
      RETURN 'costo_no_restaurado: sin otra compra válida de referencia';
    END IF;
  END IF;
  RETURN NULL;
END;
$function$;

-- =========================================================================
-- 1590-a · el arrastre y la cuenta del promedio con las notas anuladas
-- =========================================================================
DO $parche_cpp$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$               WHERE nc.compra_id = ci.compra_id
                 AND nc.sucursal_id = ci.sucursal_id
                 AND nci.producto_id = ci.producto_id) n
$a$,
$r$               WHERE nc.compra_id = ci.compra_id
                 AND nc.sucursal_id = ci.sucursal_id
                 AND nci.producto_id = ci.producto_id
                 -- mig NNN (1590-a, #1590): una nota anulada no le saca nada a su compra.
                 AND NOT nc.anulada) n
$r$, '_cpp_arrastrar (sin las anuladas)');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public._cpp_devolucion_compra(bigint,bigint,bigint,integer,integer)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  IF COALESCE(p_devuelto, 0) <= 0 THEN
    RETURN NULL;
  END IF;
$a$,
$r$  -- mig NNN (1590-a, #1590): un p_devuelto negativo es la anulación de una nota: esas
  -- unidades vuelven a la compra, y p_antes cuenta las de la nota que se anula.
  IF COALESCE(p_devuelto, 0) = 0 THEN
    RETURN NULL;
  END IF;
$r$, '_cpp_devolucion_compra (la anulación)');
  EXECUTE v_def;
END
$parche_cpp$;

-- =========================================================================
-- El alta: 1593-b3, 1557-b5 y 1593-b1
-- =========================================================================
DO $parche_alta$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$      'Hay un importe de la cabecera que no es un número. Revisá los importes; si sigue igual, recargá la aplicación y volvé a cargarla.');
  END IF;
$a$,
$r$      'Hay un importe de la cabecera que no es un número. Revisá los importes; si sigue igual, recargá la aplicación y volvé a cargarla.');
  END IF;

  /* mig NNN (1593-b3, #1593) · UNA FC B O C NO DISCRIMINA IVA NI II: van dentro
     del precio de cada renglon (mig 293). Mandada directo con IVA o II, la compra
     guardaba el total tipeado con el IVA en 0 y COMPRA-A1 la contaba. El front ya
     los manda en 0. */
  IF NOT v_es_zz AND v_letra IN ('B', 'C')
     AND (COALESCE(p_iva, 0) <> 0 OR COALESCE(p_impuestos_internos, 0) <> 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('Una factura %s no discrimina IVA ni impuestos internos: van dentro del precio de cada renglón. Cargalos en 0.', v_letra));
  END IF;
$r$, 'registrar_compra_completa (1593-b3)');

  v_def := pg_temp.parche(v_def,
$a$       AND _cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario);
$a$,
$r$       AND _cpp_fija_costo(ci.bonificacion, ci.costo_neto_unitario, ci.costo_unitario)
       /* mig NNN (1557-b5, #1557; D10) · una compra devuelta entera ya no es la mas nueva */
       AND NOT public._compra_producto_devuelto(c.id, ci.producto_id, ci.sucursal_id);
$r$, 'registrar_compra_completa (1557-b5)');

  v_def := pg_temp.parche(v_def,
$a$      IF v_bonificacion >= 100 AND v_costo_real < 0 THEN
        v_costo_real := 0;
      END IF;
    ELSE
$a$,
$r$      IF v_bonificacion >= 100 AND v_costo_real < 0 THEN
        v_costo_real := 0;
      END IF;
      /* mig NNN (1593-b1, #1593) · el costo con IVA lleva lo que el motor le sumo al
         costo real (cargos prorrateados, factor del II declarado), sin el IVA del cargo. */
      v_costo_con_iva := v_costo_con_iva
        + (v_costo_real - costo_real_unitario(v_costo_neto, v_impuestos_internos,
                                              CASE WHEN v_sin_credito THEN 'ZZ' ELSE v_tipo_factura END, 0));
    ELSE
$r$, 'registrar_compra_completa (1593-b1)');
  EXECUTE v_def;
END
$parche_alta$;

-- =========================================================================
-- La edición: SEG-1, 1593-b3, 1593-b1, STK-12 y 1557-b7
-- =========================================================================
DO $parche_edicion$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
$a$,
$r$  -- mig NNN (SEG-1, #1545): un desactivado no tiene ningún rol (#1474).
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id AND activo IS NOT FALSE;
$r$, 'actualizar_compra_items (SEG-1)');

  v_def := pg_temp.parche(v_def,
$a$  v_iva_efectivo := CASE WHEN v_sin_credito THEN 0 ELSE p_iva END;
$a$,
$r$  v_iva_efectivo := CASE WHEN v_sin_credito THEN 0 ELSE p_iva END;

  /* mig NNN (1593-b3, #1593) · una FC B o C no discrimina IVA ni II (ver el alta). */
  IF NOT v_es_zz AND COALESCE(v_compra.letra_comprobante, 'A') IN ('B', 'C')
     AND (COALESCE(p_iva, 0) <> 0 OR COALESCE(p_impuestos_internos, 0) <> 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('Una factura %s no discrimina IVA ni impuestos internos: van dentro del precio de cada renglón. Cargalos en 0.',
             v_compra.letra_comprobante));
  END IF;
$r$, 'actualizar_compra_items (1593-b3)');

  v_def := pg_temp.parche(v_def,
$a$      IF v_bonificacion >= 100 AND v_costo_real < 0 THEN
        v_costo_real := 0;
      END IF;
    ELSE
$a$,
$r$      IF v_bonificacion >= 100 AND v_costo_real < 0 THEN
        v_costo_real := 0;
      END IF;
      /* mig NNN (1593-b1, #1593) · el costo con IVA lleva lo que el motor le sumo al
         costo real (ver el alta). */
      v_costo_con_iva := v_costo_con_iva
        + (v_costo_real - costo_real_unitario(v_costo_neto, v_impuestos_internos,
                                              CASE WHEN v_sin_credito THEN 'ZZ' ELSE v_compra.tipo_factura END, 0));
    ELSE
$r$, 'actualizar_compra_items (1593-b1)');

  v_def := pg_temp.parche(v_def,
$a$        UPDATE producto_lotes
           SET cantidad          = GREATEST(cantidad - v_t, 1),
               cantidad_restante = cantidad_restante - v_t
         WHERE id = v_lote.id;
$a$,
$r$        /* mig NNN (STK-12, #1542) · el lote intacto que la segunda pasada saca entero
           quedaba en 1/0: una unidad "consumida" que no se vendio, y si la app volvia
           a mandar el lote pasaba a la bolsa. Se borra, si nada lo referencia (la
           traza de pedidos y de envios, una salvedad o una promo); si no, queda como
           antes. */
        IF v_lote.cantidad - v_t <= 0
           AND NOT EXISTS (SELECT 1 FROM pedido_item_lotes pil WHERE pil.lote_id = v_lote.id)
           AND NOT EXISTS (SELECT 1 FROM movimiento_sucursal_item_lotes mil WHERE mil.lote_id = v_lote.id)
           AND NOT EXISTS (SELECT 1 FROM salvedades_items s
                            CROSS JOIN LATERAL jsonb_array_elements(
                              CASE WHEN jsonb_typeof(s.lotes_devueltos) = 'array'
                                   THEN s.lotes_devueltos ELSE '[]'::JSONB END) e
                           WHERE s.sucursal_id = v_sucursal AND e->>'lote_id' = v_lote.id::TEXT)
           AND NOT EXISTS (SELECT 1 FROM promo_ajustes pa
                            CROSS JOIN LATERAL jsonb_array_elements(
                              CASE WHEN jsonb_typeof(pa.lotes_pendientes) = 'array'
                                   THEN pa.lotes_pendientes ELSE '[]'::JSONB END) e
                           WHERE e->>'lote_id' = v_lote.id::TEXT) THEN
          DELETE FROM producto_lotes WHERE id = v_lote.id;
        ELSE
          UPDATE producto_lotes
             SET cantidad          = GREATEST(cantidad - v_t, 1),
                 cantidad_restante = cantidad_restante - v_t
           WHERE id = v_lote.id;
        END IF;
$r$, 'actualizar_compra_items (STK-12)');

  v_def := pg_temp.parche(v_def,
$a$             ultimo_tipo_compra = v_tipo_producto,
             updated_at         = NOW()
       WHERE id = v_producto_id AND sucursal_id = v_sucursal;
$a$,
$r$             ultimo_tipo_compra = v_tipo_producto,
             updated_at         = NOW()
       WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      -- mig NNN (1557-b7, #1557; D12): los envíos aceptados después de la compra, encima.
      PERFORM public._reposicion_aplicar_envios(v_producto_id, v_sucursal, v_compra.created_at);
$r$, 'actualizar_compra_items (1557-b7)');
  EXECUTE v_def;
END
$parche_edicion$;

-- =========================================================================
-- La nota de crédito por factura: 1593-b5, 1557-b4, 1590-a, 1590-b, 1557-b5
-- =========================================================================
DO $parche_nc$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_resta NUMERIC;  -- #1557 (CMP-2)
$a$,
$r$  v_resta NUMERIC;  -- #1557 (CMP-2)
  v_compra RECORD;                   -- mig NNN (1557-b4)
  v_factor NUMERIC;                  -- mig NNN (1590-b)
  v_sub_bruto NUMERIC; v_iva_bruto NUMERIC;  -- mig NNN (1590-b)
  v_lotes JSONB := '[]'::JSONB;      -- mig NNN (1590-a)
$r$, 'registrar_nota_credito (declaración)');

  v_def := pg_temp.parche(v_def,
$a$    RETURN jsonb_build_object('success', false, 'error', 'La nota de credito se registra a nombre de quien la carga');
  END IF;
$a$,
$r$    RETURN jsonb_build_object('success', false, 'error', 'La nota de credito se registra a nombre de quien la carga');
  END IF;

  -- mig NNN (1593-b5, #1593): el número entra en varchar(50); más largo salía como error crudo.
  IF length(btrim(COALESCE(p_numero_nota, ''))) > 50 THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('El número de la nota de crédito tiene %s caracteres y entran hasta 50.', length(btrim(p_numero_nota))));
  END IF;
$r$, 'registrar_nota_credito (1593-b5)');

  v_def := pg_temp.parche(v_def,
$a$  PERFORM 1 FROM compras
   WHERE id = p_compra_id AND estado <> 'cancelada' AND sucursal_id = v_sucursal
     FOR SHARE;
$a$,
$r$  -- mig NNN (1557-b4): con el tipo de la factura, para el ajuste.
  SELECT tipo_factura, letra_comprobante INTO v_compra FROM compras
   WHERE id = p_compra_id AND estado <> 'cancelada' AND sucursal_id = v_sucursal
     FOR SHARE;
$r$, 'registrar_nota_credito (la compra)');

  v_def := pg_temp.parche(v_def,
$a$                    WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
                    GROUP BY 1) ac ON ac.producto_id = pe.producto_id
$a$,
$r$                    WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
                      AND NOT nc.anulada  -- mig NNN (1590-a)
                    GROUP BY 1) ac ON ac.producto_id = pe.producto_id
$r$, 'registrar_nota_credito (lo acreditado, sin las anuladas)');

  v_def := pg_temp.parche(v_def,
$a$      RETURN jsonb_build_object('success', false, 'error', 'Una nota de credito sin mercaderia necesita un motivo');
    END IF;
$a$,
$r$      RETURN jsonb_build_object('success', false, 'error', 'Una nota de credito sin mercaderia necesita un motivo');
    END IF;
    /* mig NNN (1557-b4, #1557) · una compra sin credito fiscal (ZZ, B o C) no lleva
       IVA ni II: su nota de ajuste tampoco. El cuadre de abajo los aceptaba. */
    IF (v_compra.tipo_factura = 'ZZ' OR upper(COALESCE(v_compra.letra_comprobante, '')) IN ('B', 'C'))
       AND (COALESCE(p_iva, 0) <> 0 OR COALESCE(p_impuestos_internos, 0) <> 0) THEN
      RETURN jsonb_build_object('success', false, 'error',
        'La compra no tiene crédito fiscal (ZZ, B o C): su nota de crédito no lleva IVA ni impuestos internos. El total es el subtotal.');
    END IF;
$r$, 'registrar_nota_credito (1557-b4)');

  -- el tope de lo que le queda a la compra, en el ajuste y en la devolución
  v_def := pg_temp.parche(v_def,
$a$WHERE nc.compra_id = c.id AND nc.sucursal_id = c.sucursal_id), 0)
$a$,
$r$WHERE nc.compra_id = c.id AND nc.sucursal_id = c.sucursal_id
                                  AND NOT nc.anulada), 0)  -- mig NNN (1590-a)
$r$, 'registrar_nota_credito (lo que le queda, sin las anuladas)', 2);

  v_def := pg_temp.parche(v_def,
$a$                WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
                  AND nc.tipo = 'ajuste') THEN
$a$,
$r$                WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
                  AND nc.tipo = 'ajuste' AND NOT nc.anulada) THEN  -- mig NNN (1590-a)
$r$, 'registrar_nota_credito (el ajuste vigente)');

  v_def := pg_temp.parche(v_def,
$a$    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.producto_id)
      INTO v_lineas
      FROM (
        SELECT pe.producto_id, pe.cantidad, pe.sub_front, pr.stock, pr.nombre,
               co.neto / co.comprado AS costo,
               round(pe.cantidad * co.neto / co.comprado, 2) AS subtotal,
               round(round(pe.cantidad * co.neto / co.comprado, 2)
                     * COALESCE(co.base_iva / NULLIF(co.neto, 0), 0) / 100, 2) AS iva
$a$,
$r$    /* mig NNN (1590-b, #1590; decision del dueño D16) · NETA DE LOS DESCUENTOS DE
       CABECERA. El costo de cada producto se multiplica por el factor de la compra
       (_compra_factor_neto): devolver todo nunca acredita mas que lo pagado (una ZZ
       de 10 x 100 con un descuento de -150 acreditaba 1.000 sobre 850). `subtotal` e
       `iva` son lo que se acredita; `subtotal_bruto` e `iva_bruto`, la cuenta sin el
       factor, que es la que hace un front de antes: se acepta cualquiera de las dos. */
    v_factor := public._compra_factor_neto(p_compra_id, v_sucursal);
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.producto_id)
      INTO v_lineas
      FROM (
        SELECT pe.producto_id, pe.cantidad, pe.sub_front, pr.stock, pr.nombre,
               co.neto / co.comprado * v_factor AS costo,
               round(pe.cantidad * co.neto / co.comprado * v_factor, 2) AS subtotal,
               round(round(pe.cantidad * co.neto / co.comprado * v_factor, 2)
                     * COALESCE(co.base_iva / NULLIF(co.neto, 0), 0) / 100, 2) AS iva,
               round(pe.cantidad * co.neto / co.comprado, 2) AS subtotal_bruto,
               round(round(pe.cantidad * co.neto / co.comprado, 2)
                     * COALESCE(co.base_iva / NULLIF(co.neto, 0), 0) / 100, 2) AS iva_bruto
$r$, 'registrar_nota_credito (1590-b, el factor)');

  v_def := pg_temp.parche(v_def,
$a$    SELECT COALESCE(sum(l.subtotal), 0), COALESCE(sum(l.iva), 0)
      INTO v_subtotal, v_iva
      FROM jsonb_to_recordset(v_lineas) AS l(subtotal NUMERIC, iva NUMERIC);
$a$,
$r$    SELECT COALESCE(sum(l.subtotal), 0), COALESCE(sum(l.iva), 0),
           COALESCE(sum(l.subtotal_bruto), 0), COALESCE(sum(l.iva_bruto), 0)
      INTO v_subtotal, v_iva, v_sub_bruto, v_iva_bruto
      FROM jsonb_to_recordset(v_lineas) AS l(subtotal NUMERIC, iva NUMERIC, subtotal_bruto NUMERIC, iva_bruto NUMERIC);
$r$, 'registrar_nota_credito (1590-b, las sumas)');

  v_def := pg_temp.parche(v_def,
$a$      FROM jsonb_to_recordset(v_lineas) AS l(producto_id BIGINT, nombre TEXT, sub_front NUMERIC, subtotal NUMERIC)
     WHERE l.sub_front IS NULL OR abs(l.sub_front - l.subtotal) > 0.05;
    IF v_mal IS NULL AND (abs(COALESCE(p_subtotal, 0) - v_subtotal) > 1 OR abs(COALESCE(p_iva, 0) - v_iva) > 1) THEN
$a$,
$r$      FROM jsonb_to_recordset(v_lineas) AS l(producto_id BIGINT, nombre TEXT, sub_front NUMERIC, subtotal NUMERIC,
                                              subtotal_bruto NUMERIC)
     WHERE l.sub_front IS NULL
        OR (abs(l.sub_front - l.subtotal) > 0.05 AND abs(l.sub_front - l.subtotal_bruto) > 0.05);  -- mig NNN (1590-b)
    IF v_mal IS NULL
       AND (abs(COALESCE(p_subtotal, 0) - v_subtotal) > 1 OR abs(COALESCE(p_iva, 0) - v_iva) > 1)
       AND (abs(COALESCE(p_subtotal, 0) - v_sub_bruto) > 1 OR abs(COALESCE(p_iva, 0) - v_iva_bruto) > 1) THEN
$r$, 'registrar_nota_credito (1590-b, lo que manda la pantalla)');

  v_def := pg_temp.parche(v_def,
$a$  VALUES (p_compra_id, p_numero_nota, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
$a$,
$r$  VALUES (p_compra_id, NULLIF(btrim(COALESCE(p_numero_nota, '')), ''),  -- mig NNN (1593-b5), como la nota por lote
          (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
$r$, 'registrar_nota_credito (el número)');

  v_def := pg_temp.parche(v_def,
$a$        UPDATE producto_lotes SET cantidad_restante = cantidad_restante - v_toma WHERE id = v_lote.id;
        v_de_lotes := v_de_lotes - v_toma;
$a$,
$r$        UPDATE producto_lotes SET cantidad_restante = cantidad_restante - v_toma WHERE id = v_lote.id;
        v_de_lotes := v_de_lotes - v_toma;
        -- mig NNN (1590-a, #1590): lo anota, para que anular la nota se lo devuelva.
        v_lotes := v_lotes || jsonb_build_object('producto_id', v_linea.producto_id,
                                                 'lote_id', v_lote.id, 'cantidad', v_toma);
$r$, 'registrar_nota_credito (los lotes que toma)');

  v_def := pg_temp.parche(v_def,
$a$          WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
            AND nci.producto_id = v_linea.producto_id AND nc.id <> v_nota_id),
$a$,
$r$          WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal
            AND nci.producto_id = v_linea.producto_id AND nc.id <> v_nota_id
            AND NOT nc.anulada),  -- mig NNN (1590-a)
$r$, 'registrar_nota_credito (lo devuelto antes, sin las anuladas)');

  v_def := pg_temp.parche(v_def,
$a$          'warning', 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo');
      END IF;
    END LOOP;
  END IF;
$a$,
$r$          'warning', 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo');
      END IF;

      -- mig NNN (1557-b5, #1557; D10): si con esta nota la compra quedó devuelta entera
      -- para el producto, la reposición vuelve a la compra anterior.
      IF public._compra_producto_devuelto(p_compra_id, v_linea.producto_id, v_sucursal) THEN
        v_aviso := public._reposicion_tras_nota(p_compra_id, v_linea.producto_id, v_sucursal);
        IF v_aviso IS NOT NULL THEN
          v_avisos := v_avisos || jsonb_build_object('producto_id', v_linea.producto_id, 'warning', v_aviso);
        END IF;
      END IF;
    END LOOP;

    -- mig NNN (1590-a, #1590): los lotes que tomó la devolución.
    UPDATE notas_credito SET lotes_tomados = v_lotes WHERE id = v_nota_id;
  END IF;
$r$, 'registrar_nota_credito (1557-b5 y los lotes)');
  EXECUTE v_def;
END
$parche_nc$;

-- =========================================================================
-- La nota de crédito por lote: 1593-b5, 1590-a, 1590-b, 1557-b5
-- =========================================================================
DO $parche_nc_lote$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_resta      numeric;  -- mig NNN (#1565)
$a$,
$r$  v_resta      numeric;  -- mig NNN (#1565)
  v_aviso_rep  text;     -- mig NNN (1557-b5)
$r$, 'registrar_nota_credito_lote (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  v_cant := p_cantidad::integer;
$a$,
$r$  v_cant := p_cantidad::integer;

  -- mig NNN (1593-b5, #1593): el número entra en varchar(50); más largo salía como error crudo.
  IF length(btrim(COALESCE(p_numero_nota, ''))) > 50 THEN
    RAISE EXCEPTION 'El número de la nota de crédito tiene % caracteres y entran hasta 50.', length(btrim(p_numero_nota));
  END IF;
$r$, 'registrar_nota_credito_lote (1593-b5)');

  v_def := pg_temp.parche(v_def,
$a$   WHERE nc.compra_id = v_lote.compra_id
     AND nc.sucursal_id = v_sucursal
     AND nci.producto_id = v_lote.producto_id;
$a$,
$r$   WHERE nc.compra_id = v_lote.compra_id
     AND nc.sucursal_id = v_sucursal
     AND nci.producto_id = v_lote.producto_id
     AND NOT nc.anulada;  -- mig NNN (1590-a)
$r$, 'registrar_nota_credito_lote (lo acreditado, sin las anuladas)');

  v_def := pg_temp.parche(v_def,
$a$  IF v_comprado IS NULL THEN
    RAISE EXCEPTION 'La compra % ya no tiene ninguna línea de este producto: no se puede resolver el costo de la nota de crédito',
      v_lote.compra_id;
  END IF;
$a$,
$r$  IF v_comprado IS NULL THEN
    RAISE EXCEPTION 'La compra % ya no tiene ninguna línea de este producto: no se puede resolver el costo de la nota de crédito',
      v_lote.compra_id;
  END IF;

  -- mig NNN (1590-b, #1590; D16): neto de los descuentos de cabecera, como la nota por factura.
  v_costo := v_costo * public._compra_factor_neto(v_lote.compra_id, v_sucursal);
$r$, 'registrar_nota_credito_lote (1590-b)');

  v_def := pg_temp.parche(v_def,
$a$                AND nc.tipo = 'ajuste') THEN
$a$,
$r$                AND nc.tipo = 'ajuste' AND NOT nc.anulada) THEN  -- mig NNN (1590-a)
$r$, 'registrar_nota_credito_lote (el ajuste vigente)');

  v_def := pg_temp.parche(v_def,
$a$                                WHERE nc.compra_id = c.id AND nc.sucursal_id = c.sucursal_id), 0)
$a$,
$r$                                WHERE nc.compra_id = c.id AND nc.sucursal_id = c.sucursal_id
                                  AND NOT nc.anulada), 0)  -- mig NNN (1590-a)
$r$, 'registrar_nota_credito_lote (lo que le queda, sin las anuladas)');

  v_def := pg_temp.parche(v_def,
$a$  RETURNING id INTO v_nota_id;
$a$,
$r$  RETURNING id INTO v_nota_id;

  -- mig NNN (1590-a, #1590): el lote que toma, para que anular la nota se lo devuelva.
  UPDATE public.notas_credito
     SET lotes_tomados = jsonb_build_array(jsonb_build_object(
           'producto_id', v_lote.producto_id, 'lote_id', p_lote_id, 'cantidad', v_cant))
   WHERE id = v_nota_id;
$r$, 'registrar_nota_credito_lote (el lote que toma)');

  v_def := pg_temp.parche(v_def,
$a$  v_aviso := public._cpp_devolucion_compra(v_lote.compra_id, v_lote.producto_id, v_sucursal,
                                           v_acreditado, v_cant);
$a$,
$r$  v_aviso := public._cpp_devolucion_compra(v_lote.compra_id, v_lote.producto_id, v_sucursal,
                                           v_acreditado, v_cant);

  -- 4) mig NNN (1557-b5, #1557; D10): devuelta entera, la reposición vuelve a la anterior.
  IF public._compra_producto_devuelto(v_lote.compra_id, v_lote.producto_id, v_sucursal) THEN
    v_aviso_rep := public._reposicion_tras_nota(v_lote.compra_id, v_lote.producto_id, v_sucursal);
  END IF;
$r$, 'registrar_nota_credito_lote (1557-b5)');

  v_def := pg_temp.parche(v_def,
$a$    'warnings',          CASE WHEN v_aviso IS NOT NULL THEN jsonb_build_array(jsonb_build_object(
                           'producto_id', v_lote.producto_id, 'motivo', v_aviso,
                           'warning', 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo')) END,
$a$,
$r$    'warnings',          CASE WHEN v_aviso IS NOT NULL OR v_aviso_rep IS NOT NULL THEN
                           COALESCE(CASE WHEN v_aviso IS NOT NULL THEN jsonb_build_array(jsonb_build_object(
                             'producto_id', v_lote.producto_id, 'motivo', v_aviso,
                             'warning', 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo')) END,
                             '[]'::jsonb)
                           || COALESCE(CASE WHEN v_aviso_rep IS NOT NULL THEN jsonb_build_array(jsonb_build_object(
                             'producto_id', v_lote.producto_id, 'warning', v_aviso_rep)) END, '[]'::jsonb) END,
$r$, 'registrar_nota_credito_lote (los avisos)');
  EXECUTE v_def;
END
$parche_nc_lote$;

-- =========================================================================
-- El envío: STK-16, 1557-b7 y 1558-b8
-- =========================================================================
DO $parche_envio$
DECLARE
  v_def text := pg_get_functiondef('public.aceptar_movimiento_sucursal(bigint,jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_foto jsonb; v_venc record; v_lote_dest bigint; v_por_etiquetar integer; v_toma integer;
$a$,
$r$  v_foto jsonb; v_venc record; v_lote_dest bigint; v_por_etiquetar integer; v_toma integer;
  v_reactivados bigint[] := '{}';  -- mig NNN (1558-b8)
$r$, 'aceptar_movimiento_sucursal (declaración)');

  v_def := pg_temp.parche(v_def,
$a$      IF NOT FOUND THEN RAISE EXCEPTION 'El producto destino elegido no existe en la sucursal'; END IF;
$a$,
$r$      IF NOT FOUND THEN RAISE EXCEPTION 'El producto destino elegido no existe en la sucursal'; END IF;
      -- mig NNN (1558-b8, #1558; decisión del dueño D7): un destino desactivado se acepta y se
      -- reactiva (el UPDATE de abajo): es normal que la otra sucursal lo tenga desactivado.
      IF (SELECT NOT p.activo FROM productos p WHERE p.id = v_dest_id AND p.sucursal_id = v_destino) THEN
        v_reactivados := v_reactivados || v_dest_id;
      END IF;
$r$, 'aceptar_movimiento_sucursal (1558-b8, el desactivado)');

  v_def := pg_temp.parche(v_def,
$a$        costo_promedio = v_promedio_nuevo, costo_real = v_real_nuevo, updated_at = now()
      WHERE id = v_dest_id AND sucursal_id = v_destino;
$a$,
$r$        costo_promedio = v_promedio_nuevo, costo_real = v_real_nuevo,
        activo = true,  -- mig NNN (1558-b8)
        updated_at = now()
      WHERE id = v_dest_id AND sucursal_id = v_destino;
$r$, 'aceptar_movimiento_sucursal (1558-b8, reactivar)');

  v_def := pg_temp.parche(v_def,
$a$      stock_destino_anterior = v_stock_d, stock_destino_nuevo = v_stock_d + v_item.cantidad
    WHERE id = v_item.id;
$a$,
$r$      stock_destino_anterior = v_stock_d, stock_destino_nuevo = v_stock_d + v_item.cantidad,
      -- mig NNN (STK-16, #1542): la foto del promedio con que se mezcló, siempre. Sin ella
      -- se mezclaba con el vivo del origen y _cpp_arrastrar descartaba el envío.
      origen_costo_promedio = COALESCE(origen_costo_promedio, CASE WHEN v_po > 0 THEN v_po END),
      -- mig NNN (1557-b7, #1557): el costo real del origen que entró en el GREATEST, para
      -- que corregir la última compra del destino no lo pise (_reposicion_aplicar_envios).
      origen_costo_real = v_orig_costo_real
    WHERE id = v_item.id;
$r$, 'aceptar_movimiento_sucursal (STK-16 y 1557-b7, las fotos)');

  v_def := pg_temp.parche(v_def,
$a$  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
$a$,
$r$  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id,
                            'reactivados', to_jsonb(v_reactivados));  -- mig NNN (1558-b8)
$r$, 'aceptar_movimiento_sucursal (lo que devuelve)');
  EXECUTE v_def;
END
$parche_envio$;

-- =========================================================================
-- STK-14 · sincronizar_lotes_compra con las reglas de la edición
-- =========================================================================
DO $parche_lotes$
DECLARE
  v_def text := pg_get_functiondef('public.sincronizar_lotes_compra(bigint,jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_comprado  integer;
$a$,
$r$  v_comprado  integer;
  v_creada    timestamptz;  -- mig NNN (STK-14)
$r$, 'sincronizar_lotes_compra (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;
$a$,
$r$  -- mig NNN (STK-14, #1542): el helper mira activo (#1474).
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;
$r$, 'sincronizar_lotes_compra (el rol)');

  v_def := pg_temp.parche(v_def,
$a$  SELECT estado INTO v_estado
    FROM public.compras
$a$,
$r$  SELECT estado, created_at INTO v_estado, v_creada
    FROM public.compras
$r$, 'sincronizar_lotes_compra (la compra)');

  v_def := pg_temp.parche(v_def,
$a$    RAISE EXCEPTION 'La compra % esta cancelada: no se le pueden cargar vencimientos', p_compra_id;
  END IF;
$a$,
$r$    RAISE EXCEPTION 'La compra % esta cancelada: no se le pueden cargar vencimientos', p_compra_id;
  END IF;

  /* mig NNN (STK-14, #1542) · LAS REGLAS DE EDITAR LA COMPRA. Por llamada directa
     se le cambiaban los vencimientos a una compra con notas de credito (que ya
     bajaron sus lotes), fuera de los 7 dias de la edicion y de un encargado. */
  IF EXISTS (SELECT 1 FROM public.notas_credito nc
              WHERE nc.compra_id = p_compra_id AND nc.sucursal_id = v_sucursal AND NOT nc.anulada) THEN
    RAISE EXCEPTION 'La compra % tiene notas de crédito: sus vencimientos ya no se cambian desde la compra. Un lote se corrige desde la ficha del producto.', p_compra_id;
  END IF;
  IF EXTRACT(EPOCH FROM (now() - v_creada)) / 86400 > 7 THEN
    RAISE EXCEPTION 'La compra % se cargó hace más de 7 días: sus vencimientos ya no se cambian desde la compra. Un lote se corrige desde la ficha del producto.', p_compra_id;
  END IF;
  IF NOT public.es_admin()
     AND EXISTS (SELECT 1 FROM public.producto_lotes l
                  WHERE l.compra_id = p_compra_id AND l.sucursal_id = v_sucursal) THEN
    RAISE EXCEPTION 'La compra % ya tiene vencimientos: cambiarlos es editar la compra, y eso lo hace un admin.', p_compra_id;
  END IF;
$r$, 'sincronizar_lotes_compra (STK-14)');
  EXECUTE v_def;
END
$parche_lotes$;

-- =========================================================================
-- 1590-a · anular_nota_credito_compra
-- =========================================================================
CREATE FUNCTION public.anular_nota_credito_compra(p_nota_id bigint, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal  bigint := public.current_sucursal_id();
  v_motivo    text   := NULLIF(btrim(COALESCE(p_motivo, '')), '');
  v_compra_id bigint;
  v_nota      record;
  r           record;
  v_antes     integer;
  v_comprado  integer;
  v_aviso     text;
  v_avisos    jsonb := '[]'::jsonb;
  v_a_lotes   integer := 0;
  v_lotes     jsonb;
BEGIN
  -- mig NNN (1590-a, #1590; decisión del dueño D15). La nota no se borra (es un comprobante
  -- del proveedor): queda anulada, con quién, cuándo y por qué, y lo que suma las notas de una
  -- compra la deja afuera. Una devolución anulada deshace lo que hizo: el stock, los lotes
  -- que tomó, el promedio y, si había devuelto entero un producto, la reposición.
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF NOT public.es_encargado_o_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para anular notas de crédito');
  END IF;
  IF v_motivo IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Anular una nota de crédito necesita un motivo');
  END IF;

  SELECT nc.compra_id INTO v_compra_id
    FROM notas_credito nc WHERE nc.id = p_nota_id AND nc.sucursal_id = v_sucursal;
  IF v_compra_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'La nota de crédito no existe en esta sucursal');
  END IF;

  -- El orden de las dos puertas que registran notas (#1095, #1471): la compra FOR SHARE,
  -- los productos por id, las líneas de la compra (serializa contra otra nota), la nota y
  -- los lotes por id.
  PERFORM 1 FROM compras
   WHERE id = v_compra_id AND sucursal_id = v_sucursal AND estado <> 'cancelada'
     FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'La compra de esta nota está cancelada: la nota no se anula');
  END IF;

  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT nci.producto_id FROM nota_credito_items nci WHERE nci.nota_credito_id = p_nota_id)
   ORDER BY id
     FOR UPDATE;

  PERFORM 1 FROM compra_items
   WHERE compra_id = v_compra_id AND sucursal_id = v_sucursal
   ORDER BY id
     FOR UPDATE;

  SELECT * INTO v_nota FROM notas_credito WHERE id = p_nota_id AND sucursal_id = v_sucursal FOR UPDATE;
  IF v_nota.anulada THEN
    RETURN jsonb_build_object('success', false, 'error', 'La nota de crédito ya está anulada');
  END IF;

  UPDATE notas_credito
     SET anulada = true, anulada_at = now(), anulada_por = auth.uid(), motivo_anulacion = v_motivo
   WHERE id = p_nota_id;

  IF v_nota.tipo = 'devolucion' THEN
    v_lotes := CASE WHEN jsonb_typeof(v_nota.lotes_tomados) = 'array' THEN v_nota.lotes_tomados ELSE '[]'::jsonb END;

    -- El stock vuelve a la bolsa ('nota_credito_anulada' no está en la lista blanca del
    -- trigger de lotes) y después cada lote recibe lo que la nota le sacó, con tope en su
    -- hueco (_mov_lotes_devolver, el patrón de STK-1). Una nota de antes de esta migración
    -- no anotó sus lotes: lo suyo queda en la bolsa.
    PERFORM set_config('app.stock_origen',   'nota_credito_anulada', true);
    PERFORM set_config('app.stock_ref_tipo', 'notas_credito',        true);
    PERFORM set_config('app.stock_ref_id',   p_nota_id::text,        true);
    PERFORM set_config('app.stock_user_id',  auth.uid()::text,       true);

    PERFORM 1 FROM producto_lotes
     WHERE sucursal_id = v_sucursal
       AND id IN (SELECT (e->>'lote_id')::bigint FROM jsonb_array_elements(v_lotes) e)
     ORDER BY id
       FOR UPDATE;

    FOR r IN
      SELECT nci.producto_id, SUM(nci.cantidad)::integer AS cantidad
        FROM nota_credito_items nci
       WHERE nci.nota_credito_id = p_nota_id AND nci.sucursal_id = v_sucursal
       GROUP BY nci.producto_id
       ORDER BY nci.producto_id
    LOOP
      -- Lo que devolvían las notas vigentes de la compra contando ésta (ya está marcada).
      SELECT COALESCE(SUM(nci.cantidad), 0)::integer + r.cantidad INTO v_antes
        FROM nota_credito_items nci
        JOIN notas_credito nc ON nc.id = nci.nota_credito_id AND nc.sucursal_id = nci.sucursal_id
       WHERE nc.compra_id = v_compra_id AND nc.sucursal_id = v_sucursal AND NOT nc.anulada
         AND nci.producto_id = r.producto_id;
      SELECT COALESCE(SUM(ci.cantidad), 0)::integer INTO v_comprado
        FROM compra_items ci
       WHERE ci.compra_id = v_compra_id AND ci.sucursal_id = v_sucursal AND ci.producto_id = r.producto_id;

      UPDATE productos SET stock = stock + r.cantidad, updated_at = now()
       WHERE id = r.producto_id AND sucursal_id = v_sucursal;

      v_a_lotes := v_a_lotes + public._mov_lotes_devolver(v_sucursal,
        (SELECT jsonb_agg(e) FROM jsonb_array_elements(v_lotes) e
          WHERE (e->>'producto_id')::bigint = r.producto_id));

      -- El promedio, la cuenta de la nota al revés.
      v_aviso := public._cpp_devolucion_compra(v_compra_id, r.producto_id, v_sucursal, v_antes, -r.cantidad);
      IF v_aviso IS NOT NULL THEN
        v_avisos := v_avisos || jsonb_build_object(
          'producto_id', r.producto_id, 'motivo', v_aviso,
          'warning', 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo');
      END IF;

      -- 1557-b5: la nota había devuelto entero el producto; ahora la compra vuelve a contar.
      IF v_comprado > 0 AND v_antes >= v_comprado THEN
        v_aviso := public._reposicion_tras_nota(v_compra_id, r.producto_id, v_sucursal);
        IF v_aviso IS NOT NULL THEN
          v_avisos := v_avisos || jsonb_build_object('producto_id', r.producto_id, 'warning', v_aviso);
        END IF;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'nota_credito_id', p_nota_id,
    'compra_id', v_compra_id,
    'tipo', v_nota.tipo,
    'total', v_nota.total,
    'unidades_a_sus_lotes', v_a_lotes,
    'warnings', CASE WHEN jsonb_array_length(v_avisos) > 0 THEN v_avisos END);
END;
$function$;

-- =========================================================================
-- Permisos: los helpers son de server; la RPC, de quien carga notas
-- =========================================================================
REVOKE ALL ON FUNCTION public._compra_producto_devuelto(bigint,bigint,bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._compra_factor_neto(bigint,bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._reposicion_aplicar_envios(bigint,bigint,timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._reposicion_tras_nota(bigint,bigint,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._compra_producto_devuelto(bigint,bigint,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public._compra_factor_neto(bigint,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public._reposicion_aplicar_envios(bigint,bigint,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public._reposicion_tras_nota(bigint,bigint,bigint) TO service_role;

REVOKE ALL ON FUNCTION public.anular_nota_credito_compra(bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.anular_nota_credito_compra(bigint,text) TO authenticated, service_role;

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
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     'e5e0067ec95ded33096aad70f3cb68c0', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     'bbdd25695b8dfaa61a7db431011c2384', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
     '3412d73ba51d8efb2a24cc6c636b1dc7', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_nota_credito_lote(bigint,numeric,text,text)',
     '0cfa702be5aaa43679a6795a3a5b1192', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.aceptar_movimiento_sucursal(bigint,jsonb)',
     'f7af3352dfebd372b53c38c0e88a6d3a', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.sincronizar_lotes_compra(bigint,jsonb)',
     'f25fc7665fecc43f3f272b46b08eb78c', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)',
     '3cbb27fa967fad761c660aab300b3c2d', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._cpp_devolucion_compra(bigint,bigint,bigint,integer,integer)',
     'bff2ccc6d4db410d49f7217488619178', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._reposicion_desde_ultima_compra(bigint,bigint)',
     'c1769eccef2cac3adb701f2f104cf580', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._ninguna_compra_mas_nueva(bigint,bigint,bigint)',
     '36962a469c877fad8b4965885714e684', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._compra_producto_devuelto(bigint,bigint,bigint)',
     '293e276020f1a426a088ca1912609c93', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._compra_factor_neto(bigint,bigint)',
     'ac1265b1a46f6f8c3a32056e2f95d48d', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._reposicion_aplicar_envios(bigint,bigint,timestamp with time zone)',
     'f36399f3c2a6c52e9a2a5e0732f8dcd3', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._reposicion_tras_nota(bigint,bigint,bigint)',
     '7f4108145b650be746bc12366cd230c0', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.anular_nota_credito_compra(bigint,text)',
     '9adaaaff3478ea10d459d8f09397ec47', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
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
