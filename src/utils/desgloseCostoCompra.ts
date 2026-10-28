/**
 * El desglose por unidad del costo final que dejó una compra para un producto:
 * neto, impuesto interno y cada cargo prorrateado con su nombre (flete, pallets,
 * bonificaciones), hasta el costo final.
 *
 * Es la misma cuenta que la sección "Costo por producto" del modal de la compra:
 * se hidrata la compra guardada (utils/hidratarCompra) y se corre el motor
 * (utils/prorrateoCompra). El costo final es el GUARDADO
 * (`compra_items.costo_real_unitario`), que es el que fue al producto y al
 * promedio; si el motor de hoy da otra cosa —una compra anterior al motor— la
 * diferencia va aparte en `otrosAjustes`, en vez de esconderla en un cargo.
 *
 * Puro y sin supabase: lo testea `desgloseCostoCompra.test.ts`.
 */
import { calcularCostosCompra, prorratearCargo } from './prorrateoCompra'
import type { CostosCompra } from './prorrateoCompra'
import { hidratarCompraGuardada } from './hidratarCompra'
import { etiquetaComprobante, tipoParaCosto } from './letraComprobante'
import { redondear } from './calculations'
import { cargosParaMotor, iiDeclaradoParaMotor, lineasParaMotor } from '../components/modals/ModalCompra.reducer'
import type { CompraDBExtended } from '../types'

export interface CargoDelDesglose {
  concepto: string
  /** Por unidad. Negativo = una bonificación que baja el costo. */
  unitario: number
}

export interface DesgloseCostoCompra {
  compraId: string
  fechaCompra: string | null
  /** "FC A", "FC B", "ZZ". */
  comprobante: string
  numeroFactura: string | null
  proveedor: string | null
  /** ZZ, B o C (mig 293): lo pagado ya trae el IVA y el II adentro. */
  costoEsLoPagado: boolean
  netoUnitario: number
  /** null = el motor no pudo recalcular la compra: II y cargos van juntos en `otrosAjustes`. */
  iiUnitario: number | null
  cargos: CargoDelDesglose[]
  /** Lo guardado menos lo que da el motor. 0 en una compra hecha con el motor. */
  otrosAjustes: number
  costoFinalUnitario: number
}

/** Una línea candidata tal como vuelve de la query, de la más nueva a la más vieja. */
export interface FilaCompraDelProducto {
  compra_id: string | number
  costo_unitario: number | string | null
  bonificacion: number | string | null
  compra: { id: string | number; estado: string | null } | null
}

const numero = (v: unknown): number => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

/** Debajo de medio centavo es redondeo del motor, no un importe. */
const importe = (v: number): number => (Math.abs(v) < 0.005 ? 0 : redondear(v, 4))

/**
 * ¿Esta línea fija el costo del producto? El mismo `v_actualiza_costo` de
 * registrar_compra_completa: los regalos (bonificación 100 %, costo 0) suman
 * stock pero no fijan costo.
 */
export function lineaFijaCosto(linea: { costo_unitario?: unknown; bonificacion?: unknown }): boolean {
  const bonificacion = numero(linea.bonificacion)
  return bonificacion < 100 && numero(linea.costo_unitario) * (1 - bonificacion / 100) > 0
}

/**
 * La compra que fijó el costo de reposición: la primera (o sea la más nueva por
 * fecha e id, el `v_es_mas_reciente` de la RPC) no cancelada donde la línea
 * fija costo. null si no hay ninguna.
 */
export function compraQueFijaCosto(filas: FilaCompraDelProducto[]): string | null {
  const fila = filas.find(f => f.compra && f.compra.estado !== 'cancelada' && lineaFijaCosto(f))
  return fila ? String(fila.compra?.id ?? fila.compra_id) : null
}

/**
 * El desglose del costo de `productoId` en esta compra. null si el producto no
 * está o ninguna de sus líneas fija costo. Con el producto en dos líneas, manda
 * la última que procesó la RPC (el id más alto): es la que quedó en la ficha.
 */
export function desgloseCostoDeCompra(
  compra: CompraDBExtended,
  productoId: string | number,
): DesgloseCostoCompra | null {
  const { estado, itemPorLinea, costoGuardadoPorLinea } = hidratarCompraGuardada(compra)

  let lineaId: number | null = null
  for (const [id, item] of itemPorLinea) {
    if (String(item.producto_id) !== String(productoId) || !lineaFijaCosto(item)) continue
    if (lineaId === null || numero(item.id) > numero(itemPorLinea.get(lineaId)?.id)) lineaId = id
  }
  if (lineaId === null) return null
  const item = itemPorLinea.get(lineaId)
  const linea = estado.items.find(l => l.lineaId === lineaId)
  if (!item || !linea) return null

  const tipoCosto = tipoParaCosto(estado.tipoFactura, estado.letraComprobante)
  const cargosMotor = cargosParaMotor(estado.cargos)
  let costos: CostosCompra | null = null
  try {
    costos = calcularCostosCompra(
      lineasParaMotor(estado.items, tipoCosto),
      cargosMotor,
      iiDeclaradoParaMotor(estado.iiDeclarado, tipoCosto),
    )
  } catch {
    // Un peso o una cantidad corruptos: el motor lanza (ver calcularCostosCompra).
    // Se muestra lo guardado sin abrir, en vez de no mostrar nada.
  }
  const costosLinea = costos?.lineas.find(l => l.id === lineaId)

  const cantidad = linea.cantidad
  const netoUnitario = costosLinea?.costoNetoUnitario
    ?? linea.costoUnitario * (1 - (linea.bonificacion || 0) / 100)
  const cargos: CargoDelDesglose[] = costosLinea
    ? cargosMotor
        .filter(c => c.prorrateaAlCosto)
        .map(c => ({
          concepto: c.concepto,
          unitario: importe(cantidad > 0 ? (prorratearCargo(c.monto, c.pesos)[lineaId] ?? 0) / cantidad : 0),
        }))
        .filter(c => c.unitario !== 0)
    : []
  const calculado = costosLinea?.costoRealUnitario ?? netoUnitario
  const costoFinalUnitario = costoGuardadoPorLinea.get(lineaId) ?? calculado

  return {
    compraId: String(compra.id),
    fechaCompra: compra.fecha_compra ?? null,
    comprobante: etiquetaComprobante(estado.tipoFactura, estado.letraComprobante),
    numeroFactura: compra.numero_factura ?? null,
    proveedor: compra.proveedor?.nombre ?? compra.proveedor_nombre ?? null,
    costoEsLoPagado: tipoCosto === 'ZZ',
    netoUnitario: redondear(netoUnitario, 4),
    iiUnitario: costosLinea ? importe(costosLinea.iiUnitario) : null,
    cargos,
    otrosAjustes: importe(costoFinalUnitario - calculado),
    costoFinalUnitario,
  }
}
