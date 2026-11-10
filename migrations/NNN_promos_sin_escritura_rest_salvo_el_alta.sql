-- NNN · Los productos y las reglas de una promo ya no se escriben por REST, salvo en el alta (#1496).
--
-- QUÉ PASABA
--   Desde la 472 (#1491) el front guarda una promo en una sola RPC, cambiar_regalo_promocion con p_datos, que
--   concilia adentro los productos y las reglas. Es SECURITY DEFINER: no usa los permisos de authenticated ni pasa
--   por RLS. Pero authenticated seguía con tres escrituras REST que sólo usaba la conciliación vieja de
--   updatePromocion:
--     · DELETE de promocion_productos;
--     · UPDATE de promocion_reglas (el upsert de las reglas);
--     · DELETE de promocion_reglas.
--   Quedaron vivas unos días para no cortar a un bundle viejo del PWA (decisión del dueño, 06/11), anotadas en
--   bundle_viejo de scripts/grants-rest.json. En las 24 horas de logs anteriores a aplicar esta migración no hubo
--   ninguna escritura REST de esas dos tablas.
--
-- QUÉ CAMBIA
--   · authenticated pierde el DELETE de promocion_productos y el UPDATE y el DELETE de promocion_reglas. Son de
--     tabla, y ninguna columna de las dos tablas tiene permisos propios (la premisa lo verifica), así que quitarlos
--     no se lleva nada por columna. El INSERT y el SELECT no se tocan: el alta de una promo (createPromocion)
--     inserta los productos y las reglas por REST, y el modal los lee.
--   · mt_promocion_productos_all y mt_promocion_reglas_all eran FOR ALL. Pasan a FOR INSERT, con la misma rama:
--     es_admin() y la sucursal activa. Con el UPDATE y el DELETE revocados, lo único que les quedaba además del
--     INSERT era acotar el SELECT, y eso ya lo da mt_promocion_*_select: la sucursal activa para cualquier rol, que
--     incluye la rama del admin. Se llaman mt_promocion_*_insert, para que el catálogo no diga que el admin borra
--     por REST lo que no puede borrar.
--
-- QUÉ NO CAMBIA
--   · Borrar una promo por REST (promociones.DELETE) sigue borrando sus productos y sus reglas: el ON DELETE
--     CASCADE corre como el dueño de cada tabla, no como authenticated.
--   · cambiar_regalo_promocion y el camino sin p_datos.
--   · El riesgo, aceptado por el dueño el 06/11: un bundle anterior a la 472 que guarde una promo cambia el regalo
--     por la RPC de cuatro argumentos y después recibe 42501 en la conciliación REST de los productos y las reglas.
--     La promo queda guardada a medias hasta que el admin acepte la actualización y vuelva a guardar.
--
-- Ensayo: scripts/test-promos-sin-escritura-rest-1496.sql. Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: los permisos y las policies que había en prod el 10/11
-- ---------------------------------------------------------------------------
DO $premisa$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT e.tabla, e.privs,
           (SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
              FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.oid = ('public.' || e.tabla)::regclass AND a.grantee = 'authenticated'::regrole) AS vivos,
           (SELECT count(*) FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.oid = ('public.' || e.tabla)::regclass AND a.grantee = 'anon'::regrole) AS de_anon,
           (SELECT count(*) FROM pg_attribute at
             WHERE at.attrelid = ('public.' || e.tabla)::regclass AND at.attacl IS NOT NULL) AS por_columna
      FROM (VALUES ('promocion_productos', 'DELETE,INSERT,SELECT'),
                   ('promocion_reglas', 'DELETE,INSERT,SELECT,UPDATE')) AS e(tabla, privs)
  LOOP
    IF r.vivos IS DISTINCT FROM r.privs OR r.de_anon <> 0 OR r.por_columna <> 0 THEN
      RAISE EXCEPTION 'premisa: authenticated tiene % sobre % (se esperaba %), anon tiene % y hay % columnas con permisos propios',
        r.vivos, r.tabla, r.privs, r.de_anon, r.por_columna;
    END IF;
  END LOOP;

  FOR r IN
    SELECT e.tabla, e.policy, p.cmd, p.roles::text AS roles, p.permissive, p.qual, p.with_check
      FROM (VALUES ('promocion_productos', 'mt_promocion_productos_all'),
                   ('promocion_reglas', 'mt_promocion_reglas_all')) AS e(tabla, policy)
      LEFT JOIN pg_policies p ON p.schemaname = 'public' AND p.tablename = e.tabla AND p.policyname = e.policy
  LOOP
    IF r.cmd IS DISTINCT FROM 'ALL' OR r.roles IS DISTINCT FROM '{authenticated}'
       OR r.permissive IS DISTINCT FROM 'PERMISSIVE'
       OR r.qual IS DISTINCT FROM '(es_admin() AND (sucursal_id = current_sucursal_id()))'
       OR r.with_check IS DISTINCT FROM '(es_admin() AND (sucursal_id = current_sucursal_id()))' THEN
      RAISE EXCEPTION 'premisa: la policy %.% no es la del baseline (%, %, %, USING %, CHECK %)',
        r.tabla, r.policy, r.cmd, r.roles, r.permissive, r.qual, r.with_check;
    END IF;
  END LOOP;
END
$premisa$;

-- ---------------------------------------------------------------------------
-- Las escrituras que sólo usaba la conciliación REST de antes de la 472
-- ---------------------------------------------------------------------------
REVOKE DELETE ON public.promocion_productos FROM authenticated;
REVOKE UPDATE, DELETE ON public.promocion_reglas FROM authenticated;

-- ---------------------------------------------------------------------------
-- Las policies quedan para lo que queda: el INSERT del alta
-- ---------------------------------------------------------------------------
DROP POLICY mt_promocion_productos_all ON public.promocion_productos;
CREATE POLICY mt_promocion_productos_insert ON public.promocion_productos
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

DROP POLICY mt_promocion_reglas_all ON public.promocion_reglas;
CREATE POLICY mt_promocion_reglas_insert ON public.promocion_reglas
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

-- ---------------------------------------------------------------------------
-- Poscondición: los permisos y las policies quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT e.tabla,
           (SELECT string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type)
              FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.oid = ('public.' || e.tabla)::regclass AND a.grantee = 'authenticated'::regrole) AS vivos,
           (SELECT string_agg(p.policyname || ' ' || p.cmd || ' ' || p.roles::text || ' ' || p.permissive
                              || ' USING ' || COALESCE(p.qual, '-') || ' CHECK ' || COALESCE(p.with_check, '-'),
                              ' | ' ORDER BY p.policyname)
              FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = e.tabla) AS policies,
           e.policies AS esperadas
      FROM (VALUES
        ('promocion_productos',
         'mt_promocion_productos_insert INSERT {authenticated} PERMISSIVE USING - CHECK (es_admin() AND (sucursal_id = current_sucursal_id()))'
         || ' | mt_promocion_productos_select SELECT {authenticated} PERMISSIVE USING (sucursal_id = current_sucursal_id()) CHECK -'),
        ('promocion_reglas',
         'mt_promocion_reglas_insert INSERT {authenticated} PERMISSIVE USING - CHECK (es_admin() AND (sucursal_id = current_sucursal_id()))'
         || ' | mt_promocion_reglas_select SELECT {authenticated} PERMISSIVE USING (sucursal_id = current_sucursal_id()) CHECK -')
      ) AS e(tabla, policies)
  LOOP
    IF r.vivos IS DISTINCT FROM 'INSERT,SELECT' OR r.policies IS DISTINCT FROM r.esperadas THEN
      RAISE EXCEPTION '% no quedó como en el repo: authenticated tiene %; policies: %', r.tabla, r.vivos, r.policies;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
