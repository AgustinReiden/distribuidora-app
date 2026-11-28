/**
 * Con qué porcentaje se calculó la comisión de una liquidación, y quién lo cargó (COM-1, D2 del
 * dueño del 26/11; T7 de #1677). Lo arma el server en `comisiones.porcentajes` de
 * `previsualizar_liquidacion` (`_liquidacion_json`): una fila por % (de una regla, o el % por
 * defecto del mes del pedido para el rol que el vendedor tenía al vender, COM-2).
 */
import { fechaCompleta } from './personal'

export interface PorcentajeComision {
  pct: number
  regla_id: number | null
  origen: 'regla' | 'por_defecto'
  /** Sólo en el % por defecto: el rol del vendedor al vender. */
  rol: 'preventista' | 'resto' | null
  /**
   * Quien dejó ese % y cuándo, de un mismo momento: el último alta o cambio del % de la regla
   * (o de la vigencia del % por defecto). `null` si lo cargó el sistema.
   */
  cargado_por: string | null
  cargado_el: string | null
  pedidos: number
  base: number
  comision: number
}

const pctTexto = (n: number): string => `${String(n).replace('.', ',')} %`

/** «3 % por defecto de preventista · lo cargó Ana el 01/11/2026 · 2 pedidos». */
export function textoPorcentajeComision(p: PorcentajeComision): string {
  const que = p.origen === 'regla'
    ? `${pctTexto(p.pct)} de una regla`
    : `${pctTexto(p.pct)} por defecto ${p.rol === 'preventista' ? 'de preventista' : 'del resto (admin, encargado)'}`
  const quien = p.cargado_por
    ? `lo cargó ${p.cargado_por}${p.cargado_el ? ` el ${fechaCompleta(p.cargado_el)}` : ''}`
    : 'lo cargó el sistema'
  const cuantos = `${p.pedidos} ${p.pedidos === 1 ? 'pedido' : 'pedidos'}`
  return `${que} · ${quien} · ${cuantos}`
}
