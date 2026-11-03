import { describe, expect, it } from 'vitest'
import {
  PUESTOS,
  conceptoDeMovimiento,
  contarPersonal,
  errorDeArreglo,
  aPagar,
  errorDeMovimiento,
  errorDePago,
  errorDeSueldo,
  estadoSaldo,
  etiquetaPuesto,
  fechaCompleta,
  filtrarPersonal,
  formatCuil,
  inicioDelPeriodo,
  normalizarCuil,
  paraLiquidar,
  parseMonto,
  textoArregloAnterior,
  textoArregloCorto,
  textoArregloLargo,
  textoPeriodo,
} from './personal'
import { formatPrecio } from './formatters'
import type {
  ArregloEmpleado,
  Empleado,
  MovimientoEmpleado,
  PeriodoPendiente,
  VistaPreviaLiquidacion,
} from '../types/personal'

const arreglo = (o: Partial<ArregloEmpleado> = {}): ArregloEmpleado => ({
  id: 1,
  vigente_desde: '2026-10-01',
  vigente_hasta: null,
  sueldo: 280000,
  frecuencia: 'semanal',
  comisiona: false,
  ...o,
})

const mov = (o: Partial<MovimientoEmpleado> = {}): MovimientoEmpleado => ({
  id: 1,
  fecha: '2026-10-20',
  tipo: 'mercaderia',
  monto: -1000,
  saldo: -1000,
  observacion: null,
  pago_id: null,
  pedido_id: null,
  gasto: null,
  revierte_id: null,
  revertido: false,
  creado_por_nombre: null,
  created_at: '2026-10-20T12:00:00Z',
  liquidacion: null,
  rendicion: null,
  ...o,
})

const emp = (o: Partial<Empleado> = {}): Empleado => ({
  id: 1,
  nombre: 'Empleado',
  puesto: 'otro',
  sucursal_id: 1,
  de_las_dos: false,
  cuil: null,
  fecha_ingreso: null,
  telefono: null,
  activo: true,
  fecha_baja: null,
  usuario: null,
  cliente: null,
  vehiculo: null,
  arreglo: null,
  arranque: null,
  saldo: 0,
  es_propio: false,
  periodo: null,
  ...o,
})

describe('PUESTOS', () => {
  it('va en el orden de la maqueta', () => {
    expect(PUESTOS.map(p => p.etiqueta)).toEqual([
      'Preventista', 'Transportista', 'Ayudante', 'Depósito', 'Administración', 'Encargado', 'Otro',
    ])
    expect(PUESTOS.map(p => p.valor)).toEqual([
      'preventista', 'transportista', 'ayudante', 'deposito', 'administracion', 'encargado', 'otro',
    ])
  })

  it('etiquetaPuesto', () => {
    expect(etiquetaPuesto('deposito')).toBe('Depósito')
    expect(etiquetaPuesto('administracion')).toBe('Administración')
  })
})

describe('inicioDelPeriodo', () => {
  it('semanal: el lunes de esa semana', () => {
    expect(inicioDelPeriodo('2026-10-29', 'semanal')).toBe('2026-10-26')
    expect(inicioDelPeriodo('2026-11-01', 'semanal')).toBe('2026-10-26') // domingo
    expect(inicioDelPeriodo('2026-10-26', 'semanal')).toBe('2026-10-26') // lunes
    expect(inicioDelPeriodo('2026-03-01', 'semanal')).toBe('2026-02-23') // cruza de mes
  })

  it('mensual: el día 1', () => {
    expect(inicioDelPeriodo('2026-10-29', 'mensual')).toBe('2026-10-01')
    expect(inicioDelPeriodo('2026-10-01', 'mensual')).toBe('2026-10-01')
  })
})

