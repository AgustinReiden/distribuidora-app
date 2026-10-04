/**
 * PeriodPicker — el selector de período, SÓLO la parte visual (WP-55, #779).
 *
 * Una fila de presets (botones que se pueden presionar) y, al lado o abajo, dos
 * campos de fecha. Nada más. Lo que este primitivo NO hace es lo que lo define:
 *  - NO sabe qué es «el último mes» ni «hoy». No importa ni calcula una fecha: los
 *    presets le llegan como `{ id, label }` y cada pantalla le deja el rango ya
 *    calculado en `desde` / `hasta`. Esa cuenta es de negocio y es distinta por
 *    pantalla (`getPresetDates` en Analytics, `rangoFromPreset` en Geolocalización,
 *    otros presets en Reportes y en el Gerencial).
 *  - NO guarda estado. `activePresetId`, `desde` y `hasta` son del padre; el picker
 *    avisa («eligieron este preset», «escribieron esta fecha») y el padre decide
 *    qué hacer, incluso si un cambio de fecha desactiva el preset.
 *  - NO dispara nada. No hay un «Generar», ni un auto-disparo, ni persistencia en
 *    la URL: si el padre consulta solo al cambiar el rango o espera un botón es
 *    cosa del padre. Unificar eso es #727, un cambio de comportamiento que este
 *    primitivo no empuja ni a favor ni en contra.
 *  - NO impone un vocabulario de presets ni una granularidad. Un selector de mes
 *    único (Metas de preventistas) no es un rango y no entra acá.
 *  - NO valida ni corrige el rango. Muestra lo que le dan: si `desde` > `hasta`
 *    los dos inputs lo muestran así. Limitar un campo con el otro es opt-in y
 *    explícito (`desdeMax`, `hastaMin`), porque hoy una pantalla lo hace y otra
 *    no, y agregarlo a la que no lo hace sería cambiarle el comportamiento.
 *
 * Decisiones de accesibilidad:
 *  - Los presets van en un `role="group"` con nombre (`etiqueta`) y cada uno es un
 *    `<Button aria-pressed>`: el activo se anuncia como «presionado», no sólo se
 *    pinta de otro color. Si `activePresetId` no es ninguno de los presets (el
 *    caso de un rango escrito a mano en una pantalla sin «Personalizado») los
 *    botones quedan todos en `aria-pressed="false"`.
 *  - Cada preset es `type="button"`: adentro de un `<form>` no manda el formulario.
 *  - Los campos de fecha traen su `<label>` visible, atado con `FormField` (que
 *    genera un id propio por instancia, así que dos pickers en la misma pantalla
 *    no se pisan). Las etiquetas por omisión son «Desde» y «Hasta»; una pantalla
 *    con otro nombre accesible se lo pasa (`desdeLabel`, `hastaLabel`).
 *
 * Layout: presets y fechas comparten una fila que envuelve. En 375 px los presets
 * ocupan el ancho y se parten en las filas que hagan falta, y las dos fechas van
 * lado a lado debajo; desde `sm` todo sigue en una fila si entra.
 *
 * Colores: los de `Button` (primario para el activo, secundario para el resto) y
 * los neutros `gray-*` con su par `dark:` — `high-contrast.css` apunta a esos
 * nombres, y el activo lleva el gancho `btn-primary` del primitivo.
 */
import type { ReactElement } from 'react'
import { cn } from '../../lib/utils'
import { Button } from './Button'
import { FormField } from './FormField'

export interface PeriodPickerPreset<Id extends string = string> {
  /** Lo que recibe `onSelectPreset`. Es de la pantalla: el picker no lo interpreta. */
  id: Id
  /** Lo que se lee en el botón. */
  label: string
}

export interface PeriodPickerProps<Id extends string = string> {
  /** Los presets de ESTA pantalla, en el orden en que se muestran. */
  presets: readonly PeriodPickerPreset<Id>[]
  /** Cuál está presionado. `null` o un id que no está en `presets`: ninguno. */
  activePresetId?: string | null
  /** El usuario eligió un preset. El rango que le corresponde lo calcula el padre. */
  onSelectPreset: (id: Id) => void
  /** Valor del campo «Desde» (`YYYY-MM-DD` o vacío). */
  desde: string
  /** Valor del campo «Hasta» (`YYYY-MM-DD` o vacío). */
  hasta: string
  onDesdeChange: (valor: string) => void
  onHastaChange: (valor: string) => void
  /** Si se ven los dos campos de fecha. Por omisión, sí. */
  mostrarFechas?: boolean
  /** Nombre accesible del grupo de presets (`aria-label` del `role="group"`). */
  etiqueta: string
  /** Etiqueta del campo «Desde». Por omisión, «Desde». */
  desdeLabel?: string
  /** Etiqueta del campo «Hasta». Por omisión, «Hasta». */
  hastaLabel?: string
  /** `max` del campo «Desde»: lo que impide elegir un «Desde» posterior al «Hasta». */
  desdeMax?: string
  /** `min` del campo «Hasta»: lo que impide elegir un «Hasta» anterior al «Desde». */
  hastaMin?: string
  /** Clases de la fila que contiene todo. */
  className?: string
}

const CLASES_INPUT_FECHA =
  'w-full h-10 px-3 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 ' +
  'text-sm text-gray-900 dark:text-white tabular-nums ' +
  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 ' +
  'dark:focus-visible:ring-offset-gray-900'

export function PeriodPicker<Id extends string = string>({
  presets,
  activePresetId = null,
  onSelectPreset,
  desde,
  hasta,
  onDesdeChange,
  onHastaChange,
  mostrarFechas = true,
  etiqueta,
  desdeLabel = 'Desde',
  hastaLabel = 'Hasta',
  desdeMax,
  hastaMin,
  className,
}: PeriodPickerProps<Id>): ReactElement {
  return (
    <div className={cn('flex flex-wrap items-end gap-x-4 gap-y-3', className)}>
      <div role="group" aria-label={etiqueta} className="flex w-full flex-wrap gap-2 sm:w-auto">
        {presets.map((preset) => {
          const activo = preset.id === activePresetId
          return (
            <Button
              key={preset.id}
              type="button"
              variant={activo ? 'primary' : 'secondary'}
              size="md"
              aria-pressed={activo}
              onClick={() => onSelectPreset(preset.id)}
            >
              {preset.label}
            </Button>
          )
        })}
      </div>

      {mostrarFechas && (
        <div className="grid w-full grid-cols-2 gap-3 sm:w-auto">
          <FormField label={desdeLabel} className="min-w-0">
            <input
              type="date"
              value={desde}
              max={desdeMax}
              onChange={(e) => onDesdeChange(e.target.value)}
              className={CLASES_INPUT_FECHA}
            />
          </FormField>
          <FormField label={hastaLabel} className="min-w-0">
            <input
              type="date"
              value={hasta}
              min={hastaMin}
              onChange={(e) => onHastaChange(e.target.value)}
              className={CLASES_INPUT_FECHA}
            />
          </FormField>
        </div>
      )}
    </div>
  )
}

export default PeriodPicker
