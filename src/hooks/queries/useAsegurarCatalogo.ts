/**
 * Alta de categoría y marca desde donde se crea un producto: la ficha y la
 * compra.
 *
 * Las dos no se guardan igual en el producto, y eso decide todo:
 *  - la MARCA es una FK (`productos.marca_id`, mig 158): sin fila en `marcas` no
 *    hay nada que asignar.
 *  - la CATEGORÍA viaja como texto (`productos.categoria`) y un trigger le busca
 *    el id en `categorias` (mig 146). Si la fila no existe el producto se guarda
 *    igual, con el nombre visible en la lista, pero `categoria_id` queda NULL: para
 *    las comisiones, las metas y las asignaciones masivas es un producto sin
 *    categoría. Así quedaron FRAU, MANITO y otras seis en prod, porque el
 *    "+ Nueva categoría" de la ficha escribía sólo el texto.
 *
 * Así que las dos se crean de verdad, antes que el producto. Si después el alta
 * del producto falla, la categoría o la marca quedan creadas: es lo que se pidió,
 * y el reintento las encuentra en vez de chocar contra el UNIQUE.
 */
import { useCallback } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useSucursal } from '../../contexts/SucursalContext'
import { buscarEnCatalogo, limpiarNombreCatalogo } from '../../utils/catalogo'
import {
  categoriasKeys,
  useCategoriasQuery,
  useSubcategoriasQuery,
  useCrearCategoriaMutation,
  useCrearSubcategoriaMutation,
} from './useCategoriasQuery'
import { marcasKeys, useMarcasQuery, useCrearMarcaMutation } from './useMarcasQuery'

/** Nombres tipeados con "+ Nueva". Cuando vienen, mandan sobre lo elegido en la lista. */
export interface NombresNuevosCatalogo {
  categoria_nueva?: string | null
  marca_nueva?: string | null
  /**
   * Subrubro tipeado en la ficha (mig 270). Cuelga de `rubro`: el nombre del rubro
   * elegido, o el de `categoria_nueva` si se tipeó uno (se crea primero).
   */
  subrubro_nuevo?: string | null
  rubro?: string | null
}

/** Lo que el producto guarda por esos nombres. Sólo trae las claves que resolvió. */
export interface CatalogoResuelto {
  categoria?: string
  marca_id?: string
  subcategoria_id?: string
}

export function useAsegurarCatalogo() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  const { data: categorias = [] } = useCategoriasQuery()
  const { data: subrubros = [] } = useSubcategoriasQuery()
  const { data: marcas = [] } = useMarcasQuery()
  const crearSubcategoria = useCrearSubcategoriaMutation()
  const { mutateAsync: crearSubcategoriaAsync } = crearSubcategoria
  const crearCategoria = useCrearCategoriaMutation()
  const crearMarca = useCrearMarcaMutation()
  const { mutateAsync: crearCategoriaAsync } = crearCategoria
  const { mutateAsync: crearMarcaAsync } = crearMarca

  const asegurar = useCallback(async (nuevos: NombresNuevosCatalogo): Promise<CatalogoResuelto> => {
    const resuelto: CatalogoResuelto = {}
    // Fila del rubro al que se cuelga el subrubro nuevo, si lo hay.
    let rubroFila: { id: string; nombre: string } | undefined

    const categoriaNueva = limpiarNombreCatalogo(nuevos.categoria_nueva ?? '')
    if (categoriaNueva) {
      const existente = buscarEnCatalogo(categorias, categoriaNueva)
      if (existente) {
        // Reactivarla sola sería devolverle a la lista algo que alguien sacó a
        // propósito: que lo decida quien la desactivó.
        if (existente.activa === false) {
          throw new Error(`La categoría "${existente.nombre}" ya existe pero está desactivada. Reactivala desde Productos → Categorías, o elegí otra.`)
        }
        resuelto.categoria = existente.nombre
        rubroFila = existente
      } else {
        try {
          const creada = await crearCategoriaAsync(categoriaNueva)
          resuelto.categoria = creada.nombre
          rubroFila = creada
        } catch (err) {
          // La lista pudo estar vieja: otra sesión la creó hace un rato y el
          // insert chocó contra el UNIQUE. Refrescarla hace que el reintento la
          // encuentre en vez de chocar otra vez.
          void queryClient.invalidateQueries({ queryKey: categoriasKeys.lists(currentSucursalId) })
          throw err
        }
      }
    }

    const subrubroNuevo = limpiarNombreCatalogo(nuevos.subrubro_nuevo ?? '')
    if (subrubroNuevo) {
      // El subrubro es una fila hija del rubro (`parent_id`): sin fila del rubro
      // no hay de dónde colgarlo (#763), y la ficha ya no deja llegar acá.
      const padre = rubroFila ?? buscarEnCatalogo(
        categorias.filter(c => c.activa !== false),
        nuevos.rubro ?? '',
      )
      if (!padre) {
        throw new Error(`El rubro "${nuevos.rubro ?? ''}" no está cargado en Categorías. Creá el rubro ahí antes de asignarle subrubros.`)
      }
      const existente = buscarEnCatalogo(subrubros.filter(s => s.parent_id === padre.id), subrubroNuevo)
      if (existente) {
        if (existente.activa === false) {
          throw new Error(`El subrubro "${existente.nombre}" ya existe pero está desactivado. Reactivalo desde Productos → Categorías, o elegí otro.`)
        }
        resuelto.subcategoria_id = existente.id
      } else {
        try {
          resuelto.subcategoria_id = (await crearSubcategoriaAsync({ nombre: subrubroNuevo, parentId: padre.id })).id
        } catch (err) {
          void queryClient.invalidateQueries({ queryKey: categoriasKeys.lists(currentSucursalId) })
          throw err
        }
      }
    }

    const marcaNueva = limpiarNombreCatalogo(nuevos.marca_nueva ?? '')
    if (marcaNueva) {
      const existente = buscarEnCatalogo(marcas, marcaNueva)
      if (existente) {
        if (!existente.activa) {
          throw new Error(`La marca "${existente.nombre}" ya existe pero está desactivada. Reactivala desde Productos → Marcas, o elegí otra.`)
        }
        resuelto.marca_id = existente.id
      } else {
        try {
          resuelto.marca_id = (await crearMarcaAsync(marcaNueva)).id
        } catch (err) {
          void queryClient.invalidateQueries({ queryKey: marcasKeys.lists(currentSucursalId) })
          throw err
        }
      }
    }

    return resuelto
  }, [categorias, subrubros, marcas, crearCategoriaAsync, crearSubcategoriaAsync, crearMarcaAsync, queryClient, currentSucursalId])

  return { asegurar, creando: crearCategoria.isPending || crearSubcategoria.isPending || crearMarca.isPending }
}