describe('textos del arreglo', () => {
  it('corto', () => {
    expect(textoArregloCorto({ sueldo: 150000, frecuencia: 'semanal', comisiona: true }))
      .toBe(`Semanal · ${formatPrecio(150000)} + comisión`)
    expect(textoArregloCorto({ sueldo: 0, frecuencia: 'semanal', comisiona: true }))
      .toBe('Semanal · sólo comisión')
    expect(textoArregloCorto({ sueldo: 900000, frecuencia: 'mensual', comisiona: false }))
      .toBe(`Mensual · ${formatPrecio(900000)}`)
  })

  it('largo', () => {
    expect(textoArregloLargo(arreglo()))
      .toBe(`${formatPrecio(280000)} por semana · no comisiona · desde el 01/10/2026`)
    expect(textoArregloLargo(arreglo({ frecuencia: 'mensual', comisiona: true })))
      .toBe(`${formatPrecio(280000)} por mes · comisiona · desde el 01/10/2026`)
  })

  it('anterior', () => {
    expect(textoArregloAnterior(arreglo({ sueldo: 250000, vigente_desde: '2025-02-03', vigente_hasta: '2026-09-30' })))
      .toBe(`Antes: ${formatPrecio(250000)} por semana, del 03/02/2025 al 30/09/2026`)
  })
})

describe('estadoSaldo', () => {
  it('a favor, debe o al día', () => {
    expect(estadoSaldo(13500)).toBe('a_favor')
    expect(estadoSaldo(-1)).toBe('debe')
    expect(estadoSaldo(0.004)).toBe('al_dia')
    expect(estadoSaldo(-0.004)).toBe('al_dia')
    expect(estadoSaldo(0)).toBe('al_dia')
  })
})

describe('conceptoDeMovimiento', () => {
  it('mercadería de un pedido', () => {
    expect(conceptoDeMovimiento(mov({ pedido_id: 8840 }))).toEqual({
      titulo: 'Mercadería',
      detalle: 'Pedido #8840 · pagado con adelanto de sueldo',
    })
  })

  it('mercadería de un pago a cuenta', () => {
    expect(conceptoDeMovimiento(mov())).toEqual({
      titulo: 'Mercadería',
      detalle: 'Pago a cuenta · pagado con adelanto de sueldo',
    })
  })

  it('la observación manda sobre el detalle armado', () => {
    expect(conceptoDeMovimiento(mov({ pedido_id: 8840, observacion: 'El pago cambió de monto' })))
      .toEqual({ titulo: 'Mercadería', detalle: 'El pago cambió de monto' })
  })

  it('reintegro de un gasto, con y sin vehículo', () => {
    expect(conceptoDeMovimiento(mov({
      tipo: 'reintegro', monto: 5000, gasto: { id: 3, rubro: 'Combustible', vehiculo: 'Partner AC456EF' },
    }))).toEqual({
      titulo: 'Reintegro de gasto',
      detalle: 'Combustible Partner AC456EF · pagó con plata propia',
    })
    expect(conceptoDeMovimiento(mov({
      tipo: 'reintegro', monto: 5000, gasto: { id: 4, rubro: 'Librería', vehiculo: null },
    })).detalle).toBe('Librería · pagó con plata propia')
  })

  it('adelanto y ajuste según el signo', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'adelanto', monto: -20000 })))
      .toEqual({ titulo: 'Adelanto en efectivo', detalle: null })
    expect(conceptoDeMovimiento(mov({ tipo: 'ajuste', monto: -3000, observacion: 'Faltante' })))
      .toEqual({ titulo: 'Ajuste en contra', detalle: 'Faltante' })
    expect(conceptoDeMovimiento(mov({ tipo: 'ajuste', monto: 3000 })).titulo).toBe('Ajuste a favor')
  })

  it('un faltante de rendición titula la rendición y lleva la observación de detalle', () => {
    const rendicion = { transportista_nombre: 'Transporte Taco Pozo', fecha: '2026-06-11' }
    expect(conceptoDeMovimiento(mov({ tipo: 'faltante', monto: -3000, observacion: 'Faltó plata', rendicion })))
      .toEqual({ titulo: 'Faltante de rendición del 11/06 (Transporte Taco Pozo)', detalle: 'Faltó plata' })
    expect(conceptoDeMovimiento(mov({ tipo: 'faltante', monto: -3000, rendicion })).detalle).toBeNull()
  })

  it('la compensación de un faltante titula que se deshizo', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'faltante', monto: 3000, revierte_id: 9 })).titulo)
      .toBe('Se deshizo un faltante de rendición')
  })

  it('reversiones', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'adelanto', monto: 20000, revierte_id: 7 })).titulo)
      .toBe('Revierte un adelanto en efectivo')
    expect(conceptoDeMovimiento(mov({ tipo: 'ajuste', monto: -3000, revierte_id: 8 })).titulo)
      .toBe('Revierte un ajuste')
  })
})

