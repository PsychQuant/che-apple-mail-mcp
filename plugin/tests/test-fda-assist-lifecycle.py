#!/usr/bin/env python3
"""Real hook/process tests with synthetic HOME and a non-Mail executable."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]

class FDALifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fda422-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'plugin/hooks').mkdir(parents=True)
        (self.root/'plugin/scripts').mkdir()
        (self.root/'bin').mkdir()
        shutil.copy2(ROOT/'plugin/hooks/session-start.sh',self.root/'plugin/hooks/session-start.sh')
        helper = ROOT/'plugin/scripts/fda-assist.pl'
        if helper.exists(): shutil.copy2(helper,self.root/'plugin/scripts/fda-assist.pl')
        self.marker=self.root/'state/che-apple-mail-mcp/fda-setup-offered'
        self.env=dict(os.environ,HOME=str(self.root),XDG_STATE_HOME=str(self.root/'state'),CHE_MAIL_HOOK_DEBUG='1',FDA_FIXTURE=str(self.root))
        self.binary=self.root/'bin/CheAppleMailMCP'
        self.binary.write_text('#!'+sys.executable+'''\nimport os,sys,time,json,signal
from pathlib import Path
r=Path(os.environ['FDA_FIXTURE']); mode=json.loads((r/'mode.json').read_text())
flag=sys.argv[1]
with (r/'calls').open('a') as f:f.write(flag+'\\n')
if flag=='--setup':
 with (r/'setups').open('a') as f:f.write('setup\\n')
 sys.exit(0)
if mode.get('hang')==flag or mode.get('orphan')==flag:
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 child=os.fork()
 with (r/'pids').open('a') as f:f.write(str(os.getpid())+'\\n')
 if mode.get('orphan')==flag and child:sys.exit(0)
 while True:time.sleep(1)
if mode.get('barrier') and flag=='--check-fda':
 (r/('ready-'+str(os.getpid()))).touch()
 while not (r/'release').exists():time.sleep(.01)
if mode.get('flood')==flag:
 while True:os.write(1,b'x'*8192)
if flag=='--version':
 print(mode.get('version','3.0.0'));sys.exit(mode.get('version_exit',0))
if mode.get('signal'):
 os.kill(os.getpid(),signal.SIGTERM)
sys.exit(mode.get('status',1))
''')
        self.binary.chmod(0o755)
        self.configure()
        self.addCleanup(self.kill_fixture_processes)

    def kill_fixture_processes(self):
        if (self.root/'pids').exists():
            for value in (self.root/'pids').read_text().splitlines():
                try: os.kill(int(value),signal.SIGKILL)
                except ProcessLookupError: pass

    def configure(self,**kwargs): (self.root/'mode.json').write_text(json.dumps(kwargs))
    def run_hook(self,timeout=5):
        started=time.monotonic()
        p=subprocess.run(['/bin/bash',str(self.root/'plugin/hooks/session-start.sh')],env=self.env,capture_output=True,text=True,timeout=timeout)
        self.assertEqual(p.returncode,0,p.stderr)
        return p,time.monotonic()-started
    def count_setups(self):
        time.sleep(.15)
        p=self.root/'setups'
        return len(p.read_text().splitlines()) if p.exists() else 0
    def assert_retry(self):
        self.configure(status=1)
        self.run_hook()
        for _ in range(40):
            if self.count_setups()==1: break
        self.assertEqual(self.count_setups(),1)
        self.assertTrue(self.marker.is_file())

    def test_each_probe_timeout_preserves_retry_and_kills_group(self):
        for flag in ['--version','--check-fda']:
            with self.subTest(flag=flag):
                self.configure(hang=flag)
                p,elapsed=self.run_hook()
                self.assertLess(elapsed,3.5)
                self.assertIn('timeout',p.stderr)
                self.assertFalse(self.marker.exists())
                self.assertEqual(self.count_setups(),0)
                for pid in (self.root/'pids').read_text().splitlines():
                    status=subprocess.run(['/bin/ps','-o','stat=','-p',pid],capture_output=True,text=True).stdout.strip()
                    self.assertTrue(not status or status.startswith('Z'),status)
                (self.root/'pids').unlink()
        self.assert_retry()

    def test_exited_leader_with_stdout_descendant_times_out(self):
        for flag in ['--version','--check-fda']:
            self.configure(orphan=flag)
            p,elapsed=self.run_hook()
            self.assertLess(elapsed,3.5)
            self.assertIn('timeout',p.stderr)
            self.assertFalse(self.marker.exists())
            for pid in (self.root/'pids').read_text().splitlines():
                status=subprocess.run(['/bin/ps','-o','stat=','-p',pid],capture_output=True,text=True).stdout.strip()
                self.assertTrue(not status or status.startswith('Z'),status)
            (self.root/'pids').unlink()
        self.assert_retry()

    def test_malformed_version_never_runs_quiet(self):
        for version in ['2.2 8.0','3.\n0.0','3.0.0\nextra']:
            calls=self.root/'calls'
            if calls.exists():calls.unlink()
            self.configure(version=version)
            self.run_hook()
            self.assertEqual(calls.read_text().splitlines(),['--version'])
            self.assertFalse(self.marker.exists())
        self.assert_retry()

    def test_supervisor_signal_during_masked_registration_and_reap(self):
        helper=self.root/'plugin/scripts/fda-assist.pl'
        original=helper.read_text()
        pause = """
