import { describe, it, expect } from 'vitest'
import { normalizarHojasDeRuta, sumarDias, CLAVES_DE_PLATA } from './hojasDeRutaDeposito'

// Forma real de `hojas_de_ruta_deposito` (mig 305): ids bigint llegan como number.
const parada = (id: number, extra: Record<string, unknown> = {}) => ({
  id,
  estado: 'asignado',
  canal: 'app',
  fecha: '2026-10-07',
  fecha_entrega_programada: null,
  created_at: '2026-10-07T12:00:00Z',
  notas: null,
  orden_entrega: 1,
  cliente: { id: 9, nombre_fantasia: 'Kiosco Lola', razon_social: null, direccion: 'San Martín 100', aclaracion_direccion: null, telefono: null, zona: 'Centro', horarios_atencion: null },
  items: [
    {
      id: 501, producto_id: 161, cantidad: 2, es_bonificacion: false, descripcion_regalo: null, unidades_por_bloque_al_crear: null,
      producto: { id: 161, nombre: 'PLACER ANANA 500 cc', codigo: '121505', categoria: 'PLACER', subcategoria_id: 'sub-1', unidades_de_venta_por_fardo: null, etiqueta_bulto: null },
      promocion: null,
    },
  ],
  cambio: null,
  ...extra,
})

const respuesta = {
  fecha: '2026-10-08',
  rutas: [{ recorrido_id: 77, estado: 'en_curso', transportista: { id: 'u-1', nombre: 'Rober' }, paradas: [parada(7143), parada(7150, { orden_entrega: 2 })] }],
  sin_ruta: [parada(8000, { estado: 'pendiente', orden_entrega: undefined })],
  subrubros: { 'sub-1': 'Jugos' },
}

describe('normalizarHojasDeRuta', () => {
  it('pasa los ids a string y conserva rutas, paradas y pedidos sin ruta', () => {
    const r = normalizarHojasDeRuta(respuesta)
    expect(r.fecha).toBe('2026-10-08')
    expect(r.rutas).toHaveLength(1)
    expect(r.rutas[0].recorridoId).toBe('77')
    expect(r.rutas[0].transportista.nombre).toBe('Rober')
    expect(r.rutas[0].paradas.map(p => p.id)).toEqual(['7143', '7150'])
    expect(r.rutas[0].paradas[0].items[0].producto_id).toBe('161')
    expect(r.sinRuta.map(p => p.id)).toEqual(['8000'])
    expect(r.subrubros).toEqual({ 'sub-1': 'Jugos' })
  })

  it('una respuesta vacía o nula no rompe: sin rutas, sin pendientes', () => {
    expect(normalizarHojasDeRuta(null)).toEqual({ fecha: null, rutas: [], sinRuta: [], subrubros: {} })
    expect(normalizarHojasDeRuta({ fecha: '2026-10-08' }).rutas).toEqual([])
  })

  it('un chofer sin nombre se muestra igual', () => {
    const r = normalizarHojasDeRuta({ ...respuesta, rutas: [{ ...respuesta.rutas[0], transportista: null }] })
    expect(r.rutas[0].transportista.nombre).toBe('Sin chofer')
  })

  it('no deja pasar ninguna clave de plata aunque el servidor la mandara', () => {
    // Defensa en profundidad: si alguien agrega `total` a la RPC, la pantalla
    // igual no lo recibe. La garantía de verdad es la RPC (mig 305).
    const conPlata = {
      ...respuesta,
      rutas: [{ ...respuesta.rutas[0], total_facturado: 999, paradas: [parada(1, { total: 5000, monto_pagado: 10, items: [{ ...parada(1).items[0], precio_unitario: 100, subtotal: 200 }] })] }],
    }
    const json = JSON.stringify(normalizarHojasDeRuta(conPlata))
    for (const clave of CLAVES_DE_PLATA) expect(json).not.toContain(`"${clave}"`)
  })
})

describe('sumarDias', () => {
  it('suma y resta días sobre YYYY-MM-DD sin correrse por zona horaria', () => {
    expect(sumarDias('2026-10-08', 1)).toBe('2026-10-09')
    expect(sumarDias('2026-10-01', -1)).toBe('2026-09-30')
    expect(sumarDias('2026-12-31', 1)).toBe('2027-01-01')
  })
})
