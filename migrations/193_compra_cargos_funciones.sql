-- ============================================================================
-- 193 · Compras: el motor de cálculo de los cargos, en SQL
-- ============================================================================
-- Ver docs/plans/2026-08-18-cargos-y-cuadre-de-compras.md
--
-- La 192 creó las tablas; acá va la aritmética que las lee. El archivo se llena
-- en tres tramos, y con la task 8 queda completo:
--
--   1 · prorratear_cargo        — reparte UN cargo sobre un vector de pesos
--   2 · costo_real_unitario     — el costo por unidad gana el término de los cargos,
--                                 y los tres llamadores pasan a la firma nueva
--   3 · calcular_costos_compra  — las tres bases, el II ajustado al declarado y
--                                 los unitarios de cada línea
--
-- Los tres van adentro del mismo BEGIN/COMMIT: el motor a medias no sirve para
-- nada, y dejar la mitad aplicada es peor que no aplicar nada.
--
-- Todo lo de acá es espejo EXACTO de `src/utils/prorrateoCompra.ts`, que ya
-- reproduce la factura testigo A0005-00461415 al medio centavo por línea. Las dos
-- implementaciones existen porque el número se calcula y se PERSISTE en la base,
-- pero el modal tiene que anticiparlo sin ir a la base. Si cambiás una, cambiá la
-- otra: `prorrateoCompra.test.ts` y `prorrateoCompra.golden.test.ts` son la
-- especificación de las dos.
--
-- Y desde la mig 196 eso NO depende de que alguien se acuerde. El espejo
-- (`scripts/espejo-motor-compras.mjs`, sobre `espejo_motor_compras`) corre las
-- DOS implementaciones sobre los mismos casos —los 10 repartos unitarios, la
-- factura testigo entera y los casos de contrato— y falla si difieren en un
-- centavo o si sólo una lanza. Corre en el gate de integridad, todos los días.
-- Tocar este archivo y no el TypeScript lo pone rojo, que es exactamente lo que
-- esta frase pedía y no podía garantizar.
--
-- "EXACTO" lo es para todo dato bien formado, y en el BORDE del jsonb es a
-- propósito MÁS permisivo que el TS: acá las claves opcionales tienen DEFAULT
-- (`condicion_iva` 'gravado' en la línea y 'no_gravado' en el cargo,
-- `porcentaje_iva` 0, `en_factura` true…), y son los MISMOS defaults que los de
-- las tablas de la 192, para que armar el jsonb desde una fila y omitir una
-- columna den lo mismo. El TS no los tiene: sus campos son obligatorios y se los
-- exige el compilador. Donde el dato es basura —no donde falta— las dos LANZAN.
--
-- ⚠ SEIS MIGRACIONES VIEJAS DEL REPO SON MINAS: `111`, `112`, `114`, `115`,
-- `126` y `128` tienen call sites de `costo_real_unitario` con TRES argumentos.
-- Una vez aplicada ésta, re-aplicar cualquiera de ellas deja una RPC de compras
-- llamando a una firma que ya no existe — y NO rompe al aplicarla, rompe en
-- producción la próxima vez que alguien registra o anula una compra. Es el mismo
-- patrón que ya mordió al trabajo de multi-rol: un `CREATE OR REPLACE` viejo que
-- revierte lógica viva en silencio. Si hay que reaplicar alguna, actualizale el
-- call site a la firma de 4 argumentos ANTES de correrla.
-- (El revisor contó cinco; la `112` también la tiene, en el UPDATE de productos.)
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1 · Reparto de un cargo sobre un vector de pesos
--
-- Espejo de `prorratearCargo()` en src/utils/prorrateoCompra.ts.
--
-- El residuo va a la línea de mayor peso (desempate: menor id) para que la suma
-- dé el monto EXACTO: sin eso, repartir sobre pesos fraccionarios no vuelve a
-- sumar el monto y el check de integridad COMPRA-A3 se pone rojo por centavos.
-- (Se llama A3 y no A2: cuando se escribió esto A2 parecía libre y no lo estaba.)
-- `ORDER BY peso DESC, id ASC` es un orden total sobre ids distintos, así que
-- cuál es la línea del residuo no depende del orden en que llegue el vector.
--
-- El orden en que se ACUMULAN las partes tampoco importa acá, y eso es una
-- propiedad de `numeric`, no una casualidad: la suma es exacta y por lo tanto
-- asociativa. En el espejo de JS sí importaba. Es también lo que permite marcar
-- la función IMMUTABLE aun con un `sum()` que el planner puede paralelizar: con
-- `double precision` el resultado dependería del plan.
--
-- Contrato de entrada, el mismo que el del TS. El cero es un estado válido; el
-- negativo, el NaN y el infinito son corrupción:
--   · peso 0        → legal, excluye la línea. ES el mecanismo de alcance.
--   · vector vacío  → 0 filas. Legal: es la grilla a medio llenar. `p_pesos`
--     NULL cuenta como vacío, porque `jsonb_object_agg` de cero filas devuelve
--     NULL y ésa es exactamente la forma en que un cargo sin repartos va a
--     llegar hasta acá.
--   · peso negativo o no finito → LANZA, nombrando la línea.
--   · monto NULL o no finito    → LANZA.
--
-- Por qué lanza en vez de normalizar a 0: convertir basura en 0 la vuelve
-- indistinguible de una exclusión deliberada, porque el 0 ES la exclusión. Y el
-- daño no es "un poco de error". Un solo NaN hace NaN a `sum(peso)` y por lo
-- tanto a TODOS los repartos del cargo, y de ahí al costo_real_unitario y al
-- costo promedio ponderado. El peso negativo es peor todavía porque no deja
-- rastro: da números plausibles, y si los negativos cancelan a los positivos el
-- cargo entero desaparece sin un solo aviso.
--
-- El CHECK de compra_cargo_repartos ya filtra lo que se GUARDA, pero `p_pesos`
-- es un jsonb: puede llegar armado desde el payload de una RPC sin haber pasado
-- nunca por la tabla. Y las dos defensas no cubren lo mismo — `'NaN' >= 0` es
-- TRUE, y `'Infinity'` pasa el CHECK entero: al infinito lo frena recién el
-- numeric(16,4) de la columna, que acá no existe.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prorratear_cargo(p_monto numeric, p_pesos jsonb)
RETURNS TABLE (item_id bigint, monto numeric)
LANGUAGE plpgsql
IMMUTABLE          -- sólo mira sus argumentos: ni tablas, ni now(), ni GUCs
PARALLEL SAFE
ROWS 25            -- líneas por compra: media 4, máximo 31. El default de 1000 miente feo
SET search_path TO 'public'
AS $fn$
DECLARE
  v_total_peso numeric;
  v_id_residuo bigint;
  v_key        text;
  v_motivo     text;
  v_val        jsonb;
