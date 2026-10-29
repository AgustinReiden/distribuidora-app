/**
 * Estadísticas de un vehículo a partir de sus cargas de combustible y de su gasto.
 */
import { cuotaDelMes, mesDe, sumarMeses } from './gastos'
import type { Gasto } from '../types/gastos'

/**
 * Km por litro por el método del tanque lleno: la distancia entre la primera y
 * la última carga con km, sobre los litros de todas menos la primera (los de la
 * primera llenaron el tanque ANTES de empezar a medir). Con menos de dos cargas
 * no hay con qué medir. Redondea a 1 decimal.
 */
export function rendimientoKmPorLitro(
  cargas: Array<{ fecha: string; km: number; litros: number }>,
): number | null {
  if (cargas.length < 2) return null
  const ordenadas = [...cargas].sort((a, b) => a.fecha.localeCompare(b.fecha) || a.km - b.km)
  const primera = ordenadas[0]
  const ultima = ordenadas[ordenadas.length - 1]
  const litros = ordenadas.slice(1).reduce((s, c) => s + c.litros, 0)
  const km = ultima.km - primera.km
  if (litros <= 0 || km <= 0) return null
  return Math.round((km / litros) * 10) / 10
}

/** Costo por km recorrido; `null` si no hay km. */
export function costoPorKm(costo: number, km: number): number | null {
  if (!(km > 0)) return null
  return Math.round((costo / km) * 100) / 100
}

// ---------------------------------------------------------------------------
// Ficha del vehículo
// ---------------------------------------------------------------------------

export interface LecturaKm {
  fecha: string
  km: number
  origen: 'manual' | 'carga' | 'gps'
  gasto_id?: number | null
}

export interface FichaVehiculo {
  /** Lo que el vehículo aporta al resultado del mes. */
  gastoMes: number
  /** Suma de las cuotas de los últimos 12 meses (el mes actual incluido). */
  gasto12Meses: number
  /** Los últimos 6 meses, del más viejo al más nuevo. */
  meses: string[]
  /** Una fila por rubro: cuota por mes (en el orden de `meses`) y total. */
  porRubro: Array<{ rubro: string; porMes: number[]; total: number }>
  cargas: Array<{ fecha: string; litros: number; km: number | null; monto: number }>
  kmPorLitro: number | null
  costoKm: number | null
}

const round2 = (n: number): number => Math.round((n + Number.EPSILON) * 100) / 100

/**
 * Arma la ficha con lo que trae `useVehiculoFichaQuery`. El costo por km toma
 * el gasto de los meses que cubren las lecturas (de la primera a la última) y
 * los km entre ellas: lo mismo de los dos lados.
 */
export function armarFichaVehiculo(
  gastos: Gasto[],
  lecturas: LecturaKm[],
  mesActual: string,
): FichaVehiculo {
  const cuotaEn = (g: Gasto, mes: string): number => cuotaDelMes(g, mes)?.monto ?? 0
  const suma = (desde: string, hasta: string): number => {
    let total = 0
    for (let m = desde; m <= hasta; m = sumarMeses(m, 1)) {
      for (const g of gastos) total += cuotaEn(g, m)
    }
    return round2(total)
  }

  const meses = [5, 4, 3, 2, 1, 0].map(n => sumarMeses(mesActual, -n))
  const rubros = new Map<string, number[]>()
  for (const g of gastos) {
    const nombre = g.rubro?.nombre ?? 'Sin rubro'
    const fila = rubros.get(nombre) ?? meses.map(() => 0)
    meses.forEach((m, i) => { fila[i] = round2(fila[i] + cuotaEn(g, m)) })
    rubros.set(nombre, fila)
  }
  const porRubro = [...rubros.entries()]
    .map(([rubro, porMes]) => ({ rubro, porMes, total: round2(porMes.reduce((s, v) => s + v, 0)) }))
    .filter(r => r.total !== 0)
    .sort((a, b) => b.total - a.total)

  const cargas = gastos
    .filter(g => g.litros != null)
    .map(g => ({
      fecha: g.fecha,
      litros: g.litros as number,
      km: lecturas.find(l => l.gasto_id === g.id)?.km ?? null,
      monto: g.costo,
    }))
    .sort((a, b) => b.fecha.localeCompare(a.fecha))

  const kmPorLitro = rendimientoKmPorLitro(
    cargas.flatMap(c => (c.km != null ? [{ fecha: c.fecha, km: c.km, litros: c.litros }] : [])),
  )

  let costoKm: number | null = null
  const ordenadas = [...lecturas].sort((a, b) => a.fecha.localeCompare(b.fecha) || a.km - b.km)
  if (ordenadas.length >= 2) {
    const primera = ordenadas[0]
    const ultima = ordenadas[ordenadas.length - 1]
    costoKm = costoPorKm(suma(mesDe(primera.fecha), mesDe(ultima.fecha)), ultima.km - primera.km)
  }

  return {
    gastoMes: suma(mesActual, mesActual),
    gasto12Meses: suma(sumarMeses(mesActual, -11), mesActual),
    meses,
    porRubro,
    cargas,
    kmPorLitro,
    costoKm,
  }
}