describe('filtrarPersonal y contarPersonal', () => {
  const lista = [
    emp({ id: 1, nombre: 'Zulema Paz', saldo: 0 }),
    emp({ id: 2, nombre: 'Pablo Ríos', saldo: -5000, puesto: 'transportista', vehiculo: { id: 9, patente: 'AC456EF', descripcion: 'Partner' } }),
    emp({ id: 3, nombre: 'Ana Gómez', activo: false, saldo: 2000, usuario: { id: 'u-1', nombre: 'agomez' } }),
    emp({ id: 4, nombre: 'Beto Sosa', activo: false, saldo: 0, cliente: { id: 5, nombre_fantasia: 'Kiosco Sosa', activo: true } }),
  ]
  const ids = (l: Empleado[]) => l.map(e => e.id)
  const HOY = '2026-10-30'

  it('todos son los activos, por nombre', () => {
    expect(ids(filtrarPersonal(lista, 'todos', '', HOY))).toEqual([2, 1])
  })

  it('con saldo trae también al inactivo con saldo', () => {
    expect(ids(filtrarPersonal(lista, 'con_saldo', '', HOY))).toEqual([3, 2])
  })

  it('inactivos', () => {
    expect(ids(filtrarPersonal(lista, 'inactivos', '', HOY))).toEqual([3, 4])
  })

  it('busca sin tildes en nombre, puesto, usuario, cliente y patente', () => {
    expect(ids(filtrarPersonal(lista, 'todos', 'rios', HOY))).toEqual([2])
    expect(ids(filtrarPersonal(lista, 'todos', 'ac456', HOY))).toEqual([2])
    expect(ids(filtrarPersonal(lista, 'todos', 'transportista', HOY))).toEqual([2])
    expect(ids(filtrarPersonal(lista, 'inactivos', 'agomez', HOY))).toEqual([3])
    expect(ids(filtrarPersonal(lista, 'inactivos', 'kiosco', HOY))).toEqual([4])
  })

  it('no muta la lista', () => {
    const copia = [...lista]
    filtrarPersonal(lista, 'todos', '', HOY)
    expect(lista).toEqual(copia)
  })

  it('cuenta cada filtro', () => {
    expect(contarPersonal(lista, HOY)).toEqual({ todos: 2, para_liquidar: 0, con_saldo: 2, inactivos: 2 })
  })

  it('para liquidar deja sólo a los de período para liquidar, y los cuenta', () => {
    const periodo = (o: Partial<PeriodoPendiente> = {}): PeriodoPendiente => ({
      desde: '2026-10-26', hasta: '2026-11-01', frecuencia: 'semanal', mas_vencidos: 0, ...o,
    })
    const con = [
      emp({ id: 1, nombre: 'Al viernes', periodo: periodo() }),
      emp({ id: 2, nombre: 'Falta mucho', periodo: periodo({ desde: '2026-11-02', hasta: '2026-11-08' }) }),
      emp({ id: 3, nombre: 'Sin período', periodo: null }),
      emp({ id: 4, nombre: 'Se fue', activo: false, periodo: periodo() }),
    ]
    expect(ids(filtrarPersonal(con, 'para_liquidar', '', HOY))).toEqual([1, 4])
    expect(ids(filtrarPersonal(con, 'para_liquidar', '', '2026-10-28'))).toEqual([])
    expect(contarPersonal(con, HOY).para_liquidar).toBe(2)
    expect(contarPersonal(con, '2026-10-28').para_liquidar).toBe(0)
  })
})

describe('CUIL', () => {
  it('formatCuil y normalizarCuil', () => {
    expect(formatCuil('20301234567')).toBe('20-30123456-7')
    expect(normalizarCuil(' 20-30123456-7 ')).toBe('20301234567')
    expect(normalizarCuil('  ')).toBeNull()
    expect(normalizarCuil('')).toBeNull()
  })
})

