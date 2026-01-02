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
