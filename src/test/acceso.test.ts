import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  hallazgosRamaAdmin,
  hallazgosRolSinActivo,
  hallazgosRpcsDefiner,
  hallazgosStorage,
  hallazgosSucursalCruzada,
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

  // #1330: un OR adentro de un AND son dos caminos, y cada uno se mira entero.
  it('un OR adentro de un AND no se esconde detrás de la sucursal del otro camino', () => {
    expect(ramasAdminSinSucursal('(es_admin() AND ((sucursal_id = current_sucursal_id()) OR compartido))')).toEqual([
      'es_admin() AND compartido',
    ])
  })

  it('el admin adentro de un OR se acota con el AND de afuera', () => {
    expect(ramasAdminSinSucursal('((es_admin() OR x) AND (sucursal_id = current_sucursal_id()))')).toEqual([])
    expect(ramasAdminSinSucursal('((es_admin() OR x) AND y)')).toEqual(['es_admin() AND y'])
  })

  it('abre los AND y los OR anidados', () => {
    const expr = "(a AND (b OR (c AND (es_admin() OR (sucursal_id = 1)))))"
    expect(ramasAdminSinSucursal(expr)).toEqual(['a AND c AND es_admin()'])
  })

  it('lo de adentro de un EXISTS es una hoja', () => {
    const expr = '(es_admin() AND (EXISTS ( SELECT 1 FROM t WHERE ((t.a = 1) OR (t.sucursal_id = 2)))))'
    expect(ramasAdminSinSucursal(expr)).toEqual([])
  })

  it('las dos policies de gastos, tal cual en prod (2026-11-02), en rojo', () => {
    const gastosSelect =
      '((es_admin() AND ((sucursal_id = current_sucursal_id()) OR compartido)) OR (es_encargado_o_admin() AND (NOT compartido) AND (sucursal_id = current_sucursal_id())))'
    const vehiculoKm =
      '(es_encargado_o_admin() AND ((sucursal_id = current_sucursal_id()) OR ((gasto_id IS NOT NULL) AND (EXISTS ( SELECT 1\n   FROM gastos g\n  WHERE (g.id = vehiculo_km.gasto_id))))))'
    expect(ramasAdminSinSucursal(gastosSelect)).toHaveLength(1)
    expect(ramasAdminSinSucursal(vehiculoKm)).toHaveLength(1)
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

describe('hallazgosSucursalCruzada', () => {
  const par = (hija: string, columna: string, padre: string, extra = {}) => ({
    hija, columna, padre, protegida: false, parcial: false, filas: 0, divergentes: 0, ...extra,
  })
  const permitidas = { 'empleados.cliente_id -> clientes': 'de las dos' }

  it('un par con FK compuesta y sin filas cruzadas no es hallazgo', () => {
    const r = hallazgosSucursalCruzada([par('compras', 'proveedor_id', 'proveedores', { protegida: true })], permitidas)
    expect(r.sinProteger).toEqual([])
    expect(r.cruzados).toEqual([])
    expect(r.permitidos).toEqual([])
  })

  it('una FK simple fuera de la lista es rojo: es la clase que vigila el gate', () => {
    const r = hallazgosSucursalCruzada([par('compras', 'proveedor_id', 'proveedores')], permitidas)
    expect(r.sinProteger.map((p: { hija: string }) => p.hija)).toEqual(['compras'])
  })

  it('una FK simple de la lista no es rojo, ni con filas que cruzan', () => {
    const r = hallazgosSucursalCruzada(
      [par('empleados', 'cliente_id', 'clientes', { filas: 2, divergentes: 1 })],
      permitidas,
    )
    expect(r.sinProteger).toEqual([])
    expect(r.cruzados).toEqual([])
    expect(r.permitidos).toHaveLength(1)
    expect(r.sobrantes).toEqual([])
  })

  it('el permiso es por par: otra columna de la misma tabla no entra', () => {
    const r = hallazgosSucursalCruzada([par('empleados', 'vehiculo_id', 'vehiculos')], permitidas)
    expect(r.sinProteger).toHaveLength(1)
    expect(r.permitidos).toEqual([])
  })

  it('filas cruzadas fuera de la lista son rojo, tenga o no FK compuesta', () => {
    const r = hallazgosSucursalCruzada(
      [par('compras', 'proveedor_id', 'proveedores', { protegida: true, divergentes: 1 })],
      permitidas,
    )
    expect(r.cruzados).toHaveLength(1)
  })

  it('un par de la lista que pasó a FK compuesta sobra, y deja de estar exceptuado', () => {
    const r = hallazgosSucursalCruzada(
      [par('empleados', 'cliente_id', 'clientes', { protegida: true, divergentes: 1 })],
      permitidas,
    )
    expect(r.sobrantes).toEqual(['empleados.cliente_id -> clientes'])
    expect(r.permitidos).toEqual([])
    expect(r.cruzados).toHaveLength(1)
  })

  it('un par de la lista que ya no existe sobra', () => {
    expect(hallazgosSucursalCruzada([], permitidas).sobrantes).toEqual(['empleados.cliente_id -> clientes'])
  })
})

describe('scripts/sucursal-cruzada-permitidas.json', () => {
  const ruta = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/sucursal-cruzada-permitidas.json')
  const lista = JSON.parse(fs.readFileSync(ruta, 'utf8')) as { pares: Record<string, string> }

  it('son sólo los tres pares de los empleados "de las dos": uno nuevo necesita una decisión del dueño', () => {
    expect(Object.keys(lista.pares).sort()).toEqual([
      'empleados.cliente_id -> clientes',
      'empleados.vehiculo_id -> vehiculos',
      'gastos.empleado_id -> empleados',
    ])
  })

  it('cada par dice por qué', () => {
    for (const motivo of Object.values(lista.pares)) expect(motivo.length).toBeGreaterThan(20)
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
    const permitidas = { [`${asignarAntes.firma}.p_usuario_id`]: 'x' }
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
    const { parametros } = hallazgosRpcsDefiner(r, { 'ultima_fecha_caja_cerrada(…).p_sucursal_id': '#9999' })
    expect(parametros.map((p: { nombre: string; parametro: string }) => `${p.nombre}.${p.parametro}`)).toEqual(['asignar_usuario_sucursal.p_usuario_id'])
  })

  it('va por firma: una sobrecarga nueva no hereda la excepción, y la vieja sobra', () => {
    const sobrecarga = { ...param('f', 'p_x', false), firma: 'f(uuid,text)' }
    const r = { gestion_usuarios: [], parametros: [sobrecarga] }
    const { parametros, sobrantes } = hallazgosRpcsDefiner(r, { 'f(uuid).p_x': 'x' })
    expect(parametros).toEqual([sobrecarga])
    expect(sobrantes).toEqual(['f(uuid).p_x'])
  })

  it('la clave por nombre ya no exime: es la forma vieja de la lista', () => {
    const r = { gestion_usuarios: [], parametros: [{ ...param('f', 'p_x', false), firma: 'f(uuid)' }] }
    expect(hallazgosRpcsDefiner(r, { 'f.p_x': 'x' }).parametros).toHaveLength(1)
    expect(hallazgosRpcsDefiner(r, { 'f(uuid).p_x': 'x' }).parametros).toEqual([])
  })

  it('una permitida que ya se acota, o cuya función no existe, sobra (y no es rojo)', () => {
    const r = { gestion_usuarios: [], parametros: [param('f', 'p_x', true)] }
    const { parametros, sobrantes } = hallazgosRpcsDefiner(r, { 'f(…).p_x': 'x', 'borrada(…).p_y': 'y' })
    expect(parametros).toEqual([])
    expect(sobrantes).toEqual(['f(…).p_x', 'borrada(…).p_y'])
  })

  it('sin listas no hay hallazgos (el script corta antes, con exit 2)', () => {
    expect(hallazgosRpcsDefiner(undefined)).toEqual({
      gestion: [],
      parametros: [],
      sobrantes: [],
      tablas: [],
      sobrantesTablas: [],
      guardas: [],
    })
  })

  // #1488: como devolvería guardas_nulas en prod antes de la 469.
  it('una guarda que falla abierta con NULL es rojo, y no tiene lista de permitidas', () => {
    const aceptar = { firma: 'aceptar_movimiento_sucursal(bigint,jsonb)', nombre: 'aceptar_movimiento_sucursal' }
    const r = { gestion_usuarios: [], parametros: [], tablas_sucursal: [], guardas_nulas: [aceptar] }
    expect(hallazgosRpcsDefiner(r).guardas).toEqual([aceptar])
    expect(hallazgosRpcsDefiner(r, { [`${aceptar.firma}.p_movimiento_id`]: 'x' }, { [aceptar.firma]: 'x' }).guardas).toEqual([aceptar])
  })

  // #1438: como devuelve auditoria_rpcs_definer() en prod antes del arreglo.
  const tabla = (firma: string, tablas: string[], nombra_sucursal: boolean) => ({
    firma,
    nombre: firma.slice(0, firma.indexOf('(')),
    tablas,
    nombra_sucursal,
  })
  const preciosAntes = tabla('actualizar_precios_masivo(jsonb)', ['productos'], false)

  it('una definer que escribe una tabla con sucursal sin nombrarla es rojo (la de #1438)', () => {
    const r = {
      gestion_usuarios: [],
      parametros: [],
      tablas_sucursal: [preciosAntes, tabla('cambiar_sucursal(bigint)', ['usuario_sucursales'], true)],
    }
    expect(hallazgosRpcsDefiner(r).tablas).toEqual([preciosAntes])
  })

  it('una definer nueva sin nombrar la sucursal es rojo aunque la lista tenga otras (control negativo)', () => {
    const nueva = tabla('zz_nueva(bigint)', ['pedidos'], false)
    const r = { gestion_usuarios: [], parametros: [], tablas_sucursal: [nueva, preciosAntes] }
    const { tablas } = hallazgosRpcsDefiner(r, {}, { 'actualizar_precios_masivo(jsonb)': 'x' })
    expect(tablas).toEqual([nueva])
  })

  it('va por firma: una sobrecarga nueva no hereda la excepción, y la vieja sobra', () => {
    const sobrecarga = tabla('f(bigint,text)', ['pedidos'], false)
    const r = { gestion_usuarios: [], parametros: [], tablas_sucursal: [sobrecarga] }
    const { tablas, sobrantesTablas } = hallazgosRpcsDefiner(r, {}, { 'f(bigint)': 'x' })
    expect(tablas).toEqual([sobrecarga])
    expect(sobrantesTablas).toEqual(['f(bigint)'])
  })

  it('una permitida que ya nombra la sucursal, o cuya función no existe, sobra (y no es rojo)', () => {
    const r = { gestion_usuarios: [], parametros: [], tablas_sucursal: [tabla('f(bigint)', ['pedidos'], true)] }
    const { tablas, sobrantesTablas } = hallazgosRpcsDefiner(r, {}, { 'f(bigint)': 'x', 'borrada()': 'y' })
    expect(tablas).toEqual([])
    expect(sobrantesTablas).toEqual(['f(bigint)', 'borrada()'])
  })

  it('las dos listas no se mezclan: un parámetro permitido no exime la tabla, ni al revés', () => {
    const r = {
      gestion_usuarios: [],
      parametros: [{ ...param('f', 'p_sucursal_id', false, 'sucursal'), firma: 'f(bigint)' }],
      tablas_sucursal: [tabla('f(bigint)', ['pedidos'], false)],
    }
    const soloParametro = hallazgosRpcsDefiner(r, { 'f(bigint).p_sucursal_id': 'x' })
    expect(soloParametro.parametros).toEqual([])
    expect(soloParametro.tablas).toHaveLength(1)
    const soloTabla = hallazgosRpcsDefiner(r, {}, { 'f(bigint)': 'x' })
    expect(soloTabla.parametros).toHaveLength(1)
    expect(soloTabla.tablas).toEqual([])
  })
})

describe('scripts/rpcs-definer-permitidas.json', () => {
  const ruta = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/rpcs-definer-permitidas.json')
  const lista = JSON.parse(fs.readFileSync(ruta, 'utf8')) as {
    parametros: Record<string, string>
    tablas: Record<string, string>
  }

  it('"tablas" son sólo las seis que ya estaban bien al nacer el gate (#1438): una nueva se acota, no se suma', () => {
    expect(Object.keys(lista.tablas).sort()).toEqual([
      'bot_admin_guardar_aviso_atrasados(uuid,boolean,integer,integer[])',
      'cliente_admite_adelanto_sueldo(bigint)',
      'guardar_rubro_gasto(jsonb)',
      'marcar_notificacion_leida(bigint)',
      'marcar_todas_notificaciones_leidas()',
      'recalcular_recorrido(bigint)',
    ])
  })

  it('las tres de #1438 no están exceptuadas: se arreglaron', () => {
    for (const firma of Object.keys(lista.tablas)) {
      expect(firma).not.toMatch(/^(actualizar_precios_masivo|get_audit_history|get_suspicious_activity)\(/)
    }
  })

  it('cada excepción dice por qué, y va por firma', () => {
    for (const [clave, motivo] of [...Object.entries(lista.parametros), ...Object.entries(lista.tablas)]) {
      expect(motivo.length).toBeGreaterThan(20)
      expect(clave).toMatch(/^[a-z_0-9]+\([^)]*\)/)
    }
  })
})

describe('hallazgosStorage', () => {
  // El texto como lo devuelve pg_policies después de la mig de #1474.
  const MIS_SUCURSALES =
    "((storage.foldername(name))[1] IN ( SELECT (us.sucursal_id)::text AS sucursal_id FROM usuario_sucursales us WHERE (us.usuario_id = auth.uid())))"
  const select = {
    policy: 'facturas_select_encargado_o_admin',
    cmd: 'SELECT',
    permissive: 'PERMISSIVE',
    roles: ['authenticated'],
    using: `((bucket_id = 'facturas'::text) AND es_encargado_o_admin() AND ${MIS_SUCURSALES})`,
    check: null,
  }
  const insert = {
    ...select,
    policy: 'facturas_insert_encargado_o_admin',
    cmd: 'INSERT',
    using: null,
    check: select.using,
  }
  const privado = [{ id: 'facturas', public: false }]

  it('las policies de facturas que miran la sucursal del path pasan', () => {
    expect(hallazgosStorage({ politicas: [select, insert], buckets: privado })).toEqual({ hallazgos: [], sobrantes: [] })
  })

  it('la policy de la 239, que mira sólo el rol, es roja', () => {
    const vieja = { ...select, using: "((bucket_id = 'facturas'::text) AND es_encargado_o_admin())" }
    const { hallazgos } = hallazgosStorage({ politicas: [vieja], buckets: privado })
    expect(hallazgos).toHaveLength(1)
    expect(hallazgos[0].motivos[0]).toMatch(/no mira la sucursal del path/)
  })

  it('nombrar la sucursal activa sin mirar el path no alcanza', () => {
    const p = { ...select, using: "((bucket_id = 'facturas'::text) AND (current_sucursal_id() = 1))" }
    expect(hallazgosStorage({ politicas: [p], buckets: privado }).hallazgos).toHaveLength(1)
  })

  it('un OR que abre un camino sin sucursal es rojo', () => {
    const p = { ...select, using: `((bucket_id = 'facturas'::text) AND (es_admin() OR ${MIS_SUCURSALES}))` }
    const { hallazgos } = hallazgosStorage({ politicas: [p], buckets: privado })
    expect(hallazgos).toHaveLength(1)
    expect(hallazgos[0].motivos).toHaveLength(1)
  })

  it('una policy sin bucket vale para todos y es roja', () => {
    const p = { ...select, using: `(es_admin() AND ${MIS_SUCURSALES})` }
    expect(hallazgosStorage({ politicas: [p], buckets: privado }).hallazgos[0].motivos[0]).toMatch(/no nombra su bucket/)
  })

  it('una policy TO public o anon es roja aunque mire la sucursal', () => {
    for (const roles of [['public'], ['anon'], ['authenticated', 'anon']]) {
      const { hallazgos } = hallazgosStorage({ politicas: [{ ...select, roles }], buckets: privado })
      expect(hallazgos[0].motivos[0]).toMatch(/tiene que ir TO authenticated/)
    }
  })

  it('una RESTRICTIVE no abre nada y no se mira', () => {
    const p = { ...select, permissive: 'RESTRICTIVE', using: "(bucket_id = 'facturas'::text)" }
    expect(hallazgosStorage({ politicas: [p], buckets: privado }).hallazgos).toEqual([])
  })

  it('un bucket público es rojo salvo que esté exceptuado', () => {
    const buckets = [{ id: 'logos', public: true }]
    expect(hallazgosStorage({ politicas: [], buckets }).hallazgos).toEqual([
      { bucket: 'logos', motivos: ['el bucket es público: se lee por URL sin pasar por RLS'] },
    ])
    expect(hallazgosStorage({ politicas: [], buckets }, [{ bucket: 'logos', motivo: 'x' }]).hallazgos).toEqual([])
  })

  it('una excepción vale para ESA expresión: si cambia, vuelve a salir; si sobra, se avisa', () => {
    const vieja = { ...select, using: "((bucket_id = 'facturas'::text) AND es_encargado_o_admin())" }
    const exc = { policy: vieja.policy, huella: huellaPolicy(vieja), motivo: 'x' }
    expect(hallazgosStorage({ politicas: [vieja], buckets: privado }, [exc]).hallazgos).toEqual([])
    const cambiada = { ...vieja, using: "((bucket_id = 'facturas'::text) AND es_admin())" }
    const r = hallazgosStorage({ politicas: [cambiada], buckets: privado }, [exc])
    expect(r.hallazgos[0].excepcionVieja).toBe(true)
    expect(hallazgosStorage({ politicas: [select], buckets: privado }, [exc]).sobrantes).toEqual([exc])
  })
})

describe('hallazgosRolSinActivo', () => {
  // Como devuelve auditoria_rol_sin_activo() en prod antes de la migración de #1490.
  const gerencial = {
    firma: 'reporte_gerencial(bigint,date,date,boolean,boolean)',
    definer: true,
    lectura: "IF NOT v_es_servicio THEN IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = '') THEN RAISE EXCEPTION ''",
  }
  const lote = {
    firma: 'ajustar_lote(bigint,integer)',
    definer: true,
    lectura: 'SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid()',
  }

  it('una lectura del rol sin activo que no está permitida es rojo, con sus lecturas', () => {
    expect(hallazgosRolSinActivo({ funciones: 2, lecturas: [gerencial, lote] }, { [lote.firma]: 'x' })).toEqual({
      sinActivo: [{ firma: gerencial.firma, lecturas: [gerencial.lectura] }],
      sobrantes: [],
    })
  })

  it('agrupa varias lecturas de la misma función', () => {
    const otra = { ...gerencial, lectura: 'SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid()' }
    expect(hallazgosRolSinActivo({ lecturas: [gerencial, otra] }).sinActivo).toEqual([
      { firma: gerencial.firma, lecturas: [gerencial.lectura, otra.lectura] },
    ])
  })

  it('la permitida que ya no lee el rol sin activo sobra, y no es rojo', () => {
    expect(hallazgosRolSinActivo({ lecturas: [] }, { [lote.firma]: 'x' })).toEqual({
      sinActivo: [],
      sobrantes: [lote.firma],
    })
  })

  it('va por firma: una sobrecarga nueva no hereda la excepción', () => {
    const sobrecarga = { ...lote, firma: 'ajustar_lote(bigint,integer,text)' }
    expect(hallazgosRolSinActivo({ lecturas: [sobrecarga] }, { [lote.firma]: 'x' }).sinActivo).toHaveLength(1)
  })
})

describe('scripts/rol-sin-activo-permitidas.json', () => {
  const ruta = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/rol-sin-activo-permitidas.json')
  const lista = JSON.parse(fs.readFileSync(ruta, 'utf8')) as { funciones: Record<string, string> }

  // Las que al nacer el gate (#1490) leían el rol sin activo pero ya frenaban a un desactivado
  // por otro lado. La lista sólo se achica: una función nueva mira activo, no se suma.
  const alNacer = [
    'actualizar_alertas_combos(numeric,numeric)',
    'actualizar_alertas_vencimiento(integer,integer)',
    'actualizar_monto_minimo_pedido(numeric)',
    'actualizar_mostrar_sin_stock(boolean)',
    'actualizar_politica_minimo_pedido(text,numeric,numeric,numeric)',
    'actualizar_preventista_pedido(bigint,uuid)',
    'actualizar_ventana_precio_anterior(integer)',
    'ajustar_lote(bigint,integer)',
    'anular_nota_credito_venta(bigint,text)',
    'bot_admin_guardar_aviso_atrasados(uuid,boolean,integer,integer[])',
    'bot_admin_guardar_config_digest(uuid,boolean,integer,integer[],text[])',
    'bot_admin_listar_config_digest()',
    'cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
    'cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)',
    'cancelar_pedido_con_stock(bigint,text,uuid,text)',
    'crear_lote_manual(bigint,date,integer)',
    'dar_de_baja_lote(bigint,integer,text)',
    'dividir_regalo_pedido(bigint,jsonb,text,uuid)',
    'guardar_producto_medidas(jsonb)',
    'hojas_de_ruta_deposito(date)',
    'marcar_no_entregado(bigint,character varying,text)',
    'obtener_geolocalizacion_preventistas(date,date)',
    'obtener_resumen_cuenta_cliente(integer)',
    'quitar_pedido_de_recorridos_activos(bigint)',
    'registrar_equivalencias_proveedor(bigint,jsonb)',
    'registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)',
    'registrar_merma_manual(bigint,integer,text,text,bigint,jsonb)',
    'registrar_nota_credito_lote(bigint,numeric,text,text)',
    'registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
    'registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)',
    'reporte_vencimientos(integer)',
    'sincronizar_lotes_compra(bigint,jsonb)',
    'sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
    'tablero_guardar_meta_cobertura(bigint,date,numeric,integer)',
    'verificar_duplicado_cliente(numeric,numeric,text,bigint)',
  ]

  it('sólo se achica: ninguna permitida es nueva', () => {
    for (const firma of Object.keys(lista.funciones)) expect(alNacer).toContain(firma)
  })

  it('ninguna de las 22 que arregló #1490 vuelve a estar permitida', () => {
    for (const firma of Object.keys(lista.funciones)) {
      expect(firma).not.toMatch(
        /^(reporte_(gerencial|alerta_detalle|bonificaciones|cuentas_por_cobrar|mermas|rechazos|rentabilidad|valuacion_inventario|ventas_por_cliente|ventas_por_preventista)|posicion_fiscal|auditoria_(integridad|sucursal_cruzada)|guardar_(analisis_mensual|meta_gerencial)|migraciones_aplicadas|asegurar_cargo_concepto|bot_admin_(audit_log|audit_summary|digests_enviados|listar_vinculados|toggle_usuario))\(/,
      )
    }
  })

  it('cada excepción dice por qué, y va por firma', () => {
    for (const [firma, motivo] of Object.entries(lista.funciones)) {
      expect(motivo.length).toBeGreaterThan(20)
      expect(firma).toMatch(/^[a-z_0-9]+\([^)]*\)$/)
    }
  })
})
