import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import ProductoUltimaCompra from './ProductoUltimaCompra'
import { compraTestigoEdicion } from '../../test/fixtures/compraTestigoEdicion'

const auth = { isAdminOrEncargado: true }
const query = vi.fn()

vi.mock('../../hooks/supabase/useAuth', () => ({ useAuth: () => auth }))
vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCompraQueFijaCostoQuery: (...args: unknown[]) => query(...args),
}))

describe('ProductoUltimaCompra', () => {
  beforeEach(() => {
    auth.isAdminOrEncargado = true
    query.mockReset().mockReturnValue({ data: compraTestigoEdicion() })
  })

  it('abre el costo de la compra por cargo, con su nombre, hasta el costo final', () => {
    render(<ProductoUltimaCompra productoId="501" costoFinalFicha={1028.6324} />)

    expect(screen.getByText('Neto de factura')).toBeInTheDocument()
    expect(screen.getByText('Flete')).toBeInTheDocument()
    expect(screen.getByText('Pallets')).toBeInTheDocument()
    expect(screen.getByText('Costo final')).toBeInTheDocument()
    expect(screen.getByText(/1\.028,63/)).toBeInTheDocument()
    expect(screen.getByText(/FC A A0005-00012345 · .* · Bebidas Testigo SA/)).toBeInTheDocument()
    expect(screen.queryByText(/se cambió después de esta compra/)).not.toBeInTheDocument()
  })

  it('avisa cuando la ficha tiene otro costo de reposición que el de la compra', () => {
    render(<ProductoUltimaCompra productoId="501" costoFinalFicha={1000} />)
    expect(screen.getByText(/se cambió después de esta compra/)).toBeInTheDocument()
  })

  it('no se muestra a quien no ve costos, ni consulta la compra', () => {
    auth.isAdminOrEncargado = false
    const { container } = render(<ProductoUltimaCompra productoId="501" costoFinalFicha={null} />)
    expect(container).toBeEmptyDOMElement()
    expect(query).toHaveBeenCalledWith('501', false)
  })

  it('sin compra que haya fijado el costo no muestra nada', () => {
    query.mockReturnValue({ data: null })
    const { container } = render(<ProductoUltimaCompra productoId="501" costoFinalFicha={null} />)
    expect(container).toBeEmptyDOMElement()
  })
})
