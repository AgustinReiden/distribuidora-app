/**
 * `ModalAnularSalvedad` — el aviso de la merma que se anula.
 *
 * `anular_salvedad` anula la merma que dejó la salvedad: dañado/vencido desde
 * la mig 244, y el faltante de stock desde la 297 (#847), salvo en un regalo,
 * que no movió stock y no dejó merma. El aviso tiene que decir lo mismo que
 * hace el RPC.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import ModalAnularSalvedad from './ModalAnularSalvedad'
import type { SalvedadItemDBExtended } from '../../types'

const salvedad = (extra: Partial<SalvedadItemDBExtended>): SalvedadItemDBExtended => ({
  id: '1',
  pedido_id: '10',
  pedido_item_id: '100',
  producto_id: '5',
  cantidad_original: 10,
  cantidad_afectada: 3,
  cantidad_entregada: 7,
  motivo: 'faltante_stock',
  monto_afectado: 300,
  precio_unitario: 100,
  stock_devuelto: false,
  estado_resolucion: 'pendiente',
  es_bonificacion: false,
  ...extra,
} as unknown as SalvedadItemDBExtended)

const renderModal = (s: SalvedadItemDBExtended) =>
  render(<ModalAnularSalvedad salvedad={s} onAnular={vi.fn()} onClose={vi.fn()} />)

describe('ModalAnularSalvedad — aviso de la merma', () => {
  it.each(['producto_danado', 'producto_vencido', 'faltante_stock'] as const)(
    'con motivo %s avisa que anula la merma',
    motivo => {
      renderModal(salvedad({ motivo }))
      expect(screen.getByText(/anular la merma de 3 u\./)).toBeInTheDocument()
    }
  )

  it('un faltante sobre un regalo no dejó merma: no la anuncia', () => {
    renderModal(salvedad({ motivo: 'faltante_stock', es_bonificacion: true }))
    expect(screen.queryByText(/anular la merma/)).not.toBeInTheDocument()
  })

  it.each(['cliente_rechaza', 'error_pedido', 'diferencia_precio', 'otro'] as const)(
    'con motivo %s no hay merma que anular',
    motivo => {
      renderModal(salvedad({ motivo }))
      expect(screen.queryByText(/anular la merma/)).not.toBeInTheDocument()
    }
  )
})
