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
 * Formato: Ticket comandera de 75mm de ancho - estilo plano
 * @param {Object} transportista - Datos del transportista
 * @param {Array} pedidos - Lista de pedidos ordenados por ruta optimizada
 * @param {Object} infoRuta - Informacion de la ruta (duracion, distancia)
 * @returns {void} - Descarga el PDF
 */
export function generarHojaRutaOptimizada(transportista, pedidos, infoRuta = {}) {
  // Ticket comandera: 75mm de ancho, altura dinamica
  const ticketWidth = 75; // mm
  const margin = 3; // mm
  const contentWidth = ticketWidth - (margin * 2);

  // Calcular altura necesaria
  let totalHeight = 40; // Header + resumen
  pedidos.forEach(pedido => {
    totalHeight += 22; // Info basica del pedido
    const itemsCount = pedido.items?.length || 0;
    totalHeight += Math.ceil(itemsCount * 4); // Productos con nombre completo
    if (pedido.notas) totalHeight += 5;
  });
  totalHeight += 35; // Cierre de jornada

  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: [ticketWidth, Math.max(totalHeight, 100)]
  });

  let y = margin;

  // === HEADER (sin colores) ===
  doc.setTextColor(0, 0, 0);
  doc.setFontSize(12);
  doc.setFont('helvetica', 'bold');
  doc.text('HOJA DE RUTA', ticketWidth / 2, y + 4, { align: 'center' });
  y += 7;

  doc.setFontSize(9);
  doc.text(transportista?.nombre || 'Transportista', ticketWidth / 2, y, { align: 'center' });
  y += 4;

  doc.setFontSize(7);
  doc.setFont('helvetica', 'normal');
  doc.text(formatFecha(new Date()), ticketWidth / 2, y, { align: 'center' });
  y += 3;

  // Metricas de ruta
  const metricasTexto = [];
  if (infoRuta.duracion_formato) metricasTexto.push(infoRuta.duracion_formato);
  if (infoRuta.distancia_formato) metricasTexto.push(infoRuta.distancia_formato);
  metricasTexto.push(`${pedidos.length} entregas`);
  doc.setFontSize(6);
  doc.text(metricasTexto.join(' | '), ticketWidth / 2, y, { align: 'center' });
  y += 4;

  // Linea divisora
  doc.setDrawColor(0, 0, 0);
  doc.setLineWidth(0.3);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 3;

  // === RESUMEN DE COBRO ===
  const totalGeneral = pedidos.reduce((sum, p) => sum + (p.total || 0), 0);
  const totalPendiente = pedidos.filter(p => p.estado_pago !== 'pagado').reduce((sum, p) => sum + (p.total || 0), 0);

  doc.setFontSize(7);
  doc.setFont('helvetica', 'bold');
  doc.text('TOTAL:', margin, y + 3);
  doc.text(formatPrecio(totalGeneral), ticketWidth - margin, y + 3, { align: 'right' });
  y += 4;

  doc.setFont('helvetica', 'normal');
  doc.setFontSize(6);
  doc.text(`Pendiente cobro: ${formatPrecio(totalPendiente)}`, margin, y + 2);
  y += 5;

  // Linea divisora
  doc.setLineWidth(0.5);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 4;

  // === LISTA DE ENTREGAS ===
  pedidos.forEach((pedido, index) => {
    // Numero de orden y cliente (sin circulo, solo numero)
    doc.setFontSize(8);
    doc.setFont('helvetica', 'bold');
    doc.text(`${index + 1}.`, margin, y);

    // Nombre del cliente completo
    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente';
    doc.text(clienteNombre, margin + 6, y);
    y += 4;

    // Direccion completa
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(6);
    const direccion = pedido.cliente?.direccion || 'Sin direccion';
    const dirLines = doc.splitTextToSize(direccion, contentWidth - 2);
    dirLines.slice(0, 2).forEach(line => {
      doc.text(line, margin, y);
      y += 2.5;
    });

    // Telefono
    if (pedido.cliente?.telefono) {
      doc.text(`Tel: ${pedido.cliente.telefono}`, margin, y);
      y += 2.5;
    }

    // Total y estado de pago
    doc.setFontSize(7);
    doc.setFont('helvetica', 'bold');
    const estadoPago = pedido.estado_pago === 'pagado' ? 'PAGADO' : pedido.estado_pago === 'parcial' ? 'PARCIAL' : 'PEND';
    doc.text(`${formatPrecio(pedido.total)} - ${estadoPago}`, margin, y);
    y += 3;

    // Productos con nombre completo
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(6);
    pedido.items?.forEach(item => {
      const productoNombre = item.producto?.nombre || 'Producto';
      doc.text(`  ${item.cantidad}x ${productoNombre}`, margin, y);
      y += 2.5;
    });

    // Notas
    if (pedido.notas) {
      doc.setFont('helvetica', 'italic');
      const notasTruncadas = pedido.notas.length > 50 ? pedido.notas.substring(0, 48) + '..' : pedido.notas;
      doc.text(`* ${notasTruncadas}`, margin, y);
      doc.setFont('helvetica', 'normal');
      y += 2.5;
    }

    // Checkbox entregado
    y += 1;
    doc.setDrawColor(100, 100, 100);
    doc.rect(margin, y - 2, 2.5, 2.5);
    doc.text('Entregado  Firma:__________', margin + 4, y);
    y += 4;

    // Linea divisora entre pedidos
    doc.setDrawColor(150, 150, 150);
    doc.setLineWidth(0.2);
    doc.line(margin, y, ticketWidth - margin, y);
    y += 3;
  });

  // === CIERRE DE JORNADA ===
  y += 2;
  doc.setDrawColor(0, 0, 0);
  doc.setLineWidth(0.5);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 4;

  doc.setFontSize(8);
  doc.setFont('helvetica', 'bold');
  doc.text('CIERRE DE JORNADA', ticketWidth / 2, y, { align: 'center' });
  y += 5;

  doc.setFont('helvetica', 'normal');
  doc.setFontSize(6);

  doc.text('Cobrado efectivo: ____________', margin, y);
  y += 4;
  doc.text('Cobrado transf: _____________', margin, y);
  y += 4;
  doc.text(`Entregas: _____ de ${pedidos.length}`, margin, y);
  y += 4;
  doc.text('Firma: ___________________', margin, y);

  // Descargar PDF
  const fecha = formatFecha(new Date()).replace(/\//g, '-');
  const nombreTransportista = (transportista?.nombre || 'transportista').replace(/\s+/g, '-').toLowerCase();
  doc.save(`ruta-${nombreTransportista}-${fecha}.pdf`);
}

