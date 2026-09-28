#!/usr/bin/env python3
"""Check the application bytes required by both source-built escripts."""

import sys
import zipfile
from pathlib import Path


REQUIRED = frozenset(
    {
        "logger/ebin/logger.app",
        "logger/ebin/Elixir.Logger.beam",
        "req_llm/ebin/req_llm.app",
        "req/ebin/req.app",
        "finch/ebin/finch.app",
    }
)


def check(path: Path) -> None:
    if not path.is_file():
        raise ValueError(f"missing escript: {path}")
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise ValueError(f"duplicate archive entries: {path}")
            missing = sorted(REQUIRED.difference(names))
            if missing:
                raise ValueError(f"missing required applications in {path}: {', '.join(missing)}")
            for name in REQUIRED:
                if archive.getinfo(name).file_size == 0:
                    raise ValueError(f"empty required application entry in {path}: {name}")
    except zipfile.BadZipFile as error:
        raise ValueError(f"invalid escript archive: {path}") from error

    print(f"escript-inventory: PASS {path.name} logger and provider dependency bytes")


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print("usage: escript-inventory.py CLI_ESCRIPT PROVIDER_ESCRIPT", file=sys.stderr)
        return 2
    try:
        for argument in arguments:
            check(Path(argument))
    except (OSError, ValueError) as error:
        print(f"escript-inventory: FAIL {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
