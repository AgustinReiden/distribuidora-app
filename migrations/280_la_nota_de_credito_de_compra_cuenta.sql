-- =========================================================================
-- mig 280 · LA NOTA DE CREDITO DE COMPRA CUENTA (#867)
--
-- Hasta aca `registrar_nota_credito` guardaba subtotal, IVA y total de la nota
-- y nada mas los miraba: `posicion_fiscal` seguia contando el IVA de la
-- factura entera como credito, el impuesto interno de la mercaderia devuelta
-- seguia contado como pagado, y un descuento del proveedor sin mercaderia de
-- por medio (precio mal facturado, II mal liquidado) no tenia donde vivir.
--
-- Decisiones del dueño:
--
--   a) posicion_fiscal RESTA el IVA de las notas de credito de compra, por la
--      FECHA DE LA NOTA (el periodo en que el proveedor la emite), de la misma
--      sucursal y con la compra no cancelada. Solo FC: una compra ZZ no tiene
--      IVA que acreditar, asi que su nota tampoco tiene IVA que restar.
--      `iva_credito` pasa a ser NETO de notas; el bruto se recupera sumando
--      `iva_notas_credito`, que se expone aparte. Las claves viejas siguen.
--
--   b) Una nota POR MERCADERIA DEVUELTA (con items) calcula y guarda el II de
--      esas lineas en `notas_credito.impuestos_internos`, y posicion_fiscal lo
--      resta de `ii_compras` (que suma todas las compras, como siempre).
--
--      COMO SE CALCULA EL II (helper `ii_nota_credito_compra`):
--        `compra_items.impuestos_internos` es la TASA efectiva de la linea y
--        `compra_items.subtotal` su neto bonificado. Σ subtotal × tasa/100 no
--        da exacto `compras.impuestos_internos`: la cabecera es lo que la
--        factura liquido (con el `ii_declarado` de la mig 277 o el redondeo de
--        cada renglon), y en las compras viejas la cabecera tiene II sin que
--        ninguna linea tenga tasa. Por eso la nota NO multiplica la tasa por
--        su cuenta: reparte la CABECERA en proporcion al II teorico de lo
--        devuelto:
--
--          II nota = II cabecera × Σ_prod (devuelto/comprado × II teorico prod)
--                                / Σ_todas II teorico
--
--        que es exactamente "neto bonificado × cantidad × tasa × factor del
--        motor", con factor = cabecera / Σ teorico. Devolver todo devuelve la
--        cabecera entera, al centavo. Si ninguna linea tiene tasa pero la
--        cabecera tiene II (compras anteriores a las tasas por linea), el
--        reparto es por neto: es la unica informacion que hay.
--        El espejo en TS es `calcularIINotaCredito` (src/utils/notaCredito.ts)
--        y solo sirve para la vista previa: lo que se guarda lo calcula la base.
--
--   c) Una nota SIN MERCADERIA (sin items) es un AJUSTE: descuento, diferencia
--      de precio, II mal liquidado. `notas_credito.tipo` se DERIVA (con items
--      -> 'devolucion', sin items -> 'ajuste'); nunca lo manda el caller. No
--      toca stock, costos, promedio ni fichas. En `reporte_gerencial` aparece
--      como `descuentos_proveedores` en el mes de la nota, y SUMA a todos los
--      margenes de los kpis y al `margen_real` mensual (resta del lado del
--      costo). `cmv` queda como estaba —costo de lo vendido a promedio— para
--      que el desglose siga cerrando: margen = venta − cmv + descuentos.
--        FC: subtotal (neto) + II que acredita.   ZZ: el total.
--      Los margenes por vendedor, categoria y producto NO lo llevan: un
--      descuento del proveedor sobre una factura no es atribuible a una venta.
--
-- FIRMA: `registrar_nota_credito` gana `p_impuestos_internos` (al final, con
-- DEFAULT NULL). Se crea la nueva desde el cuerpo VIVO y se DROPEA la vieja en
-- esta misma migracion (PGRST203). El front de produccion que todavia no tiene
-- este cambio manda los 8 parametros viejos por nombre y sigue resolviendo a la
-- nueva por el DEFAULT. En una devolucion el II lo pone la base: el total
-- guardado es `p_total − p_impuestos_internos + II calculado`, asi que con el
-- front viejo (que no manda II) el total queda bien igual.
--
-- `fecha` de la nota en hora argentina, como ya hacia `registrar_nota_credito_lote`
-- (mig 182/253): ahora la fecha decide el periodo fiscal, y CURRENT_DATE en UTC
-- fecha al dia siguiente despues de las 21:00.
--
-- `registrar_nota_credito_lote` (la otra puerta de una devolucion) calcula el
-- mismo II con el mismo helper y lo suma al total.
--
-- Backfill: las notas existentes sin items quedan 'ajuste'. En prod hay una
-- (id 1, compra 40, abril 2026): entra a descuentos_proveedores de abril y su
-- IVA sale del credito fiscal de abril. El II de las devoluciones existentes no
-- se recalcula: se verifica que ninguna cuelgue de una compra con II.
--
-- auditoria_integridad(): sin checks nuevos.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 0 · Helpers de cirugia sobre el cuerpo vivo (mismo contrato que _mig278_ancla)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig280_sustituir(p_def text, p_ancla text, p_nuevo text)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_veces int;
BEGIN
  v_veces := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, left(p_ancla, 120);
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END;
$fn$;