describe('errorDeArreglo', () => {
  const vigente = arreglo({ vigente_desde: '2026-10-26' })
  const base = { vigente_desde: '2026-10-26', sueldo: 100000, frecuencia: 'semanal' as const, comisiona: false }

  it('una fecha anterior al vigente avisa con su fecha', () => {
    expect(errorDeArreglo({ ...base, vigente_desde: '2026-10-19' }, vigente)).toBe(
      'Un arreglo nuevo vale desde después del vigente (26/10/2026): para corregir el vigente usá su misma fecha',
    )
  })

  it('la misma fecha corrige y una posterior suma', () => {
    expect(errorDeArreglo(base, vigente)).toBeNull()
    expect(errorDeArreglo({ ...base, vigente_desde: '2026-11-02' }, vigente)).toBeNull()
    expect(errorDeArreglo({ ...base, vigente_desde: '2026-01-01' }, null)).toBeNull()
  })

  it('sin sueldo fijo tiene que comisionar', () => {
    expect(errorDeArreglo({ ...base, sueldo: 0 }, vigente)).toBe('Un arreglo sin sueldo fijo tiene que comisionar')
    expect(errorDeArreglo({ ...base, sueldo: 0, comisiona: true }, vigente)).toBeNull()
  })

  it('el sueldo no es negativo', () => {
    expect(errorDeArreglo({ ...base, sueldo: -1 }, vigente)).toBe('El sueldo no puede ser negativo')
  })
})

describe('errorDeMovimiento', () => {
  const hoy = '2026-10-29'
  const adelanto = { tipo: 'adelanto' as const, monto: 20000, fecha: hoy, observacion: null }

  it('un adelanto válido no da error', () => {
    expect(errorDeMovimiento(adelanto, hoy)).toBeNull()
  })

  it('el ajuste necesita observación', () => {
    const ajuste = { tipo: 'ajuste' as const, monto: 3000, fecha: hoy, observacion: null }
    expect(errorDeMovimiento(ajuste, hoy)).toBe('El ajuste necesita una observación que diga por qué')
    expect(errorDeMovimiento({ ...ajuste, observacion: '   ' }, hoy)).toBe('El ajuste necesita una observación que diga por qué')
    expect(errorDeMovimiento({ ...ajuste, observacion: 'Saldo al empezar' }, hoy)).toBeNull()
    expect(errorDeMovimiento({ ...ajuste, monto: -3000, observacion: 'Faltante' }, hoy)).toBeNull()
  })

  it('el ajuste no puede ser cero', () => {
    expect(errorDeMovimiento({ tipo: 'ajuste', monto: 0, fecha: hoy, observacion: 'x' }, hoy))
      .toBe('El ajuste no puede ser cero')
  })

  it('el adelanto tiene que ser mayor a cero', () => {
    expect(errorDeMovimiento({ ...adelanto, monto: 0 }, hoy)).toBe('El monto tiene que ser mayor a cero')
    expect(errorDeMovimiento({ ...adelanto, monto: -5 }, hoy)).toBe('El monto tiene que ser mayor a cero')
  })

  it('la fecha no puede ser futura', () => {
    expect(errorDeMovimiento({ ...adelanto, fecha: '2026-10-30' }, hoy)).toBe('La fecha del movimiento no puede ser futura')
    expect(errorDeMovimiento({ ...adelanto, fecha: '2026-10-28' }, hoy)).toBeNull()
  })
})

describe('parseMonto', () => {
  it.each([
    ['280.000', 280000],
    ['280.000,50', 280000.5],
    ['1.234', 1234],
    ['1.234.567', 1234567],
    ['1.234,56', 1234.56],
    ['1.5', 1.5],
    ['12.50', 12.5],
    ['280 000', 280000],
    ['$ 280.000', 280000],
    ['$280.000', 280000],
    ['  3000  ', 3000],
    ['0', 0],
    ['150000', 150000],
    ['10,5', 10.5],
  ])('lee %j como %d', (texto, esperado) => {
    expect(parseMonto(texto)).toBe(esperado)
  })

  it.each(['', '   ', '-280.000', '280,000', '1,234.56', '280.000.', '12abc', 'abc', '1.2345', '280.00.0', '$'])(
    'no entiende %j: da null, nunca 0',
    texto => {
      expect(parseMonto(texto)).toBeNull()
    },
  )
})

describe('fechaCompleta', () => {
  it('pasa YYYY-MM-DD a dd/mm/aaaa', () => {
    expect(fechaCompleta('2026-09-30')).toBe('30/09/2026')
  })
})

