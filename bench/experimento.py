#!/usr/bin/env python3
"""
SkyNest · bench/experimento.py — experimento de optimización (sección 5 del informe)

Qué mide, en cada base (skynest_1k, _10k, _100k, _1m):

  1. CONSULTAS (5.5 / 5.6): las 5 consultas de sql/07_consultas.sql en tres
     condiciones:
        sin  -> solo los índices automáticos (PK, UNIQUE, EXCLUDE)
        A    -> + los índices del plan A de esa consulta (sql/08_indices.sql)
        B    -> + los índices del plan B de esa consulta
     y además B con random_page_cost = 1.1 (ajuste del planificador para SSD).
     Cada plan se crea solo, se mide y se borra, así no se mezclan.
     Por condición: 1 corrida de calentamiento (descartada) + 5 corridas.
     Tiempo = "Execution Time" de EXPLAIN (ANALYZE, TIMING OFF): tiempo de
     ejecución en el servidor, sin la red ni el cliente. Se guarda además el
     plan completo (EXPLAIN ANALYZE, BUFFERS) para las figuras del informe.

  2. ACTUALIZACIONES (costo de mantener índices): tiempo de
        - insertar 10 000 lecturas de telemetría (10 por vuelo en 1 000 vuelos)
        - actualizar la fecha de entrega de 1 000 paquetes
     sin índices extra y con distintos tipos de índice (B+, parcial, BRIN, hash,
     todos). Cada operación se ejecuta dentro de una transacción y se deshace
     (ROLLBACK), así la base no cambia entre corridas.

Uso (desde la carpeta del proyecto, con las bases ya construidas):
    .venv/bin/python bench/experimento.py                     # las 4 escalas
    .venv/bin/python bench/experimento.py --escalas 1k 10k    # algunas
    .venv/bin/python bench/experimento.py --solo-graficos     # rehace gráficos y tablas

Salida en informe/resultados/ (el informe LaTeX la lee desde ahí):
    tiempos_consultas.csv, resumen_consultas.csv, indices.csv,
    tiempos_actualizacion.csv, resumen_actualizacion.csv, plataforma.txt,
    planes/<escala>_<consulta>_<condicion>.txt,
    graficos/*.png, tablas_latex/*.tex
"""

import argparse
import csv
import os
import platform
import re
import statistics
import subprocess
import sys
import time

import psycopg2

sys.path.insert(0, os.path.dirname(__file__))
import resumir_planes  # noqa: E402

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ESCALAS = {'1k': 1_000, '10k': 10_000, '100k': 100_000, '1m': 1_000_000}
CORRIDAS = 5
FILAS_ACTUALIZACION = 1_000        # paquetes a actualizar
LECTURAS_INSERTAR = 10_000         # lecturas de telemetría a insertar (1 000 vuelos x 10)
CORRIDAS_ACT = 10
TABLAS_GRANDES = ('vuelo', 'paquete', 'telemetria_bateria')


# ----------------------------------------------------------------------
# Lectura de consultas y planes de índices
# ----------------------------------------------------------------------
def leer_consultas():
    txt = open(os.path.join(RAIZ, 'sql', '07_consultas.sql'), encoding='utf-8').read()
    return {m.group(1): m.group(2).strip().rstrip(';')
            for m in re.finditer(r'-- @consulta (C\d)\n(.*?;)', txt, re.S)}


def leer_planes():
    """{('C1','A'): ['CREATE INDEX ...', ...], ...}"""
    txt = open(os.path.join(RAIZ, 'sql', '08_indices.sql'), encoding='utf-8').read()
    planes = {}
    bloques = re.split(r'^-- @plan ', txt, flags=re.M)[1:]
    for b in bloques:
        cab, cuerpo = b.split('\n', 1)
        c, x = cab.split()[:2]
        cuerpo = '\n'.join(l for l in cuerpo.splitlines() if not l.strip().startswith('--'))
        planes[(c, x)] = [s.strip() for s in cuerpo.split(';') if s.strip().upper().startswith('CREATE')]
    return planes


def nombre_indice(stmt):
    return re.search(r'INDEX\s+(?:IF NOT EXISTS\s+)?(\w+)', stmt, re.I).group(1)


