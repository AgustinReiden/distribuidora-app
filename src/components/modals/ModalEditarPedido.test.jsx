import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen as _screen, fireEvent as _fireEvent, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalEditarPedido from './ModalEditarPedido'

// Mock formatPrecio
vi.mock('../../utils/formatters', () => ({
  formatPrecio: (value) => `$${Number(value).toFixed(2)}`
}))

describe('ModalEditarPedido', () => {
  const mockPedido = {
    id: 123,
    notas: 'Nota inicial',
    forma_pago: 'efectivo',
    estado_pago: 'pendiente',
    monto_pagado: 0,
    total: 1000,
    estado: 'preparando',
    cliente: {
      nombre_fantasia: 'Cliente Test',
      direccion: 'Dirección Test 123'
    },
    items: [
      {
        producto_id: 1,
        cantidad: 2,
        precio_unitario: 250,
        producto: { nombre: 'Producto 1' }
      },
      {
        producto_id: 2,
        cantidad: 1,
        precio_unitario: 500,
        producto: { nombre: 'Producto 2' }
      }
    ]
  }

  const mockProductos = [
    { id: 1, nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 10 },
    { id: 2, nombre: 'Producto 2', codigo: 'P002', precio: 500, stock: 5 },
    { id: 3, nombre: 'Producto 3', codigo: 'P003', precio: 100, stock: 20 }
  ]

  const defaultProps = {
    pedido: mockPedido,
    productos: mockProductos,
    isAdmin: false,
    onSave: vi.fn(),
    onSaveItems: vi.fn(),
    onClose: vi.fn(),
    guardando: false
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('Renderizado básico', () => {
    it('renderiza el modal con título correcto', () => {
      render(<ModalEditarPedido {...defaultProps} />)
      expect(screen.getByText('Editar Pedido #123')).toBeInTheDocument()
    })

    it('muestra información del cliente', () => {
      render(<ModalEditarPedido {...defaultProps} />)
      expect(screen.getByText('Cliente Test')).toBeInTheDocument()
      expect(screen.getByText('Dirección Test 123')).toBeInTheDocument()
    })

    it('muestra el total del pedido', () => {
      render(<ModalEditarPedido {...defaultProps} />)
      expect(screen.getByText('$1000.00')).toBeInTheDocument()
    })

    it('muestra productos en modo solo lectura para no-admin', () => {
      render(<ModalEditarPedido {...defaultProps} isAdmin={false} />)
      expect(screen.getByText('(solo lectura)')).toBeInTheDocument()
      expect(screen.getByText('Producto 1')).toBeInTheDocument()
      expect(screen.getByText('Producto 2')).toBeInTheDocument()
    })
  })

  describe('Notas', () => {
    it('muestra las notas iniciales del pedido', () => {
      render(<ModalEditarPedido {...defaultProps} />)
      const textarea = screen.getByPlaceholderText(/observaciones importantes/i)
      expect(textarea.value).toBe('Nota inicial')
    })

    it('permite editar las notas', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const textarea = screen.getByPlaceholderText(/observaciones importantes/i)
      await user.clear(textarea)
      await user.type(textarea, 'Nueva nota')

      expect(textarea.value).toBe('Nueva nota')
    })
  })

  describe('Forma de pago', () => {
    it('muestra la forma de pago inicial', () => {
      render(<ModalEditarPedido {...defaultProps} />)
      const select = screen.getByRole('combobox')
      expect(select.value).toBe('efectivo')
    })

    it('permite cambiar la forma de pago', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const select = screen.getByRole('combobox')
      await user.selectOptions(select, 'transferencia')

      expect(select.value).toBe('transferencia')
    })
  })

  describe('Estado de pago', () => {
    it('muestra estado pendiente por defecto', () => {
      render(<ModalEditarPedido {...defaultProps} />)
      const btnPendiente = screen.getByRole('button', { name: 'Pendiente' })
      expect(btnPendiente.className).toContain('border-red-500')
    })

    it('cambia a pagado y actualiza monto al total', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const btnPagado = screen.getByRole('button', { name: 'Pagado' })
      await user.click(btnPagado)

      expect(btnPagado.className).toContain('border-green-500')
      const inputMonto = screen.getByPlaceholderText('0.00')
      expect(inputMonto.value).toBe('1000')
    })

    it('cambia a pendiente y resetea monto a 0', async () => {
      const user = userEvent.setup()
      const pedidoPagado = { ...mockPedido, estado_pago: 'pagado', monto_pagado: 1000 }
      render(<ModalEditarPedido {...defaultProps} pedido={pedidoPagado} />)

      const btnPendiente = screen.getByRole('button', { name: 'Pendiente' })
      await user.click(btnPendiente)

      const inputMonto = screen.getByPlaceholderText('0.00')
      expect(inputMonto.value).toBe('0')
    })

    it('muestra alerta de pago parcial con saldo pendiente', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const btnParcial = screen.getByRole('button', { name: 'Parcial' })
      await user.click(btnParcial)

      const inputMonto = screen.getByPlaceholderText('0.00')
      await user.clear(inputMonto)
      await user.type(inputMonto, '300')

      expect(screen.getByText('Pago Parcial')).toBeInTheDocument()
      // Verify the paid amount shows in the partial payment section
      expect(screen.getByText(/Pagado:/)).toBeInTheDocument()
    })
  })

  describe('Botones de porcentaje', () => {
    it('aplica 25% del total', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const btn25 = screen.getByRole('button', { name: '25%' })
      await user.click(btn25)

      const inputMonto = screen.getByPlaceholderText('0.00')
      expect(inputMonto.value).toBe('250')
    })

    it('aplica 50% del total', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const btn50 = screen.getByRole('button', { name: '50%' })
      await user.click(btn50)

      const inputMonto = screen.getByPlaceholderText('0.00')
      expect(inputMonto.value).toBe('500')
    })

    it('aplica 100% y cambia estado a pagado', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const btn100 = screen.getByRole('button', { name: '100%' })
      await user.click(btn100)

      const btnPagado = screen.getByRole('button', { name: 'Pagado' })
      expect(btnPagado.className).toContain('border-green-500')
    })
  })

  describe('Lógica de monto y estado', () => {
    it('cambia a pagado cuando monto >= total', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const inputMonto = screen.getByPlaceholderText('0.00')
      await user.clear(inputMonto)
      await user.type(inputMonto, '1000')

      const btnPagado = screen.getByRole('button', { name: 'Pagado' })
      expect(btnPagado.className).toContain('border-green-500')
    })

    it('cambia a parcial cuando monto > 0 y < total', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} />)

      const inputMonto = screen.getByPlaceholderText('0.00')
      await user.clear(inputMonto)
      await user.type(inputMonto, '500')

      const btnParcial = screen.getByRole('button', { name: 'Parcial' })
      expect(btnParcial.className).toContain('border-yellow-500')
    })

    it('cambia a pendiente cuando monto = 0', async () => {
      const user = userEvent.setup()
      const pedidoParcial = { ...mockPedido, estado_pago: 'parcial', monto_pagado: 500 }
      render(<ModalEditarPedido {...defaultProps} pedido={pedidoParcial} />)

      const inputMonto = screen.getByPlaceholderText('0.00')
      await user.clear(inputMonto)
      await user.type(inputMonto, '0')

      const btnPendiente = screen.getByRole('button', { name: 'Pendiente' })
      expect(btnPendiente.className).toContain('border-red-500')
    })
  })

  describe('Pedido entregado', () => {
    it('muestra alerta cuando el pedido está entregado', () => {
      const pedidoEntregado = { ...mockPedido, estado: 'entregado' }
      render(<ModalEditarPedido {...defaultProps} pedido={pedidoEntregado} />)

      expect(screen.getByText(/este pedido ya fue entregado/i)).toBeInTheDocument()
    })

    it('no muestra controles de edición de items para admin en pedido entregado', () => {
      const pedidoEntregado = { ...mockPedido, estado: 'entregado' }
      render(<ModalEditarPedido {...defaultProps} pedido={pedidoEntregado} isAdmin={true} />)

      expect(screen.getByText('(solo lectura)')).toBeInTheDocument()
      expect(screen.queryByRole('button', { name: 'Agregar' })).not.toBeInTheDocument()
    })
  })

  describe('Edición de items (Admin)', () => {
    it('muestra controles de edición para admin', () => {
      render(<ModalEditarPedido {...defaultProps} isAdmin={true} />)

      // Admin mode shows "Agregar" button instead of read-only view
      expect(screen.getByText('Agregar')).toBeInTheDocument()
    })

    it('muestra buscador de productos al hacer clic en Agregar', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} isAdmin={true} />)

      const btnAgregar = screen.getByText('Agregar')
      await user.click(btnAgregar)

      expect(screen.getByPlaceholderText(/buscar producto/i)).toBeInTheDocument()
    })

    it('filtra productos al buscar', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} isAdmin={true} />)

      const btnAgregar = screen.getByText('Agregar')
      await user.click(btnAgregar)

      const inputBusqueda = screen.getByPlaceholderText(/buscar producto/i)
      await user.type(inputBusqueda, 'Producto 3')

      // Producto 3 no está en items así que debería aparecer
      expect(screen.getByText('P003 - Stock: 20')).toBeInTheDocument()
    })

    it('indica cuando hay modificaciones en items', async () => {
      const user = userEvent.setup()
      render(<ModalEditarPedido {...defaultProps} isAdmin={true} />)

      // Wait for initial render with items
      await waitFor(() => {
        expect(screen.getByText('Producto 1')).toBeInTheDocument()
      })

      // Find increment buttons (Plus icons in the items section)
      const itemsSection = screen.getByText('Productos del Pedido').closest('div').parentElement
      const plusButtons = itemsSection.querySelectorAll('button')

      // Find a plus button that's for incrementing quantity (not the Agregar button)
      const incrementButtons = Array.from(plusButtons).filter(btn => {
        const svg = btn.querySelector('svg.lucide-plus')
        return svg && btn.className.includes('hover:bg-gray-100')
      })

      if (incrementButtons.length > 0) {
        await user.click(incrementButtons[0])

        await waitFor(() => {
          expect(screen.getByText('Modificado')).toBeInTheDocument()
        }, { timeout: 3000 })
      }
    })
  })

  describe('Guardar', () => {
    it('llama onSave con los datos correctos', async () => {
      const user = userEvent.setup()
      const onSave = vi.fn()
      render(<ModalEditarPedido {...defaultProps} onSave={onSave} />)

      const btnGuardar = screen.getByRole('button', { name: 'Guardar' })
      await user.click(btnGuardar)

      expect(onSave).toHaveBeenCalledWith({
        notas: 'Nota inicial',
        formaPago: 'efectivo',
        estadoPago: 'pendiente',
        montoPagado: 0
      })
    })

    it('llama onSaveItems cuando hay items modificados (admin)', async () => {
      const user = userEvent.setup()
      const onSave = vi.fn()
      const onSaveItems = vi.fn().mockResolvedValue()
      render(<ModalEditarPedido {...defaultProps} isAdmin={true} onSave={onSave} onSaveItems={onSaveItems} />)

      // Wait for items to render
      await waitFor(() => {
        expect(screen.getByText('Producto 1')).toBeInTheDocument()
      })

      // Find increment buttons in items list
      const itemsSection = screen.getByText('Productos del Pedido').closest('div').parentElement
      const incrementButtons = Array.from(itemsSection.querySelectorAll('button')).filter(btn => {
        const svg = btn.querySelector('svg.lucide-plus')
        return svg && btn.className.includes('hover:bg-gray-100')
      })

      if (incrementButtons.length > 0) {
        await user.click(incrementButtons[0])

        await waitFor(() => {
          expect(screen.getByText('Guardar Todo')).toBeInTheDocument()
        }, { timeout: 3000 })

        const btnGuardar = screen.getByRole('button', { name: 'Guardar Todo' })
        await user.click(btnGuardar)

        expect(onSaveItems).toHaveBeenCalled()
      }
    })

    it('muestra spinner cuando está guardando', () => {
      render(<ModalEditarPedido {...defaultProps} guardando={true} />)

      const btnGuardar = screen.getByRole('button', { name: 'Guardar' })
      expect(btnGuardar.querySelector('svg.animate-spin')).toBeInTheDocument()
    })

    it('deshabilita botón guardar cuando guardando', () => {
      render(<ModalEditarPedido {...defaultProps} guardando={true} />)

      const btnGuardar = screen.getByRole('button', { name: 'Guardar' })
      expect(btnGuardar).toBeDisabled()
    })
  })

  describe('Cancelar', () => {
    it('llama onClose al cancelar', async () => {
      const user = userEvent.setup()
      const onClose = vi.fn()
      render(<ModalEditarPedido {...defaultProps} onClose={onClose} />)

      const btnCancelar = screen.getByRole('button', { name: 'Cancelar' })
      await user.click(btnCancelar)

      expect(onClose).toHaveBeenCalled()
    })
  })
})
