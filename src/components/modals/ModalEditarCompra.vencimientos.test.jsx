/**
 * Los vencimientos al editar una compra (migs 223/224).
 *
 * Dos fallos mudos, los dos en esta pantalla:
 *
 * 1. Etiquetar más unidades de las que tiene la línea no lo frenaba nadie. El
 *    badge de la línea se pintaba de rojo y el guardado seguía: del lado del
 *    servidor `sincronizar_lotes_compra` sólo clampea contra el stock TOTAL del
 *    producto, así que no ve la línea y el sobrante entraba a un lote que la
 *    factura no trajo.
 *
 * 2. `itemsModificados` no comparaba vencimientos, así que "Cambiar proveedor"
 *    quedaba habilitado con vencimientos tipeados y los descartaba — ese flujo
 *    clona los items DE LA BD, que todavía no los tienen.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../utils/formatters', () => ({
  formatPrecio: (value) => `$${Number(value).toFixed(2)}`,
}))

import ModalEditarCompra from './ModalEditarCompra'

const compraBase = (overrides = {}) => ({
  id: 700,
  estado: 'recibida',
  tipo_factura: 'FC',
  proveedor: { id: 6, nombre: 'Manaos' },
  numero_factura: 'A0007-1',
  fecha_compra: '2026-09-01',
  total: 1210,
  otros_impuestos: 0,
  percepcion_iva: 0,
  percepcion_iibb: 0,
  no_gravado: 0,
  items: [
    {
      id: 81, producto_id: 1, cantidad: 10, costo_unitario: 100, bonificacion: 0,
      porcentaje_iva: 21, condicion_iva: 'gravado', impuestos_internos: 0,
      producto: { nombre: 'Lima Limon 600' },
    },
  ],
  cargos: [],
  ...overrides,
})

const props = (compra, onGuardar = vi.fn().mockResolvedValue(undefined), extra = {}) => ({
  compra, usuarioId: 'u1', onGuardar, onClose: vi.fn(), guardando: false, ...extra,
})

const guardar = (user) => user.click(screen.getByRole('button', { name: /guardar/i }))

/** Los lotes que ya tiene la compra, como los trae el container. */
const lotes = (cantidad) => [
  { producto_id: 1, fecha_vencimiento: '2026-12-01', cantidad },
]

describe('ModalEditarCompra · vencimientos que exceden la línea', () => {
  it('bloquea el guardado y dice cuánto sobra', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockResolvedValue(undefined)
    // 12 u. etiquetadas contra una línea de 10: se llega bajando la cantidad en
    // una edición anterior, o cuando el mismo producto está en dos renglones.
    render(<ModalEditarCompra {...props(compraBase(), onGuardar, { lotesIniciales: lotes(12) })} />)

    await guardar(user)

    expect(onGuardar).not.toHaveBeenCalled()
    expect(screen.getByText(/Lima Limon 600.*etiquetaste 12 u\..*la línea tiene 10/)).toBeInTheDocument()
  })

  it('lo que no excede se guarda, y los vencimientos viajan en el payload', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarCompra {...props(compraBase(), onGuardar, { lotesIniciales: lotes(10) })} />)

    await guardar(user)

    expect(onGuardar).toHaveBeenCalledTimes(1)
    expect(onGuardar.mock.calls[0][0].items[0].vencimientos).toEqual([
      { fecha: '2026-12-01', cantidad: 10 },
    ])
  })

  it('etiquetar menos que la línea es legal: el resto queda sin vencimiento', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarCompra {...props(compraBase(), onGuardar, { lotesIniciales: lotes(4) })} />)

    await guardar(user)

    expect(onGuardar).toHaveBeenCalledTimes(1)
  })
})

describe('ModalEditarCompra · "Cambiar proveedor" ve los vencimientos', () => {
  const admin = { canCambiarProveedor: true, onCambiarProveedor: vi.fn() }

  it('sigue habilitado cuando la precarga no cambió nada', () => {
    render(<ModalEditarCompra {...props(compraBase(), undefined, { ...admin, lotesIniciales: lotes(10) })} />)
    // Precargar los lotes de la compra NO es una edición del usuario.
    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeEnabled()
  })

  it('se deshabilita al tocar un vencimiento', async () => {
    const user = userEvent.setup()
    render(<ModalEditarCompra {...props(compraBase(), undefined, { ...admin, lotesIniciales: lotes(10) })} />)
    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeEnabled()

    // Quitar el vencimiento precargado: hay dos layouts en el DOM, se toma el
    // primero (la tarjeta).
    await user.click(screen.getAllByRole('button', { name: /Vence 01\/12\/2026/ })[0])
    await user.click(screen.getAllByRole('button', { name: /Quitar el vencimiento 1/i })[0])

    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeDisabled()
  })

  it('y al agregar uno donde no había', async () => {
    const user = userEvent.setup()
    render(<ModalEditarCompra {...props(compraBase(), undefined, { ...admin, lotesIniciales: [] })} />)
    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeEnabled()

    await user.click(screen.getAllByRole('button', { name: /Sin vencimiento/i })[0])

    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeDisabled()
  })
})
