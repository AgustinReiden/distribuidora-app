/**
 * Los totales de /pedidos dicen qué período cuentan («Noviembre · del 1 al 27»),
 * y el rótulo cambia si se elige otro rango. Sin rótulo no se pinta nada.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'

import PedidoStats from '../PedidoStats'
import type { PedidoStatsSummary } from '../../../hooks/queries'
import { rotuloPeriodo } from '../../../utils/periodoMesEnCurso'

const VACIO: PedidoStatsSummary = {
  pendientes: { count: 0, monto: 0 },
  enPreparacion: { count: 0, monto: 0 },
  enCamino: { count: 0, monto: 0 },
  entregados: { count: 0, monto: 0 },
  impagos: { count: 0, monto: 0 },
  total: { count: 0, monto: 0 },
  aproximado: false,
}

describe('PedidoStats — rótulo del período', () => {
  it('muestra el período del mes en curso', () => {
    render(<PedidoStats summary={VACIO} periodoRotulo={rotuloPeriodo('2026-11-01', null, '2026-11-27')} />)
    expect(screen.getByTestId('periodo-totales')).toHaveTextContent('Noviembre · del 1 al 27')
  })

  it('cambia al elegir otro rango', () => {
    const { rerender } = render(
      <PedidoStats summary={VACIO} periodoRotulo={rotuloPeriodo('2026-11-01', null, '2026-11-27')} />,
    )
    rerender(
      <PedidoStats summary={VACIO} periodoRotulo={rotuloPeriodo('2026-10-28', null, '2026-11-27')} />,
    )
    expect(screen.getByTestId('periodo-totales')).toHaveTextContent('Del 28 de octubre al 27 de noviembre')
  })

  it('sin rótulo no pinta nada', () => {
    render(<PedidoStats summary={VACIO} />)
    expect(screen.queryByTestId('periodo-totales')).not.toBeInTheDocument()
  })
})
