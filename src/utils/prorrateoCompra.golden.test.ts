import { describe, it, expect } from 'vitest'
import { calcularCostosCompra, calcularTotalesCompra, resolverBasesII, toleranciaII } from './prorrateoCompra'
import { ITEMS_TESTIGO, CARGOS_TESTIGO, II_DECLARADO_TESTIGO } from './prorrateoCompra.espejo'

// La factura testigo —21 renglones, 13,3 M— vive en `prorrateoCompra.espejo.ts`
// desde que tiene dos consumidores: este golden, que fija sus numeros contra el
// Excel del gerente, y el espejo, que manda la misma factura a los dos motores.
// Dos copias de 21 lineas se desincronizan sin que nada avise.
//
// Es el caso que motivo este rediseno. El Excel del gerente cuadra el impuesto
// interno con un factor manual de 1,0496; aca tiene que dar 1,0000.
const ITEMS = ITEMS_TESTIGO
const CARGOS = CARGOS_TESTIGO
const II_DECLARADO = II_DECLARADO_TESTIGO

describe('Factura A0005-00461415 (caso testigo del rediseno)', () => {
  const r = calcularCostosCompra(ITEMS, CARGOS, II_DECLARADO)

  it('el impuesto interno cuadra SOLO: factor de ajuste = 1', () => {
    // El Excel del gerente necesita 1,0496 aca. Modelando afectaBaseII, da 1.
    expect(r.factorAjuste[8.6956]).toBeCloseTo(1, 5)
    expect(r.factorAjuste[4.1667]).toBeCloseTo(1, 5)
  })

  it('el factor se aplica a todas las lineas del bucket', () => {
    // Esta igualdad es POR CONSTRUCCION (factor = declarado/calculado), asi que no
    // valida el modelo: pasaria igual con afectaBaseII en false en todos lados. El
    // que valida el modelo es el test de arriba. Lo que si protege es que la tasa
    // se normalice igual en las dos puntas —4.1667 y 8.6956 tienen que caer en su
    // bucket— y que el factor llegue a TODAS las lineas, no a algunas.
    expect(r.totales.impuestosInternos).toBeCloseTo(338_884.46 + 199_027.21, 1)
  })

  it('el costo total sin IVA coincide con el Excel dentro de 5 centavos', () => {
    // La tolerancia es `toBeCloseTo(_, 1)`, o sea +-0,05, y NO el centavo: el
    // modelo da 12.797.344,2543 y el Excel dice 12.797.344,26. Medio centavo de
    // diferencia, que es lo que hay. Decir "al centavo" afirmaba mas de lo que
    // este assert puede sostener.
    // Y ademas: lo que la base PERSISTE no es esta suma. `costo_real_unitario`
    // es numeric(12,4), asi que redondea el UNITARIO y despues multiplica por la
    // cantidad: sobre las 2.503 unidades de esta factura eso da 12.797.344,23
    // (-0,0267, con cota teorica 0,1252). Verificado contra produccion.
    const total = r.lineas.reduce(
      (acc, l, i) => acc + l.costoRealUnitario * ITEMS[i].cantidad, 0)
    expect(total).toBeCloseTo(12_797_344.26, 1)
  })

  it('MANAOS LIMA LIMON 600cc: desglose completo por pack', () => {
    const l = r.lineas.find(x => x.id === 1)!
    expect(l.baseIvaUnitaria).toBeCloseTo(4764.85, 2)
    expect(l.iiUnitario).toBeCloseTo(198.54, 2)
    expect(l.cargosUnitarios).toBeCloseTo(658.97, 2)   // flete + pallets
    expect(l.ivaUnitario).toBeCloseTo(1000.62, 2)
    expect(l.costoRealUnitario).toBeCloseTo(5622.36, 2)
  })

  it('los separadores caen 100% en el bidon y en ningun otro producto', () => {
    // Diferencial contra la misma factura sin el cargo de separadores: lo unico
    // que puede moverse son los 8.800 del bidon. Un centavo en cualquier otra
    // linea es un separador que se fue de contrabando.
    const sinSeparadores = calcularCostosCompra(
      ITEMS, CARGOS.filter(c => c.concepto !== 'Separadores bidon'), II_DECLARADO)
    const delta = (id: number) =>
      r.lineas.find(x => x.id === id)!.cargosUnitarios -
      sinSeparadores.lineas.find(x => x.id === id)!.cargosUnitarios

    // Primero el que nombra al culpable: si falla, el mensaje trae el id de la
    // linea que se llevo separadores que no le tocaban.
    const contrabando = ITEMS.filter(i => i.id !== 21 && delta(i.id) !== 0).map(i => i.id)
    expect(contrabando).toEqual([])
    expect(delta(21) * 168).toBeCloseTo(8_800, 2)
    // Y ademas de los separadores el bidon paga su parte de flete y pallets:
    // 73.076,92 + 6.000 + 8.800 = 87.876,92 / 168
    expect(r.lineas.find(x => x.id === 21)!.cargosUnitarios).toBeCloseTo(523.08, 2)
  })

  it('el modelo NO copia el reparto de II del Excel: lo corrige', () => {
    // El factor proporcional del Excel unta el II de la promo sobre productos
    // que no participaron. MANAOS COLA 600cc (id 9) no tuvo promo: el Excel le
    // carga 419,70 por pack, el modelo 399,86.
    const sinPromo = r.lineas.find(x => x.id === 9)!
    expect(sinPromo.iiUnitario).toBeCloseTo(399.86, 2)
  })

  it('la cabecera fiscal sale del motor y no de un loop sobre las lineas', () => {
    // El defecto que este test cierra: `calcularTotalesCompra` no veia los
    // cargos, asi que las tres bonificaciones gravadas no bajaban ninguna base.
    // Los dos numeros de abajo son los que viajan a compras.impuestos_internos y
    // compras.iva, o sea a la posicion fiscal.
    const t = calcularTotalesCompra(
      ITEMS.map(i => ({ ...i, lineaId: i.id })), 'FC', {}, CARGOS, II_DECLARADO)

    // Ajustado al declarado: 338.884,46 + 199.027,21. Antes daba 546.908,57.
    expect(t.impuestosInternos).toBeCloseTo(537_911.67, 2)
    // Sobre la base gravada REAL (10.188.632,58), no sobre los netos de linea.
    // Antes daba 2.204.037,50, o sea 64.424,66 de credito fiscal inventado.
    expect(t.netoGravado).toBeCloseTo(10_188_632.58, 2)
    expect(t.iva).toBeCloseTo(10_188_632.58 * 0.21, 2)
    // El subtotal sigue siendo el neto de las LINEAS: lo clava COMPRA-A2 contra
    // SUM(compra_items.subtotal), y por eso el total de cabecera no puede bajar
    // los cargos gravados. Ver el comentario de TotalesCompra.subtotal.
    expect(t.subtotal).toBeCloseTo(10_495_416.67, 2)
  })

  it('los cargos no gravados entran al costo pero no a la base de IVA', () => {
    // Los 2.070.800 de flete + pallets + separadores no son gravados. Si entraran
    // a la base gravada, el IVA se inflaria en 434.868 que nadie facturo.
    // 10.188.632,58 = netos de las 21 lineas (10.495.416,67) menos las tres
    // bonificaciones gravadas (306.784,09), y nada mas.
    expect(r.totales.netoGravado).toBeCloseTo(10_188_632.58, 2)
    expect(r.totales.cargosAlCosto).toBeCloseTo(2_070_800, 2)
    // De esos 2.070.800 solo 170.800 (pallets + separadores) estan en el papel:
    // el flete lo factura el transportista aparte, de ahi enFactura: false.
    expect(r.totales.noGravado).toBeCloseTo(170_800, 2)
  })
})

