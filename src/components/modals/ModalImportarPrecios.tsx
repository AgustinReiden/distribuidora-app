import { useState, useCallback } from 'react';
import type { ChangeEvent, DragEvent } from 'react';
import { X, Upload, FileSpreadsheet, AlertCircle, CheckCircle, Download, RefreshCw } from 'lucide-react';
const loadExcelUtils = () => import('../../utils/excel');
import { validateExcelFile, validateAndSanitizeExcelData, FILE_LIMITS } from '../../utils/fileValidation';
import { logger } from '../../utils/logger';
import type { ProductoDB } from '../../types';

// =============================================================================
// TIPOS
// =============================================================================

/** Item de preview de precio */
export interface PrecioPreviewItem {
  fila: number;
  codigo: string;
  precioNeto: number;
  impInternos: number;
  precioFinal: number;
  productoId: string | null;
  productoNombre: string | null;
  precioActual: number | null;
  estado: 'encontrado' | 'no_encontrado';
}

/** Resultado de actualizacion de precios */
export interface ActualizarPreciosResult {
  success: boolean;
  actualizados?: number;
  errores?: string[];
  error?: string;
}

/** Props del componente principal */
export interface ModalImportarPreciosProps {
  productos: ProductoDB[];
  onActualizarPrecios: (productos: PrecioPreviewItem[]) => Promise<ActualizarPreciosResult>;
  onClose: () => void;
}

/** Fila de datos de Excel */
interface ExcelRow {
  [key: string]: string | number | null | undefined;
}

/** Mapa de columnas posibles */
interface ColumnasMap {
  codigo: string[];
  precioNeto: string[];
  impInternos: string[];
  precioFinal: string[];
}

/**
 * Normaliza un valor numerico desde diferentes formatos regionales
 * Maneja formatos como:
 * - "1.500,50" (europeo/argentino) -> 1500.50
 * - "1,500.50" (americano) -> 1500.50
 * - "1500.50" (sin separador de miles) -> 1500.50
 * - "1500,50" (europeo simple) -> 1500.50
 */
const normalizarNumero = (valor: string | number | null | undefined): number => {
  if (valor === null || valor === undefined || valor === '') return 0;

  // Si ya es numero, devolverlo directamente
  if (typeof valor === 'number') return isNaN(valor) ? 0 : valor;

  // Convertir a string y limpiar espacios
  let str = String(valor).trim();

  // Remover simbolos de moneda comunes
  str = str.replace(/[$€£¥]/g, '').trim();

  // Detectar formato regional basado en posicion de punto y coma
  const ultimoPunto = str.lastIndexOf('.');
  const ultimaComa = str.lastIndexOf(',');

  if (ultimaComa > ultimoPunto) {
    // Formato europeo: "1.500,50" -> coma es decimal
    str = str.replace(/\./g, '').replace(',', '.');
  } else if (ultimoPunto > ultimaComa && ultimaComa !== -1) {
    // Formato americano: "1,500.50" -> punto es decimal
    str = str.replace(/,/g, '');
  } else if (ultimaComa !== -1 && ultimoPunto === -1) {
    // Solo coma, sin punto: "1500,50" -> coma es decimal
    str = str.replace(',', '.');
  }
  // Si solo tiene punto, ya esta en formato correcto

  const resultado = parseFloat(str);
  return isNaN(resultado) ? 0 : resultado;
};