BEGIN
  -- NO es STRICT a propósito: STRICT devolvería 0 filas ante un monto NULL, o
  -- sea justo el silencio que este contrato viene a evitar.
  IF p_monto IS NULL
     OR p_monto = 'NaN'::numeric
     OR p_monto = 'Infinity'::numeric
     OR p_monto = '-Infinity'::numeric THEN
    RAISE EXCEPTION 'prorratear_cargo: monto no finito (%).', COALESCE(p_monto::text, 'NULL')
      USING ERRCODE = '22023';
  END IF;

  -- Vector ausente ≡ vector vacío. Cualquier otro jsonb que no sea un objeto es
  -- un error de forma, y conviene decirlo acá: `jsonb_each_text` tira "cannot
  -- call jsonb_each_text on a non-object", que no nombra ni la función ni el
  -- cargo.
  IF p_pesos IS NULL OR jsonb_typeof(p_pesos) = 'null' THEN
    RETURN;
  END IF;
  IF jsonb_typeof(p_pesos) <> 'object' THEN
    RAISE EXCEPTION 'prorratear_cargo: se esperaba un objeto {id: peso} y llego un %.',
      jsonb_typeof(p_pesos) USING ERRCODE = '22023';
  END IF;

  -- Las claves son ids de línea. Se validan ANTES que los pesos porque todo lo
  -- que sigue castea la clave a bigint, y ese error de cast no dice ni qué clave
  -- fue ni de qué función salió. Son TRES formas de romperlo y antes las tres
  -- pasaban por el mismo `!~ '^-?[0-9]+$'`, que sólo atajaba la primera:
  --   · no numérica ('pallet') → la atajaba el regex, sigue igual.
  --   · fuera del rango de bigint ('999999999999999999999') → pasaba el regex y
  --     reventaba después en el cast con un 22003 crudo, que es exactamente el
  --     error que esta validación existe para no mostrar.
  --   · no canónica ('01', '-0') → la peor, porque no es un error de forma sino
  --     PLATA DUPLICADA: '01' y '1' son claves jsonb distintas que castean al
  --     MISMO bigint, así que `repartos` emite dos filas con item_id = 1 y la
  --     línea cobra el cargo DOS VECES. Se compara contra la forma canónica en
  --     vez de buscar ceros a la izquierda porque así cae también el '-0'.
  -- El CASE fuerza el orden de evaluación en los dos lados: sin él el planner
  -- puede correr el cast antes del regex y volver al error crudo.
  SELECT e.key,
         CASE WHEN e.key !~ '^-?[0-9]+$' THEN 'no es un id de linea'
              WHEN e.key::numeric NOT BETWEEN -9223372036854775808
                                          AND  9223372036854775807
                THEN 'se sale del rango de bigint'
              ELSE 'no esta en forma canonica (como "01" o "-0"), y dos claves que castean al mismo id le cobran el cargo dos veces a esa linea'
         END
    INTO v_key, v_motivo
    FROM jsonb_each(p_pesos) e
   WHERE CASE WHEN e.key !~ '^-?[0-9]+$' THEN true
              WHEN e.key::numeric NOT BETWEEN -9223372036854775808
                                          AND  9223372036854775807 THEN true
              ELSE e.key <> (e.key::bigint)::text
         END
   ORDER BY e.key
   LIMIT 1;
  IF v_key IS NOT NULL THEN
    RAISE EXCEPTION 'prorratear_cargo: la clave "%" %.', v_key, v_motivo
      USING ERRCODE = '22023';
  END IF;

  -- Un solo recorrido, en el mismo orden y con la misma precedencia que el TS
  -- (primero "no finito", después "negativo"): ante un vector con las dos clases
  -- de basura, las dos implementaciones nombran la misma línea.
  --
  -- `jsonb_typeof = 'number'` es lo que ataja el NaN, no el chequeo de signo:
  -- Postgres serializa el NaN y el infinito de numeric como STRING
  -- (`jsonb_object_agg` de un peso NaN da '{"1": "NaN"}'), y el texto 'NaN'
  -- castea a numeric sin chistar. Al revés, un jsonb de tipo 'number' no puede
  -- ser NaN ni infinito: JSON no tiene esos literales.
  FOR v_key, v_val IN
    SELECT e.key, e.value FROM jsonb_each(p_pesos) e ORDER BY e.key::bigint
  LOOP
    IF jsonb_typeof(v_val) <> 'number' THEN
      RAISE EXCEPTION
        'prorratear_cargo: peso no finito en la linea % (%). Se esperan numeros finitos; el 0 excluye una linea.',
        v_key, v_val USING ERRCODE = '22023';
    END IF;
    IF (v_val #>> '{}')::numeric < 0 THEN
      RAISE EXCEPTION
        'prorratear_cargo: peso negativo en la linea % (%). Los pesos son proporciones; el 0 excluye una linea.',
        v_key, v_val USING ERRCODE = '22023';
    END IF;
  END LOOP;

  SELECT sum(e.value::numeric) INTO v_total_peso FROM jsonb_each_text(p_pesos) e;

  -- Validados los pesos, esto significa exactamente "todos en cero" (o sin
  -- líneas): ya no puede ser una cancelación entre positivos y negativos.
  IF v_total_peso IS NULL OR v_total_peso = 0 THEN
    RETURN;
  END IF;

  SELECT e.key::bigint INTO v_id_residuo
    FROM jsonb_each_text(p_pesos) e
   ORDER BY e.value::numeric DESC, e.key::bigint ASC
   LIMIT 1;

  -- Una sola consulta en vez de un loop con acumulador: así la definición del
  -- residuo —el monto menos todo lo demás— se lee de un renglón, que es la
  -- invariante que justifica la función entera.
  --
  -- El `ORDER BY` final no es parte del contrato, pero hace reproducible
  -- cualquier volcado y sobre 31 filas como máximo no se paga nada por él.
  RETURN QUERY
  WITH partes AS (
    SELECT e.key::bigint AS id,
           round(p_monto * e.value::numeric / v_total_peso, 2) AS parte
      FROM jsonb_each_text(p_pesos) e
     WHERE e.key::bigint <> v_id_residuo
  )
  SELECT p.id, p.parte
    FROM partes p
   UNION ALL
  SELECT v_id_residuo,
         round(p_monto - COALESCE((SELECT sum(x.parte) FROM partes x), 0), 2)
   ORDER BY 1;
END;
$fn$;

COMMENT ON FUNCTION public.prorratear_cargo(numeric, jsonb) IS
  'Reparte un cargo de compra sobre un vector {id_de_linea: peso}. La suma de '
  'los repartos da el monto EXACTO: el residuo del redondeo cae en la linea de '
  'mayor peso (desempate por menor id). Peso 0 excluye la linea y vector vacio '
  'devuelve 0 filas; un peso negativo, NaN o infinito LANZA, porque el 0 ya es '
  'el mecanismo de exclusion y normalizar basura a 0 la volveria invisible. '
  'Espejo exacto de prorratearCargo() en src/utils/prorrateoCompra.ts (mig 193).';

-- Aritmética pura, sin datos adentro, pero no hay motivo para publicarla como
-- endpoint de PostgREST para `anon`. Las RPCs de la 194 son la superficie.
--
-- `anon` va nombrado aparte y NO es redundante con PUBLIC —una concesión
-- explícita del ALTER DEFAULT PRIVILEGES no se va revocando PUBLIC— pero es
-- DEFENSIVO, no correctivo: si hoy aplica `postgres`, no saca nada. Depende del
-- rol que aplique, y eso no lo decide este archivo.
--
-- Medido el 2026-08-19: sobre el schema `public` conviven DOS default privileges
-- para funciones, y no dicen lo mismo. El de `postgres` ya NO le da EXECUTE a
-- anon (se lo sacó la mig 188); el de `supabase_admin` SÍ se lo sigue dando. O
-- sea que el REVOKE es redundante mientras aplique `postgres` y necesario apenas
-- aplique otro rol —o si alguna vez se revierte la 188—, que es justo el momento
-- en que nadie lo estaría mirando. Se queda.
REVOKE ALL ON FUNCTION public.prorratear_cargo(numeric, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prorratear_cargo(numeric, jsonb) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2 · costo_real_unitario gana un término ADITIVO para los cargos prorrateados
--
-- Hoy los tres llamadores pasan 0, así que **ningún costo se mueve**: esta
-- sección es puro andamiaje. Los cargos de verdad entran en la task 9.
--
-- LA REGLA, porque no es obvia y ya se discutió una vez:
-- **`tipo_factura` decide si se agregan IMPUESTOS encima, no si se ignoran
-- COSTOS.** En ZZ lo pagado ya incluye IVA e impuestos internos —son impuestos
-- de esa misma operación, ya adentro del precio— y por eso no se le suma nada de
-- eso. Pero un flete que factura un transportista aparte, o unos pallets que se
-- pagaron aparte, NO están adentro de ese precio: es plata que salió igual. Que
-- la mercadería haya venido con factura o sin ella no cambia que el camión se
-- pagó. Y mirado desde el dato: si alguien carga un cargo de flete sobre una
-- compra ZZ está afirmando que es un costo adicional; si ya estuviera adentro
-- del precio no lo cargaría. Descartarlo sería ignorar lo que el usuario dijo.
-- Por eso el cargo entra en las DOS ramas, y el II sólo en una.
--
-- La rama ZZ ahora también redondea, cosa que antes no hacía porque devolvía el
-- neto tal cual. Verificado contra las 109 líneas ZZ de prod: 0 se mueven —
-- ninguna tiene bonificación, así que su neto es el costo_unitario numeric(12,2)
-- y ya venía con 2 decimales. No es cosmético igual: `v_costo_real` no va sólo a
-- la columna numeric(12,4), también entra al cálculo del costo promedio
-- ponderado multiplicado por la cantidad, antes de que ninguna columna lo trunque
-- (registrar_compra_completa línea 130, actualizar_compra_items línea 243). O sea
-- que el round alinea ZZ con FC —que ya redondeaba— y hace que el CPP use el
-- mismo número que queda guardado en la línea, en vez de uno más largo que nadie
-- puede auditar después.
--
-- Se DROPEA la de 3 argumentos en vez de dejarla al lado de una de 4 con
-- DEFAULT: dos sobrecargas con rangos de aridad superpuestos dan PGRST203 en
-- runtime, invisible para tsc y para los tests (la trampa de la mig 176).
-- Verificado antes de escribir esto: la función no tiene NINGUNA dependencia
-- registrada —ni vistas, ni índices, ni CHECKs, ni defaults, ni triggers— y no
-- la llama nadie por RPC desde el front, el bot ni las edge functions. Los
-- únicos llamadores son los tres plpgsql de más abajo.
--
-- El DROP no protege de nada por sí solo: los cuerpos plpgsql son strings y
-- Postgres no los valida al dropear, así que una RPC que quedara sin parchear
-- no falla hasta que alguien la ejecuta en producción. Por eso el DROP y los
-- tres parches van en la MISMA transacción, y por eso el ensayo registra una
-- compra de punta a punta en vez de conformarse con que compile.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.costo_real_unitario(numeric, numeric, text);

CREATE OR REPLACE FUNCTION public.costo_real_unitario(
  p_costo_neto     numeric,
  p_pct_ii         numeric,
  p_tipo_factura   text,
  p_cargo_unitario numeric
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE     -- la vieja era UNSAFE (el default), y es aritmética pura
AS $fn$
  SELECT CASE
    WHEN p_tipo_factura = 'ZZ' THEN round(p_costo_neto + COALESCE(p_cargo_unitario, 0), 4)
    ELSE round(p_costo_neto * (1 + COALESCE(p_pct_ii, 0) / 100)
               + COALESCE(p_cargo_unitario, 0), 4)
  END;
$fn$;

COMMENT ON FUNCTION public.costo_real_unitario(numeric, numeric, text, numeric) IS
  'Costo de reposicion por unidad: neto + impuesto interno + cargos prorrateados '
  '(flete, pallets, separadores, bonificaciones). LA REGLA: tipo_factura decide '
  'si se agregan IMPUESTOS encima, no si se ignoran COSTOS. En ZZ lo pagado ya '
  'incluye IVA e II —son impuestos de esa operacion— asi que no se le suma nada '
  'de eso; pero el flete que factura un tercero no esta adentro de ese precio y '
  'SI suma. Por eso el cargo entra en las dos ramas y el II en una sola. '
  'El 4o argumento llego con la mig 193 y hoy todos los llamadores pasan 0. '
  'DECISION YA TOMADA, no re-litigar: el espejo calcularCostoReal() de '
  'src/utils/calculations.ts se alinea con esta misma regla en la task 9.';

-- Las dos mitades del REVOKE, por el mismo motivo defensivo que arriba.
--
-- La justificación vieja —"la de 3 argumentos está abierta a PUBLIC y a anon a
-- la vez, recrearla es la oportunidad de cerrarla"— YA NO ES CIERTA, y conviene
-- que quede dicho en vez de borrado: era verdad cuando se midió y dejó de serlo
-- cuando las migs 188/189 se aplicaron con esta rama abierta. Hoy su ACL medido
-- es `postgres=X/postgres authenticated=X/postgres service_role=X/postgres`, sin
-- PUBLIC y sin anon. El REVOKE ya no cierra nada que esté abierto: evita que el
-- CREATE de acá lo reabra según qué rol aplique la migración.
REVOKE ALL ON FUNCTION public.costo_real_unitario(numeric, numeric, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.costo_real_unitario(numeric, numeric, text, numeric) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2.1 · Helper de parcheo: reemplaza exigiendo que el ancla sea única
--
-- Mismo patrón que las migs 176/177/178. Los cuerpos se leen del CATÁLOGO VIVO
-- con pg_get_functiondef y se les cambia sólo la llamada: `migrations/` no es
-- 1:1 con prod, así que copiar el cuerpo del archivo más reciente puede revertir
-- lógica viva en silencio. Si el ancla no aparece exactamente una vez, la
-- migración FALLA en vez de aplicar un parche parcial.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig193_reemplazo_unico(
  p_texto text, p_ancla text, p_nuevo text, p_donde text
) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $helper$
DECLARE
  v_veces integer;
BEGIN
  v_veces := (length(p_texto) - length(replace(p_texto, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 193 · % : el ancla "%" aparece % veces (se esperaba 1). El cuerpo derivó del texto conocido; revisá el parche antes de aplicar.',
      p_donde, left(p_ancla, 70), v_veces;
  END IF;
  RETURN replace(p_texto, p_ancla, p_nuevo);
END;
$helper$;

-- ----------------------------------------------------------------------------
-- 2.2 · Los llamadores pasan a la firma de 4 argumentos
--
-- Son TRES, no cuatro. `cambiar_proveedor_compra` NO llama a la función:
-- clona la compra copiando la COLUMNA `ci.costo_real_unitario` de las líneas
-- originales, que es justo lo que esa RPC promete (anula y clona sin tocar
-- stock ni costos). Las dos menciones que tiene son a la columna, no a la
-- función — verificado contando `costo_real_unitario(` con el paréntesis.
--
-- El marcador de idempotencia va en un comentario de BLOQUE y no de línea: un
-- `--` pegado a la llamada se comería el `;` o el `),` que vienen después.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def text;
BEGIN
  -- a) registrar_compra_completa · alta de una compra
  v_def := pg_get_functiondef('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric)'::regprocedure);
  IF position('mig 193' in v_def) = 0 THEN
    EXECUTE public._mig193_reemplazo_unico(v_def,
      $a$costo_real_unitario(v_costo_neto, v_impuestos_internos, v_tipo_factura)$a$,
      $a$costo_real_unitario(v_costo_neto, v_impuestos_internos, v_tipo_factura, 0 /* mig 193: los cargos entran en la task 9 */)$a$,
      'registrar_compra_completa');
  END IF;

  -- b) actualizar_compra_items · edición de una compra
  v_def := pg_get_functiondef('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric)'::regprocedure);
  IF position('mig 193' in v_def) = 0 THEN
    EXECUTE public._mig193_reemplazo_unico(v_def,
      $a$costo_real_unitario(v_costo_neto, v_impuestos_internos, v_compra.tipo_factura)$a$,
      $a$costo_real_unitario(v_costo_neto, v_impuestos_internos, v_compra.tipo_factura, 0 /* mig 193: los cargos entran en la task 9 */)$a$,
      'actualizar_compra_items');
  END IF;

  -- c) anular_compra_atomica · reconstruye el costo del producto con la compra
  --    anterior. Acá la llamada es el 2º argumento de un COALESCE, no una
  --    asignación: el ancla la agarra igual porque es la expresión de la llamada.
  v_def := pg_get_functiondef('public.anular_compra_atomica(bigint,uuid)'::regprocedure);
  IF position('mig 193' in v_def) = 0 THEN
    EXECUTE public._mig193_reemplazo_unico(v_def,
      $a$costo_real_unitario(v_neto, COALESCE(v_ult.ii_linea, p.impuestos_internos), v_ult.tipo_factura)$a$,
      $a$costo_real_unitario(v_neto, COALESCE(v_ult.ii_linea, p.impuestos_internos), v_ult.tipo_factura, 0 /* mig 193: los cargos entran en la task 9 */)$a$,
      'anular_compra_atomica');
  END IF;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 2.3 · POST-condición: los tres cuerpos quedaron con la llamada nueva
--
-- La PRE-condición (el ancla tiene que aparecer exactamente una vez) es fuerte,
-- pero el guard de idempotencia de arriba es `position('mig 193' in v_def) = 0`
-- sobre TODO el functiondef. Si mañana cualquiera de esos tres cuerpos gana una
-- mención no relacionada a "mig 193" —un comentario, otra migración que la
-- nombre— el parche se saltea sin decir una palabra. Y como la firma de 3
-- argumentos ya se dropeó en esta MISMA transacción, el cuerpo queda llamando a
-- una función que no existe: no falla al aplicar, falla en producción la próxima
-- vez que alguien registra o anula una compra. El archivo describía ese modo de
-- falla más arriba y después no se defendía de él.
--
-- Se busca la MARCA COMPLETA y no el string 'mig 193': la marca sólo la puede
-- haber escrito este parche, así que una mención casual no la satisface.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
  v_marca constant text := ', 0 /* mig 193: los cargos entran en la task 9 */)';
  v_fn    text;
  v_veces integer;
  v_mal   text := '';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric)',
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric)',
    'public.anular_compra_atomica(bigint,uuid)']
  LOOP
    v_veces := (length(pg_get_functiondef(v_fn::regprocedure))
                - length(replace(pg_get_functiondef(v_fn::regprocedure), v_marca, '')))
               / length(v_marca);
    IF v_veces <> 1 THEN
      v_mal := v_mal || format('%s (%s marcas) ', split_part(v_fn, '(', 1), v_veces);
    END IF;
  END LOOP;
  IF v_mal <> '' THEN
    RAISE EXCEPTION 'mig 193 · el parche NO quedó aplicado en: %. Se esperaba exactamente 1 llamada marcada por función. La firma de 3 argumentos ya se dropeó en esta transaccion, asi que dejar pasar esto seria publicar RPCs de compras rotas.', v_mal
      USING ERRCODE = '22023';
  END IF;
END;
$post$;

-- El helper es andamiaje de esta migración, no API: se va con ella. En prod no
-- sobrevive ningún `_mig*`, así que la convención es dropearlos.
DROP FUNCTION IF EXISTS public._mig193_reemplazo_unico(text, text, text, text);

-- ----------------------------------------------------------------------------
-- 3 · El motor de costos de una compra
--
-- Espejo de `calcularCostosCompra()` en src/utils/prorrateoCompra.ts. Recibe las
-- líneas, los cargos y el impuesto interno DECLARADO por alícuota, y devuelve los
-- unitarios de cada línea más los totales que cuadran contra el papel.
--
-- El contrato de entrada usa los nombres de columna de la mig 192
-- (`condicion_iva`, `en_factura`, `prorratea_al_costo`, `afecta_base_ii`, `pesos`)
-- porque la RPC de la task 9 va a armar estos jsonb leyendo esas tablas: un
-- renombre en el medio sería una oportunidad de error sin ninguna ganancia.
--
-- TRES BASES SEPARADAS, y son distintas a propósito porque responden preguntas
-- distintas. Es acá donde se equivoca cualquiera que traduzca esto de memoria:
--
--   · base_iva_factura → neto de la línea (SÓLO si es gravada) + cargos gravados
--     que están EN FACTURA. Alimenta el IVA y el cuadre contra el papel. Filtra
--     por `en_factura`.
--   · base_costo       → neto + cargos GRAVADOS que PRORRATEAN AL COSTO. Filtra
--     por `prorratea_al_costo`, que NO es el mismo filtro. El IVA de un flete de
--     transportista inscripto es crédito fiscal: su neto entra al costo, su IVA
--     no entra a ningún lado de esta factura.
--   · base_ii          → neto + los cargos GRAVADOS con `afecta_base_ii`. El
--     filtro por condición es deliberado, no un olvido: el flag existe para
--     distinguir un descuento de precio (baja la base) de una bonificación
--     comercial (no la baja), y las dos son siempre gravadas. Un cargo no gravado
--     —pallets, separadores— no tiene por qué mover la base del impuesto interno.
--     Mismo filtro en prorrateoCompra.ts; si cambiás uno, cambiá el otro.
--
-- Y los cargos NO gravados que prorratean NO entran a `base_costo`: van aparte en
-- `cargos_al_costo` y se suman recién en `costo_real`. Meterlos en las dos los
-- CONTARÍA DOS VECES. (Este error exacto estuvo escrito en un comentario del TS.)
--
-- El IVA sale de `base_iva_factura`, NUNCA de `base_costo`.
--
-- Sumar el neto de las líneas exentas o no gravadas a `base_iva_factura` la
-- convierte en "neto de la factura" y deja de cuadrar contra el papel: por eso el
-- CASE mira `es_gravada` y devuelve 0, no el neto.
--
-- Son DOS totales de no gravado y no uno: `no_gravado` son los cargos EN FACTURA
-- (van a compras.no_gravado y al cuadre) y `cargos_al_costo` son los que
-- PRORRATEAN. Un cargo que está en el papel pero no es costo del producto —el
-- caso pallets— desaparece si se mezclan.
--
-- `cargos_al_costo` reconcilia contra Σ (cargos_unitarios × cantidad) SÓLO si
-- toda línea tiene cantidad > 0 y todo peso apunta a una línea de `p_items`. Las
-- dos excepciones son reales y ninguna se puede tapar acá. Con cantidad = 0 —que
-- este mismo archivo declara legal— el unitario se fuerza a 0 y el cargo no
-- vuelve a salir por ningún lado. Y un peso que apunta a un id que no está en
-- `p_items` es peor: `prorratear_cargo` lo reparte igual, pero ese pedazo no
-- matchea ninguna línea en `bases`, así que el cargo se EVAPORA del costo aunque
-- siga contado en el total. Acá no hay con qué atajarlo, porque `p_items` puede
-- ser legítimamente un subconjunto de la compra. LA RPC DE LA 192 TIENE QUE
-- VALIDAR que todos los pesos de un cargo apunten a líneas reales de la compra:
-- ése es el lugar correcto, no éste.
--
-- LA TASA DE II SE NORMALIZA CON round(tasa, 4) EN LAS DOS PUNTAS: al agrupar el
-- denominador y al buscar el factor. Nada de tolerancia en una y clave exacta en
-- la otra — una línea que entrara al denominador por tolerancia pero no matcheara
-- exacto se llevaría factor 1 y el total dejaría de cuadrar. En compra_items ya
-- conviven 4.1667 y 4.1700 (alguien tipeó 4,17), así que es un caso real. Que
-- queden en buckets distintos ES LO CORRECTO: si la factura declara un solo
-- bucket y hay una línea en 4,17, el cuadre tiene que avisar.
--
-- Una asimetría del TS que se replica a propósito, no por descuido: el
-- DENOMINADOR del factor usa la tasa declarada YA REDONDEADA, mientras que el II
-- de cada línea se calcula con la tasa CRUDA de la línea y sólo BUSCA el factor
-- por el bucket redondeado. Con tasas de 4 decimales o menos —todas las reales—
-- las dos coinciden; se replica igual para que el espejo sea espejo.
--
-- El factor se calcula ANTES de imputar el II a las líneas: por eso `factores`
-- es una CTE aparte y `finales` la consulta.
--
-- cantidad = 0 ⇒ todos los unitarios en 0, no una división. Y los unitarios se
-- derivan del total de la línea, nunca al revés.
--
-- POR QUÉ NO LLAMA A costo_real_unitario, que es la pregunta obvia: porque no hay
-- forma honesta de hacerlo. (a) Esta función no tiene `tipo_factura` —el modelo
-- de cargos vive en el mundo FC, donde la línea tiene condición frente al IVA—
-- así que no habría qué pasarle al 3º argumento. (b) El término de II es
-- estructuralmente distinto: acá es `base_ii × tasa × factor_de_ajuste`, y
-- costo_real_unitario sólo sabe hacer `neto × tasa`; no puede expresar ni la base
-- separada ni el factor. (c) La única llamada que compilaría sería con
-- `p_pct_ii = 0`, y con la tasa en 0 las DOS ramas del CASE dan lo mismo: la
-- regla de ZZ no se aplicaría sola, se saltearía. Una llamada que parece reuso y
-- no lo es sería peor que no llamarla.
-- Lo que SÍ se reusa —y es lo que importa— es `prorratear_cargo`: el reparto de
-- cada cargo sale de una sola implementación, igual que en el TS.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calcular_costos_compra(
  p_items        jsonb,
  p_cargos       jsonb DEFAULT '[]'::jsonb,
  p_ii_declarado jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path TO 'public'
AS $motor$
DECLARE
  v_id     text;
  v_motivo text;
  v_val    jsonb;
  v_res    jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'calcular_costos_compra: p_items tiene que ser un array y llego %.',
      COALESCE(jsonb_typeof(p_items), 'NULL') USING ERRCODE = '22023';
  END IF;
  -- Se NORMALIZA primero y se valida después. Whitelistear 'null' en el
  -- validador y confiar en un COALESCE más abajo no alcanza: COALESCE sólo tapa
  -- el NULL de SQL, y `COALESCE('null'::jsonb, '[]'::jsonb)` devuelve el escalar
  -- JSON null, no el array vacío. El validador dejaba pasar ese caso y después
  -- jsonb_array_elements moría con "cannot extract elements from a scalar", que
  -- no nombra ni la función ni el argumento — justo lo que estos IF vienen a
  -- evitar. Ausente ≡ JSON null ≡ vacío; cualquier otra forma es error.
  IF p_cargos IS NULL OR jsonb_typeof(p_cargos) = 'null' THEN
    p_cargos := '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_cargos) <> 'array' THEN
    RAISE EXCEPTION 'calcular_costos_compra: p_cargos tiene que ser un array y llego %.',
      jsonb_typeof(p_cargos) USING ERRCODE = '22023';
  END IF;

  IF p_ii_declarado IS NULL OR jsonb_typeof(p_ii_declarado) = 'null' THEN
    p_ii_declarado := '{}'::jsonb;
  END IF;
  IF jsonb_typeof(p_ii_declarado) <> 'object' THEN
    RAISE EXCEPTION 'calcular_costos_compra: p_ii_declarado tiene que ser un objeto {tasa: monto} y llego %.',
      jsonb_typeof(p_ii_declarado) USING ERRCODE = '22023';
  END IF;

  -- Mismo contrato que el TS: la cantidad 0 es válida (una línea recién agregada),
  -- la negativa y la no finita son corrupción. Sin esto la línea devolvía 0 en
  -- cada unitario mientras el total sumaba el neto igual, y el dato corrupto
  -- pasaba de largo. El CASE fuerza el orden de evaluación: sin él el planner
  -- puede correr el cast antes del chequeo de tipo y reventar con otro mensaje.
  -- El COALESCE sobre jsonb_typeof NO es decorativo: con la clave `cantidad`
  -- AUSENTE, jsonb_typeof devuelve NULL de SQL, y `NULL <> 'number'` es NULL, no
  -- true. Sin el COALESCE el CASE caía al ELSE, donde `NULL::numeric < 0` también
  -- da NULL, la fila no entraba al WHERE y el guard NO disparaba — dejando pasar
  -- exactamente el caso que viene a atajar. Y aguas abajo el daño es el peor de
  -- todos: cantidad NULL ⇒ neto NULL ⇒ los unitarios caen al ELSE 0, y como sum()
  -- saltea los NULL, la línea DESAPARECE de los totales sin un solo aviso.
  -- El golden no lo ve porque siempre manda `cantidad`.
  SELECT e->>'id', e->'cantidad' INTO v_id, v_val
    FROM jsonb_array_elements(p_items) e
   WHERE CASE WHEN COALESCE(jsonb_typeof(e->'cantidad'), 'ausente') <> 'number' THEN true
              ELSE (e->>'cantidad')::numeric < 0 END
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'calcular_costos_compra: cantidad invalida en la linea % (%). Se espera un numero finito no negativo.',
      COALESCE(v_id, '?'), COALESCE(v_val::text, 'null') USING ERRCODE = '22023';
  END IF;

  -- El id de la línea, con el mismo criterio que las claves de p_pesos y por el
  -- mismo motivo. Sin esto una línea sin `id` salía con "id": null y sin UN SOLO
  -- cargo —ningún peso matchea contra NULL— en silencio. Y la forma no canónica
  -- importa todavía más acá: si '01' y '1' conviven, el guard de duplicados de
  -- más abajo NO los ve, porque agrupa por el TEXTO de la clave, y las dos filas
  -- terminan cobrando el mismo cargo.
  SELECT COALESCE(e->>'id', '(ausente)'),
         CASE WHEN e->>'id' IS NULL
                THEN 'falta, y sin id la linea no recibe NINGUN cargo porque ningun peso matchea contra NULL'
              WHEN e->>'id' !~ '^-?[0-9]+$' THEN 'no es un id de linea'
              WHEN (e->>'id')::numeric NOT BETWEEN -9223372036854775808
                                               AND  9223372036854775807
                THEN 'se sale del rango de bigint'
              ELSE 'no esta en forma canonica (como "01" o "-0"), y dos ids que castean al mismo bigint cuentan la linea dos veces'
         END
    INTO v_id, v_motivo
    FROM jsonb_array_elements(p_items) e
   WHERE CASE WHEN e->>'id' IS NULL THEN true
              WHEN e->>'id' !~ '^-?[0-9]+$' THEN true
              WHEN (e->>'id')::numeric NOT BETWEEN -9223372036854775808
                                               AND  9223372036854775807 THEN true
              ELSE e->>'id' <> ((e->>'id')::bigint)::text
         END
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'calcular_costos_compra: el id de linea "%" %.', v_id, v_motivo
      USING ERRCODE = '22023';
  END IF;

  -- Guarda que el TS NO tiene, y va igual: dos líneas con el mismo id hacen que
  -- el reparto de un cargo se cuente una vez por cada una. Desde compra_items es
  -- imposible (id es PK), desde un payload de RPC no. Duplicar plata en silencio
  -- es peor que fallar; anotado para que el espejo TS lo copie en la task 9.
  SELECT e->>'id' INTO v_id
    FROM jsonb_array_elements(p_items) e
   GROUP BY e->>'id' HAVING count(*) > 1
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'calcular_costos_compra: la linea % aparece mas de una vez.', v_id
      USING ERRCODE = '22023';
  END IF;

  -- `condicion_iva` contra el dominio que ya define la 192. Un typo NO es
  -- inocuo y no es teórico: medido, una línea de mil pesos con "gravada" en vez
  -- de "gravado" devuelve neto_gravado 0, neto_exento 0, neto_no_gravado 0 e
  -- iva 0 — la plata desaparece de los cuatro totales A LA VEZ y no hay un solo
  -- error. El CASE de `es_gravada` y los dos de exento/no_gravado son
  -- excluyentes, así que un valor que no es ninguno de los tres cae en el hueco.
  -- Misma vara que el id duplicado: fallar antes que evaporar plata.
  SELECT e->>'id', e->'condicion_iva' INTO v_id, v_val
    FROM jsonb_array_elements(p_items) e
   WHERE COALESCE(e->>'condicion_iva', 'gravado')
         NOT IN ('gravado', 'exento', 'no_gravado')
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'calcular_costos_compra: condicion_iva invalida en la linea % (%). Se espera gravado, exento o no_gravado.',
      COALESCE(v_id, '?'), COALESCE(v_val::text, 'null') USING ERRCODE = '22023';
  END IF;

  -- Lo mismo del lado del cargo, donde el hueco es distinto pero igual de mudo:
  -- `gravado` sale de comparar contra 'gravado', así que cualquier typo cae en
  -- la rama NO gravada y el cargo deja de sumar a la base de IVA sin avisar. Se
  -- lo nombra por posición y concepto porque el cargo puede no tener id todavía
  -- (viene de una grilla a medio llenar).
  SELECT format('%s (%s)', c.ord, COALESCE(c.val->>'concepto', 'sin concepto')),
         c.val->'condicion_iva'
    INTO v_id, v_val
    FROM jsonb_array_elements(p_cargos) WITH ORDINALITY AS c(val, ord)
   WHERE COALESCE(c.val->>'condicion_iva', 'no_gravado')
         NOT IN ('gravado', 'exento', 'no_gravado')
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'calcular_costos_compra: condicion_iva invalida en el cargo % (%). Se espera gravado, exento o no_gravado.',
      v_id, COALESCE(v_val::text, 'null') USING ERRCODE = '22023';
  END IF;

  -- Las claves de p_ii_declarado son tasas. Sin esto '{"pallet":10}' tiraba un
  -- 22P02 crudo desde el cast, asimétrico con todo el cuidado que se le puso a
  -- `p_pesos` tres funciones más arriba.
  SELECT d.key INTO v_id
    FROM jsonb_each(p_ii_declarado) d
   WHERE d.key !~ '^[0-9]+(\.[0-9]+)?$'
   ORDER BY d.key
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RAISE EXCEPTION 'calcular_costos_compra: la clave "%" de p_ii_declarado no es una tasa de impuesto interno.', v_id
      USING ERRCODE = '22023';
  END IF;

  -- Y el MONTO declarado tiene que ser un número. Esto no es cosmético: con un
  -- monto null, `factor_ajuste` REPORTABA null mientras `finales` APLICABA 1 por
  -- su COALESCE(...,1). O sea que el número que va al cuadre contradecía al
  -- cálculo que lo produjo, y encima el TS en ese caso da factor 0 y II 0. De
  -- las tres respuestas posibles la única defendible es no aceptar la entrada:
  -- un monto declarado que no es un número no es un cero, es un dato que falta.
  SELECT d.key, d.value INTO v_id, v_val
    FROM jsonb_each(p_ii_declarado) d
   WHERE jsonb_typeof(d.value) <> 'number'
   ORDER BY d.key
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'calcular_costos_compra: el monto declarado para la tasa % no es un numero (%).',
      v_id, COALESCE(v_val::text, 'null') USING ERRCODE = '22023';
  END IF;

  -- Dos claves declaradas que colapsan al MISMO bucket de 4 decimales ('10' y
  -- '10.0', o '4.1667' y '04.1667') hacían que el subselect escalar de `finales`
  -- devolviera dos filas y Postgres tirara 'more than one row returned by a
  -- subquery', que no nombra ni la función ni las claves culpables. Simétrico
  -- con el guard de id duplicado, y con el mismo criterio: nombrar a los dos.
  SELECT string_agg(d.key, '" y "' ORDER BY d.key) INTO v_id
    FROM jsonb_each_text(p_ii_declarado) d
   GROUP BY round((d.key)::numeric, 4)
  HAVING count(*) > 1
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RAISE EXCEPTION 'calcular_costos_compra: las tasas declaradas "%" caen en el mismo bucket de 4 decimales y se pisarian.', v_id
      USING ERRCODE = '22023';
  END IF;

  WITH items AS (
    SELECT (e->>'id')::bigint                                  AS id,
           (e->>'cantidad')::numeric                           AS cantidad,
           COALESCE((e->>'costo_unitario')::numeric, 0)        AS costo_unitario,
           COALESCE((e->>'bonificacion')::numeric, 0)          AS bonificacion,
           COALESCE((e->>'impuestos_internos')::numeric, 0)    AS ii_tasa,
           COALESCE((e->>'porcentaje_iva')::numeric, 0)        AS pct_iva,
           COALESCE(e->>'condicion_iva', 'gravado')            AS condicion_iva
      FROM jsonb_array_elements(p_items) e
  ),
  cargos AS (
    SELECT COALESCE((e->>'monto')::numeric, 0)                 AS monto,
           COALESCE(e->>'condicion_iva', 'no_gravado') = 'gravado' AS gravado,
           COALESCE((e->>'en_factura')::boolean, true)         AS en_factura,
           COALESCE((e->>'prorratea_al_costo')::boolean, true) AS prorratea_al_costo,
           COALESCE((e->>'afecta_base_ii')::boolean, false)    AS afecta_base_ii,
           e->'pesos'                                          AS pesos
      FROM jsonb_array_elements(p_cargos) e   -- ya normalizado arriba
  ),
  -- Una sola implementación del reparto, la misma que alimenta la vista previa.
  repartos AS (
    SELECT c.gravado, c.en_factura, c.prorratea_al_costo, c.afecta_base_ii,
           r.item_id, r.monto
      FROM cargos c
      CROSS JOIN LATERAL prorratear_cargo(c.monto, c.pesos) r
  ),
  bases AS (
    SELECT i.id, i.cantidad, i.ii_tasa, i.pct_iva, i.condicion_iva,
           i.cantidad * i.costo_unitario * (1 - i.bonificacion / 100) AS neto,
           (i.condicion_iva = 'gravado')                              AS es_gravada,
           COALESCE((SELECT sum(r.monto) FROM repartos r
                      WHERE r.item_id = i.id AND r.gravado AND r.en_factura), 0)
             AS cargos_gravados_factura,
           COALESCE((SELECT sum(r.monto) FROM repartos r
                      WHERE r.item_id = i.id AND r.gravado AND r.prorratea_al_costo), 0)
             AS cargos_gravados_costo,
           COALESCE((SELECT sum(r.monto) FROM repartos r
                      WHERE r.item_id = i.id AND r.gravado AND r.afecta_base_ii), 0)
             AS cargos_base_ii,
           COALESCE((SELECT sum(r.monto) FROM repartos r
                      WHERE r.item_id = i.id AND NOT r.gravado AND r.en_factura), 0)
             AS no_gravado_factura,
           COALESCE((SELECT sum(r.monto) FROM repartos r
                      WHERE r.item_id = i.id AND NOT r.gravado AND r.prorratea_al_costo), 0)
             AS cargos_al_costo
      FROM items i
  ),
  con_bases AS (
    SELECT b.*,
           CASE WHEN b.es_gravada THEN b.neto + b.cargos_gravados_factura ELSE 0 END
             AS base_iva_factura,
           b.neto + b.cargos_gravados_costo AS base_costo,
           b.neto + b.cargos_base_ii        AS base_ii,
           round(b.ii_tasa, 4)              AS bucket
      FROM bases b
  ),
  factores AS (
    SELECT round((d.key)::numeric, 4) AS tasa,
           CASE WHEN x.calculado IS NULL OR x.calculado = 0 THEN 1
                ELSE (d.value)::numeric / x.calculado END AS factor
      FROM jsonb_each_text(p_ii_declarado) d   -- ya normalizado arriba
      CROSS JOIN LATERAL (
        SELECT sum(c.base_ii * round((d.key)::numeric, 4) / 100) AS calculado
          FROM con_bases c
         WHERE c.bucket = round((d.key)::numeric, 4)
      ) x
  ),
  finales AS (
    SELECT c.*,
           c.base_ii * c.ii_tasa / 100
             * COALESCE((SELECT f.factor FROM factores f WHERE f.tasa = c.bucket), 1) AS ii,
           c.base_iva_factura * c.pct_iva / 100 AS iva
      FROM con_bases c
  )
  SELECT jsonb_build_object(
    'lineas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id',         f.id,
               'base_iva',   CASE WHEN f.cantidad > 0 THEN f.base_iva_factura / f.cantidad ELSE 0 END,
               'ii',         CASE WHEN f.cantidad > 0 THEN f.ii              / f.cantidad ELSE 0 END,
               'cargos',     CASE WHEN f.cantidad > 0 THEN f.cargos_al_costo / f.cantidad ELSE 0 END,
               'iva',        CASE WHEN f.cantidad > 0 THEN f.iva             / f.cantidad ELSE 0 END,
               'costo_neto', CASE WHEN f.cantidad > 0 THEN f.neto            / f.cantidad ELSE 0 END,
               'costo_real', CASE WHEN f.cantidad > 0
                                  THEN (f.base_costo + f.ii + f.cargos_al_costo) / f.cantidad
                                  ELSE 0 END
             ) ORDER BY f.id) FROM finales f), '[]'::jsonb),
    'totales', (SELECT jsonb_build_object(
         'neto_gravado',       COALESCE(sum(CASE WHEN f.es_gravada THEN f.neto ELSE 0 END
                                            + f.cargos_gravados_factura), 0),
         'neto_exento',        COALESCE(sum(CASE WHEN f.condicion_iva = 'exento'     THEN f.neto ELSE 0 END), 0),
         'neto_no_gravado',    COALESCE(sum(CASE WHEN f.condicion_iva = 'no_gravado' THEN f.neto ELSE 0 END), 0),
         'iva',                COALESCE(sum(f.iva), 0),
         'impuestos_internos', COALESCE(sum(f.ii), 0),
         'no_gravado',         COALESCE(sum(f.no_gravado_factura), 0),
         'cargos_al_costo',    COALESCE(sum(f.cargos_al_costo), 0)
       ) FROM finales f),
    -- trim_scale para que la clave sea '10' y no '10.0000': el espejo de JS usa
    -- el número como clave y no arrastra ceros de relleno.
    'factor_ajuste', COALESCE((
      SELECT jsonb_object_agg(trim_scale(f.tasa)::text, f.factor) FROM factores f), '{}'::jsonb)
  ) INTO v_res;

  RETURN v_res;