describe('El solver deduce afectaBaseII de la misma factura', () => {
  // Lo que el golden de arriba tiene CLAVADO —COLA 3.00 baja la base, 3000cc
  // no—, acá se DEDUCE del impuesto interno declarado. Si el solver deduce otra
  // cosa, uno de los dos está mal y hay que mirar los dos.
  const r = resolverBasesII(ITEMS, CARGOS, II_DECLARADO)

  it('encuentra una sola combinacion, y es la del golden', () => {
    expect(r.estado).toBe('unica')
    expect(r.soluciones[0].asignacion).toEqual({
      4: true,   // Bonif. promo COLA 3.00 → descuento de precio
      5: false,  // Bonif. promo 3000cc    → bonificación comercial
    })
  })

  it('el redondeo de -0,49 es indeterminable, no una tercera variable', () => {
    // Mueve el impuesto interno 1,6 centavos: la factura no puede decidirlo. Si
    // entrara a la búsqueda, cada solución vendría con su gemela y el resultado
    // sería "ambigua" para siempre — o sea, el ajuste proporcional de vuelta.
    expect(r.indeterminables).toEqual([6])
    expect(r.candidatos).toEqual([4, 5])
  })

  it('cierra a 6 centavos sobre 338.884, que es el redondeo del proveedor', () => {
    expect(r.soluciones[0].residuos[8.6956]).toBeCloseTo(0.06, 2)
    expect(r.soluciones[0].residuos[4.1667]).toBeCloseTo(0, 2)
  })

  it('LA SEPARACION: la correcta entra holgada y la siguiente queda afuera', () => {
    // Este test es el que sostiene la tolerancia elegida. Aflojarla hasta que
    // pasen los 795,40 del 4,1667% convierte al solver en un generador de
    // respuestas plausibles; apretarla por debajo de los 6 centavos rechaza la
    // única respuesta correcta que conocemos.
    expect(r.soluciones[0].holgura).toBeLessThan(0.01)   // 300 veces adentro del borde

    const conAmbas = CARGOS.map(c => c.id === 5 ? { ...c, afectaBaseII: true } : c)
    const iiAmbas = calcularCostosCompra(ITEMS, conAmbas, {})
    const ii4 = ITEMS.reduce((acc, l, i) =>
      acc + (l.impuestosInternos === 4.1667 ? iiAmbas.lineas[i].iiUnitario * l.cantidad : 0), 0)
    expect(199_027.21 - ii4).toBeCloseTo(795.40, 1)
    expect(toleranciaII(199_027.21)).toBeCloseTo(99.51, 2)
    expect(Math.abs(199_027.21 - ii4)).toBeGreaterThan(toleranciaII(199_027.21) * 7)
  })

  it('sin el impuesto interno declarado no hay nada que deducir', () => {
    // El casillero vacío no es "no baja la base": es "no sé". El solver lo dice
    // y la interfaz cae al ajuste proporcional avisando que es una aproximación.
    expect(resolverBasesII(ITEMS, CARGOS, {}).estado).toBe('sin_datos')
  })
})

