-- ============================================================================
-- 195 · compras.bonificaciones: la cabecera puede restar una bonificación
-- ============================================================================
-- El problema, medido sobre la factura testigo A0005-00461415:
--
--     compras.total  13.343.741,18
--     el papel       13.036.957,09
--     diferencia        306.784,09   ← las tres bonificaciones gravadas
--
-- La cabecera no tiene dónde restarlas. `compras.subtotal` es el neto de los
-- RENGLONES —lo clava `COMPRA-A2` contra SUM(compra_items.subtotal)— y una
-- bonificación general no es un renglón de producto: es un cargo gravado de la
-- factura (`compra_cargos` con monto negativo, mig 192). Baja el neto gravado y
-- por lo tanto el IVA, y los dos ya salen bien del motor desde la 193/194; lo
-- único que quedaba mal era el TOTAL, y con él `COMPRA-A1`, que exige
--
--     total = subtotal + iva + ii + percepciones + no gravado + otros   (mig 178)
--
-- y es severidad `high`: `scripts/check-integridad.mjs` corre a diario desde
-- .github/workflows/integridad.yml y sale con exit 1 ante cualquier high en
-- rojo. O sea que la primera compra con bonificación general apagaba el gate
-- entero para todos los demás checks.
--
-- De las tres salidas posibles —cambiarle la semántica a `subtotal` (rompe
-- COMPRA-A2 y 132 compras), cargar la bonificación como renglón negativo (rompe
-- el stock), o agregar una columna— se eligió la ADITIVA: una columna nueva que
-- entra a la identidad. No toca `subtotal`, no toca ningún check existente, y
-- con `bonificaciones = 0` —las 132 compras de hoy— la identidad nueva ES la
-- vieja, así que el check no puede ponerse rojo por esta migración.
--
-- EL SIGNO. La columna guarda la Σ de los cargos gravados en factura TAL CUAL,
-- con su signo: negativa cuando son bonificaciones, que es el único caso que se
-- ve hoy. Es el mismo número y el mismo signo que `compra_cargos.monto`, sin
-- traducción en el medio, y deja la identidad puramente aditiva. Un
-- `bonificaciones = -306784.09` se lee raro la primera vez; una columna que a
-- veces se suma y a veces se resta se lee mal siempre.
--
-- Se parchea leyendo el catálogo y exigiendo que cada ancla aparezca una sola
-- vez (patrón de las migs 176/177/178/191/194): si un cuerpo derivó, la
-- migración falla en vez de aplicar un parche parcial.
--
-- LAS DOS RPCs CAMBIAN DE FIRMA, así que la vieja se DROPEA en la misma
-- transacción. Dejar la de N argumentos junto a la de N+1 con DEFAULT reproduce
-- la trampa de la mig 176: rangos de aridad superpuestos → PGRST203 en runtime,
-- invisible para tsc y para los tests. `cambiar_proveedor_compra` no cambia de
-- firma —sólo copia una columna más al clonar— así que va con CREATE OR REPLACE.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0 · Helper de parcheo: reemplaza exigiendo que el ancla sea única
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig195_reemplazo_unico(
  p_texto text, p_ancla text, p_nuevo text, p_donde text
) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $helper$
DECLARE
  v_veces integer;
