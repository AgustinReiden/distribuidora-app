-- =========================================================================
-- 152_guardar_horario_cliente_masivo.sql
--
-- El backfill de horarios (mig 141) convirtió lo que pudo interpretar con
-- confianza. En prod quedaron 54 clientes en texto libre que el parser no pudo
-- resolver solo: "24 HS" (19), "DE CORRIDO", "9 A 1 AM", "De 10 a 14 y de 18 a
-- 2", "Desde 9 corrido frente escuela Amalia"…
--
-- Esos 54 no son un detalle: el ruteo por barridas los manda a la barrida 2
-- ("sin horario cargado"), que es la bolsa de los que no sabemos cuándo abren.
-- Sin este RPC se convierten de a uno, cuando alguien abre la ficha, o nunca.
--
-- El RPC toma las decisiones ya revisadas por una persona en la pantalla
-- `/horarios-clientes` y las aplica en bloque. NO parsea nada: el parser vive
-- en TypeScript (`parseHorarioLibre.ts`, con sus tests contra estos mismos
-- casos reales) y reimplementarlo en PL/pgSQL sería duplicar lógica sutil.
--
-- Preserva `horarios_atencion_original` si ya tenía valor: el texto de la
-- primera conversión es el que vale como evidencia, no el de la última.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.guardar_horario_cliente_masivo(
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_actualizados integer := 0;
  v_fila         integer;
  item           jsonb;
  v_horario      text;
  v_dias         text;
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo un admin o encargado puede normalizar horarios'
      USING ERRCODE = '42501';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('success', true, 'actualizados', 0);
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_horario := nullif(trim(item->>'horarios_atencion'), '');
    v_dias    := nullif(trim(item->>'dias_atencion'), '');

    -- Sin franjas no hay nada que normalizar: se saltea en vez de borrar el
    -- texto que el preventista habia cargado.
    CONTINUE WHEN v_horario IS NULL;

    -- Formato canonico "HH:MM-HH:MM[ y HH:MM-HH:MM]". Un valor mal formado
    -- ensuciaria justo la columna que estamos limpiando.
    IF v_horario !~ '^\d{2}:\d{2}-\d{2}:\d{2}( y \d{2}:\d{2}-\d{2}:\d{2})*$' THEN
      CONTINUE;
    END IF;

    IF v_dias IS NOT NULL AND v_dias !~ '^[01]{7}$' THEN
      CONTINUE;
    END IF;

    UPDATE clientes c
    SET horarios_atencion = v_horario,
        dias_atencion     = COALESCE(v_dias, c.dias_atencion),
        -- Solo la PRIMERA conversion guarda el original.
        horarios_atencion_original = COALESCE(c.horarios_atencion_original, c.horarios_atencion)
    WHERE c.id = (item->>'cliente_id')::bigint
      AND c.sucursal_id = current_sucursal_id();

    GET DIAGNOSTICS v_fila = ROW_COUNT;
    v_actualizados := v_actualizados + v_fila;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'actualizados', v_actualizados);
END;
$fn$;

ALTER FUNCTION public.guardar_horario_cliente_masivo(jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guardar_horario_cliente_masivo(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guardar_horario_cliente_masivo(jsonb) TO authenticated;

COMMENT ON FUNCTION public.guardar_horario_cliente_masivo(jsonb) IS
  'Aplica en bloque horarios canonicos ya revisados a mano. Valida formato; no parsea (el parser vive en TS). Mig 152.';
