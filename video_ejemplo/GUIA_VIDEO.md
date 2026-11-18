# Guía para grabar los 5 videos del anexo (Hito 2)

**Qué se pide.** El enunciado (sección 7, Anexos): *"Debe anexar un vídeo de la experimentación con 1 millón
de registros con y sin índices"*. El profesor confirmó por Discord (18/11/2026) que son **5 videos, uno por
consulta, cada uno con y sin índice**. No hace falta voz: cada script trae comentarios que se leen en pantalla
y dicen qué mirar en cada resultado.

| Video | Script | Consulta | Índice que se muestra | Sin → con (informe) |
|---|---|---|---|---|
| 1 | `demo_c1.sql` | C1 · Tasa de entregas por nest y distrito | Cubrientes (plan B) | 110 → 27 ms |
| 2 | `demo_c2.sql` | C2 · Consumo de batería por km | Compuesto ruta + fecha (plan A) | 46 → 21 ms |
| 3 | `demo_c3.sql` | C3 · Baterías sobre 60 °C | Parcial (plan B) | 127 → 3 ms |
| 4 | `demo_c4.sql` | C4 · Uso de la flota | B+ en la fecha (plan A) | 43 → 15 ms |
| 5 | `demo_c5.sql` | C5 · Express con retraso | Compuesto y cubriente (plan B) + `random_page_cost = 1.1` | 113 → 41 → 20 ms |

En cada video se muestra el índice que más mejoró esa consulta (el "con índice" de la rúbrica). Los planes
A y B completos están en el informe (sección 5.3 y anexo 7.3).

Cada video dura **1,5 a 2 minutos**.

---

## 0. Antes de grabar (una sola vez)

1. **La base de 1M debe tener los esquemas** `skynest` y `reportes` (reconstruida el 18/11). Comprobar en una terminal:
   ```bash
   psql -d skynest_1m -c "\dn"
   ```
2. **Cerrar lo que no se use** (Chrome con muchas pestañas, Docker, Zoom). Con 8 GB de RAM, otras apps hacen que los
   tiempos salgan más altos.
3. **No correr la web ni `bench/experimento.py` mientras se graba**: el Laboratorio de la web crea y borra índices.
4. **Abrir pgAdmin 4** → servidor local → `skynest_1m` → **Tools → Query Tool**.
5. **Tamaño de letra legible:** en pgAdmin, *File → Preferences → Miscellaneous → Themes / Query Tool → Font size*,
   16 o más. Panel de resultados (**Data Output**) visible y amplio.
6. **Ensayo opcional:** correr una vez el bloque 3 de cada script antes de grabar, para que los datos queden en
   memoria y la primera ejecución no salga lenta.

> **Sobre los tiempos:** no tienen que coincidir con el informe; dependen de la caché y de qué más esté abierto.
> Lo que debe verse es el **cambio de plan** (de *Seq Scan* a un *Index Scan*) y que el tiempo baja.

---

## 1. Cómo grabar cada video (igual para los 5)

1. En el Query Tool: ícono de carpeta (**Open File**) → `video_ejemplo/demo_cN.sql`.
2. Iniciar la grabación de pantalla (`Cmd + Shift + 5` → **Grabar toda la pantalla** o la ventana de pgAdmin → **Grabar**).
3. Ejecutar **un bloque a la vez**, en orden: seleccionar desde el comentario `-- N.` hasta su último `;` y pulsar **F5**.
   Después de cada bloque, **esperar 2–3 segundos** para que se lea el resultado.
4. En los bloques con `EXPLAIN`, el plan sale en **Data Output** como texto: hacer scroll despacio hasta ver la
   línea que el comentario pide mirar, y luego hasta la última fila (`Execution Time`).
5. Al terminar el último bloque (borra el índice), detener la grabación (botón ⏹ de la barra de menú).
6. Guardar el archivo como `video_C1_skynest_1m.mov` (… `C5`).

### Qué bloques tiene cada script

| Bloque | Qué hace | Qué debe verse |
|---|---|---|
| 0 | Prepara: esquema `skynest` y borra índices del experimento que hayan quedado | `DO` sin error |
| 1 | La pregunta (en el comentario) y cuántas filas tienen sus tablas | p. ej. 4 851 512 lecturas en C3 |
| 2 | Índices actuales: solo los de las llaves | ningún `ix_c…` |
| 3 | **SIN ÍNDICE**: `EXPLAIN (ANALYZE, BUFFERS)` | `Seq Scan` y el `Execution Time` |
| 4 | Crea el índice, actualiza estadísticas y muestra cuánto ocupa | nombre y tamaño del índice |
| 5 | **CON ÍNDICE**: la misma consulta | `Index Scan` / `Bitmap Index Scan` / `Index Only Scan` y un tiempo menor |
| 6 | (solo C5) con `random_page_cost = 1.1` | `Index Scan using pk_vuelo`, tiempo aún menor |
| 6 o 7 | Misma cantidad de filas con o sin índice | el índice no cambia la respuesta (C3: 466) |
| 7 u 8 | Borra el índice | la base queda como al inicio |

---

## 2. Subir los videos y ponerlos en el informe

1. Subir los 5 a YouTube (**no listado**) o a Google Drive (**cualquiera con el enlace puede ver**).
2. Pegar cada enlace en `informe/hito2_secciones.tex`, sección *Video de la experimentación*, en lugar de
   `PEGAR-ENLACE-C1` … `PEGAR-ENLACE-C5`.
3. Recompilar el informe (o pedirlo en el chat del proyecto) y subir los cambios a GitHub.
