#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from email.message import EmailMessage
from email import policy

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('render_review',ROOT/'plugin/scripts/draft-render-review.py')
review=importlib.util.module_from_spec(spec);sys.modules[spec.name]=review;spec.loader.exec_module(review)

def mail(body='original',cte='quoted-printable',attachment=None):
    m=EmailMessage(policy=policy.SMTP)
    m['From']='sender@example.invalid';m['To']='test@example.invalid';m['Subject']='review fixture'
    m.set_content(body,cte=cte)
    m.add_alternative('<p>'+body+'</p>',subtype='html',cte=cte)
    if attachment is not None:m.add_attachment(attachment,maintype='application',subtype='octet-stream',filename='../secret')
    return m.as_bytes()

class RenderReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.source=self.root/'source.eml';self.source.write_bytes(mail())
        self.bundle=self.root/'review'
    def test_prepare_preserves_bytes_private_and_never_passes_render(self):
        report=review.prepare(self.source,self.bundle)
        self.assertEqual((self.bundle/'source.eml').read_bytes(),self.source.read_bytes())
        self.assertFalse(report['client_render_verified'])
        self.assertEqual(report['status'],'pending_client_review')
        self.assertEqual(self.bundle.stat().st_mode&0o777,0o700)
        self.assertEqual((self.bundle/'source.eml').stat().st_mode&0o777,0o600)
    def test_no_overwrite_existing_output(self):
        self.bundle.mkdir();(self.bundle/'kept').write_text('user data')
        with self.assertRaises((ValueError,OSError)):review.prepare(self.source,self.bundle)
        self.assertEqual((self.bundle/'kept').read_text(),'user data')
    def test_encoding_and_boundary_changes_match_content_only(self):
        review.prepare(self.source,self.bundle)
        received=self.root/'received.eml';received.write_bytes(mail(cte='base64'))
        result=review.compare(self.bundle,self.source,received)
        self.assertTrue(result['snapshot_matches']);self.assertTrue(result['content_matches'])
        self.assertEqual(result['status'],'ready_for_client_review');self.assertFalse(result['client_render_verified'])
    def test_changed_source_and_received_are_not_ready(self):
        review.prepare(self.source,self.bundle)
        received=self.root/'received.eml';received.write_bytes(mail('modified'))
        self.assertFalse(review.compare(self.bundle,self.source,received)['content_matches'])
        self.source.write_bytes(mail('new draft'))
        result=review.compare(self.bundle,self.source,received)
        self.assertFalse(result['snapshot_matches']);self.assertEqual(result['status'],'source_changed')
    def test_attachment_bytes_and_metadata_participate(self):
        a=review.analyze(mail(attachment=b'one'))
        b=review.analyze(mail(attachment=b'two'))
        self.assertNotEqual(a['content_sha256'],b['content_sha256'])
        self.source.write_bytes(mail(attachment=b'one'));review.prepare(self.source,self.bundle)
        self.assertEqual(set(p.name for p in self.bundle.iterdir()),{'review.json','source.eml'})
    def test_markup_is_only_reported_never_rendered(self):
        raw=mail('<script>alert(1)</script><blockquote type="cite">x</blockquote><img src="https://example.invalid/pixel">')
        result=review.analyze(raw)
        self.assertIn('active_markup',result['warnings']);self.assertIn('cite_quote',result['warnings']);self.assertIn('remote_resource',result['warnings'])
        self.assertFalse(result['client_render_verified'])
    def test_corrupt_snapshot_or_manifest_refused(self):
        review.prepare(self.source,self.bundle)
        (self.bundle/'source.eml').write_bytes(mail('tampered'))
        with self.assertRaises(ValueError):review.compare(self.bundle,self.source,self.source)
    def test_malformed_encoding_and_limits_refused(self):
        for raw in [b'not a message',b'Content-Type: multipart/mixed; boundary=x\r\n\r\nmissing',
                    b'Content-Type: text/plain\r\nContent-Transfer-Encoding: unknown\r\n\r\nx',
                    b'Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n@@@',
                    b'x'*(review.MAX_BYTES+1)]:
            with self.subTest(raw=raw[:80]),self.assertRaises(ValueError):review.analyze(raw)
    def test_depth_and_part_count_limits(self):
        def nested(levels):
            node=EmailMessage(policy=policy.SMTP);node.set_content('leaf')
            for _ in range(levels):
                parent=EmailMessage(policy=policy.SMTP);parent.make_mixed();parent.attach(node);node=parent
            return node.as_bytes()
        self.assertEqual(review.analyze(nested(16))['part_count'],17)
        with self.assertRaises(ValueError):review.analyze(nested(17))
        many=EmailMessage(policy=policy.SMTP);many.make_mixed()
        for _ in range(256):
            child=EmailMessage(policy=policy.SMTP);child.set_content('x');many.attach(child)
        with self.assertRaises(ValueError):review.analyze(many.as_bytes())

    def test_embedded_message_headers_affect_fingerprint(self):
        def attached(subject):
            inner=EmailMessage(policy=policy.SMTP);inner['Subject']=subject;inner.set_content('same body')
            outer=EmailMessage(policy=policy.SMTP);outer.set_content('same cover');outer.add_attachment(inner)
            return outer.as_bytes()
        self.assertNotEqual(review.analyze(attached('one'))['content_sha256'],review.analyze(attached('two'))['content_sha256'])

    def test_fifo_is_refused_without_reading(self):
        fifo=self.root/'pipe';os.mkfifo(fifo)
        with self.assertRaises(ValueError):review.read_regular(fifo)

    def test_metadata_boolean_type_and_duplicate_keys_are_not_equal(self):
        review.prepare(self.source,self.bundle)
        metadata=self.bundle/'review.json';original=metadata.read_bytes()
        metadata.write_bytes(original.replace(b'"schema_version":1',b'"schema_version":true'))
        with self.assertRaises(ValueError):review.compare(self.bundle,self.source,self.source)
        metadata.write_bytes(original[:-2]+b',"schema_version":1}\n')
        with self.assertRaises(ValueError):review.compare(self.bundle,self.source,self.source)

    def test_cli_exit_codes_preserve_pending_and_mismatch(self):
        import subprocess
        script=ROOT/'plugin/scripts/draft-render-review.py'
        def run(*args):return subprocess.run([sys.executable,str(script),*map(str,args)],capture_output=True,text=True,timeout=5)
        prepared=run('prepare','--source',self.source,'--output',self.bundle)
        self.assertEqual(prepared.returncode,0,prepared.stderr)
        self.assertFalse(json.loads(prepared.stdout)['client_render_verified'])
        received=self.root/'received.eml';received.write_bytes(mail('different'))
        result=run('compare','--review',self.bundle,'--current-source',self.source,'--received',received)
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'],'content_differs')
        bad=self.root/'bad';bad.write_bytes(b'broken')
        self.assertEqual(run('prepare','--source',bad,'--output',self.root/'bad-review').returncode,1)

    def test_malformed_quoted_printable_cannot_equal_valid_content(self):
        prefix=b'Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n'
        valid=prefix+b'abc=3DGG'
        self.source.write_bytes(valid);review.prepare(self.source,self.bundle)
        received=self.root/'received.eml'
        for payload in [b'abc=GG',b'abc=',b'abc=\rX',b'abc=\t\n',b'abc \r\n']:
            with self.subTest(payload=payload):
                received.write_bytes(prefix+payload)
                with self.assertRaises(ValueError):review.analyze(prefix+payload)
                with self.assertRaises(ValueError):review.compare(self.bundle,self.source,received)
        self.assertEqual(review.analyze(prefix+b'ab=\r\nc')['content_sha256'],review.analyze(prefix+b'abc')['content_sha256'])

    def test_parser_stops_creating_objects_at_budget(self):
        from unittest.mock import patch
        raw=b'Content-Type: multipart/mixed; boundary=b\r\n\r\n'+b'--b\r\nContent-Type: text/plain\r\n\r\nx\r\n'*5000+b'--b--\r\n'
        count=0;original=review.EmailMessage.__init__
        def counted(instance,*args,**kwargs):
            nonlocal count
            count+=1;original(instance,*args,**kwargs)
        with patch.object(review.EmailMessage,'__init__',counted):
            with self.assertRaises(ValueError):review.analyze(raw)
        self.assertEqual(count,256)

    def test_hostile_structure_finishes_unavailable_in_cli(self):
        import subprocess
        deep=b'Content-Type: text/plain\r\n\r\nx\r\n'
        for i in range(200):
            b=str(i).encode();deep=b'Content-Type: multipart/mixed; boundary=b'+b+b'\r\n\r\n--b'+b+b'\r\n'+deep+b'--b'+b+b'--\r\n'
        many=b'Content-Type: multipart/mixed; boundary=b\r\n\r\n'+b'--b\r\nContent-Type: text/plain\r\n\r\nx\r\n'*5000+b'--b--\r\n'
        for index,raw in enumerate([deep,many]):
            path=self.root/('hostile'+str(index));path.write_bytes(raw)
            result=subprocess.run([sys.executable,str(ROOT/'plugin/scripts/draft-render-review.py'),'prepare','--source',str(path),'--output',str(self.root/('out'+str(index)))],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,1,result.stderr)
            self.assertIn('UNAVAILABLE',result.stderr)
            self.assertFalse((self.root/('out'+str(index))).exists())

    def test_source_symlink_refused(self):
        link=self.root/'link.eml';link.symlink_to(self.source)
        with self.assertRaises((ValueError,OSError)):review.prepare(link,self.bundle)

if __name__=='__main__':unittest.main()
