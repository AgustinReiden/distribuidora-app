/**
 * Capa de datos de la pantalla de Salvedades (useSalvedadesQuery).
 *
 * #1008 — la pantalla no cargaba en prod (PGRST200). Las FKs de
 * `salvedades_items` hacia `productos` y `pedidos` son COMPUESTAS
 * (`(producto_id, sucursal_id)`, `(pedido_id, sucursal_id)`: el aislamiento por
 * sucursal), y PostgREST no encuentra una FK compuesta por el nombre de UNA
 * columna: `productos!producto_id` responde 400 PGRST200 y la consulta ENTERA
 * falla. El `select` es un string, así que ni `tsc` ni estos tests (que mockean
 * supabase) lo ven; por eso estos tests fijan el string y el gate
 * `scripts/check-embeds.mjs` lo prueba contra prod.
 *
 * `pedidos` además tiene DOS FKs desde `salvedades_items` (`pedido_id` y
 * `pedido_reprogramado_id`): sin hint es PGRST201, así que el hint se queda,
 * pero con el NOMBRE DEL CONSTRAINT.
 *
 * Paginación y filtros server-side: la página pide `range` + `count: 'exact'`,
 * y página y KPIs llevan los mismos filtros (estado, motivo, fecha en día
 * argentino, transportista del pedido).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createElement, type ReactNode } from 'react'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type Llamada = [string, ...unknown[]]
interface Consulta {
  tabla: string
  select: string
  opciones: unknown
  llamadas: Llamada[]
}

const consultas: Consulta[] = []
// Lo que devuelven las consultas (por defecto, vacío).
const respuestas: {
  salvedades: unknown[]
  count: number | null
  errorLista: { code?: string; message: string } | null
  perfiles: { data: unknown[] | null; error: unknown }
  perfilesIds: string[][]
} = { salvedades: [], count: 0, errorLista: null, perfiles: { data: [], error: null }, perfilesIds: [] }

vi.mock('../supabase/base', () => {
  const builder = (c: Consulta) => {
    const b: Record<string, unknown> = {}
    for (const m of ['eq', 'gte', 'lte', 'order']) {
      b[m] = (...args: unknown[]) => {
        c.llamadas.push([m, ...args])
        return b
      }
    }
    b.range = (desde: number, hasta: number) => {
      c.llamadas.push(['range', desde, hasta])
      if (respuestas.errorLista && desde > 0) {
        return Promise.resolve({ data: null, error: respuestas.errorLista, count: null })
      }
      return Promise.resolve({
        data: desde === 0 || c.opciones ? respuestas.salvedades : [],
        error: null,
        count: respuestas.count,
      })
    }
    return b
  }
  return {
    supabase: {
      from: (tabla: string) => ({
        select: (s: string, opciones?: unknown) => {
          const c: Consulta = { tabla, select: s, opciones, llamadas: [] }
          consultas.push(c)
          if (tabla === 'perfiles') {
            return {
              in: (_col: string, ids: string[]) => {
                respuestas.perfilesIds.push(ids)
                return Promise.resolve(respuestas.perfiles)
              },
            }
          }
          return builder(c)
        },
      }),
    },
    notifyError: vi.fn(),
  }
})

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import {
  fetchSalvedadesPagina,
  fetchEstadisticasSalvedades,
  salvedadesKeys,
  useSalvedadesQuery,
  useEstadisticasSalvedadesQuery,
  SALVEDADES_PAGE_SIZE,
  type SalvedadesFiltros,
} from './useSalvedadesQuery'
import { notifyError } from '../supabase/base'

const FILTROS: SalvedadesFiltros = {
  estado: 'todas',
  motivo: 'todos',
  desde: '2026-10-01',
  hasta: '2026-10-07',
  transportistaId: null,
}

function reiniciar() {
  consultas.length = 0
  respuestas.salvedades = []
  respuestas.count = 0
  respuestas.errorLista = null
  respuestas.perfiles = { data: [], error: null }
  respuestas.perfilesIds = []
  vi.mocked(notifyError).mockClear()
}

const sinEspacios = (s: string) => s.replace(/\s+/g, '')
const filtrosDe = (c: Consulta) => c.llamadas.filter(([m]) => m === 'eq' || m === 'gte' || m === 'lte')

async function selectDeFetch(f: SalvedadesFiltros = FILTROS): Promise<string> {
  await fetchSalvedadesPagina(f, 1)
  const deSalvedades = consultas.filter(c => c.tabla === 'salvedades_items')
  expect(deSalvedades).toHaveLength(1)
  return sinEspacios(deSalvedades[0].select)
}

describe('useSalvedadesQuery — select de salvedades_items', () => {
  beforeEach(reiniciar)

  it('embebe productos y pedidos por el NOMBRE DEL CONSTRAINT (FKs compuestas)', async () => {
    const select = await selectDeFetch()
    expect(select).toContain('productos!salvedades_items_producto_id_fkey(')
    expect(select).toContain('pedidos!salvedades_items_pedido_id_fkey(')
  })

  it('no usa hints por nombre de columna sobre FKs compuestas', async () => {
    const select = await selectDeFetch()
    expect(select).not.toMatch(/productos!producto_id/)
    expect(select).not.toMatch(/pedidos!pedido_id/)
    expect(select).not.toMatch(/clientes!cliente_id/)
  })

  it('sigue pidiendo los campos que arma transformarSalvedad', async () => {
    const select = await selectDeFetch()
    for (const campo of ['nombre_fantasia', 'transportista_id', 'estado', 'total', 'codigo']) {
      expect(select).toContain(campo)
    }
    expect(select).toContain('perfiles!reportado_por(')
    expect(select).toContain('perfiles!resuelto_por(')
  })

  it('con filtro de transportista, el pedido va !inner (y con el mismo hint por constraint)', async () => {
    const select = await selectDeFetch({ ...FILTROS, transportistaId: 'uuid-t1' })
    expect(select).toContain('pedido:pedidos!salvedades_items_pedido_id_fkey!inner(')
    expect(select).not.toMatch(/pedidos!pedido_id/)
  })

  it('sin filtro de transportista, el pedido NO va !inner (no descarta salvedades)', async () => {
    const select = await selectDeFetch()
    expect(select).not.toContain('!inner')
  })
})

describe('useSalvedadesQuery — página server-side', () => {
  beforeEach(reiniciar)

  it(`pide range de ${SALVEDADES_PAGE_SIZE} con count exact, del más nuevo al más viejo`, async () => {
    respuestas.count = 57
    const r = await fetchSalvedadesPagina(FILTROS, 3)

    const c = consultas[0]
    expect(c.opciones).toEqual({ count: 'exact' })
    expect(c.llamadas.filter(([m]) => m === 'range')).toEqual([['range', 40, 59]])
    expect(c.llamadas.filter(([m]) => m === 'order')).toEqual([
      ['order', 'created_at', { ascending: false }],
      ['order', 'id', { ascending: false }],
    ])
    expect(r.total).toBe(57)
  })

  it('"pendientes" filtra por estado y NO por fecha: una pendiente vieja no se esconde', async () => {
    await fetchSalvedadesPagina({ ...FILTROS, estado: 'pendientes' }, 1)
    expect(filtrosDe(consultas[0])).toEqual([['eq', 'estado_resolucion', 'pendiente']])
  })

  it('"todas" corta la fecha de created_at en día ARGENTINO, no UTC', async () => {
    await fetchSalvedadesPagina(FILTROS, 1)
    expect(filtrosDe(consultas[0])).toEqual([
      ['gte', 'created_at', '2026-10-01T00:00:00-03:00'],
      ['lte', 'created_at', '2026-10-07T23:59:59.999999-03:00'],
    ])
  })

  it('motivo y transportista del pedido van al servidor', async () => {
    await fetchSalvedadesPagina({ ...FILTROS, motivo: 'faltante_stock', transportistaId: 'uuid-t1' }, 1)
    const f = filtrosDe(consultas[0])
    expect(f).toContainEqual(['eq', 'motivo', 'faltante_stock'])
    expect(f).toContainEqual(['eq', 'pedido.transportista_id', 'uuid-t1'])
  })

  it('una página que dejó de existir (PGRST103) vuelve vacía con el total, no como error', async () => {
    respuestas.errorLista = { code: 'PGRST103', message: 'Requested range not satisfiable' }
    respuestas.count = 20
    const r = await fetchSalvedadesPagina(FILTROS, 2)
    expect(r).toEqual({ salvedades: [], total: 20 })
  })

  it('cualquier otro error de la lista se lanza', async () => {
    respuestas.errorLista = { code: 'PGRST100', message: 'boom' }
    await expect(fetchSalvedadesPagina(FILTROS, 2)).rejects.toThrow()
  })
})

describe('useSalvedadesQuery — KPIs con los mismos filtros que la lista', () => {
  beforeEach(reiniciar)

  it('trae sólo estado y monto, sin range de página ni count, con los mismos filtros', async () => {
    const f: SalvedadesFiltros = { ...FILTROS, motivo: 'cliente_rechaza', transportistaId: 'uuid-t1' }
    await fetchSalvedadesPagina(f, 2)
    await fetchEstadisticasSalvedades(f)
    const [lista, kpi] = consultas.filter(c => c.tabla === 'salvedades_items')

    expect(sinEspacios(kpi.select)).toBe(
      'estado_resolucion,monto_afectado,pedido:pedidos!salvedades_items_pedido_id_fkey!inner(transportista_id)',
    )
    expect(kpi.opciones).toBeUndefined()
    expect(filtrosDe(kpi)).toEqual(filtrosDe(lista))
    // De a 1.000 (traerTodo), desde el principio: no la página que se mira.
    expect(kpi.llamadas.find(([m]) => m === 'range')).toEqual(['range', 0, 999])
  })

  it('sin transportista, el select de KPIs no embebe el pedido', async () => {
    await fetchEstadisticasSalvedades(FILTROS)
    expect(sinEspacios(consultas[0].select)).toBe('estado_resolucion,monto_afectado')
  })

  it('cuenta pendientes, resueltas y anuladas y suma montos de TODA la lista filtrada', async () => {
    respuestas.salvedades = [
      { estado_resolucion: 'pendiente', monto_afectado: 100 },
      { estado_resolucion: 'pendiente', monto_afectado: 50 },
      { estado_resolucion: 'nota_credito', monto_afectado: 30 },
      { estado_resolucion: 'anulada', monto_afectado: 7 },
    ]
    const e = await fetchEstadisticasSalvedades(FILTROS)
    expect(e).toEqual({
      total: 4,
      pendientes: 2,
      resueltas: 1,
      anuladas: 1,
      monto_total_afectado: 187,
      monto_pendiente: 150,
    })
  })
})

describe('salvedadesKeys', () => {
  it('la key de la lista lleva sucursal, filtros y página; la de KPIs no lleva página', () => {
    expect(salvedadesKeys.lista(2, FILTROS, 3)).toEqual(['salvedades', 2, 'lista', FILTROS, 3])
    expect(salvedadesKeys.estadisticas(2, FILTROS)).toEqual(['salvedades', 2, 'estadisticas', FILTROS])
    // Las dos cuelgan de `all`: invalidar `all` (resolver/anular) las alcanza.
    expect(salvedadesKeys.lista(2, FILTROS, 1).slice(0, 1)).toEqual([...salvedadesKeys.all])
    expect(salvedadesKeys.estadisticas(1, FILTROS).slice(0, 1)).toEqual([...salvedadesKeys.all])
  })
})

/**
 * #1072 — el transportista salía siempre '-': `transformarSalvedad` armaba el
 * id pero nunca el nombre. `pedidos` no tiene FK a `perfiles` (un embed sería
 * PGRST200), así que el nombre sale de una segunda consulta plana a perfiles.
 */
