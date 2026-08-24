# Spike de capture audio macOS

## But

Prouver avant la transcription que macOS fournit simultanement :

- le microphone local ;
- le son systeme provenant de Teams, Webex, d'un navigateur ou d'une autre application.

Le spike affiche uniquement des niveaux et des compteurs de buffers. Il ne conserve aucun echantillon et n'ecrit aucun fichier audio.

## Prerequis

- Mac Apple Silicon sous macOS 15 ou plus recent ;
- Swift 6.2 ou plus recent ;
- autorisations Microphone et Enregistrement de l'ecran et de l'audio systeme.

Xcode complet n'est pas necessaire pour ce spike : les Command Line Tools suffisent pour construire le bundle local.

## Construire et lancer

```bash
./scripts/run-spike.sh
```

Au premier lancement, accepter les deux demandes macOS. Si macOS demande de fermer puis rouvrir l'application apres l'autorisation de capture, relancer la meme commande.

## Test manuel M5 puis M2

1. Ouvrir Meeting Capture Spike.
2. Cliquer sur `Tester la capture`.
3. Parler : le niveau `Microphone` et son compteur doivent bouger.
4. Lancer une video ou une reunion Teams/Webex : le niveau `Son du Mac` et son compteur doivent bouger.
5. Utiliser un casque pour le premier test afin de ne pas renvoyer le son des participants dans le microphone.
6. Cliquer sur `Arreter le test`.

Noter pour chaque machine :

- version de macOS ;
- source testee ;
- microphone detecte oui/non ;
- son systeme detecte oui/non ;
- erreur ou interruption eventuelle.

## Verification automatisee

```bash
./scripts/check.sh
```

Les Command Line Tools installes sur la machine de developpement ne fournissent
ni XCTest ni Swift Testing. Les verifications du coeur sont donc executees par
un petit binaire Swift autonome, sans framework de test externe.

## Limites volontaires

- pas de transcription ;
- pas de diarisation ;
- pas de stockage SQLite ;
- pas encore de selection d'une application audio particuliere ;
- pas de barre de menus.

Ces fonctions ne seront ajoutees qu'apres validation des deux flux sur le M2 32 Go.
