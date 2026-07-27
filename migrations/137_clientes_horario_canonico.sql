-- =========================================================================
-- 137_clientes_horario_canonico.sql
--
-- OBJETIVO: que el horario del cliente deje de ser texto libre y pase a un
-- formato que el ruteo pueda usar. Es la base de las 3 barridas.
--
-- ESTADO PREVIO (prod 2026-07-27, Tucumán, 621 clientes activos):
--   - 79 tenían franjas canónicas "HH:MM-HH:MM" en `horarios_atencion`.
--   - 259 tenían texto libre ("Lunes a sábado de 9 hs a 14 hrs y 17 hs a 21hs",
--     "24 HS", "9 A 14"). 128 variantes distintas.
--   - 283 vacío.
--   - `horario_entrega` vacío en 619/621: es la columna que el optimizador lee
--     hoy, así que el ruteo corría SIN ninguna ventana horaria.
--
-- POR QUÉ `horario_entrega` quedó vacía: el trigger
-- `clientes_proteger_columnas_preventista` no la incluye en su allow-list, así
-- que un preventista nunca pudo escribirla. Sí puede escribir
-- `horarios_atencion`. Por eso el canónico pasa a ser `horarios_atencion` y
-- `horario_entrega` se deprecia (la columna queda: la imprimen los PDFs).
--
-- DECISIÓN DE MODELO: días como bitmask + franjas en el string canónico, en vez
-- de una tabla `cliente_horarios` normalizada. Ningún cliente de los datos
-- reales tiene horario distinto según el día (el único caso ambiguo queda
-- marcado como dudoso por el parser), y rehacer el formato rompería los 4 PDFs,
-- el editor y los tests que ya existen.
--
-- El backfill NO va en esta migración: lo dispara un admin desde la pantalla de
-- revisión (/horarios-clientes), que usa el parser de `parseHorarioLibre.ts` y
-- deja a revisión manual lo que no puede convertir con seguridad.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Columnas nuevas
-- -------------------------------------------------------------------------
ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS dias_atencion varchar(7);

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS horarios_atencion_original text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'clientes_dias_atencion_check'
  ) THEN
    ALTER TABLE public.clientes
      ADD CONSTRAINT clientes_dias_atencion_check
      CHECK (dias_atencion IS NULL OR dias_atencion ~ '^[01]{7}$');
  END IF;
END $$;

COMMENT ON COLUMN public.clientes.dias_atencion IS
  'Días en que abre, bitmask de 7 chars orden Lunes→Domingo. "1111110" = lunes a sábado. NULL = sin especificar (el ruteo asume que abre todos los días). Mig 137.';
COMMENT ON COLUMN public.clientes.horarios_atencion_original IS
  'Texto libre tal como estaba antes de convertirlo al formato canónico. Permite auditar y revertir el backfill. Mig 137.';
COMMENT ON COLUMN public.clientes.horarios_atencion IS
  'Horario de atención en formato canónico "HH:MM-HH:MM" unido por " y ". Fuente única de las ventanas horarias del ruteo desde la mig 137.';
COMMENT ON COLUMN public.clientes.horario_entrega IS
  'DEPRECADA (mig 137): quedó vacía en 619/621 porque los preventistas nunca tuvieron permiso de escribirla. Se conserva porque la imprimen los PDFs y porque, si tiene valor, tiene precedencia sobre horarios_atencion.';

-- -------------------------------------------------------------------------
-- 2. Permitir que el preventista cargue los días.
--
--    CRÍTICO: sin esto, el preventista que edite el horario de un cliente y
--    marque los días recibe "no puede modificar estas columnas: dias_atencion".
--    Justamente son ellos los que van a hacer la carga.
--    Se replica la función tal cual está en prod, agregando las 2 columnas
--    nuevas a la allow-list.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clientes_proteger_columnas_preventista()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_rol text;
  v_bloqueadas text;
BEGIN
  -- RPCs SECURITY DEFINER, service_role, conexiones directas: exentas.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- Cascadas desde otros triggers (saldo_cuenta desde pedidos): exentas.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();

  IF v_rol IS NULL OR v_rol NOT IN ('preventista', 'preventista_taco') THEN
    RETURN NEW;  -- admin y encargado sin restricción
  END IF;

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key NOT IN (
      'razon_social', 'direccion', 'aclaracion_direccion', 'latitud',
      'longitud', 'telefono', 'contacto', 'horarios_atencion', 'rubro', 'notas',
      -- Mig 137: el horario canónico se carga junto con los días.
      'dias_atencion', 'horarios_atencion_original'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'El rol % no puede modificar estas columnas de clientes: %',
      v_rol, v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$fn$;

-- -------------------------------------------------------------------------
-- 3. Guardado masivo desde la pantalla de revisión de horarios.
--
--    Preserva el texto original la primera vez que se toca cada cliente, para
--    que el backfill sea auditable y reversible.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_horarios_clientes_masivo(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_item        jsonb;
  v_actualizados integer := 0;
  v_cliente_id  bigint;
  v_horario     text;
  v_dias        text;
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo un admin o encargado puede actualizar horarios en lote'
      USING ERRCODE = '42501';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items debe ser un array JSON';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_cliente_id := (v_item ->> 'cliente_id')::bigint;
    v_horario    := NULLIF(v_item ->> 'horarios_atencion', '');
    v_dias       := NULLIF(v_item ->> 'dias_atencion', '');

    IF v_cliente_id IS NULL THEN
      CONTINUE;
    END IF;

    IF v_dias IS NOT NULL AND v_dias !~ '^[01]{7}$' THEN
      RAISE EXCEPTION 'dias_atencion inválido para el cliente %: %', v_cliente_id, v_dias;
    END IF;

    UPDATE clientes
    SET horarios_atencion = v_horario,
        dias_atencion     = v_dias,
        -- Solo la primera vez: no pisar el original en sucesivas correcciones.
        horarios_atencion_original = COALESCE(horarios_atencion_original, horarios_atencion)
    WHERE id = v_cliente_id
      AND sucursal_id = current_sucursal_id();

    IF FOUND THEN
      v_actualizados := v_actualizados + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'actualizados', v_actualizados);
END;
$fn$;

ALTER FUNCTION public.guardar_horarios_clientes_masivo(jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guardar_horarios_clientes_masivo(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guardar_horarios_clientes_masivo(jsonb) TO authenticated;

COMMENT ON FUNCTION public.guardar_horarios_clientes_masivo(jsonb) IS
  'Aplica horarios canónicos + días a varios clientes. Preserva el texto libre original. Admin/encargado. Mig 137.';
