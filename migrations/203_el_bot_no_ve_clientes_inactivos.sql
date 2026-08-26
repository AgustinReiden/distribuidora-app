-- Que el bot deje de ofrecer clientes dados de baja (#491)
--
-- `clientes.activo` existe desde el baseline y es la baja logica: desde la mig
-- 200 un cliente con pedidos NO se puede borrar (FK RESTRICT), asi que
-- desactivarlo es la unica salida. El front ya filtra, y en el bot casi todo
-- filtraba tambien:
--   bot_mis_clientes            -> AND c.activo = TRUE   (mig 015)
--   bot_sugerir_visitas_rfm     -> AND c.activo = TRUE   (mig 017)
--   ficha_cliente (edge fn)     -> .eq("activo", true)
--   previsualizar_pedido (edge) -> .eq("activo", true)
--
-- El unico que no era `bot_buscar_cliente`, que es justo la PUERTA DE ENTRADA:
-- es la busqueda por nombre o codigo desde la que el preventista llega a todo
-- lo demas. O sea que un cliente desactivado seguia siendo encontrable y
-- seleccionable desde Telegram, aunque en la app web ya no apareciera.
--
-- Se agrega el mismo `AND c.activo = TRUE` que ya usan sus hermanas. No cambia
-- la firma: es un CREATE OR REPLACE del cuerpo, verificado contra el catalogo
-- vivo (identico a la mig 028, sin drift).
--
-- Efecto medido en prod al momento de escribir esto: 2 clientes inactivos sobre
-- 712 dejan de aparecer en la busqueda del bot.

CREATE OR REPLACE FUNCTION public.bot_buscar_cliente(
  p_q          text,
  p_perfil_id  uuid,
  p_rol        text,
  p_sucursal_id bigint,
  p_limit      integer DEFAULT 10
)
RETURNS TABLE(
  id bigint, codigo integer, nombre_fantasia text, razon_social text,
  saldo_cuenta numeric, direccion text, zona text, sucursal_id bigint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH terms AS (
    SELECT array_remove(
      string_to_array(
        trim(lower(f_unaccent(coalesce(p_q, '')))),
        ' '
      ),
      ''
    ) AS words
  )
  SELECT
    c.id, c.codigo, c.nombre_fantasia, c.razon_social, c.saldo_cuenta,
    c.direccion, c.zona, c.sucursal_id
  FROM clientes c, terms t
  WHERE
    c.sucursal_id = p_sucursal_id
    -- Baja logica: un cliente desactivado no se ofrece para operar. Su historial
    -- sigue intacto y visible en los reportes, que no pasan por aca.
    AND c.activo = TRUE
    AND (
      p_rol = 'admin'
      OR EXISTS(
        SELECT 1 FROM cliente_preventistas cp
        WHERE cp.cliente_id = c.id AND cp.preventista_id = p_perfil_id
      )
      -- Huerfanos (sin asignacion a ningun preventista) visibles para cualquier
      -- preventista de la misma sucursal (mig 028).
      OR NOT EXISTS(
        SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id
      )
    )
    AND (
      array_length(t.words, 1) IS NULL
      OR (
        SELECT bool_and(
          lower(f_unaccent(coalesce(c.nombre_fantasia, ''))) LIKE '%' || w || '%'
          OR lower(f_unaccent(coalesce(c.razon_social, ''))) LIKE '%' || w || '%'
          OR lower(coalesce(c.codigo::TEXT, '')) LIKE '%' || w || '%'
        )
        FROM unnest(t.words) AS w
      )
    )
  ORDER BY c.nombre_fantasia
  LIMIT p_limit;
$$;

-- CREATE OR REPLACE conserva el ACL, pero el hardening se repite igual: es
-- barato y no depende de que nadie lo haya tocado en el medio. `bot_*` la llama
-- el bot con service_role; anon y PUBLIC no tienen nada que hacer aca.
REVOKE ALL ON FUNCTION public.bot_buscar_cliente(text, uuid, text, bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_buscar_cliente(text, uuid, text, bigint, integer) TO service_role;

DO $verif$
DECLARE v_acl text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'bot_buscar_cliente';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'bot_buscar_cliente quedo con ACL default (PUBLIC ejecuta)';
  END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'bot_buscar_cliente quedo ejecutable por PUBLIC: %', v_acl;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'bot_buscar_cliente quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%service_role=X%' THEN
    RAISE EXCEPTION 'bot_buscar_cliente no quedo ejecutable por service_role: %', v_acl;
  END IF;
END
$verif$;
