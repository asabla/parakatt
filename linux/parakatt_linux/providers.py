"""Read-only provider retrieval. Credentials never cross a redirect or appear in a URL."""

import json
import time
from dataclasses import dataclass
from typing import Protocol, cast
from urllib.error import HTTPError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

MAX_BYTES = 8 * 1024 * 1024


class ProviderError(RuntimeError):
    pass


@dataclass(frozen=True)
class Response:
    status: int
    body: bytes
    retry_after: str | None = None


class Transport(Protocol):
    def __call__(self, url: str, token: str, accept: str) -> Response: ...


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(
        self, req: Request, fp: object, code: int, msg: str, headers: object, newurl: str
    ) -> None:
        return None


def http_get(url: str, token: str, accept: str) -> Response:
    if (
        urlsplit(url).hostname not in ("graph.microsoft.com", "slack.com")
        or urlsplit(url).scheme != "https"
    ):
        raise ProviderError("Unsupported provider destination")
    if not token or any(char.isspace() for char in token):
        raise ProviderError("Missing or invalid access token")
    request = Request(url, headers={"Authorization": f"Bearer {token}", "Accept": accept})
    try:
        with build_opener(NoRedirect()).open(request, timeout=20) as result:
            body = result.read(MAX_BYTES + 1)
            if len(body) > MAX_BYTES:
                raise ProviderError("Provider response exceeds 8 MiB")
            return Response(result.status, body, result.headers.get("Retry-After"))
    except HTTPError as error:
        # Do not surface server bodies: they may contain meeting data or credentials.
        return Response(error.code, error.read(MAX_BYTES + 1), error.headers.get("Retry-After"))


def get_with_retry(url: str, token: str, accept: str, transport: Transport) -> bytes:
    for attempt in range(3):
        response = transport(url, token, accept)
        if len(response.body) > MAX_BYTES:
            raise ProviderError("Provider response exceeds 8 MiB")
        if response.status == 200:
            return response.body
        if response.status in (429, 503):
            if response.retry_after and not response.retry_after.isdigit():
                raise ProviderError("Provider requested a delayed retry; retry later")
            delay = (
                int(response.retry_after)
                if response.retry_after and response.retry_after.isdigit()
                else 2**attempt
            )
            if attempt == 2 or delay > 30:
                raise ProviderError("Provider is busy or rate limited; retry later")
            time.sleep(delay)
            continue
        if response.status == 401:
            raise ProviderError("Access token expired or was rejected; sign in again")
        if response.status == 403:
            try:
                payload = object_fields(json.loads(response.body))
                error = object_fields(payload.get("error"))
                inner = object_fields(error.get("innerError", {}))
                code = inner.get("code")
            except (ValueError, ProviderError):
                code = None
            if code == "GraphAccessToTranscriptsDisabled":
                raise ProviderError("The Teams administrator has disabled Graph transcript access")
            if code == "SpeakerAttributionNotAllowed":
                raise ProviderError(
                    "The Teams administrator has disabled speaker-attributed transcripts; names will not be inferred"
                )
            raise ProviderError(
                "Access denied. Check meeting access, approved scopes, and tenant transcript/speaker-attribution settings"
            )
        raise ProviderError(f"Provider request failed (HTTP {response.status})")
    raise ProviderError("Provider request failed")


def identifier(value: str) -> str:
    if not value or len(value) > 4096 or any(ord(c) < 32 for c in value):
        raise ProviderError("Invalid source identifier")
    return quote(value, safe="")


def teams_transcript(
    token: str,
    meeting_id: str,
    transcript_id: str,
    user_id: str = "me",
    transport: Transport = http_get,
) -> str:
    owner = "me" if user_id == "me" else f"users/{identifier(user_id)}"
    url = f"https://graph.microsoft.com/v1.0/{owner}/onlineMeetings/{identifier(meeting_id)}/transcripts/{identifier(transcript_id)}/content"
    return get_with_retry(url, token, "text/vtt", transport).decode("utf-8-sig")


def slack_transcript(token: str, file_id: str, transport: Transport = http_get) -> str:
    # The source must be an accessible Huddle file/canvas, not arbitrary chat history.
    for _ in range(2):
        url = "https://slack.com/api/files.info?" + urlencode({"file": file_id})
        raw = get_with_retry(url, token, "application/json", transport)
        data: object = json.loads(raw)
        if not isinstance(data, dict):
            raise ProviderError("Slack returned an invalid response")
        fields = cast(dict[object, object], data)
        if fields.get("ok") is not True:
            raise ProviderError(
                "Slack denied file access; check scopes, membership, and transcript availability"
            )
        file: object = fields.get("file")
        if not isinstance(file, dict):
            raise ProviderError("Slack returned no file")
        file_fields = cast(dict[object, object], file)
        if isinstance(file_fields.get("huddle_transcription"), dict):
            return raw.decode("utf-8")
        linked = file_fields.get("huddle_transcript_file_id")
        if not isinstance(linked, str) or not linked:
            break
        file_id = linked
    raise ProviderError(
        "No accessible Huddle transcript. Notes-only canvases are not verbatim transcripts"
    )


def object_fields(value: object) -> dict[object, object]:
    if not isinstance(value, dict):
        raise ProviderError("Expected a provider JSON object")
    return cast(dict[object, object], value)


def slack_speaker_names(
    token: str, content: str, transport: Transport = http_get
) -> dict[str, str]:
    """Optional users:read lookup; retains only IDs and names, never profile payloads."""
    root = object_fields(json.loads(content))
    file = object_fields(root.get("file", root))
    transcript = object_fields(file.get("huddle_transcription", file))
    lines = transcript.get("lines")
    if not isinstance(lines, list):
        raise ProviderError("No transcript lines")
    user_ids: set[str] = set()
    for line in cast(list[object], lines):
        user_id = object_fields(line).get("user_id")
        if isinstance(user_id, str) and user_id:
            user_ids.add(user_id)
    if len(user_ids) > 500:
        raise ProviderError("Too many participant IDs for one meeting")
    names: dict[str, str] = {}
    for user_id in sorted(user_ids):
        url = "https://slack.com/api/users.info?" + urlencode({"user": user_id})
        response = object_fields(
            json.loads(get_with_retry(url, token, "application/json", transport))
        )
        if response.get("ok") is not True:
            raise ProviderError(
                "Cannot resolve Slack names; optional lookup requires users:read and user visibility"
            )
        user = object_fields(response.get("user"))
        profile = object_fields(user.get("profile", {}))
        name = profile.get("display_name") or user.get("real_name")
        if isinstance(name, str) and name.strip():
            names[user_id] = name.strip()
    return names
