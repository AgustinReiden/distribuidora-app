-- =========================================================================
-- NNN · REPORTES QUE CIERRAN ENTRE SÍ: LA VENTA NETA DE NOTAS DE CRÉDITO, LO
--       SIN COSTO FUERA DEL MARGEN, UN SOLO RÓTULO PARA LO SIN RUBRO Y LAS
--       COMPRAS NETAS DE SUS NOTAS
--       (plan #1603, ola 2, tarjeta B8b: REP-D y 1545-b3 de #1545, 1557-b3 de
--        #1557, 1562-b6, 1562-b7 y 1562-b9 de #1562, 1597-b1 y 1597-b2 de #1597)
--
-- Parcha por ancla, con premisa de md5 sobre el cuerpo vivo del 16/11 (ledger
-- en la 512), reporte_gerencial, reporte_ventas_por_cliente,
-- reporte_ventas_por_preventista, reporte_rentabilidad, rendimiento_preventistas,
-- reporte_stock_red, reporte_valuacion_inventario, reporte_alerta_detalle y
-- bot_compras_periodo; y, si
-- siguen existiendo (SEG-3 de #1545 decide borrar las que nadie llama; la
-- coordinadora elige el orden), seis tablero_*, _tablero_cat_nombre y
-- obtener_resumen_compras. Crea dos funciones de server: _ventas_nc y
-- _rubro_rotulo. No cambia tablas, firmas ni claves de los JSON: sólo suma
-- claves nuevas. Ensayo: scripts/test-reportes-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · REP-D · LA VENTA DE LOS RANKINGS ES NETA DE NOTAS DE CRÉDITO
-- =========================================================================
-- Decisión del dueño (D44, 15/11, en #1545): la venta de los rankings
-- (gerencial, vendedor, cliente, zona, categoría) pasa a ser neta de las notas
-- de crédito de venta. La deuda, la posición fiscal y la contribución del
-- gerencial ya las restaban.
--   · Una regla, `_ventas_nc(sucursales, desde, hasta)`: una fila por renglón
--     de nota vigente (no anulada) cuya boleta es venta (entregada, no canje,
--     no vale blanco), con la fecha de la NOTA, el cliente de la nota, la zona
--     de ese cliente, el vendedor de la boleta, el producto y lo que acredita
--     (el monto, su IVA y su ingreso real, que es el del renglón de la boleta).
--     Por la fecha de la nota, como `posicion_fiscal` y como
--     `kpis.notas_credito_venta`: un mes cerrado no cambia por una nota de
--     después.
--   · La nota resta plata: no suma ni resta pedidos, clientes compradores ni
--     unidades, y no toca el CMV (el renglón entra con cantidad 0). Un cliente
--     o un vendedor que en el período sólo tiene una nota aparece con su venta
--     en negativo y 0 pedidos.
--   · reporte_gerencial: `kpis.venta` y todo lo que cuelga de ella (venta neta,
--     IVA débito, venta real, FC/ZZ, márgenes, mensual, serie diaria,
--     vendedores, rubros, top de productos y de clientes). `kpis.venta_bruta`
--     (nueva) es la de antes y `kpis.notas_credito_venta` sigue siendo el monto
--     de las notas, así que venta_bruta − notas_credito_venta = venta. El front
--     deja de restar las notas en la contribución cuando llega venta_bruta.
--     La base de comisión, el ticket (promedio por boleta) y la cobranza no
--     cambian.
--   · reporte_ventas_por_cliente (y bot_ranking_clientes, que lo lee): el
--     total, cada cliente, cada zona y cada vendedor. `totales.clientes` y
--     `zonas[].clientes` cuentan a los que compraron (con pedidos en el
--     período): un cliente que sólo tiene una nota sale en la lista, no suma.
--   · reporte_ventas_por_preventista (y bot_ventas_por_preventista, que lo
--     lee): totalVentas.
--   · tablero_categorias, tablero_facturacion_mensual, tablero_top_clientes_zona,
--     tablero_cobertura y tablero_kpis: el monto (los cruza check-integridad.mjs
--     contra el gerencial).
--   · Quedan por boleta, sin decisión que los mueva: la comisión
--     (`_comision_lineas`, la base del gerencial), las metas
--     (`avance_metas_preventista` y `rendimiento_preventistas`), las jornadas,
--     el bot fuera de los dos rankings que heredan (bot_ventas_periodo,
--     bot_mis_ventas…) y reporte_rentabilidad.
--
-- =========================================================================
-- 2 · 1562-b6 · UNA LÍNEA SIN COSTO SE EXCLUYE DEL MARGEN
-- =========================================================================
-- Decisión del dueño (D42, en #1562): una línea sin costo (la cascada de
-- `costo_valuacion` no encontró nada) se excluye del margen y se muestra aparte
-- como «sin costo», igual en todos los reportes. rendimiento_preventistas ya
-- lo hacía (400); el gerencial y Rentabilidad la contaban como margen entero
-- (450).
--   · reporte_gerencial: los márgenes de kpis, mensual, vendedores, rubros y
--     top de productos restan el ingreso sin costo. `kpis.ingreso_real_sin_costo`,
--     `vendedores[].venta_sin_costo` y `categorias[].venta_sin_costo` son nuevas;
--     `kpis.ingreso_sin_costo` y `flags` siguen; `mensual[].ingreso_sin_costo` es
--     nueva (para el % de cada mes). La alerta ya no dice «margen sobreestimado»,
--     y su lista (reporte_alerta_detalle) resta las mismas notas, así que sigue
--     sumando el KPI. El front divide los % de margen por la venta con costo.
--   · reporte_rentabilidad: margen y % por producto (y dentro y fuera de combo)
--     y los totales, sobre el ingreso con costo.
--
-- =========================================================================
-- 3 · 1562-b7 · «SIN RUBRO», EL MISMO RÓTULO EN TODOS LOS REPORTES
-- =========================================================================
-- Decisión del dueño (D43, en #1562): los productos sin rubro llevan el rótulo
-- «Sin rubro» en todos los reportes. El tablero agrupaba por el rubro de la
-- tabla, en mayúsculas ("SIN CATEGORIA"); el gerencial, Rendimiento, Stock y
-- Valuación, por el texto del producto ("(sin categoría)"). Ahora todos dan
-- `_rubro_rotulo(COALESCE(rubro de categoria_id, productos.categoria))`: el
-- nombre del rubro tal como está en la tabla, el texto si no matchea ninguno, y
-- «Sin rubro» si no hay ninguno. La línea de un producto borrado sigue como
-- '(producto borrado)' (en el tablero también).
--
-- =========================================================================
-- 4 · 1557-b3 · «COMPRAS DEL PERÍODO» NETAS DE SUS NOTAS DE CRÉDITO
-- =========================================================================
-- Decisión del dueño (D9, en #1557): «Compras del período» se informa neto de
-- las notas de crédito de compra, con las notas como línea aparte. Las notas
-- (devolución y ajuste) de compras no canceladas, por la fecha de la nota, a su
-- total. En el gerencial `kpis.compras` y `mensual[].compras` quedan netas y
-- `compras_notas_credito` (nueva) es la línea aparte; `compras_facturas` sigue
-- siendo lo facturado. En el bot, `total_compras` y `compras_notas_credito`.
-- obtener_resumen_compras devuelve una TABLE: sumarle la columna obliga a
-- borrarla y crearla, y SEG-3 la borra; se netea `monto_total` y nada más.
--
-- =========================================================================
-- 5 · LOS BAJOS
-- =========================================================================
-- 1562-b9: reporte_gerencial sin fechas, o con desde después de hasta, daba
--   todo en cero. Ahora rechaza (22023) con el motivo, como
--   reporte_ventas_por_cliente. Rentabilidad y Ventas por preventista aceptan
--   las fechas vacías a propósito (sin filtro: el front las pide así); sólo
--   rechazan desde después de hasta.
-- 1597-b1: totalPagado de reporte_ventas_por_preventista sumaba el crédito de
--   una nota y el adelanto de sueldo, que no son plata. Ahora es lo pagado
--   menos lo no dinerario (las formas no dinerarias de `formas_pago()`, #1249).
-- 1597-b2: tablero_ficha_cliente decía «Cliente N inexistente» antes de mirar
--   el rol, y «la sucursal N no está asignada» con un cliente ajeno. Ahora mira
--   el rol primero, y lo inexistente y lo ajeno dan lo mismo.
-- 1545-b3: tablero_kpis suma `clientes_sin_compra_30`, el complemento de
--   `clientes_activos_30`; las dos claves que se superponen quedan.
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
-- Premisas: los cuerpos vivos del 16/11 (ledger en la 512). Las que SEG-3 puede
-- haber borrado son opcionales: si no están, se saltean; si están, tienen que
-- ser las de hoy.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 'a324634a3aafa53d8c45ab56b4b2c3f0', true),
    ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)', '8d4004f14c0d8581155bdac50c549371', true),
    ('public.reporte_ventas_por_preventista(date,date,bigint)', 'e9ddf433548c2fe329831d928c134592', true),
    ('public.reporte_rentabilidad(date,date,bigint,text)', '45de214d8f0bab256740889d317fcf57', true),
    ('public.rendimiento_preventistas(bigint,date)', 'de5da1d80c069e09e5d0b1cbccb36707', true),
    ('public.reporte_stock_red(bigint)', '02e17a7211a997305507e19124223a4d', true),
    ('public.reporte_valuacion_inventario(bigint)', '28bbac6328de55fe14d30cfb503d7fe9', true),
    ('public.bot_compras_periodo(date,date,bigint,integer)', '0dfd5cce59b338cefdad132eaa33638c', true),
    -- Las que leen las dos lecturas de abajo: no cambian, pero cuentan con ellas.
    ('public.bot_ventas_por_preventista(date,date,bigint,boolean,integer)', NULL, true),
    ('public.costo_valuacion(numeric,numeric,numeric,numeric,numeric)', NULL, true),
    ('public.formas_pago()', NULL, true),
    ('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', '1098d1b1d04c5185a8de76c78f1332fe', true),
    -- Opcionales (SEG-3)
    ('public.tablero_categorias(bigint,date,date,bigint)', 'f3f9e7d10e4219f51fa645931bbefda0', false),
    ('public.tablero_facturacion_mensual(bigint,integer)', '033d36e18ae7aac07ad4d8c7f4ed489d', false),
    ('public.tablero_top_clientes_zona(bigint,date,date,integer,integer)', 'b862b2b82e158acebc59009b4b374fc5', false),
    ('public.tablero_cobertura(bigint,date)', 'b5e9c1a5bf664404035ba1b2f4ba4076', false),
    ('public.tablero_kpis(bigint,integer)', '057bff6b8b17dce1e02ab4c89e494704', false),
    ('public.tablero_productos_categoria(uuid,text,bigint,date,date,bigint)', '7d41f68f5489d97b1886bc93ff5474ab', false),
    ('public.tablero_ficha_cliente(bigint)', 'bbcba23471cb9ed4c0acdd30712c72ae', false),
    ('public._tablero_cat_nombre(text)', 'b2f257af048c834b5d8ec1fc4625854b', false),
    ('public.obtener_resumen_compras(date,date)', 'a463a61a815224670752d831d4696f17', false)
  ) AS t(f, h, obligatoria) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      IF r.obligatoria THEN
        RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
      END IF;
      RAISE NOTICE 'mig NNN · % no existe (SEG-3): se saltea', r.f;
      CONTINUE;
    END IF;
    IF r.h IS NULL THEN CONTINUE; END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regproc('public._ventas_nc') IS NOT NULL OR to_regproc('public._rubro_rotulo') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · _ventas_nc o _rubro_rotulo ya existen: revisar a mano';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.notas_credito_venta'::regclass
                    AND attname = 'neto' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · falta notas_credito_venta.neto (#1257)';
  END IF;
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

-- El tramo de una definición que va desde `p_desde` (incluido) hasta `p_hasta`
-- (excluido). Las dos marcas aparecen una sola vez, en ese orden.
CREATE FUNCTION pg_temp.tramo(p_def text, p_desde text, p_hasta text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_i int := position(p_desde in p_def);
  v_j int := position(p_hasta in p_def);
BEGIN
  IF (length(p_def) - length(replace(p_def, p_desde, ''))) / length(p_desde) <> 1
     OR (length(p_def) - length(replace(p_def, p_hasta, ''))) / length(p_hasta) <> 1
     OR v_j <= v_i THEN
    RAISE EXCEPTION 'mig NNN · %: las marcas del tramo no aparecen una vez cada una y en orden', p_que;
  END IF;
  RETURN substr(p_def, v_i, v_j - v_i);
END
$f$;

-- =========================================================================
-- Las dos reglas nuevas
-- =========================================================================

-- 1562-b7 (D43): el rótulo del rubro de un producto, uno solo para todos los
-- reportes. Recibe COALESCE(nombre del rubro de categoria_id, productos.categoria).
-- Sin `SET search_path` a propósito: así Postgres la inlinea en la consulta que la
-- llama (con SET la llamaba una vez por línea: el gerencial anual subía un 30 % y
-- tablero_categorias ×3,3). No nombra objetos de ningún esquema salvo pg_catalog.
CREATE FUNCTION public._rubro_rotulo(p_nombre text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT COALESCE(NULLIF(pg_catalog.btrim(p_nombre), ''::text), 'Sin rubro'::text)
$function$;

REVOKE ALL ON FUNCTION public._rubro_rotulo(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._rubro_rotulo(text) TO service_role;

-- REP-D (D44): lo que las notas de crédito de venta le restan a la venta de los
-- rankings. Una fila por renglón de nota vigente cuya boleta es venta (la
-- definición de «venta por vendedor»: entregada, no canje, no vale blanco), en
-- las sucursales y entre las fechas DE LA NOTA. Atribuida al cliente de la nota,
-- a la zona de hoy de ese cliente (como `_tablero_ventas`) y al vendedor de la
-- boleta. `iva` es la parte del IVA de la nota (su foto, #1257); `ingreso_real`
-- es el del renglón de la boleta (FC: el neto; ZZ: el final), o la parte del
-- neto o del total de la nota si el renglón ya no está. `costo_al_crear` es el
-- de ese renglón: con él el reporte sabe si la línea acreditada era «sin costo».
-- De server: la llaman sólo los reportes (SECURITY DEFINER).
CREATE FUNCTION public._ventas_nc(p_sucs bigint[], p_desde date, p_hasta date)
RETURNS TABLE(nota_credito_id bigint, fecha date, sucursal_id bigint, pedido_id bigint,
              cliente_id bigint, zona_id bigint, usuario_id uuid, tipo_factura text,
              pedido_item_id bigint, producto_id bigint, cantidad integer,
              monto numeric, iva numeric, ingreso_real numeric, costo_al_crear numeric)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT n.id, n.fecha, n.sucursal_id, n.pedido_id, n.cliente_id, c.zona_id, pe.usuario_id,
         COALESCE(pe.tipo_factura, 'ZZ')::text, i.pedido_item_id, i.producto_id, i.cantidad,
         i.subtotal,
         i.subtotal * n.iva / n.total,
         CASE WHEN pi.id IS NOT NULL
              THEN i.cantidad * COALESCE(pi.ingreso_real_unitario,
                                         CASE WHEN pe.tipo_factura = 'FC'
                                              THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                              ELSE pi.precio_unitario END)
              ELSE i.subtotal * CASE WHEN pe.tipo_factura = 'FC' THEN n.neto ELSE n.total END / n.total
         END,
         pi.costo_unitario_al_crear
    FROM notas_credito_venta n
    JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
    JOIN pedidos pe ON pe.id = n.pedido_id
    LEFT JOIN pedido_items pi ON pi.id = i.pedido_item_id
    LEFT JOIN clientes c ON c.id = n.cliente_id
   WHERE NOT n.anulada
     AND n.total > 0
     AND n.sucursal_id = ANY(p_sucs)
     AND n.fecha BETWEEN p_desde AND p_hasta
     AND pe.estado = 'entregado'
     AND COALESCE(pe.canal, 'app') <> 'cambio'
     AND pe.tipo_factura IS DISTINCT FROM 'VB'
$function$;

REVOKE ALL ON FUNCTION public._ventas_nc(bigint[], date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._ventas_nc(bigint[], date, date) TO service_role;

-- =========================================================================
-- reporte_gerencial · REP-D, 1562-b6, 1562-b7, 1557-b3, 1562-b9
-- =========================================================================
DO $ger$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
BEGIN
  -- 1562-b9: las fechas, antes que nada.
  v_def := pg_temp.parche(v_def,
$a$BEGIN
  IF NOT v_es_servicio THEN
    IF NOT public.es_admin() THEN$a$,
$n$BEGIN
  -- 1562-b9 (#1562): sin fechas, o con desde después de hasta, el reporte daba
  -- todo en cero sin decir por qué.
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Se requieren las fechas desde y hasta' USING ERRCODE = '22023';
  END IF;
  IF p_desde > p_hasta THEN
    RAISE EXCEPTION 'La fecha desde (%) es posterior a la fecha hasta (%)', p_desde, p_hasta
      USING ERRCODE = '22023';
  END IF;
  IF NOT v_es_servicio THEN
    IF NOT public.es_admin() THEN$n$, 'gerencial · fechas');

  -- REP-D: las notas del período, por renglón (ncl) y por nota (nca).
  v_def := pg_temp.parche(v_def,
$a$  it AS (
    SELECT p.id AS pedido_id, p.usuario_id, p.fecha,$a$,
$n$  -- REP-D (#1545, D44): la venta es neta de las notas de crédito de venta, por
  -- la fecha de la nota (_ventas_nc). `ncl` es un renglón por línea acreditada;
  -- `nca`, una fila por nota.
  ncl AS (SELECT * FROM public._ventas_nc(v_sucursales, p_desde, p_hasta)),
  nca AS (SELECT nota_credito_id, fecha, cliente_id, tipo_factura,
                 SUM(monto) AS total, ROUND(SUM(iva), 2) AS iva, SUM(ingreso_real) AS real
            FROM ncl GROUP BY nota_credito_id, fecha, cliente_id, tipo_factura),
  it AS (
    SELECT p.id AS pedido_id, p.usuario_id, p.fecha,$n$, 'gerencial · ncl');

  -- 1562-b7: el rubro.
  v_def := pg_temp.parche(v_def,
$a$           CASE WHEN prod.id IS NULL THEN '(producto borrado)'
                ELSE COALESCE(NULLIF(prod.categoria,''),'(sin categoría)') END AS categoria,$a$,
$n$           -- 1562-b7 (#1562, D43): el rubro de la tabla, o el texto, o «Sin rubro»:
           -- el mismo rótulo que el tablero y que los demás reportes.
           CASE WHEN prod.id IS NULL THEN '(producto borrado)'
                ELSE public._rubro_rotulo(COALESCE(cat.nombre, prod.categoria)) END AS categoria,$n$,
    'gerencial · rubro');

  -- REP-D: los renglones de las notas, en negativo, al final de `it`.
  v_def := pg_temp.parche(v_def,
$a$    LEFT JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id
  ),
  nc AS ($a$,
$n$    LEFT JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN categorias cat ON cat.id = prod.categoria_id  -- 1562-b7: el rubro
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id
    UNION ALL
    -- REP-D: el renglón de una nota resta su monto (y su ingreso real) de la venta
    -- del vendedor de la boleta, del rubro y del producto, por la fecha de la nota.
    -- Sin pedido (no suma pedidos) y con cantidad 0 (no toca unidades ni CMV). Es
    -- «sin costo» si la línea que acredita lo era (1562-b6).
    SELECT NULL::bigint, n.usuario_id, n.fecha,
           0, -n.monto, false,
           public.costo_valuacion(n.costo_al_crear, prod.costo_promedio, prod.costo_real,
                                  prod.costo_sin_iva, prod.impuestos_internos),
           -n.ingreso_real,
           COALESCE(prod.nombre, '(producto borrado)'),
           prod.id, prod.sucursal_id,
           CASE WHEN prod.id IS NULL THEN '(producto borrado)'
                ELSE public._rubro_rotulo(COALESCE(cat.nombre, prod.categoria)) END,
           (public.costo_valuacion(n.costo_al_crear, prod.costo_promedio, prod.costo_real,
                                   prod.costo_sin_iva, prod.impuestos_internos) IS NULL),
           NULL, false, 1, 0, 0
      FROM ncl n
      LEFT JOIN productos prod ON prod.id = n.producto_id
      LEFT JOIN categorias cat ON cat.id = prod.categoria_id
  ),
  nc AS ($n$, 'gerencial · it con notas');

  -- REP-D: los kpis de venta.
  v_def := pg_temp.parche(v_def,
$a$COALESCE(SUM(venta_prod),0) AS venta, -- cargo_4$a$,
$n$COALESCE(SUM(venta_prod),0) - (SELECT COALESCE(SUM(total),0) FROM nca) AS venta, -- cargo_4; REP-D: neta de NC
            COALESCE(SUM(venta_prod),0) AS venta_bruta,$n$, 'gerencial · venta');
  v_def := pg_temp.parche(v_def,
$a$COALESCE(SUM(venta_prod - total_iva),0) AS venta_neta,$a$,
$n$COALESCE(SUM(venta_prod - total_iva),0) - (SELECT COALESCE(SUM(total - iva),0) FROM nca) AS venta_neta,$n$,
    'gerencial · venta_neta');
  v_def := pg_temp.parche(v_def,
$a$COALESCE(SUM(total_iva),0) AS iva_debito,$a$,
$n$COALESCE(SUM(total_iva),0) - (SELECT COALESCE(SUM(iva),0) FROM nca) AS iva_debito,$n$, 'gerencial · iva_debito');
  v_def := pg_temp.parche(v_def,
$a$COALESCE(SUM(total_real),0) AS venta_real,$a$,
$n$COALESCE(SUM(total_real),0) - (SELECT COALESCE(SUM(real),0) FROM nca) AS venta_real,$n$, 'gerencial · venta_real');
  v_def := pg_temp.parche(v_def,
$a$COALESCE(SUM(venta_prod) FILTER (WHERE tipo_factura='FC'),0) AS fc_venta,$a$,
$n$COALESCE(SUM(venta_prod) FILTER (WHERE tipo_factura='FC'),0)
              - (SELECT COALESCE(SUM(total),0) FROM nca WHERE tipo_factura = 'FC') AS fc_venta,$n$, 'gerencial · fc_venta');
  v_def := pg_temp.parche(v_def,
$a$COALESCE(SUM(venta_prod) FILTER (WHERE tipo_factura='ZZ'),0) AS zz_venta,$a$,
$n$COALESCE(SUM(venta_prod) FILTER (WHERE tipo_factura='ZZ'),0)
              - (SELECT COALESCE(SUM(total),0) FROM nca WHERE tipo_factura <> 'FC') AS zz_venta,$n$, 'gerencial · zz_venta');

  -- 1562-b6: el ingreso real sin costo.
  v_def := pg_temp.parche(v_def,
$a$      COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_sin_costo
    FROM it$a$,
$n$      COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_sin_costo,
      -- 1562-b6 (#1562, D42): lo sin costo queda fuera del margen, también del real.
      COALESCE(SUM(ingreso_real) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_real_sin_costo
    FROM it$n$, 'gerencial · k_it');

  -- 1557-b3: las compras, netas de sus notas.
  v_def := pg_temp.parche(v_def,
$a$  k_compra AS (SELECT f.compras_facturas + t.compras_transferencias AS compras,
      f.compras_facturas, t.compras_transferencias$a$,
$n$  -- 1557-b3 (#1557, D9): «Compras del período» es neta de las notas de crédito de
  -- compra (devolución y ajuste), por la fecha de la nota, con las notas aparte.
  k_compra AS (SELECT f.compras_facturas - n.compras_notas_credito + t.compras_transferencias AS compras,
      f.compras_facturas, t.compras_transferencias, n.compras_notas_credito$n$, 'gerencial · k_compra');
  v_def := pg_temp.parche(v_def,
$a$       FROM public.compras_transferencias_netas(p_desde, p_hasta, v_sucursales) ct) t),$a$,
$n$       FROM public.compras_transferencias_netas(p_desde, p_hasta, v_sucursales) ct) t,
    (SELECT COALESCE(SUM(ncp.total),0) AS compras_notas_credito
       FROM notas_credito ncp
       JOIN compras c ON c.id = ncp.compra_id AND c.sucursal_id = ncp.sucursal_id
      WHERE ncp.sucursal_id = ANY(v_sucursales) AND ncp.fecha BETWEEN p_desde AND p_hasta
        AND COALESCE(c.estado,'') <> 'cancelada') n),$n$, 'gerencial · k_compra notas');

  -- REP-D: las notas de venta del kpi son las mismas que restan.
  v_def := pg_temp.parche(v_def,
$a$  -- mig 290 (#845): notas de credito de VENTA vigentes, por la fecha de la nota.
  -- No tocan los margenes: la contribucion (front) las resta. (`nc` mas arriba
  -- es la base de comision, no esto.)
  ncv AS (SELECT fecha, total FROM notas_credito_venta
    WHERE NOT anulada AND sucursal_id = ANY(v_sucursales) AND fecha BETWEEN p_desde AND p_hasta),
  k_ncv AS (SELECT COALESCE(SUM(total), 0) AS monto, COUNT(*) AS n FROM ncv),
  m_ncv AS (SELECT to_char(fecha, 'YYYY-MM') AS mes, SUM(total) AS monto FROM ncv GROUP BY 1),$a$,
$n$  -- mig 290 (#845): notas de credito de VENTA vigentes, por la fecha de la nota.
  -- REP-D: son las mismas que restan de la venta (`nca`), una fila por nota, así
  -- que venta_bruta − notas_credito_venta = venta. (`nc` mas arriba es la base
  -- de comision, no esto.)
  ncv AS (SELECT fecha, total, real FROM nca),
  k_ncv AS (SELECT COALESCE(SUM(total), 0) AS monto, COUNT(*) AS n FROM ncv),
  m_ncv AS (SELECT to_char(fecha, 'YYYY-MM') AS mes, SUM(total) AS monto, SUM(real) AS real FROM ncv GROUP BY 1),$n$,
    'gerencial · ncv');

  -- 1562-b6: el ingreso real sin costo, por mes.
  v_def := pg_temp.parche(v_def,
$a$           COALESCE(SUM(costo_bonif),0) AS bonif FROM it GROUP BY 1),$a$,
$n$           COALESCE(SUM(costo_bonif),0) AS bonif,
           COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_sin_costo,
           COALESCE(SUM(ingreso_real) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_real_sin_costo
      FROM it GROUP BY 1),$n$, 'gerencial · m_it');

  -- 1557-b3: las notas de compra, por mes.
  v_def := pg_temp.parche(v_def,
$a$  m_compra AS (SELECT mes, COALESCE(SUM(fact),0) + COALESCE(SUM(transf),0) AS compras,
      COALESCE(SUM(transf),0) AS compras_transferencias FROM ($a$,
$n$  m_compra AS (SELECT mes, COALESCE(SUM(fact),0) - COALESCE(SUM(ncp),0) + COALESCE(SUM(transf),0) AS compras,
      COALESCE(SUM(transf),0) AS compras_transferencias,
      COALESCE(SUM(ncp),0) AS compras_notas_credito FROM ($n$, 'gerencial · m_compra');
  v_def := pg_temp.parche(v_def,
$a$      SELECT to_char(fecha_compra,'YYYY-MM') AS mes, total AS fact, 0::numeric AS transf
$a$,
$n$      SELECT to_char(fecha_compra,'YYYY-MM') AS mes, total AS fact, 0::numeric AS transf, 0::numeric AS ncp
$n$, 'gerencial · m_compra facturas');
  v_def := pg_temp.parche(v_def,
$a$      SELECT to_char(ct.fecha_local,'YYYY-MM'), 0::numeric, ct.monto
      FROM public.compras_transferencias_netas(p_desde, p_hasta, v_sucursales) ct
    ) x GROUP BY 1),$a$,
$n$      SELECT to_char(ct.fecha_local,'YYYY-MM'), 0::numeric, ct.monto, 0::numeric
      FROM public.compras_transferencias_netas(p_desde, p_hasta, v_sucursales) ct
      UNION ALL
      SELECT to_char(ncp.fecha,'YYYY-MM'), 0::numeric, 0::numeric, ncp.total
      FROM notas_credito ncp
      JOIN compras c ON c.id = ncp.compra_id AND c.sucursal_id = ncp.sucursal_id
      WHERE ncp.sucursal_id = ANY(v_sucursales) AND ncp.fecha BETWEEN p_desde AND p_hasta
        AND COALESCE(c.estado,'') <> 'cancelada'
    ) x GROUP BY 1),$n$, 'gerencial · m_compra notas');

  -- REP-D y 1562-b6: el mensual.
  v_def := pg_temp.parche(v_def,
$a$  mensual AS (SELECT ms.mes, COALESCE(mp.pedidos,0) AS pedidos, COALESCE(mp.venta,0) AS venta,
      COALESCE(mp.venta_real,0) AS venta_real, COALESCE(mp.clientes,0) AS clientes,
      COALESCE(mp.ticket,0) AS ticket,
      COALESCE(mi.cmv,0) AS cmv, COALESCE(mi.bonif,0) AS bonif,
      (COALESCE(mp.venta_real,0) - COALESCE(mi.cmv,0) + COALESCE(md.descuentos,0)) AS margen_real,$a$,
$n$  mensual AS (SELECT ms.mes, COALESCE(mp.pedidos,0) AS pedidos,
      COALESCE(mp.venta,0) - COALESCE(mnv.monto,0) AS venta,                 -- REP-D
      COALESCE(mp.venta_real,0) - COALESCE(mnv.real,0) AS venta_real, COALESCE(mp.clientes,0) AS clientes,
      COALESCE(mp.ticket,0) AS ticket,
      COALESCE(mi.cmv,0) AS cmv, COALESCE(mi.bonif,0) AS bonif,
      (COALESCE(mp.venta_real,0) - COALESCE(mnv.real,0) - COALESCE(mi.ingreso_real_sin_costo,0)  -- 1562-b6
       - COALESCE(mi.cmv,0) + COALESCE(md.descuentos,0)) AS margen_real,$n$, 'gerencial · mensual');
  v_def := pg_temp.parche(v_def,
$a$      COALESCE(mc.compras_transferencias,0) AS compras_transferencias,
$a$,
$n$      COALESCE(mc.compras_transferencias,0) AS compras_transferencias,
      COALESCE(mc.compras_notas_credito,0) AS compras_notas_credito,
      -- 1562-b6: lo sin costo del mes, fuera de su margen (para el % del mes).
      COALESCE(mi.ingreso_sin_costo,0) AS ingreso_sin_costo,
$n$, 'gerencial · mensual compras');

  -- 1562-b6: los márgenes de vendedores, rubros y productos.
  v_def := pg_temp.parche(v_def,
$a$      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real,
      COALESCE(SUM(costo_bonif),0) AS bonif FROM it GROUP BY usuario_id),$a$,
$n$      -- 1562-b6 (#1562, D42): la venta sin costo queda fuera del margen, y aparte.
      COALESCE(SUM(subtotal) FILTER (WHERE NOT sin_costo),0)
        - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      COALESCE(SUM(ingreso_real) FILTER (WHERE NOT sin_costo),0)
        - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real,
      COALESCE(SUM(costo_bonif),0) AS bonif,
      COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS venta_sin_costo
      FROM it GROUP BY usuario_id),$n$, 'gerencial · v_ent');
  v_def := pg_temp.parche(v_def,
$a$      e.pedidos, e.venta, e.venta_real, e.margen_comercial, e.margen_real, e.bonif,$a$,
$n$      e.pedidos, e.venta, e.venta_real, e.margen_comercial, e.margen_real, e.bonif, e.venta_sin_costo,$n$,
    'gerencial · vendedores');
  v_def := pg_temp.parche(v_def,
$a$      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real,
      COALESCE(SUM(costo_bonif),0) AS bonif, bool_or(sin_costo) AS sin_costo$a$,
$n$      COALESCE(SUM(subtotal) FILTER (WHERE NOT sin_costo),0)
        - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      COALESCE(SUM(ingreso_real) FILTER (WHERE NOT sin_costo),0)
        - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real,
      COALESCE(SUM(costo_bonif),0) AS bonif, bool_or(sin_costo) AS sin_costo,
      COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS venta_sin_costo$n$,
    'gerencial · categorias');
  v_def := pg_temp.parche(v_def,
$a$        SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen,
        SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real$a$,
$n$        COALESCE(SUM(subtotal) FILTER (WHERE NOT sin_costo),0)
          - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen,
        COALESCE(SUM(ingreso_real) FILTER (WHERE NOT sin_costo),0)
          - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real$n$,
    'gerencial · top_prod');

  -- REP-D: el top de clientes y la serie diaria.
  v_def := pg_temp.parche(v_def,
$a$      COUNT(DISTINCT p.id) AS pedidos, SUM(p.venta_prod) AS venta -- cargo_4
    FROM ped p JOIN clientes c ON c.id=p.cliente_id GROUP BY c.id ORDER BY venta DESC, c.id LIMIT 10),$a$,
$n$      COUNT(DISTINCT p.id) AS pedidos, SUM(p.venta_prod) AS venta -- cargo_4; REP-D: neta de sus NC
    FROM (SELECT id, cliente_id, venta_prod FROM ped
          UNION ALL SELECT NULL, cliente_id, -total FROM nca) p
    JOIN clientes c ON c.id=p.cliente_id GROUP BY c.id ORDER BY venta DESC, c.id LIMIT 10),$n$,
    'gerencial · top_cli');
  v_def := pg_temp.parche(v_def,
$a$  serie AS (SELECT to_char(fecha,'YYYY-MM-DD') AS dia, SUM(venta_prod) AS venta FROM ped GROUP BY fecha ORDER BY fecha)$a$,
$n$  serie AS (SELECT to_char(fecha,'YYYY-MM-DD') AS dia, SUM(venta_prod) AS venta
      FROM (SELECT fecha, venta_prod FROM ped UNION ALL SELECT fecha, -total FROM nca) s  -- REP-D
     GROUP BY fecha ORDER BY fecha)$n$, 'gerencial · serie');

  -- 1562-b6: los márgenes de kpis. Claves nuevas: venta_bruta,
  -- ingreso_real_sin_costo, compras_notas_credito.
  v_def := pg_temp.parche(v_def,
$a$'margen_comercial', kp.venta - ki.cmv + kd.descuentos,
        'margen_neto', kp.venta - ki.cmv - ki.bonif + kd.descuentos,$a$,
$n$'margen_comercial', kp.venta - ki.ingreso_sin_costo - ki.cmv + kd.descuentos,
        'margen_neto', kp.venta - ki.ingreso_sin_costo - ki.cmv - ki.bonif + kd.descuentos,$n$,
    'gerencial · kpis margen');
  v_def := pg_temp.parche(v_def,
$a$'compras_transferencias', kcp.compras_transferencias, 'ingreso_sin_costo', ki.ingreso_sin_costo,$a$,
$n$'compras_transferencias', kcp.compras_transferencias, 'ingreso_sin_costo', ki.ingreso_sin_costo,
        'compras_notas_credito', kcp.compras_notas_credito,
        'ingreso_real_sin_costo', ki.ingreso_real_sin_costo, 'venta_bruta', kp.venta_bruta,$n$,
    'gerencial · kpis nuevas');
  v_def := pg_temp.parche(v_def,
$a$'margen_comercial_neto', kp.venta_neta - ki.cmv + kd.descuentos,$a$,
$n$'margen_comercial_neto', kp.venta_neta - ki.ingreso_real_sin_costo - ki.cmv + kd.descuentos,$n$,
    'gerencial · kpis margen neto');
  v_def := pg_temp.parche(v_def,
$a$'margen_real', kp.venta_real - ki.cmv + kd.descuentos,
        'margen_real_neto', kp.venta_real - ki.cmv - ki.bonif + kd.descuentos,$a$,
$n$'margen_real', kp.venta_real - ki.ingreso_real_sin_costo - ki.cmv + kd.descuentos,
        'margen_real_neto', kp.venta_real - ki.ingreso_real_sin_costo - ki.cmv - ki.bonif + kd.descuentos,$n$,
    'gerencial · kpis margen real');
  v_def := pg_temp.parche(v_def,
$a$de productos sin costo (margen sobreestimado)$a$,
$n$de productos sin costo, que queda fuera del margen$n$, 'gerencial · alerta sin costo');

  EXECUTE v_def;
END
$ger$;

-- =========================================================================
-- reporte_ventas_por_cliente · REP-D
-- =========================================================================
DO $cli$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_ventas_por_cliente(date,date,uuid,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$      AND pe.sucursal_id = ANY(v_sucursales)
  ),
  vendedores AS ($a$,
$n$      AND pe.sucursal_id = ANY(v_sucursales)
    UNION ALL
    -- REP-D (#1545, D44): cada nota de crédito resta del cliente, del vendedor de
    -- la boleta y del mes de la nota. No es un pedido (id NULL).
    SELECT NULL::bigint, n.cliente_id, -SUM(n.monto), n.fecha, n.usuario_id
      FROM public._ventas_nc(v_sucursales, p_desde, p_hasta) n
     GROUP BY n.nota_credito_id, n.cliente_id, n.fecha, n.usuario_id
  ),
  vendedores AS ($n$, 'por cliente · ventana');
  v_def := pg_temp.parche(v_def,
$a$           COUNT(*)::int AS pedidos,
           SUM(v.total)  AS total$a$,
$n$           COUNT(v.id)::int AS pedidos,
           SUM(v.total)  AS total$n$, 'por cliente · vendedores');
  v_def := pg_temp.parche(v_def,
$a$    SELECT
      v.cliente_id,
      v.total,$a$,
$n$    SELECT
      v.id AS pedido_id,
      v.cliente_id,
      v.total,$n$, 'por cliente · base');
  v_def := pg_temp.parche(v_def,
$a$           COUNT(*)::int AS pedidos,
           SUM(total)    AS total
    FROM base$a$,
$n$           COUNT(pedido_id)::int AS pedidos,
           SUM(total)    AS total
    FROM base$n$, 'por cliente · por_cliente');
  -- Los clientes que se cuentan son los que compraron: el que sólo tiene una
  -- nota en el período sale en la lista, con su venta en negativo, y no suma.
  v_def := pg_temp.parche(v_def,
$a$           COUNT(*)::int      AS clientes,$a$,
$n$           (COUNT(*) FILTER (WHERE pedidos > 0))::int AS clientes,$n$, 'por cliente · por_zona');
  v_def := pg_temp.parche(v_def,
$a$      'clientes', (SELECT COUNT(*)::int                 FROM por_cliente),$a$,
$n$      'clientes', (SELECT (COUNT(*) FILTER (WHERE pedidos > 0))::int FROM por_cliente),$n$, 'por cliente · totales');
  v_def := pg_temp.parche(v_def,
$a$Excluye cancelados, cambios/devoluciones y vales blancos (consumo interno).'$a$,
$n$Excluye cancelados, cambios/devoluciones y vales blancos (consumo interno). Restan las notas de crédito, por la fecha de la nota.'$n$,
    'por cliente · criterio');
  EXECUTE v_def;
END
$cli$;

-- =========================================================================
-- reporte_ventas_por_preventista · REP-D, 1597-b1, 1562-b9
-- =========================================================================
DO $pre$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_ventas_por_preventista(date,date,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$BEGIN
  IF NOT v_es_servicio THEN$a$,
$n$BEGIN
  -- 1562-b9 (#1562): sin fechas es «todo» (el front lo pide así); desde después
  -- de hasta daba ceros sin decir por qué.
  IF p_desde > p_hasta THEN
    RAISE EXCEPTION 'La fecha desde (%) es posterior a la fecha hasta (%)', p_desde, p_hasta
      USING ERRCODE = '22023';
  END IF;
  IF NOT v_es_servicio THEN$n$, 'por preventista · fechas');
  v_def := pg_temp.parche(v_def,
$a$    SELECT p.usuario_id, p.total, p.estado,$a$,
$n$    SELECT p.id, p.usuario_id, p.total, p.estado,$n$, 'por preventista · ped');
  v_def := pg_temp.parche(v_def,
    pg_temp.tramo(v_def, '  por_usuario AS (', '  SELECT COALESCE((', 'por preventista · por_usuario'),
$n$  -- 1597-b1 (#1597): «Pagado» es plata. Lo pagado con una forma no dineraria (la
  -- nota de crédito, el adelanto de sueldo: las de `formas_pago()`, #1249) cancela
  -- deuda pero no es plata.
  no_din AS (
    SELECT pg.pedido_id, SUM(pg.monto) AS monto
      FROM pagos pg
     WHERE pg.pedido_id IN (SELECT ped.id FROM ped)
       AND pg.forma_pago IN (SELECT f.forma FROM public.formas_pago() f WHERE NOT f.dineraria)
     GROUP BY pg.pedido_id
  ),
  pagado AS (
    SELECT ped.id, ped.monto_pagado - LEAST(COALESCE(nd.monto, 0), ped.monto_pagado) AS plata
      FROM ped LEFT JOIN no_din nd ON nd.pedido_id = ped.id
  ),
  por_usuario AS (
    SELECT x.usuario_id,
           SUM(x.venta)     AS total_ventas,
           SUM(x.pedidos)   AS cantidad_pedidos,
           SUM(x.pagado)    AS total_pagado,
           SUM(x.pendiente) AS total_pendiente
      FROM (SELECT ped.usuario_id, ped.venta_prod AS venta, 1 AS pedidos, pg.plata AS pagado,
                   GREATEST(0, ped.total - ped.monto_pagado) AS pendiente
              FROM ped JOIN pagado pg ON pg.id = ped.id
            UNION ALL
            -- REP-D (#1545, D44): las notas de crédito restan de la venta del
            -- vendedor de la boleta, por la fecha de la nota. No son pedidos.
            SELECT n.usuario_id, -n.monto, 0, 0, 0
              FROM public._ventas_nc(v_sucursales, COALESCE(p_desde, '-infinity'::date),
                                     COALESCE(p_hasta, 'infinity'::date)) n) x
     GROUP BY x.usuario_id
  )
$n$, 'por preventista · por_usuario');
  EXECUTE v_def;
END
$pre$;

-- =========================================================================
-- reporte_rentabilidad · 1562-b6, 1562-b9
-- =========================================================================
DO $ren$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_rentabilidad(date,date,bigint,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF p_combos IS NULL OR p_combos NOT IN ('incluir', 'excluir', 'solo') THEN$a$,
$n$  -- 1562-b9 (#1562): sin fechas es «todo» (el front lo pide así); desde después
  -- de hasta daba ceros sin decir por qué.
  IF p_desde > p_hasta THEN
    RAISE EXCEPTION 'La fecha desde (%) es posterior a la fecha hasta (%)', p_desde, p_hasta
      USING ERRCODE = '22023';
  END IF;
  IF p_combos IS NULL OR p_combos NOT IN ('incluir', 'excluir', 'solo') THEN$n$, 'rentabilidad · fechas');
  v_def := pg_temp.parche(v_def,
$a$           SUM(it.ingreso_real) FILTER (WHERE it.costo IS NULL) AS ing_sin_costo$a$,
$n$           SUM(it.ingreso_real) FILTER (WHERE it.costo IS NULL) AS ing_sin_costo,
           SUM(it.ingreso_real) FILTER (WHERE it.costo IS NULL AND it.en_combo)     AS ing_sin_costo_combo,
           SUM(it.ingreso_real) FILTER (WHERE it.costo IS NULL AND NOT it.en_combo) AS ing_sin_costo_fuera$n$,
    'rentabilidad · sin costo');
  v_def := pg_temp.parche(v_def,
    pg_temp.tramo(v_def, $a$        'margen',           ROUND($a$, $a$        'fueraDeCombo', $a$, 'rentabilidad · margen'),
$n$        -- 1562-b6 (#1562, D42): el ingreso sin costo queda fuera del margen; va
        -- aparte (sinCosto, ingresosSinCosto).
        'margen',           ROUND(pp.ingresos - COALESCE(pp.ing_sin_costo, 0) - pp.costos, 2),
        'margenPorcentaje', CASE WHEN pp.ingresos - COALESCE(pp.ing_sin_costo, 0) > 0
                                 THEN ROUND((pp.ingresos - COALESCE(pp.ing_sin_costo, 0) - pp.costos)
                                            / (pp.ingresos - COALESCE(pp.ing_sin_costo, 0)) * 100, 2)
                                 ELSE 0 END,
$n$, 'rentabilidad · margen');
  v_def := pg_temp.parche(v_def,
$a$          'margen',   ROUND(COALESCE(pp.ing_fuera, 0) - COALESCE(pp.cos_fuera, 0), 2)),$a$,
$n$          'margen',   ROUND(COALESCE(pp.ing_fuera, 0) - COALESCE(pp.ing_sin_costo_fuera, 0)
                            - COALESCE(pp.cos_fuera, 0), 2)),$n$, 'rentabilidad · fuera de combo');
  v_def := pg_temp.parche(v_def,
$a$          'margen',   ROUND(COALESCE(pp.ing_combo, 0) - COALESCE(pp.cos_combo, 0), 2))$a$,
$n$          'margen',   ROUND(COALESCE(pp.ing_combo, 0) - COALESCE(pp.ing_sin_costo_combo, 0)
                            - COALESCE(pp.cos_combo, 0), 2))$n$, 'rentabilidad · en combo');
  v_def := pg_temp.parche(v_def,
$a$      ) ORDER BY (pp.ingresos - pp.costos) DESC)$a$,
$n$      ) ORDER BY (pp.ingresos - COALESCE(pp.ing_sin_costo, 0) - pp.costos) DESC)$n$, 'rentabilidad · orden');
  v_def := pg_temp.parche(v_def,
    pg_temp.tramo(v_def, $a$        'margenTotal',$a$, $a$        'cantidadPedidos',$a$, 'rentabilidad · totales'),
$n$        'margenTotal',       COALESCE(ROUND(SUM(ingresos) - COALESCE(SUM(ing_sin_costo), 0) - SUM(costos), 2), 0),
        'margenPorcentaje',  CASE WHEN COALESCE(SUM(ingresos), 0) - COALESCE(SUM(ing_sin_costo), 0) > 0
                                  THEN ROUND((SUM(ingresos) - COALESCE(SUM(ing_sin_costo), 0) - SUM(costos))
                                             / (SUM(ingresos) - COALESCE(SUM(ing_sin_costo), 0)) * 100, 2)
                                  ELSE 0 END,
$n$, 'rentabilidad · totales');
  EXECUTE v_def;
END
$ren$;

-- =========================================================================
-- reporte_alerta_detalle · REP-D en la lista de «Productos sin costo»
-- =========================================================================
-- La lista suma el KPI `ingreso_sin_costo` del gerencial, que ahora resta las
-- notas que acreditan una línea sin costo: la lista también las resta, por
-- producto y por la fecha de la nota.
DO $ale$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_alerta_detalle(bigint,text,date,date,boolean)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
    pg_temp.tramo(v_def,
      $a$      SELECT COALESCE(prod.nombre, '(producto borrado)') AS nombre, SUM(pi.subtotal) AS valor,$a$,
      $a$      GROUP BY prod.id, prod.nombre$a$, 'alerta · sin costo'),
$n$      SELECT COALESCE(prod.nombre, '(producto borrado)') AS nombre, SUM(x.subtotal) AS valor,
             CASE WHEN prod.id IS NULL THEN 'producto borrado' ELSE 'sin costo cargado' END AS detalle
      FROM (SELECT pi.producto_id, pi.subtotal, pi.costo_unitario_al_crear
              FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id
             WHERE p.estado = ANY(v_estados) AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)
               AND p.tipo_factura IS DISTINCT FROM 'VB'
               AND (p_desde IS NULL OR p.fecha >= p_desde)
               AND (p_hasta IS NULL OR p.fecha <= p_hasta)
               AND NOT pi.es_bonificacion
            UNION ALL
            -- REP-D (#1545, D44): la nota de crédito de una línea sin costo resta, como
            -- en el KPI del gerencial (por la fecha de la nota).
            SELECT n.producto_id, -n.monto, n.costo_al_crear
              FROM public._ventas_nc(v_sucursales, COALESCE(p_desde, '-infinity'::date),
                                     COALESCE(p_hasta, 'infinity'::date)) n) x
      LEFT JOIN productos prod ON prod.id = x.producto_id
      WHERE public.costo_valuacion(x.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                   prod.costo_sin_iva, prod.impuestos_internos) IS NULL
$n$, 'alerta · sin costo');
  EXECUTE v_def;
END
$ale$;

-- =========================================================================
-- 1562-b7 · el rótulo del rubro en Rendimiento, Stock y Valuación
-- =========================================================================
DO $rub$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.rendimiento_preventistas(bigint,date)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$                ELSE COALESCE(NULLIF(prod.categoria, ''), '(sin categoría)') END AS categoria$a$,
$n$                -- 1562-b7 (#1562, D43): el mismo rótulo en todos los reportes.
                ELSE public._rubro_rotulo(COALESCE(cat.nombre, prod.categoria)) END AS categoria$n$,
    'rendimiento · rubro');
  v_def := pg_temp.parche(v_def,
$a$    LEFT JOIN marcas mar ON mar.id = prod.marca_id$a$,
$n$    LEFT JOIN marcas mar ON mar.id = prod.marca_id
    LEFT JOIN categorias cat ON cat.id = prod.categoria_id  -- 1562-b7: el rubro$n$,
    'rendimiento · join del rubro');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.reporte_stock_red(bigint)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$           COALESCE(NULLIF(p.categoria,''),'(sin categoría)') AS categoria,$a$,
$n$           -- 1562-b7 (#1562, D43): el mismo rótulo en todos los reportes.
           public._rubro_rotulo(COALESCE((SELECT cat.nombre FROM categorias cat
                                           WHERE cat.id = p.categoria_id), p.categoria)) AS categoria,$n$,
    'stock red · rubro');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.reporte_valuacion_inventario(bigint)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$           COALESCE(NULLIF(p.categoria,''),'(sin categoría)') AS categoria,$a$,
$n$           -- 1562-b7 (#1562, D43): el mismo rótulo en todos los reportes.
           public._rubro_rotulo(COALESCE((SELECT cat.nombre FROM categorias cat
                                           WHERE cat.id = p.categoria_id), p.categoria)) AS categoria,$n$,
    'valuacion · rubro');
  EXECUTE v_def;
END
$rub$;

-- =========================================================================
-- bot_compras_periodo · 1557-b3
-- =========================================================================
DO $bco$
DECLARE
  v_def text := pg_get_functiondef('public.bot_compras_periodo(date,date,bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    FROM public.compras_transferencias_netas(p_desde, p_hasta, ARRAY[p_sucursal_id]) ct
  )$a$,
$n$    FROM public.compras_transferencias_netas(p_desde, p_hasta, ARRAY[p_sucursal_id]) ct
  ),
  -- 1557-b3 (#1557, D9): las compras son netas de sus notas de crédito
  -- (devolución y ajuste), por la fecha de la nota, con las notas aparte.
  ncc AS (
    SELECT COALESCE(SUM(ncp.total), 0) AS monto
    FROM notas_credito ncp
    JOIN compras c ON c.id = ncp.compra_id AND c.sucursal_id = ncp.sucursal_id
    WHERE ncp.sucursal_id = p_sucursal_id
      AND ncp.fecha >= p_desde AND ncp.fecha <= p_hasta
      AND COALESCE(c.estado, '') <> 'cancelada'
  )$n$, 'bot compras · ncc');
  v_def := pg_temp.parche(v_def,
$a$    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM compras_filtradas) + (SELECT neto FROM transf),$a$,
$n$    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM compras_filtradas) - (SELECT monto FROM ncc)
                     + (SELECT neto FROM transf),$n$, 'bot compras · total');
  v_def := pg_temp.parche(v_def,
$a$    'compras_transferencias', (SELECT neto FROM transf),$a$,
$n$    'compras_transferencias', (SELECT neto FROM transf),
    'compras_notas_credito', (SELECT monto FROM ncc),$n$, 'bot compras · notas');
  EXECUTE v_def;
END
$bco$;

-- =========================================================================
-- Los tablero_* y obtener_resumen_compras, si siguen existiendo (SEG-3)
-- =========================================================================
DO $tab$
DECLARE
  v_def text;
BEGIN
  -- 1562-b7: el rótulo del tablero es el de los reportes (sin mayúsculas, y
  -- «Sin rubro»). `_tablero_cat_nombre` queda como alias de `_rubro_rotulo`.
  IF to_regprocedure('public._tablero_cat_nombre(text)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public._tablero_cat_nombre(text)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$ SELECT upper(btrim(COALESCE(NULLIF(btrim(p_nombre), ''), 'Sin categoria'))) $a$,
$n$
  -- 1562-b7 (#1562, D43): el rótulo de los reportes, sin pasarlo a mayúsculas.
  SELECT public._rubro_rotulo(p_nombre)
$n$, '_tablero_cat_nombre');
    EXECUTE v_def;
  END IF;

  IF to_regprocedure('public.tablero_categorias(bigint,date,date,bigint)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public.tablero_categorias(bigint,date,date,bigint)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$           _tablero_cat_nombre(COALESCE(c.nombre, pr.categoria)) AS cat_nombre$a$,
$n$           CASE WHEN pr.id IS NULL THEN '(producto borrado)'  -- 1562-b7: como el gerencial
                ELSE public._rubro_rotulo(COALESCE(c.nombre, pr.categoria)) END AS cat_nombre$n$,
      'tablero_categorias · rubro');
    v_def := pg_temp.parche(v_def,
$a$     WHERE p_zona_id IS NULL OR v.zona_id = p_zona_id
  ),$a$,
$n$     WHERE p_zona_id IS NULL OR v.zona_id = p_zona_id
    UNION ALL
    -- REP-D (#1545, D44): la nota de crédito resta del rubro, por la fecha de la
    -- nota. No suma unidades ni compradores.
    SELECT NULL::bigint, 0, -n.monto, false,
           CASE WHEN pr.id IS NULL THEN '(producto borrado)'
                ELSE public._rubro_rotulo(COALESCE(c.nombre, pr.categoria)) END
      FROM public._ventas_nc(v_sucs, v_desde, v_hasta) n
      LEFT JOIN productos pr ON pr.id = n.producto_id
      LEFT JOIN categorias c ON c.id = pr.categoria_id
     WHERE p_zona_id IS NULL OR n.zona_id = p_zona_id
  ),$n$, 'tablero_categorias · notas');
    EXECUTE v_def;
  END IF;

  IF to_regprocedure('public.tablero_facturacion_mensual(bigint,integer)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public.tablero_facturacion_mensual(bigint,integer)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$  WITH v AS (SELECT * FROM _tablero_ventas(v_sucs, make_date(v_anio - 1, 1, 1), make_date(v_anio, 12, 31))),$a$,
$n$  WITH v AS (SELECT pedido_id, cliente_id, fecha, total
               FROM _tablero_ventas(v_sucs, make_date(v_anio - 1, 1, 1), make_date(v_anio, 12, 31))
             UNION ALL
             -- REP-D (#1545, D44): la nota de crédito resta en su mes. No es un pedido
             -- ni un cliente comprador.
             SELECT NULL::bigint, NULL::bigint, n.fecha, -SUM(n.monto)
               FROM public._ventas_nc(v_sucs, make_date(v_anio - 1, 1, 1), make_date(v_anio, 12, 31)) n
              GROUP BY n.nota_credito_id, n.fecha),$n$, 'tablero_facturacion_mensual · notas');
    EXECUTE v_def;
  END IF;

  IF to_regprocedure('public.tablero_top_clientes_zona(bigint,date,date,integer,integer)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public.tablero_top_clientes_zona(bigint,date,date,integer,integer)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$    SELECT cliente_id, sum(total) AS total, count(*) AS pedidos
      FROM _tablero_ventas(v_sucs, v_desde, v_hasta) GROUP BY cliente_id$a$,
$n$    -- REP-D (#1545, D44): neta de las notas de crédito del cliente, por la fecha
    -- de la nota. La nota no es un pedido.
    SELECT cliente_id, sum(total) AS total, count(pedido_id) AS pedidos
      FROM (SELECT cliente_id, pedido_id, total FROM _tablero_ventas(v_sucs, v_desde, v_hasta)
            UNION ALL
            SELECT n.cliente_id, NULL::bigint, -n.monto
              FROM public._ventas_nc(v_sucs, v_desde, v_hasta) n) x
     GROUP BY cliente_id$n$, 'tablero_top_clientes_zona · notas');
    v_def := pg_temp.parche(v_def,
$a$           (SELECT count(*) FROM rk WHERE rk.zona_id = z.id AND rk.activo) AS compradores,$a$,
$n$           (SELECT count(*) FROM rk WHERE rk.zona_id = z.id AND rk.activo AND rk.pedidos > 0) AS compradores,$n$,
      'tablero_top_clientes_zona · compradores');
    EXECUTE v_def;
  END IF;

  IF to_regprocedure('public.tablero_cobertura(bigint,date)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public.tablero_cobertura(bigint,date)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$  v AS (SELECT * FROM _tablero_ventas(v_sucs, v_ini, v_fin) WHERE zona_id IS NOT NULL),$a$,
$n$  v AS (SELECT * FROM _tablero_ventas(v_sucs, v_ini, v_fin) WHERE zona_id IS NOT NULL),
  -- REP-D (#1545, D44): la facturación de la zona es neta de sus notas de crédito.
  vnc AS (SELECT n.zona_id, sum(n.monto) AS monto
            FROM public._ventas_nc(v_sucs, v_ini, v_fin) n
           WHERE n.zona_id IS NOT NULL GROUP BY n.zona_id),$n$, 'tablero_cobertura · vnc');
    v_def := pg_temp.parche(v_def,
$a$           (SELECT COALESCE(sum(v.total), 0) FROM v WHERE v.zona_id = z.id) AS facturacion,$a$,
$n$           (SELECT COALESCE(sum(v.total), 0) FROM v WHERE v.zona_id = z.id)
             - COALESCE((SELECT vnc.monto FROM vnc WHERE vnc.zona_id = z.id), 0) AS facturacion,$n$,
      'tablero_cobertura · facturacion');
    EXECUTE v_def;
  END IF;

  IF to_regprocedure('public.tablero_kpis(bigint,integer)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public.tablero_kpis(bigint,integer)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$  WITH v AS (SELECT * FROM _tablero_ventas(v_sucs, (v_ini - interval '1 year')::date, v_corte)),$a$,
$n$  WITH v AS (SELECT * FROM _tablero_ventas(v_sucs, (v_ini - interval '1 year')::date, v_corte)),
  -- REP-D (#1545, D44): los montos son netos de las notas de crédito, por la
  -- fecha de la nota. Los pedidos y los clientes no cambian.
  n AS (SELECT fecha, monto FROM public._ventas_nc(v_sucs, (v_ini - interval '1 year')::date, v_corte)),$n$,
      'tablero_kpis · n');
    v_def := pg_temp.parche(v_def,
$a$    'mes_total',      (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha BETWEEN v_mes AND v_corte),$a$,
$n$    'mes_total',      (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha BETWEEN v_mes AND v_corte)
                      - (SELECT COALESCE(sum(monto), 0) FROM n WHERE fecha BETWEEN v_mes AND v_corte),$n$,
      'tablero_kpis · mes');
    v_def := pg_temp.parche(v_def,
$a$    'mes_ant_total',  (SELECT COALESCE(sum(total), 0) FROM v
                        WHERE fecha BETWEEN (v_mes - interval '1 year')::date AND v_corte_ant),$a$,
$n$    'mes_ant_total',  (SELECT COALESCE(sum(total), 0) FROM v
                        WHERE fecha BETWEEN (v_mes - interval '1 year')::date AND v_corte_ant)
                      - (SELECT COALESCE(sum(monto), 0) FROM n
                        WHERE fecha BETWEEN (v_mes - interval '1 year')::date AND v_corte_ant),$n$,
      'tablero_kpis · mes anterior');
    v_def := pg_temp.parche(v_def,
$a$    'anio_total',     (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha BETWEEN v_ini AND v_corte),$a$,
$n$    'anio_total',     (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha BETWEEN v_ini AND v_corte)
                      - (SELECT COALESCE(sum(monto), 0) FROM n WHERE fecha BETWEEN v_ini AND v_corte),$n$,
      'tablero_kpis · año');
    v_def := pg_temp.parche(v_def,
$a$    'anio_ant_total', (SELECT COALESCE(sum(total), 0) FROM v
                        WHERE fecha BETWEEN (v_ini - interval '1 year')::date AND v_corte_ant),$a$,
$n$    'anio_ant_total', (SELECT COALESCE(sum(total), 0) FROM v
                        WHERE fecha BETWEEN (v_ini - interval '1 year')::date AND v_corte_ant)
                      - (SELECT COALESCE(sum(monto), 0) FROM n
                        WHERE fecha BETWEEN (v_ini - interval '1 year')::date AND v_corte_ant),$n$,
      'tablero_kpis · año anterior');
    v_def := pg_temp.parche(v_def,
$a$    'clientes_nunca',$a$,
$n$    -- 1545-b3 (#1545): clientes_activos_30 (compró en los últimos 30 días) y
    -- clientes_inactivos_14 (no compra hace más de 14) se superponen: quien compró
    -- hace 15 a 30 días está en los dos. Las claves quedan (quien las lee no
    -- cambia); ésta es el complemento de las activas:
    -- activos_30 + sin_compra_30 + nunca = cartera.
    'clientes_sin_compra_30', (SELECT count(*) FROM base_cli b JOIN ult u ON u.cliente_id = b.id
                              WHERE u.ultima <= v_corte - 30),
    'clientes_nunca',$n$, 'tablero_kpis · sin compra 30');
    EXECUTE v_def;
  END IF;

  IF to_regprocedure('public.tablero_productos_categoria(uuid,text,bigint,date,date,bigint)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public.tablero_productos_categoria(uuid,text,bigint,date,date,bigint)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$                  THEN _tablero_cat_nombre(COALESCE(c.nombre, pr.categoria)) = _tablero_cat_nombre(p_categoria_nombre)$a$,
$n$                  -- 1562-b7: el rótulo ya no va en mayúsculas; la comparación sigue sin distinguirlas.
                  THEN upper(CASE WHEN pr.id IS NULL THEN '(producto borrado)'
                                  ELSE _tablero_cat_nombre(COALESCE(c.nombre, pr.categoria)) END)
                       = upper(_tablero_cat_nombre(p_categoria_nombre))$n$, 'tablero_productos_categoria · filtro');
    v_def := pg_temp.parche(v_def,
$a$    'nombre', COALESCE(_tablero_cat_nombre(p_categoria_nombre), (SELECT nombre FROM categorias WHERE id = p_categoria_id), 'Sin categoria'),$a$,
$n$    'nombre', COALESCE(CASE WHEN p_categoria_nombre IS NOT NULL THEN _tablero_cat_nombre(p_categoria_nombre) END,
                       (SELECT nombre FROM categorias WHERE id = p_categoria_id), 'Sin rubro'),$n$,
      'tablero_productos_categoria · nombre');
    EXECUTE v_def;
  END IF;

  IF to_regprocedure('public.tablero_ficha_cliente(bigint)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public.tablero_ficha_cliente(bigint)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$  SELECT sucursal_id INTO v_suc FROM clientes WHERE id = p_cliente_id;
  IF v_suc IS NULL THEN RAISE EXCEPTION 'Cliente % inexistente', p_cliente_id; END IF;$a$,
$n$  -- 1597-b2 (#1597): el rol y las sucursales primero. Antes cualquier autenticado
  -- recibía «Cliente N inexistente» y distinguía los ids que existen, y uno de
  -- otra sucursal daba «la sucursal N no está asignada». Ahora lo inexistente y
  -- lo ajeno dan lo mismo, y sólo después del rol.
  PERFORM _tablero_sucursales(NULL);
  SELECT sucursal_id INTO v_suc FROM clientes
   WHERE id = p_cliente_id
     AND (auth.uid() IS NULL
          OR sucursal_id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                              WHERE us.usuario_id = auth.uid()));
  IF v_suc IS NULL THEN RAISE EXCEPTION 'Cliente % inexistente', p_cliente_id; END IF;$n$,
      'tablero_ficha_cliente · rol primero');
    v_def := pg_temp.parche(v_def,
$a$           COALESCE(cat.nombre, NULLIF(btrim(pr.categoria), ''), 'Sin categoria') AS categoria$a$,
$n$           CASE WHEN pr.id IS NULL THEN '(producto borrado)'  -- 1562-b7
                ELSE public._rubro_rotulo(COALESCE(cat.nombre, pr.categoria)) END AS categoria$n$,
      'tablero_ficha_cliente · rubro');
    EXECUTE v_def;
  END IF;

  IF to_regprocedure('public.obtener_resumen_compras(date,date)') IS NOT NULL THEN
    v_def := pg_get_functiondef('public.obtener_resumen_compras(date,date)'::regprocedure);
    v_def := pg_temp.parche(v_def,
$a$DECLARE
  v_transf numeric;$a$,
$n$DECLARE
  v_transf numeric;
  v_nc     numeric;$n$, 'resumen compras · declare');
    v_def := pg_temp.parche(v_def,
$a$  -- mig 291 (#941): una fila por compra.$a$,
$n$  -- 1557-b3 (#1557, D9): el monto total es neto de las notas de crédito de
  -- compra, por la fecha de la nota.
  SELECT COALESCE(SUM(ncp.total), 0) INTO v_nc
    FROM notas_credito ncp
    JOIN compras c ON c.id = ncp.compra_id AND c.sucursal_id = ncp.sucursal_id
   WHERE ncp.sucursal_id = current_sucursal_id()
     AND (p_fecha_desde IS NULL OR ncp.fecha >= p_fecha_desde)
     AND (p_fecha_hasta IS NULL OR ncp.fecha <= p_fecha_hasta)
     AND COALESCE(c.estado, '') <> 'cancelada';

  -- mig 291 (#941): una fila por compra.$n$, 'resumen compras · notas');
    v_def := pg_temp.parche(v_def,
$a$  SELECT r.total_compras, r.monto_total + v_transf,$a$,
$n$  SELECT r.total_compras, r.monto_total - v_nc + v_transf,$n$, 'resumen compras · total');
    EXECUTE v_def;
  END IF;
END
$tab$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos y el definer quedaron como en el repo, y ni anon ni PUBLIC ejecutan
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._ventas_nc(bigint[],date,date)', 'c44fdae60942de6e93649d62b2024d75', false,
     'srv', true),
    ('public._rubro_rotulo(text)', '97b8e5ab79612fb9bfb5cbc50753c4db', false,
     'srv', true),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)', '897606b426a2d8e14689f27302384020', true,
     'api', true),
    ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)', '91aa50518a1b78b336fe0b8dc3619da8', true,
     'api', true),
    ('public.reporte_ventas_por_preventista(date,date,bigint)', '25d693bf203e7d777f78fc5093819be9', true,
     'api', true),
    ('public.reporte_rentabilidad(date,date,bigint,text)', 'dbd84d097cf2b3492dc0ccd32b69241f', true,
     'api', true),
    ('public.rendimiento_preventistas(bigint,date)', 'bd3dcdc97f4bf07f325ecafb10f97a09', true,
     'api', true),
    ('public.reporte_stock_red(bigint)', '3cccdf0570ed67b04cd07d497673611a', true,
     'api', true),
    ('public.reporte_valuacion_inventario(bigint)', '129700895cefddd81162409e0915798a', true,
     'api', true),
    ('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', '6497eda578300c3ab8aff643e93a038f', true,
     'api', true),
    ('public.bot_compras_periodo(date,date,bigint,integer)', '87da9566b450098c9c84e1a097cdd8fe', true,
     'srv', true),
    ('public._tablero_cat_nombre(text)', 'd7281ee690da86b96dcddc6c81d07182', false,
     'api', false),
    ('public.tablero_categorias(bigint,date,date,bigint)', 'ff95226d41f6cb1cbc12aaf6c506e204', true,
     'api', false),
    ('public.tablero_facturacion_mensual(bigint,integer)', '011430a8f97513e16b70a7917e96be0c', true,
     'api', false),
    ('public.tablero_top_clientes_zona(bigint,date,date,integer,integer)', '25516e9ac10f66147d5abfab9b306b95', true,
     'api', false),
    ('public.tablero_cobertura(bigint,date)', 'c77e1688c6850c805997518be1358355', true,
     'api', false),
    ('public.tablero_kpis(bigint,integer)', 'a785ea05ff43673c80ee702470770030', true,
     'api', false),
    ('public.tablero_productos_categoria(uuid,text,bigint,date,date,bigint)', '871cd9ee553c8245bc3e7ff6783ac065', true,
     'api', false),
    ('public.tablero_ficha_cliente(bigint)', '246ffba5873618b8e74686337e110b8b', true,
     'api', false),
    ('public.obtener_resumen_compras(date,date)', '125537d681fe1a42efef4701617077ec', true,
     'api', false)
  ) AS t(f, h, def, acl, obligatoria) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      IF r.obligatoria THEN
        RAISE EXCEPTION 'mig NNN · % no existe al final', r.f;
      END IF;
      CONTINUE;
    END IF;
    -- El cuerpo y el definer, exactos. De los EXECUTE, lo que importa: ni anon ni
    -- PUBLIC; las de server ('srv'), tampoco authenticated. Que authenticated tenga
    -- EXECUTE en las de la API no se exige: B9 (SEG-3) puede habérselo sacado.
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def,
           has_function_privilege('anon', oid, 'EXECUTE') AS anon,
           has_function_privilege('authenticated', oid, 'EXECUTE') AS auth,
           EXISTS (SELECT 1 FROM aclexplode(COALESCE(proacl, acldefault('f', proowner))) e
                    WHERE e.grantee = 0) AS publico
      INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.def IS DISTINCT FROM r.def OR x.anon OR x.publico
       OR (r.acl = 'srv' AND x.auth) THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
