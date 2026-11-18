/**
 * 1600-b8 (D58 de #1600): los pedidos sin sincronizar de otra sucursal se avisan,
 * con cuántos son, y se ofrece el cambio. H5 de la revisión de B12a: pendientes y
 * fallidos van aparte, y a una sucursal inactiva o ajena no se le ofrece el cambio.
 * Los datos son inventados.
 */
import { describe, it, expect } from 'vitest'
import { avisosColaOtraSucursal, firmaColaOtraSucursal, mensajeQuedasteEnSucursal } from './colaOtraSucursal'

const sucursales = [
  { id: 1, nombre: 'Sucursal Norte' },
  { id: 2, nombre: 'Sucursal Sur' },
]

describe('avisosColaOtraSucursal (D58)', () => {
  it('pendientes: dice cuántos son, en qué sucursal, y que se mandan sólo desde ahí', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 2, pendientes: 3, fallidos: 0 }], sucursales)
    expect(aviso).toMatchObject({ sucursalId: 2, nombre: 'Sucursal Sur', puedeCambiar: true })
    expect(aviso.lineas).toEqual([
      'Tenés 3 pedidos sin mandar guardados en Sucursal Sur. Se mandan sólo desde esa sucursal: ' +
      'cambiá a Sucursal Sur para mandarlos.',
    ])
  })

  it('en singular con uno solo', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 2, pendientes: 1, fallidos: 0 }], sucursales)
    expect(aviso.lineas).toEqual([
      'Tenés 1 pedido sin mandar guardado en Sucursal Sur. Se manda sólo desde esa sucursal: ' +
      'cambiá a Sucursal Sur para mandarlo.',
    ])
  })

  it('H5: los fallidos van aparte: hay que revisarlos, no se mandan solos al cambiar', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 2, pendientes: 1, fallidos: 2 }], sucursales)
    expect(aviso.lineas).toHaveLength(2)
    expect(aviso.lineas[1]).toBe(
      '2 pedidos de Sucursal Sur tienen error: hay que revisarlos (reintentar o eliminar) desde esa sucursal.',
    )
    const [soloFallido] = avisosColaOtraSucursal([{ sucursalId: 2, pendientes: 0, fallidos: 1 }], sucursales)
    expect(soloFallido.lineas).toEqual([
      '1 pedido de Sucursal Sur tiene error: hay que revisarlo (reintentar o eliminar) desde esa sucursal.',
    ])
    expect(soloFallido.lineas.join(' ')).not.toMatch(/para mandar/)
  })

  it('una sucursal que ya no tiene asignada: sin cambio posible, que avise al administrador', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 9, pendientes: 2, fallidos: 0 }], sucursales)
    expect(aviso.puedeCambiar).toBe(false)
    expect(aviso.lineas.join(' ')).toMatch(/ya no tenés acceso.*administrador/)
  })

  it('H5: una sucursal inactiva no ofrece el cambio, aunque esté en la lista del usuario', () => {
    const activas = new Set([1])
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 2, pendientes: 1, fallidos: 0 }], sucursales, activas)
    expect(aviso.puedeCambiar).toBe(false)
    expect(aviso.lineas.join(' ')).toMatch(/Sucursal Sur.*Avisale al administrador/)
  })

  it('una sucursal cuyo cambio se rechazó tampoco lo vuelve a ofrecer', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 2, pendientes: 1, fallidos: 0 }], sucursales, null, new Set([2]))
    expect(aviso.puedeCambiar).toBe(false)
  })

  it('sin la lista de activas (sin señal) vale la del usuario', () => {
    const [aviso] = avisosColaOtraSucursal([{ sucursalId: 2, pendientes: 1, fallidos: 0 }], sucursales, null)
    expect(aviso.puedeCambiar).toBe(true)
  })

  it('un aviso por sucursal, y nada si no hay ninguno', () => {
    expect(avisosColaOtraSucursal([
      { sucursalId: 1, pendientes: 1, fallidos: 0 },
      { sucursalId: 2, pendientes: 4, fallidos: 0 },
    ], sucursales)).toHaveLength(2)
    expect(avisosColaOtraSucursal([], sucursales)).toEqual([])
    expect(avisosColaOtraSucursal([{ sucursalId: 2, pendientes: 0, fallidos: 0 }], sucursales)).toEqual([])
  })

  it('la firma cambia si cambia la cuenta (un aviso cerrado vuelve a aparecer)', () => {
    const a = firmaColaOtraSucursal([{ sucursalId: 2, pendientes: 1, fallidos: 0 }])
    expect(firmaColaOtraSucursal([{ sucursalId: 2, pendientes: 1, fallidos: 0 }])).toBe(a)
    expect(firmaColaOtraSucursal([{ sucursalId: 2, pendientes: 2, fallidos: 0 }])).not.toBe(a)
  })

  it('después de cambiar, dice que la app se queda en esa sucursal', () => {
    expect(mensajeQuedasteEnSucursal('Sucursal Sur')).toMatch(/Ahora estás trabajando en Sucursal Sur.*se queda en esta sucursal/)
  })
})
