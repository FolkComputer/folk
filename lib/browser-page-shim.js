// Injected by builtin-programs/browser.folk into every page it shows.
//
// Chromium draws the option list of a <select> in a popup widget of its own, which is not part
// of the page's picture: on the table it could be neither seen nor clicked. When the mouse
// presses a (single-choice, drop-down) <select>, give that one select `appearance: base-select`,
// whose list is part of the page; put it back once the choice is made or the select loses
// focus. Keyboard use (arrow keys on a closed select) keeps its native behaviour.
(function () {
  if (window.__folkSelectShim) return;
  window.__folkSelectShim = true;
  var CLS = '__folk-base-select';
  function install() {
    try {
      var sheet = new CSSStyleSheet();
      sheet.replaceSync('select.' + CLS + ', select.' + CLS + '::picker(select) { appearance: base-select; }');
      document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
    } catch (e) { /* no customizable select in this Chromium: nothing to do */ }
  }
  if (document.documentElement) install(); else document.addEventListener('DOMContentLoaded', install);
  function restore(s) { setTimeout(function () { s.classList.remove(CLS); }, 0); }
  addEventListener('mousedown', function (e) {
    var s = e.target && e.target.closest ? e.target.closest('select') : null;
    if (!s || s.multiple || s.size > 1 || s.classList.contains(CLS)) return;
    s.classList.add(CLS);
    s.addEventListener('change', function () { restore(s); }, { once: true });
    s.addEventListener('blur', function () { restore(s); }, { once: true });
  }, true);
})();
