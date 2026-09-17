#!/usr/bin/env python3
"""Recoverable, cooperative single-writer distribution of sealed staged bundles.

Mail fetching and attachment classification happen before this executor. It owns
new intake/destination files and never adopts pre-existing archive files. Caller
must run the normal thread/index reconciliation gate on reconcile_targets.
"""
import argparse
from contextlib import contextmanager
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.parse import quote, unquote, urlsplit
import uuid
import unicodedata

from archive_registry import Registry, RegistryError, _unique_object, _message_id, read_json

CHUNK = 1024 * 1024
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class DistributionError(RegistryError):
    def __init__(self, cause, state):
        self.job_id = state['job_id']
        self.phase = state['phase']
        super().__init__(f"job {self.job_id} after {self.phase}: {cause}")


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parts(relative):
    if (not isinstance(relative, str) or not relative or relative.startswith('/')
            or any(ord(c) < 32 for c in relative) or '\\' in relative
            or any(p in {'', '.', '..'} for p in relative.split('/'))):
        raise RegistryError('bundle paths must be nonempty contained relative paths')
    return relative.split('/')


@contextmanager
def parent_at(base, relative, create=False):
    names = parts(relative)
    base = Path(base)
    if not base.is_absolute():
        raise RegistryError('internal directory anchor must be absolute')
    fd = os.open('/', DIR_FLAGS)
    try:
        for component in base.parts[1:] + tuple(names[:-1]):
            try:
                child = os.open(component, DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(component, 0o700, dir_fd=fd)
                os.fsync(fd)
                child = os.open(component, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd, names[-1]
    finally:
        os.close(fd)


def read_bytes(base, relative):
    with parent_at(base, relative) as (fd, name):
        handle = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        with os.fdopen(handle, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise RegistryError('expected regular file')
            return stream.read()


def file_info(base, relative):
    with parent_at(base, relative) as (fd, name):
        handle = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        with os.fdopen(handle, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise RegistryError('expected regular file')
            hashed = hashlib.sha256()
            for chunk in iter(lambda: stream.read(CHUNK), b''):
                hashed.update(chunk)
            return {'sha256': hashed.hexdigest(), 'inode': [info.st_dev, info.st_ino]}


def atomic_json(base, name, data):
    raw = encoded(data)
    with parent_at(base, name, create=True) as (fd, leaf):
        temp = '.idd-json-' + uuid.uuid4().hex
        handle = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            with os.fdopen(handle, 'wb') as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, leaf, src_dir_fd=fd, dst_dir_fd=fd)
            os.fsync(fd)
        finally:
            try: os.unlink(temp, dir_fd=fd)
            except FileNotFoundError: pass


def state_read(job):
    return json.loads(read_bytes(job, 'state.json'), object_pairs_hook=_unique_object)


@contextmanager
def tree_lock(registry, root):
    directory = Path(registry.targets[root]['index_file']).parent
    with parent_at(directory, '.archive-registry.lock') as (fd, name):
        handle = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            if not stat.S_ISREG(os.fstat(handle).st_mode):
                raise RegistryError('tree lock must be a regular file')
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RegistryError('registered tree is busy') from error
            yield directory / 'archive-dispatch'
        finally:
            os.close(handle)


def _index_op(registry, target, before_sha, after):
    return {'target_id': target, 'before_sha256': before_sha, 'after': after}


def _anchor_base(registry, target_id, anchor):
    target = registry.targets[target_id]
    if anchor in {'workspace', 'output_dir'}:
        return target[anchor]
    if anchor in target['attachment_roots']:
        return anchor
    raise RegistryError('unregistered attachment anchor')


def _file_base(registry, record):
    return _anchor_base(registry, record['target_id'], record['anchor'])


def _asset_location(registry, target_id, value):
    if not isinstance(value, str):
        raise RegistryError('attachment destination must be a path string')
    if not Path(value).is_absolute():
        parts(value)
        return 'workspace', value
    if '..' in Path(value).parts or any(ord(c) < 32 for c in value):
        raise RegistryError('invalid absolute attachment path')
    path = Path(value).resolve()
    target = registry.targets[target_id]
    anchors = [('workspace', target['workspace']), ('output_dir', target['output_dir'])]
    anchors += [(root, root) for root in target['attachment_roots']]
    for anchor, base in sorted(anchors, key=lambda item: len(item[1]), reverse=True):
        if path.is_relative_to(base) and path != Path(base):
            return anchor, str(path.relative_to(base))
    raise RegistryError('absolute attachment destination is outside registered roots')


def _record_preparation_blob(job, name, handle, parent_fd):
    info = os.fstat(handle)
    os.fsync(handle)
    os.fsync(parent_fd)
    state = state_read(job)
    if state['phase'] != 'preparing':
        raise RegistryError('blob creation outside preparation')
    state['preparation_blobs'].append({'name': name, 'inode': [info.st_dev, info.st_ino]})
    atomic_json(job, 'state.json', state)  # owner is durable before private mail bytes


def _cleanup_preparation_blobs(job, state):
    unknown = []
    for blob in state.get('preparation_blobs', []):
        name = blob['name']
        if not re.fullmatch(r'blob-[0-9a-f]{32}', name):
            raise RegistryError('invalid preparation blob name')
        with parent_at(job, name) as (fd, leaf):
            try:
                info = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(info.st_mode) or [info.st_dev, info.st_ino] != blob['inode']:
                unknown.append(name)
                continue
            os.unlink(leaf, dir_fd=fd)
            os.fsync(fd)
    if unknown:
        state['unclaimed_preparation_files'] = unknown


def _abort_preparation(job, state):
    _cleanup_preparation_blobs(job, state)
    state['phase'] = 'aborted_preparation'
    atomic_json(job, 'state.json', state)


def _stage_blob(job, stage, relative):
    # Persistent private copy: retry does not depend on the temporary export.
    name = 'blob-' + uuid.uuid4().hex
    with parent_at(stage, relative) as (src_fd, src_name), parent_at(job, name) as (dst_fd, dst_name):
        source = os.open(src_name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=src_fd)
        target = os.open(dst_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dst_fd)
        with os.fdopen(source, 'rb') as reader, os.fdopen(target, 'wb') as writer:
            _record_preparation_blob(job, name, writer.fileno(), dst_fd)
            if not stat.S_ISREG(os.fstat(reader.fileno()).st_mode):
                raise RegistryError('staged attachment must be a regular file')
            for chunk in iter(lambda: reader.read(CHUNK), b''):
                writer.write(chunk)
            writer.flush()
            os.fsync(writer.fileno())
        os.fsync(dst_fd)
    return name, file_info(job, name)['sha256']


def _bytes_blob(job, raw):
    name = 'blob-' + uuid.uuid4().hex
    with parent_at(job, name) as (fd, leaf):
        handle = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(handle, 'wb') as stream:
            _record_preparation_blob(job, name, stream.fileno(), fd)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.fsync(fd)
    return name, digest(raw)


def _check_attachment_links(markdown, stage, markdown_path, attachment_path, canonical):
    # The shipped attachment blocks use canonical inline URLs. Do not silently
    # leave alternate spellings, titles, or reference-style links dangling.
    targets = [(value, True) for value in re.findall(r'\]\(([^)]*)\)', markdown)]
    targets += [(value, False) for value in re.findall(r'^\s*\[[^]\r\n]+\]:\s*(.+)$', markdown, re.M)]
    expected = (stage / attachment_path).resolve()
    for value, inline in targets:
        match = re.match(r'(?:<([^>]+)>|(\S+))', value.strip())
        if not match:
            continue
        url = match.group(1) or match.group(2)
        try:
            parsed = urlsplit(url)
        except ValueError:
            continue  # malformed unrelated body URL is not a staged attachment reference
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        resolved = ((stage / markdown_path).parent / unquote(parsed.path)).resolve()
        if resolved == expected and (not inline or value != canonical):
            raise RegistryError('noncanonical attachment link; use a plain URL-encoded inline link')


def _prepare(registry, plan, manifest, job, job_id):
    root = plan['root_id']
    current = registry.snapshot(root)
    if (plan.get('registry_sha256') != registry.digest
            or plan.get('index_sha256') != current['index_sha256']):
        raise RegistryError('stale plan; re-plan before capture')
    items = plan.get('items')
    if not isinstance(items, list):
        raise RegistryError('plan items must be an array')
    actions = {}
    for item in items:
        if not isinstance(item, dict) or not _message_id(item.get('message_id')):
            raise RegistryError('invalid plan Message-ID')
        if item.get('action') == 'already_archived':
            if item['message_id'] not in current['history']:
                raise RegistryError('plan claims unknown ID is already archived')
            continue
        mid = item.get('message_id')
        destination = item.get('destination_target_id')
        if (item.get('action') != 'capture' or item.get('capture_target_id') != root
                or destination not in current['target_ids'] or mid in current['history'] or mid in actions):
            raise RegistryError('invalid or stale capture item')
        actions[mid] = destination
    if not isinstance(manifest, dict) or set(manifest) != {'stage_root', 'messages'}:
        raise RegistryError('manifest requires stage_root and messages')
    stage = Path(manifest['stage_root']).resolve(strict=True)
    messages = manifest['messages']
    if not isinstance(messages, list) or len(messages) != len(actions):
        raise RegistryError('manifest must contain exactly the new plan messages')
    indexes = {}
    for target in current['target_ids']:
        path = Path(registry.targets[target]['index_file'])
        indexes[target] = json.loads(read_bytes(path.parent, path.name), object_pairs_hook=_unique_object)
    captured = copy.deepcopy(indexes[root])
    destinations = copy.deepcopy(indexes)
    records, seen_ids, paths, blobs = [], set(), {}, []
    def path_key(value):
        return unicodedata.normalize('NFD', str(value)).casefold()
    historical_paths = {path_key(Path(registry.targets[target]['output_dir']) / entry['file'])
                        for target, index in indexes.items() for entry in index['emails'].values()}

    def add_file(target, anchor, relative, blob, sha, phase, retain):
        parts(relative)
        absolute = str(Path(_anchor_base(registry, target, anchor)) / relative)
        if path_key(absolute) in historical_paths:
            raise RegistryError('filename reserved by historical index entry, including tombstones')
        if absolute in paths:
            previous = records[paths[absolute]]
            if previous['sha256'] != sha:
                raise RegistryError('two bundle files conflict at the same destination')
            previous['retain'] |= retain
            if phase == 'intake_files':
                previous['phase'] = 'intake_files'
            return
        number = len(records)
        paths[absolute] = number
        records.append({'target_id': target, 'anchor': anchor, 'path': relative,
                        'blob': blob, 'sha256': sha, 'phase': phase, 'retain': retain,
                        'temp': str(Path(relative).with_name('.idd-' + job_id + '-' + str(number))),
                        'inode': None, 'temp_ready': False})

    for message in messages:
        if not isinstance(message, dict) or set(message) != {'message_id','markdown','filename','entry','attachments'}:
            raise RegistryError('invalid staged message fields')
        mid = message['message_id']
        if mid not in actions or mid in seen_ids:
            raise RegistryError('manifest IDs do not match the capture plan')
        seen_ids.add(mid)
        destination = actions[mid]
        filename = message['filename']
        if len(parts(filename)) != 1 or not filename.endswith('.md'):
            raise RegistryError('archive filename must be a single .md segment')
        raw = read_bytes(stage, message['markdown']).decode('utf-8')
        front = re.match(r'\A---\r?\n(.*?)\r?\n---(?:\r?\n|$)', raw, re.S)
        if not front:
            raise RegistryError('staged markdown needs frontmatter')
        front_text = front[1].replace('\r\n', '\n')
        ids = re.findall(r'^message_id:\s*"([^"\r\n]+)"\s*$', front_text, re.M)
        if ids != [mid]:
            raise RegistryError('staged markdown Message-ID mismatch')
        entry = message['entry']
        if not isinstance(entry, dict) or set(entry) != {'date','subject','thread_key'} or any(not isinstance(v,str) for v in entry.values()):
            raise RegistryError('entry requires date, subject and thread_key strings')
        dates = re.findall(r'^date:[ \t]*(.*?)[ \t]*$', front_text, re.M)
        threads = re.findall(r'^thread_key:[ \t]*"(.*)"[ \t]*$', front_text, re.M)
        if dates != [entry['date']] or threads != [entry['thread_key']]:
            raise RegistryError('entry date/thread_key must match staged frontmatter')
        attachments = message['attachments']
        if not isinstance(attachments, list):
            raise RegistryError('attachments must be an array, including empty')
        variants = {root: raw, destination: raw}
        replacements = {target: {} for target in variants}
        for attachment in attachments:
            if not isinstance(attachment, dict) or set(attachment) != {'file','intake_path','destination_path'}:
                raise RegistryError('attachment requires file/intake_path/destination_path')
            blob, sha = _stage_blob(job, stage, attachment['file'])
            blobs.append(blob)
            old = quote(os.path.relpath(stage / attachment['file'], (stage / message['markdown']).parent), safe='/')
            marker = '](' + old + ')'
            _check_attachment_links(raw, stage, message['markdown'], attachment['file'], old)
            if marker not in raw:
                raise RegistryError('attachment is not linked in the staged markdown')
            for target in variants:
                relative = attachment['intake_path'] if target == root else attachment['destination_path']
                anchor, relative = _asset_location(registry, target, relative)
                asset = Path(_anchor_base(registry, target, anchor)) / relative
                new = quote(os.path.relpath(asset, registry.targets[target]['output_dir']), safe='/')
                if marker in replacements[target]:
                    raise RegistryError('duplicate attachment link mapping')
                replacements[target][marker] = '](' + new + ')'
                add_file(target, anchor, relative, blob, sha,
                         'intake_files' if target == root else 'destination_files', target == destination)
        for target in variants:
            # One regex pass avoids cascading replacement when URLs overlap.
            mapping = replacements[target]
            text = re.sub('|'.join(re.escape(k) for k in mapping), lambda m: mapping[m[0]], raw) if mapping else raw
            blob, sha = _bytes_blob(job, text.encode())
            blobs.append(blob)
            add_file(target, 'output_dir', filename, blob, sha,
                     'intake_files' if target == root else 'destination_files', target == destination)
        copied = {**entry, 'file': filename, 'capture_run_id': job_id}
        captured['emails'][mid] = copied
        if destination != root:
            destinations[destination]['emails'][mid] = copied
    final_root = copy.deepcopy(captured)
    for mid, destination in actions.items():
        if destination != root:
            final_root['emails'][mid]['distributed_to'] = {
                'target_id': destination, 'file': captured['emails'][mid]['file'], 'run_id': job_id}
    changed = sorted(set(actions.values()) - {root})
    ops = {
        'intake_index': [_index_op(registry, root, current['index_sha256'][root], captured)],
        'destination_indexes': [_index_op(registry, t, current['index_sha256'][t], destinations[t]) for t in changed],
        'tombstones': [_index_op(registry, root, digest(encoded(captured)), final_root)]}
    return {'version': 1, 'job_id': job_id, 'root_id': root, 'registry_sha256': registry.digest,
            'phase': 'prepared', 'files': records, 'ops': ops, 'blobs': blobs,
            'preparation_blobs': state_read(job)['preparation_blobs'],
            'scope_sha256': current['index_sha256'],
            'reconcile_targets': sorted({root, *changed})}


def _publish(registry, job, state, record):
    base = _file_base(registry, record)
    if record['inode'] is None:
        with parent_at(base, record['temp'], create=True) as (fd, temp):
            try:
                handle = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            except FileExistsError:
                # Crash before ownership was journaled: leave the unknown temp
                # untouched and allocate a fresh one, never adopt by hash alone.
                state.setdefault('unclaimed_temps', []).append({
                    'target_id': record['target_id'], 'anchor': record['anchor'], 'path': record['temp']})
                record['temp'] = str(Path(record['path']).with_name('.idd-' + state['job_id'] + '-' + uuid.uuid4().hex))
                atomic_json(job, 'state.json', state)
                return _publish(registry, job, state, record)
            info = os.fstat(handle)
            record['inode'] = [info.st_dev, info.st_ino]
            try:
                os.fsync(handle)
                os.fsync(fd)
                atomic_json(job, 'state.json', state)  # inode AND dir entry durable before journal
            finally:
                os.close(handle)
    if not record['temp_ready']:
        with parent_at(base, record['temp']) as (fd, temp):
            handle = os.open(temp, os.O_WRONLY | os.O_NOFOLLOW, dir_fd=fd)
            with os.fdopen(handle, 'wb') as writer:
                info = os.fstat(writer.fileno())
                if [info.st_dev, info.st_ino] != record['inode'] or info.st_nlink != 1:
                    raise RegistryError('unfinished temporary file ownership changed')
                writer.truncate(0)
                with parent_at(job, record['blob']) as (src_fd, blob):
                    source = os.open(blob, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=src_fd)
                    with os.fdopen(source, 'rb') as reader:
                        for chunk in iter(lambda: reader.read(CHUNK), b''):
                            writer.write(chunk)
                writer.flush()
                os.fsync(writer.fileno())
            os.fsync(fd)
        info = file_info(base, record['temp'])
        if info['sha256'] != record['sha256'] or info['inode'] != record['inode']:
            raise RegistryError('temporary copy failed verification')
        record['temp_ready'] = True
        atomic_json(job, 'state.json', state)
    with parent_at(base, record['path'], create=True) as (fd, name), parent_at(base, record['temp']) as (tmp_fd, temp):
        try:
            os.link(temp, name, src_dir_fd=tmp_fd, dst_dir_fd=fd, follow_symlinks=False)
            os.fsync(fd)
        except FileExistsError:
            pass
    _verify_file(registry, record)


def _verify_file(registry, record):
    info = file_info(_file_base(registry, record), record['path'])
    if info['sha256'] != record['sha256'] or info['inode'] != record['inode']:
        raise RegistryError('archive file exists but is not this job\'s unchanged file')


def _update_index(registry, operation):
    path = Path(registry.targets[operation['target_id']]['index_file'])
    actual = digest(read_bytes(path.parent, path.name))
    after = digest(encoded(operation['after']))
    if actual == after:
        return
    if actual != operation['before_sha256']:
        raise RegistryError('index changed outside this transaction; manual reconciliation required')
    atomic_json(path.parent, path.name, operation['after'])


def _verify_destinations(registry, state):
    for record in state['files']:
        if record['retain']:
            _verify_file(registry, record)
    for operation in state['ops']['destination_indexes']:
        path = Path(registry.targets[operation['target_id']]['index_file'])
        if digest(read_bytes(path.parent, path.name)) != digest(encoded(operation['after'])):
            raise RegistryError('destination index changed before source cleanup')


def _validate_scope(registry, state):
    allowed = {target: {sha} for target, sha in state['scope_sha256'].items()}
    for operations in state['ops'].values():
        for operation in operations:
            allowed[operation['target_id']].add(digest(encoded(operation['after'])))
    for target, hashes in allowed.items():
        path = Path(registry.targets[target]['index_file'])
        if digest(read_bytes(path.parent, path.name)) not in hashes:
            raise RegistryError('scope index changed outside this transaction: ' + target)


def _verify_tombstones(registry, state):
    for operation in state['ops']['tombstones']:
        path = Path(registry.targets[operation['target_id']]['index_file'])
        if digest(read_bytes(path.parent, path.name)) != digest(encoded(operation['after'])):
            raise RegistryError('source index changed before cleanup')


def _finish(registry, job, state):
    _verify_destinations(registry, state)
    _verify_tombstones(registry, state)
    for record in state['files']:
        base = _file_base(registry, record)
        try:
            info = file_info(base, record['temp'])
        except FileNotFoundError:
            continue
        if info['inode'] != record['inode'] or info['sha256'] != record['sha256']:
            raise RegistryError('temporary file changed; refusing cleanup')
        with parent_at(base, record['temp']) as (fd, name):
            os.unlink(name, dir_fd=fd)
            os.fsync(fd)
    _cleanup_preparation_blobs(job, state)


PHASES = ['prepared','intake_files','intake_index','destination_files',
          'destination_indexes','tombstones','source_cleanup','complete']


def _advance(registry, job, state, checkpoint):
    if state['registry_sha256'] != registry.digest:
        raise RegistryError('registry changed; cannot resume against different paths')
    if state['phase'] == 'complete':
        return state
    start = PHASES.index(state['phase']) + 1
    for phase in PHASES[start:]:
        _validate_scope(registry, state)
        if phase.endswith('_files'):
            for record in state['files']:
                if record['phase'] == phase:
                    _publish(registry, job, state, record)
        elif phase in state['ops']:
            if phase == 'tombstones':
                _verify_destinations(registry, state)
            for operation in state['ops'][phase]:
                _update_index(registry, operation)
        elif phase == 'source_cleanup':
            _verify_destinations(registry, state)
            _verify_tombstones(registry, state)
            for record in state['files']:
                if record['retain']:
                    continue
                base = _file_base(registry, record)
                try:
                    _verify_file(registry, record)
                except FileNotFoundError:
                    continue
                with parent_at(base, record['path']) as (fd, name):
                    os.unlink(name, dir_fd=fd)
                    os.fsync(fd)
        elif phase == 'complete':
            _finish(registry, job, state)
        checkpoint(phase, state['job_id'])  # crash AFTER operation, BEFORE phase commit
        state['phase'] = phase
        atomic_json(job, 'state.json', state)
    return state


def _result(state):
    result = {key: state[key] for key in ['job_id','root_id','phase','reconcile_targets']}
    result['reconcile_required'] = True
    if state.get('unclaimed_temps'):
        result['unclaimed_temps'] = state['unclaimed_temps']
    if state.get('unclaimed_preparation_files'):
        result['unclaimed_preparation_files'] = state['unclaimed_preparation_files']
    if state.get('prior_preparation_cleanup'):
        result['prior_preparation_cleanup'] = state['prior_preparation_cleanup']
    return result


def execute(registry_path, plan, manifest, checkpoint=lambda phase, job: None):
    registry = Registry.load(registry_path)
    root = plan['root_id']
    if registry.ancestors(root)[-1] != root:
        raise RegistryError('plan root must be the organizational root')
    with tree_lock(registry, root) as journals:
        prior_cleanup = []
        if Registry.load(registry_path).digest != registry.digest:
            raise RegistryError('registry changed before capture')
        if journals.exists():
            for previous in journals.iterdir():
                if previous.is_dir():
                    try:
                        previous_state = state_read(previous)
                    except FileNotFoundError:
                        continue  # unprepared private blobs: no archive writes can have occurred
                    if previous_state['phase'] in {'preparing', 'aborted_preparation'}:
                        _abort_preparation(previous, previous_state)
                        if previous_state.get('unclaimed_preparation_files'):
                            prior_cleanup.append({'job_id': previous.name, 'unclaimed_preparation_files': previous_state['unclaimed_preparation_files']})
                    if previous_state['phase'] not in {'complete', 'aborted_preparation'}:
                        raise RegistryError('unfinished distribution; resume job ' + previous.name)
        # Reject stale plans before creating a journal or any archive file.
        current = registry.snapshot(root)
        if plan.get('registry_sha256') != registry.digest or plan.get('index_sha256') != current['index_sha256']:
            raise RegistryError('stale plan; re-plan before capture')
        job_id = uuid.uuid4().hex
        job = journals / job_id
        with parent_at(journals, job_id, create=True) as (fd, name):
            os.mkdir(name, 0o700, dir_fd=fd)
            os.fsync(fd)
        atomic_json(job, 'state.json', {'version': 1, 'job_id': job_id, 'root_id': root,
                                      'phase': 'preparing', 'preparation_blobs': []})
        try:
            state = _prepare(registry, plan, manifest, job, job_id)
            state['prior_preparation_cleanup'] = prior_cleanup
        except Exception:
            _abort_preparation(job, state_read(job))
            raise
        atomic_json(job, 'state.json', state)
        checkpoint('prepared', job_id)
        try:
            return _result(_advance(registry, job, state, checkpoint))
        except (RegistryError, OSError) as error:
            raise DistributionError(error, state) from error


def resume(registry_path, job_id, checkpoint=lambda phase, job: None):
    if not isinstance(job_id, str) or not re.fullmatch(r'[0-9a-f]{32}', job_id):
        raise RegistryError('invalid job id')
    registry = Registry.load(registry_path)
    roots = [t for t in registry.targets if registry.targets[t]['parent_id'] is None]
    matches = [(root, Path(registry.targets[root]['index_file']).parent / 'archive-dispatch' / job_id)
               for root in roots]
    matches = [(root, path) for root, path in matches if path.is_dir()]
    if len(matches) != 1:
        raise RegistryError('job missing or ambiguous')
    root, job = matches[0]
    with tree_lock(registry, root):
        state = state_read(job)
        if state.get('phase') in {'preparing', 'aborted_preparation'}:
            _abort_preparation(job, state)
            raise RegistryError('preparation aborted before archive writes; submit a corrected new plan')
        if state['job_id'] != job_id or state['root_id'] != root:
            raise RegistryError('journal identity mismatch')
        try:
            return _result(_advance(registry, job, state, checkpoint))
        except (RegistryError, OSError) as error:
            raise DistributionError(error, state) from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--registry', type=Path, default=Path.home()/'.claude/.mail/archives.json')
    sub = parser.add_subparsers(dest='command', required=True)
    apply = sub.add_parser('execute')
    apply.add_argument('--plan', type=Path, required=True)
    apply.add_argument('--manifest', type=Path, required=True)
    retry = sub.add_parser('resume')
    retry.add_argument('--job-id', required=True)
    args = parser.parse_args(argv)
    try:
        result = (execute(args.registry, read_json(args.plan)[0], read_json(args.manifest)[0])
                  if args.command == 'execute' else resume(args.registry, args.job_id))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (RegistryError, OSError, ValueError, KeyError, TypeError) as error:
        response = {'error': str(error)}
        if isinstance(error, DistributionError):
            response.update(job_id=error.job_id, phase=error.phase)
        print(json.dumps(response, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == '__main__': sys.exit(main())