describe('textoPeriodo', () => {
  it('semanal', () => {
    expect(textoPeriodo({ desde: '2026-10-26', hasta: '2026-11-01', frecuencia: 'semanal' }))
      .toBe('Semana 26/10 al 01/11')
  })

  it('mensual de mes entero, también febrero bisiesto', () => {
    expect(textoPeriodo({ desde: '2026-10-01', hasta: '2026-10-31', frecuencia: 'mensual' })).toBe('Octubre 2026')
    expect(textoPeriodo({ desde: '2028-02-01', hasta: '2028-02-29', frecuencia: 'mensual' })).toBe('Febrero 2028')
  })

  it('mensual parcial', () => {
    expect(textoPeriodo({ desde: '2026-10-15', hasta: '2026-10-31', frecuencia: 'mensual' })).toBe('15/10 al 31/10')
  })
})

describe('paraLiquidar', () => {
  const p: PeriodoPendiente = { desde: '2026-10-26', hasta: '2026-11-01', frecuencia: 'semanal', mas_vencidos: 0 }

  it('aparece dos días antes de que termine, no antes', () => {
    expect(paraLiquidar(p, '2026-10-29')).toBe(false)
    expect(paraLiquidar(p, '2026-10-30')).toBe(true)
    expect(paraLiquidar(p, '2026-11-01')).toBe(true)
  })

  it('un período terminado sigue apareciendo', () => {
    expect(paraLiquidar(p, '2026-11-05')).toBe(true)
  })

  it('sin período o con uno que no empezó, no', () => {
    expect(paraLiquidar(null, '2026-10-30')).toBe(false)
    expect(paraLiquidar({ ...p, desde: '2026-11-02', hasta: '2026-11-08' }, '2026-11-01')).toBe(false)
  })

  it('cuenta en días de calendario al cruzar de mes', () => {
    const mensual: PeriodoPendiente = { desde: '2026-02-01', hasta: '2026-02-28', frecuencia: 'mensual', mas_vencidos: 0 }
    expect(paraLiquidar(mensual, '2026-02-25')).toBe(false)
    expect(paraLiquidar(mensual, '2026-02-26')).toBe(true)
  })
})

describe('aPagar', () => {
  const vista = {
    saldo_actual: -22800,
    comisiones: { total: 368600, base: 0, detalle: [] },
    ajustes: { total: -1240, detalle: [] },
  } as unknown as VistaPreviaLiquidacion

  it('saldo + sueldo + comisiones + ajustes', () => {
    expect(aPagar(vista, 650000)).toBe(994560)
  })

  it('redondea a 2 decimales', () => {
    const v = {
      ...vista,
      saldo_actual: 0.1,
      comisiones: { total: 0.2, base: 0, detalle: [] },
      ajustes: { total: 0, detalle: [] },
    } as unknown as VistaPreviaLiquidacion
    expect(aPagar(v, 0)).toBe(0.3)
  })
})

