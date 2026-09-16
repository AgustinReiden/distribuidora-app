-- Migración 259 — el aviso de duplicado nombra al vecino por su código (#685)
--
-- `verificar_duplicado_cliente` devolvía `cliente_visible.id`, que es
-- `clientes.id`, y el front lo imprimía tal cual: «"Cristian" (#18)». Pero el id
-- no aparece en NINGUNA pantalla de la app. La lista de clientes muestra
-- `#codigo` y su buscador filtra por `codigo` (VistaClientes.tsx), así que el
-- usuario leía ese número, lo buscaba, y daba con otro comercio: el de código
-- 18, que es otro cliente.
--
-- No es un caso borde. `codigo` es integer NOT NULL UNIQUE con su propia
-- secuencia (`clientes_codigo_seq`), independiente de `clientes_id_seq`: en los
-- 730 clientes de prod no coinciden ni una vez. El número que se mostraba nunca
-- servía. El caso testigo es el 332 ("PUENTE CRISTIAN", código 316), cuyo aviso
-- nombraba al id 18 — que en la app es el #10.
--
-- Cambia sólo QUÉ NÚMERO se muestra, en las dos salidas que lo imprimen: el
-- `cliente_visible` que vuelve al front y el texto del aviso a administración.
-- `entidad_id` de la notificación sigue siendo el id: es la FK con la que se
-- deduplica y con la que se abre la ficha, no un número para leer.
--
-- El criterio, las tres reglas y la decisión de visibilidad quedan intactos:
-- esto es la mig 251 con `codigo` agregado a las cuatro sondas. Firma sin
-- cambios, así que no hay sobrecarga que dropear.
--
-- Forward-only. No toca ni una fila.

CREATE OR REPLACE FUNCTION public.verificar_duplicado_cliente(
  p_latitud          numeric,
  p_longitud         numeric,
  p_direccion        text,
  p_razon_social     text,
  p_nombre_fantasia  text,
  p_excluir_id       bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  c_bloqueo_m constant numeric := 1;
  c_aviso_m   constant numeric := 30;
  c_m_x_grado constant numeric := 111320;

  v_uid       uuid   := auth.uid();
  v_sucursal  bigint := current_sucursal_id();
  v_clave     text   := clave_direccion_cliente(p_direccion);
  v_dlat      numeric;
  v_dlng      numeric;

  -- El lado del que se está cargando, calculado UNA vez. Las sondas de nombre
  -- comparan contra esto en vez de llamar a relacion_nombres_cliente por fila.
  v_norms     text[];
  v_tok_r     text[] := tokens_nombre_cliente(p_razon_social);
  v_tok_f     text[] := tokens_nombre_cliente(p_nombre_fantasia);

  -- v_* es el candidato ELEGIDO; t_* es el de la sonda en curso. Van
  -- separados porque un SELECT ... INTO que no encuentra fila pone las
  -- variables en NULL, y sin esto la sonda del nombre borraba el candidato
  -- que ya había encontrado la de distancia.
  --
  -- v_codigo es `clientes.codigo`, el número que la app muestra y por el que
  -- busca. v_id es el interno: sirve para la FK de la notificación, nunca para
  -- imprimir (#685).
  v_id        bigint;
  v_codigo    integer;
  v_nombre    text;
  v_activo    boolean;
  v_dist      numeric;
  t_id        bigint;
  t_codigo    integer;
  t_nombre    text;
  t_activo    boolean;
  t_dist      numeric;

  v_bloquea   boolean := false;
  v_avisa     boolean := false;
  v_motivo    text;

  v_visible   boolean := true;
  v_es_prev   boolean;
  v_quien     text;
BEGIN
  IF v_uid IS NULL OR v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo verificar duplicados: sin sesión o sin sucursal activa'
      USING ERRCODE = '42501';
  END IF;

  v_norms := ARRAY(
    SELECT n FROM unnest(ARRAY[
      normalizar_nombre_cliente(p_razon_social),
      normalizar_nombre_cliente(p_nombre_fantasia)
    ]) n WHERE n <> ''
  );

  -- ---------- Bloqueo 1: misma dirección con altura -----------------------
  IF v_clave IS NOT NULL THEN
    SELECT c.id, c.codigo,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_codigo, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND clave_direccion_cliente(c.direccion) = v_clave
     ORDER BY c.activo DESC, c.id
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_codigo := t_codigo; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      v_bloquea := true;
      v_motivo  := 'direccion';
    END IF;
  END IF;

  -- ---------- Bloqueo 2 / Aviso 1: el vecino más cercano ------------------
  IF NOT v_bloquea AND p_latitud IS NOT NULL AND p_longitud IS NOT NULL THEN
    -- Prefiltro por box para seguir usando idx_clientes_coordenadas. Se calcula
    -- por eje: un grado de longitud mide menos cuanto más lejos del ecuador
    -- (en Tucumán ~89 km contra los 111 de la latitud). La decisión la toma la
    -- distancia haversine, no el box.
    v_dlat := c_aviso_m / c_m_x_grado;
    v_dlng := c_aviso_m / (c_m_x_grado * GREATEST(cos(radians(p_latitud)), 0.01));

    SELECT c.id, c.codigo,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_codigo, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND c.latitud  IS NOT NULL
       AND c.longitud IS NOT NULL
       AND c.latitud  BETWEEN p_latitud  - v_dlat AND p_latitud  + v_dlat
       AND c.longitud BETWEEN p_longitud - v_dlng AND p_longitud + v_dlng
       AND haversine_m(p_latitud, p_longitud, c.latitud, c.longitud) <= c_aviso_m
     ORDER BY haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_codigo := t_codigo; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      IF v_dist < c_bloqueo_m THEN
        v_bloquea := true;
        v_motivo  := 'punto';
      ELSE
        v_avisa  := true;
        v_motivo := 'distancia';
      END IF;
    END IF;
  END IF;

  -- ---------- Bloqueo 3: mismo nombre exacto ------------------------------
  -- Equivale a relacion_nombres_cliente(...) = 'igual', pero como igualdad
  -- contra los dos nombres normalizados del que se carga: así entra por
  -- idx_clientes_nombre_norm_* en vez de recorrer la sucursal entera.
  -- Se evalúa aunque ya haya un aviso por distancia: un bloqueo lo pisa.
  IF NOT v_bloquea AND cardinality(v_norms) > 0 THEN
    SELECT c.id, c.codigo,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_codigo, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND (normalizar_nombre_cliente(c.razon_social)    = ANY (v_norms)
         OR normalizar_nombre_cliente(c.nombre_fantasia) = ANY (v_norms))
     ORDER BY c.activo DESC, c.id
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_codigo := t_codigo; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      v_bloquea := true;
      v_avisa   := false;
      v_motivo  := 'nombre_igual';
    END IF;
  END IF;

  -- ---------- Aviso 2: un nombre contenido en el otro ---------------------
  -- Equivale a relacion_nombres_cliente(...) = 'subconjunto'. El LATERAL
  -- tokeniza cada fila UNA vez para los cuatro cruces.
  IF NOT v_bloquea AND NOT v_avisa
     AND (cardinality(v_tok_r) > 0 OR cardinality(v_tok_f) > 0) THEN
    SELECT c.id, c.codigo,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_codigo, t_nombre, t_activo, t_dist
      FROM clientes c
      CROSS JOIN LATERAL (
        SELECT tokens_nombre_cliente(c.razon_social)    AS tr,
               tokens_nombre_cliente(c.nombre_fantasia) AS tf
      ) t
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND (tokens_se_contienen(v_tok_r, t.tr)
         OR tokens_se_contienen(v_tok_r, t.tf)
         OR tokens_se_contienen(v_tok_f, t.tr)
         OR tokens_se_contienen(v_tok_f, t.tf))
     ORDER BY c.activo DESC, c.id
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_codigo := t_codigo; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      v_avisa  := true;
      v_motivo := 'nombre_subconjunto';
    END IF;
  END IF;

  IF NOT v_bloquea AND NOT v_avisa THEN
    RETURN jsonb_build_object(
      'bloquea', false, 'avisa', false, 'motivo', NULL,
      'distancia_m', NULL, 'cliente_visible', NULL);
  END IF;

  -- ---------- ¿Puede el caller ver a ese cliente? -------------------------
  -- Espejo de la policy mt_clientes_select. Si no lo ve, no le decimos quién
  -- es: sería filtrar por la ventana lo que la RLS tapa por la puerta (#543).
  v_es_prev := EXISTS (SELECT 1 FROM perfiles p WHERE p.id = v_uid AND p.rol = 'preventista');

  IF v_es_prev THEN
    SELECT (
        (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id))
        OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                    WHERE cp.cliente_id = c.id AND cp.preventista_id = v_uid)
      )
      AND (
        NOT c.reservado_admin
        OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = v_uid)
      )
      INTO v_visible
      FROM clientes c
     WHERE c.id = v_id;
  END IF;

  -- ---------- Aviso a administración cuando el vecino está tapado ---------
  IF v_es_prev AND NOT v_visible THEN
    IF NOT EXISTS (
      SELECT 1 FROM notificaciones n
       WHERE n.tipo = 'cliente_duplicado_oculto'
         AND n.entidad_id = v_id
         AND n.created_at > now() - interval '1 day'
    ) THEN
      SELECT p.nombre INTO v_quien FROM perfiles p WHERE p.id = v_uid;

      PERFORM _notificar_sucursal_roles(
        v_sucursal,
        v_uid,
        'cliente_duplicado_oculto',
        CASE WHEN v_bloquea
             THEN 'Alta de cliente bloqueada por duplicado'
             ELSE 'Alta de cliente muy cerca de otro que el preventista no ve' END,
        COALESCE(v_quien, 'Un preventista')
          || ' intentó cargar un cliente que choca con "'
          || COALESCE(v_nombre, 'sin nombre')
          -- El código, no el id: quien lee esto lo va a buscar en la app (#685).
          || '" (#' || v_codigo || '), que no tiene en su cartera'
          || CASE WHEN v_bloquea THEN '. Se bloqueó el alta. '
                  ELSE '. Se le pidió que confirme. ' END
          || 'Puede ser el mismo comercio: si corresponde, asignáselo.',
        'cliente',
        -- entidad_id sigue siendo el id: es la FK con la que se deduplica el
        -- aviso y con la que se abre la ficha, no un número para leer.
        v_id,
        jsonb_build_object(
          'preventista_id', v_uid,
          'motivo', v_motivo,
          'distancia_m', CASE WHEN v_dist IS NULL THEN NULL ELSE round(v_dist, 1) END,
          'latitud', p_latitud,
          'longitud', p_longitud
        )
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'bloquea', v_bloquea,
    'avisa',   v_avisa,
    'motivo',  v_motivo,
    'distancia_m', CASE WHEN v_dist IS NULL THEN NULL ELSE round(v_dist, 1) END,
    'cliente_visible', CASE WHEN v_visible
      THEN jsonb_build_object('id', v_id, 'codigo', v_codigo, 'nombre', v_nombre, 'activo', v_activo)
      ELSE NULL END
  );
END;
$function$;

COMMENT ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, text, text, bigint) IS
  'Única puerta del guard de clientes duplicados. Devuelve {bloquea, avisa, motivo, distancia_m, cliente_visible{id, codigo, nombre, activo}}. Tres reglas: dirección normalizada con altura (bloqueo), distancia real en metros (<1 m bloqueo, 1-30 m aviso) y nombre por tokens contra razón social y fantasía (igual = bloqueo, subconjunto = aviso). El número que se le muestra al usuario es codigo, no id: el id no aparece en ninguna pantalla. SECURITY DEFINER: ve por encima de la RLS pero no revela la identidad de un cliente que al caller se le tapa; en ese caso le avisa a administración. Fail-closed sin sesión o sin sucursal. Reemplaza a existe_cliente_en_ubicacion (mig 217).';

-- ============================================================================
-- Ensayo: que el número que sale sea el código
-- ============================================================================
-- La RPC exige sesión y sucursal, así que no se la puede invocar desde acá. El
-- chequeo es estructural: que las dos salidas que imprimen un número usen
-- v_codigo, y que ninguna vuelva a imprimir v_id. Atrapa el CREATE OR REPLACE
-- descuidado que revierte media migración, que es como volvería este bug.
DO $ensayo$
DECLARE
  d text := pg_get_functiondef(
    'public.verificar_duplicado_cliente(numeric,numeric,text,text,text,bigint)'::regprocedure);
  v_sondas int;
BEGIN
  IF position($m$'codigo', v_codigo$m$ IN d) = 0 THEN
    RAISE EXCEPTION 'cliente_visible no devuelve el código: el front no tiene con qué nombrar al vecino (#685)';
  END IF;

  IF position($m$(#' || v_codigo$m$ IN d) = 0 THEN
    RAISE EXCEPTION 'el aviso a administración no nombra al vecino por su código (#685)';
  END IF;

  IF position($m$(#' || v_id$m$ IN d) > 0 THEN
    RAISE EXCEPTION 'quedó un id impreso como si fuera un número de cliente (#685)';
  END IF;

  -- Las cuatro sondas tienen que traer el código: si una se olvida, ese motivo
  -- devuelve cliente_visible.codigo en null y el mensaje sale sin número.
  v_sondas := (length(d) - length(replace(d, 'INTO t_id, t_codigo,', '')))
              / length('INTO t_id, t_codigo,');
  IF v_sondas <> 4 THEN
    RAISE EXCEPTION 'sólo % de las 4 sondas traen el código del candidato (#685)', v_sondas;
  END IF;

  RAISE NOTICE 'OK: el aviso de duplicado nombra al vecino por su código';
END
$ensayo$;
