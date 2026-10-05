-- =========================================================================
-- mig 281 · EL IVA DEL FLETE CON FACTURA ES CREDITO FISCAL (#866)
--
-- El flete lo cobra un transportista aparte, a veces con factura (con IVA) y a
-- veces sin. Desde el rediseño de carga entra al costo como cargo de la compra
-- (`compra_cargos`), pero su IVA no vivia en ningun lado: `posicion_fiscal`
-- solo lee `compras.iva`, y un cargo gravado con `en_factura = false` (no viene
-- en el papel del proveedor) no genera IVA en el motor: su monto es costo neto.
--
-- Decision del dueño: el IVA vive ADENTRO del cargo y toma la fecha de la
-- compra para la posicion fiscal. Nada de compra ni gasto aparte.
--
--   compra_cargos.comprobante_tercero  boolean NOT NULL DEFAULT false
--   compra_cargos.iva_monto            numeric(12,2)
--   compra_cargos.tercero_nombre       text   (el transportista)
--   compra_cargos.tercero_comprobante  text   (N° de la factura del transportista)
--
-- Solo tiene sentido para un cargo GRAVADO que NO viene en la factura del
-- proveedor: si viene en el papel, su IVA ya esta en `compras.iva`. Los CHECKs
-- lo dicen, y la normalizacion de las RPCs deja todo en false/NULL cuando la
-- combinacion no aplica (en vez de hacer fallar la compra).
--
-- EL MOTOR DE COSTOS NO CAMBIA: el monto sigue siendo neto y el IVA es credito
-- fiscal, no costo. Las claves nuevas viajan dentro de cada elemento de
-- p_cargos (como concepto_id/medida_id en la 278): NINGUNA firma cambia.
--
-- posicion_fiscal suma el IVA de esos cargos como `iva_fletes`, por la FECHA DE
-- LA COMPRA, de compras no canceladas, y lo incluye en `iva_credito`. Sin mirar
-- `tipo_factura`: la factura del transportista es independiente de la del
-- proveedor, y una compra ZZ puede traer un flete con factura A.
--
-- PARCHE POR ANCLA sobre el cuerpo vivo (como la 277/278/280). Esta migracion
-- va DESPUES de la 280: el ancla de posicion_fiscal es el `nc_k` que agrega
-- esa.
--
-- auditoria_integridad(): sin checks nuevos.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._mig281_ancla(p_funcion regprocedure, p_ancla text, p_nuevo text)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · Columnas y CHECKs
-- -------------------------------------------------------------------------
ALTER TABLE public.compra_cargos
  ADD COLUMN comprobante_tercero boolean NOT NULL DEFAULT false,
  ADD COLUMN iva_monto numeric(12,2),
  ADD COLUMN tercero_nombre text,
  ADD COLUMN tercero_comprobante text,
  ADD CONSTRAINT compra_cargos_iva_monto_no_negativo CHECK (iva_monto >= 0),
  -- La factura del transportista solo existe para un cargo gravado que no viene
  -- en el papel del proveedor.
  ADD CONSTRAINT compra_cargos_tercero_coherente CHECK (
    NOT comprobante_tercero OR (NOT en_factura AND condicion_iva = 'gravado')),
  ADD CONSTRAINT compra_cargos_iva_monto_solo_tercero CHECK (
    iva_monto IS NULL OR (comprobante_tercero AND NOT en_factura AND condicion_iva = 'gravado')),
  ADD CONSTRAINT compra_cargos_tercero_datos_solo_tercero CHECK (
    comprobante_tercero OR (tercero_nombre IS NULL AND tercero_comprobante IS NULL));

COMMENT ON COLUMN public.compra_cargos.comprobante_tercero IS
  'El cargo (gravado, fuera de la factura del proveedor) viene con factura propia de un tercero, tipicamente el transportista. mig 281 (#866).';
COMMENT ON COLUMN public.compra_cargos.iva_monto IS
  'IVA de la factura del tercero. Es credito fiscal (posicion_fiscal.iva_fletes, por la fecha de la compra), no costo: el monto del cargo sigue siendo neto. mig 281 (#866).';

-- -------------------------------------------------------------------------
-- 2 · Las tres RPCs de compra leen, guardan y clonan las claves nuevas
-- -------------------------------------------------------------------------
DO $rpcs$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)',
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'
  ] LOOP
    -- 2.a · Validacion: comprobante_tercero booleano, iva_monto numero >= 0.
    PERFORM public._mig281_ancla(v_fn::regprocedure,
      $a$        OR jsonb_typeof(COALESCE(NULLIF(c.val->'afecta_base_ii',     'null'::JSONB), 'false'::JSONB)) <> 'boolean'$a$,
      $n$        OR jsonb_typeof(COALESCE(NULLIF(c.val->'afecta_base_ii',     'null'::JSONB), 'false'::JSONB)) <> 'boolean'
        -- mig 281
        OR jsonb_typeof(COALESCE(NULLIF(c.val->'comprobante_tercero', 'null'::JSONB), 'false'::JSONB)) <> 'boolean'
        OR jsonb_typeof(COALESCE(NULLIF(c.val->'iva_monto', 'null'::JSONB), '0'::JSONB)) <> 'number'
        OR CASE WHEN jsonb_typeof(c.val->'iva_monto') = 'number'
                THEN (c.val->>'iva_monto')::NUMERIC < 0 ELSE false END$n$);

    PERFORM public._mig281_ancla(v_fn::regprocedure,
      $a$                ELSE 'tiene en_factura, prorratea_al_costo o afecta_base_ii con un valor que no es booleano'$a$,
      $n$                WHEN jsonb_typeof(COALESCE(NULLIF(c.val->'iva_monto', 'null'::JSONB), '0'::JSONB)) <> 'number'
                  THEN 'tiene un iva_monto que no es un numero'
                WHEN jsonb_typeof(c.val->'iva_monto') = 'number' AND (c.val->>'iva_monto')::NUMERIC < 0
                  THEN 'tiene un iva_monto negativo'
                ELSE 'tiene en_factura, prorratea_al_costo, afecta_base_ii o comprobante_tercero con un valor que no es booleano'$n$);

    -- 2.b · Normalizacion: solo un cargo gravado fuera de la factura del
    --       proveedor puede traer comprobante de tercero. Si la combinacion no
    --       aplica, todo queda en false/NULL (no se rechaza la compra).
    PERFORM public._mig281_ancla(v_fn::regprocedure,
      $a$             'medida_id',          (SELECT cme.id FROM cargo_medidas cme$a$,
      $n$             'comprobante_tercero', t3.es,
             'iva_monto',           CASE WHEN t3.es THEN round((c.val->>'iva_monto')::NUMERIC, 2) END,
             'tercero_nombre',      CASE WHEN t3.es THEN NULLIF(btrim(c.val->>'tercero_nombre'), '') END,
             'tercero_comprobante', CASE WHEN t3.es THEN NULLIF(btrim(c.val->>'tercero_comprobante'), '') END,
             'medida_id',          (SELECT cme.id FROM cargo_medidas cme$n$);

    -- 2.c · INSERT: columnas y valores (desde v_cargos, ya normalizado).
    PERFORM public._mig281_ancla(v_fn::regprocedure,
      E'prorratea_al_costo, afecta_base_ii, base_prorrateo, concepto_id, medida_id\n',
      E'prorratea_al_costo, afecta_base_ii, base_prorrateo, concepto_id, medida_id,\n'
      || E'        comprobante_tercero, iva_monto, tercero_nombre, tercero_comprobante\n');
    PERFORM public._mig281_ancla(v_fn::regprocedure,
      E'(c.val->>''medida_id'')::BIGINT\n',
      E'(c.val->>''medida_id'')::BIGINT,\n'
      || E'             COALESCE((c.val->>''comprobante_tercero'')::BOOLEAN, false),\n'
      || E'             (c.val->>''iva_monto'')::NUMERIC,\n'
      || E'             c.val->>''tercero_nombre'',\n'
      || E'             c.val->>''tercero_comprobante''\n');
  END LOOP;
END
$rpcs$;

-- 2.d · El `t3.es` de la normalizacion: un LATERAL en el FROM de la consulta
-- que arma v_cargos (la misma en las dos RPCs; el FROM sobre p_cargos aparece
-- dos veces en cada una, por eso el ancla incluye el `INTO v_cargos`).
DO $from$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)',
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'
  ] LOOP
    PERFORM public._mig281_ancla(v_fn::regprocedure,
      E'      INTO v_cargos\n      FROM jsonb_array_elements(p_cargos) WITH ORDINALITY AS c(val, ord);',
      E'      INTO v_cargos\n      FROM jsonb_array_elements(p_cargos) WITH ORDINALITY AS c(val, ord)\n'
      || E'      -- mig 281: ¿el cargo trae factura propia de un tercero (transportista)?\n'
      || E'      CROSS JOIN LATERAL (SELECT (NOT COALESCE((c.val->>''en_factura'')::BOOLEAN, true)\n'
      || E'                                  AND COALESCE(c.val->>''condicion_iva'', ''no_gravado'') = ''gravado''\n'
      || E'                                  AND COALESCE((c.val->>''comprobante_tercero'')::BOOLEAN, false)) AS es) t3;');
  END LOOP;
