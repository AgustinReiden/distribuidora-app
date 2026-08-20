import { describe, it, expect } from 'vitest'
import { prorratearCargo, calcularCostosCompra, resolverBasesII, toleranciaII, TOLERANCIA_II_PISO, MAX_CARGOS_BASE_II, type CargoCompra, type LineaCompra } from './prorrateoCompra'
import { redondearSQL } from './calculations'

describe('prorratearCargo', () => {
  it('reparte proporcional al peso', () => {
    expect(prorratearCargo(1000, { 1: 1, 2: 1 })).toEqual({ 1: 500, 2: 500 })
  })

  it('la suma de los repartos SIEMPRE da el monto exacto', () => {
    const r = prorratearCargo(1000, { 1: 1, 2: 1, 3: 1 })
    expect(Object.values(r).reduce((a, b) => a + b, 0)).toBe(1000)
  })

  it('el residuo va a la linea de mayor peso', () => {
    // 100 / 3 partes desiguales: 1+1+4 = 6 → 16.67 + 16.67 + 66.66 = 100.00
    const r = prorratearCargo(100, { 1: 1, 2: 1, 3: 4 })
    expect(r[1]).toBe(16.67)
    expect(r[2]).toBe(16.67)
    expect(r[3]).toBe(66.66)
  })

  it('empate de peso maximo: desempata por menor id', () => {
    const r = prorratearCargo(100, { 7: 1, 3: 1, 5: 1 })
    expect(Object.values(r).reduce((a, b) => a + b, 0)).toBe(100)
    expect(r[3]).toBe(33.34) // el residuo cae en el id menor
  })

  it('peso cero excluye la linea (es el mecanismo de alcance)', () => {
    const r = prorratearCargo(880, { 1: 0, 2: 0, 3: 1 })
    expect(r[3]).toBe(880)
    expect(r[1]).toBe(0)
  })

  it('monto negativo (bonificacion) reparte igual y suma exacto', () => {
    const r = prorratearCargo(-100, { 1: 1, 2: 1, 3: 1 })
    expect(Object.values(r).reduce((a, b) => a + b, 0)).toBe(-100)
  })

  it('usa el redondeo de Postgres, no el de JS: medio centavo negativo', () => {
    // Con redondear() (Math.round) esto daria {1: -0.01, 2: -0}: el residuo cae
    // en la linea equivocada. Es el unico caso de la suite que distingue las dos
    // funciones de redondeo, asi que una regresion a redondear() lo rompe.
    const r = prorratearCargo(-0.01, { 1: 1, 2: 1 })
    expect(r[2]).toBe(-0.01)
    expect(r[1]).toBe(0)
  })

  it('suma de pesos cero devuelve vacio', () => {
    expect(prorratearCargo(1000, { 1: 0, 2: 0 })).toEqual({})
  })

  it('el flete real de la factura: 1.900.000 sobre 26 pallets', () => {
    const pesos = { 1: 0.5, 2: 0.5, 3: 2, 4: 0.5, 5: 0.5, 6: 1, 7: 1, 8: 2, 9: 1, 10: 2,
                    11: 4, 12: 1, 13: 1, 14: 2, 15: 1, 16: 1, 17: 1, 18: 1, 19: 1, 20: 1, 21: 1 }
    const r = prorratearCargo(1900000, pesos)
    expect(r[1]).toBe(36538.46)   // medio pallet
    expect(r[6]).toBe(73076.92)   // un pallet
    expect(r[11]).toBe(292307.72) // la linea del residuo: absorbe 3 centavos sobre el proporcional
    // Sumar 21 floats acumula error (da 1899999.9999999995). Cada parte es
    // exacta al centavo; el total hay que releerlo al centavo. En SQL no pasa:
    // numeric es decimal exacto y sum() da 1900000 clavado.
    expect(redondearSQL(Object.values(r).reduce((a, b) => a + b, 0), 2)).toBe(1900000)
  })

  it('sin pesos devuelve vacio', () => {
    expect(prorratearCargo(100, {})).toEqual({})
  })

  describe('contrato de entrada: el cero es valido, el negativo y el NaN son corrupcion', () => {
    it('peso negativo: falla nombrando la linea, no se come el cargo', () => {
      // Antes devolvia {} (los pesos se cancelaban a 0) y el cargo desaparecia entero.
      expect(() => prorratearCargo(100, { 1: 1, 2: -1 })).toThrow(/peso negativo en la linea 2/)
    })

    it('peso NaN: falla nombrando la linea, no redistribuye en silencio', () => {
      // Antes Number(v) || 0 lo volvia 0 y la linea 2 se llevaba los 100 enteros.
      expect(() => prorratearCargo(100, { 1: NaN, 2: 1 })).toThrow(/peso no finito en la linea 1/)
    })

    it('peso Infinity: falla nombrando la linea', () => {
      expect(() => prorratearCargo(100, { 1: 1, 2: Infinity })).toThrow(/peso no finito en la linea 2/)
    })

    it('monto no finito: falla (antes no habia ninguna defensa del lado del monto)', () => {
      expect(() => prorratearCargo(NaN, { 1: 1 })).toThrow(/monto no finito/)
      expect(() => prorratearCargo(Infinity, { 1: 1 })).toThrow(/monto no finito/)
    })
  })
})

