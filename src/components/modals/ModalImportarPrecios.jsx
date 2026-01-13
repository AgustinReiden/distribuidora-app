import React, { useState, useCallback } from 'react';
import { X, Upload, FileSpreadsheet, AlertCircle, CheckCircle, Download, RefreshCw } from 'lucide-react';
import * as XLSX from 'xlsx';

export default function ModalImportarPrecios({ productos, onActualizarPrecios, onClose }) {
  const [archivo, setArchivo] = useState(null);
  const [preview, setPreview] = useState([]);
  const [resultado, setResultado] = useState(null);
  const [procesando, setProcesando] = useState(false);
  const [erroresParseo, setErroresParseo] = useState([]);

  // Mapeo de posibles nombres de columnas
  const COLUMNAS = {
    codigo: ['codigo', 'code', 'sku', 'cod', 'código'],
    precioNeto: ['precio neto', 'precio_neto', 'neto', 'costo', 'precio sin iva', 'precio_sin_iva'],
    impInternos: ['imp internos', 'impuestos internos', 'imp_internos', 'internos', 'impuestos'],
    precioFinal: ['precio final', 'precio', 'final', 'pvp', 'precio venta']
  };

  const encontrarValor = (fila, posiblesNombres) => {
    for (const nombre of posiblesNombres) {
      const key = Object.keys(fila).find(k => k.toLowerCase().trim().includes(nombre));
      if (key && fila[key] !== undefined && fila[key] !== '') return fila[key];
    }
    return null;
  };

  const parsearExcel = useCallback((file) => {
    const reader = new FileReader();
    reader.onload = (e) => {
      try {
        const data = new Uint8Array(e.target.result);
        const workbook = XLSX.read(data, { type: 'array' });
        const sheet = workbook.Sheets[workbook.SheetNames[0]];
        const jsonData = XLSX.utils.sheet_to_json(sheet);

        procesarDatos(jsonData);
      } catch (err) {
        setErroresParseo(['Error al leer el archivo: ' + err.message]);
      }
    };
    reader.readAsArrayBuffer(file);
  }, [productos]);

  const procesarDatos = (datos) => {
    const resultados = [];
    const erroresTemp = [];

    datos.forEach((fila, index) => {
      const codigo = encontrarValor(fila, COLUMNAS.codigo);
      if (!codigo) {
        erroresTemp.push(`Fila ${index + 2}: Código no encontrado`);
        return;
      }

      const productoExistente = productos.find(
        p => p.codigo?.toLowerCase().trim() === codigo.toString().toLowerCase().trim()
      );

      const precioNeto = parseFloat(encontrarValor(fila, COLUMNAS.precioNeto)) || 0;
      const impInternos = parseFloat(encontrarValor(fila, COLUMNAS.impInternos)) || 0;
      const precioFinal = parseFloat(encontrarValor(fila, COLUMNAS.precioFinal)) || 0;

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

  const handleFileChange = (e) => {
    const file = e.target.files[0];
    if (!file) return;
    setArchivo(file);
    setResultado(null);
    parsearExcel(file);
  };

  const handleDrop = useCallback((e) => {
    e.preventDefault();
    const file = e.dataTransfer.files[0];
    if (file && (file.name.endsWith('.xlsx') || file.name.endsWith('.xls'))) {
      setArchivo(file);
      setResultado(null);
      parsearExcel(file);
    }
  }, [parsearExcel]);

  const handleImportar = async () => {
    const productosAActualizar = preview.filter(p => p.estado === 'encontrado');
    if (productosAActualizar.length === 0) return;

    setProcesando(true);
    try {
      const res = await onActualizarPrecios(productosAActualizar);
      setResultado(res);
    } catch (err) {
      setResultado({ success: false, error: err.message });
    } finally {
      setProcesando(false);
    }
  };

  const descargarPlantilla = () => {
    const plantilla = [
      { Codigo: 'EJEMPLO001', 'Precio Neto': 1000, 'Imp Internos': 50, 'Precio Final': 1200 },
      { Codigo: 'EJEMPLO002', 'Precio Neto': 500, 'Imp Internos': 0, 'Precio Final': 600 }
    ];
    const ws = XLSX.utils.json_to_sheet(plantilla);
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Precios');
    XLSX.writeFile(wb, 'plantilla_precios.xlsx');
  };

  const productosEncontrados = preview.filter(p => p.estado === 'encontrado');
  const productosNoEncontrados = preview.filter(p => p.estado === 'no_encontrado');

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
                  {resultado.errores?.length > 0 && (
                    <div className="mt-3 text-sm text-yellow-600">
                      <p>Advertencias:</p>
                      <ul className="list-disc list-inside">
                        {resultado.errores.map((e, i) => <li key={i}>{e}</li>)}
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
