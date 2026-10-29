import { describe, it, expect } from 'vitest'
import {
  armarCombos, cantidadDeCombos, precioRepartible, prorratearCombo, prorratearTotal, totalDelCombo,
  type ComboVigente, type OraculoPrecios,
} from './combos'

const FERNET = '1'
const COCA = '2'
const SPRITE = '3'
const HIELO = '4'

const LISTA: Record<string, number> = { [FERNET]: 10000, [COCA]: 2500, [SPRITE]: 2500, [HIELO]: 1000 }

/** Lista pelada: sin escalas ni descuento. */
const oraculoLista: OraculoPrecios = {
  precioLibre: p => LISTA[p],
  precioSinEscala: p => LISTA[p],
}

/** Coca a $2.000 desde 48 unidades contadas para la escala. */
function oraculoConEscala(cantidades: Map<string, number>): OraculoPrecios {
  return {
    precioLibre: (p, excluidas) => {
      if (p !== COCA) return LISTA[p]
      const contadas = (cantidades.get(COCA) ?? 0) - (excluidas.get(COCA) ?? 0)
      return contadas >= 48 ? 2000 : LISTA[COCA]
    },
    precioSinEscala: p => LISTA[p],
  }
}

function combo(parcial: Partial<ComboVigente> & Pick<ComboVigente, 'id' | 'precio' | 'componentes'>): ComboVigente {
  return { nombre: `Combo ${parcial.id}`, combinaEscalas: false, prioridad: 0, topeRestante: null, ...parcial }
}

const fernetCoca = combo({
  id: '10',
  precio: 11000,
  componentes: [
    { componente: 1, cantidad: 1, productos: [FERNET] },
    { componente: 2, cantidad: 1, productos: [COCA] },
  ],
})

const dosCocaUnFernet = combo({
  id: '11',
  precio: 14000,
  componentes: [
    { componente: 1, cantidad: 2, productos: [COCA] },
    { componente: 2, cantidad: 1, productos: [FERNET] },
  ],
})

const total = (r: ReturnType<typeof armarCombos>) =>
  r.aplicados.reduce((s, a) => s + a.lineas.reduce((t, l) => t + l.cantidad * l.precioUnitario, 0), 0)

describe('prorratearCombo', () => {
  it('1 + 1 a $11.000: 80% / 20%', () => {
    const p = prorratearCombo(11000, 1, [
      { productoId: FERNET, cantidad: 1, ref: 10000 },
      { productoId: COCA, cantidad: 1, ref: 2500 },
    ])
    expect(p.get(FERNET)).toBe(8800)
    expect(p.get(COCA)).toBe(2200)
  })

  it('2 + 1 a $14.000: el centavo va al componente de cantidad 1', () => {
    const p = prorratearCombo(14000, 1, [
      { productoId: COCA, cantidad: 2, ref: 2500 },
      { productoId: FERNET, cantidad: 1, ref: 10000 },
    ])
    expect(p.get(COCA)).toBe(2333.33)
    expect(p.get(FERNET)).toBe(9333.34)
  })

  it('el total da exacto para cualquier cantidad de combos', () => {
    for (const k of [1, 2, 3, 7, 25]) {
      const p = prorratearCombo(14000, k, [
        { productoId: COCA, cantidad: 2 * k, ref: 2500 },
        { productoId: FERNET, cantidad: k, ref: 10000 },
      ])
      const t = 2 * k * (p.get(COCA) as number) + k * (p.get(FERNET) as number)
      expect(Math.round(t * 100)).toBe(1400000 * k)
    }
  })

  it('un lugar con alternativas de distinto precio reparte por referencia', () => {
    const p = prorratearCombo(11000, 2, [
      { productoId: FERNET, cantidad: 2, ref: 10000 },
      { productoId: COCA, cantidad: 1, ref: 2500 },
      { productoId: SPRITE, cantidad: 1, ref: 2400 },
    ])
    const t = 2 * (p.get(FERNET) as number) + (p.get(COCA) as number) + (p.get(SPRITE) as number)
    expect(Math.round(t * 100)).toBe(2200000)
    expect(p.get(COCA) as number).toBeGreaterThan(p.get(SPRITE) as number)
  })

  it('rechaza una cantidad de combos que no es entera positiva', () => {
    expect(() => prorratearCombo(100, 0, [{ productoId: COCA, cantidad: 1, ref: 10 }])).toThrow()
  })
})