END;
$motor$;

COMMENT ON FUNCTION public.calcular_costos_compra(jsonb, jsonb, jsonb) IS
  'Motor de costos de una compra: reparte los cargos, arma las tres bases '
  '(base_iva_factura para el cuadre contra el papel, base_costo para el costo, '
  'base_ii para el impuesto interno), ajusta el II al declarado por alicuota y '
  'devuelve los unitarios por linea mas los totales. Espejo exacto de '
  'calcularCostosCompra() en src/utils/prorrateoCompra.ts, verificado contra la '
  'factura testigo A0005-00461415 campo por campo (mig 193). Los cargos NO '
  'gravados que prorratean NO estan en base_costo: van en cargos_al_costo y se '
  'suman una sola vez en costo_real.';

REVOKE ALL ON FUNCTION public.calcular_costos_compra(jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.calcular_costos_compra(jsonb, jsonb, jsonb) TO authenticated, service_role;

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
--   -- 1 y 3 · no escriben nada: dropearlos es exacto.
--   DROP FUNCTION IF EXISTS public.prorratear_cargo(numeric, jsonb);
--   DROP FUNCTION IF EXISTS public.calcular_costos_compra(jsonb, jsonb, jsonb);
--
--   -- 2 · costo_real_unitario. NO alcanza con recrear la de 3 argumentos: hay
--   --     que despatchar los tres llamadores en la MISMA transacción, o quedan
--   --     llamando a una firma que ya no existe y la compra deja de registrarse.
--   -- ⚠ EL DROP + CREATE HACE UNA FUNCIÓN NUEVA, que nace con los privilegios
--   -- por defecto del rol que corra el rollback. Sin las dos últimas líneas de
--   -- este bloque, seguir el recipe al pie DESHACE EN SILENCIO lo que hicieron
--   -- las migs 188/189 —se midió que así queda un `=X/postgres`, o sea PUBLIC
--   -- adentro— y pone en rojo el gate de permisos de CI. Un rollback no puede
--   -- reabrir una superficie que otra migración cerró.
--   --
--   -- `PARALLEL SAFE` va explícito por lo mismo: sin repetirlo se pierde. Ojo
--   -- que la de 3 argumentos ORIGINAL era PARALLEL UNSAFE (el default), así que
--   -- esto no restaura el estado previo al 100%: es deliberado. Volver a marcar
--   -- UNSAFE una función de aritmética pura sería restaurar una pesimización,
--   -- no una garantía; lo que el rollback tiene que devolver es la FIRMA.
--   BEGIN;
--     DROP FUNCTION IF EXISTS public.costo_real_unitario(numeric, numeric, text, numeric);
--     CREATE OR REPLACE FUNCTION public.costo_real_unitario(
--       p_costo_neto numeric, p_pct_ii numeric, p_tipo_factura text
--     ) RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $r$
--       SELECT CASE
--         WHEN p_tipo_factura = 'ZZ' THEN p_costo_neto
--         ELSE round(p_costo_neto * (1 + COALESCE(p_pct_ii, 0) / 100), 4)
--       END;
--     $r$;
--     REVOKE ALL ON FUNCTION public.costo_real_unitario(numeric, numeric, text)
--       FROM PUBLIC, anon;
--     GRANT EXECUTE ON FUNCTION public.costo_real_unitario(numeric, numeric, text)
--       TO authenticated, service_role;
--     DO $r$
--     DECLARE v_def text; v_fn text;
--     BEGIN
--       FOREACH v_fn IN ARRAY ARRAY[
--         'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric)',
--         'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric)',
--         'public.anular_compra_atomica(bigint,uuid)']
--       LOOP
--         v_def := pg_get_functiondef(v_fn::regprocedure);
--         EXECUTE replace(v_def,
--           ', 0 /* mig 193: los cargos entran en la task 9 */)', ')');
--       END LOOP;
--     END $r$;
--   COMMIT;
--
-- Exacto mientras el 4º argumento siga en 0 en todos lados: ningún costo se
-- movió. Deja de serlo en cuanto la task 9 empiece a pasar cargos de verdad —
-- ahí el rollback pasa a ser el de la 192, con recálculo de costos y CPP.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Pendientes deliberados (revisados y postergados, no olvidados)
--
--   · Las SEIS subconsultas correlacionadas de `bases` colapsan en un solo
--     `LEFT JOIN LATERAL` con seis `sum() FILTER (...)`. Es la misma cuenta con
--     un barrido en vez de seis. No se hace acá porque cambia la forma del plan
--     y este archivo ya se verificó campo por campo contra el golden; va con su
--     propia comparación de 126 celdas.
--   · `costo_real_unitario` no tiene `SET search_path`. Las otras dos de este
--     archivo sí. Es LANGUAGE sql y no referencia nada por nombre no calificado,
--     así que hoy no es explotable, pero la asimetría no tiene defensa.
--   · `src/utils/prorrateoCompra.espejo.test.ts` — el test que corre los mismos
--     casos contra las dos implementaciones y falla si divergen. El plan lo
--     menciona y no existe: hoy el espejo lo sostiene un ensayo manual. Va
--     aparte porque es TypeScript, no SQL.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Verificación
--
--   -- Reparto proporcional, y el residuo en la linea de mayor peso:
--   SELECT * FROM prorratear_cargo(100, '{"1":1,"2":1,"3":4}'::jsonb);
--   -- 1 | 16.67
--   -- 2 | 16.67
--   -- 3 | 66.66     <- absorbe el residuo
--
--   -- La suma es el monto exacto, sobre el flete real de la factura testigo:
--   SELECT sum(monto) FROM prorratear_cargo(1900000,
--     '{"1":0.5,"2":0.5,"3":2,"4":0.5,"5":0.5,"6":1,"7":1,"8":2,"9":1,"10":2,
--       "11":4,"12":1,"13":1,"14":2,"15":1,"16":1,"17":1,"18":1,"19":1,"20":1,"21":1}');
--   -- 1900000.00   (y la linea 11 se lleva 292307.72, tres centavos sobre el proporcional)
--
--   -- El peso 0 excluye, el vector vacio no explota:
--   SELECT * FROM prorratear_cargo(880, '{"1":0,"2":0,"3":1}');  -- 1|0  2|0  3|880.00
--   SELECT count(*) FROM prorratear_cargo(100, '{}');            -- 0
--
--   -- Y la basura no pasa (las cuatro tienen que fallar). La segunda va con
--   -- subselect porque un agregado no puede ir suelto en el FROM:
--   SELECT * FROM prorratear_cargo(100, '{"1":1,"2":-1}');       -- peso negativo en la linea 2
--   SELECT * FROM prorratear_cargo(100, (SELECT jsonb_object_agg('1','NaN'::numeric)));
--                                                                -- peso no finito en la linea 1
--   SELECT * FROM prorratear_cargo(NULL, '{"1":1}');             -- monto no finito
--   SELECT * FROM prorratear_cargo(100, '{"pallet":1}');         -- la clave no es un id de linea
--
--   -- Y que anon NO quedó con EXECUTE (el ACL no puede nombrarlo):
--   SELECT array_to_string(proacl, ' ') FROM pg_proc WHERE proname = 'prorratear_cargo';
--   -- postgres=X/postgres authenticated=X/postgres service_role=X/postgres
--
--   -- 2 · UNA sola firma de costo_real_unitario, y con 4 argumentos. Si esto
--   --     devuelve dos filas, PostgREST tira PGRST203 en runtime y no lo ve ni
--   --     tsc ni los tests:
--   SELECT proname, pronargs, array_to_string(proacl,' ')
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND proname = 'costo_real_unitario';
--   -- costo_real_unitario | 4 | postgres=X/postgres authenticated=X/postgres service_role=X/postgres
--
--   -- Los tres llamadores parchados, y el cuarto que no había que tocar:
--   SELECT proname,
--          (position('mig 193' in prosrc) > 0)              AS parchado,
--          (length(prosrc)-length(replace(prosrc,'costo_real_unitario(','')))
--            / length('costo_real_unitario(')               AS llamadas
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND proname IN ('registrar_compra_completa','actualizar_compra_items',
--                      'anular_compra_atomica','cambiar_proveedor_compra');
--   -- actualizar_compra_items   | t | 1
--   -- anular_compra_atomica     | t | 1
--   -- cambiar_proveedor_compra  | f | 0   <- no la llama: copia la columna
--   -- registrar_compra_completa | t | 1
--
--   -- La regla de ZZ, en dos renglones: el II no suma, el cargo sí.
--   SELECT costo_real_unitario(1000, 8.6956, 'ZZ', 0)   AS zz_sin_cargo,   -- 1000.0000
--          costo_real_unitario(1000, 8.6956, 'ZZ', 50)  AS zz_con_cargo,   -- 1050.0000
--          costo_real_unitario(1000, 8.6956, 'FC', 0)   AS fc_sin_cargo,   -- 1086.9560
--          costo_real_unitario(1000, 8.6956, 'FC', 50)  AS fc_con_cargo;   -- 1136.9560
--
--   -- Que el round nuevo de la rama ZZ no mueva ninguna línea existente
--   -- (0 = ninguna; hoy ninguna ZZ tiene bonificación, así que su neto ya venía
--   -- con 2 decimales):
--   SELECT count(*) FILTER (
--            WHERE ci.costo_unitario * (1 - COALESCE(ci.bonificacion,0)/100)
--               <> round(ci.costo_unitario * (1 - COALESCE(ci.bonificacion,0)/100), 4))
--     FROM compra_items ci JOIN compras c ON c.id = ci.compra_id
--    WHERE c.tipo_factura = 'ZZ';                              -- 0 sobre 109 líneas
--
--   -- Y que el andamiaje no quedó vivo:
--   SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND proname LIKE '\_mig193%';   -- 0
--
--   -- 3 · el motor de costos, sobre un caso mínimo: una línea gravada de 10 x 100
--   --     con un flete no gravado de 500 que prorratea al costo.
--   SELECT jsonb_pretty(calcular_costos_compra(
--     '[{"id":1,"cantidad":10,"costo_unitario":100,"bonificacion":0,
--        "impuestos_internos":0,"porcentaje_iva":21,"condicion_iva":"gravado"}]',
--     '[{"id":1,"monto":500,"condicion_iva":"no_gravado","en_factura":true,
--        "prorratea_al_costo":true,"afecta_base_ii":false,"pesos":{"1":1}}]',
--     '{}'));
--   -- lineas[0]: base_iva 100 · iva 21 · cargos 50 · costo_neto 100 · costo_real 150
--   -- El cargo NO gravado entra al costo pero NO a la base de IVA: el IVA es 21
--   -- (21% de 100), no 31,50. Y costo_real lo cuenta UNA sola vez.
--
--   -- El caso pallets, que separa los dos totales de no gravado: en el papel
--   -- pero no es costo del producto.
--   SELECT calcular_costos_compra(
--     '[{"id":1,"cantidad":10,"costo_unitario":100,"porcentaje_iva":21,"condicion_iva":"gravado"}]',
--     '[{"id":1,"monto":500,"condicion_iva":"no_gravado","en_factura":true,
--        "prorratea_al_costo":false,"pesos":{"1":1}}]')->'totales';
--   -- no_gravado 500 (cuadra contra el papel) · cargos_al_costo 0 (no reconcilia
--   -- contra ningún costo). Si se mezclaran, este cargo desaparecería.
--
--   -- Y que 4,17 y 4,1667 caen en buckets distintos: la línea tipeada a mano NO
--   -- se ajusta, y eso es el detector avisando, no un falso positivo.
--   SELECT calcular_costos_compra(
--     '[{"id":1,"cantidad":10,"costo_unitario":100,"impuestos_internos":4.1667,"porcentaje_iva":21},
--       {"id":2,"cantidad":10,"costo_unitario":100,"impuestos_internos":4.17,"porcentaje_iva":21}]',
--     '[]', '{"4.1667": 50}')->'factor_ajuste';
--   -- {"4.1667": 1.199990400076799385604915}  <- sólo el bucket declarado; el 4.17 no
--   -- aparece. El valor va COMPLETO a propósito: decía "1.2000..." y no es un
--   -- 1,2 truncado, es 1,19999… — la elipsis redondeaba para arriba y escondía
--   -- que el factor NO es 1,2. En un archivo cuyo punto es que el factor da 1,
--   -- una elipsis que miente en el cuarto decimal no es un detalle.
--
--   -- ── Los guards, que tienen que fallar los seis ────────────────────────────
--   -- Cero a la izquierda: '01' y '1' son la MISMA línea y cobrarían dos veces.
--   SELECT * FROM prorratear_cargo(100, '{"1":1,"01":1}');
--   -- la clave "01" no esta en forma canonica...
--   SELECT * FROM prorratear_cargo(100, '{"999999999999999999999":1}');
--   -- la clave "999999999999999999999" se sale del rango de bigint
--
--   -- condicion_iva con un typo: mil pesos que se evaporaban sin un error.
--   SELECT calcular_costos_compra(
--     '[{"id":1,"cantidad":10,"costo_unitario":100,"condicion_iva":"gravada"}]');
--   -- condicion_iva invalida en la linea 1 ("gravada")
--
--   -- Monto declarado nulo: reportaba factor null y aplicaba 1.
--   SELECT calcular_costos_compra(
--     '[{"id":1,"cantidad":10,"costo_unitario":100,"impuestos_internos":10}]',
--     '[]', '{"10": null}');
--   -- el monto declarado para la tasa 10 no es un numero (null)
--
--   -- Dos claves que colapsan al mismo bucket: antes era "more than one row
--   -- returned by a subquery", que no nombraba a ninguna de las dos.
--   SELECT calcular_costos_compra(
--     '[{"id":1,"cantidad":10,"costo_unitario":100,"impuestos_internos":10}]',
--     '[]', '{"10":50,"10.0":60}');
--   -- las tasas declaradas "10" y "10.0" caen en el mismo bucket de 4 decimales
--
--   -- Y una clave de tasa que no es una tasa: antes, un 22P02 crudo.
--   SELECT calcular_costos_compra('[]', '[]', '{"pallet":10}');
--   -- la clave "pallet" de p_ii_declarado no es una tasa de impuesto interno
-- ----------------------------------------------------------------------------
