/**
 * useBottomInset — pisa `--bottom-inset` (declarada en `0px` en src/index.css)
 * mientras el que llama tiene algo fijo contra el borde de abajo, y la devuelve
 * al valor de antes al dejar de tenerlo.
 *
 * El que la lee es la pila de avisos (`noticeRoot.ts`): su `padding-bottom` la
 * suma, así que subirla empuja los avisos por encima de lo fijo en vez de que lo
 * tapen.
 *
 * Se escribe como estilo en línea de `<html>`, que le gana al `:root` de la hoja
 * sin tocarla. Guarda el valor en línea que había antes (no el calculado) y lo
 * repone; si no había ninguno, saca la propiedad y vuelve a regir el de la hoja.
 *
 * `useLayoutEffect` y no `useEffect`: la pila tiene que subir antes del primer
 * pintado, no un cuadro después con el aviso ya dibujado encima del botón.
 *
 * @param valor un largo CSS con unidad (`'calc(10rem + env(safe-area-inset-bottom))'`),
 *   o `null` para no pisar nada.
 */
import { useLayoutEffect } from 'react'

const PROPIEDAD = '--bottom-inset'

export function useBottomInset(valor: string | null): void {
  useLayoutEffect(() => {
    if (valor === null) return

    const estilo = document.documentElement.style
    const anterior = estilo.getPropertyValue(PROPIEDAD)
    estilo.setProperty(PROPIEDAD, valor)

    return () => {
      if (anterior) estilo.setProperty(PROPIEDAD, anterior)
      else estilo.removeProperty(PROPIEDAD)
    }
  }, [valor])
}
