/**
 * Tests de la compra mínima por pedido.
 *
 * POR QUE ESTOS CASOS
 * -------------------
 * La regla vive en la base (`pedido_incumple_minimo`, mig 205) y acá se espeja
 * para poder bloquear ANTES de confirmar. Si las dos se desalinean, el síntoma
 * es el peor posible: el pedido se acepta en el teléfono sin señal y falla al
 * sincronizar, horas después, lejos del cliente.
 *
 * El caso del 0 es el que más importa: es el estado con el que la política
 * arranca en todas las sucursales (mig 204). Si 0 frenara pedidos, aplicar la
 * migración cortaría la operación entera de una.
 */
import { describe, it, expect } from 'vitest'
import {
  cumpleMontoMinimo,
  motivoMontoMinimo,
  motivoRechazoMinimo,
  cargoEnvioPedido,
  faltanteParaEnvioGratis,
  franjaCargo,
  umbralEnvioGratis,
  politicaCobraCargo,
  cargoTrasEdicion,
  cargoDesglose,
  ventaDePedido,
  REGLA_MINIMO_POR_DEFECTO,
  type ReglaMinimoPedido,
} from './montoMinimo'

describe('cumpleMontoMinimo', () => {
  it('mínimo 0 = sin política: no frena nada', () => {
    // Es el estado inicial de todas las sucursales tras la mig 204.
    expect(cumpleMontoMinimo(0, 0)).toBe(true)
    expect(cumpleMontoMinimo(1, 0)).toBe(true)
    expect(cumpleMontoMinimo(999999, 0)).toBe(true)
  })

  it('deja pasar el pedido que da exactamente el mínimo', () => {
    expect(cumpleMontoMinimo(10000, 10000)).toBe(true)
  })

  it('frena por debajo y deja pasar por encima', () => {
    expect(cumpleMontoMinimo(9999.99, 10000)).toBe(false)
    expect(cumpleMontoMinimo(10000.01, 10000)).toBe(true)
  })

  it('trata un total no numérico como 0, no como "pasa"', () => {
    expect(cumpleMontoMinimo(NaN, 10000)).toBe(false)
  })

  it('un mínimo inválido no frena: ante la duda, no cortar la operación', () => {
    expect(cumpleMontoMinimo(500, NaN)).toBe(true)
    expect(cumpleMontoMinimo(500, -1)).toBe(true)
  })
})

describe('motivoMontoMinimo', () => {
  it('devuelve null cuando el pedido cumple', () => {
    expect(motivoMontoMinimo(10000, 10000)).toBeNull()
    expect(motivoMontoMinimo(500, 0)).toBeNull()
  })

  it('dice el mínimo y cuánto falta', () => {
    const motivo = motivoMontoMinimo(7500, 10000)
    expect(motivo).toContain('10.000')
    expect(motivo).toContain('2.500')
  })
})

describe('cargo de envío bajo el mínimo (mig 389, #1220)', () => {
  const bloquear: ReglaMinimoPedido = { modo: 'bloquear', montoMinimo: 10000, montoEnvioGratis: 0, cargoEnvio: 0 }
  const cargo: ReglaMinimoPedido = { modo: 'cargo', montoMinimo: 10000, montoEnvioGratis: 0, cargoEnvio: 1500 }
  const escalas: ReglaMinimoPedido = { modo: 'escalas', montoMinimo: 10000, montoEnvioGratis: 20000, cargoEnvio: 1500 }

  it('arranca sin política: ni rechaza ni cobra', () => {
    expect(motivoRechazoMinimo(1, REGLA_MINIMO_POR_DEFECTO)).toBeNull()
    expect(cargoEnvioPedido(1, REGLA_MINIMO_POR_DEFECTO)).toBe(0)
  })

  it('bloquear: rechaza bajo el mínimo y nunca cobra envío', () => {
    expect(motivoRechazoMinimo(9999, bloquear)).toContain('10.000')
    expect(motivoRechazoMinimo(10000, bloquear)).toBeNull()
    // Aunque haya un cargo guardado de un modo anterior: bloquear no lo cobra.
    expect(cargoEnvioPedido(9999, { ...bloquear, cargoEnvio: 1500 })).toBe(0)
  })

  it('cargo: no rechaza nunca; cobra bajo el mínimo y desde el mínimo no', () => {
    expect(motivoRechazoMinimo(1, cargo)).toBeNull()
    expect(cargoEnvioPedido(9999.99, cargo)).toBe(1500)
    expect(cargoEnvioPedido(10000, cargo)).toBe(0)
  })

  it('cargo con mínimo 0: sin umbral, no cobra', () => {
    expect(cargoEnvioPedido(1, { ...cargo, montoMinimo: 0 })).toBe(0)
  })

  it('escalas: bajo xx rechaza, entre xx y xxx cobra, desde xxx nada', () => {
    expect(motivoRechazoMinimo(9999, escalas)).not.toBeNull()
    expect(cargoEnvioPedido(9999, escalas)).toBe(0)

    expect(motivoRechazoMinimo(10000, escalas)).toBeNull()
    expect(cargoEnvioPedido(10000, escalas)).toBe(1500)
    expect(cargoEnvioPedido(19999.99, escalas)).toBe(1500)

    expect(motivoRechazoMinimo(20000, escalas)).toBeNull()
    expect(cargoEnvioPedido(20000, escalas)).toBe(0)
  })

  it('cargo 0 no cobra nada en ningún modo', () => {
    expect(cargoEnvioPedido(1, { ...cargo, cargoEnvio: 0 })).toBe(0)
    expect(cargoEnvioPedido(10000, { ...escalas, cargoEnvio: 0 })).toBe(0)
  })

  it('dice cuánto falta para no pagar envío', () => {
    expect(faltanteParaEnvioGratis(9000, cargo)).toBe(1000)
    expect(faltanteParaEnvioGratis(12000, escalas)).toBe(8000)
    expect(faltanteParaEnvioGratis(25000, escalas)).toBeNull()
    expect(faltanteParaEnvioGratis(9000, bloquear)).toBeNull()
  })
})

