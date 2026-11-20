/**
 * Ayudas de los tests del «atrás» del teléfono. Esperan la CONDICIÓN (la mecánica de `utils/atrasModales`
 * quieta, el `popstate` llegado), no un tiempo fijo: con la máquina cargada una espera de 150 ms vence antes
 * que la cadena de `setTimeout 0` + `popstate` de jsdom y el test afirma de más (N6 de la revisión de C7).
 */
import { act } from '@testing-library/react'
import { atrasQuieto } from '../utils/atrasModales'

/** Deja que la mecánica del «atrás» termine lo que tiene pendiente (entradas por pedir o por retirar). */
export const asentar = (): Promise<void> => act(async () => { await atrasQuieto() })

/** La marca de la entrada de historial actual (la profundidad de ventanas), o undefined. */
export const marca = (): unknown => (window.history.state as Record<string, unknown> | null)?.atrasModales

/** El «atrás» del teléfono: espera a que llegue el `popstate` y a que la mecánica quede quieta. */
export async function atras(): Promise<void> {
  const llego = new Promise<void>(resolver => {
    const avisar = (): void => { clearTimeout(limite); resolver() }
    // Si no hay a dónde volver el navegador no avisa: el límite evita colgar el test.
    const limite = setTimeout(() => { window.removeEventListener('popstate', avisar); resolver() }, 3000)
    window.addEventListener('popstate', avisar, { once: true })
  })
  act(() => { window.history.back() })
  await llego
  await asentar()
}
