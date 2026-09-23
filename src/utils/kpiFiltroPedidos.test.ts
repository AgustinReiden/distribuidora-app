/**
 * Los KPIs de /pedidos como filtros (#715). Lo que se protege acá:
 *  - cada tile aplica el valor que su bucket del summary cuenta (enCamino es
 *    'asignado', no 'en_camino'; impagos es el sentinela 'impago');
 *  - el tile de estado y el de impagos son dimensiones independientes;
 *  - el summary se calcula sin estado ni pago, o los otros tiles caen a 0.
 */
import { describe, it, expect } from 'vitest'
import {
  ESTADO_PAGO_IMPAGO,
  filtroDeKpi,
  hayFiltroQueLimpiar,
  filtrosParaStats,
  kpiActivo,
  kpiEstaActivo,
  togglearKpi,
  type FiltrosKpi,
} from './kpiFiltroPedidos'
import type { FiltrosPedidosState } from '../types'

const SIN_FILTRO: FiltrosKpi = { estado: 'todos', estadoPago: 'todos' }

function filtrosCompletos(overrides: Partial<FiltrosPedidosState> = {}): FiltrosPedidosState {
  return {
    fechaDesde: '2026-08-23',
    fechaHasta: null,
    estado: 'todos',
    estadoPago: 'todos',
    transportistaId: 'todos',
    usuarioId: 'user-3',
    busqueda: '',
    conSalvedad: 'todos',
    ...overrides,
  }
}

describe('filtroDeKpi', () => {
  it('cada tile de estado aplica el estado que cuenta su bucket', () => {
    expect(filtroDeKpi('pendientes')).toEqual({ estado: 'pendiente' })
    expect(filtroDeKpi('enPreparacion')).toEqual({ estado: 'en_preparacion' })
    expect(filtroDeKpi('entregados')).toEqual({ estado: 'entregado' })
  })

  it('"En camino" filtra por estado asignado, no por en_camino', () => {
    // El summary suma en `enCamino` los pedidos con estado 'asignado': filtrar
    // por 'en_camino' daría una lista vacía al lado de un tile con N.
    expect(filtroDeKpi('enCamino')).toEqual({ estado: 'asignado' })
  })

  it('"Impagos" aplica el sentinela de pago, sin tocar el estado', () => {
    expect(ESTADO_PAGO_IMPAGO).toBe('impago')
    expect(filtroDeKpi('impagos')).toEqual({ estadoPago: 'impago' })
  })

  it('"Total" limpia estado y pago', () => {
    expect(filtroDeKpi('total')).toEqual({ estado: 'todos', estadoPago: 'todos' })
  })
})

describe('kpiActivo', () => {
  it('sin filtro de estado ni de pago no hay tile activo ("Total" nunca lo está)', () => {
    expect(kpiActivo(SIN_FILTRO)).toBeNull()
  })

  it('reconoce cada tile de estado, incluido asignado → enCamino', () => {
    expect(kpiActivo({ ...SIN_FILTRO, estado: 'pendiente' })).toBe('pendientes')
    expect(kpiActivo({ ...SIN_FILTRO, estado: 'en_preparacion' })).toBe('enPreparacion')
    expect(kpiActivo({ ...SIN_FILTRO, estado: 'asignado' })).toBe('enCamino')
    expect(kpiActivo({ ...SIN_FILTRO, estado: 'entregado' })).toBe('entregados')
  })

  it('reconoce el sentinela impago → impagos', () => {
    expect(kpiActivo({ ...SIN_FILTRO, estadoPago: 'impago' })).toBe('impagos')
  })

  it('con estado y impago a la vez gana el de estado', () => {
    expect(kpiActivo({ estado: 'pendiente', estadoPago: 'impago' })).toBe('pendientes')
  })

  it('un estado o un pago que ningún tile representa no activa nada', () => {
    // 'cancelado' sale del select de estado; 'pagado' y 'parcial', del de pago.
    expect(kpiActivo({ ...SIN_FILTRO, estado: 'cancelado' })).toBeNull()
    expect(kpiActivo({ ...SIN_FILTRO, estadoPago: 'pagado' })).toBeNull()
    expect(kpiActivo({ ...SIN_FILTRO, estadoPago: 'parcial' })).toBeNull()
  })

  it('un filtro de pago del select no tapa al tile de estado', () => {
    expect(kpiActivo({ estado: 'entregado', estadoPago: 'pagado' })).toBe('entregados')
  })
})

