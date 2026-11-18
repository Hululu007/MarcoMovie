// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
const dns = require('node:dns');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const zlib = require('node:zlib');
const iconv = require('./drpy-encoding.cjs');
const {MAX_RESULT} = require('./drpy-schema.cjs');

const dohCache = new Map();
const DOH_TTL_MS = 10 * 60 * 1000;
const DOH_ENDPOINTS = [
  'https://223.5.5.5/resolve?type=1&name=',
  'https://1.12.12.12/resolve?type=1&name=',
];

function isPublicResolvableHostname(hostname) {
  const h = String(hostname || '').trim().toLowerCase().replace(/\.$/, '');
  if (!h || net.isIP(h) !== 0) return false;
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') ||
      h.endsWith('.invalid') || h.endsWith('.test') || h.endsWith('.example')) {
    return false;
  }
  return h.includes('.');
}

function isPoisonedOrBogonIp(addr) {
  const ip = String(addr || '').trim();
  if (!ip) return true;
  if (net.isIP(ip) === 4) {
    const parts = ip.split('.').map(Number);
    if (parts.length !== 4 || parts.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return true;
    const [a, b] = parts;
    // 0.0.0.0/8, 127.0.0.0/8, 198.18.0.0/15 (FakeIP), 240.0.0.0/4
    return a === 0 || a === 127 || (a === 198 && (b === 18 || b === 19)) || a >= 240;
  }
  if (net.isIP(ip) === 6) {
    const lower = ip.toLowerCase();
    return lower === '::' || lower === '::1' || lower === '0:0:0:0:0:0:0:0' || lower === '0:0:0:0:0:0:0:1';
  }
  return true;
}

function queryDohEndpoint(endpointUrl, timeoutMs) {
  return new Promise(resolve => {
    let settled = false;
    const done = ip => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { req.destroy(); } catch (_) {}
      resolve(ip);
    };
    const req = https.get(endpointUrl, { headers: { Accept: 'application/dns-json, application/json' } }, res => {
      if (res.statusCode !== 200) { res.resume(); return done(''); }
      let size = 0;
      const chunks = [];
      res.on('data', c => {
        size += c.length;
        if (size > 65536) done('');
        else chunks.push(c);
      });
      res.on('end', () => {
        try {
          const doc = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          const answers = Array.isArray(doc?.Answer) ? doc.Answer : [];
          for (const ans of answers) {
            const candidate = String(ans?.data || '').trim();
            if (ans?.type === 1 && net.isIP(candidate) === 4 && !isPoisonedOrBogonIp(candidate)) {
              return done(candidate);
            }
          }
        } catch (_) {}
        done('');
      });
      res.on('error', () => done(''));
    });
    const timer = setTimeout(() => done(''), Math.max(300, Math.min(timeoutMs, 1800)));
    req.on('error', () => done(''));
  });
}

async function resolveCleanHostIp(hostname, budgetMs, forceDoh) {
  const cleanHost = String(hostname || '').trim().toLowerCase();
  if (!isPublicResolvableHostname(cleanHost)) return '';
  const cached = dohCache.get(cleanHost);
  if (cached && cached.expires > Date.now()) return cached.ip;
  if (!forceDoh) {
    const sysOk = await new Promise(resolve => {
      dns.lookup(cleanHost, { all: true }, (err, list) => {
        if (err || !Array.isArray(list) || !list.length) return resolve(false);
        resolve(list.some(item => item && !isPoisonedOrBogonIp(item.address)));
      });
    });
    if (sysOk) return '';
  }
  if (budgetMs < 400) return '';
  for (const prefix of DOH_ENDPOINTS) {
    const ip = await queryDohEndpoint(prefix + encodeURIComponent(cleanHost), Math.min(1400, budgetMs));
    if (ip) {
      if (dohCache.size >= 256) dohCache.delete(dohCache.keys().next().value);
      dohCache.set(cleanHost, { ip, expires: Date.now() + DOH_TTL_MS });
      return ip;
    }
  }
  return '';
}