describe('cargo de envío: edición, desglose y venta sin cargo', () => {
  const R: ReglaMinimoPedido = { modo: 'escalas', montoMinimo: 5000, montoEnvioGratis: 15000, cargoEnvio: 500 }
  const C: ReglaMinimoPedido = { modo: 'cargo', montoMinimo: 15000, montoEnvioGratis: 0, cargoEnvio: 500 }
  const B: ReglaMinimoPedido = { modo: 'bloquear', montoMinimo: 15000, montoEnvioGratis: 0, cargoEnvio: 500 }

  const base = {
    estado: 'cobrado' as const,
    cargoActual: 500,
    totalViejo: 12000,
    totalNuevo: 16000,
    regla: R,
    esPreventista: false,
    decision: null,
  }

  it('un pedido sin productos no paga envío', () => {
    expect(cargoEnvioPedido(0, C)).toBe(0)
  })

  it('el umbral depende del modo', () => {
    expect(umbralEnvioGratis(C)).toBe(15000)
    expect(umbralEnvioGratis(R)).toBe(15000)
    expect(umbralEnvioGratis(B)).toBe(0)
  })

  it('la política cobra sólo en cargo/escalas con cargo y umbral', () => {
    expect(politicaCobraCargo(R)).toBe(true)
    expect(politicaCobraCargo(C)).toBe(true)
    expect(politicaCobraCargo(B)).toBe(false)
    expect(politicaCobraCargo({ ...R, cargoEnvio: 0 })).toBe(false)
    expect(politicaCobraCargo({ ...C, montoMinimo: 0 })).toBe(false)
  })

  it('franja: el umbral exacto ya es arriba, el 0 es arriba', () => {
    expect(franjaCargo(14999.99, R)).toBe('debajo')
    expect(franjaCargo(15000, R)).toBe('arriba')
    expect(franjaCargo(0, C)).toBe('arriba')
    expect(franjaCargo(1, C)).toBe('debajo')
  })

  it('desglose: FC con IVA 21 %, ZZ todo neto, VB nada', () => {
    expect(cargoDesglose(500, 'FC')).toEqual({ neto: 413.22, iva: 86.78 })
    expect(cargoDesglose(500, 'ZZ')).toEqual({ neto: 500, iva: 0 })
    expect(cargoDesglose(500, 'VB')).toEqual({ neto: 0, iva: 0 })
    expect(cargoDesglose(0, 'FC')).toEqual({ neto: 0, iva: 0 })
  })

  it('edición sin cruce de franja: conserva el cargo aunque el costo vigente haya subido', () => {
    const r = cargoTrasEdicion({ ...base, totalNuevo: 13000, regla: { ...R, cargoEnvio: 700 } })
    expect(r).toEqual({ cargo: 500, estado: 'cobrado', requiereDecision: false })
  })

  it('regla bloquear: no cambia nada ni pide decisión', () => {
    const r = cargoTrasEdicion({ ...base, regla: B })
    expect(r).toEqual({ cargo: 500, estado: 'cobrado', requiereDecision: false })
  })

  it('no_aplica nunca gana', () => {
    const r = cargoTrasEdicion({ ...base, estado: 'no_aplica', cargoActual: 0, totalViejo: 16000, totalNuevo: 12000 })
    expect(r).toEqual({ cargo: 0, estado: 'no_aplica', requiereDecision: false })
  })

  it('admin que cruza sin decidir: queda como está y pide decisión', () => {
    const r = cargoTrasEdicion(base)
    expect(r).toEqual({ cargo: 500, estado: 'cobrado', requiereDecision: true })
  })

  it('admin: cobrar agrega el envío al bajar y no_cobrar lo bonifica', () => {
    const baja = { ...base, estado: 'gratis' as const, cargoActual: 0, totalViejo: 16000, totalNuevo: 12000 }
    expect(cargoTrasEdicion({ ...baja, decision: 'cobrar' })).toEqual({ cargo: 500, estado: 'cobrado', requiereDecision: false })
    expect(cargoTrasEdicion({ ...baja, decision: 'no_cobrar' })).toEqual({ cargo: 0, estado: 'bonificado', requiereDecision: false })
  })

  it('admin: no_cobrar hacia arriba deja gratis; cobrar hacia arriba lo mantiene', () => {
    expect(cargoTrasEdicion({ ...base, decision: 'no_cobrar' })).toEqual({ cargo: 0, estado: 'gratis', requiereDecision: false })
    expect(cargoTrasEdicion({ ...base, decision: 'cobrar' })).toEqual({ cargo: 500, estado: 'cobrado', requiereDecision: false })
  })

  it('preventista: el server decide, su decisión se ignora', () => {
    const baja = { ...base, estado: 'gratis' as const, cargoActual: 0, totalViejo: 16000, totalNuevo: 12000, esPreventista: true }
    expect(cargoTrasEdicion({ ...baja, decision: 'no_cobrar' })).toEqual({ cargo: 500, estado: 'cobrado', requiereDecision: false })
    expect(cargoTrasEdicion({ ...baja, decision: null })).toEqual({ cargo: 500, estado: 'cobrado', requiereDecision: false })
    const sube = { ...base, esPreventista: true, decision: 'cobrar' as const }
    expect(cargoTrasEdicion(sube)).toEqual({ cargo: 0, estado: 'gratis', requiereDecision: false })
  })

  it('un pedido que queda sin productos nunca paga envío, decida quien decida', () => {
    const vacio = { ...base, totalNuevo: 0 }
    const gratis = { cargo: 0, estado: 'gratis', requiereDecision: false }
    expect(cargoTrasEdicion({ ...vacio, decision: 'cobrar' })).toEqual(gratis)
    expect(cargoTrasEdicion({ ...vacio, decision: null })).toEqual(gratis)
    expect(cargoTrasEdicion({ ...vacio, esPreventista: true })).toEqual(gratis)
    // Lo frenan antes un no_aplica o una política que no cobra.
    expect(cargoTrasEdicion({ ...vacio, estado: 'no_aplica', cargoActual: 0 }))
      .toEqual({ cargo: 0, estado: 'no_aplica', requiereDecision: false })
    expect(cargoTrasEdicion({ ...vacio, regla: B }))
      .toEqual({ cargo: 500, estado: 'cobrado', requiereDecision: false })
  })

  it('desglose: tipo null o desconocido se trata como ZZ', () => {
    expect(cargoDesglose(500, null)).toEqual({ neto: 500, iva: 0 })
    expect(cargoDesglose(500, undefined)).toEqual({ neto: 500, iva: 0 })
    expect(cargoDesglose(500, 'X')).toEqual({ neto: 500, iva: 0 })
  })

  it('bonificado sin cruce se conserva', () => {
    const r = cargoTrasEdicion({ ...base, estado: 'bonificado', cargoActual: 0, totalViejo: 12000, totalNuevo: 13000 })
    expect(r).toEqual({ cargo: 0, estado: 'bonificado', requiereDecision: false })
  })

  it('venta de productos = total sin el cargo, nunca negativa', () => {
    expect(ventaDePedido({ total: 12500, cargo_envio: 500 })).toBe(12000)
    expect(ventaDePedido({ total: 0, cargo_envio: 500 })).toBe(0)
    expect(ventaDePedido({ total: 12500 })).toBe(12500)
    expect(ventaDePedido({ total: 12500, cargo_envio: null })).toBe(12500)
  })
})
