#!/usr/bin/env python3
"""Offline MIME review preparation. No networking, rendering, or send authorization."""
import argparse
from email import policy
from email.parser import BytesFeedParser
from email.message import EmailMessage
import hashlib
from html.parser import HTMLParser
import json
import os
import re
from pathlib import Path
import stat
import sys

MAX_BYTES=16*1024*1024

def digest(data): return hashlib.sha256(data).hexdigest()
def canonical(value): return json.dumps(value,ensure_ascii=True,sort_keys=True,separators=(',',':')).encode('ascii')

def read_regular(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as source:
        info=os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size>MAX_BYTES:
            raise ValueError('source must be a regular file no larger than 16 MiB')
        data=source.read(MAX_BYTES+1)
    if len(data)>MAX_BYTES: raise ValueError('source exceeds 16 MiB')
    return data

class Risks(HTMLParser):
    def __init__(self): super().__init__(convert_charrefs=True);self.flags=set()
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag=='blockquote' and (attrs.get('type') or '').lower()=='cite':self.flags.add('cite_quote')
        if 'apple-mail-urlshare' in (attrs.get('class') or '').lower():self.flags.add('apple_wrapper')
        if 'style' in attrs or tag=='style':self.flags.add('client_dependent_css')
        if tag in ('script','iframe','object','embed','form') or any(k.startswith('on') for k in attrs):self.flags.add('active_markup')
        if any((attrs.get(k) or '').strip().lower().startswith(('http:','https:','//')) for k in ('src','srcset','background')):
            self.flags.add('remote_resource')
    handle_startendtag=handle_starttag

def analyze(raw):
    if len(raw)>MAX_BYTES: raise ValueError('source exceeds 16 MiB')
    created=0
    class BudgetMessage(EmailMessage):
        def __init__(self,*args,**kwargs):
            nonlocal created
            created+=1
            if created>256:raise ValueError('MIME part limit exceeded during parsing')
            self.review_depth=0
            super().__init__(*args,**kwargs)
        def attach(self,payload):
            payload.review_depth=self.review_depth+1
            if payload.review_depth>16:raise ValueError('MIME depth limit exceeded during parsing')
            super().attach(payload)
    try:
        parser=BytesFeedParser(policy=policy.default.clone(message_factory=BudgetMessage))
        for offset in range(0,len(raw),65536):parser.feed(raw[offset:offset+65536])
        message=parser.close()
    except (ValueError,RecursionError) as exc: raise ValueError('MIME parsing failed or budget exceeded') from exc
    warnings=set();count=0
    def tree(part,depth=0,embedded=False):
        nonlocal count
        count+=1
        if count>256 or depth>16: raise ValueError('MIME part/depth limit exceeded')
        if part.defects: raise ValueError('MIME parsing defects; review source capture')
        for key,value in part.items():
            if getattr(value,'defects',()):raise ValueError('MIME/header parsing defects')
        for key in ('Content-Type','Content-Transfer-Encoding','Content-Disposition','Content-ID','Content-Location','Content-Base'):
            if len(part.get_all(key,[]))>1:raise ValueError('ambiguous MIME headers')
        encoding=part.get('Content-Transfer-Encoding','7bit').lower().strip()
        if encoding not in ('7bit','8bit','binary','quoted-printable','base64'):
            raise ValueError('unsupported transfer encoding')
        def params(header):
            return sorted([[str(k).lower(),str(v)] for k,v in (part.get_params(header=header,unquote=True) or [])[1:]
                           if str(k).lower()!='boundary'])
        node={'type':part.get_content_type(),'type_params':params('content-type'),
              'disposition':part.get_content_disposition(),'disposition_params':params('content-disposition'),
              'content_id':str(part.get('Content-ID','')),'location':str(part.get('Content-Location','')),
              'base':str(part.get('Content-Base','')),'language':str(part.get('Content-Language',''))}
        if embedded:
            node['message_headers']=[[k.lower(),str(v)] for k,v in part.items()
                                     if k.lower() not in ('content-type','content-transfer-encoding')]
        if part.is_multipart():
            node['children']=[tree(child,depth+1,part.get_content_maintype()=='message') for child in part.iter_parts()]
        else:
            if encoding=='quoted-printable':
                try: encoded=part.get_payload().encode('ascii')
                except (AttributeError,UnicodeError) as exc:raise ValueError('non-ASCII quoted-printable input') from exc
                # Accepted capture profile: ASCII QP with hex escapes and
                # CRLF/LF soft breaks; no bare '=', control bytes or trailing WSP.
                if re.search(rb'=(?![0-9A-Fa-f]{2}|\r?\n)',encoded):raise ValueError('malformed quoted-printable escape')
                if re.search(rb'[^\x09\x0a\x0d\x20-\x7e]',encoded) or re.search(rb'\r(?!\n)',encoded):raise ValueError('invalid quoted-printable bytes')
                if any(line.endswith((b' ',b'\t')) for line in encoded.splitlines()):raise ValueError('quoted-printable trailing whitespace')
            body=part.get_payload(decode=True)
            if body is None or part.defects:raise ValueError('MIME transfer decoding failed')
            if encoding=='7bit' and any(byte>127 for byte in body):raise ValueError('non-ASCII 7bit input')
            node['decoded_sha256']=digest(body)
            node['decoded_bytes']=len(body)
            if part.get_content_type()=='text/html':
                try: html=body.decode(part.get_content_charset() or 'ascii',errors='strict')
                except (LookupError,UnicodeError) as exc:raise ValueError('HTML charset could not be decoded') from exc
                scanner=Risks();scanner.feed(html);scanner.close();warnings.update(scanner.flags)
        return node
    try: mime=tree(message)
    except (RecursionError,TypeError) as exc:raise ValueError('unsupported MIME structure') from exc
    return {'schema_version':1,'source_sha256':digest(raw),'content_sha256':digest(canonical(mime)),
            'part_count':count,'warnings':sorted(warnings),'status':'pending_client_review',
            'client_render_verified':False}

def write_private(directory,name,data):
    fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)
    with os.fdopen(fd,'wb') as target:target.write(data);target.flush();os.fsync(target.fileno())

