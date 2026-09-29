import { describe, it, expect } from 'vitest'
import {
  MENSAJE_RANGO_INVERTIDO,
  OPCIONES_ESTADO,
  OPCIONES_PAGO,
  OPCIONES_SALVEDAD,
  chipsFiltrosActivos,
  contarFiltrosActivos,
  describirFiltrosActivos,
  diaSiguienteISO,
  esFechaCompleta,
  payloadLimpiarTodo,
  puntaFechaEmitible,
  validarRangoFechas,
  type FiltrosPedidosUI,
} from './filtrosPedidos'

const HOY = '2026-04-15'

const BASE: FiltrosPedidosUI = {
  estado: 'todos',
  estadoPago: 'todos',
  transportistaId: 'todos',
  usuarioId: 'todos',
  conSalvedad: 'todos',
  verCancelados: false,
  fechaDesde: null,
  fechaHasta: null,
  fechaEntregaProgramada: null,
}

/** Los siete filtros del panel, todos puestos. */
const SIETE: FiltrosPedidosUI = {
  estado: 'pendiente',
  estadoPago: 'parcial',
  transportistaId: 't1',
  usuarioId: 'u1',
  conSalvedad: 'con_salvedad',
  fechaEntregaProgramada: HOY,
  verCancelados: true,
}

const TRANSPORTISTAS = [{ id: 't1', nombre: 'Ramón Chofer' }]
const USUARIOS = [{ id: 'u1', nombre: 'Vale Preventista' }]

function chips(filtros: Partial<FiltrosPedidosUI>, isAdmin = true) {
  return chipsFiltrosActivos({ ...BASE, ...filtros }, { isAdmin, transportistas: TRANSPORTISTAS, usuarios: USUARIOS, hoy: HOY })
}

// =============================================================================
// OPCIONES
// =============================================================================

describe('opciones de los selects', () => {
  it('estado: seis opciones con el value que viaja a pedidos.estado', () => {
    expect(OPCIONES_ESTADO.map(o => [o.label, o.value])).toEqual([
      ['Todos los estados', 'todos'],
      ['Pendientes', 'pendiente'],
      ['En preparación', 'en_preparacion'],
      ['En camino', 'asignado'],
      ['Entregados', 'entregado'],
      ['Cancelados', 'cancelado'],
    ])
  })

  it('pago: incluye el impago del tile (#715)', () => {
    expect(OPCIONES_PAGO.map(o => o.value)).toEqual(['todos', 'pendiente', 'parcial', 'pagado', 'impago'])
  })

  it('salvedad: todas, con y sin', () => {
    expect(OPCIONES_SALVEDAD.map(o => o.value)).toEqual(['todos', 'con_salvedad', 'sin_salvedad'])
  })
})

// =============================================================================
// CONTADOR (#733)
// =============================================================================

