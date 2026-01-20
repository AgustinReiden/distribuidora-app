/**
 * Utilidades para manejo de archivos Excel con ExcelJS
 *
 * Reemplaza xlsx por exceljs (sin vulnerabilidades conocidas)
 * Provee API simplificada para lectura y escritura de Excel
 */
import ExcelJS from 'exceljs'

/**
 * Lee un archivo Excel y retorna los datos como array de objetos
 * @param {File|ArrayBuffer} file - Archivo Excel a leer
 * @returns {Promise<Array<Object>>} - Array de objetos con los datos
 */
export async function readExcelFile(file) {
  const workbook = new ExcelJS.Workbook()

  // Si es un File, convertir a ArrayBuffer
  let arrayBuffer
  if (file instanceof File) {
    arrayBuffer = await file.arrayBuffer()
  } else {
    arrayBuffer = file
  }

  await workbook.xlsx.load(arrayBuffer)

  const worksheet = workbook.worksheets[0]
  if (!worksheet) {
    throw new Error('El archivo no contiene hojas de cálculo')
  }

  const jsonData = []
  const headers = []

  worksheet.eachRow((row, rowNumber) => {
    if (rowNumber === 1) {
      // Primera fila son los headers
      row.eachCell((cell, colNumber) => {
        headers[colNumber] = cell.value?.toString() || `Column${colNumber}`
      })
    } else {
      // Filas de datos
      const rowData = {}
      row.eachCell((cell, colNumber) => {
        const header = headers[colNumber]
        if (header) {
          // Manejar diferentes tipos de valores de celda
          let value = cell.value
          if (value && typeof value === 'object') {
            // ExcelJS puede retornar objetos para fórmulas, fechas, etc.
            if (value.result !== undefined) {
              value = value.result // Resultado de fórmula
            } else if (value.text !== undefined) {
              value = value.text // Rich text
            } else if (value instanceof Date) {
              value = value.toISOString()
            }
          }
          rowData[header] = value
        }
      })
      // Solo agregar filas que tengan al menos un valor
      if (Object.keys(rowData).length > 0) {
        jsonData.push(rowData)
      }
    }
  })

  return jsonData
}

/**
 * Crea un archivo Excel a partir de datos y lo descarga
 * @param {Array<Object>} data - Array de objetos con los datos
 * @param {string} filename - Nombre del archivo (sin extensión)
 * @param {string} sheetName - Nombre de la hoja (default: 'Datos')
 * @param {Object} options - Opciones adicionales
 */
