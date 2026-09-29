import { describe, it, expect, vi } from 'vitest'

// hojaRutaOptimizada importa horarioParaRutear de useOptimizarRuta, que arrastra
// el cliente de supabase. Sin .env (la corrida que vale, trampa #1 del CLAUDE.md)
// createClient tira "supabaseUrl is required" y el archivo ni se carga.
vi.mock('../../supabase', () => ({ supabase: {} }))

import { buildCardOps, buildManifiestoOps } from '../hojaRutaOptimizada'
import {
  GRANADINA,
  POMELO,
  itemRegaloDosTokens,
  itemRegaloEnteroGranadina,
  itemRegaloEnteroPomelo,
  itemRegaloFraccion,
  itemVenta,
  pedido,
} from './fixtures'

/**
 * Doc de mentira: sólo hace falta que mida y NO corte, así cada línea lógica
 * queda entera en una op y se puede afirmar sobre el texto completo.
 */
const fakeDoc = () => ({
  setFont: () => {},
  setFontSize: () => {},
  splitTextToSize: (text) => [text],
})

const textos = (ops) => ops.map((op) => op.text || op.nombre).filter(Boolean)
const manifiesto = (ops) => ops
  .filter((op) => op.kind === 'manifiesto-line')
  .map((op) => `${op.cantidad} ${op.nombre}`.trim())

describe('buildCardOps — unidades del regalo', () => {
  it('parte el regalo de fracción con el factor CONGELADO, no con el vivo', () => {
    const ops = buildCardOps(fakeDoc(), pedido([itemRegaloFraccion()]), 1)
    const linea = textos(ops).find((t) => t.includes('SUELTAS'))

    // 392 / 6 (congelado) = 65 fardos + 2. Con el vivo (12) daría 32 + 8.
    expect(linea).toBe('392x Botellas Manaos Pomelo 3L (SUELTAS, NO FARDO = 65 FARDOS + 2)')
    expect(linea).not.toContain('32 FARDOS')
  })

  it('no repite el conteo de la descripción de la promo', () => {
    const ops = buildCardOps(fakeDoc(), pedido([itemRegaloFraccion()]), 1)
    // "2 Botellas Manaos…" describe un bloque: dejarlo puesto imprimía
    // "392x 2 Botellas…".
    expect(textos(ops).some((t) => t.includes('x 2 Botellas'))).toBe(false)
  })

  it('ignora el factor vivo cuando la promo mueve stock (gate de la mig 212)', () => {
    const item = itemRegaloFraccion({
      unidades_por_bloque_al_crear: null,
      promocion: { unidades_por_bloque: 6, regalo_mueve_stock: true },
    })
    const linea = textos(buildCardOps(fakeDoc(), pedido([item]), 1))
      .find((t) => t.includes('Manaos Pomelo'))

    // Sin factor: la cantidad ya está en unidades de venta, no se parte nada.
    expect(linea).toBe('392x Botellas Manaos Pomelo 3L')
  })

  it('el regalo de unidad entera conserva la aclaración de bulto', () => {
    const ops = buildCardOps(fakeDoc(), pedido([itemRegaloEnteroGranadina()]), 1)
    const linea = textos(ops).find((t) => t.includes('Granadina'))

    expect(linea).toBe('12x Granadina 1L (2 FARDOS)')
    expect(linea).not.toContain('SUELTAS')
  })

  it('la línea de venta no cambia', () => {
    const ops = buildCardOps(fakeDoc(), pedido([itemVenta()]), 1)
    expect(textos(ops)).toContain('12x Granadina 1L (2 FARDOS)')
  })
})

