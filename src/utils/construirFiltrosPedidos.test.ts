/**
 * `construirFiltrosPedidos` es el armado ÚNICO que tienen que compartir la
 * lista paginada, las cards de stats y el export "todo lo filtrado" (#524).
 * Antes cada consulta rearmaba los filtros a mano y se desincronizaban: el
 * export omitía `usuarioId` y `fechaEntregaProgramada`, y los tres caminos de
 * búsqueda interpolaban el término crudo, así que una coma o un paréntesis
 * tiraban un 400 (PGRST100) y dejaban la lista entera en error.
 */
import { describe, it, expect } from 'vitest'
import { construirFiltrosPedidos, aplicarFiltroConSalvedad } from './construirFiltrosPedidos'
import type { FiltrosPedidosState } from '../types'

interface Llamada { metodo: string; args: unknown[] }

function crearQueryFalsa() {
  const llamadas: Llamada[] = []
  const builder = {
    eq: (...args: unknown[]) => { llamadas.push({ metodo: 'eq', args }); return builder },
    gte: (...args: unknown[]) => { llamadas.push({ metodo: 'gte', args }); return builder },
    lte: (...args: unknown[]) => { llamadas.push({ metodo: 'lte', args }); return builder },
    or: (...args: unknown[]) => { llamadas.push({ metodo: 'or', args }); return builder },
    in: (...args: unknown[]) => { llamadas.push({ metodo: 'in', args }); return builder },
    not: (...args: unknown[]) => { llamadas.push({ metodo: 'not', args }); return builder },
  }
  return { builder, llamadas }
}

describe('construirFiltrosPedidos', () => {
  it('filtra por vendedor (usuarioId) — el export lo omitía', () => {
    const { builder, llamadas } = crearQueryFalsa()
    construirFiltrosPedidos(builder, { usuarioId: 'user-1' })

    expect(llamadas).toContainEqual({ metodo: 'eq', args: ['usuario_id', 'user-1'] })
  })

  it('"todos" en usuarioId no agrega filtro', () => {
    const { builder, llamadas } = crearQueryFalsa()
    construirFiltrosPedidos(builder, { usuarioId: 'todos' })

    expect(llamadas.some(l => l.metodo === 'eq' && l.args[0] === 'usuario_id')).toBe(false)
  })

  it('filtra por fecha de entrega programada — el export también lo omitía', () => {
    const { builder, llamadas } = crearQueryFalsa()
    construirFiltrosPedidos(builder, { fechaEntregaProgramada: '2026-09-15' })

    expect(llamadas).toContainEqual({ metodo: 'eq', args: ['fecha_entrega_programada', '2026-09-15'] })
  })

  it('sin verCancelados y con estado NULL: excluye cancelado/anulado pero incluye NULL', () => {
    // Éste es el `.or()` que el export reemplazaba por `.neq('estado','cancelado')`,
    // que sí excluye 'cancelado' pero también descarta las filas con estado NULL.
    const { builder, llamadas } = crearQueryFalsa()
    construirFiltrosPedidos(builder, {})

    expect(llamadas).toContainEqual({
      metodo: 'or',
      args: ['estado.is.null,and(estado.neq.cancelado,estado.neq.anulado)'],
    })
    expect(llamadas.some(l => l.metodo === 'neq')).toBe(false)
  })

  it('verCancelados=true no agrega la exclusión', () => {
    const { builder, llamadas } = crearQueryFalsa()
    construirFiltrosPedidos(builder, { verCancelados: true })

    expect(llamadas.some(l => l.args[0] === 'estado.is.null,and(estado.neq.cancelado,estado.neq.anulado)')).toBe(false)
  })

  it('estado=cancelado no agrega la exclusión (se está pidiendo justamente eso)', () => {
    const { builder, llamadas } = crearQueryFalsa()
    construirFiltrosPedidos(builder, { estado: 'cancelado' })

    expect(llamadas.some(l => l.args[0] === 'estado.is.null,and(estado.neq.cancelado,estado.neq.anulado)')).toBe(false)
    expect(llamadas).toContainEqual({ metodo: 'eq', args: ['estado', 'cancelado'] })
  })

  it('un término con coma y paréntesis no rompe el filtro (antes tiraba 400 PGRST100)', () => {
    const { builder, llamadas } = crearQueryFalsa()
    construirFiltrosPedidos(builder, {}, 'Perez, Juan (Kiosco)')

    const orBusqueda = llamadas.find(l => l.metodo === 'or' && (l.args[1] as { referencedTable?: string } | undefined)?.referencedTable === 'clientes')
    expect(orBusqueda).toBeDefined()
    const filtro = orBusqueda!.args[0] as string
    // La coma y los paréntesis de sintaxis PostgREST no pueden sobrevivir: si
    // quedaran, `,` cortaría la cláusula del `.or()` a la mitad y `()` abriría
    // un grupo que nunca cierra.
    expect(filtro).not.toMatch(/,\s*Juan/)
    expect(filtro).toContain('%Perez Juan Kiosco%')
  })

  it('búsqueda vacía o solo-sintaxis no agrega el or de clientes', () => {
    const { builder, llamadas } = crearQueryFalsa()
    construirFiltrosPedidos(builder, {}, '   ')
    construirFiltrosPedidos(builder, {}, '(),.') // todo caracteres de sintaxis

    const orsDeClientes = llamadas.filter(l => (l.args[1] as { referencedTable?: string } | undefined)?.referencedTable === 'clientes')
    expect(orsDeClientes).toHaveLength(0)
  })

  it('los tres armados posibles (paginada / stats / export) dan la MISMA secuencia de filtros', () => {
    const filtros: Partial<FiltrosPedidosState> = {
      estado: 'todos',
      usuarioId: 'user-9',
      fechaEntregaProgramada: '2026-09-15',
      fechaDesde: '2026-09-01',
    }
    const busqueda = 'Perez, Juan (Kiosco)'

    const paginada = crearQueryFalsa()
    const stats = crearQueryFalsa()
    const exportAll = crearQueryFalsa()

    construirFiltrosPedidos(paginada.builder, filtros, busqueda)
    construirFiltrosPedidos(stats.builder, filtros, busqueda)
    construirFiltrosPedidos(exportAll.builder, filtros, busqueda)

    expect(stats.llamadas).toEqual(paginada.llamadas)
    expect(exportAll.llamadas).toEqual(paginada.llamadas)
  })
})

