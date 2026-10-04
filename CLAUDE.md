# Simple Recorder — notes pour les agents

Simple Recorder enregistre plusieurs sources Syphon et NDI à la fois — un film chacune, un film où elles sont assemblées, ou les
deux — sur une horloge commune, pilotable depuis
sa fenêtre, en OSC (décrit par OSCQuery) et en MCP. Il vient du Simple Client de Syphon ; Simple Server, la source de test,
est toujours là. Adrien (spectacle vivant, app eMotion) est l'unique utilisateur ; il parle français.

## Lire d'abord
- `DECISIONS.md` — D1…, le pourquoi de chaque choix, et ce qui est remis à plus tard. **Ajouter une entrée pour tout choix structurant.**
- `README.md` — fonctionnalités, adresses OSC, MCP.
- `docs/superpowers/specs/2026-10-03-simple-recorder-design.md` — le design, en quatre parties. Les parties 1 (plusieurs sources),
  2 (film assemblé, dispositions) et 3 (image NDI) sont faites ; reste la partie 4, le son NDI, avec son plan à écrire dans
  `docs/superpowers/plans/` et à faire valider par Adrien.

## Façon de travailler
- Répondre en français. Code, commentaires et commits en anglais, avec la ligne `Co-Authored-By` de l'harnais.
- `git push origin master` pousse sur GitHub (`cieadrienm/Simple`, privé) **et** sur Gitea (`amcb/simple`). `upstream` = `Syphon/Simple`.
- Fichiers dérivés de Syphon : garder leur en-tête BSD. Fichiers neufs : même licence, copyright Adrien Mondot.

## Build et tests
```
Scripts/syphon.sh             # une fois : build/Syphon.xcframework, dont Package.swift a besoin
swift test                    # tout sauf Simple Server, ~2 min ; dessine aussi la fenêtre dans build/views/*.png
Scripts/bundle.sh             # build/Simple Recorder.app (signée, MCP dedans) et build/Simple Server.app
Tools/build.sh                # outils de vérification → build/tools
```
Pas de projet Xcode pour Simple Recorder : c'est un paquet SwiftPM (`App/` en SwiftUI, `Recorder/` en Objective-C, `MCP/`).
Simple Server se construit depuis `Simple.xcworkspace`.

## Règles qui ont coûté cher
- **Ne jamais tuer les apps d'Adrien** (eMotion, OSCScore, AMKinectTrack tournent souvent). Lancer ses propres instances et
  les tuer par PID. Pour tester : `SIMPLE_OSC_PORT=19230 SIMPLE_OSCQUERY_PORT=19231 "build/Simple Recorder.app/Contents/MacOS/Simple Recorder" -RecorderFolder <dossier>`,
  avec des `Simple Server -ServerName A` (B, C…) comme sources ; pour NDI, `build/tools/ndi-send <nom> [largeur hauteur fps] [--bgrx]` (lancé par soi, tué par PID).
- **Les réglages et les sources envoyés en OSC sont enregistrés dans les préférences d'Adrien** (`net.am-cb.simple-recorder`) :
  les remettre à la fin (vider les places : huit fois `/source/1 ""` ; `/output separate`, `/layout row`, `/gap 0`, `/width 0`, `/height 0`), ou passer par des arguments (`-RecorderName x`), qui ne sont pas enregistrés.
- **Pas d'accès à l'écran** : la fenêtre se vérifie par `build/views/*.png`, les films par `build/tools/movie-info`.
- **Une image Syphon a sa première ligne en bas** (D7). Tout ce qui l'affiche ou l'enregistre la retourne.
- **Syphon garde pour toujours l'entrée d'un serveur dont l'application a été tuée** (D42). Ne jamais supposer qu'un serveur listé vit ;
  un client déjà connecté reste « valide », seul un client neuf dit la vérité (`SyphonSource.serverIsAlive`). Le silence n'est pas la mort.
- **`[NSApp terminate:]` depuis un bloc de la file principale se bloque** s'il attend une fin qui arrive sur cette même file (D26).
- **`-[AVAssetWriter cancelWriting]` supprime le fichier.** Ne jamais l'appeler sur un film qui a des images (D21).
- **`registerDefaults` est global au processus** : `object(forKey:)` répond les valeurs enregistrées par n'importe quel contrôleur. Pour
  savoir ce qui a été réglé, lire `persistentDomain(forName:)` (D36).
