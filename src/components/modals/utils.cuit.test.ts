/**
 * El CUIT se valida de verdad: 11 dígitos y dígito verificador (D37 de #1561,
 * 1561-b11). `validarCuit` existía pero aceptaba cualquier cadena de 11 dígitos
 * y nadie la llamaba.
 */
import { describe, it, expect } from 'vitest'
import { validarCuit, errorDeCuit, errorDeDocumento } from './utils'

describe('validarCuit', () => {
  it('acepta CUIT con dígito verificador correcto, con o sin guiones', () => {
    expect(validarCuit('20-12345678-6')).toBe(true)
    expect(validarCuit('20123456786')).toBe(true)
    expect(validarCuit('30-71234567-1')).toBe(true)
    expect(validarCuit('30-11111111-8')).toBe(true)
  })

  it('rechaza 11 dígitos con el dígito verificador equivocado', () => {
    expect(validarCuit('20-12345678-9')).toBe(false)
    expect(validarCuit('20123456780')).toBe(false)
    expect(validarCuit('30-11111111-1')).toBe(false)
  })

  it('rechaza largos distintos de 11 y letras', () => {
    expect(validarCuit('2012345678')).toBe(false)
    expect(validarCuit('201234567860')).toBe(false)
    expect(validarCuit('20-1234567X-6')).toBe(false)
  })

  it('vacío se permite (es opcional)', () => {
    expect(validarCuit('')).toBe(true)
  })

  it('una combinación sin dígito posible (resto 1) es inválida', () => {
    // Se busca por fuerza bruta una base de 10 dígitos con suma ≡ 1 (mod 11).
    let encontrado = false
    for (let n = 0; n < 1000 && !encontrado; n++) {
      const base = `2000000${String(n).padStart(3, '0')}`
      const pesos = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]
      const suma = pesos.reduce((a, p, i) => a + p * Number(base[i]), 0)
      if (suma % 11 === 1) {
        encontrado = true
        for (let d = 0; d <= 9; d++) expect(validarCuit(`${base}${d}`)).toBe(false)
      }
    }
    expect(encontrado).toBe(true)
  })
})

describe('errorDeCuit', () => {
  it('vacío no es error', () => {
    expect(errorDeCuit('')).toBeNull()
    expect(errorDeCuit('  ')).toBeNull()
  })

  it('un CUIT válido no es error', () => {
    expect(errorDeCuit('20-12345678-6')).toBeNull()
  })

  it('un largo incorrecto dice cuántos dígitos hacen falta', () => {
    expect(errorDeCuit('20-1234')).toBe('El CUIT debe tener 11 dígitos')
  })

  it('un dígito verificador equivocado dice que el CUIT no es válido', () => {
    expect(errorDeCuit('20-12345678-9')).toMatch(/no es válido.*dígito verificador/)
  })

  it('uno viejo que no se tocó no bloquea guardar otros cambios', () => {
    expect(errorDeCuit('20-12345678-9', '20-12345678-9')).toBeNull()
    expect(errorDeCuit('20-12345678-9', '20123456789')).toBeNull()
  })

  it('pero si se cambia a otro inválido sí se rechaza', () => {
    expect(errorDeCuit('20-12345678-8', '20-12345678-9')).not.toBeNull()
  })

  // B17 (#1561): el campo CUIT exigía 11 dígitos y los DNI se cargaban rellenados con ceros
  // (00-0NNNNNNN-D). Uno de cada once pasa el dígito verificador: el prefijo lo frena igual.
  it('un DNI rellenado con ceros no pasa como CUIT, aunque el dígito verificador coincida', () => {
    expect(validarCuit('00-03012346-8')).toBe(true)
    expect(errorDeCuit('00-03012346-8')).toMatch(/no empieza con 00.*elegí «DNI»/)
    expect(errorDeCuit('00-03012345-6')).toMatch(/no empieza con 00/)
  })

  // El campo CUIT era obligatorio y se inventaba un número corto: el campo lo rellenaba con ceros.
  it('un número inventado rellenado con ceros no pasa como CUIT y dice que se puede dejar vacío', () => {
    expect(errorDeCuit('00-00000123-4')).toMatch(/no empieza con 00.*dejá el campo vacío/)
  })

  it('el de una ficha vieja que no se tocó no bloquea guardar otros cambios', () => {
    expect(errorDeCuit('00-03012345-6', '00-03012345-6')).toBeNull()
  })
})

describe('errorDeDocumento', () => {
  it('CUIT con dígito verificador equivocado se rechaza', () => {
    expect(errorDeDocumento('CUIT', '20-12345678-9')).toMatch(/no es válido/)
  })

  it('DNI de 7 u 8 dígitos pasa; otro largo se rechaza con su motivo', () => {
    expect(errorDeDocumento('DNI', '1234567')).toBeNull()
    expect(errorDeDocumento('DNI', '12345678')).toBeNull()
    expect(errorDeDocumento('DNI', '123456')).toBe('El DNI debe tener 7 u 8 dígitos')
  })

  it('un DNI con ceros de adelante cuenta sus cifras sin ellos (B17)', () => {
    expect(errorDeDocumento('DNI', '01234567')).toBeNull()
    expect(errorDeDocumento('DNI', '0012345')).toBe('El DNI debe tener 7 u 8 dígitos')
    expect(errorDeDocumento('DNI', '00000123')).toBe('El DNI debe tener 7 u 8 dígitos')
  })

  it('vacío se permite en los dos tipos', () => {
    expect(errorDeDocumento('CUIT', '')).toBeNull()
    expect(errorDeDocumento('DNI', '')).toBeNull()
  })
})
