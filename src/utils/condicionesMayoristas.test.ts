import { describe, it, expect } from 'vitest'
import { condicionesDeProducto } from './condicionesMayoristas'
import type { GrupoPrecioConDetalles } from '../types'

/** Grupo mínimo, con los defaults que trae la DB. */
function grupo(over: Partial<GrupoPrecioConDetalles> = {}): GrupoPrecioConDetalles {
  return {
    id: 'g1',
    nombre: 'Fideos por bulto',
    descripcion: null,
    activo: true,
    productos: [
      { id: 'gp1', grupo_precio_id: 'g1', producto_id: 'p1' },
      { id: 'gp2', grupo_precio_id: 'g1', producto_id: 'p2' },
    ],
    escalas: [
      { id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 12, precio_unitario: 800 },
    ],
    ...over,
  } as GrupoPrecioConDetalles
}

describe('condicionesDeProducto', () => {
  it('deja afuera los grupos que no incluyen al producto', () => {
    expect(condicionesDeProducto([grupo()], 'p9')).toHaveLength(0)
  })

  it('invierte la relación: devuelve el grupo con sus escalas para el producto', () => {
    const [cond] = condicionesDeProducto([grupo()], 'p1')
    expect(cond.grupoNombre).toBe('Fideos por bulto')
    expect(cond.cantidadProductos).toBe(2)
    expect(cond.escalas).toHaveLength(1)
    expect(cond.escalas[0].precioEfectivo).toBe(800)
    expect(cond.escalas[0].esOverride).toBe(false)
  })

  it('el override del producto gana sobre el precio de la escala', () => {
    const g = grupo({
      escalaMinimos: {
        e1: [
          { escala_id: 'e1', producto_id: 'p1', cantidad_minima_por_item: 6, precio_unitario_override: 750, sucursal_id: '1' },
          { escala_id: 'e1', producto_id: 'p2', cantidad_minima_por_item: 6, precio_unitario_override: null, sucursal_id: '1' },
        ],
      },
    })
    const [para1] = condicionesDeProducto([g], 'p1')
    expect(para1.escalas[0].precioEfectivo).toBe(750)
    expect(para1.escalas[0].precioGrupo).toBe(800)
    expect(para1.escalas[0].esOverride).toBe(true)

    // El mismo grupo, visto desde el otro producto, sigue al precio de escala.
    const [para2] = condicionesDeProducto([g], 'p2')
    expect(para2.escalas[0].precioEfectivo).toBe(800)
    expect(para2.escalas[0].esOverride).toBe(false)
  })

  it('un override en 0 o negativo no cuenta como precio propio', () => {
    const g = grupo({
      escalaMinimos: {
        e1: [
          { escala_id: 'e1', producto_id: 'p1', cantidad_minima_por_item: 6, precio_unitario_override: 0, sucursal_id: '1' },
        ],
      },
    })
    const [cond] = condicionesDeProducto([g], 'p1')
    expect(cond.escalas[0].esOverride).toBe(false)
    expect(cond.escalas[0].precioEfectivo).toBe(800)
  })

  it('expone con cuántos productos se comparte la condición', () => {
    // Importa para la ficha: editar el precio de una condición compartida
    // afecta a todos, y cualquier mezcla de ellos suma para llegar al mínimo.
    const g = grupo({
      productos: [
        { id: 'gp1', grupo_precio_id: 'g1', producto_id: 'p1' },
        { id: 'gp2', grupo_precio_id: 'g1', producto_id: 'p2' },
      ],
    } as Partial<GrupoPrecioConDetalles>)
    expect(condicionesDeProducto([g], 'p1')[0].cantidadProductos).toBe(2)
    expect(condicionesDeProducto([g], 'p3')).toHaveLength(0)
  })

  it('ordena las escalas por cantidad mínima ascendente', () => {
    const g = grupo({
      escalas: [
        { id: 'e2', grupo_precio_id: 'g1', cantidad_minima: 24, precio_unitario: 700 },
        { id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 12, precio_unitario: 800 },
      ],
    } as Partial<GrupoPrecioConDetalles>)
    expect(condicionesDeProducto([g], 'p1')[0].escalas.map(e => e.cantidadMinima)).toEqual([12, 24])
  })

  it('incluye grupos y escalas desactivados, marcados', () => {
    const g = grupo({
      activo: false,
      escalas: [
        { id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 12, precio_unitario: 800, activo: false },
      ],
    } as Partial<GrupoPrecioConDetalles>)
    const [cond] = condicionesDeProducto([g], 'p1')
    expect(cond.activo).toBe(false)
    expect(cond.escalas[0].activo).toBe(false)
  })

  it('arma la escala completa para describir la regla, no solo la parte del producto', () => {
    const g = grupo({
      escalas: [
        { id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 12, precio_unitario: 800, min_productos_distintos: 2 },
      ],
      escalaMinimos: {
        e1: [
          { escala_id: 'e1', producto_id: 'p1', cantidad_minima_por_item: 6, sucursal_id: '1' },
          { escala_id: 'e1', producto_id: 'p2', cantidad_minima_por_item: 6, sucursal_id: '1' },
        ],
      },
    } as Partial<GrupoPrecioConDetalles>)
    const escala = condicionesDeProducto([g], 'p1')[0].escalas[0].escala
    expect(escala.minProductosDistintos).toBe(2)
    expect(escala.minimosPorProducto.size).toBe(2)
  })

  it('ordena las condiciones por nombre de grupo', () => {
    const g1 = grupo({ id: 'gz', nombre: 'Zona sur' })
    const g2 = grupo({ id: 'ga', nombre: 'Almacenes' })
    expect(condicionesDeProducto([g1, g2], 'p1').map(c => c.grupoNombre)).toEqual(['Almacenes', 'Zona sur'])
  })
})
