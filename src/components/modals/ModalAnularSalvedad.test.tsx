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
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
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

  it.each(['cliente_rechaza', 'error_pedido', 'diferencia_precio', 'otro', 'entregado_otro_cliente'] as const)(
    'con motivo %s no hay merma que anular',
    motivo => {
      renderModal(salvedad({ motivo }))
      expect(screen.queryByText(/anular la merma/)).not.toBeInTheDocument()
    }
  )
})

describe('ModalAnularSalvedad — la línea suma lo suyo (#1140)', () => {
  it('con la línea viva, anuncia que le suma lo afectado (no que vuelve a la cantidad original)', () => {
    renderModal(salvedad({ pedido_item_id: '100', cantidad_original: 10, cantidad_afectada: 3 }))
    expect(screen.getByText(/sumarle 3 u\. a la línea/)).toBeInTheDocument()
    expect(screen.queryByText(/a 10 u\./)).not.toBeInTheDocument()
  })

  it('sin línea (la salvedad la dejó en 0 y se borró), anuncia que devuelve lo suyo al pedido (#1161)', () => {
    renderModal(salvedad({ pedido_item_id: null as unknown as string, cantidad_afectada: 3 }))
    expect(screen.getByText(/devolver 3 u\. al pedido/)).toBeInTheDocument()
    expect(screen.queryByText(/sumarle/)).not.toBeInTheDocument()
  })
})

describe('ModalAnularSalvedad — el cobro que se repone (COB-A, mig 497)', () => {
  it('no dice que el cliente vuelve a pagar: dice que se repone el cobro recortado', () => {
    renderModal(salvedad({ monto_afectado: 300 }))
    expect(screen.queryByText(/el cliente vuelve a pagar/i)).not.toBeInTheDocument()
    expect(screen.getByText(/reponer ese cobro/i)).toBeInTheDocument()
  })

  const anularConRespuesta = async (respuesta: { cobroSinReponer?: number } | void) => {
    const onAnular = vi.fn().mockResolvedValue(respuesta)
    const onClose = vi.fn()
    render(<ModalAnularSalvedad salvedad={salvedad({})} onAnular={onAnular} onClose={onClose} />)
    fireEvent.change(screen.getByPlaceholderText(/se cargó por error/i), { target: { value: 'cargada de más' } })
    fireEvent.click(screen.getByRole('button', { name: /^anular salvedad$/i }))
    await waitFor(() => expect(onAnular).toHaveBeenCalledTimes(1))
    return { onClose }
  }

  it('si el server no pudo reponer parte del cobro, lo avisa y no se cierra solo', async () => {
    const { onClose } = await anularConRespuesta({ cobroSinReponer: 1250 })

    const aviso = await screen.findByRole('alert')
    expect(aviso).toHaveTextContent(/quedó anulada, pero parte del cobro no se pudo reponer/i)
    expect(aviso).toHaveTextContent(/1\.250/)
    expect(onClose).not.toHaveBeenCalled()
    // Ya está anulada: no se ofrece anular de nuevo, sólo cerrar.
    expect(screen.queryByRole('button', { name: /^anular salvedad$/i })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /^entendido$/i }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('si volvió todo el cobro, se cierra sin aviso', async () => {
    const { onClose } = await anularConRespuesta({ cobroSinReponer: 0 })
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('sin respuesta (el caller no la pasa), se cierra como siempre', async () => {
    const { onClose } = await anularConRespuesta(undefined)
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
  })
})
