/**
 * Estadísticas de un vehículo a partir de sus cargas de combustible y de su gasto.
 */
import { cuotaDelMes, mesDe, sumarMeses } from './gastos'
import type { Gasto } from '../types/gastos'

/**
 * Km por litro por tramos entre lecturas consecutivas de cargas con km. Los litros
 * de un tramo son los de todas las cargas posteriores a la lectura de inicio hasta
 * la de fin, inclusive: las cargas sin km suman al tramo siguiente. Las cargas
 * anteriores a la primera lectura (llenaron el tanque antes de medir) y las
 * posteriores a la última (tramo sin cerrar) no cuentan. Una lectura que no avanza
 * respecto de la anterior se ignora: sus litros pasan al tramo siguiente. El resultado es la suma
 * de km de los tramos sobre la suma de sus litros, a 1 decimal; `null` si no hay
 * ningún tramo con km > 0 y litros > 0.
 *
 * Orden: por fecha; a igual fecha, por km, y las cargas sin km de ese día van antes
 * que las que sí tienen (se asume que se cargaron antes de la lectura del día).
 */
export function rendimientoKmPorLitro(
  cargas: Array<{ fecha: string; km: number | null; litros: number }>,
): number | null {
  const ordenadas = [...cargas].sort((a, b) =>
    a.fecha.localeCompare(b.fecha)
    || (a.km == null ? 0 : 1) - (b.km == null ? 0 : 1)
    || (a.km ?? 0) - (b.km ?? 0),
  )
  let kmInicio: number | null = null
  let litrosTramo = 0
  let kmTotal = 0
  let litrosTotal = 0
  for (const c of ordenadas) {
    if (kmInicio == null) {
      if (c.km != null) kmInicio = c.km
      continue
    }
    litrosTramo += c.litros
    if (c.km == null) continue
    const km = c.km - kmInicio
    // Una lectura que no avanza está mal cargada (o repite la anterior): se
    // ignora y se sigue midiendo desde la última buena, con sus litros en el
    // tramo. Reiniciar la base en ella inflaría el tramo siguiente.
    if (km <= 0) continue
    if (litrosTramo > 0) {
      kmTotal += km
      litrosTotal += litrosTramo
    }
    kmInicio = c.km
    litrosTramo = 0
  }
  if (kmTotal <= 0 || litrosTotal <= 0) return null
  return Math.round((kmTotal / litrosTotal) * 10) / 10
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

const MS_DIA = 86_400_000
const utcDia = (f: string): number => Date.UTC(Number(f.slice(0, 4)), Number(f.slice(5, 7)) - 1, Number(f.slice(8, 10)))
const diasEntre = (desde: string, hasta: string): number => Math.round((utcDia(hasta) - utcDia(desde)) / MS_DIA)

/**
 * Arma la ficha con lo que trae `useVehiculoFichaQuery`. El costo por km toma el
 * gasto del MISMO período que los km: el semiabierto [primera lectura, última
 * lectura), con la cuota mensual de cada gasto prorrateada por día (cuota × días
 * del mes dentro del período / días del mes). Las dos lecturas del mismo día no
 * tienen período: sin costo por km.
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
    cargas.map(c => ({ fecha: c.fecha, km: c.km, litros: c.litros })),
  )

  let costoKm: number | null = null
  const ordenadas = [...lecturas].sort((a, b) => a.fecha.localeCompare(b.fecha) || a.km - b.km)
  if (ordenadas.length >= 2) {
    const primera = ordenadas[0]
    const ultima = ordenadas[ordenadas.length - 1]
    let gastoPeriodo = 0
    if (diasEntre(primera.fecha, ultima.fecha) > 0) {
      for (let m = mesDe(primera.fecha); m <= mesDe(ultima.fecha); m = sumarMeses(m, 1)) {
        const siguiente = sumarMeses(m, 1)
        const desde = primera.fecha > m ? primera.fecha : m
        const hasta = ultima.fecha < siguiente ? ultima.fecha : siguiente
        const dias = diasEntre(desde, hasta)
        if (dias <= 0) continue
        const cuotas = gastos.reduce((t, g) => t + cuotaEn(g, m), 0)
        gastoPeriodo += (cuotas * dias) / diasEntre(m, siguiente)
      }
      costoKm = costoPorKm(gastoPeriodo, ultima.km - primera.km)
    }
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
