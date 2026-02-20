/**
 * ModalImportarCompra
 *
 * Permite importar ítems de compra desde un archivo Excel.
 * Mapea código de producto, cantidad, costo unitario y bonificación.
 * Sigue el patrón de ModalImportarPrecios.tsx.
 */
import { useState, useCallback } from 'react';
import type { ChangeEvent, DragEvent } from 'react';
import { X, Upload, FileSpreadsheet, AlertCircle, CheckCircle, Download } from 'lucide-react';
const loadExcelUtils = () => import('../../utils/excel');
import { validateExcelFile, validateAndSanitizeExcelData, FILE_LIMITS } from '../../utils/fileValidation';
import type { ProductoDB } from '../../types';
import type { CompraItemForm } from './ModalCompra';

// =============================================================================
// TIPOS
// =============================================================================

export interface CompraImportPreviewItem {
  fila: number;
  codigo: string;
  cantidad: number;
  costoUnitario: number;
  bonificacion: number;
  productoId: string | null;
  productoNombre: string | null;
  estado: 'encontrado' | 'no_encontrado';
}

export interface ModalImportarCompraProps {
  productos: ProductoDB[];
  onImportar: (items: CompraItemForm[]) => void;
  onClose: () => void;
}

interface ExcelRow {
  [key: string]: string | number | null | undefined;
}

interface ColumnasMap {
  codigo: string[];
  cantidad: string[];
  costoUnitario: string[];
  bonificacion: string[];
}

/**
 * Normaliza un valor numérico desde diferentes formatos regionales
 */
const normalizarNumero = (valor: string | number | null | undefined): number => {
  if (valor === null || valor === undefined || valor === '') return 0;
  if (typeof valor === 'number') return isNaN(valor) ? 0 : valor;

  let str = String(valor).trim();
  str = str.replace(/[$€£¥]/g, '').trim();

  const ultimoPunto = str.lastIndexOf('.');
  const ultimaComa = str.lastIndexOf(',');

  if (ultimaComa > ultimoPunto) {
    str = str.replace(/\./g, '').replace(',', '.');
  } else if (ultimoPunto > ultimaComa && ultimaComa !== -1) {
    str = str.replace(/,/g, '');
  } else if (ultimaComa !== -1 && ultimoPunto === -1) {
    str = str.replace(',', '.');
  }

  const resultado = parseFloat(str);
  return isNaN(resultado) ? 0 : resultado;
};