describe('prorratearTotal: cierra exacto aunque ningún lugar tenga cantidad 1 (#1259)', () => {
  const cobrado = (p: Map<string, number>, lineas: { productoId: string; cantidad: number }[]) =>
    lineas.reduce((s, l) => s + l.cantidad * Math.round((p.get(l.productoId) as number) * 100), 0)

  it('2 + 3 a $1.000,01 cobra $1.000,01, no $1.000,00', () => {
    const lineas = [
      { productoId: COCA, cantidad: 2, ref: 250 },
      { productoId: SPRITE, cantidad: 3, ref: 200 },
    ]
    expect(cobrado(prorratearTotal(1000.01, lineas), lineas)).toBe(100001)
  })

  it('un lugar de 10 partido entre alternativas (4 + 6) también cierra', () => {
    // Lugar 1: 10 de Coca o Sprite; lugar 2: 10 de Hielo. El precio es múltiplo
    // de 10 centavos (lo exige guardar_combo), pero ninguna línea sola divide el resto.
    const lineas = [
      { productoId: COCA, cantidad: 4, ref: 250 },
      { productoId: SPRITE, cantidad: 6, ref: 240 },
      { productoId: HIELO, cantidad: 10, ref: 100 },
    ]
    expect(cobrado(prorratearTotal(2500.3, lineas), lineas)).toBe(250030)
  })

  it('6 + 10 + 15: el resto no lo divide ninguna línea sola, pero cierra', () => {
    const lineas = [
      { productoId: COCA, cantidad: 6, ref: 300 },
      { productoId: SPRITE, cantidad: 10, ref: 200 },
      { productoId: HIELO, cantidad: 15, ref: 100 },
    ]
    for (const t of [4000.01, 4000.07, 3999.99, 4321.23]) {
      expect(cobrado(prorratearTotal(t, lineas), lineas)).toBe(Math.round(t * 100))
    }
  })

  it('el reparto exacto no se aleja más de unos centavos de la proporción', () => {
    const lineas = [
      { productoId: COCA, cantidad: 2, ref: 250 },
      { productoId: SPRITE, cantidad: 3, ref: 200 },
    ]
    const p = prorratearTotal(1000.01, lineas)
    expect(Math.abs((p.get(COCA) as number) - 227.27)).toBeLessThan(0.05)
    expect(Math.abs((p.get(SPRITE) as number) - 181.82)).toBeLessThan(0.05)
  })

  it('barrido: con el mcd de las cantidades dividiendo el total, siempre cierra y no se aleja de la proporción', () => {
    let semilla = 1259
    const azar = (n: number) => {
      semilla = (semilla * 1103515245 + 12345) % 2147483648
      return semilla % n
    }
    for (let caso = 0; caso < 2000; caso++) {
      const n = 1 + azar(4)
      const lineas = Array.from({ length: n }, (_, i) => ({
        productoId: String(i + 1),
        cantidad: 1 + azar(24),
        ref: (100 + azar(50000)) / 100,
      }))
      const g = lineas.reduce((m, l) => { let [a, b] = [m, l.cantidad]; while (b) [a, b] = [b, a % b]; return a }, 0)
      const ref = lineas.reduce((s, l) => s + l.cantidad * Math.round(l.ref * 100), 0)
      // Entre el 50 % y el 100 % de lo que costaría suelto, múltiplo del mcd.
      const t = (Math.floor((ref / 2 + azar(Math.floor(ref / 2))) / g) || 1) * g
      const p = prorratearTotal(t / 100, lineas)
      expect(cobrado(p, lineas)).toBe(t)
      for (const l of lineas) {
        const proporcional = (t * Math.round(l.ref * 100)) / ref
        // Unos centavos por unidad, nunca más que el resto repartido.
        expect(Math.abs(Math.round((p.get(l.productoId) as number) * 100) - proporcional)).toBeLessThanOrEqual(30)
      }
    }
  })

  it('"2 por $999,99" no se puede repartir exacto: falla en vez de cobrar $999,98', () => {
    expect(() => prorratearTotal(999.99, [{ productoId: COCA, cantidad: 2, ref: 600 }])).toThrow()
  })
})

