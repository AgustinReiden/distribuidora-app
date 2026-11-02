/**
 * VistaPersonal — los empleados de la sucursal (entrega 3 de gastos). Sólo admin.
 *
 * Mismo molde que las tarjetas de Clientes. Cada tarjeta muestra el puesto, el arreglo de
 * sueldo vigente, a qué está vinculado el empleado (usuario, cliente, vehículo) y el saldo de
 * su cuenta. Positivo es "a su favor" (la empresa le debe): al revés que en Clientes. La vista
 * sólo muestra y avisa; quién puede qué lo decide el server.
 */
import React, { useMemo, useState } from 'react'
import { Car, IdCard, Pencil, RotateCcw, Search, UserPlus, UserX, UserRound, Store } from 'lucide-react'
import PageHeader from '../layout/PageHeader'
import LoadingSpinner from '../layout/LoadingSpinner'
import QueryErrorState from '../layout/QueryErrorState'
import { Button } from '../ui/Button'
import Card from '../ui/Card'
import { cn } from '../../lib/utils'
import { formatPrecio } from '../../utils/formatters'
import { contarPersonal, estadoSaldo, etiquetaPuesto, filtrarPersonal, textoArregloCorto } from '../../utils/personal'
import type { Empleado, FiltroPersonal } from '../../types/personal'

export interface VistaPersonalProps {
  /** Activos e inactivos: el filtro decide cuáles se ven. */
  empleados: Empleado[]
  loading: boolean
  error?: Error | null
  onRetry?: () => void
  sucursalActual: { id: number; nombre: string }
  sucursales: Array<{ id: number; nombre: string }>
  onNuevo: () => void
  onEditar: (e: Empleado) => void
  onDarDeBaja: (e: Empleado) => void
  onReactivar: (e: Empleado) => void
  onVerFicha: (e: Empleado) => void
}

/** Hoy en Tucumán, no en UTC: a la noche el día UTC ya es el de mañana. */
const hoyArgentino = (): string =>
  new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Tucuman' })

function Pastilla({ activa, onClick, children }: { activa: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      type="button"
      aria-pressed={activa}
      onClick={onClick}
      className={cn(
        'px-3 py-1.5 rounded-full border text-sm transition-colors',
        activa
          ? 'border-brand-500 bg-brand-50 dark:bg-brand-900/20 text-brand-700 dark:text-brand-300 font-medium'
          : 'border-gray-200 dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700',
      )}
    >
      {children}
    </button>
  )
}

interface TarjetaProps {
  empleado: Empleado
  idx: number
  hoy: string
  nombreSucursal: string
  onEditar: () => void
  onDarDeBaja: () => void
  onReactivar: () => void
  onVerFicha: () => void
}

