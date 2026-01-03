import { jsPDF } from 'jspdf';

const formatPrecio = (p) => new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0);
const formatFecha = (fecha) => new Date(fecha || new Date()).toLocaleDateString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric' });

/**
 * Genera PDF de Orden de Preparación para el depósito
 * Formato: Ticket comandera de 75mm de ancho
 * @param {Array} pedidos - Lista de pedidos a incluir
 * @returns {void} - Descarga el PDF
 */
export function generarOrdenPreparacion(pedidos) {
  // Ticket comandera: 75mm de ancho, altura dinámica
  const ticketWidth = 75; // mm
  const margin = 3; // mm
  const contentWidth = ticketWidth - (margin * 2);

  // Calcular altura necesaria
  let totalHeight = 25; // Encabezado inicial
  pedidos.forEach(pedido => {
    totalHeight += 18; // Cabecera del pedido
    totalHeight += (pedido.items?.length || 0) * 5; // Productos
    if (pedido.notas) totalHeight += 8;
    totalHeight += 5; // Separador
  });
  totalHeight += 10; // Margen inferior

  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: [ticketWidth, Math.max(totalHeight, 50)]
  });

  let y = margin;

  // Título principal
  doc.setFontSize(12);
  doc.setFont('helvetica', 'bold');
  doc.text('ORDEN DE PREPARACION', ticketWidth / 2, y + 4, { align: 'center' });
  y += 7;

  doc.setFontSize(8);
  doc.setFont('helvetica', 'normal');
  doc.text(formatFecha(new Date()), ticketWidth / 2, y, { align: 'center' });
  y += 4;

  doc.setFontSize(7);
  doc.text(`Total: ${pedidos.length} pedido(s)`, ticketWidth / 2, y, { align: 'center' });
  y += 5;

  // Línea divisora
  doc.setLineWidth(0.3);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 4;

  // Iterar sobre cada pedido
  pedidos.forEach((pedido, index) => {
    // Cabecera del pedido
    doc.setFontSize(9);
    doc.setFont('helvetica', 'bold');
    doc.text(`#${pedido.id}`, margin, y);

    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente';
    const nombreTruncado = clienteNombre.length > 20 ? clienteNombre.substring(0, 18) + '..' : clienteNombre;
    doc.text(nombreTruncado, margin + 10, y);
    y += 4;

    // Dirección
    doc.setFontSize(7);
    doc.setFont('helvetica', 'normal');
    const direccion = pedido.cliente?.direccion || 'Sin direccion';
    const dirTruncada = direccion.length > 35 ? direccion.substring(0, 33) + '..' : direccion;
    doc.text(dirTruncada, margin, y);
    y += 3;

    // Teléfono
    if (pedido.cliente?.telefono) {
      doc.text(`Tel: ${pedido.cliente.telefono}`, margin, y);
      y += 3;
    }

    // Notas
    if (pedido.notas) {
      doc.setFontSize(6);
      doc.setFont('helvetica', 'italic');
      const notasTruncadas = pedido.notas.length > 40 ? pedido.notas.substring(0, 38) + '..' : pedido.notas;
      doc.text(`* ${notasTruncadas}`, margin, y);
      y += 3;
    }

    y += 2;

    // Lista de productos
    doc.setFontSize(8);
    doc.setFont('helvetica', 'normal');
    pedido.items?.forEach((item) => {
      const cantidad = item.cantidad;
      const producto = item.producto?.nombre || 'Producto';
      const prodTruncado = producto.length > 25 ? producto.substring(0, 23) + '..' : producto;

      // Checkbox pequeño
      doc.rect(margin, y - 2.5, 2.5, 2.5);
      doc.text(`${cantidad}x ${prodTruncado}`, margin + 4, y);
      y += 4;
    });

    y += 2;

    // Línea divisora entre pedidos
    doc.setLineWidth(0.2);
    doc.setDrawColor(150);
    doc.line(margin, y, ticketWidth - margin, y);
    doc.setDrawColor(0);
    y += 3;
  });

  // Descargar PDF
  const fecha = formatFecha(new Date()).replace(/\//g, '-');
  doc.save(`orden-preparacion-${fecha}.pdf`);
}

/**
 * Genera PDF de Hoja de Ruta para el transportista
 * Formato: Ticket comandera de 75mm de ancho
 * @param {Object} transportista - Datos del transportista
 * @param {Array} pedidos - Lista de pedidos asignados
 * @returns {void} - Descarga el PDF
 */
