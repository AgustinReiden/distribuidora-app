/**
 * INF-7 (#1563): la factura escaneada se muestra como `blob:`, porque la CSP no
 * deja cargar Storage de Supabase en un `<img>` ni en un `<iframe>`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { tipoDeArchivoFactura, urlLocalDeArchivo } from './archivoLocal'

const crearUrl = vi.fn((_b: Blob) => 'blob:factura-1')

beforeEach(() => {
  crearUrl.mockClear()
  Object.assign(URL, { createObjectURL: crearUrl, revokeObjectURL: vi.fn() })
})

describe('urlLocalDeArchivo', () => {
  it('baja la URL firmada y devuelve una blob: con su contenido', async () => {
    const bajar = vi.fn(async () => new Response('png', { headers: { 'content-type': 'image/png' } }))

    const url = await urlLocalDeArchivo('https://ref.supabase.co/storage/v1/object/sign/facturas/1/a.png?token=t', undefined, bajar)

    expect(url).toBe('blob:factura-1')
    expect(bajar).toHaveBeenCalledWith('https://ref.supabase.co/storage/v1/object/sign/facturas/1/a.png?token=t')
    expect(crearUrl.mock.calls[0][0].type).toBe('image/png')
  })

  it('un PDF servido como octet-stream se muestra como PDF, no se descarga', async () => {
    const bajar = vi.fn(async () => new Response('%PDF', { headers: { 'content-type': 'application/octet-stream' } }))

    await urlLocalDeArchivo('https://x/a.pdf', tipoDeArchivoFactura('1/a.PDF'), bajar)

    expect(crearUrl.mock.calls[0][0].type).toBe('application/pdf')
  })

  it('un error de Storage es un error, no una blob: vacía', async () => {
    const bajar = vi.fn(async () => new Response('vencida', { status: 400 }))

    await expect(urlLocalDeArchivo('https://x/a.png', undefined, bajar)).rejects.toThrow(/HTTP 400/)
    expect(crearUrl).not.toHaveBeenCalled()
  })
})

describe('tipoDeArchivoFactura', () => {
  it('el PDF lo fija la extensión; una imagen queda con el tipo que mande Storage', () => {
    expect(tipoDeArchivoFactura('3/abc.pdf')).toBe('application/pdf')
    expect(tipoDeArchivoFactura('3/abc.jpg')).toBeUndefined()
  })
})