function TarjetaEmpleado({ empleado: e, idx, hoy, nombreSucursal, onEditar, onDarDeBaja, onReactivar, onVerFicha }: TarjetaProps) {
  const inactivo = !e.activo
  const estado = estadoSaldo(e.saldo)
  const saldoColor =
    estado === 'a_favor' ? 'text-emerald-700 dark:text-emerald-300'
    : estado === 'debe' ? 'text-rose-700 dark:text-rose-300'
    : 'text-stone-500 dark:text-stone-400'
  const saldoEtiqueta = estado === 'a_favor' ? 'Saldo · a su favor' : estado === 'debe' ? 'Saldo · debe' : 'Saldo'

  const empiezaEl = e.arreglo && e.arranque && e.arranque > hoy
    ? ` · empieza el ${e.arranque.slice(8, 10)}/${e.arranque.slice(5, 7)}`
    : ''
  const arreglo = e.arreglo ? `${textoArregloCorto(e.arreglo)}${empiezaEl}` : 'Sin arreglo'

  return (
    <li
      className={cn(
        'group bg-white dark:bg-gray-800 border rounded-xl shadow-warm hover:shadow-warm-md hover:-translate-y-px dark:hover:border-gray-600 transition-[transform,box-shadow,border-color] duration-200 overflow-hidden flex flex-col',
        inactivo
          ? 'border-stone-300 dark:border-gray-600 opacity-60 grayscale'
          : 'border-stone-200/80 dark:border-gray-700 hover:border-stone-300',
      )}
      style={{
        animation: 'card-in 0.32s cubic-bezier(0.22, 1, 0.36, 1) both',
        animationDelay: `${Math.min(idx, 12) * 40}ms`,
      }}
    >
      {/* Puesto · sucursal + acciones */}
      <div className="px-4 pt-3 flex items-center justify-between gap-2">
        <div className="text-[10.5px] font-semibold uppercase tracking-[0.18em] text-stone-500 dark:text-stone-400 flex items-center min-w-0 flex-wrap">
          {inactivo && (
            <span className="mr-2 px-1.5 py-0.5 rounded bg-stone-200 dark:bg-gray-700 text-stone-700 dark:text-stone-300 tracking-normal">
              Inactivo
            </span>
          )}
          {e.es_propio && (
            <span className="mr-2 px-1.5 py-0.5 rounded bg-brand-50 dark:bg-brand-900/30 text-brand-700 dark:text-brand-300 tracking-normal">
              Tu cuenta
            </span>
          )}
          <span className="truncate">{`${etiquetaPuesto(e.puesto)} · ${e.de_las_dos ? 'Las dos' : nombreSucursal}`}</span>
        </div>
        <div className="flex gap-0.5 flex-shrink-0">
          <Button
            variant="ghost"
            size="iconSm"
            onClick={onEditar}
            className="text-stone-500 hover:text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/30"
            aria-label={`Editar empleado ${e.nombre}`}
          >
            <Pencil className="w-3.5 h-3.5" aria-hidden="true" />
          </Button>
          {!e.es_propio && (inactivo ? (
            <Button
              variant="ghost"
              size="iconSm"
              onClick={onReactivar}
              className="text-stone-500 hover:text-emerald-600 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
              aria-label={`Reactivar empleado ${e.nombre}`}
            >
              <RotateCcw className="w-3.5 h-3.5" aria-hidden="true" />
            </Button>
          ) : (
            <Button
              variant="ghost"
              size="iconSm"
              onClick={onDarDeBaja}
              className="text-stone-500 hover:text-amber-600 hover:bg-amber-50 dark:hover:bg-amber-900/30"
              aria-label={`Desactivar empleado ${e.nombre}`}
              title="Desactivar. Su cuenta y su historial quedan."
            >
              <UserX className="w-3.5 h-3.5" aria-hidden="true" />
            </Button>
          ))}
        </div>
      </div>

      <h3 className="px-4 mt-1 text-lg font-semibold text-stone-900 dark:text-white leading-tight break-words">
        {e.nombre}
      </h3>
      <p className="px-4 mt-0.5 text-sm text-stone-500 dark:text-stone-400">{arreglo}</p>

      {/* Vínculos */}
      <div className="px-4 mt-2 mb-3 space-y-1.5 text-sm text-stone-600 dark:text-stone-300">
        <div className="flex items-center gap-1.5">
          {e.usuario
            ? <IdCard className="w-4 h-4 flex-shrink-0 text-stone-400 dark:text-stone-500" aria-hidden="true" />
            : <UserRound className="w-4 h-4 flex-shrink-0 text-stone-400 dark:text-stone-500" aria-hidden="true" />}
          <span className="break-words">{e.usuario ? `Usuario ${e.usuario.nombre}` : 'Sin usuario en la app'}</span>
        </div>
        {e.cliente && (
          <div className="flex items-center gap-1.5">
            <Store className="w-4 h-4 flex-shrink-0 text-stone-400 dark:text-stone-500" aria-hidden="true" />
            <span className="break-words">{`Cliente “${e.cliente.nombre_fantasia}”`}</span>
          </div>
        )}
        {e.vehiculo && (
          <div className="flex items-center gap-1.5">
            <Car className="w-4 h-4 flex-shrink-0 text-stone-400 dark:text-stone-500" aria-hidden="true" />
            <span className="break-words">{`${e.vehiculo.descripcion} ${e.vehiculo.patente}`}</span>
          </div>
        )}
      </div>

      {/* Pie: saldo + ficha */}
      <div className="mt-auto pt-3 px-4 pb-3 flex items-end justify-between gap-2 border-t border-stone-100 dark:border-gray-700/60">
        <div>
          <p className="text-[10.5px] font-semibold uppercase tracking-[0.14em] text-stone-500 dark:text-stone-400">{saldoEtiqueta}</p>
          <p className={cn('text-lg font-bold tabular-nums', saldoColor)}>{formatPrecio(Math.abs(e.saldo))}</p>
        </div>
        <Button type="button" variant="secondary" size="sm" onClick={onVerFicha}>
          Ver ficha
        </Button>
      </div>
    </li>
  )
}