sub fixture_pause {
    my $mask = POSIX::SigSet->new();
    POSIX::sigprocmask(SIG_BLOCK, undef, $mask);
    open my $event, '>', "$ENV{FDA_FIXTURE}/transition" or die;
    print $event $mask->ismember(SIGTERM); close $event;
    while (!-e "$ENV{FDA_FIXTURE}/release-transition") { sleep 0.01 }
}
"""
        for transition in ['register','reap']:
            with self.subTest(transition=transition):
                for filename in ['transition','release-transition','calls','pids']:
                    path=self.root/filename
                    if path.exists():path.unlink()
                source=original.replace('my ($binary, $marker_dir)',pause+'my ($binary, $marker_dir)',1)
                if transition=='register':
                    source=source.replace('    close $writer;\n    POSIX::setpgid', '    close $writer;\n    fixture_pause();\n    POSIX::setpgid',1)
                    self.configure(hang='--version')
                else:
                    source=source.replace('            my $status = $?;','            my $status = $?;\n            fixture_pause() if $done == $pid;',1)
                    self.configure()
                helper.write_text(source)
                process=subprocess.Popen(['/usr/bin/perl',str(helper),str(self.binary),str(self.marker.parent)],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                try:
                    deadline=time.monotonic()+2
                    while not (self.root/'transition').exists() and time.monotonic()<deadline:time.sleep(.01)
                    self.assertEqual((self.root/'transition').read_text(),'1')
                    if transition=='register':
                        deadline=time.monotonic()+1
                        while (not (self.root/'pids').exists() or len((self.root/'pids').read_text().splitlines())<2) and time.monotonic()<deadline:time.sleep(.01)
                    process.send_signal(signal.SIGTERM)
                    (self.root/'release-transition').touch()
                    _,err=process.communicate(timeout=2)
                    self.assertEqual(process.returncode,0,err)
                    self.assertIn('interrupted',err)
                    self.assertFalse(self.marker.exists())
                    if (self.root/'pids').exists():
                        for pid in (self.root/'pids').read_text().splitlines():
                            status=subprocess.run(['/bin/ps','-o','stat=','-p',pid],capture_output=True,text=True).stdout.strip()
                            self.assertTrue(not status or status.startswith('Z'),status)
                finally:
                    (self.root/'release-transition').touch()
                    if process.poll() is None:process.kill();process.wait()
        helper.write_text(original)
        self.assert_retry()

    def test_flood_and_bad_version_preserve_offer(self):
        for mode in [{'flood':'--version'},{'flood':'--check-fda'},{'version':'3.0.0','version_exit':42},{'version':'not-a-version'}]:
            self.configure(**mode)
            p,elapsed=self.run_hook()
            self.assertLess(elapsed,3.5)
            self.assertFalse(self.marker.exists())
            self.assertEqual(self.count_setups(),0)
        self.assert_retry()

    def test_unknown_and_signal_preserve_offer(self):
        for mode in [{'status':0},{'status':2},{'status':3},{'status':42},{'signal':True}]:
            self.configure(**mode)
            p,_=self.run_hook()
            self.assertFalse(self.marker.exists())
            self.assertEqual(self.count_setups(),0)
        self.assert_retry()

    def test_concurrent_denied_has_one_atomic_offer(self):
        self.configure(barrier=True,status=1)
        processes=[subprocess.Popen(['/bin/bash',str(self.root/'plugin/hooks/session-start.sh')],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(12)]
        try:
            deadline=time.monotonic()+1.5
            while len(list(self.root.glob('ready-*')))<12 and time.monotonic()<deadline:time.sleep(.01)
            self.assertEqual(len(list(self.root.glob('ready-*'))),12)
            (self.root/'release').touch()
            outputs=[p.communicate(timeout=5) for p in processes]
            self.assertTrue(all(p.returncode==0 for p in processes))
            self.assertEqual(sum(err.count('Full Disk Access is not granted') for _,err in outputs),1)
            for _ in range(20):
                if self.count_setups()==1:break
            self.assertEqual(self.count_setups(),1)
            self.assertEqual(self.marker.stat().st_mode & 0o777,0o600)
        finally:
            for p in processes:
                if p.poll() is None:p.kill();p.wait()

    def test_legacy_marker_skips_probes(self):
        self.marker.parent.mkdir(parents=True)
        self.marker.touch()
        self.configure(hang='--version')
        _,elapsed=self.run_hook()
        self.assertLess(elapsed,1)
        self.assertFalse((self.root/'calls').exists())

if __name__=='__main__':unittest.main()
