import { describe, expect, it } from 'vitest'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { analizarRepo } from '../../scripts/lib/embedsSelect.mjs'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { columnasDeOr, huerfanos, parsearSelect, pruebasDe, queryString, verificarGrants } from '../../scripts/lib/embedsPostgrest.mjs'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { aplicarListaBlanca } from '../../scripts/lib/embedsRepo.mjs'

/**
 * El extractor del gate `scripts/check-embeds.mjs` (#1008, #1256) lee texto,
 * no AST. Estos casos fijan cómo atribuye cada select y cada filtro a SU
 * consulta, qué manda a PostgREST para probarlos y qué exige de los grants de
 * `authenticated`, porque un extractor que se pierde o confunde selects da un
 * gate verde que no mira nada. El test del repo (`embedsRepo.test.ts`) corre
 * el mismo extractor sobre los fuentes de verdad.
 */

type Filtro = { tipo: string; ruta: string[]; columnas: string[] | null; archivo: string; linea: number; firma: string; grupo: string }
type Consulta = {
  id: string
  archivo: string
  linea: number
  tabla: string
  selects: { archivo: string; linea: number; valores: string[] | null }[]
  variantes: string[]
  filtros: Filtro[]
}
type Omitido = { archivo: string; linea: number; motivo: string; firma: string }
type Resultado = { consultas: Consulta[]; omitidos: Omitido[] }
type Prueba = { select: string; params: [string, string][] }

const analizar = (archivos: Record<string, string>): Resultado => analizarRepo(Object.entries(archivos))
const uno = (src: string, ruta = 'src/a.ts'): Resultado => analizar({ [ruta]: src })
const embebidos = (c: Consulta) => c.filtros.filter((f) => f.ruta.length)
const pruebas = (c: Consulta): Prueba[] => pruebasDe(c).pruebas
const qs = (p: Prueba) => decodeURIComponent(queryString(p))

describe('extracción: el select y la tabla de su propia cadena', () => {
  it('literal con comillas simples y la tabla del .from()', () => {
    const { consultas, omitidos } = uno(`supabase.from('pedidos').select('id, cliente:clientes!inner(id)')`)
    expect(omitidos).toEqual([])
    expect(consultas).toHaveLength(1)
    expect(consultas[0]).toMatchObject({ tabla: 'pedidos', variantes: ['id,cliente:clientes!inner(id)'], linea: 1 })
  })

  it('template multilínea: saca los espacios como supabase-js (PostgREST no tolera "( id")', () => {
    const src = [
      `const q = supabase`,
      `  .from('salvedades_items')`,
      `  .select(\``,
      `    *,`,
      `    producto:productos!salvedades_items_producto_id_fkey( id, nombre )`,
      `  \`)`,
    ].join('\n')
    const [c] = uno(src).consultas
    expect(c.tabla).toBe('salvedades_items')
    expect(c.variantes).toEqual(['*,producto:productos!salvedades_items_producto_id_fkey(id,nombre)'])
  })

  it('dos consultas seguidas sin `;` no se confunden de tabla (el extractor viejo tomaba el último .from cercano)', () => {
    const src = [
      `const { data: pedidos } = await supabase.from('pedidos').select('id')`,
      `const { data: compras } = await supabase`,
      `  .from('compras')`,
      `  // un comentario en el medio de la cadena`,
      `  .select(\`id, proveedor:proveedores(id)\`)`,
      `const { data: otro } = await supabase.rpc('fn').select('id, cliente:clientes(id)')`,
    ].join('\n')
    const { consultas, omitidos } = uno(src)
    expect(consultas.map((c) => [c.tabla, c.variantes[0]])).toEqual([
      ['pedidos', 'id'],
      ['compras', 'id,proveedor:proveedores(id)'],
    ])
    // El select del rpc no tiene .from en su cadena: no se le pega la tabla de arriba.
    expect(omitidos).toHaveLength(1)
    expect(omitidos[0]).toMatchObject({ linea: 6 })
    expect(omitidos[0].motivo).toMatch(/fuera de una consulta atribuible/)
  })

  it('sigue la cadena con ?., !, genéricos, comentarios y paréntesis de cast', () => {
    const src = [
      `const r = await (supabase`,
      `  ?.from('compra_items')`,
      `  .select('id, compra:compras!inner(id, fecha_compra)') /* comentario */`,
      `  .returns<Fila[]>()!`,
      `  .order('compra(fecha_compra)', { ascending: false }) as unknown as X)`,
    ].join('\n')
    const [c] = uno(src).consultas
    expect(c.tabla).toBe('compra_items')
    expect(embebidos(c)).toMatchObject([{ tipo: 'ordenRel', ruta: ['compra'], columnas: ['fecha_compra'] }])
  })

  it('Array.from y otros .from con mayúscula no son consultas', () => {
    const { consultas, omitidos } = uno(`const xs = Array.from(new Set(ids)).filter(Boolean)`)
    expect(consultas).toEqual([])
    expect(omitidos).toEqual([])
  })

  it('ignora lo que no tiene embed al probar, pero lo devuelve (los grants lo miran igual)', () => {
    const src = [
      `supabase.from('a').select('*')`,
      `supabase.from('b').select('id, nombre')`,
      `supabase.from('c').insert([{}]).select().single()`,
    ].join('\n')
    const { consultas } = uno(src)
    expect(consultas.map((c) => [c.tabla, c.variantes])).toEqual([['a', ['*']], ['b', ['id,nombre']], ['c', ['*']]])
    expect(consultas.flatMap(pruebas)).toEqual([])
  })

  it('edge functions: comillas dobles y `;`', () => {
    const { consultas } = uno(`const r = await sb.from("bot_usuarios").select("id, perfiles!inner(rol)").eq("perfiles.activo", true);`, 'supabase/functions/x/index.ts')
    expect(consultas[0]).toMatchObject({ tabla: 'bot_usuarios', variantes: ['id,perfiles!inner(rol)'] })
    expect(embebidos(consultas[0])).toMatchObject([{ ruta: ['perfiles'], columnas: ['activo'] }])
  })
})