def tabla_indice(stmt):
    return re.search(r'\bON\s+(\w+)', stmt, re.I).group(1)


# ----------------------------------------------------------------------
# Utilidades de base de datos
# ----------------------------------------------------------------------
def borrar_indices_extra(cur):
    """Borra todo índice que no respalde una restricción (PK, UNIQUE, EXCLUDE)."""
    cur.execute("""
        SELECT i.indexrelid::regclass::text
        FROM pg_index i
        JOIN pg_class t ON t.oid = i.indrelid
        WHERE t.relnamespace::regnamespace::text IN ('skynest', 'public')  -- public: bases anteriores a los esquemas
          AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)""")
    for (ix,) in cur.fetchall():
        cur.execute(f'DROP INDEX IF EXISTS {ix}')


def analizar(cur):
    for t in TABLAS_GRANDES:
        cur.execute(f'ANALYZE {t}')


def crear_indices(cur, stmts):
    """Crea los índices; devuelve (segundos, MB totales)."""
    t0 = time.perf_counter()
    for s in stmts:
        cur.execute(s)
    seg = time.perf_counter() - t0
    analizar(cur)
    mb = 0.0
    for s in stmts:
        cur.execute("SELECT pg_relation_size(%s::regclass)", (nombre_indice(s),))
        mb += cur.fetchone()[0] / 1024 / 1024
    return seg, mb


def borrar_indices(cur, stmts):
    for s in stmts:
        cur.execute(f'DROP INDEX IF EXISTS {nombre_indice(s)}')


def tiempo_ejecucion(cur, sql):
    cur.execute('EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) ' + sql)
    return cur.fetchone()[0][0]['Execution Time']


def medir_consulta(cur, sql):
    tiempo_ejecucion(cur, sql)                         # calentamiento (descartado)
    return [tiempo_ejecucion(cur, sql) for _ in range(CORRIDAS)]


def guardar_plan(cur, sql, ruta):
    cur.execute('EXPLAIN (ANALYZE, BUFFERS) ' + sql)
    with open(ruta, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(r[0] for r in cur.fetchall()) + '\n')


def plataforma(conn):
    cur = conn.cursor()
    cur.execute('SELECT version()')
    lineas = [f'PostgreSQL: {cur.fetchone()[0]}']
    for p in ('shared_buffers', 'work_mem', 'effective_cache_size', 'random_page_cost',
              'max_parallel_workers_per_gather', 'jit'):
        cur.execute(f'SHOW {p}')
        lineas.append(f'{p}: {cur.fetchone()[0]}')
    lineas.append(f'Sistema operativo: {platform.platform()}')
    lineas.append(f'Python: {platform.python_version()}')
    try:
        if platform.system() == 'Darwin':
            cpu = subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip()
            ram = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)) / 2**30
            nucleos = subprocess.check_output(['sysctl', '-n', 'hw.ncpu'], text=True).strip()
        else:
            cpu = next(l.split(':', 1)[1].strip() for l in open('/proc/cpuinfo') if l.startswith('model name'))
            ram = os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') / 2**30
            nucleos = os.cpu_count()
        lineas += [f'CPU: {cpu}', f'Núcleos: {nucleos}', f'RAM: {ram:.0f} GB']
    except Exception as e:  # noqa: BLE001
        lineas.append(f'(no se pudo leer CPU/RAM: {e})')
    return '\n'.join(lineas)