describe('buildManifiestoOps — consolidado de la ruta', () => {
  it('parte las subunidades de toda la ruta con el factor congelado', () => {
    const ops = buildManifiestoOps(fakeDoc(), [pedido([itemRegaloFraccion()])])

    expect(manifiesto(ops)).toContain('65x Manaos Pomelo 3L (FARDOS COMPLETOS)')
    expect(manifiesto(ops)).toContain('2x botellas Manaos Pomelo 3L (SUELTAS, NO FARDO)')
  })

  it('no mezcla los fardos convertidos con una bonificación de unidad entera del mismo producto', () => {
    const ops = buildManifiestoOps(fakeDoc(), [
      pedido([itemRegaloFraccion()]),
      pedido([itemRegaloEnteroPomelo()], { id: 14 }),
    ])
    const filas = manifiesto(ops)

    // Dos filas distintas: 65 fardos del bloque de la promo y 3 unidades de
    // venta. Sumadas daban "68x … (FARDOS COMPLETOS)", que no es ninguna de las dos.
    expect(filas).toContain('65x Manaos Pomelo 3L (FARDOS COMPLETOS)')
    expect(filas).toContain('3x Manaos Pomelo 3L')
    expect(filas.some((f) => f.startsWith('68x'))).toBe(false)
  })

  it('consolida un mismo producto de dos pedidos antes de partirlo', () => {
    const ops = buildManifiestoOps(fakeDoc(), [
      pedido([itemRegaloFraccion({ cantidad: 5 })]),
      pedido([itemRegaloFraccion({ cantidad: 7 })], { id: 14 }),
    ])

    // 5 + 7 = 12 botellas = 2 fardos exactos. Partido pedido por pedido darían
    // 0 fardos + 5 sueltas y 1 fardo + 1 suelta.
    expect(manifiesto(ops)).toContain('2x Manaos Pomelo 3L (FARDOS COMPLETOS)')
    expect(manifiesto(ops).some((f) => f.includes('SUELTAS'))).toBe(false)
  })

  it('no suma líneas del mismo producto con factores distintos', () => {
    const ops = buildManifiestoOps(fakeDoc(), [
      pedido([itemRegaloFraccion({ cantidad: 12, unidades_por_bloque_al_crear: 6 })]),
      pedido([itemRegaloFraccion({ cantidad: 12, unidades_por_bloque_al_crear: 12 })], { id: 14 }),
    ])

    // 12/6 = 2 fardos y 12/12 = 1 fardo: 3 en total, cada uno con su factor.
    // Sumar las 24 subunidades crudas y partirlas por un solo factor daría 4 o 2.
    expect(manifiesto(ops)).toContain('3x Manaos Pomelo 3L (FARDOS COMPLETOS)')
  })

  it('descarta el conteo inicial de una descripción de dos tokens', () => {
    const ops = buildManifiestoOps(fakeDoc(), [pedido([itemRegaloDosTokens()])])

    // "2 Granadina" describe un bloque: imprimir "3x 2 Granadina" hacía cargar 6.
    expect(manifiesto(ops)).toContain('3x Granadina (SUELTAS, NO FARDO)')
    expect(manifiesto(ops).some((f) => f.includes('2 Granadina'))).toBe(false)
  })

  it('pluraliza la unidad de una descripción de tres tokens', () => {
    const item = itemRegaloFraccion({ cantidad: 2, descripcion_regalo: '1 Botella Manaos Pomelo 3L' })
    const ops = buildManifiestoOps(fakeDoc(), [pedido([item])])

    expect(manifiesto(ops)).toContain('2x botellas Manaos Pomelo 3L (SUELTAS, NO FARDO)')
  })

  it('regalo en fracción sin descripcion_regalo (#830): 1 fardo, no "6x"', () => {
    // Pedido 5119: sabor cambiado al cargar, descripcion_regalo = NULL. Son 6
    // botellas = 1 fardo del producto entregado, no 6 fardos.
    const item = itemRegaloFraccion({ cantidad: 6, descripcion_regalo: null })
    const lineas = manifiesto(buildManifiestoOps(fakeDoc(), [pedido([item])]))

    expect(lineas).toContain(`1x ${POMELO.nombre} (FARDO COMPLETO)`)
    expect(lineas.some((f) => f.startsWith('6x'))).toBe(false)
  })

  it('la venta sigue yendo a la lista principal con su aclaración', () => {
    const ops = buildManifiestoOps(fakeDoc(), [pedido([itemVenta()])])
    expect(manifiesto(ops)).toContain('12x Granadina 1L (2 FARDOS)')
  })

  describe('regalo repartido en sabores (#831)', () => {
    const NARANJA = { id: 11, nombre: 'Manaos Naranja 3L' }
    const LIMON = { id: 12, nombre: 'Manaos Limon 3L' }
    // 15 botellas de una promo Fracción (factor 6) repartidas en tres sabores,
    // como las deja dividir_regalo_pedido: misma promo, misma unidad y cada
    // parte con su marca de sustituto.
    const reparto = () => [
      itemRegaloFraccion({ cantidad: 8 }),
      itemRegaloFraccion({
        producto_id: NARANJA.id,
        producto: NARANJA,
        cantidad: 4,
        descripcion_regalo: '2 Botellas Manaos Pomelo 3L [Sustituido por: Manaos Naranja 3L]',
      }),
      itemRegaloFraccion({
        producto_id: LIMON.id,
        producto: LIMON,
        cantidad: 3,
        descripcion_regalo: '2 Botellas Manaos Pomelo 3L [Sustituido por: Manaos Limon 3L]',
      }),
    ]

    it('cada sabor va en su fila, con fardos por producto y sueltas por sabor', () => {
      const filas = manifiesto(buildManifiestoOps(fakeDoc(), [pedido(reparto())]))

      expect(filas).toContain('1x Manaos Pomelo 3L (FARDO COMPLETO)')
      expect(filas).toContain('2x botellas Manaos Pomelo 3L (SUELTAS, NO FARDO)')
      expect(filas).toContain('4x botellas Manaos Pomelo 3L [Sustituido por: Manaos Naranja 3L] (SUELTAS, NO FARDO)')
      expect(filas).toContain('3x botellas Manaos Pomelo 3L [Sustituido por: Manaos Limon 3L] (SUELTAS, NO FARDO)')
      // Las 15 botellas siguen siendo 15: 6 en el fardo y 9 sueltas.
      expect(filas.some((f) => f.startsWith('9x') || f.startsWith('15x'))).toBe(false)
    })

    it('dos sabores con la misma descripción no se suman en una fila anónima', () => {
      const [pomelo, naranja] = reparto()
      const filas = manifiesto(buildManifiestoOps(fakeDoc(), [
        pedido([{ ...pomelo, cantidad: 2 }, { ...naranja, cantidad: 4, descripcion_regalo: pomelo.descripcion_regalo }]),
      ]))

      expect(filas).toContain('2x botellas Manaos Pomelo 3L - Manaos Pomelo 3L (SUELTAS, NO FARDO)')
      expect(filas).toContain('4x botellas Manaos Pomelo 3L - Manaos Naranja 3L (SUELTAS, NO FARDO)')
      expect(filas.some((f) => f.startsWith('6x'))).toBe(false)
    })

    it('la tarjeta del pedido lista cada parte por separado', () => {
      const lineas = textos(buildCardOps(fakeDoc(), pedido(reparto()), 1))
        .filter((t) => t.includes('SUELTAS'))
      expect(lineas).toHaveLength(3)
      expect(lineas.some((t) => t.startsWith('4x') && t.includes('Naranja'))).toBe(true)
      expect(lineas.some((t) => t.startsWith('3x') && t.includes('Limon'))).toBe(true)
    })
  })

  it('los ids de los fixtures son los que asume el agrupado', () => {
    // Si POMELO y GRANADINA compartieran id, los tests de arriba pasarían por
    // accidente.
    expect(POMELO.id).not.toBe(GRANADINA.id)
  })
})
