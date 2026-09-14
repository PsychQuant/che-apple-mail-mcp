#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/archive_registry.py'
spec = importlib.util.spec_from_file_location('archive_registry', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
Registry, RegistryError = module.Registry, module.RegistryError


class ArchiveRegistryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.data = {'version': 1, 'targets': []}
        for tid, parent in [('root', None), ('a', 'root'), ('b', 'root'), ('leaf', 'a'), ('other', None)]:
            directory = self.base / tid
            directory.mkdir()
            (directory / 'output').mkdir()
            (directory / 'config.yaml').write_text('filters: []\n')
            (directory / 'index.json').write_text(json.dumps({'version': '1.0', 'emails': {}}))
            self.data['targets'].append({
                'id': tid, 'parent_id': parent, 'workspace': str(directory),
                'config_file': str(directory / 'config.yaml'), 'output_dir': str(directory / 'output'),
                'index_file': str(directory / 'index.json'), 'purpose': tid, 'filter_axis': 'descriptive only'})
        self.registry_path = self.base / 'archives.json'
        self.save_registry()

    def save_registry(self):
        self.registry_path.write_text(json.dumps(self.data))

    def index(self, tid, emails):
        (self.base / tid / 'index.json').write_text(json.dumps({'version': '1.0', 'emails': emails}))

    def candidate(self, mid, matches):
        return {'message_id': mid, 'matched_target_ids': matches}

    def test_organizational_tree_ignores_sibling_directory_layout(self):
        registry = Registry.load(self.registry_path)
        self.assertEqual(registry.ancestors('leaf'), ['leaf', 'a', 'root'])
        self.assertEqual(registry.component('a'), ('root', ['a', 'b', 'leaf', 'root']))
        self.assertEqual(len(registry.inventory()), 5)

    def test_377_index_entries_27_files_all_history_prevents_recapture(self):
        entries = {f'<m{i}@example.invalid>': {'file': f'{i}.md', 'date': '2026-08-10'} for i in range(377)}
        self.index('root', entries)
        for i in range(27):
            (self.base / 'root/output' / f'{i}.md').write_text('body')
        registry = Registry.load(self.registry_path)
        snapshot = registry.snapshot('a')
        self.assertEqual(snapshot['unique_message_ids'], 377)
        self.assertEqual(snapshot['historical_index_only'], 350)
        plan = registry.plan(snapshot, [self.candidate(mid, ['a']) for mid in entries])
        self.assertEqual({row['action'] for row in plan['items']}, {'already_archived'})
        self.assertEqual(len(plan['items']), 377)

    def test_child_only_candidate_is_captured_and_routed(self):
        registry = Registry.load(self.registry_path)
        result = registry.plan(registry.snapshot('leaf'), [self.candidate('<only-child@example.invalid>', ['leaf'])])
        item = result['items'][0]
        self.assertEqual(item['action'], 'capture')
        self.assertEqual(item['capture_target_id'], 'root')
        self.assertEqual(item['destination_target_id'], 'leaf')
        self.assertEqual(result['execution_status'], 'planning_only')

    def test_ambiguity_no_match_and_ancestor_chain(self):
        registry = Registry.load(self.registry_path)
        result = registry.plan(registry.snapshot('root'), [
            self.candidate('<one@example.invalid>', ['a', 'b']),
            self.candidate('<two@example.invalid>', []),
            self.candidate('<three@example.invalid>', ['root', 'a', 'leaf'])])['items']
        self.assertEqual([(r['destination_target_id'], r['reason']) for r in result],
                         [('root', 'ambiguous_intake'), ('root', 'unclassified_intake'), ('leaf', 'confirmed_match')])

    def test_multiple_historical_locations_are_not_collapsed_to_fake_owner(self):
        entry = {'<m@example.invalid>': {'file': 'm.md'}}
        self.index('a', entry)
        self.index('root', entry)
        snap = Registry.load(self.registry_path).snapshot('a')
        self.assertEqual(snap['unique_message_ids'], 1)
        self.assertEqual({r['target_id'] for r in snap['history']['<m@example.invalid>']}, {'a', 'root'})

    def test_missing_and_corrupt_scope_index_refuse_partial_snapshot(self):
        path = self.base / 'b/index.json'
        path.unlink()
        with self.assertRaises(RegistryError): Registry.load(self.registry_path).snapshot('a')
        path.write_text('{broken')
        with self.assertRaises(RegistryError): Registry.load(self.registry_path).snapshot('a')
        path.write_text('{"version":"1.0","emails":[]}')
        with self.assertRaises(RegistryError): Registry.load(self.registry_path).snapshot('a')

    def test_unrelated_missing_path_reported_but_not_part_of_selected_snapshot(self):
        (self.base / 'other/index.json').unlink()
        registry = Registry.load(self.registry_path)
        self.assertEqual(registry.snapshot('a')['unique_message_ids'], 0)
        other = next(t for t in registry.inventory() if t['id'] == 'other')
        self.assertTrue(other['errors'])

    def test_invalid_schema_cycles_parent_and_ids(self):
        for mutate in [
            lambda d: d.update(version=True),
            lambda d: d.update(extra=1),
            lambda d: d['targets'][0].update(parent_id='leaf'),
            lambda d: d['targets'][0].update(parent_id='missing'),
            lambda d: d['targets'][1].update(id='root'),
            lambda d: d['targets'][0].update(output_dir='relative'),
            lambda d: d['targets'][0].update(own_addresses=[]),
        ]:
            with self.subTest(mutate=mutate):
                d = copy.deepcopy(self.data)
                mutate(d)
                with self.assertRaises(RegistryError): Registry(d)

    def test_symlink_alias_to_shared_index_is_rejected(self):
        alias = self.base / 'index-alias.json'
        alias.symlink_to(self.base / 'root/index.json')
        self.data['targets'][1]['index_file'] = str(alias)
        with self.assertRaises(RegistryError): Registry(self.data)

    def test_hard_link_and_cross_role_shared_files_are_rejected(self):
        import os
        path = self.base / 'a/index.json'
        path.unlink()
        os.link(self.base / 'root/index.json', path)
        with self.assertRaises(RegistryError): Registry(self.data)
        path.unlink()
        path.write_text('{"version":"1.0","emails":{}}')
        self.data['targets'][1]['config_file'] = str(self.base / 'root/index.json')
        with self.assertRaises(RegistryError): Registry(self.data)

    def test_case_alias_to_same_existing_file_is_rejected(self):
        alias = self.base / 'root/INDEX.JSON'
        if not alias.is_file():
            self.skipTest('case-sensitive filesystem has distinct names')
        self.data['targets'][1]['index_file'] = str(alias)
        with self.assertRaises(RegistryError): Registry(self.data)

    def test_duplicate_json_keys_fail_loudly(self):
        self.registry_path.write_text('{"version":1,"version":1,"targets":[]}')
        with self.assertRaises(RegistryError): Registry.load(self.registry_path)
        self.save_registry()
        (self.base / 'a/index.json').write_text('{"version":"1.0","emails":{"<a@b>":{},"<a@b>":{}}}')
        with self.assertRaises(RegistryError): Registry.load(self.registry_path).snapshot('a')

    def test_escaping_index_paths_and_bad_message_ids_rejected(self):
        for entries in [
            {'<a@b>': {'file': '../outside.md'}},
            {'<a@b>': {'file': '/outside.md'}},
            {'not-a-message-id': {'file': 'a.md'}},
            {'<a@b>': []},
        ]:
            self.index('a', entries)
            with self.assertRaises(RegistryError): Registry.load(self.registry_path).snapshot('a')
        (self.base / 'a/output/escape.md').symlink_to(self.base / 'other/config.yaml')
        self.index('a', {'<a@b>': {'file': 'escape.md'}})
        with self.assertRaises(RegistryError): Registry.load(self.registry_path).snapshot('a')

    def test_candidate_outside_tree_duplicates_and_wrong_types_rejected(self):
        registry = Registry.load(self.registry_path)
        snapshot = registry.snapshot('root')
        for rows in [[self.candidate('<a@b>', ['other'])], [self.candidate('<a@b>', [True])],
                     [self.candidate('<a@b>', ['a', 'a'])], [self.candidate('<a@b>', [])] * 2]:
            with self.assertRaises(RegistryError): registry.plan(snapshot, rows)

    def test_fingerprints_change_when_index_bytes_change(self):
        registry = Registry.load(self.registry_path)
        before = registry.snapshot('a')['index_sha256']
        self.index('a', {'<a@b>': {'file': 'a.md'}})
        self.assertNotEqual(before, registry.snapshot('a')['index_sha256'])

    def test_shared_index_directory_is_rejected(self):
        path=self.base/'root/second-index.json'
        path.write_text('{"version":"1.0","emails":{}}')
        self.data['targets'][1]['index_file']=str(path)
        with self.assertRaisesRegex(RegistryError,'index directories'):
            Registry(self.data)

    def test_cli_match_missing_unregistered_registered_and_corrupt(self):
        command=[sys.executable,str(SCRIPT),'--registry',str(self.registry_path),'match',
                 '--workspace',str(self.base/'root'),'--output-dir',str(self.base/'root/output')]
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['target_id'],'root')
        self.registry_path.unlink()
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertEqual(json.loads(result.stdout)['reason'],'registry_absent')
        self.registry_path.write_text('{bad')
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.save_registry()
        command[-1]=str(self.base/'not-registered')
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertEqual(json.loads(result.stdout)['reason'],'target_unregistered')

    def test_shipped_rebuild_recipe_honors_explicit_index_directory(self):
        import os,re
        document=SCRIPT.parents[1]/'commands/archive-mail-rebuild-threads.md'
        section=document.read_text().split('### Step 2:',1)[1].split('### Step 3:',1)[0]
        code=re.search(r'```bash\n(.*?)\n```',section,re.S)[1]
        custom=self.base/'custom-state'
        env=dict(os.environ,INDEX_DIR_OVERRIDE=str(custom),archive_dir=str(self.base/'root/output'))
        code+='\nexport THREADS_FILE\npython3 -c \'import os; print(os.environ["THREADS_FILE"])\''
        run=subprocess.run(['bash','-c',code],cwd=self.base,env=env,capture_output=True,text=True,check=True)
        self.assertEqual(run.stdout.strip(),str(custom/'threads.json'))
        self.assertTrue(custom.is_dir())
        self.assertFalse((self.base/'.claude').exists())

    def test_cli_reads_only_and_reports_json_errors(self):
        before = {str(p): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        command = [sys.executable, str(SCRIPT), '--registry', str(self.registry_path)]
        success = subprocess.run(command + ['snapshot', '--target', 'a'], capture_output=True, text=True)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(json.loads(success.stdout)['root_id'], 'root')
        error = subprocess.run(command + ['snapshot', '--target', 'unknown'], capture_output=True, text=True)
        self.assertEqual(error.returncode, 2)
        self.assertIn('error', json.loads(error.stderr))
        after = {str(p): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        self.assertEqual(before, after)


if __name__ == '__main__':
    unittest.main()