describe('useSalvedadesQuery — nombre del transportista (#1072)', () => {
  beforeEach(reiniciar)

  const salvedad = (id: number, transportista_id: string | null) => ({
    id,
    pedido: { id: 100 + id, total: 1000, estado: 'entregado', transportista_id, cliente: { id: 1, nombre_fantasia: 'Kiosco' } },
  })

  async function cargar() {
    return (await fetchSalvedadesPagina(FILTROS, 1)).salvedades
  }

  it('arma transportista_nombre con los perfiles de los transportistas distintos', async () => {
    respuestas.salvedades = [salvedad(1, 'uuid-t1'), salvedad(2, 'uuid-t1'), salvedad(3, 'uuid-t2')]
    respuestas.perfiles = { data: [{ id: 'uuid-t1', nombre: 'Juan' }, { id: 'uuid-t2', nombre: 'Pedro' }], error: null }

    const lista = await cargar()

    expect(respuestas.perfilesIds).toEqual([['uuid-t1', 'uuid-t2']])
    expect(sinEspacios(consultas[1].select)).toBe('id,nombre')
    expect(lista.map(s => s.transportista_nombre)).toEqual(['Juan', 'Juan', 'Pedro'])
    expect(notifyError).not.toHaveBeenCalled()
  })

  it('sin transportistas no hace la segunda consulta', async () => {
    respuestas.salvedades = [salvedad(1, null)]

    const lista = await cargar()

    expect(consultas).toHaveLength(1)
    expect(respuestas.perfilesIds).toEqual([])
    expect(lista[0].transportista_nombre).toBeUndefined()
  })

  it('si falla perfiles, la lista carga igual, sin nombre, y avisa con mensaje normalizado', async () => {
    respuestas.salvedades = [salvedad(1, 'uuid-t1'), salvedad(2, null)]
    respuestas.perfiles = {
      data: null,
      error: { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' },
    }

    const lista = await cargar()

    expect(lista).toHaveLength(2)
    expect(lista[0].transportista_nombre).toBeUndefined()
    expect(notifyError).toHaveBeenCalledTimes(1)
    const aviso = vi.mocked(notifyError).mock.calls[0][0] as string
    expect(aviso).not.toMatch(/Failed to fetch/)
    expect(aviso).toMatch(/Sin conexión/)
  })
})

/**
 * La vista vieja recargaba TODO cada vez que se abría. Con cache, una salvedad
 * registrada desde Pedidos (que no invalida `salvedades`) no aparecía al volver
 * si la cache tenía menos de `staleTime`. Volver a la pantalla tiene que
 * consultar de nuevo aunque haya datos en cache.
 */
describe('useSalvedadesQuery — volver a la pantalla vuelve a consultar', () => {
  beforeEach(reiniciar)

  function montarCon(qc: QueryClient, usar: () => unknown) {
    const wrapper = ({ children }: { children: ReactNode }) => createElement(QueryClientProvider, { client: qc }, children)
    return renderHook(usar, { wrapper })
  }

  it('la lista: con una página recién cacheada, montar consulta igual', async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    qc.setQueryData(salvedadesKeys.lista(2, FILTROS, 1), { salvedades: [], total: 0 })

    montarCon(qc, () => useSalvedadesQuery(FILTROS, 1))

    await waitFor(() => expect(consultas.filter(c => c.tabla === 'salvedades_items')).toHaveLength(1))
  })

  it('los KPIs: con datos recién cacheados, montar consulta igual', async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    qc.setQueryData(salvedadesKeys.estadisticas(2, FILTROS), {
      total: 0, pendientes: 0, resueltas: 0, anuladas: 0, monto_total_afectado: 0, monto_pendiente: 0,
    })

    montarCon(qc, () => useEstadisticasSalvedadesQuery(FILTROS))

    await waitFor(() => expect(consultas.filter(c => c.tabla === 'salvedades_items')).toHaveLength(1))
  })
})
