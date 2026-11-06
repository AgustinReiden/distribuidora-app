import { describe, it, expect } from 'vitest'
import { calcularNuevosPrecios, mensajeErrorPreciosMasivo, redondearAMultiploDe10 } from './precios'

describe('redondearAMultiploDe10', () => {
  it('redondea al múltiplo de 10 más cercano', () => {
    expect(redondearAMultiploDe10(104)).toBe(100)
    expect(redondearAMultiploDe10(105)).toBe(110)
    expect(redondearAMultiploDe10(106)).toBe(110)
  })
})

describe('calcularNuevosPrecios', () => {
  it('aplica un aumento y redondea a múltiplo de 10', () => {
    const nuevos = calcularNuevosPrecios(
      { precio_sin_iva: 100, precio: 121, impuestos_internos: 4.1667 },
      10
    )
    expect(nuevos.precio_neto).toBe(110)
    expect(nuevos.precio_final).toBe(130)
  })

  it('aplica una rebaja', () => {
    const nuevos = calcularNuevosPrecios({ precio_sin_iva: 100, precio: 121 }, -10)
    expect(nuevos.precio_neto).toBe(90)
    expect(nuevos.precio_final).toBe(110)
  })

  it('devuelve null cuando el valor base es null o 0, para que el RPC preserve el valor previo', () => {
    const nuevos = calcularNuevosPrecios({ precio_sin_iva: null, precio: 0 }, 10)
    expect(nuevos.precio_neto).toBeNull()
    expect(nuevos.precio_final).toBeNull()
  })

  it('no deja un precio negativo tras una rebaja fuerte, lo lleva a 0', () => {
    const nuevos = calcularNuevosPrecios({ precio_sin_iva: 100, precio: 100 }, -150)
    expect(nuevos.precio_neto).toBe(0)
    expect(nuevos.precio_final).toBe(0)
  })

  it('nunca toca impuestos_internos: siempre devuelve null para que el RPC lo preserve', () => {
    // impuestos_internos es un % sobre el neto (no un precio): escalarlo con el
    // factor de aumento y redondearlo a múltiplo de 10 lo destruye (ver precios.ts).
    const conImpuesto = calcularNuevosPrecios(
      { precio_sin_iva: 100, precio: 121, impuestos_internos: 8.6956 },
      10
    )
    expect(conImpuesto.imp_internos).toBeNull()

    const sinImpuesto = calcularNuevosPrecios({ precio_sin_iva: 100, precio: 121 }, 10)
    expect(sinImpuesto.imp_internos).toBeNull()
  })
})

describe('mensajeErrorPreciosMasivo', () => {
  const ajeno = (id: number) => `Producto ID ${id} no encontrado en la sucursal activa`

  it('un solo error y nada actualizado: el error tal cual', () => {
    expect(mensajeErrorPreciosMasivo({ actualizados: 0, errores: [ajeno(7)] })).toBe(ajeno(7))
  })

  it('el rechazo por rol llega entero', () => {
    const noAutorizado = 'No autorizado: Solo administradores pueden actualizar precios'
    expect(mensajeErrorPreciosMasivo({ actualizados: 0, errores: [noAutorizado] })).toBe(noAutorizado)
  })

  it('con algunos actualizados, dice cuántos quedaron guardados y cuántos no', () => {
    expect(mensajeErrorPreciosMasivo({ actualizados: 2, errores: [ajeno(7)] })).toBe(
      `Se actualizaron 2 producto(s), pero 1 no: ${ajeno(7)}`
    )
  })

  it('nombra los tres primeros y cuenta el resto', () => {
    const errores = [1, 2, 3, 4, 5].map(ajeno)
    expect(mensajeErrorPreciosMasivo({ actualizados: 0, errores })).toBe(
      `${ajeno(1)}; ${ajeno(2)}; ${ajeno(3)} y 2 más`
    )
  })

  it('sin errores legibles cae al texto genérico', () => {
    expect(mensajeErrorPreciosMasivo({ actualizados: 0, errores: [] })).toBe('Error actualizando precios')
    expect(mensajeErrorPreciosMasivo({ actualizados: 0, errores: null })).toBe('Error actualizando precios')
    expect(mensajeErrorPreciosMasivo({ actualizados: 0, errores: [null] })).toBe('Error actualizando precios')
  })

  // #1473: el producto trabado se saltea y al final se avisa cuáles no se cambiaron.
  describe('con productos trabados', () => {
    const trabado = (id: number, nombre: string) =>
      `${nombre} (ID ${id}): otra operación lo estaba usando y no se cambió`

    it('nombra a los trabados por su nombre, sin repetirlos como errores', () => {
      expect(mensajeErrorPreciosMasivo({
        actualizados: 3,
        errores: [trabado(12, 'Aceite 900ml')],
        trabados: [{ producto_id: 12, nombre: 'Aceite 900ml' }],
      })).toBe(
        'Se actualizaron 3 producto(s). 1 no se cambiaron porque otra operación los estaba usando: Aceite 900ml. '
        + 'Quedaron seleccionados para volver a aplicar.'
      )
    })

    it('los demás errores van aparte, como siempre', () => {
      expect(mensajeErrorPreciosMasivo({
        actualizados: 0,
        errores: [ajeno(7), trabado(12, 'Aceite 900ml')],
        trabados: [{ producto_id: 12, nombre: 'Aceite 900ml' }],
      })).toBe(
        'No se actualizó ningún producto. 1 no se cambiaron porque otra operación los estaba usando: Aceite 900ml. '
        + `Quedaron seleccionados para volver a aplicar. Además, 1 con error: ${ajeno(7)}`
      )
    })

    it('nombra hasta diez trabados y cuenta el resto; sin nombre, por id', () => {
      const trabados = Array.from({ length: 12 }, (_, i) => ({ producto_id: i + 1, nombre: i === 0 ? null : `P${i + 1}` }))
      const msg = mensajeErrorPreciosMasivo({ actualizados: 1, errores: [], trabados })
      expect(msg).toContain('12 no se cambiaron porque otra operación los estaba usando: ID 1, P2, P3, P4, P5, P6, P7, P8, P9, P10 y 2 más.')
    })
  })
})