def prepare(source,output):
    raw=read_regular(source);report=analyze(raw)
    os.mkdir(output,0o700)
    directory=os.open(output,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        info=os.fstat(directory)
        if info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o700:
            raise ValueError('review directory must be private and owned by this user')
        write_private(directory,'source.eml',raw)
        # Metadata is the final completion marker. A partial bundle cannot compare.
        write_private(directory,'review.json',canonical(report)+b'\n')
        os.fsync(directory)
    finally:os.close(directory)
    return report

def unique_object(pairs):
    value={}
    for key,item in pairs:
        if key in value:raise ValueError('duplicate review metadata key')
        value[key]=item
    return value

def compare(bundle,current_source,received):
    # No claims about live Mail identity: these are caller-supplied captures.
    snapshot=read_regular(Path(bundle)/'source.eml')
    expected=analyze(snapshot)
    stored=json.loads(read_regular(Path(bundle)/'review.json'),object_pairs_hook=unique_object)
    if canonical(stored)!=canonical(expected):raise ValueError('review bundle integrity mismatch')
    current=analyze(read_regular(current_source));copy=analyze(read_regular(received))
    same_source=current['source_sha256']==expected['source_sha256']
    same_content=copy['content_sha256']==expected['content_sha256']
    status='source_changed' if not same_source else ('content_differs' if not same_content else 'ready_for_client_review')
    return {'schema_version':1,'status':status,'snapshot_matches':same_source,'content_matches':same_content,
            'client_render_verified':False,'source_sha256':expected['source_sha256'],
            'current_sha256':current['source_sha256'],'received_sha256':copy['source_sha256'],
            'warnings':sorted(set(expected['warnings'])|set(copy['warnings']))}

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    prep=sub.add_parser('prepare');prep.add_argument('--source',type=Path,required=True);prep.add_argument('--output',type=Path,required=True)
    comp=sub.add_parser('compare');comp.add_argument('--review',type=Path,required=True);comp.add_argument('--current-source',type=Path,required=True);comp.add_argument('--received',type=Path,required=True)
    args=parser.parse_args(argv)
    try:
        result=prepare(args.source,args.output) if args.command=='prepare' else compare(args.review,args.current_source,args.received)
    except (ValueError,OSError,UnicodeError,RecursionError) as exc:
        print(f'RENDER_REVIEW_UNAVAILABLE: {exc}',file=sys.stderr);return 1
    print(json.dumps(result,ensure_ascii=False,sort_keys=True))
    return 2 if result['status'] in ('source_changed','content_differs') else 0

if __name__=='__main__':raise SystemExit(main())
