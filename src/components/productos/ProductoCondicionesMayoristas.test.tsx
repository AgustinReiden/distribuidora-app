import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { CondicionMayoristaProducto } from '../../utils/condicionesMayoristas'

const mutateAsync = vi.fn(() => Promise.resolve())
let condiciones: CondicionMayoristaProducto[] = []

vi.mock('../../hooks/queries', () => ({
  useProductosQuery: () => ({ data: [{ id: 'p1', nombre: 'Fideo Mostachol' }], isLoading: false }),
  useGruposPrecioPorProductoQuery: () => ({ condiciones, isLoading: false, error: null }),
  useActualizarPrecioEscalaMutation: () => ({ mutateAsync, isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

import ProductoCondicionesMayoristas from './ProductoCondicionesMayoristas'

function condicion(over: Partial<CondicionMayoristaProducto> = {}): CondicionMayoristaProducto {
  return {
    grupoId: 'g1',
    grupoNombre: 'Fideos por bulto',
    descripcion: null,
    activo: true,
    cantidadProductos: 3,
    moq: null,
    escalas: [
      {
        escalaId: 'e1',
        cantidadMinima: 12,
        precioGrupo: 800,
        precioOverride: null,
        precioEfectivo: 800,
        esOverride: false,
        activo: true,
        escala: {
          cantidadMinima: 12,
          precioUnitario: 800,
          etiqueta: null,
          minProductosDistintos: 1,
          minimosPorProducto: new Map(),
        },
      },
    ],
    ...over,
  }
}

// Producto de $1000 final, IVA 21, costo total $600, costo real $500.
const props = {
  productoId: 'p1',
  precioLista: 1000,
  costoTotal: 600,
  costoReal: 500,
  porcentajeIva: 21,
}

describe('ProductoCondicionesMayoristas', () => {
  it('avisa cuando el producto no está en ninguna condición', () => {
    condiciones = []
    render(<ProductoCondicionesMayoristas {...props} />)
    expect(screen.getByText(/no está en ninguna condición mayorista/i)).toBeInTheDocument()
  })

  it('muestra la regla, el precio y los dos márgenes de la escala', () => {
    condiciones = [condicion()]
    render(<ProductoCondicionesMayoristas {...props} />)

    expect(screen.getByText('Fideos por bulto')).toBeInTheDocument()
    expect(screen.getByText(/12\+ unidades/)).toBeInTheDocument()
    // Bruto: 800 vs costo total 600 → 33.3%
    expect(screen.getByText(/Bruto 33\.3%/)).toBeInTheDocument()
    // Neto: 800/1.21 = 661.16 vs costo real 500 → 32.2%
    expect(screen.getByText(/Neto 32\.2%/)).toBeInTheDocument()
    // 800 sobre una lista de 1000
    expect(screen.getByText(/20\.0% bajo lista/)).toBeInTheDocument()
  })

  it('sin permiso de edición el precio no es editable', () => {
    condiciones = [condicion()]
    render(<ProductoCondicionesMayoristas {...props} puedeEditar={false} />)
    expect(screen.getByRole('button', { name: /\$/ })).toBeDisabled()
  })

  it('al editar un precio de escala compartida avisa que afecta a todo el grupo', async () => {
    condiciones = [condicion()]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /\$/ }))
    expect(screen.getByText(/Afecta a los 3 productos del grupo/i)).toBeInTheDocument()
  })

  it('un precio propio del producto no muestra la advertencia de grupo', async () => {
    condiciones = [condicion({
      escalas: [{ ...condicion().escalas[0], precioOverride: 750, precioEfectivo: 750, esOverride: true }],
    })]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    expect(screen.getByText('precio propio')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /\$/ }))
    expect(screen.queryByText(/Afecta a los/i)).not.toBeInTheDocument()
  })

  it('el margen se recalcula con lo tipeado, antes de guardar', async () => {
    condiciones = [condicion()]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /\$/ }))
    const input = screen.getByRole('textbox')
    await user.clear(input)
    await user.type(input, '900')

    // 900 vs costo total 600 → 50%
    expect(screen.getByText(/Bruto 50\.0%/)).toBeInTheDocument()
    expect(screen.getByText(/10\.0% bajo lista/)).toBeInTheDocument()
  })
})