export async function createAndDownloadExcel(data, filename, sheetName = 'Datos', options = {}) {
  const workbook = new ExcelJS.Workbook()
  workbook.creator = 'Distribuidora App'
  workbook.created = new Date()

  const worksheet = workbook.addWorksheet(sheetName)

  if (data.length === 0) {
    throw new Error('No hay datos para exportar')
  }

  // Obtener headers de las keys del primer objeto
  const headers = Object.keys(data[0])

  // Configurar columnas
  worksheet.columns = headers.map(header => ({
    header: header,
    key: header,
    width: options.columnWidth || 15
  }))

  // Agregar datos
  data.forEach(row => {
    worksheet.addRow(row)
  })

  // Estilizar header
  const headerRow = worksheet.getRow(1)
  headerRow.font = { bold: true }
  headerRow.fill = {
    type: 'pattern',
    pattern: 'solid',
    fgColor: { argb: 'FFE0E0E0' }
  }

  // Generar buffer y descargar
  const buffer = await workbook.xlsx.writeBuffer()
  downloadBuffer(buffer, `${filename}.xlsx`, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
}

/**
 * Crea una plantilla Excel con estructura predefinida
 * @param {Array<Object>} templateData - Datos de ejemplo para la plantilla
 * @param {string} filename - Nombre del archivo
 * @param {string} sheetName - Nombre de la hoja
 */
export async function createTemplate(templateData, filename, sheetName = 'Plantilla') {
  await createAndDownloadExcel(templateData, filename, sheetName, { columnWidth: 20 })
}

/**
 * Helper para descargar un buffer como archivo
 * @param {ArrayBuffer} buffer - Buffer del archivo
 * @param {string} filename - Nombre del archivo
 * @param {string} mimeType - Tipo MIME
 */
function downloadBuffer(buffer, filename, mimeType) {
  const blob = new Blob([buffer], { type: mimeType })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}

/**
 * Exporta datos a Excel con formato de reporte
 * @param {Object} config - Configuración del reporte
 * @param {string} config.titulo - Título del reporte
 * @param {Array<Object>} config.datos - Datos a exportar
 * @param {Array<{header: string, key: string, width?: number}>} config.columnas - Definición de columnas
 * @param {string} config.filename - Nombre del archivo
 */
export async function exportReport(config) {
  const { titulo, datos, columnas, filename } = config

  const workbook = new ExcelJS.Workbook()
  workbook.creator = 'Distribuidora App'
  workbook.created = new Date()

  const worksheet = workbook.addWorksheet(titulo || 'Reporte')

  // Título del reporte
  if (titulo) {
    worksheet.mergeCells(1, 1, 1, columnas.length)
    const titleCell = worksheet.getCell(1, 1)
    titleCell.value = titulo
    titleCell.font = { size: 14, bold: true }
    titleCell.alignment = { horizontal: 'center' }
  }

  // Fecha de generación
  const startRow = titulo ? 2 : 1
  worksheet.mergeCells(startRow, 1, startRow, columnas.length)
  const dateCell = worksheet.getCell(startRow, 1)
  dateCell.value = `Generado: ${new Date().toLocaleString('es-AR')}`
  dateCell.font = { size: 10, italic: true }
  dateCell.alignment = { horizontal: 'right' }

  // Configurar columnas
  const dataStartRow = startRow + 2
  worksheet.columns = columnas.map(col => ({
    header: col.header,
    key: col.key,
    width: col.width || 15
  }))

  // Headers en la fila correcta
  const headerRow = worksheet.getRow(dataStartRow)
  columnas.forEach((col, idx) => {
    headerRow.getCell(idx + 1).value = col.header
  })
  headerRow.font = { bold: true }
  headerRow.fill = {
    type: 'pattern',
    pattern: 'solid',
    fgColor: { argb: 'FF4472C4' }
  }
  headerRow.font = { bold: true, color: { argb: 'FFFFFFFF' } }

  // Agregar datos
  datos.forEach((row, idx) => {
    const dataRow = worksheet.getRow(dataStartRow + 1 + idx)
    columnas.forEach((col, colIdx) => {
      dataRow.getCell(colIdx + 1).value = row[col.key]
    })
  })

  // Generar y descargar
  const buffer = await workbook.xlsx.writeBuffer()
  downloadBuffer(buffer, `${filename}.xlsx`, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
}

/**
 * Crea un archivo Excel con múltiples hojas
 * @param {Array<{name: string, data: Array<Object>, columnWidths?: number[]}>} sheets - Array de hojas
 * @param {string} filename - Nombre del archivo (sin extensión)
 */
export async function createMultiSheetExcel(sheets, filename) {
  const workbook = new ExcelJS.Workbook()
  workbook.creator = 'Distribuidora App'
  workbook.created = new Date()

  for (const sheet of sheets) {
    const { name, data, columnWidths } = sheet

    if (!data || data.length === 0) {
      // Crear hoja vacía
      workbook.addWorksheet(name)
      continue
    }

    const worksheet = workbook.addWorksheet(name)
    const headers = Object.keys(data[0])

    // Configurar columnas con anchos personalizados
    worksheet.columns = headers.map((header, idx) => ({
      header: header,
      key: header,
      width: columnWidths?.[idx] || 15
    }))

    // Agregar datos
    data.forEach(row => {
      worksheet.addRow(row)
    })

    // Estilizar header
    const headerRow = worksheet.getRow(1)
    headerRow.font = { bold: true }
    headerRow.fill = {
      type: 'pattern',
      pattern: 'solid',
      fgColor: { argb: 'FFE0E0E0' }
    }
  }

  // Generar buffer y descargar
  const buffer = await workbook.xlsx.writeBuffer()
  downloadBuffer(buffer, `${filename}.xlsx`, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
}

export default {
  readExcelFile,
  createAndDownloadExcel,
  createTemplate,
  exportReport,
  createMultiSheetExcel
}