describe('extracción: constantes', () => {
  it('resuelve ${CONSTANTE} de la misma fuente', () => {
    const src = [`const COLS = 'id, nombre' as const`, `const q = supabase.from('pedidos').select(\`*, cliente:clientes(\${COLS})\`)`].join('\n')
    expect(uno(src).consultas[0].variantes).toEqual(['*,cliente:clientes(id,nombre)'])
  })

  it('select(CONSTANTE) y select(local) con las dos ramas de un ternario (y no el literal de la condición)', () => {
    const src = [
      `const A = 'id, c:clientes!inner(id)' as const`,
      `const B = 'id, c:clientes(id)'`,
      `function f(modo: string) {`,
      `  const selectStr = modo === 'x' ? A : B`,
      `  return supabase.from('pedidos').select(selectStr)`,
      `}`,
    ].join('\n')
    expect(uno(src).consultas[0].variantes).toEqual(['id,c:clientes!inner(id)', 'id,c:clientes(id)'])
  })

  it('sigue un import relativo y uno con @/', () => {
    const { consultas, omitidos } = analizar({
      'src/lib/cols.ts': `export const COLS = 'id, nombre'\nexport const OTRAS = 'id'`,
      'src/hooks/q.ts': [
        `import { COLS as C } from '../lib/cols'`,
        `import { OTRAS } from '@/lib/cols'`,
        `supabase.from('pedidos').select(\`id, cliente:clientes(\${C}), items:pedido_items(\${OTRAS})\`)`,
      ].join('\n'),
    })
    expect(omitidos).toEqual([])
    expect(consultas[0].variantes).toEqual(['id,cliente:clientes(id,nombre),items:pedido_items(id)'])
  })

  it('una constante local gana a otra del mismo nombre en otro archivo (el gate viejo probaba la equivocada)', () => {
    const { consultas } = analizar({
      'src/a.ts': `const SELECT = 'id, x:clientes(id)'\nsupabase.from('pedidos').select(SELECT)`,
      'src/b.ts': `const SELECT = 'id, y:perfiles(id)'\nsupabase.from('recorridos').select(SELECT)`,
    })
    expect(consultas.map((c) => [c.tabla, c.variantes[0]])).toEqual([
      ['pedidos', 'id,x:clientes(id)'],
      ['recorridos', 'id,y:perfiles(id)'],
    ])
  })

  it('un ${...} que no se puede resolver es un omitido, no "una columna cualquiera"', () => {
    const { consultas, omitidos } = uno(`supabase.from('pedidos').select(\`*, c:clientes(\${armar()})\`)`)
    expect(consultas[0].variantes).toEqual([])
    expect(omitidos).toMatchObject([{ motivo: expect.stringMatching(/select no resuelto/) }])
  })

  it('una tabla que no se puede resolver es un omitido, con firma estable para la lista blanca', () => {
    const { omitidos } = uno(`function f(tabla: string) { return supabase.from(tabla).select('id') }`)
    expect(omitidos).toMatchObject([{ archivo: 'src/a.ts', firma: 'from(tabla)' }])
  })

  it('la columna de un filtro sale del tipo literal del parámetro; si no, es un omitido', () => {
    const conTipo = uno(`function f(columna: 'cliente_id' | 'pedido_id', id: string) { return supabase.from('nc').select('id, c:clientes(id)').eq(columna, id) }`)
    expect(conTipo.omitidos).toEqual([])
    expect(conTipo.consultas[0].filtros).toMatchObject([{ tipo: 'filtro', ruta: [], columnas: ['cliente_id', 'pedido_id'] }])
    const sinTipo = uno(`function f(columna: string) { return supabase.from('nc').select('id').eq(columna, 1) }`)
    expect(sinTipo.omitidos).toMatchObject([{ motivo: expect.stringMatching(/columna no resuelta/) }])
  })
})