describe('kpiEstaActivo', () => {
  it('estado e impagos se miran por separado: pueden estar los dos activos', () => {
    const filtros: FiltrosKpi = { estado: 'asignado', estadoPago: 'impago' }

    expect(kpiEstaActivo('enCamino', filtros)).toBe(true)
    expect(kpiEstaActivo('impagos', filtros)).toBe(true)
    expect(kpiEstaActivo('pendientes', filtros)).toBe(false)
    expect(kpiEstaActivo('total', filtros)).toBe(false)
  })

  it('"Total" no está activo ni siquiera sin filtros', () => {
    expect(kpiEstaActivo('total', SIN_FILTRO)).toBe(false)
  })
})

describe('togglearKpi', () => {
  it('un tile inactivo se aplica', () => {
    expect(togglearKpi('pendientes', SIN_FILTRO)).toEqual({ estado: 'pendiente' })
    expect(togglearKpi('enCamino', SIN_FILTRO)).toEqual({ estado: 'asignado' })
    expect(togglearKpi('impagos', SIN_FILTRO)).toEqual({ estadoPago: 'impago' })
  })

  it('tocar el tile de estado activo lo deselecciona', () => {
    expect(togglearKpi('pendientes', { ...SIN_FILTRO, estado: 'pendiente' })).toEqual({ estado: 'todos' })
    expect(togglearKpi('enCamino', { ...SIN_FILTRO, estado: 'asignado' })).toEqual({ estado: 'todos' })
  })

  it('tocar "Impagos" activo lo deselecciona', () => {
    expect(togglearKpi('impagos', { ...SIN_FILTRO, estadoPago: 'impago' })).toEqual({ estadoPago: 'todos' })
  })

  it('un tile de estado no toca el pago, ni al aplicarse ni al deseleccionarse', () => {
    const conImpago: FiltrosKpi = { estado: 'todos', estadoPago: 'impago' }
    expect(togglearKpi('entregados', conImpago)).not.toHaveProperty('estadoPago')

    const ambos: FiltrosKpi = { estado: 'entregado', estadoPago: 'impago' }
    expect(togglearKpi('entregados', ambos)).toEqual({ estado: 'todos' })
  })

  it('"Impagos" no toca el estado, ni al aplicarse ni al deseleccionarse', () => {
    const conEstado: FiltrosKpi = { estado: 'pendiente', estadoPago: 'todos' }
    expect(togglearKpi('impagos', conEstado)).toEqual({ estadoPago: 'impago' })

    const ambos: FiltrosKpi = { estado: 'pendiente', estadoPago: 'impago' }
    expect(togglearKpi('impagos', ambos)).toEqual({ estadoPago: 'todos' })
  })

  it('cambiar de un tile de estado a otro reemplaza el estado', () => {
    expect(togglearKpi('entregados', { ...SIN_FILTRO, estado: 'pendiente' })).toEqual({ estado: 'entregado' })
  })

  it('"Impagos" reemplaza un pago elegido en el select', () => {
    expect(togglearKpi('impagos', { ...SIN_FILTRO, estadoPago: 'pagado' })).toEqual({ estadoPago: 'impago' })
  })

  it('"Total" limpia las dos dimensiones, haya lo que haya', () => {
    expect(togglearKpi('total', SIN_FILTRO)).toEqual({ estado: 'todos', estadoPago: 'todos' })
    expect(togglearKpi('total', { estado: 'asignado', estadoPago: 'impago' })).toEqual({ estado: 'todos', estadoPago: 'todos' })
    expect(togglearKpi('total', { estado: 'pendiente', estadoPago: 'pagado', verCancelados: false })).toEqual({ estado: 'todos', estadoPago: 'todos' })
  })

  it('"Total" con estado cancelado además prende verCancelados', () => {
    // El tile Total, con estado 'cancelado', cuenta los cancelados
    // (filtrosParaStats). Si el clic sólo limpiara el estado, la lista volvería
    // a excluirlos y mostraría menos filas que el número que se tocó.
    expect(togglearKpi('total', { estado: 'cancelado', estadoPago: 'pagado' }))
      .toEqual({ estado: 'todos', estadoPago: 'todos', verCancelados: true })
    expect(togglearKpi('total', { estado: 'cancelado', estadoPago: 'todos', verCancelados: false }))
      .toEqual({ estado: 'todos', estadoPago: 'todos', verCancelados: true })
  })
})

