/**
 * El filtro por proveedor encuentra las compras de ese proveedor.
 *
 * Los ids son `bigint` y PostgREST los entrega como NÚMERO, pero el valor de un
 * `<option>` siempre es texto. Comparados con `===` no coincidían nunca: elegir
 * un proveedor mostraba "No se encontraron compras" con compras de
 * ese proveedor en la lista. Los otros tests de la vista armaban las compras
 * con ids de texto, por eso no lo veían: acá van como llegan de la base.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import VistaCompras from '../VistaCompras'
import type { CompraDBExtended, ProveedorDBExtended } from '../../../types'

function compra(id: number, proveedorId: number, proveedor: string, factura: string): CompraDBExtended {
  return {
    id,
    proveedor_id: proveedorId,
    proveedor: { id: proveedorId, nombre: proveedor },
    proveedor_nombre: null,
    numero_factura: factura,
    estado: 'recibida',
    total: 1000,
    fecha_compra: '2026-10-01',
    created_at: '2026-10-01T13:00:00Z',
    items: [],
  } as unknown as CompraDBExtended
}

const proveedores = [
  { id: 1, nombre: 'Bebidas Testigo SA' },
  { id: 7, nombre: 'Alfajores Testigo SRL' },
] as unknown as ProveedorDBExtended[]

function renderVista(compras: CompraDBExtended[]) {
  return render(
    <VistaCompras
      compras={compras}
      proveedores={proveedores}
      loading={false}
      isAdmin
      isEncargado={false}
      onNuevaCompra={vi.fn()}
      onVerDetalle={vi.fn()}
      onAnularCompra={vi.fn()}
      ncResumen={[]}
    />
  )
}

describe('VistaCompras — filtro por proveedor', () => {
  it('con ids numéricos (como llegan de PostgREST) muestra sólo las compras del proveedor elegido', () => {
    renderVista([
      compra(10, 1, 'Bebidas Testigo SA', 'FAC-BEBIDAS-1'),
      compra(11, 7, 'Alfajores Testigo SRL', 'FAC-ALFAJORES-1'),
      compra(12, 1, 'Bebidas Testigo SA', 'FAC-BEBIDAS-2'),
    ])

    fireEvent.change(screen.getByDisplayValue('Todos proveedores'), { target: { value: '1' } })

    expect(screen.getByText('Mostrando 2 de 3 compras')).toBeInTheDocument()
    expect(screen.queryByText('No se encontraron compras con los filtros aplicados')).not.toBeInTheDocument()
    expect(screen.getAllByText('FAC-BEBIDAS-1').length).toBeGreaterThan(0)
    expect(screen.getAllByText('FAC-BEBIDAS-2').length).toBeGreaterThan(0)
    expect(screen.queryByText('FAC-ALFAJORES-1')).not.toBeInTheDocument()
  })

  it('reconoce el proveedor también por el embed cuando la columna no viene', () => {
    const sinColumna = { ...compra(20, 7, 'Alfajores Testigo SRL', 'FAC-EMBED'), proveedor_id: undefined } as unknown as CompraDBExtended
    renderVista([sinColumna, compra(21, 1, 'Bebidas Testigo SA', 'FAC-OTRA')])

    fireEvent.change(screen.getByDisplayValue('Todos proveedores'), { target: { value: '7' } })

    expect(screen.getByText('Mostrando 1 de 2 compras')).toBeInTheDocument()
    expect(screen.getAllByText('FAC-EMBED').length).toBeGreaterThan(0)
    expect(screen.queryByText('FAC-OTRA')).not.toBeInTheDocument()
  })
})
