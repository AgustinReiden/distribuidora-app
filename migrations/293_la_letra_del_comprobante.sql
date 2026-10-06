-- =========================================================================
-- mig 293 · LA LETRA DEL COMPROBANTE DE COMPRA
--
-- Hasta aca una compra era FC (fiscal: IVA discriminado y computable, el costo
-- es el neto) o ZZ (informal: lo pagado es el costo, IVA e II adentro). Falta
-- la LETRA de la factura, y la letra cambia el costo. Decision del dueño:
--
--   Letra        tipo_factura  IVA                 Costo
--   A            FC            credito fiscal      neto
--   M            FC            credito fiscal      neto   (hay que retenerle IVA
--                                                          y Ganancias al pagar,
--                                                          RG 1575: es un aviso)
--   B            FC            NO computable       lo pagado (IVA adentro), como ZZ
--   C            FC            no tiene IVA        lo pagado
--   sin factura  ZZ            —                   lo pagado
--
-- B y C siguen siendo "con factura" (FC) para todo lo que cuenta comprobantes
-- (fc_compras, fc_total, pct_fc); para el COSTO y el IVA se comportan como ZZ.
--
--   compras.letra_comprobante  text NULL  CHECK IN ('A','B','C','M')
--   NULL con FC = A (legado). ZZ lleva NULL siempre (CHECK). Backfill: las FC
--   existentes pasan a 'A'; las ZZ quedan en NULL.
--
-- "IVA computable" = tipo_factura = 'FC' AND COALESCE(letra, 'A') IN ('A','M').
--
-- COMO SE APLICA: igual que la regla de ZZ, en el BORDE del motor y no adentro.
-- `calcular_costos_compra` no conoce el tipo de factura y no cambia: las RPCs
-- ponen la tasa de IVA y de II en 0 en las lineas que van al motor (y el IVA y
-- el II de cabecera en 0). En las RPCs eso era `v_es_zz`; ahora es
-- `v_sin_credito` (= ZZ o letra B/C). Lo que SIGUE mirando `v_es_zz` es lo que
-- es propio de la informalidad: percepciones, no gravado y bonificaciones de
-- cabecera, y el cuadre del total. Una factura B puede traer percepcion de IIBB.
--
-- Para A, M y ZZ `v_sin_credito` vale exactamente lo que valia `v_es_zz`: los
-- costos de las compras FC/ZZ son bit-identicos (verificado en el dry-run
-- recalculando las compras reales).
--
-- FIRMA: registrar_compra_completa gana `p_letra_comprobante text DEFAULT NULL`
-- al final. Ninguno de sus JSONB sirve para llevarla (p_items es por linea,
-- p_cargos es un array de cargos y p_ii_declarado un mapa tasa→monto que el
-- motor valida clave por clave). Se DROPEA la firma vieja en esta misma
-- migracion (PGRST203) y se re-otorga. Un front viejo que no manda la letra
-- resuelve a la firma nueva por el DEFAULT y carga la FC como A, que es lo que
-- hacia hasta hoy.
--
-- actualizar_compra_items NO cambia de firma: la letra no se edita (el cabezal
-- de la compra no se edita). Lee la guardada.
--
-- PARCHE POR ANCLA sobre el cuerpo vivo (como la 277/278/280/281): cada ancla
-- tiene que aparecer exactamente una vez o la migracion aborta.
--
--   registrar_compra_completa  firma, letra, v_sin_credito, INSERT, borde del motor
--   actualizar_compra_items    lee la letra, v_sin_credito, borde del motor
--   cambiar_proveedor_compra   el clon copia la letra
--   posicion_fiscal            el IVA de B/C (compra y NC) no es credito
--   reporte_gerencial          el ajuste de NC de una B/C vale su total, como ZZ
--   auditoria_integridad       COMPRA-B cubre tambien B/C con IVA
--
-- No cambian (verificado): calcular_costos_compra, costo_real_unitario,
-- costo_financiero_unitario (con IVA e II de linea en 0 dan lo pagado en las
-- dos ramas), anular_compra_atomica (recalcula con el IVA/II guardado en la
-- linea, que en B/C es 0), registrar_nota_credito_lote (IVA por la alicuota de
-- la linea, 0 en B/C), ii_nota_credito_compra (II de cabecera, 0 en B/C).
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._mig293_ancla(p_funcion regprocedure, p_ancla text, p_nuevo text)
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

