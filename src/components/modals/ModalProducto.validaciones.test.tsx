/**
 * Validaciones de la ficha de producto que la base también hace cumplir con un CHECK:
 * así nadie llega al 23514 crudo (#1561 c7, #1603 ola 2).
 *
 *  - cantidad mínima de venta: de 1 a 99.999.999, o vacío (sin mínimo);
 *  - impuesto interno: de 0 a 9900 (tasa efectiva, 99 % nominal; ya no el 100 de antes);
 *  - nombre: ni vacío ni con espacios solos.
 * Y el campo Subrubro de un producto con el rubro desactivado (CAT-11, resto).
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import ModalProducto, { modalProductoSchema } from './ModalProducto'
import type { ProductoDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  useMarcasQuery: () => ({ data: [] }),
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({ default: () => null }))
vi.mock('../productos/ProductoLotes', () => ({ default: () => null }))
vi.mock('../productos/ProductoMedidas', () => ({ default: () => null }))
vi.mock('../productos/ProductoUltimaCompra', () => ({ default: () => null }))

const base = { nombre: 'Aceite 900ml', stock: 1, precio: 100 }
const mensajes = (datos: Record<string, unknown>) => {
  const r = modalProductoSchema.safeParse({ ...base, ...datos })
  return r.success ? [] : r.error.issues.map(i => `${i.path.join('.')}: ${i.message}`)
}

describe('modalProductoSchema — mínimo de venta', () => {
  it('99.999.999 pasa; 100.000.000 se rechaza con el motivo', () => {
    expect(mensajes({ cantidad_minima_venta: 99999999 })).toEqual([])
    expect(mensajes({ cantidad_minima_venta: 100000000 })).toEqual([
      'cantidad_minima_venta: El mínimo de venta no puede superar las 99.999.999 unidades. Dejalo vacío si no hay mínimo.',
    ])
  })

  it('vacío y 0 siguen siendo «sin mínimo»', () => {
    expect(mensajes({ cantidad_minima_venta: undefined })).toEqual([])
    expect(mensajes({ cantidad_minima_venta: null })).toEqual([])
    expect(mensajes({ cantidad_minima_venta: 0 })).toEqual([])
  })

  it('negativo y decimal se rechazan', () => {
    expect(mensajes({ cantidad_minima_venta: -1 })).not.toEqual([])
    expect(mensajes({ cantidad_minima_venta: 2.5 })).not.toEqual([])
  })
})

describe('modalProductoSchema — impuesto interno', () => {
  it('llega hasta 9900 (99 % nominal), no hasta 100', () => {
    expect(mensajes({ impuestos_internos: 150 })).toEqual([])
    expect(mensajes({ impuestos_internos: 9900 })).toEqual([])
  })

  it('arriba de 9900 se rechaza con el motivo, no con el 23514 de la base', () => {
    expect(mensajes({ impuestos_internos: 9901 })).toEqual([
      'impuestos_internos: El impuesto interno no puede superar el 9900 %',
    ])
  })
})

describe('modalProductoSchema — nombre', () => {
  it.each(['', '   ', ' \t '])('«%s» se rechaza: ni vacío ni espacios solos', (nombre) => {
    expect(mensajes({ nombre })).not.toEqual([])
  })

  it('el nombre sale sin espacios de los costados', () => {
    const r = modalProductoSchema.safeParse({ ...base, nombre: '  Aceite  ' })
    expect(r.success && r.data.nombre).toBe('Aceite')
  })
})

describe('ModalProducto — Subrubro con el rubro desactivado', () => {
  const producto = {
    id: '340', nombre: 'COCA COLA', precio: 100, stock: 1, stock_minimo: 10,
    categoria: 'GASEOSAS', porcentaje_iva: 21, condicion_iva: 'gravado',
  } as unknown as ProductoDB

  it('el rubro desactivado es una fila de Categorías: el campo se puede usar y no dice que falta cargarlo', () => {
    render(
      <ModalProducto
        producto={producto}
        categorias={['AGUAS']}
        subrubros={[]}
        rubrosConFila={['AGUAS']}
        rubrosDesactivados={['GASEOSAS']}
        proveedores={[]}
        onSave={vi.fn()}
        onClose={vi.fn()}
        guardando={false}
        esAdmin
      />,
    )
    expect(screen.getByLabelText('Subrubro')).toBeEnabled()
    expect(screen.queryByText(/todavía no está cargado en Categorías/)).not.toBeInTheDocument()
  })

  it('un rubro que de verdad no es fila (ni activo ni desactivado) sigue avisando', () => {
    render(
      <ModalProducto
        producto={{ ...producto, categoria: 'SUELTO' } as unknown as ProductoDB}
        categorias={['AGUAS']}
        subrubros={[]}
        rubrosConFila={['AGUAS']}
        rubrosDesactivados={['GASEOSAS']}
        proveedores={[]}
        onSave={vi.fn()}
        onClose={vi.fn()}
        guardando={false}
        esAdmin
      />,
    )
    expect(screen.getByText(/todavía no está cargado en Categorías/)).toBeInTheDocument()
  })
})
