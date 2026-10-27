# LAN Remote bridge artifacts

The VPhone bundle stages these two macOS executables so each graphical VM can
start or stop LAN Remote from **Features → LAN Remote**. Their source is in the
sibling `Others/vphone_remote` project. After editing that project, run its
Flutter tests, compile `bin/bridge.dart` to `dist/vphone-remote-bridge` with
`dart compile exe`, build/sign the audio helper, then run
`Build/SyncRemoteBridge.sh` here. The sync script checks both signatures.

Do not re-sign the Dart AOT executable. The Dart compiler's linker signature
must remain intact; forcing a new signature has caused an invalid-page kill at
launch. `StageBundle.sh` copies the signed bytes and seals the outer bundle.