END
$from$;

-- 2.e · cambiar_proveedor_compra: el clon lleva los datos del tercero.
SELECT public._mig281_ancla(
  'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure,
  E'prorratea_al_costo, afecta_base_ii, base_prorrateo, concepto_id, medida_id\n',
  E'prorratea_al_costo, afecta_base_ii, base_prorrateo, concepto_id, medida_id,\n'
  || E'      comprobante_tercero, iva_monto, tercero_nombre, tercero_comprobante\n');
SELECT public._mig281_ancla(
  'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure,
  E'v_cargo.afecta_base_ii, v_cargo.base_prorrateo, v_cargo.concepto_id, v_cargo.medida_id\n',
  E'v_cargo.afecta_base_ii, v_cargo.base_prorrateo, v_cargo.concepto_id, v_cargo.medida_id,\n'
  || E'      v_cargo.comprobante_tercero, v_cargo.iva_monto, v_cargo.tercero_nombre, v_cargo.tercero_comprobante\n');

-- -------------------------------------------------------------------------
-- 3 · posicion_fiscal: iva_fletes, dentro de iva_credito
-- -------------------------------------------------------------------------
SELECT public._mig281_ancla('public.posicion_fiscal(bigint,date,date)'::regprocedure,
  E'  compras_k AS (\n',
  E'  -- mig 281 (#866): IVA de cargos con factura de un tercero (el flete del\n'
  || E'  -- transportista), por la fecha de la COMPRA y sin mirar tipo_factura: la\n'
  || E'  -- factura del transportista no depende de la del proveedor.\n'
  || E'  fletes_k AS (\n'
  || E'    SELECT COALESCE(SUM(cc.iva_monto), 0) AS iva_fletes\n'
  || E'    FROM compra_cargos cc\n'
  || E'    JOIN compras c ON c.id = cc.compra_id AND c.sucursal_id = cc.sucursal_id\n'
  || E'    WHERE cc.comprobante_tercero\n'
  || E'      AND c.sucursal_id = ANY(v_sucursales)\n'
  || E'      AND c.fecha_compra BETWEEN p_desde AND p_hasta\n'
  || E'      AND COALESCE(c.estado, '''') <> ''cancelada''\n'
  || E'  ),\n'
  || E'  compras_k AS (\n');

SELECT public._mig281_ancla('public.posicion_fiscal(bigint,date,date)'::regprocedure,
  E'           COALESCE(SUM(iva), 0) - (SELECT iva_nc FROM nc_k) AS iva_credito,\n',
  E'           COALESCE(SUM(iva), 0) - (SELECT iva_nc FROM nc_k) + (SELECT iva_fletes FROM fletes_k) AS iva_credito,\n');

SELECT public._mig281_ancla('public.posicion_fiscal(bigint,date,date)'::regprocedure,
  E'        ''iva_notas_credito'', (SELECT iva_nc FROM nc_k),',
  E'        ''iva_fletes'', (SELECT iva_fletes FROM fletes_k),\n'
  || E'        ''iva_notas_credito'', (SELECT iva_nc FROM nc_k),');

DROP FUNCTION public._mig281_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 4 · Verificacion
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text;
  v_fn  text;
  v_n   integer;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)',
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'
  ] LOOP
    v_def := pg_get_functiondef(v_fn::regprocedure);
    IF v_def NOT LIKE '%''comprobante_tercero'', t3.es%'
       OR v_def NOT LIKE '%comprobante_tercero, iva_monto, tercero_nombre, tercero_comprobante%'
       OR v_def NOT LIKE '%AS es) t3%'
       OR v_def NOT LIKE '%tiene un iva_monto negativo%' THEN
      RAISE EXCEPTION '% no lee / guarda los datos del tercero', v_fn;
    END IF;
  END LOOP;

  v_def := pg_get_functiondef('public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure);
  IF v_def NOT LIKE '%v_cargo.comprobante_tercero, v_cargo.iva_monto, v_cargo.tercero_nombre, v_cargo.tercero_comprobante%' THEN
    RAISE EXCEPTION 'cambiar_proveedor_compra no copia los datos del tercero';
  END IF;

  v_def := pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure);
  IF v_def NOT LIKE '%+ (SELECT iva_fletes FROM fletes_k) AS iva_credito%' OR v_def NOT LIKE '%''iva_fletes''%' THEN
    RAISE EXCEPTION 'posicion_fiscal no suma iva_fletes';
  END IF;

  -- Ninguna firma cambio (PGRST203).
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname = 'public'
     AND p.proname IN ('registrar_compra_completa', 'actualizar_compra_items', 'cambiar_proveedor_compra', 'posicion_fiscal');
  IF v_n <> 4 THEN RAISE EXCEPTION 'Hay % firmas para las cuatro funciones (se esperaban 4)', v_n; END IF;

  -- Las filas existentes quedan sin tercero.
  SELECT count(*) INTO v_n FROM public.compra_cargos WHERE comprobante_tercero OR iva_monto IS NOT NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION '% cargo(s) quedaron con tercero sin que nadie lo cargue', v_n; END IF;
END
$verif$;

COMMIT;