BEGIN
  v_veces := (length(p_texto) - length(replace(p_texto, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 195 · % : el ancla "%" aparece % veces (se esperaba 1). El cuerpo derivó del texto conocido; revisá el parche antes de aplicar.',
      p_donde, left(p_ancla, 90), v_veces;
  END IF;
  RETURN replace(p_texto, p_ancla, p_nuevo);
END;
$helper$;

-- ----------------------------------------------------------------------------
-- 1 · La columna
--
-- NOT NULL DEFAULT 0: el 0 es "esta factura no trae bonificación general", que
-- es lo que pasa en las 132 compras existentes y lo que preserva la identidad
-- vieja. NULL no significaría nada distinto y obligaría a un COALESCE más en
-- cada lectura.
-- ----------------------------------------------------------------------------
ALTER TABLE public.compras
  ADD COLUMN IF NOT EXISTS bonificaciones numeric(12,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.compras.bonificaciones IS
  'Suma de los cargos GRAVADOS que vienen impresos en la factura (compra_cargos '
  'con condicion_iva=''gravado'' y en_factura), CON SU SIGNO: negativa cuando son '
  'bonificaciones generales, que es el caso normal. Existe porque compras.subtotal '
  'es el neto de los RENGLONES —lo clava COMPRA-A2 contra SUM(compra_items.subtotal)— '
  'y una bonificacion general no es un renglon de producto: sin esta columna el '
  'total de cabecera quedaba por encima del papel (306.784,09 en la factura testigo '
  'A0005-00461415) y COMPRA-A1 se ponia rojo. Entra a la identidad del check: '
  'total = subtotal + bonificaciones + iva + ii + percepciones + no_gravado + otros. '
  'Se suman los MONTOS y no el prorrateo, igual que no_gravado: la cabecera cuadra '
  'contra el papel, no contra el reparto. En ZZ es 0 (no hay comprobante). '
  'mig 195.';

-- ----------------------------------------------------------------------------
-- 2 · registrar_compra_completa recibe y persiste la bonificación de cabecera
--
-- Cinco parches sobre el cuerpo vivo: la firma, la variable, la normalización
-- (0 en ZZ, como el IVA y las percepciones), el INSERT y el control blando de
-- cuadre contra p_total.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_vieja constant text := 'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb)';
  v_nueva constant text := 'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)';
  v_def   text;
BEGIN
  -- Idempotencia por FIRMA y no por marca en el cuerpo: es lo único que no puede
  -- dar un falso positivo si mañana alguien menciona "mig 195" en un comentario.
  IF to_regprocedure(v_nueva) IS NOT NULL AND to_regprocedure(v_vieja) IS NULL THEN
    RAISE NOTICE 'mig 195 · registrar_compra_completa ya migrada, se omite';
    RETURN;
  END IF;
  IF to_regprocedure(v_vieja) IS NULL THEN
    RAISE EXCEPTION 'mig 195 · no existe % en el catálogo. Esta migración parchea el cuerpo vivo: revisá qué le pasó antes de seguir.', v_vieja;
  END IF;

  v_def := pg_get_functiondef(to_regprocedure(v_vieja));

  -- a) firma
  v_def := public._mig195_reemplazo_unico(v_def,
    $a$p_ii_declarado jsonb DEFAULT '{}'::jsonb)$a$,
    $a$p_ii_declarado jsonb DEFAULT '{}'::jsonb, p_bonificaciones numeric DEFAULT 0)$a$,
    'registrar_compra_completa · firma');

  -- b) variable
  v_def := public._mig195_reemplazo_unico(v_def,
    '  v_no_gravado_hdr      NUMERIC;
',
    '  v_no_gravado_hdr      NUMERIC;
  v_bonif_hdr           NUMERIC;    -- mig 195 · bonificaciones gravadas de la factura
',
    'registrar_compra_completa · declaraciones');

  -- c) normalización: 0 en ZZ, con el mismo criterio que el IVA
  v_def := public._mig195_reemplazo_unico(v_def,
    '  v_no_gravado_hdr := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_no_gravado, 0) END;
',
    '  v_no_gravado_hdr := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_no_gravado, 0) END;
  v_bonif_hdr      := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_bonificaciones, 0) END;  /* mig 195 */
',
    'registrar_compra_completa · normalizacion');

  -- d) INSERT
  v_def := public._mig195_reemplazo_unico(v_def,
    '    no_gravado, otros_impuestos, total, forma_pago, notas,
',
    '    no_gravado, bonificaciones, otros_impuestos, total, forma_pago, notas,
',
    'registrar_compra_completa · columnas del INSERT');
  v_def := public._mig195_reemplazo_unico(v_def,
    '    v_no_gravado_hdr, COALESCE(p_otros_impuestos, 0), p_total, p_forma_pago, p_notas,
',
    '    v_no_gravado_hdr, v_bonif_hdr, COALESCE(p_otros_impuestos, 0), p_total, p_forma_pago, p_notas,
',
    'registrar_compra_completa · valores del INSERT');

  -- e) control blando de cuadre: la misma identidad que COMPRA-A1
  v_def := public._mig195_reemplazo_unico(v_def,
    '         + v_perc_iibb_hdr + v_no_gravado_hdr + COALESCE(p_otros_impuestos, 0)
',
    '         + v_perc_iibb_hdr + v_no_gravado_hdr + v_bonif_hdr + COALESCE(p_otros_impuestos, 0)
',
    'registrar_compra_completa · cuadre');

  EXECUTE v_def;
  EXECUTE format('DROP FUNCTION %s', v_vieja);
END;
$mig$;

