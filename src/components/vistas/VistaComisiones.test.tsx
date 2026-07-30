import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComisionesResultado } from '../../hooks/queries/useComisionesQuery'

vi.mock('../../utils/formatters', () => ({
  formatPrecio: (v: number) => `$${Number(v).toFixed(2)}`,
  fechaLocalISO: () => '2026-07-27',
}))

import VistaComisiones from './VistaComisiones'

const resultado: ComisionesResultado = {
  desde: '2026-07-01',
  hasta: '2026-07-27',
  comision_default: 2,
  preventistas: [
    {
      id: 'u1',
      nombre: 'Ana',
      email: 'ana@x.com',
      base: 100000,
      // 60000 al 2% (1200) + 40000 al 1% (400) = 1600 → 1.6% efectivo
      comision: 1600,
      items: 10,
      items_sin_desglose: 0,
      base_sin_desglose: 0,
      por_origen: [
        { origen: 'lista', base: 60000, comision: 1200, items: 6 },
        { origen: 'mayorista', base: 40000, comision: 400, items: 4 },
      ],
    },
  ],
  totales: { base: 100000, comision: 1600, items: 10, items_sin_desglose: 0, base_sin_desglose: 0 },
}

const props = {
  loading: false,
  fechaDesde: '2026-07-01',
  fechaHasta: '2026-07-27',
  onFiltrar: vi.fn(),
}

describe('VistaComisiones', () => {
  it('muestra el % efectivo, que es comisión sobre base y no un % tipeado', () => {
    render(<VistaComisiones {...props} resultado={resultado} />)
    // Aparece dos veces: la fila del preventista y el total, que con un solo
    // preventista tienen que coincidir.
    expect(screen.getAllByText('1.60%')).toHaveLength(2)
    expect(screen.getAllByText('$1600.00')).toHaveLength(2)
  })

  it('el desglose por origen se abre y muestra el % de cada uno', async () => {
    const user = userEvent.setup()
    render(<VistaComisiones {...props} resultado={resultado} />)

    expect(screen.queryByText('Descuento por volumen')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /Ana/ }))

    expect(screen.getByText('Precio de lista')).toBeInTheDocument()
    expect(screen.getByText('Descuento por volumen')).toBeInTheDocument()
    // 400 sobre 40000 = 1%
    expect(screen.getByText('1.00%')).toBeInTheDocument()
  })

  it('avisa cuando hay ítems sin desglose, con cuántos y cuánta base', () => {
    render(
      <VistaComisiones
        {...props}
        resultado={{
          ...resultado,
          totales: { ...resultado.totales, items_sin_desglose: 7, base_sin_desglose: 50000 },
        }}
      />,
    )
    expect(screen.getByText(/7 de 10 ítems sin desglose/)).toBeInTheDocument()
    expect(screen.getByText(/\$50000\.00 de base/)).toBeInTheDocument()
  })

  it('no muestra el aviso cuando todos los ítems tienen desglose', () => {
    render(<VistaComisiones {...props} resultado={resultado} />)
    expect(screen.queryByText(/sin desglose/)).not.toBeInTheDocument()
  })

  it('el botón de reglas solo aparece si el container lo habilita', () => {
    const { rerender } = render(<VistaComisiones {...props} resultado={resultado} />)
    expect(screen.queryByRole('button', { name: /Reglas de comisión/ })).not.toBeInTheDocument()

    rerender(<VistaComisiones {...props} resultado={resultado} onAbrirReglas={vi.fn()} />)
    expect(screen.getByRole('button', { name: /Reglas de comisión/ })).toBeInTheDocument()
  })
})
