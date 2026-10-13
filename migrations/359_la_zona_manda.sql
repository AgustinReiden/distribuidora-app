-- Migración 359: la zona manda — cada zona tiene un preventista y sus clientes son de él
--
-- Hasta acá zona y preventista eran dos datos sueltos del cliente: las zonas se
-- llamaban "ZONA 1 <preventista>" pero nada lo ataba, y había clientes de una
-- zona atendidos por tres preventistas distintos. `preventista_zonas` existía
-- (N-a-N, vacía, sin uso) y `perfiles.zona` era un texto vacío para todos.
--
-- LA REGLA (decidida con el dueño, 2026-10-13):
--   * Una zona tiene UN preventista o ninguno; un preventista, varias zonas.
--   * Linkear la zona Z con P: todo cliente de Z queda asignado SÓLO a P
--     (activos e inactivos). Los otros preventistas lo pierden para operar;
--     lo siguen viendo como historial (mig 358).
--   * Cambiar el dueño A → B: los clientes pasan de A a B. Mismo camino.
--   * Quitar el link: los clientes CONSERVAN su preventista.
--   * Cambiarle la zona a un cliente: pasa al dueño de la zona nueva. Si la
--     zona nueva no tiene dueño, conserva el que tenía.
--   * Un preventista con zonas da de alta clientes sólo en sus zonas. Sin
--     zonas, como antes.
--   * El reservado a administración (214) no se toca: ni el link ni el cambio
--     de zona le asignan preventista.
--   * El admin puede sumarle un preventista a mano a un cliente puntual; dura
--     hasta el próximo link de su zona o cambio de zona del cliente.
-- Lo arma el admin desde "Gestionar zonas". La tabla arranca vacía: no se
-- infiere nada de los nombres de las zonas.
--
-- Además cierra #1144: `mt_clientes_update` no miraba la asignación, y desde la
-- 358 el preventista VE clientes de historial, así que podía editarlos por REST.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Un dueño por zona; se escribe sólo por RPC
-- ---------------------------------------------------------------------------
ALTER TABLE public.preventista_zonas
  ADD CONSTRAINT preventista_zonas_zona_unica UNIQUE (zona_id);

-- Escribir a mano saltearía la reasignación de clientes, que es la mitad de
-- la regla. Toda escritura pasa por asignar_preventista_zona (SECURITY DEFINER).
DROP POLICY IF EXISTS mt_preventista_zonas_insert ON public.preventista_zonas;
DROP POLICY IF EXISTS mt_preventista_zonas_update ON public.preventista_zonas;
DROP POLICY IF EXISTS mt_preventista_zonas_delete ON public.preventista_zonas;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.preventista_zonas FROM anon, authenticated;
REVOKE SELECT ON public.preventista_zonas FROM anon;

COMMENT ON TABLE public.preventista_zonas IS
  'Dueño de cada zona (mig 359): a lo sumo un preventista por zona. Los clientes '
  'de la zona se le asignan a él. Se escribe sólo con asignar_preventista_zona().';

-- ---------------------------------------------------------------------------
-- 2. Helpers internos
-- ---------------------------------------------------------------------------
-- El dueño VIGENTE: un link a alguien que ya no es preventista activo no manda.
-- (El trigger de la sección 6 los borra, esto es la segunda línea.)
CREATE OR REPLACE FUNCTION public._duenio_zona(p_zona_id bigint)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT pz.perfil_id
    FROM preventista_zonas pz
    JOIN perfiles p ON p.id = pz.perfil_id
   WHERE pz.zona_id = p_zona_id
     AND p.rol = 'preventista'
     AND p.activo
$$;