describe('hayFiltroQueLimpiar', () => {
  // "Total" es el botón de limpiar: sin estado ni pago elegidos no tiene nada
  // que hacer, y el componente no manda un cambio que sólo resetearía la página.
  it('sin estado ni pago no hay nada que limpiar', () => {
    expect(hayFiltroQueLimpiar(SIN_FILTRO)).toBe(false)
  })

  it('verCancelados solo no cuenta: "Total" no lo toca si no hay estado cancelado', () => {
    expect(hayFiltroQueLimpiar({ ...SIN_FILTRO, verCancelados: true })).toBe(false)
  })

  it('un estado, un pago o los dos sí son algo que limpiar', () => {
    expect(hayFiltroQueLimpiar({ ...SIN_FILTRO, estado: 'pendiente' })).toBe(true)
    expect(hayFiltroQueLimpiar({ ...SIN_FILTRO, estado: 'cancelado' })).toBe(true)
    expect(hayFiltroQueLimpiar({ ...SIN_FILTRO, estadoPago: 'impago' })).toBe(true)
    expect(hayFiltroQueLimpiar({ ...SIN_FILTRO, estadoPago: 'pagado' })).toBe(true)
    expect(hayFiltroQueLimpiar({ estado: 'asignado', estadoPago: 'impago' })).toBe(true)
  })
})

describe('"Total": la lista que deja el clic es la que el tile contaba', () => {
  // El invariante de la aceptación de #715 para el tile que limpia: aplicar lo
  // que devuelve togglearKpi('total') sobre los filtros da exactamente los
  // filtros con los que se calculó el número de ese tile.
  const casos: Array<[string, Partial<FiltrosPedidosState>]> = [
    ['sin filtros', {}],
    ['con un tile de estado', { estado: 'pendiente' }],
    ['con estado e impagos', { estado: 'asignado', estadoPago: 'impago' }],
    ['con un pago del select', { estadoPago: 'parcial' }],
    ['con estado cancelado', { estado: 'cancelado' }],
    ['con estado cancelado y verCancelados apagado', { estado: 'cancelado', verCancelados: false }],
    ['con verCancelados prendido', { estado: 'entregado', verCancelados: true }],
  ]

  it.each(casos)('%s', (_nombre, overrides) => {
    const filtros = filtrosCompletos(overrides)
    const despuesDelClic = { ...filtros, ...togglearKpi('total', filtros) }

    expect(despuesDelClic).toEqual(filtrosParaStats(filtros))
  })
})

describe('filtrosParaStats', () => {
  it('saca estado y pago: el summary cuenta los seis tiles, no sólo el elegido', () => {
    const stats = filtrosParaStats(filtrosCompletos({ estado: 'pendiente', estadoPago: 'impago' }))

    expect(stats.estado).toBe('todos')
    expect(stats.estadoPago).toBe('todos')
  })

  it('conserva el resto de los filtros tal cual', () => {
    const filtros = filtrosCompletos({
      estado: 'asignado',
      transportistaId: 't-1',
      conSalvedad: 'con_salvedad',
      fechaEntregaProgramada: '2026-09-22',
    })

    expect(filtrosParaStats(filtros)).toEqual({
      ...filtros,
      estado: 'todos',
      estadoPago: 'todos',
      verCancelados: undefined,
    })
  })

  it('con estado cancelado prende verCancelados, como hace la lista', () => {
    // La lista con estado='cancelado' no excluye cancelados; el summary, sin el
    // estado, los excluiría si no se le prende verCancelados.
    expect(filtrosParaStats(filtrosCompletos({ estado: 'cancelado' })).verCancelados).toBe(true)
    expect(filtrosParaStats(filtrosCompletos({ estado: 'cancelado', verCancelados: false })).verCancelados).toBe(true)
  })

  it('sin estado cancelado respeta el verCancelados que haya', () => {
    expect(filtrosParaStats(filtrosCompletos({ verCancelados: true })).verCancelados).toBe(true)
    expect(filtrosParaStats(filtrosCompletos({ verCancelados: false })).verCancelados).toBe(false)
    expect(filtrosParaStats(filtrosCompletos({ estado: 'pendiente' })).verCancelados).toBeUndefined()
  })

  it('no muta los filtros que recibe', () => {
    const filtros = filtrosCompletos({ estado: 'cancelado', estadoPago: 'impago' })
    const copia = { ...filtros }
    filtrosParaStats(filtros)

    expect(filtros).toEqual(copia)
  })
})
