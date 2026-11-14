// Laboratorio: ejecuta C1–C5 sin índices o con los planes A/B de sql/08_indices.sql.
const { api, fmt, esc } = SkyNest;
const $ = (id) => document.getElementById(id);
let consultas = [], actual = null, condicion = 'sin';
const NOMBRES = { sin: 'Sin índices', A: 'Plan A', B: 'Plan B' };

function mostrarConsulta() {
  const q = consultas.find((c) => c.id === actual);
  document.querySelectorAll('.consulta-item').forEach((b) => b.classList.toggle('activo', b.dataset.id === actual));
  $('q-id').textContent = q.id;
  $('q-titulo').textContent = q.titulo;
  $('q-desc').textContent = q.descripcion;
  $('q-sql').textContent = q.sql;
  mostrarPlan();
}

function mostrarPlan() {
  const q = consultas.find((c) => c.id === actual);
  document.querySelectorAll('#condiciones button').forEach((b) => b.classList.toggle('activo', b.dataset.c === condicion));
  if (condicion === 'sin') {
    $('plan-desc').textContent = 'Solo los índices que PostgreSQL crea por sí mismo: llaves primarias, UNIQUE y el EXCLUDE de vuelo. Las llaves foráneas no tienen índice.';
    $('plan-sql').innerHTML = '';
  } else {
    const p = q.planes[condicion];
    $('plan-desc').textContent = p.descripcion;
    $('plan-sql').innerHTML = `<pre class="codigo" style="margin-top: 12px">${esc(p.sentencias.join('\n'))}</pre>`;
  }
}

function aviso(texto, tipo = 'info') {
  $('estado').innerHTML = texto ? `<div class="mensaje mensaje-${tipo}">${esc(texto)}</div>` : '';
}

function ocupado(si) {
  $('ejecutar').disabled = si;
  $('comparar').disabled = si;
}

async function ejecutar() {
  ocupado(true);
  aviso(`Ejecutando ${actual} (${NOMBRES[condicion]})… se prepara la base y se corre 4 veces.`);
  try {
    const rpc = $('rpc').checked;
    const r = await api(`/api/consultas/${actual}/ejecutar?condicion=${condicion}&rpc=${rpc}`, { method: 'POST', conBase: true });
    aviso(r.seg_creacion > 0 ? `Se crearon los índices del ${NOMBRES[condicion]} en ${fmt(r.seg_creacion, 1)} s.` : '', 'ok');
    $('resultado').classList.remove('oculto');
    $('r-ms').textContent = `${fmt(r.ms, r.ms < 10 ? 2 : 1)} ms`;
    $('r-indices').innerHTML = r.indices_usados.length
      ? r.indices_usados.map((i) => `<span class="chip">${esc(i)}</span>`).join('')
      : '<span class="chip">ninguno: lectura secuencial</span>';
    $('r-filas').textContent = `${fmt(r.total_filas)} filas${r.total_filas > r.filas.length ? ` · se muestran las primeras ${r.filas.length}` : ''}`;
    $('r-cabeza').innerHTML = `<tr>${r.columnas.map((c) => `<th>${esc(c)}</th>`).join('')}</tr>`;
    $('r-cuerpo').innerHTML = r.filas.map((f) => `<tr>${r.columnas.map((c) =>
      `<td class="num">${typeof f[c] === 'number' ? fmt(f[c], Number.isInteger(f[c]) ? 0 : 2) : esc(f[c])}</td>`).join('')}</tr>`).join('');
    $('r-plan').textContent = r.plan;
  } catch (e) {
    aviso(e.message, 'error');
  } finally {
    ocupado(false);
  }
}

async function comparar() {
  ocupado(true);
  aviso(`Comparando ${actual} en las tres condiciones… crea y borra índices, puede tardar.`);
  try {
    const rpc = $('rpc').checked;
    const r = await api(`/api/consultas/${actual}/comparar?rpc=${rpc}`, { method: 'POST', conBase: true });
    aviso('');
    const max = Math.max(r.sin, r.A, r.B);
    $('comparacion').classList.remove('oculto');
    $('comp-barras').innerHTML = ['sin', 'A', 'B'].map((c) => {
      const mejora = c === 'sin' ? '' : ` · ${fmt(r.sin / r[c], 1)}×`;
      return `<div class="item"><span>${NOMBRES[c]}</span>
        <div class="pista"><div class="relleno" style="width: ${Math.max(1, r[c] / max * 100).toFixed(1)}%"></div></div>
        <span class="num" style="text-align: right">${fmt(r[c], r[c] < 10 ? 2 : 1)} ms${mejora}</span></div>`;
    }).join('');
  } catch (e) {
    aviso(e.message, 'error');
  } finally {
    ocupado(false);
  }
}

async function iniciarLab() {
  consultas = await api('/api/consultas');
  $('lista').innerHTML = consultas.map((q) =>
    `<button type="button" class="consulta-item" data-id="${q.id}"><strong>${q.id}</strong>${esc(q.titulo)}</button>`).join('');
  document.querySelectorAll('.consulta-item').forEach((b) => b.addEventListener('click', () => {
    actual = b.dataset.id;
    $('resultado').classList.add('oculto');
    $('comparacion').classList.add('oculto');
    aviso('');
    mostrarConsulta();
  }));
  actual = 'C1';
  mostrarConsulta();
}

document.querySelectorAll('#condiciones button').forEach((b) =>
  b.addEventListener('click', () => { condicion = b.dataset.c; mostrarPlan(); }));
document.querySelectorAll('.pestanas button').forEach((b) => b.addEventListener('click', () => {
  document.querySelectorAll('.pestanas button').forEach((x) => x.classList.toggle('activo', x === b));
  $('p-tabla').classList.toggle('oculto', b.dataset.p !== 'tabla');
  $('p-plan').classList.toggle('oculto', b.dataset.p !== 'plan');
}));
$('ejecutar').addEventListener('click', ejecutar);
$('comparar').addEventListener('click', comparar);

iniciarLab();
SkyNest.iniciar('laboratorio', () => {
  $('resultado').classList.add('oculto');
  $('comparacion').classList.add('oculto');
  aviso('');
});