-- Varios reemplazos sobre el MISMO cuerpo, aplicados en memoria y ejecutados
-- una sola vez. Hace falta para registrar_compra_completa: el primer reemplazo
-- cambia la firma, y despues de ejecutarlo hay DOS sobrecargas — los siguientes
-- tienen que ir sobre la nueva, no sobre la vieja.
CREATE OR REPLACE FUNCTION public._mig293_anclas(p_funcion regprocedure, p_pares text[])
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

-- -------------------------------------------------------------------------
-- 1 · La columna, sus CHECKs y el backfill
-- -------------------------------------------------------------------------
ALTER TABLE public.compras
  ADD COLUMN letra_comprobante text,
  ADD CONSTRAINT compras_letra_comprobante_check
    CHECK (letra_comprobante IN ('A', 'B', 'C', 'M')),
  -- Una compra sin factura no tiene letra.
  ADD CONSTRAINT compras_letra_solo_con_factura
    CHECK (letra_comprobante IS NULL OR tipo_factura = 'FC');

COMMENT ON COLUMN public.compras.letra_comprobante IS
  'Letra de la factura del proveedor (A, B, C o M). NULL con FC = A (legado); ZZ siempre NULL. B y C: el IVA no es credito fiscal y el costo es lo pagado, como ZZ. mig 293.';

-- Sin tocar updated_at ni llenar la auditoria con 80 filas que no son una
-- edicion de nadie: es la misma compra, ahora con el dato que faltaba.
ALTER TABLE public.compras DISABLE TRIGGER trigger_update_compras_timestamp;
ALTER TABLE public.compras DISABLE TRIGGER audit_compras;
UPDATE public.compras SET letra_comprobante = 'A' WHERE tipo_factura = 'FC';
ALTER TABLE public.compras ENABLE TRIGGER trigger_update_compras_timestamp;
ALTER TABLE public.compras ENABLE TRIGGER audit_compras;