describe('extracción: continuaciones por variable y helpers', () => {
  it('let q = supabase.from(...) seguido de q = q.eq(...) y q.order(...)', () => {
    const src = [
      `async function f(desde: string) {`,
      `  let q = supabase.from('compra_items').select('id, compra:compras!inner(id, fecha_compra)')`,
      `  if (desde) q = q.gte('compra.fecha_compra', desde)`,
      `  q.order('compra(fecha_compra)')`,
      `  return q`,
      `}`,
      `async function g() {`,
      `  // Otra variable con el mismo nombre: es otra consulta.`,
      `  let q = supabase.from('pedidos').select('id, cliente:clientes(id)')`,
      `  q = q.eq('cliente.id', 1)`,
      `}`,
    ].join('\n')
    const { consultas, omitidos } = uno(src)
    expect(omitidos).toEqual([])
    expect(consultas.map((c) => [c.tabla, embebidos(c).map((f) => `${f.tipo}:${f.ruta}.${f.columnas}@${f.linea}`)])).toEqual([
      ['compra_items', ['filtro:compra.fecha_compra@3', 'ordenRel:compra.fecha_compra@4']],
      ['pedidos', ['filtro:cliente.id@10']],
    ])
  })

  it('un helper de otro archivo que filtra el builder que le pasan, aplicado a cada consulta', () => {
    const { consultas, omitidos } = analizar({
      'src/utils/filtros.ts': [
        `export function aplicarFiltros<Q extends Filtrable>(query: Q, busqueda?: string): Q {`,
        `  let q = query`,
        `  if (busqueda) {`,
        `    q = q.or(\`nombre.ilike.%\${busqueda}%,cuit.ilike.%\${busqueda}%\`, { referencedTable: 'clientes' })`,
        `  }`,
        `  return q`,
        `}`,
      ].join('\n'),
      'src/hooks/lista.ts': [
        `import { aplicarFiltros } from '../utils/filtros'`,
        `const armar = () => {`,
        `  let query = supabase.from('pedidos').select('id, cliente:clientes!inner(id)').order('id')`,
        `  query = aplicarFiltros(query, 'x')`,
        `  return query`,
        `}`,
      ].join('\n'),
      'src/hooks/stats.ts': [
        `import { aplicarFiltros } from '../utils/filtros'`,
        `const r = aplicarFiltros(supabase.from('pedidos').select('estado, cliente:clientes!inner(id)'), 'x').range(0, 9)`,
      ].join('\n'),
    })
    expect(omitidos).toEqual([])
    expect(consultas).toHaveLength(2)
    for (const c of consultas) {
      expect(embebidos(c)).toMatchObject([
        { tipo: 'or', ruta: ['clientes'], columnas: ['nombre', 'cuit'], archivo: 'src/utils/filtros.ts', linea: 4 },
      ])
    }
  })

  it('ternario de dos .from en una variable: el filtro del helper va con la rama que tiene el embed', () => {
    const src = [
      `export const SEL = 'id, monto'`,
      `export const SEL_T = 'id, monto, pedido:pedidos!inner(transportista_id)'`,
      `function filtrar<Q>(q: Q, t?: string): Q {`,
      `  if (t) q = q.eq('pedido.transportista_id', t)`,
      `  return q`,
      `}`,
      `function f(t?: string) {`,
      `  const base = t`,
      `    ? supabase.from('salvedades_items').select(SEL_T)`,
      `    : supabase.from('salvedades_items').select(SEL)`,
      `  return filtrar(base, t).order('id')`,
      `}`,
    ].join('\n')
    const { consultas, omitidos } = uno(src)
    expect(omitidos).toEqual([])
    expect(consultas.map((c) => embebidos(c).length)).toEqual([1, 1])
    // La rama sin `pedido` no hace huérfano al filtro: el grupo sí lo tiene.
    expect(huerfanos(consultas)).toEqual([])
    expect(pruebas(consultas[0]).map(qs)).toEqual([
      'select=id,monto,pedido:pedidos!inner(transportista_id)&pedido.transportista_id=is.null&limit=0',
    ])
    expect(pruebas(consultas[1])).toEqual([])
  })

  it('un filtro embebido sobre algo que ningún select embebe es huérfano (en runtime, PGRST108)', () => {
    const { consultas } = uno(`supabase.from('pedidos').select('id, cliente:clientes(id)').eq('otro.id', 1)`)
    expect(huerfanos(consultas)).toMatchObject([{ ruta: ['otro'], tabla: 'pedidos' }])
  })

  it('un helper con filtros embebidos aplicado a algo que no es una consulta conocida es un omitido', () => {
    const src = [
      `function filtrar(q, t) { return q.eq('pedido.transportista_id', t) }`,
      `const r = filtrar(obtenerBuilder(), 1)`,
    ].join('\n')
    expect(uno(src).omitidos).toMatchObject([{ linea: 2, motivo: expect.stringMatching(/filtrar\(\)/) }])
  })

  it('un filtro embebido sobre una cadena que no se puede atribuir es un omitido', () => {
    const { omitidos } = uno(`const r = await algo().eq('cliente.id', 1)`)
    expect(omitidos).toMatchObject([{ motivo: expect.stringMatching(/fuera de una consulta atribuible/) }])
  })
})

