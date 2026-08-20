-- ============================================================================
-- 196 · El espejo entre las dos implementaciones del motor de compras
-- ============================================================================
-- Ver docs/archive/2026-08-18-cargos-y-cuadre-de-compras.md y la mig 193.
--
-- EL PROBLEMA. El motor de costos de una compra está escrito DOS veces:
--
--   · `src/utils/prorrateoCompra.ts` — alimenta la vista previa del modal, que
--     tiene que anticipar el costo sin ir a la base.
--   · `prorratear_cargo` / `calcular_costos_compra` (mig 193) — la canónica: lo
--     que se PERSISTE sale de acá.
--
-- Las dos se verificaron a mano contra la factura testigo A0005-00461415 —126
-- celdas y 22 repartos, cero divergencias— y los dos archivos dicen "si cambiás
-- una, cambiá la otra". Eso es una frase, no una garantía: si mañana alguien
-- toca un lado, nadie se entera hasta que un costo sale mal en producción.
--
-- LO QUE HACE ESTA FUNCIÓN. Recibe un lote de casos con la entrada en jsonb y la
-- salida que dio el motor de TypeScript, corre el motor de SQL sobre la MISMA
-- entrada y devuelve las celdas en las que los dos no dicen lo mismo. Es el
-- corazón de `scripts/espejo-motor-compras.mjs`, que corre en el gate de
-- integridad —el único lugar del proyecto con credenciales de servicio— y sale
-- con 1 ante cualquier divergencia.
--
-- POR QUÉ LA COMPARACIÓN LA HACE POSTGRES Y NO EL SCRIPT. Porque de este lado
-- los números son `numeric` —decimal exacto— y del otro son `double`. Comparar
-- en JavaScript obligaría a bajar el numeric a double primero, que es
-- exactamente la conversión que puede tapar la diferencia que se busca. Acá
-- `IS DISTINCT FROM` sobre numeric ignora la escala (500 y 500.00 son el mismo
-- número, que es lo correcto: nadie escribió mal nada) y no ignora un centavo.
--
-- POR QUÉ SE REDONDEA A `p_decimales` ANTES DE COMPARAR. El TS acumula en double
-- y sobre esta factura eso deja una discrepancia del orden de 1e-9 contra la
-- suma exacta de numeric. Comparar bit a bit haría fallar el espejo por el
-- formato de punto flotante y no por un bug, y un espejo que grita siempre no lo
-- mira nadie. El default de 6 decimales está tres órdenes arriba de ese ruido y
-- cuatro por debajo del centavo, que es la unidad que este espejo tiene que
-- cazar. La constante gemela está en `prorrateoCompra.espejo.ts`.
--
-- QUÉ ES UNA DIVERGENCIA. Tres cosas, y las tres cuentan igual:
--   · una celda con distinto valor;
--   · una celda que existe de un lado y no del otro (una línea de más, un total
--     que se dejó de emitir);
--   · que UNA SOLA de las dos implementaciones lance. Que las dos rechacen la
--     misma basura es la mitad del contrato: si el SQL lanza y el TS devuelve un
--     número, el modal le muestra al usuario un costo que la base va a rechazar.
--     El texto del mensaje NO se compara —el de SQL nombra la función en
--     snake_case y el de TS en camelCase— pero los dos viajan al reporte para
--     que un humano los lea.
--
-- ESTA FUNCIÓN NO TOCA NINGUNA TABLA. Es aritmética sobre sus argumentos, igual
-- que las dos que compara; se la marca STABLE y no IMMUTABLE sólo por el now()
-- del encabezado del reporte.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.espejo_motor_compras(
  p_casos     jsonb,
  p_decimales integer DEFAULT 6
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $espejo$
DECLARE
  v_caso        jsonb;
  v_nombre      text;
  v_motor       text;
  v_entrada     jsonb;
  v_ts_json     jsonb;
  v_ts_error    text;
  v_sql_json    jsonb;
  v_sql_error   text;
  v_divs        jsonb;
  v_celdas      integer;
  v_detalle     jsonb := '[]'::jsonb;
  v_tot_celdas  integer := 0;
  v_tot_divs    integer := 0;
  v_casos_rojos integer := 0;
BEGIN
  IF p_casos IS NULL OR jsonb_typeof(p_casos) <> 'array' THEN
    RAISE EXCEPTION 'espejo_motor_compras: p_casos tiene que ser un array y llego %.',
      COALESCE(jsonb_typeof(p_casos), 'NULL') USING ERRCODE = '22023';
  END IF;
  -- Un p_decimales absurdo no es un detalle: es la diferencia entre un espejo
  -- que mide y uno que dice que sí a cualquier cosa. 12 es el techo porque abajo
  -- de eso ya no hay señal, sólo el ruido del double.
  IF p_decimales IS NULL OR p_decimales < 0 OR p_decimales > 12 THEN
    RAISE EXCEPTION 'espejo_motor_compras: p_decimales fuera de rango (%). Se espera 0..12.',
      COALESCE(p_decimales::text, 'NULL') USING ERRCODE = '22023';
  END IF;

  FOR v_caso IN SELECT e FROM jsonb_array_elements(p_casos) e LOOP
    v_nombre    := COALESCE(v_caso->>'caso', '(sin nombre)');
    v_motor     := v_caso->>'motor';
    v_entrada   := COALESCE(v_caso->'entrada', '{}'::jsonb);
    v_ts_error  := v_caso->>'ts_error';
    v_ts_json   := CASE WHEN COALESCE(jsonb_typeof(v_caso->'ts'), 'null') = 'null'
                        THEN NULL ELSE v_caso->'ts' END;
    v_sql_json  := NULL;
    v_sql_error := NULL;

    -- Fuera del bloque con EXCEPTION a propósito: un motor mal escrito en el
    -- payload es un error del espejo, no una divergencia entre los motores, y
    -- tragárselo lo haría pasar por un caso que "coincidió".
    IF v_motor IS NULL OR v_motor NOT IN ('prorratear_cargo', 'calcular_costos_compra') THEN
      RAISE EXCEPTION 'espejo_motor_compras: motor desconocido "%" en el caso "%".',
        COALESCE(v_motor, 'null'), v_nombre USING ERRCODE = '22023';
    END IF;

    BEGIN
      IF v_motor = 'prorratear_cargo' THEN
        -- Se re-arma el objeto {id: monto} para que las dos salidas tengan la
        -- misma forma: el TS devuelve un Record y el SQL un conjunto de filas.
        -- Sin cargo repartido son 0 filas y `{}`, que es lo que devuelve el TS.
        SELECT COALESCE(jsonb_object_agg(r.item_id::text, r.monto), '{}'::jsonb)
          INTO v_sql_json
          FROM prorratear_cargo((v_entrada->>'monto')::numeric, v_entrada->'pesos') r;
      ELSE
        v_sql_json := calcular_costos_compra(
          v_entrada->'items', v_entrada->'cargos', v_entrada->'ii_declarado');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- El cast de `monto` a numeric también cae acá, y está bien: desde el
      -- punto de vista del contrato, "el SQL no acepta esta entrada" es el mismo
      -- hecho lo tire la función o lo tire el borde.
      v_sql_json  := NULL;
      v_sql_error := SQLERRM;
    END;

    IF v_ts_error IS NOT NULL OR v_sql_error IS NOT NULL THEN
      v_celdas := 0;
      v_divs := CASE
        WHEN v_ts_error IS NOT NULL AND v_sql_error IS NOT NULL THEN '[]'::jsonb
        WHEN v_ts_error IS NULL THEN jsonb_build_array(jsonb_build_object(
               'campo', '(contrato)',
               'motivo', 'el SQL rechazo la entrada y el TS la acepto',
               'ts', COALESCE(v_ts_json, 'null'::jsonb),
               'sql', to_jsonb(v_sql_error)))
        ELSE jsonb_build_array(jsonb_build_object(
               'campo', '(contrato)',
               'motivo', 'el TS rechazo la entrada y el SQL la acepto',
               'ts', to_jsonb(v_ts_error),
               'sql', COALESCE(v_sql_json, 'null'::jsonb)))
      END;
    ELSE
      -- Aplanado de los dos jsonb a `(ruta, valor)` y comparación celda por
      -- celda. La ruta se arma igual que en el espejo de JS —`.lineas[0].ii`—
      -- para que los dos reportes nombren el mismo campo con el mismo texto.
      --
      -- El FULL OUTER JOIN es el que atrapa la asimetría estructural: una clave
      -- que un lado dejó de emitir no es "igual a nada", es una divergencia.
      -- Un objeto o un array VACÍO no deja hoja, así que dos vacíos comparan 0
      -- celdas; por eso el reporte publica `celdas` y no sólo el veredicto.
      WITH RECURSIVE hojas(lado, ruta, valor) AS (
        SELECT o.lado, ''::text, o.j
          FROM (VALUES ('ts', v_ts_json), ('sql', v_sql_json)) AS o(lado, j)
        UNION ALL
        SELECT h.lado, h.ruta || e.paso, e.hijo
          FROM hojas h
          CROSS JOIN LATERAL (
            SELECT CASE WHEN jsonb_typeof(h.valor) = 'array'
                        THEN '[' || t.key || ']' ELSE '.' || t.key END AS paso,
                   t.value AS hijo
              FROM jsonb_each(
                     -- El array se vuelve objeto con el índice de clave: así una
                     -- sola rama recursiva cubre los dos contenedores (un CTE
                     -- recursivo no admite dos referencias a sí mismo). El ELSE
                     -- '{}' es el que corta en los escalares, y va acá adentro y
                     -- no en un WHERE porque el planner puede evaluar el LATERAL
                     -- antes que el filtro y reventar con "cannot call
                     -- jsonb_each on a scalar".
                     CASE jsonb_typeof(h.valor)
                       WHEN 'array' THEN (
                         SELECT COALESCE(jsonb_object_agg((a.i - 1)::text, a.v), '{}'::jsonb)
                           FROM jsonb_array_elements(h.valor) WITH ORDINALITY AS a(v, i))
                       WHEN 'object' THEN h.valor
                       ELSE '{}'::jsonb
                     END) AS t
          ) AS e
      ),
      planas AS (
        SELECT h.lado, h.ruta, h.valor
          FROM hojas h
         WHERE jsonb_typeof(h.valor) NOT IN ('object', 'array')
      ),
      pares AS (
        SELECT COALESCE(t.ruta, s.ruta) AS ruta,
               t.valor AS valor_ts, s.valor AS valor_sql,
               (t.ruta IS NOT NULL) AS en_ts, (s.ruta IS NOT NULL) AS en_sql
          FROM (SELECT ruta, valor FROM planas WHERE lado = 'ts')  t
          FULL OUTER JOIN
               (SELECT ruta, valor FROM planas WHERE lado = 'sql') s ON s.ruta = t.ruta
      )
      SELECT count(*)::integer,
             COALESCE(jsonb_agg(jsonb_build_object(
                        'campo', p.ruta,
                        'motivo', CASE WHEN NOT p.en_sql THEN 'falta en el SQL'
                                       WHEN NOT p.en_ts  THEN 'falta en el TS'
                                       ELSE 'difiere' END,
                        'ts',  COALESCE(p.valor_ts,  'null'::jsonb),
                        'sql', COALESCE(p.valor_sql, 'null'::jsonb))
                      ORDER BY p.ruta)
                      FILTER (WHERE
                        NOT p.en_ts OR NOT p.en_sql
                        OR CASE WHEN jsonb_typeof(p.valor_ts)  = 'number'
                                 AND jsonb_typeof(p.valor_sql) = 'number'
                                THEN round((p.valor_ts  #>> '{}')::numeric, p_decimales)
                                     IS DISTINCT FROM
                                     round((p.valor_sql #>> '{}')::numeric, p_decimales)
                                ELSE p.valor_ts IS DISTINCT FROM p.valor_sql
                           END),
                      '[]'::jsonb)
        INTO v_celdas, v_divs
        FROM pares p;
    END IF;

    v_tot_celdas := v_tot_celdas + COALESCE(v_celdas, 0);
    v_tot_divs   := v_tot_divs + jsonb_array_length(v_divs);
    IF jsonb_array_length(v_divs) > 0 THEN
      v_casos_rojos := v_casos_rojos + 1;
    END IF;

    v_detalle := v_detalle || jsonb_build_array(jsonb_build_object(
      'caso',         v_nombre,
      'motor',        v_motor,
      'origen',       v_caso->>'origen',
      'celdas',       COALESCE(v_celdas, 0),
      -- La salida del SQL viaja entera aunque el caso esté en verde: es la que
      -- `--fijar` congela como fixture de la capa 1.
      'sql',          v_sql_json,
      'sql_error',    v_sql_error,
      'ts_error',     v_ts_error,
      'divergencias', v_divs
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'generado_at',  now(),
    'decimales',    p_decimales,
    'casos',        jsonb_array_length(p_casos),
    'casos_rojos',  v_casos_rojos,
    'celdas',       v_tot_celdas,
    'divergencias', v_tot_divs,
    'detalle',      v_detalle
  );
END;
$espejo$;

COMMENT ON FUNCTION public.espejo_motor_compras(jsonb, integer) IS
  'Espejo entre las dos implementaciones del motor de costos de compra. Recibe '
  'casos con la entrada en jsonb y la salida del motor de TypeScript, corre el '
  'de SQL (prorratear_cargo / calcular_costos_compra, mig 193) sobre la MISMA '
  'entrada y devuelve las celdas donde no coinciden. Compara con IS DISTINCT '
  'FROM sobre numeric redondeado a p_decimales, asi 500 y 500.00 son el mismo '
  'numero y un centavo no. Que solo una de las dos lance tambien es divergencia. '
  'Lo consume scripts/espejo-motor-compras.mjs desde el gate de integridad '
  '(mig 196).';

-- Sólo el gate. No la llama ni el front ni el bot, así que `authenticated` va
-- en el REVOKE junto con PUBLIC y anon —y NO es simétrico con la 193, que sí se
-- la da a authenticated porque el modal la usa—.
--
-- `authenticated` va nombrado y medido: el default privilege del schema public
-- le da EXECUTE a los tres roles de Supabase apenas se crea la función, así que
-- revocar sólo PUBLIC y anon deja la puerta abierta sin que se note. Se midió
-- al aplicar esta misma migración: quedó `EXECUTE:authenticated` puesto por el
-- default, contra lo que decía este mismo comentario. Ver el comentario largo
-- de la 193 sobre los dos default privileges que conviven en el schema.
REVOKE ALL ON FUNCTION public.espejo_motor_compras(jsonb, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.espejo_motor_compras(jsonb, integer) TO service_role;

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
-- No escribe nada y no la llama ninguna otra función: dropearla es exacto. Deja
-- al gate de espejo sin backend, así que el paso de CI hay que sacarlo en el
-- mismo movimiento o queda fallando con un 404 de PostgREST.
--
--   DROP FUNCTION IF EXISTS public.espejo_motor_compras(jsonb, integer);
-- ----------------------------------------------------------------------------