-- Deja a cada cliente asignado SÓLO a p_duenio. Salta los reservados. Espeja
-- la columna legada `clientes.preventista_id` (la siguen leyendo el optimizador
-- de rutas y otros), igual que hace el front al guardar.
CREATE OR REPLACE FUNCTION public._asignar_clientes_a(p_cliente_ids bigint[], p_duenio uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_ids bigint[];
BEGIN
  SELECT array_agg(c.id) INTO v_ids
    FROM clientes c
   WHERE c.id = ANY (p_cliente_ids)
     AND NOT c.reservado_admin;

  IF v_ids IS NULL THEN
    RETURN 0;
  END IF;

  DELETE FROM cliente_preventistas
   WHERE cliente_id = ANY (v_ids)
     AND preventista_id <> p_duenio;

  INSERT INTO cliente_preventistas (cliente_id, preventista_id)
  SELECT unnest(v_ids), p_duenio
  ON CONFLICT DO NOTHING;

  UPDATE clientes
     SET preventista_id = p_duenio
   WHERE id = ANY (v_ids)
     AND preventista_id IS DISTINCT FROM p_duenio;

  RETURN cardinality(v_ids);
END;
$$;

REVOKE EXECUTE ON FUNCTION public._duenio_zona(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._asignar_clientes_a(bigint[], uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La RPC del panel
-- ---------------------------------------------------------------------------
-- p_preventista_id NULL = quitar el link (los clientes conservan su preventista).
-- p_simular = true no escribe nada: devuelve lo que cambiaría, para que el panel
-- lo muestre antes de confirmar.
--
-- Devuelve:
--   { duenio_anterior, clientes_zona, cambian, reservados, quitados: [{preventista_id, nombre, clientes}] }
-- `cambian` = clientes cuya asignación no es exactamente {P}.
-- `quitados` = por cada OTRO preventista, cuántos clientes de la zona pierde.
CREATE OR REPLACE FUNCTION public.asignar_preventista_zona(
  p_zona_id bigint,
  p_preventista_id uuid,
  p_simular boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal  bigint;
  v_anterior  uuid;
  v_ids       bigint[];
  v_cambian   integer := 0;
  v_reserv    integer := 0;
  v_total     integer := 0;
  v_quitados  jsonb := '[]'::jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un administrador puede asignar zonas a preventistas'
      USING ERRCODE = '42501';
  END IF;

  SELECT z.sucursal_id INTO v_sucursal
    FROM zonas z
   WHERE z.id = p_zona_id
     AND z.sucursal_id = current_sucursal_id();
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'La zona % no existe en la sucursal activa', p_zona_id
      USING ERRCODE = 'P0002';
  END IF;

  IF p_preventista_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM perfiles p
       WHERE p.id = p_preventista_id AND p.rol = 'preventista' AND p.activo
    ) THEN
      RAISE EXCEPTION 'Sólo se le puede asignar una zona a un preventista activo'
        USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM usuario_sucursales us
       WHERE us.usuario_id = p_preventista_id AND us.sucursal_id = v_sucursal
    ) THEN
      RAISE EXCEPTION 'Ese preventista no trabaja en esta sucursal'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT pz.perfil_id INTO v_anterior
    FROM preventista_zonas pz WHERE pz.zona_id = p_zona_id;

  -- Todos los clientes de la zona, activos e inactivos.
  SELECT array_agg(c.id),
         count(*),
         count(*) FILTER (WHERE c.reservado_admin)
    INTO v_ids, v_total, v_reserv
    FROM clientes c
   WHERE c.zona_id = p_zona_id;

  IF p_preventista_id IS NOT NULL THEN
    SELECT count(*) INTO v_cambian
      FROM clientes c
     WHERE c.zona_id = p_zona_id
       AND NOT c.reservado_admin
       AND (
         NOT EXISTS (SELECT 1 FROM cliente_preventistas cp
                      WHERE cp.cliente_id = c.id AND cp.preventista_id = p_preventista_id)
         OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                     WHERE cp.cliente_id = c.id AND cp.preventista_id <> p_preventista_id)
       );

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'preventista_id', q.preventista_id,
             'nombre', q.nombre,
             'clientes', q.n) ORDER BY q.n DESC, q.nombre), '[]'::jsonb)
      INTO v_quitados
      FROM (
        SELECT cp.preventista_id, pf.nombre, count(*) AS n
          FROM clientes c
          JOIN cliente_preventistas cp ON cp.cliente_id = c.id
          JOIN perfiles pf ON pf.id = cp.preventista_id
         WHERE c.zona_id = p_zona_id
           AND NOT c.reservado_admin
           AND cp.preventista_id <> p_preventista_id
         GROUP BY cp.preventista_id, pf.nombre
      ) q;
  END IF;

  IF NOT p_simular THEN
    DELETE FROM preventista_zonas WHERE zona_id = p_zona_id;
    IF p_preventista_id IS NOT NULL THEN
      INSERT INTO preventista_zonas (perfil_id, zona_id, sucursal_id)
      VALUES (p_preventista_id, p_zona_id, v_sucursal);
      IF v_ids IS NOT NULL THEN
        PERFORM _asignar_clientes_a(v_ids, p_preventista_id);
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'duenio_anterior', v_anterior,
    'clientes_zona', v_total,
    'cambian', v_cambian,
    'reservados', v_reserv,
    'quitados', v_quitados,
    'simulado', p_simular
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.asignar_preventista_zona(bigint, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.asignar_preventista_zona(bigint, uuid, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Cambiarle la zona a un cliente lo pasa al dueño de la zona nueva
-- ---------------------------------------------------------------------------
-- AFTER y `UPDATE OF zona_id`: el que guarda desde el modal (admin) manda sus
-- preventista_ids DESPUÉS del UPDATE, así que si eligió algo distinto a mano,
-- eso queda. Este trigger es lo que vale para todo otro camino.
CREATE OR REPLACE FUNCTION public.clientes_zona_asigna_duenio()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_duenio uuid;
BEGIN
  v_duenio := _duenio_zona(NEW.zona_id);
  IF v_duenio IS NOT NULL THEN
    PERFORM _asignar_clientes_a(ARRAY[NEW.id], v_duenio);
  END IF;
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.clientes_zona_asigna_duenio() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_clientes_zona_asigna_duenio ON public.clientes;
CREATE TRIGGER trg_clientes_zona_asigna_duenio
  AFTER UPDATE OF zona_id ON public.clientes
  FOR EACH ROW
  WHEN (OLD.zona_id IS DISTINCT FROM NEW.zona_id
        AND NEW.zona_id IS NOT NULL
        AND NOT NEW.reservado_admin)
  EXECUTE FUNCTION public.clientes_zona_asigna_duenio();

-- El guard de cliente_preventistas (216) rechaza que alguien que no es admin
-- asigne a otro preventista. Un encargado que le cambia la zona a un cliente
-- dispara la reasignación de arriba con SU auth.uid(). Esa inserción viene de
-- un trigger (profundidad > 1), no de una escritura directa: se exenta, igual
-- que los guards de la 080. Un preventista no llega acá: no puede cambiar
-- zona_id (clientes_proteger_columnas_preventista).
DO $guard$
DECLARE
  v_def text;
  v_old constant text :=
$o$  IF es_admin() THEN
    RETURN NEW;
  END IF;
$o$;
  v_new constant text :=
$n$  IF es_admin() THEN
    RETURN NEW;
  END IF;

  -- Reasignación por zona (mig 359): la inserta un trigger, no el usuario.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;
$n$;
BEGIN
  v_def := pg_get_functiondef('public.cliente_preventistas_no_ajeno()'::regprocedure);
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION '359: el fragmento de cliente_preventistas_no_ajeno no está una sola vez en el cuerpo vivo';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$guard$;

-- ---------------------------------------------------------------------------
-- 5. El preventista con zonas da de alta sólo en sus zonas
-- ---------------------------------------------------------------------------
-- Rol CRUDO (es_preventista() incluye admin y encargado). Exenciones de la 080:
-- RPCs definer / service_role / cascadas.
-- INVOKER a propósito: decide por `current_user`, que dentro de una función
-- SECURITY DEFINER sería siempre el dueño y el guard no correría nunca. Lo que
-- lee (su perfil, sus zonas, las zonas de la sucursal) el preventista lo ve.
CREATE OR REPLACE FUNCTION public.clientes_alta_en_zona_propia()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_zonas text;
BEGIN
  IF current_user <> 'authenticated' OR pg_trigger_depth() > 1 OR auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.rol = 'preventista') THEN
    RETURN NEW;
  END IF;

  -- Sin zonas en esta sucursal: como siempre.
  IF NOT EXISTS (
    SELECT 1 FROM preventista_zonas pz
     WHERE pz.perfil_id = auth.uid() AND pz.sucursal_id = NEW.sucursal_id
  ) THEN
    RETURN NEW;
  END IF;

  IF NEW.zona_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM preventista_zonas pz
     WHERE pz.perfil_id = auth.uid() AND pz.zona_id = NEW.zona_id
  ) THEN
    RETURN NEW;
  END IF;

  SELECT string_agg(z.nombre, ', ' ORDER BY z.nombre) INTO v_zonas
    FROM preventista_zonas pz JOIN zonas z ON z.id = pz.zona_id
   WHERE pz.perfil_id = auth.uid() AND pz.sucursal_id = NEW.sucursal_id;

  RAISE EXCEPTION 'El cliente tiene que quedar en una de tus zonas: %', v_zonas
    USING ERRCODE = '42501';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.clientes_alta_en_zona_propia() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_clientes_alta_en_zona_propia ON public.clientes;
