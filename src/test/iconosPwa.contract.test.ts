import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * Los íconos que declaran index.html y el manifest de la PWA.
 *
 * Por qué existe: en el iPhone, "Agregar a inicio" ponía la primera letra del
 * nombre sobre un fondo gris en vez del ícono, desde siempre. index.html
 * declaraba un ícono SVG (el camión, `icon.svg`) y el iOS reciente arma el ícono
 * de inicio también con los que declara el sitio: si elige el SVG no lo puede
 * dibujar y cae a la letra. Además iOS pinta de negro lo transparente, y algunas
 * versiones piden `/apple-touch-icon-precomposed.png` por su cuenta, que sin el
 * archivo contestaba el index.html (fallback de la SPA) con un 200.
 *
 * Nada de esto lo ve tsc, eslint ni un test que renderice: son strings en un
 * HTML y en vite.config.js, y archivos binarios en public/.
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const RAIZ = path.resolve(__dirname, '../..')
const PUBLIC = path.join(RAIZ, 'public')

const indexHtml = fs.readFileSync(path.join(RAIZ, 'index.html'), 'utf8')
const viteConfig = fs.readFileSync(path.join(RAIZ, 'vite.config.js'), 'utf8')

/** Los <link> de íconos de index.html: rel y href (sin el ?v= de cache). */
const linksDeIconos = Array.from(indexHtml.matchAll(/<link\b[^>]*>/g), (m) => m[0])
  .map((tag) => ({
    tag,
    rel: /\brel="([^"]+)"/.exec(tag)?.[1] ?? '',
    href: /\bhref="([^"]+)"/.exec(tag)?.[1] ?? '',
  }))
  .filter(({ rel }) => /\b(icon|apple-touch-icon|mask-icon)\b/.test(rel))

/** Cada `src: '...'` del manifest de VitePWA (íconos, atajos y capturas). */
const srcsDelManifest = Array.from(viteConfig.matchAll(/\bsrc:\s*'([^']+)'/g), (m) => m[1])

const enPublic = (href: string) => path.join(PUBLIC, href.replace(/^\//, '').replace(/\?.*$/, ''))

/** Tamaño y opacidad leyendo la cabecera del PNG, sin decodificarlo. */
function leerPng(archivo: string): { ancho: number; alto: number; opaco: boolean } {
  const b = fs.readFileSync(archivo)
  expect(b.subarray(0, 8).toString('hex'), `${archivo} no es un PNG`).toBe('89504e470d0a1a0a')
  const chunks: string[] = []
  for (let i = 8; i < b.length; i += 12 + b.readUInt32BE(i)) chunks.push(b.toString('ascii', i + 4, i + 8))
  // Tipos de color: 0 gris, 2 RGB, 3 paleta, 4 gris+alfa, 6 RGB+alfa. Los tres
  // primeros sólo son transparentes si traen un chunk tRNS.
  const tipo = b[25]
  return {
    ancho: b.readUInt32BE(16),
    alto: b.readUInt32BE(20),
    opaco: [0, 2, 3].includes(tipo) && !chunks.includes('tRNS'),
  }
}

describe('íconos de la PWA', () => {
  it('index.html declara íconos, y ninguno es SVG', () => {
    expect(linksDeIconos.length).toBeGreaterThan(0)
    for (const { tag, href } of linksDeIconos) {
      expect(href, tag).toMatch(/\.png(\?.*)?$/)
      expect(fs.existsSync(enPublic(href)), `${href} no está en public/`).toBe(true)
    }
  })

  it('el manifest sólo nombra PNG que existen en public/', () => {
    expect(srcsDelManifest.length).toBeGreaterThan(0)
    for (const src of srcsDelManifest) {
      expect(src).toMatch(/\.png$/)
      expect(fs.existsSync(enPublic(src)), `${src} no está en public/`).toBe(true)
    }
  })

  it('los íconos del manifest son opacos (iOS pinta de negro lo transparente)', () => {
    // Las capturas no son íconos: nadie las recorta ni les pone fondo.
    for (const src of srcsDelManifest.filter((s) => !s.startsWith('screenshot-'))) {
      expect(leerPng(enPublic(src)).opaco, `${src} tiene transparencia`).toBe(true)
    }
  })

  it('el apple-touch-icon es un PNG opaco de 180x180, y el precomposed es el mismo archivo', () => {
    const link = linksDeIconos.find(({ rel }) => rel === 'apple-touch-icon')
    expect(link?.tag).toContain('sizes="180x180"')

    const principal = enPublic(link?.href ?? '')
    const precomposed = path.join(PUBLIC, 'apple-touch-icon-precomposed.png')
    expect(leerPng(principal)).toEqual({ ancho: 180, alto: 180, opaco: true })
    expect(fs.readFileSync(precomposed).equals(fs.readFileSync(principal))).toBe(true)
  })
})
