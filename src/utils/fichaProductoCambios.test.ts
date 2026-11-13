import { describe, it, expect } from 'vitest'
import { camposSinCambios, soloLoCambiado } from './fichaProductoCambios'

// El formulario como lo arma la ficha al abrir un producto (números del producto,
// strings de lo tipeado).
const abierta = {
  id: '7', nombre: 'Coca 2L', codigo: 'C2', categoria: 'Bebidas', subcategoria_id: 's1', marca_id: '', proveedor_id: 'pv1',
  stock: 10, stock_minimo: 10, cantidad_minima_venta: undefined, porcentaje_iva: 21, condicion_iva: 'gravado',
  costo_sin_iva: 800, costo_con_iva: 968, impuestos_internos: '', ii_encuadre_id: '', precio_sin_iva: 1000, precio: 1210,
  unidades_de_venta_por_fardo: undefined, etiqueta_bulto: undefined, unidades_por_bulto: 6,
}

describe('soloLoCambiado (#1561, FRG-5)', () => {
  it('cambiar el subrubro no manda el precio ni los costos: no pisa lo que cambió una compra mientras tanto', () => {
    const guardada = { ...abierta, subcategoria_id: 's2' }
    const r = soloLoCambiado({ ...guardada }, abierta, guardada)
    expect(r.subcategoria_id).toBe('s2')
    expect(r.categoria).toBe('Bebidas') // viaja con el subrubro
    for (const c of ['precio', 'precio_sin_iva', 'costo_sin_iva', 'costo_con_iva', 'impuestos_internos', 'nombre', 'codigo', 'porcentaje_iva', 'condicion_iva']) {
      expect(r[c as keyof typeof r]).toBeUndefined()
    }
    expect(r.id).toBe('7')
  })

  it('un número tipeado igual al que estaba no cuenta como cambio', () => {
    const guardada = { ...abierta, precio: '1210.00', precio_sin_iva: '1000.00', stock_minimo: '10' }
    expect(camposSinCambios(abierta, guardada)).toEqual(expect.arrayContaining(['precio', 'precio_sin_iva', 'stock_minimo']))
  })

  it('cambiar el precio manda el precio y su neto, y no los costos', () => {
    const guardada = { ...abierta, precio: '1331.00', precio_sin_iva: '1100.00' }
    const r = soloLoCambiado({ ...guardada }, abierta, guardada)
    expect(r.precio).toBe('1331.00')
    expect(r.precio_sin_iva).toBe('1100.00')
    expect(r.costo_sin_iva).toBeUndefined()
    expect(r.costo_con_iva).toBeUndefined()
  })

  it('cambiar el costo manda los cuatro campos de costo, y no el precio', () => {
    const guardada = { ...abierta, costo_sin_iva: '900', costo_con_iva: '1089.00' }
    const r = soloLoCambiado({ ...guardada }, abierta, guardada)
    expect(r.costo_sin_iva).toBe('900')
    expect(r.costo_con_iva).toBe('1089.00')
    expect(r.impuestos_internos).toBe('')
    expect(r.ii_encuadre_id).toBe('')
    expect(r.precio).toBeUndefined()
  })

  it('cambiar el IVA manda la condición, la alícuota, el precio y los costos', () => {
    const guardada = { ...abierta, porcentaje_iva: 10.5, precio_sin_iva: '1095.02', costo_con_iva: '884.00' }
    const r = soloLoCambiado({ ...guardada }, abierta, guardada)
    for (const c of ['porcentaje_iva', 'condicion_iva', 'precio', 'precio_sin_iva', 'costo_sin_iva', 'costo_con_iva']) {
      expect(r[c as keyof typeof r]).not.toBeUndefined()
    }
  })

  it('un rubro, subrubro o marca tipeados como nuevos viajan aunque el select no cambie', () => {
    expect(camposSinCambios(abierta, abierta, { categoriaNueva: true })).not.toContain('categoria')
    expect(camposSinCambios(abierta, abierta, { subrubroNuevo: true })).not.toContain('subcategoria_id')
    expect(camposSinCambios(abierta, abierta, { marcaNueva: true })).not.toContain('marca_id')
  })

  it('sin cambios no manda nada más que el id', () => {
    const r = soloLoCambiado({ ...abierta }, abierta, abierta)
    const definidos = Object.entries(r).filter(([, v]) => v !== undefined).map(([k]) => k)
    expect(definidos.sort()).toEqual(['id', 'stock'])
  })
})
