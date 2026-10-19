# Weibo emoji catalog and API references

## Bundled emoji mapping

`entry/src/main/resources/rawfile/weibo-emoji.json` contains the 558 Simplified Chinese emoji mappings from:

- DimensionDev / Flare: https://github.com/DimensionDev/Flare
- Source file: https://github.com/DimensionDev/Flare/blob/master/docs/emoji.json
- Source Git blob observed on 2026-09-30: `812cc2d0aa0d28252f489a55c1c97c3d782b68c0`
- Local SHA-256: `08a01c9892e2f1d05a1614d44fdbe3e946feb90782d1c7ff650b58c88d23a9e5`

Local formatting differs from the current upstream file; all 558 phrase/URL pairs were compared and match. Flare identifies its repository license as AGPL-3.0. A copy is retained in `Flare-LICENSE.txt`. Retain attribution and the relevant license/source obligations when distributing this catalog; this note is not a legal clearance for a release.

Only the catalog is bundled, not the emoji image files. Image URLs point to Weibo's `sinaimg.cn` / `sinajs.cn` CDN. Artwork, trademarks and associated service terms remain those of their respective owners. The application rejects mappings to other hosts and renders an unknown `[phrase]` as text.

## API research

Flare's Weibo `StatusApi`, `TimelineApi`, `UserApi` and response models were consulted to check endpoint names, multipart field names and JSON shapes. Investigative downloads in `.ref/` are not application resources and should not be packaged. Endpoint references are not proof that a current logged-in Weibo account can execute every operation; authenticated verification remains separate.
