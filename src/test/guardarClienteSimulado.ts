/**
 * Una `guardar_cliente` de mentira para los tests de `useClientesQuery` (C4b v2 de #1603).
 *
 * El alta y la edición de un cliente pasaron de varias escrituras REST a una RPC. Los tests que
 * miraban lo que viajaba en el INSERT o en el PATCH siguen mirándolo: el `campos` de la RPC va al
 * `insertSpy` (como `[fila]`, la forma del INSERT) o al `updateSpy` (el patch). Lo demás —el
 * duplicado y otras RPC— lo contesta `resto`.
 */
import { vi } from 'vitest'

type Spy = (arg: unknown) => unknown

export const SIN_DUPLICADO_RPC_TEST = {
  bloquea: false, avisa: false, motivo: null, distancia_m: null, cliente_visible: null,
}

export function simularGuardarCliente(opciones: {
  insertSpy?: Spy
  updateSpy?: Spy
  guardarSpy?: Spy
  cliente?: Record<string, unknown>
  resto?: (fn: string, args: unknown) => unknown
} = {}) {
  return vi.fn((fn: string, args: Record<string, unknown>) => {
    if (fn === 'guardar_cliente') {
      const p = args.p_cliente as { id?: number; campos?: Record<string, unknown>; preventista_ids?: string[] }
      opciones.guardarSpy?.(p)
      if (p.id == null) opciones.insertSpy?.([p.campos])
      else opciones.updateSpy?.(p.campos)
      return Promise.resolve({
        data: {
          success: true,
          replay: false,
          cliente: { id: p.id != null ? String(p.id) : '77', ...(opciones.cliente ?? {}), ...(p.campos ?? {}) },
          preventista_ids: p.preventista_ids ?? [],
        },
        error: null,
      })
    }
    return opciones.resto ? opciones.resto(fn, args) : Promise.resolve({ data: SIN_DUPLICADO_RPC_TEST, error: null })
  })
}
