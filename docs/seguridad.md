# Seguridad: reglas que no se doblan

Este documento fija clases de error que LapageriaOS no va a repetir.
No describe una función que ya arranque: describe cómo hay que
diseñar autenticación, login y cualquier chequeo que decida «sí» o «no».

La chispa es [sshhole](https://sshhole.com/) (2026): en OpenSSH sobre
musl, sin PAM, una cuenta «bloqueada» con `*` en el campo de clave
aceptaba cualquier clave de más de 256 bytes. `crypt()` al fallar
devolvía `"*"`, el mismo centinela que significa «esta cuenta no entra
con clave». OpenSSH, para no filtrar usuarios por tiempo, hasheaba
igual con la sal de otra cuenta. El fallo y el bloqueo coincidían: la
comparación decía que sí.

Dos arreglos «correctos» por separado (no devolver `NULL`; igualar
tiempos) y un centinela reciclado. Eso no es un fallo raro de
criptografía: es un fallo de programación. No lo vamos a copiar.

## Reglas

1. **Un valor centinela no significa dos cosas.**
   El marcador de «cuenta sin clave / nadie entra» no puede ser el
   mismo valor que «la función de hash falló» o «entrada inválida».
   Si hace falta un resultado de error, es un código o un camino
   distinto, con un nombre distinto.

2. **Un fallo no es una denegación.**
   Si un hash o una comparación no se pueden completar (clave
   demasiado larga, algoritmo ausente, memoria, entrada podrida), el
   resultado es un error. No se traduce a «clave incorrecta» ni se
   compara contra el valor guardado.

3. **Quien no debe tener clave no pasa por verificación de clave.**
   Una cuenta solo-llave, un servicio o root bloqueado no ejecutan el
   camino que compara una clave. No hay «hashear igual para tardar lo
   mismo» reutilizando la sal o el secreto de otra cuenta: ese atajo
   fue parte del agujero.

4. **Error, denegación y «no existe» son tres resultados.**
   Se distinguen y se prueban por separado. Igualar tiempos, si hace
   falta, no se logra haciendo que un caso tome prestado el secreto
   de otro.

5. **Se prueban los bordes, no solo el camino feliz.**
   Toda autenticación o autorización nueva trae pruebas de: clave
   vacía, cuenta bloqueada, clave enorme, usuario que no existe, valor
   centinela en el almacén, fallo de la función de hash, y el cruce de
   esos casos. Si no está probado, no está hecho.

6. **Por defecto, sin autenticación por clave.**
   El acceso remoto no arranca pidiendo una clave. Si más adelante hay
   clave, queda apagada hasta que alguien la encienda a propósito, con
   las reglas de arriba.

## Qué no es este documento

No reemplaza [nx.md](nx.md), [zonas.md](zonas.md) ni
[higher-half.md](higher-half.md). Esos cubren memoria, W^X y
aislamiento. Este cubre la lógica de decisión: centinelas, errores y
comparaciones que no pueden convertirse en un «sí» por accidente.