# ----------------------------------------------------------------------
# Experimento 1: consultas
# ----------------------------------------------------------------------
def experimento_consultas(conn, escala, consultas, planes, salida, w_tiempos, w_indices):
    cur = conn.cursor()
    borrar_indices_extra(cur)
    cur.execute('VACUUM ANALYZE')
    for c, sql in consultas.items():
        condiciones = [('sin', [])] + [(x, planes[(c, x)]) for x in ('A', 'B')]
        for cond, stmts in condiciones:
            seg = mb = 0.0
            if stmts:
                seg, mb = crear_indices(cur, stmts)
                w_indices.writerow([escala, c, cond, f'{seg:.3f}', f'{mb:.2f}',
                                    ' | '.join(nombre_indice(s) for s in stmts)])
            tiempos = medir_consulta(cur, sql)
            for i, ms in enumerate(tiempos, 1):
                w_tiempos.writerow([escala, ESCALAS[escala], c, cond, i, f'{ms:.3f}'])
            guardar_plan(cur, sql, os.path.join(salida, 'planes', f'{escala}_{c}_{cond}.txt'))
            if cond == 'B':      # extra: el mismo plan B con random_page_cost para SSD
                cur.execute('SET random_page_cost = 1.1')
                for i, ms in enumerate(medir_consulta(cur, sql), 1):
                    w_tiempos.writerow([escala, ESCALAS[escala], c, 'B_rpc', i, f'{ms:.3f}'])
                guardar_plan(cur, sql, os.path.join(salida, 'planes', f'{escala}_{c}_B_rpc.txt'))
                cur.execute('RESET random_page_cost')
            print(f'  {escala:>4} {c} {cond:<3} media {statistics.mean(tiempos):9.2f} ms'
                  + (f'   (índices: {mb:.1f} MB, creados en {seg:.1f} s)' if stmts else ''))
            borrar_indices(cur, stmts)


# ----------------------------------------------------------------------
# Experimento 2: costo de actualización
# ----------------------------------------------------------------------
def condiciones_actualizacion(planes):
    def de_tabla(t):
        vistos, res = set(), []
        for stmts in planes.values():
            for s in stmts:
                n = nombre_indice(s)
                if tabla_indice(s) == t and n not in vistos:
                    vistos.add(n)
                    res.append(s)
        return res
    return {
        'telemetria_insert': {
            'sql': ("INSERT INTO telemetria_bateria (id_vuelo, marca_tiempo, voltaje_v, corriente_a, temperatura_c, carga_pct) "
                    "SELECT v.id_vuelo, v.despegue + g * interval '100 milliseconds', 44.0, 20.0, 65.0, 90.0 "
                    "FROM (SELECT id_vuelo, despegue FROM vuelo WHERE estado = 'completado' "
                    "      ORDER BY id_vuelo LIMIT %s) v CROSS JOIN generate_series(1, 10) g"),
            'condiciones': {
                'sin': [],
                'btree': planes[('C3', 'A')],
                'parcial': planes[('C3', 'B')],
                'brin': ['CREATE INDEX IF NOT EXISTS ix_upd_tel_brin ON telemetria_bateria USING brin (marca_tiempo)'],
                'todos': de_tabla('telemetria_bateria'),
            }},
        'paquete_update': {
            'sql': ("UPDATE paquete SET fecha_entrega = fecha_entrega + interval '1 second' "
                    "WHERE id_paquete IN (SELECT id_paquete FROM paquete WHERE estado = 'entregado' "
                    "ORDER BY id_paquete LIMIT %s)"),
            'condiciones': {
                'sin': [],
                'btree': planes[('C5', 'A')],
                'compuesto': planes[('C5', 'B')],
                'hash': ['CREATE INDEX IF NOT EXISTS ix_upd_paq_hash ON paquete USING hash (id_vuelo)'],
                'todos': de_tabla('paquete'),
            }},
    }


