-- Ensayo de #1298: lo que el gate del dia argentino (auditoria_fechas_utc) ve
-- y lo que no.
--
-- Tienen que pasar:
--   F1 · ve un corte UTC de cada forma que el issue decia que no veia:
--        CAST(now() AS date), date(now()), date_trunc por mes, to_char(now()),
--        extract(dow FROM current_timestamp), clock_timestamp()::date, y sobre
--        columnas timestamptz: fecha_entrega::date, CAST(created_at AS date),
--        to_char(fecha_entrega).
--   F2 · una sobrecarga nueva de una funcion permitida sale con su firma (que
--        el gate la compare por firma lo prueba src/test/fechasUtc.test.ts).
--   F3 · ve una vista, una policy y un CHECK que cortan en UTC.
--   F4 · no ve lo que esta bien escrito: AT TIME ZONE antes del ::date o del
--        to_char, date_trunc por hora, extract(epoch), un ::date sobre una
--        columna date (fecha, que en quince tablas es date), un literal que dice
--        current_date, _tablero_hoy().
--
-- Contra prod sin la migracion de #1292/#1298 fallan los nueve casos de F1 y
-- los tres de F3 (corrido el 2026-10-29); F2 y F4 pasan con las dos.
--
-- Crea funciones, una tabla, una policy y una vista en public dentro de un
-- subbloque que se revierte: no deja rastro.
--
--   psql "$DATABASE_URL" -f scripts/test-fechas-utc-1298.sql

DO $ensayo$
DECLARE
  v_g      jsonb;
  v_fallas text[] := '{}';
  v_caso   record;
  v_rep    text;
