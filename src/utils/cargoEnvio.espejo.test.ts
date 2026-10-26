import { describe, it, expect } from 'vitest'
import fixture from './cargoEnvio.espejo.json'
import {
  cargoDesglose,
  cargoEnvioPedido,
  cargoTrasEdicion,
  type CargoEnvioEstado,
  type DecisionEnvio,
  type ReglaMinimoPedido,
} from './montoMinimo'

/**
 * PARIDAD DEL CARGO DE ENVÍO, lado TypeScript.
 *
 * El server decide el cargo al crear y al editar el pedido
 * (`cargo_envio_pedido`, `cargo_desglose` y `cargo_tras_edicion`, migración
 * `cargo_1_base`); el front lo anticipa con las mismas reglas para avisar antes
 * de confirmar. Si difieren, el total que ve el preventista no es el que
 * guarda la base. Este archivo corre las tres puras del front sobre
 * `cargoEnvio.espejo.json`; el gate del SQL corre las suyas sobre los mismos
 * casos. Si cambia uno, cambia el otro y se suma el caso.
 */

interface ReglaEspejo {
  modo: 'bloquear' | 'cargo' | 'escalas'
  monto_minimo: number
  monto_envio_gratis: number
  cargo_envio: number
}

interface CasoPedido { caso: string; total: number; regla: ReglaEspejo; esperado: number }
interface CasoDesglose { caso: string; cargo: number; tipo_factura: string | null; esperado: { neto: number; iva: number } }
interface CasoEdicion {
  caso: string
  estado: CargoEnvioEstado
  cargo_actual: number
  total_viejo: number
  total_nuevo: number
  regla: ReglaEspejo
  es_preventista: boolean
  decision: DecisionEnvio | null
  esperado: { cargo: number; estado: CargoEnvioEstado; requiere_decision: boolean }
}

const casos = fixture as unknown as {
  cargo_envio_pedido: CasoPedido[]
  desglose: CasoDesglose[]
  tras_edicion: CasoEdicion[]
}

const reglaDe = (r: ReglaEspejo): ReglaMinimoPedido => ({
  modo: r.modo,
  montoMinimo: r.monto_minimo,
  montoEnvioGratis: r.monto_envio_gratis,
  cargoEnvio: r.cargo_envio,
})

describe('espejo del cargo de envío: cargo del alta', () => {
  it.each(casos.cargo_envio_pedido.map(c => [c.caso, c] as const))('%s', (_n, c) => {
    expect(cargoEnvioPedido(c.total, reglaDe(c.regla))).toBe(c.esperado)
  })
})

describe('espejo del cargo de envío: desglose', () => {
  it.each(casos.desglose.map(c => [c.caso, c] as const))('%s', (_n, c) => {
    expect(cargoDesglose(c.cargo, c.tipo_factura)).toEqual(c.esperado)
  })
})

describe('espejo del cargo de envío: tras editar', () => {
  it.each(casos.tras_edicion.map(c => [c.caso, c] as const))('%s', (_n, c) => {
    const r = cargoTrasEdicion({
      estado: c.estado,
      cargoActual: c.cargo_actual,
      totalViejo: c.total_viejo,
      totalNuevo: c.total_nuevo,
      regla: reglaDe(c.regla),
      esPreventista: c.es_preventista,
      decision: c.decision,
    })
    expect(r).toEqual({
      cargo: c.esperado.cargo,
      estado: c.esperado.estado,
      requiereDecision: c.esperado.requiere_decision,
    })
  })
})

describe('espejo del cargo de envío: el fixture', () => {
  it('no repite nombres de caso', () => {
    const nombres = [...casos.cargo_envio_pedido, ...casos.desglose, ...casos.tras_edicion].map(c => c.caso)
    expect(new Set(nombres).size).toBe(nombres.length)
  })
})