export default function ModalImportarPrecios({ productos, onActualizarPrecios, onClose }: ModalImportarPreciosProps) {
  const [archivo, setArchivo] = useState<File | null>(null);
  const [preview, setPreview] = useState<PrecioPreviewItem[]>([]);
  const [resultado, setResultado] = useState<ActualizarPreciosResult | null>(null);
  const [procesando, setProcesando] = useState<boolean>(false);
  const [erroresParseo, setErroresParseo] = useState<string[]>([]);

  // Mapeo de posibles nombres de columnas
  const COLUMNAS: ColumnasMap = {
    codigo: ['codigo', 'code', 'sku', 'cod', 'codigo'],
    precioNeto: ['precio neto', 'precio_neto', 'neto', 'costo', 'precio sin iva', 'precio_sin_iva'],
    impInternos: ['imp internos', 'impuestos internos', 'imp_internos', 'internos', 'impuestos'],
    precioFinal: ['precio final', 'precio', 'final', 'pvp', 'precio venta']
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

      // Validar y sanitizar datos
      const validation = validateAndSanitizeExcelData(jsonData);
      if (!validation.valid) {
        setErroresParseo([validation.error || 'Error de validacion']);
        return;
      }

      // Mostrar advertencias si las hay
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
    const resultados: PrecioPreviewItem[] = [];
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

      const precioNeto = normalizarNumero(encontrarValor(fila, COLUMNAS.precioNeto));
      const impInternos = normalizarNumero(encontrarValor(fila, COLUMNAS.impInternos));
      const precioFinal = normalizarNumero(encontrarValor(fila, COLUMNAS.precioFinal));

      resultados.push({
        fila: index + 2,
        codigo: codigo.toString(),
        precioNeto,
        impInternos,
        precioFinal,
        productoId: productoExistente?.id || null,
        productoNombre: productoExistente?.nombre || null,
        precioActual: productoExistente?.precio || null,
        estado: productoExistente ? 'encontrado' : 'no_encontrado'
      });
    });

    setPreview(resultados);
    setErroresParseo(erroresTemp);
  };

  const handleFileChange = (e: ChangeEvent<HTMLInputElement>): void => {
    const file = e.target.files?.[0];
    if (!file) return;

    // Validar archivo antes de procesar
    const validation = validateExcelFile(file);
    if (!validation.valid) {
      setErroresParseo([validation.error || 'Error de validacion']);
      return;
    }

    setArchivo(file);
    setResultado(null);
    setErroresParseo([]);
    parsearExcel(file);
  };

  const handleDrop = useCallback((e: DragEvent<HTMLDivElement>): void => {
    e.preventDefault();
    const file = e.dataTransfer.files[0];
    if (!file) return;

    // Validar archivo antes de procesar
    const validation = validateExcelFile(file);
    if (!validation.valid) {
      setErroresParseo([validation.error || 'Error de validacion']);
      return;
    }

    setArchivo(file);
    setResultado(null);
    setErroresParseo([]);
    parsearExcel(file);
  }, [parsearExcel]);

  const handleImportar = async (): Promise<void> => {
    const productosAActualizar = preview.filter(p => p.estado === 'encontrado' && p.productoId != null);
    if (productosAActualizar.length === 0) {
      setResultado({ success: false, error: 'No hay productos validos para actualizar' });
      return;
    }

    setProcesando(true);
    try {
      const res = await onActualizarPrecios(productosAActualizar);
      setResultado(res);
    } catch (err) {
      // Capturar mejor el error
      const error = err as Error;
      const errorMsg = error?.message || error?.toString?.() || 'Error desconocido al actualizar precios';
      logger.error('Error en importacion de precios:', err);
      setResultado({ success: false, error: errorMsg });
    } finally {
      setProcesando(false);
    }
  };

  const descargarPlantilla = async (): Promise<void> => {
    try {
      const plantilla = [
        { Codigo: 'EJEMPLO001', 'Precio Neto': 1000, 'Imp Internos': 50, 'Precio Final': 1200 },
        { Codigo: 'EJEMPLO002', 'Precio Neto': 500, 'Imp Internos': 0, 'Precio Final': 600 }
      ];
      const { createTemplate } = await loadExcelUtils();
      await createTemplate(plantilla, 'plantilla_precios', 'Precios');
    } catch (err) {
      const error = err as Error;
      logger.error('Error al descargar plantilla:', err);
      setErroresParseo([`Error al descargar la plantilla: ${error.message || 'Error desconocido'}`]);
    }
  };

  const productosEncontrados: PrecioPreviewItem[] = preview.filter(p => p.estado === 'encontrado');
  const productosNoEncontrados: PrecioPreviewItem[] = preview.filter(p => p.estado === 'no_encontrado');

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-4xl max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 shrink-0">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
              <FileSpreadsheet className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
                Importar Precios desde Excel
              </h2>
              <p className="text-sm text-gray-500">
                Actualiza precios masivamente desde un archivo Excel
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
          {/* Zona de carga de archivo */}
          {!archivo && (
            <div
              onDrop={handleDrop}
              onDragOver={(e) => e.preventDefault()}
              className="border-2 border-dashed border-gray-300 dark:border-gray-600 rounded-xl p-8 text-center hover:border-blue-500 transition-colors"
            >
              <Upload className="w-12 h-12 mx-auto text-gray-400 mb-4" />
              <p className="text-gray-600 dark:text-gray-400 mb-2">
                Arrastra un archivo Excel aquí o
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
                Formato esperado: Codigo | Precio Neto | Imp Internos | Precio Final
              </p>
              <p className="text-xs text-gray-400 mt-1">
                Máximo {FILE_LIMITS.maxSizeMB}MB por archivo
              </p>
            </div>
          )}

          {/* Botón descargar plantilla */}
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
          {archivo && !resultado && (
            <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3 flex items-center justify-between">
              <div className="flex items-center gap-2">
                <FileSpreadsheet className="w-5 h-5 text-green-600" />
                <span className="text-sm font-medium">{archivo.name}</span>
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
                      <li>...y {erroresParseo.length - 5} más</li>
                    )}
                  </ul>
                </div>
              </div>
            </div>
          )}

          {/* Preview de productos */}
          {preview.length > 0 && !resultado && (
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

              {/* Tabla de preview */}
              <div className="border dark:border-gray-700 rounded-lg overflow-hidden">
                <div className="max-h-64 overflow-y-auto">
                  <table className="w-full text-sm">
                    <thead className="bg-gray-50 dark:bg-gray-700/50 sticky top-0">
                      <tr>
                        <th className="px-3 py-2 text-left">Código</th>
                        <th className="px-3 py-2 text-left">Producto</th>
                        <th className="px-3 py-2 text-right">Precio Actual</th>
                        <th className="px-3 py-2 text-right">Precio Nuevo</th>
                        <th className="px-3 py-2 text-center">Estado</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y dark:divide-gray-700">
                      {preview.map((item, i) => (
                        <tr key={i} className={item.estado === 'no_encontrado' ? 'bg-red-50 dark:bg-red-900/10' : ''}>
                          <td className="px-3 py-2 font-mono">{item.codigo}</td>
                          <td className="px-3 py-2">
                            {item.productoNombre || <span className="text-red-500">No encontrado</span>}
                          </td>
                          <td className="px-3 py-2 text-right">
                            {item.precioActual ? `$${item.precioActual.toLocaleString()}` : '-'}
                          </td>
                          <td className="px-3 py-2 text-right font-medium text-blue-600">
                            ${item.precioFinal.toLocaleString()}
                          </td>
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

              {/* Productos no encontrados */}
              {productosNoEncontrados.length > 0 && (
                <div className="bg-red-50 dark:bg-red-900/20 rounded-lg p-3">
                  <p className="text-sm text-red-700 dark:text-red-400">
                    <AlertCircle className="w-4 h-4 inline mr-1" />
                    Los siguientes códigos no se encontraron en el sistema y serán ignorados:
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

          {/* Resultado de la importación */}
          {resultado && (
            <div className={`rounded-lg p-6 text-center ${resultado.success !== false ? 'bg-green-50 dark:bg-green-900/20' : 'bg-red-50 dark:bg-red-900/20'}`}>
              {resultado.success !== false ? (
                <>
                  <CheckCircle className="w-12 h-12 text-green-500 mx-auto mb-3" />
                  <h3 className="text-lg font-semibold text-green-700 dark:text-green-400">
                    Importación completada
                  </h3>
                  <p className="text-green-600 dark:text-green-500 mt-1">
                    Se actualizaron {resultado.actualizados} productos
                  </p>
                  {(resultado.errores?.length ?? 0) > 0 && (
                    <div className="mt-3 text-sm text-yellow-600">
                      <p>Advertencias:</p>
                      <ul className="list-disc list-inside">
                        {resultado.errores?.map((e, i) => <li key={i}>{e}</li>)}
                      </ul>
                    </div>
                  )}
                </>
              ) : (
                <>
                  <AlertCircle className="w-12 h-12 text-red-500 mx-auto mb-3" />
                  <h3 className="text-lg font-semibold text-red-700 dark:text-red-400">
                    Error en la importación
                  </h3>
                  <p className="text-red-600 dark:text-red-500 mt-1">
                    {resultado.error || 'Error desconocido'}
                  </p>
                </>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex gap-3 p-4 border-t dark:border-gray-700 shrink-0">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
          >
            {resultado ? 'Cerrar' : 'Cancelar'}
          </button>
          {!resultado && productosEncontrados.length > 0 && (
            <button
              onClick={handleImportar}
              disabled={procesando}
              className="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
            >
              {procesando ? (
                <>
                  <RefreshCw className="w-4 h-4 animate-spin" />
                  Actualizando...
                </>
              ) : (
                <>
                  <Upload className="w-4 h-4" />
                  Actualizar {productosEncontrados.length} productos
                </>
              )}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