export default function ModalImportarCompra({ productos, onImportar, onClose }: ModalImportarCompraProps) {
  const [archivo, setArchivo] = useState<File | null>(null);
  const [preview, setPreview] = useState<CompraImportPreviewItem[]>([]);
  const [erroresParseo, setErroresParseo] = useState<string[]>([]);

  const COLUMNAS: ColumnasMap = {
    codigo: ['codigo', 'code', 'sku', 'cod', 'articulo'],
    cantidad: ['cantidad', 'cant', 'qty', 'unidades'],
    costoUnitario: ['costo', 'precio', 'neto', 'costo_unitario', 'costo unitario', 'precio_neto', 'precio neto'],
    bonificacion: ['bonificacion', 'bonif', 'gratis', 'bonus']
  };

  const encontrarValor = (fila: ExcelRow, posiblesNombres: string[]): string | number | null | undefined => {
    for (const nombre of posiblesNombres) {
      const key = Object.keys(fila).find(k => k.toLowerCase().trim().includes(nombre));
      if (key && fila[key] !== undefined && fila[key] !== '') return fila[key];
    }
    return null;
  };

  const parsearExcel = useCallback(async (file: File): Promise<void> => {
    try {
      const { readExcelFile } = await loadExcelUtils();
      const jsonData = await readExcelFile(file) as ExcelRow[];

      const validation = validateAndSanitizeExcelData(jsonData);
      if (!validation.valid) {
        setErroresParseo([validation.error || 'Error de validacion']);
        return;
      }

      if (validation.warnings) {
        setErroresParseo(validation.warnings);
      }

      procesarDatos((validation.data || jsonData) as ExcelRow[]);
    } catch (err) {
      const error = err as Error;
      setErroresParseo(['Error al leer el archivo: ' + error.message]);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [productos]);

  const procesarDatos = (datos: ExcelRow[]): void => {
    const resultados: CompraImportPreviewItem[] = [];
    const erroresTemp: string[] = [];

    datos.forEach((fila, index) => {
      const codigo = encontrarValor(fila, COLUMNAS.codigo);
      if (!codigo) {
        erroresTemp.push(`Fila ${index + 2}: Codigo no encontrado`);
        return;
      }

      const productoExistente = productos.find(
        p => p.codigo?.toLowerCase().trim() === codigo.toString().toLowerCase().trim()
      );

      const cantidad = Math.max(1, Math.round(normalizarNumero(encontrarValor(fila, COLUMNAS.cantidad))));
      const costoUnitario = normalizarNumero(encontrarValor(fila, COLUMNAS.costoUnitario));
      const bonificacion = Math.max(0, normalizarNumero(encontrarValor(fila, COLUMNAS.bonificacion)));

      resultados.push({
        fila: index + 2,
        codigo: codigo.toString(),
        cantidad,
        costoUnitario,
        bonificacion,
        productoId: productoExistente?.id || null,
        productoNombre: productoExistente?.nombre || null,
        estado: productoExistente ? 'encontrado' : 'no_encontrado'
      });
    });

    setPreview(resultados);
    setErroresParseo(prev => [...prev, ...erroresTemp]);
  };

  const handleFileChange = (e: ChangeEvent<HTMLInputElement>): void => {
    const file = e.target.files?.[0];
    if (!file) return;

    const validation = validateExcelFile(file);
    if (!validation.valid) {
      setErroresParseo([validation.error || 'Error de validacion']);
      return;
    }

    setArchivo(file);
    setErroresParseo([]);
    parsearExcel(file);
  };

  const handleDrop = useCallback((e: DragEvent<HTMLDivElement>): void => {
    e.preventDefault();
    const file = e.dataTransfer.files[0];
    if (!file) return;

    const validation = validateExcelFile(file);
    if (!validation.valid) {
      setErroresParseo([validation.error || 'Error de validacion']);
      return;
    }

    setArchivo(file);
    setErroresParseo([]);
    parsearExcel(file);
  }, [parsearExcel]);

  const handleImportar = (): void => {
    const itemsValidos = preview.filter(p => p.estado === 'encontrado' && p.productoId);
    if (itemsValidos.length === 0) return;

    const items: CompraItemForm[] = itemsValidos.map(item => {
      const producto = productos.find(p => p.id === item.productoId);
      return {
        productoId: item.productoId!,
        productoNombre: item.productoNombre || producto?.nombre || '',
        productoCodigo: item.codigo,
        cantidad: item.cantidad,
        bonificacion: item.bonificacion,
        costoUnitario: item.costoUnitario || producto?.costo_sin_iva || 0,
        impuestosInternos: producto?.impuestos_internos || 0,
        porcentajeIva: 21,
        stockActual: producto?.stock || 0
      };
    });

    onImportar(items);
  };

  const descargarPlantilla = async (): Promise<void> => {
    try {
      const plantilla = [
        { Codigo: 'EJEMPLO001', Cantidad: 10, Costo: 500, 'Bonificacion%': 5.5 },
        { Codigo: 'EJEMPLO002', Cantidad: 5, Costo: 1200, 'Bonificacion%': 0 }
      ];
      const { createTemplate } = await loadExcelUtils();
      await createTemplate(plantilla, 'plantilla_compra', 'Compra');
    } catch (err) {
      const error = err as Error;
      setErroresParseo([`Error al descargar la plantilla: ${error.message || 'Error desconocido'}`]);
    }
  };

  const productosEncontrados = preview.filter(p => p.estado === 'encontrado');
  const productosNoEncontrados = preview.filter(p => p.estado === 'no_encontrado');

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-[60] p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-3xl max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 shrink-0">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
              <FileSpreadsheet className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
                Importar Items desde Excel
              </h2>
              <p className="text-sm text-gray-500">
                Agrega items de compra desde un archivo Excel
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Contenido */}
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Zona de carga */}
          {!archivo && (
            <div
              onDrop={handleDrop}
              onDragOver={(e) => e.preventDefault()}
              className="border-2 border-dashed border-gray-300 dark:border-gray-600 rounded-xl p-8 text-center hover:border-blue-500 transition-colors"
            >
              <Upload className="w-12 h-12 mx-auto text-gray-400 mb-4" />
              <p className="text-gray-600 dark:text-gray-400 mb-2">
                Arrastra un archivo Excel aqui o
              </p>
              <label className="inline-block">
                <input
                  type="file"
                  accept=".xlsx,.xls"
                  onChange={handleFileChange}
                  className="hidden"
                />
                <span className="px-4 py-2 bg-blue-600 text-white rounded-lg cursor-pointer hover:bg-blue-700 transition-colors">
                  Seleccionar archivo
                </span>
              </label>
              <p className="text-xs text-gray-500 mt-4">
                Formato esperado: Codigo | Cantidad | Costo | Bonificacion
              </p>
              <p className="text-xs text-gray-400 mt-1">
                Maximo {FILE_LIMITS.maxSizeMB}MB por archivo
              </p>
            </div>
          )}

          {/* Descargar plantilla */}
          <div className="flex justify-center">
            <button
              onClick={descargarPlantilla}
              className="flex items-center gap-2 text-sm text-blue-600 hover:text-blue-700"
            >
              <Download className="w-4 h-4" />
              Descargar plantilla de ejemplo
            </button>
          </div>

          {/* Archivo seleccionado */}
          {archivo && (
            <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3 flex items-center justify-between">
              <div className="flex items-center gap-2">
                <FileSpreadsheet className="w-5 h-5 text-green-600" />
                <span className="text-sm font-medium dark:text-white">{archivo.name}</span>
              </div>
              <button
                onClick={() => {
                  setArchivo(null);
                  setPreview([]);
                  setErroresParseo([]);
                }}
                className="text-sm text-red-600 hover:underline"
              >
                Cambiar archivo
              </button>
            </div>
          )}

          {/* Errores de parseo */}
          {erroresParseo.length > 0 && (
            <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3">
              <div className="flex items-start gap-2">
                <AlertCircle className="w-5 h-5 text-yellow-600 flex-shrink-0 mt-0.5" />
                <div>
                  <p className="text-sm font-medium text-yellow-700 dark:text-yellow-400">
                    Advertencias al procesar:
                  </p>
                  <ul className="text-xs text-yellow-600 dark:text-yellow-500 mt-1 list-disc list-inside">
                    {erroresParseo.slice(0, 5).map((err, i) => (
                      <li key={i}>{err}</li>
                    ))}
                    {erroresParseo.length > 5 && (
                      <li>...y {erroresParseo.length - 5} mas</li>
                    )}
                  </ul>
                </div>
              </div>
            </div>
          )}

          {/* Preview */}
          {preview.length > 0 && (
            <div className="space-y-4">
              {/* Resumen */}
              <div className="grid grid-cols-2 gap-4">
                <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4 text-center">
                  <p className="text-2xl font-bold text-green-600">{productosEncontrados.length}</p>
                  <p className="text-sm text-green-700 dark:text-green-400">Productos encontrados</p>
                </div>
                <div className="bg-red-50 dark:bg-red-900/20 rounded-lg p-4 text-center">
                  <p className="text-2xl font-bold text-red-600">{productosNoEncontrados.length}</p>
                  <p className="text-sm text-red-700 dark:text-red-400">No encontrados</p>
                </div>
              </div>

              {/* Tabla */}
              <div className="border dark:border-gray-700 rounded-lg overflow-hidden">
                <div className="max-h-64 overflow-y-auto">
                  <table className="w-full text-sm">
                    <thead className="bg-gray-50 dark:bg-gray-700/50 sticky top-0">
                      <tr>
                        <th className="px-3 py-2 text-left">Codigo</th>
                        <th className="px-3 py-2 text-left">Producto</th>
                        <th className="px-3 py-2 text-right">Cant.</th>
                        <th className="px-3 py-2 text-right">Costo</th>
                        <th className="px-3 py-2 text-right">Bonif.%</th>
                        <th className="px-3 py-2 text-center">Estado</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y dark:divide-gray-700">
                      {preview.map((item, i) => (
                        <tr key={i} className={item.estado === 'no_encontrado' ? 'bg-red-50 dark:bg-red-900/10' : ''}>
                          <td className="px-3 py-2 font-mono dark:text-gray-300">{item.codigo}</td>
                          <td className="px-3 py-2 dark:text-gray-300">
                            {item.productoNombre || <span className="text-red-500">No encontrado</span>}
                          </td>
                          <td className="px-3 py-2 text-right dark:text-gray-300">{item.cantidad}</td>
                          <td className="px-3 py-2 text-right font-medium text-blue-600">
                            ${item.costoUnitario.toLocaleString()}
                          </td>
                          <td className="px-3 py-2 text-right dark:text-gray-300">{item.bonificacion ? `${item.bonificacion}%` : '-'}</td>
                          <td className="px-3 py-2 text-center">
                            {item.estado === 'encontrado' ? (
                              <CheckCircle className="w-4 h-4 text-green-500 mx-auto" />
                            ) : (
                              <AlertCircle className="w-4 h-4 text-red-500 mx-auto" />
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>

              {/* No encontrados */}
              {productosNoEncontrados.length > 0 && (
                <div className="bg-red-50 dark:bg-red-900/20 rounded-lg p-3">
                  <p className="text-sm text-red-700 dark:text-red-400">
                    <AlertCircle className="w-4 h-4 inline mr-1" />
                    Los siguientes codigos no se encontraron y seran ignorados:
                  </p>
                  <div className="flex flex-wrap gap-2 mt-2">
                    {productosNoEncontrados.map((p, i) => (
                      <span key={i} className="px-2 py-1 bg-red-100 dark:bg-red-900/40 text-red-700 dark:text-red-300 rounded text-xs font-mono">
                        {p.codigo}
                      </span>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex gap-3 p-4 border-t dark:border-gray-700 shrink-0">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors dark:text-gray-300"
          >
            Cancelar
          </button>
          {productosEncontrados.length > 0 && (
            <button
              onClick={handleImportar}
              className="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
            >
              <Upload className="w-4 h-4" />
              Importar {productosEncontrados.length} items
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
