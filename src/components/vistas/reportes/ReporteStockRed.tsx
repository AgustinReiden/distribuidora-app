/**
 * Stock de la red — stock, costo y precio de TODAS las sucursales.
 *
 * SOLO LECTURA. Cualquier admin ve las dos sucursales, esté asignado o no: el
 * dato viene del RPC `reporte_stock_red`, que no cruza contra
 * `usuario_sucursales`. No se relajó la policy `mt_productos_select` porque
 * eso abriría el catálogo entero (selector de items del pedido, mermas,
 * backup a Excel) y expondría la fila completa; el RPC elige columna por
 * columna.
 *
 * Sobre el emparejado: no hay clave que una un producto de una sucursal con
 * "el mismo" de la otra. Se usa el criterio estricto de `emparejarRed`
 * (código o nombre exactos) y lo que no empareja se muestra aparte, con su
 * nombre y su cantidad: son catálogos distintos, no un error del reporte.
 */
import React, { useMemo, useState } from 'react';
import { AlertTriangle, Network, Search } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import { useStockRedQuery } from '../../../hooks/queries/useStockRedQuery';
import {
  emparejarRed,
  coincideBusqueda,
  tieneStock,
  type FilaRed,
  type ProductoRed,
} from '../../../utils/stockRed';

export interface ReporteStockRedProps {
  formatPrecio: (precio: number) => string;
}

function claseStock(stock: number): string {
  if (stock < 0) return 'text-red-600 dark:text-red-400';
  if (stock === 0) return 'text-gray-400';
  return 'text-gray-800 dark:text-gray-100';
}

/** Las tres celdas (stock/costo/precio) de una sucursal en la tabla comparativa. */
function CeldasSucursal({
  producto,
  formatPrecio,
}: {
  producto: ProductoRed | undefined;
  formatPrecio: (precio: number) => string;
}): React.ReactElement {
  if (!producto) {
    return (
      <>
        <td className="py-2 pr-4 text-right text-gray-300 dark:text-gray-600">—</td>
        <td className="py-2 pr-4 text-right text-gray-300 dark:text-gray-600">—</td>
        <td className="py-2 pr-4 text-right text-gray-300 dark:text-gray-600">—</td>
      </>
    );
  }
  return (
    <>
      <td className={`py-2 pr-4 text-right font-semibold ${claseStock(producto.stock)}`}>
        {producto.stock}
      </td>
      <td className="py-2 pr-4 text-right">
        {producto.costo_promedio != null ? formatPrecio(producto.costo_promedio) : '—'}
      </td>
      <td className="py-2 pr-4 text-right">{formatPrecio(producto.precio)}</td>
    </>
  );
}

