# Publicar FocusApp

Usa macOS con Xcode 26 o posterior, [uv](https://docs.astral.sh/uv/getting-started/installation/) y GitHub CLI autenticado con permisos de escritura en el repositorio.

## Preparar y comprobar el instalador

1. Actualiza `MARKETING_VERSION` y `CURRENT_PROJECT_VERSION` en `FocusApp.xcodeproj/project.pbxproj`. El número de compilación debe aumentar con cada versión.
2. Escribe las notas para la etiqueta en `docs/releases/`.
3. Compila desde la raíz del repo. El procedimiento verifica que la app contiene las dos arquitecturas y que la etiqueta esperada coincide con su versión.

```sh
FOCUSAPP_RELEASE_TAG=v0.1.1 ./scripts/build-dmg.sh
(cd dist && shasum -a 256 -c FocusApp.dmg.sha256)
```

Monta `dist/FocusApp.dmg`. Comprueba que abre el instalador con la app y el enlace a Aplicaciones. Copia la app a una carpeta de prueba, ejecútala y comprueba que aparecen el visor de la barra de menús y Ajustes. Activa y desactiva el desenfoque con otra ventana abierta.

El flujo habitual genera una app con firma ad hoc. Para distribuir con notarización, instala el certificado **Developer ID Application** y su clave privada en el Llavero. Guarda las credenciales de notarización en un perfil de `notarytool` y ejecuta:

```sh
FOCUSAPP_SIGN_IDENTITY='Developer ID Application: NOMBRE (TEAMID)' \
FOCUSAPP_NOTARY_PROFILE='focusapp-notary' \
FOCUSAPP_RELEASE_TAG=v0.1.1 \
  ./scripts/build-dmg.sh --notarize
```

El script firma una copia de la app con Hardened Runtime, firma la imagen, la envía a Apple y adjunta el ticket a la imagen si Apple la acepta. Actualiza el aviso de instalación de ambos README si cambia el tipo de firma de la descarga pública. [Guía de Apple](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

## Publicar en GitHub

Valida que el árbol está limpio y que el commit de la versión ya está en la rama remota. Crea la etiqueta sobre ese commit y súbela antes de publicar:

```sh
git tag -a v0.1.1 -m "FocusApp 0.1.1"
git push origin v0.1.1
gh release create v0.1.1 dist/FocusApp.dmg dist/FocusApp.dmg.sha256 \
  --verify-tag --title "FocusApp 0.1.1" --notes-file docs/releases/v0.1.1.md
```

Comprueba que GitHub muestra ambos archivos y que el enlace `releases/latest/download/FocusApp.dmg` descarga el instalador correcto. Mantén los nombres `FocusApp.dmg` y `FocusApp.dmg.sha256` en las versiones siguientes.

Para probar el actualizador desde una versión anterior que ya lo incluya, abre **Ajustes → Actualizaciones**. Confirma que muestra la versión nueva, descarga el DMG y comprueba que se abre tras verificar el SHA-256 publicado por la API de GitHub. El actualizador lee la última release estable y busca el archivo `FocusApp.dmg` de esa etiqueta.
