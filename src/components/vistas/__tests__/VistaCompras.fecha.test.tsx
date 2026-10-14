/**
 * La fecha de la compra se muestra tal cual se cargó.
 *
 * `fecha_compra` es DATE y llega como 'YYYY-MM-DD'. `new Date('2026-10-14')` la
 * toma como medianoche UTC, que en Argentina (UTC-3) es el 13 a las 21: la lista
 * mostraba el día anterior. En CI (UTC) no se ve, por eso el test fija la zona.
 */
import process from 'node:process'
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeAll, afterAll } from 'vitest'
import { render, screen } from '@testing-library/react'
import VistaCompras from '../VistaCompras'
import type { CompraDBExtended, ProveedorDBExtended } from '../../../types'

const TZ_ORIGINAL = process.env.TZ
beforeAll(() => { process.env.TZ = 'America/Argentina/Buenos_Aires' })
afterAll(() => {
  if (TZ_ORIGINAL === undefined) delete process.env.TZ
  else process.env.TZ = TZ_ORIGINAL
})

describe('VistaCompras — fecha de compra', () => {
  it('muestra el mismo día que se cargó, en la tabla y en las tarjetas', () => {
    const compra = {
      id: '1',
      proveedor_id: '1',
      proveedor: { id: '1', nombre: 'Proveedor' },
      proveedor_nombre: 'Proveedor',
      numero_factura: 'A-1',
      estado: 'recibida',
      total: 1000,
      fecha_compra: '2026-10-14',
      created_at: '2026-10-14T13:00:00Z',
      items: [],
    } as unknown as CompraDBExtended

    render(
      <VistaCompras
        compras={[compra]}
        proveedores={[] as ProveedorDBExtended[]}
        loading={false}
        isAdmin
        isEncargado={false}
        onNuevaCompra={vi.fn()}
        onVerDetalle={vi.fn()}
        onAnularCompra={vi.fn()}
        ncResumen={[]}
      />
    )

    expect(screen.getAllByText(/14\/10\/2026/).length).toBeGreaterThanOrEqual(2)
    expect(screen.queryByText(/13\/10\/2026/)).not.toBeInTheDocument()
  })
})
