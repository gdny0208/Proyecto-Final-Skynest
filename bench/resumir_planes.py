"""
SkyNest · bench/resumir_planes.py
Resume los planes de ejecución (EXPLAIN ANALYZE) para el cuerpo del informe.

De cada plan completo de informe/resultados/planes/ conserva solo:
  - los nodos del árbol (Seq Scan, Index Scan, Hash Join, Sort, ...) con las filas reales,
  - las líneas "Rows Removed by Filter" (cuánto se leyó para nada),
  - el tiempo de ejecución.
Quita costos estimados, buffers, memoria y condiciones, que no cambian la lectura.
Los planes completos quedan en los anexos.

Uso:  python bench/resumir_planes.py   (escribe informe/resultados/planes_resumen/)
"""
import os
import re
import sys

BASE = os.path.join(os.path.dirname(__file__), '..', 'informe', 'resultados')

NODO = re.compile(r'^(\s*(?:->\s+)?)([A-Z][A-Za-z ]+?(?: (?:on|using) [\w.]+)*(?: \w+)?)\s+\(cost=[^)]*\)\s+\(actual [^)]*?rows=(\d+) loops=(\d+)\)')
QUITADAS = re.compile(r'^(\s*)Rows Removed by (Filter|Index Recheck|Join Filter): (\d+)')


def miles(n):
    return f'{int(n):,}'.replace(',', ' ')


def resumir(texto):
    out = []
    for linea in texto.splitlines():
        m = NODO.match(linea)
        if m:
            sangria, nodo, filas, loops = m.groups()
            extra = f' ×{miles(loops)}' if loops != '1' else ''
            unidad = 'fila' if filas == '1' else 'filas'
            out.append(f'{sangria}{nodo}   [{miles(filas)} {unidad}{extra}]')
            continue
        m = QUITADAS.match(linea)
        if m:
            sangria, _, n = m.groups()
            out.append(f'{sangria}(descarta {miles(n)} filas)')
            continue
        if linea.startswith('Execution Time'):
            ms = float(linea.split(':')[1].split()[0])
            out.append(f'Tiempo de ejecución: {ms:.1f} ms'.replace('.', ','))
    # sangría a la mitad para que el árbol entre en el ancho de página
    def compacta(l):
        n = len(l) - len(l.lstrip())
        return ' ' * (n // 2) + l.lstrip().replace('->  ', '-> ')
    return '\n'.join(compacta(l) for l in out) + '\n'


def main(base=BASE):
    origen = os.path.join(base, 'planes')
    destino = os.path.join(base, 'planes_resumen')
    if not os.path.isdir(origen):
        sys.exit(f'No existe {origen}: primero ejecutar bench/experimento.py')
    os.makedirs(destino, exist_ok=True)
    n = 0
    for nombre in sorted(os.listdir(origen)):
        if nombre.endswith('.txt'):
            with open(os.path.join(origen, nombre), encoding='utf-8') as f:
                texto = f.read()
            with open(os.path.join(destino, nombre), 'w', encoding='utf-8') as f:
                f.write(resumir(texto))
            n += 1
    print(f'{n} planes resumidos en {os.path.normpath(destino)}')


if __name__ == '__main__':
    main()