describe('filtros y órdenes sobre embeds: lo que se manda a PostgREST', () => {
  it('cada forma con su parámetro, todas en el mismo request y con valores inocuos', () => {
    const src = [
      `supabase.from('pedidos')`,
      `  .select('id, cliente:clientes!inner(id, nombre), items:pedido_items(id)')`,
      `  .eq('estado', 'x')`,
      `  .gte('cliente.id', 5)`,
      `  .in('clientes.zona', ['a'])`,
      `  .not('cliente.cuit', 'is', null)`,
      `  .filter('cliente.nombre', 'ilike', '%x%')`,
      `  .match({ 'cliente.activo': true, estado: 'x' })`,
      `  .or('nombre.ilike.%a%,and(cuit.is.null,not.or(zona.eq.1,zona.eq.2))', { referencedTable: 'cliente' })`,
      `  .order('id', { foreignTable: 'items', ascending: false })`,
      `  .order('cliente(nombre)')`,
      `  .limit(5, { referencedTable: 'items' })`,
    ].join('\n')
    const [c] = uno(src).consultas
    expect(pruebas(c).map(qs)).toEqual([
      'select=id,cliente:clientes!inner(id,nombre),items:pedido_items(id)'
      + '&cliente.id=is.null&clientes.zona=is.null&cliente.cuit=is.null&cliente.nombre=is.null&cliente.activo=is.null'
      + '&cliente.or=(nombre.is.null,cuit.is.null,zona.is.null)&items.order=id&items.limit=0&order=cliente(nombre)&limit=0',
    ])
  })

  it('una variante del select sin el embed del filtro se prueba sin él y se informa', () => {
    const src = [
      `function f(buscar: boolean, termino: string) {`,
      `  const sel = buscar ? 'estado, cliente:clientes!inner(id)' : 'estado'`,
      `  let q = supabase.from('pedidos').select(sel)`,
      `  if (buscar) q = q.or(\`nombre.ilike.%\${termino}%\`, { referencedTable: 'clientes' })`,
      `}`,
    ].join('\n')
    const [c] = uno(src).consultas
    const r = pruebasDe(c)
    expect(r.pruebas.map(qs)).toEqual(['select=estado,cliente:clientes!inner(id)&clientes.or=(nombre.is.null)&limit=0'])
    expect(r.noAplicados).toMatchObject([{ select: 'estado' }])
    expect(huerfanos([c])).toEqual([])
  })

  it('una columna interpolada en un .or() embebido es un omitido (los valores interpolados no)', () => {
    const { omitidos } = uno(`supabase.from('pedidos').select('id, c:clientes(id)').or(\`\${campo}.eq.1\`, { referencedTable: 'c' })`)
    expect(omitidos).toMatchObject([{ motivo: expect.stringMatching(/columna interpolada/) }])
  })
})

