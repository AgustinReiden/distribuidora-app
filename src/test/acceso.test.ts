import { describe, expect, it } from 'vitest'
import {
  hallazgosRamaAdmin,
  huellaPolicy,
  lecturasDeMetadataDelUsuario,
  problemasDeSignup,
  ramasAdminSinSucursal,
  ramasDe,
  // @ts-expect-error -- módulo .mjs de scripts/, sin tipos
} from '../../scripts/lib/acceso.mjs'

/**
 * Lo que deciden los gates de acceso: scripts/check-auth.mjs (#1243) y
 * scripts/check-rama-admin.mjs (#1244). Leen texto, no ejecutan nada, así que
 * los casos son expresiones reales de prod (pg_policies.qual, tal cual las
 * escribe Postgres) y los cuerpos de handle_new_user antes y después de la 403b.
 */

describe('problemasDeSignup', () => {
  it('el signup cerrado y sin anónimos no tiene problemas', () => {
    expect(problemasDeSignup({ disable_signup: true, external: { anonymous_users: false, email: true } })).toEqual([])
  })

  it('el signup abierto es un problema (lo que decía prod el 2026-10-28)', () => {
    expect(problemasDeSignup({ disable_signup: false, external: { anonymous_users: false } })).toHaveLength(1)
  })

  it('sin el campo no se da por cerrado: no poder mirar no es un verde', () => {
    expect(problemasDeSignup({})).toHaveLength(1)
    expect(problemasDeSignup(undefined)).toHaveLength(1)
  })

  it('los anónimos habilitados también', () => {
    expect(problemasDeSignup({ disable_signup: true, external: { anonymous_users: true } })).toHaveLength(1)
  })
})

describe('lecturasDeMetadataDelUsuario', () => {
  const ANTES = `
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  INSERT INTO public.perfiles (id, email, nombre, rol, activo)
  VALUES (NEW.id, NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'nombre', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'rol', 'preventista'), true);
  v_meta_sucursal := NEW.raw_user_meta_data->>'sucursal_id';
END;`

  const DESPUES = `
DECLARE
  -- Rol y sucursal: SÓLO de raw_app_meta_data (#1243). raw_user_meta_data lo
  -- escribe el propio usuario al registrarse.
  v_rol TEXT := NULLIF(NEW.raw_app_meta_data->>'rol', '');
BEGIN
  INSERT INTO public.perfiles (id, email, nombre, rol, activo)
  VALUES (NEW.id, NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'nombre', split_part(NEW.email, '@', 1)),
    COALESCE(v_rol, 'preventista'), true);
END;`

  it('el cuerpo de antes de la 403b lee el rol y la sucursal del usuario', () => {
    const l = lecturasDeMetadataDelUsuario(ANTES)
    expect(l).toHaveLength(2)
    expect(l.join(' ')).toContain("'rol'")
    expect(l.join(' ')).toContain("'sucursal_id'")
  })

  it('el de después sólo lee el nombre, y los comentarios no cuentan', () => {
    expect(lecturasDeMetadataDelUsuario(DESPUES)).toEqual([])
  })

  it('leer el JSON entero o por otro camino también cuenta', () => {
    expect(lecturasDeMetadataDelUsuario('v := NEW.raw_user_meta_data;')).toHaveLength(1)
    expect(lecturasDeMetadataDelUsuario("v := NEW.raw_user_meta_data -> 'rol';")).toHaveLength(1)
    expect(lecturasDeMetadataDelUsuario("v := auth.jwt() -> 'user_metadata' ->> 'rol';")).toHaveLength(1)
  })

  it('raw_app_meta_data no es el metadata del usuario', () => {
    expect(lecturasDeMetadataDelUsuario("v := NEW.raw_app_meta_data->>'rol';")).toEqual([])
  })
})

describe('ramasDe', () => {
  it('abre los paréntesis que agrupan OR', () => {
    expect(ramasDe('((id = auth.uid()) OR es_admin())')).toEqual(['id = auth.uid()', 'es_admin()'])
  })

  it('un AND en el nivel de afuera es una sola rama', () => {
    const expr = '(es_admin() AND (sucursal_id = current_sucursal_id()))'
    expect(ramasDe(expr)).toEqual(['es_admin() AND (sucursal_id = current_sucursal_id())'])
  })

  it('no corta adentro de un EXISTS ni de un literal', () => {
    const expr = "(EXISTS ( SELECT 1 FROM x WHERE (a OR b)) OR (nota = 'esto OR aquello'))"
    expect(ramasDe(expr)).toEqual(['EXISTS ( SELECT 1 FROM x WHERE (a OR b))', "nota = 'esto OR aquello'"])
  })

  it('no confunde OR con una palabra que empieza con OR', () => {
    expect(ramasDe('(es_admin() AND (orden = 1))')).toHaveLength(1)
  })

  it('vacía o nula no tiene ramas', () => {
    expect(ramasDe(null)).toEqual([])
    expect(ramasDe('')).toEqual([])
  })
})

