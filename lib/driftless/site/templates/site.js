// driftless site — renders the embedded build data. No dependencies, no
// build step. The data element is JSON (see Site.embed_json); everything on
// the page is derived from it at load time.
//
// Layout: a pure model (filters, grouping, hierarchy and utilization rows,
// URL-hash state) that never touches the DOM, then the DOM rendering. The
// model is exported on globalThis.driftlessSite so it can be exercised
// outside a browser.
(function (global) {
  'use strict';

  const SEVERITIES = ['error', 'warning', 'note'];
  const QUALITIES = ['stale', 'wrong', 'weird', 'impossible'];
  const VIEWS = ['findings', 'hierarchy', 'utilization'];
  const CATEGORIES = ['modules', 'roles', 'profiles', 'classes'];

  // ---- model: state in the URL hash --------------------------------------

  const DEFAULTS = {
    view: 'findings',
    sev: [], qual: [], key: '', path: '', group: 'key',
    cat: 'modules', by: '', sort: 'name', dir: 'asc', match: '', count: '',
  };
  const LIST_KEYS = ['sev', 'qual'];

  function defaultState() {
    return JSON.parse(JSON.stringify(DEFAULTS));
  }

  // "#view=findings&sev=error,warning&path=data/" → state; unknown keys are
  // ignored and missing keys take their defaults, so any old link still opens.
  function parseHash(hash) {
    const state = defaultState();
    const params = new URLSearchParams((hash || '').replace(/^#/, ''));
    Object.keys(DEFAULTS).forEach(function (k) {
      if (!params.has(k)) { return; }
      const v = params.get(k);
      state[k] = LIST_KEYS.indexOf(k) >= 0 ? v.split(',').filter(Boolean) : v;
    });
    if (VIEWS.indexOf(state.view) < 0) { state.view = DEFAULTS.view; }
    if (CATEGORIES.indexOf(state.cat) < 0) { state.cat = DEFAULTS.cat; }
    return state;
  }

  // Only what differs from the defaults, so a pristine page has an empty hash.
  function serializeHash(state) {
    const params = new URLSearchParams();
    Object.keys(DEFAULTS).forEach(function (k) {
      const v = state[k];
      const d = DEFAULTS[k];
      const same = LIST_KEYS.indexOf(k) >= 0 ? v.join(',') === d.join(',') : v === d;
      if (same) { return; }
      params.set(k, LIST_KEYS.indexOf(k) >= 0 ? v.join(',') : v);
    });
    const s = params.toString();
    return s ? '#' + s : '';
  }

  // ---- model: findings ---------------------------------------------------

  function location(f) {
    if (!f.path) { return '-'; }
    return f.line ? f.path + ':' + f.line : f.path;
  }

  function filterFindings(findings, state) {
    const key = state.key.toLowerCase();
    const path = state.path.toLowerCase();
    return findings.filter(function (f) {
      if (state.sev.length && state.sev.indexOf(f.severity) < 0) { return false; }
      if (state.qual.length && state.qual.indexOf(f.quality || '') < 0) { return false; }
      if (key && f.key.toLowerCase().indexOf(key) < 0) { return false; }
      if (path && (f.path || '').toLowerCase().indexOf(path) < 0) { return false; }
      return true;
    });
  }

  function groupBy(items, keyFn) {
    const groups = {};
    items.forEach(function (item) {
      const k = keyFn(item);
      (groups[k] = groups[k] || []).push(item);
    });
    return Object.keys(groups).sort().map(function (k) { return { key: k, items: groups[k] }; });
  }

  // Per-key counts with the severity/quality the key carries, plus totals.
  function summarize(findings) {
    const rows = groupBy(findings, function (f) { return f.key; }).map(function (g) {
      return { key: g.key, count: g.items.length, severity: g.items[0].severity, quality: g.items[0].quality };
    });
    const bySeverity = {};
    SEVERITIES.forEach(function (s) {
      bySeverity[s] = findings.filter(function (f) { return f.severity === s; }).length;
    });
    return { rows: rows, total: findings.length, bySeverity: bySeverity };
  }

  function byLocation(a, b) {
    const pa = a.path || '';
    const pb = b.path || '';
    if (pa !== pb) { return pa < pb ? -1 : 1; }
    return (a.line || 0) - (b.line || 0);
  }

  function groupFindings(findings, group) {
    const keyFn = group === 'path' ? function (f) { return f.path || '-'; } : function (f) { return f.key; };
    return groupBy(findings, keyFn).map(function (g) {
      const items = g.items.slice().sort(group === 'path'
        ? function (a, b) { return a.key < b.key ? -1 : a.key > b.key ? 1 : (a.line || 0) - (b.line || 0); }
        : byLocation);
      return { key: g.key, items: items };
    });
  }

  // ---- model: hierarchy --------------------------------------------------

  // Findings that annotate a variable of a tier, by key: which meta field
  // names the variable and what to call the condition.
  const VAR_FLAGS = {
    'hierarchy:tiers-interpolating-unreported-facts': { field: 'unreported_facts', flag: 'unreported' },
    'hierarchy:tiers-interpolating-bare-variables': { field: 'interpolation', flag: 'bare' },
    'hierarchy:tiers-interpolating-legacy-facts': { field: 'interpolation', flag: 'legacy' },
  };

  // One row per declared tier (repo.hierarchy), each variable carrying the
  // flags findings attach to it, plus a note per other finding key that names
  // the tier (files missed, paths for unreported nodes, …). A tier that only a
  // finding mentions — none declared, e.g. an older document — still appears.
  function hierarchyRows(hierarchy, findings) {
    const rows = (hierarchy || []).map(function (t) {
      return {
        name: t.name, backend: t.backend, line: t.line, paths: t.paths || [],
        vars: (t.vars || []).map(function (v) { return { name: v, flags: [] }; }),
        notes: {}, declared: true,
      };
    });
    const byName = {};
    rows.forEach(function (r) { byName[r.name] = r; });

    findings.forEach(function (f) {
      const tier = f.meta && f.meta.tier;
      if (!tier) { return; }
      let row = byName[tier];
      if (!row) {
        row = { name: tier, backend: '', line: null, paths: [], vars: [], notes: {}, declared: false };
        byName[tier] = row;
        rows.push(row);
      }
      const spec = VAR_FLAGS[f.key];
      if (spec) {
        const names = [].concat(f.meta[spec.field] || []);
        names.forEach(function (name) {
          let v = row.vars.filter(function (x) { return x.name === name; })[0];
          if (!v) { v = { name: name, flags: [] }; row.vars.push(v); }
          const flag = spec.flag === 'legacy' && f.meta.modern ? 'legacy → ' + f.meta.modern : spec.flag;
          if (v.flags.indexOf(flag) < 0) { v.flags.push(flag); }
        });
      } else {
        row.notes[f.key] = (row.notes[f.key] || 0) + 1;
      }
    });
    return rows;
  }

  // ---- model: utilization ------------------------------------------------

  // "0", ">1", ">1 <10", ">=3" — terms AND together; null for no filter,
  // undefined for an unparseable expression.
  function parseCountExpr(expr) {
    const text = (expr || '').trim();
    if (!text) { return null; }
    const tests = [];
    const terms = text.split(/\s+/);
    for (let i = 0; i < terms.length; i++) {
      const m = /^(>=|<=|>|<|=)?(\d+)$/.exec(terms[i]);
      if (!m) { return undefined; }
      const op = m[1] || '=';
      const n = parseInt(m[2], 10);
      tests.push(function (x) {
        return op === '>' ? x > n : op === '<' ? x < n : op === '>=' ? x >= n : op === '<=' ? x <= n : x === n;
      });
    }
    return function (x) { return tests.every(function (t) { return t(x); }); };
  }

  function matcher(pattern) {
    if (!pattern) { return null; }
    try {
      const re = new RegExp(pattern, 'i');
      return function (s) { return re.test(s); };
    } catch {
      const needle = pattern.toLowerCase();
      return function (s) { return s.toLowerCase().indexOf(needle) >= 0; };
    }
  }

  // Rows of one utilization category under the state's group-by, filters,
  // and sort. `columns` is the breakdown (collectors or environments) seen
  // across the rows, so the table has one column per value.
  function utilizationRows(utilization, state) {
    const entries = (utilization && utilization[state.cat]) || [];
    const byKey = state.by ? 'by_' + state.by : null;
    const columns = [];
    if (byKey) {
      entries.forEach(function (e) {
        Object.keys(e[byKey] || {}).forEach(function (c) { if (columns.indexOf(c) < 0) { columns.push(c); } });
      });
      columns.sort();
    }
    const match = matcher(state.match);
    const count = parseCountExpr(state.count);
    const rows = entries.filter(function (e) {
      if (match && !match(e.name)) { return false; }
      if (count && !count(e.nodes || 0)) { return false; }
      return true;
    }).map(function (e) {
      return {
        name: e.name, nodes: e.nodes || 0,
        cells: columns.map(function (c) { return (e[byKey] || {})[c] || 0; }),
      };
    });
    rows.sort(function (a, b) {
      let r = state.sort === 'count' ? a.nodes - b.nodes : (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
      if (r === 0 && state.sort === 'count') { r = a.name < b.name ? -1 : a.name > b.name ? 1 : 0; }
      return state.dir === 'desc' ? -r : r;
    });
    return { columns: columns, rows: rows, total: entries.length, badCount: count === undefined };
  }

  const model = {
    SEVERITIES: SEVERITIES, QUALITIES: QUALITIES, VIEWS: VIEWS, CATEGORIES: CATEGORIES,
    defaultState: defaultState, parseHash: parseHash, serializeHash: serializeHash,
    location: location, filterFindings: filterFindings, summarize: summarize,
    groupFindings: groupFindings, hierarchyRows: hierarchyRows,
    parseCountExpr: parseCountExpr, utilizationRows: utilizationRows,
  };
  global.driftlessSite = model;

  if (typeof document === 'undefined') { return; }

  // ---- DOM helpers -------------------------------------------------------

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === 'class') { node.className = attrs[k]; } else if (k === 'on') {
          Object.keys(attrs.on).forEach(function (ev) { node.addEventListener(ev, attrs.on[ev]); });
        } else { node.setAttribute(k, attrs[k]); }
      });
    }
    (children || []).forEach(function (c) {
      if (c === null || c === undefined) { return; }
      node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return node;
  }

  function plural(n, noun) { return n + ' ' + noun + (n === 1 ? '' : 's'); }

  function severitySpan(s) { return el('span', { class: 'severity-' + s }, [s]); }
  function qualitySpan(q) { return el('span', { class: 'quality' }, [q || '']); }

  // ---- state -------------------------------------------------------------

  const data = JSON.parse(document.getElementById('driftless-data').textContent);
  const app = document.getElementById('app');
  const nav = document.getElementById('views');
  let state = parseHash(global.location.hash);

  // Re-renders the results; the controls only when the view changes or the
  // caller asks (opts.full). Rebuilding a control replaces the input being
  // typed into, so a filter change must not.
  function update(changes, opts) {
    const viewChanged = 'view' in changes && changes.view !== state.view;
    Object.keys(changes).forEach(function (k) { state[k] = changes[k]; });
    const hash = serializeHash(state);
    if (hash !== global.location.hash && !(hash === '' && global.location.hash === '')) {
      global.history.replaceState(null, '', hash || global.location.pathname + global.location.search);
    }
    if (viewChanged || (opts && opts.full)) { render(); } else { renderResults(); }
  }

  // ---- controls ----------------------------------------------------------

  function checkboxGroup(label, values, selected, key, styleFn) {
    return el('span', { class: 'group' }, [el('span', null, [label])].concat(values.map(function (v) {
      const input = el('input', { type: 'checkbox', value: v });
      input.checked = selected.indexOf(v) >= 0;
      input.addEventListener('change', function () {
        const next = values.filter(function (x) { return x === v ? input.checked : state[key].indexOf(x) >= 0; });
        const change = {};
        change[key] = next;
        update(change);
      });
      return el('label', null, [input, styleFn ? styleFn(v) : v]);
    })));
  }

  function textInput(label, key, placeholder) {
    const input = el('input', { type: 'text', value: state[key], placeholder: placeholder || '' });
    let timer = null;
    input.addEventListener('input', function () {
      clearTimeout(timer);
      timer = setTimeout(function () { const c = {}; c[key] = input.value; update(c); }, 150);
    });
    return el('label', null, [label, input]);
  }

  function select(label, key, options) {
    const sel = el('select', null, options.map(function (o) {
      const opt = el('option', { value: o[0] }, [o[1]]);
      if (o[0] === state[key]) { opt.setAttribute('selected', 'selected'); }
      return opt;
    }));
    sel.addEventListener('change', function () { const c = {}; c[key] = sel.value; update(c); });
    return el('label', null, [label, sel]);
  }

  function resetButton(keys) {
    return el('button', { type: 'button', on: { click: function () {
      const c = {};
      keys.forEach(function (k) { c[k] = defaultState()[k]; });
      update(c, { full: true });
    } } }, ['reset']);
  }

  // ---- findings view -----------------------------------------------------

  function warningsSection(warnings) {
    if (!warnings.length) { return null; }
    return el('section', { class: 'warnings' }, [
      el('strong', null, [plural(warnings.length, 'warning') + ' raised during the run']),
      el('ul', null, warnings.map(function (w) { return el('li', null, [w]); })),
    ]);
  }

  function findingsControls(shownEl) {
    return el('div', { class: 'controls' }, [
      checkboxGroup('severity', SEVERITIES, state.sev, 'sev', severitySpan),
      checkboxGroup('quality', QUALITIES, state.qual, 'qual', qualitySpan),
      textInput('key', 'key', 'substring'),
      textInput('path', 'path', 'substring'),
      select('group by', 'group', [['key', 'detector'], ['path', 'path']]),
      resetButton(['sev', 'qual', 'key', 'path', 'group']),
      shownEl,
    ]);
  }

  // Count table: count first, then severity and quality, then the key; total
  // last with a per-severity breakdown — the terminal count table's layout.
  function summarySection(findings) {
    const section = el('section', { id: 'summary' }, [el('h2', null, ['Summary'])]);
    const s = summarize(findings);
    if (!s.total) {
      section.appendChild(el('p', { class: 'empty' }, ['no findings']));
      return section;
    }
    const rows = s.rows.map(function (r) {
      return el('tr', null, [
        el('td', { class: 'count' }, [String(r.count)]),
        el('td', null, [severitySpan(r.severity)]),
        el('td', null, [qualitySpan(r.quality)]),
        el('td', { class: 'key' }, [el('a', { href: '#', on: { click: function (e) {
          e.preventDefault();
          update({ key: r.key, group: 'key' });
        } } }, [r.key])]),
      ]);
    });
    const totalCell = el('td', { colspan: '3' }, ['total: ']);
    SEVERITIES.forEach(function (sev, i) {
      if (i > 0) { totalCell.appendChild(document.createTextNode(', ')); }
      totalCell.appendChild(el('span', { class: 'severity-' + sev }, [s.bySeverity[sev] + ' ' + sev]));
    });
    rows.push(el('tr', { class: 'total' }, [el('td', { class: 'count' }, [String(s.total)]), totalCell]));

    section.appendChild(el('table', null, [
      el('thead', null, [el('tr', null, [el('th', { class: 'count' }, ['#']), el('th', null, ['severity']),
        el('th', null, ['quality']), el('th', null, ['key'])])]),
      el('tbody', null, rows),
    ]));
    return section;
  }

  function findingsSection(findings) {
    const section = el('section', { id: 'findings' }, [el('h2', null, ['Findings'])]);
    if (!findings.length) {
      section.appendChild(el('p', { class: 'empty' }, ['no findings']));
      return section;
    }
    const byPath = state.group === 'path';
    groupFindings(findings, state.group).forEach(function (g) {
      const first = g.items[0];
      const heading = byPath
        ? el('h3', null, [el('span', { class: 'location' }, [g.key]), ' ',
          el('span', { class: 'count' }, ['(' + plural(g.items.length, 'finding') + ')'])])
        : el('h3', null, [severitySpan(first.severity), ' ', qualitySpan(first.quality), ' ',
          el('span', { class: 'key' }, [g.key]), ' ',
          el('span', { class: 'count' }, ['(' + plural(g.items.length, 'finding') + ')'])]);
      const rows = g.items.map(function (f) {
        const lead = byPath
          ? el('td', { class: 'key' }, [severitySpan(f.severity), ' ', f.key, f.line ? ':' + f.line : ''])
          : el('td', { class: 'location' }, [location(f)]);
        return el('tr', null, [lead, el('td', null, [f.message])]);
      });
      section.appendChild(el('div', { class: 'group-block' }, [heading, el('table', null, [el('tbody', null, rows)])]));
    });
    return section;
  }

  // A view is its controls, built once, and a results function, re-run on
  // every state change.
  function findingsView() {
    const all = data.findings || [];
    const shownEl = el('span', { class: 'shown' });
    return {
      controls: [warningsSection(data.warnings || []), findingsControls(shownEl)],
      results: function () {
        const shown = filterFindings(all, state);
        shownEl.textContent = shown.length + ' of ' + plural(all.length, 'finding');
        return [summarySection(shown), findingsSection(shown)];
      },
    };
  }

  // ---- hierarchy view ----------------------------------------------------

  function hierarchyView() {
    return { controls: [], results: hierarchySections };
  }

  function hierarchySections() {
    const rows = hierarchyRows((data.repo || {}).hierarchy, data.findings || []);
    const section = el('section', { id: 'hierarchy' }, [el('h2', null, ['Hierarchy'])]);
    if (!rows.length) {
      section.appendChild(el('p', { class: 'empty' }, ['no tiers']));
      return [section];
    }
    const trs = rows.map(function (r) {
      const vars = r.vars.map(function (v) {
        return el('span', { class: 'var' }, [v.name].concat(v.flags.map(function (flag) {
          return el('span', { class: 'flag flag-' + flag.split(' ')[0] }, [flag]);
        })));
      });
      const notes = Object.keys(r.notes).sort().map(function (k) {
        return el('div', { class: 'tier-note' }, [el('a', { href: '#', on: { click: function (e) {
          e.preventDefault();
          update({ view: 'findings', key: k, path: '', group: 'key' });
        } } }, [k]), ': ' + plural(r.notes[k], 'finding')]);
      });
      return el('tr', { class: 'tier' }, [
        el('td', null, [r.name + (r.declared ? '' : ' (not declared)'), r.line ? el('div', { class: 'tier-note' }, ['hiera.yaml:' + r.line]) : null]),
        el('td', { class: 'paths mono' }, [r.paths.join('\n')]),
        el('td', null, vars.length ? vars : [el('span', { class: 'empty' }, ['none'])]),
        el('td', null, notes),
      ]);
    });
    section.appendChild(el('table', null, [
      el('thead', null, [el('tr', null, [el('th', null, ['tier']), el('th', null, ['paths']),
        el('th', null, ['interpolates']), el('th', null, ['findings'])])]),
      el('tbody', null, trs),
    ]));
    return [section];
  }

  // ---- utilization view --------------------------------------------------

  function utilizationView() {
    if (!data.utilization) {
      return { controls: [], results: function () {
        return [el('section', { id: 'utilization' }, [el('h2', null, ['Utilization']), el('p', { class: 'empty' },
          ['not available: no report document was built into this page (`driftless report --data-file`)'])])];
      } };
    }
    const shownEl = el('span', { class: 'shown' });
    const controls = el('div', { class: 'controls' }, [
      select('show', 'cat', CATEGORIES.map(function (c) { return [c, c]; })),
      select('group by', 'by', [['', 'none'], ['collector', 'collector'], ['environment', 'environment']]),
      select('sort by', 'sort', [['name', 'name'], ['count', 'count']]),
      select('order', 'dir', [['asc', 'ascending'], ['desc', 'descending']]),
      textInput('name', 'match', 'regex'),
      textInput('nodes', 'count', 'e.g. 0 or >1 <10'),
      resetButton(['cat', 'by', 'sort', 'dir', 'match', 'count']),
      shownEl,
    ]);
    return { controls: [el('h2', null, ['Utilization']), controls], results: function () {
      return utilizationSections(shownEl);
    } };
  }

  function utilizationSections(shownEl) {
    const section = el('section', { id: 'utilization' });
    const result = utilizationRows(data.utilization, state);
    shownEl.textContent = result.rows.length + ' of ' + result.total + ' ' + state.cat;
    if (result.badCount) {
      section.appendChild(el('p', { class: 'empty' }, ['nodes filter not understood; use a number or comparisons like >1 <10']));
    }
    if (!result.rows.length) {
      section.appendChild(el('p', { class: 'empty' }, ['nothing matches']));
      return [section];
    }
    const head = [el('th', null, [state.cat.replace(/s$/, '')]), el('th', { class: 'count' }, ['nodes'])]
      .concat(result.columns.map(function (c) { return el('th', { class: 'count' }, [c]); }));
    const body = result.rows.map(function (r) {
      return el('tr', null, [el('td', { class: 'name' }, [r.name]), el('td', { class: 'count' }, [String(r.nodes)])]
        .concat(r.cells.map(function (n) { return el('td', { class: 'count' }, [String(n)]); })));
    });
    section.appendChild(el('table', null, [el('thead', null, [el('tr', null, head)]), el('tbody', null, body)]));
    return [section];
  }

  // ---- render ------------------------------------------------------------

  function renderNav() {
    while (nav.firstChild) { nav.removeChild(nav.firstChild); }
    VIEWS.forEach(function (v) {
      const b = el('button', { type: 'button', class: v === state.view ? 'active' : '' }, [v]);
      b.addEventListener('click', function () { update({ view: v }); });
      nav.appendChild(b);
    });
    nav.hidden = false;
  }

  let view = null;
  const results = el('div', { id: 'results' });

  function render() {
    renderNav();
    view = state.view === 'hierarchy' ? hierarchyView()
      : state.view === 'utilization' ? utilizationView() : findingsView();
    while (app.firstChild) { app.removeChild(app.firstChild); }
    view.controls.filter(Boolean).forEach(function (c) { app.appendChild(c); });
    app.appendChild(results);
    renderResults();
  }

  function renderResults() {
    while (results.firstChild) { results.removeChild(results.firstChild); }
    view.results().filter(Boolean).forEach(function (s) { results.appendChild(s); });
  }

  global.addEventListener('hashchange', function () {
    state = parseHash(global.location.hash);
    render();
  });

  render();
})(typeof globalThis !== 'undefined' ? globalThis : this);
