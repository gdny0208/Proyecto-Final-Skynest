-- =====================================================================
-- SkyNest · 06_roles.sql  (tipos de usuario, sección 1.5.3 del Hito 1)
--
-- Un rol de grupo (NOLOGIN) por tipo de usuario. Principio de mínimo
-- privilegio: las escrituras de negocio se hacen SOLO a través de los
-- procedimientos almacenados, que se ejecutan con los permisos de su
-- dueño (SECURITY DEFINER). Así un despachador puede programar vuelos sin
-- tener permiso de UPDATE directo sobre drone o bateria.
--
--   rol_administrador  control total
--   rol_despachador    programa vuelos, registra y asigna paquetes, cancela
--   rol_operador       ve sus vuelos y la telemetría; despega y cierra vuelos
--   rol_cliente        registra paquetes y rastrea por código de tracking
--   rol_tecnico        ve telemetría e historial; actualiza salud/estado de baterías y drones
--   rol_analista       solo lectura de las vistas de reportes
--   rol_telemetria     solo inserta lecturas de telemetría
--
-- Los roles son del servidor (no de una base): se crean una vez y los
-- GRANT se repiten en cada base. Para crear un usuario real:
--   CREATE USER ana_analista WITH PASSWORD '...' IN ROLE rol_analista;
--
-- Requiere: 01 a 05.        Uso: psql -d skynest_1k -f sql/06_roles.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = skynest, reportes, public;
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Crear los roles si no existen
-- ---------------------------------------------------------------------
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['rol_administrador', 'rol_despachador', 'rol_operador', 'rol_cliente',
                             'rol_tecnico', 'rol_analista', 'rol_telemetria'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 2. Punto de partida: nadie (PUBLIC) crea objetos ni ejecuta funciones
-- ---------------------------------------------------------------------
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA skynest, reportes FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA skynest, reportes FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA skynest FROM PUBLIC;

-- USAGE = poder "entrar" al esquema (ver los nombres); los permisos de cada
-- tabla o vista se dan aparte. El analista NO entra a skynest: solo ve reportes.
GRANT USAGE ON SCHEMA skynest  TO rol_administrador, rol_despachador, rol_operador, rol_cliente,
                                  rol_tecnico, rol_telemetria;
GRANT USAGE ON SCHEMA reportes TO rol_administrador, rol_despachador, rol_operador, rol_cliente,
                                  rol_tecnico, rol_analista;

-- Los procedimientos de negocio corren con los permisos de su dueño
ALTER PROCEDURE sp_registrar_cliente_persona(VARCHAR, VARCHAR, CHAR, VARCHAR, VARCHAR, INTEGER) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;
ALTER PROCEDURE sp_registrar_cliente_empresa(VARCHAR, VARCHAR, CHAR, VARCHAR, VARCHAR, INTEGER) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;
ALTER PROCEDURE sp_registrar_paquete(INTEGER, CHAR, NUMERIC, NUMERIC, NUMERIC, NUMERIC, VARCHAR, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, NUMERIC, NUMERIC, CHAR) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;
ALTER PROCEDURE sp_programar_vuelo(INTEGER, TIMESTAMP, VARCHAR, INTEGER) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;
ALTER PROCEDURE sp_asignar_paquete(CHAR, INTEGER) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;
ALTER PROCEDURE sp_despegar_vuelo(INTEGER, TIMESTAMP) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;
ALTER PROCEDURE sp_cerrar_vuelo(INTEGER, NUMERIC, BOOLEAN, TIMESTAMP) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;
ALTER PROCEDURE sp_cancelar_vuelo(INTEGER) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;
ALTER PROCEDURE sp_registrar_lectura(INTEGER, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TIMESTAMP) SECURITY DEFINER SET search_path = skynest, reportes, pg_temp;

-- ---------------------------------------------------------------------
-- 3. Permisos por rol
-- ---------------------------------------------------------------------
-- Administrador: todo
GRANT ALL ON ALL TABLES IN SCHEMA skynest, reportes TO rol_administrador;
GRANT ALL ON ALL SEQUENCES IN SCHEMA skynest TO rol_administrador;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA skynest, reportes TO rol_administrador;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA skynest TO rol_administrador;

-- Despachador: lee la operación y la programa mediante procedimientos
GRANT SELECT ON distrito, estacion_nest, modelo_drone, drone, bateria, operador, autorizacion,
                ruta_vuelo, punto_ruta, permiso_vuelo, vuelo, paquete, cliente,
                v_seguimiento_paquete, v_peso_vuelo TO rol_despachador;
GRANT EXECUTE ON PROCEDURE sp_registrar_paquete, sp_programar_vuelo, sp_asignar_paquete,
                           sp_cancelar_vuelo TO rol_despachador;

-- Operador (piloto): ve vuelos, rutas y telemetría; despega, cierra o aborta
GRANT SELECT ON vuelo, ruta_vuelo, punto_ruta, drone, telemetria_bateria, distrito,
                v_peso_vuelo, v_alertas_temperatura TO rol_operador;
GRANT EXECUTE ON PROCEDURE sp_despegar_vuelo, sp_cerrar_vuelo, sp_cancelar_vuelo TO rol_operador;

-- Cliente: registra paquetes y rastrea por código (no ve la tabla paquete)
GRANT EXECUTE ON PROCEDURE sp_registrar_paquete TO rol_cliente;
GRANT EXECUTE ON FUNCTION fn_rastrear_paquete(CHAR) TO rol_cliente;

-- Técnico de mantenimiento: lee telemetría e historial; actualiza solo salud y estado
GRANT SELECT ON bateria, drone, modelo_drone, vuelo, telemetria_bateria,
                v_historial_bateria, v_alertas_temperatura, v_utilizacion_flota TO rol_tecnico;
GRANT UPDATE (salud_pct, estado, ciclos_carga) ON bateria TO rol_tecnico;
GRANT UPDATE (estado, horas_vuelo) ON drone TO rol_tecnico;

-- Analista: solo las vistas de reportes
GRANT SELECT ON v_entregas_nest_distrito, v_retrasos_express, v_consumo_modelo_ruta,
                v_utilizacion_flota, v_alertas_temperatura, v_peso_vuelo,
                v_historial_bateria, v_licencias_por_vencer TO rol_analista;

-- Sistema de telemetría: solo inserta lecturas (inserción directa, la más rápida).
-- El trigger R17 lee el horario del vuelo, por eso necesita esas 3 columnas.
GRANT INSERT ON telemetria_bateria TO rol_telemetria;
GRANT SELECT (id_vuelo, despegue, aterrizaje) ON vuelo TO rol_telemetria;
GRANT EXECUTE ON PROCEDURE sp_registrar_lectura TO rol_telemetria;

COMMIT;

-- Resumen: privilegios de tabla por rol
SELECT grantee AS rol, string_agg(DISTINCT privilege_type, ', ') AS privilegios, count(DISTINCT table_name) AS objetos
FROM information_schema.role_table_grants
WHERE grantee LIKE 'rol_%'
GROUP BY grantee ORDER BY grantee;