/**
 * Genera PDF de Recibo de Pago
 * Formato: Ticket comandera de 75mm de ancho
 * @param {Object} pago - Datos del pago registrado
 * @param {Object} cliente - Datos del cliente
 * @param {Object} empresa - Datos de la empresa (opcional)
 * @returns {void} - Descarga el PDF
 */
export function generarReciboPago(pago, cliente, empresa = {}) {
  const ticketWidth = 75; // mm
  const margin = 3; // mm
  const contentWidth = ticketWidth - (margin * 2);

  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: [ticketWidth, 120] // Altura fija para recibo
  });

  let y = margin;

  // === HEADER ===
  doc.setTextColor(0, 0, 0);
  doc.setFontSize(12);
  doc.setFont('helvetica', 'bold');
  doc.text('RECIBO DE PAGO', ticketWidth / 2, y + 4, { align: 'center' });
  y += 8;

  // Nombre empresa (opcional)
  if (empresa.nombre) {
    doc.setFontSize(8);
    doc.setFont('helvetica', 'normal');
    doc.text(empresa.nombre, ticketWidth / 2, y, { align: 'center' });
    y += 4;
  }

  // Numero de recibo
  doc.setFontSize(9);
  doc.setFont('helvetica', 'bold');
  doc.text(`N° ${pago.id || '---'}`, ticketWidth / 2, y, { align: 'center' });
  y += 5;

  // Fecha y hora
  doc.setFontSize(7);
  doc.setFont('helvetica', 'normal');
  const fechaHora = new Date(pago.created_at || new Date()).toLocaleString('es-AR', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit'
  });
  doc.text(fechaHora, ticketWidth / 2, y, { align: 'center' });
  y += 5;

  // Linea divisora
  doc.setLineWidth(0.3);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 5;

  // === DATOS DEL CLIENTE ===
  doc.setFontSize(7);
  doc.text('RECIBIDO DE:', margin, y);
  y += 3;

  doc.setFontSize(9);
  doc.setFont('helvetica', 'bold');
  doc.text(cliente?.nombre_fantasia || cliente?.nombre || 'Cliente', margin, y);
  y += 4;

  doc.setFontSize(7);
  doc.setFont('helvetica', 'normal');
  if (cliente?.direccion) {
    doc.text(cliente.direccion, margin, y);
    y += 3;
  }
  if (cliente?.telefono) {
    doc.text(`Tel: ${cliente.telefono}`, margin, y);
    y += 3;
  }
  y += 2;

  // Linea divisora
  doc.setLineWidth(0.2);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 5;

  // === DETALLE DEL PAGO ===
  doc.setFontSize(7);
  doc.text('LA SUMA DE:', margin, y);
  y += 5;

  // Monto grande
  doc.setFontSize(16);
  doc.setFont('helvetica', 'bold');
  doc.text(formatPrecio(pago.monto), ticketWidth / 2, y, { align: 'center' });
  y += 7;

  // Forma de pago
  doc.setFontSize(8);
  doc.setFont('helvetica', 'normal');
  const formasPagoLabels = {
    efectivo: 'EFECTIVO',
    transferencia: 'TRANSFERENCIA BANCARIA',
    cheque: 'CHEQUE',
    tarjeta: 'TARJETA',
    cuenta_corriente: 'CUENTA CORRIENTE'
  };
  doc.text(`Forma de pago: ${formasPagoLabels[pago.forma_pago] || pago.forma_pago || 'EFECTIVO'}`, margin, y);
  y += 4;

  // Referencia si existe
  if (pago.referencia) {
    doc.text(`Referencia: ${pago.referencia}`, margin, y);
    y += 4;
  }

  // Pedido asociado si existe
  if (pago.pedido_id) {
    doc.text(`Aplicado a Pedido #${pago.pedido_id}`, margin, y);
    y += 4;
  }

  // Concepto/Notas
  y += 2;
  doc.text('CONCEPTO:', margin, y);
  y += 3;
  doc.setFontSize(7);
  const concepto = pago.notas || 'Pago a cuenta';
  const conceptoLines = doc.splitTextToSize(concepto, contentWidth);
  conceptoLines.slice(0, 2).forEach(line => {
    doc.text(line, margin, y);
    y += 3;
  });
  y += 3;

  // Linea divisora
  doc.setLineWidth(0.3);
  doc.line(margin, y, ticketWidth - margin, y);
  y += 5;

  // === FIRMA ===
  doc.setFontSize(7);
  doc.text('Recibido por: ________________', margin, y);
  y += 6;
  doc.text('Firma: ______________________', margin, y);
  y += 8;

  // === PIE ===
  doc.setFontSize(6);
  doc.setFont('helvetica', 'italic');
  doc.text('Este recibo es comprobante de pago valido', ticketWidth / 2, y, { align: 'center' });
  y += 3;
  doc.text('Conserve este documento', ticketWidth / 2, y, { align: 'center' });

  // Descargar PDF
  const fecha = formatFecha(new Date()).replace(/\//g, '-');
  doc.save(`recibo-${pago.id || 'pago'}-${fecha}.pdf`);
}