/** Tabla plana de una sola sucursal (catálogo completo o exclusivos). */
function TablaSucursal({
  filas,
  sucursalId,
  formatPrecio,
}: {
  filas: FilaRed[];
  sucursalId: number;
  formatPrecio: (precio: number) => string;
}): React.ReactElement {
  return (
    <table className="w-full text-sm">
      <thead>
        <tr className="text-left text-gray-500 dark:text-gray-400 border-b dark:border-gray-700">
          <th className="py-2 pr-4">Producto</th>
          <th className="py-2 pr-4">Categoría</th>
          <th className="py-2 pr-4 text-right">Stock</th>
          <th className="py-2 pr-4 text-right">Costo prom.</th>
          <th className="py-2 pr-4 text-right">Reposición</th>
          <th className="py-2 text-right">Precio</th>
        </tr>
      </thead>
      <tbody>
        {filas.map((f) => {
          const p = f.porSucursal[sucursalId];
          if (!p) return null;
          return (
            <tr key={f.clave} className="border-b dark:border-gray-700/50 last:border-0">
              <td className="py-2 pr-4 text-gray-800 dark:text-gray-100">
                {p.nombre}
                {p.codigo && <span className="ml-2 text-xs text-gray-400">{p.codigo}</span>}
                {p.ultimo_tipo_compra && (
                  <span className="ml-2 text-[10px] font-semibold px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-700 text-gray-500 dark:text-gray-300">
                    {p.ultimo_tipo_compra}
                  </span>
                )}
              </td>
              <td className="py-2 pr-4 text-gray-500 dark:text-gray-400">{p.categoria}</td>
              <td className={`py-2 pr-4 text-right font-semibold ${claseStock(p.stock)}`}>
                {p.stock}
              </td>
              <td className="py-2 pr-4 text-right">
                {p.costo_promedio != null ? formatPrecio(p.costo_promedio) : '—'}
              </td>
              <td className="py-2 pr-4 text-right">
                {p.costo_reposicion != null ? formatPrecio(p.costo_reposicion) : '—'}
              </td>
              <td className="py-2 text-right">{formatPrecio(p.precio)}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

export function ReporteStockRed({ formatPrecio }: ReporteStockRedProps): React.ReactElement {
  const { data, isLoading, error } = useStockRedQuery(null);
  const [sucursalSel, setSucursalSel] = useState<number | 'red'>('red');
  const [busqueda, setBusqueda] = useState('');
  const [categoriaFiltro, setCategoriaFiltro] = useState('todas');
  const [soloConStock, setSoloConStock] = useState(false);

  const sucursales = useMemo(() => data?.sucursales ?? [], [data]);
  const orden = useMemo(() => sucursales.map((s) => s.sucursal_id), [sucursales]);

  const { emparejados, sinPar } = useMemo(
    () => emparejarRed(data?.productos ?? [], orden),
    [data, orden]
  );

  const filtrar = useMemo(
    () =>
      (filas: FilaRed[]): FilaRed[] =>
        filas.filter(
          (f) =>
            (categoriaFiltro === 'todas' || f.categoria === categoriaFiltro) &&
            (!soloConStock || tieneStock(f)) &&
            coincideBusqueda(f, busqueda)
        ),
    [busqueda, categoriaFiltro, soloConStock]
  );

  const categorias = useMemo(
    () => Array.from(new Set((data?.productos ?? []).map((p) => p.categoria))).sort(),
    [data]
  );

  if (isLoading) return <LoadingSpinner />;
  if (error) {
    return (
      <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 text-red-700 dark:text-red-300 text-sm">
        No se pudo cargar el stock de la red: {(error as Error).message}
      </div>
    );
  }
  if (!data) return <LoadingSpinner />;

  const enVariasSucursales = filtrar(emparejados);
  const sinParFiltrado = filtrar(sinPar);
  const ambiguos = sinPar.filter((f) => f.ambiguo);
  const sucursalesVisibles =
    sucursalSel === 'red' ? sucursales : sucursales.filter((s) => s.sucursal_id === sucursalSel);

  // Con una sucursal elegida no hay comparación: es su catálogo completo.
  const filasUnaSucursal =
    sucursalSel === 'red'
      ? []
      : filtrar([...emparejados, ...sinPar]).filter((f) => f.porSucursal[sucursalSel] != null);

  return (
    <div className="space-y-4">
      <div className="flex items-start gap-2 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-3 text-sm text-blue-800 dark:text-blue-200">
        <Network className="w-4 h-4 mt-0.5 shrink-0" />
        <p>
          Stock, costo y precio de todas las sucursales. <strong>Solo lectura</strong>: desde acá
          no se opera sobre la otra sucursal.
        </p>
      </div>

      {/* KPIs por sucursal */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {sucursalesVisibles.map((s) => (
          <div
            key={s.sucursal_id}
            className="bg-white dark:bg-gray-800 border dark:border-gray-700 p-4 rounded-lg"
          >
            <p className="text-sm text-gray-500 dark:text-gray-400">{s.sucursal_nombre}</p>
            <p className="text-xl font-bold text-gray-800 dark:text-gray-100">
              {s.unidades} unidades
            </p>
            <p className="text-xs text-gray-500 mt-1">
              {s.productos_con_stock} de {s.productos} productos con stock ·{' '}
              {formatPrecio(s.valuacion_promedio)} valuado
            </p>
          </div>
        ))}
      </div>

      {/* Filtros */}
      <div className="flex flex-wrap gap-3 items-center">
        <select
          aria-label="Sucursal"
          value={sucursalSel}
          onChange={(e) =>
            setSucursalSel(e.target.value === 'red' ? 'red' : Number(e.target.value))
          }
          className="px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white"
        >
          <option value="red">Red (consolidado)</option>
          {sucursales.map((s) => (
            <option key={s.sucursal_id} value={s.sucursal_id}>
              {s.sucursal_nombre}
            </option>
          ))}
        </select>

        <div className="relative">
          <Search className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
          <input
            aria-label="Buscar producto"
            type="search"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre o código"
            className="pl-9 pr-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white"
          />
        </div>

        <select
          aria-label="Categoría"
          value={categoriaFiltro}
          onChange={(e) => setCategoriaFiltro(e.target.value)}
          className="px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white"
        >
          <option value="todas">Todas las categorías</option>
          {categorias.map((c) => (
            <option key={c} value={c}>
              {c}
            </option>
          ))}
        </select>

        <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
          <input
            type="checkbox"
            checked={soloConStock}
            onChange={(e) => setSoloConStock(e.target.checked)}
            className="rounded border-gray-300"
          />
          Solo con stock
        </label>
      </div>

      {sucursalSel === 'red' ? (
        <>
          {/* En más de una sucursal */}
          <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-hidden">
            <div className="px-4 pt-4">
              <h3 className="font-semibold text-gray-700 dark:text-gray-200">
                En más de una sucursal ({enVariasSucursales.length})
              </h3>
              <p className="text-xs text-gray-500 mt-1">
                Emparejados por código exacto o nombre exacto. No hay tabla de equivalencias entre
                sucursales, así que lo que no empareja va más abajo, listado.
              </p>
            </div>
            <div className="overflow-x-auto p-4">
              {enVariasSucursales.length === 0 ? (
                <p className="text-sm text-gray-500 py-2">
                  Ningún producto empareja con el filtro elegido.
                </p>
              ) : (
                <table className="w-full text-sm">
                  <thead>
                    <tr className="text-left text-gray-500 dark:text-gray-400">
                      <th className="py-2 pr-4" rowSpan={2}>
                        Producto
                      </th>
                      {sucursales.map((s) => (
                        <th
                          key={s.sucursal_id}
                          colSpan={3}
                          className="py-2 pr-4 text-center border-b dark:border-gray-700"
                        >
                          {s.sucursal_nombre}
                        </th>
                      ))}
                    </tr>
                    <tr className="text-left text-gray-500 dark:text-gray-400 border-b dark:border-gray-700">
                      {sucursales.map((s) => (
                        <React.Fragment key={s.sucursal_id}>
                          <th className="py-2 pr-4 text-right font-normal">Stock</th>
                          <th className="py-2 pr-4 text-right font-normal">Costo</th>
                          <th className="py-2 pr-4 text-right font-normal">Precio</th>
                        </React.Fragment>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {enVariasSucursales.map((f) => (
                      <tr key={f.clave} className="border-b dark:border-gray-700/50 last:border-0">
                        <td className="py-2 pr-4 text-gray-800 dark:text-gray-100">
                          {f.nombre}
                          {f.codigo && (
                            <span className="ml-2 text-xs text-gray-400">{f.codigo}</span>
                          )}
                          <span className="block text-xs text-gray-400">{f.categoria}</span>
                          {/* El emparejado es una heurística: si el producto se
                              llama distinto en la otra sucursal, se muestra —
                              es lo que deja auditar el par. */}
                          {Object.values(f.porSucursal)
                            .filter((p): p is ProductoRed => p != null && p.nombre !== f.nombre)
                            .map((p) => (
                              <span
                                key={p.sucursal_id}
                                className="block text-xs text-gray-400 italic"
                              >
                                {p.sucursal_nombre}: {p.nombre}
                              </span>
                            ))}
                        </td>
                        {sucursales.map((s) => (
                          <CeldasSucursal
                            key={s.sucursal_id}
                            producto={f.porSucursal[s.sucursal_id]}
                            formatPrecio={formatPrecio}
                          />
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>

          {ambiguos.length > 0 && (
            <div className="flex items-start gap-2 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg p-3 text-sm text-amber-800 dark:text-amber-200">
              <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
              <p>
                {ambiguos.length} producto(s) quedaron sin emparejar porque el código o el nombre
                coincide con más de uno: {ambiguos.map((f) => f.nombre).join(', ')}.
              </p>
            </div>
          )}

          {/* Lo que existe en una sola sucursal */}
          {sucursales.map((s) => {
            const filas = sinParFiltrado.filter((f) => f.sucursales[0] === s.sucursal_id);
            return (
              <div
                key={s.sucursal_id}
                className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-hidden"
              >
                <h3 className="font-semibold text-gray-700 dark:text-gray-200 px-4 pt-4">
                  Solo en {s.sucursal_nombre} ({filas.length})
                </h3>
                <div className="overflow-x-auto p-4">
                  {filas.length === 0 ? (
                    <p className="text-sm text-gray-500 py-2">
                      Nada exclusivo de esta sucursal con el filtro elegido.
                    </p>
                  ) : (
                    <TablaSucursal
                      filas={filas}
                      sucursalId={s.sucursal_id}
                      formatPrecio={formatPrecio}
                    />
                  )}
                </div>
              </div>
            );
          })}
        </>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-hidden">
          <h3 className="font-semibold text-gray-700 dark:text-gray-200 px-4 pt-4">
            {sucursales.find((s) => s.sucursal_id === sucursalSel)?.sucursal_nombre ?? 'Sucursal'} (
            {filasUnaSucursal.length})
          </h3>
          <div className="overflow-x-auto p-4">
            {filasUnaSucursal.length === 0 ? (
              <p className="text-sm text-gray-500 py-2">Sin productos para el filtro elegido.</p>
            ) : (
              <TablaSucursal
                filas={filasUnaSucursal}
                sucursalId={sucursalSel}
                formatPrecio={formatPrecio}
              />
            )}
          </div>
        </div>
      )}

      <p className="text-xs text-gray-500">
        Costo = costo promedio ponderado; "reposición" es el costo de la última compra (FC: neto +
        impuestos internos · ZZ: total pagado, que ya los incluye). El precio es el de lista de
        cada sucursal.
      </p>
    </div>
  );
}