def experimento_actualizacion(conn, escala, planes, w):
    cur = conn.cursor()
    borrar_indices_extra(cur)
    for op, d in condiciones_actualizacion(planes).items():
        for cond, stmts in d['condiciones'].items():
            crear_indices(cur, stmts)
            tiempos = []
            for i in range(CORRIDAS_ACT + 1):
                cur.execute('BEGIN')
                t0 = time.perf_counter()
                cur.execute(d['sql'], (LECTURAS_INSERTAR // 10 if op.startswith('tel') else FILAS_ACTUALIZACION,))
                ms = (time.perf_counter() - t0) * 1000
                cur.execute('ROLLBACK')
                if i > 0:                                  # la primera es calentamiento
                    tiempos.append(ms)
                    w.writerow([escala, ESCALAS[escala], op, cond, i, f'{ms:.3f}'])
            print(f'  {escala:>4} {op:<18} {cond:<9} media {statistics.mean(tiempos):9.2f} ms')
            borrar_indices(cur, stmts)
            cur.execute(f"VACUUM {'telemetria_bateria' if op.startswith('tel') else 'paquete'}")


# ----------------------------------------------------------------------
# Resúmenes, tablas LaTeX y gráficos
# ----------------------------------------------------------------------
ORDEN_ESC = list(ESCALAS)
ETQ_ESC = {'1k': '1 000', '10k': '10 000', '100k': '100 000', '1m': '1 000 000'}


def resumir(ruta_in, ruta_out, clave):
    """clave = columnas de agrupación (sin 'corrida' ni 'ms')."""
    grupos = {}
    with open(ruta_in, encoding='utf-8') as fh:
        for f in csv.DictReader(fh):
            grupos.setdefault(tuple(f[k] for k in clave), []).append(float(f['ms']))
    filas = []
    for k, v in grupos.items():
        filas.append(dict(zip(clave, k), media_ms=statistics.mean(v),
                          desv_ms=statistics.stdev(v) if len(v) > 1 else 0.0, min_ms=min(v), max_ms=max(v)))
    # mejora respecto de "sin"
    base = {tuple(f[k] for k in clave if k != 'condicion'): f['media_ms'] for f in filas if f['condicion'] == 'sin'}
    for f in filas:
        b = base.get(tuple(f[k] for k in clave if k != 'condicion'))
        f['mejora_x'] = b / f['media_ms'] if b and f['media_ms'] else None
    with open(ruta_out, 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(list(clave) + ['media_ms', 'desv_ms', 'min_ms', 'max_ms', 'mejora_x'])
        for f in sorted(filas, key=lambda f: tuple(ORDEN_ESC.index(f['escala']) if k == 'escala' else f[k] for k in clave)):
            w.writerow([f[k] for k in clave] + [f"{f['media_ms']:.3f}", f"{f['desv_ms']:.3f}", f"{f['min_ms']:.3f}",
                                                 f"{f['max_ms']:.3f}", '' if f['mejora_x'] is None else f"{f['mejora_x']:.2f}"])
    return filas


def num(x):
    """Formato con coma decimal para el informe."""
    return (f'{x:,.2f}' if x < 100 else f'{x:,.0f}').replace(',', ' ').replace('.', ',')


def tablas_latex(filas_q, filas_u, carpeta):
    os.makedirs(carpeta, exist_ok=True)
    esc = [e for e in ORDEN_ESC if any(f['escala'] == e for f in filas_q)]
    idx = {(f['escala'], f['consulta'], f['condicion']): f for f in filas_q}

    def tabla(conds, titulo, etiqueta, archivo):
        col = 'l' + 'l' + 'r' * len(esc)
        out = [r'\begin{table}[H]', r'\centering', r'\small', f'\\caption{{{titulo}}}', f'\\label{{{etiqueta}}}',
               f'\\begin{{tabular}}{{{col}}}', r'\toprule',
               'Consulta & Índices & ' + ' & '.join(ETQ_ESC[e] for e in esc) + r' \\', r'\midrule']
        for c in sorted({f['consulta'] for f in filas_q}):
            for cond in conds:
                celdas = []
                for e in esc:
                    f = idx.get((e, c, cond))
                    celdas.append('--' if not f else f"{num(f['media_ms'])} $\\pm$ {num(f['desv_ms'])}")
                etq = cond.replace('_', r'\_')   # B_rpc -> B\_rpc (el _ rompe LaTeX)
                out.append(f'{c} & {etq} & ' + ' & '.join(celdas) + r' \\')
            out.append(r'\midrule' if c != 'C5' else r'\bottomrule')
        out += [r'\end{tabular}', r'\end{table}']
        open(os.path.join(carpeta, archivo), 'w', encoding='utf-8').write('\n'.join(out) + '\n')

    tabla(['sin'], 'Tiempo de ejecución sin índices (ms, media $\\pm$ desviación de 5 corridas)',
          'tab:sin_indices', 'tabla_sin_indices.tex')
    tabla(['A', 'B', 'B_rpc'], 'Tiempo de ejecución con índices (ms, media $\\pm$ desviación de 5 corridas). '
          'B\\_rpc: plan B con \\texttt{random\\_page\\_cost = 1.1}', 'tab:con_indices', 'tabla_con_indices.tex')

    # mejora en la escala más grande
    e = esc[-1]
    out = [r'\begin{table}[H]', r'\centering', r'\small',
           f'\\caption{{Mejora respecto de la ejecución sin índices, escala de {ETQ_ESC[e]} vuelos}}',
           r'\label{tab:mejora}', r'\begin{tabular}{lrrrr}', r'\toprule',
           r'Consulta & Sin índices (ms) & Plan A & Plan B & Plan B + rpc \\', r'\midrule']
    for c in sorted({f['consulta'] for f in filas_q}):
        s = idx.get((e, c, 'sin'))
        cel = [num(s['media_ms']) if s else '--']
        for cond in ('A', 'B', 'B_rpc'):
            f = idx.get((e, c, cond))
            cel.append('--' if not f or not f['mejora_x'] else f"{f['mejora_x']:.1f}".replace('.', ',') + r'$\times$')
        out.append(f'{c} & ' + ' & '.join(cel) + r' \\')
    out += [r'\bottomrule', r'\end{tabular}', r'\end{table}']
    open(os.path.join(carpeta, 'tabla_mejora.tex'), 'w', encoding='utf-8').write('\n'.join(out) + '\n')

    if filas_u:
        idu = {(f['escala'], f['operacion'], f['condicion']): f for f in filas_u}
        out = [r'\begin{table}[H]', r'\centering', r'\small',
               f'\\caption{{Costo de mantener índices: INSERT de {LECTURAS_INSERTAR} lecturas y UPDATE de {FILAS_ACTUALIZACION} paquetes '
               f'(ms, media de {CORRIDAS_ACT} corridas)}}',
               r'\label{tab:actualizacion}', r'\begin{tabular}{ll' + 'r' * len(esc) + '}', r'\toprule',
               'Operación & Índices & ' + ' & '.join(ETQ_ESC[x] for x in esc) + r' \\', r'\midrule']
        for op, nombre in (('telemetria_insert', 'INSERT telemetría'), ('paquete_update', 'UPDATE paquete')):
            conds = [k for k in ('sin', 'btree', 'parcial', 'brin', 'compuesto', 'hash', 'todos')
                     if any(f['operacion'] == op and f['condicion'] == k for f in filas_u)]
            for k in conds:
                cel = [num(idu[(x, op, k)]['media_ms']) if (x, op, k) in idu else '--' for x in esc]
                out.append(f'{nombre} & {k} & ' + ' & '.join(cel) + r' \\')
            out.append(r'\midrule' if op == 'telemetria_insert' else r'\bottomrule')
        out += [r'\end{tabular}', r'\end{table}']
        open(os.path.join(carpeta, 'tabla_actualizacion.tex'), 'w', encoding='utf-8').write('\n'.join(out) + '\n')


# Paleta categórica validada (orden fijo) + marcador distinto por serie
COLORES = {'sin': '#2a78d6', 'A': '#eb6834', 'B': '#1baf7a', 'B_rpc': '#eda100'}
MARCAS = {'sin': 'o', 'A': 's', 'B': '^', 'B_rpc': 'D'}
NOMBRES = {'sin': 'Sin índices', 'A': 'Plan A', 'B': 'Plan B', 'B_rpc': 'Plan B + random_page_cost 1.1'}


def graficos(filas_q, filas_u, carpeta):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    os.makedirs(carpeta, exist_ok=True)
    plt.rcParams.update({'font.size': 10, 'axes.edgecolor': '#52514e', 'axes.labelcolor': '#0b0b0b',
                         'xtick.color': '#52514e', 'ytick.color': '#52514e', 'axes.spines.top': False,
                         'axes.spines.right': False, 'figure.facecolor': '#fcfcfb', 'axes.facecolor': '#fcfcfb'})
    esc = [e for e in ORDEN_ESC if any(f['escala'] == e for f in filas_q)]
    xs = [ESCALAS[e] for e in esc]
    for c in sorted({f['consulta'] for f in filas_q}):
        fig, ax = plt.subplots(figsize=(6.4, 4.0))
        series = {}
        for cond in ('sin', 'A', 'B', 'B_rpc'):
            ys = [next((f['media_ms'] for f in filas_q if f['escala'] == e and f['consulta'] == c
                        and f['condicion'] == cond), None) for e in esc]
            if None in ys:
                continue
            series[cond] = ys
            ax.plot(xs, ys, color=COLORES[cond], marker=MARCAS[cond], markersize=6, linewidth=2,
                    label=NOMBRES[cond], markeredgecolor='#fcfcfb', markeredgewidth=1)
        # etiquetas directas selectivas: sin índices y el plan más rápido en la escala mayor
        if series:
            mejor = min((k for k in series if k != 'sin'), key=lambda k: series[k][-1], default=None)
            for k in ('sin', mejor):
                if k:
                    ax.annotate(f'{num(series[k][-1])} ms', (xs[-1], series[k][-1]), xytext=(6, 0),
                                textcoords='offset points', va='center', fontsize=8, color='#52514e')
        ax.set_xscale('log')
        ax.set_yscale('log')
        ax.set_xticks(xs)
        ax.set_xticklabels([ETQ_ESC[e] for e in esc])
        ax.set_xlabel('Vuelos en la base (escala logarítmica)')
        ax.set_ylabel('Tiempo de ejecución (ms, escala log.)')
        ax.set_title(f'{c}: tiempo de ejecución por escala', loc='left', fontsize=11, color='#0b0b0b')
        ax.grid(True, which='major', color='#e6e5e0', linewidth=0.8)
        ax.legend(frameon=False, fontsize=8)
        fig.tight_layout()
        fig.savefig(os.path.join(carpeta, f'{c}_tiempos.png'), dpi=200)
        plt.close(fig)

    # Mejora en la escala más grande (barras agrupadas)
    e = esc[-1]
    cons = sorted({f['consulta'] for f in filas_q})
    conds = ('A', 'B', 'B_rpc')
    fig, ax = plt.subplots(figsize=(6.4, 3.8))
    ancho = 0.26
    for j, cond in enumerate(conds):
        vals = [next((f['mejora_x'] or 0 for f in filas_q if f['escala'] == e and f['consulta'] == c
                      and f['condicion'] == cond), 0) for c in cons]
        pos = [i + (j - 1) * (ancho + 0.02) for i in range(len(cons))]
        ax.bar(pos, vals, width=ancho, color=COLORES[cond], label=NOMBRES[cond], edgecolor='#fcfcfb', linewidth=2)
        for p, v in zip(pos, vals):
            ax.text(p, v, f'{v:.1f}×'.replace('.', ','), ha='center', va='bottom', fontsize=7, color='#52514e')
    ax.axhline(1, color='#52514e', linewidth=1, linestyle='--')
    ax.set_xticks(range(len(cons)))
    ax.set_xticklabels(cons)
    ax.set_ylabel('Veces más rápido que sin índices')
    ax.set_title(f'Mejora por plan de índices ({ETQ_ESC[e]} vuelos)', loc='left', fontsize=11, color='#0b0b0b')
    ax.grid(True, axis='y', color='#e6e5e0', linewidth=0.8)
    ax.legend(frameon=False, fontsize=8)
    fig.tight_layout()
    fig.savefig(os.path.join(carpeta, 'mejora_escala_mayor.png'), dpi=200)
    plt.close(fig)

    # Costo de actualización en la escala más grande
    if filas_u:
        fig, axes = plt.subplots(1, 2, figsize=(7.6, 3.4))
        for ax, (op, nombre) in zip(axes, (('telemetria_insert', f'INSERT de {LECTURAS_INSERTAR} lecturas'),
                                           ('paquete_update', f'UPDATE de {FILAS_ACTUALIZACION} paquetes'))):
            fs = [f for f in filas_u if f['escala'] == e and f['operacion'] == op]
            orden = [k for k in ('sin', 'btree', 'parcial', 'brin', 'compuesto', 'hash', 'todos')
                     if any(f['condicion'] == k for f in fs)]
            vals = [next(f['media_ms'] for f in fs if f['condicion'] == k) for k in orden]
            ax.barh(orden, vals, color='#2a78d6', edgecolor='#fcfcfb', linewidth=2, height=0.6)
            for y, v in enumerate(vals):
                ax.text(v, y, ' ' + num(v), va='center', fontsize=7, color='#52514e')
            ax.invert_yaxis()
            ax.set_title(nombre, loc='left', fontsize=10, color='#0b0b0b')
            ax.set_xlabel(f'ms (media de {CORRIDAS_ACT} corridas)')
            ax.grid(True, axis='x', color='#e6e5e0', linewidth=0.8)
        fig.suptitle(f'Costo de mantener índices ({ETQ_ESC[e]} vuelos)', x=0.01, ha='left', fontsize=11)
        fig.tight_layout()
        fig.savefig(os.path.join(carpeta, 'costo_actualizacion.png'), dpi=200)
        plt.close(fig)


def postproceso(salida):
    fq = resumir(os.path.join(salida, 'tiempos_consultas.csv'), os.path.join(salida, 'resumen_consultas.csv'),
                 ('escala', 'consulta', 'condicion'))
    ru = os.path.join(salida, 'tiempos_actualizacion.csv')
    fu = resumir(ru, os.path.join(salida, 'resumen_actualizacion.csv'),
                 ('escala', 'operacion', 'condicion')) if os.path.exists(ru) else []
    tablas_latex(fq, fu, os.path.join(salida, 'tablas_latex'))
    graficos(fq, fu, os.path.join(salida, 'graficos'))
    resumir_planes.main(salida)          # versión corta de los planes para el cuerpo del informe
    print(f'Resúmenes, tablas LaTeX y gráficos en {salida}')


# ----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description='Experimento de índices SkyNest')
    ap.add_argument('--escalas', nargs='+', default=list(ESCALAS), choices=list(ESCALAS))
    ap.add_argument('--host'), ap.add_argument('--port'), ap.add_argument('--user')
    ap.add_argument('--salida', default=os.path.join(RAIZ, 'informe', 'resultados'))
    ap.add_argument('--solo-graficos', action='store_true')
    a = ap.parse_args()

    if a.solo_graficos:
        postproceso(a.salida)
        return

    os.makedirs(os.path.join(a.salida, 'planes'), exist_ok=True)
    consultas, planes = leer_consultas(), leer_planes()
    ft = open(os.path.join(a.salida, 'tiempos_consultas.csv'), 'w', newline='', encoding='utf-8')
    fi = open(os.path.join(a.salida, 'indices.csv'), 'w', newline='', encoding='utf-8')
    fu = open(os.path.join(a.salida, 'tiempos_actualizacion.csv'), 'w', newline='', encoding='utf-8')
    wt, wi, wu = csv.writer(ft), csv.writer(fi), csv.writer(fu)
    wt.writerow(['escala', 'n_vuelos', 'consulta', 'condicion', 'corrida', 'ms'])
    wi.writerow(['escala', 'consulta', 'plan', 'creacion_s', 'tamano_mb', 'indices'])
    wu.writerow(['escala', 'n_vuelos', 'operacion', 'condicion', 'corrida', 'ms'])

    t0 = time.time()
    for i, e in enumerate(a.escalas):
        conn = psycopg2.connect(dbname=f'skynest_{e}', host=a.host, port=a.port, user=a.user,
                                options='-c search_path=skynest,reportes,public')
        conn.autocommit = True
        if i == 0:
            open(os.path.join(a.salida, 'plataforma.txt'), 'w', encoding='utf-8').write(plataforma(conn) + '\n')
        print(f'=== skynest_{e} ===')
        experimento_consultas(conn, e, consultas, planes, a.salida, wt, wi)
        experimento_actualizacion(conn, e, planes, wu)
        borrar_indices_extra(conn.cursor())
        conn.close()
        for fh in (ft, fi, fu):
            fh.flush()
    for fh in (ft, fi, fu):
        fh.close()
    print(f'Experimento terminado en {time.time() - t0:.0f} s')
    postproceso(a.salida)


if __name__ == '__main__':
    main()