export default function VistaPersonal({
  empleados, loading, error, onRetry, sucursalActual, sucursales,
  onNuevo, onEditar, onDarDeBaja, onReactivar, onVerFicha,
}: VistaPersonalProps): React.ReactElement {
  const [filtro, setFiltro] = useState<FiltroPersonal>('todos')
  const [busqueda, setBusqueda] = useState('')

  const conteos = useMemo(() => contarPersonal(empleados), [empleados])
  const visibles = useMemo(() => filtrarPersonal(empleados, filtro, busqueda), [empleados, filtro, busqueda])
  const hoy = hoyArgentino()
  const hayFiltro = filtro !== 'todos' || busqueda.trim() !== ''

  const nombreSucursal = (id: number): string =>
    sucursales.find(s => s.id === id)?.nombre ?? (id === sucursalActual.id ? sucursalActual.nombre : `Sucursal ${id}`)

  // Cuenta los activos, igual que la pastilla "Todos".
  const conteo = `${conteos.todos} ${conteos.todos === 1 ? 'EMPLEADO' : 'EMPLEADOS'}`

  return (
    <div className="space-y-6">
      <PageHeader
        titulo="Personal"
        crumbs={['ADMINISTRACIÓN', sucursalActual.nombre.toUpperCase(), conteo]}
        loading={loading}
        acciones={
          <Button type="button" variant="hero" size="md" onClick={onNuevo}>
            <UserPlus className="w-4 h-4" aria-hidden="true" />
            Nuevo empleado
          </Button>
        }
      />

      <div className="space-y-3">
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400" aria-hidden="true" />
          <input
            type="text"
            value={busqueda}
            onChange={ev => setBusqueda(ev.target.value)}
            className="w-full h-10 sm:h-9 pl-9 pr-3 rounded-lg border text-sm bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 border-stone-200 dark:border-gray-700 placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
            placeholder="Buscar empleado"
            aria-label="Buscar empleado"
          />
        </div>
        <div role="group" aria-label="Filtrar personal" className="flex flex-wrap gap-2">
          <Pastilla activa={filtro === 'todos'} onClick={() => setFiltro('todos')}>{`Todos · ${conteos.todos}`}</Pastilla>
          <Pastilla activa={filtro === 'con_saldo'} onClick={() => setFiltro('con_saldo')}>{`Con saldo · ${conteos.con_saldo}`}</Pastilla>
          <Pastilla activa={filtro === 'inactivos'} onClick={() => setFiltro('inactivos')}>Inactivos</Pastilla>
        </div>
      </div>

      {loading ? (
        <LoadingSpinner text="Cargando personal…" />
      ) : error ? (
        <QueryErrorState onRetry={onRetry} />
      ) : visibles.length === 0 ? (
        <Card variant="section">
          <p className="text-sm text-gray-500 dark:text-gray-400 text-center py-6">
            {empleados.length === 0 && !hayFiltro
              ? 'Todavía no hay empleados. Cargá el primero con «Nuevo empleado».'
              : !hayFiltro
                ? 'No hay empleados activos.'
                : 'Ningún empleado coincide.'}
          </p>
        </Card>
      ) : (
        <ul className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
          {visibles.map((e, idx) => (
            <TarjetaEmpleado
              key={e.id}
              empleado={e}
              idx={idx}
              hoy={hoy}
              nombreSucursal={nombreSucursal(e.sucursal_id)}
              onEditar={() => onEditar(e)}
              onDarDeBaja={() => onDarDeBaja(e)}
              onReactivar={() => onReactivar(e)}
              onVerFicha={() => onVerFicha(e)}
            />
          ))}
        </ul>
      )}
    </div>
  )
}