describe('parsearSelect', () => {
  it('columnas, alias, casts, JSON, agregados, conteo, embeds con hints, spread', () => {
    expect(parsearSelect('*,id,monto:total::text,datos->a->>b,total.sum(),count(),cliente:clientes!fk!inner(id),...perfiles(nombre),items(count)')).toEqual([
      { tipo: 'estrella' },
      { tipo: 'columna', alias: null, columna: 'id', agregado: null },
      { tipo: 'columna', alias: 'monto', columna: 'total', agregado: null },
      { tipo: 'columna', alias: null, columna: 'datos', agregado: null },
      { tipo: 'columna', alias: null, columna: 'total', agregado: 'sum' },
      { tipo: 'conteo', alias: null },
      { tipo: 'embed', alias: 'cliente', nombre: 'clientes', hints: ['fk'], inner: true, spread: false, hijos: [{ tipo: 'columna', alias: null, columna: 'id', agregado: null }] },
      { tipo: 'embed', alias: null, nombre: 'perfiles', hints: [], inner: false, spread: true, hijos: [{ tipo: 'columna', alias: null, columna: 'nombre', agregado: null }] },
      { tipo: 'embed', alias: null, nombre: 'items', hints: [], inner: false, spread: false, hijos: [{ tipo: 'columna', alias: null, columna: 'count', agregado: null }] },
    ])
  })

  it('un embed vacío para filtrar (`rel!inner()`) y anidados', () => {
    expect(parsearSelect('id,c:clientes!inner(),r:recorridos(p:pedidos(id))')[2]).toMatchObject({
      nombre: 'recorridos', hijos: [{ tipo: 'embed', alias: 'p', nombre: 'pedidos' }],
    })
  })

  it('tira con lo que no entiende', () => {
    expect(() => parsearSelect('id,cliente:clientes(id')).toThrow(/falta "\)"/)
    expect(() => parsearSelect('id,,nombre')).toThrow(/se esperaba un nombre/)
    expect(() => parsearSelect('...perfiles')).toThrow(/spread/)
  })
})

describe('columnasDeOr', () => {
  it('columna antes del primer operador; and/or anidados; valores con puntos, comas y comodines', () => {
    expect(columnasDeOr('nombre.ilike.%\u0001%,and(fecha.gte.2024.01.01,estado.in.(a,b)),not.or(cuit.is.null,x.eq.1)'))
      .toEqual(['nombre', 'fecha', 'estado', 'cuit', 'x'])
    expect(columnasDeOr('cliente.nombre.eq.x')).toEqual(['cliente.nombre'])
    expect(() => columnasDeOr('nombre')).toThrow(/sin operador/)
  })
})

