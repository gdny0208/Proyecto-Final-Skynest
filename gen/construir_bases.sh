#!/bin/bash
# =====================================================================
# SkyNest · gen/construir_bases.sh
# Construye las bases del experimento y sus dumps (sección 4.2 / anexos).
#
# Por cada escala:
#   1. borra y crea la base skynest_<escala>
#   2. ejecuta sql/01_schema.sql y sql/02_datos_reales.sql
#   3. genera y carga los datos con gen/generar.py
#   4. ejecuta los scripts sql/03_*.sql a sql/06_*.sql que existan
#      (triggers, procedimientos, vistas, roles) DESPUÉS de cargar
#   5. verifica las reglas con gen/verificar.sql
#   6. guarda el dump en dumps/skynest_<escala>.dump
#
# Uso (desde la carpeta del proyecto):
#   bash gen/construir_bases.sh              # las 4 escalas
#   bash gen/construir_bases.sh 1k 10k       # solo algunas
#
# Antes: cerrar las conexiones a esas bases en pgAdmin / VS Code
# (si no, dropdb falla porque la base está en uso).
# =====================================================================
set -e
cd "$(dirname "$0")/.."

PY="${PY:-.venv/bin/python}"
ESCALAS="${*:-1k 10k 100k 1m}"
export PGOPTIONS='-c client_min_messages=warning'
mkdir -p dumps

for e in $ESCALAS; do
  case "$e" in
    1k)   N=1000 ;;
    10k)  N=10000 ;;
    100k) N=100000 ;;
    1m)   N=1000000 ;;
    *) echo "Escala desconocida: $e (usa 1k, 10k, 100k o 1m)"; exit 1 ;;
  esac
  DB="skynest_$e"
  echo "=================== $DB (N = $N vuelos) ==================="
  dropdb --if-exists "$DB"
  createdb "$DB"
  psql -q -d "$DB" -f sql/01_schema.sql > /dev/null
  psql -q -d "$DB" -f sql/02_datos_reales.sql > /dev/null
  "$PY" gen/generar.py --db "$DB" --n "$N"
  for f in sql/0[3-6]_*.sql; do
    [ -e "$f" ] || continue
    case "$f" in *_prueba.sql) continue ;; esac
    echo "  ejecutando $f"
    psql -q -d "$DB" -f "$f" > /dev/null
  done
  psql -d "$DB" -f gen/verificar.sql
  pg_dump -Fc -d "$DB" -f "dumps/$DB.dump"
  echo "  dump: dumps/$DB.dump ($(du -h "dumps/$DB.dump" | cut -f1))"
done

echo "Listo. Para restaurar un dump en otra máquina:"
echo "  createdb skynest_1m && pg_restore -d skynest_1m dumps/skynest_1m.dump"
