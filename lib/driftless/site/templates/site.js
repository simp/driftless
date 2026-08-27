// driftless site — renders the embedded build data. No dependencies, no
// build step. The data element is JSON (see Site.embed_json); everything on
// the page is derived from it at load time.
(function () {
  'use strict';

  var SEVERITIES = ['error', 'warning', 'note'];

  var data = JSON.parse(document.getElementById('driftless-data').textContent);
  var app = document.getElementById('app');

  // ---- DOM helpers --------------------------------------------------------

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === 'class') { node.className = attrs[k]; } else { node.setAttribute(k, attrs[k]); }
      });
    }
    (children || []).forEach(function (c) {
      node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return node;
  }

  function location(f) {
    if (!f.path) { return '-'; }
    return f.line ? f.path + ':' + f.line : f.path;
  }

  function groupBy(items, keyFn) {
    var groups = {};
    items.forEach(function (item) {
      var k = keyFn(item);
      (groups[k] = groups[k] || []).push(item);
    });
    return Object.keys(groups).sort().map(function (k) { return { key: k, items: groups[k] }; });
  }

  // ---- Sections -----------------------------------------------------------

  function warningsSection(warnings) {
    if (!warnings.length) { return null; }
    return el('section', { class: 'warnings' }, [
      el('strong', null, [warnings.length + (warnings.length === 1 ? ' warning' : ' warnings') + ' raised during the run']),
      el('ul', null, warnings.map(function (w) { return el('li', null, [w]); }))
    ]);
  }

  // Count table: count first, then severity and quality, then the key; total
  // last with a per-severity breakdown — the terminal count table's layout.
  function summarySection(findings) {
    var section = el('section', { id: 'summary' }, [el('h2', null, ['Summary'])]);
    if (!findings.length) {
      section.appendChild(el('p', { class: 'empty' }, ['no findings']));
      return section;
    }

    var rows = groupBy(findings, function (f) { return f.key; }).map(function (g) {
      var first = g.items[0];
      return el('tr', null, [
        el('td', { class: 'count' }, [String(g.items.length)]),
        el('td', { class: 'severity-' + first.severity }, [first.severity]),
        el('td', { class: 'quality' }, [first.quality || '']),
        el('td', { class: 'key' }, [g.key])
      ]);
    });

    var breakdown = SEVERITIES.map(function (s) {
      var n = findings.filter(function (f) { return f.severity === s; }).length;
      return el('span', { class: 'severity-' + s }, [n + ' ' + s]);
    });
    var totalCell = el('td', { colspan: '3' }, ['total: ']);
    breakdown.forEach(function (span, i) {
      if (i > 0) { totalCell.appendChild(document.createTextNode(', ')); }
      totalCell.appendChild(span);
    });
    rows.push(el('tr', { class: 'total' }, [el('td', { class: 'count' }, [String(findings.length)]), totalCell]));

    section.appendChild(el('table', null, [
      el('thead', null, [el('tr', null, [el('th', null, ['#']), el('th', null, ['severity']), el('th', null, ['quality']), el('th', null, ['key'])])]),
      el('tbody', null, rows)
    ]));
    return section;
  }

  // Findings grouped by key, in key order, each row a location and message.
  function findingsSection(findings) {
    var section = el('section', { id: 'findings' }, [el('h2', null, ['Findings'])]);
    if (!findings.length) {
      section.appendChild(el('p', { class: 'empty' }, ['no findings']));
      return section;
    }

    groupBy(findings, function (f) { return f.key; }).forEach(function (g) {
      var first = g.items[0];
      var heading = el('h3', null, [
        el('span', { class: 'severity-' + first.severity }, [first.severity]), ' ',
        el('span', { class: 'quality' }, [first.quality || '']), ' ',
        el('span', { class: 'key' }, [g.key]), ' ',
        el('span', { class: 'count' }, ['(' + g.items.length + (g.items.length === 1 ? ' finding)' : ' findings)')])
      ]);
      var rows = g.items.slice().sort(function (a, b) {
        var pa = a.path || '', pb = b.path || '';
        return pa < pb ? -1 : pa > pb ? 1 : (a.line || 0) - (b.line || 0);
      }).map(function (f) {
        return el('tr', null, [el('td', { class: 'location' }, [location(f)]), el('td', null, [f.message])]);
      });
      section.appendChild(el('div', { class: 'group' }, [heading, el('table', null, [el('tbody', null, rows)])]));
    });
    return section;
  }

  // ---- Render -------------------------------------------------------------

  function render() {
    var findings = data.findings || [];
    [warningsSection(data.warnings || []), summarySection(findings), findingsSection(findings)]
      .filter(Boolean)
      .forEach(function (section) { app.appendChild(section); });
  }

  render();
})();
