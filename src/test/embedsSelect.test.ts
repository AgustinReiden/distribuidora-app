import { describe, expect, it } from 'vitest'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { constantesDe, extraerSelects } from '../../scripts/lib/embedsSelect.mjs'

/**
 * El extractor del gate `scripts/check-embeds.mjs` (#1008) lee texto, no AST.
 * Estos casos fijan los tres modos en que el repo escribe un select y lo que
 * tiene que dejar afuera, porque un extractor que se pierde selects da un gate
 * verde que no mira nada.
 */

type Hallazgo = { tabla: string; select: string; linea: number }
const extraer = (src: string): { encontrados: Hallazgo[]; omitidos: { motivo: string }[] } =>
  extraerSelects(src, constantesDe(src))

describe('extraerSelects', () => {
  it('literal con comillas simples y la tabla del .from()', () => {
    const { encontrados } = extraer(`supabase.from('pedidos').select('id, cliente:clientes!inner(id)')`)
    expect(encontrados).toEqual([{ tabla: 'pedidos', select: 'id,cliente:clientes!inner(id)', linea: 1 }])
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
    const { encontrados } = extraer(src)
    expect(encontrados).toHaveLength(1)
    expect(encontrados[0].select).toBe('*,producto:productos!salvedades_items_producto_id_fkey(id,nombre)')
    expect(encontrados[0].tabla).toBe('salvedades_items')
  })

  it('resuelve ${CONSTANTE} de la misma fuente', () => {
    const src = [
      `const COLS = 'id, nombre' as const`,
      `const q = supabase.from('pedidos').select(\`*, cliente:clientes(\${COLS})\`)`,
    ].join('\n')
    expect(extraer(src).encontrados[0].select).toBe('*,cliente:clientes(id,nombre)')
  })

  it('select(CONSTANTE) y select(local) con las dos ramas de un ternario', () => {
    const src = [
      `const A = 'id, c:clientes!inner(id)'`,
      `const B = 'id, c:clientes(id)'`,
      `function f(buscar: boolean) {`,
      `  const selectStr = buscar ? A : B`,
      `  return supabase.from('pedidos').select(selectStr)`,
      `}`,
    ].join('\n')
    expect(extraer(src).encontrados.map((e) => e.select)).toEqual(['id,c:clientes!inner(id)', 'id,c:clientes(id)'])
  })

  it('un ${...} que no se puede resolver no tumba el select: va como columna cualquiera', () => {
    const src = `supabase.from('pedidos').select(\`*, c:clientes(\${armar()})\`)`
    expect(extraer(src).encontrados[0].select).toBe('*,c:clientes(id)')
  })

  it('ignora lo que no tiene embed: *, columnas sueltas y .select() pelado', () => {
    const src = [
      `supabase.from('a').select('*')`,
      `supabase.from('b').select('id, nombre')`,
      `supabase.from('c').insert([{}]).select().single()`,
    ].join('\n')
    expect(extraer(src).encontrados).toEqual([])
  })

  it('un select con embed sin .from() literal se informa, no se pierde en silencio', () => {
    const { encontrados, omitidos } = extraer(`const r = await tabla.select('id, c:clientes(id)')`)
    expect(encontrados).toEqual([])
    expect(omitidos).toHaveLength(1)
  })

  it('edge functions: comillas dobles', () => {
    const { encontrados } = extraer(`await sb.from("bot_usuarios").select("id, perfiles!inner(rol)")`)
    expect(encontrados[0]).toMatchObject({ tabla: 'bot_usuarios', select: 'id,perfiles!inner(rol)' })
  })
})