describe('calcularCostosCompra', () => {
  const linea = (over: Partial<LineaCompra> = {}): LineaCompra => ({
    id: 1, cantidad: 10, costoUnitario: 100, bonificacion: 0,
    impuestosInternos: 0, porcentajeIva: 21, condicionIva: 'gravado', ...over,
  })
  const cargo = (over: Partial<CargoCompra> = {}): CargoCompra => ({
    id: 1, concepto: 'x', monto: 0, condicionIva: 'no_gravado',
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: {}, ...over,
  })

  it('sin cargos se comporta igual que hoy: neto x (1 + II%)', () => {
    const r = calcularCostosCompra([linea({ impuestosInternos: 8.6956 })], [], {})
    expect(r.lineas[0].costoRealUnitario).toBeCloseTo(108.6956, 4)
  })

  it('un cargo NO GRAVADO entra al costo pero NO a la base de IVA', () => {
    const r = calcularCostosCompra(
      [linea()],
      [cargo({ monto: 500, pesos: { 1: 1 } })],
      {}
    )
    expect(r.lineas[0].baseIvaUnitaria).toBe(100)      // 1000/10, sin el cargo
    expect(r.lineas[0].ivaUnitario).toBe(21)           // 21% de 100, NO de 150
    expect(r.lineas[0].cargosUnitarios).toBe(50)       // 500/10
    expect(r.lineas[0].costoRealUnitario).toBe(150)    // sí entra al costo
  })

  it('un cargo fuera de factura entra al costo pero no al IVA de la factura', () => {
    const r = calcularCostosCompra(
      [linea()],
      [cargo({ monto: 500, condicionIva: 'gravado', enFactura: false, pesos: { 1: 1 } })],
      {}
    )
    expect(r.totales.netoGravado).toBe(1000)     // el cargo no suma al IVA de esta compra
    expect(r.lineas[0].costoRealUnitario).toBe(150)
  })

  it('afectaBaseII=false: la bonificacion baja el IVA pero no el impuesto interno', () => {
    const r = calcularCostosCompra(
      [linea({ impuestosInternos: 10 })],
      [cargo({ monto: -200, condicionIva: 'gravado', afectaBaseII: false, pesos: { 1: 1 } })],
      {}
    )
    expect(r.lineas[0].baseIvaUnitaria).toBe(80)   // (1000-200)/10
    expect(r.lineas[0].iiUnitario).toBe(10)        // 10% de 1000/10, NO de 800/10
  })

  it('afectaBaseII=true: la bonificacion baja las dos bases', () => {
    const r = calcularCostosCompra(
      [linea({ impuestosInternos: 10 })],
      [cargo({ monto: -200, condicionIva: 'gravado', afectaBaseII: true, pesos: { 1: 1 } })],
      {}
    )
    expect(r.lineas[0].iiUnitario).toBe(8)         // 10% de 800/10
  })

  it('el factor de ajuste cuadra el II declarado y se reporta', () => {
    const r = calcularCostosCompra(
      [linea({ impuestosInternos: 10 })],
      [],
      { 10: 110 }   // declarado 110 vs calculado 100
    )
    expect(r.factorAjuste[10]).toBeCloseTo(1.1, 6)
    expect(r.lineas[0].iiUnitario).toBeCloseTo(11, 4)
  })

  it('cantidad 0 no explota', () => {
    const r = calcularCostosCompra([linea({ cantidad: 0 })], [], {})
    expect(r.lineas[0].costoRealUnitario).toBe(0)
  })

  it('la linea exenta no suma a netoGravado, pero si tiene costo', () => {
    const r = calcularCostosCompra(
      [linea({ id: 1 }), linea({ id: 2, condicionIva: 'exento', porcentajeIva: 0 })],
      [],
      {}
    )
    expect(r.totales.netoGravado).toBe(1000)   // solo la linea gravada
    expect(r.totales.netoExento).toBe(1000)
    expect(r.totales.iva).toBe(210)            // 21% de 1000, la exenta no aporta
    expect(r.lineas[1].baseIvaUnitaria).toBe(0)
    expect(r.lineas[1].ivaUnitario).toBe(0)
    expect(r.lineas[1].costoRealUnitario).toBe(100)  // exenta de IVA no es exenta de costo
  })

  it('un cargo en factura que no prorratea al costo: cae en noGravado y no en cargosAlCosto', () => {
    // El caso pallets: esta en el papel, pero no es costo del producto.
    const r = calcularCostosCompra(
      [linea()],
      [cargo({ monto: 500, prorrateaAlCosto: false, pesos: { 1: 1 } })],
      {}
    )
    expect(r.totales.noGravado).toBe(500)       // cuadra contra el papel
    expect(r.totales.cargosAlCosto).toBe(0)     // no reconcilia contra ningun costo
    expect(r.lineas[0].cargosUnitarios).toBe(0)
    expect(r.lineas[0].costoRealUnitario).toBe(100)
  })

  it('4.17 y 4.1667 son alicuotas distintas: el bucket tipeado a mano no se ajusta', () => {
    // Datos reales de compra_items: 18 filas en 4.1667 y 1 en 4.1700.
    // Si la factura declara un solo bucket, la linea tipeada 4,17 queda afuera
    // y el II no cuadra. Eso es el detector avisando, no un falso positivo.
    const r = calcularCostosCompra(
      [linea({ id: 1, impuestosInternos: 4.1667 }), linea({ id: 2, impuestosInternos: 4.17 })],
      [],
      { 4.1667: 50 }   // declarado solo para el bucket bueno; calculado 41.667
    )
    expect(r.factorAjuste[4.1667]).toBeCloseTo(50 / 41.667, 9)
    expect(r.factorAjuste[4.17]).toBeUndefined()
    expect(r.lineas[0].iiUnitario).toBeCloseTo(5, 9)      // 50 declarados / 10 unidades
    expect(r.lineas[1].iiUnitario).toBeCloseTo(4.17, 9)   // 41.7 sin ajustar / 10
    expect(r.totales.impuestosInternos).toBeCloseTo(91.7, 6)
  })

  describe('contrato de entrada: cantidad 0 es valida, la negativa y el NaN son corrupcion', () => {
    it('cantidad negativa: falla nombrando la linea', () => {
      // Antes la linea devolvia 0 en cada unitario y el total sumaba el neto
      // negativo igual: la asimetria dejaba pasar el dato corrupto.
      expect(() => calcularCostosCompra([linea({ id: 7, cantidad: -1 })], [], {}))
        .toThrow(/cantidad invalida en la linea 7/)
    })

    it('cantidad no finita: falla nombrando la linea', () => {
      expect(() => calcularCostosCompra([linea({ id: 4, cantidad: NaN })], [], {}))
        .toThrow(/cantidad invalida en la linea 4/)
    })
  })
})