BEGIN
  BEGIN
    -- F1 · cortes UTC, uno por forma.
    CREATE FUNCTION public.zz_1298_cast() RETURNS date LANGUAGE sql AS $f$ SELECT CAST(now() AS date) $f$;
    CREATE FUNCTION public.zz_1298_date() RETURNS date LANGUAGE sql AS $f$ SELECT date(now()) $f$;
    CREATE FUNCTION public.zz_1298_trunc() RETURNS timestamptz LANGUAGE sql AS $f$ SELECT date_trunc('month', now()) $f$;
    CREATE FUNCTION public.zz_1298_tochar() RETURNS text LANGUAGE sql AS $f$ SELECT to_char(now(), 'DD/MM HH24:MI') $f$;
    CREATE FUNCTION public.zz_1298_extract() RETURNS numeric LANGUAGE sql AS $f$ SELECT extract(dow FROM current_timestamp) $f$;
    CREATE FUNCTION public.zz_1298_clock() RETURNS date LANGUAGE sql AS $f$ SELECT clock_timestamp()::date $f$;
    CREATE FUNCTION public.zz_1298_col(p bigint) RETURNS date LANGUAGE sql
      AS $f$ SELECT pd.fecha_entrega::date FROM public.pedidos pd WHERE pd.id = p $f$;
    CREATE FUNCTION public.zz_1298_col_cast(p bigint) RETURNS date LANGUAGE sql
      AS $f$ SELECT CAST(pd.created_at AS date) FROM public.pedidos pd WHERE pd.id = p $f$;
    CREATE FUNCTION public.zz_1298_col_tochar(p bigint) RETURNS text LANGUAGE plpgsql
      AS $f$ BEGIN RETURN (SELECT to_char(pd.fecha_entrega, 'DD/MM') FROM public.pedidos pd WHERE pd.id = p); END $f$;

    -- F2 · una sobrecarga de una permitida (crear_recorrido esta en la lista).
    CREATE FUNCTION public.crear_recorrido(p_zz_1298 text) RETURNS date LANGUAGE sql AS $f$ SELECT CURRENT_DATE $f$;

    -- F3 · vista, policy y CHECK.
    CREATE TABLE public.zz_1298 (id int, d date CONSTRAINT zz_1298_d_check CHECK (d <= now()::date));
    ALTER TABLE public.zz_1298 ENABLE ROW LEVEL SECURITY;
    CREATE POLICY zz_1298_sel ON public.zz_1298 FOR SELECT TO authenticated USING (d = CURRENT_DATE);
    CREATE VIEW public.zz_1298_v AS SELECT date_trunc('day', now()) AS hoy;

    -- F4 · bien escritas.
    CREATE FUNCTION public.zz_1298_ok() RETURNS jsonb LANGUAGE plpgsql AS $f$
    BEGIN
      RETURN jsonb_build_object(
        'a', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
        'b', date_trunc('hour', now()),
        'c', extract(epoch FROM now()),
        'd', to_char(now() AT TIME ZONE 'America/Argentina/Buenos_Aires', 'HH24:MI'),
        'e', (SELECT (pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date FROM public.pedidos pd LIMIT 1),
        'f', (SELECT p.fecha::date FROM public.pagos p LIMIT 1),
        'g', 'current_date en un literal',
        'h', public._tablero_hoy());
    END $f$;

    v_g := public.auditoria_fechas_utc();

    FOR v_caso IN SELECT * FROM (VALUES
        ('zz_1298_cast()',              'CAST(ahora AS date)'),
        ('zz_1298_date()',              'date(ahora)'),
        ('zz_1298_trunc()',             'date_trunc(dia, ahora)'),
        ('zz_1298_tochar()',            'to_char(ahora)'),
        ('zz_1298_extract()',           'extract(ahora)'),
        ('zz_1298_clock()',             'ahora::date'),
        ('zz_1298_col(bigint)',         'columna::date'),
        ('zz_1298_col_cast(bigint)',    'CAST(columna AS date)'),
        ('zz_1298_col_tochar(bigint)',  'to_char(columna)'),
        ('crear_recorrido(text)',       'CURRENT_DATE')) AS t(firma, patron)
    LOOP
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'funciones') x
                      WHERE x->>'firma' = v_caso.firma AND x->'patrones' ? v_caso.patron) THEN
        v_fallas := v_fallas || format('F1/F2 · %s no salio con %s: %s', v_caso.firma, v_caso.patron,
          (SELECT x FROM jsonb_array_elements(v_g->'funciones') x WHERE x->>'firma' = v_caso.firma));
      END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'vistas') x
                    WHERE x->>'nombre' = 'zz_1298_v' AND x->'patrones' ? 'date_trunc(dia, ahora)') THEN
      v_fallas := v_fallas || format('F3 · la vista no salio: %s', v_g->'vistas');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'policies') x
                    WHERE x->>'nombre' = 'zz_1298.zz_1298_sel' AND x->'patrones' ? 'CURRENT_DATE') THEN
      v_fallas := v_fallas || format('F3 · la policy no salio: %s', v_g->'policies');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'checks') x
                    WHERE x->>'nombre' = 'zz_1298.zz_1298_d_check' AND x->'patrones' ? 'ahora::date') THEN
      v_fallas := v_fallas || format('F3 · el CHECK no salio: %s', v_g->'checks');
    END IF;

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'funciones') x
                WHERE x->>'nombre' IN ('zz_1298_ok', '_tablero_hoy')) THEN
      v_fallas := v_fallas || format('F4 · salio algo bien escrito: %s',
        (SELECT jsonb_agg(x) FROM jsonb_array_elements(v_g->'funciones') x
          WHERE x->>'nombre' IN ('zz_1298_ok', '_tablero_hoy')));
    END IF;

    v_rep := format('%s funciones miradas; %s con el dia UTC fuera del ensayo',
      v_g->>'total_funciones',
      (SELECT count(*) FROM jsonb_array_elements(v_g->'funciones') x
        WHERE x->>'nombre' NOT LIKE 'zz\_1298%' AND x->>'firma' <> 'crear_recorrido(text)'));

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE NOTICE 'ENSAYO OK · %', v_rep;
END
$ensayo$;

DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