function decodeText(bytes, charset) {
  // NodeMobile is built without ICU. These common Chinese encodings must not
  // depend on TextDecoder availability; keep its existing behavior elsewhere.
  const label=charset.trim().toLowerCase().replace(/[-_]/g,'');
  if(['gbk','gb2312','gb231280','csgb2312','csiso58gb231280','chinese','isoir58','xgbk','cp936','ms936','windows936'].includes(label))return iconv.decode(bytes,'gbk');
  if(label==='gb18030')return iconv.decode(bytes,'gb18030');
  if(['big5','big5hkscs','cnbig5','csbig5','xxbig5','cp950','windows950'].includes(label))return iconv.decode(bytes,'big5');
  return new TextDecoder(charset).decode(bytes);
}

// One instance per source worker. No shared cookie state or credential cache.
class SourceHttp {
  constructor(manifest) { this.manifest=manifest; this.pending=new Map(); this.closed=false; }
  cancel(id) {
    const entry=this.pending.get(id);
    if (!entry) return;
    this.pending.delete(id); clearTimeout(entry.timer);
    entry.request?.destroy(); entry.response?.destroy(); entry.stream?.destroy();
  }
  close() { this.closed=true; for(const id of [...this.pending.keys()]) this.cancel(id); }
  receive(message) {
    if (message.kind === 'cancel') return this.cancel(message.id);
    if (message.kind !== 'http' || this.closed) return;
    const {id,buffer}=message;
    if (!Number.isSafeInteger(id) || !(buffer instanceof SharedArrayBuffer) || buffer.byteLength !== MAX_RESULT+16 || this.pending.has(id)) return;
    const entry={request:null,response:null,stream:null,timer:null}; this.pending.set(id,entry);
    const finish=(value,error=false)=>{
      if(this.pending.get(id)!==entry)return;
      this.pending.delete(id);clearTimeout(entry.timer);
      let body=Buffer.from(JSON.stringify(value));
      if(body.length>MAX_RESULT){error=true;body=Buffer.from('{"error":"drpy_http_response_too_large"}');}
      Buffer.from(buffer,16,body.length).set(body);
      const state=new Int32Array(buffer,0,4);
      Atomics.store(state,1,body.length);Atomics.store(state,0,error?2:1);Atomics.notify(state,0);
    };
    const fail=code=>{finish({error:code},true);entry.request?.destroy();entry.response?.destroy();entry.stream?.destroy();};
    try {
      const options=message.options || {};
      const remaining=Number(message.deadline)-Date.now();
      const duration=Math.min(Math.max(Number(options.timeout)||this.manifest.requestTimeoutMs,100),15000,remaining);
      if(!Number.isFinite(duration)||duration<=0)throw Error('drpy_http_timeout');
      entry.timer=setTimeout(()=>fail('drpy_http_timeout'),duration);
      let url=new URL(message.url,this.manifest.origin);
      const inputHeaders=Object.create(null);
      if(url.origin===new URL(this.manifest.origin).origin)Object.assign(inputHeaders,this.manifest.headers);
      if(options.headers && typeof options.headers==='object' && !Array.isArray(options.headers))Object.assign(inputHeaders,options.headers);
      const headers=Object.create(null);
      for(const [key,value] of Object.entries(inputHeaders)) {
        if(!/^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(key)||typeof value!=='string'||/[\r\n\0]/.test(value)||value.length>8192)throw Error('drpy_http_headers');
        if(!/^(host|connection|content-length|transfer-encoding|accept-encoding)$/i.test(key))headers[key.toLowerCase()]=value;
      }
      headers['accept-encoding']='gzip, deflate';
      if(url.username||url.password){
        if(!headers.authorization)headers.authorization='Basic '+Buffer.from(decodeURIComponent(url.username)+':'+decodeURIComponent(url.password)).toString('base64');
        url.username='';url.password='';
      }
      let method=String(options.method||'GET').toUpperCase();
      if(!['GET','POST','HEAD','PUT','PATCH','DELETE','OPTIONS'].includes(method))throw Error('drpy_http_method');
      let body=options.body ?? options.data;
      if(body!=null && typeof body!=='string')body=JSON.stringify(body);
      let bodyBuffer=body!=null && !['GET','HEAD'].includes(method)?Buffer.from(body,'utf8'):null;
      if(bodyBuffer && bodyBuffer.length>MAX_RESULT)throw Error('drpy_http_body_too_large');
      if(bodyBuffer)headers['content-length']=String(bodyBuffer.length);
      const request=async(target,redirects,dohRetried=false)=>{
        if(this.pending.get(id)!==entry)return;
        if(!['http:','https:'].includes(target.protocol))return fail('drpy_http_protocol');
        if(target.username||target.password)return fail('drpy_redirect_credentials');
        let pinnedIp='';
        if(isPublicResolvableHostname(target.hostname)){
          pinnedIp=await resolveCleanHostIp(target.hostname,Number(message.deadline)-Date.now(),dohRetried);
          if(this.pending.get(id)!==entry)return;
        }
        let redirected=false;
        let gotHeaders=false;
        const reqOptions={method,headers};
        if(pinnedIp){
          reqOptions.lookup=(_h,opts,cb)=>opts&&opts.all?cb(null,[{address:pinnedIp,family:4}]):cb(null,pinnedIp,4);
        }
        const client=(target.protocol==='https:'?https:http).request(target,reqOptions,response=>{
          gotHeaders=true;
          entry.response=response;
          response.on('error',()=>{if(!redirected)fail('drpy_http_response_failed');});
          if([301,302,303,307,308].includes(response.statusCode)&&response.headers.location&&options.redirect!==0&&options.redirect!==false){
            redirected=true;
            response.resume();
            if(redirects>=5)return fail('drpy_http_redirect_limit');
            let next;
            try{next=new URL(response.headers.location,target);}catch(_){return fail('drpy_http_redirect');}
            if(next.origin!==target.origin){delete headers.authorization;delete headers.cookie;delete headers.cookie2;delete headers['proxy-authorization'];}
            if(response.statusCode===303&&method!=='HEAD'||[301,302].includes(response.statusCode)&&method==='POST'){
              method='GET';body=null;bodyBuffer=null;delete headers['content-type'];delete headers['content-length'];
            }
            return request(next,redirects+1,false);
          }
          let source=response;
          const encoding=String(response.headers['content-encoding']||'').toLowerCase();
          if(encoding==='gzip')source=response.pipe(zlib.createGunzip());
          else if(encoding==='deflate')source=response.pipe(zlib.createInflate());
          else if(encoding==='br')source=response.pipe(zlib.createBrotliDecompress());
          entry.stream=source;
          let size=0;const chunks=[];
          source.on('data',chunk=>{size+=chunk.length;if(size>MAX_RESULT)fail('drpy_http_response_too_large');else chunks.push(chunk);});
          source.on('error',()=>fail('drpy_http_response_failed'));
          source.on('end',()=>{
            try {
              const bytes=Buffer.concat(chunks);
              const responseHeaders=Object.fromEntries(Object.entries(response.headers).map(([k,v])=>[k,Array.isArray(v)?v.join('\n'):String(v??'')]));
              // Explicit call encoding can correct a bad response header. A
              // rule's inherited default only applies when neither declares it.
              const charset=String(options.encoding||/charset\s*=\s*["']?([^;\s"']+)/i.exec(String(response.headers['content-type']||''))?.[1]||message.sourceEncoding||'utf-8');
              const content=options.buffer===2?bytes.toString('base64'):decodeText(bytes,charset);
              finish({code:response.statusCode,content,headers:responseHeaders,url:target.href});
            }catch(_){fail('drpy_http_encoding');}
          });
        });
        entry.request=client;client.on('error',err=>{
          if(redirected||this.pending.get(id)!==entry)return;
          const code=String(err&&err.code||'');
          if(!gotHeaders&&!dohRetried&&!pinnedIp&&isPublicResolvableHostname(target.hostname)&&
             ['ENOTFOUND','EAI_AGAIN','ESERVFAIL','ECONNREFUSED','ECONNRESET','ETIMEDOUT'].includes(code)&&
             Number(message.deadline)-Date.now()>1200){
            return request(target,redirects,true);
          }
          fail('drpy_http_connection_failed');
        });
        if(bodyBuffer)client.write(bodyBuffer);
        client.end();
      };
      request(url,0,false);
    }catch(error){fail(/^drpy_/.test(error.message)?error.message:'drpy_http_request');}
  }
}
module.exports={SourceHttp};
