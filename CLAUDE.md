# Simple — notes pour les agents

Simple Client et Simple Server, les apps de démonstration de Syphon, passées à Metal. Simple Client enregistre en
plus sa source dans un film, pilotable depuis sa fenêtre, en OSC (décrit par OSCQuery) et en MCP. Adrien (spectacle
vivant, app eMotion) est l'unique utilisateur ; il parle français.

## Lire d'abord
- `DECISIONS.md` — D1…, le pourquoi de chaque choix, et ce qui est remis à plus tard. **Ajouter une entrée pour tout choix structurant.**
- `README.md` — fonctionnalités, adresses OSC, MCP.
- `docs/superpowers/specs/2026-10-01-recorder-design.md` — le design de l'enregistreur.

## Façon de travailler
- Répondre en français. Code, commentaires et commits en anglais, avec la ligne `Co-Authored-By` de l'harnais.
- `origin` = GitHub `cieadrienm/Simple` (privé) ; `upstream` = `Syphon/Simple` ; `gitea` = `amcb/Simple`.
- Fichiers dérivés de Syphon : garder leur en-tête BSD. Fichiers neufs : même licence, copyright Adrien Mondot.

## Build et tests
```
swift test                    # le cœur (Recorder/), ~8 s, sans Xcode ni app lancée
Tools/build.sh                # outils de vérification → build/tools
build/tools/settings-test     # le popover de réglages et la barre d'outils, hors écran
Scripts/bundle.sh             # apps Release signées + MCP → build/ (INSTALL=1 pour /Applications)
```
`Simple.xcworkspace` pour travailler dans Xcode. Ajouter un fichier à l'app = l'ajouter à la main au `.pbxproj` de
Simple Client (les fichiers de `Recorder/` y sont référencés un par un).

## Règles qui ont coûté cher
- **Ne jamais tuer les apps d'Adrien** (eMotion, OSCScore, AMKinectTrack tournent souvent). Lancer ses propres instances
  et les tuer par PID. Pour tester : `SIMPLE_OSC_PORT=19230 SIMPLE_OSCQUERY_PORT=19231 "<app>/Contents/MacOS/Simple Client" -RecorderFolder <dossier>`.
- **Simple Client sélectionne le premier serveur Syphon venu**, parfois eMotion : envoyer `/source "Simple Server"` avant d'enregistrer en test.
- **Les réglages envoyés en OSC sont enregistrés dans les préférences d'Adrien** (`net.am-cb.simple-client`) : les remettre à
  la fin (`/codec h264`, `/width 0`, `/height 0`, `/fps 0`, `/bitrate 0`, `/name ""`, `/folder ~/Movies`).
- **Pas d'accès à l'écran** : vérifier par les outils de `Tools/` (image Syphon lue en mémoire, vue rendue hors écran, film relu).
- **Une image Syphon a sa première ligne en bas** (D7). Tout ce qui l'affiche ou l'enregistre la retourne.
- **`[NSApp terminate:]` depuis un bloc de la file principale se bloque** s'il attend une fin qui arrive sur cette même file (D26) : passer par `performSelector:afterDelay:`.
- **`-[AVAssetWriter cancelWriting]` supprime le fichier.** Ne jamais l'appeler sur un film qui a des images (D21).
- **Bonjour et réseau : tester sur l'app signée** de `build/`, pas sur le binaire Debug ; l'autorisation « Réseau local » dépend de la signature.
- Une suite `swift test` qui échoue sur un port : une instance de test tourne peut-être encore sur ce port.
- SwiftPM garde un module périmé quand on ajoute un en-tête à `Recorder/` : l'ajouter à `Recorder/RecorderKit.h`.

## Architecture en une minute
- `Common/SimpleImageView` — vue Metal qui affiche une texture, partagée par les deux apps.
- `Recorder/` — sans Syphon : `FramePacer` (quelles images garder pour un fps maximum), `MovieRecorder` (texture Metal →
  AVAssetWriter), `OSCMessage`, `OSCReceiver`, `OSCQueryServer` (celui d'eMotion, **ne pas le modifier ici**),
  `RecorderController` (réglages, états, table des paramètres commune à la fenêtre, à l'OSC et à OSCQuery).
- `Simple Client/` — `SimpleClientAppDelegate` (client Syphon, donne chaque image au contrôleur depuis le thread de Syphon),
  `ToolbarDelegate`, `RecorderSettingsViewController` (popover construit en code).
- `MCP/main.swift` — `simple-recorder-mcp`, stdio : lit par OSCQuery, écrit par OSC.
- `Tools/` — `syphon-probe`, `gl-server`, `view-test`, `settings-test`, `movie-info`, `osc-send.py`, `mcp-call.py`.

## Invariants
- Tout ce que fait l'enregistreur est un paramètre de la table de `RecorderController` : une fonction nouvelle = une entrée,
  donc une adresse OSC, une description OSCQuery, un test, une ligne du README.
- `Recorder/` n'importe jamais Syphon.
- Tout nouveau comportement a un test ; un défaut corrigé a d'abord un test qui échoue.