-- `pg_get_functiondef` no trae los GRANT: la función nueva nace con los
-- privilegios por defecto del rol que aplique. Sin esto se puede reabrir a
-- PUBLIC lo que cerraron las migs 188/189 y poner en rojo el gate de permisos.
REVOKE ALL ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3 · actualizar_compra_items conserva la bonificación al editar
--
-- `NULL` = "no me lo mandaste, dejá lo que había", igual que las percepciones y
-- el no gravado. Es lo que evita que un cliente con el bundle viejo le borre la
-- bonificación de cabecera a una compra al editarle una cantidad — y con eso le
-- vuelva a inflar el total 306.784,09 y ponga COMPRA-A1 en rojo.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_vieja constant text := 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb)';
  v_nueva constant text := 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)';
  v_def   text;
BEGIN
  IF to_regprocedure(v_nueva) IS NOT NULL AND to_regprocedure(v_vieja) IS NULL THEN
    RAISE NOTICE 'mig 195 · actualizar_compra_items ya migrada, se omite';
    RETURN;
  END IF;
  IF to_regprocedure(v_vieja) IS NULL THEN
    RAISE EXCEPTION 'mig 195 · no existe % en el catálogo. Esta migración parchea el cuerpo vivo: revisá qué le pasó antes de seguir.', v_vieja;
  END IF;

  v_def := pg_get_functiondef(to_regprocedure(v_vieja));

  v_def := public._mig195_reemplazo_unico(v_def,
    $a$p_ii_declarado jsonb DEFAULT NULL::jsonb)$a$,
    $a$p_ii_declarado jsonb DEFAULT NULL::jsonb, p_bonificaciones numeric DEFAULT NULL::numeric)$a$,
    'actualizar_compra_items · firma');

  v_def := public._mig195_reemplazo_unico(v_def,
    '         no_gravado         = CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_no_gravado, no_gravado) END,
',
    '         no_gravado         = CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_no_gravado, no_gravado) END,
         bonificaciones     = CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_bonificaciones, bonificaciones) END,  /* mig 195 */
',
    'actualizar_compra_items · UPDATE de la cabecera');

  EXECUTE v_def;
  EXECUTE format('DROP FUNCTION %s', v_vieja);
END;
$mig$;

REVOKE ALL ON FUNCTION public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4 · cambiar_proveedor_compra clona también la bonificación
--
-- Esta RPC anula la compra y la clona contra otro proveedor con una lista de
-- columnas EXPLÍCITA. Una columna que no esté en esa lista cae al DEFAULT: el
-- clon nacería con bonificaciones = 0 y el mismo `total`, o sea violando
-- COMPRA-A1 desde el minuto cero. La firma no cambia, así que va por CREATE OR
-- REPLACE y no hace falta dropear nada.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_firma constant text := 'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)';
  v_def   text;
BEGIN
  IF to_regprocedure(v_firma) IS NULL THEN
    RAISE EXCEPTION 'mig 195 · no existe % en el catálogo.', v_firma;
  END IF;
  v_def := pg_get_functiondef(to_regprocedure(v_firma));

  IF position('c.bonificaciones' in v_def) > 0 THEN
    RAISE NOTICE 'mig 195 · cambiar_proveedor_compra ya clona la bonificación, se omite';
    RETURN;
  END IF;

  v_def := public._mig195_reemplazo_unico(v_def,
    '    subtotal, iva, impuestos_internos, percepcion_iva, percepcion_iibb, no_gravado,
',
    '    subtotal, iva, impuestos_internos, percepcion_iva, percepcion_iibb, no_gravado,
    bonificaciones, /* mig 195 */
',
    'cambiar_proveedor_compra · columnas del clon');

  v_def := public._mig195_reemplazo_unico(v_def,
    '    c.subtotal, c.iva, c.impuestos_internos, c.percepcion_iva, c.percepcion_iibb, c.no_gravado,
',
    '    c.subtotal, c.iva, c.impuestos_internos, c.percepcion_iva, c.percepcion_iibb, c.no_gravado,
    c.bonificaciones, /* mig 195 */
',
    'cambiar_proveedor_compra · valores del clon');

  EXECUTE v_def;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 5 · COMPRA-A1 incluye la columna nueva en la identidad
