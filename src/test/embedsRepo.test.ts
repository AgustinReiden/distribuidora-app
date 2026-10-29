import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { beforeAll, describe, expect, it } from 'vitest'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { analizarRepo } from '../../scripts/lib/embedsSelect.mjs'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { buscarRuta, esEmbebido, huerfanos, parsearSelect, pruebasDe } from '../../scripts/lib/embedsPostgrest.mjs'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { aplicarListaBlanca, leerFuentes } from '../../scripts/lib/embedsRepo.mjs'

/**
 * El extractor del gate de embeds corrido sobre los fuentes de VERDAD de `src/`
 * y `supabase/functions/`, sin red (#1256). `embedsSelect.test.ts` prueba el
 * extractor con casos armados; esto prueba que sobre el repo no se pierde
 * nada: el gate de CI sólo ve lo que el extractor encuentra, y un extractor
 * que deja de encontrar da un gate verde que no mira nada.
 *
 * Si un cambio legítimo baja los pisos, bajalos con el número nuevo; si sube
 * los omitidos, el gate de CI también va a fallar: arreglá la consulta (o, si
 * de verdad no se puede leer, sumala a LISTA_BLANCA con su motivo).
 */

type Filtro = { tipo: string; ruta: string[]; columnas: string[] | null; archivo: string; linea: number; firma: string; grupo: string }
type Consulta = { archivo: string; linea: number; tabla: string; variantes: string[]; filtros: Filtro[] }

// path y no `new URL('../..')`: en jsdom el URL global no es el de node.
const raiz = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
let consultas: Consulta[] = []
let omitidos: { archivo: string; linea: number; motivo: string }[] = []
let sinUso: unknown[] = []
let cantidadArchivos = 0

beforeAll(() => {
  const fuentes = leerFuentes(raiz)
  cantidadArchivos = fuentes.length
  const r = analizarRepo(fuentes)
  consultas = r.consultas
  ;({ vigentes: omitidos, sinUso } = aplicarListaBlanca(r.omitidos))
}, 60_000)

describe('gate de embeds sobre el repo', () => {
  it('lee los fuentes de src/ y supabase/functions/', () => {
    expect(cantidadArchivos).toBeGreaterThan(400)
    expect(consultas.some((c) => c.archivo.startsWith('supabase/functions/'))).toBe(true)
  })

  it('no deja nada sin atribuir ni resolver, y la lista blanca no tiene entradas muertas', () => {
    expect(omitidos.map((o) => `${o.archivo}:${o.linea} — ${o.motivo}`)).toEqual([])
    expect(sinUso).toEqual([])
  })

  it('encuentra al menos lo que había el día que se escribió (242 consultas, 60 con embed, 48 pruebas distintas)', () => {
    expect(consultas.length).toBeGreaterThanOrEqual(200)
    const conPrueba = consultas.filter((c) => pruebasDe(c).pruebas.length)
    expect(conPrueba.length).toBeGreaterThanOrEqual(50)
    const distintas = new Set(conPrueba.flatMap((c) => pruebasDe(c).pruebas.map((p: { select: string }) => `${c.tabla}|${p.select}`)))
    expect(distintas.size).toBeGreaterThanOrEqual(40)
  })

  it('todos los selects parsean', () => {
    const errores: string[] = []
    for (const c of consultas) {
      for (const v of c.variantes) {
        try {
          parsearSelect(v)
        } catch (e) {
          errores.push(`${c.archivo}:${c.linea} — ${(e as Error).message}`)
        }
      }
    }
    expect(errores).toEqual([])
  })

  it('cada filtro u orden sobre un embed tiene su alias o tabla en el select de su consulta', () => {
    const conFiltro = consultas.filter((c) => c.filtros.some(esEmbebido))
    // Hoy: compras (filtro + order=rel(col)), recorridos no entregados, promos, salvedades
    // (helper), usuarios, analytics, el .or() de clientes de construirFiltrosPedidos
    // (helper, tres consultas) y el digest del bot.
    expect(conFiltro.length).toBeGreaterThanOrEqual(15)
    const tiene = (c: Consulta, f: Filtro) => c.variantes.some((v) => buscarRuta(parsearSelect(v), f.ruta))
    const mismo = (f: Filtro, g: Filtro) => f.archivo === g.archivo && f.linea === g.linea && f.firma === g.firma && f.grupo === g.grupo
    const sinEmbed: string[] = []
    for (const c of conFiltro) {
      for (const f of c.filtros.filter(esEmbebido)) {
        // Si esta consulta no lo embebe, vale sólo si es la otra rama de un
        // ternario al que se le aplicó el mismo helper y esa rama sí lo tiene.
        const enSuGrupo = consultas.some((d) => d !== c && tiene(d, f) && d.filtros.some((g) => mismo(f, g)))
        if (!tiene(c, f) && !enSuGrupo) sinEmbed.push(`${f.firma} (${f.archivo}:${f.linea}) en ${c.archivo}:${c.linea}`)
      }
    }
    expect(sinEmbed).toEqual([])
    expect(huerfanos(consultas)).toEqual([])
  })

  it('los filtros de un helper de otro archivo llegan a las consultas a las que se aplica', () => {
    const deHelper = consultas.filter((c) => c.filtros.some((f) => esEmbebido(f) && f.archivo !== c.archivo))
    expect(deHelper.length).toBeGreaterThanOrEqual(3)
  })
})