CREATE OR REPLACE FUNCTION public._mig280_ancla(p_funcion regprocedure, p_ancla text, p_nuevo text)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  EXECUTE public._mig280_sustituir(pg_get_functiondef(p_funcion), p_ancla, p_nuevo);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · Columnas nuevas de notas_credito
-- -------------------------------------------------------------------------
ALTER TABLE public.notas_credito
  ADD COLUMN impuestos_internos numeric NOT NULL DEFAULT 0
    CONSTRAINT notas_credito_ii_no_negativo CHECK (impuestos_internos >= 0),
  ADD COLUMN tipo text NOT NULL DEFAULT 'devolucion'
    CONSTRAINT notas_credito_tipo_check CHECK (tipo IN ('devolucion', 'ajuste'));

COMMENT ON COLUMN public.notas_credito.impuestos_internos IS
  'II que acredita la nota. Devolucion: lo calcula ii_nota_credito_compra sobre la cabecera de la compra. Ajuste: lo declara quien la carga. mig 280 (#867).';
COMMENT ON COLUMN public.notas_credito.tipo IS
  'devolucion = con items (baja stock); ajuste = sin mercaderia (descuento, precio, II). Lo deriva registrar_nota_credito. mig 280 (#867).';

UPDATE public.notas_credito nc
   SET tipo = 'ajuste'
 WHERE NOT EXISTS (SELECT 1 FROM public.nota_credito_items i
                    WHERE i.nota_credito_id = nc.id AND i.sucursal_id = nc.sucursal_id);

DO $guarda$
DECLARE
  v_n integer;
BEGIN
  -- Si alguna devolucion vieja cuelga de una compra con II, su II quedaria en 0
  -- y la posicion fiscal lo seguiria contando: hay que recalcularla a mano.
  SELECT count(*) INTO v_n
    FROM public.notas_credito nc
    JOIN public.compras c ON c.id = nc.compra_id AND c.sucursal_id = nc.sucursal_id
   WHERE nc.tipo = 'devolucion' AND COALESCE(c.impuestos_internos, 0) > 0;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'Hay % nota(s) de devolucion sobre compras con II: backfillear su impuestos_internos antes de aplicar', v_n;
  END IF;
END
$guarda$;

