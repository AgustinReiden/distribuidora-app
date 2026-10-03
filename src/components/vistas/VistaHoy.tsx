/**
 * "Hoy" del preventista (WP-48, #773): lo del día en una pantalla.
 *
 * Presentacional: los datos y las acciones los pone `HoyContainer`. Tiene
 * cuatro cosas, en el orden en que el preventista las usa en la calle:
 *  - la fecha de hoy, para que no haya duda de qué día está mirando;
 *  - las dos acciones de un toque: "Nuevo pedido" (abre el alta en /pedidos) y
 *    "Marcar visita" (el mismo modal de la toolbar de /pedidos);
 *  - los objetivos del mes, el mismo panel del dashboard (`PanelMisMetas`).
 *    Sin metas cargadas no se muestra nada, igual que allá;
 *  - las visitas que ya marcó hoy (`ListaVisitasHoy`, la misma del modal).
 *
 * No muestra la ruta optimizada: no está persistida (#725).
 */
import React, { useId } from 'react'
import { MapPin, ShoppingCart } from 'lucide-react'
import { Button } from '../ui/Button'
import Card from '../ui/Card'
import PanelMisMetas from '../dashboard/PanelMisMetas'
import ListaVisitasHoy from '../visitas/ListaVisitasHoy'
import { formatDate } from '../../utils/formatters'
import type { AvanceMetasResultado } from '../../hooks/queries'
import type { VisitaHoy } from '../../hooks/queries/useVisitasQuery'

export interface VistaHoyProps {
  /** El día que se está mirando (el container pasa `new Date()`). */
  fecha: Date
  visitas: readonly VisitaHoy[]
  cargandoVisitas: boolean
  errorVisitas: unknown
  /** Objetivos del mes. Sin metas, el panel no se renderiza. */
  avanceMetas?: AvanceMetasResultado
  onNuevoPedido: () => void
  onMarcarVisita: () => void
}

export default function VistaHoy({
  fecha,
  visitas,
  cargandoVisitas,
  errorVisitas,
  avanceMetas,
  onNuevoPedido,
  onMarcarVisita,
}: VistaHoyProps): React.ReactElement {
  const idTituloVisitas = useId()
  // "jueves, 2 de octubre", en horario de Argentina. `year: undefined` le saca
  // el año que formatDate pone por defecto.
  const fechaLarga = formatDate(fecha, { weekday: 'long', day: 'numeric', month: 'long', year: undefined })

  return (
    <div className="max-w-3xl mx-auto space-y-4">
      <div>
        <h1 className="text-xl font-bold text-gray-900 dark:text-gray-100">Hoy</h1>
        <p className="text-sm text-gray-500 dark:text-gray-400 mt-0.5 first-letter:uppercase">
          {fechaLarga}
        </p>
      </div>

      {/* Dos columnas desde 375 px: con `px-3` "Nuevo pedido" entra entero en
          los ~165 px de cada mitad. */}
      <div className="grid grid-cols-2 gap-3">
        <Button size="touch" className="px-3" onClick={onNuevoPedido}>
          <ShoppingCart className="w-5 h-5 shrink-0" aria-hidden="true" />
          Nuevo pedido
        </Button>
        <Button size="touch" variant="secondary" className="px-3" onClick={onMarcarVisita}>
          <MapPin className="w-5 h-5 shrink-0" aria-hidden="true" />
          Marcar visita
        </Button>
      </div>

      {avanceMetas && avanceMetas.metas.length > 0 && <PanelMisMetas avance={avanceMetas} />}

      <Card as="section" aria-labelledby={idTituloVisitas}>
        <h2 id={idTituloVisitas} className="font-semibold text-gray-900 dark:text-white mb-3">
          Visitas de hoy
        </h2>
        <ListaVisitasHoy
          visitas={visitas}
          cargando={cargandoVisitas}
          error={errorVisitas}
          scrollPropio={false}
        />
      </Card>
    </div>
  )
}
