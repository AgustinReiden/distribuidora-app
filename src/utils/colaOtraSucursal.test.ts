/**
 * 1600-b8 (D58 de #1600): los pedidos sin sincronizar de otra sucursal se avisan,
 * con cuántos son, y se ofrece el cambio. Los datos son inventados.
 */
import { describe, it, expect } from 'vitest'
import { avisosColaOtraSucursal } from './colaOtraSucursal'

const sucursales = [
  { id: 1, nombre: 'Sucursal Norte' },
  { id: 2, nombre: 'Sucursal Sur' },
]

describe('avisosColaOtraSucursal (D58)', () => {
  it('dice cuántos son, en qué sucursal, y que se mandan sólo desde ahí', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 2, cantidad: 3 }], sucursales)
    expect(aviso).toMatchObject({ sucursalId: 2, cantidad: 3, nombre: 'Sucursal Sur' })
    expect(aviso.texto).toBe(
      'Tenés 3 pedidos sin sincronizar guardados en Sucursal Sur. Se mandan sólo desde esa sucursal: ' +
      'cambiá a Sucursal Sur para mandarlos.',
    )
  })

  it('en singular con uno solo', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 2, cantidad: 1 }], sucursales)
    expect(aviso.texto).toBe(
      'Tenés 1 pedido sin sincronizar guardado en Sucursal Sur. Se manda sólo desde esa sucursal: ' +
      'cambiá a Sucursal Sur para mandarlo.',
    )
  })

  it('una sucursal que ya no tiene asignada: sin cambio posible, que avise al administrador', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 9, cantidad: 2 }], sucursales)
    expect(aviso.nombre).toBeNull()
    expect(aviso.texto).toMatch(/ya no tenés acceso.*administrador/)
  })

  it('un aviso por sucursal, y nada si no hay ninguno', () => {
    expect(avisosColaOtraSucursal([{ sucursalId: 1, cantidad: 1 }, { sucursalId: 2, cantidad: 4 }], sucursales)).toHaveLength(2)
    expect(avisosColaOtraSucursal([], sucursales)).toEqual([])
    expect(avisosColaOtraSucursal([{ sucursalId: 2, cantidad: 0 }], sucursales)).toEqual([])
  })
})
