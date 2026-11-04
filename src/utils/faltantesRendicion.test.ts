import { describe, expect, it } from 'vitest'
import {
  ETIQUETA_CAUSAL,
  MENSAJE_SIN_EMPLEADOS,
  MENSAJE_SUPERA,
  empleadoSugerido,
  empleadosParaFaltante,
  gastosDeResolucion,
  quedaAEntregar,
  textoFaltante,
  totalImputado,
} from './faltantesRendicion'
import { formatPrecio } from './formatters'
import type { FaltanteDeRendicion } from '../types/gastos'
import type { EmpleadoParaElegir } from '../types/personal'

const emp = (o: Partial<EmpleadoParaElegir> = {}): EmpleadoParaElegir => ({
  id: 1,
  nombre: 'Marcos Delgado',
  usuario_id: null,
  vehiculo_id: null,
  activo: true,
  ...o,
})

const faltante = (o: Partial<FaltanteDeRendicion> = {}): FaltanteDeRendicion => ({
  id: 1,
  transportista_id: 'u-tr',
  fecha: '2026-06-11',
  causal: 'empleado',
  monto: 2000,
  observacion: null,
  empleado: { id: 1, nombre: 'Marcos Delgado' },
  gasto_id: null,
  rubro_nombre: null,
  creado_por_nombre: 'Agustín',
  created_at: '2026-11-03T12:00:00Z',
  ...o,
})

describe('textos', () => {
  it('las causales y los avisos son los del plan', () => {
    expect(ETIQUETA_CAUSAL).toEqual({
      empleado: 'A cargo del empleado',
      robo_perdida: 'Robo o pérdida',
      gasto_no_cargado: 'Gasto que no se cargó',
    })
    expect(MENSAJE_SIN_EMPLEADOS).toBe('Para cargársela a alguien, primero dalo de alta en Personal')
    expect(MENSAJE_SUPERA).toBe('Lo imputado supera lo que había para entregar')
  })
})

describe('totalImputado y quedaAEntregar', () => {
  it('suma y redondea a dos decimales', () => {
    expect(totalImputado([{ monto: 1000.005 }, { monto: 2000 }])).toBe(3000.01)
    expect(totalImputado([])).toBe(0)
  })

  it('lo que queda es lo que había menos lo imputado', () => {
    expect(quedaAEntregar(800000, [{ monto: 3000 }, { monto: 2000 }])).toBe(795000)
    expect(quedaAEntregar(1000, [{ monto: 1500 }])).toBe(-500)
  })
})

describe('empleadosParaFaltante', () => {
  it('saca los inactivos y al propio usuario, y ordena por nombre', () => {
    const lista = [
      emp({ id: 1, nombre: 'Zulema Paz' }),
      emp({ id: 2, nombre: 'Ana Gómez', activo: false }),
      emp({ id: 3, nombre: 'Pablo Ríos', usuario_id: 'u-admin' }),
      emp({ id: 4, nombre: 'Beto Sosa' }),
    ]
    expect(empleadosParaFaltante(lista, 'u-admin').map(e => e.id)).toEqual([4, 1])
  })

  it('sin usuario no saca a nadie por eso', () => {
    expect(empleadosParaFaltante([emp({ usuario_id: 'u-x' })], null)).toHaveLength(1)
  })

  it('con todos inactivos da vacío', () => {
    expect(empleadosParaFaltante([emp({ activo: false }), emp({ id: 2, activo: false })], 'u')).toEqual([])
  })
})

describe('empleadoSugerido', () => {
  it('es el activo vinculado al transportista', () => {
    const lista = [emp({ id: 1 }), emp({ id: 2, usuario_id: 'u-tr' })]
    expect(empleadoSugerido(lista, 'u-tr')).toBe(2)
  })

  it('sin vinculado, o con el vinculado inactivo, no sugiere a nadie', () => {
    expect(empleadoSugerido([emp({ id: 1 })], 'u-tr')).toBeNull()
    expect(empleadoSugerido([emp({ id: 2, usuario_id: 'u-tr', activo: false })], 'u-tr')).toBeNull()
  })
})

describe('gastosDeResolucion', () => {
  it('son los gasto_id no nulos', () => {
    const lista = [
      faltante({ id: 1 }),
      faltante({ id: 2, causal: 'robo_perdida', empleado: null, gasto_id: 40 }),
      faltante({ id: 3, causal: 'gasto_no_cargado', empleado: null, gasto_id: 41 }),
    ]
    expect(gastosDeResolucion(lista)).toEqual(new Set([40, 41]))
    expect(gastosDeResolucion([])).toEqual(new Set())
  })
})

describe('textoFaltante', () => {
  it('a cargo de un empleado', () => {
    expect(textoFaltante(faltante())).toBe('A cargo de Marcos Delgado · ' + formatPrecio(2000))
  })

  it('robo o pérdida', () => {
    expect(textoFaltante(faltante({ causal: 'robo_perdida', monto: 1000, empleado: null, gasto_id: 40 })))
      .toBe('Robo o pérdida · ' + formatPrecio(1000))
  })

  it('gasto que no se cargó, con su rubro', () => {
    expect(textoFaltante(faltante({
      causal: 'gasto_no_cargado', monto: 500, empleado: null, gasto_id: 41, rubro_nombre: 'Peajes y estacionamiento',
    }))).toBe('Gasto que no se cargó: Peajes y estacionamiento · ' + formatPrecio(500))
  })

  it('suma la observación si la hay', () => {
    expect(textoFaltante(faltante({ observacion: 'Faltó en la caja' })))
      .toBe('A cargo de Marcos Delgado · ' + formatPrecio(2000) + ' · Faltó en la caja')
    expect(textoFaltante(faltante({ causal: 'robo_perdida', monto: 1000, empleado: null, observacion: 'Se lo robaron' })))
      .toBe('Robo o pérdida · ' + formatPrecio(1000) + ' · Se lo robaron')
  })

  it('ignora una observación en blanco', () => {
    expect(textoFaltante(faltante({ observacion: '   ' }))).toBe('A cargo de Marcos Delgado · ' + formatPrecio(2000))
  })
})
