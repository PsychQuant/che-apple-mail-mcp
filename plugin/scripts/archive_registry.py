#!/usr/bin/env python3
"""Read-only registry, history snapshot, and routing planner for archive-mail.

This module does not capture, move, delete, or update any archive. A plan is not
an execution lock or authorization. See the pending executor contract in #363.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


class RegistryError(ValueError):
    pass


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RegistryError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    try:
        raw = Path(path).read_bytes()
        data = json.loads(raw, object_pairs_hook=_unique_object)
    except (OSError, ValueError) as error:
        raise RegistryError(f"cannot read valid JSON at {path}: {error}") from error
    return data, hashlib.sha256(raw).hexdigest()


def _text(value, label):
    if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 for c in value):
        raise RegistryError(f"{label} must be a nonempty string without controls")
    return value


def _message_id(value):
    return (isinstance(value, str) and len(value) > 2 and value.startswith("<")
            and value.endswith(">") and not any(c.isspace() or ord(c) < 32 for c in value))


class Registry:
    FIELDS = {"id", "parent_id", "workspace", "config_file", "output_dir", "index_file",
              "purpose", "filter_axis"}
    PATHS = ("workspace", "config_file", "output_dir", "index_file")

    def __init__(self, data, digest=None):
        if (not isinstance(data, dict) or set(data) != {"version", "targets"}
                or type(data["version"]) is not int or data["version"] != 1
                or not isinstance(data["targets"], list)):
            raise RegistryError("registry requires version: 1 and targets array, no extra fields")
        self.digest = digest or hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
        self.targets = {}
        used_paths, used_inodes = set(), set()
        for source in data["targets"]:
            if not isinstance(source, dict) or set(source) != self.FIELDS:
                raise RegistryError("each target requires exactly " + ", ".join(sorted(self.FIELDS)))
            target = dict(source)
            tid = _text(target["id"], "id")
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", tid) or tid in self.targets:
                raise RegistryError(f"duplicate or invalid target id: {tid}")
            for key in ("purpose", "filter_axis"):
                _text(target[key], f"{tid}.{key}")
            parent = target["parent_id"]
            if parent is not None:
                _text(parent, f"{tid}.parent_id")
            for field in self.PATHS:
                value = _text(target[field], f"{tid}.{field}")
                path = Path(value)
                if not path.is_absolute():
                    raise RegistryError(f"{tid}.{field} must be absolute")
                try:
                    target[field] = str(path.resolve())
                except (OSError, RuntimeError) as error:
                    raise RegistryError(f"{tid}.{field}: cannot resolve path") from error
                if field != "workspace":
                    # realpath strings alone miss APFS case aliases and hard
                    # links. Never let a future index writer share a config.
                    resolved = Path(target[field])
                    try:
                        stat = resolved.stat()
                        inode = (stat.st_dev, stat.st_ino)
                    except FileNotFoundError:
                        inode = None  # inventory/scope validation reports stale paths
                    except OSError as error:
                        raise RegistryError(f"{tid}.{field}: cannot inspect path") from error
                    if target[field] in used_paths or (inode is not None and inode in used_inodes):
                        raise RegistryError(f"shared canonical config/output/index path: {tid}.{field}")
                    used_paths.add(target[field])
                    if inode is not None:
                        used_inodes.add(inode)
            self.targets[tid] = target
        for tid in self.targets:
            self.ancestors(tid)  # validate every parent and cycle, including unrelated trees

    @classmethod
    def load(cls, path):
        data, digest = read_json(path)
        return cls(data, digest)

    def ancestors(self, tid):
        chain = []
        while tid is not None:
            if tid not in self.targets:
                raise RegistryError(f"unknown parent or target: {tid}")
            if tid in chain:
                raise RegistryError(f"parent cycle at {tid}")
            chain.append(tid)
            tid = self.targets[tid]["parent_id"]
        return chain

    def component(self, tid):
        root = self.ancestors(tid)[-1]
        return root, sorted(key for key in self.targets if self.ancestors(key)[-1] == root)

    def path_errors(self, tid):
        target = self.targets[tid]
        errors = []
        for field in self.PATHS:
            path = Path(target[field])
            valid = path.is_dir() if field in {"workspace", "output_dir"} else path.is_file()
            if not valid:
                errors.append(f"{tid}.{field}: missing or wrong path type")
        return errors

    def inventory(self):
        return [{**self.targets[tid], "root_id": self.ancestors(tid)[-1],
                 "errors": self.path_errors(tid)} for tid in sorted(self.targets)]

    def snapshot(self, tid):
        root, scope = self.component(tid)
        history, fingerprints = {}, {}
        for key in scope:
            errors = self.path_errors(key)
            if errors:
                raise RegistryError("; ".join(errors))
            target = self.targets[key]
            index, digest = read_json(target["index_file"])
            if (not isinstance(index, dict) or index.get("version") != "1.0"
                    or not isinstance(index.get("emails"), dict)):
                raise RegistryError(f"{key}: index requires version 1.0 and emails mapping")
            fingerprints[key] = digest
            for mid, entry in index["emails"].items():
                if not _message_id(mid) or not isinstance(entry, dict):
                    raise RegistryError(f"{key}: invalid Message-ID or index entry")
                filename = entry.get("file")
                if (not isinstance(filename, str) or not filename or "\x00" in filename
                        or Path(filename).is_absolute() or ".." in Path(filename).parts):
                    raise RegistryError(f"{key}: index file must be a relative contained path")
                output = Path(target["output_dir"])
                path = (output / filename).resolve()
                if not path.is_relative_to(output):
                    raise RegistryError(f"{key}: index file escapes output_dir")
                present = path.is_file()
                history.setdefault(mid, []).append({
                    "target_id": key, "file": filename,
                    "state": "present" if present else "historical_index_only",
                })
        return {"root_id": root, "target_ids": scope, "registry_sha256": self.digest,
                "index_sha256": fingerprints, "history": history,
                "unique_message_ids": len(history),
                "historical_index_only": sum(location["state"] == "historical_index_only"
                    for locations in history.values() for location in locations)}

    def plan(self, snapshot, candidates):
        root = snapshot["root_id"]
        if snapshot["registry_sha256"] != self.digest:
            raise RegistryError("snapshot belongs to a different registry")
        _, scope = self.component(root)
        if not isinstance(candidates, list):
            raise RegistryError("candidates must be an array")
        items, seen = [], set()
        for candidate in candidates:
            if not isinstance(candidate, dict) or set(candidate) != {"message_id", "matched_target_ids"}:
                raise RegistryError("candidate requires message_id and matched_target_ids")
            mid, matches = candidate["message_id"], candidate["matched_target_ids"]
            if not _message_id(mid) or mid in seen:
                raise RegistryError("duplicate or invalid candidate Message-ID")
            seen.add(mid)
            if (not isinstance(matches, list) or any(not isinstance(k, str) or k not in scope for k in matches)
                    or len(set(matches)) != len(matches)):
                raise RegistryError("matched targets must be unique members of the selected tree")
            existing = snapshot["history"].get(mid)
            if existing:
                items.append({"message_id": mid, "action": "already_archived", "locations": existing})
                continue
            if not matches:
                destination, reason = root, "unclassified_intake"
            else:
                chains = [self.ancestors(key) for key in matches]
                deepest = max(matches, key=lambda key: len(self.ancestors(key)))
                if all(key in self.ancestors(deepest) for key in matches):
                    destination, reason = deepest, "confirmed_match"
                else:
                    destination = next(key for key in chains[0] if all(key in chain for chain in chains))
                    reason = "ambiguous_intake"
            items.append({"message_id": mid, "action": "capture", "capture_target_id": root,
                          "destination_target_id": destination, "reason": reason})
        return {"root_id": root, "registry_sha256": self.digest,
                "index_sha256": snapshot["index_sha256"], "items": items,
                "execution_status": "planning_only"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=Path.home() / ".claude/.mail/archives.json")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    commands.add_parser("validate")
    for name in ("snapshot", "plan"):
        sub = commands.add_parser(name)
        sub.add_argument("--target", required=True)
        if name == "plan":
            sub.add_argument("--candidates", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        registry = Registry.load(args.registry)
        if args.command == "list":
            result = {"targets": registry.inventory()}
        elif args.command == "validate":
            errors = [error for target in registry.inventory() for error in target["errors"]]
            if errors:
                raise RegistryError("; ".join(errors))
            result = {"valid": True, "target_count": len(registry.targets)}
        else:
            result = registry.snapshot(args.target)
            if args.command == "plan":
                candidates, _ = read_json(args.candidates)
                result = registry.plan(result, candidates)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (RegistryError, OSError, RuntimeError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
