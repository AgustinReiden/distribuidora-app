/**
 * Utilidades para manejo de archivos Excel con ExcelJS
 *
 * Reemplaza xlsx por exceljs (sin vulnerabilidades conocidas)
 * Provee API simplificada para lectura y escritura de Excel
 */
import ExcelJS from 'exceljs'

export interface ExcelOptions {
  columnWidth?: number;
}

export interface ReportConfig {
  titulo?: string;
  datos: Record<string, unknown>[];
  columnas: { header: string; key: string; width?: number }[];
  filename: string;
}

export interface SheetConfig {
  name: string;
  data: Record<string, unknown>[];
  columnWidths?: number[];
}

/**
 * Lee un archivo Excel y retorna los datos como array de objetos
 */
export async function readExcelFile(file: File | ArrayBuffer): Promise<Record<string, unknown>[]> {
  const workbook = new ExcelJS.Workbook()

  // Si es un File, convertir a ArrayBuffer
  let arrayBuffer: ArrayBuffer
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

  const jsonData: Record<string, unknown>[] = []
  const headers: string[] = []

  worksheet.eachRow((row, rowNumber) => {
    if (rowNumber === 1) {
      // Primera fila son los headers
      row.eachCell((cell, colNumber) => {
        headers[colNumber] = cell.value?.toString() || `Column${colNumber}`
      })
    } else {
      // Filas de datos
      const rowData: Record<string, unknown> = {}
      row.eachCell((cell, colNumber) => {
        const header = headers[colNumber]
        if (header) {
          // Manejar diferentes tipos de valores de celda
          let value: unknown = cell.value
          if (value && typeof value === 'object') {
            // ExcelJS puede retornar objetos para fórmulas, fechas, etc.
            const cellValue = value as { result?: unknown; text?: string }
            if (cellValue.result !== undefined) {
              value = cellValue.result // Resultado de fórmula
            } else if (cellValue.text !== undefined) {
              value = cellValue.text // Rich text
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
 * Helper para descargar un buffer como archivo
 */
function downloadBuffer(buffer: ArrayBuffer, filename: string, mimeType: string): void {
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
 * Crea un archivo Excel a partir de datos y lo descarga
 */
export async function createAndDownloadExcel(
  data: Record<string, unknown>[],
  filename: string,
  sheetName = 'Datos',
  options: ExcelOptions = {}
): Promise<void> {
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
  downloadBuffer(buffer as ArrayBuffer, `${filename}.xlsx`, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
}

/**
 * Crea una plantilla Excel con estructura predefinida
 */
export async function createTemplate(
  templateData: Record<string, unknown>[],
  filename: string,
  sheetName = 'Plantilla'
): Promise<void> {
  await createAndDownloadExcel(templateData, filename, sheetName, { columnWidth: 20 })
}

/**
 * Exporta datos a Excel con formato de reporte
 */
export async function exportReport(config: ReportConfig): Promise<void> {
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
      dataRow.getCell(colIdx + 1).value = row[col.key] as ExcelJS.CellValue
    })
  })

  // Generar y descargar
  const buffer = await workbook.xlsx.writeBuffer()
  downloadBuffer(buffer as ArrayBuffer, `${filename}.xlsx`, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
}

/**
 * Crea un archivo Excel con múltiples hojas
 */
export async function createMultiSheetExcel(sheets: SheetConfig[], filename: string): Promise<void> {
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
  downloadBuffer(buffer as ArrayBuffer, `${filename}.xlsx`, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
}

export default {
  readExcelFile,
  createAndDownloadExcel,
  createTemplate,
  exportReport,
  createMultiSheetExcel
}
