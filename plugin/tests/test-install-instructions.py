#!/usr/bin/env python3
"""Offline membership/transport regressions; never execute README commands."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('install_check', ROOT / 'scripts/check-install-instructions.py')
check = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = check
spec.loader.exec_module(check)

README = '''```bash
claude plugin marketplace add other/aggregator
claude plugin install mail@external
```'''
def manifest(name='external', plugins=('mail',)):
    return json.dumps({'name': name, 'plugins': [{'name': p} for p in plugins]}).encode()

class InstallInstructionsTests(unittest.TestCase):
    def resolve(self, readme=README, data=None):
        self.calls = []
        def fetch(repo):
            self.calls.append(repo)
            return data if data is not None else manifest()
        return check.resolve(readme, fetch)

    def test_external_membership_success_fetches_documented_repo(self):
        self.assertEqual(self.resolve(), ['mail@external via other/aggregator'])
        self.assertEqual(self.calls, ['other/aggregator'])

    def test_383_external_marketplace_exists_but_plugin_removed(self):
        with self.assertRaisesRegex(check.Invalid, 'mail.*missing'):
            self.resolve(data=manifest(plugins=('unrelated',)))

    def test_wrong_marketplace_name_is_not_local_manifest_fallback(self):
        with self.assertRaisesRegex(check.Invalid, 'external.*not added'):
            self.resolve(data=manifest(name='renamed'))

    def test_multiple_sources_resolve_independently(self):
        readme = README.replace('claude plugin install', 'claude plugin marketplace add owner/self\nclaude plugin install')
        self.assertEqual(check.resolve(readme, lambda repo: manifest('self') if repo == 'owner/self' else manifest()),
                         ['mail@external via other/aggregator'])

    def test_duplicate_marketplace_names_refused(self):
        readme = README.replace('claude plugin install', 'claude plugin marketplace add owner/self\nclaude plugin install')
        with self.assertRaisesRegex(check.Invalid, 'ambiguous'):
            self.resolve(readme)

    def test_https_git_source_and_shell_comment(self):
        readme = README.replace('other/aggregator', 'https://github.com/other/aggregator.git # comment')
        self.assertEqual(self.resolve(readme), ['mail@external via other/aggregator'])

    def test_unknown_shell_forms_do_not_silently_pass(self):
        for line in ['claude plugin install mail', 'claude plugin install mail@external && echo yes',
                     'claude plugin marketplace add $(echo evil)', 'claude plugin marketplace add /tmp/local',
                     'claude plugin install --scope=user mail@external']:
            with self.subTest(line=line), self.assertRaises(check.Invalid):
                self.resolve(README.replace('claude plugin install mail@external', line))

    def test_missing_instructions_and_unterminated_fence_refused(self):
        for text in ['', 'claude plugin install mail@external', README[:-3]]:
            with self.assertRaises(check.Invalid): self.resolve(text)

    def test_malformed_or_duplicate_manifest_entries_refused(self):
        for data in [b'{', b'[]', b'{}', manifest(plugins=('mail','mail')),
                     b'{"name":"external","plugins":[{}]}',
                     b'{"name":"external","name":"other","plugins":[]}']:
            with self.subTest(data=data), self.assertRaises((check.Invalid, check.Uncertain)): self.resolve(data=data)

    def test_transient_error_is_not_green(self):
        with self.assertRaises(check.Uncertain):
            check.resolve(README, lambda _: (_ for _ in ()).throw(check.Uncertain('timeout')))

    def fake_runner(self, responses):
        def run(args, **kwargs):
            if '--version' in args:
                return subprocess.CompletedProcess(args, 0, 'curl 8.4.0 fixture', '')
            response = responses.pop(0)
            if isinstance(response, Exception): raise response
            status, body, code = response
            Path(args[args.index('--output') + 1]).write_bytes(body)
            self.assertIn('--max-time', args)
            self.assertIn('--proto-redir', args)
            self.assertEqual(args[1], '--disable')
            self.assertLessEqual(kwargs['timeout'], 12)
            return subprocess.CompletedProcess(args, code, str(status), 'fixture error')
        return run

    def test_503_retries_then_success(self):
        responses=[(503,b'',0),(200,manifest(),0)]
        with patch.object(check.subprocess,'run',self.fake_runner(responses)), patch.object(check.time,'sleep'):
            self.assertEqual(check.fetch_manifest('other/aggregator'), manifest())
        self.assertFalse(responses)

    def test_404_is_definite_and_not_retried(self):
        responses=[(404,b'',0)]
        with patch.object(check.subprocess,'run',self.fake_runner(responses)):
            with self.assertRaises(check.Invalid): check.fetch_manifest('other/aggregator')
        self.assertFalse(responses)

    def test_timeout_and_rate_limit_are_bounded_uncertain(self):
        for response in [(429,b'',0), subprocess.TimeoutExpired('curl',12), (0,b'',28)]:
            responses=[response]*3
            with patch.object(check.subprocess,'run',self.fake_runner(responses)), patch.object(check.time,'sleep'):
                with self.assertRaises(check.Uncertain): check.fetch_manifest('other/aggregator')
            self.assertFalse(responses)

    def test_oversized_manifest_refused(self):
        responses=[(200,b' '*(check.MAX_BYTES+1),0)]
        with patch.object(check.subprocess,'run',self.fake_runner(responses)):
            with self.assertRaises(check.Invalid): check.fetch_manifest('other/aggregator')

    def test_total_deadline_is_not_reset_per_repository(self):
        with patch.object(check.subprocess,'run') as run:
            with self.assertRaises(check.Uncertain): check.fetch_manifest('other/aggregator', deadline=0)
            run.assert_not_called()

    def test_hash_inside_target_is_not_truncated_as_comment(self):
        for old, new in [('other/aggregator','other/aggregator#obsolete'),
                         ('mail@external','mail@external#obsolete'),
                         ('mail@external','"mail@external#quoted"')]:
            with self.subTest(new=new), self.assertRaises(check.Invalid):
                self.resolve(README.replace(old,new))
        self.assertEqual(self.resolve(README.replace('mail@external','mail@external # trailing comment')),
                         ['mail@external via other/aggregator'])

    def test_curl_older_than_streaming_limit_support_refuses_before_download(self):
        for version in ['curl 8.3.0', 'curl 7.88.1', 'unknown']:
            with patch.object(check.subprocess,'run',return_value=subprocess.CompletedProcess([],0,version,'')) as run:
                with self.assertRaises(check.Uncertain): check.fetch_manifest('other/aggregator')
                self.assertEqual(run.call_count,1)
                self.assertIn('--version',run.call_args.args[0])

    def test_real_curl_limits_unknown_length_chunked_response(self):
        import http.server
        import threading
        try:
            check.require_curl()
        except check.Uncertain as exc:
            self.skipTest(str(exc))
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *args): pass
            def do_GET(self):
                self.close_connection = True
                self.send_response(200)
                self.send_header('Connection','close')
                self.send_header('Transfer-Encoding','chunked')
                self.end_headers()
                try:
                    for _ in range(300):
                        self.wfile.write(b'4000\r\n' + b'x'*16384 + b'\r\n')
                    self.wfile.write(b'0\r\n\r\n')
                except (BrokenPipeError, ConnectionResetError): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread = threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        original_run = subprocess.run
        def local_run(args, **kwargs):
            if '--version' in args: return original_run(args,**kwargs)
            # Production accepts only HTTPS GitHub. This fixture replaces only
            # the destination/protocol with loopback HTTP to test curl's stream cap.
            args=list(args)
            self.assertEqual(args[args.index('--proto')+1],'=https')
            args[args.index('--proto')+1]='=http'
            args[args.index('--proto-redir')+1]='=http'
            args[-1]=f'http://127.0.0.1:{server.server_port}/manifest'
            result=original_run(args,**kwargs)
            self.assertLessEqual(Path(args[args.index('--output')+1]).stat().st_size,check.MAX_BYTES)
            self.assertEqual(result.returncode,63)
            return result
        try:
            with patch.object(check.subprocess,'run',local_run):
                with self.assertRaises(check.Invalid): check.fetch_manifest('other/aggregator')
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_install_before_add_refuses_fresh_environment(self):
        readme = "```sh\nclaude plugin install mail@external\nclaude plugin marketplace add other/aggregator\n```"
        with self.assertRaisesRegex(check.Invalid, 'not added'):
            self.resolve(readme)

    def test_main_exit_codes_and_no_partial_success(self):
        import contextlib
        import io
        for error, code, marker in [(check.Invalid('removed'),1,'INSTALL_RESOLUTION_INVALID'),
                                    (check.Uncertain('timeout'),2,'INSTALL_RESOLUTION_UNCERTAIN')]:
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(check,'fetch_manifest',side_effect=error), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(check.main(['--readme',str(ROOT/'README.md')]),code)
            self.assertEqual(stdout.getvalue(),'')
            self.assertIn(marker,stderr.getvalue())

    def test_wrapped_and_global_option_commands_cannot_hide_in_valid_subset(self):
        for extra in ['env claude plugin install removed@external',
                      'claude --debug plugin install removed@external',
                      '/usr/local/bin/claude plugin install removed@external']:
            with self.subTest(extra=extra),self.assertRaises(check.Invalid):
                self.resolve(README.rsplit('```',1)[0]+extra+'\n```')
        with self.assertRaises(check.Invalid):
            self.resolve(README+'\n```json\nclaude plugin install removed@external\n```')
        self.assertEqual(self.resolve(README.replace('```bash','```console')),['mail@external via other/aggregator'])

    def test_checkout_override_is_exact_and_external_sources_still_remote(self):
        import contextlib,io,tempfile
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);readme=root/'README.md';local=root/'marketplace.json'
            readme.write_text('```sh\nclaude plugin marketplace add owner/self\nclaude plugin install new@new-market\nclaude plugin marketplace add other/aggregator\nclaude plugin install mail@external\n```')
            local.write_bytes(manifest('new-market',('new',)))
            with patch.object(check,'fetch_manifest',return_value=manifest()) as fetch,contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(check.main(['--readme',str(readme),'--checkout-repo','owner/self','--checkout-manifest',str(local)]),0)
                self.assertEqual([c.args[0] for c in fetch.call_args_list],['other/aggregator'])
            local.write_bytes(manifest('new-market',()))
            with patch.object(check,'fetch_manifest',return_value=manifest()),contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(check.main(['--readme',str(readme),'--checkout-repo','owner/self','--checkout-manifest',str(local)]),1)
            # No override in ordinary mode: every source must remain remote.
            with patch.object(check,'fetch_manifest',return_value=manifest('old-market',('old',))) as fetch,contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(check.main(['--readme',str(readme)]),1)
                self.assertEqual(fetch.call_args.args[0],'owner/self')

    def test_dotted_marketplace_and_plugin_names(self):
        readme=README.replace('mail@external','mail.v2@external.v2')
        self.assertEqual(self.resolve(readme,data=manifest('external.v2',('mail.v2',))),['mail.v2@external.v2 via other/aggregator'])

    def test_continuations_and_outside_fence_commands_do_not_hide(self):
        continued = "claude plugin " + chr(92) + "\n install removed@external"
        split_word = "claude plu" + chr(92) + "\ngin install removed@external"
        for extra in [continued,split_word]:
            with self.assertRaises(check.Invalid): self.resolve(README+'\n```sh\n'+extra+'\n```')
        for extra in ['    claude plugin install removed@external','Use `claude plugin install removed@external`.']:
            with self.assertRaises(check.Invalid): self.resolve(README+'\n'+extra)

    def test_missing_checkout_manifest_is_definite_failure(self):
        import contextlib,io,tempfile
        with tempfile.TemporaryDirectory() as directory:
            missing=Path(directory)/'missing.json'
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(check.main(['--checkout-repo','PsychQuant/che-apple-mail-mcp','--checkout-manifest',str(missing)]),1)

    def test_quoted_shell_keywords_are_checked_as_real_tokens(self):
        for command in ['claude "plugin" install removed@external',
                        "claude plugin 'install' removed@external",
                        'claude plu"gin" in"stall" removed@external']:
            with self.subTest(command=command),self.assertRaisesRegex(check.Invalid,'removed.*missing'):
                self.resolve(README+'\n```sh\n'+command+'\n```')
        readme=README.replace('claude plugin marketplace add','claude "plugin" "marketplace" "add"')
        self.assertEqual(self.resolve(readme),['mail@external via other/aggregator'])

    def test_unrelated_schema_details_do_not_hide_or_invalidate_target(self):
        data=b'{"name":"external","metadata":{"x":1,"x":2},"plugins":[{},"future-form",{"name":"other space"},{"name":"mail"}]}'
        self.assertEqual(self.resolve(data=data),['mail@external via other/aggregator'])
        with self.assertRaises(check.Uncertain):
            self.resolve(data=b'{"name":"external","plugins":[{},"future-form"]}')
        with self.assertRaises(check.Uncertain):
            self.resolve(data=b'{"name":"external","plugins":[{"name":"mail","name":"other"}]}')
        with self.assertRaises(check.Invalid):self.resolve(data=manifest(plugins=('other',)))

    def test_prose_without_cli_prefix_is_not_an_install_command(self):
        self.assertEqual(self.resolve(README+"\nRun the plugin install step after setup. Don't skip the plugin install step.\n"),['mail@external via other/aggregator'])
        with self.assertRaises(check.Invalid):
            self.resolve(README+'\nUse `claude plugin install removed@external`.\n')
        with self.assertRaises(check.Invalid):
            self.resolve(README+'\nUse `/plugin install removed@external`.\n')

    def test_shell_operator_wrappers_do_not_hide_in_valid_subset(self):
        for command in ['(claude plugin install removed@external)',
                        '("claude" "plugin" install removed@external)',
                        'sh -c "(claude plugin install removed@external)"',
                        "sh -c \"('claude' 'plugin' 'install' removed@external)\""]:
            with self.subTest(command=command),self.assertRaises(check.Invalid):
                self.resolve(README+'\n```sh\n'+command+'\n```')

    def test_path_runs_and_malformed_quote_paths_are_bounded(self):
        import subprocess,tempfile
        for tail in ['/'*500_000, "'"+'/'*500_000, '/'*50_000, "'"+'/'*50_000]:
            with tempfile.TemporaryDirectory() as directory:
                path=Path(directory)/'input.md';path.write_text(README+'\n```sh\n'+tail+'\n```')
                code="import importlib.util,sys; s=importlib.util.spec_from_file_location('c',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.commands(open(sys.argv[2]).read())"
                result=subprocess.run([sys.executable,'-c',code,str(ROOT/'scripts/check-install-instructions.py'),str(path)],capture_output=True,text=True,timeout=5)
                if len(tail)>check.MAX_LINE_BYTES:self.assertNotEqual(result.returncode,0)
                else:self.assertEqual(result.returncode,0,result.stderr)

    def test_ansi_c_installation_wrappers_fail_explicitly(self):
        for command in ["bash -c $'claude plugin install removed@external'",
                        'bash -c $"claude plugin install removed@external"',
                        'claude $"plugin" install removed@external',
                        "bash -c $'clau"+chr(92)+"x64e plugin install removed@external'",
                        "claude $'plu"+chr(92)+"x67in' install removed@external",
                        'clau"de" '+"$'plu"+chr(92)+"x67in' install removed@external"]:
            with self.subTest(command=command),self.assertRaises(check.Invalid):
                self.resolve(README+'\n```bash\n'+command+'\n```')

    def test_current_readme_against_local_fixture(self):
        data=(ROOT/'.claude-plugin/marketplace.json').read_bytes()
        self.assertEqual(self.resolve((ROOT/'README.md').read_text(),data),
                         ['che-apple-mail-mcp@che-apple-mail-mcp via PsychQuant/che-apple-mail-mcp'])

if __name__ == '__main__': unittest.main()