describe('resolverBasesII', () => {
  // Una sola línea gravada con impuesto interno del 10%: neto 1000, II 100.
  // Cada bonificación de −200 baja el II a 80 si afecta la base.
  const linea = (over: Partial<LineaCompra> = {}): LineaCompra => ({
    id: 1, cantidad: 10, costoUnitario: 100, bonificacion: 0,
    impuestosInternos: 10, porcentajeIva: 21, condicionIva: 'gravado', ...over,
  })
  const bonif = (over: Partial<CargoCompra> = {}): CargoCompra => ({
    id: 1, concepto: 'Bonif', monto: -200, condicionIva: 'gravado',
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: { 1: 1 }, ...over,
  })

  it('una sola bonificacion: el declarado dice cual de las dos hipotesis es', () => {
    const baja = resolverBasesII([linea()], [bonif()], { 10: 80 })
    expect(baja.estado).toBe('unica')
    expect(baja.soluciones[0].asignacion).toEqual({ 1: true })

    const noBaja = resolverBasesII([linea()], [bonif()], { 10: 100 })
    expect(noBaja.estado).toBe('unica')
    expect(noBaja.soluciones[0].asignacion).toEqual({ 1: false })
  })

  it('el residuo viene con el signo de CuadreII.desvio: declarado - calculado', () => {
    const r = resolverBasesII([linea()], [bonif()], { 10: 80.5 })
    // 80,5 declarado contra 80 calculado. Entra por el piso de 1 peso.
    expect(r.estado).toBe('unica')
    expect(r.soluciones[0].residuos[10]).toBeCloseTo(0.5, 6)
  })

  it('dos bonificaciones con el mismo efecto: ambigua, y NO elige una', () => {
    // Los dos repartos son idénticos, así que "baja la primera" y "baja la
    // segunda" dan exactamente el mismo impuesto interno. La factura no alcanza.
    const r = resolverBasesII(
      [linea()],
      [bonif({ id: 1 }), bonif({ id: 2, concepto: 'Otra' })],
      { 10: 80 }
    )
    expect(r.estado).toBe('ambigua')
    expect(r.soluciones).toHaveLength(2)
    expect(r.soluciones.map(s => s.asignacion)).toEqual(
      expect.arrayContaining([{ 1: true, 2: false }, { 1: false, 2: true }])
    )
  })

  it('ninguna hipotesis cierra: lo dice, no devuelve la menos mala', () => {
    // 90 no es ni 100 (no baja) ni 80 (baja): las dos se van por 10 pesos.
    const r = resolverBasesII([linea()], [bonif()], { 10: 90 })
    expect(r.estado).toBe('sin_solucion')
    expect(r.soluciones).toEqual([])
  })

  it('un cargo NO gravado no es candidato: no puede mover la base', () => {
    // El motor lee `gravado(c) && afectaBaseII`, así que prenderle el flag a un
    // no gravado no cambia nada y sólo duplicaría las hipótesis.
    const r = resolverBasesII(
      [linea()],
      [bonif({ condicionIva: 'no_gravado' })],
      { 10: 100 }
    )
    expect(r.candidatos).toEqual([])
    expect(r.estado).toBe('unica')
    expect(r.soluciones[0].asignacion).toEqual({})
  })

  it('un cargo gravado que no toca ninguna linea con II es indeterminable', () => {
    // Su efecto sobre la única alícuota declarada es exactamente 0: con él
    // adentro toda solución vendría duplicada y el resultado sería "ambigua"
    // para siempre.
    const conII = linea({ id: 1 })
    const sinII = linea({ id: 2, impuestosInternos: 0 })
    const r = resolverBasesII(
      [conII, sinII],
      [bonif({ id: 9, pesos: { 1: 0, 2: 1 } })],
      { 10: 100 }
    )
    expect(r.indeterminables).toEqual([9])
    expect(r.candidatos).toEqual([])
    expect(r.estado).toBe('unica')
  })

  it('el indeterminable conserva el valor que traia, no se lo inventa', () => {
    const conII = linea({ id: 1 })
    const sinII = linea({ id: 2, impuestosInternos: 0 })
    const cargos = [bonif({ id: 9, pesos: { 1: 0, 2: 1 }, afectaBaseII: true })]
    const r = resolverBasesII([conII, sinII], cargos, { 10: 100 })
    // No aparece en ninguna asignación: sobre él el solver no dice nada.
    expect(r.soluciones[0].asignacion).toEqual({})
    expect(cargos[0].afectaBaseII).toBe(true)
  })

  it('sin declaracion no hay ecuacion que resolver', () => {
    expect(resolverBasesII([linea()], [bonif()], {}).estado).toBe('sin_datos')
  })

  it('una alicuota declarada que ninguna linea tiene NO es una ecuacion', () => {
    // Si contara, el calculado daría 0 y cualquier hipótesis cerraría o fallaría
    // por el declarado entero, sin haber demostrado nada sobre esa alícuota.
    const r = resolverBasesII([linea()], [bonif()], { 21: 5000 })
    expect(r.alicuotas).toEqual([])
    expect(r.estado).toBe('sin_datos')
  })

  it('mas de MAX_CARGOS_BASE_II candidatos: avisa en vez de adivinar', () => {
    const grande = linea({ cantidad: 1000 })  // neto 100.000, II 10.000
    const muchos = Array.from({ length: MAX_CARGOS_BASE_II + 1 }, (_, i) =>
      bonif({ id: i + 1, monto: -1000 }))    // efecto 100 c/u, muy por encima de la tolerancia
    const r = resolverBasesII([grande], muchos, { 10: 10_000 })
    expect(r.estado).toBe('demasiadas_hipotesis')
    expect(r.candidatos).toHaveLength(MAX_CARGOS_BASE_II + 1)
    expect(r.soluciones).toEqual([])
  })

  it('todas las alicuotas declaradas tienen que cerrar a la vez, no una sola', () => {
    // Un flag es UNO para toda la factura: una hipótesis que cuadra el 10% pero
    // rompe el 5% no es solución. La bonificación cae sobre las dos líneas.
    const a = linea({ id: 1, impuestosInternos: 10 })
    const b = linea({ id: 2, impuestosInternos: 5 })
    const cargo = bonif({ pesos: { 1: 1, 2: 1 } })  // −100 a cada una
    // Bajando la base: 10% sobre 900 = 90 y 5% sobre 900 = 45.
    expect(resolverBasesII([a, b], [cargo], { 10: 90, 5: 45 }).estado).toBe('unica')
    // El 10% cierra con "baja" y el 5% con "no baja": ninguna hipótesis sirve.
    expect(resolverBasesII([a, b], [cargo], { 10: 90, 5: 50 }).estado).toBe('sin_solucion')
  })

  it('la tolerancia tiene piso absoluto y parte relativa', () => {
    expect(toleranciaII(100)).toBe(TOLERANCIA_II_PISO)        // 0,05% = 0,05 → manda el piso
    expect(toleranciaII(338_884.46)).toBeCloseTo(169.44, 2)   // manda la relativa
    expect(toleranciaII(-338_884.46)).toBeCloseTo(169.44, 2)  // por magnitud, no por signo
  })
})
