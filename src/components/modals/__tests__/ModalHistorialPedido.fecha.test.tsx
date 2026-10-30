import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import ModalHistorialPedido, { type HistorialCambio } from '../ModalHistorialPedido'
import type { PedidoDB } from '../../../types'

const pedido = { id: 1234 } as unknown as PedidoDB

// #1319: registrar_cambio_pedido anota el cambio de la fecha del pedido como
// 'YYYY-MM-DD' -> 'YYYY-MM-DD'. Es el dato que mueve la venta y la comisión de mes.
describe('ModalHistorialPedido: fecha del pedido (#1319)', () => {
  it('muestra el campo con su nombre y las fechas en dd/mm/aaaa, sin correrlas un día', () => {
    render(
      <ModalHistorialPedido
        pedido={pedido}
        historial={[
          { campo_modificado: 'fecha', valor_anterior: '2026-10-31', valor_nuevo: '2026-11-01', usuario: { nombre: 'Ana' } },
        ] as HistorialCambio[]}
        loading={false}
        onClose={vi.fn()}
      />
    )
    expect(screen.getByText('Fecha del pedido')).toBeInTheDocument()
    expect(document.body.textContent).toContain('31/10/2026')
    expect(document.body.textContent).toContain('01/11/2026')
    expect(document.body.textContent).not.toContain('2026-10-31')
  })
})