-- -------------------------------------------------------------------------
-- 2 · registrar_compra_completa: firma nueva, letra y v_sin_credito
-- -------------------------------------------------------------------------
SELECT public._mig293_anclas(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  ARRAY[
    -- 2.a · la firma
    E'p_bonificaciones numeric DEFAULT 0)\n RETURNS jsonb',
    E'p_bonificaciones numeric DEFAULT 0, p_letra_comprobante text DEFAULT NULL::text)\n RETURNS jsonb',

    -- 2.b · las variables
    E'  v_es_zz               BOOLEAN;\n',
    E'  v_es_zz               BOOLEAN;\n'
    || E'  v_sin_credito         BOOLEAN;   -- mig 293: ZZ, o FC con letra B/C\n'
    || E'  v_letra               TEXT;      -- mig 293\n',

    -- 2.c · la letra se normaliza y valida antes de escribir nada; el IVA y el
    --       II de cabecera siguen a v_sin_credito
    E'  v_es_zz          := (v_tipo_factura = ''ZZ'');\n'
    || E'  v_iva_hdr        := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_iva, 0) END;\n'
    || E'  v_ii_hdr         := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_impuestos_internos, 0) END;\n',
    E'  v_es_zz          := (v_tipo_factura = ''ZZ'');\n'
    || E'  /* mig 293 · la letra. Sin letra, una FC es A (lo que era hasta hoy). */\n'
    || E'  v_letra          := NULLIF(upper(btrim(COALESCE(p_letra_comprobante, ''''))), '''');\n'
    || E'  IF v_es_zz AND v_letra IS NOT NULL THEN\n'
    || E'    RETURN jsonb_build_object(''success'', false, ''error'',\n'
    || E'      ''Una compra sin factura (ZZ) no lleva letra de comprobante'');\n'
    || E'  END IF;\n'
    || E'  IF NOT v_es_zz THEN\n'
    || E'    v_letra := COALESCE(v_letra, ''A'');\n'
    || E'    IF v_letra NOT IN (''A'', ''B'', ''C'', ''M'') THEN\n'
    || E'      RETURN jsonb_build_object(''success'', false, ''error'',\n'
    || E'        format(''Letra de comprobante invalida: %s. Se espera A, B, C o M.'', v_letra));\n'
    || E'    END IF;\n'
    || E'  END IF;\n'
    || E'  /* B y C: el IVA no es credito y el costo es lo pagado, como en ZZ. */\n'
    || E'  v_sin_credito    := v_es_zz OR v_letra IN (''B'', ''C'');\n'
    || E'  v_iva_hdr        := CASE WHEN v_sin_credito THEN 0 ELSE COALESCE(p_iva, 0) END;\n'
    || E'  v_ii_hdr         := CASE WHEN v_sin_credito THEN 0 ELSE COALESCE(p_impuestos_internos, 0) END;\n',

    -- 2.d · el INSERT guarda la letra
    E'    usuario_id, estado, tipo_factura, sucursal_id\n  ) VALUES (',
    E'    usuario_id, estado, tipo_factura, sucursal_id, letra_comprobante /* mig 293 */\n  ) VALUES (',
    E'    p_usuario_id, ''recibida'', v_tipo_factura, v_sucursal\n  )',
    E'    p_usuario_id, ''recibida'', v_tipo_factura, v_sucursal, v_letra\n  )',

    -- 2.e · el borde del motor y el loop de lineas: la regla de ZZ pasa a ser
    --       la de "sin credito"
    E'    WHEN v_es_zz THEN ''{}''::JSONB',
    E'    WHEN v_sin_credito THEN ''{}''::JSONB  /* mig 293 */',
    E'''impuestos_internos'', CASE WHEN v_es_zz THEN 0\n',
    E'''impuestos_internos'', CASE WHEN v_sin_credito THEN 0\n',
    E'''porcentaje_iva'',     CASE WHEN v_es_zz OR n.cond <> ''gravado'' THEN 0',
    E'''porcentaje_iva'',     CASE WHEN v_sin_credito OR n.cond <> ''gravado'' THEN 0',
    E'\n             WHEN v_es_zz THEN ''gravado''',
    E'\n             WHEN v_sin_credito THEN ''gravado''',
    E'\n      WHEN v_es_zz THEN ''gravado''',
    E'\n      WHEN v_sin_credito THEN ''gravado''',
    E'      WHEN v_es_zz OR v_condicion_iva <> ''gravado'' THEN 0',
    E'      WHEN v_sin_credito OR v_condicion_iva <> ''gravado'' THEN 0',
    E'    v_impuestos_internos := CASE WHEN v_es_zz THEN 0 ELSE',
    E'    v_impuestos_internos := CASE WHEN v_sin_credito THEN 0 ELSE',

    -- 2.f · las dos funciones de costo unitario reciben el regimen de costo
    E'costo_financiero_unitario(v_costo_neto, v_porcentaje_iva, v_impuestos_internos, v_tipo_factura)',
    E'costo_financiero_unitario(v_costo_neto, v_porcentaje_iva, v_impuestos_internos, CASE WHEN v_sin_credito THEN ''ZZ'' ELSE v_tipo_factura END)',
    E'costo_real_unitario(v_costo_neto, v_impuestos_internos, v_tipo_factura, 0',
    E'costo_real_unitario(v_costo_neto, v_impuestos_internos, CASE WHEN v_sin_credito THEN ''ZZ'' ELSE v_tipo_factura END, 0'
  ]
);

-- La firma vieja se va en la misma migracion: dos sobrecargas con rangos de
-- argumentos superpuestos son un PGRST203 en runtime.
DROP FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric);