describe('conceptoDeMovimiento de una liquidación', () => {
  const liq = (o: Partial<NonNullable<MovimientoEmpleado['liquidacion']>> = {}) => ({
    id: 5, desde: '2026-10-26', hasta: '2026-11-01', frecuencia: 'semanal' as const, pedidos: 142, anulada: false, ...o,
  })
  const chofer = { transportista_nombre: 'Martín Sosa', fecha: '2026-10-30' }

  it('sueldo', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'sueldo', monto: 650000, liquidacion: liq() })))
      .toEqual({ titulo: 'Sueldo fijo', detalle: 'Semana 26/10 al 01/11' })
    expect(conceptoDeMovimiento(mov({ tipo: 'sueldo', monto: 50000, liquidacion: liq(), observacion: 'Faltó dos días' })).detalle)
      .toBe('Semana 26/10 al 01/11 · Faltó dos días')
  })

  it('comisión, en singular y plural', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'comision', monto: 1, liquidacion: liq() })))
      .toEqual({ titulo: 'Comisión', detalle: '142 pedidos · Semana 26/10 al 01/11' })
    expect(conceptoDeMovimiento(mov({ tipo: 'comision', monto: 1, liquidacion: liq({ pedidos: 1 }) })).detalle)
      .toBe('1 pedido · Semana 26/10 al 01/11')
  })

  it('ajuste de comisión', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'ajuste_comision', monto: -1240, liquidacion: liq() })))
      .toEqual({ titulo: 'Ajuste de comisión', detalle: 'Semana 26/10 al 01/11' })
  })

  it('pago de una liquidación: oficina, rendición y anulada', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'pago', monto: -100, liquidacion: liq() })))
      .toEqual({ titulo: 'Pago', detalle: 'Liquidación Semana 26/10 al 01/11 · la pagó la oficina' })
    expect(conceptoDeMovimiento(mov({ tipo: 'pago', monto: -100, liquidacion: liq(), rendicion: chofer })).detalle)
      .toBe('Liquidación Semana 26/10 al 01/11 · salió de la rendición de Martín Sosa del 30/10')
    expect(conceptoDeMovimiento(mov({ tipo: 'pago', monto: -100, liquidacion: liq({ anulada: true }), rendicion: chofer })).detalle)
      .toBe('Liquidación Semana 26/10 al 01/11, anulada · salió de la rendición de Martín Sosa del 30/10')
  })

  it('pago suelto: oficina, rendición y con observación', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'pago', monto: -100 })))
      .toEqual({ titulo: 'Pago', detalle: 'Pago suelto · lo pagó la oficina' })
    expect(conceptoDeMovimiento(mov({ tipo: 'pago', monto: -100, rendicion: chofer })).detalle)
      .toBe('Pago suelto · salió de la rendición de Martín Sosa del 30/10')
    expect(conceptoDeMovimiento(mov({ tipo: 'pago', monto: -100, observacion: 'Aguinaldo' })).detalle).toBe('Aguinaldo')
  })

  it('reversiones, con la observación de detalle', () => {
    expect(conceptoDeMovimiento(mov({ tipo: 'pago', monto: 100, revierte_id: 9, observacion: 'Se anula' })))
      .toEqual({ titulo: 'Revierte un pago', detalle: 'Se anula' })
    expect(conceptoDeMovimiento(mov({ tipo: 'sueldo', monto: -1, revierte_id: 9 })).titulo).toBe('Revierte un sueldo')
    expect(conceptoDeMovimiento(mov({ tipo: 'comision', monto: -1, revierte_id: 9 })).titulo).toBe('Revierte una comisión')
    expect(conceptoDeMovimiento(mov({ tipo: 'ajuste_comision', monto: -1, revierte_id: 9 })).titulo)
      .toBe('Revierte un ajuste de comisión')
  })
})

describe('errorDeMovimiento de un pago', () => {
  const hoy = '2026-10-30'
  it('pide monto mayor a cero y no pide observación', () => {
    expect(errorDeMovimiento({ tipo: 'pago', monto: 0, fecha: hoy, observacion: null }, hoy))
      .toBe('El monto tiene que ser mayor a cero')
    expect(errorDeMovimiento({ tipo: 'pago', monto: 1000, fecha: hoy, observacion: null }, hoy)).toBeNull()
  })
})

describe('errorDeSueldo', () => {
  it('no negativo', () => {
    expect(errorDeSueldo(-1, 70000, null)).toBe('El sueldo no puede ser negativo')
  })

  it('sin diferencia no pide motivo', () => {
    expect(errorDeSueldo(70000, 70000, null)).toBeNull()
  })

  it('con diferencia pide motivo', () => {
    expect(errorDeSueldo(50000, 70000, null)).toBe('Escribí por qué cambia el sueldo')
    expect(errorDeSueldo(50000, 70000, '  ')).toBe('Escribí por qué cambia el sueldo')
    expect(errorDeSueldo(50000, 70000, 'Faltó dos días')).toBeNull()
  })
})

describe('errorDePago', () => {
  const hoy = '2026-10-30'

  it('no negativo y no más de lo que toca', () => {
    expect(errorDePago(-1, 100, hoy, hoy)).toBe('El pago no puede ser negativo')
    expect(errorDePago(101, 100, hoy, hoy))
      .toBe('No se le puede pagar más de lo que le toca: si le adelantás plata, cargá un adelanto')
    expect(errorDePago(100, 100, hoy, hoy)).toBeNull()
  })

  it('el que debe no cobra: pago 0 con tope negativo es válido', () => {
    expect(errorDePago(0, -500, hoy, hoy)).toBeNull()
  })

  it('la fecha no puede ser futura', () => {
    expect(errorDePago(50, 100, '2026-10-31', hoy)).toBe('La fecha del pago no puede ser futura')
  })
})

