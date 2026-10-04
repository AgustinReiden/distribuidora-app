/**
 * El filtro del Combobox (ui/Combobox): qué opciones quedan para lo tipeado.
 *
 * Vive acá y no en el componente porque es la parte que se puede romper sin que
 * se note: un proveedor que no aparece al buscarlo "sin tilde" no tira ningún
 * error, simplemente hace que alguien dé de alta un duplicado.
 */
import { sinAcentos } from './duplicadoCliente'

/** Minúsculas, sin tildes, espacios colapsados. */
export function normalizarBusqueda(texto: string | null | undefined): string {
  return sinAcentos((texto ?? '').toLowerCase()).trim().replace(/\s+/g, ' ')
}

const soloDigitos = (texto: string): string => texto.replace(/\D/g, '')

/**
 * Las opciones cuyos textos contienen TODAS las palabras de la consulta, en
 * cualquier orden y en cualquiera de los textos.
 *
 * Una palabra con dígitos matchea también contra los dígitos pelados de cada
 * texto: el CUIT se tipea con o sin guiones ("30-71234567-8" o "3071234567")
 * y los dos tienen que encontrarlo.
 *
 * Orden: primero las que EMPIEZAN con la consulta, después las que tienen una
 * palabra que empieza con ella, después el resto; dentro de cada grupo, el
 * orden original. Consulta vacía: todas, en su orden.
 */
export function filtrarOpciones<T>(
  opciones: T[],
  consulta: string,
  textos: (opcion: T) => Array<string | null | undefined>,
  limite = Infinity,
): T[] {
  const q = normalizarBusqueda(consulta)
  if (!q) return opciones.slice(0, limite)
  const palabras = q.split(' ')

  const puntuadas: Array<{ opcion: T; puntaje: number; orden: number }> = []
  opciones.forEach((opcion, orden) => {
    const campos = textos(opcion).map(normalizarBusqueda).filter(Boolean)
    const digitos = campos.map(soloDigitos).filter(Boolean)
    const todo = campos.join(' ')
    const coincide = palabras.every(p => {
      if (todo.includes(p)) return true
      const d = soloDigitos(p)
      return d.length >= 2 && d.length === p.replace(/[\s.-]/g, '').length && digitos.some(x => x.includes(d))
    })
    if (!coincide) return
    const puntaje = campos.some(c => c.startsWith(q))
      ? 0
      : todo.split(' ').some(w => w.startsWith(palabras[0])) ? 1 : 2
    puntuadas.push({ opcion, puntaje, orden })
  })

  return puntuadas
    .sort((a, b) => a.puntaje - b.puntaje || a.orden - b.orden)
    .slice(0, limite)
    .map(p => p.opcion)
}

/** ¿Lo tipeado es exactamente (sin tildes ni mayúsculas) alguno de los textos? */
export function hayCoincidenciaExacta<T>(opciones: T[], consulta: string, texto: (opcion: T) => string): boolean {
  const q = normalizarBusqueda(consulta)
  return q !== '' && opciones.some(o => normalizarBusqueda(texto(o)) === q)
}