REVOKE ALL ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 3 · actualizar_compra_items: lee la letra guardada (no se edita)
-- -------------------------------------------------------------------------
SELECT public._mig293_anclas(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  ARRAY[
    E'  v_es_zz BOOLEAN;\n',
    E'  v_es_zz BOOLEAN;\n  v_sin_credito BOOLEAN;  -- mig 293: ZZ, o FC con letra B/C\n',

    E'  SELECT id, estado, tipo_factura, created_at, fecha_compra, impuestos_internos, ii_declarado /* mig 194 */',
    E'  SELECT id, estado, tipo_factura, created_at, fecha_compra, impuestos_internos, ii_declarado /* mig 194 */,\n'
    || E'         letra_comprobante /* mig 293 */',

    E'  v_es_zz := (v_compra.tipo_factura = ''ZZ'');\n  v_iva_efectivo := CASE WHEN v_es_zz THEN 0 ELSE p_iva END;',
    E'  v_es_zz := (v_compra.tipo_factura = ''ZZ'');\n'
    || E'  /* mig 293 · B y C: el IVA no es credito y el costo es lo pagado, como en ZZ. */\n'
    || E'  v_sin_credito := v_es_zz OR COALESCE(v_compra.letra_comprobante, ''A'') IN (''B'', ''C'');\n'
    || E'  v_iva_efectivo := CASE WHEN v_sin_credito THEN 0 ELSE p_iva END;',

    E'  v_ii_hdr := CASE WHEN v_es_zz THEN 0\n',
    E'  v_ii_hdr := CASE WHEN v_sin_credito THEN 0\n',

    E'    WHEN v_es_zz THEN ''{}''::JSONB',
    E'    WHEN v_sin_credito THEN ''{}''::JSONB  /* mig 293 */',
    E'''impuestos_internos'', CASE WHEN v_es_zz THEN 0\n',
    E'''impuestos_internos'', CASE WHEN v_sin_credito THEN 0\n',
    E'''porcentaje_iva'',     CASE WHEN v_es_zz OR n.cond <> ''gravado'' THEN 0',
    E'''porcentaje_iva'',     CASE WHEN v_sin_credito OR n.cond <> ''gravado'' THEN 0',
    E'\n             WHEN v_es_zz THEN ''gravado''',
    E'\n             WHEN v_sin_credito THEN ''gravado''',
    E'\n      WHEN v_es_zz THEN ''gravado''',
    E'\n      WHEN v_sin_credito THEN ''gravado''',
    E'      WHEN v_es_zz OR v_condicion_iva <> ''gravado'' THEN 0',
    E'      WHEN v_sin_credito OR v_condicion_iva <> ''gravado'' THEN 0',
    E'    v_impuestos_internos := CASE WHEN v_es_zz THEN 0 ELSE',
    E'    v_impuestos_internos := CASE WHEN v_sin_credito THEN 0 ELSE',

    E'costo_financiero_unitario(v_costo_neto, v_porcentaje_iva, v_impuestos_internos, v_compra.tipo_factura)',
    E'costo_financiero_unitario(v_costo_neto, v_porcentaje_iva, v_impuestos_internos, CASE WHEN v_sin_credito THEN ''ZZ'' ELSE v_compra.tipo_factura END)',
    E'costo_real_unitario(v_costo_neto, v_impuestos_internos, v_compra.tipo_factura, 0',
    E'costo_real_unitario(v_costo_neto, v_impuestos_internos, CASE WHEN v_sin_credito THEN ''ZZ'' ELSE v_compra.tipo_factura END, 0',

    -- el II de cabecera sigue a v_sin_credito; percepciones, no gravado y
    -- bonificaciones siguen a v_es_zz (una B puede traer percepcion de IIBB)
    E'         impuestos_internos = CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_impuestos_internos, impuestos_internos) END,',
    E'         impuestos_internos = CASE WHEN v_sin_credito THEN 0 ELSE COALESCE(p_impuestos_internos, impuestos_internos) END,'
  ]
);

-- -------------------------------------------------------------------------
-- 4 · cambiar_proveedor_compra: el clon copia la letra
-- -------------------------------------------------------------------------
SELECT public._mig293_anclas(
  'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure,
  ARRAY[
    E'    ii_declarado /* mig 194 */\n  )',
    E'    ii_declarado, /* mig 194 */\n    letra_comprobante /* mig 293 */\n  )',
    E'    c.ii_declarado /* mig 194 */\n  FROM compras c',
    E'    c.ii_declarado, /* mig 194 */\n    c.letra_comprobante /* mig 293 */\n  FROM compras c'
  ]
);

