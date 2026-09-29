#!/usr/bin/env python3
"""Genera la imagen de disco de instalación (DMG) de TranscriptorX.

Produce un DMG con el aspecto habitual de una app de macOS: la aplicación a la
izquierda, el acceso a /Applications a la derecha, una flecha entre ambos y el
texto "arrástrala a Aplicaciones" en el idioma del sistema.

Uso:
    python3 scripts/build_dmg.py --app RUTA/TranscriptorNative.app
    python3 scripts/build_dmg.py --app RUTA/TranscriptorNative.app \
        --output dist/TranscriptorX-2.0.dmg --volname "Transcriptor X"

Solo necesita las herramientas de Xcode (swift) y hdiutil, ambas vienen de serie.

Nota: el estilo de la ventana (fondo, tamaño, posición de iconos) lo escribe el
Finder sobre un disco de lectura-escritura, igual que hacen create-dmg e
install4j. La primera vez macOS pedirá permiso para que esta Terminal controle
Finder: hay que aceptarlo o el DMG saldrá sin adornos.
"""

from __future__ import annotations

import argparse
import plistlib
import shutil
import string
import subprocess
import sys
import tempfile
import time
from pathlib import Path

APP_NAME = "TranscriptorX"
VOLUME_NAME = "TranscriptorX"
WINDOW_ORIGIN = (200, 160)
WINDOW_W, WINDOW_H = 640, 400
ICON_SIZE = 128
TEXT_SIZE = 16

# Posición de cada icono dentro de la ventana (x, y desde la esquina superior).
APP_POS = (150, 150)
APPLICATIONS_POS = (470, 150)

# Idiomas del texto de instalación. "en" es la imagen por defecto y el resto
# van en su .lproj para que macOS elija según el idioma del sistema.
LANGUAGES = ("en", "es")

BACKGROUND_SCRIPT = Path(__file__).with_name("make_background.swift")

APPLESCRIPT = """
on run argv
	set diskName to item 1 of argv
	tell application "Finder"
		tell disk diskName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set bounds of container window to {$originX, $originY, $farX, $farY}
			set opts to icon view options of container window
			set arrangement of opts to not arranged
			set icon size of opts to $icon_size
			set text size of opts to $text_size
			set background picture of opts to file ".background:background.png"
			-- Primero se apartan todos los elementos (incluidos los ocultos,
			-- por si el usuario tiene activada la opción de verlos) y luego se
			-- colocan la app y Aplicaciones en su sitio.
			set position of every item to {$hiddenX, $hiddenY}
			set position of item "$app_name" to {$appX, $appY}
			set position of item "Applications" to {$appsX, $appsY}
			open
			update without registering applications
			delay 2
		end tell
	end tell
end run
"""


def build_background(stage: Path) -> None:
    """Genera .background con la imagen por defecto y las variantes de idioma.

    El dibujo lo hace scripts/make_background.swift, que usa SF Symbols y la
    tipografía del sistema para que la flecha quede nítida y nativa. La carpeta
    lleva punto inicial porque Finder oculta automáticamente los ficheros que
    empiezan por él, igual que create-dmg e install4j.
    """
    background = stage / ".background"
    background.mkdir(parents=True, exist_ok=True)
    for language in LANGUAGES:
        target = background / "background.png"
        if language != LANGUAGES[0]:
            target = background / f"{language}.lproj" / "background.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        command = [
            "swift", str(BACKGROUND_SCRIPT),
            "--output", str(target),
            "--language", language,
            "--width", str(WINDOW_W),
            "--height", str(WINDOW_H),
            "--app-x", str(APP_POS[0]),
            "--app-y", str(APP_POS[1]),
            "--apps-x", str(APPLICATIONS_POS[0]),
            "--apps-y", str(APPLICATIONS_POS[1]),
            "--icon-size", str(ICON_SIZE),
        ]
        # El intérprete de Swift a veces se cae sin motivo; se reintenta.
        for attempt in range(3):
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode == 0:
                break
            if attempt == 2:
                sys.stderr.write(result.stderr)
                raise SystemExit(f"Falló la generación del fondo ({language})")
            time.sleep(2**attempt)


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"Falló: {' '.join(command)}")
    return result


def mounted_volumes() -> list[str]:
    result = subprocess.run(
        ["hdiutil", "info", "-plist"], capture_output=True, text=True
    )
    if result.returncode != 0:
        return []
    volumes = []
    for image in plistlib.loads(result.stdout.encode()).get("images", []):
        for entity in image.get("system-entities", []):
            point = entity.get("mount-point")
            if point:
                volumes.append(point)
    return volumes


