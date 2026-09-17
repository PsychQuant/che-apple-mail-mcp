#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
from archive_registry import Registry, RegistryError
from archive_distribution import execute, resume


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        targets = []
        for tid, parent in [('root', None), ('child', 'root')]:
            p = self.base / tid
            p.mkdir()
            (p / 'mail').mkdir()
            (p / 'config.yaml').write_text('filters: []\n')
            (p / 'index.json').write_text(json.dumps({'version':'1.0','emails':{}}))
            targets.append(dict(id=tid,parent_id=parent,workspace=str(p),config_file=str(p/'config.yaml'),
                                output_dir=str(p/'mail'),index_file=str(p/'index.json'),purpose=tid,filter_axis='test'))
        self.registry = self.base / 'archives.json'
        self.registry.write_text(json.dumps({'version':1,'targets':targets}))
        self.stage = self.base / 'stage'
        self.stage.mkdir()
        (self.stage / 'asset.csv').write_bytes(b'a,b\n1,2\n')
        (self.stage / 'mail.md').write_text('---\nmessage_id: "<m@example.invalid>"\nthread_key: "topic"\nin_reply_to: ""\ndate: 2026-09-14\nsender: sender@example.invalid\ndirection: received\n---\n\nSubject: topic\nFrom: sender@example.invalid\nTo: user@example.invalid\n\nverbatim body\n\nAttachments:\n- [asset](asset.csv)\n')
        self.manifest = {'stage_root':str(self.stage),'messages':[{
            'message_id':'<m@example.invalid>','markdown':'mail.md','filename':'mail.md',
            'entry':{'date':'2026-09-14','subject':'topic','thread_key':'topic'},
            'attachments':[{'file':'asset.csv','intake_path':'data/asset.csv','destination_path':'assets/asset.csv'}]}]}
        r = Registry.load(self.registry)
        self.plan = r.plan(r.snapshot('root'), [{'message_id':'<m@example.invalid>','matched_target_ids':['child']}])

    def state(self, tid):
        return json.loads((self.base/tid/'index.json').read_text())['emails']

    def assert_complete(self):
        self.assertFalse((self.base/'root/mail/mail.md').exists())
        self.assertFalse((self.base/'root/data/asset.csv').exists())
        self.assertTrue((self.base/'child/mail/mail.md').is_file())
        self.assertEqual((self.base/'child/assets/asset.csv').read_bytes(),b'a,b\n1,2\n')
        self.assertIn('](../assets/asset.csv)',(self.base/'child/mail/mail.md').read_text())
        self.assertEqual(self.state('root')['<m@example.invalid>']['distributed_to']['target_id'],'child')
        self.assertIn('<m@example.invalid>',self.state('child'))
        r=Registry.load(self.registry)
        self.assertEqual(r.plan(r.snapshot('child'),[{'message_id':'<m@example.invalid>','matched_target_ids':['child']}])['items'][0]['action'],'already_archived')

    def test_complete_distribution_preserves_content_attachments_and_history(self):
        result=execute(self.registry,self.plan,self.manifest)
        self.assertEqual(result['phase'],'complete')
        self.assertEqual(set(result['reconcile_targets']),{'root','child'})
        self.assert_complete()
        self.assertEqual(resume(self.registry,result['job_id'])['phase'],'complete')

    def test_recovery_at_every_durable_phase(self):
        # Separate fixture per phase: no second execution against prior history.
        for phase in ['prepared','intake_files','intake_index','destination_files','destination_indexes','tombstones','source_cleanup']:
            with self.subTest(phase=phase):
                self.tearDown()
                self.setUp()
                job=[]
                def fail(name, job_id):
                    job[:]=[job_id]
                    if name==phase: raise RuntimeError('injected')
                with self.assertRaisesRegex(RuntimeError,'injected'):
                    execute(self.registry,self.plan,self.manifest,checkpoint=fail)
                self.assertEqual(resume(self.registry,job[0])['phase'],'complete')
                self.assert_complete()

    def test_destination_failure_retains_intake(self):
        jobs=[]
        def fail(phase,job):
            jobs[:]=[job]
            if phase=='intake_index': raise RuntimeError('stop')
        with self.assertRaises(RuntimeError): execute(self.registry,self.plan,self.manifest,checkpoint=fail)
        target=self.base/'child/mail/mail.md'; target.write_text('user file')
        with self.assertRaises(RegistryError): resume(self.registry,jobs[0])
        self.assertEqual(target.read_text(),'user file')
        self.assertTrue((self.base/'root/mail/mail.md').is_file())
        self.assertNotIn('distributed_to',self.state('root')['<m@example.invalid>'])

    def test_stale_plan_and_invalid_bundle_write_no_archive_files(self):
        (self.base/'child/index.json').write_text('{"version":"1.0","emails":{},"changed":true}')
        with self.assertRaises(RegistryError): execute(self.registry,self.plan,self.manifest)
        self.assertFalse((self.base/'root/mail/mail.md').exists())

    def test_source_edit_after_tombstone_is_not_deleted(self):
        jobs=[]
        def fail(phase,job):
            jobs[:]=[job]
            if phase=='tombstones': raise RuntimeError('stop')
        with self.assertRaises(RuntimeError): execute(self.registry,self.plan,self.manifest,checkpoint=fail)
        source=self.base/'root/mail/mail.md'; source.write_text('user edit')
        with self.assertRaises(RegistryError): resume(self.registry,jobs[0])
        self.assertEqual(source.read_text(),'user edit')
        self.assertTrue((self.base/'child/mail/mail.md').exists())

    def prepared_job(self):
        jobs=[]
        def stop(phase, job):
            jobs[:]=[job]
            if phase=='prepared': raise RuntimeError('stop')
        with self.assertRaises(RuntimeError): execute(self.registry,self.plan,self.manifest,checkpoint=stop)
        directory=self.base/'root/archive-dispatch'/jobs[0]
        return jobs[0],directory,json.loads((directory/'state.json').read_text())

    def test_resume_rewrites_only_owned_incomplete_temp(self):
        import os
        from archive_distribution import atomic_json
        job,directory,state=self.prepared_job()
        record=state['files'][0]
        anchor=self.base/record['target_id']
        if record['anchor']=='output_dir': anchor=anchor/'mail'
        temp=anchor/record['temp'];temp.parent.mkdir(parents=True,exist_ok=True)
        temp.write_bytes(b'partial')
        info=temp.stat();record['inode']=[info.st_dev,info.st_ino]
        atomic_json(directory,'state.json',state)
        resume(self.registry,job)
        self.assert_complete()
        self.assertFalse(temp.exists())

    def test_unclaimed_temp_is_not_adopted_or_deleted(self):
        job,directory,state=self.prepared_job()
        record=state['files'][0]
        anchor=self.base/record['target_id']
        if record['anchor']=='output_dir': anchor=anchor/'mail'
        temp=anchor/record['temp'];temp.parent.mkdir(parents=True,exist_ok=True)
        temp.write_bytes(b'user temp')
        resume(self.registry,job)
        self.assert_complete()
        self.assertEqual(temp.read_bytes(),b'user temp')

    def test_busy_tree_rejects_second_writer(self):
        import fcntl
        lock=self.base/'root/.archive-registry.lock'
        with lock.open('wb') as handle:
            fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaisesRegex(RegistryError,'busy'):
                execute(self.registry,self.plan,self.manifest)
        self.assertFalse((self.base/'root/mail/mail.md').exists())

    def test_bad_preparation_does_not_block_corrected_execution(self):
        self.manifest['messages'][0]['message_id']='<wrong@example.invalid>'
        with self.assertRaises(RegistryError): execute(self.registry,self.plan,self.manifest)
        self.manifest['messages'][0]['message_id']='<m@example.invalid>'
        execute(self.registry,self.plan,self.manifest)
        self.assert_complete()

    def test_index_change_during_run_is_preserved_and_source_retained(self):
        jobs=[]
        def stop(phase,job):
            jobs[:]=[job]
            if phase=='intake_index': raise RuntimeError('stop')
        with self.assertRaises(RuntimeError): execute(self.registry,self.plan,self.manifest,checkpoint=stop)
        path=self.base/'child/index.json'
        changed={'version':'1.0','emails':{},'user_change':True}
        path.write_text(json.dumps(changed))
        with self.assertRaises(RegistryError): resume(self.registry,jobs[0])
        self.assertEqual(json.loads(path.read_text()),changed)
        self.assertTrue((self.base/'root/mail/mail.md').exists())

    def test_success_removes_owned_temporaries_and_sealed_blobs(self):
        result=execute(self.registry,self.plan,self.manifest)
        self.assertEqual(list((self.base/'root').rglob('.idd-*')),[])
        self.assertEqual(list((self.base/'child').rglob('.idd-*')),[])
        self.assertEqual(list((self.base/'root/archive-dispatch'/result['job_id']).glob('blob-*')),[])

    def test_stage_symlinks_and_escaping_asset_paths_refused(self):
        (self.stage/'asset.csv').unlink()
        (self.stage/'asset.csv').symlink_to(self.base/'child/config.yaml')
        with self.assertRaises(OSError): execute(self.registry,self.plan,self.manifest)
        self.assertFalse((self.base/'root/mail/mail.md').exists())
        (self.stage/'asset.csv').unlink();(self.stage/'asset.csv').write_bytes(b'asset')
        self.manifest['messages'][0]['attachments'][0]['intake_path']='../outside.csv'
        with self.assertRaises(RegistryError): execute(self.registry,self.plan,self.manifest)
        self.assertFalse((self.base/'outside.csv').exists())

    def test_resume_checks_unchanged_sibling_history(self):
        config=json.loads(self.registry.read_text())
        sibling=self.base/'sibling';sibling.mkdir();(sibling/'mail').mkdir()
        (sibling/'config.yaml').write_text('filters: []')
        (sibling/'index.json').write_text('{"version":"1.0","emails":{}}')
        config['targets'].append(dict(id='sibling',parent_id='root',workspace=str(sibling),
            config_file=str(sibling/'config.yaml'),output_dir=str(sibling/'mail'),index_file=str(sibling/'index.json'),
            purpose='sibling',filter_axis='test'))
        self.registry.write_text(json.dumps(config))
        r=Registry.load(self.registry)
        self.plan=r.plan(r.snapshot('root'),[{'message_id':'<m@example.invalid>','matched_target_ids':['child']}])
        job,_,_=self.prepared_job()
        (sibling/'index.json').write_text(json.dumps({'version':'1.0','emails':{'<m@example.invalid>':{'file':'m.md'}}}))
        with self.assertRaisesRegex(RegistryError,'index'):
            resume(self.registry,job)
        self.assertFalse((self.base/'root/mail/mail.md').exists())

    def test_attachment_noncanonical_link_is_rejected_before_capture(self):
        original=(self.stage/'mail.md').read_text()
        for extra in ['[another](./asset.csv)', '[another](asset.csv "title")', '[ref]: asset.csv']:
            (self.stage/'mail.md').write_text(original+'\n'+extra+'\n')
            with self.assertRaises(RegistryError): execute(self.registry,self.plan,self.manifest)
            self.assertFalse((self.base/'root/mail/mail.md').exists())

    def test_temp_file_and_directory_synced_before_ownership_journal(self):
        import os,stat
        from unittest.mock import patch
        import archive_distribution as dist
        job,directory,state=self.prepared_job()
        record=state['files'][0]
        events=[]
        real_fsync=dist.os.fsync;real_atomic=dist.atomic_json
        def synced(fd):
            events.append('directory' if stat.S_ISDIR(os.fstat(fd).st_mode) else 'file')
            return real_fsync(fd)
        def saved(base,name,data):
            if record['inode'] is not None and not record['temp_ready']:
                self.assertEqual(events[-2:],['file','directory'])
            return real_atomic(base,name,data)
        with patch.object(dist.os,'fsync',synced),patch.object(dist,'atomic_json',saved):
            dist._publish(Registry.load(self.registry),directory,state,record)

    def test_shared_asset_is_published_before_intake_index(self):
        import copy
        config=json.loads(self.registry.read_text())
        config['targets'][1]['workspace']=str(self.base/'root')
        self.registry.write_text(json.dumps(config))
        first=self.manifest['messages'][0]
        first['attachments'][0].update(intake_path='root-only.csv',destination_path='shared.csv')
        second=copy.deepcopy(first)
        second.update(message_id='<second@example.invalid>',markdown='mail2.md',filename='mail2.md')
        second['attachments'][0].update(intake_path='shared.csv',destination_path='child-only.csv')
        (self.stage/'mail2.md').write_text((self.stage/'mail.md').read_text().replace('<m@example.invalid>','<second@example.invalid>'))
        self.manifest['messages'].append(second)
        r=Registry.load(self.registry)
        self.plan=r.plan(r.snapshot('root'),[{'message_id':m['message_id'],'matched_target_ids':['child']} for m in self.manifest['messages']])
        def verify(phase,job):
            if phase=='intake_index': self.assertTrue((self.base/'root/shared.csv').is_file())
        result=execute(self.registry,self.plan,self.manifest,checkpoint=verify)
        self.assertEqual(list((self.base/'root/archive-dispatch'/result['job_id']).glob('blob-*')),[])

    def test_external_attachment_root_requires_registration(self):
        outside=self.base/'external-assets';outside.mkdir()
        self.manifest['messages'][0]['attachments'][0]['destination_path']=str(outside/'asset.csv')
        with self.assertRaises(RegistryError): execute(self.registry,self.plan,self.manifest)
        config=json.loads(self.registry.read_text())
        config['targets'][1]['attachment_roots']=[str(outside)]
        self.registry.write_text(json.dumps(config))
        r=Registry.load(self.registry)
        self.plan=r.plan(r.snapshot('root'),[{'message_id':'<m@example.invalid>','matched_target_ids':['child']}])
        execute(self.registry,self.plan,self.manifest)
        self.assertEqual((outside/'asset.csv').read_bytes(),b'a,b\n1,2\n')
        self.assertIn('](../../external-assets/asset.csv)',(self.base/'child/mail/mail.md').read_text())

    def test_cli_execute_and_resume(self):
        import subprocess
        planfile=self.base/'plan.json';planfile.write_text(json.dumps(self.plan))
        manifestfile=self.base/'manifest.json';manifestfile.write_text(json.dumps(self.manifest))
        command=[sys.executable,str(SCRIPTS/'archive_distribution.py'),'--registry',str(self.registry)]
        p=subprocess.run(command+['execute','--plan',str(planfile),'--manifest',str(manifestfile)],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr)
        result=json.loads(p.stdout)
        self.assert_complete()
        retry=subprocess.run(command+['resume','--job-id',result['job_id']],capture_output=True,text=True)
        self.assertEqual(retry.returncode,0,retry.stderr)
        self.assertEqual(json.loads(retry.stdout)['phase'],'complete')

    def test_metadata_mismatch_is_refused(self):
        self.manifest['messages'][0]['entry']['date']='2000-01-01'
        with self.assertRaisesRegex(RegistryError,'frontmatter'):
            execute(self.registry,self.plan,self.manifest)
        self.assertFalse((self.base/'root/mail/mail.md').exists())

    def test_message_id_containing_three_dashes_is_valid(self):
        mid='<a---b@example.invalid>'
        self.manifest['messages'][0]['message_id']=mid
        path=self.stage/'mail.md';path.write_text(path.read_text().replace('<m@example.invalid>',mid))
        r=Registry.load(self.registry)
        self.plan=r.plan(r.snapshot('root'),[{'message_id':mid,'matched_target_ids':['child']}])
        execute(self.registry,self.plan,self.manifest)
        self.assertIn(mid,self.state('child'))

    def test_process_exit_releases_lock_and_journal_resumes(self):
        import subprocess
        planfile=self.base/'plan.json';planfile.write_text(json.dumps(self.plan))
        manifestfile=self.base/'manifest.json';manifestfile.write_text(json.dumps(self.manifest))
        code="""import sys,os,json
sys.path.insert(0,sys.argv[1])
from archive_distribution import execute
def crash(phase,job):
    if phase=='intake_index': os._exit(99)
execute(sys.argv[2],json.load(open(sys.argv[3])),json.load(open(sys.argv[4])),checkpoint=crash)
"""
        result=subprocess.run([sys.executable,'-c',code,str(SCRIPTS),str(self.registry),str(planfile),str(manifestfile)])
        self.assertEqual(result.returncode,99)
        jobs=list((self.base/'root/archive-dispatch').iterdir())
        self.assertEqual(len(jobs),1)
        resume(self.registry,jobs[0].name)
        self.assert_complete()

    def test_historical_index_only_filename_is_reserved(self):
        path=self.base/'root/index.json'
        path.write_text(json.dumps({'version':'1.0','emails':{'<old@example.invalid>':{'file':'MAIL.md'}}}))
        r=Registry.load(self.registry)
        self.plan=r.plan(r.snapshot('root'),[{'message_id':'<m@example.invalid>','matched_target_ids':[]}])
        with self.assertRaisesRegex(RegistryError,'historical'):
            execute(self.registry,self.plan,self.manifest)
        self.assertFalse((self.base/'root/mail/mail.md').exists())
        self.assertEqual(r.snapshot('root')['historical_index_only'],1)

    def test_multiline_attachment_link_is_rejected(self):
        path=self.stage/'mail.md'
        path.write_text(path.read_text()+'\n[another](\nasset.csv\n)\n')
        with self.assertRaises(RegistryError): execute(self.registry,self.plan,self.manifest)
        self.assertFalse((self.base/'root/mail/mail.md').exists())

    def test_shared_attachments_remove_all_private_blobs(self):
        import copy
        second=copy.deepcopy(self.manifest['messages'][0])
        second.update(message_id='<second@example.invalid>',markdown='mail2.md',filename='mail2.md')
        (self.stage/'mail2.md').write_text((self.stage/'mail.md').read_text().replace('<m@example.invalid>','<second@example.invalid>'))
        self.manifest['messages'].append(second)
        r=Registry.load(self.registry)
        self.plan=r.plan(r.snapshot('root'),[{'message_id':m['message_id'],'matched_target_ids':['child']} for m in self.manifest['messages']])
        result=execute(self.registry,self.plan,self.manifest)
        self.assertEqual(list((self.base/'root/archive-dispatch'/result['job_id']).glob('blob-*')),[])

    def test_preparation_failure_removes_copied_private_blobs(self):
        path=self.stage/'mail.md';path.write_text(path.read_text()+'\n[bad](./asset.csv)\n')
        with self.assertRaises(RegistryError): execute(self.registry,self.plan,self.manifest)
        jobs=list((self.base/'root/archive-dispatch').iterdir())
        self.assertEqual(len(jobs),1)
        self.assertEqual(list(jobs[0].glob('blob-*')),[])
        self.assertEqual(json.loads((jobs[0]/'state.json').read_text())['phase'],'aborted_preparation')

    def test_process_exit_during_preparation_cleans_owned_blobs_on_retry(self):
        import subprocess
        planfile=self.base/'plan.json';planfile.write_text(json.dumps(self.plan))
        manifestfile=self.base/'manifest.json';manifestfile.write_text(json.dumps(self.manifest))
        code="""import sys,os,json
sys.path.insert(0,sys.argv[1])
import archive_distribution as d
d._check_attachment_links=lambda *args: os._exit(98)
d.execute(sys.argv[2],json.load(open(sys.argv[3])),json.load(open(sys.argv[4])))
"""
        result=subprocess.run([sys.executable,'-c',code,str(SCRIPTS),str(self.registry),str(planfile),str(manifestfile)])
        self.assertEqual(result.returncode,98)
        old=list((self.base/'root/archive-dispatch').iterdir())[0]
        self.assertTrue(list(old.glob('blob-*')))
        self.assertEqual(json.loads((old/'state.json').read_text())['phase'],'preparing')
        sentinel=old/'unknown-user-file';sentinel.write_text('keep')
        execute(self.registry,self.plan,self.manifest)
        self.assertEqual(list(old.glob('blob-*')),[])
        self.assertEqual(sentinel.read_text(),'keep')
        self.assert_complete()

    def test_unclassified_message_remains_in_intake(self):
        r=Registry.load(self.registry)
        self.plan=r.plan(r.snapshot('root'),[{'message_id':'<m@example.invalid>','matched_target_ids':[]}])
        execute(self.registry,self.plan,self.manifest)
        self.assertTrue((self.base/'root/mail/mail.md').exists())
        self.assertTrue((self.base/'root/data/asset.csv').exists())
        self.assertEqual(self.state('child'),{})
        self.assertNotIn('distributed_to',self.state('root')['<m@example.invalid>'])


if __name__=='__main__': unittest.main()