-- -------------------------------------------------------------------------
-- 2 · El II de una devolucion
--
-- Solo lo llaman las dos RPCs de nota de credito (SECURITY DEFINER), asi que no
-- necesita EXECUTE para nadie mas: se revoca a las tres (CLAUDE.md).
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ii_nota_credito_compra(
  p_compra_id   bigint,
  p_sucursal_id bigint,
  p_items       jsonb
) RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  WITH cab AS (
    SELECT COALESCE(c.impuestos_internos, 0) AS ii
      FROM compras c
     WHERE c.id = p_compra_id AND c.sucursal_id = p_sucursal_id
  ),
  lin AS (
    SELECT ci.producto_id,
           SUM(ci.cantidad)::numeric                                       AS comprado,
           SUM(ci.subtotal * COALESCE(ci.impuestos_internos, 0) / 100)     AS ii_teorico,
           SUM(ci.subtotal)                                                AS neto
      FROM compra_items ci
     WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = p_sucursal_id
     GROUP BY ci.producto_id
  ),
  tot AS (SELECT SUM(ii_teorico) AS ii_teorico, SUM(neto) AS neto FROM lin),
  dev AS (
    SELECT (i->>'producto_id')::bigint AS producto_id,
           SUM((i->>'cantidad')::numeric) AS cantidad
      FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) i
     GROUP BY 1
  ),
  prop AS (
    SELECT SUM(LEAST(d.cantidad, l.comprado) / l.comprado * l.ii_teorico) AS ii_teorico,
           SUM(LEAST(d.cantidad, l.comprado) / l.comprado * l.neto)       AS neto
      FROM dev d JOIN lin l ON l.producto_id = d.producto_id
     WHERE l.comprado > 0 AND d.cantidad > 0
  )
  SELECT COALESCE(round(
           CASE WHEN cab.ii <= 0 THEN 0
                WHEN tot.ii_teorico > 0 THEN cab.ii * COALESCE(prop.ii_teorico, 0) / tot.ii_teorico
                WHEN tot.neto > 0       THEN cab.ii * COALESCE(prop.neto, 0) / tot.neto
                ELSE 0 END, 2), 0)
    FROM cab, tot, prop;
$fn$;

COMMENT ON FUNCTION public.ii_nota_credito_compra(bigint, bigint, jsonb) IS
  'II de una nota de credito por devolucion: reparte compras.impuestos_internos en proporcion al II teorico (subtotal x tasa) de lo devuelto; por neto si ninguna linea tiene tasa. mig 280 (#867).';

