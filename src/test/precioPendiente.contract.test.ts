import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { PRECIO_PENDIENTE, tienePrecioDeVenta } from '../utils/precioVenta'

/**
 * "Sin precio de venta" es UNA regla con dos lados que tienen que coincidir:
 *
 *  - el server: `validar_precio_item_pedido` (mig 139) rechaza en el alta la
 *    línea de un producto con `precio IS NULL OR precio <= 0`, salvo el regalo
 *    y, desde la 317, el vale blanco; y `notificar_producto_sin_precio` avisa
 *    a admins y encargados cuando nace un producto así;
 *  - el front: `tienePrecioDeVenta` decide qué se ofrece deshabilitado, y el
 *    alta rápida de la compra guarda `PRECIO_PENDIENTE`.
 *
 * Reporte del dueño (20/10/2026): el alta rápida guardaba el costo con IVA como
 * precio. Para el trigger eso era un precio válido y el preventista vendía al
 * costo. Si alguien vuelve a "precargar" el precio, o el server cambia qué
 * cuenta como sin precio, este test se pone rojo.
 *
 * Las migraciones son la vista curada (Trampa 3): la definición vigente se
 * verificó contra prod con `pg_get_functiondef` el 20/10/2026.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const RAIZ = path.resolve(__dirname, '..', '..')
// Normaliza CRLF: el checkout de Windows puede traerlos.
const leer = (rel: string) => fs.readFileSync(path.join(RAIZ, rel), 'utf8').replace(/\r\n/g, '\n')

describe('contrato: producto sin precio de venta', () => {
  const m139 = leer('migrations/139_guarda_precio_venta.sql')
  const m317 = leer('migrations/317_el_vale_blanco_es_un_comprobante.sql')

  it('el trigger de pedido_items rechaza en el alta un producto con lista NULL o <= 0', () => {
    expect(m139).toMatch(/CREATE TRIGGER trg_validar_precio_item_pedido\s+BEFORE INSERT/)
    expect(m139).toContain("IF TG_OP = 'INSERT' AND (v_precio_lista IS NULL OR v_precio_lista <= 0) THEN")
    expect(m139).toContain('está pendiente de carga de precio de venta y no puede venderse')
  })

  it('la 317 sólo agrega la excepción del vale blanco, no afloja la condición', () => {
    expect(m317).toContain(
      "IF TG_OP = 'INSERT' AND (v_precio_lista IS NULL OR v_precio_lista <= 0)\n" +
      '     -- mig 3XA: un vale blanco va a costo, no a lista (N5).\n' +
      "     AND NOT EXISTS (SELECT 1 FROM pedidos WHERE id = NEW.pedido_id AND tipo_factura = 'VB') THEN",
    )
  })

  it('el alta de un producto sin precio avisa a admins y encargados', () => {
    expect(m139).toMatch(/AFTER INSERT ON public\.productos[\s\S]*?WHEN \(NEW\.precio IS NULL OR NEW\.precio <= 0\)/)
  })

  it('el front usa el mismo corte que el trigger', () => {
    const servidorRechaza = (precio: number | null) => precio === null || precio <= 0
    for (const precio of [null, -5, 0, 0.001, 0.01, 1, 7400]) {
      expect(tienePrecioDeVenta({ precio })).toBe(!servidorRechaza(precio))
    }
  })

  it('el precio "pendiente" es justamente uno que el trigger rechaza', () => {
    expect(PRECIO_PENDIENTE).toBe(0)
    expect(tienePrecioDeVenta({ precio: PRECIO_PENDIENTE })).toBe(false)
  })
})
