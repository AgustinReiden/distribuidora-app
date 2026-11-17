import { useEffect, useState } from 'react'
import { fechaLocalISO } from '../utils/formatters'

/** Cada cuánto se mira si cambió el día. Un minuto alcanza: el día nuevo se nota recién al cruzar la medianoche. */
const REVISAR_CADA_MS = 60_000

/**
 * El día de hoy en Argentina (`YYYY-MM-DD`), que se actualiza solo al cruzar la medianoche.
 *
 * Una pantalla que arma «Este mes» o «Hoy» con un `useMemo(..., [])` queda fija en el día en que se
 * montó: abierta de un día para el otro, el período nuevo no incluye el día de hoy (#1597, 1597-b3).
 * Quien depende de este valor se recalcula cuando cambia el día. También se revisa al volver a la
 * pestaña, porque un navegador en segundo plano frena los temporizadores.
 */
export function useDiaArgentino(): string {
  const [dia, setDia] = useState<string>(() => fechaLocalISO())

  useEffect(() => {
    const revisar = (): void => setDia(actual => {
      const hoy = fechaLocalISO()
      return hoy === actual ? actual : hoy
    })
    const timer = setInterval(revisar, REVISAR_CADA_MS)
    const alVolver = (): void => { if (document.visibilityState === 'visible') revisar() }
    document.addEventListener('visibilitychange', alVolver)
    return () => {
      clearInterval(timer)
      document.removeEventListener('visibilitychange', alVolver)
    }
  }, [])

  return dia
}