CREATE TRIGGER trg_clientes_alta_en_zona_propia
  BEFORE INSERT ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.clientes_alta_en_zona_propia();

-- ---------------------------------------------------------------------------
-- 6. El que deja de ser preventista activo suelta sus zonas
-- ---------------------------------------------------------------------------
-- Pariente de soltar_cartera_preventista_inactivo (264). Sin esto, el próximo
-- cambio de zona le asignaría clientes a alguien que ya no trabaja.
CREATE OR REPLACE FUNCTION public.soltar_zonas_preventista()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  DELETE FROM preventista_zonas WHERE perfil_id = NEW.id;
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.soltar_zonas_preventista() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_soltar_zonas_preventista ON public.perfiles;
CREATE TRIGGER trg_soltar_zonas_preventista
  AFTER UPDATE OF activo, rol ON public.perfiles
  FOR EACH ROW
  WHEN ((OLD.activo IS DISTINCT FROM NEW.activo AND NEW.activo = false)
        OR (OLD.rol IS DISTINCT FROM NEW.rol AND NEW.rol <> 'preventista'))
  EXECUTE FUNCTION public.soltar_zonas_preventista();

-- ---------------------------------------------------------------------------
-- 7. #1144: ver no es editar
-- ---------------------------------------------------------------------------
-- Para el rol crudo preventista se suma la rama de OPERAR de mt_clientes_select
-- (sin asignar o asignado a él). El reservado ya estaba excluido. Para los
-- demás roles no cambia nada.
ALTER POLICY mt_clientes_update ON public.clientes
  USING (
    public.es_preventista()
    AND sucursal_id = public.current_sucursal_id()
    AND (
      NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol = 'preventista'
      )
      OR (
        NOT reservado_admin
        AND (
          NOT EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                       WHERE cp.cliente_id = clientes.id)
          OR EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                      WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid())
        )
      )
    )
  )
  WITH CHECK (
    public.es_preventista()
    AND sucursal_id = public.current_sucursal_id()
    AND (
      NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol = 'preventista'
      )
      OR (
        NOT reservado_admin
        AND (
          NOT EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                       WHERE cp.cliente_id = clientes.id)
          OR EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                      WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid())
        )
      )
    )
  );

COMMIT;
