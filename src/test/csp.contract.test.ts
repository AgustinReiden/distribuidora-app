import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * La CSP del repo: la meta de index.html, nginx.conf y public/_headers dicen lo
 * mismo, y dejan ver la factura escaneada (INF-7, #1563).
 *
 * El visor de la factura la muestra como `blob:` (`urlLocalDeArchivo`): la imagen
 * entra por `img-src blob:` y el PDF, por `frame-src 'self' blob:`. Sin
 * `frame-src`, el `<iframe>` cae en `default-src 'self'`, que no incluye `blob:`,
 * y el PDF queda en blanco. Supabase no se abre a imágenes ni a frames: se baja
 * por `connect-src`.
 *
 * Ojo: la CSP de producción vive en el panel de Coolify, no acá. Este test cuida
 * el repo; la de producción se mira con `curl -I`.
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const RAIZ = path.resolve(__dirname, '../..')
const leer = (archivo: string) => fs.readFileSync(path.join(RAIZ, archivo), 'utf8')

const CSPS = {
  'index.html': leer('index.html').match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)?.[1],
  'nginx.conf': leer('nginx.conf').match(/add_header Content-Security-Policy "([^"]+)"/)?.[1],
  'public/_headers': leer('public/_headers').match(/^\s*Content-Security-Policy: (.+)$/m)?.[1]?.trim(),
}

function directiva(csp: string, nombre: string): string[] | undefined {
  const parte = csp.split(';').map(d => d.trim().split(/\s+/)).find(([n]) => n === nombre)
  return parte?.slice(1)
}

describe('la CSP del repo', () => {
  it('está en los tres lugares, y es la misma', () => {
    for (const [archivo, csp] of Object.entries(CSPS)) expect(csp, archivo).toBeTruthy()
    expect(new Set(Object.values(CSPS)).size).toBe(1)
  })

  const csp = CSPS['index.html'] ?? ''

  it('deja ver la factura escaneada como blob: la imagen y el PDF', () => {
    expect(directiva(csp, 'img-src')).toContain('blob:')
    expect(directiva(csp, 'frame-src')).toEqual(["'self'", 'blob:'])
  })

  it('no abre Supabase a imágenes ni a frames: se baja por connect-src', () => {
    expect(directiva(csp, 'img-src')?.some(s => s.includes('supabase'))).toBe(false)
    expect(directiva(csp, 'frame-src')?.some(s => s.includes('supabase'))).toBe(false)
    expect(directiva(csp, 'connect-src')).toContain('https://*.supabase.co')
  })

  it('nadie puede enmarcar la app', () => {
    expect(directiva(csp, 'frame-ancestors')).toEqual(["'none'"])
  })
})