describe('verificarGrants (mapa de privilegios de mentira)', () => {
  // productos se concede columna por columna y los costos quedan afuera (#974).
  const mapa = {
    tablas: {
      productos: { columnas: ['id', 'nombre', 'costo_real'], legibles: ['id', 'nombre'] },
      pedidos: { columnas: ['id', 'cliente_id', 'total'], legibles: ['id', 'cliente_id', 'total'] },
      pedido_items: { columnas: ['id', 'pedido_id', 'producto_id'], legibles: ['id', 'pedido_id', 'producto_id'] },
      clientes: { columnas: ['id', 'nombre'], legibles: ['id', 'nombre'] },
      secreta: { columnas: ['id'], legibles: [] },
    },
    fks: [
      { nombre: 'pedidos_cliente_id_fkey', tabla: 'pedidos', columnas: ['cliente_id'], ref_tabla: 'clientes', ref_columnas: ['id'] },
      { nombre: 'pedido_items_producto_id_fkey', tabla: 'pedido_items', columnas: ['producto_id'], ref_tabla: 'productos', ref_columnas: ['id'] },
    ],
  }
  const errores = (src: string, ruta = 'src/a.ts') => verificarGrants(uno(src, ruta).consultas, mapa)

  it('productos(*) en un embed, select("*") y .select() pelado sobre productos fallan; las columnas concedidas no', () => {
    expect(errores(`supabase.from('pedido_items').select('id, producto:productos(*)')`)).toMatchObject([
      { tabla: 'productos', columna: '*', archivo: 'src/a.ts', linea: 1, motivo: expect.stringMatching(/costo_real/) },
    ])
    expect(errores(`supabase.from('productos').select('*')`)).toHaveLength(1)
    expect(errores(`supabase.from('productos').update({ nombre: 'x' }).eq('id', 1).select().single()`)).toHaveLength(1)
    expect(errores(`supabase.from('pedido_items').select('id, producto:productos(id, nombre)')`)).toEqual([])
  })

  it('una columna sin grant, una que no existe y un count sin nada legible', () => {
    expect(errores(`supabase.from('pedido_items').select('id, p:productos(costo_real)')`)).toMatchObject([
      { tabla: 'productos', columna: 'costo_real', motivo: 'authenticated no la puede leer' },
    ])
    expect(errores(`supabase.from('pedidos').select('id, nope')`)).toMatchObject([{ tabla: 'pedidos', columna: 'nope', motivo: 'no existe en la tabla' }])
    expect(errores(`supabase.from('secreta').select('count()')`)).toMatchObject([{ tabla: 'secreta', columna: 'count()' }])
    expect(errores(`supabase.from('pedidos').select('id, items:pedido_items(count)')`)).toEqual([])
  })

  it('el embed se resuelve por nombre de tabla, de FK o de columna FK; si no, falla', () => {
    expect(errores(`supabase.from('pedidos').select('id, c:pedidos_cliente_id_fkey(nombre)')`)).toEqual([])
    expect(errores(`supabase.from('pedidos').select('id, cliente_id(nombre)')`)).toEqual([])
    expect(errores(`supabase.from('pedidos').select('id, x:inventada(id)')`)).toMatchObject([{ motivo: expect.stringMatching(/no se puede resolver/) }])
  })

  it('las columnas de filtros y órdenes, de la raíz y de los embeds', () => {
    expect(errores(`supabase.from('productos').select('id').eq('costo_real', 1)`)).toMatchObject([{ tabla: 'productos', columna: 'costo_real' }])
    expect(errores(`supabase.from('pedido_items').select('id, p:productos!inner(id)').gte('p.costo_real', 1).order('id')`))
      .toMatchObject([{ tabla: 'productos', columna: 'costo_real', linea: 1 }])
  })

  it('las consultas de supabase/functions corren con service_role: no se les exige nada', () => {
    expect(errores(`sb.from('productos').select('*')`, 'supabase/functions/bot/index.ts')).toEqual([])
  })
})

describe('aplicarListaBlanca', () => {
  it('separa lo cubierto y avisa las entradas que ya no cubren nada', () => {
    const lista = [
      { archivo: 'src/a.ts', firma: 'from(tabla)', motivo: 'x' },
      { archivo: 'src/b.ts', firma: 'from(t)', motivo: 'y' },
    ]
    const r = aplicarListaBlanca([
      { archivo: 'src/a.ts', linea: 9, motivo: 'm', firma: 'from(tabla)' },
      { archivo: 'src/c.ts', linea: 1, motivo: 'm', firma: 'select(x)' },
    ], lista)
    expect(r.vigentes).toMatchObject([{ archivo: 'src/c.ts' }])
    expect(r.sinUso).toEqual([lista[1]])
  })
})