describe('La cabecera cuadra contra el papel: bonificaciones de factura', () => {
  const t = calcularTotalesCompra(
    ITEMS.map(i => ({ ...i, lineaId: i.id })), 'FC',
    { noGravado: 170_800 }, CARGOS, II_DECLARADO)

  it('la bonificacion general es la suma de los cargos gravados EN la factura', () => {
    // Las dos promos más el redondeo: -103.465,32 -203.318,28 -0,49.
    expect(t.bonificaciones).toBeCloseTo(-306_784.09, 2)
  })

  it('el total baja 306.784,09: es lo que la cabecera no tenia donde restar', () => {
    // `subtotal` es el neto de los RENGLONES y lo clava COMPRA-A2 contra
    // SUM(compra_items.subtotal), así que una bonificación general —que no es un
    // renglón de producto— no tenía columna. El total salía 306.784,09 arriba
    // del papel y COMPRA-A1 (severidad high) se ponía rojo.
    const viejo = t.subtotal + t.iva + t.impuestosInternos
      + t.percepcionIva + t.percepcionIibb + t.noGravado + t.otrosImpuestos
    expect(viejo - t.total).toBeCloseTo(306_784.09, 2)
    // ±0,05 y no el centavo: el impuesto interno ajustado arrastra una cola
    // sub-centavo (537.911,6670) que el total hereda. La base redondea a 2
    // decimales al persistir; acá no hay dónde hacerlo sin mentir.
    expect(t.total).toBeCloseTo(13_036_957.10, 1)
  })

  it('la identidad de COMPRA-A1 (mig 195) cierra al centavo', () => {
    expect(t.total).toBeCloseTo(
      t.subtotal + t.bonificaciones + t.iva + t.impuestosInternos
      + t.percepcionIva + t.percepcionIibb + t.noGravado + t.otrosImpuestos, 6)
  })

  it('y ahora las filas del resumen suman el total que muestran', () => {
    // El resumen imprime el GRAVADO (que ya trae la bonificación adentro), no el
    // subtotal, así que hasta la mig 195 las filas visibles sumaban 306.784,09
    // menos que el "Total" impreso abajo de ellas.
    expect(t.netoGravado + t.netoExento + t.netoNoGravado + t.iva
           + t.impuestosInternos + t.noGravado).toBeCloseTo(t.total, 6)
  })

  it('en ZZ no hay papel contra el que cuadrar: total = subtotal', () => {
    const zz = calcularTotalesCompra(
      ITEMS.map(i => ({ ...i, lineaId: i.id })), 'ZZ', {}, CARGOS, II_DECLARADO)
    expect(zz.bonificaciones).toBe(0)
    expect(zz.total).toBeCloseTo(zz.subtotal, 6)
  })
})
