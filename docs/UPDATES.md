# Automatische Updates

JellyDesk nutzt [Sparkle 2](https://sparkle-project.org) für automatische Updates. Die App prüft einmal am Tag `SUFeedURL` (siehe `JellyDesk/Info.plist`), vergleicht die dort stehenden Versionen mit dem laufenden Build und bietet bei einem Fund den Standard-Sparkle-Dialog an. Manuell geht es jederzeit über „JellyDesk → Nach Updates suchen …“.

Standardmäßig steht der Feed in `main`:

```
https://raw.githubusercontent.com/derpfiff/JellyDesk/main/appcast.xml
```

Er wird aus den GitHub-Releases bedient. Für eine neue Veröffentlichung sind drei Schritte nötig.

## 1. Einmalig: Signaturschlüssel

Sparkle bringt `generate_keys` mit, das einen EdDSA-Schlüssel anlegt. Der private Teil bleibt lokal in den Schlüsselbund; der öffentliche Teil wird in die App eingebettet:

```sh
./build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

Das Werkzeug legt den privaten Schlüssel im Schlüsselbund ab und druckt den öffentlichen Teil aus. Diesen Teil in `JellyDesk/Info.plist` unter `SUPublicEDKey` eintragen. Ohne gültigen Schlüssel schlägt die Signaturprüfung bei jedem Update fehl, der Updater bricht dann mit einer Fehlermeldung ab.

Der Schlüssel darf veröffentlicht werden – er ist nur zum Prüfen gedacht. Der private Teil wird nirgends eingecheckt.

## 2. Bei jeder Veröffentlichung: Build, signieren, hochladen

1. **Bauen** mit Developer ID (lokale Signatur reicht für den Updater nicht, sobald das Update auf einem fremden Rechner ankommt):

    ```sh
    xcodebuild -scheme JellyDesk -configuration Release archive \
      -archivePath build/JellyDesk.xcarchive
    xcodebuild -exportArchive -archivePath build/JellyDesk.xcarchive \
      -exportOptionsPlist Config/ExportOptions.plist \
      -exportPath build/Export
    ```

2. **Notarisieren** (optional für lokale Tests, zwingend für Dritte):

    ```sh
    xcrun notarytool submit build/Export/JellyDesk.app \
      --keychain-profile "AC_PASSWORD" --wait
    xcrun stapler staple build/Export/JellyDesk.app
    ```

3. **Verpacken** als ZIP (einfacher für Sparkle als DMG):

    ```sh
    cd build/Export
    ditto -c -k --sequesterRsrc --keepParent JellyDesk.app JellyDesk-1.2.0.zip
    ```

4. **Signatur** mit Sparkles `sign_update`:

    ```sh
    ./build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update build/Export/JellyDesk-1.2.0.zip
    ```

    Das Werkzeug druckt eine Zeile mit `sparkle:edSignature="…" length="…"` für den Appcast.

5. **GitHub-Release** anlegen: das ZIP als Anhang, Tag wie `v1.2.0`.

## 3. appcast.xml aktualisieren

`appcast.xml` im Repo pflegt die Historie. Ein neuer Eintrag sieht ungefähr so aus:

```xml
<item>
  <title>Version 1.2.0</title>
  <sparkle:version>3</sparkle:version>
  <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[
    <p>Was ist neu?</p>
  ]]></description>
  <pubDate>Thu, 20 Nov 2026 17:00:00 +0000</pubDate>
  <enclosure
    url="https://github.com/derpfiff/JellyDesk/releases/download/v1.2.0/JellyDesk-1.2.0.zip"
    sparkle:edSignature="…"
    length="…"
    type="application/octet-stream" />
</item>
```

`sparkle:version` entspricht `CURRENT_PROJECT_VERSION` in `project.yml`, `sparkle:shortVersionString` dem `MARKETING_VERSION`. Beide müssen zu dem gebauten ZIP passen, sonst erkennt Sparkle das Update nicht als neuer.

Nach einem Commit von `appcast.xml` auf `main` bekommen alle laufenden Installationen das Update beim nächsten Check angeboten.

## Hinweise zum Sandbox-Modus

Sparkle läuft hier im sandboxed Modus. Die beiden XPC-Dienste (`-spks`, `-spki`) liegen im Sparkle-Paket und werden in `JellyDesk/JellyDesk.entitlements` über `com.apple.security.temporary-exception.mach-lookup.global-name` freigegeben. Weitere Ausnahmen braucht es nicht; `com.apple.security.network.client` ist für den Download des ZIPs schon gesetzt.

Wer Sparkle nicht nutzen will (etwa für Test-Builds), kann `SUFeedURL` in `Info.plist` leeren – der Updater macht dann beim Start nichts, und der Menüeintrag „Nach Updates suchen …“ zeigt einen Hinweis.