--
-- Mismo patrón que la mig 178. Con `bonificaciones = 0` la fórmula nueva es
-- idéntica a la vieja, así que las 132 compras existentes siguen en verde por
-- construcción y no por suerte.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def   text;
  v_ancla CONSTANT text := $a$('COMPRA-A1','high','compras.total = subtotal+iva+ii+percepciones+no gravado+otros (mig 178)',
      (SELECT count(*) FROM compras WHERE estado<>'cancelada' AND abs(COALESCE(total,0)-(
        COALESCE(subtotal,0)+COALESCE(iva,0)+COALESCE(impuestos_internos,0)
        +COALESCE(percepcion_iva,0)+COALESCE(percepcion_iibb,0)
        +COALESCE(no_gravado,0)+COALESCE(otros_impuestos,0)))>1.0)),$a$;
  v_nuevo CONSTANT text := $a$('COMPRA-A1','high','compras.total = subtotal+bonificaciones+iva+ii+percepciones+no gravado+otros (mig 195)',
      (SELECT count(*) FROM compras WHERE estado<>'cancelada' AND abs(COALESCE(total,0)-(
        COALESCE(subtotal,0)+COALESCE(bonificaciones,0)+COALESCE(iva,0)+COALESCE(impuestos_internos,0)
        +COALESCE(percepcion_iva,0)+COALESCE(percepcion_iibb,0)
        +COALESCE(no_gravado,0)+COALESCE(otros_impuestos,0)))>1.0)),$a$;
BEGIN
  v_def := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);

  IF position('(mig 195)' in v_def) > 0 THEN
    RAISE NOTICE 'mig 195 · COMPRA-A1 ya incluye las bonificaciones, se omite';
    RETURN;
  END IF;

  EXECUTE public._mig195_reemplazo_unico(v_def, v_ancla, v_nuevo, 'auditoria_integridad · COMPRA-A1');
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 6 · Post-check: nada nace en rojo y no queda ninguna firma ambigua
--
-- Se EJECUTA y no se compila: la mig 194 dejó dicho por qué —un `format()` con
-- un placeholder de más compila perfecto y explota en runtime, y lo agarró el
-- ensayo al ejecutar, no al crear la función—.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
  v_n integer;
BEGIN
  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('registrar_compra_completa', 'actualizar_compra_items');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'mig 195 · hay % firmas de las dos RPCs de compra (se esperaban 2). Rangos de aridad superpuestos = PGRST203 en runtime, invisible para tsc y los tests.', v_n
      USING ERRCODE = '22023';
  END IF;

  SELECT (a.c->>'violaciones')::int INTO v_n
    FROM jsonb_array_elements(auditoria_integridad()->'checks') a(c)
   WHERE a.c->>'id' = 'COMPRA-A1';
  IF v_n IS NULL THEN
    RAISE EXCEPTION 'mig 195 · COMPRA-A1 desapareció de auditoria_integridad(): el parche se comió el check.'
      USING ERRCODE = '22023';
  END IF;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig 195 · COMPRA-A1 queda con % violaciones. Con bonificaciones=0 la identidad nueva ES la vieja, así que esto significa drift previo: revisalo antes de aplicar.', v_n
      USING ERRCODE = '22023';
  END IF;
END;
$post$;

-- El helper es andamiaje de esta migración, no API: se va con ella.
DROP FUNCTION IF EXISTS public._mig195_reemplazo_unico(text, text, text, text);

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
--   BEGIN;
--     -- 1. desandar el parche de COMPRA-A1 (volver la fórmula al texto de la 178)
--     -- 2. volver las dos RPCs a su firma anterior leyendo el cuerpo vivo y
--     --    sacando p_bonificaciones, la variable, el INSERT/UPDATE y el cuadre;
--     --    después DROP de las firmas de 20 y 14 argumentos.
--     -- 3. re-otorgar los privilegios, que el CREATE no restaura solo.
--     -- 4. recién ahí: ALTER TABLE compras DROP COLUMN bonificaciones;
--   COMMIT;
--
-- El orden importa: dropear la columna antes que el check deja
-- auditoria_integridad() referenciando una columna que no existe y TODOS los
-- checks se caen juntos, no sólo COMPRA-A1.
--
-- Y sólo es limpio mientras ninguna compra tenga bonificación de cabecera. En
-- cuanto la tenga, dropear la columna devuelve esa compra al total inflado.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Verificación
--
--   -- UNA sola firma de cada RPC, con 20 y 14 argumentos:
--   SELECT proname, pronargs, array_to_string(proacl, ' ')
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND proname IN ('registrar_compra_completa','actualizar_compra_items');
--
--   -- Los checks de compras, todos en verde:
--   SELECT c->>'id', c->>'severidad', c->>'violaciones'
--     FROM jsonb_array_elements(auditoria_integridad()->'checks') c
--    WHERE c->>'id' LIKE 'COMPRA-%';
--
--   -- La factura testigo end-to-end (21 renglones, 6 cargos): total contra el
--   -- papel = 13.036.957,09 y factor de ajuste 1,000000 en las dos alícuotas.
-- ----------------------------------------------------------------------------
