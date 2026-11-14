"""Transcript import and read-only connector commands, independent of the desktop UI."""

import argparse
import getpass
import json
import os
import sys
from pathlib import Path

from .backend import Backend, Paths
from .meeting_notes import render_minutes
from .providers import (
    ProviderError,
    slack_speaker_names,
    slack_transcript,
    teams_transcript,
)
from .transcript_service import read_transcript


def teams_token(client_id, tenant, announce=print):
    """Use the same delegated sign-in and keyring cache as the desktop."""
    from .authentication import TeamsAuthentication

    return TeamsAuthentication(client_id, tenant).token(
        announce=lambda prompt: announce(prompt.message)
    )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Import Teams meetings and Slack Huddle transcripts; no speech model required"
    )
    parser.add_argument("--data-dir", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    file = commands.add_parser("file", help="Import an exported transcript")
    file.add_argument("path", type=Path)
    file.add_argument("--provider", choices=["teams", "slack"], required=True)
    file.add_argument("--source-id")
    file.add_argument("--title")
    teams = commands.add_parser("teams", help="Read one existing Teams transcript")
    teams.add_argument("--meeting-id", required=True)
    teams.add_argument("--transcript-id", required=True)
    teams.add_argument("--user-id", default="me")
    teams.add_argument("--client-id")
    teams.add_argument("--tenant", default="organizations")
    teams.add_argument("--title", default="Teams meeting")
    slack = commands.add_parser("slack", help="Read an accessible Huddle transcript file")
    slack.add_argument("--workspace", required=True)
    slack.add_argument("--file-id", required=True)
    slack.add_argument("--title", default="Slack Huddle")
    slack.add_argument(
        "--resolve-names",
        action="store_true",
        help="Resolve participant names using optional users:read permission",
    )
    token = commands.add_parser(
        "set-slack-token", help="Store a scoped Slack token in the OS keyring"
    )
    token.add_argument("--workspace", required=True)
    rename = commands.add_parser("speaker", help="Set a reversible speaker display-name correction")
    rename.add_argument("--record-id", required=True)
    rename.add_argument("--original", required=True)
    rename.add_argument("--name", required=True, help="Empty string restores the original label")
    action = commands.add_parser(
        "action", help="Add a confirmed action with a supporting utterance"
    )
    action.add_argument("--record-id", required=True)
    action.add_argument("--text", required=True)
    action.add_argument("--owner")
    action.add_argument("--due-date", help="YYYY-MM-DD; omitted dates remain unknown")
    action.add_argument(
        "--source-utterance", type=int, required=True, help="Zero-based source utterance index"
    )
    complete = commands.add_parser(
        "complete-action", help="Mark a confirmed follow-up item complete"
    )
    complete.add_argument("--record-id", required=True)
    complete.add_argument("--action-id", required=True)
    export = commands.add_parser(
        "export", help="Export imported utterances as source-attributed Markdown"
    )
    export.add_argument("--record-id", required=True)
    export.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        names = {}
        if args.command == "set-slack-token":
            from keyring.backends.SecretService import Keyring

            value = getpass.getpass("Slack token (hidden): ")
            if not value or any(c.isspace() for c in value):
                raise ValueError("Missing or invalid token")
            Keyring().set_password("parakatt-integrations", f"slack:{args.workspace}", value)
            print("Stored in the desktop keyring")
            return 0
        if args.command == "file":
            content = read_transcript(args.path)
            provider, source_id, title = args.provider, args.source_id, args.title or args.path.stem
        elif args.command == "teams":
            token = os.environ.get("PARAKATT_TEAMS_ACCESS_TOKEN") or teams_token(
                args.client_id, args.tenant, lambda message: print(message, file=sys.stderr)
            )
            content = teams_transcript(token, args.meeting_id, args.transcript_id, args.user_id)
            provider, source_id, title = (
                "teams",
                f"{args.user_id}/{args.meeting_id}/{args.transcript_id}",
                args.title,
            )
        elif args.command == "slack":
            from keyring.backends.SecretService import Keyring

            token = os.environ.get("PARAKATT_SLACK_ACCESS_TOKEN") or Keyring().get_password(
                "parakatt-integrations", f"slack:{args.workspace}"
            )
            if not token:
                raise ProviderError("Use set-slack-token for this workspace first")
            content = slack_transcript(token, args.file_id)
            if args.resolve_names:
                names = slack_speaker_names(token, content)
            provider, source_id, title = "slack", f"{args.workspace}/{args.file_id}", args.title
        backend = Backend(Paths.discover(data=args.data_dir))
        if args.command == "action":
            if args.source_utterance < 0:
                raise ValueError("Source utterance index must be non-negative")
            action = backend.engine.add_meeting_action(
                args.record_id, args.text, args.owner, args.due_date, args.source_utterance
            )
            print(json.dumps({"id": action.id, "source_quote": action.source_quote}))
            return 0
        if args.command == "complete-action":
            backend.engine.complete_meeting_action(args.record_id, args.action_id, True)
            print("Action completed")
            return 0
        if args.command == "speaker":
            backend.engine.set_transcript_speaker_alias(args.record_id, args.original, args.name)
            print("Speaker correction saved; original attribution retained")
            return 0
        if args.command == "export":
            row = backend.engine.get_transcription(args.record_id)
            origin = backend.engine.get_transcript_origin(args.record_id)
            cues = backend.engine.get_imported_utterances(args.record_id)
            recognized = backend.engine.get_transcription_processing(args.record_id).recognized_text
            text = render_minutes(
                row.title or "Meeting transcript",
                origin.provider,
                origin.source_id,
                cues,
                backend.engine.get_meeting_actions(args.record_id),
                row.text if row.text != recognized else None,
            )
            args.output.write_text(text, encoding="utf-8")
            print(str(args.output))
            return 0
        result = backend.engine.import_transcript(
            backend.api.TranscriptImportRequest(
                provider=backend.api.TranscriptProvider.TEAMS
                if provider == "teams"
                else backend.api.TranscriptProvider.SLACK,
                source_id=source_id,
                title=title,
                content=content,
            )
        )
        for original, display in names.items():
            backend.engine.set_transcript_speaker_alias(result.id, original, display)
        print(
            json.dumps(
                {
                    "id": result.id,
                    "created": result.created,
                    "utterance_count": result.utterance_count,
                }
            )
        )
        return 0
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
