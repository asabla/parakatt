# Pinned native dependency notices

These files are exact copies of the upstream notices listed in `../media-tools.json`.
The build verifies each file against its existing SHA-256 before it adds the notice
to the application. CI does not need to retrieve these small files from upstream
servers, which can reject requests from hosted runners.

Files ending in `.base64` retain the original Gitiles response bytes so the pinned
upstream checksums remain unchanged. The build decodes them into readable text for
the application bundle. The corresponding-source archive includes the originals.

When updating a dependency, update its notice, source URL, revision, and checksum
together. Do not edit license text.