/**
 * Genera PDF de Estado de Cuenta del Cliente
 * Formato: A4 para impresion profesional
 * @param {Object} cliente - Datos del cliente
 * @param {Array} pedidos - Lista de pedidos del cliente
 * @param {Array} pagos - Lista de pagos del cliente
 * @param {Object} resumen - Resumen de cuenta
 * @returns {void} - Descarga el PDF
 */
export function generarEstadoCuenta(cliente, pedidos, pagos, resumen) {
  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: 'a4'
  });

  const pageWidth = 210;
  const margin = 15;
  const contentWidth = pageWidth - (margin * 2);
  let y = margin;

  // === HEADER ===
  doc.setFontSize(18);
  doc.setFont('helvetica', 'bold');
  doc.text('ESTADO DE CUENTA', pageWidth / 2, y, { align: 'center' });
  y += 10;

  doc.setFontSize(10);
  doc.setFont('helvetica', 'normal');
  doc.text(`Fecha: ${formatFecha(new Date())}`, pageWidth - margin, y, { align: 'right' });
  y += 10;

  // === DATOS DEL CLIENTE ===
  doc.setFillColor(240, 240, 240);
  doc.rect(margin, y, contentWidth, 25, 'F');
  y += 5;

  doc.setFontSize(12);
  doc.setFont('helvetica', 'bold');
  doc.text(cliente?.nombre_fantasia || cliente?.nombre || 'Cliente', margin + 5, y + 3);

  doc.setFontSize(9);
  doc.setFont('helvetica', 'normal');
  y += 7;
  if (cliente?.direccion) doc.text(`Direccion: ${cliente.direccion}`, margin + 5, y + 3);
  y += 5;
  if (cliente?.telefono) doc.text(`Telefono: ${cliente.telefono}`, margin + 5, y + 3);
  if (cliente?.zona) doc.text(`Zona: ${cliente.zona}`, margin + 100, y + 3);
  y += 15;

  // === RESUMEN ===
  doc.setFontSize(11);
  doc.setFont('helvetica', 'bold');
  doc.text('RESUMEN DE CUENTA', margin, y);
  y += 6;

  doc.setFontSize(9);
  doc.setFont('helvetica', 'normal');

  // Grid de resumen
  const col1 = margin;
  const col2 = margin + 60;
  const col3 = margin + 120;

  doc.text('Total Compras:', col1, y);
  doc.text(formatPrecio(resumen?.total_compras || 0), col1 + 35, y);

  doc.text('Total Pagos:', col2, y);
  doc.text(formatPrecio(resumen?.total_pagos || 0), col2 + 35, y);
  y += 5;

  doc.text('Limite Credito:', col1, y);
  doc.text(formatPrecio(cliente?.limite_credito || 0), col1 + 35, y);

  doc.text('Dias Credito:', col2, y);
  doc.text(`${cliente?.dias_credito || 30} dias`, col2 + 35, y);
  y += 8;

  // Saldo destacado
  doc.setFillColor(resumen?.saldo_actual > 0 ? 255 : 220, resumen?.saldo_actual > 0 ? 240 : 255, 240);
  doc.rect(col3 - 5, y - 12, 65, 18, 'F');
  doc.setFontSize(10);
  doc.setFont('helvetica', 'bold');
  doc.text('SALDO ACTUAL:', col3, y - 5);
  doc.setFontSize(14);
  doc.setTextColor(resumen?.saldo_actual > 0 ? 200 : 0, resumen?.saldo_actual > 0 ? 0 : 150, 0);
  doc.text(formatPrecio(resumen?.saldo_actual || 0), col3, y + 2);
  doc.setTextColor(0, 0, 0);
  y += 15;

  // === MOVIMIENTOS ===
  doc.setFontSize(11);
  doc.setFont('helvetica', 'bold');
  doc.text('ULTIMOS MOVIMIENTOS', margin, y);
  y += 6;

  // Combinar y ordenar pedidos y pagos
  const movimientos = [
    ...(pedidos || []).map(p => ({
      fecha: p.created_at,
      tipo: 'PEDIDO',
      detalle: `Pedido #${p.id}`,
      debe: p.total,
      haber: 0,
      estado: p.estado_pago
    })),
    ...(pagos || []).map(p => ({
      fecha: p.created_at,
      tipo: 'PAGO',
      detalle: `${p.forma_pago}${p.referencia ? ` - ${p.referencia}` : ''}`,
      debe: 0,
      haber: p.monto
    }))
  ].sort((a, b) => new Date(b.fecha) - new Date(a.fecha)).slice(0, 20);

  // Encabezados de tabla
  doc.setFontSize(8);
  doc.setFont('helvetica', 'bold');
  doc.setFillColor(50, 50, 50);
  doc.setTextColor(255, 255, 255);
  doc.rect(margin, y, contentWidth, 6, 'F');
  y += 4;
  doc.text('FECHA', margin + 2, y);
  doc.text('TIPO', margin + 25, y);
  doc.text('DETALLE', margin + 50, y);
  doc.text('DEBE', margin + 120, y);
  doc.text('HABER', margin + 145, y);
  doc.text('ESTADO', margin + 170, y);
  y += 5;
  doc.setTextColor(0, 0, 0);

  // Filas
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(7);
  let saldoAcumulado = 0;

  movimientos.reverse().forEach((mov, index) => {
    saldoAcumulado += mov.debe - mov.haber;

    if (y > 270) {
      doc.addPage();
      y = margin;
    }

    // Alternar color de fila
    if (index % 2 === 0) {
      doc.setFillColor(248, 248, 248);
      doc.rect(margin, y - 3, contentWidth, 5, 'F');
    }

    doc.text(formatFecha(mov.fecha), margin + 2, y);
    doc.text(mov.tipo, margin + 25, y);
    doc.text(mov.detalle.substring(0, 30), margin + 50, y);
    doc.text(mov.debe > 0 ? formatPrecio(mov.debe) : '-', margin + 120, y);
    doc.text(mov.haber > 0 ? formatPrecio(mov.haber) : '-', margin + 145, y);
    doc.text(mov.estado || '-', margin + 170, y);
    y += 5;
  });

  // Descargar PDF
  const fecha = formatFecha(new Date()).replace(/\//g, '-');
  const nombreCliente = (cliente?.nombre_fantasia || 'cliente').replace(/\s+/g, '-').toLowerCase().substring(0, 20);
  doc.save(`estado-cuenta-${nombreCliente}-${fecha}.pdf`);
}