describe('precioRepartible', () => {
  it('true si el máximo común divisor de las cantidades divide el precio en centavos', () => {
    expect(precioRepartible(999.98, [2])).toBe(true)
    expect(precioRepartible(1000.01, [2, 3])).toBe(true)
    expect(precioRepartible(11000, [1, 1])).toBe(true)
  })

  it('false para "2 por $999,99" o un 4 + 6 a precio impar', () => {
    expect(precioRepartible(999.99, [2])).toBe(false)
    expect(precioRepartible(1000.01, [4, 6])).toBe(false)
  })
})

describe('totalDelCombo', () => {
  it('excluyente: k × precio', () => {
    expect(totalDelCombo(11000, 3, [{ productoId: FERNET, cantidad: 3, ref: 10000 }])).toBe(33000)
  })

  it('acumulable: resta lo que la escala ya bajó', () => {
    expect(totalDelCombo(11000, 2, [
      { productoId: FERNET, cantidad: 2, ref: 10000, sinEscala: 10000 },
      { productoId: COCA, cantidad: 2, ref: 2000, sinEscala: 2500 },
    ])).toBe(21000)
  })
})

describe('cantidadDeCombos', () => {
  it('cuenta los combos de un 2 + 1', () => {
    expect(cantidadDeCombos(dosCocaUnFernet.componentes, new Map([[COCA, 4], [FERNET, 2]]))).toBe(2)
  })

  it('null si un lugar no completa', () => {
    expect(cantidadDeCombos(dosCocaUnFernet.componentes, new Map([[COCA, 3], [FERNET, 2]]))).toBeNull()
  })

  it('null si los lugares dan distinta cantidad', () => {
    expect(cantidadDeCombos(fernetCoca.componentes, new Map([[COCA, 2], [FERNET, 1]]))).toBeNull()
  })

  it('null si hay un producto que no es del combo', () => {
    expect(cantidadDeCombos(fernetCoca.componentes, new Map([[COCA, 1], [FERNET, 1], [HIELO, 1]]))).toBeNull()
  })

  it('suma las alternativas de un mismo lugar', () => {
    const c = [
      { componente: 1, cantidad: 1, productos: [FERNET] },
      { componente: 2, cantidad: 2, productos: [COCA, SPRITE] },
    ]
    expect(cantidadDeCombos(c, new Map([[FERNET, 2], [COCA, 3], [SPRITE, 1]]))).toBe(2)
  })
})

