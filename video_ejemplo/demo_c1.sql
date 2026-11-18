-- =====================================================================
-- SkyNest · Video 1 de 5 · Consulta 1: Tasa de entregas exitosas por nest y distrito
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
-- 1. La pregunta: En marzo de 2026, ¿qué porcentaje de paquetes se entregó y cuánto demoró, por nest de salida y distrito de destino?
--    Tablas que usa y cuántas filas tienen
-- ---------------------------------------------------------------------
SELECT 'vuelo' AS tabla, count(*) AS filas FROM vuelo
UNION ALL
SELECT 'paquete' AS tabla, count(*) AS filas FROM paquete;

-- ---------------------------------------------------------------------
-- 2. Punto de partida: solo los índices de las llaves (PRIMARY KEY y UNIQUE)
-- ---------------------------------------------------------------------
SELECT tablename AS tabla, indexname AS indice
FROM pg_indexes
WHERE schemaname = 'skynest' AND tablename IN ('paquete', 'vuelo')
ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- 3. SIN ÍNDICE. Mirar: "Parallel Seq Scan on paquete" y "Parallel Seq Scan on vuelo": lee las dos tablas completas.
--    En la última fila, "Execution Time" (en el informe: unos 110 ms).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT n.nombre                                         AS nest_origen,
       d.nombre                                         AS distrito_destino,
       count(*)                                         AS paquetes,
       count(*) FILTER (WHERE p.estado = 'entregado')   AS entregados,
       round(100.0 * count(*) FILTER (WHERE p.estado = 'entregado') / count(*), 1) AS tasa_exito_pct,
       round(avg(EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60)::numeric, 1) AS min_prom_entrega
FROM vuelo v
JOIN paquete p        ON p.id_vuelo = v.id_vuelo
JOIN ruta_vuelo r     ON r.id_ruta  = v.id_ruta
JOIN estacion_nest n  ON n.id_nest  = r.id_nest_origen
JOIN distrito d       ON d.ubigeo   = r.ubigeo_destino
WHERE v.despegue >= '2026-03-01' AND v.despegue < '2026-04-01'
GROUP BY n.nombre, d.nombre
ORDER BY tasa_exito_pct, paquetes DESC;

-- ---------------------------------------------------------------------
-- 4. CREAR EL ÍNDICE: índices CUBRIENTES (INCLUDE).
--    Después se actualizan las estadísticas (ANALYZE) y se muestra cuánto ocupa
-- ---------------------------------------------------------------------
CREATE INDEX ix_c1b_vuelo_despegue_cov ON vuelo (despegue) INCLUDE (id_ruta);
CREATE INDEX ix_c1b_paquete_vuelo_cov  ON paquete (id_vuelo) INCLUDE (estado, fecha_entrega);
ANALYZE paquete;
ANALYZE vuelo;
SELECT indexname AS indice, pg_size_pretty(pg_relation_size(('skynest.' || indexname)::regclass)) AS tamano
FROM pg_indexes
WHERE schemaname = 'skynest' AND indexname IN ('ix_c1b_vuelo_despegue_cov', 'ix_c1b_paquete_vuelo_cov');

-- ---------------------------------------------------------------------
-- 5. CON ÍNDICE. Es la MISMA consulta. Mirar: "Index Only Scan using ix_c1b_paquete_vuelo_cov": responde con el índice, sin leer la tabla paquete.
--    "Execution Time" mucho menor (en el informe: unos 27 ms, 4 veces más rápido).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT n.nombre                                         AS nest_origen,
       d.nombre                                         AS distrito_destino,
       count(*)                                         AS paquetes,
       count(*) FILTER (WHERE p.estado = 'entregado')   AS entregados,
       round(100.0 * count(*) FILTER (WHERE p.estado = 'entregado') / count(*), 1) AS tasa_exito_pct,
       round(avg(EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60)::numeric, 1) AS min_prom_entrega
FROM vuelo v
JOIN paquete p        ON p.id_vuelo = v.id_vuelo
JOIN ruta_vuelo r     ON r.id_ruta  = v.id_ruta
JOIN estacion_nest n  ON n.id_nest  = r.id_nest_origen
JOIN distrito d       ON d.ubigeo   = r.ubigeo_destino
WHERE v.despegue >= '2026-03-01' AND v.despegue < '2026-04-01'
GROUP BY n.nombre, d.nombre
ORDER BY tasa_exito_pct, paquetes DESC;

-- ---------------------------------------------------------------------
-- 6. El índice no cambia la respuesta, solo el tiempo: mismas filas con o sin índice
-- ---------------------------------------------------------------------
SELECT count(*) AS filas_del_resultado FROM (
SELECT n.nombre                                         AS nest_origen,
       d.nombre                                         AS distrito_destino,
       count(*)                                         AS paquetes,
       count(*) FILTER (WHERE p.estado = 'entregado')   AS entregados,
       round(100.0 * count(*) FILTER (WHERE p.estado = 'entregado') / count(*), 1) AS tasa_exito_pct,
       round(avg(EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60)::numeric, 1) AS min_prom_entrega
FROM vuelo v
JOIN paquete p        ON p.id_vuelo = v.id_vuelo
JOIN ruta_vuelo r     ON r.id_ruta  = v.id_ruta
JOIN estacion_nest n  ON n.id_nest  = r.id_nest_origen
JOIN distrito d       ON d.ubigeo   = r.ubigeo_destino
WHERE v.despegue >= '2026-03-01' AND v.despegue < '2026-04-01'
GROUP BY n.nombre, d.nombre
ORDER BY tasa_exito_pct, paquetes DESC
) AS r;

-- ---------------------------------------------------------------------
-- 7. Dejar la base como estaba: borrar el índice del video
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS ix_c1b_vuelo_despegue_cov;
DROP INDEX IF EXISTS ix_c1b_paquete_vuelo_cov;
ANALYZE paquete;
ANALYZE vuelo;
