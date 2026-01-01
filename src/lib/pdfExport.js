import { jsPDF } from 'jspdf';

const formatPrecio = (p) => new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0);
const formatFecha = (fecha) => new Date(fecha || new Date()).toLocaleDateString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric' });

/**
 * Genera PDF de Orden de Preparación para el depósito
 * @param {Array} pedidos - Lista de pedidos a incluir
 * @returns {void} - Descarga el PDF
 */
export function generarOrdenPreparacion(pedidos) {
  const doc = new jsPDF();
  const pageWidth = doc.internal.pageSize.getWidth();
  const pageHeight = doc.internal.pageSize.getHeight();
  const margin = 15;
  let y = margin;

  // Función para agregar nueva página si es necesario
  const checkNewPage = (requiredSpace = 30) => {
    if (y + requiredSpace > pageHeight - margin) {
      doc.addPage();
      y = margin;
      return true;
    }
    return false;
  };

  // Título principal
  doc.setFontSize(18);
  doc.setFont('helvetica', 'bold');
  doc.text('ORDENES DE PREPARACION', pageWidth / 2, y, { align: 'center' });
  y += 8;

  doc.setFontSize(12);
  doc.setFont('helvetica', 'normal');
  doc.text(formatFecha(new Date()), pageWidth / 2, y, { align: 'center' });
  y += 5;

  doc.setFontSize(10);
  doc.text(`Total de pedidos: ${pedidos.length}`, pageWidth / 2, y, { align: 'center' });
  y += 12;

  // Línea divisora
  doc.setLineWidth(0.5);
  doc.line(margin, y, pageWidth - margin, y);
  y += 8;

  // Iterar sobre cada pedido
  pedidos.forEach((pedido, index) => {
    // Calcular espacio necesario para este pedido
    const itemsCount = pedido.items?.length || 0;
    const requiredSpace = 40 + (itemsCount * 8);
    checkNewPage(requiredSpace);

    // Cabecera del pedido
    doc.setFillColor(240, 240, 240);
    doc.rect(margin, y - 2, pageWidth - (margin * 2), 12, 'F');

    doc.setFontSize(12);
    doc.setFont('helvetica', 'bold');
    doc.text(`PEDIDO #${pedido.id}`, margin + 3, y + 5);

    doc.setFont('helvetica', 'normal');
    doc.setFontSize(10);
    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente';
    doc.text(clienteNombre, margin + 50, y + 5);
    y += 14;

    // Dirección del cliente
    doc.setFontSize(9);
    doc.setTextColor(100);
    const direccion = pedido.cliente?.direccion || 'Sin dirección';
    doc.text(`Direccion: ${direccion}`, margin + 3, y);
    y += 6;

    // Teléfono si existe
    if (pedido.cliente?.telefono) {
      doc.text(`Telefono: ${pedido.cliente.telefono}`, margin + 3, y);
      y += 6;
    }

    // Notas si existen
    if (pedido.notas) {
      doc.setTextColor(0, 100, 200);
      doc.text(`Notas: ${pedido.notas}`, margin + 3, y);
      y += 6;
    }

    doc.setTextColor(0);
    y += 4;

    // Lista de productos con checkboxes
    doc.setFontSize(10);
    pedido.items?.forEach((item) => {
      checkNewPage(10);

      // Checkbox vacío
      doc.setLineWidth(0.3);
      doc.rect(margin + 3, y - 3, 4, 4);

      // Cantidad y producto
      const cantidad = item.cantidad;
      const producto = item.producto?.nombre || 'Producto desconocido';
      doc.text(`${cantidad}x ${producto}`, margin + 12, y);
      y += 7;
    });

    y += 5;

    // Línea divisora entre pedidos
    doc.setLineWidth(0.2);
    doc.setDrawColor(200);
    doc.line(margin, y, pageWidth - margin, y);
    doc.setDrawColor(0);
    y += 8;
  });

  // Descargar PDF
  const fecha = formatFecha(new Date()).replace(/\//g, '-');
  doc.save(`orden-preparacion-${fecha}.pdf`);
}

/**
 * Genera PDF de Hoja de Ruta para el transportista
 * @param {Object} transportista - Datos del transportista
 * @param {Array} pedidos - Lista de pedidos asignados
 * @returns {void} - Descarga el PDF
 */
export function generarHojaRuta(transportista, pedidos) {
  const doc = new jsPDF();
  const pageWidth = doc.internal.pageSize.getWidth();
  const pageHeight = doc.internal.pageSize.getHeight();
  const margin = 15;
  let y = margin;

  // Función para agregar nueva página si es necesario
  const checkNewPage = (requiredSpace = 30) => {
    if (y + requiredSpace > pageHeight - margin) {
      doc.addPage();
      y = margin;
      // Repetir cabecera en nueva página
      doc.setFontSize(10);
      doc.setFont('helvetica', 'italic');
      doc.text(`Hoja de Ruta - ${transportista?.nombre || 'Transportista'} (continuacion)`, margin, y);
      y += 10;
      return true;
    }
    return false;
  };

  // Calcular totales
  const totalPedidos = pedidos.length;
  const totalACobrar = pedidos.reduce((sum, p) => sum + (p.total || 0), 0);
  const totalPendienteCobro = pedidos
    .filter(p => p.estado_pago !== 'pagado')
    .reduce((sum, p) => sum + (p.total || 0), 0);

  // Título principal
  doc.setFontSize(18);
  doc.setFont('helvetica', 'bold');
  doc.text('HOJA DE RUTA', pageWidth / 2, y, { align: 'center' });
  y += 10;

  // Información del transportista
  doc.setFontSize(14);
  doc.setFont('helvetica', 'bold');
  doc.text(transportista?.nombre || 'Transportista', pageWidth / 2, y, { align: 'center' });
  y += 7;

  doc.setFontSize(11);
  doc.setFont('helvetica', 'normal');
  doc.text(formatFecha(new Date()), pageWidth / 2, y, { align: 'center' });
  y += 10;

  // Resumen
  doc.setFillColor(230, 240, 250);
  doc.rect(margin, y, pageWidth - (margin * 2), 20, 'F');
  y += 6;

  doc.setFontSize(10);
  doc.text(`Total entregas: ${totalPedidos}`, margin + 5, y);
  doc.text(`Total a cobrar: ${formatPrecio(totalACobrar)}`, pageWidth / 2, y);
  y += 7;
  doc.text(`Pendiente de cobro: ${formatPrecio(totalPendienteCobro)}`, margin + 5, y);
  y += 12;

  // Línea divisora
  doc.setLineWidth(0.5);
  doc.line(margin, y, pageWidth - margin, y);
  y += 10;

  // Iterar sobre cada pedido/entrega
  pedidos.forEach((pedido, index) => {
    // Calcular espacio necesario
    const itemsText = pedido.items?.map(i => `${i.producto?.nombre} x${i.cantidad}`).join(', ') || '';
    const requiredSpace = 60;
    checkNewPage(requiredSpace);

    // Número de entrega
    doc.setFillColor(50, 100, 150);
    doc.setTextColor(255);
    doc.setFontSize(12);
    doc.setFont('helvetica', 'bold');
    doc.circle(margin + 8, y, 6, 'F');
    doc.text(`${index + 1}`, margin + 6, y + 3);
    doc.setTextColor(0);

    // Nombre del cliente
    doc.setFontSize(12);
    doc.setFont('helvetica', 'bold');
    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente';
    doc.text(clienteNombre, margin + 20, y + 2);

    // Total del pedido
    const estadoPagoColor = pedido.estado_pago === 'pagado' ? [0, 150, 0] :
                            pedido.estado_pago === 'parcial' ? [200, 150, 0] : [200, 0, 0];
    doc.setTextColor(...estadoPagoColor);
    doc.text(formatPrecio(pedido.total), pageWidth - margin - 5, y + 2, { align: 'right' });
    doc.setTextColor(0);
    y += 10;

    // Dirección
    doc.setFontSize(10);
    doc.setFont('helvetica', 'normal');
    const direccion = pedido.cliente?.direccion || 'Sin dirección';
    doc.text(`  ${direccion}`, margin + 20, y);
    y += 6;

    // Teléfono
    if (pedido.cliente?.telefono) {
      doc.text(`  Tel: ${pedido.cliente.telefono}`, margin + 20, y);
      y += 6;
    }

    // Estado de pago
    const estadoPagoTexto = pedido.estado_pago === 'pagado' ? 'PAGADO' :
                           pedido.estado_pago === 'parcial' ? 'PAGO PARCIAL' : 'PENDIENTE DE PAGO';
    doc.setTextColor(...estadoPagoColor);
    doc.text(`  Estado: ${estadoPagoTexto}`, margin + 20, y);
    doc.setTextColor(0);
    y += 6;

    // Forma de pago
    if (pedido.forma_pago) {
      const formaPagoTexto = {
        efectivo: 'Efectivo',
        transferencia: 'Transferencia',
        cheque: 'Cheque',
        cuenta_corriente: 'Cuenta Corriente',
        tarjeta: 'Tarjeta'
      }[pedido.forma_pago] || pedido.forma_pago;
      doc.text(`  Forma de pago: ${formaPagoTexto}`, margin + 20, y);
      y += 6;
    }

    // Productos (resumido)
    doc.setFontSize(9);
    doc.setTextColor(80);
    // Dividir productos en líneas si son muy largos
    const maxWidth = pageWidth - margin - 30;
    const productosLines = doc.splitTextToSize(`  Productos: ${itemsText}`, maxWidth);
    productosLines.forEach(line => {
      checkNewPage(8);
      doc.text(line, margin + 20, y);
      y += 5;
    });
    doc.setTextColor(0);
    y += 3;

    // Notas si existen
    if (pedido.notas) {
      doc.setFontSize(9);
      doc.setTextColor(0, 100, 200);
      const notasLines = doc.splitTextToSize(`  Notas: ${pedido.notas}`, maxWidth);
      notasLines.forEach(line => {
        checkNewPage(8);
        doc.text(line, margin + 20, y);
        y += 5;
      });
      doc.setTextColor(0);
      y += 2;
    }

    // Área de firma
    y += 3;
    doc.setFontSize(9);
    doc.setFont('helvetica', 'normal');
    doc.text('Entregado:', margin + 20, y);

    // Checkbox
    doc.setLineWidth(0.3);
    doc.rect(margin + 45, y - 3, 4, 4);
    doc.text('SI', margin + 51, y);
    doc.rect(margin + 60, y - 3, 4, 4);
    doc.text('NO', margin + 66, y);

    // Línea para firma
    doc.text('Firma: ___________________________', margin + 90, y);
    y += 10;

    // Línea divisora
    doc.setLineWidth(0.2);
    doc.setDrawColor(180);
    doc.line(margin + 15, y, pageWidth - margin, y);
    doc.setDrawColor(0);
    y += 8;
  });

  // Pie de página con resumen final en la última página
  y = pageHeight - 40;
  doc.setLineWidth(0.5);
  doc.line(margin, y, pageWidth - margin, y);
  y += 8;

  doc.setFontSize(10);
  doc.setFont('helvetica', 'bold');
  doc.text('RESUMEN DE COBRANZA', margin, y);
  y += 8;

  doc.setFont('helvetica', 'normal');
  doc.text(`Total cobrado: ___________________`, margin, y);
  doc.text(`Total en efectivo: ___________________`, pageWidth / 2, y);
  y += 7;
  doc.text(`Total transferencia: ___________________`, margin, y);
  doc.text(`Firma transportista: ___________________`, pageWidth / 2, y);

  // Descargar PDF
  const fecha = formatFecha(new Date()).replace(/\//g, '-');
  const nombreTransportista = (transportista?.nombre || 'transportista').replace(/\s+/g, '-').toLowerCase();
  doc.save(`hoja-ruta-${nombreTransportista}-${fecha}.pdf`);
}
