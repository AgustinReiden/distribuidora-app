import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../utils/formatters', () => ({
  formatPrecio: (value) => `$${Number(value).toFixed(2)}`,
}))

import ModalEditarCompra from './ModalEditarCompra'

// mig 177: la condición de IVA también se edita línea por línea al modificar
// una compra ya registrada, no sólo al cargarla.

const compraBase = (overrides = {}) => ({
  id: 133,
  estado: 'recibida',
  tipo_factura: 'FC',
  proveedor: { id: 6, nombre: 'Proveedor' },
  numero_factura: '0001-1',
  fecha_compra: '2026-07-12',
  total: 1210,
  otros_impuestos: 0,
  percepcion_iva: 0,
  percepcion_iibb: 0,
  no_gravado: 0,
  items: [
    {
      producto_id: 1,
      cantidad: 10,
      costo_unitario: 100,
      bonificacion: 0,
      porcentaje_iva: 21,
      condicion_iva: 'gravado',
      impuestos_internos: 0,
      producto: { nombre: 'Prod 1' },
    },
  ],
  ...overrides,
})

const props = (compra, onGuardar = vi.fn()) => ({
  compra, usuarioId: 'u1', onGuardar, onClose: vi.fn(), guardando: false,
})

/**
 * El <select> de condición de la única línea.
 * Hay DOS en el DOM — tarjeta (mobile) y tabla (desktop) — y CSS decide cuál se
 * ve. En jsdom no hay media queries, así que se toma el primero: alcanza para
 * verificar comportamiento, y `ambosLayouts` cubre que estén los dos.
 */
const selectorIva = () => screen.getAllByRole('combobox')[0]
const ambosLayouts = () => screen.getAllByRole('combobox')

describe('ModalEditarCompra · condición de IVA por línea', () => {
  it('ofrece las cuatro condiciones y arranca en la de la línea', () => {
    render(<ModalEditarCompra {...props(compraBase())} />)
    expect(selectorIva()).toHaveValue('gravado:21')
    const labels = [...selectorIva().options].map(o => o.textContent)
    expect(labels).toEqual(['21%', '10,5%', 'Exento', 'No gravado'])
  })

  // La tabla tiene 600px de columnas fijas dentro de un overflow-x-auto: en un
  // teléfono el IVA quedaba fuera de pantalla y parecía que no existía.
  it('el selector está en los dos layouts, tarjeta y tabla', () => {
    render(<ModalEditarCompra {...props(compraBase())} />)
    const [tarjeta, tabla] = ambosLayouts()
    expect(ambosLayouts()).toHaveLength(2)
    // `closest` en vez de querySelector sobre el container: el modal va en un
    // portal, así que no cuelga del nodo que devuelve render().
    expect(tarjeta.closest('.md\\:hidden')).not.toBeNull()
    expect(tabla.closest('.md\\:block')).not.toBeNull()
  })

  it('editar en un layout se refleja en el otro: es el mismo estado', async () => {
    const user = userEvent.setup()
    render(<ModalEditarCompra {...props(compraBase())} />)
    const [tarjeta, tabla] = ambosLayouts()

    await user.selectOptions(tarjeta, 'exento')

    expect(tarjeta).toHaveValue('exento')
    expect(tabla).toHaveValue('exento')
  })

  it('cambiar a 10,5% recalcula el IVA del resumen', async () => {
    const user = userEvent.setup()
    render(<ModalEditarCompra {...props(compraBase())} />)
    expect(screen.getByText('$210.00')).toBeInTheDocument() // 1000 × 21%

    await user.selectOptions(selectorIva(), 'gravado:10.5')

    expect(screen.getByText('$105.00')).toBeInTheDocument() // 1000 × 10,5%
    expect(screen.queryByText('$210.00')).not.toBeInTheDocument()
  })

  it('pasar a no gravado deja el IVA en cero sin tocar el neto', async () => {
    const user = userEvent.setup()
    render(<ModalEditarCompra {...props(compraBase())} />)

    await user.selectOptions(selectorIva(), 'no_gravado')

    expect(selectorIva()).toHaveValue('no_gravado')
    expect(screen.getByText('$0.00')).toBeInTheDocument() // IVA
    // El neto no se mueve: aparece como subtotal de la línea, subtotal y total.
    expect(screen.getAllByText('$1000.00').length).toBeGreaterThanOrEqual(2)
    expect(screen.queryByText('$210.00')).not.toBeInTheDocument()
  })

  it('el payload que se guarda lleva la condición y la alícuota coherentes', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarCompra {...props(compraBase(), onGuardar)} />)

    await user.selectOptions(selectorIva(), 'exento')
    await user.click(screen.getByRole('button', { name: /guardar/i }))

    expect(onGuardar).toHaveBeenCalledTimes(1)
    const enviado = onGuardar.mock.calls[0][0]
    expect(enviado.items[0]).toMatchObject({ condicionIva: 'exento', porcentajeIva: 0 })
    expect(enviado.iva).toBe(0)
    expect(enviado.subtotal).toBe(1000)
  })

  it('una línea vieja sin snapshot cae a la condición de la ficha del producto', () => {
    const compra = compraBase({
      items: [{
        producto_id: 1, cantidad: 10, costo_unitario: 100, bonificacion: 0,
        producto: { nombre: 'Prod 1', porcentaje_iva: 10.5, condicion_iva: 'gravado' },
      }],
    })
    render(<ModalEditarCompra {...props(compra)} />)
    expect(selectorIva()).toHaveValue('gravado:10.5')
  })

  it('en ZZ no hay condición que elegir: sin factura no se discrimina', () => {
    render(<ModalEditarCompra {...props(compraBase({ tipo_factura: 'ZZ' }))} />)
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
  })
})
