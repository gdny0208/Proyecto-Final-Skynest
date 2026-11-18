-- =====================================================================
-- SkyNest · Video 4 de 5 · Consulta 4: Uso de la flota frente al promedio de su modelo
-- Base: skynest_1m (1 000 000 de vuelos), en pgAdmin → Query Tool.
--
-- Cómo usarlo: ejecutar UN BLOQUE A LA VEZ, en orden. Para ejecutar un bloque,
-- seleccionarlo con el mouse (desde su comentario hasta el último ;) y pulsar F5.
-- Los comentarios dicen qué mirar en cada resultado: se leen en pantalla, así el
-- video se entiende sin voz. Al terminar, la base queda igual que al principio.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Preparación: tablas del esquema skynest y sin índices del experimento
-- ---------------------------------------------------------------------
SET search_path = skynest, reportes, public;
DO $$
DECLARE ix text;
BEGIN
    FOR ix IN SELECT indexname FROM pg_indexes WHERE schemaname = 'skynest' AND indexname LIKE 'ix\_c%' LOOP
        EXECUTE format('DROP INDEX skynest.%I', ix);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 1. La pregunta: En septiembre de 2026, ¿cuántos vuelos y horas hizo cada drone y cuánto se aleja del promedio de su modelo?
--    Tablas que usa y cuántas filas tienen
-- ---------------------------------------------------------------------
SELECT 'vuelo' AS tabla, count(*) AS filas FROM vuelo;

-- ---------------------------------------------------------------------
-- 2. Punto de partida: solo los índices de las llaves (PRIMARY KEY y UNIQUE)
-- ---------------------------------------------------------------------
SELECT tablename AS tabla, indexname AS indice
FROM pg_indexes
WHERE schemaname = 'skynest' AND tablename IN ('vuelo')
ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- 3. SIN ÍNDICE. Mirar: "Parallel Seq Scan on vuelo" con "Rows Removed by Filter": recorre el millón de vuelos.
--    En la última fila, "Execution Time" (en el informe: unos 43 ms).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
WITH por_drone AS (
    SELECT v.id_drone,
           count(*) AS vuelos,
           sum(EXTRACT(EPOCH FROM (v.aterrizaje - v.despegue)) / 3600) AS horas
    FROM vuelo v
    WHERE v.estado IN ('completado', 'abortado')
      AND v.despegue >= '2026-09-01' AND v.despegue < '2026-10-01'
    GROUP BY v.id_drone
)
SELECT n.nombre                        AS nest,
       pd.id_drone,
       m.fabricante || ' ' || m.nombre AS modelo,
       pd.vuelos,
       round(pd.horas::numeric, 2)     AS horas,
       round(avg(pd.horas) OVER (PARTITION BY d.id_modelo)::numeric, 2)            AS horas_prom_modelo,
       round((pd.horas - avg(pd.horas) OVER (PARTITION BY d.id_modelo))::numeric, 2) AS diferencia
FROM por_drone pd
JOIN drone d          ON d.id_drone  = pd.id_drone
JOIN modelo_drone m   ON m.id_modelo = d.id_modelo
JOIN estacion_nest n  ON n.id_nest   = d.id_nest_base
ORDER BY diferencia, pd.id_drone;

-- ---------------------------------------------------------------------
-- 4. CREAR EL ÍNDICE: índice B+ en la fecha de despegue.
--    Después se actualizan las estadísticas (ANALYZE) y se muestra cuánto ocupa
-- ---------------------------------------------------------------------
CREATE INDEX ix_c4a_vuelo_despegue ON vuelo (despegue);
ANALYZE vuelo;
SELECT indexname AS indice, pg_size_pretty(pg_relation_size(('skynest.' || indexname)::regclass)) AS tamano
FROM pg_indexes
WHERE schemaname = 'skynest' AND indexname IN ('ix_c4a_vuelo_despegue');

-- ---------------------------------------------------------------------
-- 5. CON ÍNDICE. Es la MISMA consulta. Mirar: "Bitmap Index Scan on ix_c4a_vuelo_despegue": va directo a los vuelos de septiembre.
--    "Execution Time" menor (en el informe: unos 15 ms, 2,9 veces más rápido).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
WITH por_drone AS (
    SELECT v.id_drone,
           count(*) AS vuelos,
           sum(EXTRACT(EPOCH FROM (v.aterrizaje - v.despegue)) / 3600) AS horas
    FROM vuelo v
    WHERE v.estado IN ('completado', 'abortado')
      AND v.despegue >= '2026-09-01' AND v.despegue < '2026-10-01'
    GROUP BY v.id_drone
)
SELECT n.nombre                        AS nest,
       pd.id_drone,
       m.fabricante || ' ' || m.nombre AS modelo,
       pd.vuelos,
       round(pd.horas::numeric, 2)     AS horas,
       round(avg(pd.horas) OVER (PARTITION BY d.id_modelo)::numeric, 2)            AS horas_prom_modelo,
       round((pd.horas - avg(pd.horas) OVER (PARTITION BY d.id_modelo))::numeric, 2) AS diferencia
FROM por_drone pd
JOIN drone d          ON d.id_drone  = pd.id_drone
JOIN modelo_drone m   ON m.id_modelo = d.id_modelo
JOIN estacion_nest n  ON n.id_nest   = d.id_nest_base
ORDER BY diferencia, pd.id_drone;

-- ---------------------------------------------------------------------
-- 6. El índice no cambia la respuesta, solo el tiempo: mismas filas con o sin índice
-- ---------------------------------------------------------------------
SELECT count(*) AS filas_del_resultado FROM (
WITH por_drone AS (
    SELECT v.id_drone,
           count(*) AS vuelos,
           sum(EXTRACT(EPOCH FROM (v.aterrizaje - v.despegue)) / 3600) AS horas
    FROM vuelo v
    WHERE v.estado IN ('completado', 'abortado')
      AND v.despegue >= '2026-09-01' AND v.despegue < '2026-10-01'
    GROUP BY v.id_drone
)
SELECT n.nombre                        AS nest,
       pd.id_drone,
       m.fabricante || ' ' || m.nombre AS modelo,
       pd.vuelos,
       round(pd.horas::numeric, 2)     AS horas,
       round(avg(pd.horas) OVER (PARTITION BY d.id_modelo)::numeric, 2)            AS horas_prom_modelo,
       round((pd.horas - avg(pd.horas) OVER (PARTITION BY d.id_modelo))::numeric, 2) AS diferencia
FROM por_drone pd
JOIN drone d          ON d.id_drone  = pd.id_drone
JOIN modelo_drone m   ON m.id_modelo = d.id_modelo
JOIN estacion_nest n  ON n.id_nest   = d.id_nest_base
ORDER BY diferencia, pd.id_drone
) AS r;

-- ---------------------------------------------------------------------
-- 7. Dejar la base como estaba: borrar el índice del video
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS ix_c4a_vuelo_despegue;
ANALYZE vuelo;
