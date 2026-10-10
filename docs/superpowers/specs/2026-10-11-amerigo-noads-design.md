# Amerigo NoAds — design

App iPhone perso (non distribuée) qui reprend les usages d'Amerigo sans pubs :
détecter les vidéos dans des pages web, les télécharger, les lire, gérer les fichiers.

## Contraintes

- Dev sur Windows, pas de Mac, Apple ID gratuit.
- Build : GitHub Actions (runner macOS), `.ipa` non signée.
- Install : Sideloadly (Windows) avec l'Apple ID gratuit ; re-signature tous les 7 jours.
- Repo GitHub public par défaut (minutes macOS illimitées). Privé possible : ~20 builds/mois.

## Périmètre

Inclus :
- Navigateur intégré avec détection de vidéos `.mp4` et `.m3u8` (HLS).
- Téléchargement en arrière-plan (mp4) et HLS hors-ligne.
- Lecteur natif (PiP, AirPlay, lecture en arrière-plan).
- Gestion de fichiers : lister, ouvrir, renommer, supprimer, créer un dossier.
- Dossier de l'app exposé dans l'app Fichiers d'iOS (déplacement/partage/zip délégués).

Exclus (v1) : transfert PC, bloqueur de pubs, favoris, historique, onglets, code PIN.
Hors d'atteinte : vidéos DRM. Flux `blob:`/MSE (YouTube & co) : signalés « non téléchargeable ».

## Architecture

SwiftUI, iOS 16+. `TabView` à deux onglets.

| Fichier | Rôle |
|---|---|
| `project.yml` | Spec XcodeGen (génère le `.xcodeproj` en CI) |
| `App/AmerigoApp.swift` | Point d'entrée, `TabView`, config `AVAudioSession(.playback)` |
| `App/BrowserView.swift` | Barre d'adresse, précédent/suivant/recharger, `WKWebView`, badge vidéos détectées, liste + bouton Télécharger |
| `App/Downloader.swift` | `ObservableObject` : file des téléchargements, progression, erreurs, réessai |
| `App/FilesView.swift` | Téléchargements en cours en haut ; contenu de `Documents/` ; renommer, supprimer, nouveau dossier ; ouverture du lecteur |
| `App/PlayerView.swift` | Wrapper `AVPlayerViewController` |
| `App/sniffer.js` | Script injecté (`WKUserScript`, tous les frames, document start) |
| `App/Info.plist` | `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, `UIBackgroundModes: audio` |
| `test/sniffer.test.js` | Tests `node --test` du sniffer |
| `.github/workflows/build.yml` | `brew install xcodegen` → `xcodegen` → `xcodebuild` sans signature → zip `Payload/` en `.ipa` → artifact |

## Flux de données

1. `sniffer.js` intercepte : `src` des `<video>`/`<source>` (y compris ajoutés dynamiquement, via `MutationObserver`), URLs passées à `fetch` et `XMLHttpRequest.open`.
   Il résout en URL absolue, garde celles dont le chemin finit par `.mp4`, `.m3u8` (ou contient ces extensions avant `?`), dédoublonne,
   et poste `{url, kind: "mp4"|"hls"|"blob", pageTitle}` via `webkit.messageHandlers.video`.
2. `BrowserView` accumule les détections de la page courante (remises à zéro à chaque navigation) → badge.
3. Télécharger → `Downloader` :
   - `mp4` : `URLSession` background configuration, `downloadTask` ; cookies copiés depuis `WKWebsiteDataStore.httpCookieStore`, en-tête `Referer` = URL de la page. Fin → déplacement vers `Documents/<titre>.mp4`.
   - `hls` : `AVAssetDownloadURLSession` + `AVURLAsset` (cookies + Referer passés en options). Fin → `.movpkg` déplacé dans `Documents/`.
   - `blob` : non téléchargeable, affiché grisé avec explication.
4. Nom de fichier : titre de la page nettoyé (caractères interdits retirés), suffixe ` (2)` si collision.

## Gestion d'erreurs

- Échec de téléchargement : ligne rouge avec le message de l'erreur + bouton « Réessayer ». Pas de retry automatique.
- Aucune détection : pas de badge.
- Pas de persistance de la file : un téléchargement interrompu par la fermeture forcée de l'app est perdu (relancer à la main).

## Tests

- `node --test` sur `sniffer.js` : détection `<video src>`, `<source>`, ajout dynamique, `fetch`, XHR, URL relative, query string, dédoublonnage, `blob:`. Le script est écrit pour être chargeable sous Node (DOM simulé minimal dans le test).
- Swift : la compilation en CI fait office de vérification.
- Check-list manuelle sur iPhone : un site mp4, un site HLS, lecture en arrière-plan + PiP, visibilité dans l'app Fichiers, renommer/supprimer.

## Installation (une fois)

1. Installer iTunes et iCloud **versions .exe Apple** (pas Microsoft Store), puis Sideloadly.
2. Créer le repo GitHub public, pousser.
3. Télécharger l'artifact `.ipa` du dernier build, l'ouvrir dans Sideloadly, iPhone en USB, Apple ID.
4. iPhone : Réglages → Confidentialité → Mode développeur ; Réglages → Général → VPN et gestion de l'appareil → faire confiance.
5. Activer l'auto-refresh de Sideloadly (PC allumé, même Wi-Fi).