def detach(mount: Path, device: str) -> None:
    """Desmonta de forma graceful para que Finder volque el .DS_Store."""
    for attempt in range(3):
        result = subprocess.run(
            ["hdiutil", "detach", str(mount)], capture_output=True, text=True
        )
        if result.returncode == 0:
            return
        time.sleep(2**attempt)
    print("hdiutil detach falló; forzando con diskutil", file=sys.stderr)
    run(["diskutil", "eject", device, "-force"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="Ruta del .app ya compilado")
    parser.add_argument("--output", default=f"dist/{APP_NAME}-2.0.dmg")
    parser.add_argument("--volname", default=VOLUME_NAME)
    args = parser.parse_args()

    app = Path(args.app).resolve()
    if not app.is_dir():
        raise SystemExit(f"No existe la aplicación: {app}")

    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    # Si ya hay un volumen con ese nombre, macOS monta el nuevo como
    # "nombre 1" y el AppleScript acaba dando estilo al volumen equivocado.
    target = f"/Volumes/{args.volname}"
    if target in mounted_volumes():
        raise SystemExit(
            f"Ya está montado {target}. Desmóntalo antes de construir:\n"
            f"    hdiutil detach {target}"
        )

    workdir = Path(tempfile.mkdtemp())
    try:
        stage = workdir / "stage"
        stage.mkdir()
        shutil.copytree(app, stage / app.name, symlinks=True)
        (stage / "Applications").symlink_to("/Applications")
        build_background(stage)

        # Disco de lectura-escritura: hace falta para que Finder pueda escribir
        # el estilo en el volumen montado.
        rw = workdir / "rw.dmg"
        run([
            "hdiutil", "create",
            "-srcfolder", str(stage),
            "-volname", args.volname,
            "-fs", "HFS+",
            "-fsargs", "-c c=64,a=16,e=16",
            "-format", "UDRW",
            str(rw),
        ])

        mount_line = run([
            "hdiutil", "attach", str(rw),
            "-readwrite", "-noverify", "-noautoopen", "-nobrowse",
            "-plist",
        ]).stdout
        entities = plistlib.loads(mount_line.encode())["system-entities"]
        mount = Path(next(
            entity["mount-point"]
            for entity in entities
            if entity.get("content-hint") == "Apple_HFS"
        ))
        device = next(
            entity["dev-entry"]
            for entity in entities
            if entity.get("content-hint") != "Apple_HFS"
        )
        try:
            script = string.Template(APPLESCRIPT).substitute(
                originX=WINDOW_ORIGIN[0],
                originY=WINDOW_ORIGIN[1],
                farX=WINDOW_ORIGIN[0] + WINDOW_W,
                farY=WINDOW_ORIGIN[1] + WINDOW_H,
                icon_size=ICON_SIZE,
                text_size=TEXT_SIZE,
                app_name=app.name,
                appX=APP_POS[0],
                appY=APP_POS[1],
                appsX=APPLICATIONS_POS[0],
                appsY=APPLICATIONS_POS[1],
                hiddenX=WINDOW_ORIGIN[0] + WINDOW_W + 100,
                hiddenY=WINDOW_ORIGIN[1] + WINDOW_H + 100,
            )
            result = subprocess.run(
                ["osascript", "-e", script, args.volname],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                print("AVISO: Finder no pudo aplicar el estilo al volumen.", file=sys.stderr)
                print(result.stderr.strip(), file=sys.stderr)
                print("¿Has aceptado el permiso de Terminal para controlar Finder?",
                      file=sys.stderr)
            elif not (mount / ".DS_Store").exists():
                raise SystemExit("Finder no escribió el .DS_Store: el DMG saldría sin estilo.")
            shutil.rmtree(mount / ".fseventsd", ignore_errors=True)
        finally:
            detach(mount, device)

        if output.exists():
            output.unlink()
        run([
            "hdiutil", "convert",
            "-format", "UDZO",
            "-imagekey", "zlib-level=9",
            "-o", str(output), str(rw),
        ])
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    run(["hdiutil", "verify", str(output)])
    verify_contents(output)
    print(f"OK: {output} ({output.stat().st_size:,} bytes)")


def verify_contents(image: Path) -> None:
    """Monta la imagen final y comprueba que lleva el estilo y la estructura."""
    entities = plistlib.loads(run([
        "hdiutil", "attach", str(image), "-nobrowse", "-readonly", "-plist",
    ]).stdout.encode())["system-entities"]
    mount = Path(next(
        entity["mount-point"]
        for entity in entities
        if entity.get("content-hint") == "Apple_HFS"
    ))
    try:
        required = [".DS_Store", ".background/background.png", "Applications"]
        apps = [item.name for item in mount.iterdir() if item.suffix == ".app"]
        if not apps:
            required.append("la aplicación")
        missing = [item for item in required if not (mount / item).exists()]
        if missing:
            raise SystemExit(f"Falta en el DMG: {', '.join(missing)}")
        print(f"Contenido verificado: {apps[0]}, Applications, .DS_Store y .background")
    finally:
        detach(mount, "")


if __name__ == "__main__":
    main()
