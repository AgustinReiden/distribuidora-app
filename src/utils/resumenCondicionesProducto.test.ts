import { describe, it, expect } from 'vitest'
import { resumenCondicionesPorProducto } from './resumenCondicionesProducto'
import type { GrupoPrecioConDetalles } from '../types'

/** Condición mínima, con los defaults que trae la DB. */
function grupo(over: Partial<GrupoPrecioConDetalles> = {}): GrupoPrecioConDetalles {
  return {
    id: 'g1',
    nombre: 'Fideos Cotella 500g',
    descripcion: null,
    activo: true,
    productos: [
      { id: 'gp1', grupo_precio_id: 'g1', producto_id: 'p1' },
      { id: 'gp2', grupo_precio_id: 'g1', producto_id: 'p2' },
    ],
    escalas: [
      { id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 12, precio_unitario: 850 },
    ],
    ...over,
  } as GrupoPrecioConDetalles
}

describe('resumenCondicionesPorProducto', () => {
  it('expone el precio y la cantidad de la escala para cada producto', () => {
    const mapa = resumenCondicionesPorProducto([grupo()])
    expect(mapa.get('p1')).toEqual({
      cantidadCondiciones: 1,
      precioDesde: 850,
      cantidadDesde: 12,
    })
    expect(mapa.get('p2')?.precioDesde).toBe(850)
  })

  it('no incluye productos que no están en ninguna condición', () => {
    expect(resumenCondicionesPorProducto([grupo()]).has('p9')).toBe(false)
  })

  it('ignora las condiciones desactivadas: no aplican precio', () => {
    expect(resumenCondicionesPorProducto([grupo({ activo: false })].map(g => g)).size).toBe(0)
  })

  it('ignora las escalas desactivadas', () => {
    const g = grupo({
      escalas: [
        { id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 12, precio_unitario: 850, activo: false },
      ],
    } as Partial<GrupoPrecioConDetalles>)
    expect(resumenCondicionesPorProducto([g]).size).toBe(0)
  })

  it('una condición sin escalas no aparece', () => {
    const g = grupo({ escalas: [] } as Partial<GrupoPrecioConDetalles>)
    expect(resumenCondicionesPorProducto([g]).size).toBe(0)
  })

  it('con varias escalas toma la más barata y su cantidad', () => {
    const g = grupo({
      escalas: [
        { id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 6, precio_unitario: 890 },
        { id: 'e2', grupo_precio_id: 'g1', cantidad_minima: 12, precio_unitario: 850 },
      ],
    } as Partial<GrupoPrecioConDetalles>)
    expect(resumenCondicionesPorProducto([g]).get('p1')).toEqual({
      cantidadCondiciones: 1,
      precioDesde: 850,
      cantidadDesde: 12,
    })
  })

  it('un producto en dos condiciones toma el precio más bajo y cuenta las dos', () => {
    // El caso "½ fardo + fardo" que hay en prod, antes de consolidarlas.
    const medio = grupo({ id: 'g1', nombre: 'CODITO 1/2 FARDO' })
    const entero = grupo({
      id: 'g2',
      nombre: 'FIDEO X FARDO',
      productos: [{ id: 'gp3', grupo_precio_id: 'g2', producto_id: 'p1' }],
      escalas: [{ id: 'e2', grupo_precio_id: 'g2', cantidad_minima: 24, precio_unitario: 800 }],
    } as Partial<GrupoPrecioConDetalles>)

    expect(resumenCondicionesPorProducto([medio, entero]).get('p1')).toEqual({
      cantidadCondiciones: 2,
      precioDesde: 800,
      cantidadDesde: 24,
    })
  })

  it('el precio propio del producto gana sobre el de la escala', () => {
    const g = grupo({
      escalaMinimos: {
        e1: [
          {
            escala_id: 'e1',
            producto_id: 'p1',
            cantidad_minima_por_item: 1,
            precio_unitario_override: 700,
            sucursal_id: '1',
          },
        ],
      },
    } as Partial<GrupoPrecioConDetalles>)
    expect(resumenCondicionesPorProducto([g]).get('p1')?.precioDesde).toBe(700)
    // El resto del grupo sigue con el precio de la escala.
    expect(resumenCondicionesPorProducto([g]).get('p2')?.precioDesde).toBe(850)
  })

  it('un override en 0 no pisa el precio de la escala', () => {
    const g = grupo({
      escalaMinimos: {
        e1: [
          {
            escala_id: 'e1',
            producto_id: 'p1',
            cantidad_minima_por_item: 1,
            precio_unitario_override: 0,
            sucursal_id: '1',
          },
        ],
      },
    } as Partial<GrupoPrecioConDetalles>)
    expect(resumenCondicionesPorProducto([g]).get('p1')?.precioDesde).toBe(850)
  })

  it('sin condiciones devuelve un mapa vacío', () => {
    expect(resumenCondicionesPorProducto([]).size).toBe(0)
  })
})