REVOKE EXECUTE ON FUNCTION public.ii_nota_credito_compra(bigint, bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ii_nota_credito_compra(bigint, bigint, jsonb) TO service_role;

-- -------------------------------------------------------------------------
-- 3 · registrar_nota_credito: tipo derivado, II, ajuste sin mercaderia.
--     Cambia la firma (+ p_impuestos_internos): nueva desde el cuerpo vivo,
--     DROP de la vieja.
-- -------------------------------------------------------------------------
DO $rnc$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb)'::regprocedure);
BEGIN
  v_def := public._mig280_sustituir(v_def,
    $a$p_items jsonb DEFAULT '[]'::jsonb)$a$,
    $n$p_items jsonb DEFAULT '[]'::jsonb, p_impuestos_internos numeric DEFAULT NULL::numeric)$n$);

  v_def := public._mig280_sustituir(v_def,
    E'  v_exceso TEXT;  -- mig 236\n',
    E'  v_exceso TEXT;  -- mig 236\n  v_tipo TEXT; v_ii NUMERIC; v_total NUMERIC;  -- mig 280\n');

  v_def := public._mig280_sustituir(v_def,
    $a$  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id)
  VALUES (p_compra_id, p_numero_nota, CURRENT_DATE, p_subtotal, p_iva, p_total, p_motivo, p_usuario_id, v_sucursal)
  RETURNING id INTO v_nota_id;$a$,
    $n$  /* mig 280 (#867) · DEVOLUCION O AJUSTE.

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
          p_subtotal, p_iva, v_total, p_motivo, p_usuario_id, v_sucursal,
          v_ii, v_tipo)
  RETURNING id INTO v_nota_id;$n$);

  v_def := public._mig280_sustituir(v_def,
    $a$RETURN jsonb_build_object('success', true, 'nota_credito_id', v_nota_id);$a$,
    $n$RETURN jsonb_build_object('success', true, 'nota_credito_id', v_nota_id,
                            'tipo', v_tipo, 'impuestos_internos', v_ii, 'total', v_total);$n$);

  DROP FUNCTION public.registrar_nota_credito(bigint, character varying, text, numeric, numeric, numeric, uuid, jsonb);
  EXECUTE v_def;
END
$rnc$;

REVOKE EXECUTE ON FUNCTION public.registrar_nota_credito(bigint, character varying, text, numeric, numeric, numeric, uuid, jsonb, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_nota_credito(bigint, character varying, text, numeric, numeric, numeric, uuid, jsonb, numeric) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 4 · registrar_nota_credito_lote: el mismo II, sumado al total
-- -------------------------------------------------------------------------
SELECT public._mig280_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
  E'  v_nota_id    bigint;\nBEGIN',
  E'  v_nota_id    bigint;\n  v_ii         numeric;  -- mig 280\nBEGIN');

SELECT public._mig280_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
  E'  v_iva      := round(v_subtotal * v_tasa_iva / 100, 2);\n',
  E'  v_iva      := round(v_subtotal * v_tasa_iva / 100, 2);\n'
  || E'  -- mig 280 (#867): el II de lo devuelto, con el mismo reparto que la nota\n'
  || E'  -- por factura entera (ii_nota_credito_compra).\n'
  || E'  v_ii       := public.ii_nota_credito_compra(v_lote.compra_id, v_sucursal,\n'
  || E'                  jsonb_build_array(jsonb_build_object(''producto_id'', v_lote.producto_id, ''cantidad'', v_cant)));\n');

SELECT public._mig280_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
  E'    compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id\n  ) VALUES (',
  E'    compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id,\n    impuestos_internos, tipo\n  ) VALUES (');

SELECT public._mig280_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
  E'    v_subtotal, v_iva, v_subtotal + v_iva,\n',
  E'    v_subtotal, v_iva, v_subtotal + v_iva + v_ii,\n');

SELECT public._mig280_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
  E'    auth.uid(), v_sucursal\n  )\n  RETURNING id INTO v_nota_id;',
  E'    auth.uid(), v_sucursal,\n    v_ii, ''devolucion''\n  )\n  RETURNING id INTO v_nota_id;');

SELECT public._mig280_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
  E'    ''total'',             v_subtotal + v_iva\n  );',
  E'    ''impuestos_internos'', v_ii,\n    ''total'',             v_subtotal + v_iva + v_ii\n  );');

-- -------------------------------------------------------------------------
-- 5 · posicion_fiscal: IVA e II netos de notas de credito
-- -------------------------------------------------------------------------
SELECT public._mig280_ancla('public.posicion_fiscal(bigint,date,date)'::regprocedure,
  E'  compras_k AS (\n',
  E'  -- mig 280 (#867): notas de credito de compra por la fecha de la NOTA.\n'
  || E'  -- IVA solo de compras FC (una ZZ no tiene IVA que acreditar); el II de\n'
  || E'  -- todas, igual que ii_compras.\n'
  || E'  nc_k AS (\n'
  || E'    SELECT COALESCE(SUM(nc.iva) FILTER (WHERE COALESCE(c.tipo_factura, ''FC'') = ''FC''), 0) AS iva_nc,\n'
  || E'           COALESCE(SUM(nc.impuestos_internos), 0) AS ii_nc\n'
  || E'    FROM notas_credito nc\n'
  || E'    JOIN compras c ON c.id = nc.compra_id AND c.sucursal_id = nc.sucursal_id\n'
  || E'    WHERE nc.sucursal_id = ANY(v_sucursales)\n'
  || E'      AND nc.fecha BETWEEN p_desde AND p_hasta\n'
  || E'      AND COALESCE(c.estado, '''') <> ''cancelada''\n'
  || E'  ),\n'
  || E'  compras_k AS (\n');

SELECT public._mig280_ancla('public.posicion_fiscal(bigint,date,date)'::regprocedure,
  E'           COALESCE(SUM(iva), 0) AS iva_credito,\n',
  E'           COALESCE(SUM(iva), 0) - (SELECT iva_nc FROM nc_k) AS iva_credito,\n');

SELECT public._mig280_ancla('public.posicion_fiscal(bigint,date,date)'::regprocedure,
  E'           COALESCE(SUM(impuestos_internos), 0) AS ii_compras,\n',
  E'           COALESCE(SUM(impuestos_internos), 0) - (SELECT ii_nc FROM nc_k) AS ii_compras,\n');

SELECT public._mig280_ancla('public.posicion_fiscal(bigint,date,date)'::regprocedure,
  E'        ''iva_credito'', c.iva_credito, ''ii_compras'', c.ii_compras,\n',
  E'        ''iva_credito'', c.iva_credito, ''ii_compras'', c.ii_compras,\n'
  || E'        ''iva_notas_credito'', (SELECT iva_nc FROM nc_k), ''ii_notas_credito'', (SELECT ii_nc FROM nc_k),\n');

-- -------------------------------------------------------------------------
-- 6 · reporte_gerencial: descuentos de proveedores
-- -------------------------------------------------------------------------
SELECT public._mig280_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  E'  k_nuevos AS (SELECT COUNT(*) AS nuevos FROM (',
  E'  -- mig 280 (#867): notas de credito de compra SIN mercaderia (descuentos,\n'
  || E'  -- diferencias de precio, II mal liquidado), en el mes de la nota. Restan\n'
  || E'  -- del lado del costo: suman a los margenes, no tocan cmv.\n'
  || E'  --   FC: neto + II que acredita (el IVA es credito fiscal, no costo).\n'
  || E'  --   ZZ: el total (en ZZ lo pagado ya es el costo final).\n'
  || E'  desc_nc AS (\n'
  || E'    SELECT nc.fecha,\n'
  || E'           CASE WHEN COALESCE(c.tipo_factura, ''FC'') = ''ZZ'' THEN nc.total\n'
  || E'                ELSE nc.subtotal + nc.impuestos_internos END AS monto\n'
  || E'    FROM notas_credito nc\n'
  || E'    JOIN compras c ON c.id = nc.compra_id AND c.sucursal_id = nc.sucursal_id\n'
  || E'    WHERE nc.tipo = ''ajuste'' AND nc.sucursal_id = ANY(v_sucursales)\n'
  || E'      AND nc.fecha BETWEEN p_desde AND p_hasta\n'
  || E'      AND COALESCE(c.estado, '''') <> ''cancelada''\n'
  || E'  ),\n'
  || E'  k_desc AS (SELECT COALESCE(SUM(monto), 0) AS descuentos FROM desc_nc),\n'
  || E'  m_desc AS (SELECT to_char(fecha, ''YYYY-MM'') AS mes, SUM(monto) AS descuentos FROM desc_nc GROUP BY 1),\n'
  || E'  k_nuevos AS (SELECT COUNT(*) AS nuevos FROM (');

SELECT public._mig280_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  E'      (mp.venta_real - COALESCE(mi.cmv,0)) AS margen_real,\n',
  E'      (mp.venta_real - COALESCE(mi.cmv,0) + COALESCE(md.descuentos,0)) AS margen_real,\n'
  || E'      COALESCE(md.descuentos,0) AS descuentos_proveedores,\n');

SELECT public._mig280_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  'LEFT JOIN m_compra mc ON mc.mes=mp.mes),',
  'LEFT JOIN m_compra mc ON mc.mes=mp.mes LEFT JOIN m_desc md ON md.mes=mp.mes),');

SELECT public._mig280_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  E'''margen_comercial'', kp.venta - ki.cmv,\n        ''margen_neto'', kp.venta - ki.cmv - ki.bonif,',
  E'''margen_comercial'', kp.venta - ki.cmv + kd.descuentos,\n        ''margen_neto'', kp.venta - ki.cmv - ki.bonif + kd.descuentos,');

SELECT public._mig280_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  '''margen_comercial_neto'', kp.venta_neta - ki.cmv,',
  '''margen_comercial_neto'', kp.venta_neta - ki.cmv + kd.descuentos,');

SELECT public._mig280_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  '''margen_real'', kp.venta_real - ki.cmv,',
  '''margen_real'', kp.venta_real - ki.cmv + kd.descuentos,');

SELECT public._mig280_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  '''margen_real_neto'', kp.venta_real - ki.cmv - ki.bonif,',
  '''margen_real_neto'', kp.venta_real - ki.cmv - ki.bonif + kd.descuentos,'
  || E'\n        ''descuentos_proveedores'', kd.descuentos,');

SELECT public._mig280_ancla('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  'FROM k_ped kp, k_it ki, k_nc kc, k_merma km, k_compra kcp, k_nuevos kn),',
  'FROM k_ped kp, k_it ki, k_nc kc, k_merma km, k_compra kcp, k_nuevos kn, k_desc kd),');

DROP FUNCTION public._mig280_ancla(regprocedure, text, text);
DROP FUNCTION public._mig280_sustituir(text, text, text);

-- -------------------------------------------------------------------------
-- 7 · Verificacion. Si algo de esto falla, no se aplica nada.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n   integer;
  v_def text;
BEGIN
  -- Una sola firma de registrar_nota_credito, la nueva (PGRST203).
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname = 'public' AND p.proname = 'registrar_nota_credito';
  IF v_n <> 1 THEN RAISE EXCEPTION 'Hay % firmas de registrar_nota_credito (se esperaba 1)', v_n; END IF;
  IF to_regprocedure('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)') IS NULL THEN
    RAISE EXCEPTION 'No quedo la firma nueva de registrar_nota_credito';
  END IF;

  -- Permisos: la RPC para authenticated y no para anon; el helper para nadie.
  IF has_function_privilege('anon', 'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.ii_nota_credito_compra(bigint,bigint,jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.ii_nota_credito_compra(bigint,bigint,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Permisos de registrar_nota_credito / ii_nota_credito_compra mal puestos';
  END IF;

  -- La RPC nueva conserva los guardas del cuerpo vivo.
  v_def := pg_get_functiondef('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure);
  IF v_def NOT LIKE '%es_encargado_o_admin()%' OR v_def NOT LIKE '%FOR UPDATE%'
     OR v_def NOT LIKE '%ii_nota_credito_compra%' OR v_def NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'registrar_nota_credito perdio un guarda o no calcula el II';
  END IF;

  v_def := pg_get_functiondef('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure);
  IF v_def NOT LIKE '%ii_nota_credito_compra%' OR v_def NOT LIKE '%v_subtotal + v_iva + v_ii%' THEN
    RAISE EXCEPTION 'registrar_nota_credito_lote no calcula el II';
  END IF;

  v_def := pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure);
  IF v_def NOT LIKE '%iva_notas_credito%' OR v_def NOT LIKE '%(SELECT ii_nc FROM nc_k) AS ii_compras%' THEN
    RAISE EXCEPTION 'posicion_fiscal no resta las notas de credito';
  END IF;

  v_def := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  IF v_def NOT LIKE '%''descuentos_proveedores'', kd.descuentos%' OR v_def NOT LIKE '%LEFT JOIN m_desc md%' THEN
    RAISE EXCEPTION 'reporte_gerencial no expone descuentos_proveedores';
  END IF;

  -- Toda nota quedo con tipo coherente con sus items.
  SELECT count(*) INTO v_n FROM public.notas_credito nc
   WHERE (nc.tipo = 'ajuste') = EXISTS (SELECT 1 FROM public.nota_credito_items i
                                         WHERE i.nota_credito_id = nc.id AND i.sucursal_id = nc.sucursal_id);
  IF v_n > 0 THEN RAISE EXCEPTION '% nota(s) con tipo incoherente con sus items', v_n; END IF;
END
$verif$;

COMMIT;
