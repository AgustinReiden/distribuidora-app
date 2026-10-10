import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import ModalHistorialPedido, { type HistorialCambio } from '../ModalHistorialPedido'
import type { PedidoDB } from '../../../types'

const pedido = { id: 1234 } as unknown as PedidoDB

const PRODUCTOS = [
  { id: 86, nombre: 'Manaos Cola 2.25L' },
  { id: '314', nombre: 'Manaos Limón 3LT' },
  { id: 226, nombre: 'Fardo Naranja' },
]

function renderModal(cambio: HistorialCambio, productos = PRODUCTOS) {
  return render(
    <ModalHistorialPedido pedido={pedido} historial={[cambio]} loading={false} onClose={vi.fn()} productos={productos} />
  )
}

describe('ModalHistorialPedido: cambios de items', () => {
  it('muestra nombres, cantidad antes -> después y la marca de regalo, sin JSON crudo', () => {
    renderModal({
      campo_modificado: 'items',
      valor_anterior:
        '[{"producto_id": 86, "cantidad": 2, "precio_unitario": 8500.00, "es_bonificacion": false}, {"producto_id": 314, "cantidad": 2, "precio_unitario": 0, "es_bonificacion": true, "descripcion_regalo": "2 Botellas Limón"}]',
      valor_nuevo:
        '[{"producto_id": 86, "cantidad": 6, "precio_unitario": 8500, "es_bonificacion": false}, {"producto_id": 314, "cantidad": 2, "precio_unitario": 0, "es_bonificacion": true, "descripcion_regalo": "2 Botellas Limón [Sustituido por: NARANJA]"}, {"producto_id": 226, "cantidad": 1, "precio_unitario": 100, "es_bonificacion": false}]',
    })
    expect(screen.getByText('Manaos Cola 2.25L')).toBeInTheDocument()
    expect(screen.getByText('Manaos Limón 3LT')).toBeInTheDocument()
    expect(screen.getByText('Fardo Naranja')).toBeInTheDocument()
    expect(screen.getByText(/2\s*→\s*6/)).toBeInTheDocument()
    expect(screen.getByText('Regalo')).toBeInTheDocument()
    expect(screen.getByText(/Sustituido por: NARANJA/)).toBeInTheDocument()
    expect(screen.getAllByText(/Agregado/).length).toBeGreaterThan(0)
    expect(document.body.textContent).not.toContain('producto_id')
    expect(document.body.textContent).not.toContain('"cantidad"')
  })

  it('marca lo quitado con texto accesible', () => {
    renderModal({
      campo_modificado: 'items',
      valor_anterior: '[{"producto_id": 86, "cantidad": 2, "precio_unitario": 8500, "es_bonificacion": false}]',
      valor_nuevo: '[]',
    })
    expect(screen.getByText('Manaos Cola 2.25L')).toBeInTheDocument()
    expect(screen.getAllByText(/Quitado/).length).toBeGreaterThan(0)
  })

  it('sin la lista de productos cae a "Producto #id"', () => {
    renderModal(
      {
        campo_modificado: 'items',
        valor_anterior: '[]',
        valor_nuevo: '[{"producto_id": 999, "cantidad": 1, "precio_unitario": 5, "es_bonificacion": false}]',
      },
      []
    )
    expect(screen.getByText('Producto #999')).toBeInTheDocument()
  })

  it('un texto que no es JSON se muestra tal cual, cortando línea', () => {
    renderModal({ campo_modificado: 'items', valor_anterior: 'algo viejo', valor_nuevo: 'algo nuevo' })
    const nuevo = screen.getByText('algo nuevo')
    expect(nuevo).toBeInTheDocument()
    expect(nuevo.className).toContain('break-words')
    expect(nuevo.className).not.toContain('whitespace-nowrap')
  })

  it('los demás campos siguen igual', () => {
    renderModal({ campo_modificado: 'estado', valor_anterior: 'pendiente', valor_nuevo: 'entregado' })
    expect(screen.getByText('Pendiente')).toBeInTheDocument()
    expect(screen.getByText('Entregado')).toBeInTheDocument()
  })

  it("el estado 'anulado' tiene etiqueta, no se ve crudo (#1080)", () => {
    renderModal({ campo_modificado: 'estado', valor_anterior: 'asignado', valor_nuevo: 'anulado' })
    expect(screen.getByText('Anulado')).toBeInTheDocument()
    expect(screen.queryByText('anulado')).not.toBeInTheDocument()
    // Las demás etiquetas no cambian: 'asignado' sigue siendo "En camino".
    expect(screen.getByText('En camino')).toBeInTheDocument()
  })
})
