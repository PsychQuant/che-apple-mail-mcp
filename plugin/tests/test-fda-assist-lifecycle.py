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
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]

# Two kinds of budget live in this file (#624). A poll on a fixture reaching a known point uses
# POLL_SECONDS: a slow start only costs time, and a real failure still fails the assertion after it.
# `assertLess(elapsed, ...)`, `run_hook(timeout=5)` and `communicate(timeout=2)` measure the 2.0 s
# probe deadline in fda-assist.pl, so they assume an idle machine and stay as they are; that deadline
# does not change for test convenience. They can still fail under heavy CPU load.
#
# The concurrent test rests on the same deadline. Twelve hooks have to reach the barrier inside the
# 2.0 s each probe allows, and no poll changes that: measured under load, every `--version` probe
# expired before Python started, and the hooks exited with nothing raced. Only that run is a skip. Once
# any hook has reached the barrier the run is a failure, because a deadlock between hooks looks the
# same from here. A hook that times out at the barrier has already written `ready-*`, so a slow run can
# still pass with fewer than twelve contenders.
POLL_SECONDS = 10

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
if mode.get('slow_start')==flag:time.sleep(30)
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

    def recorded_pids(self,grace):
        path=self.root/'pids'
        deadline=time.monotonic()+grace
        while True:
            pids=path.read_text().split() if path.exists() else []
            if pids or time.monotonic()>=deadline:return pids
            time.sleep(.01)

    def fixture_processes(self,wait):
        # The path holds this test's temporary directory, so this finds the fixture and nothing else.
        # A killed process takes a moment to go, hence the poll: free on success, slow only on a survivor.
        # ps and not pgrep: the path is matched literally, and a failed listing raises instead of reading as none.
        deadline=time.monotonic()+wait
        while True:
            listing=subprocess.run(['/bin/ps','-axww','-o','pid=,command='],capture_output=True,text=True,check=True).stdout
            found=[line.split()[0] for line in listing.splitlines() if str(self.binary) in line]
            if not found or time.monotonic()>=deadline:return found
            time.sleep(.05)

    def assert_fixture_group_gone(self,elapsed,grace=1,wait=POLL_SECONDS):
        # #624: no pid means the deadline beat the fixture's pid line. That is only true of a full
        # probe timeout, and load can only lengthen elapsed, so this lower bound holds under load too.
        pids=self.recorded_pids(grace)
        if not pids:self.assertGreaterEqual(elapsed,2.0,'no pid recorded and the probe ended before its 2.0 s deadline')
        self.assertEqual(self.fixture_processes(wait),[])
        for pid in pids:
            status=subprocess.run(['/bin/ps','-o','stat=','-p',pid],capture_output=True,text=True).stdout.strip()
            self.assertTrue(not status or status.startswith('Z'),status)
        (self.root/'pids').unlink(missing_ok=True)

    def assert_every_hook_timed_out(self,errors,wall):
        self.assertEqual([e for e in errors if 'version timeout (2 seconds)' not in e],[],'a hook left the race without a --version timeout')
        self.assertGreaterEqual(wall,2.0,'hooks reported a probe timeout before the 2.0 s deadline')

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
                self.assert_fixture_group_gone(elapsed)
        self.assert_retry()

    # #624: under load the 2.0 s deadline can expire before the fixture records a pid. The group is
    # killed and `pids` never appears, which the product does correctly and the tests must accept.
    def test_probe_timeout_before_the_fixture_records_a_pid(self):
        self.configure(slow_start='--version')
        p,elapsed=self.run_hook()
        self.assertIn('timeout',p.stderr)
        self.assert_fixture_group_gone(elapsed)

    def test_a_pid_recorded_late_is_still_checked(self):
        survivor=subprocess.Popen(['/bin/sh','-c','sleep .2; echo $$ >"$1"; exec sleep 30','sh',str(self.root/'pids')])
        self.addCleanup(survivor.wait)
        self.addCleanup(survivor.kill)
        with self.assertRaises(AssertionError):
            self.assert_fixture_group_gone(elapsed=2.0,grace=POLL_SECONDS)

    def test_a_survivor_with_no_pid_recorded_is_found(self):
        self.configure(slow_start='--version')
        survivor=subprocess.Popen([str(self.binary),'--version'],env=self.env)
        self.addCleanup(survivor.wait)
        self.addCleanup(survivor.kill)
        with self.assertRaises(AssertionError):
            self.assert_fixture_group_gone(elapsed=2.0,grace=0,wait=.2)

    def test_a_fixture_that_is_still_leaving_is_waited_for(self):
        # The listings are scripted: a real process racing a timer passes without any poll under load.
        listings=iter([f'123 {self.binary} --version\n',''])
        def scripted(command,**kwargs):
            return subprocess.CompletedProcess(command,0,next(listings),'')
        with mock.patch('subprocess.run',scripted):
            self.assertEqual(self.fixture_processes(POLL_SECONDS),[])
        self.assertEqual(list(listings),[])

    def test_a_failed_listing_raises_instead_of_reading_as_none(self):
        real=subprocess.run
        with mock.patch('subprocess.run',lambda command,**kwargs:real(['/usr/bin/false'],**kwargs)):
            with self.assertRaises(subprocess.CalledProcessError):
                self.fixture_processes(0)

    def test_no_pid_before_the_deadline_is_a_failure(self):
        with self.assertRaises(AssertionError):
            self.assert_fixture_group_gone(elapsed=1.9,grace=0)

    def test_concurrent_hooks_that_all_time_out_are_a_skip_not_a_failure(self):
        self.configure(barrier=True,status=1,slow_start='--version')
        started=time.monotonic()
        with self.assertRaises(unittest.SkipTest):
            self.run_concurrent_hooks()
        self.assertLess(time.monotonic()-started,POLL_SECONDS,'the poll outlived the hooks')

    def test_only_a_full_probe_timeout_excuses_the_race(self):
        timed_out='che-apple-mail-mcp: FDA assist version timeout (2 seconds); preserving offer\n'
        self.assert_every_hook_timed_out([timed_out]*12,2.0)
        with self.assertRaises(AssertionError):
            self.assert_every_hook_timed_out([timed_out]*11+['version exited 3\n'],2.0)
        with self.assertRaises(AssertionError):
            self.assert_every_hook_timed_out([timed_out]*12,1.9)
        quiet='che-apple-mail-mcp: FDA assist quiet timeout (2 seconds); preserving offer\n'
        with self.assertRaises(AssertionError):
            self.assert_every_hook_timed_out([timed_out]*11+[quiet],2.0)

    def assert_never_a_skip(self):
        try:
            self.run_concurrent_hooks()
        except AssertionError:
            return
        except unittest.SkipTest:
            pass
        self.fail('a run that does not qualify was excused')

    def test_a_hook_that_reached_the_barrier_is_never_a_skip(self):
        self.configure(barrier=True,status=1,slow_start='--version')
        (self.root/'ready-other').touch()
        self.assert_never_a_skip()

    def test_a_hook_that_fails_after_its_timeout_is_never_a_skip(self):
        self.configure(barrier=True,status=1,slow_start='--version')
        hook=self.root/'plugin/hooks/session-start.sh'
        hook.write_text('#!/bin/bash\ntrap \'exit 3\' EXIT\n'+hook.read_text())
        self.assert_never_a_skip()

    def test_the_fixture_path_is_matched_literally(self):
        directory=self.root/'with[bracket'
        directory.mkdir()
        self.binary=directory/'CheAppleMailMCP'
        shutil.copy2(self.root/'bin/CheAppleMailMCP',self.binary)
        self.configure(slow_start='--version')
        survivor=subprocess.Popen([str(self.binary),'--version'],env=self.env)
        self.addCleanup(survivor.wait)
        self.addCleanup(survivor.kill)
        self.assertEqual(self.fixture_processes(0),[str(survivor.pid)])

    def test_exited_leader_with_stdout_descendant_times_out(self):
        for flag in ['--version','--check-fda']:
            self.configure(orphan=flag)
            p,elapsed=self.run_hook()
            self.assertLess(elapsed,3.5)
            self.assertIn('timeout',p.stderr)
            self.assertFalse(self.marker.exists())
            self.assert_fixture_group_gone(elapsed)
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
                    deadline=time.monotonic()+POLL_SECONDS
                    while not (self.root/'transition').exists() and time.monotonic()<deadline:time.sleep(.01)
                    self.assertEqual((self.root/'transition').read_text(),'1')
                    if transition=='register':
                        deadline=time.monotonic()+POLL_SECONDS
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
        self.run_concurrent_hooks()

    def run_concurrent_hooks(self):
        started=time.monotonic()
        processes=[subprocess.Popen(['/bin/bash',str(self.root/'plugin/hooks/session-start.sh')],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(12)]
        try:
            deadline=time.monotonic()+POLL_SECONDS
            while len(list(self.root.glob('ready-*')))<12 and time.monotonic()<deadline and any(p.poll() is None for p in processes):time.sleep(.01)
            # The barrier holds a hook until `release`, so a hook that has gone left by another way.
            if all(p.poll() is not None for p in processes):
                errors=[p.communicate(timeout=5)[1] for p in processes]
                self.assertEqual(len(list(self.root.glob('ready-*'))),0,errors)
                self.assertEqual([p.returncode for p in processes],[0]*12,errors)
                self.assert_every_hook_timed_out(errors,time.monotonic()-started)
                self.skipTest('every --version probe hit the 2.0 s deadline, so no hook reached the barrier')
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
