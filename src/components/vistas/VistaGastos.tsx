/**
 * VistaGastos — los gastos de un mes, por mes imputado (entrega 1 de gastos).
 *
 * Un gasto repartido aparece en cada mes que toca, con su cuota y la marca
 * "cuota k de n". Los totales de arriba son los del mes entero: los filtros
 * sólo recortan la lista. Quién edita y anula lo valida el server; acá se
 * esconden los botones que el rol no puede usar.
 */
import React, { useMemo, useState } from 'react'
import { ChevronLeft, ChevronRight, Download, Pencil, Plus, Settings2, Trash2 } from 'lucide-react'
import PageHeader from '../layout/PageHeader'
import { Button } from '../ui/Button'
import Card from '../ui/Card'
import { Badge } from '../ui/Badge'
import { Combobox } from '../ui/Combobox'
import { cn } from '../../lib/utils'
import { formatPrecio } from '../../utils/formatters'
import {
  GRUPOS_GASTO,
  cuotaDelMes,
  etiquetaComprobante,
  etiquetaGrupo,
  etiquetaMes,
  sumarMeses,
} from '../../utils/gastos'
import type { Gasto, GrupoGasto, RubroGasto, Vehiculo } from '../../types/gastos'

export interface VistaGastosProps {
  mes: string
  onCambiarMes: (mes: string) => void
  gastos: Gasto[]
  rubros: RubroGasto[]
  vehiculos: Vehiculo[]
  loading: boolean
  usuarioId: string
  esAdmin: boolean
  /** El usuario tiene todas las sucursales activas: puede tocar cualquier compartido. */
  tieneTodasLasSucursales: boolean
  sucursalActual: { id: number; nombre: string }
  onNuevoGasto: () => void
  onEditarGasto: (g: Gasto) => void
  onAnularGasto: (g: Gasto) => void
  onAbrirRubros?: () => void
  onExportar: () => void
}

type FiltroGrupo = 'todos' | GrupoGasto
type Alcance = 'todos' | 'sucursal' | 'compartidos'

const round2 = (n: number): number => Math.round((n + Number.EPSILON) * 100) / 100

/** Opción "sin filtro" del buscador: la key vacía es "todos". */
interface OpcionFiltro { key: string; label: string; texto: string }

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

