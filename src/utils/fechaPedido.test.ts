/**
 * El piso y el techo de la fecha de un pedido para quien no es admin (#1514). Espejo de
 * `_fecha_pedido_fuera_de_rango` (mig 481): mismos bordes que el ensayo
 * scripts/test-fecha-pedido-piso-1514.sql.
 */
import { describe, it, expect } from 'vitest'
import {
  DIAS_ATRAS_FECHA_PEDIDO_POR_DEFECTO,
  diasAtrasVigentes,
  fechaPedidoFueraDeRango,
  mensajeFechaAnteriorAlPiso,
  pisoFechaPedido,
} from './fechaPedido'

const HOY = '2026-11-10'

describe('pisoFechaPedido', () => {
  it('resta los días de la política al día argentino de hoy', () => {
    expect(pisoFechaPedido(7, HOY)).toBe('2026-11-03')
    expect(pisoFechaPedido(0, HOY)).toBe(HOY)
  })

  it('cruza meses, años y el 29 de febrero', () => {
    expect(pisoFechaPedido(7, '2026-03-03')).toBe('2026-02-24')
    expect(pisoFechaPedido(7, '2027-01-02')).toBe('2026-12-26')
    expect(pisoFechaPedido(1, '2028-03-01')).toBe('2028-02-29')
  })

  it('sin política, o con un valor que no es un entero >= 0, rige el default de 7', () => {
    expect(DIAS_ATRAS_FECHA_PEDIDO_POR_DEFECTO).toBe(7)
    for (const v of [undefined, null, -1, 2.5, Number.NaN]) {
      expect(diasAtrasVigentes(v)).toBe(7)
      expect(pisoFechaPedido(v, HOY)).toBe('2026-11-03')
    }
  })
})

describe('fechaPedidoFueraDeRango', () => {
  it('hoy y el piso exacto entran', () => {
    expect(fechaPedidoFueraDeRango(HOY, 7, HOY)).toBeNull()
    expect(fechaPedidoFueraDeRango('2026-11-03', 7, HOY)).toBeNull()
  })

  it('un día antes del piso no entra, y dice cuál es el piso', () => {
    expect(fechaPedidoFueraDeRango('2026-11-02', 7, HOY))
      .toEqual({ tipo: 'anterior', piso: '2026-11-03', dias: 7 })
  })

  it('mañana no entra (el techo es hoy)', () => {
    expect(fechaPedidoFueraDeRango('2026-11-11', 7, HOY)).toEqual({ tipo: 'futura' })
  })

  it('con 0 días sólo entra hoy', () => {
    expect(fechaPedidoFueraDeRango(HOY, 0, HOY)).toBeNull()
    expect(fechaPedidoFueraDeRango('2026-11-09', 0, HOY))
      .toEqual({ tipo: 'anterior', piso: HOY, dias: 0 })
  })

  it('una fecha vacía no se juzga: el alta usa la de hoy', () => {
    expect(fechaPedidoFueraDeRango('', 7, HOY)).toBeNull()
    expect(fechaPedidoFueraDeRango(undefined, 7, HOY)).toBeNull()
  })

  it('acepta un timestamp: mira sólo el día', () => {
    expect(fechaPedidoFueraDeRango('2026-11-02T12:00:00Z', 7, HOY))
      .toEqual({ tipo: 'anterior', piso: '2026-11-03', dias: 7 })
  })
})

describe('mensajeFechaAnteriorAlPiso', () => {
  it('nombra el piso en DD/MM/YYYY y los días', () => {
    expect(mensajeFechaAnteriorAlPiso('2026-11-03', 7)).toBe(
      'La fecha del pedido no puede ser anterior al 03/11/2026: hasta 7 días atrás. Si el pedido es de antes, lo carga un admin.',
    )
    expect(mensajeFechaAnteriorAlPiso('2026-11-09', 1)).toMatch(/hasta 1 día atrás/)
  })

  it('con 0 días dice que sólo entra hoy', () => {
    expect(mensajeFechaAnteriorAlPiso(HOY, 0)).toMatch(/no puede ser anterior a hoy/)
  })
})
