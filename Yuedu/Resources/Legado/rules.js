/* Yuedu rule interpreter. Independently implemented from documented rule behavior.
 * Runs in an isolated WebKit page. Parsed remote documents are never inserted into
 * the live page; script evaluation is exclusively the host's env.evalJS hook.
 */
(function (global) {
  'use strict';
  const MAX_RESULTS = 30000, MAX_DEPTH = 64;
  const isNode = value => value && typeof value.nodeType === 'number';
  const own = (object, key) => object != null && Object.prototype.hasOwnProperty.call(object, key);
  const unique = values => Array.from(new Set(values));
  function fail(message) { throw new Error('规则解析：' + message); }
  function bounded(values) { if (values.length > MAX_RESULTS) fail('匹配结果超过上限'); return values; }
  function unwrap(value) {
    if (value && value.__legadoNode) return value.__legadoNode;
    if (value && value.__legadoNodes) return value.__legadoNodes;
    return value;
  }
  function list(value) { value = unwrap(value); return value == null ? [] : Array.isArray(value) ? value : [value]; }
  function string(value) {
    value = unwrap(value);
    if (value == null) return '';
    if (Array.isArray(value)) return value.map(string).join('\n');
    if (isNode(value)) return value.nodeType === 9 ? value.documentElement.outerHTML : value.outerHTML || value.nodeValue || value.textContent || '';
    if (typeof value === 'object') return JSON.stringify(value);
    return String(value);
  }
  function unquote(value) {
    const s = value.trim();
    if (s.length < 2 || !['"', "'"].includes(s[0]) || s[s.length - 1] !== s[0]) return s;
    if (s[0] === '"') { try { return JSON.parse(s); } catch (_) {} }
    return s.slice(1, -1).replace(/\\([\\'"nrt])/g, (_, c) => ({ n: '\n', r: '\r', t: '\t' }[c] || c));
  }
  // All rule separators are recognized outside balanced brackets and quotes.
  function positions(text, separators) {
    const result = [], stack = [];
    let quote = '', escaped = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (escaped) { escaped = false; continue; }
      if (c === '\\') { escaped = true; continue; }
      if (quote) { if (c === quote) quote = ''; continue; }
      if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
      if ('([{'.includes(c)) { stack.push(c); continue; }
      if (')]}'.includes(c)) { stack.pop(); continue; }
      if (!stack.length) {
        const separator = separators.find(s => text.startsWith(s, i));
        if (separator) { result.push({ index: i, separator }); i += separator.length - 1; }
      }
    }
    return result;
  }
  function split(text, separator) {
    const result = []; let start = 0;
    for (const p of positions(text, [separator])) { result.push(text.slice(start, p.index)); start = p.index + separator.length; }
    result.push(text.slice(start)); return result;
  }
  function balancedEnd(text, start) {
    const close = { '(': ')', '[': ']', '{': '}' }[text[start]];
    let depth = 1, quote = '', escaped = false;
    for (let i = start + 1; i < text.length; i++) {
      const c = text[i];
      if (escaped) { escaped = false; continue; }
      if (c === '\\') { escaped = true; continue; }
      if (quote) { if (c === quote) quote = ''; continue; }
      if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
      if (c === text[start]) depth++;
      else if (c === close && --depth === 0) return i;
    }
    fail('括号未闭合');
  }
  function parseHTML(value) {
    value = unwrap(value);
    if (isNode(value)) return value;
    if (Array.isArray(value) && value.length === 1 && isNode(unwrap(value[0]))) return unwrap(value[0]);
    const html = string(value);
    if (/^\s*<\?xml\b/i.test(html)) return new DOMParser().parseFromString(html, 'application/xml');
    // A template retains table fragments, unlike parsing a bare <tr> as a page.
    if (/^\s*<(?:td|th|tr|tbody|thead|tfoot)\b/i.test(html)) {
      const doc = document.implementation.createHTMLDocument('');
      const template = doc.createElement('template'); template.innerHTML = html;
      const container = doc.createElement('div'); container.appendChild(template.content);
      return container;
    }
    return new DOMParser().parseFromString(html, 'text/html');
  }
  const blockTags = new Set('ADDRESS ARTICLE ASIDE BLOCKQUOTE BR DD DIV DL DT FIELDSET FIGCAPTION FIGURE FOOTER FORM H1 H2 H3 H4 H5 H6 HEADER HR LI MAIN NAV OL P PRE SECTION TABLE TBODY TD TH THEAD TR UL'.split(' '));
  function nodeText(node, direct) {
    if (!isNode(node)) return string(node);
    let result = '';
    function visit(parent) {
      for (const child of parent.childNodes || []) {
        if (child.nodeType === 3 || child.nodeType === 4) result += child.nodeValue;
        else if (child.nodeType === 1 && !/^(SCRIPT|STYLE)$/i.test(child.tagName)) {
          const space = blockTags.has(child.tagName);
          if (space) result += ' ';
          if (!direct) visit(child);
          if (space) result += ' ';
        }
      }
    }
    visit(node);
    return result.replace(/[\s\u00a0]+/g, ' ').trim();
  }
  function htmlText(html) {
    const raw = string(html);
    if (!/<\/?[A-Za-z][^>]*>/.test(raw)) {
      // JSON APIs commonly return plain text with intentional blank lines.
      // Decode entities without treating a literal '<' as a markup opener.
      const textarea = document.createElement('textarea');
      textarea.innerHTML = raw.replace(/</g, '&lt;');
      return textarea.value.replace(/\u00a0/g, ' ');
    }
    const root = parseHTML(html); let output = '';
    function walk(node) {
      if (node.nodeType === 3 || node.nodeType === 4) { output += node.nodeValue.replace(/\u00a0/g, ' '); return; }
      if (node.nodeType === 1 && /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|HEAD)$/i.test(node.tagName)) return;
      const block = node.nodeType === 1 && blockTags.has(node.tagName);
      if (block) output += '\n';
      for (const child of node.childNodes || []) walk(child);
      if (block) output += '\n';
    }
    walk(root.nodeType === 9 ? root.body || root : root);
    return output.replace(/\r\n?/g, '\n').split('\n').map(s => s.replace(/[\t \f]+/g, ' ').trim()).filter(Boolean).join('\n');
  }
  function regex(pattern, globalFlag) {
    let flags = globalFlag ? 'g' : '';
    pattern = String(pattern).replace(/\(\?([imsu]+)\)/g, (_, f) => { for (const c of f) if (!flags.includes(c)) flags += c; return ''; });
    pattern = pattern.replace(/\\Q([\s\S]*?)\\E/g, (_, s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).replace(/\\A/g, '^').replace(/\\[zZ]/g, '$');
    pattern = pattern.replace(/\\p\{IsHan\}/g, '\\p{Script=Han}');
    if (/\\[pP]\{/.test(pattern) && !flags.includes('u')) flags += 'u';
    try { return new RegExp(pattern, flags); } catch (_) { fail('正则表达式无效或包含不支持的 Java 正则扩展'); }
  }
  function replacementValue(template, match) {
    let result = '';
    for (let i = 0; i < template.length; i++) {
      if (template[i] === '\\' && i + 1 < template.length) result += template[++i];
      else if (template[i] === '$' && /\d/.test(template[i + 1] || '')) {
        let group = Number(template[++i]);
        while (/\d/.test(template[i + 1] || '') && group * 10 + Number(template[i + 1]) < match.length) group = group * 10 + Number(template[++i]);
        result += match[group] || '';
      } else if (template[i] === '$' && template[i + 1] === '{') {
        const end = template.indexOf('}', i + 2); if (end < 0) fail('正则替换分组未闭合');
        result += match.groups && match.groups[template.slice(i + 2, end)] || ''; i = end;
      } else result += template[i];
    }
    return result;
  }
  function replace(value, pattern, replacement, firstOnly) {
    const input = string(value); if (!pattern) return input;
    const re = regex(pattern, !firstOnly);
    if (firstOnly) { const m = re.exec(input); return m ? replacementValue(replacement, m) : ''; }
    return input.replace(re, function () {
      const args = Array.from(arguments), hasGroups = typeof args[args.length - 1] === 'object';
      const groups = hasGroups ? args.pop() : undefined; args.splice(-2); args.groups = groups;
      return replacementValue(replacement, args);
    });
  }
  function combine(rule, evaluate, keepEmpty) {
    const found = positions(rule, ['&&', '||', '%%']);
    if (!found.length) return evaluate(rule);
    const operator = found[0].separator, pieces = split(rule, operator), results = [];
    for (const piece of pieces) {
      const value = combine(piece.trim(), evaluate, keepEmpty);
      if (value.length || keepEmpty) results.push(value);
      if (operator === '||' && value.length) return value;
    }
    if (operator === '%%') {
      const result = []; // Legado interleaves up to the first result's length.
      for (let i = 0; i < (results[0] || []).length; i++) for (const values of results) if (i < values.length) result.push(values[i]);
      return bounded(result);
    }
    return bounded(results.flat());
  }
  function selectorTokens(selector) {
    const tokens = []; let start = 0, depth = 0, quote = '', escaped = false, relation = ' ';
    function append(end) { const part = selector.slice(start, end).trim(); if (part) { tokens.push({ selector: part, relation }); relation = ' '; } }
    for (let i = 0; i < selector.length; i++) {
      const c = selector[i];
      if (escaped) { escaped = false; continue; }
      if (c === '\\') { escaped = true; continue; }
      if (quote) { if (quote === c) quote = ''; continue; }
      if (c === '"' || c === "'") { quote = c; continue; }
      if (c === '[' || c === '(') depth++;
      else if (c === ']' || c === ')') depth--;
      else if (!depth && /[\s>+~]/.test(c)) {
        append(i);
        if (c !== ' ' && /[>+~]/.test(c)) relation = c;
        start = i + 1;
      }
    }
    append(selector.length); return tokens;
  }
  function compound(selector) {
    let native = ''; const checks = [];
    for (let i = 0; i < selector.length;) {
      if (selector[i] === '[') {
        const end = balancedEnd(selector, i), raw = selector.slice(i + 1, end).trim();
        const reg = raw.match(/^([^\s~]+)\s*~=\s*([\s\S]*)$/);
        const op = raw.match(/^([^\s=^$*!|]+)\s*([*^$|]?=|!=)\s*([\s\S]*)$/);
        if (reg) { const re = regex(unquote(reg[2]), false); checks.push(n => n.hasAttribute(reg[1]) && re.test(n.getAttribute(reg[1]))); }
        else if (raw.startsWith('^')) checks.push(n => Array.from(n.attributes || []).some(a => a.name.startsWith(raw.slice(1))));
        else if (raw === '*') checks.push(n => n.attributes.length > 0);
        else if (op && op[2] === '!=') checks.push(n => n.getAttribute(op[1]) !== unquote(op[3]));
        else if (op) native += '[' + op[1] + op[2] + JSON.stringify(unquote(op[3])) + ']';
        else native += selector.slice(i, end + 1);
        i = end + 1; continue;
      }
      const pseudo = selector.slice(i).match(/^:(containsOwn|containsWholeOwnText|containsWholeText|containsData|contains|matchesOwn|matchesWholeOwnText|matchesWholeText|matches|eq|lt|gt|has|not|is)\(/i);
      if (pseudo) {
        const open = i + pseudo[0].length - 1, end = balancedEnd(selector, open), arg = selector.slice(open + 1, end), type = pseudo[1].toLowerCase();
        if (type === 'has') checks.push(n => cssSelect(n, arg, false).length > 0);
        else if (type === 'not' || type === 'is') checks.push(n => matchesSelector(n, arg) === (type === 'is'));
        else if (['eq', 'lt', 'gt'].includes(type)) {
          const number = Number(arg.trim()); if (!Number.isInteger(number)) fail('伪类索引无效');
          checks.push(n => { const index = Array.from(n.parentNode?.children || []).indexOf(n); return type === 'eq' ? index === number : type === 'lt' ? index < number : index > number; });
        } else {
          const re = type.startsWith('matches') ? regex(arg, false) : null;
          const needle = unquote(arg).toLowerCase();
          checks.push(n => {
            const value = type.includes('whole') ? (type.includes('own') ? Array.from(n.childNodes).filter(c => c.nodeType === 3).map(c => c.nodeValue).join('') : n.textContent) : type === 'containsdata' ? Array.from(n.querySelectorAll('script,style')).map(c => c.textContent).join(' ') : nodeText(n, type.includes('own'));
            return re ? re.test(value) : String(value).toLowerCase().includes(needle);
          });
        }
        i = end + 1; continue;
      }
      native += selector[i++];
    }
    native = native.trim() || '*';
    return node => {
      let match; try { match = node.matches(native); } catch (_) { fail('CSS 选择器无效'); }
      return match && checks.every(check => check(node));
    };
  }
  function compiledSelector(selector, scope) {
    const tokens = selectorTokens(selector); if (!tokens.length) return () => false;
    const tests = tokens.map(t => compound(t.selector));
    function matches(node, index) {
      if (!node || node.nodeType !== 1 || !tests[index](node)) return false;
      if (index === 0) {
        if (tokens[0].relation === '>') return node.parentElement === scope;
        if (tokens[0].relation === '+') return node.previousElementSibling === scope;
        if (tokens[0].relation === '~') { for (let p = node.previousElementSibling; p; p = p.previousElementSibling) if (p === scope) return true; return false; }
        return true;
      }
      const relation = tokens[index].relation;
      if (relation === '>') return matches(node.parentElement, index - 1);
      if (relation === '+') return matches(node.previousElementSibling, index - 1);
      if (relation === '~') { for (let prev = node.previousElementSibling; prev; prev = prev.previousElementSibling) if (matches(prev, index - 1)) return true; return false; }
      for (let parent = node.parentElement; parent; parent = parent.parentElement) if (matches(parent, index - 1)) return true;
      return false;
    }
    return node => matches(node, tests.length - 1);
  }
  function matchesSelector(node, selector) { return split(selector, ',').some(part => compiledSelector(part.trim())(node)); }
  function cssSelect(root, selector, includeRoot = true) {
    root = parseHTML(root); selector = selector.trim();
    if (!selector) return Array.from(root.children || []);
    const candidates = Array.from(root.querySelectorAll ? root.querySelectorAll('*') : []);
    if (includeRoot && root.nodeType === 1) candidates.unshift(root);
    if (/^\s*[+~]/.test(selector)) for (let sibling = root.nextElementSibling; sibling; sibling = sibling.nextElementSibling) candidates.push(sibling, ...sibling.querySelectorAll('*'));
    const tests = split(selector, ',').map(s => compiledSelector(s.trim(), root));
    return bounded(candidates.filter(n => tests.some(test => test(n))));
  }
  function indexSpec(rule) {
    const bracket = rule.match(/\[\s*(!?)([-\d\s,:]+)\]\s*$/);
    if (bracket) return { selector: rule.slice(0, bracket.index).trim(), excluded: bracket[1] === '!', parts: bracket[2].split(','), ranges: true };
    const legacy = rule.match(/(?:\.?(!)|\.)(-?\d+(?::-?\d+)*)\s*$/);
    if (legacy) return { selector: rule.slice(0, legacy.index).replace(/\.$/, '').trim(), excluded: !!legacy[1], parts: legacy[2].split(':'), ranges: false };
    return { selector: rule.trim() };
  }
  function applyIndices(values, spec) {
    if (!spec.parts) return values;
    const size = values.length, indexes = [];
    const number = raw => { const n = Number(raw); if (!Number.isSafeInteger(n)) fail('列表索引超出整数范围'); return n; };
    function add(n) { if (n < 0) n += size; if (n >= 0 && n < size && !indexes.includes(n)) indexes.push(n); }
    for (const raw of spec.parts) {
      const p = raw.trim();
      if (spec.ranges && p.includes(':')) {
        const parts = p.split(':'); if (parts.length > 3) fail('列表切片格式无效');
        let start = parts[0].trim() === '' ? 0 : number(parts[0]), end = parts[1].trim() === '' ? size - 1 : number(parts[1]);
        if (start < 0) start += size; if (end < 0) end += size;
        if (!size || (start < 0 && end < 0) || (start >= size && end >= size)) continue;
        start = Math.max(0, Math.min(size - 1, start)); end = Math.max(0, Math.min(size - 1, end));
        let step = parts.length < 3 || !parts[2].trim() ? 1 : number(parts[2]);
        if (step <= 0) step = -step < size ? step + size : 1;
        for (let i = start; start <= end ? i <= end : i >= end; i += start <= end ? step : -step) add(i);
      } else add(number(p));
    }
    return spec.excluded ? values.filter((_, i) => !indexes.includes(i)) : indexes.map(i => values[i]);
  }
  function selectStep(root, rule) {
    const spec = indexSpec(rule), selector = spec.selector;
    let values;
    if (!selector || selector === 'children') values = Array.from(root.children || []);
    else {
      const shorthand = selector.match(/^(class|tag|id|text)\.([\s\S]+)$/);
      if (shorthand) {
        const all = Array.from(root.querySelectorAll('*')); if (root.nodeType === 1) all.unshift(root);
        const arg = shorthand[2];
        if (shorthand[1] === 'class') values = all.filter(n => arg.split(/\s+/).every(c => n.classList.contains(c)));
        else if (shorthand[1] === 'tag') values = all.filter(n => n.tagName.toLowerCase() === arg.toLowerCase());
        else if (shorthand[1] === 'id') values = all.filter(n => n.id === arg);
        else values = all.filter(n => nodeText(n, true).toLowerCase().includes(arg.toLowerCase()));
      } else values = cssSelect(root, selector);
    }
    return applyIndices(values, spec);
  }
  function outputNodes(nodes, attribute) {
    if (attribute === 'html' || attribute === 'all') {
      const html = nodes.map(n => {
        if (attribute === 'all') return string(n);
        const clone = n.cloneNode(true);
        for (const s of clone.querySelectorAll?.('script,style') || []) s.remove();
        return /^(SCRIPT|STYLE)$/i.test(clone.tagName || '') ? '' : string(clone);
      }).filter(Boolean).join('\n');
      return html ? [html] : [];
    }
    const result = nodes.map(n => {
      if (attribute === 'text') return nodeText(n, false);
      if (attribute === 'ownText') return nodeText(n, true);
      if (attribute === 'textNodes') return Array.from(n.childNodes || []).filter(c => c.nodeType === 3).map(c => c.nodeValue.trim()).filter(Boolean).join('\n');
      if (attribute.startsWith('abs:')) { const value = n.getAttribute?.(attribute.slice(4)) || ''; try { return new URL(value, n.ownerDocument.baseURI).href; } catch (_) { return value; } }
      return n.getAttribute?.(attribute) || '';
    }).filter(v => v.trim() !== '');
    return ['text', 'ownText', 'textNodes'].includes(attribute) ? result : unique(result);
  }
  function css(content, rule, mode) {
    const forced = /^@css:/i.test(rule); if (forced) rule = rule.slice(5);
    rule = rule.replace(/^@@/, '').replace(/^@/, '');
    return combine(rule, branch => {
      const branchForced = forced || /^@css:/i.test(branch);
      branch = branch.replace(/^@css:/i, '').replace(/^@@/, '');
      let nodes = list(content).map(parseHTML), parts = split(branch, '@').map(s => s.trim());
      while (parts.length > 1 && !parts[parts.length - 1]) parts.pop();
      let attribute = null;
      if (mode !== 'elements') attribute = parts.pop() || 'text';
      if (branchForced) { const selector = parts.join('@'); if (selector) nodes = nodes.flatMap(n => cssSelect(n, selector)); }
      else for (const part of parts) nodes = bounded(nodes.flatMap(n => selectStep(n, part)));
      return attribute == null ? nodes : outputNodes(nodes, attribute);
    }, mode === 'elements');
  }
  function xpath(content, rule, mode) {
    rule = rule.replace(/^@xpath:/i, '');
    return combine(rule, branch => {
      let attribute = null;
      const suffix = branch.match(/@(html|all|text|ownText|textNodes)$/); if (suffix) { attribute = suffix[1]; branch = branch.slice(0, suffix.index); }
      const results = [];
      for (const raw of list(content)) {
        const original = parseHTML(raw);
        // A selected row is its own XPath document, matching Jsoup fragment parsing.
        const doc = original.nodeType === 9 ? original : new DOMParser().parseFromString(string(original), 'text/html');
        let context = doc;
        if (original.nodeType !== 9 && /^\s*<\/?(?:tr|td|th|tbody)\b/i.test(string(original))) {
          const template = doc.createElement('template'); template.innerHTML = string(original);
          doc.body.replaceChildren(template.content); context = doc;
        }
        let found;
        try { found = doc.evaluate(branch, context, null, XPathResult.ANY_TYPE, null); } catch (_) { fail('XPath 表达式无效或包含不支持的扩展函数'); }
        if (found.resultType === XPathResult.STRING_TYPE) results.push(found.stringValue);
        else if (found.resultType === XPathResult.NUMBER_TYPE) results.push(found.numberValue);
        else if (found.resultType === XPathResult.BOOLEAN_TYPE) results.push(found.booleanValue);
        else { let node; while ((node = found.iterateNext())) { results.push(node.nodeType === 2 || node.nodeType === 3 ? node.nodeValue : node); bounded(results); } }
      }
      if (attribute) return outputNodes(results.filter(isNode), attribute);
      return mode === 'elements' ? results : results.map(string).filter(v => v !== '');
    }, mode === 'elements');
  }
  function jsonValue(content) {
    content = unwrap(content);
    if (typeof content !== 'string') return content;
    try { return JSON.parse(content); } catch (_) { fail('JSONPath 的输入不是有效 JSON'); }
  }
  function isJSONInput(content) {
    content = unwrap(content);
    if (typeof content === 'object') return !isNode(content) && !list(content).some(isNode);
    if (typeof content !== 'string' || !/^\s*[\[{]/.test(content)) return false;
    try { const value = JSON.parse(content); return value !== null && typeof value === 'object'; } catch (_) { return false; }
  }
  function jsonChildren(value) { return value != null && typeof value === 'object' ? Object.values(value) : []; }
  function descendants(value) {
    const result = [], queue = [value];
    while (queue.length) { const next = queue.pop(); result.push(next); bounded(result); queue.push(...jsonChildren(next).reverse()); }
    return result;
  }
  function jsonPath(content, path, depth = 0) {
    if (depth > MAX_DEPTH) fail('JSONPath 嵌套过深');
    const root = jsonValue(content); let values = [root], offset = 0;
    path = path.trim(); if (path[0] === '$' || path[0] === '@') offset++;
    while (offset < path.length) {
      let recursive = false;
      if (path.startsWith('..', offset)) { recursive = true; offset += 2; }
      else if (path[offset] === '.') offset++;
      if (recursive) values = values.flatMap(descendants);
      if (path[offset] === '[') {
        const end = balancedEnd(path, offset), token = path.slice(offset + 1, end).trim(); offset = end + 1;
        if (token === '*') values = values.flatMap(jsonChildren);
        else if (token.startsWith('?(') && token.endsWith(')')) values = values.flatMap(jsonChildren).filter(value => truth(evaluateExpression(token.slice(2, -1), value, root, depth + 1)));
        else if (token.startsWith('(') && token.endsWith(')')) values = values.flatMap(value => { const index = evaluateExpression(token.slice(1, -1), value, root, depth + 1); return own(value, index) ? [value[index]] : []; });
        else {
          const union = split(token, ',');
          values = values.flatMap(value => union.flatMap(part => {
            part = part.trim();
            if (/^-?\d*\s*:\s*-?\d*(?:\s*:\s*-?\d*)?$/.test(part)) {
              if (!Array.isArray(value)) return [];
              const p = part.split(':').map(s => s.trim() === '' ? null : Number(s)), step = p[2] ?? 1;
              if (!step || !Number.isSafeInteger(step)) fail('JSONPath 切片步长无效');
              const size = value.length;
              let start = p[0] ?? (step > 0 ? 0 : size - 1), end = p[1] ?? (step > 0 ? size : -1);
              if (start < 0) start += size; if (p[1] != null && end < 0) end += size;
              start = Math.max(step > 0 ? 0 : -1, Math.min(size - (step < 0 ? 1 : 0), start));
              end = Math.max(-1, Math.min(size, end)); const output = [];
              for (let i = start; step > 0 ? i < end : i > end; i += step) if (i >= 0 && i < size) output.push(value[i]);
              return output;
            }
            let key = unquote(part); if (/^-?\d+$/.test(key) && Array.isArray(value)) { key = Number(key); if (key < 0) key += value.length; }
            return own(value, key) ? [value[key]] : [];
          }));
        }
      } else {
        const name = path.slice(offset).match(/^(\*|[^.\[\]()]+)/); if (!name) fail('JSONPath 路径格式无效');
        offset += name[0].length; const key = name[1].trim();
        if (path.startsWith('()', offset)) {
          offset += 2;
          const data = values.length === 1 && Array.isArray(values[0]) ? values[0] : values;
          if (key === 'length' || key === 'size') values = [values.length === 1 && values[0] != null ? typeof values[0] === 'object' ? Object.keys(values[0]).length : String(values[0]).length : values.length];
          else if (key === 'keys') values = [Object.keys(values[0] || {})];
          else if (key === 'first') values = data.slice(0, 1);
          else if (key === 'last') values = data.slice(-1);
          else if (['min', 'max', 'sum', 'avg', 'stddev'].includes(key)) {
            const nums = data.map(Number).filter(Number.isFinite), sum = nums.reduce((a, b) => a + b, 0), avg = sum / nums.length;
            values = [key === 'min' ? Math.min(...nums) : key === 'max' ? Math.max(...nums) : key === 'sum' ? sum : key === 'avg' ? avg : Math.sqrt(nums.reduce((a, b) => a + (b - avg) ** 2, 0) / nums.length)];
          } else fail('JSONPath 函数尚未实现：' + key);
        } else values = values.flatMap(value => key === '*' ? jsonChildren(value) : own(value, key) ? [value[key]] : []);
      }
      bounded(values);
    }
    return values;
  }
  function truth(value) { return Array.isArray(value) ? value.length > 0 : !!value; }
  function evaluateExpression(expression, current, root, depth) {
    let offset = 0, token;
    const precedence = { '||': 1, '&&': 2, '==': 3, '===': 3, '!=': 3, '!==': 3, '=~': 3, '<': 4, '<=': 4, '>': 4, '>=': 4, in: 4, nin: 4, subsetof: 4, anyof: 4, noneof: 4, size: 4, empty: 4, '+': 5, '-': 5, '*': 6, '/': 6, '%': 6 };
    function next() {
      while (/\s/.test(expression[offset] || '') && offset < expression.length) offset++;
      if (offset >= expression.length) return token = { kind: 'end' };
      const c = expression[offset];
      if (c === '"' || c === "'") { const start = offset++; while (offset < expression.length) { if (expression[offset] === '\\') offset += 2; else if (expression[offset++] === c) break; } return token = { kind: 'value', value: unquote(expression.slice(start, offset)) }; }
      if (c === '@' || c === '$') {
        const start = offset++;
        while (offset < expression.length) { if (expression[offset] === '[') offset = balancedEnd(expression, offset) + 1; else if (/[\w.$@\u0080-\uffff]/.test(expression[offset])) offset++; else if (expression.startsWith('()', offset)) offset += 2; else break; }
        const path = expression.slice(start, offset), found = jsonPath(c === '@' ? current : root, path, depth + 1);
        return token = { kind: 'value', value: found.length === 1 ? found[0] : found.length ? found : undefined };
      }
      if (c === '[') { const end = balancedEnd(expression, offset); const raw = expression.slice(offset + 1, end); offset = end + 1; return token = { kind: 'value', value: split(raw, ',').filter(x => x.trim()).map(x => evaluateExpression(x, current, root, depth + 1)) }; }
      if (c === '/' && token?.kind === 'operator' && token.value === '=~') {
        let end = offset + 1, escaped = false, inClass = false;
        for (; end < expression.length; end++) { const ch = expression[end]; if (escaped) { escaped = false; continue; } if (ch === '\\') { escaped = true; continue; } if (ch === '[') inClass = true; if (ch === ']') inClass = false; if (ch === '/' && !inClass) break; }
        if (end === expression.length) fail('JSONPath 正则未闭合');
        const pattern = expression.slice(offset + 1, end); offset = end + 1; let flags = ''; while (/[imsu]/.test(expression[offset] || '') && offset < expression.length) flags += expression[offset++];
        return token = { kind: 'value', value: new RegExp(pattern, flags) };
      }
      const numeric = expression.slice(offset).match(/^\d+(?:\.\d+)?(?:e[+-]?\d+)?/i);
      if (numeric) { offset += numeric[0].length; return token = { kind: 'value', value: Number(numeric[0]) }; }
      const word = expression.slice(offset).match(/^[A-Za-z_]\w*/);
      if (word) { offset += word[0].length; const key = word[0]; if (key === 'true' || key === 'false' || key === 'null') return token = { kind: 'value', value: key === 'null' ? null : key === 'true' }; if (key === 'length') return token = { kind: 'value', value: current?.length }; if (!(key in precedence)) fail('JSONPath 过滤器标识符无效'); return token = { kind: 'operator', value: key }; }
      const op = expression.slice(offset).match(/^(===|!==|==|!=|<=|>=|=~|&&|\|\||[()!+*/%<>-])/);
      if (!op) fail('JSONPath 过滤器格式无效'); offset += op[0].length; return token = { kind: 'operator', value: op[0] };
    }
    function unary() {
      if (token.kind === 'value') { const value = token.value; next(); return value; }
      if (token.value === '(') { next(); const result = binary(0); if (token.value !== ')') fail('JSONPath 过滤器括号不匹配'); next(); return result; }
      if (['!', '-', '+'].includes(token.value)) { const op = token.value; next(); const value = unary(); return op === '!' ? !truth(value) : op === '-' ? -Number(value) : Number(value); }
      fail('JSONPath 过滤器缺少值');
    }
    function binary(minimum) {
      let left = unary();
      while (token.kind === 'operator' && (precedence[token.value] || 0) > minimum) {
        const op = token.value, rank = precedence[op]; next(); const right = binary(rank);
        if (op === '&&') left = truth(left) && truth(right); else if (op === '||') left = truth(left) || truth(right);
        else if (op === '==' || op === '===') left = JSON.stringify(left) === JSON.stringify(right);
        else if (op === '!=' || op === '!==') left = JSON.stringify(left) !== JSON.stringify(right);
        else if (op === '=~') left = right instanceof RegExp && right.test(string(left));
        else if (op === '<') left = left < right; else if (op === '<=') left = left <= right; else if (op === '>') left = left > right; else if (op === '>=') left = left >= right;
        else if (op === '+') left = left + right; else if (op === '-') left = left - right; else if (op === '*') left = left * right; else if (op === '/') left = left / right; else if (op === '%') left = left % right;
        else if (op === 'in' || op === 'nin') left = Array.isArray(right) && right.includes(left) === (op === 'in');
        else if (op === 'size') left = left != null && (left.length ?? Object.keys(left).length) === right;
        else if (op === 'empty') left = (left == null || (left.length ?? Object.keys(left).length) === 0) === right;
        else if (op === 'subsetof') left = Array.isArray(left) && Array.isArray(right) && left.every(x => right.includes(x));
        else if (op === 'anyof' || op === 'noneof') left = Array.isArray(left) && Array.isArray(right) && left.some(x => right.includes(x)) === (op === 'anyof');
      }
      return left;
    }
    next(); const result = binary(0); if (token.kind !== 'end') fail('JSONPath 过滤器包含多余内容'); return result;
  }
  function json(content, rule, mode, depth) {
    rule = rule.replace(/^@json:/i, '');
    return combine(rule, branch => {
      if (branch.includes('{$')) {
        const replaced = branch.replace(/\{(\$[^}]+)\}/g, (_, path) => jsonPath(content, path, depth).map(string).join('\n'));
        return replaced ? [replaced] : [];
      }
      let values = jsonPath(content, branch, depth);
      if (values.length === 1 && Array.isArray(values[0])) values = values[0];
      return mode === 'elements' ? values.filter(v => v != null) : values.filter(v => v != null).map(string).filter(v => v !== '');
    }, mode === 'elements');
  }
  function stages(rule) {
    const result = [], re = /<js>([\s\S]*?)<\/js>|@js:([\s\S]*)$/gi; let end = 0, match;
    while ((match = re.exec(rule))) {
      if (match.index > end && rule.slice(end, match.index).trim()) result.push({ code: rule.slice(end, match.index).trim(), js: false });
      result.push({ code: match[1] ?? match[2], js: true }); end = re.lastIndex;
    }
    if (end < rule.length && rule.slice(end).trim()) result.push({ code: rule.slice(end).trim(), js: false });
    return result;
  }
  function scriptReplacement(code) {
    let quote = '', escaped = false, comment = '', regularExpression = false, characterClass = false, depth = 0;
    for (let i = 0; i < code.length; i++) {
      const c = code[i], next = code[i + 1];
      if (comment === '//') { if (c === '\n') comment = ''; continue; }
      if (comment === '/*') { if (c === '*' && next === '/') { comment = ''; i++; } continue; }
      if (escaped) { escaped = false; continue; }
      if (c === '\\' && (quote || regularExpression)) { escaped = true; continue; }
      if (quote) { if (c === quote) quote = ''; continue; }
      if (regularExpression) {
        if (c === '[') characterClass = true;
        else if (c === ']') characterClass = false;
        else if (c === '/' && !characterClass) regularExpression = false;
        continue;
      }
      if (c === '/' && (next === '/' || next === '*')) { comment = '/' + next; i++; continue; }
      if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
      if (c === '/') {
        const before = code.slice(0, i).trimEnd();
        if (!before || /[=(:,;!&|?{}\[]$/.test(before) || /\b(return|throw|yield|case)$/.test(before)) { regularExpression = true; continue; }
      }
      if ('({['.includes(c)) depth++;
      else if (')}]'.includes(c)) depth--;
      if (!depth && c === '#' && next === '#') return { script: code.slice(0, i), parts: code.slice(i + 2).split('##') };
    }
    return { script: code, parts: null };
  }
  function putRules(code, original, env, depth) {
    const re = /@put:\s*\{/ig; let match;
    while ((match = re.exec(code))) {
      const start = code.indexOf('{', match.index), end = balancedEnd(code, start), body = code.slice(start + 1, end);
      for (const pair of split(body, ',')) {
        const colon = positions(pair, [':'])[0]; if (!colon) continue;
        const key = unquote(pair.slice(0, colon.index)), valueRule = unquote(pair.slice(colon.index + 1));
        if (key) env.putVar?.(key, extract(original, valueRule, env, 'string', depth + 1));
      }
      code = code.slice(0, match.index) + code.slice(end + 1); re.lastIndex = match.index;
    }
    return code;
  }
  function templates(code, original, result, env, depth) {
    let changed = false;
    code = code.replace(/@get:\{([^}]+)\}/gi, (_, key) => { changed = true; return string(env.getVar?.(key) ?? ''); });
    let cursor = 0;
    while ((cursor = code.indexOf('{{', cursor)) >= 0) {
      const end = balancedEnd(code, cursor); if (code[end - 1] !== '}') fail('模板结束符无效');
      const expression = code.slice(cursor + 2, end - 1).trim();
      const value = /^(@|\$\.|\$\[|\/\/)/.test(expression) ? extract(original, expression, env, 'string', depth + 1) : env.evalJS ? env.evalJS(expression, result) : fail('此规则需要脚本运行环境');
      const text = string(value); code = code.slice(0, cursor) + text + code.slice(end + 1); cursor += text.length; changed = true;
    }
    return { code, changed };
  }
  function regexElements(content, pattern) {
    const parts = split(pattern, '&&'); let text = string(content), output = [];
    for (let i = 0; i < parts.length; i++) {
      const re = regex(parts[i], true); output = []; let match;
      while ((match = re.exec(text))) { const row = Array.from(match, x => x || ''); Object.defineProperty(row, '__legadoCapture', { value: true }); output.push(row); bounded(output); if (!match[0]) re.lastIndex++; }
      if (i < parts.length - 1) text = output.map(row => row[0]).join('');
    }
    return output;
  }
  function extract(content, rule, env = {}, mode = 'string', depth = 0) {
    if (depth > MAX_DEPTH) fail('规则嵌套过深');
    if (!['string', 'strings', 'elements'].includes(mode)) fail('未知输出类型');
    if (rule == null || String(rule).trim() === '') return mode === 'string' ? '' : [];
    const original = content; let result = content;
    for (const stage of stages(String(rule))) {
      let code = putRules(stage.code, original, env, depth);
      const rawSelection = code.split('##')[0], literal = /@get:\{|\{\{/.test(rawSelection) || (Array.isArray(unwrap(result)) && /\$\d{1,2}/.test(rawSelection));
      code = templates(code, original, result, env, depth).code;
      if (stage.js) {
        const parsed = scriptReplacement(code);
        if (parsed.script.trim() || !parsed.parts) {
          if (!env.evalJS) fail('此规则需要脚本运行环境');
          result = env.evalJS(parsed.script, result);
        }
        if (parsed.parts) result = mode === 'string' ? replace(result, parsed.parts[0], parsed.parts[1] || '', parsed.parts.length > 2) : list(result).map(value => replace(value, parsed.parts[0], parsed.parts[1] || '', parsed.parts.length > 2));
        continue;
      }
      const parts = code.split('##'); let selection = parts[0].trim();
      if (literal) {
        if (Array.isArray(unwrap(result))) selection = selection.replace(/\$(\d{1,2})/g, (all, n) => string(unwrap(result)[Number(n)] ?? all));
        result = selection;
      } else if (selection) {
        if (mode === 'elements' && selection[0] === ':') result = regexElements(result, selection.slice(1));
        else if (/^@xpath:/i.test(selection)) result = xpath(result, selection, mode);
        else if (/^@json:/i.test(selection) || /^\$(\.|\[)/.test(selection) || (!/^@@|^@css:/i.test(selection) && isJSONInput(result))) result = json(result, selection, mode, depth);
        else if (selection.startsWith('/')) result = xpath(result, selection, mode);
        else result = css(result, selection, mode);
      }
      if (parts.length > 1) result = mode === 'string' ? replace(result, parts[1], parts[2] || '', parts.length > 3) : list(result).map(value => replace(value, parts[1], parts[2] || '', parts.length > 3));
      if (mode === 'string') result = string(result);
    }
    return mode === 'string' ? string(result) : bounded(list(result).filter(v => v != null));
  }
  function javaList(items) {
    const values = Array.from(items);
    Object.defineProperties(values, {
      size: { value: () => values.length }, get: { value: i => values[i] },
      isEmpty: { value: () => !values.length }, contains: { value: v => values.includes(v) },
      add: { value: v => { values.push(v); return true; } },
      clear: { value: () => values.splice(0), configurable: true }, toArray: { value: () => values.slice() },
      subList: { value: (start, end) => { const view = javaList(values.slice(start, end)); Object.defineProperty(view, 'clear', { value: () => { values.splice(start, end - start); view.splice(0); }, configurable: true }); return view; } }
    });
    return values;
  }
  const nodeWrappers = new WeakMap();
  class JSoupNode {
    constructor(node) { if (nodeWrappers.has(node)) return nodeWrappers.get(node); this.__legadoNode = node; nodeWrappers.set(node, this); }
    select(selector) { return new JSoupElements(cssSelect(this.__legadoNode, String(selector))); }
    selectFirst(selector) { return this.select(selector).first(); }
    getElementsByTag(tag) { return new JSoupElements(cssSelect(this.__legadoNode, String(tag))); }
    getElementsByClass(name) { return new JSoupElements(selectStep(this.__legadoNode, 'class.' + name)); }
    getElementById(id) { return new JSoupElements(selectStep(this.__legadoNode, 'id.' + id)).first(); }
    getAllElements() { return new JSoupElements(cssSelect(this.__legadoNode, '*')); }
    children() { return new JSoupElements(Array.from(this.__legadoNode.children || [])); }
    child(index) { return this.children().get(index); }
    childNodeSize() { return this.__legadoNode.childNodes.length; }
    childNode(index) { const node = this.__legadoNode.childNodes[index]; return node ? new JSoupNode(node) : null; }
    childNodes() { return new JSoupElements(Array.from(this.__legadoNode.childNodes)); }
    parent() { return this.__legadoNode.parentElement ? new JSoupNode(this.__legadoNode.parentElement) : null; }
    parents() { const nodes = []; for (let n = this.__legadoNode.parentElement; n; n = n.parentElement) nodes.push(n); return new JSoupElements(nodes); }
    nextElementSibling() { return this.__legadoNode.nextElementSibling ? new JSoupNode(this.__legadoNode.nextElementSibling) : null; }
    previousElementSibling() { return this.__legadoNode.previousElementSibling ? new JSoupNode(this.__legadoNode.previousElementSibling) : null; }
    siblingElements() { return new JSoupElements(Array.from(this.__legadoNode.parentElement?.children || []).filter(n => n !== this.__legadoNode)); }
    elementSiblingIndex() { return Array.from(this.__legadoNode.parentNode?.children || []).indexOf(this.__legadoNode); }
    text(value) { if (arguments.length) { this.__legadoNode.textContent = String(value); return this; } return this.__legadoNode.nodeType === 3 ? this.__legadoNode.nodeValue : nodeText(this.__legadoNode, false); }
    ownText() { return nodeText(this.__legadoNode, true); }
    wholeText() { return this.__legadoNode.textContent || ''; }
    getWholeText() { return this.wholeText(); }
    textNodes() { return new JSoupElements(Array.from(this.__legadoNode.childNodes).filter(n => n.nodeType === 3)); }
    html(value) { if (arguments.length) { this.__legadoNode.innerHTML = String(value); return this; } return this.__legadoNode.innerHTML || ''; }
    outerHtml() { return string(this.__legadoNode); }
    data() { return this.__legadoNode.textContent || ''; }
    attr(name, value) { if (arguments.length > 1) { this.__legadoNode.setAttribute(name, String(value)); return this; } return outputNodes([this.__legadoNode], String(name))[0] || ''; }
    hasAttr(name) { return this.__legadoNode.hasAttribute?.(name) || false; }
    removeAttr(name) { this.__legadoNode.removeAttribute?.(name); return this; }
    tagName(value) { if (arguments.length) fail('暂不支持修改元素标签名称'); return (this.__legadoNode.tagName || this.__legadoNode.nodeName).toLowerCase(); }
    nodeName() { return this.tagName(); }
    id() { return this.attr('id'); }
    className() { return this.attr('class'); }
    hasClass(name) { return this.__legadoNode.classList?.contains(name) || false; }
    addClass(name) { this.__legadoNode.classList?.add(name); return this; }
    removeClass(name) { this.__legadoNode.classList?.remove(name); return this; }
    val(value) { return arguments.length ? this.attr('value', value) : this.attr('value'); }
    is(selector) { return matchesSelector(this.__legadoNode, selector); }
    remove() { this.__legadoNode.remove(); return this; }
    empty() { this.__legadoNode.replaceChildren(); return this; }
    append(html) { this.__legadoNode.insertAdjacentHTML('beforeend', String(html)); return this; }
    prepend(html) { this.__legadoNode.insertAdjacentHTML('afterbegin', String(html)); return this; }
    before(html) { this.__legadoNode.insertAdjacentHTML('beforebegin', String(html)); return this; }
    after(html) { this.__legadoNode.insertAdjacentHTML('afterend', String(html)); return this; }
    unwrap() { const node = this.__legadoNode; node.replaceWith(...Array.from(node.childNodes)); return this; }
    clone() { return new JSoupNode(this.__legadoNode.cloneNode(true)); }
    body() { const n = this.__legadoNode.body || this.__legadoNode.querySelector('body'); return n ? new JSoupNode(n) : null; }
    head() { const n = this.__legadoNode.head || this.__legadoNode.querySelector('head'); return n ? new JSoupNode(n) : null; }
    title() { return this.__legadoNode.title || this.select('title').text(); }
    toString() { return this.outerHtml(); }
  }
  class JSoupElements {
    constructor(nodes) { this.__legadoNodes = nodes.map(unwrap); for (let i = 0; i < nodes.length; i++) this[i] = new JSoupNode(this.__legadoNodes[i]); this.length = nodes.length; }
    size() { return this.__legadoNodes.length; }
    isEmpty() { return !this.size(); }
    get(index) { const n = this.__legadoNodes[Number(index)]; if (!n) throw new RangeError('元素索引越界'); return new JSoupNode(n); }
    first() { return this.size() ? this.get(0) : null; }
    last() { return this.size() ? this.get(this.size() - 1) : null; }
    eq(index) { if (index < 0) index += this.size(); return new JSoupElements(this.__legadoNodes.slice(index, index + 1)); }
    select(selector) { return new JSoupElements(unique(this.__legadoNodes.flatMap(n => cssSelect(n, selector)))); }
    not(selector) { return new JSoupElements(this.__legadoNodes.filter(n => !matchesSelector(n, selector))); }
    children() { return new JSoupElements(unique(this.__legadoNodes.flatMap(n => Array.from(n.children || [])))); }
    parents() { return new JSoupElements(unique(this.__legadoNodes.flatMap(n => new JSoupNode(n).parents().__legadoNodes))); }
    attr(name, value) { if (arguments.length > 1) { this.__legadoNodes.forEach(n => new JSoupNode(n).attr(name, value)); return this; } return outputNodes(this.__legadoNodes, String(name))[0] || ''; }
    eachAttr(name) { return javaList(outputNodes(this.__legadoNodes, String(name))); }
    eachText() { return javaList(this.__legadoNodes.map(n => nodeText(n, false))); }
    text(value) { if (arguments.length) { this.__legadoNodes.forEach(n => n.textContent = String(value)); return this; } return this.eachText().filter(Boolean).join(' '); }
    html(value) { if (arguments.length) { this.__legadoNodes.forEach(n => n.innerHTML = String(value)); return this; } return this.__legadoNodes.map(n => n.innerHTML || '').join('\n'); }
    outerHtml() { return this.__legadoNodes.map(string).join('\n'); }
    syncIndexes() { for (let i = 0; i < this.length; i++) delete this[i]; this.length = this.__legadoNodes.length; for (let i = 0; i < this.length; i++) this[i] = new JSoupNode(this.__legadoNodes[i]); }
    remove(index) {
      if (!arguments.length) { this.__legadoNodes.forEach(n => n.remove()); return this; }
      const position = typeof index === 'number' ? index : this.__legadoNodes.indexOf(unwrap(index));
      if (position < 0 || position >= this.size()) return null;
      const removed = this.__legadoNodes.splice(position, 1)[0]; this.syncIndexes(); return new JSoupNode(removed);
    }
    contains(node) { return this.__legadoNodes.includes(unwrap(node)); }
    clear() { this.__legadoNodes.splice(0); this.syncIndexes(); }
    subList(start, end) { const parent = this, view = new JSoupElements(this.__legadoNodes.slice(start, end)); view.clear = () => { parent.__legadoNodes.splice(start, end - start); parent.syncIndexes(); view.__legadoNodes.splice(0); view.syncIndexes(); }; return view; }
    removeAttr(name) { this.__legadoNodes.forEach(n => n.removeAttribute?.(name)); return this; }
    empty() { this.__legadoNodes.forEach(n => n.replaceChildren()); return this; }
    add(node) { this.__legadoNodes.push(unwrap(node)); this[this.length++] = node instanceof JSoupNode ? node : new JSoupNode(unwrap(node)); return true; }
    toArray() { return javaList(this.__legadoNodes.map(n => new JSoupNode(n))); }
    forEach(callback) { this.toArray().forEach(callback); }
    iterator() { let i = 0; return { hasNext: () => i < this.size(), next: () => this.get(i++) }; }
    [Symbol.iterator]() { return this.toArray()[Symbol.iterator](); }
    toString() { return this.outerHtml(); }
  }
  function jsoup(html, baseURL) {
    const root = parseHTML(html);
    if (baseURL && root.nodeType === 9) { const base = root.createElement('base'); base.href = baseURL; root.head?.prepend(base); }
    return new JSoupNode(root);
  }
  global.LegadoRules = Object.freeze({ extract, htmlText, jsoup, cssSelect, jsonPath, regex, replace, string, unwrap, wrap: value => isNode(value) ? new JSoupNode(value) : Array.isArray(value) && value.every(isNode) ? new JSoupElements(value) : value });
})(globalThis);