describe('aplicarFiltroConSalvedad', () => {
  it('"todos" no toca la query', () => {
    const { builder, llamadas } = crearQueryFalsa()
    aplicarFiltroConSalvedad(builder, 'todos', [1, 2, 3])
    expect(llamadas).toHaveLength(0)
  })

  it('con_salvedad filtra por los ids conocidos', () => {
    const { builder, llamadas } = crearQueryFalsa()
    aplicarFiltroConSalvedad(builder, 'con_salvedad', [10, 20])
    expect(llamadas).toContainEqual({ metodo: 'in', args: ['id', [10, 20]] })
  })

  it('con_salvedad sin ninguna fila conocida no trae nada (sentinela -1, no in.() inválido)', () => {
    const { builder, llamadas } = crearQueryFalsa()
    aplicarFiltroConSalvedad(builder, 'con_salvedad', [])
    expect(llamadas).toContainEqual({ metodo: 'in', args: ['id', [-1]] })
  })

  it('sin_salvedad excluye los ids conocidos', () => {
    const { builder, llamadas } = crearQueryFalsa()
    aplicarFiltroConSalvedad(builder, 'sin_salvedad', [10, 20])
    expect(llamadas).toContainEqual({ metodo: 'not', args: ['id', 'in', '(10,20)'] })
  })

  it('sin_salvedad sin ninguna fila conocida no excluye nada', () => {
    const { builder, llamadas } = crearQueryFalsa()
    aplicarFiltroConSalvedad(builder, 'sin_salvedad', null)
    expect(llamadas).toContainEqual({ metodo: 'not', args: ['id', 'in', '(-1)'] })
  })
})
