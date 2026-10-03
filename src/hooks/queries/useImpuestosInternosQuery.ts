/**
 * TanStack Query hooks para los encuadres de impuestos internos (mig 277).
 *
 * Catálogos GLOBALES (sin sucursal): la ley es nacional y un id común hace que
 * un traspaso entre sucursales no tenga que mapear nada. Por eso las keys no
 * llevan sucursal.
 *
 * Cambiar una alícuota va por la RPC `cambiar_alicuota_ii`, nunca por dos
 * escrituras sueltas: cerrar la vigente y abrir la nueva por separado deja al
 * encuadre un instante sin tasa, y el refresco de la base pondría el impuesto
 * interno de todas sus fichas en 0.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { AlicuotaII, EncuadreII } from '../../utils/impuestosInternos'

export interface CatalogoII {
  encuadres: EncuadreII[]
  alicuotas: AlicuotaII[]
}

export const impuestosInternosKeys = {
  all: ['impuestos_internos'] as const,
  catalogo: () => [...impuestosInternosKeys.all, 'catalogo'] as const,
}

async function fetchCatalogoII(): Promise<CatalogoII> {
  const [encuadres, alicuotas] = await Promise.all([
    supabase.from('ii_encuadres').select('id, nombre, criterio, activo').order('id'),
    supabase.from('ii_alicuotas').select('id, encuadre_id, tasa_nominal, vigente_desde, vigente_hasta').order('vigente_desde'),
  ])
  if (encuadres.error) throw encuadres.error
  if (alicuotas.error) throw alicuotas.error
  // Los bigint llegan como number y numeric como string: se normaliza una sola
  // vez acá para que nadie compare '1' con 1.
  return {
    encuadres: (encuadres.data ?? []).map(e => ({
      id: String(e.id),
      nombre: e.nombre,
      criterio: e.criterio ?? null,
      activo: e.activo,
    })),
    alicuotas: (alicuotas.data ?? []).map(a => ({
      id: String(a.id),
      encuadre_id: String(a.encuadre_id),
      tasa_nominal: Number(a.tasa_nominal),
      vigente_desde: a.vigente_desde,
      vigente_hasta: a.vigente_hasta ?? null,
    })),
  }
}

export function useCatalogoIIQuery() {
  return useQuery({
    queryKey: impuestosInternosKeys.catalogo(),
    queryFn: fetchCatalogoII,
    staleTime: 10 * 60 * 1000,
  })
}

export interface EncuadreIIInput {
  nombre: string
  criterio?: string | null
  activo?: boolean
}

export function useGuardarEncuadreIIMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, data }: { id?: string; data: EncuadreIIInput }) => {
      const nombre = data.nombre.trim()
      if (!nombre) throw new Error('El encuadre necesita un nombre')
      const fila = {
        nombre,
        criterio: data.criterio?.trim() || null,
        ...(data.activo !== undefined ? { activo: data.activo } : {}),
      }
      const query = id
        ? supabase.from('ii_encuadres').update(fila).eq('id', id).select('id').single()
        : supabase.from('ii_encuadres').insert([fila]).select('id').single()
      const { data: res, error } = await query
      if (error) {
        if (error.code === '23505') throw new Error(`Ya existe un encuadre llamado "${nombre}"`)
        throw error
      }
      return String(res.id)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: impuestosInternosKeys.all })
    },
  })
}

export interface CambiarAlicuotaInput {
  encuadreId: string
  /** Fracción: 0.08 es el 8%. */
  tasaNominal: number
  /** 'YYYY-MM-DD'; no puede ser futura (la base lo rechaza). */
  vigenteDesde: string
}

export function useCambiarAlicuotaIIMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ encuadreId, tasaNominal, vigenteDesde }: CambiarAlicuotaInput) => {
      if (!(tasaNominal >= 0 && tasaNominal < 1)) {
        throw new Error('La tasa nominal tiene que estar entre 0% y 100%')
      }
      const { error } = await supabase.rpc('cambiar_alicuota_ii', {
        p_encuadre_id: Number(encuadreId),
        p_tasa_nominal: tasaNominal,
        p_vigente_desde: vigenteDesde,
      })
      if (error) {
        if (error.code === '22023') throw new Error('Todavía no se pueden cargar alícuotas con vigencia futura.')
        if (error.code === '23P01') throw new Error('Esa vigencia se superpone con otra alícuota del mismo encuadre.')
        throw error
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: impuestosInternosKeys.all })
      // La base acaba de recalcular el impuesto interno de las fichas, en las
      // dos sucursales: se invalida el prefijo, no la key de una sola.
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}
