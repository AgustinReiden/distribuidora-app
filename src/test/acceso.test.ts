import { describe, expect, it } from 'vitest'
import {
  hallazgosRamaAdmin,
  hallazgosRpcsDefiner,
  huellaPolicy,
  lecturasDeMetadataDelUsuario,
  problemasDeSignup,
  ramasAdminSinSucursal,
  ramasDe,
  // @ts-expect-error -- módulo .mjs de scripts/, sin tipos
} from '../../scripts/lib/acceso.mjs'

/**
 * Lo que deciden los gates de acceso: scripts/check-auth.mjs (#1243) y
 * scripts/check-rama-admin.mjs (#1244), y lo que decide scripts/check-rpcs-definer.mjs
 * (#1291) sobre la salida de su RPC. Leen texto, no ejecutan nada, así que
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

  it('las cinco de #1272, como quedaron en prod (mig 415), ya no tienen rama admin sin sucursal', () => {
    // pg_policies.qual / with_check tal cual, 2026-10-29.
    const cpInsert = {
      tabla: 'cliente_preventistas',
      policy: 'cp_insert',
      cmd: 'INSERT',
      using: null,
      check: '((es_admin() AND cliente_de_sucursal_activa(cliente_id)) OR (preventista_id = auth.uid()))',
    }
    const metas = {
      tabla: 'metas_gerenciales',
      policy: 'metas_gerenciales_admin_select',
      cmd: 'SELECT',
      using:
        '(es_admin() AND ((sucursal_id IN ( SELECT us.sucursal_id\n   FROM usuario_sucursales us\n  WHERE (us.usuario_id = auth.uid()))) ' +
        'OR ((sucursal_id IS NULL) AND (NOT (EXISTS ( SELECT 1\n   FROM sucursales s\n  WHERE (s.activa AND (NOT (EXISTS ( SELECT 1\n' +
        '           FROM usuario_sucursales us\n          WHERE ((us.usuario_id = auth.uid()) AND (us.sucursal_id = s.id))))))))))))',
      check: null,
    }
    const cpDeleteNuevo = { ...cpDelete, using: '(es_admin() AND cliente_de_sucursal_activa(cliente_id))' }
    expect(hallazgosRamaAdmin([cpInsert, metas, cpDeleteNuevo]).hallazgos).toEqual([])
    // Y las de antes, sí: la de metas era un EXISTS sobre perfiles con el rol admin.
    const metasAntes = {
      ...metas,
      using: "(EXISTS ( SELECT 1\n   FROM perfiles\n  WHERE ((perfiles.id = auth.uid()) AND (perfiles.rol = 'admin'::text))))",
    }
    expect(hallazgosRamaAdmin([cpDelete, metasAntes]).hallazgos).toHaveLength(2)
  })

  it('una excepción de una policy que ya mira la sucursal sobra', () => {
    const exc = [{ tabla: 'zonas', policy: 'mt_zonas_update', huella: huellaPolicy(bien), motivo: 'x' }]
    const { hallazgos, sobrantes } = hallazgosRamaAdmin([bien], exc)
    expect(hallazgos).toEqual([])
    expect(sobrantes).toEqual(exc)
  })
})

describe('hallazgosRpcsDefiner', () => {
  // Como devuelve auditoria_rpcs_definer() en prod antes del arreglo de #1291.
  const asignarAntes = {
    firma: 'asignar_usuario_sucursal(uuid,bigint,character varying,boolean)',
    nombre: 'asignar_usuario_sucursal',
    tablas: ['usuario_sucursales'],
    acota: false,
  }
  const cambiarSucursal = { firma: 'cambiar_sucursal(bigint)', nombre: 'cambiar_sucursal', tablas: ['usuario_sucursales'], acota: true }
  const param = (nombre: string, parametro: string, acotado: boolean, clase = 'usuario') => ({
    firma: `${nombre}(…)`,
    nombre,
    parametro,
    clase,
    acotado,
  })

  it('la RPC de #1291 es rojo: escribe usuario_sucursales sin acotar al usuario', () => {
    const r = { gestion_usuarios: [asignarAntes, cambiarSucursal], parametros: [] }
    expect(hallazgosRpcsDefiner(r).gestion).toEqual([asignarAntes])
  })

  it('la gestión de usuarios no tiene excepciones: la lista de permitidas no la exime', () => {
    const r = { gestion_usuarios: [asignarAntes], parametros: [] }
    const permitidas = { 'asignar_usuario_sucursal.p_usuario_id': 'x' }
    expect(hallazgosRpcsDefiner(r, permitidas).gestion).toHaveLength(1)
  })

  it('un parámetro sin acotar es rojo, salvo que esté permitido', () => {
    const r = {
      gestion_usuarios: [],
      parametros: [
        param('asignar_usuario_sucursal', 'p_usuario_id', false),
        param('asignar_usuario_sucursal', 'p_sucursal_id', true, 'sucursal'),
        param('ultima_fecha_caja_cerrada', 'p_sucursal_id', false, 'sucursal'),
      ],
    }
    const { parametros } = hallazgosRpcsDefiner(r, { 'ultima_fecha_caja_cerrada.p_sucursal_id': '#9999' })
    expect(parametros.map((p: { nombre: string; parametro: string }) => `${p.nombre}.${p.parametro}`)).toEqual(['asignar_usuario_sucursal.p_usuario_id'])
  })

  it('va por nombre y no por firma: una sobrecarga nueva sigue permitida', () => {
    const r = { gestion_usuarios: [], parametros: [{ ...param('f', 'p_x', false), firma: 'f(uuid,text)' }] }
    expect(hallazgosRpcsDefiner(r, { 'f.p_x': 'x' }).parametros).toEqual([])
  })

  it('una permitida que ya se acota, o cuya función no existe, sobra (y no es rojo)', () => {
    const r = { gestion_usuarios: [], parametros: [param('f', 'p_x', true)] }
    const { parametros, sobrantes } = hallazgosRpcsDefiner(r, { 'f.p_x': 'x', 'borrada.p_y': 'y' })
    expect(parametros).toEqual([])
    expect(sobrantes).toEqual(['f.p_x', 'borrada.p_y'])
  })

  it('sin listas no hay hallazgos (el script corta antes, con exit 2)', () => {
    expect(hallazgosRpcsDefiner(undefined)).toEqual({ gestion: [], parametros: [], sobrantes: [] })
  })
})