describe('contarFiltrosActivos', () => {
  it('sin filtros es 0', () => {
    expect(contarFiltrosActivos(BASE, { isAdmin: true })).toBe(0)
    expect(contarFiltrosActivos({ estado: 'todos' }, { isAdmin: false })).toBe(0)
  })

  it('el admin cuenta los siete', () => {
    expect(contarFiltrosActivos(SIETE, { isAdmin: true })).toBe(7)
  })

  it('un no-admin cuenta sólo lo que ve: estado y cancelados', () => {
    expect(contarFiltrosActivos(SIETE, { isAdmin: false })).toBe(2)
  })

  it.each([
    ['transportista', { transportistaId: 't1' }],
    ['usuario', { usuarioId: 'u1' }],
    ['salvedad', { conSalvedad: 'sin_salvedad' as const }],
    ['entrega', { fechaEntregaProgramada: HOY }],
    ['pago pendiente', { estadoPago: 'pendiente' }],
    ['pago parcial', { estadoPago: 'parcial' }],
    ['pago pagado', { estadoPago: 'pagado' }],
  ])('%s: 1 para el admin, 0 para un no-admin', (_nombre, filtros) => {
    expect(contarFiltrosActivos({ ...BASE, ...filtros }, { isAdmin: true })).toBe(1)
    expect(contarFiltrosActivos({ ...BASE, ...filtros }, { isAdmin: false })).toBe(0)
  })

  // Comentario del dueño en #733: el tile "Impagos" pone el pago para cualquier
  // rol, así que para el no-admin ese filtro sí es visible y tiene que contar.
  it('EXCEPCIÓN: el pago impago del tile cuenta para cualquier rol', () => {
    expect(contarFiltrosActivos({ ...BASE, estadoPago: 'impago' }, { isAdmin: false })).toBe(1)
    expect(contarFiltrosActivos({ ...BASE, estadoPago: 'impago' }, { isAdmin: true })).toBe(1)
  })

  it('no cuenta el rango de fechas de carga (tiene su chip; la ventana de 30 días viene puesta)', () => {
    expect(contarFiltrosActivos({ ...BASE, fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' }, { isAdmin: true })).toBe(0)
  })

  it('"todos" y la entrega vacía no cuentan; los opcionales ausentes tampoco', () => {
    expect(contarFiltrosActivos({ estado: 'todos', fechaEntregaProgramada: null }, { isAdmin: true })).toBe(0)
  })
})

describe('describirFiltrosActivos', () => {
  it.each([
    [0, 'Refiná tu búsqueda'],
    [1, '1 filtro activo'],
    [2, '2 filtros activos'],
    [7, '7 filtros activos'],
  ])('%i → "%s"', (n, texto) => {
    expect(describirFiltrosActivos(n)).toBe(texto)
  })
})

// =============================================================================
// CHIPS
// =============================================================================

describe('chipsFiltrosActivos', () => {
  it('sin filtros no hay chips', () => {
    expect(chips({})).toEqual([])
  })

  it.each([
    [{ estado: 'entregado' }, 'estado', 'Estado', 'Entregados', { estado: 'todos' }, 'success'],
    [{ estado: 'asignado' }, 'estado', 'Estado', 'En camino', { estado: 'todos' }, 'brand'],
    [{ estado: 'cancelado' }, 'estado', 'Estado', 'Cancelados', { estado: 'todos' }, 'danger'],
    [{ estadoPago: 'pagado' }, 'estadoPago', 'Pago', 'Pagado', { estadoPago: 'todos' }, 'success'],
    [{ estadoPago: 'parcial' }, 'estadoPago', 'Pago', 'Parcial', { estadoPago: 'todos' }, 'warning'],
    [{ estadoPago: 'impago' }, 'estadoPago', 'Pago', 'Impagos', { estadoPago: 'todos' }, 'danger'],
    [{ transportistaId: 't1' }, 'transportistaId', 'Transportista', 'Ramón Chofer', { transportistaId: 'todos' }, 'neutral'],
    [{ transportistaId: 'sin_asignar' }, 'transportistaId', 'Transportista', 'Sin asignar', { transportistaId: 'todos' }, 'neutral'],
    [{ usuarioId: 'u1' }, 'usuarioId', 'Cargado por', 'Vale Preventista', { usuarioId: 'todos' }, 'neutral'],
    [{ conSalvedad: 'con_salvedad' as const }, 'conSalvedad', 'Salvedad', 'Con salvedad', { conSalvedad: 'todos' }, 'warning'],
    [{ conSalvedad: 'sin_salvedad' as const }, 'conSalvedad', 'Salvedad', 'Sin salvedad', { conSalvedad: 'todos' }, 'neutral'],
    [{ fechaEntregaProgramada: HOY }, 'fechaEntregaProgramada', 'Entrega', 'Hoy', { fechaEntregaProgramada: null }, 'brand'],
    [{ fechaEntregaProgramada: '2026-04-16' }, 'fechaEntregaProgramada', 'Entrega', 'Mañana', { fechaEntregaProgramada: null }, 'brand'],
    [{ fechaEntregaProgramada: '2026-05-20' }, 'fechaEntregaProgramada', 'Entrega', '20/05/2026', { fechaEntregaProgramada: null }, 'brand'],
    [{ verCancelados: true }, 'verCancelados', 'Cancelados', 'Incluidos', { verCancelados: false }, 'danger'],
  ])('%o → chip %s "%s: %s" que se quita con %o', (filtros, id, etiqueta, valor, quitar, tone) => {
    expect(chips(filtros)).toEqual([
      { id, etiqueta, valor, quitar, tone, nombreQuitar: `Quitar filtro ${etiqueta}` },
    ])
  })

  it('un id que no está en la lista se muestra como #id, no se pierde el chip', () => {
    expect(chips({ transportistaId: 'zz' })[0].valor).toBe('#zz')
    expect(chips({ usuarioId: 'yy' })[0].valor).toBe('#yy')
  })

  it('el id se compara como string: un id numérico de la base resuelve igual', () => {
    const resultado = chipsFiltrosActivos(
      { ...BASE, transportistaId: '7' },
      { isAdmin: true, transportistas: [{ id: 7 as unknown as string, nombre: 'Numérico' }], hoy: HOY },
    )
    expect(resultado[0].valor).toBe('Numérico')
  })

  it('el rango de fechas es el chip de siempre: "Filtrado: desde – hasta", con puntos suspensivos si falta una punta', () => {
    expect(chips({ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' })).toEqual([{
      id: 'fechas',
      etiqueta: 'Filtrado',
      valor: '2026-04-01 – 2026-04-15',
      nombreQuitar: 'Limpiar filtro de fechas',
      quitar: { fechaDesde: null, fechaHasta: null },
      tone: 'brand',
    }])
    expect(chips({ fechaDesde: '2026-04-01' })[0].valor).toBe('2026-04-01 – …')
    expect(chips({ fechaHasta: '2026-04-15' })[0].valor).toBe('… – 2026-04-15')
  })

  it('un rango invertido que llegue de afuera se marca en rojo', () => {
    expect(chips({ fechaDesde: '2026-05-31', fechaHasta: '2026-05-01' })[0].tone).toBe('danger')
  })

  it('el orden es el del panel, con las fechas al final', () => {
    expect(chips({ ...SIETE, fechaDesde: '2026-04-01' }).map(c => c.id)).toEqual([
      'estado', 'estadoPago', 'transportistaId', 'usuarioId', 'conSalvedad', 'fechaEntregaProgramada', 'verCancelados', 'fechas',
    ])
  })

  it('un no-admin sólo tiene chips de estado, cancelados y fechas (#733)', () => {
    expect(chips({ ...SIETE, fechaDesde: '2026-04-01' }, false).map(c => c.id)).toEqual(['estado', 'verCancelados', 'fechas'])
  })

  it('EXCEPCIÓN: un no-admin sí tiene el chip del pago impago del tile', () => {
    expect(chips({ estadoPago: 'impago' }, false).map(c => c.id)).toEqual(['estadoPago'])
  })

  it('el contador y los chips (sin fechas) cuentan lo mismo, para los dos roles', () => {
    for (const isAdmin of [true, false]) {
      for (const filtros of [SIETE, { ...SIETE, estadoPago: 'impago' }, { estado: 'todos' }]) {
        const sinFechas = chips(filtros, isAdmin).filter(c => c.id !== 'fechas')
        expect(sinFechas).toHaveLength(contarFiltrosActivos({ ...BASE, ...filtros }, { isAdmin }))
      }
    }
  })
})

// =============================================================================
// RANGO DE FECHAS (#734)
// =============================================================================

describe('validarRangoFechas', () => {
  it.each([
    [null, null],
    ['2026-05-01', null],
    [null, '2026-05-31'],
    ['2026-05-01', '2026-05-31'],
    ['2026-05-01', '2026-05-01'],
    ['', ''],
  ])('desde=%s hasta=%s es válido', (desde, hasta) => {
    expect(validarRangoFechas(desde, hasta)).toEqual({ valido: true, mensaje: null })
  })

  it('desde posterior a hasta es inválido, con un mensaje para el usuario', () => {
    expect(validarRangoFechas('2026-05-31', '2026-05-01')).toEqual({ valido: false, mensaje: MENSAJE_RANGO_INVERTIDO })
    expect(MENSAJE_RANGO_INVERTIDO).toMatch(/posterior/)
  })

  it('un año anterior a 2000 ya tipeado entero sí cuenta: 1999 invertido se avisa', () => {
    expect(validarRangoFechas('1999-12-31', '1999-12-30').valido).toBe(false)
    expect(validarRangoFechas('1999-12-30', '1999-12-31').valido).toBe(true)
  })

  it('compara fechas, no el largo: cruza de año bien', () => {
    expect(validarRangoFechas('2025-12-31', '2026-01-01').valido).toBe(true)
    expect(validarRangoFechas('2026-01-01', '2025-12-31').valido).toBe(false)
  })

  // Al tipear el año con el teclado el navegador manda '0002-…', '0020-…',
  // '0202-…' antes de '2026-…'. Con la otra punta puesta eso parece un rango
  // invertido pasajero, y no hay que avisarlo: es un borrador.
  it.each([
    ['2026-05-01', '0002-05-01'],
    ['2026-05-01', '0020-05-01'],
    ['2026-05-01', '0202-05-01'],
    ['0002-05-01', '2026-05-31'],
    ['0999-12-31', '0999-12-30'],
  ])('una punta a medio escribir no es un rango invertido (desde=%s hasta=%s)', (desde, hasta) => {
    expect(validarRangoFechas(desde, hasta)).toEqual({ valido: true, mensaje: null })
  })
})

describe('esFechaCompleta / puntaFechaEmitible', () => {
  it.each(['1000-01-01', '1999-12-31', '2000-01-01', '2026-05-01', '2099-12-31'])('%s es una fecha completa', (valor) => {
    expect(esFechaCompleta(valor)).toBe(true)
    expect(puntaFechaEmitible(valor)).toBe(true)
  })

  it.each(['0002-05-01', '0020-05-01', '0202-05-01', '0999-12-31', '2026-05', '26-05-01', 'abc'])(
    '%s es un borrador: no se emite',
    (valor) => {
      expect(esFechaCompleta(valor)).toBe(false)
      expect(puntaFechaEmitible(valor)).toBe(false)
    },
  )

  it.each(['', null, undefined])('la punta vacía (%s) sí se emite: es un rango abierto', (valor) => {
    expect(esFechaCompleta(valor)).toBe(false)
    expect(puntaFechaEmitible(valor)).toBe(true)
  })
})

describe('diaSiguienteISO', () => {
  it.each([
    ['2026-04-15', '2026-04-16'],
    ['2026-04-30', '2026-05-01'],
    ['2026-12-31', '2027-01-01'],
    ['2028-02-28', '2028-02-29'],
  ])('%s → %s', (hoy, manana) => {
    expect(diaSiguienteISO(hoy)).toBe(manana)
  })
})

// =============================================================================
// LIMPIAR TODO
// =============================================================================

describe('payloadLimpiarTodo', () => {
  it('los siete filtros del panel a default, sin búsqueda ni fechas de carga', () => {
    expect(payloadLimpiarTodo()).toEqual({
      estado: 'todos',
      estadoPago: 'todos',
      transportistaId: 'todos',
      usuarioId: 'todos',
      conSalvedad: 'todos',
      fechaEntregaProgramada: null,
      verCancelados: false,
    })
    expect(payloadLimpiarTodo()).not.toHaveProperty('fechaDesde')
    expect(payloadLimpiarTodo()).not.toHaveProperty('fechaHasta')
    expect(payloadLimpiarTodo()).not.toHaveProperty('busqueda')
  })

  it('aplicado sobre los siete filtros, no deja ninguno activo para ningún rol', () => {
    const limpio = { ...SIETE, ...payloadLimpiarTodo() }
    expect(contarFiltrosActivos(limpio, { isAdmin: true })).toBe(0)
    expect(contarFiltrosActivos(limpio, { isAdmin: false })).toBe(0)
  })
})
