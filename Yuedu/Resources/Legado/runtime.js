/* Independently implemented Legado host adapter for the iOS WebKit runtime.
 * Only explicitly exported JSON operations cross into native code. */
(function () {
  const nativeEval = (0, eval);
  const nativeString = String;
  const nativeJSON = JSON;
  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const text = value => value === null || value === undefined ? '' : typeof value === 'string' ? value : Array.isArray(value) ? value.map(text).join('\n') : value instanceof Node ? value.outerHTML || value.textContent || '' : typeof value === 'object' ? JSON.stringify(value) : String(value);
  const clone = value => JSON.parse(JSON.stringify(value === undefined ? null : value));
  const variableText = value => value == null ? '' : String(value);
  let state, sourceConfig, bridgeName, environment, currentContent, currentBook, currentChapter, stage, sourceHeaders, resolvingHeaders;
  let calls, logs, interactive, currentRequestOptions;
  const MAX_ITEMS = 20000, MAX_PAGES = 200;
  function bridge(action, payload) {
    if (++calls > 10000) throw Error('书源宿主调用过多');
    const answer = JSON.parse(prompt(bridgeName, JSON.stringify({action, payload: payload || {}})) || '{"error":"书源执行已取消"}');
    if (answer.error) throw Error(answer.error);
    return answer.value;
  }
  function util(method, ...args) { return bridge('utility', {method, arguments: args}); }
  function bytes(value, charset) {
    if (Array.isArray(value) || ArrayBuffer.isView(value)) return Array.from(value, n => Number(n) & 255);
    return util('encode', text(value), charset || 'UTF-8');
  }
  function decode(value, charset) { return util('decode', bytes(value), charset || 'UTF-8'); }
  function list(items) {
    const result = Array.from(items || []);
    Object.defineProperties(result, {
      size: {value: () => result.length}, get: {value: index => result[index]},
      add: {value: value => { result.push(value); return true; }},
      addAll: {value: values => { result.push(...Array.from(values)); return true; }},
      isEmpty: {value: () => result.length === 0}, toArray: {value: () => result.slice()},
      clear: {value: () => { result.length = 0; }},
      remove: {value: value => typeof value === 'number' ? result.splice(value, 1)[0] : result.splice(result.indexOf(value), 1)[0]}
    });
    return result;
  }
  function map(values) {
    const result = Object.assign(Object.create(null), values || {});
    Object.defineProperties(result, {
      get: {value: key => result[key] === undefined ? null : result[key]},
      put: {value: (key, value) => { const old = result[key]; result[key] = value; return old; }},
      putAll: {value: values => Object.assign(result, values)},
      containsKey: {value: key => own(result, key)}, size: {value: () => Object.keys(result).length},
      remove: {value: key => { const old = result[key]; delete result[key]; return old; }},
      keySet: {value: () => list(Object.keys(result))}, values: {value: () => list(Object.values(result))},
      isEmpty: {value: () => Object.keys(result).length === 0}, toString: {value: () => JSON.stringify(result)}
    });
    return result;
  }
  function parseObject(value) {
    if (!value) return {};
    if (typeof value === 'object') return value;
    const raw = String(value).trim();
    try { return JSON.parse(raw); } catch (_) { return nativeEval('(' + raw + ')'); }
  }
  function variableObject(object) {
    object = Object.assign({}, object || {});
    object.__variables = object.__variables || {};
    Object.defineProperties(object, {
      getVariable: {value: key => key === undefined ? JSON.stringify(object.__variables) : object.__variables[key] || ''},
      putVariable: {value: (key, value) => { object.__variables[key] = variableText(value); return value; }},
      setVariable: {value: value => { object.__variables = typeof value === 'object' ? value : parseObject(value); }},
      setType: {value: value => { object.type = Number(value); }},
      setReverseToc: {value: value => { object.reverseToc = !!value; }},
      putImgUrl: {value: (key, value) => { object.__variables['image:' + key] = text(value); }}
    });
    return object;
  }
  function getVar(key) {
    for (const container of [currentChapter && currentChapter.__variables, currentBook && currentBook.__variables, state.variables]) {
      if (container && own(container, key)) return container[key];
    }
    return '';
  }
  function putVar(key, value) {
    const target = currentChapter ? currentChapter.__variables : currentBook ? currentBook.__variables : state.variables;
    target[key] = variableText(value);
    return value;
  }
  function evalJS(code, result) {
    const previous = globalThis.result;
    globalThis.result = LegadoRules.wrap(result);
    try {
      const output = nativeEval(String(code));
      return output === undefined ? globalThis.result : output;
    } finally { globalThis.result = previous; }
  }
  function context(content, base) {
    currentContent = content;
    globalThis.src = LegadoRules.wrap(content);
    globalThis.title = currentChapter && currentChapter.title || '';
    globalThis.nextChapterUrl = currentChapter && currentChapter.nextChapterUrl || '';
    if (base) globalThis.baseUrl = base;
    environment = {baseURL: globalThis.baseUrl || sourceConfig.bookSourceUrl, evalJS, getVar, putVar};
    return environment;
  }
  function extract(content, rule, mode) {
    if (rule === undefined || rule === null || rule === '') return mode === 'string' ? '' : [];
    return LegadoRules.extract(content, String(rule), context(currentContent, globalThis.baseUrl), mode || 'string');
  }
  function stripJS(code) { return String(code).replace(/^\s*@js\s*:/i, '').replace(/^\s*<js>/i, '').replace(/<\/js>\s*$/i, ''); }
  function template(value, encode) {
    return String(value).replace(/\{\{([\s\S]*?)\}\}/g, (_, code) => {
      let output;
      if (/^(?:\$[.\[]|@@|@css:|@json:|@xpath:)/i.test(code.trim())) output = extract(currentContent, code, 'string');
      else output = evalJS(code, currentContent);
      const string = text(output);
      return encode ? encodeURIComponent(string) : string;
    });
  }
  function absolute(url, base) {
    const value = String(url || '').trim();
    if (/^(data|https?):/i.test(value)) return value;
    try {
      // The HTTP adapter must encode a raw query in the source's charset.
      // URL.href would eagerly turn Chinese search terms into UTF-8 escapes.
      const query = value.indexOf('?');
      const fragment = value.indexOf('#');
      const split = query >= 0 ? query : fragment >= 0 ? fragment : value.length;
      const resolved = new URL(value, base || globalThis.baseUrl || sourceConfig.bookSourceUrl);
      return split < value.length ? resolved.origin + resolved.pathname + value.slice(split) : resolved.href;
    }
    catch (_) { throw Error('书源生成了无效网址'); }
  }
  function splitOptions(value) {
    const match = String(value).match(/,\s*\{/);
    if (!match) return [String(value).trim(), {}];
    const offset = match.index;
    return [String(value).slice(0, offset).trim(), parseObject(String(value).slice(offset + 1))];
  }
  function evaluateURL(raw) {
    let value = raw;
    if (typeof value !== 'string') return value;
    if (/^\s*@js:/i.test(value)) value = evalJS(stripJS(value), value);
    else if (/<js>/i.test(value)) {
      let prior = '', cursor = 0, match;
      const pattern = /<js>([\s\S]*?)<\/js>/gi;
      while ((match = pattern.exec(value))) {
        const prefix = value.slice(cursor, match.index).trim();
        if (prefix) prior = template(prefix, false);
        const output = evalJS(match[1], prior || value);
        if (output !== undefined && output !== null) prior = output;
        cursor = pattern.lastIndex;
      }
      const suffix = value.slice(cursor).trim();
      value = suffix ? suffix : prior;
    } else {
      const index = value.toLowerCase().indexOf('@js:');
      if (index >= 0) value = evalJS(value.slice(index + 4), template(value.slice(0, index), false));
    }
    return value;
  }
  function headers() {
    if (sourceHeaders) return Object.assign({}, sourceHeaders, state.loginHeaders);
    if (resolvingHeaders) return Object.assign({}, state.loginHeaders);
    resolvingHeaders = true;
    try {
      let value = sourceConfig.header;
      if (typeof value === 'string' && /^\s*(?:@js:|<js>)/i.test(value)) value = evalJS(stripJS(value), '');
      sourceHeaders = value ? parseObject(value) : {};
      for (const key of Object.keys(sourceHeaders)) {
        if (sourceHeaders[key] === 'baseUrl' && /^(referer|origin)$/i.test(key)) sourceHeaders[key] = globalThis.baseUrl || sourceConfig.bookSourceUrl;
      }
      return Object.assign({}, sourceHeaders, state.loginHeaders);
    } finally { resolvingHeaders = false; }
  }
  function requestOptions(raw, overrides) {
    let value = evaluateURL(raw);
    if (value && typeof value === 'object') return {inline: value, url: globalThis.baseUrl || sourceConfig.bookSourceUrl};
    value = text(value);
    // Expand templates raw; the native HTTP layer applies charset encoding.
    const pair = splitOptions(value);
    let options = Object.assign({}, pair[1], overrides || {});
    const interpolate = input => String(input).replace(/\{\{([\s\S]*?)\}\}/g, (_, code) => {
      return text(evalJS(code, currentContent));
    });
    let url = interpolate(pair[0]);
    url = url.replace(/<([^<>]*)>/g, (_, pages) => { const choices = pages.split(','); return choices[Math.min(Math.max((globalThis.page || 1) - 1, 0), choices.length - 1)]; });
    url = absolute(url);
    options.headers = Object.assign({}, headers(), options.headers ? parseObject(options.headers) : {});
    if (typeof options.body === 'string') options.body = interpolate(options.body);
    else if (options.body && typeof options.body === 'object') {
      const walk = object => typeof object === 'string' ? template(object, false) : Array.isArray(object) ? object.map(walk) : object && typeof object === 'object' ? Object.fromEntries(Object.entries(object).map(([k,v]) => [k,walk(v)])) : object;
      options.body = walk(options.body);
    }
    options.url = url;
    options.cookieJar = sourceConfig.enabledCookieJar !== false;
    options.concurrentRate = state.concurrentRate || sourceConfig.concurrentRate || '';
    globalThis.java.url = url;
    globalThis.java.ruleUrl = String(raw);
    globalThis.java.headerMap = map(options.headers);
    if (options.js) {
      const result = evalJS(options.js, url);
      options.url = result ? absolute(text(result)) : globalThis.java.url;
      options.headers = Object.assign({}, globalThis.java.headerMap);
    }
    return options;
  }
  function responseObject(value) {
    let body = String(value.body || '');
    const getHeader = key => { const match = Object.keys(value.headers || {}).find(k => k.toLowerCase() === String(key).toLowerCase()); return match ? value.headers[match] : ''; };
    const response = {
      body: () => body, code: () => Number(value.status || 200), statusCode: () => Number(value.status || 200),
      header: getHeader, headers: key => key === undefined ? map(value.headers) : list(getHeader(key) ? [getHeader(key)] : []),
      url: () => String(value.url || ''), toString: () => body, bytes: () => util('base64Decode', value.bytes || ''),
      request: () => ({url: () => String(value.url || '')}),
      newBuilder: () => ({body: changed => { body = text(changed); return {build: () => response}; }, build: () => response})
    };
    response.raw = () => response;
    Object.defineProperty(response,'__nativeResponse',{value:()=>Object.assign({},value,{body})});
    return response;
  }
  function fetch(raw, overrides, checkLogin) {
    const options = requestOptions(raw, overrides);
    return performRequest(options,checkLogin);
  }
  function performRequest(options,checkLogin) {
    if (own(options, 'inline')) return {body: typeof options.inline === 'string' ? options.inline : JSON.stringify(options.inline), url: options.url, status: 200, headers: {}};
    let response;
    if (/^data:/i.test(options.url)) {
      const comma = options.url.indexOf(',');
      const meta = options.url.slice(0, comma);
      const content = options.url.slice(comma + 1);
      const data = /;base64/i.test(meta) ? util('base64Decode', content) : bytes(decodeURIComponent(content));
      // Legado custom data URLs expose bytes as hex; normal MIME text data URLs
      // retain their decoded string, matching their declared representation.
      const custom = options.type !== undefined && options.type !== null;
      response = {body: custom ? util('hexEncode', data) : decode(data), bytes: util('base64Encode', data), url: options.url, status: 200, headers: {}};
    } else {
      response = bridge('request', options);
      if (options.type !== undefined && options.type !== null) response.body = util('hexEncode', util('base64Decode', response.bytes));
    }
    if (checkLogin && sourceConfig.loginCheckJs) {
      currentRequestOptions=options;
      const returned = evalJS(stripJS(sourceConfig.loginCheckJs), responseObject(response));
      if (returned && typeof returned.__nativeResponse === 'function') response=returned.__nativeResponse();
      else if (returned && typeof returned.body === 'function') {
        response.body = text(returned.body());
        if(typeof returned.code === 'function')response.status=Number(returned.code());
        if(typeof returned.url === 'function')response.url=text(returned.url());
      }
      else if (typeof returned === 'string') response.body = returned;
    }
    return response;
  }
  function stageRequest(raw, overrides) {
    const response = fetch(raw, overrides, true);
    globalThis.baseUrl = response.url;
    globalThis.java.url = response.url;
    context(response.body, response.url);
    if (Number(response.status) >= 400) throw Error('服务器返回 HTTP ' + response.status + '；可检查登录状态或稍后重试');
    return response;
  }
  function cryptoWrapper(algorithm, key, iv) {
    const options = {algorithm: algorithm || 'AES', key: key == null ? [] : bytes(key), iv: iv == null ? [] : bytes(iv)};
    const api = {};
    for (const [method, field] of [['setKey','key'],['setIv','iv'],['setPublicKey','publicKey'],['setPrivateKey','privateKey']]) {
      api[method] = value => { options[field] = typeof value === 'string' && /Key$/.test(field) ? value : bytes(value); return api; };
    }
    const perform = (action, input) => util('crypto', Object.assign({}, options, {action, input: bytes(input)}));
    api.encrypt = input => perform('encrypt', input);
    api.decrypt = input => perform('decrypt', typeof input === 'string' ? util('base64Decode', input) : input);
    api.encryptBase64 = input => util('base64Encode', api.encrypt(input));
    api.encryptHex = input => util('hexEncode', api.encrypt(input));
    api.decryptStr = (input, charset) => decode(api.decrypt(input), charset);
    api.decryptBase64 = input => util('base64Encode', api.decrypt(input));
    api.sign = input => perform('sign', input);
    api.verify = (input, signature) => util('crypto', Object.assign({}, options, {action:'verify', input:bytes(input),signature:bytes(signature)}));
    return api;
  }
  function installHost() {
    const source = Object.assign({}, sourceConfig);
    source.key = sourceConfig.bookSourceUrl;
    source.getKey = () => sourceConfig.bookSourceUrl;
    source.getVariable = () => state.sourceVariable || '';
    source.setVariable = value => { state.sourceVariable = text(value); return value; };
    source.get = key => state.variables[key] || '';
    source.put = (key,value) => { state.variables[key] = variableText(value); return value; };
    source.getLoginInfoMap = () => map(state.loginInfo);
    source.putLoginInfo = value => { state.loginInfo = parseObject(value); };
    source.putLoginInfoMap = value => { state.loginInfo = clone(value); };
    source.removeLoginInfo = () => { state.loginInfo = {}; };
    source.getLoginHeaderMap = () => map(state.loginHeaders);
    source.getLoginHeader = () => JSON.stringify(state.loginHeaders);
    source.putLoginHeader = value => { state.loginHeaders = parseObject(value); sourceHeaders = null; };
    source.removeLoginHeader = () => { state.loginHeaders = {}; sourceHeaders = null; };
    source.putConcurrent = value => { state.concurrentRate = text(value); };
    source.refreshExplore = () => { state.exploreRevision = (state.exploreRevision || 0) + 1; };
    source.refreshJSLib = () => { state.libraryRevision = (state.libraryRevision || 0) + 1; };
    globalThis.source = source;

    const cookieCall = (action,url,value,key) => bridge('cookie',{action,url:text(url || source.getKey()),value:text(value),key});
    globalThis.cookie = {
      getKey: source.getKey,
      getCookie: (url,key) => cookieCall('get',url,null,key),
      setCookie: (url,value) => cookieCall('set',url,value),
      replaceCookie: (url,value) => cookieCall('replace',url,value),
      removeCookie: url => cookieCall('remove',url),
      setWebCookie: url => cookieCall('get',url)
    };
    const cacheRead = key => { const item = state.cache[key]; if (!item) return null; if (item.expires && Date.now() > item.expires) {delete state.cache[key];return null;} return item.value; };
    globalThis.cache = {
      get: cacheRead, getFromMemory: cacheRead,
      put: (key,value,seconds) => { state.cache[key] = {value:text(value),expires:seconds ? Date.now()+Number(seconds)*1000 : 0}; return value; },
      delete: key => { delete state.cache[key]; },
      putMemory: (key,value) => { state.cache[key] = {value:text(value),expires:0}; return value; },
      deleteMemory: key => { delete state.cache[key]; }
    };
    const log = value => { const message = text(value).slice(0,2000); if (logs.length < 100) logs.push(message); return value; };
    const browser = (url,title,js,html) => {
      const options=requestOptions(url);
      const response=bridge('browser',Object.assign({},options,{title:text(title),js:typeof js==='string'?js:'',html:html || '',interactive:true}));
      return response && typeof response==='object' ? responseObject(response) : response;
    };
    const java = {
      get: (key,headers,timeout) => headers === undefined && !/^https?:/i.test(String(key)) ? getVar(String(key)) : responseObject(fetch(key,{headers:headers || {},timeout})),
      put: putVar,
      ajax: (url,headers) => fetch(url,headers ? {headers:parseObject(headers)} : null).body,
      connect: (url,headers) => responseObject(fetch(url,headers ? {headers:parseObject(headers)} : null)),
      getStrResponse: url => responseObject(url === undefined && currentRequestOptions ? performRequest(Object.assign({},currentRequestOptions),false) : fetch(url)),
      post: (url,body,headers,timeout) => responseObject(fetch(url,{method:'POST',body,headers:headers || {},timeout})),
      head: (url,headers) => responseObject(fetch(url,{method:'HEAD',headers:headers || {}})),
      ajaxAll: urls => list(Array.from(urls).map(url => fetch(url).body)),
      ajaxTestAll: urls => list(Array.from(urls).map(url => { try {return fetch(url).status === 200 ? url : '';} catch(_){return '';} }).filter(Boolean)),
      getString: (rule,contentOrURL) => {
        const content = contentOrURL != null && typeof contentOrURL !== 'boolean' ? contentOrURL : currentContent;
        if(contentOrURL === true) { const value = extract(content,rule,'strings')[0]; return value ? absolute(value) : ''; }
        return extract(content,rule,'string');
      },
      getStringList: (rule,contentOrURL) => list(extract(contentOrURL != null && typeof contentOrURL !== 'boolean' ? contentOrURL : currentContent,rule,'strings').map(value => contentOrURL === true ? absolute(value) : value)),
      getElements: rule => list(extract(currentContent,rule,'elements').map(value => value instanceof Node ? LegadoRules.jsoup(value) : value)),
      getElement: rule => { const value = extract(currentContent,rule,'elements')[0]; return value instanceof Node ? LegadoRules.jsoup(value) : value; },
      setContent: (content,url) => { context(content,url); return content; },
      log, toast:log, longToast:log,
      md5Encode: value => util('digest','MD5',bytes(value),'hex'),
      digestHex: (value,algorithm) => util('digest',algorithm || 'MD5',bytes(value),'hex'),
      base64Encode: (value,flags) => util('base64Encode',bytes(value)).replace(flags === 2 ? /\r?\n/g : /$^/g,''),
      base64Decode: (value,charset) => decode(util('base64Decode',text(value)), typeof charset === 'string' ? charset : 'UTF-8'),
      base64DecodeToByteArray: value => list(util('base64Decode',text(value))),
      hexDecodeToByteArray: value => list(util('hexDecode',text(value))),
      hexDecodeToString: (value,charset) => decode(util('hexDecode',text(value)),charset),
      strToBytes: (value,charset) => list(bytes(value,charset)), bytesToStr:decode,
      encodeURI: (value,charset) => util('urlEncode',text(value),charset || 'UTF-8'),
      createSymmetricCrypto:cryptoWrapper, createAsymmetricCrypto:cryptoWrapper,
      aesBase64DecodeToString: (data,key,algorithmOrIV,iv) => cryptoWrapper(iv === undefined ? 'AES/CBC/PKCS5Padding' : algorithmOrIV,key,iv === undefined ? algorithmOrIV : iv).decryptStr(data),
      timeFormat: (time,pattern) => util('timeFormat',Number(time),pattern || 'yyyy-MM-dd HH:mm:ss'),
      timeFormatUTC: (time,pattern,timezone) => util('timeFormat',Number(time),pattern || 'yyyy-MM-dd HH:mm:ss', timezone || 'UTC'),
      randomUUID: () => util('randomUUID'),
      s2t: value => util('transform',text(value),'s2t'), t2s: value => util('transform',text(value),'t2s'),
      getWebViewUA: () => navigator.userAgent, getUserAgent: () => navigator.userAgent,
      deviceID: () => state.deviceID, androidId: () => state.deviceID,
      getCookie: (url,key) => cookieCall('get',url,null,key),
      webView: (html,url,js) => bridge('request',{url:absolute(url || baseUrl),html:text(html),webView:true,webJs:js || '',headers:headers()}).body,
      startBrowser: (url,title) => browser(url,title),
      startBrowserAwait: (url,title) => browser(url,title),
      startBrowserDp: (url,title) => browser(url,title),
      showBrowser: (url,title) => browser(url,title),
      openUrl: (url,title) => browser(url,title), open: (url,title) => browser(url,title),
      getVerificationCode: (imageURL,title) => bridge('browser',{method:'code',url:absolute(imageURL),message:text(title || '请输入图片中的验证码'),interactive:true}),
      copyText: value => bridge('clipboard',{text:text(value)}),
      upLoginData: value => { if(value) source.putLoginInfo(value); return source.getLoginInfoMap(); },
      refreshExplore: source.refreshExplore,
      refreshTocUrl: () => { if(currentBook) currentBook.tocUrl = currentBook.bookUrl; },
      initUrl: value => {
        if(value === undefined && currentRequestOptions) { java.url=currentRequestOptions.url;return java.url; }
        java.ruleUrl = text(value); currentRequestOptions=requestOptions(value);java.url=currentRequestOptions.url;return java.url;
      },
      toNumChapter: value => util('chapterNumber',text(value)),
      queryBase64TTF: value => ({fontBytes: util('base64Decode',text(value))}),
      queryTTF: url => ({fontBytes: util('base64Decode',fetch(url).bytes)}),
      replaceFont: (content,from,to) => util('fontReplace',from.fontBytes,to.fontBytes,text(content)),
      downloadFile: url => { const response = fetch(url);const name='source-cache:'+util('randomUUID');state.files[name]=response.bytes;return name; },
      readTxtFile: (path,charset) => { if(!own(state.files,path)) throw Error('书源只能读取它自己下载的缓存文件');return decode(util('base64Decode',state.files[path]),charset); },
      searchBook: (query) => { const result = runSearch(String(query),1); return list(result.items); },
      openVideoPlayer: () => { throw Error('此配置选择了视频内容；当前应用仅处理文字书源'); },
      qread: () => { throw Error('此操作需要平台专用外部阅读器'); }
    };
    java.webview = java.webView;
    java.startBrowserAwaitAwait = java.startBrowserAwait;
    globalThis.java = java;
    installJavaClasses(java);
  }
  function installJavaClasses(java) {
    function JavaString(value,charset) {
      const result = new nativeString(Array.isArray(value) ? decode(value,charset) : text(value));
      result.getBytes = encoding => list(bytes(result.valueOf(),encoding));
      result.equals = other => result.valueOf() === String(other);
      result.replaceAll = (pattern,replacement) => result.valueOf().replace(new RegExp(pattern,'g'),replacement);
      return result;
    }
    function ByteArrayOutputStream() { this.value = []; }
    ByteArrayOutputStream.prototype.write = function(value,offset,length) { this.value.push(...(Array.isArray(value) ? value.slice(offset || 0,length == null ? undefined : (offset || 0)+length) : [value & 255])); };
    ByteArrayOutputStream.prototype.toByteArray = function() { return list(this.value); };
    ByteArrayOutputStream.prototype.toString = function(charset) { return decode(this.value,charset); };
    ByteArrayOutputStream.prototype.close = function() {};
    function ByteArrayInputStream(value) { this.bytes = bytes(value); }
    function SecretKeySpec(value,algorithm) { this.bytes=bytes(value);this.algorithm=algorithm; }
    function IvParameterSpec(value) { this.bytes=bytes(value); }
    const Base64 = {
      decode: value => list(util('base64Decode',text(value))),
      encode: value => list(bytes(util('base64Encode',bytes(value)))),
      encodeToString: value => util('base64Encode',bytes(value)),
      getDecoder: () => ({decode:value=>list(util('base64Decode',text(value)))}),
      getEncoder: () => ({encodeToString:value=>util('base64Encode',bytes(value)),encode:value=>list(bytes(util('base64Encode',bytes(value))))}),
      DEFAULT:0, NO_WRAP:2, URL_SAFE:8
    };
    const Cipher = {ENCRYPT_MODE:1,DECRYPT_MODE:2,getInstance:algorithm=>{
      const options={algorithm};
      return {init:(mode,key,iv)=>{options.action=Number(mode)===1?'encrypt':'decrypt';if(key && key.publicKey)options.publicKey=key.publicKey;else if(key && key.privateKey)options.privateKey=key.privateKey;else options.key=key && key.bytes || bytes(key);options.iv=iv && iv.bytes || [];},
        doFinal:(value,offset,length)=>list(util('crypto',Object.assign({},options,{input:bytes(value).slice(offset || 0,length==null?undefined:(offset || 0)+length)}))),
        getBlockSize:()=>/RSA/i.test(algorithm)?256:/DES/i.test(algorithm)?8:16};
    }};
    const Mac={getInstance:algorithm=>{let key=[],data=[];return{init:value=>{key=value.bytes || bytes(value);},update:value=>{data.push(...bytes(value));},doFinal:value=>list(util('crypto',{algorithm,action:'sign',key,input:value==null?data:bytes(value)}))};}};
    java.lang={String:JavaString,Thread:{sleep:ms=>bridge('sleep',{milliseconds:Number(ms)})},System:{currentTimeMillis:()=>Date.now(),arraycopy:(src,start,dst,target,length)=>{for(let i=0;i<length;i++)dst[target+i]=src[start+i];}},Integer:{parseInt:(v,radix)=>parseInt(v,radix||10)},Long:{parseLong:v=>Number(v)}};
    java.util={ArrayList:function(values){return list(Array.isArray(values)?values:[]);},HashMap:function(values){return map(values);},Arrays:{copyOfRange:(values,start,end)=>list(values.slice(start,end)),copyOf:(values,length)=>list(Array.from({length},(_,i)=>values[i] || 0))},Base64,UUID:{randomUUID:()=>util('randomUUID')}};
    java.io={ByteArrayOutputStream,ByteArrayInputStream};
    java.security={MessageDigest:{getInstance:algorithm=>{let data=[];return{update:value=>{data.push(...bytes(value));},digest:value=>list(util('digest',algorithm,value==null?data:bytes(value),'bytes'))};}},
      KeyFactory:{getInstance:()=>({generatePublic:spec=>({publicKey:spec.bytes}),generatePrivate:spec=>({privateKey:spec.bytes})})},
      spec:{X509EncodedKeySpec:SecretKeySpec,PKCS8EncodedKeySpec:SecretKeySpec},interfaces:{}};
    const javax={crypto:{Cipher,Mac,spec:{SecretKeySpec,IvParameterSpec}}};
    const org={jsoup:{Jsoup:{parse:html=>LegadoRules.jsoup(html)},parser:{Parser:{unescapeEntities:html=>LegadoRules.htmlText(text(html))}}}};
    const android={util:{Base64},webkit:{CookieManager:{getInstance:()=>({getCookie:cookie.getCookie,setCookie:cookie.setCookie,removeAllCookies:()=>cookie.removeCookie(source.key),flush:()=>{}})}},graphics:{BitmapFactory:{decodeStream:stream=>{const bitmap=util('bitmapDecode',stream.bytes);return{getWidth:()=>bitmap.width,getHeight:()=>bitmap.height,getPixel:(x,y)=>{if(x<0||y<0||x>=bitmap.width||y>=bitmap.height)throw Error('像素索引越界');return bitmap.pixels[y*bitmap.width+x];}};}}}};
    function StrResponse(url,body) {return responseObject({url:text(url),body:text(body),status:200,headers:{}});}
    const io={legado:{app:{help:{http:{StrResponse,CookieStore:{setCookie:cookie.setCookie}}}}},legato:{kazusa:{utils:{TimeoutCancellationException:Error}}}};
    globalThis.Packages={java,javax,org,android,io};
    globalThis.javax=javax;globalThis.org=org;globalThis.android=android;
    globalThis.JavaImporter=function(...packages){const out={};out.importPackage=(...values)=>values.forEach(value=>Object.assign(out,value));out.importPackage(...packages);return out;};
    globalThis.importPackage=(...packages)=>packages.forEach(value=>Object.assign(globalThis,value));
    globalThis.importClass=value=>{if(value && value.name)globalThis[value.name]=value;};
  }
  function activateBook(value) {
    const url = value && (value.bookUrl || value.bookURL) || '';
    const saved = url && state.books[url] || {};
    currentBook = variableObject(Object.assign({name:'',author:'',bookUrl:url,origin:sourceConfig.bookSourceUrl,type:0},saved,value || {}));
    currentBook.__variables = Object.assign({},saved.__variables || {},value && value.__variables || {});
    globalThis.book = currentBook;
    currentChapter = null;
    globalThis.chapter = null;
  }
  function saveBook() {
    if (currentBook && currentBook.bookUrl) state.books[currentBook.bookUrl] = clone(currentBook);
  }
  function field(content, rules, key, mode) {
    const rule = rules && rules[key];
    if (!rule) return mode === 'strings' || mode === 'elements' ? [] : '';
    try { return extract(content,rule,mode || 'string'); }
    catch(error) { throw Error(stage + '.' + key + '：' + error.message); }
  }
  function optionalField(content,rules,key) {
    try{return field(content,rules,key);}catch(error){if(logs.length<100)logs.push(error.message);return '';}
  }
  function resolveLink(value, base) {
    const string = text(value).trim();
    if(!string) return '';
    const parts = splitOptions(string);
    const url=parts[0].split('\n').find(v=>v.trim()) || '';
    return absolute(url,base) + (Object.keys(parts[1]).length ? ','+JSON.stringify(parts[1]) : '');
  }
  function isTextBook(book) { return book.type == null || [0,8].includes(Number(book.type)); }
  function bool(value) { return /^(?:true|1|yes)$/i.test(text(value).trim()); }
  function searchRows(response, rules) {
    stage = rules === sourceConfig.ruleExplore ? 'ruleExplore' : 'ruleSearch';
    context(response.body,response.url);
    if(sourceConfig.bookUrlPattern && LegadoRules.regex(sourceConfig.bookUrlPattern,false).test(response.url))return singleBookResult(response);
    const prefix=typeof rules.bookList==='string' && /^[+-]/.test(rules.bookList);
    const rows = field(response.body,prefix?Object.assign({},rules,{bookList:rules.bookList.slice(1)}):rules,'bookList','elements');
    if(!Array.isArray(rows)) throw Error(stage+'.bookList：未返回列表');
    if(!rows.length)return singleBookResult(response);
    if(prefix && rules.bookList.startsWith('-'))rows.reverse();
    const items=[];
    const sharedVariables = clone(currentBook && currentBook.__variables || {});
    for(const row of rows.slice(0,100)) {
      activateBook({origin:sourceConfig.bookSourceUrl,type:0,__variables:clone(sharedVariables)});
      context(row,response.url);
      const metadata = {};
      for(const key of ['name','author','kind','wordCount','lastChapter','intro','coverUrl','bookUrl']) {
        const value = ['name','author','bookUrl'].includes(key)?field(row,rules,key):optionalField(row,rules,key);
        metadata[key] = text(value);
        if(value !== '') currentBook[key] = text(value);
      }
      currentBook.bookUrl = resolveLink(metadata.bookUrl || currentBook.bookUrl || response.url,response.url);
      if(!metadata.name || !currentBook.bookUrl || !isTextBook(currentBook)) continue;
      currentBook.name = metadata.name;
      saveBook();
      items.push({name:metadata.name,author:metadata.author,intro:metadata.intro,bookUrl:currentBook.bookUrl,context:clone(currentBook)});
    }
    return {items};
  }
  function runSearch(query,pageNumber) {
    globalThis.key=query;globalThis.page=pageNumber || 1;stage='searchUrl';
    activateBook({});
    context('',sourceConfig.bookSourceUrl);
    if(!sourceConfig.searchUrl) throw Error('此书源没有搜索规则，可使用发现分类');
    const response=stageRequest(sourceConfig.searchUrl);
    return searchRows(response,sourceConfig.ruleSearch || {});
  }
  function bookInfo(value) {
    activateBook(value);
    stage='ruleBookInfo';
    const response=stageRequest(currentBook.bookUrl);
    return parseBookInfo(response);
  }
  function parseBookInfo(response) {
    stage='ruleBookInfo';
    let content=response.body;
    const rules=sourceConfig.ruleBookInfo || {};
    if(rules.init) { content=field(content,rules,'init','elements'); if(Array.isArray(content) && content.length===1)content=content[0]; context(content,response.url); }
    for(const key of ['name','author','intro','kind','wordCount','lastChapter','coverUrl','tocUrl']) {
      const value=key==='tocUrl'?field(content,rules,key):optionalField(content,rules,key);
      if(value !== '')currentBook[key]=text(value);
    }
    currentBook.tocUrl=resolveLink(currentBook.tocUrl || currentBook.bookUrl,response.url);
    if(!isTextBook(currentBook))throw Error('此结果是漫画、有声或视频内容，已排除');
    saveBook();
    return {content,url:response.url};
  }
  function singleBookResult(response) {
    activateBook({bookUrl:response.url,__variables:clone(currentBook && currentBook.__variables || {})});
    context(response.body,response.url);
    parseBookInfo(response);
    if(!currentBook.name || !isTextBook(currentBook))return {items:[]};
    return {items:[{name:currentBook.name,author:currentBook.author || '',intro:currentBook.intro || '',bookUrl:currentBook.bookUrl,context:clone(currentBook)}]};
  }
  function runBook(value) {
    const detail=bookInfo(value);
    stage='ruleToc';
    const rules=sourceConfig.ruleToc || {};
    if(rules.preUpdateJs)evalJS(stripJS(rules.preUpdateJs),detail.content);
    const pending=[currentBook.tocUrl],visited=new Set(),seen=new Set(),chapters=[];
    let pageCount=0;
    while(pending.length) {
      const url=pending.shift(); if(!url || visited.has(url))continue;
      if(++pageCount>MAX_PAGES)throw Error('目录分页超过'+MAX_PAGES+'页，已停止，避免循环请求');
      visited.add(url);currentChapter=null;globalThis.chapter=null;
      const response=url===detail.url?{body:detail.content,url:detail.url}:stageRequest(url);
      context(response.body,response.url);
      const orderPrefix=typeof rules.chapterList==='string' && /^[+-]/.test(rules.chapterList);
      const rows=field(response.body,orderPrefix?Object.assign({},rules,{chapterList:rules.chapterList.slice(1)}):rules,'chapterList','elements');
      if(!Array.isArray(rows))throw Error('ruleToc.chapterList：未返回列表');
      for(const row of rows) {
        context(row,response.url);
        currentChapter=variableObject(Object.assign({title:'',url:'',bookUrl:currentBook.bookUrl,index:chapters.length},row && typeof row==='object' && !(row instanceof Node)?row:{}));
        globalThis.chapter=currentChapter;
        const name=field(row,rules,'chapterName'); if(name)currentChapter.title=text(name);
        currentChapter.isVolume=bool(field(row,rules,'isVolume'));
        currentChapter.isVip=bool(field(row,rules,'isVip'));
        currentChapter.isPay=bool(field(row,rules,'isPay'));
        currentChapter.updateTime=text(field(row,rules,'updateTime'));
        const path=field(row,rules,'chapterUrl');
        currentChapter.url=resolveLink(path || currentChapter.url || response.url,response.url);
        if(currentChapter.isVolume || !currentChapter.title)continue;
        const identity=rules.chapterUrl?currentChapter.url:currentChapter.url+'#'+currentChapter.index;
        if(seen.has(identity))continue;seen.add(identity);
        chapters.push({title:currentChapter.title,url:currentChapter.url,context:clone(currentChapter)});
        if(chapters.length>MAX_ITEMS)throw Error('目录超过'+MAX_ITEMS+'章');
      }
      currentChapter=null;globalThis.chapter=null;context(response.body,response.url);
      for(const next of field(response.body,rules,'nextTocUrl','strings')) {const link=resolveLink(next,response.url);if(link && !visited.has(link))pending.push(link);}
    }
    if(!!currentBook.reverseToc !== (typeof rules.chapterList==='string' && rules.chapterList.startsWith('-')))chapters.reverse();
    chapters.forEach((chapter,index)=>{chapter.context.index=index;chapter.context.nextChapterUrl=chapters[index+1] && chapters[index+1].url || '';});
    if(!chapters.length)throw Error('未解析到目录。可检查登录状态、网址或书源规则');
    if(!isTextBook(currentBook))throw Error('此结果是漫画、有声或视频内容，已排除');
    saveBook();
    return {book:clone(currentBook),chapters};
  }
  function runChapter(bookValue,chapterValue) {
    const incoming=bookValue || {};
    const saved=state.books[incoming.bookUrl] || {};
    // A shelf snapshot predates script changes made by earlier chapters. Keep
    // their mutable book fields/variables, while using the reader's position.
    const restored=Object.assign({},incoming,saved);
    for(const key of ['durChapterIndex','durChapterTitle'])if(own(incoming,key))restored[key]=incoming[key];
    activateBook(restored);
    currentChapter=variableObject(chapterValue || {});globalThis.chapter=currentChapter;
    const rules=sourceConfig.ruleContent || {};
    const pending=[currentChapter.url],visited=new Set(),parts=[];
    let pageCount=0;
    while(pending.length) {
      const url=pending.shift();if(!url || visited.has(url))continue;
      if(++pageCount>MAX_PAGES)throw Error('正文分页超过'+MAX_PAGES+'页，已停止，避免循环请求');
      visited.add(url);stage='ruleContent';
      const options=rules.webJs?{webView:true,webJs:rules.webJs}:{};
      const response=stageRequest(url,options);
      context(response.body,response.url);
      let content=field(response.body,rules,'content');
      if(rules.subContent)content=field(content,rules,'subContent');
      if(content)parts.push(text(content));
      const title=field(response.body,rules,'title');if(title)currentChapter.title=text(title);
      for(const next of field(response.body,rules,'nextContentUrl','strings')) {const link=resolveLink(next,response.url);if(link && link!==currentChapter.nextChapterUrl && !visited.has(link))pending.push(link);}
    }
    let content=parts.join('\n\n');
    if(rules.replaceRegex)content=extract(content,rules.replaceRegex,'string');
    content=LegadoRules.htmlText(content);
    if(rules.callBackJs)evalJS(stripJS(rules.callBackJs),content);
    saveBook();
    if(!content.trim())throw Error(currentChapter.isVip?'章节可能需要登录或订阅，请先在书源设置中完成授权':'未解析到正文，请检查书源规则或网站响应');
    return {content,chapter:clone(currentChapter),book:clone(currentBook)};
  }
  function categories() {
    stage='exploreUrl';context('',sourceConfig.bookSourceUrl);activateBook({});
    let raw=sourceConfig.exploreUrl || '';
    raw=evaluateURL(raw);
    if(typeof raw==='string') {
      const value=raw.trim();
      if(value.startsWith('[')||value.startsWith('{'))raw=parseObject(value);
      else raw=value.split(/\n|&&/).map(line=>{const i=line.indexOf('::');return i<0?null:{title:line.slice(0,i),url:line.slice(i+2)};}).filter(Boolean);
    }
    if(!Array.isArray(raw))raw=Object.entries(raw || {}).map(([title,url])=>({title,url}));
    return {categories:raw.map(item=>({title:text(item.title || item.name),url:text(item.url),style:item.style || {}}))};
  }
  function loadLibraries() {
    const raw=sourceConfig.jsLib;
    if(!raw)return;
    let libraries=raw;
    if(typeof libraries==='string' && libraries.trim().startsWith('[')) {try{libraries=JSON.parse(libraries);}catch(_){}}
    for(const item of Array.isArray(libraries)?libraries:[libraries]) {
      let code=text(item);
      if(/^https?:\/\/\S+$/i.test(code.trim()))code=fetch(code.trim()).body;
      evalJS(stripJS(code),'');
    }
  }
  function run(operation,payload) {
    sourceConfig=payload.source || {};
    bridgeName=payload.bridgeName;
    state=clone(payload.state || {});
    for(const name of ['variables','loginInfo','loginHeaders','cache','books','files'])state[name]=state[name] || {};
    state.deviceID=state.deviceID || 'yuedu-'+Math.random().toString(36).slice(2)+Date.now().toString(36);
    calls=0;logs=[];interactive=!!payload.interactive;sourceHeaders=null;resolvingHeaders=false;currentRequestOptions=null;
    currentContent='';currentBook=null;currentChapter=null;stage=operation;
    globalThis.baseUrl=sourceConfig.bookSourceUrl || 'https://localhost/';globalThis.key=payload.query || '';globalThis.page=payload.page || 1;
    try {
      installHost();activateBook(payload.book || {});context(payload.content || '',globalThis.baseUrl);
      if(operation!=='extract' && operation!=='evaluate' && operation!=='audit')loadLibraries();
      let result;
      switch(operation) {
      case 'search':result=runSearch(payload.query || '',payload.page || 1);break;
      case 'book':result=runBook(payload.book || {});break;
      case 'chapter':result=runChapter(payload.book,payload.chapter);break;
      case 'categories':result=categories();break;
      case 'loginUI':{
        let raw=sourceConfig.loginUi || [];
        if(typeof raw==='string' && /^\s*(?:@js:|<js>)/i.test(raw))raw=evalJS(stripJS(raw),'');
        if(typeof raw==='string')raw=parseObject(raw);
        result={items:Array.isArray(raw)?raw:[]};break;
      }
      case 'explore':globalThis.page=payload.page || 1;result=searchRows(stageRequest(payload.url),sourceConfig.ruleExplore || sourceConfig.ruleSearch || {});break;
      case 'extract':{
        const rows=payload.listRule?extract(payload.content,payload.listRule,'elements'):[payload.content];
        result={rows:rows.map(row=>{context(row,globalThis.baseUrl);return Object.fromEntries(Object.entries(payload.fields || {}).map(([key,rule])=>[key,text(extract(row,rule,'string'))]));})};break;
      }
      case 'evaluate':result={value:evalJS(payload.script,payload.result === undefined?'':payload.result)};break;
      case 'request':result={response:fetch(payload.url,payload.options,true)};break;
      case 'login':{
        if(payload.loginInfo)state.loginInfo=payload.loginInfo;
        if(payload.variable !== undefined)state.sourceVariable=text(payload.variable);
        let action=payload.action === undefined ? sourceConfig.loginUrl || '' : payload.action;
        if(typeof action==='string' && action.trim().startsWith('{')) {
          const config=parseObject(action);
          action=config.url && config.url !== 'null' ? config.url : '';
        }
        let value='';
        if(action && /^\s*https?:/i.test(action))value=bridge('browser',{url:action,title:sourceConfig.bookSourceName,interactive:true});
        else if(action) {
          if(payload.action && payload.action !== 'void 0' && sourceConfig.loginUrl && !/^\s*https?:/i.test(sourceConfig.loginUrl))evalJS(stripJS(sourceConfig.loginUrl),'');
          value=evalJS(stripJS(action),'');
        }
        result={value:value === undefined?null:value};break;
      }
      case 'audit':{
        const errors=[];
        for(const item of payload.scripts || [])try{new Function(stripJS(item.script));}catch(error){errors.push({path:item.path,error:error.message});}
        result={errors};break;
      }
      default:throw Error('未知书源操作：'+operation);
      }
      return Object.assign({},result,{state,logs});
    } catch(error) { return {error:stage+'：'+(error && error.message || String(error)),state,logs}; }
  }
  globalThis.Legado={run};
})();
