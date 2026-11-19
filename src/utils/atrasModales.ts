/**
 * El «atrás» del teléfono cierra la ventana (modal) que está abierta (decisión 4 del dueño, #1603).
 *
 * Sin esto, «atrás» (el botón o el gesto de Android, el gesto de volver de iPhone) navega: cambia de
 * ruta o sale de la app, y desmonta la pantalla con el modal y lo tipeado adentro, sin preguntar. Acá cada
 * ventana abierta se anota en una pila y suma UNA entrada al historial del navegador; un «atrás» consume la
 * entrada de arriba y le pide cerrarse a la ventana de arriba (que puede preguntar «¿Salir sin guardar?»).
 *
 * Cuentas que se llevan:
 *  - `pila`: las ventanas abiertas, la de arriba al final.
 *  - `empujadas`: las entradas del historial que son nuestras (cada una lleva `atrasModales: <profundidad>`
 *    en su `history.state`, junto al estado del router, que se conserva).
 * `sincronizar` iguala las dos: pide entradas que faltan y retira las que sobran con UN `history.go(-n)`.
 * Se corre diferido (`setTimeout 0`) para que StrictMode (montar, desmontar, montar) y un modal que se
 * reemplaza por otro no dejen entradas de más ni de menos.
 *
 * Reglas:
 *  - Un «atrás» con ventanas abiertas no navega: cierra la de arriba. Si la ventana NO se cierra (pide
 *    confirmar, o es una ventana que no se cierra con Escape tampoco), la entrada consumida se repone.
 *  - Si la ventana se cierra por otro camino (guardar, la X, Escape), su entrada se retira sola, sin
 *    navegar de más: el retiro es un `history.go(-n)` cuyo `popstate` se ignora.
 *  - Sin ventanas abiertas no hace nada: el «atrás» navega como siempre (deep links y router intactos).
 *  - Si alguien navegó encima de nuestra entrada (el router cambió de ruta con la ventana abierta), no se
 *    retira nada: ir hacia atrás llevaría a otra pantalla. Queda una entrada vieja, inofensiva.
 *  - Al recargar con una ventana abierta, el historial conserva la marca pero no hay ventana: se vuelve a
 *    la entrada de abajo (`limpiarAtrasAlCargar`, desde `main.tsx`) para no dejar un «atrás» fantasma.
 */

/** La marca que llevan las entradas de historial que son de una ventana. */
const CLAVE = 'atrasModales'

interface Registro {
  cerrar: () => void
}

const pila: Registro[] = []
let empujadas = 0
let retiroPendiente = false
let escuchando = false
let timerSincronizar: ReturnType<typeof setTimeout> | null = null
let timerRetiro: ReturnType<typeof setTimeout> | null = null

/** Cuántas entradas nuestras hay apiladas en la entrada de historial que `state` describe. */
function profundidad(state: unknown): number {
  const p = (state as Record<string, unknown> | null | undefined)?.[CLAVE]
  return typeof p === 'number' && p > 0 ? p : 0
}

function hayHistorial(): boolean {
  return typeof window !== 'undefined' && typeof window.history?.pushState === 'function'
}

function asegurarEscucha(): void {
  if (escuchando || !hayHistorial()) return
  window.addEventListener('popstate', alPopstate)
  escuchando = true
}

function programar(): void {
  if (timerSincronizar !== null) return
  timerSincronizar = setTimeout(() => {
    timerSincronizar = null
    sincronizar()
  }, 0)
}

/** Pide un retiro de `n` entradas y ya no mira hasta que llegue su `popstate` (o pase un segundo). */
function retirar(n: number): void {
  retiroPendiente = true
  window.history.go(-n)
  // Si no hay a dónde volver, el navegador no avisa: se destraba solo.
  timerRetiro = setTimeout(() => {
    timerRetiro = null
    retiroPendiente = false
    programar()
  }, 1000)
}

function terminarRetiro(): void {
  retiroPendiente = false
  if (timerRetiro !== null) {
    clearTimeout(timerRetiro)
    timerRetiro = null
  }
}

function sincronizar(): void {
  if (!hayHistorial() || retiroPendiente) return
  if (empujadas > pila.length) {
    const n = empujadas - pila.length
    // Sólo se retira si seguimos parados en nuestra entrada de arriba: con otra ruta encima, volver
    // llevaría a otra pantalla.
    const parados = profundidad(window.history.state) === empujadas
    empujadas = pila.length
    if (parados) retirar(n)
    return
  }
  while (empujadas < pila.length) {
    empujadas += 1
    window.history.pushState({ ...(window.history.state ?? {}), [CLAVE]: empujadas }, '')
  }
}

function alPopstate(): void {
  if (retiroPendiente) {
    // El eco de un retiro nuestro.
    terminarRetiro()
    programar()
    return
  }
  const prof = profundidad(window.history.state)
  // Un «adelante» u otra navegación: no es un «atrás» sobre nuestras entradas.
  if (prof >= empujadas) return
  empujadas = prof
  pila[pila.length - 1]?.cerrar()
  // Si la ventana no se cerró (pide confirmar), la entrada consumida se repone.
  programar()
}

/**
 * Anota una ventana abierta. Devuelve la función que la quita (al cerrarse o desmontarse). `cerrar` es lo
 * que hace el «atrás»: pedirle cierre a la ventana, que puede cerrarla o preguntar antes.
 */
export function registrarAtrasModal(cerrar: () => void): () => void {
  if (!hayHistorial()) return () => {}
  asegurarEscucha()
  const registro: Registro = { cerrar }
  pila.push(registro)
  programar()
  return () => {
    const i = pila.indexOf(registro)
    if (i >= 0) pila.splice(i, 1)
    programar()
  }
}

/**
 * Al arrancar la app: si el historial quedó con la marca de una ventana abierta (se recargó con una ventana
 * abierta), no hay ventana que le corresponda; se vuelve a la entrada de abajo para no dejar un «atrás»
 * que no hace nada.
 */
export function limpiarAtrasAlCargar(): void {
  if (!hayHistorial()) return
  asegurarEscucha()
  const prof = profundidad(window.history.state)
  if (prof > 0) retirar(prof)
}

/**
 * Volver a la pantalla de antes (el `history.back()` de un modal que ES una ruta, como el del recorrido del
 * preventista). Con una ventana abierta, el historial tiene nuestra entrada arriba: un `history.back()` pelado
 * sólo la sacaría a ella y dejaría la pantalla puesta. Acá se vuelve de una por nuestras entradas y por la
 * pantalla, y el `popstate` resultante no se toma por un «atrás» del usuario.
 */
export function volverUnaPantalla(): void {
  if (typeof window === 'undefined') return
  if (!hayHistorial()) return
  const n = 1 + empujadas
  empujadas = 0
  retirar(n)
}

/** Para los tests: deja la mecánica como recién cargada (el historial de jsdom no se toca). */
export function reiniciarAtrasModales(): void {
  pila.length = 0
  empujadas = 0
  terminarRetiro()
  if (timerSincronizar !== null) {
    clearTimeout(timerSincronizar)
    timerSincronizar = null
  }
}