export function generarHojaRuta(transportista, pedidos) {
  // Ticket comandera: 75mm de ancho
  const ticketWidth = 75; // mm
  const margin = 3; // mm

  // Calcular altura necesaria
  let totalHeight = 35; // Encabezado y resumen
  pedidos.forEach(pedido => {
    totalHeight += 30; // Info básica del pedido
    const itemsCount = pedido.items?.length || 0;
    totalHeight += Math.ceil(itemsCount * 4); // Productos resumidos
    if (pedido.notas) totalHeight += 6;
  });
  totalHeight += 25; // Pie de página

  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: [ticketWidth, Math.max(totalHeight, 80)]
  });

  let y = margin;

  // Calcular totales
  const totalPedidos = pedidos.length;
  const totalACobrar = pedidos.reduce((sum, p) => sum + (p.total || 0), 0);
  const totalPendienteCobro = pedidos
    .filter(p => p.estado_pago !== 'pagado')
    .reduce((sum, p) => sum + (p.total || 0), 0);

  // Título principal
  doc.setFontSize(12);
  doc.setFont('helvetica', 'bold');
  doc.text('HOJA DE RUTA', ticketWidth / 2, y + 4, { align: 'center' });
  y += 7;

  // Nombre del transportista
  doc.setFontSize(9);
  doc.text(transportista?.nombre || 'Transportista', ticketWidth / 2, y, { align: 'center' });
  y += 4;

  doc.setFontSize(7);
  doc.setFont('helvetica', 'normal');
  doc.text(formatFecha(new Date()), ticketWidth / 2, y, { align: 'center' });
  y += 5;

  // Resumen
  doc.setLineWidth(0.3);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 3;

  doc.setFontSize(7);
  doc.text(`Entregas: ${totalPedidos}`, margin, y);
  doc.text(`Total: ${formatPrecio(totalACobrar)}`, ticketWidth - margin, y, { align: 'right' });
  y += 3;
  doc.text(`Pend. cobro: ${formatPrecio(totalPendienteCobro)}`, margin, y);
  y += 4;

  doc.line(margin, y, ticketWidth - margin, y);
  y += 4;

  // Iterar sobre cada pedido/entrega
  pedidos.forEach((pedido, index) => {
    // Número de entrega
    doc.setFontSize(10);
    doc.setFont('helvetica', 'bold');
    doc.text(`${index + 1}.`, margin, y);

    // Nombre del cliente
    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente';
    const nombreTruncado = clienteNombre.length > 18 ? clienteNombre.substring(0, 16) + '..' : clienteNombre;
    doc.text(nombreTruncado, margin + 6, y);

    // Total con color según estado de pago
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(8);
    const estadoPagoSymbol = pedido.estado_pago === 'pagado' ? '[P]' :
                             pedido.estado_pago === 'parcial' ? '[*]' : '[$]';
    doc.text(`${estadoPagoSymbol} ${formatPrecio(pedido.total)}`, ticketWidth - margin, y, { align: 'right' });
    y += 4;

    // Dirección
    doc.setFontSize(7);
    const direccion = pedido.cliente?.direccion || 'Sin direccion';
    const dirTruncada = direccion.length > 40 ? direccion.substring(0, 38) + '..' : direccion;
    doc.text(dirTruncada, margin, y);
    y += 3;

    // Teléfono
    if (pedido.cliente?.telefono) {
      doc.text(`Tel: ${pedido.cliente.telefono}`, margin, y);
      y += 3;
    }

    // Forma de pago
    const formaPagoTexto = {
      efectivo: 'Efvo',
      transferencia: 'Transf',
      cheque: 'Cheque',
      cuenta_corriente: 'Cta.Cte',
      tarjeta: 'Tarjeta'
    }[pedido.forma_pago] || pedido.forma_pago || 'Efvo';

    const estadoPagoTexto = pedido.estado_pago === 'pagado' ? 'PAGADO' :
                           pedido.estado_pago === 'parcial' ? 'PARCIAL' : 'PEND';
    doc.text(`${formaPagoTexto} | ${estadoPagoTexto}`, margin, y);
    y += 3;

    // Productos (formato compacto)
    doc.setFontSize(6);
    const productosTexto = pedido.items?.map(i => `${i.cantidad}x${i.producto?.nombre?.substring(0,12) || '?'}`).join(', ') || '';
    const prodLines = doc.splitTextToSize(productosTexto, ticketWidth - (margin * 2));
    prodLines.slice(0, 2).forEach(line => {
      doc.text(line, margin, y);
      y += 3;
    });

    // Notas
    if (pedido.notas) {
      doc.setFont('helvetica', 'italic');
      const notasTruncadas = pedido.notas.length > 35 ? pedido.notas.substring(0, 33) + '..' : pedido.notas;
      doc.text(`* ${notasTruncadas}`, margin, y);
      y += 3;
      doc.setFont('helvetica', 'normal');
    }

    // Área de confirmación compacta
    y += 1;
    doc.setFontSize(7);
    doc.rect(margin, y - 2, 2.5, 2.5); // Checkbox
    doc.text('Entregado', margin + 4, y);
    doc.text('Firma:______________', ticketWidth / 2, y);
    y += 4;

    // Línea divisora
    doc.setLineWidth(0.2);
    doc.setDrawColor(150);
    doc.line(margin, y, ticketWidth - margin, y);
    doc.setDrawColor(0);
    y += 3;
  });

  // Pie de página con resumen
  y += 2;
  doc.setLineWidth(0.5);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 4;

  doc.setFontSize(8);
  doc.setFont('helvetica', 'bold');
  doc.text('RESUMEN COBRANZA', ticketWidth / 2, y, { align: 'center' });
  y += 4;

  doc.setFont('helvetica', 'normal');
  doc.setFontSize(7);
  doc.text('Cobrado: ____________', margin, y);
  y += 4;
  doc.text('Efectivo: ____________', margin, y);
  y += 4;
  doc.text('Transf: ____________', margin, y);
  y += 4;
  doc.text('Firma: ______________', margin, y);

  // Descargar PDF
  const fecha = formatFecha(new Date()).replace(/\//g, '-');
  const nombreTransportista = (transportista?.nombre || 'transportista').replace(/\s+/g, '-').toLowerCase();
  doc.save(`hoja-ruta-${nombreTransportista}-${fecha}.pdf`);
}