describe('armarCombos', () => {
  it('5 Coca + 2 Fernet con un 2 + 1: dos combos y una Coca suelta', () => {
    const r = armarCombos(new Map([[COCA, 5], [FERNET, 2]]), [dosCocaUnFernet], oraculoLista)
    expect(r.aplicados).toHaveLength(1)
    expect(r.aplicados[0].cantidadCombos).toBe(2)
    expect(r.sueltas.get(COCA)).toBe(1)
    expect(r.sueltas.has(FERNET)).toBe(false)
    expect(Math.round(total(r) * 100)).toBe(2800000)
  })

  it('sin todos los componentes no arma nada', () => {
    const r = armarCombos(new Map([[FERNET, 3]]), [fernetCoca], oraculoLista)
    expect(r.aplicados).toHaveLength(0)
    expect(r.sueltas.get(FERNET)).toBe(3)
  })

  it('un precio fijo que no baja el total no se aplica', () => {
    const caro = { ...fernetCoca, precio: 12500 }
    expect(armarCombos(new Map([[FERNET, 1], [COCA, 1]]), [caro], oraculoLista).aplicados).toHaveLength(0)
  })

  it('el tope corta la cantidad de combos', () => {
    const r = armarCombos(new Map([[FERNET, 5], [COCA, 5]]), [{ ...fernetCoca, topeRestante: 2 }], oraculoLista)
    expect(r.aplicados[0].cantidadCombos).toBe(2)
    expect(r.sueltas.get(FERNET)).toBe(3)
  })

  it('excluyente: con 48 Coca a mayorista no arma el combo (perdería la escala)', () => {
    const carrito = new Map([[COCA, 48], [FERNET, 1]])
    const r = armarCombos(carrito, [fernetCoca], oraculoConEscala(carrito))
    expect(r.aplicados).toHaveLength(0)
  })

  it('excluyente: con 60 Coca sí arma, y la Coca del combo va contra la lista', () => {
    const carrito = new Map([[COCA, 60], [FERNET, 1]])
    const r = armarCombos(carrito, [fernetCoca], oraculoConEscala(carrito))
    expect(r.aplicados[0].cantidadCombos).toBe(1)
    const coca = r.aplicados[0].lineas.find(l => l.productoId === COCA)
    expect(coca?.precioSinCombo).toBe(2500)
    expect(r.excluidas.get(COCA)).toBe(1)
  })

  it('acumulable: la Coca del combo toma la escala y el descuento se suma ($10.500)', () => {
    const carrito = new Map([[COCA, 48], [FERNET, 1]])
    const acumulable = { ...fernetCoca, combinaEscalas: true }
    const r = armarCombos(carrito, [acumulable], oraculoConEscala(carrito))
    expect(r.aplicados[0].cantidadCombos).toBe(1)
    const coca = r.aplicados[0].lineas.find(l => l.productoId === COCA)
    expect(coca?.precioSinCombo).toBe(2000)
    expect(coca?.precioSinEscala).toBe(2500)
    // 11.000 − (2.500 − 2.000): el descuento del combo encima de la escala.
    expect(Math.round(total(r) * 100)).toBe(1050000)
    expect(r.excluidas.size).toBe(0)
  })

  it('excluyente: las líneas no llevan precio sin escala', () => {
    const r = armarCombos(new Map([[FERNET, 1], [COCA, 1]]), [fernetCoca], oraculoLista)
    expect(r.aplicados[0].lineas.every(l => l.precioSinEscala === null)).toBe(true)
  })

  it('la prioridad decide entre dos combos que comparten un producto', () => {
    const fernetHielo = combo({
      id: '12',
      precio: 10500,
      prioridad: 5,
      componentes: [
        { componente: 1, cantidad: 1, productos: [FERNET] },
        { componente: 2, cantidad: 1, productos: [HIELO] },
      ],
    })
    const r = armarCombos(new Map([[FERNET, 1], [COCA, 1], [HIELO, 1]]), [fernetCoca, fernetHielo], oraculoLista)
    expect(r.aplicados.map(a => a.comboId)).toEqual(['12'])
  })

  it('a igual prioridad gana el que más ahorra', () => {
    const fernetHielo = combo({
      id: '12',
      precio: 10900,
      componentes: [
        { componente: 1, cantidad: 1, productos: [FERNET] },
        { componente: 2, cantidad: 1, productos: [HIELO] },
      ],
    })
    // Fernet+Coca ahorra 1.500; Fernet+Hielo, 100.
    const r = armarCombos(new Map([[FERNET, 1], [COCA, 1], [HIELO, 1]]), [fernetHielo, fernetCoca], oraculoLista)
    expect(r.aplicados.map(a => a.comboId)).toEqual(['10'])
  })

  describe('un excluyente que sólo conviene completo (#1259)', () => {
    // A a $100, $90 desde 12 unidades contadas para la escala; B a $100. Combo
    // A + B excluyente a $150. Sacar la primera A del conteo le hace perder la
    // escala a todas las demás: una instancia sola no conviene, todas sí.
    const A = '5'
    const B = '6'
    const oraculoAB = (carrito: Map<string, number>): OraculoPrecios => ({
      precioLibre: (p, excluidas) =>
        p === A && (carrito.get(A) ?? 0) - (excluidas.get(A) ?? 0) >= 12 ? 90 : 100,
      precioSinEscala: () => 100,
    })
    const ab = combo({
      id: '20',
      precio: 150,
      componentes: [
        { componente: 1, cantidad: 1, productos: [A] },
        { componente: 2, cantidad: 1, productos: [B] },
      ],
    })
    const totalPedido = (r: ReturnType<typeof armarCombos>, o: OraculoPrecios) =>
      total(r) + [...r.sueltas].reduce((s, [p, q]) => s + q * o.precioLibre(p, r.excluidas), 0)

    it('12 A + 12 B: arma los 12 combos y cobra $1.800, no $2.280', () => {
      const carrito = new Map([[A, 12], [B, 12]])
      const o = oraculoAB(carrito)
      const r = armarCombos(carrito, [ab], o)
      expect(r.aplicados[0]?.cantidadCombos).toBe(12)
      expect(totalPedido(r, o)).toBe(1800)
    })

    it('12 A + 6 B: arma 6 combos y cobra $1.500, no $1.680', () => {
      const carrito = new Map([[A, 12], [B, 6]])
      const o = oraculoAB(carrito)
      const r = armarCombos(carrito, [ab], o)
      expect(r.aplicados[0]?.cantidadCombos).toBe(6)
      expect(totalPedido(r, o)).toBe(1500)
    })

    it('con el tope en 2 no llega a convenir ($2.300 contra $2.280) y no arma ninguno', () => {
      const carrito = new Map([[A, 12], [B, 12]])
      const r = armarCombos(carrito, [{ ...ab, topeRestante: 2 }], oraculoAB(carrito))
      expect(r.aplicados).toHaveLength(0)
    })

    it('con el tope en 3 ya conviene: 3 combos, $2.250', () => {
      const carrito = new Map([[A, 12], [B, 12]])
      const o = oraculoAB(carrito)
      const r = armarCombos(carrito, [{ ...ab, topeRestante: 3 }], o)
      expect(r.aplicados[0]?.cantidadCombos).toBe(3)
      expect(totalPedido(r, o)).toBe(2250)
    })
  })

  it('no arma un combo cuyo precio no se puede repartir exacto ("2 por $999,99")', () => {
    const dosPor = combo({ id: '21', precio: 999.99, componentes: [{ componente: 1, cantidad: 2, productos: [FERNET] }] })
    const r = armarCombos(new Map([[FERNET, 2]]), [dosPor], oraculoLista)
    expect(r.aplicados).toHaveLength(0)
    expect(r.sueltas.get(FERNET)).toBe(2)
  })

  it('un lugar con alternativas se llena con las unidades más caras', () => {
    const conAlternativas = combo({
      id: '13',
      precio: 11000,
      componentes: [
        { componente: 1, cantidad: 1, productos: [FERNET] },
        { componente: 2, cantidad: 1, productos: [HIELO, COCA] },
      ],
    })
    const r = armarCombos(new Map([[FERNET, 1], [COCA, 1], [HIELO, 1]]), [conAlternativas], oraculoLista)
    expect(r.aplicados[0].lineas.map(l => l.productoId)).toEqual([FERNET, COCA])
    expect(r.sueltas.get(HIELO)).toBe(1)
  })
})
