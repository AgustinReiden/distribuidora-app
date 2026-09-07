import { describe, it, expect } from 'vitest'
import { costoCanonicoUnitario } from './costoCanonico'

// Producto con TODOS los términos cargados y distintos entre sí: cada test
// tapa un término y verifica cuál gana. Si el orden se rompe, el valor
// devuelto dice exactamente en qué escalón se cayó.
const productoCompleto = {
  costo_promedio: 70,
  costo_real: 80,
  costo_sin_iva: 100,
  impuestos_internos: 10,
}

describe('costoCanonicoUnitario', () => {
  describe('orden de la cascada', () => {
    it('el snapshot congelado gana sobre todo lo demás', () => {
      expect(costoCanonicoUnitario(55, productoCompleto)).toBe(55)
    })

    it('sin snapshot gana costo_promedio, no costo_real', () => {
      // El bug que unifica esta función: las tres superficies viejas se
      // saltaban el promedio y cobraban el costo de reposición como CMV.
      expect(costoCanonicoUnitario(null, productoCompleto)).toBe(70)
    })

    it('sin snapshot ni promedio cae a costo_real', () => {
      expect(
        costoCanonicoUnitario(null, { ...productoCompleto, costo_promedio: null })
      ).toBe(80)
    })

    it('sin snapshot, promedio ni costo_real usa la fórmula con impuestos internos', () => {
      expect(
        costoCanonicoUnitario(null, {
          ...productoCompleto,
          costo_promedio: null,
          costo_real: null,
        })
      ).toBe(110)
    })

    it('la fórmula sin impuestos internos es el neto tal cual', () => {
      expect(
        costoCanonicoUnitario(null, { costo_sin_iva: 100, impuestos_internos: null })
      ).toBe(100)
    })
  })

  describe('semántica COALESCE: 0 es un valor, no un hueco', () => {
    it('un snapshot en 0 corta la cascada (regalo con costo cero)', () => {
      expect(costoCanonicoUnitario(0, productoCompleto)).toBe(0)
    })

    it('un costo_promedio en 0 corta la cascada', () => {
      expect(costoCanonicoUnitario(null, { ...productoCompleto, costo_promedio: 0 })).toBe(0)
    })
  })

  describe('ausencia de datos', () => {
    it('undefined en el snapshot equivale a NULL', () => {
      expect(costoCanonicoUnitario(undefined, productoCompleto)).toBe(70)
    })

    it('un producto sin ningún costo cargado da 0, no NaN', () => {
      expect(costoCanonicoUnitario(null, {})).toBe(0)
    })

    it('sin producto (embed nulo) y sin snapshot da 0', () => {
      expect(costoCanonicoUnitario(null, null)).toBe(0)
      expect(costoCanonicoUnitario(null, undefined)).toBe(0)
    })

    it('sin producto pero con snapshot devuelve el snapshot', () => {
      expect(costoCanonicoUnitario(42, null)).toBe(42)
    })

    it('un valor no numérico se trata como ausente', () => {
      // PostgREST puede devolver numeric como string; un string vacío o basura
      // no debe convertirse en 0 silenciosamente y tapar el resto de la cascada.
      expect(costoCanonicoUnitario('' as unknown as number, productoCompleto)).toBe(70)
      expect(costoCanonicoUnitario('abc' as unknown as number, productoCompleto)).toBe(70)
    })

    it('un numeric que llega como string se usa igual', () => {
      expect(costoCanonicoUnitario('55.5' as unknown as number, productoCompleto)).toBe(55.5)
    })
  })

  describe('costo_con_iva no participa', () => {
    it('un producto que sólo tiene costo_con_iva da 0, no el costo financiero', () => {
      // costo_con_iva es el costo FINANCIERO (IVA adentro). El COMMENT de la
      // columna dice literal "NO usar para margen real": entra al CMV inflado.
      const soloFinanciero = { costo_con_iva: 121 } as unknown as Parameters<
        typeof costoCanonicoUnitario
      >[1]
      expect(costoCanonicoUnitario(null, soloFinanciero)).toBe(0)
    })
  })

  describe('ZZ: lo pagado ya incluye IVA e impuestos internos (mig 111)', () => {
    it('no le suma impuestos internos encima al costo_real de una compra ZZ', () => {
      // En ZZ costo_real guarda lo pagado tal cual. Como costo_real corta la
      // cascada antes de la fórmula, los internos nunca se suman dos veces.
      const zz = { costo_promedio: null, costo_real: 500, costo_sin_iva: 500, impuestos_internos: 8.6956 }
      expect(costoCanonicoUnitario(null, zz)).toBe(500)
    })
  })
})