describe('ramasAdminSinSucursal', () => {
  // Las de #1244, tal cual estaban en prod.
  it.each([
    ['perfiles_select_admin', 'es_admin()'],
    ['Perfiles: actualizacion propio o admin', '((id = auth.uid()) OR es_admin())'],
    ['cdc_insert', 'es_admin()'],
    ['cp_insert', '(es_admin() OR (preventista_id = auth.uid()))'],
    [
      'metas_gerenciales_admin_select',
      "(EXISTS ( SELECT 1\n   FROM perfiles\n  WHERE ((perfiles.id = auth.uid()) AND (perfiles.rol = 'admin'::text))))",
    ],
  ])('%s: en rojo', (_nombre, expr) => {
    expect(ramasAdminSinSucursal(expr)).toHaveLength(1)
  })

  // Las que ya estaban bien escritas, y las de después de la 404.
  it.each([
    ['mt_zonas_update', '(es_admin() AND (sucursal_id = current_sucursal_id()))'],
    [
      'mt_compra_items_select (vieja)',
      "((es_encargado_o_admin() OR (EXISTS ( SELECT 1\n   FROM perfiles\n  WHERE ((perfiles.id = auth.uid()) AND (perfiles.rol = 'deposito'::text))))) AND (sucursal_id = current_sucursal_id()))",
    ],
    [
      'mt_clientes_insert',
      '(es_preventista() AND (sucursal_id = current_sucursal_id()) AND ((NOT reservado_admin) OR es_admin()))',
    ],
    ['comision_reglas_admin_select', '(es_admin() AND ((sucursal_id IS NULL) OR (sucursal_id = current_sucursal_id())))'],
    [
      'visitas_cliente_select',
      "((sucursal_id = current_sucursal_id()) AND ((preventista_id = auth.uid()) OR (EXISTS ( SELECT 1\n   FROM perfiles p\n  WHERE ((p.id = auth.uid()) AND (p.rol = ANY (ARRAY['admin'::text, 'encargado'::text])))))))",
    ],
    ['perfiles_select_admin (404)', '(es_admin() AND admin_comparte_sucursal_con(id))'],
    ['perfiles_update_admin (404)', '(es_admin() AND admin_abarca_sucursales_de(id))'],
    ['cdc_insert (404)', '(es_admin() AND cliente_de_sucursal_activa(cliente_id))'],
    // Sin rama admin: reservado_admin es una columna, no el rol.
    ['perfiles_update_self', '(id = auth.uid())'],
    ['read_sucursales', "(auth.role() = 'authenticated'::text)"],
  ])('%s: en verde', (_nombre, expr) => {
    expect(ramasAdminSinSucursal(expr)).toEqual([])
  })
})

describe('hallazgosRamaAdmin', () => {
  const cpDelete = { tabla: 'cliente_preventistas', policy: 'cp_delete', cmd: 'DELETE', using: 'es_admin()', check: null }
  const bien = {
    tabla: 'zonas',
    policy: 'mt_zonas_update',
    cmd: 'UPDATE',
    using: '(es_admin() AND (sucursal_id = current_sucursal_id()))',
    check: '(es_admin() AND (sucursal_id = current_sucursal_id()))',
  }

  it('la huella es el md5 de `using|check`, el mismo que calcula pg_policies en SQL', () => {
    // SELECT md5(coalesce(qual,'') || '|' || coalesce(with_check,'')) en prod, 2026-10-28.
    expect(huellaPolicy(cpDelete)).toBe('004e99e26fd7fc30631b300cfdc132a7')
  })

  it('mira USING y WITH CHECK por separado', () => {
    const insert = { tabla: 't', policy: 'p', cmd: 'INSERT', using: null, check: 'es_admin()' }
    const { hallazgos } = hallazgosRamaAdmin([insert, bien])
    expect(hallazgos).toHaveLength(1)
    expect(hallazgos[0].ramas).toEqual([{ clausula: 'WITH CHECK', rama: 'es_admin()' }])
  })

  it('una excepción con la huella vigente la exime', () => {
    const exc = [{ tabla: 'cliente_preventistas', policy: 'cp_delete', huella: huellaPolicy(cpDelete), motivo: '#1272' }]
    expect(hallazgosRamaAdmin([cpDelete, bien], exc)).toEqual({ hallazgos: [], sobrantes: [] })
  })

  it('si la policy cambia, la excepción deja de eximirla', () => {
    const exc = [{ tabla: 'cliente_preventistas', policy: 'cp_delete', huella: 'vieja', motivo: '#1272' }]
    const { hallazgos, sobrantes } = hallazgosRamaAdmin([cpDelete], exc)
    expect(hallazgos).toHaveLength(1)
    expect(hallazgos[0].excepcionVieja).toBe(true)
    expect(sobrantes).toEqual([])
  })

  it('una excepción de una policy que ya mira la sucursal sobra', () => {
    const exc = [{ tabla: 'zonas', policy: 'mt_zonas_update', huella: huellaPolicy(bien), motivo: 'x' }]
    const { hallazgos, sobrantes } = hallazgosRamaAdmin([bien], exc)
    expect(hallazgos).toEqual([])
    expect(sobrantes).toEqual(exc)
  })
})