-- -------------------------------------------------------------------------
-- 5 · posicion_fiscal: el IVA de una B/C no es credito (ni el de su NC)
-- -------------------------------------------------------------------------
SELECT public._mig293_anclas(
  'public.posicion_fiscal(bigint,date,date)'::regprocedure,
  ARRAY[
    E'    SELECT COALESCE(tipo_factura, ''FC'') AS tipo_factura, subtotal, iva,\n',
    E'    SELECT COALESCE(tipo_factura, ''FC'') AS tipo_factura, subtotal, iva,\n'
    || E'           -- mig 293: solo A y M (o FC sin letra, legado) dan credito fiscal.\n'
    || E'           (COALESCE(tipo_factura, ''FC'') = ''FC''\n'
    || E'            AND COALESCE(letra_comprobante, ''A'') IN (''A'', ''M'')) AS iva_computable,\n',

    E'COALESCE(SUM(nc.iva) FILTER (WHERE COALESCE(c.tipo_factura, ''FC'') = ''FC''), 0) AS iva_nc,',
    E'COALESCE(SUM(nc.iva) FILTER (WHERE COALESCE(c.tipo_factura, ''FC'') = ''FC''\n'
    || E'                                         AND COALESCE(c.letra_comprobante, ''A'') IN (''A'', ''M'')), 0) AS iva_nc,  /* mig 293 */',

    E'           COALESCE(SUM(iva), 0) - (SELECT iva_nc FROM nc_k)',
    E'           COALESCE(SUM(iva) FILTER (WHERE iva_computable), 0) - (SELECT iva_nc FROM nc_k)'
  ]
);

-- -------------------------------------------------------------------------
-- 6 · reporte_gerencial: un ajuste por NC sobre una B/C vale su total
--     (como ZZ: el IVA no se recupera, es parte del costo que se descuenta)
-- -------------------------------------------------------------------------
SELECT public._mig293_ancla(
  'public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  E'           CASE WHEN COALESCE(c.tipo_factura, ''FC'') = ''ZZ'' THEN nc.total',
  E'           CASE WHEN COALESCE(c.tipo_factura, ''FC'') = ''ZZ''\n'
  || E'                  OR c.letra_comprobante IN (''B'', ''C'') THEN nc.total  /* mig 293 */'
);

-- -------------------------------------------------------------------------
-- 7 · auditoria_integridad: COMPRA-B mira todas las compras sin credito
-- -------------------------------------------------------------------------
SELECT public._mig293_ancla(
  'public.auditoria_integridad()'::regprocedure,
  E'(''COMPRA-B'',''high'',''compra ZZ con iva<>0'',\n'
  || E'      (SELECT count(*) FROM compras WHERE tipo_factura=''ZZ'' AND COALESCE(iva,0)<>0 AND estado<>''cancelada'')),',
  E'(''COMPRA-B'',''high'',''compra sin credito fiscal (ZZ, o FC con letra B/C) con iva<>0'',\n'
  || E'      (SELECT count(*) FROM compras WHERE (tipo_factura=''ZZ'' OR letra_comprobante IN (''B'',''C''))\n'
  || E'         AND COALESCE(iva,0)<>0 AND estado<>''cancelada'')),  /* mig 293 */'
);

DROP FUNCTION public._mig293_ancla(regprocedure, text, text);
DROP FUNCTION public._mig293_anclas(regprocedure, text[]);

-- -------------------------------------------------------------------------
-- 8 · Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n int;
  v_sig text := 'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)';
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'registrar_compra_completa';
  IF v_n <> 1 THEN RAISE EXCEPTION 'registrar_compra_completa: % sobrecargas (se esperaba 1)', v_n; END IF;

  IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN
    RAISE EXCEPTION 'registrar_compra_completa quedo ejecutable por anon';
  END IF;
  IF NOT has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN
    RAISE EXCEPTION 'registrar_compra_completa quedo sin EXECUTE para authenticated';
  END IF;

  SELECT count(*) INTO v_n FROM compras WHERE tipo_factura = 'FC' AND letra_comprobante IS NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'Quedaron % compras FC sin letra', v_n; END IF;
  SELECT count(*) INTO v_n FROM compras WHERE tipo_factura = 'ZZ' AND letra_comprobante IS NOT NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'Quedaron % compras ZZ con letra', v_n; END IF;

  -- Ningun v_es_zz quedo decidiendo el IVA/II de linea ni el costo.
  IF pg_get_functiondef(v_sig::regprocedure) ~ 'v_es_zz OR (n\.cond|v_condicion_iva)|WHEN v_es_zz THEN ''gravado''|v_es_zz THEN ''\{\}'''
     OR pg_get_functiondef('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure)
        ~ 'v_es_zz OR (n\.cond|v_condicion_iva)|WHEN v_es_zz THEN ''gravado''|v_es_zz THEN ''\{\}''' THEN
    RAISE EXCEPTION 'Quedo una rama de IVA de linea mirando v_es_zz';
  END IF;
END
$verif$;

COMMIT;
