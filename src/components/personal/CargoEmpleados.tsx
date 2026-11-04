/**
 * CargoEmpleados — la sección «A cargo de empleados» (gastos 7). Va en la baja de stock y en
 * la resolución de una salvedad, y sólo la ve el admin: cada línea es un empleado y un monto
 * que la liquidación le descuenta como una `rotura`.
 *
 * El monto por defecto es el costo repartido en partes iguales (`repartirCosto`) entre todas las
 * líneas, mientras nadie haya tocado un monto a mano. Si la suma pasa el costo avisa, pero no
 * bloquea: el que decide es el admin. Con el costo desconocido o en 0 el monto arranca vacío.
 *
 * El componente es controlado: las líneas viven en el modal, que las convierte en `p_cargos`
 * con `armarCargos`.
 */
import React, { useEffect, useId, useMemo, useState } from 'react'
import type { SelectHTMLAttributes } from 'react'
import { AlertTriangle, ChevronDown, X } from 'lucide-react'
import { InputMonto } from '../ui/InputMonto'
import { cn } from '../../lib/utils'
import { useEmpleadosParaElegirQuery } from '../../hooks/queries/usePersonalQuery'
import { empleadosParaFaltante } from '../../utils/faltantesRendicion'
import { formatPrecio } from '../../utils/formatters'
import { montoATexto, parseMonto, repartirCosto } from '../../utils/personal'
import type { LineaCargo } from '../../types/personal'

export type { LineaCargo }

export interface CargoEmpleadosProps {
  /** El costo de la mercadería perdida; `null` si no se conoce. */
  costo: number | null
  value: LineaCargo[]
  onChange: (v: LineaCargo[]) => void
  /** El usuario logueado: nadie se carga a sí mismo (el server igual lo rechaza). */
  usuarioId?: string | null
}

const CLASE_INPUT =
  'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white'

/** Un select con la flecha de los demás campos: el CSS global le saca la del navegador. */
function Lista({ contenedor, className, children, ...resto }: SelectHTMLAttributes<HTMLSelectElement> & { contenedor?: string }) {
  return (
    <div className={cn('relative', contenedor)}>
      <select {...resto} className={cn(className, 'pr-9')}>
        {children}
      </select>
      <ChevronDown aria-hidden="true" className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
    </div>
  )
}

/** Los montos que corresponden a `n` líneas sin tocar: el costo repartido, o vacíos si no se conoce. */
function montosRepartidos(costo: number | null, n: number): string[] {
  if (costo === null || !(costo > 0)) return Array.from({ length: n }, () => '')
  return repartirCosto(costo, n).map(montoATexto)
}

export default function CargoEmpleados({ costo, value, onChange, usuarioId = null }: CargoEmpleadosProps): React.ReactElement {
  const id = useId()
  const { data: empleados = [] } = useEmpleadosParaElegirQuery()
  // Una vez que alguien escribe un monto, el reparto automático se apaga para siempre en este cargo.
  const [tocado, setTocado] = useState(false)

  const elegibles = useMemo(() => empleadosParaFaltante(empleados, usuarioId), [empleados, usuarioId])

  // El costo cambia (el admin cambia la cantidad de la baja): los montos sin tocar lo siguen.
  useEffect(() => {
    if (tocado || value.length === 0) return
    const montos = montosRepartidos(costo, value.length)
    if (value.some((l, i) => l.monto !== montos[i])) {
      onChange(value.map((l, i) => ({ ...l, monto: montos[i] })))
    }
  }, [costo, tocado, value, onChange])

  const conReparto = (lineas: LineaCargo[]): LineaCargo[] => {
    if (tocado) return lineas
    const montos = montosRepartidos(costo, lineas.length)
    return lineas.map((l, i) => ({ ...l, monto: montos[i] }))
  }

  const sumarLinea = () => onChange(conReparto([...value, { empleado_id: null, monto: '' }]))
  const quitarLinea = (i: number) => onChange(conReparto(value.filter((_, j) => j !== i)))
  const cambiarEmpleado = (i: number, texto: string) =>
    onChange(value.map((l, j) => (j === i ? { ...l, empleado_id: texto === '' ? null : Number(texto) } : l)))
  const cambiarMonto = (i: number, monto: string) => {
    setTocado(true)
    onChange(value.map((l, j) => (j === i ? { ...l, monto } : l)))
  }

  const suma = value.reduce((total, l) => total + (parseMonto(l.monto) ?? 0), 0)
  const pasaDelCosto = costo !== null && costo > 0 && Math.round(suma * 100) > Math.round(costo * 100)

  return (
    <section aria-labelledby={`${id}-titulo`} className="space-y-2 rounded-lg border border-gray-200 dark:border-gray-700 p-3">
      <div>
        <h3 id={`${id}-titulo`} className="text-sm font-medium text-gray-700 dark:text-gray-300">A cargo de empleados</h3>
        <p className="text-xs text-gray-500">
          Si lo paga alguien, se le descuenta de su liquidación. Si no elegís a nadie, no se le cobra a nadie.
          {costo !== null && costo > 0 && <> Costo de la mercadería: {formatPrecio(costo)}.</>}
        </p>
      </div>

      {value.map((linea, i) => {
        const tomados = new Set(value.filter((_, j) => j !== i).map(l => l.empleado_id))
        return (
          <div key={i} className="flex items-start gap-2">
            <Lista
              aria-label={`Empleado ${i + 1}`}
              value={linea.empleado_id === null ? '' : String(linea.empleado_id)}
              onChange={e => cambiarEmpleado(i, e.target.value)}
              contenedor="flex-1 min-w-0"
              className={cn(CLASE_INPUT, 'bg-white')}
            >
              <option value="">Elegí un empleado</option>
              {elegibles
                .filter(e => !tomados.has(e.id))
                .map(e => <option key={e.id} value={String(e.id)}>{e.nombre}</option>)}
            </Lista>
            <div className="relative w-36 shrink-0">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">$</span>
              <InputMonto
                aria-label={`Monto a cargo ${i + 1}`}
                value={linea.monto}
                onChange={texto => cambiarMonto(i, texto)}
                placeholder="0,00"
                className={cn(CLASE_INPUT, 'pl-7 text-right')}
              />
            </div>
            <button
              type="button"
              aria-label={`Quitar empleado ${i + 1}`}
              onClick={() => quitarLinea(i)}
              className="mt-2 p-1 text-gray-400 hover:text-red-600"
            >
              <X className="w-4 h-4" aria-hidden="true" />
            </button>
          </div>
        )
      })}

      {pasaDelCosto && (
        <p role="status" className="flex items-start gap-2 text-sm text-amber-700 dark:text-amber-400">
          <AlertTriangle className="w-4 h-4 shrink-0 mt-0.5" aria-hidden="true" />
          <span>Cargás más que el costo de la mercadería ({formatPrecio(costo)})</span>
        </p>
      )}

      <button
        type="button"
        onClick={sumarLinea}
        disabled={value.length >= elegibles.length}
        className="text-sm text-brand-600 dark:text-brand-400 font-medium hover:underline disabled:opacity-50 disabled:no-underline"
      >
        + Empleado
      </button>
    </section>
  )
}