/**
 * Genera PDF profesional de Hoja de Ruta Optimizada
 * Formato: A4 horizontal para mejor visualizacion
 * @param {Object} transportista - Datos del transportista
 * @param {Array} pedidos - Lista de pedidos ordenados por ruta optimizada
 * @param {Object} infoRuta - Informacion de la ruta (duracion, distancia)
 * @returns {void} - Descarga el PDF
 */
export function generarHojaRutaOptimizada(transportista, pedidos, infoRuta = {}) {
  // A4 vertical
  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: 'a4'
  });

  const pageWidth = 210;
  const pageHeight = 297;
  const margin = 15;
  const contentWidth = pageWidth - (margin * 2);

  let y = margin;

  // === HEADER ===
  doc.setFillColor(37, 99, 235); // Azul
  doc.rect(0, 0, pageWidth, 45, 'F');

  doc.setTextColor(255, 255, 255);
  doc.setFontSize(20);
  doc.setFont('helvetica', 'bold');
  doc.text('HOJA DE RUTA', margin, 18);

  doc.setFontSize(12);
  doc.setFont('helvetica', 'normal');
  doc.text(formatFecha(new Date()), pageWidth - margin, 18, { align: 'right' });

  // Info transportista
  doc.setFontSize(14);
  doc.setFont('helvetica', 'bold');
  doc.text(`Transportista: ${transportista?.nombre || 'Sin asignar'}`, margin, 32);

  // Metricas de ruta
  doc.setFontSize(10);
  doc.setFont('helvetica', 'normal');
  const metricas = [];
  if (infoRuta.duracion_formato) metricas.push(`Duracion: ${infoRuta.duracion_formato}`);
  if (infoRuta.distancia_formato) metricas.push(`Distancia: ${infoRuta.distancia_formato}`);
  metricas.push(`Entregas: ${pedidos.length}`);
  doc.text(metricas.join('  |  '), margin, 40);

  y = 55;

  // === RESUMEN DE COBRO ===
  doc.setTextColor(0, 0, 0);
  const totalGeneral = pedidos.reduce((sum, p) => sum + (p.total || 0), 0);
  const totalPendiente = pedidos.filter(p => p.estado_pago !== 'pagado').reduce((sum, p) => sum + (p.total || 0), 0);
  const totalCobrado = totalGeneral - totalPendiente;

  doc.setFillColor(249, 250, 251);
  doc.rect(margin, y, contentWidth, 20, 'F');
  doc.setDrawColor(229, 231, 235);
  doc.rect(margin, y, contentWidth, 20, 'S');

  doc.setFontSize(9);
  doc.setFont('helvetica', 'bold');
  doc.text('RESUMEN', margin + 5, y + 7);

  doc.setFont('helvetica', 'normal');
  doc.text(`Total a cobrar: ${formatPrecio(totalGeneral)}`, margin + 5, y + 15);
  doc.text(`Pendiente: ${formatPrecio(totalPendiente)}`, margin + 65, y + 15);
  doc.text(`Ya pagado: ${formatPrecio(totalCobrado)}`, margin + 120, y + 15);

  y += 28;

  // === TABLA DE ENTREGAS ===
  // Header de tabla
  doc.setFillColor(243, 244, 246);
  doc.rect(margin, y, contentWidth, 10, 'F');

  doc.setFontSize(8);
  doc.setFont('helvetica', 'bold');
  doc.setTextColor(55, 65, 81);

  const cols = {
    orden: margin + 3,
    cliente: margin + 15,
    direccion: margin + 60,
    telefono: margin + 120,
    total: margin + 150,
    estado: margin + 175
  };

  doc.text('#', cols.orden, y + 7);
  doc.text('CLIENTE', cols.cliente, y + 7);
  doc.text('DIRECCION', cols.direccion, y + 7);
  doc.text('TELEFONO', cols.telefono, y + 7);
  doc.text('TOTAL', cols.total, y + 7);
  doc.text('CHECK', cols.estado, y + 7);

  y += 12;

  // Filas de pedidos
  doc.setFont('helvetica', 'normal');
  doc.setTextColor(0, 0, 0);

  pedidos.forEach((pedido, index) => {
    // Verificar si necesitamos nueva pagina
    if (y > pageHeight - 60) {
      doc.addPage();
      y = margin;

      // Repetir header de tabla en nueva pagina
      doc.setFillColor(243, 244, 246);
      doc.rect(margin, y, contentWidth, 10, 'F');
      doc.setFontSize(8);
      doc.setFont('helvetica', 'bold');
      doc.setTextColor(55, 65, 81);
      doc.text('#', cols.orden, y + 7);
      doc.text('CLIENTE', cols.cliente, y + 7);
      doc.text('DIRECCION', cols.direccion, y + 7);
      doc.text('TELEFONO', cols.telefono, y + 7);
      doc.text('TOTAL', cols.total, y + 7);
      doc.text('CHECK', cols.estado, y + 7);
      y += 12;
      doc.setFont('helvetica', 'normal');
      doc.setTextColor(0, 0, 0);
    }

    const rowHeight = 18;

    // Fondo alternado
    if (index % 2 === 0) {
      doc.setFillColor(255, 255, 255);
    } else {
      doc.setFillColor(249, 250, 251);
    }
    doc.rect(margin, y, contentWidth, rowHeight, 'F');

    // Linea inferior
    doc.setDrawColor(229, 231, 235);
    doc.line(margin, y + rowHeight, margin + contentWidth, y + rowHeight);

    doc.setFontSize(8);

    // Numero de orden (circulo)
    const circleX = cols.orden + 4;
    const circleY = y + 6;
    doc.setFillColor(37, 99, 235);
    doc.circle(circleX, circleY, 4, 'F');
    doc.setTextColor(255, 255, 255);
    doc.setFont('helvetica', 'bold');
    doc.text((index + 1).toString(), circleX, circleY + 1.5, { align: 'center' });
    doc.setTextColor(0, 0, 0);
    doc.setFont('helvetica', 'normal');

    // Cliente
    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente';
    const nombreTruncado = clienteNombre.length > 22 ? clienteNombre.substring(0, 20) + '..' : clienteNombre;
    doc.setFont('helvetica', 'bold');
    doc.text(nombreTruncado, cols.cliente, y + 6);
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(7);
    doc.setTextColor(107, 114, 128);
    doc.text(`Pedido #${pedido.id}`, cols.cliente, y + 11);
    doc.setTextColor(0, 0, 0);
    doc.setFontSize(8);

    // Direccion
    const direccion = pedido.cliente?.direccion || 'Sin direccion';
    const dirLines = doc.splitTextToSize(direccion, 55);
    doc.text(dirLines.slice(0, 2).join('\n'), cols.direccion, y + 6);

    // Telefono
    doc.text(pedido.cliente?.telefono || '-', cols.telefono, y + 6);

    // Total y estado de pago
    doc.setFont('helvetica', 'bold');
    doc.text(formatPrecio(pedido.total), cols.total, y + 6);
    doc.setFont('helvetica', 'normal');

    const estadoPagoLabel = pedido.estado_pago === 'pagado' ? 'PAGADO' : pedido.estado_pago === 'parcial' ? 'PARCIAL' : 'PEND';
    const estadoColor = pedido.estado_pago === 'pagado' ? [34, 197, 94] : pedido.estado_pago === 'parcial' ? [234, 179, 8] : [239, 68, 68];
    doc.setTextColor(...estadoColor);
    doc.setFontSize(7);
    doc.text(estadoPagoLabel, cols.total, y + 11);
    doc.setTextColor(0, 0, 0);
    doc.setFontSize(8);

    // Forma de pago
    const formaPagoLabels = {
      efectivo: 'Efvo',
      transferencia: 'Transf',
      cheque: 'Cheque',
      cuenta_corriente: 'C.Cte',
      tarjeta: 'Tarj'
    };
    doc.setFontSize(6);
    doc.setTextColor(107, 114, 128);
    doc.text(formaPagoLabels[pedido.forma_pago] || 'Efvo', cols.total, y + 15);
    doc.setTextColor(0, 0, 0);
    doc.setFontSize(8);

    // Checkbox de entregado
    doc.setDrawColor(156, 163, 175);
    doc.rect(cols.estado + 2, y + 3, 6, 6);

    y += rowHeight;
  });

  // === SECCION DE PRODUCTOS (siguiente pagina si es necesario) ===
  if (y > pageHeight - 80) {
    doc.addPage();
    y = margin;
  } else {
    y += 10;
  }

  // Detalle de productos por entrega
  doc.setFontSize(10);
  doc.setFont('helvetica', 'bold');
  doc.text('DETALLE DE PRODUCTOS POR ENTREGA', margin, y);
  y += 8;

  doc.setFontSize(7);
  doc.setFont('helvetica', 'normal');

  pedidos.forEach((pedido, index) => {
    if (y > pageHeight - 30) {
      doc.addPage();
      y = margin;
    }

    doc.setFont('helvetica', 'bold');
    doc.text(`${index + 1}. ${pedido.cliente?.nombre_fantasia || 'Cliente'} (#${pedido.id})`, margin, y);
    doc.setFont('helvetica', 'normal');

    const productos = pedido.items?.map(i =>
      `${i.cantidad}x ${(i.producto?.nombre || '?').substring(0, 25)}`
    ).join(', ') || 'Sin productos';

    const prodLines = doc.splitTextToSize(productos, contentWidth - 5);
    y += 4;
    prodLines.slice(0, 2).forEach(line => {
      doc.text(line, margin + 5, y);
      y += 3.5;
    });

    if (pedido.notas) {
      doc.setFont('helvetica', 'italic');
      doc.setTextColor(107, 114, 128);
      const notaTruncada = pedido.notas.length > 60 ? pedido.notas.substring(0, 58) + '..' : pedido.notas;
      doc.text(`Nota: ${notaTruncada}`, margin + 5, y);
      doc.setTextColor(0, 0, 0);
      doc.setFont('helvetica', 'normal');
      y += 3.5;
    }

    y += 3;
  });

  // === SECCION DE FIRMA ===
  if (y > pageHeight - 50) {
    doc.addPage();
    y = margin;
  } else {
    y += 10;
  }

  doc.setDrawColor(156, 163, 175);
  doc.line(margin, y, margin + contentWidth, y);
  y += 10;

  doc.setFontSize(9);
  doc.setFont('helvetica', 'bold');
  doc.text('CIERRE DE JORNADA', margin, y);
  y += 8;

  doc.setFont('helvetica', 'normal');
  doc.setFontSize(8);

  // Campos para llenar
  const fieldY = y;
  doc.text('Total cobrado en efectivo: ___________________', margin, fieldY);
  doc.text('Total cobrado transferencia: ___________________', margin, fieldY + 8);
  doc.text('Entregas completadas: _____ de ' + pedidos.length, margin, fieldY + 16);

  doc.text('Observaciones:', margin + 100, fieldY);
  doc.setDrawColor(200, 200, 200);
  doc.rect(margin + 100, fieldY + 4, 75, 20);

  y = fieldY + 35;
  doc.text('Firma transportista: _______________________', margin, y);
  doc.text('Fecha: ' + formatFecha(new Date()), margin + 100, y);

  // Descargar PDF
  const fecha = formatFecha(new Date()).replace(/\//g, '-');
  const nombreTransportista = (transportista?.nombre || 'transportista').replace(/\s+/g, '-').toLowerCase();
  doc.save(`ruta-optimizada-${nombreTransportista}-${fecha}.pdf`);
}