export default function VistaGastos({
  mes, onCambiarMes, gastos, rubros, vehiculos, loading, usuarioId, esAdmin, tieneTodasLasSucursales,
  sucursalActual, onNuevoGasto, onEditarGasto, onAnularGasto, onAbrirRubros, onExportar,
}: VistaGastosProps): React.ReactElement {
  const [grupo, setGrupo] = useState<FiltroGrupo>('todos')
  const [rubroId, setRubroId] = useState('')
  const [vehiculoId, setVehiculoId] = useState('')
  const [alcance, setAlcance] = useState<Alcance>('todos')

  const grupoDe = (g: Gasto): GrupoGasto =>
    g.rubro?.grupo ?? rubros.find(r => r.id === g.rubro_id)?.grupo ?? 'otros'

  // Lo que cada gasto aporta al resultado de este mes. Sin cuota (fuera de la
  // ventana) no se muestra: no es de este mes.
  const lineas = useMemo(
    () => gastos.flatMap(g => {
      const cuota = cuotaDelMes(g, mes)
      return cuota ? [{ gasto: g, cuota, grupo: grupoDe(g) }] : []
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [gastos, mes, rubros],
  )

  const totales = useMemo(() => {
    const porGrupo = new Map<GrupoGasto, number>()
    let todos = 0
    for (const l of lineas) {
      porGrupo.set(l.grupo, round2((porGrupo.get(l.grupo) ?? 0) + l.cuota.monto))
      todos = round2(todos + l.cuota.monto)
    }
    return { porGrupo, todos }
  }, [lineas])

  const visibles = lineas.filter(l =>
    (grupo === 'todos' || l.grupo === grupo)
    && (!rubroId || String(l.gasto.rubro_id) === rubroId)
    && (!vehiculoId || String(l.gasto.vehiculo_id) === vehiculoId)
    && (alcance === 'todos' || (alcance === 'compartidos' ? l.gasto.compartido : !l.gasto.compartido)),
  )

  const puedeTocar = (g: Gasto): boolean =>
    esAdmin
      ? !g.compartido || g.creado_por === usuarioId || tieneTodasLasSucursales
      : g.creado_por === usuarioId && !g.compartido

  const opcionesRubro: OpcionFiltro[] = [
    { key: '', label: 'Todos los rubros', texto: 'Todos los rubros' },
    ...rubros.map(r => ({ key: String(r.id), label: r.nombre, texto: etiquetaGrupo(r.grupo) })),
  ]
  const opcionesVehiculo: OpcionFiltro[] = [
    { key: '', label: 'Todos los vehículos', texto: 'Todos los vehículos' },
    ...vehiculos.map(v => ({ key: String(v.id), label: `${v.patente} · ${v.descripcion}`, texto: v.descripcion })),
  ]

  const conteo = `${gastos.length} ${gastos.length === 1 ? 'GASTO' : 'GASTOS'}`

  return (
    <div className="space-y-6">
      <PageHeader
        titulo="Gastos"
        periodo={`de ${etiquetaMes(mes)}`}
        crumbs={['ADMINISTRACIÓN', sucursalActual.nombre.toUpperCase(), conteo]}
        loading={loading}
        acciones={
          <div className="flex flex-wrap items-center gap-2">
            {esAdmin && onAbrirRubros && (
              <Button type="button" variant="secondary" size="md" onClick={onAbrirRubros}>
                <Settings2 className="w-4 h-4" aria-hidden="true" />
                Rubros
              </Button>
            )}
            <Button type="button" variant="secondary" size="md" onClick={onExportar}>
              <Download className="w-4 h-4" aria-hidden="true" />
              Exportar
            </Button>
            <Button type="button" variant="hero" size="md" onClick={onNuevoGasto}>
              <Plus className="w-4 h-4" aria-hidden="true" />
              Nuevo gasto
            </Button>
          </div>
        }
      />

      {/* Mes */}
      <div className="inline-flex items-center rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800">
        <button
          type="button"
          aria-label="Mes anterior"
          className="px-2.5 py-1.5 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 rounded-l-lg"
          onClick={() => onCambiarMes(sumarMeses(mes, -1))}
        >
          <ChevronLeft className="w-4 h-4" aria-hidden="true" />
        </button>
        <span className="px-3 min-w-[150px] text-center font-medium text-gray-800 dark:text-gray-100 capitalize">
          {etiquetaMes(mes)}
        </span>
        <button
          type="button"
          aria-label="Mes siguiente"
          className="px-2.5 py-1.5 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 rounded-r-lg"
          onClick={() => onCambiarMes(sumarMeses(mes, 1))}
        >
          <ChevronRight className="w-4 h-4" aria-hidden="true" />
        </button>
      </div>

      {/* Total por grupo */}
      <div className="grid grid-cols-2 md:grid-cols-4 xl:grid-cols-7 gap-3">
        {GRUPOS_GASTO.map(g => (
          <Card key={g.valor} variant="stat" data-testid={`total-${g.valor}`}>
            <p className="text-xs text-gray-500 dark:text-gray-400">{g.etiqueta}</p>
            <p className="text-lg font-bold text-gray-800 dark:text-white">{formatPrecio(totales.porGrupo.get(g.valor) ?? 0)}</p>
          </Card>
        ))}
        <Card variant="stat" accent="brand" data-testid="total-todos">
          <p className="text-xs text-gray-500 dark:text-gray-400">Total del mes</p>
          <p className="text-lg font-bold text-gray-800 dark:text-white">{formatPrecio(totales.todos)}</p>
        </Card>
      </div>

      {/* Filtros */}
      <div className="space-y-3">
        <div className="flex flex-wrap gap-2">
          <Pastilla activa={grupo === 'todos'} onClick={() => setGrupo('todos')}>Todos</Pastilla>
          {GRUPOS_GASTO.map(g => (
            <Pastilla key={g.valor} activa={grupo === g.valor} onClick={() => setGrupo(g.valor)}>{g.etiqueta}</Pastilla>
          ))}
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <Combobox
            opciones={opcionesRubro}
            getKey={o => o.key}
            getLabel={o => o.label}
            getTextosBusqueda={o => [o.label, o.texto]}
            valor={rubroId}
            textoSinOpcion="Todos los rubros"
            onSeleccionar={o => setRubroId(o.key)}
            aria-label="Filtrar por rubro"
          />
          <Combobox
            opciones={opcionesVehiculo}
            getKey={o => o.key}
            getLabel={o => o.label}
            getTextosBusqueda={o => [o.label, o.texto]}
            valor={vehiculoId}
            textoSinOpcion="Todos los vehículos"
            onSeleccionar={o => setVehiculoId(o.key)}
            aria-label="Filtrar por vehículo"
          />
        </div>
        {esAdmin && (
          <div className="flex flex-wrap gap-2">
            <Pastilla activa={alcance === 'todos'} onClick={() => setAlcance('todos')}>Todos</Pastilla>
            <Pastilla activa={alcance === 'sucursal'} onClick={() => setAlcance('sucursal')}>De {sucursalActual.nombre}</Pastilla>
            <Pastilla activa={alcance === 'compartidos'} onClick={() => setAlcance('compartidos')}>Compartidos</Pastilla>
          </div>
        )}
      </div>

      {/* Lista */}
      {loading ? (
        <p className="text-sm text-gray-500" role="status">Cargando gastos…</p>
      ) : visibles.length === 0 ? (
        <Card variant="section">
          <p className="text-sm text-gray-500 dark:text-gray-400 text-center py-6">
            {gastos.length === 0
              ? `No hay gastos en ${etiquetaMes(mes)}.`
              : 'No hay gastos que coincidan con los filtros.'}
          </p>
        </Card>
      ) : (
        <ul className="space-y-2">
          {visibles.map(({ gasto: g, cuota, grupo: grupoDelGasto }) => {
            const rubroNombre = g.rubro?.nombre ?? rubros.find(r => r.id === g.rubro_id)?.nombre ?? 'Gasto'
            return (
              <Card as="li" variant="row" key={g.id} data-testid={`gasto-${g.id}`}>
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0 flex-1 space-y-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium text-gray-800 dark:text-white">{rubroNombre}</span>
                      <Badge tone="neutral">{etiquetaGrupo(grupoDelGasto)}</Badge>
                      {g.compartido && <Badge tone="warning">Compartido</Badge>}
                    </div>
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      {g.fecha.slice(8, 10)}/{g.fecha.slice(5, 7)}/{g.fecha.slice(0, 4)}
                      {' · '}
                      {etiquetaComprobante(g.comprobante)}
                      {g.comprobante_numero ? ` ${g.comprobante_numero}` : ''}
                      {g.vehiculo ? ` · ${g.vehiculo.patente}` : ''}
                    </p>
                    {g.observacion && (
                      <p className="text-sm text-gray-600 dark:text-gray-300">{g.observacion}</p>
                    )}
                  </div>
                  <div className="text-right">
                    <p className="font-semibold text-gray-800 dark:text-white">{formatPrecio(cuota.monto)}</p>
                    {cuota.n > 1 && (
                      <>
                        <p className="text-xs text-gray-500">{`cuota ${cuota.k} de ${cuota.n}`}</p>
                        <p className="text-xs text-gray-400">{`de ${formatPrecio(g.costo)}`}</p>
                      </>
                    )}
                    {cuota.n === 1 && g.monto_total !== g.costo && (
                      <p className="text-xs text-gray-400">{`Total ${formatPrecio(g.monto_total)}`}</p>
                    )}
                  </div>
                  {puedeTocar(g) && (
                    <div className="flex items-center gap-1">
                      <Button type="button" variant="ghost" size="sm" aria-label={`Editar gasto de ${rubroNombre}`} onClick={() => onEditarGasto(g)}>
                        <Pencil className="w-4 h-4" aria-hidden="true" />
                      </Button>
                      <Button type="button" variant="ghost" size="sm" aria-label={`Anular gasto de ${rubroNombre}`} onClick={() => onAnularGasto(g)}>
                        <Trash2 className="w-4 h-4 text-red-600" aria-hidden="true" />
                      </Button>
                    </div>
                  )}
                </div>
              </Card>
            )
          })}
        </ul>
      )}
    </div>
  )
}