- **Bonjour et réseau : tester sur l'app signée** de `build/` ; l'autorisation « Réseau local » dépend de la signature.
- **Deux files de commandes Metal ne sont pas ordonnées entre elles** : une texture dessinée sur l'une ne se lit sur l'autre qu'après
  la fin de son tampon de commandes (D52). Et **16384 de côté** est la plus grande image : au-delà tout est perdu en silence (D51).
- **Le lecteur d'AVFoundation rend une image noire datée 0** pour le vide au début d'un film : la sauter avant de relire « la première image ».
- Une suite `swift test` qui échoue sur un port : une instance de test tourne peut-être encore sur ce port.
- `Recorder/module.modulemap` est écrit à la main : un en-tête **public** de `Recorder/` va dans `Recorder/RecorderKit.h` (sinon SwiftPM garde un module périmé) ; un en-tête **privé** (il inclut ceux du SDK NDI, ou Swift ne doit pas le voir) va sur la liste `exclude` du module map, et les tests l'atteignent par un en-tête de renvoi dans `Tests/NDITestSupport` (D57).
- **Les chaînes de NDI ne vivent que jusqu'à l'appel suivant** : les copier aussitôt. Un nom de source qui n'est pas de l'UTF-8 valide a déjà fait planter l'app (D60). Et la bibliothèque NDI n'est jamais liée, seulement chargée (D56) : son absence est un état, un test qui en a besoin se saute (`XCTSkip`).
- **Les tests NDI n'affirment que sur leur propre émetteur** : d'autres sources NDI sont peut-être sur le réseau (celles d'Adrien). Ne jamais se connecter à une source qu'on n'a pas créée.
- Le vérificateur de types de Swift cale sur les longues sommes de tableaux dans les tests : passer par une fonction.

## Architecture en une minute
- `Recorder/` — Objective-C, sans Syphon : `FramePacer` (quelles images garder pour un fps maximum), `MovieRecorder` (texture
  Metal → AVAssetWriter), `Take` (les films d'un enregistrement, assemblé compris, leurs noms, leur horloge), `Layout` (où va chaque source : pur calcul),
  `Compositor` (les sources dessinées en une image), `FrameSource.h` (ce qu'est une
  source, un annuaire de sources), `NDILibrary` (la bibliothèque NDI, chargée à l'exécution), `NDITextureRing` (les textures où s'écrit une image NDI), `NDIFinder` (cherche les sources NDI, privé), `NDISource` (en reçoit une, privé), `NDIDirectory` (l'annuaire NDI), `CompositeDirectory` (Syphon d'abord, puis NDI : un seul annuaire), `RecorderController` (places, réglages, états, la table des paramètres commune à la
  fenêtre, à l'OSC et à OSCQuery), `OSCMessage`, `OSCReceiver`, `OSCQueryServer` (celui d'eMotion, **ne pas le modifier ici**).
- `App/` — Swift : `SimpleRecorderApp` (lancement, menu, fin propre), `SyphonSources` (seul fichier qui importe Syphon),
  `RecorderModel` (ce que la fenêtre montre du contrôleur, qu'il relit à chaque notification), `Views/`.
- `MCP/main.swift` — `simple-recorder-mcp`, stdio : lit par OSCQuery, écrit par OSC.
- `Simple Server/`, `Common/SimpleImageView` — la source de test, en Objective-C, dans son projet Xcode.
- `ThirdParty/NDI` — les en-têtes du SDK NDI (cible SwiftPM `NDIHeaders`) ; `Tests/NDITestSupport` — un émetteur NDI pour les tests et les en-têtes de renvoi vers les en-têtes privés.
- `Tools/` — `syphon-probe`, `gl-server`, `view-test`, `movie-info`, `ndi-send` (émetteur NDI de test), `osc-send.py`, `mcp-call.py`.

## Invariants
- Tout ce que fait l'enregistreur est un paramètre de la table de `RecorderController` : une fonction nouvelle = une entrée,
  donc une adresse OSC, une description OSCQuery, un test, une ligne du README.
- `Recorder/` n'importe jamais Syphon et ne lie jamais NDI ; `App/` ne contient pas de logique d'enregistrement.
- La fenêtre ne garde aucun état de l'enregistreur : elle montre le contrôleur, que l'OSC et le MCP changent aussi.
- Tout nouveau comportement a un test ; un défaut corrigé a d'abord un test qui échoue.
